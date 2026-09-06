"""Non-pixel DCM migration guards. Source checks only; never builds or opens a database."""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


def source(name):
    return (SOURCES / name).read_text()


class DCMConsumerTests(unittest.TestCase):
    def test_browser_metadata_and_raw_import_do_not_construct_legacy_objects(self):
        browser = source("BrowserController.m")
        self.assertNotIn("DCMObject", browser)
        self.assertNotIn("DCMPixelDataAttribute", browser)
        self.assertEqual(browser.count("metadataDocumentForFile:[[destStudy paths] anyObject]"), 2)
        self.assertEqual(browser.count('existingOtherPatientNames = HorosDICOMMetadataString(metadata, @"0010,1001")'), 2)
        self.assertEqual(browser.count('existingOtherPatientIDs = HorosDICOMMetadataString(metadata, @"0010,1000")'), 2)
        raw = browser.split("- (IBAction)importRawData:", 1)[1].split("- (IBAction) viewXML:", 1)[0]
        for token in ("writeRawSecondaryCapture:&image", "generatedDICOMUID", "UINT16_MAX",
                      "(data.length - byteOffset) / frameLength", "isfinite(depth.doubleValue)",
                      "NSUUID.UUID.UUIDString", "Import stopped after %ld of %ld slices"):
            self.assertIn(token, raw)
        self.assertIn("image.isSigned = pixelType == 3 || pixelType == 5", raw)
        self.assertIn("image.isBigEndian = pixelType == 4 || pixelType == 5", raw)

    def test_key_images_preserve_existing_values_and_zero_based_convention(self):
        image = source("DicomImage.m")
        self.assertNotIn("DCMObject", image)
        self.assertNotIn("graphicAnnotationSequence", image)
        setter = image.split("- (void) setIsKeyImage:", 1)[1].split("- (", 1)[0]
        self.assertIn("metadataDocumentForFile:self.completePath", setter)
        self.assertIn("Cannot read existing key-image metadata", setter)
        self.assertIn('HorosDICOMMetadataValues(metadata, @"0028,6022")', setter)
        self.assertIn("[NSMutableArray arrayWithArray:existingKeyFrames]", setter)
        self.assertIn("[[self frameID] stringValue]", setter)
        self.assertIn('c = @"0"', setter)

    def test_rtstruct_keeps_conversion_and_writing_but_replaces_parser(self):
        pix = source("DCMPix.m")
        conversion = pix.split("- (void)createROIsFromRTSTRUCTFile:", 1)[1].split("- (void) reloadAnnotations", 1)[0]
        for retired in ("DCMObject", "DCMSequenceAttribute", "attributeWithName:", "attributeArrayWithName:"):
            self.assertNotIn(retired, conversion)
        for tag in ("3006,0010", "3006,0012", "3006,0014", "3006,0020", "3006,0039", "3006,0040"):
            self.assertIn(tag, conversion)
        for token in ("imageGeometry", "pointCount.count != 1", "dcmPoints.count % 3",
                      "isfinite(point.floatValue)", "N2PerformManagedObjectContextBlockAndWait",
                      "RSTRUCTConvertToBrush", "archiveROIsAsDICOM:", "roiPathForImage:"):
            self.assertIn(token, conversion)
        self.assertLess(conversion.index("Invalid contour point count"), conversion.index("archiveROIsAsDICOM:"))

    def test_metadata_access_is_direct_and_rejects_binary_and_invalid_numbers(self):
        metadata = source("HorosDICOMMetadata.m")
        access = metadata.split("static NSXMLElement *HorosDICOMMetadataElement", 1)[1].split(
            "NSString *HorosDICOMMetadataShortValue", 1)[0]
        for token in ("item.children", 'attributeForName:@"attributeTag"', 'attributeForName:@"readOnly"',
                      'isEqualToString:@"SQ"', 'elementsForName:@"item"', "scanDouble:&number", "!isfinite(number)"):
            self.assertIn(token, access)
        self.assertNotIn("nodesForXPath", access)
        self.assertNotIn("metadataDocumentForFile", access)

    def test_raw_writer_is_native_and_checks_dimensions_and_byte_order(self):
        bridge = source("ModernDCMTKBridge.cpp")
        writer = bridge.split("int HorosModernDCMTKWriteRawSecondaryCapture", 1)[1].split(
            "int HorosModernDCMTKReplaceTagValue", 1)[0]
        for token in ("image->length != expected", "expected > 0xfffffffeUL", "UID_SecondaryCaptureImageStorage",
                      '"ISO_IR 192"', "std::isfinite", "image->isBigEndian", "words.data()",
                      "EVR_OB", "EVR_OW", "file.saveFile(path, EXS_LittleEndianExplicit)"):
            self.assertIn(token, writer)
        wrapper = source("DicomFileDCMTKCategory.mm").split("+ (BOOL)writeRawSecondaryCapture:", 1)[1].split(
            "+ (NSXMLDocument *)metadataDocumentForFile:", 1)[0]
        self.assertLess(wrapper.index("BOOL success = write("), wrapper.index("moveItemAtPath:"))
        self.assertIn('[@"." stringByAppendingString:NSUUID.UUID.UUIDString]', wrapper)
        self.assertIn("removeItemAtPath:temporary", wrapper)

    def test_nonimage_previews_do_not_require_legacy_pixel_parser(self):
        pix = source("DCMPix.m")
        preview = pix.split("- (BOOL)loadDICOMModernNonImage", 1)[1].split("- (BOOL)loadDICOMModernDCMTK", 1)[0]
        for token in ("metadataDocumentForFile:self.srcFile", "encapsulatedPDFForFile:self.srcFile",
                      "frameNo >= rep.pageCount", 'hasPrefix:@"1.2.840.10008.5.1.4.1.1.88."', "loadCustomImageAnnotations"):
            self.assertIn(token, preview)
        for retired in ("DCMObject", "NSTask", "loadDICOMDCMFramework"):
            self.assertNotIn(retired, preview)
        self.assertIn("return [self loadDICOMModernNonImage]", pix)
        self.assertNotIn("loadDICOMDCMFramework", pix)

    def test_transfer_conversion_uses_existing_modern_writer_and_quality(self):
        scu = source("DCMTKStoreSCU.mm")
        conversion = scu.split("static OFBool decompressFile", 1)[1].split("static long seed", 1)[0]
        for retired in ("DCMObject", "DCMTransferSyntax", "useDCMTKForJP2K"):
            self.assertNotIn(retired, conversion)
        self.assertIn("HorosStoreSCUWriteFileInTransferSyntax(fname, outfname, EXS_LittleEndianExplicit, 1)", conversion)
        self.assertIn("HorosStoreSCUWriteFileInTransferSyntax(fname, outfname, opt_networkTransferSyntax, opt_Quality)", conversion)

    def test_retired_import_subclasses_and_empty_presentation_state_stub_are_removed(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("DCMObjectDBImport", "DCMObjectPixelDataImport", "NetworkMoveDataHandler"):
            self.assertNotIn(name, project)
            for suffix in (".h", ".m"):
                self.assertFalse((SOURCES / (name + suffix)).exists())
        self.assertNotIn("DCMObject", source("DICOMExport.h"))
        self.assertNotIn("DCMObject", source("DICOMExport.mm"))
        self.assertNotIn("graphicAnnotationSequence", source("DicomImage.h"))


if __name__ == "__main__":
    unittest.main()
