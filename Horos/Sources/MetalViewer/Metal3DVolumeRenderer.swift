import AppKit
import Foundation
import Metal
import MetalKit
import simd

enum Metal3DCropPlane: CaseIterable {
    case minX
    case maxX
    case minY
    case maxY
    case minZ
    case maxZ

    var axis: Int {
        switch self {
        case .minX, .maxX: return 0
        case .minY, .maxY: return 1
        case .minZ, .maxZ: return 2
        }
    }

    var isMax: Bool {
        switch self {
        case .maxX, .maxY, .maxZ: return true
        default: return false
        }
    }
}

struct Metal3DCropHandleProjection {
    let plane: Metal3DCropPlane
    let position: CGPoint
    let dragAxis: CGVector
    let pixelsPerWorldUnit: CGFloat
    let isOccluded: Bool
}

struct Metal3DCropEdgeProjection {
    let start: CGPoint
    let end: CGPoint
    let isOccluded: Bool
}

struct Metal3DCropWireframeProjection {
    let edges: [Metal3DCropEdgeProjection]
}

struct Metal3DTrajectoryHandleProjection {
    let position: CGPoint
    let hitRadius: CGFloat
}

struct Metal3DSegmentationInput {
    let dimensions: SIMD3<Int>
    let spacing: SIMD3<Float>
    let sourceCropMin: SIMD3<Int>
    let sourceSpacing: SIMD3<Float>
    let referenceVoxelToPatientMatrix: [[Double]]
    let sourceVoxelToVolumeVoxelMatrix: simd_float4x4?
    let float32VolumeData: Data
}

struct Metal3DTumorSegmentationStatistics {
    let surfaceCount: Int
    let voxelVolumeML: Double
    let labelVoxelCounts: [UInt8: Int]

    var labelVolumesML: [UInt8: Double] {
        var volumes = [UInt8: Double]()
        for (label, count) in labelVoxelCounts {
            volumes[label] = Double(count) * voxelVolumeML
        }
        return volumes
    }

    var wholeTumorVolumeML: Double {
        volumeML(for: Set([1, 2, 4]))
    }

    var tumorCoreVolumeML: Double {
        volumeML(for: Set([1, 4]))
    }

    func volumeML(for labels: Set<UInt8>) -> Double {
        labels.reduce(0) { partialResult, label in
            partialResult + Double(labelVoxelCounts[label] ?? 0) * voxelVolumeML
        }
    }
}

private struct Metal3DVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct Metal3DVolumeCropBounds {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    var minZ: Int
    var maxZ: Int

    var dimensions: SIMD3<Int> {
        SIMD3<Int>(
            max(maxX - minX + 1, 1),
            max(maxY - minY + 1, 1),
            max(maxZ - minZ + 1, 1)
        )
    }
}

private struct Metal3DSkinDistanceNode {
    let distance: UInt16
    let index: Int
}

private struct Metal3DSkinDistanceNeighbor {
    let dx: Int
    let dy: Int
    let dz: Int
    let cost: UInt16
}

private struct Metal3DSkinDistanceHeap {
    private var nodes = [Metal3DSkinDistanceNode]()

    mutating func reserveCapacity(_ capacity: Int) {
        nodes.reserveCapacity(capacity)
    }

    mutating func push(_ node: Metal3DSkinDistanceNode) {
        nodes.append(node)
        siftUp(from: nodes.count - 1)
    }

    mutating func pop() -> Metal3DSkinDistanceNode? {
        guard nodes.isEmpty == false else { return nil }
        if nodes.count == 1 {
            return nodes.removeLast()
        }

        let result = nodes[0]
        nodes[0] = nodes.removeLast()
        siftDown(from: 0)
        return result
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard nodes[child].distance < nodes[parent].distance else { break }
            nodes.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent

            if left < nodes.count, nodes[left].distance < nodes[candidate].distance {
                candidate = left
            }
            if right < nodes.count, nodes[right].distance < nodes[candidate].distance {
                candidate = right
            }
            guard candidate != parent else { break }
            nodes.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

private struct Metal3DVolumeUniforms {
    var cameraPosition: SIMD3<Float>
    var tanHalfFovY: Float
    var cameraRight: SIMD3<Float>
    var aspectRatio: Float
    var cameraUp: SIMD3<Float>
    var stepSize: Float
    var cameraForward: SIMD3<Float>
    var density: Float
    var alphaFloor: Float
    var boxMin: SIMD3<Float>
    var padding0: Float = 0
    var boxMax: SIMD3<Float>
    var padding1: Float = 0
    var cropBoxMin: SIMD3<Float>
    var padding2: Float = 0
    var cropBoxMax: SIMD3<Float>
    var padding3: Float = 0
    var volumeDimensions: SIMD3<UInt32>
    var cropEnabled: UInt32
    var voxelSpacing: SIMD3<Float>
    var maxSteps: UInt32
    var windowLevel: Float
    var windowWidth: Float
    var boneRenderingOptions: SIMD4<Float>
    var opacityDomainMin: Float
    var opacityDomainMax: Float
    var useRawOpacityCurve: UInt32
    var usePreIntegratedTransfer: UInt32
    var shading: Float
    var ambient: Float
    var diffuse: Float
    var specular: Float
    var specularPower: Float
    var hasCLUT: UInt32
    var skinMaskEnabled: UInt32
    var viewProjectionMatrix: simd_float4x4
}

private struct Metal3DOverlayVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct Metal3DOverlayUniforms {
    var viewProjectionMatrix: simd_float4x4
    var color: SIMD4<Float>
}

private struct Metal3DTumorSurface {
    let label: UInt8
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
}

private struct Metal3DSurgicalTrajectory {
    let tumorCenter: SIMD3<Float>
    let skinPoint: SIMD3<Float>
    let distalEnd: SIMD3<Float>
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let projectedOutlineVertexBuffer: MTLBuffer?
    let projectedOutlineVertexCount: Int
}

private enum Metal3DDefaults {
    static let maxDynamicValue: Float = 32000
    static let noCLUT = NSLocalizedString("No CLUT", comment: "")
    static let linearOpacity = NSLocalizedString("Linear Table", comment: "")
    static let defaultWLWW = NSLocalizedString("Default WL & WW", comment: "")
    static let fullDynamic = NSLocalizedString("Full dynamic", comment: "")
    static let otherWLWW = NSLocalizedString("Other", comment: "")
    static let vrBonesCLUT = NSLocalizedString("VR Muscles-Bones", comment: "")
    static let vrOpacity = NSLocalizedString("Logarithmic Inverse Table", comment: "")
}

final class Metal3DVolumeRenderer: NSObject, MTKViewDelegate {
    private let deviceRef: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let overlayPipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let maskSamplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer
    private let depthStencilState: MTLDepthStencilState
    private let pixList: [DCMPix]
    private let cropHandleColor = SIMD4<Float>(0.16, 0.98, 0.32, 1.0)
    private let cropHandleHighlightColor = SIMD4<Float>(1.0, 0.18, 0.82, 1.0)
    private let fullSourceDimensions: SIMD3<Int>
    private let sourceCropBounds: Metal3DVolumeCropBounds
    private let sourceDimensions: SIMD3<Int>
    private let sourceVoxelSpacing: SIMD3<Float>
    private let volumeDimensions: SIMD3<Int>
    private let voxelSpacing: SIMD3<Float>
    private let referenceVoxelToPatientMatrix: simd_float4x4
    private let patientRowDirection: SIMD3<Float>
    private let patientColumnDirection: SIMD3<Float>
    private let patientSliceDirection: SIMD3<Float>
    private let boxMin: SIMD3<Float>
    private let boxMax: SIMD3<Float>
    private let gantryTiltCorrection: MetalViewerGantryTiltGeometry?
    private var cropBoxMin = SIMD3<Float>(repeating: -0.28)
    private var cropBoxMax = SIMD3<Float>(repeating: 0.28)
    private let superSampling: Float
    private let valueFactor: Float
    private let offset16: Float
    private let transferTextureWidth = 4096
    private let preIntegratedTransferTextureWidth = 256
    private let preIntegratedTransferSamples = 8
    private let shadingAmbient: Float = 0.15
    private let shadingDiffuse: Float = 0.9
    private let shadingSpecular: Float = 0.3
    private let shadingSpecularPower: Float = 15.0
    private let boneLowerHU: Float = 160.0
    private let boneUpperHU: Float = 2200.0
    private let boneSurfaceHU: Float = 300.0
    private let cropHandleRadius: Float = 0.016
    private let histogramDomainMin: Float = -1200.0
    private let histogramDomainMax: Float = 3200.0
    private static let skinClipDepthPreferenceKey = "Metal3DSkinShellThicknessMM"

    private var volumeTexture: MTLTexture?
    private var clutTexture: MTLTexture?
    private var opacityTexture: MTLTexture?
    private var preIntegratedTransferTexture: MTLTexture?
    private var skinMaskTexture: MTLTexture?
    private var skinSurfaceVertexBuffer: MTLBuffer?
    private var skinSurfaceVertexCount = 0
    private var skinSurfaceVertexFloatData: Data?
    private var skinSurfaceWorldPoints = [SIMD3<Float>]()
    private var tumourSeedSphereVertexBuffer: MTLBuffer?
    private var tumourSeedSphereVertexCount = 0
    private var tumourSeeds = [MetalViewerTumourSeed]()
    private var tumorSurfaces = [Metal3DTumorSurface]()
    private var tumorCentroidWorldPosition: SIMD3<Float>?
    private var enhancingTumorSurfaceWorldPoints = [SIMD3<Float>]()
    private var surgicalTrajectory: Metal3DSurgicalTrajectory?
    private var trajectoryHandleHovered = false
    private var suppressProjectedTrajectoryOutline = false
    private lazy var emptySkinMaskTexture: MTLTexture? = makeEmptySkinMaskTexture()
    private var drawableSize = CGSize(width: 1, height: 1)
    private var rawVolume = [Float]()
    private var customOpacityControlPoints = [SIMD2<Float>]()

    private(set) var selectedWLPresetName = Metal3DDefaults.defaultWLWW
    private(set) var selectedCLUTName = Metal3DDefaults.noCLUT
    private(set) var selectedOpacityName = Metal3DDefaults.linearOpacity
    private(set) var isGantryTiltCorrected = false
    private(set) var cropEnabled = false
    private(set) var cropOverlayVisible = false
    private var hoveredCropPlane: Metal3DCropPlane?
    private var activeCropPlane: Metal3DCropPlane?
    private(set) var shadingEnabled = UserDefaults.standard.bool(forKey: "defaultShading")

    private var windowLevel: Float = 0
    private var windowWidth: Float = 1
    private var currentCLUTPixels = [SIMD4<UInt8>]()
    private var currentOpacityPoints = [String]()
    private var cameraRotation: simd_quatf
    private var orbitRadius: Float
    private var orthographicZoomScale: Float = 1.0
    private var preIntegrationEnabled = false
    private var showSkin = true
    private var showSkinSurface = false
    private var showTumorSegmentation = true
    private var tumorLabelFilter: Set<UInt8>?
    private(set) var currentSkinClipDepthMM: Float = 6.0
    private var skinMaskExtractionAttempted = false
    private var skinSurfaceExtractionAttempted = false

    init(device: MTLDevice, pixList: [DCMPix], volumeData: Data) {
        self.deviceRef = device
        self.pixList = pixList
        self.currentSkinClipDepthMM = Self.initialSkinClipDepthMM(for: pixList)

        guard let firstPix = pixList.first else {
            fatalError("3D Metal viewer requires at least one DCMPix slice.")
        }

        firstPix.checkLoad()
        firstPix.computePixMinPixMax()

        let width = max(Int(firstPix.pwidth), 1)
        let height = max(Int(firstPix.pheight), 1)
        let depth = max(pixList.count, 1)
        let fullSourceDimensions = SIMD3<Int>(width, height, depth)
        self.fullSourceDimensions = fullSourceDimensions

        let sourceSpacing = Self.voxelSpacing(for: pixList)
        if let sliceGeometry = MetalViewerSliceGeometry(pix: firstPix) {
            self.patientRowDirection = simd_normalize(SIMD3<Float>(Float(sliceGeometry.row.x), Float(sliceGeometry.row.y), Float(sliceGeometry.row.z)))
            self.patientColumnDirection = simd_normalize(SIMD3<Float>(Float(sliceGeometry.column.x), Float(sliceGeometry.column.y), Float(sliceGeometry.column.z)))
            self.patientSliceDirection = simd_normalize(SIMD3<Float>(Float(sliceGeometry.normal.x), Float(sliceGeometry.normal.y), Float(sliceGeometry.normal.z)))
        } else {
            self.patientRowDirection = SIMD3<Float>(1, 0, 0)
            self.patientColumnDirection = SIMD3<Float>(0, 1, 0)
            self.patientSliceDirection = SIMD3<Float>(0, 0, 1)
        }
        let cropBounds = Self.volumeCropBounds(for: pixList, dimensions: fullSourceDimensions, spacing: sourceSpacing)
        self.sourceCropBounds = cropBounds
        let gantryTiltGeometry = MetalViewerGantryTiltGeometryBuilder.geometry(
            for: pixList,
            sourceDimensions: fullSourceDimensions,
            sourceBounds: MetalViewerVolumeBounds(
                minimum: SIMD3<Int>(cropBounds.minX, cropBounds.minY, cropBounds.minZ),
                maximum: SIMD3<Int>(cropBounds.maxX, cropBounds.maxY, cropBounds.maxZ)
            ),
            fallbackSliceSpacing: sourceSpacing.z
        )
        let gantryTiltCorrection = Self.isCTVolume(pixList) && gantryTiltGeometry.requiresCorrection()
            ? gantryTiltGeometry
            : nil
        self.gantryTiltCorrection = gantryTiltCorrection
        self.isGantryTiltCorrected = gantryTiltCorrection != nil
        let sourceDimensions = gantryTiltCorrection?.dimensions ?? cropBounds.dimensions
        self.sourceDimensions = sourceDimensions
        let correctedSourceSpacing = gantryTiltCorrection?.correctedSpacing ?? sourceSpacing
        self.sourceVoxelSpacing = correctedSourceSpacing
        let textureGeometry = Self.isotropicTextureGeometry(sourceDimensions: sourceDimensions, sourceSpacing: correctedSourceSpacing)
        self.volumeDimensions = textureGeometry.dimensions
        self.voxelSpacing = textureGeometry.spacing
        let sourceVoxelToPatientMatrix = gantryTiltCorrection?.correctedVoxelToPatientMatrix
            ?? MetalViewerGantryTiltGeometryBuilder.sourceVoxelToPatientMatrix(for: pixList, fallbackSliceSpacing: correctedSourceSpacing.z)
        let referenceCropBounds = gantryTiltCorrection == nil
            ? cropBounds
            : Metal3DVolumeCropBounds(
                minX: 0,
                maxX: max(sourceDimensions.x - 1, 0),
                minY: 0,
                maxY: max(sourceDimensions.y - 1, 0),
                minZ: 0,
                maxZ: max(sourceDimensions.z - 1, 0)
            )
        self.referenceVoxelToPatientMatrix = Self.referenceVoxelToPatientMatrix(
            sourceVoxelToPatientMatrix: sourceVoxelToPatientMatrix,
            cropBounds: referenceCropBounds,
            outputSpacing: textureGeometry.spacing
        )
        let extent = Self.volumeExtent(dimensions: self.volumeDimensions, spacing: self.voxelSpacing)
        self.boxMin = -extent * 0.5
        self.boxMax = extent * 0.5
        let yaw = simd_quatf(angle: Float(35.0 * .pi / 180.0), axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: Float(22.0 * .pi / 180.0), axis: SIMD3<Float>(1, 0, 0))
        self.cameraRotation = simd_normalize(yaw * pitch)
        self.orbitRadius = max(simd_length(self.boxMax - self.boxMin) * 1.8, 1.8)
        self.superSampling = max(UserDefaults.standard.float(forKey: "superSampling"), 1.0)
        let scalarMapping = Self.scalarMapping(for: pixList)
        self.valueFactor = scalarMapping.valueFactor
        self.offset16 = scalarMapping.offset16
        _ = volumeData

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Could not create a Metal command queue for the 3D viewer.")
        }
        self.commandQueue = commandQueue

        let vertices: [Metal3DVertex] = [
            Metal3DVertex(position: [-1, -1], uv: [0, 0]),
            Metal3DVertex(position: [1, -1], uv: [1, 0]),
            Metal3DVertex(position: [-1, 1], uv: [0, 1]),
            Metal3DVertex(position: [1, 1], uv: [1, 1]),
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Metal3DVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            fatalError("Could not create a vertex buffer for the 3D viewer.")
        }
        self.vertexBuffer = vertexBuffer

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "metal3DVolumeVertex"),
              let fragmentFunction = library.makeFunction(name: "metal3DVolumeFragment"),
              let overlayVertexFunction = library.makeFunction(name: "metal3DOverlayVertexMain"),
              let overlayFragmentFunction = library.makeFunction(name: "metal3DOverlayFragment") else {
            fatalError("Could not load Metal 3D volume shader functions.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create the 3D Metal pipeline: \(error)")
        }

        let overlayPipelineDescriptor = MTLRenderPipelineDescriptor()
        overlayPipelineDescriptor.vertexFunction = overlayVertexFunction
        overlayPipelineDescriptor.fragmentFunction = overlayFragmentFunction
        overlayPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        overlayPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        overlayPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        overlayPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        overlayPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        overlayPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        overlayPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlayPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            overlayPipelineState = try device.makeRenderPipelineState(descriptor: overlayPipelineDescriptor)
        } catch {
            fatalError("Could not create the 3D Metal overlay pipeline: \(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Could not create the 3D viewer sampler state.")
        }
        self.samplerState = samplerState

        let maskSamplerDescriptor = MTLSamplerDescriptor()
        maskSamplerDescriptor.minFilter = .nearest
        maskSamplerDescriptor.magFilter = .nearest
        maskSamplerDescriptor.mipFilter = .notMipmapped
        maskSamplerDescriptor.sAddressMode = .clampToEdge
        maskSamplerDescriptor.tAddressMode = .clampToEdge
        maskSamplerDescriptor.rAddressMode = .clampToEdge
        guard let maskSamplerState = device.makeSamplerState(descriptor: maskSamplerDescriptor) else {
            fatalError("Could not create the 3D viewer mask sampler state.")
        }
        self.maskSamplerState = maskSamplerState

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.isDepthWriteEnabled = true
        depthStateDescriptor.depthCompareFunction = .lessEqual
        guard let depthStencilState = device.makeDepthStencilState(descriptor: depthStateDescriptor) else {
            fatalError("Could not create 3D viewer depth stencil state.")
        }
        self.depthStencilState = depthStencilState

        super.init()

        self.rawVolume = makeRawVolume()

        volumeTexture = makeVolumeTexture()
        applyWLPreset(named: Metal3DDefaults.defaultWLWW)
        applyCLUT(named: defaultCLUTName())
        applyOpacity(named: defaultOpacityName())
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func orientationOverlayState(in contentRect: CGRect, cubeTopInset: CGFloat = 12) -> MetalOrientationOverlayState? {
        let camera = currentCameraState(for: drawableSize)
        return MetalOrientationOverlayState(
            screenRightPatientVector: patientVector(forVolumeVector: camera.right),
            screenUpPatientVector: patientVector(forVolumeVector: camera.up),
            screenForwardPatientVector: patientVector(forVolumeVector: camera.forward),
            contentRect: contentRect,
            cubeTopInset: cubeTopInset
        )
    }

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let volumeTexture,
              let clutTexture,
              let opacityTexture else {
            return
        }

        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let camera = currentCameraState(for: view.drawableSize)
        var uniforms = makeUniforms(for: view.drawableSize, camera: camera)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Metal3DVolumeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(clutTexture, index: 1)
        encoder.setFragmentTexture(opacityTexture, index: 2)
        encoder.setFragmentTexture(preIntegratedTransferTexture ?? clutTexture, index: 3)
        encoder.setFragmentTexture(skinMaskTexture ?? emptySkinMaskTexture, index: 4)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentSamplerState(maskSamplerState, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if showSkinSurface {
            drawSkinSurfaceOverlay(with: encoder, camera: camera)
        }

        drawTumorSurfaceOverlays(with: encoder, camera: camera)
        drawTumourSeedSpheres(with: encoder, camera: camera)
        drawSurgicalTrajectoryOverlay(with: encoder, camera: camera)

        if cropOverlayVisible {
            drawCropOverlay(with: encoder, camera: camera)
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func patientVector(forVolumeVector vector: SIMD3<Float>) -> SIMD3<Float> {
        let patientVector = patientRowDirection * vector.x
            + patientColumnDirection * vector.y
            + patientSliceDirection * vector.z
        guard simd_length_squared(patientVector) > 0.000001 else {
            return vector
        }
        return simd_normalize(patientVector)
    }

    func applyWLPreset(named presetName: String) {
        let name = sanitizeWLPresetName(presetName)
        selectedWLPresetName = name

        guard let firstPix = pixList.first else { return }
        switch name {
        case Metal3DDefaults.defaultWLWW:
            let savedWW = firstPix.savedWW > 0 ? firstPix.savedWW : firstPix.fullww
            let savedWL = firstPix.savedWW > 0 ? firstPix.savedWL : firstPix.fullwl
            windowLevel = savedWL
            windowWidth = max(savedWW, 1)

        case Metal3DDefaults.fullDynamic:
            windowLevel = firstPix.fullwl
            windowWidth = max(firstPix.fullww, 1)

        case Metal3DDefaults.otherWLWW:
            break

        default:
            let dictionary = UserDefaults.standard.dictionary(forKey: "WLWW3") ?? [:]
            if let values = dictionary[name] as? [NSNumber], values.count >= 2 {
                windowLevel = values[0].floatValue
                windowWidth = max(values[1].floatValue, 1)
            }
        }

        rebuildTransferTextures()
    }

    func adjustWindowLevelWidth(deltaX: Float, deltaY: Float) {
        let widthScale = max(windowWidth * 0.005, 0.5)
        let levelScale = max(windowWidth * 0.0025, 0.25)

        windowWidth = max(windowWidth + deltaX * widthScale, 1)
        windowLevel += deltaY * levelScale
        selectedWLPresetName = Metal3DDefaults.otherWLWW
        rebuildTransferTextures()
    }

    func applyCLUT(named presetName: String) {
        let dictionary = UserDefaults.standard.dictionary(forKey: "CLUT") ?? [:]
        let fallbackName = Metal3DDefaults.noCLUT
        let name = dictionary[presetName] != nil ? presetName : fallbackName
        selectedCLUTName = name

        if name == Metal3DDefaults.noCLUT {
            currentCLUTPixels = Self.grayscalePixels()
            rebuildTransferTextures()
            return
        }

        guard let clut = dictionary[name] as? [String: Any],
              let redValues = clut["Red"] as? [NSNumber],
              let greenValues = clut["Green"] as? [NSNumber],
              let blueValues = clut["Blue"] as? [NSNumber],
              redValues.count >= 256,
              greenValues.count >= 256,
              blueValues.count >= 256 else {
            currentCLUTPixels = Self.grayscalePixels()
            rebuildTransferTextures()
            selectedCLUTName = fallbackName
            return
        }

        var pixels = [SIMD4<UInt8>](repeating: SIMD4<UInt8>(0, 0, 0, 255), count: 256)
        for index in 0..<256 {
            pixels[index] = SIMD4<UInt8>(
                UInt8(clamping: redValues[index].intValue),
                UInt8(clamping: greenValues[index].intValue),
                UInt8(clamping: blueValues[index].intValue),
                255
            )
        }
        currentCLUTPixels = pixels
        rebuildTransferTextures()
    }

    func applyOpacity(named presetName: String) {
        let dictionary = UserDefaults.standard.dictionary(forKey: "OPACITY") ?? [:]
        let fallbackName = Metal3DDefaults.linearOpacity
        let name = presetName == fallbackName || dictionary[presetName] != nil ? presetName : fallbackName
        selectedOpacityName = name

        if name == Metal3DDefaults.linearOpacity {
            currentOpacityPoints = []
            rebuildTransferTextures()
            return
        }

        guard let opacityPreset = dictionary[name] as? [String: Any],
              let points = opacityPreset["Points"] as? [Any] else {
            currentOpacityPoints = []
            rebuildTransferTextures()
            selectedOpacityName = fallbackName
            return
        }

        currentOpacityPoints = points.compactMap { $0 as? String }
        rebuildTransferTextures()
    }

    func setCropEnabled(_ enabled: Bool) {
        cropEnabled = enabled
    }

    func setCropOverlayVisible(_ visible: Bool) {
        cropOverlayVisible = visible
    }

    func setHoveredCropPlane(_ plane: Metal3DCropPlane?) {
        hoveredCropPlane = plane
    }

    func setActiveCropPlane(_ plane: Metal3DCropPlane?) {
        activeCropPlane = plane
    }

    func cropHandleProjections(in bounds: CGRect) -> [Metal3DCropHandleProjection] {
        let camera = currentCameraState(for: bounds.size)
        let cropCenter = 0.5 * (cropBoxMin + cropBoxMax)
        let faceCenters: [(Metal3DCropPlane, SIMD3<Float>, SIMD3<Float>)] = [
            (.minX, SIMD3<Float>(cropBoxMin.x, cropCenter.y, cropCenter.z), SIMD3<Float>(1, 0, 0)),
            (.maxX, SIMD3<Float>(cropBoxMax.x, cropCenter.y, cropCenter.z), SIMD3<Float>(1, 0, 0)),
            (.minY, SIMD3<Float>(cropCenter.x, cropBoxMin.y, cropCenter.z), SIMD3<Float>(0, 1, 0)),
            (.maxY, SIMD3<Float>(cropCenter.x, cropBoxMax.y, cropCenter.z), SIMD3<Float>(0, 1, 0)),
            (.minZ, SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMin.z), SIMD3<Float>(0, 0, 1)),
            (.maxZ, SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMax.z), SIMD3<Float>(0, 0, 1)),
        ]

        let worldDelta = max(simd_length(boxMax - boxMin) * 0.05, 0.01)
        var projections = [Metal3DCropHandleProjection]()

        for (plane, center, normal) in faceCenters {
            guard let position = project(point: center, camera: camera, in: bounds) else { continue }
            let offsetPoint = center + normal * worldDelta
            guard let offsetPosition = project(point: offsetPoint, camera: camera, in: bounds) else { continue }
            let dragAxis = CGVector(dx: offsetPosition.x - position.x, dy: offsetPosition.y - position.y)
            let axisLength = hypot(dragAxis.dx, dragAxis.dy)
            guard axisLength > 0.5 else { continue }
            let pixelsPerWorldUnit = axisLength / CGFloat(worldDelta)
            let handleWorldRadius = Float(9.0 / max(pixelsPerWorldUnit, 0.001))

            projections.append(
                Metal3DCropHandleProjection(
                    plane: plane,
                    position: position,
                    dragAxis: dragAxis,
                    pixelsPerWorldUnit: pixelsPerWorldUnit,
                    isOccluded: isOccludedByVolume(point: center, camera: camera, allowance: handleWorldRadius * 1.1)
                )
            )
        }

        return projections
    }

    func cropWireframeProjection(in bounds: CGRect) -> Metal3DCropWireframeProjection? {
        let camera = currentCameraState(for: bounds.size)
        let corners3D: [SIMD3<Float>] = [
            SIMD3<Float>(cropBoxMin.x, cropBoxMin.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMin.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMax.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMax.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMin.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMin.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMax.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMax.y, cropBoxMax.z),
        ]

        var corners2D = [CGPoint]()
        corners2D.reserveCapacity(corners3D.count)
        for corner in corners3D {
            guard let projected = project(point: corner, camera: camera, in: bounds) else {
                return nil
            }
            corners2D.append(projected)
        }
        let edgeIndices: [(Int, Int)] = [
            (0, 1), (1, 3), (3, 2), (2, 0),
            (4, 5), (5, 7), (7, 6), (6, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        var edges = [Metal3DCropEdgeProjection]()
        let segmentCount = 10
        for (startIndex, endIndex) in edgeIndices {
            let start3D = corners3D[startIndex]
            let end3D = corners3D[endIndex]
            let start2D = corners2D[startIndex]
            let end2D = corners2D[endIndex]

            for segmentIndex in 0..<segmentCount {
                let t0 = Float(segmentIndex) / Float(segmentCount)
                let t1 = Float(segmentIndex + 1) / Float(segmentCount)
                let midT = 0.5 * (t0 + t1)
                let midPoint3D = start3D + (end3D - start3D) * midT
                let segmentStart2D = CGPoint(
                    x: start2D.x + CGFloat(t0) * (end2D.x - start2D.x),
                    y: start2D.y + CGFloat(t0) * (end2D.y - start2D.y)
                )
                let segmentEnd2D = CGPoint(
                    x: start2D.x + CGFloat(t1) * (end2D.x - start2D.x),
                    y: start2D.y + CGFloat(t1) * (end2D.y - start2D.y)
                )
                edges.append(
                    Metal3DCropEdgeProjection(
                        start: segmentStart2D,
                        end: segmentEnd2D,
                        isOccluded: isOccludedByVolume(point: midPoint3D, camera: camera, allowance: 0.002)
                    )
                )
            }
        }
        return Metal3DCropWireframeProjection(edges: edges)
    }

    func trajectoryHandleProjection(in bounds: CGRect) -> Metal3DTrajectoryHandleProjection? {
        guard let surgicalTrajectory else { return nil }

        let camera = currentCameraState(for: bounds.size)
        guard let position = project(point: surgicalTrajectory.distalEnd, camera: camera, in: bounds) else {
            return nil
        }

        let radiusWorld = 7.5 / volumePhysicalScale()
        let radiusPoint = surgicalTrajectory.distalEnd + camera.right * radiusWorld
        let projectedRadius: CGFloat
        if let radiusPosition = project(point: radiusPoint, camera: camera, in: bounds) {
            projectedRadius = hypot(radiusPosition.x - position.x, radiusPosition.y - position.y)
        } else {
            projectedRadius = 10
        }

        return Metal3DTrajectoryHandleProjection(
            position: position,
            hitRadius: max(projectedRadius, 12)
        )
    }

    func setTrajectoryHandleHovered(_ isHovered: Bool) {
        guard trajectoryHandleHovered != isHovered else { return }
        trajectoryHandleHovered = isHovered
        rebuildSurgicalTrajectoryForCurrentHandleState()
    }

    func dragTrajectoryHandle(screenDelta: CGVector, in bounds: CGRect) {
        guard let surgicalTrajectory else { return }

        suppressProjectedTrajectoryOutline = true
        let camera = currentCameraState(for: bounds.size)
        let worldUnitsPerPixel = (2.0 * camera.tanHalfFovY) / max(Float(bounds.height), 1)
        let worldDelta = camera.right * Float(screenDelta.dx) * worldUnitsPerPixel
            + camera.up * Float(screenDelta.dy) * worldUnitsPerPixel
        let newEnd = surgicalTrajectory.distalEnd + worldDelta
        setSurgicalTrajectoryDistalEnd(newEnd)
    }

    func finishTrajectoryHandleDrag() {
        guard suppressProjectedTrajectoryOutline else { return }
        suppressProjectedTrajectoryOutline = false
        rebuildSurgicalTrajectoryForCurrentHandleState()
    }

    func setCropPlane(_ plane: Metal3DCropPlane, value: Float) {
        let minimumGap: Float = 0.03
        switch plane {
        case .minX:
            cropBoxMin.x = min(max(value, boxMin.x), cropBoxMax.x - minimumGap)
        case .maxX:
            cropBoxMax.x = max(min(value, boxMax.x), cropBoxMin.x + minimumGap)
        case .minY:
            cropBoxMin.y = min(max(value, boxMin.y), cropBoxMax.y - minimumGap)
        case .maxY:
            cropBoxMax.y = max(min(value, boxMax.y), cropBoxMin.y + minimumGap)
        case .minZ:
            cropBoxMin.z = min(max(value, boxMin.z), cropBoxMax.z - minimumGap)
        case .maxZ:
            cropBoxMax.z = max(min(value, boxMax.z), cropBoxMin.z + minimumGap)
        }
    }

    func cropPlaneValue(_ plane: Metal3DCropPlane) -> Float {
        switch plane {
        case .minX: return cropBoxMin.x
        case .maxX: return cropBoxMax.x
        case .minY: return cropBoxMin.y
        case .maxY: return cropBoxMax.y
        case .minZ: return cropBoxMin.z
        case .maxZ: return cropBoxMax.z
        }
    }

    func rotateTrackball(from previousLocation: CGPoint, to currentLocation: CGPoint, in bounds: CGRect) {
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        let dx = Float(currentLocation.x - previousLocation.x)
        let dy = Float(currentLocation.y - previousLocation.y)

        let motionFactor: Float = 10.0
        let azimuthDegrees = dx * (-20.0 / width) * motionFactor
        let elevationDegrees = dy * (-20.0 / height) * motionFactor
        let azimuthRadians = azimuthDegrees * (.pi / 180.0)
        let elevationRadians = elevationDegrees * (.pi / 180.0)

        let currentUp = simd_normalize(simd_act(cameraRotation, SIMD3<Float>(0, 1, 0)))
        let currentForward = simd_normalize(simd_act(cameraRotation, SIMD3<Float>(0, 0, 1)))
        var currentRight = simd_cross(currentForward, currentUp)
        if simd_length_squared(currentRight) < 1e-6 {
            currentRight = SIMD3<Float>(1, 0, 0)
        } else {
            currentRight = simd_normalize(currentRight)
        }

        let azimuthRotation = simd_quatf(angle: azimuthRadians, axis: currentUp)
        let elevatedRight = simd_normalize(simd_act(azimuthRotation, currentRight))
        let elevationRotation = simd_quatf(angle: elevationRadians, axis: elevatedRight)
        cameraRotation = simd_normalize(elevationRotation * azimuthRotation * cameraRotation)
    }

    func zoom(delta: Float) {
        let zoomScale = exp(delta * 0.0015)
        orthographicZoomScale = min(max(orthographicZoomScale * zoomScale, 0.25), 16.0)
    }

    private func sanitizeWLPresetName(_ name: String) -> String {
        if name.hasPrefix("- ") {
            return String(name.dropFirst(2))
        }
        if name.hasPrefix("-    ") {
            return String(name.dropFirst(5))
        }
        return name
    }

    private func defaultCLUTName() -> String {
        let dictionary = UserDefaults.standard.dictionary(forKey: "CLUT") ?? [:]
        if pixList.first?.isRGB == false, dictionary[Metal3DDefaults.vrBonesCLUT] != nil {
            return Metal3DDefaults.vrBonesCLUT
        }
        return Metal3DDefaults.noCLUT
    }

    private func defaultOpacityName() -> String {
        let dictionary = UserDefaults.standard.dictionary(forKey: "OPACITY") ?? [:]
        if pixList.first?.isRGB == false, dictionary[Metal3DDefaults.vrOpacity] != nil {
            return Metal3DDefaults.vrOpacity
        }
        return Metal3DDefaults.linearOpacity
    }

    private func rebuildTransferTextures() {
        if currentCLUTPixels.isEmpty {
            currentCLUTPixels = Self.grayscalePixels()
        }
        clutTexture = makeColorTransferTexture()
        opacityTexture = makeOpacityTransferTexture()
        preIntegratedTransferTexture = preIntegrationEnabled ? makePreIntegratedTransferTexture() : nil
    }

    private func makeUniforms(for drawableSize: CGSize, camera: CameraState) -> Metal3DVolumeUniforms {

        let stepSize = rayMarchStepSize()
        let density: Float = 1.0
        let alphaFloor: Float = 0.0
        let rayLength = simd_length((cropEnabled ? cropBoxMax - cropBoxMin : boxMax - boxMin))
        let maxSteps = UInt32(min(max(Int(ceil(rayLength / max(stepSize, 0.0001))) + 8, 256), 8192))

        return Metal3DVolumeUniforms(
            cameraPosition: camera.position,
            tanHalfFovY: camera.tanHalfFovY,
            cameraRight: camera.right,
            aspectRatio: camera.aspectRatio,
            cameraUp: camera.up,
            stepSize: stepSize,
            cameraForward: camera.forward,
            density: density,
            alphaFloor: alphaFloor,
            boxMin: boxMin,
            boxMax: boxMax,
            cropBoxMin: cropBoxMin,
            cropBoxMax: cropBoxMax,
            volumeDimensions: SIMD3<UInt32>(
                UInt32(max(volumeDimensions.x, 1)),
                UInt32(max(volumeDimensions.y, 1)),
                UInt32(max(volumeDimensions.z, 1))
            ),
            cropEnabled: cropEnabled ? 1 : 0,
            voxelSpacing: voxelSpacing,
            maxSteps: maxSteps,
            windowLevel: windowLevel,
            windowWidth: windowWidth,
            boneRenderingOptions: .zero,
            opacityDomainMin: histogramDomainMin,
            opacityDomainMax: histogramDomainMax,
            useRawOpacityCurve: customOpacityControlPoints.isEmpty ? 0 : 1,
            usePreIntegratedTransfer: preIntegrationEnabled ? 1 : 0,
            shading: shadingEnabled ? 1.0 : 0.0,
            ambient: shadingAmbient,
            diffuse: shadingDiffuse,
            specular: shadingSpecular,
            specularPower: shadingSpecularPower,
            hasCLUT: clutTexture == nil ? 0 : 1,
            skinMaskEnabled: (showSkin == false && skinMaskTexture != nil) ? 1 : 0,
            viewProjectionMatrix: camera.viewProjectionMatrix
        )
    }

    private struct CameraState {
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let tanHalfFovY: Float
        let aspectRatio: Float
        let viewProjectionMatrix: simd_float4x4
    }

    private func currentCameraState(for drawableSize: CGSize) -> CameraState {
        let width = max(Float(drawableSize.width), 1)
        let height = max(Float(drawableSize.height), 1)
        let aspectRatio = width / height
        let cameraDirection = simd_act(cameraRotation, SIMD3<Float>(0, 0, 1))
        let target = SIMD3<Float>(repeating: 0)
        let cameraPosition = target + cameraDirection * orbitRadius
        let cameraForward = simd_normalize(target - cameraPosition)
        let rotatedUp = simd_act(cameraRotation, SIMD3<Float>(0, 1, 0))
        let cameraRight = simd_normalize(simd_cross(cameraForward, rotatedUp))
        let cameraUp = simd_normalize(simd_cross(cameraRight, cameraForward))
        let baseHalfViewHeight = max(simd_length(boxMax - boxMin) * 0.55, 0.55)
        let halfViewHeight = baseHalfViewHeight / max(orthographicZoomScale, 0.001)
        let nearPlane: Float = 0.01
        let farPlane: Float = 20.0
        let viewMatrix = Self.lookAtMatrix(eye: cameraPosition, center: target, up: cameraUp)
        let projectionMatrix = Self.orthographicMatrix(
            halfHeight: halfViewHeight,
            aspectRatio: aspectRatio,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
        return CameraState(
            position: cameraPosition,
            forward: cameraForward,
            right: cameraRight,
            up: cameraUp,
            tanHalfFovY: halfViewHeight,
            aspectRatio: aspectRatio,
            viewProjectionMatrix: projectionMatrix * viewMatrix
        )
    }

    private func drawCropOverlay(with encoder: MTLRenderCommandEncoder, camera: CameraState) {
        var overlayUniforms = Metal3DOverlayUniforms(
            viewProjectionMatrix: camera.viewProjectionMatrix,
            color: SIMD4<Float>(0.15, 1.0, 0.25, 1.0)
        )

        encoder.setRenderPipelineState(overlayPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)

        let edgeVertices = makeCropEdgeVertices()
        if edgeVertices.isEmpty == false {
            let edgeLength = MemoryLayout<Metal3DOverlayVertex>.stride * edgeVertices.count
            if let edgeBuffer = deviceRef.makeBuffer(bytes: edgeVertices, length: edgeLength, options: .storageModeShared) {
                encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeVertices.count)
            }
        }

        let sphereVertices = makeCropHandleSphereVertices()
        if sphereVertices.isEmpty == false {
            let sphereLength = MemoryLayout<Metal3DOverlayVertex>.stride * sphereVertices.count
            if let sphereBuffer = deviceRef.makeBuffer(bytes: sphereVertices, length: sphereLength, options: .storageModeShared) {
                encoder.setVertexBuffer(sphereBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sphereVertices.count)
            }
        }
    }

    private func drawSkinSurfaceOverlay(with encoder: MTLRenderCommandEncoder, camera: CameraState) {
        ensureSkinMaskTexture(includeSurface: true)
        guard let skinSurfaceVertexBuffer, skinSurfaceVertexCount > 0 else { return }

        var overlayUniforms = Metal3DOverlayUniforms(
            viewProjectionMatrix: camera.viewProjectionMatrix,
            color: SIMD4<Float>(1.0, 0.02, 0.01, 1.0)
        )

        encoder.setRenderPipelineState(overlayPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(skinSurfaceVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: skinSurfaceVertexCount)
    }

    private func drawTumorSurfaceOverlays(with encoder: MTLRenderCommandEncoder, camera: CameraState) {
        guard showTumorSegmentation, tumorSurfaces.isEmpty == false else { return }

        encoder.setRenderPipelineState(overlayPipelineState)
        encoder.setDepthStencilState(depthStencilState)

        for surface in tumorSurfaces {
            if let tumorLabelFilter, tumorLabelFilter.contains(surface.label) == false {
                continue
            }
            var overlayUniforms = Metal3DOverlayUniforms(
                viewProjectionMatrix: camera.viewProjectionMatrix,
                color: tumorColor(for: surface.label)
            )
            encoder.setVertexBuffer(surface.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: surface.vertexCount)
        }
    }

    private func drawTumourSeedSpheres(with encoder: MTLRenderCommandEncoder, camera: CameraState) {
        guard let tumourSeedSphereVertexBuffer, tumourSeedSphereVertexCount > 0 else {
            return
        }

        var overlayUniforms = Metal3DOverlayUniforms(
            viewProjectionMatrix: camera.viewProjectionMatrix,
            color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0)
        )

        encoder.setRenderPipelineState(overlayPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(tumourSeedSphereVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: tumourSeedSphereVertexCount)
    }

    private func drawSurgicalTrajectoryOverlay(with encoder: MTLRenderCommandEncoder, camera: CameraState) {
        guard let surgicalTrajectory else { return }

        var overlayUniforms = Metal3DOverlayUniforms(
            viewProjectionMatrix: camera.viewProjectionMatrix,
            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        )

        encoder.setRenderPipelineState(overlayPipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(surgicalTrajectory.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<Metal3DOverlayUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: surgicalTrajectory.vertexCount)

        if showSkinSurface,
           let projectedOutlineVertexBuffer = surgicalTrajectory.projectedOutlineVertexBuffer,
           surgicalTrajectory.projectedOutlineVertexCount > 0 {
            encoder.setVertexBuffer(projectedOutlineVertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: surgicalTrajectory.projectedOutlineVertexCount
            )
        }
    }

    private func makeCropEdgeVertices() -> [Metal3DOverlayVertex] {
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(cropBoxMin.x, cropBoxMin.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMin.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMax.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMax.y, cropBoxMin.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMin.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMin.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMin.x, cropBoxMax.y, cropBoxMax.z),
            SIMD3<Float>(cropBoxMax.x, cropBoxMax.y, cropBoxMax.z),
        ]
        let indices: [(Int, Int)] = [
            (0, 1), (1, 3), (3, 2), (2, 0),
            (4, 5), (5, 7), (7, 6), (6, 4),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]
        var vertices = [Metal3DOverlayVertex]()
        vertices.reserveCapacity(indices.count * 2)
        for (start, end) in indices {
            vertices.append(Metal3DOverlayVertex(position: corners[start], normal: .zero, color: cropHandleColor))
            vertices.append(Metal3DOverlayVertex(position: corners[end], normal: .zero, color: cropHandleColor))
        }
        return vertices
    }

    private func makeCropHandleSphereVertices() -> [Metal3DOverlayVertex] {
        let cropCenter = 0.5 * (cropBoxMin + cropBoxMax)
        let centers: [(Metal3DCropPlane, SIMD3<Float>)] = [
            (.minX, SIMD3<Float>(cropBoxMin.x, cropCenter.y, cropCenter.z)),
            (.maxX, SIMD3<Float>(cropBoxMax.x, cropCenter.y, cropCenter.z)),
            (.minY, SIMD3<Float>(cropCenter.x, cropBoxMin.y, cropCenter.z)),
            (.maxY, SIMD3<Float>(cropCenter.x, cropBoxMax.y, cropCenter.z)),
            (.minZ, SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMin.z)),
            (.maxZ, SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMax.z)),
        ]
        let latitudes = 16
        let longitudes = 24
        var vertices = [Metal3DOverlayVertex]()
        for (plane, center) in centers {
            let isHighlighted = plane == activeCropPlane || plane == hoveredCropPlane
            let color = isHighlighted ? cropHandleHighlightColor : cropHandleColor
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

                    let p00 = center + cropHandleRadius * Self.spherePoint(theta: theta0, phi: phi0)
                    let p01 = center + cropHandleRadius * Self.spherePoint(theta: theta0, phi: phi1)
                    let p10 = center + cropHandleRadius * Self.spherePoint(theta: theta1, phi: phi0)
                    let p11 = center + cropHandleRadius * Self.spherePoint(theta: theta1, phi: phi1)
                    let n00 = Self.spherePoint(theta: theta0, phi: phi0)
                    let n01 = Self.spherePoint(theta: theta0, phi: phi1)
                    let n10 = Self.spherePoint(theta: theta1, phi: phi0)
                    let n11 = Self.spherePoint(theta: theta1, phi: phi1)

                    vertices.append(Metal3DOverlayVertex(position: p00, normal: n00, color: color))
                    vertices.append(Metal3DOverlayVertex(position: p10, normal: n10, color: color))
                    vertices.append(Metal3DOverlayVertex(position: p11, normal: n11, color: color))
                    vertices.append(Metal3DOverlayVertex(position: p00, normal: n00, color: color))
                    vertices.append(Metal3DOverlayVertex(position: p11, normal: n11, color: color))
                    vertices.append(Metal3DOverlayVertex(position: p01, normal: n01, color: color))
                }
            }
        }
        return vertices
    }

    private static func spherePoint(theta: Float, phi: Float) -> SIMD3<Float> {
        SIMD3<Float>(
            sin(theta) * cos(phi),
            cos(theta),
            sin(theta) * sin(phi)
        )
    }

    private static func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)

        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    private static func orthographicMatrix(halfHeight: Float, aspectRatio: Float, nearPlane: Float, farPlane: Float) -> simd_float4x4 {
        let halfWidth = max(halfHeight * aspectRatio, 0.0001)
        let yScale = 1.0 / max(halfHeight, 0.0001)
        let xScale = 1.0 / halfWidth
        let zScale = 1.0 / (nearPlane - farPlane)
        let wzScale = nearPlane / (nearPlane - farPlane)
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, 0),
            SIMD4<Float>(0, 0, wzScale, 1)
        ))
    }

    private func isOccludedByVolume(point _: SIMD3<Float>, camera _: CameraState, allowance _: Float) -> Bool {
        return false
    }

    private func project(point: SIMD3<Float>, camera: CameraState, in bounds: CGRect) -> CGPoint? {
        let relative = point - camera.position
        let depth = simd_dot(relative, camera.forward)
        guard depth > 0.0001 else { return nil }

        let x = simd_dot(relative, camera.right) / (camera.aspectRatio * camera.tanHalfFovY)
        let y = simd_dot(relative, camera.up) / camera.tanHalfFovY

        let screenX = bounds.minX + CGFloat((x * 0.5 + 0.5)) * bounds.width
        let screenY = bounds.minY + CGFloat((y * 0.5 + 0.5)) * bounds.height
        return CGPoint(x: screenX, y: screenY)
    }

    func setShadingEnabled(_ enabled: Bool) {
        shadingEnabled = enabled
    }

    func setPreIntegrationEnabled(_ enabled: Bool) {
        guard preIntegrationEnabled != enabled else { return }
        preIntegrationEnabled = enabled
        preIntegratedTransferTexture = enabled ? makePreIntegratedTransferTexture() : nil
    }

    func setShowSkin(_ showSkin: Bool) {
        self.showSkin = showSkin
        if showSkin == false {
            ensureSkinMaskTexture()
        }
    }

    func setShowSkinSurface(_ showSkinSurface: Bool) {
        self.showSkinSurface = showSkinSurface
        if showSkinSurface {
            ensureSkinMaskTexture(includeSurface: true)
        }
    }

    func setSkinClipDepthMM(_ depthMM: Float) {
        let clampedDepth = min(max(depthMM, 0), 20)
        guard abs(currentSkinClipDepthMM - clampedDepth) > 0.01 else { return }

        currentSkinClipDepthMM = clampedDepth
        UserDefaults.standard.set(clampedDepth, forKey: Self.skinClipDepthPreferenceKey)
        skinMaskTexture = nil
        skinSurfaceVertexBuffer = nil
        skinSurfaceVertexCount = 0
        skinSurfaceVertexFloatData = nil
        skinSurfaceWorldPoints = []
        surgicalTrajectory = nil
        trajectoryHandleHovered = false
        suppressProjectedTrajectoryOutline = false
        skinMaskExtractionAttempted = false
        skinSurfaceExtractionAttempted = false

        if showSkin == false || showSkinSurface {
            ensureSkinMaskTexture(includeSurface: showSkinSurface)
        }
    }

    func setShowTumorSegmentation(_ showTumorSegmentation: Bool) {
        self.showTumorSegmentation = showTumorSegmentation
    }

    func setTumorLabelFilter(_ labels: Set<UInt8>?) {
        tumorLabelFilter = labels?.isEmpty == true ? nil : labels
    }

    func setTumourSeeds(_ seeds: [MetalViewerTumourSeed]) {
        tumourSeeds = seeds
        rebuildTumourSeedSphereVertexBuffer()
    }

    func segmentationInput() -> Metal3DSegmentationInput {
        let data = rawVolume.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return Metal3DSegmentationInput(
            dimensions: volumeDimensions,
            spacing: voxelSpacing,
            sourceCropMin: SIMD3<Int>(sourceCropBounds.minX, sourceCropBounds.minY, sourceCropBounds.minZ),
            sourceSpacing: sourceVoxelSpacing,
            referenceVoxelToPatientMatrix: Self.matrixRows(referenceVoxelToPatientMatrix),
            sourceVoxelToVolumeVoxelMatrix: sourceVoxelToVolumeVoxelMatrix(),
            float32VolumeData: data
        )
    }

    private func sourceVoxelToVolumeVoxelMatrix() -> simd_float4x4? {
        guard let gantryTiltCorrection else { return nil }

        let correctedPatientToVoxelMatrix = simd_inverse(gantryTiltCorrection.correctedVoxelToPatientMatrix)
        let correctedToVolumeScale = simd_float4x4(
            SIMD4<Float>(sourceVoxelSpacing.x / max(voxelSpacing.x, 0.0001), 0, 0, 0),
            SIMD4<Float>(0, sourceVoxelSpacing.y / max(voxelSpacing.y, 0.0001), 0, 0),
            SIMD4<Float>(0, 0, sourceVoxelSpacing.z / max(voxelSpacing.z, 0.0001), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        return correctedToVolumeScale * correctedPatientToVoxelMatrix * gantryTiltCorrection.sourceVoxelToPatientMatrix
    }

    @discardableResult
    func setTumorSegmentationLabelmap(_ labelmap: Data) -> Metal3DTumorSegmentationStatistics {
        let expectedVoxelCount = max(volumeDimensions.x * volumeDimensions.y * volumeDimensions.z, 0)
        guard expectedVoxelCount > 0, labelmap.count == expectedVoxelCount else {
            NSLog(
                "Metal3DVolumeRenderer tumour segmentation labelmap size mismatch %ld != %ld",
                labelmap.count,
                expectedVoxelCount
            )
            tumorSurfaces = []
            tumorCentroidWorldPosition = nil
            enhancingTumorSurfaceWorldPoints = []
            surgicalTrajectory = nil
            trajectoryHandleHovered = false
            suppressProjectedTrajectoryOutline = false
            return Metal3DTumorSegmentationStatistics(
                surfaceCount: 0,
                voxelVolumeML: voxelVolumeML(),
                labelVoxelCounts: [:]
            )
        }

        let labels = Set(labelmap).filter { $0 != 0 }.sorted()
        var labelVoxelCounts = [UInt8: Int]()
        for label in labelmap where label != 0 {
            labelVoxelCounts[label, default: 0] += 1
        }
        let enhancingTumorLabel: UInt8?
        if labels.contains(4) {
            enhancingTumorLabel = 4
        } else if labels.contains(3) {
            enhancingTumorLabel = 3
        } else {
            enhancingTumorLabel = nil
        }
        tumorCentroidWorldPosition = Self.enhancingTumorCentroidWorldPosition(
            labelmap: labelmap,
            dimensions: volumeDimensions,
            spacing: voxelSpacing
        ) { physicalPosition in
            worldPosition(forPhysicalPosition: physicalPosition)
        }
        enhancingTumorSurfaceWorldPoints = []
        surgicalTrajectory = nil
        trajectoryHandleHovered = false
        suppressProjectedTrajectoryOutline = false

        var surfaces = [Metal3DTumorSurface]()
        surfaces.reserveCapacity(labels.count)

        for label in labels {
            let sourceVolume = labelmap.map { value -> Float in
                value == label ? 1.0 : 0.0
            }
            let volumeData = sourceVolume.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
            guard let extractedSurface = Metal3DSurfaceExtractor.extractSkinSurface(
                fromVolume: volumeData,
                width: volumeDimensions.x,
                height: volumeDimensions.y,
                depth: volumeDimensions.z,
                spacingX: voxelSpacing.x,
                spacingY: voxelSpacing.y,
                spacingZ: voxelSpacing.z,
                threshold: 0.5
            ),
            let surfaceVertexBuffer = makeOverlaySurfaceVertexBuffer(
                vertexFloatData: extractedSurface.vertexFloatData,
                color: tumorColor(for: label)
            ) else {
                NSLog("Metal3DVolumeRenderer tumour segmentation skipped empty label %d", Int(label))
                continue
            }

            if label == enhancingTumorLabel,
               let surfaceCentroid = centroidWorldPosition(fromSurfaceVertexFloatData: extractedSurface.vertexFloatData) {
                let surfacePoints = worldPositions(fromSurfaceVertexFloatData: extractedSurface.vertexFloatData)
                enhancingTumorSurfaceWorldPoints = surfacePoints
                tumorCentroidWorldPosition = surfaceCentroid
            }

            surfaces.append(
                Metal3DTumorSurface(
                    label: label,
                    vertexBuffer: surfaceVertexBuffer.buffer,
                    vertexCount: surfaceVertexBuffer.count
                )
            )
        }

        tumorSurfaces = surfaces
        showTumorSegmentation = true
        tumorLabelFilter = nil
        if MetalViewerDiagnostics.isTimingLogEnabled {
            NSLog(
                "HOROS_METAL_TIMING Metal3DVolumeRenderer tumourSegmentation labels=%@ surfaces=%ld volume=%ldx%ldx%ld",
                labels.map { String($0) }.joined(separator: ",") as NSString,
                surfaces.count,
                volumeDimensions.x,
                volumeDimensions.y,
                volumeDimensions.z
            )
        }
        return Metal3DTumorSegmentationStatistics(
            surfaceCount: surfaces.count,
            voxelVolumeML: voxelVolumeML(),
            labelVoxelCounts: labelVoxelCounts
        )
    }

    func clearTumorSegmentation() {
        tumorSurfaces = []
        tumorLabelFilter = nil
        tumorCentroidWorldPosition = nil
        enhancingTumorSurfaceWorldPoints = []
        surgicalTrajectory = nil
        trajectoryHandleHovered = false
        suppressProjectedTrajectoryOutline = false
    }

    func showInitialSurgicalTrajectory() -> String? {
        guard let tumorCentroidWorldPosition else {
            return NSLocalizedString("No enhancing tumour label is available for trajectory planning.", comment: "")
        }

        ensureSkinMaskTexture(includeSurface: true, includeSurfacePoints: true)
        guard skinSurfaceWorldPoints.isEmpty == false else {
            return NSLocalizedString("The outer skin surface is not available yet.", comment: "")
        }

        guard let skinPoint = nearestSkinPoint(to: tumorCentroidWorldPosition) else {
            return NSLocalizedString("Could not find a skin-surface point for the trajectory.", comment: "")
        }

        guard let trajectory = makeSurgicalTrajectory(from: tumorCentroidWorldPosition, to: skinPoint) else {
            return NSLocalizedString("Could not create the surgical trajectory overlay.", comment: "")
        }

        surgicalTrajectory = trajectory
        trajectoryHandleHovered = false
        suppressProjectedTrajectoryOutline = false
        if MetalViewerDiagnostics.isTimingLogEnabled {
            NSLog(
                "HOROS_METAL_TIMING Metal3DVolumeRenderer surgicalTrajectory center=(%.4f,%.4f,%.4f) skin=(%.4f,%.4f,%.4f) length=%.4f",
                Double(tumorCentroidWorldPosition.x),
                Double(tumorCentroidWorldPosition.y),
                Double(tumorCentroidWorldPosition.z),
                Double(skinPoint.x),
                Double(skinPoint.y),
                Double(skinPoint.z),
                Double(simd_length(skinPoint - tumorCentroidWorldPosition))
            )
        }
        return nil
    }

    private func rebuildSurgicalTrajectoryForCurrentHandleState() {
        guard let surgicalTrajectory,
              let updatedTrajectory = makeSurgicalTrajectory(
                from: surgicalTrajectory.tumorCenter,
                toSkinPoint: surgicalTrajectory.skinPoint,
                distalEnd: surgicalTrajectory.distalEnd
              ) else {
            return
        }
        self.surgicalTrajectory = updatedTrajectory
    }

    private func setSurgicalTrajectoryDistalEnd(_ distalEnd: SIMD3<Float>) {
        guard let surgicalTrajectory,
              simd_length_squared(distalEnd - surgicalTrajectory.tumorCenter) > 0.000001,
              let updatedTrajectory = makeSurgicalTrajectory(
                from: surgicalTrajectory.tumorCenter,
                toSkinPoint: surgicalTrajectory.skinPoint,
                distalEnd: distalEnd
              ) else {
            return
        }
        self.surgicalTrajectory = updatedTrajectory
    }

    private static func enhancingTumorCentroidWorldPosition(
        labelmap: Data,
        dimensions: SIMD3<Int>,
        spacing: SIMD3<Float>,
        worldPosition: (SIMD3<Float>) -> SIMD3<Float>
    ) -> SIMD3<Float>? {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let expectedVoxelCount = width * height * depth
        guard labelmap.count == expectedVoxelCount else { return nil }

        let labels = Set(labelmap)
        let targetLabel: UInt8
        if labels.contains(4) {
            targetLabel = 4
        } else if labels.contains(3) {
            targetLabel = 3
        } else {
            return nil
        }

        let sliceElementCount = width * height
        var count = 0
        var sum = SIMD3<Double>(repeating: 0)

        labelmap.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<expectedVoxelCount where baseAddress[index] == targetLabel {
                let z = index / sliceElementCount
                let remainder = index - z * sliceElementCount
                let y = remainder / width
                let x = remainder - y * width
                sum += SIMD3<Double>(Double(x), Double(y), Double(z))
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let centroidVoxel = SIMD3<Float>(
            Float(sum.x / Double(count)),
            Float(sum.y / Double(count)),
            Float(sum.z / Double(count))
        )
        return worldPosition(
            SIMD3<Float>(
                centroidVoxel.x * spacing.x,
                centroidVoxel.y * spacing.y,
                centroidVoxel.z * spacing.z
            )
        )
    }

    private func nearestSkinPoint(to point: SIMD3<Float>) -> SIMD3<Float>? {
        if skinSurfaceWorldPoints.count >= 3 {
            var bestPoint: SIMD3<Float>?
            var bestDistanceSquared = Float.greatestFiniteMagnitude
            var index = 0
            while index + 2 < skinSurfaceWorldPoints.count {
                let candidate = Self.closestPoint(
                    to: point,
                    onTriangleA: skinSurfaceWorldPoints[index],
                    b: skinSurfaceWorldPoints[index + 1],
                    c: skinSurfaceWorldPoints[index + 2]
                )
                let distanceSquared = simd_length_squared(candidate - point)
                if distanceSquared < bestDistanceSquared {
                    bestDistanceSquared = distanceSquared
                    bestPoint = candidate
                }
                index += 3
            }
            if let bestPoint {
                return bestPoint
            }
        }

        var bestPoint: SIMD3<Float>?
        var bestDistanceSquared = Float.greatestFiniteMagnitude
        for candidate in skinSurfaceWorldPoints {
            let distanceSquared = simd_length_squared(candidate - point)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = candidate
            }
        }
        return bestPoint
    }

    private static func closestPoint(
        to point: SIMD3<Float>,
        onTriangleA a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>
    ) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 {
            return a
        }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 {
            return b
        }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return a + v * ab
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 {
            return c
        }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return a + w * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + w * (c - b)
        }

        let denominator = 1.0 / (va + vb + vc)
        let v = vb * denominator
        let w = vc * denominator
        return a + ab * v + ac * w
    }

    private func makeSurgicalTrajectory(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Metal3DSurgicalTrajectory? {
        let vector = end - start
        let length = simd_length(vector)
        guard length > 0.001 else { return nil }

        let direction = vector / length
        let protrusionWorldLength = 50.0 / volumePhysicalScale()
        let protrudingEnd = end + direction * protrusionWorldLength
        return makeSurgicalTrajectory(from: start, toSkinPoint: end, distalEnd: protrudingEnd)
    }

    private func makeSurgicalTrajectory(
        from start: SIMD3<Float>,
        toSkinPoint skinPoint: SIMD3<Float>,
        distalEnd: SIMD3<Float>
    ) -> Metal3DSurgicalTrajectory? {
        var vertices = makeCylinderVertices(
            from: start,
            to: distalEnd,
            radiusMM: 2.5,
            color: SIMD4<Float>(0.0, 0.98, 1.0, 0.96)
        )
        vertices += makeSphereVertices(
            center: distalEnd,
            radiusMM: 7.5,
            color: trajectoryHandleHovered
                ? SIMD4<Float>(1.0, 0.0, 0.95, 0.98)
                : SIMD4<Float>(0.0, 0.9, 0.18, 0.98)
        )
        guard vertices.isEmpty == false else { return nil }

        let projectedOutlineVertices = suppressProjectedTrajectoryOutline
            ? []
            : makeProjectedTumorOutlineVertices(
                tumorCenter: start,
                skinPoint: skinPoint,
                distalEnd: distalEnd
            )
        let projectedOutlineVertexBuffer: MTLBuffer?
        if projectedOutlineVertices.isEmpty {
            projectedOutlineVertexBuffer = nil
        } else {
            projectedOutlineVertexBuffer = deviceRef.makeBuffer(
                bytes: projectedOutlineVertices,
                length: MemoryLayout<Metal3DOverlayVertex>.stride * projectedOutlineVertices.count,
                options: .storageModeShared
            )
        }

        let bufferLength = MemoryLayout<Metal3DOverlayVertex>.stride * vertices.count
        guard let buffer = deviceRef.makeBuffer(bytes: vertices, length: bufferLength, options: .storageModeShared) else {
            return nil
        }
        return Metal3DSurgicalTrajectory(
            tumorCenter: start,
            skinPoint: skinPoint,
            distalEnd: distalEnd,
            vertexBuffer: buffer,
            vertexCount: vertices.count,
            projectedOutlineVertexBuffer: projectedOutlineVertexBuffer,
            projectedOutlineVertexCount: projectedOutlineVertexBuffer == nil ? 0 : projectedOutlineVertices.count
        )
    }

    private func makeProjectedTumorOutlineVertices(
        tumorCenter: SIMD3<Float>,
        skinPoint: SIMD3<Float>,
        distalEnd: SIMD3<Float>
    ) -> [Metal3DOverlayVertex] {
        let vector = distalEnd - tumorCenter
        let length = simd_length(vector)
        guard length > 0.001, enhancingTumorSurfaceWorldPoints.count >= 3 else {
            return []
        }

        let direction = vector / length
        let entryPoint = trajectorySkinEntryPoint(from: tumorCenter, direction: direction) ?? skinPoint
        let basis = orthonormalBasis(for: direction)
        var projectedPoints = [SIMD2<Float>]()
        projectedPoints.reserveCapacity(enhancingTumorSurfaceWorldPoints.count)

        for point in enhancingTumorSurfaceWorldPoints {
            let relative = point - entryPoint
            projectedPoints.append(SIMD2<Float>(simd_dot(relative, basis.right), simd_dot(relative, basis.up)))
        }

        let hull = convexHull(projectedPoints)
        guard hull.count >= 3 else { return [] }

        let color = SIMD4<Float>(1.0, 0.0, 0.95, 0.98)
        let surfaceOffset = direction * (0.8 / volumePhysicalScale())
        var worldPoints = [SIMD3<Float>]()
        worldPoints.reserveCapacity(hull.count * 8)

        for index in 0..<hull.count {
            let start = hull[index]
            let end = hull[(index + 1) % hull.count]
            let edgeLengthMM = simd_length(end - start) * volumePhysicalScale()
            let sampleCount = max(Int(ceil(edgeLengthMM / 3.0)), 1)

            for sampleIndex in 0..<sampleCount {
                let t = Float(sampleIndex) / Float(sampleCount)
                let point = start + (end - start) * t
                if let skinPoint = projectedSkinPoint(
                    forOutlinePoint: point,
                    tumorCenter: tumorCenter,
                    entryPoint: entryPoint,
                    direction: direction,
                    basis: basis
                ) {
                    worldPoints.append(skinPoint + surfaceOffset)
                }
            }
        }

        guard worldPoints.count >= 3 else { return [] }

        var vertices = [Metal3DOverlayVertex]()
        vertices.reserveCapacity(worldPoints.count * 28 * 12)
        for index in 0..<worldPoints.count {
            let start = worldPoints[index]
            let end = worldPoints[(index + 1) % worldPoints.count]
            vertices += makeCylinderVertices(from: start, to: end, radiusMM: 1.5, color: color)
        }
        return vertices
    }

    private func projectedSkinPoint(
        forOutlinePoint point: SIMD2<Float>,
        tumorCenter: SIMD3<Float>,
        entryPoint: SIMD3<Float>,
        direction: SIMD3<Float>,
        basis: (right: SIMD3<Float>, up: SIMD3<Float>)
    ) -> SIMD3<Float>? {
        let lateralPoint = entryPoint + basis.right * point.x + basis.up * point.y
        let entryDistance = max(simd_dot(entryPoint - tumorCenter, direction), 0.01)
        let rayOrigin = lateralPoint - direction * (entryDistance + 0.02)
        return trajectorySkinEntryPoint(from: rayOrigin, direction: direction)
    }

    private func trajectorySkinEntryPoint(from origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard skinSurfaceWorldPoints.count >= 3 else { return nil }

        var bestDistance = Float.greatestFiniteMagnitude
        var bestPoint: SIMD3<Float>?
        var index = 0
        while index + 2 < skinSurfaceWorldPoints.count {
            if let distance = Self.rayTriangleIntersectionDistance(
                origin: origin,
                direction: direction,
                a: skinSurfaceWorldPoints[index],
                b: skinSurfaceWorldPoints[index + 1],
                c: skinSurfaceWorldPoints[index + 2]
            ),
            distance > 0,
            distance < bestDistance {
                bestDistance = distance
                bestPoint = origin + direction * distance
            }
            index += 3
        }
        return bestPoint
    }

    private static func rayTriangleIntersectionDistance(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>
    ) -> Float? {
        let epsilon: Float = 0.000001
        let edge1 = b - a
        let edge2 = c - a
        let h = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard abs(determinant) > epsilon else { return nil }

        let inverseDeterminant = 1.0 / determinant
        let s = origin - a
        let u = inverseDeterminant * simd_dot(s, h)
        guard u >= 0, u <= 1 else { return nil }

        let q = simd_cross(s, edge1)
        let v = inverseDeterminant * simd_dot(direction, q)
        guard v >= 0, u + v <= 1 else { return nil }

        let distance = inverseDeterminant * simd_dot(edge2, q)
        return distance > epsilon ? distance : nil
    }

    private func orthonormalBasis(for direction: SIMD3<Float>) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let reference = abs(direction.z) < 0.85 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(reference, direction))
        let up = simd_normalize(simd_cross(direction, right))
        return (right, up)
    }

    private func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let epsilon: Float = 0.000001
        let sorted = points.sorted {
            if abs($0.x - $1.x) > epsilon {
                return $0.x < $1.x
            }
            return $0.y < $1.y
        }

        var unique = [SIMD2<Float>]()
        unique.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = unique.last, simd_length_squared(point - last) < epsilon * epsilon {
                continue
            }
            unique.append(point)
        }

        guard unique.count > 2 else { return unique }

        func cross(_ origin: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let oa = a - origin
            let ob = b - origin
            return oa.x * ob.y - oa.y * ob.x
        }

        var lower = [SIMD2<Float>]()
        for point in unique {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= epsilon {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper = [SIMD2<Float>]()
        for point in unique.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= epsilon {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private func makeCylinderVertices(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radiusMM: Float,
        color: SIMD4<Float>
    ) -> [Metal3DOverlayVertex] {
        let vector = end - start
        let length = simd_length(vector)
        guard length > 0.001 else { return [] }

        let direction = vector / length
        let shaftRadius = max(radiusMM, 0.1) / volumePhysicalScale()

        let basis = orthonormalBasis(for: direction)
        let segments = 28
        var vertices = [Metal3DOverlayVertex]()
        vertices.reserveCapacity(segments * 12)

        for segment in 0..<segments {
            let a0 = Float(segment) * 2.0 * Float.pi / Float(segments)
            let a1 = Float(segment + 1) * 2.0 * Float.pi / Float(segments)
            let radial0 = cos(a0) * basis.right + sin(a0) * basis.up
            let radial1 = cos(a1) * basis.right + sin(a1) * basis.up

            let s0 = start + radial0 * shaftRadius
            let s1 = start + radial1 * shaftRadius
            let e0 = end + radial0 * shaftRadius
            let e1 = end + radial1 * shaftRadius
            appendTriangle(&vertices, s0, s1, e1, normal: radial0, color: color)
            appendTriangle(&vertices, s0, e1, e0, normal: radial0, color: color)
            appendTriangle(&vertices, start, s0, s1, normal: -direction, color: color)
            appendTriangle(&vertices, end, e1, e0, normal: direction, color: color)
        }

        return vertices
    }

    private func makeSphereVertices(
        center: SIMD3<Float>,
        radiusMM: Float,
        color: SIMD4<Float>
    ) -> [Metal3DOverlayVertex] {
        let radius = max(radiusMM, 0.1) / volumePhysicalScale()
        let latitudes = 16
        let longitudes = 24
        var vertices = [Metal3DOverlayVertex]()
        vertices.reserveCapacity(latitudes * longitudes * 6)

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

                let n00 = Self.spherePoint(theta: theta0, phi: phi0)
                let n01 = Self.spherePoint(theta: theta0, phi: phi1)
                let n10 = Self.spherePoint(theta: theta1, phi: phi0)
                let n11 = Self.spherePoint(theta: theta1, phi: phi1)
                let p00 = center + radius * n00
                let p01 = center + radius * n01
                let p10 = center + radius * n10
                let p11 = center + radius * n11

                vertices.append(Metal3DOverlayVertex(position: p00, normal: n00, color: color))
                vertices.append(Metal3DOverlayVertex(position: p10, normal: n10, color: color))
                vertices.append(Metal3DOverlayVertex(position: p11, normal: n11, color: color))
                vertices.append(Metal3DOverlayVertex(position: p00, normal: n00, color: color))
                vertices.append(Metal3DOverlayVertex(position: p11, normal: n11, color: color))
                vertices.append(Metal3DOverlayVertex(position: p01, normal: n01, color: color))
            }
        }

        return vertices
    }

    private func rebuildTumourSeedSphereVertexBuffer() {
        let vertices = tumourSeeds.flatMap { seed -> [Metal3DOverlayVertex] in
            guard let center = renderWorldPosition(forTumourSeed: seed) else {
                return []
            }
            return makeSphereVertices(
                center: center,
                radiusMM: Float(max(seed.diameterMM * 0.5, 0.05)),
                color: SIMD4<Float>(1.0, 0.0, 0.0, 0.98)
            )
        }

        tumourSeedSphereVertexCount = vertices.count
        guard vertices.isEmpty == false else {
            tumourSeedSphereVertexBuffer = nil
            return
        }

        tumourSeedSphereVertexBuffer = deviceRef.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Metal3DOverlayVertex>.stride * vertices.count,
            options: .storageModeShared
        )
        if tumourSeedSphereVertexBuffer == nil {
            tumourSeedSphereVertexCount = 0
        }
    }

    private func renderWorldPosition(forTumourSeed seed: MetalViewerTumourSeed) -> SIMD3<Float>? {
        let sourceX = Float(seed.pixelX)
        let sourceY = Float(seed.pixelY)
        let sourceZ = Float(seed.sliceIndex)

        if let gantryTiltCorrection {
            guard sourceX >= Float(sourceCropBounds.minX) - 0.5,
                  sourceX <= Float(sourceCropBounds.maxX) + 0.5,
                  sourceY >= Float(sourceCropBounds.minY) - 0.5,
                  sourceY <= Float(sourceCropBounds.maxY) + 0.5,
                  sourceZ >= Float(sourceCropBounds.minZ) - 0.5,
                  sourceZ <= Float(sourceCropBounds.maxZ) + 0.5 else {
                return nil
            }

            let sourceVoxel = SIMD4<Float>(sourceX, sourceY, sourceZ, 1)
            let patientPoint = gantryTiltCorrection.sourceVoxelToPatientMatrix * sourceVoxel
            let correctedVoxel = simd_inverse(gantryTiltCorrection.correctedVoxelToPatientMatrix) * patientPoint
            guard correctedVoxel.x >= -0.5,
                  correctedVoxel.x <= Float(sourceDimensions.x) - 0.5,
                  correctedVoxel.y >= -0.5,
                  correctedVoxel.y <= Float(sourceDimensions.y) - 0.5,
                  correctedVoxel.z >= -0.5,
                  correctedVoxel.z <= Float(sourceDimensions.z) - 0.5 else {
                return nil
            }

            let physicalPosition = SIMD3<Float>(
                correctedVoxel.x * sourceVoxelSpacing.x,
                correctedVoxel.y * sourceVoxelSpacing.y,
                correctedVoxel.z * sourceVoxelSpacing.z
            )
            return worldPosition(forPhysicalPosition: physicalPosition)
        }

        guard sourceX >= Float(sourceCropBounds.minX) - 0.5,
              sourceX <= Float(sourceCropBounds.maxX) + 0.5,
              sourceY >= Float(sourceCropBounds.minY) - 0.5,
              sourceY <= Float(sourceCropBounds.maxY) + 0.5,
              sourceZ >= Float(sourceCropBounds.minZ) - 0.5,
              sourceZ <= Float(sourceCropBounds.maxZ) + 0.5 else {
            return nil
        }

        let croppedX = sourceX - Float(sourceCropBounds.minX)
        let croppedY = sourceY - Float(sourceCropBounds.minY)
        let croppedZ = sourceZ - Float(sourceCropBounds.minZ)
        let physicalPosition = SIMD3<Float>(
            croppedX * sourceVoxelSpacing.x,
            croppedY * sourceVoxelSpacing.y,
            croppedZ * sourceVoxelSpacing.z
        )
        return worldPosition(forPhysicalPosition: physicalPosition)
    }

    private func appendTriangle(
        _ vertices: inout [Metal3DOverlayVertex],
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        normal: SIMD3<Float>,
        color: SIMD4<Float>
    ) {
        vertices.append(Metal3DOverlayVertex(position: a, normal: normal, color: color))
        vertices.append(Metal3DOverlayVertex(position: b, normal: normal, color: color))
        vertices.append(Metal3DOverlayVertex(position: c, normal: normal, color: color))
    }

    private func voxelVolumeML() -> Double {
        Double(voxelSpacing.x) * Double(voxelSpacing.y) * Double(voxelSpacing.z) / 1000.0
    }

    func makeHistogramModel() -> Metal3DHistogramModel? {
        guard rawVolume.isEmpty == false else { return nil }
        return Metal3DHistogramModel(voxels: rawVolume)
    }

    func opacityControlPoints() -> [SIMD2<Float>] {
        if customOpacityControlPoints.isEmpty == false {
            return customOpacityControlPoints
        }
        return defaultOpacityControlPoints()
    }

    func setOpacityControlPoints(_ points: [SIMD2<Float>]) {
        guard points.count >= 2 else { return }
        customOpacityControlPoints = points.sorted { $0.x < $1.x }.map {
            SIMD2<Float>($0.x, min(max($0.y, 0), 1))
        }
        rebuildTransferTextures()
    }

    private func makeVolumeTexture() -> MTLTexture? {
        guard MetalTextureLimits.supports3DTexture(
            width: volumeDimensions.x,
            height: volumeDimensions.y,
            depth: volumeDimensions.z
        ) else {
            return nil
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = max(volumeDimensions.x, 1)
        descriptor.height = max(volumeDimensions.y, 1)
        descriptor.depth = max(volumeDimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let convertedVolume = rawVolume
        let expectedBytes = max(volumeDimensions.x * volumeDimensions.y * volumeDimensions.z, 1) * MemoryLayout<Float>.stride
        convertedVolume.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, max(volumeDimensions.x, 1), max(volumeDimensions.y, 1), max(volumeDimensions.z, 1)),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: max(volumeDimensions.x, 1) * MemoryLayout<Float>.stride,
                bytesPerImage: max(volumeDimensions.x * volumeDimensions.y, 1) * MemoryLayout<Float>.stride
            )
            if bytes.count < expectedBytes {
                NSLog("3D Metal viewer converted volume shorter than expected: %ld < %d", bytes.count, expectedBytes)
            }
        }

        return texture
    }

    private struct SkinShellExtractionResult {
        let mask: [UInt8]
        let threshold: Float
        let method: String
        let shellThicknessMM: Float
        let foregroundVoxelCount: Int
        let filledObjectVoxelCount: Int
        let surfaceVoxelCount: Int
        let outsideVoxelCount: Int
        let shellVoxelCount: Int
        let maskedVoxelCount: Int
        let surfaceVertexFloatData: Data?
        let surfaceVertexBuffer: MTLBuffer?
        let surfaceVertexCount: Int
        let surfacePointCount: Int
        let surfaceTriangleCount: Int
    }

    private func ensureSkinMaskTexture(includeSurface: Bool = false, includeSurfacePoints: Bool = false) {
        let hasSurface = skinSurfaceVertexBuffer != nil &&
            skinSurfaceVertexCount > 0 &&
            skinSurfaceVertexFloatData != nil
        let needsMask = skinMaskTexture == nil && skinMaskExtractionAttempted == false
        let needsSurface = includeSurface && hasSurface == false && skinSurfaceExtractionAttempted == false
        let needsSurfacePoints = includeSurfacePoints && skinSurfaceWorldPoints.isEmpty
        let buildSurface = needsSurface ||
            (needsSurfacePoints && skinSurfaceVertexFloatData == nil && skinSurfaceExtractionAttempted == false)
        guard needsMask || buildSurface || (needsSurfacePoints && skinSurfaceVertexFloatData != nil) else { return }

        if buildSurface == false,
           needsMask == false,
           needsSurfacePoints,
           let vertexFloatData = skinSurfaceVertexFloatData {
            let start = CFAbsoluteTimeGetCurrent()
            skinSurfaceWorldPoints = worldPositions(fromSurfaceVertexFloatData: vertexFloatData)
            if MetalViewerDiagnostics.isTimingLogEnabled {
                NSLog(
                    "HOROS_METAL_TIMING Metal3DVolumeRenderer skinSurfaceWorldPoints points=%ld %.3f s",
                    skinSurfaceWorldPoints.count,
                    CFAbsoluteTimeGetCurrent() - start
                )
            }
            return
        }

        if needsMask {
            skinMaskExtractionAttempted = true
        }
        if buildSurface {
            skinSurfaceExtractionAttempted = true
        }

        let start = CFAbsoluteTimeGetCurrent()
        guard let result = makeSkinShellMask(includeSurface: buildSurface) else {
            if MetalViewerDiagnostics.isTimingLogEnabled {
                NSLog(
                    "HOROS_METAL_TIMING Metal3DVolumeRenderer skinExtraction unavailable %.3f s",
                    CFAbsoluteTimeGetCurrent() - start
                )
            }
            return
        }

        if skinMaskTexture == nil {
            skinMaskTexture = makeSkinMaskTexture(mask: result.mask)
        }
        if buildSurface {
            skinSurfaceVertexBuffer = result.surfaceVertexBuffer
            skinSurfaceVertexCount = result.surfaceVertexCount
            skinSurfaceVertexFloatData = result.surfaceVertexFloatData
        }
        if needsSurfacePoints,
           skinSurfaceWorldPoints.isEmpty,
           let vertexFloatData = skinSurfaceVertexFloatData {
            skinSurfaceWorldPoints = worldPositions(fromSurfaceVertexFloatData: vertexFloatData)
        }
        if MetalViewerDiagnostics.isTimingLogEnabled {
            NSLog(
                "HOROS_METAL_TIMING Metal3DVolumeRenderer skinExtraction method=%@ threshold=%.3f shell=%.1fmm foreground=%ld filled=%ld surfaceVoxels=%ld surfacePoints=%ld surfaceTriangles=%ld surfaceVertices=%ld outside=%ld shell=%ld masked=%ld volume=%ldx%ldx%ld %.3f s",
                result.method as NSString,
                Double(result.threshold),
                Double(result.shellThicknessMM),
                result.foregroundVoxelCount,
                result.filledObjectVoxelCount,
                result.surfaceVoxelCount,
                result.surfacePointCount,
                result.surfaceTriangleCount,
                result.surfaceVertexCount,
                result.outsideVoxelCount,
                result.shellVoxelCount,
                result.maskedVoxelCount,
                volumeDimensions.x,
                volumeDimensions.y,
                volumeDimensions.z,
                CFAbsoluteTimeGetCurrent() - start
            )
        }
    }

    private func makeSkinShellMask(includeSurface: Bool) -> SkinShellExtractionResult? {
        let voxelCount = rawVolume.count
        guard voxelCount > 0 else { return nil }

        let thresholdResult = skinForegroundThreshold()
        var foreground = [UInt8](repeating: 0, count: voxelCount)
        var foregroundVoxelCount = 0
        for index in rawVolume.indices {
            let value = rawVolume[index]
            guard value.isFinite, value >= thresholdResult.threshold else { continue }
            foreground[index] = 1
            foregroundVoxelCount += 1
        }

        let foregroundFraction = Float(foregroundVoxelCount) / Float(max(voxelCount, 1))
        guard foregroundFraction > 0.01, foregroundFraction < 0.98 else {
            NSLog(
                "Metal3DVolumeRenderer skinExtraction rejected foreground fraction %.3f threshold %.3f",
                Double(foregroundFraction),
                Double(thresholdResult.threshold)
            )
            return nil
        }

        let isCT = Self.isCTVolume(pixList)
        let shellThicknessMM = skinShellThicknessMM()
        let envelopeForeground = Self.skinEnvelopeForegroundMask(
            foreground: foreground,
            values: rawVolume,
            rejectHighDensity: isCT
        )
        guard envelopeForeground.count > 0 else {
            NSLog(
                "Metal3DVolumeRenderer skinExtraction found no envelope foreground threshold %.3f",
                Double(thresholdResult.threshold)
            )
            return nil
        }

        let envelopeRadiusMM = Self.skinExternalAirProbeRadiusMM(isCT: isCT)
        var envelope = Self.externalAirReconstructedEnvelopeMask(
            foreground: envelopeForeground.mask,
            dimensions: volumeDimensions,
            spacing: voxelSpacing,
            radiusMM: envelopeRadiusMM
        )
        var envelopeMethod = String(format: "externalAirProbe%.1fmm", Double(envelopeRadiusMM))
        if envelope.count == 0 {
            let fallbackEnvelope = Self.axialClosedEnvelopeMask(
                foreground: envelopeForeground.mask,
                dimensions: volumeDimensions
            )
            envelope = (
                mask: fallbackEnvelope.mask,
                count: fallbackEnvelope.count,
                exteriorAir: Self.invertedMask(fallbackEnvelope.mask)
            )
            envelopeMethod = "axialClosedEnvelopeFallback"
        }
        envelopeMethod += "+openBoundaryAir"
        let envelopeFraction = Float(envelope.count) / Float(max(voxelCount, 1))
        guard envelopeFraction > 0.01, envelopeFraction < 0.995 else {
            NSLog(
                "Metal3DVolumeRenderer skinExtraction rejected envelope fraction %.3f threshold %.3f",
                Double(envelopeFraction),
                Double(thresholdResult.threshold)
            )
            return nil
        }

        let exteriorForegroundSurface = Self.exteriorForegroundSurfaceMask(
            foreground: envelopeForeground.mask,
            exteriorAirMask: envelope.exteriorAir,
            dimensions: volumeDimensions
        )
        let uncappedExteriorSurface = Self.surfaceMaskByOpeningZCropCaps(
            exteriorForegroundSurface,
            dimensions: volumeDimensions
        )
        let exteriorSurface = Self.largestConnectedSurfaceComponentMask(
            uncappedExteriorSurface,
            dimensions: volumeDimensions
        )
        var extractionMethod = "\(thresholdResult.method)+\(envelopeForeground.method)+\(envelopeMethod)+maskOnly"
        var surfaceVoxelCount = exteriorSurface.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        var surfacePointCount = 0
        var surfaceTriangleCount = 0
        var surfaceVertexBuffer: MTLBuffer?
        var surfaceVertexCount = 0
        var surfaceVertexFloatData: Data?

        if includeSurface {
            // Contour the actual image intensities, then let the rotating visibility pass remove
            // internal cut-surface clutter without flattening reachable facial detail.
            let rawVolumeByteCount = rawVolume.count * MemoryLayout<Float>.stride
            let extractedSurfaceResult = rawVolume.withUnsafeBufferPointer { buffer -> Metal3DSurfaceExtractionResult? in
                guard let baseAddress = buffer.baseAddress else { return nil }
                let volumeData = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: UnsafeRawPointer(baseAddress)),
                    count: rawVolumeByteCount,
                    deallocator: .none
                )
                return Metal3DSurfaceExtractor.extractSkinSurface(
                    fromVolume: volumeData,
                    width: volumeDimensions.x,
                    height: volumeDimensions.y,
                    depth: volumeDimensions.z,
                    spacingX: voxelSpacing.x,
                    spacingY: voxelSpacing.y,
                    spacingZ: voxelSpacing.z,
                    threshold: thresholdResult.threshold,
                    openMinimumZCap: true
                )
            }
            guard let extractedSurface = extractedSurfaceResult else {
                NSLog(
                    "Metal3DVolumeRenderer skinExtraction produced no outer surface threshold %.3f",
                    Double(thresholdResult.threshold)
                )
                return nil
            }

            guard extractedSurface.surfaceVoxelMask.count == voxelCount else {
                NSLog(
                    "Metal3DVolumeRenderer skinExtraction surface mask size mismatch %ld != %ld",
                    extractedSurface.surfaceVoxelMask.count,
                    voxelCount
                )
                return nil
            }

            var filteredSurfaceVertexCount = 0
            var filteredSurfaceTriangleCount = 0
            guard let filteredSurfaceData = Metal3DSurfaceExtractor.filterSurfaceVertexFloatData(
                byRotatingVisibility: extractedSurface.vertexFloatData,
                spacingX: voxelSpacing.x,
                spacingY: voxelSpacing.y,
                spacingZ: voxelSpacing.z,
                vertexCount: &filteredSurfaceVertexCount,
                triangleCount: &filteredSurfaceTriangleCount
            ) else {
                NSLog("Metal3DVolumeRenderer skinExtraction Metal visibility filter unavailable")
                return nil
            }

            let overlaySurfaceVertexBuffer = makeSkinSurfaceVertexBuffer(vertexFloatData: filteredSurfaceData)
            surfaceVertexBuffer = overlaySurfaceVertexBuffer?.buffer
            surfaceVertexCount = overlaySurfaceVertexBuffer?.count ?? 0
            surfaceVertexFloatData = filteredSurfaceData
            surfaceVoxelCount = extractedSurface.surfaceVoxelCount
            surfacePointCount = filteredSurfaceVertexCount
            surfaceTriangleCount = filteredSurfaceTriangleCount
            extractionMethod = "\(thresholdResult.method)+rawScalar+\(envelopeForeground.method)+\(envelopeMethod)+\(extractedSurface.extractionMethod)+openZCropCaps+rotatingVisibilityMetal"
        }

        var mask = Self.invertedMask(envelope.mask)
        let outsideCount = max(voxelCount - envelope.count, 0)

        Self.markObjectWithinPhysicalDistance(
            object: envelope.mask,
            surface: exteriorSurface,
            mask: &mask,
            dimensions: volumeDimensions,
            spacing: voxelSpacing,
            maximumDistanceMM: shellThicknessMM
        )

        var maskedVoxelCount = 0
        for value in mask where value != 0 {
            maskedVoxelCount += 1
        }
        let shellVoxelCount = max(maskedVoxelCount - outsideCount, 0)

        return SkinShellExtractionResult(
            mask: mask,
            threshold: thresholdResult.threshold,
            method: extractionMethod,
            shellThicknessMM: shellThicknessMM,
            foregroundVoxelCount: foregroundVoxelCount,
            filledObjectVoxelCount: envelope.count,
            surfaceVoxelCount: surfaceVoxelCount,
            outsideVoxelCount: outsideCount,
            shellVoxelCount: shellVoxelCount,
            maskedVoxelCount: maskedVoxelCount,
            surfaceVertexFloatData: surfaceVertexFloatData,
            surfaceVertexBuffer: surfaceVertexBuffer,
            surfaceVertexCount: surfaceVertexCount,
            surfacePointCount: surfacePointCount,
            surfaceTriangleCount: surfaceTriangleCount
        )
    }

    private static func exteriorForegroundSurfaceMask(
        foreground: [UInt8],
        exteriorAirMask: [UInt8],
        dimensions: SIMD3<Int>
    ) -> [UInt8] {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard foreground.count == voxelCount, exteriorAirMask.count == voxelCount else {
            return [UInt8](repeating: 0, count: foreground.count)
        }

        func hasExteriorAirNear(x: Int, y: Int, z: Int) -> Bool {
            let minimumX = max(x - 1, 0)
            let maximumX = min(x + 1, width - 1)
            let minimumY = max(y - 1, 0)
            let maximumY = min(y + 1, height - 1)
            let minimumZ = max(z - 1, 0)
            let maximumZ = min(z + 1, depth - 1)

            for neighborZ in minimumZ...maximumZ {
                let sliceOffset = neighborZ * sliceElementCount
                for neighborY in minimumY...maximumY {
                    let rowOffset = sliceOffset + neighborY * width
                    for neighborX in minimumX...maximumX where exteriorAirMask[rowOffset + neighborX] != 0 {
                        return true
                    }
                }
            }
            return false
        }

        var surface = [UInt8](repeating: 0, count: voxelCount)
        for z in 0..<depth {
            let sliceOffset = z * sliceElementCount
            for y in 0..<height {
                let rowOffset = sliceOffset + y * width
                for x in 0..<width {
                    let index = rowOffset + x
                    guard foreground[index] != 0, hasExteriorAirNear(x: x, y: y, z: z) else { continue }
                    surface[index] = 255
                }
            }
        }
        return surface
    }

    private static func surfaceMaskByOpeningZCropCaps(
        _ surfaceMask: [UInt8],
        dimensions: SIMD3<Int>
    ) -> [UInt8] {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard surfaceMask.count == voxelCount else { return surfaceMask }

        var minimumSurfaceZ: Int?
        var maximumSurfaceZ: Int?
        for z in 0..<depth {
            let sliceOffset = z * sliceElementCount
            var sliceHasSurface = false
            for index in sliceOffset..<(sliceOffset + sliceElementCount) where surfaceMask[index] != 0 {
                sliceHasSurface = true
                break
            }
            if sliceHasSurface {
                minimumSurfaceZ = z
                break
            }
        }

        for z in stride(from: depth - 1, through: 0, by: -1) {
            let sliceOffset = z * sliceElementCount
            var sliceHasSurface = false
            for index in sliceOffset..<(sliceOffset + sliceElementCount) where surfaceMask[index] != 0 {
                sliceHasSurface = true
                break
            }
            if sliceHasSurface {
                maximumSurfaceZ = z
                break
            }
        }

        guard minimumSurfaceZ != nil || maximumSurfaceZ != nil else { return surfaceMask }

        var opened = surfaceMask
        func clearSlice(_ z: Int) {
            let sliceOffset = z * sliceElementCount
            for index in sliceOffset..<(sliceOffset + sliceElementCount) {
                opened[index] = 0
            }
        }

        if let capZ = minimumSurfaceZ {
            let maximumCapZ = min(capZ + 1, depth - 1)
            for z in capZ...maximumCapZ {
                clearSlice(z)
            }
        }
        if let capZ = maximumSurfaceZ {
            let minimumCapZ = max(capZ - 1, 0)
            for z in minimumCapZ...capZ {
                clearSlice(z)
            }
        }
        return opened
    }

    private static func largestConnectedSurfaceComponentMask(
        _ surfaceMask: [UInt8],
        dimensions: SIMD3<Int>
    ) -> [UInt8] {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard surfaceMask.count == voxelCount, voxelCount <= Int(Int32.max) else {
            return surfaceMask
        }

        var visited = [UInt8](repeating: 0, count: voxelCount)
        var largestComponent = [Int32]()
        var queue = [Int32]()
        var component = [Int32]()

        func appendNeighbor(_ index: Int) {
            guard surfaceMask[index] != 0, visited[index] == 0 else { return }
            visited[index] = 1
            queue.append(Int32(index))
            component.append(Int32(index))
        }

        for startIndex in 0..<voxelCount where surfaceMask[startIndex] != 0 && visited[startIndex] == 0 {
            queue.removeAll(keepingCapacity: true)
            component.removeAll(keepingCapacity: true)
            appendNeighbor(startIndex)

            var head = 0
            while head < queue.count {
                let index = Int(queue[head])
                head += 1

                let z = index / sliceElementCount
                let inSliceIndex = index - z * sliceElementCount
                let y = inSliceIndex / width
                let x = inSliceIndex - y * width

                for dz in -1...1 {
                    let neighborZ = z + dz
                    guard neighborZ >= 0, neighborZ < depth else { continue }
                    for dy in -1...1 {
                        let neighborY = y + dy
                        guard neighborY >= 0, neighborY < height else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                            let neighborX = x + dx
                            guard neighborX >= 0, neighborX < width else { continue }
                            appendNeighbor(neighborZ * sliceElementCount + neighborY * width + neighborX)
                        }
                    }
                }
            }

            if component.count > largestComponent.count {
                largestComponent = component
            }
        }

        guard largestComponent.isEmpty == false else { return surfaceMask }

        var filtered = [UInt8](repeating: 0, count: voxelCount)
        for index in largestComponent {
            filtered[Int(index)] = 255
        }
        return filtered
    }

    private static func filteredSurfaceVertexFloatData(
        _ vertexFloatData: Data,
        surfaceMask: [UInt8],
        exteriorAirMask: [UInt8],
        dimensions: SIMD3<Int>,
        spacing: SIMD3<Float>
    ) -> (data: Data, vertexCount: Int, triangleCount: Int) {
        let floatsPerVertex = 6
        let floatsPerTriangle = floatsPerVertex * 3
        let floatByteCount = MemoryLayout<Float>.stride
        guard vertexFloatData.count >= floatsPerTriangle * floatByteCount,
              vertexFloatData.count % (floatsPerTriangle * floatByteCount) == 0 else {
            return (
                vertexFloatData,
                vertexFloatData.count / (floatsPerVertex * floatByteCount),
                vertexFloatData.count / (floatsPerTriangle * floatByteCount)
            )
        }

        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard surfaceMask.count == voxelCount, exteriorAirMask.count == voxelCount else {
            return (
                vertexFloatData,
                vertexFloatData.count / (floatsPerVertex * floatByteCount),
                vertexFloatData.count / (floatsPerTriangle * floatByteCount)
            )
        }

        let floats = vertexFloatData.withUnsafeBytes { bytes -> [Float] in
            Array(bytes.bindMemory(to: Float.self))
        }
        let triangleCount = floats.count / floatsPerTriangle
        var filteredFloats = [Float]()
        filteredFloats.reserveCapacity(floats.count)

        func hasSurfaceVoxelNear(_ voxelPosition: SIMD3<Float>) -> Bool {
            let centerX = min(max(Int(round(Double(voxelPosition.x))), 0), width - 1)
            let centerY = min(max(Int(round(Double(voxelPosition.y))), 0), height - 1)
            let centerZ = min(max(Int(round(Double(voxelPosition.z))), 0), depth - 1)
            let minimumX = max(centerX - 1, 0)
            let maximumX = min(centerX + 1, width - 1)
            let minimumY = max(centerY - 1, 0)
            let maximumY = min(centerY + 1, height - 1)
            let minimumZ = max(centerZ - 1, 0)
            let maximumZ = min(centerZ + 1, depth - 1)

            for z in minimumZ...maximumZ {
                let sliceOffset = z * sliceElementCount
                for y in minimumY...maximumY {
                    let rowOffset = sliceOffset + y * width
                    for x in minimumX...maximumX where surfaceMask[rowOffset + x] != 0 {
                        return true
                    }
                }
            }
            return false
        }

        func hasExteriorAirNear(_ voxelPosition: SIMD3<Float>) -> Bool {
            let centerX = min(max(Int(round(Double(voxelPosition.x))), 0), width - 1)
            let centerY = min(max(Int(round(Double(voxelPosition.y))), 0), height - 1)
            let centerZ = min(max(Int(round(Double(voxelPosition.z))), 0), depth - 1)
            let minimumX = max(centerX - 1, 0)
            let maximumX = min(centerX + 1, width - 1)
            let minimumY = max(centerY - 1, 0)
            let maximumY = min(centerY + 1, height - 1)
            let minimumZ = max(centerZ - 1, 0)
            let maximumZ = min(centerZ + 1, depth - 1)

            for z in minimumZ...maximumZ {
                let sliceOffset = z * sliceElementCount
                for y in minimumY...maximumY {
                    let rowOffset = sliceOffset + y * width
                    for x in minimumX...maximumX where exteriorAirMask[rowOffset + x] != 0 {
                        return true
                    }
                }
            }
            return false
        }

        for triangleIndex in 0..<triangleCount {
            let base = triangleIndex * floatsPerTriangle
            var centroid = SIMD3<Float>(repeating: 0)
            for vertexIndex in 0..<3 {
                let vertexBase = base + vertexIndex * floatsPerVertex
                centroid += SIMD3<Float>(
                    floats[vertexBase],
                    floats[vertexBase + 1],
                    floats[vertexBase + 2]
                )
            }
            centroid /= 3

            let voxelPosition = SIMD3<Float>(
                centroid.x / max(spacing.x, 0.001),
                centroid.y / max(spacing.y, 0.001),
                centroid.z / max(spacing.z, 0.001)
            )
            guard hasSurfaceVoxelNear(voxelPosition) else { continue }
            guard hasExteriorAirNear(voxelPosition) else { continue }

            filteredFloats.append(contentsOf: floats[base..<(base + floatsPerTriangle)])
        }

        guard filteredFloats.isEmpty == false else {
            return (Data(), 0, 0)
        }

        let filteredData = filteredFloats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return (filteredData, filteredFloats.count / floatsPerVertex, filteredFloats.count / floatsPerTriangle)
    }

    private func makeSkinSurfaceVertexBuffer(vertexFloatData: Data) -> (buffer: MTLBuffer, count: Int)? {
        makeOverlaySurfaceVertexBuffer(
            vertexFloatData: vertexFloatData,
            color: SIMD4<Float>(1.0, 0.02, 0.01, 0.80)
        )
    }

    private func volumePhysicalExtent() -> SIMD3<Float> {
        SIMD3<Float>(
            max(Float(volumeDimensions.x - 1), 1) * voxelSpacing.x,
            max(Float(volumeDimensions.y - 1), 1) * voxelSpacing.y,
            max(Float(volumeDimensions.z - 1), 1) * voxelSpacing.z
        )
    }

    private func volumePhysicalScale() -> Float {
        let extent = volumePhysicalExtent()
        return max(max(extent.x, extent.y), max(extent.z, 1))
    }

    private func worldPosition(forPhysicalPosition physicalPosition: SIMD3<Float>) -> SIMD3<Float> {
        let extent = volumePhysicalExtent()
        return (physicalPosition - extent * 0.5) / volumePhysicalScale()
    }

    private func worldPositions(fromSurfaceVertexFloatData vertexFloatData: Data) -> [SIMD3<Float>] {
        let floatStride = MemoryLayout<Float>.stride
        guard vertexFloatData.count >= floatStride * 6,
              vertexFloatData.count % (floatStride * 6) == 0 else {
            return []
        }

        return vertexFloatData.withUnsafeBytes { bytes -> [SIMD3<Float>] in
            let floats = bytes.bindMemory(to: Float.self)
            let vertexCount = floats.count / 6
            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(vertexCount)
            for vertexIndex in 0..<vertexCount {
                let base = vertexIndex * 6
                positions.append(
                    worldPosition(
                        forPhysicalPosition: SIMD3<Float>(
                            floats[base],
                            floats[base + 1],
                            floats[base + 2]
                        )
                    )
                )
            }
            return positions
        }
    }

    private func centroidWorldPosition(fromSurfaceVertexFloatData vertexFloatData: Data) -> SIMD3<Float>? {
        let positions = worldPositions(fromSurfaceVertexFloatData: vertexFloatData)
        guard positions.isEmpty == false else { return nil }

        var sum = SIMD3<Double>(repeating: 0)
        for position in positions {
            sum += SIMD3<Double>(Double(position.x), Double(position.y), Double(position.z))
        }

        let count = Double(positions.count)
        return SIMD3<Float>(
            Float(sum.x / count),
            Float(sum.y / count),
            Float(sum.z / count)
        )
    }

    private func makeOverlaySurfaceVertexBuffer(vertexFloatData: Data, color: SIMD4<Float>) -> (buffer: MTLBuffer, count: Int)? {
        let floatStride = MemoryLayout<Float>.stride
        guard vertexFloatData.count >= floatStride * 6,
              vertexFloatData.count % (floatStride * 6) == 0 else {
            return nil
        }

        let vertexCount = vertexFloatData.count / (floatStride * 6)
        guard vertexCount > 0 else { return nil }

        let length = MemoryLayout<Metal3DOverlayVertex>.stride * vertexCount
        guard let buffer = deviceRef.makeBuffer(length: length, options: .storageModeShared) else {
            return nil
        }

        vertexFloatData.withUnsafeBytes { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            let vertices = buffer.contents().bindMemory(to: Metal3DOverlayVertex.self, capacity: vertexCount)
            for vertexIndex in 0..<vertexCount {
                let base = vertexIndex * 6
                let physicalPosition = SIMD3<Float>(floats[base], floats[base + 1], floats[base + 2])
                let rawNormal = SIMD3<Float>(floats[base + 3], floats[base + 4], floats[base + 5])
                let normal = simd_length_squared(rawNormal) > 0.000001 ? simd_normalize(rawNormal) : SIMD3<Float>(0, 0, 1)
                vertices[vertexIndex] = Metal3DOverlayVertex(
                    position: worldPosition(forPhysicalPosition: physicalPosition),
                    normal: normal,
                    color: color
                )
            }
        }

        return (buffer, vertexCount)
    }

    private func makeSkinMaskTexture(mask: [UInt8]) -> MTLTexture? {
        guard MetalTextureLimits.supports3DTexture(
            width: volumeDimensions.x,
            height: volumeDimensions.y,
            depth: volumeDimensions.z
        ) else {
            return nil
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = max(volumeDimensions.x, 1)
        descriptor.height = max(volumeDimensions.y, 1)
        descriptor.depth = max(volumeDimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        mask.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, descriptor.width, descriptor.height, descriptor.depth),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: descriptor.width,
                bytesPerImage: descriptor.width * descriptor.height
            )
        }

        return texture
    }

    private func makeEmptySkinMaskTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var zero: UInt8 = 0
        texture.replace(
            region: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
            mipmapLevel: 0,
            slice: 0,
            withBytes: &zero,
            bytesPerRow: 1,
            bytesPerImage: 1
        )
        return texture
    }

    private func tumorColor(for label: UInt8) -> SIMD4<Float> {
        switch label {
        case 1:
            return SIMD4<Float>(1.0, 0.22, 0.18, 0.78)
        case 2:
            return SIMD4<Float>(0.1, 0.72, 1.0, 0.52)
        case 3, 4:
            return SIMD4<Float>(1.0, 0.86, 0.12, 0.82)
        default:
            return SIMD4<Float>(0.92, 0.28, 1.0, 0.68)
        }
    }

    private func skinForegroundThreshold() -> (threshold: Float, method: String) {
        if Self.isCTVolume(pixList) {
            return (-500, "ctHU")
        }

        return (Self.otsuThreshold(values: rawVolume), "otsu")
    }

    private func skinShellThicknessMM() -> Float {
        min(max(currentSkinClipDepthMM, 0), 20)
    }

    private static func initialSkinClipDepthMM(for pixList: [DCMPix]) -> Float {
        if let savedDepth = UserDefaults.standard.object(forKey: skinClipDepthPreferenceKey) as? NSNumber {
            return min(max(savedDepth.floatValue, 0), 20)
        }
        return isCTVolume(pixList) ? 6.0 : 10.0
    }

    private static func otsuThreshold(values: [Float]) -> Float {
        let sampleLimit = 2_000_000
        let sampleStride = max(values.count / sampleLimit, 1)
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude

        var index = 0
        while index < values.count {
            let value = values[index]
            if value.isFinite {
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
            index += sampleStride
        }

        guard minimum.isFinite, maximum.isFinite, maximum > minimum + 0.0001 else {
            return minimum.isFinite ? minimum : 0
        }

        let binCount = 1024
        let span = maximum - minimum
        var histogram = [Int](repeating: 0, count: binCount)

        index = 0
        while index < values.count {
            let value = values[index]
            if value.isFinite {
                let fraction = min(max((value - minimum) / span, 0), 1)
                let bin = min(max(Int((fraction * Float(binCount - 1)).rounded()), 0), binCount - 1)
                histogram[bin] += 1
            }
            index += sampleStride
        }

        let total = histogram.reduce(0, +)
        guard total > 0 else { return minimum }

        var totalSum = 0.0
        for bin in 0..<binCount {
            totalSum += Double(bin * histogram[bin])
        }

        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = -Double.greatestFiniteMagnitude
        var thresholdBin = 0

        for bin in 0..<binCount {
            backgroundWeight += histogram[bin]
            if backgroundWeight == 0 { continue }

            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }

            backgroundSum += Double(bin * histogram[bin])
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (totalSum - backgroundSum) / Double(foregroundWeight)
            let delta = backgroundMean - foregroundMean
            let variance = Double(backgroundWeight) * Double(foregroundWeight) * delta * delta
            if variance > bestVariance {
                bestVariance = variance
                thresholdBin = bin
            }
        }

        let threshold = minimum + (Float(thresholdBin) + 0.5) * span / Float(binCount)
        let noiseFloor = minimum + span * 0.03
        return max(threshold, noiseFloor)
    }

    private static func skinEnvelopeForegroundMask(
        foreground: [UInt8],
        values: [Float],
        rejectHighDensity: Bool
    ) -> (mask: [UInt8], count: Int, method: String) {
        var foregroundCount = 0
        for value in foreground where value != 0 {
            foregroundCount += 1
        }

        guard rejectHighDensity, values.count == foreground.count else {
            return (foreground, foregroundCount, "foreground")
        }

        let maximumSkinBoundaryHU: Float = 700
        var filtered = [UInt8](repeating: 0, count: foreground.count)
        var filteredCount = 0
        for index in foreground.indices where foreground[index] != 0 {
            let value = values[index]
            guard value.isFinite, value <= maximumSkinBoundaryHU else { continue }
            filtered[index] = 1
            filteredCount += 1
        }

        let minimumUsefulCount = max(1024, foregroundCount / 20)
        if filteredCount >= minimumUsefulCount {
            return (filtered, filteredCount, "ctSoftTissueForeground")
        }

        return (foreground, foregroundCount, "foreground")
    }

    private enum BinaryMorphologyOperation {
        case dilation
        case erosion
    }

    private static func skinExternalAirProbeRadiusMM(isCT: Bool) -> Float {
        isCT ? 1.0 : 0.5
    }

    // Keep air reachable by a finite probe from outside, then contour everything else.
    private static func externalAirReconstructedEnvelopeMask(
        foreground: [UInt8],
        dimensions: SIMD3<Int>,
        spacing: SIMD3<Float>,
        radiusMM: Float
    ) -> (mask: [UInt8], count: Int, exteriorAir: [UInt8]) {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let voxelCount = max(width * height * depth, 1)
        guard foreground.count == voxelCount else {
            return (
                [UInt8](repeating: 0, count: foreground.count),
                0,
                [UInt8](repeating: 0, count: foreground.count)
            )
        }

        let radiusX = min(max(Int(ceil(Double(radiusMM / max(spacing.x, 0.001)))), 1), max(width - 1, 1))
        let radiusY = min(max(Int(ceil(Double(radiusMM / max(spacing.y, 0.001)))), 1), max(height - 1, 1))
        let radiusZ = min(max(Int(ceil(Double(radiusMM / max(spacing.z, 0.001)))), 1), max(depth - 1, 1))

        var air = [UInt8](repeating: 0, count: voxelCount)
        for index in foreground.indices where foreground[index] == 0 {
            air[index] = 1
        }

        let passableAirCore = binaryErodedMask(
            air,
            dimensions: SIMD3<Int>(width, height, depth),
            radiusX: radiusX,
            radiusY: radiusY,
            radiusZ: radiusZ
        )
        let reachableAirCore = floodFillExteriorAirCore(
            passableAirCore,
            dimensions: SIMD3<Int>(width, height, depth)
        )
        let reconstructedAir = binaryDilatedMask(
            reachableAirCore,
            dimensions: SIMD3<Int>(width, height, depth),
            radiusX: radiusX,
            radiusY: radiusY,
            radiusZ: radiusZ
        )
        var exteriorAir = reconstructedAir
        for index in 0..<voxelCount where air[index] == 0 {
            exteriorAir[index] = 0
        }

        var envelope = [UInt8](repeating: 0, count: voxelCount)
        var envelopeCount = 0
        for index in 0..<voxelCount where reconstructedAir[index] == 0 || air[index] == 0 {
            envelope[index] = 1
            envelopeCount += 1
        }

        return (envelope, envelopeCount, exteriorAir)
    }

    private static func binaryErodedMask(
        _ mask: [UInt8],
        dimensions: SIMD3<Int>,
        radiusX: Int,
        radiusY: Int,
        radiusZ: Int
    ) -> [UInt8] {
        // Exterior-of-volume space is air, not a wall. That keeps crop planes from becoming skin caps.
        var result = binaryMorphology1D(
            mask,
            dimensions: dimensions,
            axis: 0,
            radius: radiusX,
            operation: .erosion,
            erosionTreatsOutOfBoundsAsSet: true
        )
        result = binaryMorphology1D(
            result,
            dimensions: dimensions,
            axis: 1,
            radius: radiusY,
            operation: .erosion,
            erosionTreatsOutOfBoundsAsSet: true
        )
        result = binaryMorphology1D(
            result,
            dimensions: dimensions,
            axis: 2,
            radius: radiusZ,
            operation: .erosion,
            erosionTreatsOutOfBoundsAsSet: true
        )
        return result
    }

    private static func binaryDilatedMask(
        _ mask: [UInt8],
        dimensions: SIMD3<Int>,
        radiusX: Int,
        radiusY: Int,
        radiusZ: Int
    ) -> [UInt8] {
        var result = binaryMorphology1D(mask, dimensions: dimensions, axis: 0, radius: radiusX, operation: .dilation)
        result = binaryMorphology1D(result, dimensions: dimensions, axis: 1, radius: radiusY, operation: .dilation)
        result = binaryMorphology1D(result, dimensions: dimensions, axis: 2, radius: radiusZ, operation: .dilation)
        return result
    }

    private static func binaryMorphology1D(
        _ input: [UInt8],
        dimensions: SIMD3<Int>,
        axis: Int,
        radius: Int,
        operation: BinaryMorphologyOperation,
        erosionTreatsOutOfBoundsAsSet: Bool = false
    ) -> [UInt8] {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard input.count == voxelCount, radius > 0 else { return input }

        var output = [UInt8](repeating: 0, count: voxelCount)

        func applyLine(base: Int, stride: Int, length: Int) {
            guard length > 0 else { return }

            var nonzeroCount = 0
            let initialEnd = min(radius, length - 1)
            for offset in 0...initialEnd where input[base + offset * stride] != 0 {
                nonzeroCount += 1
            }

            for offset in 0..<length {
                let index = base + offset * stride
                switch operation {
                case .dilation:
                    output[index] = nonzeroCount > 0 ? 1 : 0
                case .erosion:
                    let requiredCount: Int
                    if erosionTreatsOutOfBoundsAsSet {
                        let windowStart = max(offset - radius, 0)
                        let windowEnd = min(offset + radius, length - 1)
                        requiredCount = windowEnd - windowStart + 1
                    } else {
                        requiredCount = radius * 2 + 1
                    }
                    let hasCompleteWindow = erosionTreatsOutOfBoundsAsSet || (offset >= radius && offset + radius < length)
                    output[index] = (hasCompleteWindow && nonzeroCount == requiredCount) ? 1 : 0
                }

                let removedOffset = offset - radius
                if removedOffset >= 0, input[base + removedOffset * stride] != 0 {
                    nonzeroCount -= 1
                }

                let addedOffset = offset + radius + 1
                if addedOffset < length, input[base + addedOffset * stride] != 0 {
                    nonzeroCount += 1
                }
            }
        }

        switch axis {
        case 0:
            for z in 0..<depth {
                let sliceOffset = z * sliceElementCount
                for y in 0..<height {
                    applyLine(base: sliceOffset + y * width, stride: 1, length: width)
                }
            }
        case 1:
            for z in 0..<depth {
                let sliceOffset = z * sliceElementCount
                for x in 0..<width {
                    applyLine(base: sliceOffset + x, stride: width, length: height)
                }
            }
        default:
            for y in 0..<height {
                let rowOffset = y * width
                for x in 0..<width {
                    applyLine(base: rowOffset + x, stride: sliceElementCount, length: depth)
                }
            }
        }

        return output
    }

    private static func floodFillExteriorAirCore(
        _ passableAirCore: [UInt8],
        dimensions: SIMD3<Int>
    ) -> [UInt8] {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        guard passableAirCore.count == voxelCount, voxelCount <= Int(Int32.max) else {
            return [UInt8](repeating: 0, count: passableAirCore.count)
        }

        var exteriorCore = [UInt8](repeating: 0, count: voxelCount)
        var queue = [Int32]()
        queue.reserveCapacity(min(voxelCount, 1_000_000))

        func enqueueExterior(_ index: Int) {
            guard passableAirCore[index] != 0, exteriorCore[index] == 0 else { return }
            exteriorCore[index] = 1
            queue.append(Int32(index))
        }

        let minSeedX = 0
        let maxSeedX = width - 1
        let minSeedY = 0
        let maxSeedY = height - 1
        for z in 0..<depth {
            let sliceOffset = z * sliceElementCount
            for x in 0..<width {
                enqueueExterior(sliceOffset + minSeedY * width + x)
                enqueueExterior(sliceOffset + maxSeedY * width + x)
            }
        }

        for z in 0..<depth {
            let sliceOffset = z * sliceElementCount
            for y in 0..<height {
                let rowOffset = sliceOffset + y * width
                enqueueExterior(rowOffset + minSeedX)
                enqueueExterior(rowOffset + maxSeedX)
            }
        }

        var head = 0
        while head < queue.count {
            let index = Int(queue[head])
            head += 1

            let z = index / sliceElementCount
            let inSliceIndex = index - z * sliceElementCount
            let y = inSliceIndex / width
            let x = inSliceIndex - y * width

            if x > 0 { enqueueExterior(index - 1) }
            if x + 1 < width { enqueueExterior(index + 1) }
            if y > 0 { enqueueExterior(index - width) }
            if y + 1 < height { enqueueExterior(index + width) }
            if z > 0 { enqueueExterior(index - sliceElementCount) }
            if z + 1 < depth { enqueueExterior(index + sliceElementCount) }
        }

        return exteriorCore
    }

    private static func axialClosedEnvelopeMask(
        foreground: [UInt8],
        dimensions: SIMD3<Int>
    ) -> (mask: [UInt8], count: Int) {
        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        var envelope = [UInt8](repeating: 0, count: voxelCount)
        var count = 0

        for z in 0..<depth {
            let sliceOffset = z * sliceElementCount

            for y in 0..<height {
                let rowOffset = sliceOffset + y * width
                var minimumX = width
                var maximumX = -1
                for x in 0..<width where foreground[rowOffset + x] != 0 {
                    minimumX = min(minimumX, x)
                    maximumX = max(maximumX, x)
                }
                guard maximumX >= minimumX else { continue }

                for x in minimumX...maximumX {
                    let index = rowOffset + x
                    if envelope[index] == 0 {
                        envelope[index] = 1
                        count += 1
                    }
                }
            }

            for x in 0..<width {
                var minimumY = height
                var maximumY = -1
                for y in 0..<height where foreground[sliceOffset + y * width + x] != 0 {
                    minimumY = min(minimumY, y)
                    maximumY = max(maximumY, y)
                }

                for y in 0..<height {
                    let index = sliceOffset + y * width + x
                    if maximumY < minimumY || y < minimumY || y > maximumY {
                        if envelope[index] != 0 {
                            envelope[index] = 0
                            count -= 1
                        }
                    }
                }
            }
        }

        return (envelope, count)
    }

    private static func invertedMask(_ object: [UInt8]) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: object.count)
        for index in object.indices where object[index] == 0 {
            mask[index] = 255
        }
        return mask
    }

    private static func markObjectWithinPhysicalDistance(
        object: [UInt8],
        surface: [UInt8],
        mask: inout [UInt8],
        dimensions: SIMD3<Int>,
        spacing: SIMD3<Float>,
        maximumDistanceMM: Float
    ) {
        guard maximumDistanceMM > 0 else { return }

        let width = max(dimensions.x, 1)
        let height = max(dimensions.y, 1)
        let depth = max(dimensions.z, 1)
        let sliceElementCount = width * height
        let voxelCount = max(sliceElementCount * depth, 1)
        let distanceScale: Float = 100.0
        let maximumDistance = UInt16(min(max((maximumDistanceMM * distanceScale).rounded(), 0), Float(UInt16.max - 255)))
        guard maximumDistance > 0 else { return }

        let neighbors = [
            Metal3DSkinDistanceNeighbor(dx: -1, dy: 0, dz: 0, cost: UInt16(max(Int((spacing.x * distanceScale).rounded()), 1))),
            Metal3DSkinDistanceNeighbor(dx: 1, dy: 0, dz: 0, cost: UInt16(max(Int((spacing.x * distanceScale).rounded()), 1))),
            Metal3DSkinDistanceNeighbor(dx: 0, dy: -1, dz: 0, cost: UInt16(max(Int((spacing.y * distanceScale).rounded()), 1))),
            Metal3DSkinDistanceNeighbor(dx: 0, dy: 1, dz: 0, cost: UInt16(max(Int((spacing.y * distanceScale).rounded()), 1))),
            Metal3DSkinDistanceNeighbor(dx: 0, dy: 0, dz: -1, cost: UInt16(max(Int((spacing.z * distanceScale).rounded()), 1))),
            Metal3DSkinDistanceNeighbor(dx: 0, dy: 0, dz: 1, cost: UInt16(max(Int((spacing.z * distanceScale).rounded()), 1))),
        ]

        var distances = [UInt16](repeating: UInt16.max, count: voxelCount)
        var heap = Metal3DSkinDistanceHeap()
        heap.reserveCapacity(min(voxelCount, 1_000_000))

        var sourceCount = 0
        for index in 0..<voxelCount where object[index] != 0 && surface[index] != 0 {
            distances[index] = 0
            heap.push(Metal3DSkinDistanceNode(distance: 0, index: index))
            sourceCount += 1
        }
        guard sourceCount > 0 else { return }

        while let node = heap.pop() {
            guard node.distance == distances[node.index] else { continue }
            guard node.distance <= maximumDistance else { break }

            mask[node.index] = 255
            let z = node.index / sliceElementCount
            let remainder = node.index - z * sliceElementCount
            let y = remainder / width
            let x = remainder - y * width

            for neighbor in neighbors {
                let nx = x + neighbor.dx
                let ny = y + neighbor.dy
                let nz = z + neighbor.dz
                guard nx >= 0, nx < width, ny >= 0, ny < height, nz >= 0, nz < depth else { continue }

                let neighborIndex = nz * sliceElementCount + ny * width + nx
                guard object[neighborIndex] != 0 else { continue }

                let candidateDistance = Int(node.distance) + Int(neighbor.cost)
                guard candidateDistance <= Int(maximumDistance), candidateDistance < Int(distances[neighborIndex]) else {
                    continue
                }

                let clampedDistance = UInt16(candidateDistance)
                distances[neighborIndex] = clampedDistance
                heap.push(Metal3DSkinDistanceNode(distance: clampedDistance, index: neighborIndex))
            }
        }
    }

    private static func grayscalePixels() -> [SIMD4<UInt8>] {
        var pixels = [SIMD4<UInt8>](repeating: SIMD4<UInt8>(0, 0, 0, 255), count: 256)
        let inverted = (((UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics") ?? [:])["DisplayUseInvertedPolarity"] as? Bool) == true)
        for index in 0..<256 {
            let value = UInt8(inverted ? 255 - index : index)
            pixels[index] = SIMD4<UInt8>(value, value, value, 255)
        }
        return pixels
    }

    private func makeOpacityTransferTexture() -> MTLTexture? {
        let width = transferTextureWidth
        var values = [Float](repeating: 0, count: width)

        if customOpacityControlPoints.isEmpty == false {
            let points = customOpacityControlPoints
            for index in 0..<width {
                let fraction = Float(index) / Float(max(width - 1, 1))
                let sample = histogramDomainMin + fraction * (histogramDomainMax - histogramDomainMin)
                if sample <= points[0].x {
                    values[index] = points[0].y / superSampling
                    continue
                }
                if sample >= points[points.count - 1].x {
                    values[index] = points[points.count - 1].y / superSampling
                    continue
                }

                for pointIndex in 1..<points.count {
                    let previous = points[pointIndex - 1]
                    let current = points[pointIndex]
                    if sample <= current.x {
                        let t = (sample - previous.x) / max(current.x - previous.x, 0.0001)
                        let opacity = previous.y + (current.y - previous.y) * t
                        values[index] = opacity / superSampling
                        break
                    }
                }
            }
        } else if currentOpacityPoints.isEmpty {
            for index in 0..<width {
                values[index] = (Float(index) / Float(max(width - 1, 1))) / superSampling
            }
        } else {
            var points = [(x: Float, y: Float)]()
            for string in currentOpacityPoints {
                var point = NSPointFromString(string)
                point.x -= 1000
                let mappedX = min(max(Float(point.x) / 256.0, 0), 1)
                points.append((x: mappedX, y: Float(point.y) / superSampling))
            }
            points.sort { $0.x < $1.x }

            for index in 0..<width {
                let sample = Float(index) / Float(max(width - 1, 1))
                if sample <= 0 {
                    values[index] = 0
                    continue
                }
                if sample >= 1 {
                    values[index] = points.last?.y ?? (1.0 / superSampling)
                    continue
                }

                if let first = points.first, sample <= first.x {
                    values[index] = first.x > 0 ? (sample / max(first.x, 0.0001)) * first.y : first.y
                    continue
                }

                var assigned = false
                for pointIndex in 1..<points.count {
                    let previous = points[pointIndex - 1]
                    let current = points[pointIndex]
                    if sample <= current.x {
                        let t = (sample - previous.x) / max(current.x - previous.x, 0.0001)
                        values[index] = previous.y + (current.y - previous.y) * t
                        assigned = true
                        break
                    }
                }

                if assigned == false {
                    let last = points.last?.y ?? (1.0 / superSampling)
                    let lastX = points.last?.x ?? 1
                    values[index] = last + (1.0 / superSampling - last) * ((sample - lastX) / max(1 - lastX, 0.0001))
                }
            }
        }
        applyCompositeOpacityCorrection(to: &values)
        let data = values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return makeFloat1DTexture(data: data, width: values.count)
    }

    private func makePreIntegratedTransferTexture() -> MTLTexture? {
        let width = max(preIntegratedTransferTextureWidth, 2)
        let sampleCount = max(preIntegratedTransferSamples, 1)
        let domain = preIntegratedTransferDomain()
        let span = max(domain.max - domain.min, 0.0001)
        let opacityPoints = normalizedOpacityControlPoints()
        let rawOpacityPoints = customOpacityControlPoints.map { (x: $0.x, y: $0.y) }
        var pixels = [SIMD4<UInt16>](repeating: SIMD4<UInt16>(repeating: 0), count: width * width)

        for currentIndex in 0..<width {
            let currentScalar = domain.min + (Float(currentIndex) / Float(width - 1)) * span
            for previousIndex in 0..<width {
                let previousScalar = domain.min + (Float(previousIndex) / Float(width - 1)) * span
                var premultipliedColor = SIMD3<Float>(repeating: 0)
                var accumulatedAlpha: Float = 0

                for sampleIndex in 0..<sampleCount {
                    let t = (Float(sampleIndex) + 0.5) / Float(sampleCount)
                    let scalar = previousScalar + (currentScalar - previousScalar) * t
                    let segmentOpacity = correctedOpacityForScalar(
                        scalar,
                        opacityPoints: opacityPoints,
                        rawOpacityPoints: rawOpacityPoints
                    )
                    guard segmentOpacity > 0 else { continue }

                    let subsegmentAlpha = Float(1.0 - pow(1.0 - Double(segmentOpacity), 1.0 / Double(sampleCount)))
                    guard subsegmentAlpha > 0 else { continue }

                    let visibility = (1.0 - accumulatedAlpha) * subsegmentAlpha
                    premultipliedColor += visibility * colorForScalar(scalar)
                    accumulatedAlpha += visibility
                }

                pixels[currentIndex * width + previousIndex] = SIMD4<UInt16>(
                    Self.unorm16(premultipliedColor.x),
                    Self.unorm16(premultipliedColor.y),
                    Self.unorm16(premultipliedColor.z),
                    Self.unorm16(accumulatedAlpha)
                )
            }
        }

        return makeRGBA16Unorm2DTexture(pixels: pixels, width: width, height: width)
    }

    private func preIntegratedTransferDomain() -> (min: Float, max: Float) {
        if customOpacityControlPoints.isEmpty == false {
            return (histogramDomainMin, histogramDomainMax)
        }

        let lower = windowLevel - windowWidth * 0.5
        return (lower, lower + max(windowWidth, 1))
    }

    private func normalizedOpacityControlPoints() -> [(x: Float, y: Float)] {
        currentOpacityPoints.compactMap { string -> (x: Float, y: Float)? in
            var point = NSPointFromString(string)
            point.x -= 1000
            let x = min(max(Float(point.x) / 256.0, 0), 1)
            let y = min(max(Float(point.y), 0), 1)
            return (x: x, y: y)
        }
        .sorted { $0.x < $1.x }
    }

    private func correctedOpacityForScalar(
        _ scalar: Float,
        opacityPoints: [(x: Float, y: Float)],
        rawOpacityPoints: [(x: Float, y: Float)]
    ) -> Float {
        let baseOpacity = baseOpacityForScalar(
            scalar,
            opacityPoints: opacityPoints,
            rawOpacityPoints: rawOpacityPoints
        )
        let opacity = min(max(baseOpacity, 0), 1) / superSampling
        let factor = opacityCorrectionFactor()
        guard opacity > 0.0001, abs(factor - 1.0) > 0.0001 else {
            return opacity
        }
        return Float(1.0 - pow(1.0 - Double(opacity), Double(factor)))
    }

    private func baseOpacityForScalar(
        _ scalar: Float,
        opacityPoints: [(x: Float, y: Float)],
        rawOpacityPoints: [(x: Float, y: Float)]
    ) -> Float {
        if customOpacityControlPoints.isEmpty == false {
            return interpolatedOpacity(scalar: scalar, points: rawOpacityPoints)
        }

        let normalizedScalar = normalizedWindowFraction(for: scalar)
        guard opacityPoints.isEmpty == false else {
            return normalizedScalar
        }

        if normalizedScalar <= 0 {
            return 0
        }
        if normalizedScalar >= 1 {
            return opacityPoints.last?.y ?? 1
        }
        if let first = opacityPoints.first, normalizedScalar <= first.x {
            return first.x > 0 ? (normalizedScalar / max(first.x, 0.0001)) * first.y : first.y
        }

        return interpolatedOpacity(scalar: normalizedScalar, points: opacityPoints)
    }

    private func interpolatedOpacity(scalar: Float, points: [(x: Float, y: Float)]) -> Float {
        guard let first = points.first else { return 0 }
        if scalar <= first.x {
            return first.y
        }

        guard let last = points.last else { return first.y }
        if scalar >= last.x {
            return last.y
        }

        for pointIndex in 1..<points.count {
            let previous = points[pointIndex - 1]
            let current = points[pointIndex]
            if scalar <= current.x {
                let t = (scalar - previous.x) / max(current.x - previous.x, 0.0001)
                return previous.y + (current.y - previous.y) * t
            }
        }

        return last.y
    }

    private func colorForScalar(_ scalar: Float) -> SIMD3<Float> {
        let normalizedScalar = normalizedWindowFraction(for: scalar)
        let lastIndex = max(currentCLUTPixels.count - 1, 0)
        let scaledIndex = normalizedScalar * Float(lastIndex)
        let lowerIndex = min(max(Int(floor(scaledIndex)), 0), lastIndex)
        let upperIndex = min(lowerIndex + 1, lastIndex)
        guard currentCLUTPixels.indices.contains(lowerIndex),
              currentCLUTPixels.indices.contains(upperIndex) else {
            return SIMD3<Float>(repeating: normalizedScalar)
        }

        let fraction = scaledIndex - Float(lowerIndex)
        let lower = currentCLUTPixels[lowerIndex]
        let upper = currentCLUTPixels[upperIndex]
        let lowerColor = SIMD3<Float>(
            Float(lower.x) / 255.0,
            Float(lower.y) / 255.0,
            Float(lower.z) / 255.0
        )
        let upperColor = SIMD3<Float>(
            Float(upper.x) / 255.0,
            Float(upper.y) / 255.0,
            Float(upper.z) / 255.0
        )
        return lowerColor + (upperColor - lowerColor) * fraction
    }

    private func normalizedWindowFraction(for scalar: Float) -> Float {
        let lower = windowLevel - windowWidth * 0.5
        return min(max((scalar - lower) / max(windowWidth, 0.0001), 0), 1)
    }

    private static func unorm16(_ value: Float) -> UInt16 {
        UInt16(clamping: Int((min(max(value, 0), 1) * 65535.0).rounded()))
    }

    private func applyCompositeOpacityCorrection(to values: inout [Float]) {
        let factor = opacityCorrectionFactor()
        guard abs(factor - 1.0) > 0.0001 else { return }

        for index in values.indices {
            let opacity = min(max(values[index], 0), 1)
            if opacity > 0.0001 {
                values[index] = Float(1.0 - pow(1.0 - Double(opacity), Double(factor)))
            } else {
                values[index] = opacity
            }
        }
    }

    private func rayMarchStepSize() -> Float {
        max(minimumNormalizedVoxelSpacing(), 0.000125)
    }

    private func opacityCorrectionFactor() -> Float {
        return max(superSampling, 0.0001)
    }

    private func minimumNormalizedVoxelSpacing() -> Float {
        let extent = boxMax - boxMin
        let spacing = SIMD3<Float>(
            extent.x / max(Float(volumeDimensions.x - 1), 1.0),
            extent.y / max(Float(volumeDimensions.y - 1), 1.0),
            extent.z / max(Float(volumeDimensions.z - 1), 1.0)
        )
        return max(min(min(spacing.x, spacing.y), spacing.z), 0.0001)
    }

    private func defaultOpacityControlPoints() -> [SIMD2<Float>] {
        return [
            SIMD2<Float>(histogramDomainMin, 0.0),
            SIMD2<Float>(boneLowerHU, 0.0),
            SIMD2<Float>(boneSurfaceHU, 1.0),
            SIMD2<Float>(boneUpperHU, 1.0),
            SIMD2<Float>(histogramDomainMax, 1.0),
        ]
    }

    private func makeColorTransferTexture() -> MTLTexture? {
        let width = transferTextureWidth
        var pixels = [SIMD4<UInt8>](repeating: SIMD4<UInt8>(0, 0, 0, 255), count: width)

        for index in 0..<width {
            let fraction = Float(index) / Float(max(width - 1, 1))
            let lutIndex = min(max(Int((fraction * 255.0).rounded()), 0), 255)
            pixels[index] = currentCLUTPixels[lutIndex]
        }

        return makeRGBA1DTexture(pixels: pixels)
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

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

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

    private func makeRGBA16Unorm2DTexture(pixels: [SIMD4<UInt16>], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, max(width, 1), max(height, 1)),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: max(width, 1) * MemoryLayout<SIMD4<UInt16>>.stride
            )
        }

        return texture
    }

    private func makeFloat1DTexture(data: Data, width: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: max(width, 1),
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = deviceRef.makeTexture(descriptor: descriptor) else {
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, max(width, 1), 1),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: max(width, 1) * MemoryLayout<Float>.stride
            )
        }

        return texture
    }

    private static func voxelSpacing(for pixList: [DCMPix]) -> SIMD3<Float> {
        guard let firstPix = pixList.first else {
            return SIMD3<Float>(repeating: 1)
        }

        let rowSpacing = Float(max(firstPix.pixelSpacingX, 0.0001))
        let columnSpacing = Float(max(firstPix.pixelSpacingY, 0.0001))
        let sliceSpacing: Float
        let storedSliceSpacing = Float(max(abs(firstPix.spacingBetweenSlices), 0.0))
        let fallbackSliceSpacing = Float(max(max(max(abs(firstPix.spacingBetweenSlices), abs(firstPix.sliceInterval)), abs(firstPix.sliceThickness)), 0.0001))
        if pixList.count > 1 {
            let nextPix = pixList[1]
            let delta = SIMD3<Float>(
                Float(nextPix.originX - firstPix.originX),
                Float(nextPix.originY - firstPix.originY),
                Float(nextPix.originZ - firstPix.originZ)
            )
            let distance = simd_length(delta)
            if distance > 0.0001 {
                sliceSpacing = distance
            } else if storedSliceSpacing > 0.0001 {
                sliceSpacing = storedSliceSpacing
            } else {
                sliceSpacing = fallbackSliceSpacing
            }
        } else {
            sliceSpacing = max(fallbackSliceSpacing, 1.0)
        }

        return SIMD3<Float>(rowSpacing, columnSpacing, sliceSpacing)
    }

    private static func referenceVoxelToPatientMatrix(
        sourceVoxelToPatientMatrix: simd_float4x4,
        cropBounds: Metal3DVolumeCropBounds,
        outputSpacing: SIMD3<Float>
    ) -> simd_float4x4 {
        let cropOrigin = sourceVoxelToPatientMatrix * SIMD4<Float>(
            Float(cropBounds.minX),
            Float(cropBounds.minY),
            Float(cropBounds.minZ),
            1
        )

        func normalizedColumn(_ column: SIMD4<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
            let vector = SIMD3<Float>(column.x, column.y, column.z)
            return simd_length(vector) > 0.0001 ? simd_normalize(vector) : fallback
        }

        let rowDirection = normalizedColumn(sourceVoxelToPatientMatrix.columns.0, fallback: SIMD3<Float>(1, 0, 0))
        let columnDirection = normalizedColumn(sourceVoxelToPatientMatrix.columns.1, fallback: SIMD3<Float>(0, 1, 0))
        let sliceDirection = normalizedColumn(sourceVoxelToPatientMatrix.columns.2, fallback: SIMD3<Float>(0, 0, 1))
        let rowStep = rowDirection * outputSpacing.x
        let columnStep = columnDirection * outputSpacing.y
        let sliceStep = sliceDirection * outputSpacing.z

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(cropOrigin.x, cropOrigin.y, cropOrigin.z, 1)
        )
    }

    private static func matrixRows(_ matrix: simd_float4x4) -> [[Double]] {
        [
            [Double(matrix.columns.0.x), Double(matrix.columns.1.x), Double(matrix.columns.2.x), Double(matrix.columns.3.x)],
            [Double(matrix.columns.0.y), Double(matrix.columns.1.y), Double(matrix.columns.2.y), Double(matrix.columns.3.y)],
            [Double(matrix.columns.0.z), Double(matrix.columns.1.z), Double(matrix.columns.2.z), Double(matrix.columns.3.z)],
            [Double(matrix.columns.0.w), Double(matrix.columns.1.w), Double(matrix.columns.2.w), Double(matrix.columns.3.w)],
        ]
    }

    private static func volumeCropBounds(
        for pixList: [DCMPix],
        dimensions: SIMD3<Int>,
        spacing: SIMD3<Float>
    ) -> Metal3DVolumeCropBounds {
        let fullBounds = Metal3DVolumeCropBounds(
            minX: 0,
            maxX: max(dimensions.x - 1, 0),
            minY: 0,
            maxY: max(dimensions.y - 1, 0),
            minZ: 0,
            maxZ: max(dimensions.z - 1, 0)
        )

        guard let firstPix = pixList.first, shouldCropAir(for: firstPix) else {
            return fullBounds
        }

        let start = CFAbsoluteTimeGetCurrent()
        let threshold: Float = -900
        let fullWidth = max(dimensions.x, 1)
        let fullHeight = max(dimensions.y, 1)
        let fullDepth = min(max(dimensions.z, 1), pixList.count)
        let fullSliceElementCount = fullWidth * fullHeight
        var minX = fullWidth
        var maxX = -1
        var minY = fullHeight
        var maxY = -1
        var minZ = fullDepth
        var maxZ = -1

        for sliceIndex in 0..<fullDepth {
            let pix = pixList[sliceIndex]
            pix.checkLoad()
            guard let source = pix.fImage else { continue }

            var sliceHasContent = false
            for y in 0..<fullHeight {
                let rowOffset = y * fullWidth
                for x in 0..<fullWidth {
                    let index = rowOffset + x
                    guard index < fullSliceElementCount, source[index] > threshold else { continue }

                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    sliceHasContent = true
                }
            }

            if sliceHasContent {
                minZ = min(minZ, sliceIndex)
                maxZ = max(maxZ, sliceIndex)
            }
        }

        guard maxX >= minX, maxY >= minY, maxZ >= minZ else {
            return fullBounds
        }

        let marginX = max(Int((12.0 / Double(max(spacing.x, 0.0001))).rounded()), 4)
        let marginY = max(Int((12.0 / Double(max(spacing.y, 0.0001))).rounded()), 4)
        let marginZ = max(Int((8.0 / Double(max(spacing.z, 0.0001))).rounded()), 1)
        let cropBounds = Metal3DVolumeCropBounds(
            minX: max(minX - marginX, 0),
            maxX: min(maxX + marginX, fullWidth - 1),
            minY: max(minY - marginY, 0),
            maxY: min(maxY + marginY, fullHeight - 1),
            minZ: max(minZ - marginZ, 0),
            maxZ: min(maxZ + marginZ, fullDepth - 1)
        )

        let cropDimensions = cropBounds.dimensions
        if cropDimensions.x >= fullWidth, cropDimensions.y >= fullHeight, cropDimensions.z >= fullDepth {
            return fullBounds
        }

        if MetalViewerDiagnostics.isTimingLogEnabled {
            NSLog(
                "HOROS_METAL_TIMING Metal3DVolumeRenderer airCrop source=%ldx%ldx%ld crop=(%ld:%ld,%ld:%ld,%ld:%ld) output=%ldx%ldx%ld %.3f s",
                dimensions.x,
                dimensions.y,
                dimensions.z,
                cropBounds.minX,
                cropBounds.maxX,
                cropBounds.minY,
                cropBounds.maxY,
                cropBounds.minZ,
                cropBounds.maxZ,
                cropDimensions.x,
                cropDimensions.y,
                cropDimensions.z,
                CFAbsoluteTimeGetCurrent() - start
            )
        }

        return cropBounds
    }

    private static func shouldCropAir(for firstPix: DCMPix) -> Bool {
        let modality = firstPix.modalityString?.uppercased() ?? ""
        let rescale = firstPix.rescaleType?.uppercased() ?? ""
        let seriesMinimum = Float(firstPix.minValueOfSeries)
        let seriesMaximum = Float(firstPix.maxValueOfSeries)
        return modality.contains("CT") || rescale == "HU" || (seriesMinimum < -500 && seriesMaximum > 300)
    }

    private static func isCTVolume(_ pixList: [DCMPix]) -> Bool {
        guard let firstPix = pixList.first else { return false }
        let modality = firstPix.modalityString?.uppercased() ?? ""
        let rescale = firstPix.rescaleType?.uppercased() ?? ""
        return modality.contains("CT") || rescale == "HU"
    }

    private static func volumeExtent(dimensions: SIMD3<Int>, spacing: SIMD3<Float>) -> SIMD3<Float> {
        let rawExtent = SIMD3<Float>(
            max(Float(dimensions.x - 1), 1) * spacing.x,
            max(Float(dimensions.y - 1), 1) * spacing.y,
            max(Float(dimensions.z - 1), 1) * spacing.z
        )
        let maxComponent = max(max(rawExtent.x, rawExtent.y), max(rawExtent.z, 1))
        return rawExtent / maxComponent
    }

    private static func isotropicTextureGeometry(
        sourceDimensions: SIMD3<Int>,
        sourceSpacing: SIMD3<Float>
    ) -> (dimensions: SIMD3<Int>, spacing: SIMD3<Float>) {
        let inPlaneSpacing = max(min(sourceSpacing.x, sourceSpacing.y), 0.0001)
        let sourceDepth = max(sourceDimensions.z, 1)
        guard sourceDepth > 1, sourceSpacing.z > inPlaneSpacing * 1.15 else {
            return (sourceDimensions, sourceSpacing)
        }

        let physicalDepth = Float(sourceDepth - 1) * sourceSpacing.z
        let targetDepth = Int((physicalDepth / inPlaneSpacing).rounded()) + 1
        let depthLimit = max(sourceDepth, min(targetDepth, 640))
        let outputDepth = max(sourceDepth, min(targetDepth, depthLimit))
        guard outputDepth > sourceDepth else {
            return (sourceDimensions, sourceSpacing)
        }

        var outputSpacing = sourceSpacing
        outputSpacing.z = physicalDepth / Float(max(outputDepth - 1, 1))
        return (SIMD3<Int>(sourceDimensions.x, sourceDimensions.y, outputDepth), outputSpacing)
    }

    private static func scalarMapping(for pixList: [DCMPix]) -> (valueFactor: Float, offset16: Float) {
        guard let firstPix = pixList.first else {
            return (1, 0)
        }

        if firstPix.suvConverted {
            let maximum = max(Float(firstPix.maxValueOfSeries), 1)
            return (Metal3DDefaults.maxDynamicValue / maximum, 0)
        }

        var minimum = Float(firstPix.minValueOfSeries)
        var maximum = Float(firstPix.maxValueOfSeries)
        for pix in pixList {
            minimum = min(minimum, Float(pix.minValueOfSeries))
            maximum = max(maximum, Float(pix.maxValueOfSeries))
        }

        let range = max(maximum - minimum, 1)
        if range > Metal3DDefaults.maxDynamicValue || range < 50 {
            return (Metal3DDefaults.maxDynamicValue / range, -minimum)
        }

        return (1, -minimum)
    }

    private func makeRawVolume() -> [Float] {
        if let gantryTiltCorrection {
            return makeGantryTiltCorrectedRawVolume(gantryTiltCorrection)
        }

        let sliceElementCount = max(sourceDimensions.x * sourceDimensions.y, 1)
        var converted = [Float](repeating: 0, count: sliceElementCount * max(sourceDimensions.z, 1))
        let fullWidth = max(fullSourceDimensions.x, 1)
        let cropWidth = max(sourceDimensions.x, 1)
        let cropHeight = max(sourceDimensions.y, 1)

        for sourceZ in sourceCropBounds.minZ...sourceCropBounds.maxZ {
            guard sourceZ >= 0, sourceZ < pixList.count else { continue }
            let croppedZ = sourceZ - sourceCropBounds.minZ
            guard croppedZ >= 0, croppedZ < sourceDimensions.z else { continue }
            let pix = pixList[sourceZ]
            pix.checkLoad()
            pix.computePixMinPixMax()
            guard let source = pix.fImage else { continue }

            let destinationOffset = croppedZ * sliceElementCount
            for croppedY in 0..<cropHeight {
                let sourceY = sourceCropBounds.minY + croppedY
                let sourceOffset = sourceY * fullWidth + sourceCropBounds.minX
                let rowDestinationOffset = destinationOffset + croppedY * cropWidth
                for croppedX in 0..<cropWidth {
                    converted[rowDestinationOffset + croppedX] = source[sourceOffset + croppedX]
                }
            }
        }

        if sourceDimensions.x == volumeDimensions.x,
           sourceDimensions.y == volumeDimensions.y,
           sourceDimensions.z == volumeDimensions.z {
            return converted
        }

        return resampleVolumeAlongZ(converted)
    }

    private func makeGantryTiltCorrectedRawVolume(_ correction: MetalViewerGantryTiltGeometry) -> [Float] {
        let backgroundValue: Float = -1024
        for pix in pixList {
            pix.checkLoad()
            pix.computePixMinPixMax()
        }
        let sourceSlices: [UnsafeMutablePointer<Float>?] = pixList.map { $0.fImage }
        let converted = MetalViewerGantryTiltCPUResampler.resample(
            sourceSlices: sourceSlices,
            sourceDimensions: fullSourceDimensions,
            outputDimensions: sourceDimensions,
            outputVoxelToPatientMatrix: correction.correctedVoxelToPatientMatrix,
            sourceVoxelToPatientMatrix: correction.sourceVoxelToPatientMatrix,
            backgroundValue: backgroundValue
        )

        if sourceDimensions.x == volumeDimensions.x,
           sourceDimensions.y == volumeDimensions.y,
           sourceDimensions.z == volumeDimensions.z {
            return converted
        }

        return resampleVolumeAlongZ(converted)
    }

    private func resampleVolumeAlongZ(_ sourceVolume: [Float]) -> [Float] {
        let start = CFAbsoluteTimeGetCurrent()
        let width = max(sourceDimensions.x, 1)
        let height = max(sourceDimensions.y, 1)
        let sourceDepth = max(sourceDimensions.z, 1)
        let outputDepth = max(volumeDimensions.z, 1)
        let sliceElementCount = max(width * height, 1)
        var output = [Float](repeating: 0, count: sliceElementCount * outputDepth)

        guard sourceDepth > 1, outputDepth > 1 else {
            return sourceVolume
        }

        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: outputDepth) { outputZ in
                let physicalZ = Float(outputZ) * voxelSpacing.z
                let sourceZ = min(max(physicalZ / max(sourceVoxelSpacing.z, 0.0001), 0), Float(sourceDepth - 1))
                let baseZ = min(max(Int(floor(sourceZ)), 0), sourceDepth - 1)
                let fraction = sourceZ - Float(baseZ)
                let z0 = min(max(baseZ - 1, 0), sourceDepth - 1)
                let z1 = baseZ
                let z2 = min(baseZ + 1, sourceDepth - 1)
                let z3 = min(baseZ + 2, sourceDepth - 1)
                let offset0 = z0 * sliceElementCount
                let offset1 = z1 * sliceElementCount
                let offset2 = z2 * sliceElementCount
                let offset3 = z3 * sliceElementCount
                let outputOffset = outputZ * sliceElementCount

                if fraction <= 0.0001 {
                    for index in 0..<sliceElementCount {
                        outputBase[outputOffset + index] = sourceVolume[offset1 + index]
                    }
                } else {
                    for index in 0..<sliceElementCount {
                        let sample0 = sourceVolume[offset0 + index]
                        let sample1 = sourceVolume[offset1 + index]
                        let sample2 = sourceVolume[offset2 + index]
                        let sample3 = sourceVolume[offset3 + index]
                        let interpolated = Self.catmullRom(sample0, sample1, sample2, sample3, fraction)
                        let minimum = min(min(sample0, sample1), min(sample2, sample3))
                        let maximum = max(max(sample0, sample1), max(sample2, sample3))
                        outputBase[outputOffset + index] = min(max(interpolated, minimum), maximum)
                    }
                }
            }
        }

        if MetalViewerDiagnostics.isTimingLogEnabled {
            NSLog(
                "HOROS_METAL_TIMING Metal3DVolumeRenderer isotropicZResampleCubic source=%ldx%ldx%ld spacing=%.3fx%.3fx%.3f output=%ldx%ldx%ld spacing=%.3fx%.3fx%.3f %.3f s",
                sourceDimensions.x,
                sourceDimensions.y,
                sourceDimensions.z,
                Double(sourceVoxelSpacing.x),
                Double(sourceVoxelSpacing.y),
                Double(sourceVoxelSpacing.z),
                volumeDimensions.x,
                volumeDimensions.y,
                volumeDimensions.z,
                Double(voxelSpacing.x),
                Double(voxelSpacing.y),
                Double(voxelSpacing.z),
                CFAbsoluteTimeGetCurrent() - start
            )
        }

        return output
    }

    private static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2.0 * p1) +
            (-p0 + p2) * t +
            (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
            (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
        )
    }
}
