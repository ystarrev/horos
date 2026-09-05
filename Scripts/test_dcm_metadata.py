"""Metadata migration source/fixture checks. Does not build or run the reader."""

import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

from test_dcm_extraction import DCMExtractionTests

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


class DCMMetadataTests(DCMExtractionTests):
    def test_controller_no_longer_uses_legacy_parser(self):
        for filename in ("XMLController.m", "XMLController.h"):
            source = (SOURCES / filename).read_text()
            self.assertNotRegex(source, r"\b(?:DCMObject|DCMAttribute|dcmDocument)\b")
        source = (SOURCES / "XMLController.m").read_text()
        self.assertIn("metadataDocumentForFile:srcFile", source)
        self.assertIn("getNIfTIXML:srcFile", source)
        self.assertIn("HorosDICOMMetadataText(xmlDocument)", source)
        self.assertIn("HorosMetadataItemIsReadOnly(item)", source)

    def test_reader_is_single_load_read_only_and_has_no_binary_output(self):
        source = (SOURCES / "ModernDCMTKBridge.cpp").read_text()
        reader = source.split("char* HorosModernDCMTKCopyMetadataXML(", 1)[1].split(
            "char* HorosModernDCMTKCopyField(", 1)[0]
        self.assertEqual(reader.count(".loadFile("), 1)
        self.assertIn("file.writeXML(output, 0)", reader)
        self.assertIn("convertToUTF8()", reader)
        self.assertIn("charset.value.c_str()", reader)
        self.assertIn("findAndDeleteElement(DCM_SpecificCharacterSet", reader)
        for call in ("saveFile(", "chooseRepresentation(", "CopyDecodedFrame("):
            self.assertNotIn(call, reader)
        preparation = source.split("static OFCondition HorosModernDCMTKPrepareMetadataXML", 1)[1].split(
            "char* HorosModernDCMTKCopyMetadataXML", 1)[0]
        for vr in ("OB", "OW", "OF", "OD", "OL", "OV", "UN"):
            self.assertIn("case EVR_" + vr + ":", preparation)
        self.assertIn("element->ident() == EVR_SQ", preparation)
        self.assertIn("depth > 128", preparation)

    def test_editing_warning_distinguishes_preference_from_window_toggle(self):
        source = (SOURCES / "XMLController.m").read_text()
        setter = source.split("- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:", 1)[1].split(
            "- (IBAction) validatorWebSite:", 1)[0]
        self.assertIn("DICOM editing is disabled in Settings.", setter)
        self.assertIn("DICOM editing is allowed in Settings, but is not enabled for this window.", setter)
        self.assertIn("Click Edit in the Meta-Data toolbar, just left of Add", setter)
        self.assertNotIn("Activate DICOM editing to change the values.", setter)
        self.assertIn("isDICOM && self.editingActivated", setter)
        xib = ET.parse(ROOT / "Horos/Resources/Base.lproj/XMLViewer.xib")
        button = xib.find(".//button[@id='54']")
        self.assertIn("in this window", button.attrib["toolTip"])
        self.assertEqual(button.find("connections/action").attrib["selector"], "switchEditing:")

    def test_metadata_edit_snapshots_dates_before_reimport_and_keeps_them_when_regrouping(self):
        source = (SOURCES / "XMLController.m").read_text()
        update = source.split("- (NSArray*) updateDB:", 1)[1].split("- (IBAction) executeAdd:", 1)[0]
        self.assertIn("N2PerformManagedObjectContextBlockAndWait", update)
        self.assertIn("image.completePath.stringByStandardizingPath", update)
        self.assertIn('setObject:image.series.dateAdded forKey:@"series"', update)
        self.assertIn('setObject:image.series.study.dateAdded forKey:@"study"', update)
        self.assertLess(update.index("for (DicomImage *image in objects)"),
                        update.index("rereadFilesAtPaths:files originalDatesAdded:originalDatesAdded"))
        self.assertIn("[self updateDB:files objects:nil originalDatesAdded:originalDatesAdded]", update)
        self.assertNotIn("addFilesAtPaths:", update)

    def test_date_preservation_is_opt_in_not_all_rereads(self):
        source = (SOURCES / "DicomDatabase.mm").read_text()
        path_import = source.split("-(NSArray*)addFilesAtPaths:")[-1].split("-(NSArray*)rereadFilesAtPaths:", 1)[0]
        dictionary_import = source.split("-(NSArray*)addFilesDescribedInDictionaries:")[-1].split(
            "-(NSArray*)addFilesDescribedInDictionariesOnContextQueue:", 1)[0]
        for normal_import in (path_import, dictionary_import):
            self.assertIn("originalDatesAdded:nil", normal_import)
        metadata_import = source.split("-(NSArray*)rereadFilesAtPaths:", 1)[1].split(
            "-(NSArray*)addFilesAtPathsOnContextQueue:", 1)[0]
        for option in ("N2PerformManagedObjectContextBlockAndWait", "rereadExistingItems:YES",
                       "importedFiles:NO", "returnArray:YES", "originalDatesAdded:originalDatesAdded ?: @{}"):
            self.assertIn(option, metadata_import)
        path_parser = source.split("-(NSArray*)addFilesAtPathsOnContextQueue:", 1)[1].split(
            "-(NSArray*)addFilesDescribedInDictionaries:", 1)[0]
        self.assertIn("addFilesDescribedInDictionariesOnContextQueue:dicomFilesArray", path_parser)
        self.assertIn("originalDatesAdded:originalDatesAdded", path_parser)

    def test_importer_preserves_existing_dates_and_inherits_dates_for_new_groups(self):
        source = (SOURCES / "DicomDatabase.mm").read_text()
        importer = source.split("-(NSArray*)addFilesDescribedInDictionariesOnContextQueue:", 1)[1]
        importer = importer.split("[self.managedObjectContext save:NULL]", 1)[0]
        self.assertIn("objectForKey:newFile.stringByStandardizingPath", importer)
        self.assertIn('study.dateAdded = sourceDates ? [sourceDates objectForKey:@"study"] : today;', importer)
        self.assertIn('setValue:sourceDates ? [sourceDates objectForKey:@"series"] : today forKey:@"dateAdded"', importer)
        self.assertRegex(importer, r"if \(originalDatesAdded == nil\)\s+tstudy.dateAdded = today;")
        date_reset = (r"if \(DICOMSR == NO && originalDatesAdded == nil\)\s*\{\s*"
                      r'\[seriesTable setValue:today forKey:@"dateAdded"\];\s*study.dateAdded = today;')
        self.assertEqual(len(re.findall(date_reset, importer)), 2)
        # Cover every date assignment, including the duplicate-image path and empty-study placeholder.
        self.assertEqual(len(re.findall(r'\.dateAdded =|forKey:@"dateAdded"', importer)), 7)

    def test_adapter_uses_xml_parser_and_preserves_multivalue_semantics(self):
        source = (SOURCES / "HorosDICOMMetadata.m").read_text()
        self.assertIn("NSXMLNodeLoadExternalEntitiesNever", source)
        self.assertIn("source.DTD == nil", source)
        self.assertIn('attributeForName:@"vm"', source)
        self.assertIn('integerValue] > 1', source)
        self.assertIn('@"readOnly"', source)
        self.assertIn('@"DICOMObject"', source)
        self.assertIn('@"item"', source)
        self.assertIn('@"number"', source)
        self.assertNotIn("DCMObject", source)

    def test_bridge_and_adapter_are_wired_into_existing_targets(self):
        files = self.target_files("Horos", "PBXSourcesBuildPhase")
        self.assertEqual(files.count("HorosDICOMMetadata.m"), 1)
        self.assertNotIn("HorosDICOMMetadata.m", self.target_files("DCM", "PBXSourcesBuildPhase"))
        header = (SOURCES / "ModernDCMTKBridge.h").read_text()
        self.assertIn("char* HorosModernDCMTKCopyMetadataXML(const char* path, char** failureReason)", header)
        category = (SOURCES / "XMLControllerDCMTKCategory.mm").read_text()
        self.assertIn('"HorosModernDCMTKCopyMetadataXML"', category)
        self.assertIn("freeString(xml)", category)
        self.assertIn("freeString(failure)", category)
        self.assertIn("HorosDICOMMetadataDocument(xmlString, error)", category)

    def test_fixture_covers_dates_charsets_private_tags_and_sequences(self):
        root = ET.parse(ROOT / "Scripts/tests/dcm_metadata_baseline.xml").getroot()
        elements = {node.attrib["tag"]: node for node in root.iter("element")}
        self.assertEqual(elements["0008,0020"].text, "20260228")
        self.assertEqual(elements["0008,0030"].text, "000000.123456")
        self.assertTrue(elements["0008,002a"].text.endswith("-0700"))
        self.assertIn("J\u00e9r\u00f4me & Example", elements["0010,0010"].text)
        self.assertEqual(elements["0020,0032"].text.split("\\"), ["1.25", "-2.5", "0"])
        self.assertIn("literal \\ slash <tag>\n", elements["0040,a160"].text)
        self.assertEqual(elements["0040,a160"].attrib["vm"], "1")
        self.assertEqual(elements["0071,1001"].text, "text")
        self.assertIsNotNone(root.find(".//sequence/item/sequence/item/element"))
        self.assertEqual(len(root.findall(".//pixel-item")), 2)
        self.assertEqual(elements["0042,0011"].attrib["binary"], "hidden")


if __name__ == "__main__":
    unittest.main()
