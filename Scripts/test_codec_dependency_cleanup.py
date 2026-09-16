"""Non-build guards for removing unused standalone codec dependencies."""

import configparser
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET

from test_macos_baseline import ROOT, project_objects


class CodecDependencyCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.objects = project_objects("Horos.xcodeproj/project.pbxproj")

    def test_removed_targets_proxies_settings_and_scripts_are_absent(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("Grok", project)
        self.assertNotIn("CharLS", project)  # Lowercase dcmtkcharls must remain.
        for name in ("Grok", "CharLS"):
            self.assertFalse((ROOT / "Horos/Scripts" / name).exists())
        self.assertFalse((ROOT / "Horos/Scripts/DCMTK/Patches").exists())

    def test_no_dangling_target_dependencies_or_project_attributes(self):
        for obj in self.objects.values():
            for key in ("buildPhases", "dependencies", "targets", "buildConfigurations"):
                for reference in obj.get(key, []):
                    self.assertIn(reference, self.objects)
            for key in ("target", "targetProxy", "remoteGlobalIDString", "buildConfigurationList"):
                if key in obj:
                    self.assertIn(obj[key], self.objects)
            for target in obj.get("attributes", {}).get("TargetAttributes", {}):
                self.assertIn(target, self.objects)

    def test_submodule_manifest_and_gitlinks_no_longer_track_unused_codecs(self):
        config = configparser.ConfigParser()
        config.read(ROOT / ".gitmodules")
        for name in ("Grok", "CharLS"):
            self.assertFalse(config.has_section(f'submodule "{name}"'))
        for name in ("DCMTK", "GDCM", "OpenJPEG", "OpenSSL"):
            self.assertEqual(config[f'submodule "{name}"']["path"], name)
        tracked = subprocess.check_output(
            ["git", "ls-files", "--stage", "--", "Grok", "CharLS"], cwd=ROOT, text=True
        )
        self.assertEqual(tracked, "")

    def test_schemes_do_not_refer_to_the_removed_targets(self):
        retired = {"71A5230E2021D1B60065793A", "9920CBEC202A0BA600FE0A2A"}
        for path in (ROOT / "Horos.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"):
            for reference in ET.parse(path).iter("BuildableReference"):
                self.assertNotIn(reference.get("BlueprintIdentifier"), retired)

    def test_actual_jpeg_ls_and_jpeg2000_libraries_stay_linked(self):
        target = next(obj for obj in self.objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        configs = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        for key in configs:
            settings = self.objects[key]["buildSettings"]
            flags = settings["OTHER_LDFLAGS"]
            for flag in ("-ldcmjpls", "-ldcmtkcharls", "-lGDCM", "-lssl", "-lcrypto",
                         "$(CONFIGURATION_TEMP_DIR)/OpenJPEG.build/Install/lib/libopenjp2.a"):
                self.assertEqual(flags.count(flag), 1)
            self.assertNotIn("-lCharLS", flags)
        dependencies = {self.objects[self.objects[key]["target"]]["name"]
                        for key in target["dependencies"]}
        self.assertTrue({"DCMTK", "GDCM", "OpenSSL"}.issubset(dependencies))
        for name in ("DCMTK", "GDCM"):
            codec = next(obj for obj in self.objects.values() if obj.get("name") == name
                         and obj.get("isa") == "PBXAggregateTarget")
            self.assertIn("OpenJPEG", {self.objects[self.objects[key]["target"]]["name"]
                                       for key in codec["dependencies"]})

    def test_jpeg_ls_is_supplied_by_bundled_toolkit_codecs(self):
        script = (ROOT / "Horos/Scripts/GDCM/CMake.sh").read_text()
        self.assertIn("args+=(-DGDCM_USE_SYSTEM_CHARLS=OFF)", script)
        self.assertNotIn("-DGDCM_USE_SYSTEM_CHARLS=ON", script)
        dcmtk = (ROOT / "DCMTK/dcmjpls/libsrc/CMakeLists.txt").read_text()
        self.assertRegex(dcmtk, r"DCMTK_TARGET_LINK_MODULES\(dcmjpls[^)]*\bdcmtkcharls\)")
        gdcm = (ROOT / "GDCM/Utilities/CMakeLists.txt").read_text()
        self.assertIn("if(NOT GDCM_USE_SYSTEM_CHARLS)", gdcm)
        self.assertIn("add_subdirectory(gdcmcharls)", gdcm)
        bridge = (ROOT / "Horos/Sources/ModernDCMTKBridge.cpp").read_text()
        for registration in ("DJLSDecoderRegistration", "DJLSEncoderRegistration"):
            self.assertIn(f"{registration}::registerCodecs();", bridge)
        make = (ROOT / "Horos/Scripts/DCMTK/Make.sh").read_text()
        self.assertIn("$(pick_lib dcmtkcharls || true)", make)
        self.assertIn('bridge_link_args+=("${dcmtkcharls_lib}")', make)

    def test_application_does_not_call_standalone_codec_apis(self):
        retired = re.compile(r'\b(?:grk_[A-Za-z0-9_]+|charls_jpegls_[A-Za-z0-9_]+)\s*\('
                             r'|\bJpegLs(?:Encode|Decode|ReadHeader|DecodeRect|VerifyEncode)\s*\('
                             r'|#\s*(?:include|import)\s*[<"](?:charls/|grok)')
        for path in (ROOT / "Horos/Sources").rglob("*"):
            if path.suffix in (".h", ".m", ".mm", ".cpp", ".swift"):
                self.assertNotRegex(path.read_text(), retired, str(path.relative_to(ROOT)))

    def test_about_and_license_no_longer_claim_grok_is_shipped(self):
        self.assertNotIn("Grok", (ROOT / "Binaries/Splash/about.html").read_text())
        license_text = (ROOT / "LICENSE").read_text()
        self.assertNotIn("Grok", license_text)
        self.assertIn("GNU Lesser General Public License", license_text)

    def test_retained_dependency_script_parses_without_running_it(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(ROOT / "Horos/Scripts/GDCM/CMake.sh")],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
