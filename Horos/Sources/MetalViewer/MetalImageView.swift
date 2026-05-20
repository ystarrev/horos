import AppKit
import MetalKit
import simd

private final class MetalMPRPreviewOverlayView: NSView {
    weak var owner: MetalImageView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }

        NSColor(calibratedWhite: 0.18, alpha: 0.9).setFill()
        layout.dividerRect.fill()
        NSColor(calibratedWhite: 0.55, alpha: 0.8).setFill()
        CGRect(x: layout.dividerRect.midX - 0.5, y: layout.dividerRect.minY, width: 1, height: layout.dividerRect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.95),
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = .zero
                return shadow
            }(),
        ]

        for pane in layout.previewPanes {
            drawLabel(pane.left, at: CGPoint(x: pane.rect.minX + 8, y: pane.rect.midY), alignment: .left, attributes: attributes)
            drawLabel(pane.right, at: CGPoint(x: pane.rect.maxX - 8, y: pane.rect.midY), alignment: .right, attributes: attributes)
            drawLabel(pane.top, at: CGPoint(x: pane.rect.midX, y: pane.rect.minY + 8), alignment: .center, attributes: attributes)
            drawLabel(pane.bottom, at: CGPoint(x: pane.rect.midX, y: pane.rect.maxY - 8), alignment: .center, attributes: attributes)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds),
              layout.dividerRect.insetBy(dx: -5, dy: 0).contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }
        addCursorRect(layout.dividerRect.insetBy(dx: -5, dy: 0), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.beginMPRPreviewDividerDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.dragMPRPreviewDivider(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endMPRPreviewDividerDrag(with: event)
    }

    private enum LabelAlignment {
        case left
        case right
        case center
    }

    private func drawLabel(
        _ label: String,
        at point: CGPoint,
        alignment: LabelAlignment,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let size = attributed.size()
        let originX: CGFloat
        switch alignment {
        case .left:
            originX = point.x
        case .right:
            originX = point.x - size.width
        case .center:
            originX = point.x - size.width * 0.5
        }

        attributed.draw(at: CGPoint(x: originX, y: point.y - size.height * 0.5))
    }
}

final class MetalImageView: MTKView {
    struct MouseAnnotationState {
        let pixelPoint: CGPoint
        let pixelValue: Float
        let dicomPoint: SIMD3<Float>
    }

    private var dragAnchor: NSPoint = .zero
    private var wlAnchor: Float = 0
    private var wwAnchor: Float = 0
    private var panAnchor = SIMD2<Float>(repeating: 0)
    private var activeMouseButton: MetalViewerMouseButton = .left
    private var activeMouseTool: MetalViewerMouseTool = .windowLevel
    private var mprDragMode: MPRDragMode = .none
    private var mprScrollAxisOverride: Int?
    private var isDraggingMPRPreviewDivider = false
    private var didChangeWindowLevelDuringDrag = false
    private var didDragMouseInteraction = false
    private var sliceDragAccumulator: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?
    private var preciseScrollSliceAccumulator: CGFloat = 0
    private let mprPreviewOverlayView = MetalMPRPreviewOverlayView(frame: .zero)

    private enum MPRDragMode {
        case none
        case rotate
        case pan
        case plane
        case planeTilt
        case previewPlane
    }

    private func mouseTool(for button: MetalViewerMouseButton, event: NSEvent) -> MetalViewerMouseTool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.shift) ? .pan : mouseToolAssignments.tool(for: button)
    }

    private static let preciseScrollPointsPerSlice: CGFloat = 18
    private static let momentumScrollPointsPerSlice: CGFloat = 60

    let renderer: MetalViewerRenderer
    var titleDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var interactionEventHandler: (() -> Void)?
    var annotationStateDidChange: (() -> Void)?
    var windowLevelInteractionHandler: (() -> Void)?
    var tumourSeedPlacementHandler: ((MetalViewerTumourSeedPlacement) -> Void)?
    var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private(set) var mouseAnnotationState: MouseAnnotationState?

    init(
        frame frameRect: NSRect,
        pixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)? = nil
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac.")
        }

        renderer = MetalViewerRenderer(device: device, pixList: pixList, windowLevelState: windowLevelState)
        super.init(frame: frameRect, device: device)

        self.delegate = renderer
        self.framebufferOnly = false
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.colorPixelFormat = .bgra8Unorm
        self.depthStencilPixelFormat = .depth32Float
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        self.preferredFramesPerSecond = 60

        mprPreviewOverlayView.owner = self
        mprPreviewOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mprPreviewOverlayView)
        NSLayoutConstraint.activate([
            mprPreviewOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mprPreviewOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mprPreviewOverlayView.topAnchor.constraint(equalTo: topAnchor),
            mprPreviewOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renderer.stateDidChange = { [weak self] state in
            self?.titleDidChange?(state)
            self?.needsDisplay = true
            self?.mprPreviewOverlayView.needsDisplay = true
            if let overlayView = self?.mprPreviewOverlayView {
                overlayView.window?.invalidateCursorRects(for: overlayView)
            }
            self?.annotationStateDidChange?()
        }
        renderer.windowLevelStateDidChange = windowLevelStateDidChange
        renderer.resetAndLoadInitialSlice()
        titleDidChange?(renderer.stateDescription)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        mprPreviewOverlayView.needsDisplay = true
        mprPreviewOverlayView.window?.invalidateCursorRects(for: mprPreviewOverlayView)
    }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        interactionEventHandler?()
        let point = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let phase = event.momentumPhase.isEmpty ? event.phase : event.momentumPhase

        if phase.contains(.began) {
            preciseScrollSliceAccumulator = 0
        }

        if renderer.displayMode == .mpr,
           renderer.mprSlicePlaneAxis(at: point, in: bounds) == nil {
            preciseScrollSliceAccumulator = 0
            zoomFromScrollWheel(delta: delta)
            updateMouseAnnotationState(from: point)
            return
        }

        if event.hasPreciseScrollingDeltas {
            preciseScrollSliceAccumulator += delta
            let scrollPointsPerSlice = event.momentumPhase.isEmpty ? Self.preciseScrollPointsPerSlice : Self.momentumScrollPointsPerSlice
            let stepCount = Int(preciseScrollSliceAccumulator / scrollPointsPerSlice)
            if stepCount != 0 {
                stepThroughCurrentMode(by: stepCount, event: event, at: point)
                preciseScrollSliceAccumulator -= CGFloat(stepCount) * scrollPointsPerSlice
            }
        } else if delta != 0 {
            stepThroughCurrentMode(by: delta > 0 ? 1 : -1, event: event, at: point)
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            preciseScrollSliceAccumulator = 0
        }
        updateMouseAnnotationState(from: point)
    }

    override func magnify(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        let zoomFactor = min(max(1.0 + Float(event.magnification), 0.1), 10.0)
        renderer.zoom(by: zoomFactor)
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        beginMouseInteraction(with: event, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        dragMouseInteraction(with: event, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        endMouseInteraction(with: event, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        beginMouseInteraction(with: event, button: .right)
    }

    override func rightMouseDragged(with event: NSEvent) {
        dragMouseInteraction(with: event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        endMouseInteraction(with: event, button: .right)
    }

    private func beginMouseInteraction(with event: NSEvent, button: MetalViewerMouseButton) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        dragAnchor = convert(event.locationInWindow, from: nil)
        wlAnchor = renderer.activeWindowLevel
        wwAnchor = renderer.activeWindowWidth
        panAnchor = renderer.panOffset
        activeMouseButton = button
        activeMouseTool = mouseTool(for: button, event: event)
        didChangeWindowLevelDuringDrag = false
        didDragMouseInteraction = false
        sliceDragAccumulator = 0
        mprScrollAxisOverride = nil
        if renderer.displayMode == .mpr {
            switch activeMouseTool {
            case .pan:
                mprDragMode = .pan
            case .windowLevel, .rotate:
                if renderer.beginMPRPreviewPlaneDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .previewPlane
                } else if renderer.beginMPRPlaneDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .plane
                } else if renderer.beginMPRPlaneTiltDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .planeTilt
                } else {
                    mprDragMode = .rotate
                }
            case .scroll:
                mprScrollAxisOverride = renderer.mprSlicePlaneAxis(at: dragAnchor, in: bounds)
                mprDragMode = .none
            case .zoom, .tumourSeed:
                mprDragMode = .none
            }
        } else {
            mprDragMode = .none
        }
        updateMouseAnnotationState(from: dragAnchor)
    }

    private func dragMouseInteraction(with event: NSEvent, button: MetalViewerMouseButton) {
        guard button == activeMouseButton else {
            return
        }
        interactionEventHandler?()
        let currentPoint = convert(event.locationInWindow, from: nil)
        let currentMouseTool = mouseTool(for: activeMouseButton, event: event)

        if currentMouseTool != activeMouseTool,
           mprDragMode != .plane,
           mprDragMode != .planeTilt,
           mprDragMode != .previewPlane {
            activeMouseTool = currentMouseTool
            dragAnchor = currentPoint
            wlAnchor = renderer.activeWindowLevel
            wwAnchor = renderer.activeWindowWidth
            panAnchor = renderer.panOffset
            sliceDragAccumulator = 0
            mprScrollAxisOverride = nil
            if renderer.displayMode == .mpr {
                switch currentMouseTool {
                case .pan:
                    mprDragMode = .pan
                case .windowLevel, .rotate:
                    if renderer.beginMPRPreviewPlaneDrag(at: currentPoint, in: bounds) {
                        mprDragMode = .previewPlane
                    } else {
                        mprDragMode = .rotate
                    }
                case .scroll:
                    mprScrollAxisOverride = renderer.mprSlicePlaneAxis(at: currentPoint, in: bounds)
                    mprDragMode = .none
                case .zoom, .tumourSeed:
                    mprDragMode = .none
                }
            }
        }

        let deltaX = Float(currentPoint.x - dragAnchor.x)
        let deltaY = Float(currentPoint.y - dragAnchor.y)
        if hypot(currentPoint.x - dragAnchor.x, currentPoint.y - dragAnchor.y) > 3 {
            didDragMouseInteraction = true
        }

        if renderer.displayMode == .mpr {
            dragMPRInteraction(
                tool: activeMouseTool,
                currentPoint: currentPoint,
                deltaX: deltaX,
                deltaY: deltaY,
                event: event
            )
            updateMouseAnnotationState(from: currentPoint)
            return
        }

        dragStackInteraction(
            tool: activeMouseTool,
            currentPoint: currentPoint,
            deltaX: deltaX,
            deltaY: deltaY,
            event: event
        )
        updateMouseAnnotationState(from: currentPoint)
    }

    private func endMouseInteraction(with event: NSEvent, button: MetalViewerMouseButton) {
        guard button == activeMouseButton else {
            return
        }
        interactionEventHandler?()
        renderer.endMPRPlaneDrag()
        mprDragMode = .none
        mprScrollAxisOverride = nil
        sliceDragAccumulator = 0
        let currentPoint = convert(event.locationInWindow, from: nil)
        if activeMouseTool == .tumourSeed,
           didDragMouseInteraction == false,
           let placement = renderer.tumourSeedPlacement(at: currentPoint, in: bounds) {
            tumourSeedPlacementHandler?(placement)
        }
        if didChangeWindowLevelDuringDrag, renderer.displayMode == .stack2D {
            renderer.commitWindowLevel()
        }
        didChangeWindowLevelDuringDrag = false
        didDragMouseInteraction = false
        updateMouseAnnotationState(from: currentPoint)
    }

    private func dragStackInteraction(
        tool: MetalViewerMouseTool,
        currentPoint: CGPoint,
        deltaX: Float,
        deltaY: Float,
        event: NSEvent
    ) {
        switch tool {
        case .windowLevel:
            renderer.updateWindowLevel(
                wl: wlAnchor - deltaY * max(abs(wlAnchor), 128) * 0.003,
                ww: wwAnchor + deltaX * max(abs(wwAnchor), 256) * 0.003
            )
            didChangeWindowLevelDuringDrag = true
            windowLevelInteractionHandler?()
        case .pan:
            renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
        case .zoom:
            zoomFromDrag(deltaY: deltaY, currentPoint: currentPoint)
        case .scroll:
            scrollFromDrag(to: currentPoint, event: event)
        case .rotate:
            renderer.rotateStack(from: dragAnchor, to: currentPoint, in: bounds)
            dragAnchor = currentPoint
        case .tumourSeed:
            break
        }
    }

    private func dragMPRInteraction(
        tool: MetalViewerMouseTool,
        currentPoint: CGPoint,
        deltaX: Float,
        deltaY: Float,
        event: NSEvent
    ) {
        switch tool {
        case .pan:
            renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
        case .zoom:
            zoomFromDrag(deltaY: deltaY, currentPoint: currentPoint)
        case .scroll:
            scrollOrScaleMPRFromDrag(to: currentPoint, deltaY: deltaY, event: event)
        case .windowLevel, .rotate:
            switch mprDragMode {
            case .plane:
                renderer.dragMPRPlane(to: currentPoint)
            case .planeTilt:
                renderer.dragMPRPlaneTilt(to: currentPoint)
            case .previewPlane:
                renderer.dragMPRPreviewPlane(to: currentPoint, in: bounds)
            case .rotate:
                renderer.rotateMPR(from: dragAnchor, to: currentPoint, in: bounds)
                dragAnchor = currentPoint
            case .pan:
                renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
            case .none:
                break
            }
        case .tumourSeed:
            break
        }
    }

    private func zoomFromDrag(deltaY: Float, currentPoint: CGPoint) {
        let zoomFactor = min(max(Float(exp(Double(deltaY) * 0.01)), 0.05), 20)
        renderer.zoom(by: zoomFactor)
        dragAnchor = currentPoint
        panAnchor = renderer.panOffset
    }

    private func zoomFromScrollWheel(delta: CGFloat) {
        guard delta != 0 else { return }
        let zoomFactor = min(max(Float(exp(Double(delta) * 0.0015)), 0.05), 20)
        renderer.zoom(by: zoomFactor)
    }

    private func scrollFromDrag(to currentPoint: CGPoint, event: NSEvent) {
        sliceDragAccumulator += currentPoint.y - dragAnchor.y
        dragAnchor = currentPoint

        let stepCount = Int(sliceDragAccumulator / 14)
        guard stepCount != 0 else {
            return
        }

        stepThroughCurrentMode(by: stepCount, event: event, at: currentPoint)
        sliceDragAccumulator -= CGFloat(stepCount * 14)
    }

    private func scrollOrScaleMPRFromDrag(to currentPoint: CGPoint, deltaY: Float, event: NSEvent) {
        if mprScrollAxisOverride == nil {
            mprScrollAxisOverride = renderer.mprSlicePlaneAxis(at: currentPoint, in: bounds)
        }

        guard mprScrollAxisOverride != nil else {
            sliceDragAccumulator = 0
            zoomFromDrag(deltaY: deltaY, currentPoint: currentPoint)
            return
        }

        scrollFromDrag(to: currentPoint, event: event)
    }

    func beginMPRPreviewDividerDrag(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        isDraggingMPRPreviewDivider = true
        updateMPRPreviewDivider(with: event)
    }

    func dragMPRPreviewDivider(with event: NSEvent) {
        guard isDraggingMPRPreviewDivider else { return }
        interactionEventHandler?()
        updateMPRPreviewDivider(with: event)
    }

    func endMPRPreviewDividerDrag(with event: NSEvent) {
        guard isDraggingMPRPreviewDivider else { return }
        interactionEventHandler?()
        updateMPRPreviewDivider(with: event)
        isDraggingMPRPreviewDivider = false
    }

    override func mouseMoved(with event: NSEvent) {
        interactionEventHandler?()
        let point = convert(event.locationInWindow, from: nil)
        updateMouseAnnotationState(from: point)
    }

    override func mouseExited(with event: NSEvent) {
        renderer.updateMPRHover(at: nil, in: bounds)
        if mouseAnnotationState != nil {
            mouseAnnotationState = nil
            annotationStateDidChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // left arrow
            renderer.stepSlice(by: 1)
        case 124: // right arrow
            renderer.stepSlice(by: -1)
        case 126: // up arrow
            renderer.zoom(by: 1.1)
        case 125: // down arrow
            renderer.zoom(by: 1.0 / 1.1)
        case 15: // r
            renderer.rerunRegistration()
        default:
            super.keyDown(with: event)
        }
    }

    var currentSliceGeometry: MetalViewerSliceGeometry? {
        guard let pix = renderer.currentPix else { return nil }
        return MetalViewerSliceGeometry(pix: pix)
    }

    var displayedImageRect: CGRect {
        renderer.imageRect(in: bounds)
    }

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        renderer.setDisplayMode(mode)
        mouseAnnotationState = nil
        annotationStateDidChange?()
    }

    private func stepThroughCurrentMode(by stepCount: Int, event: NSEvent, at point: CGPoint? = nil) {
        if renderer.displayMode == .mpr {
            renderer.moveMPRPlane(axis: mprScrollAxis(for: event, at: point), by: -Float(stepCount))
        } else {
            renderer.stepSlice(by: stepCount)
        }
    }

    private func mprScrollAxis(for event: NSEvent, at point: CGPoint?) -> Int {
        if let mprScrollAxisOverride {
            return mprScrollAxisOverride
        }
        if let point,
           let slicePlaneAxis = renderer.mprSlicePlaneAxis(at: point, in: bounds) {
            return slicePlaneAxis
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) {
            return 0
        }
        if flags.contains(.shift) {
            return 1
        }
        return 2
    }

    private func updateMPRPreviewDivider(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        renderer.setMPRPreviewDividerLocation(point.x, in: bounds)
        needsDisplay = true
        mprPreviewOverlayView.needsDisplay = true
        mprPreviewOverlayView.window?.invalidateCursorRects(for: mprPreviewOverlayView)
    }

    private func updateMouseAnnotationState(from point: CGPoint) {
        guard renderer.displayMode == .stack2D else {
            renderer.updateMPRHover(at: point, in: bounds)
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

        guard let pix = renderer.currentPix else {
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

        guard let normalizedImagePoint = renderer.normalizedImagePoint(for: point, in: bounds),
              let nextMouseAnnotationState = mouseAnnotationState(for: pix, normalizedImagePoint: normalizedImagePoint) else {
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

        mouseAnnotationState = nextMouseAnnotationState
        annotationStateDidChange?()
    }

    private func mouseAnnotationState(for pix: DCMPix, normalizedImagePoint: CGPoint) -> MouseAnnotationState? {
        pix.checking.lock()
        defer { pix.checking.unlock() }

        pix.checkLoad()
        let width = Int(pix.pwidth)
        let height = Int(pix.pheight)
        guard width > 0,
              height > 0,
              let imagePointer = pix.fImage else {
            return nil
        }

        let pixelX = max(0, min(CGFloat(width - 1), normalizedImagePoint.x * CGFloat(width)))
        let pixelY = max(0, min(CGFloat(height - 1), normalizedImagePoint.y * CGFloat(height)))
        let sampleX = min(max(Int(pixelX), 0), width - 1)
        let sampleY = min(max(Int(pixelY), 0), height - 1)
        let pixelValue = imagePointer[sampleY * width + sampleX]

        var dicomCoords = [Float](repeating: 0, count: 3)
        pix.convertX(Float(pixelX), pixY: Float(pixelY), toDICOMCoords: &dicomCoords, pixelCenter: true)

        return MouseAnnotationState(
            pixelPoint: CGPoint(x: pixelX, y: pixelY),
            pixelValue: pixelValue,
            dicomPoint: SIMD3<Float>(dicomCoords[0], dicomCoords[1], dicomCoords[2])
        )
    }
}
