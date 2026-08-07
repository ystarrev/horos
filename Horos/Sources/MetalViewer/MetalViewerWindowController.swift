import AppKit

private final class MetalImagePrintView: NSView {
    private let image: NSImage
    private let printInfo: NSPrintInfo

    init(image: NSImage, printInfo: NSPrintInfo) {
        self.image = image
        self.printInfo = printInfo
        super.init(frame: NSRect(origin: .zero, size: printInfo.paperSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        setFrameSize(printInfo.paperSize)
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        setFrameSize(printInfo.paperSize)
        return bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        let destinationBounds = printInfo.imageablePageBounds.insetBy(dx: 4, dy: 4)
        guard destinationBounds.width > 0,
              destinationBounds.height > 0,
              image.size.width > 0,
              image.size.height > 0
        else {
            return
        }

        let scale = min(
            destinationBounds.width / image.size.width,
            destinationBounds.height / image.size.height
        )
        let imageSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(
            x: destinationBounds.midX - imageSize.width / 2,
            y: destinationBounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
    }
}

private final class MetalViewerWindow: NSWindow {
    var tabKeyHandler: ((Bool) -> Bool)?
    var annotationLevelHandler: ((MetalViewerAnnotationLevel) -> Void)?
    var modifierFlagsHandler: ((NSEvent.ModifierFlags) -> Void)?
    var printImageHandler: (() -> Void)?
    var wlwwMenuHandler: ((String) -> Void)?
    var clutMenuHandler: ((String) -> Void)?
    var opacityMenuHandler: ((String) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            modifierFlagsHandler?(event.modifierFlags)
        }
        if event.type == .keyDown,
           event.keyCode == 48,
           shouldUseTabForPaneTraversal(event),
           tabKeyHandler?(event.modifierFlags.contains(.shift)) == true {
            return
        }

        super.sendEvent(event)
    }

    override func resignKey() {
        modifierFlagsHandler?([])
        super.resignKey()
    }

    @objc func annotMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let level = MetalViewerAnnotationLevel(rawValue: menuItem.tag) else {
            return
        }
        annotationLevelHandler?(level)
    }

    override func printWindow(_ sender: Any?) {
        printImageHandler?()
    }

    @objc(ApplyWLWW:)
    private func applyWLWWFromMenu(_ sender: Any?) {
        guard let title = (sender as? NSMenuItem)?.title else { return }
        wlwwMenuHandler?(title)
    }

    @objc(ApplyCLUT:)
    private func applyCLUTFromMenu(_ sender: Any?) {
        guard let title = (sender as? NSMenuItem)?.title else { return }
        clutMenuHandler?(title)
    }

    @objc(ApplyOpacity:)
    private func applyOpacityFromMenu(_ sender: Any?) {
        guard let title = (sender as? NSMenuItem)?.title else { return }
        opacityMenuHandler?(title)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printWindow(_:)) {
            return printImageHandler != nil
        }
        if menuItem.action == NSSelectorFromString("ApplyWLWW:") {
            return wlwwMenuHandler != nil
        }
        if menuItem.action == NSSelectorFromString("ApplyCLUT:") {
            return clutMenuHandler != nil
        }
        if menuItem.action == NSSelectorFromString("ApplyOpacity:") {
            return opacityMenuHandler != nil
        }
        guard menuItem.action == #selector(annotMenu(_:)) else {
            return true
        }

        guard let level = MetalViewerAnnotationLevel(rawValue: menuItem.tag) else {
            menuItem.state = .off
            return false
        }
        menuItem.state = level == MetalViewerAnnotationLevel.current ? .on : .off
        return true
    }

    private func shouldUseTabForPaneTraversal(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.intersection([.command, .control, .option]).isEmpty
    }
}

final class MetalViewerWindowController: NSWindowController, NSSplitViewDelegate {
    private struct RegistrationFramePair: Hashable {
        let movingFrameUID: String
        let fixedFrameUID: String
    }

    private enum Layout {
        static let defaultScoutDimension: CGFloat = 172
        static let minimumScoutDimension: CGFloat = 86
        static let minimumPaneWidth: CGFloat = 480
        static let minimumPaneHeight: CGFloat = 300
        static let maximumPaneCount = 8
        static let scoutWidthAutosaveKey = "HorosMetalViewerScoutWidth"
        static let scoutHeightAutosaveKey = "HorosMetalViewerScoutHeight"
        static let leftSplitViewAutosaveName = "HorosMetalViewerSplitView.Left"
        static let bottomSplitViewAutosaveName = "HorosMetalViewerSplitView.Bottom"
        static let syncScaleAutosaveKey = "HorosMetalViewerSyncScale"
    }

    private var study: MetalViewerStudy
    private var scoutPlacement: MetalViewerScoutPlacement
    private let toolbarView = MetalViewerToolbarView(frame: .zero)
    private let scoutView: MetalViewerScoutView
    private let contentSplitView = NSSplitView(frame: .zero)
    private let scoutContainer = NSView()
    private let paneContainer = NSView()
    private let paneStackView = NSStackView()
    private let scoutWidthConstraint: NSLayoutConstraint
    private let scoutHeightConstraint: NSLayoutConstraint

    private var paneViews: [MetalViewerPaneView] = []
    private weak var activePaneView: MetalViewerPaneView?
    private var isRestoringSplitPosition = true
    private var selectedWLWWTitle = NSLocalizedString("Default WL & WW", comment: "")
    private var viewerMode: MetalViewerToolbarView.ViewerMode = .stack2D
    private var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private var isSyncScaleEnabled = UserDefaults.standard.bool(forKey: Layout.syncScaleAutosaveKey)
    private var isApplyingSyncedScale = false
    private var lastPaneScales: [ObjectIdentifier: Float] = [:]
    private var annotationDefaultsObserver: NSObjectProtocol?
    private var scoutPlacementObserver: NSObjectProtocol?
    private var registrationTransformsByFramePair: [
        RegistrationFramePair: MetalViewerRegistrationWorldTransform
    ] = [:]

    init(study: MetalViewerStudy) {
        self.study = study
        let initialScoutPlacement = MetalViewerScoutPlacement.saved
        self.scoutPlacement = initialScoutPlacement

        let firstSeries = study.series.first { $0.identifier == study.initialSeriesIdentifier } ?? study.series[0]
        let firstPix = firstSeries.firstPreviewPix() ?? firstSeries.loadedPixList()[0]
        let imageWidth = max(CGFloat(firstPix.pwidth), 512)
        let imageHeight = max(CGFloat(firstPix.pheight), 512)
        let aspectRatio = imageWidth / max(imageHeight, 1)
        let contentWidth = min(max(imageWidth, 900), 1600)
        let contentHeight = min(max(contentWidth / aspectRatio, 700), 1200)
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let window = MetalViewerWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.scoutView = MetalViewerScoutView(
            series: study.series,
            procedureEvents: study.procedureEvents,
            placement: initialScoutPlacement
        )
        self.scoutWidthConstraint = scoutContainer.widthAnchor.constraint(
            equalToConstant: Self.savedScoutDimension(for: .left, splitLength: contentRect.width)
        )
        self.scoutHeightConstraint = scoutContainer.heightAnchor.constraint(
            equalToConstant: Self.savedScoutDimension(for: .bottom, splitLength: contentRect.height)
        )

        window.title = study.title
        window.minSize = NSSize(width: 980, height: 640)
        window.center()

        let rootView = NSView(frame: contentRect)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor

        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.isVertical = initialScoutPlacement == .left
        contentSplitView.dividerStyle = .thin
        contentSplitView.autosaveName = initialScoutPlacement == .left
            ? Layout.leftSplitViewAutosaveName
            : Layout.bottomSplitViewAutosaveName
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
        paneStackView.alignment = .width
        paneStackView.spacing = 8
        paneContainer.addSubview(paneStackView)

        if initialScoutPlacement == .left {
            contentSplitView.addArrangedSubview(scoutContainer)
            contentSplitView.addArrangedSubview(paneContainer)
            contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        } else {
            contentSplitView.addArrangedSubview(paneContainer)
            contentSplitView.addArrangedSubview(scoutContainer)
            contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        }

        scoutWidthConstraint.priority = .defaultLow
        scoutHeightConstraint.priority = .defaultLow

        rootView.addSubview(toolbarView)
        rootView.addSubview(contentSplitView)
        window.contentView = rootView

        super.init(window: window)

        window.tabKeyHandler = { [weak self] moveBackward in
            self?.moveActivePane(backward: moveBackward) ?? false
        }
        window.annotationLevelHandler = { [weak self] level in
            self?.setAnnotationLevel(level)
        }
        window.modifierFlagsHandler = { [weak self] flags in
            self?.toolbarView.setMouseModifierFlags(flags)
        }
        window.printImageHandler = { [weak self] in
            self?.printActiveImage()
        }
        window.wlwwMenuHandler = { [weak self] title in
            self?.applyWLWWMenuTitle(title)
        }
        window.clutMenuHandler = { [weak self] title in
            self?.applyCLUT(named: title)
        }
        window.opacityMenuHandler = { [weak self] title in
            self?.applyOpacity(named: title)
        }
        contentSplitView.delegate = self
        toolbarView.wlwwSelectionHandler = { [weak self] command in
            self?.applyWLWWCommand(command)
        }
        toolbarView.clutSelectionHandler = { [weak self] presetName in
            self?.applyCLUT(named: presetName)
        }
        toolbarView.opacitySelectionHandler = { [weak self] presetName in
            self?.applyOpacity(named: presetName)
        }
        toolbarView.viewerModeSelectionHandler = { [weak self] mode in
            self?.applyViewerMode(mode)
        }
        toolbarView.selectMouseToolAssignments(mouseToolAssignments)
        toolbarView.mouseToolSelectionHandler = { [weak self] assignments in
            self?.applyMouseToolAssignments(assignments)
        }
        toolbarView.setSyncScaleEnabled(isSyncScaleEnabled)
        toolbarView.syncScaleSelectionHandler = { [weak self] isEnabled in
            self?.setSyncScaleEnabled(isEnabled)
        }
        toolbarView.annotationLevelSelectionHandler = { [weak self] level in
            self?.setAnnotationLevel(level)
        }
        setAnnotationLevel(MetalViewerAnnotationLevel.current)
        annotationDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyAnnotationLevel(MetalViewerAnnotationLevel.current)
            if let activePaneView = self.activePaneView {
                self.reloadDisplayMenus(for: activePaneView)
            }
        }
        scoutPlacementObserver = NotificationCenter.default.addObserver(
            forName: MetalViewerScoutPlacement.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let placement = notification.object as? MetalViewerScoutPlacement
                ?? MetalViewerScoutPlacement.saved
            self?.applyScoutPlacement(placement)
        }

        var constraints = [
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
        ]
        constraints.append(initialScoutPlacement == .left ? scoutWidthConstraint : scoutHeightConstraint)
        NSLayoutConstraint.activate(constraints)

        addPane(for: firstSeries, makeActive: true)

        scoutView.selectionHandler = { [weak self] series in
            guard let self else { return }
            if let targetPane = self.activePaneView ?? self.paneViews.first {
                let syncedScale = self.synchronizedScaleValue(excluding: targetPane) ?? targetPane.currentScale
                targetPane.display(series: series)
                self.applySyncedScaleIfNeeded(to: targetPane, preferredScale: syncedScale)
                self.reloadWLWWMenu(for: targetPane)
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

    }

    deinit {
        if let annotationDefaultsObserver {
            NotificationCenter.default.removeObserver(annotationDefaultsObserver)
        }
        if let scoutPlacementObserver {
            NotificationCenter.default.removeObserver(scoutPlacementObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMinimumPosition }
        let minimumPosition = isScoutFirst
            ? Layout.minimumScoutDimension
            : minimumPaneDimension
        return max(proposedMinimumPosition, minimumPosition)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMaximumPosition }
        let trailingMinimum = isScoutFirst ? minimumPaneDimension : Layout.minimumScoutDimension
        let maximumPosition = max(
            isScoutFirst ? Layout.minimumScoutDimension : minimumPaneDimension,
            splitLength - splitView.dividerThickness - trailingMinimum
        )
        return min(proposedMaximumPosition, maximumPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as AnyObject? === contentSplitView else { return }
        activeScoutDimensionConstraint.constant = currentScoutDimension
        saveSplitPosition()
    }

    func restoreSavedSplitPositionForPresentation() {
        restoreSavedSplitPosition()
    }

    private func recalibrateScoutLayoutAfterPresentation() {
        DispatchQueue.main.async { [weak self] in
            self?.performScoutLayoutRecalibration()
            DispatchQueue.main.async { [weak self] in
                self?.performScoutLayoutRecalibration()
            }
        }
    }

    private func restoreSavedSplitPosition() {
        defer { isRestoringSplitPosition = false }

        contentSplitView.layoutSubtreeIfNeeded()
        let dimension = Self.savedScoutDimension(for: scoutPlacement, splitLength: splitLength)
        contentSplitView.setPosition(dividerPosition(forScoutDimension: dimension), ofDividerAt: 0)
        activeScoutDimensionConstraint.constant = currentScoutDimension
    }

    private func performScoutLayoutRecalibration() {
        window?.contentView?.layoutSubtreeIfNeeded()
        contentSplitView.layoutSubtreeIfNeeded()

        let currentDimension = currentScoutDimension > 0
            ? currentScoutDimension
            : activeScoutDimensionConstraint.constant
        let dimension = clampedScoutDimension(currentDimension)
        let largerDimension = clampedScoutDimension(dimension + 1)
        let smallerDimension = clampedScoutDimension(dimension - 1)
        let nudgeDimension = largerDimension != dimension ? largerDimension : smallerDimension

        if nudgeDimension != dimension {
            contentSplitView.setPosition(
                dividerPosition(forScoutDimension: nudgeDimension),
                ofDividerAt: 0
            )
            contentSplitView.layoutSubtreeIfNeeded()
        }

        contentSplitView.setPosition(
            dividerPosition(forScoutDimension: dimension),
            ofDividerAt: 0
        )
        contentSplitView.adjustSubviews()
        activeScoutDimensionConstraint.constant = currentScoutDimension
        scoutView.recalibrateLayoutForCurrentDimension()
    }

    private func saveSplitPosition() {
        guard isRestoringSplitPosition == false else { return }
        let displayedDimension = currentScoutDimension > 0
            ? currentScoutDimension
            : activeScoutDimensionConstraint.constant
        let dimension = clampedScoutDimension(displayedDimension)
        UserDefaults.standard.set(Double(dimension), forKey: scoutDimensionAutosaveKey)
        activeScoutDimensionConstraint.constant = dimension
    }

    private func clampedScoutDimension(_ dimension: CGFloat) -> CGFloat {
        let maximumDimension = max(
            Layout.minimumScoutDimension,
            splitLength - contentSplitView.dividerThickness - minimumPaneDimension
        )
        return min(max(dimension, Layout.minimumScoutDimension), maximumDimension)
    }

    private static func savedScoutDimension(
        for placement: MetalViewerScoutPlacement,
        splitLength: CGFloat
    ) -> CGFloat {
        let defaultsKey = placement == .left
            ? Layout.scoutWidthAutosaveKey
            : Layout.scoutHeightAutosaveKey
        let savedDimension = (UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber)
            .map { CGFloat(truncating: $0) }
            ?? Layout.defaultScoutDimension
        let minimumPaneDimension = placement == .left
            ? Layout.minimumPaneWidth
            : Layout.minimumPaneHeight
        let maximumDimension = max(
            Layout.minimumScoutDimension,
            splitLength - minimumPaneDimension
        )
        return min(
            max(savedDimension, Layout.minimumScoutDimension),
            maximumDimension
        )
    }

    private var isScoutFirst: Bool {
        contentSplitView.arrangedSubviews.first === scoutContainer
    }

    private var splitLength: CGFloat {
        scoutPlacement == .left
            ? contentSplitView.bounds.width
            : contentSplitView.bounds.height
    }

    private var currentScoutDimension: CGFloat {
        scoutPlacement == .left
            ? scoutContainer.frame.width
            : scoutContainer.frame.height
    }

    private var minimumPaneDimension: CGFloat {
        scoutPlacement == .left
            ? Layout.minimumPaneWidth
            : Layout.minimumPaneHeight
    }

    private var activeScoutDimensionConstraint: NSLayoutConstraint {
        scoutPlacement == .left ? scoutWidthConstraint : scoutHeightConstraint
    }

    private var scoutDimensionAutosaveKey: String {
        scoutPlacement == .left
            ? Layout.scoutWidthAutosaveKey
            : Layout.scoutHeightAutosaveKey
    }

    private func dividerPosition(forScoutDimension dimension: CGFloat) -> CGFloat {
        if isScoutFirst {
            return dimension
        }
        return max(
            minimumPaneDimension,
            splitLength - contentSplitView.dividerThickness - dimension
        )
    }

    private func applyScoutPlacement(_ placement: MetalViewerScoutPlacement) {
        guard placement != scoutPlacement else { return }

        saveSplitPosition()
        isRestoringSplitPosition = true
        activeScoutDimensionConstraint.isActive = false

        contentSplitView.removeArrangedSubview(scoutContainer)
        scoutContainer.removeFromSuperview()
        contentSplitView.removeArrangedSubview(paneContainer)
        paneContainer.removeFromSuperview()

        scoutPlacement = placement
        contentSplitView.isVertical = placement == .left
        contentSplitView.autosaveName = placement == .left
            ? Layout.leftSplitViewAutosaveName
            : Layout.bottomSplitViewAutosaveName
        if placement == .left {
            contentSplitView.addArrangedSubview(scoutContainer)
            contentSplitView.addArrangedSubview(paneContainer)
            contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        } else {
            contentSplitView.addArrangedSubview(paneContainer)
            contentSplitView.addArrangedSubview(scoutContainer)
            contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        }

        activeScoutDimensionConstraint.constant = Self.savedScoutDimension(
            for: placement,
            splitLength: splitLength
        )
        activeScoutDimensionConstraint.isActive = true
        scoutView.setPlacement(placement)

        window?.contentView?.layoutSubtreeIfNeeded()
        contentSplitView.layoutSubtreeIfNeeded()
        restoreSavedSplitPosition()
        recalibrateScoutLayoutAfterPresentation()
    }

    private func addPane(for series: MetalViewerSeries, makeActive: Bool) {
        guard paneViews.count < Layout.maximumPaneCount else {
            NSSound.beep()
            return
        }

        let pane = MetalViewerPaneView(series: series)
        pane.setMouseToolAssignments(mouseToolAssignments)
        pane.setDisplayMode(displayMode(for: viewerMode))
        pane.activateHandler = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.setActivePane(pane)
        }
        pane.windowLevelInteractionHandler = { [weak self, weak pane] in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.selectedWLWWTitle = NSLocalizedString("Other", comment: "")
            self.toolbarView.selectWLWWTitle(self.selectedWLWWTitle)
        }
        pane.windowLevelTargetDidChange = { [weak self, weak pane] _ in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.reloadWLWWMenu(for: pane)
        }
        pane.seriesDropHandler = { [weak self, weak pane] identifier, isOverlay in
            guard let self, let pane else { return }
            self.assignSeries(withIdentifier: identifier, to: pane, overlay: isOverlay)
        }
        pane.displayedSeriesDidChange = { [weak self, weak pane] in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.updateScoutHighlights(for: pane)
        }
        pane.registrationInitialTransformProvider = { [weak self] baseSeries, overlaySeries in
            self?.registrationTransform(
                forBaseSeries: baseSeries,
                overlaySeries: overlaySeries
            )
        }
        pane.registrationSupportSelectionProvider = { [weak self] baseSeries, overlaySeries in
            self?.registrationSupportSelection(
                forBaseSeries: baseSeries,
                overlaySeries: overlaySeries
            )
        }
        pane.registrationTransformDidComplete = { [weak self] baseSeries, overlaySeries, transform in
            self?.storeRegistrationTransform(
                transform,
                forBaseSeries: baseSeries,
                overlaySeries: overlaySeries
            )
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
            self.handlePaneScaleDidChange(pane)
        }

        paneViews.append(pane)
        applySyncedScaleIfNeeded(to: pane)
        recordScale(for: pane)
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
        updateScoutHighlights(for: pane)
        reloadWLWWMenu(for: pane)
        pane.focusImageView()
        updateToolbarStatus()
        updateReferenceLines()
    }

    @discardableResult
    private func moveActivePane(backward: Bool) -> Bool {
        guard paneViews.isEmpty == false else {
            return false
        }

        guard paneViews.count > 1 else {
            setActivePane(paneViews[0])
            return true
        }

        let currentIndex: Int
        if let activePaneView,
           let activeIndex = paneViews.firstIndex(where: { $0 === activePaneView }) {
            currentIndex = activeIndex
        } else {
            currentIndex = backward ? 0 : -1
        }

        let offset = backward ? -1 : 1
        let nextIndex = (currentIndex + offset + paneViews.count) % paneViews.count
        setActivePane(paneViews[nextIndex])
        return true
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
            rowStack.alignment = .height
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
        lastPaneScales.removeValue(forKey: ObjectIdentifier(pane))
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
            let syncedScale = synchronizedScaleValue(excluding: pane) ?? pane.currentScale
            pane.display(series: series)
            applySyncedScaleIfNeeded(to: pane, preferredScale: syncedScale)
            if activePaneView === pane {
                reloadWLWWMenu(for: pane)
            }
        }
        if activePaneView === pane {
            updateToolbarStatus()
        }
        updateReferenceLines()
    }

    private func registrationTransform(
        forBaseSeries baseSeries: MetalViewerSeries,
        overlaySeries: MetalViewerSeries
    ) -> MetalViewerRegistrationWorldTransform? {
        guard let fixedFrameUID = baseSeries.frameOfReferenceUID,
              let movingFrameUID = overlaySeries.frameOfReferenceUID,
              fixedFrameUID != movingFrameUID else {
            return nil
        }

        let directKey = RegistrationFramePair(
            movingFrameUID: movingFrameUID,
            fixedFrameUID: fixedFrameUID
        )
        if let directTransform = registrationTransformsByFramePair[directKey] {
            return directTransform
        }

        let reverseKey = RegistrationFramePair(
            movingFrameUID: fixedFrameUID,
            fixedFrameUID: movingFrameUID
        )
        return registrationTransformsByFramePair[reverseKey]?.inverted
    }

    private func storeRegistrationTransform(
        _ transform: MetalViewerRegistrationWorldTransform,
        forBaseSeries baseSeries: MetalViewerSeries,
        overlaySeries: MetalViewerSeries
    ) {
        guard let fixedFrameUID = baseSeries.frameOfReferenceUID,
              let movingFrameUID = overlaySeries.frameOfReferenceUID,
              fixedFrameUID != movingFrameUID else {
            return
        }
        let key = RegistrationFramePair(
            movingFrameUID: movingFrameUID,
            fixedFrameUID: fixedFrameUID
        )
        registrationTransformsByFramePair[key] = transform
    }

    private func registrationSupportSelection(
        forBaseSeries baseSeries: MetalViewerSeries,
        overlaySeries: MetalViewerSeries
    ) -> MetalViewerRegistrationSupportSelection? {
        let baseModality = baseSeries.modality.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let overlayModality = overlaySeries.modality.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if baseModality == "MR", overlayModality == "MR" {
            return longitudinalMRRegistrationSupportSelection(
                forBaseSeries: baseSeries,
                overlaySeries: overlaySeries
            )
        }

        let mrSeries: MetalViewerSeries
        let sharesBaseFrame: Bool
        if baseModality == "MR", overlayModality == "CT" {
            mrSeries = baseSeries
            sharesBaseFrame = true
        } else if baseModality == "CT", overlayModality == "MR" {
            mrSeries = overlaySeries
            sharesBaseFrame = false
        } else {
            return nil
        }

        guard let frameUID = mrSeries.frameOfReferenceUID,
              let primaryMetadata = mrSeries.registrationMetadata else {
            return nil
        }

        let supportCandidates = study.series.filter { candidate in
            guard candidate !== mrSeries,
                  candidate.studyIdentifier == mrSeries.studyIdentifier,
                  candidate.isMagneticResonance,
                  candidate.frameOfReferenceUID == frameUID,
                  candidate.sharesSourceSeries(with: mrSeries) == false,
                  let metadata = candidate.registrationMetadata,
                  metadata.isEligibleSupportSeries else {
                return false
            }
            return true
        }

        var selectedSeries = [mrSeries]
        var orientationCounts: [MetalViewerRegistrationOrientationGroup: Int] = [
            primaryMetadata.orientation: 1,
        ]
        var representedContrasts = Set([
            "\(primaryMetadata.orientation.rawValue)|\(primaryMetadata.contrast.rawValue)",
        ])
        let contrastPriority: [MetalViewerRegistrationContrastGroup: Int] = [
            .t1PostContrast: 0,
            .t1: 1,
            .t2: 2,
            .flair: 3,
            .other: 4,
        ]
        let sortedCandidates = supportCandidates.sorted { lhs, rhs in
            guard let lhsMetadata = lhs.registrationMetadata,
                  let rhsMetadata = rhs.registrationMetadata else {
                return lhs.imageCount > rhs.imageCount
            }
            let lhsIsOrthogonal = lhsMetadata.orientation != primaryMetadata.orientation
            let rhsIsOrthogonal = rhsMetadata.orientation != primaryMetadata.orientation
            if lhsIsOrthogonal != rhsIsOrthogonal {
                return lhsIsOrthogonal
            }
            let lhsPriority = contrastPriority[lhsMetadata.contrast] ?? Int.max
            let rhsPriority = contrastPriority[rhsMetadata.contrast] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.imageCount != rhs.imageCount {
                return lhs.imageCount > rhs.imageCount
            }
            return lhs.identifier < rhs.identifier
        }

        var repeatedContrastCandidates = [MetalViewerSeries]()
        for candidate in sortedCandidates {
            guard selectedSeries.count < 6 else { break }
            guard let metadata = candidate.registrationMetadata else { continue }
            let key = "\(metadata.orientation.rawValue)|\(metadata.contrast.rawValue)"
            guard (orientationCounts[metadata.orientation] ?? 0) < 3,
                  selectedSeries.allSatisfy({ $0.sharesSourceSeries(with: candidate) == false }) else {
                continue
            }
            guard representedContrasts.contains(key) == false else {
                repeatedContrastCandidates.append(candidate)
                continue
            }
            representedContrasts.insert(key)
            orientationCounts[metadata.orientation, default: 0] += 1
            selectedSeries.append(candidate)
        }

        // Some scanners copy ContrastBolusAgent to every series in an exam,
        // making pre- and post-contrast T1 series look identical in metadata.
        // Prefer contrast diversity first, then fill remaining orientation
        // slots so those useful companion acquisitions are not discarded.
        for candidate in repeatedContrastCandidates {
            guard selectedSeries.count < 6 else { break }
            guard let metadata = candidate.registrationMetadata,
                  (orientationCounts[metadata.orientation] ?? 0) < 3,
                  selectedSeries.allSatisfy({ $0.sharesSourceSeries(with: candidate) == false }) else {
                continue
            }
            orientationCounts[metadata.orientation, default: 0] += 1
            selectedSeries.append(candidate)
        }

        guard selectedSeries.count > 1 else { return nil }
        let groupedByOrientation = Dictionary(grouping: selectedSeries) {
            $0.registrationMetadata?.orientation ?? .oblique
        }
        let orientationWeight = 1 / Float(max(groupedByOrientation.count, 1))
        var weightsByIdentifier: [String: Float] = [:]
        for seriesGroup in groupedByOrientation.values {
            let seriesWeight = orientationWeight / Float(max(seriesGroup.count, 1))
            for series in seriesGroup {
                weightsByIdentifier[series.identifier] = seriesWeight
            }
        }

        let primaryWeight = weightsByIdentifier[mrSeries.identifier] ?? 1
        let items = selectedSeries.dropFirst().map { series in
            MetalViewerRegistrationSupportSelection.Item(
                series: series,
                sharesBaseFrame: sharesBaseFrame,
                weight: weightsByIdentifier[series.identifier] ?? 0
            )
        }
        return MetalViewerRegistrationSupportSelection(
            primaryWeight: primaryWeight,
            items: items
        )
    }

    private func longitudinalMRRegistrationSupportSelection(
        forBaseSeries baseSeries: MetalViewerSeries,
        overlaySeries: MetalViewerSeries
    ) -> MetalViewerRegistrationSupportSelection? {
        guard baseSeries.studyIdentifier != overlaySeries.studyIdentifier,
              let baseFrameUID = baseSeries.frameOfReferenceUID,
              let overlayFrameUID = overlaySeries.frameOfReferenceUID,
              let baseMetadata = baseSeries.registrationMetadata,
              let overlayMetadata = overlaySeries.registrationMetadata,
              baseMetadata.orientation == overlayMetadata.orientation else {
            return nil
        }

        func supportCandidates(
            for primarySeries: MetalViewerSeries,
            frameUID: String
        ) -> [MetalViewerSeries] {
            study.series.filter { candidate in
                guard candidate !== primarySeries,
                      candidate.studyIdentifier == primarySeries.studyIdentifier,
                      candidate.isMagneticResonance,
                      candidate.frameOfReferenceUID == frameUID,
                      candidate.sharesSourceSeries(with: primarySeries) == false,
                      let metadata = candidate.registrationMetadata,
                      metadata.isEligibleSupportSeries else {
                    return false
                }
                return true
            }
        }

        func contrastsAreCompatible(
            _ lhs: MetalViewerRegistrationContrastGroup,
            _ rhs: MetalViewerRegistrationContrastGroup
        ) -> Bool {
            lhs == rhs
                || (lhs == .t1 && rhs == .t1PostContrast)
                || (lhs == .t1PostContrast && rhs == .t1)
        }

        typealias CandidatePair = (
            base: MetalViewerSeries,
            overlay: MetalViewerSeries,
            metadata: MetalViewerRegistrationSeriesMetadata,
            orthogonalPenalty: Int,
            contrastPenalty: Int,
            imageCountDifference: Int
        )
        let baseCandidates = supportCandidates(for: baseSeries, frameUID: baseFrameUID)
        let overlayCandidates = supportCandidates(for: overlaySeries, frameUID: overlayFrameUID)
        var candidatePairs = [CandidatePair]()
        for baseCandidate in baseCandidates {
            guard let baseCandidateMetadata = baseCandidate.registrationMetadata else { continue }
            for overlayCandidate in overlayCandidates {
                guard let overlayCandidateMetadata = overlayCandidate.registrationMetadata,
                      baseCandidateMetadata.orientation == overlayCandidateMetadata.orientation,
                      baseCandidateMetadata.reconstruction == overlayCandidateMetadata.reconstruction,
                      contrastsAreCompatible(
                          baseCandidateMetadata.contrast,
                          overlayCandidateMetadata.contrast
                      ) else {
                    continue
                }
                candidatePairs.append((
                    base: baseCandidate,
                    overlay: overlayCandidate,
                    metadata: baseCandidateMetadata,
                    orthogonalPenalty: baseCandidateMetadata.orientation == baseMetadata.orientation ? 1 : 0,
                    contrastPenalty: baseCandidateMetadata.contrast == overlayCandidateMetadata.contrast ? 0 : 1,
                    imageCountDifference: abs(baseCandidate.imageCount - overlayCandidate.imageCount)
                ))
            }
        }

        candidatePairs.sort { lhs, rhs in
            if lhs.orthogonalPenalty != rhs.orthogonalPenalty {
                return lhs.orthogonalPenalty < rhs.orthogonalPenalty
            }
            if lhs.contrastPenalty != rhs.contrastPenalty {
                return lhs.contrastPenalty < rhs.contrastPenalty
            }
            if lhs.imageCountDifference != rhs.imageCountDifference {
                return lhs.imageCountDifference < rhs.imageCountDifference
            }
            if lhs.base.imageCount != rhs.base.imageCount {
                return lhs.base.imageCount > rhs.base.imageCount
            }
            if lhs.base.identifier != rhs.base.identifier {
                return lhs.base.identifier < rhs.base.identifier
            }
            return lhs.overlay.identifier < rhs.overlay.identifier
        }

        var selectedPairs = [CandidatePair]()
        var usedBaseIdentifiers = Set<String>()
        var usedOverlayIdentifiers = Set<String>()
        var representedChannels = Set<String>()
        for pair in candidatePairs {
            guard selectedPairs.count < 3,
                  usedBaseIdentifiers.contains(pair.base.identifier) == false,
                  usedOverlayIdentifiers.contains(pair.overlay.identifier) == false else {
                continue
            }
            let channel = [
                pair.metadata.orientation.rawValue,
                pair.metadata.contrast.rawValue,
                pair.metadata.reconstruction.rawValue,
            ].joined(separator: "|")
            guard representedChannels.insert(channel).inserted else { continue }
            usedBaseIdentifiers.insert(pair.base.identifier)
            usedOverlayIdentifiers.insert(pair.overlay.identifier)
            selectedPairs.append(pair)
        }
        guard selectedPairs.isEmpty == false else { return nil }

        var channelCountByOrientation: [MetalViewerRegistrationOrientationGroup: Int] = [
            baseMetadata.orientation: 1,
        ]
        for pair in selectedPairs {
            channelCountByOrientation[pair.metadata.orientation, default: 0] += 1
        }
        let orientationWeight = 1 / Float(max(channelCountByOrientation.count, 1))
        let primaryWeight = orientationWeight
            / Float(max(channelCountByOrientation[baseMetadata.orientation] ?? 1, 1))
        let items = selectedPairs.map { pair in
            MetalViewerRegistrationSupportSelection.Item(
                series: pair.base,
                pairedSeries: pair.overlay,
                sharesBaseFrame: true,
                weight: orientationWeight
                    / Float(max(channelCountByOrientation[pair.metadata.orientation] ?? 1, 1))
            )
        }
        return MetalViewerRegistrationSupportSelection(
            primaryWeight: primaryWeight,
            items: items
        )
    }

    @discardableResult
    func updateStudy(
        _ study: MetalViewerStudy,
        selectInitialSeries: Bool = false,
        revealSelectedSeriesInScout: Bool = false
    ) -> Int {
        for series in study.series {
            let previousSeries = self.study.series.first(where: { $0.identifier == series.identifier })
                ?? self.study.series.first(where: { $0.sharesSourceSeries(with: series) })
            if let previousSeries {
                let automaticWindowNeedsRefresh =
                    previousSeries.windowLevelPresetTitle == NSLocalizedString("Auto", comment: "")
                    && series.imageCount != previousSeries.imageCount
                series.windowLevelState = automaticWindowNeedsRefresh
                    ? MetalViewerWindowLevelState()
                    : previousSeries.windowLevelState
                series.windowLevelPresetTitle = previousSeries.windowLevelPresetTitle
                series.transferFunctionState = previousSeries.transferFunctionState
            }
        }
        self.study = study
        window?.title = study.title
        scoutView.reload(
            series: study.series,
            procedureEvents: study.procedureEvents,
            loadThumbnailsImmediately: false
        )
        let selectedSeries = selectInitialSeries
            ? study.series.first(where: { $0.identifier == study.initialSeriesIdentifier })
            : activePaneView.flatMap { matchingSeries(for: $0.series, in: study) }
        let selectedIdentifier = selectedSeries?.identifier ?? study.initialSeriesIdentifier
        let selectedOverlayIdentifier = selectInitialSeries
            ? nil
            : activePaneView?.overlaySeries.flatMap { matchingSeries(for: $0, in: study) }?.identifier
        scoutView.setDisplayedSeries(
            primaryIdentifier: selectedIdentifier,
            overlayIdentifier: selectedOverlayIdentifier,
            scrollToVisible: revealSelectedSeriesInScout
        )

        var refreshedPaneCount = 0
        for pane in paneViews {
            guard let updatedSeries = matchingSeries(for: pane.series, in: study) else {
                continue
            }
            let syncedScale = synchronizedScaleValue(excluding: pane) ?? pane.currentScale
            let updatedOverlaySeries = pane.overlaySeries.flatMap { overlaySeries in
                matchingSeries(for: overlaySeries, in: study)
            }
            if pane.refreshAfterDatabaseUpdate(series: updatedSeries, overlaySeries: updatedOverlaySeries) {
                applySyncedScaleIfNeeded(to: pane, preferredScale: syncedScale)
                refreshedPaneCount += 1
            }
        }

        if selectInitialSeries,
           let selectedSeries = study.series.first(where: { $0.identifier == study.initialSeriesIdentifier }),
           let targetPane = activePaneView ?? paneViews.first {
            let syncedScale = synchronizedScaleValue(excluding: targetPane) ?? targetPane.currentScale
            targetPane.display(series: selectedSeries)
            applySyncedScaleIfNeeded(to: targetPane, preferredScale: syncedScale)
            setActivePane(targetPane)
            refreshedPaneCount += 1
        }

        if let activePaneView {
            updateScoutHighlights(for: activePaneView)
            reloadWLWWMenu(for: activePaneView)
        }
        updateToolbarStatus()
        updateReferenceLines()
        recalibrateScoutLayoutAfterPresentation()
        return refreshedPaneCount
    }

    private func matchingSeries(for previousSeries: MetalViewerSeries, in study: MetalViewerStudy) -> MetalViewerSeries? {
        study.series.first(where: { $0.identifier == previousSeries.identifier })
            ?? study.series.first(where: { $0.sharesSourceSeries(with: previousSeries) })
    }

    private func updateScoutHighlights(for pane: MetalViewerPaneView) {
        scoutView.setDisplayedSeries(
            primaryIdentifier: pane.series.identifier,
            overlayIdentifier: pane.overlaySeries?.identifier
        )
    }

    private func updateToolbarStatus() {
        guard let activePaneView else {
            toolbarView.updateStatus("No active pane")
            return
        }

        let modeTitle = title(for: viewerMode)
        toolbarView.updateStatus("\(activePaneView.series.title)  •  \(modeTitle)  •  \(activePaneView.currentStateDescription)")
    }

    private func reloadWLWWMenu(for pane: MetalViewerPaneView) {
        let series = pane.activeWindowLevelSeries
        selectedWLWWTitle = series.windowLevelPresetTitle
        toolbarView.reloadWLWWMenu(selectedTitle: selectedWLWWTitle, modality: series.modality)
        reloadTransferMenus(for: pane)
    }

    private func reloadDisplayMenus(for pane: MetalViewerPaneView) {
        reloadWLWWMenu(for: pane)
    }

    private func reloadTransferMenus(for pane: MetalViewerPaneView) {
        let state = pane.activeTransferFunctionState
        toolbarView.reloadCLUTMenu(selectedTitle: state.clutName)
        toolbarView.reloadOpacityMenu(selectedTitle: state.opacityName)
    }

    private func applyViewerMode(_ mode: MetalViewerToolbarView.ViewerMode) {
        viewerMode = mode
        let displayMode = displayMode(for: mode)
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

    private func displayMode(for viewerMode: MetalViewerToolbarView.ViewerMode) -> MetalViewerDisplayMode {
        switch viewerMode {
        case .stack2D:
            return .stack2D
        case .mpr:
            return .mpr
        case .mpr3D:
            return .mpr3D
        }
    }

    private func title(for viewerMode: MetalViewerToolbarView.ViewerMode) -> String {
        switch viewerMode {
        case .stack2D:
            return NSLocalizedString("2D", comment: "")
        case .mpr:
            return NSLocalizedString("MPR", comment: "")
        case .mpr3D:
            return NSLocalizedString("3D MPR", comment: "")
        }
    }

    private func applyMouseToolAssignments(_ assignments: MetalViewerMouseToolAssignments) {
        mouseToolAssignments = assignments
        for pane in paneViews {
            pane.setMouseToolAssignments(assignments)
        }
    }

    private func setSyncScaleEnabled(_ isEnabled: Bool) {
        isSyncScaleEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Layout.syncScaleAutosaveKey)
        toolbarView.setSyncScaleEnabled(isEnabled)
        recordAllPaneScales()

        if isEnabled,
           let sourcePane = activePaneView ?? paneViews.first,
           let sourceScale = sourcePane.currentScale {
            synchronizeScale(from: sourcePane, scale: sourceScale)
        }
    }

    private func setAnnotationLevel(_ level: MetalViewerAnnotationLevel) {
        if UserDefaults.standard.integer(forKey: MetalViewerAnnotationLevel.defaultsKey) != level.rawValue {
            UserDefaults.standard.set(level.rawValue, forKey: MetalViewerAnnotationLevel.defaultsKey)
        }
        applyAnnotationLevel(level)
    }

    private func applyAnnotationLevel(_ level: MetalViewerAnnotationLevel) {
        toolbarView.selectAnnotationLevel(level)
        for pane in paneViews {
            pane.setAnnotationLevel(level)
        }
    }

    private func handlePaneScaleDidChange(_ pane: MetalViewerPaneView) {
        guard let scale = pane.currentScale else {
            lastPaneScales.removeValue(forKey: ObjectIdentifier(pane))
            return
        }

        let identifier = ObjectIdentifier(pane)
        let previousScale = lastPaneScales[identifier]
        lastPaneScales[identifier] = scale

        guard isSyncScaleEnabled,
              isApplyingSyncedScale == false,
              let previousScale,
              abs(previousScale - scale) > 0.0001 else {
            return
        }

        synchronizeScale(from: pane, scale: scale)
    }

    private func applySyncedScaleIfNeeded(to pane: MetalViewerPaneView, preferredScale: Float? = nil) {
        guard isSyncScaleEnabled else {
            recordScale(for: pane)
            return
        }

        guard let scale = preferredScale ?? synchronizedScaleValue(excluding: pane) else {
            recordScale(for: pane)
            return
        }

        isApplyingSyncedScale = true
        pane.setScale(scale)
        recordScale(for: pane)
        isApplyingSyncedScale = false
    }

    private func synchronizeScale(from sourcePane: MetalViewerPaneView, scale: Float) {
        guard isSyncScaleEnabled,
              scale.isFinite else {
            return
        }

        isApplyingSyncedScale = true
        for pane in paneViews where pane !== sourcePane {
            pane.setScale(scale)
            recordScale(for: pane)
        }
        recordScale(for: sourcePane)
        isApplyingSyncedScale = false
    }

    private func synchronizedScaleValue(excluding excludedPane: MetalViewerPaneView?) -> Float? {
        if let activePaneView,
           activePaneView !== excludedPane,
           let scale = activePaneView.currentScale {
            return scale
        }

        for pane in paneViews where pane !== excludedPane {
            if let scale = pane.currentScale {
                return scale
            }
        }

        return nil
    }

    private func recordScale(for pane: MetalViewerPaneView) {
        let identifier = ObjectIdentifier(pane)
        if let scale = pane.currentScale {
            lastPaneScales[identifier] = scale
        } else {
            lastPaneScales.removeValue(forKey: identifier)
        }
    }

    private func recordAllPaneScales() {
        lastPaneScales.removeAll()
        for pane in paneViews {
            recordScale(for: pane)
        }
    }

    private func applyWLWWCommand(_ command: MetalViewerToolbarView.WLWWCommand) {
        guard let activePaneView else { return }
        let targetSeries = activePaneView.activeWindowLevelSeries

        switch command {
        case .other:
            selectedWLWWTitle = NSLocalizedString("Other", comment: "")
            targetSeries.windowLevelPresetTitle = selectedWLWWTitle

        case .defaultWindow:
            activePaneView.applyDefaultWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Default WL & WW", comment: "")
            targetSeries.windowLevelPresetTitle = selectedWLWWTitle

        case .automatic:
            activePaneView.applyAutomaticWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Auto", comment: "")
            targetSeries.windowLevelPresetTitle = selectedWLWWTitle

        case .fullDynamic:
            activePaneView.applyFullDynamicWindowLevelPreset()
            selectedWLWWTitle = NSLocalizedString("Full dynamic", comment: "")
            targetSeries.windowLevelPresetTitle = selectedWLWWTitle

        case .preset(let name):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                confirmDeleteWLWWPreset(named: name)
                return
            }
            guard let window = wlwwPreset(named: name) else { return }
            activePaneView.applyWindowLevel(window)
            selectedWLWWTitle = name
            targetSeries.windowLevelPresetTitle = selectedWLWWTitle

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

    private func applyWLWWMenuTitle(_ title: String) {
        let command: MetalViewerToolbarView.WLWWCommand
        if title == NSLocalizedString("Other", comment: "") {
            command = .other
        } else if title == NSLocalizedString("Default WL & WW", comment: "") {
            command = .defaultWindow
        } else if title == NSLocalizedString("Auto", comment: "") {
            command = .automatic
        } else if title == NSLocalizedString("Full dynamic", comment: "") {
            command = .fullDynamic
        } else if title == NSLocalizedString("Add Current WL/WW", comment: "") {
            command = .addCurrent
        } else if title == NSLocalizedString("Set WL/WW manually", comment: "")
                    || title == NSLocalizedString("Set WL/WW Manually", comment: "") {
            command = .setManually
        } else {
            command = .preset(Self.wlwwPresetName(fromMenuTitle: title))
        }
        applyWLWWCommand(command)
    }

    private static func wlwwPresetName(fromMenuTitle title: String) -> String {
        guard let separator = title.firstIndex(of: "-") else { return title }
        let prefix = String(title[..<separator]).trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty == false, prefix.allSatisfy(\.isNumber) else { return title }
        return String(title[title.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    private func applyCLUT(named presetName: String) {
        guard let activePaneView else { return }
        activePaneView.applyCLUT(named: presetName)
        reloadTransferMenus(for: activePaneView)
        updateToolbarStatus()
    }

    private func applyOpacity(named presetName: String) {
        guard let activePaneView else { return }
        activePaneView.applyOpacity(named: presetName)
        reloadTransferMenus(for: activePaneView)
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
        let modality = activePaneView?.activeWindowLevelSeries.modality ?? "OT"
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
            activePaneView?.activeWindowLevelSeries.windowLevelPresetTitle = name
            toolbarView.reloadWLWWMenu(selectedTitle: name, modality: activePaneView?.activeWindowLevelSeries.modality ?? "OT")
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
            activePaneView?.activeWindowLevelSeries.windowLevelPresetTitle = selectedWLWWTitle
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
                modality: self?.activePaneView?.activeWindowLevelSeries.modality ?? "OT"
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

    private func printActiveImage() {
        guard let pane = activePaneView ?? paneViews.first else {
            NSSound.beep()
            return
        }
        guard pane.supportsImagePrinting else {
            presentPrintAlert(NSLocalizedString(
                "Switch the active pane to the 2D stack before printing.",
                comment: ""
            ))
            return
        }
        guard let image = pane.makePrintFrame()?.makeImage() else {
            presentPrintAlert(NSLocalizedString(
                "Horos could not render the active image for printing.",
                comment: ""
            ))
            return
        }

        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            NSSound.beep()
            return
        }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true

        let printView = MetalImagePrintView(image: image, printInfo: printInfo)
        let operation = NSPrintOperation(view: printView, printInfo: printInfo)
        operation.jobTitle = pane.series.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = true
        _ = operation.run()
    }

    private func presentPrintAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Print Image", comment: "")
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
