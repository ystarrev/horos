import AppKit
import MetalKit

final class Metal3DVolumeView: NSView {
    private let metalView: MTKView
    private var renderer: Metal3DVolumeRenderer?
    private var lastDragLocation: NSPoint?
    var wlwwInteractionHandler: ((String) -> Void)?
    private lazy var panGestureRecognizer: NSPanGestureRecognizer = {
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        recognizer.buttonMask = 0x1
        return recognizer
    }()

    var cropEnabled = false {
        didSet {
            renderer?.setCropEnabled(cropEnabled)
            updateAppearance()
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
        metalView.addGestureRecognizer(panGestureRecognizer)
        addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    @objc
    private func handlePanGesture(_ recognizer: NSPanGestureRecognizer) {
        let location = recognizer.location(in: metalView)

        switch recognizer.state {
        case .began:
            window?.makeFirstResponder(self)
            lastDragLocation = location

        case .changed:
            guard let lastDragLocation else {
                self.lastDragLocation = location
                return
            }

            let deltaX = Float(location.x - lastDragLocation.x)
            let deltaY = Float(location.y - lastDragLocation.y)
            let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
            if modifierFlags.contains(.control) {
                renderer?.adjustWindowLevelWidth(deltaX: deltaX, deltaY: deltaY)
                if let selectedWLPresetName {
                    wlwwInteractionHandler?(selectedWLPresetName)
                }
            } else {
                renderer?.rotate(deltaX: deltaX, deltaY: deltaY)
            }
            metalView.setNeedsDisplay(metalView.bounds)
            self.lastDragLocation = location

        default:
            lastDragLocation = nil
        }
    }

    func configure(pixList: [DCMPix], volumeData: Data) {
        guard let device = metalView.device else { return }
        let renderer = Metal3DVolumeRenderer(device: device, pixList: pixList, volumeData: volumeData)
        renderer.setCropEnabled(cropEnabled)
        self.renderer = renderer
        metalView.delegate = renderer
        metalView.setNeedsDisplay(metalView.bounds)
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

    private func updateAppearance() {
        if cropEnabled {
            metalView.clearColor = MTLClearColor(red: 0.02, green: 0.015, blue: 0.015, alpha: 1.0)
        } else {
            metalView.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.015, alpha: 1.0)
        }
        metalView.setNeedsDisplay(metalView.bounds)
    }
}
