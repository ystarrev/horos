"""Source/project checks for the staged DCM removal. Does not build or launch Horos."""

import pathlib
import plistlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DCMExtractionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["plutil", "-convert", "xml1", "-o", "-", str(ROOT / "Horos.xcodeproj/project.pbxproj")],
            check=True, capture_output=True,
        )
        cls.project = plistlib.loads(result.stdout)["objects"]

    def target_files(self, target_name, phase_type):
        target = next(obj for obj in self.project.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == target_name)
        files = []
        for phase_id in target["buildPhases"]:
            phase = self.project[phase_id]
            if phase["isa"] == phase_type:
                for build_file_id in phase["files"]:
                    build_file = self.project[build_file_id]
                    reference = self.project[build_file["fileRef"]]
                    files.append(reference.get("path", reference.get("name")))
        return files

    def test_node_service_is_compiled_only_in_horos(self):
        path = "Horos/Sources/DCMNetServiceDelegate.m"
        self.assertEqual(self.target_files("Horos", "PBXSourcesBuildPhase").count(path), 1)
        self.assertNotIn(path, self.target_files("DCM", "PBXSourcesBuildPhase"))
        self.assertTrue((ROOT / path).is_file())
        self.assertFalse((ROOT / "DCM Framework/DCMNetServiceDelegate.m").exists())

    def test_node_header_belongs_to_horos_not_dcm(self):
        path = "Horos/Sources/DCMNetServiceDelegate.h"
        self.assertEqual(self.target_files("Horos", "PBXHeadersBuildPhase").count(path), 1)
        self.assertNotIn(path, self.target_files("DCM", "PBXHeadersBuildPhase"))
        self.assertTrue((ROOT / path).is_file())
        self.assertFalse((ROOT / "DCM Framework/DCMNetServiceDelegate.h").exists())
        self.assertNotIn("DCMNetServiceDelegate", (ROOT / "DCM Framework/DCM.h").read_text())

    def test_callers_import_the_node_service_directly(self):
        usage = re.compile(r"\[DCMNetServiceDelegate\b|\b(?:CMOVE|CGET)RetrieveMode\b")
        for directory in (ROOT / "Horos/Sources", ROOT / "Preference Panes"):
            for path in directory.rglob("*"):
                if path.suffix not in (".m", ".mm"):
                    continue
                source = path.read_text()
                if usage.search(source):
                    with self.subTest(path=str(path.relative_to(ROOT))):
                        self.assertIn('#import "DCMNetServiceDelegate.h"', source)

    def test_existing_node_contract_is_preserved(self):
        header = (ROOT / "Horos/Sources/DCMNetServiceDelegate.h").read_text()
        source = (ROOT / "Horos/Sources/DCMNetServiceDelegate.m").read_text()
        self.assertIn("@interface DCMNetServiceDelegate : NSObject", header)
        self.assertRegex(header, r"CMOVERetrieveMode\s*=\s*0")
        self.assertRegex(header, r"CGETRetrieveMode\s*=\s*1")
        for key in ("DCMNetServicesDidChange", "SERVERS", "searchDICOMBonjour",
                    "HorosDirectTransferVersion", "HorosDirectTransferPort", "HorosDirectTransferToken"):
            self.assertIn('@"' + key + '"', source)

    def test_dcm_file_references_use_the_new_paths(self):
        for reference in self.project.values():
            if reference.get("isa") == "PBXFileReference":
                path = reference.get("path", "")
                self.assertFalse(path.startswith("DCM Framework/DCMNetServiceDelegate"))


if __name__ == "__main__":
    unittest.main()
