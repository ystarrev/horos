import AppKit
import CoreGraphics

private let metalViewerStudyBadgeColor = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.72, alpha: 1.0)

extension NSPasteboard.PasteboardType {
    static let metalViewerSeriesIdentifier = NSPasteboard.PasteboardType("org.horos.metalviewer.series-id")
    static let metalViewerDropMode = NSPasteboard.PasteboardType("org.horos.metalviewer.drop-mode")
}

final class MetalViewerScoutView: NSScrollView {
    private let stackView = NSStackView()
    private var itemViews: [MetalViewerScoutItemView] = []

    var selectionHandler: ((MetalViewerSeries) -> Void)?
    var openSeriesHandler: ((MetalViewerSeries) -> Void)?

    init(series: [MetalViewerSeries]) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        self.documentView = documentView

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])

        reload(series: series)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(series: [MetalViewerSeries]) {
        itemViews.forEach { item in
            stackView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }

        itemViews = series.map { series in
            let item = MetalViewerScoutItemView(series: series)
            item.onSelect = { [weak self] selectedSeries in
                self?.setSelectedSeries(identifier: selectedSeries.identifier)
                self?.selectionHandler?(selectedSeries)
            }
            item.onOpen = { [weak self] openedSeries in
                self?.setSelectedSeries(identifier: openedSeries.identifier)
                self?.openSeriesHandler?(openedSeries)
            }
            stackView.addArrangedSubview(item)
            return item
        }

        if let first = itemViews.first {
            first.isSelected = true
        }
    }

    func setSelectedSeries(identifier: String) {
        for item in itemViews {
            item.isSelected = (item.series.identifier == identifier)
        }
    }
}

private final class MetalViewerScoutItemView: NSView {
    let series: MetalViewerSeries

    private let studyHeaderView = NSView()
    private let studyBadgeField = NSTextField(labelWithString: "")
    private let studyDateLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var dragTimer: Timer?
    private var didStartDrag = false
    private weak var dragPreviewView: NSImageView?

    var onSelect: ((MetalViewerSeries) -> Void)?
    var onOpen: ((MetalViewerSeries) -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(series: MetalViewerSeries) {
        self.series = series
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        studyHeaderView.translatesAutoresizingMaskIntoConstraints = false

        studyBadgeField.translatesAutoresizingMaskIntoConstraints = false
        studyBadgeField.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        studyBadgeField.textColor = .white
        studyBadgeField.alignment = .center
        studyBadgeField.wantsLayer = true
        studyBadgeField.layer?.backgroundColor = metalViewerStudyBadgeColor.cgColor
        studyBadgeField.layer?.cornerRadius = 10
        studyBadgeField.stringValue = "\(series.studyNumber)"

        studyDateLabel.translatesAutoresizingMaskIntoConstraints = false
        studyDateLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        studyDateLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        studyDateLabel.lineBreakMode = .byTruncatingTail
        studyDateLabel.stringValue = series.studyDate.map { Self.studyDateFormatter.string(from: $0) } ?? ""

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = makeThumbnail(for: series)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = series.title

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        metaLabel.stringValue = "\(series.imageCount) image\(series.imageCount == 1 ? "" : "s")"

        addSubview(studyHeaderView)
        studyHeaderView.addSubview(studyBadgeField)
        studyHeaderView.addSubview(studyDateLabel)
        addSubview(imageView)
        addSubview(titleLabel)
        addSubview(metaLabel)

        let preferredWidthConstraint = widthAnchor.constraint(equalToConstant: 196)
        preferredWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            preferredWidthConstraint,
            widthAnchor.constraint(lessThanOrEqualToConstant: 196),

            studyHeaderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            studyHeaderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            studyHeaderView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            studyHeaderView.heightAnchor.constraint(equalToConstant: 20),

            studyBadgeField.leadingAnchor.constraint(equalTo: studyHeaderView.leadingAnchor),
            studyBadgeField.centerYAnchor.constraint(equalTo: studyHeaderView.centerYAnchor),
            studyBadgeField.widthAnchor.constraint(equalToConstant: 20),
            studyBadgeField.heightAnchor.constraint(equalToConstant: 20),

            studyDateLabel.leadingAnchor.constraint(equalTo: studyBadgeField.trailingAnchor, constant: 8),
            studyDateLabel.trailingAnchor.constraint(equalTo: studyHeaderView.trailingAnchor),
            studyDateLabel.centerYAnchor.constraint(equalTo: studyHeaderView.centerYAnchor),

            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            imageView.topAnchor.constraint(equalTo: studyHeaderView.bottomAnchor, constant: 8),
            imageView.heightAnchor.constraint(equalToConstant: 120),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
        didStartDrag = false

        if event.clickCount >= 2 {
            cancelPendingDrag()
            onOpen?(series)
            return
        }

        cancelPendingDrag()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.beginLongPressDrag()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.clickCount < 2, didStartDrag == false else {
            return
        }

        updateDragPreviewPosition(with: event)

        let currentPoint = convert(event.locationInWindow, from: nil)
        let startPoint = mouseDownPoint ?? currentPoint
        guard hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) > 4 else {
            return
        }

        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        cancelPendingDrag()
        removeDragPreview()

        if event.clickCount < 2, didStartDrag == false {
            onSelect?(series)
        }

        super.mouseUp(with: event)
        mouseDownPoint = nil
        mouseDownEvent = nil
        didStartDrag = false
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isSelected ? NSColor(calibratedRed: 0.18, green: 0.26, blue: 0.38, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)).cgColor
        layer?.borderColor = (isSelected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.24, alpha: 1)).cgColor
    }

    private func bitmapImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        return image
    }

    private func beginLongPressDrag() {
        guard didStartDrag == false, let mouseDownEvent else {
            return
        }

        showDragPreview(using: mouseDownEvent)
    }

    private func beginDrag(with event: NSEvent) {
        cancelPendingDrag()
        didStartDrag = true
        onSelect?(series)
        removeDragPreview()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(series.identifier, forType: .metalViewerSeriesIdentifier)
        let dropMode = event.modifierFlags.contains(.control) ? "overlay" : "replace"
        pasteboardItem.setString(dropMode, forType: .metalViewerDropMode)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragFrame = bounds
        let dragImage = bitmapImage()
        draggingItem.setDraggingFrame(dragFrame, contents: dragImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none

        mouseDownPoint = nil
        mouseDownEvent = nil
    }

    private func cancelPendingDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func showDragPreview(using event: NSEvent) {
        guard dragPreviewView == nil,
              let contentView = window?.contentView else {
            return
        }

        let preview = NSImageView(image: bitmapImage())
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        preview.layer?.shadowColor = NSColor.black.cgColor
        preview.layer?.shadowOpacity = 0.35
        preview.layer?.shadowRadius = 10
        preview.layer?.shadowOffset = CGSize(width: 0, height: -2)
        preview.alphaValue = 0

        let frameInWindow = convert(bounds, to: nil)
        let frameInContent = contentView.convert(frameInWindow, from: nil)
        preview.frame = frameInContent
        contentView.addSubview(preview)
        dragPreviewView = preview

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            preview.animator().alphaValue = 0.92
            preview.animator().frame = frameInContent.insetBy(dx: -3, dy: -3)
        }

        updateDragPreviewPosition(with: event)
    }

    private func updateDragPreviewPosition(with event: NSEvent) {
        guard let preview = dragPreviewView,
              let contentView = window?.contentView else {
            return
        }

        let locationInWindow = event.locationInWindow
        let locationInContent = contentView.convert(locationInWindow, from: nil)
        let size = preview.frame.size
        preview.frame.origin = CGPoint(
            x: locationInContent.x - size.width * 0.5,
            y: locationInContent.y - size.height * 0.5
        )
    }

    private func removeDragPreview() {
        guard let preview = dragPreviewView else {
            return
        }

        dragPreviewView = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            preview.animator().alphaValue = 0
        }, completionHandler: {
            preview.removeFromSuperview()
        })
    }

    private func makeThumbnail(for series: MetalViewerSeries) -> NSImage? {
        guard let pix = series.firstPreviewPix() else { return nil }

        pix.checkLoad()
        pix.computePixMinPixMax()

        let width = max(Int(pix.pwidth), 1)
        let height = max(Int(pix.pheight), 1)
        guard let imagePointer = pix.fImage else { return nil }

        let windowWidth = max(Float(pix.ww > 0 ? pix.ww : pix.fullww), 1)
        let windowLevel = Float(pix.wl != 0 ? pix.wl : pix.fullwl)
        let low = windowLevel - windowWidth * 0.5
        let high = windowLevel + windowWidth * 0.5
        let count = width * height

        var grayscale = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let sample = imagePointer[index]
            let normalized = max(0, min(1, (sample - low) / max(high - low, 1)))
            grayscale[index] = UInt8((normalized * 255).rounded())
        }

        let data = Data(grayscale)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static let studyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

extension MetalViewerScoutItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didStartDrag = false
        removeDragPreview()
    }
}
