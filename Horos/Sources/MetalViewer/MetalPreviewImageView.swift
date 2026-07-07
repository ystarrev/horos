import AppKit
import MetalKit
import simd

private struct MetalPreviewVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct MetalPreviewUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var windowLevel: Float
    var windowWidth: Float
    var currentSliceIndex: Float
    var useVolumeTexture: UInt32
    var volumeTextureKind: UInt32
    var rescaleSlope: Float
    var rescaleIntercept: Float
    var padding: Float
}

private extension MetalStoredInt16PixelData {
    func rescaledValue(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        let byteOffset = (y * width + x) * MemoryLayout<UInt16>.stride
        guard byteOffset + 1 < data.count else { return nil }

        let raw = UInt16(data[byteOffset]) | (UInt16(data[byteOffset + 1]) << 8)
        let storedValue: Float
        if isSigned {
            storedValue = Float(Int16(bitPattern: raw))
        } else {
            storedValue = Float(raw)
        }

        return storedValue * rescaleSlope + rescaleIntercept
    }
}

private final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    private let deviceRef: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    private(set) var pixList: [DCMPix] = []
    private(set) var currentIndex = 0
    private(set) var currentPix: DCMPix?
    private var displayedSliceIndex: Int?
    private var imageTexture: MTLTexture?
    private var volumeEntry: MetalSeriesTextureCache.Entry?
    private var requestedVolumeKey: String?
    private var textureSize: SIMD2<Int> = .zero
    private var imageTextureKind: MetalSeriesTextureKind = .rescaledFloat
    private var imageRescaleSlope: Float = 1
    private var imageRescaleIntercept: Float = 0
    private var imagePixelSpacing = SIMD2<Float>(repeating: 1)
    private var imageDefaultWindowLevel: Float?
    private var imageDefaultWindowWidth: Float?
    private(set) var imageAspectRatio: Float = 1
    private(set) var windowLevel: Float = 0
    private(set) var windowWidth: Float = 1
    private(set) var panOffset = SIMD2<Float>(repeating: 0)
    private(set) var zoomScale: Float = 1
    var contentDidChange: (() -> Void)?

    init(device: MTLDevice) {
        self.deviceRef = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Could not create Metal command queue.")
        }
        self.commandQueue = commandQueue

        let vertices: [MetalPreviewVertex] = [
            MetalPreviewVertex(position: [-1, -1], texCoord: [0, 1]),
            MetalPreviewVertex(position: [1, -1], texCoord: [1, 1]),
            MetalPreviewVertex(position: [-1, 1], texCoord: [0, 0]),
            MetalPreviewVertex(position: [1, 1], texCoord: [1, 0]),
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<MetalPreviewVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            fatalError("Could not create Metal preview vertex buffer.")
        }
        self.vertexBuffer = vertexBuffer

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "metalPreviewVertex"),
              let fragmentFunction = library.makeFunction(name: "metalPreviewFragment") else {
            fatalError("Could not load Metal preview shader functions.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create Metal preview pipeline: \(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Could not create Metal preview sampler state.")
        }
        self.samplerState = samplerState
    }

    func updatePixList(_ pixList: [DCMPix], firstImage: Int, resetWindowLevel: Bool) {
        self.pixList = pixList
        currentIndex = max(0, min(firstImage, max(pixList.count - 1, 0)))
        displayedSliceIndex = currentIndex
        volumeEntry = nil
        requestedVolumeKey = nil
        loadCurrentPix(resetWindowLevel: resetWindowLevel || currentPix == nil)
        requestVolumeTexture(for: pixList)
    }

    func updateIndex(_ index: Int, resetWindowLevel: Bool) {
        guard pixList.isEmpty == false else {
            currentIndex = 0
            displayedSliceIndex = nil
            currentPix = nil
            resetImageTextureState()
            volumeEntry = nil
            requestedVolumeKey = nil
            return
        }
        currentIndex = max(0, min(index, pixList.count - 1))
        displayedSliceIndex = currentIndex
        loadCurrentPix(resetWindowLevel: resetWindowLevel)
    }

    func updateCurrentPix(_ pix: DCMPix?, at index: Int, resetWindowLevel: Bool) {
        guard let pix else {
            currentIndex = max(0, index)
            displayedSliceIndex = currentIndex
            currentPix = nil
            resetImageTextureState()
            return
        }

        if pixList.indices.contains(index) {
            if pixList[index] !== pix {
                volumeEntry = nil
                requestedVolumeKey = nil
            }
            pixList[index] = pix
        }

        currentIndex = max(0, index)
        displayedSliceIndex = currentIndex
        loadPix(pix, resetWindowLevel: resetWindowLevel)
    }

    func setDisplayedSliceIndex(_ index: Int) {
        displayedSliceIndex = max(0, index)
    }

    func setWindowLevel(_ wl: Float, width ww: Float) {
        windowLevel = wl
        windowWidth = max(ww, 1)
    }

    func setPanOffset(x: Float, y: Float) {
        panOffset = SIMD2<Float>(x, y)
    }

    func resetViewTransform() {
        panOffset = .zero
        zoomScale = 1
    }

    private func loadCurrentPix(resetWindowLevel: Bool) {
        guard pixList.indices.contains(currentIndex) else {
            currentPix = nil
            resetImageTextureState()
            return
        }

        let pix = pixList[currentIndex]
        loadPix(pix, resetWindowLevel: resetWindowLevel)
    }

    private func loadPix(_ pix: DCMPix, resetWindowLevel: Bool) {
        let usingVolumeTexture = canUseVolumeTexture(for: pix, at: volumeSliceIndex)

        currentPix = pix
        let width = max(Int(pix.widthWithoutLoading()), 1)
        let height = max(Int(pix.heightWithoutLoading()), 1)
        if usingVolumeTexture == false {
            imageTexture = makeTexture(for: pix)
        }
        let spacingX: Float
        let spacingY: Float
        if pix.isLoaded() {
            spacingX = Float(max(pix.pixelSpacingX, 1))
            spacingY = Float(max(pix.pixelSpacingY, 1))
        } else {
            spacingX = max(imagePixelSpacing.x, 1)
            spacingY = max(imagePixelSpacing.y, 1)
        }
        imageAspectRatio = Float(width) * spacingX / max(Float(height) * spacingY, 1)

        if resetWindowLevel {
            if pix.isLoaded() {
                let savedWW = pix.savedWW > 0 ? pix.savedWW : (pix.ww > 0 ? pix.ww : pix.fullww)
                let savedWL = pix.savedWW > 0 ? pix.savedWL : (pix.wl != 0 ? pix.wl : pix.fullwl)
                windowWidth = max(savedWW, 1)
                windowLevel = savedWL
            } else if let defaultWindowWidth = imageDefaultWindowWidth,
                      let defaultWindowLevel = imageDefaultWindowLevel {
                windowWidth = max(defaultWindowWidth, 1)
                windowLevel = defaultWindowLevel
            } else {
                pix.checkLoad()
                let savedWW = pix.savedWW > 0 ? pix.savedWW : (pix.ww > 0 ? pix.ww : pix.fullww)
                let savedWL = pix.savedWW > 0 ? pix.savedWL : (pix.wl != 0 ? pix.wl : pix.fullwl)
                windowWidth = max(savedWW, 1)
                windowLevel = savedWL
            }
        }
    }

    private func requestVolumeTexture(
        for pixList: [DCMPix],
        storageMode: MetalSeriesTextureStorageMode = .storedInt16
    ) {
        guard pixList.count > 1,
              let key = MetalSeriesTextureCache.shared.key(for: pixList, device: deviceRef, storageMode: storageMode) else {
            requestedVolumeKey = nil
            volumeEntry = nil
            return
        }

        if storageMode == .storedInt16,
           MetalSeriesTextureCache.shared.isEntryKnownUnavailable(
                for: pixList,
                device: deviceRef,
                storageMode: storageMode
           ) {
            requestVolumeTexture(for: pixList, storageMode: .rescaledFloat)
            return
        }

        guard requestedVolumeKey != key || volumeEntry == nil else { return }
        if requestedVolumeKey != key {
            volumeEntry = nil
        }
        requestedVolumeKey = key

        if let entry = MetalSeriesTextureCache.shared.cachedEntry(for: pixList, device: deviceRef, storageMode: storageMode) {
            volumeEntry = entry
            contentDidChange?()
            return
        }

        MetalSeriesTextureCache.shared.requestEntry(for: pixList, device: deviceRef, storageMode: storageMode) { [weak self] entry in
            guard let self,
                  self.requestedVolumeKey == key else {
                return
            }

            guard let entry else {
                if storageMode == .storedInt16 {
                    self.requestVolumeTexture(for: pixList, storageMode: .rescaledFloat)
                }
                return
            }

            self.volumeEntry = entry
            self.contentDidChange?()
        }
    }

    private func canUseVolumeTexture(for pix: DCMPix?, at index: Int) -> Bool {
        guard let pix,
              let volumeEntry,
              index >= 0,
              index < volumeEntry.dimensions.z else {
            return false
        }

        return volumeEntry.dimensions.x == max(Int(pix.widthWithoutLoading()), 1)
            && volumeEntry.dimensions.y == max(Int(pix.heightWithoutLoading()), 1)
    }

    private var volumeSliceIndex: Int {
        let requestedIndex = displayedSliceIndex ?? currentIndex
        guard let volumeEntry else {
            return max(0, requestedIndex)
        }
        return max(0, min(requestedIndex, volumeEntry.dimensions.z - 1))
    }

    private func resetImageTextureState() {
        imageTexture = nil
        textureSize = .zero
        imageTextureKind = .rescaledFloat
        imageRescaleSlope = 1
        imageRescaleIntercept = 0
        imagePixelSpacing = SIMD2<Float>(repeating: 1)
        imageDefaultWindowLevel = nil
        imageDefaultWindowWidth = nil
    }

    private func makeTexture(for pix: DCMPix) -> MTLTexture? {
        let width = max(Int(pix.widthWithoutLoading()), 1)
        let height = max(Int(pix.heightWithoutLoading()), 1)
        if let storedTexture = makeStoredInt16Texture(for: pix, width: width, height: height) {
            return storedTexture
        }

        return makeFloatTexture(for: pix, width: width, height: height)
    }

    private func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat, kind: MetalSeriesTextureKind) -> MTLTexture? {
        let requiredSize = SIMD2<Int>(width, height)
        let texture: MTLTexture
        if let existingTexture = imageTexture, textureSize == requiredSize, imageTextureKind == kind {
            texture = existingTexture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]

            guard let newTexture = deviceRef.makeTexture(descriptor: descriptor) else {
                return nil
            }
            imageTexture = newTexture
            textureSize = requiredSize
            imageTextureKind = kind
            texture = newTexture
        }
        return texture
    }

    private func makeStoredInt16Texture(for pix: DCMPix, width: Int, height: Int) -> MTLTexture? {
        guard let storedPixels = MetalStoredInt16PixelData(pix: pix),
              storedPixels.width == width,
              storedPixels.height == height else {
            return nil
        }

        guard let texture = texture(
            width: width,
            height: height,
            pixelFormat: storedPixels.pixelFormat,
            kind: storedPixels.textureKind
        ) else {
            return nil
        }

        imageRescaleSlope = storedPixels.rescaleSlope
        imageRescaleIntercept = storedPixels.rescaleIntercept
        imagePixelSpacing = storedPixels.pixelSpacing
        let defaultWindow = storedPixels.inferredWindow
        imageDefaultWindowLevel = defaultWindow.level
        imageDefaultWindowWidth = defaultWindow.width

        storedPixels.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: storedPixels.bytesPerRow
            )
        }
        return texture
    }

    private func makeFloatTexture(for pix: DCMPix, width: Int, height: Int) -> MTLTexture? {
        guard let texture = texture(width: width, height: height, pixelFormat: .r32Float, kind: .rescaledFloat) else {
            return nil
        }
        imageRescaleSlope = 1
        imageRescaleIntercept = 0
        imagePixelSpacing = SIMD2<Float>(
            Float(max(pix.pixelSpacingX, 1)),
            Float(max(pix.pixelSpacingY, 1))
        )
        imageDefaultWindowLevel = nil
        imageDefaultWindowWidth = nil

        let pixelCount = width * height
        let bytesPerRow = MemoryLayout<Float>.stride * width

        let primaryRGBSource: UnsafeMutableRawPointer?
        if let baseAddr = pix.baseAddr {
            primaryRGBSource = UnsafeMutableRawPointer(baseAddr)
        } else {
            primaryRGBSource = nil
        }

        let fallbackRGBSource: UnsafeMutableRawPointer?
        if let fImage = pix.fImage {
            fallbackRGBSource = UnsafeMutableRawPointer(fImage)
        } else {
            fallbackRGBSource = nil
        }

        if pix.isRGB, let rgbSource = primaryRGBSource ?? fallbackRGBSource {
            var pixels = [Float](repeating: 0, count: pixelCount)
            let bytes = UnsafeRawPointer(rgbSource).assumingMemoryBound(to: UInt8.self)
            for index in 0..<pixelCount {
                let r = Float(bytes[index * 4 + 1])
                let g = Float(bytes[index * 4 + 2])
                let b = Float(bytes[index * 4 + 3])
                pixels[index] = 0.299 * r + 0.587 * g + 0.114 * b
            }

            let region = MTLRegionMake2D(0, 0, width, height)
            pixels.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: bytesPerRow)
            }
        } else if let fImage = pix.fImage {
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.replace(region: region, mipmapLevel: 0, withBytes: fImage, bytesPerRow: bytesPerRow)
        } else {
            return nil
        }
        return texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let sampledVolumeSliceIndex = volumeSliceIndex
        let sampledVolumeEntry = canUseVolumeTexture(for: currentPix, at: sampledVolumeSliceIndex) ? volumeEntry : nil
        let sampledTextureKind = sampledVolumeEntry?.textureKind.rawValue ?? imageTextureKind.rawValue
        let sampledRescaleSlope = sampledVolumeEntry?.rescaleSlope ?? imageRescaleSlope
        let sampledRescaleIntercept = sampledVolumeEntry?.rescaleIntercept ?? imageRescaleIntercept
        let floatImageTexture = imageTextureKind == .rescaledFloat ? imageTexture : nil
        let signedImageTexture = imageTextureKind == .storedInt16Signed ? imageTexture : nil
        let unsignedImageTexture = imageTextureKind == .storedInt16Unsigned ? imageTexture : nil
        let floatVolumeTexture = sampledVolumeEntry?.textureKind == .rescaledFloat ? sampledVolumeEntry?.texture : nil
        let signedVolumeTexture = sampledVolumeEntry?.textureKind == .storedInt16Signed ? sampledVolumeEntry?.texture : nil
        let unsignedVolumeTexture = sampledVolumeEntry?.textureKind == .storedInt16Unsigned ? sampledVolumeEntry?.texture : nil
        guard imageTexture != nil || sampledVolumeEntry != nil else {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
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

        var uniforms = MetalPreviewUniforms(
            scale: scale,
            offset: offset,
            windowLevel: windowLevel,
            windowWidth: windowWidth,
            currentSliceIndex: Float(sampledVolumeSliceIndex),
            useVolumeTexture: sampledVolumeEntry == nil ? 0 : 1,
            volumeTextureKind: sampledTextureKind,
            rescaleSlope: sampledRescaleSlope,
            rescaleIntercept: sampledRescaleIntercept,
            padding: 0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalPreviewUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalPreviewUniforms>.stride, index: 0)
        encoder.setFragmentTexture(floatImageTexture, index: 0)
        encoder.setFragmentTexture(floatVolumeTexture, index: 1)
        encoder.setFragmentTexture(signedVolumeTexture, index: 2)
        encoder.setFragmentTexture(unsignedVolumeTexture, index: 3)
        encoder.setFragmentTexture(signedImageTexture, index: 4)
        encoder.setFragmentTexture(unsignedImageTexture, index: 5)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@objcMembers
final class MetalPreviewImageView: MTKView {
    private var trackingAreaRef: NSTrackingArea?
    private let previewRenderer: MetalPreviewRenderer
    private var dragAnchor: NSPoint = .zero
    private var wlAnchor: Float = 0
    private var wwAnchor: Float = 0
    private(set) var mouseDraggingInProgress = false
    private(set) var mousePixelX: Int = 0
    private(set) var mousePixelY: Int = 0
    private(set) var mousePixelValue: Float = 0
    private(set) var mouseDicomX: Float = 0
    private(set) var mouseDicomY: Float = 0
    private(set) var mouseDicomZ: Float = 0
    private(set) var mouseOnImage = false
    private var lastMousePoint: CGPoint?
    private weak var mouseSamplePix: DCMPix?
    private var mouseSampleStoredPixels: MetalStoredInt16PixelData?

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice()
        guard let resolvedDevice else {
            fatalError("Metal is not available on this Mac.")
        }

        previewRenderer = MetalPreviewRenderer(device: resolvedDevice)
        super.init(frame: frameRect, device: resolvedDevice)

        delegate = previewRenderer
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        preferredFramesPerSecond = 60
        previewRenderer.contentDidChange = { [weak self] in
            self?.markOverlayDirty()
        }
    }

    convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, device: MTLCreateSystemDefaultDevice())
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    @objc(curDCM)
    var curDCM: DCMPix? {
        previewRenderer.currentPix
    }

    @objc(mouseDragging)
    var mouseDragging: Bool {
        mouseDraggingInProgress
    }

    @objc var currentWindowLevel: Float {
        previewRenderer.windowLevel
    }

    @objc var currentWindowWidth: Float {
        previewRenderer.windowWidth
    }

    @objc var currentIndex: Int {
        previewRenderer.currentIndex
    }

    @objc var currentPixListCount: Int {
        previewRenderer.pixList.count
    }

    @objc func setDisplayedImageIndex(_ index: Int) {
        previewRenderer.setDisplayedSliceIndex(index)
        refreshMouseStateForCurrentImage()
        markOverlayDirty()
    }

    @objc func updatePixList(_ pixList: [DCMPix], firstImage: Int, resetWindowLevel: Bool) {
        previewRenderer.updatePixList(pixList, firstImage: firstImage, resetWindowLevel: resetWindowLevel)
        refreshMouseStateForCurrentImage()
        markOverlayDirty()
    }

    @objc func updateIndex(_ index: Int, resetWindowLevel: Bool) {
        previewRenderer.updateIndex(index, resetWindowLevel: resetWindowLevel)
        refreshMouseStateForCurrentImage()
        markOverlayDirty()
    }

    @objc func updateCurrentPix(_ pix: DCMPix?, index: Int, resetWindowLevel: Bool) {
        previewRenderer.updateCurrentPix(pix, at: index, resetWindowLevel: resetWindowLevel)
        refreshMouseStateForCurrentImage()
        markOverlayDirty()
    }

    @objc func setWindowLevel(_ wl: Float, width ww: Float) {
        previewRenderer.setWindowLevel(wl, width: ww)
        markOverlayDirty()
    }

    @objc func resetViewTransform() {
        previewRenderer.resetViewTransform()
        markOverlayDirty()
    }

    @objc func setPanOffsetX(_ x: Float, y: Float) {
        previewRenderer.setPanOffset(x: x, y: y)
        markOverlayDirty()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragAnchor = convert(event.locationInWindow, from: nil)
        wlAnchor = previewRenderer.windowLevel
        wwAnchor = previewRenderer.windowWidth
        mouseDraggingInProgress = true
    }

    override func mouseDragged(with event: NSEvent) {
        let currentPoint = convert(event.locationInWindow, from: nil)
        let deltaX = Float(currentPoint.x - dragAnchor.x)
        let deltaY = Float(currentPoint.y - dragAnchor.y)
        previewRenderer.setWindowLevel(
            wlAnchor - deltaY * max(abs(wlAnchor), 128) * 0.003,
            width: wwAnchor + deltaX * max(abs(wwAnchor), 256) * 0.003
        )
        updateMouseState(from: currentPoint)
        markOverlayDirty()
    }

    override func mouseUp(with event: NSEvent) {
        mouseDraggingInProgress = false
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    override func swipe(with event: NSEvent) {
        super.swipe(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateMouseState(from: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        mouseSamplePix = nil
        mouseSampleStoredPixels = nil
        mouseOnImage = false
        mousePixelX = 0
        mousePixelY = 0
        mousePixelValue = 0
        mouseDicomX = 0
        mouseDicomY = 0
        mouseDicomZ = 0
        markOverlayDirty()
    }

    private func refreshMouseStateForCurrentImage() {
        guard let lastMousePoint else { return }
        updateMouseState(from: lastMousePoint)
    }

    private func updateMouseState(from point: CGPoint) {
        lastMousePoint = point

        guard let pix = previewRenderer.currentPix else {
            mouseOnImage = false
            mouseSamplePix = nil
            mouseSampleStoredPixels = nil
            return
        }

        let imageRect = displayedImageRect
        let width = Int(pix.widthWithoutLoading())
        let height = Int(pix.heightWithoutLoading())
        guard imageRect.contains(point), width > 0, height > 0 else {
            mouseOnImage = false
            return
        }

        let normalizedX = (point.x - imageRect.minX) / imageRect.width
        let normalizedY = (imageRect.maxY - point.y) / imageRect.height
        let pixelX = max(0, min(CGFloat(width - 1), normalizedX * CGFloat(width)))
        let pixelY = max(0, min(CGFloat(height - 1), normalizedY * CGFloat(height)))
        let sampleX = min(max(Int(pixelX), 0), width - 1)
        let sampleY = min(max(Int(pixelY), 0), height - 1)

        var dicomCoords = [Float](repeating: 0, count: 3)
        if pix.isLoaded() {
            pix.convertX(Float(pixelX), pixY: Float(pixelY), toDICOMCoords: &dicomCoords, pixelCenter: true)
        }

        mouseOnImage = true
        mousePixelX = sampleX
        mousePixelY = sampleY
        mousePixelValue = pixelValue(for: pix, x: sampleX, y: sampleY, width: width)
        mouseDicomX = dicomCoords[0]
        mouseDicomY = dicomCoords[1]
        mouseDicomZ = dicomCoords[2]
        markOverlayDirty()
    }

    private func pixelValue(for pix: DCMPix, x: Int, y: Int, width: Int) -> Float {
        if pix.isLoaded(), let fImage = pix.fImage {
            return fImage[y * width + x]
        }

        if mouseSamplePix !== pix {
            mouseSamplePix = pix
            mouseSampleStoredPixels = nil
        }

        if mouseSampleStoredPixels == nil {
            mouseSampleStoredPixels = MetalStoredInt16PixelData(pix: pix)
        }

        if let storedValue = mouseSampleStoredPixels?.rescaledValue(x: x, y: y) {
            return storedValue
        }

        pix.checkLoad()
        return pix.fImage?[y * width + x] ?? 0
    }

    private var displayedImageRect: CGRect {
        let bounds = bounds
        let viewAspect = max(bounds.width / max(bounds.height, 1), 0.0001)
        var imageWidth = bounds.width
        var imageHeight = bounds.height
        let aspect = CGFloat(max(previewRenderer.imageAspectRatio, 0.0001))

        if aspect > viewAspect {
            imageHeight = imageWidth / aspect
        } else {
            imageWidth = imageHeight * aspect
        }

        return CGRect(
            x: bounds.midX - imageWidth * 0.5,
            y: bounds.midY - imageHeight * 0.5,
            width: imageWidth,
            height: imageHeight
        )
    }

    private func markOverlayDirty() {
        needsDisplay = true
        superview?.subviews.forEach {
            if $0 !== self {
                $0.needsDisplay = true
            }
        }
    }
}
