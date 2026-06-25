import AppKit
import Dispatch
import Foundation
import Metal
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
    case measure = 5
    case tumourSeed = 6
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

enum MetalViewerMeasurementDisplaySpace: Equatable {
    case stack2D(sliceIndex: Int, pixelPoint: CGPoint)
    case mprPreview(planeRawValue: Int, baseVoxel: SIMD3<Float>)
}

struct MetalViewerMeasurementPoint: Equatable {
    let displaySpace: MetalViewerMeasurementDisplaySpace
    let dicomPoint: SIMD3<Double>
}

struct MetalViewerMeasurement: Equatable {
    let identifier: String
    var start: MetalViewerMeasurementPoint
    var end: MetalViewerMeasurementPoint
    var isActive: Bool
    var labelOffset: CGPoint = .zero

    var lengthMM: Double {
        simd_distance(start.dicomPoint, end.dicomPoint)
    }

    var lengthLabel: String {
        let millimeters = lengthMM
        if millimeters < 0.1 {
            return String(format: "%.2f \u{00B5}m", millimeters * 1000.0)
        }
        if millimeters < 10 {
            return String(format: "%.2f mm", millimeters)
        }
        return String(format: "%.2f cm", millimeters / 10.0)
    }
}

struct MetalViewerMeasurementOverlay: Equatable {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let label: String
    let labelCenter: CGPoint
    let isActive: Bool
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

private struct MetalViewerTumourSeedStoreError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class MetalViewerTumourSeedStore {
    static let shared = MetalViewerTumourSeedStore()
    static let didChangeNotification = Notification.Name("HorosMetalViewerTumourSeedsDidChange")
    static let studyIdentifierUserInfoKey = "studyIdentifier"
    static let seriesIdentifierUserInfoKey = "seriesIdentifier"

    private init() {
    }

    func seeds(for series: MetalViewerSeries) -> [MetalViewerTumourSeed] {
        seeds(forPixList: series.loadedPixList())
    }

    func seeds(forPixList pixList: [DCMPix]) -> [MetalViewerTumourSeed] {
        Self.seeds(fromBridgeDictionaries: MetalTumourSeedSRBridge.seedDictionaries(forPixList: pixList))
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

        let pixList = series.loadedPixList()
        if let message = MetalTumourSeedSRBridge.archiveSeed(
            identifier: seed.identifier,
            pixelX: seed.pixelX,
            pixelY: seed.pixelY,
            sliceIndex: seed.sliceIndex,
            dicomX: seed.dicomX,
            dicomY: seed.dicomY,
            dicomZ: seed.dicomZ,
            diameterMM: seed.diameterMM,
            createdAt: seed.createdAt,
            pixList: pixList
        ) {
            throw MetalViewerTumourSeedStoreError(message: message)
        }

        postChangeNotification(for: scope)
        return seed
    }

    func deleteSeed(identifier: String, for series: MetalViewerSeries) throws {
        let scope = series.tumourSeedScope
        if let message = MetalTumourSeedSRBridge.deleteSeed(identifier: identifier, pixList: series.loadedPixList()) {
            throw MetalViewerTumourSeedStoreError(message: message)
        }
        postChangeNotification(for: scope)
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

    private static func seeds(fromBridgeDictionaries dictionaries: Any) -> [MetalViewerTumourSeed] {
        guard let items = dictionaries as? [Any] else {
            return []
        }

        return items.compactMap { item in
            let dictionary: [String: Any]
            if let stringDictionary = item as? [String: Any] {
                dictionary = stringDictionary
            } else if let hashableDictionary = item as? [AnyHashable: Any] {
                dictionary = hashableDictionary.reduce(into: [String: Any]()) { result, pair in
                    if let key = pair.key as? String {
                        result[key] = pair.value
                    }
                }
            } else {
                return nil
            }
            return seed(fromBridgeDictionary: dictionary)
        }
    }

    private static func seed(fromBridgeDictionary dictionary: [String: Any]) -> MetalViewerTumourSeed? {
        guard let identifier = nonEmpty(dictionary["identifier"] as? String),
              let studyIdentifier = nonEmpty(dictionary["studyIdentifier"] as? String),
              let seriesIdentifier = nonEmpty(dictionary["seriesIdentifier"] as? String),
              let sliceIndex = intValue(dictionary["sliceIndex"]),
              let pixelX = doubleValue(dictionary["pixelX"]),
              let pixelY = doubleValue(dictionary["pixelY"]),
              let dicomX = doubleValue(dictionary["dicomX"]),
              let dicomY = doubleValue(dictionary["dicomY"]),
              let dicomZ = doubleValue(dictionary["dicomZ"]) else {
            return nil
        }

        let diameterMM = max(doubleValue(dictionary["diameterMM"]) ?? MetalViewerTumourSeed.defaultDiameterMM, 0.1)
        let createdAtUnix = doubleValue(dictionary["createdAtUnix"]) ?? Date().timeIntervalSince1970
        return MetalViewerTumourSeed(
            identifier: identifier,
            studyIdentifier: studyIdentifier,
            seriesIdentifier: seriesIdentifier,
            sliceIndex: sliceIndex,
            pixelX: pixelX,
            pixelY: pixelY,
            dicomX: dicomX,
            dicomY: dicomY,
            dicomZ: dicomZ,
            diameterMM: diameterMM,
            createdAt: Date(timeIntervalSince1970: createdAtUnix)
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as NSNumber:
            return value.intValue
        case let value as Int:
            return value
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func postChangeNotification(for scope: MetalViewerTumourSeedScope) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [
                Self.studyIdentifierUserInfoKey: scope.studyIdentifier,
                Self.seriesIdentifierUserInfoKey: scope.seriesIdentifier,
            ]
        )
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

final class MetalSeriesTextureCache {
    final class Entry {
        let key: String
        let texture: MTLTexture
        let dimensions: SIMD3<Int>
        let byteCount: Int

        init(key: String, texture: MTLTexture, dimensions: SIMD3<Int>) {
            self.key = key
            self.texture = texture
            self.dimensions = dimensions
            self.byteCount = max(dimensions.x, 1) * max(dimensions.y, 1) * max(dimensions.z, 1) * MemoryLayout<Float>.stride
        }
    }

    static let shared = MetalSeriesTextureCache()

    private let lock = NSLock()
    private let buildQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.horos.metalviewer.series-texture-cache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let maximumEntryCount = 3
    private let maximumCachedBytes = 1_500_000_000
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private var inFlightCompletions: [String: [(Entry?) -> Void]] = [:]
    private var cachedByteCount = 0

    private init() {}

    func key(for pixList: [DCMPix], device: MTLDevice) -> String? {
        guard pixList.isEmpty == false,
              let dimensionPix = pixList.first(where: { Int($0.pwidth) > 0 && Int($0.pheight) > 0 }) else {
            return nil
        }

        let width = Int(dimensionPix.pwidth)
        let height = Int(dimensionPix.pheight)
        guard width > 0, height > 0 else { return nil }

        let deviceKey: String
        if #available(macOS 10.13, *) {
            deviceKey = "\(device.registryID)"
        } else {
            deviceKey = device.name
        }
        var components: [String] = [
            "device=\(deviceKey)",
            "size=\(width)x\(height)x\(pixList.count)"
        ]
        components.reserveCapacity(pixList.count + 2)

        for (index, pix) in pixList.enumerated() {
            let sourcePath = nonEmptyString(pix.value(forKey: "srcFile") as? String)
                ?? nonEmptyString(pix.srcFile)
                ?? "object:\(ObjectIdentifier(pix))"
            let frameNumber = (pix.value(forKey: "frameNo") as? NSNumber)?.intValue ?? 0
            components.append("\(index):\(sourcePath):f\(frameNumber)")
        }

        return components.joined(separator: "|")
    }

    func cachedEntry(for pixList: [DCMPix], device: MTLDevice) -> Entry? {
        guard let key = key(for: pixList, device: device) else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }
        markAccessedLocked(key)
        return entry
    }

    func requestEntry(for pixList: [DCMPix], device: MTLDevice, completion: @escaping (Entry?) -> Void) {
        guard let key = key(for: pixList, device: device) else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        lock.lock()
        if let entry = entries[key] {
            markAccessedLocked(key)
            lock.unlock()
            DispatchQueue.main.async {
                completion(entry)
            }
            return
        }

        if inFlightCompletions[key] != nil {
            inFlightCompletions[key]?.append(completion)
            lock.unlock()
            return
        }

        inFlightCompletions[key] = [completion]
        lock.unlock()

        let buildPixList = pixList
        buildQueue.addOperation { [weak self] in
            guard let self else { return }
            let entry = autoreleasepool {
                self.buildEntry(key: key, pixList: buildPixList, device: device)
            }
            self.finishRequest(key: key, entry: entry)
        }
    }

    private func buildEntry(key: String, pixList: [DCMPix], device: MTLDevice) -> Entry? {
        guard pixList.isEmpty == false, let firstPix = pixList.first else { return nil }

        let start = CFAbsoluteTimeGetCurrent()
        firstPix.checkLoad()
        let width = max(Int(firstPix.pwidth), 1)
        let height = max(Int(firstPix.pheight), 1)
        let depth = max(pixList.count, 1)
        let dimensions = SIMD3<Int>(width, height, depth)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let pixelCount = width * height
        let bytesPerRow = width * MemoryLayout<Float>.stride
        let bytesPerImage = max(pixelCount, 1) * MemoryLayout<Float>.stride

        for (sliceIndex, pix) in pixList.enumerated() {
            pix.checkLoad()

            guard max(Int(pix.pwidth), 1) == width,
                  max(Int(pix.pheight), 1) == height else {
                return nil
            }

            if pix.isRGB, let rgbSource = rgbSourcePointer(for: pix) {
                var pixels = [Float](repeating: 0, count: pixelCount)
                let bytes = UnsafeRawPointer(rgbSource).assumingMemoryBound(to: UInt8.self)
                for index in 0..<pixelCount {
                    let r = Float(bytes[index * 4 + 1])
                    let g = Float(bytes[index * 4 + 2])
                    let b = Float(bytes[index * 4 + 3])
                    pixels[index] = 0.299 * r + 0.587 * g + 0.114 * b
                }
                pixels.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    texture.replace(
                        region: MTLRegionMake3D(0, 0, sliceIndex, width, height, 1),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: baseAddress,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage
                    )
                }
            } else if let fImage = pix.fImage {
                texture.replace(
                    region: MTLRegionMake3D(0, 0, sliceIndex, width, height, 1),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: fImage,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            } else {
                return nil
            }
        }

        print(String(
            format: "HOROS_METAL_TIMING MetalSeriesTextureCache build %dx%dx%d %.3f s",
            width,
            height,
            depth,
            CFAbsoluteTimeGetCurrent() - start
        ))
        return Entry(key: key, texture: texture, dimensions: dimensions)
    }

    private func finishRequest(key: String, entry: Entry?) {
        lock.lock()
        if let entry {
            entries[key] = entry
            cachedByteCount += entry.byteCount
            markAccessedLocked(key)
            trimLocked(keeping: key)
        }
        let completions = inFlightCompletions.removeValue(forKey: key) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for completion in completions {
                completion(entry)
            }
        }
    }

    private func markAccessedLocked(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimLocked(keeping newestKey: String) {
        while accessOrder.count > maximumEntryCount || (cachedByteCount > maximumCachedBytes && accessOrder.count > 1) {
            guard let key = accessOrder.first else { return }
            if key == newestKey, accessOrder.count == 1 {
                return
            }
            accessOrder.removeFirst()
            if let removed = entries.removeValue(forKey: key) {
                cachedByteCount -= removed.byteCount
            }
        }
    }

    private func nonEmptyString(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func rgbSourcePointer(for pix: DCMPix) -> UnsafeMutableRawPointer? {
        if let baseAddr = pix.baseAddr {
            return UnsafeMutableRawPointer(baseAddr)
        }

        if let fImage = pix.fImage {
            return UnsafeMutableRawPointer(fImage)
        }

        return nil
    }
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

struct MetalViewerVolumeBounds {
    let minimum: SIMD3<Int>
    let maximum: SIMD3<Int>

    var dimensions: SIMD3<Int> {
        SIMD3<Int>(
            max(maximum.x - minimum.x + 1, 1),
            max(maximum.y - minimum.y + 1, 1),
            max(maximum.z - minimum.z + 1, 1)
        )
    }

    init(minimum: SIMD3<Int>, maximum: SIMD3<Int>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    init(dimensions: SIMD3<Int>) {
        self.minimum = SIMD3<Int>(repeating: 0)
        self.maximum = SIMD3<Int>(
            max(dimensions.x - 1, 0),
            max(dimensions.y - 1, 0),
            max(dimensions.z - 1, 0)
        )
    }
}

struct MetalViewerGantryTiltGeometry {
    let dimensions: SIMD3<Int>
    let correctedVoxelToPatientMatrix: simd_float4x4
    let sourceVoxelToPatientMatrix: simd_float4x4
    let shiftPerSliceMM: Float

    var correctedSpacing: SIMD3<Float> {
        Self.voxelSpacing(from: correctedVoxelToPatientMatrix)
    }

    func requiresCorrection(minimumShiftPerSliceMM: Float = 0.01) -> Bool {
        shiftPerSliceMM > minimumShiftPerSliceMM
    }

    static func voxelSpacing(from matrix: simd_float4x4) -> SIMD3<Float> {
        let x = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let y = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let z = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        return SIMD3<Float>(
            max(simd_length(x), 0.0001),
            max(simd_length(y), 0.0001),
            max(simd_length(z), 0.0001)
        )
    }
}

enum MetalViewerGantryTiltGeometryBuilder {
    static func geometry(
        for pixList: [DCMPix],
        sourceDimensions: SIMD3<Int>,
        sourceBounds: MetalViewerVolumeBounds? = nil,
        fallbackSliceSpacing: Float? = nil
    ) -> MetalViewerGantryTiltGeometry {
        let bounds = sourceBounds ?? MetalViewerVolumeBounds(dimensions: sourceDimensions)
        let sourceMatrix = sourceVoxelToPatientMatrix(
            for: pixList,
            fallbackSliceSpacing: fallbackSliceSpacing
        )
        let orthogonalMatrix = orthogonalVoxelToPatientMatrix(
            for: pixList,
            fallbackSliceSpacing: fallbackSliceSpacing
        )
        let boundedOrthogonalMatrix = voxelMatrix(
            orthogonalMatrix,
            shiftedTo: SIMD3<Float>(
                Float(bounds.minimum.x),
                Float(bounds.minimum.y),
                Float(bounds.minimum.z)
            )
        )

        guard sourceDimensions.x > 0, sourceDimensions.y > 0, sourceDimensions.z > 0 else {
            return MetalViewerGantryTiltGeometry(
                dimensions: sourceDimensions,
                correctedVoxelToPatientMatrix: boundedOrthogonalMatrix,
                sourceVoxelToPatientMatrix: sourceMatrix,
                shiftPerSliceMM: 0
            )
        }

        let orthogonalSliceStep = SIMD3<Float>(
            orthogonalMatrix.columns.2.x,
            orthogonalMatrix.columns.2.y,
            orthogonalMatrix.columns.2.z
        )
        let sourceSliceStep = SIMD3<Float>(
            sourceMatrix.columns.2.x,
            sourceMatrix.columns.2.y,
            sourceMatrix.columns.2.z
        )
        let gantryTiltShift = simd_length(sourceSliceStep - orthogonalSliceStep)
        guard gantryTiltShift > 0.01 else {
            return MetalViewerGantryTiltGeometry(
                dimensions: bounds.dimensions,
                correctedVoxelToPatientMatrix: boundedOrthogonalMatrix,
                sourceVoxelToPatientMatrix: sourceMatrix,
                shiftPerSliceMM: gantryTiltShift
            )
        }

        let inverseOrthogonalMatrix = simd_inverse(orthogonalMatrix)
        let minX = Float(bounds.minimum.x)
        let maxX = Float(bounds.maximum.x)
        let minY = Float(bounds.minimum.y)
        let maxY = Float(bounds.maximum.y)
        let minZ = Float(bounds.minimum.z)
        let maxZ = Float(bounds.maximum.z)
        let sourceCorners = [
            SIMD3<Float>(minX, minY, minZ),
            SIMD3<Float>(maxX, minY, minZ),
            SIMD3<Float>(maxX, maxY, minZ),
            SIMD3<Float>(minX, maxY, minZ),
            SIMD3<Float>(minX, minY, maxZ),
            SIMD3<Float>(maxX, minY, maxZ),
            SIMD3<Float>(maxX, maxY, maxZ),
            SIMD3<Float>(minX, maxY, maxZ),
        ]

        let orthogonalCoordinates = sourceCorners.map { sourceCorner -> SIMD3<Float> in
            let sourceWorld = sourceMatrix * SIMD4<Float>(sourceCorner, 1)
            let orthogonalVoxel = inverseOrthogonalMatrix * sourceWorld
            return SIMD3<Float>(orthogonalVoxel.x, orthogonalVoxel.y, orthogonalVoxel.z)
        }

        var minimumVoxel = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximumVoxel = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for coordinate in orthogonalCoordinates {
            minimumVoxel = SIMD3<Float>(
                Swift.min(minimumVoxel.x, coordinate.x),
                Swift.min(minimumVoxel.y, coordinate.y),
                Swift.min(minimumVoxel.z, coordinate.z)
            )
            maximumVoxel = SIMD3<Float>(
                Swift.max(maximumVoxel.x, coordinate.x),
                Swift.max(maximumVoxel.y, coordinate.y),
                Swift.max(maximumVoxel.z, coordinate.z)
            )
        }

        let minimumIndex = SIMD3<Float>(floor(minimumVoxel.x), floor(minimumVoxel.y), floor(minimumVoxel.z))
        let maximumIndex = SIMD3<Float>(ceil(maximumVoxel.x), ceil(maximumVoxel.y), ceil(maximumVoxel.z))
        let expandedDimensions = SIMD3<Int>(
            max(Int(maximumIndex.x - minimumIndex.x) + 1, bounds.dimensions.x),
            max(Int(maximumIndex.y - minimumIndex.y) + 1, bounds.dimensions.y),
            max(Int(maximumIndex.z - minimumIndex.z) + 1, bounds.dimensions.z)
        )
        let expandedMatrix = voxelMatrix(orthogonalMatrix, shiftedTo: minimumIndex)

        return MetalViewerGantryTiltGeometry(
            dimensions: expandedDimensions,
            correctedVoxelToPatientMatrix: expandedMatrix,
            sourceVoxelToPatientMatrix: sourceMatrix,
            shiftPerSliceMM: gantryTiltShift
        )
    }

    static func sourceVoxelToPatientMatrix(
        for pixList: [DCMPix],
        fallbackSliceSpacing: Float? = nil
    ) -> simd_float4x4 {
        guard let firstPix = pixList.first,
              let geometry = MetalViewerSliceGeometry(pix: firstPix) else {
            return matrix_identity_float4x4
        }

        let row = simd_normalize(SIMD3<Float>(Float(geometry.row.x), Float(geometry.row.y), Float(geometry.row.z)))
        let column = simd_normalize(SIMD3<Float>(Float(geometry.column.x), Float(geometry.column.y), Float(geometry.column.z)))
        let fallbackNormal = simd_normalize(simd_cross(row, column))

        let sliceStep: SIMD3<Float>
        if pixList.count > 1, let lastPix = pixList.last {
            let delta = SIMD3<Float>(
                Float(lastPix.originX - firstPix.originX),
                Float(lastPix.originY - firstPix.originY),
                Float(lastPix.originZ - firstPix.originZ)
            ) / Float(max(pixList.count - 1, 1))
            sliceStep = simd_length(delta) > 0.0001 ? delta : fallbackNormal * sliceSpacing(for: firstPix, fallback: fallbackSliceSpacing)
        } else {
            sliceStep = fallbackNormal * sliceSpacing(for: firstPix, fallback: fallbackSliceSpacing)
        }

        let rowStep = row * Float(max(firstPix.pixelSpacingX, 0.000001))
        let columnStep = column * Float(max(firstPix.pixelSpacingY, 0.000001))
        let origin = SIMD3<Float>(Float(firstPix.originX), Float(firstPix.originY), Float(firstPix.originZ))

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }

    static func orthogonalVoxelToPatientMatrix(
        for pixList: [DCMPix],
        fallbackSliceSpacing: Float? = nil
    ) -> simd_float4x4 {
        guard let firstPix = pixList.first,
              let geometry = MetalViewerSliceGeometry(pix: firstPix) else {
            return matrix_identity_float4x4
        }

        let row = simd_normalize(SIMD3<Float>(Float(geometry.row.x), Float(geometry.row.y), Float(geometry.row.z)))
        let column = simd_normalize(SIMD3<Float>(Float(geometry.column.x), Float(geometry.column.y), Float(geometry.column.z)))
        let normal = simd_normalize(simd_cross(row, column))

        let sliceStep: SIMD3<Float>
        if pixList.count > 1, let lastPix = pixList.last {
            let delta = SIMD3<Float>(
                Float(lastPix.originX - firstPix.originX),
                Float(lastPix.originY - firstPix.originY),
                Float(lastPix.originZ - firstPix.originZ)
            ) / Float(max(pixList.count - 1, 1))
            let normalSpacing = simd_dot(delta, normal)
            sliceStep = abs(normalSpacing) > 0.0001
                ? normal * normalSpacing
                : normal * sliceSpacing(for: firstPix, fallback: fallbackSliceSpacing)
        } else {
            sliceStep = normal * sliceSpacing(for: firstPix, fallback: fallbackSliceSpacing)
        }

        let rowStep = row * Float(max(firstPix.pixelSpacingX, 0.000001))
        let columnStep = column * Float(max(firstPix.pixelSpacingY, 0.000001))
        let origin = SIMD3<Float>(Float(firstPix.originX), Float(firstPix.originY), Float(firstPix.originZ))

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }

    private static func sliceSpacing(for pix: DCMPix, fallback: Float?) -> Float {
        if let fallback, fallback > 0.000001 {
            return fallback
        }

        let candidates = [pix.sliceInterval, pix.spacingBetweenSlices, pix.sliceThickness]
        let spacing = candidates.first(where: { abs($0) > 0.000001 }) ?? 1.0
        return Float(abs(spacing))
    }

    private static func voxelMatrix(_ matrix: simd_float4x4, shiftedTo voxel: SIMD3<Float>) -> simd_float4x4 {
        let origin = matrix * SIMD4<Float>(voxel, 1)
        return simd_float4x4(
            matrix.columns.0,
            matrix.columns.1,
            matrix.columns.2,
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }
}

enum MetalViewerGantryTiltCPUResampler {
    static func resample(
        sourceSlices: [UnsafeMutablePointer<Float>?],
        sourceDimensions: SIMD3<Int>,
        outputDimensions: SIMD3<Int>,
        outputVoxelToPatientMatrix: simd_float4x4,
        sourceVoxelToPatientMatrix: simd_float4x4,
        backgroundValue: Float
    ) -> [Float] {
        let width = max(outputDimensions.x, 1)
        let height = max(outputDimensions.y, 1)
        let depth = max(outputDimensions.z, 1)
        let outputPlaneSize = max(width * height, 1)
        let sourceWidth = max(sourceDimensions.x, 1)
        let sourceHeight = max(sourceDimensions.y, 1)
        let sourceDepth = max(sourceDimensions.z, 1)
        let outputVoxelToSourceVoxelMatrix = simd_inverse(sourceVoxelToPatientMatrix) * outputVoxelToPatientMatrix
        let xStep = SIMD3<Float>(
            outputVoxelToSourceVoxelMatrix.columns.0.x,
            outputVoxelToSourceVoxelMatrix.columns.0.y,
            outputVoxelToSourceVoxelMatrix.columns.0.z
        )
        let yStep = SIMD3<Float>(
            outputVoxelToSourceVoxelMatrix.columns.1.x,
            outputVoxelToSourceVoxelMatrix.columns.1.y,
            outputVoxelToSourceVoxelMatrix.columns.1.z
        )
        let zStep = SIMD3<Float>(
            outputVoxelToSourceVoxelMatrix.columns.2.x,
            outputVoxelToSourceVoxelMatrix.columns.2.y,
            outputVoxelToSourceVoxelMatrix.columns.2.z
        )
        let origin = SIMD3<Float>(
            outputVoxelToSourceVoxelMatrix.columns.3.x,
            outputVoxelToSourceVoxelMatrix.columns.3.y,
            outputVoxelToSourceVoxelMatrix.columns.3.z
        )
        var output = [Float](repeating: backgroundValue, count: outputPlaneSize * depth)

        func sample(_ x: Float, _ y: Float, _ z: Float) -> Float {
            guard x >= 0, y >= 0, z >= 0,
                  x <= Float(sourceWidth - 1),
                  y <= Float(sourceHeight - 1),
                  z <= Float(sourceDepth - 1) else {
                return backgroundValue
            }

            let x0 = min(max(Int(floor(x)), 0), sourceWidth - 1)
            let y0 = min(max(Int(floor(y)), 0), sourceHeight - 1)
            let z0 = min(max(Int(floor(z)), 0), sourceDepth - 1)
            let x1 = min(x0 + 1, sourceWidth - 1)
            let y1 = min(y0 + 1, sourceHeight - 1)
            let z1 = min(z0 + 1, sourceDepth - 1)
            let tx = x - Float(x0)
            let ty = y - Float(y0)
            let tz = z - Float(z0)

            func sampleSlice(_ sx: Int, _ sy: Int, _ sz: Int) -> Float {
                guard sz >= 0,
                      sz < sourceSlices.count,
                      let pixels = sourceSlices[sz] else {
                    return backgroundValue
                }
                return pixels[sy * sourceWidth + sx]
            }

            let c000 = sampleSlice(x0, y0, z0)
            let c100 = sampleSlice(x1, y0, z0)
            let c010 = sampleSlice(x0, y1, z0)
            let c110 = sampleSlice(x1, y1, z0)
            let c001 = sampleSlice(x0, y0, z1)
            let c101 = sampleSlice(x1, y0, z1)
            let c011 = sampleSlice(x0, y1, z1)
            let c111 = sampleSlice(x1, y1, z1)

            let c00 = c000 * (1 - tx) + c100 * tx
            let c10 = c010 * (1 - tx) + c110 * tx
            let c01 = c001 * (1 - tx) + c101 * tx
            let c11 = c011 * (1 - tx) + c111 * tx
            let c0 = c00 * (1 - ty) + c10 * ty
            let c1 = c01 * (1 - ty) + c11 * ty
            return c0 * (1 - tz) + c1 * tz
        }

        output.withUnsafeMutableBufferPointer { outputBuffer in
            guard let outputBase = outputBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: depth) { z in
                let zBase = origin + zStep * Float(z)
                let outputZOffset = z * outputPlaneSize
                for y in 0..<height {
                    var sourceVoxel = zBase + yStep * Float(y)
                    var outputIndex = outputZOffset + y * width
                    for _ in 0..<width {
                        outputBase[outputIndex] = sample(sourceVoxel.x, sourceVoxel.y, sourceVoxel.z)
                        sourceVoxel += xStep
                        outputIndex += 1
                    }
                }
            }
        }
        return output
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
