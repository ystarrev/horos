import AppKit
import Foundation
import simd

enum MetalViewerMouseButton: Int, Hashable {
    case left = 0
    case right = 1
}

enum MetalViewerMouseTool: Int, CaseIterable, Hashable {
    case windowLevel = 0
    case pan = 1
    case zoom = 2
    case rotate = 3
    case scroll = 4
    case tumourSeed = 5
}

struct MetalViewerMouseToolAssignments: Equatable {
    var left: MetalViewerMouseTool = .windowLevel
    var right: MetalViewerMouseTool = .zoom

    func tool(for button: MetalViewerMouseButton) -> MetalViewerMouseTool {
        switch button {
        case .left:
            return left
        case .right:
            return right
        }
    }

    mutating func setTool(_ tool: MetalViewerMouseTool, for button: MetalViewerMouseButton) {
        switch button {
        case .left:
            left = tool
        case .right:
            right = tool
        }
    }
}

enum MetalViewerImageInterpolationMode: Int, CaseIterable {
    case nearest = 0
    case linear = 1
    case lanczos = 2

    static let defaultsKey = "HorosMetalViewerImageInterpolationMode"
    static let defaultMode: MetalViewerImageInterpolationMode = .linear

    static var saved: MetalViewerImageInterpolationMode {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil else {
            return defaultMode
        }
        return MetalViewerImageInterpolationMode(rawValue: defaults.integer(forKey: defaultsKey)) ?? defaultMode
    }

    static func save(_ mode: MetalViewerImageInterpolationMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

    var title: String {
        switch self {
        case .nearest:
            return NSLocalizedString("Nearest", comment: "")
        case .linear:
            return NSLocalizedString("Linear", comment: "")
        case .lanczos:
            return NSLocalizedString("Lanczos", comment: "")
        }
    }

    var summary: String {
        switch self {
        case .nearest:
            return NSLocalizedString("Preserves exact source pixels when zoomed in. Useful for pixel inspection, but jagged.", comment: "")
        case .linear:
            return NSLocalizedString("Fast smooth interpolation. This is the current Metal viewer behavior.", comment: "")
        case .lanczos:
            return NSLocalizedString("Higher quality zoom interpolation with crisper detail. Downsampling stays linear to avoid shimmer.", comment: "")
        }
    }
}

struct MetalViewerTumourSeedScope: Equatable {
    let studyIdentifier: String
    let seriesIdentifier: String
}

struct MetalViewerTumourSeedPlacement {
    let sliceIndex: Int
    let pixelPoint: CGPoint
    let dicomPoint: SIMD3<Double>
}

struct MetalViewerTumourSeed: Codable, Equatable {
    static let defaultDiameterMM: Double = 5.0

    let identifier: String
    let studyIdentifier: String
    let seriesIdentifier: String
    let sliceIndex: Int
    let pixelX: Double
    let pixelY: Double
    let dicomX: Double
    let dicomY: Double
    let dicomZ: Double
    let diameterMM: Double
    let createdAt: Date

    var pixelPoint: CGPoint {
        CGPoint(x: pixelX, y: pixelY)
    }

    var dicomPoint: SIMD3<Double> {
        SIMD3<Double>(dicomX, dicomY, dicomZ)
    }
}

private struct MetalViewerTumourSeedDocument: Codable {
    var schema: String
    var studyIdentifier: String
    var seriesIdentifier: String
    var seeds: [MetalViewerTumourSeed]
}

final class MetalViewerTumourSeedStore {
    static let shared = MetalViewerTumourSeedStore()
    static let didChangeNotification = Notification.Name("HorosMetalViewerTumourSeedsDidChange")
    static let studyIdentifierUserInfoKey = "studyIdentifier"
    static let seriesIdentifierUserInfoKey = "seriesIdentifier"

    private static let schema = "com.horos.metalviewer.tumour-seeds.v1"
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private init() {
    }

    func seeds(for series: MetalViewerSeries) -> [MetalViewerTumourSeed] {
        seeds(for: series.tumourSeedScope)
    }

    func seeds(forPixList pixList: [DCMPix]) -> [MetalViewerTumourSeed] {
        guard let scope = Self.scope(forPixList: pixList) else {
            return []
        }
        return seeds(for: scope)
    }

    func addSeed(
        placement: MetalViewerTumourSeedPlacement,
        for series: MetalViewerSeries,
        diameterMM: Double = MetalViewerTumourSeed.defaultDiameterMM
    ) throws -> MetalViewerTumourSeed {
        let scope = series.tumourSeedScope
        let seed = MetalViewerTumourSeed(
            identifier: UUID().uuidString,
            studyIdentifier: scope.studyIdentifier,
            seriesIdentifier: scope.seriesIdentifier,
            sliceIndex: placement.sliceIndex,
            pixelX: Double(placement.pixelPoint.x),
            pixelY: Double(placement.pixelPoint.y),
            dicomX: placement.dicomPoint.x,
            dicomY: placement.dicomPoint.y,
            dicomZ: placement.dicomPoint.z,
            diameterMM: max(diameterMM, 0.1),
            createdAt: Date()
        )

        try updateSeeds(for: scope) { seeds in
            seeds.append(seed)
        }
        return seed
    }

    static func scope(forPixList pixList: [DCMPix]) -> MetalViewerTumourSeedScope? {
        for pix in pixList {
            guard let imageObject = imageObject(for: pix) else {
                continue
            }
            let studyIdentifier = nonEmpty(imageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String)
            let seriesIdentifier = nonEmpty(imageObject.value(forKeyPath: "series.seriesDICOMUID") as? String)
                ?? nonEmpty(imageObject.value(forKeyPath: "series.seriesInstanceUID") as? String)
            if let studyIdentifier, let seriesIdentifier {
                return MetalViewerTumourSeedScope(studyIdentifier: studyIdentifier, seriesIdentifier: seriesIdentifier)
            }
        }
        return nil
    }

    static func notification(_ notification: Notification, matches scope: MetalViewerTumourSeedScope) -> Bool {
        guard let studyIdentifier = notification.userInfo?[studyIdentifierUserInfoKey] as? String,
              let seriesIdentifier = notification.userInfo?[seriesIdentifierUserInfoKey] as? String else {
            return false
        }
        return studyIdentifier == scope.studyIdentifier && seriesIdentifier == scope.seriesIdentifier
    }

    func seeds(for scope: MetalViewerTumourSeedScope) -> [MetalViewerTumourSeed] {
        lock.lock()
        defer { lock.unlock() }
        return loadDocument(for: scope).seeds
    }

    private func updateSeeds(
        for scope: MetalViewerTumourSeedScope,
        mutation: (inout [MetalViewerTumourSeed]) -> Void
    ) throws {
        var document: MetalViewerTumourSeedDocument
        lock.lock()
        do {
            document = loadDocument(for: scope)
            mutation(&document.seeds)
            try save(document, for: scope)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [
                Self.studyIdentifierUserInfoKey: scope.studyIdentifier,
                Self.seriesIdentifierUserInfoKey: scope.seriesIdentifier,
            ]
        )
    }

    private func loadDocument(for scope: MetalViewerTumourSeedScope) -> MetalViewerTumourSeedDocument {
        let emptyDocument = MetalViewerTumourSeedDocument(
            schema: Self.schema,
            studyIdentifier: scope.studyIdentifier,
            seriesIdentifier: scope.seriesIdentifier,
            seeds: []
        )

        guard let fileURL = try? fileURL(for: scope),
              let data = try? Data(contentsOf: fileURL),
              var document = try? JSONDecoder().decode(MetalViewerTumourSeedDocument.self, from: data),
              document.schema == Self.schema else {
            return emptyDocument
        }

        document.seeds = document.seeds.filter {
            $0.studyIdentifier == scope.studyIdentifier && $0.seriesIdentifier == scope.seriesIdentifier
        }
        return document
    }

    private func save(_ document: MetalViewerTumourSeedDocument, for scope: MetalViewerTumourSeedScope) throws {
        let directory = try storageDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: try fileURL(for: scope), options: .atomic)
    }

    private func fileURL(for scope: MetalViewerTumourSeedScope) throws -> URL {
        try storageDirectory().appendingPathComponent("\(fileComponent(scope.studyIdentifier))--\(fileComponent(scope.seriesIdentifier)).json")
    }

    private func storageDirectory() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Horos", isDirectory: true)
            .appendingPathComponent("MetalTumourSeeds", isDirectory: true)
    }

    private func fileComponent(_ identifier: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier
        return encoded.isEmpty ? "unknown" : String(encoded.prefix(180))
    }

    private static func imageObject(for pix: DCMPix) -> NSManagedObject? {
        if let imageObject = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject {
            return imageObject
        }
        return pix.value(forKey: "imageObj") as? NSManagedObject
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct MetalViewerWindowLevel: Equatable {
    var level: Float
    var width: Float
}

struct MetalViewerWindowLevelState {
    var defaultWindow: MetalViewerWindowLevel?
    var customWindow: MetalViewerWindowLevel?
}

final class MetalViewerSeries {
    let identifier: String
    let title: String
    let seriesNumber: String
    let studyIdentifier: String
    let studyTitle: String
    let studyDate: Date?
    let studyNumber: Int
    let showsStudyHeader: Bool
    let imageCount: Int
    let modality: String

    private let imageObjects: [NSManagedObject]
    private let isBonjour: Bool
    private var cachedPixList: [DCMPix]?
    private var cachedVolumeBacking: NSData?
    private var cachedStructuredReportHTML: String?
    var windowLevelState = MetalViewerWindowLevelState()
    var windowLevelPresetTitle = NSLocalizedString("Default WL & WW", comment: "")

    init(
        identifier: String = UUID().uuidString,
        title: String,
        seriesNumber: String,
        studyIdentifier: String,
        studyTitle: String,
        studyDate: Date?,
        studyNumber: Int,
        showsStudyHeader: Bool,
        imageObjects: [NSManagedObject],
        isBonjour: Bool,
        initialPixList: [DCMPix]? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.seriesNumber = seriesNumber
        self.studyIdentifier = studyIdentifier
        self.studyTitle = studyTitle
        self.studyDate = studyDate
        self.studyNumber = studyNumber
        self.showsStudyHeader = showsStudyHeader
        self.imageObjects = imageObjects
        self.isBonjour = isBonjour
        self.imageCount = imageObjects.isEmpty ? (initialPixList?.count ?? 0) : imageObjects.count
        self.modality = Self.modality(for: imageObjects, initialPixList: initialPixList)
        self.cachedPixList = initialPixList
        self.cachedVolumeBacking = nil
        self.cachedStructuredReportHTML = nil
    }

    var isStructuredReport: Bool {
        if modality == "SR" {
            return true
        }

        if imageObjects.contains(where: { Self.isStructuredReport(imageObject: $0) }) {
            return true
        }

        if let cachedPixList,
           cachedPixList.contains(where: { Self.isStructuredReportSOPClassUID($0.value(forKey: "SOPClassUID") as? String) }) {
            return true
        }

        return structuredReportHTML() != nil
    }

    var tumourSeedScope: MetalViewerTumourSeedScope {
        if let imageObject = imageObjects.first {
            let studyIdentifier = Self.nonEmpty(imageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String)
                ?? self.studyIdentifier
            let seriesIdentifier = Self.nonEmpty(imageObject.value(forKeyPath: "series.seriesDICOMUID") as? String)
                ?? Self.nonEmpty(imageObject.value(forKeyPath: "series.seriesInstanceUID") as? String)
                ?? identifier
            return MetalViewerTumourSeedScope(studyIdentifier: studyIdentifier, seriesIdentifier: seriesIdentifier)
        }

        if let cachedPixList,
           let scope = MetalViewerTumourSeedStore.scope(forPixList: cachedPixList) {
            return scope
        }

        return MetalViewerTumourSeedScope(studyIdentifier: studyIdentifier, seriesIdentifier: identifier)
    }

    func structuredReportHTML() -> String? {
        if let cachedStructuredReportHTML {
            return cachedStructuredReportHTML
        }

        let candidatePaths = structuredReportCandidatePaths()
        for path in candidatePaths {
            if let html = StructuredReportSupport.htmlString(forPath: path), html.isEmpty == false {
                cachedStructuredReportHTML = html
                return html
            }
        }

        return nil
    }

    func loadedPixList() -> [DCMPix] {
        if let cachedPixList {
            return cachedPixList
        }

        let loadList = imageObjects
        guard loadList.isEmpty == false else {
            cachedPixList = []
            return []
        }

        let multiFrame = loadList.count == 1 && (((loadList[0].value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? 0) > 1 || ((loadList[0].value(forKey: "numberOfSeries") as? NSNumber)?.intValue ?? 0) > 1)

        var memBlock: UInt = 0
        if multiFrame {
            let object = loadList[0]
            let height = UInt((object.value(forKey: "height") as? NSNumber)?.intValue ?? 0)
            let width = UInt((object.value(forKey: "width") as? NSNumber)?.intValue ?? 0)
            let frames = UInt((object.value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? 0)
            memBlock = width * height * frames
        } else {
            for image in loadList {
                var width = UInt((image.value(forKey: "width") as? NSNumber)?.intValue ?? 0)
                var height = UInt((image.value(forKey: "height") as? NSNumber)?.intValue ?? 0)
                if width * height < 256 * 256 {
                    width = 256
                    height = 256
                }
                memBlock += width * height
            }
        }

        if memBlock < 256 * 256 {
            memBlock = 256 * 256
        }

        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Int(memBlock))
        let volumeBacking = NSData(bytesNoCopy: pointer, length: Int(memBlock) * MemoryLayout<Float>.size, freeWhenDone: true)

        var pixList: [DCMPix] = []
        var memOffset: UInt = 0

        if multiFrame {
            let object = loadList[0]
            let numberOfFrames = (object.value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? 0
            let width = UInt((object.value(forKey: "width") as? NSNumber)?.intValue ?? 0)
            let height = UInt((object.value(forKey: "height") as? NSNumber)?.intValue ?? 0)
            let seriesID = (object.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
            let path = Self.resolvedPath(for: object) ?? ""

            for i in 0..<numberOfFrames {
                if let pix = DCMPix(path: path, i, numberOfFrames, pointer.advanced(by: Int(memOffset)), i, seriesID, isBonjour: isBonjour, imageObj: object) {
                    pixList.append(pix)
                    memOffset += width * height
                }
            }
        } else {
            for (index, object) in loadList.enumerated() {
                let width = UInt((object.value(forKey: "width") as? NSNumber)?.intValue ?? 0)
                let height = UInt((object.value(forKey: "height") as? NSNumber)?.intValue ?? 0)
                let frameID = (object.value(forKey: "frameID") as? NSNumber)?.intValue ?? 0
                let seriesID = (object.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
                let path = Self.resolvedPath(for: object) ?? ""

                if let pix = DCMPix(path: path, index, loadList.count, pointer.advanced(by: Int(memOffset)), frameID, seriesID, isBonjour: isBonjour, imageObj: object) {
                    pixList.append(pix)
                    memOffset += width * height
                }
            }
        }

        cachedPixList = pixList
        cachedVolumeBacking = volumeBacking
        return pixList
    }

    func retainLoadedPixelCache(from previousSeries: MetalViewerSeries) {
        guard imageCount == previousSeries.imageCount else { return }

        // The renderer keeps DCMPix references when a same-count refresh swaps series objects.
        // Carry the backing store forward so those external fImage pointers remain valid.
        if cachedPixList == nil {
            cachedPixList = previousSeries.cachedPixList
            cachedVolumeBacking = previousSeries.cachedVolumeBacking
        }

        if cachedStructuredReportHTML == nil {
            cachedStructuredReportHTML = previousSeries.cachedStructuredReportHTML
        }
    }

    func firstPreviewPix() -> DCMPix? {
        if let cachedPixList, let first = cachedPixList.first {
            return first
        }

        guard let firstObject = imageObjects.first else {
            return nil
        }

        let path = Self.resolvedPath(for: firstObject) ?? ""
        let frameID = (firstObject.value(forKey: "frameID") as? NSNumber)?.intValue ?? 0
        let seriesID = (firstObject.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
        return DCMPix(path: path, 0, 1, nil, frameID, seriesID, isBonjour: isBonjour, imageObj: firstObject)
    }

    private static func resolvedPath(for imageObject: NSManagedObject) -> String? {
        if imageObject.responds(to: NSSelectorFromString("completePathResolved")),
           let value = imageObject.perform(NSSelectorFromString("completePathResolved"))?.takeUnretainedValue() as? String,
           value.isEmpty == false {
            return value
        }

        if imageObject.responds(to: NSSelectorFromString("completePath")),
           let value = imageObject.perform(NSSelectorFromString("completePath"))?.takeUnretainedValue() as? String,
           value.isEmpty == false {
            return value
        }

        if let value = imageObject.value(forKey: "completePath") as? String,
           value.isEmpty == false {
            return value
        }

        return nil
    }

    private static func modality(for imageObjects: [NSManagedObject], initialPixList: [DCMPix]?) -> String {
        if let modality = imageObjects.first?.value(forKeyPath: "series.modality") as? String,
           modality.isEmpty == false {
            return modality.uppercased()
        }
        if let modality = initialPixList?.first?.modalityString,
           modality.isEmpty == false {
            return modality.uppercased()
        }
        return "OT"
    }

    private func structuredReportCandidatePaths() -> [String] {
        var orderedPaths: [String] = []
        var seen = Set<String>()

        func appendPath(_ path: String?) {
            guard let path, path.isEmpty == false, seen.contains(path) == false else { return }
            seen.insert(path)
            orderedPaths.append(path)
        }

        for imageObject in imageObjects where Self.isStructuredReport(imageObject: imageObject) {
            appendPath(Self.resolvedPath(for: imageObject))
        }

        if let cachedPixList {
            for pix in cachedPixList {
                if Self.isStructuredReportSOPClassUID(pix.value(forKey: "SOPClassUID") as? String) {
                    appendPath(pix.srcFile)
                }
            }
        }

        if imageObjects.isEmpty {
            appendPath(firstPreviewPix()?.srcFile)
        }
        return orderedPaths
    }

    private static func isStructuredReport(imageObject: NSManagedObject) -> Bool {
        if isStructuredReportSOPClassUID(imageObject.value(forKeyPath: "series.seriesSOPClassUID") as? String) {
            return true
        }

        if let modality = imageObject.value(forKeyPath: "series.modality") as? String,
           modality.uppercased() == "SR" {
            return true
        }

        if imageObject.responds(to: NSSelectorFromString("sopClassUID")),
           let value = imageObject.perform(NSSelectorFromString("sopClassUID"))?.takeUnretainedValue() as? String {
            return isStructuredReportSOPClassUID(value)
        }

        return false
    }

    private static func isStructuredReportSOPClassUID(_ sopClassUID: String?) -> Bool {
        sopClassUID?.hasPrefix("1.2.840.10008.5.1.4.1.1.88") == true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

final class MetalViewerStudy {
    let title: String
    let series: [MetalViewerSeries]
    let initialSeriesIdentifier: String

    init(title: String, series: [MetalViewerSeries], initialSeriesIdentifier: String) {
        precondition(series.isEmpty == false, "MetalViewerStudy requires at least one series.")
        self.title = title
        self.series = series
        self.initialSeriesIdentifier = initialSeriesIdentifier
    }
}

struct MetalViewerSliceGeometry {
    let pix: DCMPix
    let origin: SIMD3<Double>
    let row: SIMD3<Double>
    let column: SIMD3<Double>
    let normal: SIMD3<Double>
    let width: Double
    let height: Double
    let spacingX: Double
    let spacingY: Double

    init?(pix: DCMPix) {
        self.pix = pix
        let rowColumnNormal = Self.orientationVector(for: pix)
        let row = SIMD3<Double>(Double(rowColumnNormal[0]), Double(rowColumnNormal[1]), Double(rowColumnNormal[2]))
        let column = SIMD3<Double>(Double(rowColumnNormal[3]), Double(rowColumnNormal[4]), Double(rowColumnNormal[5]))
        let normal = SIMD3<Double>(Double(rowColumnNormal[6]), Double(rowColumnNormal[7]), Double(rowColumnNormal[8]))

        let rowLength = simd_length(row)
        let columnLength = simd_length(column)
        let normalLength = simd_length(normal)
        guard rowLength > 0.000001, columnLength > 0.000001, normalLength > 0.000001 else {
            return nil
        }

        self.row = row / rowLength
        self.column = column / columnLength
        self.normal = normal / normalLength
        self.spacingX = max(Double(pix.pixelSpacingX), 0.000001)
        self.spacingY = max(Double(pix.pixelSpacingY), 0.000001)
        self.width = max(Double(pix.pwidth), 1)
        self.height = max(Double(pix.pheight), 1)
        self.origin = SIMD3<Double>(pix.originX, pix.originY, pix.originZ)
    }

    func slicePoint(from worldPoint: SIMD3<Double>) -> CGPoint {
        let delta = worldPoint - origin
        let x = (simd_dot(delta, row) + spacingX * 0.5) / spacingX
        let y = (simd_dot(delta, column) + spacingY * 0.5) / spacingY
        return CGPoint(x: x, y: y)
    }

    private static func orientationVector(for pix: DCMPix) -> [Float] {
        var vector = Array(repeating: Float(0), count: 9)
        let selector = NSSelectorFromString("orientation:")
        typealias OrientationIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>?) -> Void
        let implementation = pix.method(for: selector)
        let function = unsafeBitCast(implementation, to: OrientationIMP.self)
        function(pix, selector, &vector)
        return vector
    }
}

struct MetalViewerReferenceLine {
    let start: CGPoint
    let end: CGPoint
    let thicknessOffset: CGVector?
}

struct MetalOrientationOverlayState {
    let screenRightPatientVector: SIMD3<Float>
    let screenUpPatientVector: SIMD3<Float>
    let screenForwardPatientVector: SIMD3<Float>
    let contentRect: CGRect
    let cubeTopInset: CGFloat

    init?(
        screenRightPatientVector: SIMD3<Float>,
        screenUpPatientVector: SIMD3<Float>,
        screenForwardPatientVector: SIMD3<Float>,
        contentRect: CGRect,
        cubeTopInset: CGFloat = 12
    ) {
        guard contentRect.width > 0,
              contentRect.height > 0,
              simd_length_squared(screenRightPatientVector) > 0.000001,
              simd_length_squared(screenUpPatientVector) > 0.000001,
              simd_length_squared(screenForwardPatientVector) > 0.000001 else {
            return nil
        }

        self.screenRightPatientVector = simd_normalize(screenRightPatientVector)
        self.screenUpPatientVector = simd_normalize(screenUpPatientVector)
        self.screenForwardPatientVector = simd_normalize(screenForwardPatientVector)
        self.contentRect = contentRect
        self.cubeTopInset = cubeTopInset
    }
}

final class MetalOrientationOverlayView: NSView {
    var overlayState: MetalOrientationOverlayState? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let overlayState else { return }

        let contentRect = overlayState.contentRect.intersection(bounds)
        guard contentRect.width > 12, contentRect.height > 12 else { return }

        drawEdgeLabels(for: overlayState, in: contentRect)
        drawOrientationCube(for: overlayState, in: contentRect)
    }

    private func drawEdgeLabels(for state: MetalOrientationOverlayState, in rect: CGRect) {
        let rightVector = state.screenRightPatientVector
        let upVector = state.screenUpPatientVector
        let left = Self.orientationText(for: rightVector, inverted: true)
        let right = Self.orientationText(for: rightVector, inverted: false)
        let top = Self.orientationText(for: upVector, inverted: false)
        let bottom = Self.orientationText(for: upVector, inverted: true)

        let midX = rect.midX
        let midY = rect.midY
        let inset: CGFloat = 10

        drawLabel(left, at: CGPoint(x: rect.minX + inset, y: midY), alignment: .left, attributes: Self.edgeTextAttributes)
        drawLabel(right, at: CGPoint(x: rect.maxX - inset, y: midY), alignment: .right, attributes: Self.edgeTextAttributes)
        drawLabel(top, at: CGPoint(x: midX, y: rect.minY + inset), alignment: .center, attributes: Self.edgeTextAttributes)
        drawLabel(bottom, at: CGPoint(x: midX, y: rect.maxY - inset), alignment: .center, attributes: Self.edgeTextAttributes)
    }

    private struct CubeFace {
        let label: String
        let color: NSColor
        let normal: SIMD3<Float>
        let corners: [SIMD3<Float>]
    }

    private func drawOrientationCube(for state: MetalOrientationOverlayState, in rect: CGRect) {
        let side = min(max(min(rect.width, rect.height) * 0.18, 58), 86)
        guard rect.width > side + 24, rect.height > side + 24 else { return }

        let cubeTopInset = min(max(state.cubeTopInset, 12), max(rect.height - side - 12, 12))
        let cubeRect = CGRect(
            x: rect.maxX - side - 12,
            y: rect.minY + cubeTopInset,
            width: side,
            height: side
        )
        let center = CGPoint(x: cubeRect.midX, y: cubeRect.midY)
        let scale = Float(side * 0.34)

        let faces = Self.cubeFaces()
        let projectedFaces = faces.map { face -> (face: CubeFace, points: [CGPoint], depth: Float, facing: Float) in
            let points = face.corners.map { Self.project($0, state: state, center: center, scale: scale) }
            let depth = face.corners.reduce(Float(0)) { partial, corner in
                partial + simd_dot(corner, state.screenForwardPatientVector)
            } / Float(face.corners.count)
            let facing = simd_dot(face.normal, state.screenForwardPatientVector)
            return (face, points, depth, facing)
        }

        let visibleFaces = projectedFaces
            .filter { $0.facing < 0.18 }
            .sorted { $0.depth > $1.depth }

        for projected in visibleFaces {
            drawCubeFace(projected.face, points: projected.points, facing: projected.facing)
        }

        drawCubeOutline(state: state, center: center, scale: scale)
    }

    private func drawCubeFace(_ face: CubeFace, points: [CGPoint], facing: Float) {
        guard points.count >= 3 else { return }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.close()

        let alpha = CGFloat(min(max(0.50 + (-facing * 0.34), 0.50), 0.88))
        face.color.withAlphaComponent(alpha).setFill()
        path.fill()

        NSColor.black.withAlphaComponent(0.42).setStroke()
        path.lineWidth = 1
        path.stroke()

        let labelPoint = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x / CGFloat(points.count), y: partial.y + point.y / CGFloat(points.count))
        }
        drawLabel(face.label, at: labelPoint, alignment: .center, attributes: Self.cubeTextAttributes)
    }

    private func drawCubeOutline(state: MetalOrientationOverlayState, center: CGPoint, scale: Float) {
        let edges = [
            CubeEdge(-1, -1, -1, 1, -1, -1),
            CubeEdge(1, -1, -1, 1, 1, -1),
            CubeEdge(1, 1, -1, -1, 1, -1),
            CubeEdge(-1, 1, -1, -1, -1, -1),
            CubeEdge(-1, -1, 1, 1, -1, 1),
            CubeEdge(1, -1, 1, 1, 1, 1),
            CubeEdge(1, 1, 1, -1, 1, 1),
            CubeEdge(-1, 1, 1, -1, -1, 1),
            CubeEdge(-1, -1, -1, -1, -1, 1),
            CubeEdge(1, -1, -1, 1, -1, 1),
            CubeEdge(1, 1, -1, 1, 1, 1),
            CubeEdge(-1, 1, -1, -1, 1, 1),
        ]

        let outline = NSBezierPath()
        for edge in edges {
            let start = Self.project(edge.start, state: state, center: center, scale: scale)
            let end = Self.project(edge.end, state: state, center: center, scale: scale)
            outline.move(to: start)
            outline.line(to: end)
        }
        NSColor.black.withAlphaComponent(0.65).setStroke()
        outline.lineWidth = 1.1
        outline.stroke()
    }

    private struct CubeEdge {
        let start: SIMD3<Float>
        let end: SIMD3<Float>

        init(_ sx: Float, _ sy: Float, _ sz: Float, _ ex: Float, _ ey: Float, _ ez: Float) {
            start = SIMD3<Float>(sx, sy, sz)
            end = SIMD3<Float>(ex, ey, ez)
        }
    }

    private enum LabelAlignment {
        case left
        case right
        case center
    }

    private func drawLabel(
        _ label: String,
        at point: CGPoint,
        alignment: LabelAlignment,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard label.isEmpty == false else { return }

        let attributed = NSAttributedString(string: label, attributes: attributes)
        let size = attributed.size()
        let originX: CGFloat
        switch alignment {
        case .left:
            originX = point.x
        case .right:
            originX = point.x - size.width
        case .center:
            originX = point.x - size.width * 0.5
        }

        attributed.draw(at: CGPoint(x: originX, y: point.y - size.height * 0.5))
    }

    private static func project(
        _ point: SIMD3<Float>,
        state: MetalOrientationOverlayState,
        center: CGPoint,
        scale: Float
    ) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(simd_dot(point, state.screenRightPatientVector) * scale),
            y: center.y - CGFloat(simd_dot(point, state.screenUpPatientVector) * scale)
        )
    }

    private static func cubeFaces() -> [CubeFace] {
        let xColor = NSColor(calibratedRed: 0.10, green: 0.25, blue: 1.0, alpha: 1.0)
        let yColor = NSColor(calibratedRed: 0.00, green: 0.70, blue: 0.18, alpha: 1.0)
        let zColor = NSColor(calibratedRed: 0.92, green: 0.12, blue: 0.10, alpha: 1.0)

        return [
            CubeFace(
                label: NSLocalizedString("L", comment: "L: Left"),
                color: xColor,
                normal: SIMD3<Float>(1, 0, 0),
                corners: [
                    SIMD3<Float>(1, -1, -1),
                    SIMD3<Float>(1, 1, -1),
                    SIMD3<Float>(1, 1, 1),
                    SIMD3<Float>(1, -1, 1),
                ]
            ),
            CubeFace(
                label: NSLocalizedString("R", comment: "R: Right"),
                color: xColor,
                normal: SIMD3<Float>(-1, 0, 0),
                corners: [
                    SIMD3<Float>(-1, -1, -1),
                    SIMD3<Float>(-1, -1, 1),
                    SIMD3<Float>(-1, 1, 1),
                    SIMD3<Float>(-1, 1, -1),
                ]
            ),
            CubeFace(
                label: NSLocalizedString("P", comment: "P: Posterior"),
                color: yColor,
                normal: SIMD3<Float>(0, 1, 0),
                corners: [
                    SIMD3<Float>(-1, 1, -1),
                    SIMD3<Float>(-1, 1, 1),
                    SIMD3<Float>(1, 1, 1),
                    SIMD3<Float>(1, 1, -1),
                ]
            ),
            CubeFace(
                label: NSLocalizedString("A", comment: "A: Anterior"),
                color: yColor,
                normal: SIMD3<Float>(0, -1, 0),
                corners: [
                    SIMD3<Float>(-1, -1, -1),
                    SIMD3<Float>(1, -1, -1),
                    SIMD3<Float>(1, -1, 1),
                    SIMD3<Float>(-1, -1, 1),
                ]
            ),
            CubeFace(
                label: NSLocalizedString("S", comment: "S: Superior"),
                color: zColor,
                normal: SIMD3<Float>(0, 0, 1),
                corners: [
                    SIMD3<Float>(-1, -1, 1),
                    SIMD3<Float>(1, -1, 1),
                    SIMD3<Float>(1, 1, 1),
                    SIMD3<Float>(-1, 1, 1),
                ]
            ),
            CubeFace(
                label: NSLocalizedString("I", comment: "I: Inferior"),
                color: zColor,
                normal: SIMD3<Float>(0, 0, -1),
                corners: [
                    SIMD3<Float>(-1, -1, -1),
                    SIMD3<Float>(-1, 1, -1),
                    SIMD3<Float>(1, 1, -1),
                    SIMD3<Float>(1, -1, -1),
                ]
            ),
        ]
    }

    private static func orientationText(for vector: SIMD3<Float>, inverted: Bool) -> String {
        let oriented = inverted ? -vector : vector
        var absX = abs(vector.x)
        var absY = abs(vector.y)
        var absZ = abs(vector.z)
        let xLabel = oriented.x < 0 ? NSLocalizedString("R", comment: "R: Right") : NSLocalizedString("L", comment: "L: Left")
        let yLabel = oriented.y < 0 ? NSLocalizedString("A", comment: "A: Anterior") : NSLocalizedString("P", comment: "P: Posterior")
        let zLabel = oriented.z < 0 ? NSLocalizedString("I", comment: "I: Inferior") : NSLocalizedString("S", comment: "S: Superior")

        var result = ""
        for _ in 0..<3 {
            if absX > 0.2, absX >= absY, absX >= absZ {
                result += xLabel
                absX = 0
            } else if absY > 0.2, absY >= absX, absY >= absZ {
                result += yLabel
                absY = 0
            } else if absZ > 0.2, absZ >= absX, absZ >= absY {
                result += zLabel
                absZ = 0
            } else {
                break
            }
        }
        return result
    }

    private static let edgeTextAttributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            .shadow: shadow,
        ]
    }()

    private static let cubeTextAttributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: 15, weight: .heavy),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
    }()
}

enum MetalViewerReferenceLineCalculator {
    static func line(active: MetalViewerSliceGeometry, target: MetalViewerSliceGeometry) -> MetalViewerReferenceLine? {
        let planeAngleSin = simd_length(simd_cross(active.normal, target.normal))
        guard planeAngleSin >= Self.minimumReferenceAngleSin else {
            return nil
        }

        let activePlanePoint = dicomPoint(for: active.pix, x: 0, y: 0)
        let targetCorners = [
            dicomPoint(for: target.pix, x: 0, y: 0),
            dicomPoint(for: target.pix, x: target.width, y: 0),
            dicomPoint(for: target.pix, x: target.width, y: target.height),
            dicomPoint(for: target.pix, x: 0, y: target.height),
        ]

        let edges = [
            (targetCorners[0], targetCorners[1]),
            (targetCorners[1], targetCorners[2]),
            (targetCorners[2], targetCorners[3]),
            (targetCorners[3], targetCorners[0]),
        ]

        var intersections: [CGPoint] = []
        for edge in edges {
            guard let worldPoint = intersectSegment(edge.0, edge.1, planeNormal: active.normal, planePoint: activePlanePoint) else {
                continue
            }

            let slicePoint = target.slicePoint(from: worldPoint)
            if slicePoint.x.isFinite == false || slicePoint.y.isFinite == false {
                continue
            }

            if intersections.contains(where: { hypot($0.x - slicePoint.x, $0.y - slicePoint.y) < 0.25 }) == false {
                intersections.append(slicePoint)
            }
        }

        guard intersections.count >= 2 else {
            return nil
        }

        guard let lineEndpoints = farthestPair(in: intersections) else {
            return nil
        }

        return MetalViewerReferenceLine(
            start: lineEndpoints.start,
            end: lineEndpoints.end,
            thicknessOffset: thicknessOffset(active: active, target: target)
        )
    }

    private static func farthestPair(in points: [CGPoint]) -> (start: CGPoint, end: CGPoint)? {
        guard points.count >= 2 else {
            return nil
        }

        var result = (start: points[0], end: points[1])
        var maxDistance = hypot(points[0].x - points[1].x, points[0].y - points[1].y)

        for startIndex in 0..<(points.count - 1) {
            for endIndex in (startIndex + 1)..<points.count {
                let distance = hypot(points[startIndex].x - points[endIndex].x, points[startIndex].y - points[endIndex].y)
                if distance > maxDistance {
                    maxDistance = distance
                    result = (start: points[startIndex], end: points[endIndex])
                }
            }
        }

        return result
    }

    private static func thicknessOffset(active: MetalViewerSliceGeometry, target: MetalViewerSliceGeometry) -> CGVector? {
        let thickness = Double(active.pix.sliceThickness)
        guard thickness.isFinite, thickness > 0 else {
            return nil
        }

        let lineDirection = simd_cross(active.normal, target.normal)
        let lineDirectionLength = simd_length(lineDirection)
        guard lineDirectionLength > 0.000001 else {
            return nil
        }

        let targetLineDirection = lineDirection / lineDirectionLength
        let targetThicknessDirection = simd_normalize(simd_cross(target.normal, targetLineDirection))
        let distancePerMM = abs(simd_dot(active.normal, targetThicknessDirection))
        guard distancePerMM > 0.000001 else {
            return nil
        }

        let halfSlabDistance = (thickness * 0.5) / distancePerMM
        let offsetWorld = targetThicknessDirection * halfSlabDistance
        let dx = simd_dot(offsetWorld, target.row) / target.spacingX
        let dy = simd_dot(offsetWorld, target.column) / target.spacingY
        guard dx.isFinite, dy.isFinite else {
            return nil
        }

        return CGVector(dx: dx, dy: dy)
    }

    private static let minimumReferenceAngleSin = 0.17364817766693033

    private static func dicomPoint(for pix: DCMPix, x: Double, y: Double) -> SIMD3<Double> {
        var point = [Double](repeating: 0, count: 3)
        pix.convertDoubleX(x, pixY: y, toDICOMCoords: &point, pixelCenter: true)
        return SIMD3<Double>(point[0], point[1], point[2])
    }

    private static func intersectSegment(_ start: SIMD3<Double>, _ end: SIMD3<Double>, planeNormal: SIMD3<Double>, planePoint: SIMD3<Double>) -> SIMD3<Double>? {
        let direction = end - start
        let denominator = simd_dot(planeNormal, direction)
        if abs(denominator) < 1e-8 {
            return nil
        }

        let t = simd_dot(planeNormal, planePoint - start) / denominator
        guard t >= 0.0, t <= 1.0 else {
            return nil
        }

        return start + direction * t
    }
}
