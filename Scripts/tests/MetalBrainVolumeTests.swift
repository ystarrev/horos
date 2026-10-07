import Foundation
import simd

@main
enum MetalBrainVolumeTests {
    static func main() throws {
        var slices = [MRIBrainVolume.Slice]()
        for z in 0..<8 {
            let pixels = (0..<64).map { Float(($0 % 8) * 10 + ($0 / 8) + z) }
            slices.append(MRIBrainVolume.Slice(width: 8, height: 8, origin: SIMD3(20, -50, Double(z) + 30),
                row: SIMD3(1, 0, 0), column: SIMD3(0, 1, 0), spacing: SIMD2(1, 1), pixels: pixels))
        }
        let volume = try MRIBrainVolume(slices: slices)
        let points: [SIMD3<Double>] = [SIMD3(1.5, 1.5, 1.5), SIMD3(5.5, 1.5, 1.5),
            SIMD3(5.5, 5.5, 1.5), SIMD3(1.5, 5.5, 1.5), SIMD3(1.5, 1.5, 5.5),
            SIMD3(5.5, 1.5, 5.5), SIMD3(5.5, 5.5, 5.5), SIMD3(1.5, 5.5, 5.5)]
        let faces: [SIMD3<Int>] = [SIMD3(0, 2, 1), SIMD3(0, 3, 2), SIMD3(4, 5, 6), SIMD3(4, 6, 7),
            SIMD3(0, 1, 5), SIMD3(0, 5, 4), SIMD3(3, 7, 6), SIMD3(3, 6, 2),
            SIMD3(0, 4, 7), SIMD3(0, 7, 3), SIMD3(1, 2, 6), SIMD3(1, 6, 5)]
        let result = MRIBrainExtractionResult(points: points, triangles: faces, background: 0)
        let masked = try MRIBrainMaskedVolume(result: result, volume: volume)
        var included = 0
        for i in stride(from: 0, to: masked.samples.count, by: 2) {
            if masked.samples[i + 1] > 0 {
                included += 1
                let index = i / 2
                let x = index % masked.dimensions.x
                let y = (index / masked.dimensions.x) % masked.dimensions.y
                let z = index / (masked.dimensions.x * masked.dimensions.y)
                precondition(masked.samples[i] == Float(x * 10 + y + z))
            } else { precondition(masked.samples[i] == 0) }
        }
        precondition(included == 64)
        precondition(masked.originLPS == volume.originLPS)
        precondition(masked.spacing == volume.spacing)
        precondition(masked.displayRange.y > masked.displayRange.x)
        do {
            _ = try MRIBrainMaskedVolume(result: result, volume: volume, cancelled: { true })
            preconditionFailure("Cancellation ignored")
        } catch let error as CocoaError { precondition(error.code == .userCancelled) }
        print("Brain volume stencil fixtures passed")
    }
}
