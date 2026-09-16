"""No-build source checks and Foundation filesystem smoke tests on temporary fixtures.

The JXA counterpart exercises the native operations, not the unbuilt ObjC method.
Source contracts below pin the wrapper's matching suffix and conflict rules.
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_macos_baseline import ROOT


BODY = (ROOT / "Nitrogen/Sources/NSFileManager+N2.mm").read_text().split(
    "-(NSString*)confirmNoIndexDirectoryAtPath:", 1)[1].split("-(NSUInteger)sizeAtPath:", 1)[0]


class NoIndexSourceTests(unittest.TestCase):
    def test_suffix_branches_and_empty_path(self):
        self.assertIn("if (path.length == 0)\n\t\treturn nil;", BODY)
        suffixed, unsuffixed = BODY.split("if ([path hasSuffix:ext]) {", 1)[1].split("} else {", 1)
        self.assertIn("pathWithExt = path;", suffixed)
        self.assertIn("pathWithoutExt = [path substringToIndex:path.length-ext.length];", suffixed)
        self.assertIn("pathWithoutExt = path;", unsuffixed)
        self.assertIn("pathWithExt = [path stringByAppendingString:ext];", unsuffixed)

    def test_conflicts_are_not_deleted_and_both_folders_are_not_merged(self):
        self.assertNotIn("removeItem", BODY)
        self.assertIn("if (pathWithExtExists && !pathWithExtIsDir)", BODY)
        self.assertIn("if (!pathWithExtExists && pathWithoutExtExists && pathWithoutExtIsDir)", BODY)
        self.assertIn("if (!pathWithExtExists || !pathWithExtIsDir)", BODY)
        self.assertIn("moveItemAtPath:pathWithoutExt toPath:pathWithExt error:&error", BODY)
        # Keep the existing directory-creation hook used during database relocation.
        self.assertIn("return [self confirmDirectoryAtPath:pathWithExt];", BODY)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation")
class NoIndexNativeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="horos-noindex-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def ensure(self, path):
        script = r'''
            ObjC.import("Foundation");
            var fm = $.NSFileManager.defaultManager;
            function state(path) {
                var isDirectory = Ref();
                var exists = fm.fileExistsAtPathIsDirectory(path, isDirectory);
                return {exists: !!exists, directory: !!isDirectory[0]};
            }
            function ensure(path) {
                if (!path) return null;
                path = $(path);
                var ext = ".noindex", withExt, withoutExt;
                if (path.hasSuffix(ext)) {
                    withExt = path;
                    withoutExt = path.substringToIndex(path.length - ext.length);
                } else {
                    withoutExt = path;
                    withExt = path.stringByAppendingString(ext);
                }
                var from = state(withoutExt), to = state(withExt);
                if (to.exists && !to.directory) throw new Error("Destination is a file");
                if (!to.exists && from.exists && from.directory) {
                    fm.moveItemAtPathToPathError(withoutExt, withExt, null);
                    to = state(withExt);
                    if (!to.exists || !to.directory) throw new Error("Rename failed");
                }
                if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(withExt, true, $(), null))
                    throw new Error("Directory creation failed");
                return ObjC.unwrap(withExt);
            }
            function run(argv) {
                try { return JSON.stringify({path: ensure(argv[0])}); }
                catch (error) { return JSON.stringify({error: String(error)}); }
            }
        '''
        output = subprocess.check_output(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(path)], text=True, timeout=15)
        return json.loads(output)

    def test_new_short_and_unicode_folder_names(self):
        for name in ("x", "nested/Incoming", "Images \u00e9", "DATABASE.noindex"):
            with self.subTest(name=name):
                requested = self.root / name
                expected = requested if name.endswith(".noindex") else requested.with_name(requested.name + ".noindex")
                self.assertEqual(self.ensure(requested), {"path": str(expected)})
                self.assertTrue(expected.is_dir())

    def test_legacy_folder_is_renamed_without_changing_its_contents(self):
        for requested_name in ("Incoming", "DATABASE.noindex"):
            with self.subTest(name=requested_name):
                bare = self.root / requested_name.removesuffix(".noindex")
                bare.mkdir()
                (bare / "sentinel").write_bytes(b"test contents")
                destination = bare.with_name(bare.name + ".noindex")
                self.assertEqual(self.ensure(self.root / requested_name), {"path": str(destination)})
                self.assertFalse(bare.exists())
                self.assertEqual((destination / "sentinel").read_bytes(), b"test contents")

    def test_both_existing_folders_are_preserved(self):
        for name in ("DATABASE", "DATABASE.noindex", "DATABASE.noindex.noindex"):
            folder = self.root / name
            folder.mkdir()
            (folder / "sentinel").write_text(name)
        for requested in ("DATABASE", "DATABASE.noindex"):
            self.assertEqual(self.ensure(self.root / requested), {"path": str(self.root / "DATABASE.noindex")})
        for name in ("DATABASE", "DATABASE.noindex", "DATABASE.noindex.noindex"):
            self.assertEqual((self.root / name / "sentinel").read_text(), name)

    def test_file_conflict_preserves_the_file_and_legacy_folder(self):
        (self.root / "Incoming").mkdir()
        (self.root / "Incoming" / "sentinel").write_bytes(b"legacy")
        conflict = self.root / "Incoming.noindex"
        conflict.write_bytes(b"do not delete")
        self.assertIn("error", self.ensure(conflict))
        self.assertEqual(conflict.read_bytes(), b"do not delete")
        self.assertEqual((self.root / "Incoming" / "sentinel").read_bytes(), b"legacy")

    def test_empty_path_does_nothing(self):
        self.assertEqual(self.ensure(""), {"path": None})
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
