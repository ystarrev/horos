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

private final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    private final class FrameResources {
        let allocator: MTL4CommandAllocator
        let uniforms: MTLBuffer
        let residency: MTLResidencySet
        var inFlight = false
        var sampledTextures: [MTLTexture] = []
        var drawable: CAMetalDrawable?
        var renderPass: MTL4RenderPassDescriptor?
        var drawableResidency: MTLResidencySet?

        init(device: MTLDevice, vertexBuffer: MTLBuffer) throws {
            guard let allocator = device.makeCommandAllocator(),
                  let uniforms = device.makeBuffer(length: MemoryLayout<MetalPreviewUniforms>.stride,
                                                   options: .storageModeShared) else {
                throw NSError(domain: "MetalPreviewRenderer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not allocate Metal preview frame resources."])
            }
            self.allocator = allocator
            self.uniforms = uniforms
            let descriptor = MTLResidencySetDescriptor()
            descriptor.initialCapacity = 6
            residency = try device.makeResidencySet(descriptor: descriptor)
            residency.addAllocation(vertexBuffer)
            residency.addAllocation(uniforms)
            residency.commit()
        }

        func releaseCompletedResources() {
            for texture in sampledTextures { residency.removeAllocation(texture) }
            residency.commit()
            sampledTextures.removeAll(keepingCapacity: true)
            drawable = nil
            renderPass = nil
            drawableResidency = nil
            inFlight = false
        }
    }

    private let deviceRef: MTLDevice
    private let commandQueue: MTL4CommandQueue
    private let commandBuffer: MTL4CommandBuffer
    private let vertexArguments: MTL4ArgumentTable
    private let fragmentArguments: MTL4ArgumentTable
    private let frames: [FrameResources]
    private var pendingRedraw = false
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer

    private(set) var pixList: [DCMPix] = []
    private(set) var currentIndex = 0
    private(set) var currentPix: DCMPix?
    private var displayedSliceIndex: Int?
    private var imageTexture: MTLTexture?
    private var volumeEntry: MetalSeriesTextureCache.Entry?
    private var requestedVolumeKey: String?
    private var imageTexturePool: [MTLTexture] = []
    private var imageTextureKind: MetalSeriesTextureKind = .rescaledFloat
    private var imageRescaleSlope: Float = 1
    private var imageRescaleIntercept: Float = 0
    private var imagePixelSpacing = SIMD2<Float>(repeating: 1)
    private var windowSeriesKey: String?
    private var needsDefaultWindow = true
    private(set) var imageAspectRatio: Float = 1
    private(set) var windowLevel: Float = 0
    private(set) var windowWidth: Float = 1
    private(set) var panOffset = SIMD2<Float>(repeating: 0)
    private(set) var zoomScale: Float = 1
    var contentDidChange: (() -> Void)?

    init(device: MTLDevice) {
        self.deviceRef = device

        guard let commandQueue = device.makeMTL4CommandQueue(),
              let commandBuffer = device.makeCommandBuffer() else {
            fatalError("Could not create Metal command queue.")
        }
        self.commandQueue = commandQueue
        self.commandBuffer = commandBuffer

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

        do {
            let pipelines = try MetalPipelineCache.shared(for: device)
            pipelineState = try pipelines.renderPipeline(vertex: "metalPreviewVertex", fragment: "metalPreviewFragment")
            frames = try (0..<3).map { _ in try FrameResources(device: device, vertexBuffer: vertexBuffer) }
            let vertexDescriptor = MTL4ArgumentTableDescriptor()
            vertexDescriptor.maxBufferBindCount = 2
            vertexDescriptor.initializeBindings = true
            vertexArguments = try device.makeArgumentTable(descriptor: vertexDescriptor)
            vertexArguments.setAddress(vertexBuffer.gpuAddress, index: 0)
            let fragmentDescriptor = MTL4ArgumentTableDescriptor()
            fragmentDescriptor.maxBufferBindCount = 1
            fragmentDescriptor.maxTextureBindCount = 6
            fragmentDescriptor.initializeBindings = true
            fragmentArguments = try device.makeArgumentTable(descriptor: fragmentDescriptor)
        } catch {
            fatalError("Could not create Metal preview pipeline: \(error)")
        }

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
        // A replacement thumbnail is not necessarily a slice of the cached volume.
        if pix == nil || !pixList.indices.contains(index) || pixList[index] !== pix {
            pixList = []
            volumeEntry = nil
            requestedVolumeKey = nil
        }

        guard let pix else {
            currentIndex = max(0, index)
            displayedSliceIndex = currentIndex
            currentPix = nil
            resetImageTextureState()
            return
        }

        currentIndex = max(0, index)
        displayedSliceIndex = currentIndex
        loadPix(pix, resetWindowLevel: resetWindowLevel)
    }

    func updateSinglePix(_ pix: DCMPix?, at index: Int, resetWindowLevel: Bool) {
        pixList = []
        volumeEntry = nil
        requestedVolumeKey = nil
        updateCurrentPix(pix, at: index, resetWindowLevel: resetWindowLevel)
    }

    func setDisplayedSliceIndex(_ index: Int) {
        displayedSliceIndex = max(0, index)
    }

    func setWindowLevel(_ wl: Float, width ww: Float) {
        guard wl.isFinite, ww.isFinite else { return }
        guard ww > 0 else {
            needsDefaultWindow = true
            if let currentPix { loadPix(currentPix, resetWindowLevel: true) }
            return
        }
        needsDefaultWindow = false
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
        let reader = pix.srcFile.flatMap { try? SwiftDICOMReader.cached(contentsOfFile: $0) }
        let seriesUID = reader?.stringValue(forTag: "0020,000E")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesKey = seriesUID?.isEmpty == false ? seriesUID : pix.srcFile
        if resetWindowLevel || currentPix == nil || seriesKey != windowSeriesKey {
            needsDefaultWindow = true
        }
        windowSeriesKey = seriesKey

        currentPix = pix
        let width = max(Int(pix.widthWithoutLoading()), 1)
        let height = max(Int(pix.heightWithoutLoading()), 1)
        // A published volume is immutable. Only decode again for a new window,
        // not for every slice scroll or when its asynchronous upload arrives.
        let storedPixels = usingVolumeTexture && !needsDefaultWindow ? nil : MetalStoredInt16PixelData(pix: pix)
        if usingVolumeTexture == false {
            if let storedPixels, storedPixels.width == width, storedPixels.height == height,
               let texture = makeStoredInt16Texture(storedPixels) {
                imageTexture = texture
            } else {
                resetImageTextureState()
            }
        }
        if let storedPixels {
            imageRescaleSlope = storedPixels.rescaleSlope
            imageRescaleIntercept = storedPixels.rescaleIntercept
            imagePixelSpacing = storedPixels.pixelSpacing
        }
        let spacingX = max(imagePixelSpacing.x, 0.0001)
        let spacingY = max(imagePixelSpacing.y, 0.0001)
        imageAspectRatio = Float(width) * spacingX / max(Float(height) * spacingY, 1)

        if needsDefaultWindow, let storedPixels {
            let modality = reader?.stringValue(forTag: "0008,0060") ?? pix.modalityString
            let dicomWindow = storedPixels.defaultWindow.flatMap { window in
                window.level.isFinite && window.width.isFinite && window.width > 0 ? window : nil
            }
            let useAutomaticWindow = modality?.uppercased() == "MR" || dicomWindow == nil
            let automaticWindow = useAutomaticWindow
                ? MetalViewerAutomaticWindowLevel.window(for: storedPixels, modality: modality)
                : nil
            let window = automaticWindow ?? dicomWindow ?? storedPixels.storedRangeWindow
            windowWidth = max(window.width, 1)
            windowLevel = window.level
            needsDefaultWindow = false
        }
    }

    private func requestVolumeTexture(for pixList: [DCMPix]) {
        guard let request = MetalSeriesTextureCache.shared.makeRequest(for: pixList, device: deviceRef) else {
            requestedVolumeKey = nil
            volumeEntry = nil
            return
        }
        let key = request.key

        if MetalSeriesTextureCache.shared.isEntryKnownUnavailable(for: request) {
            return
        }

        guard requestedVolumeKey != key || volumeEntry == nil else { return }
        if requestedVolumeKey != key {
            volumeEntry = nil
        }
        requestedVolumeKey = key

        if let entry = MetalSeriesTextureCache.shared.cachedEntry(for: request) {
            volumeEntry = entry
            if needsDefaultWindow { loadCurrentPix(resetWindowLevel: true) }
            contentDidChange?()
            return
        }

        MetalSeriesTextureCache.shared.requestEntry(for: request) { [weak self] entry in
            guard let self,
                  self.requestedVolumeKey == key else {
                return
            }

            guard let entry else { return }

            self.volumeEntry = entry
            if self.needsDefaultWindow { self.loadCurrentPix(resetWindowLevel: true) }
            self.contentDidChange?()
        }
    }

    private func canUseVolumeTexture(for pix: DCMPix?, at index: Int) -> Bool {
        guard let pix,
              let volumeEntry,
              pixList.indices.contains(index),
              pixList[index] === pix,
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
        imageTexturePool.removeAll()
        imageTextureKind = .rescaledFloat
        imageRescaleSlope = 1
        imageRescaleIntercept = 0
        imagePixelSpacing = SIMD2<Float>(repeating: 1)
        needsDefaultWindow = true
    }

    private func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat, kind: MetalSeriesTextureKind) -> MTLTexture? {
        precondition(Thread.isMainThread)
        imageTexturePool.removeAll { $0.width != width || $0.height != height || $0.pixelFormat != pixelFormat }
        let texture: MTLTexture
        // CPU uploads must not overwrite a texture sampled by an outstanding frame.
        if let existingTexture = imageTexturePool.first(where: { candidate in
            !frames.contains { frame in
                frame.inFlight && frame.sampledTextures.contains { $0 === candidate }
            }
        }) {
            texture = existingTexture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared

            guard let newTexture = deviceRef.makeTexture(descriptor: descriptor) else {
                return nil
            }
            imageTexturePool.append(newTexture)
            texture = newTexture
        }
        imageTexture = texture
        imageTextureKind = kind
        return texture
    }

    private func makeStoredInt16Texture(_ storedPixels: MetalStoredInt16PixelData) -> MTLTexture? {
        let width = storedPixels.width
        let height = storedPixels.height
        guard let texture = texture(
            width: width,
            height: height,
            pixelFormat: storedPixels.pixelFormat,
            kind: storedPixels.textureKind
        ) else {
            return nil
        }

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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        precondition(Thread.isMainThread)
        let performanceStartedAt = MetalPerformanceTrace.begin()
        guard let frame = frames.first(where: { !$0.inFlight }) else {
            // Coalesce while busy. Completion requests the latest state, not a stale slice.
            pendingRedraw = true
            return
        }
        pendingRedraw = false
        guard let renderPassDescriptor = view.currentMTL4RenderPassDescriptor,
              let drawable = view.currentDrawable,
              let layer = view.layer as? CAMetalLayer else {
            return
        }

        let sampledVolumeSliceIndex = volumeSliceIndex
        let sampledVolumeEntry = canUseVolumeTexture(for: currentPix, at: sampledVolumeSliceIndex) ? volumeEntry : nil
        let sampledTextureKind = sampledVolumeEntry?.textureKind.rawValue ?? imageTextureKind.rawValue
        let sampledRescaleSlope = sampledVolumeEntry?.rescaleSlope ?? imageRescaleSlope
        let sampledRescaleIntercept = sampledVolumeEntry?.rescaleIntercept ?? imageRescaleIntercept
        let signedImageTexture = sampledVolumeEntry == nil && imageTextureKind == .storedInt16Signed ? imageTexture : nil
        let unsignedImageTexture = sampledVolumeEntry == nil && imageTextureKind == .storedInt16Unsigned ? imageTexture : nil
        let signedVolumeTexture = sampledVolumeEntry?.textureKind == .storedInt16Signed ? sampledVolumeEntry?.texture : nil
        let unsignedVolumeTexture = sampledVolumeEntry?.textureKind == .storedInt16Unsigned ? sampledVolumeEntry?.texture : nil

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

        frame.allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: frame.allocator)
        frame.drawable = drawable
        frame.renderPass = renderPassDescriptor
        frame.drawableResidency = layer.residencySet
        let textures = [signedVolumeTexture, unsignedVolumeTexture, signedImageTexture, unsignedImageTexture]
        frame.sampledTextures = textures.compactMap { $0 }
        for texture in frame.sampledTextures { frame.residency.addAllocation(texture) }
        frame.residency.commit()
        commandBuffer.useResidencySet(frame.residency)
        commandBuffer.useResidencySet(layer.residencySet)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.endCommandBuffer()
            frame.releaseCompletedResources()
            NSLog("Could not create Metal 4 preview render encoder.")
            return
        }

        if imageTexture != nil || sampledVolumeEntry != nil {
            withUnsafeBytes(of: &uniforms) { bytes in
                frame.uniforms.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            vertexArguments.setAddress(frame.uniforms.gpuAddress, index: 1)
            fragmentArguments.setAddress(frame.uniforms.gpuAddress, index: 0)
            for (index, texture) in textures.enumerated() {
                fragmentArguments.setTexture(texture?.gpuResourceID ?? MTLResourceID(), index: index + 2)
            }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setArgumentTable(vertexArguments, stages: .vertex)
            encoder.setArgumentTable(fragmentArguments, stages: .fragment)
            encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.endCommandBuffer()

        let options = MTL4CommitOptions()
        // Metal 4 does not retain resources. Keep this renderer and its frame alive
        // even if the preview view closes before the GPU completes the submission.
        options.addFeedbackHandler { [self, frame, weak view] feedback in
            if let error = feedback.error { NSLog("Metal 4 preview failed: %@", error.localizedDescription) }
            DispatchQueue.main.async { [self, frame, weak view] in
                frame.releaseCompletedResources()
                if pendingRedraw {
                    pendingRedraw = false
                    view?.needsDisplay = true
                }
            }
        }
        MetalPerformanceTrace.track(options, operation: "draw.preview", since: performanceStartedAt, drawable: drawable)
        frame.inFlight = true
        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer], options: options)
        commandQueue.signalDrawable(drawable)
        drawable.present()
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

    @objc func updateSinglePix(_ pix: DCMPix?, index: Int, resetWindowLevel: Bool) {
        previewRenderer.updateSinglePix(pix, at: index, resetWindowLevel: resetWindowLevel)
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

        let dicomPoint = MetalViewerSliceGeometry(pix: pix)?.dicomPoint(
            pixelX: Double(pixelX),
            pixelY: Double(pixelY)
        ) ?? .zero

        mouseOnImage = true
        mousePixelX = sampleX
        mousePixelY = sampleY
        mousePixelValue = pixelValue(for: pix, x: sampleX, y: sampleY)
        mouseDicomX = Float(dicomPoint.x)
        mouseDicomY = Float(dicomPoint.y)
        mouseDicomZ = Float(dicomPoint.z)
        markOverlayDirty()
    }

    private func pixelValue(for pix: DCMPix, x: Int, y: Int) -> Float {
        if mouseSamplePix !== pix {
            mouseSamplePix = pix
            mouseSampleStoredPixels = nil
        }

        if mouseSampleStoredPixels == nil {
            mouseSampleStoredPixels = MetalStoredInt16PixelData(pix: pix)
        }

        return mouseSampleStoredPixels?.rescaledValue(x: x, y: y) ?? 0
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
