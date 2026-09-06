#import "HorosJPEGCodecBridge.h"

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmjpeg/djdecode.h>
#include <dcmtk/ofstd/ofcond.h>
#include <dcmtk/ofstd/ofstd.h>

static void HorosRegisterJPEGCodecs(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DJDecoderRegistration::registerCodecs();
    });
}

static const char *HorosUTF8StringOrDefault(NSString *value, const char *fallback)
{
    if (value.length == 0)
        return fallback;

    const char *utf8 = value.UTF8String;
    return utf8 ? utf8 : fallback;
}

NSData *HorosDecodeJPEGFrame(NSData *jpegData,
                          NSString *transferSyntaxUID,
                          NSString *photometricInterpretation,
                          int rows,
                          int columns,
                          int samplesPerPixel,
                          int bitsAllocated,
                          int bitsStored,
                          BOOL isSigned,
                          int planarConfiguration)
{
    if (jpegData.length == 0 || transferSyntaxUID.length == 0 || rows <= 0 || columns <= 0)
        return nil;

    HorosRegisterJPEGCodecs();

    DcmXfer xfer(transferSyntaxUID.UTF8String);
    const E_TransferSyntax syntax = xfer.getXfer();
    if (syntax == EXS_Unknown)
        return nil;

    if (samplesPerPixel <= 0)
        samplesPerPixel = 1;
    if (bitsAllocated <= 0)
        bitsAllocated = bitsStored > 0 ? bitsStored : 8;
    if (bitsStored <= 0 || bitsStored > bitsAllocated)
        bitsStored = bitsAllocated;

    DcmDataset dataset;
    dataset.putAndInsertUint16(DCM_Rows, static_cast<Uint16>(rows));
    dataset.putAndInsertUint16(DCM_Columns, static_cast<Uint16>(columns));
    dataset.putAndInsertUint16(DCM_SamplesPerPixel, static_cast<Uint16>(samplesPerPixel));
    dataset.putAndInsertUint16(DCM_BitsAllocated, static_cast<Uint16>(bitsAllocated));
    dataset.putAndInsertUint16(DCM_BitsStored, static_cast<Uint16>(bitsStored));
    dataset.putAndInsertUint16(DCM_HighBit, static_cast<Uint16>(bitsStored - 1));
    dataset.putAndInsertUint16(DCM_PixelRepresentation, static_cast<Uint16>(isSigned ? 1 : 0));
    dataset.putAndInsertString(
        DCM_PhotometricInterpretation,
        HorosUTF8StringOrDefault(photometricInterpretation, samplesPerPixel > 1 ? "RGB" : "MONOCHROME2")
    );
    if (samplesPerPixel > 1)
        dataset.putAndInsertUint16(
            DCM_PlanarConfiguration,
            static_cast<Uint16>(planarConfiguration > 0 ? planarConfiguration : 0)
        );

    DcmPixelData *pixelData = new DcmPixelData(DCM_PixelData);
    DcmPixelSequence *pixelSequence = new DcmPixelSequence(DcmTag(DCM_PixelData, EVR_OB));
    DcmPixelItem *offsetTable = new DcmPixelItem(DcmTag(DCM_Item, EVR_OB));
    DcmPixelItem *fragment = new DcmPixelItem(DcmTag(DCM_Item, EVR_OB));

    OFCondition status = fragment->putUint8Array(
        static_cast<const Uint8 *>(jpegData.bytes),
        static_cast<unsigned long>(jpegData.length)
    );
    if (status.bad()) {
        delete fragment;
        delete offsetTable;
        delete pixelSequence;
        delete pixelData;
        return nil;
    }
    status = pixelSequence->insert(offsetTable);
    if (status.bad()) {
        delete fragment;
        delete offsetTable;
        delete pixelSequence;
        delete pixelData;
        return nil;
    }
    offsetTable = nullptr;
    status = pixelSequence->insert(fragment);
    if (status.bad()) {
        delete fragment;
        delete pixelSequence;
        delete pixelData;
        return nil;
    }
    fragment = nullptr;
    pixelData->putOriginalRepresentation(syntax, nullptr, pixelSequence);
    pixelSequence = nullptr;
    status = dataset.insert(pixelData, OFTrue);
    if (status.bad()) {
        delete pixelData;
        return nil;
    }
    pixelData = nullptr;

    DcmElement *element = nullptr;
    if (dataset.findAndGetElement(DCM_PixelData, element).bad() || element == nullptr)
        return nil;

    DcmPixelData *datasetPixelData = dynamic_cast<DcmPixelData *>(element);
    if (datasetPixelData == nullptr)
        return nil;

    Uint32 frameSize = 0;
    status = datasetPixelData->getUncompressedFrameSize(&dataset, frameSize, OFFalse);
    if (status.bad() || frameSize == 0)
        return nil;

    const Uint32 bufferSize = (frameSize & 1) ? frameSize + 1 : frameSize;
    NSMutableData *rawData = [NSMutableData dataWithLength:bufferSize];
    Uint32 startFragment = 0;
    OFString colorModel;
    status = datasetPixelData->getUncompressedFrame(
        &dataset,
        0,
        startFragment,
        static_cast<Uint8 *>(rawData.mutableBytes),
        bufferSize,
        colorModel,
        nullptr
    );
    if (status.bad())
        return nil;

    if (bufferSize != frameSize)
        rawData.length = frameSize;
    return rawData;
}
