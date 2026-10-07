import Foundation
import simd

enum MRIBrainExtractionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Immutable input, independent of any viewer, database context or GPU resource.
struct MRIBrainVolume {
    struct Slice {
        let width: Int
        let height: Int
        let origin: SIMD3<Double>
        let row: SIMD3<Double>
        let column: SIMD3<Double>
        let spacing: SIMD2<Double>
        let pixels: [Float]
    }

    let dimensions: SIMD3<Int>
    let spacing: SIMD3<Double>
    let originLPS: SIMD3<Double>
    let axes: simd_double3x3
    let pixels: [Float]

    init(slices: [Slice]) throws {
        guard let first = slices.first, slices.count >= 8, first.width >= 8, first.height >= 8,
              first.width <= 4096, first.height <= 4096, slices.count <= 4096 else {
            throw MRIBrainExtractionError.invalid("Brain extraction needs a complete 3D MRI series.")
        }
        func finite(_ v: SIMD3<Double>) -> Bool { (0..<3).allSatisfy { v[$0].isFinite } }
        guard finite(first.row), finite(first.column),
              abs(simd_length(first.row) - 1) < 0.001, abs(simd_length(first.column) - 1) < 0.001,
              abs(simd_dot(first.row, first.column)) < 0.001,
              first.spacing.x.isFinite, first.spacing.y.isFinite,
              first.spacing.x > 0, first.spacing.y > 0 else {
            throw MRIBrainExtractionError.invalid("Invalid MRI orientation or pixel spacing.")
        }
        let normal = simd_normalize(simd_cross(first.row, first.column))
        guard slices.allSatisfy({ finite($0.origin) }) else {
            throw MRIBrainExtractionError.invalid("Invalid MRI slice position.")
        }
        let ordered = slices.sorted { simd_dot($0.origin, normal) < simd_dot($1.origin, normal) }
        let origin = ordered[0].origin
        let step = simd_dot(ordered.last!.origin - origin, normal) / Double(ordered.count - 1)
        guard step.isFinite, step > 0.01 else {
            throw MRIBrainExtractionError.invalid("MRI slices have duplicate positions.")
        }
        let count = first.width * first.height * slices.count
        guard count <= 256_000_000 else {
            throw MRIBrainExtractionError.invalid("This MRI is too large for brain extraction.")
        }
        var values = [Float]()
        values.reserveCapacity(count)
        for (index, slice) in ordered.enumerated() {
            guard slice.width == first.width, slice.height == first.height,
                  slice.pixels.count == first.width * first.height,
                  simd_distance(slice.row, first.row) < 0.001,
                  simd_distance(slice.column, first.column) < 0.001,
                  simd_distance(slice.spacing, first.spacing) < 0.001,
                  simd_distance(slice.origin, origin + normal * (Double(index) * step)) < max(0.05, step * 0.02),
                  slice.pixels.allSatisfy({ $0.isFinite }) else {
                throw MRIBrainExtractionError.invalid("Brain extraction requires consistent, regularly spaced MRI slices without gaps or gantry shear.")
            }
            values.append(contentsOf: slice.pixels)
        }
        dimensions = SIMD3(first.width, first.height, slices.count)
        spacing = SIMD3(first.spacing.x, first.spacing.y, step)
        originLPS = origin
        axes = simd_double3x3(columns: (first.row, first.column, normal))
        pixels = values
    }

    func patientPoint(_ physical: SIMD3<Double>) -> SIMD3<Double> { originLPS + axes * physical }

    func sample(_ physical: SIMD3<Double>) -> Double? {
        let p = physical / spacing
        guard (0..<3).allSatisfy({ p[$0].isFinite && p[$0] >= 0 && p[$0] <= Double(dimensions[$0] - 1) }) else { return nil }
        let x = Int(p.x.rounded()), y = Int(p.y.rounded()), z = Int(p.z.rounded())
        return Double(pixels[(z * dimensions.y + y) * dimensions.x + x])
    }

}

struct MRIBrainExtractionResult {
    /// Physical millimetres in the input volume's axis system.
    let points: [SIMD3<Double>]
    let triangles: [SIMD3<Int>]
    let background: Float

    func patientPoints(in volume: MRIBrainVolume) -> [SIMD3<Double>] {
        points.map { volume.patientPoint($0) }
    }
}

/// Native-resolution MRI clipped by the extraction mesh. Intensity and mask are
/// separate channels so interpolation cannot pull skull values across the stencil.
struct MRIBrainMaskedVolume {
    let dimensions: SIMD3<Int>
    let spacing: SIMD3<Double>
    let originLPS: SIMD3<Double>
    let axes: simd_double3x3
    let samples: [Float]
    let displayRange: SIMD2<Float>

    init(result: MRIBrainExtractionResult, volume: MRIBrainVolume, cancelled: () -> Bool = { false }) throws {
        guard !result.points.isEmpty else { throw MRIBrainExtractionError.invalid("Empty brain surface.") }
        let voxels = result.points.map { $0 / volume.spacing }
        var lower = volume.dimensions &- SIMD3(repeating: 1), upper = SIMD3<Int>.zero
        for p in voxels { for a in 0..<3 {
            guard p[a].isFinite, abs(p[a]) < 1_000_000 else { throw MRIBrainExtractionError.invalid("Invalid brain surface.") }
            lower[a] = min(lower[a], max(0, Int(max(-1, p[a]).rounded(.down)) - 1))
            upper[a] = max(upper[a], min(volume.dimensions[a] - 1, Int(min(Double(volume.dimensions[a]), p[a]).rounded(.up)) + 1))
        } }
        let size = upper &- lower &+ SIMD3(repeating: 1)
        guard (0..<3).allSatisfy({ size[$0] > 1 }) else { throw MRIBrainExtractionError.invalid("Brain surface is outside the MRI.") }
        let offset = SIMD3(Double(lower.x), Double(lower.y), Double(lower.z))
        let points = voxels.map { $0 - offset }
        var crossings = [[Double]](repeating: [], count: size.y * size.z)
        // X-directed scanlines; tiny Y/Z offsets avoid shared-edge ambiguity.
        for triangle in result.triangles {
            if cancelled() { throw CocoaError(.userCancelled) }
            guard (0..<3).allSatisfy({ points.indices.contains(triangle[$0]) }) else {
                throw MRIBrainExtractionError.invalid("Invalid brain mesh indices.")
            }
            let a = points[triangle.x], b = points[triangle.y], c = points[triangle.z]
            let u = b - a, v = c - a
            let determinant = u.y * v.z - u.z * v.y
            if abs(determinant) < 1e-10 { continue }
            let y0 = max(0, Int(floor(min(a.y, min(b.y, c.y)))))
            let y1 = min(size.y - 1, Int(ceil(max(a.y, max(b.y, c.y)))))
            let z0 = max(0, Int(floor(min(a.z, min(b.z, c.z)))))
            let z1 = min(size.z - 1, Int(ceil(max(a.z, max(b.z, c.z)))))
            if y0 > y1 || z0 > z1 { continue }
            for z in z0...z1 { for y in y0...y1 {
                let dy = Double(y) + 1e-7 - a.y, dz = Double(z) + 3e-7 - a.z
                let s = (dy * v.z - dz * v.y) / determinant
                let t = (u.y * dz - u.z * dy) / determinant
                if s >= 0 && t >= 0 && s + t <= 1 {
                    crossings[z * size.y + y].append(a.x + s * u.x + t * v.x)
                }
            } }
        }
        var data = [Float](repeating: 0, count: size.x * size.y * size.z * 2)
        var minimum = Float.infinity, maximum = -Float.infinity, count = 0
        for z in 0..<size.z {
            if cancelled() { throw CocoaError(.userCancelled) }
            for y in 0..<size.y {
                var hits = [Double]()
                for x in crossings[z * size.y + y].sorted() {
                    if hits.last.map({ abs($0 - x) > 1e-6 }) ?? true { hits.append(x) }
                }
                guard hits.count.isMultiple(of: 2) else {
                    throw MRIBrainExtractionError.invalid("Brain surface stencil is not closed. Extract the brain again.")
                }
                for pair in stride(from: 0, to: hits.count, by: 2) {
                    let begin = max(0, Int(ceil(hits[pair])))
                    let end = min(size.x - 1, Int(floor(hits[pair + 1])))
                    if begin > end { continue }
                    for x in begin...end {
                        let value = volume.pixels[((z + lower.z) * volume.dimensions.y + y + lower.y) * volume.dimensions.x + x + lower.x]
                        let index = ((z * size.y + y) * size.x + x) * 2
                        data[index] = value; data[index + 1] = 1
                        minimum = min(minimum, value); maximum = max(maximum, value); count += 1
                    }
                }
            }
        }
        guard count > 0, maximum > minimum else { throw MRIBrainExtractionError.invalid("The clipped brain volume contains no tissue contrast.") }
        let low = min(0, minimum)
        var histogram = [Int](repeating: 0, count: 65536)
        for i in stride(from: 0, to: data.count, by: 2) {
            if i % 65536 == 0 && cancelled() { throw CocoaError(.userCancelled) }
            let bin = Int((Double(data[i]) - Double(low)) / (Double(maximum) - Double(low)) * 65535)
            histogram[min(65535, max(0, bin))] += 1
        }
        var total = 0, percentile = maximum
        for (i, n) in histogram.enumerated() {
            total += n
            if Double(total) >= Double(data.count / 2) * 0.98 {
                percentile = low + (maximum - low) * Float(i) / 65535
                break
            }
        }
        dimensions = size
        spacing = volume.spacing
        originLPS = volume.patientPoint(offset * volume.spacing)
        axes = volume.axes
        samples = data
        displayRange = SIMD2(low, low + max(1e-6, percentile - low) * 1.1)
    }
}
