import Foundation

// This harness reads synthetic metadata only. Pixel decoding and non-DICOM
// fallback must never be reached in these cases.
func HorosDecodeJPEGFrame(_ data: Data, _ syntax: String, _ photometric: String,
    _ rows: Int32, _ columns: Int32, _ samples: Int32, _ allocated: Int32,
    _ stored: Int32, _ signed: Bool, _ planar: Int32) -> Data? {
    fatalError("Metadata inspection attempted to decode pixels")
}

enum DicomFile {
    static func metadataDictionary(fileAtPath: String, dicomOnly: Bool) -> NSMutableDictionary? {
        fatalError("Prepared DICOM metadata was reparsed through the non-DICOM importer")
    }
}

private func word(_ value: UInt16) -> Data {
    Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
}

private func integer(_ value: UInt32) -> Data {
    word(UInt16(truncatingIfNeeded: value)) + word(UInt16(truncatingIfNeeded: value >> 16))
}

private func element(_ group: UInt16, _ tag: UInt16, _ vr: String, _ value: Data, implicit: Bool = false) -> Data {
    var value = value
    if value.count % 2 != 0 { value.append(vr == "UI" ? 0 : 32) }
    var result = word(group) + word(tag)
    if implicit { result += integer(UInt32(value.count)) }
    else {
        result += Data(vr.utf8)
        if ["OB", "UT", "SQ"].contains(vr) { result += word(0) + integer(UInt32(value.count)) }
        else { result += word(UInt16(value.count)) }
    }
    return result + value
}

private func fixture(modality: String, syntax: String, frames: Int = 1, raw: Bool = false) -> Data {
    let implicit = syntax == SwiftDICOMReader.implicitVRLittleEndianUID
    var result = raw ? Data() : Data(repeating: 0, count: 128) + Data("DICM".utf8)
    if !raw { result += element(2, 0x10, "UI", Data(syntax.utf8)) }
    let sop = modality == "SR" ? "1.2.840.10008.5.1.4.1.1.88.11" : "1.2.840.10008.5.1.4.1.1.4"
    for (group, tag, vr, text): (UInt16, UInt16, String, String) in [
        (8, 5, "CS", "ISO_IR 192"), (8, 0x16, "UI", sop), (8, 0x18, "UI", "2.25.1003"),
        (8, 0x20, "DA", "20260102"), (8, 0x30, "TM", "123456"), (8, 0x60, "CS", modality),
        (8, 0x103e, "LO", "Synthetic import"), (0x10, 0x10, "PN", "TEST^J\u{00e9}rome"),
        (0x10, 0x20, "LO", "TEST-ID"), (0x10, 0x30, "DA", "19800101"),
        (0x20, 0x0d, "UI", "2.25.1001"), (0x20, 0x0e, "UI", "2.25.1002"),
        (0x20, 0x11, "IS", "2"), (0x20, 0x13, "IS", "7"),
        (0x20, 0x32, "DS", "1\\2\\3"), (0x20, 0x37, "DS", "1\\0\\0\\0\\1\\0"),
        (0x28, 8, "IS", String(frames))
    ] {
        result += element(group, tag, vr, Data(text.utf8), implicit: implicit)
    }
    if modality != "SR" {
        result += element(0x28, 0x10, "US", word(2), implicit: implicit)
        result += element(0x28, 0x11, "US", word(3), implicit: implicit)
    }
    return result
}

@main struct DICOMImportInspectionTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "org.horos.tests.import.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "oneFileOnSeriesForUS")
        defaults.set(true, forKey: "UsePatientIDForUID")
        let settings = SwiftDICOMImportSettings(defaults: defaults)
        var count = 0
        var batchPaths: [String] = []
        var batchPrepared: [String: DICOMImportMetadataResult] = [:]
        for modality in ["MR", "US", "SR"] {
            for syntax in [SwiftDICOMReader.implicitVRLittleEndianUID,
                           SwiftDICOMReader.explicitVRLittleEndianUID, SwiftDICOMReader.jpegLosslessSV1UID,
                           "1.2.840.10008.1.2.4.90"] {
                let source = directory.appendingPathComponent("incoming-\(count).dcm")
                let destination = directory.appendingPathComponent("database-\(count).dcm")
                let bytes = fixture(modality: modality, syntax: syntax, frames: modality == "MR" ? 2 : 1)
                try bytes.write(to: source)
                var reader: SwiftDICOMReader? = try SwiftDICOMReader(contentsOfFile: source.path, metadataForExternalDecoder: true)
                weak var releasedReader = reader
                let inspection = DICOMImportInspection(reader: reader!, settings: settings)
                reader = nil
                precondition(inspection.sourceIsCurrent && inspection.transferSyntaxUID == syntax)
                try FileManager.default.moveItem(at: source, to: destination)
                let expectedReader = try SwiftDICOMReader(contentsOfFile: destination.path, metadataForExternalDecoder: true)
                let expected = SwiftDICOMImportMetadata.buildDictionary(reader: expectedReader, path: destination.path, settings: settings)!
                let prepared = inspection.metadataResult(fileAtPath: destination.path)
                precondition(prepared.metadata!.isEqual(to: expected as! [AnyHashable: Any]))
                precondition(prepared.metadata!["filePath"] as? String == destination.path)
                if modality == "US" {
                    precondition((prepared.metadata!["seriesID"] as? String)?.hasSuffix(destination.lastPathComponent) == true)
                }
                precondition(releasedReader == nil, "Image snapshot retained after metadata preparation")
                releasedReader = nil
                inspection.discard()

                // Removing the file proves the next stage consumes the handoff
                // rather than silently reopening it. No database is involved.
                try FileManager.default.removeItem(at: destination)
                let result = DICOMImportMetadataParser.parsePaths([destination.path], dicomOnly: true,
                    preparedResults: [destination.path: prepared], isCancelled: { false }, progress: { _ in })
                precondition(result.count == 1 && result[0].metadata === prepared.metadata)
                let cancelled = DICOMImportMetadataParser.parsePaths([destination.path], dicomOnly: true,
                    preparedResults: [destination.path: prepared], isCancelled: { true }, progress: { _ in })
                precondition(cancelled.isEmpty)
                batchPaths.insert(destination.path, at: 0)
                batchPrepared[destination.path] = prepared
                count += 1
            }
        }

        var progress: [Int] = []
        let handedOff = DICOMImportMetadataParser.parsePaths(batchPaths, dicomOnly: true,
            preparedResults: batchPrepared, isCancelled: { false }, progress: { progress.append($0) })
        precondition(handedOff.map(\.path) == batchPaths)
        precondition(progress == Array(1...batchPaths.count))
        let extra = directory.appendingPathComponent("not-prepared.dcm")
        try fixture(modality: "MR", syntax: SwiftDICOMReader.explicitVRLittleEndianUID).write(to: extra)
        let mixedPaths = batchPaths + [extra.path]
        let mixed = DICOMImportMetadataParser.parsePaths(mixedPaths, dicomOnly: true,
            preparedResults: batchPrepared, isCancelled: { false }, progress: { _ in })
        precondition(mixed.map(\.path) == mixedPaths && mixed.allSatisfy { $0.metadata != nil })

        let source = directory.appendingPathComponent("changed.dcm")
        try fixture(modality: "MR", syntax: SwiftDICOMReader.explicitVRLittleEndianUID).write(to: source)
        let inspector = DICOMImportMetadataParser()
        let changed = inspector.inspectFile(atPath: source.path)!
        try Data("Not DICOM".utf8).write(to: source)
        precondition(!changed.sourceIsCurrent)
        changed.discard()
        precondition(inspector.inspectFile(atPath: source.path) == nil)

        let raw = directory.appendingPathComponent("raw.dcm")
        try fixture(modality: "MR", syntax: SwiftDICOMReader.implicitVRLittleEndianUID, raw: true).write(to: raw)
        precondition(inspector.inspectFile(atPath: raw.path)?.metadataResult(fileAtPath: raw.path).metadata != nil)
        print("\(count) metadata equivalence cases, relocation, snapshot release, batch ordering, mixed inputs, cancellation, replacement and raw-dataset checks passed")
    }
}
