#include "ModernDCMTKBridge.h"

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdicdir.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/dcmsr/dsrtypes.h>
#include <dcmtk/dcmseg/segdoc.h>
#include <dcmtk/dcmseg/segment.h>
#include <dcmtk/dcmiod/cielabutil.h>
#include <dcmtk/dcmfg/fgderimg.h>
#include <dcmtk/dcmfg/fgfracon.h>
#include <dcmtk/dcmfg/fgplanor.h>
#include <dcmtk/dcmfg/fgplanpo.h>
#include <dcmtk/dcmfg/fgpixmsr.h>
#include <dcmtk/dcmjpeg/djdecode.h>
#include <dcmtk/dcmjpeg/djencode.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpls/djdecode.h>
#include <dcmtk/dcmjpls/djencode.h>
#include <dcmtk/dcmjpls/djrparam.h>
#if __has_include(<dcmtk/dcmj2k/djdecode.h>) && __has_include(<dcmtk/dcmj2k/djencode.h>) && __has_include(<dcmtk/dcmj2k/djrparam.h>)
#include <dcmtk/dcmj2k/djdecode.h>
#include <dcmtk/dcmj2k/djencode.h>
#include <dcmtk/dcmj2k/djrparam.h>
#define HOROS_HAS_DCMJ2K 1
#else
#define HOROS_HAS_DCMJ2K 0
#endif
#if __has_include(<dcmtk/dcmrle/dcrledrg.h>) && __has_include(<dcmtk/dcmrle/dcrleerg.h>) && __has_include(<dcmtk/dcmrle/dcrlerp.h>)
#include <dcmtk/dcmrle/dcrledrg.h>
#include <dcmtk/dcmrle/dcrleerg.h>
#include <dcmtk/dcmrle/dcrlerp.h>
#define HOROS_HAS_DCMRLE 1
#else
#define HOROS_HAS_DCMRLE 0
#endif
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/ofstd/ofstrutl.h>

#ifndef HOROS_MODERN_BRIDGE_HAS_OPENJPEG
#define HOROS_MODERN_BRIDGE_HAS_OPENJPEG 0
#endif

#if HOROS_MODERN_BRIDGE_HAS_OPENJPEG
#include "OPJSupport.h"
#endif

#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

static bool HorosModernDCMTKLoadStructuredReport(const char* path, DcmFileFormat& fileformat, DSRDocument& document);

static int HorosModernDCMTKSegmentationFailure(char** failureReason, const std::string& message)
{
    if (failureReason != nullptr)
    {
        std::free(*failureReason);
        *failureReason = static_cast<char*>(std::malloc(message.size() + 1));
        if (*failureReason != nullptr)
            std::memcpy(*failureReason, message.c_str(), message.size() + 1);
    }
    return 0;
}

static void HorosModernDCMTKClearDecodedFrame(HorosModernDCMTKDecodedFrame* frame)
{
    if (frame == nullptr)
        return;

    frame->pixels = nullptr;
    frame->pixelCount = 0;
    frame->rows = 0;
    frame->columns = 0;
    frame->bitsAllocated = 0;
    frame->bitsStored = 0;
    frame->pixelRepresentation = 0;
    frame->slope = 1.0;
    frame->intercept = 0.0;
    frame->windowCenter = 0.0;
    frame->windowWidth = 0.0;
    frame->pixelSpacingX = 1.0;
    frame->pixelSpacingY = 1.0;
    frame->sliceThickness = 0.0;
    frame->spacingBetweenSlices = 0.0;
    frame->origin[0] = frame->origin[1] = frame->origin[2] = 0.0;
    frame->orientation[0] = 1.0;
    frame->orientation[1] = 0.0;
    frame->orientation[2] = 0.0;
    frame->orientation[3] = 0.0;
    frame->orientation[4] = 1.0;
    frame->orientation[5] = 0.0;
    frame->orientation[6] = 0.0;
    frame->orientation[7] = 0.0;
    frame->orientation[8] = 1.0;
    frame->isOriginDefined = 0;
    frame->isRGB = 0;
    frame->failureReason = nullptr;
}

static char* HorosModernDCMTKDuplicateCString(const char* value)
{
    if (value == nullptr)
        return nullptr;

    const size_t length = std::strlen(value);
    char* copy = static_cast<char*>(std::malloc(length + 1));
    if (copy == nullptr)
        return nullptr;

    std::memcpy(copy, value, length + 1);
    return copy;
}

static char* HorosModernDCMTKDuplicateOFString(const OFString& value)
{
    if (value.empty())
        return nullptr;

    std::string sanitized;
    sanitized.reserve(value.size());
    for (size_t index = 0; index < value.size(); ++index)
    {
        const char c = value[index];
        if (c != '\0')
            sanitized.push_back(c);
    }

    while (!sanitized.empty() && (sanitized.back() == '\0' || sanitized.back() == ' '))
        sanitized.pop_back();

    if (sanitized.empty())
        return nullptr;

    return HorosModernDCMTKDuplicateCString(sanitized.c_str());
}

static int HorosModernDCMTKValidationFail(char** failureReason, const std::string& reason)
{
    if (failureReason != nullptr)
        *failureReason = HorosModernDCMTKDuplicateCString(reason.c_str());
    return 0;
}

static int HorosModernDCMTKDecodedFrameFail(HorosModernDCMTKDecodedFrame* frame, const std::string& reason)
{
    if (frame != nullptr)
    {
        if (frame->failureReason != nullptr)
            std::free(frame->failureReason);
        frame->failureReason = HorosModernDCMTKDuplicateCString(reason.c_str());
    }

    return 0;
}

static void HorosModernDCMTKEnsureDataDictionary()
{
    if (dcmDataDict.isDictionaryLoaded())
        return;

    DcmDataDictionary& dictionary = dcmDataDict.wrlock();
    dictionary.reloadDictionaries(OFFalse, OFTrue);
    dcmDataDict.wrunlock();
}

static void HorosModernDCMTKEnsureCodecRegistration()
{
    static bool registered = false;
    if (registered)
        return;

    DJDecoderRegistration::registerCodecs();
    DJEncoderRegistration::registerCodecs();
#if HOROS_HAS_DCMRLE
    DcmRLEDecoderRegistration::registerCodecs();
    DcmRLEEncoderRegistration::registerCodecs();
#endif
    DJLSDecoderRegistration::registerCodecs();
    DJLSEncoderRegistration::registerCodecs();
#if HOROS_HAS_DCMJ2K
    DJ2KDecoderRegistration::registerCodecs();
    DJ2KEncoderRegistration::registerCodecs();
#endif

    registered = true;
}

static OFCondition HorosModernDCMTKChooseUncompressedRepresentation(DcmDataset* dataset, std::string& failureReason)
{
    if (dataset == nullptr)
    {
        failureReason = "missing dataset";
        return EC_IllegalParameter;
    }

    OFCondition status = dataset->chooseRepresentation(EXS_LittleEndianExplicit, nullptr);
    if (status.bad())
    {
        std::ostringstream reason;
        reason << "chooseRepresentation failed status=" << status.text();
        failureReason = reason.str();
        return status;
    }

    if (!dataset->canWriteXfer(EXS_LittleEndianExplicit))
    {
        failureReason = "chooseRepresentation failed: cannot write Explicit VR Little Endian";
        return EC_CannotChangeRepresentation;
    }

    return EC_Normal;
}

static bool HorosModernDCMTKIsJPEG2000TransferSyntax(E_TransferSyntax transferSyntax)
{
    return transferSyntax == EXS_JPEG2000LosslessOnly ||
           transferSyntax == EXS_JPEG2000 ||
           transferSyntax == EXS_JPEG2000MulticomponentLosslessOnly ||
           transferSyntax == EXS_JPEG2000Multicomponent;
}

static int HorosModernDCMTKSignExtendStoredBits(unsigned int value, Uint16 bitsStored)
{
    if (bitsStored == 0)
        return static_cast<int>(value);
    if (bitsStored >= 32)
        return static_cast<int>(value);

    const unsigned int mask = 1U << (bitsStored - 1);
    const unsigned int storedMask = (1U << bitsStored) - 1U;
    const unsigned int storedValue = value & storedMask;
    return static_cast<int>((storedValue ^ mask) - mask);
}

#if HOROS_MODERN_BRIDGE_HAS_OPENJPEG
static bool HorosModernDCMTKAppendPixelItemBytes(DcmPixelSequence* pixelSequence,
                                                 unsigned long itemIndex,
                                                 std::vector<unsigned char>& compressed,
                                                 std::string& failureReason)
{
    DcmPixelItem* pixelItem = nullptr;
    OFCondition status = pixelSequence->getItem(pixelItem, itemIndex);
    if (status.bad() || pixelItem == nullptr)
    {
        std::ostringstream reason;
        reason << "missing JPEG 2000 fragment item=" << itemIndex << " status=" << status.text();
        failureReason = reason.str();
        return false;
    }

    Uint8* itemBytes = nullptr;
    status = pixelItem->getUint8Array(itemBytes);
    const Uint32 itemLength = pixelItem->getLength();
    if (status.bad() || itemBytes == nullptr || itemLength == 0)
    {
        std::ostringstream reason;
        reason << "empty JPEG 2000 fragment item=" << itemIndex << " status=" << status.text();
        failureReason = reason.str();
        return false;
    }

    compressed.insert(compressed.end(), itemBytes, itemBytes + itemLength);
    return true;
}

static bool HorosModernDCMTKCopyJPEG2000FrameBytes(DcmPixelData* pixelData,
                                                   E_TransferSyntax transferSyntax,
                                                   unsigned long frameIndex,
                                                   long int frameCount,
                                                   std::vector<unsigned char>& compressed,
                                                   std::string& failureReason)
{
    DcmPixelSequence* pixelSequence = nullptr;
    OFCondition status = pixelData->getEncapsulatedRepresentation(transferSyntax, nullptr, pixelSequence);
    if (status.bad() || pixelSequence == nullptr)
    {
        std::ostringstream reason;
        reason << "missing encapsulated JPEG 2000 representation status=" << status.text();
        failureReason = reason.str();
        return false;
    }

    const unsigned long itemCount = pixelSequence->card();
    if (itemCount < 2)
    {
        std::ostringstream reason;
        reason << "JPEG 2000 pixel sequence has no frame fragments itemCount=" << itemCount;
        failureReason = reason.str();
        return false;
    }

    // Item 0 is the Basic Offset Table. Most Horos preview data is one DICOM
    // frame per file; concatenate all fragments in that case.
    if (frameCount <= 1)
    {
        for (unsigned long itemIndex = 1; itemIndex < itemCount; ++itemIndex)
        {
            if (!HorosModernDCMTKAppendPixelItemBytes(pixelSequence, itemIndex, compressed, failureReason))
                return false;
        }
        return !compressed.empty();
    }

    // Common multi-frame case: one compressed fragment per frame after the
    // offset table. More complex multi-fragment frames still use DCMTK's codec.
    const unsigned long itemIndex = frameIndex + 1;
    if (itemIndex < itemCount)
        return HorosModernDCMTKAppendPixelItemBytes(pixelSequence, itemIndex, compressed, failureReason);

    std::ostringstream reason;
    reason << "unsupported JPEG 2000 frame layout frame=" << frameIndex
           << " frames=" << frameCount
           << " itemCount=" << itemCount;
    failureReason = reason.str();
    return false;
}

static bool HorosModernDCMTKCopyOpenJPEGRawDecodedFrame(DcmPixelData* pixelData,
                                                        E_TransferSyntax transferSyntax,
                                                        unsigned long frameIndex,
                                                        long int frameCount,
                                                        unsigned long pixelCount,
                                                        std::vector<unsigned char>& decodedBytes,
                                                        std::string& failureReason)
{
    if (!HorosModernDCMTKIsJPEG2000TransferSyntax(transferSyntax))
    {
        failureReason = "transfer syntax is not JPEG 2000";
        return false;
    }

    std::vector<unsigned char> compressed;
    if (!HorosModernDCMTKCopyJPEG2000FrameBytes(pixelData, transferSyntax, frameIndex, frameCount, compressed, failureReason))
        return false;

    long decodedLength = 0;
    int colorModel = 0;
    OPJSupport opj;
    void* decoded = opj.decompressJPEG2K(static_cast<void*>(compressed.data()),
                                         static_cast<long>(compressed.size()),
                                         &decodedLength,
                                         &colorModel);
    if (decoded == nullptr || decodedLength <= 0)
    {
        failureReason = "OpenJPEG failed to decode JPEG 2000 frame";
        return false;
    }

    if (colorModel != 0)
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded unsupported color model=" << colorModel;
        failureReason = reason.str();
        std::free(decoded);
        return false;
    }

    if (pixelCount == 0 || decodedLength < 0 || static_cast<unsigned long>(decodedLength) < pixelCount)
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded frame too small length=" << decodedLength << " pixels=" << pixelCount;
        failureReason = reason.str();
        std::free(decoded);
        return false;
    }

    const unsigned char* byteSource = static_cast<const unsigned char*>(decoded);
    decodedBytes.assign(byteSource, byteSource + decodedLength);
    std::free(decoded);
    return true;
}

static float* HorosModernDCMTKCopyOpenJPEGDecodedPixels(DcmPixelData* pixelData,
                                                        E_TransferSyntax transferSyntax,
                                                        unsigned long frameIndex,
                                                        long int frameCount,
                                                        unsigned long pixelCount,
                                                        Uint16 bitsAllocated,
                                                        Uint16 bitsStored,
                                                        Uint16 pixelRepresentation,
                                                        Float64 slope,
                                                        Float64 intercept,
                                                        std::string& failureReason)
{
    if (!HorosModernDCMTKIsJPEG2000TransferSyntax(transferSyntax))
    {
        failureReason = "transfer syntax is not JPEG 2000";
        return nullptr;
    }

    std::vector<unsigned char> compressed;
    if (!HorosModernDCMTKCopyJPEG2000FrameBytes(pixelData, transferSyntax, frameIndex, frameCount, compressed, failureReason))
        return nullptr;

    long decodedLength = 0;
    int colorModel = 0;
    OPJSupport opj;
    void* decoded = opj.decompressJPEG2K(static_cast<void*>(compressed.data()),
                                         static_cast<long>(compressed.size()),
                                         &decodedLength,
                                         &colorModel);
    if (decoded == nullptr || decodedLength <= 0)
    {
        failureReason = "OpenJPEG failed to decode JPEG 2000 frame";
        return nullptr;
    }

    if (colorModel != 0)
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded unsupported color model=" << colorModel;
        failureReason = reason.str();
        std::free(decoded);
        return nullptr;
    }

    if (pixelCount == 0 || decodedLength < 0 || static_cast<unsigned long>(decodedLength) < pixelCount)
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded frame too small length=" << decodedLength << " pixels=" << pixelCount;
        failureReason = reason.str();
        std::free(decoded);
        return nullptr;
    }

    const unsigned long decodedBytesPerPixel = static_cast<unsigned long>(decodedLength) / pixelCount;
    if (decodedBytesPerPixel == 0)
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded invalid bytesPerPixel length=" << decodedLength << " pixels=" << pixelCount;
        failureReason = reason.str();
        std::free(decoded);
        return nullptr;
    }

    float* pixels = static_cast<float*>(std::malloc(sizeof(float) * pixelCount));
    if (pixels == nullptr)
    {
        failureReason = "pixel allocation failed";
        std::free(decoded);
        return nullptr;
    }

    const bool isSigned = pixelRepresentation != 0;
    if (decodedBytesPerPixel == 1)
    {
        const Uint8* source = reinterpret_cast<const Uint8*>(decoded);
        for (unsigned long index = 0; index < pixelCount; ++index)
        {
            int value = isSigned ? static_cast<Sint8>(source[index]) : static_cast<int>(source[index]);
            if (isSigned && bitsStored > 0 && bitsStored < bitsAllocated)
                value = HorosModernDCMTKSignExtendStoredBits(static_cast<unsigned int>(source[index]), bitsStored);
            pixels[index] = static_cast<float>(static_cast<double>(value) * slope + intercept);
        }
    }
    else if (decodedBytesPerPixel == 2)
    {
        const Uint16* source = reinterpret_cast<const Uint16*>(decoded);
        for (unsigned long index = 0; index < pixelCount; ++index)
        {
            int value = isSigned ? static_cast<int>(static_cast<Sint16>(source[index])) : static_cast<int>(source[index]);
            if (isSigned && bitsStored > 0 && bitsStored < bitsAllocated)
                value = HorosModernDCMTKSignExtendStoredBits(static_cast<int>(source[index]), bitsStored);
            pixels[index] = static_cast<float>(static_cast<double>(value) * slope + intercept);
        }
    }
    else if (decodedBytesPerPixel == 4)
    {
        const Uint32* source = reinterpret_cast<const Uint32*>(decoded);
        for (unsigned long index = 0; index < pixelCount; ++index)
        {
            double value = isSigned ? static_cast<double>(static_cast<Sint32>(source[index])) : static_cast<double>(source[index]);
            pixels[index] = static_cast<float>(value * slope + intercept);
        }
    }
    else
    {
        std::ostringstream reason;
        reason << "OpenJPEG decoded unsupported bytesPerPixel=" << decodedBytesPerPixel
               << " length=" << decodedLength;
        failureReason = reason.str();
        std::free(decoded);
        std::free(pixels);
        return nullptr;
    }

    std::free(decoded);
    return pixels;
}

static bool HorosModernDCMTKWriteOpenJPEGDecompressedFile(DcmFileFormat& fileformat,
                                                          const char* outputPath,
                                                          E_TransferSyntax originalSyntax)
{
    if (outputPath == nullptr || outputPath[0] == '\0' || !HorosModernDCMTKIsJPEG2000TransferSyntax(originalSyntax))
        return false;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return false;

    Uint16 rows = 0;
    Uint16 columns = 0;
    Uint16 samplesPerPixel = 1;
    Uint16 bitsAllocated = 0;
    Uint16 bitsStored = 0;
    if (dataset->findAndGetUint16(DCM_Rows, rows).bad() ||
        dataset->findAndGetUint16(DCM_Columns, columns).bad() ||
        dataset->findAndGetUint16(DCM_BitsAllocated, bitsAllocated).bad() ||
        dataset->findAndGetUint16(DCM_BitsStored, bitsStored).bad())
        return false;

    dataset->findAndGetUint16(DCM_SamplesPerPixel, samplesPerPixel);
    if (rows == 0 || columns == 0 || samplesPerPixel != 1)
        return false;
    if (bitsAllocated != 8 && bitsAllocated != 16 && bitsAllocated != 32)
        return false;
    if (bitsStored == 0 || bitsStored > bitsAllocated)
        bitsStored = bitsAllocated;

    long int frameCount = 1;
    OFCondition numberOfFramesStatus = dataset->findAndGetLongInt(DCM_NumberOfFrames, frameCount);
    if (numberOfFramesStatus.bad() || frameCount < 1)
        frameCount = 1;

    DcmElement* element = nullptr;
    if (dataset->findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
        return false;

    DcmPixelData* pixelData = dynamic_cast<DcmPixelData*>(element);
    if (pixelData == nullptr)
        return false;

    const unsigned long pixelCount = static_cast<unsigned long>(rows) * static_cast<unsigned long>(columns);
    const unsigned long bytesPerPixel = bitsAllocated / 8;
    const unsigned long expectedFrameBytes = pixelCount * bytesPerPixel;
    if (expectedFrameBytes == 0)
        return false;

    std::vector<unsigned char> allFrames;
    allFrames.reserve(expectedFrameBytes * static_cast<unsigned long>(frameCount));
    for (long int frameIndex = 0; frameIndex < frameCount; ++frameIndex)
    {
        std::vector<unsigned char> decodedFrame;
        std::string failureReason;
        if (!HorosModernDCMTKCopyOpenJPEGRawDecodedFrame(pixelData,
                                                         originalSyntax,
                                                         static_cast<unsigned long>(frameIndex),
                                                         frameCount,
                                                         pixelCount,
                                                         decodedFrame,
                                                         failureReason))
            return false;

        if (decodedFrame.size() < expectedFrameBytes)
            return false;

        allFrames.insert(allFrames.end(), decodedFrame.data(), decodedFrame.data() + expectedFrameBytes);
    }

    OFCondition status = EC_Normal;
    if (bitsAllocated == 8)
    {
        status = dataset->putAndInsertUint8Array(DCM_PixelData,
                                                 reinterpret_cast<const Uint8*>(allFrames.data()),
                                                 static_cast<unsigned long>(allFrames.size()),
                                                 OFTrue);
    }
    else if (bitsAllocated == 16)
    {
        std::vector<Uint16> words(allFrames.size() / sizeof(Uint16));
        std::memcpy(words.data(), allFrames.data(), words.size() * sizeof(Uint16));
        status = dataset->putAndInsertUint16Array(DCM_PixelData,
                                                  words.data(),
                                                  static_cast<unsigned long>(words.size()),
                                                  OFTrue);
    }
    else
    {
        std::vector<Uint32> words(allFrames.size() / sizeof(Uint32));
        std::memcpy(words.data(), allFrames.data(), words.size() * sizeof(Uint32));
        status = dataset->putAndInsertUint32Array(DCM_PixelData,
                                                  words.data(),
                                                  static_cast<unsigned long>(words.size()),
                                                  OFTrue);
    }

    if (status.bad())
        return false;

    fileformat.loadAllDataIntoMemory();
    status = fileformat.saveFile(outputPath, EXS_LittleEndianExplicit);
    return status.good();
}

static int HorosModernDCMTKOpenJPEGCompressionRate(E_TransferSyntax requestedSyntax,
                                                   int quality,
                                                   Uint16 rows,
                                                   Uint16 columns)
{
    if (requestedSyntax == EXS_JPEG2000LosslessOnly || quality <= 0)
        return 0;

    switch (quality)
    {
        case 1:
            return 4;
        case 2:
            return (columns <= 600 || rows <= 600) ? 6 : 8;
        case 3:
            return 16;
        default:
            return 0;
    }
}

static bool HorosModernDCMTKCopyNativeUncompressedFrame(DcmDataset* dataset,
                                                        DcmPixelData* pixelData,
                                                        unsigned long frameIndex,
                                                        std::vector<unsigned char>& frameBytes)
{
    if (dataset == nullptr || pixelData == nullptr)
        return false;

    Uint32 frameSize = 0;
    OFCondition status = pixelData->getUncompressedFrameSize(dataset, frameSize, OFFalse);
    if (status.bad() || frameSize == 0)
        return false;

    const Uint32 bufferSize = (frameSize & 1) ? frameSize + 1 : frameSize;
    frameBytes.assign(bufferSize, 0);

    Uint32 startFragment = 0;
    OFString colorModel;
    status = pixelData->getUncompressedFrame(dataset,
                                             static_cast<Uint32>(frameIndex),
                                             startFragment,
                                             reinterpret_cast<Uint8*>(frameBytes.data()),
                                             bufferSize,
                                             colorModel,
                                             nullptr);
    if (status.bad())
        return false;

    frameBytes.resize(frameSize);
    return true;
}

static bool HorosModernDCMTKWriteOpenJPEGCompressedFile(DcmFileFormat& fileformat,
                                                        const char* outputPath,
                                                        E_TransferSyntax requestedSyntax,
                                                        int quality)
{
    if (outputPath == nullptr || outputPath[0] == '\0')
        return false;
    if (requestedSyntax != EXS_JPEG2000LosslessOnly && requestedSyntax != EXS_JPEG2000)
        return false;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return false;

    Uint16 rows = 0;
    Uint16 columns = 0;
    Uint16 samplesPerPixel = 1;
    Uint16 bitsAllocated = 0;
    Uint16 bitsStored = 0;
    Uint16 pixelRepresentation = 0;
    if (dataset->findAndGetUint16(DCM_Rows, rows).bad() ||
        dataset->findAndGetUint16(DCM_Columns, columns).bad() ||
        dataset->findAndGetUint16(DCM_BitsAllocated, bitsAllocated).bad() ||
        dataset->findAndGetUint16(DCM_BitsStored, bitsStored).bad())
        return false;

    dataset->findAndGetUint16(DCM_SamplesPerPixel, samplesPerPixel);
    dataset->findAndGetUint16(DCM_PixelRepresentation, pixelRepresentation);
    if (rows == 0 || columns == 0 || samplesPerPixel != 1)
        return false;
    if (bitsAllocated != 8 && bitsAllocated != 16 && bitsAllocated != 32)
        return false;
    if (bitsStored == 0 || bitsStored > bitsAllocated)
        bitsStored = bitsAllocated;

    long int frameCount = 1;
    OFCondition numberOfFramesStatus = dataset->findAndGetLongInt(DCM_NumberOfFrames, frameCount);
    if (numberOfFramesStatus.bad() || frameCount < 1)
        frameCount = 1;

    DcmElement* element = nullptr;
    if (dataset->findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
        return false;

    DcmPixelData* sourcePixelData = dynamic_cast<DcmPixelData*>(element);
    if (sourcePixelData == nullptr)
        return false;

    std::unique_ptr<DcmPixelData> compressedPixelData(new DcmPixelData(DCM_PixelData));
    std::unique_ptr<DcmPixelSequence> pixelSequence(new DcmPixelSequence(DcmTag(DCM_PixelData, EVR_OB)));
    std::unique_ptr<DcmPixelItem> offsetTable(new DcmPixelItem(DcmTag(DCM_Item, EVR_OB)));
    OFCondition status = pixelSequence->insert(offsetTable.get());
    if (status.bad())
        return false;
    offsetTable.release();

    const int rate = HorosModernDCMTKOpenJPEGCompressionRate(requestedSyntax, quality, rows, columns);
    unsigned long totalCompressedBytes = 0;
    unsigned long totalUncompressedBytes = 0;

    for (long int frameIndex = 0; frameIndex < frameCount; ++frameIndex)
    {
        std::vector<unsigned char> frameBytes;
        if (!HorosModernDCMTKCopyNativeUncompressedFrame(dataset,
                                                        sourcePixelData,
                                                        static_cast<unsigned long>(frameIndex),
                                                        frameBytes) ||
            frameBytes.empty())
            return false;

        long compressedLength = 0;
        OPJSupport opj;
        unsigned char* compressedBytes = opj.compressJPEG2K(static_cast<void*>(frameBytes.data()),
                                                            samplesPerPixel,
                                                            rows,
                                                            columns,
                                                            bitsStored,
                                                            static_cast<unsigned char>(bitsAllocated),
                                                            pixelRepresentation != 0,
                                                            rate,
                                                            &compressedLength);
        if (compressedBytes == nullptr || compressedLength <= 0)
            return false;

        const Uint8* fragmentBytes = reinterpret_cast<const Uint8*>(compressedBytes);
        unsigned long fragmentLength = static_cast<unsigned long>(compressedLength);
        std::vector<unsigned char> paddedCompressedBytes;
        if (fragmentLength & 1)
        {
            paddedCompressedBytes.assign(compressedBytes, compressedBytes + fragmentLength);
            paddedCompressedBytes.push_back(0);
            fragmentBytes = reinterpret_cast<const Uint8*>(paddedCompressedBytes.data());
            fragmentLength = static_cast<unsigned long>(paddedCompressedBytes.size());
        }

        std::unique_ptr<DcmPixelItem> fragment(new DcmPixelItem(DcmTag(DCM_Item, EVR_OB)));
        status = fragment->putUint8Array(fragmentBytes, fragmentLength);
        std::free(compressedBytes);
        if (status.bad())
            return false;

        status = pixelSequence->insert(fragment.get());
        if (status.bad())
            return false;
        fragment.release();

        totalUncompressedBytes += static_cast<unsigned long>(frameBytes.size());
        totalCompressedBytes += static_cast<unsigned long>(compressedLength);
    }

    compressedPixelData->putOriginalRepresentation(requestedSyntax, nullptr, pixelSequence.get());
    pixelSequence.release();
    status = dataset->insert(compressedPixelData.get(), OFTrue);
    if (status.bad())
        return false;
    compressedPixelData.release();

    if (requestedSyntax == EXS_JPEG2000 && totalCompressedBytes > 0)
    {
        dataset->putAndInsertString(DCM_LossyImageCompression, "01", OFTrue);
        dataset->putAndInsertString(DCM_LossyImageCompressionMethod, "ISO_15444_1", OFTrue);

        const double ratio = static_cast<double>(totalUncompressedBytes) / static_cast<double>(totalCompressedBytes);
        char ratioString[64];
        std::snprintf(ratioString, sizeof(ratioString), "%.3g", ratio);
        dataset->putAndInsertString(DCM_LossyImageCompressionRatio, ratioString, OFTrue);
    }

    fileformat.loadAllDataIntoMemory();
    status = fileformat.saveFile(outputPath, requestedSyntax);
    return status.good();
}
#endif

static DcmMetaInfo* HorosModernDCMTKMetaInfo(DcmFileFormat& fileformat)
{
    return fileformat.getMetaInfo();
}

static void HorosModernDCMTKClearBasicMetadata(HorosModernDCMTKBasicMetadata* metadata)
{
    if (metadata == nullptr)
        return;

    std::memset(metadata, 0, sizeof(*metadata));
}

static void HorosModernDCMTKAssignTagString(DcmItem* item, const DcmTagKey& key, char** destination)
{
    if (item == nullptr || destination == nullptr)
        return;

    OFString value;
    if (item->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        *destination = HorosModernDCMTKDuplicateOFString(value);
}

static bool HorosModernDCMTKKeyObjectTitle(int titleCode, const char*& codeValue, const char*& codeMeaning)
{
    switch (titleCode)
    {
        case 113000: codeValue = "113000"; codeMeaning = "Of Interest"; return true;
        case 113001: codeValue = "113001"; codeMeaning = "Rejected for Quality Reasons"; return true;
        case 113002: codeValue = "113002"; codeMeaning = "For Referring Provider"; return true;
        case 113003: codeValue = "113003"; codeMeaning = "For Surgery"; return true;
        case 113004: codeValue = "113004"; codeMeaning = "For Teaching"; return true;
        case 113005: codeValue = "113005"; codeMeaning = "For Conference"; return true;
        case 113006: codeValue = "113006"; codeMeaning = "For Therapy"; return true;
        case 113007: codeValue = "113007"; codeMeaning = "For Patient"; return true;
        case 113008: codeValue = "113008"; codeMeaning = "For Peer Review"; return true;
        case 113009: codeValue = "113009"; codeMeaning = "For Research"; return true;
        case 113010: codeValue = "113010"; codeMeaning = "Quality Issue"; return true;
        case 113013: codeValue = "113013"; codeMeaning = "Best In Set"; return true;
        case 113018: codeValue = "113018"; codeMeaning = "For Printing"; return true;
        case 113020: codeValue = "113020"; codeMeaning = "For Report Attachment"; return true;
        default: return false;
    }
}

static OFCondition HorosModernDCMTKBuildKeyObjectReport(DSRDocument& document,
                                                        const char* sopInstanceUID,
                                                        const char* seriesInstanceUID,
                                                        const char* studyInstanceUID,
                                                        const char* studyDescription,
                                                        const char* patientName,
                                                        const char* patientBirthDate,
                                                        const char* patientSex,
                                                        const char* patientID,
                                                        const char* referringPhysician,
                                                        const char* studyID,
                                                        const char* accessionNumber,
                                                        int titleCode,
                                                        const char* keyDescription,
                                                        const char* const* imagePaths,
                                                        const char* const* imageSeriesInstanceUIDs,
                                                        const char* const* imageSOPInstanceUIDs,
                                                        int imageCount)
{
    if (studyInstanceUID == nullptr || studyInstanceUID[0] == '\0')
        return EC_IllegalParameter;

    const char* codeValue = nullptr;
    const char* codeMeaning = nullptr;
    if (!HorosModernDCMTKKeyObjectTitle(titleCode, codeValue, codeMeaning))
        return EC_IllegalParameter;

    OFCondition status = document.createNewDocument(DSRTypes::DT_KeyObjectSelectionDocument);
    if (status.good())
        status = document.setSpecificCharacterSet("ISO_IR 192");
    if (status.good())
        status = document.createNewSeriesInStudy(studyInstanceUID);
    if (status.bad())
        return status;

    if (status.good() && studyDescription != nullptr && studyDescription[0] != '\0')
        status = document.setStudyDescription(studyDescription);
    if (status.good())
        status = document.setSeriesDescription("OsiriX Key Object Report");
    if (status.good() && patientName != nullptr && patientName[0] != '\0')
        status = document.setPatientName(patientName);
    if (status.good() && patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        status = document.setPatientBirthDate(patientBirthDate);
    if (status.good() && patientSex != nullptr && patientSex[0] != '\0')
        status = document.setPatientSex(patientSex);
    if (status.good() && patientID != nullptr && patientID[0] != '\0')
        status = document.setPatientID(patientID);
    if (status.good() && referringPhysician != nullptr && referringPhysician[0] != '\0')
        status = document.setReferringPhysicianName(referringPhysician);
    if (status.good() && studyID != nullptr && studyID[0] != '\0')
        status = document.setStudyID(studyID);
    if (status.good() && accessionNumber != nullptr && accessionNumber[0] != '\0')
        status = document.setAccessionNumber(accessionNumber);
    if (status.good())
        status = document.setSeriesNumber("5002");
    if (status.good())
        status = document.setManufacturer("OsiriX");
    if (status.bad())
        return status;

    DSRDocumentTree& tree = document.getTree();
    if (tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container) == 0)
        return EC_IllegalCall;

    status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue(codeValue, "DCM", codeMeaning));
    if (status.bad())
        return status;

    if (keyDescription != nullptr && keyDescription[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_hasObsContext, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent) == 0)
            return EC_IllegalCall;
        status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("113012", "DCM", "Key Object Description"));
        if (status.bad())
            return status;
        status = tree.getCurrentContentItem().setStringValue(keyDescription);
        if (status.bad())
            return status;
        tree.goUp();
    }

    bool first = true;
    for (int index = 0; index < imageCount; ++index)
    {
        const char* imagePath = (imagePaths != nullptr) ? imagePaths[index] : nullptr;
        const char* imageSeriesUID = (imageSeriesInstanceUIDs != nullptr) ? imageSeriesInstanceUIDs[index] : nullptr;
        const char* imageSOPInstanceUID = (imageSOPInstanceUIDs != nullptr) ? imageSOPInstanceUIDs[index] : nullptr;
        if (imagePath == nullptr || imagePath[0] == '\0' ||
            imageSeriesUID == nullptr || imageSeriesUID[0] == '\0' ||
            imageSOPInstanceUID == nullptr || imageSOPInstanceUID[0] == '\0')
            continue;

        DcmFileFormat imageFile;
        if (imageFile.loadFile(imagePath, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).bad())
            continue;

        OFString sopClassUID;
        if (imageFile.getDataset() == nullptr ||
            imageFile.getDataset()->findAndGetOFString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
            sopClassUID.empty())
            continue;

        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, first ? DSRTypes::AM_belowCurrent : DSRTypes::AM_afterCurrent) == 0)
            return EC_IllegalCall;
        first = false;

        status = tree.getCurrentContentItem().setImageReference(DSRImageReferenceValue(sopClassUID, OFString(imageSOPInstanceUID)));
        if (status.bad())
            return status;

        status = document.getCurrentRequestedProcedureEvidence().addItem(OFString(studyInstanceUID),
                                                                         OFString(imageSeriesUID),
                                                                         sopClassUID,
                                                                         OFString(imageSOPInstanceUID));
        if (status.bad())
            return status;
    }

    if (!first)
        tree.goUp();

    return EC_Normal;
}

int HorosModernDCMTKIsDICOMFile(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    return fileformat.loadFile(path).good() ? 1 : 0;
}

int HorosModernDCMTKValidateDICOMDIR(const char* path, char** failureReason)
{
    if (failureReason != nullptr)
        *failureReason = nullptr;
    if (path == nullptr || path[0] == '\0')
        return HorosModernDCMTKValidationFail(failureReason, "invalid DICOMDIR path");

    HorosModernDCMTKEnsureDataDictionary();

    OFFilename fileName(path);
    DcmDicomDir dicomDir(fileName);
    OFCondition status = dicomDir.error();
    if (status.bad())
    {
        std::ostringstream reason;
        reason << "DICOMDIR load failed: " << status.text();
        return HorosModernDCMTKValidationFail(failureReason, reason.str());
    }

    // Force construction of the directory record hierarchy inside the
    // isolated validator process.
    (void)dicomDir.getRootRecord();
    return 1;
}

int HorosModernDCMTKValidateDICOMFile(const char* path, char** failureReason)
{
    if (failureReason != nullptr)
        *failureReason = nullptr;
    if (path == nullptr || path[0] == '\0')
        return HorosModernDCMTKValidationFail(failureReason, "invalid DICOM path");

    HorosModernDCMTKEnsureDataDictionary();
    HorosModernDCMTKEnsureCodecRegistration();

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
    {
        std::ostringstream reason;
        reason << "loadFile failed: " << status.text();
        return HorosModernDCMTKValidationFail(failureReason, reason.str());
    }

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return HorosModernDCMTKValidationFail(failureReason, "missing dataset");

    DcmElement* element = nullptr;
    if (dataset->findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
        return 1;

    DcmPixelData* pixelData = dynamic_cast<DcmPixelData*>(element);
    if (pixelData == nullptr)
        return HorosModernDCMTKValidationFail(failureReason, "PixelData is not DcmPixelData");

    const DcmXfer xfer(dataset->getOriginalXfer());
    bool pixelDataIsUncompressed = !xfer.usesEncapsulatedFormat();
    Uint32 frameSize = 0;
    status = pixelData->getUncompressedFrameSize(dataset, frameSize, pixelDataIsUncompressed ? OFTrue : OFFalse);

    std::string representationFailure;
    if ((status.bad() || frameSize == 0) && !pixelDataIsUncompressed)
    {
        OFCondition representationStatus = HorosModernDCMTKChooseUncompressedRepresentation(dataset, representationFailure);
        if (representationStatus.good())
        {
            element = nullptr;
            if (dataset->findAndGetElement(DCM_PixelData, element).good() && element != nullptr)
            {
                pixelData = dynamic_cast<DcmPixelData*>(element);
                if (pixelData != nullptr)
                {
                    pixelDataIsUncompressed = true;
                    frameSize = 0;
                    status = pixelData->getUncompressedFrameSize(dataset, frameSize, OFTrue);
                }
            }
        }
    }

    if (status.bad() || frameSize == 0)
    {
        HorosModernDCMTKDecodedFrame decodedFrame;
        if (HorosModernDCMTKCopyDecodedFrame(path, 0, &decodedFrame))
        {
            HorosModernDCMTKFreeDecodedFrame(&decodedFrame);
            return 1;
        }

        std::string decodedFailure = decodedFrame.failureReason != nullptr ? decodedFrame.failureReason : "";
        HorosModernDCMTKFreeDecodedFrame(&decodedFrame);
        std::ostringstream reason;
        reason << "cannot decode PixelData: ";
        if (!decodedFailure.empty())
            reason << decodedFailure;
        else if (!representationFailure.empty())
            reason << representationFailure;
        else
            reason << status.text();
        return HorosModernDCMTKValidationFail(failureReason, reason.str());
    }

    const Uint32 bufferSize = (frameSize & 1) ? frameSize + 1 : frameSize;
    std::vector<unsigned char> frameBytes(bufferSize);
    Uint32 startFragment = 0;
    OFString colorModel;
    status = pixelData->getUncompressedFrame(dataset,
                                             0,
                                             startFragment,
                                             frameBytes.data(),
                                             bufferSize,
                                             colorModel,
                                             nullptr);
    if (status.bad())
    {
        HorosModernDCMTKDecodedFrame decodedFrame;
        if (HorosModernDCMTKCopyDecodedFrame(path, 0, &decodedFrame))
        {
            HorosModernDCMTKFreeDecodedFrame(&decodedFrame);
            return 1;
        }

        std::string decodedFailure = decodedFrame.failureReason != nullptr ? decodedFrame.failureReason : "";
        HorosModernDCMTKFreeDecodedFrame(&decodedFrame);
        std::ostringstream reason;
        reason << "first-frame decode failed: " << status.text();
        if (!decodedFailure.empty())
            reason << " (" << decodedFailure << ")";
        return HorosModernDCMTKValidationFail(failureReason, reason.str());
    }

    return 1;
}

char* HorosModernDCMTKCopyGeneratedUID(void)
{
    char uid[100];
    return HorosModernDCMTKDuplicateCString(dcmGenerateUniqueIdentifier(uid));
}

char* HorosModernDCMTKCopySpecificCharacterSet(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path).good())
        return nullptr;

    DcmDataset* dataset = fileformat.getDataset();
    OFString value;
    if (dataset != nullptr && dataset->findAndGetOFString(DCM_SpecificCharacterSet, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateOFString(value);

    return nullptr;
}

char* HorosModernDCMTKCopyField(const char* path, const char* fieldName)
{
    if (path == nullptr || path[0] == '\0' || fieldName == nullptr || fieldName[0] == '\0')
        return nullptr;

    HorosModernDCMTKEnsureDataDictionary();

    DcmTagKey key(0xffff, 0xffff);

    const DcmDataDictionary& globalDataDict = dcmDataDict.rdlock();
    const DcmDictEntry* entry = globalDataDict.findEntry(fieldName);
    if (entry != nullptr)
        key = entry->getKey();
    dcmDataDict.rdunlock();

    if (key.getGroup() == 0xffff && key.getElement() == 0xffff)
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    OFString value;
    DcmDataset* dataset = fileformat.getDataset();
    if (dataset != nullptr && dataset->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateOFString(value);

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (metaInfo != nullptr && metaInfo->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateOFString(value);

    return nullptr;
}

char* HorosModernDCMTKCopyFieldByTag(const char* path, unsigned short group, unsigned short element)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    DcmTagKey key(group, element);
    OFString value;
    DcmDataset* dataset = fileformat.getDataset();
    if (dataset != nullptr && dataset->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateOFString(value);

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (metaInfo != nullptr && metaInfo->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateOFString(value);

    return nullptr;
}

int HorosModernDCMTKCopyBufferByTag(const char* path, unsigned short group, unsigned short element, unsigned char** buffer, unsigned long* length)
{
    if (buffer == nullptr || length == nullptr)
        return 0;

    *buffer = nullptr;
    *length = 0;

    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const Uint8* data = nullptr;
    unsigned long dataLength = 0;
    if (dataset->findAndGetUint8Array(DcmTagKey(group, element), data, &dataLength, OFFalse).bad() ||
        data == nullptr || dataLength == 0)
        return 0;

    unsigned char* copy = static_cast<unsigned char*>(std::malloc(dataLength));
    if (copy == nullptr)
        return 0;

    std::memcpy(copy, data, dataLength);
    *buffer = copy;
    *length = dataLength;
    return 1;
}


int HorosModernDCMTKCopyFileDataInTransferSyntax(const char* path,
                                                 const char* transferSyntaxUID,
                                                 int quality,
                                                 unsigned char** buffer,
                                                 unsigned long* length)
{
    if (buffer)
        *buffer = nullptr;
    if (length)
        *length = 0;

    if (path == nullptr || path[0] == '\0' || transferSyntaxUID == nullptr || transferSyntaxUID[0] == '\0' || buffer == nullptr || length == nullptr)
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmXfer originalXfer(dataset->getOriginalXfer());
    DcmXfer requestedXfer(transferSyntaxUID);
    if (requestedXfer.getXfer() == EXS_Unknown)
        return 0;

    const E_TransferSyntax originalSyntax = originalXfer.getXfer();
    const E_TransferSyntax requestedSyntax = requestedXfer.getXfer();
    const bool syntaxEquivalent =
        (originalSyntax == requestedSyntax) ||
        (originalSyntax == EXS_JPEG2000 && requestedSyntax == EXS_JPEG2000LosslessOnly) ||
        (originalSyntax == EXS_JPEG2000LosslessOnly && requestedSyntax == EXS_JPEG2000) ||
        (originalSyntax == EXS_JPEGLSLossy && requestedSyntax == EXS_JPEGLSLossless) ||
        (originalSyntax == EXS_JPEGLSLossless && requestedSyntax == EXS_JPEGLSLossy);

    auto copyFileBytes = [&](const char* sourcePath) -> int {
        FILE* fp = std::fopen(sourcePath, "rb");
        if (fp == nullptr)
            return 0;

        if (std::fseek(fp, 0, SEEK_END) != 0)
        {
            std::fclose(fp);
            return 0;
        }

        const long size = std::ftell(fp);
        if (size < 0)
        {
            std::fclose(fp);
            return 0;
        }

        if (std::fseek(fp, 0, SEEK_SET) != 0)
        {
            std::fclose(fp);
            return 0;
        }

        unsigned char* data = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(size)));
        if (data == nullptr && size > 0)
        {
            std::fclose(fp);
            return 0;
        }

        const size_t readLength = (size > 0) ? std::fread(data, 1, static_cast<size_t>(size), fp) : 0;
        std::fclose(fp);
        if (readLength != static_cast<size_t>(size))
        {
            std::free(data);
            return 0;
        }

        *buffer = data;
        *length = static_cast<unsigned long>(readLength);
        return 1;
    };

    if (syntaxEquivalent)
        return copyFileBytes(path);

    HorosModernDCMTKEnsureCodecRegistration();

    DcmRepresentationParameter* params = nullptr;
    DJ_RPLossy lossyParams(90);
    DJ_RPLossy jpeg2000Params(quality);
    DJ_RPLossy jpeg2000LosslessParams(quality);
#if HOROS_HAS_DCMRLE
    DcmRLERepresentationParameter rleParams;
#endif
    DJ_RPLossless losslessParams(6, 0);

    if (requestedSyntax == EXS_JPEGProcess14SV1)
        params = &losslessParams;
    else if (requestedSyntax == EXS_JPEGProcess2_4)
        params = &lossyParams;
    else if (requestedSyntax == EXS_RLELossless)
#if HOROS_HAS_DCMRLE
        params = &rleParams;
#else
        return 0;
#endif
    else if (requestedSyntax == EXS_JPEG2000LosslessOnly)
        params = &jpeg2000LosslessParams;
    else if (requestedSyntax == EXS_JPEG2000)
        params = &jpeg2000Params;
    else if (requestedSyntax == EXS_JPEGLSLossless)
        params = &jpeg2000LosslessParams;
    else if (requestedSyntax == EXS_JPEGLSLossy)
        params = &jpeg2000Params;

    dataset->chooseRepresentation(requestedSyntax, params);
    if (!dataset->canWriteXfer(requestedSyntax))
        return 0;

    char tempPath[256];
    std::snprintf(tempPath, sizeof(tempPath), "/tmp/horos-modern-bridge-%u.dcm", static_cast<unsigned>(std::rand()));
    status = fileformat.saveFile(tempPath, requestedSyntax);
    if (status.bad())
        return 0;

    const int copied = copyFileBytes(tempPath);
    std::remove(tempPath);
    return copied;
}


int HorosModernDCMTKWriteFileInTransferSyntax(const char* inputPath,
                                              const char* outputPath,
                                              const char* transferSyntaxUID,
                                              int quality)
{
    if (inputPath == nullptr || inputPath[0] == '\0' || outputPath == nullptr || outputPath[0] == '\0' ||
        transferSyntaxUID == nullptr || transferSyntaxUID[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(inputPath, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmXfer originalXfer(dataset->getOriginalXfer());
    DcmXfer requestedXfer(transferSyntaxUID);
    if (requestedXfer.getXfer() == EXS_Unknown)
        return 0;

    const E_TransferSyntax originalSyntax = originalXfer.getXfer();
    const E_TransferSyntax requestedSyntax = requestedXfer.getXfer();
    const bool syntaxEquivalent =
        (originalSyntax == requestedSyntax) ||
        (originalSyntax == EXS_JPEG2000 && requestedSyntax == EXS_JPEG2000LosslessOnly) ||
        (originalSyntax == EXS_JPEG2000LosslessOnly && requestedSyntax == EXS_JPEG2000) ||
        (originalSyntax == EXS_JPEGLSLossy && requestedSyntax == EXS_JPEGLSLossless) ||
        (originalSyntax == EXS_JPEGLSLossless && requestedSyntax == EXS_JPEGLSLossy);

#if HOROS_MODERN_BRIDGE_HAS_OPENJPEG
    if (requestedSyntax == EXS_LittleEndianExplicit &&
        originalXfer.usesEncapsulatedFormat() &&
        HorosModernDCMTKIsJPEG2000TransferSyntax(originalSyntax))
    {
        if (HorosModernDCMTKWriteOpenJPEGDecompressedFile(fileformat, outputPath, originalSyntax))
            return 1;
    }

    if (!originalXfer.usesEncapsulatedFormat() &&
        (requestedSyntax == EXS_JPEG2000LosslessOnly || requestedSyntax == EXS_JPEG2000))
    {
        if (HorosModernDCMTKWriteOpenJPEGCompressedFile(fileformat, outputPath, requestedSyntax, quality))
            return 1;
    }
#endif

    if (!syntaxEquivalent)
    {
        HorosModernDCMTKEnsureCodecRegistration();

        DcmRepresentationParameter* params = nullptr;
        DJ_RPLossy lossyParams(90);
        DJ_RPLossy jpeg2000Params(quality);
        DJ_RPLossy jpeg2000LosslessParams(quality);
#if HOROS_HAS_DCMRLE
        DcmRLERepresentationParameter rleParams;
#endif
        DJ_RPLossless losslessParams(6, 0);

        if (requestedSyntax == EXS_JPEGProcess14SV1)
            params = &losslessParams;
        else if (requestedSyntax == EXS_JPEGProcess2_4)
            params = &lossyParams;
        else if (requestedSyntax == EXS_RLELossless)
#if HOROS_HAS_DCMRLE
            params = &rleParams;
#else
            return 0;
#endif
        else if (requestedSyntax == EXS_JPEG2000LosslessOnly)
            params = &jpeg2000LosslessParams;
        else if (requestedSyntax == EXS_JPEG2000)
            params = &jpeg2000Params;
        else if (requestedSyntax == EXS_JPEGLSLossless)
            params = &jpeg2000LosslessParams;
        else if (requestedSyntax == EXS_JPEGLSLossy)
            params = &jpeg2000Params;

        dataset->chooseRepresentation(requestedSyntax, params);
        if (!dataset->canWriteXfer(requestedSyntax))
            return 0;
    }

    fileformat.loadAllDataIntoMemory();
    status = fileformat.saveFile(outputPath, requestedSyntax);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKReplaceTagValue(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const DcmTagKey key(group, element);
    const bool shouldRemove = (removeIfEmpty != 0) && (value == nullptr || value[0] == '\0');

    if (shouldRemove)
        status = dataset->findAndDeleteElement(key);
    else
        status = dataset->putAndInsertString(key, value != nullptr ? value : "", OFTrue);

    if (status.bad())
        return 0;

    E_TransferSyntax originalXfer = dataset->getOriginalXfer();
    status = fileformat.saveFile(path, originalXfer, EET_UndefinedLength, EGL_recalcGL, EPD_withoutPadding);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKGetDecompressionInfo(const char* path, int* isEncapsulated, unsigned short* rows, unsigned short* columns, char** modality, char** sopClassUID)
{
    if (isEncapsulated)
        *isEncapsulated = 0;
    if (rows)
        *rows = 0;
    if (columns)
        *columns = 0;
    if (modality)
        *modality = nullptr;
    if (sopClassUID)
        *sopClassUID = nullptr;

    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    if (isEncapsulated)
    {
        DcmXfer originalXfer(dataset->getOriginalXfer());
        *isEncapsulated = (originalXfer.usesEncapsulatedFormat() && originalXfer.isPixelDataCompressed()) ? 1 : 0;
    }

    if (rows)
    {
        Uint16 value = 0;
        if (dataset->findAndGetUint16(DCM_Rows, value, OFFalse).good())
            *rows = value;
    }

    if (columns)
    {
        Uint16 value = 0;
        if (dataset->findAndGetUint16(DCM_Columns, value, OFFalse).good())
            *columns = value;
    }

    OFString stringValue;
    if (modality && dataset->findAndGetOFString(DCM_Modality, stringValue, OFFalse).good() && !stringValue.empty())
        *modality = HorosModernDCMTKDuplicateOFString(stringValue);

    stringValue.clear();
    if (sopClassUID && dataset->findAndGetOFString(DCM_SOPClassUID, stringValue, OFFalse).good() && !stringValue.empty())
        *sopClassUID = HorosModernDCMTKDuplicateOFString(stringValue);

    return 1;
}

int HorosModernDCMTKGetBasicMetadata(const char* path, HorosModernDCMTKBasicMetadata* metadata)
{
    HorosModernDCMTKClearBasicMetadata(metadata);

    if (path == nullptr || path[0] == '\0' || metadata == nullptr)
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    HorosModernDCMTKAssignTagString(metaInfo, DCM_TransferSyntaxUID, &metadata->transferSyntaxUID);
    HorosModernDCMTKAssignTagString(metaInfo, DCM_PrivateInformationCreatorUID, &metadata->privateInformationCreatorUID);

    HorosModernDCMTKAssignTagString(dataset, DCM_SpecificCharacterSet, &metadata->specificCharacterSet);
    HorosModernDCMTKAssignTagString(dataset, DCM_SOPClassUID, &metadata->sopClassUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_ImageType, &metadata->imageType);
    HorosModernDCMTKAssignTagString(dataset, DCM_SOPInstanceUID, &metadata->sopInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_Modality, &metadata->modality);
    HorosModernDCMTKAssignTagString(dataset, DCM_AcquisitionDate, &metadata->acquisitionDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_ContentDate, &metadata->contentDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesDate, &metadata->seriesDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyDate, &metadata->studyDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_AcquisitionTime, &metadata->acquisitionTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_ContentTime, &metadata->contentTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesTime, &metadata->seriesTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyTime, &metadata->studyTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_ScanOptions, &metadata->scanOptions);
    HorosModernDCMTKAssignTagString(dataset, DCM_EchoTime, &metadata->echoTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_InstanceNumber, &metadata->instanceNumber);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesNumber, &metadata->seriesNumber);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesInstanceUID, &metadata->seriesInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyInstanceUID, &metadata->studyInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyID, &metadata->studyID);

    Uint16 rows = 0;
    if (dataset->findAndGetUint16(DCM_Rows, rows, OFFalse).good())
        metadata->rows = rows;

    Uint16 columns = 0;
    if (dataset->findAndGetUint16(DCM_Columns, columns, OFFalse).good())
        metadata->columns = columns;

    const char* numberOfFrames = nullptr;
    if (dataset->findAndGetString(DCM_NumberOfFrames, numberOfFrames, OFFalse).good() && numberOfFrames != nullptr)
        metadata->numberOfFrames = std::atoi(numberOfFrames);

    return 1;
}

int HorosModernDCMTKCopyImageGeometry(const char* path, double* origin3, double* orientation9)
{
    if (origin3)
        std::memset(origin3, 0, sizeof(double) * 3);
    if (orientation9)
        std::memset(orientation9, 0, sizeof(double) * 9);

    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    int found = 0;
    if (origin3)
    {
        int count = 0;
        while (count < 3 && dataset->findAndGetFloat64(DCM_ImagePositionPatient, origin3[count], count, OFFalse).good())
            count++;
        if (count == 3)
            found = 1;
    }

    if (orientation9)
    {
        int count = 0;
        while (count < 6 && dataset->findAndGetFloat64(DCM_ImageOrientationPatient, orientation9[count], count, OFFalse).good())
            count++;
        if (count == 6)
            found = 1;
    }

    return found;
}

int HorosModernDCMTKCopyFrameGeometry(const char* path, double** sliceLocations, int* sliceCount, double** triggerDelays, int* triggerCount)
{
    const DcmTagKey cardiacTriggerSequenceTag(0x0018, 0x9118);
    const DcmTagKey triggerDelayTimeTag(0x0020, 0x9153);

    if (sliceLocations)
        *sliceLocations = nullptr;
    if (sliceCount)
        *sliceCount = 0;
    if (triggerDelays)
        *triggerDelays = nullptr;
    if (triggerCount)
        *triggerCount = 0;

    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    std::vector<double> locations;
    std::vector<double> triggers;

    double orientationMultiFrame[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    double originMultiFrame[3] = {0, 0, 0};

    DcmItem* sharedItem = nullptr;
    if (dataset->findAndGetSequenceItem(DCM_SharedFunctionalGroupsSequence, sharedItem, 0).good())
    {
        DcmItem* eitem = nullptr;
        if (sharedItem->findAndGetSequenceItem(DCM_PlanePositionVolumeSequence, eitem, 0).good())
        {
            int count = 0;
            while (count < 6 && eitem->findAndGetFloat64(DCM_ImageOrientationVolume, orientationMultiFrame[count], count, OFFalse).good())
                count++;
        }
    }

    int frameIndex = 0;
    DcmItem* perFrameItem = nullptr;
    while (dataset->findAndGetSequenceItem(DCM_PerFrameFunctionalGroupsSequence, perFrameItem, frameIndex++).good())
    {
        int x = 0;
        DcmItem* eitem = nullptr;
        while (true)
        {
            if (perFrameItem->findAndGetSequenceItem(cardiacTriggerSequenceTag, eitem, x).good())
            {
                Float64 trigger = 0;
                if (eitem->findAndGetFloat64(triggerDelayTimeTag, trigger, 0, OFFalse).good())
                    triggers.push_back(trigger);
            }

            bool succeed = true;
            if (perFrameItem->findAndGetSequenceItem(DCM_PlanePositionVolumeSequence, eitem, x).good())
            {
                int count = 0;
                while (count < 3 && eitem->findAndGetFloat64(DCM_ImagePositionVolume, originMultiFrame[count], count, OFFalse).good())
                    count++;
                if (count != 3)
                    succeed = false;
            }
            else
            {
                succeed = false;
            }

            if (!succeed)
            {
                succeed = true;
                if (perFrameItem->findAndGetSequenceItem(DCM_PlanePositionSequence, eitem, x).good())
                {
                    int count = 0;
                    while (count < 3 && eitem->findAndGetFloat64(DCM_ImagePositionPatient, originMultiFrame[count], count, OFFalse).good())
                        count++;
                    if (count != 3)
                        succeed = false;
                }
                else
                {
                    succeed = false;
                }

                if (perFrameItem->findAndGetSequenceItem(DCM_PlaneOrientationSequence, eitem, x).good())
                {
                    int count = 0;
                    while (count < 6 && eitem->findAndGetFloat64(DCM_ImageOrientationPatient, orientationMultiFrame[count], count, OFFalse).good())
                        count++;
                    if (count != 6 && count != 0)
                        succeed = false;
                }
                else
                {
                    succeed = false;
                }
            }

            if (succeed)
            {
                orientationMultiFrame[6] = orientationMultiFrame[1] * orientationMultiFrame[5] - orientationMultiFrame[2] * orientationMultiFrame[4];
                orientationMultiFrame[7] = orientationMultiFrame[2] * orientationMultiFrame[3] - orientationMultiFrame[0] * orientationMultiFrame[5];
                orientationMultiFrame[8] = orientationMultiFrame[0] * orientationMultiFrame[4] - orientationMultiFrame[1] * orientationMultiFrame[3];

                double location = 0;
                if (fabs(orientationMultiFrame[6]) > fabs(orientationMultiFrame[7]) && fabs(orientationMultiFrame[6]) > fabs(orientationMultiFrame[8]))
                    location = originMultiFrame[0];
                if (fabs(orientationMultiFrame[7]) > fabs(orientationMultiFrame[6]) && fabs(orientationMultiFrame[7]) > fabs(orientationMultiFrame[8]))
                    location = originMultiFrame[1];
                if (fabs(orientationMultiFrame[8]) > fabs(orientationMultiFrame[6]) && fabs(orientationMultiFrame[8]) > fabs(orientationMultiFrame[7]))
                    location = originMultiFrame[2];

                locations.push_back(location);
            }

            x++;
            if (eitem == nullptr)
                break;
        }
    }

    if (sliceLocations && !locations.empty())
    {
        *sliceLocations = static_cast<double*>(std::malloc(sizeof(double) * locations.size()));
        if (*sliceLocations)
            std::memcpy(*sliceLocations, locations.data(), sizeof(double) * locations.size());
        if (sliceCount)
            *sliceCount = static_cast<int>(locations.size());
    }

    if (triggerDelays && !triggers.empty())
    {
        *triggerDelays = static_cast<double*>(std::malloc(sizeof(double) * triggers.size()));
        if (*triggerDelays)
            std::memcpy(*triggerDelays, triggers.data(), sizeof(double) * triggers.size());
        if (triggerCount)
            *triggerCount = static_cast<int>(triggers.size());
    }

    return (locations.empty() && triggers.empty()) ? 0 : 1;
}

int HorosModernDCMTKCopyDecodedFrame(const char* path, unsigned long frameIndex, HorosModernDCMTKDecodedFrame* frame)
{
    HorosModernDCMTKClearDecodedFrame(frame);

    if (path == nullptr || path[0] == '\0' || frame == nullptr)
        return HorosModernDCMTKDecodedFrameFail(frame, "invalid arguments");

    HorosModernDCMTKEnsureDataDictionary();
    HorosModernDCMTKEnsureCodecRegistration();

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
    {
        std::ostringstream reason;
        reason << "loadFile failed: " << status.text();
        return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
    }

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return HorosModernDCMTKDecodedFrameFail(frame, "missing dataset");

    OFString sopClassUID;
    if (dataset->findAndGetOFString(DCM_SOPClassUID, sopClassUID, OFFalse).good() &&
        sopClassUID.find("1.2.840.10008.5.1.4.1.1.88") == 0)
        return HorosModernDCMTKDecodedFrameFail(frame, "structured report SOP class");

    Uint16 rows = 0;
    Uint16 columns = 0;
    Uint16 samplesPerPixel = 1;
    Uint16 bitsAllocated = 0;
    Uint16 bitsStored = 0;
    Uint16 pixelRepresentation = 0;

    if (dataset->findAndGetUint16(DCM_Rows, rows).bad() ||
        dataset->findAndGetUint16(DCM_Columns, columns).bad() ||
        dataset->findAndGetUint16(DCM_BitsAllocated, bitsAllocated).bad() ||
        dataset->findAndGetUint16(DCM_BitsStored, bitsStored).bad())
        return HorosModernDCMTKDecodedFrameFail(frame, "missing required image attributes");

    dataset->findAndGetUint16(DCM_SamplesPerPixel, samplesPerPixel);
    dataset->findAndGetUint16(DCM_PixelRepresentation, pixelRepresentation);

    OFString photometricInterpretation;
    if (dataset->findAndGetOFString(DCM_PhotometricInterpretation, photometricInterpretation, OFFalse).good() &&
        photometricInterpretation != "MONOCHROME2")
    {
        std::ostringstream reason;
        reason << "unsupported photometric interpretation: " << photometricInterpretation.c_str();
        return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
    }

    if (rows == 0 || columns == 0 || samplesPerPixel != 1)
    {
        std::ostringstream reason;
        reason << "unsupported dimensions/samples rows=" << rows << " columns=" << columns << " samples=" << samplesPerPixel;
        return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
    }
    if (bitsAllocated != 8 && bitsAllocated != 16 && bitsAllocated != 32)
    {
        std::ostringstream reason;
        reason << "unsupported bits allocated: " << bitsAllocated;
        return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
    }
    if (bitsStored == 0 || bitsStored > bitsAllocated)
        bitsStored = bitsAllocated;

    long int frameCount = 1;
    OFCondition numberOfFramesStatus = dataset->findAndGetLongInt(DCM_NumberOfFrames, frameCount);
    if (numberOfFramesStatus.bad() || frameCount < 1)
        frameCount = 1;
    if (frameCount < 1 || frameIndex >= static_cast<unsigned long>(frameCount))
    {
        std::ostringstream reason;
        reason << "frame index out of range frame=" << frameIndex << " count=" << frameCount;
        return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
    }

    Float64 slope = 1.0;
    Float64 intercept = 0.0;
    Float64 windowCenter = 0.0;
    Float64 windowWidth = 0.0;
    dataset->findAndGetFloat64(DCM_RescaleSlope, slope);
    if (slope == 0.0)
        slope = 1.0;
    dataset->findAndGetFloat64(DCM_RescaleIntercept, intercept);
    dataset->findAndGetFloat64(DCM_WindowCenter, windowCenter, 0);
    dataset->findAndGetFloat64(DCM_WindowWidth, windowWidth, 0);

    const unsigned long pixelCount = static_cast<unsigned long>(rows) * static_cast<unsigned long>(columns);

    DcmElement* element = nullptr;
    if (dataset->findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
        return HorosModernDCMTKDecodedFrameFail(frame, "missing PixelData");

    DcmPixelData* pixelData = dynamic_cast<DcmPixelData*>(element);
    if (pixelData == nullptr)
        return HorosModernDCMTKDecodedFrameFail(frame, "PixelData is not DcmPixelData");

    const E_TransferSyntax originalXfer = dataset->getOriginalXfer();
    const DcmXfer xfer(originalXfer);
    bool pixelDataIsUncompressed = !xfer.usesEncapsulatedFormat();
    float* pixels = nullptr;

#if HOROS_MODERN_BRIDGE_HAS_OPENJPEG
    if (xfer.usesEncapsulatedFormat() &&
        HorosModernDCMTKIsJPEG2000TransferSyntax(originalXfer) &&
        bitsAllocated != bitsStored)
    {
        std::string openJPEGReason;
        pixels = HorosModernDCMTKCopyOpenJPEGDecodedPixels(pixelData,
                                                           originalXfer,
                                                           frameIndex,
                                                           frameCount,
                                                           pixelCount,
                                                           bitsAllocated,
                                                           bitsStored,
                                                           pixelRepresentation,
                                                           slope,
                                                           intercept,
                                                           openJPEGReason);
        if (pixels == nullptr)
        {
            std::ostringstream reason;
            reason << "OpenJPEG JPEG 2000 decode failed: " << openJPEGReason
                   << " transferSyntax=" << xfer.getXferName()
                   << " bitsAllocated=" << bitsAllocated
                   << " bitsStored=" << bitsStored;
            return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
        }
    }
#endif

    if (pixels == nullptr && xfer.usesEncapsulatedFormat() && bitsAllocated != bitsStored)
    {
        std::string decodeReason;
        status = HorosModernDCMTKChooseUncompressedRepresentation(dataset, decodeReason);
        if (status.bad())
        {
            std::ostringstream reason;
            reason << decodeReason
                   << " transferSyntax=" << xfer.getXferName()
                   << " bitsAllocated=" << bitsAllocated
                   << " bitsStored=" << bitsStored;
            return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
        }

        element = nullptr;
        if (dataset->findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
            return HorosModernDCMTKDecodedFrameFail(frame, "missing PixelData after decompression");

        pixelData = dynamic_cast<DcmPixelData*>(element);
        if (pixelData == nullptr)
            return HorosModernDCMTKDecodedFrameFail(frame, "PixelData is not DcmPixelData after decompression");

        pixelDataIsUncompressed = true;
    }

    Uint32 frameSize = 0;
    if (pixels == nullptr)
    {
        status = pixelData->getUncompressedFrameSize(dataset, frameSize, pixelDataIsUncompressed ? OFTrue : OFFalse);
        if ((status.bad() || frameSize == 0) && xfer.usesEncapsulatedFormat() && !pixelDataIsUncompressed)
        {
            std::string decodeReason;
            OFCondition decodeStatus = HorosModernDCMTKChooseUncompressedRepresentation(dataset, decodeReason);
            if (decodeStatus.good())
            {
                element = nullptr;
                if (dataset->findAndGetElement(DCM_PixelData, element).good() && element != nullptr)
                {
                    DcmPixelData* decompressedPixelData = dynamic_cast<DcmPixelData*>(element);
                    if (decompressedPixelData != nullptr)
                    {
                        pixelData = decompressedPixelData;
                        pixelDataIsUncompressed = true;
                        frameSize = 0;
                        status = pixelData->getUncompressedFrameSize(dataset, frameSize, OFTrue);
                    }
                }
            }
        }
        if (status.bad() || frameSize == 0)
        {
            std::ostringstream reason;
            reason << "getUncompressedFrameSize failed status=" << status.text()
                   << " transferSyntax=" << xfer.getXferName()
                   << " encapsulated=" << (xfer.usesEncapsulatedFormat() ? "yes" : "no")
                   << " pixelDataIsUncompressed=" << (pixelDataIsUncompressed ? "yes" : "no")
                   << " frameSize=" << frameSize;
            return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
        }

        const Uint32 bufferSize = (frameSize & 1) ? frameSize + 1 : frameSize;
        std::vector<unsigned char> raw(bufferSize);
        Uint32 startFragment = 0;
        OFString colorModel;
        status = pixelData->getUncompressedFrame(dataset, static_cast<Uint32>(frameIndex), startFragment, raw.data(), bufferSize, colorModel, nullptr);
        if (status.bad())
        {
            std::ostringstream reason;
            reason << "getUncompressedFrame failed status=" << status.text()
                   << " transferSyntax=" << xfer.getXferName()
                   << " colorModel=" << colorModel.c_str();
            return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
        }

        if (frameSize < pixelCount * (bitsAllocated / 8))
        {
            std::ostringstream reason;
            reason << "decoded frame too small frameSize=" << frameSize
                   << " expected=" << pixelCount * (bitsAllocated / 8);
            return HorosModernDCMTKDecodedFrameFail(frame, reason.str());
        }

        pixels = static_cast<float*>(std::malloc(sizeof(float) * pixelCount));
        if (pixels == nullptr)
            return HorosModernDCMTKDecodedFrameFail(frame, "pixel allocation failed");

        const bool isSigned = pixelRepresentation != 0;
        if (bitsAllocated == 8)
        {
            const Uint8* source = reinterpret_cast<const Uint8*>(raw.data());
            for (unsigned long index = 0; index < pixelCount; ++index)
            {
                int value = isSigned ? static_cast<Sint8>(source[index]) : static_cast<int>(source[index]);
                pixels[index] = static_cast<float>(static_cast<double>(value) * slope + intercept);
            }
        }
        else if (bitsAllocated == 16)
        {
            const Uint16* source = reinterpret_cast<const Uint16*>(raw.data());
            for (unsigned long index = 0; index < pixelCount; ++index)
            {
                int value = isSigned ? static_cast<Sint16>(source[index]) : static_cast<int>(source[index]);
                pixels[index] = static_cast<float>(static_cast<double>(value) * slope + intercept);
            }
        }
        else
        {
            const Uint32* source = reinterpret_cast<const Uint32*>(raw.data());
            for (unsigned long index = 0; index < pixelCount; ++index)
            {
                double value = isSigned ? static_cast<double>(static_cast<Sint32>(source[index])) : static_cast<double>(source[index]);
                pixels[index] = static_cast<float>(value * slope + intercept);
            }
        }
    }

    frame->pixels = pixels;
    frame->pixelCount = pixelCount;
    frame->rows = rows;
    frame->columns = columns;
    frame->bitsAllocated = bitsAllocated;
    frame->bitsStored = bitsStored;
    frame->pixelRepresentation = pixelRepresentation;
    frame->slope = slope;
    frame->intercept = intercept;
    frame->windowCenter = windowCenter;
    frame->windowWidth = windowWidth;
    frame->isRGB = 0;

    Float64 value = 0.0;
    if (dataset->findAndGetFloat64(DCM_PixelSpacing, value, 0).good())
        frame->pixelSpacingY = value;
    if (dataset->findAndGetFloat64(DCM_PixelSpacing, value, 1).good())
        frame->pixelSpacingX = value;
    if (frame->pixelSpacingX == 1.0 && frame->pixelSpacingY == 1.0)
    {
        if (dataset->findAndGetFloat64(DCM_ImagerPixelSpacing, value, 0).good())
            frame->pixelSpacingY = value;
        if (dataset->findAndGetFloat64(DCM_ImagerPixelSpacing, value, 1).good())
            frame->pixelSpacingX = value;
    }

    dataset->findAndGetFloat64(DCM_SliceThickness, frame->sliceThickness);
    dataset->findAndGetFloat64(DCM_SpacingBetweenSlices, frame->spacingBetweenSlices);

    if (dataset->findAndGetFloat64(DCM_ImagePositionPatient, frame->origin[0], 0).good() &&
        dataset->findAndGetFloat64(DCM_ImagePositionPatient, frame->origin[1], 1).good() &&
        dataset->findAndGetFloat64(DCM_ImagePositionPatient, frame->origin[2], 2).good())
        frame->isOriginDefined = 1;

    if (dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[0], 0).good() &&
        dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[1], 1).good() &&
        dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[2], 2).good() &&
        dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[3], 3).good() &&
        dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[4], 4).good() &&
        dataset->findAndGetFloat64(DCM_ImageOrientationPatient, frame->orientation[5], 5).good())
    {
        frame->orientation[6] = frame->orientation[1] * frame->orientation[5] - frame->orientation[2] * frame->orientation[4];
        frame->orientation[7] = frame->orientation[2] * frame->orientation[3] - frame->orientation[0] * frame->orientation[5];
        frame->orientation[8] = frame->orientation[0] * frame->orientation[4] - frame->orientation[1] * frame->orientation[3];
    }

    return 1;
}

int HorosModernDCMTKCopyEncapsulatedDocument(const char* path, unsigned char** buffer, unsigned long* length)
{
    if (buffer)
        *buffer = nullptr;
    if (length)
        *length = 0;

    if (path == nullptr || path[0] == '\0')
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const Uint8* data = nullptr;
    unsigned long dataLength = 0;
    if (dataset->findAndGetUint8Array(DCM_EncapsulatedDocument, data, &dataLength, OFFalse).good() && data != nullptr && dataLength > 0)
    {
        unsigned char* copy = static_cast<unsigned char*>(std::malloc(dataLength));
        if (copy == nullptr)
            return 0;
        std::memcpy(copy, data, dataLength);
        if (buffer)
            *buffer = copy;
        if (length)
            *length = dataLength;
        return 1;
    }

    return 0;
}

int HorosModernDCMTKWriteBufferByTag(const char* path, unsigned short group, unsigned short element, const unsigned char* buffer, unsigned long length)
{
    if (path == nullptr || path[0] == '\0' || buffer == nullptr || length == 0)
        return 0;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const DcmTagKey key(group, element);
    if (dataset->putAndInsertUint8Array(key, buffer, length, OFTrue).bad())
        return 0;

    const E_TransferSyntax originalXfer = fileformat.getDataset()->getOriginalXfer();
    OFCondition status = fileformat.saveFile(path, originalXfer, EET_UndefinedLength, EGL_recalcGL, EPD_withoutPadding);
    return status.good() ? 1 : 0;
}

char* HorosModernDCMTKCopyStructuredReportHTML(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    HorosModernDCMTKEnsureDataDictionary();

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    OFString sopClassUID;
    if (fileformat.getDataset()->findAndGetOFString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
        sopClassUID.empty() ||
        DSRTypes::sopClassUIDToDocumentType(sopClassUID.c_str()) == DSRTypes::DT_invalid) {
        return nullptr;
    }

    DSRDocument document;
    const size_t readFlags =
        DSRTypes::RF_acceptUnknownRelationshipType |
        DSRTypes::RF_ignoreRelationshipConstraints |
        DSRTypes::RF_ignoreContentItemErrors |
        DSRTypes::RF_skipInvalidContentItems;

    if (document.read(*fileformat.getDataset(), readFlags).bad())
        return nullptr;

    const size_t renderFlags =
        DSRTypes::HF_renderDcmtkFootnote |
        DSRTypes::HF_XHTML11Compatibility |
        DSRTypes::HF_addDocumentTypeReference;

    std::ostringstream output;
    if (document.renderHTML(output, renderFlags, nullptr, nullptr).bad())
        return nullptr;

    const std::string html = output.str();
    return HorosModernDCMTKDuplicateCString(html.c_str());
}

char* HorosModernDCMTKCopyStructuredReportXML(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::ostringstream output;
    const size_t writeFlags = 0;
    if (document.writeXML(output, writeFlags).bad())
        return nullptr;

    const std::string xml = output.str();
    return HorosModernDCMTKDuplicateCString(xml.c_str());
}

static bool HorosModernDCMTKLoadStructuredReport(const char* path, DcmFileFormat& fileformat, DSRDocument& document)
{
    if (path == nullptr || path[0] == '\0')
        return false;

    HorosModernDCMTKEnsureDataDictionary();

    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return false;

    OFString sopClassUID;
    if (fileformat.getDataset()->findAndGetOFString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
        sopClassUID.empty() ||
        DSRTypes::sopClassUIDToDocumentType(sopClassUID.c_str()) == DSRTypes::DT_invalid)
        return false;

    const size_t readFlags =
        DSRTypes::RF_acceptUnknownRelationshipType |
        DSRTypes::RF_ignoreRelationshipConstraints |
        DSRTypes::RF_ignoreContentItemErrors |
        DSRTypes::RF_skipInvalidContentItems;

    return document.read(*fileformat.getDataset(), readFlags).good();
}

static bool HorosModernDCMTKStructuredReportItemMatchesCode(DSRContentItem& item,
                                                            const char* codeValue,
                                                            const char* codingSchemeDesignator,
                                                            const char* codeMeaning)
{
    const DSRCodedEntryValue conceptName = item.getConceptName();
    if (conceptName.isEmpty())
        return false;

    if (codeValue != nullptr && codeValue[0] != '\0' && conceptName.getCodeValue() != codeValue)
        return false;

    if (codingSchemeDesignator != nullptr &&
        codingSchemeDesignator[0] != '\0' &&
        conceptName.getCodingSchemeDesignator() != codingSchemeDesignator)
        return false;

    if (codeMeaning != nullptr && codeMeaning[0] != '\0' && conceptName.getCodeMeaning() != codeMeaning)
        return false;

    return true;
}

char* HorosModernDCMTKCopyStructuredReportKeyObjectType(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    document.getTree().gotoRoot();
    const OFString codeMeaning = document.getTree().getCurrentContentItem().getConceptName().getCodeMeaning();
    if (codeMeaning.empty())
        return nullptr;

    return HorosModernDCMTKDuplicateCString(codeMeaning.c_str());
}

char* HorosModernDCMTKCopyStructuredReportRootCodeMeaning(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    document.getTree().gotoRoot();
    const OFString codeMeaning = document.getTree().getCurrentContentItem().getConceptName().getCodeMeaning();
    if (codeMeaning.empty())
        return nullptr;

    return HorosModernDCMTKDuplicateCString(codeMeaning.c_str());
}

char* HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::vector<OFString> uids;
    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (item.getValueType() == DSRTypes::VT_Image)
        {
            OFString sopInstance = item.getImageReference().getSOPInstanceUID();
            if (!sopInstance.empty())
                uids.push_back(sopInstance);
        }
    } while (tree.iterate());

    if (uids.empty())
        return nullptr;

    OFString joined;
    for (size_t index = 0; index < uids.size(); ++index)
    {
        if (index > 0)
            joined += "\\";
        joined += uids[index];
    }

    return HorosModernDCMTKDuplicateCString(joined.c_str());
}

char* HorosModernDCMTKCopyStructuredReportPrimaryReference(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    int instanceNumber = 0;
    OFString rawInstanceNumber;
    if (document.getInstanceNumber(rawInstanceNumber).good() && !rawInstanceNumber.empty())
        instanceNumber = std::atoi(rawInstanceNumber.c_str());

    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (item.getValueType() == DSRTypes::VT_Image)
        {
            OFString sopInstance = item.getImageReference().getSOPInstanceUID();
            if (sopInstance.empty())
                continue;

            std::string value = sopInstance.c_str();
            if (instanceNumber > 0)
            {
                value += "-";
                value += std::to_string(instanceNumber);
            }
            return HorosModernDCMTKDuplicateCString(value.c_str());
        }
    } while (tree.iterate());

    return nullptr;
}

char* HorosModernDCMTKCopyStructuredReportNamedTextValue(const char* path,
                                                         const char* codeValue,
                                                         const char* codingSchemeDesignator,
                                                         const char* codeMeaning)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (!HorosModernDCMTKStructuredReportItemMatchesCode(item, codeValue, codingSchemeDesignator, codeMeaning))
            continue;

        const OFString value = item.getStringValue();
        if (!value.empty())
            return HorosModernDCMTKDuplicateOFString(value);
    } while (tree.iterate());

    return nullptr;
}

char* HorosModernDCMTKCopyStructuredReportNamedTextValues(const char* path,
                                                          const char* codeValue,
                                                          const char* codingSchemeDesignator,
                                                          const char* codeMeaning)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::vector<OFString> values;
    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (!HorosModernDCMTKStructuredReportItemMatchesCode(item, codeValue, codingSchemeDesignator, codeMeaning))
            continue;

        const OFString value = item.getStringValue();
        if (!value.empty())
            values.push_back(value);
    } while (tree.iterate());

    if (values.empty())
        return nullptr;

    OFString joined;
    for (size_t index = 0; index < values.size(); ++index)
    {
        if (index > 0)
            joined += "\\";
        joined += values[index];
    }

    return HorosModernDCMTKDuplicateCString(joined.c_str());
}

char* HorosModernDCMTKCopySurgicalProcedureRecordJSON(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    DSRDocumentTree& tree = document.getTree();
    if (tree.gotoRoot() == 0)
        return nullptr;

    DSRContentItem& root = tree.getCurrentContentItem();
    if (!HorosModernDCMTKStructuredReportItemMatchesCode(root, "HSP", "99HOROS", "Surgical Procedure"))
        return nullptr;

    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (!HorosModernDCMTKStructuredReportItemMatchesCode(item,
                                                             "HSP.RECORD",
                                                             "99HOROS",
                                                             "Horos Surgical Procedure Record"))
            continue;

        const OFString value = item.getStringValue();
        if (!value.empty())
            return HorosModernDCMTKDuplicateOFString(value);
    } while (tree.iterate());

    return nullptr;
}

int HorosModernDCMTKWriteSurgicalProcedureStructuredReport(const char* path,
                                                            const char* sopInstanceUID,
                                                            const char* seriesInstanceUID,
                                                            const char* studyInstanceUID,
                                                            const char* patientName,
                                                            const char* patientBirthDate,
                                                            const char* patientID,
                                                            const char* contentDate,
                                                            const char* contentTime,
                                                            const char* operation,
                                                            const char* diagnosis,
                                                            const char* results,
                                                            const char* optics,
                                                            const char* assistants,
                                                            const char* recordJSON)
{
    if (path == nullptr || path[0] == '\0' ||
        sopInstanceUID == nullptr || sopInstanceUID[0] == '\0' ||
        seriesInstanceUID == nullptr || seriesInstanceUID[0] == '\0' ||
        studyInstanceUID == nullptr || studyInstanceUID[0] == '\0' ||
        contentDate == nullptr || contentDate[0] == '\0' ||
        contentTime == nullptr || contentTime[0] == '\0' ||
        recordJSON == nullptr || recordJSON[0] == '\0')
        return 0;

    DSRDocument document;
    OFCondition status = document.createNewDocument(DSRTypes::DT_BasicTextSR);
    if (status.good())
        status = document.setSpecificCharacterSet("ISO_IR 192");
    if (status.good())
        status = document.createNewSeriesInStudy(studyInstanceUID);
    if (status.good())
        status = document.setStudyDescription("Surgical Procedure");
    if (status.good())
        status = document.setSeriesDescription("Horos Surgical Procedure SR");
    if (status.good() && patientName != nullptr && patientName[0] != '\0')
        status = document.setPatientName(patientName);
    if (status.good() && patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        status = document.setPatientBirthDate(patientBirthDate);
    if (status.good() && patientID != nullptr && patientID[0] != '\0')
        status = document.setPatientID(patientID);
    if (status.good())
        status = document.setStudyID("SURG");
    if (status.good())
        status = document.setSeriesNumber("1");
    if (status.good())
        status = document.setInstanceNumber("1");
    if (status.good())
        status = document.setManufacturer("Horos");
    if (status.good())
        status = document.setContentDate(contentDate);
    if (status.good())
        status = document.setContentTime(contentTime);
    if (status.bad())
        return 0;

    DSRDocumentTree& tree = document.getTree();
    if (tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container) == 0)
        return 0;
    status = tree.getCurrentContentItem().setConceptName(
        DSRCodedEntryValue("HSP", "99HOROS", "Surgical Procedure"));
    if (status.bad())
        return 0;

    const auto addTextItem = [&tree](const char* codeValue,
                                     const char* codeMeaning,
                                     const char* value) -> bool {
        if (value == nullptr || value[0] == '\0')
            return true;
        if (tree.addContentItem(DSRTypes::RT_contains,
                                DSRTypes::VT_Text,
                                DSRTypes::AM_belowCurrent) == 0)
            return false;
        OFCondition itemStatus = tree.getCurrentContentItem().setConceptName(
            DSRCodedEntryValue(codeValue, "99HOROS", codeMeaning));
        if (itemStatus.good())
            itemStatus = tree.getCurrentContentItem().setStringValue(value);
        tree.goUp();
        return itemStatus.good();
    };

    if (!addTextItem("HSP.DATE", "Procedure Date", contentDate) ||
        !addTextItem("HSP.OP", "Operation", operation) ||
        !addTextItem("HSP.DX", "Diagnosis", diagnosis) ||
        !addTextItem("HSP.RESULTS", "Results", results) ||
        !addTextItem("HSP.OPTICS", "Optics", optics) ||
        !addTextItem("HSP.ASSTS", "Assistants", assistants) ||
        !addTextItem("HSP.RECORD", "Horos Surgical Procedure Record", recordJSON))
        return 0;

    status = document.completeDocument();
    if (status.bad())
        return 0;

    DcmFileFormat fileformat;
    status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_StudyInstanceUID, studyInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_Modality, "SR", OFTrue);
    dataset->putAndInsertString(DCM_StudyDate, contentDate, OFTrue);
    dataset->putAndInsertString(DCM_SeriesDate, contentDate, OFTrue);
    dataset->putAndInsertString(DCM_AcquisitionDate, contentDate, OFTrue);
    dataset->putAndInsertString(DCM_ContentDate, contentDate, OFTrue);
    dataset->putAndInsertString(DCM_StudyTime, contentTime, OFTrue);
    dataset->putAndInsertString(DCM_SeriesTime, contentTime, OFTrue);
    dataset->putAndInsertString(DCM_AcquisitionTime, contentTime, OFTrue);
    dataset->putAndInsertString(DCM_ContentTime, contentTime, OFTrue);
    dataset->putAndInsertString(DCM_StudyDescription, "Surgical Procedure", OFTrue);
    dataset->putAndInsertString(DCM_SeriesDescription, "Horos Surgical Procedure SR", OFTrue);
    if (metaInfo != nullptr)
        metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);

    status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteCompatibilityROIStructuredReport(const char* path,
                                                          const char* sopInstanceUID,
                                                          const char* seriesInstanceUID,
                                                          const char* studyInstanceUID,
                                                          const char* studyDescription,
                                                          const char* patientName,
                                                          const char* patientBirthDate,
                                                          const char* patientSex,
                                                          const char* patientID,
                                                          const char* referringPhysician,
                                                          const char* studyID,
                                                          const char* accessionNumber,
                                                          const char* seriesDescription,
                                                          const char* seriesNumber,
                                                          const char* manufacturer,
                                                          const char* contentDate,
                                                          const char* contentTime,
                                                          const char* referencedSOPClassUID,
                                                          const char* referencedSOPInstanceUID,
                                                          const char* referencedFrameNumber,
                                                          const unsigned char* roiArchiveBytes,
                                                          unsigned long roiArchiveLength)
{
    if (path == nullptr || path[0] == '\0' ||
        studyInstanceUID == nullptr || studyInstanceUID[0] == '\0' ||
        seriesInstanceUID == nullptr || seriesInstanceUID[0] == '\0' ||
        sopInstanceUID == nullptr || sopInstanceUID[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    const char* sopClassUID = UID_BasicTextSRStorage;

    dataset->putAndInsertString(DCM_SOPClassUID, sopClassUID, OFTrue);
    dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_StudyInstanceUID, studyInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_Modality, "SR", OFTrue);
    dataset->putAndInsertString(DCM_ConversionType, "WSD", OFTrue);

    if (studyDescription != nullptr && studyDescription[0] != '\0')
        dataset->putAndInsertString(DCM_StudyDescription, studyDescription, OFTrue);
    if (patientName != nullptr && patientName[0] != '\0')
        dataset->putAndInsertString(DCM_PatientName, patientName, OFTrue);
    if (patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        dataset->putAndInsertString(DCM_PatientBirthDate, patientBirthDate, OFTrue);
    if (patientSex != nullptr && patientSex[0] != '\0')
        dataset->putAndInsertString(DCM_PatientSex, patientSex, OFTrue);
    if (patientID != nullptr && patientID[0] != '\0')
        dataset->putAndInsertString(DCM_PatientID, patientID, OFTrue);
    if (referringPhysician != nullptr && referringPhysician[0] != '\0')
        dataset->putAndInsertString(DCM_ReferringPhysicianName, referringPhysician, OFTrue);
    if (studyID != nullptr && studyID[0] != '\0')
        dataset->putAndInsertString(DCM_StudyID, studyID, OFTrue);
    if (accessionNumber != nullptr && accessionNumber[0] != '\0')
        dataset->putAndInsertString(DCM_AccessionNumber, accessionNumber, OFTrue);
    if (seriesDescription != nullptr && seriesDescription[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesDescription, seriesDescription, OFTrue);
    if (seriesNumber != nullptr && seriesNumber[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesNumber, seriesNumber, OFTrue);
    if (manufacturer != nullptr && manufacturer[0] != '\0')
        dataset->putAndInsertString(DCM_Manufacturer, manufacturer, OFTrue);
    if (contentDate != nullptr && contentDate[0] != '\0')
        dataset->putAndInsertString(DCM_ContentDate, contentDate, OFTrue);
    if (contentTime != nullptr && contentTime[0] != '\0')
        dataset->putAndInsertString(DCM_ContentTime, contentTime, OFTrue);
    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPClassUID, referencedSOPClassUID, OFTrue);
    if (referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPInstanceUID, referencedSOPInstanceUID, OFTrue);
    if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedFrameNumber, referencedFrameNumber, OFTrue);
    if (roiArchiveBytes != nullptr && roiArchiveLength > 0)
    {
        dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument, roiArchiveBytes, roiArchiveLength, OFTrue);
        dataset->putAndInsertUint8Array(DcmTagKey(0x0071, 0x0011), roiArchiveBytes, roiArchiveLength, OFTrue);
    }

    if (metaInfo != nullptr)
    {
        metaInfo->putAndInsertString(DCM_MediaStorageSOPClassUID, sopClassUID, OFTrue);
        metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }

    OFCondition status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteCompatibilityStructuredReport(const char* path,
                                                       const char* sopInstanceUID,
                                                       const char* seriesInstanceUID,
                                                       const char* studyInstanceUID,
                                                       const char* studyDescription,
                                                       const char* patientName,
                                                       const char* patientBirthDate,
                                                       const char* patientSex,
                                                       const char* patientID,
                                                       const char* referringPhysician,
                                                       const char* studyID,
                                                       const char* accessionNumber,
                                                       const char* seriesDescription,
                                                       const char* seriesNumber,
                                                       const char* manufacturer,
                                                       const char* contentDate,
                                                       const char* contentTime,
                                                       const char* referencedSOPClassUID,
                                                       const char* referencedSOPInstanceUID,
                                                       const char* referencedFrameNumber,
                                                       const char* rootCodeMeaning,
                                                       const char* childTextValue,
                                                       const unsigned char* encapsulatedBytes,
                                                       unsigned long encapsulatedLength)
{
    if (path == nullptr || path[0] == '\0' ||
        studyInstanceUID == nullptr || studyInstanceUID[0] == '\0')
        return 0;

    DSRDocument document;
    OFCondition status = document.createNewDocument(DSRTypes::DT_BasicTextSR);
    if (status.good())
        status = document.setSpecificCharacterSet("ISO_IR 192");
    if (status.good())
        status = document.createNewSeriesInStudy(studyInstanceUID);
    if (status.good() && studyDescription != nullptr && studyDescription[0] != '\0')
        status = document.setStudyDescription(studyDescription);
    if (status.good() && seriesDescription != nullptr && seriesDescription[0] != '\0')
        status = document.setSeriesDescription(seriesDescription);
    if (status.good() && patientName != nullptr && patientName[0] != '\0')
        status = document.setPatientName(patientName);
    if (status.good() && patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        status = document.setPatientBirthDate(patientBirthDate);
    if (status.good() && patientSex != nullptr && patientSex[0] != '\0')
        status = document.setPatientSex(patientSex);
    if (status.good() && patientID != nullptr && patientID[0] != '\0')
        status = document.setPatientID(patientID);
    if (status.good() && referringPhysician != nullptr && referringPhysician[0] != '\0')
        status = document.setReferringPhysicianName(referringPhysician);
    if (status.good() && studyID != nullptr && studyID[0] != '\0')
        status = document.setStudyID(studyID);
    if (status.good() && accessionNumber != nullptr && accessionNumber[0] != '\0')
        status = document.setAccessionNumber(accessionNumber);
    if (status.good() && seriesNumber != nullptr && seriesNumber[0] != '\0')
        status = document.setSeriesNumber(seriesNumber);
    if (status.good() && manufacturer != nullptr && manufacturer[0] != '\0')
        status = document.setManufacturer(manufacturer);
    if (status.good() && contentDate != nullptr && contentDate[0] != '\0')
        status = document.setContentDate(contentDate);
    if (status.good() && contentTime != nullptr && contentTime[0] != '\0')
        status = document.setContentTime(contentTime);
    if (status.bad())
        return 0;

    DSRDocumentTree& tree = document.getTree();
    if (tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container) == 0)
        return 0;

    const char* rootMeaning = (rootCodeMeaning != nullptr && rootCodeMeaning[0] != '\0') ? rootCodeMeaning : "Annotations";
    status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", rootMeaning));
    if (status.bad())
        return 0;

    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0' &&
        referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent) == 0)
            return 0;
        tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("IHE.10", "99HUG", "Image Reference"));
        DSRImageReferenceValue imageRef{OFString(referencedSOPClassUID), OFString(referencedSOPInstanceUID)};
        if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
            imageRef.getFrameList().putString(referencedFrameNumber);
        status = tree.getCurrentContentItem().setImageReference(imageRef);
        if (status.bad())
            return 0;
        tree.goUp();
    }

    if (childTextValue != nullptr && childTextValue[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent) == 0)
            return 0;
        status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("CODE_01", OFFIS_CODING_SCHEME_DESIGNATOR, "Description"));
        if (status.bad())
            return 0;
        status = tree.getCurrentContentItem().setStringValue(childTextValue);
        if (status.bad())
            return 0;
        tree.goUp();
    }

    DcmFileFormat fileformat;
    status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    if (seriesInstanceUID != nullptr && seriesInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    if (sopInstanceUID != nullptr && sopInstanceUID[0] != '\0')
    {
        dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
        if (metaInfo != nullptr)
            metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }
    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPClassUID, referencedSOPClassUID, OFTrue);
    if (referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPInstanceUID, referencedSOPInstanceUID, OFTrue);
    if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedFrameNumber, referencedFrameNumber, OFTrue);
    if (encapsulatedBytes != nullptr && encapsulatedLength > 0)
        dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument, encapsulatedBytes, encapsulatedLength, OFTrue);

    status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteKeyObjectReport(const char* path,
                                         const char* sopInstanceUID,
                                         const char* seriesInstanceUID,
                                         const char* studyInstanceUID,
                                         const char* studyDescription,
                                         const char* patientName,
                                         const char* patientBirthDate,
                                         const char* patientSex,
                                         const char* patientID,
                                         const char* referringPhysician,
                                         const char* studyID,
                                         const char* accessionNumber,
                                         int titleCode,
                                         const char* keyDescription,
                                         const char* const* imagePaths,
                                         const char* const* imageSeriesInstanceUIDs,
                                         const char* const* imageSOPInstanceUIDs,
                                         int imageCount)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    DSRDocument document;
    OFCondition status = HorosModernDCMTKBuildKeyObjectReport(document,
                                                              sopInstanceUID,
                                                              seriesInstanceUID,
                                                              studyInstanceUID,
                                                              studyDescription,
                                                              patientName,
                                                              patientBirthDate,
                                                              patientSex,
                                                              patientID,
                                                              referringPhysician,
                                                              studyID,
                                                              accessionNumber,
                                                              titleCode,
                                                              keyDescription,
                                                              imagePaths,
                                                              imageSeriesInstanceUIDs,
                                                              imageSOPInstanceUIDs,
                                                              imageCount);
    if (status.bad())
        return 0;

    DcmFileFormat fileformat;
    status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    if (seriesInstanceUID != nullptr && seriesInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    if (sopInstanceUID != nullptr && sopInstanceUID[0] != '\0')
    {
        dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
        if (metaInfo != nullptr)
            metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }

    status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteStructuredReportFromXML(const char* xmlPath, const char* dicomPath)
{
    if (xmlPath == nullptr || xmlPath[0] == '\0' || dicomPath == nullptr || dicomPath[0] == '\0')
        return 0;

    DSRDocument document;
    if (document.readXML(xmlPath, 0).bad())
        return 0;

    DcmFileFormat fileformat;
    OFCondition status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    status = fileformat.saveFile(dicomPath, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteBinarySegmentation(const char* outputPath,
                                             const char* segmentLabel,
                                             const char* trackingUID,
                                             const char* authoringJSON,
                                             double colorRed,
                                             double colorGreen,
                                             double colorBlue,
                                             const char* const* sourceImagePaths,
                                             const unsigned char* const* frameMasks,
                                             int frameCount,
                                             unsigned short rows,
                                             unsigned short columns,
                                             char** failureReason)
{
    if (failureReason != nullptr)
        *failureReason = nullptr;
    if (outputPath == nullptr || outputPath[0] == '\0')
        return HorosModernDCMTKSegmentationFailure(failureReason, "The DICOM SEG output path is empty.");
    if (sourceImagePaths == nullptr || frameMasks == nullptr || frameCount <= 0 || rows == 0 || columns == 0)
        return HorosModernDCMTKSegmentationFailure(failureReason, "The DICOM SEG source geometry is incomplete.");

    DcmFileFormat sourceFile;
    OFCondition status = sourceFile.loadFile(sourceImagePaths[0]);
    if (status.bad() || sourceFile.getDataset() == nullptr)
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot read the first source image: ") + status.text());

    IODGeneralEquipmentModule::EquipmentInfo equipment("Horos Project", "Horos Metal ROI", "HOROS", "1");
    ContentIdentificationMacro content("1", "HOROSROI", "Horos manual 3D segmentation", "Horos");
    DcmSegmentation* rawSegmentation = nullptr;
    status = DcmSegmentation::createBinarySegmentation(rawSegmentation, rows, columns, equipment, content);
    std::unique_ptr<DcmSegmentation> segmentation(rawSegmentation);
    if (status.bad() || segmentation == nullptr)
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot create the DICOM SEG object: ") + status.text());

    status = segmentation->importFromSourceImage(*sourceFile.getDataset());
    if (status.bad())
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot import patient and study identity into DICOM SEG: ") + status.text());

    DcmSegment* segment = nullptr;
    const OFString resolvedLabel = segmentLabel != nullptr && segmentLabel[0] != '\0' ? segmentLabel : "ROI";
    OFString seriesDescription = "SEG ";
    seriesDescription += resolvedLabel;
    if (seriesDescription.length() > 64)
        seriesDescription.resize(64);
    segmentation->getSeries().setSeriesDescription(seriesDescription);
    segmentation->getSeries().setSeriesNumber("9001");

    CodeSequenceMacro category("85756007", "SCT", "Tissue");
    CodeSequenceMacro propertyType("85756007", "SCT", "Tissue");
    status = DcmSegment::create(segment, resolvedLabel, category, propertyType, DcmSegTypes::SAT_MANUAL);
    if (status.bad() || segment == nullptr)
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot describe the DICOM segment: ") + status.text());
    segment->setTrackingID(resolvedLabel);
    if (trackingUID != nullptr && trackingUID[0] != '\0')
        segment->setTrackingUID(trackingUID);
    double displayL = 0;
    double displayA = 0;
    double displayB = 0;
    IODCIELabUtil::rgb2DicomLab(
        displayL,
        displayA,
        displayB,
        std::max(0.0, std::min(colorRed, 1.0)),
        std::max(0.0, std::min(colorGreen, 1.0)),
        std::max(0.0, std::min(colorBlue, 1.0))
    );
    segment->setRecommendedDisplayCIELabValue(
        static_cast<Uint16>(std::lround(std::max(0.0, std::min(displayL, 65535.0)))),
        static_cast<Uint16>(std::lround(std::max(0.0, std::min(displayA, 65535.0)))),
        static_cast<Uint16>(std::lround(std::max(0.0, std::min(displayB, 65535.0))))
    );
    Uint16 segmentNumber = 0;
    status = segmentation->addSegment(segment, segmentNumber);
    if (status.bad())
    {
        delete segment;
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot add the segment to DICOM SEG: ") + status.text());
    }

    OFString pixelSpacing;
    OFString sliceThickness;
    OFString spacingBetweenSlices;
    sourceFile.getDataset()->findAndGetOFStringArray(DCM_PixelSpacing, pixelSpacing);
    sourceFile.getDataset()->findAndGetOFStringArray(DCM_SliceThickness, sliceThickness);
    sourceFile.getDataset()->findAndGetOFStringArray(DCM_SpacingBetweenSlices, spacingBetweenSlices);
    if (pixelSpacing.empty())
        pixelSpacing = "1\\1";
    if (sliceThickness.empty())
        sliceThickness = "1";
    if (spacingBetweenSlices.empty())
        spacingBetweenSlices = sliceThickness;

    FGPixelMeasures pixelMeasures;
    pixelMeasures.setPixelSpacing(pixelSpacing);
    pixelMeasures.setSliceThickness(sliceThickness);
    pixelMeasures.setSpacingBetweenSlices(spacingBetweenSlices);
    status = segmentation->addForAllFrames(pixelMeasures);
    if (status.bad())
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot add pixel geometry to DICOM SEG: ") + status.text());

    int writtenFrameCount = 0;
    const size_t pixelsPerFrame = static_cast<size_t>(rows) * static_cast<size_t>(columns);
    for (int frameIndex = 0; frameIndex < frameCount; ++frameIndex)
    {
        const unsigned char* mask = frameMasks[frameIndex];
        const char* sourcePath = sourceImagePaths[frameIndex];
        if (mask == nullptr || sourcePath == nullptr || sourcePath[0] == '\0')
            continue;
        if (std::all_of(mask, mask + pixelsPerFrame, [](unsigned char value) { return value == 0; }))
            continue;

        DcmFileFormat frameSource;
        status = frameSource.loadFile(sourcePath);
        if (status.bad() || frameSource.getDataset() == nullptr)
            return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot read a referenced source image: ") + status.text());

        OFString position[3];
        for (unsigned long component = 0; component < 3; ++component)
        {
            status = frameSource.getDataset()->findAndGetOFString(
                DCM_ImagePositionPatient,
                position[component],
                component
            );
            if (status.bad() || position[component].empty())
                return HorosModernDCMTKSegmentationFailure(failureReason, "A source image has no Image Position (Patient).");
        }
        OFString orientation[6];
        for (unsigned long component = 0; component < 6; ++component)
        {
            status = frameSource.getDataset()->findAndGetOFString(
                DCM_ImageOrientationPatient,
                orientation[component],
                component
            );
            if (status.bad() || orientation[component].empty())
                return HorosModernDCMTKSegmentationFailure(failureReason, "A source image has no Image Orientation (Patient).");
        }

        FGPlanePosPatient planePosition;
        FGPlaneOrientationPatient planeOrientation;
        FGFrameContent frameContent;
        FGDerivationImage derivation;
        status = planePosition.setImagePositionPatient(position[0], position[1], position[2]);
        if (status.bad())
            return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot encode source image position in DICOM SEG: ") + status.text());
        status = planeOrientation.setImageOrientationPatient(
            orientation[0],
            orientation[1],
            orientation[2],
            orientation[3],
            orientation[4],
            orientation[5]
        );
        if (status.bad())
            return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot encode source image orientation in DICOM SEG: ") + status.text());
        frameContent.setStackID("1");
        frameContent.setInStackPositionNumber(static_cast<Uint32>(frameIndex + 1));
        frameContent.setDimensionIndexValues(1, 0);
        frameContent.setDimensionIndexValues(static_cast<Uint32>(frameIndex + 1), 1);

        DerivationImageItem* derivationItem = nullptr;
        status = derivation.addDerivationImageItem(
            CodeSequenceMacro("113076", "DCM", "Segmentation"),
            "Manual three-dimensional segmentation in Horos",
            derivationItem
        );
        if (status.good() && derivationItem != nullptr)
        {
            SourceImageItem* sourceItem = nullptr;
            status = derivationItem->addSourceImageItem(
                frameSource.getDataset(),
                CodeSequenceMacro("121322", "DCM", "Source image for image processing operation"),
                sourceItem
            );
            if (status.good() && sourceItem != nullptr)
                sourceItem->setSpatialLocationsPreserved("YES", OFTrue);
        }
        if (status.bad())
            return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot reference a source image from DICOM SEG: ") + status.text());

        OFVector<FGBase*> perFrameGroups;
        perFrameGroups.push_back(&planePosition);
        perFrameGroups.push_back(&planeOrientation);
        perFrameGroups.push_back(&frameContent);
        perFrameGroups.push_back(&derivation);
        status = segmentation->addFrame(const_cast<Uint8*>(mask), segmentNumber, perFrameGroups);
        if (status.bad())
            return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot add a binary mask frame to DICOM SEG: ") + status.text());
        ++writtenFrameCount;
    }

    if (writtenFrameCount == 0)
        return HorosModernDCMTKSegmentationFailure(failureReason, "The ROI does not intersect any source image frames.");

    char dimensionUID[100];
    dcmGenerateUniqueIdentifier(dimensionUID, SITE_INSTANCE_UID_ROOT);
    IODMultiframeDimensionModule& dimensions = segmentation->getDimensions();
    dimensions.addDimensionIndex(DCM_StackID, dimensionUID, DCM_FrameContentSequence, "ROI_STACK");
    dimensions.addDimensionIndex(DCM_InStackPositionNumber, dimensionUID, DCM_FrameContentSequence, "ROI_STACK");
    IODMultiframeDimensionModule::DimensionOrganizationItem* organization =
        new IODMultiframeDimensionModule::DimensionOrganizationItem;
    organization->setDimensionOrganizationUID(dimensionUID);
    dimensions.getDimensionOrganizationSequence().push_back(organization);

    segmentation->getFunctionalGroups().setCheckOnWrite(OFTrue);
    segmentation->setCheckDimensionsOnWrite(OFTrue);
    DcmFileFormat output;
    status = segmentation->writeDataset(*output.getDataset());
    if (status.bad())
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot serialize DICOM SEG: ") + status.text());

    if (trackingUID != nullptr && trackingUID[0] != '\0')
    {
        const std::string stableSOPInstanceUID = std::string(trackingUID) + ".1";
        const std::string stableSeriesInstanceUID = std::string(trackingUID) + ".2";
        output.getDataset()->putAndInsertString(DCM_SOPInstanceUID, stableSOPInstanceUID.c_str(), OFTrue);
        output.getDataset()->putAndInsertString(DCM_SeriesInstanceUID, stableSeriesInstanceUID.c_str(), OFTrue);
    }

    DcmTag creatorTag(DcmTagKey(0x7777, 0x0010), EVR_LO);
    output.getDataset()->putAndInsertString(creatorTag, "HOROS_METAL_ROI", OFTrue);
    if (authoringJSON != nullptr && authoringJSON[0] != '\0')
    {
        DcmTag authoringTag(DcmTagKey(0x7777, 0x1001), EVR_UT);
        output.getDataset()->putAndInsertString(authoringTag, authoringJSON, OFTrue);
    }

    status = output.saveFile(outputPath, EXS_LittleEndianExplicit);
    if (status.bad())
        return HorosModernDCMTKSegmentationFailure(failureReason, std::string("Cannot save DICOM SEG: ") + status.text());
    return 1;
}

void HorosModernDCMTKFreeBasicMetadata(HorosModernDCMTKBasicMetadata* metadata)
{
    if (metadata == nullptr)
        return;

    std::free(metadata->transferSyntaxUID);
    std::free(metadata->privateInformationCreatorUID);
    std::free(metadata->specificCharacterSet);
    std::free(metadata->sopClassUID);
    std::free(metadata->imageType);
    std::free(metadata->sopInstanceUID);
    std::free(metadata->modality);
    std::free(metadata->acquisitionDate);
    std::free(metadata->contentDate);
    std::free(metadata->seriesDate);
    std::free(metadata->studyDate);
    std::free(metadata->acquisitionTime);
    std::free(metadata->contentTime);
    std::free(metadata->seriesTime);
    std::free(metadata->studyTime);
    std::free(metadata->scanOptions);
    std::free(metadata->echoTime);
    std::free(metadata->instanceNumber);
    std::free(metadata->seriesNumber);
    std::free(metadata->seriesInstanceUID);
    std::free(metadata->studyInstanceUID);
    std::free(metadata->studyID);
    HorosModernDCMTKClearBasicMetadata(metadata);
}

void HorosModernDCMTKFreeBuffer(void* buffer)
{
    std::free(buffer);
}

void HorosModernDCMTKFreeDecodedFrame(HorosModernDCMTKDecodedFrame* frame)
{
    if (frame == nullptr)
        return;

    if (frame->pixels != nullptr)
        std::free(frame->pixels);
    if (frame->failureReason != nullptr)
        std::free(frame->failureReason);

    HorosModernDCMTKClearDecodedFrame(frame);
}

void HorosModernDCMTKFreeString(char* value)
{
    std::free(value);
}
