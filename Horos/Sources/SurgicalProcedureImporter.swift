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

private struct PreparedProcedure: Sendable {
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
    case missingColumns([String])
    case database(String)
    case spreadsheet(String)

    var errorDescription: String? {
        switch self {
        case .missingColumns(let columns): "The table is missing required columns: \(columns.joined(separator: ", "))."
        case .database(let message), .spreadsheet(let message): message
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

private struct SurgicalNumbersTable: Decodable, Sendable {
    let sheet: String
    let table: String
    let headerRow: Int
    let rows: [[String]]
}

private enum SurgicalNumbersReader {
    // Numbers reads a disposable copy, never the user's original document. Bulk column
    // reads avoid an Apple Event round trip for every cell in a large surgical log.
    static let script = #"""
    function run(argv) {
        var numbers = Application(argv[0]);
        var document = numbers.open(Path(argv[1]));
        try {
            var required = ['Date', 'Name', 'ID', 'Operation', 'Diagnosis', 'Results', 'Optics', 'Assistants'];
            var matches = [];
            var sheets = document.sheets();
            function normalized(value) { return String(value == null ? '' : value).trim().toLowerCase(); }
            function cellText(value, formatted) {
                if (value instanceof Date) {
                    function pad(n) { return ('0' + n).slice(-2); }
                    // Numbers exposes date-only cells as UTC instants. Local calendar
                    // accessors can shift midnight into the previous day west of UTC.
                    return value.getUTCFullYear() + '-' + pad(value.getUTCMonth() + 1) + '-' + pad(value.getUTCDate());
                }
                if (value == null) return formatted == null ? '' : String(formatted);
                if (typeof value === 'number' && /^0\d+$/.test(String(formatted))) return String(formatted);
                return String(value);
            }
            for (var s = 0; s < sheets.length; s++) {
                var tables = sheets[s].tables();
                for (var t = 0; t < tables.length; t++) {
                    var table = tables[t];
                    var count = table.rowCount();
                    for (var h = 0; h < Math.min(20, count); h++) {
                        var header = table.rows[h].cells.value().map(normalized);
                        if (!required.every(function (name) { return header.indexOf(name.toLowerCase()) >= 0; })) continue;
                        required.forEach(function (name) {
                            if (header.indexOf(name.toLowerCase()) !== header.lastIndexOf(name.toLowerCase()))
                                throw new Error('Duplicate column: ' + name);
                        });
                        var columns = required.map(function (name) {
                            var cells = table.columns[header.indexOf(name.toLowerCase())].cells;
                            var values = cells.value();
                            var formatted = cells.formattedValue();
                            return values.map(function (value, i) { return cellText(value, formatted[i]); });
                        });
                        var rows = [required];
                        var lastRow = count - table.footerRowCount();
                        if (columns.some(function (column) { return column.length !== count; }))
                            throw new Error('Numbers returned an incomplete column.');
                        for (var r = h + 1; r < lastRow; r++) {
                            rows.push(columns.map(function (column) { return column[r]; }));
                        }
                        matches.push({sheet: sheets[s].name(), table: table.name(), headerRow: h + 1, rows: rows});
                        break;
                    }
                }
            }
            if (matches.length !== 1) {
                throw new Error(matches.length === 0
                    ? 'No surgical log table found. Required columns: ' + required.join(', ')
                    : 'More than one surgical log table found: ' + matches.map(function (m) { return m.sheet + ' / ' + m.table; }).join(', '));
            }
            return JSON.stringify(matches[0]);
        } finally {
            document.close({saving: 'no'});
        }
    }
    """#

    static func read(url: URL, applicationURL: URL) throws -> SurgicalNumbersTable {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorosSurgeryPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let snapshot = temporaryDirectory.appendingPathComponent("Surgical Log Preview.numbers")
        try FileManager.default.copyItem(at: url, to: snapshot)
        let errorURL = temporaryDirectory.appendingPathComponent("reader-error.txt")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errorFile = try FileHandle(forWritingTo: errorURL)
        defer { try? errorFile.close() }
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, applicationURL.path, snapshot.path]
        process.standardOutput = output
        process.standardError = errorFile
        try process.run()
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.schedule(deadline: .now() + 180)
        timeout.setEventHandler { if process.isRunning { process.terminate() } }
        timeout.resume()
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Numbers did not finish reading the document."
            throw ImportError.spreadsheet("Unable to read the Numbers document. Allow Horos to control Numbers in System Settings > Privacy & Security > Automation if requested.\n\n\(detail)")
        }
        return try JSONDecoder().decode(SurgicalNumbersTable.self, from: data)
    }
}

private func readPatients(databaseURL: URL) throws -> (patients: [PatientRecord], expectedSRCount: Int) {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let database else {
        defer { if database != nil { sqlite3_close(database) } }
        throw ImportError.database("Unable to open Horos database read-only: \(databaseURL.path)")
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)

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
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
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
        step = sqlite3_step(statement)
    }
    guard step == SQLITE_DONE else { throw ImportError.database(String(cString: sqlite3_errmsg(database))) }
    let countSQL = """
    SELECT COUNT(*) FROM ZIMAGE
    JOIN ZSERIES ON ZIMAGE.ZSERIES = ZSERIES.Z_PK
    WHERE UPPER(COALESCE(ZSERIES.ZNAME, '')) = 'HOROS SURGICAL PROCEDURE SR'
       OR UPPER(COALESCE(ZSERIES.ZSERIESDESCRIPTION, '')) = 'HOROS SURGICAL PROCEDURE SR'
    """
    var countStatement: OpaquePointer?
    guard sqlite3_prepare_v2(database, countSQL, -1, &countStatement, nil) == SQLITE_OK, let countStatement else {
        throw ImportError.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(countStatement) }
    guard sqlite3_step(countStatement) == SQLITE_ROW else {
        throw ImportError.database(String(cString: sqlite3_errmsg(database)))
    }
    return (records, Int(sqlite3_column_int64(countStatement, 0)))
}

private func prepareProcedures(table: SurgicalNumbersTable, sourceURL: URL, patients: [PatientRecord]) throws -> ([PreparedProcedure], [SurgicalProcedurePreviewRow]) {
    let rows = table.rows
    guard let header = rows.first else { throw ImportError.spreadsheet("The surgical log table is empty.") }
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

    let matcher = PatientMatcher(records: patients)
    var prepared: [PreparedProcedure] = []
    var eventOccurrences: [String: Int] = [:]
    var skipped: [SurgicalProcedurePreviewRow] = []

    func value(_ name: String, in row: [String]) -> String {
        guard let index = columns[name], index < row.count else { return "" }
        return clean(row[index])
    }

    for (zeroBasedIndex, row) in rows.dropFirst().enumerated() {
        guard row.contains(where: { clean($0).isEmpty == false }) else { continue }
        let sourceRow = table.headerRow + zeroBasedIndex + 1
        let operation = value("Operation", in: row)
        let sourceName = value("Name", in: row)
        let sourceID = value("ID", in: row)
        let dateText = value("Date", in: row)
        func skip(_ reason: String) {
            skipped.append(SurgicalProcedurePreviewRow(row: sourceRow, action: .skipped, patient: sourceName,
                date: dateText, operation: operation, details: "\(reason)\n\nSource ID: \(sourceID)"))
        }
        guard let procedureDate = parseDate(dateText) else { skip("Missing or invalid surgery date."); continue }
        guard operation.isEmpty == false, sourceName.isEmpty == false else { skip("Missing Name or Operation."); continue }
        let (match, reason) = matcher.match(name: sourceName, patientID: sourceID)
        guard let match else {
            skip(reason.replacingOccurrences(of: "_", with: " "))
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
            value("Optics", in: row), value("Assistants", in: row), sourceURL.path,
            String(sourceRow),
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
            sourceFile: sourceURL.path,
            sourceRow: sourceRow,
            sourceFingerprint: fingerprint
        ))
    }
    return (prepared, skipped)
}

private enum SurgicalProcedurePreviewAction: String, Sendable {
    case add = "Add"
    case update = "Update"
    case unchanged = "Unchanged"
    case skipped = "Skipped"
    case review = "Review"
}

private struct SurgicalProcedurePreviewRow: Sendable {
    let row: Int
    let action: SurgicalProcedurePreviewAction
    let patient: String
    let date: String
    let operation: String
    let details: String
}

private struct SurgicalProcedureImportPreview: Sendable {
    let source: String
    let sourceURL: URL
    let sourceStamp: SurgicalProcedureSourceStamp
    let database: String
    let existingRecordCount: Int
    let rows: [SurgicalProcedurePreviewRow]
    let changes: [SurgicalProcedurePlannedChange]

    var summary: String {
        [.add, .update, .unchanged, .skipped, .review].map { (action: SurgicalProcedurePreviewAction) in
            "\(action.rawValue): \(rows.filter { $0.action == action }.count)"
        }.joined(separator: "    ")
    }
}

private struct SurgicalProcedureSourceStamp: Equatable, Sendable {
    let modificationDate: Date
    let size: UInt64
}

private func surgicalProcedureSourceStamp(_ url: URL) throws -> SurgicalProcedureSourceStamp {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let date = attributes[.modificationDate] as? Date,
          let number = attributes[.size] as? NSNumber else {
        throw ImportError.spreadsheet("Unable to verify the selected Numbers document.")
    }
    return SurgicalProcedureSourceStamp(modificationDate: date, size: number.uint64Value)
}

private struct SurgicalProcedurePlannedChange: Sendable {
    let action: SurgicalProcedurePreviewAction
    let procedure: PreparedProcedure
    let replacing: SurgicalProcedureSRDescriptor?
}

private struct SurgicalProcedurePreviewComparison: Sendable {
    let rows: [SurgicalProcedurePreviewRow]
    let changes: [SurgicalProcedurePlannedChange]
}

private func procedureFields(_ record: SurgicalProcedureRecord) -> [(String, String)] {
    [
        ("Date", calendarDateString(record.procedureDate) + " 12:00"),
        ("Operation", record.operation),
        ("Diagnosis", record.diagnosis),
        ("Results", record.results),
        ("Optics", record.optics),
        ("Assistants", record.assistants),
    ]
}

private func previewProcedures(
    _ procedures: [PreparedProcedure],
    existing: [SurgicalProcedureSRDescriptor],
    skipped: [SurgicalProcedurePreviewRow]
) -> SurgicalProcedurePreviewComparison {
    let byID = Dictionary(grouping: existing, by: { $0.record.eventID })
    let bySourceRow = Dictionary(grouping: existing, by: { $0.record.sourceRow })
    let byPatientDate = Dictionary(grouping: existing, by: {
        "\($0.record.patientKey)|\(calendarDateString($0.record.procedureDate))"
    })
    var claimedRecords = Set<String>()
    var rows = skipped
    var plannedChanges: [SurgicalProcedurePlannedChange] = []
    for procedure in procedures {
        let sameDay = byPatientDate["\(procedure.patientKey)|\(calendarDateString(procedure.procedureDate))"] ?? []
        // Row numbers can move between exports. Never overwrite a different patient's
        // procedure simply because it now occupies the same spreadsheet row.
        let candidates = byID[procedure.eventID] ?? (bySourceRow[procedure.sourceRow] ?? []).filter {
            $0.record.patientKey == procedure.patientKey
                && calendarDateString($0.record.procedureDate) == calendarDateString(procedure.procedureDate)
        }
        let record = procedure.record(importedAt: Date(), updatedAt: Date())
        let fields = procedureFields(record)
        var action: SurgicalProcedurePreviewAction
        var detail: String
        var replacement: SurgicalProcedureSRDescriptor?
        if candidates.count > 1 {
            action = .review
            detail = "Multiple existing surgery records match this row; no update is proposed."
        } else if let descriptor = candidates.first {
            if claimedRecords.insert(descriptor.record.eventID).inserted == false {
                action = .review
                detail = "Another spreadsheet row already matched this surgery; no second update is proposed."
            } else {
                let previous = procedureFields(descriptor.record)
                let changes = zip(previous, fields).filter { $0.0.1 != $0.1.1 }
                if changes.isEmpty {
                    action = .unchanged
                    detail = "The existing surgical procedure SR is already current. Changes to the source filename, row number, fingerprint, or automatically selected anchor study do not alter the procedure and will not trigger an update."
                } else {
                    action = .update
                    replacement = descriptor
                    detail = changes.map { old, new in
                        "\(new.0)\n  Current: \(old.1.isEmpty ? "(empty)" : old.1)\n  Proposed: \(new.1.isEmpty ? "(empty)" : new.1)"
                    }.joined(separator: "\n\n")
                }
            }
        } else if sameDay.isEmpty == false {
            action = .review
            detail = "There is already a surgery for this patient on this date with a different operation or event identity. No addition is proposed until this is reviewed.\n\nExisting operations: "
                + sameDay.map { $0.record.operation }.joined(separator: "; ")
        } else {
            action = .add
            detail = "Would add a surgical procedure SR to this matched patient's studies."
        }
        if action != .update {
            detail += "\n\n" + fields.map { "\($0.0): \($0.1.isEmpty ? "(empty)" : $0.1)" }.joined(separator: "\n")
        }
        rows.append(SurgicalProcedurePreviewRow(row: procedure.sourceRow, action: action,
            patient: "\(procedure.matchedPatientName) [\(procedure.matchedPatientID)]",
            date: calendarDateString(procedure.procedureDate), operation: procedure.operation, details: detail))
        if action == .add || action == .update {
            plannedChanges.append(SurgicalProcedurePlannedChange(
                action: action, procedure: procedure, replacing: replacement))
        }
    }
    return SurgicalProcedurePreviewComparison(
        rows: rows.sorted { $0.row < $1.row },
        changes: plannedChanges.sorted { $0.procedure.sourceRow < $1.procedure.sourceRow })
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
    guard let value, value.isEmpty == false else { return dicomUID(for: eventID, component: component) }
    return value
}

private func payload(
    for record: SurgicalProcedureRecord,
    replacing descriptor: SurgicalProcedureSRDescriptor?
) throws -> [String: Any] {
    [
        "recordJSON": try SurgicalProcedureRecordCoding.encode(record),
        "eventID": record.eventID,
        "sopInstanceUID": retainedUID(descriptor?.sopInstanceUID, eventID: record.eventID, component: "sop"),
        "seriesInstanceUID": retainedUID(descriptor?.seriesInstanceUID, eventID: record.eventID, component: "series"),
        "studyInstanceUID": retainedUID(descriptor?.studyInstanceUID, eventID: record.eventID, component: "study"),
        "patientName": record.matchedPatientName,
        "patientBirthDate": record.matchedBirthDate.map { dicomDateFormatter.string(from: $0) } ?? "",
        "patientID": record.matchedPatientID,
        "contentDate": dicomDateFormatter.string(from: record.procedureDate),
        "contentTime": "120000",
        "existingPath": descriptor?.path ?? "",
    ]
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
    _ changes: [SurgicalProcedurePlannedChange],
    expectedExistingCount: Int,
    databaseBasePath: String
) throws -> (inserted: Int, updated: Int, unchanged: Int) {
    guard changes.isEmpty == false else { return (0, 0, 0) }
    let current = SurgicalProcedureRecordCoding.descriptors(databaseBasePath: databaseBasePath)
    guard current.count == expectedExistingCount else {
        throw ImportError.database("The surgery records changed after this preview was created. Close the preview and run it again.")
    }
    let currentByID = Dictionary(grouping: current, by: { $0.record.eventID })
    let currentByPatientDate = Dictionary(grouping: current, by: {
        "\($0.record.patientKey)|\(calendarDateString($0.record.procedureDate))"
    })
    var payloads: [[String: Any]] = []
    var added = 0
    var updated = 0
    let now = Date()

    for change in changes {
        let procedure = change.procedure
        let replacement: SurgicalProcedureSRDescriptor?
        switch change.action {
        case .add:
            let patientDate = "\(procedure.patientKey)|\(calendarDateString(procedure.procedureDate))"
            guard currentByID[procedure.eventID] == nil,
                  currentByPatientDate[patientDate, default: []].isEmpty else {
                throw ImportError.database("A surgery matching spreadsheet row \(procedure.sourceRow) appeared after this preview was created. Run the preview again.")
            }
            replacement = nil
            added += 1
        case .update:
            guard let expected = change.replacing,
                  let candidates = currentByID[expected.record.eventID],
                  candidates.count == 1,
                  let candidate = candidates.first,
                  candidate.record == expected.record,
                  candidate.path == expected.path else {
                throw ImportError.database("The surgery corresponding to spreadsheet row \(procedure.sourceRow) changed after this preview was created. Run the preview again.")
            }
            replacement = candidate
            updated += 1
        default:
            continue
        }
        let record = procedure.record(importedAt: replacement?.record.importedAt ?? now, updatedAt: now)
        payloads.append(try payload(for: record, replacing: replacement))
    }

    try storePayloads(payloads, databaseBasePath: databaseBasePath)
    return (added, updated, 0)
}

@MainActor
private final class SurgicalProcedurePreviewWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let preview: SurgicalProcedureImportPreview
    private let tableView = NSTableView()
    private let detailsView = NSTextView()
    private let filter = NSPopUpButton()
    private let onCommit: @MainActor () -> Void
    private var visibleRows: [SurgicalProcedurePreviewRow] = []

    init(preview: SurgicalProcedureImportPreview, onCommit: @escaping @MainActor () -> Void) {
        self.preview = preview
        self.onCommit = onCommit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Surgical Procedure Import Preview"
        window.minSize = NSSize(width: 800, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView else { return }

        let sourceLabel = NSTextField(wrappingLabelWithString: preview.source + "\nDatabase: " + preview.database)
        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.isSelectable = true
        let summary = NSTextField(labelWithString: preview.summary)
        summary.font = .systemFont(ofSize: 13, weight: .semibold)
        let readOnlyLabel = NSTextField(labelWithString: "No database records have been changed. Review the proposed changes before committing.")
        readOnlyLabel.textColor = .secondaryLabelColor
        filter.addItems(withTitles: ["All Rows", "Proposed Changes", "Needs Review / Skipped", "Unchanged"])
        filter.target = self
        filter.action = #selector(updateFilter)

        for (identifier, title, width) in [
            ("row", "Row", 55.0), ("action", "Action", 90.0), ("patient", "Matched Patient", 280.0),
            ("date", "Surgery Date", 110.0), ("operation", "Operation", 490.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .bezelBorder

        let detailsScroll = NSScrollView()
        detailsScroll.hasVerticalScroller = true
        detailsScroll.borderType = .bezelBorder
        detailsScroll.documentView = detailsView
        detailsView.isEditable = false
        detailsView.isSelectable = true
        detailsView.isRichText = false
        detailsView.font = .systemFont(ofSize: 13)
        detailsView.textColor = .textColor
        detailsView.backgroundColor = .textBackgroundColor
        detailsView.textContainerInset = NSSize(width: 10, height: 10)
        detailsView.isVerticallyResizable = true
        detailsView.isHorizontallyResizable = false
        detailsView.autoresizingMask = [.width]
        detailsView.textContainer?.widthTracksTextView = true
        detailsView.textContainer?.containerSize = NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)
        let close = NSButton(title: "Close", target: self, action: #selector(closePreview))
        close.keyEquivalent = "\u{1b}"
        let commit = NSButton(
            title: "Commit \(preview.changes.count) Change\(preview.changes.count == 1 ? "" : "s")",
            target: self,
            action: #selector(confirmCommit)
        )
        commit.bezelStyle = .rounded
        commit.isEnabled = preview.changes.isEmpty == false

        for view in [sourceLabel, summary, readOnlyLabel, filter, tableScroll, detailsScroll, close, commit] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sourceLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            sourceLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sourceLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            summary.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 12),
            summary.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: filter.leadingAnchor, constant: -12),
            filter.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            filter.trailingAnchor.constraint(equalTo: sourceLabel.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: sourceLabel.trailingAnchor),
            tableScroll.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.40),
            detailsScroll.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 10),
            detailsScroll.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            detailsScroll.trailingAnchor.constraint(equalTo: sourceLabel.trailingAnchor),
            detailsScroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: sourceLabel.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            commit.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            commit.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            readOnlyLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            readOnlyLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            readOnlyLabel.trailingAnchor.constraint(lessThanOrEqualTo: commit.leadingAnchor, constant: -12),
        ])
        updateFilter()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closePreview() { close() }

    @objc private func confirmCommit() {
        guard let window, preview.changes.isEmpty == false else { return }
        let additions = preview.changes.filter { $0.action == .add }.count
        let updates = preview.changes.filter { $0.action == .update }.count
        let alert = NSAlert()
        alert.messageText = "Commit Surgical Procedure Changes?"
        alert.informativeText = "Horos will add \(additions) and update \(updates) surgical procedure SR record\(preview.changes.count == 1 ? "" : "s"). Review, skipped, and unchanged rows will not be modified."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onCommit()
        }
    }

    @objc private func updateFilter() {
        visibleRows = preview.rows.filter { row in
            switch filter.indexOfSelectedItem {
            case 1: return row.action == .add || row.action == .update
            case 2: return row.action == .review || row.action == .skipped
            case 3: return row.action == .unchanged
            default: return true
            }
        }
        tableView.reloadData()
        if visibleRows.isEmpty {
            detailsView.string = "No rows in this category."
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, visibleRows.indices.contains(row) else { return nil }
        let entry = visibleRows[row]
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let text: String
        switch identifier.rawValue {
        case "row": text = String(entry.row)
        case "action": text = entry.action.rawValue
        case "patient": text = entry.patient
        case "date": text = entry.date
        default: text = entry.operation
        }
        cell.textField?.stringValue = text
        cell.toolTip = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard visibleRows.indices.contains(tableView.selectedRow) else { detailsView.string = ""; return }
        let row = visibleRows[tableView.selectedRow]
        detailsView.string = "Row \(row.row) - \(row.action.rawValue)\n\(row.patient)\n\(row.date) - \(row.operation)\n\n\(row.details)"
        detailsView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

@MainActor
@objcMembers
final class SurgicalProcedureImportController: NSObject {
    private static let menuItemTag = 0x5355_5247
    private static let shared = SurgicalProcedureImportController()
    private static let lastFileKey = "SurgicalProcedureImportLastNumbersFile"
    private static let lastBookmarkKey = "SurgicalProcedureImportLastNumbersBookmark"
    private var isPreviewing = false
    private var isCommitting = false
    private var previewWindow: SurgicalProcedurePreviewWindowController?

    private func rememberFile(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.lastBookmarkKey)
    }

    private func rememberedFile() -> URL? {
        if let bookmark = UserDefaults.standard.data(forKey: Self.lastBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale { rememberFile(url) }
                return url
            }
        }
        return UserDefaults.standard.string(forKey: Self.lastFileKey).map { URL(fileURLWithPath: $0) }
    }

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
        guard isPreviewing == false else { return }
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
        panel.message = NSLocalizedString("Choose a Numbers surgical log to preview changes before importing.", comment: "")
        panel.prompt = NSLocalizedString("Preview", comment: "")
        panel.allowedContentTypes = [UTType(filenameExtension: "numbers")
            ?? UTType(importedAs: "com.apple.iwork.numbers.numbers", conformingTo: .data)]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if let previous = rememberedFile() {
            panel.directoryURL = previous.deletingLastPathComponent()
            panel.nameFieldStringValue = previous.lastPathComponent
        }

        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard response == .OK, let numbersURL = panel.url, let self else { return }
            self.rememberFile(numbersURL)
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Numbers")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers")
            guard let appURL else {
                self.presentMessage(title: "Numbers Required", message: "Install Apple Numbers to read this document.",
                                    style: .warning, window: parentWindow)
                return
            }
            self.performPreview(
                numbersURL: numbersURL,
                applicationURL: appURL,
                databaseURL: URL(fileURLWithPath: databasePath),
                basePath: basePath,
                parentWindow: parentWindow
            )
        }
    }

    private func performPreview(
        numbersURL: URL,
        applicationURL: URL,
        databaseURL: URL,
        basePath: String,
        parentWindow: NSWindow
    ) {
        isPreviewing = true
        let progressAlert = NSAlert()
        progressAlert.messageText = NSLocalizedString("Preparing Surgical Procedure Preview", comment: "")
        progressAlert.informativeText = NSLocalizedString("Reading Numbers and comparing with the current Horos database. No records will be changed.", comment: "")
        progressAlert.alertStyle = .informational
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        progressAlert.accessoryView = progress
        progressAlert.addButton(withTitle: "Please Wait").isEnabled = false
        progressAlert.beginSheetModal(for: parentWindow) { _ in }

        Task { @MainActor [self] in
            let outcome: Result<SurgicalProcedureImportPreview, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let sourceStamp = try surgicalProcedureSourceStamp(numbersURL)
                    let table = try SurgicalNumbersReader.read(url: numbersURL, applicationURL: applicationURL)
                    guard try surgicalProcedureSourceStamp(numbersURL) == sourceStamp else {
                        throw ImportError.spreadsheet("The Numbers document changed while Horos was reading it. Save it and run the preview again.")
                    }
                    let snapshot = try readPatients(databaseURL: databaseURL)
                    let (procedures, skipped) = try prepareProcedures(table: table, sourceURL: numbersURL, patients: snapshot.patients)
                    let existing = SurgicalProcedureRecordCoding.descriptors(databaseBasePath: basePath)
                    guard existing.count == snapshot.expectedSRCount else {
                        throw ImportError.database("The database lists \(snapshot.expectedSRCount) surgery SR files, but only \(existing.count) could be read. Preview stopped to avoid proposing duplicates. Check that the database drive is available and try again after any transfers finish.")
                    }
                    let comparison = previewProcedures(procedures, existing: existing, skipped: skipped)
                    return .success(SurgicalProcedureImportPreview(
                        source: "\(numbersURL.path)\n\(table.sheet) / \(table.table)",
                        sourceURL: numbersURL,
                        sourceStamp: sourceStamp,
                        database: basePath,
                        existingRecordCount: existing.count,
                        rows: comparison.rows,
                        changes: comparison.changes))
                } catch {
                    return .failure(error)
                }
            }.value

            if parentWindow.attachedSheet === progressAlert.window {
                parentWindow.endSheet(progressAlert.window)
            }
            progress.stopAnimation(nil)
            isPreviewing = false

            switch outcome {
            case .success(let preview):
                previewWindow?.close()
                previewWindow = SurgicalProcedurePreviewWindowController(preview: preview) { [unowned self, weak browser = BrowserController.currentBrowser()] in
                    performCommit(preview: preview, browser: browser)
                }
                NSApp.activate(ignoringOtherApps: true)
                previewWindow?.showWindow(nil)
            case .failure(let error):
                presentMessage(
                    title: NSLocalizedString("Surgical Procedure Preview Failed", comment: ""),
                    message: error.localizedDescription,
                    style: .critical,
                    window: parentWindow
                )
            }
        }
    }

    private func performCommit(preview: SurgicalProcedureImportPreview, browser: BrowserController?) {
        guard isCommitting == false, preview.changes.isEmpty == false,
              let parentWindow = previewWindow?.window else { return }
        isCommitting = true
        let progressAlert = NSAlert()
        progressAlert.messageText = "Committing Surgical Procedure Changes"
        progressAlert.informativeText = "Writing and verifying DICOM SR records in the current Horos database..."
        progressAlert.alertStyle = .informational
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        progress.style = .spinning
        progress.startAnimation(nil)
        progressAlert.accessoryView = progress
        progressAlert.addButton(withTitle: "Please Wait").isEnabled = false
        progressAlert.beginSheetModal(for: parentWindow) { _ in }

        Task { @MainActor in
            let outcome: Result<(inserted: Int, updated: Int, unchanged: Int), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    guard try surgicalProcedureSourceStamp(preview.sourceURL) == preview.sourceStamp else {
                        throw ImportError.spreadsheet("The Numbers document changed after this preview was created. Close the preview and run it again.")
                    }
                    return .success(try importProcedures(
                        preview.changes,
                        expectedExistingCount: preview.existingRecordCount,
                        databaseBasePath: preview.database
                    ))
                } catch {
                    return .failure(error)
                }
            }.value

            if parentWindow.attachedSheet === progressAlert.window {
                parentWindow.endSheet(progressAlert.window)
            }
            progress.stopAnimation(nil)
            isCommitting = false
            switch outcome {
            case .success(let summary):
                previewWindow?.close()
                previewWindow = nil
                _ = browser?.outlineViewRefresh()
                presentMessage(
                    title: "Surgical Procedure Import Complete",
                    message: "Added \(summary.inserted) and updated \(summary.updated) surgical procedure SR record\(summary.inserted + summary.updated == 1 ? "" : "s").",
                    style: .informational,
                    window: browser?.window ?? NSApp.keyWindow
                )
            case .failure(let error):
                presentMessage(
                    title: "Surgical Procedure Import Failed",
                    message: error.localizedDescription,
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
