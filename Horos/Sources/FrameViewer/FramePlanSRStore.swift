import Foundation
import CoreData

/// One mutable, unverified local SR per planning series. All database objects stay on their context queue.
final class FramePlanSRStore {
    private static let queue = DispatchQueue(label: "org.horos.frame-plan-storage", qos: .utility)
    private static let seriesName = "Horos Frame Plan SR"
    private let database: DicomDatabase
    let databasePath: String
    let reference: FrameImageReference
    private let metadata: [String: String]
    private let referencedFrame: String
    private var expectedPlan: FramePlan?
    private var didLoad = false

    init(pix: DCMPix, reference: FrameImageReference) throws {
        precondition(Thread.isMainThread)
        guard let image = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject,
              let context = image.managedObjectContext,
              let source = DicomDatabase.perform(NSSelectorFromString("databaseForContext:"), with: context)?
                .takeUnretainedValue() as? DicomDatabase,
              source.isLocal(), !source.isReadOnly,
              let independent = source.independentDatabase() as? DicomDatabase,
              let path = pix.srcFile else {
            throw FramePlanError.invalid("Frame autosave requires images in a writable local database.")
        }
        database = independent
        databasePath = source.baseDirPath
        self.reference = reference
        let reader = try SwiftDICOMReader.cached(contentsOfFile: path)
        let tags = ["0008,0016", "0008,0018", "0008,1030", "0010,0010", "0010,0030",
                    "0010,0040", "0010,0020", "0008,0090", "0020,0010", "0008,0050",
                    "0008,0020", "0008,0030", "0008,0201"]
        metadata = Dictionary(uniqueKeysWithValues: tags.map { ($0, reader.stringValue(forTag: $0) ?? "") })
        referencedFrame = (Int(reader.stringValue(forTag: "0028,0008") ?? "1") ?? 1) > 1
            ? String(pix.frameNo + 1) : ""
    }

    func load(completion: @escaping (Result<FramePlan?, Error>) -> Void) {
        perform({
            let found = try self.findPlan()
            self.expectedPlan = found?.plan
            self.didLoad = true
            return found?.plan
        }, completion: completion)
    }

    func save(_ plan: FramePlan, completion: @escaping (Result<Void, Error>) -> Void) {
        perform({ try self.write(plan) }, completion: completion)
    }

    private func perform<T>(_ body: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        Self.queue.async {
            var result: Result<T, Error>!
            self.database.managedObjectContext.performAndWait { result = Result { try body() } }
            let outcome = result!
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private struct StoredPlan {
        let plan: FramePlan
        let path: String
        let sopUID: String
        let seriesUID: String
    }

    private func findPlan() throws -> StoredPlan? {
        let sources = NSFetchRequest<NSManagedObject>(entityName: "Series")
        sources.predicate = NSPredicate(format: "seriesDICOMUID == %@ AND study.studyInstanceUID == %@",
                                       reference.seriesInstanceUID, reference.studyInstanceUID)
        guard try !database.managedObjectContext.fetch(sources).isEmpty else {
            throw FramePlanError.invalid("The planning image series is no longer in this database.")
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
        request.predicate = NSPredicate(format: "series.study.studyInstanceUID == %@ AND series.name == %@",
                                        reference.studyInstanceUID, Self.seriesName)
        var match: StoredPlan?
        for image in try database.managedObjectContext.fetch(request) {
            guard let path = image.perform(NSSelectorFromString("completePathResolved"))?.takeUnretainedValue() as? String else {
                throw FramePlanError.invalid("A saved Frame Plan SR is unavailable.")
            }
            let plan = try readPlan(at: path)
            guard plan.image.seriesInstanceUID == reference.seriesInstanceUID else { continue }
            try plan.validate(for: reference)
            guard match == nil else {
                throw FramePlanError.invalid("Multiple Frame plans exist for this image series. Resolve the duplicate plans before editing.")
            }
            let reader = try SwiftDICOMReader.cached(contentsOfFile: path)
            guard let sop = reader.stringValue(forTag: "0008,0018"), !sop.isEmpty,
                  let series = reader.stringValue(forTag: "0020,000E"), !series.isEmpty else {
                throw FramePlanError.invalid("The saved Frame Plan SR has missing identifiers.")
            }
            match = StoredPlan(plan: plan, path: path, sopUID: sop, seriesUID: series)
        }
        return match
    }

    private func readPlan(at path: String) throws -> FramePlan {
        guard let read = HorosSRTextReader(), let release = HorosSRFreeString(),
              let text = read(path, "CODE_01", nil, "Description") else {
            throw FramePlanError.invalid("Cannot read the saved Frame Plan SR. It has not been overwritten.")
        }
        defer { release(text) }
        do {
            return try FramePlanSRPayload.decode(String(cString: text))
        } catch {
            throw FramePlanError.invalid("The saved Frame Plan SR contains an unreadable plan payload. The file has been preserved and has not been overwritten. \(error.localizedDescription)")
        }
    }

    private static func uid() -> String {
        var uuid = UUID().uuid
        let value = withUnsafeBytes(of: &uuid) { bytes in
            bytes.reduce(UInt128(0)) { ($0 << 8) | UInt128($1) }
        }
        return "2.25.\(value)"
    }

    private func write(_ plan: FramePlan) throws {
        guard didLoad else { throw FramePlanError.invalid("The saved Frame plan has not finished loading.") }
        try plan.validate(for: reference)
        let existing = try findPlan()
        guard existing?.plan == expectedPlan else {
            throw FramePlanError.invalid("The saved Frame plan changed outside this window. Reopen Frame before making further changes.")
        }
        guard let writer = HorosSRWriter(), let writeTag = HorosDICOMTagWriter() else {
            throw FramePlanError.invalid("The DICOM SR writer is unavailable.")
        }
        // Binary property lists preserve all floating-point geometry exactly; base64 keeps
        // the SR TEXT value independent of DICOM character-set and text normalization.
        let payload = try FramePlanSRPayload.encode(plan)
        guard let destination = existing?.path ?? database.uniquePathForNewDataFile(withExtension: "dcm") else {
            throw FramePlanError.invalid("Cannot allocate a database file for the Frame plan.")
        }
        let temporary = destination + "." + UUID().uuidString + ".tmp"
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyyMMdd"
        let now = Date()
        let contentDate = date.string(from: now)
        date.dateFormat = "HHmmss.SSSSSS"
        // Keep UTF-8 storage alive for the entire C call, including non-ASCII patient names.
        let strings = [temporary, existing?.sopUID ?? Self.uid(), existing?.seriesUID ?? Self.uid(),
            reference.studyInstanceUID, metadata["0008,1030"] ?? "", metadata["0010,0010"] ?? "",
            metadata["0010,0030"] ?? "", metadata["0010,0040"] ?? "", metadata["0010,0020"] ?? "",
            metadata["0008,0090"] ?? "", metadata["0020,0010"] ?? "", metadata["0008,0050"] ?? "",
            Self.seriesName, "99001", "Horos", contentDate, date.string(from: now),
            metadata["0008,0016"] ?? "", metadata["0008,0018"] ?? "", referencedFrame, "Frame Plan", payload]
        let pointers = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        let p = pointers.map { UnsafePointer($0) }
        guard writer(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11],
                     p[12], p[13], p[14], p[15], p[16], p[17], p[18], p[19], p[20], p[21], nil, 0) != 0,
              try readPlan(at: temporary) == plan else {
            throw FramePlanError.invalid("Could not write and verify the Frame Plan SR.")
        }
        // Creation time belongs to the plan; study date/time still belong to the source acquisition.
        for (element, tag) in [(UInt16(0x0020), "0008,0020"), (0x0030, "0008,0030"), (0x0201, "0008,0201")] {
            guard writeTag(temporary, 0x0008, element, metadata[tag] ?? "", 0) != 0 else {
                throw FramePlanError.invalid("Cannot preserve the source study metadata in the Frame Plan SR.")
            }
        }
        // Metadata edits rewrite the file too; verify the final bytes before replacing
        // a previously saved plan or importing a new one into the database.
        guard try readPlan(at: temporary) == plan else {
            throw FramePlanError.invalid("The final Frame Plan SR failed verification. The existing saved plan has not been replaced.")
        }
        let url = URL(fileURLWithPath: destination)
        try Data(contentsOf: URL(fileURLWithPath: temporary)).write(to: url, options: .atomic)
        // The existing SR keeps its path, SOP/series identity and study membership.
        // Only its plan contents change. Re-importing it would broadcast database
        // changes and recompute albums on every continuous slider adjustment.
        if existing != nil {
            expectedPlan = plan
            return
        }
        let imported = database.addFiles(atPaths: [destination], postNotifications: true, dicomOnly: true,
            rereadExistingItems: true, generatedByOsiriX: true)
        do {
            guard imported?.isEmpty == false else {
                throw FramePlanError.invalid("The Frame Plan SR could not be added to the database.")
            }
            // The importer logs database errors; explicitly check persistence before marking the plan saved.
            try database.managedObjectContext.save()
        } catch {
            database.managedObjectContext.rollback()
            try FileManager.default.removeItem(at: url)
            throw FramePlanError.invalid("The Frame Plan SR could not be saved in the database. Your plan is still open and unsaved. \(error.localizedDescription)")
        }
        expectedPlan = plan
    }
}
