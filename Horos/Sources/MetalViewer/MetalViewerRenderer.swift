import Foundation
import Dispatch
import Metal
import MetalKit
import simd

private let registrationHistogramBins = 64
private let useGPUPyramidGeneration = true

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

private struct SlabGeometry {
    let normalWorld: SIMD3<Float>
    let thicknessMM: Float
}

private struct MetalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

final class MetalViewerRenderer: NSObject, MTKViewDelegate {
    private let deviceRef: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let registrationPipelineState: MTLComputePipelineState
    private let gaussianBlurPipelineState: MTLComputePipelineState
    private let downsamplePipelineState: MTLComputePipelineState
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    private(set) var pixList: [DCMPix]
    private var overlayPixList: [DCMPix] = []
    private var baseTexture: MTLTexture?
    private var baseVolumeTexture: MTLTexture?
    private var overlayVolumeTexture: MTLTexture?
    private var baseVolumeData: [Float] = []
    private var overlayVolumeData: [Float] = []
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
    private var registrationGeneration: UInt = 0
    private var registrationInProgress = false
    private var registrationProgress: Float = 0
    private var registrationStatusMessage: String?

    var stateDidChange: ((String) -> Void)?
    var registrationDidChange: ((Bool, String, Float) -> Void)?
    var windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)?

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
        let sliceText = pixList.count > 1 ? "Slice \(currentSliceIndex + 1)/\(pixList.count)" : "Slice 1/1"
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
              let registrationFunction = library.makeFunction(name: "metalViewerRegistrationJointHistogram"),
              let gaussianBlurFunction = library.makeFunction(name: "metalViewerGaussianBlur3D"),
              let downsampleFunction = library.makeFunction(name: "metalViewerDownsample3D") else {
            fatalError("Could not load Metal shader functions.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            registrationPipelineState = try device.makeComputePipelineState(function: registrationFunction)
            gaussianBlurPipelineState = try device.makeComputePipelineState(function: gaussianBlurFunction)
            downsamplePipelineState = try device.makeComputePipelineState(function: downsampleFunction)
        } catch {
            fatalError("Could not create Metal pipeline: \(error)")
        }

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
    }

    func setOverlayPixList(_ overlayPixList: [DCMPix]) {
        self.overlayPixList = overlayPixList
        prepareBaseVolumeIfNeeded()
        let movingVoxelToWorld = volumeVoxelToWorldMatrix(for: overlayPixList)
        let fullResolutionVolume = makeVolumeData(for: overlayPixList)
        overlayVolumeData = fullResolutionVolume.data
        overlayVolumeDimensions = fullResolutionVolume.dimensions
        let overlayRegistrationWindow = registrationWindow(for: fullResolutionVolume.data, pixList: overlayPixList)
        overlayRegistrationWindowLevel = overlayRegistrationWindow.level
        overlayRegistrationWindowWidth = overlayRegistrationWindow.width
        overlayVolumeCenterWorld = volumeCenterWorld(for: overlayPixList, voxelToWorld: movingVoxelToWorld)
        overlayInformativeCenterWorld = informativeCenterWorld(
            for: fullResolutionVolume.data,
            dimensions: fullResolutionVolume.dimensions,
            voxelToWorld: movingVoxelToWorld,
            level: overlayRegistrationWindow.level,
            width: overlayRegistrationWindow.width
        )
        overlayIsThinSlab = isThinSlab(dimensions: fullResolutionVolume.dimensions, voxelToWorld: movingVoxelToWorld)
        overlaySlabGeometry = overlayIsThinSlab ? slabGeometry(dimensions: fullResolutionVolume.dimensions, voxelToWorld: movingVoxelToWorld) : nil
        overlayVolumeTexture = makeTexture3D(from: fullResolutionVolume.data, dimensions: fullResolutionVolume.dimensions)
        overlayVolumeLevels = makeVolumeLevels(
            from: fullResolutionVolume.data,
            dimensions: fullResolutionVolume.dimensions,
            baseVoxelToWorld: movingVoxelToWorld
        )
        movingWorldToVoxel = simd_inverse(movingVoxelToWorld)
        movingRotationCenterWorld = volumeCenterWorld(for: overlayPixList, voxelToWorld: movingVoxelToWorld)
        overlayTranslationWorld = .zero
        overlayRotationRadians = .zero
        overlayTranslationPixels = .zero
        loadSlice(at: currentSliceIndex)
        runRegistration()
    }

    func clearOverlayPixList() {
        overlayPixList = []
        overlayVolumeTexture = nil
        overlayVolumeData = []
        overlayVolumeDimensions = SIMD3<Int>(repeating: 1)
        overlayVolumeLevels = []
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
    }

    func updateWindowLevel(wl: Float, ww: Float) {
        let window = MetalViewerWindowLevel(level: wl, width: max(1, ww))
        applyWindowLevel(window)
        customSeriesWindowLevel = window
        notifyWindowLevelStateDidChange()
        stateDidChange?(stateDescription)
    }

    func applyWindowLevel(_ window: MetalViewerWindowLevel, asCustom: Bool) {
        applyWindowLevel(window)
        if asCustom {
            customSeriesWindowLevel = window
        } else {
            defaultSeriesWindowLevel = window
            customSeriesWindowLevel = nil
        }
        notifyWindowLevelStateDidChange()
        stateDidChange?(stateDescription)
    }

    func applyDefaultWindowLevelPreset() {
        guard pixList.indices.contains(currentSliceIndex) else { return }
        let pix = pixList[currentSliceIndex]
        let width = pix.savedWW > 0 ? pix.savedWW : windowLevelDefaults(for: pix).width
        let level = pix.savedWW > 0 ? pix.savedWL : windowLevelDefaults(for: pix).level
        applyWindowLevel(MetalViewerWindowLevel(level: level, width: width), asCustom: false)
    }

    func applyFullDynamicWindowLevelPreset() {
        guard pixList.indices.contains(currentSliceIndex) else { return }
        let pix = pixList[currentSliceIndex]
        applyWindowLevel(MetalViewerWindowLevel(level: pix.fullwl, width: max(1, pix.fullww)), asCustom: false)
    }

    func applyRobustSeriesWindowLevelPreset() {
        guard pixList.indices.contains(currentSliceIndex) else { return }
        let window = robustSeriesWindowLevel() ?? windowLevelDefaults(for: pixList[currentSliceIndex])
        applyWindowLevel(window, asCustom: false)
    }

    func commitWindowLevel() {
        stateDidChange?(stateDescription)
    }

    func resetWindowLevel() {
        guard pixList.indices.contains(currentSliceIndex) else { return }
        customSeriesWindowLevel = nil
        let defaultWindow = defaultSeriesWindowLevel ?? windowLevelDefaults(for: pixList[currentSliceIndex])
        defaultSeriesWindowLevel = defaultWindow
        applyWindowLevel(defaultWindow)
        notifyWindowLevelStateDidChange()
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
        let loadSliceStart = CFAbsoluteTimeGetCurrent()
        guard pixList.indices.contains(index) else { return }
        let pix = pixList[index]

        let checkLoadStart = CFAbsoluteTimeGetCurrent()
        pix.checkLoad()
        metalRendererTimingLog("MetalViewerRenderer pix.checkLoad slice \(index)", since: checkLoadStart)
        let minMaxStart = CFAbsoluteTimeGetCurrent()
        pix.computePixMinPixMax()
        metalRendererTimingLog("MetalViewerRenderer computePixMinPixMax slice \(index)", since: minMaxStart)

        let width = max(Int(pix.pwidth), 1)
        let height = max(Int(pix.pheight), 1)
        imageAspectRatio = Float(width) * Float(max(pix.pixelSpacingX, 1)) / max(Float(height) * Float(max(pix.pixelSpacingY, 1)), 1)

        let textureStart = CFAbsoluteTimeGetCurrent()
        guard let texture = makeTexture(for: pix) else {
            return
        }
        metalRendererTimingLog("MetalViewerRenderer makeTexture slice \(index)", since: textureStart)
        baseTexture = texture

        if let customWindow = customSeriesWindowLevel {
            applyWindowLevel(customWindow)
        } else if let defaultWindow = defaultSeriesWindowLevel {
            applyWindowLevel(defaultWindow)
        } else {
            let defaultWindow = windowLevelDefaults(for: pix)
            defaultSeriesWindowLevel = defaultWindow
            applyWindowLevel(defaultWindow)
            notifyWindowLevelStateDidChange()
        }

        if let overlayPix = currentOverlayPix {
            let overlayCheckLoadStart = CFAbsoluteTimeGetCurrent()
            overlayPix.checkLoad()
            metalRendererTimingLog("MetalViewerRenderer overlay pix.checkLoad slice \(index)", since: overlayCheckLoadStart)
            let overlayMinMaxStart = CFAbsoluteTimeGetCurrent()
            overlayPix.computePixMinPixMax()
            metalRendererTimingLog("MetalViewerRenderer overlay computePixMinPixMax slice \(index)", since: overlayMinMaxStart)

            let overlayDefaultWW = overlayPix.ww > 0 ? overlayPix.ww : overlayPix.fullww
            let overlayDefaultWL = overlayPix.wl != 0 ? overlayPix.wl : overlayPix.fullwl
            overlayWindowWidth = max(1, overlayDefaultWW)
            overlayWindowLevel = overlayDefaultWL
            overlayTranslationPixels = currentOverlayTranslationPixels()
        } else {
            overlayWindowWidth = 1
            overlayWindowLevel = 0
            overlayTranslationPixels = .zero
        }

        stateDidChange?(stateDescription)
        metalRendererTimingLog("MetalViewerRenderer loadSlice \(index) total", since: loadSliceStart)
    }

    private func windowLevelDefaults(for pix: DCMPix) -> MetalViewerWindowLevel {
        let modality = pix.modalityString?.uppercased() ?? ""
        if modality == "MR",
           pix.savedWW <= 0,
           pix.ww <= 0,
           let robustWindow = robustSeriesWindowLevel() {
            return robustWindow
        }

        let defaultWW = pix.ww > 0 ? pix.ww : pix.fullww
        let defaultWL = pix.wl != 0 ? pix.wl : pix.fullwl
        return MetalViewerWindowLevel(level: defaultWL, width: max(1, defaultWW))
    }

    private func robustSeriesWindowLevel() -> MetalViewerWindowLevel? {
        guard pixList.isEmpty == false else { return nil }

        let maxSliceSamples = 17
        let sliceStep = max(1, pixList.count / maxSliceSamples)
        var sliceIndexes = Array(stride(from: 0, to: pixList.count, by: sliceStep))
        if let lastIndex = pixList.indices.last, sliceIndexes.contains(lastIndex) == false {
            sliceIndexes.append(lastIndex)
        }

        var samples: [Float] = []
        samples.reserveCapacity(80_000)

        for sliceIndex in sliceIndexes {
            let pix = pixList[sliceIndex]
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

    private func applyWindowLevel(_ window: MetalViewerWindowLevel) {
        windowLevel = window.level
        windowWidth = max(1, window.width)
    }

    private func notifyWindowLevelStateDidChange() {
        windowLevelStateDidChange?(
            MetalViewerWindowLevelState(
                defaultWindow: defaultSeriesWindowLevel,
                customWindow: customSeriesWindowLevel
            )
        )
    }

    private func prepareBaseVolumeIfNeeded() {
        let prepareStart = CFAbsoluteTimeGetCurrent()
        guard baseVolumeTexture == nil else { return }
        let geometryStart = CFAbsoluteTimeGetCurrent()
        fixedVoxelToWorld = volumeVoxelToWorldMatrix(for: pixList)
        metalRendererTimingLog("MetalViewerRenderer volume geometry", since: geometryStart)
        let volumeDataStart = CFAbsoluteTimeGetCurrent()
        let fullResolutionVolume = makeVolumeData(for: pixList)
        metalRendererTimingLog("MetalViewerRenderer makeVolumeData", since: volumeDataStart)
        baseVolumeData = fullResolutionVolume.data
        baseVolumeDimensions = fullResolutionVolume.dimensions
        let registrationWindowStart = CFAbsoluteTimeGetCurrent()
        let baseRegistrationWindow = registrationWindow(for: fullResolutionVolume.data, pixList: pixList)
        metalRendererTimingLog("MetalViewerRenderer registrationWindow", since: registrationWindowStart)
        baseRegistrationWindowLevel = baseRegistrationWindow.level
        baseRegistrationWindowWidth = baseRegistrationWindow.width
        baseVolumeCenterWorld = volumeCenterWorld(for: pixList, voxelToWorld: fixedVoxelToWorld)
        let informativeStart = CFAbsoluteTimeGetCurrent()
        baseInformativeCenterWorld = informativeCenterWorld(
            for: fullResolutionVolume.data,
            dimensions: fullResolutionVolume.dimensions,
            voxelToWorld: fixedVoxelToWorld,
            level: baseRegistrationWindow.level,
            width: baseRegistrationWindow.width
        )
        metalRendererTimingLog("MetalViewerRenderer informativeCenterWorld", since: informativeStart)
        baseIsThinSlab = isThinSlab(dimensions: fullResolutionVolume.dimensions, voxelToWorld: fixedVoxelToWorld)
        baseSlabGeometry = baseIsThinSlab ? slabGeometry(dimensions: fullResolutionVolume.dimensions, voxelToWorld: fixedVoxelToWorld) : nil
        let texture3DStart = CFAbsoluteTimeGetCurrent()
        baseVolumeTexture = makeTexture3D(from: fullResolutionVolume.data, dimensions: fullResolutionVolume.dimensions)
        metalRendererTimingLog("MetalViewerRenderer makeTexture3D base", since: texture3DStart)
        let levelsStart = CFAbsoluteTimeGetCurrent()
        baseVolumeLevels = makeVolumeLevels(
            from: fullResolutionVolume.data,
            dimensions: fullResolutionVolume.dimensions,
            baseVoxelToWorld: fixedVoxelToWorld
        )
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

    private func makeVolumeData(for pixList: [DCMPix]) -> (data: [Float], dimensions: SIMD3<Int>) {
        let makeVolumeStart = CFAbsoluteTimeGetCurrent()
        guard let firstPix = pixList.first else {
            return ([Float](), SIMD3<Int>(1, 1, 1))
        }
        
        let width = max(Int(firstPix.pwidth), 1)
        let height = max(Int(firstPix.pheight), 1)
        let depth = max(pixList.count, 1)
        let sliceElementCount = width * height
        var volume = [Float](repeating: 0, count: sliceElementCount * depth)
        var loadedImagePointers = Array<UnsafeMutablePointer<Float>?>(repeating: nil, count: depth)

        for (sliceIndex, pix) in pixList.enumerated() {
            let sliceLoadStart = CFAbsoluteTimeGetCurrent()
            pix.checkLoad()
            pix.computePixMinPixMax()
            loadedImagePointers[sliceIndex] = pix.fImage
            if sliceIndex < 3 || sliceIndex == depth - 1 {
                metalRendererTimingLog("MetalViewerRenderer makeVolumeData load source slice \(sliceIndex)", since: sliceLoadStart)
            }
        }

        let copyStart = CFAbsoluteTimeGetCurrent()
        volume.withUnsafeMutableBufferPointer { destinationBuffer in
            guard let destinationBase = destinationBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: depth) { sliceIndex in
                guard let imagePointer = loadedImagePointers[sliceIndex] else { return }
                let destinationOffset = sliceIndex * sliceElementCount
                for elementIndex in 0..<sliceElementCount {
                    destinationBase[destinationOffset + elementIndex] = imagePointer[elementIndex]
                }
            }
        }
        metalRendererTimingLog("MetalViewerRenderer makeVolumeData copy \(depth) slices", since: copyStart)
        metalRendererTimingLog("MetalViewerRenderer makeVolumeData total \(width)x\(height)x\(depth)", since: makeVolumeStart)

        return (volume, SIMD3<Int>(width, height, depth))
    }

    private func registrationWindow(for volume: [Float], pixList: [DCMPix]) -> (level: Float, width: Float) {
        guard volume.isEmpty == false else { return (0, 1) }

        let isCT = pixList.first?.modalityString?.uppercased().contains("CT") == true
        let lowerPercentile: Float = isCT ? 0.005 : 0.01
        let upperPercentile: Float = isCT ? 0.995 : 0.99
        let maxSamples = 262_144
        let stride = max(volume.count / maxSamples, 1)

        var samples = [Float]()
        samples.reserveCapacity((volume.count + stride - 1) / stride)
        var index = 0
        while index < volume.count {
            let value = volume[index]
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
        let level = lowerValue + width * 0.5
        return (level, width)
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

    private func makeVolumeLevels(from fullData: [Float], dimensions: SIMD3<Int>, baseVoxelToWorld: simd_float4x4) -> [VolumeLevel] {
        if useGPUPyramidGeneration,
           let fullTexture = makeTexture3D(from: fullData, dimensions: dimensions),
           let gpuLevels = makeVolumeLevelsGPU(from: fullTexture, dimensions: dimensions, baseVoxelToWorld: baseVoxelToWorld) {
            return gpuLevels
        }

        return makeVolumeLevelsCPU(from: fullData, dimensions: dimensions, baseVoxelToWorld: baseVoxelToWorld)
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

        guard let halfTexture = gaussianDownsampleTexture3D(source: fullTexture, dimensions: dimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld)),
              let quarterTexture = gaussianDownsampleTexture3D(source: halfTexture, dimensions: halfDimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld * scaleMatrix(factor: 2))),
              let eighthTexture = gaussianDownsampleTexture3D(source: quarterTexture, dimensions: quarterDimensions, voxelSpacing: voxelSpacing(from: baseVoxelToWorld * scaleMatrix(factor: 4))) else {
            return nil
        }

        let texturesByFactor: [Int: (MTLTexture, SIMD3<Int>)] = [
            1: (fullTexture, dimensions),
            2: (halfTexture, halfDimensions),
            4: (quarterTexture, quarterDimensions),
            8: (eighthTexture, eighthDimensions),
        ]

        return factors.compactMap { factor in
            guard let entry = texturesByFactor[factor] else { return nil }
            return VolumeLevel(texture: entry.0, voxelToWorld: baseVoxelToWorld * scaleMatrix(factor: factor))
        }
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

    private func volumeVoxelToWorldMatrix(for pixList: [DCMPix]) -> simd_float4x4 {
        guard let firstPix = pixList.first else {
            return matrix_identity_float4x4
        }

        let orientation = orientationVector(for: firstPix)
        let row = simd_normalize(SIMD3<Float>(orientation[0], orientation[1], orientation[2]))
        let column = simd_normalize(SIMD3<Float>(orientation[3], orientation[4], orientation[5]))
        let fallbackNormal = simd_normalize(simd_cross(row, column))

        let sliceStep: SIMD3<Float>
        if pixList.count > 1 {
            let nextPix = pixList[1]
            let delta = SIMD3<Float>(
                Float(nextPix.originX - firstPix.originX),
                Float(nextPix.originY - firstPix.originY),
                Float(nextPix.originZ - firstPix.originZ)
            )
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

    private func informativeCenterWorld(
        for volume: [Float],
        dimensions: SIMD3<Int>,
        voxelToWorld: simd_float4x4,
        level: Float,
        width: Float
    ) -> SIMD3<Float> {
        guard volume.isEmpty == false else { return .zero }

        let normalizedThreshold: Float = 0.18
        let sliceElementCount = max(dimensions.x * dimensions.y, 1)
        let maxSamples = 200_000
        let strideX = max(dimensions.x / 96, 1)
        let strideY = max(dimensions.y / 96, 1)
        let strideZ = max(dimensions.z / 96, 1)
        let adaptiveStride = max(Int(sqrt(Double(max(volume.count / maxSamples, 1)))), 1)
        let sampleStrideX = max(strideX, adaptiveStride)
        let sampleStrideY = max(strideY, adaptiveStride)
        let sampleStrideZ = max(strideZ, adaptiveStride)

        var weightedWorld = SIMD3<Float>(repeating: 0)
        var totalWeight: Float = 0

        for z in stride(from: 0, to: max(dimensions.z, 1), by: sampleStrideZ) {
            for y in stride(from: 0, to: max(dimensions.y, 1), by: sampleStrideY) {
                for x in stride(from: 0, to: max(dimensions.x, 1), by: sampleStrideX) {
                    let index = z * sliceElementCount + y * dimensions.x + x
                    guard index < volume.count else { continue }

                    let value = volume[index]
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
        guard baseVolumeData.isEmpty == false,
              overlayVolumeData.isEmpty == false else {
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

        registrationGeneration += 1
        let generation = registrationGeneration
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
            let result = self.optimizeOverlayTransform(startingAt: initialGuess, generation: generation)

            DispatchQueue.main.async {
                guard generation == self.registrationGeneration else { return }
                self.publishRegistrationUpdate(
                    state: result.state,
                    inProgress: false,
                    progress: 1,
                    message: "Registered 3D",
                    residualError: result.metric,
                    generation: generation
                )
            }
        }
    }

    private func optimizeOverlayTransform(startingAt initialGuess: RigidTransformState, generation: UInt) -> (state: RigidTransformState, metric: Float) {
        struct RigidStep {
            let translationMM: Float
            let rotationRadians: Float
            let maxIterations: Int
            let allowsRotation: Bool
        }

        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let rigidSteps: [RigidStep] = slabAwareRegistration
            ? [
                RigidStep(translationMM: 12, rotationRadians: 0, maxIterations: 24, allowsRotation: false),
                RigidStep(translationMM: 8, rotationRadians: 0, maxIterations: 20, allowsRotation: false),
                RigidStep(translationMM: 6, rotationRadians: 2 * .pi / 180, maxIterations: 20, allowsRotation: true),
                RigidStep(translationMM: 4, rotationRadians: 1.2 * .pi / 180, maxIterations: 18, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.6 * .pi / 180, maxIterations: 16, allowsRotation: true),
                RigidStep(translationMM: 1, rotationRadians: 0.25 * .pi / 180, maxIterations: 14, allowsRotation: true)
            ]
            : [
                RigidStep(translationMM: 40, rotationRadians: 12 * .pi / 180, maxIterations: 32, allowsRotation: true),
                RigidStep(translationMM: 20, rotationRadians: 6 * .pi / 180, maxIterations: 28, allowsRotation: true),
                RigidStep(translationMM: 10, rotationRadians: 3 * .pi / 180, maxIterations: 24, allowsRotation: true),
                RigidStep(translationMM: 5, rotationRadians: 1.5 * .pi / 180, maxIterations: 20, allowsRotation: true),
                RigidStep(translationMM: 2, rotationRadians: 0.75 * .pi / 180, maxIterations: 18, allowsRotation: true),
                RigidStep(translationMM: 1, rotationRadians: 0.35 * .pi / 180, maxIterations: 16, allowsRotation: true)
            ]

        let levelPairs = Array(zip(baseVolumeLevels, overlayVolumeLevels))
        guard levelPairs.isEmpty == false else { return (initialGuess, .greatestFiniteMagnitude) }
        var best = initialGuess
        let firstUseBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: 0, totalLevels: levelPairs.count)
        var bestMetric = metricValue(
            for: initialGuess,
            level: levelPairs[0],
            levelIndex: 0,
            totalLevels: levelPairs.count,
            useBoneOnly: firstUseBoneOnly
        )

        for (levelIndex, levelPair) in levelPairs.enumerated() {
            let useBoneOnly = shouldUseBoneOnlyMetric(forLevelIndex: levelIndex, totalLevels: levelPairs.count)

            for (stepIndex, step) in rigidSteps.enumerated() {
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
                    totalSteps: rigidSteps.count
                )
                best = result.state
                bestMetric = result.metric

                let completedStages = Float(levelIndex * rigidSteps.count + stepIndex + 1)
                let progress = completedStages / Float(levelPairs.count * rigidSteps.count)
                publishRegistrationUpdate(
                    state: best,
                    inProgress: true,
                    progress: progress,
                    message: "Registering 3D L\(levelIndex + 1)/\(levelPairs.count)",
                    residualError: bestMetric,
                    generation: generation
                )
            }
        }

        return (best, bestMetric)
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

            let completedStages = Float(levelIndex * totalSteps + stepIndex)
            let iterationFraction = Float(iteration) / Float(max(maxIterations, 1))
            let progress = (completedStages + 0.1 + iterationFraction * 0.8) / Float(totalLevels * totalSteps)
            publishRegistrationUpdate(
                state: bestState,
                inProgress: true,
                progress: progress,
                message: "Registering 3D L\(levelIndex + 1)/\(totalLevels)",
                residualError: bestMetric,
                generation: generation
            )

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

            if parameterSpan < Swift.max(translationMM * 0.25, rotationRadians * 0.25) && metricSpan < 0.0001 {
                break
            }
        }

        sortSimplex()
        return (state(for: simplex[0].parameters), simplex[0].metric)
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
        let baseVolumeTexture = level.0.texture
        let overlayVolumeTexture = level.1.texture

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 4)
        let threadgroups = MTLSize(
            width: (baseVolumeTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (baseVolumeTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: (baseVolumeTexture.depth + threadsPerGroup.depth - 1) / threadsPerGroup.depth
        )
        let histogramEntryCount = registrationHistogramBins * registrationHistogramBins + 1
        let histogramBufferLength = histogramEntryCount * MemoryLayout<UInt32>.stride

        guard let histogramBuffer = deviceRef.makeBuffer(length: histogramBufferLength, options: .storageModeShared) else {
            return .greatestFiniteMagnitude
        }
        memset(histogramBuffer.contents(), 0, histogramBufferLength)

        var uniforms = RegistrationUniforms(
            baseWindowLevel: baseRegistrationWindowLevel,
            baseWindowWidth: max(baseRegistrationWindowWidth, 1),
            overlayWindowLevel: overlayRegistrationWindowLevel,
            overlayWindowWidth: max(overlayRegistrationWindowWidth, 1),
            metricOptions: metricOptions(forLevelIndex: levelIndex, totalLevels: totalLevels, useBoneOnly: useBoneOnly),
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

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let histogram = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: histogramEntryCount)
        let overlapCount = Int(histogram[histogramEntryCount - 1])
        guard overlapCount > 0 else {
            return .greatestFiniteMagnitude
        }

        var baseMarginal = [Double](repeating: 0, count: registrationHistogramBins)
        var overlayMarginal = [Double](repeating: 0, count: registrationHistogramBins)
        var jointEntropy: Double = 0
        let overlapTotal = Double(overlapCount)

        for overlayBin in 0..<registrationHistogramBins {
            for baseBin in 0..<registrationHistogramBins {
                let index = overlayBin * registrationHistogramBins + baseBin
                let count = Double(histogram[index])
                if count <= 0 { continue }
                let probability = count / overlapTotal
                baseMarginal[baseBin] += probability
                overlayMarginal[overlayBin] += probability
                jointEntropy -= probability * log(probability)
            }
        }

        guard jointEntropy > 0 else {
            return .greatestFiniteMagnitude
        }

        var baseEntropy: Double = 0
        var overlayEntropy: Double = 0
        for probability in baseMarginal where probability > 0 {
            baseEntropy -= probability * log(probability)
        }
        for probability in overlayMarginal where probability > 0 {
            overlayEntropy -= probability * log(probability)
        }

        let nmi = (baseEntropy + overlayEntropy) / jointEntropy
        let fixedVoxelCount = Double(baseVolumeTexture.width * baseVolumeTexture.height * baseVolumeTexture.depth)
        let movingVoxelCount = Double(overlayVolumeTexture.width * overlayVolumeTexture.height * overlayVolumeTexture.depth)
        let overlapDenominator = min(fixedVoxelCount, movingVoxelCount)
        let overlapFraction = overlapTotal / max(overlapDenominator, 1)
        let slabAwareRegistration = baseIsThinSlab || overlayIsThinSlab
        let minimumUsefulOverlap: Double
        if slabAwareRegistration {
            minimumUsefulOverlap = useBoneOnly ? 0.015 : 0.035
        } else {
            minimumUsefulOverlap = useBoneOnly ? 0.003 : 0.01
        }
        let overlapPenalty = overlapFraction < minimumUsefulOverlap
            ? Float((minimumUsefulOverlap - overlapFraction) * (slabAwareRegistration ? 8.0 : 4.0))
            : 0
        let slabPenalty = slabAwareRegistration ? slabOverlapPenalty(for: state) : 0

        return Float(-nmi) + overlapPenalty + slabPenalty
    }

    private func metricOptions(forLevelIndex levelIndex: Int, totalLevels: Int, useBoneOnly: Bool) -> SIMD4<Float> {
        guard useBoneOnly,
              let basePix = pixList.first,
              let overlayPix = overlayPixList.first else {
            let usesStructureMetric = shouldUseStructureMetric(forLevelIndex: levelIndex, totalLevels: totalLevels)
            return usesStructureMetric ? SIMD4<Float>(2, structureGradientThreshold(forLevelIndex: levelIndex, totalLevels: totalLevels), 0, 0) : .zero
        }

        let baseModality = basePix.modalityString?.uppercased() ?? ""
        let overlayModality = overlayPix.modalityString?.uppercased() ?? ""
        let baseRescale = basePix.rescaleType?.uppercased() ?? ""
        let overlayRescale = overlayPix.rescaleType?.uppercased() ?? ""
        let isCTToCT = baseModality.contains("CT") && overlayModality.contains("CT")
        let usesHU = baseRescale == "HU" && overlayRescale == "HU"

        if isCTToCT && usesHU {
            return SIMD4<Float>(1, 65, 3000, 0)
        }

        let usesStructureMetric = shouldUseStructureMetric(forLevelIndex: levelIndex, totalLevels: totalLevels)
        return usesStructureMetric ? SIMD4<Float>(2, structureGradientThreshold(forLevelIndex: levelIndex, totalLevels: totalLevels), 0, 0) : .zero
    }

    private func shouldUseBoneOnlyMetric(forLevelIndex levelIndex: Int, totalLevels: Int) -> Bool {
        guard totalLevels > 0 else { return false }
        return levelIndex == totalLevels - 1
    }

    private func shouldUseStructureMetric(forLevelIndex levelIndex: Int, totalLevels: Int) -> Bool {
        guard totalLevels > 1 else { return true }
        return levelIndex >= max(totalLevels - 2, 0)
    }

    private func structureGradientThreshold(forLevelIndex levelIndex: Int, totalLevels: Int) -> Float {
        guard totalLevels > 1 else { return 0.018 }
        return levelIndex == totalLevels - 1 ? 0.018 : 0.012
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
}
