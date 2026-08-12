import AppKit
import CryptoKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

private struct PatientRecord {
    let name: String
    let patientID: String
    let patientUID: String
    let birthDate: Date?
    let studyInstanceUID: String
    let studyDate: Double
}

private struct PreparedProcedure {
    let eventID: String
    let patientKey: String
    let procedureDate: Date
    let sourcePatientName: String
    let sourcePatientID: String
    let matchedPatientName: String
    let matchedPatientID: String
    let matchedPatientUID: String
    let matchedBirthDate: Date?
    let anchorStudyInstanceUID: String
    let operation: String
    let normalizedOperation: String
    let diagnosis: String
    let results: String
    let optics: String
    let assistants: String
    let sourceFile: String
    let sourceRow: Int
    let sourceFingerprint: String

    func hasSameImportedValues(as record: SurgicalProcedureRecord) -> Bool {
        patientKey == record.patientKey
            && procedureDate == record.procedureDate
            && sourcePatientName == record.sourcePatientName
            && sourcePatientID == record.sourcePatientID
            && matchedPatientName == record.matchedPatientName
            && matchedPatientID == record.matchedPatientID
            && matchedPatientUID == record.matchedPatientUID
            && matchedBirthDate == record.matchedBirthDate
            && anchorStudyInstanceUID == record.anchorStudyInstanceUID
            && operation == record.operation
            && normalizedOperation == record.normalizedOperation
            && diagnosis == record.diagnosis
            && results == record.results
            && optics == record.optics
            && assistants == record.assistants
            && sourceFile == record.sourceFile
            && sourceRow == record.sourceRow
            && sourceFingerprint == record.sourceFingerprint
    }

    func record(importedAt: Date, updatedAt: Date) -> SurgicalProcedureRecord {
        SurgicalProcedureRecord(
            eventID: eventID,
            patientKey: patientKey,
            procedureDate: procedureDate,
            sourcePatientName: sourcePatientName,
            sourcePatientID: sourcePatientID,
            matchedPatientName: matchedPatientName,
            matchedPatientID: matchedPatientID,
            matchedPatientUID: matchedPatientUID,
            matchedBirthDate: matchedBirthDate,
            anchorStudyInstanceUID: anchorStudyInstanceUID,
            operation: operation,
            normalizedOperation: normalizedOperation,
            diagnosis: diagnosis,
            results: results,
            optics: optics,
            assistants: assistants,
            sourceFile: sourceFile,
            sourceRow: sourceRow,
            sourceFingerprint: sourceFingerprint,
            importedAt: importedAt,
            updatedAt: updatedAt
        )
    }
}

private enum ImportError: LocalizedError {
    case malformedCSV
    case missingColumns([String])
    case database(String)

    var errorDescription: String? {
        switch self {
        case .malformedCSV: "The CSV contains an unterminated quoted field."
        case .missingColumns(let columns): "CSV is missing required columns: \(columns.joined(separator: ", "))."
        case .database(let message): message
        }
    }
}

private final class PatientMatcher {
    private var byID: [String: [PatientRecord]] = [:]
    private var byExactName: [String: [PatientRecord]] = [:]
    private var byPrimaryName: [String: [PatientRecord]] = [:]

    init(records: [PatientRecord]) {
        for record in records {
            let id = normalizeID(record.patientID)
            if id.isEmpty == false { byID[id, default: []].append(record) }
            let exactName = exactNameKey(record.name)
            if exactName.isEmpty == false { byExactName[exactName, default: []].append(record) }
            let primaryName = primaryNameKey(record.name)
            if primaryName.isEmpty == false { byPrimaryName[primaryName, default: []].append(record) }
        }
    }

    func match(name: String, patientID: String) -> (PatientRecord?, String) {
        let id = normalizeID(patientID)
        if id.isEmpty == false {
            guard let candidates = byID[id], candidates.isEmpty == false else {
                return (nil, "patient_id_not_found")
            }
            let compatible = candidates.filter { namesAreCompatible(name, $0.name) }
            if compatible.isEmpty == false {
                return chooseUnambiguous(compatible)
            }

            let idOnlyMatch = chooseUnambiguous(candidates)
            return idOnlyMatch.0 == nil ? (nil, "patient_id_name_mismatch") : idOnlyMatch
        }

        if let exact = byExactName[exactNameKey(name)], exact.isEmpty == false {
            return chooseUnambiguous(exact)
        }
        return chooseUnambiguous(byPrimaryName[primaryNameKey(name)] ?? [])
    }

    private func chooseUnambiguous(_ candidates: [PatientRecord]) -> (PatientRecord?, String) {
        guard candidates.isEmpty == false else { return (nil, "no_match") }
        let birthDates = Set(candidates.compactMap(\.birthDate).map(calendarDateString))
        let names = Set(candidates.map { primaryNameKey($0.name) }.filter { $0.isEmpty == false })
        guard birthDates.count <= 1, names.count <= 1 else { return (nil, "ambiguous_match") }
        return (candidates.max { ($0.studyDate, $0.studyInstanceUID) < ($1.studyDate, $1.studyInstanceUID) }, "matched")
    }
}

private func clean(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func folded(_ value: String) -> String {
    clean(value).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
}

private func normalizeID(_ value: String) -> String {
    folded(value).unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
}

private func nameTokens(_ value: String) -> [String] {
    folded(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.isEmpty == false }
}

private func exactNameKey(_ value: String) -> String { nameTokens(value).joined(separator: " ") }
private func primaryNameKey(_ value: String) -> String { nameTokens(value).prefix(2).joined(separator: " ") }
private func normalizedOperation(_ value: String) -> String { nameTokens(value).joined(separator: " ") }

private func namesAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
    let exact = exactNameKey(lhs)
    if exact.isEmpty == false, exact == exactNameKey(rhs) { return true }
    let primary = primaryNameKey(lhs)
    return primary.isEmpty == false && primary == primaryNameKey(rhs)
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let calendarDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func calendarDateString(_ date: Date) -> String {
    calendarDateFormatter.string(from: date)
}

private func parseDate(_ value: String) -> Date? {
    let input = clean(value)
    let choices: [(pattern: String, format: String, twoDigitYear: Bool)] = [
        (#"^[A-Za-z]{3,9}\s+\d{1,2},\s+\d{4}$"#, "MMM d, yyyy", false),
        (#"^[A-Za-z]{3,9}\s+\d{1,2},\s+\d{2}$"#, "MMM d, yy", true),
        (#"^\d{4}-\d{1,2}-\d{1,2}$"#, "yyyy-MM-dd", false),
        (#"^\d{1,2}/\d{1,2}/\d{4}$"#, "M/d/yyyy", false),
        (#"^\d{1,2}/\d{1,2}/\d{2}$"#, "M/d/yy", true),
        (#"^\d{1,2}-[A-Za-z]{3,9}-\d{4}$"#, "d-MMM-yyyy", false),
        (#"^\d{1,2}-[A-Za-z]{3,9}-\d{2}$"#, "d-MMM-yy", true),
    ]
    guard let choice = choices.first(where: {
        input.range(of: $0.pattern, options: .regularExpression) != nil
    }) else {
        return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.isLenient = false
    formatter.dateFormat = choice.format
    if choice.twoDigitYear {
        formatter.twoDigitStartDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 1970, month: 1, day: 1)
        )
    }
    guard let date = formatter.date(from: input) else { return nil }
    let year = formatter.calendar.component(.year, from: date)
    guard (1900...2100).contains(year) else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
}

private func parseCSV(_ text: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var insideQuotes = false
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        let isLineBreak = character == "\n" || character == "\r" || character == "\r\n"
        if character == "\"" {
            if insideQuotes, next < text.endIndex, text[next] == "\"" {
                field.append("\"")
                index = text.index(after: next)
                continue
            }
            insideQuotes.toggle()
        } else if character == ",", insideQuotes == false {
            row.append(field)
            field = ""
        } else if isLineBreak, insideQuotes == false {
            if character == "\r", next < text.endIndex, text[next] == "\n" {
                index = next
            }
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        } else {
            field.append(character)
        }
        index = text.index(after: index)
    }

    guard insideQuotes == false else { throw ImportError.malformedCSV }
    if field.isEmpty == false || row.isEmpty == false {
        row.append(field)
        rows.append(row)
    }
    return rows
}

private func readPatients(databaseURL: URL) throws -> [PatientRecord] {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let database else {
        defer { if database != nil { sqlite3_close(database) } }
        throw ImportError.database("Unable to open Horos database read-only: \(databaseURL.path)")
    }
    defer { sqlite3_close(database) }

    let sql = """
    SELECT DISTINCT COALESCE(ZNAME, ''), COALESCE(ZPATIENTID, ''), COALESCE(ZPATIENTUID, ''),
           ZDATEOFBIRTH, COALESCE(ZSTUDYINSTANCEUID, ''), COALESCE(ZDATE, 0)
    FROM ZSTUDY
    WHERE (COALESCE(ZNAME, '') <> '' OR COALESCE(ZPATIENTID, '') <> '')
      AND NOT EXISTS (
          SELECT 1 FROM ZSERIES
          WHERE ZSERIES.ZSTUDY = ZSTUDY.Z_PK
            AND (
                UPPER(COALESCE(ZSERIES.ZNAME, '')) = 'HOROS SURGICAL PROCEDURE SR'
                OR UPPER(COALESCE(ZSERIES.ZSERIESDESCRIPTION, '')) = 'HOROS SURGICAL PROCEDURE SR'
            )
      )
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw ImportError.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    func textColumn(_ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    let coreDataEpoch = Date(timeIntervalSince1970: 978_307_200)
    var records: [PatientRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        let birthDate: Date? = sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil
            : coreDataEpoch.addingTimeInterval(sqlite3_column_double(statement, 3))
        records.append(PatientRecord(
            name: clean(textColumn(0)),
            patientID: clean(textColumn(1)),
            patientUID: clean(textColumn(2)),
            birthDate: birthDate,
            studyInstanceUID: clean(textColumn(4)),
            studyDate: sqlite3_column_double(statement, 5)
        ))
    }
    return records
}

private func prepareProcedures(csvURL: URL, databaseURL: URL) throws -> ([PreparedProcedure], Int, [String: Int]) {
    let text = try String(contentsOf: csvURL, encoding: .utf8)
    let rows = try parseCSV(text)
    guard let header = rows.first else { throw ImportError.malformedCSV }
    var columns: [String: Int] = [:]
    for (index, rawName) in header.enumerated() {
        let name = clean(rawName)
        if name.isEmpty == false, columns[name] == nil {
            columns[name] = index
        }
    }
    let required = ["Date", "Name", "ID", "Operation", "Diagnosis", "Results", "Optics", "Assistants"]
    let missing = required.filter { columns[$0] == nil }
    guard missing.isEmpty else { throw ImportError.missingColumns(missing) }

    let matcher = PatientMatcher(records: try readPatients(databaseURL: databaseURL))
    var prepared: [PreparedProcedure] = []
    var eventOccurrences: [String: Int] = [:]
    var validRows = 0
    var skipped: [String: Int] = [:]

    func value(_ name: String, in row: [String]) -> String {
        guard let index = columns[name], index < row.count else { return "" }
        return clean(row[index])
    }

    for (zeroBasedIndex, row) in rows.dropFirst().enumerated() {
        guard let procedureDate = parseDate(value("Date", in: row)) else { continue }
        let operation = value("Operation", in: row)
        let sourceName = value("Name", in: row)
        guard operation.isEmpty == false, sourceName.isEmpty == false else { continue }
        validRows += 1

        let sourceID = value("ID", in: row)
        let (match, reason) = matcher.match(name: sourceName, patientID: sourceID)
        guard let match else {
            skipped[reason, default: 0] += 1
            continue
        }

        let stableName = primaryNameKey(match.name).isEmpty ? primaryNameKey(sourceName) : primaryNameKey(match.name)
        var identity = "\(stableName)|\(match.birthDate.map(calendarDateString) ?? "")"
        if match.birthDate == nil { identity += "|\(normalizeID(match.patientID))" }
        let patientKey = String(sha256(identity).prefix(32))
        let operationKey = normalizedOperation(operation)
        let eventIdentity = "\(patientKey)|\(calendarDateString(procedureDate))|\(operationKey)"
        let occurrence = eventOccurrences[eventIdentity, default: 0]
        eventOccurrences[eventIdentity] = occurrence + 1
        let eventID = sha256(occurrence == 0 ? eventIdentity : "\(eventIdentity)|occurrence:\(occurrence + 1)")
        let values = [
            sourceName, sourceID, match.name, match.patientID, match.patientUID,
            match.birthDate.map(calendarDateString) ?? "", match.studyInstanceUID,
            operation, operationKey, value("Diagnosis", in: row), value("Results", in: row),
            value("Optics", in: row), value("Assistants", in: row), csvURL.path,
            String(zeroBasedIndex + 2),
        ]
        let fingerprint = sha256(values.joined(separator: "\u{1f}"))
        prepared.append(PreparedProcedure(
            eventID: eventID,
            patientKey: patientKey,
            procedureDate: procedureDate,
            sourcePatientName: sourceName,
            sourcePatientID: sourceID,
            matchedPatientName: match.name,
            matchedPatientID: match.patientID,
            matchedPatientUID: match.patientUID,
            matchedBirthDate: match.birthDate,
            anchorStudyInstanceUID: match.studyInstanceUID,
            operation: operation,
            normalizedOperation: operationKey,
            diagnosis: value("Diagnosis", in: row),
            results: value("Results", in: row),
            optics: value("Optics", in: row),
            assistants: value("Assistants", in: row),
            sourceFile: csvURL.path,
            sourceRow: zeroBasedIndex + 2,
            sourceFingerprint: fingerprint
        ))
    }
    return (prepared, validRows, skipped)
}

private func sourceLocationKey(file: String, row: Int) -> String {
    "\(file)\u{1f}\(row)"
}

private func decimalUIDComponent(for seed: String) -> String {
    var decimalDigits = [0]
    for byte in SHA256.hash(data: Data(seed.utf8)).prefix(16) {
        var carry = Int(byte)
        for index in decimalDigits.indices {
            let value = decimalDigits[index] * 256 + carry
            decimalDigits[index] = value % 10
            carry = value / 10
        }
        while carry > 0 {
            decimalDigits.append(carry % 10)
            carry /= 10
        }
    }
    return decimalDigits.reversed().map(String.init).joined()
}

private func dicomUID(for eventID: String, component: String) -> String {
    "2.25.\(decimalUIDComponent(for: "\(eventID)|\(component)"))"
}

private let dicomDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd"
    return formatter
}()

private func retainedUID(_ value: String?, eventID: String, component: String) -> String {
    guard let value, value.isEmpty == false else {
        return dicomUID(for: eventID, component: component)
    }
    return value
}

private func payload(
    for record: SurgicalProcedureRecord,
    replacing descriptor: SurgicalProcedureSRDescriptor?
) throws -> [String: Any] {
    [
        "recordJSON": try SurgicalProcedureRecordCoding.encode(record),
        "eventID": record.eventID,
        "sopInstanceUID": retainedUID(
            descriptor?.sopInstanceUID,
            eventID: record.eventID,
            component: "sop"
        ),
        "seriesInstanceUID": retainedUID(
            descriptor?.seriesInstanceUID,
            eventID: record.eventID,
            component: "series"
        ),
        "studyInstanceUID": retainedUID(
            descriptor?.studyInstanceUID,
            eventID: record.eventID,
            component: "study"
        ),
        "patientName": record.matchedPatientName,
        "patientBirthDate": record.matchedBirthDate.map {
            dicomDateFormatter.string(from: $0)
        } ?? "",
        "patientID": record.matchedPatientID,
        "contentDate": dicomDateFormatter.string(from: record.procedureDate),
        "contentTime": "120000",
        "existingPath": descriptor?.path ?? "",
    ]
}

private func descriptorMaps(
    _ descriptors: [SurgicalProcedureSRDescriptor]
) -> (byID: [String: SurgicalProcedureSRDescriptor], bySource: [String: SurgicalProcedureSRDescriptor]) {
    var byID: [String: SurgicalProcedureSRDescriptor] = [:]
    var bySource: [String: SurgicalProcedureSRDescriptor] = [:]
    for descriptor in descriptors {
        byID[descriptor.record.eventID] = descriptor
        bySource[sourceLocationKey(file: descriptor.record.sourceFile, row: descriptor.record.sourceRow)] = descriptor
    }
    return (byID, bySource)
}

private func storePayloads(_ payloads: [[String: Any]], databaseBasePath: String) throws {
    guard payloads.isEmpty == false else { return }
    let result = StructuredReportSupport.storeSurgicalProcedureRecordPayloads(
        payloads,
        databaseBasePath: databaseBasePath
    )
    let errors = (result["errors"] as? [String]) ?? []
    let storedCount = (result["storedCount"] as? NSNumber)?.intValue ?? 0
    guard errors.isEmpty, storedCount == payloads.count else {
        var messages = errors
        if storedCount != payloads.count {
            messages.append("Horos verified \(storedCount) of \(payloads.count) surgical procedure SR files.")
        }
        throw ImportError.database(messages.joined(separator: "\n"))
    }
}

private func importProcedures(
    _ procedures: [PreparedProcedure],
    databaseBasePath: String
) throws -> (Int, Int, Int) {
    let existingDescriptors = SurgicalProcedureRecordCoding.descriptors(databaseBasePath: databaseBasePath)
    var maps = descriptorMaps(existingDescriptors)
    var payloads: [[String: Any]] = []
    var inserted = 0
    var updated = 0
    var unchanged = 0
    let now = Date()

    for procedure in procedures {
        let sourceKey = sourceLocationKey(file: procedure.sourceFile, row: procedure.sourceRow)
        let existing = maps.byID[procedure.eventID] ?? maps.bySource[sourceKey]
        if let existing, procedure.hasSameImportedValues(as: existing.record) {
            unchanged += 1
            continue
        }

        let record = procedure.record(importedAt: existing?.record.importedAt ?? now, updatedAt: now)
        payloads.append(try payload(for: record, replacing: existing))
        let replacement = SurgicalProcedureSRDescriptor(
            record: record,
            replacing: existing
        )
        if let existing {
            maps.byID[existing.record.eventID] = nil
            maps.bySource[sourceLocationKey(file: existing.record.sourceFile, row: existing.record.sourceRow)] = nil
            updated += 1
        } else {
            inserted += 1
        }
        maps.byID[record.eventID] = replacement
        maps.bySource[sourceKey] = replacement
    }

    try storePayloads(payloads, databaseBasePath: databaseBasePath)
    return (inserted, updated, unchanged)
}

private extension SurgicalProcedureSRDescriptor {
    init(record: SurgicalProcedureRecord, replacing descriptor: SurgicalProcedureSRDescriptor?) {
        self.record = record
        recordJSON = ""
        path = descriptor?.path ?? ""
        studyXID = descriptor?.studyXID ?? ""
        studyInstanceUID = descriptor?.studyInstanceUID ?? dicomUID(for: record.eventID, component: "study")
        seriesInstanceUID = descriptor?.seriesInstanceUID ?? dicomUID(for: record.eventID, component: "series")
        sopInstanceUID = descriptor?.sopInstanceUID ?? dicomUID(for: record.eventID, component: "sop")
    }
}

private struct SurgicalProcedureImportSummary: Sendable {
    let validRows: Int
    let matchedRows: Int
    let skipped: [String: Int]
    let inserted: Int
    let updated: Int
    let unchanged: Int
}

private enum SurgicalProcedureImportOutcome: Sendable {
    case success(SurgicalProcedureImportSummary)
    case failure(String)
}

@MainActor
@objcMembers
final class SurgicalProcedureImportController: NSObject {
    private static let menuItemTag = 0x5355_5247
    private static let shared = SurgicalProcedureImportController()

    @objc(installMenuItem)
    class func installMenuItem() {
        shared.installMenuItemIfNeeded()
    }

    private func installMenuItemIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.item(withTitle: NSLocalizedString("File", comment: ""))?.submenu,
              let importMenu = fileMenu.item(withTitle: NSLocalizedString("Import", comment: ""))?.submenu,
              importMenu.item(withTag: Self.menuItemTag) == nil else {
            return
        }

        if importMenu.items.last?.isSeparatorItem == false {
            importMenu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: NSLocalizedString("Import Surgical Procedures...", comment: ""),
            action: #selector(importSurgicalProcedures(_:)),
            keyEquivalent: ""
        )
        item.tag = Self.menuItemTag
        item.target = self
        importMenu.addItem(item)
    }

    @objc(importSurgicalProcedures:)
    private func importSurgicalProcedures(_ sender: Any?) {
        guard let browser = BrowserController.currentBrowser(),
              let databasePaths = browser
                .perform(NSSelectorFromString("surgicalProcedureImportDatabasePaths"))?
                .takeUnretainedValue() as? [String: String],
              let databasePath = databasePaths["databasePath"],
              let basePath = databasePaths["basePath"],
              let parentWindow = browser.window else {
            presentMessage(
                title: NSLocalizedString("Surgical Procedure Import", comment: ""),
                message: NSLocalizedString("Select a local Horos database before importing procedures.", comment: ""),
                style: .warning,
                window: NSApp.keyWindow
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Import Surgical Procedures", comment: "")
        panel.message = NSLocalizedString("Choose the surgical log CSV to match against the current Horos database.", comment: "")
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let defaultCSV = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/Dropbox/ImagesD/SurgicalLog.csv")
        if FileManager.default.fileExists(atPath: defaultCSV.path) {
            panel.directoryURL = defaultCSV.deletingLastPathComponent()
            panel.nameFieldStringValue = defaultCSV.lastPathComponent
        }

        panel.beginSheetModal(for: parentWindow) { [weak self, weak browser] response in
            guard response == .OK, let csvURL = panel.url, let self else { return }
            self.performImport(
                csvURL: csvURL,
                databaseURL: URL(fileURLWithPath: databasePath),
                basePath: basePath,
                browser: browser,
                parentWindow: parentWindow
            )
        }
    }

    private func performImport(
        csvURL: URL,
        databaseURL: URL,
        basePath: String,
        browser: BrowserController?,
        parentWindow: NSWindow
    ) {
        let progressAlert = NSAlert()
        progressAlert.messageText = NSLocalizedString("Importing Surgical Procedures", comment: "")
        progressAlert.informativeText = NSLocalizedString("Matching the CSV against the current Horos database...", comment: "")
        progressAlert.alertStyle = .informational
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        progressAlert.accessoryView = progress
        progressAlert.beginSheetModal(for: parentWindow) { _ in }

        Task { @MainActor [weak browser] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    let (procedures, validRows, skipped) = try prepareProcedures(
                        csvURL: csvURL,
                        databaseURL: databaseURL
                    )
                    let changes = try importProcedures(
                        procedures,
                        databaseBasePath: basePath
                    )
                    return SurgicalProcedureImportOutcome.success(
                        SurgicalProcedureImportSummary(
                            validRows: validRows,
                            matchedRows: procedures.count,
                            skipped: skipped,
                            inserted: changes.0,
                            updated: changes.1,
                            unchanged: changes.2
                        )
                    )
                } catch {
                    return SurgicalProcedureImportOutcome.failure(error.localizedDescription)
                }
            }.value

            if parentWindow.attachedSheet === progressAlert.window {
                parentWindow.endSheet(progressAlert.window)
            }
            progress.stopAnimation(nil)

            switch outcome {
            case .success(let summary):
                _ = browser?.outlineViewRefresh()
                let skippedCount = summary.validRows - summary.matchedRows
                let skippedDetails = summary.skipped.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
                    .joined(separator: "\n")
                var message = "Matched \(summary.matchedRows) of \(summary.validRows) dated procedures.\n"
                message += "Added \(summary.inserted), updated \(summary.updated), already current \(summary.unchanged)."
                if skippedCount > 0 {
                    message += "\n\nSkipped \(skippedCount) unmatched or ambiguous rows."
                    if skippedDetails.isEmpty == false { message += "\n\(skippedDetails)" }
                }
                presentMessage(
                    title: NSLocalizedString("Surgical Procedure Import Complete", comment: ""),
                    message: message,
                    style: .informational,
                    window: parentWindow
                )

            case .failure(let message):
                presentMessage(
                    title: NSLocalizedString("Surgical Procedure Import Failed", comment: ""),
                    message: message,
                    style: .critical,
                    window: parentWindow
                )
            }
        }
    }

    private func presentMessage(title: String, message: String, style: NSAlert.Style, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
