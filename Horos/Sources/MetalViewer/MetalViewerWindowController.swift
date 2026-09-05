import AppKit
import simd

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
    var roiRefinementHandler: (() -> Void)?

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           event.keyCode == 15,
           flags.contains([.command, .option]),
           let roiRefinementHandler {
            roiRefinementHandler()
            return true
        }
        return super.performKeyEquivalent(with: event)
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

private final class MetalViewerPatientScoutLaneView: NSView {
    let scoutView: MetalViewerScoutView
    private let titleLabel = NSTextField(labelWithString: "")
    private var titleHeightConstraint: NSLayoutConstraint!
    private var scoutTopToTitleConstraint: NSLayoutConstraint!
    private var scoutTopToLaneConstraint: NSLayoutConstraint!

    init(study: MetalViewerStudy, placement: MetalViewerScoutPlacement) {
        scoutView = MetalViewerScoutView(
            series: study.series,
            procedureEvents: study.procedureEvents,
            placement: placement
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        updateTitle(study.patientIdentity.displayName)
        titleHeightConstraint = titleLabel.heightAnchor.constraint(equalToConstant: 0)
        scoutTopToTitleConstraint = scoutView.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: 2
        )
        scoutTopToLaneConstraint = scoutView.topAnchor.constraint(equalTo: topAnchor)

        addSubview(titleLabel)
        addSubview(scoutView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            titleHeightConstraint,
            scoutView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scoutView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scoutView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setShowsTitle(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
    }

    func setShowsTitle(_ showsTitle: Bool) {
        titleLabel.isHidden = showsTitle == false
        titleHeightConstraint.constant = showsTitle ? 17 : 0
        scoutTopToLaneConstraint.isActive = showsTitle == false
        scoutTopToTitleConstraint.isActive = showsTitle
    }
}

private final class MetalViewerPatientContext {
    var study: MetalViewerStudy
    let roiStore: MetalStudyROIStore
    let roiPersistence: MetalStudyROIPersistence
    let scoutLaneView: MetalViewerPatientScoutLaneView
    var displayedROIIdentifiers = Set<UUID>()
    var knownROIIdentifiers = Set<UUID>()

    init(study: MetalViewerStudy, placement: MetalViewerScoutPlacement) {
        self.study = study
        roiPersistence = MetalStudyROIPersistence(study: study)
        roiStore = MetalStudyROIStore(
            studyInstanceUID: study.series[0].studyIdentifier,
            restoredROIs: roiPersistence.restoredROIs
        )
        scoutLaneView = MetalViewerPatientScoutLaneView(study: study, placement: placement)
        if let selectedIdentifier = roiStore.selectedROIIdentifier {
            displayedROIIdentifiers.insert(selectedIdentifier)
        }
        knownROIIdentifiers = Set(roiStore.rois.map(\.id))
    }
}

final class MetalViewerWindowController: NSWindowController, NSSplitViewDelegate {
    private static weak var roiColorPanelOwner: MetalViewerWindowController?

    private struct RegistrationFramePair: Hashable {
        let movingFrameUID: String
        let fixedFrameUID: String
    }

    private struct PendingROITransfer {
        let sourcePatientIdentifier: String
        let sourceROIIdentifier: UUID
        let sourceSeriesIdentifier: String
        let targetPatientIdentifier: String
        let targetSeriesIdentifier: String
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
        static let rightSplitViewAutosaveName = "HorosMetalViewerSplitView.Right"
        static let topSplitViewAutosaveName = "HorosMetalViewerSplitView.Top"
        static let bottomSplitViewAutosaveName = "HorosMetalViewerSplitView.Bottom"
        static let syncScaleAutosaveKey = "HorosMetalViewerSyncScale"
    }

    private let primaryPatientContext: MetalViewerPatientContext
    private var secondaryPatientContext: MetalViewerPatientContext?
    private var roiCommandPatientContext: MetalViewerPatientContext?
    private var scoutPlacement: MetalViewerScoutPlacement
    private let toolbarView = MetalViewerToolbarView(frame: .zero)
    private let scoutLaneStackView = NSStackView()
    private var scoutLaneCrossAxisConstraints: [NSLayoutConstraint] = []
    private var scoutLaneEqualSizeConstraints: [NSLayoutConstraint] = []
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
    private var roiOverlayPreferencesObserver: NSObjectProtocol?
    private var registrationTransformsByFramePair: [
        RegistrationFramePair: MetalViewerRegistrationWorldTransform
    ] = [:]
    private var pendingROITransfer: PendingROITransfer?
    private var studyROIEditingMode: MetalStudyROIEditingMode = .inactive
    private var colorPanelROIIdentifier: UUID?
    private let studyROIRefinementQueue = DispatchQueue(
        label: "org.horosproject.horos.metal-roi-refinement",
        qos: .userInitiated
    )
    private var isStudyROIRefinementInProgress = false
    private var studyROIRefinementIndicator: NSProgressIndicator?
    private var studyROIRefinementGeneration = 0
    private var pendingStudyROIPreviewWorkItem: DispatchWorkItem?
    private var isStudyROIPreviewInFlight = false

    private var patientContexts: [MetalViewerPatientContext] {
        [primaryPatientContext] + [secondaryPatientContext].compactMap { $0 }
    }

    private var allSeries: [MetalViewerSeries] {
        patientContexts.flatMap { $0.study.series }
    }

    private var activePatientContext: MetalViewerPatientContext {
        if let roiCommandPatientContext {
            return roiCommandPatientContext
        }
        if let activePaneView,
           let context = patientContext(for: activePaneView.series) {
            return context
        }
        return primaryPatientContext
    }

    private var studyROIStore: MetalStudyROIStore {
        activePatientContext.roiStore
    }

    private var displayedROIIdentifiers: Set<UUID> {
        get { activePatientContext.displayedROIIdentifiers }
        set { activePatientContext.displayedROIIdentifiers = newValue }
    }

    var canAddPatient: Bool {
        secondaryPatientContext == nil
    }

    init(study: MetalViewerStudy) {
        let initialScoutPlacement = MetalViewerScoutPlacement.saved
        let primaryPatientContext = MetalViewerPatientContext(
            study: study,
            placement: initialScoutPlacement
        )
        self.primaryPatientContext = primaryPatientContext
        self.scoutPlacement = initialScoutPlacement

        let requestedFirstSeries = study.series.first { $0.identifier == study.initialSeriesIdentifier }
        let firstSeries = (requestedFirstSeries?.isDICOMSegmentation == false ? requestedFirstSeries : nil)
            ?? study.series.first(where: { $0.isDICOMSegmentation == false })
            ?? study.series[0]
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
        contentSplitView.isVertical = initialScoutPlacement.usesVerticalTimeline
        contentSplitView.dividerStyle = .thin
        contentSplitView.autosaveName = Self.splitViewAutosaveName(for: initialScoutPlacement)
        contentSplitView.wantsLayer = true
        contentSplitView.layer?.backgroundColor = NSColor.black.cgColor

        scoutContainer.translatesAutoresizingMaskIntoConstraints = false
        scoutContainer.wantsLayer = true
        scoutContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        scoutLaneStackView.translatesAutoresizingMaskIntoConstraints = false
        scoutLaneStackView.orientation = initialScoutPlacement.usesVerticalTimeline ? .horizontal : .vertical
        scoutLaneStackView.distribution = .fillEqually
        scoutLaneStackView.alignment = initialScoutPlacement.usesVerticalTimeline ? .height : .width
        scoutLaneStackView.spacing = 2
        scoutLaneStackView.addArrangedSubview(primaryPatientContext.scoutLaneView)
        scoutContainer.addSubview(scoutLaneStackView)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.wantsLayer = true
        paneContainer.layer?.backgroundColor = NSColor.black.cgColor

        paneStackView.translatesAutoresizingMaskIntoConstraints = false
        paneStackView.orientation = .vertical
        paneStackView.distribution = .fillEqually
        paneStackView.alignment = .width
        paneStackView.spacing = 8
        paneContainer.addSubview(paneStackView)

        if initialScoutPlacement.placesScoutBeforePane {
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
            guard let self else { return }
            self.toolbarView.setMouseModifierFlags(flags)
            for pane in self.paneViews {
                pane.updateMouseToolCursor(modifierFlags: flags)
            }
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
        window.roiRefinementHandler = { [weak self] in
            self?.refineSelectedROIFromImage()
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
        toolbarView.roiCommandHandler = { [weak self] command in
            self?.applyROICommand(command)
        }
        reloadStudyROIMenu()
        configurePatientContext(primaryPatientContext)
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
        roiOverlayPreferencesObserver = NotificationCenter.default.addObserver(
            forName: MetalViewerMPRROIOverlayPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyStudyROISurfacePreferences()
        }

        var constraints = [
            toolbarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: rootView.topAnchor),

            contentSplitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentSplitView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            contentSplitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            scoutLaneStackView.leadingAnchor.constraint(equalTo: scoutContainer.leadingAnchor),
            scoutLaneStackView.trailingAnchor.constraint(equalTo: scoutContainer.trailingAnchor),
            scoutLaneStackView.topAnchor.constraint(equalTo: scoutContainer.topAnchor),
            scoutLaneStackView.bottomAnchor.constraint(equalTo: scoutContainer.bottomAnchor),

            paneStackView.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor, constant: 8),
            paneStackView.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor, constant: -8),
            paneStackView.topAnchor.constraint(equalTo: paneContainer.topAnchor, constant: 8),
            paneStackView.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor, constant: -8),
        ]
        constraints.append(initialScoutPlacement.usesVerticalTimeline ? scoutWidthConstraint : scoutHeightConstraint)
        NSLayoutConstraint.activate(constraints)
        configureScoutLaneStack(for: initialScoutPlacement)

        addPane(for: firstSeries, makeActive: true)

    }

    private func patientContext(for series: MetalViewerSeries) -> MetalViewerPatientContext? {
        patientContexts.first {
            $0.study.patientIdentity.identifier == series.patientIdentity.identifier
        }
    }

    private func patientContext(identifier: String) -> MetalViewerPatientContext? {
        patientContexts.first { $0.study.patientIdentity.identifier == identifier }
    }

    private func configurePatientContext(_ context: MetalViewerPatientContext) {
        let scout = context.scoutLaneView.scoutView
        context.roiStore.didChange = { [weak self, weak context] in
            guard let self, let context else { return }
            self.synchronizeDisplayedROIsWithStore(in: context)
            self.refreshStudyROIBindings()
            self.refreshScoutROIs(in: context)
            if self.activePatientContext === context {
                self.reloadStudyROIMenu()
            }
        }
        context.roiStore.persistenceHandler = { [weak persistence = context.roiPersistence] rois in
            persistence?.persist(rois)
        }
        context.roiPersistence.errorHandler = { [weak self, weak context] message in
            guard let self, let context else { return }
            self.toolbarView.updateStatus(
                String(
                    format: NSLocalizedString("ROI autosave failed for %@: %@", comment: ""),
                    context.study.patientIdentity.displayName,
                    message
                )
            )
        }

        scout.selectionHandler = { [weak self] series in
            guard let self else { return }
            let targetPane = self.activePaneView
                ?? self.paneViews.first(where: { $0.series.patientIdentity == series.patientIdentity })
                ?? self.paneViews.first
            guard let targetPane else { return }
            let syncedScale = self.synchronizedScaleValue(excluding: targetPane) ?? targetPane.currentScale
            targetPane.display(series: series)
            self.applySyncedScaleIfNeeded(to: targetPane, preferredScale: syncedScale)
            self.setActivePane(targetPane)
        }
        scout.openSeriesHandler = { [weak self] series in
            self?.addPane(for: series, makeActive: true)
        }
        scout.overlaySeriesHandler = { [weak self] series in
            guard let self,
                  let targetPane = self.activePaneView ?? self.paneViews.first else {
                NSSound.beep()
                return
            }
            self.assignSeries(withIdentifier: series.identifier, to: targetPane, overlay: true)
        }
        scout.roiSelectionHandler = { [weak self, weak context] identifier in
            guard let self, let context else { return }
            self.roiCommandPatientContext = context
            context.displayedROIIdentifiers.insert(identifier)
            context.roiStore.select(identifier)
        }
        scout.roiContextCommandHandler = { [weak self, weak context] identifier, command in
            guard let self, let context else { return }
            self.roiCommandPatientContext = context
            switch command {
            case .toggleMPRVisibility:
                self.toggleMPRVisibility(for: identifier)
            case .adjustPosition:
                self.beginAdjustingROIPosition(identifier, in: context)
            case .rename:
                context.roiStore.select(identifier)
                self.applyROICommand(.rename)
            case .duplicate:
                context.roiStore.select(identifier)
                self.applyROICommand(.duplicate)
            case .color:
                context.roiStore.select(identifier)
                self.applyROICommand(.color)
            case .delete:
                context.roiStore.select(identifier)
                self.applyROICommand(.delete)
            }
        }
        scout.roiRotationHandler = { [weak self] rotation in
            self?.activePaneView?.setMPRSceneRotation(rotation)
        }
        scout.roiTransferHandler = { [weak self] sourcePatientIdentifier, roiIdentifier, targetSeries in
            self?.beginROITransfer(
                sourcePatientIdentifier: sourcePatientIdentifier,
                roiIdentifier: roiIdentifier,
                targetSeries: targetSeries
            )
        }
        refreshScoutROIs(in: context)
    }

    private func refreshScoutROIs(in context: MetalViewerPatientContext) {
        context.scoutLaneView.scoutView.setROIs(
            context.roiStore.rois,
            selectedIdentifier: context.roiStore.selectedROIIdentifier,
            displayedIdentifiers: context.displayedROIIdentifiers
        )
    }

    private func beginAdjustingROIPosition(
        _ identifier: UUID,
        in context: MetalViewerPatientContext
    ) {
        guard let roi = context.roiStore.rois.first(where: { $0.id == identifier }),
              let sourceSeries = context.study.series.first(where: {
                  $0.identifier == roi.sourceSeriesIdentifier
              }) ?? context.study.series.first(where: {
                  $0.frameOfReferenceUID == roi.frameOfReferenceUID
                      && $0.isDICOMSegmentation == false
              }) else {
            NSSound.beep()
            return
        }

        context.roiStore.select(identifier)
        context.displayedROIIdentifiers.insert(identifier)
        var pane = paneViews.first(where: { $0.series.identifier == sourceSeries.identifier })
        if pane == nil {
            addPane(for: sourceSeries, makeActive: true)
            pane = activePaneView
        }
        guard let pane else {
            NSSound.beep()
            return
        }
        setActivePane(pane)
        roiCommandPatientContext = context
        viewerMode = .mpr3D
        pane.setDisplayMode(.mpr3D)
        toolbarView.selectViewerMode(.mpr3D)
        refreshStudyROIBindings()
        setStudyROIEditingMode(.translate, in: pane)
        refreshScoutROIs(in: context)
        toolbarView.updateStatus(
            NSLocalizedString(
                "Drag the ROI in any MPR plane to adjust its position. Use another plane to correct depth; press Escape when finished.",
                comment: ""
            )
        )
    }

    @discardableResult
    func addPatientStudy(
        _ study: MetalViewerStudy,
        selectInitialSeries: Bool
    ) -> Bool {
        if let existingContext = patientContext(identifier: study.patientIdentity.identifier) {
            _ = updatePatientStudy(
                study,
                selectInitialSeries: selectInitialSeries,
                revealSelectedSeriesInScout: true
            )
            return true
        }
        guard secondaryPatientContext == nil else {
            NSSound.beep()
            toolbarView.updateStatus(
                NSLocalizedString("The Metal Planar workspace currently supports two patients.", comment: "")
            )
            return false
        }

        let context = MetalViewerPatientContext(study: study, placement: scoutPlacement)
        secondaryPatientContext = context
        configurePatientContext(context)
        scoutLaneStackView.addArrangedSubview(context.scoutLaneView)
        configureScoutLaneStack(for: scoutPlacement)
        let expandedScoutDimension = clampedScoutDimension(
            max(
                currentScoutDimension * 2 + scoutLaneStackView.spacing,
                Layout.defaultScoutDimension * 2
            )
        )
        contentSplitView.setPosition(
            dividerPosition(forScoutDimension: expandedScoutDimension),
            ofDividerAt: 0
        )
        activeScoutDimensionConstraint.constant = currentScoutDimension
        updateWindowTitle()

        if selectInitialSeries,
           let series = study.series.first(where: { $0.identifier == study.initialSeriesIdentifier })
                ?? study.series.first {
            addPane(for: series, makeActive: true)
        }
        recalibrateScoutLayoutAfterPresentation()
        return true
    }

    @discardableResult
    func updatePatientStudy(
        _ study: MetalViewerStudy,
        selectInitialSeries: Bool = false,
        revealSelectedSeriesInScout: Bool = false
    ) -> Int {
        guard let context = patientContext(identifier: study.patientIdentity.identifier) else {
            return addPatientStudy(study, selectInitialSeries: selectInitialSeries) ? 1 : 0
        }
        return updateStudy(
            study,
            in: context,
            selectInitialSeries: selectInitialSeries,
            revealSelectedSeriesInScout: revealSelectedSeriesInScout
        )
    }

    private func configureScoutLaneStack(for placement: MetalViewerScoutPlacement) {
        NSLayoutConstraint.deactivate(scoutLaneCrossAxisConstraints)
        NSLayoutConstraint.deactivate(scoutLaneEqualSizeConstraints)
        scoutLaneStackView.orientation = placement.usesVerticalTimeline ? .horizontal : .vertical
        scoutLaneStackView.distribution = .fillEqually
        scoutLaneStackView.alignment = placement.usesVerticalTimeline ? .height : .width
        let resizeOrientation: NSLayoutConstraint.Orientation = placement.usesVerticalTimeline
            ? .horizontal
            : .vertical
        patientContexts.forEach {
            $0.scoutLaneView.setContentHuggingPriority(.defaultLow, for: resizeOrientation)
            $0.scoutLaneView.setContentCompressionResistancePriority(
                .defaultLow,
                for: resizeOrientation
            )
        }
        scoutLaneCrossAxisConstraints = patientContexts.map { context in
            if placement.usesVerticalTimeline {
                return context.scoutLaneView.heightAnchor.constraint(
                    equalTo: scoutLaneStackView.heightAnchor
                )
            }
            return context.scoutLaneView.widthAnchor.constraint(
                equalTo: scoutLaneStackView.widthAnchor
            )
        }
        if let firstLane = patientContexts.first?.scoutLaneView {
            scoutLaneEqualSizeConstraints = patientContexts.dropFirst().map { context in
                if placement.usesVerticalTimeline {
                    return context.scoutLaneView.widthAnchor.constraint(equalTo: firstLane.widthAnchor)
                }
                return context.scoutLaneView.heightAnchor.constraint(equalTo: firstLane.heightAnchor)
            }
        } else {
            scoutLaneEqualSizeConstraints = []
        }
        NSLayoutConstraint.activate(scoutLaneCrossAxisConstraints)
        NSLayoutConstraint.activate(scoutLaneEqualSizeConstraints)
        patientContexts.forEach {
            $0.scoutLaneView.setShowsTitle(secondaryPatientContext != nil)
            $0.scoutLaneView.scoutView.setPlacement(placement)
        }
    }

    private func updateWindowTitle() {
        window?.title = patientContexts.map { $0.study.title }.joined(separator: "  |  ")
    }

    deinit {
        patientContexts.forEach { $0.roiStore.flushPendingPersistence() }
        if Self.roiColorPanelOwner === self {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            Self.roiColorPanelOwner = nil
        }
        if let annotationDefaultsObserver {
            NotificationCenter.default.removeObserver(annotationDefaultsObserver)
        }
        if let scoutPlacementObserver {
            NotificationCenter.default.removeObserver(scoutPlacementObserver)
        }
        if let roiOverlayPreferencesObserver {
            NotificationCenter.default.removeObserver(roiOverlayPreferencesObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMinimumPosition }
        let minimumPosition = isScoutFirst
            ? minimumScoutDimension
            : minimumPaneDimension
        return max(proposedMinimumPosition, minimumPosition)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === contentSplitView, dividerIndex == 0 else { return proposedMaximumPosition }
        let trailingMinimum = isScoutFirst ? minimumPaneDimension : minimumScoutDimension
        let maximumPosition = max(
            isScoutFirst ? minimumScoutDimension : minimumPaneDimension,
            splitLength - splitView.dividerThickness - trailingMinimum
        )
        return min(proposedMaximumPosition, maximumPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as AnyObject? === contentSplitView else { return }
        activeScoutDimensionConstraint.constant = currentScoutDimension
        patientContexts.forEach { $0.scoutLaneView.scoutView.recalibrateLayoutForCurrentDimension() }
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
        patientContexts.forEach { $0.scoutLaneView.scoutView.recalibrateLayoutForCurrentDimension() }
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
            minimumScoutDimension,
            splitLength - contentSplitView.dividerThickness - minimumPaneDimension
        )
        return min(max(dimension, minimumScoutDimension), maximumDimension)
    }

    private var minimumScoutDimension: CGFloat {
        secondaryPatientContext == nil
            ? Layout.minimumScoutDimension
            : Layout.minimumScoutDimension * 2 + scoutLaneStackView.spacing
    }

    private static func savedScoutDimension(
        for placement: MetalViewerScoutPlacement,
        splitLength: CGFloat
    ) -> CGFloat {
        let defaultsKey = placement.usesVerticalTimeline
            ? Layout.scoutWidthAutosaveKey
            : Layout.scoutHeightAutosaveKey
        let savedDimension = (UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber)
            .map { CGFloat(truncating: $0) }
            ?? Layout.defaultScoutDimension
        let minimumPaneDimension = placement.usesVerticalTimeline
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
        scoutPlacement.usesVerticalTimeline
            ? contentSplitView.bounds.width
            : contentSplitView.bounds.height
    }

    private var currentScoutDimension: CGFloat {
        scoutPlacement.usesVerticalTimeline
            ? scoutContainer.frame.width
            : scoutContainer.frame.height
    }

    private var minimumPaneDimension: CGFloat {
        scoutPlacement.usesVerticalTimeline
            ? Layout.minimumPaneWidth
            : Layout.minimumPaneHeight
    }

    private var activeScoutDimensionConstraint: NSLayoutConstraint {
        scoutPlacement.usesVerticalTimeline ? scoutWidthConstraint : scoutHeightConstraint
    }

    private var scoutDimensionAutosaveKey: String {
        scoutPlacement.usesVerticalTimeline
            ? Layout.scoutWidthAutosaveKey
            : Layout.scoutHeightAutosaveKey
    }

    private func applyStudyROISurfacePreferences() {
        let opacity = MetalViewerMPRROIOverlayPreferences.opacity
        for pane in paneViews {
            pane.setStudyROISurfaceOpacity(opacity)
        }
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
        contentSplitView.isVertical = placement.usesVerticalTimeline
        contentSplitView.autosaveName = Self.splitViewAutosaveName(for: placement)
        if placement.placesScoutBeforePane {
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
        configureScoutLaneStack(for: placement)

        window?.contentView?.layoutSubtreeIfNeeded()
        contentSplitView.layoutSubtreeIfNeeded()
        restoreSavedSplitPosition()
        recalibrateScoutLayoutAfterPresentation()
    }

    private static func splitViewAutosaveName(for placement: MetalViewerScoutPlacement) -> String {
        switch placement {
        case .left:
            return Layout.leftSplitViewAutosaveName
        case .right:
            return Layout.rightSplitViewAutosaveName
        case .top:
            return Layout.topSplitViewAutosaveName
        case .bottom:
            return Layout.bottomSplitViewAutosaveName
        }
    }

    private func addPane(for series: MetalViewerSeries, makeActive: Bool) {
        guard paneViews.count < Layout.maximumPaneCount else {
            NSSound.beep()
            return
        }

        let pane = MetalViewerPaneView(series: series)
        guard let context = patientContext(for: series) else {
            NSSound.beep()
            return
        }
        pane.configureStudyROI(store: context.roiStore)
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
            guard let self, let pane else { return }
            self.refreshStudyROIBindings()
            if self.activePaneView === pane {
                self.updateScoutHighlights(for: pane)
                self.reloadStudyROIMenu()
            }
        }
        pane.overlayBlendDidChange = { [weak self, weak pane] value in
            guard let self, let pane else { return }
            self.synchronizeOverlayBlend(value, from: pane)
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
            self?.refreshStudyROIBindings()
            self?.completePendingROITransfer(
                baseSeries: baseSeries,
                overlaySeries: overlaySeries,
                transform: transform
            )
        }
        pane.studyROIEditingModeDidChange = { [weak self, weak pane] mode in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.studyROIEditingMode = mode
            self.reloadStudyROIMenu()
        }
        pane.studyROIRefinementHandler = { [weak self, weak pane] preview in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.scheduleInteractiveROIRefinement(preview: preview)
        }
        pane.mprRotationDidChange = { [weak self, weak pane] rotation in
            guard let self, let pane, self.activePaneView === pane else { return }
            self.patientContext(for: pane.series)?.scoutLaneView.scoutView.setROIRotation(rotation)
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
        refreshStudyROIBindings()
        applySyncedScaleIfNeeded(to: pane)
        recordScale(for: pane)
        rebuildPaneLayout()

        if makeActive {
            setActivePane(pane)
        }

        updateReferenceLines()
    }

    private func setActivePane(_ pane: MetalViewerPaneView) {
        if activePaneView !== pane, studyROIEditingMode != .inactive {
            setStudyROIEditingMode(.inactive, in: nil)
        }
        roiCommandPatientContext = nil
        activePaneView = pane
        for candidate in paneViews {
            candidate.isActive = (candidate === pane)
        }
        updateScoutHighlights(for: pane)
        patientContext(for: pane.series)?.scoutLaneView.scoutView.setROIRotation(pane.mprSceneRotation)
        reloadWLWWMenu(for: pane)
        reloadStudyROIMenu()
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
        guard let series = allSeries.first(where: { $0.identifier == identifier }) else {
            NSSound.beep()
            return
        }

        if overlay {
            pane.overlay(series: series)
            assignMatchingCompanionOverlays(for: pane, overlaySeries: series)
            synchronizeOverlayBlend(0.5, from: pane)
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

    private func assignMatchingCompanionOverlays(
        for sourcePane: MetalViewerPaneView,
        overlaySeries: MetalViewerSeries
    ) {
        let baseStudyIdentifier = sourcePane.series.studyIdentifier
        let overlayStudyIdentifier = overlaySeries.studyIdentifier
        guard baseStudyIdentifier != overlayStudyIdentifier else { return }

        var usedOverlaySeries = [overlaySeries]
        for pane in paneViews where pane !== sourcePane {
            guard pane.series.studyIdentifier == baseStudyIdentifier else { continue }

            if let existingOverlay = pane.overlaySeries {
                if existingOverlay.studyIdentifier == overlayStudyIdentifier {
                    usedOverlaySeries.append(existingOverlay)
                    continue
                }
            }

            guard let matchingSeries = matchingCompanionSeries(
                for: pane.series,
                inStudy: overlayStudyIdentifier,
                excluding: usedOverlaySeries
            ) else {
                continue
            }
            usedOverlaySeries.append(matchingSeries)
            pane.overlay(series: matchingSeries)
        }
    }

    private func matchingCompanionSeries(
        for baseSeries: MetalViewerSeries,
        inStudy studyIdentifier: String,
        excluding excludedSeries: [MetalViewerSeries]
    ) -> MetalViewerSeries? {
        guard let baseMetadata = baseSeries.registrationMetadata else { return nil }
        let baseModality = baseSeries.modality.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        let candidates = allSeries.filter { candidate in
            guard candidate.studyIdentifier == studyIdentifier,
                  candidate.modality.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == baseModality,
                  excludedSeries.allSatisfy({ $0.sharesSourceSeries(with: candidate) == false }),
                  let metadata = candidate.registrationMetadata,
                  metadata.orientation == baseMetadata.orientation,
                  registrationContrastsAreCompatible(metadata.contrast, baseMetadata.contrast) else {
                return false
            }
            return baseMetadata.isEligibleSupportSeries == false || metadata.isEligibleSupportSeries
        }

        return candidates.sorted { lhs, rhs in
            guard let lhsMetadata = lhs.registrationMetadata,
                  let rhsMetadata = rhs.registrationMetadata else {
                return lhs.identifier < rhs.identifier
            }
            let lhsContrastPenalty = lhsMetadata.contrast == baseMetadata.contrast ? 0 : 1
            let rhsContrastPenalty = rhsMetadata.contrast == baseMetadata.contrast ? 0 : 1
            if lhsContrastPenalty != rhsContrastPenalty {
                return lhsContrastPenalty < rhsContrastPenalty
            }
            let lhsReconstructionPenalty = lhsMetadata.reconstruction == baseMetadata.reconstruction ? 0 : 1
            let rhsReconstructionPenalty = rhsMetadata.reconstruction == baseMetadata.reconstruction ? 0 : 1
            if lhsReconstructionPenalty != rhsReconstructionPenalty {
                return lhsReconstructionPenalty < rhsReconstructionPenalty
            }
            let lhsImageCountDifference = abs(lhs.imageCount - baseSeries.imageCount)
            let rhsImageCountDifference = abs(rhs.imageCount - baseSeries.imageCount)
            if lhsImageCountDifference != rhsImageCountDifference {
                return lhsImageCountDifference < rhsImageCountDifference
            }
            if lhs.imageCount != rhs.imageCount {
                return lhs.imageCount > rhs.imageCount
            }
            return lhs.identifier < rhs.identifier
        }.first
    }

    private func registrationContrastsAreCompatible(
        _ lhs: MetalViewerRegistrationContrastGroup,
        _ rhs: MetalViewerRegistrationContrastGroup
    ) -> Bool {
        lhs == rhs
            || (lhs == .t1 && rhs == .t1PostContrast)
            || (lhs == .t1PostContrast && rhs == .t1)
    }

    private func synchronizeOverlayBlend(_ value: Double, from sourcePane: MetalViewerPaneView) {
        guard let sourceOverlaySeries = sourcePane.overlaySeries else { return }
        let baseStudyIdentifier = sourcePane.series.studyIdentifier
        let overlayStudyIdentifier = sourceOverlaySeries.studyIdentifier
        for pane in paneViews where pane !== sourcePane {
            guard pane.series.studyIdentifier == baseStudyIdentifier,
                  pane.overlaySeries?.studyIdentifier == overlayStudyIdentifier else {
                continue
            }
            pane.setOverlayBlend(value)
        }
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

    private func beginROITransfer(
        sourcePatientIdentifier: String,
        roiIdentifier: UUID,
        targetSeries: MetalViewerSeries
    ) {
        guard sourcePatientIdentifier != targetSeries.patientIdentity.identifier,
              let sourceContext = patientContext(identifier: sourcePatientIdentifier),
              let targetContext = patientContext(for: targetSeries),
              let sourceROI = sourceContext.roiStore.rois.first(where: { $0.id == roiIdentifier }),
              let sourceSeries = sourceContext.study.series.first(where: {
                  $0.identifier == sourceROI.sourceSeriesIdentifier
              }) ?? sourceContext.study.series.first(where: {
                  $0.frameOfReferenceUID == sourceROI.frameOfReferenceUID
                      && $0.isDICOMSegmentation == false
              }),
              sourceSeries.frameOfReferenceUID != nil,
              targetSeries.frameOfReferenceUID != nil else {
            NSSound.beep()
            toolbarView.updateStatus(
                NSLocalizedString("The ROI and target series do not contain enough spatial information for transfer.", comment: "")
            )
            return
        }

        pendingROITransfer = PendingROITransfer(
            sourcePatientIdentifier: sourcePatientIdentifier,
            sourceROIIdentifier: roiIdentifier,
            sourceSeriesIdentifier: sourceSeries.identifier,
            targetPatientIdentifier: targetContext.study.patientIdentity.identifier,
            targetSeriesIdentifier: targetSeries.identifier
        )
        toolbarView.updateStatus(
            String(
                format: NSLocalizedString("Registering %@ to %@ before copying ROI…", comment: ""),
                sourceContext.study.patientIdentity.displayName,
                targetContext.study.patientIdentity.displayName
            )
        )

        var targetPane = paneViews.first {
            $0.series.identifier == targetSeries.identifier
        }
        if targetPane == nil {
            addPane(for: targetSeries, makeActive: true)
            targetPane = activePaneView
        } else if let targetPane {
            setActivePane(targetPane)
        }
        guard let targetPane else {
            pendingROITransfer = nil
            NSSound.beep()
            return
        }
        if targetPane.series.identifier != targetSeries.identifier {
            targetPane.display(series: targetSeries)
        }
        targetPane.overlay(series: sourceSeries)

        if let transform = registrationTransform(
            forBaseSeries: targetSeries,
            overlaySeries: sourceSeries
        ) {
            completePendingROITransfer(
                baseSeries: targetSeries,
                overlaySeries: sourceSeries,
                transform: transform
            )
        }
    }

    private func completePendingROITransfer(
        baseSeries: MetalViewerSeries,
        overlaySeries: MetalViewerSeries,
        transform: MetalViewerRegistrationWorldTransform
    ) {
        guard let pending = pendingROITransfer,
              pending.targetSeriesIdentifier == baseSeries.identifier,
              pending.sourceSeriesIdentifier == overlaySeries.identifier else {
            return
        }
        pendingROITransfer = nil
        guard
              let sourceContext = patientContext(identifier: pending.sourcePatientIdentifier),
              let targetContext = patientContext(identifier: pending.targetPatientIdentifier),
              let sourceROI = sourceContext.roiStore.rois.first(where: {
                  $0.id == pending.sourceROIIdentifier
              }),
              let targetSeries = targetContext.study.series.first(where: {
                  $0.identifier == pending.targetSeriesIdentifier
              }),
              let targetFrameUID = targetSeries.frameOfReferenceUID,
              let transferredROI = sourceROI.transferred(
                  movingToFixedWorld: transform.movingToFixedWorld,
                  studyInstanceUID: targetSeries.studyIdentifier,
                  frameOfReferenceUID: targetFrameUID,
                  sourceSeriesIdentifier: targetSeries.identifier
              ),
              targetSeriesContainsTransferredROICenter(
                  transferredROI.center.vector,
                  series: targetSeries
              ) else {
            NSSound.beep()
            toolbarView.updateStatus(
                NSLocalizedString("ROI transfer stopped because the registered result did not land within the target image volume.", comment: "")
            )
            return
        }

        roiCommandPatientContext = targetContext
        targetContext.displayedROIIdentifiers.insert(transferredROI.id)
        targetContext.roiStore.addTransferredROI(transferredROI)
        refreshScoutROIs(in: targetContext)
        refreshStudyROIBindings()
        reloadStudyROIMenu()
        toolbarView.updateStatus(
            String(
                format: NSLocalizedString("Copied ROI to %@. Refine it on the target images before clinical use.", comment: ""),
                targetContext.study.patientIdentity.displayName
            )
        )
    }

    private func targetSeriesContainsTransferredROICenter(
        _ point: SIMD3<Double>,
        series: MetalViewerSeries
    ) -> Bool {
        let geometries = series.loadedPixList().compactMap { MetalViewerSliceGeometry(pix: $0) }
        guard let firstGeometry = geometries.first else { return false }
        let nearestGeometry = geometries.min {
            abs(simd_dot(point - $0.origin, $0.normal))
                < abs(simd_dot(point - $1.origin, $1.normal))
        } ?? firstGeometry
        let pixelPoint = nearestGeometry.slicePoint(from: point)
        let horizontalMargin = nearestGeometry.width * 0.25
        let verticalMargin = nearestGeometry.height * 0.25
        guard Double(pixelPoint.x) >= -horizontalMargin,
              Double(pixelPoint.x) <= nearestGeometry.width + horizontalMargin,
              Double(pixelPoint.y) >= -verticalMargin,
              Double(pixelPoint.y) <= nearestGeometry.height + verticalMargin else {
            return false
        }
        let signedDistances = geometries.map {
            simd_dot($0.origin - firstGeometry.origin, firstGeometry.normal)
        }
        let pointDistance = simd_dot(point - firstGeometry.origin, firstGeometry.normal)
        let minimumDistance = (signedDistances.min() ?? 0) - 20
        let maximumDistance = (signedDistances.max() ?? 0) + 20
        return pointDistance >= minimumDistance && pointDistance <= maximumDistance
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

        let supportCandidates = allSeries.filter { candidate in
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
            allSeries.filter { candidate in
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
                      registrationContrastsAreCompatible(
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
        updateStudy(
            study,
            in: primaryPatientContext,
            selectInitialSeries: selectInitialSeries,
            revealSelectedSeriesInScout: revealSelectedSeriesInScout
        )
    }

    private func updateStudy(
        _ study: MetalViewerStudy,
        in context: MetalViewerPatientContext,
        selectInitialSeries: Bool,
        revealSelectedSeriesInScout: Bool
    ) -> Int {
        for series in study.series {
            let previousSeries = context.study.series.first(where: { $0.identifier == series.identifier })
                ?? context.study.series.first(where: { $0.sharesSourceSeries(with: series) })
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
        context.study = study
        context.scoutLaneView.updateTitle(study.patientIdentity.displayName)
        let contextScout = context.scoutLaneView.scoutView
        contextScout.reload(
            series: study.series,
            procedureEvents: study.procedureEvents,
            loadThumbnailsImmediately: false
        )
        context.roiStore.mergeRestoredROIs(context.roiPersistence.updateStudy(study))
        refreshScoutROIs(in: context)
        updateWindowTitle()
        let selectedSeries = selectInitialSeries
            ? study.series.first(where: { $0.identifier == study.initialSeriesIdentifier })
            : activePaneView.flatMap {
                $0.series.patientIdentity == study.patientIdentity
                    ? matchingSeries(for: $0.series, in: study)
                    : nil
            }
        let selectedIdentifier = selectedSeries?.identifier ?? study.initialSeriesIdentifier
        let selectedOverlayIdentifier = selectInitialSeries
            ? nil
            : activePaneView?.overlaySeries.flatMap {
                $0.patientIdentity == study.patientIdentity
                    ? matchingSeries(for: $0, in: study)
                    : nil
            }?.identifier
        contextScout.setDisplayedSeries(
            primaryIdentifier: selectedIdentifier,
            overlayIdentifier: selectedOverlayIdentifier,
            scrollToVisible: revealSelectedSeriesInScout
        )

        var refreshedPaneCount = 0
        for pane in paneViews {
            let baseBelongsToContext = pane.series.patientIdentity == study.patientIdentity
            let overlayBelongsToContext = pane.overlaySeries?.patientIdentity == study.patientIdentity
            guard baseBelongsToContext || overlayBelongsToContext else { continue }
            let updatedSeries = baseBelongsToContext
                ? (matchingSeries(for: pane.series, in: study) ?? pane.series)
                : pane.series
            let syncedScale = synchronizedScaleValue(excluding: pane) ?? pane.currentScale
            let updatedOverlaySeries = pane.overlaySeries.flatMap { overlaySeries in
                overlayBelongsToContext
                    ? (matchingSeries(for: overlaySeries, in: study) ?? overlaySeries)
                    : overlaySeries
            }
            if pane.refreshAfterDatabaseUpdate(series: updatedSeries, overlaySeries: updatedOverlaySeries) {
                applySyncedScaleIfNeeded(to: pane, preferredScale: syncedScale)
                refreshedPaneCount += 1
            }
        }

        if selectInitialSeries,
           let selectedSeries = study.series.first(where: { $0.identifier == study.initialSeriesIdentifier }),
           let targetPane = paneViews.first(where: {
               $0.series.patientIdentity == study.patientIdentity
           }) ?? activePaneView ?? paneViews.first {
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
        for context in patientContexts {
            let primaryIdentifier = pane.series.patientIdentity == context.study.patientIdentity
                ? pane.series.identifier
                : nil
            let overlayIdentifier = pane.overlaySeries?.patientIdentity == context.study.patientIdentity
                ? pane.overlaySeries?.identifier
                : nil
            context.scoutLaneView.scoutView.setDisplayedSeries(
                primaryIdentifier: primaryIdentifier,
                overlayIdentifier: overlayIdentifier
            )
        }
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

    private func reloadStudyROIMenu() {
        toolbarView.reloadROIMenu(
            store: studyROIStore,
            editingMode: studyROIEditingMode,
            canCreateSEGFromLegacyBrush: activePaneView?.hasLegacyBrushROI ?? false
        )
    }

    private func applyROICommand(_ command: MetalViewerToolbarView.ROICommand) {
        switch command {
        case let .select(identifier):
            setStudyROIEditingMode(.inactive, in: nil)
            displayedROIIdentifiers.insert(identifier)
            studyROIStore.select(identifier)
        case .newSphere:
            guard let activePaneView else {
                NSSound.beep()
                return
            }
            viewerMode = .mpr3D
            activePaneView.setDisplayMode(.mpr3D)
            activePaneView.configureStudyROI(
                store: studyROIStore,
                currentToCanonicalTransform: matrix_identity_float4x4
            )
            toolbarView.selectViewerMode(.mpr3D)
            setStudyROIEditingMode(.createSphere, in: activePaneView)
        case .createSEGFromLegacyBrush:
            createSEGFromLegacyBrushROI()
        case .addAnchor:
            guard studyROIStore.selectedROI != nil,
                  let activePaneView else {
                NSSound.beep()
                return
            }
            guard canProjectSelectedROI(into: activePaneView.series) else {
                NSSound.beep()
                toolbarView.updateStatus(
                    NSLocalizedString("Register this series to the ROI source series before adding anchors.", comment: "")
                )
                return
            }
            viewerMode = .mpr3D
            activePaneView.setDisplayMode(.mpr3D)
            toolbarView.selectViewerMode(.mpr3D)
            setStudyROIEditingMode(.inactive, in: nil)
            toolbarView.assignMouseToolToSelectedButton(.roiAnchor)
        case .deleteAnchor:
            guard studyROIStore.selectedROI?.anchors.isEmpty == false,
                  let activePaneView else {
                NSSound.beep()
                return
            }
            guard canProjectSelectedROI(into: activePaneView.series) else {
                NSSound.beep()
                toolbarView.updateStatus(
                    NSLocalizedString("Register this series to the ROI source series before deleting anchors.", comment: "")
                )
                return
            }
            viewerMode = .mpr3D
            activePaneView.setDisplayMode(.mpr3D)
            toolbarView.selectViewerMode(.mpr3D)
            setStudyROIEditingMode(.inactive, in: nil)
            toolbarView.assignMouseToolToSelectedButton(.deleteROIAnchor)
        case .refineFromImage:
            refineSelectedROIFromImage()
        case .finishEditing:
            studyROIStore.cancelProvisionalSphere()
            setStudyROIEditingMode(.inactive, in: nil)
        case .duplicate:
            setStudyROIEditingMode(.inactive, in: nil)
            if studyROIStore.duplicateSelectedROI() == nil {
                NSSound.beep()
            }
        case .rename:
            renameSelectedROI()
        case .color:
            showSelectedROIColorPanel()
        case .delete:
            deleteSelectedROI()
        case .undo:
            studyROIStore.undo()
        case .redo:
            studyROIStore.redo()
        }
        reloadStudyROIMenu()
        updateToolbarStatus()
    }

    private func setStudyROIEditingMode(_ mode: MetalStudyROIEditingMode, in editingPane: MetalViewerPaneView?) {
        studyROIEditingMode = mode
        for pane in paneViews {
            pane.setStudyROIEditingMode(pane === editingPane ? mode : .inactive)
        }
        reloadStudyROIMenu()
    }

    private func refreshStudyROIBindings() {
        for pane in paneViews {
            guard let context = patientContext(for: pane.series) else { continue }
            let displayedROIs = context.roiStore.rois.filter {
                context.displayedROIIdentifiers.contains($0.id)
            }
            let selectedTransform = context.roiStore.selectedROI.flatMap {
                currentToCanonicalTransform(for: $0, displayedIn: pane.series)
            }
            pane.configureStudyROI(
                store: context.roiStore,
                currentToCanonicalTransform: context.roiStore.selectedROI == nil
                    ? matrix_identity_float4x4
                    : selectedTransform
            )
            let projections = displayedROIs.compactMap { roi -> MetalStudyROISurfaceProjection? in
                guard let transform = currentToCanonicalTransform(for: roi, displayedIn: pane.series) else {
                    return nil
                }
                return MetalStudyROISurfaceProjection(
                    roi: roi,
                    currentToCanonicalTransform: transform
                )
            }
            pane.setStudyROISurfaces(projections)
            pane.refreshStudyROIOverlay()
        }
    }

    private func synchronizeDisplayedROIsWithStore(in context: MetalViewerPatientContext) {
        let validIdentifiers = Set(context.roiStore.rois.map(\.id))
        context.displayedROIIdentifiers.formIntersection(validIdentifiers)
        context.displayedROIIdentifiers.formUnion(
            validIdentifiers.subtracting(context.knownROIIdentifiers)
        )
        context.knownROIIdentifiers = validIdentifiers
    }

    private func toggleMPRVisibility(for identifier: UUID) {
        if displayedROIIdentifiers.remove(identifier) == nil {
            displayedROIIdentifiers.insert(identifier)
        }
        refreshStudyROIBindings()
        refreshScoutROIs(in: activePatientContext)
    }

    private func canProjectSelectedROI(into series: MetalViewerSeries) -> Bool {
        guard let roi = studyROIStore.selectedROI else { return true }
        return currentToCanonicalTransform(for: roi, displayedIn: series) != nil
    }

    private func selectedROICurrentToCanonicalTransform(
        for series: MetalViewerSeries
    ) -> simd_float4x4? {
        guard let roi = studyROIStore.selectedROI else { return matrix_identity_float4x4 }
        return currentToCanonicalTransform(for: roi, displayedIn: series)
    }

    private func currentToCanonicalTransform(
        for roi: MetalStudyROI,
        displayedIn series: MetalViewerSeries
    ) -> simd_float4x4? {
        let roiContext = patientContexts.first {
            $0.roiStore.rois.contains(where: { $0.id == roi.id })
        } ?? patientContext(for: series)
        guard let canonicalSeries = roiContext?.study.series.first(where: {
                  $0.isDICOMSegmentation == false
                      && $0.identifier == roi.sourceSeriesIdentifier
              })
                ?? roiContext?.study.series.first(where: {
                    $0.isDICOMSegmentation == false
                        && $0.frameOfReferenceUID == roi.frameOfReferenceUID
                }) else {
            return matrix_identity_float4x4
        }
        if series.identifier == canonicalSeries.identifier
            || series.frameOfReferenceUID == canonicalSeries.frameOfReferenceUID {
            return matrix_identity_float4x4
        }
        guard series.frameOfReferenceUID != nil,
              canonicalSeries.frameOfReferenceUID != nil else { return nil }
        return registrationTransform(
            forBaseSeries: canonicalSeries,
            overlaySeries: series
        )?.movingToFixedWorld
    }

    private func showSelectedROIColorPanel() {
        guard let roi = studyROIStore.selectedROI else {
            NSSound.beep()
            return
        }
        colorPanelROIIdentifier = roi.id
        let panel = NSColorPanel.shared
        panel.title = String(
            format: NSLocalizedString("ROI Color — %@", comment: ""),
            roi.name
        )
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = roi.color
        panel.setTarget(self)
        panel.setAction(#selector(roiColorPanelDidChange(_:)))
        Self.roiColorPanelOwner = self
        panel.orderFront(nil)
    }

    @objc
    private func roiColorPanelDidChange(_ sender: NSColorPanel) {
        guard let identifier = colorPanelROIIdentifier else { return }
        studyROIStore.setColor(sender.color, for: identifier)
    }

    private func refineSelectedROIFromImage() {
        pendingStudyROIPreviewWorkItem?.cancel()
        pendingStudyROIPreviewWorkItem = nil
        enqueueROIRefinement(preview: false, interaction: false, showsFeedback: true)
    }

    private func createSEGFromLegacyBrushROI() {
        guard isStudyROIRefinementInProgress == false,
              let sourcePane = activePaneView,
              let request = sourcePane.legacyBrushSegmentationRequest() else {
            NSSound.beep()
            return
        }

        pendingStudyROIPreviewWorkItem?.cancel()
        pendingStudyROIPreviewWorkItem = nil
        studyROIStore.cancelProvisionalSphere()
        setStudyROIEditingMode(.inactive, in: nil)
        isStudyROIRefinementInProgress = true
        setStudyROIRefinementIndicatorVisible(true)
        studyROIRefinementGeneration &+= 1
        let generation = studyROIRefinementGeneration
        let sourceSeriesIdentifier = sourcePane.series.identifier
        let sourceStudyIdentifier = sourcePane.series.studyIdentifier
        let frameOfReferenceUID = sourcePane.series.frameOfReferenceUID ?? sourceSeriesIdentifier

        studyROIRefinementQueue.async { [weak self, weak sourcePane] in
            let result = request.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStudyROIRefinementInProgress = false
                self.setStudyROIRefinementIndicatorVisible(false)
                guard generation == self.studyROIRefinementGeneration else { return }
                guard let result else {
                    self.presentROIRefinementMessage(
                        title: NSLocalizedString("Legacy ROI Could Not Be Converted", comment: ""),
                        detail: NSLocalizedString(
                            "The legacy brush mask did not contain enough valid image geometry to create a DICOM SEG.",
                            comment: ""
                        )
                    )
                    return
                }

                let color = NSColor(
                    deviceRed: CGFloat(result.colorRed),
                    green: CGFloat(result.colorGreen),
                    blue: CGFloat(result.colorBlue),
                    alpha: 1
                )
                guard self.studyROIStore.createImageSeededROI(
                    name: result.name,
                    studyInstanceUID: sourceStudyIdentifier,
                    frameOfReferenceUID: frameOfReferenceUID,
                    sourceSeriesIdentifier: sourceSeriesIdentifier,
                    color: color,
                    center: result.center,
                    radiusMM: result.radiusMM,
                    voxelField: result.voxelField
                ) != nil else {
                    self.presentROIRefinementMessage(
                        title: NSLocalizedString("Legacy ROI Could Not Be Converted", comment: ""),
                        detail: NSLocalizedString("The generated segmentation field was invalid.", comment: "")
                    )
                    return
                }

                if let sourcePane,
                   self.paneViews.contains(where: { $0 === sourcePane }),
                   self.activePaneView === sourcePane {
                    self.viewerMode = .mpr3D
                    sourcePane.setDisplayMode(.mpr3D)
                    self.toolbarView.selectViewerMode(.mpr3D)
                }
                self.refreshStudyROIBindings()
                self.reloadStudyROIMenu()
                self.updateToolbarStatus()
            }
        }
    }

    private func scheduleInteractiveROIRefinement(preview: Bool) {
        if preview {
            guard pendingStudyROIPreviewWorkItem == nil,
                  isStudyROIPreviewInFlight == false else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingStudyROIPreviewWorkItem = nil
                self?.enqueueROIRefinement(
                    preview: true,
                    interaction: true,
                    showsFeedback: false
                )
            }
            pendingStudyROIPreviewWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: workItem)
        } else {
            pendingStudyROIPreviewWorkItem?.cancel()
            pendingStudyROIPreviewWorkItem = nil
            enqueueROIRefinement(
                preview: false,
                interaction: true,
                showsFeedback: false
            )
        }
    }

    private func enqueueROIRefinement(
        preview: Bool,
        interaction: Bool,
        showsFeedback: Bool
    ) {
        guard let storedROI = studyROIStore.selectedROI,
              let activePaneView else {
            if showsFeedback { NSSound.beep() }
            return
        }
        // External DICOM SEGs contain a precise voxel mask but no Horos authoring
        // landmarks. Give the refinement request a movable boundary scaffold
        // without mutating the stored ROI unless a successful result is applied.
        let preservesEstablishedBoundary = storedROI.voxelField?.isValid == true
            && (storedROI.automaticAnchorCount > 0 || storedROI.manualAnchorCount > 0)
        var roi = storedROI
        roi.seedAutomaticBoundaryScaffoldIfNeeded()
        if showsFeedback, isStudyROIRefinementInProgress {
            NSSound.beep()
            return
        }

        let targetSeries = activePaneView.activeWindowLevelSeries
        guard let currentToCanonical = selectedROICurrentToCanonicalTransform(for: targetSeries) else {
            if showsFeedback {
                NSSound.beep()
                presentROIRefinementMessage(
                    title: NSLocalizedString("Register This Series First", comment: ""),
                    detail: NSLocalizedString(
                        "The displayed series must be registered to the ROI source series before it can refine the ROI.",
                        comment: ""
                    )
                )
            }
            return
        }

        if showsFeedback {
            setStudyROIEditingMode(.inactive, in: nil)
            isStudyROIRefinementInProgress = true
            setStudyROIRefinementIndicatorVisible(true)
        }
        if preview { isStudyROIPreviewInFlight = true }
        studyROIRefinementGeneration &+= 1
        let generation = studyROIRefinementGeneration
        let request = MetalStudyROIRefinementRequest(
            roi: roi,
            pixList: targetSeries.loadedPixList(),
            canonicalToSeriesWorld: simd_inverse(currentToCanonical),
            preservesEstablishedBoundary: preservesEstablishedBoundary
        )
        studyROIRefinementQueue.async { [weak self] in
            let result = request.run(
                preview: preview,
                reusePreparedConstraints: interaction
            )
            let failureDetail = request.failureDetail
            DispatchQueue.main.async {
                guard let self else { return }
                if showsFeedback {
                    self.isStudyROIRefinementInProgress = false
                    self.setStudyROIRefinementIndicatorVisible(false)
                }
                if preview { self.isStudyROIPreviewInFlight = false }
                guard generation == self.studyROIRefinementGeneration else { return }
                guard let result else {
                    if showsFeedback {
                        self.presentROIRefinementMessage(
                            title: NSLocalizedString("ROI Refinement Could Not Be Completed", comment: ""),
                            detail: failureDetail ?? NSLocalizedString(
                                "The refinement could not produce a reliable result for the current ROI.",
                                comment: ""
                            )
                        )
                    }
                    return
                }
                guard self.studyROIStore.rois.first(where: { $0.id == storedROI.id }) == storedROI else {
                    if showsFeedback {
                        self.presentROIRefinementMessage(
                            title: NSLocalizedString("ROI Changed During Refinement", comment: ""),
                            detail: NSLocalizedString(
                                "The refinement result was not applied because the ROI was edited while the image was being analyzed.",
                                comment: ""
                            )
                        )
                    }
                    return
                }
                if preview {
                    self.studyROIStore.applyInteractiveImageRefinement(
                        result.automaticAnchors,
                        voxelField: result.voxelField,
                        to: result.roiIdentifier
                    )
                } else if interaction {
                    self.studyROIStore.applyAutomaticImageRefinement(
                        result.automaticAnchors,
                        voxelField: result.voxelField,
                        measuredVolumeMM3: result.volumeMM3,
                        to: result.roiIdentifier
                    )
                } else {
                    self.studyROIStore.applyImageRefinement(
                        result.automaticAnchors,
                        voxelField: result.voxelField,
                        measuredVolumeMM3: result.volumeMM3,
                        to: result.roiIdentifier
                    )
                }
            }
        }
    }

    private func setStudyROIRefinementIndicatorVisible(_ isVisible: Bool) {
        if isVisible {
            guard studyROIRefinementIndicator == nil else { return }
            let indicator = NSProgressIndicator()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.style = .spinning
            indicator.controlSize = .large
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
            paneContainer.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: paneContainer.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: paneContainer.centerYAnchor),
            ])
            studyROIRefinementIndicator = indicator
        } else {
            studyROIRefinementIndicator?.stopAnimation(nil)
            studyROIRefinementIndicator?.removeFromSuperview()
            studyROIRefinementIndicator = nil
        }
    }

    private func presentROIRefinementMessage(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func renameSelectedROI() {
        guard let selectedROI = studyROIStore.selectedROI else {
            NSSound.beep()
            return
        }
        let field = NSTextField(string: selectedROI.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename 3D ROI", comment: "")
        alert.informativeText = NSLocalizedString("The name is stored with the study segmentation.", comment: "")
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        window?.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        studyROIStore.renameSelectedROI(to: field.stringValue)
    }

    private func deleteSelectedROI() {
        guard let selectedROI = studyROIStore.selectedROI else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Delete “%@”?", comment: ""), selectedROI.name)
        alert.informativeText = NSLocalizedString("This removes the segmentation from the study. You can undo this while the viewer remains open.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        studyROIStore.deleteSelectedROI()
        setStudyROIEditingMode(.inactive, in: nil)
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
        reloadStudyROIMenu()
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
