import AppKit
import CoreData

final class Metal3DViewerWindowController: NSWindowController, NSWindowDelegate {
    private let volumeView = Metal3DVolumeView(frame: .zero)
    private let toolbarController = Metal3DViewerToolbarController()
    private let histogramPanelController = Metal3DHistogramPanelController()
    private let pixList: [DCMPix]
    private let volumeData: Data
    private var tumorSegmentationTask: Metal3DLocalTumorSegmentationTask?
    private var latestTumorSegmentationSummary: String?
    private var latestTumorSeriesFetchSummary: String?

    init(pixList: [DCMPix], volumeData: Data, title: String) {
        self.pixList = pixList
        self.volumeData = volumeData

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: title)
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        configureWindow()
        configureToolbar()
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentWindowOnViewerScreen() {
        MetalViewerScreenPlacement.applyPresentationFrame(to: window, display: false)
        showWindow(NSApp)
        window?.makeKeyAndOrderFront(NSApp)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow() {
        guard let window else { return }
        window.delegate = self
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
    }

    private func configureToolbar() {
        let wlwwDictionary = UserDefaults.standard.dictionary(forKey: "WLWW3") ?? [:]
        let clutDictionary = UserDefaults.standard.dictionary(forKey: "CLUT") ?? [:]
        let opacityDictionary = UserDefaults.standard.dictionary(forKey: "OPACITY") ?? [:]
        let wlwwNames = Array(wlwwDictionary.keys).sorted()
        let clutNames = Array(clutDictionary.keys)
            .filter { $0 != NSLocalizedString("No CLUT", comment: "") }
            .sorted()
        let opacityNames = Array(opacityDictionary.keys)
            .filter { $0 != NSLocalizedString("Linear Table", comment: "") }
            .sorted()

        toolbarController.configure(wlwwPresetNames: wlwwNames, clutNames: clutNames, opacityNames: opacityNames)
        toolbarController.cropHandler = { [weak self] isEnabled in
            self?.volumeView.cropEnabled = isEnabled
        }
        toolbarController.shadingHandler = { [weak self] isEnabled in
            self?.volumeView.shadingEnabled = isEnabled
        }
        toolbarController.skinHandler = { [weak self] isEnabled in
            self?.volumeView.showSkin = isEnabled
        }
        toolbarController.skinSurfaceHandler = { [weak self] isEnabled in
            self?.volumeView.showSkinSurface = isEnabled
        }
        toolbarController.skinClipDepthHandler = { [weak self] depthMM in
            self?.volumeView.skinClipDepthMM = depthMM
        }
        toolbarController.tumorSegmentationHandler = { [weak self] in
            self?.runTumorSegmentation()
        }
        toolbarController.tumorVisibilityHandler = { [weak self] isVisible in
            self?.volumeView.showTumorSegmentation = isVisible
        }
        toolbarController.tumorLabelFilterHandler = { [weak self] label in
            self?.volumeView.setTumorLabelFilter(label)
        }
        toolbarController.tumorInfoHandler = { [weak self] in
            self?.showTumorSegmentationInfo()
        }
        toolbarController.tumorClearHandler = { [weak self] in
            self?.volumeView.clearTumorSegmentation()
            self?.volumeView.setTumorLabelFilter(nil)
            self?.toolbarController.selectAllTumorLabels()
            self?.toolbarController.setSurgicalTrajectoryAvailable(false)
            self?.latestTumorSegmentationSummary = nil
            self?.latestTumorSeriesFetchSummary = nil
        }
        toolbarController.surgicalTrajectoryHandler = { [weak self] in
            self?.showInitialSurgicalTrajectory()
        }
        toolbarController.histogramHandler = { [weak self] in
            self?.toggleHistogramPanel()
        }
        histogramPanelController.opacityPointsChanged = { [weak self] points in
            self?.volumeView.setOpacityControlPoints(points)
        }
        toolbarController.wlwwSelectionHandler = { [weak self] selectedTitle in
            guard let self else { return }
            if let actualSelection = self.volumeView.applyWLPreset(named: selectedTitle) {
                self.toolbarController.selectWLPreset(named: actualSelection)
            }
        }
        toolbarController.clutSelectionHandler = { [weak self] selectedTitle in
            guard let self else { return }
            if let actualSelection = self.volumeView.applyCLUT(named: selectedTitle) {
                self.toolbarController.selectCLUT(named: actualSelection)
            }
        }
        toolbarController.opacitySelectionHandler = { [weak self] selectedTitle in
            guard let self else { return }
            if let actualSelection = self.volumeView.applyOpacity(named: selectedTitle) {
                self.toolbarController.selectOpacity(named: actualSelection)
            }
        }
        volumeView.wlwwInteractionHandler = { [weak self] selectedTitle in
            self?.toolbarController.selectWLPreset(named: selectedTitle)
        }

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("HorosMetal3DToolbar"))
        toolbar.delegate = toolbarController
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar

        let skinIdentifier = Metal3DViewerToolbarController.ItemIdentifier.skin
        if toolbar.items.contains(where: { $0.itemIdentifier == skinIdentifier }) == false {
            toolbar.insertItem(withItemIdentifier: skinIdentifier, at: min(2, toolbar.items.count))
        }
        let skinSurfaceIdentifier = Metal3DViewerToolbarController.ItemIdentifier.skinSurface
        if toolbar.items.contains(where: { $0.itemIdentifier == skinSurfaceIdentifier }) == false {
            let skinIndex = toolbar.items.firstIndex { $0.itemIdentifier == skinIdentifier }
            toolbar.insertItem(withItemIdentifier: skinSurfaceIdentifier, at: min((skinIndex ?? 2) + 1, toolbar.items.count))
        }
        let skinDepthIdentifier = Metal3DViewerToolbarController.ItemIdentifier.skinDepth
        if toolbar.items.contains(where: { $0.itemIdentifier == skinDepthIdentifier }) == false {
            let skinSurfaceIndex = toolbar.items.firstIndex { $0.itemIdentifier == skinSurfaceIdentifier }
            toolbar.insertItem(withItemIdentifier: skinDepthIdentifier, at: min((skinSurfaceIndex ?? 3) + 1, toolbar.items.count))
        }
        let tumorIdentifier = Metal3DViewerToolbarController.ItemIdentifier.tumorSegmentation
        if toolbar.items.contains(where: { $0.itemIdentifier == tumorIdentifier }) == false {
            let skinDepthIndex = toolbar.items.firstIndex { $0.itemIdentifier == skinDepthIdentifier }
            toolbar.insertItem(withItemIdentifier: tumorIdentifier, at: min((skinDepthIndex ?? 4) + 1, toolbar.items.count))
        }
        let tumorVisibilityIdentifier = Metal3DViewerToolbarController.ItemIdentifier.tumorVisibility
        if toolbar.items.contains(where: { $0.itemIdentifier == tumorVisibilityIdentifier }) == false {
            let tumorIndex = toolbar.items.firstIndex { $0.itemIdentifier == tumorIdentifier }
            toolbar.insertItem(withItemIdentifier: tumorVisibilityIdentifier, at: min((tumorIndex ?? 5) + 1, toolbar.items.count))
        }
        let tumorLabelIdentifier = Metal3DViewerToolbarController.ItemIdentifier.tumorLabel
        if toolbar.items.contains(where: { $0.itemIdentifier == tumorLabelIdentifier }) == false {
            let tumorVisibilityIndex = toolbar.items.firstIndex { $0.itemIdentifier == tumorVisibilityIdentifier }
            toolbar.insertItem(withItemIdentifier: tumorLabelIdentifier, at: min((tumorVisibilityIndex ?? 6) + 1, toolbar.items.count))
        }
        let tumorInfoIdentifier = Metal3DViewerToolbarController.ItemIdentifier.tumorInfo
        if toolbar.items.contains(where: { $0.itemIdentifier == tumorInfoIdentifier }) == false {
            let tumorLabelIndex = toolbar.items.firstIndex { $0.itemIdentifier == tumorLabelIdentifier }
            toolbar.insertItem(withItemIdentifier: tumorInfoIdentifier, at: min((tumorLabelIndex ?? 7) + 1, toolbar.items.count))
        }
        let tumorClearIdentifier = Metal3DViewerToolbarController.ItemIdentifier.tumorClear
        if toolbar.items.contains(where: { $0.itemIdentifier == tumorClearIdentifier }) == false {
            let tumorInfoIndex = toolbar.items.firstIndex { $0.itemIdentifier == tumorInfoIdentifier }
            toolbar.insertItem(withItemIdentifier: tumorClearIdentifier, at: min((tumorInfoIndex ?? 8) + 1, toolbar.items.count))
        }
        let surgicalTrajectoryIdentifier = Metal3DViewerToolbarController.ItemIdentifier.surgicalTrajectory
        if toolbar.items.contains(where: { $0.itemIdentifier == surgicalTrajectoryIdentifier }) == false {
            let tumorClearIndex = toolbar.items.firstIndex { $0.itemIdentifier == tumorClearIdentifier }
            toolbar.insertItem(withItemIdentifier: surgicalTrajectoryIdentifier, at: min((tumorClearIndex ?? 9) + 1, toolbar.items.count))
        }
    }

    private func configureContent() {
        guard let window else { return }

        let rootView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor
        rootView.addSubview(volumeView)
        window.contentView = rootView

        NSLayoutConstraint.activate([
            volumeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            volumeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            volumeView.topAnchor.constraint(equalTo: rootView.topAnchor),
            volumeView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        volumeView.configure(pixList: pixList, volumeData: volumeData)
        if let selectedWLPresetName = volumeView.selectedWLPresetName {
            toolbarController.selectWLPreset(named: selectedWLPresetName)
        }
        if let selectedCLUTName = volumeView.selectedCLUTName {
            toolbarController.selectCLUT(named: selectedCLUTName)
        }
        if let selectedOpacityName = volumeView.selectedOpacityName {
            toolbarController.selectOpacity(named: selectedOpacityName)
        }
        toolbarController.setSkinClipDepthMM(volumeView.skinClipDepthMM)
        histogramPanelController.update(
            histogram: volumeView.makeHistogramModel(),
            opacityPoints: volumeView.opacityControlPoints()
        )
    }

    private func toggleHistogramPanel() {
        histogramPanelController.update(
            histogram: volumeView.makeHistogramModel(),
            opacityPoints: volumeView.opacityControlPoints()
        )
        guard let panel = histogramPanelController.window else { return }

        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        if let window {
            let origin = NSPoint(x: window.frame.maxX + 14, y: window.frame.maxY - panel.frame.height - 40)
            panel.setFrameOrigin(origin)
        }
        histogramPanelController.showWindow(self)
        panel.orderFrontRegardless()
    }

    private func runTumorSegmentation() {
        guard tumorSegmentationTask == nil else {
            showTumorSegmentationAlert(
                message: NSLocalizedString("Tumour segmentation is already running.", comment: ""),
                informativeText: NSLocalizedString("Wait for the current local helper process to finish, or close this viewer to cancel it.", comment: "")
            )
            return
        }
        guard let segmentationInput = volumeView.segmentationInput() else {
            NSSound.beep()
            return
        }

        let launchWithHelper: (URL) -> Void = { [weak self] helperURL in
            self?.selectLocalTumorSeriesThenStartSegmentation(helperURL: helperURL, input: segmentationInput)
        }

        if let helperURL = Metal3DLocalTumorSegmentationTask.configuredHelperURL() {
            launchWithHelper(helperURL)
            return
        }

        chooseTumorSegmentationHelper(completion: launchWithHelper)
    }

    private func selectLocalTumorSeriesThenStartSegmentation(helperURL: URL, input: Metal3DSegmentationInput) {
        let series = currentLocalSeriesSummaries()
        guard series.isEmpty == false else {
            latestTumorSeriesFetchSummary = NSLocalizedString("No local study series were available to pass to the segmenter.", comment: "")
            startTumorSegmentation(helperURL: helperURL, input: input, selectedDICOMSeries: [])
            return
        }

        presentTumorSeriesSelection(series: series, helperURL: helperURL, input: input)
    }

    private func presentTumorSeriesSelection(
        series: [[AnyHashable: Any]],
        helperURL: URL,
        input: Metal3DSegmentationInput
    ) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Select series for tumour segmentation", comment: "")
        alert.informativeText = NSLocalizedString("Choose which local DICOM series to pass to the local segmenter.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Use Selected", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Skip", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        var controls = [(button: NSButton, series: [AnyHashable: Any])]()
        for summary in series {
            let button = NSButton(checkboxWithTitle: Self.tumorSeriesSelectionTitle(summary), target: nil, action: nil)
            button.state = .on
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = Self.tumorSeriesSelectionTooltip(summary)
            stack.addArrangedSubview(button)
            controls.append((button, summary))
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: max(32, controls.count * 26)))
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
        ])
        scrollView.documentView = documentView
        alert.accessoryView = scrollView

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let selected = controls
                    .filter { $0.button.state == .on }
                    .map { $0.series }
                self.startSegmentationWithSelectedLocalSeries(selected, helperURL: helperURL, input: input)

            case .alertSecondButtonReturn:
                self.latestTumorSeriesFetchSummary = NSLocalizedString("No local study series were passed to the segmenter.", comment: "")
                self.startTumorSegmentation(helperURL: helperURL, input: input, selectedDICOMSeries: [])

            default:
                break
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func startSegmentationWithSelectedLocalSeries(
        _ selectedSeries: [[AnyHashable: Any]],
        helperURL: URL,
        input: Metal3DSegmentationInput
    ) {
        guard selectedSeries.isEmpty == false else {
            latestTumorSeriesFetchSummary = NSLocalizedString("No local study series were selected.", comment: "")
            startTumorSegmentation(helperURL: helperURL, input: input, selectedDICOMSeries: [])
            return
        }

        let selectedPayload = selectedSeries.map(Self.jsonSafeDictionary)
        latestTumorSeriesFetchSummary = String(
            format: NSLocalizedString("Passing %ld selected local study series to the segmenter.", comment: ""),
            selectedPayload.count
        )
        startTumorSegmentation(helperURL: helperURL, input: input, selectedDICOMSeries: selectedPayload)
    }

    private func currentStudyObject() -> NSManagedObject? {
        for pix in pixList {
            guard let imageObject = pix.value(forKey: "imageObj") as? NSManagedObject else { continue }
            if let study = imageObject.value(forKeyPath: "series.study") as? NSManagedObject {
                return study
            }
        }
        return nil
    }

    private func currentLocalSeriesSummaries() -> [[AnyHashable: Any]] {
        guard let study = currentStudyObject(),
              let seriesObjects = (study.value(forKey: "series") as? NSSet)?.allObjects as? [NSManagedObject] else {
            return []
        }

        let summaries = seriesObjects.compactMap { series -> [AnyHashable: Any]? in
            let images = (series.value(forKey: "images") as? NSSet)?.allObjects as? [NSManagedObject] ?? []
            let paths = images.compactMap { image -> String? in
                Self.nonEmpty(image.value(forKey: "completePathResolved") as? String)
                    ?? Self.nonEmpty(image.value(forKey: "completePath") as? String)
            }
            .sorted()
            guard paths.isEmpty == false else { return nil }

            let description = Self.nonEmpty(series.value(forKey: "seriesDescription") as? String)
            let number = Self.nonEmpty(series.value(forKey: "name") as? String)
            let modality = Self.nonEmpty(series.value(forKey: "modality") as? String)
            let uid = Self.nonEmpty(series.value(forKey: "seriesDICOMUID") as? String)
                ?? Self.nonEmpty(series.value(forKey: "seriesInstanceUID") as? String)
            var summary: [AnyHashable: Any] = [
                "alreadyLocal": true,
                "localPaths": paths,
                "localImageCount": paths.count,
                "numberImages": paths.count,
            ]
            if let description { summary["seriesDescription"] = description }
            if let number { summary["seriesNumber"] = number }
            if let modality { summary["modality"] = modality }
            if let uid {
                summary["seriesInstanceUID"] = uid
                summary["seriesDICOMUID"] = uid
            }
            if let role = Self.suggestedTumorSeriesRole(description: description, seriesNumber: number) {
                summary["suggestedRole"] = role
            }
            return summary
        }

        return summaries.sorted { left, right in
            let leftNumber = Int(left["seriesNumber"] as? String ?? "") ?? Int.max
            let rightNumber = Int(right["seriesNumber"] as? String ?? "") ?? Int.max
            if leftNumber != rightNumber {
                return leftNumber < rightNumber
            }
            let leftDescription = left["seriesDescription"] as? String ?? ""
            let rightDescription = right["seriesDescription"] as? String ?? ""
            return leftDescription.localizedCaseInsensitiveCompare(rightDescription) == .orderedAscending
        }
    }

    private func chooseTumorSegmentationHelper(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.message = NSLocalizedString("Choose the local tumour segmentation helper executable.", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: Metal3DLocalTumorSegmentationTask.helperPathPreferenceKey)
            completion(url)
        }
    }

    private func startTumorSegmentation(
        helperURL: URL,
        input: Metal3DSegmentationInput,
        selectedDICOMSeries: [[String: Any]]
    ) {
        let title = window?.title ?? NSLocalizedString("3D VR", comment: "")
        let task = Metal3DLocalTumorSegmentationTask(
            helperURL: helperURL,
            input: input,
            title: title,
            selectedDICOMSeries: selectedDICOMSeries,
            tumourSeeds: MetalViewerTumourSeedStore.shared.seeds(forPixList: pixList)
        )
        tumorSegmentationTask = task

        task.run { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.tumorSegmentationTask === task {
                    self.tumorSegmentationTask = nil
                }

                switch result {
                case .success(let output):
                    let statistics = self.volumeView.setTumorSegmentationLabelmap(output.labelmap)
                    self.volumeView.setTumorLabelFilter(nil)
                    self.toolbarController.selectAllTumorLabels()
                    self.toolbarController.setSurgicalTrajectoryAvailable(statistics.labelVoxelCounts.isEmpty == false)
                    var details = [
                        String(
                            format: NSLocalizedString("Loaded %@ and created %ld visible label surface(s).", comment: ""),
                            output.labelmapURL.path,
                            statistics.surfaceCount
                        )
                    ]
                    if let statisticsText = Self.tumorSegmentationStatisticsText(statistics) {
                        details.append(statisticsText)
                    }
                    if output.labels.isEmpty == false {
                        let labelText = output.labels
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: ", ")
                        details.append(String(format: NSLocalizedString("Labels: %@", comment: ""), labelText))
                    }
                    if let message = output.message, message.isEmpty == false {
                        details.append(message)
                    }
                    if let seriesSummary = self.latestTumorSeriesFetchSummary, seriesSummary.isEmpty == false {
                        details.append(seriesSummary)
                    }
                    if let resultURL = output.resultURL {
                        details.append(String(format: NSLocalizedString("Result metadata: %@", comment: ""), resultURL.path))
                    }

                    self.latestTumorSegmentationSummary = details.joined(separator: "\n\n")
                    self.showTumorSegmentationAlert(
                        message: NSLocalizedString("Tumour segmentation loaded.", comment: ""),
                        informativeText: self.latestTumorSegmentationSummary ?? ""
                    )

                case .failure(let error):
                    self.showTumorSegmentationAlert(
                        message: NSLocalizedString("Tumour segmentation failed.", comment: ""),
                        informativeText: error.localizedDescription
                    )
                }
            }
        }
    }

    private func showTumorSegmentationAlert(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showTumorSegmentationInfo() {
        guard let latestTumorSegmentationSummary else {
            showTumorSegmentationAlert(
                message: NSLocalizedString("No tumour segmentation loaded.", comment: ""),
                informativeText: NSLocalizedString("Run local tumour segmentation first.", comment: "")
            )
            return
        }

        showTumorSegmentationAlert(
            message: NSLocalizedString("Tumour segmentation info", comment: ""),
            informativeText: latestTumorSegmentationSummary
        )
    }

    private func showInitialSurgicalTrajectory() {
        if let message = volumeView.showInitialSurgicalTrajectory() {
            showTumorSegmentationAlert(
                message: NSLocalizedString("Surgical trajectory unavailable.", comment: ""),
                informativeText: message
            )
        }
    }

    func windowWillClose(_ notification: Notification) {
        tumorSegmentationTask?.cancel()
        tumorSegmentationTask = nil
        histogramPanelController.close()
    }

    private static func windowTitle(for title: String) -> String {
        let prefix = NSLocalizedString("3D VR", comment: "")
        guard let suffix = nonEmpty(title) else {
            return prefix
        }
        return "\(prefix): \(suffix)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func tumorSegmentationStatisticsText(_ statistics: Metal3DTumorSegmentationStatistics) -> String? {
        guard statistics.labelVoxelCounts.isEmpty == false else { return nil }

        var lines = [String]()
        lines.append(String(format: NSLocalizedString("Whole tumour: %.2f mL", comment: ""), statistics.wholeTumorVolumeML))
        lines.append(String(format: NSLocalizedString("Tumour core: %.2f mL", comment: ""), statistics.tumorCoreVolumeML))

        let labelNames: [UInt8: String] = [
            1: NSLocalizedString("Non-enhancing", comment: ""),
            2: NSLocalizedString("Edema", comment: ""),
            3: NSLocalizedString("Other", comment: ""),
            4: NSLocalizedString("Enhancing", comment: ""),
        ]
        let labelVolumes = statistics.labelVolumesML
        for label in statistics.labelVoxelCounts.keys.sorted() {
            let name = labelNames[label] ?? String(format: NSLocalizedString("Label %d", comment: ""), Int(label))
            let voxelCount = statistics.labelVoxelCounts[label] ?? 0
            let volumeML = labelVolumes[label] ?? 0
            lines.append(String(format: "%@: %.2f mL (%ld voxels)", name, volumeML, voxelCount))
        }

        return lines.joined(separator: "\n")
    }

    private static func suggestedTumorSeriesRole(description: String?, seriesNumber: String?) -> String? {
        let text = "\(description ?? "") \(seriesNumber ?? "")"
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        if text.contains("flair") || text.contains("fluid attenuated") {
            return "flair"
        }

        if text.contains("t2"),
           ["flair", "dwi", "diff", "adc", "localizer", "scout"].contains(where: { text.contains($0) }) == false {
            return "t2"
        }

        let looksT1 = ["t1", "mprage", "spgr", "bravo", "ir fspgr"].contains { text.contains($0) }
        guard looksT1 else { return nil }

        if ["post", "gad", "gadavist", "contrast", "ce", "+c", "c+", "t1c", "gd"].contains(where: { text.contains($0) }) {
            return "t1c"
        }

        return "t1"
    }

    private static func tumorSeriesSelectionTitle(_ series: [AnyHashable: Any]) -> String {
        var parts = [String]()
        if let number = nonEmpty(series["seriesNumber"] as? String) {
            parts.append("#\(number)")
        }
        parts.append(nonEmpty(series["seriesDescription"] as? String) ?? NSLocalizedString("Untitled series", comment: ""))
        if let modality = nonEmpty(series["modality"] as? String) {
            parts.append("[\(modality)]")
        }
        if let role = nonEmpty(series["suggestedRole"] as? String) {
            parts.append("(\(role))")
        }
        if let count = (series["numberImages"] as? NSNumber)?.intValue ?? (series["numberImages"] as? String).flatMap(Int.init) {
            parts.append("\(count) images")
        }
        if (series["alreadyLocal"] as? Bool) == true {
            if let count = (series["localImageCount"] as? Int) ?? (series["localImageCount"] as? NSNumber)?.intValue {
                parts.append(String(format: NSLocalizedString("local %ld", comment: ""), count))
            } else {
                parts.append(NSLocalizedString("local", comment: ""))
            }
        }
        return parts.joined(separator: " ")
    }

    private static func tumorSeriesSelectionTooltip(_ series: [AnyHashable: Any]) -> String {
        var lines = [String]()
        if let server = nonEmpty(series["serverDescription"] as? String) {
            lines.append(String(format: NSLocalizedString("Server: %@", comment: ""), server))
        }
        if let uid = nonEmpty(series["seriesInstanceUID"] as? String) {
            lines.append(String(format: NSLocalizedString("Series UID: %@", comment: ""), uid))
        }
        if (series["alreadyLocal"] as? Bool) == true {
            lines.append(NSLocalizedString("Already available locally.", comment: ""))
        }
        return lines.joined(separator: "\n")
    }

    private static func jsonSafeDictionary(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        var output = [String: Any]()
        for (key, value) in dictionary {
            guard let stringKey = key as? String else { continue }
            if JSONSerialization.isValidJSONObject([stringKey: value]) {
                output[stringKey] = value
            } else if let value = value as? CustomStringConvertible {
                output[stringKey] = value.description
            }
        }
        return output
    }
}

private final class Metal3DLocalTumorSegmentationTask {
    static let helperPathPreferenceKey = "Metal3DTumorSegmentationHelperPath"
    private static let pythonInterpreterPathPreferenceKey = "Metal3DTumorSegmentationPythonPath"

    struct Output {
        let labelmap: Data
        let labelmapURL: URL
        let resultURL: URL?
        let message: String?
        let labels: [UInt8: String]
    }

    private let helperURL: URL
    private let input: Metal3DSegmentationInput
    private let title: String
    private let selectedDICOMSeries: [[String: Any]]
    private let tumourSeeds: [MetalViewerTumourSeed]
    private var process: Process?

    init(
        helperURL: URL,
        input: Metal3DSegmentationInput,
        title: String,
        selectedDICOMSeries: [[String: Any]],
        tumourSeeds: [MetalViewerTumourSeed]
    ) {
        self.helperURL = helperURL
        self.input = input
        self.title = title
        self.selectedDICOMSeries = selectedDICOMSeries
        self.tumourSeeds = tumourSeeds
    }

    static func configuredHelperURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: helperPathPreferenceKey),
              path.isEmpty == false else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        if [
            "metal3d_tumor_segmentation_mock.py",
            "metal3d_tumor_segmentation_candidate.py",
        ].contains(url.lastPathComponent) {
            let nnUNetURL = url.deletingLastPathComponent().appendingPathComponent("metal3d_tumor_segmentation_nnunet.py")
            if FileManager.default.fileExists(atPath: nnUNetURL.path) {
                UserDefaults.standard.set(nnUNetURL.path, forKey: helperPathPreferenceKey)
                return nnUNetURL
            }
        }
        return url
    }

    func cancel() {
        process?.terminate()
    }

    func run(completion: @escaping (Result<Output, Error>) -> Void) {
        do {
            let job = try makeJob()
            let process = Process()
            FileManager.default.createFile(atPath: job.stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: job.stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: job.stdoutURL)
            let stderr = try FileHandle(forWritingTo: job.stderrURL)
            if helperURL.pathExtension.lowercased() == "py" {
                let pythonURL = Self.preferredPythonInterpreterURL()
                process.executableURL = pythonURL
                process.arguments = [helperURL.path, "--job", job.jobJSONURL.path]
            } else if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                process.executableURL = helperURL
                process.arguments = ["--job", job.jobJSONURL.path]
            } else {
                let pythonURL = Self.preferredPythonInterpreterURL()
                process.executableURL = pythonURL
                process.arguments = [helperURL.path, "--job", job.jobJSONURL.path]
            }
            process.currentDirectoryURL = job.directoryURL
            process.standardOutput = stdout
            process.standardError = stderr
            self.process = process

            process.terminationHandler = { process in
                stdout.closeFile()
                stderr.closeFile()
                let standardOutput = (try? String(contentsOf: job.stdoutURL, encoding: .utf8)) ?? ""
                let standardError = (try? String(contentsOf: job.stderrURL, encoding: .utf8)) ?? ""

                guard process.terminationStatus == 0 else {
                    completion(.failure(Metal3DLocalTumorSegmentationError.helperFailed(
                        status: process.terminationStatus,
                        jobDirectory: job.directoryURL,
                        stdout: standardOutput,
                        stderr: standardError
                    )))
                    return
                }

                do {
                    let labelmap = try Data(contentsOf: job.outputLabelmapURL)
                    guard labelmap.count == job.expectedVoxelCount else {
                        throw Metal3DLocalTumorSegmentationError.labelmapSizeMismatch(
                            expected: job.expectedVoxelCount,
                            actual: labelmap.count,
                            url: job.outputLabelmapURL
                        )
                    }
                    let manifest = Self.loadResultManifest(from: job.resultJSONURL)
                    completion(.success(Output(
                        labelmap: labelmap,
                        labelmapURL: job.outputLabelmapURL,
                        resultURL: FileManager.default.fileExists(atPath: job.resultJSONURL.path) ? job.resultJSONURL : nil,
                        message: manifest.message,
                        labels: manifest.labels
                    )))
                } catch {
                    completion(.failure(error))
                }
            }

            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private static func loadResultManifest(from url: URL) -> (message: String?, labels: [UInt8: String]) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, [:])
        }

        var messageParts = [String]()
        if let message = object["message"] as? String, message.isEmpty == false {
            messageParts.append(message)
        }
        if let seedGuidance = tumourSeedGuidanceMessage(from: object) {
            messageParts.append(seedGuidance)
        }
        let message = messageParts.isEmpty ? nil : messageParts.joined(separator: "\n")

        var labels = [UInt8: String]()
        if let labelObject = object["labels"] as? [String: Any] {
            for (key, value) in labelObject {
                guard let label = UInt8(key) else { continue }
                labels[label] = String(describing: value)
            }
        }

        return (message, labels)
    }

    private static func tumourSeedGuidanceMessage(from object: [String: Any]) -> String? {
        guard let guidance = object["tumourSeedGuidance"] as? [String: Any] else { return nil }
        let provided = integerValue(guidance["provided"]) ?? 0
        let usable = integerValue(guidance["usable"]) ?? 0
        guard provided > 0 else { return nil }

        let used = booleanValue(guidance["used"]) ?? false
        let mode = guidance["mode"] as? String
        if used {
            if let mode, mode.isEmpty == false, mode != "none" {
                return String(
                    format: NSLocalizedString("Tumour seed guidance: used %ld/%ld usable seed(s) (%@).", comment: ""),
                    usable,
                    provided,
                    mode
                )
            }
            return String(
                format: NSLocalizedString("Tumour seed guidance: used %ld/%ld usable seed(s).", comment: ""),
                usable,
                provided
            )
        }

        return String(
            format: NSLocalizedString("Tumour seed guidance: %ld/%ld seed(s) usable, not used by this helper.", comment: ""),
            usable,
            provided
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func preferredPythonInterpreterURL() -> URL {
        let fileManager = FileManager.default
        if let savedPath = UserDefaults.standard.string(forKey: pythonInterpreterPathPreferenceKey),
           savedPath.isEmpty == false,
           fileManager.isExecutableFile(atPath: savedPath) {
            return URL(fileURLWithPath: savedPath)
        }

        let candidatePaths = [
            "/Users/ystarrev/miniconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            UserDefaults.standard.set(path, forKey: pythonInterpreterPathPreferenceKey)
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private static func tumourSeedPayload(_ seed: MetalViewerTumourSeed, input: Metal3DSegmentationInput) -> [String: Any] {
        let croppedX = Float(seed.pixelX) - Float(input.sourceCropMin.x)
        let croppedY = Float(seed.pixelY) - Float(input.sourceCropMin.y)
        let croppedZ = Float(seed.sliceIndex) - Float(input.sourceCropMin.z)
        let volumeVoxel = SIMD3<Float>(
            croppedX * input.sourceSpacing.x / max(input.spacing.x, 0.0001),
            croppedY * input.sourceSpacing.y / max(input.spacing.y, 0.0001),
            croppedZ * input.sourceSpacing.z / max(input.spacing.z, 0.0001)
        )
        let isInsideVolume = volumeVoxel.x >= -0.5 &&
            volumeVoxel.y >= -0.5 &&
            volumeVoxel.z >= -0.5 &&
            volumeVoxel.x <= Float(max(input.dimensions.x - 1, 0)) + 0.5 &&
            volumeVoxel.y <= Float(max(input.dimensions.y - 1, 0)) + 0.5 &&
            volumeVoxel.z <= Float(max(input.dimensions.z - 1, 0)) + 0.5

        var payload: [String: Any] = [
            "id": seed.identifier,
            "studyInstanceUID": seed.studyIdentifier,
            "seriesInstanceUID": seed.seriesIdentifier,
            "sliceIndex": seed.sliceIndex,
            "sourcePixel": [seed.pixelX, seed.pixelY],
            "dicomPositionMM": [seed.dicomX, seed.dicomY, seed.dicomZ],
            "diameterMM": seed.diameterMM,
            "createdAt": ISO8601DateFormatter().string(from: seed.createdAt),
        ]
        if isInsideVolume {
            payload["volumeVoxel"] = [
                Double(volumeVoxel.x),
                Double(volumeVoxel.y),
                Double(volumeVoxel.z),
            ]
        }
        return payload
    }

    private func makeJob() throws -> Metal3DLocalTumorSegmentationJob {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HorosMetal3DTumorSegmentation", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let volumeURL = directoryURL.appendingPathComponent("volume.float32.raw")
        let jobJSONURL = directoryURL.appendingPathComponent("job.json")
        let outputLabelmapURL = directoryURL.appendingPathComponent("tumor-labelmap.uint8.raw")
        let resultJSONURL = directoryURL.appendingPathComponent("result.json")
        let stdoutURL = directoryURL.appendingPathComponent("stdout.txt")
        let stderrURL = directoryURL.appendingPathComponent("stderr.txt")

        try input.float32VolumeData.write(to: volumeURL, options: .atomic)

        let expectedVoxelCount = max(input.dimensions.x * input.dimensions.y * input.dimensions.z, 0)
        let job: [String: Any] = [
            "schema": "com.horos.metal3d.tumor-segmentation-job.v1",
            "title": title,
            "workingDirectory": directoryURL.path,
            "inputVolume": volumeURL.path,
            "inputScalarType": "float32-le",
            "inputVolumes": [
                [
                    "role": "displayed",
                    "path": volumeURL.path,
                    "scalarType": "float32-le",
                    "dimensions": [input.dimensions.x, input.dimensions.y, input.dimensions.z],
                    "spacingMM": [input.spacing.x, input.spacing.y, input.spacing.z]
                ]
            ],
            "selectedDICOMSeries": selectedDICOMSeries,
            "tumourSeeds": tumourSeeds.map { Self.tumourSeedPayload($0, input: input) },
            "tumourSeedSelectionRadiusMM": 60.0,
            "outputLabelmap": outputLabelmapURL.path,
            "outputLabelType": "uint8",
            "resultJSON": resultJSONURL.path,
            "outputLabelmaps": [
                [
                    "role": "tumour-labels",
                    "path": outputLabelmapURL.path,
                    "labelType": "uint8",
                    "dimensions": [input.dimensions.x, input.dimensions.y, input.dimensions.z],
                    "spacingMM": [input.spacing.x, input.spacing.y, input.spacing.z]
                ]
            ],
            "dimensions": [input.dimensions.x, input.dimensions.y, input.dimensions.z],
            "spacingMM": [input.spacing.x, input.spacing.y, input.spacing.z],
            "expectedVoxelCount": expectedVoxelCount,
            "labels": [
                "0": "background",
                "1": "tumour core",
                "2": "edema",
                "4": "enhancing tumour"
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: jobJSONURL, options: .atomic)

        return Metal3DLocalTumorSegmentationJob(
            directoryURL: directoryURL,
            jobJSONURL: jobJSONURL,
            outputLabelmapURL: outputLabelmapURL,
            resultJSONURL: resultJSONURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            expectedVoxelCount: expectedVoxelCount
        )
    }
}

private struct Metal3DLocalTumorSegmentationJob {
    let directoryURL: URL
    let jobJSONURL: URL
    let outputLabelmapURL: URL
    let resultJSONURL: URL
    let stdoutURL: URL
    let stderrURL: URL
    let expectedVoxelCount: Int
}

private enum Metal3DLocalTumorSegmentationError: LocalizedError {
    case helperFailed(status: Int32, jobDirectory: URL, stdout: String, stderr: String)
    case labelmapSizeMismatch(expected: Int, actual: Int, url: URL)

    var errorDescription: String? {
        switch self {
        case .helperFailed(let status, let jobDirectory, let stdout, let stderr):
            let detail = [stderr, stdout].filter { $0.isEmpty == false }.joined(separator: "\n")
            return String(
                format: NSLocalizedString("The local helper exited with status %d.\n\nJob folder: %@\n\n%@", comment: ""),
                status,
                jobDirectory.path,
                detail
            )

        case .labelmapSizeMismatch(let expected, let actual, let url):
            return String(
                format: NSLocalizedString("The helper wrote %@, but its byte count was %ld instead of the expected %ld.", comment: ""),
                url.path,
                actual,
                expected
            )
        }
    }
}
