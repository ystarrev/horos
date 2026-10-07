import AppKit
import CoreData
import Metal
import UniformTypeIdentifiers
import simd

private final class FrameSidebarStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(HorosFrameViewerLauncher)
final class FrameViewerLauncher: NSObject {
    private static var controllers: [FrameViewerWindowController] = []

    @objc class func visibleWindows() -> [NSWindow] {
        controllers.compactMap(\.window).filter(\.isVisible)
    }

    @objc class func closeAllWindows() {
        controllers.compactMap(\.window).forEach { $0.performClose(nil) }
    }

    @objc class func savePlansBeforeClosing() -> Bool {
        controllers.allSatisfy { controller in
            guard let window = controller.window else { return true }
            return controller.windowShouldClose(window)
        }
    }

    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        precondition(Thread.isMainThread)
        do {
            guard let frames = context["pixList"] as? [DCMPix], frames.count >= 2 else {
                throw FramePlanError.invalid("Select one complete MRI or CT image series for Frame planning.")
            }
            var studyUID = "", seriesUID = "", frameUID = ""
            var sops = Set<String>()
            for pix in frames {
                guard let path = pix.srcFile,
                      let reader = try? SwiftDICOMReader.cached(contentsOfFile: path),
                      let study = reader.stringValue(forTag: "0020,000D"), !study.isEmpty,
                      let series = reader.stringValue(forTag: "0020,000E"), !series.isEmpty,
                      let frame = reader.stringValue(forTag: "0020,0052"), !frame.isEmpty,
                      let sop = reader.stringValue(forTag: "0008,0018"), !sop.isEmpty,
                      ["MR", "CT"].contains(reader.stringValue(forTag: "0008,0060") ?? ""),
                      MetalViewerSliceGeometry(pix: pix) != nil else {
                    throw FramePlanError.invalid("Frame requires MRI or CT images with patient-space geometry and DICOM identifiers.")
                }
                if seriesUID.isEmpty { studyUID = study; seriesUID = series; frameUID = frame }
                guard study == studyUID, series == seriesUID, frame == frameUID else {
                    throw FramePlanError.invalid("Select a single image series, not multiple studies or series.")
                }
                sops.insert("\(sop)#\(pix.frameNo)")
            }
            let reference = FrameImageReference(studyInstanceUID: studyUID, seriesInstanceUID: seriesUID,
                frameOfReferenceUID: frameUID, frameIdentifiers: sops.sorted(), frameCount: frames.count)
            let title = context["title"] as? String ?? "Frame"
            // Repeated spatial locations imply a dynamic/multi-echo stack, not a planning volume.
            let geometries = frames.compactMap { MetalViewerSliceGeometry(pix: $0) }
            guard let first = geometries.first,
                  geometries.allSatisfy({ simd_dot($0.row, first.row) > 0.999
                      && simd_dot($0.column, first.column) > 0.999
                      && $0.width == first.width && $0.height == first.height
                      && abs($0.spacingX - first.spacingX) < 0.0001
                      && abs($0.spacingY - first.spacingY) < 0.0001 }) else {
                throw FramePlanError.invalid("Frame needs one parallel image stack.")
            }
            let locations = geometries.map { simd_dot($0.origin, first.normal) }.sorted()
            guard zip(locations, locations.dropFirst()).allSatisfy({ $1 - $0 > 0.001 }) else {
                throw FramePlanError.invalid("This series contains repeated slice positions. Select a single static acquisition for planning.")
            }
            let spacing = (locations.last! - locations[0]) / Double(locations.count - 1)
            guard zip(locations, locations.dropFirst()).allSatisfy({ abs(($1 - $0) - spacing) < max(0.01, spacing * 0.02) }) else {
                throw FramePlanError.invalid("This series has missing or unevenly spaced slices. Select a complete regular image stack.")
            }
            let orderedFrames = zip(frames, geometries).sorted {
                simd_dot($0.1.origin, first.normal) < simd_dot($1.1.origin, first.normal)
            }.map { $0.0 }
            let series = MetalViewerSeries(identifier: seriesUID, patientIdentity: .fallback(title: title),
                title: title, seriesNumber: "", studyIdentifier: studyUID, studyTitle: title,
                studyDate: nil, studyNumber: 0, showsStudyHeader: false, imageObjects: [],
                isBonjour: false, initialPixList: orderedFrames)
            let store = try FramePlanSRStore(pix: orderedFrames[0], reference: reference)
            if let existing = controllers.first(where: { $0.matches(store) }) {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            let controller = try FrameViewerWindowController(series: series, reference: reference, store: store)
            controllers.append(controller)
            controller.onClose = { [weak controller] in controllers.removeAll { $0 === controller } }
            MetalViewerScreenPlacement.applyPresentationFrame(to: controller.window, display: false)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } catch { NSAlert(error: error).runModal() }
    }
}

final class FrameViewerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate {
    private var plan: FramePlan
    private var savedPlan: FramePlan
    private let store: FramePlanSRStore
    private var isReady = false
    private var pendingSaves = 0
    private var closeAfterSaving = false
    private let saveStatus = NSTextField(labelWithString: "Loading saved plan...")
    private let catalogue: [FrameElectrodeSpecification]
    private let pane: MetalViewerPaneView
    private let initialTarget: SIMD3<Double>
    private let frameInputs: [(path: String, index: Int, geometry: MetalViewerSliceGeometry)]
    private var detectionProgress: Progress?
    private var brainProgress: Progress?
    private var brainVolume: MetalBrainVolume?
    private let brainButton = NSButton(title: "Brain", target: nil, action: nil)
    private let brainStatus = NSTextField(labelWithString: "")
    private let frameStatus = NSTextField(labelWithString: "No frame detected")
    private let readFrameButton = NSButton(title: "Read Frame", target: nil, action: nil)
    private let acceptFrameButton = NSButton(title: "Accept Frame", target: nil, action: nil)
    private let table = NSTableView()
    private let model = NSPopUpButton()
    private let nameField = NSTextField()
    private var numberFields: [NSTextField] = []
    private let coordinateModeLabel = NSTextField(labelWithString: "Image LPS (mm)")
    private var coordinateButtons: [NSButton] = []
    private var angleSliders: [NSSlider] = []
    private let visible = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
    private let place = NSButton(title: "Place Target", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Image coordinates (LPS, mm) - Not frame calibrated")
    private let tools = NSSegmentedControl()
    private var selectedID: UUID?
    private var isRefreshingSelection = false
    private var planURL: URL?
    private let edits = UndoManager()
    var onClose: (() -> Void)?

    private var selectedIndex: Int? { plan.electrodes.firstIndex { $0.id == selectedID } }
    private var coordinateFrame: LeksellFrameFit? { plan.frameFit?.reviewed == true ? plan.frameFit : nil }

    func matches(_ other: FramePlanSRStore) -> Bool {
        store.reference == other.reference && store.databasePath == other.databasePath
    }

    init(series: MetalViewerSeries, reference: FrameImageReference, store: FramePlanSRStore) throws {
        self.store = store
        catalogue = try FrameElectrodeSpecification.loadCatalogue()
        plan = FramePlan(image: reference)
        savedPlan = plan
        let frames = series.loadedPixList()
        frameInputs = try frames.map { pix in
            guard let path = pix.srcFile, let geometry = MetalViewerSliceGeometry(pix: pix) else {
                throw FramePlanError.invalid("Missing frame-localizer source geometry.")
            }
            return (path, Int(pix.frameNo), geometry)
        }
        guard let geometry = MetalViewerSliceGeometry(pix: frames[frames.count / 2]) else {
            throw FramePlanError.invalid("Image geometry is unavailable.")
        }
        initialTarget = geometry.dicomPoint(pixelX: geometry.width / 2, pixelY: geometry.height / 2)
        pane = MetalViewerPaneView(series: series)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 850),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Frame - \(series.title)"
        window.minSize = NSSize(width: 920, height: 720)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HorosFrameViewer")
        pane.canClose = false
        pane.isActive = true
        pane.setDisplayMode(.mpr)
        pane.setStudyROISurfaceOpacity(1)
        pane.sliceOverlayDrawHandler = { [weak self] slices in
            guard let self else { return }
            FrameElectrodeGeometry.draw(FrameElectrodeGeometry.localizerRods(self.plan.frameFit),
                                        selectedID: nil, slices: slices, localizerStyle: true)
        }
        buildInterface(in: window)
        refresh()
        store.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let restored):
                if let restored { self.plan = restored; self.savedPlan = restored }
                self.selectedID = self.plan.electrodes.first?.id
                self.isReady = true
                self.saveStatus.stringValue = restored == nil ? "Autosave ready" : "Saved to DICOM SR"
                self.refresh()
            case .failure(let error):
                NSAlert(error: error).runModal()
                self.window?.close()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { edits }
    func windowWillClose(_ notification: Notification) {
        detectionProgress?.cancel()
        brainProgress?.cancel()
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.makeFirstResponder(nil) else { return false }
        if pendingSaves > 0 { closeAfterSaving = true; return false }
        guard plan != savedPlan else { return true }
        closeAfterSaving = true
        autosave()
        return false
    }

    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.toolTip = title
        return button
    }

    private func buildInterface(in window: NSWindow) {
        let root = NSView()
        window.contentView = root
        let bar = NSStackView(views: [button("Open Plan", "folder", #selector(openPlan)),
                                     button("Save Plan", "square.and.arrow.down", #selector(savePlan)),
                                     button("Export JSON", "square.and.arrow.up", #selector(exportPlan))])
        bar.orientation = .horizontal
        bar.spacing = 8
        tools.segmentCount = 4
        for (i, symbol) in ["circle.lefthalf.filled", "hand.draw", "plus.magnifyingglass", "rotate.3d"].enumerated() {
            tools.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: i)
            tools.setWidth(34, forSegment: i)
            tools.setToolTip(["Window/level", "Pan", "Zoom", "Rotate planes"][i], forSegment: i)
        }
        tools.selectedSegment = 3
        tools.target = self
        tools.action = #selector(changeTool)
        bar.addArrangedSubview(tools)
        let views = NSSegmentedControl(labels: ["Scene", "Slices"], trackingMode: .selectOne,
                                       target: self, action: #selector(changeView(_:)))
        views.selectedSegment = 0
        bar.addArrangedSubview(views)
        brainButton.target = self
        brainButton.action = #selector(toggleBrain)
        brainButton.setButtonType(.toggle)
        brainButton.bezelStyle = .rounded
        brainButton.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Brain")
        brainButton.imagePosition = .imageLeading
        brainButton.toolTip = "Extract or show the clipped brain volume; click again to hide or cancel"
        bar.addArrangedSubview(brainButton)
        let sidebar = FrameSidebarStackView()
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Electrode"))
        column.title = "Electrodes"
        column.width = 270
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.rowHeight = 28
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        sidebar.addArrangedSubview(scroll)
        let commands = NSStackView(views: [button("Add", "plus", #selector(addElectrode)),
                                         button("Duplicate", "plus.square.on.square", #selector(duplicateElectrode)),
                                         button("Delete", "trash", #selector(deleteElectrode))])
        commands.spacing = 4
        sidebar.addArrangedSubview(commands)
        coordinateModeLabel.font = .boldSystemFont(ofSize: 12)
        coordinateModeLabel.textColor = .systemOrange
        nameField.delegate = self
        model.addItems(withTitles: catalogue.map(\.identifier))
        model.selectItem(withTitle: "3389S-40")
        model.target = self
        model.action = #selector(changeModel)
        var rows: [[NSView]] = [[NSTextField(labelWithString: "Name"), nameField],
                               [NSTextField(labelWithString: "Model"), model],
                               [NSTextField(labelWithString: "Coordinates"), coordinateModeLabel]]
        for label in ["X (mm)", "Y (mm)", "Z (mm)", "Image azimuth", "Image declination", "Depth (mm)"] {
            let field = NSTextField()
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            numberFields.append(field)
            if numberFields.count <= 3 {
                let axis = numberFields.count - 1
                let labels = [["R", "L"], ["A", "P"], ["S", "I"]][axis]
                let controls = NSStackView(views: [field])
                controls.spacing = 4
                for (i, title) in labels.enumerated() {
                    let nudge = NSButton(title: title, target: self, action: #selector(nudgeCoordinate(_:)))
                    nudge.tag = axis * 2 + i
                    nudge.bezelStyle = .rounded
                    nudge.controlSize = .small
                    nudge.widthAnchor.constraint(equalToConstant: 25).isActive = true
                    let direction = [["right", "left"], ["anterior", "posterior"], ["superior", "inferior"]][axis][i]
                    nudge.toolTip = "Move target 1 mm \(direction) along the active coordinate axis"
                    nudge.setAccessibilityLabel("Move target 1 mm \(direction)")
                    coordinateButtons.append(nudge)
                    controls.addArrangedSubview(nudge)
                }
                controls.addArrangedSubview(NSView())
                rows.append([NSTextField(labelWithString: label), controls])
            } else if numberFields.count == 4 || numberFields.count == 5 {
                let slider = NSSlider(value: 90, minValue: 0, maxValue: 180,
                                      target: self, action: #selector(changeAngle(_:)))
                slider.tag = numberFields.count - 1
                slider.isContinuous = true
                slider.toolTip = label + " (degrees)"
                slider.setAccessibilityLabel(label)
                angleSliders.append(slider)
                let control = NSStackView(views: [field, slider])
                control.orientation = .vertical
                control.alignment = .trailing
                slider.widthAnchor.constraint(equalTo: control.widthAnchor).isActive = true
                rows.append([NSTextField(labelWithString: label), control])
            } else {
                rows.append([NSTextField(labelWithString: label), NSStackView(views: [field, NSView()])])
            }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        sidebar.addArrangedSubview(grid)
        visible.target = self
        visible.action = #selector(changeVisibility)
        sidebar.addArrangedSubview(visible)
        place.target = self
        place.action = #selector(togglePlacement)
        place.setButtonType(.toggle)
        place.bezelStyle = .rounded
        place.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Place target")
        place.imagePosition = .imageLeading
        place.toolTip = "Place the selected electrode target on a plane or slice"
        sidebar.addArrangedSubview(NSStackView(views: [place, button("Go to Target", "location", #selector(goToTarget))]))
        saveStatus.font = .systemFont(ofSize: 12)
        saveStatus.maximumNumberOfLines = 3
        saveStatus.lineBreakMode = .byWordWrapping
        sidebar.addArrangedSubview(saveStatus)
        brainStatus.font = .systemFont(ofSize: 12)
        brainStatus.maximumNumberOfLines = 3
        brainStatus.lineBreakMode = .byWordWrapping
        sidebar.addArrangedSubview(brainStatus)
        brainStatus.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        saveStatus.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        readFrameButton.target = self
        readFrameButton.action = #selector(readFrame)
        readFrameButton.bezelStyle = .rounded
        acceptFrameButton.target = self
        acceptFrameButton.action = #selector(acceptFrame)
        acceptFrameButton.bezelStyle = .rounded
        sidebar.addArrangedSubview(NSStackView(views: [readFrameButton, acceptFrameButton,
            button("Clear", "xmark", #selector(clearFrame))]))
        frameStatus.font = .systemFont(ofSize: 12)
        frameStatus.maximumNumberOfLines = 4
        frameStatus.lineBreakMode = .byWordWrapping
        sidebar.addArrangedSubview(frameStatus)
        frameStatus.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .systemOrange
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        for view in [bar, sidebarScroll, pane, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // Give spare height to the list, anchoring all editing controls below it.
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let fillSidebar = sidebar.heightAnchor.constraint(equalTo: sidebarScroll.contentView.heightAnchor)
        fillSidebar.priority = .defaultLow
        fillSidebar.isActive = true
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebarScroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 316),
            sidebarScroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            sidebar.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 300),
            sidebar.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor),
            scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            grid.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            status.leadingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor),
            status.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            pane.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 12),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            pane.topAnchor.constraint(equalTo: sidebarScroll.topAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        changeTool()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan.electrodes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let electrode = plan.electrodes[row]
        let label = NSTextField(labelWithString: electrode.name)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = electrode.isVisible ? .labelColor : .secondaryLabelColor
        guard let fit = plan.frameFit, fit.reviewed else { return label }

        let point = fit.coordinates(of: electrode.targetLPS)
        let coordinates = NSStackView(views: zip(["X", "Y", "Z"], [point.x, point.y, point.z]).map { axis, value in
            let field = NSTextField(labelWithString: String(format: "%@ %.1f", locale: Locale(identifier: "en_US_POSIX"), axis, value))
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = label.textColor
            return field
        })
        coordinates.orientation = .horizontal
        coordinates.distribution = .fillEqually
        coordinates.spacing = 4
        let cell = NSTableCellView()
        cell.textField = label
        cell.toolTip = String(format: "%@\nLeksell target: X %.1f, Y %.1f, Z %.1f mm",
                              electrode.name, point.x, point.y, point.z)
        for view in [label, coordinates] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            label.heightAnchor.constraint(equalToConstant: 17),
            coordinates.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            coordinates.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            coordinates.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            coordinates.heightAnchor.constraint(equalToConstant: 15)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshingSelection else { return }
        selectedID = plan.electrodes.indices.contains(table.selectedRow) ? plan.electrodes[table.selectedRow].id : nil
        cancelPlacement()
        refreshEditor()
        refreshGeometry()
    }

    private func apply(_ next: FramePlan, action: String) {
        let previous = plan
        guard next != previous else { return }
        edits.registerUndo(withTarget: self) { $0.apply(previous, action: action) }
        edits.setActionName(action)
        plan = next
        refresh()
        autosave()
    }

    private func refresh() {
        window?.isDocumentEdited = plan != savedPlan
        isRefreshingSelection = true
        let showsFrameCoordinates = plan.frameFit?.reviewed == true
        table.rowHeight = showsFrameCoordinates ? 44 : 28
        table.tableColumns.first?.title = showsFrameCoordinates ? "Electrodes - Leksell (mm)" : "Electrodes"
        table.reloadData()
        if let index = selectedIndex { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        isRefreshingSelection = false
        refreshEditor()
        refreshGeometry()
    }

    private func refreshEditor() {
        let electrode = selectedIndex.map { plan.electrodes[$0] }
        readFrameButton.isEnabled = isReady && detectionProgress == nil
        acceptFrameButton.isEnabled = plan.frameFit != nil && plan.frameFit?.reviewed == false && detectionProgress == nil
        if detectionProgress == nil {
            if let fit = plan.frameFit {
                frameStatus.stringValue = String(format: "%@ - RMS %.2f mm, max %.2f mm\n%d samples",
                    fit.reviewed ? "Frame accepted" : "Review detected rods", fit.rmsMM, fit.maximumErrorMM, fit.sampleCount)
            } else { frameStatus.stringValue = "No frame detected" }
        }
        if let fit = plan.frameFit, fit.reviewed, let electrode {
            let p = fit.coordinates(of: electrode.targetLPS)
            status.stringValue = String(format: "Leksell target: X %.1f  Y %.1f  Z %.1f mm", p.x, p.y, p.z)
        } else { status.stringValue = "Image coordinates (LPS, mm) - Not frame calibrated" }
        coordinateModeLabel.stringValue = coordinateFrame == nil ? "Image LPS (mm)" : "Leksell (mm)"
        coordinateModeLabel.textColor = coordinateFrame == nil ? .systemOrange : .systemCyan
        for button in coordinateButtons { button.isEnabled = electrode != nil }
        nameField.isEnabled = electrode != nil
        model.isEnabled = isReady
        visible.isEnabled = electrode != nil
        place.isEnabled = isReady
        nameField.stringValue = electrode?.name ?? ""
        if let electrode {
            if model.item(withTitle: electrode.specification.identifier) == nil {
                model.addItem(withTitle: electrode.specification.identifier)
            }
            model.selectItem(withTitle: electrode.specification.identifier)
        }
        visible.state = electrode?.isVisible == true ? .on : .off
        let values = electrode.map { electrode -> [Double] in
            let p = electrode.targetCoordinates(in: coordinateFrame)
            return [p.x, p.y, p.z, electrode.azimuthDegrees, electrode.imageDeclinationDegrees, electrode.depthMM]
        } ?? []
        for (index, field) in numberFields.enumerated() {
            field.isEnabled = electrode != nil
            field.stringValue = values.isEmpty ? "" : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), values[index])
        }
        for slider in angleSliders {
            slider.isEnabled = electrode != nil
            let value = values.isEmpty ? 90 : values[slider.tag]
            // Keep older inferior trajectories editable without clamping their angle.
            slider.minValue = value < 0 ? -180 : 0
            slider.doubleValue = value
        }
    }

    private func refreshGeometry() {
        let surfaces = plan.electrodes.flatMap {
            FrameElectrodeGeometry.surfaces(for: $0, selected: $0.id == selectedID)
        }
        pane.setSceneSurfaces(surfaces)
        pane.setSceneLines(FrameElectrodeGeometry.localizerLines(plan.frameFit))
        pane.setBrainVolume(brainButton.state == .on ? brainVolume : nil)
    }

    @objc private func toggleBrain() {
        if let progress = brainProgress {
            progress.cancel()
            brainProgress = nil
            brainButton.state = .off
            brainStatus.stringValue = ""
            return
        }
        guard isReady else { brainButton.state = .off; return }
        if brainVolume != nil { refreshGeometry(); return }
        brainButton.state = .on
        let progress = Progress(totalUnitCount: 100)
        brainProgress = progress
        brainStatus.stringValue = "Loading MRI for brain extraction..."
        let sources = frameInputs.map {
            MRIBrainDICOMLoader.Source(path: $0.path, frameIndex: $0.index, origin: $0.geometry.origin,
                row: $0.geometry.row, column: $0.geometry.column,
                spacing: SIMD2($0.geometry.spacingX, $0.geometry.spacingY))
        }
        let reference = plan.image
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: (Double) -> Void = { fraction in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.brainProgress === progress, !progress.isCancelled else { return }
                    self.brainStatus.stringValue = "Extracting brain: \(Int(fraction * 100))%"
                }
            }
            let result = Result {
                let volume = try MRIBrainDICOMLoader.load(sources, studyUID: reference.studyInstanceUID,
                    seriesUID: reference.seriesInstanceUID, frameOfReferenceUID: reference.frameOfReferenceUID,
                    frameIdentifiers: Set(reference.frameIdentifiers), cancelled: { progress.isCancelled },
                    progress: { report($0 * 0.15) })
                let brain = try MRIBrainExtractor.extract(volume, cancelled: { progress.isCancelled },
                    progress: { report(0.15 + $0 * 0.85) })
                let masked = try MRIBrainMaskedVolume(result: brain, volume: volume, cancelled: { progress.isCancelled })
                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw MRIBrainExtractionError.invalid("Metal is unavailable.")
                }
                return try MetalBrainVolume(masked, device: device)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.brainProgress === progress, !progress.isCancelled else { return }
                self.brainProgress = nil
                switch result {
                case .success(let volume):
                    self.brainVolume = volume
                    self.brainStatus.stringValue = "Brain volume - review extraction"
                case .failure(let error):
                    self.brainButton.state = .off
                    self.brainStatus.stringValue = "Brain extraction failed"
                    NSAlert(error: error).runModal()
                }
                self.refreshGeometry()
            }
        }
    }

    @objc private func readFrame() {
        guard isReady, detectionProgress == nil, window?.makeFirstResponder(nil) == true else { return }
        let progress = Progress(totalUnitCount: Int64(frameInputs.count))
        detectionProgress = progress
        frameStatus.stringValue = "Reading frame..."
        refreshEditor()
        let inputs = frameInputs
        let reference = plan.image
        let frameIdentifiers = Set(reference.frameIdentifiers)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try LeksellFrameReader.read(count: inputs.count, load: { i in
                    if progress.isCancelled { throw CocoaError(.userCancelled) }
                    let source = inputs[i], geometry = source.geometry
                    let reader = try SwiftDICOMReader.cached(contentsOfFile: source.path)
                    guard reader.stringValue(forTag: "0020,000D") == reference.studyInstanceUID,
                          reader.stringValue(forTag: "0020,000E") == reference.seriesInstanceUID,
                          reader.stringValue(forTag: "0020,0052") == reference.frameOfReferenceUID,
                          let sop = reader.stringValue(forTag: "0008,0018"),
                          frameIdentifiers.contains("\(sop)#\(source.index)") else {
                        throw FramePlanError.invalid("The frame-localizer source images changed. Reopen Frame before detection.")
                    }
                    let frame = try reader.storedPixelFrame(at: source.index)
                    let pixels = frame.data.withUnsafeBytes { bytes in
                        (0..<(frame.width * frame.height)).map { i -> Float in
                            let raw = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                            let value = frame.isSigned ? Float(Int16(bitPattern: raw)) : Float(raw)
                            return value * frame.rescaleSlope + frame.rescaleIntercept
                        }
                    }
                    return LeksellFrameReader.Slice(width: frame.width, height: frame.height,
                        origin: geometry.origin, row: geometry.row, column: geometry.column,
                        spacing: SIMD2(geometry.spacingX, geometry.spacingY), pixels: pixels)
                }, progress: { fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.detectionProgress === progress, !progress.isCancelled else { return }
                        self.frameStatus.stringValue = "Reading frame: \(Int(fraction * 100))%"
                    }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detectionProgress === progress, !progress.isCancelled else { return }
                self.detectionProgress = nil
                switch result {
                case .success(let fit):
                    guard self.window?.makeFirstResponder(nil) == true else { self.refreshEditor(); return }
                    var next = self.plan
                    next.frameFit = fit
                    self.apply(next, action: "Read Leksell Frame")
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
                self.refreshEditor()
            }
        }
    }

    @objc private func acceptFrame() {
        guard plan.frameFit != nil, detectionProgress == nil, window?.makeFirstResponder(nil) == true else { return }
        var next = plan
        next.frameFit?.reviewed = true
        apply(next, action: "Accept Leksell Frame")
    }

    @objc private func clearFrame() {
        guard window?.makeFirstResponder(nil) == true else { return }
        detectionProgress?.cancel()
        detectionProgress = nil
        var next = plan
        next.frameFit = nil
        apply(next, action: "Clear Leksell Frame")
        refreshEditor()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let index = selectedIndex, let field = notification.object as? NSTextField else { return }
        var next = plan
        if field === nameField { next.electrodes[index].name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let component = numberFields.firstIndex(where: { $0 === field }) {
            let electrode = plan.electrodes[index]
            let coordinates = electrode.targetCoordinates(in: coordinateFrame)
            let current = [coordinates.x, coordinates.y, coordinates.z,
                           electrode.azimuthDegrees, electrode.imageDeclinationDegrees, electrode.depthMM][component]
            // Display rounding must not change stored geometry when a field is only focused.
            guard field.stringValue != String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), current) else { return }
            guard let value = Double(field.stringValue), value.isFinite else { NSSound.beep(); refreshEditor(); return }
            switch component {
            case 0...2:
                var target = coordinates
                target[component] = value
                next.electrodes[index].setTargetCoordinates(target, in: coordinateFrame)
            case 3: next.electrodes[index].azimuthDegrees = value
            case 4: next.electrodes[index].imageDeclinationDegrees = value
            default: next.electrodes[index].depthMM = value
            }
        }
        do { try next.validate(for: plan.image); apply(next, action: "Edit Electrode") }
        catch { NSAlert(error: error).runModal(); refreshEditor() }
    }

    @objc private func nudgeCoordinate(_ sender: NSButton) {
        guard isReady, window?.makeFirstResponder(nil) == true, let index = selectedIndex else { return }
        let axis = sender.tag / 2
        let positive = axis == 2 ? sender.tag % 2 == 0 : sender.tag % 2 == 1
        var next = plan
        next.electrodes[index].nudgeTarget(axis: axis, positiveAnatomicalDirection: positive, in: coordinateFrame)
        do { try next.validate(for: plan.image); apply(next, action: "Move Target 1 mm") }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func changeAngle(_ slider: NSSlider) {
        guard isReady, window?.makeFirstResponder(nil) == true, let index = selectedIndex else { return }
        var next = plan
        let value = (slider.doubleValue * 10).rounded() / 10
        if slider.tag == 3 { next.electrodes[index].azimuthDegrees = value }
        else { next.electrodes[index].imageDeclinationDegrees = value }
        apply(next, action: slider.tag == 3 ? "Adjust Azimuth" : "Adjust Declination")
    }

    @objc private func addElectrode() {
        guard isReady, window?.makeFirstResponder(nil) == true, plan.electrodes.count < 128 else { NSSound.beep(); return }
        let specification = chosenSpecification
        let electrode = FrameElectrode(name: "Electrode \(plan.electrodes.count + 1)", specification: specification,
                                      targetLPS: initialTarget)
        var next = plan
        next.electrodes.append(electrode)
        selectedID = electrode.id
        apply(next, action: "Add Electrode")
        place.state = .on
        togglePlacement()
    }

    @objc private func duplicateElectrode() {
        guard isReady, window?.makeFirstResponder(nil) == true, let index = selectedIndex, plan.electrodes.count < 128 else { return }
        var copy = plan.electrodes[index]
        copy.id = UUID()
        copy.name = String(copy.name.prefix(240)) + " Copy"
        var next = plan
        next.electrodes.append(copy)
        selectedID = copy.id
        apply(next, action: "Duplicate Electrode")
    }

    @objc private func deleteElectrode() {
        guard let index = selectedIndex else { return }
        var next = plan
        next.electrodes.remove(at: index)
        selectedID = next.electrodes.first?.id
        cancelPlacement()
        apply(next, action: "Delete Electrode")
    }

    @objc private func changeModel() {
        guard let index = selectedIndex, catalogue.indices.contains(model.indexOfSelectedItem) else { return }
        var next = plan
        next.electrodes[index].specification = catalogue[model.indexOfSelectedItem]
        apply(next, action: "Change Electrode Model")
    }

    @objc private func changeVisibility() {
        guard let index = selectedIndex else { return }
        var next = plan
        next.electrodes[index].isVisible = visible.state == .on
        apply(next, action: "Show/Hide Electrode")
    }

    private func cancelPlacement() {
        place.state = .off
        pane.patientPointPlacementHandler = nil
    }

    private var chosenSpecification: FrameElectrodeSpecification {
        catalogue.first { $0.identifier == model.titleOfSelectedItem }
            ?? selectedIndex.map { plan.electrodes[$0].specification } ?? catalogue[0]
    }

    @objc private func togglePlacement() {
        guard isReady, place.state == .on, window?.makeFirstResponder(nil) == true else { cancelPlacement(); return }
        pane.patientPointPlacementHandler = { [weak self] point in
            guard let self else { return }
            var next = self.plan
            if let index = self.selectedIndex {
                next.electrodes[index].targetLPS = point
                next.electrodes[index].isVisible = true
            } else {
                guard next.electrodes.count < 128 else { NSSound.beep(); return }
                let electrode = FrameElectrode(name: "Electrode \(next.electrodes.count + 1)",
                    specification: self.chosenSpecification, targetLPS: point)
                next.electrodes.append(electrode)
                self.selectedID = electrode.id
            }
            self.cancelPlacement()
            self.apply(next, action: "Place Electrode Target")
        }
    }

    @objc private func goToTarget() {
        guard let index = selectedIndex else { return }
        pane.focusMPR(on: plan.electrodes[index].targetLPS)
    }

    @objc private func changeTool() {
        cancelPlacement()
        var assignments = MetalViewerMouseToolAssignments()
        assignments.setTool([MetalViewerMouseTool.windowLevel, .pan, .zoom, .rotate][max(0, tools.selectedSegment)], for: .left)
        assignments.setTool(.zoom, for: .right)
        pane.setMouseToolAssignments(assignments)
    }

    @objc private func changeView(_ sender: NSSegmentedControl) {
        pane.setDisplayMode(sender.selectedSegment == 0 ? .mpr : .mpr3D)
    }

    private func autosave() {
        guard isReady else { return }
        // Continuous slider edits keep only the latest pending plan, not a queue
        // of intermediate SR rewrites. Completion below flushes the latest state.
        guard pendingSaves == 0 else { return }
        let snapshot = plan
        pendingSaves += 1
        saveStatus.stringValue = "Saving to DICOM SR..."
        saveStatus.textColor = .secondaryLabelColor
        store.save(snapshot) { [weak self] result in
            guard let self else { return }
            self.pendingSaves -= 1
            switch result {
            case .success:
                self.savedPlan = snapshot
                if self.pendingSaves == 0 {
                    self.saveStatus.stringValue = "Saved to DICOM SR"
                    self.saveStatus.textColor = .secondaryLabelColor
                }
                if self.plan != snapshot { self.autosave() }
            case .failure(let error):
                self.saveStatus.stringValue = "Autosave failed: \(error.localizedDescription)"
                self.saveStatus.textColor = .systemRed
                self.closeAfterSaving = false
            }
            self.window?.isDocumentEdited = self.plan != self.savedPlan
            if self.pendingSaves == 0 && self.closeAfterSaving && self.plan == self.savedPlan {
                self.closeAfterSaving = false
                self.window?.performClose(nil)
            }
        }
    }

    @objc private func savePlan() {
        guard window?.makeFirstResponder(nil) == true else { return }
        autosave()
    }

    @objc private func exportPlan() { _ = save() }

    private func save() -> Bool {
        guard isReady, window?.makeFirstResponder(nil) == true else { return false }
        var destination = planURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Frame Plan.json"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        do {
            try plan.write(to: destination!)
            planURL = destination
            return true
        } catch { NSAlert(error: error).runModal(); return false }
    }

    @objc private func openPlan() {
        guard isReady, window?.makeFirstResponder(nil) == true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let next = try FramePlan.read(from: url, image: plan.image)
            cancelPlacement()
            planURL = url
            selectedID = next.electrodes.first?.id
            apply(next, action: "Import Frame Plan")
        } catch { NSAlert(error: error).runModal() }
    }
}
