"""Source/fixture checks for the DICOM date migration. Does not build or run Horos.

Actual date conversion is exercised by tests/DCMDateTests.mm after an approved
build. Python datetime below checks the expected fixtures, not the app code.
"""

from datetime import datetime, timezone
import json
import re
import unittest
from zoneinfo import ZoneInfo

import test_dcm_extraction

ROOT = test_dcm_extraction.ROOT


class DCMDateTests(test_dcm_extraction.DCMExtractionTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.source = (ROOT / "Horos/Sources/DCMCalendarDate.mm").read_text()
        cls.header = (ROOT / "Horos/Sources/DCMCalendarDate.h").read_text()
        cls.fixture = json.loads((ROOT / "Scripts/tests/dcm_dates_baseline.json").read_text())

    def test_dicom_conversion_is_delegated_to_dcmtk(self):
        for call in ("DcmDate::getOFDateFromString", "DcmTime::getOFTimeFromString",
                     "DcmDateTime::getOFDateTimeFromString", "DcmDate::getDicomDateFromOFDate",
                     "DcmTime::getDicomTimeFromOFTime", "DcmDateTime::getDicomDateTimeFromOFDateTime"):
            self.assertIn(call, self.source)
        self.assertNotIn("componentsSeparatedByString", self.source)
        self.assertNotIn("pow(", self.source)
        self.assertNotIn("(unsigned long)ti", self.source)
        self.assertIn("std::floor(seconds)", self.source)

    def test_archive_class_layout_and_keys_are_retained(self):
        self.assertIn("@interface DCMCalendarDate : NSDate", self.header)
        body = self.header.split("@interface DCMCalendarDate : NSDate {", 1)[1].split("}", 1)[0]
        declarations = [re.sub(r"\s+", " ", field.strip()) for field in body.split(";") if field.strip()]
        self.assertEqual(declarations, self.fixture["instanceVariables"])
        for key in self.fixture["archiveKeys"]:
            self.assertEqual(self.source.count('@"' + key + '"'), 2)
        self.assertIn("[super encodeWithCoder:coder]", self.source)
        self.assertIn("[super initWithCoder:coder]", self.source)
        self.assertIn("if (coder.allowsKeyedCoding)", self.source)

    def test_legacy_byte_container_is_removed(self):
        self.assertFalse((ROOT / "DCM Framework/DCMDataContainer.m").exists())

    def test_datetime_fixture_offsets_and_local_dst_are_correct(self):
        for case in self.fixture["valid"]:
            if case["kind"] != "DT":
                continue
            with self.subTest(value=case["input"]):
                date = datetime.strptime(case["output"], "%Y%m%d%H%M%S.%f%z")
                self.assertEqual(date.astimezone(timezone.utc).strftime("%Y%m%d%H%M%S.%f"), case["utc"])
                if "zone" in case:
                    self.assertEqual(date.astimezone(ZoneInfo(case["zone"])).utcoffset(), date.utcoffset())

    def test_runtime_fixture_covers_boundary_cases(self):
        cases = {(case["kind"], case["input"]) for case in self.fixture["valid"]}
        for key in (("TM", "00"), ("TM", "000000.000001"), ("DA", "2024.02.29"),
                    ("DT", "19991231235959.000001-0700"), ("DT", "20240229123456.123456-0030")):
            self.assertIn(key, cases)
        self.assertIn("20230229", self.fixture["invalid"]["DA"])
        self.assertIn("000000-", self.fixture["ranges"]["TM"])

    def test_objcpp_implementation_is_in_horos(self):
        path = "Horos/Sources/DCMCalendarDate.mm"
        self.assertFalse((ROOT / path[:-1]).exists())
        self.assertEqual(self.target_files("Horos", "PBXSourcesBuildPhase").count(path), 1)
        reference = next(obj for obj in self.project.values() if obj.get("path") == path)
        self.assertEqual(reference["lastKnownFileType"], "sourcecode.cpp.objcpp")


if __name__ == "__main__":
    unittest.main()
