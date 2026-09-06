"""Check dictionary compatibility and packaging without building or opening DICOM files.

The text parser here models dictionary metadata for source regression tests only.
Production uses DCMTK's DcmDataDictionary, exercised by tests/DCMTagTests.mm.
"""

import json
import re
import unittest

import test_dcm_extraction

ROOT = test_dcm_extraction.ROOT


def toolkit_entries():
    normal, repeating = [], []
    for line in (ROOT / "DCMTK/dcmdata/data/dicom.dic").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        tag, vr, name, vm, _ = line.split()
        group, element = tag.strip("()").split(",")
        key = group.split("-")[0] + "," + element.split("-")[0]
        info = {
            "Description": name,
            "VR": {"px": "ox", "xs": "US/SS", "lt": "US/SS/OW", "up": "UL"}.get(vr, vr),
            "VM": re.sub(r"-\d+n$", "-n", vm),
        }
        (repeating if "-" in tag else normal).append((key.upper(), info))
    return normal + repeating


class DCMTagTests(test_dcm_extraction.DCMExtractionTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.compatibility = json.loads((ROOT / "Horos/Resources/DCMTagDictionaryCompatibility.json").read_text())
        cls.baseline = {}
        for line in (ROOT / "Scripts/tests/dcm_tags_baseline.tsv").read_text().splitlines():
            if line.startswith("#"):
                continue
            tag, name, vr, vm = line.split("\t")
            cls.baseline[tag] = {"Description": name, "VR": vr, "VM": vm}
        cls.tags, cls.names = {}, {}
        for key, info in toolkit_entries():
            cls.tags.setdefault(key, info.copy())
            cls.names[info["Description"]] = key
        for key, overrides in cls.compatibility["Tags"].items():
            cls.tags.setdefault(key, {}).update(overrides)
        for key in sorted(cls.tags):
            cls.names[cls.tags[key]["Description"]] = key
        cls.names.update(cls.compatibility["Aliases"])

    def test_all_legacy_tag_metadata_is_preserved(self):
        self.assertEqual(len(self.baseline), 3672)
        for key, expected in self.baseline.items():
            with self.subTest(tag=key):
                self.assertEqual(self.tags[key], expected)

    def test_legacy_names_and_ambiguous_aliases_are_preserved(self):
        expected = {info["Description"]: key for key, info in sorted(self.baseline.items())}
        expected.update({"ReferencedPrintJobSequence": "2100,0500", "TM-LinePosition": "0018,603D"})
        for name, key in expected.items():
            with self.subTest(name=name):
                self.assertEqual(self.names[name], key)

    def test_current_keywords_and_legacy_keywords_are_both_available(self):
        for old, current, tag in (
            ("PatientsName", "PatientName", "0010,0010"),
            ("PatientsBirthDate", "PatientBirthDate", "0010,0030"),
            ("PatientsSex", "PatientSex", "0010,0040"),
        ):
            self.assertEqual(self.names[old], tag)
            self.assertEqual(self.names[current], tag)
        self.assertEqual(self.names["SegmentationType"], "0062,0001")

    def test_overrides_are_compact_and_contain_valid_tags(self):
        self.assertLess(len(self.compatibility["Tags"]), len(self.baseline) // 4)
        for key, info in self.compatibility["Tags"].items():
            self.assertRegex(key, r"^[0-9A-F]{4},[0-9A-F]{4}$")
            self.assertTrue(info.keys() <= {"Description", "VR", "VM"})
        self.assertEqual(self.names["CurveDescription14"], "5014,0022")
        self.assertNotIn("GenericGroupLengthToEnd", self.names)
        self.assertEqual(self.names["IllegalPrivateCreator"], "0001,0010")
        self.assertEqual(self.tags["7053,1000"]["VR"], "DS")

    def test_old_dictionary_resources_are_removed(self):
        projects = list(ROOT.rglob("*.xcodeproj/project.pbxproj"))
        for name in ("nameDictionary.plist", "tagDictionary.plist"):
            self.assertFalse((ROOT / "DCM Framework" / name).exists())
            for project in projects:
                self.assertNotIn(name, project.read_text(), str(project.relative_to(ROOT)))
        resources = self.target_files("Horos", "PBXResourcesBuildPhase")
        self.assertEqual(resources.count("Horos/Resources/DCMTagDictionaryCompatibility.json"), 1)
        self.assertEqual(resources.count("DCMTK/dicom.dic"), 1)
        self.assertEqual(self.target_files("Horos", "PBXResourcesBuildPhase").count("DCMTK/dicom.dic"), 1)

    def test_dictionary_implementation_is_owned_by_horos(self):
        source = "Horos/Sources/DCMTagDictionary.mm"
        self.assertEqual(self.target_files("Horos", "PBXSourcesBuildPhase").count(source), 1)
        self.assertFalse((ROOT / source[:-1]).exists())
        reference = next(obj for obj in self.project.values() if obj.get("path") == source)
        self.assertEqual(reference["lastKnownFileType"], "sourcecode.cpp.objcpp")


if __name__ == "__main__":
    unittest.main()
