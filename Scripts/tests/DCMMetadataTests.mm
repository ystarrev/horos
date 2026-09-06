// Standalone runtime harness for a user-approved build; not an app target.
// Arguments: dcm_metadata_baseline.xml, newly built modern bridge dylib.
#import <Foundation/Foundation.h>
#import "HorosDICOMMetadata.h"
#include "ModernDCMTKBridge.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dlfcn.h>
#include <cstdlib>
#include <string>
#include <vector>

static void Check(BOOL result, NSString *message)
{
    if (!result)
    {
        NSLog(@"FAIL: %@", message);
        std::abort();
    }
}

static NSXMLElement *Element(NSXMLDocument *document, NSString *tag)
{
    NSString *xpath = [NSString stringWithFormat:@"//*[@attributeTag='%@']", tag];
    return [[document nodesForXPath:xpath error:nil] firstObject];
}

static void CheckPDFExtraction(void *bridge, NSString *directory)
{
    auto copyPDF = reinterpret_cast<int (*)(const char*, unsigned char**, unsigned long*, char**, char**)>(
        dlsym(bridge, "HorosModernDCMTKCopyEncapsulatedPDF"));
    auto copyDocument = reinterpret_cast<int (*)(const char*, unsigned char**, unsigned long*)>(
        dlsym(bridge, "HorosModernDCMTKCopyEncapsulatedDocument"));
    auto freeBuffer = reinterpret_cast<void (*)(void*)>(dlsym(bridge, "HorosModernDCMTKFreeBuffer"));
    auto freeString = reinterpret_cast<void (*)(char*)>(dlsym(bridge, "HorosModernDCMTKFreeString"));
    Check(copyPDF && copyDocument && freeBuffer && freeString, @"PDF bridge symbols exported");

    // Extraction fixture, not a PDF renderer test. An odd byte count exercises DICOM OB padding.
    std::string payload = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n";
    if (payload.size() % 2 == 0) payload += '\n';
    DcmFileFormat file;
    DcmDataset *dataset = file.getDataset();
    Check(dataset->putAndInsertString(DCM_SOPClassUID, UID_EncapsulatedPDFStorage).good(), @"PDF SOP class");
    Check(dataset->putAndInsertString(DCM_SOPInstanceUID, "1.2.3.4.6").good(), @"PDF SOP instance");
    Check(dataset->putAndInsertString(DCM_MIMETypeOfEncapsulatedDocument, "application/pdf").good(), @"PDF MIME type");
    Check(dataset->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100").good(), @"PDF source charset");
    Check(dataset->putAndInsertString(DCM_DocumentTitle, "R\xe9sum\xe9").good(), @"PDF Latin-1 title");
    Check(dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument,
        reinterpret_cast<const Uint8*>(payload.data()), payload.size()).good(), @"PDF payload");
    Check(dataset->putAndInsertUint32(DCM_EncapsulatedDocumentLength, payload.size()).good(), @"PDF unpadded length");
    NSString *path = [directory stringByAppendingPathComponent:@"pdf.dcm"];
    auto read = [&](BOOL expectedSuccess, unsigned long expectedLength, NSString *expectedTitle) {
        NSData *before = [NSData dataWithContentsOfFile:path];
        unsigned char *buffer = nullptr;
        unsigned long length = 0;
        char *title = nullptr, *failure = nullptr;
        int success = copyPDF(path.fileSystemRepresentation, &buffer, &length, &title, &failure);
        Check((success != 0) == expectedSuccess, @"PDF extraction status");
        if (expectedSuccess)
        {
            Check(buffer && length == expectedLength && failure == nullptr, @"PDF extraction length");
            Check(std::memcmp(buffer, payload.data(), payload.size()) == 0, @"PDF bytes unchanged");
            Check(title && [[NSString stringWithUTF8String:title] isEqualToString:expectedTitle], @"PDF decoded title");
        }
        else
            Check(!buffer && length == 0 && !title && failure, @"PDF failure has empty outputs and an error");
        freeBuffer(buffer);
        freeString(title);
        freeString(failure);
        Check([before isEqualToData:[NSData dataWithContentsOfFile:path]], @"PDF source DICOM unchanged");
    };
    for (E_TransferSyntax syntax : {EXS_LittleEndianExplicit, EXS_LittleEndianImplicit, EXS_BigEndianExplicit})
    {
        Check(file.saveFile(path.fileSystemRepresentation, syntax).good(), @"Save synthetic DICOM PDF");
        read(YES, payload.size(), @"R\u00e9sum\u00e9");
    }
    Check(dataset->findAndDeleteElement(DCM_EncapsulatedDocumentLength).good(), @"Remove optional length");
    Check(dataset->putAndInsertString(DCM_MIMETypeOfEncapsulatedDocument, "Application/PDF").good(), @"Case-insensitive MIME type");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save legacy PDF");
    read(YES, payload.size() + 1, @"R\u00e9sum\u00e9");
    Check(dataset->putAndInsertString(DCM_SpecificCharacterSet, "INVALID_CHARSET").good(), @"Invalid optional-title charset");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save invalid-title PDF");
    read(YES, payload.size() + 1, @"");
    Check(dataset->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100").good(), @"Restore charset");
    for (Uint32 invalidLength : {Uint32(0), Uint32(payload.size() - 2), Uint32(payload.size() + 100)})
    {
        Check(dataset->putAndInsertUint32(DCM_EncapsulatedDocumentLength, invalidLength).good(), @"Invalid PDF length");
        Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save invalid-length PDF");
        read(NO, 0, nil);
    }
    Check(dataset->putAndInsertUint32(DCM_EncapsulatedDocumentLength, payload.size()).good(), @"Restore PDF length");
    Check(dataset->putAndInsertString(DCM_MIMETypeOfEncapsulatedDocument, "text/xml").good(), @"Non-PDF MIME type");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save non-PDF MIME");
    read(NO, 0, nil);
    Check(dataset->putAndInsertString(DCM_MIMETypeOfEncapsulatedDocument, "application/pdf").good(), @"Restore MIME type");
    Check(dataset->putAndInsertString(DCM_SOPClassUID, UID_BasicTextSRStorage).good(), @"Legacy ROI/SR SOP class");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save SR payload");
    read(NO, 0, nil);
    unsigned char *buffer = nullptr;
    unsigned long length = 0;
    Check(copyDocument(path.fileSystemRepresentation, &buffer, &length) && length == payload.size() + 1,
          @"Generic legacy ROI/SR extraction remains unchanged");
    freeBuffer(buffer);
    Check(dataset->putAndInsertString(DCM_SOPClassUID, UID_EncapsulatedPDFStorage).good(), @"Restore PDF SOP class");
    Check(dataset->findAndDeleteElement(DCM_EncapsulatedDocument).good(), @"Remove missing PDF payload");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), @"Save missing PDF");
    read(NO, 0, nil);
    char *failure = nullptr;
    Check(!copyPDF(nullptr, &buffer, &length, nullptr, &failure) && failure && !buffer && length == 0, @"Missing path rejected");
    freeString(failure);
}

static void CheckRawImport(void *bridge, NSString *directory)
{
    auto write = reinterpret_cast<decltype(&HorosModernDCMTKWriteRawSecondaryCapture)>(
        dlsym(bridge, "HorosModernDCMTKWriteRawSecondaryCapture"));
    auto freeString = reinterpret_cast<void (*)(char*)>(dlsym(bridge, "HorosModernDCMTKFreeString"));
    Check(write && freeString, @"Raw image writer exported");
    const unsigned char little[] = {0, 0, 1, 0, 0, 128, 255, 255};
    const unsigned char big[] = {0, 0, 0, 1, 128, 0, 255, 255};
    const unsigned char bytes[] = {0, 127, 128, 255};
    HorosModernDCMTKRawImage image = {};
    image.rows = image.columns = 2;
    image.rowSpacing = 0.75; image.columnSpacing = 1.25;
    image.sliceThickness = 2.5; image.slicePosition = 5;
    image.patientName = "Test^J\xc3\xa9r\xc3\xb4me";
    image.patientID = "RAW_TEST";
    image.studyDescription = "Synthetic raw import";
    image.studyInstanceUID = "1.2.3.100";
    image.seriesInstanceUID = "1.2.3.100.1";
    image.studyID = "100";
    image.date = "20260906"; image.time = "120000";
    NSString *path = [directory stringByAppendingPathComponent:@"raw.dcm"];
    std::string previousUID;
    for (int pixelType = 0; pixelType <= 5; ++pixelType)
    {
        image.rows = image.columns = pixelType == 0 ? 1 : 2;
        image.samplesPerPixel = pixelType == 0 ? 3 : 1;
        image.bitsAllocated = pixelType < 2 ? 8 : 16;
        image.isSigned = pixelType == 3 || pixelType == 5;
        image.isBigEndian = pixelType == 4 || pixelType == 5;
        image.pixels = pixelType < 2 ? bytes : (image.isBigEndian ? big : little);
        image.length = pixelType == 0 ? 3 : (pixelType == 1 ? 4 : 8);
        image.instanceNumber = pixelType;
        char *failure = nullptr;
        Check(write(path.fileSystemRepresentation, &image, &failure) && !failure, @"Write raw frame");
        DcmFileFormat file;
        Check(file.loadFile(path.fileSystemRepresentation).good(), @"Read back raw frame");
        DcmDataset *dataset = file.getDataset();
        OFString value;
        Check(dataset->findAndGetOFStringArray(DCM_SOPClassUID, value).good() && value == UID_SecondaryCaptureImageStorage, @"Secondary capture SOP class");
        Check(dataset->findAndGetOFStringArray(DCM_SOPInstanceUID, value).good() && value != previousUID.c_str(), @"Unique instance UID");
        previousUID = value.c_str();
        Check(dataset->findAndGetOFStringArray(DCM_PatientName, value).good() && value == image.patientName, @"UTF-8 patient name unchanged");
        Check(dataset->findAndGetOFStringArray(DCM_PixelSpacing, value).good() && value == "0.75\\1.25", @"Non-square row/column spacing preserved");
        Check(dataset->findAndGetOFStringArray(DCM_ImageOrientationPatient, value).good() && value == "1\\0\\0\\0\\1\\0", @"No image rotation");
        Check(dataset->findAndGetOFStringArray(DCM_ImagePositionPatient, value).good() && value == "0\\0\\5", @"Slice position preserved");
        Uint16 representation = 99;
        Check(dataset->findAndGetUint16(DCM_PixelRepresentation, representation).good() && representation == image.isSigned, @"Signedness preserved");
        if (image.bitsAllocated == 8)
        {
            const Uint8 *pixels = nullptr;
            unsigned long count = 0;
            Check(dataset->findAndGetUint8Array(DCM_PixelData, pixels, &count).good() &&
                  count == 4 && std::memcmp(pixels, bytes, image.length) == 0, @"8-bit bytes and odd RGB padding");
        }
        else
        {
            const Uint16 *pixels = nullptr;
            unsigned long count = 0;
            Check(dataset->findAndGetUint16Array(DCM_PixelData, pixels, &count).good() && count == 4 &&
                  pixels[0] == 0 && pixels[1] == 1 && pixels[2] == 0x8000 && pixels[3] == 0xffff, @"16-bit values and byte order unchanged");
        }
    }
    NSData *before = [NSData dataWithContentsOfFile:path];
    --image.length;
    char *failure = nullptr;
    Check(!write(path.fileSystemRepresentation, &image, &failure) && failure, @"Truncated raw frame rejected");
    freeString(failure);
    Check([before isEqualToData:[NSData dataWithContentsOfFile:path]], @"Invalid input does not overwrite a file");
    ++image.length;
    image.rowSpacing = 0;
    failure = nullptr;
    Check(!write(path.fileSystemRepresentation, &image, &failure) && failure, @"Zero spacing rejected");
    freeString(failure);
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        Check(argc == 3, @"Expected fixture and bridge paths");
        NSString *xml = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                                   encoding:NSUTF8StringEncoding error:nil];
        NSError *error = nil;
        NSXMLDocument *document = HorosDICOMMetadataDocument(xml, &error);
        Check(document != nil && error == nil, @"Parse synthetic metadata fixture");
        Check([document.rootElement.name isEqualToString:@"DICOMObject"], @"Root compatibility");
        Check([Element(document, @"0008,0030").stringValue isEqualToString:@"000000.123456"], @"Raw TM precision");
        Check([Element(document, @"0008,002a").stringValue isEqualToString:@"20260228000000.123456-0700"], @"Raw DT offset");
        Check([Element(document, @"0010,0010").stringValue isEqualToString:@"Test^J\u00e9r\u00f4me & Example"], @"Unicode and XML escaping");
        Check(Element(document, @"0020,0032").childCount == 3, @"Separate VM values");
        Check(Element(document, @"0040,a160").childCount == 1, @"Literal text backslash stays in one value");
        Check([Element(document, @"0040,a160").stringValue containsString:@"literal \\ slash <tag>\n"], @"Text and newline unchanged");
        Check([Element(document, @"0008,0050").stringValue isEqualToString:@""], @"Empty value");
        Check([HorosDICOMMetadataString(document.rootElement, @"0008,0050") isEqualToString:@""], @"Present empty scalar stays empty");
        Check(HorosDICOMMetadataValues(document.rootElement, @"0008,0050").count == 0, @"Empty scalar is not a phantom key-frame zero");
        Check(HorosDICOMMetadataString(document.rootElement, @"0008,1155") == nil, @"Direct lookup does not borrow nested reference UID");
        Check([HorosDICOMMetadataNumbers(document.rootElement, @"0020,0032") isEqualToArray:@[@1.25, @(-2.5), @0]], @"Numeric VM and signs preserved");
        Check(HorosDICOMMetadataValues(document.rootElement, @"7fe0,0010") == nil, @"No binary placeholders in operational values");
        Check(HorosDICOMMetadataValues(document.rootElement, @"0008,1115") == nil, @"Sequence cannot be read as a scalar");
        Check(HorosDICOMMetadataItems(document.rootElement, @"0008,1115").count == 2, @"Direct sequence items include empty items");
        Check([HorosDICOMMetadataString(document.rootElement, @"0040,a160") containsString:@"literal \\ slash <tag>\n"], @"Operational text preserves literal backslashes");
        NSXMLElement *invalidNumbers = [NSXMLElement elementWithName:@"item"];
        [invalidNumbers addChild:HorosDICOMMetadataAttribute(@"3006,0050", @"ContourData", @"DS", @[@"1", @"not-a-number", @"3"])];
        Check(HorosDICOMMetadataNumbers(invalidNumbers, @"3006,0050") == nil, @"Malformed geometry is not coerced to zero");
        Check(Element(document, @"0008,1115").childCount == 2, @"Empty sequence item retained");
        Check([[[Element(document, @"7fe0,0010") attributeForName:@"readOnly"] stringValue] boolValue], @"Binary is read-only");
        Check(Element(document, @"7fe0,0010").childCount == 1, @"Compressed fragments are not fake sequence items");
        Check([[[Element(document, @"0008,1115") attributeForName:@"readOnly"] stringValue] boolValue], @"Sequence writing remains disabled");
        Check([HorosDICOMMetadataText(document) containsString:@"(0008,1115)[0].(0008,1140)[0].(0008,1155)"], @"Nested item paths");
        Check([HorosDICOMMetadataText(document) containsString:@"(0002,0010)"], @"File meta information retained");
        Check([HorosDICOMMetadataShortValue(Element(document, @"0010,0010")) isEqualToString:@"Test^J\u00e9r\u00f4me & Example"], @"Unicode tag-menu preview");
        Check([HorosDICOMMetadataShortValue(Element(document, @"0020,0032")) isEqualToString:@"1.25 -2.5 0"], @"Multiple values in tag-menu preview");
        Check(HorosDICOMMetadataShortValue(Element(document, @"0008,1115")).length == 0, @"No sequence menu preview");
        Check(HorosDICOMMetadataShortValue(Element(document, @"7fe0,0010")).length == 0, @"No pixel menu preview");
        Check(HorosDICOMMetadataShortValue(Element(document, @"0042,0011")).length == 0, @"No embedded document menu preview");
        Check(HorosDICOMMetadataShortValue(HorosDICOMMetadataAttribute(@"0040,a160", @"TextValue", @"UT",
            @[[ @"x" stringByPaddingToLength:100 withString:@"x" startingAtIndex:0]])).length == 0, @"Long preview omitted without a length attribute");
        Check(HorosDICOMMetadataAttribute(@"bad", @"Bad", @"LO", @[]) == nil, @"Invalid tag rejected");
        Check(HorosDICOMMetadataDocument(@"<wrong/>", &error) == nil && error != nil, @"Unexpected XML rejected");
        Check(HorosDICOMMetadataDocument(@"<data-set>", &error) == nil && error != nil, @"Malformed XML rejected");
        NSString *dtd = @"<!DOCTYPE data-set [<!ENTITY local 'value'>]><data-set/>";
        Check(HorosDICOMMetadataDocument(dtd, &error) == nil, @"DTD rejected");

        void *bridge = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
        Check(bridge != nullptr, @"Load built bridge");
        auto copyXML = reinterpret_cast<char* (*)(const char*, char**)>(dlsym(bridge, "HorosModernDCMTKCopyMetadataXML"));
        auto freeString = reinterpret_cast<void (*)(char*)>(dlsym(bridge, "HorosModernDCMTKFreeString"));
        Check(copyXML && freeString, @"Metadata bridge symbols exported");
        char *reason = nullptr;
        Check(copyXML(nullptr, &reason) == nullptr && reason != nullptr, @"Invalid file request reports error");
        freeString(reason);

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Check([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:&error], @"Create synthetic test directory");
        @try
        {
            CheckRawImport(bridge, directory);
            CheckPDFExtraction(bridge, directory);
            DcmFileFormat file;
            DcmDataset *dataset = file.getDataset();
            Check(dataset->putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage).good(), @"SOP class");
            Check(dataset->putAndInsertString(DCM_SOPInstanceUID, "1.2.3.4.5").good(), @"SOP UID");
            Check(dataset->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100").good(), @"Source charset");
            Check(dataset->putAndInsertString(DCM_PatientName, "Test^J\xe9r\xf4me").good(), @"Latin-1 name");
            Check(dataset->putAndInsertString(DCM_StudyDate, "20260228").good(), @"Date");
            Check(dataset->putAndInsertString(DCM_StudyTime, "000000.123456").good(), @"Time");
            std::string longText(8192, 'x');
            Check(dataset->putAndInsertString(DCM_TextValue, longText.c_str()).good(), @"Deferred long text");
            auto *sequence = new DcmSequenceOfItems(DCM_ReferencedSeriesSequence);
            auto *item = new DcmItem;
            Check(item->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100").good(), @"Nested charset");
            Check(item->putAndInsertString(DCM_PatientName, "Nested^J\xe9r\xf4me").good(), @"Nested name");
            Check(sequence->insert(item).good() && dataset->insert(sequence).good(), @"Nested sequence");
            std::vector<Uint16> pixels(32768, 1234);
            Check(dataset->putAndInsertUint16Array(DCM_PixelData, pixels.data(), pixels.size()).good(), @"Deferred pixels");

            for (E_TransferSyntax syntax : {EXS_LittleEndianExplicit, EXS_LittleEndianImplicit, EXS_BigEndianExplicit})
            {
                NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.dcm", syntax]];
                Check(file.saveFile(path.fileSystemRepresentation, syntax).good(), @"Write synthetic DICOM");
                NSData *before = [NSData dataWithContentsOfFile:path];
                reason = nullptr;
                char *result = copyXML(path.fileSystemRepresentation, &reason);
                Check(result != nullptr && reason == nullptr, @"DCMTK bulk metadata read");
                NSXMLDocument *actual = HorosDICOMMetadataDocument([NSString stringWithUTF8String:result], &error);
                freeString(result);
                freeString(reason);
                Check(actual != nil, @"Actual DCMTK XML matches adapter");
                Check([Element(actual, @"0008,0005").stringValue isEqualToString:@"ISO_IR 100"], @"Original charset displayed");
                Check([Element(actual, @"0010,0010").stringValue isEqualToString:@"Test^J\u00e9r\u00f4me"], @"Actual character conversion");
                NSArray *names = [actual nodesForXPath:@"//*[@attributeTag='0010,0010']" error:nil];
                Check(names.count == 2 && [[names[1] stringValue] isEqualToString:@"Nested^J\u00e9r\u00f4me"], @"Nested character conversion");
                Check(Element(actual, @"0040,a160").stringValue.length == longText.size(), @"Long text loaded without loading pixels");
                Check([Element(actual, @"7fe0,0010").stringValue containsString:@"Binary"], @"Pixel data omitted");
                Check([before isEqualToData:[NSData dataWithContentsOfFile:path]], @"Source file unchanged");
            }
        }
        @finally
        {
            [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        }
        NSLog(@"DCM metadata runtime checks passed");
    }
    return 0;
}
