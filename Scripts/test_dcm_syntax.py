"""Check the DCM-to-DCMTK syntax migration without building or opening DICOM files.

The fixture records the old public identifiers and display policy, with two
explicitly documented corrections. Runtime tests live in tests/DCMSyntaxTests.mm.
"""

import json
import re
import unittest

import test_dcm_extraction

ROOT = test_dcm_extraction.ROOT


class DCMSyntaxTests(test_dcm_extraction.DCMExtractionTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.baseline = json.loads((ROOT / "Scripts/tests/dcm_syntax_baseline.json").read_text())
        cls.uid_source = (ROOT / "Horos/Sources/DCMAbstractSyntaxUID.mm").read_text()
        cls.transfer_source = (ROOT / "Horos/Sources/DCMTransferSyntax.mm").read_text()
        header = (ROOT / "DCMTK/dcmdata/include/dcmtk/dcmdata/dcuid.h").read_text()
        cls.macros = dict(re.findall(r'^#define (UID_\w+)\s+"([^"]+)"', header, re.M))
        cls.constants = {}
        for name, expression in re.findall(
                r'static NSString \* const (\w+) = @([^;]+);', cls.uid_source):
            cls.constants[name] = (expression.strip('"') if expression.startswith('"')
                                   else cls.macros[expression])

    def test_public_uid_values(self):
        actual = {selector: self.constants[name] for selector, name in re.findall(
            r'\+\s*\(NSString\s*\*\)\s*(\w+)\s*\{\s*return\s+(\w+);', self.uid_source)}
        self.assertEqual(actual, self.baseline["getters"])

    def test_display_categories_are_unchanged(self):
        for name, expected in self.baseline["arrays"].items():
            with self.subTest(category=name):
                match = re.search(r'\+\s*\(NSArray\s*\*\)\s*' + name
                                  + r'\s*\{[\s\S]*?\[NSArray arrayWithObjects:([\s\S]*?),\s*nil\]',
                                  self.uid_source)
                self.assertIsNotNone(match)
                self.assertEqual([self.constants[item.strip()] for item in match[1].split(",")], expected)

    def test_factories_keep_their_transfer_uids(self):
        actual = {selector: self.macros[name] for selector, name in re.findall(
            r'\+\s*\(id\)\s*(\w+)\s*\{\s*return.*?initWithTS:@(UID_\w+)\]', self.transfer_source)}
        self.assertEqual(actual, self.baseline["transferFactories"])

    def test_dcmtk_flags_match_legacy_encodings(self):
        table = (ROOT / "DCMTK/dcmdata/libsrc/dcxfer.cc").read_text()
        entries = re.findall(r'\{\s*(UID_\w+),\s*"[^"]+",\s*EXS_\w+,\s*'
                             r'(EBO_\w+),\s*EBO_\w+,\s*(EVT_\w+),\s*(EPE_\w+)', table)
        flags = {self.macros[uid]: {
            "uid": self.macros[uid], "encapsulated": encoding == "EPE_Encapsulated",
            "littleEndian": endian == "EBO_LittleEndian", "explicitVR": vr == "EVT_Explicit"
        } for uid, endian, vr, encoding in entries}
        for expected in self.baseline["transferSyntaxes"]:
            with self.subTest(uid=expected["uid"]):
                self.assertEqual(flags[expected["uid"]], expected)
        for call in ("syntax.usesEncapsulatedFormat()", "syntax.isLittleEndian()", "syntax.isExplicitVR()"):
            self.assertIn(call, self.transfer_source)
        self.assertNotIn("gTransferSyntaxes", self.transfer_source)

    def test_cpp_helpers_are_in_the_existing_target_once(self):
        sources = self.target_files("Horos", "PBXSourcesBuildPhase")
        for name in ("DCMAbstractSyntaxUID", "DCMTransferSyntax"):
            path = "Horos/Sources/" + name + ".mm"
            self.assertEqual(sources.count(path), 1)
            self.assertNotIn(path[:-1], sources)
            self.assertFalse((ROOT / path[:-1]).exists())
            reference = next(obj for obj in self.project.values()
                             if obj.get("isa") == "PBXFileReference" and obj.get("path") == path)
            self.assertEqual(reference["lastKnownFileType"], "sourcecode.cpp.objcpp")


if __name__ == "__main__":
    unittest.main()
