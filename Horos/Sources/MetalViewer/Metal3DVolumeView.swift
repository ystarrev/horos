import AppKit
import MetalKit

final class Metal3DVolumeView: NSView {
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

    private let metalView: MTKView
    private let cropOverlayView = CropOverlayView(frame: .zero)
    private var renderer: Metal3DVolumeRenderer?
    private var lastDragLocation: NSPoint?
    private var activeCropPlane: Metal3DCropPlane?
    private var cropHandleProjections = [Metal3DCropPlane: Metal3DCropHandleProjection]()
    private var cropHandleViews = [Metal3DCropPlane: CropHandleView]()
    var wlwwInteractionHandler: ((String) -> Void)?

    private var cropApplied = false

    var cropEnabled = false {
        didSet {
            if cropEnabled {
                cropApplied = true
                renderer?.setCropEnabled(true)
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

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cropOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cropOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cropOverlayView.topAnchor.constraint(equalTo: topAnchor),
            cropOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for plane in Metal3DCropPlane.allCases {
            let handleView = CropHandleView(plane: plane)
            handleView.isHidden = true
            cropOverlayView.addSubview(handleView)
            cropHandleViews[plane] = handleView
        }

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()
        refreshCropHandles()
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        renderer?.zoom(delta: Float(event.scrollingDeltaY))
        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if cropEnabled, let hitPlane = cropPlane(at: location) {
            activeCropPlane = hitPlane
            lastDragLocation = location
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
            renderer?.adjustWindowLevelWidth(deltaX: deltaX, deltaY: deltaY)
            if let selectedWLPresetName {
                wlwwInteractionHandler?(selectedWLPresetName)
            }
        } else {
            renderer?.rotateTrackball(from: lastDragLocation, to: location, in: bounds)
        }

        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
        self.lastDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        activeCropPlane = nil
        lastDragLocation = nil
    }

    func configure(pixList: [DCMPix], volumeData: Data) {
        guard let device = metalView.device else { return }
        let renderer = Metal3DVolumeRenderer(device: device, pixList: pixList, volumeData: volumeData)
        renderer.setCropEnabled(cropApplied || cropEnabled)
        renderer.setCropOverlayVisible(cropEnabled)
        renderer.setShadingEnabled(shadingEnabled)
        self.renderer = renderer
        metalView.delegate = renderer
        metalView.setNeedsDisplay(metalView.bounds)
        refreshCropHandles()
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
            if handleView.frame.insetBy(dx: -6, dy: -6).contains(location) {
                return plane
            }
        }
        return nil
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
}
