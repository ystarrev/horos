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
    private let boxMin: SIMD3<Float>
    private let boxMax: SIMD3<Float>
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

    private var volumeTexture: MTLTexture?
    private var clutTexture: MTLTexture?
    private var opacityTexture: MTLTexture?
    private var preIntegratedTransferTexture: MTLTexture?
    private var drawableSize = CGSize(width: 1, height: 1)
    private var rawVolume = [Float]()
    private var customOpacityControlPoints = [SIMD2<Float>]()

    private(set) var selectedWLPresetName = Metal3DDefaults.defaultWLWW
    private(set) var selectedCLUTName = Metal3DDefaults.noCLUT
    private(set) var selectedOpacityName = Metal3DDefaults.linearOpacity
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

    init(device: MTLDevice, pixList: [DCMPix], volumeData: Data) {
        self.deviceRef = device
        self.pixList = pixList

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
        self.sourceVoxelSpacing = sourceSpacing
        let cropBounds = Self.volumeCropBounds(for: pixList, dimensions: fullSourceDimensions, spacing: sourceSpacing)
        self.sourceCropBounds = cropBounds
        let sourceDimensions = cropBounds.dimensions
        self.sourceDimensions = sourceDimensions
        let textureGeometry = Self.isotropicTextureGeometry(sourceDimensions: sourceDimensions, sourceSpacing: sourceSpacing)
        self.volumeDimensions = textureGeometry.dimensions
        self.voxelSpacing = textureGeometry.spacing
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
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if cropOverlayVisible {
            drawCropOverlay(with: encoder, camera: camera)
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
        applyVTKCompositeOpacityCorrection(to: &values)
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

    private func applyVTKCompositeOpacityCorrection(to values: inout [Float]) {
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

        return cropBounds
    }

    private static func shouldCropAir(for firstPix: DCMPix) -> Bool {
        let modality = firstPix.modalityString?.uppercased() ?? ""
        let rescale = firstPix.rescaleType?.uppercased() ?? ""
        let seriesMinimum = Float(firstPix.minValueOfSeries)
        let seriesMaximum = Float(firstPix.maxValueOfSeries)
        return modality.contains("CT") || rescale == "HU" || (seriesMinimum < -500 && seriesMaximum > 300)
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

        for outputZ in 0..<outputDepth {
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
                    output[outputOffset + index] = sourceVolume[offset1 + index]
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
                    output[outputOffset + index] = min(max(interpolated, minimum), maximum)
                }
            }
        }

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
