import AppKit
import Foundation
import simd

final class MetalViewerSeries {
    let identifier: String
    let title: String
    let studyIdentifier: String
    let studyTitle: String
    let studyDate: Date?
    let studyNumber: Int
    let showsStudyHeader: Bool
    let imageCount: Int

    private let imageObjects: [NSManagedObject]
    private let isBonjour: Bool
    private var cachedPixList: [DCMPix]?
    private var cachedVolumeBacking: NSData?
    private var cachedStructuredReportHTML: String?
    private var didAttemptStructuredReportHTML = false

    init(
        identifier: String = UUID().uuidString,
        title: String,
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
        self.studyIdentifier = studyIdentifier
        self.studyTitle = studyTitle
        self.studyDate = studyDate
        self.studyNumber = studyNumber
        self.showsStudyHeader = showsStudyHeader
        self.imageObjects = imageObjects
        self.isBonjour = isBonjour
        self.imageCount = imageObjects.isEmpty ? (initialPixList?.count ?? 0) : imageObjects.count
        self.cachedPixList = initialPixList
        self.cachedVolumeBacking = nil
        self.cachedStructuredReportHTML = nil
        self.didAttemptStructuredReportHTML = false
    }

    var isStructuredReport: Bool {
        structuredReportHTML() != nil
    }

    func structuredReportHTML() -> String? {
        if didAttemptStructuredReportHTML {
            return cachedStructuredReportHTML
        }

        didAttemptStructuredReportHTML = true

        if let cachedStructuredReportHTML {
            return cachedStructuredReportHTML
        }

        for path in structuredReportCandidatePaths() {
            if let html = StructuredReportSupport.htmlString(forPath: path), html.isEmpty == false {
                cachedStructuredReportHTML = html
                return html
            }
        }

        cachedStructuredReportHTML = nil
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

    private func structuredReportCandidatePaths() -> [String] {
        var orderedPaths: [String] = []
        var seen = Set<String>()

        func appendPath(_ path: String?) {
            guard let path, path.isEmpty == false, seen.contains(path) == false else { return }
            seen.insert(path)
            orderedPaths.append(path)
        }

        for imageObject in imageObjects {
            appendPath(Self.resolvedPath(for: imageObject))
        }

        if let cachedPixList {
            for pix in cachedPixList {
                appendPath(pix.srcFile)
            }
        }

        appendPath(firstPreviewPix()?.srcFile)
        return orderedPaths
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
}

enum MetalViewerReferenceLineCalculator {
    static func line(active: MetalViewerSliceGeometry, target: MetalViewerSliceGeometry) -> MetalViewerReferenceLine? {
        let targetPlanePoint = dicomPoint(for: target.pix, x: 0, y: 0)

        let activeCorners = [
            dicomPoint(for: active.pix, x: 0, y: 0),
            dicomPoint(for: active.pix, x: active.width, y: 0),
            dicomPoint(for: active.pix, x: active.width, y: active.height),
            dicomPoint(for: active.pix, x: 0, y: active.height),
        ]

        let edges = [
            (activeCorners[0], activeCorners[1]),
            (activeCorners[1], activeCorners[2]),
            (activeCorners[2], activeCorners[3]),
            (activeCorners[3], activeCorners[0]),
        ]

        var intersections: [CGPoint] = []
        for edge in edges {
            guard let worldPoint = intersectSegment(edge.0, edge.1, planeNormal: target.normal, planePoint: targetPlanePoint) else {
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

        return MetalViewerReferenceLine(start: intersections[0], end: intersections[1])
    }

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
