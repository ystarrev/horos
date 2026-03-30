import AppKit

final class MetalViewerWindowController: NSWindowController, NSSplitViewDelegate {
    private enum Layout {
        static let initialScoutWidth: CGFloat = 220
        static let minimumScoutWidth: CGFloat = 172
        static let minimumPaneWidth: CGFloat = 480
        static let maximumPaneCount = 8
    }

    private let study: MetalViewerStudy
    private let toolbarView = MetalViewerToolbarView(frame: .zero)
    private let scoutView: MetalViewerScoutView
    private let contentSplitView = NSSplitView(frame: .zero)
    private let scoutContainer = NSView()
    private let paneContainer = NSView()
    private let paneStackView = NSStackView()
    private let scoutWidthConstraint: NSLayoutConstraint
    private let scoutMinimumWidthConstraint: NSLayoutConstraint

    private var paneViews: [MetalViewerPaneView] = []
    private weak var activePaneView: MetalViewerPaneView?

    init(study: MetalViewerStudy) {
        self.study = study

        let firstSeries = study.series.first { $0.identifier == study.initialSeriesIdentifier } ?? study.series[0]
        let firstPix = firstSeries.firstPreviewPix() ?? firstSeries.loadedPixList()[0]
        let imageWidth = max(CGFloat(firstPix.pwidth), 512)
        let imageHeight = max(CGFloat(firstPix.pheight), 512)
        let aspectRatio = imageWidth / max(imageHeight, 1)

        let contentWidth = min(max(imageWidth, 900), 1600)
        let contentHeight = min(max(contentWidth / aspectRatio, 700), 1200)
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.scoutView = MetalViewerScoutView(series: study.series)
        self.scoutWidthConstraint = scoutContainer.widthAnchor.constraint(equalToConstant: Layout.initialScoutWidth)
        self.scoutMinimumWidthConstraint = scoutContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumScoutWidth)

        window.title = study.title
        window.minSize = NSSize(width: 980, height: 640)
        window.center()

        let rootView = NSView(frame: contentRect)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor

        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.isVertical = true
        contentSplitView.dividerStyle = .thin
        contentSplitView.autosaveName = "HorosMetalViewerSplitView"
        contentSplitView.wantsLayer = true
        contentSplitView.layer?.backgroundColor = NSColor.black.cgColor

        scoutContainer.translatesAutoresizingMaskIntoConstraints = false
        scoutContainer.wantsLayer = true
        scoutContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        scoutContainer.addSubview(scoutView)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.wantsLayer = true
        paneContainer.layer?.backgroundColor = NSColor.black.cgColor

        paneStackView.translatesAutoresizingMaskIntoConstraints = false
        paneStackView.orientation = .vertical
        paneStackView.distribution = .fillEqually
        paneStackView.alignment = .leading
        paneStackView.spacing = 8
        paneContainer.addSubview(paneStackView)

        contentSplitView.addArrangedSubview(scoutContainer)
        contentSplitView.addArrangedSubview(paneContainer)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        scoutWidthConstraint.priority = .defaultLow

        rootView.addSubview(toolbarView)
        rootView.addSubview(contentSplitView)
        window.contentView = rootView

        super.init(window: window)

        contentSplitView.delegate = self

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: rootView.topAnchor),

            contentSplitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentSplitView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            contentSplitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            scoutView.leadingAnchor.constraint(equalTo: scoutContainer.leadingAnchor),
            scoutView.trailingAnchor.constraint(equalTo: scoutContainer.trailingAnchor),
            scoutView.topAnchor.constraint(equalTo: scoutContainer.topAnchor),
            scoutView.bottomAnchor.constraint(equalTo: scoutContainer.bottomAnchor),

            paneStackView.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor, constant: 8),
            paneStackView.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor, constant: -8),
            paneStackView.topAnchor.constraint(equalTo: paneContainer.topAnchor, constant: 8),
            paneStackView.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor, constant: -8),

            scoutWidthConstraint,
            scoutMinimumWidthConstraint,
        ])

        addPane(for: firstSeries, makeActive: true)
        scoutView.setSelectedSeries(identifier: firstSeries.identifier)

        scoutView.selectionHandler = { [weak self] series in
            guard let self else { return }
            self.scoutView.setSelectedSeries(identifier: series.identifier)
        }

        scoutView.openSeriesHandler = { [weak self] series in
            self?.addPane(for: series, makeActive: true)
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyInitialSplitPositionIfNeeded()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyInitialSplitPositionIfNeeded() {
        guard contentSplitView.arrangedSubviews.count >= 2 else { return }
        let currentScoutWidth = scoutContainer.frame.width
        if currentScoutWidth < Layout.minimumScoutWidth || currentScoutWidth > 420 {
            contentSplitView.setPosition(Layout.initialScoutWidth, ofDividerAt: 0)
        }
        scoutWidthConstraint.constant = scoutContainer.frame.width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMinimumPosition }
        return Layout.minimumScoutWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMaximumPosition }
        return max(Layout.minimumScoutWidth, splitView.bounds.width - splitView.dividerThickness - Layout.minimumPaneWidth)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as AnyObject? === contentSplitView else { return }
        scoutWidthConstraint.constant = scoutContainer.frame.width
    }

    private func addPane(for series: MetalViewerSeries, makeActive: Bool) {
        guard paneViews.count < Layout.maximumPaneCount else {
            NSSound.beep()
            return
        }

        let pane = MetalViewerPaneView(series: series)
        pane.activateHandler = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.setActivePane(pane)
        }
        pane.seriesDropHandler = { [weak self, weak pane] identifier, isOverlay in
            guard let self, let pane else { return }
            self.assignSeries(withIdentifier: identifier, to: pane, overlay: isOverlay)
        }
        pane.closeHandler = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.removePane(pane)
        }
        pane.stateDidChange = { [weak self, weak pane] _ in
            guard let self, let pane else { return }
            if self.activePaneView === pane {
                self.updateToolbarStatus()
            }
            self.updateReferenceLines()
        }

        paneViews.append(pane)
        rebuildPaneLayout()

        if makeActive {
            setActivePane(pane)
        }

        updateReferenceLines()
    }

    private func setActivePane(_ pane: MetalViewerPaneView) {
        activePaneView = pane
        for candidate in paneViews {
            candidate.isActive = (candidate === pane)
        }
        pane.focusImageView()
        updateToolbarStatus()
        updateReferenceLines()
    }

    private func rebuildPaneLayout() {
        paneStackView.arrangedSubviews.forEach { row in
            paneStackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        for pane in paneViews {
            pane.canClose = paneViews.count > 1
        }

        let columnCount = preferredColumnCount(for: paneViews.count)
        for startIndex in stride(from: 0, to: paneViews.count, by: columnCount) {
            let endIndex = min(startIndex + columnCount, paneViews.count)
            let rowStack = NSStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.orientation = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.alignment = .centerY
            rowStack.spacing = 8

            for pane in paneViews[startIndex..<endIndex] {
                rowStack.addArrangedSubview(pane)
            }

            paneStackView.addArrangedSubview(rowStack)
        }
    }

    private func removePane(_ pane: MetalViewerPaneView) {
        guard paneViews.count > 1 else {
            NSSound.beep()
            return
        }

        let wasActive = (activePaneView === pane)
        paneViews.removeAll { $0 === pane }
        rebuildPaneLayout()

        if wasActive {
            if let replacement = paneViews.first {
                setActivePane(replacement)
            } else {
                activePaneView = nil
                updateToolbarStatus()
            }
        } else {
            updateToolbarStatus()
        }

        updateReferenceLines()
    }

    private func preferredColumnCount(for paneCount: Int) -> Int {
        switch paneCount {
        case 0...1: return 1
        case 2...4: return 2
        default: return 3
        }
    }

    private func assignSeries(withIdentifier identifier: String, to pane: MetalViewerPaneView, overlay: Bool) {
        guard let series = study.series.first(where: { $0.identifier == identifier }) else {
            NSSound.beep()
            return
        }

        if overlay {
            pane.overlay(series: series)
        } else {
            pane.display(series: series)
        }
        scoutView.setSelectedSeries(identifier: series.identifier)

        if activePaneView === pane {
            updateToolbarStatus()
        }
        updateReferenceLines()
    }

    private func updateToolbarStatus() {
        guard let activePaneView else {
            toolbarView.updateStatus("No active pane")
            return
        }

        toolbarView.updateStatus("\(activePaneView.series.title)  •  \(activePaneView.currentStateDescription)")
    }

    private func updateReferenceLines() {
        guard let activePaneView,
              let activeGeometry = activePaneView.currentSliceGeometry() else {
            paneViews.forEach { $0.setReferenceLine(nil) }
            return
        }

        for pane in paneViews {
            guard pane !== activePaneView,
                  pane.series.studyIdentifier == activePaneView.series.studyIdentifier,
                  let targetGeometry = pane.currentSliceGeometry() else {
                pane.setReferenceLine(nil)
                continue
            }

            let line = MetalViewerReferenceLineCalculator.line(active: activeGeometry, target: targetGeometry)
            pane.setReferenceLine(line)
        }

        activePaneView.setReferenceLine(nil)
    }
}
