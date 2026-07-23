import AppKit
import SwiftData

@objcMembers
final class SurgicalProcedureEvent: NSObject {
    let identifier: String
    let patientKey: String
    let name: String
    let patientID: String
    let patientUID: String
    let dateOfBirth: Date?
    let date: Date
    let operation: String
    let diagnosis: String
    let results: String
    let optics: String
    let assistants: String
    let anchorStudyInstanceUID: String

    init(record: SurgicalProcedureRecord) {
        identifier = record.eventID
        patientKey = record.patientKey
        name = record.matchedPatientName
        patientID = record.matchedPatientID
        patientUID = record.matchedPatientUID
        dateOfBirth = record.matchedBirthDate
        date = Self.noon(on: record.procedureDate)
        operation = record.operation
        diagnosis = record.diagnosis
        results = record.results
        optics = record.optics
        assistants = record.assistants
        anchorStudyInstanceUID = record.anchorStudyInstanceUID
        super.init()
    }

    var type: String { "Procedure" }
    var modality: String { "SURG" }
    var displayTitle: String { operation.isEmpty ? "Surgery" : "Surgery: \(operation)" }
    var studyInstanceUID: String { "procedure:\(identifier)" }
    var studyName: String { diagnosis }
    var noFiles: NSNumber { NSNumber(value: 0) }
    var rawNoFiles: NSNumber { NSNumber(value: 0) }
    var numberOfImages: NSNumber { NSNumber(value: 0) }
    var noSeries: NSNumber { NSNumber(value: 0) }
    var stateText: NSNumber { NSNumber(value: 0) }
    var expanded: NSNumber { NSNumber(value: false) }
    var isDistant: Bool { false }
    var study: Any? { nil }
    var imageSeries: Any? { nil }
    var series: Any? { nil }
    var dateAdded: Any? { nil }
    var reportURL: Any? { nil }
    var xid: String { studyInstanceUID }

    @objc(XID)
    func legacyXID() -> String {
        studyInstanceUID
    }

    @objc(displayValueForColumnIdentifier:)
    func displayValue(forColumnIdentifier identifier: String) -> Any {
        switch identifier {
        case "name": return displayTitle
        case "date": return date
        case "dateOfBirth": return dateOfBirth ?? ""
        case "patientID": return patientID
        case "modality": return modality
        case "studyName", "seriesDescription": return diagnosis
        case "noFiles", "numberOfImages": return 0
        default: return ""
        }
    }

    func detailsHTML() -> String {
        let rows = [
            ("Operation", operation),
            ("Diagnosis", diagnosis),
            ("Results", results),
            ("Optics", optics),
            ("Assistants", assistants),
        ]
        let sections = rows.compactMap { title, value -> String? in
            guard value.isEmpty == false else { return nil }
            return "<section><h2>\(Self.escapeHTML(title))</h2><p>\(Self.escapeHTML(value))</p></section>"
        }.joined()

        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html{color-scheme:dark}body{margin:0;padding:28px 34px;background:#171918;color:#f1f3f2;font:15px -apple-system,system-ui,sans-serif;line-height:1.45}
        header{border-bottom:2px solid #e6a63a;padding-bottom:18px;margin-bottom:22px}
        h1{font-size:24px;margin:0 0 6px;color:#ffbd52}header p{margin:0;color:#b9bfbc}
        section{margin:0 0 22px}h2{font-size:12px;text-transform:uppercase;color:#aab0ad;margin:0 0 5px}section p{font-size:17px;margin:0;white-space:normal}
        </style></head><body><header><h1>Surgical Procedure</h1><p>\(Self.escapeHTML(Self.displayDateFormatter.string(from: date)))</p></header>\(sections)</body></html>
        """
    }

    override func value(forUndefinedKey key: String) -> Any? {
        nil
    }

    override func setValue(_ value: Any?, forUndefinedKey key: String) {}

    override var hash: Int {
        identifier.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SurgicalProcedureEvent else { return false }
        return other.identifier == identifier
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static func noon(on date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

@objcMembers
final class SurgicalProcedureTimelineStore: NSObject {
    private struct CacheEntry {
        let modificationDate: Date
        let events: [SurgicalProcedureEvent]
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static let storeName = "SurgicalProcedures.store"

    @objc(sidecarURLForDatabaseBasePath:)
    class func sidecarURL(forDatabaseBasePath basePath: String) -> URL {
        URL(fileURLWithPath: basePath, isDirectory: true).appendingPathComponent(storeName)
    }

    @objc(eventsForDatabaseBasePath:)
    class func events(forDatabaseBasePath basePath: String) -> [SurgicalProcedureEvent] {
        guard basePath.isEmpty == false else { return [] }

        let storeURL = sidecarURL(forDatabaseBasePath: basePath)
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        let modificationDate = latestStoreModificationDate(for: storeURL)

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[storeURL.path], cached.modificationDate == modificationDate {
            return cached.events
        }

        do {
            let schema = Schema([SurgicalProcedureRecord.self])
            let configuration = ModelConfiguration(
                "SurgicalProcedures",
                schema: schema,
                url: storeURL,
                allowsSave: false,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<SurgicalProcedureRecord>(
                sortBy: [
                    SortDescriptor(\.procedureDate, order: .reverse),
                    SortDescriptor(\.operation),
                ]
            )
            descriptor.includePendingChanges = false
            let events = try context.fetch(descriptor).map(SurgicalProcedureEvent.init(record:))
            cache[storeURL.path] = CacheEntry(modificationDate: modificationDate, events: events)
            return events
        } catch {
            NSLog("Unable to read surgical procedure SwiftData store at %@: %@", storeURL.path, error.localizedDescription)
            return []
        }
    }

    @objc(invalidateCacheForDatabaseBasePath:)
    class func invalidateCache(forDatabaseBasePath basePath: String) {
        let path = sidecarURL(forDatabaseBasePath: basePath).path
        lock.lock()
        cache.removeValue(forKey: path)
        lock.unlock()
    }

    private class func latestStoreModificationDate(for storeURL: URL) -> Date {
        let candidates = [storeURL, URL(fileURLWithPath: storeURL.path + "-wal")]
        return candidates.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
    }
}
