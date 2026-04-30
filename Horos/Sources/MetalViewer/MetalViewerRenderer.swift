import Foundation
import Dispatch
import Metal
import MetalKit
import simd

private let registrationHistogramBins = 64
private let useGPUPyramidGeneration = true
private let maximumMPRPlaneTiltRadians = Float.pi / 4

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

private func metalRendererTimingLog(_ message: String, since start: CFAbsoluteTime) {
    print(String(format: "HOROS_METAL_TIMING %@ %.3f s", message, CFAbsoluteTimeGetCurrent() - start))
}

private struct MetalUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
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
}

private struct RegistrationUniforms {
    var baseWindowLevel: Float
    var baseWindowWidth: Float
    var overlayWindowLevel: Float
    var overlayWindowWidth: Float
    var metricOptions: SIMD4<Float>
    var overlayTranslationWorld: SIMD3<Float>
    var movingRotationCenterWorld: SIMD3<Float>
    var baseTextureSize: SIMD3<UInt32>
    var movingInverseRotation: simd_float4x4
    var fixedVoxelToWorld: simd_float4x4
    var movingWorldToVoxel: simd_float4x4
}

private struct GaussianBlurUniforms {
    var sourceSize: SIMD3<UInt32>
    var axis: UInt32
    var radius: UInt32
}

private struct DownsampleUniforms {
    var sourceSize: SIMD3<UInt32>
    var factor: UInt32
}

private struct GantryTiltResampleUniforms {
    var outputSize: SIMD4<UInt32>
    var outputVoxelToWorld: simd_float4x4
    var sourceWorldToVoxel: simd_float4x4
    var backgroundValue: SIMD4<Float>
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

private struct VolumeLevel {
    let texture: MTLTexture
    let voxelToWorld: simd_float4x4
}

private struct VolumeTextureBuildResult {
    let texture: MTLTexture
    let dimensions: SIMD3<Int>
    let voxelToWorld: simd_float4x4
    let resampledData: [Float]?
}

private struct OrthogonalVolumeGeometry {
    let dimensions: SIMD3<Int>
    let voxelToWorld: simd_float4x4
    let sourceVoxelToWorld: simd_float4x4
    let gantryTiltShiftPerSliceMM: Float
}

private struct SlabGeometry {
    let normalWorld: SIMD3<Float>
    let thicknessMM: Float
}

private struct MetalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct MetalMPRVertex {
    var position: SIMD3<Float>
    var baseVoxel: SIMD3<Float>
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

private struct MetalMPRPreviewPane {
    let plane: MetalMPRPlane
    let viewport: MTLViewport
    let scissor: MTLScissorRect
}

private struct MetalMPRRenderLayout {
    let mainViewport: MTLViewport
    let mainScissor: MTLScissorRect
    let previewPanes: [MetalMPRPreviewPane]
}

struct MetalMPRPreviewOverlayPane {
    let rect: CGRect
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
}

private enum MetalViewerWindowLevelTarget {
    case base
    case overlay
}

final class MetalViewerRenderer: NSObject, MTKViewDelegate {
    private let deviceRef: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let mprPipelineState: MTLRenderPipelineState
    private let mprPlaneHighlightPipelineState: MTLRenderPipelineState
    private let mprBorderPipelineState: MTLRenderPipelineState
    private let mprIntersectionPipelineState: MTLRenderPipelineState
    private let mprDepthStencilState: MTLDepthStencilState
    private let registrationPipelineState: MTLComputePipelineState
    private let registrationSamplingProbePipelineState: MTLComputePipelineState
    private let gaussianBlurPipelineState: MTLComputePipelineState
    private let downsamplePipelineState: MTLComputePipelineState
    private let gantryTiltResamplePipelineState: MTLComputePipelineState
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    private(set) var pixList: [DCMPix]
    private var overlayPixList: [DCMPix] = []
    private var baseTexture: MTLTexture?
    private var baseVolumeTexture: MTLTexture?
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
    private var baseIsThinSlab = false
    private var overlayIsThinSlab = false
    private var baseSlabGeometry: SlabGeometry?
    private var overlaySlabGeometry: SlabGeometry?

    private(set) var currentSliceIndex = 0
    private(set) var windowLevel: Float = 0
    private(set) var windowWidth: Float = 1
    private var defaultSeriesWindowLevel: MetalViewerWindowLevel?
    private var customSeriesWindowLevel: MetalViewerWindowLevel?
    private(set) var overlayWindowLevel: Float = 0
    private(set) var overlayWindowWidth: Float = 1
    private var overlayDefaultSeriesWindowLevel: MetalViewerWindowLevel?
    private var overlayCustomSeriesWindowLevel: MetalViewerWindowLevel?
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
    private(set) var displayMode: MetalViewerDisplayMode = .stack2D
    private var mprRotation = simd_normalize(
        simd_quatf(angle: -0.65, axis: SIMD3<Float>(0, 0, 1)) *
        simd_quatf(angle: -0.55, axis: SIMD3<Float>(1, 0, 0))
    )
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
    private var hoveredMPRPlane: MetalMPRPlane?
    private var mprPlaneDragState: MetalMPRPlaneDragState?
    private var mprPlaneTiltDragState: MetalMPRPlaneTiltDragState?
    private var registrationGeneration: UInt = 0
    private var registrationInProgress = false
    private var registrationProgress: Float = 0
    private var registrationStatusMessage: String?
    private var registrationMetricCallCount = 0
    private var registrationMetricTotalTime: CFTimeInterval = 0
    private var registrationMetricGPUTime: CFTimeInterval = 0
    private var registrationMetricCPUTime: CFTimeInterval = 0

    var stateDidChange: ((String) -> Void)?
    var registrationDidChange: ((Bool, String, Float) -> Void)?
    var windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?
    var overlayWindowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?

    var activeWindowLevel: Float {
        activeWindowLevelTarget == .overlay ? overlayWindowLevel : windowLevel
    }

    var activeWindowWidth: Float {
        activeWindowLevelTarget == .overlay ? overlayWindowWidth : windowWidth
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

    var stateDescription: String {
        let sliceText: String
        switch displayMode {
        case .stack2D:
            sliceText = pixList.count > 1 ? "Slice \(currentSliceIndex + 1)/\(pixList.count)" : "Slice 1/1"
        case .mpr:
            sliceText = "MPR"
        }
        let zoomText = Int((zoomScale * 100).rounded())
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
            let progressPercent = Int((registrationProgress * 100).rounded())
            let prefix = registrationStatusMessage ?? "Registering"
            progressText = "  \(prefix) \(progressPercent)%"
        } else {
            progressText = ""
        }

        return "\(sliceText)  WL \(Int(windowLevel.rounded()))  WW \(Int(windowWidth.rounded()))  Zoom \(zoomText)%\(registrationText)\(progressText)"
    }

    init(
        device: MTLDevice,
        pixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState()
    ) {
        self.deviceRef = device
        self.pixList = pixList
        self.defaultSeriesWindowLevel = windowLevelState.defaultWindow
        self.customSeriesWindowLevel = windowLevelState.customWindow

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
              let registrationSamplingProbeFunction = library.makeFunction(name: "metalViewerRegistrationSamplingProbe"),
              let gaussianBlurFunction = library.makeFunction(name: "metalViewerGaussianBlur3D"),
              let downsampleFunction = library.makeFunction(name: "metalViewerDownsample3D"),
              let gantryTiltResampleFunction = library.makeFunction(name: "metalViewerGantryTiltResample3D") else {
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
        mprPlaneHighlightPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprBorderPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprBorderPipelineDescriptor.vertexFunction = mprBorderVertexFunction
        mprBorderPipelineDescriptor.fragmentFunction = mprBorderFragmentFunction
        mprBorderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        mprBorderPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let mprIntersectionPipelineDescriptor = MTLRenderPipelineDescriptor()
        mprIntersectionPipelineDescriptor.vertexFunction = mprBorderVertexFunction
        mprIntersectionPipelineDescriptor.fragmentFunction = mprIntersectionFragmentFunction
        mprIntersectionPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        mprIntersectionPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            mprPipelineState = try device.makeRenderPipelineState(descriptor: mprPipelineDescriptor)
            mprPlaneHighlightPipelineState = try device.makeRenderPipelineState(descriptor: mprPlaneHighlightPipelineDescriptor)
            mprBorderPipelineState = try device.makeRenderPipelineState(descriptor: mprBorderPipelineDescriptor)
            mprIntersectionPipelineState = try device.makeRenderPipelineState(descriptor: mprIntersectionPipelineDescriptor)
            registrationPipelineState = try device.makeComputePipelineState(function: registrationFunction)
            registrationSamplingProbePipelineState = try device.makeComputePipelineState(function: registrationSamplingProbeFunction)
            gaussianBlurPipelineState = try device.makeComputePipelineState(function: gaussianBlurFunction)
            downsamplePipelineState = try device.makeComputePipelineState(function: downsampleFunction)
            gantryTiltResamplePipelineState = try device.makeComputePipelineState(function: gantryTiltResampleFunction)
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
    }

    func resetAndLoadInitialSlice() {
        currentSliceIndex = 0
        loadSlice(at: currentSliceIndex)
        resetMPRPlaneToCurrentSlice()
    }

    func setOverlayPixList(
        _ overlayPixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)? = nil
    ) {
        let overlayStart = CFAbsoluteTimeGetCurrent()
        self.overlayPixList = overlayPixList
        overlayDefaultSeriesWindowLevel = windowLevelState.defaultWindow
        overlayCustomSeriesWindowLevel = windowLevelState.customWindow
        overlayWindowLevelStateDidChange = windowLevelStateDidChange
        prepareBaseVolumeIfNeeded()
        let loadStart = CFAbsoluteTimeGetCurrent()
        loadVolumeSlices(overlayPixList)
        metalRendererTimingLog("MetalViewerRenderer overlay loadVolumeSlices", since: loadStart)
        let geometryStart = CFAbsoluteTimeGetCurrent()
        let overlayBuildResult = makeVolumeTexture(from: overlayPixList)
        guard let overlayBuildResult else { return }
        let movingVoxelToWorld = overlayBuildResult.voxelToWorld
        overlayVolumeDimensions = overlayBuildResult.dimensions
        metalRendererTimingLog("MetalViewerRenderer overlay geometry/texture", since: geometryStart)
        let windowStart = CFAbsoluteTimeGetCurrent()
        let overlaySourceDimensions = volumeDimensions(for: overlayPixList)
        let overlaySourceVoxelToWorld = sourceVolumeVoxelToWorldMatrix(for: overlayPixList)
        let overlayRegistrationWindow = overlayBuildResult.resampledData.map {
            registrationWindow(for: $0, modality: overlayPixList.first?.modalityString)
        } ?? registrationWindow(for: overlayPixList, dimensions: overlaySourceDimensions)
        metalRendererTimingLog("MetalViewerRenderer overlay registrationWindow", since: windowStart)
        overlayRegistrationWindowLevel = overlayRegistrationWindow.level
        overlayRegistrationWindowWidth = overlayRegistrationWindow.width
        overlayVolumeCenterWorld = volumeCenterWorld(dimensions: overlayVolumeDimensions, voxelToWorld: movingVoxelToWorld)
        let informativeStart = CFAbsoluteTimeGetCurrent()
        overlayInformativeCenterWorld = overlayBuildResult.resampledData.map {
            informativeCenterWorld(
                for: $0,
                dimensions: overlayVolumeDimensions,
                voxelToWorld: movingVoxelToWorld,
                level: overlayRegistrationWindow.level,
                width: overlayRegistrationWindow.width
            )
        } ?? informativeCenterWorld(
            for: overlayPixList,
            dimensions: overlaySourceDimensions,
            voxelToWorld: overlaySourceVoxelToWorld,
            level: overlayRegistrationWindow.level,
            width: overlayRegistrationWindow.width
        )
        metalRendererTimingLog("MetalViewerRenderer overlay informativeCenterWorld", since: informativeStart)
        overlayIsThinSlab = isThinSlab(dimensions: overlayVolumeDimensions, voxelToWorld: movingVoxelToWorld)
        overlaySlabGeometry = overlayIsThinSlab ? slabGeometry(dimensions: overlayVolumeDimensions, voxelToWorld: movingVoxelToWorld) : nil
        let textureStart = CFAbsoluteTimeGetCurrent()
        overlayVolumeTexture = overlayBuildResult.texture
        metalRendererTimingLog("MetalViewerRenderer makeTexture3D overlay", since: textureStart)
        let levelsStart = CFAbsoluteTimeGetCurrent()
        overlayVolumeLevels = makeVolumeLevels(from: overlayVolumeTexture, dimensions: overlayVolumeDimensions, baseVoxelToWorld: movingVoxelToWorld)
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevels overlay", since: levelsStart)
        movingWorldToVoxel = simd_inverse(movingVoxelToWorld)
        movingRotationCenterWorld = overlayVolumeCenterWorld
        overlayTranslationWorld = .zero
        overlayRotationRadians = .zero
        overlayTranslationPixels = .zero
        loadSlice(at: currentSliceIndex)
        metalRendererTimingLog("MetalViewerRenderer setOverlayPixList total", since: overlayStart)
        runRegistration()
    }

    func clearOverlayPixList() {
        overlayPixList = []
        overlayVolumeTexture = nil
        overlayVolumeDimensions = SIMD3<Int>(repeating: 1)
        overlayVolumeLevels = []
        overlayDefaultSeriesWindowLevel = nil
        overlayCustomSeriesWindowLevel = nil
        overlayWindowLevelStateDidChange = nil
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
    }

    func stepSlice(by delta: Int) {
        guard pixList.isEmpty == false else { return }
        let nextIndex = max(0, min(pixList.count - 1, currentSliceIndex - delta))
        guard nextIndex != currentSliceIndex else { return }
        currentSliceIndex = nextIndex
        loadSlice(at: currentSliceIndex)
        if displayMode == .mpr {
            resetMPRPlaneToCurrentSlice()
        }
    }

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        hoveredMPRPlane = nil
        mprPlaneDragState = nil
        mprPlaneTiltDragState = nil
        if mode == .mpr {
            prepareBaseVolumeIfNeeded()
            resetMPRPlaneToCurrentSlice()
        }
        stateDidChange?(stateDescription)
    }

    func rotateMPR(from previousPoint: CGPoint, to currentPoint: CGPoint, in bounds: CGRect) {
        guard displayMode == .mpr else { return }
        let mainBounds = mprMainInteractionBounds(in: bounds)
        guard mainBounds.contains(previousPoint) || mainBounds.contains(currentPoint) else { return }
        let localBounds = CGRect(origin: .zero, size: mainBounds.size)
        let localPreviousPoint = CGPoint(x: previousPoint.x - mainBounds.minX, y: previousPoint.y - mainBounds.minY)
        let localCurrentPoint = CGPoint(x: currentPoint.x - mainBounds.minX, y: currentPoint.y - mainBounds.minY)
        let start = mprArcballVector(for: localPreviousPoint, in: localBounds)
        let end = mprArcballVector(for: localCurrentPoint, in: localBounds)
        let axis = simd_cross(start, end)
        let axisLength = simd_length(axis)
        guard axisLength > 0.0001 else { return }

        let dot = min(max(simd_dot(start, end), -1), 1)
        let angle = atan2(axisLength, dot)
        let dragRotation = simd_quatf(angle: angle, axis: axis / axisLength)
        mprRotation = simd_normalize(dragRotation * mprRotation)
        stateDidChange?(stateDescription)
    }

    func beginMPRPlaneDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode == .mpr else { return false }
        prepareBaseVolumeIfNeeded()
        guard let interaction = mprMainInteraction(at: point, in: bounds) else {
            mprPlaneDragState = nil
            return false
        }
        guard let hit = mprPlaneHit(at: point, in: bounds),
              mprHitIsInsidePlaneInterior(hit) else {
            mprPlaneDragState = nil
            return false
        }

        guard let screenDeltaPerVoxel = mprScreenDeltaPerVoxel(for: hit.plane, at: hit.baseVoxel, in: interaction.bounds),
              simd_length_squared(screenDeltaPerVoxel) > 0.0001 else {
            mprPlaneDragState = nil
            return false
        }

        mprPlaneDragState = MetalMPRPlaneDragState(
            plane: hit.plane,
            startPoint: SIMD2<Float>(Float(point.x), Float(point.y)),
            startPlaneVoxel: mprVoxelValue(for: hit.plane),
            screenDeltaPerVoxel: screenDeltaPerVoxel
        )
        mprPlaneTiltDragState = nil
        hoveredMPRPlane = hit.plane
        stateDidChange?(stateDescription)
        return true
    }

    func beginMPRPlaneTiltDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard displayMode == .mpr else { return false }
        prepareBaseVolumeIfNeeded()
        guard let interaction = mprMainInteraction(at: point, in: bounds) else {
            mprPlaneTiltDragState = nil
            return false
        }
        guard let hit = mprPlaneHit(at: point, in: bounds),
              mprHitIsInsidePlaneInterior(hit) == false,
              let componentIndex = mprTiltComponent(for: hit) else {
            mprPlaneTiltDragState = nil
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
    }

    func moveMPRPlane(axis: Int, by delta: Float) {
        guard displayMode == .mpr else { return }
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

    func mprPreviewOverlayLayout(in bounds: CGRect) -> MetalMPRPreviewOverlayLayout? {
        guard displayMode == .mpr,
              let metrics = mprLayoutMetrics(totalWidth: bounds.width, totalHeight: bounds.height, unitScale: 1) else {
            return nil
        }

        let mainRect = CGRect(x: bounds.minX, y: bounds.minY, width: metrics.mainWidth, height: metrics.totalHeight)
        let dividerRect = CGRect(x: mainRect.maxX, y: bounds.minY, width: metrics.gap, height: metrics.totalHeight)
        let previewPanes = metrics.previewPaneRects.enumerated().map { index, rect in
            let labels: (left: String, right: String, top: String, bottom: String)
            switch index {
            case 0:
                labels = (left: "L", right: "R", top: "A", bottom: "P")
            case 1:
                labels = (left: "L", right: "R", top: "S", bottom: "I")
            default:
                labels = (left: "A", right: "P", top: "S", bottom: "I")
            }
            return MetalMPRPreviewOverlayPane(
                rect: rect.offsetBy(dx: bounds.minX, dy: bounds.minY),
                left: labels.left,
                right: labels.right,
                top: labels.top,
                bottom: labels.bottom
            )
        }

        return MetalMPRPreviewOverlayLayout(
            mainRect: mainRect,
            dividerRect: dividerRect,
            previewPanes: previewPanes
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
        guard displayMode == .mpr, let point else {
            if hoveredMPRPlane != nil {
                hoveredMPRPlane = nil
                stateDidChange?(stateDescription)
            }
            return
        }

        prepareBaseVolumeIfNeeded()
        let nextPlane = mprPlane(at: point, in: bounds)
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
        let defaults = windowLevelDefaults(for: pix, series: activeWindowLevelPixList)
        let width = pix.savedWW > 0 ? pix.savedWW : defaults.width
        let level = pix.savedWW > 0 ? pix.savedWL : defaults.level
        applyWindowLevel(MetalViewerWindowLevel(level: level, width: width), asCustom: false)
    }

    func applyFullDynamicWindowLevelPreset() {
        guard let pix = activeWindowLevelPix else { return }
        applyWindowLevel(MetalViewerWindowLevel(level: pix.fullwl, width: max(1, pix.fullww)), asCustom: false)
    }

    func applyRobustSeriesWindowLevelPreset() {
        guard let pix = activeWindowLevelPix else { return }
        let window = robustSeriesWindowLevel(for: activeWindowLevelPixList) ?? windowLevelDefaults(for: pix, series: activeWindowLevelPixList)
        applyWindowLevel(window, asCustom: false)
    }

    func commitWindowLevel() {
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
        zoomScale = min(max(zoomScale * factor, 0.1), 32.0)
        stateDidChange?(stateDescription)
    }

    func setPanOffset(_ value: SIMD2<Float>) {
        panOffset = value
        stateDidChange?(stateDescription)
    }

    func rerunRegistration() {
        runRegistration()
    }

    func setOverlayBlend(_ value: Float) {
        overlayBlend = min(max(value, 0), 1)
        stateDidChange?(stateDescription)
    }

    func imageRect(in bounds: CGRect) -> CGRect {
        let viewAspect = max(bounds.width / max(bounds.height, 1), 0.0001)
        var imageWidth = bounds.width
        var imageHeight = bounds.height

        if CGFloat(imageAspectRatio) > viewAspect {
            imageHeight = imageWidth / CGFloat(imageAspectRatio)
        } else {
            imageWidth = imageHeight * CGFloat(imageAspectRatio)
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

    private func loadSlice(at index: Int) {
        guard pixList.indices.contains(index) else { return }
        let pix = pixList[index]

        pix.checkLoad()
        pix.computePixMinPixMax()

        let width = max(Int(pix.pwidth), 1)
        let height = max(Int(pix.pheight), 1)
        imageAspectRatio = Float(width) * Float(max(pix.pixelSpacingX, 1)) / max(Float(height) * Float(max(pix.pixelSpacingY, 1)), 1)

        guard let texture = makeTexture(for: pix) else {
            return
        }
        baseTexture = texture

        if let customWindow = customSeriesWindowLevel {
            applyBaseWindowLevel(customWindow)
        } else if let defaultWindow = defaultSeriesWindowLevel {
            applyBaseWindowLevel(defaultWindow)
        } else {
            let defaultWindow = windowLevelDefaults(for: pix)
            defaultSeriesWindowLevel = defaultWindow
            applyBaseWindowLevel(defaultWindow)
            notifyWindowLevelStateDidChange()
        }

        if let overlayPix = currentOverlayPix {
            overlayPix.checkLoad()
            overlayPix.computePixMinPixMax()

            if let customWindow = overlayCustomSeriesWindowLevel {
                applyOverlayWindowLevel(customWindow)
            } else if let defaultWindow = overlayDefaultSeriesWindowLevel {
                applyOverlayWindowLevel(defaultWindow)
            } else {
                let defaultWindow = windowLevelDefaults(for: overlayPix, series: overlayPixList)
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

    private var activeWindowLevelPixList: [DCMPix] {
        switch activeWindowLevelTarget {
        case .base:
            return pixList
        case .overlay:
            return overlayPixList
        }
    }

    private func windowLevelDefaults(for pix: DCMPix, series: [DCMPix]? = nil) -> MetalViewerWindowLevel {
        let modality = pix.modalityString?.uppercased() ?? ""
        if modality == "MR",
           pix.savedWW <= 0,
           pix.ww <= 0,
           let robustWindow = robustSeriesWindowLevel(for: series ?? pixList) {
            return robustWindow
        }

        let defaultWW = pix.ww > 0 ? pix.ww : pix.fullww
        let defaultWL = pix.wl != 0 ? pix.wl : pix.fullwl
        return MetalViewerWindowLevel(level: defaultWL, width: max(1, defaultWW))
    }

    private func robustSeriesWindowLevel(for seriesPixList: [DCMPix]) -> MetalViewerWindowLevel? {
        guard seriesPixList.isEmpty == false else { return nil }

        let maxSliceSamples = 17
        let sliceStep = max(1, seriesPixList.count / maxSliceSamples)
        var sliceIndexes = Array(stride(from: 0, to: seriesPixList.count, by: sliceStep))
        if let lastIndex = seriesPixList.indices.last, sliceIndexes.contains(lastIndex) == false {
            sliceIndexes.append(lastIndex)
        }

        var samples: [Float] = []
        samples.reserveCapacity(80_000)

        for sliceIndex in sliceIndexes {
            let pix = seriesPixList[sliceIndex]
            pix.checkLoad()
            guard let pixels = pix.fImage else { continue }

            let pixelCount = max(Int(pix.pwidth) * Int(pix.pheight), 0)
            guard pixelCount > 0 else { continue }

            let pixelStep = max(1, pixelCount / 5_000)
            var index = 0
            while index < pixelCount {
                let value = pixels[index]
                if value.isFinite && abs(value) > Float.ulpOfOne {
                    samples.append(value)
                }
                index += pixelStep
            }
        }

        guard samples.count >= 32 else { return nil }
        samples.sort()

        let lowIndex = percentileIndex(0.005, count: samples.count)
        let highIndex = percentileIndex(0.995, count: samples.count)
        let low = samples[lowIndex]
        let high = samples[max(highIndex, lowIndex)]
        let width = max(high - low, 1)
        return MetalViewerWindowLevel(level: low + width * 0.5, width: width)
    }

    private func percentileIndex(_ percentile: Float, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        return min(max(Int((Float(count - 1) * clamped).rounded()), 0), count - 1)
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

    private func prepareBaseVolumeIfNeeded() {
        let prepareStart = CFAbsoluteTimeGetCurrent()
        guard baseVolumeTexture == nil else { return }
        let volumeDataStart = CFAbsoluteTimeGetCurrent()
        loadVolumeSlices(pixList)
        metalRendererTimingLog("MetalViewerRenderer loadVolumeSlices", since: volumeDataStart)
        let geometryStart = CFAbsoluteTimeGetCurrent()
        guard let baseBuildResult = makeVolumeTexture(from: pixList) else { return }
        fixedVoxelToWorld = baseBuildResult.voxelToWorld
        baseVolumeDimensions = baseBuildResult.dimensions
        baseVolumeTexture = baseBuildResult.texture
        metalRendererTimingLog("MetalViewerRenderer volume geometry/texture", since: geometryStart)
        let registrationWindowStart = CFAbsoluteTimeGetCurrent()
        let baseSourceDimensions = volumeDimensions(for: pixList)
        let baseSourceVoxelToWorld = sourceVolumeVoxelToWorldMatrix(for: pixList)
        let baseRegistrationWindow = baseBuildResult.resampledData.map {
            registrationWindow(for: $0, modality: pixList.first?.modalityString)
        } ?? registrationWindow(for: pixList, dimensions: baseSourceDimensions)
        metalRendererTimingLog("MetalViewerRenderer registrationWindow", since: registrationWindowStart)
        baseRegistrationWindowLevel = baseRegistrationWindow.level
        baseRegistrationWindowWidth = baseRegistrationWindow.width
        baseVolumeCenterWorld = volumeCenterWorld(dimensions: baseVolumeDimensions, voxelToWorld: fixedVoxelToWorld)
        let informativeStart = CFAbsoluteTimeGetCurrent()
        baseInformativeCenterWorld = baseBuildResult.resampledData.map {
            informativeCenterWorld(
                for: $0,
                dimensions: baseVolumeDimensions,
                voxelToWorld: fixedVoxelToWorld,
                level: baseRegistrationWindow.level,
                width: baseRegistrationWindow.width
            )
        } ?? informativeCenterWorld(
            for: pixList,
            dimensions: baseSourceDimensions,
            voxelToWorld: baseSourceVoxelToWorld,
            level: baseRegistrationWindow.level,
            width: baseRegistrationWindow.width
        )
        metalRendererTimingLog("MetalViewerRenderer informativeCenterWorld", since: informativeStart)
        baseIsThinSlab = isThinSlab(dimensions: baseVolumeDimensions, voxelToWorld: fixedVoxelToWorld)
        baseSlabGeometry = baseIsThinSlab ? slabGeometry(dimensions: baseVolumeDimensions, voxelToWorld: fixedVoxelToWorld) : nil
        let levelsStart = CFAbsoluteTimeGetCurrent()
        baseVolumeLevels = makeVolumeLevels(from: baseVolumeTexture, dimensions: baseVolumeDimensions, baseVoxelToWorld: fixedVoxelToWorld)
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevels", since: levelsStart)
        metalRendererTimingLog("MetalViewerRenderer prepareBaseVolumeIfNeeded total", since: prepareStart)
    }

    private func makeTexture(for pix: DCMPix) -> MTLTexture? {
        let width = max(Int(pix.pwidth), 1)
        let height = max(Int(pix.pheight), 1)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = deviceRef.makeTexture(descriptor: descriptor),
              let imagePointer = pix.fImage else {
            return nil
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: imagePointer,
            bytesPerRow: width * MemoryLayout<Float>.stride
        )

        return texture
    }

    private func volumeDimensions(for pixList: [DCMPix]) -> SIMD3<Int> {
        guard let firstPix = pixList.first else {
            return SIMD3<Int>(1, 1, 1)
        }

        return SIMD3<Int>(
            max(Int(firstPix.pwidth), 1),
            max(Int(firstPix.pheight), 1),
            max(pixList.count, 1)
        )
    }

    private func loadVolumeSlices(_ pixList: [DCMPix]) {
        guard pixList.isEmpty == false else { return }

        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1), pixList.count)
        guard workerCount > 1 else {
            for pix in pixList {
                pix.checkLoad()
                pix.computePixMinPixMax()
            }
            return
        }

        let queue = OperationQueue()
        queue.name = "org.horos.metalviewer.registration-volume-loader"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = workerCount

        for pix in pixList {
            queue.addOperation {
                pix.checkLoad()
                pix.computePixMinPixMax()
            }
        }

        queue.waitUntilAllOperationsAreFinished()
    }

    private func registrationWindow(for pixList: [DCMPix], dimensions: SIMD3<Int>) -> (level: Float, width: Float) {
        guard pixList.isEmpty == false else { return (0, 1) }
        let isCT = pixList.first?.modalityString?.uppercased().contains("CT") == true
        let lowerPercentile: Float = isCT ? 0.005 : 0.01
        let upperPercentile: Float = isCT ? 0.995 : 0.99
        let maxSamples = 262_144
        let voxelCount = max(dimensions.x * dimensions.y * dimensions.z, 1)
        let stride = max(voxelCount / maxSamples, 1)

        var samples = [Float]()
        samples.reserveCapacity((voxelCount + stride - 1) / stride)

        for linearIndex in Swift.stride(from: 0, to: voxelCount, by: stride) {
            let sliceElementCount = max(dimensions.x * dimensions.y, 1)
            let z = linearIndex / sliceElementCount
            let sliceIndex = min(max(z, 0), pixList.count - 1)
            let sliceOffset = linearIndex - z * sliceElementCount
            guard let pixels = pixList[sliceIndex].fImage,
                  sliceOffset >= 0,
                  sliceOffset < sliceElementCount else {
                continue
            }

            let value = pixels[sliceOffset]
            if value.isFinite { samples.append(value) }
        }

        guard samples.isEmpty == false else { return (0, 1) }
        samples.sort()

        let lowerIndex = min(max(Int(Float(samples.count - 1) * lowerPercentile), 0), samples.count - 1)
        let upperIndex = min(max(Int(Float(samples.count - 1) * upperPercentile), 0), samples.count - 1)
        let lowerValue = samples[min(lowerIndex, upperIndex)]
        let upperValue = samples[max(lowerIndex, upperIndex)]
        let width = max(upperValue - lowerValue, 1)
        let level = lowerValue + width * 0.5
        return (level, width)
    }

    private func registrationWindow(for volumeData: [Float], modality: String?) -> (level: Float, width: Float) {
        guard volumeData.isEmpty == false else { return (0, 1) }
        let isCT = modality?.uppercased().contains("CT") == true
        let lowerPercentile: Float = isCT ? 0.005 : 0.01
        let upperPercentile: Float = isCT ? 0.995 : 0.99
        let maxSamples = 262_144
        let stride = max(volumeData.count / maxSamples, 1)
        var samples: [Float] = []
        samples.reserveCapacity((volumeData.count + stride - 1) / stride)

        var index = 0
        while index < volumeData.count {
            let value = volumeData[index]
            if value.isFinite {
                samples.append(value)
            }
            index += stride
        }

        guard samples.isEmpty == false else { return (0, 1) }
        samples.sort()
        let lowerIndex = min(max(Int(Float(samples.count - 1) * lowerPercentile), 0), samples.count - 1)
        let upperIndex = min(max(Int(Float(samples.count - 1) * upperPercentile), 0), samples.count - 1)
        let lowerValue = samples[min(lowerIndex, upperIndex)]
        let upperValue = samples[max(lowerIndex, upperIndex)]
        let width = max(upperValue - lowerValue, 1)
        return (lowerValue + width * 0.5, width)
    }

    private func makeVolumeTexture(from pixList: [DCMPix]) -> VolumeTextureBuildResult? {
        let geometry = orthogonalVolumeGeometry(for: pixList)
        if geometry.gantryTiltShiftPerSliceMM > 0.01 {
            let resampleStart = CFAbsoluteTimeGetCurrent()
            let sourceDimensions = volumeDimensions(for: pixList)
            let backgroundValue: Float = pixList.first?.modalityString?.uppercased().contains("CT") == true ? -1024 : 0
            if let sourceTexture = makeTexture3D(from: pixList, dimensions: sourceDimensions),
               let texture = makeWritableTexture3D(dimensions: geometry.dimensions),
               runGantryTiltResample(
                    source: sourceTexture,
                    destination: texture,
                    outputDimensions: geometry.dimensions,
                    outputVoxelToWorld: geometry.voxelToWorld,
                    sourceVoxelToWorld: geometry.sourceVoxelToWorld,
                    backgroundValue: backgroundValue
               ) {
                print(String(
                    format: "HOROS_METAL_TIMING MetalViewerRenderer gantryTiltResampleGPU shiftPerSlice=%.3fmm output=%dx%dx%d %.3f s",
                    geometry.gantryTiltShiftPerSliceMM,
                    geometry.dimensions.x,
                    geometry.dimensions.y,
                    geometry.dimensions.z,
                    CFAbsoluteTimeGetCurrent() - resampleStart
                ))
                return VolumeTextureBuildResult(
                    texture: texture,
                    dimensions: geometry.dimensions,
                    voxelToWorld: geometry.voxelToWorld,
                    resampledData: nil
                )
            }

            let fallbackStart = CFAbsoluteTimeGetCurrent()
            let data = resampleGantryTiltedVolume(
                pixList,
                outputDimensions: geometry.dimensions,
                outputVoxelToWorld: geometry.voxelToWorld,
                sourceVoxelToWorld: geometry.sourceVoxelToWorld
            )
            guard let texture = makeTexture3D(from: data, dimensions: geometry.dimensions) else {
                return nil
            }
            print(String(
                format: "HOROS_METAL_TIMING MetalViewerRenderer gantryTiltResampleCPUFallback shiftPerSlice=%.3fmm output=%dx%dx%d %.3f s",
                geometry.gantryTiltShiftPerSliceMM,
                geometry.dimensions.x,
                geometry.dimensions.y,
                geometry.dimensions.z,
                CFAbsoluteTimeGetCurrent() - fallbackStart
            ))
            return VolumeTextureBuildResult(
                texture: texture,
                dimensions: geometry.dimensions,
                voxelToWorld: geometry.voxelToWorld,
                resampledData: data
            )
        }

        guard let texture = makeTexture3D(from: pixList, dimensions: geometry.dimensions) else {
            return nil
        }
        return VolumeTextureBuildResult(
            texture: texture,
            dimensions: geometry.dimensions,
            voxelToWorld: geometry.voxelToWorld,
            resampledData: nil
        )
    }

    private func makeTexture3D(from pixList: [DCMPix], dimensions: SIMD3<Int>) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = max(dimensions.x, 1)
        descriptor.height = max(dimensions.y, 1)
        descriptor.depth = max(dimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let bytesPerRow = width * MemoryLayout<Float>.stride
        let bytesPerImage = max(width * height, 1) * MemoryLayout<Float>.stride

        for (sliceIndex, pix) in pixList.enumerated() where sliceIndex < dimensions.z {
            guard let imagePointer = pix.fImage else { continue }
            texture.replace(
                region: MTLRegionMake3D(0, 0, sliceIndex, width, height, 1),
                mipmapLevel: 0,
                slice: 0,
                withBytes: imagePointer,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }

    private func makeTexture3D(from volume: [Float], dimensions: SIMD3<Int>) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = max(dimensions.x, 1)
        descriptor.height = max(dimensions.y, 1)
        descriptor.depth = max(dimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let bytesPerRow = max(dimensions.x, 1) * MemoryLayout<Float>.stride
        let bytesPerImage = max(dimensions.x * dimensions.y, 1) * MemoryLayout<Float>.stride
        volume.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, max(dimensions.x, 1), max(dimensions.y, 1), max(dimensions.z, 1)),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }

    private func makeVolumeLevels(from fullTexture: MTLTexture?, dimensions: SIMD3<Int>, baseVoxelToWorld: simd_float4x4) -> [VolumeLevel] {
        guard let fullTexture else { return [] }
        if useGPUPyramidGeneration,
           let gpuLevels = makeVolumeLevelsGPU(from: fullTexture, dimensions: dimensions, baseVoxelToWorld: baseVoxelToWorld) {
            return gpuLevels
        }

        return [VolumeLevel(texture: fullTexture, voxelToWorld: baseVoxelToWorld)]
    }

    private func makeVolumeLevelsCPU(from fullData: [Float], dimensions: SIMD3<Int>, baseVoxelToWorld: simd_float4x4) -> [VolumeLevel] {
        let requestedFactors = [8, 4, 2, 1]
        var levels: [VolumeLevel] = []
        let voxelSpacing = voxelSpacing(from: baseVoxelToWorld)

        for factor in requestedFactors {
            let levelData = downsampleVolume(
                fullData,
                dimensions: dimensions,
                factor: factor,
                voxelSpacing: voxelSpacing
            )
            guard let texture = makeTexture3D(from: levelData.data, dimensions: levelData.dimensions) else { continue }
            let scale = simd_float4x4(
                SIMD4<Float>(Float(factor), 0, 0, 0),
                SIMD4<Float>(0, Float(factor), 0, 0),
                SIMD4<Float>(0, 0, Float(factor), 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
            levels.append(VolumeLevel(texture: texture, voxelToWorld: baseVoxelToWorld * scale))
        }

        if levels.isEmpty, let texture = makeTexture3D(from: fullData, dimensions: dimensions) {
            levels.append(VolumeLevel(texture: texture, voxelToWorld: baseVoxelToWorld))
        }

        return levels
    }

    private func makeVolumeLevelsGPU(from fullTexture: MTLTexture, dimensions: SIMD3<Int>, baseVoxelToWorld: simd_float4x4) -> [VolumeLevel]? {
        let levelsStart = CFAbsoluteTimeGetCurrent()
        let factors = [8, 4, 2, 1]
        let halfDimensions = SIMD3<Int>(
            max((dimensions.x + 1) / 2, 1),
            max((dimensions.y + 1) / 2, 1),
            max((dimensions.z + 1) / 2, 1)
        )
        let quarterDimensions = SIMD3<Int>(
            max((halfDimensions.x + 1) / 2, 1),
            max((halfDimensions.y + 1) / 2, 1),
            max((halfDimensions.z + 1) / 2, 1)
        )
        let eighthDimensions = SIMD3<Int>(
            max((quarterDimensions.x + 1) / 2, 1),
            max((quarterDimensions.y + 1) / 2, 1),
            max((quarterDimensions.z + 1) / 2, 1)
        )

        let halfStart = CFAbsoluteTimeGetCurrent()
        guard let halfTexture = gaussianDownsampleTexture3D(source: fullTexture, dimensions: dimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld)) else {
            return nil
        }
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevelsGPU half", since: halfStart)

        let quarterStart = CFAbsoluteTimeGetCurrent()
        guard let quarterTexture = gaussianDownsampleTexture3D(source: halfTexture, dimensions: halfDimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld * scaleMatrix(factor: 2))) else {
            return nil
        }
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevelsGPU quarter", since: quarterStart)

        let eighthStart = CFAbsoluteTimeGetCurrent()
        guard let eighthTexture = gaussianDownsampleTexture3D(source: quarterTexture, dimensions: quarterDimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld * scaleMatrix(factor: 4))) else {
            return nil
        }
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevelsGPU eighth", since: eighthStart)

        let texturesByFactor: [Int: (MTLTexture, SIMD3<Int>)] = [
            1: (fullTexture, dimensions),
            2: (halfTexture, halfDimensions),
            4: (quarterTexture, quarterDimensions),
            8: (eighthTexture, eighthDimensions),
        ]

        let levels: [VolumeLevel] = factors.compactMap { factor -> VolumeLevel? in
            guard let entry = texturesByFactor[factor] else { return nil }
            return VolumeLevel(texture: entry.0, voxelToWorld: baseVoxelToWorld * scaleMatrix(factor: factor))
        }
        metalRendererTimingLog("MetalViewerRenderer makeVolumeLevelsGPU total", since: levelsStart)
        return levels
    }

    private func gaussianDownsampleTexture3D(source: MTLTexture, dimensions: SIMD3<Int>, voxelSpacing: SIMD3<Float>) -> MTLTexture? {
        let sigmaMM: Float = 1.0
        let sigma = SIMD3<Float>(
            sigmaMM / max(voxelSpacing.x, 0.0001),
            sigmaMM / max(voxelSpacing.y, 0.0001),
            sigmaMM / max(voxelSpacing.z, 0.0001)
        )

        guard let xKernelBuffer = makeKernelBuffer(sigma: sigma.x),
              let yKernelBuffer = makeKernelBuffer(sigma: sigma.y),
              let zKernelBuffer = makeKernelBuffer(sigma: sigma.z),
              let blurXTexture = makeWritableTexture3D(dimensions: dimensions),
              let blurYTexture = makeWritableTexture3D(dimensions: dimensions),
              let blurZTexture = makeWritableTexture3D(dimensions: dimensions) else {
            return nil
        }

        guard runGaussianBlur(source: source, destination: blurXTexture, dimensions: dimensions, axis: 0, kernelBuffer: xKernelBuffer),
              runGaussianBlur(source: blurXTexture, destination: blurYTexture, dimensions: dimensions, axis: 1, kernelBuffer: yKernelBuffer),
              runGaussianBlur(source: blurYTexture, destination: blurZTexture, dimensions: dimensions, axis: 2, kernelBuffer: zKernelBuffer) else {
            return nil
        }

        let outputDimensions = SIMD3<Int>(
            max((dimensions.x + 1) / 2, 1),
            max((dimensions.y + 1) / 2, 1),
            max((dimensions.z + 1) / 2, 1)
        )
        guard let downsampledTexture = makeWritableTexture3D(dimensions: outputDimensions),
              runDownsample(source: blurZTexture, destination: downsampledTexture, sourceDimensions: dimensions, factor: 2) else {
            return nil
        }

        return downsampledTexture
    }

    private func makeWritableTexture3D(dimensions: SIMD3<Int>) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = max(dimensions.x, 1)
        descriptor.height = max(dimensions.y, 1)
        descriptor.depth = max(dimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return deviceRef.makeTexture(descriptor: descriptor)
    }

    private func makeKernelBuffer(sigma: Float) -> MTLBuffer? {
        let kernel = gaussianKernel(sigma: sigma)
        let length = kernel.count * MemoryLayout<Float>.stride
        return deviceRef.makeBuffer(bytes: kernel, length: length, options: .storageModeShared)
    }

    private func runGaussianBlur(source: MTLTexture, destination: MTLTexture, dimensions: SIMD3<Int>, axis: UInt32, kernelBuffer: MTLBuffer) -> Bool {
        var uniforms = GaussianBlurUniforms(
            sourceSize: SIMD3<UInt32>(UInt32(dimensions.x), UInt32(dimensions.y), UInt32(dimensions.z)),
            axis: axis,
            radius: UInt32(max((kernelBuffer.length / MemoryLayout<Float>.stride - 1) / 2, 0))
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        let threadsPerGroup = MTLSize(width: 4, height: 4, depth: 4)
        let threadgroups = MTLSize(
            width: (destination.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (destination.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (destination.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )

        encoder.setComputePipelineState(gaussianBlurPipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<GaussianBlurUniforms>.stride, index: 0)
        encoder.setBuffer(kernelBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func runDownsample(source: MTLTexture, destination: MTLTexture, sourceDimensions: SIMD3<Int>, factor: UInt32) -> Bool {
        var uniforms = DownsampleUniforms(
            sourceSize: SIMD3<UInt32>(UInt32(sourceDimensions.x), UInt32(sourceDimensions.y), UInt32(sourceDimensions.z)),
            factor: factor
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        let threadsPerGroup = MTLSize(width: 4, height: 4, depth: 4)
        let threadgroups = MTLSize(
            width: (destination.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (destination.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (destination.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )

        encoder.setComputePipelineState(downsamplePipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<DownsampleUniforms>.stride, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func runGantryTiltResample(
        source: MTLTexture,
        destination: MTLTexture,
        outputDimensions: SIMD3<Int>,
        outputVoxelToWorld: simd_float4x4,
        sourceVoxelToWorld: simd_float4x4,
        backgroundValue: Float
    ) -> Bool {
        var uniforms = GantryTiltResampleUniforms(
            outputSize: SIMD4<UInt32>(
                UInt32(max(outputDimensions.x, 1)),
                UInt32(max(outputDimensions.y, 1)),
                UInt32(max(outputDimensions.z, 1)),
                0
            ),
            outputVoxelToWorld: outputVoxelToWorld,
            sourceWorldToVoxel: simd_inverse(sourceVoxelToWorld),
            backgroundValue: SIMD4<Float>(backgroundValue, 0, 0, 0)
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        let threadsPerGroup = MTLSize(width: 4, height: 4, depth: 4)
        let threadgroups = MTLSize(
            width: (destination.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (destination.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (destination.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )

        encoder.setComputePipelineState(gantryTiltResamplePipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<GantryTiltResampleUniforms>.stride, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func scaleMatrix(factor: Int) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(Float(factor), 0, 0, 0),
            SIMD4<Float>(0, Float(factor), 0, 0),
            SIMD4<Float>(0, 0, Float(factor), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private func downsampleVolume(
        _ source: [Float],
        dimensions: SIMD3<Int>,
        factor: Int,
        voxelSpacing: SIMD3<Float>
    ) -> (data: [Float], dimensions: SIMD3<Int>) {
        let factor = max(factor, 1)
        if factor == 1 || dimensions.x < 2 || dimensions.y < 2 || dimensions.z < 2 {
            return (source, dimensions)
        }

        let sigmaMM = Float(factor) * 0.5
        let sigmaX = sigmaMM / max(voxelSpacing.x, 0.0001)
        let sigmaY = sigmaMM / max(voxelSpacing.y, 0.0001)
        let sigmaZ = sigmaMM / max(voxelSpacing.z, 0.0001)
        let blurred = gaussianBlur3D(source, dimensions: dimensions, sigma: SIMD3<Float>(sigmaX, sigmaY, sigmaZ))

        let outputWidth = max((dimensions.x + factor - 1) / factor, 1)
        let outputHeight = max((dimensions.y + factor - 1) / factor, 1)
        let outputDepth = max((dimensions.z + factor - 1) / factor, 1)
        var output = [Float](repeating: 0, count: outputWidth * outputHeight * outputDepth)

        func sourceIndex(x: Int, y: Int, z: Int) -> Int {
            z * dimensions.x * dimensions.y + y * dimensions.x + x
        }

        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: outputDepth) { z in
                for y in 0..<outputHeight {
                    for x in 0..<outputWidth {
                        let startX = x * factor
                        let startY = y * factor
                        let startZ = z * factor
                        let endX = min(startX + factor, dimensions.x)
                        let endY = min(startY + factor, dimensions.y)
                        let endZ = min(startZ + factor, dimensions.z)

                        var sum: Float = 0
                        var count = 0
                        for sampleZ in startZ..<endZ {
                            for sampleY in startY..<endY {
                                for sampleX in startX..<endX {
                                    sum += blurred[sourceIndex(x: sampleX, y: sampleY, z: sampleZ)]
                                    count += 1
                                }
                            }
                        }

                        let outputIndex = z * outputWidth * outputHeight + y * outputWidth + x
                        outputBase[outputIndex] = count > 0 ? sum / Float(count) : 0
                    }
                }
            }
        }

        return (output, SIMD3<Int>(outputWidth, outputHeight, outputDepth))
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
        return thinnest < 40 && anisotropy < 0.35
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

    private func gaussianBlur3D(_ source: [Float], dimensions: SIMD3<Int>, sigma: SIMD3<Float>) -> [Float] {
        var result = source
        if sigma.x > 0.001 {
            result = convolveVolume(result, dimensions: dimensions, kernel: gaussianKernel(sigma: sigma.x), axis: 0)
        }
        if sigma.y > 0.001 {
            result = convolveVolume(result, dimensions: dimensions, kernel: gaussianKernel(sigma: sigma.y), axis: 1)
        }
        if sigma.z > 0.001 {
            result = convolveVolume(result, dimensions: dimensions, kernel: gaussianKernel(sigma: sigma.z), axis: 2)
        }
        return result
    }

    private func gaussianKernel(sigma: Float) -> [Float] {
        let clampedSigma = max(sigma, 0.001)
        let radius = max(Int(ceil(clampedSigma * 2.5)), 1)
        var kernel: [Float] = []
        kernel.reserveCapacity(radius * 2 + 1)
        var sum: Float = 0

        for offset in -radius...radius {
            let x = Float(offset)
            let value = exp(-(x * x) / (2 * clampedSigma * clampedSigma))
            kernel.append(value)
            sum += value
        }

        guard sum > 0 else { return [1] }
        return kernel.map { $0 / sum }
    }

    private func convolveVolume(_ source: [Float], dimensions: SIMD3<Int>, kernel: [Float], axis: Int) -> [Float] {
        let radius = kernel.count / 2
        var output = [Float](repeating: 0, count: source.count)

        func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
            z * dimensions.x * dimensions.y + y * dimensions.x + x
        }

        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: dimensions.z) { z in
                for y in 0..<dimensions.y {
                    for x in 0..<dimensions.x {
                        var sum: Float = 0
                        for kernelIndex in 0..<kernel.count {
                            let offset = kernelIndex - radius
                            let sampleX: Int
                            let sampleY: Int
                            let sampleZ: Int

                            switch axis {
                            case 0:
                                sampleX = min(max(x + offset, 0), dimensions.x - 1)
                                sampleY = y
                                sampleZ = z
                            case 1:
                                sampleX = x
                                sampleY = min(max(y + offset, 0), dimensions.y - 1)
                                sampleZ = z
                            default:
                                sampleX = x
                                sampleY = y
                                sampleZ = min(max(z + offset, 0), dimensions.z - 1)
                            }

                            sum += source[index(sampleX, sampleY, sampleZ)] * kernel[kernelIndex]
                        }
                        outputBase[index(x, y, z)] = sum
                    }
                }
            }
        }

        return output
    }

    private func orthogonalVolumeGeometry(for pixList: [DCMPix]) -> OrthogonalVolumeGeometry {
        let sourceDimensions = volumeDimensions(for: pixList)
        let orthogonalMatrix = volumeVoxelToWorldMatrix(for: pixList)
        let sourceMatrix = sourceVolumeVoxelToWorldMatrix(for: pixList)
        guard sourceDimensions.x > 0, sourceDimensions.y > 0, sourceDimensions.z > 0 else {
            return OrthogonalVolumeGeometry(
                dimensions: sourceDimensions,
                voxelToWorld: orthogonalMatrix,
                sourceVoxelToWorld: sourceMatrix,
                gantryTiltShiftPerSliceMM: 0
            )
        }

        let orthogonalSliceStep = SIMD3<Float>(
            orthogonalMatrix.columns.2.x,
            orthogonalMatrix.columns.2.y,
            orthogonalMatrix.columns.2.z
        )
        let sourceSliceStep = SIMD3<Float>(
            sourceMatrix.columns.2.x,
            sourceMatrix.columns.2.y,
            sourceMatrix.columns.2.z
        )
        let gantryTiltShift = simd_length(sourceSliceStep - orthogonalSliceStep)
        guard gantryTiltShift > 0.01 else {
            return OrthogonalVolumeGeometry(
                dimensions: sourceDimensions,
                voxelToWorld: orthogonalMatrix,
                sourceVoxelToWorld: sourceMatrix,
                gantryTiltShiftPerSliceMM: gantryTiltShift
            )
        }

        let inverseOrthogonalMatrix = simd_inverse(orthogonalMatrix)
        let maxX = Float(max(sourceDimensions.x - 1, 0))
        let maxY = Float(max(sourceDimensions.y - 1, 0))
        let maxZ = Float(max(sourceDimensions.z - 1, 0))
        let sourceCorners = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(maxX, 0, 0),
            SIMD3<Float>(maxX, maxY, 0),
            SIMD3<Float>(0, maxY, 0),
            SIMD3<Float>(0, 0, maxZ),
            SIMD3<Float>(maxX, 0, maxZ),
            SIMD3<Float>(maxX, maxY, maxZ),
            SIMD3<Float>(0, maxY, maxZ),
        ]

        let orthogonalCoordinates = sourceCorners.map { sourceCorner -> SIMD3<Float> in
            let sourceWorld = sourceMatrix * SIMD4<Float>(sourceCorner, 1)
            let orthogonalVoxel = inverseOrthogonalMatrix * sourceWorld
            return SIMD3<Float>(orthogonalVoxel.x, orthogonalVoxel.y, orthogonalVoxel.z)
        }

        var minimumVoxel = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximumVoxel = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for coordinate in orthogonalCoordinates {
            minimumVoxel = SIMD3<Float>(
                Swift.min(minimumVoxel.x, coordinate.x),
                Swift.min(minimumVoxel.y, coordinate.y),
                Swift.min(minimumVoxel.z, coordinate.z)
            )
            maximumVoxel = SIMD3<Float>(
                Swift.max(maximumVoxel.x, coordinate.x),
                Swift.max(maximumVoxel.y, coordinate.y),
                Swift.max(maximumVoxel.z, coordinate.z)
            )
        }

        let minimumIndex = SIMD3<Float>(floor(minimumVoxel.x), floor(minimumVoxel.y), floor(minimumVoxel.z))
        let maximumIndex = SIMD3<Float>(ceil(maximumVoxel.x), ceil(maximumVoxel.y), ceil(maximumVoxel.z))
        let expandedDimensions = SIMD3<Int>(
            max(Int(maximumIndex.x - minimumIndex.x) + 1, sourceDimensions.x),
            max(Int(maximumIndex.y - minimumIndex.y) + 1, sourceDimensions.y),
            max(Int(maximumIndex.z - minimumIndex.z) + 1, sourceDimensions.z)
        )
        let expandedOrigin = orthogonalMatrix * SIMD4<Float>(minimumIndex, 1)
        let expandedMatrix = simd_float4x4(
            orthogonalMatrix.columns.0,
            orthogonalMatrix.columns.1,
            orthogonalMatrix.columns.2,
            SIMD4<Float>(expandedOrigin.x, expandedOrigin.y, expandedOrigin.z, 1)
        )

        print(String(
            format: "HOROS_METAL_TIMING MetalViewerRenderer gantryTiltGeometry shiftPerSlice=%.3fmm source=%dx%dx%d orthogonal=%dx%dx%d",
            gantryTiltShift,
            sourceDimensions.x,
            sourceDimensions.y,
            sourceDimensions.z,
            expandedDimensions.x,
            expandedDimensions.y,
            expandedDimensions.z
        ))

        return OrthogonalVolumeGeometry(
            dimensions: expandedDimensions,
            voxelToWorld: expandedMatrix,
            sourceVoxelToWorld: sourceMatrix,
            gantryTiltShiftPerSliceMM: gantryTiltShift
        )
    }

    private func resampleGantryTiltedVolume(
        _ pixList: [DCMPix],
        outputDimensions: SIMD3<Int>,
        outputVoxelToWorld: simd_float4x4,
        sourceVoxelToWorld: simd_float4x4
    ) -> [Float] {
        let width = max(outputDimensions.x, 1)
        let height = max(outputDimensions.y, 1)
        let depth = max(outputDimensions.z, 1)
        let backgroundValue: Float = pixList.first?.modalityString?.uppercased().contains("CT") == true ? -1024 : 0
        let sourceWorldToVoxel = simd_inverse(sourceVoxelToWorld)
        var output = [Float](repeating: backgroundValue, count: width * height * depth)

        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: depth) { z in
                for y in 0..<height {
                    for x in 0..<width {
                        let outputVoxel = SIMD4<Float>(Float(x), Float(y), Float(z), 1)
                        let world = outputVoxelToWorld * outputVoxel
                        let sourceVoxel = sourceWorldToVoxel * world
                        outputBase[z * width * height + y * width + x] = sampleSourceVolume(
                            pixList,
                            x: sourceVoxel.x,
                            y: sourceVoxel.y,
                            z: sourceVoxel.z,
                            backgroundValue: backgroundValue
                        )
                    }
                }
            }
        }

        return output
    }

    private func sampleSourceVolume(
        _ pixList: [DCMPix],
        x: Float,
        y: Float,
        z: Float,
        backgroundValue: Float
    ) -> Float {
        guard let firstPix = pixList.first else { return backgroundValue }
        let width = Int(firstPix.pwidth)
        let height = Int(firstPix.pheight)
        let depth = pixList.count
        guard width > 0, height > 0, depth > 0,
              x >= 0, y >= 0, z >= 0,
              x <= Float(width - 1),
              y <= Float(height - 1),
              z <= Float(depth - 1) else {
            return backgroundValue
        }

        let x0 = min(max(Int(floor(x)), 0), width - 1)
        let y0 = min(max(Int(floor(y)), 0), height - 1)
        let z0 = min(max(Int(floor(z)), 0), depth - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let z1 = min(z0 + 1, depth - 1)
        let tx = x - Float(x0)
        let ty = y - Float(y0)
        let tz = z - Float(z0)

        func sample(_ sx: Int, _ sy: Int, _ sz: Int) -> Float {
            guard pixList.indices.contains(sz),
                  let pixels = pixList[sz].fImage else {
                return backgroundValue
            }
            return pixels[sy * width + sx]
        }

        let c000 = sample(x0, y0, z0)
        let c100 = sample(x1, y0, z0)
        let c010 = sample(x0, y1, z0)
        let c110 = sample(x1, y1, z0)
        let c001 = sample(x0, y0, z1)
        let c101 = sample(x1, y0, z1)
        let c011 = sample(x0, y1, z1)
        let c111 = sample(x1, y1, z1)

        let c00 = c000 * (1 - tx) + c100 * tx
        let c10 = c010 * (1 - tx) + c110 * tx
        let c01 = c001 * (1 - tx) + c101 * tx
        let c11 = c011 * (1 - tx) + c111 * tx
        let c0 = c00 * (1 - ty) + c10 * ty
        let c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz
    }

    private func sourceVolumeVoxelToWorldMatrix(for pixList: [DCMPix]) -> simd_float4x4 {
        guard let firstPix = pixList.first else {
            return matrix_identity_float4x4
        }

        let orientation = orientationVector(for: firstPix)
        let row = simd_normalize(SIMD3<Float>(orientation[0], orientation[1], orientation[2]))
        let column = simd_normalize(SIMD3<Float>(orientation[3], orientation[4], orientation[5]))
        let fallbackNormal = simd_normalize(simd_cross(row, column))

        let sliceStep: SIMD3<Float>
        if pixList.count > 1, let lastPix = pixList.last {
            let delta = SIMD3<Float>(
                Float(lastPix.originX - firstPix.originX),
                Float(lastPix.originY - firstPix.originY),
                Float(lastPix.originZ - firstPix.originZ)
            ) / Float(max(pixList.count - 1, 1))
            sliceStep = simd_length(delta) > 0.0001 ? delta : fallbackNormal * sliceSpacing(for: firstPix)
        } else {
            sliceStep = fallbackNormal * sliceSpacing(for: firstPix)
        }

        let rowStep = row * Float(max(firstPix.pixelSpacingX, 0.000001))
        let columnStep = column * Float(max(firstPix.pixelSpacingY, 0.000001))
        let origin = SIMD3<Float>(Float(firstPix.originX), Float(firstPix.originY), Float(firstPix.originZ))

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }

    private func volumeVoxelToWorldMatrix(for pixList: [DCMPix]) -> simd_float4x4 {
        guard let firstPix = pixList.first else {
            return matrix_identity_float4x4
        }

        let orientation = orientationVector(for: firstPix)
        let row = simd_normalize(SIMD3<Float>(orientation[0], orientation[1], orientation[2]))
        let column = simd_normalize(SIMD3<Float>(orientation[3], orientation[4], orientation[5]))
        let fallbackNormal = simd_normalize(simd_cross(row, column))

        let sliceStep: SIMD3<Float>
        if pixList.count > 1, let lastPix = pixList.last {
            let delta = SIMD3<Float>(
                Float(lastPix.originX - firstPix.originX),
                Float(lastPix.originY - firstPix.originY),
                Float(lastPix.originZ - firstPix.originZ)
            ) / Float(max(pixList.count - 1, 1))
            let normalSpacing = simd_dot(delta, fallbackNormal)
            sliceStep = abs(normalSpacing) > 0.0001
                ? fallbackNormal * normalSpacing
                : fallbackNormal * sliceSpacing(for: firstPix)
        } else {
            sliceStep = fallbackNormal * sliceSpacing(for: firstPix)
        }

        let rowStep = row * Float(max(firstPix.pixelSpacingX, 0.000001))
        let columnStep = column * Float(max(firstPix.pixelSpacingY, 0.000001))
        let origin = SIMD3<Float>(Float(firstPix.originX), Float(firstPix.originY), Float(firstPix.originZ))

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }

    private func sliceSpacing(for pix: DCMPix) -> Float {
        let candidates = [pix.sliceInterval, pix.spacingBetweenSlices, pix.sliceThickness]
        let spacing = candidates.first(where: { abs($0) > 0.000001 }) ?? 1.0
        return Float(abs(spacing))
    }

    private func volumeCenterWorld(for pixList: [DCMPix], voxelToWorld: simd_float4x4) -> SIMD3<Float> {
        guard let firstPix = pixList.first else { return .zero }
        let centerVoxel = SIMD4<Float>(
            Float(max(firstPix.pwidth - 1, 0)) * 0.5,
            Float(max(firstPix.pheight - 1, 0)) * 0.5,
            Float(max(pixList.count - 1, 0)) * 0.5,
            1
        )
        let world = voxelToWorld * centerVoxel
        return SIMD3<Float>(world.x, world.y, world.z)
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

    private func informativeCenterWorld(
        for volumeData: [Float],
        dimensions: SIMD3<Int>,
        voxelToWorld: simd_float4x4,
        level: Float,
        width: Float
    ) -> SIMD3<Float> {
        guard volumeData.isEmpty == false else { return .zero }

        let normalizedThreshold: Float = 0.18
        let sliceElementCount = max(dimensions.x * dimensions.y, 1)
        let maxSamples = 200_000
        let strideX = max(dimensions.x / 96, 1)
        let strideY = max(dimensions.y / 96, 1)
        let strideZ = max(dimensions.z / 96, 1)
        let voxelCount = max(sliceElementCount * dimensions.z, 1)
        let adaptiveStride = max(Int(sqrt(Double(max(voxelCount / maxSamples, 1)))), 1)
        let sampleStrideX = max(strideX, adaptiveStride)
        let sampleStrideY = max(strideY, adaptiveStride)
        let sampleStrideZ = max(strideZ, adaptiveStride)

        var weightedWorld = SIMD3<Float>(repeating: 0)
        var totalWeight: Float = 0

        for z in stride(from: 0, to: max(dimensions.z, 1), by: sampleStrideZ) {
            for y in stride(from: 0, to: max(dimensions.y, 1), by: sampleStrideY) {
                for x in stride(from: 0, to: max(dimensions.x, 1), by: sampleStrideX) {
                    let index = z * sliceElementCount + y * dimensions.x + x
                    guard volumeData.indices.contains(index) else { continue }
                    let value = volumeData[index]
                    let normalized = min(max((value - (level - width * 0.5)) / max(width, 1), 0), 1)
                    let weight = max(normalized - normalizedThreshold, 0)
                    if weight <= 0 {
                        continue
                    }

                    let voxel = SIMD4<Float>(Float(x), Float(y), Float(z), 1)
                    let world = voxelToWorld * voxel
                    weightedWorld += SIMD3<Float>(world.x, world.y, world.z) * weight
                    totalWeight += weight
                }
            }
        }

        if totalWeight <= 0.0001 {
            return volumeCenterWorld(dimensions: dimensions, voxelToWorld: voxelToWorld)
        }

        return weightedWorld / totalWeight
    }

    private func informativeCenterWorld(
        for pixList: [DCMPix],
        dimensions: SIMD3<Int>,
        voxelToWorld: simd_float4x4,
        level: Float,
        width: Float
    ) -> SIMD3<Float> {
        guard pixList.isEmpty == false else { return .zero }

        let normalizedThreshold: Float = 0.18
        let sliceElementCount = max(dimensions.x * dimensions.y, 1)
        let maxSamples = 200_000
        let strideX = max(dimensions.x / 96, 1)
        let strideY = max(dimensions.y / 96, 1)
        let strideZ = max(dimensions.z / 96, 1)
        let voxelCount = max(sliceElementCount * dimensions.z, 1)
        let adaptiveStride = max(Int(sqrt(Double(max(voxelCount / maxSamples, 1)))), 1)
        let sampleStrideX = max(strideX, adaptiveStride)
        let sampleStrideY = max(strideY, adaptiveStride)
        let sampleStrideZ = max(strideZ, adaptiveStride)

        var weightedWorld = SIMD3<Float>(repeating: 0)
        var totalWeight: Float = 0

        for z in stride(from: 0, to: max(dimensions.z, 1), by: sampleStrideZ) {
            let sliceIndex = min(max(z, 0), pixList.count - 1)
            guard let pixels = pixList[sliceIndex].fImage else { continue }
            for y in stride(from: 0, to: max(dimensions.y, 1), by: sampleStrideY) {
                for x in stride(from: 0, to: max(dimensions.x, 1), by: sampleStrideX) {
                    let index = z * sliceElementCount + y * dimensions.x + x
                    let sliceOffset = index - z * sliceElementCount
                    guard sliceOffset >= 0, sliceOffset < sliceElementCount else { continue }

                    let value = pixels[sliceOffset]
                    let normalized = min(max((value - (level - width * 0.5)) / max(width, 1), 0), 1)
                    let weight = max(normalized - normalizedThreshold, 0)
                    if weight <= 0 {
                        continue
                    }

                    let voxel = SIMD4<Float>(Float(x), Float(y), Float(z), 1)
                    let world = voxelToWorld * voxel
                    weightedWorld += SIMD3<Float>(world.x, world.y, world.z) * weight
                    totalWeight += weight
                }
            }
        }

        if totalWeight <= 0.0001 {
            let centerVoxel = SIMD4<Float>(
                Float(max(dimensions.x - 1, 0)) * 0.5,
                Float(max(dimensions.y - 1, 0)) * 0.5,
                Float(max(dimensions.z - 1, 0)) * 0.5,
                1
            )
            let world = voxelToWorld * centerVoxel
            return SIMD3<Float>(world.x, world.y, world.z)
        }

        return weightedWorld / totalWeight
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

    private func orientationVector(for pix: DCMPix) -> [Float] {
        var vector = Array(repeating: Float(0), count: 9)
        let selector = NSSelectorFromString("orientation:")
        typealias OrientationIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>?) -> Void
        let implementation = pix.method(for: selector)
        let function = unsafeBitCast(implementation, to: OrientationIMP.self)
        function(pix, selector, &vector)
        return vector
    }

    private func transformedOverlayCenterWorld(for state: RigidTransformState) -> SIMD3<Float> {
        let centeredPoint = overlayInformativeCenterWorld - movingRotationCenterWorld
        let rotated = rotationMatrix(for: state.rotationRadians) * SIMD4<Float>(centeredPoint, 1)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z) + movingRotationCenterWorld + state.translationWorld
    }

    private func transformedOverlayVolumeCenterWorld(for state: RigidTransformState) -> SIMD3<Float> {
        let centeredPoint = overlayVolumeCenterWorld - movingRotationCenterWorld
        let rotated = rotationMatrix(for: state.rotationRadians) * SIMD4<Float>(centeredPoint, 1)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z) + movingRotationCenterWorld + state.translationWorld
    }

    private func slabOverlapPenalty(for state: RigidTransformState) -> Float {
        guard let baseSlabGeometry, let overlaySlabGeometry else { return 0 }

        let transformedOverlayCenter = transformedOverlayVolumeCenterWorld(for: state)
        let centerDelta = transformedOverlayCenter - baseVolumeCenterWorld
        let combinedNormal = baseSlabGeometry.normalWorld + overlaySlabGeometry.normalWorld
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

    private func centerOfMassInitialGuess() -> RigidTransformState {
        guard baseVolumeLevels.isEmpty == false,
              overlayVolumeLevels.isEmpty == false else {
            return RigidTransformState(
                translationWorld: overlayTranslationWorld,
                rotationRadians: overlayRotationRadians
            )
        }

        let currentState = RigidTransformState(
            translationWorld: overlayTranslationWorld,
            rotationRadians: overlayRotationRadians
        )
        let transformedOverlayCenter = transformedOverlayCenterWorld(for: currentState)
        let delta = baseInformativeCenterWorld - transformedOverlayCenter

        return RigidTransformState(
            translationWorld: overlayTranslationWorld + delta,
            rotationRadians: overlayRotationRadians
        )
    }

    private func runRegistration() {
        guard baseVolumeLevels.isEmpty == false, overlayVolumeLevels.isEmpty == false else { return }

        let registrationStart = CFAbsoluteTimeGetCurrent()
        registrationGeneration += 1
        let generation = registrationGeneration
        registrationMetricCallCount = 0
        registrationMetricTotalTime = 0
        registrationMetricGPUTime = 0
        registrationMetricCPUTime = 0
        let initialGuess = centerOfMassInitialGuess()
        publishRegistrationUpdate(
            state: initialGuess,
            inProgress: true,
            progress: 0,
            message: "Registering 3D",
            residualError: nil,
            generation: generation
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.logRegistrationSamplingProbe(for: initialGuess)
            let result = self.optimizeOverlayTransform(startingAt: initialGuess, generation: generation)
            let metricCount = self.registrationMetricCallCount
            let metricTotal = self.registrationMetricTotalTime
            let metricGPU = self.registrationMetricGPUTime
            let metricCPU = self.registrationMetricCPUTime

            DispatchQueue.main.async {
                guard generation == self.registrationGeneration else { return }
                print(String(
                    format: "HOROS_METAL_TIMING MetalViewerRenderer registration metrics calls=%d total=%.3f s gpu=%.3f s cpu=%.3f s avg=%.4f s",
                    metricCount,
                    metricTotal,
                    metricGPU,
                    metricCPU,
                    metricCount > 0 ? metricTotal / Double(metricCount) : 0
                ))
                self.publishRegistrationUpdate(
                    state: result.state,
                    inProgress: false,
                    progress: 1,
                    message: "Registered 3D",
                    residualError: result.metric,
                    generation: generation
                )
                metalRendererTimingLog("MetalViewerRenderer registration total", since: registrationStart)
            }
        }
    }

    private func logRegistrationSamplingProbe(for state: RigidTransformState) {
        let levelPairs = Array(zip(baseVolumeLevels, overlayVolumeLevels))
        guard levelPairs.isEmpty == false else { return }

        for (levelIndex, levelPair) in levelPairs.enumerated() {
            let probeStart = CFAbsoluteTimeGetCurrent()
            let baseVolumeTexture = levelPair.0.texture
            let overlayVolumeTexture = levelPair.1.texture
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
            let threadgroups = MTLSize(
                width: (baseVolumeTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: (baseVolumeTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                depth: (baseVolumeTexture.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
            )
            let countBufferLength = max(threadgroups.width * threadgroups.height * threadgroups.depth, 1) * MemoryLayout<UInt32>.stride
            guard let countBuffer = deviceRef.makeBuffer(length: countBufferLength, options: .storageModeShared) else {
                continue
            }
            memset(countBuffer.contents(), 0, countBufferLength)

            let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: levelIndex, totalLevels: levelPairs.count)
            var uniforms = RegistrationUniforms(
                baseWindowLevel: baseRegistrationWindowLevel,
                baseWindowWidth: max(baseRegistrationWindowWidth, 1),
                overlayWindowLevel: overlayRegistrationWindowLevel,
                overlayWindowWidth: max(overlayRegistrationWindowWidth, 1),
                metricOptions: metricOptions(forLevelIndex: levelIndex, totalLevels: levelPairs.count, useBoneOnly: useBoneOnly),
                overlayTranslationWorld: state.translationWorld,
                movingRotationCenterWorld: movingRotationCenterWorld,
                baseTextureSize: SIMD3<UInt32>(
                    UInt32(baseVolumeTexture.width),
                    UInt32(baseVolumeTexture.height),
                    UInt32(baseVolumeTexture.depth)
                ),
                movingInverseRotation: rotationMatrix(for: -state.rotationRadians),
                fixedVoxelToWorld: levelPair.0.voxelToWorld,
                movingWorldToVoxel: simd_inverse(levelPair.1.voxelToWorld)
            )

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                continue
            }

            encoder.setComputePipelineState(registrationSamplingProbePipelineState)
            encoder.setTexture(baseVolumeTexture, index: 0)
            encoder.setTexture(overlayVolumeTexture, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<RegistrationUniforms>.stride, index: 0)
            encoder.setBuffer(countBuffer, offset: 0, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let counts = countBuffer.contents().bindMemory(to: UInt32.self, capacity: countBufferLength / MemoryLayout<UInt32>.stride)
            var acceptedSamples = 0
            for index in 0..<(countBufferLength / MemoryLayout<UInt32>.stride) {
                acceptedSamples += Int(counts[index])
            }

            print(String(
                format: "HOROS_METAL_TIMING MetalViewerRenderer registration samplingProbe level=%d/%d samples=%d %.3f s",
                levelIndex + 1,
                levelPairs.count,
                acceptedSamples,
                CFAbsoluteTimeGetCurrent() - probeStart
            ))
        }
    }

    private func optimizeOverlayTransform(startingAt initialGuess: RigidTransformState, generation: UInt) -> (state: RigidTransformState, metric: Float) {
        let optimizeStart = CFAbsoluteTimeGetCurrent()
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

        let levelPairs = Array(zip(baseVolumeLevels, overlayVolumeLevels))
        guard levelPairs.isEmpty == false else { return (initialGuess, .greatestFiniteMagnitude) }
        let seeded = coarseSeedSearch(
            startingAt: initialGuess,
            level: levelPairs[0],
            totalLevels: levelPairs.count,
            fastAxisOnly: ctToCTRegistration
        )
        var best = seeded.state
        var bestMetric = seeded.metric

        for (levelIndex, levelPair) in levelPairs.enumerated() {
            let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: levelIndex, totalLevels: levelPairs.count)
            let levelMetricOptions = metricOptions(forLevelIndex: levelIndex, totalLevels: levelPairs.count, useBoneOnly: useBoneOnly)
            print(String(
                format: "HOROS_METAL_TIMING MetalViewerRenderer registration level=%d/%d metricMode=%@ options=(%.3f, %.3f, %.3f, %.3f)",
                levelIndex + 1,
                levelPairs.count,
                metricModeName(levelMetricOptions) as NSString,
                levelMetricOptions.x,
                levelMetricOptions.y,
                levelMetricOptions.z,
                levelMetricOptions.w
            ))
            let isFinalFullResolutionLevel = levelIndex == levelPairs.count - 1
            let stepsForLevel = isFinalFullResolutionLevel && rigidSteps.count > 3
                ? Array(rigidSteps.suffix(3))
                : rigidSteps

            for (stepIndex, step) in stepsForLevel.enumerated() {
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
                    generation: generation,
                    stepIndex: stepIndex,
                    totalSteps: stepsForLevel.count
                )
                best = result.state
                bestMetric = result.metric
                print(String(
                    format: "HOROS_METAL_TIMING MetalViewerRenderer registration level=%d/%d step=%d/%d metric=%.6f",
                    levelIndex + 1,
                    levelPairs.count,
                    stepIndex + 1,
                    stepsForLevel.count,
                    bestMetric
                ))

                let totalStageCount = levelPairs.enumerated().reduce(0) { partial, item in
                    let itemIsFinalFullResolutionLevel = item.offset == levelPairs.count - 1
                    return partial + (itemIsFinalFullResolutionLevel && rigidSteps.count > 3 ? 3 : rigidSteps.count)
                }
                let completedStagesBeforeLevel = levelPairs.prefix(levelIndex).enumerated().reduce(0) { partial, item in
                    let itemIsFinalFullResolutionLevel = item.offset == levelPairs.count - 1
                    return partial + (itemIsFinalFullResolutionLevel && rigidSteps.count > 3 ? 3 : rigidSteps.count)
                }
                let completedStages = Float(completedStagesBeforeLevel + stepIndex + 1)
                let progress = completedStages / Float(max(totalStageCount, 1))
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: progress,
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count)",
                    residualError: bestMetric,
                    generation: generation
                )
            }

            if ctToCTRegistration == false {
                let refinement = smoothDescentRefinement(
                    startingAt: best,
                    startingMetric: bestMetric,
                    level: levelPair,
                    levelIndex: levelIndex,
                    totalLevels: levelPairs.count,
                    useBoneOnly: useBoneOnly,
                    generation: generation
                )
                best = refinement.state
                bestMetric = refinement.metric
                print(String(
                    format: "HOROS_METAL_TIMING MetalViewerRenderer registration level=%d/%d smoothDescent metric=%.6f",
                    levelIndex + 1,
                    levelPairs.count,
                    bestMetric
                ))
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: Float(levelIndex + 1) / Float(max(levelPairs.count, 1)),
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count) refine",
                    residualError: bestMetric,
                    generation: generation
                )
            }
        }

        metalRendererTimingLog("MetalViewerRenderer optimizeOverlayTransform total", since: optimizeStart)
        return (best, bestMetric)
    }

    private func coarseSeedSearch(
        startingAt initialState: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        totalLevels: Int,
        fastAxisOnly: Bool
    ) -> (state: RigidTransformState, metric: Float) {
        let seedStart = CFAbsoluteTimeGetCurrent()
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let seedDistance: Float = slabAwareRegistration ? 24 : 60
        let translationSeeds: [SIMD3<Float>]
        if fastAxisOnly {
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
        let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: 0, totalLevels: totalLevels)
        var bestState = initialState
        var bestMetric = Float.greatestFiniteMagnitude
        var evaluatedSeeds = 0

        for translationSeed in translationSeeds {
            var candidate = initialState
            candidate.translationWorld += translationSeed
            let candidateMetric = metricValue(
                for: candidate,
                level: level,
                levelIndex: 0,
                totalLevels: totalLevels,
                useBoneOnly: useBoneOnly
            )
            evaluatedSeeds += 1
            if candidateMetric < bestMetric {
                bestMetric = candidateMetric
                bestState = candidate
            }
        }

        print(String(
            format: "HOROS_METAL_TIMING MetalViewerRenderer registration coarseSeedSearch seeds=%d best=%.6f %.3f s",
            evaluatedSeeds,
            bestMetric,
            CFAbsoluteTimeGetCurrent() - seedStart
        ))
        return (bestState, bestMetric)
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
        generation: UInt,
        stepIndex: Int,
        totalSteps: Int
    ) -> (state: RigidTransformState, metric: Float) {
        let levelStart = CFAbsoluteTimeGetCurrent()
        let startingMetricCount = registrationMetricCallCount
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

        var simplex: [Vertex] = []
        let startParameters = parameters(for: initialState)
        simplex.append(Vertex(parameters: startParameters, metric: metricValue(for: initialState, level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)))
        for dimension in 0..<6 {
            var candidate = startParameters
            candidate[dimension] += parameterScales[dimension]
            simplex.append(Vertex(parameters: candidate, metric: metricValue(for: state(for: candidate), level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)))
        }

        func sortSimplex() {
            simplex.sort { $0.metric < $1.metric }
        }

        sortSimplex()
        var bestMetric = simplex[0].metric
        var bestState = state(for: simplex[0].parameters)

        for iteration in 0..<maxIterations {
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
            let reflectedMetric = metricValue(for: state(for: reflected), level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)

            if reflectedMetric < bestVertex.metric {
                let expanded = centroid + gamma * (reflected - centroid)
                let expandedMetric = metricValue(for: state(for: expanded), level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)
                simplex[6] = expandedMetric < reflectedMetric
                    ? Vertex(parameters: expanded, metric: expandedMetric)
                    : Vertex(parameters: reflected, metric: reflectedMetric)
            } else if reflectedMetric < secondWorstVertex.metric {
                simplex[6] = Vertex(parameters: reflected, metric: reflectedMetric)
            } else {
                let shouldOutsideContract = reflectedMetric < worstVertex.metric
                let contractionTarget = shouldOutsideContract ? reflected : worstVertex.parameters
                let contracted = centroid + rho * (contractionTarget - centroid)
                let contractedMetric = metricValue(for: state(for: contracted), level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)

                let contractionAccepted = shouldOutsideContract
                    ? contractedMetric <= reflectedMetric
                    : contractedMetric < worstVertex.metric

                if contractionAccepted {
                    simplex[6] = Vertex(parameters: contracted, metric: contractedMetric)
                } else {
                    for index in 1..<simplex.count {
                        simplex[index].parameters = bestVertex.parameters + sigma * (simplex[index].parameters - bestVertex.parameters)
                        simplex[index].metric = metricValue(for: state(for: simplex[index].parameters), level: level, levelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)
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
                generation: generation
            )

            if parameterSpan < Swift.max(translationMM * 0.25, rotationRadians * 0.25) && metricSpan < 0.0001 {
                break
            }
        }

        sortSimplex()
        let metricCalls = registrationMetricCallCount - startingMetricCount
        print(String(
            format: "HOROS_METAL_TIMING MetalViewerRenderer optimizeLevelWithNelderMead level=%d/%d step=%d/%d calls=%d best=%.6f %.3f s",
            levelIndex + 1,
            totalLevels,
            stepIndex + 1,
            totalSteps,
            metricCalls,
            simplex[0].metric,
            CFAbsoluteTimeGetCurrent() - levelStart
        ))
        return (state(for: simplex[0].parameters), simplex[0].metric)
    }

    private func smoothDescentRefinement(
        startingAt initialState: RigidTransformState,
        startingMetric initialMetric: Float,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool,
        generation: UInt
    ) -> (state: RigidTransformState, metric: Float) {
        let descentStart = CFAbsoluteTimeGetCurrent()
        let startingMetricCount = registrationMetricCallCount
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
            pass += 1
            var improvedThisPass = false

            for dimension in 0..<6 {
                let step: Float
                if dimension < 3 {
                    step = translationStep >= minTranslationStep ? translationStep : 0
                } else {
                    step = rotationStep >= minRotationStep ? rotationStep : 0
                }
                guard step > 0 else { continue }

                var bestCandidateParameters = bestParameters
                var bestCandidateMetric = bestMetric

                for direction in [Float(-1), Float(1)] {
                    var candidate = bestParameters
                    candidate[dimension] += direction * step
                    let candidateState = state(for: candidate)
                    let candidateMetric = metricValue(
                        for: candidateState,
                        level: level,
                        levelIndex: levelIndex,
                        totalLevels: totalLevels,
                        useBoneOnly: useBoneOnly
                    )
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
                generation: generation
            )
        }

        let metricCalls = registrationMetricCallCount - startingMetricCount
        print(String(
            format: "HOROS_METAL_TIMING MetalViewerRenderer smoothDescentRefinement level=%d/%d passes=%d calls=%d best=%.6f finalStep=(%.3fmm, %.4fdeg) %.3f s",
            levelIndex + 1,
            totalLevels,
            pass,
            metricCalls,
            bestMetric,
            translationStep,
            rotationStep * 180 / .pi,
            CFAbsoluteTimeGetCurrent() - descentStart
        ))
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
            self.registrationInProgress = inProgress
            self.registrationProgress = max(0, min(progress, 1))
            let formattedMessage: String
            if let residualError {
                formattedMessage = "\(message ?? (inProgress ? "Registering 3D" : "Registered 3D"))  Residual Error: \(String(format: "%.6f", residualError))"
            } else {
                formattedMessage = message ?? (inProgress ? "Registering 3D" : "Registered 3D")
            }
            self.registrationStatusMessage = formattedMessage
            self.stateDidChange?(self.stateDescription)
            self.registrationDidChange?(inProgress, formattedMessage, self.registrationProgress)
        }
    }

    private func metricValue(
        for state: RigidTransformState,
        level: (VolumeLevel, VolumeLevel),
        levelIndex: Int,
        totalLevels: Int,
        useBoneOnly: Bool
    ) -> Float {
        let metricStart = CFAbsoluteTimeGetCurrent()
        var gpuElapsed: CFTimeInterval = 0
        var cpuElapsed: CFTimeInterval = 0
        defer {
            registrationMetricCallCount += 1
            registrationMetricGPUTime += gpuElapsed
            registrationMetricCPUTime += cpuElapsed
            registrationMetricTotalTime += CFAbsoluteTimeGetCurrent() - metricStart
        }

        let baseVolumeTexture = level.0.texture
        let overlayVolumeTexture = level.1.texture
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
        let threadgroups = MTLSize(
            width: (baseVolumeTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (baseVolumeTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (baseVolumeTexture.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )
        let options = metricOptions(forLevelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly)

        var uniforms = RegistrationUniforms(
            baseWindowLevel: baseRegistrationWindowLevel,
            baseWindowWidth: max(baseRegistrationWindowWidth, 1),
            overlayWindowLevel: overlayRegistrationWindowLevel,
            overlayWindowWidth: max(overlayRegistrationWindowWidth, 1),
            metricOptions: options,
            overlayTranslationWorld: state.translationWorld,
            movingRotationCenterWorld: movingRotationCenterWorld,
            baseTextureSize: SIMD3<UInt32>(
                UInt32(baseVolumeTexture.width),
                UInt32(baseVolumeTexture.height),
                UInt32(baseVolumeTexture.depth)
            ),
            movingInverseRotation: rotationMatrix(for: -state.rotationRadians),
            fixedVoxelToWorld: level.0.voxelToWorld,
            movingWorldToVoxel: simd_inverse(level.1.voxelToWorld)
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

        encoder.setComputePipelineState(registrationPipelineState)
        encoder.setTexture(baseVolumeTexture, index: 0)
        encoder.setTexture(overlayVolumeTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<RegistrationUniforms>.stride, index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        let gpuStart = CFAbsoluteTimeGetCurrent()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        gpuElapsed = CFAbsoluteTimeGetCurrent() - gpuStart
        let cpuStart = CFAbsoluteTimeGetCurrent()

        let histogram = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: histogramEntryCount)
        var overlapCount = 0
        for index in 0..<histogramEntryCount {
            overlapCount += Int(histogram[index])
        }
        guard overlapCount > 0 else {
            return .greatestFiniteMagnitude
        }

        let overlapTotal = Double(overlapCount)
        guard let nmi = smoothedNormalizedMutualInformation(histogram: histogram, bins: registrationHistogramBins) else {
            return .greatestFiniteMagnitude
        }
        let overlapPenalty = registrationOverlapPenalty(
            overlapTotal: overlapTotal,
            fixedVoxelCount: baseVolumeTexture.width * baseVolumeTexture.height * baseVolumeTexture.depth,
            movingVoxelCount: overlayVolumeTexture.width * overlayVolumeTexture.height * overlayVolumeTexture.depth,
            options: options,
            state: state
        )

        let metric = Float(-nmi) + overlapPenalty
        cpuElapsed = CFAbsoluteTimeGetCurrent() - cpuStart
        return metric
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
        let minimumUsefulOverlap: Double
        if mode == 1 {
            minimumUsefulOverlap = slabAwareRegistration ? 0.015 : 0.003
        } else if mode == 3 {
            minimumUsefulOverlap = slabAwareRegistration ? 0.02 : 0.006
        } else {
            minimumUsefulOverlap = slabAwareRegistration ? 0.035 : 0.01
        }
        let overlapPenalty = overlapFraction < minimumUsefulOverlap
            ? Float((minimumUsefulOverlap - overlapFraction) * (slabAwareRegistration ? 8.0 : 4.0))
            : 0
        let slabPenalty = slabAwareRegistration ? slabOverlapPenalty(for: state) : 0
        return overlapPenalty + slabPenalty
    }

    private func metricModeName(_ options: SIMD4<Float>) -> String {
        switch Int(options.x.rounded()) {
        case 1: return "boneNMI"
        case 2: return "structureNMI"
        case 3: return "ctBodyNMI"
        default: return "NMI"
        }
    }

    private func isCTToCTRegistration() -> Bool {
        guard let basePix = pixList.first,
              let overlayPix = overlayPixList.first else {
            return false
        }

        let baseModality = basePix.modalityString?.uppercased() ?? ""
        let overlayModality = overlayPix.modalityString?.uppercased() ?? ""
        return baseModality.contains("CT") && overlayModality.contains("CT")
    }

    private func metricOptions(forLevelIndex _: Int, totalLevels _: Int, useBoneOnly _: Bool) -> SIMD4<Float> {
        if isCTToCTRegistration() {
            return SIMD4<Float>(3, -700, 3000, 0)
        }

        return SIMD4<Float>.zero
    }

    private func shouldUseBoneOnlyMetric(forLevelIndex levelIndex: Int, totalLevels: Int) -> Bool {
        guard totalLevels > 0 else { return false }
        return levelIndex == totalLevels - 1
    }

    private func currentOverlayTranslationPixels(for translationWorld: SIMD3<Float>? = nil) -> SIMD2<Float> {
        guard let currentPix else { return .zero }
        let translation = translationWorld ?? overlayTranslationWorld
        let pixelX = currentPix.pixelSpacingX != 0 ? Double(translation.x) / currentPix.pixelSpacingX : 0
        let pixelY = currentPix.pixelSpacingY != 0 ? Double(translation.y) / currentPix.pixelSpacingY : 0
        return SIMD2<Float>(Float(pixelX), Float(pixelY))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {
        if displayMode == .mpr {
            drawMPR(in: view)
            return
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let baseTexture else {
            return
        }

        let drawableAspect = max(Float(view.drawableSize.width / max(view.drawableSize.height, 1)), 0.0001)
        var scale = SIMD2<Float>(repeating: 1)
        if imageAspectRatio > drawableAspect {
            scale.y = drawableAspect / imageAspectRatio
        } else {
            scale.x = imageAspectRatio / drawableAspect
        }
        scale *= zoomScale
        let offset = SIMD2<Float>(
            Float((CGFloat(panOffset.x) / max(view.bounds.width, 1)) * 2.0),
            Float((CGFloat(panOffset.y) / max(view.bounds.height, 1)) * 2.0)
        )

        var uniforms = MetalUniforms(
            scale: scale,
            offset: offset,
            baseWindowLevel: windowLevel,
            baseWindowWidth: max(windowWidth, 1),
            overlayWindowLevel: overlayWindowLevel,
            overlayWindowWidth: max(overlayWindowWidth, 1),
            overlayBlend: overlayBlend,
            overlayTranslationWorld: overlayTranslationWorld,
            movingRotationCenterWorld: movingRotationCenterWorld,
            fixedVolumeSize: SIMD3<UInt32>(
                UInt32(max(baseVolumeTexture?.width ?? baseTexture.width, 1)),
                UInt32(max(baseVolumeTexture?.height ?? baseTexture.height, 1)),
                UInt32(max(baseVolumeTexture?.depth ?? 1, 1))
            ),
            currentSliceIndex: Float(currentSliceIndex),
            movingInverseRotation: rotationMatrix(for: -overlayRotationRadians),
            fixedVoxelToWorld: fixedVoxelToWorld,
            movingWorldToVoxel: movingWorldToVoxel,
            hasOverlay: overlayVolumeTexture == nil ? 0 : 1
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.setFragmentTexture(baseTexture, index: 0)
        encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
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
        var uniforms = MetalMPRUniforms(
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
            movingInverseRotation: rotationMatrix(for: -overlayRotationRadians),
            fixedVoxelToWorld: fixedVoxelToWorld,
            movingWorldToVoxel: movingWorldToVoxel,
            hasOverlay: overlayVolumeTexture == nil ? 0 : 1
        )
        let renderLayout = mprRenderLayout(for: view)
        if let renderLayout {
            encoder.setViewport(renderLayout.mainViewport)
            encoder.setScissorRect(renderLayout.mainScissor)
        }

        encoder.setRenderPipelineState(mprPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        vertices.withUnsafeBytes { vertexBytes in
            guard let vertexBaseAddress = vertexBytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 0)
            encoder.setFragmentTexture(baseVolumeTexture, index: 0)
            encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        let highlightVertices = makeMPRPlaneHighlightVertices()
        if highlightVertices.isEmpty == false {
            encoder.setRenderPipelineState(mprPlaneHighlightPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            highlightVertices.withUnsafeBytes { vertexBytes in
                guard let vertexBaseAddress = vertexBytes.baseAddress else {
                    return
                }
                encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: highlightVertices.count)
            }
        }

        let borderVertices = makeMPRBorderVertices()
        encoder.setRenderPipelineState(mprBorderPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        borderVertices.withUnsafeBytes { vertexBytes in
            guard let vertexBaseAddress = vertexBytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: borderVertices.count)
        }

        let intersectionVertices = makeMPRIntersectionVertices()
        encoder.setRenderPipelineState(mprIntersectionPipelineState)
        encoder.setDepthStencilState(mprDepthStencilState)
        intersectionVertices.withUnsafeBytes { vertexBytes in
            guard let vertexBaseAddress = vertexBytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
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

        let planes: [MetalMPRPlane] = [.axial, .coronal, .sagittal]
        let panes = Array(zip(planes, metrics.previewPaneRects)).compactMap { pair -> MetalMPRPreviewPane? in
            let (plane, rect) = pair
            let y = min(max(Int(rect.minY.rounded(.down)), 0), max(renderHeight - 1, 0))
            let maxY = min(max(Int(rect.maxY.rounded(.down)), y + 1), renderHeight)
            let height = maxY - y
            guard height > 0 else {
                return nil
            }
            let viewport = MTLViewport(
                originX: Double(previewX),
                originY: Double(y),
                width: Double(previewWidth),
                height: Double(height),
                znear: 0,
                zfar: 1
            )
            let scissor = MTLScissorRect(x: previewX, y: y, width: previewWidth, height: height)
            return MetalMPRPreviewPane(plane: plane, viewport: viewport, scissor: scissor)
        }

        guard panes.count == planes.count else {
            return nil
        }
        return MetalMPRRenderLayout(
            mainViewport: mainViewport,
            mainScissor: mainScissor,
            previewPanes: panes
        )
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

    private func drawMPRPreviewPanes(
        _ panes: [MetalMPRPreviewPane],
        encoder: MTLRenderCommandEncoder,
        uniforms: MetalMPRUniforms,
        baseVolumeTexture: MTLTexture
    ) {
        var previewUniforms = uniforms
        previewUniforms.viewProjectionMatrix = matrix_identity_float4x4

        for pane in panes {
            let vertices = makePlanarMPRPreviewVertices(for: pane.plane, viewport: pane.viewport)
            guard vertices.isEmpty == false else {
                continue
            }

            encoder.setViewport(pane.viewport)
            encoder.setScissorRect(pane.scissor)
            encoder.setRenderPipelineState(mprPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            vertices.withUnsafeBytes { vertexBytes in
                guard let vertexBaseAddress = vertexBytes.baseAddress else {
                    return
                }
                encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
                encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 0)
                encoder.setFragmentTexture(baseVolumeTexture, index: 0)
                encoder.setFragmentTexture(overlayVolumeTexture, index: 1)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }

            let borderVertices = makePlanarMPRPreviewBorderVertices(for: pane.plane, viewport: pane.viewport)
            guard borderVertices.isEmpty == false else {
                continue
            }
            encoder.setRenderPipelineState(mprBorderPipelineState)
            encoder.setDepthStencilState(mprDepthStencilState)
            borderVertices.withUnsafeBytes { vertexBytes in
                guard let vertexBaseAddress = vertexBytes.baseAddress else {
                    return
                }
                encoder.setVertexBytes(vertexBaseAddress, length: vertexBytes.count, index: 0)
                encoder.setVertexBytes(&previewUniforms, length: MemoryLayout<MetalMPRUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: borderVertices.count)
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
        vertices.reserveCapacity(24)

        switch hoveredMPRPlane {
        case .axial:
            appendMPRHighlightBorder(
                to: &vertices,
                minU: 0,
                maxU: maxX,
                minV: 0,
                maxV: maxY,
                uInset: mprVoxelInset(forAxis: 0),
                vInset: mprVoxelInset(forAxis: 1)
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
                uInset: mprVoxelInset(forAxis: 0),
                vInset: mprVoxelInset(forAxis: 2)
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
                uInset: mprVoxelInset(forAxis: 1),
                vInset: mprVoxelInset(forAxis: 2)
            ) { u, v in
                self.mprPlaneVoxel(for: .sagittal, first: u, second: v)
            }
        }

        return vertices
    }

    private func makeMPRBorderVertices() -> [MetalMPRVertex] {
        var vertices: [MetalMPRVertex] = []
        vertices.reserveCapacity(24)
        appendMPRPlaneBorder(to: &vertices, corners: mprPlaneCorners(for: .axial))
        appendMPRPlaneBorder(to: &vertices, corners: mprPlaneCorners(for: .coronal))
        appendMPRPlaneBorder(to: &vertices, corners: mprPlaneCorners(for: .sagittal))

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

    private func makePlanarMPRPreviewVertices(for plane: MetalMPRPlane, viewport: MTLViewport) -> [MetalMPRVertex] {
        let corners = mprPlaneCorners(for: plane)
        guard corners.count == 4,
              viewport.width > 1,
              viewport.height > 1 else {
            return []
        }

        let worldCorners = corners.map { mprDisplayWorldPosition(for: $0) }
        let horizontalLength = simd_length(worldCorners[1] - worldCorners[0])
        let verticalLength = simd_length(worldCorners[3] - worldCorners[0])
        let planeAspect = horizontalLength / max(verticalLength, 0.0001)
        let viewportAspect = Float(viewport.width / max(viewport.height, 1))
        let padding: Float = 0.92
        var halfWidth = padding
        var halfHeight = padding
        if planeAspect > viewportAspect {
            halfHeight = padding * viewportAspect / max(planeAspect, 0.0001)
        } else {
            halfWidth = padding * planeAspect / max(viewportAspect, 0.0001)
        }

        let positions: [SIMD3<Float>]
        switch plane {
        case .axial:
            positions = [
                SIMD3<Float>(-halfWidth, halfHeight, 0),
                SIMD3<Float>(halfWidth, halfHeight, 0),
                SIMD3<Float>(halfWidth, -halfHeight, 0),
                SIMD3<Float>(-halfWidth, -halfHeight, 0),
            ]
        case .coronal, .sagittal:
            positions = [
                SIMD3<Float>(-halfWidth, -halfHeight, 0),
                SIMD3<Float>(halfWidth, -halfHeight, 0),
                SIMD3<Float>(halfWidth, halfHeight, 0),
                SIMD3<Float>(-halfWidth, halfHeight, 0),
            ]
        }

        return [
            MetalMPRVertex(position: positions[0], baseVoxel: corners[0]),
            MetalMPRVertex(position: positions[1], baseVoxel: corners[1]),
            MetalMPRVertex(position: positions[2], baseVoxel: corners[2]),
            MetalMPRVertex(position: positions[0], baseVoxel: corners[0]),
            MetalMPRVertex(position: positions[2], baseVoxel: corners[2]),
            MetalMPRVertex(position: positions[3], baseVoxel: corners[3]),
        ]
    }

    private func makePlanarMPRPreviewBorderVertices(for plane: MetalMPRPlane, viewport: MTLViewport) -> [MetalMPRVertex] {
        let filledVertices = makePlanarMPRPreviewVertices(for: plane, viewport: viewport)
        guard filledVertices.count == 6 else { return [] }

        let corners = [
            filledVertices[0],
            filledVertices[1],
            filledVertices[2],
            filledVertices[5],
        ]
        return [
            corners[0], corners[1],
            corners[1], corners[2],
            corners[2], corners[3],
            corners[3], corners[0],
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
        let innerMinU = minU + clampedUInset
        let innerMaxU = maxU - clampedUInset
        let innerMinV = minV + clampedVInset
        let innerMaxV = maxV - clampedVInset

        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(minU, minV), makeVoxel(maxU, minV), makeVoxel(innerMaxU, innerMinV), makeVoxel(innerMinU, innerMinV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(minU, innerMaxV), makeVoxel(innerMaxU, innerMaxV), makeVoxel(maxU, maxV), makeVoxel(minU, maxV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(minU, minV), makeVoxel(innerMinU, minV), makeVoxel(innerMinU, maxV), makeVoxel(minU, maxV),
        ])
        appendMPRQuad(to: &vertices, corners: [
            makeVoxel(innerMaxU, minV), makeVoxel(maxU, minV), makeVoxel(maxU, maxV), makeVoxel(innerMaxU, maxV),
        ])
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
        let column: SIMD3<Float>
        switch axis {
        case 0:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.0.x, fixedVoxelToWorld.columns.0.y, fixedVoxelToWorld.columns.0.z)
        case 1:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.1.x, fixedVoxelToWorld.columns.1.y, fixedVoxelToWorld.columns.1.z)
        default:
            column = SIMD3<Float>(fixedVoxelToWorld.columns.2.x, fixedVoxelToWorld.columns.2.y, fixedVoxelToWorld.columns.2.z)
        }
        return 10.0 / max(simd_length(column), 0.0001)
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

    private func appendMPRPlaneBorder(to vertices: inout [MetalMPRVertex], corners: [SIMD3<Float>]) {
        guard corners.count == 4 else { return }
        let borderVertices = [
            corners[0], corners[1],
            corners[1], corners[2],
            corners[2], corners[3],
            corners[3], corners[0],
        ]
        vertices.append(contentsOf: borderVertices.map {
            MetalMPRVertex(position: mprDisplayPosition(for: $0), baseVoxel: $0)
        })
    }

    private func mprDisplayPosition(for baseVoxel: SIMD3<Float>) -> SIMD3<Float> {
        let world = fixedVoxelToWorld * SIMD4<Float>(baseVoxel, 1)
        let delta = SIMD3<Float>(world.x, world.y, world.z) - baseVolumeCenterWorld
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

        return translationMatrix * depthRangeMatrix * aspectMatrix * scaleMatrix * mprRotationMatrix()
    }

    private func mprArcballVector(for point: CGPoint, in bounds: CGRect) -> SIMD3<Float> {
        let radius = Float(max(min(bounds.width, bounds.height), 1)) * 0.5
        let x = Float(bounds.midX - point.x) / radius
        let y = Float(bounds.midY - point.y) / radius
        let distance = sqrt(x * x + y * y)
        let sphereRadius: Float = 1.0
        let sphereShoulder = sphereRadius * Float(1.0 / sqrt(2.0))

        if distance < sphereShoulder {
            return simd_normalize(SIMD3<Float>(x, y, sqrt(sphereRadius * sphereRadius - distance * distance)))
        }

        return simd_normalize(SIMD3<Float>(x, y, (sphereRadius * sphereRadius * 0.5) / max(distance, 0.0001)))
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
