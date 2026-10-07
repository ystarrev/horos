// Modified Swift adaptation of AIRS vtkImageMRIBrainExtractor, not verbatim source.
// Copyright (c) 2004 Atamai, Inc.
//
// Use, modification and redistribution of the software, in source or
// binary forms, are permitted provided that the following terms and
// conditions are met:
// 1) Redistribution of the source code, in verbatim or modified
// form, must retain the above copyright notice, this license,
// the following disclaimer, and any notices that refer to this
// license and/or the following disclaimer.
// 2) Redistribution in binary form must include the above copyright
// notice, a copy of this license and the following disclaimer
// in the documentation or with other materials provided with the
// distribution.
// 3) Modified copies of the source code must be clearly marked as such,
// and must not be misrepresented as verbatim copies of the source code.
// THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE SOFTWARE "AS IS"
// WITHOUT EXPRESSED OR IMPLIED WARRANTY INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE. IN NO EVENT SHALL ANY COPYRIGHT HOLDER OR OTHER PARTY WHO MAY
// MODIFY AND/OR REDISTRIBUTE THE SOFTWARE UNDER THE TERMS OF THIS LICENSE
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, LOSS OF DATA OR DATA BECOMING INACCURATE
// OR LOSS OF PROFIT OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF
// THE USE OR INABILITY TO USE THE SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGES.

import Foundation
import simd

enum MRIBrainExtractor {
    struct Configuration {
        var iterations = 1000
        var subdivisions = 4
        var brainThreshold = 0.7
        var minimumRadiusMM = 8.0
        var maximumRadiusMM = 10.0
        var minimumSearchMM = 7
        var maximumSearchMM = 3
    }

    static func extract(_ volume: MRIBrainVolume, configuration c: Configuration = Configuration(),
                        cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> MRIBrainExtractionResult {
        func check() throws { if cancelled() { throw CocoaError(.userCancelled) } }
        try check()
        guard (1...5000).contains(c.iterations), (0...5).contains(c.subdivisions),
              c.brainThreshold.isFinite, (0...1).contains(c.brainThreshold),
              c.minimumRadiusMM.isFinite, c.maximumRadiusMM.isFinite,
              c.minimumRadiusMM > 0, c.maximumRadiusMM > c.minimumRadiusMM,
              (1...50).contains(c.minimumSearchMM), (1...c.minimumSearchMM).contains(c.maximumSearchMM) else {
            throw MRIBrainExtractionError.invalid("Invalid brain extraction settings.")
        }
        // Bounded histogram supports rescaled floating-point MRI without quantizing
        // the source volume. AIRS uses the full integer scalar-type histogram.
        let low = Double(volume.pixels.min()!), high = Double(volume.pixels.max()!)
        guard high > low else { throw MRIBrainExtractionError.invalid("The MRI contains no intensity variation.") }
        let bins = 65536
        let scale = Double(bins - 1) / (high - low)
        func bin(_ value: Double) -> Int { min(bins - 1, max(0, Int((value - low) * scale))) }
        func quantile(_ histogram: [Int], _ count: Int, _ fraction: Double) -> Double {
            let target = max(1, Int(Double(count) * fraction))
            var sum = 0
            for (i, n) in histogram.enumerated() {
                sum += n
                if sum >= target { return low + Double(i) / scale }
            }
            return high
        }
        var histogram = [Int](repeating: 0, count: bins)
        for (i, value) in volume.pixels.enumerated() {
            if i % 65536 == 0 { try check() }
            histogram[bin(Double(value))] += 1
        }
        let t2 = quantile(histogram, volume.pixels.count, 0.02)
        let t98 = quantile(histogram, volume.pixels.count, 0.98)
        guard t98 > t2 else { throw MRIBrainExtractionError.invalid("Insufficient MRI tissue contrast for brain extraction.") }
        let threshold = t2 + 0.1 * (t98 - t2)
        var moment = SIMD3<Double>.zero, mass = 0.0, tissueCount = 0
        let nx = volume.dimensions.x, ny = volume.dimensions.y, nz = volume.dimensions.z
        for z in 0..<nz {
            try check()
            for y in 0..<ny { for x in 0..<nx {
                let v = Double(volume.pixels[(z * ny + y) * nx + x])
                if v > threshold {
                    // Baseline removal also handles negative rescale intercepts.
                    let weight = min(v, t98) - min(0, t2)
                    moment += SIMD3(Double(x), Double(y), Double(z)) * weight
                    mass += weight
                    tissueCount += 1
                }
            } }
        }
        guard mass > 0, tissueCount > 0 else { throw MRIBrainExtractionError.invalid("No brain tissue candidate found.") }
        let center = moment / mass * volume.spacing
        let radius = pow(3 * Double(tissueCount) * volume.spacing.x * volume.spacing.y * volume.spacing.z / (4 * .pi), 1.0 / 3)
        histogram = [Int](repeating: 0, count: bins)
        var medianCount = 0
        for z in 0..<nz {
            try check()
            for y in 0..<ny { for x in 0..<nx {
                let v = Double(volume.pixels[(z * ny + y) * nx + x])
                let p = SIMD3(Double(x), Double(y), Double(z)) * volume.spacing
                if v > t2 && v < t98 && simd_length_squared(p - center) < radius * radius {
                    histogram[bin(v)] += 1; medianCount += 1
                }
            } }
        }
        let median = medianCount > 0 ? quantile(histogram, medianCount, 0.5) : t98
        var (points, faces) = sphere(subdivisions: c.subdivisions)
        points = points.map { center + $0 * (radius * 0.5) }
        var neighbors = [[Int]](repeating: [], count: points.count)
        for t in faces {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                if !neighbors[a].contains(b) { neighbors[a].append(b) }
                if !neighbors[b].contains(a) { neighbors[b].append(a) }
            }
        }
        let e = 0.5 * (1 / c.minimumRadiusMM + 1 / c.maximumRadiusMM)
        let f = 6 / (1 / c.minimumRadiusMM - 1 / c.maximumRadiusMM)
        var edgeSquared = 0.0
        var next = points
        for iteration in 0..<c.iterations {
            try check()
            if iteration % 50 == 0 {
                edgeSquared = points.indices.reduce(0.0) { sum, i in
                    sum + neighbors[i].reduce(0.0) { $0 + simd_length_squared(points[$1] - points[i]) } / Double(neighbors[i].count)
                } / Double(points.count)
                guard edgeSquared > 1e-12, edgeSquared.isFinite else { throw MRIBrainExtractionError.invalid("Brain surface collapsed.") }
            }
            var normals = [SIMD3<Double>](repeating: .zero, count: points.count)
            for t in faces {
                let normal = simd_cross(points[t.y] - points[t.x], points[t.z] - points[t.x])
                normals[t.x] += normal; normals[t.y] += normal; normals[t.z] += normal
            }
            for i in points.indices {
                let length = simd_length(normals[i])
                guard length > 1e-12 else { throw MRIBrainExtractionError.invalid("Degenerate brain surface.") }
                let normal = normals[i] / length
                let mean = neighbors[i].reduce(SIMD3<Double>.zero) { $0 + points[$1] } / Double(neighbors[i].count)
                let displacement = mean - points[i]
                let normalPart = normal * simd_dot(displacement, normal)
                let smoothness = 0.5 * (1 + tanh(f * (2 * simd_length(normalPart) / edgeSquared - e)))
                var imageForce = 0.0
                if volume.sample(points[i] - normal) != nil,
                   volume.sample(points[i] - normal * Double(c.minimumSearchMM)) != nil {
                    var minimum = median, maximum = threshold
                    for distance in 1...c.minimumSearchMM {
                        if let v = volume.sample(points[i] - normal * Double(distance)) {
                            minimum = min(minimum, v)
                            if distance <= c.maximumSearchMM { maximum = max(maximum, v) }
                        }
                    }
                    minimum = max(t2, minimum); maximum = min(median, maximum)
                    let local = (maximum - t2) * c.brainThreshold + t2
                    imageForce = 2 * (minimum - local) / (maximum > t2 ? maximum - t2 : 1)
                }
                next[i] = points[i] + 0.5 * (displacement - normalPart) + smoothness * normalPart
                    + normal * (0.05 * sqrt(edgeSquared) * imageForce)
                guard (0..<3).allSatisfy({ next[i][$0].isFinite }) else {
                    throw MRIBrainExtractionError.invalid("Brain extraction did not converge.")
                }
            }
            swap(&points, &next)
            if iteration % 10 == 0 { progress(Double(iteration + 1) / Double(c.iterations)) }
        }
        try check()
        progress(1)
        return MRIBrainExtractionResult(points: points, triangles: faces, background: Float(t2))
    }

    private static func sphere(subdivisions: Int) -> ([SIMD3<Double>], [SIMD3<Int>]) {
        // Same 5-by-4 initial sphere topology as AIRS; project subdivision vertices
        // onto the sphere directly instead of VTK's constrained smoothing filter.
        var p: [SIMD3<Double>] = [SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        for ring in 1...2 { for j in 0..<5 {
            let phi = Double(ring) * .pi / 3, theta = Double(j) * 2 * .pi / 5
            p.append(SIMD3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi)))
        } }
        var triangles = [SIMD3<Int>]()
        for j in 0..<5 {
            let a = 2 + j, b = 2 + (j + 1) % 5, c = a + 5, d = b + 5
            triangles += [SIMD3(0, a, b), SIMD3(a, c, b), SIMD3(b, c, d), SIMD3(1, d, c)]
        }
        for _ in 0..<subdivisions {
            var edges = [UInt64: Int]()
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let i = edges[key] { return i }
                let i = p.count
                p.append(simd_normalize(p[a] + p[b])); edges[key] = i
                return i
            }
            var refined = [SIMD3<Int>]()
            for t in triangles {
                let a = midpoint(t.x, t.y), b = midpoint(t.y, t.z), c = midpoint(t.z, t.x)
                refined += [SIMD3(t.x, a, c), SIMD3(a, t.y, b), SIMD3(c, b, t.z), SIMD3(a, b, c)]
            }
            triangles = refined
        }
        return (p, triangles)
    }
}
