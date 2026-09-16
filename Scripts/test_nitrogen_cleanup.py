"""Verify Nitrogen pruning and navigator organization without building Horos."""

from collections import Counter
from pathlib import Path
import re
import subprocess
import unittest

from test_macos_baseline import ROOT, project_objects


PROJECTS = ("Horos.xcodeproj/project.pbxproj",
            "Nitrogen/Nitrogen.xcodeproj/project.pbxproj")
RETIRED = ("N2CSV", "N2Pair", "N2SingletonObject", "N2Task", "NSURL+N2")


class NitrogenCleanupTests(unittest.TestCase):
    def test_retired_helpers_have_no_files_callers_or_project_references(self):
        pattern = re.compile(r"\b(?:" + "|".join(map(re.escape, RETIRED)) + r")\b")
        for name in RETIRED:
            for extension in ("h", "mm"):
                self.assertFalse((ROOT / "Nitrogen/Sources" / f"{name}.{extension}").exists())
        tracked = subprocess.check_output(
            ["git", "ls-files", "-z", "--", "Horos", "Nitrogen", "Preference Panes"], cwd=ROOT
        ).decode().split("\0")
        for name in tracked:
            path = ROOT / name
            if path.is_file() and path.suffix in (".h", ".m", ".mm", ".swift", ".pch",
                                                 ".xib", ".storyboard", ".plist"):
                self.assertNotRegex(path.read_text(errors="replace"), pattern, name)
        for project in PROJECTS:
            self.assertNotRegex((ROOT / project).read_text(), pattern)
            objects = project_objects(project)
            for obj in objects.values():
                for key in ("children", "files", "buildPhases", "buildConfigurations", "targets"):
                    for reference in obj.get(key, []):
                        self.assertIn(reference, objects, (project, key, reference))
                if "fileRef" in obj:
                    self.assertIn(obj["fileRef"], objects)

    def test_unused_parsers_are_gone_but_swift_keeps_foundation_iso_formatter(self):
        for extension in ("h", "m"):
            self.assertFalse((ROOT / "Nitrogen/Sources" / f"ISO8601DateFormatter.{extension}").exists())
        for project in PROJECTS:
            self.assertNotIn("ISO8601DateFormatter", (ROOT / project).read_text())
        forbidden = re.compile(r"N2URLParts|URLWithParts:|dataWithBase64:|initWithBase64:|base64EncodingTable")
        for root in ("Horos", "Nitrogen", "Preference Panes"):
            for path in (ROOT / root).rglob("*"):
                if not path.is_file() or path.suffix not in (".h", ".m", ".mm", ".swift", ".pch"):
                    continue
                source = path.read_text(errors="replace")
                self.assertNotRegex(source, forbidden, str(path))
                if path.suffix != ".swift":
                    self.assertNotRegex(source, r"\bISO8601DateFormatter\b", str(path))
        swift = ROOT / "Horos/Sources/MetalViewer/Metal3DViewerWindowController.swift"
        self.assertIn("ISO8601DateFormatter().string(from:", swift.read_text())

    def test_purpose_groups_keep_every_remaining_source_at_its_original_path(self):
        objects = project_objects(PROJECTS[0])
        nitrogen = next(obj for obj in objects.values()
                        if obj.get("isa") == "PBXGroup" and obj.get("name") == "Nitrogen")
        self.assertEqual(nitrogen["path"], "Nitrogen/Sources")
        groups = [objects[key] for key in nitrogen["children"]]
        self.assertEqual([group["name"] for group in groups], [
            "Database & Preferences", "Networking", "Files & Processes",
            "Threading & Diagnostics", "Foundation Extensions", "AppKit Extensions",
            "UI Controls", "Geometry & Layout", "Scripting",
        ])
        parents = {child: key for key, obj in objects.items() for child in obj.get("children", [])}

        def resolved_path(key):
            obj = objects[key]
            parent = ROOT if obj.get("sourceTree") == "SOURCE_ROOT" or key not in parents else resolved_path(parents[key])
            return parent / obj.get("path", "")

        files = []
        for group in groups:
            self.assertEqual(group["isa"], "PBXGroup")
            self.assertNotIn("path", group)
            self.assertTrue(group["children"])
            for key in group["children"]:
                self.assertEqual(objects[key]["isa"], "PBXFileReference")
                path = resolved_path(key)
                self.assertEqual(path, ROOT / "Nitrogen/Sources" / Path(objects[key]["path"]).name)
                self.assertTrue(path.is_file(), path)
                files.append(path)
        self.assertEqual(len(files), len(set(files)))
        self.assertEqual(set(files), {path for path in (ROOT / "Nitrogen/Sources").iterdir()
                                      if path.suffix in (".h", ".m", ".mm")})

    def test_retained_implementations_are_still_compiled_once_in_horos(self):
        objects = project_objects(PROJECTS[0])
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        sources = Counter()
        for key in target["buildPhases"]:
            phase = objects[key]
            if phase["isa"] == "PBXSourcesBuildPhase":
                sources.update(Path(objects[objects[file]["fileRef"]]["path"]).name
                               for file in phase["files"])
        retained = {path.name for path in (ROOT / "Nitrogen/Sources").iterdir()
                    if path.suffix in (".m", ".mm")}
        self.assertTrue({"N2ManagedDatabase.mm",
                         "NSThread+N2.mm", "N2DirectoryEnumerator.mm", "N2AdaptiveBox.mm"} <= retained)
        for name in retained:
            self.assertEqual(sources[name], 1, name)


if __name__ == "__main__":
    unittest.main()
