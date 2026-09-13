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

    def test_window_resets_for_new_series_not_for_every_slice(self):
        method = renderer_method("private func loadPix(")
        self.assertIn('reader?.stringValue(forTag: "0020,000E")', method)
        self.assertIn("resetWindowLevel || currentPix == nil || seriesKey != windowSeriesKey", method)
        self.assertLess(method.index("seriesKey != windowSeriesKey"), method.index("currentPix = pix"))
        self.assertIn("if needsDefaultWindow, let storedPixels", method)
        self.assertIn("needsDefaultWindow = false", method)
        self.assertNotIn("imageObj", method)

    def test_mr_uses_planar_auto_window_and_ct_keeps_valid_dicom_window(self):
        method = renderer_method("private func loadPix(")
        self.assertIn('reader?.stringValue(forTag: "0008,0060") ?? pix.modalityString', method)
        self.assertIn('modality?.uppercased() == "MR" || dicomWindow == nil', method)
        self.assertIn("MetalViewerAutomaticWindowLevel.window(for: storedPixels, modality: modality)", method)
        self.assertIn("automaticWindow ?? dicomWindow ?? storedPixels.storedRangeWindow", method)
        self.assertIn("window.level.isFinite && window.width.isFinite && window.width > 0", method)
        self.assertNotIn("storedPixels.inferredWindow", method)

    def test_manual_adjustments_survive_async_volume_completion(self):
        setter = renderer_method("func setWindowLevel(")
        self.assertIn("needsDefaultWindow = false", setter)
        request = renderer_method("private func requestVolumeTexture(")
        self.assertIn("if needsDefaultWindow { loadCurrentPix(resetWindowLevel: true) }", request)
        self.assertIn("if self.needsDefaultWindow { self.loadCurrentPix(resetWindowLevel: true) }", request)
        load = renderer_method("private func loadPix(")
        self.assertIn("usingVolumeTexture && !needsDefaultWindow ? nil : MetalStoredInt16PixelData(pix: pix)", load)

    def test_zero_width_requests_auto_and_invalid_windows_are_rejected(self):
        setter = renderer_method("func setWindowLevel(")
        self.assertIn("guard wl.isFinite, ww.isFinite else { return }", setter)
        self.assertIn("guard ww > 0 else", setter)
        self.assertIn("loadPix(currentPix, resetWindowLevel: true)", setter)
        self.assertLess(setter.index("guard ww > 0"), setter.index("windowLevel = wl"))

    def test_pixel_decode_is_reused_for_upload_and_window_calculation(self):
        load = renderer_method("private func loadPix(")
        self.assertEqual(load.count("MetalStoredInt16PixelData(pix: pix)"), 1)
        self.assertIn("makeStoredInt16Texture(storedPixels)", load)
        upload = renderer_method("private func makeStoredInt16Texture(")
        self.assertNotIn("MetalStoredInt16PixelData(pix:", upload)
        self.assertIn("storedPixels.data.withUnsafeBytes", upload)

    def test_empty_or_failed_pixels_leave_the_next_window_pending(self):
        reset = renderer_method("private func resetImageTextureState()")
        self.assertIn("needsDefaultWindow = true", reset)
        self.assertNotIn("imageDefaultWindowLevel", METAL)
        self.assertNotIn("imageDefaultWindowWidth", METAL)


if __name__ == "__main__":
    unittest.main()
