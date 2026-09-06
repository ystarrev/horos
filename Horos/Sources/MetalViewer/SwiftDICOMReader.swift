import Foundation

/// The normalized stored-value frame consumed by the Metal texture pipeline.
/// Pixel samples are always little-endian UInt16 bit patterns; signedness and
/// rescale parameters describe how the shader interprets them.
struct SwiftDICOMStoredPixelFrame {
    let data: Data
    let width: Int
    let height: Int
    let bitsStored: Int
    let rescaleSlope: Float
    let rescaleIntercept: Float
    let isSigned: Bool
    let pixelSpacingX: Float
    let pixelSpacingY: Float
    let windowLevel: Float?
    let windowWidth: Float?
}

struct SwiftDICOMDynamicFrameAttributes {
    let temporalIndex: Int?
    let inStackPosition: Int?
    let position: SIMD3<Double>?
    let acquisitionTime: String?
    let triggerMilliseconds: Double?
    let echoMilliseconds: Double?
    let numberOfTemporalPositions: Int
    let hasExplicit3DTemporalDimension: Bool
    let imageType: [String]
    let hasMRDiffusionSequence: Bool
    let recommendedDisplayFrameRate: Double?
    let frameTimeMilliseconds: Double?
}

struct SwiftDICOMFrameGeometryAttributes {
    let origin: SIMD3<Double>
    let row: SIMD3<Double>
    let column: SIMD3<Double>
    let spacingX: Double
    let spacingY: Double
    let sliceThickness: Double
    let spacingBetweenSlices: Double
}

/// One segment definition and its display metadata from a DICOM Segmentation
/// Storage object. The color remains in DICOM CIELab here so the reader does
/// not need an AppKit dependency.
struct SwiftDICOMSegmentationDefinition {
    let number: Int
    let label: String
    let trackingUID: String?
    let recommendedDisplayCIELab: [Double]
}

/// A decoded SEG frame. `maskData` contains one byte per source pixel in
/// normal DICOM row order (zero outside, 255 inside).
struct SwiftDICOMSegmentationFrame {
    let segmentNumber: Int
    let geometry: SwiftDICOMFrameGeometryAttributes
    let referencedSOPInstanceUID: String?
    let maskData: Data
}

struct SwiftDICOMSegmentation {
    let sopInstanceUID: String
    let frameOfReferenceUID: String
    let rows: Int
    let columns: Int
    let segments: [SwiftDICOMSegmentationDefinition]
    let frames: [SwiftDICOMSegmentationFrame]
}

enum SwiftDICOMReaderError: LocalizedError {
    case invalidFile(String)
    case unsupportedTransferSyntax(String)
    case unsupportedPixelFormat(String)
    case missingAttribute(String)
    case invalidFrame(Int)
    case truncated(String)
    case jpegDecodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile(let reason):
            return "Invalid DICOM file: \(reason)"
        case .unsupportedTransferSyntax(let uid):
            return "Unsupported DICOM transfer syntax: \(uid)"
        case .unsupportedPixelFormat(let reason):
            return "Unsupported DICOM pixel format: \(reason)"
        case .missingAttribute(let name):
            return "Missing required DICOM attribute: \(name)"
        case .invalidFrame(let index):
            return "Invalid DICOM frame index: \(index)"
        case .truncated(let context):
            return "Truncated DICOM data while reading \(context)"
        case .jpegDecodeFailed:
            return "JPEG Lossless frame decoding failed"
        }
    }
}

/// Bounds-checked DICOM Part 10 reader for Horos' current display pipeline.
///
/// Supported transfer syntaxes are deliberately explicit and correspond to
/// the formats present in the active Horos database:
/// - Implicit VR Little Endian
/// - Explicit VR Little Endian
/// - JPEG Lossless, Non-Hierarchical, First-Order Prediction (Process 14 SV1)
///
/// Parsing, sequence traversal, frame selection, stored-value normalization,
/// and enhanced multi-frame metadata handling are all implemented here. The
/// JPEG bitstream alone is handed to the DCMTK codec boundary.
final class SwiftDICOMReader {
    static let implicitVRLittleEndianUID = "1.2.840.10008.1.2"
    static let explicitVRLittleEndianUID = "1.2.840.10008.1.2.1"
    static let jpegLosslessSV1UID = "1.2.840.10008.1.2.4.70"

    let sourcePath: String
    let transferSyntaxUID: String
    let numberOfFrames: Int

    private let data: Data
    private let root: SwiftDICOMDataset
    private let fileMeta: SwiftDICOMDataset?
    private let textEncoding: String.Encoding

    private static let readerCache: NSCache<NSString, SwiftDICOMReader> = {
        let cache = NSCache<NSString, SwiftDICOMReader>()
        cache.name = "org.horos.swift-dicom-reader"
        cache.countLimit = 512
        cache.totalCostLimit = 512 * 1_024 * 1_024
        return cache
    }()

    init(contentsOfFile path: String, metadataForExternalDecoder: Bool = false) throws {
        let mappedData: Data
        do {
            mappedData = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        } catch {
            throw SwiftDICOMReaderError.invalidFile(error.localizedDescription)
        }
        guard mappedData.count >= 8 else {
            throw SwiftDICOMReaderError.truncated("file header")
        }

        var parser = SwiftDICOMParser(data: mappedData)
        let parsed = try parser.parse(allowExternalPixelSyntax: metadataForExternalDecoder)
        guard Self.supportedTransferSyntaxUIDs.contains(parsed.transferSyntaxUID) ||
              (metadataForExternalDecoder && Self.externalPixelSyntaxUIDs.contains(parsed.transferSyntaxUID)) else {
            throw SwiftDICOMReaderError.unsupportedTransferSyntax(parsed.transferSyntaxUID)
        }

        data = mappedData
        sourcePath = path
        transferSyntaxUID = parsed.transferSyntaxUID
        root = parsed.dataset
        fileMeta = parsed.fileMeta
        textEncoding = Self.dicomTextEncoding(in: parsed.dataset)
        numberOfFrames = max(Self.integer(in: parsed.dataset, tag: .numberOfFrames) ?? 1, 1)
    }

    static func cached(contentsOfFile path: String) throws -> SwiftDICOMReader {
        let key = path as NSString
        if let cached = readerCache.object(forKey: key) {
            return cached
        }
        let reader = try SwiftDICOMReader(contentsOfFile: path)
        readerCache.setObject(reader, forKey: key, cost: reader.data.count)
        return reader
    }

    static func invalidateCache(forPath path: String) {
        readerCache.removeObject(forKey: path as NSString)
    }

    static func storedPixelFrame(contentsOfFile path: String, frameIndex: Int) -> SwiftDICOMStoredPixelFrame? {
        do {
            return try cached(contentsOfFile: path).storedPixelFrame(at: frameIndex)
        } catch {
            NSLog("SwiftDICOMReader: %@ (%@)", error.localizedDescription, path)
            return nil
        }
    }

    func stringValue(forTag tagString: String) -> String? {
        guard let tag = SwiftDICOMTag(dicomString: tagString) else { return nil }
        return Self.decodedString(in: root, tag: tag, encoding: textEncoding)
            ?? Self.decodedString(in: fileMeta, tag: tag, encoding: .ascii)
    }

    func firstStringValue(forTag tagString: String) -> String? {
        guard let tag = SwiftDICOMTag(dicomString: tagString) else {
            return nil
        }
        let dataset = root.firstDataset(containing: tag) ?? fileMeta?.firstDataset(containing: tag)
        return Self.decodedString(in: dataset, tag: tag, encoding: textEncoding)
    }

    func numberValue(forTag tagString: String) -> Double? {
        guard let tag = SwiftDICOMTag(dicomString: tagString) else { return nil }
        return Self.number(in: root, tag: tag)
    }

    func integerValue(forTag tagString: String) -> Int? {
        guard let value = numberValue(forTag: tagString), value.isFinite else { return nil }
        return Int(value.rounded())
    }

    func numberValues(forTag tagString: String) -> [Double] {
        guard let tag = SwiftDICOMTag(dicomString: tagString) else { return [] }
        return Self.numbers(in: root, tag: tag) ?? []
    }

    /// Decodes standards-compliant native binary or fractional DICOM SEG
    /// Pixel Data. Horos-authored objects normally restore their richer editable
    /// state from a private payload; this is the interoperable path for SEG
    /// objects authored elsewhere.
    func segmentation() throws -> SwiftDICOMSegmentation {
        let sopClassUID = Self.string(in: root, tag: .sopClassUID) ?? ""
        let modality = Self.string(in: root, tag: .modality)?.uppercased() ?? ""
        guard sopClassUID == "1.2.840.10008.5.1.4.1.1.66.4" || modality == "SEG" else {
            throw SwiftDICOMReaderError.unsupportedPixelFormat("the object is not DICOM Segmentation Storage")
        }
        guard transferSyntaxUID == Self.explicitVRLittleEndianUID
                || transferSyntaxUID == Self.implicitVRLittleEndianUID else {
            throw SwiftDICOMReaderError.unsupportedTransferSyntax(transferSyntaxUID)
        }
        guard let rows = Self.unsignedShort(in: root, tag: .rows), rows > 0,
              let columns = Self.unsignedShort(in: root, tag: .columns), columns > 0 else {
            throw SwiftDICOMReaderError.missingAttribute("SEG Rows/Columns")
        }

        let segmentDefinitions = root.sequenceItems(for: .segmentSequence).compactMap {
            item -> SwiftDICOMSegmentationDefinition? in
            guard let number = Self.unsignedShort(in: item, tag: .segmentNumber), number > 0 else {
                return nil
            }
            let label = Self.decodedString(in: item, tag: .segmentLabel, encoding: textEncoding)
                ?? "Segment \(number)"
            return SwiftDICOMSegmentationDefinition(
                number: number,
                label: label,
                trackingUID: Self.string(in: item, tag: .trackingUID),
                recommendedDisplayCIELab: Self.numbers(
                    in: item,
                    tag: .recommendedDisplayCIELabValue
                ) ?? []
            )
        }
        guard segmentDefinitions.isEmpty == false else {
            throw SwiftDICOMReaderError.missingAttribute("Segment Sequence")
        }

        let perFrameGroups = root.sequenceItems(for: .perFrameFunctionalGroups)
        guard perFrameGroups.count >= numberOfFrames else {
            throw SwiftDICOMReaderError.truncated("SEG Per-frame Functional Groups Sequence")
        }
        guard let pixelElement = root.element(for: .pixelData),
              let pixelRange = pixelElement.valueRange else {
            throw SwiftDICOMReaderError.missingAttribute("SEG Pixel Data")
        }

        let pixelCount = rows * columns
        let bitsAllocated = Self.unsignedShort(in: root, tag: .bitsAllocated) ?? 0
        let segmentationType = Self.string(in: root, tag: .segmentationType)?.uppercased() ?? "BINARY"
        let maximumFractionalValue = max(
            Self.unsignedShort(in: root, tag: .maximumFractionalValue) ?? 255,
            1
        )

        func decodedMask(frameIndex: Int) throws -> Data {
            var mask = [UInt8](repeating: 0, count: pixelCount)
            if segmentationType == "BINARY", bitsAllocated == 1 {
                // Native one-bit multi-frame Pixel Data is one continuous
                // little-endian bit stream; individual frames are not padded.
                let firstBit = frameIndex * pixelCount
                for pixelIndex in 0..<pixelCount {
                    let bitIndex = firstBit + pixelIndex
                    let byteIndex = pixelRange.lowerBound + bitIndex / 8
                    guard byteIndex < pixelRange.upperBound else {
                        throw SwiftDICOMReaderError.truncated("SEG binary frame \(frameIndex)")
                    }
                    if data[byteIndex] & UInt8(1 << (bitIndex & 7)) != 0 {
                        mask[pixelIndex] = 255
                    }
                }
            } else if bitsAllocated == 8 {
                let firstByte = pixelRange.lowerBound + frameIndex * pixelCount
                guard firstByte >= pixelRange.lowerBound,
                      firstByte + pixelCount <= pixelRange.upperBound else {
                    throw SwiftDICOMReaderError.truncated("SEG fractional frame \(frameIndex)")
                }
                let threshold = max(maximumFractionalValue / 2, 1)
                for pixelIndex in 0..<pixelCount where Int(data[firstByte + pixelIndex]) >= threshold {
                    mask[pixelIndex] = 255
                }
            } else if bitsAllocated == 16 {
                let firstByte = pixelRange.lowerBound + frameIndex * pixelCount * 2
                guard firstByte >= pixelRange.lowerBound,
                      firstByte + pixelCount * 2 <= pixelRange.upperBound else {
                    throw SwiftDICOMReaderError.truncated("SEG fractional frame \(frameIndex)")
                }
                let threshold = max(maximumFractionalValue / 2, 1)
                for pixelIndex in 0..<pixelCount {
                    if Int(data.uint16(at: firstByte + pixelIndex * 2)) >= threshold {
                        mask[pixelIndex] = 255
                    }
                }
            } else {
                throw SwiftDICOMReaderError.unsupportedPixelFormat(
                    "SEG type=\(segmentationType), BitsAllocated=\(bitsAllocated)"
                )
            }
            return Data(mask)
        }

        var frames: [SwiftDICOMSegmentationFrame] = []
        frames.reserveCapacity(numberOfFrames)
        for frameIndex in 0..<numberOfFrames {
            let group = perFrameGroups[frameIndex]
            let segmentIdentification = group.firstSequenceItem(for: .segmentIdentificationSequence)
            let segmentNumber = Self.unsignedShort(
                in: segmentIdentification,
                tag: .referencedSegmentNumber
            ) ?? segmentDefinitions[0].number
            guard segmentDefinitions.contains(where: { $0.number == segmentNumber }),
                  let geometry = frameGeometryAttributes(at: frameIndex) else {
                continue
            }
            let derivationImage = group.firstSequenceItem(for: .derivationImageSequence)
            let sourceImage = derivationImage?.firstSequenceItem(for: .sourceImageSequence)
            frames.append(SwiftDICOMSegmentationFrame(
                segmentNumber: segmentNumber,
                geometry: geometry,
                referencedSOPInstanceUID: Self.string(in: sourceImage, tag: .referencedSOPInstanceUID),
                maskData: try decodedMask(frameIndex: frameIndex)
            ))
        }
        guard frames.isEmpty == false else {
            throw SwiftDICOMReaderError.invalidFile("SEG contains no decodable spatial frames")
        }

        return SwiftDICOMSegmentation(
            sopInstanceUID: Self.string(in: root, tag: .sopInstanceUID) ?? sourcePath,
            frameOfReferenceUID: Self.string(in: root, tag: .frameOfReferenceUID) ?? "",
            rows: rows,
            columns: columns,
            segments: segmentDefinitions,
            frames: frames
        )
    }

    func phoneFrameCalibration(at frameIndex: Int) -> (slope: Float, intercept: Float, level: Float?, width: Float?) {
        let frame = root.sequenceItems(for: .perFrameFunctionalGroups).safeElement(at: frameIndex)
        let shared = root.sequenceItems(for: .sharedFunctionalGroups).first
        let slope = Self.nestedFloat(perFrame: frame, shared: shared, root: root,
            sequenceTag: .pixelValueTransformationSequence, valueTag: .rescaleSlope) ?? 1
        let intercept = Self.nestedFloat(perFrame: frame, shared: shared, root: root,
            sequenceTag: .pixelValueTransformationSequence, valueTag: .rescaleIntercept) ?? 0
        let level = Self.nestedFloat(perFrame: frame, shared: shared, root: root,
            sequenceTag: .frameVOILUTSequence, valueTag: .windowCenter)
        let width = Self.nestedFloat(perFrame: frame, shared: shared, root: root,
            sequenceTag: .frameVOILUTSequence, valueTag: .windowWidth).map { abs($0) }
        return (slope == 0 ? 1 : slope, intercept, level, width)
    }

    func storedPixelFrame(at frameIndex: Int) throws -> SwiftDICOMStoredPixelFrame {
        guard frameIndex >= 0, frameIndex < numberOfFrames else {
            throw SwiftDICOMReaderError.invalidFrame(frameIndex)
        }

        guard let width = Self.unsignedShort(in: root, tag: .columns), width > 0 else {
            throw SwiftDICOMReaderError.missingAttribute("Columns")
        }
        guard let height = Self.unsignedShort(in: root, tag: .rows), height > 0 else {
            throw SwiftDICOMReaderError.missingAttribute("Rows")
        }

        let samplesPerPixel = Self.unsignedShort(in: root, tag: .samplesPerPixel) ?? 1
        guard samplesPerPixel == 1 else {
            throw SwiftDICOMReaderError.unsupportedPixelFormat("only monochrome images are displayed")
        }

        let photometric = Self.string(in: root, tag: .photometricInterpretation)?.uppercased() ?? "MONOCHROME2"
        guard photometric == "MONOCHROME1" || photometric == "MONOCHROME2" else {
            throw SwiftDICOMReaderError.unsupportedPixelFormat(photometric)
        }

        let bitsAllocated = Self.unsignedShort(in: root, tag: .bitsAllocated) ?? 0
        guard bitsAllocated == 8 || bitsAllocated == 16 else {
            throw SwiftDICOMReaderError.unsupportedPixelFormat("BitsAllocated=\(bitsAllocated)")
        }
        let declaredBitsStored = Self.unsignedShort(in: root, tag: .bitsStored) ?? bitsAllocated
        let bitsStored = min(max(declaredBitsStored, 1), bitsAllocated)
        let highBit = Self.unsignedShort(in: root, tag: .highBit) ?? max(bitsStored - 1, 0)
        let isSigned = (Self.unsignedShort(in: root, tag: .pixelRepresentation) ?? 0) != 0

        let frameGroup = root.sequenceItems(for: .perFrameFunctionalGroups).safeElement(at: frameIndex)
        let sharedGroup = root.sequenceItems(for: .sharedFunctionalGroups).first

        let slopeValue = Self.nestedFloat(
            perFrame: frameGroup,
            shared: sharedGroup,
            root: root,
            sequenceTag: .pixelValueTransformationSequence,
            valueTag: .rescaleSlope
        ) ?? 1
        let interceptValue = Self.nestedFloat(
            perFrame: frameGroup,
            shared: sharedGroup,
            root: root,
            sequenceTag: .pixelValueTransformationSequence,
            valueTag: .rescaleIntercept
        ) ?? 0
        let slope = slopeValue == 0 ? 1 : slopeValue

        let spacing = Self.nestedNumbers(
            perFrame: frameGroup,
            shared: sharedGroup,
            root: root,
            sequenceTag: .pixelMeasuresSequence,
            valueTag: .pixelSpacing
        ) ?? Self.numbers(in: root, tag: .imagerPixelSpacing) ?? []
        let spacingY = max(Float(spacing.first ?? 1), 0.0001)
        let spacingX = max(Float(spacing.dropFirst().first ?? spacing.first ?? 1), 0.0001)

        let windowLevel = Self.nestedFloat(
            perFrame: frameGroup,
            shared: sharedGroup,
            root: root,
            sequenceTag: .frameVOILUTSequence,
            valueTag: .windowCenter
        )
        let windowWidth = Self.nestedFloat(
            perFrame: frameGroup,
            shared: sharedGroup,
            root: root,
            sequenceTag: .frameVOILUTSequence,
            valueTag: .windowWidth
        ).map { abs($0) }

        guard let pixelElement = root.element(for: .pixelData) else {
            throw SwiftDICOMReaderError.missingAttribute("PixelData")
        }
        let decodedFrame: Data
        switch transferSyntaxUID {
        case Self.implicitVRLittleEndianUID, Self.explicitVRLittleEndianUID:
            decodedFrame = try uncompressedFrame(
                pixelElement: pixelElement,
                frameIndex: frameIndex,
                width: width,
                height: height,
                samplesPerPixel: samplesPerPixel,
                bitsAllocated: bitsAllocated
            )
        case Self.jpegLosslessSV1UID:
            let jpegData = try encapsulatedFrame(pixelElement: pixelElement, frameIndex: frameIndex)
            guard let result = HorosDecodeJPEGFrame(
                jpegData,
                transferSyntaxUID,
                photometric,
                Int32(width),
                Int32(height),
                Int32(samplesPerPixel),
                Int32(bitsAllocated),
                Int32(bitsStored),
                isSigned,
                Int32(Self.unsignedShort(in: root, tag: .planarConfiguration) ?? 0)
            ) else {
                throw SwiftDICOMReaderError.jpegDecodeFailed
            }
            decodedFrame = result as Data
        default:
            throw SwiftDICOMReaderError.unsupportedTransferSyntax(transferSyntaxUID)
        }

        let pixelCount = width * height * samplesPerPixel
        let normalizedData = try Self.normalizedStoredData(
            decodedFrame,
            pixelCount: pixelCount,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: highBit,
            isSigned: isSigned
        )

        let inverse = photometric == "MONOCHROME1"
        return SwiftDICOMStoredPixelFrame(
            data: normalizedData,
            width: width,
            height: height,
            bitsStored: bitsStored,
            rescaleSlope: inverse ? -slope : slope,
            rescaleIntercept: inverse ? -interceptValue : interceptValue,
            isSigned: isSigned,
            pixelSpacingX: spacingX,
            pixelSpacingY: spacingY,
            windowLevel: windowLevel.map { inverse ? -$0 : $0 },
            windowWidth: windowWidth
        )
    }

    func dynamicFrameAttributes(at frameIndex: Int) -> SwiftDICOMDynamicFrameAttributes? {
        guard frameIndex >= 0, frameIndex < numberOfFrames else { return nil }
        let perFrameItem = root.sequenceItems(for: .perFrameFunctionalGroups).safeElement(at: frameIndex)
        let frameContent = perFrameItem?.firstSequenceItem(for: .frameContentSequence)
        let planePosition = perFrameItem?.firstSequenceItem(for: .planePositionSequence)
            ?? perFrameItem?.firstSequenceItem(for: .planePositionVolumeSequence)
        let cardiac = perFrameItem?.firstSequenceItem(for: .cardiacSynchronizationSequence)
        let temporalPosition = perFrameItem?.firstSequenceItem(for: .temporalPositionSequence)
        let mrEcho = perFrameItem?.firstSequenceItem(for: .mrEchoSequence)

        let isExplicit3DTemporal = Self.string(in: root, tag: .dimensionOrganizationType)?.uppercased()
            == "3D_TEMPORAL"
        let dimensionValues = Self.numbers(in: frameContent, tag: .dimensionIndexValues) ?? []
        let nuclearMedicineTemporalIndex = Self.numbers(in: root, tag: .timeSliceVector)?.safeElement(at: frameIndex)
            ?? Self.numbers(in: root, tag: .timeSlotVector)?.safeElement(at: frameIndex)
        let temporalIndex = Self.integer(in: frameContent, tag: .temporalPositionIndex)
            ?? Self.integer(in: root, tag: .temporalPositionIdentifier)
            ?? (isExplicit3DTemporal ? dimensionValues.first.map { Int($0.rounded()) } : nil)
            ?? nuclearMedicineTemporalIndex.map { Int($0.rounded()) }

        let nuclearMedicineSliceIndex = Self.numbers(in: root, tag: .sliceVector)?.safeElement(at: frameIndex)
        let inStackPosition = Self.integer(in: frameContent, tag: .inStackPositionNumber)
            ?? nuclearMedicineSliceIndex.map { Int($0.rounded()) }
        let positionValues = Self.numbers(in: planePosition, tag: .imagePositionPatient)
            ?? Self.numbers(in: planePosition, tag: .imagePositionVolume)
            ?? Self.numbers(in: root, tag: .imagePositionPatient)
            ?? Self.numbers(in: root, tag: .imagePositionVolume)
        let position = positionValues.flatMap { values -> SIMD3<Double>? in
            guard values.count >= 3 else { return nil }
            return SIMD3<Double>(values[0], values[1], values[2])
        }

        let triggerMilliseconds = Self.number(in: cardiac, tag: .nominalCardiacTriggerDelayTime)
            ?? Self.number(in: cardiac, tag: .actualCardiacTriggerDelayTime)
            ?? Self.number(in: cardiac, tag: .nominalPercentageOfCardiacPhase)
            ?? Self.number(in: temporalPosition, tag: .temporalPositionTimeOffset)
            ?? Self.number(in: root, tag: .triggerTime)
        let echoMilliseconds = Self.number(in: mrEcho, tag: .effectiveEchoTime)
            ?? Self.number(in: mrEcho, tag: .echoTime)
            ?? Self.number(in: root, tag: .echoTime)
        let acquisitionTime = Self.string(in: frameContent, tag: .frameAcquisitionDateTime)
            ?? Self.string(in: root, tag: .acquisitionDateTime)
            ?? Self.string(in: root, tag: .acquisitionTime)
            ?? Self.string(in: root, tag: .contentTime)

        let imageType = (Self.string(in: root, tag: .imageType) ?? "")
            .components(separatedBy: "\\")
            .filter { $0.isEmpty == false }
        let recommendedRate = Self.number(in: root, tag: .recommendedDisplayFrameRate)
            ?? Self.number(in: root, tag: .cineRate)
        let frameTime = Self.number(in: root, tag: .frameTime)
            ?? Self.numbers(in: root, tag: .frameTimeVector)?.first

        return SwiftDICOMDynamicFrameAttributes(
            temporalIndex: temporalIndex,
            inStackPosition: inStackPosition,
            position: position,
            acquisitionTime: acquisitionTime,
            triggerMilliseconds: triggerMilliseconds,
            echoMilliseconds: echoMilliseconds,
            numberOfTemporalPositions: Self.integer(in: root, tag: .numberOfTemporalPositions) ?? 0,
            hasExplicit3DTemporalDimension: isExplicit3DTemporal,
            imageType: imageType,
            hasMRDiffusionSequence: perFrameItem?.firstSequenceItem(for: .mrDiffusionSequence) != nil,
            recommendedDisplayFrameRate: recommendedRate,
            frameTimeMilliseconds: frameTime
        )
    }

    func frameGeometryAttributes(at frameIndex: Int) -> SwiftDICOMFrameGeometryAttributes? {
        guard frameIndex >= 0, frameIndex < numberOfFrames else { return nil }
        let sharedGroup = root.sequenceItems(for: .sharedFunctionalGroups).first
        let perFrameGroup = root.sequenceItems(for: .perFrameFunctionalGroups).safeElement(at: frameIndex)

        let planeOrientation = perFrameGroup?.firstSequenceItem(for: .planeOrientationSequence)
            ?? perFrameGroup?.firstSequenceItem(for: .planeOrientationVolumeSequence)
            ?? sharedGroup?.firstSequenceItem(for: .planeOrientationSequence)
            ?? sharedGroup?.firstSequenceItem(for: .planeOrientationVolumeSequence)
        let orientationValues = Self.numbers(in: planeOrientation, tag: .imageOrientationPatient)
            ?? Self.numbers(in: planeOrientation, tag: .imageOrientationVolume)
            ?? Self.numbers(in: root, tag: .imageOrientationPatient)
            ?? Self.numbers(in: root, tag: .imageOrientationVolume)

        var row = SIMD3<Double>(1, 0, 0)
        var column = SIMD3<Double>(0, 1, 0)
        if let orientationValues, orientationValues.count >= 6 {
            row = SIMD3<Double>(orientationValues[0], orientationValues[1], orientationValues[2])
            column = SIMD3<Double>(orientationValues[3], orientationValues[4], orientationValues[5])
        }

        let planePosition = perFrameGroup?.firstSequenceItem(for: .planePositionSequence)
            ?? perFrameGroup?.firstSequenceItem(for: .planePositionVolumeSequence)
            ?? sharedGroup?.firstSequenceItem(for: .planePositionSequence)
            ?? sharedGroup?.firstSequenceItem(for: .planePositionVolumeSequence)
        let positionValues = Self.numbers(in: planePosition, tag: .imagePositionPatient)
            ?? Self.numbers(in: planePosition, tag: .imagePositionVolume)
            ?? Self.numbers(in: root, tag: .imagePositionPatient)
            ?? Self.numbers(in: root, tag: .imagePositionVolume)
            ?? []
        let origin = positionValues.count >= 3
            ? SIMD3<Double>(positionValues[0], positionValues[1], positionValues[2])
            : .zero

        let pixelMeasures = perFrameGroup?.firstSequenceItem(for: .pixelMeasuresSequence)
            ?? sharedGroup?.firstSequenceItem(for: .pixelMeasuresSequence)
        let spacing = Self.numbers(in: pixelMeasures, tag: .pixelSpacing)
            ?? Self.numbers(in: root, tag: .pixelSpacing)
            ?? Self.numbers(in: root, tag: .imagerPixelSpacing)
            ?? []

        return SwiftDICOMFrameGeometryAttributes(
            origin: origin,
            row: row,
            column: column,
            spacingX: max(spacing.dropFirst().first ?? spacing.first ?? 1, 0.000001),
            spacingY: max(spacing.first ?? 1, 0.000001),
            sliceThickness: abs(
                Self.number(in: pixelMeasures, tag: .sliceThickness)
                    ?? Self.number(in: root, tag: .sliceThickness)
                    ?? 0
            ),
            spacingBetweenSlices: abs(
                Self.number(in: pixelMeasures, tag: .spacingBetweenSlices)
                    ?? Self.number(in: root, tag: .spacingBetweenSlices)
                    ?? 0
            )
        )
    }

    private func uncompressedFrame(
        pixelElement: SwiftDICOMElement,
        frameIndex: Int,
        width: Int,
        height: Int,
        samplesPerPixel: Int,
        bitsAllocated: Int
    ) throws -> Data {
        guard let valueRange = pixelElement.valueRange else {
            throw SwiftDICOMReaderError.invalidFile("uncompressed PixelData has no value")
        }
        let bytesPerSample = bitsAllocated / 8
        let frameByteCount = width * height * samplesPerPixel * bytesPerSample
        let lowerBound = valueRange.lowerBound + frameIndex * frameByteCount
        let upperBound = lowerBound + frameByteCount
        guard lowerBound >= valueRange.lowerBound, upperBound <= valueRange.upperBound else {
            throw SwiftDICOMReaderError.truncated("uncompressed PixelData frame \(frameIndex)")
        }
        return Data(data[lowerBound..<upperBound])
    }

    private func encapsulatedFrame(pixelElement: SwiftDICOMElement, frameIndex: Int) throws -> Data {
        let fragments = pixelElement.fragments
        guard fragments.isEmpty == false else {
            throw SwiftDICOMReaderError.truncated("encapsulated PixelData")
        }

        let selectedFragments: ArraySlice<SwiftDICOMFragment>
        let offsets = pixelElement.basicOffsetTable
        if offsets.isEmpty == false, offsets.indices.contains(frameIndex) {
            let baseOffset = fragments[0].itemHeaderOffset
            let startOffset = baseOffset + Int(offsets[frameIndex])
            let endOffset = offsets.indices.contains(frameIndex + 1)
                ? baseOffset + Int(offsets[frameIndex + 1])
                : Int.max
            let firstIndex = fragments.firstIndex { $0.itemHeaderOffset >= startOffset } ?? fragments.endIndex
            let endIndex = fragments.firstIndex { $0.itemHeaderOffset >= endOffset } ?? fragments.endIndex
            selectedFragments = fragments[firstIndex..<endIndex]
        } else if numberOfFrames == 1 {
            selectedFragments = fragments[...]
        } else if fragments.count == numberOfFrames {
            selectedFragments = fragments[frameIndex...frameIndex]
        } else {
            throw SwiftDICOMReaderError.unsupportedPixelFormat(
                "multi-frame encapsulated PixelData without a usable Basic Offset Table"
            )
        }

        guard selectedFragments.isEmpty == false else {
            throw SwiftDICOMReaderError.truncated("encapsulated PixelData frame \(frameIndex)")
        }
        var result = Data()
        result.reserveCapacity(selectedFragments.reduce(0) { $0 + $1.dataRange.count })
        for fragment in selectedFragments {
            result.append(contentsOf: data[fragment.dataRange])
        }
        return result
    }

    private static func normalizedStoredData(
        _ sourceData: Data,
        pixelCount: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        isSigned: Bool
    ) throws -> Data {
        guard pixelCount > 0 else {
            throw SwiftDICOMReaderError.invalidFile("empty pixel frame")
        }
        let bytesPerSample = bitsAllocated / 8
        guard sourceData.count >= pixelCount * bytesPerSample else {
            throw SwiftDICOMReaderError.truncated("decoded pixel frame")
        }

        let lowBit = max(highBit - bitsStored + 1, 0)
        let mask = bitsStored == 16 ? UInt16.max : UInt16((1 << bitsStored) - 1)
        let signBit = UInt16(1 << max(bitsStored - 1, 0))
        var output = [UInt16](repeating: 0, count: pixelCount)

        sourceData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<pixelCount {
                let rawValue: UInt16
                if bitsAllocated == 16 {
                    let byteOffset = index * 2
                    rawValue = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                } else {
                    rawValue = UInt16(bytes[index])
                }

                let storedValue = (rawValue >> UInt16(lowBit)) & mask
                output[index] = isSigned && storedValue & signBit != 0
                    ? storedValue | ~mask
                    : storedValue
            }
        }
        return output.withUnsafeBytes { Data($0) }
    }

    private static func nestedFloat(
        perFrame: SwiftDICOMDataset?,
        shared: SwiftDICOMDataset?,
        root: SwiftDICOMDataset,
        sequenceTag: SwiftDICOMTag,
        valueTag: SwiftDICOMTag
    ) -> Float? {
        float(in: perFrame?.firstSequenceItem(for: sequenceTag), tag: valueTag)
            ?? float(in: shared?.firstSequenceItem(for: sequenceTag), tag: valueTag)
            ?? float(in: root, tag: valueTag)
    }

    private static func nestedNumbers(
        perFrame: SwiftDICOMDataset?,
        shared: SwiftDICOMDataset?,
        root: SwiftDICOMDataset,
        sequenceTag: SwiftDICOMTag,
        valueTag: SwiftDICOMTag
    ) -> [Double]? {
        numbers(in: perFrame?.firstSequenceItem(for: sequenceTag), tag: valueTag)
            ?? numbers(in: shared?.firstSequenceItem(for: sequenceTag), tag: valueTag)
            ?? numbers(in: root, tag: valueTag)
    }

    private static func unsignedShort(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> Int? {
        guard let dataset, let element = dataset.element(for: tag) else { return nil }
        if element.vr == "US", let range = element.valueRange, range.count >= 2 {
            return Int(dataset.data.uint16(at: range.lowerBound))
        }
        return integer(in: dataset, tag: tag)
    }

    private static func integer(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> Int? {
        guard let value = number(in: dataset, tag: tag), value.isFinite else { return nil }
        return Int(value.rounded())
    }

    private static func number(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> Double? {
        numbers(in: dataset, tag: tag)?.first
    }

    private static func float(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> Float? {
        guard let component = string(in: dataset, tag: tag)?.components(separatedBy: "\\").first else {
            return nil
        }
        return Float(component.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func numbers(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> [Double]? {
        guard let dataset,
              let element = dataset.element(for: tag),
              let range = element.valueRange else {
            return nil
        }
        let values: [Double]
        switch element.vr {
        case "US":
            values = stride(from: range.lowerBound, to: range.upperBound - 1, by: 2)
                .map { Double(dataset.data.uint16(at: $0)) }
        case "SS":
            values = stride(from: range.lowerBound, to: range.upperBound - 1, by: 2)
                .map { Double(Int16(bitPattern: dataset.data.uint16(at: $0))) }
        case "UL", "AT":
            values = stride(from: range.lowerBound, to: range.upperBound - 3, by: 4)
                .map { Double(dataset.data.uint32(at: $0)) }
        case "SL":
            values = stride(from: range.lowerBound, to: range.upperBound - 3, by: 4)
                .map { Double(Int32(bitPattern: dataset.data.uint32(at: $0))) }
        case "FL":
            values = stride(from: range.lowerBound, to: range.upperBound - 3, by: 4)
                .map { Double(Float(bitPattern: dataset.data.uint32(at: $0))) }
        case "FD":
            values = stride(from: range.lowerBound, to: range.upperBound - 7, by: 8)
                .map { Double(bitPattern: dataset.data.uint64(at: $0)) }
        default:
            guard let value = string(in: dataset, tag: tag) else { return nil }
            values = value.components(separatedBy: "\\").compactMap {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return values.isEmpty ? nil : values
    }

    private static func string(in dataset: SwiftDICOMDataset?, tag: SwiftDICOMTag) -> String? {
        guard let dataset,
              let range = dataset.element(for: tag)?.valueRange,
              range.isEmpty == false else {
            return nil
        }
        let value = String(decoding: dataset.data[range], as: UTF8.self)
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\0")
        ))
        return trimmed.isEmpty == false ? trimmed : nil
    }

    private static func decodedString(
        in dataset: SwiftDICOMDataset?,
        tag: SwiftDICOMTag,
        encoding: String.Encoding
    ) -> String? {
        guard let dataset,
              let range = dataset.element(for: tag)?.valueRange,
              range.isEmpty == false else {
            return nil
        }

        let valueData = dataset.data.subdata(in: range)
        let value = String(data: valueData, encoding: encoding)
            ?? String(data: valueData, encoding: .utf8)
            ?? String(data: valueData, encoding: .isoLatin1)
        let trimmed = value?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\0")
        ))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func dicomTextEncoding(in dataset: SwiftDICOMDataset) -> String.Encoding {
        guard let characterSet = string(in: dataset, tag: .specificCharacterSet)?.uppercased() else {
            return .ascii
        }
        if characterSet.contains("ISO_IR 192") || characterSet.contains("ISO IR 192") {
            return .utf8
        }
        if characterSet.contains("ISO_IR 100") || characterSet.contains("ISO IR 100") {
            return .isoLatin1
        }
        if characterSet.contains("ISO 2022 IR 87") {
            return .iso2022JP
        }
        if characterSet.contains("ISO_IR 13") || characterSet.contains("ISO IR 13") {
            return .shiftJIS
        }
        return .utf8
    }

    // Metadata remains explicit-VR little-endian for these compressed pixel encodings.
    // Opt-in only: the normal Metal reader still rejects pixel encodings it cannot decode.
    fileprivate static let externalPixelSyntaxUIDs: Set<String> = [
        "1.2.840.10008.1.2.4.50", "1.2.840.10008.1.2.4.51", "1.2.840.10008.1.2.4.57",
        "1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81",
        "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91", "1.2.840.10008.1.2.5"
    ]

    private static let supportedTransferSyntaxUIDs: Set<String> = [
        implicitVRLittleEndianUID,
        explicitVRLittleEndianUID,
        jpegLosslessSV1UID
    ]
}

private struct SwiftDICOMTag: Hashable {
    let group: UInt16
    let element: UInt16

    var key: UInt32 { UInt32(group) << 16 | UInt32(element) }

    init(group: UInt16, element: UInt16) {
        self.group = group
        self.element = element
    }

    init?(dicomString: String) {
        let components = dicomString.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              let group = UInt16(components[0], radix: 16),
              let element = UInt16(components[1], radix: 16) else {
            return nil
        }
        self.init(group: group, element: element)
    }

    static let transferSyntaxUID = Self(group: 0x0002, element: 0x0010)
    static let privateInformationCreatorUID = Self(group: 0x0002, element: 0x0100)
    static let specificCharacterSet = Self(group: 0x0008, element: 0x0005)
    static let sopClassUID = Self(group: 0x0008, element: 0x0016)
    static let sopInstanceUID = Self(group: 0x0008, element: 0x0018)
    static let imageType = Self(group: 0x0008, element: 0x0008)
    static let modality = Self(group: 0x0008, element: 0x0060)
    static let sourceImageSequence = Self(group: 0x0008, element: 0x2112)
    static let derivationImageSequence = Self(group: 0x0008, element: 0x9124)
    static let referencedSOPInstanceUID = Self(group: 0x0008, element: 0x1155)
    static let acquisitionDateTime = Self(group: 0x0008, element: 0x002a)
    static let acquisitionTime = Self(group: 0x0008, element: 0x0032)
    static let contentTime = Self(group: 0x0008, element: 0x0033)
    static let recommendedDisplayFrameRate = Self(group: 0x0008, element: 0x2144)
    static let cineRate = Self(group: 0x0018, element: 0x0040)
    static let sliceThickness = Self(group: 0x0018, element: 0x0050)
    static let echoTime = Self(group: 0x0018, element: 0x0081)
    static let spacingBetweenSlices = Self(group: 0x0018, element: 0x0088)
    static let triggerTime = Self(group: 0x0018, element: 0x1060)
    static let frameTime = Self(group: 0x0018, element: 0x1063)
    static let frameTimeVector = Self(group: 0x0018, element: 0x1065)
    static let mrEchoSequence = Self(group: 0x0018, element: 0x9114)
    static let mrDiffusionSequence = Self(group: 0x0018, element: 0x9117)
    static let cardiacSynchronizationSequence = Self(group: 0x0018, element: 0x9118)
    static let frameAcquisitionDateTime = Self(group: 0x0018, element: 0x9074)
    static let effectiveEchoTime = Self(group: 0x0018, element: 0x9082)
    static let samplesPerPixel = Self(group: 0x0028, element: 0x0002)
    static let photometricInterpretation = Self(group: 0x0028, element: 0x0004)
    static let planarConfiguration = Self(group: 0x0028, element: 0x0006)
    static let numberOfFrames = Self(group: 0x0028, element: 0x0008)
    static let rows = Self(group: 0x0028, element: 0x0010)
    static let columns = Self(group: 0x0028, element: 0x0011)
    static let pixelSpacing = Self(group: 0x0028, element: 0x0030)
    static let imagerPixelSpacing = Self(group: 0x0018, element: 0x1164)
    static let bitsAllocated = Self(group: 0x0028, element: 0x0100)
    static let bitsStored = Self(group: 0x0028, element: 0x0101)
    static let highBit = Self(group: 0x0028, element: 0x0102)
    static let pixelRepresentation = Self(group: 0x0028, element: 0x0103)
    static let windowCenter = Self(group: 0x0028, element: 0x1050)
    static let windowWidth = Self(group: 0x0028, element: 0x1051)
    static let rescaleIntercept = Self(group: 0x0028, element: 0x1052)
    static let rescaleSlope = Self(group: 0x0028, element: 0x1053)
    static let pixelData = Self(group: 0x7fe0, element: 0x0010)

    static let frameOfReferenceUID = Self(group: 0x0020, element: 0x0052)
    static let temporalPositionIdentifier = Self(group: 0x0020, element: 0x0100)
    static let numberOfTemporalPositions = Self(group: 0x0020, element: 0x0105)
    static let imagePositionPatient = Self(group: 0x0020, element: 0x0032)
    static let imageOrientationPatient = Self(group: 0x0020, element: 0x0037)
    static let inStackPositionNumber = Self(group: 0x0020, element: 0x9057)
    static let frameContentSequence = Self(group: 0x0020, element: 0x9111)
    static let temporalPositionIndex = Self(group: 0x0020, element: 0x9128)
    static let dimensionIndexValues = Self(group: 0x0020, element: 0x9157)
    static let nominalCardiacTriggerDelayTime = Self(group: 0x0020, element: 0x9153)
    static let nominalPercentageOfCardiacPhase = Self(group: 0x0020, element: 0x9241)
    static let actualCardiacTriggerDelayTime = Self(group: 0x0020, element: 0x9252)
    static let imagePositionVolume = Self(group: 0x0020, element: 0x9301)
    static let imageOrientationVolume = Self(group: 0x0020, element: 0x9302)
    static let temporalPositionTimeOffset = Self(group: 0x0020, element: 0x930d)
    static let planePositionVolumeSequence = Self(group: 0x0020, element: 0x930e)
    static let planeOrientationVolumeSequence = Self(group: 0x0020, element: 0x930f)
    static let temporalPositionSequence = Self(group: 0x0020, element: 0x9310)
    static let dimensionOrganizationType = Self(group: 0x0020, element: 0x9311)
    static let pixelMeasuresSequence = Self(group: 0x0028, element: 0x9110)
    static let pixelValueTransformationSequence = Self(group: 0x0028, element: 0x9145)
    static let frameVOILUTSequence = Self(group: 0x0028, element: 0x9132)
    static let planePositionSequence = Self(group: 0x0020, element: 0x9113)
    static let planeOrientationSequence = Self(group: 0x0020, element: 0x9116)
    static let sharedFunctionalGroups = Self(group: 0x5200, element: 0x9229)
    static let perFrameFunctionalGroups = Self(group: 0x5200, element: 0x9230)

    static let segmentationType = Self(group: 0x0062, element: 0x0001)
    static let segmentSequence = Self(group: 0x0062, element: 0x0002)
    static let segmentNumber = Self(group: 0x0062, element: 0x0004)
    static let segmentLabel = Self(group: 0x0062, element: 0x0005)
    static let segmentIdentificationSequence = Self(group: 0x0062, element: 0x000a)
    static let referencedSegmentNumber = Self(group: 0x0062, element: 0x000b)
    static let recommendedDisplayCIELabValue = Self(group: 0x0062, element: 0x000d)
    static let maximumFractionalValue = Self(group: 0x0062, element: 0x000e)
    static let trackingUID = Self(group: 0x0062, element: 0x0021)

    static let timeSlotVector = Self(group: 0x0054, element: 0x0070)
    static let sliceVector = Self(group: 0x0054, element: 0x0080)
    static let timeSliceVector = Self(group: 0x0054, element: 0x0100)

    static let item = Self(group: 0xfffe, element: 0xe000)
    static let itemDelimitation = Self(group: 0xfffe, element: 0xe00d)
    static let sequenceDelimitation = Self(group: 0xfffe, element: 0xe0dd)
}

private struct SwiftDICOMFragment {
    let itemHeaderOffset: Int
    let dataRange: Range<Int>
}

private final class SwiftDICOMElement {
    let tag: SwiftDICOMTag
    let vr: String
    let valueRange: Range<Int>?
    let items: [SwiftDICOMDataset]
    let fragments: [SwiftDICOMFragment]
    let basicOffsetTable: [UInt32]

    init(
        tag: SwiftDICOMTag,
        vr: String,
        valueRange: Range<Int>? = nil,
        items: [SwiftDICOMDataset] = [],
        fragments: [SwiftDICOMFragment] = [],
        basicOffsetTable: [UInt32] = []
    ) {
        self.tag = tag
        self.vr = vr
        self.valueRange = valueRange
        self.items = items
        self.fragments = fragments
        self.basicOffsetTable = basicOffsetTable
    }
}

private final class SwiftDICOMDataset {
    let data: Data
    private var elements: [UInt32: SwiftDICOMElement] = [:]

    init(data: Data) {
        self.data = data
    }

    func add(_ element: SwiftDICOMElement) {
        elements[element.tag.key] = element
    }

    func element(for tag: SwiftDICOMTag) -> SwiftDICOMElement? {
        elements[tag.key]
    }

    func sequenceItems(for tag: SwiftDICOMTag) -> [SwiftDICOMDataset] {
        element(for: tag)?.items ?? []
    }

    func firstSequenceItem(for tag: SwiftDICOMTag) -> SwiftDICOMDataset? {
        sequenceItems(for: tag).first
    }

    func firstDataset(containing tag: SwiftDICOMTag) -> SwiftDICOMDataset? {
        if element(for: tag) != nil {
            return self
        }
        for element in elements.values {
            for item in element.items {
                if let match = item.firstDataset(containing: tag) {
                    return match
                }
            }
        }
        return nil
    }
}

private struct SwiftDICOMParseResult {
    let transferSyntaxUID: String
    let dataset: SwiftDICOMDataset
    let fileMeta: SwiftDICOMDataset?
}

private struct SwiftDICOMParser {
    private let data: Data
    private var cursor = 0

    init(data: Data) {
        self.data = data
    }

    mutating func parse(allowExternalPixelSyntax: Bool = false) throws -> SwiftDICOMParseResult {
        var transferSyntaxUID: String?
        var fileMeta: SwiftDICOMDataset?
        if data.count >= 132,
           data[128] == 0x44, data[129] == 0x49, data[130] == 0x43, data[131] == 0x4d {
            cursor = 132
            let meta = try parseFileMetaInformation()
            fileMeta = meta
            transferSyntaxUID = stringValue(in: meta, tag: .transferSyntaxUID)
        } else {
            cursor = 0
        }

        let syntaxUID = transferSyntaxUID ?? inferredTransferSyntaxUID(at: cursor)
        let explicitVR: Bool
        switch syntaxUID {
        case SwiftDICOMReader.implicitVRLittleEndianUID:
            explicitVR = false
        case SwiftDICOMReader.explicitVRLittleEndianUID, SwiftDICOMReader.jpegLosslessSV1UID:
            explicitVR = true
        default:
            guard allowExternalPixelSyntax, SwiftDICOMReader.externalPixelSyntaxUIDs.contains(syntaxUID) else {
                throw SwiftDICOMReaderError.unsupportedTransferSyntax(syntaxUID)
            }
            explicitVR = true
        }

        let dataset = try parseDataset(end: data.count, explicitVR: explicitVR, stopsAtDelimiter: false)
        return SwiftDICOMParseResult(transferSyntaxUID: syntaxUID, dataset: dataset, fileMeta: fileMeta)
    }

    private mutating func parseFileMetaInformation() throws -> SwiftDICOMDataset {
        let dataset = SwiftDICOMDataset(data: data)
        while cursor + 8 <= data.count {
            let tag = tag(at: cursor)
            guard tag.group == 0x0002 else { break }
            let header = try elementHeader(at: cursor, explicitVR: true)
            cursor = header.valueOffset
            let end = try checkedEnd(start: cursor, length: header.length, context: "file meta information")
            dataset.add(SwiftDICOMElement(tag: tag, vr: header.vr, valueRange: cursor..<end))
            cursor = end
        }
        return dataset
    }

    private mutating func parseDataset(
        end: Int,
        explicitVR: Bool,
        stopsAtDelimiter: Bool
    ) throws -> SwiftDICOMDataset {
        let dataset = SwiftDICOMDataset(data: data)
        while cursor + 8 <= min(end, data.count) {
            let elementStart = cursor
            let currentTag = tag(at: cursor)
            if currentTag == .itemDelimitation || currentTag == .sequenceDelimitation {
                guard stopsAtDelimiter else {
                    throw SwiftDICOMReaderError.invalidFile("unexpected sequence delimiter")
                }
                cursor += 8
                break
            }
            if currentTag == .item {
                throw SwiftDICOMReaderError.invalidFile("unexpected sequence item")
            }

            let header = try elementHeader(at: cursor, explicitVR: explicitVR)
            cursor = header.valueOffset
            let isUndefinedLength = header.length == UInt32.max
            let isImplicitItemSequence = explicitVR == false
                && isUndefinedLength == false
                && currentTag != .pixelData
                && header.length >= 8
                && cursor + 8 <= min(end, data.count)
                && tag(at: cursor) == .item
            let isSequence = header.vr == "SQ"
                || SwiftDICOMParser.implicitSequenceTags.contains(currentTag.key)
                || isImplicitItemSequence
                || (isUndefinedLength && currentTag != .pixelData)

            if currentTag == .pixelData, isUndefinedLength {
                let encapsulated = try parseEncapsulatedPixelData()
                dataset.add(SwiftDICOMElement(
                    tag: currentTag,
                    vr: header.vr,
                    fragments: encapsulated.fragments,
                    basicOffsetTable: encapsulated.basicOffsetTable
                ))
            } else if isSequence {
                let sequenceEnd = isUndefinedLength
                    ? nil
                    : try checkedEnd(start: cursor, length: header.length, context: "sequence")
                let items = try parseSequence(end: sequenceEnd, explicitVR: explicitVR)
                dataset.add(SwiftDICOMElement(tag: currentTag, vr: "SQ", items: items))
            } else {
                guard isUndefinedLength == false else {
                    throw SwiftDICOMReaderError.invalidFile("undefined-length non-sequence element")
                }
                let valueEnd = try checkedEnd(start: cursor, length: header.length, context: "element value")
                dataset.add(SwiftDICOMElement(tag: currentTag, vr: header.vr, valueRange: cursor..<valueEnd))
                cursor = valueEnd
            }

            guard cursor > elementStart else {
                throw SwiftDICOMReaderError.invalidFile("parser made no progress")
            }
            if cursor >= end { break }
        }
        return dataset
    }

    private mutating func parseSequence(end: Int?, explicitVR: Bool) throws -> [SwiftDICOMDataset] {
        var items: [SwiftDICOMDataset] = []
        let sequenceLimit = end ?? data.count
        while cursor + 8 <= min(sequenceLimit, data.count) {
            let itemTag = tag(at: cursor)
            let itemLength = data.uint32(at: cursor + 4)
            if itemTag == .sequenceDelimitation {
                cursor += 8
                break
            }
            guard itemTag == .item else {
                throw SwiftDICOMReaderError.invalidFile("sequence contains a non-item element")
            }
            cursor += 8
            if itemLength == UInt32.max {
                items.append(try parseDataset(end: sequenceLimit, explicitVR: explicitVR, stopsAtDelimiter: true))
            } else {
                let itemEnd = try checkedEnd(start: cursor, length: itemLength, context: "sequence item")
                items.append(try parseDataset(end: itemEnd, explicitVR: explicitVR, stopsAtDelimiter: false))
                cursor = itemEnd
            }
        }
        if let end {
            cursor = end
        }
        return items
    }

    private mutating func parseEncapsulatedPixelData() throws -> (
        fragments: [SwiftDICOMFragment],
        basicOffsetTable: [UInt32]
    ) {
        var fragments: [SwiftDICOMFragment] = []
        var offsets: [UInt32] = []
        var isFirstItem = true
        while cursor + 8 <= data.count {
            let itemHeaderOffset = cursor
            let itemTag = tag(at: cursor)
            let itemLength = data.uint32(at: cursor + 4)
            if itemTag == .sequenceDelimitation {
                cursor += 8
                return (fragments, offsets)
            }
            guard itemTag == .item, itemLength != UInt32.max else {
                throw SwiftDICOMReaderError.invalidFile("invalid encapsulated PixelData item")
            }
            cursor += 8
            let itemEnd = try checkedEnd(start: cursor, length: itemLength, context: "encapsulated PixelData item")
            if isFirstItem {
                guard itemLength % 4 == 0 else {
                    throw SwiftDICOMReaderError.invalidFile("invalid Basic Offset Table")
                }
                var offsetCursor = cursor
                while offsetCursor + 4 <= itemEnd {
                    offsets.append(data.uint32(at: offsetCursor))
                    offsetCursor += 4
                }
                isFirstItem = false
            } else {
                fragments.append(SwiftDICOMFragment(itemHeaderOffset: itemHeaderOffset, dataRange: cursor..<itemEnd))
            }
            cursor = itemEnd
        }
        throw SwiftDICOMReaderError.truncated("encapsulated PixelData sequence")
    }

    private func elementHeader(at offset: Int, explicitVR: Bool) throws -> (
        vr: String,
        length: UInt32,
        valueOffset: Int
    ) {
        guard offset + 8 <= data.count else {
            throw SwiftDICOMReaderError.truncated("element header")
        }
        if explicitVR {
            let vrBytes = [data[offset + 4], data[offset + 5]]
            guard let vr = String(bytes: vrBytes, encoding: .ascii), vr.count == 2 else {
                throw SwiftDICOMReaderError.invalidFile("invalid value representation")
            }
            if Self.longValueRepresentations.contains(vr) {
                guard offset + 12 <= data.count else {
                    throw SwiftDICOMReaderError.truncated("long element header")
                }
                return (vr, data.uint32(at: offset + 8), offset + 12)
            }
            return (vr, UInt32(data.uint16(at: offset + 6)), offset + 8)
        }

        let currentTag = tag(at: offset)
        return (Self.implicitVR(for: currentTag), data.uint32(at: offset + 4), offset + 8)
    }

    private func checkedEnd(start: Int, length: UInt32, context: String) throws -> Int {
        guard length != UInt32.max,
              start >= 0,
              start <= data.count,
              Int(length) <= data.count - start else {
            throw SwiftDICOMReaderError.truncated(context)
        }
        return start + Int(length)
    }

    private func tag(at offset: Int) -> SwiftDICOMTag {
        SwiftDICOMTag(group: data.uint16(at: offset), element: data.uint16(at: offset + 2))
    }

    private func inferredTransferSyntaxUID(at offset: Int) -> String {
        guard offset + 6 <= data.count else { return SwiftDICOMReader.implicitVRLittleEndianUID }
        let candidate = String(bytes: [data[offset + 4], data[offset + 5]], encoding: .ascii) ?? ""
        return Self.knownValueRepresentations.contains(candidate)
            ? SwiftDICOMReader.explicitVRLittleEndianUID
            : SwiftDICOMReader.implicitVRLittleEndianUID
    }

    private func stringValue(in dataset: SwiftDICOMDataset, tag: SwiftDICOMTag) -> String? {
        guard let range = dataset.element(for: tag)?.valueRange else { return nil }
        let value = String(decoding: data[range], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return value.isEmpty ? nil : value
    }

    private static func implicitVR(for tag: SwiftDICOMTag) -> String {
        switch tag.key {
        case SwiftDICOMTag.samplesPerPixel.key,
             SwiftDICOMTag.planarConfiguration.key,
             SwiftDICOMTag.rows.key,
             SwiftDICOMTag.columns.key,
             SwiftDICOMTag.bitsAllocated.key,
             SwiftDICOMTag.bitsStored.key,
             SwiftDICOMTag.highBit.key,
             SwiftDICOMTag.pixelRepresentation.key,
             SwiftDICOMTag.segmentNumber.key,
             SwiftDICOMTag.referencedSegmentNumber.key,
             SwiftDICOMTag.maximumFractionalValue.key,
             SwiftDICOMTag.recommendedDisplayCIELabValue.key:
            return "US"
        case SwiftDICOMTag.pixelData.key:
            return "OW"
        default:
            return implicitSequenceTags.contains(tag.key) ? "SQ" : "UN"
        }
    }

    private static let implicitSequenceTags: Set<UInt32> = [
        SwiftDICOMTag.mrEchoSequence.key,
        SwiftDICOMTag.mrDiffusionSequence.key,
        SwiftDICOMTag.cardiacSynchronizationSequence.key,
        SwiftDICOMTag.frameContentSequence.key,
        SwiftDICOMTag.pixelMeasuresSequence.key,
        SwiftDICOMTag.pixelValueTransformationSequence.key,
        SwiftDICOMTag.frameVOILUTSequence.key,
        SwiftDICOMTag.planePositionSequence.key,
        SwiftDICOMTag.planeOrientationSequence.key,
        SwiftDICOMTag.planePositionVolumeSequence.key,
        SwiftDICOMTag.planeOrientationVolumeSequence.key,
        SwiftDICOMTag.temporalPositionSequence.key,
        SwiftDICOMTag.sharedFunctionalGroups.key,
        SwiftDICOMTag.perFrameFunctionalGroups.key,
        SwiftDICOMTag.segmentSequence.key,
        SwiftDICOMTag.segmentIdentificationSequence.key,
        SwiftDICOMTag.derivationImageSequence.key,
        SwiftDICOMTag.sourceImageSequence.key
    ]

    private static let longValueRepresentations: Set<String> = [
        "OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"
    ]

    private static let knownValueRepresentations: Set<String> = [
        "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FL", "FD", "IS", "LO", "LT", "OB", "OD", "OF",
        "OL", "OV", "OW", "PN", "SH", "SL", "SQ", "SS", "ST", "SV", "TM", "UC", "UI", "UL", "UN",
        "UR", "US", "UT", "UV"
    ]
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | (UInt64(uint32(at: offset + 4)) << 32)
    }
}

private extension Array {
    func safeElement(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
