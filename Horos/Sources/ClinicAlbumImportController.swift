import AppKit
import CoreData
import Vision
import ImageIO

private enum ClinicAlbumError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private enum ClinicAlbumStore {
    // These value predicates are immutable after construction and contain no managed objects.
    private struct FetchPredicate: @unchecked Sendable {
        let value: NSPredicate
    }
    static func study(_ object: NSManagedObject) -> ClinicStudy {
        // Dictionary fetches return the stored name; DicomStudy.name formats it for display.
        // Fire the fault before reading the primitive value so validation compares like with like.
        object.willAccessValue(forKey: "name")
        defer { object.didAccessValue(forKey: "name") }
        return ClinicStudy(uri: object.objectID.uriRepresentation().absoluteString,
                    name: object.primitiveValue(forKey: "name") as? String ?? "",
                    patientID: object.value(forKey: "patientID") as? String ?? "",
                    patientUID: object.value(forKey: "patientUID") as? String ?? "",
                    birthDate: object.value(forKey: "dateOfBirth") as? Date,
                    sex: object.value(forKey: "patientSex") as? String ?? "")
    }

    static func fetch(_ predicate: NSPredicate, in context: NSManagedObjectContext) async throws -> [ClinicStudy] {
        let filter = FetchPredicate(value: predicate)
        return try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Study")
            request.resultType = .dictionaryResultType
            request.predicate = filter.value
            let objectID = NSExpressionDescription()
            objectID.name = "objectID"
            objectID.expression = NSExpression.expressionForEvaluatedObject()
            objectID.expressionResultType = .objectIDAttributeType
            request.propertiesToFetch = [objectID, "name", "patientID", "patientUID", "dateOfBirth", "patientSex"]
            return try context.fetch(request).map { row in
                guard let id = row["objectID"] as? NSManagedObjectID else {
                    throw ClinicAlbumError.message("A study identifier could not be read.")
                }
                return ClinicStudy(uri: id.uriRepresentation().absoluteString,
                                   name: row["name"] as? String ?? "", patientID: row["patientID"] as? String ?? "",
                                   patientUID: row["patientUID"] as? String ?? "", birthDate: row["dateOfBirth"] as? Date,
                                   sex: row["patientSex"] as? String ?? "")
            }
        }
    }

    @MainActor
    static func matches(query: String, browser: BrowserController, in context: NSManagedObjectContext) async throws -> [ClinicStudy] {
        let parsed = ClinicAlbumMatching.names(from: [(query, 1)]).first
        let search = ClinicAlbumMatching.searchName(parsed?.name ?? query)
        guard !search.isEmpty else { return [] }
        let namePredicate = browser.patientsnamePredicate(search) ?? NSPredicate(value: false)
        var seedPredicate: NSPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            namePredicate, NSPredicate(format: "patientID == %@", query.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        if let id = parsed?.patientID {
            let exactID = NSPredicate(format: "patientID == %@", id)
            // Prefer the identifier over names; expand the resulting identity group below.
            if !(try await fetch(exactID, in: context)).isEmpty { seedPredicate = exactID }
        }
        let procedureName = StructuredReportSupport.surgicalProcedureSeriesDescription()
        let surgery = NSPredicate(format: "ANY series.name ==[cd] %@ OR ANY series.seriesDescription ==[cd] %@", procedureName, procedureName)
        let notSurgery = NSCompoundPredicate(notPredicateWithSubpredicate: surgery)
        var found: [String: ClinicStudy] = [:]
        var pending = try await fetch(NSCompoundPredicate(andPredicateWithSubpredicates: [seedPredicate, notSurgery]), in: context)
        var predicates: [NSPredicate] = [seedPredicate]
        var processed = Set<String>()
        // Match the database's transitive study grouping. Surgery records are terminal
        // matches, not bridges that expand the imaging identity group.
        while !pending.isEmpty {
            try Task.checkCancellation()
            var nextPredicates: [NSPredicate] = []
            for record in pending {
                found[record.uri] = record
                var values: [String: Any] = ["type": "Study", "name": record.name,
                                           "patientID": record.patientID, "patientUID": record.patientUID]
                if let date = record.birthDate { values["dateOfBirth"] = date }
                if let predicate = browser.samePatientStudiesPredicate(forStudy: values),
                   processed.insert(predicate.predicateFormat).inserted {
                    nextPredicates.append(predicate)
                }
            }
            predicates.append(contentsOf: nextPredicates)
            pending = []
            for offset in stride(from: 0, to: nextPredicates.count, by: 64) {
                let batch = Array(nextPredicates[offset..<min(offset + 64, nextPredicates.count)])
                let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSCompoundPredicate(orPredicateWithSubpredicates: batch), notSurgery
                ])
                for record in try await fetch(combined, in: context) where found[record.uri] == nil {
                    found[record.uri] = record
                    pending.append(record)
                }
            }
        }
        for offset in stride(from: 0, to: predicates.count, by: 64) {
            try Task.checkCancellation()
            let batch = Array(predicates[offset..<min(offset + 64, predicates.count)])
            let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSCompoundPredicate(orPredicateWithSubpredicates: batch), surgery
            ])
            for record in try await fetch(combined, in: context) { found[record.uri] = record }
        }
        return found.values.sorted { $0.uri < $1.uri }
    }

    struct Saved: @unchecked Sendable {
        let name: String
        let inserted: [NSManagedObjectID]
        let updated: [NSManagedObjectID]
    }

    static func create(name: String, studies: [ClinicStudy], in context: NSManagedObjectContext) async throws -> Saved {
        try await context.perform {
            // Use an isolated transaction, not a save/rollback of the browser's pending edits.
            context.reset()
            do {
                guard let coordinator = context.persistentStoreCoordinator, !studies.isEmpty else {
                    throw ClinicAlbumError.message("No studies were selected.")
                }
                var objects = Set<NSManagedObject>()
                for expected in studies {
                    guard let url = URL(string: expected.uri),
                          let id = coordinator.managedObjectID(forURIRepresentation: url),
                          let object = try? context.existingObject(with: id),
                          !object.isDeleted, object.entity.name == "Study", study(object) == expected else {
                        throw ClinicAlbumError.message("A selected study was removed or its patient details changed. Close this preview and read the clipboard again.")
                    }
                    objects.insert(object)
                }
                let request = NSFetchRequest<NSManagedObject>(entityName: "Album")
                let usedNames = Set(try context.fetch(request).compactMap { $0.value(forKey: "name") as? String })
                var uniqueName = name
                var suffix = 2
                while usedNames.contains(uniqueName) {
                    uniqueName = "\(name) #\(suffix)"
                    suffix += 1
                }
                let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
                album.setValue(uniqueName, forKey: "name")
                album.setValue(false, forKey: "smartAlbum")
                album.mutableSetValue(forKey: "studies").addObjects(from: Array(objects))
                try context.obtainPermanentIDs(for: [album])
                let inserted = context.insertedObjects.map(\.objectID)
                let updated = context.updatedObjects.map(\.objectID)
                try context.save()
                return Saved(name: uniqueName, inserted: inserted, updated: updated)
            } catch {
                context.rollback()
                throw error
            }
        }
    }
}

@MainActor
@objc(ClinicAlbumImportController)
final class ClinicAlbumImportController: NSObject {
    private static let shared = ClinicAlbumImportController()
    private var preview: ClinicAlbumReviewController?

    @objc class func installMenuItem() {
        guard let file = NSApp.mainMenu?.item(withTitle: NSLocalizedString("File", comment: ""))?.submenu,
              let menu = file.item(withTitle: NSLocalizedString("Import", comment: ""))?.submenu else { return }
        let selector = #selector(importClipboard(_:))
        guard !menu.items.contains(where: { $0.action == selector }) else { return }
        let item = NSMenuItem(title: "Create Clinic Album from Clipboard...", action: selector, keyEquivalent: "")
        item.target = shared
        menu.addItem(item)
    }

    @objc private func importClipboard(_ sender: Any?) {
        if let window = preview?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let browser = BrowserController.currentBrowser(), let database = browser.database,
              database.isLocal(), !database.isReadOnly,
              let mainContext = database.managedObjectContext,
              let coordinator = mainContext.persistentStoreCoordinator else {
            Self.showError("Select a writable local database first.", window: NSApp.keyWindow)
            return
        }
        let clipboard = NSPasteboard.general
        guard let data = clipboard.data(forType: .png) ?? clipboard.data(forType: .tiff),
              let image = NSImage(data: data) else {
            Self.showError("The clipboard does not contain an image. Copy the clinic screenshot and try again.", window: browser.window)
            return
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        let controller = ClinicAlbumReviewController(image: image, browser: browser, database: database, context: context)
        controller.onClose = { [weak self] in self?.preview = nil }
        preview = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.load(data: data)
    }

    static func showError(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Clinic Album"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

@MainActor
private final class ClinicAlbumReviewController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private struct Row {
        let source: ClinicName
        var query: String
        var studies: [ClinicStudy]
        var included: Bool
        var revision = UUID()
        var error: String?
    }
    private weak var browser: BrowserController?
    private let database: DicomDatabase
    private let context: NSManagedObjectContext
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Reading clipboard image...")
    private let albumName = NSTextField(string: "Clinic - " + Date().formatted(date: .abbreviated, time: .omitted))
    private let clinicDate = NSDatePicker()
    private let create = NSButton(title: "Create Album", target: nil, action: nil)
    private let add = NSButton()
    private let refresh = NSButton()
    private var rows: [Row] = []
    private var task: Task<Void, Never>?
    private var searches: [Int: Task<Void, Never>] = [:]
    private var loading = true
    private var committing = false
    var onClose: (() -> Void)?

    init(image: NSImage, browser: BrowserController, database: DicomDatabase, context: NSManagedObjectContext) {
        self.browser = browser
        self.database = database
        self.context = context
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Clinic Album Review"
        window.minSize = NSSize(width: 1000, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }

        let nameLabel = NSTextField(labelWithString: "Album:")
        let dateLabel = NSTextField(labelWithString: "Clinic date:")
        clinicDate.datePickerElements = [.yearMonthDay]
        clinicDate.dateValue = Date()
        clinicDate.target = self
        clinicDate.action = #selector(dateChanged)
        create.target = self
        create.action = #selector(confirmCreate)
        create.isEnabled = false
        create.bezelStyle = .rounded
        let close = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        close.keyEquivalent = "\u{1b}"
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add patient")
        add.target = self
        add.action = #selector(addPatient)
        add.isEnabled = false
        add.bezelStyle = .rounded
        add.toolTip = "Add patient"
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh local studies")
        refresh.target = self
        refresh.action = #selector(refreshStudies)
        refresh.bezelStyle = .rounded
        refresh.isEnabled = false
        refresh.toolTip = "Refresh local studies after retrieving from PACS"

        for (id, title, width) in [("include", "Add", 40.0), ("source", "Clipboard name", 185.0),
                                   ("query", "Search name or ID", 185.0), ("patient", "Database patient / ID / DOB / studies", 380.0),
                                   ("pacs", "PACS", 50.0), ("status", "Review", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 32
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let screenshot = NSImageView()
        screenshot.image = image
        screenshot.imageScaling = .scaleProportionallyUpOrDown
        screenshot.toolTip = "Clipboard screenshot"
        status.textColor = .secondaryLabelColor
        for view in [nameLabel, albumName, dateLabel, clinicDate, scroll, screenshot, status, refresh, add, close, create] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            nameLabel.centerYAnchor.constraint(equalTo: albumName.centerYAnchor),
            albumName.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            albumName.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            albumName.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -20),
            dateLabel.centerYAnchor.constraint(equalTo: albumName.centerYAnchor),
            clinicDate.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 8),
            clinicDate.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            clinicDate.centerYAnchor.constraint(equalTo: albumName.centerYAnchor),
            screenshot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            screenshot.widthAnchor.constraint(equalToConstant: 140),
            screenshot.topAnchor.constraint(equalTo: scroll.topAnchor),
            screenshot.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: screenshot.trailingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: albumName.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            create.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            create.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            close.trailingAnchor.constraint(equalTo: create.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            add.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            add.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 32),
            refresh.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(data: Data) {
        task = Task { [weak self] in
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let names = try await Self.recognize(data)
                let recognized = ProcessInfo.processInfo.systemUptime
                guard !Task.isCancelled, let self, let browser = self.browser else { return }
                self.rows = names.map { Row(source: $0, query: $0.searchQuery, studies: [], included: false) }
                for index in self.rows.indices {
                    self.status.stringValue = "Finding studies and surgeries: \(index + 1) of \(names.count)..."
                    let studies = try await ClinicAlbumStore.matches(query: self.rows[index].query, browser: browser, in: self.context)
                    try Task.checkCancellation()
                    self.rows[index].studies = studies
                    self.rows[index].included = !studies.isEmpty
                    self.table.reloadData()
                }
                self.loading = false
                self.add.isEnabled = true
                self.table.reloadData()
                self.updateStatus()
                NSLog("CLINICALBUM OCR=%.0fms matching=%.0fms rows=%ld studies=%ld", (recognized - start) * 1000,
                      (ProcessInfo.processInfo.systemUptime - recognized) * 1000, names.count, self.selectedStudies.count)
                if names.isEmpty {
                    ClinicAlbumImportController.showError("No patient names were recognized in the clipboard image.", window: self.window)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status.stringValue = "Could not prepare the clinic album."
                ClinicAlbumImportController.showError(error.localizedDescription, window: self.window)
            }
        }
    }

    private nonisolated static func recognize(_ data: Data) async throws -> [ClinicName] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000
              ] as CFDictionary) else {
            throw ClinicAlbumError.message("The clipboard image could not be read.")
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.automaticallyDetectsLanguage = false
        let observations = try await request.perform(on: image)
        // Join OCR fragments on the same baseline before pairing names with age/sex lines.
        let ordered = observations.sorted { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }
        var lines: [[RecognizedTextObservation]] = []
        for observation in ordered {
            if let last = lines.last, let first = last.first,
               abs(first.boundingBox.cgRect.midY - observation.boundingBox.cgRect.midY) < min(first.boundingBox.height, observation.boundingBox.height) * 0.45 {
                lines[lines.count - 1].append(observation)
            } else { lines.append([observation]) }
        }
        return ClinicAlbumMatching.names(from: lines.map { line in
            let texts = line.sorted { $0.boundingBox.cgRect.minX < $1.boundingBox.cgRect.minX }.compactMap { $0.topCandidates(1).first }
            return (texts.map(\.string).joined(separator: " "), texts.map(\.confidence).min() ?? 0)
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    @objc private func addPatient() {
        guard !committing, add.isEnabled else { return }
        rows.append(Row(source: ClinicName(name: "", confidence: 1), query: "", studies: [], included: false))
        table.reloadData()
        table.scrollRowToVisible(rows.count - 1)
        (table.view(atColumn: 2, row: rows.count - 1, makeIfNecessary: true) as? NSTextField)?.selectText(nil)
        updateStatus()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        switch tableColumn?.identifier.rawValue {
        case "pacs":
            let button = NSButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Query patient in PACS")!, target: self, action: #selector(queryPACS(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.toolTip = row.studies.isEmpty ? "Find patient studies in Query/Retrieve" : "Find additional studies in Query/Retrieve"
            button.isEnabled = !loading && !committing && searches[index] == nil && !row.query.isEmpty
            return button
        case "include":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(includeChanged(_:)))
            button.tag = index
            button.state = row.included ? .on : .off
            button.isEnabled = !row.studies.isEmpty && !committing && !loading
            return button
        case "query":
            let field = NSTextField(string: row.query)
            field.tag = index
            field.target = self
            field.action = #selector(queryChanged(_:))
            field.delegate = self
            field.isEnabled = !committing && !loading
            return field
        case "patient":
            let descriptions = Set(row.studies.map { record in
                let dob = record.birthDate?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "DOB unknown"
                return "\(record.name) [\(record.patientID)] / \(dob)"
            }).sorted()
            let label = NSTextField(labelWithString: descriptions.joined(separator: "; "))
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = descriptions.joined(separator: "\n")
            return label
        case "source":
            let label = NSTextField(labelWithString: row.source.name.isEmpty ? "Manual entry" : row.source.name)
            label.toolTip = "\(row.source.searchQuery)\nAge: \(row.source.age.map(String.init) ?? "unknown") / \(row.source.sex ?? "unknown")"
            return label
        default:
            let text: String
            if let error = row.error { text = error }
            else if searches[index] != nil || loading { text = "Searching..." }
            else if !row.studies.isEmpty {
                let warnings = ClinicAlbumMatching.warnings(for: row.source, studies: row.studies, on: clinicDate.dateValue)
                text = (["\(row.studies.count) studies"] + warnings).joined(separator: "; ")
            } else { text = "Not found" }
            let label = NSTextField(labelWithString: text)
            label.toolTip = text
            return label
        }
    }

    @objc private func queryChanged(_ sender: NSTextField) {
        let index = sender.tag
        guard !loading, !committing, let browser, rows.indices.contains(index), rows[index].query != sender.stringValue else { return }
        searches[index]?.cancel()
        rows[index].query = sender.stringValue
        rows[index].studies = []
        rows[index].included = false
        rows[index].error = nil
        let revision = UUID()
        rows[index].revision = revision
        let query = sender.stringValue
        searches[index] = Task { [weak self] in
            guard let self else { return }
            do {
                let studies = try await ClinicAlbumStore.matches(query: query, browser: browser, in: self.context)
                guard !Task.isCancelled, self.rows[index].revision == revision else { return }
                self.rows[index].studies = studies
                self.rows[index].included = !studies.isEmpty
            } catch {
                guard !Task.isCancelled, self.rows[index].revision == revision else { return }
                self.rows[index].error = error.localizedDescription
            }
            self.searches[index] = nil
            self.table.reloadData()
            self.updateStatus()
        }
        table.reloadData()
        updateStatus()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { queryChanged(field) }
    }

    @objc private func includeChanged(_ sender: NSButton) {
        rows[sender.tag].included = sender.state == .on
        updateStatus()
    }

    @objc private func dateChanged() {
        table.reloadData()
        updateStatus()
    }

    private var selectedStudies: [ClinicStudy] {
        var seen = Set<String>()
        return rows.filter(\.included).flatMap(\.studies).filter { seen.insert($0.uri).inserted }
    }

    private func updateStatus() {
        let included = rows.filter(\.included).count
        status.stringValue = "\(included) of \(rows.count) names included; \(selectedStudies.count) studies"
        create.isEnabled = !loading && searches.isEmpty && !committing && !selectedStudies.isEmpty
        refresh.isEnabled = !loading && searches.isEmpty && !committing
    }

    @objc private func queryPACS(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        guard !loading, !committing, rows.indices.contains(sender.tag), searches[sender.tag] == nil else { return }
        let row = rows[sender.tag]
        let parsed = ClinicAlbumMatching.names(from: [(row.query, 1)]).first
        let ids = Set(row.studies.map(\.patientID).filter { !$0.isEmpty })
        let typedID = row.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let numericID = !typedID.isEmpty && typedID.allSatisfy(\.isNumber) ? typedID : nil
        let id = parsed?.patientID ?? numericID ?? (ids.count == 1 ? ids.first : nil) ?? ""
        let name = parsed?.name ?? row.query
        guard !id.isEmpty || !ClinicAlbumMatching.searchName(name).isEmpty else { return }
        if !QueryController.openPatientQuery(patientID: id, name: name) {
            ClinicAlbumImportController.showError("The Query/Retrieve window is busy. Finish or cancel its current query, then try again.", window: window)
        }
    }

    @objc private func refreshStudies() {
        window?.makeFirstResponder(nil)
        guard !loading, !committing, searches.isEmpty, let browser, browser.database === database else { return }
        loading = true
        add.isEnabled = false
        updateStatus()
        table.reloadData()
        task = Task { [weak self] in
            guard let self else { return }
            for index in self.rows.indices {
                self.status.stringValue = "Refreshing studies: \(index + 1) of \(self.rows.count)..."
                do {
                    let studies = try await ClinicAlbumStore.matches(query: self.rows[index].query, browser: browser, in: self.context)
                    guard !Task.isCancelled else { return }
                    let include = self.rows[index].included || self.rows[index].studies.isEmpty
                    self.rows[index].studies = studies
                    self.rows[index].included = include && !studies.isEmpty
                    self.rows[index].error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.rows[index].error = error.localizedDescription
                    self.rows[index].included = false
                }
            }
            self.loading = false
            self.add.isEnabled = true
            self.table.reloadData()
            self.updateStatus()
        }
    }

    @objc private func confirmCreate() {
        window?.makeFirstResponder(nil)
        let name = albumName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ClinicAlbumImportController.showError("Enter an album name.", window: window)
            return
        }
        let studies = selectedStudies
        guard !loading, searches.isEmpty, !committing, !studies.isEmpty else { return }
        commit(name: name, studies: studies)
    }

    private func commit(name: String, studies: [ClinicStudy]) {
        guard let browser, browser.database === database, database.isLocal(), !database.isReadOnly,
              let mainContext = database.managedObjectContext,
              mainContext.persistentStoreCoordinator === context.persistentStoreCoordinator else {
            ClinicAlbumImportController.showError("The active database changed. Close this preview and read the clipboard again.", window: window)
            return
        }
        committing = true
        albumName.isEnabled = false
        clinicDate.isEnabled = false
        add.isEnabled = false
        create.isEnabled = false
        refresh.isEnabled = false
        table.reloadData()
        status.stringValue = "Creating album..."
        task = Task { [self] in
            do {
                let saved = try await ClinicAlbumStore.create(name: name, studies: studies, in: context)
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSInsertedObjectsKey: saved.inserted, NSUpdatedObjectsKey: saved.updated], into: [mainContext])
                NotificationCenter.default.post(name: Notification.Name("InvalidateAlbumsCache"), object: database)
                if browser.database === database {
                    browser.refreshAlbums()
                    _ = browser.outlineViewRefresh()
                }
                committing = false
                close()
                let alert = NSAlert()
                alert.messageText = "Created \(saved.name)"
                alert.informativeText = "Added \(studies.count) studies."
                if let parent = browser.window { alert.beginSheetModal(for: parent) { _ in } }
            } catch {
                committing = false
                albumName.isEnabled = true
                clinicDate.isEnabled = true
                add.isEnabled = true
                table.reloadData()
                updateStatus()
                ClinicAlbumImportController.showError(error.localizedDescription, window: window)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !committing }
    func windowWillClose(_ notification: Notification) {
        if !committing { task?.cancel() }
        searches.values.forEach { $0.cancel() }
        onClose?()
    }
    @objc private func cancel() { if !committing { close() } }
}
