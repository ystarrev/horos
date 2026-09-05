import AppKit
import CryptoKit
import Foundation
import Metal
import simd

struct MetalStudyROIPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ value: SIMD3<Double>) {
        x = value.x
        y = value.y
        z = value.z
    }

    var vector: SIMD3<Double> {
        SIMD3<Double>(x, y, z)
    }
}

struct MetalStudyROIGridDimensions: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let z: Int

    var voxelCount: Int {
        guard x > 0, y > 0, z > 0 else { return 0 }
        return x * y * z
    }
}

/// A tightly cropped, canonical-world probability field produced by image
/// refinement. Probabilities are quantized to one byte so the complete editable
/// result can live in the private authoring payload alongside the DICOM SEG.
struct MetalStudyROIVoxelField: Codable, Equatable, Sendable {
    let dimensions: MetalStudyROIGridDimensions
    let origin: MetalStudyROIPoint
    let spacingMM: Double
    let probabilities: Data

    var isValid: Bool {
        dimensions.voxelCount > 0
            && probabilities.count == dimensions.voxelCount
            && spacingMM.isFinite
            && spacingMM > 0
    }

    var volumeMM3: Double {
        guard isValid else { return 0 }
        let insideCount = probabilities.reduce(into: 0) { count, value in
            if value >= 128 { count += 1 }
        }
        return Double(insideCount) * spacingMM * spacingMM * spacingMM
    }

    func translated(by offset: SIMD3<Double>) -> MetalStudyROIVoxelField {
        MetalStudyROIVoxelField(
            dimensions: dimensions,
            origin: MetalStudyROIPoint(origin.vector + offset),
            spacingMM: spacingMM,
            probabilities: probabilities
        )
    }

    func transformed(by matrix: simd_float4x4) -> MetalStudyROIVoxelField? {
        guard isValid else { return nil }
        let sourceMaximum = origin.vector + SIMD3<Double>(
            Double(dimensions.x - 1),
            Double(dimensions.y - 1),
            Double(dimensions.z - 1)
        ) * spacingMM
        func apply(_ point: SIMD3<Double>, matrix: simd_float4x4) -> SIMD3<Double> {
            let value = matrix * SIMD4<Float>(
                Float(point.x),
                Float(point.y),
                Float(point.z),
                1
            )
            let divisor = abs(value.w) > 0.000_001 ? value.w : 1
            return SIMD3<Double>(
                Double(value.x / divisor),
                Double(value.y / divisor),
                Double(value.z / divisor)
            )
        }

        let corners = [origin.x, sourceMaximum.x].flatMap { x in
            [origin.y, sourceMaximum.y].flatMap { y in
                [origin.z, sourceMaximum.z].map { z in
                    apply(SIMD3<Double>(x, y, z), matrix: matrix)
                }
            }
        }
        guard var minimum = corners.first else { return nil }
        var maximum = minimum
        for point in corners.dropFirst() {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        minimum -= SIMD3<Double>(repeating: spacingMM)
        maximum += SIMD3<Double>(repeating: spacingMM)
        let rawDimensions = (maximum - minimum) / spacingMM
        let transformedDimensions = MetalStudyROIGridDimensions(
            x: max(Int(ceil(rawDimensions.x)) + 1, 2),
            y: max(Int(ceil(rawDimensions.y)) + 1, 2),
            z: max(Int(ceil(rawDimensions.z)) + 1, 2)
        )
        guard transformedDimensions.voxelCount > 0,
              transformedDimensions.voxelCount <= 1_000_000 else { return nil }

        let inverse = simd_inverse(matrix)
        var transformedProbabilities = Data(
            repeating: 0,
            count: transformedDimensions.voxelCount
        )
        for z in 0..<transformedDimensions.z {
            for y in 0..<transformedDimensions.y {
                for x in 0..<transformedDimensions.x {
                    let targetPoint = minimum + SIMD3<Double>(
                        Double(x),
                        Double(y),
                        Double(z)
                    ) * spacingMM
                    let sourcePoint = apply(targetPoint, matrix: inverse)
                    guard let probability = probability(at: sourcePoint) else { continue }
                    let index = (z * transformedDimensions.y + y) * transformedDimensions.x + x
                    transformedProbabilities[index] = UInt8(
                        min(max((probability * 255).rounded(), 0), 255)
                    )
                }
            }
        }
        let transformed = MetalStudyROIVoxelField(
            dimensions: transformedDimensions,
            origin: MetalStudyROIPoint(minimum),
            spacingMM: spacingMM,
            probabilities: transformedProbabilities
        )
        return transformed.volumeMM3 > 0 ? transformed : nil
    }

    func extentMaximumDistance(from point: SIMD3<Double>) -> Double {
        guard isValid else { return 0 }
        let maximum = origin.vector + SIMD3<Double>(
            Double(dimensions.x - 1) * spacingMM,
            Double(dimensions.y - 1) * spacingMM,
            Double(dimensions.z - 1) * spacingMM
        )
        var result = 0.0
        for z in [origin.z, maximum.z] {
            for y in [origin.y, maximum.y] {
                for x in [origin.x, maximum.x] {
                    result = max(result, simd_distance(point, SIMD3<Double>(x, y, z)))
                }
            }
        }
        return result
    }

    func occupiedMaximumDistance(from point: SIMD3<Double>) -> Double {
        guard isValid else { return 0 }
        var result = 0.0
        for index in 0..<dimensions.voxelCount where probabilities[index] >= 128 {
            let plane = dimensions.x * dimensions.y
            let z = index / plane
            let remainder = index - z * plane
            let y = remainder / dimensions.x
            let x = remainder - y * dimensions.x
            let world = origin.vector + SIMD3<Double>(Double(x), Double(y), Double(z)) * spacingMM
            result = max(result, simd_distance(point, world) + spacingMM)
        }
        return result
    }

    func probability(at point: SIMD3<Double>) -> Double? {
        guard isValid else { return nil }
        let coordinate = (point - origin.vector) / spacingMM
        guard coordinate.x >= 0, coordinate.y >= 0, coordinate.z >= 0,
              coordinate.x <= Double(dimensions.x - 1),
              coordinate.y <= Double(dimensions.y - 1),
              coordinate.z <= Double(dimensions.z - 1) else { return nil }

        let x0 = Int(floor(coordinate.x))
        let y0 = Int(floor(coordinate.y))
        let z0 = Int(floor(coordinate.z))
        let x1 = min(x0 + 1, dimensions.x - 1)
        let y1 = min(y0 + 1, dimensions.y - 1)
        let z1 = min(z0 + 1, dimensions.z - 1)
        let fx = coordinate.x - Double(x0)
        let fy = coordinate.y - Double(y0)
        let fz = coordinate.z - Double(z0)

        func value(_ x: Int, _ y: Int, _ z: Int) -> Double {
            let index = (z * dimensions.y + y) * dimensions.x + x
            return Double(probabilities[index]) / 255
        }
        let c00 = value(x0, y0, z0) * (1 - fx) + value(x1, y0, z0) * fx
        let c10 = value(x0, y1, z0) * (1 - fx) + value(x1, y1, z0) * fx
        let c01 = value(x0, y0, z1) * (1 - fx) + value(x1, y0, z1) * fx
        let c11 = value(x0, y1, z1) * (1 - fx) + value(x1, y1, z1) * fx
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy
        return c0 * (1 - fz) + c1 * fz
    }

    func surfaceRadius(
        from center: SIMD3<Double>,
        along proposedDirection: SIMD3<Double>
    ) -> Double? {
        let directionLength = simd_length(proposedDirection)
        guard isValid, directionLength > 0.000_001 else { return nil }
        let direction = proposedDirection / directionLength
        let maximumRadius = extentMaximumDistance(from: center) + spacingMM
        let step = max(spacingMM * 0.5, 0.1)
        var previousRadius = 0.0
        var previousProbability = probability(at: center) ?? 0
        guard previousProbability >= 0.5 else { return nil }

        var radius = step
        while radius <= maximumRadius {
            let currentProbability = probability(at: center + direction * radius) ?? 0
            if previousProbability >= 0.5, currentProbability < 0.5 {
                var lower = previousRadius
                var upper = radius
                for _ in 0..<8 {
                    let middle = (lower + upper) * 0.5
                    if (probability(at: center + direction * middle) ?? 0) >= 0.5 {
                        lower = middle
                    } else {
                        upper = middle
                    }
                }
                return (lower + upper) * 0.5
            }
            previousRadius = radius
            previousProbability = currentProbability
            radius += step
        }
        return nil
    }

    /// Returns sub-voxel points where the 0.5 isosurface crosses grid edges.
    /// Unlike rays from a single centre, this covers concave, tubular, and
    /// branching structures in their entirety.
    func boundaryPoints() -> [SIMD3<Double>] {
        guard isValid else { return [] }
        let values = [UInt8](probabilities)
        let width = dimensions.x
        let height = dimensions.y
        let depth = dimensions.z
        let plane = width * height
        var result: [SIMD3<Double>] = []
        result.reserveCapacity(min(dimensions.voxelCount / 4, 100_000))

        func appendCrossing(
            from index: Int,
            to neighborIndex: Int,
            coordinate: SIMD3<Double>,
            axis: SIMD3<Double>
        ) {
            let first = Double(values[index]) / 255
            let second = Double(values[neighborIndex]) / 255
            guard (first >= 0.5) != (second >= 0.5) else { return }
            let denominator = second - first
            let fraction = abs(denominator) > 0.000_001
                ? min(max((0.5 - first) / denominator, 0), 1)
                : 0.5
            result.append(
                origin.vector + (coordinate + axis * fraction) * spacingMM
            )
        }

        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let index = z * plane + y * width + x
                    let coordinate = SIMD3<Double>(Double(x), Double(y), Double(z))
                    if x + 1 < width {
                        appendCrossing(
                            from: index,
                            to: index + 1,
                            coordinate: coordinate,
                            axis: SIMD3<Double>(1, 0, 0)
                        )
                    }
                    if y + 1 < height {
                        appendCrossing(
                            from: index,
                            to: index + width,
                            coordinate: coordinate,
                            axis: SIMD3<Double>(0, 1, 0)
                        )
                    }
                    if z + 1 < depth {
                        appendCrossing(
                            from: index,
                            to: index + plane,
                            coordinate: coordinate,
                            axis: SIMD3<Double>(0, 0, 1)
                        )
                    }
                }
            }
        }
        return result
    }

    func uniformlySampledBoundaryPoints(targetCount: Int) -> [SIMD3<Double>] {
        let candidates = boundaryPoints()
        guard targetCount > 0 else { return [] }
        guard candidates.count > targetCount else { return candidates }

        let centroid = candidates.reduce(SIMD3<Double>.zero, +) / Double(candidates.count)
        var selectedIndex = candidates.indices.max {
            simd_length_squared(candidates[$0] - centroid)
                < simd_length_squared(candidates[$1] - centroid)
        } ?? 0
        var minimumDistances = Array(
            repeating: Double.greatestFiniteMagnitude,
            count: candidates.count
        )
        var result: [SIMD3<Double>] = []
        result.reserveCapacity(targetCount)

        for _ in 0..<targetCount {
            let selected = candidates[selectedIndex]
            result.append(selected)
            var farthestIndex = selectedIndex
            var farthestDistance = -Double.greatestFiniteMagnitude
            for index in candidates.indices {
                minimumDistances[index] = min(
                    minimumDistances[index],
                    simd_length_squared(candidates[index] - selected)
                )
                if minimumDistances[index] > farthestDistance {
                    farthestDistance = minimumDistances[index]
                    farthestIndex = index
                }
            }
            guard farthestDistance > spacingMM * spacingMM * 0.25 else { break }
            selectedIndex = farthestIndex
        }
        return result
    }

    func nearestBoundaryPoint(to point: SIMD3<Double>) -> SIMD3<Double>? {
        boundaryPoints().min {
            simd_length_squared($0 - point) < simd_length_squared($1 - point)
        }
    }

    func outwardNormal(at point: SIMD3<Double>) -> SIMD3<Double>? {
        guard isValid else { return nil }
        let step = max(spacingMM, 0.1)
        func sampled(_ offset: SIMD3<Double>) -> Double {
            probability(at: point + offset) ?? 0
        }
        let gradient = SIMD3<Double>(
            sampled(SIMD3<Double>(step, 0, 0)) - sampled(SIMD3<Double>(-step, 0, 0)),
            sampled(SIMD3<Double>(0, step, 0)) - sampled(SIMD3<Double>(0, -step, 0)),
            sampled(SIMD3<Double>(0, 0, step)) - sampled(SIMD3<Double>(0, 0, -step))
        )
        guard simd_length_squared(gradient) > 0.000_001 else { return nil }
        // Probability decreases from foreground to background.
        return -simd_normalize(gradient)
    }
}

struct MetalLegacyBrushMaskSlice: Sendable {
    let geometry: MetalViewerSliceGeometry
    let maskWidth: Int
    let maskHeight: Int
    let originX: Double
    let originY: Double
    let maskData: Data

    var effectiveThicknessMM: Double {
        let betweenSlices = abs(geometry.spacingBetweenSlices)
        if betweenSlices > 0.01 { return betweenSlices }
        let sliceThickness = abs(geometry.sliceThickness)
        if sliceThickness > 0.01 { return sliceThickness }
        return max(geometry.spacingX, geometry.spacingY)
    }

    func occupiedPixelBounds() -> (minimumX: Int, minimumY: Int, maximumX: Int, maximumY: Int)? {
        guard maskWidth > 0,
              maskHeight > 0,
              maskData.count >= maskWidth * maskHeight else { return nil }
        var minimumX = maskWidth
        var minimumY = maskHeight
        var maximumX = -1
        var maximumY = -1
        for storedRow in 0..<maskHeight {
            let pixelY = maskHeight - storedRow - 1
            let rowOffset = storedRow * maskWidth
            for pixelX in 0..<maskWidth where maskData[rowOffset + pixelX] > 0 {
                minimumX = min(minimumX, pixelX)
                minimumY = min(minimumY, pixelY)
                maximumX = max(maximumX, pixelX)
                maximumY = max(maximumY, pixelY)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return (minimumX, minimumY, maximumX, maximumY)
    }

    func contains(worldPoint: SIMD3<Double>, gridSpacing: Double) -> Bool {
        let distanceFromPlane = abs(simd_dot(worldPoint - geometry.origin, geometry.normal))
        let halfThickness = max(effectiveThicknessMM * 0.5, gridSpacing * 0.55)
        guard distanceFromPlane <= halfThickness else { return false }

        let pixelPoint = geometry.slicePoint(from: worldPoint)
        let localX = Int(floor(Double(pixelPoint.x) - originX))
        let localY = Int(floor(Double(pixelPoint.y) - originY))
        guard localX >= 0, localX < maskWidth,
              localY >= 0, localY < maskHeight else { return false }

        // The bridge reverses rows for Core Graphics display. Convert back to
        // the source DICOM pixel-row convention when sampling the mask.
        let storedRow = maskHeight - localY - 1
        return maskData[storedRow * maskWidth + localX] > 0
    }
}

struct MetalLegacyBrushSegmentationRequest: Sendable {
    let name: String
    let colorRed: Double
    let colorGreen: Double
    let colorBlue: Double
    let slices: [MetalLegacyBrushMaskSlice]

    func run() -> MetalLegacyBrushSegmentationResult? {
        let populatedSlices = slices.compactMap { slice -> (MetalLegacyBrushMaskSlice, (Int, Int, Int, Int))? in
            guard let bounds = slice.occupiedPixelBounds() else { return nil }
            return (slice, (bounds.minimumX, bounds.minimumY, bounds.maximumX, bounds.maximumY))
        }
        guard populatedSlices.isEmpty == false else { return nil }

        var minimum = SIMD3<Double>(repeating: Double.greatestFiniteMagnitude)
        var maximum = SIMD3<Double>(repeating: -Double.greatestFiniteMagnitude)
        var minimumSourceSpacing = Double.greatestFiniteMagnitude
        for (slice, bounds) in populatedSlices {
            minimumSourceSpacing = min(
                minimumSourceSpacing,
                max(min(slice.geometry.spacingX, slice.geometry.spacingY), 0.01)
            )
            let halfThickness = slice.effectiveThicknessMM * 0.5
            for pixelY in [Double(bounds.1) + slice.originY, Double(bounds.3 + 1) + slice.originY] {
                for pixelX in [Double(bounds.0) + slice.originX, Double(bounds.2 + 1) + slice.originX] {
                    let planePoint = slice.geometry.dicomPoint(pixelX: pixelX, pixelY: pixelY)
                    for direction in [-1.0, 1.0] {
                        let point = planePoint + slice.geometry.normal * (halfThickness * direction)
                        minimum = SIMD3<Double>(
                            min(minimum.x, point.x),
                            min(minimum.y, point.y),
                            min(minimum.z, point.z)
                        )
                        maximum = SIMD3<Double>(
                            max(maximum.x, point.x),
                            max(maximum.y, point.y),
                            max(maximum.z, point.z)
                        )
                    }
                }
            }
        }
        guard minimumSourceSpacing.isFinite,
              minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite else { return nil }

        var spacing = min(max(minimumSourceSpacing, 0.45), 1.0)
        let padding = SIMD3<Double>(repeating: spacing * 1.5)
        minimum -= padding
        maximum += padding

        func dimensions(for candidateSpacing: Double) -> MetalStudyROIGridDimensions? {
            let extent = maximum - minimum
            let rawValues = [extent.x, extent.y, extent.z].map {
                ceil(max($0, 0) / candidateSpacing) + 1
            }
            guard rawValues.allSatisfy({ $0.isFinite && $0 >= 2 && $0 <= 4_096 }) else { return nil }
            let values = rawValues.map { Int($0) }
            return MetalStudyROIGridDimensions(x: values[0], y: values[1], z: values[2])
        }

        let maximumVoxelCount = 420_000
        var gridDimensions: MetalStudyROIGridDimensions?
        for _ in 0..<8 {
            guard let candidate = dimensions(for: spacing) else { return nil }
            gridDimensions = candidate
            if candidate.voxelCount <= maximumVoxelCount { break }
            spacing *= pow(Double(candidate.voxelCount) / Double(maximumVoxelCount), 1.0 / 3.0) * 1.01
        }
        guard let gridDimensions,
              gridDimensions.voxelCount > 0,
              gridDimensions.voxelCount <= maximumVoxelCount else { return nil }

        var probabilities = Array(repeating: UInt8(0), count: gridDimensions.voxelCount)
        var insideCount = 0
        var coordinateSum = SIMD3<Double>(repeating: 0)
        for z in 0..<gridDimensions.z {
            for y in 0..<gridDimensions.y {
                for x in 0..<gridDimensions.x {
                    let point = minimum + SIMD3<Double>(Double(x), Double(y), Double(z)) * spacing
                    guard populatedSlices.contains(where: {
                        $0.0.contains(worldPoint: point, gridSpacing: spacing)
                    }) else { continue }
                    let index = (z * gridDimensions.y + y) * gridDimensions.x + x
                    probabilities[index] = 255
                    insideCount += 1
                    coordinateSum += SIMD3<Double>(Double(x), Double(y), Double(z))
                }
            }
        }
        guard insideCount > 0 else { return nil }

        let meanCoordinate = coordinateSum / Double(insideCount)
        var centerCoordinate = SIMD3<Int>(repeating: 0)
        var nearestDistanceSquared = Double.greatestFiniteMagnitude
        for index in probabilities.indices where probabilities[index] >= 128 {
            let plane = gridDimensions.x * gridDimensions.y
            let z = index / plane
            let remainder = index - z * plane
            let y = remainder / gridDimensions.x
            let x = remainder - y * gridDimensions.x
            let coordinate = SIMD3<Double>(Double(x), Double(y), Double(z))
            let distanceSquared = simd_length_squared(coordinate - meanCoordinate)
            if distanceSquared < nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                centerCoordinate = SIMD3<Int>(x, y, z)
            }
        }

        let field = MetalStudyROIVoxelField(
            dimensions: gridDimensions,
            origin: MetalStudyROIPoint(minimum),
            spacingMM: spacing,
            probabilities: Data(probabilities)
        )
        let center = minimum + SIMD3<Double>(
            Double(centerCoordinate.x),
            Double(centerCoordinate.y),
            Double(centerCoordinate.z)
        ) * spacing
        let equivalentRadius = max(
            pow(3 * field.volumeMM3 / (4 * Double.pi), 1.0 / 3.0),
            spacing
        )
        return MetalLegacyBrushSegmentationResult(
            name: name,
            colorRed: colorRed,
            colorGreen: colorGreen,
            colorBlue: colorBlue,
            center: center,
            radiusMM: equivalentRadius,
            voxelField: field
        )
    }
}

struct MetalLegacyBrushSegmentationResult: Sendable {
    let name: String
    let colorRed: Double
    let colorGreen: Double
    let colorBlue: Double
    let center: SIMD3<Double>
    let radiusMM: Double
    let voxelField: MetalStudyROIVoxelField
}

enum MetalStudyROIAnchorKind: String, Codable, Equatable, Sendable {
    case manual
    case automatic
}

struct MetalStudyROI: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var trackingUID: String
    var name: String
    var studyInstanceUID: String
    var frameOfReferenceUID: String
    var sourceSeriesIdentifier: String
    var colorRed: Double
    var colorGreen: Double
    var colorBlue: Double
    var center: MetalStudyROIPoint
    var radiusMM: Double
    var anchors: [MetalStudyROIPoint]
    var anchorKinds: [MetalStudyROIAnchorKind]
    var anchorBaselinePoints: [MetalStudyROIPoint]
    var supportRadiusMM: Double
    var volumeMM3: Double
    var modifiedAt: Date
    var voxelField: MetalStudyROIVoxelField?

    private var kernelAnchorDirections: [SIMD3<Double>] = []
    private var kernelAnchorRadii: [Double] = []
    private var kernelAnchorDisplacements: [SIMD3<Double>] = []
    private var kernelSpatialSupportMM = 4.0
    private var hasAnchorDeformation = false
    private var kernelAngularSupport = 1.0

    init(
        id: UUID = UUID(),
        trackingUID: String = MetalStudyROI.makeTrackingUID(),
        name: String,
        studyInstanceUID: String,
        frameOfReferenceUID: String,
        sourceSeriesIdentifier: String,
        color: NSColor,
        center: SIMD3<Double>,
        radiusMM: Double
    ) {
        self.id = id
        self.trackingUID = trackingUID
        self.name = name
        self.studyInstanceUID = studyInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.sourceSeriesIdentifier = sourceSeriesIdentifier
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        colorRed = Double(rgb.redComponent)
        colorGreen = Double(rgb.greenComponent)
        colorBlue = Double(rgb.blueComponent)
        self.center = MetalStudyROIPoint(center)
        self.radiusMM = max(radiusMM, 0.5)
        anchors = []
        anchorKinds = []
        anchorBaselinePoints = []
        supportRadiusMM = max(radiusMM * 0.8, 4)
        volumeMM3 = 4.0 / 3.0 * Double.pi * pow(max(radiusMM, 0.5), 3)
        modifiedAt = Date()
        voxelField = nil
    }

    var color: NSColor {
        NSColor(
            deviceRed: CGFloat(colorRed),
            green: CGFloat(colorGreen),
            blue: CGFloat(colorBlue),
            alpha: 1
        )
    }

    mutating func setColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        colorRed = Double(rgb.redComponent)
        colorGreen = Double(rgb.greenComponent)
        colorBlue = Double(rgb.blueComponent)
        modifiedAt = Date()
    }

    mutating func translate(by offset: SIMD3<Double>) {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { return }
        center = MetalStudyROIPoint(center.vector + offset)
        anchors = anchors.map { MetalStudyROIPoint($0.vector + offset) }
        anchorBaselinePoints = anchorBaselinePoints.map {
            MetalStudyROIPoint($0.vector + offset)
        }
        voxelField = voxelField?.translated(by: offset)
        modifiedAt = Date()
        rebuildDerivedState()
    }

    var volumeML: Double {
        volumeMM3 / 1_000
    }

    var conservativeBoundingRadiusMM: Double {
        max(
            max(radiusMM, kernelAnchorRadii.max() ?? radiusMM),
            voxelField?.occupiedMaximumDistance(from: center.vector) ?? 0
        )
    }

    var manualAnchorCount: Int {
        anchorKinds.filter { $0 == .manual }.count
    }

    var automaticAnchorCount: Int {
        max(anchors.count - manualAnchorCount, 0)
    }

    func anchorKind(at index: Int) -> MetalStudyROIAnchorKind {
        anchorKinds.indices.contains(index) ? anchorKinds[index] : .manual
    }

    func surfaceRadius(along proposedDirection: SIMD3<Double>) -> Double {
        let directionLength = simd_length(proposedDirection)
        guard directionLength > 0.000_001 else {
            return radiusMM
        }
        let direction = proposedDirection / directionLength

        if let voxelField,
           let baselineRadius = voxelField.surfaceRadius(
               from: center.vector,
               along: direction
           ) {
            guard hasAnchorDeformation else { return baselineRadius }
            let baselinePoint = center.vector + direction * baselineRadius
            var deformedPoint = baselinePoint
            // The displacement kernels are centred on their edited target
            // locations. A few fixed-point iterations find the corresponding
            // deformed surface point without assuming the surface is spherical.
            for _ in 0..<3 {
                deformedPoint = baselinePoint + interpolatedSurfaceDisplacement(at: deformedPoint)
            }
            return max(simd_dot(deformedPoint - center.vector, direction), 0.5)
        }

        guard anchors.isEmpty == false,
              anchors.count == kernelAnchorDirections.count,
              anchors.count == kernelAnchorRadii.count else {
            return radiusMM
        }
        return max(
            interpolatedAnchorValue(
                along: direction,
                values: kernelAnchorRadii,
                fallback: radiusMM
            ),
            0.5
        )
    }

    private func interpolatedAnchorValue(
        along direction: SIMD3<Double>,
        values: [Double],
        fallback: Double
    ) -> Double {
        guard values.count == anchors.count else { return fallback }
        var weightedRadius = 0.0
        var totalWeight = 0.0
        var uncoveredFraction = 1.0
        for index in anchors.indices {
            let chordDistance = simd_distance(direction, kernelAnchorDirections[index])
            if chordDistance < 0.000_001 {
                return values[index]
            }
            let kernel = Self.wendlandC2(chordDistance / max(kernelAngularSupport, 0.001))
            guard kernel > 0 else { continue }
            // Manual anchors are hard constraints at their exact direction (the
            // early return above). Give them only a modest interpolation bias so
            // they do not flatten a broad neighborhood that image refinement
            // should still be free to fit.
            let priority = anchorKind(at: index) == .manual ? 2.5 : 1.0
            let weight = priority * kernel / max(chordDistance * chordDistance, 0.000_001)
            weightedRadius += weight * values[index]
            totalWeight += weight
            // Combining the compact kernels as coverage keeps the blend smooth
            // where the nearest anchor changes. Taking only the strongest kernel
            // created Voronoi-like creases and allowed the contour to sag back
            // toward the original sphere between otherwise good auto anchors.
            uncoveredFraction *= 1 - kernel
        }
        guard totalWeight > 0 else { return fallback }
        let constrainedRadius = weightedRadius / totalWeight
        let combinedInfluence = 1 - uncoveredFraction
        return fallback + (constrainedRadius - fallback) * combinedInfluence
    }

    private func interpolatedSurfaceDisplacement(
        at point: SIMD3<Double>
    ) -> SIMD3<Double> {
        guard hasAnchorDeformation,
              anchors.count == kernelAnchorDisplacements.count else {
            return .zero
        }
        var weightedDisplacement = SIMD3<Double>.zero
        var totalWeight = 0.0
        var uncoveredFraction = 1.0
        for index in anchors.indices {
            let distance = simd_distance(point, anchors[index].vector)
            if distance < 0.000_001 {
                return kernelAnchorDisplacements[index]
            }
            let kernel = Self.wendlandC2(distance / max(kernelSpatialSupportMM, 0.001))
            guard kernel > 0 else { continue }
            let priority = anchorKind(at: index) == .manual ? 2.5 : 1.0
            let weight = priority * kernel / max(distance * distance, 0.000_001)
            weightedDisplacement += kernelAnchorDisplacements[index] * weight
            totalWeight += weight
            uncoveredFraction *= 1 - kernel
        }
        guard totalWeight > 0 else { return .zero }
        return weightedDisplacement / totalWeight * (1 - uncoveredFraction)
    }

    mutating func setSphere(center: SIMD3<Double>, radiusMM: Double) {
        self.center = MetalStudyROIPoint(center)
        self.radiusMM = max(radiusMM, 0.5)
        supportRadiusMM = max(self.radiusMM * 0.8, 4)
        anchors.removeAll()
        anchorKinds.removeAll()
        anchorBaselinePoints.removeAll()
        voxelField = nil
        kernelAnchorDirections.removeAll()
        kernelAnchorRadii.removeAll()
        kernelAnchorDisplacements.removeAll()
        hasAnchorDeformation = false
        volumeMM3 = 4.0 / 3.0 * Double.pi * pow(self.radiusMM, 3)
        modifiedAt = Date()
    }

    @discardableResult
    mutating func addAnchor(_ point: SIMD3<Double>) -> Int {
        seedAutomaticBoundaryScaffoldIfNeeded()
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        let minimumSeparation = max(voxelField?.spacingMM ?? radiusMM * 0.015, 0.25)
        if let index = anchors.firstIndex(where: {
            simd_distance($0.vector, point) < minimumSeparation
        }) {
            anchors[index] = MetalStudyROIPoint(point)
            anchorKinds[index] = .manual
            rebuildAnchorSurface()
            return index
        } else {
            let estimatedBaseline = point - interpolatedSurfaceDisplacement(at: point)
            let baselinePoint = voxelField?.nearestBoundaryPoint(to: estimatedBaseline) ?? point
            let promotionDistance = max((voxelField?.spacingMM ?? 0.5) * 4, 2.5)
            if let automaticIndex = anchors.indices
                .filter({ anchorKinds[$0] == .automatic })
                .min(by: {
                    simd_length_squared(anchorBaselinePoints[$0].vector - baselinePoint)
                        < simd_length_squared(anchorBaselinePoints[$1].vector - baselinePoint)
                }),
               simd_distance(
                   anchorBaselinePoints[automaticIndex].vector,
                   baselinePoint
               ) <= promotionDistance {
                // Promote the nearest scaffold correspondence instead of leaving
                // a zero-displacement handle behind at the old surface. Keeping
                // both would permit a duplicated fold between the old and new
                // boundary positions.
                anchors[automaticIndex] = MetalStudyROIPoint(point)
                anchorKinds[automaticIndex] = .manual
                anchorBaselinePoints[automaticIndex] = MetalStudyROIPoint(baselinePoint)
                rebuildAnchorSurface()
                return automaticIndex
            }
            anchors.append(MetalStudyROIPoint(point))
            anchorKinds.append(.manual)
            anchorBaselinePoints.append(MetalStudyROIPoint(baselinePoint))
        }
        rebuildAnchorSurface()
        return anchors.count - 1
    }

    mutating func moveAnchor(at index: Int, to point: SIMD3<Double>) {
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        guard anchors.indices.contains(index) else { return }
        anchors[index] = MetalStudyROIPoint(point)
        anchorKinds[index] = .manual
        rebuildAnchorSurface()
    }

    mutating func removeAnchor(at index: Int) {
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        guard anchors.indices.contains(index) else { return }
        anchors.remove(at: index)
        anchorKinds.remove(at: index)
        anchorBaselinePoints.remove(at: index)
        rebuildAnchorSurface()
    }

    mutating func replaceAutomaticAnchors(with points: [SIMD3<Double>]) {
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        let manualIndices = anchors.indices.filter { anchorKinds[$0] == .manual }
        let manualAnchors = manualIndices.map { anchors[$0] }
        let boundaryPoints = voxelField?.boundaryPoints() ?? []
        let manualBaselines = manualAnchors.map { anchor in
            MetalStudyROIPoint(
                boundaryPoints.min {
                    simd_length_squared($0 - anchor.vector)
                        < simd_length_squared($1 - anchor.vector)
                } ?? anchor.vector
            )
        }
        let minimumManualDistance = max(voxelField?.spacingMM ?? 0.5, 0.5)
        let automaticPoints = points.filter { point in
            manualAnchors.allSatisfy {
                simd_distance($0.vector, point) >= minimumManualDistance
            }
        }
        anchors = manualAnchors + automaticPoints.map(MetalStudyROIPoint.init)
        anchorKinds = Array(repeating: .manual, count: manualAnchors.count)
            + Array(repeating: .automatic, count: automaticPoints.count)
        anchorBaselinePoints = manualBaselines + automaticPoints.map(MetalStudyROIPoint.init)
        rebuildAnchorSurface()
    }

    mutating func applyImageRefinement(
        automaticPoints: [SIMD3<Double>],
        voxelField: MetalStudyROIVoxelField,
        measuredVolumeMM3: Double? = nil,
        updateVolume: Bool = true
    ) {
        self.voxelField = voxelField.isValid ? voxelField : nil
        replaceAutomaticAnchors(with: automaticPoints)
        if updateVolume, let field = self.voxelField {
            volumeMM3 = measuredVolumeMM3 ?? field.volumeMM3
        }
        modifiedAt = Date()
    }

    func implicitValue(at point: SIMD3<Double>) -> Double {
        if let voxelField {
            let sampledPoint = point - interpolatedSurfaceDisplacement(at: point)
            guard let probability = voxelField.probability(at: sampledPoint) else { return 1 }
            return 0.5 - probability
        }
        let offset = point - center.vector
        let distance = simd_length(offset)
        guard anchors.count == kernelAnchorDirections.count,
              anchors.count == kernelAnchorRadii.count,
              anchors.isEmpty == false,
              distance > 0.000_001 else {
            return distance - radiusMM
        }

        return distance - surfaceRadius(along: offset / distance)
    }

    mutating func rebuildDerivedState() {
        radiusMM = max(radiusMM, 0.5)
        if voxelField?.isValid == false { voxelField = nil }
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        rebuildKernelState()
    }

    /// Adds a sparse, deterministic set of movable boundary landmarks to an
    /// imported voxel mask. The voxel field remains the exact baseline; these
    /// zero-displacement landmarks localize subsequent manual deformations and
    /// keep image refinement from replacing the imported shape wholesale.
    @discardableResult
    mutating func seedAutomaticBoundaryScaffoldIfNeeded(targetCount: Int = 96) -> Bool {
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        guard automaticAnchorCount == 0,
              let voxelField,
              voxelField.isValid,
              targetCount >= 24 else { return false }
        let minimumManualDistance = max(voxelField.spacingMM, 0.5)
        let points = voxelField.uniformlySampledBoundaryPoints(targetCount: targetCount)
            .filter { point in
                anchors.indices.allSatisfy { index in
                    anchorKinds[index] != .manual
                        || simd_distance(anchors[index].vector, point) >= minimumManualDistance
                }
            }
        guard points.count >= min(targetCount / 2, 32) else { return false }

        let encodedPoints = points.map(MetalStudyROIPoint.init)
        anchors.append(contentsOf: encodedPoints)
        anchorKinds.append(contentsOf: repeatElement(.automatic, count: encodedPoints.count))
        anchorBaselinePoints.append(contentsOf: encodedPoints)
        rebuildAnchorSurface()
        return true
    }

    func duplicated(name: String) -> MetalStudyROI {
        var duplicate = MetalStudyROI(
            id: UUID(),
            trackingUID: Self.makeTrackingUID(),
            name: name,
            studyInstanceUID: studyInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            sourceSeriesIdentifier: sourceSeriesIdentifier,
            color: color,
            center: center.vector,
            radiusMM: radiusMM
        )
        duplicate.anchors = anchors
        duplicate.anchorKinds = anchorKinds
        duplicate.anchorBaselinePoints = anchorBaselinePoints
        duplicate.supportRadiusMM = supportRadiusMM
        duplicate.volumeMM3 = volumeMM3
        duplicate.voxelField = voxelField
        duplicate.modifiedAt = Date()
        duplicate.rebuildDerivedState()
        return duplicate
    }

    func transferred(
        movingToFixedWorld matrix: simd_float4x4,
        studyInstanceUID: String,
        frameOfReferenceUID: String,
        sourceSeriesIdentifier: String
    ) -> MetalStudyROI? {
        func transformedPoint(_ point: MetalStudyROIPoint) -> MetalStudyROIPoint {
            let value = matrix * SIMD4<Float>(
                Float(point.x),
                Float(point.y),
                Float(point.z),
                1
            )
            let divisor = abs(value.w) > 0.000_001 ? value.w : 1
            return MetalStudyROIPoint(
                SIMD3<Double>(
                    Double(value.x / divisor),
                    Double(value.y / divisor),
                    Double(value.z / divisor)
                )
            )
        }

        var transferred = MetalStudyROI(
            name: name,
            studyInstanceUID: studyInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            sourceSeriesIdentifier: sourceSeriesIdentifier,
            color: color,
            center: transformedPoint(center).vector,
            radiusMM: radiusMM
        )
        transferred.anchors = anchors.map(transformedPoint)
        transferred.anchorKinds = anchorKinds
        transferred.anchorBaselinePoints = anchorBaselinePoints.map(transformedPoint)
        transferred.supportRadiusMM = supportRadiusMM
        transferred.voxelField = voxelField?.transformed(by: matrix)
        transferred.volumeMM3 = transferred.voxelField?.volumeMM3 ?? volumeMM3
        transferred.modifiedAt = Date()
        transferred.rebuildDerivedState()
        guard transferred.voxelField != nil || transferred.radiusMM > 0 else { return nil }
        return transferred
    }

    func anchorSurfaceNormal(at index: Int) -> SIMD3<Double>? {
        guard anchorBaselinePoints.indices.contains(index) else { return nil }
        return voxelField?.outwardNormal(at: anchorBaselinePoints[index].vector)
    }

    func deformedSurfacePoint(fromBaseline point: SIMD3<Double>) -> SIMD3<Double> {
        guard hasAnchorDeformation else { return point }
        var result = point
        for _ in 0..<3 {
            result = point + interpolatedSurfaceDisplacement(at: result)
        }
        return result
    }

    mutating func updateEstimatedVolume() {
        if let voxelField, voxelField.isValid, hasAnchorDeformation == false {
            volumeMM3 = voxelField.volumeMM3
            return
        }
        if anchors.isEmpty {
            volumeMM3 = 4.0 / 3.0 * Double.pi * pow(radiusMM, 3)
            return
        }

        let boundingRadius = conservativeBoundingRadiusMM
        let minimum = center.vector - SIMD3<Double>(repeating: boundingRadius)
        let maximum = center.vector + SIMD3<Double>(repeating: boundingRadius)
        var spacing = max(min(radiusMM / 30, 1.0), 0.25)
        let extent = simd_max(maximum - minimum, SIMD3<Double>(repeating: spacing))
        let initialSampleCount = (extent.x / spacing) * (extent.y / spacing) * (extent.z / spacing)
        let maximumSampleCount = 4_000_000.0
        if initialSampleCount > maximumSampleCount {
            spacing *= pow(initialSampleCount / maximumSampleCount, 1.0 / 3.0)
        }
        let dimensions = SIMD3<Int>(
            max(Int(ceil((maximum.x - minimum.x) / spacing)), 1),
            max(Int(ceil((maximum.y - minimum.y) / spacing)), 1),
            max(Int(ceil((maximum.z - minimum.z) / spacing)), 1)
        )
        var insideCount = 0
        for z in 0..<dimensions.z {
            let worldZ = minimum.z + (Double(z) + 0.5) * spacing
            for y in 0..<dimensions.y {
                let worldY = minimum.y + (Double(y) + 0.5) * spacing
                for x in 0..<dimensions.x {
                    let point = SIMD3<Double>(
                        minimum.x + (Double(x) + 0.5) * spacing,
                        worldY,
                        worldZ
                    )
                    if implicitValue(at: point) <= 0 {
                        insideCount += 1
                    }
                }
            }
        }
        volumeMM3 = Double(insideCount) * spacing * spacing * spacing
    }

    private mutating func rebuildKernelState() {
        let count = anchors.count
        guard count > 0 else {
            kernelAnchorDirections = []
            kernelAnchorRadii = []
            kernelAnchorDisplacements = []
            kernelSpatialSupportMM = 4
            hasAnchorDeformation = false
            kernelAngularSupport = 1
            supportRadiusMM = max(radiusMM * 0.8, 4)
            return
        }

        kernelAnchorDirections = anchors.map {
            Self.radialDirection(from: center.vector, to: $0.vector)
        }
        kernelAnchorRadii = anchors.map {
            max(simd_distance(center.vector, $0.vector), 0.5)
        }
        kernelAnchorDisplacements = anchors.indices.map { index in
            guard anchorBaselinePoints.indices.contains(index) else { return .zero }
            return anchors[index].vector - anchorBaselinePoints[index].vector
        }
        hasAnchorDeformation = kernelAnchorDisplacements.contains {
            simd_length_squared($0) > 0.05 * 0.05
        }
        kernelSpatialSupportMM = Self.preferredSpatialSupport(
            for: anchorBaselinePoints.map(\.vector),
            maximumDisplacement: kernelAnchorDisplacements.map { simd_length($0) }.max() ?? 0
        )
        kernelAngularSupport = Self.preferredAngularSupport(for: kernelAnchorDirections)
        supportRadiusMM = max(radiusMM * kernelAngularSupport, 4)
    }

    private mutating func normalizeAnchorKinds() {
        if anchorKinds.count > anchors.count {
            anchorKinds.removeLast(anchorKinds.count - anchors.count)
        } else if anchorKinds.count < anchors.count {
            // Points saved before provenance was introduced may include hand work;
            // preserve them rather than allowing a future refinement to move them.
            anchorKinds.append(contentsOf: repeatElement(
                .manual,
                count: anchors.count - anchorKinds.count
            ))
        }
    }

    private mutating func normalizeAnchorBaselines() {
        guard anchorBaselinePoints.count != anchors.count else { return }
        guard let voxelField, voxelField.isValid else {
            anchorBaselinePoints = anchors
            return
        }

        // Authoring payloads created before surface correspondences were stored
        // used centre-radial automatic points. Preserve manual work, derive its
        // nearest baseline correspondence, and replace the obsolete automatic
        // scaffold with complete topology-independent boundary coverage.
        let manualAnchors = anchors.indices.compactMap { index in
            anchorKinds[index] == .manual ? anchors[index] : nil
        }
        let boundaryPoints = voxelField.boundaryPoints()
        anchors = manualAnchors
        anchorKinds = Array(repeating: .manual, count: manualAnchors.count)
        anchorBaselinePoints = manualAnchors.map { anchor in
            MetalStudyROIPoint(
                boundaryPoints.min {
                    simd_length_squared($0 - anchor.vector)
                        < simd_length_squared($1 - anchor.vector)
                } ?? anchor.vector
            )
        }
        let minimumManualDistance = max(voxelField.spacingMM, 0.5)
        let automaticPoints = voxelField.uniformlySampledBoundaryPoints(targetCount: 96)
            .filter { point in
                manualAnchors.allSatisfy {
                    simd_distance($0.vector, point) >= minimumManualDistance
                }
            }
            .map(MetalStudyROIPoint.init)
        anchors.append(contentsOf: automaticPoints)
        anchorKinds.append(contentsOf: repeatElement(.automatic, count: automaticPoints.count))
        anchorBaselinePoints.append(contentsOf: automaticPoints)
    }

    private mutating func rebuildAnchorSurface() {
        rebuildKernelState()
        modifiedAt = Date()
    }

    private static func radialDirection(
        from center: SIMD3<Double>,
        to point: SIMD3<Double>
    ) -> SIMD3<Double> {
        let offset = point - center
        let length = simd_length(offset)
        guard length > 0.000_001 else { return SIMD3<Double>(0, 0, 1) }
        return offset / length
    }

    private static func preferredAngularSupport(for directions: [SIMD3<Double>]) -> Double {
        guard directions.count > 1 else { return 1.25 }
        var nearestDistances: [Double] = []
        nearestDistances.reserveCapacity(directions.count)
        for index in directions.indices {
            var nearest = Double.greatestFiniteMagnitude
            for otherIndex in directions.indices where otherIndex != index {
                nearest = min(nearest, simd_distance(directions[index], directions[otherIndex]))
            }
            if nearest.isFinite { nearestDistances.append(nearest) }
        }
        nearestDistances.sort()
        let median = nearestDistances[nearestDistances.count / 2]
        return min(max(median * 3.5, 0.9), 1.5)
    }

    private static func preferredSpatialSupport(
        for points: [SIMD3<Double>],
        maximumDisplacement: Double
    ) -> Double {
        guard points.count > 1 else { return max(4, maximumDisplacement + 1) }
        var nearestDistances: [Double] = []
        nearestDistances.reserveCapacity(points.count)
        for index in points.indices {
            var nearest = Double.greatestFiniteMagnitude
            for otherIndex in points.indices where otherIndex != index {
                nearest = min(nearest, simd_distance(points[index], points[otherIndex]))
            }
            if nearest.isFinite { nearestDistances.append(nearest) }
        }
        nearestDistances.sort()
        let median = nearestDistances[nearestDistances.count / 2]
        return min(max(median * 3, maximumDisplacement + median, 2.5), 12)
    }

    private static func wendlandC2(_ normalizedDistance: Double) -> Double {
        guard normalizedDistance < 1 else { return 0 }
        let remainder = 1 - max(normalizedDistance, 0)
        return pow(remainder, 4) * (4 * normalizedDistance + 1)
    }

    static func makeTrackingUID() -> String {
        var uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        var decimal = ""
        var value = bytes.map(Int.init)
        while value.contains(where: { $0 != 0 }) {
            var quotient: [Int] = []
            var remainder = 0
            for byte in value {
                let accumulator = remainder * 256 + byte
                if quotient.isEmpty == false || accumulator / 10 != 0 {
                    quotient.append(accumulator / 10)
                }
                remainder = accumulator % 10
            }
            decimal.append(String(remainder))
            value = quotient
        }
        return "2.25." + String(decimal.reversed())
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackingUID, name, studyInstanceUID, frameOfReferenceUID
        case sourceSeriesIdentifier, colorRed, colorGreen, colorBlue
        case center, radiusMM, anchors, anchorKinds, anchorBaselinePoints
        case supportRadiusMM, volumeMM3, modifiedAt
        case voxelField
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trackingUID = try container.decode(String.self, forKey: .trackingUID)
        name = try container.decode(String.self, forKey: .name)
        studyInstanceUID = try container.decode(String.self, forKey: .studyInstanceUID)
        frameOfReferenceUID = try container.decode(String.self, forKey: .frameOfReferenceUID)
        sourceSeriesIdentifier = try container.decode(String.self, forKey: .sourceSeriesIdentifier)
        colorRed = try container.decode(Double.self, forKey: .colorRed)
        colorGreen = try container.decode(Double.self, forKey: .colorGreen)
        colorBlue = try container.decode(Double.self, forKey: .colorBlue)
        center = try container.decode(MetalStudyROIPoint.self, forKey: .center)
        radiusMM = try container.decode(Double.self, forKey: .radiusMM)
        anchors = try container.decode([MetalStudyROIPoint].self, forKey: .anchors)
        anchorKinds = try container.decodeIfPresent(
            [MetalStudyROIAnchorKind].self,
            forKey: .anchorKinds
        ) ?? Self.legacyAnchorKinds(for: anchors)
        anchorBaselinePoints = try container.decodeIfPresent(
            [MetalStudyROIPoint].self,
            forKey: .anchorBaselinePoints
        ) ?? []
        supportRadiusMM = try container.decode(Double.self, forKey: .supportRadiusMM)
        volumeMM3 = try container.decode(Double.self, forKey: .volumeMM3)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        voxelField = try container.decodeIfPresent(MetalStudyROIVoxelField.self, forKey: .voxelField)
        normalizeAnchorKinds()
        normalizeAnchorBaselines()
        rebuildKernelState()
    }

    private static func legacyAnchorKinds(
        for anchors: [MetalStudyROIPoint]
    ) -> [MetalStudyROIAnchorKind] {
        // Older authoring payloads did not record provenance. A dense point cloud
        // was produced by image refinement, while a small set was hand-authored.
        // This lets an existing refined ROI be simplified on its next refinement
        // without sacrificing the usual small set of manually placed points.
        let kind: MetalStudyROIAnchorKind = anchors.count >= 24 ? .automatic : .manual
        return Array(repeating: kind, count: anchors.count)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trackingUID, forKey: .trackingUID)
        try container.encode(name, forKey: .name)
        try container.encode(studyInstanceUID, forKey: .studyInstanceUID)
        try container.encode(frameOfReferenceUID, forKey: .frameOfReferenceUID)
        try container.encode(sourceSeriesIdentifier, forKey: .sourceSeriesIdentifier)
        try container.encode(colorRed, forKey: .colorRed)
        try container.encode(colorGreen, forKey: .colorGreen)
        try container.encode(colorBlue, forKey: .colorBlue)
        try container.encode(center, forKey: .center)
        try container.encode(radiusMM, forKey: .radiusMM)
        try container.encode(anchors, forKey: .anchors)
        try container.encode(anchorKinds, forKey: .anchorKinds)
        try container.encode(anchorBaselinePoints, forKey: .anchorBaselinePoints)
        try container.encode(supportRadiusMM, forKey: .supportRadiusMM)
        try container.encode(volumeMM3, forKey: .volumeMM3)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(voxelField, forKey: .voxelField)
    }
}

struct MetalStudyROISurfaceProjection {
    let roi: MetalStudyROI
    let currentToCanonicalTransform: simd_float4x4
}

enum MetalStudyROIEditingMode: Equatable, Sendable {
    case inactive
    case createSphere
    case translate
}

final class MetalStudyROIStore: @unchecked Sendable {
    static let didChangeNotification = Notification.Name("HorosMetalStudyROIDidChange")

    let studyInstanceUID: String
    private(set) var rois: [MetalStudyROI] = []
    private(set) var selectedROIIdentifier: UUID?
    private(set) var revision = 0
    var didChange: (() -> Void)?
    var persistenceHandler: (([MetalStudyROI]) -> Void)?

    private var undoStack: [[MetalStudyROI]] = []
    private var redoStack: [[MetalStudyROI]] = []
    private var provisionalSphereSnapshot: [MetalStudyROI]?
    private var provisionalSphereSelection: UUID?
    private var provisionalAnchorSnapshot: [MetalStudyROI]?
    private var provisionalAnchorIdentifier: UUID?
    private var provisionalAnchorDidMove = false
    private var provisionalTranslationSnapshot: [MetalStudyROI]?
    private var provisionalTranslationIdentifier: UUID?
    private let volumeQueue = DispatchQueue(label: "org.horosproject.horos.metal-roi-volume", qos: .userInitiated)
    private var volumeGenerationByIdentifier: [UUID: Int] = [:]
    private var saveWorkItem: DispatchWorkItem?

    init(studyInstanceUID: String, restoredROIs: [MetalStudyROI] = []) {
        self.studyInstanceUID = studyInstanceUID
        rois = restoredROIs.map { roi in
            var restored = roi
            restored.rebuildDerivedState()
            return restored
        }
        selectedROIIdentifier = rois.first?.id
        for roi in rois where roi.anchors.isEmpty == false {
            scheduleVolumeEstimate(for: roi.id)
        }
    }

    var selectedROI: MetalStudyROI? {
        guard let selectedROIIdentifier else { return nil }
        return rois.first(where: { $0.id == selectedROIIdentifier })
    }

    var canUndo: Bool { undoStack.isEmpty == false }
    var canRedo: Bool { redoStack.isEmpty == false }

    func select(_ identifier: UUID?) {
        selectedROIIdentifier = identifier
        notifyChanged(schedulePersistence: false)
    }

    func mergeRestoredROIs(_ restoredROIs: [MetalStudyROI]) {
        guard restoredROIs.isEmpty == false else { return }
        var changedIdentifiers: [UUID] = []
        for restoredROI in restoredROIs {
            var restored = restoredROI
            restored.rebuildDerivedState()
            if let index = rois.firstIndex(where: { $0.id == restored.id }) {
                guard restored.modifiedAt > rois[index].modifiedAt else { continue }
                rois[index] = restored
            } else {
                rois.append(restored)
            }
            changedIdentifiers.append(restored.id)
        }
        guard changedIdentifiers.isEmpty == false else { return }
        if selectedROIIdentifier == nil {
            selectedROIIdentifier = changedIdentifiers.first
        }
        changedIdentifiers.forEach { scheduleVolumeEstimate(for: $0) }
        notifyChanged(schedulePersistence: false)
    }

    @discardableResult
    func addTransferredROI(_ roi: MetalStudyROI) -> UUID {
        pushUndoState()
        rois.append(roi)
        selectedROIIdentifier = roi.id
        scheduleVolumeEstimate(for: roi.id)
        notifyChanged(schedulePersistence: true)
        return roi.id
    }

    func beginSphere(
        center: SIMD3<Double>,
        name: String,
        studyInstanceUID: String,
        frameOfReferenceUID: String,
        sourceSeriesIdentifier: String,
        color: NSColor
    ) -> UUID {
        provisionalSphereSnapshot = rois
        provisionalSphereSelection = selectedROIIdentifier
        let roi = MetalStudyROI(
            name: name,
            studyInstanceUID: studyInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            sourceSeriesIdentifier: sourceSeriesIdentifier,
            color: color,
            center: center,
            radiusMM: 1
        )
        rois.append(roi)
        selectedROIIdentifier = roi.id
        notifyChanged(schedulePersistence: false)
        return roi.id
    }

    @discardableResult
    func createImageSeededROI(
        name: String,
        studyInstanceUID: String,
        frameOfReferenceUID: String,
        sourceSeriesIdentifier: String,
        color: NSColor,
        center: SIMD3<Double>,
        radiusMM: Double,
        voxelField: MetalStudyROIVoxelField
    ) -> UUID? {
        guard voxelField.isValid else { return nil }
        pushUndoState()
        var roi = MetalStudyROI(
            name: name,
            studyInstanceUID: studyInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            sourceSeriesIdentifier: sourceSeriesIdentifier,
            color: color,
            center: center,
            radiusMM: radiusMM
        )
        roi.applyImageRefinement(
            automaticPoints: [],
            voxelField: voxelField,
            measuredVolumeMM3: voxelField.volumeMM3
        )
        rois.append(roi)
        selectedROIIdentifier = roi.id
        notifyChanged(schedulePersistence: true)
        return roi.id
    }

    func updateSphere(identifier: UUID, center: SIMD3<Double>, edge: SIMD3<Double>) {
        guard let index = rois.firstIndex(where: { $0.id == identifier }) else { return }
        rois[index].setSphere(center: center, radiusMM: max(simd_distance(center, edge), 0.5))
        notifyChanged(schedulePersistence: false)
    }

    func finishSphere(identifier: UUID) {
        if let provisionalSphereSnapshot {
            undoStack.append(provisionalSphereSnapshot)
            if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
            redoStack.removeAll()
        }
        provisionalSphereSnapshot = nil
        provisionalSphereSelection = nil
        scheduleVolumeEstimate(for: identifier)
        notifyChanged(schedulePersistence: true)
    }

    func beginTranslatingROI(_ identifier: UUID) -> Bool {
        guard provisionalTranslationSnapshot == nil,
              rois.contains(where: { $0.id == identifier }) else { return false }
        provisionalTranslationSnapshot = rois
        provisionalTranslationIdentifier = identifier
        return true
    }

    func translateROI(_ identifier: UUID, by offset: SIMD3<Double>) {
        guard provisionalTranslationIdentifier == identifier,
              let snapshot = provisionalTranslationSnapshot,
              let source = snapshot.first(where: { $0.id == identifier }),
              let index = rois.firstIndex(where: { $0.id == identifier }) else { return }
        if simd_length_squared(offset) < 0.000_001 {
            rois[index] = source
        } else {
            var translated = source
            translated.translate(by: offset)
            rois[index] = translated
        }
        notifyChanged(schedulePersistence: false)
    }

    func finishTranslatingROI(_ identifier: UUID) {
        guard provisionalTranslationIdentifier == identifier,
              let snapshot = provisionalTranslationSnapshot else { return }
        provisionalTranslationSnapshot = nil
        provisionalTranslationIdentifier = nil
        guard snapshot != rois else { return }
        appendUndoState(snapshot)
        notifyChanged(schedulePersistence: true)
    }

    func cancelTranslatingROI() {
        guard let snapshot = provisionalTranslationSnapshot else { return }
        rois = snapshot
        provisionalTranslationSnapshot = nil
        provisionalTranslationIdentifier = nil
        notifyChanged(schedulePersistence: false)
    }

    func cancelProvisionalSphere() {
        guard let provisionalSphereSnapshot else { return }
        rois = provisionalSphereSnapshot
        self.provisionalSphereSnapshot = nil
        selectedROIIdentifier = provisionalSphereSelection
        provisionalSphereSelection = nil
        notifyChanged(schedulePersistence: false)
    }

    @discardableResult
    func addAnchor(_ point: SIMD3<Double>, to identifier: UUID) -> Int? {
        guard let index = rois.firstIndex(where: { $0.id == identifier }) else { return nil }
        pushUndoState()
        let anchorIndex = rois[index].addAnchor(point)
        scheduleVolumeEstimate(for: identifier)
        notifyChanged(schedulePersistence: true)
        return anchorIndex
    }

    func beginMovingAnchor(at anchorIndex: Int, in identifier: UUID) -> Bool {
        guard provisionalAnchorSnapshot == nil,
              let roiIndex = rois.firstIndex(where: { $0.id == identifier }),
              rois[roiIndex].anchors.indices.contains(anchorIndex) else { return false }
        provisionalAnchorSnapshot = rois
        provisionalAnchorIdentifier = identifier
        provisionalAnchorDidMove = false
        return true
    }

    func moveAnchor(at anchorIndex: Int, to point: SIMD3<Double>, in identifier: UUID) {
        guard provisionalAnchorIdentifier == identifier,
              let roiIndex = rois.firstIndex(where: { $0.id == identifier }) else { return }
        if provisionalAnchorDidMove == false {
            volumeGenerationByIdentifier[identifier, default: 0] += 1
            provisionalAnchorDidMove = true
        }
        rois[roiIndex].moveAnchor(at: anchorIndex, to: point)
        notifyChanged(schedulePersistence: false)
    }

    func finishMovingAnchor(in identifier: UUID) {
        guard provisionalAnchorIdentifier == identifier,
              let snapshot = provisionalAnchorSnapshot else { return }
        provisionalAnchorSnapshot = nil
        provisionalAnchorIdentifier = nil
        provisionalAnchorDidMove = false
        if snapshot != rois {
            appendUndoState(snapshot)
            scheduleVolumeEstimate(for: identifier)
            notifyChanged(schedulePersistence: true)
        }
    }

    func cancelMovingAnchor() {
        guard let snapshot = provisionalAnchorSnapshot else { return }
        let identifier = provisionalAnchorIdentifier
        let needsVolumeEstimate = provisionalAnchorDidMove
        rois = snapshot
        provisionalAnchorSnapshot = nil
        provisionalAnchorIdentifier = nil
        provisionalAnchorDidMove = false
        if needsVolumeEstimate, let identifier {
            scheduleVolumeEstimate(for: identifier)
        }
        notifyChanged(schedulePersistence: needsVolumeEstimate)
    }

    func removeAnchor(at anchorIndex: Int, from identifier: UUID) {
        guard let roiIndex = rois.firstIndex(where: { $0.id == identifier }),
              rois[roiIndex].anchors.indices.contains(anchorIndex) else { return }
        pushUndoState()
        rois[roiIndex].removeAnchor(at: anchorIndex)
        scheduleVolumeEstimate(for: identifier)
        notifyChanged(schedulePersistence: true)
    }

    func applyImageRefinement(
        _ points: [SIMD3<Double>],
        voxelField: MetalStudyROIVoxelField,
        measuredVolumeMM3: Double,
        to identifier: UUID
    ) {
        guard let roiIndex = rois.firstIndex(where: { $0.id == identifier }) else { return }
        pushUndoState()
        rois[roiIndex].applyImageRefinement(
            automaticPoints: points,
            voxelField: voxelField,
            measuredVolumeMM3: measuredVolumeMM3
        )
        notifyChanged(schedulePersistence: true)
    }

    func applyInteractiveImageRefinement(
        _ points: [SIMD3<Double>],
        voxelField: MetalStudyROIVoxelField,
        to identifier: UUID
    ) {
        guard provisionalAnchorIdentifier == identifier,
              let roiIndex = rois.firstIndex(where: { $0.id == identifier }) else { return }
        rois[roiIndex].applyImageRefinement(
            automaticPoints: points,
            voxelField: voxelField,
            updateVolume: false
        )
        notifyChanged(schedulePersistence: false)
    }

    func applyAutomaticImageRefinement(
        _ points: [SIMD3<Double>],
        voxelField: MetalStudyROIVoxelField,
        measuredVolumeMM3: Double,
        to identifier: UUID
    ) {
        guard let roiIndex = rois.firstIndex(where: { $0.id == identifier }) else { return }
        rois[roiIndex].applyImageRefinement(
            automaticPoints: points,
            voxelField: voxelField,
            measuredVolumeMM3: measuredVolumeMM3
        )
        notifyChanged(schedulePersistence: true)
    }

    func renameSelectedROI(to name: String) {
        guard let selectedROIIdentifier,
              let index = rois.firstIndex(where: { $0.id == selectedROIIdentifier }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != rois[index].name else { return }
        pushUndoState()
        rois[index].name = trimmed
        rois[index].modifiedAt = Date()
        notifyChanged(schedulePersistence: true)
    }

    func setColor(_ color: NSColor, for identifier: UUID) {
        guard let index = rois.firstIndex(where: { $0.id == identifier }) else { return }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let components = SIMD3<Double>(
            Double(rgb.redComponent),
            Double(rgb.greenComponent),
            Double(rgb.blueComponent)
        )
        let current = SIMD3<Double>(
            rois[index].colorRed,
            rois[index].colorGreen,
            rois[index].colorBlue
        )
        guard simd_distance_squared(components, current) > 0.000_001 else { return }
        pushUndoState()
        rois[index].setColor(rgb)
        notifyChanged(schedulePersistence: true)
    }

    @discardableResult
    func duplicateSelectedROI() -> UUID? {
        guard let selectedROIIdentifier,
              let source = rois.first(where: { $0.id == selectedROIIdentifier }) else { return nil }
        pushUndoState()

        let baseName = source.name + " " + NSLocalizedString("Copy", comment: "")
        let existingNames = Set(rois.map { $0.name.lowercased() })
        var name = baseName
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }

        var duplicate = source.duplicated(name: name)
        duplicate.seedAutomaticBoundaryScaffoldIfNeeded()
        rois.append(duplicate)
        self.selectedROIIdentifier = duplicate.id
        notifyChanged(schedulePersistence: true)
        return duplicate.id
    }

    func deleteSelectedROI() {
        guard let selectedROIIdentifier,
              let index = rois.firstIndex(where: { $0.id == selectedROIIdentifier }) else { return }
        pushUndoState()
        rois.remove(at: index)
        volumeGenerationByIdentifier[selectedROIIdentifier, default: 0] += 1
        self.selectedROIIdentifier = rois.indices.contains(index) ? rois[index].id : rois.last?.id
        notifyChanged(schedulePersistence: true)
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        invalidateVolumeEstimates()
        redoStack.append(rois)
        rois = state
        rois.indices.forEach { rois[$0].rebuildDerivedState() }
        if let selectedROIIdentifier, rois.contains(where: { $0.id == selectedROIIdentifier }) == false {
            self.selectedROIIdentifier = rois.last?.id
        }
        notifyChanged(schedulePersistence: true)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        invalidateVolumeEstimates()
        undoStack.append(rois)
        rois = state
        rois.indices.forEach { rois[$0].rebuildDerivedState() }
        if let selectedROIIdentifier, rois.contains(where: { $0.id == selectedROIIdentifier }) == false {
            self.selectedROIIdentifier = rois.last?.id
        }
        notifyChanged(schedulePersistence: true)
    }

    private func pushUndoState() {
        appendUndoState(rois)
    }

    private func appendUndoState(_ state: [MetalStudyROI]) {
        undoStack.append(state)
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
        redoStack.removeAll()
    }

    private func invalidateVolumeEstimates() {
        for identifier in Array(volumeGenerationByIdentifier.keys) {
            volumeGenerationByIdentifier[identifier, default: 0] += 1
        }
    }

    private func scheduleVolumeEstimate(for identifier: UUID) {
        guard let roi = rois.first(where: { $0.id == identifier }) else { return }
        let generation = (volumeGenerationByIdentifier[identifier] ?? 0) + 1
        volumeGenerationByIdentifier[identifier] = generation
        volumeQueue.async { [weak self] in
            var measured = roi
            measured.updateEstimatedVolume()
            DispatchQueue.main.async {
                guard let self,
                      generation == self.volumeGenerationByIdentifier[identifier],
                      let index = self.rois.firstIndex(where: { $0.id == identifier }) else { return }
                self.rois[index].volumeMM3 = measured.volumeMM3
                self.notifyChanged(schedulePersistence: true)
            }
        }
    }

    private func notifyChanged(schedulePersistence: Bool) {
        revision &+= 1
        didChange?()
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: ["studyInstanceUID": studyInstanceUID]
        )
        guard schedulePersistence else { return }
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWorkItem = nil
            self.persistenceHandler?(self.rois)
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    func flushPendingPersistence() {
        guard saveWorkItem != nil else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistenceHandler?(rois)
    }
}

struct MetalStudyROIRefinementResult: Sendable {
    let roiIdentifier: UUID
    let automaticAnchors: [SIMD3<Double>]
    let voxelField: MetalStudyROIVoxelField
    let volumeMM3: Double
    let meanDisplacementMM: Double
    let maximumDisplacementMM: Double
}

private final class MetalStudyROIGPUSolver: @unchecked Sendable {
    final class EdgeBuffers: @unchecked Sendable {
        let count: Int
        fileprivate let x: MTLBuffer
        fileprivate let y: MTLBuffer
        fileprivate let z: MTLBuffer

        fileprivate init(count: Int, x: MTLBuffer, y: MTLBuffer, z: MTLBuffer) {
            self.count = count
            self.x = x
            self.y = y
            self.z = z
        }
    }

    final class Workspace: @unchecked Sendable {
        let count: Int
        fileprivate let probability: MTLBuffer
        fileprivate let fixed: MTLBuffer
        fileprivate let initial: MTLBuffer

        fileprivate init(
            count: Int,
            probability: MTLBuffer,
            fixed: MTLBuffer,
            initial: MTLBuffer
        ) {
            self.count = count
            self.probability = probability
            self.fixed = fixed
            self.initial = initial
        }
    }

    private struct Uniforms {
        var dimensions: SIMD3<UInt32>
        var voxelCount: UInt32
        var priorWeight: Float
        var relaxation: Float
        var phase: UInt32
        var padding: UInt32 = 0
    }

    static let shared: MetalStudyROIGPUSolver? = MetalStudyROIGPUSolver()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "metalStudyROIRedBlackRelaxation"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    func makeEdgeBuffers(
        xEdges: [Float],
        yEdges: [Float],
        zEdges: [Float]
    ) -> EdgeBuffers? {
        guard xEdges.isEmpty == false,
              xEdges.count == yEdges.count,
              xEdges.count == zEdges.count else { return nil }
        let byteCount = xEdges.count * MemoryLayout<Float>.stride
        guard let x = device.makeBuffer(
            bytes: xEdges,
            length: byteCount,
            options: .storageModeShared
        ),
              let y = device.makeBuffer(
                bytes: yEdges,
                length: byteCount,
                options: .storageModeShared
              ),
              let z = device.makeBuffer(
                bytes: zEdges,
                length: byteCount,
                options: .storageModeShared
              ) else { return nil }
        return EdgeBuffers(count: xEdges.count, x: x, y: y, z: z)
    }

    func makeWorkspace(count: Int) -> Workspace? {
        guard count > 0 else { return nil }
        let byteCount = count * MemoryLayout<Float>.stride
        guard let probability = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared
        ),
              let fixed = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
              ),
              let initial = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
              ) else { return nil }
        return Workspace(
            count: count,
            probability: probability,
            fixed: fixed,
            initial: initial
        )
    }

    private func copy(_ values: [Float], to buffer: MTLBuffer) {
        values.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: source, byteCount: bytes.count)
        }
    }

    private func copy(_ source: MTLBuffer, to destination: MTLBuffer, byteCount: Int) {
        destination.contents().copyMemory(
            from: UnsafeRawPointer(source.contents()),
            byteCount: byteCount
        )
    }

    func solve(
        dimensions: MetalStudyROIGridDimensions,
        fixedValues: [Float],
        initialValues: [Float]?,
        reuseProbability: Bool,
        priorWeight: Float,
        edgeBuffers: EdgeBuffers,
        workspace: Workspace,
        sweepCount: Int
    ) -> Bool {
        let count = dimensions.voxelCount
        guard count > 0,
              fixedValues.count == count,
              edgeBuffers.count == count,
              workspace.count == count else { return false }
        if reuseProbability == false,
           initialValues?.count != count {
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        // The workspace belongs to the prepared image/ROI pair. Reusing these
        // shared buffers removes three full-volume Metal allocations from every
        // drag preview while still beginning each solve from its warm solution.
        copy(fixedValues, to: workspace.fixed)
        let byteCount = count * MemoryLayout<Float>.stride
        if reuseProbability {
            copy(workspace.probability, to: workspace.initial, byteCount: byteCount)
        } else if let initialValues {
            copy(initialValues, to: workspace.probability)
            copy(initialValues, to: workspace.initial)
        }

        let threadWidth = max(
            min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
            1
        )
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: 1, depth: 1)
        let threads = MTLSize(width: count, height: 1, depth: 1)
        var uniforms = Uniforms(
            dimensions: SIMD3<UInt32>(
                UInt32(dimensions.x),
                UInt32(dimensions.y),
                UInt32(dimensions.z)
            ),
            voxelCount: UInt32(count),
            priorWeight: max(priorWeight, 0),
            relaxation: 1.35,
            phase: 0
        )

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(workspace.probability, offset: 0, index: 0)
        encoder.setBuffer(workspace.fixed, offset: 0, index: 1)
        encoder.setBuffer(workspace.initial, offset: 0, index: 2)
        encoder.setBuffer(edgeBuffers.x, offset: 0, index: 3)
        encoder.setBuffer(edgeBuffers.y, offset: 0, index: 4)
        encoder.setBuffer(edgeBuffers.z, offset: 0, index: 5)

        let sweepCount = max(sweepCount, 1)
        for sweep in 0..<sweepCount {
            for phase in UInt32(0)...UInt32(1) {
                uniforms.phase = phase
                encoder.setBytes(
                    &uniforms,
                    length: MemoryLayout<Uniforms>.stride,
                    index: 6
                )
                encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
                if sweep + 1 < sweepCount || phase == 0 {
                    encoder.memoryBarrier(scope: .buffers)
                }
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    func quantizedProbabilities(in workspace: Workspace) -> ([UInt8], Int) {
        let count = workspace.count
        let pointer = workspace.probability.contents().bindMemory(to: Float.self, capacity: count)
        var bytes = Array(repeating: UInt8(0), count: count)
        var insideCount = 0
        for index in 0..<count {
            let rawProbability = pointer[index]
            let probability = rawProbability.isFinite
                ? min(max(rawProbability, 0), 1)
                : 0
            let byte = UInt8((probability * 255).rounded())
            bytes[index] = byte
            if byte >= 128 { insideCount += 1 }
        }
        return (bytes, insideCount)
    }
}

final class MetalStudyROIRefinementRequest: @unchecked Sendable {
    private(set) var failureDetail: String?

    private func fail<T>(_ detail: String) -> T? {
        failureDetail = detail
        return nil
    }

    private struct Slice {
        let pixels: MetalStoredInt16PixelData
        let geometry: MetalViewerSliceGeometry
        let position: Double
    }

    private struct IntensityVolume {
        let slices: [Slice]
        let referenceNormal: SIMD3<Double>
        let sliceSpacing: Double
        let minimumVoxelSpacing: Double

        init?(pixList: [DCMPix]) {
            guard let firstGeometry = pixList.lazy.compactMap({ MetalViewerSliceGeometry(pix: $0) }).first else {
                return nil
            }
            let normalLength = simd_length(firstGeometry.normal)
            guard normalLength > 0.000_001 else { return nil }
            let referenceNormal = firstGeometry.normal / normalLength

            var decoded: [Slice] = []
            decoded.reserveCapacity(pixList.count)
            for pix in pixList {
                guard let geometry = MetalViewerSliceGeometry(pix: pix),
                      abs(simd_dot(geometry.normal, referenceNormal)) >= 0.95,
                      let pixels = MetalStoredInt16PixelData(pix: pix) else { continue }
                decoded.append(
                    Slice(
                        pixels: pixels,
                        geometry: geometry,
                        position: simd_dot(geometry.origin, referenceNormal)
                    )
                )
            }
            guard decoded.isEmpty == false else { return nil }
            decoded.sort { $0.position < $1.position }

            var separations: [Double] = []
            if decoded.count > 1 {
                separations.reserveCapacity(decoded.count - 1)
                for index in 1..<decoded.count {
                    let separation = abs(decoded[index].position - decoded[index - 1].position)
                    if separation > 0.000_1 { separations.append(separation) }
                }
            }
            separations.sort()
            let measuredSliceSpacing = separations.isEmpty
                ? max(firstGeometry.spacingBetweenSlices, firstGeometry.sliceThickness, 1)
                : separations[separations.count / 2]

            self.slices = decoded
            self.referenceNormal = referenceNormal
            sliceSpacing = max(measuredSliceSpacing, 0.1)
            minimumVoxelSpacing = max(
                min(firstGeometry.spacingX, firstGeometry.spacingY, measuredSliceSpacing),
                0.1
            )
        }

        func value(at point: SIMD3<Double>) -> Double? {
            let position = simd_dot(point, referenceNormal)
            guard let first = slices.first, let last = slices.last else { return nil }
            let edgeTolerance = max(sliceSpacing * 0.65, 0.75)
            guard position >= first.position - edgeTolerance,
                  position <= last.position + edgeTolerance else { return nil }

            let bracket = bracketingSliceIndices(for: position)
            let lowerSlice = slices[bracket.lower]
            let upperSlice = slices[bracket.upper]
            let lowerValue = value(in: lowerSlice, at: point)
            guard bracket.lower != bracket.upper else { return lowerValue }
            let upperValue = value(in: upperSlice, at: point)
            switch (lowerValue, upperValue) {
            case let (lower?, upper?):
                let denominator = upperSlice.position - lowerSlice.position
                guard abs(denominator) > 0.000_001 else { return lower }
                let fraction = min(max((position - lowerSlice.position) / denominator, 0), 1)
                return lower + (upper - lower) * fraction
            case let (lower?, nil):
                return lower
            case let (nil, upper?):
                return upper
            case (nil, nil):
                return nil
            }
        }

        private func value(in slice: Slice, at point: SIMD3<Double>) -> Double? {
            let slicePoint = slice.geometry.slicePoint(from: point)
            let x = Double(slicePoint.x) - 0.5
            let y = Double(slicePoint.y) - 0.5
            guard x >= 0, y >= 0,
                  x <= Double(slice.pixels.width - 1),
                  y <= Double(slice.pixels.height - 1) else { return nil }

            let x0 = Int(floor(x))
            let y0 = Int(floor(y))
            let x1 = min(x0 + 1, slice.pixels.width - 1)
            let y1 = min(y0 + 1, slice.pixels.height - 1)
            guard let value00 = slice.pixels.rescaledValue(x: x0, y: y0),
                  let value10 = slice.pixels.rescaledValue(x: x1, y: y0),
                  let value01 = slice.pixels.rescaledValue(x: x0, y: y1),
                  let value11 = slice.pixels.rescaledValue(x: x1, y: y1) else { return nil }
            let horizontal = Float(x - Double(x0))
            let vertical = Float(y - Double(y0))
            let top = value00 + (value10 - value00) * horizontal
            let bottom = value01 + (value11 - value01) * horizontal
            return Double(top + (bottom - top) * vertical)
        }

        private func bracketingSliceIndices(for position: Double) -> (lower: Int, upper: Int) {
            guard slices.count > 1 else { return (0, 0) }
            if position <= slices[0].position { return (0, 0) }
            if position >= slices[slices.count - 1].position {
                let lastIndex = slices.count - 1
                return (lastIndex, lastIndex)
            }

            var lower = 0
            var upper = slices.count - 1
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if slices[middle].position < position {
                    lower = middle
                } else {
                    upper = middle
                }
            }
            return (lower, upper)
        }
    }

    private let roi: MetalStudyROI
    private let pixList: [DCMPix]
    private let canonicalToSeriesWorld: simd_float4x4
    private let preservesEstablishedBoundary: Bool

    init(
        roi: MetalStudyROI,
        pixList: [DCMPix],
        canonicalToSeriesWorld: simd_float4x4,
        preservesEstablishedBoundary: Bool
    ) {
        self.roi = roi
        self.pixList = pixList
        self.canonicalToSeriesWorld = canonicalToSeriesWorld
        self.preservesEstablishedBoundary = preservesEstablishedBoundary
    }

    private struct RandomWalkerGrid {
        let dimensions: MetalStudyROIGridDimensions
        let origin: SIMD3<Double>
        let spacing: Double
        let intensities: [Float]
        let valid: [Bool]

        var voxelCount: Int { dimensions.voxelCount }

        func index(x: Int, y: Int, z: Int) -> Int {
            (z * dimensions.y + y) * dimensions.x + x
        }

        func coordinate(for index: Int) -> SIMD3<Int> {
            let plane = dimensions.x * dimensions.y
            let z = index / plane
            let remainder = index - z * plane
            let y = remainder / dimensions.x
            return SIMD3<Int>(remainder - y * dimensions.x, y, z)
        }

        func point(x: Int, y: Int, z: Int) -> SIMD3<Double> {
            origin + SIMD3<Double>(Double(x), Double(y), Double(z)) * spacing
        }

        func nearestIndex(to point: SIMD3<Double>) -> Int? {
            let coordinate = (point - origin) / spacing
            let x = Int(coordinate.x.rounded())
            let y = Int(coordinate.y.rounded())
            let z = Int(coordinate.z.rounded())
            guard x >= 0, y >= 0, z >= 0,
                  x < dimensions.x, y < dimensions.y, z < dimensions.z else { return nil }
            return index(x: x, y: y, z: z)
        }

        func intensity(at point: SIMD3<Double>) -> Double? {
            let coordinate = (point - origin) / spacing
            guard coordinate.x >= 0, coordinate.y >= 0, coordinate.z >= 0,
                  coordinate.x <= Double(dimensions.x - 1),
                  coordinate.y <= Double(dimensions.y - 1),
                  coordinate.z <= Double(dimensions.z - 1) else { return nil }

            let x0 = Int(floor(coordinate.x))
            let y0 = Int(floor(coordinate.y))
            let z0 = Int(floor(coordinate.z))
            let x1 = min(x0 + 1, dimensions.x - 1)
            let y1 = min(y0 + 1, dimensions.y - 1)
            let z1 = min(z0 + 1, dimensions.z - 1)
            let corners = [
                index(x: x0, y: y0, z: z0), index(x: x1, y: y0, z: z0),
                index(x: x0, y: y1, z: z0), index(x: x1, y: y1, z: z0),
                index(x: x0, y: y0, z: z1), index(x: x1, y: y0, z: z1),
                index(x: x0, y: y1, z: z1), index(x: x1, y: y1, z: z1),
            ]
            guard corners.allSatisfy({ valid[$0] }) else { return nil }

            let fx = coordinate.x - Double(x0)
            let fy = coordinate.y - Double(y0)
            let fz = coordinate.z - Double(z0)
            func value(_ x: Int, _ y: Int, _ z: Int) -> Double {
                Double(intensities[index(x: x, y: y, z: z)])
            }
            let c00 = value(x0, y0, z0) * (1 - fx) + value(x1, y0, z0) * fx
            let c10 = value(x0, y1, z0) * (1 - fx) + value(x1, y1, z0) * fx
            let c01 = value(x0, y0, z1) * (1 - fx) + value(x1, y0, z1) * fx
            let c11 = value(x0, y1, z1) * (1 - fx) + value(x1, y1, z1) * fx
            let c0 = c00 * (1 - fy) + c10 * fy
            let c1 = c01 * (1 - fy) + c11 * fy
            return c0 * (1 - fz) + c1 * fz
        }
    }

    private struct RandomWalkerEdges {
        let x: [Float]
        let y: [Float]
        let z: [Float]
    }

    private struct RandomWalkerFieldResult {
        let field: MetalStudyROIVoxelField
        let insideVoxelCount: Int

        var volumeMM3: Double {
            Double(insideVoxelCount)
                * field.spacingMM
                * field.spacingMM
                * field.spacingMM
        }
    }

    private final class PreparedRandomWalkerData: @unchecked Sendable {
        final class ROIState: @unchecked Sendable {
            let lock = NSLock()
            let workspace: MetalStudyROIGPUSolver.Workspace
            var hasWarmSolution = false
            var previewConstraintBase: [Float]?

            init(workspace: MetalStudyROIGPUSolver.Workspace) {
                self.workspace = workspace
            }
        }

        let grid: RandomWalkerGrid
        let gpuEdgeBuffers: MetalStudyROIGPUSolver.EdgeBuffers
        let validVoxelCount: Int
        private let stateLock = NSLock()
        private var roiStates: [UUID: ROIState] = [:]

        init(
            grid: RandomWalkerGrid,
            gpuEdgeBuffers: MetalStudyROIGPUSolver.EdgeBuffers
        ) {
            self.grid = grid
            self.gpuEdgeBuffers = gpuEdgeBuffers
            validVoxelCount = grid.valid.lazy.filter { $0 }.count
        }

        func state(
            for identifier: UUID,
            solver: MetalStudyROIGPUSolver
        ) -> ROIState? {
            stateLock.lock()
            defer { stateLock.unlock() }
            if let state = roiStates[identifier] { return state }
            guard let workspace = solver.makeWorkspace(count: grid.voxelCount) else {
                return nil
            }
            let state = ROIState(workspace: workspace)
            roiStates[identifier] = state
            return state
        }
    }

    private static let preparationCacheLock = NSLock()
    private static var preparationCache: [String: PreparedRandomWalkerData] = [:]
    private static var preparationCacheOrder: [String] = []

    private func preparedRandomWalkerData() -> PreparedRandomWalkerData? {
        let requestedHalfExtent = max(roi.conservativeBoundingRadiusMM + 10, 12)
        // Five-millimetre buckets keep a drag inside the same prepared volume.
        // A new volume is prepared only if the edited ROI approaches its edge.
        let halfExtent = ceil(requestedHalfExtent / 5) * 5
        let key = preparationCacheKey(halfExtent: halfExtent)
        Self.preparationCacheLock.lock()
        if let cached = Self.preparationCache[key] {
            Self.preparationCacheLock.unlock()
            return cached
        }
        Self.preparationCacheLock.unlock()

        guard let volume = IntensityVolume(pixList: pixList) else {
            return fail("No spatially consistent image slices could be decoded for refinement.")
        }
        guard let grid = makeRandomWalkerGrid(volume: volume, halfExtent: halfExtent) else {
            return fail("The cropped refinement region did not contain enough usable image samples.")
        }
        let edges = randomWalkerEdges(grid: grid)
        guard let gpuEdgeBuffers = MetalStudyROIGPUSolver.shared?.makeEdgeBuffers(
            xEdges: edges.x,
            yEdges: edges.y,
            zEdges: edges.z
        ) else {
            return fail("The Metal refinement buffers could not be prepared.")
        }
        let prepared = PreparedRandomWalkerData(
            grid: grid,
            gpuEdgeBuffers: gpuEdgeBuffers
        )
        Self.preparationCacheLock.lock()
        Self.preparationCache[key] = prepared
        Self.preparationCacheOrder.removeAll { $0 == key }
        Self.preparationCacheOrder.append(key)
        while Self.preparationCacheOrder.count > 4 {
            let discardedKey = Self.preparationCacheOrder.removeFirst()
            Self.preparationCache.removeValue(forKey: discardedKey)
        }
        Self.preparationCacheLock.unlock()
        return prepared
    }

    private func preparationCacheKey(halfExtent: Double) -> String {
        let paths = pixList.compactMap(\.srcFile)
        let columns = canonicalToSeriesWorld.columns
        let matrixValues = [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w,
        ].map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        return [
            paths.first ?? "",
            paths.last ?? "",
            String(pixList.count),
            String(format: "%.2f,%.2f,%.2f", roi.center.x, roi.center.y, roi.center.z),
            String(format: "%.1f", halfExtent),
            matrixValues,
        ].joined(separator: "|")
    }

    private func randomWalkerField(
        prepared: PreparedRandomWalkerData,
        sweepCount: Int,
        preview: Bool,
        reusePreparedConstraints: Bool
    ) -> RandomWalkerFieldResult? {
        let grid = prepared.grid
        guard let solver = MetalStudyROIGPUSolver.shared,
              let state = prepared.state(for: roi.id, solver: solver) else {
            return fail("The Metal refinement workspace could not be prepared.")
        }
        state.lock.lock()
        defer { state.lock.unlock() }

        let constraintBase: [Float]
        if (preview || reusePreparedConstraints),
           let cached = state.previewConstraintBase {
            constraintBase = cached
        } else {
            constraintBase = randomWalkerConstraintBase(grid: grid)
            state.previewConstraintBase = constraintBase
        }
        var fixedValues = constraintBase
        let preservesEstablishedBoundary = self.preservesEstablishedBoundary
            || state.hasWarmSolution
            || roi.manualAnchorCount > 0
        applyAnchorRandomWalkerConstraints(
            grid: grid,
            preservesEstablishedBoundary: preservesEstablishedBoundary,
            to: &fixedValues
        )
        guard fixedValues.contains(where: { $0 >= 0.99 }),
              fixedValues.contains(where: { $0 == 0 }) else {
            return fail("The ROI did not provide both interior and exterior refinement constraints.")
        }

        // The hard landmark patch carries the edited boundary into the solve.
        // Preserve the prior field everywhere else so an explicit refinement
        // cannot jump wholesale to a stronger parallel tissue edge.
        let reusesWarmSolution = state.hasWarmSolution
        let initial = reusesWarmSolution ? nil : initialProbabilities(grid: grid)
        guard solveRandomWalker(
            grid: grid,
            edgeBuffers: prepared.gpuEdgeBuffers,
            workspace: state.workspace,
            fixedValues: &fixedValues,
            initial: initial,
            reuseProbability: reusesWarmSolution,
            priorWeight: preservesEstablishedBoundary ? 0.5 : 0.000_01,
            sweepCount: sweepCount
        ) else {
            return fail("The Metal probability solver did not complete successfully.")
        }
        state.hasWarmSolution = true

        var (bytes, insideCount) = solver.quantizedProbabilities(in: state.workspace)
        if preview == false {
            retainCenterConnectedForeground(in: &bytes, grid: grid)
            insideCount = bytes.lazy.filter { $0 >= 128 }.count
        }
        guard insideCount >= 8,
              insideCount < max(Int(Double(prepared.validVoxelCount) * 0.9), 9) else {
            return fail("The solved foreground was empty or occupied nearly the entire usable crop.")
        }
        return RandomWalkerFieldResult(
            field: MetalStudyROIVoxelField(
                dimensions: grid.dimensions,
                origin: MetalStudyROIPoint(grid.origin),
                spacingMM: grid.spacing,
                probabilities: Data(bytes)
            ),
            insideVoxelCount: insideCount
        )
    }

    private func retainCenterConnectedForeground(
        in probabilities: inout [UInt8],
        grid: RandomWalkerGrid
    ) {
        guard probabilities.count == grid.voxelCount else { return }
        var seed = grid.nearestIndex(to: roi.center.vector)
        if let candidate = seed, probabilities[candidate] < 128 {
            seed = nil
        }
        if seed == nil {
            var nearestDistanceSquared = Double.greatestFiniteMagnitude
            for index in probabilities.indices where probabilities[index] >= 128 {
                let coordinate = grid.coordinate(for: index)
                let point = grid.point(x: coordinate.x, y: coordinate.y, z: coordinate.z)
                let distanceSquared = simd_length_squared(point - roi.center.vector)
                if distanceSquared < nearestDistanceSquared {
                    nearestDistanceSquared = distanceSquared
                    seed = index
                }
            }
        }
        guard let seed else { return }

        var connected = Array(repeating: false, count: probabilities.count)
        var queue = [seed]
        connected[seed] = true
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let coordinate = grid.coordinate(for: index)
            for deltaZ in -1...1 {
                let z = coordinate.z + deltaZ
                guard z >= 0, z < grid.dimensions.z else { continue }
                for deltaY in -1...1 {
                    let y = coordinate.y + deltaY
                    guard y >= 0, y < grid.dimensions.y else { continue }
                    for deltaX in -1...1 {
                        guard deltaX != 0 || deltaY != 0 || deltaZ != 0 else { continue }
                        let x = coordinate.x + deltaX
                        guard x >= 0, x < grid.dimensions.x else { continue }
                        let neighbor = grid.index(x: x, y: y, z: z)
                        guard connected[neighbor] == false,
                              probabilities[neighbor] >= 128 else { continue }
                        connected[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
        }
        for index in probabilities.indices where probabilities[index] >= 128 && connected[index] == false {
            probabilities[index] = 0
        }
    }

    private func makeRandomWalkerGrid(
        volume: IntensityVolume,
        halfExtent: Double
    ) -> RandomWalkerGrid? {
        var spacing = min(max(volume.minimumVoxelSpacing, 0.55), 1.0)

        func gridDimension(for candidateSpacing: Double) -> Int {
            let halfVoxelCount = Int(ceil(halfExtent / candidateSpacing))
            return max(halfVoxelCount * 2 + 1, 5)
        }

        var dimension = gridDimension(for: spacing)
        let maximumVoxelCount = 420_000.0
        let initialVoxelCount = pow(Double(dimension), 3)
        if initialVoxelCount > maximumVoxelCount {
            spacing *= pow(initialVoxelCount / maximumVoxelCount, 1.0 / 3.0)
            dimension = gridDimension(for: spacing)
        }
        let dimensions = MetalStudyROIGridDimensions(
            x: dimension,
            y: dimension,
            z: dimension
        )
        let origin = roi.center.vector - SIMD3<Double>(repeating: Double(dimension - 1) * spacing * 0.5)
        var rawIntensities = Array(repeating: Float(0), count: dimensions.voxelCount)
        var valid = Array(repeating: false, count: dimensions.voxelCount)
        var validValues: [Float] = []
        validValues.reserveCapacity(dimensions.voxelCount)

        for z in 0..<dimension {
            for y in 0..<dimension {
                for x in 0..<dimension {
                    let index = (z * dimension + y) * dimension + x
                    let point = origin + SIMD3<Double>(Double(x), Double(y), Double(z)) * spacing
                    guard let value = sample(canonicalPoint: point, volume: volume),
                          value.isFinite else { continue }
                    let floatValue = Float(value)
                    rawIntensities[index] = floatValue
                    valid[index] = true
                    validValues.append(floatValue)
                }
            }
        }
        // Thin acquired slabs legitimately occupy much less than ten percent of
        // a cubic canonical crop. Absolute usable data and seed validation below
        // are the meaningful requirements; crop occupancy is not.
        guard validValues.count >= 64 else { return nil }
        validValues.sort()
        let lower = validValues[Int(Double(validValues.count - 1) * 0.02)]
        let upper = validValues[Int(Double(validValues.count - 1) * 0.98)]
        let range = max(upper - lower, 0.000_001)
        for index in rawIntensities.indices where valid[index] {
            rawIntensities[index] = min(max((rawIntensities[index] - lower) / range, 0), 1)
        }
        return RandomWalkerGrid(
            dimensions: dimensions,
            origin: origin,
            spacing: spacing,
            intensities: rawIntensities,
            valid: valid
        )
    }

    private func initialProbabilities(grid: RandomWalkerGrid) -> [Float] {
        var result = Array(repeating: Float(0), count: grid.voxelCount)
        for index in result.indices where grid.valid[index] {
            let coordinate = grid.coordinate(for: index)
            let point = grid.point(x: coordinate.x, y: coordinate.y, z: coordinate.z)
            let signedValue = roi.implicitValue(at: point)
            if roi.voxelField != nil {
                result[index] = Float(min(max(0.5 - signedValue, 0), 1))
            } else {
                result[index] = signedValue <= 0 ? 1 : 0
            }
        }
        return result
    }

    private func randomWalkerConstraintBase(
        grid: RandomWalkerGrid
    ) -> [Float] {
        var fixed = Array(repeating: Float.nan, count: grid.voxelCount)
        let dimensions = grid.dimensions
        var inside = Array(repeating: false, count: grid.voxelCount)
        for z in 0..<dimensions.z {
            for y in 0..<dimensions.y {
                for x in 0..<dimensions.x {
                    let index = grid.index(x: x, y: y, z: z)
                    guard grid.valid[index] else { continue }
                    inside[index] = roi.implicitValue(
                        at: grid.point(x: x, y: y, z: z)
                    ) <= 0
                }
            }
        }

        func neighborIndices(x: Int, y: Int, z: Int) -> [Int] {
            var result: [Int] = []
            result.reserveCapacity(6)
            if x > 0 { result.append(grid.index(x: x - 1, y: y, z: z)) }
            if x + 1 < dimensions.x { result.append(grid.index(x: x + 1, y: y, z: z)) }
            if y > 0 { result.append(grid.index(x: x, y: y - 1, z: z)) }
            if y + 1 < dimensions.y { result.append(grid.index(x: x, y: y + 1, z: z)) }
            if z > 0 { result.append(grid.index(x: x, y: y, z: z - 1)) }
            if z + 1 < dimensions.z { result.append(grid.index(x: x, y: y, z: z + 1)) }
            return result
        }

        // A topology-independent distance transform supplies a stable interior
        // core and distant exterior shell. The previous centre/radius test could
        // only describe star-shaped objects and abandoned curved vessel limbs.
        var boundaryDistance = Array(repeating: Int.max, count: grid.voxelCount)
        var queue: [Int] = []
        queue.reserveCapacity(grid.voxelCount / 8)
        for z in 0..<dimensions.z {
            for y in 0..<dimensions.y {
                for x in 0..<dimensions.x {
                    let index = grid.index(x: x, y: y, z: z)
                    guard grid.valid[index] else { continue }
                    let neighbors = neighborIndices(x: x, y: y, z: z)
                    let isBoundary = neighbors.contains { neighbor in
                        (grid.valid[neighbor] && inside[neighbor] != inside[index])
                            || (inside[index] && grid.valid[neighbor] == false)
                    }
                    if isBoundary {
                        boundaryDistance[index] = 0
                        queue.append(index)
                    }
                }
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let coordinate = grid.coordinate(for: index)
            let nextDistance = boundaryDistance[index] + 1
            for neighbor in neighborIndices(
                x: coordinate.x,
                y: coordinate.y,
                z: coordinate.z
            ) where grid.valid[neighbor]
                && inside[neighbor] == inside[index]
                && nextDistance < boundaryDistance[neighbor] {
                boundaryDistance[neighbor] = nextDistance
                queue.append(neighbor)
            }
        }

        let interiorSeedDepth = max(min(roi.radiusMM * 0.25, 2.0), grid.spacing * 1.25)
        let interiorSteps = max(Int(ceil(interiorSeedDepth / grid.spacing)), 1)
        let exteriorSteps = max(Int(ceil(10.0 / grid.spacing)), 1)
        var deepestInsideIndex: Int?
        for index in fixed.indices {
            guard grid.valid[index] else {
                fixed[index] = 0
                continue
            }
            let coordinate = grid.coordinate(for: index)
            if coordinate.x == 0 || coordinate.y == 0 || coordinate.z == 0
                || coordinate.x == dimensions.x - 1
                || coordinate.y == dimensions.y - 1
                || coordinate.z == dimensions.z - 1 {
                fixed[index] = 0
            } else if inside[index], boundaryDistance[index] >= interiorSteps {
                fixed[index] = 1
            } else if inside[index] == false, boundaryDistance[index] >= exteriorSteps {
                fixed[index] = 0
            }
            if inside[index], let current = deepestInsideIndex {
                if boundaryDistance[index] > boundaryDistance[current] {
                    deepestInsideIndex = index
                }
            } else if inside[index] {
                deepestInsideIndex = index
            }
        }
        if fixed.contains(where: { $0 >= 0.99 }) == false,
           let deepestInsideIndex {
            fixed[deepestInsideIndex] = 1
        }

        return fixed
    }

    private func applyAnchorRandomWalkerConstraints(
        grid: RandomWalkerGrid,
        preservesEstablishedBoundary: Bool,
        to fixed: inout [Float]
    ) {
        let pairedSeedDistance = max(grid.spacing * 1.75, 1.0)
        let manualOverrideRegions: [(point: SIMD3<Double>, radius: Double)] = roi.anchors.indices.compactMap { index in
            guard roi.anchorKind(at: index) == .manual else { return nil }
            let point = roi.anchors[index].vector
            let displacement = roi.anchorBaselinePoints.indices.contains(index)
                ? simd_distance(roi.anchorBaselinePoints[index].vector, point)
                : 0
            return (
                point,
                min(max(grid.spacing * 8, displacement * 2 + 4, 6), 10)
            )
        }
        for index in roi.anchors.indices {
            let boundaryPoint = roi.anchors[index].vector
            let isManual = roi.anchorKind(at: index) == .manual
            if isManual == false,
               manualOverrideRegions.contains(where: {
                   simd_distance($0.point, boundaryPoint) <= $0.radius
               }) {
                // A user landmark identifies which of several nearby image
                // transitions is the intended boundary. Do not let the old
                // automatic scaffold keep its previous interface pinned in the
                // region that landmark is meant to correct.
                continue
            }
            let radialOffset = boundaryPoint - roi.center.vector
            guard simd_length_squared(radialOffset) > 0.000_001 else { continue }
            let radial = simd_normalize(radialOffset)
            let surfaceFallback = roi.anchorSurfaceNormal(at: index) ?? radial
            let normal = isManual
                ? surfaceFallback
                : imageBoundaryNormal(
                    at: boundaryPoint,
                    radialFallback: surfaceFallback,
                    grid: grid
                )
            // Automatic scaffold points are allowed to move, but an inside/outside
            // pair prevents the solver from abandoning the imported SEG surface.
            let guardDistance = isManual
                ? pairedSeedDistance
                : max(grid.spacing * 2.5, 2.0)
            if isManual {
                applyManualBoundaryPatch(
                    anchorIndex: index,
                    boundaryPoint: boundaryPoint,
                    outwardNormal: normal,
                    guardDistance: guardDistance,
                    grid: grid,
                    values: &fixed
                )
            } else {
                applyBoundaryConstraintPair(
                    at: boundaryPoint,
                    outwardNormal: normal,
                    guardDistance: guardDistance,
                    includesBoundarySeed: preservesEstablishedBoundary,
                    grid: grid,
                    values: &fixed
                )
            }
        }
    }

    private func applyManualBoundaryPatch(
        anchorIndex: Int,
        boundaryPoint: SIMD3<Double>,
        outwardNormal: SIMD3<Double>,
        guardDistance: Double,
        grid: RandomWalkerGrid,
        values: inout [Float]
    ) {
        let referenceAxis = abs(outwardNormal.z) < 0.8
            ? SIMD3<Double>(0, 0, 1)
            : SIMD3<Double>(0, 1, 0)
        let firstTangent = simd_normalize(simd_cross(outwardNormal, referenceAxis))
        let secondTangent = simd_normalize(simd_cross(outwardNormal, firstTangent))
        let displacement = roi.anchorBaselinePoints.indices.contains(anchorIndex)
            ? simd_distance(
                roi.anchorBaselinePoints[anchorIndex].vector,
                boundaryPoint
              )
            : 0
        let supportRadius = min(
            max(grid.spacing * 2.5, displacement * 1.25, 1.5),
            3.0
        )
        let diagonalRadius = supportRadius / sqrt(2)
        let offsets: [SIMD3<Double>] = [
            .zero,
            firstTangent * supportRadius,
            -firstTangent * supportRadius,
            secondTangent * supportRadius,
            -secondTangent * supportRadius,
            (firstTangent + secondTangent) * diagonalRadius,
            (firstTangent - secondTangent) * diagonalRadius,
            (-firstTangent + secondTangent) * diagonalRadius,
            (-firstTangent - secondTangent) * diagonalRadius,
        ]
        let probeDistance = max(grid.spacing * 0.75, 0.35)
        let referenceTransition = signedImageTransition(
            at: boundaryPoint,
            outwardNormal: outwardNormal,
            probeDistance: probeDistance,
            grid: grid
        )
        for offset in offsets {
            let proposedPoint = boundaryPoint + offset
            let constrainedPoint = simd_length_squared(offset) < 0.000_001
                ? boundaryPoint
                : edgeLockedBoundaryPoint(
                    near: proposedPoint,
                    outwardNormal: outwardNormal,
                    referenceTransition: referenceTransition,
                    probeDistance: probeDistance,
                    searchDistance: min(max(grid.spacing * 2.5, 1.25), 2.0),
                    grid: grid
                )
            applyBoundaryConstraintPair(
                at: constrainedPoint,
                outwardNormal: outwardNormal,
                guardDistance: guardDistance,
                includesBoundarySeed: true,
                grid: grid,
                values: &values
            )
        }
    }

    private func signedImageTransition(
        at point: SIMD3<Double>,
        outwardNormal: SIMD3<Double>,
        probeDistance: Double,
        grid: RandomWalkerGrid
    ) -> Double? {
        guard let inside = grid.intensity(at: point - outwardNormal * probeDistance),
              let outside = grid.intensity(at: point + outwardNormal * probeDistance) else {
            return nil
        }
        return outside - inside
    }

    private func edgeLockedBoundaryPoint(
        near proposedPoint: SIMD3<Double>,
        outwardNormal: SIMD3<Double>,
        referenceTransition: Double?,
        probeDistance: Double,
        searchDistance: Double,
        grid: RandomWalkerGrid
    ) -> SIMD3<Double> {
        guard let referenceTransition,
              abs(referenceTransition) >= 0.005 else { return proposedPoint }
        let expectedSign = referenceTransition.sign == .minus ? -1.0 : 1.0
        let step = max(grid.spacing * 0.25, 0.1)
        let sampleCount = max(Int(ceil(searchDistance / step)), 1)
        var bestPoint = proposedPoint
        var bestScore = -Double.greatestFiniteMagnitude
        for sample in -sampleCount...sampleCount {
            let offset = Double(sample) * step
            guard abs(offset) <= searchDistance else { continue }
            let candidate = proposedPoint + outwardNormal * offset
            guard let transition = signedImageTransition(
                at: candidate,
                outwardNormal: outwardNormal,
                probeDistance: probeDistance,
                grid: grid
            ), transition * expectedSign > 0 else { continue }
            // Prefer the matching transition with the clearest edge, while a
            // modest distance cost keeps the patch on the interface indicated
            // by the landmark rather than another same-polarity edge nearby.
            let distanceCost = abs(offset) / max(searchDistance, 0.001) * abs(referenceTransition) * 0.2
            let score = abs(transition) - distanceCost
            if score > bestScore {
                bestScore = score
                bestPoint = candidate
            }
        }
        return bestPoint
    }

    private func applyBoundaryConstraintPair(
        at boundaryPoint: SIMD3<Double>,
        outwardNormal: SIMD3<Double>,
        guardDistance: Double,
        includesBoundarySeed: Bool,
        grid: RandomWalkerGrid,
        values: inout [Float]
    ) {
        setConstraint(
            1,
            near: boundaryPoint - outwardNormal * guardDistance,
            radius: grid.spacing * 0.65,
            grid: grid,
            values: &values
        )
        setConstraint(
            0,
            near: boundaryPoint + outwardNormal * guardDistance,
            radius: grid.spacing * 0.65,
            grid: grid,
            values: &values
        )
        if includesBoundarySeed {
            setConstraint(
                0.5,
                near: boundaryPoint,
                radius: grid.spacing * 0.35,
                grid: grid,
                values: &values
            )
        }
    }

    private func setConstraint(
        _ value: Float,
        near point: SIMD3<Double>,
        radius: Double,
        grid: RandomWalkerGrid,
        values: inout [Float]
    ) {
        guard let centerIndex = grid.nearestIndex(to: point) else { return }
        let centerCoordinate = grid.coordinate(for: centerIndex)
        let voxelRadius = max(Int(ceil(radius / grid.spacing)), 0)
        for z in max(centerCoordinate.z - voxelRadius, 0)...min(centerCoordinate.z + voxelRadius, grid.dimensions.z - 1) {
            for y in max(centerCoordinate.y - voxelRadius, 0)...min(centerCoordinate.y + voxelRadius, grid.dimensions.y - 1) {
                for x in max(centerCoordinate.x - voxelRadius, 0)...min(centerCoordinate.x + voxelRadius, grid.dimensions.x - 1) {
                    let index = grid.index(x: x, y: y, z: z)
                    guard grid.valid[index] else { continue }
                    let candidate = grid.point(x: x, y: y, z: z)
                    if simd_distance(candidate, point) <= max(radius, grid.spacing * 0.51) {
                        values[index] = value
                    }
                }
            }
        }
    }

    private func imageBoundaryNormal(
        at point: SIMD3<Double>,
        radialFallback: SIMD3<Double>,
        grid: RandomWalkerGrid
    ) -> SIMD3<Double> {
        guard let index = grid.nearestIndex(to: point) else { return radialFallback }
        let coordinate = grid.coordinate(for: index)
        guard coordinate.x > 0, coordinate.y > 0, coordinate.z > 0,
              coordinate.x + 1 < grid.dimensions.x,
              coordinate.y + 1 < grid.dimensions.y,
              coordinate.z + 1 < grid.dimensions.z else { return radialFallback }
        let plane = grid.dimensions.x * grid.dimensions.y
        let neighborIndices = [
            index - 1, index + 1,
            index - grid.dimensions.x, index + grid.dimensions.x,
            index - plane, index + plane,
        ]
        guard neighborIndices.allSatisfy({ grid.valid[$0] }) else { return radialFallback }
        let gradient = SIMD3<Double>(
            Double(grid.intensities[index + 1] - grid.intensities[index - 1]),
            Double(grid.intensities[index + grid.dimensions.x] - grid.intensities[index - grid.dimensions.x]),
            Double(grid.intensities[index + plane] - grid.intensities[index - plane])
        )
        guard simd_length_squared(gradient) > 0.000_001 else { return radialFallback }
        var normal = simd_normalize(gradient)
        if simd_dot(normal, radialFallback) < 0 { normal = -normal }
        return normal
    }

    private func randomWalkerEdges(grid: RandomWalkerGrid) -> RandomWalkerEdges {
        var differences: [Float] = []
        differences.reserveCapacity(min(grid.voxelCount * 3, 100_000))
        let sampleStride = max(grid.voxelCount / 30_000, 1)
        for index in stride(from: 0, to: grid.voxelCount, by: sampleStride) where grid.valid[index] {
            let coordinate = grid.coordinate(for: index)
            if coordinate.x + 1 < grid.dimensions.x {
                let neighbor = index + 1
                if grid.valid[neighbor] { differences.append(abs(grid.intensities[index] - grid.intensities[neighbor])) }
            }
            if coordinate.y + 1 < grid.dimensions.y {
                let neighbor = index + grid.dimensions.x
                if grid.valid[neighbor] { differences.append(abs(grid.intensities[index] - grid.intensities[neighbor])) }
            }
            if coordinate.z + 1 < grid.dimensions.z {
                let neighbor = index + grid.dimensions.x * grid.dimensions.y
                if grid.valid[neighbor] { differences.append(abs(grid.intensities[index] - grid.intensities[neighbor])) }
            }
        }
        differences.sort()
        let localContrast = differences.isEmpty
            ? Float(0.05)
            : differences[Int(Double(differences.count - 1) * 0.75)]
        let sigma = max(localContrast * 1.5, 0.025)
        let beta = 1 / (2 * sigma * sigma)

        func edgeWeight(_ first: Int, _ second: Int) -> Float {
            guard grid.valid[first], grid.valid[second] else { return 0 }
            let difference = grid.intensities[first] - grid.intensities[second]
            return 0.000_5 + exp(-beta * difference * difference)
        }

        var xEdges = Array(repeating: Float(0), count: grid.voxelCount)
        var yEdges = Array(repeating: Float(0), count: grid.voxelCount)
        var zEdges = Array(repeating: Float(0), count: grid.voxelCount)
        for z in 0..<grid.dimensions.z {
            for y in 0..<grid.dimensions.y {
                for x in 0..<grid.dimensions.x {
                    let index = grid.index(x: x, y: y, z: z)
                    if x + 1 < grid.dimensions.x { xEdges[index] = edgeWeight(index, index + 1) }
                    if y + 1 < grid.dimensions.y { yEdges[index] = edgeWeight(index, index + grid.dimensions.x) }
                    if z + 1 < grid.dimensions.z { zEdges[index] = edgeWeight(index, index + grid.dimensions.x * grid.dimensions.y) }
                }
            }
        }
        return RandomWalkerEdges(x: xEdges, y: yEdges, z: zEdges)
    }

    private func solveRandomWalker(
        grid: RandomWalkerGrid,
        edgeBuffers: MetalStudyROIGPUSolver.EdgeBuffers,
        workspace: MetalStudyROIGPUSolver.Workspace,
        fixedValues: inout [Float],
        initial: [Float]?,
        reuseProbability: Bool,
        priorWeight: Float,
        sweepCount: Int
    ) -> Bool {
        MetalStudyROIGPUSolver.shared?.solve(
            dimensions: grid.dimensions,
            fixedValues: fixedValues,
            initialValues: initial,
            reuseProbability: reuseProbability,
            priorWeight: priorWeight,
            edgeBuffers: edgeBuffers,
            workspace: workspace,
            sweepCount: sweepCount
        ) ?? false
    }

    private func sample(
        canonicalPoint: SIMD3<Double>,
        volume: IntensityVolume
    ) -> Double? {
        let transformed = canonicalToSeriesWorld * SIMD4<Float>(
            Float(canonicalPoint.x),
            Float(canonicalPoint.y),
            Float(canonicalPoint.z),
            1
        )
        guard abs(transformed.w) > 0.000_001 else { return nil }
        return volume.value(
            at: SIMD3<Double>(
                Double(transformed.x / transformed.w),
                Double(transformed.y / transformed.w),
                Double(transformed.z / transformed.w)
            )
        )
    }

    func run(
        preview: Bool = false,
        reusePreparedConstraints: Bool = false
    ) -> MetalStudyROIRefinementResult? {
        failureDetail = nil
        guard let prepared = preparedRandomWalkerData(),
              let fieldResult = randomWalkerField(
                prepared: prepared,
                sweepCount: preview ? 28 : 160,
                preview: preview,
                reusePreparedConstraints: reusePreparedConstraints
              ) else {
            if failureDetail == nil {
                failureDetail = "The refinement preparation or probability solve could not be completed."
            }
            return nil
        }
        let field = fieldResult.field
        if preview == false {
            let volumeRatio = fieldResult.volumeMM3 / max(roi.volumeMM3, 0.001)
            guard (0.55...1.8).contains(volumeRatio) else {
                return fail(String(
                    format: "The result was rejected because its volume was %.0f%% of the starting ROI.",
                    volumeRatio * 100
                ))
            }
        }
        let manualBoundaryProbabilities = roi.anchors.indices.compactMap { index -> Double? in
            guard roi.anchorKind(at: index) == .manual else { return nil }
            return field.probability(at: roi.anchors[index].vector)
        }
        guard manualBoundaryProbabilities.count == roi.manualAnchorCount,
              manualBoundaryProbabilities.allSatisfy({ (0.1...0.9).contains($0) }) else {
            return fail("The result was rejected because it did not preserve every manual boundary landmark.")
        }
        if preview {
            // A live drag only needs the new probability field. Keep the current
            // sparse visual handles and defer connectivity cleanup, volume
            // measurement, boundary sampling, and displacement statistics to the
            // definitive solve performed when the mouse is released.
            let currentAutomaticAnchors = roi.anchors.indices.compactMap { index -> SIMD3<Double>? in
                roi.anchorKind(at: index) == .automatic
                    ? roi.anchors[index].vector
                    : nil
            }
            return MetalStudyROIRefinementResult(
                roiIdentifier: roi.id,
                automaticAnchors: currentAutomaticAnchors,
                voxelField: field,
                volumeMM3: roi.volumeMM3,
                meanDisplacementMM: 0,
                maximumDisplacementMM: 0
            )
        }
        // Sample the complete solved isosurface. This remains stable for curved
        // vessels and concave structures that cannot be observed from one centre.
        let anchors = stableAutomaticBoundaryAnchors(for: field, targetCount: 96)
        guard anchors.count >= 24 else {
            return fail("The solved ROI did not provide a usable closed boundary.")
        }
        return MetalStudyROIRefinementResult(
            roiIdentifier: roi.id,
            automaticAnchors: anchors,
            voxelField: field,
            volumeMM3: fieldResult.volumeMM3,
            meanDisplacementMM: 0,
            maximumDisplacementMM: 0
        )
    }

    private func stableAutomaticBoundaryAnchors(
        for field: MetalStudyROIVoxelField,
        targetCount: Int
    ) -> [SIMD3<Double>] {
        guard targetCount > 0 else { return [] }
        let preserved = roi.anchors.indices.compactMap { index -> SIMD3<Double>? in
            guard roi.anchorKind(at: index) == .automatic else { return nil }
            let point = roi.anchors[index].vector
            guard let probability = field.probability(at: point),
                  (0.47...0.53).contains(probability) else { return nil }
            return point
        }
        var result = Array(preserved.prefix(targetCount))
        let minimumSeparation = max(field.spacingMM * 0.75, 0.3)
        if result.count < targetCount {
            let candidates = field.uniformlySampledBoundaryPoints(targetCount: targetCount * 2)
            for point in candidates where result.count < targetCount {
                guard result.allSatisfy({ simd_distance($0, point) >= minimumSeparation }) else {
                    continue
                }
                result.append(point)
            }
        }
        return result
    }

}

struct MetalStudyROIContourSegment {
    let start: CGPoint
    let end: CGPoint
}

enum MetalStudyROIContourBuilder {
    static func segments(
        for roi: MetalStudyROI,
        slice: MetalMPRROISliceGeometry,
        maximumGridDimension: Int = 192
    ) -> [MetalStudyROIContourSegment] {
        guard slice.imageRect.width > 1, slice.imageRect.height > 1 else { return [] }
        let aspect = slice.imageRect.width / max(slice.imageRect.height, 1)
        let columns = max(24, aspect >= 1 ? maximumGridDimension : Int(CGFloat(maximumGridDimension) * aspect))
        let rows = max(24, aspect >= 1 ? Int(CGFloat(maximumGridDimension) / aspect) : maximumGridDimension)
        let columnCount = columns + 1
        var values = Array(repeating: 0.0, count: columnCount * (rows + 1))
        for row in 0...rows {
            let vertical = Double(row) / Double(rows)
            for column in 0...columns {
                let horizontal = Double(column) / Double(columns)
                values[row * columnCount + column] = roi.implicitValue(
                    at: slice.worldPoint(horizontal: horizontal, vertical: vertical)
                )
            }
        }

        func screenPoint(column: Double, row: Double) -> CGPoint {
            CGPoint(
                x: slice.imageRect.minX + CGFloat(column / Double(columns)) * slice.imageRect.width,
                y: slice.imageRect.minY + CGFloat(row / Double(rows)) * slice.imageRect.height
            )
        }

        func interpolatedPoint(_ first: (Double, Double, Double), _ second: (Double, Double, Double)) -> CGPoint {
            let denominator = first.2 - second.2
            let fraction = abs(denominator) > 1e-12 ? first.2 / denominator : 0.5
            return screenPoint(
                column: first.0 + (second.0 - first.0) * fraction,
                row: first.1 + (second.1 - first.1) * fraction
            )
        }

        var result: [MetalStudyROIContourSegment] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = (Double(column), Double(row), values[row * columnCount + column])
                let topRight = (Double(column + 1), Double(row), values[row * columnCount + column + 1])
                let bottomRight = (Double(column + 1), Double(row + 1), values[(row + 1) * columnCount + column + 1])
                let bottomLeft = (Double(column), Double(row + 1), values[(row + 1) * columnCount + column])
                var crossings: [CGPoint] = []
                if (topLeft.2 <= 0) != (topRight.2 <= 0) { crossings.append(interpolatedPoint(topLeft, topRight)) }
                if (topRight.2 <= 0) != (bottomRight.2 <= 0) { crossings.append(interpolatedPoint(topRight, bottomRight)) }
                if (bottomRight.2 <= 0) != (bottomLeft.2 <= 0) { crossings.append(interpolatedPoint(bottomRight, bottomLeft)) }
                if (bottomLeft.2 <= 0) != (topLeft.2 <= 0) { crossings.append(interpolatedPoint(bottomLeft, topLeft)) }
                if crossings.count == 2 {
                    result.append(MetalStudyROIContourSegment(start: crossings[0], end: crossings[1]))
                } else if crossings.count == 4 {
                    let centerValue = (topLeft.2 + topRight.2 + bottomRight.2 + bottomLeft.2) * 0.25
                    let pairs = centerValue <= 0 ? [(0, 3), (1, 2)] : [(0, 1), (2, 3)]
                    for pair in pairs {
                        result.append(MetalStudyROIContourSegment(start: crossings[pair.0], end: crossings[pair.1]))
                    }
                }
            }
        }
        return result
    }
}

private struct MetalStudyROIAuthoringEnvelope: Codable {
    static let schema = "org.horosproject.metal-study-roi.v1"

    let schema: String
    let roi: MetalStudyROI

    init(roi: MetalStudyROI) {
        schema = Self.schema
        self.roi = roi
    }
}

final class MetalStudyROIPersistence: @unchecked Sendable {
    private struct RestoredState {
        let rois: [MetalStudyROI]
        let paths: [UUID: String]
        let payloads: [UUID: String]
    }

    private struct PersistJob: @unchecked Sendable {
        let roi: MetalStudyROI
        let pixList: [DCMPix]
        let sourcePaths: [String]
        let sourceFrameNumbers: [Int]
        let existingPath: String?
        let authoringJSON: String
    }

    private(set) var restoredROIs: [MetalStudyROI]
    var errorHandler: ((String) -> Void)?
    private var study: MetalViewerStudy
    private let queue = DispatchQueue(label: "org.horosproject.horos.metal-roi-dicom-seg", qos: .utility)
    private var pathsByROIIdentifier: [UUID: String]
    private var persistedAuthoringJSONByROIIdentifier: [UUID: String]
    private var generation = 0
    private let generationLock = NSLock()

    private final class MaskAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data]

        init(count: Int) {
            storage = Array(repeating: Data(), count: count)
        }

        func set(_ data: Data, at index: Int) {
            lock.lock()
            storage[index] = data
            lock.unlock()
        }

        func values() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    init(study: MetalViewerStudy) {
        self.study = study
        let restoredState = Self.restoredState(from: study)
        restoredROIs = restoredState.rois
        pathsByROIIdentifier = restoredState.paths
        persistedAuthoringJSONByROIIdentifier = restoredState.payloads
    }

    func updateStudy(_ study: MetalViewerStudy) -> [MetalStudyROI] {
        self.study = study
        let restoredState = Self.restoredState(from: study)
        restoredROIs = restoredState.rois
        pathsByROIIdentifier.merge(restoredState.paths) { _, refreshed in refreshed }
        persistedAuthoringJSONByROIIdentifier.merge(restoredState.payloads) { _, refreshed in refreshed }
        return restoredROIs
    }

    private static func restoredState(from study: MetalViewerStudy) -> RestoredState {
        var restored: [MetalStudyROI] = []
        var paths: [UUID: String] = [:]
        var payloads: [UUID: String] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for series in study.series {
            guard let path = series.firstSourcePath(),
                  let reader = try? SwiftDICOMReader.cached(contentsOfFile: path) else { continue }
            let isSegmentation = series.modality.caseInsensitiveCompare("SEG") == .orderedSame
                || reader.stringValue(forTag: "0008,0016") == "1.2.840.10008.5.1.4.1.1.66.4"
            guard isSegmentation else { continue }

            if let json = reader.stringValue(forTag: "7777,1001"),
               let data = Data(base64Encoded: json),
               let envelope = try? decoder.decode(MetalStudyROIAuthoringEnvelope.self, from: data),
               envelope.schema == MetalStudyROIAuthoringEnvelope.schema {
                restored.removeAll { $0.id == envelope.roi.id }
                restored.append(envelope.roi)
                paths[envelope.roi.id] = path
                payloads[envelope.roi.id] = json
                continue
            }

            // A standard SEG is useful even without Horos' optional private
            // authoring state. Reconstruct its masks into the same canonical
            // voxel field used by the manual Metal ROI tools.
            guard let segmentation = try? reader.segmentation() else { continue }
            let decodedROIs = externalROIs(
                from: segmentation,
                sourcePath: path,
                study: study
            )
            for roi in decodedROIs {
                restored.removeAll { $0.id == roi.id }
                restored.append(roi)
                paths[roi.id] = path
                if let json = encodedAuthoringJSON(for: roi) {
                    // Treat the imported state as already persisted. It is only
                    // rewritten if the user actually edits it.
                    payloads[roi.id] = json
                }
            }
        }
        return RestoredState(
            rois: restored.sorted { $0.modifiedAt > $1.modifiedAt },
            paths: paths,
            payloads: payloads
        )
    }

    private static func externalROIs(
        from segmentation: SwiftDICOMSegmentation,
        sourcePath: String,
        study: MetalViewerStudy
    ) -> [MetalStudyROI] {
        let sourceSeries = bestSourceSeries(for: segmentation, in: study)
        let sourceSeriesIdentifier = sourceSeries?.identifier
            ?? study.series.first(where: { $0.isDICOMSegmentation == false })?.identifier
            ?? study.initialSeriesIdentifier
        let studyInstanceUID = sourceSeries?.studyIdentifier
            ?? study.series.first?.studyIdentifier
            ?? ""
        let frameOfReferenceUID = segmentation.frameOfReferenceUID.isEmpty
            ? sourceSeries?.frameOfReferenceUID ?? ""
            : segmentation.frameOfReferenceUID
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        let modificationDate = fileAttributes?[.modificationDate] as? Date ?? .distantPast

        return segmentation.segments.compactMap { definition -> MetalStudyROI? in
            let segmentFrames = segmentation.frames.filter {
                $0.segmentNumber == definition.number && $0.maskData.contains(where: { $0 != 0 })
            }
            guard segmentFrames.isEmpty == false else { return nil }
            let slices = segmentFrames.compactMap { frame -> MetalLegacyBrushMaskSlice? in
                guard let geometry = MetalViewerSliceGeometry(
                    attributes: frame.geometry,
                    width: segmentation.columns,
                    height: segmentation.rows
                ) else { return nil }
                return MetalLegacyBrushMaskSlice(
                    geometry: geometry,
                    maskWidth: segmentation.columns,
                    maskHeight: segmentation.rows,
                    originX: 0,
                    originY: 0,
                    maskData: verticallyReversedMask(
                        frame.maskData,
                        rows: segmentation.rows,
                        columns: segmentation.columns
                    )
                )
            }
            let color = displayColor(
                dicomCIELab: definition.recommendedDisplayCIELab,
                segmentNumber: definition.number
            )
            guard let reconstructed = MetalLegacyBrushSegmentationRequest(
                name: definition.label,
                colorRed: Double(color.redComponent),
                colorGreen: Double(color.greenComponent),
                colorBlue: Double(color.blueComponent),
                slices: slices
            ).run() else { return nil }

            let trackingUID = definition.trackingUID
                ?? deterministicDICOMUID(seed: "\(segmentation.sopInstanceUID)|\(definition.number)")
            var roi = MetalStudyROI(
                id: deterministicUUID(seed: "\(segmentation.sopInstanceUID)|\(definition.number)"),
                trackingUID: trackingUID,
                name: definition.label,
                studyInstanceUID: studyInstanceUID,
                frameOfReferenceUID: frameOfReferenceUID,
                sourceSeriesIdentifier: sourceSeriesIdentifier,
                color: color,
                center: reconstructed.center,
                radiusMM: reconstructed.radiusMM
            )
            roi.applyImageRefinement(
                automaticPoints: [],
                voxelField: reconstructed.voxelField,
                measuredVolumeMM3: reconstructed.voxelField.volumeMM3
            )
            roi.modifiedAt = modificationDate
            return roi
        }
    }

    private static func bestSourceSeries(
        for segmentation: SwiftDICOMSegmentation,
        in study: MetalViewerStudy
    ) -> MetalViewerSeries? {
        let referencedSOPInstanceUIDs = Set(segmentation.frames.compactMap(\.referencedSOPInstanceUID))
        let candidates = study.series.filter { $0.isDICOMSegmentation == false }
        if referencedSOPInstanceUIDs.isEmpty == false {
            let scored = candidates.map { series -> (MetalViewerSeries, Int) in
                let seriesSOPInstanceUIDs = Set(series.loadedPixList().compactMap { pix -> String? in
                    guard let path = pix.srcFile,
                          let reader = try? SwiftDICOMReader.cached(contentsOfFile: path) else { return nil }
                    return reader.stringValue(forTag: "0008,0018")
                })
                return (series, referencedSOPInstanceUIDs.intersection(seriesSOPInstanceUIDs).count)
            }
            if let match = scored.max(by: { $0.1 < $1.1 }), match.1 > 0 {
                return match.0
            }
        }
        if segmentation.frameOfReferenceUID.isEmpty == false,
           let match = candidates.first(where: {
               $0.frameOfReferenceUID == segmentation.frameOfReferenceUID
           }) {
            return match
        }
        return candidates.first
    }

    private static func verticallyReversedMask(_ mask: Data, rows: Int, columns: Int) -> Data {
        guard rows > 0, columns > 0, mask.count >= rows * columns else { return mask }
        let source = [UInt8](mask)
        var result = [UInt8](repeating: 0, count: rows * columns)
        for sourceRow in 0..<rows {
            let destinationRow = rows - sourceRow - 1
            result.replaceSubrange(
                destinationRow * columns..<(destinationRow + 1) * columns,
                with: source[sourceRow * columns..<(sourceRow + 1) * columns]
            )
        }
        return Data(result)
    }

    private static func encodedAuthoringJSON(for roi: MetalStudyROI) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(MetalStudyROIAuthoringEnvelope(roi: roi)))?.base64EncodedString()
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let hexadecimal = SHA256.hash(data: Data(seed.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let uuidString = "\(hexadecimal.prefix(8))-\(hexadecimal.dropFirst(8).prefix(4))-\(hexadecimal.dropFirst(12).prefix(4))-\(hexadecimal.dropFirst(16).prefix(4))-\(hexadecimal.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func deterministicDICOMUID(seed: String) -> String {
        var decimalDigits = [0]
        for byte in SHA256.hash(data: Data(seed.utf8)).prefix(16) {
            var carry = Int(byte)
            for index in decimalDigits.indices {
                let value = decimalDigits[index] * 256 + carry
                decimalDigits[index] = value % 10
                carry = value / 10
            }
            while carry > 0 {
                decimalDigits.append(carry % 10)
                carry /= 10
            }
        }
        return "2.25." + decimalDigits.reversed().map(String.init).joined()
    }

    private static func displayColor(dicomCIELab values: [Double], segmentNumber: Int) -> NSColor {
        guard values.count >= 3 else {
            let defaults: [NSColor] = [.systemYellow, .systemGreen, .systemCyan, .systemOrange, .systemPink]
            return defaults[(max(segmentNumber, 1) - 1) % defaults.count].usingColorSpace(.deviceRGB)
                ?? .systemYellow
        }

        let lightness = values[0] * 100 / 65_535
        let a = values[1] * 255 / 65_535 - 128
        let b = values[2] * 255 / 65_535 - 128
        let fy = (lightness + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        let epsilon = 216.0 / 24_389.0
        let kappa = 24_389.0 / 27.0
        func inverseLab(_ value: Double) -> Double {
            let cube = value * value * value
            return cube > epsilon ? cube : (116 * value - 16) / kappa
        }
        let x = 0.95047 * inverseLab(fx)
        let y = inverseLab(fy)
        let z = 1.08883 * inverseLab(fz)
        func gamma(_ value: Double) -> Double {
            let linear = max(value, 0)
            return linear <= 0.003_130_8
                ? 12.92 * linear
                : 1.055 * pow(linear, 1 / 2.4) - 0.055
        }
        let red = min(max(gamma(3.240_454_2 * x - 1.537_138_5 * y - 0.498_531_4 * z), 0), 1)
        let green = min(max(gamma(-0.969_266 * x + 1.876_010_8 * y + 0.041_556 * z), 0), 1)
        let blue = min(max(gamma(0.055_643_4 * x - 0.204_025_9 * y + 1.057_225_2 * z), 0), 1)
        return NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
    }

    func persist(_ rois: [MetalStudyROI]) {
        generationLock.lock()
        generation &+= 1
        let requestedGeneration = generation
        generationLock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let liveIdentifiers = Set(rois.map(\.id))
        let staleIdentifiers = pathsByROIIdentifier.keys.filter { liveIdentifiers.contains($0) == false }
        if staleIdentifiers.isEmpty == false,
           let sourcePixList = study.series.first(where: { $0.isDICOMSegmentation == false })?.loadedPixList() {
            for identifier in staleIdentifiers {
                guard let path = pathsByROIIdentifier[identifier] else { continue }
                if let error = MetalStudyROISegBridge.deleteSegmentation(atPath: path, pixList: sourcePixList) {
                    NSLog("MetalStudyROIPersistence could not delete DICOM SEG: %@", error)
                    errorHandler?(error)
                } else {
                    pathsByROIIdentifier.removeValue(forKey: identifier)
                    persistedAuthoringJSONByROIIdentifier.removeValue(forKey: identifier)
                }
            }
        }

        let jobs: [PersistJob] = rois.compactMap { roi in
            guard let sourceSeries = study.series.first(where: {
                $0.isDICOMSegmentation == false
                    && $0.identifier == roi.sourceSeriesIdentifier
            })
                    ?? study.series.first(where: {
                        $0.isDICOMSegmentation == false
                            && $0.frameOfReferenceUID == roi.frameOfReferenceUID
                    }),
                  sourceSeries.modality.caseInsensitiveCompare("SEG") != .orderedSame else { return nil }
            let pixList = sourceSeries.loadedPixList()
            let sourcePaths = pixList.compactMap(\.srcFile)
            let sourceFrameNumbers = pixList.map { max(Int($0.frameNo), 0) }
            guard pixList.isEmpty == false,
                  sourcePaths.count == pixList.count,
                  let data = try? encoder.encode(MetalStudyROIAuthoringEnvelope(roi: roi)) else { return nil }
            let json = data.base64EncodedString()
            let existingPath = pathsByROIIdentifier[roi.id]
            if existingPath != nil,
               persistedAuthoringJSONByROIIdentifier[roi.id] == json {
                return nil
            }
            return PersistJob(
                roi: roi,
                pixList: pixList,
                sourcePaths: sourcePaths,
                sourceFrameNumbers: sourceFrameNumbers,
                existingPath: existingPath,
                authoringJSON: json
            )
        }

        queue.async { [self] in
            for job in jobs {
                guard self.isCurrentGeneration(requestedGeneration),
                      let encoded = self.makeMasks(for: job, generation: requestedGeneration) else { return }
                DispatchQueue.main.sync {
                    guard self.isCurrentGeneration(requestedGeneration) else { return }
                    let result = MetalStudyROISegBridge.writeSegmentation(
                        label: job.roi.name,
                        trackingUID: job.roi.trackingUID,
                        authoringJSON: job.authoringJSON,
                        colorRed: job.roi.colorRed,
                        colorGreen: job.roi.colorGreen,
                        colorBlue: job.roi.colorBlue,
                        sourceImagePaths: job.sourcePaths,
                        frameMasks: encoded.masks,
                        rows: UInt(encoded.rows),
                        columns: UInt(encoded.columns),
                        pixList: job.pixList,
                        existingPath: job.existingPath
                    )
                    if let path = result["path"], result["error"] == nil {
                        SwiftDICOMReader.invalidateCache(forPath: path)
                        self.pathsByROIIdentifier[job.roi.id] = path
                        self.persistedAuthoringJSONByROIIdentifier[job.roi.id] = job.authoringJSON
                    } else if let error = result["error"] {
                        NSLog("MetalStudyROIPersistence could not autosave DICOM SEG: %@", error)
                        self.errorHandler?(error)
                    }
                }
            }
        }
    }

    private func isCurrentGeneration(_ candidate: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == candidate
    }

    private func makeMasks(
        for job: PersistJob,
        generation requestedGeneration: Int
    ) -> (masks: [Data], rows: Int, columns: Int)? {
        guard let firstPath = job.sourcePaths.first,
              let firstReader = try? SwiftDICOMReader.cached(contentsOfFile: firstPath),
              let rows = firstReader.integerValue(forTag: "0028,0010"),
              let columns = firstReader.integerValue(forTag: "0028,0011"),
              rows > 0, columns > 0 else { return nil }

        let boundingRadius = job.roi.conservativeBoundingRadiusMM
        let boundingRadiusSquared = boundingRadius * boundingRadius
        let maskAccumulator = MaskAccumulator(count: job.sourcePaths.count)
        DispatchQueue.concurrentPerform(iterations: job.sourcePaths.count) { frameIndex in
            guard self.isCurrentGeneration(requestedGeneration),
                  let reader = try? SwiftDICOMReader.cached(contentsOfFile: job.sourcePaths[frameIndex]),
                  reader.integerValue(forTag: "0028,0010") == rows,
                  reader.integerValue(forTag: "0028,0011") == columns,
                  let geometry = reader.frameGeometryAttributes(at: job.sourceFrameNumbers[frameIndex]) else {
                return
            }
            var bytes = Array(repeating: UInt8(0), count: rows * columns)
            for rowIndex in 0..<rows {
                if rowIndex.isMultiple(of: 32), self.isCurrentGeneration(requestedGeneration) == false {
                    return
                }
                let rowOrigin = geometry.origin + geometry.column * (Double(rowIndex) * geometry.spacingY)
                for columnIndex in 0..<columns {
                    let world = rowOrigin + geometry.row * (Double(columnIndex) * geometry.spacingX)
                    let delta = world - job.roi.center.vector
                    guard simd_length_squared(delta) <= boundingRadiusSquared else { continue }
                    if job.roi.implicitValue(at: world) <= 0 {
                        bytes[rowIndex * columns + columnIndex] = 1
                    }
                }
            }
            let data = Data(bytes)
            maskAccumulator.set(data, at: frameIndex)
        }
        let masks = maskAccumulator.values()
        guard masks.allSatisfy({ $0.count == rows * columns }) else { return nil }
        return (masks, rows, columns)
    }
}
