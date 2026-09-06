"""Guard the final DCM removal without building or opening patient data."""

import re
import unittest

from test_dcm_extraction import DCMExtractionTests, ROOT


class DCMRemovalTests(DCMExtractionTests):
    def test_no_framework_target_link_or_embed(self):
        self.assertFalse((ROOT / "DCM Framework/DCM.h").exists())
        self.assertFalse((ROOT / "DicomImporter/GetMetadataForFile.m").exists())
        for obj in self.project.values():
            self.assertFalse(obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "DCM")
            self.assertNotEqual(obj.get("path"), "DCM.framework")
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("DCM Framework", project)
        self.assertNotIn("/DCM\\\\ Framework", project)
        self.assertFalse((ROOT / "Horos.xcodeproj/xcshareddata/xcschemes/Horos DCM.xcscheme").exists())

    def test_project_references_are_resolvable(self):
        reference_keys = {"children", "files", "buildPhases", "dependencies", "targets",
                          "buildConfigurations", "fileRef", "target", "targetProxy",
                          "buildConfigurationList", "productReference", "mainGroup",
                          "productRefGroup", "containerPortal", "remoteGlobalIDString"}
        for object_id, obj in self.project.items():
            for key in reference_keys & obj.keys():
                values = obj[key] if isinstance(obj[key], list) else [obj[key]]
                for value in values:
                    with self.subTest(object=object_id, key=key, value=value):
                        self.assertIn(value, self.project)

    def test_compatibility_classes_and_resources_are_in_horos_once(self):
        sources = self.target_files("Horos", "PBXSourcesBuildPhase")
        headers = self.target_files("Horos", "PBXHeadersBuildPhase")
        for name, suffix in (("DCMAbstractSyntaxUID", "mm"), ("DCMTransferSyntax", "mm"),
                             ("DCMCalendarDate", "mm"), ("DCMAttributeTag", "m"),
                             ("DCMTagDictionary", "mm"), ("DCMTagForNameDictionary", "m")):
            self.assertEqual(sources.count(f"Horos/Sources/{name}.{suffix}"), 1)
            self.assertEqual(headers.count(f"Horos/Sources/{name}.h"), 1)
        resources = self.target_files("Horos", "PBXResourcesBuildPhase")
        self.assertEqual(resources.count("Horos/Resources/DCMTagDictionaryCompatibility.json"), 1)
        self.assertEqual(resources.count("DCMTK/dicom.dic"), 1)

    def test_application_has_no_legacy_parser_references(self):
        retired = re.compile(r'\b(?:DCMObject|DCMLimitedObject|DCMAttribute|DCMDataContainer|'
                             r'DCMPixelDataAttribute|DCMSequenceAttribute|DCMLink|'
                             r'DCMJPEGCodecBridge|DCMDecodeJPEGFrame|'
                             r'loadDICOMDCMFramework|warnAboutLegacyDCMImageLoader)\b')
        for directory in ("Horos", "Nitrogen/Sources", "Preference Panes"):
            for path in (ROOT / directory).rglob("*"):
                if path.suffix not in (".h", ".m", ".mm", ".swift"):
                    continue
                source = path.read_text()
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.assertNotRegex(source, retired)
                    self.assertNotIn('#import "DCM.h"', source)

    def test_swift_jpeg_codec_is_wired_into_horos(self):
        bridge = ROOT / "Horos/Horos-Bridging-Header.h"
        imports = re.findall(r'^#import "([^"]+)"', bridge.read_text(), re.MULTILINE)
        self.assertIn("Sources/HorosJPEGCodecBridge.h", imports)
        search_paths = (bridge.parent, ROOT / "Horos/Sources", ROOT / "Nitrogen/Sources")
        for header in imports:
            with self.subTest(header=header):
                self.assertTrue(any((directory / header).is_file() for directory in search_paths))
        self.assertEqual(self.target_files("Horos", "PBXSourcesBuildPhase").count(
            "HorosJPEGCodecBridge.mm"), 1)
        header = (ROOT / "Horos/Sources/HorosJPEGCodecBridge.h").read_text()
        codec = (ROOT / "Horos/Sources/HorosJPEGCodecBridge.mm").read_text()
        reader = (ROOT / "Horos/Sources/MetalViewer/SwiftDICOMReader.swift").read_text()
        for source in (header, codec, reader):
            self.assertIn("HorosDecodeJPEGFrame(", source)
        self.assertIn("<dcmtk/dcmjpeg/djdecode.h>", codec)
        self.assertIn("datasetPixelData->getUncompressedFrame(", codec)

    def test_horos_links_the_actual_openjpeg_archive_in_each_configuration(self):
        target = next(obj for obj in self.project.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        configurations = self.project[target["buildConfigurationList"]]["buildConfigurations"]
        for configuration_id in configurations:
            configuration = self.project[configuration_id]
            flags = configuration["buildSettings"]["OTHER_LDFLAGS"]
            with self.subTest(configuration=configuration["name"]):
                # Grok also installs libopenjp2.a, but with a different exported API.
                self.assertEqual(flags.count(
                    "$(CONFIGURATION_TEMP_DIR)/OpenJPEG.build/Install/lib/libopenjp2.a"), 1)
                self.assertNotIn("-lopenjp2", flags)

    def test_decoder_has_one_modern_path_and_preserves_annotations(self):
        pix = (ROOT / "Horos/Sources/DCMPix.m").read_text()
        loader = pix.split("- (void) CheckLoadIn", 1)[1].split("- (", 1)[0]
        self.assertEqual(loader.count("success = [self loadDICOMModernDCMTK]"), 1)
        for removed in ("loadDICOMPapyrus", "clearCachedDCMFrameworkFiles", "purgeCacheLock"):
            self.assertNotIn(removed, pix)
        self.assertIn("HorosModernDCMTKCopyFieldByTag", pix)
        self.assertIn("- (void)loadCustomImageAnnotations", pix)
        preview = (ROOT / "Horos/Sources/PreviewView.m").read_text()
        self.assertIn("[pix loadCustomImageAnnotations]", preview)

    def test_predicate_vr_codes_keep_their_saved_values(self):
        editor = (ROOT / "Horos/Sources/O2DicomPredicateEditorView.m").read_text()
        values = re.findall(r"O2([A-Z]{2}) = (0x[0-9A-F]+)", editor)
        self.assertEqual(len(values), 27)
        for name, value in values:
            self.assertEqual(int(value, 16), int.from_bytes(name.encode("ascii"), "big"))


if __name__ == "__main__":
    unittest.main()
