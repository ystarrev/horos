import AppKit
import Foundation
import Dispatch
import Metal
import MetalKit
import simd

private let registrationHistogramBins = 64
// Keep the MIND accumulator layout synchronized with MetalShaders.metal.
private let registrationMINDAgreementScale = 65_535.0
private let registrationMINDAgreementLowIndex = 0
private let registrationMINDAgreementHighIndex = 1
private let registrationMINDValidDescriptorCountIndex = 2
private let registrationMINDOverlapCountIndex = 3
// A small tile retains enough parallel work while amortizing the fixed-volume
// sample and mask decision across nearby transform candidates.
private let registrationCandidateTileSize = 4
private let maximumMPRPlaneTiltRadians = Float.pi / 4
private let maximumInlineMetalVertexBytes = 4 * 1024

private enum RegistrationSamplingMode: String {
    case fast
    case reference
}

private enum RegistrationSearchMode {
    case full
    case refinement
}

struct MetalViewerRegistrationWorldTransform {
    let movingToFixedWorld: simd_float4x4

    var inverted: MetalViewerRegistrationWorldTransform {
        MetalViewerRegistrationWorldTransform(
            movingToFixedWorld: simd_inverse(movingToFixedWorld)
        )
    }
}

struct MetalViewerRegistrationSupportInput {
    let identifier: String
    let pixList: [DCMPix]
    let pairedPixList: [DCMPix]?
    let sharesBaseFrame: Bool
    let weight: Float
}

private final class RegistrationJob: @unchecked Sendable {
    let generation: UInt
    private let refinementTranslationAnchor: SIMD3<Float>?
    private let refinementRotationAnchor: SIMD3<Float>?
    private let maximumRefinementTranslationMM: Float = 6
    private let maximumRefinementRotationRadians: Float = 2 * .pi / 180

    private let cancellationLock = NSLock()
    private var cancelled = false

    init(
        generation: UInt,
        refinementTranslationAnchor: SIMD3<Float>? = nil,
        refinementRotationAnchor: SIMD3<Float>? = nil
    ) {
        self.generation = generation
        self.refinementTranslationAnchor = refinementTranslationAnchor
        self.refinementRotationAnchor = refinementRotationAnchor
    }

    var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    func permits(
        translationWorld: SIMD3<Float>,
        rotationRadians: SIMD3<Float>
    ) -> Bool {
        guard let refinementTranslationAnchor,
              let refinementRotationAnchor else {
            return true
        }
        return simd_length(translationWorld - refinementTranslationAnchor)
                <= maximumRefinementTranslationMM
            && simd_length(rotationRadians - refinementRotationAnchor)
                <= maximumRefinementRotationRadians
    }
}

private enum MetalMPRPreviewLayoutDefaults {
    static let widthFractionDefaultsKey = "HorosMetalViewerMPRPreviewWidthFraction"
    static let defaultWidthFraction: CGFloat = 0.24
    static let minimumWidthFraction: CGFloat = 0.16
    static let maximumWidthFraction: CGFloat = 0.55
    static let gap: CGFloat = 8
    static let paneGap: CGFloat = 6
    static let minimumPreviewWidth: CGFloat = 170
    static let minimumMainWidth: CGFloat = 240
}

private func configureMPRAlphaBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .sourceAlpha
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.rgbBlendOperation = .add
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    attachment.alphaBlendOperation = .add
}

private struct MetalUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var rotationRadians: Float
    var drawableAspect: Float
    var baseWindowLevel: Float
    var baseWindowWidth: Float
    var overlayWindowLevel: Float
    var overlayWindowWidth: Float
    var overlayBlend: Float
    var overlayTranslationWorld: SIMD3<Float>
    var movingRotationCenterWorld: SIMD3<Float>
    var fixedVolumeSize: SIMD3<UInt32>
    var currentSliceIndex: Float
    var movingInverseRotation: simd_float4x4
    var fixedVoxelToWorld: simd_float4x4
    var movingWorldToVoxel: simd_float4x4
    var hasOverlay: UInt32
    var imageInterpolationMode: UInt32
    var baseHasCustomCLUT: UInt32
    var overlayHasCustomCLUT: UInt32
    var baseVolumeTextureKind: UInt32
    var baseVolumeRescaleSlope: Float
    var baseVolumeRescaleIntercept: Float
    var baseVolumePadding: UInt32
}

private struct MetalMPRUniforms {
    var viewProjectionMatrix: simd_float4x4
    var baseWindowLevel: Float
    var baseWindowWidth: Float
    var overlayWindowLevel: Float
    var overlayWindowWidth: Float
    var overlayBlend: Float
    var overlayTranslationWorld: SIMD3<Float>
    var movingRotationCenterWorld: SIMD3<Float>
    var fixedVolumeSize: SIMD3<UInt32>
    var movingInverseRotation: simd_float4x4
    var fixedVoxelToWorld: simd_float4x4
    var movingWorldToVoxel: simd_float4x4
    var hasOverlay: UInt32
    var baseHasCustomCLUT: UInt32
    var overlayHasCustomCLUT: UInt32
}

private struct RegistrationUniforms {
    var baseWindowLevel: Float
    var baseWindowWidth: Float
    var overlayWindowLevel: Float
    var overlayWindowWidth: Float
    var metricOptions: SIMD4<Float>
    var baseTextureSize: SIMD3<UInt32>
    var fixedVoxelToMovingTexture: simd_float4x4
    var samplingOptions: SIMD4<UInt32>
}

private struct BlockMatchingUniforms {
    var windows: SIMD4<Float>
    var baseTextureSize: SIMD4<UInt32>
    var movingTextureSize: SIMD4<UInt32>
    var blockStrideAndFlags: SIMD4<UInt32>
    var blockRadius: SIMD4<UInt32>
    var searchRadius: SIMD4<UInt32>
    var fixedVoxelToMovingTexture: simd_float4x4
}

private struct BlockMatchResult {
    var displacementAndScore: SIMD4<Float>
    var quality: SIMD4<Float>
}

private struct BlockCorrespondence {
    let movingWorld: SIMD3<Float>
    let fixedWorld: SIMD3<Float>
    let score: Float
    let distinctiveness: Float
}

private enum BlockMatchingMetric: UInt32 {
    case intensityNCC = 0
    case gradientMagnitudeNCC = 1
    case mindSelfSimilarity = 2
}

private struct MRSequenceSignature {
    let scanningSequences: Set<String>
    let scanOptions: Set<String>
    let imageTypes: Set<String>

    var isSpinEcho: Bool {
        scanningSequences.contains("SE")
    }

    var isGradientEcho: Bool {
        scanningSequences.contains("GR")
    }

    var usesFatSuppression: Bool {
        imageTypes.contains("WATER") || scanOptions.contains { option in
            option == "FS"
                || option.hasPrefix("FS_")
                || option.hasPrefix("FSA")
                || option.contains("FATSAT")
                || option.contains("FAT_SUP")
        }
    }

    var dixonContrastComponents: Set<String> {
        imageTypes.intersection(["WATER", "FAT", "IN_PHASE", "OPP_PHASE"])
    }
}

private struct RigidTransformState {
    var translationWorld: SIMD3<Float>
    var rotationRadians: SIMD3<Float>
}

private struct ParameterVector {
    var values: [Float]

    init(_ x: Float, _ y: Float, _ z: Float, _ rx: Float, _ ry: Float, _ rz: Float) {
        self.values = [x, y, z, rx, ry, rz]
    }

    init(repeating value: Float) {
        self.values = Array(repeating: value, count: 6)
    }

    subscript(index: Int) -> Float {
        get { values[index] }
        set { values[index] = newValue }
    }

    static func + (lhs: ParameterVector, rhs: ParameterVector) -> ParameterVector {
        var result = lhs
        for index in 0..<6 {
            result[index] += rhs[index]
        }
        return result
    }

    static func - (lhs: ParameterVector, rhs: ParameterVector) -> ParameterVector {
        var result = lhs
        for index in 0..<6 {
            result[index] -= rhs[index]
        }
        return result
    }

    static func * (lhs: Float, rhs: ParameterVector) -> ParameterVector {
        var result = rhs
        for index in 0..<6 {
            result[index] *= lhs
        }
        return result
    }

    static func * (lhs: ParameterVector, rhs: Float) -> ParameterVector {
        rhs * lhs
    }

    static func / (lhs: ParameterVector, rhs: Float) -> ParameterVector {
        (1 / rhs) * lhs
    }

    mutating func add(_ other: ParameterVector) {
        for index in 0..<6 {
            values[index] += other[index]
        }
    }

    func distance(to other: ParameterVector) -> Float {
        var sum: Float = 0
        for index in 0..<6 {
            let delta = values[index] - other[index]
            sum += delta * delta
        }
        return sqrt(sum)
    }
}

private typealias VolumeLevel = MetalPreparedVolumeLevel

private struct SlabGeometry {
    let normalWorld: SIMD3<Float>
    let thicknessMM: Float
}

private struct PreparedRegistrationSupportVolume {
    let input: MetalViewerRegistrationSupportInput
    let entry: MetalPreparedVolumeCache.Entry
    let pairedEntry: MetalPreparedVolumeCache.Entry?
}

private struct RegistrationSupportMetricPair {
    let identifier: String
    let fixedLevel: VolumeLevel
    let movingLevel: VolumeLevel
    let fixedWindow: MetalViewerWindowLevel
    let movingWindow: MetalViewerWindowLevel
    let usesReverseTransform: Bool
    let weight: Float
}

private struct RegistrationBlockMatchingPair {
    let identifier: String
    let fixedLevel: VolumeLevel
    let movingLevel: VolumeLevel
    let fixedWindow: MetalViewerWindowLevel
    let movingWindow: MetalViewerWindowLevel
}

private struct RegistrationSupportMetricContext {
    let primaryWeight: Float
    let pairs: [RegistrationSupportMetricPair]
}

private struct MetalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct MetalMPRVertex {
    var position: SIMD3<Float>
    var baseVoxel: SIMD3<Float>
    var color: SIMD4<Float>

    init(
        position: SIMD3<Float>,
        baseVoxel: SIMD3<Float>,
        color: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
    ) {
        self.position = position
        self.baseVoxel = baseVoxel
        self.color = color
    }

    func withColor(_ color: SIMD4<Float>) -> MetalMPRVertex {
        MetalMPRVertex(position: position, baseVoxel: baseVoxel, color: color)
    }
}

private enum MetalMPRPlane: Int {
    case sagittal = 0
    case coronal = 1
    case axial = 2
}

private struct MetalMPRPlaneHit {
    let plane: MetalMPRPlane
    let baseVoxel: SIMD3<Float>
    let depth: Float
}

private struct MetalMPRPlaneDragState {
    let plane: MetalMPRPlane
    let startPoint: SIMD2<Float>
    let startPlaneVoxel: Float
    let screenDeltaPerVoxel: SIMD2<Float>
}

private struct MetalMPRPlaneTiltDragState {
    let plane: MetalMPRPlane
    let componentIndex: Int
    let startPoint: SIMD2<Float>
    let startAngle: Float
    let screenDeltaPerRadian: SIMD2<Float>
}

private struct MetalMPRPreviewHit {
    let plane: MetalMPRPlane
    let baseVoxel: SIMD3<Float>
}

enum MetalMPRPreviewLineInteraction: Equatable {
    case move
    case tilt
}

struct MetalMPRPreviewLinePointer {
    let interaction: MetalMPRPreviewLineInteraction
    let lineAngleRadians: CGFloat
    let actionAngleRadians: CGFloat?
}

private struct MetalMPRPreviewLineHit {
    let displayedPlane: MetalMPRPlane
    let referencePlane: MetalMPRPlane
    let interaction: MetalMPRPreviewLineInteraction
    let componentIndex: Int?
    let baseVoxel: SIMD3<Float>
    let paneRect: CGRect
    let lineFraction: Float
    let lineAngleRadians: CGFloat
    let actionAngleRadians: CGFloat?
}

private struct MetalMPRPreviewLineDragContext {
    let displayedPlane: MetalMPRPlane
    let referencePlane: MetalMPRPlane
    let interaction: MetalMPRPreviewLineInteraction
    let componentIndex: Int?
    let baseVoxel: SIMD3<Float>
    let paneRect: CGRect
    let lineFraction: Float
    var continuousLineAngleRadians: CGFloat
    let actionLineAngleOffsetRadians: CGFloat?
}

private struct MetalMPRPreviewPane {
    let plane: MetalMPRPlane
    let viewport: MTLViewport
    let scissor: MTLScissorRect
    let unitScale: CGFloat
}

private struct MetalMPRPreviewOrientation {
    let horizontalUsesFirstCoordinate: Bool
    let horizontalIsForward: Bool
    let verticalIsForward: Bool

    func screenFractions(first: Float, second: Float) -> SIMD2<Float> {
        var horizontal = horizontalUsesFirstCoordinate ? first : second
        var vertical = horizontalUsesFirstCoordinate ? second : first
        if horizontalIsForward == false { horizontal = 1 - horizontal }
        if verticalIsForward == false { vertical = 1 - vertical }
        return SIMD2<Float>(horizontal, vertical)
    }

    func planeFractions(horizontal: Float, vertical: Float) -> SIMD2<Float> {
        let resolvedHorizontal = horizontalIsForward ? horizontal : 1 - horizontal
        let resolvedVertical = verticalIsForward ? vertical : 1 - vertical
        return horizontalUsesFirstCoordinate
            ? SIMD2<Float>(resolvedHorizontal, resolvedVertical)
            : SIMD2<Float>(resolvedVertical, resolvedHorizontal)
    }
}

private struct MetalMPRRenderLayout {
    let mainViewport: MTLViewport
    let mainScissor: MTLScissorRect
    let previewPanes: [MetalMPRPreviewPane]
}

struct MetalMPRPreviewOverlayPane {
    let rect: CGRect
    let borderColor: NSColor?
    let left: String
    let right: String
    let top: String
    let bottom: String
}

struct MetalMPRPreviewOverlayLayout {
    let mainRect: CGRect
    let dividerRect: CGRect
    let previewPanes: [MetalMPRPreviewOverlayPane]
}

enum MetalViewerDisplayMode {
    case stack2D
    case mpr
    case mpr3D

    var isMPRLike: Bool {
        switch self {
        case .mpr, .mpr3D:
            return true
        case .stack2D:
            return false
        }
    }
}

private enum MetalViewerWindowLevelTarget {
    case base
    case overlay
}

struct MetalPrintFrame {
    let bgraPixels: Data
    let width: Int
    let height: Int

    func makeImage() -> NSImage? {
        guard width > 0,
              height > 0,
              bgraPixels.count >= width * height * 4,
              let provider = CGDataProvider(data: bgraPixels as CFData)
        else {
            return nil
        }

        let alphaInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(alphaInfo)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(width), height: CGFloat(height))
        )
    }
}

final class MetalViewerRenderer: NSObject, MTKViewDelegate {
    private static let mprPlanes: [MetalMPRPlane] = [.axial, .coronal, .sagittal]
    private static let initialMPRRotation = simd_normalize(
        simd_quatf(angle: -0.65, axis: SIMD3<Float>(0, 0, 1)) *
        simd_quatf(angle: -0.55, axis: SIMD3<Float>(1, 0, 0))
    )

    private let deviceRef: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let mprPipelineState: MTLRenderPipelineState
    private let mprPlaneHighlightPipelineState: MTLRenderPipelineState
    private let mprBorderPipelineState: MTLRenderPipelineState
    private let mprIntersectionPipelineState: MTLRenderPipelineState
    private let mprDepthStencilState: MTLDepthStencilState
    private let registrationPipelineState: MTLComputePipelineState
    private let registrationBatchPipelineState: MTLComputePipelineState
    private let registrationBlockMatchingPipelineState: MTLComputePipelineState
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    private(set) var pixList: [DCMPix]
    private var overlayPixList: [DCMPix] = []
    private var baseVolumeTexture: MTLTexture?
    private var baseCLUTTexture: MTLTexture?
    private var baseOpacityTexture: MTLTexture?
    private var overlayCLUTTexture: MTLTexture?
    private var overlayOpacityTexture: MTLTexture?
    private var baseTransferFunctionState = MetalViewerTransferFunctionState()
    private var overlayTransferFunctionState = MetalViewerTransferFunctionState()
    private var baseHasCustomCLUT = false
    private var overlayHasCustomCLUT = false
    private var stackVolumeTextureEntry: MetalSeriesTextureCache.Entry?
    private var immediateStackSliceTextureEntry: MetalSeriesTextureCache.Entry?
    private var immediateStackSliceIndex: Int?
    private var immediateStackSlicePixels: MetalStoredInt16PixelData?
    private var requestedStackVolumeKey: String?
    private var requestedBasePreparedVolumeKey: String?
    private var overlaySourceTextureEntry: MetalSeriesTextureCache.Entry?
    private var requestedOverlayVolumeKey: String?
    private var requestedOverlayPreparedVolumeKey: String?
    private var overlayVolumeTexture: MTLTexture?
    private var baseVolumeDimensions = SIMD3<Int>(repeating: 1)
    private var overlayVolumeDimensions = SIMD3<Int>(repeating: 1)
    private var baseVolumeLevels: [VolumeLevel] = []
    private var overlayVolumeLevels: [VolumeLevel] = []
    private var imageAspectRatio: Float = 1
    private var fixedVoxelToWorld = matrix_identity_float4x4
    private var movingWorldToVoxel = matrix_identity_float4x4
    private var movingRotationCenterWorld = SIMD3<Float>(repeating: 0)
    private var baseVolumeCenterWorld = SIMD3<Float>(repeating: 0)
    private var overlayVolumeCenterWorld = SIMD3<Float>(repeating: 0)
    private var baseInformativeCenterWorld = SIMD3<Float>(repeating: 0)
    private var overlayInformativeCenterWorld = SIMD3<Float>(repeating: 0)
    private var baseUsesGantryTiltCorrectedVolume = false
    private var overlayUsesGantryTiltCorrectedVolume = false
    private var baseIsThinSlab = false
    private var overlayIsThinSlab = false
    private var baseSlabGeometry: SlabGeometry?
    private var overlaySlabGeometry: SlabGeometry?
    private var contrastInvariantMRSlabMatchingCache: Bool?
    private var minimumCranialCoverageFractionCache: Float?
    private var registrationPrimaryWeight: Float = 1
    private var registrationSupportInputs: [MetalViewerRegistrationSupportInput] = []
    private var preparedRegistrationSupportVolumes: [PreparedRegistrationSupportVolume] = []
    private let registrationSupportLock = NSLock()
    private var pendingRegistrationSupportIdentifiers = Set<String>()
    private var registrationSupportPreparationStarted = false
    private var registrationSupportGeneration: UInt = 0

    private(set) var currentSliceIndex = 0
    private(set) var windowLevel: Float = 0
    private(set) var windowWidth: Float = 1
    private var defaultSeriesWindowLevel: MetalViewerWindowLevel?
    private var customSeriesWindowLevel: MetalViewerWindowLevel?
    private var usesAutomaticBaseWindowLevel: Bool
    private(set) var overlayWindowLevel: Float = 0
    private(set) var overlayWindowWidth: Float = 1
    private var overlayDefaultSeriesWindowLevel: MetalViewerWindowLevel?
    private var overlayCustomSeriesWindowLevel: MetalViewerWindowLevel?
    private var usesAutomaticOverlayWindowLevel = false
    private var baseRegistrationWindowLevel: Float = 0
    private var baseRegistrationWindowWidth: Float = 1
    private var overlayRegistrationWindowLevel: Float = 0
    private var overlayRegistrationWindowWidth: Float = 1
    private(set) var overlayBlend: Float = 0.5
    private(set) var overlayTranslationWorld = SIMD3<Float>(repeating: 0)
    private(set) var overlayRotationRadians = SIMD3<Float>(repeating: 0)
    private(set) var overlayTranslationPixels = SIMD2<Float>(repeating: 0)
    private(set) var zoomScale: Float = 1
    private(set) var panOffset = SIMD2<Float>(repeating: 0)
    private var mpr3DPanOffsets: [MetalMPRPlane: SIMD2<Float>] = [:]
    private(set) var stackRotationRadians: Float = 0
    private(set) var displayMode: MetalViewerDisplayMode = .stack2D
    private var mprRotation = MetalViewerRenderer.initialMPRRotation
    private var mprPlaneVoxel = SIMD3<Float>(repeating: 0)
    private var mprAxialTilt = SIMD2<Float>(repeating: 0)
    private var mprCoronalTilt = SIMD2<Float>(repeating: 0)
    private var mprSagittalTilt = SIMD2<Float>(repeating: 0)
    private var mprAxialTiltPivot = SIMD2<Float>(repeating: 0)
    private var mprCoronalTiltPivot = SIMD2<Float>(repeating: 0)
    private var mprSagittalTiltPivot = SIMD2<Float>(repeating: 0)
    private var mprPreviewWidthFraction: CGFloat = {
        let value = UserDefaults.standard.object(forKey: MetalMPRPreviewLayoutDefaults.widthFractionDefaultsKey) as? Double
        let fraction = CGFloat(value ?? Double(MetalMPRPreviewLayoutDefaults.defaultWidthFraction))
        return min(
            max(fraction, MetalMPRPreviewLayoutDefaults.minimumWidthFraction),
            MetalMPRPreviewLayoutDefaults.maximumWidthFraction
        )
    }()
    private var tumourSeeds: [MetalViewerTumourSeed] = []
    private var imageInterpolationMode = MetalViewerImageInterpolationMode.saved
    private var defaultsObserver: NSObjectProtocol?
    private var hoveredMPRPlane: MetalMPRPlane?
    private var mprPlaneDragState: MetalMPRPlaneDragState?
    private var mprPlaneTiltDragState: MetalMPRPlaneTiltDragState?
    private var mprPreviewLineDragContext: MetalMPRPreviewLineDragContext?
    private var registrationGeneration: UInt = 0
    private var activeRegistrationJob: RegistrationJob?
    private var registrationInProgress = false
    private var registrationProgress: Float = 0
    private var registrationStatusMessage: String?
    private var suggestedRegistrationWorldTransform: MetalViewerRegistrationWorldTransform?

    var stateDidChange: ((String) -> Void)?
    var registrationDidChange: ((Bool, String, Float) -> Void)?
    var registrationTransformDidComplete: ((MetalViewerRegistrationWorldTransform) -> Void)?
    var windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?
    var overlayWindowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?
    var transferFunctionStateDidChange: ((MetalViewerTransferFunctionState) -> Void)?
    var overlayTransferFunctionStateDidChange: ((MetalViewerTransferFunctionState) -> Void)?

    var activeWindowLevel: Float {
        activeWindowLevelTarget == .overlay ? overlayWindowLevel : windowLevel
    }

    var activeWindowWidth: Float {
        activeWindowLevelTarget == .overlay ? overlayWindowWidth : windowWidth
    }

    var isOverlayWindowLevelActive: Bool {
        activeWindowLevelTarget == .overlay
    }

    var activeTransferFunctionState: MetalViewerTransferFunctionState {
        activeWindowLevelTarget == .overlay ? overlayTransferFunctionState : baseTransferFunctionState
    }

    var currentPix: DCMPix? {
        guard pixList.indices.contains(currentSliceIndex) else { return nil }
        return pixList[currentSliceIndex]
    }

    var currentOverlayPix: DCMPix? {
        guard overlayPixList.isEmpty == false else { return nil }
        let overlayIndex = min(currentSliceIndex, overlayPixList.count - 1)
        return overlayPixList[overlayIndex]
    }

    var displayedStackRotationDegrees: Float {
        var degrees = stackRotationRadians * 180.0 / Float.pi
        degrees.formTruncatingRemainder(dividingBy: 360.0)
        if degrees < 0 {
            degrees += 360.0
        }
        return degrees
    }

    var displaysGantryTiltCorrectedImage: Bool {
        switch displayMode {
        case .stack2D:
            return stackDisplayUsesCorrectedBaseVolume()
                || (overlayVolumeTexture != nil && overlayUsesGantryTiltCorrectedVolume)
        case .mpr, .mpr3D:
            return baseUsesGantryTiltCorrectedVolume
                || (overlayVolumeTexture != nil && overlayUsesGantryTiltCorrectedVolume)
        }
    }

    var stateDescription: String {
        let sliceText: String
        switch displayMode {
        case .stack2D:
            sliceText = pixList.count > 1 ? "Slice \(currentSliceIndex + 1)/\(pixList.count)" : "Slice 1/1"
        case .mpr:
            sliceText = "MPR"
        case .mpr3D:
            sliceText = "3D MPR"
        }
        let zoomText = formattedStateValue(zoomScale * 100)
        let registrationText: String
        if overlayVolumeTexture != nil {
            registrationText = String(
                format: "  Reg T(%.1f, %.1f, %.1f mm) R(%.1f, %.1f, %.1f°)",
                overlayTranslationWorld.x,
                overlayTranslationWorld.y,
                overlayTranslationWorld.z,
                overlayRotationRadians.x * 180 / .pi,
                overlayRotationRadians.y * 180 / .pi,
                overlayRotationRadians.z * 180 / .pi
            )
        } else {
            registrationText = ""
        }

        let progressText: String
        if registrationInProgress {
            let progressPercent = formattedStateValue(registrationProgress * 100)
            let prefix = registrationStatusMessage ?? "Registering"
            progressText = "  \(prefix) \(progressPercent)%"
        } else {
            progressText = ""
        }

        return "\(sliceText)  WL \(formattedStateValue(windowLevel))  WW \(formattedStateValue(windowWidth))  Zoom \(zoomText)%\(registrationText)\(progressText)"
    }

    private func formattedStateValue(_ value: Float) -> String {
        guard value.isFinite else { return "--" }

        let roundedValue = Double(value.rounded())
        if abs(roundedValue) < 1_000_000_000 {
            return String(format: "%.0f", roundedValue)
        }
        return String(format: "%.3g", roundedValue)
    }

    init(
        device: MTLDevice,
        pixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        usesAutomaticWindowLevel: Bool = false,
        transferFunctionState: MetalViewerTransferFunctionState = MetalViewerTransferFunctionState()
    ) {
        self.deviceRef = device
        self.pixList = pixList
        self.defaultSeriesWindowLevel = windowLevelState.defaultWindow
        self.customSeriesWindowLevel = windowLevelState.customWindow
        self.usesAutomaticBaseWindowLevel = usesAutomaticWindowLevel
        self.baseTransferFunctionState = transferFunctionState

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Could not create Metal command queue.")
        }
        self.commandQueue = commandQueue

        let vertices: [MetalVertex] = [
            MetalVertex(position: [-1, -1], texCoord: [0, 1]),
            MetalVertex(position: [1, -1], texCoord: [1, 1]),
            MetalVertex(position: [-1, 1], texCoord: [0, 0]),
            MetalVertex(position: [1, 1], texCoord: [1, 0]),
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<MetalVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            fatalError("Could not create Metal vertex buffer.")
        }
        self.vertexBuffer = vertexBuffer

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "metalViewerVertex"),
              let fragmentFunction = library.makeFunction(name: "metalViewerFragment"),
              let mprVertexFunction = library.makeFunction(name: "metalViewerMPRVertex"),
              let mprFragmentFunction = library.makeFunction(name: "metalViewerMPRFragment"),
              let mprPlaneHighlightVertexFunction = library.makeFunction(name: "metalViewerMPRPlaneHighlightVertex"),
              let mprPlaneHighlightFragmentFunction = library.makeFunction(name: "metalViewerMPRPlaneHighlightFragment"),
              let mprBorderVertexFunction = library.makeFunction(name: "metalViewerMPRBorderVertex"),
              let mprBorderFragmentFunction = library.makeFunction(name: "metalViewerMPRBorderFragment"),
              let mprIntersectionFragmentFunction = library.makeFunction(name: "metalViewerMPRIntersectionFragment"),
              let registrationFunction = library.makeFunction(name: "metalViewerRegistrationJointHistogram"),
              let registrationBatchFunction = library.makeFunction(name: "metalViewerRegistrationJointHistogramsBatch"),
              let registrationBlockMatchingFunction = library.makeFunction(name: "metalViewerRegistrationBlockMatching") else {
            fatalError("Could not load Metal shader functions.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprPipelineDescriptor.vertexFunction = mprVertexFunction
        mprPipelineDescriptor.fragmentFunction = mprFragmentFunction
        mprPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        mprPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprPlaneHighlightPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprPlaneHighlightPipelineDescriptor.vertexFunction = mprPlaneHighlightVertexFunction
        mprPlaneHighlightPipelineDescriptor.fragmentFunction = mprPlaneHighlightFragmentFunction
        mprPlaneHighlightPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        configureMPRAlphaBlending(mprPlaneHighlightPipelineDescriptor.colorAttachments[0])
        mprPlaneHighlightPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprBorderPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprBorderPipelineDescriptor.vertexFunction = mprBorderVertexFunction
        mprBorderPipelineDescriptor.fragmentFunction = mprBorderFragmentFunction
        mprBorderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        configureMPRAlphaBlending(mprBorderPipelineDescriptor.colorAttachments[0])
        mprBorderPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprIntersectionPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprIntersectionPipelineDescriptor.vertexFunction = mprBorderVertexFunction
        mprIntersectionPipelineDescriptor.fragmentFunction = mprIntersectionFragmentFunction
        mprIntersectionPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        configureMPRAlphaBlending(mprIntersectionPipelineDescriptor.colorAttachments[0])
        mprIntersectionPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            mprPipelineState = try device.makeRenderPipelineState(descriptor: mprPipelineDescriptor)
            mprPlaneHighlightPipelineState = try device.makeRenderPipelineState(descriptor: mprPlaneHighlightPipelineDescriptor)
            mprBorderPipelineState = try device.makeRenderPipelineState(descriptor: mprBorderPipelineDescriptor)
            mprIntersectionPipelineState = try device.makeRenderPipelineState(descriptor: mprIntersectionPipelineDescriptor)
            registrationPipelineState = try device.makeComputePipelineState(function: registrationFunction)
            registrationBatchPipelineState = try device.makeComputePipelineState(function: registrationBatchFunction)
            registrationBlockMatchingPipelineState = try device.makeComputePipelineState(function: registrationBlockMatchingFunction)
        } catch {
            fatalError("Could not create Metal pipeline: \(error)")
        }

        let mprDepthStencilDescriptor = MTLDepthStencilDescriptor()
        mprDepthStencilDescriptor.depthCompareFunction = .lessEqual
        mprDepthStencilDescriptor.isDepthWriteEnabled = true
        guard let mprDepthStencilState = device.makeDepthStencilState(descriptor: mprDepthStencilDescriptor) else {
            fatalError("Could not create Metal MPR depth stencil state.")
        }
        self.mprDepthStencilState = mprDepthStencilState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Could not create Metal sampler state.")
        }
        self.samplerState = samplerState

        super.init()

        rebuildBaseTransferTextures()
        rebuildOverlayTransferTextures()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.refreshImageInterpolationMode()
        }
    }

    deinit {
        activeRegistrationJob?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func resetAndLoadInitialSlice() {
        currentSliceIndex = Self.initialSliceIndex(for: pixList)
        loadSlice(at: currentSliceIndex)
        requestStackVolumeTexture()
        resetMPRPlaneToCurrentSlice()
    }

    private static func initialSliceIndex(for pixList: [DCMPix]) -> Int {
        pixList.isEmpty ? 0 : pixList.count / 2
    }

    func replaceSeries(
        with newPixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState,
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?,
        usesAutomaticWindowLevel: Bool,
        transferFunctionState: MetalViewerTransferFunctionState,
        transferFunctionStateDidChange: ((MetalViewerTransferFunctionState) -> Void)?
    ) {
        guard newPixList.isEmpty == false else { return }

        // Reset all series-owned state while retaining the expensive immutable Metal resources.
        invalidateActiveRegistrationJob()
        registrationInProgress = false
        registrationProgress = 0
        registrationStatusMessage = nil

        pixList = newPixList
        contrastInvariantMRSlabMatchingCache = nil
        minimumCranialCoverageFractionCache = nil
        suggestedRegistrationWorldTransform = nil
        resetRegistrationSupportVolumes()
        currentSliceIndex = Self.initialSliceIndex(for: newPixList)
        baseVolumeTexture = nil
        stackVolumeTextureEntry = nil
        immediateStackSliceTextureEntry = nil
        immediateStackSliceIndex = nil
        immediateStackSlicePixels = nil
        requestedStackVolumeKey = nil
        requestedBasePreparedVolumeKey = nil
        baseVolumeDimensions = SIMD3<Int>(repeating: 1)
        baseVolumeLevels = []
        imageAspectRatio = 1
        fixedVoxelToWorld = matrix_identity_float4x4
        baseVolumeCenterWorld = .zero
        baseInformativeCenterWorld = .zero
        baseUsesGantryTiltCorrectedVolume = false
        baseIsThinSlab = false
        baseSlabGeometry = nil
        baseRegistrationWindowLevel = 0
        baseRegistrationWindowWidth = 1

        defaultSeriesWindowLevel = windowLevelState.defaultWindow
        customSeriesWindowLevel = windowLevelState.customWindow
        usesAutomaticBaseWindowLevel = usesAutomaticWindowLevel
        self.windowLevelStateDidChange = windowLevelStateDidChange
        windowLevel = 0
        windowWidth = 1

        baseTransferFunctionState = transferFunctionState
        self.transferFunctionStateDidChange = transferFunctionStateDidChange
        rebuildBaseTransferTextures()

        overlayPixList = []
        overlaySourceTextureEntry = nil
        requestedOverlayVolumeKey = nil
        requestedOverlayPreparedVolumeKey = nil
        overlayVolumeTexture = nil
        overlayVolumeDimensions = SIMD3<Int>(repeating: 1)
        overlayVolumeLevels = []
        overlayUsesGantryTiltCorrectedVolume = false
        overlayDefaultSeriesWindowLevel = nil
        overlayCustomSeriesWindowLevel = nil
        usesAutomaticOverlayWindowLevel = false
        overlayWindowLevelStateDidChange = nil
        overlayTransferFunctionState = MetalViewerTransferFunctionState()
        overlayTransferFunctionStateDidChange = nil
        rebuildOverlayTransferTextures()
        overlayWindowLevel = 0
        overlayWindowWidth = 1
        overlayRegistrationWindowLevel = 0
        overlayRegistrationWindowWidth = 1
        overlayBlend = 0.5
        overlayVolumeCenterWorld = .zero
        overlayInformativeCenterWorld = .zero
        overlayIsThinSlab = false
        overlaySlabGeometry = nil
        movingWorldToVoxel = matrix_identity_float4x4
        movingRotationCenterWorld = .zero
        overlayTranslationWorld = .zero
        overlayRotationRadians = .zero
        overlayTranslationPixels = .zero

        zoomScale = 1
        panOffset = .zero
        mpr3DPanOffsets.removeAll()
        stackRotationRadians = 0
        displayMode = .stack2D
        mprRotation = Self.initialMPRRotation
        mprPlaneVoxel = .zero
        mprAxialTilt = .zero
        mprCoronalTilt = .zero
        mprSagittalTilt = .zero
        mprAxialTiltPivot = .zero
        mprCoronalTiltPivot = .zero
        mprSagittalTiltPivot = .zero
        hoveredMPRPlane = nil
        mprPlaneDragState = nil
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = nil
        tumourSeeds = []

        loadSlice(at: currentSliceIndex)
        requestStackVolumeTexture()
        resetMPRPlaneToCurrentSlice()
        registrationDidChange?(false, "", 0)
        stateDidChange?(stateDescription)
    }

    private func refreshImageInterpolationMode() {
        let mode = MetalViewerImageInterpolationMode.saved
        guard mode != imageInterpolationMode else { return }
        imageInterpolationMode = mode
        loadSlice(at: currentSliceIndex)
        stateDidChange?(stateDescription)
    }

    func setOverlayPixList(
        _ overlayPixList: [DCMPix],
        suggestedRegistrationWorldTransform: MetalViewerRegistrationWorldTransform? = nil,
        registrationPrimaryWeight: Float = 1,
        registrationSupportInputs: [MetalViewerRegistrationSupportInput] = [],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)? = nil,
        usesAutomaticWindowLevel: Bool = false,
        transferFunctionState: MetalViewerTransferFunctionState = MetalViewerTransferFunctionState(),
        transferFunctionStateDidChange: ((MetalViewerTransferFunctionState) -> Void)? = nil
    ) {
        invalidateActiveRegistrationJob()
        self.overlayPixList = overlayPixList
        contrastInvariantMRSlabMatchingCache = nil
        minimumCranialCoverageFractionCache = nil
        self.suggestedRegistrationWorldTransform = suggestedRegistrationWorldTransform
        resetRegistrationSupportVolumes(
            primaryWeight: registrationPrimaryWeight,
            inputs: registrationSupportInputs
        )
        registrationInProgress = false
        registrationProgress = 0
        registrationStatusMessage = nil
        overlaySourceTextureEntry = nil
        requestedOverlayVolumeKey = nil
        requestedOverlayPreparedVolumeKey = nil
        overlayVolumeTexture = nil
        overlayVolumeLevels = []
        overlayUsesGantryTiltCorrectedVolume = false
        overlayDefaultSeriesWindowLevel = windowLevelState.defaultWindow
        overlayCustomSeriesWindowLevel = windowLevelState.customWindow
        usesAutomaticOverlayWindowLevel = usesAutomaticWindowLevel
        overlayWindowLevelStateDidChange = windowLevelStateDidChange
        overlayTransferFunctionState = transferFunctionState
        overlayTransferFunctionStateDidChange = transferFunctionStateDidChange
        rebuildOverlayTransferTextures()
        publishRegistrationPreparationUpdate(
            message: "Loading registration volumes",
            progress: 0.05
        )
        prepareBaseVolumeIfNeeded()
        requestOverlayVolumeTexture()
    }

    func clearOverlayPixList() {
        invalidateActiveRegistrationJob()
        registrationInProgress = false
        registrationProgress = 0
        registrationStatusMessage = nil
        overlayPixList = []
        contrastInvariantMRSlabMatchingCache = nil
        minimumCranialCoverageFractionCache = nil
        suggestedRegistrationWorldTransform = nil
        resetRegistrationSupportVolumes()
        overlaySourceTextureEntry = nil
        requestedOverlayVolumeKey = nil
        requestedOverlayPreparedVolumeKey = nil
        overlayVolumeTexture = nil
        overlayVolumeDimensions = SIMD3<Int>(repeating: 1)
        overlayVolumeLevels = []
        overlayUsesGantryTiltCorrectedVolume = false
        overlayDefaultSeriesWindowLevel = nil
        overlayCustomSeriesWindowLevel = nil
        usesAutomaticOverlayWindowLevel = false
        overlayWindowLevelStateDidChange = nil
        overlayTransferFunctionState = MetalViewerTransferFunctionState()
        overlayTransferFunctionStateDidChange = nil
        rebuildOverlayTransferTextures()
        overlayWindowLevel = 0
        overlayWindowWidth = 1
        overlayRegistrationWindowLevel = 0
        overlayRegistrationWindowWidth = 1
        overlayVolumeCenterWorld = .zero
        overlayInformativeCenterWorld = .zero
        overlayIsThinSlab = false
        overlaySlabGeometry = nil
        overlayTranslationWorld = .zero
        overlayRotationRadians = .zero
        overlayTranslationPixels = .zero
        stateDidChange?(stateDescription)
        registrationDidChange?(false, "", 0)
    }

    func stepSlice(by delta: Int) {
        guard pixList.isEmpty == false else { return }
        let nextIndex = max(0, min(pixList.count - 1, currentSliceIndex - delta))
        guard nextIndex != currentSliceIndex else { return }
        currentSliceIndex = nextIndex
        loadSlice(at: currentSliceIndex)
        if displayMode.isMPRLike {
            resetMPRPlaneToCurrentSlice()
        }
    }

    func setSliceIndex(_ index: Int) {
        guard pixList.isEmpty == false else { return }
        let nextIndex = max(0, min(pixList.count - 1, index))
        guard nextIndex != currentSliceIndex else {
            stateDidChange?(stateDescription)
            return
        }
        currentSliceIndex = nextIndex
        loadSlice(at: currentSliceIndex)
        if displayMode.isMPRLike {
            resetMPRPlaneToCurrentSlice()
        }
    }

    func makePrintFrame(at index: Int) -> MetalPrintFrame? {
        guard pixList.indices.contains(index) else { return nil }

        let previousSliceIndex = currentSliceIndex
        currentSliceIndex = index
        loadSlice(at: index)
        defer {
            if previousSliceIndex != currentSliceIndex {
                currentSliceIndex = previousSliceIndex
                loadSlice(at: previousSliceIndex)
            }
        }

        guard let currentPix,
              let displayVolumeTexture = stackDisplayVolumeTexture() else {
            return nil
        }
        let displayVolumeEntry = stackDisplayVolumeEntry()
        let displayVolumeKind = displayVolumeEntry?.textureKind ?? .rescaledFloat
        let floatDisplayVolumeTexture = displayVolumeKind == .rescaledFloat ? displayVolumeTexture : nil
        let signedDisplayVolumeTexture = displayVolumeKind == .storedInt16Signed ? displayVolumeTexture : nil
        let unsignedDisplayVolumeTexture = displayVolumeKind == .storedInt16Unsigned ? displayVolumeTexture : nil

        let sourceWidth = max(Int(currentPix.widthWithoutLoading()), 1)
        let sourceHeight = max(Int(currentPix.heightWithoutLoading()), 1)
        let maximumDimension = 4_096
        let reduction = max(
            CGFloat(sourceWidth) / CGFloat(maximumDimension),
            CGFloat(sourceHeight) / CGFloat(maximumDimension),
            1
        )
        let width = max(Int((CGFloat(sourceWidth) / reduction).rounded()), 1)
        let height = max(Int((CGFloat(sourceHeight) / reduction).rounded()), 1)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget, .shaderRead]

        guard let outputTexture = deviceRef.makeTexture(descriptor: textureDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        let drawableAspect = max(Float(width) / Float(max(height, 1)), 0.0001)
        let displayAspectRatio = max(imageAspectRatio, 0.0001)
        var scale = SIMD2<Float>(repeating: 1)
        if displayAspectRatio > drawableAspect {
            scale.y = drawableAspect / displayAspectRatio
        } else {
            scale.x = displayAspectRatio / drawableAspect
        }

        var uniforms = MetalUniforms(
            scale: scale,
            offset: .zero,
            rotationRadians: stackRotationRadians,
            drawableAspect: drawableAspect,
            baseWindowLevel: windowLevel,
            baseWindowWidth: max(windowWidth, 1),
            overlayWindowLevel: overlayWindowLevel,
            overlayWindowWidth: max(overlayWindowWidth, 1),
            overlayBlend: overlayBlend,
            overlayTranslationWorld: overlayTranslationWorld,
            movingRotationCenterWorld: movingRotationCenterWorld,
            fixedVolumeSize: stackDisplayVolumeDimensions(volumeTexture: displayVolumeTexture),
            currentSliceIndex: stackDisplaySliceIndex(),
            movingInverseRotation: inverseRotationMatrix(for: overlayRotationRadians),
            fixedVoxelToWorld: fixedVoxelToWorld,
            movingWorldToVoxel: movingWorldToVoxel,
            hasOverlay: overlayVolumeTexture == nil ? 0 : 1,
            imageInterpolationMode: UInt32(imageInterpolationMode.rawValue),
            baseHasCustomCLUT: baseHasCustomCLUT ? 1 : 0,
            overlayHasCustomCLUT: overlayHasCustomCLUT ? 1 : 0,
            baseVolumeTextureKind: displayVolumeKind.rawValue,
            baseVolumeRescaleSlope: displayVolumeEntry?.rescaleSlope ?? 1,
            baseVolumeRescaleIntercept: displayVolumeEntry?.rescaleIntercept ?? 0,
            baseVolumePadding: 0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
        encoder.setFragmentTexture(floatDisplayVolumeTexture, index: 2)
        setTransferTextures(on: encoder)
        encoder.setFragmentTexture(signedDisplayVolumeTexture, index: 7)
        encoder.setFragmentTexture(unsignedDisplayVolumeTexture, index: 8)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = width * 4
        var bgraPixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgraPixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            outputTexture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        return MetalPrintFrame(
            bgraPixels: Data(bgraPixels),
            width: width,
            height: height
        )
    }

    func setPixList(_ newPixList: [DCMPix], preservingSliceIndex: Bool = true) {
        guard newPixList.isEmpty == false else { return }

        let previousSliceIndex = currentSliceIndex
        invalidateActiveRegistrationJob()
        registrationInProgress = false
        registrationProgress = 0
        registrationStatusMessage = nil

        pixList = newPixList
        contrastInvariantMRSlabMatchingCache = nil
        minimumCranialCoverageFractionCache = nil
        suggestedRegistrationWorldTransform = nil
        resetRegistrationSupportVolumes()
        currentSliceIndex = preservingSliceIndex
            ? min(max(previousSliceIndex, 0), newPixList.count - 1)
            : Self.initialSliceIndex(for: newPixList)

        baseVolumeTexture = nil
        stackVolumeTextureEntry = nil
        immediateStackSliceTextureEntry = nil
        immediateStackSliceIndex = nil
        immediateStackSlicePixels = nil
        requestedStackVolumeKey = nil
        requestedBasePreparedVolumeKey = nil
        baseVolumeDimensions = SIMD3<Int>(repeating: 1)
        baseVolumeLevels = []
        fixedVoxelToWorld = matrix_identity_float4x4
        baseVolumeCenterWorld = .zero
        baseInformativeCenterWorld = .zero
        baseUsesGantryTiltCorrectedVolume = false
        baseIsThinSlab = false
        baseSlabGeometry = nil

        if overlayPixList.isEmpty == false {
            clearOverlayPixList()
        }

        loadSlice(at: currentSliceIndex)
        requestStackVolumeTexture()
        if displayMode.isMPRLike {
            prepareBaseVolumeIfNeeded()
            resetMPRPlaneToCurrentSlice()
        }
        stateDidChange?(stateDescription)
    }

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        hoveredMPRPlane = nil
        mprPlaneDragState = nil
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = nil
        if mode.isMPRLike {
            prepareBaseVolumeIfNeeded()
            resetMPRPlaneToCurrentSlice()
        }
        stateDidChange?(stateDescription)
    }

    func rotateMPR(from previousPoint: CGPoint, to currentPoint: CGPoint, in bounds: CGRect) {
        guard displayMode == .mpr else { return }
        let mainBounds = mprMainInteractionBounds(in: bounds)
        guard mainBounds.contains(previousPoint) || mainBounds.contains(currentPoint) else { return }
        let dx = Float(currentPoint.x - previousPoint.x)
        let dy = Float(currentPoint.y - previousPoint.y)
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return }

        let motionFactor: Float = 10
        let radiansPerDegree = Float.pi / 180
        let azimuth = dx * (20 / Float(max(mainBounds.width, 1))) * motionFactor * radiansPerDegree
        let elevation = dy * (20 / Float(max(mainBounds.height, 1))) * motionFactor * radiansPerDegree
        let azimuthRotation = simd_quatf(angle: azimuth, axis: SIMD3<Float>(0, 1, 0))
        let elevationRotation = simd_quatf(angle: elevation, axis: SIMD3<Float>(1, 0, 0))

        mprRotation = simd_normalize(elevationRotation * azimuthRotation * mprRotation)
        stateDidChange?(stateDescription)
    }

    func beginMPRPlaneDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode == .mpr else { return false }
        prepareBaseVolumeIfNeeded()
        guard let interaction = mprMainInteraction(at: point, in: bounds) else {
            mprPlaneDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }
        guard let hit = mprPlaneHit(at: point, in: bounds),
              mprHitIsInsidePlaneInterior(hit) else {
            mprPlaneDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        guard let screenDeltaPerVoxel = mprScreenDeltaPerVoxel(for: hit.plane, at: hit.baseVoxel, in: interaction.bounds),
              simd_length_squared(screenDeltaPerVoxel) > 0.0001 else {
            mprPlaneDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        mprPlaneDragState = MetalMPRPlaneDragState(
            plane: hit.plane,
            startPoint: SIMD2<Float>(Float(point.x), Float(point.y)),
            startPlaneVoxel: mprVoxelValue(for: hit.plane),
            screenDeltaPerVoxel: screenDeltaPerVoxel
        )
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = nil
        hoveredMPRPlane = hit.plane
        stateDidChange?(stateDescription)
        return true
    }

    func beginMPRPlaneTiltDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode == .mpr else { return false }
        prepareBaseVolumeIfNeeded()
        guard let interaction = mprMainInteraction(at: point, in: bounds) else {
            mprPlaneTiltDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }
        guard let hit = mprPlaneHit(at: point, in: bounds),
              mprHitIsInsidePlaneInterior(hit) == false,
              let componentIndex = mprTiltComponent(for: hit) else {
            mprPlaneTiltDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        setMPRTiltPivotValue(
            mprCurrentTiltPivotValue(for: hit.plane, componentIndex: componentIndex),
            for: hit.plane,
            componentIndex: componentIndex
        )
        guard let screenDeltaPerRadian = mprScreenDeltaPerRadian(
            for: hit.plane,
            componentIndex: componentIndex,
            at: hit.baseVoxel,
            in: interaction.bounds
        ),
              simd_length_squared(screenDeltaPerRadian) > 0.0001 else {
            mprPlaneTiltDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        mprPlaneTiltDragState = MetalMPRPlaneTiltDragState(
            plane: hit.plane,
            componentIndex: componentIndex,
            startPoint: SIMD2<Float>(Float(point.x), Float(point.y)),
            startAngle: mprTiltValue(for: hit.plane, componentIndex: componentIndex),
            screenDeltaPerRadian: screenDeltaPerRadian
        )
        mprPlaneDragState = nil
        mprPreviewLineDragContext = nil
        hoveredMPRPlane = hit.plane
        stateDidChange?(stateDescription)
        return true
    }

    func dragMPRPlane(to point: CGPoint) {
        guard let mprPlaneDragState else { return }
        let currentPoint = SIMD2<Float>(Float(point.x), Float(point.y))
        let mouseDelta = currentPoint - mprPlaneDragState.startPoint
        let screenDelta = mprPlaneDragState.screenDeltaPerVoxel
        let voxelDelta = simd_dot(mouseDelta, screenDelta) / max(simd_length_squared(screenDelta), 0.0001)
        setMPRVoxelValue(
            mprPlaneDragState.startPlaneVoxel + voxelDelta,
            for: mprPlaneDragState.plane
        )
        stateDidChange?(stateDescription)
    }

    func dragMPRPlaneTilt(to point: CGPoint) {
        guard let mprPlaneTiltDragState else { return }
        let currentPoint = SIMD2<Float>(Float(point.x), Float(point.y))
        let mouseDelta = currentPoint - mprPlaneTiltDragState.startPoint
        let screenDelta = mprPlaneTiltDragState.screenDeltaPerRadian
        let angleDelta = simd_dot(mouseDelta, screenDelta) / max(simd_length_squared(screenDelta), 0.0001)
        setMPRTiltValue(
            mprPlaneTiltDragState.startAngle + angleDelta,
            for: mprPlaneTiltDragState.plane,
            componentIndex: mprPlaneTiltDragState.componentIndex
        )
        stateDidChange?(stateDescription)
    }

    func endMPRPlaneDrag() {
        mprPlaneDragState = nil
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = nil
    }

    func mprPreviewLinePointer(at point: CGPoint, in bounds: CGRect) -> MetalMPRPreviewLinePointer? {
        guard displayMode.isMPRLike else { return nil }
        prepareBaseVolumeIfNeeded()
        guard let hit = mprPreviewLineHit(at: point, in: bounds) else {
            return nil
        }
        return MetalMPRPreviewLinePointer(
            interaction: hit.interaction,
            lineAngleRadians: hit.lineAngleRadians,
            actionAngleRadians: hit.actionAngleRadians
        )
    }

    func activeMPRPreviewLinePointer() -> MetalMPRPreviewLinePointer? {
        guard displayMode.isMPRLike,
              var context = mprPreviewLineDragContext else {
            return nil
        }
        prepareBaseVolumeIfNeeded()
        guard let pointer = mprPreviewLinePointer(
            displayedPlane: context.displayedPlane,
            referencePlane: context.referencePlane,
            interaction: context.interaction,
            componentIndex: context.componentIndex,
            baseVoxel: context.baseVoxel,
            paneRect: context.paneRect,
            lineFraction: context.lineFraction
        ) else {
            return nil
        }

        guard let actionLineAngleOffsetRadians = context.actionLineAngleOffsetRadians else {
            return pointer
        }

        let lineAngle = mprLineAngle(pointer.lineAngleRadians, closestTo: context.continuousLineAngleRadians)
        context.continuousLineAngleRadians = lineAngle
        mprPreviewLineDragContext = context
        let actionAngle = lineAngle + actionLineAngleOffsetRadians
        return MetalMPRPreviewLinePointer(
            interaction: pointer.interaction,
            lineAngleRadians: lineAngle,
            actionAngleRadians: pointer.interaction == .tilt ? actionAngle : nil
        )
    }

    func beginMPRPreviewPlaneMoveDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode.isMPRLike else { return false }
        prepareBaseVolumeIfNeeded()
        guard let hit = mprPreviewLineHit(at: point, in: bounds),
              hit.interaction == .move,
              let screenDeltaPerVoxel = mprPreviewScreenDeltaPerVoxel(
                for: hit.referencePlane,
                at: hit.baseVoxel,
                displayedIn: hit.displayedPlane,
                paneRect: hit.paneRect
              ),
              simd_length_squared(screenDeltaPerVoxel) > 0.0001 else {
            mprPlaneDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        mprPlaneDragState = MetalMPRPlaneDragState(
            plane: hit.referencePlane,
            startPoint: SIMD2<Float>(Float(point.x), Float(point.y)),
            startPlaneVoxel: mprVoxelValue(for: hit.referencePlane),
            screenDeltaPerVoxel: screenDeltaPerVoxel
        )
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = MetalMPRPreviewLineDragContext(
            displayedPlane: hit.displayedPlane,
            referencePlane: hit.referencePlane,
            interaction: hit.interaction,
            componentIndex: hit.componentIndex,
            baseVoxel: hit.baseVoxel,
            paneRect: hit.paneRect,
            lineFraction: hit.lineFraction,
            continuousLineAngleRadians: hit.lineAngleRadians,
            actionLineAngleOffsetRadians: mprPreviewActionLineAngleOffset(for: hit)
        )
        hoveredMPRPlane = hit.referencePlane
        stateDidChange?(stateDescription)
        return true
    }

    func beginMPRPreviewPlaneTiltDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode.isMPRLike else { return false }
        prepareBaseVolumeIfNeeded()
        guard let hit = mprPreviewLineHit(at: point, in: bounds),
              hit.interaction == .tilt,
              let componentIndex = hit.componentIndex else {
            mprPreviewLineDragContext = nil
            return false
        }

        setMPRTiltPivotValue(
            mprCurrentTiltPivotValue(for: hit.referencePlane, componentIndex: componentIndex),
            for: hit.referencePlane,
            componentIndex: componentIndex
        )
        guard let screenDeltaPerRadian = mprPreviewScreenDeltaPerRadian(
            for: hit.referencePlane,
            componentIndex: componentIndex,
            at: hit.baseVoxel,
            displayedIn: hit.displayedPlane,
            paneRect: hit.paneRect
        ),
              simd_length_squared(screenDeltaPerRadian) > 0.0001 else {
            mprPlaneTiltDragState = nil
            mprPreviewLineDragContext = nil
            return false
        }

        mprPlaneTiltDragState = MetalMPRPlaneTiltDragState(
            plane: hit.referencePlane,
            componentIndex: componentIndex,
            startPoint: SIMD2<Float>(Float(point.x), Float(point.y)),
            startAngle: mprTiltValue(for: hit.referencePlane, componentIndex: componentIndex),
            screenDeltaPerRadian: screenDeltaPerRadian
        )
        mprPlaneDragState = nil
        mprPreviewLineDragContext = MetalMPRPreviewLineDragContext(
            displayedPlane: hit.displayedPlane,
            referencePlane: hit.referencePlane,
            interaction: hit.interaction,
            componentIndex: componentIndex,
            baseVoxel: hit.baseVoxel,
            paneRect: hit.paneRect,
            lineFraction: hit.lineFraction,
            continuousLineAngleRadians: hit.lineAngleRadians,
            actionLineAngleOffsetRadians: mprPreviewActionLineAngleOffset(for: hit)
        )
        hoveredMPRPlane = hit.referencePlane
        stateDidChange?(stateDescription)
        return true
    }

    func beginMPRPreviewPlaneDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode.isMPRLike else { return false }
        prepareBaseVolumeIfNeeded()
        guard let hit = mprPreviewHit(at: point, in: bounds) else {
            return false
        }

        setMPRPlaneIntersection(hit.baseVoxel, in: hit.plane)
        mprPlaneDragState = nil
        mprPlaneTiltDragState = nil
        mprPreviewLineDragContext = nil
        hoveredMPRPlane = hit.plane
        stateDidChange?(stateDescription)
        return true
    }

    func dragMPRPreviewPlane(to point: CGPoint, in bounds: CGRect) {
        guard displayMode.isMPRLike else { return }
        prepareBaseVolumeIfNeeded()
        guard let hit = mprPreviewHit(at: point, in: bounds) else {
            return
        }

        setMPRPlaneIntersection(hit.baseVoxel, in: hit.plane)
        hoveredMPRPlane = hit.plane
        stateDidChange?(stateDescription)
    }

    func mprSlicePlaneAxis(at point: CGPoint, in bounds: CGRect) -> Int? {
        guard displayMode.isMPRLike else { return nil }
        prepareBaseVolumeIfNeeded()
        if displayMode == .mpr, let mainPlane = mprPlane(at: point, in: bounds) {
            return mainPlane.rawValue
        }
        return mprPreviewPane(at: point, in: bounds)?.plane.rawValue
    }

    func moveMPRPlane(axis: Int, by delta: Float) {
        guard displayMode.isMPRLike else { return }
        prepareBaseVolumeIfNeeded()
        switch axis {
        case 0:
            mprPlaneVoxel.x = min(max(mprPlaneVoxel.x + delta, 0), Float(max(baseVolumeDimensions.x - 1, 0)))
        case 1:
            mprPlaneVoxel.y = min(max(mprPlaneVoxel.y + delta, 0), Float(max(baseVolumeDimensions.y - 1, 0)))
        default:
            mprPlaneVoxel.z = min(max(mprPlaneVoxel.z + delta, 0), Float(max(baseVolumeDimensions.z - 1, 0)))
        }
        stateDidChange?(stateDescription)
    }

    func setMPRPreviewDividerLocation(_ dividerX: CGFloat, in bounds: CGRect) {
        guard displayMode == .mpr, bounds.width > 0 else { return }
        let gap = MetalMPRPreviewLayoutDefaults.gap
        let previewWidth = bounds.width - dividerX - gap
        setMPRPreviewWidthFraction(previewWidth / bounds.width)
    }

    private var mprPlanesInAnatomicalOrder: [MetalMPRPlane] {
        let permutations: [[MetalMPRPlane]] = [
            [.axial, .coronal, .sagittal],
            [.axial, .sagittal, .coronal],
            [.coronal, .axial, .sagittal],
            [.coronal, .sagittal, .axial],
            [.sagittal, .axial, .coronal],
            [.sagittal, .coronal, .axial],
        ]
        let anatomicalNormals = [
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(1, 0, 0),
        ]
        return permutations.max { lhs, rhs in
            let lhsScore = zip(lhs, anatomicalNormals).reduce(Float(0)) {
                $0 + abs(simd_dot(mprStoragePlaneNormalWorld(for: $1.0), $1.1))
            }
            let rhsScore = zip(rhs, anatomicalNormals).reduce(Float(0)) {
                $0 + abs(simd_dot(mprStoragePlaneNormalWorld(for: $1.0), $1.1))
            }
            return lhsScore < rhsScore
        } ?? Self.mprPlanes
    }

    private func mprStoragePlaneNormalWorld(for plane: MetalMPRPlane) -> SIMD3<Float> {
        let column: SIMD4<Float>
        switch plane {
        case .sagittal:
            column = fixedVoxelToWorld.columns.0
        case .coronal:
            column = fixedVoxelToWorld.columns.1
        case .axial:
            column = fixedVoxelToWorld.columns.2
        }
        let normal = SIMD3<Float>(column.x, column.y, column.z)
        return simd_length_squared(normal) > 0.000001
            ? simd_normalize(normal)
            : SIMD3<Float>(0, 0, 1)
    }

    private func mprAnatomicalScreenAxes(for plane: MetalMPRPlane) -> (
        right: SIMD3<Float>,
        up: SIMD3<Float>
    ) {
        switch mprPlanesInAnatomicalOrder.firstIndex(of: plane) ?? 0 {
        case 1:
            return (right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 0, 1))
        case 2:
            return (right: SIMD3<Float>(0, 1, 0), up: SIMD3<Float>(0, 0, 1))
        default:
            return (right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, -1, 0))
        }
    }

    private func mprPreviewOrientation(
        for plane: MetalMPRPlane,
        corners: [SIMD3<Float>]
    ) -> MetalMPRPreviewOrientation? {
        guard corners.count == 4 else { return nil }
        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let first = worldCorners[1] - worldCorners[0]
        let second = worldCorners[3] - worldCorners[0]
        guard simd_length_squared(first) > 0.000001,
              simd_length_squared(second) > 0.000001 else {
            return nil
        }
        let firstDirection = simd_normalize(first)
        let secondDirection = simd_normalize(second)
        let axes = mprAnatomicalScreenAxes(for: plane)
        let directScore = abs(simd_dot(firstDirection, axes.right))
            + abs(simd_dot(secondDirection, axes.up))
        let swappedScore = abs(simd_dot(secondDirection, axes.right))
            + abs(simd_dot(firstDirection, axes.up))
        let horizontalUsesFirstCoordinate = directScore >= swappedScore
        let horizontalDirection = horizontalUsesFirstCoordinate ? firstDirection : secondDirection
        let verticalDirection = horizontalUsesFirstCoordinate ? secondDirection : firstDirection
        return MetalMPRPreviewOrientation(
            horizontalUsesFirstCoordinate: horizontalUsesFirstCoordinate,
            horizontalIsForward: simd_dot(horizontalDirection, axes.right) >= 0,
            verticalIsForward: simd_dot(verticalDirection, axes.up) >= 0
        )
    }

    func mprPreviewOverlayLayout(in bounds: CGRect) -> MetalMPRPreviewOverlayLayout? {
        switch displayMode {
        case .mpr:
            guard let metrics = mprLayoutMetrics(totalWidth: bounds.width, totalHeight: bounds.height, unitScale: 1) else {
                return nil
            }

            let mainRect = CGRect(x: bounds.minX, y: bounds.minY, width: metrics.mainWidth, height: metrics.totalHeight)
            let dividerRect = CGRect(x: mainRect.maxX, y: bounds.minY, width: metrics.gap, height: metrics.totalHeight)
            let previewPanes = zip(mprPlanesInAnatomicalOrder, metrics.previewPaneRects).map { pair in
                let (plane, rect) = pair
                return mprOverlayPane(for: plane, rect: rect.offsetBy(dx: bounds.minX, dy: bounds.minY))
            }
            return MetalMPRPreviewOverlayLayout(
                mainRect: mainRect,
                dividerRect: dividerRect,
                previewPanes: previewPanes
            )
        case .mpr3D:
            guard let paneRects = mpr3DPaneRects(totalWidth: bounds.width, totalHeight: bounds.height, unitScale: 1) else {
                return nil
            }
            let previewPanes = zip(mprPlanesInAnatomicalOrder, paneRects).map { pair in
                let (plane, rect) = pair
                return mprOverlayPane(
                    for: plane,
                    rect: rect.offsetBy(dx: bounds.minX, dy: bounds.minY),
                    borderColor: mprAxisNSColor(for: plane)
                )
            }
            return MetalMPRPreviewOverlayLayout(
                mainRect: bounds,
                dividerRect: .zero,
                previewPanes: previewPanes
            )
        case .stack2D:
            return nil
        }
    }

    private func mprOverlayPane(
        for plane: MetalMPRPlane,
        rect: CGRect,
        borderColor: NSColor? = nil
    ) -> MetalMPRPreviewOverlayPane {
        let labels = mprOverlayLabels(for: plane)
        return MetalMPRPreviewOverlayPane(
            rect: rect,
            borderColor: borderColor,
            left: labels.left,
            right: labels.right,
            top: labels.top,
            bottom: labels.bottom
        )
    }

    private func mprOverlayLabels(
        for plane: MetalMPRPlane
    ) -> (left: String, right: String, top: String, bottom: String) {
        let corners = mprPlaneCorners(for: plane)
        guard let orientation = mprPreviewOrientation(for: plane, corners: corners) else {
            return (left: "", right: "", top: "", bottom: "")
        }
        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let firstDirection = simd_normalize(worldCorners[1] - worldCorners[0])
        let secondDirection = simd_normalize(worldCorners[3] - worldCorners[0])
        var rightDirection = orientation.horizontalUsesFirstCoordinate
            ? firstDirection
            : secondDirection
        var upDirection = orientation.horizontalUsesFirstCoordinate
            ? secondDirection
            : firstDirection
        if orientation.horizontalIsForward == false { rightDirection = -rightDirection }
        if orientation.verticalIsForward == false { upDirection = -upDirection }
        return (
            left: mprPatientOrientationText(for: -rightDirection),
            right: mprPatientOrientationText(for: rightDirection),
            top: mprPatientOrientationText(for: upDirection),
            bottom: mprPatientOrientationText(for: -upDirection)
        )
    }

    private func mprPatientOrientationText(for vector: SIMD3<Float>) -> String {
        guard simd_length_squared(vector) > 0.000001 else { return "" }
        let direction = simd_normalize(vector)
        return [
            (abs(direction.x), direction.x < 0 ? "R" : "L"),
            (abs(direction.y), direction.y < 0 ? "A" : "P"),
            (abs(direction.z), direction.z < 0 ? "I" : "S"),
        ]
            .filter { $0.0 > 0.2 }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }
            .joined()
    }

    private func mprAxisColor(for plane: MetalMPRPlane, alpha: Float? = nil) -> SIMD4<Float> {
        let defaults = UserDefaults.standard
        let rawColors = (1...3).map { index -> SIMD4<Float> in
            let prefix = "MPR_AXIS_\(index)"
            return SIMD4<Float>(
                defaults.float(forKey: "\(prefix)_RED"),
                defaults.float(forKey: "\(prefix)_GREEN"),
                defaults.float(forKey: "\(prefix)_BLUE"),
                defaults.float(forKey: "\(prefix)_ALPHA")
            )
        }
        let allUnset = rawColors.allSatisfy { color in
            color.x == 0 && color.y == 0 && color.z == 0 && color.w == 0
        }
        let colors = allUnset ? mprDefaultAxisColors() : rawColors
        let anatomicalIndex = mprPlanesInAnatomicalOrder.firstIndex(of: plane)
            ?? Self.mprPlanes.firstIndex(of: plane)
            ?? 0
        let color = colors[min(max(anatomicalIndex, 0), colors.count - 1)]
        return mprBrightReferenceColor(color, alpha: alpha)
    }

    private func mprBrightReferenceColor(_ color: SIMD4<Float>, alpha: Float? = nil) -> SIMD4<Float> {
        let brightnessBoost: Float = 1.45
        return SIMD4<Float>(
            min(color.x * brightnessBoost, 1),
            min(color.y * brightnessBoost, 1),
            min(color.z * brightnessBoost, 1),
            alpha ?? 1
        )
    }

    private func mprDefaultAxisColors() -> [SIMD4<Float>] {
        [
            SIMD4<Float>(1.0, 0.92, 0.0, 1.0),
            SIMD4<Float>(0.9, 0.0, 1.0, 1.0),
            SIMD4<Float>(0.0, 0.82, 1.0, 1.0),
        ]
    }

    private func mprAxisNSColor(for plane: MetalMPRPlane) -> NSColor {
        let color = mprAxisColor(for: plane)
        return NSColor(
            srgbRed: CGFloat(color.x),
            green: CGFloat(color.y),
            blue: CGFloat(color.z),
            alpha: CGFloat(color.w)
        )
    }

    func orientationOverlayState(in bounds: CGRect) -> MetalOrientationOverlayState? {
        guard displayMode == .mpr else { return nil }
        let normalizedRotation = simd_normalize(mprRotation)
        let rotationVector = normalizedRotation.vector
        let inverseRotation = simd_quatf(
            ix: -rotationVector.x,
            iy: -rotationVector.y,
            iz: -rotationVector.z,
            r: rotationVector.w
        )
        let contentRect = mprPreviewOverlayLayout(in: bounds)?.mainRect ?? bounds
        return MetalOrientationOverlayState(
            screenRightPatientVector: simd_act(inverseRotation, SIMD3<Float>(-1, 0, 0)),
            screenUpPatientVector: simd_act(inverseRotation, SIMD3<Float>(0, 1, 0)),
            screenForwardPatientVector: simd_act(inverseRotation, SIMD3<Float>(0, 0, 1)),
            contentRect: contentRect
        )
    }

    private func setMPRPreviewWidthFraction(_ fraction: CGFloat) {
        let clampedFraction = min(
            max(fraction, MetalMPRPreviewLayoutDefaults.minimumWidthFraction),
            MetalMPRPreviewLayoutDefaults.maximumWidthFraction
        )
        guard abs(clampedFraction - mprPreviewWidthFraction) > 0.0001 else { return }
        mprPreviewWidthFraction = clampedFraction
        UserDefaults.standard.set(Double(clampedFraction), forKey: MetalMPRPreviewLayoutDefaults.widthFractionDefaultsKey)
        stateDidChange?(stateDescription)
    }

    func updateMPRHover(at point: CGPoint?, in bounds: CGRect) {
        guard mprPlaneDragState == nil, mprPlaneTiltDragState == nil else { return }
        guard displayMode.isMPRLike, let point else {
            if hoveredMPRPlane != nil {
                hoveredMPRPlane = nil
                stateDidChange?(stateDescription)
            }
            return
        }

        prepareBaseVolumeIfNeeded()
        let mainPlane = displayMode == .mpr ? mprPlane(at: point, in: bounds) : nil
        let nextPlane = mainPlane ?? mprPreviewHit(at: point, in: bounds)?.plane
        guard hoveredMPRPlane != nextPlane else { return }
        hoveredMPRPlane = nextPlane
        stateDidChange?(stateDescription)
    }

    func updateWindowLevel(wl: Float, ww: Float) {
        let window = MetalViewerWindowLevel(level: wl, width: max(1, ww))
        switch activeWindowLevelTarget {
        case .base:
            applyBaseWindowLevel(window)
            customSeriesWindowLevel = window
            notifyWindowLevelStateDidChange()
        case .overlay:
            applyOverlayWindowLevel(window)
            overlayCustomSeriesWindowLevel = window
            notifyOverlayWindowLevelStateDidChange()
        }
        stateDidChange?(stateDescription)
    }

    func applyWindowLevel(_ window: MetalViewerWindowLevel, asCustom: Bool) {
        switch activeWindowLevelTarget {
        case .base:
            applyBaseWindowLevel(window)
            if asCustom {
                customSeriesWindowLevel = window
            } else {
                defaultSeriesWindowLevel = window
                customSeriesWindowLevel = nil
            }
            notifyWindowLevelStateDidChange()
        case .overlay:
            applyOverlayWindowLevel(window)
            if asCustom {
                overlayCustomSeriesWindowLevel = window
            } else {
                overlayDefaultSeriesWindowLevel = window
                overlayCustomSeriesWindowLevel = nil
            }
            notifyOverlayWindowLevelStateDidChange()
        }
        stateDidChange?(stateDescription)
    }

    func applyDefaultWindowLevelPreset() {
        guard let pix = activeWindowLevelPix else { return }
        applyWindowLevel(windowLevelDefaults(for: pix), asCustom: false)
    }

    func applyFullDynamicWindowLevelPreset() {
        guard let pix = activeWindowLevelPix else { return }
        let compactWindow: MetalViewerWindowLevel?
        switch activeWindowLevelTarget {
        case .base:
            compactWindow = stackVolumeTextureEntry?.fullDynamicWindow
        case .overlay:
            compactWindow = overlaySourceTextureEntry?.fullDynamicWindow
        }
        let window = compactWindow
            ?? MetalStoredInt16PixelData(pix: pix)?.storedRangeWindow
            ?? MetalViewerWindowLevel(level: 0, width: 1)
        applyWindowLevel(window, asCustom: false)
    }

    func applyAutomaticWindowLevelPreset() {
        guard let pix = activeWindowLevelPix else { return }
        let window = MetalViewerAutomaticWindowLevel.window(for: pix) ?? windowLevelDefaults(for: pix)
        applyWindowLevel(window, asCustom: false)
    }

    func commitWindowLevel() {
        stateDidChange?(stateDescription)
    }

    func applyCLUT(named presetName: String) {
        switch activeWindowLevelTarget {
        case .base:
            baseTransferFunctionState.clutName = presetName
            rebuildBaseTransferTextures()
            transferFunctionStateDidChange?(baseTransferFunctionState)
        case .overlay:
            overlayTransferFunctionState.clutName = presetName
            rebuildOverlayTransferTextures()
            overlayTransferFunctionStateDidChange?(overlayTransferFunctionState)
        }
        stateDidChange?(stateDescription)
    }

    func applyOpacity(named presetName: String) {
        switch activeWindowLevelTarget {
        case .base:
            baseTransferFunctionState.opacityName = presetName
            rebuildBaseTransferTextures()
            transferFunctionStateDidChange?(baseTransferFunctionState)
        case .overlay:
            overlayTransferFunctionState.opacityName = presetName
            rebuildOverlayTransferTextures()
            overlayTransferFunctionStateDidChange?(overlayTransferFunctionState)
        }
        stateDidChange?(stateDescription)
    }

    func resetWindowLevel() {
        switch activeWindowLevelTarget {
        case .base:
            guard pixList.indices.contains(currentSliceIndex) else { return }
            customSeriesWindowLevel = nil
            let defaultWindow = defaultSeriesWindowLevel ?? windowLevelDefaults(for: pixList[currentSliceIndex])
            defaultSeriesWindowLevel = defaultWindow
            applyBaseWindowLevel(defaultWindow)
            notifyWindowLevelStateDidChange()
        case .overlay:
            guard let overlayPix = currentOverlayPix else { return }
            overlayCustomSeriesWindowLevel = nil
            let defaultWindow = overlayDefaultSeriesWindowLevel ?? windowLevelDefaults(for: overlayPix)
            overlayDefaultSeriesWindowLevel = defaultWindow
            applyOverlayWindowLevel(defaultWindow)
            notifyOverlayWindowLevelStateDidChange()
        }
        stateDidChange?(stateDescription)
    }

    func zoom(by factor: Float) {
        setZoomScale(zoomScale * factor)
    }

    func setZoomScale(_ scale: Float) {
        guard scale.isFinite else { return }
        let clampedScale = min(max(scale, 0.1), 32.0)
        guard abs(zoomScale - clampedScale) > Float.ulpOfOne else { return }
        zoomScale = clampedScale
        stateDidChange?(stateDescription)
    }

    func setPanOffset(_ value: SIMD2<Float>) {
        panOffset = value
        stateDidChange?(stateDescription)
    }

    func panOffset(forMPRPlaneAxis axis: Int?) -> SIMD2<Float> {
        guard displayMode == .mpr3D else {
            return panOffset
        }
        guard let axis,
              let plane = MetalMPRPlane(rawValue: axis) else {
            return .zero
        }
        return mpr3DPanOffsets[plane] ?? .zero
    }

    func setPanOffset(_ value: SIMD2<Float>, forMPRPlaneAxis axis: Int?) {
        guard displayMode == .mpr3D else {
            setPanOffset(value)
            return
        }
        guard let axis,
              let plane = MetalMPRPlane(rawValue: axis) else {
            return
        }
        mpr3DPanOffsets[plane] = value
        stateDidChange?(stateDescription)
    }

    func rotateStack(from previousPoint: CGPoint, to currentPoint: CGPoint, in bounds: CGRect) {
        guard displayMode == .stack2D else { return }
        let rect = imageRect(in: bounds)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let previousVector = CGVector(dx: previousPoint.x - center.x, dy: previousPoint.y - center.y)
        let currentVector = CGVector(dx: currentPoint.x - center.x, dy: currentPoint.y - center.y)
        let minimumRadius: CGFloat = 8
        guard hypot(previousVector.dx, previousVector.dy) > minimumRadius,
              hypot(currentVector.dx, currentVector.dy) > minimumRadius else {
            return
        }

        let previousAngle = atan2(previousVector.dy, previousVector.dx)
        let currentAngle = atan2(currentVector.dy, currentVector.dx)
        stackRotationRadians = normalizedStackRotation(stackRotationRadians + Float(currentAngle - previousAngle))
        stateDidChange?(stateDescription)
    }

    func rerunRegistration(usingReferenceSampling: Bool = false) {
        let samplingMode: RegistrationSamplingMode = usingReferenceSampling ? .reference : .fast
        runRegistration(
            startingAt: RigidTransformState(
                translationWorld: overlayTranslationWorld,
                rotationRadians: overlayRotationRadians
            ),
            samplingMode: samplingMode,
            searchMode: .refinement
        )
    }

    func setOverlayBlend(_ value: Float) {
        overlayBlend = min(max(value, 0), 1)
        stateDidChange?(stateDescription)
    }

    func setTumourSeeds(_ seeds: [MetalViewerTumourSeed]) {
        guard tumourSeeds != seeds else { return }
        tumourSeeds = seeds
        stateDidChange?(stateDescription)
    }

    func imageRect(in bounds: CGRect) -> CGRect {
        let viewAspect = max(bounds.width / max(bounds.height, 1), 0.0001)
        let displayAspectRatio = stackDisplayAspectRatio()
        var imageWidth = bounds.width
        var imageHeight = bounds.height

        if CGFloat(displayAspectRatio) > viewAspect {
            imageHeight = imageWidth / CGFloat(displayAspectRatio)
        } else {
            imageWidth = imageHeight * CGFloat(displayAspectRatio)
        }

        imageWidth *= CGFloat(zoomScale)
        imageHeight *= CGFloat(zoomScale)

        return CGRect(
            x: bounds.midX - imageWidth * 0.5 + CGFloat(panOffset.x),
            y: bounds.midY - imageHeight * 0.5 + CGFloat(panOffset.y),
            width: imageWidth,
            height: imageHeight
        )
    }

    func normalizedImagePoint(for point: CGPoint, in bounds: CGRect) -> CGPoint? {
        let rect = imageRect(in: bounds)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let rotation = CGFloat(stackRotationRadians)
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let unrotatedPoint = CGPoint(
            x: center.x + translated.x * cosine + translated.y * sine,
            y: center.y - translated.x * sine + translated.y * cosine
        )

        guard rect.contains(unrotatedPoint), rect.width > 0, rect.height > 0 else {
            return nil
        }

        return CGPoint(
            x: (unrotatedPoint.x - rect.minX) / rect.width,
            y: (rect.maxY - unrotatedPoint.y) / rect.height
        )
    }

    private func rotatedStackPoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        let rotation = CGFloat(stackRotationRadians)
        guard abs(rotation) > 0.000001 else {
            return point
        }

        let center = CGPoint(x: imageRect.midX, y: imageRect.midY)
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return CGPoint(
            x: center.x + translated.x * cosine - translated.y * sine,
            y: center.y + translated.x * sine + translated.y * cosine
        )
    }

    func tumourSeedPlacement(at point: CGPoint, in bounds: CGRect) -> MetalViewerTumourSeedPlacement? {
        switch displayMode {
        case .stack2D:
            return stackTumourSeedPlacement(at: point, in: bounds)
        case .mpr, .mpr3D:
            return mprTumourSeedPlacement(at: point, in: bounds)
        }
    }

    func tumourSeedIdentifier(at point: CGPoint, in bounds: CGRect) -> String? {
        switch displayMode {
        case .stack2D:
            return stackTumourSeedIdentifier(at: point, in: bounds)
        case .mpr:
            return mprPreviewTumourSeedIdentifier(at: point, in: bounds)
                ?? mprMainTumourSeedIdentifier(at: point, in: bounds)
        case .mpr3D:
            return mprPreviewTumourSeedIdentifier(at: point, in: bounds)
        }
    }

    func measurementPoint(at point: CGPoint, in bounds: CGRect) -> MetalViewerMeasurementPoint? {
        switch displayMode {
        case .stack2D:
            return stackMeasurementPoint(at: point, in: bounds)
        case .mpr, .mpr3D:
            return mprMeasurementPoint(at: point, in: bounds)
        }
    }

    func screenPoint(for measurementPoint: MetalViewerMeasurementPoint, in bounds: CGRect) -> CGPoint? {
        switch measurementPoint.displaySpace {
        case let .stack2D(sliceIndex, pixelPoint):
            guard displayMode == .stack2D,
                  sliceIndex == currentSliceIndex,
                  let pix = currentPix,
                  pix.pwidth > 0,
                  pix.pheight > 0 else {
                return nil
            }

            let rect = imageRect(in: bounds)
            let unrotatedPoint = CGPoint(
                x: rect.minX + (pixelPoint.x / CGFloat(pix.pwidth)) * rect.width,
                y: rect.maxY - (pixelPoint.y / CGFloat(pix.pheight)) * rect.height
            )
            return rotatedStackPoint(unrotatedPoint, in: rect)
        case let .mprPreview(planeRawValue, baseVoxel):
            guard displayMode.isMPRLike,
                  let plane = MetalMPRPlane(rawValue: planeRawValue),
                  let rect = mprPreviewRect(for: plane, in: bounds) else {
                return nil
            }

            let viewport = mprPreviewViewport(for: rect)
            guard let position = planarMPRPreviewPosition(for: baseVoxel, plane: plane, viewport: viewport) else {
                return nil
            }
            let screenPoint = mprPreviewScreenPoint(for: position, in: rect)
            guard screenPoint.x.isFinite,
                  screenPoint.y.isFinite else {
                return nil
            }
            return CGPoint(x: CGFloat(screenPoint.x), y: CGFloat(screenPoint.y))
        }
    }

    private func stackTumourSeedPlacement(at point: CGPoint, in bounds: CGRect) -> MetalViewerTumourSeedPlacement? {
        guard let pix = currentPix,
              let sliceGeometry = MetalViewerSliceGeometry(pix: pix),
              let normalizedImagePoint = normalizedImagePoint(for: point, in: bounds),
              pix.pwidth > 0,
              pix.pheight > 0 else {
            return nil
        }

        let pixelX = max(0, min(CGFloat(pix.pwidth - 1), normalizedImagePoint.x * CGFloat(pix.pwidth)))
        let pixelY = max(0, min(CGFloat(pix.pheight - 1), normalizedImagePoint.y * CGFloat(pix.pheight)))
        let dicomPoint = sliceGeometry.dicomPoint(
            pixelX: Double(pixelX),
            pixelY: Double(pixelY)
        )
        return MetalViewerTumourSeedPlacement(
            sliceIndex: currentSliceIndex,
            pixelPoint: CGPoint(x: pixelX, y: pixelY),
            dicomPoint: dicomPoint
        )
    }

    private func stackTumourSeedIdentifier(at point: CGPoint, in bounds: CGRect) -> String? {
        guard tumourSeeds.isEmpty == false,
              let pix = currentPix,
              let sliceGeometry = MetalViewerSliceGeometry(pix: pix) else {
            return nil
        }

        let rect = imageRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        var bestIdentifier: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for seed in tumourSeeds {
            let radiusMM = max(seed.diameterMM * 0.5, 0.05)
            let distanceFromSlice = simd_dot(seed.dicomPoint - sliceGeometry.origin, sliceGeometry.normal)
            guard abs(distanceFromSlice) <= radiusMM else {
                continue
            }

            let crossSectionRadiusMM = sqrt(max(radiusMM * radiusMM - distanceFromSlice * distanceFromSlice, 0))
            let slicePoint = sliceGeometry.slicePoint(from: seed.dicomPoint)
            guard slicePoint.x.isFinite,
                  slicePoint.y.isFinite,
                  slicePoint.x >= -1,
                  slicePoint.y >= -1,
                  slicePoint.x <= CGFloat(sliceGeometry.width + 1),
                  slicePoint.y <= CGFloat(sliceGeometry.height + 1) else {
                continue
            }

            let unrotatedCenter = CGPoint(
                x: rect.minX + (slicePoint.x / CGFloat(sliceGeometry.width)) * rect.width,
                y: rect.maxY - (slicePoint.y / CGFloat(sliceGeometry.height)) * rect.height
            )
            let center = rotatedStackPoint(unrotatedCenter, in: rect)
            let radiusX = CGFloat(crossSectionRadiusMM / sliceGeometry.spacingX) * rect.width / max(CGFloat(sliceGeometry.width), 1)
            let radiusY = CGFloat(crossSectionRadiusMM / sliceGeometry.spacingY) * rect.height / max(CGFloat(sliceGeometry.height), 1)
            let hitRadius = max(radiusX, radiusY, 8)
            let distance = hypot(point.x - center.x, point.y - center.y)
            guard distance <= hitRadius,
                  distance < bestDistance else {
                continue
            }
            bestDistance = distance
            bestIdentifier = seed.identifier
        }
        return bestIdentifier
    }

    private func stackMeasurementPoint(at point: CGPoint, in bounds: CGRect) -> MetalViewerMeasurementPoint? {
        guard let pix = currentPix,
              let sliceGeometry = MetalViewerSliceGeometry(pix: pix),
              let normalizedImagePoint = normalizedImagePoint(for: point, in: bounds),
              pix.pwidth > 0,
              pix.pheight > 0 else {
            return nil
        }

        let pixelX = max(0, min(CGFloat(pix.pwidth - 1), normalizedImagePoint.x * CGFloat(pix.pwidth)))
        let pixelY = max(0, min(CGFloat(pix.pheight - 1), normalizedImagePoint.y * CGFloat(pix.pheight)))
        let dicomPoint = sliceGeometry.dicomPoint(
            pixelX: Double(pixelX),
            pixelY: Double(pixelY)
        )
        return MetalViewerMeasurementPoint(
            displaySpace: .stack2D(sliceIndex: currentSliceIndex, pixelPoint: CGPoint(x: pixelX, y: pixelY)),
            dicomPoint: dicomPoint
        )
    }

    private func mprTumourSeedPlacement(at point: CGPoint, in bounds: CGRect) -> MetalViewerTumourSeedPlacement? {
        prepareBaseVolumeIfNeeded()
        guard let firstPix = pixList.first,
              firstPix.pwidth > 0,
              firstPix.pheight > 0,
              pixList.isEmpty == false else {
            return nil
        }

        let baseVoxel: SIMD3<Float>
        if displayMode == .mpr3D {
            guard let previewBaseVoxel = mprPreviewBaseVoxel(at: point, in: bounds) else {
                return nil
            }
            baseVoxel = previewBaseVoxel
        } else if let hit = mprPlaneHit(at: point, in: bounds) {
            baseVoxel = hit.baseVoxel
        } else if let previewBaseVoxel = mprPreviewBaseVoxel(at: point, in: bounds) {
            baseVoxel = previewBaseVoxel
        } else {
            return nil
        }

        let worldPoint = mprDisplayWorldPosition(for: baseVoxel)
        let sourceWorldToVoxel = simd_inverse(MetalViewerGantryTiltGeometryBuilder.sourceVoxelToPatientMatrix(for: pixList))
        let sourceVoxel = sourceWorldToVoxel * SIMD4<Float>(worldPoint, 1)
        let sourceMaxX = Float(max(firstPix.pwidth - 1, 0))
        let sourceMaxY = Float(max(firstPix.pheight - 1, 0))
        let sourceMaxZ = Float(max(pixList.count - 1, 0))
        guard sourceVoxel.x >= -0.5,
              sourceVoxel.y >= -0.5,
              sourceVoxel.z >= -0.5,
              sourceVoxel.x <= sourceMaxX + 0.5,
              sourceVoxel.y <= sourceMaxY + 0.5,
              sourceVoxel.z <= sourceMaxZ + 0.5 else {
            return nil
        }

        let pixelX = CGFloat(min(max(sourceVoxel.x, 0), sourceMaxX))
        let pixelY = CGFloat(min(max(sourceVoxel.y, 0), sourceMaxY))
        let sliceIndex = Int(min(max(sourceVoxel.z.rounded(), 0), sourceMaxZ))
        return MetalViewerTumourSeedPlacement(
            sliceIndex: sliceIndex,
            pixelPoint: CGPoint(x: pixelX, y: pixelY),
            dicomPoint: SIMD3<Double>(Double(worldPoint.x), Double(worldPoint.y), Double(worldPoint.z))
        )
    }

    private func mprPreviewTumourSeedIdentifier(at point: CGPoint, in bounds: CGRect) -> String? {
        guard tumourSeeds.isEmpty == false,
              let previewPane = mprPreviewPane(at: point, in: bounds) else {
            return nil
        }

        prepareBaseVolumeIfNeeded()
        return mprTumourSeedIdentifier(
            at: point,
            inPreviewPlane: previewPane.plane,
            paneRect: previewPane.rect
        )
    }

    private func mprMainTumourSeedIdentifier(at point: CGPoint, in bounds: CGRect) -> String? {
        guard tumourSeeds.isEmpty == false,
              let interaction = mprMainInteraction(at: point, in: bounds) else {
            return nil
        }

        prepareBaseVolumeIfNeeded()
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(interaction.bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(interaction.bounds.height, 1)) * 2.0)
        )
        let viewProjectionMatrix = mprViewProjectionMatrix(offset: offset, viewportSize: interaction.bounds.size)
        let worldToBaseVoxel = simd_inverse(fixedVoxelToWorld)
        let hitPoint = SIMD2<Float>(Float(interaction.point.x), Float(interaction.point.y))
        var bestIdentifier: String?
        var bestDistance = Float.greatestFiniteMagnitude

        for seed in tumourSeeds {
            let centerWorld = SIMD3<Float>(Float(seed.dicomX), Float(seed.dicomY), Float(seed.dicomZ))
            let centerVoxel = mprBaseVoxel(forWorld: centerWorld, worldToBaseVoxel: worldToBaseVoxel)
            guard let projectedCenter = mprProjectedPoint(
                for: centerVoxel,
                viewProjectionMatrix: viewProjectionMatrix,
                bounds: interaction.bounds
            ) else {
                continue
            }

            let distance = simd_distance(
                SIMD2<Float>(projectedCenter.x, projectedCenter.y),
                hitPoint
            )
            guard distance <= 10,
                  distance < bestDistance else {
                continue
            }
            bestDistance = distance
            bestIdentifier = seed.identifier
        }
        return bestIdentifier
    }

    private func mprMeasurementPoint(at point: CGPoint, in bounds: CGRect) -> MetalViewerMeasurementPoint? {
        prepareBaseVolumeIfNeeded()

        guard let previewHit = mprPreviewHit(at: point, in: bounds) else {
            return nil
        }

        let worldPoint = mprDisplayWorldPosition(for: previewHit.baseVoxel)
        return MetalViewerMeasurementPoint(
            displaySpace: .mprPreview(planeRawValue: previewHit.plane.rawValue, baseVoxel: previewHit.baseVoxel),
            dicomPoint: SIMD3<Double>(Double(worldPoint.x), Double(worldPoint.y), Double(worldPoint.z))
        )
    }

    private func mprPreviewBaseVoxel(at point: CGPoint, in bounds: CGRect) -> SIMD3<Float>? {
        mprPreviewHit(at: point, in: bounds)?.baseVoxel
    }

    private func mprPreviewViewport(for rect: CGRect) -> MTLViewport {
        MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(max(rect.width, 1)),
            height: Double(max(rect.height, 1)),
            znear: 0,
            zfar: 1
        )
    }

    private func mprPreviewInteractionRect(for rect: CGRect, in bounds: CGRect) -> CGRect {
        guard displayMode == .mpr3D,
              bounds.height > bounds.width else {
            return rect
        }

        return CGRect(
            x: rect.minX,
            y: bounds.minY + bounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func mprPreviewPane(at point: CGPoint, in bounds: CGRect) -> (plane: MetalMPRPlane, rect: CGRect)? {
        guard let layout = mprPreviewOverlayLayout(in: bounds) else {
            return nil
        }

        let planes = mprPlanesInAnatomicalOrder
        for (index, pane) in layout.previewPanes.enumerated() where index < planes.count {
            let rect = mprPreviewInteractionRect(for: pane.rect, in: bounds)
            if rect.contains(point) {
                return (planes[index], rect)
            }
        }

        return nil
    }

    private func mprPreviewRect(for plane: MetalMPRPlane, in bounds: CGRect) -> CGRect? {
        guard let layout = mprPreviewOverlayLayout(in: bounds) else {
            return nil
        }

        let planes = mprPlanesInAnatomicalOrder
        for (index, pane) in layout.previewPanes.enumerated() where index < planes.count {
            if planes[index] == plane {
                return mprPreviewInteractionRect(for: pane.rect, in: bounds)
            }
        }

        return nil
    }

    private func mprPreviewHit(at point: CGPoint, in bounds: CGRect) -> MetalMPRPreviewHit? {
        guard let previewPane = mprPreviewPane(at: point, in: bounds) else {
            return nil
        }

        let rect = previewPane.rect
        let plane = previewPane.plane
        let viewport = mprPreviewViewport(for: rect)
        guard let geometry = planarMPRPreviewGeometry(for: plane, viewport: viewport),
              geometry.halfWidth > 0.0001,
              geometry.halfHeight > 0.0001 else {
            return nil
        }

        let localX = Float((point.x - rect.minX) / max(rect.width, 1))
        let localY = Float((point.y - rect.minY) / max(rect.height, 1))
        let positionX = localX * 2 - 1 - geometry.panOffset.x
        let positionY = localY * 2 - 1 - geometry.panOffset.y
        guard positionX >= -geometry.halfWidth,
              positionX <= geometry.halfWidth,
              positionY >= -geometry.halfHeight,
              positionY <= geometry.halfHeight else {
            return nil
        }

        let screenFractions = SIMD2<Float>(
            (positionX + geometry.halfWidth) / (geometry.halfWidth * 2),
            (positionY + geometry.halfHeight) / (geometry.halfHeight * 2)
        )
        let planeFractions = geometry.orientation.planeFractions(
            horizontal: screenFractions.x,
            vertical: screenFractions.y
        )

        let cornerLocals = geometry.corners.map { mprPlaneLocalCoordinates(for: plane, baseVoxel: $0) }
        let minU = cornerLocals.map { $0.x }.min() ?? 0
        let maxU = cornerLocals.map { $0.x }.max() ?? 1
        let minV = cornerLocals.map { $0.y }.min() ?? 0
        let maxV = cornerLocals.map { $0.y }.max() ?? 1
        guard maxU - minU > 0.0001,
              maxV - minV > 0.0001 else {
            return nil
        }
        let first = minU + planeFractions.x * (maxU - minU)
        let second = minV + planeFractions.y * (maxV - minV)
        return MetalMPRPreviewHit(
            plane: plane,
            baseVoxel: mprPlaneVoxel(for: plane, first: first, second: second)
        )
    }

    private func mprPreviewLineHit(at point: CGPoint, in bounds: CGRect) -> MetalMPRPreviewLineHit? {
        guard let previewPane = mprPreviewPane(at: point, in: bounds) else {
            return nil
        }

        let rect = previewPane.rect
        let displayedPlane = previewPane.plane
        let viewport = mprPreviewViewport(for: rect)
        let displayedCorners = mprPlaneCorners(for: displayedPlane)
        guard displayedCorners.count == 4 else {
            return nil
        }

        let pointVector = SIMD2<Float>(Float(point.x), Float(point.y))
        let hitTolerance: Float = 8
        var bestHit: MetalMPRPreviewLineHit?
        var bestDistance = Float.greatestFiniteMagnitude

        for referencePlane in Self.mprPlanes where referencePlane != displayedPlane {
            guard let segment = mprIntersectionSegment(
                    firstCorners: displayedCorners,
                    secondCorners: mprPlaneCorners(for: referencePlane)
                  ),
                  let startPosition = planarMPRPreviewPosition(for: segment.0, plane: displayedPlane, viewport: viewport),
                  let endPosition = planarMPRPreviewPosition(for: segment.1, plane: displayedPlane, viewport: viewport) else {
                continue
            }

            let startPoint = mprPreviewScreenPoint(for: startPosition, in: rect)
            let endPoint = mprPreviewScreenPoint(for: endPosition, in: rect)
            let distance = mprDistanceFromPoint(pointVector, toSegmentFrom: startPoint, to: endPoint)
            guard distance.value <= hitTolerance, distance.value < bestDistance else {
                continue
            }

            let interaction = mprPreviewLineInteraction(forFraction: distance.fraction)
            let baseVoxel = segment.0 + (segment.1 - segment.0) * distance.fraction
            let lineDelta = endPoint - startPoint
            let componentIndex = interaction == .tilt ? mprPreviewTiltComponent(
                for: referencePlane,
                displayedIn: displayedPlane
            ) : nil
            let actionAngleRadians = interaction == .tilt && componentIndex != nil
                ? mprPreviewTiltActionAngle(lineDelta: lineDelta, lineFraction: distance.fraction)
                : nil
            bestDistance = distance.value
            bestHit = MetalMPRPreviewLineHit(
                displayedPlane: displayedPlane,
                referencePlane: referencePlane,
                interaction: interaction,
                componentIndex: componentIndex,
                baseVoxel: baseVoxel,
                paneRect: rect,
                lineFraction: distance.fraction,
                lineAngleRadians: CGFloat(atan2(lineDelta.y, lineDelta.x)),
                actionAngleRadians: actionAngleRadians
            )
        }

        return bestHit
    }

    private func mprPreviewLinePointer(
        displayedPlane: MetalMPRPlane,
        referencePlane: MetalMPRPlane,
        interaction: MetalMPRPreviewLineInteraction,
        componentIndex: Int?,
        baseVoxel: SIMD3<Float>,
        paneRect: CGRect,
        lineFraction: Float
    ) -> MetalMPRPreviewLinePointer? {
        let viewport = mprPreviewViewport(for: paneRect)
        let displayedCorners = mprPlaneCorners(for: displayedPlane)
        guard displayedCorners.count == 4,
              let segment = mprIntersectionSegment(
                firstCorners: displayedCorners,
                secondCorners: mprPlaneCorners(for: referencePlane)
              ),
              let startPosition = planarMPRPreviewPosition(for: segment.0, plane: displayedPlane, viewport: viewport),
              let endPosition = planarMPRPreviewPosition(for: segment.1, plane: displayedPlane, viewport: viewport) else {
            return nil
        }

        let startPoint = mprPreviewScreenPoint(for: startPosition, in: paneRect)
        let endPoint = mprPreviewScreenPoint(for: endPosition, in: paneRect)
        let lineDelta = endPoint - startPoint
        guard simd_length_squared(lineDelta) > 0.0001 else {
            return nil
        }

        let actionAngleRadians = interaction == .tilt && componentIndex != nil
            ? mprPreviewTiltActionAngle(lineDelta: lineDelta, lineFraction: lineFraction)
            : nil

        return MetalMPRPreviewLinePointer(
            interaction: interaction,
            lineAngleRadians: CGFloat(atan2(lineDelta.y, lineDelta.x)),
            actionAngleRadians: actionAngleRadians
        )
    }

    private func mprPreviewLineInteraction(forFraction fraction: Float) -> MetalMPRPreviewLineInteraction {
        fraction >= (1.0 / 3.0) && fraction <= (2.0 / 3.0) ? .move : .tilt
    }

    private func mprPreviewActionLineAngleOffset(for hit: MetalMPRPreviewLineHit) -> CGFloat? {
        let actionAngle: CGFloat?
        switch hit.interaction {
        case .move:
            actionAngle = hit.lineAngleRadians + CGFloat.pi * 0.5
        case .tilt:
            actionAngle = hit.actionAngleRadians
        }
        guard let actionAngle else {
            return nil
        }
        return mprNormalizedSignedAngle(actionAngle - hit.lineAngleRadians)
    }

    private func mprNormalizedSignedAngle(_ angle: CGFloat) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        var normalized = (angle + CGFloat.pi).truncatingRemainder(dividingBy: fullTurn)
        if normalized < 0 {
            normalized += fullTurn
        }
        return normalized - CGFloat.pi
    }

    private func mprLineAngle(_ angle: CGFloat, closestTo reference: CGFloat) -> CGFloat {
        angle + ((reference - angle) / CGFloat.pi).rounded() * CGFloat.pi
    }

    private func mprPreviewTiltActionAngle(lineDelta: SIMD2<Float>, lineFraction: Float) -> CGFloat? {
        let lineLength = simd_length(lineDelta)
        guard lineLength > 0.0001 else {
            return nil
        }

        let radiusDirection = (lineFraction < 0.5 ? lineDelta : -lineDelta) / lineLength
        return CGFloat(atan2(radiusDirection.y, radiusDirection.x))
    }

    private func mprPreviewTiltComponent(
        for referencePlane: MetalMPRPlane,
        displayedIn displayedPlane: MetalMPRPlane
    ) -> Int? {
        let displayedAxes = Set(mprPreviewLocalAxisIndices(for: displayedPlane))
        let referenceAxes = mprPreviewLocalAxisIndices(for: referencePlane)
        for (index, axis) in referenceAxes.enumerated() where displayedAxes.contains(axis) {
            return index
        }
        return nil
    }

    private func mprPreviewLocalAxisIndices(for plane: MetalMPRPlane) -> [Int] {
        switch plane {
        case .axial:
            return [0, 1]
        case .coronal:
            return [0, 2]
        case .sagittal:
            return [1, 2]
        }
    }

    private func mprPreviewScreenPoint(for position: SIMD3<Float>, in rect: CGRect) -> SIMD2<Float> {
        SIMD2<Float>(
            Float(rect.minX) + (position.x * 0.5 + 0.5) * Float(rect.width),
            Float(rect.minY) + (position.y * 0.5 + 0.5) * Float(rect.height)
        )
    }

    private func mprDistanceFromPoint(
        _ point: SIMD2<Float>,
        toSegmentFrom start: SIMD2<Float>,
        to end: SIMD2<Float>
    ) -> (value: Float, fraction: Float) {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0.0001 else {
            return (simd_distance(point, start), 0)
        }
        let fraction = min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1)
        let closestPoint = start + segment * fraction
        return (simd_distance(point, closestPoint), fraction)
    }

    private func normalizedStackRotation(_ angle: Float) -> Float {
        let fullTurn = Float.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: fullTurn)
        if normalized > Float.pi {
            normalized -= fullTurn
        } else if normalized < -Float.pi {
            normalized += fullTurn
        }
        return normalized
    }

    private func loadSlice(at index: Int) {
        guard pixList.indices.contains(index) else { return }
        let pix = pixList[index]

        let width = max(Int(pix.widthWithoutLoading()), 1)
        let height = max(Int(pix.heightWithoutLoading()), 1)
        let sliceGeometry = MetalViewerSliceGeometry(pix: pix)
        let spacingX = Float(sliceGeometry?.spacingX ?? 1)
        let spacingY = Float(sliceGeometry?.spacingY ?? 1)
        imageAspectRatio = Float(width) * spacingX / max(Float(height) * spacingY, 0.0001)

        var storedPixels: MetalStoredInt16PixelData?
        if displayMode == .stack2D,
           stackDisplayUsesCorrectedBaseVolume() == false,
           stackDisplayUsesSharedVolumeTexture(for: pix, at: index) == false {
            if immediateStackSliceIndex != index
                || immediateStackSliceTextureEntry?.dimensions.x != width
                || immediateStackSliceTextureEntry?.dimensions.y != height {
                immediateStackSliceTextureEntry = nil
                immediateStackSliceIndex = nil
                immediateStackSlicePixels = nil

                storedPixels = MetalStoredInt16PixelData(pix: pix)
                if let storedPixels,
                   let entry = makeImmediateStackSliceTextureEntry(
                    from: storedPixels,
                    pix: pix,
                    index: index
                   ) {
                    immediateStackSliceTextureEntry = entry
                    immediateStackSliceIndex = index
                    immediateStackSlicePixels = storedPixels
                }
            }
        }

        if let customWindow = customSeriesWindowLevel {
            applyBaseWindowLevel(customWindow)
        } else if let defaultWindow = defaultSeriesWindowLevel {
            applyBaseWindowLevel(defaultWindow)
        } else {
            let defaultWindow = initialWindowLevelDefaults(
                for: pix,
                usesAutomaticWindowLevel: usesAutomaticBaseWindowLevel,
                storedPixels: storedPixels
            )
            defaultSeriesWindowLevel = defaultWindow
            applyBaseWindowLevel(defaultWindow)
            notifyWindowLevelStateDidChange()
        }

        if let overlayPix = currentOverlayPix {
            if let customWindow = overlayCustomSeriesWindowLevel {
                applyOverlayWindowLevel(customWindow)
            } else if let defaultWindow = overlayDefaultSeriesWindowLevel {
                applyOverlayWindowLevel(defaultWindow)
            } else {
                let defaultWindow = initialWindowLevelDefaults(
                    for: overlayPix,
                    usesAutomaticWindowLevel: usesAutomaticOverlayWindowLevel
                )
                overlayDefaultSeriesWindowLevel = defaultWindow
                applyOverlayWindowLevel(defaultWindow)
                notifyOverlayWindowLevelStateDidChange()
            }
            overlayTranslationPixels = currentOverlayTranslationPixels()
        } else {
            overlayWindowWidth = 1
            overlayWindowLevel = 0
            overlayTranslationPixels = .zero
        }

        stateDidChange?(stateDescription)
    }

    private func makeImmediateStackSliceTextureEntry(
        from storedPixels: MetalStoredInt16PixelData,
        pix: DCMPix,
        index: Int
    ) -> MetalSeriesTextureCache.Entry? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = storedPixels.pixelFormat
        descriptor.width = storedPixels.width
        descriptor.height = storedPixels.height
        descriptor.depth = 1
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = deviceRef.makeTexture(descriptor: descriptor),
              storedPixels.data.count >= storedPixels.byteCount else {
            return nil
        }

        var uploaded = false
        storedPixels.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(
                    0,
                    0,
                    0,
                    storedPixels.width,
                    storedPixels.height,
                    1
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: storedPixels.bytesPerRow,
                bytesPerImage: storedPixels.byteCount
            )
            uploaded = true
        }
        guard uploaded else { return nil }

        return MetalSeriesTextureCache.Entry(
            key: "immediate-stack-slice|\(ObjectIdentifier(pix))|\(index)",
            texture: texture,
            dimensions: SIMD3<Int>(storedPixels.width, storedPixels.height, 1),
            textureKind: storedPixels.textureKind,
            bytesPerVoxel: MemoryLayout<UInt16>.stride,
            rescaleSlope: storedPixels.rescaleSlope,
            rescaleIntercept: storedPixels.rescaleIntercept,
            defaultWindow: storedPixels.inferredWindow,
            fullDynamicWindow: storedPixels.storedRangeWindow
        )
    }

    private func resetMPRPlaneToCurrentSlice() {
        let width = Float(max(baseVolumeDimensions.x, Int(currentPix?.pwidth ?? 1)))
        let height = Float(max(baseVolumeDimensions.y, Int(currentPix?.pheight ?? 1)))
        let depth = Float(max(baseVolumeDimensions.z, pixList.count))
        mprPlaneVoxel = SIMD3<Float>(
            max(width - 1, 0) * 0.5,
            max(height - 1, 0) * 0.5,
            min(Float(currentSliceIndex), max(depth - 1, 0))
        )
        resetMPRTiltPivots()
    }

    private var hasOverlayImage: Bool {
        overlayPixList.isEmpty == false || overlayVolumeTexture != nil
    }

    private var activeWindowLevelTarget: MetalViewerWindowLevelTarget {
        hasOverlayImage && overlayBlend > 0.5 ? .overlay : .base
    }

    private var activeWindowLevelPix: DCMPix? {
        switch activeWindowLevelTarget {
        case .base:
            return currentPix
        case .overlay:
            return currentOverlayPix
        }
    }

    private func requestStackVolumeTexture() {
        guard let key = MetalSeriesTextureCache.shared.key(
                  for: pixList,
                  device: deviceRef
              ) else {
            requestedStackVolumeKey = nil
            stackVolumeTextureEntry = nil
            registrationPreparationDidFail("Could not read the base registration volume")
            return
        }

        if MetalSeriesTextureCache.shared.isEntryKnownUnavailable(
               for: pixList,
               device: deviceRef
        ) {
            NSLog("%@", "Metal Viewer: unsupported stored-pixel encoding for volume \(key)")
            registrationPreparationDidFail("Unsupported base registration volume")
            return
        }

        requestedStackVolumeKey = key
        if let entry = MetalSeriesTextureCache.shared.cachedEntry(
            for: pixList,
            device: deviceRef
        ) {
            stackVolumeTextureEntry = entry
            stackVolumeTextureDidBecomeAvailable()
            return
        }

        let requestedPixList = pixList
        let decodedSliceSeed: MetalSeriesTextureCache.DecodedSliceSeed?
        if let immediateStackSliceIndex,
           let immediateStackSlicePixels,
           requestedPixList.indices.contains(immediateStackSliceIndex) {
            decodedSliceSeed = MetalSeriesTextureCache.DecodedSliceSeed(
                pix: requestedPixList[immediateStackSliceIndex],
                index: immediateStackSliceIndex,
                pixels: immediateStackSlicePixels
            )
        } else {
            decodedSliceSeed = nil
        }
        MetalSeriesTextureCache.shared.requestEntry(
            for: requestedPixList,
            device: deviceRef,
            decodedSliceSeed: decodedSliceSeed
        ) { [weak self] entry in
            guard let self,
                  self.requestedStackVolumeKey == key,
                  self.pixList.count == requestedPixList.count,
                  zip(self.pixList, requestedPixList).allSatisfy({ currentPix, requestedPix in
                      currentPix === requestedPix
                  }) else {
                return
            }

            guard let entry else {
                self.requestedStackVolumeKey = nil
                NSLog(
                    "%@",
                    "Metal Viewer: compact volume decode failed for \(requestedPixList.first?.srcFile ?? "unknown source")"
                )
                self.registrationPreparationDidFail("Could not decode the base registration volume")
                return
            }

            self.stackVolumeTextureEntry = entry
            self.stackVolumeTextureDidBecomeAvailable()
        }
    }

    private func stackVolumeTextureDidBecomeAvailable() {
        if displayMode.isMPRLike || overlayPixList.isEmpty == false {
            publishRegistrationPreparationUpdate(
                message: "Preparing base registration volume",
                progress: 0.25
            )
            prepareBaseVolumeIfNeeded()
        }
        stateDidChange?(stateDescription)
    }

    private func requestOverlayVolumeTexture() {
        guard overlayPixList.isEmpty == false,
              let key = MetalSeriesTextureCache.shared.key(
                for: overlayPixList,
                device: deviceRef
              ) else {
            requestedOverlayVolumeKey = nil
            overlaySourceTextureEntry = nil
            registrationPreparationDidFail("Could not read the overlay registration volume")
            return
        }

        requestedOverlayVolumeKey = key
        if let entry = MetalSeriesTextureCache.shared.cachedEntry(
            for: overlayPixList,
            device: deviceRef
        ) {
            overlaySourceTextureEntry = entry
            publishRegistrationPreparationUpdate(
                message: "Preparing overlay registration volume",
                progress: 0.5
            )
            prepareOverlayVolumeIfNeeded()
            return
        }

        let requestedPixList = overlayPixList
        MetalSeriesTextureCache.shared.requestEntry(
            for: requestedPixList,
            device: deviceRef
        ) { [weak self] entry in
            guard let self,
                  self.requestedOverlayVolumeKey == key,
                  self.overlayPixList.count == requestedPixList.count,
                  zip(self.overlayPixList, requestedPixList).allSatisfy({ currentPix, requestedPix in
                      currentPix === requestedPix
                  }) else {
                return
            }

            guard let entry else {
                self.requestedOverlayVolumeKey = nil
                NSLog(
                    "%@",
                    "Metal Viewer: compact overlay volume decode failed for \(requestedPixList.first?.srcFile ?? "unknown source")"
                )
                self.registrationPreparationDidFail("Could not decode the overlay registration volume")
                return
            }

            self.overlaySourceTextureEntry = entry
            self.publishRegistrationPreparationUpdate(
                message: "Preparing overlay registration volume",
                progress: 0.5
            )
            self.prepareOverlayVolumeIfNeeded()
        }
    }

    private func windowLevelDefaults(
        for pix: DCMPix,
        storedPixels: MetalStoredInt16PixelData? = nil
    ) -> MetalViewerWindowLevel {
        let resolvedStoredPixels = storedPixels ?? MetalStoredInt16PixelData(pix: pix)
        return resolvedStoredPixels?.inferredWindow
            ?? MetalViewerWindowLevel(level: 0, width: 1)
    }

    private func initialWindowLevelDefaults(
        for pix: DCMPix,
        usesAutomaticWindowLevel: Bool,
        storedPixels: MetalStoredInt16PixelData? = nil
    ) -> MetalViewerWindowLevel {
        let resolvedStoredPixels = storedPixels ?? MetalStoredInt16PixelData(pix: pix)
        if usesAutomaticWindowLevel,
           let resolvedStoredPixels,
           let automaticWindow = MetalViewerAutomaticWindowLevel.window(
            for: resolvedStoredPixels,
            modality: pix.modalityString
           ) {
            return automaticWindow
        }
        return resolvedStoredPixels?.inferredWindow
            ?? MetalViewerWindowLevel(level: 0, width: 1)
    }

    private func applyBaseWindowLevel(_ window: MetalViewerWindowLevel) {
        windowLevel = window.level
        windowWidth = max(1, window.width)
    }

    private func applyOverlayWindowLevel(_ window: MetalViewerWindowLevel) {
        overlayWindowLevel = window.level
        overlayWindowWidth = max(1, window.width)
    }

    private func notifyWindowLevelStateDidChange() {
        windowLevelStateDidChange?(
            MetalViewerWindowLevelState(
                defaultWindow: defaultSeriesWindowLevel,
                customWindow: customSeriesWindowLevel
            )
        )
    }

    private func notifyOverlayWindowLevelStateDidChange() {
        overlayWindowLevelStateDidChange?(
            MetalViewerWindowLevelState(
                defaultWindow: overlayDefaultSeriesWindowLevel,
                customWindow: overlayCustomSeriesWindowLevel
            )
        )
    }

    private func rebuildBaseTransferTextures() {
        let clut = makeCLUTTexture(named: baseTransferFunctionState.clutName)
        baseCLUTTexture = clut.texture
        baseTransferFunctionState.clutName = clut.name
        baseHasCustomCLUT = clut.isCustom

        let opacity = makeOpacityTexture(named: baseTransferFunctionState.opacityName)
        baseOpacityTexture = opacity.texture
        baseTransferFunctionState.opacityName = opacity.name
    }

    private func rebuildOverlayTransferTextures() {
        let clut = makeCLUTTexture(named: overlayTransferFunctionState.clutName)
        overlayCLUTTexture = clut.texture
        overlayTransferFunctionState.clutName = clut.name
        overlayHasCustomCLUT = clut.isCustom

        let opacity = makeOpacityTexture(named: overlayTransferFunctionState.opacityName)
        overlayOpacityTexture = opacity.texture
        overlayTransferFunctionState.opacityName = opacity.name
    }

    private func makeCLUTTexture(named presetName: String) -> (texture: MTLTexture?, name: String, isCustom: Bool) {
        let noCLUT = NSLocalizedString("No CLUT", comment: "")
        let presets = UserDefaults.standard.dictionary(forKey: "CLUT") ?? [:]
        var pixels = (0..<256).map { value in
            SIMD4<UInt8>(UInt8(value), UInt8(value), UInt8(value), 255)
        }

        guard presetName != noCLUT,
              let preset = presets[presetName] as? [String: Any],
              let red = preset["Red"] as? [NSNumber],
              let green = preset["Green"] as? [NSNumber],
              let blue = preset["Blue"] as? [NSNumber],
              red.count >= 256,
              green.count >= 256,
              blue.count >= 256 else {
            return (makeRGBA1DTexture(pixels: pixels), noCLUT, false)
        }

        for index in 0..<256 {
            pixels[index] = SIMD4<UInt8>(
                UInt8(clamping: red[index].intValue),
                UInt8(clamping: green[index].intValue),
                UInt8(clamping: blue[index].intValue),
                255
            )
        }
        return (makeRGBA1DTexture(pixels: pixels), presetName, true)
    }

    private func makeOpacityTexture(named presetName: String) -> (texture: MTLTexture?, name: String) {
        let linearTable = NSLocalizedString("Linear Table", comment: "")
        let presets = UserDefaults.standard.dictionary(forKey: "OPACITY") ?? [:]
        let pointStrings: [String]
        let resolvedName: String

        if presetName == linearTable {
            pointStrings = []
            resolvedName = linearTable
        } else if let preset = presets[presetName] as? [String: Any],
                  let points = preset["Points"] as? [Any] {
            pointStrings = points.compactMap { $0 as? String }
            resolvedName = presetName
        } else {
            pointStrings = []
            resolvedName = linearTable
        }

        let width = 4096
        var values = [Float](repeating: 0, count: width)
        var points = pointStrings.map { string -> (x: Float, y: Float) in
            var point = NSPointFromString(string)
            point.x -= 1000
            return (
                x: min(max(Float(point.x) / 256.0, 0), 1),
                y: min(max(Float(point.y), 0), 1)
            )
        }
        points.sort { $0.x < $1.x }

        for index in 0..<width {
            let sample = Float(index) / Float(max(width - 1, 1))
            guard points.isEmpty == false else {
                values[index] = sample
                continue
            }

            if let first = points.first, sample <= first.x {
                values[index] = first.x > 0 ? (sample / first.x) * first.y : first.y
                continue
            }

            var assigned = false
            for pointIndex in 1..<points.count {
                let previous = points[pointIndex - 1]
                let current = points[pointIndex]
                if sample <= current.x {
                    let fraction = (sample - previous.x) / max(current.x - previous.x, 0.0001)
                    values[index] = previous.y + (current.y - previous.y) * fraction
                    assigned = true
                    break
                }
            }

            if assigned == false {
                let last = points.last ?? (x: 0, y: 0)
                values[index] = last.y + (1 - last.y) * ((sample - last.x) / max(1 - last.x, 0.0001))
            }
        }

        return (makeFloat1DTexture(values: values), resolvedName)
    }

    private func makeRGBA1DTexture(pixels: [SIMD4<UInt8>]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: pixels.count,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else { return nil }

        pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, pixels.count, 1),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: pixels.count * MemoryLayout<SIMD4<UInt8>>.stride
            )
        }
        return texture
    }

    private func makeFloat1DTexture(values: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: values.count,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else { return nil }

        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, values.count, 1),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: values.count * MemoryLayout<Float>.stride
            )
        }
        return texture
    }

    private func setTransferTextures(on encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(baseCLUTTexture, index: 3)
        encoder.setFragmentTexture(baseOpacityTexture, index: 4)
        encoder.setFragmentTexture(overlayCLUTTexture, index: 5)
        encoder.setFragmentTexture(overlayOpacityTexture, index: 6)
    }

    private func resetRegistrationSupportVolumes(
        primaryWeight: Float = 1,
        inputs: [MetalViewerRegistrationSupportInput] = []
    ) {
        registrationSupportGeneration &+= 1
        var identifiers = Set<String>()
        let filteredInputs = inputs.filter { input in
            guard input.pixList.isEmpty == false,
                  input.weight > 0,
                  identifiers.insert(input.identifier).inserted else {
                return false
            }
            if let pairedPixList = input.pairedPixList {
                return pairedPixList.isEmpty == false
            }
            return true
        }
        registrationSupportLock.lock()
        registrationPrimaryWeight = max(primaryWeight, 0.0001)
        registrationSupportInputs = filteredInputs
        preparedRegistrationSupportVolumes = []
        registrationSupportLock.unlock()
        pendingRegistrationSupportIdentifiers = []
        registrationSupportPreparationStarted = false
    }

    private func prepareRegistrationSupportVolumesIfNeeded() {
        guard registrationSupportPreparationStarted == false,
              registrationSupportInputs.isEmpty == false else {
            return
        }

        registrationSupportPreparationStarted = true
        let generation = registrationSupportGeneration
        let inputs = registrationSupportInputs
        pendingRegistrationSupportIdentifiers = Set(inputs.map(\.identifier))
        publishRegistrationPreparationUpdate(
            message: "Preparing registration series 0/\(inputs.count)",
            progress: 0.55
        )

        for input in inputs {
            prepareRegistrationSupportEntry(
                for: input.pixList,
                identifier: input.identifier,
                generation: generation
            ) { [weak self] entry in
                guard let self else { return }
                guard let entry,
                      let pairedPixList = input.pairedPixList else {
                    self.completeRegistrationSupportPreparation(
                        input: input,
                        entry: entry,
                        pairedEntry: nil,
                        generation: generation
                    )
                    return
                }

                self.prepareRegistrationSupportEntry(
                    for: pairedPixList,
                    identifier: "\(input.identifier) paired",
                    pendingIdentifier: input.identifier,
                    generation: generation
                ) { [weak self] pairedEntry in
                    self?.completeRegistrationSupportPreparation(
                        input: input,
                        entry: entry,
                        pairedEntry: pairedEntry,
                        generation: generation
                    )
                }
            }
        }
    }

    private func prepareRegistrationSupportEntry(
        for pixList: [DCMPix],
        identifier: String,
        pendingIdentifier: String? = nil,
        generation: UInt,
        completion: @escaping (MetalPreparedVolumeCache.Entry?) -> Void
    ) {
        let pendingIdentifier = pendingIdentifier ?? identifier
        MetalSeriesTextureCache.shared.requestEntry(
            for: pixList,
            device: deviceRef
        ) { [weak self] sourceEntry in
            guard let self,
                  generation == self.registrationSupportGeneration,
                  self.pendingRegistrationSupportIdentifiers.contains(pendingIdentifier) else {
                return
            }
            guard let sourceEntry else {
                NSLog("%@", "Metal Viewer: could not decode registration support series \(identifier)")
                completion(nil)
                return
            }

            let correctGantryTilt = self.shouldCorrectGantryTilt(for: pixList)
            MetalPreparedVolumeCache.shared.requestEntry(
                for: pixList,
                sourceEntry: sourceEntry,
                device: self.deviceRef,
                correctGantryTilt: correctGantryTilt,
                includeRegistrationPyramid: true
            ) { [weak self] entry in
                guard let self,
                      generation == self.registrationSupportGeneration,
                      self.pendingRegistrationSupportIdentifiers.contains(pendingIdentifier) else {
                    return
                }
                if entry == nil {
                    NSLog("%@", "Metal Viewer: could not prepare registration support series \(identifier)")
                }
                completion(entry)
            }
        }
    }

    private func completeRegistrationSupportPreparation(
        input: MetalViewerRegistrationSupportInput,
        entry: MetalPreparedVolumeCache.Entry?,
        pairedEntry: MetalPreparedVolumeCache.Entry?,
        generation: UInt
    ) {
        guard generation == registrationSupportGeneration,
              pendingRegistrationSupportIdentifiers.remove(input.identifier) != nil else {
            return
        }

        if let entry,
           input.pairedPixList == nil || pairedEntry != nil {
            registrationSupportLock.lock()
            preparedRegistrationSupportVolumes.removeAll {
                $0.input.identifier == input.identifier
            }
            preparedRegistrationSupportVolumes.append(
                PreparedRegistrationSupportVolume(
                    input: input,
                    entry: entry,
                    pairedEntry: pairedEntry
                )
            )
            registrationSupportLock.unlock()
        }

        let totalCount = registrationSupportInputs.count
        let completedCount = totalCount - pendingRegistrationSupportIdentifiers.count
        publishRegistrationPreparationUpdate(
            message: "Preparing registration series \(completedCount)/\(totalCount)",
            progress: 0.55 + 0.35 * Float(completedCount) / Float(max(totalCount, 1))
        )
        if pendingRegistrationSupportIdentifiers.isEmpty {
            startRegistrationIfReady()
        }
    }

    private func prepareBaseVolumeIfNeeded() {
        let needsRegistrationPyramid = overlayPixList.isEmpty == false
        if baseVolumeTexture != nil,
           needsRegistrationPyramid == false || baseVolumeLevels.count > 1 {
            return
        }
        guard let stackVolumeTextureEntry else {
            requestStackVolumeTexture()
            return
        }
        let correctGantryTilt = shouldCorrectGantryTilt(for: pixList)

        let key = MetalPreparedVolumeCache.shared.key(
            for: stackVolumeTextureEntry,
            correctGantryTilt: correctGantryTilt
        )
        let requestIdentity = "\(key)|pyramid=\(needsRegistrationPyramid ? 1 : 0)"
        guard requestedBasePreparedVolumeKey != requestIdentity else { return }
        requestedBasePreparedVolumeKey = requestIdentity
        let requestedPixList = pixList

        MetalPreparedVolumeCache.shared.requestEntry(
            for: requestedPixList,
            sourceEntry: stackVolumeTextureEntry,
            device: deviceRef,
            correctGantryTilt: correctGantryTilt,
            includeRegistrationPyramid: needsRegistrationPyramid
        ) { [weak self] entry in
            guard let self,
                  self.requestedBasePreparedVolumeKey == requestIdentity,
                  self.pixList.count == requestedPixList.count,
                  zip(self.pixList, requestedPixList).allSatisfy({ currentPix, requestedPix in
                      currentPix === requestedPix
                  }) else {
                return
            }
            self.requestedBasePreparedVolumeKey = nil
            guard let entry else {
                NSLog("%@", "Metal Viewer: GPU preparation failed for the base volume")
                self.registrationPreparationDidFail("Could not prepare the base registration volume")
                return
            }
            self.installBasePreparedVolume(entry)
        }
    }

    private func prepareOverlayVolumeIfNeeded() {
        guard overlayPixList.isEmpty == false,
              overlayVolumeTexture == nil,
              let overlaySourceTextureEntry else {
            return
        }
        let correctGantryTilt = shouldCorrectGantryTilt(for: overlayPixList)

        let key = MetalPreparedVolumeCache.shared.key(
            for: overlaySourceTextureEntry,
            correctGantryTilt: correctGantryTilt
        )
        guard requestedOverlayPreparedVolumeKey != key else { return }
        requestedOverlayPreparedVolumeKey = key
        let requestedPixList = overlayPixList

        MetalPreparedVolumeCache.shared.requestEntry(
            for: requestedPixList,
            sourceEntry: overlaySourceTextureEntry,
            device: deviceRef,
            correctGantryTilt: correctGantryTilt,
            includeRegistrationPyramid: true
        ) { [weak self] entry in
            guard let self,
                  self.requestedOverlayPreparedVolumeKey == key,
                  self.overlayPixList.count == requestedPixList.count,
                  zip(self.overlayPixList, requestedPixList).allSatisfy({ currentPix, requestedPix in
                      currentPix === requestedPix
                  }) else {
                return
            }
            self.requestedOverlayPreparedVolumeKey = nil
            guard let entry else {
                NSLog("%@", "Metal Viewer: GPU preparation failed for the overlay volume")
                self.registrationPreparationDidFail("Could not prepare the overlay registration volume")
                return
            }
            self.installOverlayPreparedVolume(entry)
        }
    }

    private func installBasePreparedVolume(_ entry: MetalPreparedVolumeCache.Entry) {
        let wasUnprepared = baseVolumeTexture == nil
        fixedVoxelToWorld = entry.voxelToWorld
        baseVolumeDimensions = entry.dimensions
        baseVolumeTexture = entry.texture
        baseUsesGantryTiltCorrectedVolume = entry.isGantryTiltCorrected
        baseVolumeLevels = entry.levels
        let baseRegistrationWindow = defaultSeriesWindowLevel ?? entry.defaultWindow
        baseRegistrationWindowLevel = baseRegistrationWindow.level
        baseRegistrationWindowWidth = baseRegistrationWindow.width
        baseVolumeCenterWorld = volumeCenterWorld(
            dimensions: baseVolumeDimensions,
            voxelToWorld: fixedVoxelToWorld
        )
        baseInformativeCenterWorld = baseVolumeCenterWorld
        baseIsThinSlab = isThinSlab(
            dimensions: baseVolumeDimensions,
            voxelToWorld: fixedVoxelToWorld
        )
        baseSlabGeometry = baseIsThinSlab
            ? slabGeometry(dimensions: baseVolumeDimensions, voxelToWorld: fixedVoxelToWorld)
            : nil
        if wasUnprepared, displayMode.isMPRLike {
            resetMPRPlaneToCurrentSlice()
        }
        prepareOverlayVolumeIfNeeded()
        startRegistrationIfReady()
        stateDidChange?(stateDescription)
    }

    private func installOverlayPreparedVolume(_ entry: MetalPreparedVolumeCache.Entry) {
        let movingVoxelToWorld = entry.voxelToWorld
        overlayVolumeDimensions = entry.dimensions
        overlayUsesGantryTiltCorrectedVolume = entry.isGantryTiltCorrected
        overlayVolumeTexture = entry.texture
        overlayVolumeLevels = entry.levels
        let overlayRegistrationWindow = overlayDefaultSeriesWindowLevel ?? entry.defaultWindow
        overlayRegistrationWindowLevel = overlayRegistrationWindow.level
        overlayRegistrationWindowWidth = overlayRegistrationWindow.width
        overlayVolumeCenterWorld = volumeCenterWorld(
            dimensions: overlayVolumeDimensions,
            voxelToWorld: movingVoxelToWorld
        )
        overlayInformativeCenterWorld = overlayVolumeCenterWorld
        overlayIsThinSlab = isThinSlab(
            dimensions: overlayVolumeDimensions,
            voxelToWorld: movingVoxelToWorld
        )
        overlaySlabGeometry = overlayIsThinSlab
            ? slabGeometry(dimensions: overlayVolumeDimensions, voxelToWorld: movingVoxelToWorld)
            : nil
        movingWorldToVoxel = simd_inverse(movingVoxelToWorld)
        movingRotationCenterWorld = overlayVolumeCenterWorld
        overlayTranslationWorld = .zero
        overlayRotationRadians = .zero
        overlayTranslationPixels = .zero
        loadSlice(at: currentSliceIndex)
        prepareBaseVolumeIfNeeded()
        startRegistrationIfReady()
        stateDidChange?(stateDescription)
    }

    private func startRegistrationIfReady() {
        guard registrationInProgress == false,
              baseVolumeTexture != nil,
              overlayVolumeTexture != nil,
              baseVolumeLevels.count > 1,
              overlayVolumeLevels.count > 1 else {
            return
        }
        if registrationSupportInputs.isEmpty == false {
            if registrationSupportPreparationStarted == false {
                prepareRegistrationSupportVolumesIfNeeded()
                return
            }
            guard pendingRegistrationSupportIdentifiers.isEmpty else {
                return
            }
        }
        let additionalInitialStates: [RigidTransformState]
        if let suggestedRegistrationWorldTransform,
           let suggestedState = registrationState(for: suggestedRegistrationWorldTransform) {
            additionalInitialStates = [suggestedState]
        } else {
            additionalInitialStates = []
        }
        runRegistration(
            additionalInitialStates: additionalInitialStates,
            samplingMode: .fast
        )
    }

    private func invalidateActiveRegistrationJob() {
        activeRegistrationJob?.cancel()
        activeRegistrationJob = nil
        registrationGeneration &+= 1
    }

    private func publishRegistrationPreparationUpdate(message: String, progress: Float) {
        guard overlayPixList.isEmpty == false else { return }
        registrationProgress = max(registrationProgress, min(max(progress, 0), 0.95))
        registrationStatusMessage = message
        registrationDidChange?(true, message, registrationProgress)
    }

    private func registrationPreparationDidFail(_ message: String) {
        guard overlayPixList.isEmpty == false else { return }
        invalidateActiveRegistrationJob()
        registrationInProgress = false
        registrationProgress = 0
        registrationStatusMessage = message
        stateDidChange?(stateDescription)
        registrationDidChange?(false, message, 0)
    }

    private func voxelSpacing(from voxelToWorld: simd_float4x4) -> SIMD3<Float> {
        let x = SIMD3<Float>(voxelToWorld.columns.0.x, voxelToWorld.columns.0.y, voxelToWorld.columns.0.z)
        let y = SIMD3<Float>(voxelToWorld.columns.1.x, voxelToWorld.columns.1.y, voxelToWorld.columns.1.z)
        let z = SIMD3<Float>(voxelToWorld.columns.2.x, voxelToWorld.columns.2.y, voxelToWorld.columns.2.z)
        return SIMD3<Float>(max(simd_length(x), 0.0001), max(simd_length(y), 0.0001), max(simd_length(z), 0.0001))
    }

    private func physicalExtent(dimensions: SIMD3<Int>, voxelToWorld: simd_float4x4) -> SIMD3<Float> {
        let spacing = voxelSpacing(from: voxelToWorld)
        return SIMD3<Float>(
            Float(max(dimensions.x - 1, 0)) * spacing.x,
            Float(max(dimensions.y - 1, 0)) * spacing.y,
            Float(max(dimensions.z - 1, 0)) * spacing.z
        )
    }

    private func thinSlabAxis(for level: VolumeLevel) -> Int {
        let extent = physicalExtent(dimensions: level.dimensions, voxelToWorld: level.voxelToWorld)
        let extents = [extent.x, extent.y, extent.z]
        return extents.enumerated().min(by: { $0.element < $1.element })?.offset ?? 2
    }

    private func slabFastSamplingStride(
        for level: (VolumeLevel, VolumeLevel)
    ) -> SIMD3<Int>? {
        // Fast slab sampling must be a property of the pair, not of whichever
        // series happens to be fixed. Otherwise reversing a thin-to-thick
        // registration silently selects a different optimizer.
        guard baseIsThinSlab,
              overlayIsThinSlab else {
            return nil
        }

        let baseThinAxis = thinSlabAxis(for: level.0)
        var stride = SIMD3<Int>(repeating: 2)
        // Subsample only within the slab plane. Retaining every sample through
        // its thin dimension avoids erasing already-limited anatomical data.
        stride[baseThinAxis] = 1
        return stride
    }

    private func registrationSamplingStride(
        for level: (VolumeLevel, VolumeLevel),
        samplingMode: RegistrationSamplingMode
    ) -> SIMD3<Int> {
        guard samplingMode == .fast else {
            return SIMD3<Int>(repeating: 1)
        }
        return slabFastSamplingStride(for: level) ?? SIMD3<Int>(repeating: 2)
    }

    private func isThinSlab(dimensions: SIMD3<Int>, voxelToWorld: simd_float4x4) -> Bool {
        let extent = physicalExtent(dimensions: dimensions, voxelToWorld: voxelToWorld)
        let sortedExtent = [extent.x, extent.y, extent.z].sorted()
        guard let thinnest = sortedExtent.first,
              let middle = sortedExtent.dropFirst().first,
              let thickest = sortedExtent.last else {
            return false
        }

        let minInPlaneExtent = max(middle, thickest)
        let anisotropy = thinnest / max(minInPlaneExtent, 0.0001)
        // This flag means limited anatomical coverage, not merely a very small
        // slice count. Orbit/sella protocols commonly cover 50–80 mm through
        // plane and still behave as slabs for registration: treating them as
        // whole head volumes permits coarse seeds and rotations that align an
        // unrelated accidental intersection. The anisotropy guard keeps true
        // whole-volume acquisitions out of this path.
        return thinnest < 100 && anisotropy < 0.55
    }

    private func isCrossPlaneThinSlabRegistration() -> Bool {
        guard baseIsThinSlab,
              overlayIsThinSlab,
              let baseSlabGeometry,
              let overlaySlabGeometry else {
            return false
        }
        return abs(simd_dot(baseSlabGeometry.normalWorld, overlaySlabGeometry.normalWorld)) < 0.7
    }

    private func isUnequalCoverageThinSlabRegistration() -> Bool {
        baseIsThinSlab != overlayIsThinSlab
    }

    private func isCrossModalityUnequalCoverageRegistration() -> Bool {
        guard isUnequalCoverageThinSlabRegistration() else { return false }
        return isCTRegistrationVolume(pixList) != isCTRegistrationVolume(overlayPixList)
    }

    private func minimumCranialCoverageFraction() -> Float {
        if let cached = minimumCranialCoverageFractionCache {
            return cached
        }
        guard isCrossModalityUnequalCoverageRegistration() else {
            minimumCranialCoverageFractionCache = 0
            return 0
        }

        let thinPixList = baseIsThinSlab ? pixList : overlayPixList
        guard let path = thinPixList.first?.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              let reader = try? SwiftDICOMReader.cached(contentsOfFile: path) else {
            minimumCranialCoverageFractionCache = 0
            return 0
        }

        let metadataTags = ["0008,1030", "0008,103E", "0018,0015", "0018,1030"]
        let metadata = metadataTags.compactMap { reader.stringValue(forTag: $0) }.joined(separator: " ")
        let tokens = Set(metadata
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false })
        let cranialTokens: Set<String> = [
            "BRAIN", "HEAD", "ORBIT", "ORBITS", "SINUS", "SINUSES", "SKULL",
        ]

        let minimumFraction: Float
        if tokens.contains("SELLA") || tokens.contains("PITUITARY") {
            minimumFraction = 0.55
        } else if tokens.isDisjoint(with: cranialTokens) == false {
            minimumFraction = 0.50
        } else {
            minimumFraction = 0
        }
        minimumCranialCoverageFractionCache = minimumFraction
        return minimumFraction
    }

    private func mrSequenceSignature(for volumePixList: [DCMPix]) -> MRSequenceSignature? {
        guard let firstPix = volumePixList.first,
              firstPix.modalityString?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == "MR",
              let path = firstPix.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              let reader = try? SwiftDICOMReader.cached(contentsOfFile: path) else {
            return nil
        }

        func codeValues(forTag tag: String) -> Set<String> {
            guard let value = reader.stringValue(forTag: tag) else { return [] }
            return Set(value
                .components(separatedBy: "\\")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { $0.isEmpty == false })
        }

        let scanningSequences = codeValues(forTag: "0018,0020")
        let scanOptions = codeValues(forTag: "0018,0022")
        let imageTypes = codeValues(forTag: "0008,0008")
        guard scanningSequences.isEmpty == false
                || scanOptions.isEmpty == false
                || imageTypes.isEmpty == false else {
            return nil
        }
        return MRSequenceSignature(
            scanningSequences: scanningSequences,
            scanOptions: scanOptions,
            imageTypes: imageTypes
        )
    }

    private func usesContrastInvariantMRSlabMatching() -> Bool {
        if let cached = contrastInvariantMRSlabMatchingCache {
            return cached
        }
        guard baseIsThinSlab || overlayIsThinSlab,
              let baseSignature = mrSequenceSignature(for: pixList),
              let overlaySignature = mrSequenceSignature(for: overlayPixList) else {
            contrastInvariantMRSlabMatchingCache = false
            return false
        }

        let crossesSpinAndGradientEcho =
            (baseSignature.isSpinEcho && overlaySignature.isGradientEcho)
            || (baseSignature.isGradientEcho && overlaySignature.isSpinEcho)
        let changesFatSuppression =
            baseSignature.usesFatSuppression != overlaySignature.usesFatSuppression
        let changesDixonReconstruction =
            baseSignature.dixonContrastComponents != overlaySignature.dixonContrastComponents
            && (baseSignature.dixonContrastComponents.isEmpty == false
                || overlaySignature.dixonContrastComponents.isEmpty == false)
        let usesContrastInvariantMatching = crossesSpinAndGradientEcho
            || changesFatSuppression
            || changesDixonReconstruction
        contrastInvariantMRSlabMatchingCache = usesContrastInvariantMatching
        return usesContrastInvariantMatching
    }

    private func usesStructureOnlyCrossPlaneMetric() -> Bool {
        guard isCTRegistrationVolume(pixList) == false,
              isCTRegistrationVolume(overlayPixList) == false else {
            return false
        }
        return isCrossPlaneThinSlabRegistration()
    }

    private func slabGeometry(dimensions: SIMD3<Int>, voxelToWorld: simd_float4x4) -> SlabGeometry {
        let columns = [
            SIMD3<Float>(voxelToWorld.columns.0.x, voxelToWorld.columns.0.y, voxelToWorld.columns.0.z),
            SIMD3<Float>(voxelToWorld.columns.1.x, voxelToWorld.columns.1.y, voxelToWorld.columns.1.z),
            SIMD3<Float>(voxelToWorld.columns.2.x, voxelToWorld.columns.2.y, voxelToWorld.columns.2.z)
        ]
        let counts = [
            Float(max(dimensions.x - 1, 0)),
            Float(max(dimensions.y - 1, 0)),
            Float(max(dimensions.z - 1, 0))
        ]
        let extents = zip(columns, counts).map { column, count in
            simd_length(column) * count
        }
        let minIndex = extents.enumerated().min(by: { $0.element < $1.element })?.offset ?? 2
        let normal = simd_normalize(columns[minIndex])
        return SlabGeometry(normalWorld: normal, thicknessMM: max(extents[minIndex], 0.1))
    }

    private func volumeCenterWorld(dimensions: SIMD3<Int>, voxelToWorld: simd_float4x4) -> SIMD3<Float> {
        let centerVoxel = SIMD4<Float>(
            Float(max(dimensions.x - 1, 0)) * 0.5,
            Float(max(dimensions.y - 1, 0)) * 0.5,
            Float(max(dimensions.z - 1, 0)) * 0.5,
            1
        )
        let world = voxelToWorld * centerVoxel
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    private func rotationMatrix(for radians: SIMD3<Float>) -> simd_float4x4 {
        let cx = cos(radians.x)
        let sx = sin(radians.x)
        let cy = cos(radians.y)
        let sy = sin(radians.y)
        let cz = cos(radians.z)
        let sz = sin(radians.z)

        let rx = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cx, sx, 0),
            SIMD4<Float>(0, -sx, cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let ry = simd_float4x4(
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sy, 0, cy, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let rz = simd_float4x4(
            SIMD4<Float>(cz, sz, 0, 0),
            SIMD4<Float>(-sz, cz, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        return rz * ry * rx
    }

    private func inverseRotationMatrix(for radians: SIMD3<Float>) -> simd_float4x4 {
        // Negating Euler angles without reversing their multiplication order is
        // not the inverse of a compound rotation. A rigid rotation matrix is
        // orthonormal, so its transpose is the exact inverse regardless of the
        // number of axes involved.
        rotationMatrix(for: radians).transpose
    }

    private func registrationWorldTransform(
        for state: RigidTransformState
    ) -> MetalViewerRegistrationWorldTransform {
        var transform = rotationMatrix(for: state.rotationRadians)
        let rotatedCenter = transform * SIMD4<Float>(movingRotationCenterWorld, 1)
        let worldOffset = movingRotationCenterWorld
            + state.translationWorld
            - SIMD3<Float>(rotatedCenter.x, rotatedCenter.y, rotatedCenter.z)
        transform.columns.3 = SIMD4<Float>(worldOffset, 1)
        return MetalViewerRegistrationWorldTransform(movingToFixedWorld: transform)
    }

    private func registrationState(
        for worldTransform: MetalViewerRegistrationWorldTransform
    ) -> RigidTransformState? {
        let transform = worldTransform.movingToFixedWorld
        let xAxis = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let yAxis = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let zAxis = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let axes = [xAxis, yAxis, zAxis]
        guard axes.allSatisfy({ axis in
            axis.x.isFinite && axis.y.isFinite && axis.z.isFinite
                && abs(simd_length(axis) - 1) < 0.02
        }),
              abs(simd_dot(xAxis, yAxis)) < 0.02,
              abs(simd_dot(xAxis, zAxis)) < 0.02,
              abs(simd_dot(yAxis, zAxis)) < 0.02,
              simd_dot(simd_cross(xAxis, yAxis), zAxis) > 0.98 else {
            return nil
        }

        // rotationMatrix(for:) uses Rz * Ry * Rx. Registrations are limited to
        // small patient-position differences, so the nonsingular ZYX solution
        // is the expected path; reject a gimbal-lock matrix rather than making
        // an arbitrary Euler choice for a shared-frame seed.
        // This renderer's Y rotation matrix stores +sin(y) in row 2,
        // column 0, so preserve that convention when reconstructing Euler
        // angles from the reusable world transform.
        let sinY = min(max(transform.columns.0.z, -1), 1)
        let rotationY = asin(sinY)
        guard abs(cos(rotationY)) > 0.0001 else { return nil }
        let rotationX = atan2(transform.columns.1.z, transform.columns.2.z)
        let rotationZ = atan2(transform.columns.0.y, transform.columns.0.x)
        let rotation = SIMD3<Float>(rotationX, rotationY, rotationZ)

        let rotatedCenter = transform * SIMD4<Float>(movingRotationCenterWorld, 0)
        let worldOffset = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let translation = worldOffset
            - movingRotationCenterWorld
            + SIMD3<Float>(rotatedCenter.x, rotatedCenter.y, rotatedCenter.z)
        guard translation.x.isFinite,
              translation.y.isFinite,
              translation.z.isFinite else {
            return nil
        }
        return RigidTransformState(
            translationWorld: translation,
            rotationRadians: rotation
        )
    }

    private func registrationTextureCoordinateMatrix(
        for state: RigidTransformState,
        fixedVoxelToWorld: simd_float4x4,
        movingWorldToVoxel: simd_float4x4,
        movingTextureSize: SIMD3<Int>
    ) -> simd_float4x4 {
        var translateToRotationCenter = matrix_identity_float4x4
        translateToRotationCenter.columns.3 = SIMD4<Float>(
            -state.translationWorld.x - movingRotationCenterWorld.x,
            -state.translationWorld.y - movingRotationCenterWorld.y,
            -state.translationWorld.z - movingRotationCenterWorld.z,
            1
        )

        var translateFromRotationCenter = matrix_identity_float4x4
        translateFromRotationCenter.columns.3 = SIMD4<Float>(movingRotationCenterWorld, 1)

        let inverseWidth = 1 / Float(max(movingTextureSize.x, 1))
        let inverseHeight = 1 / Float(max(movingTextureSize.y, 1))
        let inverseDepth = 1 / Float(max(movingTextureSize.z, 1))
        var movingVoxelToTexture = matrix_identity_float4x4
        movingVoxelToTexture.columns.0.x = inverseWidth
        movingVoxelToTexture.columns.1.y = inverseHeight
        movingVoxelToTexture.columns.2.z = inverseDepth
        movingVoxelToTexture.columns.3 = SIMD4<Float>(
            0.5 * inverseWidth,
            0.5 * inverseHeight,
            0.5 * inverseDepth,
            1
        )

        return movingVoxelToTexture
            * movingWorldToVoxel
            * translateFromRotationCenter
            * inverseRotationMatrix(for: state.rotationRadians)
            * translateToRotationCenter
            * fixedVoxelToWorld
    }

    private func reverseRegistrationTextureCoordinateMatrix(
        for state: RigidTransformState,
        fixedVoxelToWorld: simd_float4x4,
        movingWorldToVoxel: simd_float4x4,
        movingTextureSize: SIMD3<Int>
    ) -> simd_float4x4 {
        var translateToRotationCenter = matrix_identity_float4x4
        translateToRotationCenter.columns.3 = SIMD4<Float>(-movingRotationCenterWorld, 1)

        var translateFromRotationCenter = matrix_identity_float4x4
        translateFromRotationCenter.columns.3 = SIMD4<Float>(
            movingRotationCenterWorld.x + state.translationWorld.x,
            movingRotationCenterWorld.y + state.translationWorld.y,
            movingRotationCenterWorld.z + state.translationWorld.z,
            1
        )

        let inverseWidth = 1 / Float(max(movingTextureSize.x, 1))
        let inverseHeight = 1 / Float(max(movingTextureSize.y, 1))
        let inverseDepth = 1 / Float(max(movingTextureSize.z, 1))
        var movingVoxelToTexture = matrix_identity_float4x4
        movingVoxelToTexture.columns.0.x = inverseWidth
        movingVoxelToTexture.columns.1.y = inverseHeight
        movingVoxelToTexture.columns.2.z = inverseDepth
        movingVoxelToTexture.columns.3 = SIMD4<Float>(
            0.5 * inverseWidth,
            0.5 * inverseHeight,
            0.5 * inverseDepth,
            1
        )

        return movingVoxelToTexture
            * movingWorldToVoxel
            * translateFromRotationCenter
            * rotationMatrix(for: state.rotationRadians)
            * translateToRotationCenter
            * fixedVoxelToWorld
    }

    private func transformedOverlayPointWorld(_ pointWorld: SIMD3<Float>, for state: RigidTransformState) -> SIMD3<Float> {
        let centeredPoint = pointWorld - movingRotationCenterWorld
        let rotated = rotationMatrix(for: state.rotationRadians) * SIMD4<Float>(centeredPoint, 1)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z) + movingRotationCenterWorld + state.translationWorld
    }

    private func transformedOverlayCenterWorld(for state: RigidTransformState) -> SIMD3<Float> {
        transformedOverlayPointWorld(overlayInformativeCenterWorld, for: state)
    }

    private func transformedOverlayVolumeCenterWorld(for state: RigidTransformState) -> SIMD3<Float> {
        transformedOverlayPointWorld(overlayVolumeCenterWorld, for: state)
    }

    private func inverseTransformedBasePointWorld(_ pointWorld: SIMD3<Float>, for state: RigidTransformState) -> SIMD3<Float> {
        let translatedPoint = pointWorld - movingRotationCenterWorld - state.translationWorld
        let unrotated = inverseRotationMatrix(for: state.rotationRadians) * SIMD4<Float>(translatedPoint, 1)
        return SIMD3<Float>(unrotated.x, unrotated.y, unrotated.z) + movingRotationCenterWorld
    }

    private func projectedVolumeBounds(
        dimensions: SIMD3<Int>,
        voxelToWorld: simd_float4x4,
        direction: SIMD3<Float>
    ) -> (minimum: Float, maximum: Float) {
        let origin = SIMD3<Float>(
            voxelToWorld.columns.3.x,
            voxelToWorld.columns.3.y,
            voxelToWorld.columns.3.z
        )
        let columns = [
            SIMD3<Float>(voxelToWorld.columns.0.x, voxelToWorld.columns.0.y, voxelToWorld.columns.0.z),
            SIMD3<Float>(voxelToWorld.columns.1.x, voxelToWorld.columns.1.y, voxelToWorld.columns.1.z),
            SIMD3<Float>(voxelToWorld.columns.2.x, voxelToWorld.columns.2.y, voxelToWorld.columns.2.z),
        ]
        let counts = [
            Float(max(dimensions.x - 1, 0)),
            Float(max(dimensions.y - 1, 0)),
            Float(max(dimensions.z - 1, 0)),
        ]
        var minimum = simd_dot(origin, direction)
        var maximum = minimum
        for (column, count) in zip(columns, counts) {
            let projectedEdge = simd_dot(column * count, direction)
            if projectedEdge >= 0 {
                maximum += projectedEdge
            } else {
                minimum += projectedEdge
            }
        }
        return (minimum, maximum)
    }

    private func cranialCoverageFraction(for state: RigidTransformState) -> Float? {
        guard minimumCranialCoverageFraction() > 0 else { return nil }
        let baseVoxelToWorld = fixedVoxelToWorld
        let overlayVoxelToWorld = simd_inverse(movingWorldToVoxel)
        let thinDimensions = baseIsThinSlab ? baseVolumeDimensions : overlayVolumeDimensions
        let thinVoxelToWorld = baseIsThinSlab ? baseVoxelToWorld : overlayVoxelToWorld
        let fullDimensions = baseIsThinSlab ? overlayVolumeDimensions : baseVolumeDimensions
        let fullVoxelToWorld = baseIsThinSlab ? overlayVoxelToWorld : baseVoxelToWorld
        let thinCenterWorld = baseIsThinSlab
            ? baseVolumeCenterWorld
            : overlayVolumeCenterWorld
        return cranialCoverageFraction(
            for: state,
            thinCenterWorld: thinCenterWorld,
            thinDimensions: thinDimensions,
            thinVoxelToWorld: thinVoxelToWorld,
            fullDimensions: fullDimensions,
            fullVoxelToWorld: fullVoxelToWorld,
            thinSharesBaseFrame: baseIsThinSlab
        )
    }

    private func cranialCoverageFraction(
        for state: RigidTransformState,
        thinCenterWorld: SIMD3<Float>,
        thinDimensions: SIMD3<Int>,
        thinVoxelToWorld: simd_float4x4,
        fullDimensions: SIMD3<Int>,
        fullVoxelToWorld: simd_float4x4,
        thinSharesBaseFrame: Bool
    ) -> Float? {
        let superiorDirection = SIMD3<Float>(0, 0, 1)
        let thinBounds = projectedVolumeBounds(
            dimensions: thinDimensions,
            voxelToWorld: thinVoxelToWorld,
            direction: superiorDirection
        )
        let fullBounds = projectedVolumeBounds(
            dimensions: fullDimensions,
            voxelToWorld: fullVoxelToWorld,
            direction: superiorDirection
        )
        let thinExtent = thinBounds.maximum - thinBounds.minimum
        let fullExtent = fullBounds.maximum - fullBounds.minimum
        guard fullExtent / max(thinExtent, 0.0001) >= 1.5 else { return nil }

        let thinCenterInFullWorld = thinSharesBaseFrame
            ? inverseTransformedBasePointWorld(thinCenterWorld, for: state)
            : transformedOverlayPointWorld(thinCenterWorld, for: state)
        let superiorPosition = simd_dot(thinCenterInFullWorld, superiorDirection)
        return (superiorPosition - fullBounds.minimum) / max(fullExtent, 0.0001)
    }

    private func focusStackOnRegisteredOverlayIfNeeded(for state: RigidTransformState) {
        guard displayMode == .stack2D,
              baseIsThinSlab == false,
              overlayIsThinSlab,
              pixList.count > 1,
              baseVolumeDimensions.z > 1 else {
            return
        }

        // A thin moving slab can occupy only one end of a larger fixed volume.
        // Leaving the viewer on the fixed volume's middle slice then shows no
        // overlay even though the registration succeeded. Convert the
        // registered slab center into the fixed volume and show that location.
        let registeredCenterWorld = transformedOverlayCenterWorld(for: state)
        let baseVoxel = simd_inverse(fixedVoxelToWorld)
            * SIMD4<Float>(registeredCenterWorld, 1)
        guard baseVoxel.z.isFinite else { return }

        let volumeSlice = min(
            max(baseVoxel.z, 0),
            Float(max(baseVolumeDimensions.z - 1, 0))
        )
        let normalizedSlice = volumeSlice / Float(max(baseVolumeDimensions.z - 1, 1))
        let targetIndex = min(
            max(Int((normalizedSlice * Float(pixList.count - 1)).rounded()), 0),
            pixList.count - 1
        )
        guard targetIndex != currentSliceIndex else { return }

        currentSliceIndex = targetIndex
        loadSlice(at: targetIndex)
    }

    private func rotationAdjustedState(from state: RigidTransformState, deltaRotation: SIMD3<Float>, preserving pointWorld: SIMD3<Float>) -> RigidTransformState {
        let targetPoint = transformedOverlayPointWorld(pointWorld, for: state)
        var adjustedState = state
        adjustedState.rotationRadians += deltaRotation

        let centeredPoint = pointWorld - movingRotationCenterWorld
        let rotated = rotationMatrix(for: adjustedState.rotationRadians) * SIMD4<Float>(centeredPoint, 1)
        let transformedWithoutTranslation = SIMD3<Float>(rotated.x, rotated.y, rotated.z) + movingRotationCenterWorld
        adjustedState.translationWorld = targetPoint - transformedWithoutTranslation
        return adjustedState
    }

    private func slabOverlapPenalty(for state: RigidTransformState) -> Float {
        guard let baseSlabGeometry, let overlaySlabGeometry else { return 0 }

        let transformedOverlayCenter = transformedOverlayVolumeCenterWorld(for: state)
        let centerDelta = transformedOverlayCenter - baseVolumeCenterWorld
        let rotatedOverlayNormal4 = rotationMatrix(for: state.rotationRadians)
            * SIMD4<Float>(overlaySlabGeometry.normalWorld, 0)
        var rotatedOverlayNormal = simd_normalize(SIMD3<Float>(
            rotatedOverlayNormal4.x,
            rotatedOverlayNormal4.y,
            rotatedOverlayNormal4.z
        ))
        let normalDotProduct = simd_dot(baseSlabGeometry.normalWorld, rotatedOverlayNormal)
        // Center separation along a shared slab normal is meaningful only for
        // approximately parallel acquisitions. Axial/coronal slabs can have
        // widely separated centers and still intersect through the anatomy;
        // applying this penalty to them biases the optimizer toward a false
        // center-to-center alignment.
        guard abs(normalDotProduct) >= 0.7 else { return 0 }

        if normalDotProduct < 0 {
            rotatedOverlayNormal = -rotatedOverlayNormal
        }
        let combinedNormal = baseSlabGeometry.normalWorld + rotatedOverlayNormal
        let slabNormal = simd_length(combinedNormal) > 0.0001
            ? simd_normalize(combinedNormal)
            : baseSlabGeometry.normalWorld
        let normalSeparation = abs(simd_dot(centerDelta, slabNormal))
        let combinedHalfThickness = 0.5 * (baseSlabGeometry.thicknessMM + overlaySlabGeometry.thicknessMM)
        let normalOverlapFraction = max(0, (combinedHalfThickness - normalSeparation) / max(combinedHalfThickness, 0.0001))

        if normalOverlapFraction >= 0.5 {
            return 0
        }

        let missingOverlap = 0.5 - normalOverlapFraction
        return missingOverlap * 2.5
    }

    private func currentRegistrationLevelPairs() -> [(VolumeLevel, VolumeLevel)] {
        guard baseVolumeLevels.isEmpty == false,
              overlayVolumeLevels.isEmpty == false else {
            return []
        }

        let pairCount = min(baseVolumeLevels.count, overlayVolumeLevels.count)
        let baseLevels = Array(baseVolumeLevels.suffix(pairCount))
        let overlayLevels = Array(overlayVolumeLevels.suffix(pairCount))
        return Array(zip(baseLevels, overlayLevels))
    }

    private func registrationSupportMetricContext(
        for level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int
    ) -> RegistrationSupportMetricContext {
        // The additional series stabilize the broad search. The finest level
        // deliberately returns to the displayed pair for its independent
        // verification and local refinement.
        guard totalLevels > 1,
              levelIndex < totalLevels - 1 else {
            return RegistrationSupportMetricContext(primaryWeight: 1, pairs: [])
        }

        registrationSupportLock.lock()
        let primaryWeight = registrationPrimaryWeight
        let supportInputs = registrationSupportInputs
        let preparedVolumes = preparedRegistrationSupportVolumes
        registrationSupportLock.unlock()
        guard preparedVolumes.isEmpty == false else {
            return RegistrationSupportMetricContext(primaryWeight: 1, pairs: [])
        }

        let preparedByIdentifier: [String: PreparedRegistrationSupportVolume] = Dictionary(
            uniqueKeysWithValues: preparedVolumes.map {
                ($0.input.identifier, $0)
            }
        )
        let baseWindow = MetalViewerWindowLevel(
            level: baseRegistrationWindowLevel,
            width: max(baseRegistrationWindowWidth, 1)
        )
        let overlayWindow = MetalViewerWindowLevel(
            level: overlayRegistrationWindowLevel,
            width: max(overlayRegistrationWindowWidth, 1)
        )

        let pairs: [RegistrationSupportMetricPair] = supportInputs.compactMap {
            input -> RegistrationSupportMetricPair? in
            guard let prepared = preparedByIdentifier[input.identifier],
                  prepared.entry.levels.isEmpty == false else {
                return nil
            }
            let supportLevelIndex = min(
                max(levelIndex + prepared.entry.levels.count - totalLevels, 0),
                prepared.entry.levels.count - 1
            )
            let supportLevel = prepared.entry.levels[supportLevelIndex]
            if let pairedEntry = prepared.pairedEntry {
                guard pairedEntry.levels.isEmpty == false else { return nil }
                let pairedLevelIndex = min(
                    max(levelIndex + pairedEntry.levels.count - totalLevels, 0),
                    pairedEntry.levels.count - 1
                )
                return RegistrationSupportMetricPair(
                    identifier: input.identifier,
                    fixedLevel: supportLevel,
                    movingLevel: pairedEntry.levels[pairedLevelIndex],
                    fixedWindow: prepared.entry.defaultWindow,
                    movingWindow: pairedEntry.defaultWindow,
                    usesReverseTransform: false,
                    weight: input.weight
                )
            }
            if input.sharesBaseFrame {
                return RegistrationSupportMetricPair(
                    identifier: input.identifier,
                    fixedLevel: supportLevel,
                    movingLevel: level.1,
                    fixedWindow: prepared.entry.defaultWindow,
                    movingWindow: overlayWindow,
                    usesReverseTransform: false,
                    weight: input.weight
                )
            }
            return RegistrationSupportMetricPair(
                identifier: input.identifier,
                fixedLevel: supportLevel,
                movingLevel: level.0,
                fixedWindow: prepared.entry.defaultWindow,
                movingWindow: baseWindow,
                usesReverseTransform: true,
                weight: input.weight
            )
        }
        return RegistrationSupportMetricContext(
            primaryWeight: primaryWeight,
            pairs: pairs
        )
    }

    private func registrationSupportBlockMatchingPairs(
        for level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int
    ) -> [RegistrationBlockMatchingPair] {
        registrationSupportLock.lock()
        let supportInputs = registrationSupportInputs
        let preparedVolumes = preparedRegistrationSupportVolumes
        registrationSupportLock.unlock()
        guard supportInputs.isEmpty == false,
              preparedVolumes.isEmpty == false else {
            return []
        }

        let preparedByIdentifier: [String: PreparedRegistrationSupportVolume] = Dictionary(
            uniqueKeysWithValues: preparedVolumes.map {
                ($0.input.identifier, $0)
            }
        )
        let baseWindow = MetalViewerWindowLevel(
            level: baseRegistrationWindowLevel,
            width: max(baseRegistrationWindowWidth, 1)
        )
        let overlayWindow = MetalViewerWindowLevel(
            level: overlayRegistrationWindowLevel,
            width: max(overlayRegistrationWindowWidth, 1)
        )
        var representedNormals = [SIMD3<Float>]()
        if let primaryNormal = baseIsThinSlab
            ? baseSlabGeometry?.normalWorld
            : overlaySlabGeometry?.normalWorld {
            representedNormals.append(primaryNormal)
        }

        var pairs = [RegistrationBlockMatchingPair]()
        for input in supportInputs {
            guard pairs.count < 2,
                  let prepared = preparedByIdentifier[input.identifier],
                  prepared.entry.levels.isEmpty == false else {
                continue
            }
            let supportLevelIndex = min(
                max(levelIndex + prepared.entry.levels.count - totalLevels, 0),
                prepared.entry.levels.count - 1
            )
            let supportLevel = prepared.entry.levels[supportLevelIndex]
            if isThinSlab(
                dimensions: supportLevel.dimensions,
                voxelToWorld: supportLevel.voxelToWorld
            ) {
                let supportNormal = slabGeometry(
                    dimensions: supportLevel.dimensions,
                    voxelToWorld: supportLevel.voxelToWorld
                ).normalWorld
                guard representedNormals.allSatisfy({
                    abs(simd_dot($0, supportNormal)) < 0.9
                }) else {
                    continue
                }
                representedNormals.append(supportNormal)
            }

            if let pairedEntry = prepared.pairedEntry,
               pairedEntry.levels.isEmpty == false {
                let pairedLevelIndex = min(
                    max(levelIndex + pairedEntry.levels.count - totalLevels, 0),
                    pairedEntry.levels.count - 1
                )
                pairs.append(RegistrationBlockMatchingPair(
                    identifier: input.identifier,
                    fixedLevel: supportLevel,
                    movingLevel: pairedEntry.levels[pairedLevelIndex],
                    fixedWindow: prepared.entry.defaultWindow,
                    movingWindow: pairedEntry.defaultWindow
                ))
            } else if input.sharesBaseFrame {
                pairs.append(RegistrationBlockMatchingPair(
                    identifier: input.identifier,
                    fixedLevel: supportLevel,
                    movingLevel: level.1,
                    fixedWindow: prepared.entry.defaultWindow,
                    movingWindow: overlayWindow
                ))
            } else {
                pairs.append(RegistrationBlockMatchingPair(
                    identifier: input.identifier,
                    fixedLevel: level.0,
                    movingLevel: supportLevel,
                    fixedWindow: baseWindow,
                    movingWindow: prepared.entry.defaultWindow
                ))
            }
        }
        return pairs
    }

    private func dicomInitialGuess() -> RigidTransformState {
        RigidTransformState(
            translationWorld: .zero,
            rotationRadians: .zero
        )
    }

    private func physicalCenterInitialGuess() -> RigidTransformState {
        RigidTransformState(
            translationWorld: baseVolumeCenterWorld - overlayVolumeCenterWorld,
            rotationRadians: .zero
        )
    }

    private func coverageAwareCenterInitialGuess() -> RigidTransformState {
        let centerDelta = baseVolumeCenterWorld - overlayVolumeCenterWorld
        guard isUnequalCoverageThinSlabRegistration() else {
            return RigidTransformState(
                translationWorld: centerDelta,
                rotationRadians: .zero
            )
        }

        let baseVoxelToWorld = fixedVoxelToWorld
        let overlayVoxelToWorld = simd_inverse(movingWorldToVoxel)
        let thinDimensions = baseIsThinSlab ? baseVolumeDimensions : overlayVolumeDimensions
        let thinVoxelToWorld = baseIsThinSlab ? baseVoxelToWorld : overlayVoxelToWorld
        let fullDimensions = baseIsThinSlab ? overlayVolumeDimensions : baseVolumeDimensions
        let fullVoxelToWorld = baseIsThinSlab ? overlayVoxelToWorld : baseVoxelToWorld
        return coverageAwareCenterInitialGuess(
            thinDimensions: thinDimensions,
            thinVoxelToWorld: thinVoxelToWorld,
            fullDimensions: fullDimensions,
            fullVoxelToWorld: fullVoxelToWorld,
            thinSharesBaseFrame: baseIsThinSlab
        )
    }

    private func coverageAwareCenterInitialGuess(
        thinDimensions: SIMD3<Int>,
        thinVoxelToWorld: simd_float4x4,
        fullDimensions: SIMD3<Int>,
        fullVoxelToWorld: simd_float4x4,
        thinSharesBaseFrame: Bool
    ) -> RigidTransformState {
        let thinCenterWorld = volumeCenterWorld(
            dimensions: thinDimensions,
            voxelToWorld: thinVoxelToWorld
        )
        let fullCenterWorld = volumeCenterWorld(
            dimensions: fullDimensions,
            voxelToWorld: fullVoxelToWorld
        )
        let centerDelta = thinSharesBaseFrame
            ? thinCenterWorld - fullCenterWorld
            : fullCenterWorld - thinCenterWorld

        // A targeted slab occupies only one anatomical portion of a larger
        // acquisition. Aligning their volume centers through-plane moves the
        // slab to the middle of the larger volume, which is generally the
        // wrong anatomy. Preserve the DICOM through-plane placement and use
        // center alignment only within the slab plane.
        let thinSlabNormal = slabGeometry(
            dimensions: thinDimensions,
            voxelToWorld: thinVoxelToWorld
        ).normalWorld
        let inPlaneCenterDelta = centerDelta
            - simd_dot(centerDelta, thinSlabNormal) * thinSlabNormal
        return RigidTransformState(
            translationWorld: inPlaneCenterDelta,
            rotationRadians: .zero
        )
    }

    private func crossModalityCoverageSweepInitialGuesses() -> [RigidTransformState] {
        guard isCrossModalityUnequalCoverageRegistration() else { return [] }

        let baseVoxelToWorld = fixedVoxelToWorld
        let overlayVoxelToWorld = simd_inverse(movingWorldToVoxel)
        let thinDimensions = baseIsThinSlab ? baseVolumeDimensions : overlayVolumeDimensions
        let thinVoxelToWorld = baseIsThinSlab ? baseVoxelToWorld : overlayVoxelToWorld
        let fullDimensions = baseIsThinSlab ? overlayVolumeDimensions : baseVolumeDimensions
        let fullVoxelToWorld = baseIsThinSlab ? overlayVoxelToWorld : baseVoxelToWorld
        return coverageSweepInitialGuesses(
            thinDimensions: thinDimensions,
            thinVoxelToWorld: thinVoxelToWorld,
            fullDimensions: fullDimensions,
            fullVoxelToWorld: fullVoxelToWorld,
            thinSharesBaseFrame: baseIsThinSlab,
            minimumCranialFraction: minimumCranialCoverageFraction()
        )
    }

    private func coverageSweepInitialGuesses(
        thinDimensions: SIMD3<Int>,
        thinVoxelToWorld: simd_float4x4,
        fullDimensions: SIMD3<Int>,
        fullVoxelToWorld: simd_float4x4,
        thinSharesBaseFrame: Bool,
        minimumCranialFraction: Float
    ) -> [RigidTransformState] {

        func physicalAxes(
            dimensions: SIMD3<Int>,
            voxelToWorld: simd_float4x4
        ) -> [(direction: SIMD3<Float>, extent: Float, edge: SIMD3<Float>)] {
            let columns = [
                SIMD3<Float>(voxelToWorld.columns.0.x, voxelToWorld.columns.0.y, voxelToWorld.columns.0.z),
                SIMD3<Float>(voxelToWorld.columns.1.x, voxelToWorld.columns.1.y, voxelToWorld.columns.1.z),
                SIMD3<Float>(voxelToWorld.columns.2.x, voxelToWorld.columns.2.y, voxelToWorld.columns.2.z),
            ]
            let counts = [
                Float(max(dimensions.x - 1, 0)),
                Float(max(dimensions.y - 1, 0)),
                Float(max(dimensions.z - 1, 0)),
            ]
            return zip(columns, counts).map { column, count in
                let spacing = simd_length(column)
                let direction = spacing > 0.0001 ? column / spacing : SIMD3<Float>(repeating: 0)
                let edge = column * count
                return (direction, simd_length(edge), edge)
            }
        }

        let thinAxes = physicalAxes(dimensions: thinDimensions, voxelToWorld: thinVoxelToWorld)
        let fullAxes = physicalAxes(dimensions: fullDimensions, voxelToWorld: fullVoxelToWorld)
        guard let thinAxis = thinAxes.enumerated().min(by: { $0.element.extent < $1.element.extent })?.offset else {
            return []
        }

        var sweepDirection = SIMD3<Float>(repeating: 0)
        var availableCenterTravel: Float = 0
        for (axisIndex, thinAxisGeometry) in thinAxes.enumerated() where axisIndex != thinAxis {
            guard simd_length(thinAxisGeometry.direction) > 0.5 else { continue }
            let fullProjectedExtent = fullAxes.reduce(Float(0)) { partial, fullAxisGeometry in
                partial + abs(simd_dot(fullAxisGeometry.edge, thinAxisGeometry.direction))
            }
            let coverageRatio = fullProjectedExtent / max(thinAxisGeometry.extent, 0.0001)
            guard coverageRatio >= 1.5 else { continue }
            let centerTravel = max((fullProjectedExtent - thinAxisGeometry.extent) * 0.5, 0)
            if centerTravel > availableCenterTravel {
                availableCenterTravel = centerTravel
                sweepDirection = thinAxisGeometry.direction
            }
        }

        // The ordinary coarse search covers 24 mm around each seed. Space
        // these coverage seeds no more than 48 mm apart so a targeted slab can
        // find anatomy anywhere along the larger acquisition without turning
        // every unequal-coverage registration into a full 3D grid search.
        let localSearchReach: Float = 24
        guard availableCenterTravel > localSearchReach,
              simd_length(sweepDirection) > 0.5 else {
            return []
        }
        let segmentCount = min(
            max(Int(ceil((2 * availableCenterTravel) / (2 * localSearchReach))), 2),
            6
        )
        let centerState = coverageAwareCenterInitialGuess(
            thinDimensions: thinDimensions,
            thinVoxelToWorld: thinVoxelToWorld,
            fullDimensions: fullDimensions,
            fullVoxelToWorld: fullVoxelToWorld,
            thinSharesBaseFrame: thinSharesBaseFrame
        )
        let thinCenterWorld = volumeCenterWorld(
            dimensions: thinDimensions,
            voxelToWorld: thinVoxelToWorld
        )
        let movingOffsetSign: Float = thinSharesBaseFrame ? -1 : 1
        return (0...segmentCount).compactMap { index in
            let fraction = Float(index) / Float(segmentCount)
            let offset = -availableCenterTravel + 2 * availableCenterTravel * fraction
            var state = centerState
            state.translationWorld += movingOffsetSign * offset * sweepDirection
            if minimumCranialFraction > 0,
               let coverageFraction = cranialCoverageFraction(
                   for: state,
                   thinCenterWorld: thinCenterWorld,
                   thinDimensions: thinDimensions,
                   thinVoxelToWorld: thinVoxelToWorld,
                   fullDimensions: fullDimensions,
                   fullVoxelToWorld: fullVoxelToWorld,
                   thinSharesBaseFrame: thinSharesBaseFrame
               ),
               coverageFraction < minimumCranialFraction {
                return nil
            }
            return state
        }
    }

    private func registrationSupportCoverageSweepInitialGuesses() -> [RigidTransformState] {
        guard isCrossModalityUnequalCoverageRegistration() else { return [] }

        registrationSupportLock.lock()
        let supportInputs = registrationSupportInputs
        let preparedVolumes = preparedRegistrationSupportVolumes
        registrationSupportLock.unlock()
        guard supportInputs.isEmpty == false,
              preparedVolumes.isEmpty == false else {
            return []
        }

        let preparedByIdentifier: [String: PreparedRegistrationSupportVolume] = Dictionary(
            uniqueKeysWithValues: preparedVolumes.map {
                ($0.input.identifier, $0)
            }
        )
        var representedNormals = [SIMD3<Float>]()
        if let primaryNormal = baseIsThinSlab
            ? baseSlabGeometry?.normalWorld
            : overlaySlabGeometry?.normalWorld {
            representedNormals.append(primaryNormal)
        }

        let minimumCranialFraction = minimumCranialCoverageFraction()
        var candidates = [RigidTransformState]()
        for input in supportInputs {
            guard let prepared = preparedByIdentifier[input.identifier] else { continue }
            let thinDimensions = prepared.entry.dimensions
            let thinVoxelToWorld = prepared.entry.voxelToWorld
            guard isThinSlab(
                dimensions: thinDimensions,
                voxelToWorld: thinVoxelToWorld
            ) else {
                continue
            }

            let supportNormal = slabGeometry(
                dimensions: thinDimensions,
                voxelToWorld: thinVoxelToWorld
            ).normalWorld
            guard representedNormals.allSatisfy({
                abs(simd_dot($0, supportNormal)) < 0.9
            }) else {
                continue
            }

            let fullDimensions = input.sharesBaseFrame
                ? overlayVolumeDimensions
                : baseVolumeDimensions
            let fullVoxelToWorld = input.sharesBaseFrame
                ? simd_inverse(movingWorldToVoxel)
                : fixedVoxelToWorld
            guard isThinSlab(
                dimensions: fullDimensions,
                voxelToWorld: fullVoxelToWorld
            ) == false else {
                continue
            }

            let supportCandidates = coverageSweepInitialGuesses(
                thinDimensions: thinDimensions,
                thinVoxelToWorld: thinVoxelToWorld,
                fullDimensions: fullDimensions,
                fullVoxelToWorld: fullVoxelToWorld,
                thinSharesBaseFrame: input.sharesBaseFrame,
                minimumCranialFraction: minimumCranialFraction
            )
            guard supportCandidates.isEmpty == false else { continue }
            representedNormals.append(supportNormal)
            candidates.append(contentsOf: supportCandidates)
        }
        return candidates
    }

    private func centerOfMassInitialGuess() -> RigidTransformState {
        RigidTransformState(
            translationWorld: baseInformativeCenterWorld - overlayInformativeCenterWorld,
            rotationRadians: .zero
        )
    }

    private func automaticRegistrationInitialGuesses() -> [RigidTransformState] {
        var candidates: [RigidTransformState]
        if isUnequalCoverageThinSlabRegistration() {
            candidates = [dicomInitialGuess()]
            let coverageSweepCandidates = crossModalityCoverageSweepInitialGuesses()
            if coverageSweepCandidates.isEmpty {
                candidates.append(coverageAwareCenterInitialGuess())
            } else {
                candidates.append(contentsOf: coverageSweepCandidates)
            }
            candidates.append(contentsOf: registrationSupportCoverageSweepInitialGuesses())
        } else {
            candidates = [
                physicalCenterInitialGuess(),
                dicomInitialGuess(),
                centerOfMassInitialGuess(),
            ]
        }
        var distinctCandidates: [RigidTransformState] = []
        for candidate in candidates {
            let isDuplicate = distinctCandidates.contains { existing in
                simd_length(existing.translationWorld - candidate.translationWorld) < 0.01
                    && simd_length(existing.rotationRadians - candidate.rotationRadians) < 0.0001
            }
            if isDuplicate == false {
                distinctCandidates.append(candidate)
            }
        }
        return distinctCandidates
    }

    private func runRegistration(
        startingAt initialState: RigidTransformState? = nil,
        additionalInitialStates: [RigidTransformState] = [],
        samplingMode requestedSamplingMode: RegistrationSamplingMode,
        searchMode: RegistrationSearchMode = .full
    ) {
        let levelPairs = currentRegistrationLevelPairs()
        guard levelPairs.isEmpty == false else { return }

        let supportsFastWholeVolumeRegistration = isCTToCTRegistration()
            && baseIsThinSlab == false
            && overlayIsThinSlab == false
        let supportsFastSlabRegistration = levelPairs.last.map {
            slabFastSamplingStride(for: $0) != nil
        } ?? false
        let samplingMode: RegistrationSamplingMode = requestedSamplingMode == .fast
            && (supportsFastWholeVolumeRegistration || supportsFastSlabRegistration)
            ? .fast
            : .reference
        let initialGuesses = initialState.map { [$0] } ?? automaticRegistrationInitialGuesses()
        var supplementalInitialGuesses: [RigidTransformState] = []
        if initialState == nil {
            for candidate in additionalInitialStates {
                let existingCandidates = initialGuesses + supplementalInitialGuesses
                let isDuplicate = existingCandidates.contains { existing in
                    simd_length(existing.translationWorld - candidate.translationWorld) < 0.01
                        && simd_length(existing.rotationRadians - candidate.rotationRadians) < 0.0001
                }
                if isDuplicate == false {
                    supplementalInitialGuesses.append(candidate)
                }
            }
        }
        guard let initialGuess = initialGuesses.first else { return }
        invalidateActiveRegistrationJob()
        let job = RegistrationJob(
            generation: registrationGeneration,
            refinementTranslationAnchor: searchMode == .refinement
                ? initialGuess.translationWorld
                : nil,
            refinementRotationAnchor: searchMode == .refinement
                ? initialGuess.rotationRadians
                : nil
        )
        activeRegistrationJob = job
        publishRegistrationUpdate(
            state: initialGuess,
            inProgress: true,
            progress: 0,
            message: searchMode == .refinement
                ? "Refining 3D"
                : (samplingMode == .fast ? "Registering 3D Fast" : "Registering 3D Reference"),
            residualError: nil,
            generation: job.generation
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, job.isCancelled == false else { return }
            let result = self.optimizeOverlayTransform(
                startingAt: initialGuesses,
                supplementalInitialGuesses: supplementalInitialGuesses,
                job: job,
                levelPairs: levelPairs,
                samplingMode: samplingMode,
                searchMode: searchMode
            )
            guard job.isCancelled == false else { return }

            DispatchQueue.main.async {
                guard job.isCancelled == false,
                      job.generation == self.registrationGeneration,
                      self.activeRegistrationJob === job else { return }
                self.activeRegistrationJob = nil
                self.publishRegistrationUpdate(
                    state: result.state,
                    inProgress: false,
                    progress: 1,
                    message: searchMode == .refinement ? "Refined 3D" : "Registered 3D",
                    residualError: result.metric,
                    generation: job.generation
                )
            }
        }
    }

    private func blockMatchingInitialGuess(
        startingAt initialState: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        metric: BlockMatchingMetric,
        job: RegistrationJob
    ) -> RigidTransformState? {
        blockMatchingInitialGuess(
            startingAt: initialState,
            fixedLevel: level.0,
            movingLevel: level.1,
            fixedWindow: MetalViewerWindowLevel(
                level: baseRegistrationWindowLevel,
                width: max(baseRegistrationWindowWidth, 1)
            ),
            movingWindow: MetalViewerWindowLevel(
                level: overlayRegistrationWindowLevel,
                width: max(overlayRegistrationWindowWidth, 1)
            ),
            metric: metric,
            job: job
        )
    }

    private func blockMatchingInitialGuess(
        startingAt initialState: RigidTransformState,
        fixedLevel: VolumeLevel,
        movingLevel: VolumeLevel,
        fixedWindow: MetalViewerWindowLevel,
        movingWindow: MetalViewerWindowLevel,
        metric: BlockMatchingMetric,
        job: RegistrationJob
    ) -> RigidTransformState? {
        guard job.isCancelled == false else { return nil }
        let fixedSpacing = voxelSpacing(from: fixedLevel.voxelToWorld)
        let movingSpacing = voxelSpacing(from: movingLevel.voxelToWorld)

        func sparseStride(spacing: Float) -> UInt32 {
            UInt32(min(max(Int(ceil(18 / max(spacing, 0.0001))), 2), 10))
        }
        func blockRadius(spacing: Float) -> UInt32 {
            let maximumRadius = metric == .gradientMagnitudeNCC ? 1 : 2
            return UInt32(min(max(Int(ceil(5 / max(spacing, 0.0001))), 1), maximumRadius))
        }
        func searchRadius(spacing: Float) -> UInt32 {
            UInt32(min(max(Int(ceil(18 / max(spacing, 0.0001))), 1), 5))
        }

        let blockStride = SIMD3<UInt32>(
            sparseStride(spacing: fixedSpacing.x),
            sparseStride(spacing: fixedSpacing.y),
            sparseStride(spacing: fixedSpacing.z)
        )
        let blockRadii = SIMD3<UInt32>(
            blockRadius(spacing: fixedSpacing.x),
            blockRadius(spacing: fixedSpacing.y),
            blockRadius(spacing: fixedSpacing.z)
        )
        let searchRadii = SIMD3<UInt32>(
            searchRadius(spacing: movingSpacing.x),
            searchRadius(spacing: movingSpacing.y),
            searchRadius(spacing: movingSpacing.z)
        )
        let fixedDimensions = fixedLevel.dimensions
        let blockGrid = SIMD3<Int>(
            (fixedDimensions.x + Int(blockStride.x) - 1) / Int(blockStride.x),
            (fixedDimensions.y + Int(blockStride.y) - 1) / Int(blockStride.y),
            (fixedDimensions.z + Int(blockStride.z) - 1) / Int(blockStride.z)
        )
        let resultCount = blockGrid.x * blockGrid.y * blockGrid.z
        guard resultCount >= 8,
              let resultBuffer = deviceRef.makeBuffer(
                length: resultCount * MemoryLayout<BlockMatchResult>.stride,
                options: .storageModeShared
              ) else {
            return nil
        }
        memset(resultBuffer.contents(), 0, resultBuffer.length)

        let fixedToMovingTexture = registrationTextureCoordinateMatrix(
            for: initialState,
            fixedVoxelToWorld: fixedLevel.voxelToWorld,
            movingWorldToVoxel: simd_inverse(movingLevel.voxelToWorld),
            movingTextureSize: movingLevel.dimensions
        )
        var uniforms = BlockMatchingUniforms(
            windows: SIMD4<Float>(
                fixedWindow.level,
                max(fixedWindow.width, 1),
                movingWindow.level,
                max(movingWindow.width, 1)
            ),
            baseTextureSize: SIMD4<UInt32>(
                UInt32(max(fixedDimensions.x, 1)),
                UInt32(max(fixedDimensions.y, 1)),
                UInt32(max(fixedDimensions.z, 1)),
                0
            ),
            movingTextureSize: SIMD4<UInt32>(
                UInt32(max(movingLevel.dimensions.x, 1)),
                UInt32(max(movingLevel.dimensions.y, 1)),
                UInt32(max(movingLevel.dimensions.z, 1)),
                0
            ),
            blockStrideAndFlags: SIMD4<UInt32>(
                blockStride.x,
                blockStride.y,
                blockStride.z,
                metric.rawValue
            ),
            blockRadius: SIMD4<UInt32>(blockRadii.x, blockRadii.y, blockRadii.z, 0),
            searchRadius: SIMD4<UInt32>(searchRadii.x, searchRadii.y, searchRadii.z, 0),
            fixedVoxelToMovingTexture: fixedToMovingTexture
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(registrationBlockMatchingPipelineState)
        encoder.setTexture(fixedLevel.texture, index: 0)
        encoder.setTexture(movingLevel.texture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<BlockMatchingUniforms>.stride, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: blockGrid.x, height: blockGrid.y, depth: blockGrid.z),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 2)
        )
        encoder.endEncoding()
        guard job.isCancelled == false else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard job.isCancelled == false,
              commandBuffer.status == .completed else { return nil }

        let results = resultBuffer.contents().bindMemory(
            to: BlockMatchResult.self,
            capacity: resultCount
        )
        let minimumScore: Float
        switch metric {
        case .intensityNCC:
            minimumScore = 0.25
        case .gradientMagnitudeNCC:
            minimumScore = 0.12
        case .mindSelfSimilarity:
            minimumScore = 0.35
        }
        var correspondences: [BlockCorrespondence] = []
        correspondences.reserveCapacity(min(resultCount, 512))
        let movingDimensions = SIMD3<Float>(
            Float(max(movingLevel.dimensions.x, 1)),
            Float(max(movingLevel.dimensions.y, 1)),
            Float(max(movingLevel.dimensions.z, 1))
        )

        for z in 0..<blockGrid.z {
            guard job.isCancelled == false else { return nil }
            for y in 0..<blockGrid.y {
                for x in 0..<blockGrid.x {
                    let index = (z * blockGrid.y + y) * blockGrid.x + x
                    let result = results[index]
                    let score = result.displacementAndScore.w
                    guard result.quality.w > 0,
                          score.isFinite,
                          score >= minimumScore else {
                        continue
                    }

                    let fixedVoxel = SIMD3<Float>(
                        Float(min(x * Int(blockStride.x) + Int(blockStride.x) / 2, fixedDimensions.x - 1)),
                        Float(min(y * Int(blockStride.y) + Int(blockStride.y) / 2, fixedDimensions.y - 1)),
                        Float(min(z * Int(blockStride.z) + Int(blockStride.z) / 2, fixedDimensions.z - 1))
                    )
                    let predictedMovingTexture = fixedToMovingTexture * SIMD4<Float>(fixedVoxel, 1)
                    let movingVoxel = SIMD3<Float>(
                        predictedMovingTexture.x * movingDimensions.x - 0.5 + result.displacementAndScore.x,
                        predictedMovingTexture.y * movingDimensions.y - 0.5 + result.displacementAndScore.y,
                        predictedMovingTexture.z * movingDimensions.z - 0.5 + result.displacementAndScore.z
                    )
                    guard movingVoxel.x >= 0,
                          movingVoxel.x < movingDimensions.x,
                          movingVoxel.y >= 0,
                          movingVoxel.y < movingDimensions.y,
                          movingVoxel.z >= 0,
                          movingVoxel.z < movingDimensions.z else {
                        continue
                    }

                    let fixedWorld4 = fixedLevel.voxelToWorld * SIMD4<Float>(fixedVoxel, 1)
                    let movingWorld4 = movingLevel.voxelToWorld * SIMD4<Float>(movingVoxel, 1)
                    correspondences.append(BlockCorrespondence(
                        movingWorld: SIMD3<Float>(movingWorld4.x, movingWorld4.y, movingWorld4.z),
                        fixedWorld: SIMD3<Float>(fixedWorld4.x, fixedWorld4.y, fixedWorld4.z),
                        score: score,
                        distinctiveness: max(result.quality.y, 0)
                    ))
                }
            }
        }

        if correspondences.count > 512 {
            correspondences.sort {
                ($0.score + min($0.distinctiveness, 0.1))
                    > ($1.score + min($1.distinctiveness, 0.1))
            }
            correspondences.removeSubrange(512..<correspondences.count)
        }
        guard let refinedState = robustRigidState(
            from: correspondences,
            startingAt: initialState,
            job: job
        ) else {
            return nil
        }
        return refinedState
    }

    private func robustRigidState(
        from correspondences: [BlockCorrespondence],
        startingAt initialState: RigidTransformState,
        job: RegistrationJob
    ) -> RigidTransformState? {
        guard correspondences.count >= 8,
              job.isCancelled == false else { return nil }

        func median(_ values: [Float]) -> Float {
            guard values.isEmpty == false else { return .greatestFiniteMagnitude }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return 0.5 * (sorted[middle - 1] + sorted[middle])
            }
            return sorted[middle]
        }

        func residualDistances(for state: RigidTransformState) -> [Float] {
            correspondences.map {
                simd_length($0.fixedWorld - transformedOverlayPointWorld($0.movingWorld, for: state))
            }
        }

        var state = initialState
        let initialMedianResidual = median(residualDistances(for: state))
        let rotationDerivativeStep: Float = 0.001

        for _ in 0..<5 {
            guard job.isCancelled == false else { return nil }
            let transformedPoints = correspondences.map {
                transformedOverlayPointWorld($0.movingWorld, for: state)
            }
            let distances = zip(correspondences, transformedPoints).map {
                simd_length($0.0.fixedWorld - $0.1)
            }
            let medianResidual = median(distances)
            let medianAbsoluteDeviation = median(distances.map { abs($0 - medianResidual) })
            let robustScale = max(1.4826 * medianAbsoluteDeviation, 0.75)
            let trimIndex = min(
                max(Int(Float(distances.count - 1) * 0.8), 0),
                distances.count - 1
            )
            let trimmedCutoff = distances.sorted()[trimIndex]
            let tukeyCutoff = max(4.685 * robustScale, 2)
            let residualCutoff = min(max(trimmedCutoff, 2), tukeyCutoff)

            var normal = Array(repeating: Array(repeating: Double(0), count: 6), count: 6)
            var rightHandSide = Array(repeating: Double(0), count: 6)
            var contributingMatches = 0

            for (index, correspondence) in correspondences.enumerated() {
                guard job.isCancelled == false else { return nil }
                let distance = distances[index]
                guard distance <= residualCutoff else { continue }
                let normalizedResidual = distance / max(tukeyCutoff, 0.0001)
                let tukeyBase = max(1 - normalizedResidual * normalizedResidual, 0)
                let tukeyWeight = tukeyBase * tukeyBase
                let scoreWeight = max(correspondence.score, 0.05)
                    * (0.5 + min(correspondence.distinctiveness * 5, 0.5))
                let weight = Double(tukeyWeight * scoreWeight)
                guard weight > 0 else { continue }

                let transformed = transformedPoints[index]
                let residual = correspondence.fixedWorld - transformed
                var rotationDerivatives = [SIMD3<Float>]()
                rotationDerivatives.reserveCapacity(3)
                for axis in 0..<3 {
                    var perturbedState = state
                    perturbedState.rotationRadians[axis] += rotationDerivativeStep
                    let perturbed = transformedOverlayPointWorld(
                        correspondence.movingWorld,
                        for: perturbedState
                    )
                    rotationDerivatives.append((perturbed - transformed) / rotationDerivativeStep)
                }

                for component in 0..<3 {
                    let jacobian = [
                        component == 0 ? Float(1) : Float(0),
                        component == 1 ? Float(1) : Float(0),
                        component == 2 ? Float(1) : Float(0),
                        rotationDerivatives[0][component],
                        rotationDerivatives[1][component],
                        rotationDerivatives[2][component],
                    ]
                    for row in 0..<6 {
                        rightHandSide[row] += weight * Double(jacobian[row] * residual[component])
                        for column in row..<6 {
                            normal[row][column] += weight * Double(jacobian[row] * jacobian[column])
                        }
                    }
                }
                contributingMatches += 1
            }
            guard contributingMatches >= 6 else { return nil }
            for row in 0..<6 {
                for column in 0..<row {
                    normal[row][column] = normal[column][row]
                }
                normal[row][row] += row < 3 ? 1e-5 : 1e-3
            }
            guard var delta = solveSixBySix(normal, rightHandSide) else { return nil }

            let translationDelta = SIMD3<Float>(Float(delta[0]), Float(delta[1]), Float(delta[2]))
            let translationLength = simd_length(translationDelta)
            if translationLength > 8 {
                let scale = Double(8 / translationLength)
                for index in 0..<3 { delta[index] *= scale }
            }
            let rotationDelta = SIMD3<Float>(Float(delta[3]), Float(delta[4]), Float(delta[5]))
            let rotationLength = simd_length(rotationDelta)
            let maximumRotationStep = Float(3) * .pi / 180
            if rotationLength > maximumRotationStep {
                let scale = Double(maximumRotationStep / rotationLength)
                for index in 3..<6 { delta[index] *= scale }
            }

            state.translationWorld += SIMD3<Float>(Float(delta[0]), Float(delta[1]), Float(delta[2]))
            state.rotationRadians += SIMD3<Float>(Float(delta[3]), Float(delta[4]), Float(delta[5]))
            if simd_length(SIMD3<Float>(Float(delta[0]), Float(delta[1]), Float(delta[2]))) < 0.05,
               simd_length(SIMD3<Float>(Float(delta[3]), Float(delta[4]), Float(delta[5]))) < 0.02 * .pi / 180 {
                break
            }
        }

        let finalMedianResidual = median(residualDistances(for: state))
        guard finalMedianResidual.isFinite,
              finalMedianResidual < initialMedianResidual,
              finalMedianResidual <= max(initialMedianResidual * 0.9, 1.5) else {
            return nil
        }
        return state
    }

    private func solveSixBySix(
        _ matrix: [[Double]],
        _ rightHandSide: [Double]
    ) -> [Double]? {
        guard matrix.count == 6,
              matrix.allSatisfy({ $0.count == 6 }),
              rightHandSide.count == 6 else {
            return nil
        }
        var augmented = matrix.enumerated().map { row, values in
            values + [rightHandSide[row]]
        }
        for pivotColumn in 0..<6 {
            guard let pivotRow = (pivotColumn..<6).max(by: {
                abs(augmented[$0][pivotColumn]) < abs(augmented[$1][pivotColumn])
            }),
                  abs(augmented[pivotRow][pivotColumn]) > 1e-10 else {
                return nil
            }
            if pivotRow != pivotColumn {
                augmented.swapAt(pivotRow, pivotColumn)
            }
            let pivot = augmented[pivotColumn][pivotColumn]
            for column in pivotColumn...6 {
                augmented[pivotColumn][column] /= pivot
            }
            for row in 0..<6 where row != pivotColumn {
                let factor = augmented[row][pivotColumn]
                guard factor != 0 else { continue }
                for column in pivotColumn...6 {
                    augmented[row][column] -= factor * augmented[pivotColumn][column]
                }
            }
        }
        let solution = augmented.map { $0[6] }
        return solution.allSatisfy(\.isFinite) ? solution : nil
    }

    private func optimizeOverlayTransform(
        startingAt initialGuesses: [RigidTransformState],
        supplementalInitialGuesses: [RigidTransformState],
        job: RegistrationJob,
        levelPairs: [(VolumeLevel, VolumeLevel)],
        samplingMode: RegistrationSamplingMode,
        searchMode: RegistrationSearchMode
    ) -> (state: RigidTransformState, metric: Float) {
        struct RigidStep {
            let translationMM: Float
            let rotationRadians: Float
            let maxIterations: Int
            let allowsRotation: Bool
        }

        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let ctToCTRegistration = isCTToCTRegistration()
        let rigidSteps: [RigidStep]
        if ctToCTRegistration && slabAwareRegistration {
            rigidSteps = [
                RigidStep(translationMM: 12, rotationRadians: 0, maxIterations: 14, allowsRotation: false),
                RigidStep(translationMM: 6, rotationRadians: 1.5 * .pi / 180, maxIterations: 12, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.4 * .pi / 180, maxIterations: 10, allowsRotation: true)
            ]
        } else if ctToCTRegistration {
            rigidSteps = [
                RigidStep(translationMM: 24, rotationRadians: 6 * .pi / 180, maxIterations: 18, allowsRotation: true),
                RigidStep(translationMM: 8, rotationRadians: 2 * .pi / 180, maxIterations: 14, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.5 * .pi / 180, maxIterations: 10, allowsRotation: true)
            ]
        } else if slabAwareRegistration {
            rigidSteps = [
                RigidStep(translationMM: 12, rotationRadians: 0, maxIterations: 24, allowsRotation: false),
                RigidStep(translationMM: 8, rotationRadians: 0, maxIterations: 20, allowsRotation: false),
                RigidStep(translationMM: 6, rotationRadians: 2 * .pi / 180, maxIterations: 20, allowsRotation: true),
                RigidStep(translationMM: 4, rotationRadians: 1.2 * .pi / 180, maxIterations: 18, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.6 * .pi / 180, maxIterations: 16, allowsRotation: true),
                RigidStep(translationMM: 1, rotationRadians: 0.25 * .pi / 180, maxIterations: 14, allowsRotation: true)
            ]
        } else {
            rigidSteps = [
                RigidStep(translationMM: 40, rotationRadians: 12 * .pi / 180, maxIterations: 32, allowsRotation: true),
                RigidStep(translationMM: 20, rotationRadians: 6 * .pi / 180, maxIterations: 28, allowsRotation: true),
                RigidStep(translationMM: 10, rotationRadians: 3 * .pi / 180, maxIterations: 24, allowsRotation: true),
                RigidStep(translationMM: 5, rotationRadians: 1.5 * .pi / 180, maxIterations: 20, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.75 * .pi / 180, maxIterations: 18, allowsRotation: true),
                RigidStep(translationMM: 1, rotationRadians: 0.35 * .pi / 180, maxIterations: 16, allowsRotation: true)
            ]
        }

        guard initialGuesses.isEmpty == false,
              levelPairs.isEmpty == false,
              job.isCancelled == false else {
            return (dicomInitialGuess(), .greatestFiniteMagnitude)
        }
        let coarseSamplingStride = registrationSamplingStride(
            for: levelPairs[0],
            samplingMode: samplingMode
        )
        var coarseInitialGuesses = initialGuesses
        if searchMode == .full, slabAwareRegistration {
            let defaultBlockMetric: BlockMatchingMetric =
                isCTRegistrationVolume(pixList) != isCTRegistrationVolume(overlayPixList)
                    || isCrossPlaneThinSlabRegistration()
                ? .gradientMagnitudeNCC
                : .intensityNCC
            var blockMetrics = [defaultBlockMetric]
            if usesContrastInvariantMRSlabMatching(),
               blockMetrics.contains(.mindSelfSimilarity) == false {
                blockMetrics.append(.mindSelfSimilarity)
            }
            for initialGuess in initialGuesses.prefix(2) {
                for blockMetric in blockMetrics {
                    guard let blockMatchedGuess = blockMatchingInitialGuess(
                        startingAt: initialGuess,
                        level: levelPairs[0],
                        metric: blockMetric,
                        job: job
                    ) else {
                        continue
                    }
                    let isDuplicate = coarseInitialGuesses.contains { existing in
                        simd_length(existing.translationWorld - blockMatchedGuess.translationWorld) < 0.1
                            && simd_length(existing.rotationRadians - blockMatchedGuess.rotationRadians) < 0.02 * .pi / 180
                    }
                    if isDuplicate == false {
                        coarseInitialGuesses.append(blockMatchedGuess)
                    }
                }
            }

            let supportContext = registrationSupportMetricContext(
                for: levelPairs[0],
                levelIndex: 0,
                totalLevels: levelPairs.count
            )
            let supportBlockPairs = registrationSupportBlockMatchingPairs(
                for: levelPairs[0],
                levelIndex: 0,
                totalLevels: levelPairs.count
            )
            if supportContext.pairs.isEmpty == false,
               supportBlockPairs.isEmpty == false,
               job.isCancelled == false {
                let supportMetrics = registrationSupportMetricValues(
                    for: initialGuesses,
                    pairs: supportContext.pairs,
                    levelIndex: 0,
                    totalLevels: levelPairs.count,
                    useBoneOnly: shouldUseBoneOnlyMetric(
                        forLevelIndex: 0,
                        totalLevels: levelPairs.count
                    ),
                    samplingStride: coarseSamplingStride,
                    job: job
                )
                for blockPair in supportBlockPairs {
                    guard let metricIndex = supportContext.pairs.firstIndex(where: {
                        $0.identifier == blockPair.identifier
                    }),
                          metricIndex < supportMetrics.count else {
                        continue
                    }

                    var rankedSeeds = [(state: RigidTransformState, metric: Float)]()
                    for (stateIndex, state) in initialGuesses.enumerated() {
                        guard stateIndex < supportMetrics[metricIndex].count,
                              let metric = supportMetrics[metricIndex][stateIndex],
                              metric.isFinite,
                              metric < Float.greatestFiniteMagnitude / 2 else {
                            continue
                        }
                        rankedSeeds.append((state: state, metric: metric))
                    }
                    rankedSeeds.sort { $0.metric < $1.metric }

                    for rankedSeed in rankedSeeds.prefix(2) {
                        for blockMetric in blockMetrics {
                            guard let blockMatchedGuess = blockMatchingInitialGuess(
                                startingAt: rankedSeed.state,
                                fixedLevel: blockPair.fixedLevel,
                                movingLevel: blockPair.movingLevel,
                                fixedWindow: blockPair.fixedWindow,
                                movingWindow: blockPair.movingWindow,
                                metric: blockMetric,
                                job: job
                            ) else {
                                continue
                            }
                            let isDuplicate = coarseInitialGuesses.contains { existing in
                                simd_length(
                                    existing.translationWorld - blockMatchedGuess.translationWorld
                                ) < 0.1
                                    && simd_length(
                                        existing.rotationRadians - blockMatchedGuess.rotationRadians
                                    ) < 0.02 * .pi / 180
                            }
                            if isDuplicate == false {
                                coarseInitialGuesses.append(blockMatchedGuess)
                            }
                        }
                    }
                }
            }
        }

        let levelIndices: [Int]
        if searchMode == .refinement {
            levelIndices = Array(max(levelPairs.count - 2, 0)..<levelPairs.count)
        } else {
            levelIndices = Array(levelPairs.indices)
        }
        guard let firstLevelIndex = levelIndices.first else {
            return (initialGuesses[0], .greatestFiniteMagnitude)
        }

        let seeded: (state: RigidTransformState, metric: Float)
        if searchMode == .full {
            seeded = coarseSeedSearch(
                startingAt: coarseInitialGuesses,
                supplementalStates: supplementalInitialGuesses,
                level: levelPairs[0],
                totalLevels: levelPairs.count,
                ctToCTRegistration: ctToCTRegistration,
                samplingStride: coarseSamplingStride,
                job: job
            )
        } else {
            let firstLevel = levelPairs[firstLevelIndex]
            let firstLevelSamplingStride = registrationSamplingStride(
                for: firstLevel,
                samplingMode: samplingMode
            )
            let initialState = initialGuesses[0]
            seeded = (
                state: initialState,
                metric: metricValue(
                    for: initialState,
                    level: firstLevel,
                    levelIndex: firstLevelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: shouldUseBoneOnlyMetric(
                        forLevelIndex: firstLevelIndex,
                        totalLevels: levelPairs.count
                    ),
                    samplingStride: firstLevelSamplingStride,
                    job: job
                )
            )
        }
        var best = seeded.state
        var bestMetric = seeded.metric

        for (levelOrdinal, levelIndex) in levelIndices.enumerated() {
            guard job.isCancelled == false else { return (best, bestMetric) }
            let levelPair = levelPairs[levelIndex]
            let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: levelIndex, totalLevels: levelPairs.count)
            let searchSamplingStride = registrationSamplingStride(
                for: levelPair,
                samplingMode: samplingMode
            )
            let isFinalFullResolutionLevel = levelIndex == levelPairs.count - 1
            let stepsForLevel: [RigidStep]
            if searchMode == .refinement {
                stepsForLevel = [
                    RigidStep(
                        translationMM: 2,
                        rotationRadians: 0.5 * .pi / 180,
                        maxIterations: 12,
                        allowsRotation: true
                    ),
                    RigidStep(
                        translationMM: 1,
                        rotationRadians: 0.25 * .pi / 180,
                        maxIterations: 14,
                        allowsRotation: true
                    ),
                ]
            } else {
                stepsForLevel = isFinalFullResolutionLevel && rigidSteps.count > 3
                    ? Array(rigidSteps.suffix(3))
                    : rigidSteps
            }

            for (stepIndex, step) in stepsForLevel.enumerated() {
                guard job.isCancelled == false else { return (best, bestMetric) }
                let result = optimizeLevelWithNelderMead(
                    startingAt: best,
                    level: levelPair,
                    levelIndex: levelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    translationMM: step.translationMM,
                    rotationRadians: step.rotationRadians,
                    allowsRotation: step.allowsRotation,
                    maxIterations: step.maxIterations,
                    job: job,
                    stepIndex: stepIndex,
                    totalSteps: stepsForLevel.count,
                    samplingStride: searchSamplingStride,
                    speculativelyBatchCandidates: ctToCTRegistration == false
                )
                best = result.state
                bestMetric = result.metric

                let totalStageCount: Int
                let completedStagesBeforeLevel: Int
                if searchMode == .refinement {
                    totalStageCount = levelIndices.count * stepsForLevel.count
                    completedStagesBeforeLevel = levelOrdinal * stepsForLevel.count
                } else {
                    totalStageCount = levelPairs.enumerated().reduce(0) { partial, item in
                        let itemIsFinalFullResolutionLevel = item.offset == levelPairs.count - 1
                        return partial + (itemIsFinalFullResolutionLevel && rigidSteps.count > 3 ? 3 : rigidSteps.count)
                    }
                    completedStagesBeforeLevel = levelPairs.prefix(levelIndex).enumerated().reduce(0) { partial, item in
                        let itemIsFinalFullResolutionLevel = item.offset == levelPairs.count - 1
                        return partial + (itemIsFinalFullResolutionLevel && rigidSteps.count > 3 ? 3 : rigidSteps.count)
                    }
                }
                let completedStages = Float(completedStagesBeforeLevel + stepIndex + 1)
                let progress = completedStages / Float(max(totalStageCount, 1))
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: progress,
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count)",
                    residualError: bestMetric,
                    generation: job.generation
                )
            }

            let usesFastSlabRefinement = samplingMode == .fast && slabAwareRegistration
            if ctToCTRegistration || usesFastSlabRefinement {
                let refinementSamplingStride = samplingMode == .fast && isFinalFullResolutionLevel
                    ? SIMD3<Int>(repeating: 1)
                    : searchSamplingStride
                if refinementSamplingStride != searchSamplingStride {
                    bestMetric = metricValue(
                        for: best,
                        level: levelPair,
                        levelIndex: levelIndex,
                        totalLevels: levelPairs.count,
                        useBoneOnly: useBoneOnly,
                        samplingStride: refinementSamplingStride,
                        job: job
                    )
                }
                let refinement = batchedDescentRefinement(
                    startingAt: best,
                    startingMetric: bestMetric,
                    level: levelPair,
                    levelIndex: levelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    job: job,
                    samplingStride: refinementSamplingStride,
                    includeCombinedRotationCandidates: ctToCTRegistration
                )
                best = refinement.state
                bestMetric = refinement.metric
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: Float(levelIndex + 1) / Float(max(levelPairs.count, 1)),
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count) polish",
                    residualError: bestMetric,
                    generation: job.generation
                )
            } else {
                let refinement = smoothDescentRefinement(
                    startingAt: best,
                    startingMetric: bestMetric,
                    level: levelPair,
                    levelIndex: levelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    job: job,
                    samplingStride: searchSamplingStride
                )
                best = refinement.state
                bestMetric = refinement.metric
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: Float(levelIndex + 1) / Float(max(levelPairs.count, 1)),
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count) refine",
                    residualError: bestMetric,
                    generation: job.generation
                )
            }
        }

        if slabAwareRegistration,
           ctToCTRegistration == false,
           let finalLevel = levelPairs.last {
            // Repeating registration from the displayed transform used to
            // improve some limited-coverage MR pairs because it restarted the
            // local optimizer after the first pass exhausted its iteration
            // budget. Continue that same local search automatically at full
            // resolution, without reopening the wide seed search.
            let finalLevelIndex = levelPairs.count - 1
            let useBoneOnly = shouldUseBoneOnlyMetric(
                forLevelIndex: finalLevelIndex,
                totalLevels: levelPairs.count
            )
            let exactSamplingStride = SIMD3<Int>(repeating: 1)
            let maximumContinuationPasses = 2

            for continuationIndex in 0..<maximumContinuationPasses {
                guard job.isCancelled == false else { return (best, bestMetric) }
                let startingState = best
                let startingMetric = bestMetric
                let simplexResult = optimizeLevelWithNelderMead(
                    startingAt: best,
                    level: finalLevel,
                    levelIndex: finalLevelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    translationMM: 1,
                    rotationRadians: 0.25 * .pi / 180,
                    allowsRotation: true,
                    maxIterations: 18,
                    job: job,
                    stepIndex: continuationIndex,
                    totalSteps: maximumContinuationPasses,
                    samplingStride: exactSamplingStride,
                    speculativelyBatchCandidates: true
                )
                if simplexResult.metric.isFinite,
                   simplexResult.metric < bestMetric {
                    best = simplexResult.state
                    bestMetric = simplexResult.metric
                }

                let descentResult = smoothDescentRefinement(
                    startingAt: best,
                    startingMetric: bestMetric,
                    level: finalLevel,
                    levelIndex: finalLevelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    job: job,
                    samplingStride: exactSamplingStride
                )
                if descentResult.metric.isFinite,
                   descentResult.metric < bestMetric {
                    best = descentResult.state
                    bestMetric = descentResult.metric
                }

                let metricImprovement = max(startingMetric - bestMetric, 0)
                let translationChange = simd_length(
                    best.translationWorld - startingState.translationWorld
                )
                let rotationChangeDegrees = simd_length(
                    best.rotationRadians - startingState.rotationRadians
                ) * 180 / .pi
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: 0.98 + 0.01 * Float(continuationIndex + 1),
                    message: "Registering 3D final polish",
                    residualError: bestMetric,
                    generation: job.generation
                )

                let meaningfulMetricImprovement = metricImprovement >= 0.00005
                let meaningfulTransformChange = translationChange >= 0.05
                    || rotationChangeDegrees >= 0.02
                if meaningfulMetricImprovement == false
                    || meaningfulTransformChange == false {
                    break
                }
            }
        }

        return (best, bestMetric)
    }

    private func coarseSeedSearch(
        startingAt initialStates: [RigidTransformState],
        supplementalStates: [RigidTransformState],
        level: (VolumeLevel, VolumeLevel),
        totalLevels: Int,
        ctToCTRegistration: Bool,
        samplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> (state: RigidTransformState, metric: Float) {
        guard job.isCancelled == false else {
            return (initialStates.first ?? dicomInitialGuess(), .greatestFiniteMagnitude)
        }
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let seedDistance: Float = slabAwareRegistration ? 24 : 60
        let translationSeeds: [SIMD3<Float>]
        if ctToCTRegistration {
            translationSeeds = [
                SIMD3<Float>(repeating: 0),
                SIMD3<Float>(-seedDistance, 0, 0),
                SIMD3<Float>(seedDistance, 0, 0),
                SIMD3<Float>(0, -seedDistance, 0),
                SIMD3<Float>(0, seedDistance, 0),
                SIMD3<Float>(0, 0, -seedDistance),
                SIMD3<Float>(0, 0, seedDistance)
            ]
        } else {
            let translationOffsets: [Float] = [-seedDistance, 0, seedDistance]
            var seeds: [SIMD3<Float>] = []
            for xOffset in translationOffsets {
                for yOffset in translationOffsets {
                    for zOffset in translationOffsets {
                        seeds.append(SIMD3<Float>(xOffset, yOffset, zOffset))
                    }
                }
            }
            translationSeeds = seeds
        }
        let rotationSeeds = coarseRotationSeeds(forCTToCTRegistration: ctToCTRegistration, slabAwareRegistration: slabAwareRegistration)
        let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: 0, totalLevels: totalLevels)
        let centerStates = initialStates + supplementalStates
        let initialMetrics = metricValues(
            for: centerStates,
            level: level,
            levelIndex: 0,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly,
            samplingStride: samplingStride,
            job: job
        )
        var bestCenterState = initialStates.first ?? dicomInitialGuess()
        var bestCenterMetric = Float.greatestFiniteMagnitude
        for (candidate, candidateMetric) in zip(centerStates, initialMetrics) {
            if candidateMetric < bestCenterMetric {
                bestCenterMetric = candidateMetric
                bestCenterState = candidate
            }
        }

        var candidateStates: [RigidTransformState] = []
        candidateStates.reserveCapacity(initialStates.count * translationSeeds.count * rotationSeeds.count)
        // Search every current-series DICOM/physical/informative center rather
        // than committing to one basin early. A transform learned from another
        // series is evaluated above, but it does not create another wide search
        // neighborhood; the current series must support that transform as-is
        // before the ordinary multiresolution refinement can select it.
        for initialState in initialStates {
            guard job.isCancelled == false else { return (bestCenterState, bestCenterMetric) }
            for translationSeed in translationSeeds {
                for rotationSeed in rotationSeeds {
                    var candidate = initialState
                    candidate.translationWorld += translationSeed
                    candidate.rotationRadians += rotationSeed
                    candidateStates.append(candidate)
                }
            }
        }
        let candidateMetrics = metricValues(
            for: candidateStates,
            level: level,
            levelIndex: 0,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly,
            samplingStride: samplingStride,
            job: job
        )

        var bestState = bestCenterState
        var bestMetric = bestCenterMetric
        for (candidate, candidateMetric) in zip(candidateStates, candidateMetrics) {
            if candidateMetric < bestMetric {
                bestMetric = candidateMetric
                bestState = candidate
            }
        }

        return (bestState, bestMetric)
    }

    private func coarseRotationSeeds(forCTToCTRegistration ctToCTRegistration: Bool, slabAwareRegistration: Bool) -> [SIMD3<Float>] {
        if slabAwareRegistration && ctToCTRegistration == false {
            let angle = Float(6) * .pi / 180
            return [
                SIMD3<Float>(repeating: 0),
                SIMD3<Float>(-angle, 0, 0),
                SIMD3<Float>(angle, 0, 0),
                SIMD3<Float>(0, -angle, 0),
                SIMD3<Float>(0, angle, 0),
                SIMD3<Float>(0, 0, -angle),
                SIMD3<Float>(0, 0, angle),
            ]
        }

        guard ctToCTRegistration else {
            return [SIMD3<Float>(repeating: 0)]
        }

        let angle = (slabAwareRegistration ? Float(2) : Float(6)) * .pi / 180
        return [
            SIMD3<Float>(repeating: 0),
            SIMD3<Float>(-angle, 0, 0),
            SIMD3<Float>(angle, 0, 0),
            SIMD3<Float>(0, -angle, 0),
            SIMD3<Float>(0, angle, 0),
            SIMD3<Float>(0, 0, -angle),
            SIMD3<Float>(0, 0, angle)
        ]
    }

    private func optimizeLevelWithNelderMead(
        startingAt initialState: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        translationMM: Float,
        rotationRadians: Float,
        allowsRotation: Bool,
        maxIterations: Int,
        job: RegistrationJob,
        stepIndex: Int,
        totalSteps: Int,
        samplingStride: SIMD3<Int>,
        speculativelyBatchCandidates: Bool
    ) -> (state: RigidTransformState, metric: Float) {
        guard job.isCancelled == false else { return (initialState, .greatestFiniteMagnitude) }
        struct Vertex {
            var parameters: ParameterVector
            var metric: Float
        }

        let alpha: Float = 1
        let gamma: Float = 2
        let rho: Float = 0.5
        let sigma: Float = 0.5

        let parameterScales = ParameterVector(
            translationMM,
            translationMM,
            translationMM,
            allowsRotation ? rotationRadians : 0,
            allowsRotation ? rotationRadians : 0,
            allowsRotation ? rotationRadians : 0
        )

        func metrics(for candidateParameters: [ParameterVector]) -> [Float] {
            guard candidateParameters.isEmpty == false else { return [] }
            guard job.isCancelled == false else {
                return Array(repeating: .greatestFiniteMagnitude, count: candidateParameters.count)
            }

            var uniqueParameters: [ParameterVector] = []
            var uniqueIndexByCandidate: [Int] = []
            uniqueParameters.reserveCapacity(candidateParameters.count)
            uniqueIndexByCandidate.reserveCapacity(candidateParameters.count)

            for candidate in candidateParameters {
                if let uniqueIndex = uniqueParameters.firstIndex(where: { $0.values == candidate.values }) {
                    uniqueIndexByCandidate.append(uniqueIndex)
                } else {
                    uniqueIndexByCandidate.append(uniqueParameters.count)
                    uniqueParameters.append(candidate)
                }
            }

            let uniqueMetrics = metricValues(
                for: uniqueParameters.map { state(for: $0) },
                level: level,
                levelIndex: levelIndex,
                totalLevels: totalLevels,
                useBoneOnly: useBoneOnly,
                samplingStride: samplingStride,
                job: job
            )
            return uniqueIndexByCandidate.map { uniqueMetrics[$0] }
        }

        let startParameters = parameters(for: initialState)
        var initialSimplexParameters = [startParameters]
        initialSimplexParameters.reserveCapacity(7)
        for dimension in 0..<6 {
            var candidate = startParameters
            candidate[dimension] += parameterScales[dimension]
            initialSimplexParameters.append(candidate)
        }
        let initialSimplexMetrics = metrics(for: initialSimplexParameters)
        var simplex = zip(initialSimplexParameters, initialSimplexMetrics).map {
            Vertex(parameters: $0.0, metric: $0.1)
        }

        func sortSimplex() {
            simplex.sort { $0.metric < $1.metric }
        }

        sortSimplex()
        var bestMetric = simplex[0].metric
        var bestState = state(for: simplex[0].parameters)

        for iteration in 0..<maxIterations {
            guard job.isCancelled == false else { return (bestState, bestMetric) }
            sortSimplex()
            bestMetric = simplex[0].metric
            bestState = state(for: simplex[0].parameters)

            let bestVertex = simplex[0]
            let worstVertex = simplex[6]
            let secondWorstVertex = simplex[5]

            var centroid = ParameterVector(repeating: 0)
            for index in 0..<6 {
                centroid.add(simplex[index].parameters)
            }
            centroid = centroid / 6

            let reflected = centroid + alpha * (centroid - worstVertex.parameters)
            let expanded = centroid + gamma * (reflected - centroid)
            let outsideContracted = centroid + rho * (reflected - centroid)
            let insideContracted = centroid + rho * (worstVertex.parameters - centroid)
            let speculativeMetrics = speculativelyBatchCandidates
                ? metrics(for: [reflected, expanded, outsideContracted, insideContracted])
                : []

            func evaluatedMetric(for parameters: ParameterVector, speculativeIndex: Int) -> Float {
                if speculativeMetrics.indices.contains(speculativeIndex) {
                    return speculativeMetrics[speculativeIndex]
                }
                return metricValue(
                    for: state(for: parameters),
                    level: level,
                    levelIndex: levelIndex,
                    totalLevels: totalLevels,
                    useBoneOnly: useBoneOnly,
                    samplingStride: samplingStride,
                    job: job
                )
            }

            let reflectedMetric = evaluatedMetric(for: reflected, speculativeIndex: 0)

            if reflectedMetric < bestVertex.metric {
                let expandedMetric = evaluatedMetric(for: expanded, speculativeIndex: 1)
                simplex[6] = expandedMetric < reflectedMetric
                    ? Vertex(parameters: expanded, metric: expandedMetric)
                    : Vertex(parameters: reflected, metric: reflectedMetric)
            } else if reflectedMetric < secondWorstVertex.metric {
                simplex[6] = Vertex(parameters: reflected, metric: reflectedMetric)
            } else {
                let shouldOutsideContract = reflectedMetric < worstVertex.metric
                let contracted = shouldOutsideContract ? outsideContracted : insideContracted
                let contractedMetric = evaluatedMetric(
                    for: contracted,
                    speculativeIndex: shouldOutsideContract ? 2 : 3
                )

                let contractionAccepted = shouldOutsideContract
                    ? contractedMetric <= reflectedMetric
                    : contractedMetric < worstVertex.metric

                if contractionAccepted {
                    simplex[6] = Vertex(parameters: contracted, metric: contractedMetric)
                } else {
                    var shrinkIndexes: [Int] = []
                    var shrinkParameters: [ParameterVector] = []
                    shrinkIndexes.reserveCapacity(simplex.count - 1)
                    shrinkParameters.reserveCapacity(simplex.count - 1)
                    for index in 1..<simplex.count {
                        let shrunkParameters = bestVertex.parameters + sigma * (simplex[index].parameters - bestVertex.parameters)
                        simplex[index].parameters = shrunkParameters
                        shrinkIndexes.append(index)
                        shrinkParameters.append(shrunkParameters)
                    }

                    let shrinkMetrics = metrics(for: shrinkParameters)
                    for (index, metric) in zip(shrinkIndexes, shrinkMetrics) {
                        simplex[index].metric = metric
                    }
                }
            }

            let parameterSpan = simplex.dropFirst().reduce(Float(0)) { current, vertex in
                Swift.max(current, vertex.parameters.distance(to: simplex[0].parameters))
            }
            let metricSpan = simplex.dropFirst().reduce(Float(0)) { current, vertex in
                Swift.max(current, abs(vertex.metric - simplex[0].metric))
            }

            sortSimplex()
            bestMetric = simplex[0].metric
            bestState = state(for: simplex[0].parameters)
            let completedStages = Float(levelIndex * totalSteps + stepIndex)
            let iterationFraction = Float(iteration + 1) / Float(max(maxIterations, 1))
            let progress = (completedStages + 0.1 + iterationFraction * 0.8) / Float(totalLevels * totalSteps)
            publishRegistrationUpdate(
                state: bestState,
                inProgress: true,
                progress: progress,
                message: "Registering 3D L\(levelIndex + 1)/\(totalLevels) iter \(iteration + 1)/\(maxIterations)",
                residualError: bestMetric,
                generation: job.generation
            )

            if parameterSpan < Swift.max(translationMM * 0.25, rotationRadians * 0.25) && metricSpan < 0.0001 {
                break
            }
        }

        sortSimplex()
        return (state(for: simplex[0].parameters), simplex[0].metric)
    }

    private func smoothDescentRefinement(
        startingAt initialState: RigidTransformState,
        startingMetric initialMetric: Float,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        job: RegistrationJob,
        samplingStride: SIMD3<Int>
    ) -> (state: RigidTransformState, metric: Float) {
        guard job.isCancelled == false else { return (initialState, initialMetric) }
        let isFinalLevel = levelIndex == totalLevels - 1
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        var translationStep: Float
        var rotationStep: Float
        let minTranslationStep: Float
        let minRotationStep: Float
        let maxPasses: Int

        if slabAwareRegistration {
            translationStep = isFinalLevel ? 0.75 : 1.5
            rotationStep = isFinalLevel ? 0.15 * .pi / 180 : 0.3 * .pi / 180
            minTranslationStep = isFinalLevel ? 0.08 : 0.2
            minRotationStep = isFinalLevel ? 0.03 * .pi / 180 : 0.08 * .pi / 180
            maxPasses = isFinalLevel ? 18 : 10
        } else {
            translationStep = isFinalLevel ? 0.8 : 2.0
            rotationStep = isFinalLevel ? 0.2 * .pi / 180 : 0.6 * .pi / 180
            minTranslationStep = isFinalLevel ? 0.08 : 0.25
            minRotationStep = isFinalLevel ? 0.03 * .pi / 180 : 0.08 * .pi / 180
            maxPasses = isFinalLevel ? 20 : 12
        }

        var bestParameters = parameters(for: initialState)
        var bestMetric = initialMetric
        var bestState = initialState
        var pass = 0

        while pass < maxPasses,
              translationStep >= minTranslationStep || rotationStep >= minRotationStep {
            guard job.isCancelled == false else { return (bestState, bestMetric) }
            pass += 1
            var improvedThisPass = false

            for dimension in 0..<6 {
                guard job.isCancelled == false else { return (bestState, bestMetric) }
                let step: Float
                if dimension < 3 {
                    step = translationStep >= minTranslationStep ? translationStep : 0
                } else {
                    step = rotationStep >= minRotationStep ? rotationStep : 0
                }
                guard step > 0 else { continue }

                var bestCandidateParameters = bestParameters
                var bestCandidateMetric = bestMetric
                let candidateParameters = [Float(-1), Float(1)].map { direction -> ParameterVector in
                    var candidate = bestParameters
                    candidate[dimension] += direction * step
                    return candidate
                }
                let candidateMetrics = metricValues(
                    for: candidateParameters.map { state(for: $0) },
                    level: level,
                    levelIndex: levelIndex,
                    totalLevels: totalLevels,
                    useBoneOnly: useBoneOnly,
                    samplingStride: samplingStride,
                    job: job
                )

                for (candidate, candidateMetric) in zip(candidateParameters, candidateMetrics) {
                    if candidateMetric < bestCandidateMetric {
                        bestCandidateMetric = candidateMetric
                        bestCandidateParameters = candidate
                    }
                }

                if bestCandidateMetric < bestMetric {
                    bestMetric = bestCandidateMetric
                    bestParameters = bestCandidateParameters
                    bestState = state(for: bestParameters)
                    improvedThisPass = true
                }
            }

            if improvedThisPass == false {
                translationStep *= 0.5
                rotationStep *= 0.5
            } else if pass % 3 == 0 {
                translationStep *= 0.75
                rotationStep *= 0.75
            }

            publishRegistrationUpdate(
                state: bestState,
                inProgress: true,
                progress: (Float(levelIndex) + 0.9 + 0.1 * Float(pass) / Float(max(maxPasses, 1))) / Float(max(totalLevels, 1)),
                message: "Registering 3D L\(levelIndex + 1)/\(totalLevels) smooth",
                residualError: bestMetric,
                generation: job.generation
            )
        }

        return (bestState, bestMetric)
    }

    private func batchedDescentRefinement(
        startingAt initialState: RigidTransformState,
        startingMetric initialMetric: Float,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        job: RegistrationJob,
        samplingStride: SIMD3<Int>,
        includeCombinedRotationCandidates: Bool = true
    ) -> (state: RigidTransformState, metric: Float) {
        guard job.isCancelled == false else { return (initialState, initialMetric) }
        let isFinalLevel = levelIndex == totalLevels - 1
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        var translationStep: Float = slabAwareRegistration ? (isFinalLevel ? 0.5 : 1.5) : (isFinalLevel ? 0.8 : 2.0)
        var rotationStep: Float = slabAwareRegistration ? (isFinalLevel ? 0.15 : 0.5) * .pi / 180 : (isFinalLevel ? 0.25 : 1.0) * .pi / 180
        let minTranslationStep: Float = isFinalLevel ? 0.08 : 0.25
        let minRotationStep: Float = (isFinalLevel ? 0.04 : 0.1) * .pi / 180
        let maxPasses = isFinalLevel ? 10 : 6

        var bestMetric = initialMetric
        var bestState = initialState
        var pass = 0

        while pass < maxPasses,
              translationStep >= minTranslationStep || rotationStep >= minRotationStep {
            guard job.isCancelled == false else { return (bestState, bestMetric) }
            pass += 1
            var candidateStates: [RigidTransformState] = []
            candidateStates.reserveCapacity(includeCombinedRotationCandidates ? 38 : 12)

            for dimension in 0..<6 {
                let step: Float
                if dimension < 3 {
                    step = translationStep >= minTranslationStep ? translationStep : 0
                } else {
                    step = rotationStep >= minRotationStep ? rotationStep : 0
                }
                guard step > 0 else { continue }

                for direction in [Float(-1), Float(1)] {
                    if dimension < 3 {
                        var candidate = bestState
                        candidate.translationWorld[dimension] += direction * step
                        candidateStates.append(candidate)
                    } else {
                        var deltaRotation = SIMD3<Float>(repeating: 0)
                        deltaRotation[dimension - 3] = direction * step
                        candidateStates.append(
                            rotationAdjustedState(
                                from: bestState,
                                deltaRotation: deltaRotation,
                                preserving: overlayInformativeCenterWorld
                            )
                        )
                    }
                }
            }

            if includeCombinedRotationCandidates,
               rotationStep >= minRotationStep {
                for xDirection in [Float(-1), Float(0), Float(1)] {
                    for yDirection in [Float(-1), Float(0), Float(1)] {
                        for zDirection in [Float(-1), Float(0), Float(1)] {
                            let nonZeroAxes = (xDirection != 0 ? 1 : 0)
                                + (yDirection != 0 ? 1 : 0)
                                + (zDirection != 0 ? 1 : 0)
                            guard nonZeroAxes >= 2 else { continue }

                            candidateStates.append(
                                rotationAdjustedState(
                                    from: bestState,
                                    deltaRotation: SIMD3<Float>(
                                        xDirection * rotationStep,
                                        yDirection * rotationStep,
                                        zDirection * rotationStep
                                    ),
                                    preserving: overlayInformativeCenterWorld
                                )
                            )
                        }
                    }
                }
            }

            guard candidateStates.isEmpty == false else { break }

            let candidateMetrics = metricValues(
                for: candidateStates,
                level: level,
                levelIndex: levelIndex,
                totalLevels: totalLevels,
                useBoneOnly: useBoneOnly,
                samplingStride: samplingStride,
                job: job
            )

            var bestCandidateState = bestState
            var bestCandidateMetric = bestMetric
            for (candidate, metric) in zip(candidateStates, candidateMetrics) where metric < bestCandidateMetric {
                bestCandidateMetric = metric
                bestCandidateState = candidate
            }

            if bestCandidateMetric < bestMetric {
                bestMetric = bestCandidateMetric
                bestState = bestCandidateState
                if pass % 3 == 0 {
                    translationStep *= 0.75
                    rotationStep *= 0.75
                }
            } else {
                translationStep *= 0.5
                rotationStep *= 0.5
            }

            publishRegistrationUpdate(
                state: bestState,
                inProgress: true,
                progress: (Float(levelIndex) + 0.9 + 0.1 * Float(pass) / Float(max(maxPasses, 1))) / Float(max(totalLevels, 1)),
                message: "Registering 3D L\(levelIndex + 1)/\(totalLevels) polish",
                residualError: bestMetric,
                generation: job.generation
            )
        }

        return (bestState, bestMetric)
    }

    private func parameters(for state: RigidTransformState) -> ParameterVector {
        ParameterVector(
            state.translationWorld.x,
            state.translationWorld.y,
            state.translationWorld.z,
            state.rotationRadians.x,
            state.rotationRadians.y,
            state.rotationRadians.z
        )
    }

    private func state(for parameters: ParameterVector) -> RigidTransformState {
        RigidTransformState(
            translationWorld: SIMD3<Float>(parameters[0], parameters[1], parameters[2]),
            rotationRadians: SIMD3<Float>(parameters[3], parameters[4], parameters[5])
        )
    }

    private func publishRegistrationUpdate(
        state: RigidTransformState,
        inProgress: Bool,
        progress: Float,
        message: String?,
        residualError: Float?,
        generation: UInt
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.registrationGeneration else { return }
            self.overlayTranslationWorld = state.translationWorld
            self.overlayRotationRadians = state.rotationRadians
            self.overlayTranslationPixels = self.currentOverlayTranslationPixels(for: state.translationWorld)
            if inProgress == false {
                self.focusStackOnRegisteredOverlayIfNeeded(for: state)
            }
            self.registrationInProgress = inProgress
            self.registrationProgress = max(0, min(progress, 1))
            let baseMessage = message ?? (inProgress ? "Registering 3D" : "Registered 3D")
            let statusMessage: String
            let displayMessage: String
            if let residualError {
                let metricName = self.usesContrastInvariantMRSlabMatching() ? "MIND" : "NMI"
                let scoreMessage = "\(metricName) Score: \(String(format: "%.6f", -residualError))"
                statusMessage = "\(baseMessage)  \(scoreMessage)"
                displayMessage = "\(baseMessage)\n\(scoreMessage)"
            } else {
                statusMessage = baseMessage
                displayMessage = baseMessage
            }
            self.registrationStatusMessage = statusMessage
            self.stateDidChange?(self.stateDescription)
            self.registrationDidChange?(inProgress, displayMessage, self.registrationProgress)
            if inProgress == false,
               let residualError,
               residualError.isFinite,
               residualError < Float.greatestFiniteMagnitude * 0.5 {
                self.registrationTransformDidComplete?(
                    self.registrationWorldTransform(for: state)
                )
            }
        }
    }

    private func registrationSampleGridSize(
        for texture: MTLTexture,
        samplingStride requestedSamplingStride: SIMD3<Int>
    ) -> SIMD3<Int> {
        let samplingStride = SIMD3<Int>(
            max(requestedSamplingStride.x, 1),
            max(requestedSamplingStride.y, 1),
            max(requestedSamplingStride.z, 1)
        )
        return SIMD3<Int>(
            (texture.width + samplingStride.x - 1) / samplingStride.x,
            (texture.height + samplingStride.y - 1) / samplingStride.y,
            (texture.depth + samplingStride.z - 1) / samplingStride.z
        )
    }

    private func normalizedRegistrationSamplingStride(_ requestedSamplingStride: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3<Int>(
            max(requestedSamplingStride.x, 1),
            max(requestedSamplingStride.y, 1),
            max(requestedSamplingStride.z, 1)
        )
    }

    private func registrationSamplingOptions(_ samplingStride: SIMD3<Int>) -> SIMD4<UInt32> {
        SIMD4<UInt32>(
            UInt32(samplingStride.x),
            UInt32(samplingStride.y),
            UInt32(samplingStride.z),
            0
        )
    }

    private func registrationVoxelCount(_ dimensions: SIMD3<Int>) -> Int {
        dimensions.x * dimensions.y * dimensions.z
    }

    private func mindMetricComponents(
        histogram: UnsafePointer<UInt32>
    ) -> (similarity: Double, overlapCount: Int, validDescriptorCount: Int)? {
        let overlapCount = Int(histogram[registrationMINDOverlapCountIndex])
        let validDescriptorCount = Int(histogram[registrationMINDValidDescriptorCountIndex])
        guard overlapCount > 0,
              validDescriptorCount > 0 else { return nil }

        // Geometric overlap alone is insufficient for a descriptor metric: a
        // mostly featureless intersection can otherwise win from a handful of
        // informative voxels. Keep this deliberately conservative so small,
        // targeted slabs remain valid at coarse pyramid levels.
        let fractionalMinimum = Int(ceil(Double(overlapCount) * 0.01))
        let minimumValidDescriptorCount = min(overlapCount, max(32, fractionalMinimum))
        guard validDescriptorCount >= minimumValidDescriptorCount else { return nil }

        let agreementSum = UInt64(histogram[registrationMINDAgreementLowIndex])
            | (UInt64(histogram[registrationMINDAgreementHighIndex]) << 32)
        let denominator = Double(validDescriptorCount) * registrationMINDAgreementScale
        return (
            similarity: Double(agreementSum) / denominator,
            overlapCount: overlapCount,
            validDescriptorCount: validDescriptorCount
        )
    }

    private func directionalMetricValue(
        for state: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        samplingStride requestedSamplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> Float {
        guard job.isCancelled == false else { return .greatestFiniteMagnitude }
        let baseVolumeTexture = level.0.texture
        let overlayVolumeTexture = level.1.texture
        let samplingStride = normalizedRegistrationSamplingStride(requestedSamplingStride)
        let baseSampleGridSize = registrationSampleGridSize(
            for: baseVolumeTexture,
            samplingStride: samplingStride
        )
        let overlaySampleGridSize = registrationSampleGridSize(
            for: overlayVolumeTexture,
            samplingStride: samplingStride
        )
        let options = metricOptions(forLevelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)
        let movingWorldToVoxel = simd_inverse(level.1.voxelToWorld)
        let movingTextureSize = SIMD3<Int>(
            overlayVolumeTexture.width,
            overlayVolumeTexture.height,
            overlayVolumeTexture.depth
        )

        var uniforms = RegistrationUniforms(
            baseWindowLevel: baseRegistrationWindowLevel,
            baseWindowWidth: max(baseRegistrationWindowWidth, 1),
            overlayWindowLevel: overlayRegistrationWindowLevel,
            overlayWindowWidth: max(overlayRegistrationWindowWidth, 1),
            metricOptions: options,
            baseTextureSize: SIMD3<UInt32>(
                UInt32(baseVolumeTexture.width),
                UInt32(baseVolumeTexture.height),
                UInt32(baseVolumeTexture.depth)
            ),
            fixedVoxelToMovingTexture: registrationTextureCoordinateMatrix(
                for: state,
                fixedVoxelToWorld: level.0.voxelToWorld,
                movingWorldToVoxel: movingWorldToVoxel,
                movingTextureSize: movingTextureSize
            ),
            samplingOptions: registrationSamplingOptions(samplingStride)
        )

        let histogramEntryCount = registrationHistogramBins * registrationHistogramBins
        let histogramBufferLength = histogramEntryCount * MemoryLayout<UInt32>.stride

        guard let histogramBuffer = deviceRef.makeBuffer(length: histogramBufferLength, options: .storageModeShared) else {
            return .greatestFiniteMagnitude
        }
        memset(histogramBuffer.contents(), 0, histogramBufferLength)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return .greatestFiniteMagnitude
        }

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
        let threadgroups = MTLSize(
            width: (baseSampleGridSize.x + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (baseSampleGridSize.y + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (baseSampleGridSize.z + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )
        encoder.setComputePipelineState(registrationPipelineState)
        encoder.setTexture(baseVolumeTexture, index: 0)
        encoder.setTexture(overlayVolumeTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<RegistrationUniforms>.stride, index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        guard job.isCancelled == false else { return .greatestFiniteMagnitude }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard job.isCancelled == false else { return .greatestFiniteMagnitude }
        guard commandBuffer.status == .completed else {
            return .greatestFiniteMagnitude
        }

        let histogram = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: histogramEntryCount)
        let metricMode = Int(options.x.rounded())
        let overlapCount: Int
        let similarity: Double
        if metricMode == 4 {
            guard let components = mindMetricComponents(histogram: histogram) else {
                return .greatestFiniteMagnitude
            }
            overlapCount = components.overlapCount
            similarity = components.similarity
        } else {
            var histogramTotal = 0
            for index in 0..<histogramEntryCount {
                histogramTotal += Int(histogram[index])
            }
            overlapCount = histogramTotal
            guard let nmi = smoothedNormalizedMutualInformation(
                histogram: histogram,
                bins: registrationHistogramBins
            ) else {
                return .greatestFiniteMagnitude
            }
            similarity = nmi
        }
        guard overlapCount > 0 else {
            return .greatestFiniteMagnitude
        }

        let overlapTotal = Double(overlapCount)
        let overlapPenalty = registrationOverlapPenalty(
            overlapTotal: overlapTotal,
            fixedVoxelCount: registrationVoxelCount(baseSampleGridSize),
            movingVoxelCount: registrationVoxelCount(overlaySampleGridSize),
            options: options,
            state: state
        )

        let metric = Float(-similarity) + overlapPenalty
        return metric
    }

    private func usesBidirectionalSlabMetric(options: SIMD4<Float>) -> Bool {
        let metricMode = Int(options.x.rounded())
        guard baseIsThinSlab || overlayIsThinSlab else { return false }
        if isCrossModalityUnequalCoverageRegistration() {
            return metricMode == 0 || metricMode == 2
        }
        return isCTRegistrationVolume(pixList) == false
            && isCTRegistrationVolume(overlayPixList) == false
            && (metricMode == 0 || metricMode == 2 || metricMode == 4)
    }

    private func bidirectionalMetricWeights(
        for level: (VolumeLevel, VolumeLevel)
    ) -> (forward: Float, reverse: Float) {
        if isUnequalCoverageThinSlabRegistration() {
            // Partial-to-full registration is not a symmetric problem. Always
            // evaluate the smaller, targeted slab as the fixed domain so an
            // arbitrary section of the larger volume cannot dominate merely
            // by contributing many more samples. This remains independent of
            // the order in which the user selected the two series.
            return baseIsThinSlab
                ? (forward: 1, reverse: 0)
                : (forward: 0, reverse: 1)
        }

        func physicalCoverage(of volumeLevel: VolumeLevel) -> Float {
            let spacing = voxelSpacing(from: volumeLevel.voxelToWorld)
            let size = SIMD3<Float>(
                Float(max(volumeLevel.dimensions.x, 1)) * spacing.x,
                Float(max(volumeLevel.dimensions.y, 1)) * spacing.y,
                Float(max(volumeLevel.dimensions.z, 1)) * spacing.z
            )
            return max(size.x * size.y * size.z, 0.0001)
        }

        let forwardCoverage = physicalCoverage(of: level.0)
        let reverseCoverage = physicalCoverage(of: level.1)
        let coverageTotal = forwardCoverage + reverseCoverage
        // With unequal coverage, the smaller targeted volume is the better
        // fixed domain: nearly all of its samples can contribute to the metric.
        // Weight by the opposite volume's coverage to prefer that domain while
        // retaining the other direction as a consistency check.
        let forwardWeight = min(max(reverseCoverage / max(coverageTotal, 0.0001), 0.25), 0.75)
        return (forwardWeight, 1 - forwardWeight)
    }

    private func metricValue(
        for state: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        samplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> Float {
        metricValues(
            for: [state],
            level: level,
            levelIndex: levelIndex,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly,
            samplingStride: samplingStride,
            job: job
        ).first ?? .greatestFiniteMagnitude
    }

    private func metricValues(
        for states: [RigidTransformState],
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        samplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> [Float] {
        func applyingJobLimits(to metrics: [Float]) -> [Float] {
            zip(states, metrics).map { state, metric in
                job.permits(
                    translationWorld: state.translationWorld,
                    rotationRadians: state.rotationRadians
                ) ? metric : .greatestFiniteMagnitude
            }
        }

        let primaryMetrics = primaryMetricValues(
            for: states,
            level: level,
            levelIndex: levelIndex,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly,
            samplingStride: samplingStride,
            job: job
        )
        let supportContext = registrationSupportMetricContext(
            for: level,
            levelIndex: levelIndex,
            totalLevels: totalLevels
        )
        let supportPairs = supportContext.pairs
        guard supportPairs.isEmpty == false,
              job.isCancelled == false else {
            return applyingJobLimits(to: primaryMetrics)
        }

        let supportMetrics = registrationSupportMetricValues(
            for: states,
            pairs: supportPairs,
            levelIndex: levelIndex,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly,
            samplingStride: samplingStride,
            job: job
        )
        guard supportMetrics.count == supportPairs.count,
              supportMetrics.allSatisfy({ $0.count == primaryMetrics.count }) else {
            return applyingJobLimits(to: primaryMetrics)
        }

        let combinedMetrics = primaryMetrics.enumerated().map { candidateIndex, primaryMetric in
            guard primaryMetric.isFinite,
                  primaryMetric < Float.greatestFiniteMagnitude / 2 else {
                return Float.greatestFiniteMagnitude
            }

            var weightedMetric = supportContext.primaryWeight * primaryMetric
            var totalWeight = supportContext.primaryWeight
            for (pairIndex, pair) in supportPairs.enumerated() {
                let supportMetric = supportMetrics[pairIndex][candidateIndex]
                // A candidate that misses one support slab should lose that
                // channel's vote, not make the entire multi-series search
                // undefined. Valid NMI scores are negative, so zero is a
                // deliberately poor contribution.
                let contribution = supportMetric.flatMap { metric in
                    metric.isFinite && metric < Float.greatestFiniteMagnitude / 2
                        ? metric
                        : nil
                } ?? 0
                weightedMetric += pair.weight * contribution
                totalWeight += pair.weight
            }
            return weightedMetric / max(totalWeight, 0.0001)
        }
        return applyingJobLimits(to: combinedMetrics)
    }

    private func primaryMetricValues(
        for states: [RigidTransformState],
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        samplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> [Float] {
        guard states.isEmpty == false else { return [] }
        guard job.isCancelled == false else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }
        let options = metricOptions(forLevelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)
        let usesBidirectionalMetric = usesBidirectionalSlabMetric(options: options)
        let metricWeights = usesBidirectionalMetric
            ? bidirectionalMetricWeights(for: level)
            : (forward: Float(1), reverse: Float(0))
        let evaluatesForwardDirection = metricWeights.forward > 0
        let evaluatesReverseDirection = usesBidirectionalMetric && metricWeights.reverse > 0
        guard states.count > 1 || usesBidirectionalMetric else {
            return states.map {
                directionalMetricValue(
                    for: $0,
                    level: level,
                    levelIndex: levelIndex,
                    totalLevels: totalLevels,
                    useBoneOnly: useBoneOnly,
                    samplingStride: samplingStride,
                    job: job
                )
            }
        }

        let baseVolumeTexture = level.0.texture
        let overlayVolumeTexture = level.1.texture
        let effectiveSamplingStride = normalizedRegistrationSamplingStride(samplingStride)
        let baseSampleGridSize = registrationSampleGridSize(
            for: baseVolumeTexture,
            samplingStride: effectiveSamplingStride
        )
        let overlaySampleGridSize = registrationSampleGridSize(
            for: overlayVolumeTexture,
            samplingStride: effectiveSamplingStride
        )
        let movingWorldToVoxel = simd_inverse(level.1.voxelToWorld)
        let movingTextureSize = SIMD3<Int>(
            overlayVolumeTexture.width,
            overlayVolumeTexture.height,
            overlayVolumeTexture.depth
        )
        let uniforms = states.map { state in
            RegistrationUniforms(
                baseWindowLevel: baseRegistrationWindowLevel,
                baseWindowWidth: max(baseRegistrationWindowWidth, 1),
                overlayWindowLevel: overlayRegistrationWindowLevel,
                overlayWindowWidth: max(overlayRegistrationWindowWidth, 1),
                metricOptions: options,
                baseTextureSize: SIMD3<UInt32>(
                    UInt32(baseVolumeTexture.width),
                    UInt32(baseVolumeTexture.height),
                    UInt32(baseVolumeTexture.depth)
                ),
                fixedVoxelToMovingTexture: registrationTextureCoordinateMatrix(
                    for: state,
                    fixedVoxelToWorld: level.0.voxelToWorld,
                    movingWorldToVoxel: movingWorldToVoxel,
                    movingTextureSize: movingTextureSize
                ),
                samplingOptions: registrationSamplingOptions(effectiveSamplingStride)
            )
        }
        let reverseUniforms: [RegistrationUniforms] = usesBidirectionalMetric
            ? states.map { state in
                RegistrationUniforms(
                    baseWindowLevel: overlayRegistrationWindowLevel,
                    baseWindowWidth: max(overlayRegistrationWindowWidth, 1),
                    overlayWindowLevel: baseRegistrationWindowLevel,
                    overlayWindowWidth: max(baseRegistrationWindowWidth, 1),
                    metricOptions: options,
                    baseTextureSize: SIMD3<UInt32>(
                        UInt32(overlayVolumeTexture.width),
                        UInt32(overlayVolumeTexture.height),
                        UInt32(overlayVolumeTexture.depth)
                    ),
                    fixedVoxelToMovingTexture: reverseRegistrationTextureCoordinateMatrix(
                        for: state,
                        fixedVoxelToWorld: level.1.voxelToWorld,
                        movingWorldToVoxel: simd_inverse(level.0.voxelToWorld),
                        movingTextureSize: SIMD3<Int>(
                            baseVolumeTexture.width,
                            baseVolumeTexture.height,
                            baseVolumeTexture.depth
                        )
                    ),
                    samplingOptions: registrationSamplingOptions(effectiveSamplingStride)
                )
            }
            : []

        let histogramEntryCount = registrationHistogramBins * registrationHistogramBins
        let histogramPassLength = histogramEntryCount * states.count * MemoryLayout<UInt32>.stride
        let histogramBufferLength = histogramPassLength * (usesBidirectionalMetric ? 2 : 1)
        guard let uniformBuffer = uniforms.withUnsafeBytes({ uniformBytes -> MTLBuffer? in
            guard let baseAddress = uniformBytes.baseAddress else { return nil }
            return deviceRef.makeBuffer(
                bytes: baseAddress,
                length: uniformBytes.count,
                options: .storageModeShared
            )
        }),
              let reverseUniformBuffer = usesBidirectionalMetric
                ? reverseUniforms.withUnsafeBytes({ uniformBytes -> MTLBuffer? in
                    guard let baseAddress = uniformBytes.baseAddress else { return nil }
                    return deviceRef.makeBuffer(
                        bytes: baseAddress,
                        length: uniformBytes.count,
                        options: .storageModeShared
                    )
                })
                : uniformBuffer,
              let histogramBuffer = deviceRef.makeBuffer(length: histogramBufferLength, options: .storageModeShared) else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }
        memset(histogramBuffer.contents(), 0, histogramBufferLength)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }

        var candidateCount = UInt32(states.count)
        let candidateTileCount = (states.count + registrationCandidateTileSize - 1) / registrationCandidateTileSize
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
        let threadgroups = MTLSize(
            width: (baseSampleGridSize.x + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (baseSampleGridSize.y + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (baseSampleGridSize.z * candidateTileCount + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )
        encoder.setComputePipelineState(registrationBatchPipelineState)
        encoder.setBytes(&candidateCount, length: MemoryLayout<UInt32>.stride, index: 2)
        if evaluatesForwardDirection {
            encoder.setTexture(baseVolumeTexture, index: 0)
            encoder.setTexture(overlayVolumeTexture, index: 1)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setBuffer(histogramBuffer, offset: 0, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        }

        if evaluatesReverseDirection {
            let reverseThreadgroups = MTLSize(
                width: (overlaySampleGridSize.x + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: (overlaySampleGridSize.y + threadsPerGroup.height - 1) / threadsPerGroup.height,
                depth: (overlaySampleGridSize.z * candidateTileCount + threadsPerGroup.depth - 1) / threadsPerGroup.depth
            )
            encoder.setTexture(overlayVolumeTexture, index: 0)
            encoder.setTexture(baseVolumeTexture, index: 1)
            encoder.setBuffer(reverseUniformBuffer, offset: 0, index: 0)
            encoder.setBuffer(histogramBuffer, offset: histogramPassLength, index: 1)
            encoder.dispatchThreadgroups(reverseThreadgroups, threadsPerThreadgroup: threadsPerGroup)
        }
        encoder.endEncoding()

        guard job.isCancelled == false else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard job.isCancelled == false else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }
        guard job.isCancelled == false,
              commandBuffer.status == .completed else {
            return Array(repeating: .greatestFiniteMagnitude, count: states.count)
        }

        let histogram = histogramBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: histogramEntryCount * states.count * (usesBidirectionalMetric ? 2 : 1)
        )
        let metrics = states.enumerated().map { candidateIndex, state -> Float in
            func directionalMetric(
                histogram candidateHistogram: UnsafePointer<UInt32>,
                fixedGridSize: SIMD3<Int>,
                movingGridSize: SIMD3<Int>
            ) -> Float? {
                let metricMode = Int(options.x.rounded())
                let overlapCount: Int
                let similarity: Double
                if metricMode == 4 {
                    guard let components = mindMetricComponents(histogram: candidateHistogram) else {
                        return nil
                    }
                    overlapCount = components.overlapCount
                    similarity = components.similarity
                } else {
                    var histogramTotal = 0
                    for index in 0..<histogramEntryCount {
                        histogramTotal += Int(candidateHistogram[index])
                    }
                    overlapCount = histogramTotal
                    guard let nmi = smoothedNormalizedMutualInformation(
                        histogram: candidateHistogram,
                        bins: registrationHistogramBins
                    ) else {
                        return nil
                    }
                    similarity = nmi
                }
                guard overlapCount > 0 else {
                    return nil
                }

                let overlapPenalty = registrationOverlapPenalty(
                    overlapTotal: Double(overlapCount),
                    fixedVoxelCount: registrationVoxelCount(fixedGridSize),
                    movingVoxelCount: registrationVoxelCount(movingGridSize),
                    options: options,
                    state: state
                )
                return Float(-similarity) + overlapPenalty
            }

            var weightedMetric: Float = 0
            if metricWeights.forward > 0 {
                let forwardHistogram = UnsafePointer(
                    histogram.advanced(by: candidateIndex * histogramEntryCount)
                )
                guard let forwardMetric = directionalMetric(
                    histogram: forwardHistogram,
                    fixedGridSize: baseSampleGridSize,
                    movingGridSize: overlaySampleGridSize
                ) else {
                    return .greatestFiniteMagnitude
                }
                weightedMetric += metricWeights.forward * forwardMetric
            }

            guard usesBidirectionalMetric else {
                return weightedMetric
            }

            if metricWeights.reverse > 0 {
                let reverseHistogramOffset = histogramEntryCount * states.count
                    + candidateIndex * histogramEntryCount
                let reverseHistogram = UnsafePointer(
                    histogram.advanced(by: reverseHistogramOffset)
                )
                guard let reverseMetric = directionalMetric(
                    histogram: reverseHistogram,
                    fixedGridSize: overlaySampleGridSize,
                    movingGridSize: baseSampleGridSize
                ) else {
                    return .greatestFiniteMagnitude
                }
                weightedMetric += metricWeights.reverse * reverseMetric
            }
            return weightedMetric
        }
        return metrics
    }

    private func registrationSupportMetricValues(
        for states: [RigidTransformState],
        pairs: [RegistrationSupportMetricPair],
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        samplingStride: SIMD3<Int>,
        job: RegistrationJob
    ) -> [[Float?]] {
        guard states.isEmpty == false,
              pairs.isEmpty == false,
              job.isCancelled == false else {
            return pairs.map { _ in Array(repeating: nil, count: states.count) }
        }

        let options = metricOptions(
            forLevelIndex: levelIndex,
            totalLevels: totalLevels,
            useBoneOnly: useBoneOnly
        )
        let effectiveSamplingStride = normalizedRegistrationSamplingStride(samplingStride)
        let histogramEntryCount = registrationHistogramBins * registrationHistogramBins
        let histogramPassEntryCount = histogramEntryCount * states.count
        let histogramBufferLength = histogramPassEntryCount
            * pairs.count
            * MemoryLayout<UInt32>.stride

        var uniformBuffers = [MTLBuffer]()
        var fixedSampleGridSizes = [SIMD3<Int>]()
        var movingSampleGridSizes = [SIMD3<Int>]()
        uniformBuffers.reserveCapacity(pairs.count)
        fixedSampleGridSizes.reserveCapacity(pairs.count)
        movingSampleGridSizes.reserveCapacity(pairs.count)

        for pair in pairs {
            let fixedTexture = pair.fixedLevel.texture
            let movingTexture = pair.movingLevel.texture
            let movingWorldToVoxel = simd_inverse(pair.movingLevel.voxelToWorld)
            let movingTextureSize = SIMD3<Int>(
                movingTexture.width,
                movingTexture.height,
                movingTexture.depth
            )
            let uniforms = states.map { state in
                let fixedVoxelToMovingTexture = pair.usesReverseTransform
                    ? reverseRegistrationTextureCoordinateMatrix(
                        for: state,
                        fixedVoxelToWorld: pair.fixedLevel.voxelToWorld,
                        movingWorldToVoxel: movingWorldToVoxel,
                        movingTextureSize: movingTextureSize
                    )
                    : registrationTextureCoordinateMatrix(
                        for: state,
                        fixedVoxelToWorld: pair.fixedLevel.voxelToWorld,
                        movingWorldToVoxel: movingWorldToVoxel,
                        movingTextureSize: movingTextureSize
                    )
                return RegistrationUniforms(
                    baseWindowLevel: pair.fixedWindow.level,
                    baseWindowWidth: max(pair.fixedWindow.width, 1),
                    overlayWindowLevel: pair.movingWindow.level,
                    overlayWindowWidth: max(pair.movingWindow.width, 1),
                    metricOptions: options,
                    baseTextureSize: SIMD3<UInt32>(
                        UInt32(fixedTexture.width),
                        UInt32(fixedTexture.height),
                        UInt32(fixedTexture.depth)
                    ),
                    fixedVoxelToMovingTexture: fixedVoxelToMovingTexture,
                    samplingOptions: registrationSamplingOptions(effectiveSamplingStride)
                )
            }
            guard let uniformBuffer = uniforms.withUnsafeBytes({ bytes -> MTLBuffer? in
                guard let baseAddress = bytes.baseAddress else { return nil }
                return deviceRef.makeBuffer(
                    bytes: baseAddress,
                    length: bytes.count,
                    options: .storageModeShared
                )
            }) else {
                return pairs.map { _ in Array(repeating: nil, count: states.count) }
            }
            uniformBuffers.append(uniformBuffer)
            fixedSampleGridSizes.append(
                registrationSampleGridSize(
                    for: fixedTexture,
                    samplingStride: effectiveSamplingStride
                )
            )
            movingSampleGridSizes.append(
                registrationSampleGridSize(
                    for: movingTexture,
                    samplingStride: effectiveSamplingStride
                )
            )
        }

        guard let histogramBuffer = deviceRef.makeBuffer(
            length: histogramBufferLength,
            options: .storageModeShared
        ),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return pairs.map { _ in Array(repeating: nil, count: states.count) }
        }
        memset(histogramBuffer.contents(), 0, histogramBufferLength)

        var candidateCount = UInt32(states.count)
        let candidateTileCount = (states.count + registrationCandidateTileSize - 1)
            / registrationCandidateTileSize
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
        encoder.setComputePipelineState(registrationBatchPipelineState)
        encoder.setBytes(&candidateCount, length: MemoryLayout<UInt32>.stride, index: 2)

        for (pairIndex, pair) in pairs.enumerated() {
            let fixedGridSize = fixedSampleGridSizes[pairIndex]
            let threadgroups = MTLSize(
                width: (fixedGridSize.x + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: (fixedGridSize.y + threadsPerGroup.height - 1) / threadsPerGroup.height,
                depth: (fixedGridSize.z * candidateTileCount + threadsPerGroup.depth - 1)
                    / threadsPerGroup.depth
            )
            encoder.setTexture(pair.fixedLevel.texture, index: 0)
            encoder.setTexture(pair.movingLevel.texture, index: 1)
            encoder.setBuffer(uniformBuffers[pairIndex], offset: 0, index: 0)
            encoder.setBuffer(
                histogramBuffer,
                offset: pairIndex * histogramPassEntryCount * MemoryLayout<UInt32>.stride,
                index: 1
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        }
        encoder.endEncoding()

        guard job.isCancelled == false else {
            return pairs.map { _ in Array(repeating: nil, count: states.count) }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard job.isCancelled == false,
              commandBuffer.status == .completed else {
            return pairs.map { _ in Array(repeating: nil, count: states.count) }
        }

        let histogram = histogramBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: histogramPassEntryCount * pairs.count
        )
        let metricMode = Int(options.x.rounded())
        return pairs.indices.map { pairIndex in
            states.indices.map { candidateIndex -> Float? in
                let candidateHistogram = UnsafePointer(
                    histogram.advanced(
                        by: pairIndex * histogramPassEntryCount
                            + candidateIndex * histogramEntryCount
                    )
                )
                let overlapCount: Int
                let similarity: Double
                if metricMode == 4 {
                    guard let components = mindMetricComponents(
                        histogram: candidateHistogram
                    ) else {
                        return nil
                    }
                    overlapCount = components.overlapCount
                    similarity = components.similarity
                } else {
                    var histogramTotal = 0
                    for index in 0..<histogramEntryCount {
                        histogramTotal += Int(candidateHistogram[index])
                    }
                    overlapCount = histogramTotal
                    guard let nmi = smoothedNormalizedMutualInformation(
                        histogram: candidateHistogram,
                        bins: registrationHistogramBins
                    ) else {
                        return nil
                    }
                    similarity = nmi
                }

                let overlapDenominator = min(
                    registrationVoxelCount(fixedSampleGridSizes[pairIndex]),
                    registrationVoxelCount(movingSampleGridSizes[pairIndex])
                )
                let overlapFraction = Double(overlapCount)
                    / Double(max(overlapDenominator, 1))
                guard overlapFraction >= 0.35 else {
                    return nil
                }
                return Float(-similarity)
            }
        }
    }

    private func smoothedNormalizedMutualInformation(histogram: UnsafePointer<UInt32>, bins: Int) -> Double? {
        let entryCount = bins * bins
        var smoothedHistogram = [Double](repeating: 0, count: entryCount)
        let kernel = [1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0]

        for overlayBin in 0..<bins {
            for baseBin in 0..<bins {
                var smoothedCount: Double = 0
                var weightTotal: Double = 0
                var kernelIndex = 0
                for overlayOffset in -1...1 {
                    for baseOffset in -1...1 {
                        let neighborOverlayBin = overlayBin + overlayOffset
                        let neighborBaseBin = baseBin + baseOffset
                        let weight = kernel[kernelIndex]
                        kernelIndex += 1
                        guard neighborOverlayBin >= 0,
                              neighborOverlayBin < bins,
                              neighborBaseBin >= 0,
                              neighborBaseBin < bins else {
                            continue
                        }

                        let neighborIndex = neighborOverlayBin * bins + neighborBaseBin
                        smoothedCount += Double(histogram[neighborIndex]) * weight
                        weightTotal += weight
                    }
                }

                let index = overlayBin * bins + baseBin
                smoothedHistogram[index] = smoothedCount / max(weightTotal, 1)
            }
        }

        let smoothedTotal = smoothedHistogram.reduce(0, +)
        guard smoothedTotal > 0 else { return nil }

        var baseMarginal = [Double](repeating: 0, count: bins)
        var overlayMarginal = [Double](repeating: 0, count: bins)
        var jointEntropy: Double = 0

        for overlayBin in 0..<bins {
            for baseBin in 0..<bins {
                let index = overlayBin * bins + baseBin
                let count = smoothedHistogram[index]
                if count <= 0 { continue }
                let probability = count / smoothedTotal
                baseMarginal[baseBin] += probability
                overlayMarginal[overlayBin] += probability
                jointEntropy -= probability * log(probability)
            }
        }

        guard jointEntropy > 0 else { return nil }

        var baseEntropy: Double = 0
        var overlayEntropy: Double = 0
        for probability in baseMarginal where probability > 0 {
            baseEntropy -= probability * log(probability)
        }
        for probability in overlayMarginal where probability > 0 {
            overlayEntropy -= probability * log(probability)
        }

        return (baseEntropy + overlayEntropy) / jointEntropy
    }

    private func registrationOverlapPenalty(
        overlapTotal: Double,
        fixedVoxelCount: Int,
        movingVoxelCount: Int,
        options: SIMD4<Float>,
        state: RigidTransformState
    ) -> Float {
        let fixedVoxelCount = Double(fixedVoxelCount)
        let movingVoxelCount = Double(movingVoxelCount)
        let overlapDenominator = min(fixedVoxelCount, movingVoxelCount)
        let overlapFraction = overlapTotal / max(overlapDenominator, 1)
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let mode = Int(options.x.rounded())
        let usesContrastInvariantSlabMetric = mode == 4
        var residualRotationPenalty: Float = 0

        let minimumCranialFraction = minimumCranialCoverageFraction()
        if minimumCranialFraction > 0,
           let coverageFraction = cranialCoverageFraction(for: state),
           coverageFraction < minimumCranialFraction {
            return .greatestFiniteMagnitude
        }

        if slabAwareRegistration,
           isCTRegistrationVolume(pixList) == false,
           isCTRegistrationVolume(overlayPixList) == false {
            // The voxel-to-world matrices already describe whether each
            // acquisition is axial, coronal, sagittal, or oblique. The fitted
            // Euler angles therefore represent patient repositioning only.
            // Large residual rotations in limited-coverage head MR are false
            // cross-plane intersections, not plausible rigid registrations.
            let maximumResidualRotationDegrees: Float
            if usesContrastInvariantSlabMetric && isUnequalCoverageThinSlabRegistration() {
                maximumResidualRotationDegrees = 12
            } else {
                maximumResidualRotationDegrees = 15
            }
            let maximumResidualRotation = maximumResidualRotationDegrees * .pi / 180
            let largestRotation = max(
                abs(state.rotationRadians.x),
                max(abs(state.rotationRadians.y), abs(state.rotationRadians.z))
            )
            guard largestRotation <= maximumResidualRotation else {
                return .greatestFiniteMagnitude
            }
            let unpenalizedRotationDegrees: Float
            if usesContrastInvariantSlabMetric {
                unpenalizedRotationDegrees = isUnequalCoverageThinSlabRegistration() ? 6 : 8
            } else {
                unpenalizedRotationDegrees = isCrossPlaneThinSlabRegistration() ? 8 : 10
            }
            let unpenalizedRotation = unpenalizedRotationDegrees
                * .pi / 180
            if largestRotation > unpenalizedRotation {
                let excessFraction = (largestRotation - unpenalizedRotation)
                    / max(maximumResidualRotation - unpenalizedRotation, 0.0001)
                let penaltyScale: Float = isCrossPlaneThinSlabRegistration() ? 0.15 : 0.1
                residualRotationPenalty = penaltyScale * excessFraction * excessFraction
            }
        }

        // Plain NMI becomes statistically meaningless when it is computed
        // from only a tiny accidental intersection. This is particularly easy
        // to trigger with orthogonal axial/coronal limited-coverage volumes:
        // an outlying coarse seed can obtain a deceptively sharp histogram and
        // pull the optimizer completely away from the DICOM-aligned anatomy.
        // Such a transform is not a usable registration, so reject it instead
        // of trying to repair its score with a small linear penalty.
        if mode == 0 || (mode == 2 && isCrossModalityUnequalCoverageRegistration()) {
            let minimumReliableOverlap: Double
            if isCrossModalityUnequalCoverageRegistration() {
                minimumReliableOverlap = 0.35
            } else {
                minimumReliableOverlap = slabAwareRegistration ? 0.03 : 0.02
            }
            guard overlapFraction >= minimumReliableOverlap else {
                return .greatestFiniteMagnitude
            }
        } else if mode == 4 {
            // A small targeted slab should be almost entirely contained by a
            // larger 3D acquisition. Two similarly sized oblique slabs can
            // have much less reciprocal voxel overlap even when their anatomy
            // is correctly aligned, especially at the coarsest pyramid level.
            let minimumReliableOverlap = isUnequalCoverageThinSlabRegistration()
                ? 0.5
                : 0.25
            guard overlapFraction >= minimumReliableOverlap else {
                return .greatestFiniteMagnitude
            }
        }

        let minimumUsefulOverlap: Double
        if mode == 1 {
            minimumUsefulOverlap = slabAwareRegistration ? 0.08 : 0.003
        } else if mode == 2 {
            minimumUsefulOverlap = usesStructureOnlyCrossPlaneMetric()
                ? 0.025
                : (slabAwareRegistration ? 0.015 : 0.003)
        } else if mode == 3 {
            minimumUsefulOverlap = slabAwareRegistration ? 0.10 : 0.006
        } else if mode == 4 {
            minimumUsefulOverlap = slabAwareRegistration ? 0.20 : 0.08
        } else {
            minimumUsefulOverlap = slabAwareRegistration ? 0.15 : 0.08
        }
        let overlapPenalty = overlapFraction < minimumUsefulOverlap
            ? Float((minimumUsefulOverlap - overlapFraction) * (slabAwareRegistration ? 12.0 : 10.0))
            : 0
        let slabPenalty = slabAwareRegistration ? slabOverlapPenalty(for: state) : 0
        return overlapPenalty + slabPenalty + residualRotationPenalty
    }

    private func isCTToCTRegistration() -> Bool {
        isCTRegistrationVolume(pixList) && isCTRegistrationVolume(overlayPixList)
    }

    private func isCTRegistrationVolume(_ volumePixList: [DCMPix]) -> Bool {
        guard let firstPix = volumePixList.first else { return false }
        let modality = firstPix.modalityString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let rescale = firstPix.rescaleType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return modality == "CT" || rescale == "HU"
    }

    private func shouldCorrectGantryTilt(for pixList: [DCMPix]) -> Bool {
        isCTRegistrationVolume(pixList)
    }

    private func metricOptions(forLevelIndex levelIndex: Int, totalLevels: Int, useBoneOnly _: Bool) -> SIMD4<Float> {
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let fixedVolumeIsCT = isCTRegistrationVolume(pixList)
        if fixedVolumeIsCT && (slabAwareRegistration == false || isCTRegistrationVolume(overlayPixList)) {
            return SIMD4<Float>(3, -700, 3000, 0)
        }

        if isCrossModalityUnequalCoverageRegistration() {
            // Raw NMI is the more reliable objective for locating a small MR
            // slab within a much larger CT acquisition. Once that broad search
            // has reached the correct cranial basin, use shared image edges for
            // the last local stages so CT/MR signal differences cannot leave a
            // sagittal slab displaced within the head.
            let firstStructureLevel = max(totalLevels - 2, 1)
            if totalLevels > 1, levelIndex >= firstStructureLevel {
                let isFinalLevel = levelIndex == totalLevels - 1
                let gradientThreshold: Float = isFinalLevel ? 0.03 : 0.015
                return SIMD4<Float>(2, gradientThreshold, 0, 0)
            }
            return SIMD4<Float>.zero
        }

        if usesContrastInvariantMRSlabMatching() {
            // Limited-coverage MR volumes with different sequence or Dixon
            // reconstruction contrast do not have a stable intensity
            // relationship. Optimize a local modality-independent
            // self-similarity descriptor throughout this path instead of
            // allowing a false raw-NMI overlap to dominate.
            return SIMD4<Float>(4, 0, 0, 0)
        }

        if usesStructureOnlyCrossPlaneMetric() {
            // Orthogonal limited-coverage MR series often have substantially
            // different sequence contrast. Rank the complete search by
            // gradient-magnitude NMI so shared anatomical boundaries, rather
            // than raw T1 signal, determine the transform.
            let isFinalLevel = levelIndex == totalLevels - 1
            let gradientThreshold: Float = isFinalLevel ? 0.03 : 0.012
            return SIMD4<Float>(2, gradientThreshold, 0, 0)
        }

        let firstStructureLevel = max(totalLevels - 2, 1)
        if slabAwareRegistration,
           isUnequalCoverageThinSlabRegistration() == false,
           totalLevels > 1,
           levelIndex >= firstStructureLevel {
            let isFinalLevel = levelIndex == totalLevels - 1
            let gradientThreshold: Float = isFinalLevel ? 0.035 : 0.02
            return SIMD4<Float>(2, gradientThreshold, 0, 0)
        }

        return SIMD4<Float>.zero
    }

    private func shouldUseBoneOnlyMetric(forLevelIndex levelIndex: Int, totalLevels: Int) -> Bool {
        guard totalLevels > 0 else { return false }
        return levelIndex == totalLevels - 1
    }

    private func currentOverlayTranslationPixels(for translationWorld: SIMD3<Float>? = nil) -> SIMD2<Float> {
        guard let currentPix,
              let geometry = MetalViewerSliceGeometry(pix: currentPix) else {
            return .zero
        }
        let translation = translationWorld ?? overlayTranslationWorld
        let pixelX = Double(translation.x) / geometry.spacingX
        let pixelY = Double(translation.y) / geometry.spacingY
        return SIMD2<Float>(Float(pixelX), Float(pixelY))
    }

    private func stackDisplayUsesCorrectedBaseVolume() -> Bool {
        overlayVolumeTexture != nil && baseVolumeTexture != nil && baseUsesGantryTiltCorrectedVolume
    }

    private func stackDisplayUsesSharedVolumeTexture() -> Bool {
        return stackDisplayUsesSharedVolumeTexture(for: currentPix, at: currentSliceIndex)
    }

    private func stackDisplayUsesSharedVolumeTexture(for pix: DCMPix?, at index: Int) -> Bool {
        return stackDisplayCanUseSharedVolumeTexture(for: pix, at: index)
    }

    private func stackDisplayCanUseSharedVolumeTexture(for pix: DCMPix?, at index: Int) -> Bool {
        guard displayMode == .stack2D,
              overlayVolumeTexture == nil,
              let stackVolumeTextureEntry,
              let pix,
              index >= 0,
              index < stackVolumeTextureEntry.dimensions.z else {
            return false
        }

        return stackVolumeTextureEntry.dimensions.x == max(Int(pix.widthWithoutLoading()), 1)
            && stackVolumeTextureEntry.dimensions.y == max(Int(pix.heightWithoutLoading()), 1)
    }

    private func stackDisplayVolumeTexture() -> MTLTexture? {
        if stackDisplayUsesCorrectedBaseVolume() {
            return baseVolumeTexture
        }

        if stackDisplayUsesSharedVolumeTexture() {
            return stackVolumeTextureEntry?.texture
        }

        return currentImmediateStackSliceTextureEntry()?.texture
    }

    private func stackDisplayVolumeEntry() -> MetalSeriesTextureCache.Entry? {
        guard stackDisplayUsesCorrectedBaseVolume() == false else {
            return nil
        }

        if stackDisplayUsesSharedVolumeTexture() {
            return stackVolumeTextureEntry
        }

        return currentImmediateStackSliceTextureEntry()
    }

    private func currentImmediateStackSliceTextureEntry() -> MetalSeriesTextureCache.Entry? {
        guard displayMode == .stack2D,
              immediateStackSliceIndex == currentSliceIndex,
              let immediateStackSliceTextureEntry,
              let currentPix,
              immediateStackSliceTextureEntry.dimensions.x == max(Int(currentPix.widthWithoutLoading()), 1),
              immediateStackSliceTextureEntry.dimensions.y == max(Int(currentPix.heightWithoutLoading()), 1) else {
            return nil
        }

        return immediateStackSliceTextureEntry
    }

    private func stackDisplayVolumeDimensions(volumeTexture: MTLTexture) -> SIMD3<UInt32> {
        return SIMD3<UInt32>(
            UInt32(max(volumeTexture.width, 1)),
            UInt32(max(volumeTexture.height, 1)),
            UInt32(max(volumeTexture.depth, 1))
        )
    }

    private func stackDisplayAspectRatio() -> Float {
        guard stackDisplayUsesCorrectedBaseVolume() else {
            return imageAspectRatio
        }

        let xStep = SIMD3<Float>(
            fixedVoxelToWorld.columns.0.x,
            fixedVoxelToWorld.columns.0.y,
            fixedVoxelToWorld.columns.0.z
        )
        let yStep = SIMD3<Float>(
            fixedVoxelToWorld.columns.1.x,
            fixedVoxelToWorld.columns.1.y,
            fixedVoxelToWorld.columns.1.z
        )
        let widthMM = Float(max(baseVolumeDimensions.x, 1)) * max(simd_length(xStep), 0.0001)
        let heightMM = Float(max(baseVolumeDimensions.y, 1)) * max(simd_length(yStep), 0.0001)
        return widthMM / max(heightMM, 0.0001)
    }

    private func stackDisplaySliceIndex() -> Float {
        let fallbackSliceIndex = Float(currentSliceIndex)
        guard stackDisplayUsesCorrectedBaseVolume(),
              let currentPix else {
            return fallbackSliceIndex
        }

        let sourceVoxelToWorld = MetalViewerGantryTiltGeometryBuilder.sourceVoxelToPatientMatrix(for: pixList)
        let sourceVoxel = SIMD4<Float>(
            Float(max(currentPix.pwidth - 1, 0)) * 0.5,
            Float(max(currentPix.pheight - 1, 0)) * 0.5,
            Float(currentSliceIndex),
            1
        )
        let sourceWorld = sourceVoxelToWorld * sourceVoxel
        let correctedVoxel = simd_inverse(fixedVoxelToWorld) * sourceWorld
        return min(max(correctedVoxel.z, 0), Float(max(baseVolumeDimensions.z - 1, 0)))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {
        switch displayMode {
        case .mpr:
            drawMPR(in: view)
            return
        case .mpr3D:
            drawMPR3D(in: view)
            return
        case .stack2D:
            break
        }

        guard let displayVolumeTexture = stackDisplayVolumeTexture() else { return }
        let displayVolumeEntry = stackDisplayVolumeEntry()
        let displayVolumeKind = displayVolumeEntry?.textureKind ?? .rescaledFloat
        let floatDisplayVolumeTexture = displayVolumeKind == .rescaledFloat ? displayVolumeTexture : nil
        let signedDisplayVolumeTexture = displayVolumeKind == .storedInt16Signed ? displayVolumeTexture : nil
        let unsignedDisplayVolumeTexture = displayVolumeKind == .storedInt16Unsigned ? displayVolumeTexture : nil
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        let drawableAspect = max(Float(view.drawableSize.width / max(view.drawableSize.height, 1)), 0.0001)
        let displayAspectRatio = stackDisplayAspectRatio()
        var scale = SIMD2<Float>(repeating: 1)
        if displayAspectRatio > drawableAspect {
            scale.y = drawableAspect / displayAspectRatio
        } else {
            scale.x = displayAspectRatio / drawableAspect
        }
        scale *= zoomScale
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(view.bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(view.bounds.height, 1)) * 2.0)
        )

        var uniforms = MetalUniforms(
            scale: scale,
            offset: offset,
            rotationRadians: stackRotationRadians,
            drawableAspect: drawableAspect,
            baseWindowLevel: windowLevel,
            baseWindowWidth: max(windowWidth, 1),
            overlayWindowLevel: overlayWindowLevel,
            overlayWindowWidth: max(overlayWindowWidth, 1),
            overlayBlend: overlayBlend,
            overlayTranslationWorld: overlayTranslationWorld,
            movingRotationCenterWorld: movingRotationCenterWorld,
            fixedVolumeSize: stackDisplayVolumeDimensions(volumeTexture: displayVolumeTexture),
            currentSliceIndex: stackDisplaySliceIndex(),
            movingInverseRotation: inverseRotationMatrix(for: overlayRotationRadians),
            fixedVoxelToWorld: fixedVoxelToWorld,
            movingWorldToVoxel: movingWorldToVoxel,
            hasOverlay: overlayVolumeTexture == nil ? 0 : 1,
            imageInterpolationMode: UInt32(imageInterpolationMode.rawValue),
            baseHasCustomCLUT: baseHasCustomCLUT ? 1 : 0,
            overlayHasCustomCLUT: overlayHasCustomCLUT ? 1 : 0,
            baseVolumeTextureKind: displayVolumeKind.rawValue,
            baseVolumeRescaleSlope: displayVolumeEntry?.rescaleSlope ?? 1,
            baseVolumeRescaleIntercept: displayVolumeEntry?.rescaleIntercept ?? 0,
            baseVolumePadding: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
        encoder.setFragmentTexture(floatDisplayVolumeTexture, index: 2)
        setTransferTextures(on: encoder)
        encoder.setFragmentTexture(signedDisplayVolumeTexture, index: 7)
        encoder.setFragmentTexture(unsignedDisplayVolumeTexture, index: 8)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawMPR(in view: MTKView) {
        prepareBaseVolumeIfNeeded()
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let baseVolumeTexture else {
            return
        }
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare

        let vertices = makeMPRVertices()
        guard vertices.isEmpty == false,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let mainBounds = mprMainInteractionBounds(in: view.bounds)
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(mainBounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(mainBounds.height, 1)) * 2.0)
        )
        let viewProjectionMatrix = mprViewProjectionMatrix(offset: offset, viewportSize: mainBounds.size)
        var uniforms = makeMPRUniforms(
            viewProjectionMatrix: viewProjectionMatrix,
            baseVolumeTexture: baseVolumeTexture
        )
        let renderLayout = mprRenderLayout(for: view)
        if let renderLayout {
            encoder.setViewport(renderLayout.mainViewport)
            encoder.setScissorRect(renderLayout.mainScissor)
        }

        encoder.setRenderPipelineState(mprPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        if setMPRVertexData(vertices, on: encoder) {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 0)
            encoder.setFragmentTexture(baseVolumeTexture, index: 0)
            encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
            setTransferTextures(on: encoder)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        let seedVertices = makeMPRTumourSeedSphereVertices()
        if seedVertices.isEmpty == false {
            encoder.setRenderPipelineState(mprPlaneHighlightPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            let vertexBufferLength = MemoryLayout<MetalMPRVertex>.stride * seedVertices.count
            if let vertexBuffer = deviceRef.makeBuffer(
                bytes: seedVertices,
                length: vertexBufferLength,
                options: .storageModeShared
            ) {
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: seedVertices.count)
            }
        }

        let highlightVertices = makeMPRPlaneHighlightVertices()
        if highlightVertices.isEmpty == false {
            encoder.setRenderPipelineState(mprPlaneHighlightPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            if setMPRVertexData(highlightVertices, on: encoder) {
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: highlightVertices.count)
            }
        }

        let borderVertices = makeMPRBorderVertices()
        encoder.setRenderPipelineState(mprBorderPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        if setMPRVertexData(borderVertices, on: encoder) {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: borderVertices.count)
        }

        let intersectionVertices = makeMPRIntersectionVertices()
        encoder.setRenderPipelineState(mprIntersectionPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        if setMPRVertexData(intersectionVertices, on: encoder) {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: intersectionVertices.count)
        }

        if let renderLayout {
            drawMPRPreviewPanes(
                renderLayout.previewPanes,
                encoder: encoder,
                uniforms: uniforms,
                baseVolumeTexture: baseVolumeTexture
            )
        }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeMPRUniforms(
        viewProjectionMatrix: simd_float4x4,
        baseVolumeTexture: MTLTexture
    ) -> MetalMPRUniforms {
        MetalMPRUniforms(
            viewProjectionMatrix: viewProjectionMatrix,
            baseWindowLevel: windowLevel,
            baseWindowWidth: max(windowWidth, 1),
            overlayWindowLevel: overlayWindowLevel,
            overlayWindowWidth: max(overlayWindowWidth, 1),
            overlayBlend: overlayBlend,
            overlayTranslationWorld: overlayTranslationWorld,
            movingRotationCenterWorld: movingRotationCenterWorld,
            fixedVolumeSize: SIMD3<UInt32>(
                UInt32(max(baseVolumeTexture.width, 1)),
                UInt32(max(baseVolumeTexture.height, 1)),
                UInt32(max(baseVolumeTexture.depth, 1))
            ),
            movingInverseRotation: inverseRotationMatrix(for: overlayRotationRadians),
            fixedVoxelToWorld: fixedVoxelToWorld,
            movingWorldToVoxel: movingWorldToVoxel,
            hasOverlay: overlayVolumeTexture == nil ? 0 : 1,
            baseHasCustomCLUT: baseHasCustomCLUT ? 1 : 0,
            overlayHasCustomCLUT: overlayHasCustomCLUT ? 1 : 0
        )
    }

    private func setMPRVertexData(
        _ vertices: [MetalMPRVertex],
        on encoder: MTLRenderCommandEncoder
    ) -> Bool {
        let byteCount = vertices.count * MemoryLayout<MetalMPRVertex>.stride
        guard byteCount > 0 else { return false }

        if byteCount <= maximumInlineMetalVertexBytes {
            return vertices.withUnsafeBytes { vertexBytes in
                guard let vertexBaseAddress = vertexBytes.baseAddress else {
                    return false
                }
                encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
                return true
            }
        }

        guard let vertexBuffer = deviceRef.makeBuffer(
            bytes: vertices,
            length: byteCount,
            options: .storageModeShared
        ) else {
            return false
        }
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        return true
    }

    private func drawMPR3D(in view: MTKView) {
        prepareBaseVolumeIfNeeded()
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let baseVolumeTexture,
              let panes = mpr3DRenderPanes(for: view) else {
            return
        }
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let uniforms = makeMPRUniforms(
            viewProjectionMatrix: matrix_identity_float4x4,
            baseVolumeTexture: baseVolumeTexture
        )
        drawMPRPreviewPanes(
            panes,
            encoder: encoder,
            uniforms: uniforms,
            baseVolumeTexture: baseVolumeTexture
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func mprRenderLayout(for view: MTKView) -> MetalMPRRenderLayout? {
        let drawableWidth = Int(view.drawableSize.width.rounded(.down))
        let drawableHeight = Int(view.drawableSize.height.rounded(.down))
        guard drawableWidth > 0, drawableHeight > 0 else {
            return nil
        }

        let scale = max(view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 1, 1)
        guard let metrics = mprLayoutMetrics(
            totalWidth: CGFloat(drawableWidth),
            totalHeight: CGFloat(drawableHeight),
            unitScale: scale
        ) else {
            return nil
        }
        let renderHeight = drawableHeight
        let gap = min(max(Int(metrics.gap.rounded(.down)), 1), max(drawableWidth - 2, 1))
        let unclampedMainWidth = Int(metrics.mainWidth.rounded(.down))
        let mainWidth = min(max(unclampedMainWidth, 1), max(drawableWidth - gap - 1, 1))
        let previewX = mainWidth + gap
        let previewWidth = drawableWidth - previewX
        guard previewWidth > 0 else {
            return nil
        }

        let mainViewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(mainWidth),
            height: Double(renderHeight),
            znear: 0,
            zfar: 1
        )
        let mainScissor = MTLScissorRect(x: 0, y: 0, width: mainWidth, height: renderHeight)

        let previewPaneRects = metrics.previewPaneRects.map { rect in
            CGRect(x: CGFloat(previewX), y: rect.minY, width: CGFloat(previewWidth), height: rect.height)
        }
        guard let panes = mprPreviewPanes(
            for: previewPaneRects,
            renderWidth: drawableWidth,
            renderHeight: renderHeight,
            unitScale: scale
        ) else {
            return nil
        }
        return MetalMPRRenderLayout(
            mainViewport: mainViewport,
            mainScissor: mainScissor,
            previewPanes: panes
        )
    }

    private func mpr3DRenderPanes(for view: MTKView) -> [MetalMPRPreviewPane]? {
        let drawableWidth = Int(view.drawableSize.width.rounded(.down))
        let drawableHeight = Int(view.drawableSize.height.rounded(.down))
        guard drawableWidth > 0, drawableHeight > 0 else {
            return nil
        }

        let scale = max(view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 1, 1)
        guard let paneRects = mpr3DPaneRects(
            totalWidth: CGFloat(drawableWidth),
            totalHeight: CGFloat(drawableHeight),
            unitScale: scale
        ) else {
            return nil
        }

        return mprPreviewPanes(for: paneRects, renderWidth: drawableWidth, renderHeight: drawableHeight, unitScale: scale)
    }

    private func mprPreviewPanes(
        for paneRects: [CGRect],
        renderWidth: Int,
        renderHeight: Int,
        unitScale: CGFloat
    ) -> [MetalMPRPreviewPane]? {
        let orderedPlanes = mprPlanesInAnatomicalOrder
        let panes = Array(zip(orderedPlanes, paneRects)).compactMap { pair -> MetalMPRPreviewPane? in
            let (plane, rect) = pair
            let x = min(max(Int(rect.minX.rounded(.down)), 0), max(renderWidth - 1, 0))
            let maxX = min(max(Int(rect.maxX.rounded(.down)), x + 1), renderWidth)
            let y = min(max(Int(rect.minY.rounded(.down)), 0), max(renderHeight - 1, 0))
            let maxY = min(max(Int(rect.maxY.rounded(.down)), y + 1), renderHeight)
            let width = maxX - x
            let height = maxY - y
            guard width > 0, height > 0 else {
                return nil
            }
            let viewport = MTLViewport(
                originX: Double(x),
                originY: Double(y),
                width: Double(width),
                height: Double(height),
                znear: 0,
                zfar: 1
            )
            let scissor = MTLScissorRect(x: x, y: y, width: width, height: height)
            return MetalMPRPreviewPane(plane: plane, viewport: viewport, scissor: scissor, unitScale: unitScale)
        }

        guard panes.count == orderedPlanes.count else {
            return nil
        }
        return panes
    }

    private func mprLayoutMetrics(
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        unitScale: CGFloat
    ) -> (totalHeight: CGFloat, gap: CGFloat, previewWidth: CGFloat, mainWidth: CGFloat, previewPaneRects: [CGRect])? {
        guard totalWidth > 0, totalHeight > 0 else {
            return nil
        }

        let gap = max(MetalMPRPreviewLayoutDefaults.gap * unitScale, 1)
        let paneGap = max(MetalMPRPreviewLayoutDefaults.paneGap * unitScale, 1)
        let minimumPreviewWidth = MetalMPRPreviewLayoutDefaults.minimumPreviewWidth * unitScale
        let minimumMainWidth = MetalMPRPreviewLayoutDefaults.minimumMainWidth * unitScale
        let maximumPreviewWidth = min(
            totalWidth * MetalMPRPreviewLayoutDefaults.maximumWidthFraction,
            totalWidth - gap - minimumMainWidth
        )
        guard maximumPreviewWidth >= minimumPreviewWidth,
              totalHeight >= minimumMainWidth else {
            return nil
        }

        let requestedPreviewWidth = totalWidth * mprPreviewWidthFraction
        let previewWidth = min(max(requestedPreviewWidth, minimumPreviewWidth), maximumPreviewWidth)
        let mainWidth = totalWidth - previewWidth - gap
        guard mainWidth >= minimumMainWidth else {
            return nil
        }

        let availablePreviewHeight = totalHeight - (paneGap * 2)
        guard availablePreviewHeight > 0 else {
            return nil
        }
        let paneHeight = floor(availablePreviewHeight / 3)
        guard paneHeight > 0 else {
            return nil
        }

        let previewX = mainWidth + gap
        let paneRects = (0..<3).map { index -> CGRect in
            let y = CGFloat(index) * (paneHeight + paneGap)
            let height = index == 2 ? totalHeight - y : paneHeight
            return CGRect(x: previewX, y: y, width: previewWidth, height: height)
        }

        return (
            totalHeight: totalHeight,
            gap: gap,
            previewWidth: previewWidth,
            mainWidth: mainWidth,
            previewPaneRects: paneRects
        )
    }

    private func mpr3DPaneRects(
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        unitScale: CGFloat
    ) -> [CGRect]? {
        guard totalWidth > 0, totalHeight > 0 else {
            return nil
        }

        let paneGap = max(MetalMPRPreviewLayoutDefaults.paneGap * unitScale, 1)
        if totalWidth >= totalHeight {
            let availableWidth = totalWidth - paneGap * 2
            guard availableWidth > 3 else {
                return nil
            }
            let paneWidth = floor(availableWidth / 3)
            guard paneWidth > 0 else {
                return nil
            }
            return (0..<3).map { index in
                let x = CGFloat(index) * (paneWidth + paneGap)
                let width = index == 2 ? totalWidth - x : paneWidth
                return CGRect(x: x, y: 0, width: width, height: totalHeight)
            }
        }

        let availableHeight = totalHeight - paneGap * 2
        guard availableHeight > 3 else {
            return nil
        }
        let paneHeight = floor(availableHeight / 3)
        guard paneHeight > 0 else {
            return nil
        }
        return (0..<3).map { index in
            let y = CGFloat(index) * (paneHeight + paneGap)
            let height = index == 2 ? totalHeight - y : paneHeight
            return CGRect(x: 0, y: y, width: totalWidth, height: height)
        }
    }

    private func drawMPRPreviewPanes(
        _ panes: [MetalMPRPreviewPane],
        encoder: MTLRenderCommandEncoder,
        uniforms: MetalMPRUniforms,
        baseVolumeTexture: MTLTexture
    ) {
        var previewUniforms = uniforms
        previewUniforms.viewProjectionMatrix = matrix_identity_float4x4

        for pane in panes {
            let vertices = makePlanarMPRPreviewVertices(for: pane.plane, viewport: pane.viewport, unitScale: pane.unitScale)
            guard vertices.isEmpty == false else {
                continue
            }

            encoder.setViewport(pane.viewport)
            encoder.setScissorRect(pane.scissor)
            encoder.setRenderPipelineState(mprPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            if setMPRVertexData(vertices, on: encoder) {
                encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 0)
                encoder.setFragmentTexture(baseVolumeTexture, index: 0)
                encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
                setTransferTextures(on: encoder)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }

            let sliceThicknessVertices = makePlanarMPRPreviewSliceThicknessVertices(for: pane.plane, viewport: pane.viewport, unitScale: pane.unitScale)
            if sliceThicknessVertices.isEmpty == false {
                encoder.setRenderPipelineState(mprPlaneHighlightPipelineState)
                encoder.setDepthStencilState(mprDepthStencilState)
                if setMPRVertexData(sliceThicknessVertices, on: encoder) {
                    encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sliceThicknessVertices.count)
                }
            }

            let seedVertices = makePlanarMPRPreviewTumourSeedCrossSectionVertices(for: pane.plane, viewport: pane.viewport, unitScale: pane.unitScale)
            if seedVertices.isEmpty == false {
                encoder.setRenderPipelineState(mprPlaneHighlightPipelineState)
                encoder.setDepthStencilState(mprDepthStencilState)
                let vertexBufferLength = MemoryLayout<MetalMPRVertex>.stride * seedVertices.count
                if let vertexBuffer = deviceRef.makeBuffer(
                    bytes: seedVertices,
                    length: vertexBufferLength,
                    options: .storageModeShared
                ) {
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: seedVertices.count)
                }
            }

            let intersectionVertices = makePlanarMPRPreviewIntersectionVertices(for: pane.plane, viewport: pane.viewport, unitScale: pane.unitScale)
            if intersectionVertices.isEmpty == false {
                encoder.setRenderPipelineState(mprIntersectionPipelineState)
                encoder.setDepthStencilState(mprDepthStencilState)
                if setMPRVertexData(intersectionVertices, on: encoder) {
                    encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: intersectionVertices.count)
                }
            }

            if displayMode != .mpr3D {
                let borderVertices = makePlanarMPRPreviewBorderVertices(for: pane.plane, viewport: pane.viewport, unitScale: pane.unitScale)
                guard borderVertices.isEmpty == false else {
                    continue
                }
                encoder.setRenderPipelineState(mprBorderPipelineState)
                encoder.setDepthStencilState(mprDepthStencilState)
                if setMPRVertexData(borderVertices, on: encoder) {
                    encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: borderVertices.count)
                }
            }
        }
    }

    private func mprMaxVoxel() -> SIMD3<Float> {
        SIMD3<Float>(
            Float(max(baseVolumeDimensions.x - 1, 0)),
            Float(max(baseVolumeDimensions.y - 1, 0)),
            Float(max(baseVolumeDimensions.z - 1, 0))
        )
    }

    private func mprPlaneCorners(for plane: MetalMPRPlane) -> [SIMD3<Float>] {
        let maxVoxel = mprMaxVoxel()
        guard maxVoxel.x > 0, maxVoxel.y > 0, maxVoxel.z > 0 else {
            return []
        }

        switch plane {
        case .axial:
            return [
                mprPlaneVoxel(for: .axial, first: 0, second: 0),
                mprPlaneVoxel(for: .axial, first: maxVoxel.x, second: 0),
                mprPlaneVoxel(for: .axial, first: maxVoxel.x, second: maxVoxel.y),
                mprPlaneVoxel(for: .axial, first: 0, second: maxVoxel.y),
            ]
        case .coronal:
            return [
                mprPlaneVoxel(for: .coronal, first: 0, second: 0),
                mprPlaneVoxel(for: .coronal, first: maxVoxel.x, second: 0),
                mprPlaneVoxel(for: .coronal, first: maxVoxel.x, second: maxVoxel.z),
                mprPlaneVoxel(for: .coronal, first: 0, second: maxVoxel.z),
            ]
        case .sagittal:
            return [
                mprPlaneVoxel(for: .sagittal, first: 0, second: 0),
                mprPlaneVoxel(for: .sagittal, first: maxVoxel.y, second: 0),
                mprPlaneVoxel(for: .sagittal, first: maxVoxel.y, second: maxVoxel.z),
                mprPlaneVoxel(for: .sagittal, first: 0, second: maxVoxel.z),
            ]
        }
    }

    private func mprPlaneVoxel(for plane: MetalMPRPlane, first: Float, second: Float) -> SIMD3<Float> {
        mprPlaneVoxel(for: plane, first: first, second: second, overridingComponent: nil, angle: nil)
    }

    private func mprPlaneVoxel(
        for plane: MetalMPRPlane,
        first: Float,
        second: Float,
        overridingComponent componentIndex: Int?,
        angle overrideAngle: Float?
    ) -> SIMD3<Float> {
        let maxVoxel = mprMaxVoxel()
        let sagittalX = min(max(mprPlaneVoxel.x, 0), maxVoxel.x)
        let coronalY = min(max(mprPlaneVoxel.y, 0), maxVoxel.y)
        let axialZ = min(max(mprPlaneVoxel.z, 0), maxVoxel.z)

        switch plane {
        case .axial:
            let tilt = mprTilt(for: .axial, overridingComponent: componentIndex, angle: overrideAngle)
            let axialX = first
            let axialY = second
            let z = axialZ +
                (axialX - mprAxialTiltPivot.x) * tan(tilt.x) +
                (axialY - mprAxialTiltPivot.y) * tan(tilt.y)
            return SIMD3<Float>(axialX, axialY, z)
        case .coronal:
            let tilt = mprTilt(for: .coronal, overridingComponent: componentIndex, angle: overrideAngle)
            let coronalX = first
            let coronalZ = second
            let y = coronalY +
                (coronalX - mprCoronalTiltPivot.x) * tan(tilt.x) +
                (coronalZ - mprCoronalTiltPivot.y) * tan(tilt.y)
            return SIMD3<Float>(coronalX, y, coronalZ)
        case .sagittal:
            let tilt = mprTilt(for: .sagittal, overridingComponent: componentIndex, angle: overrideAngle)
            let sagittalY = first
            let sagittalZ = second
            let x = sagittalX +
                (sagittalY - mprSagittalTiltPivot.x) * tan(tilt.x) +
                (sagittalZ - mprSagittalTiltPivot.y) * tan(tilt.y)
            return SIMD3<Float>(x, sagittalY, sagittalZ)
        }
    }

    private func mprTilt(
        for plane: MetalMPRPlane,
        overridingComponent componentIndex: Int?,
        angle overrideAngle: Float?
    ) -> SIMD2<Float> {
        var tilt: SIMD2<Float>
        switch plane {
        case .axial:
            tilt = mprAxialTilt
        case .coronal:
            tilt = mprCoronalTilt
        case .sagittal:
            tilt = mprSagittalTilt
        }
        if let componentIndex, let overrideAngle {
            if componentIndex == 0 {
                tilt.x = overrideAngle
            } else {
                tilt.y = overrideAngle
            }
        }
        return tilt
    }

    private func makeMPRVertices() -> [MetalMPRVertex] {
        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(18)
        appendMPRPlane(to: &vertices, corners: mprPlaneCorners(for: .axial))
        appendMPRPlane(to: &vertices, corners: mprPlaneCorners(for: .coronal))
        appendMPRPlane(to: &vertices, corners: mprPlaneCorners(for: .sagittal))

        return vertices
    }

    private func makeMPRPlaneHighlightVertices() -> [MetalMPRVertex] {
        guard let hoveredMPRPlane else { return [] }
        let maxX = Float(max(baseVolumeDimensions.x - 1, 0))
        let maxY = Float(max(baseVolumeDimensions.y - 1, 0))
        let maxZ = Float(max(baseVolumeDimensions.z - 1, 0))
        guard maxX > 0, maxY > 0, maxZ > 0 else {
            return []
        }

        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(120)

        switch hoveredMPRPlane {
        case .axial:
            appendMPRHighlightBorder(
                to: &vertices,
                minU: 0,
                maxU: maxX,
                minV: 0,
                maxV: maxY,
                uInset: mprHighlightVoxelInset(forAxis: 0),
                vInset: mprHighlightVoxelInset(forAxis: 1)
            ) { u, v in
                self.mprPlaneVoxel(for: .axial, first: u, second: v)
            }
        case .coronal:
            appendMPRHighlightBorder(
                to: &vertices,
                minU: 0,
                maxU: maxX,
                minV: 0,
                maxV: maxZ,
                uInset: mprHighlightVoxelInset(forAxis: 0),
                vInset: mprHighlightVoxelInset(forAxis: 2)
            ) { u, v in
                self.mprPlaneVoxel(for: .coronal, first: u, second: v)
            }
        case .sagittal:
            appendMPRHighlightBorder(
                to: &vertices,
                minU: 0,
                maxU: maxY,
                minV: 0,
                maxV: maxZ,
                uInset: mprHighlightVoxelInset(forAxis: 1),
                vInset: mprHighlightVoxelInset(forAxis: 2)
            ) { u, v in
                self.mprPlaneVoxel(for: .sagittal, first: u, second: v)
            }
        }

        return vertices
    }

    private func makeMPRBorderVertices() -> [MetalMPRVertex] {
        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(24)
        appendMPRPlaneBorder(to: &vertices, plane: .axial)
        appendMPRPlaneBorder(to: &vertices, plane: .coronal)
        appendMPRPlaneBorder(to: &vertices, plane: .sagittal)

        return vertices
    }

    private func makeMPRIntersectionVertices() -> [MetalMPRVertex] {
        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(6)
        appendMPRPlaneIntersection(to: &vertices, firstPlane: .axial, secondPlane: .coronal)
        appendMPRPlaneIntersection(to: &vertices, firstPlane: .axial, secondPlane: .sagittal)
        appendMPRPlaneIntersection(to: &vertices, firstPlane: .coronal, secondPlane: .sagittal)
        return vertices
    }

    private func appendMPRPlaneIntersection(
        to vertices: inout [MetalMPRVertex],
        firstPlane: MetalMPRPlane,
        secondPlane: MetalMPRPlane
    ) {
        guard let segment = mprIntersectionSegment(
            firstCorners: mprPlaneCorners(for: firstPlane),
            secondCorners: mprPlaneCorners(for: secondPlane)
        ) else {
            return
        }
        vertices.append(MetalMPRVertex(position: mprDisplayPosition(for: segment.0), baseVoxel: segment.0))
        vertices.append(MetalMPRVertex(position: mprDisplayPosition(for: segment.1), baseVoxel: segment.1))
    }

    private func appendMPRPlane(to vertices: inout [MetalMPRVertex], corners: [SIMD3<Float>]) {
        guard corners.count == 4 else { return }
        let planeVertices = [
            corners[0], corners[1], corners[2],
            corners[0], corners[2], corners[3],
        ]
        vertices.append(contentsOf: planeVertices.map {
            MetalMPRVertex(position: mprDisplayPosition(for: $0), baseVoxel: $0)
        })
    }

    private func makePlanarMPRPreviewVertices(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> [MetalMPRVertex] {
        guard let geometry = planarMPRPreviewGeometry(for: plane, viewport: viewport, unitScale: unitScale) else {
            return []
        }

        let planeFractions = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(0, 1),
        ]
        let positions = planeFractions.map { fraction -> SIMD3<Float> in
            let screen = geometry.orientation.screenFractions(
                first: fraction.x,
                second: fraction.y
            )
            return SIMD3<Float>(
                -geometry.halfWidth + screen.x * geometry.halfWidth * 2 + geometry.panOffset.x,
                -geometry.halfHeight + screen.y * geometry.halfHeight * 2 + geometry.panOffset.y,
                0
            )
        }

        return [
            MetalMPRVertex(position: positions[0], baseVoxel: geometry.corners[0]),
            MetalMPRVertex(position: positions[1], baseVoxel: geometry.corners[1]),
            MetalMPRVertex(position: positions[2], baseVoxel: geometry.corners[2]),
            MetalMPRVertex(position: positions[0], baseVoxel: geometry.corners[0]),
            MetalMPRVertex(position: positions[2], baseVoxel: geometry.corners[2]),
            MetalMPRVertex(position: positions[3], baseVoxel: geometry.corners[3]),
        ]
    }

    private func planarMPRPreviewGeometry(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> (
        corners: [SIMD3<Float>],
        halfWidth: Float,
        halfHeight: Float,
        panOffset: SIMD2<Float>,
        orientation: MetalMPRPreviewOrientation
    )? {
        let corners = mprPlaneCorners(for: plane)
        guard corners.count == 4,
              let orientation = mprPreviewOrientation(for: plane, corners: corners),
              viewport.width > 1,
              viewport.height > 1 else {
            return nil
        }

        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let firstLength = simd_length(worldCorners[1] - worldCorners[0])
        let secondLength = simd_length(worldCorners[3] - worldCorners[0])
        let horizontalLength = orientation.horizontalUsesFirstCoordinate
            ? firstLength
            : secondLength
        let verticalLength = orientation.horizontalUsesFirstCoordinate
            ? secondLength
            : firstLength
        let planeAspect = horizontalLength / max(verticalLength, 0.0001)
        let viewportAspect = Float(viewport.width / max(viewport.height, 1))
        let padding: Float = 0.92
        let contentScale = displayMode == .mpr3D ? zoomScale : 1
        var halfWidth = padding
        var halfHeight = padding
        if planeAspect > viewportAspect {
            halfHeight = padding * viewportAspect / max(planeAspect, 0.0001)
        } else {
            halfWidth = padding * planeAspect / max(viewportAspect, 0.0001)
        }
        halfWidth *= contentScale
        halfHeight *= contentScale

        return (
            corners: corners,
            halfWidth: halfWidth,
            halfHeight: halfHeight,
            panOffset: planarMPRPreviewPanOffset(
                for: plane,
                viewport: viewport,
                unitScale: unitScale
            ),
            orientation: orientation
        )
    }

    private func planarMPRPreviewPanOffset(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> SIMD2<Float> {
        guard displayMode == .mpr3D else {
            return SIMD2<Float>(repeating: 0)
        }

        let panePanOffset = mpr3DPanOffsets[plane] ?? .zero
        let scale = Float(max(unitScale, 0.0001))
        return SIMD2<Float>(
            panePanOffset.x * scale * 2 / max(Float(viewport.width), 1),
            panePanOffset.y * scale * 2 / max(Float(viewport.height), 1)
        )
    }

    private func planarMPRPreviewPosition(
        for baseVoxel: SIMD3<Float>,
        plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> SIMD3<Float>? {
        guard let geometry = planarMPRPreviewGeometry(for: plane, viewport: viewport, unitScale: unitScale) else {
            return nil
        }

        let local = mprPlaneLocalCoordinates(for: plane, baseVoxel: baseVoxel)
        let cornerLocals = geometry.corners.map { mprPlaneLocalCoordinates(for: plane, baseVoxel: $0) }
        let minU = cornerLocals.map { $0.x }.min() ?? 0
        let maxU = cornerLocals.map { $0.x }.max() ?? 1
        let minV = cornerLocals.map { $0.y }.min() ?? 0
        let maxV = cornerLocals.map { $0.y }.max() ?? 1
        guard maxU - minU > 0.0001,
              maxV - minV > 0.0001 else {
            return nil
        }

        let uFraction = (local.x - minU) / (maxU - minU)
        let vFraction = (local.y - minV) / (maxV - minV)
        let screen = geometry.orientation.screenFractions(
            first: uFraction,
            second: vFraction
        )
        let x = -geometry.halfWidth + screen.x * geometry.halfWidth * 2
        let y = -geometry.halfHeight + screen.y * geometry.halfHeight * 2

        return SIMD3<Float>(x + geometry.panOffset.x, y + geometry.panOffset.y, 0)
    }

    private func makeMPRTumourSeedSphereVertices() -> [MetalMPRVertex] {
        guard tumourSeeds.isEmpty == false else { return [] }

        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(tumourSeeds.count * 16 * 24 * 6)
        let worldToBaseVoxel = simd_inverse(fixedVoxelToWorld)
        for seed in tumourSeeds {
            let centerWorld = SIMD3<Float>(Float(seed.dicomX), Float(seed.dicomY), Float(seed.dicomZ))
            appendMPRTumourSeedSphere(
                to: &vertices,
                centerWorld: centerWorld,
                radiusMM: Float(max(seed.diameterMM * 0.5, 0.05)),
                worldToBaseVoxel: worldToBaseVoxel
            )
        }
        return vertices
    }

    private func makePlanarMPRPreviewTumourSeedCrossSectionVertices(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> [MetalMPRVertex] {
        guard tumourSeeds.isEmpty == false else { return [] }

        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(tumourSeeds.count * 32 * 3)
        appendMPRTumourSeedCrossSections(to: &vertices, for: plane) { _, baseVoxel in
            planarMPRPreviewPosition(for: baseVoxel, plane: plane, viewport: viewport, unitScale: unitScale)
        }
        return vertices
    }

    private func makePlanarMPRPreviewSliceThicknessVertices(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> [MetalMPRVertex] {
        let currentCorners = mprPlaneCorners(for: plane)
        guard currentCorners.count == 4 else {
            return []
        }

        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(12)
        for otherPlane in Self.mprPlanes where otherPlane != plane {
            guard let band = mprSliceThicknessBandSegments(
                currentPlaneCorners: currentCorners,
                slicePlane: otherPlane
            ),
                  let startA = planarMPRPreviewPosition(for: band.first.0, plane: plane, viewport: viewport, unitScale: unitScale),
                  let endA = planarMPRPreviewPosition(for: band.first.1, plane: plane, viewport: viewport, unitScale: unitScale),
                  let startB = planarMPRPreviewPosition(for: band.second.0, plane: plane, viewport: viewport, unitScale: unitScale),
                  let endB = planarMPRPreviewPosition(for: band.second.1, plane: plane, viewport: viewport, unitScale: unitScale) else {
                continue
            }

            let color = mprAxisColor(for: otherPlane, alpha: 0.18)
            vertices.append(MetalMPRVertex(position: startA, baseVoxel: band.first.0, color: color))
            vertices.append(MetalMPRVertex(position: endA, baseVoxel: band.first.1, color: color))
            vertices.append(MetalMPRVertex(position: endB, baseVoxel: band.second.1, color: color))
            vertices.append(MetalMPRVertex(position: startA, baseVoxel: band.first.0, color: color))
            vertices.append(MetalMPRVertex(position: endB, baseVoxel: band.second.1, color: color))
            vertices.append(MetalMPRVertex(position: startB, baseVoxel: band.second.0, color: color))
        }
        return vertices
    }

    private func makePlanarMPRPreviewIntersectionVertices(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> [MetalMPRVertex] {
        let otherPlanes = Self.mprPlanes.filter { $0 != plane }
        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(otherPlanes.count * 6)

        for otherPlane in otherPlanes {
            guard let segment = mprIntersectionSegment(
                firstCorners: mprPlaneCorners(for: plane),
                secondCorners: mprPlaneCorners(for: otherPlane)
            ),
                  let start = planarMPRPreviewPosition(for: segment.0, plane: plane, viewport: viewport, unitScale: unitScale),
                  let end = planarMPRPreviewPosition(for: segment.1, plane: plane, viewport: viewport, unitScale: unitScale) else {
                continue
            }

            let color = mprAxisColor(for: otherPlane)
            appendPlanarMPRPreviewReferenceLine(
                to: &vertices,
                start: start,
                end: end,
                startBaseVoxel: segment.0,
                endBaseVoxel: segment.1,
                color: color,
                viewport: viewport
            )
        }

        return vertices
    }

    private func appendPlanarMPRPreviewReferenceLine(
        to vertices: inout [MetalMPRVertex],
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        startBaseVoxel: SIMD3<Float>,
        endBaseVoxel: SIMD3<Float>,
        color: SIMD4<Float>,
        viewport: MTLViewport
    ) {
        let viewportWidth = max(Float(viewport.width), 1)
        let viewportHeight = max(Float(viewport.height), 1)
        let screenDelta = SIMD2<Float>(
            (end.x - start.x) * viewportWidth,
            (end.y - start.y) * viewportHeight
        )
        let lineLength = simd_length(screenDelta)
        if lineLength > 0.0001 {
            let sideOffsetPixels: Float = 1
            let sideColor = SIMD4<Float>(color.x, color.y, color.z, 0.5)
            let normal = SIMD2<Float>(-screenDelta.y, screenDelta.x) / lineLength
            let offset = SIMD2<Float>(
                normal.x * sideOffsetPixels * 2 / viewportWidth,
                normal.y * sideOffsetPixels * 2 / viewportHeight
            )
            appendPlanarMPRPreviewLine(
                to: &vertices,
                start: SIMD3<Float>(start.x - offset.x, start.y - offset.y, start.z),
                end: SIMD3<Float>(end.x - offset.x, end.y - offset.y, end.z),
                startBaseVoxel: startBaseVoxel,
                endBaseVoxel: endBaseVoxel,
                color: sideColor
            )
            appendPlanarMPRPreviewLine(
                to: &vertices,
                start: SIMD3<Float>(start.x + offset.x, start.y + offset.y, start.z),
                end: SIMD3<Float>(end.x + offset.x, end.y + offset.y, end.z),
                startBaseVoxel: startBaseVoxel,
                endBaseVoxel: endBaseVoxel,
                color: sideColor
            )
        }

        appendPlanarMPRPreviewLine(
            to: &vertices,
            start: start,
            end: end,
            startBaseVoxel: startBaseVoxel,
            endBaseVoxel: endBaseVoxel,
            color: color
        )
    }

    private func appendPlanarMPRPreviewLine(
        to vertices: inout [MetalMPRVertex],
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        startBaseVoxel: SIMD3<Float>,
        endBaseVoxel: SIMD3<Float>,
        color: SIMD4<Float>
    ) {
        vertices.append(MetalMPRVertex(position: start, baseVoxel: startBaseVoxel, color: color))
        vertices.append(MetalMPRVertex(position: end, baseVoxel: endBaseVoxel, color: color))
    }

    private func mprSliceThicknessBandSegments(
        currentPlaneCorners: [SIMD3<Float>],
        slicePlane: MetalMPRPlane
    ) -> (
        first: (SIMD3<Float>, SIMD3<Float>),
        second: (SIMD3<Float>, SIMD3<Float>)
    )? {
        let sliceCorners = mprPlaneCorners(for: slicePlane)
        guard currentPlaneCorners.count == 4,
              sliceCorners.count == 4,
              let centerSegment = mprIntersectionSegment(
                firstCorners: currentPlaneCorners,
                secondCorners: sliceCorners
              ),
              let normal = mprPlaneNormalWorld(for: sliceCorners) else {
            return nil
        }

        let halfThickness = mprSliceThicknessMM(for: slicePlane) * 0.5
        guard halfThickness > 0.0001 else {
            return nil
        }

        let firstCorners = mprOffsetPlaneCorners(sliceCorners, normalWorld: normal, offsetMM: -halfThickness)
        let secondCorners = mprOffsetPlaneCorners(sliceCorners, normalWorld: normal, offsetMM: halfThickness)
        guard let firstSegment = mprIntersectionSegment(
            firstCorners: currentPlaneCorners,
            secondCorners: firstCorners
        ),
              let secondSegment = mprIntersectionSegment(
                firstCorners: currentPlaneCorners,
                secondCorners: secondCorners
              ) else {
            return nil
        }

        return (
            first: mprSegment(firstSegment, orderedLike: centerSegment),
            second: mprSegment(secondSegment, orderedLike: centerSegment)
        )
    }

    private func mprPlaneNormalWorld(for corners: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard corners.count == 4 else {
            return nil
        }
        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let normal = simd_cross(worldCorners[1] - worldCorners[0], worldCorners[2] - worldCorners[0])
        guard simd_length_squared(normal) > 0.000001 else {
            return nil
        }
        return simd_normalize(normal)
    }

    private func mprOffsetPlaneCorners(
        _ corners: [SIMD3<Float>],
        normalWorld: SIMD3<Float>,
        offsetMM: Float
    ) -> [SIMD3<Float>] {
        let worldToBaseVoxel = simd_inverse(fixedVoxelToWorld)
        return corners.map { corner in
            let world = mprDisplayWorldPosition(for: corner) + normalWorld * offsetMM
            return mprBaseVoxel(forWorld: world, worldToBaseVoxel: worldToBaseVoxel)
        }
    }

    private func mprSegment(
        _ segment: (SIMD3<Float>, SIMD3<Float>),
        orderedLike reference: (SIMD3<Float>, SIMD3<Float>)
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let referenceStart = mprDisplayWorldPosition(for: reference.0)
        let referenceEnd = mprDisplayWorldPosition(for: reference.1)
        let direction = referenceEnd - referenceStart
        guard simd_length_squared(direction) > 0.000001 else {
            return segment
        }

        let normalizedDirection = simd_normalize(direction)
        let firstDistance = simd_dot(mprDisplayWorldPosition(for: segment.0) - referenceStart, normalizedDirection)
        let secondDistance = simd_dot(mprDisplayWorldPosition(for: segment.1) - referenceStart, normalizedDirection)
        return firstDistance <= secondDistance ? segment : (segment.1, segment.0)
    }

    private func mprSliceThicknessMM(for plane: MetalMPRPlane) -> Float {
        let column: SIMD4<Float>
        switch plane {
        case .sagittal:
            column = fixedVoxelToWorld.columns.0
        case .coronal:
            column = fixedVoxelToWorld.columns.1
        case .axial:
            column = fixedVoxelToWorld.columns.2
        }
        return max(simd_length(SIMD3<Float>(column.x, column.y, column.z)), 0.001)
    }

    private func appendMPRTumourSeedCrossSections(
        to vertices: inout [MetalMPRVertex],
        for plane: MetalMPRPlane,
        makePosition: (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>?
    ) {
        let corners = mprPlaneCorners(for: plane)
        guard corners.count == 4,
              mprPlaneEquation(for: corners) != nil else {
            return
        }

        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let worldNormal = simd_cross(worldCorners[1] - worldCorners[0], worldCorners[2] - worldCorners[0])
        guard simd_length_squared(worldNormal) > 0.000001 else {
            return
        }

        let normal = simd_normalize(worldNormal)
        var uAxis = worldCorners[1] - worldCorners[0]
        if simd_length_squared(uAxis) <= 0.000001 {
            uAxis = worldCorners[3] - worldCorners[0]
        }
        guard simd_length_squared(uAxis) > 0.000001 else {
            return
        }
        uAxis = simd_normalize(uAxis)
        let vAxis = simd_normalize(simd_cross(normal, uAxis))
        let worldToBaseVoxel = simd_inverse(fixedVoxelToWorld)
        let segmentCount = 32

        for seed in tumourSeeds {
            let centerWorld = SIMD3<Float>(Float(seed.dicomX), Float(seed.dicomY), Float(seed.dicomZ))
            let radiusMM = Float(max(seed.diameterMM * 0.5, 0.05))
            let distanceFromPlane = simd_dot(centerWorld - worldCorners[0], normal)
            guard abs(distanceFromPlane) <= radiusMM else {
                continue
            }

            let crossSectionRadiusMM = sqrt(max(radiusMM * radiusMM - distanceFromPlane * distanceFromPlane, 0))
            let projectedWorld = centerWorld - normal * distanceFromPlane
            let projectedVoxel = mprBaseVoxel(forWorld: projectedWorld, worldToBaseVoxel: worldToBaseVoxel)
            guard mprPoint(projectedVoxel, isInsideQuad: corners),
                  let centerPosition = makePosition(projectedWorld, projectedVoxel) else {
                continue
            }

            for segmentIndex in 0..<segmentCount {
                let a0 = Float(segmentIndex) / Float(segmentCount) * Float.pi * 2
                let a1 = Float(segmentIndex + 1) / Float(segmentCount) * Float.pi * 2
                let p0World = projectedWorld + (cos(a0) * uAxis + sin(a0) * vAxis) * crossSectionRadiusMM
                let p1World = projectedWorld + (cos(a1) * uAxis + sin(a1) * vAxis) * crossSectionRadiusMM
                let p0Voxel = mprBaseVoxel(forWorld: p0World, worldToBaseVoxel: worldToBaseVoxel)
                let p1Voxel = mprBaseVoxel(forWorld: p1World, worldToBaseVoxel: worldToBaseVoxel)
                guard let p0Position = makePosition(p0World, p0Voxel),
                      let p1Position = makePosition(p1World, p1Voxel) else {
                    continue
                }
                vertices.append(MetalMPRVertex(position: centerPosition, baseVoxel: projectedVoxel))
                vertices.append(MetalMPRVertex(position: p0Position, baseVoxel: p0Voxel))
                vertices.append(MetalMPRVertex(position: p1Position, baseVoxel: p1Voxel))
            }
        }
    }

    private func mprTumourSeedIdentifier(
        at point: CGPoint,
        inPreviewPlane plane: MetalMPRPlane,
        paneRect: CGRect
    ) -> String? {
        let corners = mprPlaneCorners(for: plane)
        guard corners.count == 4,
              mprPlaneEquation(for: corners) != nil else {
            return nil
        }

        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let worldNormal = simd_cross(worldCorners[1] - worldCorners[0], worldCorners[2] - worldCorners[0])
        guard simd_length_squared(worldNormal) > 0.000001 else {
            return nil
        }

        let normal = simd_normalize(worldNormal)
        var uAxis = worldCorners[1] - worldCorners[0]
        if simd_length_squared(uAxis) <= 0.000001 {
            uAxis = worldCorners[3] - worldCorners[0]
        }
        guard simd_length_squared(uAxis) > 0.000001 else {
            return nil
        }
        uAxis = simd_normalize(uAxis)

        let viewport = mprPreviewViewport(for: paneRect)
        let worldToBaseVoxel = simd_inverse(fixedVoxelToWorld)
        let hitPoint = SIMD2<Float>(Float(point.x), Float(point.y))
        var bestIdentifier: String?
        var bestDistance = Float.greatestFiniteMagnitude

        for seed in tumourSeeds {
            let centerWorld = SIMD3<Float>(Float(seed.dicomX), Float(seed.dicomY), Float(seed.dicomZ))
            let radiusMM = Float(max(seed.diameterMM * 0.5, 0.05))
            let distanceFromPlane = simd_dot(centerWorld - worldCorners[0], normal)
            guard abs(distanceFromPlane) <= radiusMM else {
                continue
            }

            let crossSectionRadiusMM = sqrt(max(radiusMM * radiusMM - distanceFromPlane * distanceFromPlane, 0))
            let projectedWorld = centerWorld - normal * distanceFromPlane
            let projectedVoxel = mprBaseVoxel(forWorld: projectedWorld, worldToBaseVoxel: worldToBaseVoxel)
            guard mprPoint(projectedVoxel, isInsideQuad: corners),
                  let centerPosition = planarMPRPreviewPosition(for: projectedVoxel, plane: plane, viewport: viewport) else {
                continue
            }

            let centerPoint = mprPreviewScreenPoint(for: centerPosition, in: paneRect)
            var hitRadius: Float = 8
            if crossSectionRadiusMM > 0.0001 {
                let edgeWorld = projectedWorld + uAxis * crossSectionRadiusMM
                let edgeVoxel = mprBaseVoxel(forWorld: edgeWorld, worldToBaseVoxel: worldToBaseVoxel)
                if let edgePosition = planarMPRPreviewPosition(for: edgeVoxel, plane: plane, viewport: viewport) {
                    let edgePoint = mprPreviewScreenPoint(for: edgePosition, in: paneRect)
                    hitRadius = max(simd_distance(centerPoint, edgePoint), hitRadius)
                }
            }

            let distance = simd_distance(centerPoint, hitPoint)
            guard distance <= hitRadius,
                  distance < bestDistance else {
                continue
            }
            bestDistance = distance
            bestIdentifier = seed.identifier
        }

        return bestIdentifier
    }

    private func appendMPRTumourSeedSphere(
        to vertices: inout [MetalMPRVertex],
        centerWorld: SIMD3<Float>,
        radiusMM: Float,
        worldToBaseVoxel: simd_float4x4
    ) {
        let latitudes = 16
        let longitudes = 24

        for latitude in 0..<latitudes {
            let v0 = Float(latitude) / Float(latitudes)
            let v1 = Float(latitude + 1) / Float(latitudes)
            let theta0 = v0 * .pi
            let theta1 = v1 * .pi

            for longitude in 0..<longitudes {
                let u0 = Float(longitude) / Float(longitudes)
                let u1 = Float(longitude + 1) / Float(longitudes)
                let phi0 = u0 * 2.0 * .pi
                let phi1 = u1 * 2.0 * .pi

                let p00 = centerWorld + mprSphereNormal(theta: theta0, phi: phi0) * radiusMM
                let p01 = centerWorld + mprSphereNormal(theta: theta0, phi: phi1) * radiusMM
                let p10 = centerWorld + mprSphereNormal(theta: theta1, phi: phi0) * radiusMM
                let p11 = centerWorld + mprSphereNormal(theta: theta1, phi: phi1) * radiusMM

                appendMPRTumourSeedSphereTriangle(&vertices, p00, p10, p11, worldToBaseVoxel: worldToBaseVoxel)
                appendMPRTumourSeedSphereTriangle(&vertices, p00, p11, p01, worldToBaseVoxel: worldToBaseVoxel)
            }
        }
    }

    private func appendMPRTumourSeedSphereTriangle(
        _ vertices: inout [MetalMPRVertex],
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>,
        _ third: SIMD3<Float>,
        worldToBaseVoxel: simd_float4x4
    ) {
        for worldPoint in [first, second, third] {
            vertices.append(MetalMPRVertex(
                position: mprDisplayPosition(forWorld: worldPoint),
                baseVoxel: mprBaseVoxel(forWorld: worldPoint, worldToBaseVoxel: worldToBaseVoxel)
            ))
        }
    }

    private func mprSphereNormal(theta: Float, phi: Float) -> SIMD3<Float> {
        SIMD3<Float>(
            sin(theta) * cos(phi),
            cos(theta),
            sin(theta) * sin(phi)
        )
    }

    private func mprBaseVoxel(
        forWorld world: SIMD3<Float>,
        worldToBaseVoxel: simd_float4x4
    ) -> SIMD3<Float> {
        let baseVoxel = worldToBaseVoxel * SIMD4<Float>(world, 1)
        return SIMD3<Float>(baseVoxel.x, baseVoxel.y, baseVoxel.z)
    }

    private func makePlanarMPRPreviewBorderVertices(
        for plane: MetalMPRPlane,
        viewport: MTLViewport,
        unitScale: CGFloat = 1
    ) -> [MetalMPRVertex] {
        let filledVertices = makePlanarMPRPreviewVertices(for: plane, viewport: viewport, unitScale: unitScale)
        guard filledVertices.count == 6 else { return [] }

        let color = mprAxisColor(for: plane)
        let corners = [
            filledVertices[0],
            filledVertices[1],
            filledVertices[2],
            filledVertices[5],
        ]
        return [
            corners[0].withColor(color), corners[1].withColor(color),
            corners[1].withColor(color), corners[2].withColor(color),
            corners[2].withColor(color), corners[3].withColor(color),
            corners[3].withColor(color), corners[0].withColor(color),
        ]
    }

    private func mprIntersectionSegment(
        firstCorners: [SIMD3<Float>],
        secondCorners: [SIMD3<Float>]
    ) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard firstCorners.count == 4,
              secondCorners.count == 4,
              let firstPlaneEquation = mprPlaneEquation(for: firstCorners),
              let secondPlaneEquation = mprPlaneEquation(for: secondCorners) else {
            return nil
        }

        var points: [SIMD3<Float>] = []
        appendMPRQuadEdgeIntersections(
            to: &points,
            edgeCorners: firstCorners,
            targetCorners: secondCorners,
            targetPlane: secondPlaneEquation
        )
        appendMPRQuadEdgeIntersections(
            to: &points,
            edgeCorners: secondCorners,
            targetCorners: firstCorners,
            targetPlane: firstPlaneEquation
        )

        var uniquePoints: [SIMD3<Float>] = []
        for point in points where uniquePoints.contains(where: { simd_distance_squared($0, point) < 0.0001 }) == false {
            uniquePoints.append(point)
        }

        guard uniquePoints.count >= 2 else { return nil }
        var bestPair = (uniquePoints[0], uniquePoints[1])
        var bestDistance = simd_distance_squared(uniquePoints[0], uniquePoints[1])
        for firstIndex in 0..<(uniquePoints.count - 1) {
            for secondIndex in (firstIndex + 1)..<uniquePoints.count {
                let distance = simd_distance_squared(uniquePoints[firstIndex], uniquePoints[secondIndex])
                if distance > bestDistance {
                    bestDistance = distance
                    bestPair = (uniquePoints[firstIndex], uniquePoints[secondIndex])
                }
            }
        }
        return bestDistance > 0.0001 ? bestPair : nil
    }

    private func appendMPRQuadEdgeIntersections(
        to points: inout [SIMD3<Float>],
        edgeCorners: [SIMD3<Float>],
        targetCorners: [SIMD3<Float>],
        targetPlane: (normal: SIMD3<Float>, d: Float)
    ) {
        let edges = [
            (edgeCorners[0], edgeCorners[1]),
            (edgeCorners[1], edgeCorners[2]),
            (edgeCorners[2], edgeCorners[3]),
            (edgeCorners[3], edgeCorners[0]),
        ]

        for edge in edges {
            guard let intersection = mprSegmentPlaneIntersection(
                from: edge.0,
                to: edge.1,
                plane: targetPlane
            ), mprPoint(intersection, isInsideQuad: targetCorners) else {
                continue
            }
            points.append(intersection)
        }
    }

    private func mprPlaneEquation(for corners: [SIMD3<Float>]) -> (normal: SIMD3<Float>, d: Float)? {
        guard corners.count >= 3 else { return nil }
        let normal = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
        guard simd_length_squared(normal) > 0.000001 else { return nil }
        let normalized = simd_normalize(normal)
        return (normalized, -simd_dot(normalized, corners[0]))
    }

    private func mprSegmentPlaneIntersection(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        plane: (normal: SIMD3<Float>, d: Float)
    ) -> SIMD3<Float>? {
        let startDistance = simd_dot(plane.normal, start) + plane.d
        let endDistance = simd_dot(plane.normal, end) + plane.d
        let denominator = startDistance - endDistance

        if abs(startDistance) < 0.0001, abs(endDistance) < 0.0001 {
            return nil
        }
        guard abs(denominator) > 0.000001 else { return nil }

        let t = startDistance / denominator
        guard t >= -0.0001, t <= 1.0001 else { return nil }
        return start + (end - start) * min(max(t, 0), 1)
    }

    private func mprPoint(_ point: SIMD3<Float>, isInsideQuad corners: [SIMD3<Float>]) -> Bool {
        guard corners.count == 4 else { return false }
        return mprPoint(point, isInsideTriangle: [corners[0], corners[1], corners[2]]) ||
            mprPoint(point, isInsideTriangle: [corners[0], corners[2], corners[3]])
    }

    private func mprPoint(_ point: SIMD3<Float>, isInsideTriangle corners: [SIMD3<Float>]) -> Bool {
        guard corners.count == 3 else { return false }
        let v0 = corners[1] - corners[0]
        let v1 = corners[2] - corners[0]
        let v2 = point - corners[0]
        let dot00 = simd_dot(v0, v0)
        let dot01 = simd_dot(v0, v1)
        let dot02 = simd_dot(v0, v2)
        let dot11 = simd_dot(v1, v1)
        let dot12 = simd_dot(v1, v2)
        let denominator = dot00 * dot11 - dot01 * dot01
        guard abs(denominator) > 0.000001 else { return false }
        let u = (dot11 * dot02 - dot01 * dot12) / denominator
        let v = (dot00 * dot12 - dot01 * dot02) / denominator
        return u >= -0.0001 && v >= -0.0001 && u + v <= 1.0001
    }

    private func appendMPRHighlightBorder(
        to vertices: inout [MetalMPRVertex],
        minU: Float,
        maxU: Float,
        minV: Float,
        maxV: Float,
        uInset: Float,
        vInset: Float,
        makeVoxel: (Float, Float) -> SIMD3<Float>
    ) {
        let clampedUInset = min(max(uInset, 0), (maxU - minU) * 0.5)
        let clampedVInset = min(max(vInset, 0), (maxV - minV) * 0.5)
        guard clampedUInset > 0, clampedVInset > 0 else { return }

        let innerMinU = minU + clampedUInset
        let innerMaxU = maxU - clampedUInset
        let innerMinV = minV + clampedVInset
        let innerMaxV = maxV - clampedVInset

        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(innerMinU, minV), makeVoxel(innerMaxU, minV), makeVoxel(innerMaxU, innerMinV), makeVoxel(innerMinU, innerMinV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(innerMinU, innerMaxV), makeVoxel(innerMaxU, innerMaxV), makeVoxel(innerMaxU, maxV), makeVoxel(innerMinU, maxV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(minU, innerMinV), makeVoxel(innerMinU, innerMinV), makeVoxel(innerMinU, innerMaxV), makeVoxel(minU, innerMaxV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(innerMaxU, innerMinV), makeVoxel(maxU, innerMinV), makeVoxel(maxU, innerMaxV), makeVoxel(innerMaxU, innerMaxV),
        ])

        appendMPRHighlightCorner(to: &vertices, centerU: innerMinU, centerV: innerMinV, outerU: minU, outerV: minV, uRadius: clampedUInset, vRadius: clampedVInset, makeVoxel: makeVoxel)
        appendMPRHighlightCorner(to: &vertices, centerU: innerMaxU, centerV: innerMinV, outerU: maxU, outerV: minV, uRadius: clampedUInset, vRadius: clampedVInset, makeVoxel: makeVoxel)
        appendMPRHighlightCorner(to: &vertices, centerU: innerMaxU, centerV: innerMaxV, outerU: maxU, outerV: maxV, uRadius: clampedUInset, vRadius: clampedVInset, makeVoxel: makeVoxel)
        appendMPRHighlightCorner(to: &vertices, centerU: innerMinU, centerV: innerMaxV, outerU: minU, outerV: maxV, uRadius: clampedUInset, vRadius: clampedVInset, makeVoxel: makeVoxel)
    }

    private func appendMPRHighlightCorner(
        to vertices: inout [MetalMPRVertex],
        centerU: Float,
        centerV: Float,
        outerU: Float,
        outerV: Float,
        uRadius: Float,
        vRadius: Float,
        makeVoxel: (Float, Float) -> SIMD3<Float>
    ) {
        let segmentCount = 8
        let uSign: Float = outerU < centerU ? -1 : 1
        let vSign: Float = outerV < centerV ? -1 : 1
        let startAngle: Float
        let endAngle: Float
        if uSign < 0, vSign < 0 {
            startAngle = Float.pi
            endAngle = Float.pi * 1.5
        } else if uSign > 0, vSign < 0 {
            startAngle = Float.pi * 1.5
            endAngle = Float.pi * 2
        } else if uSign > 0, vSign > 0 {
            startAngle = 0
            endAngle = Float.pi * 0.5
        } else {
            startAngle = Float.pi * 0.5
            endAngle = Float.pi
        }

        let center = makeVoxel(centerU, centerV)
        for segmentIndex in 0..<segmentCount {
            let t0 = Float(segmentIndex) / Float(segmentCount)
            let t1 = Float(segmentIndex + 1) / Float(segmentCount)
            let a0 = startAngle + (endAngle - startAngle) * t0
            let a1 = startAngle + (endAngle - startAngle) * t1
            let p0 = makeVoxel(centerU + cos(a0) * uRadius, centerV + sin(a0) * vRadius)
            let p1 = makeVoxel(centerU + cos(a1) * uRadius, centerV + sin(a1) * vRadius)
            vertices.append(MetalMPRVertex(position: mprDisplayPosition(for: center), baseVoxel: center))
            vertices.append(MetalMPRVertex(position: mprDisplayPosition(for: p0), baseVoxel: p0))
            vertices.append(MetalMPRVertex(position: mprDisplayPosition(for: p1), baseVoxel: p1))
        }
    }

    private func appendMPRQuad(to vertices: inout [MetalMPRVertex], corners: [SIMD3<Float>]) {
        guard corners.count == 4 else { return }
        let quadVertices = [
            corners[0], corners[1], corners[2],
            corners[0], corners[2], corners[3],
        ]
        vertices.append(contentsOf: quadVertices.map {
            MetalMPRVertex(position: mprDisplayPosition(for: $0), baseVoxel: $0)
        })
    }

    private func mprVoxelInset(forAxis axis: Int) -> Float {
        mprVoxelInset(forAxis: axis, radiusMM: 10.0)
    }

    private func mprHighlightVoxelInset(forAxis axis: Int) -> Float {
        mprVoxelInset(forAxis: axis, radiusMM: 2.0)
    }

    private func mprVoxelInset(forAxis axis: Int, radiusMM: Float) -> Float {
        let column: SIMD3<Float>
        switch axis {
        case 0:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.0.x, fixedVoxelToWorld.columns.0.y, fixedVoxelToWorld.columns.0.z)
        case 1:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.1.x, fixedVoxelToWorld.columns.1.y, fixedVoxelToWorld.columns.1.z)
        default:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.2.x, fixedVoxelToWorld.columns.2.y, fixedVoxelToWorld.columns.2.z)
        }
        return radiusMM / max(simd_length(column), 0.0001)
    }

    private func mprMainInteractionBounds(in bounds: CGRect) -> CGRect {
        mprPreviewOverlayLayout(in: bounds)?.mainRect ?? bounds
    }

    private func mprMainInteraction(at point: CGPoint, in bounds: CGRect) -> (point: CGPoint, bounds: CGRect)? {
        let mainBounds = mprMainInteractionBounds(in: bounds)
        guard mainBounds.contains(point) else {
            return nil
        }

        return (
            CGPoint(x: point.x - mainBounds.minX, y: point.y - mainBounds.minY),
            CGRect(origin: .zero, size: mainBounds.size)
        )
    }

    private func mprPlane(at point: CGPoint, in bounds: CGRect) -> MetalMPRPlane? {
        mprPlaneHit(at: point, in: bounds)?.plane
    }

    private func mprPlaneHit(at point: CGPoint, in bounds: CGRect) -> MetalMPRPlaneHit? {
        guard let interaction = mprMainInteraction(at: point, in: bounds) else {
            return nil
        }
        let maxX = Float(max(baseVolumeDimensions.x - 1, 0))
        let maxY = Float(max(baseVolumeDimensions.y - 1, 0))
        let maxZ = Float(max(baseVolumeDimensions.z - 1, 0))
        guard maxX > 0, maxY > 0, maxZ > 0 else {
            return nil
        }

        let planeCorners: [(MetalMPRPlane, [SIMD3<Float>])] = [
            (.axial, mprPlaneCorners(for: .axial)),
            (.coronal, mprPlaneCorners(for: .coronal)),
            (.sagittal, mprPlaneCorners(for: .sagittal)),
        ]

        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(interaction.bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(interaction.bounds.height, 1)) * 2.0)
        )
        let viewProjectionMatrix = mprViewProjectionMatrix(offset: offset, viewportSize: interaction.bounds.size)
        let hitPoint = SIMD2<Float>(Float(interaction.point.x), Float(interaction.point.y))
        var bestHit: MetalMPRPlaneHit?
        var bestDepth = Float.greatestFiniteMagnitude

        for (plane, corners) in planeCorners {
            let projectedCorners = corners.map {
                mprProjectedPoint(for: $0, viewProjectionMatrix: viewProjectionMatrix, bounds: interaction.bounds)
            }
            guard projectedCorners.allSatisfy({ $0 != nil }) else { continue }
            let points = projectedCorners.compactMap { $0 }
            guard let hit = mprHit(
                at: hitPoint,
                insideQuadWithProjectedCorners: points,
                baseCorners: corners
            ) else { continue }
            if hit.depth < bestDepth {
                bestDepth = hit.depth
                bestHit = MetalMPRPlaneHit(plane: plane, baseVoxel: hit.baseVoxel, depth: hit.depth)
            }
        }

        return bestHit
    }

    private func mprProjectedPoint(
        for baseVoxel: SIMD3<Float>,
        viewProjectionMatrix: simd_float4x4,
        bounds: CGRect
    ) -> SIMD3<Float>? {
        let clip = viewProjectionMatrix * SIMD4<Float>(mprDisplayPosition(for: baseVoxel), 1)
        guard abs(clip.w) > 0.0001 else { return nil }
        let normalized = SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        return SIMD3<Float>(
            (normalized.x * 0.5 + 0.5) * Float(bounds.width),
            (normalized.y * 0.5 + 0.5) * Float(bounds.height),
            normalized.z
        )
    }

    private func mprHit(
        at point: SIMD2<Float>,
        insideQuadWithProjectedCorners projectedCorners: [SIMD3<Float>],
        baseCorners: [SIMD3<Float>]
    ) -> (depth: Float, baseVoxel: SIMD3<Float>)? {
        guard projectedCorners.count == 4, baseCorners.count == 4 else { return nil }
        return mprHit(
            at: point,
            insideTriangleWithProjectedCorners: [projectedCorners[0], projectedCorners[1], projectedCorners[2]],
            baseCorners: [baseCorners[0], baseCorners[1], baseCorners[2]]
        ) ?? mprHit(
            at: point,
            insideTriangleWithProjectedCorners: [projectedCorners[0], projectedCorners[2], projectedCorners[3]],
            baseCorners: [baseCorners[0], baseCorners[2], baseCorners[3]]
        )
    }

    private func mprHit(
        at point: SIMD2<Float>,
        insideTriangleWithProjectedCorners projectedCorners: [SIMD3<Float>],
        baseCorners: [SIMD3<Float>]
    ) -> (depth: Float, baseVoxel: SIMD3<Float>)? {
        guard projectedCorners.count == 3, baseCorners.count == 3 else { return nil }
        let a = projectedCorners[0]
        let b = projectedCorners[1]
        let c = projectedCorners[2]
        let denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
        guard abs(denominator) > 0.0001 else { return nil }
        let alpha = ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
        let beta = ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
        let gamma = 1 - alpha - beta
        guard alpha >= 0 && beta >= 0 && gamma >= 0 else { return nil }
        return (
            depth: alpha * a.z + beta * b.z + gamma * c.z,
            baseVoxel: alpha * baseCorners[0] + beta * baseCorners[1] + gamma * baseCorners[2]
        )
    }

    private func mprHitIsInsidePlaneInterior(_ hit: MetalMPRPlaneHit) -> Bool {
        guard let region = mprPlaneHitRegion(for: hit) else { return false }
        return region.isInterior
    }

    private func mprTiltComponent(for hit: MetalMPRPlaneHit) -> Int? {
        guard let region = mprPlaneHitRegion(for: hit), region.isInterior == false else {
            return nil
        }
        return region.componentIndex
    }

    private func mprPlaneHitRegion(for hit: MetalMPRPlaneHit) -> (isInterior: Bool, componentIndex: Int?)? {
        let maxX = Float(max(baseVolumeDimensions.x - 1, 0))
        let maxY = Float(max(baseVolumeDimensions.y - 1, 0))
        let maxZ = Float(max(baseVolumeDimensions.z - 1, 0))
        let local: SIMD2<Float>
        let maxLocal: SIMD2<Float>
        let inset: SIMD2<Float>

        switch hit.plane {
        case .axial:
            local = SIMD2<Float>(hit.baseVoxel.x, hit.baseVoxel.y)
            maxLocal = SIMD2<Float>(maxX, maxY)
            inset = SIMD2<Float>(mprVoxelInset(forAxis: 0), mprVoxelInset(forAxis: 1))
        case .coronal:
            local = SIMD2<Float>(hit.baseVoxel.x, hit.baseVoxel.z)
            maxLocal = SIMD2<Float>(maxX, maxZ)
            inset = SIMD2<Float>(mprVoxelInset(forAxis: 0), mprVoxelInset(forAxis: 2))
        case .sagittal:
            local = SIMD2<Float>(hit.baseVoxel.y, hit.baseVoxel.z)
            maxLocal = SIMD2<Float>(maxY, maxZ)
            inset = SIMD2<Float>(mprVoxelInset(forAxis: 1), mprVoxelInset(forAxis: 2))
        }

        let clampedInset = SIMD2<Float>(
            min(max(inset.x, 0), maxLocal.x * 0.5),
            min(max(inset.y, 0), maxLocal.y * 0.5)
        )
        let isInterior = local.x > clampedInset.x &&
            local.x < maxLocal.x - clampedInset.x &&
            local.y > clampedInset.y &&
            local.y < maxLocal.y - clampedInset.y
        if isInterior {
            return (isInterior: true, componentIndex: nil)
        }

        let horizontalEdgeDistance = min(local.x, maxLocal.x - local.x)
        let verticalEdgeDistance = min(local.y, maxLocal.y - local.y)
        let horizontalScore = horizontalEdgeDistance / max(clampedInset.x, 0.0001)
        let verticalScore = verticalEdgeDistance / max(clampedInset.y, 0.0001)
        return (isInterior: false, componentIndex: horizontalScore <= verticalScore ? 0 : 1)
    }

    private func mprScreenDeltaPerVoxel(
        for plane: MetalMPRPlane,
        at baseVoxel: SIMD3<Float>,
        in bounds: CGRect
    ) -> SIMD2<Float>? {
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(bounds.height, 1)) * 2.0)
        )
        let viewProjectionMatrix = mprViewProjectionMatrix(offset: offset, viewportSize: bounds.size)
        guard let projectedStart = mprProjectedPoint(
            for: baseVoxel,
            viewProjectionMatrix: viewProjectionMatrix,
            bounds: bounds
        ),
              let projectedEnd = mprProjectedPoint(
                for: baseVoxel + mprNormalVoxelStep(for: plane),
                viewProjectionMatrix: viewProjectionMatrix,
                bounds: bounds
              ) else {
            return nil
        }
        return SIMD2<Float>(projectedEnd.x - projectedStart.x, projectedEnd.y - projectedStart.y)
    }

    private func mprScreenDeltaPerRadian(
        for plane: MetalMPRPlane,
        componentIndex: Int,
        at baseVoxel: SIMD3<Float>,
        in bounds: CGRect
    ) -> SIMD2<Float>? {
        let local = mprPlaneLocalCoordinates(for: plane, baseVoxel: baseVoxel)
        let angleStep: Float = 0.01
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(bounds.height, 1)) * 2.0)
        )
        let viewProjectionMatrix = mprViewProjectionMatrix(offset: offset, viewportSize: bounds.size)
        let startVoxel = mprPlaneVoxel(for: plane, first: local.x, second: local.y)
        let startAngle = mprTiltValue(for: plane, componentIndex: componentIndex)
        let endVoxel = mprPlaneVoxel(
            for: plane,
            first: local.x,
            second: local.y,
            overridingComponent: componentIndex,
            angle: startAngle + angleStep
        )
        guard let projectedStart = mprProjectedPoint(
            for: startVoxel,
            viewProjectionMatrix: viewProjectionMatrix,
            bounds: bounds
        ),
              let projectedEnd = mprProjectedPoint(
                for: endVoxel,
                viewProjectionMatrix: viewProjectionMatrix,
                bounds: bounds
              ) else {
            return nil
        }
        return SIMD2<Float>(
            (projectedEnd.x - projectedStart.x) / angleStep,
            (projectedEnd.y - projectedStart.y) / angleStep
        )
    }

    private func mprPreviewScreenDeltaPerVoxel(
        for plane: MetalMPRPlane,
        at baseVoxel: SIMD3<Float>,
        displayedIn displayedPlane: MetalMPRPlane,
        paneRect: CGRect
    ) -> SIMD2<Float>? {
        let viewport = mprPreviewViewport(for: paneRect)
        guard let startPosition = planarMPRPreviewPosition(
            for: baseVoxel,
            plane: displayedPlane,
            viewport: viewport
        ),
              let endPosition = planarMPRPreviewPosition(
                for: baseVoxel + mprNormalVoxelStep(for: plane),
                plane: displayedPlane,
                viewport: viewport
              ) else {
            return nil
        }

        let projectedStart = mprPreviewScreenPoint(for: startPosition, in: paneRect)
        let projectedEnd = mprPreviewScreenPoint(for: endPosition, in: paneRect)
        return projectedEnd - projectedStart
    }

    private func mprPreviewScreenDeltaPerRadian(
        for plane: MetalMPRPlane,
        componentIndex: Int,
        at baseVoxel: SIMD3<Float>,
        displayedIn displayedPlane: MetalMPRPlane,
        paneRect: CGRect
    ) -> SIMD2<Float>? {
        let local = mprPlaneLocalCoordinates(for: plane, baseVoxel: baseVoxel)
        let angleStep: Float = 0.01
        let viewport = mprPreviewViewport(for: paneRect)
        let startVoxel = mprPlaneVoxel(for: plane, first: local.x, second: local.y)
        let startAngle = mprTiltValue(for: plane, componentIndex: componentIndex)
        let endVoxel = mprPlaneVoxel(
            for: plane,
            first: local.x,
            second: local.y,
            overridingComponent: componentIndex,
            angle: startAngle + angleStep
        )
        guard let startPosition = planarMPRPreviewPosition(
            for: startVoxel,
            plane: displayedPlane,
            viewport: viewport
        ),
              let endPosition = planarMPRPreviewPosition(
                for: endVoxel,
                plane: displayedPlane,
                viewport: viewport
              ) else {
            return nil
        }

        let projectedStart = mprPreviewScreenPoint(for: startPosition, in: paneRect)
        let projectedEnd = mprPreviewScreenPoint(for: endPosition, in: paneRect)
        return (projectedEnd - projectedStart) / angleStep
    }

    private func mprPlaneLocalCoordinates(for plane: MetalMPRPlane, baseVoxel: SIMD3<Float>) -> SIMD2<Float> {
        switch plane {
        case .axial:
            return SIMD2<Float>(baseVoxel.x, baseVoxel.y)
        case .coronal:
            return SIMD2<Float>(baseVoxel.x, baseVoxel.z)
        case .sagittal:
            return SIMD2<Float>(baseVoxel.y, baseVoxel.z)
        }
    }

    private func mprNormalVoxelStep(for plane: MetalMPRPlane) -> SIMD3<Float> {
        switch plane {
        case .sagittal:
            return SIMD3<Float>(1, 0, 0)
        case .coronal:
            return SIMD3<Float>(0, 1, 0)
        case .axial:
            return SIMD3<Float>(0, 0, 1)
        }
    }

    private func mprVoxelValue(for plane: MetalMPRPlane) -> Float {
        switch plane {
        case .sagittal:
            return mprPlaneVoxel.x
        case .coronal:
            return mprPlaneVoxel.y
        case .axial:
            return mprPlaneVoxel.z
        }
    }

    private func mprTiltValue(for plane: MetalMPRPlane, componentIndex: Int) -> Float {
        switch plane {
        case .axial:
            return componentIndex == 0 ? mprAxialTilt.x : mprAxialTilt.y
        case .coronal:
            return componentIndex == 0 ? mprCoronalTilt.x : mprCoronalTilt.y
        case .sagittal:
            return componentIndex == 0 ? mprSagittalTilt.x : mprSagittalTilt.y
        }
    }

    private func resetMPRTiltPivots() {
        mprAxialTiltPivot = SIMD2<Float>(mprPlaneVoxel.x, mprPlaneVoxel.y)
        mprCoronalTiltPivot = SIMD2<Float>(mprPlaneVoxel.x, mprPlaneVoxel.z)
        mprSagittalTiltPivot = SIMD2<Float>(mprPlaneVoxel.y, mprPlaneVoxel.z)
    }

    private func mprCurrentTiltPivotValue(for plane: MetalMPRPlane, componentIndex: Int) -> Float {
        switch plane {
        case .axial:
            return componentIndex == 0 ? mprPlaneVoxel.x : mprPlaneVoxel.y
        case .coronal:
            return componentIndex == 0 ? mprPlaneVoxel.x : mprPlaneVoxel.z
        case .sagittal:
            return componentIndex == 0 ? mprPlaneVoxel.y : mprPlaneVoxel.z
        }
    }

    private func setMPRTiltPivotValue(_ value: Float, for plane: MetalMPRPlane, componentIndex: Int) {
        switch plane {
        case .axial:
            if componentIndex == 0 {
                mprAxialTiltPivot.x = value
            } else {
                mprAxialTiltPivot.y = value
            }
        case .coronal:
            if componentIndex == 0 {
                mprCoronalTiltPivot.x = value
            } else {
                mprCoronalTiltPivot.y = value
            }
        case .sagittal:
            if componentIndex == 0 {
                mprSagittalTiltPivot.x = value
            } else {
                mprSagittalTiltPivot.y = value
            }
        }
    }

    private func setMPRVoxelValue(_ value: Float, for plane: MetalMPRPlane) {
        switch plane {
        case .sagittal:
            mprPlaneVoxel.x = min(max(value, 0), Float(max(baseVolumeDimensions.x - 1, 0)))
        case .coronal:
            mprPlaneVoxel.y = min(max(value, 0), Float(max(baseVolumeDimensions.y - 1, 0)))
        case .axial:
            mprPlaneVoxel.z = min(max(value, 0), Float(max(baseVolumeDimensions.z - 1, 0)))
        }
    }

    private func setMPRPlaneIntersection(_ voxel: SIMD3<Float>, in plane: MetalMPRPlane) {
        let clampedVoxel = SIMD3<Float>(
            min(max(voxel.x, 0), Float(max(baseVolumeDimensions.x - 1, 0))),
            min(max(voxel.y, 0), Float(max(baseVolumeDimensions.y - 1, 0))),
            min(max(voxel.z, 0), Float(max(baseVolumeDimensions.z - 1, 0)))
        )

        switch plane {
        case .axial:
            mprPlaneVoxel.x = clampedVoxel.x
            mprPlaneVoxel.y = clampedVoxel.y
        case .coronal:
            mprPlaneVoxel.x = clampedVoxel.x
            mprPlaneVoxel.z = clampedVoxel.z
        case .sagittal:
            mprPlaneVoxel.y = clampedVoxel.y
            mprPlaneVoxel.z = clampedVoxel.z
        }
    }

    private func setMPRTiltValue(_ value: Float, for plane: MetalMPRPlane, componentIndex: Int) {
        let clampedValue = min(max(value, -maximumMPRPlaneTiltRadians), maximumMPRPlaneTiltRadians)
        switch plane {
        case .axial:
            if componentIndex == 0 {
                mprAxialTilt.x = clampedValue
            } else {
                mprAxialTilt.y = clampedValue
            }
        case .coronal:
            if componentIndex == 0 {
                mprCoronalTilt.x = clampedValue
            } else {
                mprCoronalTilt.y = clampedValue
            }
        case .sagittal:
            if componentIndex == 0 {
                mprSagittalTilt.x = clampedValue
            } else {
                mprSagittalTilt.y = clampedValue
            }
        }
    }

    private func appendMPRPlaneBorder(to vertices: inout [MetalMPRVertex], plane: MetalMPRPlane) {
        let corners = mprPlaneCorners(for: plane)
        guard corners.count == 4 else { return }
        let color = mprAxisColor(for: plane)
        let borderVertices = [
            corners[0], corners[1],
            corners[1], corners[2],
            corners[2], corners[3],
            corners[3], corners[0],
        ]
        vertices.append(contentsOf: borderVertices.map {
            MetalMPRVertex(position: mprDisplayPosition(for: $0), baseVoxel: $0, color: color)
        })
    }

    private func mprDisplayPosition(for baseVoxel: SIMD3<Float>) -> SIMD3<Float> {
        mprDisplayPosition(forWorld: mprDisplayWorldPosition(for: baseVoxel))
    }

    private func mprDisplayPosition(forWorld world: SIMD3<Float>) -> SIMD3<Float> {
        let delta = world - baseVolumeCenterWorld
        return delta * mprDisplayScale()
    }

    private func mprDisplayScale() -> Float {
        let width = Float(max(baseVolumeDimensions.x - 1, 1))
        let height = Float(max(baseVolumeDimensions.y - 1, 1))
        let depth = Float(max(baseVolumeDimensions.z - 1, 1))
        let corners = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(width, 0, 0),
            SIMD3<Float>(width, height, 0),
            SIMD3<Float>(0, height, 0),
            SIMD3<Float>(0, 0, depth),
            SIMD3<Float>(width, 0, depth),
            SIMD3<Float>(width, height, depth),
            SIMD3<Float>(0, height, depth),
        ]
        let maxDistance = corners
            .map { simd_length(mprDisplayWorldPosition(for: $0) - baseVolumeCenterWorld) }
            .max() ?? 1
        return 0.92 / max(maxDistance, 0.0001)
    }

    private func mprDisplayWorldPosition(for baseVoxel: SIMD3<Float>) -> SIMD3<Float> {
        let world = fixedVoxelToWorld * SIMD4<Float>(baseVoxel, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    private func mprViewProjectionMatrix(offset: SIMD2<Float>, viewportSize: CGSize) -> simd_float4x4 {
        let width = Float(max(viewportSize.width, 1))
        let height = Float(max(viewportSize.height, 1))
        let horizontalAspectScale = min(1, height / width)
        let verticalAspectScale = min(1, width / height)

        var aspectMatrix = matrix_identity_float4x4
        aspectMatrix.columns.0.x = horizontalAspectScale
        aspectMatrix.columns.1.y = verticalAspectScale

        var scaleMatrix = matrix_identity_float4x4
        scaleMatrix.columns.0.x = zoomScale
        scaleMatrix.columns.1.y = zoomScale
        scaleMatrix.columns.2.z = zoomScale

        var translationMatrix = matrix_identity_float4x4
        translationMatrix.columns.3.x = offset.x
        translationMatrix.columns.3.y = offset.y

        var depthRangeMatrix = matrix_identity_float4x4
        depthRangeMatrix.columns.2.z = 0.5
        depthRangeMatrix.columns.3.z = 0.5

        var horizontalConventionMatrix = matrix_identity_float4x4
        horizontalConventionMatrix.columns.0.x = -1

        let viewMatrix = horizontalConventionMatrix * mprRotationMatrix()
        return translationMatrix * depthRangeMatrix * aspectMatrix * scaleMatrix * viewMatrix
    }

    private func mprRotationMatrix() -> simd_float4x4 {
        let vector = simd_normalize(mprRotation).vector
        let x = vector.x
        let y = vector.y
        let z = vector.z
        let w = vector.w

        return simd_float4x4(
            SIMD4<Float>(1 - 2 * y * y - 2 * z * z, 2 * x * y + 2 * w * z, 2 * x * z - 2 * w * y, 0),
            SIMD4<Float>(2 * x * y - 2 * w * z, 1 - 2 * x * x - 2 * z * z, 2 * y * z + 2 * w * x, 0),
            SIMD4<Float>(2 * x * z + 2 * w * y, 2 * y * z - 2 * w * x, 1 - 2 * x * x - 2 * y * y, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
