import AppKit

private final class HorosSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HorosSettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.24, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class HorosDefaultsCheckbox: NSButton {
    let defaultsKey: String
    var changeHandler: ((Bool) -> Void)?

    init(title: String, defaultsKey: String) {
        self.defaultsKey = defaultsKey
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = UserDefaults.standard.bool(forKey: defaultsKey) ? .on : .off
        target = self
        action = #selector(valueChanged(_:))
        font = .systemFont(ofSize: 13)
        contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func valueChanged(_ sender: NSButton) {
        let value = sender.state == .on
        UserDefaults.standard.set(value, forKey: defaultsKey)
        changeHandler?(value)
    }
}

private final class HorosDefaultsTextField: NSTextField, NSTextFieldDelegate {
    enum ValueKind {
        case string
        case integer
    }

    let defaultsKey: String
    let valueKind: ValueKind
    var changeHandler: (() -> Void)?

    init(defaultsKey: String, valueKind: ValueKind = .string) {
        self.defaultsKey = defaultsKey
        self.valueKind = valueKind
        super.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBordered = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        focusRingType = .exterior
        font = .systemFont(ofSize: 13)
        target = self
        action = #selector(valueChanged(_:))
        delegate = self

        switch valueKind {
        case .string:
            stringValue = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        case .integer:
            integerValue = UserDefaults.standard.integer(forKey: defaultsKey)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        persist()
    }

    @objc private func valueChanged(_ sender: NSTextField) {
        persist()
    }

    private func persist() {
        switch valueKind {
        case .string:
            UserDefaults.standard.set(stringValue, forKey: defaultsKey)
        case .integer:
            UserDefaults.standard.set(integerValue, forKey: defaultsKey)
        }
        changeHandler?()
    }
}

private final class HorosDefaultsPopup: NSPopUpButton {
    let defaultsKey: String
    var changeHandler: ((Int) -> Void)?

    init(defaultsKey: String, items: [(String, Int)]) {
        self.defaultsKey = defaultsKey
        super.init(frame: .zero, pullsDown: false)
        controlSize = .regular
        for (title, tag) in items {
            addItem(withTitle: title)
            lastItem?.tag = tag
        }
        selectItem(withTag: UserDefaults.standard.integer(forKey: defaultsKey))
        if selectedItem == nil {
            selectItem(at: 0)
        }
        target = self
        action = #selector(valueChanged(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func valueChanged(_ sender: NSPopUpButton) {
        let value = sender.selectedItem?.tag ?? 0
        UserDefaults.standard.set(value, forKey: defaultsKey)
        changeHandler?(value)
    }
}

class HorosScrollableSettingsPaneViewController: HorosSettingsPaneViewController {
    private let paneSubtitle: String
    let pageStack = NSStackView()

    init(paneTitle: String, subtitle: String) {
        paneSubtitle = subtitle
        super.init(paneTitle: paneTitle)
    }

    override func loadView() {
        let root = HorosSettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        view = root

        let scrollView = NSScrollView(frame: root.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        let document = HorosSettingsFlippedView(frame: root.bounds)
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 18
        pageStack.edgeInsets = NSEdgeInsets(top: 34, left: 42, bottom: 34, right: 42)
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pageStack)

        let title = NSTextField(labelWithString: paneTitle)
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        pageStack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: paneSubtitle)
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        subtitle.maximumNumberOfLines = 2
        pageStack.addArrangedSubview(subtitle)

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            pageStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            pageStack.topAnchor.constraint(equalTo: document.topAnchor),
            pageStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            subtitle.widthAnchor.constraint(equalTo: pageStack.widthAnchor, constant: -84),
        ])

        buildSettings()
    }

    func buildSettings() {}

    @discardableResult
    func addCard(title: String, rows: [NSView]) -> NSView {
        let card = HorosSettingsCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .medium)
        heading.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        stack.addArrangedSubview(heading)

        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }

        pageStack.addArrangedSubview(card)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: pageStack.widthAnchor, constant: -84),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    func labeledRow(_ title: String, control: NSView, detail: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 210).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11.5)
            detailLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1)
            row.addArrangedSubview(detailLabel)
        }
        return row
    }

    func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }
}

private final class HorosDatabaseLocationView: NSView {
    private let modeControl = NSSegmentedControl(labels: ["Default", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let selectButton = NSButton(title: "Select…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        modeControl.selectedSegment = min(max(UserDefaults.standard.integer(forKey: "DEFAULT_DATABASELOCATION"), 0), 1)
        modeControl.role = .valueSelection
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        stack.addArrangedSubview(modeControl)

        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(pathLabel)

        selectButton.target = self
        selectButton.action = #selector(selectLocation(_:))
        stack.addArrangedSubview(selectButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refresh() {
        let isCustom = modeControl.selectedSegment == 1
        selectButton.isEnabled = isCustom
        let path = UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL") ?? ""
        pathLabel.stringValue = isCustom && path.isEmpty == false ? path : "~/Documents/Horos Data"
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1,
           (UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL") ?? "").isEmpty {
            selectLocation(sender)
            return
        }
        applyLocation(mode: sender.selectedSegment)
    }

    @objc private func selectLocation(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Location"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let selectedURL = panel.url else {
                self.modeControl.selectedSegment = UserDefaults.standard.integer(forKey: "DEFAULT_DATABASELOCATION")
                self.refresh()
                return
            }

            var location = selectedURL.path
            if (location as NSString).lastPathComponent == "Horos Data" {
                location = (location as NSString).deletingLastPathComponent
            }
            let locationURL = URL(fileURLWithPath: location)
            if locationURL.lastPathComponent == "DATABASE",
               locationURL.deletingLastPathComponent().lastPathComponent == "Horos Data" {
                location = locationURL.deletingLastPathComponent().deletingLastPathComponent().path
            }

            UserDefaults.standard.set(location, forKey: "DEFAULT_DATABASELOCATIONURL")
            self.modeControl.selectedSegment = 1
            self.applyLocation(mode: 1)
        }
    }

    private func applyLocation(mode: Int) {
        let defaults = UserDefaults.standard
        defaults.set(mode, forKey: "DEFAULT_DATABASELOCATION")
        defaults.set(mode, forKey: "DATABASELOCATION")
        defaults.set(defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL") ?? "", forKey: "DATABASELOCATIONURL")
        defaults.removeObject(forKey: "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")
        refresh()
        BrowserController.currentBrowser()?.resetToLocalDatabase()
    }
}

final class DatabaseSettingsPaneViewController: HorosScrollableSettingsPaneViewController {
    init() {
        super.init(
            paneTitle: "Database",
            subtitle: "Choose where the Horos database lives and how imported DICOM studies are copied, grouped, displayed, and cleaned."
        )
    }

    override func buildSettings() {
        let copyMode = HorosDefaultsPopup(
            defaultsKey: "COPYDATABASEMODE",
            items: [("Always", 0), ("When files are not on the internal drive", 2), ("Ask", 3)]
        )
        let copyFiles = HorosDefaultsCheckbox(title: "Copy imported files into the Horos Data folder", defaultsKey: "COPYDATABASE")
        copyMode.isEnabled = copyFiles.state == .on
        copyFiles.changeHandler = { copyMode.isEnabled = $0 }

        addCard(title: "Storage & Import", rows: [
            labeledRow("Database location", control: HorosDatabaseLocationView(frame: .zero)),
            copyFiles,
            labeledRow("Copy files", control: copyMode),
            HorosDefaultsCheckbox(title: "Import DICOM files only", defaultsKey: "onlyDICOM"),
            HorosDefaultsCheckbox(title: "Validate external files before importing", defaultsKey: "validateFilesBeforeImporting"),
        ])

        let projectionMode = HorosDefaultsPopup(
            defaultsKey: "combineProjectionSeriesMode",
            items: [("Combine matching projections", 0), ("Split matching projections", 1)]
        )
        let projectionToggle = HorosDefaultsCheckbox(title: "Apply projection-series grouping for CR, DX, MG, RF and XA", defaultsKey: "combineProjectionSeries")
        projectionMode.isEnabled = projectionToggle.state == .on
        projectionToggle.changeHandler = { projectionMode.isEnabled = $0 }

        addCard(title: "Series Parsing", rows: [
            projectionToggle,
            labeledRow("Projection series", control: projectionMode),
            HorosDefaultsCheckbox(title: "Split multi-phase cardiac CT into temporal series", defaultsKey: "SEPARATECARDIAC4D"),
            HorosDefaultsCheckbox(title: "Create one ultrasound series per file", defaultsKey: "oneFileOnSeriesForUS"),
            HorosDefaultsCheckbox(title: "Group localizer and scout images", defaultsKey: "NOLOCALIZER"),
            labeledRow("Localizer descriptions", control: HorosDefaultsTextField(defaultsKey: "NOLOCALIZER_Strings")),
            labeledRow(
                "Image order",
                control: HorosDefaultsPopup(
                    defaultsKey: "sortSeriesBySliceLocation",
                    items: [("Instance number", 0), ("Ascending slice location", 1), ("Descending slice location", -1), ("Ascending date", 2), ("Descending date", -2)]
                )
            ),
        ])

        addCard(title: "Automatic Cleaning", rows: [
            HorosDefaultsCheckbox(title: "Automatically delete studies that match the age rules below", defaultsKey: "AUTOCLEANINGDATE"),
            HorosDefaultsCheckbox(title: "Require an acquisition date older than the selected interval", defaultsKey: "AUTOCLEANINGDATEPRODUCED"),
            labeledRow(
                "Acquisition age",
                control: HorosDefaultsPopup(
                    defaultsKey: "AUTOCLEANINGDATEPRODUCEDDAYS",
                    items: [("1 week", 7), ("2 weeks", 14), ("1 month", 31), ("3 months", 90), ("6 months", 180), ("1 year", 365)]
                )
            ),
            HorosDefaultsCheckbox(title: "Require the study not to have been opened during the selected interval", defaultsKey: "AUTOCLEANINGDATEOPENED"),
            labeledRow(
                "Time since opened",
                control: HorosDefaultsPopup(
                    defaultsKey: "AUTOCLEANINGDATEOPENEDDAYS",
                    items: [("1 week", 7), ("2 weeks", 14), ("1 month", 31), ("3 months", 90), ("6 months", 180), ("1 year", 365)]
                )
            ),
            HorosDefaultsCheckbox(title: "Require the Comments field to match a text rule", defaultsKey: "AUTOCLEANINGCOMMENTS"),
            labeledRow(
                "Comments rule",
                control: HorosDefaultsPopup(defaultsKey: "AUTOCLEANINGDONTCONTAIN", items: [("Contains", 0), ("Does not contain", 1)])
            ),
            labeledRow("Comments text", control: HorosDefaultsTextField(defaultsKey: "AUTOCLEANINGCOMMENTSTEXT")),
            separator(),
            HorosDefaultsCheckbox(title: "Keep the configured amount of disk space free", defaultsKey: "AUTOCLEANINGSPACE"),
            labeledRow(
                "Minimum free space",
                control: HorosDefaultsPopup(
                    defaultsKey: "AUTOCLEANINGSPACESIZE",
                    items: [("20 MB", 20), ("100 MB", 100), ("1 GB", 1024), ("5 GB", 5120), ("10 GB", 10000), ("20 GB", 20000), ("40 GB", 40000), ("5%", -5), ("10%", -10), ("15%", -15), ("20%", -20), ("30%", -30), ("40%", -40), ("50%", -50)]
                )
            ),
            labeledRow(
                "Delete first",
                control: HorosDefaultsPopup(defaultsKey: "AutocleanSpaceMode", items: [("Least recently created", 0), ("Least recently opened", 1), ("Least recently added", 2)])
            ),
            HorosDefaultsCheckbox(title: "Never automatically delete studies with comments", defaultsKey: "dontDeleteStudiesWithComments"),
            HorosDefaultsCheckbox(title: "Never automatically delete studies in a regular album", defaultsKey: "dontDeleteStudiesIfInAlbum"),
            HorosDefaultsCheckbox(title: "Also delete original files when automatically deleting linked images", defaultsKey: "AUTOCLEANINGDELETEORIGINAL"),
        ])

        let fontSize = HorosDefaultsPopup(defaultsKey: "dbFontSize", items: [("Small", -1), ("Regular", 0), ("Large", 1)])
        fontSize.changeHandler = { _ in
            BrowserController.currentBrowser()?.setTableViewRowHeight()
            BrowserController.currentBrowser()?.refreshMatrix(nil)
        }
        let horizontalHistory = HorosDefaultsCheckbox(title: "Display the comparative-study history horizontally", defaultsKey: "horizontalHistory")
        horizontalHistory.changeHandler = { [weak self] _ in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Restart Horos"
            alert.informativeText = "Restart Horos to apply the comparative-study history layout change."
            alert.beginSheetModal(for: window, completionHandler: nil)
        }

        addCard(title: "Database Browser", rows: [
            HorosDefaultsCheckbox(title: "Display all studies belonging to each patient", defaultsKey: "KeepStudiesOfSamePatientTogether"),
            HorosDefaultsCheckbox(title: "Capitalize patient names and descriptions", defaultsKey: "CapitalizedString"),
            HorosDefaultsCheckbox(title: "Clear the search field when selecting another album", defaultsKey: "clearSearchAndTimeIntervalWhenSelectingAlbum"),
            labeledRow("Database font", control: fontSize),
            labeledRow(
                "Patient age",
                control: HorosDefaultsPopup(defaultsKey: "yearOldDatabaseDisplay", items: [("Current age", 0), ("Age at acquisition", 1), ("Both when different", 2)])
            ),
            horizontalHistory,
            HorosDefaultsCheckbox(title: "Reverse scrolling in the database preview", defaultsKey: "Scroll Wheel Reversed"),
        ])

        addCard(title: "Reports & Export", rows: [
            HorosDefaultsCheckbox(title: "Open encapsulated PDF reports in Preview", defaultsKey: "openPDFwithPreview"),
            HorosDefaultsCheckbox(title: "Use a DICOMDIR structure when exporting to the filesystem", defaultsKey: "AddDICOMDIRForExport"),
        ])

        addCard(title: "DICOM Comments", rows: [
            HorosDefaultsCheckbox(title: "Load database comments from DICOM files", defaultsKey: "CommentsFromDICOMFiles"),
            HorosDefaultsCheckbox(title: "Store comments and status in DICOM files", defaultsKey: "savedCommentsAndStatusInDICOMFiles"),
            HorosDefaultsCheckbox(title: "Populate the selected comment field from imported DICOM metadata", defaultsKey: "COMMENTSAUTOFILL"),
            HorosDefaultsCheckbox(title: "Apply automatic comments at study level", defaultsKey: "COMMENTSAUTOFILLStudyLevel"),
            HorosDefaultsCheckbox(title: "Apply automatic comments at series level", defaultsKey: "COMMENTSAUTOFILLSeriesLevel"),
        ])
    }
}

private protocol HorosNetworkSettingsReloadable: AnyObject {
    func reloadSettings()
}

private final class ListenerSettingsViewController: HorosScrollableSettingsPaneViewController {
    init() {
        super.init(paneTitle: "Listener", subtitle: "Configure the DICOM Store SCP used to receive studies from scanners and PACS systems.")
    }

    override func buildSettings() {
        let aeTitle = HorosDefaultsTextField(defaultsKey: "AETITLE")
        let hostTitle = HorosDefaultsCheckbox(title: "Use this Mac's host name as the AE title", defaultsKey: "UseHostNameForAETitle")
        aeTitle.isEnabled = hostTitle.state == .off
        hostTitle.changeHandler = { aeTitle.isEnabled = !$0 }

        let tlsAETitle = HorosDefaultsTextField(defaultsKey: "TLSStoreSCPAETITLE")
        let tlsUsesDefaultAETitle = HorosDefaultsCheckbox(title: "Use the regular listener AE title for TLS", defaultsKey: "TLSStoreSCPAETITLEIsDefaultAET")
        tlsAETitle.isEnabled = tlsUsesDefaultAETitle.state == .off
        tlsUsesDefaultAETitle.changeHandler = { tlsAETitle.isEnabled = !$0 }

        addCard(title: "DICOM Receiver", rows: [
            HorosDefaultsCheckbox(title: "Activate the DICOM listener while Horos is running", defaultsKey: "STORESCP"),
            labeledRow("AE title", control: aeTitle, detail: "Maximum 16 characters"),
            hostTitle,
            labeledRow("Port", control: HorosDefaultsTextField(defaultsKey: "AEPORT", valueKind: .integer)),
            labeledRow(
                "Preferred syntax",
                control: HorosDefaultsPopup(
                    defaultsKey: "preferredSyntaxForIncoming",
                    items: [("Implicit Little Endian only", 0), ("Explicit Little Endian", 2), ("JPEG Baseline", 4), ("JPEG Extended", 5), ("JPEG Lossless", 21), ("RLE", 22), ("JPEG-LS Lossless only", 23), ("JPEG-LS", 24), ("JPEG 2000 Lossless only", 26), ("JPEG 2000", 27)]
                )
            ),
            labeledRow("DIMSE timeout (seconds)", control: HorosDefaultsTextField(defaultsKey: "DICOMTimeout", valueKind: .integer)),
            labeledRow("Connection timeout (seconds)", control: HorosDefaultsTextField(defaultsKey: "DICOMConnectionTimeout", valueKind: .integer)),
            HorosDefaultsCheckbox(title: "Run the listener only while Horos is the active application", defaultsKey: "RunListenerOnlyIfActive"),
        ])

        addCard(title: "Incoming Studies", rows: [
            labeledRow("Scan incoming files every", control: HorosDefaultsTextField(defaultsKey: "LISTENERCHECKINTERVAL", valueKind: .integer), detail: "seconds"),
            labeledRow(
                "On receipt",
                control: HorosDefaultsPopup(
                    defaultsKey: "ListenerCompressionSettings",
                    items: [("Keep transfer syntax unchanged", 0), ("Decompress compressed images", 1), ("Compress uncompressed images using General settings", 2)]
                )
            ),
            labeledRow(
                "Unreadable files",
                control: HorosDefaultsPopup(defaultsKey: "DELETEFILELISTENER", items: [("Move to NOT READABLE", 0), ("Delete", 1)])
            ),
            HorosDefaultsCheckbox(title: "Replace an existing file when a newer matching instance arrives", defaultsKey: "REPLACE_WITH_NEW_INCOMING_FILE"),
            HorosDefaultsCheckbox(title: "Add received studies only to the default local database", defaultsKey: "addNewIncomingFilesToDefaultDBOnly"),
            HorosDefaultsCheckbox(title: "Store the source AE title in Source Application Entity Title (0002,0016)", defaultsKey: "putSrcAETitleInSourceApplicationEntityTitle"),
            HorosDefaultsCheckbox(title: "Store the destination AE title in Private Information Creator UID (0002,0100)", defaultsKey: "putDstAETitleInPrivateInformationCreatorUID"),
        ])

        addCard(title: "TLS Listener", rows: [
            HorosDefaultsCheckbox(title: "Activate the TLS DICOM listener", defaultsKey: "STORESCPTLS"),
            labeledRow("TLS AE title", control: tlsAETitle),
            tlsUsesDefaultAETitle,
            labeledRow("TLS port", control: HorosDefaultsTextField(defaultsKey: "TLSStoreSCPAEPORT", valueKind: .integer)),
            NSTextField(wrappingLabelWithString: "The existing Keychain identity and cipher-suite configuration are preserved. Certificate selection remains in macOS Keychain Access."),
        ])

        addCard(title: "Services & Diagnostics", rows: [
            HorosDefaultsCheckbox(title: "Publish this DICOM listener with Bonjour", defaultsKey: "publishDICOMBonjour"),
            HorosDefaultsCheckbox(title: "Enable C-GET SCP support", defaultsKey: "activateCGETSCP"),
            HorosDefaultsCheckbox(title: "Enable C-FIND SCP support", defaultsKey: "activateCFINDSCP"),
            HorosDefaultsCheckbox(title: "Record DICOM network events", defaultsKey: "NETWORKLOGS"),
            labeledRow(
                "Keep network logs",
                control: HorosDefaultsPopup(defaultsKey: "LOGCLEANINGDAYS", items: [("1 day", 1), ("1 week", 7), ("1 month", 31), ("3 months", 90), ("1 year", 365), ("2 years", 730)])
            ),
        ])
    }
}

private final class DICOMNodeEditorView: NSView {
    let descriptionField = NSTextField()
    let aeTitleField = NSTextField()
    let addressField = NSTextField()
    let portField = NSTextField()
    let retrieveModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let queryButton = NSButton(checkboxWithTitle: "Query / Retrieve", target: nil, action: nil)
    let sendButton = NSButton(checkboxWithTitle: "Send", target: nil, action: nil)
    let tlsButton = NSButton(checkboxWithTitle: "TLS", target: nil, action: nil)
    let tlsAuthenticationButton = NSButton(checkboxWithTitle: "Require authenticated TLS", target: nil, action: nil)

    init(node: [String: Any]?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 300))

        descriptionField.stringValue = node?["Description"] as? String ?? "Description"
        aeTitleField.stringValue = node?["AETitle"] as? String ?? "PACS"
        addressField.stringValue = node?["Address"] as? String ?? "127.0.0.1"
        portField.integerValue = (node?["Port"] as? NSNumber)?.intValue ?? Int(node?["Port"] as? String ?? "") ?? 11112
        enabledButton.state = ((node?["Activated"] as? NSNumber)?.boolValue ?? true) ? .on : .off
        queryButton.state = ((node?["QR"] as? NSNumber)?.boolValue ?? true) ? .on : .off
        sendButton.state = ((node?["Send"] as? NSNumber)?.boolValue ?? true) ? .on : .off
        tlsButton.state = ((node?["TLSEnabled"] as? NSNumber)?.boolValue ?? false) ? .on : .off
        tlsAuthenticationButton.state = ((node?["TLSAuthenticated"] as? NSNumber)?.boolValue ?? false) ? .on : .off

        retrieveModePopup.addItem(withTitle: "C-MOVE")
        retrieveModePopup.lastItem?.tag = 0
        retrieveModePopup.addItem(withTitle: "C-GET")
        retrieveModePopup.lastItem?.tag = 1
        retrieveModePopup.selectItem(withTag: (node?["retrieveMode"] as? NSNumber)?.intValue ?? 0)

        let grid = NSGridView(views: [
            [label("Description"), descriptionField],
            [label("AE title"), aeTitleField],
            [label("Address"), addressField],
            [label("Port"), portField],
            [label("Retrieve with"), retrieveModePopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let options = NSStackView(views: [enabledButton, queryButton, sendButton, tlsButton, tlsAuthenticationButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 7
        options.translatesAutoresizingMaskIntoConstraints = false
        addSubview(options)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            options.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 116),
            options.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            options.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }
}

private final class DICOMNodesSettingsViewController: HorosScrollableSettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate, HorosNetworkSettingsReloadable {
    private var nodes: [[String: Any]] = []
    private let tableView = NSTableView()

    init() {
        super.init(paneTitle: "Nodes", subtitle: "DICOM destinations used by Query/Retrieve, Send, remote searches, and routing.")
    }

    override func buildSettings() {
        configureTable()
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        tableView.frame = NSRect(x: 0, y: 0, width: 760, height: 330)
        tableView.autoresizingMask = [.width]
        scroll.documentView = tableView
        scroll.heightAnchor.constraint(equalToConstant: 330).isActive = true

        let add = NSButton(title: "Add…", target: self, action: #selector(addNode(_:)))
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editNode(_:)))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeNode(_:)))
        let buttons = NSStackView(views: [add, edit, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        addCard(title: "DICOM Nodes", rows: [scroll, buttons])
        reloadSettings()
    }

    func reloadSettings() {
        nodes = (UserDefaults.standard.array(forKey: "SERVERS") as? [[String: Any]]) ?? []
        tableView.reloadData()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(editNode(_:))
        tableView.target = self

        for (identifier, title, width) in [
            ("enabled", "", 34.0),
            ("description", "Description", 170.0),
            ("ae", "AE Title", 100.0),
            ("address", "Address", 170.0),
            ("port", "Port", 65.0),
            ("roles", "Uses", 105.0),
            ("tls", "TLS", 45.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard nodes.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let node = nodes[row]
        if identifier == "enabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(nodeEnabledChanged(_:)))
            checkbox.tag = row
            checkbox.state = ((node["Activated"] as? NSNumber)?.boolValue ?? true) ? .on : .off
            return checkbox
        }

        let text: String
        switch identifier {
        case "description": text = node["Description"] as? String ?? ""
        case "ae": text = node["AETitle"] as? String ?? ""
        case "address": text = node["Address"] as? String ?? ""
        case "port": text = String(describing: node["Port"] ?? "")
        case "roles":
            var roles: [String] = []
            if (node["QR"] as? NSNumber)?.boolValue ?? false { roles.append("Q/R") }
            if (node["Send"] as? NSNumber)?.boolValue ?? false { roles.append("Send") }
            text = roles.joined(separator: ", ")
        case "tls": text = (node["TLSEnabled"] as? NSNumber)?.boolValue ?? false ? "Yes" : ""
        default: text = ""
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    @objc private func nodeEnabledChanged(_ sender: NSButton) {
        guard nodes.indices.contains(sender.tag) else { return }
        nodes[sender.tag]["Activated"] = sender.state == .on
        saveNodes()
    }

    @objc private func addNode(_ sender: Any?) {
        presentEditor(index: nil)
    }

    @objc private func editNode(_ sender: Any?) {
        guard nodes.indices.contains(tableView.selectedRow) else { NSSound.beep(); return }
        presentEditor(index: tableView.selectedRow)
    }

    @objc private func removeNode(_ sender: Any?) {
        guard nodes.indices.contains(tableView.selectedRow) else { NSSound.beep(); return }
        nodes.remove(at: tableView.selectedRow)
        saveNodes()
        tableView.reloadData()
    }

    private func presentEditor(index: Int?) {
        guard let window = view.window else { return }
        let existing = index.flatMap { nodes.indices.contains($0) ? nodes[$0] : nil }
        let editor = DICOMNodeEditorView(node: existing)
        let alert = NSAlert()
        alert.messageText = index == nil ? "Add DICOM Node" : "Edit DICOM Node"
        alert.informativeText = "AE titles are limited to 16 characters. Existing advanced TLS properties are preserved."
        alert.accessoryView = editor
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = editor.aeTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = editor.addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = editor.portField.integerValue
            guard title.isEmpty == false, title.count <= 16, address.isEmpty == false, port > 0, port <= 65_535 else {
                NSSound.beep()
                return
            }

            var node = existing ?? [:]
            node["Description"] = editor.descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            node["AETitle"] = title
            node["Address"] = address
            node["Port"] = String(port)
            node["Activated"] = editor.enabledButton.state == .on
            node["QR"] = editor.queryButton.state == .on
            node["Send"] = editor.sendButton.state == .on
            node["retrieveMode"] = editor.retrieveModePopup.selectedItem?.tag ?? 0
            node["TLSEnabled"] = editor.tlsButton.state == .on
            node["TLSAuthenticated"] = editor.tlsAuthenticationButton.state == .on
            if node["TransferSyntax"] == nil { node["TransferSyntax"] = 0 }

            if let index { self.nodes[index] = node } else { self.nodes.append(node) }
            self.saveNodes()
            self.tableView.reloadData()
        }
    }

    private func saveNodes() {
        UserDefaults.standard.set(nodes, forKey: "SERVERS")
    }
}

private final class DICOMRouteEditorView: NSView {
    let nameField = NSTextField()
    let destinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let predicateField = NSTextField()
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let imagesOnlyButton = NSButton(checkboxWithTitle: "Route image-storage instances only", target: nil, action: nil)
    let previousPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let previousModalityButton = NSButton(checkboxWithTitle: "Same modality", target: nil, action: nil)
    let previousDescriptionButton = NSButton(checkboxWithTitle: "Same description", target: nil, action: nil)
    let retryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let cfindButton = NSButton(checkboxWithTitle: "Verify destination with C-FIND before sending", target: nil, action: nil)
    let schedulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let delayField = NSTextField()
    let fromField = NSTextField()
    let toField = NSTextField()

    init(route: [String: Any]?, destinations: [[String: Any]]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 570, height: 445))

        nameField.stringValue = route?["name"] as? String ?? "New route"
        predicateField.stringValue = route?["filter"] as? String ?? "(series.study.modality contains[c] \"CT\")"

        for node in destinations {
            let description = node["Description"] as? String ?? "Unnamed"
            destinationPopup.addItem(withTitle: description)
            destinationPopup.lastItem?.representedObject = description
        }
        if let destination = route?["server"] as? String { destinationPopup.selectItem(withTitle: destination) }

        for (title, tag) in [("All newly received files", 0), ("Horos-generated data", 1), ("Imported files", 2)] {
            sourcePopup.addItem(withTitle: title)
            sourcePopup.lastItem?.tag = tag
        }
        sourcePopup.selectItem(withTag: (route?["filterType"] as? NSNumber)?.intValue ?? 0)

        imagesOnlyButton.state = ((route?["imagesOnly"] as? NSNumber)?.boolValue ?? false) ? .on : .off

        for count in 0...3 {
            previousPopup.addItem(withTitle: count == 0 ? "Do not include previous studies" : "Include \(count) previous \(count == 1 ? "study" : "studies")")
            previousPopup.lastItem?.tag = count
        }
        previousPopup.selectItem(withTag: (route?["previousStudies"] as? NSNumber)?.intValue ?? 0)
        previousModalityButton.state = ((route?["previousModality"] as? NSNumber)?.boolValue ?? false) ? .on : .off
        previousDescriptionButton.state = ((route?["previousDescription"] as? NSNumber)?.boolValue ?? false) ? .on : .off

        for count in [0, 5, 20, 100, 1_400] {
            retryPopup.addItem(withTitle: count == 0 ? "Do not retry" : "Try \(count) times every 30 seconds")
            retryPopup.lastItem?.tag = count
        }
        retryPopup.selectItem(withTag: (route?["failureRetry"] as? NSNumber)?.intValue ?? Int(route?["failureRetry"] as? String ?? "") ?? 20)
        cfindButton.state = ((route?["cfindTest"] as? NSNumber)?.boolValue ?? true) ? .on : .off

        for (title, tag) in [("Immediately", 0), ("After a delay", 1), ("During a time window", 2)] {
            schedulePopup.addItem(withTitle: title)
            schedulePopup.lastItem?.tag = tag
        }
        schedulePopup.selectItem(withTag: (route?["scheduleType"] as? NSNumber)?.intValue ?? Int(route?["scheduleType"] as? String ?? "") ?? 0)
        delayField.integerValue = (route?["delayTime"] as? NSNumber)?.intValue ?? Int(route?["delayTime"] as? String ?? "") ?? 2
        fromField.stringValue = route?["fromTime"] as? String ?? "21:00"
        toField.stringValue = route?["toTime"] as? String ?? "06:00"

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Destination"), destinationPopup],
            [label("Source"), sourcePopup],
            [label("Predicate"), predicateField],
            [label("Previous studies"), previousPopup],
            [label("Retry"), retryPopup],
            [label("Schedule"), schedulePopup],
            [label("Delay (hours)"), delayField],
            [label("Time window"), horizontal([fromField, NSTextField(labelWithString: "to"), toField])],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let options = NSStackView(views: [imagesOnlyButton, previousModalityButton, previousDescriptionButton, cfindButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 7
        options.translatesAutoresizingMaskIntoConstraints = false
        addSubview(options)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            options.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 116),
            options.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            options.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 7
        return stack
    }
}

private final class DICOMRoutingSettingsViewController: HorosScrollableSettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate, HorosNetworkSettingsReloadable {
    private var routes: [[String: Any]] = []
    private let tableView = NSTableView()

    init() {
        super.init(paneTitle: "Routing", subtitle: "Automatically forward newly received or imported DICOM studies to configured destinations.")
    }

    override func buildSettings() {
        addCard(title: "Autorouting", rows: [
            HorosDefaultsCheckbox(title: "Enable automatic DICOM routing", defaultsKey: "AUTOROUTINGACTIVATED"),
            HorosDefaultsCheckbox(title: "Show errors produced by routing jobs", defaultsKey: "ShowErrorMessagesForAutorouting"),
        ])

        configureTable()
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        tableView.frame = NSRect(x: 0, y: 0, width: 760, height: 285)
        tableView.autoresizingMask = [.width]
        scroll.documentView = tableView
        scroll.heightAnchor.constraint(equalToConstant: 285).isActive = true

        let buttons = NSStackView(views: [
            NSButton(title: "Add…", target: self, action: #selector(addRoute(_:))),
            NSButton(title: "Edit…", target: self, action: #selector(editRoute(_:))),
            NSButton(title: "Remove", target: self, action: #selector(removeRoute(_:))),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addCard(title: "Rules", rows: [scroll, buttons])
        reloadSettings()
    }

    func reloadSettings() {
        routes = (UserDefaults.standard.array(forKey: "AUTOROUTINGDICTIONARY") as? [[String: Any]]) ?? []
        tableView.reloadData()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(editRoute(_:))
        for (identifier, title, width) in [("enabled", "", 34.0), ("name", "Name", 150.0), ("server", "Destination", 150.0), ("filter", "Predicate", 330.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { routes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard routes.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let route = routes[row]
        if identifier == "enabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(routeEnabledChanged(_:)))
            checkbox.tag = row
            checkbox.state = ((route["activated"] as? NSNumber)?.boolValue ?? true) ? .on : .off
            return checkbox
        }
        let text = route[identifier] as? String ?? ""
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    @objc private func routeEnabledChanged(_ sender: NSButton) {
        guard routes.indices.contains(sender.tag) else { return }
        routes[sender.tag]["activated"] = sender.state == .on
        saveRoutes()
    }

    @objc private func addRoute(_ sender: Any?) { presentEditor(index: nil) }

    @objc private func editRoute(_ sender: Any?) {
        guard routes.indices.contains(tableView.selectedRow) else { NSSound.beep(); return }
        presentEditor(index: tableView.selectedRow)
    }

    @objc private func removeRoute(_ sender: Any?) {
        guard routes.indices.contains(tableView.selectedRow) else { NSSound.beep(); return }
        routes.remove(at: tableView.selectedRow)
        saveRoutes()
        tableView.reloadData()
    }

    private func presentEditor(index: Int?) {
        guard let window = view.window else { return }
        let destinations = ((UserDefaults.standard.array(forKey: "SERVERS") as? [[String: Any]]) ?? []).filter {
            ($0["Activated"] as? NSNumber)?.boolValue ?? true
        }
        guard destinations.isEmpty == false else {
            let alert = NSAlert()
            alert.messageText = "No DICOM destination is available"
            alert.informativeText = "Add an enabled DICOM node before creating a routing rule."
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        let existing = index.flatMap { routes.indices.contains($0) ? routes[$0] : nil }
        let editor = DICOMRouteEditorView(route: existing, destinations: destinations)
        let alert = NSAlert()
        alert.messageText = index == nil ? "Add Routing Rule" : "Edit Routing Rule"
        alert.informativeText = "The predicate is evaluated against imported Image objects and their series.study relationships."
        alert.accessoryView = editor
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = editor.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, let destination = editor.destinationPopup.selectedItem?.representedObject as? String else {
                NSSound.beep()
                return
            }
            var route = existing ?? [:]
            route["name"] = name
            route["description"] = route["description"] as? String ?? ""
            route["activated"] = (route["activated"] as? NSNumber)?.boolValue ?? true
            route["server"] = destination
            route["filter"] = editor.predicateField.stringValue
            route["filterType"] = editor.sourcePopup.selectedItem?.tag ?? 0
            route["imagesOnly"] = editor.imagesOnlyButton.state == .on
            route["previousStudies"] = editor.previousPopup.selectedItem?.tag ?? 0
            route["previousModality"] = editor.previousModalityButton.state == .on
            route["previousDescription"] = editor.previousDescriptionButton.state == .on
            route["failureRetry"] = editor.retryPopup.selectedItem?.tag ?? 0
            route["cfindTest"] = editor.cfindButton.state == .on
            route["scheduleType"] = editor.schedulePopup.selectedItem?.tag ?? 0
            route["delayTime"] = max(editor.delayField.integerValue, 0)
            route["fromTime"] = editor.fromField.stringValue
            route["toTime"] = editor.toField.stringValue
            route["version"] = 1
            if let index { self.routes[index] = route } else { self.routes.append(route) }
            self.saveRoutes()
            self.tableView.reloadData()
        }
    }

    private func saveRoutes() {
        UserDefaults.standard.set(routes, forKey: "AUTOROUTINGDICTIONARY")
    }
}

private final class RemoteSearchSettingsViewController: HorosScrollableSettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate, HorosNetworkSettingsReloadable {
    private var nodes: [[String: Any]] = []
    private var selectedNodeKeys = Set<String>()
    private let tableView = NSTableView()

    init() {
        super.init(paneTitle: "Remote Search", subtitle: "Choose whether database searches and Smart Albums also query selected DICOM nodes.")
    }

    override func buildSettings() {
        addCard(title: "PACS On-Demand", rows: [
            HorosDefaultsCheckbox(title: "Search selected DICOM nodes for prior studies", defaultsKey: "searchForComparativeStudiesOnDICOMNodes"),
            HorosDefaultsCheckbox(title: "Include remote results when using the database search field", defaultsKey: "PACSOnDemandForSearchField"),
            HorosDefaultsCheckbox(title: "Include configured remote results in Smart Albums", defaultsKey: "searchForSmartAlbumStudiesOnDICOMNodes"),
            HorosDefaultsCheckbox(title: "Automatically retrieve incomplete local studies", defaultsKey: "automaticallyRetrievePartialStudies"),
            HorosDefaultsCheckbox(title: "Prefer the study containing more images", defaultsKey: "preferStudyWithMoreImages"),
            labeledRow("Concurrent retrieves", control: HorosDefaultsTextField(defaultsKey: "MaxConcurrentPODRetrieves", valueKind: .integer)),
        ])

        configureTable()
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        tableView.frame = NSRect(x: 0, y: 0, width: 760, height: 260)
        tableView.autoresizingMask = [.width]
        scroll.documentView = tableView
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        addCard(title: "Search Sources", rows: [scroll])

        let note = NSTextField(wrappingLabelWithString: "Remote Smart Album date and modality filters already stored in the database preferences are preserved. New analysis Smart Albums remain local unless remote searching is explicitly enabled here.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        addCard(title: "Smart Albums", rows: [note])
        reloadSettings()
    }

    func reloadSettings() {
        nodes = ((UserDefaults.standard.array(forKey: "SERVERS") as? [[String: Any]]) ?? []).filter {
            ($0["Activated"] as? NSNumber)?.boolValue ?? true
        }
        let savedSources = (UserDefaults.standard.array(forKey: "comparativeSearchDICOMNodes") as? [[String: Any]]) ?? []
        selectedNodeKeys = Set(savedSources.compactMap { source in
            guard let server = source["server"] as? [String: Any] else { return nil }
            return Self.nodeKey(server)
        })
        tableView.reloadData()
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        for (identifier, title, width) in [("selected", "", 34.0), ("description", "Description", 210.0), ("ae", "AE Title", 120.0), ("address", "Address", 210.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard nodes.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let node = nodes[row]
        if identifier == "selected" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(sourceChanged(_:)))
            checkbox.tag = row
            checkbox.state = selectedNodeKeys.contains(Self.nodeKey(node)) ? .on : .off
            return checkbox
        }
        let text: String
        switch identifier {
        case "description": text = node["Description"] as? String ?? ""
        case "ae": text = node["AETitle"] as? String ?? ""
        case "address": text = "\(node["Address"] ?? ""):\(node["Port"] ?? "")"
        default: text = ""
        }
        return NSTextField(labelWithString: text)
    }

    @objc private func sourceChanged(_ sender: NSButton) {
        guard nodes.indices.contains(sender.tag) else { return }
        let key = Self.nodeKey(nodes[sender.tag])
        if sender.state == .on { selectedNodeKeys.insert(key) } else { selectedNodeKeys.remove(key) }
        saveSources()
    }

    private func saveSources() {
        let sources: [[String: Any]] = nodes.filter { selectedNodeKeys.contains(Self.nodeKey($0)) }.map { node in
            [
                "activated": true,
                "name": node["Description"] as? String ?? "",
                "AETitle": node["AETitle"] as? String ?? "",
                "AddressAndPort": "\(node["Address"] ?? ""):\(node["Port"] ?? "")",
                "server": node,
            ]
        }
        UserDefaults.standard.set(sources, forKey: "comparativeSearchDICOMNodes")
        if sources.isEmpty {
            UserDefaults.standard.set(false, forKey: "searchForComparativeStudiesOnDICOMNodes")
        }
        BrowserController.currentBrowser()?.refreshComparativeStudiesIfNeeded(nil)
        BrowserController.currentBrowser()?.outlineViewRefresh()
    }

    private static func nodeKey(_ node: [String: Any]) -> String {
        "\(node["AETitle"] ?? "")|\(node["Address"] ?? "")|\(node["Port"] ?? "")"
    }
}

final class NetworkSettingsPaneViewController: HorosSettingsPaneViewController {
    private let segmentedControl = NSSegmentedControl(labels: ["Listener", "Nodes", "Routing", "Remote Search"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentContainer = NSView()
    private lazy var controllers: [NSViewController] = [
        ListenerSettingsViewController(),
        DICOMNodesSettingsViewController(),
        DICOMRoutingSettingsViewController(),
        RemoteSearchSettingsViewController(),
    ]
    private var activeController: NSViewController?

    init() {
        super.init(paneTitle: "Network")
    }

    override func loadView() {
        let root = HorosSettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        view = root

        segmentedControl.selectedSegment = 0
        segmentedControl.role = .tabs
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.frame = NSRect(x: 42, y: 18, width: 520, height: 30)
        root.addSubview(segmentedControl)

        contentContainer.frame = NSRect(x: 0, y: 58, width: root.bounds.width, height: root.bounds.height - 58)
        contentContainer.autoresizingMask = [.width, .height]
        root.addSubview(contentContainer)

        for controller in controllers { addChild(controller) }
        displayController(at: 0)
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        displayController(at: sender.selectedSegment)
    }

    private func displayController(at index: Int) {
        guard controllers.indices.contains(index) else { return }
        activeController?.view.removeFromSuperview()
        let controller = controllers[index]
        activeController = controller
        if let reloadable = controller as? HorosNetworkSettingsReloadable {
            reloadable.reloadSettings()
        }
        controller.view.frame = contentContainer.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(controller.view)
    }
}
