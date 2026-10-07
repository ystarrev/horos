import Foundation
import simd

// Standalone fixtures for FramePlan.swift. No patient data or database access.
@main
enum FramePlanTests {
    static func main() throws {
        let spec = try FrameElectrodeSpecification(identifier: "fixture", text: "false\n0\n0.5\n2\n2.5\n4\n")
        precondition(!spec.isContact(segment: 0) && spec.isContact(segment: 1))
        var electrode = FrameElectrode(name: "Test", specification: spec, targetLPS: SIMD3(12, -8, 41))
        precondition(simd_distance(electrode.shaftDirectionLPS, SIMD3(0, 0, 1)) < 1e-12)
        electrode.imageDeclinationDegrees = 0
        precondition(simd_distance(electrode.shaftDirectionLPS, SIMD3(0, -1, 0)) < 1e-12)
        electrode.imageDeclinationDegrees = 180
        precondition(simd_distance(electrode.shaftDirectionLPS, SIMD3(0, 1, 0)) < 1e-12)
        for a in stride(from: 0.0, through: 180, by: 15) {
            for d in stride(from: -180.0, through: 180, by: 15) {
                electrode.azimuthDegrees = a
                electrode.declinationDegrees = d
                // Independent matrix composition of Tactics' PostMultiply rotations.
                let rotationZ = simd_quatd(angle: -a * .pi / 180, axis: SIMD3(0, 0, 1))
                let rotationX = simd_quatd(angle: -d * .pi / 180, axis: SIMD3(1, 0, 0))
                let tacticsDirection = rotationX.act(rotationZ.act(SIMD3(-1, 0, 0)))
                let direction = tacticsDirection * SIMD3<Double>(1, -1, -1)
                precondition(simd_distance(electrode.shaftDirectionLPS, direction) < 1e-12)
                electrode.depthMM = 3.5
                precondition(simd_distance(electrode.point(at: 17), electrode.targetLPS + direction * 20.5) < 1e-10)
            }
        }
        let image = FrameImageReference(studyInstanceUID: "study", seriesInstanceUID: "series",
                                       frameOfReferenceUID: "frame", frameIdentifiers: ["image#0"], frameCount: 1)
        var plan = FramePlan(image: image, electrodes: [electrode])
        let encoded = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(FramePlan.self, from: encoded)
        precondition(decoded == plan)
        try decoded.validate(for: image)
        // Old plans must retain their physical trajectories when displaying new angles.
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(electrode)) as! [String: Any]
        legacyObject.removeValue(forKey: "angleConventionVersion")
        for d in [-150.0, -90, -30, 0, 45, 90, 180] {
            legacyObject["azimuthDegrees"] = 60.0
            legacyObject["declinationDegrees"] = d
            var legacy = try JSONDecoder().decode(FrameElectrode.self, from: JSONSerialization.data(withJSONObject: legacyObject))
            let a = Double.pi / 3
            let r = d * .pi / 180
            let oldDirection = SIMD3(-cos(a), sin(a) * cos(r), -sin(a) * sin(r))
            precondition(simd_distance(legacy.shaftDirectionLPS, oldDirection) < 1e-12)
            let displayed = legacy.imageDeclinationDegrees
            legacy.imageDeclinationDegrees = displayed
            precondition(simd_distance(legacy.shaftDirectionLPS, oldDirection) < 1e-12)
        }
        let other = FrameImageReference(studyInstanceUID: "study", seriesInstanceUID: "other-series",
                                       frameOfReferenceUID: "frame", frameIdentifiers: ["image#0"], frameCount: 1)
        expectFailure { try decoded.validate(for: other) }
        plan.electrodes.append(electrode)
        expectFailure { try plan.validate(for: image) }
        expectFailure { _ = try FrameElectrodeSpecification(identifier: "bad", text: "false\n0\n2\n1\n") }
        expectFailure { _ = try FrameElectrodeSpecification(identifier: "bad", text: "false\n0\nnan\n") }
        electrode.depthMM = .infinity
        expectFailure { try electrode.validate() }
        print("Frame planning fixtures passed")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection") } catch {}
    }
}
