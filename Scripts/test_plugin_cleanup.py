"""Check retired plugin scaffolding without building or opening patient data."""

from pathlib import Path
import plistlib
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
CLEANUP = ROOT / "Horos/Scripts/Horos/RemoveRetiredFrameworks.sh"
RETIRED_FRAMEWORKS = ("DCM", "Horos", "HorosAPI", "OsiriXAPI", "OsiriX Headers", "HorosDCM")


class PluginCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        data = subprocess.check_output([
            "plutil", "-convert", "xml1", "-o", "-",
            str(ROOT / "Horos.xcodeproj/project.pbxproj"),
        ])
        cls.objects = plistlib.loads(data)["objects"]

    def test_api_target_and_framework_packaging_are_removed(self):
        for obj in self.objects.values():
            self.assertFalse(obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "API")
            self.assertNotIn(obj.get("path"), [f"{name}.framework" for name in RETIRED_FRAMEWORKS])
        for path in ("API/HorosAPI.m", "API/Info.plist", "Horos/Scripts/Horos/API.sh",
                     "Horos/Scripts/Horos/API-Headers.pl",
                     "Horos.xcodeproj/xcshareddata/xcschemes/Horos API.xcscheme"):
            self.assertFalse((ROOT / path).exists(), path)

        target = next(obj for obj in self.objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        phases = [self.objects[key] for key in target["buildPhases"]]
        names = [phase.get("name") for phase in phases]
        self.assertNotIn("Copy Horos Framework", names)
        self.assertNotIn("API", names)

    def test_transitional_framework_cleanup_is_removed(self):
        self.assertFalse(CLEANUP.exists())
        for obj in self.objects.values():
            self.assertNotEqual(obj.get("name"), "Remove Retired Frameworks")
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("RemoveRetiredFrameworks.sh", project)
        self.assertNotIn("59F69A4E1056328D008585F5", project)

    def test_unused_plugin_hooks_have_no_remaining_callers(self):
        retired = re.compile(r"\b(?:setRoiView|isLUT12Bit|LUT12toRGB|canDisplay12Bit|"
                             r"setCanDisplay12Bit|set12BitInvocation|fill12BitBufferInvocation|"
                             r"is12bitPluginAvailable|automatic12BitTotoku|BlendingPlugin|"
                             r"OsirixRightMouse(?:Up|Down|Dragged)Notification|"
                             r"OsirixDraw(?:Objects|TextInfo)Notification)\b")
        for directory in ("Horos/Sources", "Preference Panes", "Nitrogen/Sources"):
            for path in (ROOT / directory).rglob("*"):
                if path.suffix in (".h", ".m", ".mm", ".swift", ".xib"):
                    with self.subTest(path=str(path.relative_to(ROOT))):
                        self.assertNotRegex(path.read_text(), retired)
        roi = (ROOT / "Horos/Sources/ROI.h").read_text()
        self.assertRegex(roi, r"@property[^;]+\bcurView\s*;")
        blending = (ROOT / "Horos/Sources/OSIWindowController.h").read_text()
        self.assertIn("BlendingFusion = 1", blending)

    def test_annotation_and_display_controls_are_removed(self):
        settings = (ROOT / "Horos/Sources/HorosSettingsWindowController.swift").read_text()
        self.assertNotIn('"Plugin"', settings)
        # Old saved layouts must not display the retired token as literal text.
        preview = (ROOT / "Horos/Sources/PreviewView.m").read_text()
        self.assertRegex(preview, r'isEqualToString:@"Plugin"\]\)\s*\{\s*//[^\n]+\n\s*\}')
        path = ROOT / "Preference Panes/OSIViewerPreferencePane/Base.lproj/OSIViewerPreferencePanePref.xib"
        tree = ET.parse(path)
        removed = {"390", "391", "399", "394", "443"}
        for element in tree.iter():
            self.assertNotIn(element.get("id"), removed)
            for key in ("destination", "firstItem", "secondItem", "previousBinding"):
                self.assertNotIn(element.get(key), removed)

    def test_required_internal_bundle_loading_is_retained(self):
        loader = (ROOT / "Horos/Sources/HorosDCMTKBridgeLoader.m").read_text()
        self.assertIn("bundle.builtInPlugInsPath", loader)
        for name in ("DCMPix.m", "PreviewView.m", "DicomFileDCMTKCategory.mm",
                     "DicomImageDCMTKCategory.mm", "XMLControllerDCMTKCategory.mm",
                     "SRAnnotation.mm", "KeyObjectReport.mm", "DICOMExport.mm"):
            self.assertIn('#import "HorosDCMTKBridgeLoader.h"',
                          (ROOT / "Horos/Sources" / name).read_text())
        preferences = (ROOT / "Horos/Sources/PreferencesWindowController.mm").read_text()
        self.assertIn("prefPane", preferences)
        self.assertIn("principalClass", preferences)


if __name__ == "__main__":
    unittest.main()
