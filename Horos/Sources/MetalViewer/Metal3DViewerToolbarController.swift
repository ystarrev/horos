import AppKit

struct Metal3DViewerContentCapabilities {
    let modalities: Set<String>
    let activeModality: String

    init(pixList: [DCMPix]) {
        let orderedModalities = pixList.compactMap { pix -> String? in
            guard let modality = pix.modalityString?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
                  modality.isEmpty == false else {
                return nil
            }
            return modality
        }
        var modalities = Set<String>(orderedModalities)
        if pixList.contains(where: { $0.rescaleType?.uppercased() == "HU" }) {
            modalities.insert("CT")
        }
        self.modalities = modalities
        self.activeModality = orderedModalities.first
            ?? (modalities.contains("CT") ? "CT" : modalities.sorted().first ?? "OT")
    }

    var containsCT: Bool {
        modalities.contains("CT")
    }

    var containsMRI: Bool {
        modalities.contains("MR") || modalities.contains("MRI")
    }

    var hasVisibilityOptions: Bool {
        containsCT || containsMRI
    }

    var toolbarConfigurationSuffix: String {
        switch (containsCT, containsMRI) {
        case (true, true):
            return "CTMR"
        case (true, false):
            return "CT"
        case (false, true):
            return "MR"
        default:
            return "Other"
        }
    }
}

final class Metal3DViewerToolbarController: NSObject, NSToolbarDelegate {
    enum ItemIdentifier {
        static let crop = NSToolbarItem.Identifier("com.horos.metal3d.crop")
        static let shading = NSToolbarItem.Identifier("com.horos.metal3d.shading")
        static let visibility = NSToolbarItem.Identifier("com.horos.metal3d.visibility")
        static let tumorActions = NSToolbarItem.Identifier("com.horos.metal3d.tumorActions")
        static let tumorLabel = NSToolbarItem.Identifier("com.horos.metal3d.tumorLabel")
        static let histogram = NSToolbarItem.Identifier("com.horos.metal3d.histogram")
        static let wlww = NSToolbarItem.Identifier("com.horos.metal3d.wlww")
        static let clut = NSToolbarItem.Identifier("com.horos.metal3d.clut")
        static let opacity = NSToolbarItem.Identifier("com.horos.metal3d.opacity")
    }

    var cropHandler: ((Bool) -> Void)?
    var shadingHandler: ((Bool) -> Void)?
    var skinHandler: ((Bool) -> Void)?
    var skinSurfaceHandler: ((Bool) -> Void)?
    var metalVisibilityHandler: ((Bool) -> Void)?
    var skinClipDepthHandler: ((Float) -> Void)?
    var tumorSegmentationHandler: (() -> Void)?
    var tumorVisibilityHandler: ((Bool) -> Void)?
    var tumorLabelFilterHandler: ((Set<UInt8>?) -> Void)?
    var tumorInfoHandler: (() -> Void)?
    var tumorClearHandler: (() -> Void)?
    var surgicalTrajectoryHandler: (() -> Void)?
    var histogramHandler: (() -> Void)?
    var wlwwSelectionHandler: ((String) -> Void)?
    var clutSelectionHandler: ((String) -> Void)?
    var opacitySelectionHandler: ((String) -> Void)?

    private let wlwwPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tumorLabelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let visibilityMenu = NSMenu(title: NSLocalizedString("Visibility", comment: ""))
    private let tumorActionsMenu = NSMenu(title: NSLocalizedString("Tumour", comment: ""))
    private var contentCapabilities = Metal3DViewerContentCapabilities(pixList: [])
    private var activeModality = "OT"
    private var wlwwPresetNames = [String]()
    private var cropEnabled = false
    private var shadingEnabled = true
    private var skinEnabled = true
    private var skinSurfaceEnabled = false
    private var metalVisible = true
    private var skinClipDepthMM: Float = 6.0
    private var tumorVisible = true
    private var surgicalTrajectoryAvailable = false
    private weak var surgicalTrajectoryMenuItem: NSMenuItem?

    override init() {
        super.init()
        configurePopUp(wlwwPopup)
        configurePopUp(clutPopup)
        configurePopUp(opacityPopup)
        configureTumorLabelPopup()
    }

    func configure(
        contentCapabilities: Metal3DViewerContentCapabilities,
        activeModality: String,
        wlwwPresetNames: [String],
        clutNames: [String],
        opacityNames: [String]
    ) {
        self.contentCapabilities = contentCapabilities
        self.activeModality = activeModality.uppercased()
        self.wlwwPresetNames = wlwwPresetNames
        metalVisible = contentCapabilities.containsCT == false

        reloadWLPresetMenu()

        let clutItems = [NSLocalizedString("No CLUT", comment: "")] + clutNames
        reload(popUp: clutPopup, items: clutItems)

        let opacityItems = [NSLocalizedString("Linear Table", comment: "")] + opacityNames
        reload(popUp: opacityPopup, items: opacityItems)
        rebuildVisibilityMenu()
        rebuildTumorActionsMenu()
    }

    func setActiveModality(_ modality: String) {
        activeModality = modality.uppercased()
        reloadWLPresetMenu()
    }

    func selectWLPreset(named name: String) {
        selectItem(named: name, in: wlwwPopup)
    }

    func selectCLUT(named name: String) {
        selectItem(named: name, in: clutPopup)
    }

    func selectOpacity(named name: String) {
        selectItem(named: name, in: opacityPopup)
    }

    func setSkinClipDepthMM(_ depth: Float) {
        skinClipDepthMM = min(max(depth, 0), 20)
        rebuildVisibilityMenu()
    }

    func selectAllTumorLabels() {
        tumorLabelPopup.selectItem(withTitle: NSLocalizedString("All", comment: ""))
    }

    func setSurgicalTrajectoryAvailable(_ isAvailable: Bool) {
        surgicalTrajectoryAvailable = isAvailable
        surgicalTrajectoryMenuItem?.isEnabled = isAvailable
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            ItemIdentifier.crop,
            ItemIdentifier.shading,
        ]
        if contentCapabilities.hasVisibilityOptions {
            identifiers.append(ItemIdentifier.visibility)
        }
        if contentCapabilities.containsMRI {
            identifiers.append(ItemIdentifier.tumorActions)
            identifiers.append(ItemIdentifier.tumorLabel)
        }
        if contentCapabilities.containsCT {
            identifiers.append(ItemIdentifier.histogram)
        }
        identifiers += [
            .flexibleSpace,
            ItemIdentifier.wlww,
            ItemIdentifier.clut,
            ItemIdentifier.opacity,
        ]
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            ItemIdentifier.crop,
            ItemIdentifier.shading,
            ItemIdentifier.wlww,
            ItemIdentifier.clut,
            ItemIdentifier.opacity,
            .flexibleSpace,
            .space,
        ]
        if contentCapabilities.hasVisibilityOptions {
            identifiers.insert(ItemIdentifier.visibility, at: 2)
        }
        if contentCapabilities.containsMRI {
            identifiers.insert(ItemIdentifier.tumorActions, at: 3)
            identifiers.insert(ItemIdentifier.tumorLabel, at: 4)
        }
        if contentCapabilities.containsCT {
            identifiers.insert(ItemIdentifier.histogram, at: min(identifiers.count, 5))
        }
        return identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemIdentifier.crop:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Crop", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Show and manipulate cropping cube", comment: "")
            item.target = self
            item.action = #selector(toggleCrop(_:))
            item.image = NSImage(systemSymbolName: "crop", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.shading:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Shading", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Toggle volume shading", comment: "")
            item.target = self
            item.action = #selector(toggleShading(_:))
            item.image = NSImage(systemSymbolName: shadingEnabled ? "lightbulb.max.fill" : "lightbulb.slash", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.visibility:
            guard contentCapabilities.hasVisibilityOptions else { return nil }
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Visibility", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Choose which structures from the loaded modalities are visible", comment: "")
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: item.label)
            item.menu = visibilityMenu
            item.target = self
            item.action = #selector(showVisibilityMenu(_:))
            return item

        case ItemIdentifier.tumorActions:
            guard contentCapabilities.containsMRI else { return nil }
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Tumour", comment: "")
            item.paletteLabel = NSLocalizedString("Tumour Tools", comment: "")
            item.toolTip = NSLocalizedString("Tumour segmentation and surgical planning tools", comment: "")
            item.image = NSImage(systemSymbolName: "cross.case", accessibilityDescription: item.label)
            item.menu = tumorActionsMenu
            item.target = self
            item.action = #selector(showTumorActionsMenu(_:))
            return item

        case ItemIdentifier.tumorLabel:
            guard contentCapabilities.containsMRI else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Label", comment: "")
            item.paletteLabel = NSLocalizedString("Tumour Label Filter", comment: "")
            item.toolTip = NSLocalizedString("Choose which tumour segmentation label surface is shown", comment: "")
            item.view = makeToolbarPopup(tumorLabelPopup, width: 150)
            return item

        case ItemIdentifier.histogram:
            guard contentCapabilities.containsCT else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Histogram", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Show the CT voxel histogram", comment: "")
            item.target = self
            item.action = #selector(toggleHistogram(_:))
            item.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.wlww:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("WL/WW", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Window level and width presets", comment: "")
            item.view = makeToolbarPopup(wlwwPopup, width: 190)
            return item

        case ItemIdentifier.clut:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("CLUT", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Pseudo color lookup table presets", comment: "")
            item.view = makeToolbarPopup(clutPopup, width: 180)
            return item

        case ItemIdentifier.opacity:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Opacity", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Opacity presets", comment: "")
            item.view = makeToolbarPopup(opacityPopup, width: 200)
            return item

        default:
            return nil
        }
    }

    @objc
    private func toggleCrop(_ sender: Any?) {
        cropEnabled.toggle()
        cropHandler?(cropEnabled)
    }

    @objc
    private func toggleShading(_ sender: Any?) {
        shadingEnabled.toggle()
        if let item = sender as? NSToolbarItem {
            item.image = NSImage(
                systemSymbolName: shadingEnabled ? "lightbulb.max.fill" : "lightbulb.slash",
                accessibilityDescription: item.label
            )
        }
        shadingHandler?(shadingEnabled)
    }

    @objc
    private func showVisibilityMenu(_ sender: Any?) {
        visibilityMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc
    private func showTumorActionsMenu(_ sender: Any?) {
        tumorActionsMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc
    private func toggleSkin(_ sender: NSMenuItem) {
        skinEnabled.toggle()
        sender.state = skinEnabled ? .on : .off
        skinHandler?(skinEnabled)
    }

    @objc
    private func toggleSkinSurface(_ sender: NSMenuItem) {
        skinSurfaceEnabled.toggle()
        sender.state = skinSurfaceEnabled ? .on : .off
        skinSurfaceHandler?(skinSurfaceEnabled)
    }

    @objc
    private func skinDepthDidChange(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        setSkinClipDepthMM(number.floatValue)
        skinClipDepthHandler?(skinClipDepthMM)
    }

    @objc
    private func toggleMetalVisibility(_ sender: NSMenuItem) {
        metalVisible = sender.state != .on
        sender.state = metalVisible ? .on : .off
        metalVisibilityHandler?(metalVisible)
    }

    @objc
    private func toggleHistogram(_ sender: Any?) {
        histogramHandler?()
    }

    @objc
    private func runTumorSegmentation(_ sender: Any?) {
        tumorSegmentationHandler?()
    }

    @objc
    private func toggleTumorVisibility(_ sender: NSMenuItem) {
        tumorVisible.toggle()
        sender.state = tumorVisible ? .on : .off
        tumorVisibilityHandler?(tumorVisible)
    }

    @objc
    private func clearTumorSegmentation(_ sender: Any?) {
        tumorClearHandler?()
    }

    @objc
    private func showTumorInfo(_ sender: Any?) {
        tumorInfoHandler?()
    }

    @objc
    private func showSurgicalTrajectory(_ sender: Any?) {
        surgicalTrajectoryHandler?()
    }

    @objc
    private func tumorLabelSelectionDidChange(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            tumorLabelFilterHandler?(Set([1, 2, 4]))
        case 2:
            tumorLabelFilterHandler?(Set([1, 4]))
        case 3:
            tumorLabelFilterHandler?(Set([2]))
        case 4:
            tumorLabelFilterHandler?(Set([4]))
        case 5:
            tumorLabelFilterHandler?(Set([1]))
        case 6:
            tumorLabelFilterHandler?(Set([3]))
        default:
            tumorLabelFilterHandler?(nil)
        }
    }

    @objc
    private func wlwwSelectionDidChange(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        wlwwSelectionHandler?(title)
    }

    @objc
    private func clutSelectionDidChange(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        clutSelectionHandler?(title)
    }

    @objc
    private func opacitySelectionDidChange(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        opacitySelectionHandler?(title)
    }

    private func rebuildVisibilityMenu() {
        visibilityMenu.autoenablesItems = false
        visibilityMenu.removeAllItems()

        if contentCapabilities.containsMRI {
            visibilityMenu.addItem(
                checkableMenuItem(
                    title: NSLocalizedString("Show Skin", comment: ""),
                    action: #selector(toggleSkin(_:)),
                    isOn: skinEnabled
                )
            )
            visibilityMenu.addItem(
                checkableMenuItem(
                    title: NSLocalizedString("Show Surface", comment: ""),
                    action: #selector(toggleSkinSurface(_:)),
                    isOn: skinSurfaceEnabled
                )
            )
            visibilityMenu.addItem(
                checkableMenuItem(
                    title: NSLocalizedString("Show Tumour", comment: ""),
                    action: #selector(toggleTumorVisibility(_:)),
                    isOn: tumorVisible
                )
            )

            let depthItem = NSMenuItem(
                title: NSLocalizedString("Skin Clip Depth", comment: ""),
                action: nil,
                keyEquivalent: ""
            )
            let depthMenu = NSMenu(title: depthItem.title)
            var depthValues: [Float] = [0, 2, 4, 6, 8, 10, 12, 15, 20]
            if depthValues.contains(where: { abs($0 - skinClipDepthMM) < 0.01 }) == false {
                depthValues.append(skinClipDepthMM)
                depthValues.sort()
            }
            for depth in depthValues {
                let item = NSMenuItem(
                    title: String(format: "%.1f mm", depth),
                    action: #selector(skinDepthDidChange(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: depth)
                item.state = abs(depth - skinClipDepthMM) < 0.01 ? .on : .off
                depthMenu.addItem(item)
            }
            depthItem.submenu = depthMenu
            visibilityMenu.addItem(.separator())
            visibilityMenu.addItem(depthItem)
        }

        if contentCapabilities.containsCT {
            if visibilityMenu.items.isEmpty == false {
                visibilityMenu.addItem(.separator())
            }
            visibilityMenu.addItem(
                checkableMenuItem(
                    title: NSLocalizedString("Show Metal", comment: ""),
                    action: #selector(toggleMetalVisibility(_:)),
                    isOn: metalVisible
                )
            )
        }
    }

    private func rebuildTumorActionsMenu() {
        tumorActionsMenu.autoenablesItems = false
        tumorActionsMenu.removeAllItems()
        surgicalTrajectoryMenuItem = nil
        guard contentCapabilities.containsMRI else { return }

        tumorActionsMenu.addItem(
            actionMenuItem(
                title: NSLocalizedString("Run Tumour Segmentation", comment: ""),
                action: #selector(runTumorSegmentation(_:))
            )
        )
        tumorActionsMenu.addItem(
            actionMenuItem(
                title: NSLocalizedString("Segmentation Information", comment: ""),
                action: #selector(showTumorInfo(_:))
            )
        )
        tumorActionsMenu.addItem(
            actionMenuItem(
                title: NSLocalizedString("Clear Tumour Segmentation", comment: ""),
                action: #selector(clearTumorSegmentation(_:))
            )
        )
        tumorActionsMenu.addItem(.separator())
        let trajectoryItem = actionMenuItem(
            title: NSLocalizedString("Show Initial Surgical Trajectory", comment: ""),
            action: #selector(showSurgicalTrajectory(_:))
        )
        trajectoryItem.isEnabled = surgicalTrajectoryAvailable
        tumorActionsMenu.addItem(trajectoryItem)
        surgicalTrajectoryMenuItem = trajectoryItem
    }

    private func checkableMenuItem(title: String, action: Selector, isOn: Bool) -> NSMenuItem {
        let item = actionMenuItem(title: title, action: action)
        item.state = isOn ? .on : .off
        return item
    }

    private func actionMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func reloadWLPresetMenu() {
        let items = [
            NSLocalizedString("Other", comment: ""),
            NSLocalizedString("Default WL & WW", comment: ""),
            NSLocalizedString("Full dynamic", comment: ""),
        ] + wlwwPresetNames
            .filter { shouldShowWLPreset(named: $0, modality: activeModality) }
            .map { "- \($0)" }
        reload(popUp: wlwwPopup, items: items)
    }

    private func shouldShowWLPreset(named name: String, modality: String) -> Bool {
        let uppercasedName = name.uppercased()
        let knownPrefixes = ["CT", "MR", "MRI", "PT", "PET", "NM", "US", "XA", "RF", "CR", "DX", "MG"]
        let matchingPrefixes = knownPrefixes.filter {
            uppercasedName == $0
                || uppercasedName.hasPrefix("\($0) ")
                || uppercasedName.hasPrefix("\($0)-")
        }

        guard matchingPrefixes.isEmpty == false else { return true }
        if modality == "MR" || modality == "MRI" {
            return matchingPrefixes.contains("MR") || matchingPrefixes.contains("MRI")
        }
        if modality == "PT" {
            return matchingPrefixes.contains("PT") || matchingPrefixes.contains("PET")
        }
        return matchingPrefixes.contains(modality)
    }

    private func configurePopUp(_ popup: NSPopUpButton) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.bezelStyle = .regularSquare
        popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    private func configureTumorLabelPopup() {
        tumorLabelPopup.translatesAutoresizingMaskIntoConstraints = false
        tumorLabelPopup.controlSize = .small
        tumorLabelPopup.removeAllItems()
        tumorLabelPopup.addItems(withTitles: [
            NSLocalizedString("All", comment: ""),
            NSLocalizedString("Whole", comment: ""),
            NSLocalizedString("Core", comment: ""),
            NSLocalizedString("Edema", comment: ""),
            NSLocalizedString("Enhancing", comment: ""),
            NSLocalizedString("Non-enhancing", comment: ""),
            NSLocalizedString("Other", comment: ""),
        ])
        tumorLabelPopup.target = self
        tumorLabelPopup.action = #selector(tumorLabelSelectionDidChange(_:))
        tumorLabelPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    private func reload(popUp: NSPopUpButton, items: [String]) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: items)
        if popUp === wlwwPopup {
            popUp.target = self
            popUp.action = #selector(wlwwSelectionDidChange(_:))
        } else if popUp === clutPopup {
            popUp.target = self
            popUp.action = #selector(clutSelectionDidChange(_:))
        } else {
            popUp.target = self
            popUp.action = #selector(opacitySelectionDidChange(_:))
        }
    }

    private func selectItem(named name: String, in popup: NSPopUpButton) {
        if popup.itemTitles.contains(name) {
            popup.selectItem(withTitle: name)
            return
        }

        let prefixedName = "- \(name)"
        if popup.itemTitles.contains(prefixedName) {
            popup.selectItem(withTitle: prefixedName)
        }
    }

    private func makeToolbarPopup(_ popup: NSPopUpButton, width: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(popup)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: 30),
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.heightAnchor.constraint(equalToConstant: 26),
        ])

        return container
    }

}
