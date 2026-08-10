import AppKit
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
    var supportRadiusMM: Double
    var volumeMM3: Double
    var modifiedAt: Date
    var voxelField: MetalStudyROIVoxelField?

    private var kernelAnchorDirections: [SIMD3<Double>] = []
    private var kernelAnchorRadii: [Double] = []
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
        if directionLength > 0.000_001,
           let refinedRadius = voxelField?.surfaceRadius(
               from: center.vector,
               along: proposedDirection
           ) {
            return refinedRadius
        }
        guard directionLength > 0.000_001,
              anchors.count == kernelAnchorDirections.count,
              anchors.count == kernelAnchorRadii.count,
              anchors.isEmpty == false else {
            return radiusMM
        }

        let direction = proposedDirection / directionLength
        var weightedRadius = 0.0
        var totalWeight = 0.0
        var uncoveredFraction = 1.0
        for index in anchors.indices {
            let chordDistance = simd_distance(direction, kernelAnchorDirections[index])
            if chordDistance < 0.000_001 {
                return max(kernelAnchorRadii[index], 0.5)
            }
            let kernel = Self.wendlandC2(chordDistance / max(kernelAngularSupport, 0.001))
            guard kernel > 0 else { continue }
            // Manual anchors are hard constraints at their exact direction (the
            // early return above). Give them only a modest interpolation bias so
            // they do not flatten a broad neighborhood that image refinement
            // should still be free to fit.
            let priority = anchorKind(at: index) == .manual ? 2.5 : 1.0
            let weight = priority * kernel / max(chordDistance * chordDistance, 0.000_001)
            weightedRadius += weight * kernelAnchorRadii[index]
            totalWeight += weight
            // Combining the compact kernels as coverage keeps the blend smooth
            // where the nearest anchor changes. Taking only the strongest kernel
            // created Voronoi-like creases and allowed the contour to sag back
            // toward the original sphere between otherwise good auto anchors.
            uncoveredFraction *= 1 - kernel
        }
        guard totalWeight > 0 else { return radiusMM }
        let constrainedRadius = weightedRadius / totalWeight
        let combinedInfluence = 1 - uncoveredFraction
        return max(radiusMM + (constrainedRadius - radiusMM) * combinedInfluence, 0.5)
    }

    mutating func setSphere(center: SIMD3<Double>, radiusMM: Double) {
        self.center = MetalStudyROIPoint(center)
        self.radiusMM = max(radiusMM, 0.5)
        supportRadiusMM = max(self.radiusMM * 0.8, 4)
        anchors.removeAll()
        anchorKinds.removeAll()
        voxelField = nil
        kernelAnchorDirections.removeAll()
        kernelAnchorRadii.removeAll()
        volumeMM3 = 4.0 / 3.0 * Double.pi * pow(self.radiusMM, 3)
        modifiedAt = Date()
    }

    @discardableResult
    mutating func addAnchor(_ point: SIMD3<Double>) -> Int {
        voxelField = nil
        normalizeAnchorKinds()
        let minimumSeparation = max(radiusMM * 0.015, 0.25)
        let direction = Self.radialDirection(from: center.vector, to: point)
        if let index = anchors.firstIndex(where: {
            simd_distance($0.vector, point) < minimumSeparation
                || simd_distance(Self.radialDirection(from: center.vector, to: $0.vector), direction) < 0.01
        }) {
            anchors[index] = MetalStudyROIPoint(point)
            anchorKinds[index] = .manual
            rebuildAnchorSurface()
            return index
        } else {
            anchors.append(MetalStudyROIPoint(point))
            anchorKinds.append(.manual)
        }
        rebuildAnchorSurface()
        return anchors.count - 1
    }

    mutating func moveAnchor(at index: Int, to point: SIMD3<Double>) {
        normalizeAnchorKinds()
        guard anchors.indices.contains(index) else { return }
        voxelField = nil
        anchors[index] = MetalStudyROIPoint(point)
        anchorKinds[index] = .manual
        rebuildAnchorSurface()
    }

    mutating func removeAnchor(at index: Int) {
        normalizeAnchorKinds()
        guard anchors.indices.contains(index) else { return }
        voxelField = nil
        anchors.remove(at: index)
        anchorKinds.remove(at: index)
        rebuildAnchorSurface()
    }

    mutating func replaceAutomaticAnchors(with points: [SIMD3<Double>]) {
        voxelField = nil
        normalizeAnchorKinds()
        let manualAnchors = anchors.indices.compactMap { index in
            anchorKinds[index] == .manual ? anchors[index] : nil
        }
        let manualDirections = manualAnchors.map {
            Self.radialDirection(from: center.vector, to: $0.vector)
        }
        let minimumManualChordDistance = 0.04
        let automaticPoints = points.filter { point in
            let direction = Self.radialDirection(from: center.vector, to: point)
            return manualDirections.allSatisfy {
                simd_distance($0, direction) >= minimumManualChordDistance
            }
        }
        anchors = manualAnchors + automaticPoints.map(MetalStudyROIPoint.init)
        anchorKinds = Array(repeating: .manual, count: manualAnchors.count)
            + Array(repeating: .automatic, count: automaticPoints.count)
        rebuildAnchorSurface()
    }

    mutating func applyImageRefinement(
        automaticPoints: [SIMD3<Double>],
        voxelField: MetalStudyROIVoxelField,
        measuredVolumeMM3: Double? = nil,
        updateVolume: Bool = true
    ) {
        replaceAutomaticAnchors(with: automaticPoints)
        self.voxelField = voxelField.isValid ? voxelField : nil
        if updateVolume, let field = self.voxelField {
            volumeMM3 = measuredVolumeMM3 ?? field.volumeMM3
        }
        modifiedAt = Date()
    }

    func implicitValue(at point: SIMD3<Double>) -> Double {
        if let voxelField {
            guard let probability = voxelField.probability(at: point) else { return 1 }
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
        rebuildKernelState()
    }

    mutating func updateEstimatedVolume() {
        if let voxelField, voxelField.isValid {
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
        case center, radiusMM, anchors, anchorKinds, supportRadiusMM, volumeMM3, modifiedAt
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
        supportRadiusMM = try container.decode(Double.self, forKey: .supportRadiusMM)
        volumeMM3 = try container.decode(Double.self, forKey: .volumeMM3)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        voxelField = try container.decodeIfPresent(MetalStudyROIVoxelField.self, forKey: .voxelField)
        normalizeAnchorKinds()
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
        try container.encode(supportRadiusMM, forKey: .supportRadiusMM)
        try container.encode(volumeMM3, forKey: .volumeMM3)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(voxelField, forKey: .voxelField)
    }
}

enum MetalStudyROIEditingMode: Equatable, Sendable {
    case inactive
    case createSphere
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
            priorWeight: 0.000_01,
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

    init(
        roi: MetalStudyROI,
        pixList: [DCMPix],
        canonicalToSeriesWorld: simd_float4x4
    ) {
        self.roi = roi
        self.pixList = pixList
        self.canonicalToSeriesWorld = canonicalToSeriesWorld
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
        applyManualRandomWalkerConstraints(grid: grid, to: &fixedValues)
        guard fixedValues.contains(where: { $0 >= 0.99 }),
              fixedValues.contains(where: { $0 == 0 }) else {
            return fail("The ROI did not provide both interior and exterior refinement constraints.")
        }

        // Constructing the initial field asks the current ROI surface for every
        // voxel. Once an image/ROI pair has a solved field, that field is both a
        // better initial estimate and dramatically cheaper to reuse.
        let initial = state.hasWarmSolution ? nil : initialProbabilities(grid: grid)
        guard solveRandomWalker(
            grid: grid,
            edgeBuffers: prepared.gpuEdgeBuffers,
            workspace: state.workspace,
            fixedValues: &fixedValues,
            initial: initial,
            reuseProbability: state.hasWarmSolution,
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
            result[index] = signedValue <= 0 ? 1 : 0
        }
        return result
    }

    private func randomWalkerConstraintBase(
        grid: RandomWalkerGrid
    ) -> [Float] {
        var fixed = Array(repeating: Float.nan, count: grid.voxelCount)
        let dimensions = grid.dimensions
        for z in 0..<dimensions.z {
            for y in 0..<dimensions.y {
                for x in 0..<dimensions.x {
                    let index = grid.index(x: x, y: y, z: z)
                    if grid.valid[index] == false
                        || x == 0 || y == 0 || z == 0
                        || x == dimensions.x - 1
                        || y == dimensions.y - 1
                        || z == dimensions.z - 1 {
                        fixed[index] = 0
                        continue
                    }

                    let point = grid.point(x: x, y: y, z: z)
                    let offset = point - roi.center.vector
                    let distance = simd_length(offset)
                    if distance > 0.000_001 {
                        let existingRadius = roi.surfaceRadius(along: offset / distance)
                        let signedDistance = distance - existingRadius
                        let exteriorSearchDistance = 10.0
                        // In three dimensions, a tiny foreground core and a
                        // distant background shell cause the harmonic solution
                        // to collapse inward even for uniform edge weights. This
                        // erosion depth balances spherical harmonic falloff so
                        // the current boundary is the neutral 0.5 solution while
                        // retaining the requested 10 mm outward search range.
                        let interiorSeedDepth = existingRadius * exteriorSearchDistance
                            / max(existingRadius + 2 * exteriorSearchDistance, 0.001)
                        if signedDistance <= -max(interiorSeedDepth, grid.spacing * 1.5) {
                            fixed[index] = 1
                        } else if signedDistance >= exteriorSearchDistance {
                            fixed[index] = 0
                        }
                    } else {
                        fixed[index] = 1
                    }
                }
            }
        }

        return fixed
    }

    private func applyManualRandomWalkerConstraints(
        grid: RandomWalkerGrid,
        to fixed: inout [Float]
    ) {
        let pairedSeedDistance = max(grid.spacing * 1.75, 1.0)
        for index in roi.anchors.indices where roi.anchorKind(at: index) == .manual {
            let boundaryPoint = roi.anchors[index].vector
            let radialOffset = boundaryPoint - roi.center.vector
            guard simd_length_squared(radialOffset) > 0.000_001 else { continue }
            let radial = simd_normalize(radialOffset)
            let normal = imageBoundaryNormal(
                at: boundaryPoint,
                radialFallback: radial,
                grid: grid
            )
            setConstraint(
                1,
                near: boundaryPoint - normal * pairedSeedDistance,
                radius: grid.spacing * 0.65,
                grid: grid,
                values: &fixed
            )
            setConstraint(
                0,
                near: boundaryPoint + normal * pairedSeedDistance,
                radius: grid.spacing * 0.65,
                grid: grid,
                values: &fixed
            )
            // A 0.5 Dirichlet seed makes the final iso-surface pass through the
            // user's point without pretending that the point specifies a normal.
            setConstraint(
                0.5,
                near: boundaryPoint,
                radius: grid.spacing * 0.35,
                grid: grid,
                values: &fixed
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
        sweepCount: Int
    ) -> Bool {
        MetalStudyROIGPUSolver.shared?.solve(
            dimensions: grid.dimensions,
            fixedValues: fixedValues,
            initialValues: initial,
            reuseProbability: reuseProbability,
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
            // measurement, ray extraction, and displacement statistics to the
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
        // Automatic anchors are now sparse visual handles sampled from the voxel
        // result; they no longer define the surface. Forty-two stable directions
        // communicate the result without recreating the former 162-point mesh.
        let directions = Self.icosphereDirections(subdivisions: 1)
        let anchors = directions.compactMap { direction -> SIMD3<Double>? in
            guard let radius = field.surfaceRadius(
                from: roi.center.vector,
                along: direction
            ) else { return nil }
            return roi.center.vector + direction * radius
        }
        guard anchors.count >= directions.count / 2 else {
            return fail("The solved ROI did not form a closed surface around its centre.")
        }
        let displacements = anchors.map { point in
            let direction = simd_normalize(point - roi.center.vector)
            return abs(
                simd_distance(point, roi.center.vector)
                    - roi.surfaceRadius(along: direction)
            )
        }
        return MetalStudyROIRefinementResult(
            roiIdentifier: roi.id,
            automaticAnchors: anchors,
            voxelField: field,
            volumeMM3: fieldResult.volumeMM3,
            meanDisplacementMM: displacements.reduce(0, +) / Double(max(displacements.count, 1)),
            maximumDisplacementMM: displacements.max() ?? 0
        )
    }

    private static func icosphereDirections(subdivisions: Int) -> [SIMD3<Double>] {
        let goldenRatio = (1 + sqrt(5.0)) * 0.5
        var directions = [
            SIMD3<Double>(-1, goldenRatio, 0), SIMD3<Double>(1, goldenRatio, 0),
            SIMD3<Double>(-1, -goldenRatio, 0), SIMD3<Double>(1, -goldenRatio, 0),
            SIMD3<Double>(0, -1, goldenRatio), SIMD3<Double>(0, 1, goldenRatio),
            SIMD3<Double>(0, -1, -goldenRatio), SIMD3<Double>(0, 1, -goldenRatio),
            SIMD3<Double>(goldenRatio, 0, -1), SIMD3<Double>(goldenRatio, 0, 1),
            SIMD3<Double>(-goldenRatio, 0, -1), SIMD3<Double>(-goldenRatio, 0, 1),
        ].map { simd_normalize($0) }
        var faces = [
            SIMD3<Int>(0, 11, 5), SIMD3<Int>(0, 5, 1), SIMD3<Int>(0, 1, 7),
            SIMD3<Int>(0, 7, 10), SIMD3<Int>(0, 10, 11), SIMD3<Int>(1, 5, 9),
            SIMD3<Int>(5, 11, 4), SIMD3<Int>(11, 10, 2), SIMD3<Int>(10, 7, 6),
            SIMD3<Int>(7, 1, 8), SIMD3<Int>(3, 9, 4), SIMD3<Int>(3, 4, 2),
            SIMD3<Int>(3, 2, 6), SIMD3<Int>(3, 6, 8), SIMD3<Int>(3, 8, 9),
            SIMD3<Int>(4, 9, 5), SIMD3<Int>(2, 4, 11), SIMD3<Int>(6, 2, 10),
            SIMD3<Int>(8, 6, 7), SIMD3<Int>(9, 8, 1),
        ]

        for _ in 0..<max(subdivisions, 0) {
            var midpointIndices: [UInt64: Int] = [:]
            var subdividedFaces: [SIMD3<Int>] = []
            subdividedFaces.reserveCapacity(faces.count * 4)

            func midpointIndex(_ first: Int, _ second: Int) -> Int {
                let lower = min(first, second)
                let upper = max(first, second)
                let key = (UInt64(lower) << 32) | UInt64(upper)
                if let existing = midpointIndices[key] { return existing }
                directions.append(simd_normalize(directions[first] + directions[second]))
                let index = directions.count - 1
                midpointIndices[key] = index
                return index
            }

            for face in faces {
                let firstSecond = midpointIndex(face.x, face.y)
                let secondThird = midpointIndex(face.y, face.z)
                let thirdFirst = midpointIndex(face.z, face.x)
                subdividedFaces.append(contentsOf: [
                    SIMD3<Int>(face.x, firstSecond, thirdFirst),
                    SIMD3<Int>(face.y, secondThird, firstSecond),
                    SIMD3<Int>(face.z, thirdFirst, secondThird),
                    SIMD3<Int>(firstSecond, secondThird, thirdFirst),
                ])
            }
            faces = subdividedFaces
        }
        return directions
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
        maximumGridDimension: Int = 112
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
            guard let pix = series.firstPreviewPix(),
                  let path = pix.srcFile,
                  let reader = try? SwiftDICOMReader.cached(contentsOfFile: path) else { continue }
            let isSegmentation = series.modality.caseInsensitiveCompare("SEG") == .orderedSame
                || reader.stringValue(forTag: "0008,0016") == "1.2.840.10008.5.1.4.1.1.66.4"
            guard isSegmentation,
                  let json = reader.stringValue(forTag: "7777,1001"),
                  let data = Data(base64Encoded: json),
                  let envelope = try? decoder.decode(MetalStudyROIAuthoringEnvelope.self, from: data),
                  envelope.schema == MetalStudyROIAuthoringEnvelope.schema else { continue }
            restored.removeAll { $0.id == envelope.roi.id }
            restored.append(envelope.roi)
            paths[envelope.roi.id] = path
            payloads[envelope.roi.id] = json
        }
        return RestoredState(
            rois: restored.sorted { $0.modifiedAt > $1.modifiedAt },
            paths: paths,
            payloads: payloads
        )
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
