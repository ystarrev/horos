import AppKit

final class Metal3DViewerToolbarController: NSObject, NSToolbarDelegate {
    enum ItemIdentifier {
        static let crop = NSToolbarItem.Identifier("com.horos.metal3d.crop")
        static let shading = NSToolbarItem.Identifier("com.horos.metal3d.shading")
        static let skin = NSToolbarItem.Identifier("com.horos.metal3d.skin")
        static let skinSurface = NSToolbarItem.Identifier("com.horos.metal3d.skinSurface")
        static let skinDepth = NSToolbarItem.Identifier("com.horos.metal3d.skinDepth")
        static let tumorSegmentation = NSToolbarItem.Identifier("com.horos.metal3d.tumorSegmentation")
        static let tumorVisibility = NSToolbarItem.Identifier("com.horos.metal3d.tumorVisibility")
        static let tumorLabel = NSToolbarItem.Identifier("com.horos.metal3d.tumorLabel")
        static let tumorInfo = NSToolbarItem.Identifier("com.horos.metal3d.tumorInfo")
        static let tumorClear = NSToolbarItem.Identifier("com.horos.metal3d.tumorClear")
        static let surgicalTrajectory = NSToolbarItem.Identifier("com.horos.metal3d.surgicalTrajectory")
        static let histogram = NSToolbarItem.Identifier("com.horos.metal3d.histogram")
        static let wlww = NSToolbarItem.Identifier("com.horos.metal3d.wlww")
        static let clut = NSToolbarItem.Identifier("com.horos.metal3d.clut")
        static let opacity = NSToolbarItem.Identifier("com.horos.metal3d.opacity")
    }

    var cropHandler: ((Bool) -> Void)?
    var shadingHandler: ((Bool) -> Void)?
    var skinHandler: ((Bool) -> Void)?
    var skinSurfaceHandler: ((Bool) -> Void)?
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
    private let skinCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Show Skin", comment: ""), target: nil, action: nil)
    private let skinSurfaceCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Surface", comment: ""), target: nil, action: nil)
    private let skinDepthSlider = NSSlider(value: 6.0, minValue: 0.0, maxValue: 20.0, target: nil, action: nil)
    private let skinDepthValueLabel = NSTextField(labelWithString: "")
    private let tumorVisibilityCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Show Tumour", comment: ""), target: nil, action: nil)
    private var cropEnabled = false
    private var shadingEnabled = true
    private var skinEnabled = true
    private var skinSurfaceEnabled = false
    private var skinClipDepthMM: Float = 6.0
    private var tumorVisible = true
    private var surgicalTrajectoryAvailable = false
    private weak var surgicalTrajectoryItem: NSToolbarItem?

    override init() {
        super.init()
        configurePopUp(wlwwPopup)
        configurePopUp(clutPopup)
        configurePopUp(opacityPopup)
        configureTumorLabelPopup()
        skinCheckbox.controlSize = .small
        skinCheckbox.font = NSFont.systemFont(ofSize: 12)
        skinCheckbox.state = .on
        skinCheckbox.target = self
        skinCheckbox.action = #selector(toggleSkin(_:))
        skinSurfaceCheckbox.controlSize = .small
        skinSurfaceCheckbox.font = NSFont.systemFont(ofSize: 12)
        skinSurfaceCheckbox.state = .off
        skinSurfaceCheckbox.target = self
        skinSurfaceCheckbox.action = #selector(toggleSkinSurface(_:))
        skinDepthSlider.controlSize = .small
        skinDepthSlider.numberOfTickMarks = 6
        skinDepthSlider.allowsTickMarkValuesOnly = false
        skinDepthSlider.isContinuous = false
        skinDepthSlider.target = self
        skinDepthSlider.action = #selector(skinDepthDidChange(_:))
        skinDepthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        skinDepthValueLabel.textColor = NSColor.secondaryLabelColor
        skinDepthValueLabel.alignment = .right
        tumorVisibilityCheckbox.controlSize = .small
        tumorVisibilityCheckbox.font = NSFont.systemFont(ofSize: 12)
        tumorVisibilityCheckbox.state = .on
        tumorVisibilityCheckbox.target = self
        tumorVisibilityCheckbox.action = #selector(toggleTumorVisibility(_:))
        setSkinClipDepthMM(skinClipDepthMM)
    }

    func configure(wlwwPresetNames: [String], clutNames: [String], opacityNames: [String]) {
        let wlwwItems = [
            NSLocalizedString("Other", comment: ""),
            NSLocalizedString("Default WL & WW", comment: ""),
            NSLocalizedString("Full dynamic", comment: ""),
        ] + wlwwPresetNames.map { "- \($0)" }
        reload(popUp: wlwwPopup, items: wlwwItems)

        let clutItems = [NSLocalizedString("No CLUT", comment: "")] + clutNames
        reload(popUp: clutPopup, items: clutItems)

        let opacityItems = [NSLocalizedString("Linear Table", comment: "")] + opacityNames
        reload(popUp: opacityPopup, items: opacityItems)
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
        skinDepthSlider.floatValue = skinClipDepthMM
        skinDepthValueLabel.stringValue = String(format: "%.1f mm", skinClipDepthMM)
    }

    func selectAllTumorLabels() {
        tumorLabelPopup.selectItem(withTitle: NSLocalizedString("All", comment: ""))
    }

    func setSurgicalTrajectoryAvailable(_ isAvailable: Bool) {
        surgicalTrajectoryAvailable = isAvailable
        surgicalTrajectoryItem?.isEnabled = isAvailable
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.crop,
            ItemIdentifier.shading,
            ItemIdentifier.skin,
            ItemIdentifier.skinSurface,
            ItemIdentifier.skinDepth,
            ItemIdentifier.tumorSegmentation,
            ItemIdentifier.tumorVisibility,
            ItemIdentifier.tumorLabel,
            ItemIdentifier.tumorInfo,
            ItemIdentifier.tumorClear,
            ItemIdentifier.surgicalTrajectory,
            ItemIdentifier.histogram,
            ItemIdentifier.wlww,
            ItemIdentifier.clut,
            ItemIdentifier.opacity,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.crop,
            ItemIdentifier.shading,
            ItemIdentifier.skin,
            ItemIdentifier.skinSurface,
            ItemIdentifier.skinDepth,
            ItemIdentifier.tumorSegmentation,
            ItemIdentifier.tumorVisibility,
            ItemIdentifier.tumorLabel,
            ItemIdentifier.tumorInfo,
            ItemIdentifier.tumorClear,
            ItemIdentifier.surgicalTrajectory,
            ItemIdentifier.histogram,
            ItemIdentifier.wlww,
            ItemIdentifier.clut,
            ItemIdentifier.opacity,
            .flexibleSpace,
            .space,
        ]
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

        case ItemIdentifier.skin:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Skin", comment: "")
            item.paletteLabel = NSLocalizedString("Show Skin", comment: "")
            item.toolTip = NSLocalizedString("Show or hide the extracted outer skin shell", comment: "")
            skinCheckbox.state = skinEnabled ? .on : .off
            item.view = skinCheckbox
            return item

        case ItemIdentifier.skinSurface:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Surface", comment: "")
            item.paletteLabel = NSLocalizedString("Show Skin Surface", comment: "")
            item.toolTip = NSLocalizedString("Show or hide the red extracted skin boundary surface", comment: "")
            skinSurfaceCheckbox.state = skinSurfaceEnabled ? .on : .off
            item.view = skinSurfaceCheckbox
            return item

        case ItemIdentifier.skinDepth:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Clip", comment: "")
            item.paletteLabel = NSLocalizedString("Skin Clip Depth", comment: "")
            item.toolTip = NSLocalizedString("Adjust how many millimeters inward from the extracted skin boundary are clipped", comment: "")
            item.view = makeSkinDepthSlider(width: 170)
            return item

        case ItemIdentifier.tumorSegmentation:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Run Tumour", comment: "")
            item.paletteLabel = NSLocalizedString("Run Tumour Segmentation", comment: "")
            item.toolTip = NSLocalizedString("Run a local tumour segmentation helper and show the returned labelmap", comment: "")
            item.target = self
            item.action = #selector(runTumorSegmentation(_:))
            item.image = NSImage(systemSymbolName: "cross.case", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.tumorVisibility:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Tumour", comment: "")
            item.paletteLabel = NSLocalizedString("Show Tumour Segmentation", comment: "")
            item.toolTip = NSLocalizedString("Show or hide the loaded tumour segmentation surfaces", comment: "")
            tumorVisibilityCheckbox.state = tumorVisible ? .on : .off
            item.view = tumorVisibilityCheckbox
            return item

        case ItemIdentifier.tumorLabel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Label", comment: "")
            item.paletteLabel = NSLocalizedString("Tumour Label Filter", comment: "")
            item.toolTip = NSLocalizedString("Choose which tumour segmentation label surface is shown", comment: "")
            item.view = makeLabeledPopup(title: item.label, popup: tumorLabelPopup, width: 150)
            return item

        case ItemIdentifier.tumorInfo:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Info", comment: "")
            item.paletteLabel = NSLocalizedString("Tumour Segmentation Info", comment: "")
            item.toolTip = NSLocalizedString("Show statistics and metadata for the current tumour segmentation", comment: "")
            item.target = self
            item.action = #selector(showTumorInfo(_:))
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.tumorClear:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Clear", comment: "")
            item.paletteLabel = NSLocalizedString("Clear Tumour Segmentation", comment: "")
            item.toolTip = NSLocalizedString("Remove the currently loaded tumour segmentation surfaces", comment: "")
            item.target = self
            item.action = #selector(clearTumorSegmentation(_:))
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: item.label)
            return item

        case ItemIdentifier.surgicalTrajectory:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Trajectory", comment: "")
            item.paletteLabel = NSLocalizedString("Surgical Trajectory", comment: "")
            item.toolTip = NSLocalizedString("Show the initial tumour-centre to skin-surface surgical trajectory", comment: "")
            item.target = self
            item.action = #selector(showSurgicalTrajectory(_:))
            item.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: item.label)
            item.isEnabled = surgicalTrajectoryAvailable
            surgicalTrajectoryItem = item
            return item

        case ItemIdentifier.histogram:
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
            item.view = makeLabeledPopup(title: item.label, popup: wlwwPopup, width: 220)
            return item

        case ItemIdentifier.clut:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("CLUT", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Pseudo color lookup table presets", comment: "")
            item.view = makeLabeledPopup(title: item.label, popup: clutPopup, width: 220)
            return item

        case ItemIdentifier.opacity:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("Opacity", comment: "")
            item.paletteLabel = item.label
            item.toolTip = NSLocalizedString("Opacity presets", comment: "")
            item.view = makeLabeledPopup(title: item.label, popup: opacityPopup, width: 220)
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
    private func toggleSkin(_ sender: NSButton) {
        skinEnabled = sender.state == .on
        skinHandler?(skinEnabled)
    }

    @objc
    private func toggleSkinSurface(_ sender: NSButton) {
        skinSurfaceEnabled = sender.state == .on
        skinSurfaceHandler?(skinSurfaceEnabled)
    }

    @objc
    private func skinDepthDidChange(_ sender: NSSlider) {
        setSkinClipDepthMM(sender.floatValue)
        skinClipDepthHandler?(skinClipDepthMM)
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
    private func toggleTumorVisibility(_ sender: NSButton) {
        tumorVisible = sender.state == .on
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

    private func configurePopUp(_ popup: NSPopUpButton) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
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

    private func makeLabeledPopup(title: String, popup: NSPopUpButton, width: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor

        let stack = NSStackView(views: [label, popup])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeSkinDepthSlider(width: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: NSLocalizedString("Clip", comment: ""))
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor

        let header = NSStackView(views: [label, skinDepthValueLabel])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        skinDepthValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        skinDepthSlider.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, skinDepthSlider])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            skinDepthSlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }
}
