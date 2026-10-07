// Tactics geometry conventions adapted in Swift; see FrameElectrodes/LICENSE.
import Foundation
import simd

enum FramePlanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

struct FrameElectrodeSpecification: Codable, Equatable {
    let identifier: String
    let tipIsContact: Bool
    let boundariesMM: [Double]
    // Tactics renders every catalogue entry with a 0.5 mm radius.
    var radiusMM: Double = 0.5

    init(identifier: String, text: String) throws {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = lines.first, first == "true" || first == "false" else {
            throw FramePlanError.invalid("Invalid electrode catalogue entry: \(identifier)")
        }
        self.identifier = identifier
        tipIsContact = first == "true"
        boundariesMM = try lines.dropFirst().map {
            guard let value = Double($0), value.isFinite else {
                throw FramePlanError.invalid("Invalid electrode dimension: \(identifier)")
            }
            return value
        }
        try validate()
    }

    func validate() throws {
        guard !identifier.isEmpty, boundariesMM.count >= 2, boundariesMM.count <= 512,
              boundariesMM.first == 0, radiusMM.isFinite, radiusMM > 0, radiusMM <= 10,
              boundariesMM.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 2000 }),
              zip(boundariesMM, boundariesMM.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw FramePlanError.invalid("Invalid electrode geometry: \(identifier)")
        }
    }

    func isContact(segment: Int) -> Bool { segment.isMultiple(of: 2) == tipIsContact }

    static func loadCatalogue(bundle: Bundle = .main) throws -> [Self] {
        guard let directory = bundle.url(forResource: "FrameElectrodes", withExtension: nil) else {
            throw FramePlanError.invalid("The Frame electrode catalogue is missing.")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw FramePlanError.invalid("The Frame electrode catalogue is empty.") }
        return try urls.map { try Self(identifier: $0.deletingPathExtension().lastPathComponent,
                                      text: String(contentsOf: $0, encoding: .utf8)) }
    }
}

struct FrameElectrode: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var specification: FrameElectrodeSpecification
    var targetLPS: SIMD3<Double>
    var azimuthDegrees: Double = 90
    var declinationDegrees: Double = 90
    // Missing in initial plans, whose angles were applied directly in LPS.
    var angleConventionVersion: Int? = 2
    var depthMM: Double = 0
    var isVisible = true

    var imageDeclinationDegrees: Double {
        get {
            guard angleConventionVersion == nil else { return declinationDegrees }
            let shifted = declinationDegrees + 180
            return shifted > 180 ? shifted - 360 : shifted
        }
        set {
            declinationDegrees = newValue
            angleConventionVersion = 2
        }
    }

    /// Tactics' -Z then -X rotations in LAI, converted back to DICOM LPS.
    /// These are IMAGE angles, not calibrated Leksell settings.
    var shaftDirectionLPS: SIMD3<Double> {
        let a = azimuthDegrees * .pi / 180
        let d = imageDeclinationDegrees * .pi / 180
        return SIMD3(-cos(a), -sin(a) * cos(d), sin(a) * sin(d))
    }

    func point(at distanceMM: Double) -> SIMD3<Double> {
        targetLPS + shaftDirectionLPS * (depthMM + distanceMM)
    }

    func targetCoordinates(in frame: LeksellFrameFit?) -> SIMD3<Double> {
        frame.map { $0.coordinates(of: targetLPS) } ?? targetLPS
    }

    mutating func setTargetCoordinates(_ coordinates: SIMD3<Double>, in frame: LeksellFrameFit?) {
        targetLPS = frame.map { $0.patientPoint(for: coordinates) } ?? coordinates
    }

    mutating func nudgeTarget(axis: Int, positiveAnatomicalDirection: Bool, in frame: LeksellFrameFit?) {
        // Positive anatomical directions are left, posterior, superior in LPS.
        var coordinates = targetCoordinates(in: frame)
        let sign = positiveAnatomicalDirection ? 1.0 : -1.0
        coordinates[axis] += frame != nil && axis != 0 ? -sign : sign
        setTargetCoordinates(coordinates, in: frame)
    }

    func validate() throws {
        try specification.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              angleConventionVersion == nil || angleConventionVersion == 2,
              name.count <= 256, (0..<3).allSatisfy({ targetLPS[$0].isFinite && abs(targetLPS[$0]) <= 10000 }),
              azimuthDegrees.isFinite, (0...180).contains(azimuthDegrees),
              declinationDegrees.isFinite, (-180...180).contains(declinationDegrees),
              depthMM.isFinite, (-500...500).contains(depthMM) else {
            throw FramePlanError.invalid("Invalid electrode target, angle, or depth.")
        }
    }
}

struct FrameImageReference: Codable, Equatable {
    let studyInstanceUID: String
    let seriesInstanceUID: String
    let frameOfReferenceUID: String
    let frameIdentifiers: [String]
    let frameCount: Int
}

/// Positions remain in the planning image's patient coordinates. Registration
/// and calibration must later be stored separately, never baked into these points.
struct FramePlan: Codable, Equatable {
    var formatVersion = 1
    var coordinateSystem = "DICOM-LPS-mm"
    let image: FrameImageReference
    var electrodes: [FrameElectrode] = []
    var frameFit: LeksellFrameFit?

    func validate(for image: FrameImageReference) throws {
        guard formatVersion == 1, coordinateSystem == "DICOM-LPS-mm" else {
            throw FramePlanError.invalid("Unsupported Frame plan format or coordinate system.")
        }
        guard self.image == image else {
            throw FramePlanError.invalid("This plan belongs to a different image series or image set. Open its original planning series first.")
        }
        guard electrodes.count <= 128, Set(electrodes.map(\.id)).count == electrodes.count else {
            throw FramePlanError.invalid("Invalid electrode list.")
        }
        try electrodes.forEach { try $0.validate() }
        try frameFit?.validate()
    }

    static func read(from url: URL, image: FrameImageReference) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw FramePlanError.invalid("The Frame plan file is too large.") }
        let plan = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try plan.validate(for: image)
        return plan
    }

    func write(to url: URL) throws {
        try validate(for: image)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum FramePlanSRPayload {
    private static let prefix = "Horos Frame Plan / binary-plist v1\n"

    static func encode(_ plan: FramePlan) throws -> String {
        try plan.validate(for: plan.image)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(plan)
        guard data.count <= 8_000_000 else { throw FramePlanError.invalid("The Frame plan is too large.") }
        return prefix + data.base64EncodedString()
    }

    static func decode(_ text: String) throws -> FramePlan {
        guard text.utf8.count <= 12_000_000 else { throw FramePlanError.invalid("The saved Frame plan is too large.") }
        do {
            if text.hasPrefix(prefix) {
                guard let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) else {
                    throw FramePlanError.invalid("The Frame SR payload is damaged.")
                }
                return try PropertyListDecoder().decode(FramePlan.self, from: data)
            }
            // Read plans written by the initial JSON-based SR implementation.
            return try JSONDecoder().decode(FramePlan.self, from: Data(text.utf8))
        } catch {
            throw FramePlanError.invalid("Cannot decode the Frame SR payload: \(String(reflecting: error))")
        }
    }
}
