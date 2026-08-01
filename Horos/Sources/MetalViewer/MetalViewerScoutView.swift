import AppKit
import CoreGraphics

private let metalViewerScoutTextColor = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
private let metalViewerScoutStudySeparatorColor = NSColor.systemRed
private let metalViewerScoutProcedureColor = NSColor.systemOrange
let metalViewerActiveSelectionBlue = NSColor(srgbRed: 0.0, green: 0.68, blue: 1.0, alpha: 1.0)

private enum MetalViewerScoutHighlight {
    case none
    case singleSeries
    case primaryOverlaySeries
    case secondaryOverlaySeries

    var color: NSColor? {
        switch self {
        case .none: return nil
        case .singleSeries: return metalViewerActiveSelectionBlue
        case .primaryOverlaySeries: return .systemGreen
        case .secondaryOverlaySeries: return .systemRed
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .none:
            return NSColor(calibratedWhite: 0.16, alpha: 1)
        case .singleSeries:
            return NSColor(calibratedRed: 0.18, green: 0.26, blue: 0.38, alpha: 1)
        case .primaryOverlaySeries:
            return NSColor(calibratedRed: 0.10, green: 0.27, blue: 0.14, alpha: 1)
        case .secondaryOverlaySeries:
            return NSColor(calibratedRed: 0.30, green: 0.12, blue: 0.14, alpha: 1)
        }
    }
}

private final class MetalViewerScoutDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class MetalViewerScoutClipView: NSClipView {
    var scoutPlacement: MetalViewerScoutPlacement = .left

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        switch scoutPlacement {
        case .left:
            constrainedBounds.origin.x = 0
        case .bottom:
            constrainedBounds.origin.y = 0
        }
        return constrainedBounds
    }
}

private final class MetalViewerScoutSelectionTintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum MetalViewerScoutLayout {
    static let fallbackThumbnailWidth: CGFloat = 128
    static let thumbnailAspectRatio: CGFloat = 1.0
    static let thumbnailInset: CGFloat = 4
    static let horizontalProcedureWidth: CGFloat = 52
    static let studySeparatorSpacing: CGFloat = 0
    static let studySeparatorThickness: CGFloat = 10
}

private enum MetalViewerScoutTimelineEntry {
    case study([MetalViewerSeries])
    case procedure(SurgicalProcedureEvent)

    var date: Date {
        switch self {
        case .study(let series): return series.first?.studyDate ?? .distantPast
        case .procedure(let event): return event.date
        }
    }

    var sortIdentifier: String {
        switch self {
        case .study(let series): return "0-\(series.first?.studyIdentifier ?? "")"
        case .procedure(let event): return "1-\(event.identifier)"
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let metalViewerSeriesIdentifier = NSPasteboard.PasteboardType("org.horos.metalviewer.series-id")
    static let metalViewerDropMode = NSPasteboard.PasteboardType("org.horos.metalviewer.drop-mode")
}

final class MetalViewerScoutView: NSScrollView {
    private let stackView = NSStackView()
    private var scoutPlacement: MetalViewerScoutPlacement
    private var viewportConstraint: NSLayoutConstraint?
    private var currentSeries: [MetalViewerSeries]
    private var currentProcedureEvents: [SurgicalProcedureEvent]
    private var itemViews: [MetalViewerScoutItemView] = []
    private var groupViews: [MetalViewerScoutStudyGroupView] = []
    private var procedureViews: [MetalViewerScoutProcedureView] = []
    private var separatorViews: [MetalViewerScoutStudySeparatorView] = []
    private var pendingThumbnailRefresh: DispatchWorkItem?

    var selectionHandler: ((MetalViewerSeries) -> Void)?
    var openSeriesHandler: ((MetalViewerSeries) -> Void)?
    var overlaySeriesHandler: ((MetalViewerSeries) -> Void)?

    init(
        series: [MetalViewerSeries],
        procedureEvents: [SurgicalProcedureEvent] = [],
        placement: MetalViewerScoutPlacement = .defaultPlacement
    ) {
        scoutPlacement = placement
        currentSeries = series
        currentProcedureEvents = procedureEvents
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        borderType = .noBorder
        autohidesScrollers = true
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        let clipView = MetalViewerScoutClipView()
        clipView.scoutPlacement = placement
        contentView = clipView

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.spacing = MetalViewerScoutLayout.studySeparatorSpacing
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 4, bottom: 12, right: 4)
        configureScrollAxis()

        let documentView = MetalViewerScoutDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        self.documentView = documentView

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        updateViewportConstraint()

        reload(series: series, procedureEvents: procedureEvents)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(
        series: [MetalViewerSeries],
        procedureEvents: [SurgicalProcedureEvent] = [],
        loadThumbnailsImmediately: Bool = true
    ) {
        currentSeries = series
        currentProcedureEvents = procedureEvents
        pendingThumbnailRefresh?.cancel()
        pendingThumbnailRefresh = nil

        groupViews.forEach { group in
            stackView.removeArrangedSubview(group)
            group.removeFromSuperview()
        }
        procedureViews.forEach { procedure in
            stackView.removeArrangedSubview(procedure)
            procedure.removeFromSuperview()
        }
        separatorViews.forEach { separator in
            stackView.removeArrangedSubview(separator)
            separator.removeFromSuperview()
        }

        itemViews = []
        groupViews = []
        procedureViews = []
        separatorViews = []

        let timelineEntries = Self.timelineEntries(series: series, procedureEvents: procedureEvents)
        let arrangedEntries = scoutPlacement == .bottom
            ? Array(timelineEntries.reversed())
            : timelineEntries
        for (index, entry) in arrangedEntries.enumerated() {
            if index > 0 {
                let separator = MetalViewerScoutStudySeparatorView()
                stackView.addArrangedSubview(separator)
                switch scoutPlacement {
                case .left:
                    separator.widthAnchor.constraint(
                        equalTo: stackView.widthAnchor,
                        constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)
                    ).isActive = true
                    separator.heightAnchor.constraint(equalToConstant: MetalViewerScoutLayout.studySeparatorThickness).isActive = true
                case .bottom:
                    separator.heightAnchor.constraint(
                        equalTo: stackView.heightAnchor,
                        constant: -(stackView.edgeInsets.top + stackView.edgeInsets.bottom)
                    ).isActive = true
                    separator.widthAnchor.constraint(equalToConstant: MetalViewerScoutLayout.studySeparatorThickness).isActive = true
                }
                separatorViews.append(separator)
            }

            switch entry {
            case .study(let studySeries):
                let groupView = MetalViewerScoutStudyGroupView(placement: scoutPlacement)
                stackView.addArrangedSubview(groupView)
                switch scoutPlacement {
                case .left:
                    groupView.widthAnchor.constraint(
                        equalTo: stackView.widthAnchor,
                        constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)
                    ).isActive = true
                case .bottom:
                    groupView.heightAnchor.constraint(
                        equalTo: stackView.heightAnchor,
                        constant: -(stackView.edgeInsets.top + stackView.edgeInsets.bottom)
                    ).isActive = true
                }
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

            case .procedure(let event):
                let procedureView = MetalViewerScoutProcedureView(event: event, placement: scoutPlacement)
                stackView.addArrangedSubview(procedureView)
                switch scoutPlacement {
                case .left:
                    procedureView.widthAnchor.constraint(
                        equalTo: stackView.widthAnchor,
                        constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)
                    ).isActive = true
                case .bottom:
                    procedureView.heightAnchor.constraint(
                        equalTo: stackView.heightAnchor,
                        constant: -(stackView.edgeInsets.top + stackView.edgeInsets.bottom)
                    ).isActive = true
                    procedureView.widthAnchor.constraint(
                        equalToConstant: MetalViewerScoutLayout.horizontalProcedureWidth
                    ).isActive = true
                }
                procedureViews.append(procedureView)
            }
        }

        let newestSeriesIdentifier = timelineEntries.compactMap { entry -> String? in
            guard case .study(let studySeries) = entry else { return nil }
            return studySeries.first?.identifier
        }.first
        if let newestSeriesIdentifier,
           let newestItem = itemViews.first(where: { $0.series.identifier == newestSeriesIdentifier }) {
            newestItem.highlight = .singleSeries
        }

        if loadThumbnailsImmediately == false {
            scheduleVisibleThumbnailLoad()
        }

        DispatchQueue.main.async { [weak self] in
            self?.scrollToStart()
            self?.scheduleVisibleThumbnailLoad()
        }
    }

    func setPlacement(_ placement: MetalViewerScoutPlacement) {
        guard placement != scoutPlacement else { return }

        let primaryIdentifier = itemViews.first {
            $0.highlight == .singleSeries || $0.highlight == .primaryOverlaySeries
        }?.series.identifier
        let overlayIdentifier = itemViews.first {
            $0.highlight == .secondaryOverlaySeries
        }?.series.identifier

        scoutPlacement = placement
        (contentView as? MetalViewerScoutClipView)?.scoutPlacement = placement
        configureScrollAxis()
        updateViewportConstraint()
        reload(
            series: currentSeries,
            procedureEvents: currentProcedureEvents,
            loadThumbnailsImmediately: false
        )

        if let primaryIdentifier {
            setDisplayedSeries(
                primaryIdentifier: primaryIdentifier,
                overlayIdentifier: overlayIdentifier
            )
        }
        recalibrateLayoutForCurrentDimension()
    }

    func setSelectedSeries(identifier: String, scrollToVisible: Bool = false) {
        setDisplayedSeries(
            primaryIdentifier: identifier,
            overlayIdentifier: nil,
            scrollToVisible: scrollToVisible
        )
    }

    func setDisplayedSeries(
        primaryIdentifier: String,
        overlayIdentifier: String?,
        scrollToVisible: Bool = false
    ) {
        for item in itemViews {
            if let overlayIdentifier {
                if item.series.identifier == primaryIdentifier {
                    item.highlight = .primaryOverlaySeries
                } else if item.series.identifier == overlayIdentifier {
                    item.highlight = .secondaryOverlaySeries
                } else {
                    item.highlight = .none
                }
            } else {
                item.highlight = item.series.identifier == primaryIdentifier ? .singleSeries : .none
            }
        }

        if scrollToVisible {
            DispatchQueue.main.async { [weak self] in
                self?.scrollSeriesToVisible(identifier: primaryIdentifier)
            }
        }
    }

    func recalibrateLayoutForCurrentDimension() {
        needsLayout = true
        contentView.needsLayout = true
        documentView?.needsLayout = true
        layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        documentView?.layoutSubtreeIfNeeded()
        tile()
        var bounds = contentView.bounds
        switch scoutPlacement {
        case .left:
            bounds.origin.x = 0
        case .bottom:
            bounds.origin.y = 0
        }
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    private func configureScrollAxis() {
        switch scoutPlacement {
        case .left:
            hasVerticalScroller = true
            hasHorizontalScroller = false
            stackView.orientation = .vertical
            stackView.alignment = .centerX
        case .bottom:
            hasVerticalScroller = false
            hasHorizontalScroller = true
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
        }
    }

    private func updateViewportConstraint() {
        viewportConstraint?.isActive = false
        let constraint: NSLayoutConstraint
        switch scoutPlacement {
        case .left:
            constraint = stackView.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        case .bottom:
            constraint = stackView.heightAnchor.constraint(equalTo: contentView.heightAnchor)
        }
        constraint.isActive = true
        viewportConstraint = constraint
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

        let documentLength = scoutPlacement == .left
            ? documentView.bounds.height
            : documentView.bounds.width
        guard documentLength > 0 else {
            scheduleVisibleThumbnailLoad()
            return
        }

        let visibleRect: NSRect
        switch scoutPlacement {
        case .left:
            visibleRect = contentView.documentVisibleRect.insetBy(dx: 0, dy: -240)
        case .bottom:
            visibleRect = contentView.documentVisibleRect.insetBy(dx: -240, dy: 0)
        }
        for item in itemViews {
            let itemFrame = item.convert(item.bounds, to: documentView)
            guard itemFrame.intersects(visibleRect) else { continue }
            item.loadThumbnailIfNeeded()
        }
    }

    private func scrollToStart(retryCount: Int = 0) {
        guard let documentView else { return }

        let documentLength = scoutPlacement == .left ? documentView.bounds.height : documentView.bounds.width
        guard documentLength > 0 || retryCount >= 3 else {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToStart(retryCount: retryCount + 1)
            }
            return
        }

        switch scoutPlacement {
        case .left:
            contentView.scroll(to: .zero)
        case .bottom:
            var visibleBounds = contentView.bounds
            visibleBounds.origin = CGPoint(
                x: max(documentView.bounds.width - visibleBounds.width, 0),
                y: 0
            )
            contentView.scroll(to: contentView.constrainBoundsRect(visibleBounds).origin)
        }
        reflectScrolledClipView(contentView)
    }

    private func scrollSeriesToVisible(identifier: String, retryCount: Int = 0) {
        guard let documentView,
              let item = itemViews.first(where: { $0.series.identifier == identifier }) else {
            return
        }

        layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        let itemFrame = item.convert(item.bounds, to: documentView)
        let itemLength = scoutPlacement == .left ? itemFrame.height : itemFrame.width
        let visibleLength = scoutPlacement == .left ? contentView.bounds.height : contentView.bounds.width
        guard itemLength > 0, visibleLength > 0 else {
            guard retryCount < 4 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.scrollSeriesToVisible(identifier: identifier, retryCount: retryCount + 1)
            }
            return
        }

        let revealFrame: NSRect
        switch scoutPlacement {
        case .left:
            revealFrame = itemFrame.insetBy(dx: 0, dy: -8)
        case .bottom:
            revealFrame = itemFrame.insetBy(dx: -8, dy: 0)
        }
        var visibleBounds = contentView.bounds
        switch scoutPlacement {
        case .left:
            if revealFrame.minY < visibleBounds.minY {
                visibleBounds.origin.y = revealFrame.minY
            } else if revealFrame.maxY > visibleBounds.maxY {
                visibleBounds.origin.y = revealFrame.maxY - visibleBounds.height
            } else {
                item.loadThumbnailIfNeeded()
                return
            }
        case .bottom:
            if revealFrame.minX < visibleBounds.minX {
                visibleBounds.origin.x = revealFrame.minX
            } else if revealFrame.maxX > visibleBounds.maxX {
                visibleBounds.origin.x = revealFrame.maxX - visibleBounds.width
            } else {
                item.loadThumbnailIfNeeded()
                return
            }
        }

        contentView.scroll(to: contentView.constrainBoundsRect(visibleBounds).origin)
        reflectScrolledClipView(contentView)
        item.loadThumbnailIfNeeded()
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

    private static func timelineEntries(
        series: [MetalViewerSeries],
        procedureEvents: [SurgicalProcedureEvent]
    ) -> [MetalViewerScoutTimelineEntry] {
        let studies = groupedByStudy(series).map(MetalViewerScoutTimelineEntry.study)
        let procedures = procedureEvents.map(MetalViewerScoutTimelineEntry.procedure)
        return (studies + procedures).sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.sortIdentifier < $1.sortIdentifier
        }
    }
}

private final class MetalViewerScoutStudySeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MetalViewerScoutLayout.studySeparatorThickness / 2
        layer?.backgroundColor = metalViewerScoutStudySeparatorColor.withAlphaComponent(0.85).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

private final class MetalViewerScoutStudyGroupView: NSView {
    private let stackView = NSStackView()
    private let scoutPlacement: MetalViewerScoutPlacement

    init(placement: MetalViewerScoutPlacement) {
        scoutPlacement = placement
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = metalViewerScoutTextColor.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = NSColor.clear.cgColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        switch placement {
        case .left:
            stackView.orientation = .vertical
            stackView.alignment = .centerX
        case .bottom:
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
        }
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
        switch scoutPlacement {
        case .left:
            item.widthAnchor.constraint(
                equalTo: stackView.widthAnchor,
                constant: -(stackView.edgeInsets.left + stackView.edgeInsets.right)
            ).isActive = true
        case .bottom:
            item.heightAnchor.constraint(
                equalTo: stackView.heightAnchor,
                constant: -(stackView.edgeInsets.top + stackView.edgeInsets.bottom)
            ).isActive = true
        }
    }
}

private final class MetalViewerScoutVerticalProcedureTextView: NSView {
    private let text: NSAttributedString

    init(date: String, operation: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let text = NSMutableAttributedString(
            string: date,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: metalViewerScoutProcedureColor,
                .paragraphStyle: paragraph,
            ]
        )
        text.append(NSAttributedString(
            string: "\n\(operation)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: .pi / 2)
        let textRect = CGRect(
            x: -bounds.height * 0.5 + 2,
            y: -bounds.width * 0.5 + 2,
            width: max(bounds.height - 4, 0),
            height: max(bounds.width - 4, 0)
        )
        text.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        context.restoreGState()
    }
}

private final class MetalViewerScoutProcedureView: NSView {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(event: SurgicalProcedureEvent, placement: MetalViewerScoutPlacement) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        layer?.borderColor = metalViewerScoutProcedureColor.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = metalViewerScoutProcedureColor.withAlphaComponent(0.10).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = metalViewerScoutProcedureColor
        iconView.image = NSImage(
            systemSymbolName: "cross.case.fill",
            accessibilityDescription: NSLocalizedString("Surgical Procedure", comment: "")
        )

        let dateLabel = Self.label(
            Self.dateFormatter.string(from: event.date),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: metalViewerScoutProcedureColor
        )
        let operationLabel = Self.label(
            event.operation.isEmpty ? NSLocalizedString("Surgical Procedure", comment: "") : event.operation,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        operationLabel.maximumNumberOfLines = placement == .left ? 3 : 1

        let diagnosisLabel = Self.label(
            event.diagnosis,
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        diagnosisLabel.maximumNumberOfLines = placement == .left ? 2 : 1
        diagnosisLabel.isHidden = event.diagnosis.isEmpty

        let heading = NSStackView(views: [iconView, dateLabel])
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6

        let content: NSView
        switch placement {
        case .left:
            let stack = NSStackView(views: [heading, operationLabel, diagnosisLabel])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .width
            stack.spacing = 3
            content = stack
        case .bottom:
            content = MetalViewerScoutVerticalProcedureTextView(
                date: Self.dateFormatter.string(from: event.date),
                operation: event.operation.isEmpty
                    ? NSLocalizedString("Surgical Procedure", comment: "")
                    : event.operation
            )
        }
        addSubview(content)

        switch placement {
        case .left:
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),
                dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 74),
            ])
        case .bottom:
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        }

        toolTip = Self.procedureToolTip(for: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func label(_ value: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func procedureToolTip(for event: SurgicalProcedureEvent) -> String {
        [
            ("Date", dateFormatter.string(from: event.date)),
            ("Name", event.name),
            ("ID", event.patientID),
            ("Operation", event.operation),
            ("Diagnosis", event.diagnosis),
            ("Results", event.results),
            ("Optics", event.optics),
            ("Assistants", event.assistants),
        ]
        .filter { $0.1.isEmpty == false }
        .map { "\($0.0): \($0.1)" }
        .joined(separator: "\n")
    }
}

private final class MetalViewerScoutItemView: NSView {
    let series: MetalViewerSeries

    private let imageView = NSImageView()
    private let topOverlayLabel = NSTextField(labelWithString: "")
    private let timeOverlayLabel = NSTextField(labelWithString: "")
    private let titleOverlayLabel = NSTextField(labelWithString: "")
    private let countOverlayLabel = NSTextField(labelWithString: "")
    private let selectionTintView = MetalViewerScoutSelectionTintView()
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var dragTimer: Timer?
    private var didStartDrag = false
    private var didLoadThumbnail = false
    private weak var dragPreviewView: NSImageView?

    var onSelect: ((MetalViewerSeries) -> Void)?
    var onOpen: ((MetalViewerSeries) -> Void)?
    var onOverlay: ((MetalViewerSeries) -> Void)?

    var highlight: MetalViewerScoutHighlight = .none {
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
        topOverlayLabel.lineBreakMode = .byClipping
        timeOverlayLabel.lineBreakMode = .byClipping
        updateOverlayLabels(isStructuredReport: series.modality == "SR")

        addSubview(imageView)
        imageView.addSubview(topOverlayLabel)
        imageView.addSubview(timeOverlayLabel)
        imageView.addSubview(titleOverlayLabel)
        imageView.addSubview(countOverlayLabel)

        selectionTintView.translatesAutoresizingMaskIntoConstraints = false
        selectionTintView.wantsLayer = true
        selectionTintView.layer?.backgroundColor = metalViewerActiveSelectionBlue.withAlphaComponent(0.20).cgColor
        selectionTintView.layer?.cornerRadius = 8
        addSubview(selectionTintView, positioned: .above, relativeTo: imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MetalViewerScoutLayout.thumbnailInset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MetalViewerScoutLayout.thumbnailInset),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: MetalViewerScoutLayout.thumbnailInset),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: MetalViewerScoutLayout.thumbnailAspectRatio),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MetalViewerScoutLayout.thumbnailInset),

            selectionTintView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            selectionTintView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            selectionTintView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectionTintView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

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

    override func layout() {
        super.layout()
        updateDateTimeFontForCurrentWidth()
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
        let highlightColor = highlight.color
        selectionTintView.isHidden = highlightColor == nil
        selectionTintView.layer?.backgroundColor = highlightColor?.withAlphaComponent(0.20).cgColor
        layer?.backgroundColor = highlight.backgroundColor.cgColor
        layer?.borderWidth = highlightColor == nil ? 2 : 3
        layer?.borderColor = (highlightColor ?? NSColor(calibratedWhite: 0.24, alpha: 1)).cgColor
        layer?.shadowColor = highlightColor?.cgColor
        layer?.shadowOpacity = highlightColor == nil ? 0 : 0.95
        layer?.shadowRadius = highlightColor == nil ? 0 : 5
        layer?.shadowOffset = .zero
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
        topOverlayLabel.stringValue = series.studyDate.map { Self.studyDateFormatter.string(from: $0) } ?? ""
        timeOverlayLabel.stringValue = series.studyDate.map { Self.studyTimeFormatter.string(from: $0) } ?? ""
        titleOverlayLabel.stringValue = isStructuredReport ? "" : series.title
        if isStructuredReport {
            countOverlayLabel.stringValue = ""
        } else if let timePointCount = series.dynamicTimePointCountHint {
            countOverlayLabel.stringValue = "\(timePointCount) time point\(timePointCount == 1 ? "" : "s")"
        } else {
            countOverlayLabel.stringValue = "\(series.imageCount) image\(series.imageCount == 1 ? "" : "s")"
        }

        timeOverlayLabel.isHidden = timeOverlayLabel.stringValue.isEmpty
        titleOverlayLabel.isHidden = isStructuredReport
        countOverlayLabel.isHidden = isStructuredReport
        needsLayout = true
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

    private func updateDateTimeFontForCurrentWidth() {
        guard topOverlayLabel.stringValue.isEmpty == false else { return }

        let labelWidth = topOverlayLabel.bounds.width > 0
            ? topOverlayLabel.bounds.width
            : max(0, imageView.bounds.width - 8)
        let availableWidth = max(0, labelWidth - 8)
        guard availableWidth > 0 else { return }

        let font = Self.fontFitting(text: topOverlayLabel.stringValue, width: availableWidth)
        guard abs((topOverlayLabel.font?.pointSize ?? 0) - font.pointSize) > 0.25 else { return }
        topOverlayLabel.font = font
        timeOverlayLabel.font = font
    }

    private static func fontFitting(text: String, width: CGFloat) -> NSFont {
        let minimumSize: CGFloat = 11
        var lowerBound = minimumSize
        var upperBound = max(minimumSize, width)

        for _ in 0..<10 {
            let candidateSize = (lowerBound + upperBound) * 0.5
            let candidateFont = NSFont.systemFont(ofSize: candidateSize, weight: .regular)
            let measuredWidth = (text as NSString).size(withAttributes: [.font: candidateFont]).width
            if measuredWidth <= width {
                lowerBound = candidateSize
            } else {
                upperBound = candidateSize
            }
        }

        return NSFont.systemFont(ofSize: floor(lowerBound), weight: .regular)
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

        guard let pix = series.middlePreviewPix(),
              let storedPixels = MetalStoredInt16PixelData(pix: pix) else {
            return (nil, false)
        }

        let width = storedPixels.width
        let height = storedPixels.height
        let defaultWindow = storedPixels.inferredWindow
        let displayWindow = series.isMagneticResonance
            ? (MetalViewerAutomaticWindowLevel.window(
                for: storedPixels,
                modality: pix.modalityString
            ) ?? defaultWindow)
            : defaultWindow
        let windowWidth = displayWindow.width
        let windowLevel = displayWindow.level
        let low = windowLevel - windowWidth * 0.5
        let high = windowLevel + windowWidth * 0.5
        let count = width * height

        var grayscale = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            guard let sample = storedPixels.rescaledValue(at: index) else { continue }
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
