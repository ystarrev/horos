"""DICOM file-replacement cache contracts; no build or patient data access."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
READER = (SOURCES / "SwiftDICOMReader.swift").read_text()
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
HARNESS = (ROOT / "Scripts/tests/SwiftDICOMStoredPixelTests.swift").read_text()


def method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class DICOMFileCacheTests(unittest.TestCase):
    def test_identity_tracks_replacement_and_same_size_in_place_edits(self):
        revision = READER.split("struct SwiftDICOMFileRevision:", 1)[1].split("\n}", 1)[0]
        for field in ("st_dev", "st_ino", "st_size", "st_mtimespec.tv_sec",
                      "st_mtimespec.tv_nsec", "st_ctimespec.tv_sec", "st_ctimespec.tv_nsec"):
            self.assertIn(field, revision)
        self.assertIn("Darwin.fstatat(AT_FDCWD, $0, &status, 0)", revision)
        self.assertNotIn("Darwin.stat(", revision)
        self.assertIn("else { return nil }", revision)

    def test_reader_never_serves_a_stale_or_deleted_file(self):
        cached = method(READER, "static func cached(contentsOfFile path:")
        self.assertLess(cached.index("cached.fileRevision == SwiftDICOMFileRevision"),
                        cached.index("return cached"))
        load = method(READER, "init(contentsOfFile path:")
        self.assertIn("revision == SwiftDICOMFileRevision(contentsOfFile: path)", load)
        self.assertIn("fileRevision = revision", load)
        self.assertNotIn("mappedIfSafe", load)
        self.assertNotIn("alwaysMapped", load)

    def test_geometry_and_volume_keys_include_the_file_revision(self):
        geometry = method(MODELS, "func metadata(for pix:")
        self.assertIn('let key = "\\(revision.cacheKey)|frame=\\(frameIndex)"', geometry)
        self.assertIn("reader.fileRevision == revision", geometry)
        request = method(MODELS, "func makeRequest(")
        self.assertIn("sourceRevisions[sourcePath]", request)  # One stat per multiframe file.
        self.assertIn('components.append("\\(index):\\(revision.cacheKey):f\\(frameNumber)")', request)
        self.assertNotIn("pixList.compactMap", request)  # Do not read every header on the UI thread.

    def test_background_build_rechecks_source_revisions_and_seed(self):
        build = method(MODELS, "func requestEntry(\n        for request: Request,")
        self.assertEqual(build.count("guard request.sourcesAreCurrent else { return nil }"), 2)
        self.assertNotIn("makeRequest(", build)
        seed = method(MODELS, "private func buildStoredInt16Entry(")
        self.assertIn("pixList[seed.index] === seed.pix", seed)
        self.assertIn("let revision = seed.pixels.fileRevision", seed)
        self.assertIn("revision == SwiftDICOMFileRevision(contentsOfFile: path)", seed)

    def test_volume_dimensions_prefer_source_headers_over_lazy_dcmpix_defaults(self):
        dimensions = method(MODELS, "private func dimensionsWithoutLoading(for pix:")
        self.assertIn('reader.integerValue(forTag: "0028,0011")', dimensions)
        self.assertIn('reader.integerValue(forTag: "0028,0010")', dimensions)
        self.assertLess(dimensions.index("return SliceDimensions"), dimensions.index("pix.widthWithoutLoading()"))

    def test_runtime_harness_checks_real_cache_and_pixel_results(self):
        for scenario in ("verifyFileReplacementCache", "Unchanged file should reuse reader",
                         "Atomic replacement retained stale pixels", "In-place edit retained stale pixels",
                         "Cached snapshot changed after in-place edit", "Deleted file was served from cache",
                         "Recreated file retained stale geometry", "Explicit invalidation retained reader"):
            self.assertIn(scenario, HARNESS)


if __name__ == "__main__":
    unittest.main()
