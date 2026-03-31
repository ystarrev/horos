import AppKit

final class Metal3DViewerToolbarController: NSObject, NSToolbarDelegate {
    enum ItemIdentifier {
        static let crop = NSToolbarItem.Identifier("com.horos.metal3d.crop")
        static let wlww = NSToolbarItem.Identifier("com.horos.metal3d.wlww")
        static let clut = NSToolbarItem.Identifier("com.horos.metal3d.clut")
        static let opacity = NSToolbarItem.Identifier("com.horos.metal3d.opacity")
    }

    var cropHandler: ((Bool) -> Void)?
    var wlwwSelectionHandler: ((String) -> Void)?
    var clutSelectionHandler: ((String) -> Void)?
    var opacitySelectionHandler: ((String) -> Void)?

    private let wlwwPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var cropEnabled = false

    override init() {
        super.init()
        configurePopUp(wlwwPopup)
        configurePopUp(clutPopup)
        configurePopUp(opacityPopup)
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.crop,
            ItemIdentifier.wlww,
            ItemIdentifier.clut,
            ItemIdentifier.opacity,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.crop,
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
}
