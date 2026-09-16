"""Source contracts and native Foundation smoke checks; does not build Horos."""

import json
import re
import subprocess
import sys
import unittest

from test_macos_baseline import ROOT


def source(name):
    return (ROOT / "Nitrogen/Sources" / name).read_text()


class NitrogenFoundationTests(unittest.TestCase):
    def test_shell_only_keeps_the_native_serial_number_lookup(self):
        body = source("N2Shell.mm")
        self.assertEqual(re.findall(r"^\+\([^)]*\)(\w+)", body, re.MULTILINE), ["serialNumber"])
        self.assertIn('IOServiceMatching("IOPlatformExpertDevice")', body)
        self.assertIn("CFSTR(kIOPlatformSerialNumberKey)", body)
        self.assertIn("IOObjectRelease(platformExpert)", body)
        self.assertIn("[N2Shell serialNumber]", (ROOT / "Horos/Sources/AppController.m").read_text())
        for retired in ("NSTask", "gethostbyname", "gethostname", "ipconfig", "getuid"):
            self.assertNotIn(retired, body)

    def test_unused_string_and_bitmap_methods_are_gone(self):
        strings = source("NSString+N2.h") + source("NSString+N2.mm")
        for retired in ("markedString", "sizeString:", "dateString:", "stringByTrimmingStartAndEnd",
                        "urlEncodedString", "xmlEscapedString", "xmlUnescapedString"):
            self.assertNotIn(retired, strings)
        bitmaps = source("NSBitmapImageRep+N2.h") + source("NSBitmapImageRep+N2.mm")
        for retired in ("_spp", "repUsingColorSpaceName", "ATMask", "smoothen", "convolveWithFilter",
                        "fftConvolveWithFilter", "time1!!!!!!", "return self;;"):
            self.assertNotIn(retired, bitmaps)
        for retained in ("setColor:", "-(NSImage*)image"):
            self.assertIn(retained, bitmaps)

    def test_trash_uses_system_operation_without_deleting_name_collisions(self):
        body = source("NSFileManager+N2.mm").split("- (void)moveItemAtPathToTrash:", 1)[1].split(
            "-(NSString*)userApplicationSupportFolderForApp", 1)[0]
        self.assertIn("path.length == 0", body)
        self.assertIn("trashItemAtURL:[NSURL fileURLWithPath:path]", body)
        self.assertIn("resultingItemURL:NULL error:&error", body)
        self.assertIn("error.localizedDescription", body)
        for old in (".Trash", "removeItem", "moveItemAtPath:", "lastPathComponent"):
            self.assertNotIn(old, body)

    def test_temporary_file_reservation_handles_encoding_failure_and_descriptor_lifetime(self):
        body = source("NSFileManager+N2.mm").split("-(NSString*)tmpFilePathInDir:", 1)[1].split(
            "-(NSString*)tmpDirPath", 1)[0]
        self.assertIn("dirPath.length == 0", body)
        self.assertIn("templatePath.fileSystemRepresentation", body)
        self.assertIn("strdup(fileSystemPath)", body)
        self.assertIn("int descriptor = mkstemp(temp);", body)
        failure = body.split("if (descriptor == -1) {", 1)[1].split("}", 1)[0]
        self.assertIn("int errorCode = errno;", failure)
        self.assertIn("free(temp);", failure)
        self.assertIn("return nil;", failure)
        self.assertLess(body.index("close(descriptor);"), body.index("NSString *result"))
        self.assertIn("stringWithFileSystemRepresentation:temp length:strlen(temp)", body)
        self.assertIn("free(temp);\n    return result;", body)
        for old in ("getBytes:", "stringWithUTF8String:", "n2_descriptionWithCalendarFormat:"):
            self.assertNotIn(old, body)

    def test_exception_stack_symbols_belong_to_original_exception(self):
        body = source("NSException+N2.mm")
        self.assertIn('self.callStackSymbols componentsJoinedByString:@"\\r"', body)
        for old in ("backtrace_symbols", "std::vector", "callStackReturnAddresses", "NSThread"):
            self.assertNotIn(old, body)

    def test_duration_uses_foundation_with_truncated_not_rounded_units(self):
        body = source("NSString+N2.mm").split("+(NSString*)timeString:(NSTimeInterval)time maxUnits:", 1)[1].split(
            "-(NSString*)ASCIIString", 1)[0]
        for setting in ("NSDateComponentsFormatterUnitsStyleFull", "NSDateComponentsFormatterZeroFormattingBehaviorDropAll",
                        "NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond",
                        "formatter.maximumUnitCount = unitCount", "formatter.allowsFractionalUnits = NO"):
            self.assertIn(setting, body)
        self.assertIn("MAX(1, MIN(3, maxUnits))", body)
        self.assertIn("std::isfinite(time) ? MAX(0.0, std::floor(time)) : 0.0", body)
        self.assertIn("time >= 3600.0 ? 3600.0 : 60.0", body)
        self.assertIn("std::floor(time / unitSeconds) * unitSeconds", body)
        self.assertIn("unitCount == 2 && time >= 3600.0 && std::fmod(time, 3600.0) >= 60.0", body)
        self.assertIn("std::floor(time / 60.0) * 60.0", body)

    def test_legacy_data_identifier_helpers_remain_without_base64_methods(self):
        for filename in ("NSData+N2.h", "NSData+N2.mm"):
            body = source(filename)
            self.assertNotIn("base64", body.lower())
            for retained in ("dataWithHex:", "initWithHex:", "hex", "md5"):
                self.assertIn(retained, body)
        self.assertIn("CC_MD5(self.bytes, self.length", source("NSData+N2.mm"))

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation")
    def test_native_duration_formatter_preserves_pretruncated_values(self):
        # Exercise the actual Foundation formatter, not the unbuilt Objective-C wrapper.
        # These intervals have already had their omitted units truncated.
        cases = [(0, 1, "0 seconds"), (59, 1, "59 seconds"), (60, 1, "1 minute"),
                 (3540, 1, "59 minutes"), (3599, 2, "59 minutes, 59 seconds"),
                 (3600, 1, "1 hour"), (3601, 2, "1 hour, 1 second"),
                 (3659, 2, "1 hour, 59 seconds"), (3660, 2, "1 hour, 1 minute"),
                 (3661, 3, "1 hour, 1 minute, 1 second"), (7140, 2, "1 hour, 59 minutes"),
                 (90060, 2, "25 hours, 1 minute")]
        script = r'''
            ObjC.import("Foundation");
            var calendar = $.NSCalendar.alloc.initWithCalendarIdentifier($.NSCalendarIdentifierGregorian);
            calendar.locale = $.NSLocale.alloc.initWithLocaleIdentifier("en_US_POSIX");
            var formatter = $.NSDateComponentsFormatter.alloc.init;
            formatter.calendar = calendar;
            formatter.unitsStyle = $.NSDateComponentsFormatterUnitsStyleFull;
            formatter.allowedUnits = $.NSCalendarUnitHour | $.NSCalendarUnitMinute | $.NSCalendarUnitSecond;
            formatter.zeroFormattingBehavior = $.NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
            formatter.allowsFractionalUnits = false;
            JSON.stringify(CASES.map(function(row) {
                formatter.maximumUnitCount = row[1];
                return ObjC.unwrap(formatter.stringFromTimeInterval(row[0]));
            }));
        '''.replace("CASES", json.dumps(cases))
        output = subprocess.check_output(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], text=True, timeout=15)
        self.assertEqual(json.loads(output), [case[2] for case in cases])


if __name__ == "__main__":
    unittest.main()
