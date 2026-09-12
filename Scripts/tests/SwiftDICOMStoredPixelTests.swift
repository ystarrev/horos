// Standalone runtime harness, not part of Horos. After build approval, append
// this file to SwiftDICOMReader.swift in a temporary source file and compile it
// with MetalViewerCachePolicy.swift and -parse-as-library. Same-file access
// tests the private production helper.
// The codec stub prevents linking DCMTK; no JPEG decoding or patient files are used.
import Foundation

func HorosDecodeJPEGFrame(
    _ data: Data, _ syntax: String, _ photometric: String,
    _ rows: Int32, _ columns: Int32, _ samples: Int32,
    _ allocated: Int32, _ stored: Int32, _ signed: Bool, _ planar: Int32
) -> Data? {
    fatalError("Pixel normalization tests must not invoke the JPEG codec")
}

private func checkPixels(_ condition: Bool, _ context: String) {
    if !condition {
        fatalError("FAIL: \(context)")
    }
}

extension SwiftDICOMReader {
    static func verifyStoredPixelNormalization() throws {
        // Exhaust every possible source word, including unused bits, sign bits,
        // and shifted samples. The reference uses integer arithmetic, not the
        // production byte-writing implementation.
        for bitsAllocated in [8, 16] {
            let pixelCount = 1 << bitsAllocated
            var source = Data()
            source.reserveCapacity(pixelCount * (bitsAllocated / 8))
            for rawValue in 0..<pixelCount {
                source.append(UInt8(truncatingIfNeeded: rawValue))
                if bitsAllocated == 16 {
                    source.append(UInt8(truncatingIfNeeded: rawValue >> 8))
                }
            }
            for bitsStored in 1...bitsAllocated {
                for highBit in (bitsStored - 1)..<bitsAllocated {
                    for isSigned in [false, true] {
                        let actual = try normalizedStoredData(
                            source, pixelCount: pixelCount, bitsAllocated: bitsAllocated,
                            bitsStored: bitsStored, highBit: highBit, isSigned: isSigned
                        )
                        let context = "allocated=\(bitsAllocated), stored=\(bitsStored), high=\(highBit), signed=\(isSigned)"
                        checkPixels(actual.startIndex == 0 && actual.count == pixelCount * 2, context)
                        let range = 1 << bitsStored
                        let divisor = 1 << (highBit - bitsStored + 1)
                        actual.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                            for rawValue in 0..<pixelCount {
                                let stored = (rawValue / divisor) % range
                                let signed = isSigned && stored >= range / 2 ? stored - range : stored
                                let expected = UInt16(truncatingIfNeeded: signed)
                                let offset = rawValue * 2
                                checkPixels(bytes[offset] == UInt8(truncatingIfNeeded: expected)
                                    && bytes[offset + 1] == UInt8(truncatingIfNeeded: expected >> 8), context)
                            }
                        }
                    }
                }
            }
        }

        // Exercise non-zero Data indices and trailing bytes on both paths.
        for bitsAllocated in [8, 16] {
            for bitsStored in [8, bitsAllocated] {
                let pixelCount = 64
                let source = Data((0..<(pixelCount * bitsAllocated / 8)).map { UInt8($0) })
                let expected = try normalizedStoredData(
                    source, pixelCount: pixelCount, bitsAllocated: bitsAllocated,
                    bitsStored: bitsStored, highBit: bitsStored - 1, isSigned: true
                )
                var prefixed = Data([0xA5])
                prefixed.append(source)
                let sliced = prefixed.dropFirst()
                checkPixels(sliced.startIndex != 0, "test requires nonzero slice index")
                for input in [sliced, sliced + Data([0xAA, 0xBB]), source + Data([0xAA, 0xBB])] {
                    let actual = try normalizedStoredData(
                        input, pixelCount: pixelCount, bitsAllocated: bitsAllocated,
                        bitsStored: bitsStored, highBit: bitsStored - 1, isSigned: true
                    )
                    checkPixels(actual.startIndex == 0 && actual == expected, "sliced/padded frame")
                }
                var changed = expected
                changed[0] ^= 0xFF
                checkPixels(source[0] == 0 && expected[0] == 0, "copy-on-write isolation")
            }
        }

        for bitsAllocated in [8, 16] {
            do {
                _ = try normalizedStoredData(
                    Data(), pixelCount: 0, bitsAllocated: bitsAllocated,
                    bitsStored: bitsAllocated, highBit: bitsAllocated - 1, isSigned: false
                )
                fatalError("Empty frame accepted")
            } catch SwiftDICOMReaderError.invalidFile {
                // Expected.
            }
            do {
                _ = try normalizedStoredData(
                    Data(repeating: 0, count: bitsAllocated / 8 - 1), pixelCount: 1,
                    bitsAllocated: bitsAllocated, bitsStored: bitsAllocated,
                    highBit: bitsAllocated - 1, isSigned: false
                )
                fatalError("Truncated frame accepted")
            } catch SwiftDICOMReaderError.truncated {
                // Expected.
            }
        }
    }
}

extension SwiftDICOMReader {
    static func verifyFileReplacementCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reused.dcm")

        func words(_ values: [UInt16]) -> Data {
            Data(values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
        }
        func fixture(_ value: UInt16, width: UInt16 = 2, height: UInt16 = 2) -> Data {
            var data = Data()
            func add(_ group: UInt16, _ element: UInt16, _ bytes: Data) {
                data.append(words([group, element, UInt16(bytes.count), 0])) // Implicit VR LE.
                data.append(bytes)
            }
            add(0x0028, 0x0010, words([height]))
            add(0x0028, 0x0011, words([width]))
            add(0x0028, 0x0100, words([16]))
            add(0x0028, 0x0101, words([16]))
            add(0x0028, 0x0102, words([15]))
            add(0x7fe0, 0x0010, words(Array(repeating: value, count: 4)))
            return data
        }

        try fixture(10).write(to: file)
        let original = try cached(contentsOfFile: file.path)
        let unchanged = try cached(contentsOfFile: file.path)
        checkPixels(original === unchanged, "Unchanged file should reuse reader")
        let originalDate = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!

        try fixture(20).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let replaced = try cached(contentsOfFile: file.path)
        let replacedFrame = try replaced.storedPixelFrame(at: 0)
        checkPixels(replaced !== original && replacedFrame.data == words([20, 20, 20, 20]),
                    "Atomic replacement retained stale pixels")

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: fixture(30))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let edited = try cached(contentsOfFile: file.path)
        let editedFrame = try edited.storedPixelFrame(at: 0)
        checkPixels(edited !== replaced && editedFrame.data == words([30, 30, 30, 30]),
                    "In-place edit retained stale pixels")
        checkPixels((try replaced.storedPixelFrame(at: 0)).data == words([20, 20, 20, 20]),
                    "Cached snapshot changed after in-place edit")

        try FileManager.default.removeItem(at: file)
        do {
            _ = try cached(contentsOfFile: file.path)
            fatalError("Deleted file was served from cache")
        } catch SwiftDICOMReaderError.invalidFile { }
        try fixture(40, width: 4, height: 1).write(to: file)
        let recreated = try cached(contentsOfFile: file.path)
        checkPixels(recreated.integerValue(forTag: "0028,0011") == 4
                    && recreated.integerValue(forTag: "0028,0010") == 1,
                    "Recreated file retained stale geometry")
        invalidateCache(forPath: file.path)
        let invalidated = try cached(contentsOfFile: file.path)
        checkPixels(recreated !== invalidated, "Explicit invalidation retained reader")
    }
}

@main
struct StoredPixelNormalizationTests {
    static func main() throws {
        try SwiftDICOMReader.verifyStoredPixelNormalization()
        try SwiftDICOMReader.verifyFileReplacementCache()
        print("Stored pixel normalization: exhaustive byte equality passed")
        print("DICOM file replacement cache: identity and pixels passed")
    }
}
