import AppKit
import Foundation
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
        max(radiusMM, kernelAnchorRadii.max() ?? radiusMM)
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
        guard directionLength > 0.000_001,
              anchors.count == kernelAnchorDirections.count,
              anchors.count == kernelAnchorRadii.count,
              anchors.isEmpty == false else {
            return radiusMM
        }

        let direction = proposedDirection / directionLength
        var weightedRadius = 0.0
        var totalWeight = 0.0
        var strongestInfluence = 0.0
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
            strongestInfluence = max(strongestInfluence, kernel)
        }
        guard totalWeight > 0 else { return radiusMM }
        let constrainedRadius = weightedRadius / totalWeight
        return max(radiusMM + (constrainedRadius - radiusMM) * strongestInfluence, 0.5)
    }

    mutating func setSphere(center: SIMD3<Double>, radiusMM: Double) {
        self.center = MetalStudyROIPoint(center)
        self.radiusMM = max(radiusMM, 0.5)
        supportRadiusMM = max(self.radiusMM * 0.8, 4)
        anchors.removeAll()
        anchorKinds.removeAll()
        kernelAnchorDirections.removeAll()
        kernelAnchorRadii.removeAll()
        volumeMM3 = 4.0 / 3.0 * Double.pi * pow(self.radiusMM, 3)
        modifiedAt = Date()
    }

    @discardableResult
    mutating func addAnchor(_ point: SIMD3<Double>) -> Int {
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
        anchors[index] = MetalStudyROIPoint(point)
        anchorKinds[index] = .manual
        rebuildAnchorSurface()
    }

    mutating func removeAnchor(at index: Int) {
        normalizeAnchorKinds()
        guard anchors.indices.contains(index) else { return }
        anchors.remove(at: index)
        anchorKinds.remove(at: index)
        rebuildAnchorSurface()
    }

    mutating func replaceAutomaticAnchors(with points: [SIMD3<Double>]) {
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

    func implicitValue(at point: SIMD3<Double>) -> Double {
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
        normalizeAnchorKinds()
        rebuildKernelState()
    }

    mutating func updateEstimatedVolume() {
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

    func applyImageRefinement(_ points: [SIMD3<Double>], to identifier: UUID) {
        guard let roiIndex = rois.firstIndex(where: { $0.id == identifier }) else { return }
        pushUndoState()
        rois[roiIndex].replaceAutomaticAnchors(with: points)
        scheduleVolumeEstimate(for: identifier)
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
    let meanDisplacementMM: Double
    let maximumDisplacementMM: Double
}

final class MetalStudyROIRefinementRequest: @unchecked Sendable {
    private struct Candidate {
        let radius: Double
        let displacement: Double
        let dataCost: Double
    }

    private struct DirectionSamples {
        let direction: SIMD3<Double>
        let originalRadius: Double
        let candidates: [Candidate]
        let hasImageEvidence: Bool
        let confidence: Double
        let isManualConstraint: Bool
    }

    private struct DirectionSeed {
        let direction: SIMD3<Double>
        let manualRadius: Double?
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

    func run() -> MetalStudyROIRefinementResult? {
        guard let volume = IntensityVolume(pixList: pixList) else { return nil }
        let directionSeeds = refinementDirections()
        guard directionSeeds.isEmpty == false else { return nil }

        let step = min(max(volume.minimumVoxelSpacing * 0.75, 0.35), 0.8)
        let samples = directionSeeds.map { seed in
            makeSamples(seed: seed, step: step, volume: volume)
        }
        let automaticSamples = samples.filter { $0.isManualConstraint == false }
        guard automaticSamples.lazy.filter(\.hasImageEvidence).count
            >= max(4, automaticSamples.count / 4) else {
            return nil
        }
        let directions = directionSeeds.map(\.direction)
        let neighbors = nearestNeighbors(for: directions, count: min(5, max(directions.count - 1, 0)))
        var selectedIndices = samples.map { samples in
            samples.candidates.enumerated().min(by: { $0.element.dataCost < $1.element.dataCost })?.offset ?? 0
        }

        for _ in 0..<5 {
            for index in samples.indices {
                guard samples[index].isManualConstraint == false else { continue }
                let neighboringOffsets = neighbors[index].map { neighbor -> Double in
                    let selected = samples[neighbor].candidates[selectedIndices[neighbor]]
                    return selected.displacement
                }
                let neighboringRadii = neighbors[index].map { neighbor -> Double in
                    samples[neighbor].candidates[selectedIndices[neighbor]].radius
                }
                let targetOffset = neighboringOffsets.isEmpty
                    ? 0
                    : neighboringOffsets.reduce(0, +) / Double(neighboringOffsets.count)
                let targetRadius = neighboringRadii.isEmpty
                    ? samples[index].originalRadius
                    : neighboringRadii.reduce(0, +) / Double(neighboringRadii.count)
                let best = samples[index].candidates.enumerated().min { lhs, rhs in
                    refinementCost(
                        lhs.element,
                        targetOffset: targetOffset,
                        targetRadius: targetRadius,
                        step: step,
                        confidence: samples[index].confidence
                    ) < refinementCost(
                        rhs.element,
                        targetOffset: targetOffset,
                        targetRadius: targetRadius,
                        step: step,
                        confidence: samples[index].confidence
                    )
                }
                selectedIndices[index] = best?.offset ?? selectedIndices[index]
            }
        }

        let selectedCandidates = regularizedCandidates(
            samples: samples,
            selectedCandidates: samples.indices.map { samples[$0].candidates[selectedIndices[$0]] },
            neighbors: neighbors,
            step: step
        )
        let anchors = prunedAnchors(
            samples: samples,
            selectedCandidates: selectedCandidates,
            step: step,
            volume: volume
        )
        let displacements = selectedCandidates.map { abs($0.displacement) }
        return MetalStudyROIRefinementResult(
            roiIdentifier: roi.id,
            automaticAnchors: anchors,
            meanDisplacementMM: displacements.reduce(0, +) / Double(max(displacements.count, 1)),
            maximumDisplacementMM: displacements.max() ?? 0
        )
    }

    private func prunedAnchors(
        samples: [DirectionSamples],
        selectedCandidates: [Candidate],
        step: Double,
        volume: IntensityVolume
    ) -> [SIMD3<Double>] {
        guard samples.count > 12, samples.count == selectedCandidates.count else {
            return samples.indices.filter { samples[$0].isManualConstraint == false }.map {
                roi.center.vector + samples[$0].direction * selectedCandidates[$0].radius
            }
        }

        let targetStrengths = samples.indices.map { index in
            boundaryStrength(
                radius: selectedCandidates[index].radius,
                direction: samples[index].direction,
                probeDistance: max(step, volume.minimumVoxelSpacing * 0.75),
                volume: volume
            ) ?? 0
        }
        let sortedStrengths = targetStrengths.sorted()
        let strengthReference = max(
            sortedStrengths[min(Int(Double(sortedStrengths.count - 1) * 0.9), sortedStrengths.count - 1)],
            0.000_001
        )
        let localGeometryTolerance = max(step * 1.15, 0.55)
        let localBoundaryLossTolerance = 0.06
        let manualIndices = samples.indices.filter { samples[$0].isManualConstraint }
        let minimumAnchorCount = manualIndices.count >= 6 ? 4 : 8
        var activeIndices = samples.indices.filter { samples[$0].isManualConstraint == false }

        while activeIndices.count > minimumAnchorCount {
            var bestRemoval: (position: Int, score: Double)?
            for (position, sampleIndex) in activeIndices.enumerated() {
                let neighboringIndices = (activeIndices + manualIndices)
                    .filter { $0 != sampleIndex }
                    .sorted {
                        simd_dot(samples[sampleIndex].direction, samples[$0].direction)
                            > simd_dot(samples[sampleIndex].direction, samples[$1].direction)
                    }
                    .prefix(6)
                guard neighboringIndices.count >= 3 else { continue }

                var weightedRadius = 0.0
                var totalWeight = 0.0
                for neighborIndex in neighboringIndices {
                    let chordDistance = simd_distance(
                        samples[sampleIndex].direction,
                        samples[neighborIndex].direction
                    )
                    let weight = 1 / max(chordDistance * chordDistance, 0.000_001)
                    weightedRadius += selectedCandidates[neighborIndex].radius * weight
                    totalWeight += weight
                }
                guard totalWeight > 0 else { continue }
                let reconstructedRadius = weightedRadius / totalWeight
                let geometryError = abs(reconstructedRadius - selectedCandidates[sampleIndex].radius)
                guard geometryError <= localGeometryTolerance else { continue }

                let reconstructedStrength = boundaryStrength(
                    radius: reconstructedRadius,
                    direction: samples[sampleIndex].direction,
                    probeDistance: max(step, volume.minimumVoxelSpacing * 0.75),
                    volume: volume
                ) ?? 0
                let normalizedBoundaryLoss = max(
                    targetStrengths[sampleIndex] - reconstructedStrength,
                    0
                ) / strengthReference
                guard normalizedBoundaryLoss <= localBoundaryLossTolerance else { continue }

                let score = geometryError / localGeometryTolerance + normalizedBoundaryLoss * 4
                if let currentBest = bestRemoval {
                    if score < currentBest.score {
                        bestRemoval = (position, score)
                    }
                } else {
                    bestRemoval = (position, score)
                }
            }
            guard let bestRemoval else { break }
            activeIndices.remove(at: bestRemoval.position)
        }

        let maximumGlobalError = max(step * 2.25, 1.25)
        let maximumRMSError = max(step, 0.55)
        let targetBoundaryQuality = targetStrengths.reduce(0, +)
        let maximumMeanBoundaryLoss = strengthReference * 0.012

        while true {
            var candidateROI = roi
            candidateROI.replaceAutomaticAnchors(
                with: activeIndices.map {
                    roi.center.vector + samples[$0].direction * selectedCandidates[$0].radius
                }
            )
            let radialErrors = samples.indices.map { index in
                abs(
                    candidateROI.surfaceRadius(along: samples[index].direction)
                        - selectedCandidates[index].radius
                )
            }
            let maximumError = radialErrors.max() ?? 0
            let rmsError = sqrt(
                radialErrors.reduce(0) { $0 + $1 * $1 } / Double(max(radialErrors.count, 1))
            )
            let candidateBoundaryQuality = samples.indices.reduce(0.0) { partial, index in
                let reconstructedRadius = candidateROI.surfaceRadius(along: samples[index].direction)
                return partial + (boundaryStrength(
                    radius: reconstructedRadius,
                    direction: samples[index].direction,
                    probeDistance: max(step, volume.minimumVoxelSpacing * 0.75),
                    volume: volume
                ) ?? 0)
            }
            let meanBoundaryLoss = max(
                targetBoundaryQuality - candidateBoundaryQuality,
                0
            ) / Double(max(samples.count, 1))
            if maximumError <= maximumGlobalError,
               rmsError <= maximumRMSError,
               meanBoundaryLoss <= maximumMeanBoundaryLoss {
                return activeIndices.map {
                    roi.center.vector + samples[$0].direction * selectedCandidates[$0].radius
                }
            }

            let activeSet = Set(activeIndices)
            let omittedIndices = samples.indices.filter {
                samples[$0].isManualConstraint == false && activeSet.contains($0) == false
            }
            guard omittedIndices.isEmpty == false else {
                return samples.indices.filter { samples[$0].isManualConstraint == false }.map {
                    roi.center.vector + samples[$0].direction * selectedCandidates[$0].radius
                }
            }
            let restorationCount = min(8, omittedIndices.count)
            let indicesToRestore = omittedIndices
                .sorted { radialErrors[$0] > radialErrors[$1] }
                .prefix(restorationCount)
            activeIndices.append(contentsOf: indicesToRestore)
        }
    }

    private func refinementDirections() -> [DirectionSeed] {
        var result: [DirectionSeed] = []
        result.reserveCapacity(224)
        for index in roi.anchors.indices where roi.anchorKind(at: index) == .manual {
            let anchor = roi.anchors[index]
            let offset = anchor.vector - roi.center.vector
            let length = simd_length(offset)
            guard length > 0.000_001 else { continue }
            let direction = offset / length
            if result.contains(where: { simd_dot($0.direction, direction) > 0.999 }) == false {
                result.append(DirectionSeed(direction: direction, manualRadius: length))
            }
        }

        for direction in Self.fibonacciDirections(count: 192) {
            if result.contains(where: { simd_dot($0.direction, direction) > 0.9995 }) == false {
                result.append(DirectionSeed(direction: direction, manualRadius: nil))
            }
        }
        return result
    }

    private func makeSamples(
        seed: DirectionSeed,
        step: Double,
        volume: IntensityVolume
    ) -> DirectionSamples {
        let direction = seed.direction
        if let manualRadius = seed.manualRadius {
            return DirectionSamples(
                direction: direction,
                originalRadius: manualRadius,
                candidates: [Candidate(radius: manualRadius, displacement: 0, dataCost: 0)],
                hasImageEvidence: true,
                confidence: 1,
                isManualConstraint: true
            )
        }
        let originalRadius = roi.surfaceRadius(along: direction)
        let maximumTravel = 10.0
        let inwardTravel = min(max(originalRadius - 0.5, 0), maximumTravel)
        var offsets = stride(from: -inwardTravel, through: maximumTravel, by: step).map { $0 }
        if offsets.contains(where: { abs($0 - maximumTravel) < 0.000_1 }) == false {
            offsets.append(maximumTravel)
        }
        if inwardTravel > 0,
           offsets.contains(where: { abs($0 + inwardTravel) < 0.000_1 }) == false {
            offsets.append(-inwardTravel)
        }
        if offsets.contains(where: { abs($0) < 0.000_1 }) == false { offsets.append(0) }
        offsets.sort()

        let probeDistance = max(step, volume.minimumVoxelSpacing * 0.75)
        let rawStrengths = offsets.map { offset in
            boundaryStrength(
                radius: max(originalRadius + offset, 0.5),
                direction: direction,
                probeDistance: probeDistance,
                volume: volume
            )
        }
        let validStrengths = rawStrengths.compactMap { $0 }.sorted()
        let scale = validStrengths.isEmpty
            ? 1
            : max(validStrengths[min(Int(Double(validStrengths.count - 1) * 0.9), validStrengths.count - 1)], 0.000_001)
        let confidence = boundaryConfidence(for: validStrengths)
        let zeroIndex = offsets.indices.min(by: { abs(offsets[$0]) < abs(offsets[$1]) }) ?? 0
        let originalStrength = rawStrengths[zeroIndex] ?? 0

        let candidates = offsets.indices.map { index -> Candidate in
            let offset = offsets[index]
            let normalizedImprovement = ((rawStrengths[index] ?? originalStrength) - originalStrength) / scale
            let displacementFraction = offset / max(maximumTravel, step)
            let missingPenalty = rawStrengths[index] == nil ? 1.5 : 0
            return Candidate(
                radius: max(originalRadius + offset, 0.5),
                displacement: offset,
                dataCost: -normalizedImprovement * (0.15 + confidence * 0.85)
                    + 0.28 * displacementFraction * displacementFraction
                    + missingPenalty
            )
        }
        return DirectionSamples(
            direction: direction,
            originalRadius: originalRadius,
            candidates: candidates,
            hasImageEvidence: validStrengths.isEmpty == false,
            confidence: confidence,
            isManualConstraint: false
        )
    }

    private func boundaryStrength(
        radius: Double,
        direction: SIMD3<Double>,
        probeDistance: Double,
        volume: IntensityVolume
    ) -> Double? {
        let radii = [
            radius - probeDistance * 2,
            radius - probeDistance,
            radius + probeDistance,
            radius + probeDistance * 2,
        ]
        let values = radii.map { sample(radius: max($0, 0.1), direction: direction, volume: volume) }
        guard let insideFar = values[0], let insideNear = values[1],
              let outsideNear = values[2], let outsideFar = values[3] else { return nil }
        let inside = (insideFar + insideNear) * 0.5
        let outside = (outsideNear + outsideFar) * 0.5
        let centralGradient = abs(outsideNear - insideNear)
        let regionalContrast = abs(outside - inside)
        return centralGradient * 0.65 + regionalContrast * 0.35
    }

    private func sample(
        radius: Double,
        direction: SIMD3<Double>,
        volume: IntensityVolume
    ) -> Double? {
        let canonicalPoint = roi.center.vector + direction * radius
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

    private func refinementCost(
        _ candidate: Candidate,
        targetOffset: Double,
        targetRadius: Double,
        step: Double,
        confidence: Double
    ) -> Double {
        let normalizedDifference = (candidate.displacement - targetOffset) / max(step, 0.1)
        let radiusScale = max(step * 2, 0.75)
        let normalizedRadiusDifference = (candidate.radius - targetRadius) / radiusScale
        return candidate.dataCost
            + 0.06 * Self.huber(normalizedDifference)
            + (0.16 - confidence * 0.08) * Self.huber(normalizedRadiusDifference)
    }

    private func regularizedCandidates(
        samples: [DirectionSamples],
        selectedCandidates: [Candidate],
        neighbors: [[Int]],
        step: Double
    ) -> [Candidate] {
        guard samples.count == selectedCandidates.count else { return selectedCandidates }
        let dataRadii = selectedCandidates.map(\.radius)
        var radii = dataRadii

        for _ in 0..<12 {
            let previousRadii = radii
            for index in samples.indices {
                guard samples[index].isManualConstraint == false else {
                    radii[index] = dataRadii[index]
                    continue
                }
                let neighborRadii = neighbors[index].map { previousRadii[$0] }.sorted()
                guard neighborRadii.isEmpty == false else { continue }
                let neighborMean = neighborRadii.reduce(0, +) / Double(neighborRadii.count)
                let neighborMedian = neighborRadii[neighborRadii.count / 2]
                let confidence = samples[index].confidence
                let dataWeight = 0.65 + confidence * 3.5
                let priorWeight = 0.45
                let smoothnessWeight = 2.4 - confidence * 1.2
                var regularizedRadius = (
                    dataRadii[index] * dataWeight
                        + samples[index].originalRadius * priorWeight
                        + neighborMean * smoothnessWeight
                ) / (dataWeight + priorWeight + smoothnessWeight)

                let signedExcursion = dataRadii[index] - neighborMedian
                let coherentNeighbors = neighbors[index].filter { neighborIndex in
                    let neighborExcursion = dataRadii[neighborIndex] - neighborMedian
                    return signedExcursion * neighborExcursion > 0
                        && abs(neighborExcursion) >= max(step, 0.4)
                }.count
                let baseExcursion = max(step * 2, 0.8)
                let supportedExcursion = max(step * 6, 2.5)
                let permittedExcursion = confidence >= 0.7 && coherentNeighbors >= 2
                    ? supportedExcursion
                    : baseExcursion
                regularizedRadius = min(
                    max(regularizedRadius, neighborMedian - permittedExcursion),
                    neighborMedian + permittedExcursion
                )

                let minimumRadius = samples[index].candidates.map(\.radius).min() ?? 0.5
                let maximumRadius = samples[index].candidates.map(\.radius).max() ?? dataRadii[index]
                radii[index] = min(max(regularizedRadius, minimumRadius), maximumRadius)
            }
        }

        return samples.indices.map { index in
            Candidate(
                radius: radii[index],
                displacement: radii[index] - samples[index].originalRadius,
                dataCost: selectedCandidates[index].dataCost
            )
        }
    }

    private func boundaryConfidence(for sortedStrengths: [Double]) -> Double {
        guard sortedStrengths.count >= 5,
              let peak = sortedStrengths.last else { return 0 }
        let median = sortedStrengths[sortedStrengths.count / 2]
        let deviations = sortedStrengths.map { abs($0 - median) }.sorted()
        let medianAbsoluteDeviation = deviations[deviations.count / 2]
        let noiseScale = max(medianAbsoluteDeviation * 1.4826, peak * 0.08, 0.000_001)
        let prominence = (peak - median) / noiseScale
        return min(max((prominence - 1) / 4, 0), 1)
    }

    private static func huber(_ value: Double) -> Double {
        let magnitude = abs(value)
        return magnitude <= 1 ? 0.5 * magnitude * magnitude : magnitude - 0.5
    }

    private func nearestNeighbors(for directions: [SIMD3<Double>], count: Int) -> [[Int]] {
        directions.indices.map { index in
            directions.indices
                .filter { $0 != index }
                .sorted { simd_dot(directions[index], directions[$0]) > simd_dot(directions[index], directions[$1]) }
                .prefix(count)
                .map { $0 }
        }
    }

    private static func fibonacciDirections(count: Int) -> [SIMD3<Double>] {
        guard count > 0 else { return [] }
        let goldenAngle = Double.pi * (3 - sqrt(5))
        return (0..<count).map { index in
            let y = 1 - (Double(index) + 0.5) * 2 / Double(count)
            let radial = sqrt(max(1 - y * y, 0))
            let angle = Double(index) * goldenAngle
            return SIMD3<Double>(cos(angle) * radial, y, sin(angle) * radial)
        }
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
