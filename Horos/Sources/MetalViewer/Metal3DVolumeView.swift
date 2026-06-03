import AppKit
import MetalKit

final class Metal3DVolumeView: NSView {
    private let cropHandleHitPadding: CGFloat = 11
    private let orientationCubeTopInset: CGFloat = 148

    private final class CropOverlayView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var wireframeEdges = [Metal3DCropEdgeProjection]() {
            didSet {
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard wireframeEdges.isEmpty == false else { return }

            for edge in wireframeEdges {
                (edge.isOccluded ? NSColor.systemGreen.withAlphaComponent(0.22) : NSColor.systemGreen.withAlphaComponent(0.9)).setStroke()
                let path = NSBezierPath()
                path.lineWidth = edge.isOccluded ? 1.0 : 1.5
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.move(to: edge.start)
                path.line(to: edge.end)
                path.stroke()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    private final class CropHandleView: NSView {
        let plane: Metal3DCropPlane

        init(plane: Metal3DCropPlane) {
            self.plane = plane
            super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            wantsLayer = true
            layer?.backgroundColor = NSColor.systemGreen.cgColor
            layer?.cornerRadius = 9
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class PassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    private let metalView: MTKView
    private let cropOverlayView = CropOverlayView(frame: .zero)
    private let orientationOverlayView = MetalOrientationOverlayView(frame: .zero)
    private let gantryTiltCorrectionLabel = PassthroughLabel(labelWithString: NSLocalizedString("Gantry Tilt Corrected", comment: ""))
    private var renderer: Metal3DVolumeRenderer?
    private var lastDragLocation: NSPoint?
    private var activeCropPlane: Metal3DCropPlane?
    private var isDraggingTrajectoryHandle = false
    private var cropHandleProjections = [Metal3DCropPlane: Metal3DCropHandleProjection]()
    private var cropHandleViews = [Metal3DCropPlane: CropHandleView]()
    private var trackingAreaRef: NSTrackingArea?
    private var isWindowLevelInteractionActive = false
    private var tumourSeedScope: MetalViewerTumourSeedScope?
    private var tumourSeedPixList: [DCMPix] = []
    private var tumourSeedObserver: NSObjectProtocol?
    var wlwwInteractionHandler: ((String) -> Void)?

    private var cropApplied = false

    var cropEnabled = false {
        didSet {
            if cropEnabled {
                cropApplied = true
                renderer?.setCropEnabled(true)
            } else {
                activeCropPlane = nil
                renderer?.setActiveCropPlane(nil)
                renderer?.setHoveredCropPlane(nil)
            }
            renderer?.setCropOverlayVisible(cropEnabled)
            updateAppearance()
            refreshCropHandles()
        }
    }

    var shadingEnabled = true {
        didSet {
            renderer?.setShadingEnabled(shadingEnabled)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    var preIntegrationEnabled = true {
        didSet {
            renderer?.setPreIntegrationEnabled(preIntegrationEnabled)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    var showSkin = true {
        didSet {
            renderer?.setShowSkin(showSkin)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    var showSkinSurface = false {
        didSet {
            renderer?.setShowSkinSurface(showSkinSurface)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    var skinClipDepthMM: Float = 6.0 {
        didSet {
            skinClipDepthMM = min(max(skinClipDepthMM, 0), 20)
            renderer?.setSkinClipDepthMM(skinClipDepthMM)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    var showTumorSegmentation = true {
        didSet {
            renderer?.setShowTumorSegmentation(showTumorSegmentation)
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    override init(frame frameRect: NSRect) {
        metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.015, alpha: 1.0)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        addSubview(metalView)

        cropOverlayView.translatesAutoresizingMaskIntoConstraints = false
        cropOverlayView.wantsLayer = false
        cropOverlayView.isHidden = true
        addSubview(cropOverlayView)

        orientationOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(orientationOverlayView)

        gantryTiltCorrectionLabel.translatesAutoresizingMaskIntoConstraints = false
        gantryTiltCorrectionLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        gantryTiltCorrectionLabel.textColor = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
        gantryTiltCorrectionLabel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 2
            return shadow
        }()
        gantryTiltCorrectionLabel.isHidden = true
        addSubview(gantryTiltCorrectionLabel)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cropOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cropOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cropOverlayView.topAnchor.constraint(equalTo: topAnchor),
            cropOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            orientationOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            orientationOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            orientationOverlayView.topAnchor.constraint(equalTo: topAnchor),
            orientationOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gantryTiltCorrectionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            gantryTiltCorrectionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        for plane in Metal3DCropPlane.allCases {
            let handleView = CropHandleView(plane: plane)
            handleView.isHidden = true
            cropOverlayView.addSubview(handleView)
            cropHandleViews[plane] = handleView
        }

        tumourSeedObserver = NotificationCenter.default.addObserver(
            forName: MetalViewerTumourSeedStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.tumourSeedsDidChange(notification)
        }

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let tumourSeedObserver {
            NotificationCenter.default.removeObserver(tumourSeedObserver)
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func layout() {
        super.layout()
        refreshCropHandles()
        refreshOrientationOverlay()
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        renderer?.zoom(delta: Float(event.scrollingDeltaY))
        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
        refreshOrientationOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if trajectoryHandle(at: location) != nil {
            isDraggingTrajectoryHandle = true
            activeCropPlane = nil
            renderer?.setActiveCropPlane(nil)
            renderer?.setTrajectoryHandleHovered(true)
            lastDragLocation = location
            metalView.setNeedsDisplay(metalView.bounds)
            return
        }
        if cropEnabled, let hitPlane = cropPlane(at: location) {
            activeCropPlane = hitPlane
            renderer?.setActiveCropPlane(hitPlane)
            lastDragLocation = location
            metalView.setNeedsDisplay(metalView.bounds)
            return
        }
        lastDragLocation = location
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let lastDragLocation else {
            self.lastDragLocation = location
            return
        }

        if isDraggingTrajectoryHandle {
            let screenDelta = CGVector(dx: location.x - lastDragLocation.x, dy: location.y - lastDragLocation.y)
            renderer?.dragTrajectoryHandle(screenDelta: screenDelta, in: bounds)
            renderer?.setTrajectoryHandleHovered(true)
            metalView.setNeedsDisplay(metalView.bounds)
            self.lastDragLocation = location
            return
        }

        if let activeCropPlane,
           let projection = cropHandleProjections[activeCropPlane],
           let renderer {
            let screenDelta = CGVector(dx: location.x - lastDragLocation.x, dy: location.y - lastDragLocation.y)
            let axisLength = hypot(projection.dragAxis.dx, projection.dragAxis.dy)
            if axisLength > 0.5, projection.pixelsPerWorldUnit > 0.001 {
                let normalizedAxis = CGVector(dx: projection.dragAxis.dx / axisLength, dy: projection.dragAxis.dy / axisLength)
                let signedPixels = screenDelta.dx * normalizedAxis.dx + screenDelta.dy * normalizedAxis.dy
                let worldDelta = Float(signedPixels / projection.pixelsPerWorldUnit)
                let newValue = renderer.cropPlaneValue(activeCropPlane) + worldDelta
                renderer.setCropPlane(activeCropPlane, value: newValue)
                metalView.setNeedsDisplay(metalView.bounds)
                refreshCropHandles()
            }
            self.lastDragLocation = location
            return
        }

        let deltaX = Float(location.x - lastDragLocation.x)
        let deltaY = Float(location.y - lastDragLocation.y)
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.control) {
            beginWindowLevelInteractionIfNeeded()
            renderer?.adjustWindowLevelWidth(deltaX: deltaX, deltaY: deltaY)
            if let selectedWLPresetName {
                wlwwInteractionHandler?(selectedWLPresetName)
            }
        } else {
            renderer?.rotateTrackball(from: lastDragLocation, to: location, in: bounds)
        }

        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
        refreshOrientationOverlay()
        self.lastDragLocation = location
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDraggingTrajectoryHandle = false
        activeCropPlane = nil
        renderer?.setActiveCropPlane(nil)
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let lastDragLocation else {
            self.lastDragLocation = location
            return
        }

        let deltaY = Float(location.y - lastDragLocation.y)
        renderer?.zoom(delta: deltaY * 3.0)
        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
        refreshOrientationOverlay()
        self.lastDragLocation = location
    }

    override func rightMouseUp(with event: NSEvent) {
        lastDragLocation = nil
    }

    override func mouseUp(with event: NSEvent) {
        let wasDraggingTrajectoryHandle = isDraggingTrajectoryHandle
        isDraggingTrajectoryHandle = false
        activeCropPlane = nil
        renderer?.setActiveCropPlane(nil)
        endWindowLevelInteractionIfNeeded()
        let location = convert(event.locationInWindow, from: nil)
        if wasDraggingTrajectoryHandle {
            renderer?.finishTrajectoryHandleDrag()
        }
        updateHoveredTrajectoryHandle(at: location)
        if cropEnabled {
            updateHoveredCropPlane(at: location)
        }
        lastDragLocation = nil
        metalView.setNeedsDisplay(metalView.bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredTrajectoryHandle(at: location)
        if cropEnabled {
            updateHoveredCropPlane(at: location)
        }
    }

    override func mouseExited(with event: NSEvent) {
        renderer?.setTrajectoryHandleHovered(false)
        renderer?.setHoveredCropPlane(nil)
        metalView.setNeedsDisplay(metalView.bounds)
    }

    func configure(pixList: [DCMPix], volumeData: Data) {
        guard let device = metalView.device else { return }
        let renderer = Metal3DVolumeRenderer(device: device, pixList: pixList, volumeData: volumeData)
        tumourSeedScope = MetalViewerTumourSeedStore.scope(forPixList: pixList)
        tumourSeedPixList = pixList
        renderer.setCropEnabled(cropApplied || cropEnabled)
        renderer.setCropOverlayVisible(cropEnabled)
        renderer.setShadingEnabled(shadingEnabled)
        renderer.setPreIntegrationEnabled(preIntegrationEnabled)
        self.renderer = renderer
        gantryTiltCorrectionLabel.isHidden = !renderer.isGantryTiltCorrected
        skinClipDepthMM = renderer.currentSkinClipDepthMM
        renderer.setShowSkin(showSkin)
        renderer.setShowSkinSurface(showSkinSurface)
        renderer.setShowTumorSegmentation(showTumorSegmentation)
        reloadTumourSeeds()
        metalView.delegate = renderer
        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
        refreshOrientationOverlay()
    }

    private func beginWindowLevelInteractionIfNeeded() {
        guard isWindowLevelInteractionActive == false else { return }
        isWindowLevelInteractionActive = true
        renderer?.setPreIntegrationEnabled(false)
    }

    private func endWindowLevelInteractionIfNeeded() {
        guard isWindowLevelInteractionActive else { return }
        isWindowLevelInteractionActive = false
        renderer?.setPreIntegrationEnabled(preIntegrationEnabled)
    }

    @discardableResult
    func applyWLPreset(named presetName: String) -> String? {
        renderer?.applyWLPreset(named: presetName)
        metalView.setNeedsDisplay(metalView.bounds)
        return renderer?.selectedWLPresetName
    }

    @discardableResult
    func applyCLUT(named presetName: String) -> String? {
        renderer?.applyCLUT(named: presetName)
        metalView.setNeedsDisplay(metalView.bounds)
        return renderer?.selectedCLUTName
    }

    @discardableResult
    func applyOpacity(named presetName: String) -> String? {
        renderer?.applyOpacity(named: presetName)
        metalView.setNeedsDisplay(metalView.bounds)
        return renderer?.selectedOpacityName
    }

    var selectedWLPresetName: String? {
        renderer?.selectedWLPresetName
    }

    var selectedCLUTName: String? {
        renderer?.selectedCLUTName
    }

    var selectedOpacityName: String? {
        renderer?.selectedOpacityName
    }

    func makeHistogramModel() -> Metal3DHistogramModel? {
        renderer?.makeHistogramModel()
    }

    func opacityControlPoints() -> [SIMD2<Float>] {
        renderer?.opacityControlPoints() ?? []
    }

    func segmentationInput() -> Metal3DSegmentationInput? {
        renderer?.segmentationInput()
    }

    @discardableResult
    func setTumorSegmentationLabelmap(_ labelmap: Data) -> Metal3DTumorSegmentationStatistics {
        let statistics = renderer?.setTumorSegmentationLabelmap(labelmap) ?? Metal3DTumorSegmentationStatistics(
            surfaceCount: 0,
            voxelVolumeML: 0,
            labelVoxelCounts: [:]
        )
        metalView.setNeedsDisplay(metalView.bounds)
        return statistics
    }

    func clearTumorSegmentation() {
        renderer?.clearTumorSegmentation()
        metalView.setNeedsDisplay(metalView.bounds)
        refreshOrientationOverlay()
    }

    func setTumorLabelFilter(_ labels: Set<UInt8>?) {
        renderer?.setTumorLabelFilter(labels)
        metalView.setNeedsDisplay(metalView.bounds)
    }

    func showInitialSurgicalTrajectory() -> String? {
        guard let renderer else {
            return NSLocalizedString("The 3D renderer is not ready.", comment: "")
        }
        guard let message = renderer.showInitialSurgicalTrajectory() else {
            metalView.setNeedsDisplay(metalView.bounds)
            return nil
        }
        return message
    }

    func setOpacityControlPoints(_ points: [SIMD2<Float>]) {
        renderer?.setOpacityControlPoints(points)
        metalView.setNeedsDisplay(metalView.bounds)
    }

    private func updateAppearance() {
        if cropEnabled {
            metalView.clearColor = MTLClearColor(red: 0.02, green: 0.015, blue: 0.015, alpha: 1.0)
        } else if cropApplied {
            metalView.clearColor = MTLClearColor(red: 0.015, green: 0.012, blue: 0.012, alpha: 1.0)
        } else {
            metalView.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.015, alpha: 1.0)
        }
        metalView.setNeedsDisplay(metalView.bounds)
    }

    private func cropPlane(at location: CGPoint) -> Metal3DCropPlane? {
        for (plane, handleView) in cropHandleViews where handleView.isHidden == false {
            if handleView.frame.insetBy(dx: -cropHandleHitPadding, dy: -cropHandleHitPadding).contains(location) {
                return plane
            }
        }
        return nil
    }

    private func trajectoryHandle(at location: CGPoint) -> Metal3DTrajectoryHandleProjection? {
        guard let projection = renderer?.trajectoryHandleProjection(in: bounds) else {
            return nil
        }

        let distance = hypot(location.x - projection.position.x, location.y - projection.position.y)
        return distance <= projection.hitRadius ? projection : nil
    }

    private func refreshCropHandles() {
        guard cropEnabled, let renderer else {
            cropHandleProjections.removeAll()
            cropOverlayView.wireframeEdges = []
            for handleView in cropHandleViews.values {
                handleView.isHidden = true
            }
            return
        }

        cropOverlayView.wireframeEdges = []

        let projections = renderer.cropHandleProjections(in: bounds)
        cropHandleProjections = Dictionary(uniqueKeysWithValues: projections.map { ($0.plane, $0) })

        for (plane, handleView) in cropHandleViews {
            guard let projection = cropHandleProjections[plane] else {
                handleView.isHidden = true
                continue
            }

            let size = handleView.frame.size
            handleView.frame = NSRect(
                x: projection.position.x - size.width * 0.5,
                y: projection.position.y - size.height * 0.5,
                width: size.width,
                height: size.height
            )
            handleView.alphaValue = 0.0
            handleView.isHidden = false
        }
    }

    private func refreshOrientationOverlay() {
        orientationOverlayView.overlayState = renderer?.orientationOverlayState(
            in: bounds,
            cubeTopInset: orientationCubeTopInset
        )
    }

    private func updateHoveredCropPlane(at location: CGPoint) {
        let hoveredPlane = cropPlane(at: location)
        renderer?.setHoveredCropPlane(hoveredPlane)
        metalView.setNeedsDisplay(metalView.bounds)
    }

    private func updateHoveredTrajectoryHandle(at location: CGPoint) {
        renderer?.setTrajectoryHandleHovered(trajectoryHandle(at: location) != nil)
        metalView.setNeedsDisplay(metalView.bounds)
    }

    private func tumourSeedsDidChange(_ notification: Notification) {
        guard let tumourSeedScope,
              MetalViewerTumourSeedStore.notification(notification, matches: tumourSeedScope) else {
            return
        }
        reloadTumourSeeds()
    }

    private func reloadTumourSeeds() {
        guard tumourSeedScope != nil else {
            renderer?.setTumourSeeds([])
            return
        }
        guard tumourSeedPixList.isEmpty == false else {
            renderer?.setTumourSeeds([])
            return
        }
        renderer?.setTumourSeeds(MetalViewerTumourSeedStore.shared.seeds(forPixList: tumourSeedPixList))
        metalView.setNeedsDisplay(metalView.bounds)
    }
}
