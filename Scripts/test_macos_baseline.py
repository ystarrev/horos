"""Source/project checks for macOS 27 cleanup. No build or patient data access."""

from pathlib import Path
import plistlib
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
CONSUMERS = (
    "BrowserControllerDCMTKCategory.mm", "DCMPix.m", "DCMTKStoreSCU.mm",
    "DICOMExport.mm", "DicomDatabase+DCMTK.mm", "DicomFile.mm",
    "DicomFileDCMTKCategory.mm", "DicomImageDCMTKCategory.mm",
    "KeyObjectReport.mm", "MetalViewer/MetalStudyROISegBridge.mm",
    "PreviewView.m", "SRAnnotation.mm", "StructuredReportSupport.m",
    "XMLControllerDCMTKCategory.mm",
)
RETIRED_DATABASE_ACCESSORS = (
    "databaseLastModification", "setDatabaseLastModification",
    "localManagedObjectContext", "localManagedObjectContextIndependentContext",
    "defaultManagerObjectContext", "defaultManagerObjectContextIndependentContext",
    "managedObjectContextIndependentContext", "computeDATABASEINDEXforDatabase",
    "setBonjourDatabaseValue", "localDatabasePath", "setFixedDocumentsDirectory",
    "localDocumentsDirectory", "fixedDocumentsDirectory", "cfixedDocumentsDirectory",
    "cfixedIncomingDirectory", "cfixedTempNoIndexDirectory", "cfixedIncomingNoIndexDirectory",
    "defaultDocumentsDirectory", "TEMPPATH", "currentDatabasePath", "bonjourManagedObjectContext",
)


def project_objects(path):
    data = subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(ROOT / path)])
    return plistlib.loads(data)["objects"]


class MacOSBaselineTests(unittest.TestCase):
    def test_deployment_baseline_and_removed_os_branches(self):
        config = (ROOT / "Config.xcconfig").read_text()
        self.assertRegex(config, r"(?m)^ARCHS\s*=\s*arm64\s*$")
        self.assertRegex(config, r"(?m)^MACOSX_DEPLOYMENT_TARGET\s*=\s*27\.0\s*$")
        obsolete = re.compile(r"(?:#|@)available\(macOS (?:10\.\d+|11\.0),|__LP64__")
        for path in SOURCES.rglob("*"):
            if path.suffix in (".m", ".mm", ".swift"):
                self.assertNotRegex(path.read_text(), obsolete, str(path))
        browser = (SOURCES / "BrowserController.m").read_text()
        self.assertNotIn("_scrollerStyle:", browser)
        self.assertIn("scroller.scrollerStyle != NSScrollerStyleOverlay", browser)
        self.assertIn("verticalScroller.scrollerStyle == NSScrollerStyleOverlay", browser)

    def test_retired_json_has_no_sources_or_project_references(self):
        self.assertFalse(any((ROOT / "Nitrogen/Sources/JSON").glob("*")))
        for project in ("Horos.xcodeproj/project.pbxproj", "Nitrogen/Nitrogen.xcodeproj/project.pbxproj"):
            objects = project_objects(project)
            for obj in objects.values():
                self.assertNotRegex(str(obj), r"SBJSON|SBJson|AGL\.framework")
                self.assertFalse(obj.get("isa") == "PBXGroup" and obj.get("path") == "JSON")
                for key in ("children", "files", "buildPhases", "buildConfigurations", "targets"):
                    for reference in obj.get(key, []):
                        self.assertIn(reference, objects, (project, key, reference))
                if "fileRef" in obj:
                    self.assertIn(obj["fileRef"], objects)
        for directory in (SOURCES, ROOT / "Nitrogen/Sources", ROOT / "Preference Panes"):
            for path in directory.rglob("*"):
                if path.suffix in (".h", ".m", ".mm", ".swift", ".xib"):
                    self.assertNotRegex(path.read_text(), r"\b(?:SBJSON|SBJson\w*|JSONValue|JSONRepresentation)\b")

    def test_loader_is_compiled_once_in_horos(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        owners = []
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] != "PBXSourcesBuildPhase":
                    continue
                for build_id in phase["files"]:
                    path = objects[objects[build_id]["fileRef"]].get("path", "")
                    if path.endswith("HorosDCMTKBridgeLoader.m"):
                        owners.append(target["name"])
        self.assertEqual(owners, ["Horos"])
        parents = {child: key for key, obj in objects.items() for child in obj.get("children", [])}

        def resolved_path(key):
            obj = objects[key]
            parent = ROOT if obj.get("sourceTree") == "SOURCE_ROOT" or key not in parents else resolved_path(parents[key])
            return parent / obj.get("path", "")

        for name in ("HorosDCMTKBridgeLoader.m", "HorosDCMTKBridgeLoader.h"):
            key = next(key for key, obj in objects.items()
                       if obj.get("isa") == "PBXFileReference" and obj.get("path") == name)
            self.assertEqual(resolved_path(key), SOURCES / name)
            self.assertTrue(resolved_path(key).is_file())

    def test_all_dynamic_consumers_use_the_shared_typed_api(self):
        api = (SOURCES / "ModernDCMTKBridge.h").read_text()
        implementation = (SOURCES / "ModernDCMTKBridge.cpp").read_text()
        declarations = set(re.findall(r"\b(HorosModernDCMTK\w+)\s*\(", api))
        for name in CONSUMERS:
            source = (SOURCES / name).read_text()
            with self.subTest(consumer=name):
                self.assertIn('#import "HorosDCMTKBridgeLoader.h"', source)
                functions = re.findall(r"HorosDCMTKFunction\((\w+)\)", source)
                self.assertTrue(functions)
                for function in functions:
                    self.assertIn(function, declarations)
                    self.assertRegex(implementation, r"\b" + function + r"\s*\(")
                self.assertNotRegex(source, r"\b(?:dlopen|dlsym|dlclose)\s*\(")
                self.assertNotRegex(source, r"typedef[^;]*\(\*Horos\w*(?:Fn|Function)\)")
        for path in SOURCES.rglob("*"):
            if path.suffix in (".m", ".mm", ".swift") and path.name != "HorosDCMTKBridgeLoader.m":
                self.assertNotRegex(path.read_text(), r"\b(?:dlopen|dlsym)\s*\(", str(path))

    def test_loader_preserves_locations_lifetime_and_nullable_errors(self):
        source = (SOURCES / "HorosDCMTKBridgeLoader.m").read_text()
        header = (SOURCES / "HorosDCMTKBridgeLoader.h").read_text()
        for location in ("resourcePath", "privateFrameworksPath", "sharedFrameworksPath", "builtInPlugInsPath"):
            self.assertIn("bundle." + location, source)
        self.assertIn('@"DCMTK/libHorosModernDCMTKBridge.dylib"', source)
        self.assertIn('dlopen("libHorosModernDCMTKBridge.dylib", RTLD_LAZY | RTLD_LOCAL)', source)
        self.assertIn("dispatch_once(&onceToken", source)
        self.assertIn("static void *handle = NULL", source)
        self.assertNotIn("dlclose(", source)
        self.assertIn("handle != NULL ? dlsym(handle, name) : NULL", source)
        self.assertIn("name == NULL || name[0] == '\\0'", source)
        self.assertIn('#include "ModernDCMTKBridge.h"', header)
        self.assertIn('extern "C"', header)
        self.assertIn("__typeof__(&(function))", header)
        self.assertIn("HorosDCMTKBridgeSymbol(#function)", header)

    def test_opengl_autolink_suppression_is_not_removed_as_a_dependency(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            settings = objects[key]["buildSettings"]
            flags = settings["OTHER_SWIFT_FLAGS"]
            index = flags.index("OpenGL")
            self.assertEqual(flags[index - 3:index],
                             ["-Xfrontend", "-disable-autolink-framework", "-Xfrontend"])

    def test_retired_defaults_wrapper_and_its_tests_are_removed_from_projects(self):
        for name in ("Sources/N2UserDefaults.h", "Sources/N2UserDefaults.mm",
                     "Unit Tests/N2UserDefaultsTest.h", "Unit Tests/N2UserDefaultsTest.mm"):
            self.assertFalse((ROOT / "Nitrogen" / name).exists(), name)
        for project in ("Horos.xcodeproj/project.pbxproj", "Nitrogen/Nitrogen.xcodeproj/project.pbxproj"):
            self.assertNotIn("N2UserDefaults", (ROOT / project).read_text())
            objects = project_objects(project)
            for obj in objects.values():
                for key in ("children", "files", "buildPhases", "buildConfigurations", "targets"):
                    for reference in obj.get(key, []):
                        self.assertIn(reference, objects, (project, key, reference))
                if "fileRef" in obj:
                    self.assertIn(obj["fileRef"], objects)

    def test_retired_accessors_have_no_source_or_interface_callers(self):
        pattern = re.compile(r"\b(?:N2UserDefaults|" + "|".join(RETIRED_DATABASE_ACCESSORS) + r")\b")
        tracked = subprocess.check_output(
            ["git", "ls-files", "-z", "--", "Horos", "Nitrogen", "Preference Panes"], cwd=ROOT
        ).decode().split("\0")
        for name in tracked:
            path = ROOT / name
            if path.is_file() and path.suffix in (".h", ".m", ".mm", ".swift", ".xib", ".storyboard", ".sdef", ".plist"):
                self.assertNotRegex(path.read_text(errors="replace"), pattern, name)

    def test_browser_keeps_database_object_not_duplicate_context_accessors(self):
        header = (SOURCES / "BrowserController.h").read_text()
        source = (SOURCES / "BrowserController.m").read_text()
        self.assertIn("DicomDatabase* database", header)
        for name in ("managedObjectContext", "managedObjectModel"):
            declaration = r"(?m)^[-+]\s*\([^\n)]*\)\s*" + name + r"\b"
            self.assertNotRegex(header, declaration)
            self.assertNotRegex(source, declaration)
            self.assertIn("self.database." + name, source)

    def test_log_window_preserves_selected_database_and_context(self):
        source = (SOURCES / "LogArrayController.m").read_text()
        self.assertIn('#import "BrowserController.h"', source)
        self.assertIn('#import "DicomDatabase.h"', source)
        self.assertIn("[self setManagedObjectContext:browserWindow.database.managedObjectContext]", source)
        self.assertIn("return browserWindow.database.managedObjectContext", source)
        self.assertIn("[self fetch:nil]", source)
        self.assertNotIn("[browserWindow managedObjectContext]", source)
        self.assertNotRegex(source, r"defaultDatabase|activeLocalDatabase|independentContext")


if __name__ == "__main__":
    unittest.main()
