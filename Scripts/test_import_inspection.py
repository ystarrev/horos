"""Interpret production Swift import code against synthetic files; no app build."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


class ImportInspectionTests(unittest.TestCase):
    def test_metadata_handoff_and_relocation(self):
        files = [
            SOURCES / "MetalViewer/MetalViewerCachePolicy.swift",
            SOURCES / "MetalViewer/SwiftDICOMReader.swift",
            SOURCES / "SwiftDICOMImportMetadata.swift",
            SOURCES / "DICOMImportMetadataParser.swift",
            ROOT / "Scripts/tests/DICOMImportInspectionTests.swift",
        ]
        swift = subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="horos-import-inspection-") as folder:
            source = Path(folder) / "Inspection.swift"
            source.write_text("\n".join(path.read_text() for path in files))
            subprocess.run([swift, "-interpret", "-parse-as-library", "-swift-version", "5",
                            "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
                            "-module-cache-path", "/tmp/horos-frame-module-cache", str(source)],
                           check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
