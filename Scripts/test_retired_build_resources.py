"""Guard obsolete build resource removal without building the application."""

import re
import subprocess
import unittest

from test_macos_baseline import ROOT, project_objects


class RetiredBuildResourceTests(unittest.TestCase):
    def test_obsolete_root_utilities_are_removed(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("LocalizationExtract.sh", "LocalizationGenerate.sh", "README.txt",
                     "To-Do.txt", "ramDiskScript.txt"):
            with self.subTest(name=name):
                self.assertFalse((ROOT / name).exists())
                self.assertNotIn(name, project)

    def test_obsolete_documentation_target_is_removed(self):
        self.assertFalse((ROOT / "Doxyfile-horos").exists())
        schemes = ROOT / "Horos.xcodeproj/xcshareddata/xcschemes"
        self.assertFalse((schemes / "Documentation.xcscheme").exists())
        retired = re.compile(r"Doxyfile-horos|Doxygen\.app|BF7486A50CC6AA5C00198387|"
                             r"BF7486A40CC6AA5C00198387|BF7486AA0CC6AA7C00198387|"
                             r"BF7486A60CC6AA5D00198387|43E98D201A32BF6A001B9E51")
        self.assertNotRegex((ROOT / "Horos.xcodeproj/project.pbxproj").read_text(), retired)
        for path in schemes.glob("*.xcscheme"):
            self.assertNotRegex(path.read_text(), retired, str(path))
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        for obj in objects.values():
            self.assertNotEqual(obj.get("name"), "Documentation")
            if "buildConfigurationList" in obj:
                self.assertIn(obj["buildConfigurationList"], objects)

    def test_unused_archives_and_resource_references_are_removed(self):
        for name in ("PAGES", "Ming"):
            self.assertFalse((ROOT / "Binaries" / f"{name}.zip").exists())
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("PAGES", project)
        self.assertNotIn("Ming", project)
        # Keep ignoring old unpacked directories on other existing checkouts.
        ignored = (ROOT / ".gitignore").read_text()
        self.assertIn("Binaries/PAGES/", ignored)
        self.assertIn("Binaries/Ming/", ignored)

    def test_unpack_script_only_prepares_the_retained_validator(self):
        path = ROOT / "Horos/Scripts/Horos/Unzip.sh"
        script = path.read_text()
        self.assertEqual(re.findall(r"^unzip -uo (.+)$", script, re.M), ["dciodvfy.zip"])
        self.assertNotRegex(script, r"PAGES|Ming|rm ")
        self.assertIn('touch "$DERIVED_FILE_DIR/UnzipBinaries.stamp"', script)
        result = subprocess.run(["/bin/sh", "-n", str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_stays_in_app_resources_and_metadata_action(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        resources = []
        for key in target["buildPhases"]:
            phase = objects[key]
            if phase["isa"] == "PBXResourcesBuildPhase":
                resources += [objects[objects[file]["fileRef"]].get("name") for file in phase["files"]]
        self.assertEqual(resources.count("dciodvfy"), 1)
        self.assertTrue((ROOT / "Binaries/dciodvfy.zip").is_file())
        controller = (ROOT / "Horos/Sources/XMLController.m").read_text()
        self.assertIn('stringByAppendingPathComponent:@"/dciodvfy"', controller)

    def test_unused_pages_database_accessor_is_removed(self):
        for filename in ("DicomDatabase.h", "DicomDatabase.mm"):
            self.assertNotIn("pagesDirPath", (ROOT / "Horos/Sources" / filename).read_text())

    def test_obsolete_disc_launcher_and_build_phase_are_removed(self):
        self.assertFalse(any((ROOT / "Horos Launcher").rglob("*")))
        retired = re.compile(r"Horos Launcher|ZipHorosLauncher|BurnOsirixApplication")
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotRegex(project, retired)
        for path in (ROOT / "Horos").rglob("*"):
            if path.suffix in (".h", ".m", ".mm", ".swift", ".xib", ".sh", ".plist"):
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.assertNotRegex(path.read_text(), retired)

    def test_disc_export_and_metal_launchers_are_retained(self):
        burner = (ROOT / "Horos/Sources/BurnerWindowController.m").read_text()
        self.assertIn("[self addDICOMDIRUsingDCMTK_forFilesAtPaths:newFiles dicomImages:dbObjects]", burner)
        self.assertIn("[self produceHtml: burnFolder dicomObjects: originalDbObjects]", burner)
        estimate = burner.split("- (IBAction) estimateFolderSize:", 1)[1].split("#pragma mark", 1)[0]
        self.assertIn("size += [fattrs fileSize]/1024", estimate)
        self.assertIn("BurnSupplementaryFolder", estimate)
        self.assertIn("getSizeOfDirectory:", estimate)
        self.assertNotRegex(estimate, r"8\s*\*\s*1024")

        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        sources = [objects[objects[file]["fileRef"]]["path"]
                   for key in target["buildPhases"]
                   if objects[key]["isa"] == "PBXSourcesBuildPhase" for file in objects[key]["files"]]
        for name in ("MetalViewerLauncher", "Metal3DViewerLauncher"):
            path = f"Horos/Sources/MetalViewer/{name}.swift"
            self.assertEqual(sources.count(path), 1)
            self.assertTrue((ROOT / path).is_file())

    def test_obsolete_options_and_their_callers_are_removed(self):
        self.assertFalse((ROOT / "Horos/Sources/options.h").exists())
        retired = re.compile(r"options\.h|\b(?:OPTIONS_H_INCLUDED|WITH_IMPORTANT_NOTICE|"
                             r"WITH_OS_VALIDATION|WITH_RED_CAPTION|WITH_CODE_SIGNING|"
                             r"displayImportantNotice)\b")
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        self.assertNotRegex(project, retired)
        for path in (ROOT / "Horos").rglob("*"):
            if path.suffix in (".h", ".m", ".mm", ".swift", ".pch", ".xib"):
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.assertNotRegex(path.read_text(), retired)
        controller = (ROOT / "Horos/Sources/AppController.m").read_text()
        self.assertIn("#ifdef NDEBUG\n    PFMoveToApplicationsFolderIfNecessary();\n#endif", controller)

    def test_active_other_sources_are_retained(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        group = next(obj for obj in objects.values()
                     if obj.get("isa") == "PBXGroup" and obj.get("name") == "Other Sources")
        paths = {objects[key]["path"] for key in group["children"]}
        self.assertEqual(paths, {"Horos/Sources/main.m", "Horos/Sources/url.h"})
        for path in paths:
            self.assertTrue((ROOT / path).is_file(), path)

        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        sources = set()
        for key in target["buildPhases"]:
            phase = objects[key]
            if phase["isa"] == "PBXSourcesBuildPhase":
                sources.update(objects[objects[file]["fileRef"]]["path"] for file in phase["files"])
        self.assertIn("Horos/Sources/main.m", sources)

    def test_keychain_helper_is_retained_with_network_sources(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        group = next(obj for obj in objects.values()
                     if obj.get("isa") == "PBXGroup" and obj.get("name") == "Network")
        paths = {objects[key].get("path") for key in group["children"]}
        retained = {"Horos/Sources/DDKeychain.h", "Horos/Sources/DDKeychain.m",
                    "Horos/Sources/DDKeychain.LICENSE.txt"}
        self.assertTrue(retained <= paths)
        for path in retained:
            self.assertTrue((ROOT / path).is_file(), path)

        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        for phase_type, filename in (("PBXSourcesBuildPhase", "DDKeychain.m"),
                                     ("PBXHeadersBuildPhase", "DDKeychain.h")):
            files = [objects[objects[file]["fileRef"]]["path"]
                     for key in target["buildPhases"]
                     if objects[key]["isa"] == phase_type for file in objects[key]["files"]]
            self.assertEqual(files.count(f"Horos/Sources/{filename}"), 1)

        for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            config = objects[key]
            with self.subTest(configuration=config["name"]):
                self.assertIn("$(PROJECT_DIR)/Horos/Sources",
                              config["buildSettings"]["HEADER_SEARCH_PATHS"])
        for filename in ("DICOMTLS.h", "DCMTKStoreSCU.h", "DCMTKServiceClassUser.h"):
            self.assertIn('#import "DDKeychain.h"', (ROOT / "Horos/Sources" / filename).read_text())

    def test_retired_http_server_directory_and_paths_are_removed(self):
        self.assertFalse(any((ROOT / "cocoahttpserver").rglob("*")))
        self.assertNotIn("cocoahttpserver", (ROOT / "Horos.xcodeproj/project.pbxproj").read_text())
        license_text = (ROOT / "Horos/Sources/DDKeychain.LICENSE.txt").read_text()
        for notice in ("Software License Agreement (BSD License)",
                       "Copyright (c) 2006, Deusty Designs, LLC", "All rights reserved.",
                       "Redistribution and use", "THIS SOFTWARE IS PROVIDED"):
            self.assertIn(notice, license_text)


if __name__ == "__main__":
    unittest.main()
