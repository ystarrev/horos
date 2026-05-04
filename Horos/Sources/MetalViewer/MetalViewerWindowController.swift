import AppKit

private func metalWindowTimingLog(_ message: String, since start: CFAbsoluteTime) {
    print(String(format: "HOROS_METAL_TIMING %@ %.3f s", message, CFAbsoluteTimeGetCurrent() - start))
}

private final class MetalViewerSplitView: NSSplitView {
    var dividerDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        dividerDragEnded?()
    }
}

final class MetalViewerWindowController: NSWindowController, NSSplitViewDelegate {
    private enum Layout {
        static let minimumScoutWidth: CGFloat = 172
        static let minimumPaneWidth: CGFloat = 480
        static let maximumPaneCount = 8
        static let scoutWidthAutosaveKey = "HorosMetalViewerScoutWidth"
    }

    private var study: MetalViewerStudy
    private let toolbarView = MetalViewerToolbarView(frame: .zero)
    private let scoutView: MetalViewerScoutView
    private let contentSplitView = MetalViewerSplitView(frame: .zero)
    private let scoutContainer = NSView()
    private let paneContainer = NSView()
    private let paneStackView = NSStackView()
    private let scoutWidthConstraint: NSLayoutConstraint
    private let scoutMinimumWidthConstraint: NSLayoutConstraint

    private var paneViews: [MetalViewerPaneView] = []
    private weak var activePaneView: MetalViewerPaneView?
    private let seriesPreloader = MetalViewerSeriesPreloader()
    private var isRestoringSplitPosition = true
    private var selectedWLWWTitle = NSLocalizedString("Default WL & WW", comment: "")
    private var viewerMode: MetalViewerToolbarView.ViewerMode = .stack2D

    init(study: MetalViewerStudy) {
        let initStart = CFAbsoluteTimeGetCurrent()
        self.study = study

        let firstSeriesStart = CFAbsoluteTimeGetCurrent()
        let firstSeries = study.series.first { $0.identifier == study.initialSeriesIdentifier } ?? study.series[0]
        let firstPix = firstSeries.firstPreviewPix() ?? firstSeries.loadedPixList()[0]
        let imageWidth = max(CGFloat(firstPix.pwidth), 512)
        let imageHeight = max(CGFloat(firstPix.pheight), 512)
        let aspectRatio = imageWidth / max(imageHeight, 1)
        metalWindowTimingLog("MetalViewerWindowController first series/pix sizing", since: firstSeriesStart)

        let contentWidth = min(max(imageWidth, 900), 1600)
        let contentHeight = min(max(contentWidth / aspectRatio, 700), 1200)
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let scoutStart = CFAbsoluteTimeGetCurrent()
        self.scoutView = MetalViewerScoutView(series: study.series)
        metalWindowTimingLog("MetalViewerWindowController scout init", since: scoutStart)
        self.scoutWidthConstraint = scoutContainer.widthAnchor.constraint(equalToConstant: Self.savedScoutWidth(forSplitWidth: contentRect.width))
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
        contentSplitView.dividerDragEnded = { [weak self] in
            self?.saveSplitPosition()
        }
        toolbarView.wlwwSelectionHandler = { [weak self] command in
            self?.applyWLWWCommand(command)
        }
        toolbarView.viewerModeSelectionHandler = { [weak self] mode in
            self?.applyViewerMode(mode)
        }

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

        let firstPaneStart = CFAbsoluteTimeGetCurrent()
        addPane(for: firstSeries, makeActive: true, preload: false)
        metalWindowTimingLog("MetalViewerWindowController first pane init", since: firstPaneStart)
        scoutView.setSelectedSeries(identifier: firstSeries.identifier)

        scoutView.selectionHandler = { [weak self] series in
            guard let self else { return }
            self.scoutView.setSelectedSeries(identifier: series.identifier)
            if let targetPane = self.activePaneView ?? self.paneViews.first {
                targetPane.display(series: series)
                self.preloadActiveSeries(series)
                self.selectedWLWWTitle = series.windowLevelPresetTitle
                self.toolbarView.reloadWLWWMenu(selectedTitle: self.selectedWLWWTitle, modality: series.modality)
                if self.activePaneView == nil {
                    self.setActivePane(targetPane)
                } else {
                    self.updateToolbarStatus()
                    self.updateReferenceLines()
                }
            }
        }

        scoutView.openSeriesHandler = { [weak self] series in
            self?.addPane(for: series, makeActive: true)
        }
        scoutView.overlaySeriesHandler = { [weak self] series in
            guard let self else { return }
            guard let targetPane = self.activePaneView ?? self.paneViews.first else {
                NSSound.beep()
                return
            }
            self.assignSeries(withIdentifier: series.identifier, to: targetPane, overlay: true)
        }

        DispatchQueue.main.async { [weak self] in
            self?.preloadActiveSeries(firstSeries)
        }
        metalWindowTimingLog("MetalViewerWindowController init total", since: initStart)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    func restoreSavedSplitPositionForPresentation() {
        restoreSavedSplitPosition()
    }

    private func restoreSavedSplitPosition() {
        defer { isRestoringSplitPosition = false }

        contentSplitView.layoutSubtreeIfNeeded()
        guard let savedWidth = UserDefaults.standard.object(forKey: Layout.scoutWidthAutosaveKey) as? Double else {
            return
        }

        let width = clampedScoutWidth(CGFloat(savedWidth))
        contentSplitView.setPosition(width, ofDividerAt: 0)
        scoutWidthConstraint.constant = scoutContainer.frame.width
    }

    private func saveSplitPosition() {
        guard isRestoringSplitPosition == false else { return }
        let width = clampedScoutWidth(scoutContainer.frame.width)
        UserDefaults.standard.set(Double(width), forKey: Layout.scoutWidthAutosaveKey)
        scoutWidthConstraint.constant = width
    }

    private func clampedScoutWidth(_ width: CGFloat) -> CGFloat {
        let maxWidth = max(
            Layout.minimumScoutWidth,
            contentSplitView.bounds.width - contentSplitView.dividerThickness - Layout.minimumPaneWidth
        )
        return min(max(width, Layout.minimumScoutWidth), maxWidth)
    }

    private static func savedScoutWidth(forSplitWidth splitWidth: CGFloat) -> CGFloat {
        guard let savedWidth = UserDefaults.standard.object(forKey: Layout.scoutWidthAutosaveKey) as? Double else {
            return Layout.minimumScoutWidth
        }

        let maxWidth = max(Layout.minimumScoutWidth, splitWidth - Layout.minimumPaneWidth)
        return min(max(CGFloat(savedWidth), Layout.minimumScoutWidth), maxWidth)
    }

    private func addPane(for series: MetalViewerSeries, makeActive: Bool, preload: Bool = true) {
        let addPaneStart = CFAbsoluteTimeGetCurrent()
        guard paneViews.count < Layout.maximumPaneCount else {
            NSSound.beep()
            return
        }

        let pane = MetalViewerPaneView(series: series)
        pane.setDisplayMode(viewerMode == .mpr ? .mpr : .stack2D)
        pane.activateHandler = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.setActivePane(pane)
        }
        pane.windowLevelInteractionHandler = { [weak self, weak pane] in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.selectedWLWWTitle = NSLocalizedString("Other", comment: "")
            self.toolbarView.selectWLWWTitle(self.selectedWLWWTitle)
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
            if preload {
                preloadActiveSeries(series)
            }
        }

        updateReferenceLines()
        metalWindowTimingLog("MetalViewerWindowController addPane \(series.title)", since: addPaneStart)
    }

    private func setActivePane(_ pane: MetalViewerPaneView) {
        activePaneView = pane
        for candidate in paneViews {
            candidate.isActive = (candidate === pane)
        }
        selectedWLWWTitle = pane.series.windowLevelPresetTitle
        toolbarView.reloadWLWWMenu(selectedTitle: selectedWLWWTitle, modality: pane.series.modality)
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
            preloadActiveSeries(series)
            selectedWLWWTitle = series.windowLevelPresetTitle
            toolbarView.reloadWLWWMenu(selectedTitle: selectedWLWWTitle, modality: series.modality)
        }
        scoutView.setSelectedSeries(identifier: series.identifier)

        if activePaneView === pane {
            updateToolbarStatus()
        }
        updateReferenceLines()
    }

    @discardableResult
    func updateStudy(_ study: MetalViewerStudy, selectInitialSeries: Bool = false) -> Int {
        let updateStart = CFAbsoluteTimeGetCurrent()
        var previousWindowLevelStates: [String: MetalViewerWindowLevelState] = [:]
        var previousWindowLevelPresetTitles: [String: String] = [:]
        for series in self.study.series {
            previousWindowLevelStates[series.identifier] = series.windowLevelState
            previousWindowLevelPresetTitles[series.identifier] = series.windowLevelPresetTitle
        }
        for series in study.series {
            if let windowLevelState = previousWindowLevelStates[series.identifier] {
                series.windowLevelState = windowLevelState
            }
            if let windowLevelPresetTitle = previousWindowLevelPresetTitles[series.identifier] {
                series.windowLevelPresetTitle = windowLevelPresetTitle
            }
        }
        self.study = study
        window?.title = study.title
        scoutView.reload(series: study.series, loadThumbnailsImmediately: false)
        let selectedIdentifier = selectInitialSeries ? study.initialSeriesIdentifier : (activePaneView?.series.identifier ?? study.initialSeriesIdentifier)
        scoutView.setSelectedSeries(identifier: selectedIdentifier)

        var refreshedPaneCount = 0
        for pane in paneViews {
            guard let updatedSeries = study.series.first(where: { $0.identifier == pane.series.identifier }) else {
                continue
            }
            let updatedOverlaySeries = pane.overlaySeries.flatMap { overlaySeries in
                study.series.first(where: { $0.identifier == overlaySeries.identifier })
            }
            if pane.refreshAfterDatabaseUpdate(series: updatedSeries, overlaySeries: updatedOverlaySeries) {
                refreshedPaneCount += 1
                if pane === activePaneView {
                    preloadActiveSeries(updatedSeries)
                }
            }
        }

        if selectInitialSeries,
           let selectedSeries = study.series.first(where: { $0.identifier == study.initialSeriesIdentifier }),
           let targetPane = activePaneView ?? paneViews.first {
            targetPane.display(series: selectedSeries)
            preloadActiveSeries(selectedSeries)
            selectedWLWWTitle = selectedSeries.windowLevelPresetTitle
            toolbarView.reloadWLWWMenu(selectedTitle: selectedWLWWTitle, modality: selectedSeries.modality)
            setActivePane(targetPane)
            refreshedPaneCount += 1
        }

        if let activeSeries = activePaneView?.series {
            selectedWLWWTitle = activeSeries.windowLevelPresetTitle
            toolbarView.reloadWLWWMenu(selectedTitle: selectedWLWWTitle, modality: activeSeries.modality)
        }
        updateToolbarStatus()
        updateReferenceLines()
        metalWindowTimingLog("MetalViewerWindowController updateStudy", since: updateStart)
        return refreshedPaneCount
    }

    private func updateToolbarStatus() {
        guard let activePaneView else {
            toolbarView.updateStatus("No active pane")
            return
        }

        let modeTitle = viewerMode == .mpr ? NSLocalizedString("MPR", comment: "") : NSLocalizedString("2D", comment: "")
        toolbarView.updateStatus("\(activePaneView.series.title)  •  \(modeTitle)  •  \(activePaneView.currentStateDescription)")
    }

    private func applyViewerMode(_ mode: MetalViewerToolbarView.ViewerMode) {
        viewerMode = mode
        let displayMode: MetalViewerDisplayMode = mode == .mpr ? .mpr : .stack2D
        guard let activePaneView else {
            toolbarView.selectViewerMode(mode)
            updateToolbarStatus()
            return
        }
        activePaneView.setDisplayMode(displayMode)
        toolbarView.selectViewerMode(mode)
        updateToolbarStatus()
        updateReferenceLines()
    }

    private func applyWLWWCommand(_ command: MetalViewerToolbarView.WLWWCommand) {
        guard let activePaneView else { return }

        switch command {
        case .other:
            selectedWLWWTitle = NSLocalizedString("Other", comment: "")
            activePaneView.series.windowLevelPresetTitle = selectedWLWWTitle

        case .defaultWindow:
            activePaneView.applyDefaultWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Default WL & WW", comment: "")
            activePaneView.series.windowLevelPresetTitle = selectedWLWWTitle

        case .robustSeries:
            activePaneView.applyRobustSeriesWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Robust MRI series", comment: "")
            activePaneView.series.windowLevelPresetTitle = selectedWLWWTitle

        case .fullDynamic:
            activePaneView.applyFullDynamicWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Full dynamic", comment: "")
            activePaneView.series.windowLevelPresetTitle = selectedWLWWTitle

        case .preset(let name):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                confirmDeleteWLWWPreset(named: name)
                return
            }
            guard let window = wlwwPreset(named: name) else { return }
            activePaneView.applyWindowLevel(window)
            selectedWLWWTitle = name
            activePaneView.series.windowLevelPresetTitle = selectedWLWWTitle

        case .addCurrent:
            addCurrentWLWWPreset()
            return

        case .setManually:
            setWLWWManually()
            return
        }

        toolbarView.selectWLWWTitle(selectedWLWWTitle)
        updateToolbarStatus()
    }

    private func wlwwPreset(named name: String) -> MetalViewerWindowLevel? {
        guard let value = UserDefaults.standard.dictionary(forKey: "WLWW3")?[name] else { return nil }
        if let values = value as? [NSNumber], values.count >= 2 {
            return MetalViewerWindowLevel(level: values[0].floatValue, width: max(1, values[1].floatValue))
        }
        if let values = value as? [Double], values.count >= 2 {
            return MetalViewerWindowLevel(level: Float(values[0]), width: max(1, Float(values[1])))
        }
        if let values = value as? [Float], values.count >= 2 {
            return MetalViewerWindowLevel(level: values[0], width: max(1, values[1]))
        }
        return nil
    }

    private func addCurrentWLWWPreset() {
        guard let currentWindow = activePaneView?.currentWindowLevel else { return }
        let modality = activePaneView?.series.modality ?? "OT"
        let defaultName = modality == "OT"
            ? NSLocalizedString("Unnamed", comment: "")
            : "\(modality) - \(NSLocalizedString("Unnamed", comment: ""))"
        presentWLWWEntrySheet(
            title: NSLocalizedString("Add Current WL/WW", comment: ""),
            name: defaultName,
            window: currentWindow,
            includesName: true
        ) { [weak self] name, window in
            guard let self, let name, name.isEmpty == false else { return }
            var presets = UserDefaults.standard.dictionary(forKey: "WLWW3") ?? [:]
            presets[name] = [NSNumber(value: window.level), NSNumber(value: window.width)]
            UserDefaults.standard.set(presets, forKey: "WLWW3")
            selectedWLWWTitle = name
            activePaneView?.applyWindowLevel(window)
            activePaneView?.series.windowLevelPresetTitle = name
            toolbarView.reloadWLWWMenu(selectedTitle: name, modality: activePaneView?.series.modality ?? "OT")
            updateToolbarStatus()
        }
    }

    private func setWLWWManually() {
        guard let currentWindow = activePaneView?.currentWindowLevel else { return }
        presentWLWWEntrySheet(
            title: NSLocalizedString("Set WL/WW Manually", comment: ""),
            name: nil,
            window: currentWindow,
            includesName: false
        ) { [weak self] _, window in
            guard let self else { return }
            selectedWLWWTitle = NSLocalizedString("Other", comment: "")
            activePaneView?.applyWindowLevel(window)
            activePaneView?.series.windowLevelPresetTitle = selectedWLWWTitle
            toolbarView.selectWLWWTitle(selectedWLWWTitle)
            updateToolbarStatus()
        }
    }

    private func confirmDeleteWLWWPreset(named name: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Remove a WL/WW preset", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Are you sure you want to delete preset: '%@'?", comment: ""), name)
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let deleteHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                self?.toolbarView.selectWLWWTitle(self?.selectedWLWWTitle ?? NSLocalizedString("Default WL & WW", comment: ""))
                return
            }
            var presets = UserDefaults.standard.dictionary(forKey: "WLWW3") ?? [:]
            presets.removeValue(forKey: name)
            UserDefaults.standard.set(presets, forKey: "WLWW3")
            self?.selectedWLWWTitle = NSLocalizedString("Default WL & WW", comment: "")
            self?.toolbarView.reloadWLWWMenu(
                selectedTitle: self?.selectedWLWWTitle ?? "",
                modality: self?.activePaneView?.series.modality ?? "OT"
            )
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: deleteHandler)
        } else {
            deleteHandler(alert.runModal())
        }
    }

    private func presentWLWWEntrySheet(
        title: String,
        name: String?,
        window initialWindow: MetalViewerWindowLevel,
        includesName: Bool,
        completion: @escaping (String?, MetalViewerWindowLevel) -> Void
    ) {
        let nameField = NSTextField(string: name ?? "")
        let wlField = NSTextField(string: String(format: "%.3f", initialWindow.level))
        let wwField = NSTextField(string: String(format: "%.3f", initialWindow.width))

        let rows: [[NSView]] = includesName
            ? [
                [NSTextField(labelWithString: NSLocalizedString("Name:", comment: "")), nameField],
                [NSTextField(labelWithString: NSLocalizedString("WL:", comment: "")), wlField],
                [NSTextField(labelWithString: NSLocalizedString("WW:", comment: "")), wwField],
            ]
            : [
                [NSTextField(labelWithString: NSLocalizedString("WL:", comment: "")), wlField],
                [NSTextField(labelWithString: NSLocalizedString("WW:", comment: "")), wwField],
            ]

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 160

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: includesName ? 86 : 56))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = container
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let responseHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let wl = Float(wlField.floatValue)
            let ww = max(1, Float(wwField.floatValue))
            completion(includesName ? nameField.stringValue : nil, MetalViewerWindowLevel(level: wl, width: ww))
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: responseHandler)
        } else {
            responseHandler(alert.runModal())
        }
    }

    private func preloadActiveSeries(_ series: MetalViewerSeries) {
        guard series.isStructuredReport == false else {
            seriesPreloader.cancel()
            return
        }

        let pixList = series.loadedPixList()
        seriesPreloader.preloadAfterFirstSlice(series: series, pixList: pixList)
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

private final class MetalViewerSeriesPreloader {
    private let queue = OperationQueue()
    private let stateLock = NSLock()
    private var generation = 0

    init() {
        let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        queue.name = "org.horos.metalviewer.series-preloader"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = workerCount
    }

    func cancel() {
        stateLock.lock()
        generation += 1
        stateLock.unlock()
        queue.cancelAllOperations()
    }

    func preloadAfterFirstSlice(series: MetalViewerSeries, pixList: [DCMPix]) {
        cancel()

        guard pixList.count > 1 else { return }

        stateLock.lock()
        let activeGeneration = generation
        stateLock.unlock()

        let preloadStart = CFAbsoluteTimeGetCurrent()
        let workerCount = queue.maxConcurrentOperationCount
        print("HOROS_METAL_TIMING MetalViewerSeriesPreloader start series=\(series.title) slices=\(pixList.count - 1) workers=\(workerCount)")

        let completion = BlockOperation { [weak self] in
            guard let self, self.isCurrent(activeGeneration) else { return }
            metalWindowTimingLog("MetalViewerSeriesPreloader finished series=\(series.title)", since: preloadStart)
        }

        for pix in pixList.dropFirst() {
            let operation = BlockOperation { [weak self] in
                guard let self, self.isCurrent(activeGeneration) else { return }
                pix.checkLoad()
            }
            completion.addDependency(operation)
            queue.addOperation(operation)
        }

        queue.addOperation(completion)
    }

    private func isCurrent(_ candidate: Int) -> Bool {
        stateLock.lock()
        let current = generation
        stateLock.unlock()
        return current == candidate
    }
}
