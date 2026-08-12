import AppKit
import Foundation

struct SurgicalProcedureRecord: Codable, Equatable, Sendable {
    var eventID: String
    var patientKey: String
    var procedureDate: Date
    var sourcePatientName: String
    var sourcePatientID: String
    var matchedPatientName: String
    var matchedPatientID: String
    var matchedPatientUID: String
    var matchedBirthDate: Date?
    var anchorStudyInstanceUID: String
    var operation: String
    var normalizedOperation: String
    var diagnosis: String
    var results: String
    var optics: String
    var assistants: String
    var sourceFile: String
    var sourceRow: Int
    var sourceFingerprint: String
    var importedAt: Date
    var updatedAt: Date
}

struct SurgicalProcedureSRDescriptor: Sendable {
    let record: SurgicalProcedureRecord
    let recordJSON: String
    let path: String
    let studyXID: String
    let studyInstanceUID: String
    let seriesInstanceUID: String
    let sopInstanceUID: String

    init?(dictionary: [String: Any]) {
        guard let recordJSON = dictionary["recordJSON"] as? String,
              let record = SurgicalProcedureRecordCoding.decode(recordJSON) else {
            return nil
        }
        self.record = record
        self.recordJSON = recordJSON
        path = dictionary["path"] as? String ?? ""
        studyXID = dictionary["studyXID"] as? String ?? ""
        studyInstanceUID = dictionary["studyInstanceUID"] as? String ?? ""
        seriesInstanceUID = dictionary["seriesInstanceUID"] as? String ?? ""
        sopInstanceUID = dictionary["sopInstanceUID"] as? String ?? ""
    }
}

enum SurgicalProcedureRecordCoding {
    static func encode(_ record: SurgicalProcedureRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }

    static func decode(_ json: String) -> SurgicalProcedureRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(SurgicalProcedureRecord.self, from: data)
    }

    static func descriptors(databaseBasePath basePath: String) -> [SurgicalProcedureSRDescriptor] {
        StructuredReportSupport
            .surgicalProcedureRecordDescriptors(databaseBasePath: basePath)
            .compactMap { SurgicalProcedureSRDescriptor(dictionary: $0) }
    }
}

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
    let backingStudyXID: String
    let dicomPath: String

    init(descriptor: SurgicalProcedureSRDescriptor) {
        let record = descriptor.record
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
        backingStudyXID = descriptor.studyXID
        dicomPath = descriptor.path
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
    var reportURL: String? { dicomPath.isEmpty ? nil : dicomPath }
    var xid: String { backingStudyXID }

    @objc(XID)
    func legacyXID() -> String {
        backingStudyXID
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

    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}

    override var hash: Int { identifier.hashValue }

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
    @objc(eventsForSurgicalProcedureStudies:)
    class func events(forSurgicalProcedureStudies studies: [Any]) -> [SurgicalProcedureEvent] {
        StructuredReportSupport
            .surgicalProcedureRecordDescriptors(studies: studies)
            .compactMap { SurgicalProcedureSRDescriptor(dictionary: $0) }
            .map(SurgicalProcedureEvent.init(descriptor:))
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.operation.localizedCaseInsensitiveCompare($1.operation) == .orderedAscending
            }
    }
}
