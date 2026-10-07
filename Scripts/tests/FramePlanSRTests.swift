import Foundation

// Run with FramePlan.swift and the existing ModernDCMTKBridge library. Synthetic data only.
@main
enum FramePlanSRTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("plan.dcm").path
        let image = FrameImageReference(studyInstanceUID: "2.25.113", seriesInstanceUID: "2.25.114",
            frameOfReferenceUID: "2.25.115", frameIdentifiers: (0..<350).map { "2.25.\(1000 + $0)#0" }, frameCount: 350)
        let spec = try FrameElectrodeSpecification(identifier: "fixture", text: "false\n0\n0.5\n2\n4\n")
        let electrode = FrameElectrode(name: "Test / \"quoted\" \\ electrode", specification: spec,
            targetLPS: SIMD3(12.3456789, -80.2345678, 41.3456789))
        for electrodes in [[], [electrode]] {
            let plan = FramePlan(image: image, electrodes: electrodes)
            let payload = try FramePlanSRPayload.encode(plan)
            precondition(payload.utf8.count > 4096, "Exercise DCMTK's deferred long-value loading")
            let strings = [path, "2.25.111", "2.25.112", image.studyInstanceUID, "Synthetic study",
                "Test^Synthetic", "", "", "TEST", "", "", "", "Horos Frame Plan SR", "99001", "Horos",
                "20260929", "120000", "1.2.840.10008.5.1.4.1.1.4", "2.25.1000", "", "Frame Plan", payload]
            let pointers = strings.map { strdup($0)! }
            defer { pointers.forEach { free($0) } }
            let p = pointers.map { UnsafePointer($0) }
            precondition(HorosModernDCMTKWriteCompatibilityStructuredReport(
                p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11],
                p[12], p[13], p[14], p[15], p[16], p[17], p[18], p[19], p[20], p[21], nil, 0) != 0)
            // Match the complete autosave path, including the in-place metadata edits.
            // Reading only the initial writer output misses deferred-value corruption.
            for (element, value) in [(UInt16(0x0020), "20260901"), (0x0030, "103000"), (0x0201, "-0600")] {
                precondition(HorosModernDCMTKReplaceTagValue(path, 0x0008, element, value, 0) != 0)
                guard let editedText = HorosModernDCMTKCopyStructuredReportNamedTextValue(path, "CODE_01", nil, "Description") else {
                    preconditionFailure("SR text missing after metadata edit")
                }
                let editedPayload = String(cString: editedText)
                HorosModernDCMTKFreeString(editedText)
                precondition(editedPayload == payload, "Metadata edit corrupted the plan payload")
            }
            guard let text = HorosModernDCMTKCopyStructuredReportNamedTextValue(path, "CODE_01", nil, "Description") else {
                preconditionFailure("SR text missing")
            }
            defer { HorosModernDCMTKFreeString(text) }
            let restoredText = String(cString: text)
            precondition(restoredText == payload, "SR changed the plan payload")
            do {
                let restored = try FramePlanSRPayload.decode(restoredText)
                precondition(restored == plan)
                try restored.validate(for: image)
            } catch {
                print("Frame SR round-trip failed: \(String(reflecting: error))")
                throw error
            }
        }
        print("Frame SR round-trip fixtures passed")
    }
}
