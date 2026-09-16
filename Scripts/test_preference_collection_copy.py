"""Non-build source checks and Core Foundation tests using synthetic settings only.

Native fixtures exercise the replacement API, not compiled Horos methods.
No application preferences or patient files are read or changed.
"""

import ctypes
from datetime import datetime
import plistlib
import shlex
import shutil
import subprocess
import sys
import unittest

from test_macos_baseline import ROOT, project_objects


APP = (ROOT / "Horos/Sources/AppController.m").read_text()
PANE = (ROOT / "Preference Panes/OSIHangingPreferencePane/OSIHangingPreferencePanePref.m").read_text()
STARTUP = APP[APP.index("    NSMutableArray *dbArray ="):APP.index(
    '\tif( [[NSUserDefaults standardUserDefaults] valueForKey: @"timeZone"])')]
COPY = "    NSDictionary *savedProtocols =" + PANE.split("    NSDictionary *savedProtocols =", 1)[1].split(
    "    for( NSString *modality in hangingProtocols)", 1)[0]


class CollectionCopySourceTests(unittest.TestCase):
    def test_startup_only_copies_the_list_and_balances_ownership(self):
        self.assertIn('arrayForKey: @"localDatabasePaths"] mutableCopy];', STARTUP)
        self.assertNotIn("autorelease", STARTUP)
        self.assertNotIn("[dbArray release]", STARTUP)
        self.assertIn("for( NSDictionary *d in dbArray)", STARTUP)
        for path in ("/tmp/", "/private/tmp/", "/private/var/tmp/"):
            self.assertIn(f'hasPrefix: @"{path}"', STARTUP)
        self.assertIn("if( toBeRemoved.count)", STARTUP)
        self.assertIn("[dbArray removeObjectsInArray: toBeRemoved]", STARTUP)
        self.assertIn('setObject: dbArray forKey: @"localDatabasePaths"', STARTUP)
        self.assertNotIn("[d set", STARTUP)

    def test_protocol_copy_keeps_mutable_containers_and_owning_ivar(self):
        self.assertIn('dictionaryForKey:@"HANGINGPROTOCOLS"', COPY)
        self.assertIn("savedProtocols\n        ?", COPY)
        self.assertIn("CFPropertyListCreateDeepCopy(kCFAllocatorDefault,", COPY)
        self.assertIn("(CFPropertyListRef)savedProtocols, kCFPropertyListMutableContainers)", COPY)
        self.assertIn(": nil;", COPY)
        self.assertLess(COPY.index("[hangingProtocols release];"), COPY.index("hangingProtocols = editableProtocols;"))
        self.assertNotIn("autorelease", COPY)
        dealloc = PANE.split("- (void)dealloc", 1)[1].split("- (void)setModalityForHangingProtocols:", 1)[0]
        self.assertIn("[hangingProtocols release]", dealloc)

    def test_recursive_copy_and_unused_dictionary_methods_have_no_callers(self):
        for directory in ("Horos", "Nitrogen", "Preference Panes"):
            for path in (ROOT / directory).rglob("*"):
                if path.is_file() and path.suffix in (".h", ".m", ".mm", ".swift", ".pch", ".xib"):
                    self.assertNotIn("deepMutableCopy", path.read_text(errors="replace"), str(path))
        dictionary = (ROOT / "Nitrogen/Sources/NSDictionary+N2.mm").read_text()
        self.assertNotIn("ofClass:", dictionary)
        # These two callers deliberately use identity, not isEqual: matching.
        self.assertIn("[self objectForKey:key] == obj", dictionary)
        for path in ("Anonymization.mm", "QTExportHTMLSummary.m"):
            self.assertIn("keyForObject:", (ROOT / "Horos/Sources" / path).read_text())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "Requires macOS SDK")
    def test_actual_copy_callsite_excerpts_pass_sdk_syntax_check(self):
        fixtures = {
            "AppController.m": 'void checkStartup(void) {\n' + STARTUP + '\n}\n',
            "OSIHangingPreferencePanePref.m": (
                'void checkProtocols(void) {\nNSMutableDictionary *hangingProtocols = nil;\n'
                + COPY + '\n[hangingProtocols release];\n}\n'),
        }
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        target = next(obj for obj in objects.values()
                      if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        source_phase = next(objects[key] for key in target["buildPhases"]
                            if objects[key]["isa"] == "PBXSourcesBuildPhase")
        flags_by_file = {}
        for key in source_phase["files"]:
            entry = objects[key]
            name = objects[entry["fileRef"]]["path"].split("/")[-1]
            flags_by_file[name] = shlex.split(entry.get("settings", {}).get("COMPILER_FLAGS", ""))
        self.assertIn("-fobjc-arc", flags_by_file["AppController.m"])
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        for name, fixture in fixtures.items():
            with self.subTest(name=name):
                # Horos defaults to MRC; apply each file's project overrides separately.
                result = subprocess.run([
                    "xcrun", "clang", "-fsyntax-only", "-fno-objc-arc", *flags_by_file[name],
                    "-x", "objective-c", "-target", "arm64-apple-macos27.0",
                    "-isysroot", sdk, "-Werror", "-",
                ], input='#import <Cocoa/Cocoa.h>\n#import <CoreFoundation/CoreFoundation.h>\n' + fixture,
                    capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "Requires Core Foundation")
class NativePropertyListCopyTests(unittest.TestCase):
    def setUp(self):
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        pointer, index = ctypes.c_void_p, ctypes.c_long
        signatures = {
            "CFDataCreate": (pointer, [pointer, pointer, index]),
            "CFDataGetLength": (index, [pointer]),
            "CFDataGetBytePtr": (pointer, [pointer]),
            "CFPropertyListCreateWithData": (pointer, [pointer, pointer, ctypes.c_ulong, pointer, pointer]),
            "CFPropertyListCreateDeepCopy": (pointer, [pointer, pointer, ctypes.c_ulong]),
            "CFPropertyListCreateData": (pointer, [pointer, pointer, index, ctypes.c_ulong, pointer]),
            "CFDictionaryGetValue": (pointer, [pointer, pointer]),
            "CFDictionarySetValue": (None, [pointer, pointer, pointer]),
            "CFArrayGetValueAtIndex": (pointer, [pointer, index]),
            "CFArrayAppendValue": (None, [pointer, pointer]),
            "CFArrayRemoveValueAtIndex": (None, [pointer, index]),
            "CFArrayCreateMutableCopy": (pointer, [pointer, index, pointer]),
            "CFRelease": (None, [pointer]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.cf, name)
            function.restype, function.argtypes = result, arguments

    def own(self, value):
        self.assertTrue(value, "Core Foundation allocation failed")
        self.addCleanup(self.cf.CFRelease, value)
        return value

    def native(self, value):
        data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
        buffer = ctypes.create_string_buffer(data)
        cfdata = self.own(self.cf.CFDataCreate(None, buffer, len(data)))
        return self.own(self.cf.CFPropertyListCreateWithData(None, cfdata, 0, None, None))

    def read(self, value):
        # kCFPropertyListBinaryFormat_v1_0 = 200.
        data = self.own(self.cf.CFPropertyListCreateData(None, value, 200, 0, None))
        return plistlib.loads(ctypes.string_at(self.cf.CFDataGetBytePtr(data), self.cf.CFDataGetLength(data)))

    def test_native_copy_preserves_types_and_isolates_nested_edits(self):
        settings = {"MR": [{"Name": "Default", "Sync": True, "WL": 120, "WW": 600.5,
                            "Payload": b"\x00\xff", "Date": datetime(2026, 9, 1)}], "CT": []}
        original = self.native(settings)
        # kCFPropertyListMutableContainers = 1.
        copied = self.own(self.cf.CFPropertyListCreateDeepCopy(None, original, 1))
        self.assertEqual(self.read(copied), settings)
        protocols = self.cf.CFDictionaryGetValue(copied, self.native("MR"))
        protocol = self.cf.CFArrayGetValueAtIndex(protocols, 0)
        self.cf.CFDictionarySetValue(protocol, self.native("WL"), self.native(42))
        self.cf.CFArrayAppendValue(protocols, self.native({"Name": "Additional"}))
        self.cf.CFDictionarySetValue(copied, self.native("US"), self.native([]))
        edited = self.read(copied)
        self.assertEqual(edited["MR"][0]["WL"], 42)
        self.assertEqual(edited["MR"][1], {"Name": "Additional"})
        self.assertEqual(edited["US"], [])
        self.assertEqual(self.read(original), settings)

    def test_empty_dictionary_is_editable(self):
        copied = self.own(self.cf.CFPropertyListCreateDeepCopy(None, self.native({}), 1))
        self.cf.CFDictionarySetValue(copied, self.native("MR"), self.native([]))
        self.assertEqual(self.read(copied), {"MR": []})

    def test_shallow_list_copy_preserves_entries_and_does_not_modify_source(self):
        entries = [{"Path": "/Volumes/Example/Horos Data", "Description": "Database"},
                   {"Path": "/tmp/example", "Description": "Temporary"}]
        original = self.native(entries)
        copied = self.own(self.cf.CFArrayCreateMutableCopy(None, 0, original))
        self.assertEqual(self.cf.CFArrayGetValueAtIndex(copied, 0),
                         self.cf.CFArrayGetValueAtIndex(original, 0))
        self.cf.CFArrayRemoveValueAtIndex(copied, 1)
        self.assertEqual(self.read(copied), entries[:1])
        self.assertEqual(self.read(original), entries)


if __name__ == "__main__":
    unittest.main()
