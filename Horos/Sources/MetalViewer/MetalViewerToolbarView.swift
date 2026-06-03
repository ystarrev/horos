import AppKit

final class MetalViewerToolbarView: NSView {
    enum ViewerMode: Int {
        case stack2D = 0
        case mpr = 1
    }

    enum WLWWCommand {
        case other
        case defaultWindow
        case robustSeries
        case fullDynamic
        case preset(String)
        case addCurrent
        case setManually
    }

    private let contentStack = NSStackView()
    private let viewerModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wlwwPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let syncScaleButton = NSButton(frame: .zero)
    private let leftMouseButtonRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Left Button", comment: ""), target: nil, action: nil)
    private let rightMouseButtonRadio = NSButton(radioButtonWithTitle: NSLocalizedString("Right Button", comment: ""), target: nil, action: nil)
    private var selectedMouseButton: MetalViewerMouseButton = .left
    private var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private var mouseToolButtons: [MetalViewerMouseTool: NSButton] = [:]
    var viewerModeSelectionHandler: ((ViewerMode) -> Void)?
    var wlwwSelectionHandler: ((WLWWCommand) -> Void)?
    var mouseToolSelectionHandler: ((MetalViewerMouseToolAssignments) -> Void)?
    var syncScaleSelectionHandler: ((Bool) -> Void)?

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
            ("WL/WW & CLUT", makeWLWWContent()),
            ("Sync Scale", makeSyncScaleContent()),
            ("Propagate", makeIconButtonContent(imageName: "Propagate", alternateImageName: "PropagateOn")),
            ("View", makeViewerModeContent()),
        ]

        items.forEach { title, view in
            contentStack.addArrangedSubview(MetalViewerToolbarItemView(title: title, contentView: view))
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),

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
        let isMR = normalizedModality == "MR"

        func addItem(_ title: String, command: WLWWCommand?, state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: #selector(wlwwSelectionDidChange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.state = state
            wlwwPopup.menu?.addItem(item)
        }

        addItem(NSLocalizedString("Other", comment: ""), command: .other, state: selectedTitle == NSLocalizedString("Other", comment: "") ? .on : .off)
        addItem(NSLocalizedString("Default WL & WW", comment: ""), command: .defaultWindow, state: selectedTitle == NSLocalizedString("Default WL & WW", comment: "") ? .on : .off)
        if isMR {
            addItem(NSLocalizedString("Robust MRI series", comment: ""), command: .robustSeries, state: selectedTitle == NSLocalizedString("Robust MRI series", comment: "") ? .on : .off)
        }
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

    func selectViewerMode(_ mode: ViewerMode) {
        viewerModePopup.selectItem(withTag: mode.rawValue)
    }

    func selectMouseToolAssignments(_ assignments: MetalViewerMouseToolAssignments) {
        mouseToolAssignments = assignments
        updateMouseButtonRadioStates()
        updateMouseToolHighlights()
    }

    func setSyncScaleEnabled(_ isEnabled: Bool) {
        syncScaleButton.state = isEnabled ? .on : .off
        updateSyncScaleButtonImage()
    }

    private func makeAnnotationsContent() -> NSView {
        let grid = NSGridView(views: [
            [makeToolbarRadio("None", selected: false), makeToolbarRadio("Basic", selected: false)],
            [makeToolbarRadio("Graphic", selected: false), makeToolbarRadio("Full", selected: true)],
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

    private func makeViewerModeContent() -> NSView {
        viewerModePopup.translatesAutoresizingMaskIntoConstraints = false
        viewerModePopup.controlSize = .small
        viewerModePopup.bezelStyle = .texturedRounded
        viewerModePopup.target = self
        viewerModePopup.action = #selector(viewerModeDidChange(_:))
        viewerModePopup.removeAllItems()
        addViewerModeMenuItem(title: NSLocalizedString("2D", comment: ""), imageName: "Stack", mode: .stack2D)
        addViewerModeMenuItem(title: NSLocalizedString("MPR", comment: ""), imageName: "MPR", mode: .mpr)
        selectViewerMode(.stack2D)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewerModePopup)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 102),
            container.heightAnchor.constraint(equalToConstant: 42),

            viewerModePopup.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            viewerModePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            viewerModePopup.widthAnchor.constraint(equalToConstant: 96),
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
            container.widthAnchor.constraint(equalToConstant: 230),
            container.heightAnchor.constraint(equalToConstant: 42),

            vertical.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        updateMouseButtonRadioStates()
        updateMouseToolHighlights()
        return container
    }

    private func makeWLWWContent() -> NSView {
        configurePopup(wlwwPopup)
        reloadWLWWMenu()

        configurePopup(opacityPopup)
        opacityPopup.addItems(withTitles: [NSLocalizedString("Linear Table", comment: "")])

        let rows = [
            (NSLocalizedString("WL/WW:", comment: ""), wlwwPopup),
            (NSLocalizedString("Opacity:", comment: ""), opacityPopup),
        ].map { label, popup in
            let labelField = NSTextField(labelWithString: label)
            labelField.font = NSFont.systemFont(ofSize: 10)
            labelField.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            labelField.alignment = .right

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
            container.widthAnchor.constraint(equalToConstant: 176),
            container.heightAnchor.constraint(equalToConstant: 42),

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
    private func viewerModeDidChange(_ sender: NSPopUpButton) {
        guard let mode = ViewerMode(rawValue: sender.selectedItem?.tag ?? ViewerMode.stack2D.rawValue) else {
            return
        }
        viewerModeSelectionHandler?(mode)
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
        mouseToolAssignments.setTool(tool, for: selectedMouseButton)
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
        let selectedTool = mouseToolAssignments.tool(for: selectedMouseButton)
        for (tool, button) in mouseToolButtons {
            let isSelected = tool == selectedTool
            button.state = isSelected ? .on : .off
            button.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = isSelected ? 1 : 0
            button.contentTintColor = tool == .tumourSeed ? nil : (isSelected ? NSColor.controlAccentColor : .white)
        }
    }

    private func mouseToolImage(for tool: MetalViewerMouseTool) -> NSImage {
        switch tool {
        case .windowLevel:
            return toolbarImage(named: "WLWW")
        case .pan:
            return toolbarImage(named: "Move")
        case .zoom:
            return toolbarImage(named: "Zoom")
        case .rotate:
            return toolbarImage(named: "Rotate")
        case .scroll:
            return toolbarImage(named: "Stack")
        case .tumourSeed:
            return tumourSeedTargetImage()
        }
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
        case .tumourSeed:
            return NSLocalizedString("Tumour Seed", comment: "")
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
        case .tumourSeed:
            return NSLocalizedString("Tumour Seed: click a tumour focus to place a seed point used by segmentation.", comment: "")
        }
    }

    private func tumourSeedTargetImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let outerRect = NSRect(x: 3, y: 3, width: 18, height: 18)
        let middleRect = outerRect.insetBy(dx: 4, dy: 4)
        let innerRect = outerRect.insetBy(dx: 7, dy: 7)

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: outerRect).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: middleRect).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: innerRect).fill()

        let crosshair = NSBezierPath()
        crosshair.lineWidth = 1.4
        crosshair.move(to: CGPoint(x: center.x, y: 1.5))
        crosshair.line(to: CGPoint(x: center.x, y: 6))
        crosshair.move(to: CGPoint(x: center.x, y: 18))
        crosshair.line(to: CGPoint(x: center.x, y: 22.5))
        crosshair.move(to: CGPoint(x: 1.5, y: center.y))
        crosshair.line(to: CGPoint(x: 6, y: center.y))
        crosshair.move(to: CGPoint(x: 18, y: center.y))
        crosshair.line(to: CGPoint(x: 22.5, y: center.y))
        NSColor.white.setStroke()
        crosshair.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
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

    private func makeIconButtonContent(imageName: String, alternateImageName: String? = nil) -> NSView {
        let button = NSButton(image: toolbarImage(named: imageName), target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = true
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        if let alternateImageName {
            button.alternateImage = toolbarImage(named: alternateImageName)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 46),
            container.heightAnchor.constraint(equalToConstant: 42),

            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])
        return container
    }

    private func makeToolbarRadio(_ title: String, selected: Bool, size: CGFloat = 11) -> NSView {
        let button = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        button.font = NSFont.systemFont(ofSize: size)
        button.state = selected ? .on : .off
        button.setButtonType(.radio)
        return button
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
