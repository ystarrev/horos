"""Non-build source-contract checks for direct DICOM export."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BROWSER = (ROOT / "Horos/Sources/BrowserController.m").read_text()
CODEC = (ROOT / "Horos/Sources/DicomDatabase+DCMTK.mm").read_text()
EXPORT = CODEC.split("+(BOOL)exportDicomFileAtPath:", 1)[1].split("+(BOOL)fileNeedsDecompression:", 1)[0]


class ExportPipelineTests(unittest.TestCase):
    def test_no_destination_conversion_pass(self):
        self.assertNotIn("files2Compress", BROWSER)
        self.assertIn("exportDicomFileAtPath:[filesToExport objectAtIndex:i] toPath:dest", BROWSER)

    def test_source_is_read_only(self):
        self.assertIn("HorosModernDCMTKWriteTransferSyntax(source, temporary, syntax, quality)", EXPORT)
        self.assertIn("copyItemAtPath:source toPath:temporary", EXPORT)
        self.assertNotIn("removeItemAtPath:source", EXPORT)
        self.assertNotIn("moveItemAtPath:source", EXPORT)

    def test_publish_only_completed_files(self):
        self.assertIn("if (!written)", EXPORT)
        self.assertGreaterEqual(EXPORT.count("if (thread.isCancelled)"), 2)
        self.assertIn("moveItemAtPath:temporary toPath:destination error:error", EXPORT)
        self.assertNotIn("removeItemAtPath:destination", EXPORT)
        self.assertIn("@finally", EXPORT)
        self.assertIn("removeItemAtPath:staging", EXPORT)

    def test_representation_policy(self):
        self.assertIn('syntax = @"1.2.840.10008.1.2.1"', EXPORT)
        self.assertIn("!encapsulated", EXPORT)
        self.assertIn("isStructuredReport:sop", EXPORT)
        self.assertIn("compressionForModality:modality quality:&quality resolution:resolution", EXPORT)


if __name__ == "__main__":
    unittest.main()
