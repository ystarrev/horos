import Foundation
import simd

@main
enum LeksellFrameReaderTests {
    static func main() throws {
        let center = SIMD3<Double>(10, 20, 30)
        for angle in [0.0, 0.02] {
            let rotation = simd_quatd(angle: angle, axis: SIMD3(0, 1, 0))
            var blobs: [LeksellFrameReader.Blob] = []
            for x in [-96.0, 96] {
                for z in stride(from: -50.0, through: 50, by: 2) {
                    for y in [-60.0, 60, z] {
                        let point = rotation.act(SIMD3(x, y, z)) + center
                        blobs.append(.init(point: point, weight: 100))
                    }
                }
            }
            let fit = try LeksellFrameReader.fit(blobs)
            precondition(simd_distance(fit.centerLPS, center) < 0.1)
            precondition(fit.rmsMM < 0.1 && !fit.reviewed)
            let test = rotation.act(SIMD3<Double>(12, 23, 34)) + center
            precondition(simd_distance(fit.coordinates(of: test), SIMD3(112, 77, 66)) < 0.1)
            precondition(simd_distance(fit.patientPoint(for: fit.coordinates(of: test)), test) < 1e-9)
            let spec = try FrameElectrodeSpecification(identifier: "test", text: "true\n0\n5")
            for axis in 0..<3 {
                for positive in [false, true] {
                    var electrode = FrameElectrode(name: "Test", specification: spec, targetLPS: test)
                    electrode.nudgeTarget(axis: axis, positiveAnatomicalDirection: positive, in: fit)
                    let change = fit.coordinates(of: electrode.targetLPS) - fit.coordinates(of: test)
                    let expected = (positive ? 1.0 : -1.0) * (axis == 0 ? 1 : -1)
                    precondition(abs(change[axis] - expected) < 1e-9)
                    precondition(abs(simd_distance(electrode.targetLPS, test) - 1) < 1e-9)
                    electrode = FrameElectrode(name: "Test", specification: spec, targetLPS: test)
                    electrode.nudgeTarget(axis: axis, positiveAnatomicalDirection: positive, in: nil)
                    precondition(abs((electrode.targetLPS - test)[axis] - (positive ? 1 : -1)) < 1e-9)
                }
            }
            let reference = FrameImageReference(studyInstanceUID: "study", seriesInstanceUID: "series",
                frameOfReferenceUID: "frame", frameIdentifiers: ["sop#0"], frameCount: 1)
            let plan = FramePlan(image: reference, frameFit: fit)
            let saved = try FramePlanSRPayload.encode(plan)
            let decoded = try FramePlanSRPayload.decode(saved)
            precondition(decoded == plan)
            do {
                _ = try LeksellFrameReader.fit(blobs.filter { $0.point.x < center.x })
                preconditionFailure("Missing plate must be rejected")
            } catch {}
        }
        // A small bright component yields an intensity-weighted patient-space centroid.
        var pixels = [Float](repeating: 10, count: 100 * 100)
        for y in 40..<60 { for x in 40..<60 { pixels[y * 100 + x] = 100 } }
        pixels[20 * 100 + 10] = 100; pixels[20 * 100 + 11] = 100
        let slice = LeksellFrameReader.Slice(width: 100, height: 100, origin: .zero,
            row: SIMD3(1, 0, 0), column: SIMD3(0, 1, 0), spacing: SIMD2(1, 1), pixels: pixels)
        let extracted = try LeksellFrameReader.extractBlobs(slice)
        precondition(extracted.count == 1)
        precondition(simd_distance(extracted[0].point, SIMD3(10.5, 20, 0)) < 1e-8)
        print("Leksell frame fixtures passed")
    }
}
