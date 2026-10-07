import Foundation
import simd

/// Snapshot these values on the owning viewer/context queue, then load off-main.
enum MRIBrainDICOMLoader {
    struct Source {
        let path: String
        let frameIndex: Int
        let origin: SIMD3<Double>
        let row: SIMD3<Double>
        let column: SIMD3<Double>
        let spacing: SIMD2<Double>
    }

    static func load(_ sources: [Source], studyUID: String, seriesUID: String,
                     frameOfReferenceUID: String, frameIdentifiers: Set<String>,
                     cancelled: () -> Bool, progress: (Double) -> Void) throws -> MRIBrainVolume {
        guard sources.count >= 8, sources.count == frameIdentifiers.count else {
            throw MRIBrainExtractionError.invalid("Select a complete, single-volume MRI series for brain extraction.")
        }
        var slices = [MRIBrainVolume.Slice]()
        var seen = Set<String>()
        var totalPixels = 0
        for (i, source) in sources.enumerated() {
            if cancelled() { throw CocoaError(.userCancelled) }
            let slice: MRIBrainVolume.Slice = try autoreleasepool {
                let reader = try SwiftDICOMReader.cached(contentsOfFile: source.path)
                guard reader.stringValue(forTag: "0008,0060") == "MR",
                      reader.stringValue(forTag: "0020,000D") == studyUID,
                      reader.stringValue(forTag: "0020,000E") == seriesUID,
                      reader.stringValue(forTag: "0020,0052") == frameOfReferenceUID,
                      let sop = reader.stringValue(forTag: "0008,0018"),
                      frameIdentifiers.contains("\(sop)#\(source.frameIndex)"),
                      seen.insert("\(sop)#\(source.frameIndex)").inserted else {
                    throw MRIBrainExtractionError.invalid("Brain extraction requires the original MRI image set. Reopen the viewer if the series has changed.")
                }
                let frame = try reader.storedPixelFrame(at: source.frameIndex)
                guard frame.width > 0, frame.height > 0, frame.width <= 4096, frame.height <= 4096,
                      frame.data.count == frame.width * frame.height * 2 else {
                    throw MRIBrainExtractionError.invalid("Unsupported MRI pixel data.")
                }
                totalPixels += frame.width * frame.height
                guard totalPixels <= 256_000_000 else { throw MRIBrainExtractionError.invalid("MRI is too large for brain extraction.") }
                let pixels = frame.data.withUnsafeBytes { bytes in
                    (0..<(frame.width * frame.height)).map { i -> Float in
                        let raw = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        let value = frame.isSigned ? Float(Int16(bitPattern: raw)) : Float(raw)
                        return value * frame.rescaleSlope + frame.rescaleIntercept
                    }
                }
                return MRIBrainVolume.Slice(width: frame.width, height: frame.height, origin: source.origin,
                    row: source.row, column: source.column, spacing: source.spacing, pixels: pixels)
            }
            slices.append(slice)
            progress(Double(i + 1) / Double(sources.count))
        }
        if cancelled() { throw CocoaError(.userCancelled) }
        return try MRIBrainVolume(slices: slices)
    }
}
