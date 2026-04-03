import AppKit
import CoreData

final class Metal3DViewerWindowController: NSWindowController, NSWindowDelegate {
    private let volumeView = Metal3DVolumeView(frame: .zero)
    private let toolbarController = Metal3DViewerToolbarController()
    private let histogramPanelController = Metal3DHistogramPanelController()
    private let pixList: [DCMPix]
    private let volumeData: Data

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

    func presentAndZoomWindow() {
        showWindow(NSApp)
        window?.makeKeyAndOrderFront(NSApp)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.zoom(nil)
        }
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
        toolbarController.histogramHandler = { [weak self] in
            self?.toggleHistogramPanel()
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
        histogramPanelController.update(histogram: volumeView.makeHistogramModel())
    }

    private func toggleHistogramPanel() {
        histogramPanelController.update(histogram: volumeView.makeHistogramModel())
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

    func windowWillClose(_ notification: Notification) {
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
}
