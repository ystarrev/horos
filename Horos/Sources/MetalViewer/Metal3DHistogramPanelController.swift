import AppKit

final class Metal3DHistogramPanelController: NSWindowController {
    private let histogramView = Metal3DHistogramView(frame: .zero)

    var opacityPointsChanged: (([SIMD2<Float>]) -> Void)? {
        didSet {
            histogramView.opacityPointsChanged = opacityPointsChanged
        }
    }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = NSLocalizedString("CT Histogram", comment: "")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = false

        super.init(window: panel)

        let rootView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(histogramView)
        panel.contentView = rootView

        NSLayoutConstraint.activate([
            histogramView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            histogramView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            histogramView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            histogramView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(histogram: Metal3DHistogramModel?, opacityPoints: [SIMD2<Float>]) {
        histogramView.histogram = histogram
        histogramView.opacityPoints = opacityPoints
    }
}
