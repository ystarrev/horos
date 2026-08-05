import AppKit
import Dispatch
import Foundation
import Metal
import simd

enum MetalViewerDiagnostics {
    private static let timingLogDefaultsKey = "HorosMetalViewerTimingLogEnabled"
    private static let registrationTimingLogDefaultsKey = "HorosMetalViewerRegistrationTimingLogEnabled"

    static var isTimingLogEnabled: Bool {
        bool(forKey: timingLogDefaultsKey, defaultValue: false)
    }

    static var isRegistrationTimingLogEnabled: Bool {
        isTimingLogEnabled || bool(forKey: registrationTimingLogDefaultsKey, defaultValue: false)
    }

    static func timingLog(_ message: String) {
        guard isTimingLogEnabled else { return }
        emit("HOROS_METAL_TIMING \(message)")
    }

    static func timingLog(_ message: String, since start: CFAbsoluteTime) {
        guard isTimingLogEnabled else { return }
        emit(String(format: "HOROS_METAL_TIMING %@ %.3f s", message, CFAbsoluteTimeGetCurrent() - start))
    }

    static func timingLog(format: String, _ arguments: CVarArg...) {
        guard isTimingLogEnabled else { return }
        emit(String(format: "HOROS_METAL_TIMING " + format, arguments: arguments))
    }

    static func registrationTimingLog(_ message: String) {
        guard isRegistrationTimingLogEnabled else { return }
        emit("HOROS_METAL_REGISTRATION_TIMING \(message)")
    }

    static func registrationTimingLog(_ message: String, since start: CFAbsoluteTime) {
        guard isRegistrationTimingLogEnabled else { return }
        emit(String(format: "HOROS_METAL_REGISTRATION_TIMING %@ %.3f s", message, CFAbsoluteTimeGetCurrent() - start))
    }

    static func registrationTimingLog(format: String, _ arguments: CVarArg...) {
        guard isRegistrationTimingLogEnabled else { return }
        emit(String(format: "HOROS_METAL_REGISTRATION_TIMING " + format, arguments: arguments))
    }

    /// One concise profile is emitted for every completed registration so a
    /// performance run does not depend on a hidden diagnostics preference.
    static func registrationProfileLog(format: String, _ arguments: CVarArg...) {
        emit(String(format: "HOROS_METAL_REGISTRATION_PROFILE " + format, arguments: arguments))
    }

    private static func emit(_ message: String) {
        NSLog("%@", message)
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}

enum MetalTextureLimits {
    static let maximum3DTextureDimension = 2_048

    static func supports3DTexture(width: Int, height: Int, depth: Int) -> Bool {
        width > 0 && height > 0 && depth > 0
            && width <= maximum3DTextureDimension
            && height <= maximum3DTextureDimension
            && depth <= maximum3DTextureDimension
    }
}

enum MetalViewerMouseButton: Int, CaseIterable, Hashable {
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

enum MetalViewerMouseModifier: String, CaseIterable, Hashable {
    case none
    case control
    case command
    case option
    case shift

    init(modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) {
            self = .control
        } else if flags.contains(.command) {
            self = .command
        } else if flags.contains(.option) {
            self = .option
        } else if flags.contains(.shift) {
            self = .shift
        } else {
            self = .none
        }
    }
}

struct MetalViewerMouseToolAssignments: Equatable {
    private static let defaultsKey = "HorosMetalViewerMouseToolAssignments"

    private struct Binding: Hashable {
        let button: MetalViewerMouseButton
        let modifier: MetalViewerMouseModifier

        var defaultsKey: String {
            "\(modifier.rawValue).\(button.rawValue)"
        }
    }

    private var assignedTools: [Binding: MetalViewerMouseTool] = [:]

    init(userDefaults: UserDefaults = .standard) {
        guard let storedAssignments = userDefaults.dictionary(forKey: Self.defaultsKey) else {
            return
        }
        for modifier in MetalViewerMouseModifier.allCases {
            for button in MetalViewerMouseButton.allCases {
                let binding = Binding(button: button, modifier: modifier)
                guard let rawValue = (storedAssignments[binding.defaultsKey] as? NSNumber)?.intValue,
                      let tool = MetalViewerMouseTool(rawValue: rawValue) else {
                    continue
                }
                assignedTools[binding] = tool
            }
        }
    }

    func tool(for button: MetalViewerMouseButton) -> MetalViewerMouseTool {
        tool(for: button, modifier: .none)
    }

    func tool(
        for button: MetalViewerMouseButton,
        modifier: MetalViewerMouseModifier
    ) -> MetalViewerMouseTool {
        if let assignedTool = assignedTools[Binding(button: button, modifier: modifier)] {
            return assignedTool
        }
        if modifier == .shift {
            return .pan
        }
        switch button {
        case .left:
            return .windowLevel
        case .right:
            return .zoom
        }
    }

    func resolvedTool(
        for button: MetalViewerMouseButton,
        modifierFlags: NSEvent.ModifierFlags
    ) -> MetalViewerMouseTool {
        tool(
            for: button,
            modifier: MetalViewerMouseModifier(modifierFlags: modifierFlags)
        )
    }

    mutating func setTool(
        _ tool: MetalViewerMouseTool,
        for button: MetalViewerMouseButton,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        let modifier = MetalViewerMouseModifier(modifierFlags: modifierFlags)
        assignedTools[Binding(button: button, modifier: modifier)] = tool
    }

    func save(userDefaults: UserDefaults = .standard) {
        let storedAssignments = assignedTools.reduce(into: [String: Int]()) { result, assignment in
            result[assignment.key.defaultsKey] = assignment.value.rawValue
        }
        userDefaults.set(storedAssignments, forKey: Self.defaultsKey)
    }
}

enum MetalViewerScoutPlacement: Int, CaseIterable {
    case left = 0
    case bottom = 1

    static let defaultsKey = "HorosMetalViewerScoutPlacement"
    static let didChangeNotification = Notification.Name("HorosMetalViewerScoutPlacementDidChange")
    static let defaultPlacement: MetalViewerScoutPlacement = .left

    static var saved: MetalViewerScoutPlacement {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil else {
            return defaultPlacement
        }
        return MetalViewerScoutPlacement(rawValue: defaults.integer(forKey: defaultsKey)) ?? defaultPlacement
    }

    static func save(_ placement: MetalViewerScoutPlacement) {
        guard placement != saved else { return }
        UserDefaults.standard.set(placement.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: placement)
    }

    var title: String {
        switch self {
        case .left:
            return NSLocalizedString("Left", comment: "")
        case .bottom:
            return NSLocalizedString("Bottom", comment: "")
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

enum MetalViewerAutomaticWindowLevel {
    static func window(for pix: DCMPix) -> MetalViewerWindowLevel? {
        guard let storedPixels = MetalStoredInt16PixelData(pix: pix) else { return nil }
        return window(for: storedPixels, modality: pix.modalityString)
    }

    static func window(
        for storedPixels: MetalStoredInt16PixelData,
        modality modalityString: String?
    ) -> MetalViewerWindowLevel? {
        var samples: [Float] = []
        samples.reserveCapacity(5_000)

        let modality = modalityString?.uppercased() ?? ""

        let pixelWidth = storedPixels.width
        let pixelHeight = storedPixels.height
        let pixelCount = pixelWidth * pixelHeight
        guard pixelCount > 0 else { return nil }

        let cornerIndexes = [
            0,
            max(pixelWidth - 1, 0),
            max((pixelHeight - 1) * pixelWidth, 0),
            max(pixelCount - 1, 0),
        ]
        let cornerValues = cornerIndexes
            .compactMap { storedPixels.rescaledValue(at: $0) }
            .filter { $0.isFinite }
        let backgroundValue = repeatedCornerValue(in: cornerValues)

        let pixelStep = max(1, pixelCount / 5_000)
        var index = 0
        while index < pixelCount {
            guard let value = storedPixels.rescaledValue(at: index) else {
                index += pixelStep
                continue
            }
            let isBackground = backgroundValue.map {
                abs(value - $0) <= max(abs($0) * 0.00001, 0.0001)
            } ?? false
            let isZeroBackground = modality == "MR" && abs(value) <= Float.ulpOfOne
            if value.isFinite && isBackground == false && isZeroBackground == false {
                samples.append(value)
            }
            index += pixelStep
        }

        guard samples.count >= 32 else { return nil }
        samples.sort()

        let percentileRange: (low: Float, high: Float)
        switch modality {
        case "US", "XA", "RF":
            percentileRange = (0.01, 0.99)
        default:
            percentileRange = (0.005, 0.995)
        }

        let lowIndex = percentileIndex(percentileRange.low, count: samples.count)
        let highIndex = percentileIndex(percentileRange.high, count: samples.count)
        var low = samples[lowIndex]
        let high = samples[max(highIndex, lowIndex)]
        if (modality == "PT" || modality == "NM") && low >= 0 {
            low = 0
        }
        let width = max(high - low, 1)
        return MetalViewerWindowLevel(level: low + width * 0.5, width: width)
    }

    private static func repeatedCornerValue(in values: [Float]) -> Float? {
        guard values.count >= 2 else { return nil }

        var bestValue: Float?
        var bestCount = 1
        for candidate in values {
            let tolerance = max(abs(candidate) * 0.00001, 0.0001)
            let count = values.reduce(into: 0) { result, value in
                if abs(value - candidate) <= tolerance {
                    result += 1
                }
            }
            if count > bestCount {
                bestValue = candidate
                bestCount = count
            }
        }
        return bestValue
    }

    private static func percentileIndex(_ percentile: Float, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        return min(max(Int((Float(count - 1) * clamped).rounded()), 0), count - 1)
    }
}

struct MetalViewerWindowLevelState {
    var defaultWindow: MetalViewerWindowLevel?
    var customWindow: MetalViewerWindowLevel?
}

struct MetalViewerTransferFunctionState {
    var clutName = NSLocalizedString("No CLUT", comment: "")
    var opacityName = NSLocalizedString("Linear Table", comment: "")
}

enum MetalSeriesTextureKind: UInt32 {
    case rescaledFloat = 1
    case storedInt16Signed = 2
    case storedInt16Unsigned = 3
}

struct MetalStoredInt16PixelData {
    let data: Data
    let width: Int
    let height: Int
    let bitsStored: Int
    let rescaleSlope: Float
    let rescaleIntercept: Float
    let isSigned: Bool
    let pixelSpacing: SIMD2<Float>
    let defaultWindow: MetalViewerWindowLevel?

    var textureKind: MetalSeriesTextureKind {
        isSigned ? .storedInt16Signed : .storedInt16Unsigned
    }

    var pixelFormat: MTLPixelFormat {
        isSigned ? .r16Sint : .r16Uint
    }

    var byteCount: Int {
        max(width * height, 1) * MemoryLayout<UInt16>.stride
    }

    var bytesPerRow: Int {
        width * MemoryLayout<UInt16>.stride
    }

    var inferredWindow: MetalViewerWindowLevel {
        if let defaultWindow {
            return defaultWindow
        }

        return storedRangeWindow
    }

    var storedRangeWindow: MetalViewerWindowLevel {

        let bits = min(max(bitsStored, 1), 30)
        let storedMinimum: Float
        let storedMaximum: Float
        if isSigned {
            let magnitude = Float(1 << max(bits - 1, 0))
            storedMinimum = -magnitude
            storedMaximum = magnitude - 1
        } else {
            storedMinimum = 0
            storedMaximum = Float((1 << bits) - 1)
        }

        let value0 = storedMinimum * rescaleSlope + rescaleIntercept
        let value1 = storedMaximum * rescaleSlope + rescaleIntercept
        let low = min(value0, value1)
        let high = max(value0, value1)
        let width = max(high - low, 1)
        return MetalViewerWindowLevel(level: low + width * 0.5, width: width)
    }

    func rescaledValue(at index: Int) -> Float? {
        guard index >= 0, index < width * height else { return nil }

        let byteOffset = index * MemoryLayout<UInt16>.stride
        guard byteOffset + 1 < data.count else { return nil }

        let raw = UInt16(data[byteOffset]) | (UInt16(data[byteOffset + 1]) << 8)
        let storedValue = isSigned
            ? Float(Int16(bitPattern: raw))
            : Float(raw)
        return storedValue * rescaleSlope + rescaleIntercept
    }

    func rescaledValue(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return rescaledValue(at: y * width + x)
    }

    init?(pix: DCMPix) {
        guard let path = pix.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              let frame = SwiftDICOMReader.storedPixelFrame(
                contentsOfFile: path,
                frameIndex: max(Int(pix.frameNo), 0)
              ) else {
            return nil
        }
        self.init(dicomFrame: frame)
    }

    fileprivate init(dicomFrame frame: SwiftDICOMStoredPixelFrame) {
        data = frame.data
        width = frame.width
        height = frame.height
        bitsStored = frame.bitsStored
        rescaleSlope = frame.rescaleSlope
        rescaleIntercept = frame.rescaleIntercept
        isSigned = frame.isSigned
        pixelSpacing = SIMD2<Float>(frame.pixelSpacingX, frame.pixelSpacingY)
        defaultWindow = (frame.windowWidth ?? 0) > 0
            ? MetalViewerWindowLevel(level: frame.windowLevel ?? 0, width: frame.windowWidth ?? 1)
            : nil
    }

    fileprivate init(
        data: Data,
        width: Int,
        height: Int,
        bitsStored: Int,
        rescaleSlope: Float,
        rescaleIntercept: Float,
        isSigned: Bool,
        pixelSpacing: SIMD2<Float>,
        defaultWindow: MetalViewerWindowLevel?
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.bitsStored = bitsStored
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.isSigned = isSigned
        self.pixelSpacing = pixelSpacing
        self.defaultWindow = defaultWindow
    }

    func matchesVolumeEncoding(of firstSlice: MetalStoredInt16PixelData) -> Bool {
        isSigned == firstSlice.isSigned
            && Self.rescaleValuesMatch(rescaleSlope, firstSlice.rescaleSlope)
            && Self.rescaleValuesMatch(rescaleIntercept, firstSlice.rescaleIntercept)
    }

    private static func rescaleValuesMatch(_ lhs: Float, _ rhs: Float) -> Bool {
        let tolerance = max(max(abs(lhs), abs(rhs)), 1) * 0.0001
        return abs(lhs - rhs) <= tolerance
    }
}

private final class MetalSwiftDICOMSeriesPixelDecoder {
    private let reader: SwiftDICOMReader
    private let sourcePath: String

    init?(pixList: [DCMPix]) {
        guard let firstPix = pixList.first,
              pixList.count > 1,
              let path = firstPix.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              pixList.allSatisfy({ $0.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines) == path }),
              let reader = try? SwiftDICOMReader.cached(contentsOfFile: path),
              reader.numberOfFrames > 1 else {
            return nil
        }
        self.reader = reader
        self.sourcePath = path
    }

    func decode(pix: DCMPix) -> MetalStoredInt16PixelData? {
        guard pix.srcFile?.trimmingCharacters(in: .whitespacesAndNewlines) == sourcePath,
              let frame = try? reader.storedPixelFrame(at: max(Int(pix.frameNo), 0)) else {
            return nil
        }
        return MetalStoredInt16PixelData(dicomFrame: frame)
    }
}

final class MetalSeriesTextureCache {
    private struct SliceDimensions {
        let width: Int
        let height: Int
    }

    private final class ParallelSliceBuildState: @unchecked Sendable {
        private let lock = NSLock()
        private var failedSliceIndexes = Set<Int>()

        var failures: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return failedSliceIndexes.sorted()
        }

        func fail(sliceIndex: Int) {
            lock.lock()
            failedSliceIndexes.insert(sliceIndex)
            lock.unlock()
        }

        func upload(sliceIndex: Int, _ body: () -> Bool) {
            lock.lock()
            defer { lock.unlock() }
            if body() == false {
                failedSliceIndexes.insert(sliceIndex)
            }
        }
    }

    struct DecodedSliceSeed {
        let pix: DCMPix
        let index: Int
        let pixels: MetalStoredInt16PixelData
    }

    final class Entry {
        let key: String
        let texture: MTLTexture
        let dimensions: SIMD3<Int>
        let byteCount: Int
        let textureKind: MetalSeriesTextureKind
        let rescaleSlope: Float
        let rescaleIntercept: Float
        let defaultWindow: MetalViewerWindowLevel
        let fullDynamicWindow: MetalViewerWindowLevel

        init(
            key: String,
            texture: MTLTexture,
            dimensions: SIMD3<Int>,
            textureKind: MetalSeriesTextureKind,
            bytesPerVoxel: Int,
            rescaleSlope: Float = 1,
            rescaleIntercept: Float = 0,
            defaultWindow: MetalViewerWindowLevel = MetalViewerWindowLevel(level: 0, width: 1),
            fullDynamicWindow: MetalViewerWindowLevel = MetalViewerWindowLevel(level: 0, width: 1)
        ) {
            self.key = key
            self.texture = texture
            self.dimensions = dimensions
            self.textureKind = textureKind
            self.rescaleSlope = rescaleSlope
            self.rescaleIntercept = rescaleIntercept
            self.defaultWindow = defaultWindow
            self.fullDynamicWindow = fullDynamicWindow
            self.byteCount = max(dimensions.x, 1) * max(dimensions.y, 1) * max(dimensions.z, 1) * max(bytesPerVoxel, 1)
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
    private let maximumUnavailableStoredInt16Count = 128
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private var inFlightCompletions: [String: [(Entry?) -> Void]] = [:]
    private var unavailableStoredInt16Keys: Set<String> = []
    private var unavailableStoredInt16Order: [String] = []
    private var cachedByteCount = 0

    private init() {}

    func key(
        for pixList: [DCMPix],
        device: MTLDevice
    ) -> String? {
        guard pixList.isEmpty == false,
              let dimensions = pixList.compactMap({ dimensionsWithoutLoading(for: $0) }).first else {
            return nil
        }

        let width = dimensions.width
        let height = dimensions.height
        guard width > 0, height > 0 else { return nil }

        let deviceKey: String
        if #available(macOS 10.13, *) {
            deviceKey = "\(device.registryID)"
        } else {
            deviceKey = device.name
        }
        var components: [String] = [
            "device=\(deviceKey)",
            "storage=stored-int16",
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

    func cachedEntry(
        for pixList: [DCMPix],
        device: MTLDevice
    ) -> Entry? {
        guard let key = key(for: pixList, device: device) else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }
        markAccessedLocked(key)
        return entry
    }

    func isEntryKnownUnavailable(
        for pixList: [DCMPix],
        device: MTLDevice
    ) -> Bool {
        guard let key = key(for: pixList, device: device) else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        return unavailableStoredInt16Keys.contains(key)
    }

    func requestEntry(
        for pixList: [DCMPix],
        device: MTLDevice,
        decodedSliceSeed: DecodedSliceSeed? = nil,
        completion: @escaping (Entry?) -> Void
    ) {
        guard let key = key(for: pixList, device: device) else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        lock.lock()
        if unavailableStoredInt16Keys.contains(key) {
            lock.unlock()
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

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
                self.buildEntry(
                    key: key,
                    pixList: buildPixList,
                    device: device,
                    decodedSliceSeed: decodedSliceSeed
                )
            }
            self.finishRequest(key: key, entry: entry)
        }
    }

    private func buildEntry(
        key: String,
        pixList: [DCMPix],
        device: MTLDevice,
        decodedSliceSeed: DecodedSliceSeed?
    ) -> Entry? {
        buildStoredInt16Entry(
            key: key,
            pixList: pixList,
            device: device,
            decodedSliceSeed: decodedSliceSeed
        )
    }

    private func buildStoredInt16Entry(
        key: String,
        pixList: [DCMPix],
        device: MTLDevice,
        decodedSliceSeed: DecodedSliceSeed?
    ) -> Entry? {
        let seriesDecoder = MetalSwiftDICOMSeriesPixelDecoder(pixList: pixList)
        let decodedSliceSeed = decodedSliceSeed.flatMap { seed -> DecodedSliceSeed? in
            guard pixList.indices.contains(seed.index),
                  pixList[seed.index] === seed.pix else {
                return nil
            }
            return seed
        }

        guard pixList.isEmpty == false,
              let firstPix = pixList.first,
              let firstDimensions = dimensionsWithoutLoading(for: firstPix),
              let firstSlice = decodedStoredInt16Slice(
                at: 0,
                in: pixList,
                seriesDecoder: seriesDecoder,
                decodedSliceSeed: decodedSliceSeed
              ) else {
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        let width = max(firstDimensions.width, 1)
        let height = max(firstDimensions.height, 1)
        let depth = max(pixList.count, 1)
        guard firstSlice.width == width, firstSlice.height == height else { return nil }
        guard canCreateVolumeTexture(
            width: width,
            height: height,
            depth: depth,
            bytesPerVoxel: MemoryLayout<UInt16>.stride
        ) else {
            return nil
        }

        let dimensions = SIMD3<Int>(width, height, depth)
        _ = MetalViewerSliceGeometry(pix: firstPix)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = firstSlice.pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = firstSlice.bytesPerRow
        let bytesPerImage = firstSlice.byteCount

        guard uploadStoredInt16Slice(
            firstSlice,
            sliceIndex: 0,
            width: width,
            height: height,
            texture: texture,
            bytesPerRow: bytesPerRow,
            bytesPerImage: bytesPerImage
        ) else {
            return nil
        }

        let remainingSlicesLoaded: Bool
        if seriesDecoder == nil, pixList.count > 2 {
            remainingSlicesLoaded = loadStoredInt16SlicesConcurrently(
                pixList: pixList,
                decodedSliceSeed: decodedSliceSeed,
                firstSlice: firstSlice,
                texture: texture,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        } else {
            remainingSlicesLoaded = loadStoredInt16SlicesSerially(
                pixList: pixList,
                seriesDecoder: seriesDecoder,
                decodedSliceSeed: decodedSliceSeed,
                firstSlice: firstSlice,
                texture: texture,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }
        guard remainingSlicesLoaded else { return nil }

        MetalViewerDiagnostics.timingLog(
            format: "MetalSeriesTextureCache buildStoredInt16 %dx%dx%d %.3f s",
            width,
            height,
            depth,
            CFAbsoluteTimeGetCurrent() - start
        )
        return Entry(
            key: key,
            texture: texture,
            dimensions: dimensions,
            textureKind: firstSlice.textureKind,
            bytesPerVoxel: MemoryLayout<UInt16>.stride,
            rescaleSlope: firstSlice.rescaleSlope,
            rescaleIntercept: firstSlice.rescaleIntercept,
            defaultWindow: firstSlice.inferredWindow,
            fullDynamicWindow: firstSlice.storedRangeWindow
        )
    }

    private func loadStoredInt16SlicesSerially(
        pixList: [DCMPix],
        seriesDecoder: MetalSwiftDICOMSeriesPixelDecoder?,
        decodedSliceSeed: DecodedSliceSeed?,
        firstSlice: MetalStoredInt16PixelData,
        texture: MTLTexture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerImage: Int
    ) -> Bool {
        for sliceIndex in 1..<pixList.count {
            let pix = pixList[sliceIndex]
            guard let sliceDimensions = dimensionsWithoutLoading(for: pix),
                  max(sliceDimensions.width, 1) == width,
                  max(sliceDimensions.height, 1) == height,
                  let slice = decodedStoredInt16Slice(
                    at: sliceIndex,
                    in: pixList,
                    seriesDecoder: seriesDecoder,
                    decodedSliceSeed: decodedSliceSeed
                  ),
                  slice.width == width,
                  slice.height == height,
                  slice.matchesVolumeEncoding(of: firstSlice),
                  uploadStoredInt16Slice(
                    slice,
                    sliceIndex: sliceIndex,
                    width: width,
                    height: height,
                    texture: texture,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                  ) else {
                return false
            }
        }
        return true
    }

    private func loadStoredInt16SlicesConcurrently(
        pixList: [DCMPix],
        decodedSliceSeed: DecodedSliceSeed?,
        firstSlice: MetalStoredInt16PixelData,
        texture: MTLTexture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerImage: Int
    ) -> Bool {
        let sliceCount = pixList.count - 1
        let workerCount = min(
            min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1), 4),
            sliceCount
        )
        guard workerCount > 1 else {
            return loadStoredInt16SlicesSerially(
                pixList: pixList,
                seriesDecoder: nil,
                decodedSliceSeed: decodedSliceSeed,
                firstSlice: firstSlice,
                texture: texture,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        let state = ParallelSliceBuildState()
        let queue = OperationQueue()
        queue.name = "org.horos.metalviewer.stored-volume-loader"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = workerCount

        for sliceIndex in 1..<pixList.count {
            let pix = pixList[sliceIndex]
            queue.addOperation { [weak self] in
                autoreleasepool {
                    guard let self else { return }
                    guard let sliceDimensions = self.dimensionsWithoutLoading(for: pix),
                          max(sliceDimensions.width, 1) == width,
                          max(sliceDimensions.height, 1) == height,
                          let slice = self.decodedStoredInt16Slice(
                            at: sliceIndex,
                            in: pixList,
                            seriesDecoder: nil,
                            decodedSliceSeed: decodedSliceSeed
                          ),
                          slice.width == width,
                          slice.height == height,
                          slice.matchesVolumeEncoding(of: firstSlice) else {
                        state.fail(sliceIndex: sliceIndex)
                        return
                    }

                    state.upload(sliceIndex: sliceIndex) {
                        self.uploadStoredInt16Slice(
                            slice,
                            sliceIndex: sliceIndex,
                            width: width,
                            height: height,
                            texture: texture,
                            bytesPerRow: bytesPerRow,
                            bytesPerImage: bytesPerImage
                        )
                    }
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        let failedSliceIndexes = state.failures
        guard failedSliceIndexes.isEmpty == false else { return true }

        // Retry only failed file reads serially before deciding that a source
        // slice is genuinely missing or malformed.
        NSLog(
            "%@",
            "MetalSeriesTextureCache: retrying \(failedSliceIndexes.count) DICOM slice(s) serially"
        )
        var missingSliceIndexes = [Int]()
        for sliceIndex in failedSliceIndexes {
            let pix = pixList[sliceIndex]
            let sliceDimensions = dimensionsWithoutLoading(for: pix)
            let slice = decodedStoredInt16Slice(
                at: sliceIndex,
                in: pixList,
                seriesDecoder: nil,
                decodedSliceSeed: decodedSliceSeed
            )
            let dimensionsMatch = sliceDimensions.map {
                max($0.width, 1) == width && max($0.height, 1) == height
            } ?? false
            let recovered: Bool
            if dimensionsMatch,
               let slice,
               slice.width == width,
               slice.height == height,
               slice.matchesVolumeEncoding(of: firstSlice) {
                recovered = uploadStoredInt16Slice(
                    slice,
                    sliceIndex: sliceIndex,
                    width: width,
                    height: height,
                    texture: texture,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            } else {
                recovered = false
            }
            if recovered == false {
                NSLog(
                    "%@",
                    "MetalSeriesTextureCache: DICOM slice \(sliceIndex) could not be decoded from \(pix.srcFile ?? "unknown source")"
                )
                missingSliceIndexes.append(sliceIndex)
            }
        }

        guard missingSliceIndexes.isEmpty == false else { return true }
        let maximumRecoverableMissingSliceCount = max(pixList.count / 100, 1)
        guard missingSliceIndexes.count <= maximumRecoverableMissingSliceCount else {
            NSLog(
                "%@",
                "MetalSeriesTextureCache: refusing to substitute \(missingSliceIndexes.count) missing slices in a \(pixList.count)-slice volume"
            )
            return false
        }

        let missingSliceSet = Set(missingSliceIndexes)
        for missingSliceIndex in missingSliceIndexes {
            guard let replacement = nearestDecodableStoredInt16Slice(
                    to: missingSliceIndex,
                    in: pixList,
                    excluding: missingSliceSet,
                    decodedSliceSeed: decodedSliceSeed,
                    matching: firstSlice,
                    width: width,
                    height: height
                  ),
                  uploadStoredInt16Slice(
                    replacement.slice,
                    sliceIndex: missingSliceIndex,
                    width: width,
                    height: height,
                    texture: texture,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                  ) else {
                return false
            }
            NSLog(
                "%@",
                "MetalSeriesTextureCache: substituted source slice \(replacement.index) for missing registration slice \(missingSliceIndex)"
            )
        }
        return true
    }

    private func nearestDecodableStoredInt16Slice(
        to missingIndex: Int,
        in pixList: [DCMPix],
        excluding missingIndexes: Set<Int>,
        decodedSliceSeed: DecodedSliceSeed?,
        matching firstSlice: MetalStoredInt16PixelData,
        width: Int,
        height: Int
    ) -> (slice: MetalStoredInt16PixelData, index: Int)? {
        guard pixList.isEmpty == false else { return nil }

        for distance in 1..<pixList.count {
            let candidateIndexes = [missingIndex - distance, missingIndex + distance]
            for candidateIndex in candidateIndexes where pixList.indices.contains(candidateIndex) {
                guard missingIndexes.contains(candidateIndex) == false,
                      let slice = decodedStoredInt16Slice(
                        at: candidateIndex,
                        in: pixList,
                        seriesDecoder: nil,
                        decodedSliceSeed: decodedSliceSeed
                      ),
                      slice.width == width,
                      slice.height == height,
                      slice.matchesVolumeEncoding(of: firstSlice) else {
                    continue
                }
                return (slice, candidateIndex)
            }
        }
        return nil
    }

    private func decodedStoredInt16Slice(
        at index: Int,
        in pixList: [DCMPix],
        seriesDecoder: MetalSwiftDICOMSeriesPixelDecoder?,
        decodedSliceSeed: DecodedSliceSeed?
    ) -> MetalStoredInt16PixelData? {
        if decodedSliceSeed?.index == index {
            return decodedSliceSeed?.pixels
        }
        return seriesDecoder?.decode(pix: pixList[index])
            ?? MetalStoredInt16PixelData(pix: pixList[index])
    }

    private func canCreateVolumeTexture(
        width: Int,
        height: Int,
        depth: Int,
        bytesPerVoxel: Int
    ) -> Bool {
        guard MetalTextureLimits.supports3DTexture(width: width, height: height, depth: depth) else {
            NSLog("%@", "MetalSeriesTextureCache: skipping stored-int16 \(width)x\(height)x\(depth) volume; Metal limits 3D texture dimensions to \(MetalTextureLimits.maximum3DTextureDimension)")
            return false
        }

        let byteCount = width * height * depth * bytesPerVoxel
        guard byteCount <= maximumCachedBytes else {
            NSLog("%@", "MetalSeriesTextureCache: skipping stored-int16 \(width)x\(height)x\(depth) volume; \(byteCount) bytes exceeds the volume texture cache limit")
            return false
        }

        return true
    }

    private func dimensionsWithoutLoading(for pix: DCMPix) -> SliceDimensions? {
        let width = Int(pix.widthWithoutLoading())
        let height = Int(pix.heightWithoutLoading())
        guard width > 0, height > 0 else { return nil }
        return SliceDimensions(width: width, height: height)
    }

    private func uploadStoredInt16Slice(
        _ slice: MetalStoredInt16PixelData,
        sliceIndex: Int,
        width: Int,
        height: Int,
        texture: MTLTexture,
        bytesPerRow: Int,
        bytesPerImage: Int
    ) -> Bool {
        guard slice.data.count >= bytesPerImage else { return false }

        slice.data.withUnsafeBytes { buffer in
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
        return true
    }

    private func finishRequest(key: String, entry: Entry?) {
        lock.lock()
        if let entry {
            entries[key] = entry
            cachedByteCount += entry.byteCount
            clearStoredInt16UnavailableLocked(key)
            markAccessedLocked(key)
            trimLocked(keeping: key)
        } else {
            markStoredInt16UnavailableLocked(key)
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

    private func markStoredInt16UnavailableLocked(_ key: String) {
        if unavailableStoredInt16Keys.insert(key).inserted {
            unavailableStoredInt16Order.append(key)
        }

        while unavailableStoredInt16Order.count > maximumUnavailableStoredInt16Count {
            let staleKey = unavailableStoredInt16Order.removeFirst()
            unavailableStoredInt16Keys.remove(staleKey)
        }
    }

    private func clearStoredInt16UnavailableLocked(_ key: String) {
        guard unavailableStoredInt16Keys.remove(key) != nil else { return }
        unavailableStoredInt16Order.removeAll { $0 == key }
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

}

enum MetalDynamicDetectionConfidence: Int {
    case manual = 0
    case high = 2
}

struct MetalDynamicSequence {
    let timePoints: [[DCMPix]]
    let frameDuration: TimeInterval
    let confidence: MetalDynamicDetectionConfidence
    let evidence: [String]

    var count: Int { timePoints.count }
}

private struct MetalDynamicFrameMetadata {
    let sourceIndex: Int
    let pix: DCMPix
    let temporalIndex: Int?
    let inStackPosition: Int?
    let position: SIMD3<Double>?
    let acquisitionSeconds: Double?
    let triggerMilliseconds: Double?
    let echoMilliseconds: Double?
    let hasExplicitTemporalDimension: Bool
    let hasCineTiming: Bool
    let hasDynamicImageType: Bool
    let excludesTimingHeuristic: Bool
    let preferredFrameDuration: TimeInterval?

    var spatialKey: String {
        if let inStackPosition {
            return "stack:\(inStackPosition)"
        }
        if let position {
            return String(
                format: "position:%.3f:%.3f:%.3f",
                position.x,
                position.y,
                position.z
            )
        }
        return "single-position"
    }

    var temporalSortValue: Double {
        if let triggerMilliseconds { return triggerMilliseconds / 1_000 }
        if let acquisitionSeconds { return acquisitionSeconds }
        if let temporalIndex { return Double(temporalIndex) }
        return Double(sourceIndex)
    }
}

private enum MetalDynamicSeriesDetector {
    private static let defaultFrameDuration: TimeInterval = 0.1

    static func detect(pixList: [DCMPix], force: Bool) -> MetalDynamicSequence? {
        guard pixList.count > 1 else { return nil }

        let metadata = readMetadata(for: pixList)
        guard metadata.count == pixList.count else {
            return force ? forcedSequence(from: pixList, metadata: metadata) : nil
        }

        if let explicit = sequenceFromExplicitTemporalDimension(metadata) {
            return makeSequence(
                timePoints: explicit,
                metadata: metadata,
                confidence: force ? .manual : .high,
                evidence: [NSLocalizedString("DICOM temporal position dimension", comment: "")]
            )
        }

        let hasDynamicImageType = metadata.contains(where: \.hasDynamicImageType)
        let hasCineTiming = metadata.contains(where: \.hasCineTiming)
        let excludesTimingHeuristic = metadata.contains(where: \.excludesTimingHeuristic)
        let hasVaryingEcho = Set(
            metadata.compactMap(\.echoMilliseconds).map { Int(($0 * 1_000).rounded()) }
        ).count > 1

        if excludesTimingHeuristic == false, hasVaryingEcho == false,
           let repeatedGeometry = sequenceFromRepeatedGeometry(metadata),
           hasDynamicImageType || hasCineTiming || hasUsefulAcquisitionTiming(metadata) {
            var evidence = [NSLocalizedString("Repeated spatial geometry with acquisition timing", comment: "")]
            if hasDynamicImageType {
                evidence.append(NSLocalizedString("DICOM Image Type identifies dynamic or gated data", comment: ""))
            }
            return makeSequence(
                timePoints: repeatedGeometry,
                metadata: metadata,
                confidence: force ? .manual : .high,
                evidence: evidence
            )
        }

        if isSinglePosition(metadata), hasDynamicImageType || hasCineTiming {
            let timePoints = metadata
                .sorted { temporalOrdering($0, $1) }
                .map { [$0.pix] }
            return makeSequence(
                timePoints: timePoints,
                metadata: metadata,
                confidence: force ? .manual : .high,
                evidence: [NSLocalizedString("DICOM cine timing", comment: "")]
            )
        }

        return force ? forcedSequence(from: pixList, metadata: metadata) : nil
    }

    private static func readMetadata(for pixList: [DCMPix]) -> [MetalDynamicFrameMetadata] {
        var cachedPath: String?
        var cachedReader: SwiftDICOMReader?
        var result: [MetalDynamicFrameMetadata] = []
        result.reserveCapacity(pixList.count)

        for (index, pix) in pixList.enumerated() {
            guard let path = nonEmpty(pix.srcFile) else { continue }
            let reader: SwiftDICOMReader
            if path == cachedPath, let cached = cachedReader {
                reader = cached
            } else {
                guard let parsed = try? SwiftDICOMReader.cached(contentsOfFile: path) else {
                    continue
                }
                cachedPath = path
                cachedReader = parsed
                reader = parsed
            }

            guard let attributes = reader.dynamicFrameAttributes(at: max(Int(pix.frameNo), 0)) else {
                continue
            }
            result.append(metadata(for: pix, sourceIndex: index, attributes: attributes))
        }
        return result
    }

    private static func metadata(
        for pix: DCMPix,
        sourceIndex: Int,
        attributes: SwiftDICOMDynamicFrameAttributes
    ) -> MetalDynamicFrameMetadata {
        let imageType = attributes.imageType.map { $0.uppercased() }
        let hasDynamicImageType = imageType.contains(where: {
            $0 == "DYNAMIC" || $0 == "GATED" || $0.contains("PERFUSION") || $0.contains("CINE")
        })
        let excludesTimingHeuristic = attributes.hasMRDiffusionSequence
            || imageType.contains(where: {
                $0.contains("DIFFUSION") || $0 == "ADC" || $0.contains("TRACEW")
                    || $0.contains("MIP") || $0.contains("SUBTRACTION")
                    || $0 == "PHASE" || $0.contains("MAGNITUDE") || $0.contains("ENERGY")
            })

        let preferredFrameDuration: TimeInterval?
        if let recommendedRate = attributes.recommendedDisplayFrameRate, recommendedRate > 0 {
            preferredFrameDuration = 1 / recommendedRate
        } else if let frameTimeMilliseconds = attributes.frameTimeMilliseconds, frameTimeMilliseconds > 0 {
            preferredFrameDuration = frameTimeMilliseconds / 1_000
        } else {
            preferredFrameDuration = nil
        }

        return MetalDynamicFrameMetadata(
            sourceIndex: sourceIndex,
            pix: pix,
            temporalIndex: attributes.temporalIndex,
            inStackPosition: attributes.inStackPosition,
            position: attributes.position,
            acquisitionSeconds: dicomTimeSeconds(attributes.acquisitionTime),
            triggerMilliseconds: attributes.triggerMilliseconds,
            echoMilliseconds: attributes.echoMilliseconds,
            hasExplicitTemporalDimension: attributes.hasExplicit3DTemporalDimension
                || attributes.numberOfTemporalPositions > 1
                || attributes.temporalIndex != nil,
            hasCineTiming: preferredFrameDuration != nil,
            hasDynamicImageType: hasDynamicImageType,
            excludesTimingHeuristic: excludesTimingHeuristic,
            preferredFrameDuration: preferredFrameDuration
        )
    }

    private static func sequenceFromExplicitTemporalDimension(_ metadata: [MetalDynamicFrameMetadata]) -> [[DCMPix]]? {
        guard metadata.contains(where: \.hasExplicitTemporalDimension) else { return nil }
        let indexed = metadata.compactMap { item -> (Int, MetalDynamicFrameMetadata)? in
            guard let temporalIndex = item.temporalIndex else { return nil }
            return (temporalIndex, item)
        }
        guard indexed.count == metadata.count else { return nil }

        let grouped = Dictionary(grouping: indexed, by: { $0.0 })
        guard grouped.count > 1 else { return nil }
        let ordered = grouped.keys.sorted().compactMap { key in
            grouped[key].flatMap { values -> [DCMPix]? in
                let frames = values.map(\.1)
                let spatialCounts = Dictionary(grouping: frames, by: \.spatialKey).values.map(\.count)
                guard spatialCounts.allSatisfy({ $0 == 1 }) else { return nil }
                return orderedPix(frames)
            }
        }
        return ordered.count == grouped.count && rectangular(timePoints: ordered) ? ordered : nil
    }

    private static func sequenceFromRepeatedGeometry(_ metadata: [MetalDynamicFrameMetadata]) -> [[DCMPix]]? {
        let grouped = Dictionary(grouping: metadata, by: \.spatialKey)
        guard grouped.isEmpty == false else { return nil }
        let occurrenceCounts = Set(grouped.values.map(\.count))
        guard occurrenceCounts.count == 1, let timeCount = occurrenceCounts.first, timeCount > 1 else { return nil }

        if grouped.count == 1 {
            return metadata.sorted(by: temporalOrdering).map { [$0.pix] }
        }

        let orderedSpatialGroups = spatiallyOrderedGroups(grouped)
        var timePoints = Array(repeating: [MetalDynamicFrameMetadata](), count: timeCount)
        for spatialGroup in orderedSpatialGroups {
            let occurrences = spatialGroup.sorted(by: temporalOrdering)
            for index in 0..<timeCount {
                timePoints[index].append(occurrences[index])
            }
        }
        return timePoints.map { $0.map(\.pix) }
    }

    private static func forcedSequence(from pixList: [DCMPix], metadata: [MetalDynamicFrameMetadata]) -> MetalDynamicSequence? {
        let timePoints: [[DCMPix]]
        if metadata.count == pixList.count, let repeated = sequenceFromRepeatedGeometry(metadata) {
            timePoints = repeated
        } else {
            timePoints = pixList.map { [$0] }
        }
        guard timePoints.count > 1 else { return nil }
        return makeSequence(
            timePoints: timePoints,
            metadata: metadata,
            confidence: .manual,
            evidence: [NSLocalizedString("User requested dynamic interpretation", comment: "")]
        )
    }

    private static func makeSequence(
        timePoints: [[DCMPix]],
        metadata: [MetalDynamicFrameMetadata],
        confidence: MetalDynamicDetectionConfidence,
        evidence: [String]
    ) -> MetalDynamicSequence? {
        guard timePoints.count > 1, timePoints.allSatisfy({ $0.isEmpty == false }) else { return nil }
        let preferred = metadata.compactMap(\.preferredFrameDuration).first
        let inferred = inferredFrameDuration(from: metadata)
        let duration: TimeInterval
        if let preferred {
            duration = min(max(preferred, 1.0 / 60.0), 2.0)
        } else if let inferred {
            // Acquisition intervals identify temporal order, but long scanner intervals
            // are not useful as literal cine playback delays.
            duration = min(max(inferred, 1.0 / 60.0), 0.5)
        } else {
            duration = defaultFrameDuration
        }
        return MetalDynamicSequence(
            timePoints: timePoints,
            frameDuration: duration,
            confidence: confidence,
            evidence: evidence
        )
    }

    private static func rectangular(timePoints: [[DCMPix]]) -> Bool {
        guard let count = timePoints.first?.count, count > 0 else { return false }
        return timePoints.allSatisfy { $0.count == count }
    }

    private static func orderedPix(_ metadata: [MetalDynamicFrameMetadata]) -> [DCMPix] {
        spatiallyOrderedGroups(Dictionary(grouping: metadata, by: \.spatialKey))
            .flatMap { $0.sorted { $0.sourceIndex < $1.sourceIndex } }
            .map(\.pix)
    }

    private static func spatiallyOrderedGroups(
        _ groups: [String: [MetalDynamicFrameMetadata]]
    ) -> [[MetalDynamicFrameMetadata]] {
        let representatives = groups.values.compactMap(\.first)
        let ranges: [Double] = (0..<3).map { axis in
            let values = representatives.compactMap { item -> Double? in
                guard let position = item.position else { return nil }
                return position[axis]
            }
            guard let minimum = values.min(), let maximum = values.max() else { return 0 }
            return maximum - minimum
        }
        let dominantAxis = ranges.enumerated().max(by: { $0.element < $1.element })?.offset ?? 2

        return groups.values.sorted { lhs, rhs in
            guard let left = lhs.first, let right = rhs.first else { return lhs.count < rhs.count }
            if let leftStack = left.inStackPosition, let rightStack = right.inStackPosition, leftStack != rightStack {
                return leftStack < rightStack
            }
            if let leftPosition = left.position, let rightPosition = right.position,
               leftPosition[dominantAxis] != rightPosition[dominantAxis] {
                return leftPosition[dominantAxis] < rightPosition[dominantAxis]
            }
            return left.sourceIndex < right.sourceIndex
        }
    }

    private static func temporalOrdering(_ lhs: MetalDynamicFrameMetadata, _ rhs: MetalDynamicFrameMetadata) -> Bool {
        if lhs.temporalSortValue != rhs.temporalSortValue {
            return lhs.temporalSortValue < rhs.temporalSortValue
        }
        return lhs.sourceIndex < rhs.sourceIndex
    }

    private static func isSinglePosition(_ metadata: [MetalDynamicFrameMetadata]) -> Bool {
        Set(metadata.map(\.spatialKey)).count == 1
    }

    private static func hasUsefulAcquisitionTiming(_ metadata: [MetalDynamicFrameMetadata]) -> Bool {
        let acquisitionTimes = Set(metadata.compactMap(\.acquisitionSeconds).map { Int(($0 * 1_000).rounded()) })
        let triggerTimes = Set(metadata.compactMap(\.triggerMilliseconds).map { Int($0.rounded()) })
        let echoTimes = Set(metadata.compactMap(\.echoMilliseconds).map { Int(($0 * 1_000).rounded()) })
        return (acquisitionTimes.count > 1 || triggerTimes.count > 1) && echoTimes.count <= 1
    }

    private static func inferredFrameDuration(from metadata: [MetalDynamicFrameMetadata]) -> TimeInterval? {
        let grouped = Dictionary(grouping: metadata, by: \.spatialKey)
        guard let longest = grouped.values.max(by: { $0.count < $1.count }) else { return nil }
        let times = longest.compactMap(\.acquisitionSeconds).sorted()
        guard times.count > 1 else { return nil }
        let differences = zip(times.dropFirst(), times).compactMap { pair -> Double? in
            let difference = pair.0 - pair.1
            return difference > 0 ? difference : nil
        }.sorted()
        guard differences.isEmpty == false else { return nil }
        return differences[differences.count / 2]
    }

    private static func dicomTimeSeconds(_ rawValue: Any?) -> Double? {
        if let date = rawValue as? Date {
            let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            guard let hour = components.hour else { return nil }
            return Double(hour * 3_600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
                + Double(components.nanosecond ?? 0) / 1_000_000_000
        }

        let stringValue: String?
        if let value = rawValue as? String {
            stringValue = value
        } else if let value = rawValue as? NSNumber {
            stringValue = value.stringValue
        } else {
            stringValue = nil
        }
        guard let value = nonEmpty(stringValue) else { return nil }
        let timeComponent: String
        if value.count >= 14, value.prefix(8).allSatisfy(\.isNumber) {
            timeComponent = String(value.dropFirst(8))
        } else {
            timeComponent = value
        }
        let normalized = timeComponent
            .components(separatedBy: CharacterSet(charactersIn: "+-"))
            .first?
            .replacingOccurrences(of: ":", with: "") ?? timeComponent
        guard normalized.count >= 2 else { return nil }
        let hour = Double(normalized.prefix(2)) ?? 0
        let minuteStart = normalized.index(normalized.startIndex, offsetBy: min(2, normalized.count))
        let minuteEnd = normalized.index(minuteStart, offsetBy: min(2, normalized.distance(from: minuteStart, to: normalized.endIndex)))
        let minute = Double(normalized[minuteStart..<minuteEnd]) ?? 0
        let second = minuteEnd < normalized.endIndex ? Double(normalized[minuteEnd...]) ?? 0 : 0
        return hour * 3_600 + minute * 60 + second
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private extension Array {
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class MetalViewerSeries {
    private static let dynamicDetectionQueue = DispatchQueue(
        label: "org.horosproject.horos.metalviewer.dynamic-detection",
        qos: .userInitiated
    )

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
    let forcesDynamicInterpretation: Bool
    let sourceSeriesIdentifiers: Set<String>
    let dynamicTimePointCountHint: Int?

    private let imageObjects: [NSManagedObject]
    private let isBonjour: Bool
    private var cachedPixList: [DCMPix]?
    private var cachedStructuredReportHTML: String?
    private var cachedDynamicSequence: MetalDynamicSequence?
    private var hasCompletedDynamicDetection = false
    private var dynamicDetectionInProgress = false
    private var dynamicDetectionCompletions: [(MetalDynamicSequence?) -> Void] = []
    var windowLevelState = MetalViewerWindowLevelState()
    var windowLevelPresetTitle = NSLocalizedString("Default WL & WW", comment: "")
    var transferFunctionState = MetalViewerTransferFunctionState()

    var isMagneticResonance: Bool {
        modality.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("MR") == .orderedSame
    }

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
        initialPixList: [DCMPix]? = nil,
        forceDynamicInterpretation: Bool = false,
        sourceSeriesIdentifiers: Set<String>? = nil,
        dynamicTimePointCountHint: Int? = nil
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
        self.forcesDynamicInterpretation = forceDynamicInterpretation
        self.sourceSeriesIdentifiers = sourceSeriesIdentifiers ?? [identifier]
        self.dynamicTimePointCountHint = dynamicTimePointCountHint
        self.cachedPixList = initialPixList
        self.cachedStructuredReportHTML = nil
        if isMagneticResonance {
            self.windowLevelPresetTitle = NSLocalizedString("Auto", comment: "")
        }
    }

    func sharesSourceSeries(with other: MetalViewerSeries) -> Bool {
        sourceSeriesIdentifiers.isDisjoint(with: other.sourceSeriesIdentifiers) == false
    }

    func detectDynamicSequence(completion: @escaping (MetalDynamicSequence?) -> Void) {
        precondition(Thread.isMainThread, "Dynamic DICOM detection must be requested on the main thread.")

        if hasCompletedDynamicDetection {
            completion(cachedDynamicSequence)
            return
        }

        dynamicDetectionCompletions.append(completion)
        guard dynamicDetectionInProgress == false else { return }
        dynamicDetectionInProgress = true

        let pixList = loadedPixList()
        let force = forcesDynamicInterpretation
        Self.dynamicDetectionQueue.async { [weak self] in
            let sequence = MetalDynamicSeriesDetector.detect(pixList: pixList, force: force)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedDynamicSequence = sequence
                self.hasCompletedDynamicDetection = true
                self.dynamicDetectionInProgress = false
                let completions = self.dynamicDetectionCompletions
                self.dynamicDetectionCompletions.removeAll()
                completions.forEach { $0(sequence) }
            }
        }
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

        var pixList: [DCMPix] = []

        if multiFrame {
            let object = loadList[0]
            let numberOfFrames = (object.value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? 0
            let width = (object.value(forKey: "width") as? NSNumber)?.intValue ?? 0
            let height = (object.value(forKey: "height") as? NSNumber)?.intValue ?? 0
            let seriesID = (object.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
            let path = Self.resolvedPath(for: object) ?? ""

            for i in 0..<numberOfFrames {
                if let pix = DCMPix(path: path, i, numberOfFrames, nil, i, seriesID, isBonjour: isBonjour, imageObj: object) {
                    pix.setWidthWithoutLoading(width, heightWithoutLoading: height)
                    pixList.append(pix)
                }
            }
        } else {
            for (index, object) in loadList.enumerated() {
                let width = (object.value(forKey: "width") as? NSNumber)?.intValue ?? 0
                let height = (object.value(forKey: "height") as? NSNumber)?.intValue ?? 0
                let frameID = (object.value(forKey: "frameID") as? NSNumber)?.intValue ?? 0
                let seriesID = (object.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
                let path = Self.resolvedPath(for: object) ?? ""

                if let pix = DCMPix(path: path, index, loadList.count, nil, frameID, seriesID, isBonjour: isBonjour, imageObj: object) {
                    pix.setWidthWithoutLoading(width, heightWithoutLoading: height)
                    pixList.append(pix)
                }
            }
        }

        cachedPixList = pixList
        return pixList
    }

    func retainLoadedPixelCache(from previousSeries: MetalViewerSeries) {
        guard imageCount == previousSeries.imageCount else { return }

        if cachedPixList == nil {
            cachedPixList = previousSeries.cachedPixList
        }

        if cachedStructuredReportHTML == nil {
            cachedStructuredReportHTML = previousSeries.cachedStructuredReportHTML
        }

        if hasCompletedDynamicDetection == false, previousSeries.hasCompletedDynamicDetection {
            cachedDynamicSequence = previousSeries.cachedDynamicSequence
            hasCompletedDynamicDetection = true
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
        guard let pix = DCMPix(path: path, 0, 1, nil, frameID, seriesID, isBonjour: isBonjour, imageObj: firstObject) else {
            return nil
        }
        pix.setWidthWithoutLoading(
            (firstObject.value(forKey: "width") as? NSNumber)?.intValue ?? 0,
            heightWithoutLoading: (firstObject.value(forKey: "height") as? NSNumber)?.intValue ?? 0
        )
        return pix
    }

    func middlePreviewPix() -> DCMPix? {
        if let cachedPixList, cachedPixList.isEmpty == false {
            return cachedPixList[cachedPixList.count / 2]
        }

        guard imageObjects.isEmpty == false else {
            return nil
        }

        let firstObject = imageObjects[0]
        let numberOfFrames = (firstObject.value(forKey: "numberOfFrames") as? NSNumber)?.intValue ?? 0
        let numberOfSeries = (firstObject.value(forKey: "numberOfSeries") as? NSNumber)?.intValue ?? 0
        let multiFrame = imageObjects.count == 1 && (numberOfFrames > 1 || numberOfSeries > 1)

        let object: NSManagedObject
        let imageIndex: Int
        let imageCount: Int
        let frameID: Int

        if multiFrame {
            object = firstObject
            imageCount = max(numberOfFrames > 0 ? numberOfFrames : numberOfSeries, 1)
            imageIndex = imageCount / 2
            frameID = imageIndex
        } else {
            imageCount = imageObjects.count
            imageIndex = imageCount / 2
            object = imageObjects[imageIndex]
            frameID = (object.value(forKey: "frameID") as? NSNumber)?.intValue ?? 0
        }

        let path = Self.resolvedPath(for: object) ?? ""
        let seriesID = (object.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
        guard let pix = DCMPix(
            path: path,
            imageIndex,
            imageCount,
            nil,
            frameID,
            seriesID,
            isBonjour: isBonjour,
            imageObj: object
        ) else {
            return nil
        }
        pix.setWidthWithoutLoading(
            (object.value(forKey: "width") as? NSNumber)?.intValue ?? 0,
            heightWithoutLoading: (object.value(forKey: "height") as? NSNumber)?.intValue ?? 0
        )
        return pix
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
        guard let sopClassUID else { return false }
        return sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1.88")
            && sopClassUID != "1.2.840.10008.5.1.4.1.1.88.59"
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
    let procedureEvents: [SurgicalProcedureEvent]

    init(
        title: String,
        series: [MetalViewerSeries],
        initialSeriesIdentifier: String,
        procedureEvents: [SurgicalProcedureEvent] = []
    ) {
        precondition(series.isEmpty == false, "MetalViewerStudy requires at least one series.")
        self.title = title
        self.series = series
        self.initialSeriesIdentifier = initialSeriesIdentifier
        self.procedureEvents = procedureEvents
    }
}

private struct MetalDICOMFrameGeometryMetadata {
    let origin: SIMD3<Double>
    let row: SIMD3<Double>
    let column: SIMD3<Double>
    let normal: SIMD3<Double>
    let spacingX: Double
    let spacingY: Double
    let sliceThickness: Double
    let spacingBetweenSlices: Double
    let sliceLocation: Double
}

private final class MetalDICOMFrameGeometryCache {
    static let shared = MetalDICOMFrameGeometryCache()

    private let lock = NSLock()
    private let maximumEntryCount = 4_096
    private var entries: [String: MetalDICOMFrameGeometryMetadata] = [:]
    private var insertionOrder: [String] = []
    private var unavailableKeys = Set<String>()

    private init() {}

    func metadata(for pix: DCMPix) -> MetalDICOMFrameGeometryMetadata? {
        guard let path = nonEmpty(pix.srcFile) else { return nil }
        let frameIndex = max(Int(pix.frameNo), 0)
        let key = "\(path)|frame=\(frameIndex)"

        lock.lock()
        if let entry = entries[key] {
            lock.unlock()
            return entry
        }
        if unavailableKeys.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let reader = try? SwiftDICOMReader.cached(contentsOfFile: path),
              let attributes = reader.frameGeometryAttributes(at: frameIndex),
              let metadata = Self.metadata(
            attributes: attributes,
            width: max(Int(pix.widthWithoutLoading()), 1),
            height: max(Int(pix.heightWithoutLoading()), 1)
        ) else {
            lock.lock()
            unavailableKeys.insert(key)
            lock.unlock()
            return nil
        }

        lock.lock()
        let isNewEntry = entries[key] == nil
        entries[key] = metadata
        if isNewEntry {
            insertionOrder.append(key)
        }
        if entries.count > maximumEntryCount, insertionOrder.isEmpty == false {
            let expiredKey = insertionOrder.removeFirst()
            entries.removeValue(forKey: expiredKey)
        }
        lock.unlock()
        return metadata
    }

    private static func metadata(
        attributes: SwiftDICOMFrameGeometryAttributes,
        width: Int,
        height: Int
    ) -> MetalDICOMFrameGeometryMetadata? {
        var row = attributes.row
        var column = attributes.column
        if simd_length(row) > 0.000001, simd_length(column) > 0.000001 {
            row = simd_normalize(row)
            column = simd_normalize(column)
        } else {
            row = SIMD3<Double>(1, 0, 0)
            column = SIMD3<Double>(0, 1, 0)
        }
        let normalCandidate = simd_cross(row, column)
        guard simd_length(normalCandidate) > 0.000001 else { return nil }
        let normal = simd_normalize(normalCandidate)

        let center = attributes.origin
            + row * ((Double(width) * 0.5 - 0.5) * attributes.spacingX)
            + column * ((Double(height) * 0.5 - 0.5) * attributes.spacingY)
        let absoluteNormal = SIMD3<Double>(abs(normal.x), abs(normal.y), abs(normal.z))
        let sliceLocation: Double
        if absoluteNormal.x >= absoluteNormal.y, absoluteNormal.x >= absoluteNormal.z {
            sliceLocation = center.x
        } else if absoluteNormal.y >= absoluteNormal.z {
            sliceLocation = center.y
        } else {
            sliceLocation = center.z
        }

        return MetalDICOMFrameGeometryMetadata(
            origin: attributes.origin,
            row: row,
            column: column,
            normal: normal,
            spacingX: attributes.spacingX,
            spacingY: attributes.spacingY,
            sliceThickness: attributes.sliceThickness,
            spacingBetweenSlices: attributes.spacingBetweenSlices,
            sliceLocation: sliceLocation
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

struct MetalViewerSliceGeometry {
    let origin: SIMD3<Double>
    let row: SIMD3<Double>
    let column: SIMD3<Double>
    let normal: SIMD3<Double>
    let width: Double
    let height: Double
    let spacingX: Double
    let spacingY: Double
    let sliceThickness: Double
    let spacingBetweenSlices: Double
    let sliceLocation: Double

    init?(pix: DCMPix) {
        guard let metadata = MetalDICOMFrameGeometryCache.shared.metadata(for: pix) else {
            return nil
        }

        self.row = metadata.row
        self.column = metadata.column
        self.normal = metadata.normal
        self.spacingX = metadata.spacingX
        self.spacingY = metadata.spacingY
        self.width = max(Double(pix.widthWithoutLoading()), 1)
        self.height = max(Double(pix.heightWithoutLoading()), 1)
        self.origin = metadata.origin
        self.sliceThickness = metadata.sliceThickness
        self.spacingBetweenSlices = metadata.spacingBetweenSlices
        self.sliceLocation = metadata.sliceLocation
    }

    func slicePoint(from worldPoint: SIMD3<Double>) -> CGPoint {
        let delta = worldPoint - origin
        let x = (simd_dot(delta, row) + spacingX * 0.5) / spacingX
        let y = (simd_dot(delta, column) + spacingY * 0.5) / spacingY
        return CGPoint(x: x, y: y)
    }

    func dicomPoint(pixelX: Double, pixelY: Double, pixelCenter: Bool = true) -> SIMD3<Double> {
        let x = pixelCenter ? pixelX - 0.5 : pixelX
        let y = pixelCenter ? pixelY - 0.5 : pixelY
        return origin + row * (x * spacingX) + column * (y * spacingY)
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
        if pixList.count > 1,
           let lastPix = pixList.last,
           let lastGeometry = MetalViewerSliceGeometry(pix: lastPix) {
            let delta = SIMD3<Float>(
                Float(lastGeometry.origin.x - geometry.origin.x),
                Float(lastGeometry.origin.y - geometry.origin.y),
                Float(lastGeometry.origin.z - geometry.origin.z)
            ) / Float(max(pixList.count - 1, 1))
            sliceStep = simd_length(delta) > 0.0001
                ? delta
                : fallbackNormal * sliceSpacing(for: geometry, fallback: fallbackSliceSpacing)
        } else {
            sliceStep = fallbackNormal * sliceSpacing(for: geometry, fallback: fallbackSliceSpacing)
        }

        let rowStep = row * Float(geometry.spacingX)
        let columnStep = column * Float(geometry.spacingY)
        let origin = SIMD3<Float>(Float(geometry.origin.x), Float(geometry.origin.y), Float(geometry.origin.z))

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
        if pixList.count > 1,
           let lastPix = pixList.last,
           let lastGeometry = MetalViewerSliceGeometry(pix: lastPix) {
            let delta = SIMD3<Float>(
                Float(lastGeometry.origin.x - geometry.origin.x),
                Float(lastGeometry.origin.y - geometry.origin.y),
                Float(lastGeometry.origin.z - geometry.origin.z)
            ) / Float(max(pixList.count - 1, 1))
            let normalSpacing = simd_dot(delta, normal)
            sliceStep = abs(normalSpacing) > 0.0001
                ? normal * normalSpacing
                : normal * sliceSpacing(for: geometry, fallback: fallbackSliceSpacing)
        } else {
            sliceStep = normal * sliceSpacing(for: geometry, fallback: fallbackSliceSpacing)
        }

        let rowStep = row * Float(geometry.spacingX)
        let columnStep = column * Float(geometry.spacingY)
        let origin = SIMD3<Float>(Float(geometry.origin.x), Float(geometry.origin.y), Float(geometry.origin.z))

        return simd_float4x4(
            SIMD4<Float>(rowStep.x, rowStep.y, rowStep.z, 0),
            SIMD4<Float>(columnStep.x, columnStep.y, columnStep.z, 0),
            SIMD4<Float>(sliceStep.x, sliceStep.y, sliceStep.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        )
    }

    private static func sliceSpacing(for geometry: MetalViewerSliceGeometry, fallback: Float?) -> Float {
        if let fallback, fallback > 0.000001 {
            return fallback
        }

        let candidates = [geometry.spacingBetweenSlices, geometry.sliceThickness]
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

struct MetalPreparedVolumeLevel {
    let texture: MTLTexture
    let dimensions: SIMD3<Int>
    let voxelToWorld: simd_float4x4
}

final class MetalPreparedVolumeCache {
    final class Entry {
        let key: String
        let sourceKey: String
        let texture: MTLTexture
        let dimensions: SIMD3<Int>
        let voxelToWorld: simd_float4x4
        let isGantryTiltCorrected: Bool
        let levels: [MetalPreparedVolumeLevel]
        let hasRegistrationPyramid: Bool
        let defaultWindow: MetalViewerWindowLevel
        let fullDynamicWindow: MetalViewerWindowLevel
        let byteCount: Int

        fileprivate init(
            key: String,
            sourceKey: String,
            texture: MTLTexture,
            dimensions: SIMD3<Int>,
            voxelToWorld: simd_float4x4,
            isGantryTiltCorrected: Bool,
            levels: [MetalPreparedVolumeLevel],
            hasRegistrationPyramid: Bool,
            defaultWindow: MetalViewerWindowLevel,
            fullDynamicWindow: MetalViewerWindowLevel
        ) {
            self.key = key
            self.sourceKey = sourceKey
            self.texture = texture
            self.dimensions = dimensions
            self.voxelToWorld = voxelToWorld
            self.isGantryTiltCorrected = isGantryTiltCorrected
            self.levels = levels
            self.hasRegistrationPyramid = hasRegistrationPyramid
            self.defaultWindow = defaultWindow
            self.fullDynamicWindow = fullDynamicWindow
            self.byteCount = levels.reduce(0) { partial, level in
                partial + max(level.dimensions.x, 1)
                    * max(level.dimensions.y, 1)
                    * max(level.dimensions.z, 1)
                    * MemoryLayout<Float>.stride
            }
        }
    }

    static let shared = MetalPreparedVolumeCache()

    private struct StoredConversionUniforms {
        var sourceSize: SIMD4<UInt32>
        var rescale: SIMD4<Float>
    }

    private struct ResampleUniforms {
        var outputSize: SIMD4<UInt32>
        var outputVoxelToWorld: simd_float4x4
        var sourceWorldToVoxel: simd_float4x4
        var backgroundValue: SIMD4<Float>
    }

    private struct BlurUniforms {
        var sourceSize: SIMD3<UInt32>
        var axis: UInt32
        var radius: UInt32
    }

    private struct DownsampleUniforms {
        var sourceSize: SIMD3<UInt32>
        var factor: UInt32
    }

    private final class Pipelines {
        let commandQueue: MTLCommandQueue
        let convertSigned: MTLComputePipelineState
        let convertUnsigned: MTLComputePipelineState
        let resample: MTLComputePipelineState
        let gaussianBlur: MTLComputePipelineState
        let downsample: MTLComputePipelineState

        init?(device: MTLDevice) {
            guard let commandQueue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let convertSignedFunction = library.makeFunction(name: "metalViewerConvertStoredSigned3D"),
                  let convertUnsignedFunction = library.makeFunction(name: "metalViewerConvertStoredUnsigned3D"),
                  let resampleFunction = library.makeFunction(name: "metalViewerGantryTiltResample3D"),
                  let gaussianBlurFunction = library.makeFunction(name: "metalViewerGaussianBlur3D"),
                  let downsampleFunction = library.makeFunction(name: "metalViewerDownsample3D") else {
                return nil
            }

            do {
                self.commandQueue = commandQueue
                self.convertSigned = try device.makeComputePipelineState(function: convertSignedFunction)
                self.convertUnsigned = try device.makeComputePipelineState(function: convertUnsignedFunction)
                self.resample = try device.makeComputePipelineState(function: resampleFunction)
                self.gaussianBlur = try device.makeComputePipelineState(function: gaussianBlurFunction)
                self.downsample = try device.makeComputePipelineState(function: downsampleFunction)
            } catch {
                return nil
            }
        }
    }

    private let lock = NSLock()
    private let preparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.horos.metalviewer.prepared-volume-cache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let maximumEntryCount = 3
    private let maximumCachedBytes = 1_500_000_000
    private var pipelinesByDevice: [UInt64: Pipelines] = [:]
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private var cachedByteCount = 0
    private var inFlightCompletions: [String: [(Entry?) -> Void]] = [:]

    private init() {}

    func key(
        for sourceEntry: MetalSeriesTextureCache.Entry,
        correctGantryTilt: Bool
    ) -> String {
        "prepared-v1|gantry=\(correctGantryTilt ? 1 : 0)|\(sourceEntry.key)"
    }

    func cachedEntry(
        for sourceEntry: MetalSeriesTextureCache.Entry,
        correctGantryTilt: Bool,
        requiringRegistrationPyramid: Bool
    ) -> Entry? {
        let key = key(for: sourceEntry, correctGantryTilt: correctGantryTilt)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key],
              requiringRegistrationPyramid == false || entry.hasRegistrationPyramid else {
            return nil
        }
        markAccessedLocked(key)
        return entry
    }

    func requestEntry(
        for pixList: [DCMPix],
        sourceEntry: MetalSeriesTextureCache.Entry,
        device: MTLDevice,
        correctGantryTilt: Bool,
        includeRegistrationPyramid: Bool,
        completion: @escaping (Entry?) -> Void
    ) {
        let key = key(for: sourceEntry, correctGantryTilt: correctGantryTilt)
        let requestKey = "\(key)|pyramid=\(includeRegistrationPyramid ? 1 : 0)"

        lock.lock()
        if let entry = entries[key],
           includeRegistrationPyramid == false || entry.hasRegistrationPyramid {
            markAccessedLocked(key)
            lock.unlock()
            DispatchQueue.main.async {
                completion(entry)
            }
            return
        }
        if inFlightCompletions[requestKey] != nil {
            inFlightCompletions[requestKey]?.append(completion)
            lock.unlock()
            return
        }
        inFlightCompletions[requestKey] = [completion]
        lock.unlock()

        let requestedPixList = pixList
        preparationQueue.addOperation { [weak self] in
            guard let self else { return }
            self.encodeEntry(
                key: key,
                requestKey: requestKey,
                pixList: requestedPixList,
                sourceEntry: sourceEntry,
                existingEntry: self.existingPreparedEntry(forKey: key),
                device: device,
                correctGantryTilt: correctGantryTilt,
                includeRegistrationPyramid: includeRegistrationPyramid
            )
        }
    }

    private func existingPreparedEntry(forKey key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    private func encodeEntry(
        key: String,
        requestKey: String,
        pixList: [DCMPix],
        sourceEntry: MetalSeriesTextureCache.Entry,
        existingEntry: Entry?,
        device: MTLDevice,
        correctGantryTilt: Bool,
        includeRegistrationPyramid: Bool
    ) {
        guard let pipelines = pipelines(for: device),
              sourceEntry.textureKind == .storedInt16Signed || sourceEntry.textureKind == .storedInt16Unsigned,
              pixList.isEmpty == false else {
            finish(requestKey: requestKey, key: key, entry: nil)
            return
        }

        let start = CFAbsoluteTimeGetCurrent()
        let sourceDimensions = sourceEntry.dimensions
        let geometry = MetalViewerGantryTiltGeometryBuilder.geometry(
            for: pixList,
            sourceDimensions: sourceDimensions
        )
        let appliesGantryCorrection = correctGantryTilt && geometry.requiresCorrection()
        let outputDimensions = appliesGantryCorrection ? geometry.dimensions : sourceDimensions
        let outputVoxelToWorld = appliesGantryCorrection
            ? geometry.correctedVoxelToPatientMatrix
            : geometry.sourceVoxelToPatientMatrix

        guard let commandBuffer = pipelines.commandQueue.makeCommandBuffer() else {
            finish(requestKey: requestKey, key: key, entry: nil)
            return
        }

        let primaryTexture: MTLTexture
        if let existingEntry,
           existingEntry.dimensions == outputDimensions,
           Self.matricesMatch(existingEntry.voxelToWorld, outputVoxelToWorld) {
            primaryTexture = existingEntry.texture
        } else {
            guard let convertedTexture = makeWritableFloatTexture(
                device: device,
                dimensions: sourceDimensions
            ), encodeStoredConversion(
                sourceEntry: sourceEntry,
                destination: convertedTexture,
                pipelines: pipelines,
                commandBuffer: commandBuffer
            ) else {
                finish(requestKey: requestKey, key: key, entry: nil)
                return
            }

            if appliesGantryCorrection {
                guard let correctedTexture = makeWritableFloatTexture(
                    device: device,
                    dimensions: outputDimensions
                ), encodeResample(
                    source: convertedTexture,
                    destination: correctedTexture,
                    outputDimensions: outputDimensions,
                    outputVoxelToWorld: outputVoxelToWorld,
                    sourceVoxelToWorld: geometry.sourceVoxelToPatientMatrix,
                    backgroundValue: Self.isCTVolume(pixList) ? -1024 : 0,
                    pipelines: pipelines,
                    commandBuffer: commandBuffer
                ) else {
                    finish(requestKey: requestKey, key: key, entry: nil)
                    return
                }
                primaryTexture = correctedTexture
            } else {
                primaryTexture = convertedTexture
            }
        }

        var levels = [MetalPreparedVolumeLevel(
            texture: primaryTexture,
            dimensions: outputDimensions,
            voxelToWorld: outputVoxelToWorld
        )]
        if includeRegistrationPyramid {
            guard let pyramidLevels = encodeRegistrationPyramid(
                source: primaryTexture,
                dimensions: outputDimensions,
                voxelToWorld: outputVoxelToWorld,
                device: device,
                pipelines: pipelines,
                commandBuffer: commandBuffer
            ) else {
                finish(requestKey: requestKey, key: key, entry: nil)
                return
            }
            levels = pyramidLevels
        }

        let entry = Entry(
            key: key,
            sourceKey: sourceEntry.key,
            texture: primaryTexture,
            dimensions: outputDimensions,
            voxelToWorld: outputVoxelToWorld,
            isGantryTiltCorrected: appliesGantryCorrection,
            levels: levels,
            hasRegistrationPyramid: includeRegistrationPyramid,
            defaultWindow: sourceEntry.defaultWindow,
            fullDynamicWindow: sourceEntry.fullDynamicWindow
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            finish(requestKey: requestKey, key: key, entry: nil)
            return
        }
        MetalViewerDiagnostics.registrationTimingLog(
            format: "MetalPreparedVolumeCache prepare %dx%dx%d pyramid=%d gantry=%d %.3f s",
            outputDimensions.x,
            outputDimensions.y,
            outputDimensions.z,
            includeRegistrationPyramid ? 1 : 0,
            appliesGantryCorrection ? 1 : 0,
            CFAbsoluteTimeGetCurrent() - start
        )
        finish(requestKey: requestKey, key: key, entry: entry)
    }

    private func encodeStoredConversion(
        sourceEntry: MetalSeriesTextureCache.Entry,
        destination: MTLTexture,
        pipelines: Pipelines,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var uniforms = StoredConversionUniforms(
            sourceSize: SIMD4<UInt32>(
                UInt32(max(sourceEntry.dimensions.x, 1)),
                UInt32(max(sourceEntry.dimensions.y, 1)),
                UInt32(max(sourceEntry.dimensions.z, 1)),
                0
            ),
            rescale: SIMD4<Float>(sourceEntry.rescaleSlope, sourceEntry.rescaleIntercept, 0, 0)
        )
        encoder.setComputePipelineState(
            sourceEntry.textureKind == .storedInt16Signed
                ? pipelines.convertSigned
                : pipelines.convertUnsigned
        )
        encoder.setTexture(sourceEntry.texture, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<StoredConversionUniforms>.stride, index: 0)
        Self.dispatch3D(encoder: encoder, dimensions: sourceEntry.dimensions)
        encoder.endEncoding()
        return true
    }

    private func encodeResample(
        source: MTLTexture,
        destination: MTLTexture,
        outputDimensions: SIMD3<Int>,
        outputVoxelToWorld: simd_float4x4,
        sourceVoxelToWorld: simd_float4x4,
        backgroundValue: Float,
        pipelines: Pipelines,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var uniforms = ResampleUniforms(
            outputSize: SIMD4<UInt32>(
                UInt32(max(outputDimensions.x, 1)),
                UInt32(max(outputDimensions.y, 1)),
                UInt32(max(outputDimensions.z, 1)),
                0
            ),
            outputVoxelToWorld: outputVoxelToWorld,
            sourceWorldToVoxel: simd_inverse(sourceVoxelToWorld),
            backgroundValue: SIMD4<Float>(backgroundValue, 0, 0, 0)
        )
        encoder.setComputePipelineState(pipelines.resample)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<ResampleUniforms>.stride, index: 0)
        Self.dispatch3D(encoder: encoder, dimensions: outputDimensions)
        encoder.endEncoding()
        return true
    }

    private func encodeRegistrationPyramid(
        source: MTLTexture,
        dimensions: SIMD3<Int>,
        voxelToWorld: simd_float4x4,
        device: MTLDevice,
        pipelines: Pipelines,
        commandBuffer: MTLCommandBuffer
    ) -> [MetalPreparedVolumeLevel]? {
        var fineToCoarse = [MetalPreparedVolumeLevel(
            texture: source,
            dimensions: dimensions,
            voxelToWorld: voxelToWorld
        )]
        var currentTexture = source
        var currentDimensions = dimensions
        var factor = 1

        for _ in 0..<3 {
            let spacing = MetalViewerGantryTiltGeometry.voxelSpacing(
                from: voxelToWorld * Self.scaleMatrix(factor: factor)
            )
            guard let downsampled = encodeGaussianDownsample(
                source: currentTexture,
                dimensions: currentDimensions,
                voxelSpacing: spacing,
                device: device,
                pipelines: pipelines,
                commandBuffer: commandBuffer
            ) else {
                return nil
            }
            factor *= 2
            currentDimensions = SIMD3<Int>(
                max((currentDimensions.x + 1) / 2, 1),
                max((currentDimensions.y + 1) / 2, 1),
                max((currentDimensions.z + 1) / 2, 1)
            )
            currentTexture = downsampled
            fineToCoarse.append(MetalPreparedVolumeLevel(
                texture: downsampled,
                dimensions: currentDimensions,
                voxelToWorld: voxelToWorld * Self.scaleMatrix(factor: factor)
            ))
        }

        return Array(fineToCoarse.reversed())
    }

    private func encodeGaussianDownsample(
        source: MTLTexture,
        dimensions: SIMD3<Int>,
        voxelSpacing: SIMD3<Float>,
        device: MTLDevice,
        pipelines: Pipelines,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let sigmaMM: Float = 1
        let sigma = SIMD3<Float>(
            sigmaMM / max(voxelSpacing.x, 0.0001),
            sigmaMM / max(voxelSpacing.y, 0.0001),
            sigmaMM / max(voxelSpacing.z, 0.0001)
        )
        guard let xKernel = makeKernelBuffer(device: device, sigma: sigma.x),
              let yKernel = makeKernelBuffer(device: device, sigma: sigma.y),
              let zKernel = makeKernelBuffer(device: device, sigma: sigma.z),
              let blurX = makeWritableFloatTexture(device: device, dimensions: dimensions),
              let blurY = makeWritableFloatTexture(device: device, dimensions: dimensions),
              let blurZ = makeWritableFloatTexture(device: device, dimensions: dimensions),
              encodeBlur(source: source, destination: blurX, dimensions: dimensions, axis: 0, kernel: xKernel, pipelines: pipelines, commandBuffer: commandBuffer),
              encodeBlur(source: blurX, destination: blurY, dimensions: dimensions, axis: 1, kernel: yKernel, pipelines: pipelines, commandBuffer: commandBuffer),
              encodeBlur(source: blurY, destination: blurZ, dimensions: dimensions, axis: 2, kernel: zKernel, pipelines: pipelines, commandBuffer: commandBuffer) else {
            return nil
        }

        let outputDimensions = SIMD3<Int>(
            max((dimensions.x + 1) / 2, 1),
            max((dimensions.y + 1) / 2, 1),
            max((dimensions.z + 1) / 2, 1)
        )
        guard let output = makeWritableFloatTexture(device: device, dimensions: outputDimensions),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        var uniforms = DownsampleUniforms(
            sourceSize: SIMD3<UInt32>(
                UInt32(max(dimensions.x, 1)),
                UInt32(max(dimensions.y, 1)),
                UInt32(max(dimensions.z, 1))
            ),
            factor: 2
        )
        encoder.setComputePipelineState(pipelines.downsample)
        encoder.setTexture(blurZ, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<DownsampleUniforms>.stride, index: 0)
        Self.dispatch3D(encoder: encoder, dimensions: outputDimensions)
        encoder.endEncoding()
        return output
    }

    private func encodeBlur(
        source: MTLTexture,
        destination: MTLTexture,
        dimensions: SIMD3<Int>,
        axis: UInt32,
        kernel: MTLBuffer,
        pipelines: Pipelines,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var uniforms = BlurUniforms(
            sourceSize: SIMD3<UInt32>(
                UInt32(max(dimensions.x, 1)),
                UInt32(max(dimensions.y, 1)),
                UInt32(max(dimensions.z, 1))
            ),
            axis: axis,
            radius: UInt32(max((kernel.length / MemoryLayout<Float>.stride - 1) / 2, 0))
        )
        encoder.setComputePipelineState(pipelines.gaussianBlur)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.setBuffer(kernel, offset: 0, index: 1)
        Self.dispatch3D(encoder: encoder, dimensions: dimensions)
        encoder.endEncoding()
        return true
    }

    private func makeKernelBuffer(device: MTLDevice, sigma: Float) -> MTLBuffer? {
        let clampedSigma = max(sigma, 0.001)
        let radius = max(Int(ceil(clampedSigma * 2.5)), 1)
        var kernel = [Float]()
        kernel.reserveCapacity(radius * 2 + 1)
        var sum: Float = 0
        for offset in -radius...radius {
            let x = Float(offset)
            let value = exp(-(x * x) / (2 * clampedSigma * clampedSigma))
            kernel.append(value)
            sum += value
        }
        guard sum > 0 else { return nil }
        kernel = kernel.map { $0 / sum }
        return device.makeBuffer(
            bytes: kernel,
            length: kernel.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
    }

    private func makeWritableFloatTexture(
        device: MTLDevice,
        dimensions: SIMD3<Int>
    ) -> MTLTexture? {
        guard MetalTextureLimits.supports3DTexture(
            width: dimensions.x,
            height: dimensions.y,
            depth: dimensions.z
        ) else {
            return nil
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = max(dimensions.x, 1)
        descriptor.height = max(dimensions.y, 1)
        descriptor.depth = max(dimensions.z, 1)
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func pipelines(for device: MTLDevice) -> Pipelines? {
        let deviceKey = device.registryID
        lock.lock()
        if let pipelines = pipelinesByDevice[deviceKey] {
            lock.unlock()
            return pipelines
        }
        lock.unlock()

        guard let pipelines = Pipelines(device: device) else { return nil }
        lock.lock()
        let resolved = pipelinesByDevice[deviceKey] ?? pipelines
        pipelinesByDevice[deviceKey] = resolved
        lock.unlock()
        return resolved
    }

    private func finish(requestKey: String, key: String, entry: Entry?) {
        lock.lock()
        var resolvedEntry = entry
        if let entry {
            if let current = entries[key],
               current.hasRegistrationPyramid,
               entry.hasRegistrationPyramid == false {
                resolvedEntry = current
                markAccessedLocked(key)
            } else {
                if let previous = entries.updateValue(entry, forKey: key) {
                    cachedByteCount -= previous.byteCount
                }
                cachedByteCount += entry.byteCount
                markAccessedLocked(key)
                trimLocked(keeping: key)
            }
        }
        let completions = inFlightCompletions.removeValue(forKey: requestKey) ?? []
        let deliveredEntry = resolvedEntry
        lock.unlock()

        DispatchQueue.main.async {
            for completion in completions {
                completion(deliveredEntry)
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
            if key == newestKey, accessOrder.count == 1 { return }
            accessOrder.removeFirst()
            if let removed = entries.removeValue(forKey: key) {
                cachedByteCount -= removed.byteCount
            }
        }
    }

    private static func dispatch3D(
        encoder: MTLComputeCommandEncoder,
        dimensions: SIMD3<Int>
    ) {
        let threads = MTLSize(width: 4, height: 4, depth: 4)
        let groups = MTLSize(
            width: (max(dimensions.x, 1) + threads.width - 1) / threads.width,
            height: (max(dimensions.y, 1) + threads.height - 1) / threads.height,
            depth: (max(dimensions.z, 1) + threads.depth - 1) / threads.depth
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private static func scaleMatrix(factor: Int) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(Float(factor), 0, 0, 0),
            SIMD4<Float>(0, Float(factor), 0, 0),
            SIMD4<Float>(0, 0, Float(factor), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func matricesMatch(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Bool {
        let difference = lhs - rhs
        return simd_length(difference.columns.0) < 0.0001
            && simd_length(difference.columns.1) < 0.0001
            && simd_length(difference.columns.2) < 0.0001
            && simd_length(difference.columns.3) < 0.0001
    }

    private static func isCTVolume(_ pixList: [DCMPix]) -> Bool {
        guard let firstPix = pixList.first else { return false }
        let modality = firstPix.modalityString?.uppercased() ?? ""
        let rescale = firstPix.rescaleType?.uppercased() ?? ""
        return modality.contains("CT") || rescale == "HU"
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

        let activePlanePoint = active.dicomPoint(pixelX: 0, pixelY: 0)
        let targetCorners = [
            target.dicomPoint(pixelX: 0, pixelY: 0),
            target.dicomPoint(pixelX: target.width, pixelY: 0),
            target.dicomPoint(pixelX: target.width, pixelY: target.height),
            target.dicomPoint(pixelX: 0, pixelY: target.height),
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
        let thickness = active.sliceThickness
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
