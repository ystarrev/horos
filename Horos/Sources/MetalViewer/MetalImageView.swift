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
              owner.renderer.displayMode.isMPRLike,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }

        if layout.dividerRect.width > 0, layout.dividerRect.height > 0 {
            NSColor(calibratedWhite: 0.18, alpha: 0.9).setFill()
            layout.dividerRect.fill()
            NSColor(calibratedWhite: 0.55, alpha: 0.8).setFill()
            CGRect(x: layout.dividerRect.midX - 0.5, y: layout.dividerRect.minY, width: 1, height: layout.dividerRect.height).fill()
        }

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
              owner.renderer.displayMode.isMPRLike,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds),
              layout.dividerRect.width > 0,
              layout.dividerRect.insetBy(dx: -5, dy: 0).contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let owner,
              owner.renderer.displayMode.isMPRLike,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }
        if layout.dividerRect.width > 0 {
            addCursorRect(layout.dividerRect.insetBy(dx: -5, dy: 0), cursor: .resizeLeftRight)
        }
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
    private var measurements: [MetalViewerMeasurement] = []
    private var activeMeasurementIdentifier: String?
    private var selectedMeasurementIdentifier: String?
    private var activeMeasurementDragMode: MeasurementDragMode?
    private var activeTumourSeedDeletion = false

    private enum MeasurementHitComponent {
        case startHandle
        case endHandle
        case label
        case line
    }

    private struct MeasurementHit {
        let identifier: String
        let component: MeasurementHitComponent
    }

    private enum MeasurementDragMode {
        case create
        case startHandle
        case endHandle
        case label(startPoint: CGPoint, startOffset: CGPoint)
        case selectOnly
    }

    private enum MPRDragMode {
        case none
        case rotate
        case pan
        case plane
        case planeTilt
        case previewPlane
    }

    private struct MPRLineCursorKey: Equatable {
        let interaction: MetalMPRPreviewLineInteraction
        let lineAngleBucket: Int
        let actionAngleBucket: Int
    }

    private var mprLineCursorCache: (key: MPRLineCursorKey, cursor: NSCursor)?
    private var mprLineCursorContinuousAngle: CGFloat?

    private static let mprLineCursorAngleBucketsPerTurn = 1440

    private func mprLineCursor(for pointer: MetalMPRPreviewLinePointer) -> NSCursor {
        let lineAngle: CGFloat
        if pointer.interaction == .tilt,
           let actionAngleRadians = pointer.actionAngleRadians {
            lineAngle = actionAngleRadians
        } else {
            lineAngle = Self.mprLineCursorLineAngle(
                pointer.lineAngleRadians,
                closestTo: mprLineCursorContinuousAngle
            )
        }
        mprLineCursorContinuousAngle = lineAngle
        let key = Self.mprLineCursorKey(for: pointer, lineAngleRadians: lineAngle)
        if let cached = mprLineCursorCache, cached.key == key {
            return cached.cursor
        }

        let cursorLineAngle = Self.mprLineCursorLineAngle(for: key)
        let actionAngle = Self.mprLineCursorActionAngle(for: key)
        let cursor: NSCursor
        switch key.interaction {
        case .move:
            cursor = Self.makeMPRLineMoveCursor(
                lineAngleRadians: cursorLineAngle,
                translationAngleRadians: actionAngle
            )
        case .tilt:
            cursor = Self.makeMPRLineTiltCursor(
                lineAngleRadians: cursorLineAngle,
                radiusAngleRadians: actionAngle
            )
        }

        mprLineCursorCache = (key, cursor)
        return cursor
    }

    private static func mprLineCursorKey(
        for pointer: MetalMPRPreviewLinePointer,
        lineAngleRadians: CGFloat
    ) -> MPRLineCursorKey {
        let lineAngle = normalizedMPRLineCursorFullTurnAngle(lineAngleRadians)
        let actionAngle: CGFloat
        switch pointer.interaction {
        case .move:
            actionAngle = lineAngle + CGFloat.pi * 0.5
        case .tilt:
            actionAngle = pointer.actionAngleRadians ?? lineAngle
        }
        return MPRLineCursorKey(
            interaction: pointer.interaction,
            lineAngleBucket: mprLineCursorLineAngleBucket(lineAngle),
            actionAngleBucket: mprLineCursorActionAngleBucket(actionAngle)
        )
    }

    private static func mprLineCursorLineAngle(for key: MPRLineCursorKey) -> CGFloat {
        CGFloat(key.lineAngleBucket) * CGFloat.pi * 2 / CGFloat(mprLineCursorAngleBucketsPerTurn)
    }

    private static func mprLineCursorActionAngle(for key: MPRLineCursorKey) -> CGFloat {
        CGFloat(key.actionAngleBucket) * CGFloat.pi * 2 / CGFloat(mprLineCursorAngleBucketsPerTurn)
    }

    private static func mprLineCursorLineAngleBucket(_ angle: CGFloat) -> Int {
        mprLineCursorActionAngleBucket(angle)
    }

    private static func mprLineCursorLineAngle(_ angle: CGFloat, closestTo reference: CGFloat?) -> CGFloat {
        let baseAngle = normalizedMPRLineCursorHalfTurnAngle(angle)
        guard let reference else {
            return baseAngle
        }
        return baseAngle + ((reference - baseAngle) / CGFloat.pi).rounded() * CGFloat.pi
    }

    private static func mprLineCursorActionAngleBucket(_ angle: CGFloat) -> Int {
        let normalizedAngle = normalizedMPRLineCursorFullTurnAngle(angle)
        let bucketScale = CGFloat(mprLineCursorAngleBucketsPerTurn) / (CGFloat.pi * 2)
        return Int((normalizedAngle * bucketScale).rounded()) % mprLineCursorAngleBucketsPerTurn
    }

    private static func normalizedMPRLineCursorHalfTurnAngle(_ angle: CGFloat) -> CGFloat {
        var normalized = angle.truncatingRemainder(dividingBy: CGFloat.pi)
        if normalized < 0 {
            normalized += CGFloat.pi
        }
        return normalized
    }

    private static func normalizedMPRLineCursorFullTurnAngle(_ angle: CGFloat) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: fullTurn)
        if normalized < 0 {
            normalized += fullTurn
        }
        return normalized
    }

    private static func makeMPRLineMoveCursor(
        lineAngleRadians: CGFloat,
        translationAngleRadians: CGFloat
    ) -> NSCursor {
        makeCursor { size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let lineHalfLength: CGFloat = 8
            let arrowHalfLength: CGFloat = 9
            let lineStart = cursorPoint(CGPoint(x: -lineHalfLength, y: 0), center: center, angle: lineAngleRadians)
            let lineEnd = cursorPoint(CGPoint(x: lineHalfLength, y: 0), center: center, angle: lineAngleRadians)
            let arrowStart = cursorPoint(CGPoint(x: -arrowHalfLength, y: 0), center: center, angle: translationAngleRadians)
            let arrowEnd = cursorPoint(CGPoint(x: arrowHalfLength, y: 0), center: center, angle: translationAngleRadians)

            drawCursorStrokes { width, color in
                strokeCursorLine(from: lineStart, to: lineEnd, width: width, color: color)
                strokeCursorDoubleArrow(from: arrowStart, to: arrowEnd, width: width, color: color)
            }
        }
    }

    private static func makeMPRLineTiltCursor(
        lineAngleRadians: CGFloat,
        radiusAngleRadians: CGFloat
    ) -> NSCursor {
        makeCursor { size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let lineHalfLength: CGFloat = 7
            let lineStart = cursorPoint(CGPoint(x: -lineHalfLength, y: 0), center: center, angle: lineAngleRadians)
            let lineEnd = cursorPoint(CGPoint(x: lineHalfLength, y: 0), center: center, angle: lineAngleRadians)
            let radius: CGFloat = 12
            let arcCenter = cursorPoint(CGPoint(x: radius, y: 0), center: center, angle: radiusAngleRadians)
            let startAngle = atan2(center.y - arcCenter.y, center.x - arcCenter.x)
            let arcSweep = CGFloat.pi * 0.42

            drawCursorStrokes { width, color in
                strokeCursorLine(from: lineStart, to: lineEnd, width: width, color: color)
                strokeCursorCircularArrow(
                    center: arcCenter,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: startAngle + arcSweep,
                    width: width,
                    color: color
                )
                strokeCursorCircularArrow(
                    center: arcCenter,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: startAngle - arcSweep,
                    width: width,
                    color: color
                )
            }
        }
    }

    private static func makeCursor(draw: (CGSize) -> Void) -> NSCursor {
        let size = CGSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        draw(size)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
    }

    private static func strokeCursorLine(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func strokeCursorDoubleArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        strokeCursorLine(from: start, to: end, width: width, color: color)
        strokeCursorArrowHead(at: start, from: end, width: width, color: color)
        strokeCursorArrowHead(at: end, from: start, width: width, color: color)
    }

    private static func strokeCursorArrowHead(at tip: CGPoint, from tail: CGPoint, width: CGFloat, color: NSColor) {
        let dx = tip.x - tail.x
        let dy = tip.y - tail.y
        let length = max(hypot(dx, dy), 0.0001)
        let unitX = dx / length
        let unitY = dy / length
        let headLength: CGFloat = 5
        let headWidth: CGFloat = 4
        let base = CGPoint(x: tip.x - unitX * headLength, y: tip.y - unitY * headLength)
        let normalX = -unitY
        let normalY = unitX
        let left = CGPoint(x: base.x + normalX * headWidth, y: base.y + normalY * headWidth)
        let right = CGPoint(x: base.x - normalX * headWidth, y: base.y - normalY * headWidth)
        strokeCursorLine(from: left, to: tip, width: width, color: color)
        strokeCursorLine(from: right, to: tip, width: width, color: color)
    }

    private static func strokeCursorCircularArrow(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        width: CGFloat,
        color: NSColor
    ) {
        let points = cursorCircularArcPoints(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle
        )
        guard points.count >= 2 else {
            return
        }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()

        strokeCursorArrowHead(at: points[points.count - 1], from: points[points.count - 2], width: width, color: color)
    }

    private static func cursorCircularArcPoints(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat
    ) -> [CGPoint] {
        let steps = 24
        return (0...steps).map { index in
            let fraction = CGFloat(index) / CGFloat(steps)
            let angle = startAngle + (endAngle - startAngle) * fraction
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
    }

    private static func cursorPoint(_ local: CGPoint, center: CGPoint, angle: CGFloat) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(
            x: center.x + local.x * cosine - local.y * sine,
            y: center.y + local.x * sine + local.y * cosine
        )
    }

    private static func drawCursorStrokes(_ draw: (CGFloat, NSColor) -> Void) {
        draw(4, .black)
        draw(2, .white)
    }

    private func mouseTool(for button: MetalViewerMouseButton, event: NSEvent) -> MetalViewerMouseTool {
        let assignedTool = mouseToolAssignments.tool(for: button)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           button == .right,
           mouseToolAssignments.tool(for: .left) == .tumourSeed {
            return .tumourSeed
        }
        if flags.contains(.shift),
           assignedTool != .measure,
           activeMouseTool != .measure {
            return .pan
        }
        return assignedTool
    }

    private static let preciseScrollPointsPerSlice: CGFloat = 18
    private static let momentumScrollPointsPerSlice: CGFloat = 60
    private static let measurementLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    let renderer: MetalViewerRenderer
    var titleDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var interactionEventHandler: (() -> Void)?
    var annotationStateDidChange: (() -> Void)?
    var windowLevelInteractionHandler: (() -> Void)?
    var windowLevelInteractionAllowedHandler: (() -> Bool)?
    var tumourSeedPlacementHandler: ((MetalViewerTumourSeedPlacement) -> Void)?
    var tumourSeedDeletionHandler: ((String) -> Void)?
    var measurementsDidChange: (([MetalViewerMeasurementOverlay]) -> Void)?
    var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private(set) var mouseAnnotationState: MouseAnnotationState?

    init(
        frame frameRect: NSRect,
        pixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)? = nil,
        usesAutomaticWindowLevel: Bool = false,
        transferFunctionState: MetalViewerTransferFunctionState = MetalViewerTransferFunctionState(),
        transferFunctionStateDidChange: ((MetalViewerTransferFunctionState) -> Void)? = nil
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac.")
        }

        renderer = MetalViewerRenderer(
            device: device,
            pixList: pixList,
            windowLevelState: windowLevelState,
            usesAutomaticWindowLevel: usesAutomaticWindowLevel,
            transferFunctionState: transferFunctionState
        )
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
        mprPreviewOverlayView.frame = bounds
        mprPreviewOverlayView.autoresizingMask = [.width, .height]
        addSubview(mprPreviewOverlayView)

        renderer.stateDidChange = { [weak self] state in
            self?.titleDidChange?(state)
            self?.needsDisplay = true
            self?.mprPreviewOverlayView.needsDisplay = true
            if let overlayView = self?.mprPreviewOverlayView {
                overlayView.window?.invalidateCursorRects(for: overlayView)
            }
            self?.publishMeasurementOverlays()
            self?.annotationStateDidChange?()
        }
        renderer.windowLevelStateDidChange = windowLevelStateDidChange
        renderer.transferFunctionStateDidChange = transferFunctionStateDidChange
        renderer.resetAndLoadInitialSlice()
        titleDidChange?(renderer.stateDescription)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func display(pixList: [DCMPix], preservingSliceIndex: Bool = true) {
        renderer.setPixList(pixList, preservingSliceIndex: preservingSliceIndex)
        needsDisplay = true
        mprPreviewOverlayView.needsDisplay = true
        publishMeasurementOverlays()
        annotationStateDidChange?()
    }

    override func layout() {
        super.layout()
        mprPreviewOverlayView.needsDisplay = true
        mprPreviewOverlayView.window?.invalidateCursorRects(for: mprPreviewOverlayView)
        publishMeasurementOverlays()
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

        if renderer.displayMode.isMPRLike,
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
        activeTumourSeedDeletion = activeMouseTool == .tumourSeed
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
        didChangeWindowLevelDuringDrag = false
        didDragMouseInteraction = false
        sliceDragAccumulator = 0
        mprScrollAxisOverride = nil
        if activeMouseTool == .measure {
            beginMeasurementInteraction(at: dragAnchor)
            mprDragMode = .none
            updateMouseAnnotationState(from: dragAnchor)
            return
        }
        if renderer.displayMode.isMPRLike {
            switch activeMouseTool {
            case .pan:
                mprDragMode = .pan
            case .windowLevel:
                mprDragMode = .none
            case .rotate:
                if renderer.beginMPRPreviewPlaneMoveDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .plane
                } else if renderer.beginMPRPreviewPlaneTiltDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .planeTilt
                } else if renderer.beginMPRPreviewPlaneDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .previewPlane
                } else if renderer.displayMode == .mpr, renderer.beginMPRPlaneDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .plane
                } else if renderer.displayMode == .mpr, renderer.beginMPRPlaneTiltDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .planeTilt
                } else if renderer.displayMode == .mpr {
                    mprDragMode = .rotate
                } else {
                    mprDragMode = .none
                }
            case .scroll:
                mprScrollAxisOverride = renderer.mprSlicePlaneAxis(at: dragAnchor, in: bounds)
                mprDragMode = .none
            case .zoom, .measure, .tumourSeed:
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

        if activeMouseTool != .measure,
           currentMouseTool != activeMouseTool,
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
            if renderer.displayMode.isMPRLike {
                switch currentMouseTool {
                case .pan:
                    mprDragMode = .pan
                case .windowLevel:
                    mprDragMode = .none
                case .rotate:
                    if renderer.beginMPRPreviewPlaneMoveDrag(at: currentPoint, in: bounds) {
                        mprDragMode = .plane
                    } else if renderer.beginMPRPreviewPlaneTiltDrag(at: currentPoint, in: bounds) {
                        mprDragMode = .planeTilt
                    } else if renderer.beginMPRPreviewPlaneDrag(at: currentPoint, in: bounds) {
                        mprDragMode = .previewPlane
                    } else if renderer.displayMode == .mpr {
                        mprDragMode = .rotate
                    } else {
                        mprDragMode = .none
                    }
                case .scroll:
                    mprScrollAxisOverride = renderer.mprSlicePlaneAxis(at: currentPoint, in: bounds)
                    mprDragMode = .none
                case .zoom, .measure, .tumourSeed:
                    mprDragMode = .none
                }
            }
        }

        let deltaX = Float(currentPoint.x - dragAnchor.x)
        let deltaY = Float(currentPoint.y - dragAnchor.y)
        if hypot(currentPoint.x - dragAnchor.x, currentPoint.y - dragAnchor.y) > 3 {
            didDragMouseInteraction = true
        }

        if renderer.displayMode.isMPRLike {
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
        if activeMouseTool == .measure {
            finishMeasurementInteraction(at: currentPoint, event: event)
        }
        if activeMouseTool == .tumourSeed,
           didDragMouseInteraction == false {
            if activeTumourSeedDeletion {
                if let identifier = renderer.tumourSeedIdentifier(at: currentPoint, in: bounds) {
                    tumourSeedDeletionHandler?(identifier)
                }
            } else if let placement = renderer.tumourSeedPlacement(at: currentPoint, in: bounds) {
                tumourSeedPlacementHandler?(placement)
            }
        }
        if didChangeWindowLevelDuringDrag {
            renderer.commitWindowLevel()
        }
        didChangeWindowLevelDuringDrag = false
        didDragMouseInteraction = false
        activeTumourSeedDeletion = false
        updateMouseAnnotationState(from: currentPoint)
        if renderer.displayMode.isMPRLike {
            updateMPRLineCursor(at: currentPoint, event: event)
        }
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
            updateWindowLevelFromDrag(deltaX: deltaX, deltaY: deltaY)
        case .pan:
            renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
        case .zoom:
            zoomFromDrag(deltaY: deltaY, currentPoint: currentPoint)
        case .scroll:
            scrollFromDrag(to: currentPoint, event: event)
        case .rotate:
            renderer.rotateStack(from: dragAnchor, to: currentPoint, in: bounds)
            dragAnchor = currentPoint
        case .measure:
            dragMeasurementInteraction(to: currentPoint, event: event)
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
        case .windowLevel:
            updateWindowLevelFromDrag(deltaX: deltaX, deltaY: deltaY)
        case .rotate:
            switch mprDragMode {
            case .plane:
                renderer.dragMPRPlane(to: currentPoint)
                updateActiveMPRLineCursor()
            case .planeTilt:
                renderer.dragMPRPlaneTilt(to: currentPoint)
                updateActiveMPRLineCursor()
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
        case .measure:
            dragMeasurementInteraction(to: currentPoint, event: event)
        case .tumourSeed:
            break
        }
    }

    private func updateWindowLevelFromDrag(deltaX: Float, deltaY: Float) {
        guard windowLevelInteractionAllowedHandler?() ?? true else { return }
        renderer.updateWindowLevel(
            wl: wlAnchor - deltaY * max(abs(wlAnchor), 128) * 0.003,
            ww: wwAnchor + deltaX * max(abs(wwAnchor), 256) * 0.003
        )
        didChangeWindowLevelDuringDrag = true
        windowLevelInteractionHandler?()
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

    private func beginMeasurementInteraction(at point: CGPoint) {
        activeMeasurementIdentifier = nil
        activeMeasurementDragMode = nil

        if let hit = measurementHit(at: point) {
            selectMeasurement(hit.identifier)
            activeMeasurementIdentifier = hit.identifier
            switch hit.component {
            case .startHandle:
                activeMeasurementDragMode = .startHandle
            case .endHandle:
                activeMeasurementDragMode = .endHandle
            case .label:
                let startOffset = measurements.first { $0.identifier == hit.identifier }?.labelOffset ?? .zero
                activeMeasurementDragMode = .label(startPoint: point, startOffset: startOffset)
            case .line:
                activeMeasurementDragMode = .selectOnly
            }
            return
        }

        if selectedMeasurementIdentifier != nil {
            deselectMeasurements()
            return
        }

        beginNewMeasurement(at: point)
    }

    private func beginNewMeasurement(at point: CGPoint) {
        guard let measurementPoint = renderer.measurementPoint(at: point, in: bounds) else {
            activeMeasurementIdentifier = nil
            activeMeasurementDragMode = nil
            return
        }

        let measurement = MetalViewerMeasurement(
            identifier: UUID().uuidString,
            start: measurementPoint,
            end: measurementPoint,
            isActive: true
        )
        measurements.append(measurement)
        activeMeasurementIdentifier = measurement.identifier
        activeMeasurementDragMode = .create
        selectedMeasurementIdentifier = nil
        publishMeasurementOverlays()
    }

    private func dragMeasurementInteraction(to currentPoint: CGPoint, event: NSEvent) {
        guard let mode = activeMeasurementDragMode else {
            return
        }

        switch mode {
        case .create:
            updateCreatedMeasurement(to: currentPoint, event: event)
        case .startHandle:
            updateMeasurementEndpoint(.startHandle, to: currentPoint, event: event)
        case .endHandle:
            updateMeasurementEndpoint(.endHandle, to: currentPoint, event: event)
        case let .label(startPoint, startOffset):
            updateMeasurementLabelOffset(startPoint: startPoint, startOffset: startOffset, currentPoint: currentPoint)
        case .selectOnly:
            break
        }
    }

    private func updateCreatedMeasurement(to currentPoint: CGPoint, event: NSEvent) {
        guard let identifier = activeMeasurementIdentifier,
              let index = measurements.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }

        let measurement = measurements[index]
        let startViewPoint = renderer.screenPoint(for: measurement.start, in: bounds) ?? currentPoint
        let targetPoint = constrainedMeasurementTarget(from: startViewPoint, to: currentPoint, event: event)
        guard let endPoint = renderer.measurementPoint(at: targetPoint, in: bounds),
              measurementPoint(endPoint, isCompatibleWith: measurement.start) else {
            return
        }

        measurements[index].end = endPoint
        publishMeasurementOverlays()
    }

    private func updateMeasurementEndpoint(_ component: MeasurementHitComponent, to currentPoint: CGPoint, event: NSEvent) {
        guard let identifier = activeMeasurementIdentifier,
              let index = measurements.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }

        let measurement = measurements[index]
        let fixedPoint: MetalViewerMeasurementPoint
        switch component {
        case .startHandle:
            fixedPoint = measurement.end
        case .endHandle:
            fixedPoint = measurement.start
        case .label, .line:
            return
        }

        guard let fixedViewPoint = renderer.screenPoint(for: fixedPoint, in: bounds) else {
            return
        }

        let targetPoint = constrainedMeasurementTarget(from: fixedViewPoint, to: currentPoint, event: event)
        guard let draggedPoint = renderer.measurementPoint(at: targetPoint, in: bounds),
              measurementPoint(draggedPoint, isCompatibleWith: fixedPoint) else {
            return
        }

        switch component {
        case .startHandle:
            measurements[index].start = draggedPoint
        case .endHandle:
            measurements[index].end = draggedPoint
        case .label, .line:
            break
        }
        selectMeasurement(identifier, publish: false)
        publishMeasurementOverlays()
    }

    private func updateMeasurementLabelOffset(startPoint: CGPoint, startOffset: CGPoint, currentPoint: CGPoint) {
        guard let identifier = activeMeasurementIdentifier,
              let index = measurements.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }

        measurements[index].labelOffset = CGPoint(
            x: startOffset.x + currentPoint.x - startPoint.x,
            y: startOffset.y + currentPoint.y - startPoint.y
        )
        selectMeasurement(identifier, publish: false)
        publishMeasurementOverlays()
    }

    private func finishMeasurementInteraction(at currentPoint: CGPoint, event: NSEvent) {
        guard let mode = activeMeasurementDragMode else {
            activeMeasurementIdentifier = nil
            return
        }

        switch mode {
        case .create:
            finalizeCreatedMeasurement(at: currentPoint, event: event)
        case .startHandle, .endHandle, .label, .selectOnly:
            activeMeasurementIdentifier = nil
            activeMeasurementDragMode = nil
            publishMeasurementOverlays()
        }
    }

    private func finalizeCreatedMeasurement(at currentPoint: CGPoint, event: NSEvent) {
        updateCreatedMeasurement(to: currentPoint, event: event)

        guard let identifier = activeMeasurementIdentifier,
              let index = measurements.firstIndex(where: { $0.identifier == identifier }) else {
            activeMeasurementIdentifier = nil
            activeMeasurementDragMode = nil
            return
        }

        let measurement = measurements[index]
        let startPoint = renderer.screenPoint(for: measurement.start, in: bounds)
        let endPoint = renderer.screenPoint(for: measurement.end, in: bounds)
        let screenDistance = startPoint.flatMap { start in
            endPoint.map { hypot($0.x - start.x, $0.y - start.y) }
        } ?? 0

        if screenDistance <= 3 || measurement.lengthMM <= 0.0001 {
            measurements.remove(at: index)
        } else {
            measurements[index].isActive = false
        }
        activeMeasurementIdentifier = nil
        activeMeasurementDragMode = nil
        selectedMeasurementIdentifier = nil
        publishMeasurementOverlays()
    }

    private func measurementHit(at point: CGPoint) -> MeasurementHit? {
        for measurement in measurements.reversed() {
            guard let startPoint = renderer.screenPoint(for: measurement.start, in: bounds),
                  let endPoint = renderer.screenPoint(for: measurement.end, in: bounds) else {
                continue
            }

            if hypot(point.x - startPoint.x, point.y - startPoint.y) <= 9 {
                return MeasurementHit(identifier: measurement.identifier, component: .startHandle)
            }
            if hypot(point.x - endPoint.x, point.y - endPoint.y) <= 9 {
                return MeasurementHit(identifier: measurement.identifier, component: .endHandle)
            }
            if measurementLabelRect(for: measurement, startPoint: startPoint, endPoint: endPoint)
                .insetBy(dx: -4, dy: -4)
                .contains(point) {
                return MeasurementHit(identifier: measurement.identifier, component: .label)
            }
            if distance(from: point, toSegmentFrom: startPoint, to: endPoint) <= 5 {
                return MeasurementHit(identifier: measurement.identifier, component: .line)
            }
        }

        return nil
    }

    private func selectMeasurement(_ identifier: String, publish: Bool = true) {
        selectedMeasurementIdentifier = identifier
        for index in measurements.indices {
            measurements[index].isActive = measurements[index].identifier == identifier
        }
        if publish {
            publishMeasurementOverlays()
        }
    }

    private func deselectMeasurements() {
        selectedMeasurementIdentifier = nil
        activeMeasurementIdentifier = nil
        activeMeasurementDragMode = nil
        for index in measurements.indices {
            measurements[index].isActive = false
        }
        publishMeasurementOverlays()
    }

    @discardableResult
    private func deleteSelectedMeasurement() -> Bool {
        guard let identifier = selectedMeasurementIdentifier,
              let index = measurements.firstIndex(where: { $0.identifier == identifier }) else {
            return false
        }

        measurements.remove(at: index)
        selectedMeasurementIdentifier = nil
        activeMeasurementIdentifier = nil
        activeMeasurementDragMode = nil
        publishMeasurementOverlays()
        return true
    }

    private func measurementLabelRect(
        for measurement: MetalViewerMeasurement,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) -> CGRect {
        let paddedSize = measurementLabelPaddedSize(for: measurement.lengthLabel)
        let center = measurementLabelCenter(for: measurement, startPoint: startPoint, endPoint: endPoint)
        return CGRect(
            x: center.x - paddedSize.width * 0.5,
            y: center.y - paddedSize.height * 0.5,
            width: paddedSize.width,
            height: paddedSize.height
        )
    }

    private func measurementLabelCenter(
        for measurement: MetalViewerMeasurement,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) -> CGPoint {
        let paddedSize = measurementLabelPaddedSize(for: measurement.lengthLabel)
        let midpoint = CGPoint(
            x: (startPoint.x + endPoint.x) * 0.5,
            y: (startPoint.y + endPoint.y) * 0.5
        )
        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let length = max(hypot(deltaX, deltaY), 0.0001)
        let defaultCenter = clampedMeasurementLabelCenter(
            CGPoint(
                x: midpoint.x - deltaY / length * 12,
                y: midpoint.y + deltaX / length * 12
            ),
            paddedSize: paddedSize
        )
        return clampedMeasurementLabelCenter(
            CGPoint(
                x: defaultCenter.x + measurement.labelOffset.x,
                y: defaultCenter.y + measurement.labelOffset.y
            ),
            paddedSize: paddedSize
        )
    }

    private func measurementLabelPaddedSize(for label: String) -> CGSize {
        let textSize = (label as NSString).size(withAttributes: [
            .font: Self.measurementLabelFont,
        ])
        return CGSize(width: textSize.width + 8, height: textSize.height + 4)
    }

    private func clampedMeasurementLabelCenter(_ center: CGPoint, paddedSize: CGSize) -> CGPoint {
        let halfWidth = paddedSize.width * 0.5
        let halfHeight = paddedSize.height * 0.5
        let minX = bounds.minX + halfWidth + 4
        let maxX = max(minX, bounds.maxX - halfWidth - 4)
        let minY = bounds.minY + halfHeight + 4
        let maxY = max(minY, bounds.maxY - halfHeight - 4)
        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }

    private func distance(from point: CGPoint, toSegmentFrom startPoint: CGPoint, to endPoint: CGPoint) -> CGFloat {
        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - startPoint.x, point.y - startPoint.y)
        }

        let rawFraction = ((point.x - startPoint.x) * deltaX + (point.y - startPoint.y) * deltaY) / lengthSquared
        let fraction = min(max(rawFraction, 0), 1)
        let projected = CGPoint(
            x: startPoint.x + deltaX * fraction,
            y: startPoint.y + deltaY * fraction
        )
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    private func constrainedMeasurementTarget(from startPoint: CGPoint, to currentPoint: CGPoint, event: NSEvent) -> CGPoint {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift) else {
            return currentPoint
        }

        let deltaX = currentPoint.x - startPoint.x
        let deltaY = currentPoint.y - startPoint.y
        let absX = abs(deltaX)
        let absY = abs(deltaY)
        guard absX > 0.0001 || absY > 0.0001 else {
            return currentPoint
        }

        if absX < 0.0001 || absY / max(absX, 0.0001) > 1.5 {
            return CGPoint(x: startPoint.x, y: currentPoint.y)
        }
        if absY / max(absX, 0.0001) < 0.5 {
            return CGPoint(x: currentPoint.x, y: startPoint.y)
        }

        return CGPoint(
            x: currentPoint.x,
            y: startPoint.y + (deltaY < 0 ? -absX : absX)
        )
    }

    private func measurementPoint(_ point: MetalViewerMeasurementPoint, isCompatibleWith startPoint: MetalViewerMeasurementPoint) -> Bool {
        switch (startPoint.displaySpace, point.displaySpace) {
        case let (.stack2D(startSliceIndex, _), .stack2D(endSliceIndex, _)):
            return startSliceIndex == endSliceIndex
        case let (.mprPreview(startPlaneRawValue, _), .mprPreview(endPlaneRawValue, _)):
            return startPlaneRawValue == endPlaneRawValue
        default:
            return false
        }
    }

    private func publishMeasurementOverlays() {
        let overlays = measurements.compactMap { measurement -> MetalViewerMeasurementOverlay? in
            guard let startPoint = renderer.screenPoint(for: measurement.start, in: bounds),
                  let endPoint = renderer.screenPoint(for: measurement.end, in: bounds) else {
                return nil
            }
            return MetalViewerMeasurementOverlay(
                startPoint: startPoint,
                endPoint: endPoint,
                label: measurement.lengthLabel,
                labelCenter: measurementLabelCenter(for: measurement, startPoint: startPoint, endPoint: endPoint),
                isActive: measurement.isActive
            )
        }
        measurementsDidChange?(overlays)
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
        updateMPRLineCursor(at: point, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        renderer.updateMPRHover(at: nil, in: bounds)
        resetMPRLineCursor()
        NSCursor.arrow.set()
        if mouseAnnotationState != nil {
            mouseAnnotationState = nil
            annotationStateDidChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), deleteSelectedMeasurement() {
            return
        }

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
        publishMeasurementOverlays()
    }

    private func stepThroughCurrentMode(by stepCount: Int, event: NSEvent, at point: CGPoint? = nil) {
        if renderer.displayMode.isMPRLike {
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

    private func updateMPRLineCursor(at point: CGPoint, event: NSEvent) {
        guard renderer.displayMode.isMPRLike else {
            resetMPRLineCursor()
            NSCursor.arrow.set()
            return
        }
        switch mouseTool(for: .left, event: event) {
        case .rotate:
            break
        case .windowLevel, .pan, .scroll, .zoom, .measure, .tumourSeed:
            resetMPRLineCursor()
            NSCursor.arrow.set()
            return
        }

        guard let pointer = renderer.mprPreviewLinePointer(at: point, in: bounds) else {
            resetMPRLineCursor()
            NSCursor.arrow.set()
            return
        }

        mprLineCursor(for: pointer).set()
    }

    private func resetMPRLineCursor() {
        mprLineCursorCache = nil
        mprLineCursorContinuousAngle = nil
    }

    private func updateActiveMPRLineCursor() {
        guard let pointer = renderer.activeMPRPreviewLinePointer() else {
            return
        }
        mprLineCursor(for: pointer).set()
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
