import AppKit
import CryptoKit
import Foundation
import simd

/// The phone receives scalar samples and patient-space triangle meshes, never DICOM files.
@objc(HorosPhoneVolumeExporter)
final class HorosPhoneVolumeExporter: NSObject {
    @objc var transferThread: Thread?
    private let liveROIs: [String: [MetalStudyROI]]
    private var assets: [[String: Any]] = []
    private var assetNames: [String] = []
    private var roiBytes = 0

    override init() {
        precondition(Thread.isMainThread)
        liveROIs = MetalViewerLauncher.phoneROISnapshot()
        super.init()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "HorosPhoneVolume", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func checkCancellation() throws {
        if transferThread?.isCancelled == true { throw failure("Cancelled iPhone transfer.") }
    }

    /// Called on the selected images' managed-object context, not on the main thread.
    @objc(writeImages:toDirectory:error:)
    func write(images: [NSManagedObject], toDirectory directory: URL) throws -> [String] {
        assets.removeAll(); assetNames.removeAll(); roiBytes = 0
        let selected = images.filter {
            ["CT", "MR"].contains(($0.value(forKeyPath: "series.modality") as? String ?? "").uppercased())
        }
        let seriesIDs = Set(selected.compactMap {
            ($0.value(forKey: "series") as? NSManagedObject)?.objectID
        })
        guard seriesIDs.count == 1,
              let seriesObject = selected.first?.value(forKey: "series") as? NSManagedObject,
              let studyObject = seriesObject.value(forKey: "study") as? NSManagedObject else {
            throw failure("Select exactly one CT or MRI volume to send to the iPhone.")
        }
        let identity = MetalViewerPatientIdentity.fallback(title: "Horos image")
        let studyUID = studyObject.value(forKey: "studyInstanceUID") as? String ?? ""
        func makeSeries(_ object: NSManagedObject, images: [NSManagedObject]) -> MetalViewerSeries {
            MetalViewerSeries(identifier: object.objectID.uriRepresentation().absoluteString,
                patientIdentity: identity, title: object.value(forKey: "name") as? String ?? "Image", seriesNumber: "",
                studyIdentifier: studyUID, studyTitle: "Horos image", studyDate: nil,
                studyNumber: 1, showsStudyHeader: false, imageObjects: images, isBonjour: false)
        }
        let source = makeSeries(seriesObject, images: selected)
        let pixels = source.loadedPixList()
        guard !pixels.isEmpty else { throw failure("The selected volume has no image frames.") }
        var externalReaders: [String: SwiftDICOMReader] = [:]
        var frames: [(pix: DCMPix, geometry: MetalViewerSliceGeometry, reader: SwiftDICOMReader)] = []
        var temporalPositions = Set<Int>()
        var echoTimes = Set<Int>()
        for pix in pixels {
            try checkCancellation()
            guard let path = pix.srcFile else { throw failure("An image has no source file.") }
            let reader: SwiftDICOMReader
            if let cached = externalReaders[path] { reader = cached }
            else if let native = try? SwiftDICOMReader.cached(contentsOfFile: path) { reader = native }
            else {
                reader = try SwiftDICOMReader(contentsOfFile: path, metadataForExternalDecoder: true)
                externalReaders[path] = reader
            }
            guard let attributes = reader.frameGeometryAttributes(at: max(Int(pix.frameNo), 0)),
                  attributes.spacingX > 0, attributes.spacingY > 0,
                  let geometry = MetalViewerSliceGeometry(attributes: attributes,
                    width: Int(pix.widthWithoutLoading()), height: Int(pix.heightWithoutLoading())),
                  simd_length(geometry.row) > 0.99, simd_length(geometry.column) > 0.99 else {
                throw failure("An image is missing valid patient geometry. Nothing was sent.")
            }
            if let dynamic = reader.dynamicFrameAttributes(at: max(Int(pix.frameNo), 0)) {
                if let t = dynamic.temporalIndex { temporalPositions.insert(t) }
                if let echo = dynamic.echoMilliseconds, echo.isFinite { echoTimes.insert(Int((echo * 100).rounded())) }
            }
            frames.append((pix, geometry, reader))
        }
        guard temporalPositions.count <= 1, echoTimes.count <= 1 else {
            throw failure("This selection contains multiple MRI time points or echoes. Send one volume at a time.")
        }
        let normal = frames[0].geometry.normal
        frames.sort { simd_dot($0.geometry.origin, normal) < simd_dot($1.geometry.origin, normal) }
        let first = frames[0].geometry
        let width = Int(first.width), height = Int(first.height), depth = frames.count
        guard width > 0, height > 0, width <= 4096, height <= 4096, depth <= 4096,
              abs(simd_dot(first.row, first.column)) < 0.0001 else { throw failure("Unsupported volume geometry.") }
        let singleSliceSpacing = abs(first.spacingBetweenSlices) > 0.000001 ? abs(first.spacingBetweenSlices)
            : (abs(first.sliceThickness) > 0.000001 ? abs(first.sliceThickness) : 1)
        let step = depth > 1 ? (frames[depth - 1].geometry.origin - first.origin) / Double(depth - 1)
            : normal * singleSliceSpacing
        let spacingZ = simd_dot(step, normal)
        guard spacingZ >= 0.001, spacingZ <= 100 else {
            throw failure("The selection contains duplicate slice positions or multiple volumes.")
        }
        for (index, frame) in frames.enumerated() {
            let photo = frame.reader.stringValue(forTag: "0028,0004")?.uppercased()
            guard ["MONOCHROME1", "MONOCHROME2"].contains(photo ?? ""),
                  photo == frames[0].reader.stringValue(forTag: "0028,0004")?.uppercased() else {
                throw failure("A scalar volume must use one monochrome photometric interpretation.")
            }
            let g = frame.geometry
            guard Int(g.width) == width, Int(g.height) == height,
                  simd_length(g.row - first.row) < 0.0001,
                  simd_length(g.column - first.column) < 0.0001,
                  abs(g.spacingX - first.spacingX) < 0.0001,
                  abs(g.spacingY - first.spacingY) < 0.0001,
                  simd_length(g.origin - (first.origin + step * Double(index))) < max(0.01, spacingZ * 0.001) else {
                throw failure("These slices do not form one regularly spaced volume. Separate localizers, echoes, or time points before sending.")
            }
        }
        // Correct a tilted acquisition on the Mac. Padding retains the entire field of view.
        let shifts = frames.map { frame -> SIMD2<Double> in
            let delta = frame.geometry.origin - first.origin
            func snapped(_ value: Double) -> Double {
                abs(value - value.rounded()) < 0.00001 ? value.rounded() : value
            }
            return SIMD2(snapped(simd_dot(delta, first.row) / first.spacingX),
                         snapped(simd_dot(delta, first.column) / first.spacingY))
        }
        let lowX = floor(shifts.map(\.x).min() ?? 0), lowY = floor(shifts.map(\.y).min() ?? 0)
        let highX = ceil(shifts.map(\.x).max() ?? 0), highY = ceil(shifts.map(\.y).max() ?? 0)
        let outputWidth = width + Int(highX - lowX), outputHeight = height + Int(highY - lowY)
        guard outputWidth <= 4096, outputHeight <= 4096,
              UInt64(outputWidth) * UInt64(outputHeight) * UInt64(depth) <= 268_435_456 else {
            throw failure("The prepared volume exceeds the iPhone's 1 GiB transfer limit.")
        }
        let origin = first.origin + first.row * (lowX * first.spacingX) + first.column * (lowY * first.spacingY)
        let modality = source.modality.uppercased()
        let firstReader = frames[0].reader
        let inverted = firstReader.stringValue(forTag: "0028,0004")?.uppercased() == "MONOCHROME1"
        let volumeName = "volume.f32"
        let volumeURL = directory.appendingPathComponent(volumeName)
        guard FileManager.default.createFile(atPath: volumeURL.path, contents: nil) else { throw failure("Cannot create the prepared volume.") }
        let output = try FileHandle(forWritingTo: volumeURL)
        defer { try? output.close() }
        var minimum = Float.greatestFiniteMagnitude, maximum = -Float.greatestFiniteMagnitude
        var windowLevel: Double?, windowWidth: Double?
        var hash = SHA256()
        for (z, frame) in frames.enumerated() {
            try checkCancellation()
            try autoreleasepool {
                let decoded = try decode(frame.pix, reader: frame.reader, inverted: inverted)
                guard decoded.width == width, decoded.height == height else { throw failure("Decoded slice dimensions changed.") }
                if z == 0 { windowLevel = decoded.level; windowWidth = decoded.window }
                let shift = shifts[z]
                var samples = [Float](repeating: modality == "CT" ? -1024 : 0, count: outputWidth * outputHeight)
                for y in 0..<outputHeight {
                    for x in 0..<outputWidth {
                        let sx = Double(x) + lowX - shift.x, sy = Double(y) + lowY - shift.y
                        if sx >= -0.000001, sy >= -0.000001, sx <= Double(width - 1) + 0.000001, sy <= Double(height - 1) + 0.000001 {
                            let px = min(max(sx, 0), Double(width - 1)), py = min(max(sy, 0), Double(height - 1))
                            let ix = Int(floor(px)), iy = Int(floor(py))
                            let jx = min(ix + 1, width - 1), jy = min(iy + 1, height - 1)
                            let fx = Float(px - Double(ix)), fy = Float(py - Double(iy))
                            let top = decoded.values[iy * width + ix] * (1 - fx) + decoded.values[iy * width + jx] * fx
                            let bottom = decoded.values[jy * width + ix] * (1 - fx) + decoded.values[jy * width + jx] * fx
                            samples[y * outputWidth + x] = top * (1 - fy) + bottom * fy
                        }
                    }
                }
                for value in samples {
                    guard value.isFinite else { throw failure("A decoded image contains invalid intensities.") }
                    minimum = min(minimum, value); maximum = max(maximum, value)
                }
                let bytes = samples.withUnsafeBytes { Data($0) }
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
            }
        }
        try output.synchronize()
        assets.append(["name": volumeName, "byteCount": outputWidth * outputHeight * depth * 4,
                       "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
        assetNames.append(volumeName)
        if let savedWidth = (seriesObject.value(forKey: "windowWidth") as? NSNumber)?.doubleValue,
           let savedLevel = (seriesObject.value(forKey: "windowLevel") as? NSNumber)?.doubleValue,
           savedWidth.isFinite, savedWidth > 0, savedLevel.isFinite {
            windowLevel = savedLevel; windowWidth = savedWidth
        } else if modality == "CT" { windowLevel = 40; windowWidth = 100 }
        if windowWidth == nil || !(windowWidth!.isFinite) || windowWidth! <= 0 || windowLevel == nil || !(windowLevel!.isFinite) {
            windowWidth = max(Double(maximum) - Double(minimum), 1)
            windowLevel = Double(minimum) + windowWidth! * 0.5
        }
        let imageToPatient: [Double] = [first.row.x, first.column.x, normal.x, origin.x,
            first.row.y, first.column.y, normal.y, origin.y,
            first.row.z, first.column.z, normal.z, origin.z, 0, 0, 0, 1]
        var associated = [source]
        let studySeries = studyObject.value(forKey: "series") as? NSSet ?? NSSet()
        for case let object as NSManagedObject in studySeries
            where (object.value(forKey: "modality") as? String)?.uppercased() == "SEG" {
            let associatedImages = (object.value(forKey: "images") as? NSSet)?.allObjects.compactMap {
                $0 as? NSManagedObject
            } ?? []
            associated.append(makeSeries(object, images: associatedImages))
        }
        let study = MetalViewerStudy(patientIdentity: identity, title: "Horos image", series: associated, initialSeriesIdentifier: source.identifier)
        let savedROIs = MetalStudyROIPersistence(study: study).restoredROIs
        // A live snapshot also represents deletions not yet flushed to DICOM SEG.
        let sourceROIs = liveROIs[studyUID] ?? savedROIs
        var rois: [[String: Any]] = []
        let frameUID = firstReader.stringValue(forTag: "0020,0052") ?? ""
        for var roi in sourceROIs where roi.studyInstanceUID == studyUID {
            guard roi.sourceSeriesIdentifier == source.identifier ||
                  (!frameUID.isEmpty && roi.frameOfReferenceUID == frameUID) else { continue }
            roi.rebuildDerivedState()
            let vertices = metalStudyROISurfaceVertices(for: roi).map { $0.position }
            if !vertices.isEmpty {
                rois.append(try writeROI(vertices, id: roi.id.uuidString, name: roi.name,
                    color: [roi.colorRed, roi.colorGreen, roi.colorBlue, 0.65], directory: directory))
            }
        }
        let sortedPixels = frames.map(\.pix)
        for record in MetalLegacyROISRBridge.roiDictionaries(forPixList: sortedPixels) {
            let index = (record["sliceIndex"] as? NSNumber)?.intValue ?? -1
            guard index >= 0, index < frames.count else { throw failure("An ROI refers to an unavailable image frame.") }
            let mesh = try legacyMesh(record, geometry: frames[index].geometry)
            if !mesh.isEmpty {
                let color = ["red", "green", "blue", "alpha"].map { (record[$0] as? NSNumber)?.doubleValue ?? 1 }
                rois.append(try writeROI(mesh, id: UUID().uuidString, name: record["name"] as? String ?? "ROI", color: color, directory: directory))
            }
        }
        guard rois.count <= 512 else { throw failure("Too many ROIs for one phone transfer.") }
        let seriesUID = firstReader.stringValue(forTag: "0020,000E") ?? source.identifier
        let descriptor: [String: Any] = ["id": UUID().uuidString, "name": source.title.isEmpty ? modality : source.title,
            "seriesUID": seriesUID, "studyUID": studyUID, "frameOfReferenceUID": frameUID, "modality": modality,
            "dimensions": [outputWidth, outputHeight, depth], "spacing": [first.spacingX, first.spacingY, spacingZ],
            "imageToPatient": imageToPatient, "windowLevel": windowLevel!, "windowWidth": windowWidth!,
            "invertDisplay": inverted, "voxels": volumeName, "rois": rois]
        let manifest: [String: Any] = ["version": 2, "coordinateSystem": "DICOM_LPS_mm", "sampleType": "float32-le",
                                      "volumes": [descriptor], "assets": assets]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        guard json.count <= 4 * 1024 * 1024 else { throw failure("The ROI manifest is too large.") }
        try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return ["manifest.json"] + assetNames
    }

    private struct Decoded {
        var width: Int; var height: Int; var values: [Float]; var level: Double?; var window: Double?
    }

    private func decode(_ pix: DCMPix, reader: SwiftDICOMReader, inverted: Bool) throws -> Decoded {
        let frameNumber = max(Int(pix.frameNo), 0)
        if let frame = try? reader.storedPixelFrame(at: frameNumber) {
            // The existing Metal reader folds MONOCHROME1 into rescale. Undo that for quantitative data.
            let sign: Float = inverted ? -1 : 1
            let slope = frame.rescaleSlope * sign, intercept = frame.rescaleIntercept * sign
            var values = [Float](repeating: 0, count: frame.width * frame.height)
            frame.data.withUnsafeBytes { raw in
                for index in values.indices {
                    let word = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                    values[index] = (frame.isSigned ? Float(Int16(bitPattern: word)) : Float(word)) * slope + intercept
                }
            }
            return Decoded(width: frame.width, height: frame.height, values: values,
                           level: frame.windowLevel.map { Double($0 * sign) }, window: frame.windowWidth.map(Double.init))
        }
        // DCMTK handles the compressed pixels; the native reader supplies per-frame calibration.
        guard pix.loadDICOMModernDCMTK(), !pix.isRGB,
              let samples = pix.fImage, pix.pwidth > 0, pix.pheight > 0 else {
            throw failure("Horos could not decode this frame without losing geometry or intensity calibration. Nothing was sent.")
        }
        let calibration = reader.phoneFrameCalibration(at: frameNumber)
        let originalSlope = pix.slope == 0 ? 1 : pix.slope
        let values = UnsafeBufferPointer(start: samples, count: pix.pwidth * pix.pheight).map {
            (($0 - pix.offset) / originalSlope) * calibration.slope + calibration.intercept
        }
        return Decoded(width: pix.pwidth, height: pix.pheight, values: values,
            level: calibration.level.map(Double.init), window: calibration.width.map(Double.init))
    }

    private func writeROI(_ vertices: [SIMD3<Float>], id: String, name: String, color: [Double], directory: URL) throws -> [String: Any] {
        try checkCancellation()
        guard vertices.count % 3 == 0 else { throw failure("Invalid ROI triangles.") }
        var packed: [Float] = []
        packed.reserveCapacity(vertices.count * 3)
        for p in vertices {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw failure("An ROI has invalid patient coordinates.") }
            packed.append(contentsOf: [p.x, p.y, p.z])
        }
        let data = packed.withUnsafeBytes { Data($0) }
        roiBytes += data.count
        guard roiBytes <= 64 * 1024 * 1024 else { throw failure("The ROI geometry exceeds the phone's 64 MiB limit.") }
        let file = "roi-\(assetNames.count).f32"
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        assets.append(["name": file, "byteCount": data.count,
                       "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        assetNames.append(file)
        return ["id": id, "name": name.isEmpty ? "ROI" : name, "color": color,
                "primitive": "triangles", "vertices": file]
    }

    private func legacyMesh(_ roi: [String: Any], geometry g: MetalViewerSliceGeometry) throws -> [SIMD3<Float>] {
        func number(_ key: String) -> Double { (roi[key] as? NSNumber)?.doubleValue ?? 0 }
        func world(_ x: Double, _ y: Double) -> SIMD3<Float> {
            let p = g.dicomPoint(pixelX: x, pixelY: y)
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let kind = roi["kind"] as? String ?? "polyline"
        var mesh: [SIMD3<Float>] = []
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let delta = b - a
            guard simd_length(delta) > 0.00001 else { return }
            let direction = simd_normalize(delta)
            let reference = abs(direction.z) < 0.8 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
            let u = simd_normalize(simd_cross(direction, reference)) * 0.25
            let v = simd_normalize(simd_cross(direction, u)) * 0.25
            let ring = [u, v, -u, -v]
            for i in 0..<4 {
                let j = (i + 1) % 4
                mesh.append(contentsOf: [a+ring[i], b+ring[i], b+ring[j], a+ring[i], b+ring[j], a+ring[j]])
            }
        }
        if kind == "brush" {
            let width = Int(number("maskWidth")), height = Int(number("maskHeight"))
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  let data = roi["maskData"] as? Data, data.count == width * height else { throw failure("An ROI brush mask is invalid.") }
            func occupied(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && x < width && y >= 0 && y < height && data[(height - 1 - y) * width + x] != 0
            }
            let ox = number("maskOriginX"), oy = number("maskOriginY")
            for y in 0..<height { for x in 0..<width where occupied(x, y) {
                let px = ox + Double(x), py = oy + Double(y)
                if !occupied(x-1,y) { line(world(px,py), world(px,py+1)) }
                if !occupied(x+1,y) { line(world(px+1,py), world(px+1,py+1)) }
                if !occupied(x,y-1) { line(world(px,py), world(px+1,py)) }
                if !occupied(x,y+1) { line(world(px,py+1), world(px+1,py+1)) }
                if mesh.count > 1_500_000 { throw failure("An ROI brush outline is too large for the phone.") }
            } }
            return mesh
        }
        if kind == "layer" { throw failure("Image-layer ROIs are not yet transferable. Convert the layer to a contour or segmentation before sending.") }
        let coordinates = roi["points"] as? [NSNumber] ?? []
        var points: [SIMD3<Float>] = []
        if coordinates.count >= 2 {
            for i in stride(from: 0, to: coordinates.count - 1, by: 2) {
                points.append(world(coordinates[i].doubleValue, coordinates[i+1].doubleValue))
            }
        }
        let x = number("rectX"), y = number("rectY"), w = number("rectWidth"), h = number("rectHeight")
        var closed = kind == "closedPolygon"
        if kind == "rectangle" {
            points = [world(x,y), world(x+w,y), world(x+w,y+h), world(x,y+h)]; closed = true
        } else if kind == "oval" {
            points = (0..<96).map { i in
                let angle = Double(i) * 2 * .pi / 96
                return world(x + abs(w)*cos(angle), y + abs(h)*sin(angle))
            }; closed = true
        }
        if kind == "point" || kind == "text" || points.count == 1 {
            let p = points.first ?? world(x,y)
            line(p - SIMD3(1.5,0,0), p + SIMD3(1.5,0,0))
            line(p - SIMD3(0,1.5,0), p + SIMD3(0,1.5,0))
            line(p - SIMD3(0,0,1.5), p + SIMD3(0,0,1.5))
        } else if points.count >= 2 {
            if (roi["spline"] as? NSNumber)?.boolValue == true, points.count >= 3 {
                let controls = points
                func control(_ index: Int) -> SIMD3<Float> {
                    controls[closed ? (index % controls.count + controls.count) % controls.count : min(max(index, 0), controls.count - 1)]
                }
                points = [controls[0]]
                for index in 0..<(closed ? controls.count : controls.count - 1) {
                    let p0 = control(index-1), p1 = control(index), p2 = control(index+1), p3 = control(index+2)
                    let c1 = p1 + (p2-p0)/6, c2 = p2 - (p3-p1)/6
                    for sample in 1...16 {
                        let t = Float(sample)/16, u = 1-t
                        points.append(p1*(u*u*u) + c1*(3*u*u*t) + c2*(3*u*t*t) + p2*(t*t*t))
                    }
                }
            }
            for i in 1..<points.count { line(points[i-1], points[i]) }
            if closed { line(points.last!, points[0]) }
            if kind == "arrow" {
                let d = simd_normalize(points[1] - points[0]) * 3
                let n = SIMD3<Float>(Float(g.normal.x), Float(g.normal.y), Float(g.normal.z))
                let side = simd_cross(n, d) * 0.5
                line(points[0], points[0]+d+side); line(points[0], points[0]+d-side)
            }
        }
        return mesh
    }
}
