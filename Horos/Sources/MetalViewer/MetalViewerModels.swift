import AppKit
import Foundation
import simd

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
