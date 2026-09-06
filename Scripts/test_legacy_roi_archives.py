"""Source guards for legacy ROI archive decoding; no build or patient data access."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LegacyROIArchiveTests(unittest.TestCase):
    def test_version_16_consumes_all_four_extension_objects(self):
        source = (ROOT / "Horos/Sources/ROI.m").read_text()
        decoder = source.split("- (instancetype)initWithCoder:", 1)[1].split("- (void)encodeWithCoder:", 1)[0]
        extension = re.search(r"if \(fileVersion >= 16\)\s*\{(.*?)\}", decoder, re.S)
        self.assertIsNotNone(extension)
        self.assertEqual(extension[1].count("[coder decodeObject]"), 4)
        self.assertLess(decoder.index("fileVersion >= 15"), extension.start())

    def test_writer_keeps_version_11_format(self):
        source = (ROOT / "Horos/Sources/ROI.m").read_text()
        self.assertRegex(source, r"#define ROIVERSION 11\b")
        writer = source.split("- (void)encodeWithCoder:", 1)[1].split("- (id)copyWithZone:", 1)[0]
        self.assertIn("[ROI setVersion:ROIVERSION]", writer)
        self.assertNotIn("fileVersion", writer)


if __name__ == "__main__":
    unittest.main()
