import AppKit
import Foundation
import Metal
import MetalKit
import simd

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
    var windowLevel: Float
    var windowWidth: Float
    var shading: Float
    var hasCLUT: UInt32
}

private enum Metal3DDefaults {
    static let maxDynamicValue: Float = 32000
    static let transparentBelowRawValue: Float = 30
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
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer
    private let pixList: [DCMPix]
    private let volumeDimensions: SIMD3<Int>
    private let boxMin: SIMD3<Float>
    private let boxMax: SIMD3<Float>
    private let cropBoxMin = SIMD3<Float>(repeating: -0.28)
    private let cropBoxMax = SIMD3<Float>(repeating: 0.28)
    private let superSampling: Float
    private let valueFactor: Float
    private let offset16: Float
    private let transferTextureWidth = 4096

    private var volumeTexture: MTLTexture?
    private var clutTexture: MTLTexture?
    private var opacityTexture: MTLTexture?
    private var drawableSize = CGSize(width: 1, height: 1)

    private(set) var selectedWLPresetName = Metal3DDefaults.defaultWLWW
    private(set) var selectedCLUTName = Metal3DDefaults.noCLUT
    private(set) var selectedOpacityName = Metal3DDefaults.linearOpacity
    private(set) var cropEnabled = false

    private var windowLevel: Float = 0
    private var windowWidth: Float = 1
    private var currentCLUTPixels = [SIMD4<UInt8>]()
    private var currentOpacityPoints = [String]()
    private var orbitYaw = Float(35.0 * .pi / 180.0)
    private var orbitPitch = Float(22.0 * .pi / 180.0)
    private var orbitRadius: Float

    init(device: MTLDevice, pixList: [DCMPix], volumeData: Data) {
        self.deviceRef = device
        self.pixList = pixList

        guard let firstPix = pixList.first else {
            fatalError("3D Metal viewer requires at least one DCMPix slice.")
        }

        let width = max(Int(firstPix.pwidth), 1)
        let height = max(Int(firstPix.pheight), 1)
        let depth = max(pixList.count, 1)
        self.volumeDimensions = SIMD3<Int>(width, height, depth)

        let spacing = Self.voxelSpacing(for: pixList)
        let extent = Self.volumeExtent(dimensions: self.volumeDimensions, spacing: spacing)
        self.boxMin = -extent * 0.5
        self.boxMax = extent * 0.5
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
              let fragmentFunction = library.makeFunction(name: "metal3DVolumeFragment") else {
            fatalError("Could not load Metal 3D volume shader functions.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create the 3D Metal pipeline: \(error)")
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

        super.init()

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
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let volumeTexture else {
            return
        }

        var uniforms = makeUniforms(for: view.drawableSize)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Metal3DVolumeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(clutTexture, index: 1)
        encoder.setFragmentTexture(opacityTexture, index: 2)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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

    func rotate(deltaX: Float, deltaY: Float) {
        orbitYaw -= deltaX * 0.01
        orbitPitch += deltaY * 0.01

        let pitchLimit = Float(85.0 * .pi / 180.0)
        orbitPitch = min(max(orbitPitch, -pitchLimit), pitchLimit)
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
    }

    private func makeUniforms(for drawableSize: CGSize) -> Metal3DVolumeUniforms {
        let width = max(Float(drawableSize.width), 1)
        let height = max(Float(drawableSize.height), 1)
        let aspectRatio = width / height

        let cameraDirection = SIMD3<Float>(
            cos(orbitPitch) * sin(orbitYaw),
            sin(orbitPitch),
            cos(orbitPitch) * cos(orbitYaw)
        )
        let target = SIMD3<Float>(repeating: 0)
        let cameraPosition = target + cameraDirection * orbitRadius
        let cameraForward = simd_normalize(target - cameraPosition)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let cameraRight = simd_normalize(simd_cross(cameraForward, worldUp))
        let cameraUp = simd_normalize(simd_cross(cameraRight, cameraForward))
        let tanHalfFovY = tan(Float(26.0 * .pi / 180.0))

        let diagonal = simd_length(boxMax - boxMin)
        let stepSize = max(diagonal / 420.0, 0.0025)
        let density: Float = 1.0

        return Metal3DVolumeUniforms(
            cameraPosition: cameraPosition,
            tanHalfFovY: tanHalfFovY,
            cameraRight: cameraRight,
            aspectRatio: aspectRatio,
            cameraUp: cameraUp,
            stepSize: stepSize,
            cameraForward: cameraForward,
            density: density,
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
            windowLevel: windowLevel,
            windowWidth: windowWidth,
            shading: 1.0,
            hasCLUT: clutTexture == nil ? 0 : 1
        )
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

        let convertedVolume = makeConvertedVolume()
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
        let transparentThreshold = min(
            max((Metal3DDefaults.transparentBelowRawValue + offset16) * valueFactor, 0),
            Metal3DDefaults.maxDynamicValue
        )

        if currentOpacityPoints.isEmpty {
            for index in 0..<width {
                let convertedSample = Float(index) * textureDomainScale
                if convertedSample < transparentThreshold {
                    values[index] = 0
                    continue
                }
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
                if sample < transparentThreshold {
                    values[index] = 0
                    continue
                }
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

    private func makeConvertedVolume() -> [Float] {
        let sliceElementCount = max(volumeDimensions.x * volumeDimensions.y, 1)
        var converted = [Float](repeating: 0, count: sliceElementCount * max(volumeDimensions.z, 1))
        let scale = valueFactor / Metal3DDefaults.maxDynamicValue

        for (sliceIndex, pix) in pixList.enumerated() {
            pix.checkLoad()
            pix.computePixMinPixMax()
            guard let source = pix.fImage else { continue }

            let destinationOffset = sliceIndex * sliceElementCount
            for elementIndex in 0..<sliceElementCount {
                let scalar = source[elementIndex]
                let mapped = (scalar + offset16) * scale
                converted[destinationOffset + elementIndex] = min(max(mapped, 0), 1)
            }
        }

        return converted
    }
}
