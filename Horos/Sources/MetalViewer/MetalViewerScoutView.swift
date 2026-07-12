import AppKit
import CoreGraphics

private let metalViewerScoutTextColor = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
private let metalViewerScoutStudyNumberTextColor = NSColor.systemRed

private final class MetalViewerScoutDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class MetalViewerScoutClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        constrainedBounds.origin.x = 0
        return constrainedBounds
    }
}

private enum MetalViewerScoutLayout {
    static let fallbackThumbnailWidth: CGFloat = 128
    static let thumbnailAspectRatio: CGFloat = 1.0
    static let thumbnailInset: CGFloat = 4
    static let studySeparatorSpacing: CGFloat = 0
    static let studySeparatorThickness: CGFloat = 10
}

extension NSPasteboard.PasteboardType {
    static let metalViewerSeriesIdentifier = NSPasteboard.PasteboardType("org.horos.metalviewer.series-id")
    static let metalViewerDropMode = NSPasteboard.PasteboardType("org.horos.metalviewer.drop-mode")
}

final class MetalViewerScoutView: NSScrollView {
    private let stackView = NSStackView()
    private var itemViews: [MetalViewerScoutItemView] = []
    private var groupViews: [MetalViewerScoutStudyGroupView] = []
    private var separatorViews: [MetalViewerScoutStudySeparatorView] = []
    private var pendingThumbnailRefresh: DispatchWorkItem?

    var selectionHandler: ((MetalViewerSeries) -> Void)?
    var openSeriesHandler: ((MetalViewerSeries) -> Void)?
    var overlaySeriesHandler: ((MetalViewerSeries) -> Void)?

    init(series: [MetalViewerSeries]) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        contentView = MetalViewerScoutClipView()

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = MetalViewerScoutLayout.studySeparatorSpacing
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 4, bottom: 12, right: 4)

        let documentView = MetalViewerScoutDocumentView()
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

    func reload(series: [MetalViewerSeries], loadThumbnailsImmediately: Bool = true) {
        pendingThumbnailRefresh?.cancel()
        pendingThumbnailRefresh = nil

        groupViews.forEach { group in
            stackView.removeArrangedSubview(group)
            group.removeFromSuperview()
        }
        separatorViews.forEach { separator in
            stackView.removeArrangedSubview(separator)
            separator.removeFromSuperview()
        }

        itemViews = []
        groupViews = []
        separatorViews = []

        for (index, studySeries) in Self.groupedByStudy(series).enumerated() {
            if index > 0 {
                let separator = MetalViewerScoutStudySeparatorView()
                stackView.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)).isActive = true
                separator.heightAnchor.constraint(equalToConstant: MetalViewerScoutLayout.studySeparatorThickness).isActive = true
                separatorViews.append(separator)
            }

            let groupView = MetalViewerScoutStudyGroupView()
            stackView.addArrangedSubview(groupView)
            groupView.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)).isActive = true
            groupViews.append(groupView)

            for series in studySeries {
                let item = MetalViewerScoutItemView(series: series, loadThumbnailImmediately: loadThumbnailsImmediately)
                item.onSelect = { [weak self] selectedSeries in
                    self?.setSelectedSeries(identifier: selectedSeries.identifier)
                    self?.selectionHandler?(selectedSeries)
                }
                item.onOpen = { [weak self] openedSeries in
                    self?.setSelectedSeries(identifier: openedSeries.identifier)
                    self?.openSeriesHandler?(openedSeries)
                }
                item.onOverlay = { [weak self] overlaySeries in
                    self?.setSelectedSeries(identifier: overlaySeries.identifier)
                    self?.overlaySeriesHandler?(overlaySeries)
                }
                groupView.addItem(item)
                itemViews.append(item)
            }
        }

        if let first = itemViews.first {
            first.isSelected = true
        }

        if loadThumbnailsImmediately == false {
            scheduleVisibleThumbnailLoad()
        }

        DispatchQueue.main.async { [weak self] in
            self?.scrollToTop()
            self?.scheduleVisibleThumbnailLoad()
        }
    }

    func setSelectedSeries(identifier: String) {
        for item in itemViews {
            item.isSelected = (item.series.identifier == identifier)
        }
    }

    func recalibrateLayoutForCurrentWidth() {
        needsLayout = true
        contentView.needsLayout = true
        documentView?.needsLayout = true
        layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        documentView?.layoutSubtreeIfNeeded()
        tile()
        var bounds = contentView.bounds
        bounds.origin.x = 0
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        scheduleVisibleThumbnailLoad()
    }

    private func scheduleVisibleThumbnailLoad() {
        pendingThumbnailRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.loadVisibleThumbnails()
        }
        pendingThumbnailRefresh = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func loadVisibleThumbnails() {
        pendingThumbnailRefresh = nil
        guard let documentView else { return }

        guard documentView.bounds.height > 0 else {
            scheduleVisibleThumbnailLoad()
            return
        }

        let visibleRect = contentView.documentVisibleRect.insetBy(dx: 0, dy: -240)
        for item in itemViews {
            let itemFrame = item.convert(item.bounds, to: documentView)
            guard itemFrame.intersects(visibleRect) else { continue }
            item.loadThumbnailIfNeeded()
        }
    }

    private func scrollToTop(retryCount: Int = 0) {
        guard let documentView else { return }

        guard documentView.bounds.height > 0 || retryCount >= 3 else {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToTop(retryCount: retryCount + 1)
            }
            return
        }

        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private static func groupedByStudy(_ series: [MetalViewerSeries]) -> [[MetalViewerSeries]] {
        var groups: [[MetalViewerSeries]] = []
        for item in series {
            if let last = groups.last,
               last.first?.studyIdentifier == item.studyIdentifier {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }
}

private final class MetalViewerScoutStudySeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MetalViewerScoutLayout.studySeparatorThickness / 2
        layer?.backgroundColor = metalViewerScoutStudyNumberTextColor.withAlphaComponent(0.85).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class MetalViewerScoutStudyGroupView: NSView {
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = metalViewerScoutTextColor.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = NSColor.clear.cgColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addItem(_ item: MetalViewerScoutItemView) {
        stackView.addArrangedSubview(item)
        item.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)).isActive = true
    }
}

private final class MetalViewerScoutItemView: NSView {
    let series: MetalViewerSeries

    private let imageView = NSImageView()
    private let topOverlayLabel = NSTextField(labelWithString: "")
    private let timeOverlayLabel = NSTextField(labelWithString: "")
    private let titleOverlayLabel = NSTextField(labelWithString: "")
    private let countOverlayLabel = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var dragTimer: Timer?
    private var didStartDrag = false
    private var didLoadThumbnail = false
    private weak var dragPreviewView: NSImageView?

    var onSelect: ((MetalViewerSeries) -> Void)?
    var onOpen: ((MetalViewerSeries) -> Void)?
    var onOverlay: ((MetalViewerSeries) -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(series: MetalViewerSeries, loadThumbnailImmediately: Bool = true) {
        self.series = series
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = Self.placeholderThumbnail(size: Self.thumbnailSize)
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        imageView.layer?.cornerRadius = 4

        configureOverlayLabel(topOverlayLabel, alignment: .left)
        configureOverlayLabel(timeOverlayLabel, alignment: .left)
        configureOverlayLabel(titleOverlayLabel, alignment: .left)
        configureOverlayLabel(countOverlayLabel, alignment: .left)
        updateOverlayLabels(isStructuredReport: series.modality == "SR")

        addSubview(imageView)
        imageView.addSubview(topOverlayLabel)
        imageView.addSubview(timeOverlayLabel)
        imageView.addSubview(titleOverlayLabel)
        imageView.addSubview(countOverlayLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MetalViewerScoutLayout.thumbnailInset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MetalViewerScoutLayout.thumbnailInset),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: MetalViewerScoutLayout.thumbnailInset),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: MetalViewerScoutLayout.thumbnailAspectRatio),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MetalViewerScoutLayout.thumbnailInset),

            topOverlayLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 4),
            topOverlayLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -4),
            topOverlayLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 3),

            timeOverlayLabel.leadingAnchor.constraint(equalTo: topOverlayLabel.leadingAnchor),
            timeOverlayLabel.trailingAnchor.constraint(equalTo: topOverlayLabel.trailingAnchor),
            timeOverlayLabel.topAnchor.constraint(equalTo: topOverlayLabel.bottomAnchor),

            countOverlayLabel.leadingAnchor.constraint(equalTo: topOverlayLabel.leadingAnchor),
            countOverlayLabel.trailingAnchor.constraint(equalTo: topOverlayLabel.trailingAnchor),
            countOverlayLabel.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -3),

            titleOverlayLabel.leadingAnchor.constraint(equalTo: topOverlayLabel.leadingAnchor),
            titleOverlayLabel.trailingAnchor.constraint(equalTo: topOverlayLabel.trailingAnchor),
            titleOverlayLabel.bottomAnchor.constraint(equalTo: countOverlayLabel.topAnchor),
        ])

        updateAppearance()

        if loadThumbnailImmediately {
            loadThumbnailIfNeeded()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        loadThumbnailIfNeeded()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
        didStartDrag = false

        if event.clickCount >= 2 {
            cancelPendingDrag()
            onOpen?(series)
            return
        }

        cancelPendingDrag()
        guard event.modifierFlags.contains(.control) == false else {
            return
        }
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
            if event.modifierFlags.contains(.control) {
                showContextMenu(with: event)
            } else {
                onSelect?(series)
            }
        }

        super.mouseUp(with: event)
        mouseDownPoint = nil
        mouseDownEvent = nil
        didStartDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        loadThumbnailIfNeeded()
        cancelPendingDrag()
        removeDragPreview()
        showContextMenu(with: event)
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isSelected ? NSColor(calibratedRed: 0.18, green: 0.26, blue: 0.38, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)).cgColor
        layer?.borderColor = (isSelected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.24, alpha: 1)).cgColor
    }

    func loadThumbnailIfNeeded() {
        guard didLoadThumbnail == false else { return }
        didLoadThumbnail = true

        let thumbnailResult = makeThumbnail(for: series)
        if let thumbnail = thumbnailResult.image {
            imageView.image = thumbnail
        }
        updateOverlayLabels(isStructuredReport: thumbnailResult.isStructuredReport)
    }

    private func updateOverlayLabels(isStructuredReport: Bool) {
        topOverlayLabel.attributedStringValue = Self.studySeriesAttributedString(
            for: series,
            includeSeriesNumber: isStructuredReport == false,
            includeTime: isStructuredReport
        )
        timeOverlayLabel.stringValue = isStructuredReport ? "" : (series.studyDate.map { Self.studyTimeFormatter.string(from: $0) } ?? "")
        titleOverlayLabel.stringValue = isStructuredReport ? "" : series.title
        if isStructuredReport {
            countOverlayLabel.stringValue = ""
        } else if let timePointCount = series.dynamicTimePointCountHint {
            countOverlayLabel.stringValue = "\(timePointCount) time point\(timePointCount == 1 ? "" : "s")"
        } else {
            countOverlayLabel.stringValue = "\(series.imageCount) image\(series.imageCount == 1 ? "" : "s")"
        }

        timeOverlayLabel.isHidden = isStructuredReport
        titleOverlayLabel.isHidden = isStructuredReport
        countOverlayLabel.isHidden = isStructuredReport
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: NSLocalizedString("Open in New Pane", comment: ""), action: #selector(openInNewPaneMenuItem(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let overlayItem = NSMenuItem(title: NSLocalizedString("Overlay on Current Pane", comment: ""), action: #selector(overlayOnCurrentPaneMenuItem(_:)), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func openInNewPaneMenuItem(_ sender: NSMenuItem) {
        onOpen?(series)
    }

    @objc private func overlayOnCurrentPaneMenuItem(_ sender: NSMenuItem) {
        onOverlay?(series)
    }

    private func configureOverlayLabel(_ label: NSTextField, alignment: NSTextAlignment) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = metalViewerScoutTextColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
    }

    private static func studySeriesAttributedString(
        for series: MetalViewerSeries,
        includeSeriesNumber: Bool,
        includeTime: Bool
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let studyAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: metalViewerScoutStudyNumberTextColor,
        ]
        let seriesAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: metalViewerScoutTextColor,
        ]
        let text = NSMutableAttributedString(string: "\(series.studyNumber)", attributes: studyAttributes)
        let seriesNumber = series.seriesNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        if includeSeriesNumber, seriesNumber.isEmpty == false {
            text.append(NSAttributedString(string: "-\(seriesNumber)", attributes: seriesAttributes))
        }
        if let studyDate = series.studyDate {
            let dateText = Self.studyDateFormatter.string(from: studyDate)
            let metadataText = includeTime ? "\(dateText) \(Self.studyTimeFormatter.string(from: studyDate))" : dateText
            let separator = includeTime ? " " : "  "
            text.append(NSAttributedString(string: "\(separator)\(metadataText)", attributes: seriesAttributes))
        }

        return text
    }

    private static func placeholderThumbnail(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        NSColor(calibratedWhite: 0.24, alpha: 1).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        border.lineWidth = 1
        border.stroke()

        NSColor(calibratedWhite: 0.36, alpha: 1).setStroke()
        let centerY = size.height * 0.5
        let waveform = NSBezierPath()
        waveform.move(to: NSPoint(x: 32, y: centerY))
        waveform.curve(
            to: NSPoint(x: size.width - 32, y: centerY),
            controlPoint1: NSPoint(x: 70, y: centerY + 18),
            controlPoint2: NSPoint(x: size.width - 70, y: centerY - 18)
        )
        waveform.lineWidth = 2
        waveform.stroke()

        image.unlockFocus()
        return image
    }

    private static let thumbnailSize = NSSize(
        width: MetalViewerScoutLayout.fallbackThumbnailWidth,
        height: MetalViewerScoutLayout.fallbackThumbnailWidth * MetalViewerScoutLayout.thumbnailAspectRatio
    )

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

    private func makeThumbnail(for series: MetalViewerSeries) -> (image: NSImage?, isStructuredReport: Bool) {
        if series.isStructuredReport {
            return (Self.structuredReportIconThumbnail(size: Self.thumbnailSize), true)
        }

        guard let pix = series.firstPreviewPix() else { return (nil, false) }

        pix.checkLoad()
        pix.computePixMinPixMax()

        let width = max(Int(pix.pwidth), 1)
        let height = max(Int(pix.pheight), 1)
        guard let imagePointer = pix.fImage else { return (nil, false) }

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
        guard let provider = CGDataProvider(data: data as CFData) else { return (nil, false) }
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
            return (nil, false)
        }

        return (NSImage(cgImage: cgImage, size: NSSize(width: width, height: height)), false)
    }

    private static func structuredReportIconThumbnail(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let pageWidth = size.width * 0.52
        let pageHeight = size.height * 0.66
        let pageRect = NSRect(
            x: (size.width - pageWidth) * 0.5,
            y: size.height * 0.12,
            width: pageWidth,
            height: pageHeight
        )
        let pagePath = NSBezierPath(rect: pageRect)
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        pagePath.fill()

        NSColor(calibratedWhite: 0.64, alpha: 1).setStroke()
        pagePath.lineWidth = 1
        pagePath.stroke()

        let foldSize = min(pageRect.width, pageRect.height) * 0.22
        let foldPath = NSBezierPath()
        foldPath.move(to: NSPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY))
        foldPath.line(to: NSPoint(x: pageRect.maxX, y: pageRect.maxY - foldSize))
        foldPath.line(to: NSPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY - foldSize))
        foldPath.close()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        foldPath.fill()
        NSColor(calibratedWhite: 0.68, alpha: 1).setStroke()
        foldPath.lineWidth = 1
        foldPath.stroke()

        let badgeSize = min(pageRect.width, pageRect.height) * 0.24
        let badgeRect = NSRect(
            x: pageRect.midX - badgeSize * 0.5,
            y: pageRect.maxY - foldSize - badgeSize - 6,
            width: badgeSize,
            height: badgeSize
        )
        NSColor(calibratedRed: 0.03, green: 0.46, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        NSColor.white.setStroke()
        let pulsePath = NSBezierPath()
        pulsePath.lineWidth = 1.3
        pulsePath.move(to: NSPoint(x: badgeRect.minX + badgeSize * 0.20, y: badgeRect.midY))
        pulsePath.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.36, y: badgeRect.midY))
        pulsePath.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.44, y: badgeRect.midY + badgeSize * 0.20))
        pulsePath.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.58, y: badgeRect.midY - badgeSize * 0.24))
        pulsePath.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.68, y: badgeRect.midY))
        pulsePath.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.82, y: badgeRect.midY))
        pulsePath.stroke()

        let title = NSLocalizedString("Diagnostic\nImaging\nReport", comment: "")
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
        let titleRect = NSRect(
            x: pageRect.minX + 5,
            y: pageRect.minY + 12,
            width: pageRect.width - 10,
            height: max(28, badgeRect.minY - pageRect.minY - 14)
        )
        title.draw(in: titleRect, withAttributes: attributes)

        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        border.lineWidth = 1
        border.stroke()
        image.unlockFocus()
        return image
    }

    private static let studyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let studyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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
