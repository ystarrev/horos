import Foundation
import simd

// Synthetic-only fixtures; interpret with MRIBrainVolume.swift and MRIBrainExtractor.swift.
@main
enum MRIBrainExtractorTests {
    static func main() throws {
        let side = 64
        let angle = Double.pi / 6
        let row = SIMD3(cos(angle), sin(angle), 0.0)
        let column = SIMD3(-sin(angle), cos(angle), 0.0)
        let origin = SIMD3<Double>(20, -70, 35)
        var slices = [MRIBrainVolume.Slice]()
        for z in 0..<side {
            var pixels = [Float]()
            for y in 0..<side { for x in 0..<side {
                let r = simd_length(SIMD3(Double(x - 32), Double(y - 32), Double(z - 32)))
                // Brain, dark CSF gap and a disconnected bright skull shell.
                pixels.append(r < 18 ? Float(100 + x % 9) : (r > 24 && r < 26 ? 150 : 0))
            } }
            slices.append(MRIBrainVolume.Slice(width: side, height: side,
                origin: origin + SIMD3(0, 0, Double(z) * 4), row: row, column: column,
                spacing: SIMD2(4, 4), pixels: pixels))
        }
        let volume = try MRIBrainVolume(slices: slices.reversed())
        precondition(volume.originLPS == origin)
        precondition(simd_distance(volume.patientPoint(SIMD3(2, 3, 4)), origin + row * 2 + column * 3 + SIMD3(0, 0, 4)) < 1e-10)
        let configuration = MRIBrainExtractor.Configuration()
        let result = try MRIBrainExtractor.extract(volume, configuration: configuration)
        let radii = result.points.map { simd_distance($0, SIMD3(128, 128, 128)) }
        let mean = radii.reduce(0, +) / Double(radii.count)
        print("Synthetic brain mean radius: \(mean) mm")
        precondition(mean > 60 && mean < 84)
        precondition(radii.max()! < 96, "Must stop before the skull shell")
        precondition(result.triangles.count == 20 * 256)
        let masked = try MRIBrainMaskedVolume(result: result, volume: volume)
        let tissueValues = stride(from: 0, to: masked.samples.count, by: 2).compactMap { i in
            masked.samples[i + 1] > 0 ? masked.samples[i] : nil
        }
        precondition(!tissueValues.isEmpty)
        precondition(tissueValues.max()! < 150, "Stencil must exclude the skull shell")
        for t in result.triangles {
            let a = result.points[t.x], b = result.points[t.y], c = result.points[t.z]
            precondition(simd_dot(simd_cross(b - a, c - a), (a + b + c) / 3 - SIMD3(128, 128, 128)) > 0)
        }
        do {
            _ = try MRIBrainExtractor.extract(volume, cancelled: { true })
            preconditionFailure("Cancellation was ignored")
        } catch let error as CocoaError { precondition(error.code == .userCancelled) }
        var missingSlice = slices
        missingSlice.remove(at: 20)
        expectFailure { _ = try MRIBrainVolume(slices: missingSlice) }
        expectFailure { _ = try MRIBrainVolume(slices: Array(slices.prefix(2))) }
        let blank = slices.map { MRIBrainVolume.Slice(width: $0.width, height: $0.height,
            origin: $0.origin, row: $0.row, column: $0.column, spacing: $0.spacing,
            pixels: [Float](repeating: 0, count: $0.pixels.count)) }
        expectFailure { _ = try MRIBrainExtractor.extract(MRIBrainVolume(slices: blank)) }
        print("Brain extraction fixtures passed")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection") } catch {}
    }
}
