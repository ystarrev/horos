// Standalone runtime harness for a user-approved build; not an app target.
// Arguments: dcm_metadata_baseline.xml, newly built modern bridge dylib.
#import <Foundation/Foundation.h>
#import "HorosDICOMMetadata.h"
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
        Check(Element(document, @"0008,1115").childCount == 2, @"Empty sequence item retained");
        Check([[[Element(document, @"7fe0,0010") attributeForName:@"readOnly"] stringValue] boolValue], @"Binary is read-only");
        Check(Element(document, @"7fe0,0010").childCount == 1, @"Compressed fragments are not fake sequence items");
        Check([[[Element(document, @"0008,1115") attributeForName:@"readOnly"] stringValue] boolValue], @"Sequence writing remains disabled");
        Check([HorosDICOMMetadataText(document) containsString:@"(0008,1115)[0].(0008,1140)[0].(0008,1155)"], @"Nested item paths");
        Check([HorosDICOMMetadataText(document) containsString:@"(0002,0010)"], @"File meta information retained");
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
