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
    var maxSteps: UInt32
    var windowLevel: Float
    var windowWidth: Float
    var boneRenderingOptions: SIMD4<Float>
    var opacityDomainMin: Float
    var opacityDomainMax: Float
    var useRawOpacityCurve: UInt32
    var padding4: UInt32 = 0
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
    private let volumeDimensions: SIMD3<Int>
    private let boxMin: SIMD3<Float>
    private let boxMax: SIMD3<Float>
    private var cropBoxMin = SIMD3<Float>(repeating: -0.28)
    private var cropBoxMax = SIMD3<Float>(repeating: 0.28)
    private let superSampling: Float
    private let valueFactor: Float
    private let offset16: Float
    private let transferTextureWidth = 4096
    private let boneModeEnabled: Bool
    private let shadingAmbient: Float = 0.26
    private let shadingDiffuse: Float = 0.28
    private let shadingSpecular: Float = 0.035
    private let shadingSpecularPower: Float = 36.0
    private let boneLowerHU: Float = 160.0
    private let boneUpperHU: Float = 2200.0
    private let boneSurfaceHU: Float = 300.0
    private let cropHandleRadius: Float = 0.016
    private let histogramDomainMin: Float = -1200.0
    private let histogramDomainMax: Float = 3200.0

    private var volumeTexture: MTLTexture?
    private var clutTexture: MTLTexture?
    private var opacityTexture: MTLTexture?
    private var drawableSize = CGSize(width: 1, height: 1)
    private var rawVolume = [Float]()
    private var customOpacityControlPoints = [SIMD2<Float>]()

    private(set) var selectedWLPresetName = Metal3DDefaults.defaultWLWW
    private(set) var selectedCLUTName = Metal3DDefaults.noCLUT
    private(set) var selectedOpacityName = Metal3DDefaults.linearOpacity
    private(set) var cropEnabled = false
    private(set) var cropOverlayVisible = false
    private(set) var shadingEnabled = UserDefaults.standard.bool(forKey: "defaultShading")

    private var windowLevel: Float = 0
    private var windowWidth: Float = 1
    private var currentCLUTPixels = [SIMD4<UInt8>]()
    private var currentOpacityPoints = [String]()
    private var cameraRotation: simd_quatf
    private var orbitRadius: Float

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
        self.volumeDimensions = SIMD3<Int>(width, height, depth)

        let spacing = Self.voxelSpacing(for: pixList)
        let extent = Self.volumeExtent(dimensions: self.volumeDimensions, spacing: spacing)
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
        self.boneModeEnabled = Self.shouldUseBoneMode(for: firstPix)
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
        applyWLPreset(named: boneModeEnabled ? Metal3DDefaults.fullDynamic : Metal3DDefaults.defaultWLWW)
        applyCLUT(named: defaultCLUTName())
        applyOpacity(named: defaultOpacityName())
        shadingEnabled = boneModeEnabled || shadingEnabled
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let volumeTexture else {
            return
        }

        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        let camera = currentCameraState(for: view.drawableSize)
        var uniforms = makeUniforms(for: view.drawableSize, camera: camera)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Metal3DVolumeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(clutTexture, index: 1)
        encoder.setFragmentTexture(opacityTexture, index: 2)
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
        orbitRadius = min(max(orbitRadius / zoomScale, 0.25), 8.0)
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
        if boneModeEnabled {
            return Metal3DDefaults.noCLUT
        }
        let dictionary = UserDefaults.standard.dictionary(forKey: "CLUT") ?? [:]
        if pixList.first?.isRGB == false, dictionary[Metal3DDefaults.vrBonesCLUT] != nil {
            return Metal3DDefaults.vrBonesCLUT
        }
        return Metal3DDefaults.noCLUT
    }

    private func defaultOpacityName() -> String {
        if boneModeEnabled {
            return Metal3DDefaults.linearOpacity
        }
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
    }

    private func makeUniforms(for drawableSize: CGSize, camera: CameraState) -> Metal3DVolumeUniforms {

        let diagonal = simd_length(boxMax - boxMin)
        let stepSize = max(diagonal / 300.0, 0.0030)
        let density: Float = 10.5
        let alphaFloor: Float = 0.07
        let maxSteps: UInt32 = 768

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
            maxSteps: maxSteps,
            windowLevel: windowLevel,
            windowWidth: windowWidth,
            boneRenderingOptions: boneRenderingOptions(),
            opacityDomainMin: histogramDomainMin,
            opacityDomainMax: histogramDomainMax,
            useRawOpacityCurve: customOpacityControlPoints.isEmpty ? 0 : 1,
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
        let tanHalfFovY = tan(Float(26.0 * .pi / 180.0))
        let nearPlane: Float = 0.01
        let farPlane: Float = 20.0
        let viewMatrix = Self.lookAtMatrix(eye: cameraPosition, center: target, up: cameraUp)
        let projectionMatrix = Self.perspectiveMatrix(
            verticalFov: Float(52.0 * .pi / 180.0),
            aspectRatio: aspectRatio,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
        return CameraState(
            position: cameraPosition,
            forward: cameraForward,
            right: cameraRight,
            up: cameraUp,
            tanHalfFovY: tanHalfFovY,
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
            vertices.append(Metal3DOverlayVertex(position: corners[start]))
            vertices.append(Metal3DOverlayVertex(position: corners[end]))
        }
        return vertices
    }

    private func makeCropHandleSphereVertices() -> [Metal3DOverlayVertex] {
        let cropCenter = 0.5 * (cropBoxMin + cropBoxMax)
        let centers: [SIMD3<Float>] = [
            SIMD3<Float>(cropBoxMin.x, cropCenter.y, cropCenter.z),
            SIMD3<Float>(cropBoxMax.x, cropCenter.y, cropCenter.z),
            SIMD3<Float>(cropCenter.x, cropBoxMin.y, cropCenter.z),
            SIMD3<Float>(cropCenter.x, cropBoxMax.y, cropCenter.z),
            SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMin.z),
            SIMD3<Float>(cropCenter.x, cropCenter.y, cropBoxMax.z),
        ]
        let latitudes = 8
        let longitudes = 12
        var vertices = [Metal3DOverlayVertex]()
        for center in centers {
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

                    vertices.append(Metal3DOverlayVertex(position: p00))
                    vertices.append(Metal3DOverlayVertex(position: p10))
                    vertices.append(Metal3DOverlayVertex(position: p11))
                    vertices.append(Metal3DOverlayVertex(position: p00))
                    vertices.append(Metal3DOverlayVertex(position: p11))
                    vertices.append(Metal3DOverlayVertex(position: p01))
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

    private static func perspectiveMatrix(verticalFov: Float, aspectRatio: Float, nearPlane: Float, farPlane: Float) -> simd_float4x4 {
        let yScale = 1 / tan(verticalFov * 0.5)
        let xScale = yScale / aspectRatio
        let zRange = farPlane - nearPlane
        let zScale = farPlane / (nearPlane - farPlane)
        let wzScale = (farPlane * nearPlane) / (nearPlane - farPlane)
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private func isOccludedByVolume(point: SIMD3<Float>, camera: CameraState, allowance: Float) -> Bool {
        guard boneModeEnabled else { return false }

        let toPoint = point - camera.position
        let targetDistance = simd_length(toPoint)
        guard targetDistance > 0.0001 else { return false }

        let rayDirection = toPoint / targetDistance
        guard let intersection = intersectBox(rayOrigin: camera.position, rayDirection: rayDirection, boxMin: boxMin, boxMax: boxMax) else {
            return false
        }

        let diagonal = simd_length(boxMax - boxMin)
        let step = max(diagonal / 600.0, 0.0015)
        let endDistance = min(intersection.tMax, targetDistance)
        var t = max(intersection.tMin, 0)
        var previousScalar: Float?

        while t <= endDistance {
            let worldPoint = camera.position + rayDirection * t
            let scalar = sampleVolume(worldPoint: worldPoint)
            if scalar >= boneLowerHU, scalar <= boneUpperHU {
                let crossed = previousScalar == nil ? scalar >= boneSurfaceHU : (previousScalar! < boneSurfaceHU && scalar >= boneSurfaceHU)
                if crossed && t < targetDistance - max(allowance, step * 0.5) {
                    return true
                }
            }
            previousScalar = scalar
            t += step
        }

        return false
    }

    private func intersectBox(rayOrigin: SIMD3<Float>, rayDirection: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> (tMin: Float, tMax: Float)? {
        let safeDirection = SIMD3<Float>(
            abs(rayDirection.x) < 1e-5 ? 1e-5 : rayDirection.x,
            abs(rayDirection.y) < 1e-5 ? 1e-5 : rayDirection.y,
            abs(rayDirection.z) < 1e-5 ? 1e-5 : rayDirection.z
        )
        let inverseDirection = 1.0 / safeDirection
        let t0 = (boxMin - rayOrigin) * inverseDirection
        let t1 = (boxMax - rayOrigin) * inverseDirection
        let tSmall = simd.min(t0, t1)
        let tLarge = simd.max(t0, t1)
        let tMin = max(max(tSmall.x, tSmall.y), tSmall.z)
        let tMax = min(min(tLarge.x, tLarge.y), tLarge.z)
        return tMax >= max(tMin, 0) ? (tMin, tMax) : nil
    }

    private func sampleVolume(worldPoint: SIMD3<Float>) -> Float {
        let normalized = (worldPoint - boxMin) / (boxMax - boxMin)
        let clamped = simd_clamp(normalized, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

        let fx = clamped.x * Float(max(volumeDimensions.x - 1, 1))
        let fy = clamped.y * Float(max(volumeDimensions.y - 1, 1))
        let fz = clamped.z * Float(max(volumeDimensions.z - 1, 1))

        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let z0 = Int(floor(fz))
        let x1 = min(x0 + 1, max(volumeDimensions.x - 1, 0))
        let y1 = min(y0 + 1, max(volumeDimensions.y - 1, 0))
        let z1 = min(z0 + 1, max(volumeDimensions.z - 1, 0))

        let tx = fx - Float(x0)
        let ty = fy - Float(y0)
        let tz = fz - Float(z0)

        let c000 = voxelValue(x: x0, y: y0, z: z0)
        let c100 = voxelValue(x: x1, y: y0, z: z0)
        let c010 = voxelValue(x: x0, y: y1, z: z0)
        let c110 = voxelValue(x: x1, y: y1, z: z0)
        let c001 = voxelValue(x: x0, y: y0, z: z1)
        let c101 = voxelValue(x: x1, y: y0, z: z1)
        let c011 = voxelValue(x: x0, y: y1, z: z1)
        let c111 = voxelValue(x: x1, y: y1, z: z1)

        let c00 = c000 + (c100 - c000) * tx
        let c10 = c010 + (c110 - c010) * tx
        let c01 = c001 + (c101 - c001) * tx
        let c11 = c011 + (c111 - c011) * tx
        let c0 = c00 + (c10 - c00) * ty
        let c1 = c01 + (c11 - c01) * ty
        return c0 + (c1 - c0) * tz
    }

    private func voxelValue(x: Int, y: Int, z: Int) -> Float {
        let clampedX = min(max(x, 0), max(volumeDimensions.x - 1, 0))
        let clampedY = min(max(y, 0), max(volumeDimensions.y - 1, 0))
        let clampedZ = min(max(z, 0), max(volumeDimensions.z - 1, 0))
        let sliceStride = max(volumeDimensions.x * volumeDimensions.y, 1)
        let index = clampedZ * sliceStride + clampedY * max(volumeDimensions.x, 1) + clampedX
        return rawVolume[index]
    }

    private func project(point: SIMD3<Float>, camera: CameraState, in bounds: CGRect) -> CGPoint? {
        let relative = point - camera.position
        let depth = simd_dot(relative, camera.forward)
        guard depth > 0.0001 else { return nil }

        let x = simd_dot(relative, camera.right) / (depth * camera.aspectRatio * camera.tanHalfFovY)
        let y = simd_dot(relative, camera.up) / (depth * camera.tanHalfFovY)

        let screenX = bounds.minX + CGFloat((x * 0.5 + 0.5)) * bounds.width
        let screenY = bounds.minY + CGFloat((y * 0.5 + 0.5)) * bounds.height
        return CGPoint(x: screenX, y: screenY)
    }

    func setShadingEnabled(_ enabled: Bool) {
        shadingEnabled = enabled
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
        opacityTexture = makeOpacityTransferTexture()
    }

    private func boneRenderingOptions() -> SIMD4<Float> {
        guard boneModeEnabled else {
            return .zero
        }

        let lower = boneLowerHU
        let upper = boneUpperHU
        let surface = boneSurfaceHU
        guard upper > lower, surface > lower, surface < upper else {
            return .zero
        }

        return SIMD4<Float>(1, lower, upper, surface)
    }

    private static func shouldUseBoneMode(for firstPix: DCMPix) -> Bool {
        let modality = firstPix.modalityString?.uppercased() ?? ""
        let rescale = firstPix.rescaleType?.uppercased() ?? ""
        let seriesMinimum = Float(firstPix.minValueOfSeries)
        let seriesMaximum = Float(firstPix.maxValueOfSeries)
        let looksLikeCTRange = seriesMinimum < 200 && seriesMaximum > 1200
        return modality.contains("CT") || rescale == "HU" || (firstPix.isRGB == false && looksLikeCTRange)
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
        let start = valueFactor * (offset16 + windowLevel - windowWidth * 0.5)
        let end = valueFactor * (offset16 + windowLevel + windowWidth * 0.5)
        let span = max(end - start, 0.0001)
        let textureDomainScale = Metal3DDefaults.maxDynamicValue / Float(max(width - 1, 1))

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
                let convertedSample = Float(index) * textureDomainScale
                let clamped = min(max((convertedSample - start) / span, 0), 1)
                values[index] = clamped / superSampling
            }
        } else {
            var points = [(x: Float, y: Float)]()
            for string in currentOpacityPoints {
                var point = NSPointFromString(string)
                point.x -= 1000
                let mappedX = start + (Float(point.x) / 256.0) * span
                points.append((x: mappedX, y: Float(point.y) / superSampling))
            }

            for index in 0..<width {
                let sample = Float(index) * textureDomainScale
                if sample <= start {
                    values[index] = 0
                    continue
                }
                if sample >= end {
                    values[index] = points.last?.y ?? (1.0 / superSampling)
                    continue
                }

                if let first = points.first, sample <= first.x {
                    values[index] = first.x > start ? ((sample - start) / max(first.x - start, 0.0001)) * first.y : first.y
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
                    values[index] = last + (1.0 / superSampling - last) * ((sample - (points.last?.x ?? end)) / max(end - (points.last?.x ?? end), 0.0001))
                }
            }
        }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return makeFloat1DTexture(data: data, width: values.count)
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
        let start = valueFactor * (offset16 + windowLevel - windowWidth * 0.5)
        let end = valueFactor * (offset16 + windowLevel + windowWidth * 0.5)
        let span = max(end - start, 0.0001)
        let textureDomainScale = Metal3DDefaults.maxDynamicValue / Float(max(width - 1, 1))

        for index in 0..<width {
            let sample = Float(index) * textureDomainScale
            let normalized = min(max((sample - start) / span, 0), 1)
            let lutIndex = min(max(Int((normalized * 255.0).rounded()), 0), 255)
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

    private static func volumeExtent(dimensions: SIMD3<Int>, spacing: SIMD3<Float>) -> SIMD3<Float> {
        let rawExtent = SIMD3<Float>(
            max(Float(dimensions.x - 1), 1) * spacing.x,
            max(Float(dimensions.y - 1), 1) * spacing.y,
            max(Float(dimensions.z - 1), 1) * spacing.z
        )
        let maxComponent = max(max(rawExtent.x, rawExtent.y), max(rawExtent.z, 1))
        return rawExtent / maxComponent
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
        let sliceElementCount = max(volumeDimensions.x * volumeDimensions.y, 1)
        var converted = [Float](repeating: 0, count: sliceElementCount * max(volumeDimensions.z, 1))

        for (sliceIndex, pix) in pixList.enumerated() {
            pix.checkLoad()
            pix.computePixMinPixMax()
            guard let source = pix.fImage else { continue }

            let destinationOffset = sliceIndex * sliceElementCount
            for elementIndex in 0..<sliceElementCount {
                converted[destinationOffset + elementIndex] = source[elementIndex]
            }
        }

        return converted
    }
}
