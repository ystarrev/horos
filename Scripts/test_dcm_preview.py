"""Source regression guards for database preview stacks; no build or patient data."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREVIEW = (ROOT / "Horos/Sources/PreviewView.m").read_text()
METAL = (ROOT / "Horos/Sources/MetalViewer/MetalPreviewImageView.swift").read_text()


def objc_method(name):
    return PREVIEW.split(name, 1)[1].split("\n- (", 1)[0]


def renderer_method(name):
    return METAL.split(name, 1)[1].split("\n    }", 1)[0]


class DICOMPreviewTests(unittest.TestCase):
    def test_stack_requires_database_identity_not_series_number(self):
        gate = objc_method("- (BOOL)pixListRepresentsDisplayedFiles:")
        self.assertIn("[pixels count] < 2", gate)
        self.assertIn("[pixels count] != [_dcmFilesList count]", gate)
        self.assertIn("[fileObject isKindOfClass:[DicomImage class]]", gate)
        self.assertIn("[pixelObject isKindOfClass:[DCMPix class]]", gate)
        self.assertIn("image.isDeleted || image.managedObjectContext == nil", gate)
        self.assertIn("[pix.imageObjectID isEqual:image.objectID] == NO", gate)
        self.assertIn("DicomSeries *series = image.series", gate)
        self.assertIn("series == nil || series.isDeleted", gate)
        self.assertIn("seriesObjectID = series.objectID", gate)
        self.assertIn("[seriesObjectID isEqual:series.objectID] == NO", gate)
        self.assertNotIn("serieNo", gate)
        # Read the supplied UI-context image objects, not a DCMPix's worker context.
        self.assertNotIn("[pix imageObj]", gate)

    def test_documents_and_incompatible_dimensions_cannot_form_a_stack(self):
        gate = objc_method("- (BOOL)pixListRepresentsDisplayedFiles:")
        self.assertIn("[image.isImageStorage boolValue] == NO", gate)
        self.assertIn('[series.modality isEqualToString:@"SEG"]', gate)
        self.assertIn("width <= 0 || height <= 0", gate)
        self.assertIn("[pix widthWithoutLoading] != width", gate)
        self.assertIn("[pix heightWithoutLoading] != height", gate)
        self.assertNotIn("CheckLoadIn", gate)
        self.assertNotIn("removeObject", gate)

    def test_selection_changes_explicitly_leave_stack_mode(self):
        for signature in ("- (void) setPixels:", "- (void) setIndex:",
                          "- (void) setIndexWithReset:", "- (void)refreshMetalPixListIfNeeded"):
            with self.subTest(method=signature):
                method = objc_method(signature)
                self.assertIn("pixListRepresentsDisplayedFiles:", method)
                self.assertIn("[_metalView updatePixList:", method)
                self.assertIn("[_metalView updateSinglePix:", method)
                self.assertIn("[self refreshPreviewMode]", method)

    def test_incremental_thumbnail_loading_can_invalidate_a_stack(self):
        method = objc_method("- (void)refreshMetalPixListIfNeeded")
        self.assertIn("canRefreshFullPixList == NO && _metalView.currentPixListCount > 0", method)
        self.assertIn("[_dcmPixList objectAtIndex:index] : nil", method)

    def test_single_preview_clears_pending_and_cached_volumes_before_loading(self):
        method = renderer_method("func updateSinglePix(_ pix:")
        for reset in ("pixList = []", "volumeEntry = nil", "requestedVolumeKey = nil"):
            self.assertLess(method.index(reset), method.index("updateCurrentPix(pix,"))
        self.assertIn("@objc func updateSinglePix(_ pix:", METAL)
        self.assertIn("previewRenderer.updateSinglePix(pix,", METAL)

    def test_cleared_or_replaced_slice_cannot_reuse_a_volume(self):
        method = renderer_method("func updateCurrentPix(_ pix:")
        self.assertIn("pix == nil || !pixList.indices.contains(index) || pixList[index] !== pix", method)
        for reset in ("pixList = []", "volumeEntry = nil", "requestedVolumeKey = nil"):
            self.assertLess(method.index(reset), method.index("guard let pix else"))
        eligibility = renderer_method("private func canUseVolumeTexture(")
        self.assertIn("pixList.indices.contains(index)", eligibility)
        self.assertIn("pixList[index] === pix", eligibility)
        request = renderer_method("private func requestVolumeTexture(")
        self.assertLess(request.index("self.requestedVolumeKey == key"),
                        request.index("self.volumeEntry = entry"))


if __name__ == "__main__":
    unittest.main()
