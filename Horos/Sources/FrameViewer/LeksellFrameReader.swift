// Fiducial extraction and rod/intersection fitting adapted from AIRS vtkFrameFinder.
// See FrameElectrodes/AIRS-LICENSE. Uses patient LPS millimetres, not scanner voxel axes.
import Foundation
import simd

struct LeksellFrameFit: Codable, Equatable {
    let centerLPS: SIMD3<Double>
    let xAxisLPS: SIMD3<Double>
    let yAxisLPS: SIMD3<Double>
    let zAxisLPS: SIMD3<Double>
    let rmsMM: Double
    let maximumErrorMM: Double
    let sampleCount: Int
    let rodEndpointsLPS: [SIMD3<Double>]
    var reviewed = false

    func coordinates(of point: SIMD3<Double>) -> SIMD3<Double> {
        let delta = point - centerLPS
        return SIMD3(100 + simd_dot(delta, xAxisLPS), 100 + simd_dot(delta, yAxisLPS),
                     100 + simd_dot(delta, zAxisLPS))
    }

    func patientPoint(for coordinates: SIMD3<Double>) -> SIMD3<Double> {
        let delta = coordinates - SIMD3(repeating: 100)
        return centerLPS + xAxisLPS * delta.x + yAxisLPS * delta.y + zAxisLPS * delta.z
    }

    func validate() throws {
        let values = [centerLPS, xAxisLPS, yAxisLPS, zAxisLPS] + rodEndpointsLPS
        guard values.allSatisfy({ p in (0..<3).allSatisfy { p[$0].isFinite && abs(p[$0]) < 10000 } }),
              [xAxisLPS, yAxisLPS, zAxisLPS].allSatisfy({ abs(simd_length($0) - 1) < 1e-6 }),
              abs(simd_dot(xAxisLPS, yAxisLPS)) < 1e-6,
              simd_dot(simd_cross(xAxisLPS, yAxisLPS), zAxisLPS) > 0.999999,
              rmsMM.isFinite, rmsMM >= 0, rmsMM <= 1.5,
              maximumErrorMM.isFinite, maximumErrorMM <= 2, maximumErrorMM >= rmsMM,
              sampleCount >= 36, rodEndpointsLPS.count == 12 else {
            throw FramePlanError.invalid("Invalid Leksell frame fit.")
        }
    }
}

enum LeksellFrameReader {
    struct Slice {
        let width: Int
        let height: Int
        let origin: SIMD3<Double>
        let row: SIMD3<Double>
        let column: SIMD3<Double>
        let spacing: SIMD2<Double>
        let pixels: [Float]
    }

    struct Blob {
        let point: SIMD3<Double>
        let weight: Double
    }

    static func read(count: Int, load: (Int) throws -> Slice, progress: (Double) -> Void) throws -> LeksellFrameFit {
        guard count >= 6 else { throw FramePlanError.invalid("Frame detection needs at least six axial slices through the localizers.") }
        var blobs: [Blob] = []
        for index in 0..<count {
            let slice = try load(index)
            guard abs(simd_cross(slice.row, slice.column).z) > 0.96 else {
                throw FramePlanError.invalid("Read Frame currently requires an axial acquisition through both side localizers.")
            }
            blobs += try extractBlobs(slice)
            guard blobs.count < 100_000 else { throw FramePlanError.invalid("Too many candidate fiducials. Select a frame-localizer acquisition.") }
            progress(Double(index + 1) / Double(count))
        }
        return try fit(blobs)
    }

    static func extractBlobs(_ slice: Slice) throws -> [Blob] {
        let w = slice.width, h = slice.height
        guard w > 1, h > 1, slice.pixels.count == w * h,
              slice.spacing.x > 0, slice.spacing.y > 0 else {
            throw FramePlanError.invalid("Invalid frame-localizer image dimensions.")
        }
        // AIRS uses half the 98th percentile and rejects components over 24 square mm.
        let rx = min(w / 2, Int(100 / slice.spacing.x)), ry = min(h / 2, Int(100 / slice.spacing.y))
        var samples: [Float] = []
        for y in stride(from: h / 2 - ry, to: h / 2 + ry, by: 3) {
            for x in stride(from: w / 2 - rx, to: w / 2 + rx, by: 3) {
                let value = slice.pixels[y * w + x]
                if value.isFinite && value > 0 { samples.append(value) }
            }
        }
        guard samples.count > 100 else { return [] }
        samples.sort()
        let upper = samples[min(samples.count - 1, Int(Double(samples.count) * 0.98))]
        let threshold = upper * 0.5
        let maxCount = max(2, Int(24 / (slice.spacing.x * slice.spacing.y)))
        var visited = [Bool](repeating: false, count: w * h)
        var result: [Blob] = []
        for start in slice.pixels.indices where !visited[start] && slice.pixels[start] > threshold {
            var stack = [start], count = 0
            var sum = 0.0, xsum = 0.0, ysum = 0.0
            visited[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                let weight = Double(min(slice.pixels[i], upper))
                count += 1; sum += weight; xsum += Double(x) * weight; ysum += Double(y) * weight
                for next in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1,
                             y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] {
                    if next >= 0 && !visited[next] && slice.pixels[next].isFinite && slice.pixels[next] > threshold {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            if count >= 2 && count <= maxCount && sum > 0 {
                let point = slice.origin + slice.row * (xsum / sum * slice.spacing.x)
                    + slice.column * (ysum / sum * slice.spacing.y)
                result.append(Blob(point: point, weight: sum / Double(count)))
            }
        }
        return result
    }

    private struct Cluster {
        let lower: Int
        let upper: Int
        let weight: Double
        var center: Double { Double(lower + upper) / 2 }
        func contains(_ value: Double) -> Bool { value >= Double(lower) - 0.5 && value <= Double(upper) + 0.5 }
    }

    private static func clusters(_ blobs: [Blob], axis: SIMD3<Double>, fraction: Double) -> [Cluster] {
        var bins: [Int: Double] = [:]
        for blob in blobs { bins[Int(simd_dot(blob.point, axis).rounded()), default: 0] += blob.weight }
        let threshold = (bins.values.max() ?? 0) * fraction
        let keys = bins.keys.filter { bins[$0]! >= threshold }.sorted()
        var result: [Cluster] = [], index = 0
        while index < keys.count {
            let start = keys[index]
            var end = start, weight = bins[start]!
            index += 1
            while index < keys.count && keys[index] <= end + 2 {
                end = keys[index]; weight += bins[end]!; index += 1
            }
            if end - start <= 14 { result.append(Cluster(lower: start, upper: end, weight: weight)) }
        }
        return result
    }

    private static func pair(_ clusters: [Cluster], distance: Double) throws -> (Cluster, Cluster) {
        var candidates: [(Double, Cluster, Cluster)] = []
        for i in clusters.indices {
            for j in clusters.indices where j > i {
                let error = abs(clusters[j].center - clusters[i].center - distance)
                if error < 10 { candidates.append((error, clusters[i], clusters[j])) }
            }
        }
        guard let best = candidates.min(by: { $0.0 < $1.0 }) else {
            throw FramePlanError.invalid("Cannot identify both localizer plates and their 120 mm rod spacing.")
        }
        return (best.1, best.2)
    }

    private struct Line {
        let center: SIMD3<Double>
        let direction: SIMD3<Double>
        let points: [SIMD3<Double>]
        func error(_ point: SIMD3<Double>) -> Double { simd_length(simd_cross(point - center, direction)) }
    }

    private static func line(_ points: [SIMD3<Double>], trim: Bool = true) throws -> Line {
        guard points.count >= 6, let low = points.map(\.z).min(), let high = points.map(\.z).max(), high - low >= 25 else {
            throw FramePlanError.invalid("Insufficient rod coverage: each localizer rod needs at least 25 mm across six slices.")
        }
        let center = points.reduce(.zero, +) / Double(points.count)
        var covariance = simd_double3x3()
        for p in points {
            let d = p - center
            covariance += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        var direction = SIMD3<Double>(0, 0, 1)
        for _ in 0..<40 {
            let next = covariance * direction
            guard simd_length(next) > 1e-10 else { throw FramePlanError.invalid("Degenerate localizer rod.") }
            direction = simd_normalize(next)
        }
        if direction.z < 0 { direction = -direction }
        let fitted = Line(center: center, direction: direction, points: points)
        if trim {
            let retained = points.filter { fitted.error($0) <= 2 }
            guard retained.count >= points.count * 4 / 5 else { throw FramePlanError.invalid("Localizer rod fit contains too many outliers.") }
            return try line(retained, trim: false)
        }
        return fitted
    }

    private static func intersection(_ a: Line, _ b: Line) throws -> SIMD3<Double> {
        let offset = a.center - b.center
        let dot = simd_dot(a.direction, b.direction)
        let denominator = 1 - dot * dot
        guard denominator > 0.1 else { throw FramePlanError.invalid("Localizer diagonal is not distinct from its vertical rods.") }
        let t = (dot * simd_dot(b.direction, offset) - simd_dot(a.direction, offset)) / denominator
        let s = (simd_dot(b.direction, offset) - dot * simd_dot(a.direction, offset)) / denominator
        let p = a.center + t * a.direction, q = b.center + s * b.direction
        guard simd_distance(p, q) <= 2 else { throw FramePlanError.invalid("Localizer rods do not intersect consistently.") }
        return (p + q) / 2
    }

    static func fit(_ blobs: [Blob]) throws -> LeksellFrameFit {
        let sidePair = try pair(clusters(blobs, axis: SIMD3(1, 0, 0), fraction: 0.1), distance: 192)
        var centers: [SIMD3<Double>] = [], lines: [Line] = []
        for side in [sidePair.0, sidePair.1] {
            let plate = blobs.filter { side.contains($0.point.x) }
            guard let low = plate.map({ $0.point.z }).min(), let high = plate.map({ $0.point.z }).max() else {
                throw FramePlanError.invalid("Missing side localizer.")
            }
            let interior = plate.filter { $0.point.z > low + (high - low) * 0.1 && $0.point.z < high - (high - low) * 0.1 }
            let bars = try pair(clusters(interior, axis: SIMD3(0, 1, 0), fraction: 0.05), distance: 120)
            let diagonalAxis = simd_normalize(SIMD3<Double>(0, 1, -1))
            guard let diagonal = clusters(interior, axis: diagonalAxis, fraction: 0.05).max(by: { $0.weight < $1.weight }) else {
                throw FramePlanError.invalid("Missing diagonal localizer rod.")
            }
            let diagonalPoints = interior.filter { diagonal.contains(simd_dot($0.point, diagonalAxis)) }
            let verticalPoints = interior.filter { !diagonal.contains(simd_dot($0.point, diagonalAxis)) }
            let d = try line(diagonalPoints.map(\.point))
            let a = try line(verticalPoints.filter { bars.0.contains($0.point.y) }.map(\.point))
            let b = try line(verticalPoints.filter { bars.1.contains($0.point.y) }.map(\.point))
            guard simd_dot(a.direction, b.direction) > 0.995,
                  a.direction.z > 0.94, b.direction.z > 0.94 else {
                throw FramePlanError.invalid("Side localizer rods are not parallel or the frame is too tilted for automatic detection.")
            }
            let cornerA = try intersection(d, a), cornerB = try intersection(d, b)
            let vertical = simd_normalize(a.direction + b.direction)
            let delta = cornerB - cornerA
            let height = abs(simd_dot(delta, vertical))
            let width = simd_length(simd_cross(delta, vertical))
            guard abs(height - 120) <= 5, abs(width - 120) <= 5 else {
                throw FramePlanError.invalid("Detected localizer geometry does not match the 120 mm Leksell N-pattern.")
            }
            centers.append((cornerA + cornerB) / 2)
            lines += [d, a, b]
        }
        let delta = centers[1] - centers[0]
        guard abs(simd_length(delta) - 192) <= 6 else { throw FramePlanError.invalid("The two side localizers have inconsistent separation.") }
        let x = simd_normalize(delta)
        let superior = simd_normalize(lines[1].direction + lines[2].direction + lines[4].direction + lines[5].direction)
        guard abs(simd_dot(x, superior)) < 0.05 else { throw FramePlanError.invalid("Side localizer centers disagree in height.") }
        let y = simd_normalize(simd_cross(x, superior))
        let z = simd_cross(x, y)
        var errors: [Double] = [], endpoints: [SIMD3<Double>] = []
        for line in lines {
            errors += line.points.map { line.error($0) }
            let distances = line.points.map { simd_dot($0 - line.center, line.direction) }
            endpoints += [line.center + line.direction * distances.min()!, line.center + line.direction * distances.max()!]
        }
        let result = LeksellFrameFit(centerLPS: (centers[0] + centers[1]) / 2,
            xAxisLPS: x, yAxisLPS: y, zAxisLPS: z,
            rmsMM: sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)),
            maximumErrorMM: errors.max()!, sampleCount: errors.count, rodEndpointsLPS: endpoints)
        try result.validate()
        return result
    }
}
