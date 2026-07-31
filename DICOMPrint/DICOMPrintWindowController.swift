import AppKit
import Foundation

struct DICOMPrintSource {
    let title: String
    let sliceCount: Int
    let currentSliceIndex: Int
    let frameProvider: (Int) -> MetalDICOMPrintFrame?
}

private struct DICOMPrintFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct DICOMPrintFormat {
    let title: String
    let columns: Int
    let rows: Int

    var imagesPerPage: Int {
        columns * rows
    }
}

private enum DICOMPrintPreferences {
    static let printerDefaultsKey = "AYDicomPrinter"

    static let filmOrientations = ["Portrait", "Landscape"]
    static let filmDestinations = ["Processor", "Magazine"]
    static let filmSizes = [
        "8 IN x 10 IN", "8.5 IN x 11 IN", "10 IN x 12 IN", "10 IN x 14 IN",
        "11 IN x 14 IN", "11 IN x 17 IN", "14 IN x 14 IN", "14 IN x 17 IN",
        "24 CM x  24 CM", "24 CM x  30 CM", "A4", "A3",
    ]
    static let magnificationTypes = ["NONE", "BILINEAR", "CUBIC", "REPLICATE"]
    static let trimValues = ["NO", "YES"]
    static let borderDensities = ["BLACK", "WHITE"]
    static let emptyImageDensities = ["BLACK", "WHITE"]
    static let priorities = ["HIGH", "MED", "LOW"]
    static let media = ["Blue Film", "Clear Film", "Paper"]
    static let formats = [
        DICOMPrintFormat(title: "Standard 1 × 1", columns: 1, rows: 1),
        DICOMPrintFormat(title: "Standard 1 × 2", columns: 2, rows: 1),
        DICOMPrintFormat(title: "Standard 2 × 1", columns: 1, rows: 2),
        DICOMPrintFormat(title: "Standard 2 × 2", columns: 2, rows: 2),
        DICOMPrintFormat(title: "Standard 2 × 3", columns: 3, rows: 2),
        DICOMPrintFormat(title: "Standard 2 × 4", columns: 4, rows: 2),
        DICOMPrintFormat(title: "Standard 3 × 3", columns: 3, rows: 3),
        DICOMPrintFormat(title: "Standard 3 × 4", columns: 4, rows: 3),
        DICOMPrintFormat(title: "Standard 3 × 5", columns: 5, rows: 3),
        DICOMPrintFormat(title: "Standard 4 × 4", columns: 4, rows: 4),
        DICOMPrintFormat(title: "Standard 4 × 5", columns: 5, rows: 4),
        DICOMPrintFormat(title: "Standard 4 × 6", columns: 6, rows: 4),
        DICOMPrintFormat(title: "Standard 5 × 6", columns: 6, rows: 5),
        DICOMPrintFormat(title: "Standard 5 × 7", columns: 7, rows: 5),
    ]

    static func updateLegacyTags() {
        guard let storedPrinters = UserDefaults.standard.array(forKey: printerDefaultsKey) as? [[String: Any]] else {
            return
        }

        var changed = false
        let printers = storedPrinters.map { printer -> [String: Any] in
            guard printer["imageDisplayFormatTag"] == nil else { return printer }

            var updatedPrinter = printer
            updatedPrinter["filmOrientationTag"] = tag(
                for: printer["filmOrientation"] as? String,
                in: filmOrientations
            )
            updatedPrinter["filmDestinationTag"] = tag(
                for: printer["filmDestination"] as? String,
                in: filmDestinations
            )
            updatedPrinter["filmSizeTag"] = tag(
                for: printer["filmSize"] as? String,
                in: filmSizes
            )
            updatedPrinter["magnificationTypeTag"] = tag(
                for: printer["magnificationType"] as? String,
                in: magnificationTypes
            )
            updatedPrinter["trimTag"] = tag(
                for: printer["trim"] as? String,
                in: trimValues
            )
            updatedPrinter["imageDisplayFormatTag"] = tag(
                for: printer["imageDisplayFormat"] as? String,
                in: [
                    "Standard 1,1", "Standard 1,2", "Standard 2,1", "Standard 2,2",
                    "Standard 2,3", "Standard 2,4", "Standard 3,3", "Standard 3,4",
                    "Standard 3,5", "Standard 4,4", "Standard 4,5", "Standard 4,6",
                    "Standard 5,6", "Standard 5,7",
                ]
            )
            updatedPrinter["borderDensityTag"] = tag(
                for: printer["borderDensity"] as? String,
                in: borderDensities
            )
            updatedPrinter["emptyImageDensityTag"] = tag(
                for: printer["emptyImageDensity"] as? String,
                in: emptyImageDensities
            )
            updatedPrinter["priorityTag"] = tag(
                for: printer["priority"] as? String,
                in: priorities
            )
            updatedPrinter["mediumTag"] = tag(
                for: printer["medium"] as? String,
                in: media
            )
            changed = true
            return updatedPrinter
        }

        if changed {
            UserDefaults.standard.set(printers, forKey: printerDefaultsKey)
        }
    }

    static func printers() -> [[String: Any]] {
        updateLegacyTags()
        return UserDefaults.standard.array(forKey: printerDefaultsKey) as? [[String: Any]] ?? []
    }

    private static func tag(for value: String?, in values: [String]) -> String {
        String(values.firstIndex(of: value ?? "") ?? 0)
    }
}

final class DICOMPrintWindowController: NSWindowController, NSWindowDelegate {
    private enum SelectionMode: Int {
        case currentImage
        case entireSeries
    }

    private let source: DICOMPrintSource
    private var printers: [[String: Any]]
    private var isPrinting = false

    private let printerPopUp = NSPopUpButton()
    private let printerDetailsLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionPopUp = NSPopUpButton()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let intervalField = NSTextField()
    private let rangeGrid = NSGridView(frame: .zero)
    private let formatPopUp = NSPopUpButton()
    private let copiesField = NSTextField()
    private let pagesLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let verifyButton = NSButton()
    private let printButton = NSButton()
    private let cancelButton = NSButton()

    var didClose: (() -> Void)?

    init(source: DICOMPrintSource) {
        self.source = source
        self.printers = DICOMPrintPreferences.printers()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(
            format: NSLocalizedString("DICOM Print — %@", comment: ""),
            source.title
        )
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self

        configureInterface()
        configureInitialValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func updateAllPreferencesFormat() {
        DICOMPrintPreferences.updateLegacyTags()
    }

    func present() {
        guard printers.isEmpty == false else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("DICOM Print", comment: "")
            alert.informativeText = NSLocalizedString(
                "No DICOM printers are configured. Add a printer in Settings before printing.",
                comment: ""
            )
            alert.runModal()
            didClose?()
            return
        }

        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard isPrinting == false else { return }
        didClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isPrinting == false
    }

    private func configureInterface() {
        guard let contentView = window?.contentView else { return }

        printerPopUp.target = self
        printerPopUp.action = #selector(printerChanged(_:))

        printerDetailsLabel.textColor = .secondaryLabelColor
        printerDetailsLabel.maximumNumberOfLines = 2

        selectionPopUp.addItem(withTitle: NSLocalizedString("Current image", comment: ""))
        selectionPopUp.lastItem?.tag = SelectionMode.currentImage.rawValue
        selectionPopUp.addItem(withTitle: NSLocalizedString("Entire series", comment: ""))
        selectionPopUp.lastItem?.tag = SelectionMode.entireSeries.rawValue
        selectionPopUp.target = self
        selectionPopUp.action = #selector(selectionChanged(_:))

        configureIntegerField(fromField)
        configureIntegerField(toField)
        configureIntegerField(intervalField)
        configureIntegerField(copiesField)
        for field in [fromField, toField, intervalField, copiesField] {
            field.target = self
            field.action = #selector(printOptionsChanged(_:))
        }

        let fromLabel = NSTextField(labelWithString: NSLocalizedString("From", comment: ""))
        let toLabel = NSTextField(labelWithString: NSLocalizedString("To", comment: ""))
        let intervalLabel = NSTextField(labelWithString: NSLocalizedString("Interval", comment: ""))
        rangeGrid.addRow(with: [fromLabel, fromField, toLabel, toField, intervalLabel, intervalField])
        rangeGrid.column(at: 1).width = 64
        rangeGrid.column(at: 3).width = 64
        rangeGrid.column(at: 5).width = 64

        for format in DICOMPrintPreferences.formats {
            formatPopUp.addItem(withTitle: format.title)
        }
        formatPopUp.target = self
        formatPopUp.action = #selector(printOptionsChanged(_:))

        pagesLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.stringValue = NSLocalizedString(
            "Images are rendered by Metal and sent as DICOM grayscale print objects.",
            comment: ""
        )

        progressIndicator.isIndeterminate = true
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true

        verifyButton.title = NSLocalizedString("Verify", comment: "")
        verifyButton.bezelStyle = .rounded
        verifyButton.target = self
        verifyButton.action = #selector(verifyConnection(_:))

        printButton.title = NSLocalizedString("Print", comment: "")
        printButton.bezelStyle = .rounded
        printButton.keyEquivalent = "\r"
        printButton.target = self
        printButton.action = #selector(printImages(_:))

        cancelButton.title = NSLocalizedString("Cancel", comment: "")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        let printerRow = labeledRow(
            title: NSLocalizedString("Printer", comment: ""),
            control: printerPopUp
        )
        let selectionRow = labeledRow(
            title: NSLocalizedString("Images", comment: ""),
            control: selectionPopUp
        )
        let formatRow = labeledRow(
            title: NSLocalizedString("Film layout", comment: ""),
            control: formatPopUp
        )
        let copiesRow = labeledRow(
            title: NSLocalizedString("Copies", comment: ""),
            control: copiesField
        )

        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let buttonRow = NSStackView(views: [verifyButton, NSView(), cancelButton, printButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            printerRow,
            printerDetailsLabel,
            separator(),
            selectionRow,
            rangeGrid,
            formatRow,
            copiesRow,
            pagesLabel,
            separator(),
            statusRow,
            buttonRow,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.setCustomSpacing(5, after: printerRow)
        stack.setCustomSpacing(16, after: printerDetailsLabel)
        stack.setCustomSpacing(5, after: selectionRow)
        stack.setCustomSpacing(16, after: pagesLabel)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            printerPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            formatPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            copiesField.widthAnchor.constraint(equalToConstant: 80),
        ])
    }

    private func configureInitialValues() {
        for printer in printers {
            printerPopUp.addItem(withTitle: stringValue(printer["printerName"], fallback: "DICOM Printer"))
        }
        let defaultIndex = printers.firstIndex {
            stringValue($0["defaultPrinter"], fallback: "") == "1"
        } ?? 0
        printerPopUp.selectItem(at: defaultIndex)

        let sliceCount = max(source.sliceCount, 1)
        fromField.integerValue = 1
        toField.integerValue = sliceCount
        intervalField.integerValue = 1
        selectionPopUp.selectItem(withTag: SelectionMode.currentImage.rawValue)
        updatePrinterOptions()
        updateSelectionControls()
        updatePageCount()
    }

    private func configureIntegerField(_ field: NSTextField) {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        field.formatter = formatter
        field.alignment = .right
        field.stringValue = "1"
    }

    private func labeledRow(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, control, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private var selectedPrinter: [String: Any]? {
        guard printers.indices.contains(printerPopUp.indexOfSelectedItem) else { return nil }
        return printers[printerPopUp.indexOfSelectedItem]
    }

    private var selectionMode: SelectionMode {
        SelectionMode(rawValue: selectionPopUp.selectedTag()) ?? .currentImage
    }

    private var selectedFormat: DICOMPrintFormat {
        let index = min(max(formatPopUp.indexOfSelectedItem, 0), DICOMPrintPreferences.formats.count - 1)
        return DICOMPrintPreferences.formats[index]
    }

    private func selectedSliceIndices() -> [Int] {
        guard source.sliceCount > 0 else { return [] }
        if selectionMode == .currentImage {
            return [min(max(source.currentSliceIndex, 0), source.sliceCount - 1)]
        }

        let first = min(max(fromField.integerValue - 1, 0), source.sliceCount - 1)
        let last = min(max(toField.integerValue - 1, 0), source.sliceCount - 1)
        let lowerBound = min(first, last)
        let upperBound = max(first, last)
        let interval = max(intervalField.integerValue, 1)
        return Array(stride(from: lowerBound, through: upperBound, by: interval))
    }

    @objc private func printerChanged(_ sender: Any?) {
        updatePrinterOptions()
        updatePageCount()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateSelectionControls()
        updatePageCount()
    }

    @objc private func printOptionsChanged(_ sender: Any?) {
        updatePageCount()
    }

    private func updatePrinterOptions() {
        guard let printer = selectedPrinter else {
            printButton.isEnabled = false
            verifyButton.isEnabled = false
            return
        }

        let host = stringValue(printer["host"], fallback: "")
        let port = stringValue(printer["port"], fallback: "")
        let aeTitle = stringValue(printer["aeTitle"], fallback: "")
        printerDetailsLabel.stringValue = "\(host):\(port)  •  AE \(aeTitle)"

        let formatIndex = indexedValue(
            printer["imageDisplayFormatTag"],
            count: DICOMPrintPreferences.formats.count
        )
        formatPopUp.selectItem(at: formatIndex)
        copiesField.integerValue = max(integerValue(printer["copies"], fallback: 1), 1)
        printButton.isEnabled = true
        verifyButton.isEnabled = true
    }

    private func updateSelectionControls() {
        rangeGrid.isHidden = selectionMode != .entireSeries
    }

    private func updatePageCount() {
        let imageCount = selectedSliceIndices().count
        let imagesPerPage = max(selectedFormat.imagesPerPage, 1)
        let pageCount = max((imageCount + imagesPerPage - 1) / imagesPerPage, imageCount == 0 ? 0 : 1)
        pagesLabel.stringValue = String(
            format: NSLocalizedString("%ld images • %ld pages", comment: ""),
            imageCount,
            pageCount
        )
    }

    @objc private func cancel(_ sender: Any?) {
        guard isPrinting == false else { return }
        close()
    }

    @objc private func verifyConnection(_ sender: Any?) {
        guard let printer = selectedPrinter else { return }
        setBusy(true, message: NSLocalizedString("Verifying printer connection…", comment: ""))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try DICOMPrintJob.verify(printer: printer)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                switch result {
                case .success:
                    self.statusLabel.stringValue = NSLocalizedString("Printer connection verified.", comment: "")
                case let .failure(error):
                    self.presentError(
                        title: NSLocalizedString("Verification failed", comment: ""),
                        error: error
                    )
                }
            }
        }
    }

    @objc private func printImages(_ sender: Any?) {
        guard let printer = selectedPrinter else { return }
        let indices = selectedSliceIndices()
        guard indices.isEmpty == false else {
            presentError(
                title: NSLocalizedString("Print failed", comment: ""),
                error: DICOMPrintFailure(message: NSLocalizedString("There are no images selected.", comment: ""))
            )
            return
        }

        let pageCount = (indices.count + selectedFormat.imagesPerPage - 1) / selectedFormat.imagesPerPage
        if pageCount > 10 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("DICOM Print", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("Are you sure you want to print %ld pages?", comment: ""),
                pageCount
            )
            alert.addButton(withTitle: NSLocalizedString("Print", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isPrinting = true
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        setBusy(true, message: NSLocalizedString("Rendering images with Metal…", comment: ""))

        captureFrames(indices: indices, position: 0, captured: []) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.finishPrinting(result: .failure(error))
            case let .success(frames):
                let format = self.selectedFormat
                let copies = max(self.copiesField.integerValue, 1)
                self.statusLabel.stringValue = NSLocalizedString("Creating and sending DICOM print objects…", comment: "")
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<Void, Error>
                    do {
                        try DICOMPrintJob(
                            printer: printer,
                            format: format,
                            copies: copies,
                            frames: frames
                        ).run()
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    DispatchQueue.main.async {
                        self.finishPrinting(result: result)
                    }
                }
            }
        }
    }

    private func captureFrames(
        indices: [Int],
        position: Int,
        captured: [MetalDICOMPrintFrame],
        completion: @escaping (Result<[MetalDICOMPrintFrame], Error>) -> Void
    ) {
        guard indices.indices.contains(position) else {
            completion(.success(captured))
            return
        }

        let sliceIndex = indices[position]
        statusLabel.stringValue = String(
            format: NSLocalizedString("Rendering image %ld of %ld with Metal…", comment: ""),
            position + 1,
            indices.count
        )

        guard let frame = source.frameProvider(sliceIndex) else {
            completion(.failure(DICOMPrintFailure(
                message: String(
                    format: NSLocalizedString("Metal could not render image %ld.", comment: ""),
                    sliceIndex + 1
                )
            )))
            return
        }

        var nextCaptured = captured
        nextCaptured.append(frame)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.captureFrames(
                indices: indices,
                position: position + 1,
                captured: nextCaptured,
                completion: completion
            )
        }
    }

    private func finishPrinting(result: Result<Void, Error>) {
        isPrinting = false
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        setBusy(false, message: "")

        switch result {
        case .success:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("DICOM Print", comment: "")
            alert.informativeText = NSLocalizedString("The print job was sent to the printer.", comment: "")
            alert.runModal()
            close()
        case let .failure(error):
            presentError(title: NSLocalizedString("Print failed", comment: ""), error: error)
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        progressIndicator.isHidden = !busy
        if busy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        for control in [
            printerPopUp, selectionPopUp, fromField, toField, intervalField,
            formatPopUp, copiesField, verifyButton, printButton, cancelButton,
        ] {
            control.isEnabled = !busy
        }
        if message.isEmpty == false {
            statusLabel.stringValue = message
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .critical
        alert.messageText = title
        alert.runModal()
        statusLabel.stringValue = error.localizedDescription
    }

    private func indexedValue(_ value: Any?, count: Int) -> Int {
        min(max(integerValue(value, fallback: 0), 0), max(count - 1, 0))
    }

    private func integerValue(_ value: Any?, fallback: Int) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let number = Int(string) {
            return number
        }
        return fallback
    }

    private func stringValue(_ value: Any?, fallback: String) -> String {
        if let value = value as? String, value.isEmpty == false {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return fallback
    }
}

private struct DICOMPrintJob {
    let printer: [String: Any]
    let format: DICOMPrintFormat
    let copies: Int
    let frames: [MetalDICOMPrintFrame]

    func run() throws {
        try Self.validateNetworkConfiguration(printer)

        let fileManager = FileManager.default
        let jobDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Horos-DICOM-Print-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: jobDirectory)
        }

        let databaseDirectory = jobDirectory.appendingPathComponent("database", isDirectory: true)
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        let logDirectory = try makeLogDirectory()
        let printConfigurationURL = jobDirectory.appendingPathComponent("printer.cfg")
        let loggerConfigurationURL = jobDirectory.appendingPathComponent("logger.cfg")
        try printConfiguration().write(to: printConfigurationURL, atomically: true, encoding: .utf8)
        try loggerConfiguration(logDirectory: logDirectory)
            .write(to: loggerConfigurationURL, atomically: true, encoding: .utf8)

        let imageFiles = try writeDICOMImages(to: jobDirectory)
        let imagesPerPage = max(format.imagesPerPage, 1)
        for pageStart in stride(from: 0, to: imageFiles.count, by: imagesPerPage) {
            let pageEnd = min(pageStart + imagesPerPage, imageFiles.count)
            var arguments = commonArguments(
                printConfigurationURL: printConfigurationURL,
                loggerConfigurationURL: loggerConfigurationURL
            )
            arguments += presentationStateArguments()
            arguments += imageFiles[pageStart..<pageEnd].map(\.path)
            _ = try Self.runTool(
                named: "dcmpsprt",
                arguments: arguments,
                currentDirectory: jobDirectory
            )
        }

        let presentationStates = try fileManager.contentsOfDirectory(
            at: databaseDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("SP_") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard presentationStates.isEmpty == false else {
            throw DICOMPrintFailure(message: NSLocalizedString(
                "DCMTK did not create any DICOM presentation states.",
                comment: ""
            ))
        }

        var sendArguments = commonArguments(
            printConfigurationURL: printConfigurationURL,
            loggerConfigurationURL: loggerConfigurationURL
        )
        sendArguments += [
            "--printer", "PRINTSCP",
            "--copies", String(max(copies, 1)),
            "--priority", indexedString(
                printer["priorityTag"],
                values: DICOMPrintPreferences.priorities
            ),
            "--destination", indexedString(
                printer["filmDestinationTag"],
                values: DICOMPrintPreferences.filmDestinations
            ).uppercased(),
            "--medium-type", indexedString(
                printer["mediumTag"],
                values: DICOMPrintPreferences.media
            ).uppercased(),
        ]
        sendArguments += presentationStates.map(\.path)
        _ = try Self.runTool(
            named: "dcmprscu",
            arguments: sendArguments,
            currentDirectory: jobDirectory
        )
    }

    static func verify(printer: [String: Any]) throws {
        try validateNetworkConfiguration(printer)

        let host = stringValue(printer["host"], fallback: "")
        let port = integerValue(printer["port"], fallback: 0)
        let calledAETitle = stringValue(printer["aeTitle"], fallback: "")

        let callingAETitle = UserDefaults.standard.string(forKey: "AETITLE") ?? "HOROS"
        _ = try runTool(
            named: "echoscu",
            arguments: [
                host, String(port),
                "-aet", callingAETitle,
                "-aec", calledAETitle,
                "-to", "5",
                "-ta", "5",
                "-td", "5",
            ],
            currentDirectory: nil
        )
    }

    private static func validateNetworkConfiguration(_ printer: [String: Any]) throws {
        let host = stringValue(printer["host"], fallback: "")
        let port = integerValue(printer["port"], fallback: 0)
        let calledAETitle = stringValue(printer["aeTitle"], fallback: "")
        guard host.isEmpty == false, port > 0, calledAETitle.isEmpty == false else {
            throw DICOMPrintFailure(message: NSLocalizedString(
                "The selected printer has an incomplete network configuration.",
                comment: ""
            ))
        }
    }

    private func writeDICOMImages(to directory: URL) throws -> [URL] {
        var imageFiles: [URL] = []
        for (index, frame) in frames.enumerated() {
            let outputURL = directory.appendingPathComponent(
                String(format: "image-%05ld.dcm", index + 1)
            )
            let exporter = DICOMExport()
            if let sourceFilePath = frame.sourceFilePath, sourceFilePath.isEmpty == false {
                exporter.setSourceFile(sourceFilePath)
            }
            exporter.setSeriesDescription("Horos Metal DICOM Print")
            exporter.setSeriesNumber(67_000 + DICOMExport.currentTimeSeriesNumberOffset())

            let writtenPath: String = try frame.grayscalePixels.withUnsafeBytes { bytes in
                guard let pixels = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw DICOMPrintFailure(message: NSLocalizedString(
                        "A rendered print image did not contain pixel data.",
                        comment: ""
                    ))
                }
                exporter.setPixelData(
                    UnsafeMutablePointer(mutating: pixels),
                    samplesPerPixel: 1,
                    bitsPerSample: 8,
                    width: frame.width,
                    height: frame.height
                )
                guard let writtenPath = exporter.writeDCMFile(outputURL.path) else {
                    throw DICOMPrintFailure(message: NSLocalizedString(
                        "Horos could not create a DICOM print image.",
                        comment: ""
                    ))
                }
                return writtenPath
            }
            imageFiles.append(URL(fileURLWithPath: writtenPath))
        }
        return imageFiles
    }

    private func commonArguments(
        printConfigurationURL: URL,
        loggerConfigurationURL: URL
    ) -> [String] {
        [
            "-c", printConfigurationURL.path,
            "-lc", loggerConfigurationURL.path,
        ]
    }

    private func presentationStateArguments() -> [String] {
        let filmSize = indexedString(
            printer["filmSizeTag"],
            values: DICOMPrintPreferences.filmSizes
        )
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ".", with: "_")
        let magnification = indexedString(
            printer["magnificationTypeTag"],
            values: DICOMPrintPreferences.magnificationTypes
        )
        let configurationInformation = Self.stringValue(
            printer["configurationInformation"],
            fallback: ""
        )
        let borderDensity = indexedString(
            printer["borderDensityTag"],
            values: DICOMPrintPreferences.borderDensities
        )
        let emptyImageDensity = indexedString(
            printer["emptyImageDensityTag"],
            values: DICOMPrintPreferences.emptyImageDensities
        )
        let trim = indexedValue(printer["trimTag"], count: DICOMPrintPreferences.trimValues.count) == 0
            ? "--no-trim"
            : "--trim"
        let orientation = indexedValue(
            printer["filmOrientationTag"],
            count: DICOMPrintPreferences.filmOrientations.count
        ) == 0 ? "--portrait" : "--landscape"

        return [
            "--printer", "PRINTSCP",
            "--layout", String(format.columns), String(format.rows),
            "--filmsize", filmSize.uppercased(),
            "--magnification", magnification,
            "--configinfo", configurationInformation,
            "--border", borderDensity,
            "--empty-image", emptyImageDensity,
            trim,
            orientation,
        ]
    }

    private func printConfiguration() -> String {
        let printerAETitle = Self.sanitizedConfigurationValue(
            Self.stringValue(printer["aeTitle"], fallback: "")
        )
        let host = Self.sanitizedConfigurationValue(
            Self.stringValue(printer["host"], fallback: "")
        )
        let port = max(Self.integerValue(printer["port"], fallback: 0), 0)
        let callingAETitle = Self.sanitizedConfigurationValue(
            UserDefaults.standard.string(forKey: "AETITLE") ?? "HOROS_DICOM_PRINT"
        )
        let filmDestination = indexedString(
            printer["filmDestinationTag"],
            values: DICOMPrintPreferences.filmDestinations
        ).uppercased()
        let filmSize = indexedString(
            printer["filmSizeTag"],
            values: DICOMPrintPreferences.filmSizes
        )
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ".", with: "_")
        .uppercased()
        let medium = indexedString(
            printer["mediumTag"],
            values: DICOMPrintPreferences.media
        ).uppercased()
        let magnification = indexedString(
            printer["magnificationTypeTag"],
            values: DICOMPrintPreferences.magnificationTypes
        )

        return """
        [[GENERAL]]

        [DATABASE]
        Directory = database

        [NETWORK]
        aetitle = \(callingAETitle)

        [[COMMUNICATION]]

        [PRINTSCP]
        Aetitle = \(printerAETitle)
        Description = DICOM Printer
        Hostname = \(host)
        Port = \(port)
        Type = LOCALPRINTER
        DisableNewVRs = true
        DisplayFormat=\(format.columns),\(format.rows)
        FilmDestination = \(filmDestination)
        FilmSizeID = \(filmSize)
        ImplicitOnly = true
        MagnificationType = \(magnification)
        MaxDensity = 320
        MaxPDU = 16384
        MediumType = \(medium)
        OmitSOPClassUIDFromCreateResponse = true
        PresentationLUTMatchRequired = true
        PresentationLUTinFilmSession = false
        Supports12Bit = false
        SupportsPresentationLUT = false
        """
    }

    private func loggerConfiguration(logDirectory: URL) -> String {
        """
        log4cplus.rootLogger = INFO, logfile
        log4cplus.appender.logfile = log4cplus::FileAppender
        log4cplus.appender.logfile.File = \(logDirectory.appendingPathComponent("print.log").path)
        log4cplus.appender.logfile.Append = true
        log4cplus.appender.logfile.ImmediateFlush = true
        """
    }

    private func makeLogDirectory() throws -> URL {
        let libraryDirectory = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let logDirectory = libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("HorosDicomPrint", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        return logDirectory
    }

    private func indexedString(_ value: Any?, values: [String]) -> String {
        values[indexedValue(value, count: values.count)]
    }

    private func indexedValue(_ value: Any?, count: Int) -> Int {
        min(max(Self.integerValue(value, fallback: 0), 0), max(count - 1, 0))
    }

    private static func runTool(
        named name: String,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> String {
        guard let resourceDirectory = Bundle.main.resourceURL else {
            throw DICOMPrintFailure(message: NSLocalizedString(
                "Horos could not locate its DICOM print resources.",
                comment: ""
            ))
        }
        let executableURL = resourceDirectory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw DICOMPrintFailure(message: String(
                format: NSLocalizedString("The bundled %@ tool is missing or is not executable.", comment: ""),
                name
            ))
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["DCMDICTPATH"] = resourceDirectory.appendingPathComponent("dicom.dic").path
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DICOMPrintFailure(message: detail.isEmpty
                ? String(
                    format: NSLocalizedString("%@ failed with status %d.", comment: ""),
                    name,
                    process.terminationStatus
                )
                : detail
            )
        }
        return output
    }

    private static func sanitizedConfigurationValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func integerValue(_ value: Any?, fallback: Int) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let number = Int(string) {
            return number
        }
        return fallback
    }

    private static func stringValue(_ value: Any?, fallback: String) -> String {
        if let value = value as? String, value.isEmpty == false {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return fallback
    }
}
