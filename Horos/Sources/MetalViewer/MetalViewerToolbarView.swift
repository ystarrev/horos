import AppKit

enum MetalViewerAnnotationLevel: Int, CaseIterable {
    case none = 0
    case graphics = 1
    case basic = 2
    case full = 3

    static let defaultsKey = "ANNOTATIONS"

    static var current: MetalViewerAnnotationLevel {
        MetalViewerAnnotationLevel(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .none
    }
}

final class MetalViewerToolbarView: NSView {
    enum ViewerMode: Int {
        case stack2D = 0
        case mpr = 1
        case mpr3D = 2
    }

    enum WLWWCommand {
        case other
        case defaultWindow
        case automatic
        case fullDynamic
        case preset(String)
        case addCurrent
        case setManually
    }

    enum ROICommand {
        case select(UUID)
        case newSphere
        case createSEGFromLegacyBrush
        case addAnchor
        case deleteAnchor
        case refineFromImage
        case finishEditing
        case duplicate
        case rename
        case color
        case delete
        case undo
        case redo
    }

    private let contentStack = NSStackView()
    private let viewerModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wlwwPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let roiPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let legacyBrushSEGButton = NSButton(frame: .zero)
    private let syncScaleButton = NSButton(frame: .zero)
    private let leftMouseButtonRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Left Button", comment: ""), target: nil, action: nil)
    private let rightMouseButtonRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Right Button", comment: ""), target: nil, action: nil)
    private var selectedMouseButton: MetalViewerMouseButton = .left
    private var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private var mouseModifierFlags: NSEvent.ModifierFlags = []
    private var mouseToolButtons: [MetalViewerMouseTool: NSButton] = [:]
    private var annotationButtons: [MetalViewerAnnotationLevel: NSButton] = [:]
    var viewerModeSelectionHandler: ((ViewerMode) -> Void)?
    var wlwwSelectionHandler: ((WLWWCommand) -> Void)?
    var clutSelectionHandler: ((String) -> Void)?
    var opacitySelectionHandler: ((String) -> Void)?
    var mouseToolSelectionHandler: ((MetalViewerMouseToolAssignments) -> Void)?
    var syncScaleSelectionHandler: ((Bool) -> Void)?
    var annotationLevelSelectionHandler: ((MetalViewerAnnotationLevel) -> Void)?
    var roiCommandHandler: ((ROICommand) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 14
        addSubview(contentStack)

        let items: [(String, NSView)] = [
            ("Annotations", makeAnnotationsContent()),
            ("Mouse button function", makeMouseToolsContent()),
            ("ROI", makeROIContent()),
            ("WL/WW & CLUT", makeWLWWContent()),
            ("Sync Scale", makeSyncScaleContent()),
            ("View", makeViewerModeContent()),
        ]

        items.forEach { title, view in
            contentStack.addArrangedSubview(MetalViewerToolbarItemView(title: title, contentView: view))
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 100),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTitle(_ title: String) {
    }

    func updateStatus(_ status: String) {
    }

    func reloadWLWWMenu(
        selectedTitle: String = NSLocalizedString("Default WL & WW", comment: ""),
        modality: String = "OT"
    ) {
        wlwwPopup.removeAllItems()
        let normalizedModality = modality.uppercased()

        func addItem(_ title: String, command: WLWWCommand?, state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: #selector(wlwwSelectionDidChange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.state = state
            wlwwPopup.menu?.addItem(item)
        }

        addItem(NSLocalizedString("Other", comment: ""), command: .other, state: selectedTitle == NSLocalizedString("Other", comment: "") ? .on : .off)
        addItem(NSLocalizedString("Default WL & WW", comment: ""), command: .defaultWindow, state: selectedTitle == NSLocalizedString("Default WL & WW", comment: "") ? .on : .off)
        addItem(NSLocalizedString("Auto", comment: ""), command: .automatic, state: selectedTitle == NSLocalizedString("Auto", comment: "") ? .on : .off)
        addItem(NSLocalizedString("Full dynamic", comment: ""), command: .fullDynamic, state: selectedTitle == NSLocalizedString("Full dynamic", comment: "") ? .on : .off)
        wlwwPopup.menu?.addItem(.separator())

        let presetKeys: [String]
        if let wlwwDictionary = UserDefaults.standard.dictionary(forKey: "WLWW3") {
            presetKeys = Array(wlwwDictionary.keys)
        } else {
            presetKeys = []
        }
        let presetNames = presetKeys
            .filter { shouldShowPreset(named: $0, modality: normalizedModality) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for (index, name) in presetNames.enumerated() {
            let title = "\(index + 1) - \(name)"
            addItem(title, command: .preset(name), state: selectedTitle == title || selectedTitle == name ? .on : .off)
        }

        wlwwPopup.menu?.addItem(.separator())
        addItem(NSLocalizedString("Add Current WL/WW", comment: ""), command: .addCurrent)
        addItem(NSLocalizedString("Set WL/WW Manually", comment: ""), command: .setManually)

        selectWLWWTitle(selectedTitle)
    }

    func selectWLWWTitle(_ title: String) {
        if let item = wlwwPopup.itemTitles.first(where: { $0 == title || $0.hasSuffix(" - \(title)") }) {
            wlwwPopup.selectItem(withTitle: item)
        } else {
            wlwwPopup.selectItem(withTitle: NSLocalizedString("Other", comment: ""))
        }

        for item in wlwwPopup.itemArray {
            guard item.isSeparatorItem == false else { continue }
            item.state = item == wlwwPopup.selectedItem ? .on : .off
        }
    }

    func reloadCLUTMenu(selectedTitle: String = NSLocalizedString("No CLUT", comment: "")) {
        let noCLUT = NSLocalizedString("No CLUT", comment: "")
        let presetNames = (UserDefaults.standard.dictionary(forKey: "CLUT")?.keys.map { $0 } ?? [])
            .filter { $0 != noCLUT }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        reloadTransferMenu(
            clutPopup,
            defaultTitle: noCLUT,
            presetNames: presetNames,
            selectedTitle: selectedTitle,
            action: #selector(clutSelectionDidChange(_:))
        )
    }

    func reloadOpacityMenu(selectedTitle: String = NSLocalizedString("Linear Table", comment: "")) {
        let linearTable = NSLocalizedString("Linear Table", comment: "")
        let presetNames = (UserDefaults.standard.dictionary(forKey: "OPACITY")?.keys.map { $0 } ?? [])
            .filter { $0 != linearTable }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        reloadTransferMenu(
            opacityPopup,
            defaultTitle: linearTable,
            presetNames: presetNames,
            selectedTitle: selectedTitle,
            action: #selector(opacitySelectionDidChange(_:))
        )
    }

    func selectViewerMode(_ mode: ViewerMode) {
        viewerModePopup.selectItem(withTag: mode.rawValue)
    }

    func reloadROIMenu(
        store: MetalStudyROIStore,
        editingMode: MetalStudyROIEditingMode,
        canCreateSEGFromLegacyBrush: Bool = false
    ) {
        roiPopup.removeAllItems()
        legacyBrushSEGButton.isEnabled = canCreateSEGFromLegacyBrush

        func addItem(
            _ title: String,
            command: ROICommand,
            enabled: Bool = true,
            state: NSControl.StateValue = .off,
            keyEquivalent: String = "",
            modifierMask: NSEvent.ModifierFlags = []
        ) {
            let item = NSMenuItem(
                title: title,
                action: #selector(roiSelectionDidChange(_:)),
                keyEquivalent: keyEquivalent
            )
            item.target = self
            item.representedObject = command
            item.isEnabled = enabled
            item.state = state
            item.keyEquivalentModifierMask = modifierMask
            roiPopup.menu?.addItem(item)
        }

        if store.rois.isEmpty {
            let empty = NSMenuItem(title: NSLocalizedString("No ROIs", comment: ""), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            roiPopup.menu?.addItem(empty)
        } else {
            for roi in store.rois {
                let title = String(format: NSLocalizedString("%@ — %.3f mL", comment: ""), roi.name, roi.volumeML)
                addItem(
                    title,
                    command: .select(roi.id),
                    state: store.selectedROIIdentifier == roi.id ? .on : .off
                )
            }
        }

        roiPopup.menu?.addItem(.separator())
        addItem(NSLocalizedString("New Spherical ROI…", comment: ""), command: .newSphere)
        addItem(
            NSLocalizedString("Create SEG from Legacy Brush ROI", comment: ""),
            command: .createSEGFromLegacyBrush,
            enabled: canCreateSEGFromLegacyBrush
        )
        let selectedMouseTool = mouseToolAssignments.resolvedTool(
            for: selectedMouseButton,
            modifierFlags: mouseModifierFlags
        )
        addItem(
            NSLocalizedString("Add or Move Surface Anchor", comment: ""),
            command: .addAnchor,
            enabled: store.selectedROI != nil,
            state: selectedMouseTool == .roiAnchor ? .on : .off
        )
        addItem(
            NSLocalizedString("Delete Surface Anchor", comment: ""),
            command: .deleteAnchor,
            enabled: store.selectedROI?.anchors.isEmpty == false,
            state: selectedMouseTool == .deleteROIAnchor ? .on : .off
        )
        addItem(
            NSLocalizedString("Refine ROI from Image", comment: ""),
            command: .refineFromImage,
            enabled: store.selectedROI != nil,
            keyEquivalent: "r",
            modifierMask: [.command, .option]
        )
        let finishEditingTitle: String
        switch editingMode {
        case .translate:
            finishEditingTitle = NSLocalizedString("Finish Adjusting ROI", comment: "")
        case .createSphere:
            finishEditingTitle = NSLocalizedString("Cancel New ROI", comment: "")
        case .inactive:
            finishEditingTitle = NSLocalizedString("Finish ROI Editing", comment: "")
        }
        addItem(
            finishEditingTitle,
            command: .finishEditing,
            enabled: editingMode != .inactive
        )
        roiPopup.menu?.addItem(.separator())
        addItem(NSLocalizedString("Duplicate ROI", comment: ""), command: .duplicate, enabled: store.selectedROI != nil)
        addItem(NSLocalizedString("Rename ROI…", comment: ""), command: .rename, enabled: store.selectedROI != nil)
        addItem(NSLocalizedString("ROI Color…", comment: ""), command: .color, enabled: store.selectedROI != nil)
        addItem(NSLocalizedString("Delete ROI", comment: ""), command: .delete, enabled: store.selectedROI != nil)
        roiPopup.menu?.addItem(.separator())
        addItem(NSLocalizedString("Undo ROI Edit", comment: ""), command: .undo, enabled: store.canUndo)
        addItem(NSLocalizedString("Redo ROI Edit", comment: ""), command: .redo, enabled: store.canRedo)

        if let selected = store.selectedROI {
            let selectedTitle = String(format: NSLocalizedString("%@ — %.3f mL", comment: ""), selected.name, selected.volumeML)
            roiPopup.selectItem(withTitle: selectedTitle)
        } else {
            roiPopup.selectItem(at: 0)
        }
    }

    func selectMouseToolAssignments(_ assignments: MetalViewerMouseToolAssignments) {
        mouseToolAssignments = assignments
        updateMouseButtonRadioStates()
        updateMouseToolHighlights()
    }

    func assignMouseToolToSelectedButton(_ tool: MetalViewerMouseTool) {
        setSelectedMouseTool(tool, modifierFlags: mouseModifierFlags)
    }

    func setMouseModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let relevantFlags = flags.intersection([.control, .command, .option, .shift])
        guard relevantFlags != mouseModifierFlags else { return }
        mouseModifierFlags = relevantFlags
        updateMouseToolHighlights()
    }

    func setSyncScaleEnabled(_ isEnabled: Bool) {
        syncScaleButton.state = isEnabled ? .on : .off
        updateSyncScaleButtonImage()
    }

    func selectAnnotationLevel(_ level: MetalViewerAnnotationLevel) {
        for (buttonLevel, button) in annotationButtons {
            button.state = buttonLevel == level ? .on : .off
        }
    }

    private func makeAnnotationsContent() -> NSView {
        let grid = NSGridView(views: [
            [makeAnnotationRadio("None", level: .none), makeAnnotationRadio("Basic", level: .basic)],
            [makeAnnotationRadio("Graphics", level: .graphics), makeAnnotationRadio("Full", level: .full)],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 0
        grid.columnSpacing = 10

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 156),
            container.heightAnchor.constraint(equalToConstant: 42),

            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            grid.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeAnnotationRadio(_ title: String, level: MetalViewerAnnotationLevel) -> NSButton {
        let button = NSButton(
            radioButtonWithTitle: NSLocalizedString(title, comment: ""),
            target: self,
            action: #selector(annotationRadioPressed(_:))
        )
        button.font = NSFont.systemFont(ofSize: 11)
        button.tag = level.rawValue
        button.state = level == MetalViewerAnnotationLevel.current ? .on : .off
        annotationButtons[level] = button
        return button
    }

    @objc private func annotationRadioPressed(_ sender: NSButton) {
        guard let level = MetalViewerAnnotationLevel(rawValue: sender.tag) else {
            return
        }
        selectAnnotationLevel(level)
        annotationLevelSelectionHandler?(level)
    }

    private func makeViewerModeContent() -> NSView {
        viewerModePopup.translatesAutoresizingMaskIntoConstraints = false
        viewerModePopup.controlSize = .small
        viewerModePopup.bezelStyle = .texturedRounded
        viewerModePopup.target = self
        viewerModePopup.action = #selector(viewerModeDidChange(_:))
        viewerModePopup.removeAllItems()
        addViewerModeMenuItem(title: NSLocalizedString("2D", comment: ""), imageName: "Stack", mode: .stack2D)
        addViewerModeMenuItem(title: NSLocalizedString("MPR", comment: ""), imageName: "MPR", mode: .mpr)
        addViewerModeMenuItem(title: NSLocalizedString("3D MPR", comment: ""), imageName: "MPR", mode: .mpr3D)
        selectViewerMode(.stack2D)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewerModePopup)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 128),
            container.heightAnchor.constraint(equalToConstant: 42),

            viewerModePopup.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            viewerModePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            viewerModePopup.widthAnchor.constraint(equalToConstant: 122),
        ])
        return container
    }

    private func addViewerModeMenuItem(title: String, imageName: String, mode: ViewerMode) {
        viewerModePopup.addItem(withTitle: title)
        guard let item = viewerModePopup.lastItem else {
            return
        }
        item.tag = mode.rawValue
        item.image = toolbarMenuImage(named: imageName)
    }

    private func makeMouseToolsContent() -> NSView {
        let iconsStack = NSStackView()
        iconsStack.translatesAutoresizingMaskIntoConstraints = false
        iconsStack.orientation = .horizontal
        iconsStack.alignment = .centerY
        iconsStack.spacing = 6

        for tool in MetalViewerMouseTool.allCases {
            let button = NSButton(image: mouseToolImage(for: tool), target: self, action: #selector(mouseToolButtonPressed(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.setButtonType(.toggle)
            button.tag = tool.rawValue
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = mouseToolTooltip(tool)
            button.setAccessibilityLabel(mouseToolTitle(tool))
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            mouseToolButtons[tool] = button
            iconsStack.addArrangedSubview(button)
        }

        let chevron = NSButton(title: "⌄", target: nil, action: nil)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isBordered = false
        chevron.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        chevron.contentTintColor = .white
        chevron.toolTip = NSLocalizedString("More mouse tool choices.", comment: "")
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 14),
        ])
        iconsStack.addArrangedSubview(chevron)

        let buttonChoiceStack = NSStackView()
        buttonChoiceStack.translatesAutoresizingMaskIntoConstraints = false
        buttonChoiceStack.orientation = .horizontal
        buttonChoiceStack.alignment = .centerY
        buttonChoiceStack.spacing = 12
        configureMouseButtonRadio(leftMouseButtonRadio, buttonChoice: .left)
        configureMouseButtonRadio(rightMouseButtonRadio, buttonChoice: .right)
        buttonChoiceStack.addArrangedSubview(leftMouseButtonRadio)
        buttonChoiceStack.addArrangedSubview(rightMouseButtonRadio)

        let vertical = NSStackView(views: [iconsStack, buttonChoiceStack])
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 2

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vertical)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 294),
            container.heightAnchor.constraint(equalToConstant: 42),

            vertical.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        updateMouseButtonRadioStates()
        updateMouseToolHighlights()
        return container
    }

    private func makeROIContent() -> NSView {
        roiPopup.translatesAutoresizingMaskIntoConstraints = false
        roiPopup.controlSize = .mini
        roiPopup.toolTip = NSLocalizedString("Create and edit study-level 3D segmentations in the 3D MPR view.", comment: "")

        legacyBrushSEGButton.translatesAutoresizingMaskIntoConstraints = false
        legacyBrushSEGButton.title = NSLocalizedString("SEG", comment: "")
        legacyBrushSEGButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        legacyBrushSEGButton.controlSize = .small
        legacyBrushSEGButton.bezelStyle = .texturedRounded
        legacyBrushSEGButton.target = self
        legacyBrushSEGButton.action = #selector(createSEGFromLegacyBrush(_:))
        legacyBrushSEGButton.toolTip = NSLocalizedString(
            "Create an editable DICOM SEG from the legacy brush ROI nearest the displayed slice.",
            comment: ""
        )
        legacyBrushSEGButton.isEnabled = false

        let controls = NSStackView(views: [roiPopup, legacyBrushSEGButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 198),
            container.heightAnchor.constraint(equalToConstant: 42),
            controls.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            roiPopup.widthAnchor.constraint(equalToConstant: 148),
            legacyBrushSEGButton.widthAnchor.constraint(equalToConstant: 42),
        ])
        return container
    }

    private func makeWLWWContent() -> NSView {
        configurePopup(wlwwPopup)
        reloadWLWWMenu()

        configurePopup(clutPopup)
        reloadCLUTMenu()

        configurePopup(opacityPopup)
        reloadOpacityMenu()

        let rows = [
            (NSLocalizedString("WL/WW:", comment: ""), wlwwPopup),
            (NSLocalizedString("CLUT:", comment: ""), clutPopup),
            (NSLocalizedString("Opacity:", comment: ""), opacityPopup),
        ].map { label, popup in
            let labelField = NSTextField(labelWithString: label)
            labelField.font = NSFont.systemFont(ofSize: 10)
            labelField.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            labelField.alignment = .right
            labelField.translatesAutoresizingMaskIntoConstraints = false
            labelField.widthAnchor.constraint(equalToConstant: 36).isActive = true

            let row = NSStackView(views: [labelField, popup])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            return row
        }

        let vertical = NSStackView(views: rows)
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 1

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vertical)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 180),
            container.heightAnchor.constraint(equalToConstant: 58),

            vertical.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .mini
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: 140),
        ])
    }

    private func reloadTransferMenu(
        _ popup: NSPopUpButton,
        defaultTitle: String,
        presetNames: [String],
        selectedTitle: String,
        action: Selector
    ) {
        popup.removeAllItems()

        func addItem(_ title: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            popup.menu?.addItem(item)
        }

        addItem(defaultTitle)
        if presetNames.isEmpty == false {
            popup.menu?.addItem(.separator())
            presetNames.forEach(addItem)
        }

        let resolvedTitle = popup.itemTitles.contains(selectedTitle) ? selectedTitle : defaultTitle
        popup.selectItem(withTitle: resolvedTitle)
        for item in popup.itemArray where item.isSeparatorItem == false {
            item.state = item.title == resolvedTitle ? .on : .off
        }
    }

    private func shouldShowPreset(named name: String, modality: String) -> Bool {
        let uppercasedName = name.uppercased()
        let knownPrefixes = ["CT", "MR", "MRI", "PT", "PET", "NM", "US", "XA", "RF", "CR", "DX", "MG"]
        let matchingPrefixes = knownPrefixes.filter {
            uppercasedName == $0 || uppercasedName.hasPrefix("\($0) ") || uppercasedName.hasPrefix("\($0)-")
        }

        guard matchingPrefixes.isEmpty == false else {
            return true
        }

        if modality == "MR" {
            return matchingPrefixes.contains("MR") || matchingPrefixes.contains("MRI")
        }
        if modality == "PT" {
            return matchingPrefixes.contains("PT") || matchingPrefixes.contains("PET")
        }
        return matchingPrefixes.contains(modality)
    }

    @objc
    private func wlwwSelectionDidChange(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let command = item.representedObject as? WLWWCommand else {
            return
        }
        wlwwSelectionHandler?(command)
    }

    @objc
    private func clutSelectionDidChange(_ sender: NSMenuItem) {
        selectTransferItem(sender, in: clutPopup)
        clutSelectionHandler?(sender.title)
    }

    @objc
    private func opacitySelectionDidChange(_ sender: NSMenuItem) {
        selectTransferItem(sender, in: opacityPopup)
        opacitySelectionHandler?(sender.title)
    }

    private func selectTransferItem(_ selectedItem: NSMenuItem, in popup: NSPopUpButton) {
        popup.select(selectedItem)
        for item in popup.itemArray where item.isSeparatorItem == false {
            item.state = item === selectedItem ? .on : .off
        }
    }

    @objc
    private func viewerModeDidChange(_ sender: NSPopUpButton) {
        guard let mode = ViewerMode(rawValue: sender.selectedItem?.tag ?? ViewerMode.stack2D.rawValue) else {
            return
        }
        viewerModeSelectionHandler?(mode)
    }

    @objc
    private func roiSelectionDidChange(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ROICommand else { return }
        roiCommandHandler?(command)
    }

    @objc
    private func createSEGFromLegacyBrush(_ sender: NSButton) {
        roiCommandHandler?(.createSEGFromLegacyBrush)
    }

    private func configureMouseButtonRadio(_ radio: NSButton, buttonChoice: MetalViewerMouseButton) {
        radio.font = NSFont.systemFont(ofSize: 10)
        radio.setButtonType(.radio)
        radio.tag = buttonChoice.rawValue
        radio.target = self
        radio.action = #selector(mouseButtonChoiceDidChange(_:))
        switch buttonChoice {
        case .left:
            radio.toolTip = NSLocalizedString("Show and edit the tool assigned to the left mouse button.", comment: "")
        case .right:
            radio.toolTip = NSLocalizedString("Show and edit the tool assigned to the right mouse button.", comment: "")
        }
    }

    @objc
    private func mouseButtonChoiceDidChange(_ sender: NSButton) {
        guard let buttonChoice = MetalViewerMouseButton(rawValue: sender.tag) else {
            return
        }
        selectedMouseButton = buttonChoice
        updateMouseButtonRadioStates()
        updateMouseToolHighlights()
    }

    @objc
    private func mouseToolButtonPressed(_ sender: NSButton) {
        guard let tool = MetalViewerMouseTool(rawValue: sender.tag) else {
            return
        }
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? mouseModifierFlags
        setMouseModifierFlags(modifierFlags)
        setSelectedMouseTool(tool, modifierFlags: modifierFlags)
    }

    private func setSelectedMouseTool(
        _ tool: MetalViewerMouseTool,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        mouseToolAssignments.setTool(
            tool,
            for: selectedMouseButton,
            modifierFlags: modifierFlags
        )
        mouseToolAssignments.save()
        updateMouseToolHighlights()
        mouseToolSelectionHandler?(mouseToolAssignments)
    }

    @objc
    private func syncScaleButtonPressed(_ sender: NSButton) {
        updateSyncScaleButtonImage()
        syncScaleSelectionHandler?(sender.state == .on)
    }

    private func updateMouseButtonRadioStates() {
        leftMouseButtonRadio.state = selectedMouseButton == .left ? .on : .off
        rightMouseButtonRadio.state = selectedMouseButton == .right ? .on : .off
    }

    private func updateMouseToolHighlights() {
        let selectedTool = mouseToolAssignments.resolvedTool(
            for: selectedMouseButton,
            modifierFlags: mouseModifierFlags
        )
        for (tool, button) in mouseToolButtons {
            let isSelected = tool == selectedTool
            button.state = isSelected ? .on : .off
            button.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = isSelected ? 1 : 0
            let usesFixedColor = tool == .tumourSeed || tool == .roiAnchor || tool == .deleteROIAnchor
            button.contentTintColor = usesFixedColor ? nil : (isSelected ? NSColor.controlAccentColor : .white)
        }
    }

    private func mouseToolImage(for tool: MetalViewerMouseTool) -> NSImage {
        MetalViewerMouseToolArtwork.image(for: tool)
    }

    private func mouseToolTitle(_ tool: MetalViewerMouseTool) -> String {
        switch tool {
        case .windowLevel:
            return NSLocalizedString("Window Level", comment: "")
        case .pan:
            return NSLocalizedString("Pan", comment: "")
        case .zoom:
            return NSLocalizedString("Zoom", comment: "")
        case .rotate:
            return NSLocalizedString("Rotate", comment: "")
        case .scroll:
            return NSLocalizedString("Scroll Through Slices", comment: "")
        case .measure:
            return NSLocalizedString("Measure", comment: "")
        case .tumourSeed:
            return NSLocalizedString("Tumour Seed", comment: "")
        case .roiAnchor:
            return NSLocalizedString("Add or Move ROI Anchor", comment: "")
        case .deleteROIAnchor:
            return NSLocalizedString("Delete ROI Anchor", comment: "")
        }
    }

    private func mouseToolTooltip(_ tool: MetalViewerMouseTool) -> String {
        switch tool {
        case .windowLevel:
            return NSLocalizedString("Window Level: drag horizontally to change window width and vertically to change window level.", comment: "")
        case .pan:
            return NSLocalizedString("Pan: drag to move the image within the pane.", comment: "")
        case .zoom:
            return NSLocalizedString("Zoom: drag up to zoom in or down to zoom out.", comment: "")
        case .rotate:
            return NSLocalizedString("Rotate: drag around the image center to rotate the 2D image. In MPR, drag to rotate the view.", comment: "")
        case .scroll:
            return NSLocalizedString("Scroll: drag vertically to move through slices.", comment: "")
        case .measure:
            return NSLocalizedString("Measure: drag to place a length measurement. Hold Shift to constrain horizontally, vertically, or diagonally.", comment: "")
        case .tumourSeed:
            return NSLocalizedString("Tumour Seed: click a tumour focus to place a seed point used by segmentation.", comment: "")
        case .roiAnchor:
            return NSLocalizedString("ROI Anchor: click to add an anchor to the selected 3D ROI, or drag an existing anchor to reposition it.", comment: "")
        case .deleteROIAnchor:
            return NSLocalizedString("Delete ROI Anchor: click an existing anchor to remove it from the selected 3D ROI.", comment: "")
        }
    }

    private func makeSyncScaleContent() -> NSView {
        syncScaleButton.translatesAutoresizingMaskIntoConstraints = false
        syncScaleButton.isBordered = true
        syncScaleButton.bezelStyle = .texturedRounded
        syncScaleButton.setButtonType(.toggle)
        syncScaleButton.imageScaling = .scaleProportionallyDown
        syncScaleButton.target = self
        syncScaleButton.action = #selector(syncScaleButtonPressed(_:))
        syncScaleButton.toolTip = NSLocalizedString("Synchronize zoom scale between open viewer panes in this window.", comment: "")
        syncScaleButton.setAccessibilityLabel(NSLocalizedString("Sync Scale", comment: ""))
        updateSyncScaleButtonImage()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(syncScaleButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 68),
            container.heightAnchor.constraint(equalToConstant: 42),

            syncScaleButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            syncScaleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            syncScaleButton.widthAnchor.constraint(equalToConstant: 34),
            syncScaleButton.heightAnchor.constraint(equalToConstant: 34),
        ])
        return container
    }

    private func updateSyncScaleButtonImage() {
        syncScaleButton.image = toolbarImage(named: syncScaleButton.state == .on ? "SyncLock.pdf" : "Sync.pdf")
    }

    private func toolbarImage(named name: String) -> NSImage {
        if let image = NSImage(named: NSImage.Name(name)) {
            return image
        }
        return NSImage(size: NSSize(width: 24, height: 24))
    }

    private func toolbarMenuImage(named name: String) -> NSImage {
        let image = (toolbarImage(named: name).copy() as? NSImage) ?? toolbarImage(named: name)
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

private final class MetalViewerToolbarItemView: NSView {
    init(title: String, contentView: NSView) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        label.alignment = .center

        addSubview(contentView)
        addSubview(label)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
