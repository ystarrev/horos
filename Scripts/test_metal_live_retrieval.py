"""Live query viewing and diagnostic source contracts; no app build or PACS access."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"


class MetalLiveRetrievalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.launcher = (SOURCES / "MetalViewerLauncher.swift").read_text()
        cls.renderer = (SOURCES / "MetalViewerRenderer.swift").read_text()
        cls.pane = (SOURCES / "MetalViewerPaneView.swift").read_text()
        cls.window = (SOURCES / "MetalViewerWindowController.swift").read_text()
        cls.query = (ROOT / "Horos/Sources/QueryController.mm").read_text()
        cls.benchmark = cls.launcher.split("enum MetalViewerScreenPlacement", 1)[0]

    def test_refresh_is_batched_but_cannot_wait_until_transfer_stops(self):
        schedule = self.launcher.split("private class func scheduleDatabaseRefresh", 1)[1].split("private class func clampedRefreshInterval", 1)[0]
        self.assertIn("pendingRefreshStartedAt", schedule)
        self.assertIn("maxDeferral - elapsed", schedule)
        self.assertIn("return 0.5", schedule)
        self.assertIn("return max(1, delay * 2)", schedule)
        self.assertNotIn("incomingImportCoalescingDelay", schedule)

    def test_refresh_only_updates_matching_open_patient_contexts(self):
        refresh = self.launcher.split("private class func refreshOpenViewersFromDatabase", 1)[1].split("private class func refreshIdentifiers", 1)[0]
        self.assertIn("context.identifiers.intersects(importedIdentifiers) == false", refresh)
        self.assertIn("controller.updatePatientStudy(updatedStudy)", refresh)
        self.assertIn("markScoutStudiesOpened: false", refresh)
        self.assertNotIn("makeKeyAndOrderFront", refresh)

    def test_2d_update_keeps_existing_view_and_interactions(self):
        refresh = self.pane.split("func refreshAfterDatabaseUpdate", 1)[1].split("override func mouseDown", 1)[0]
        inplace = refresh.split("if displayMode == .stack2D", 1)[1].split("let preservedDisplayMode", 1)[0]
        self.assertIn("dynamicSequence == nil", inplace)
        self.assertIn("overlaySeries == nil, overlayForRefresh == nil", inplace)
        self.assertIn("metalView.display(pixList: updatedSeries.loadedPixList(), preservingDisplayedImage: true)", inplace)
        self.assertNotIn("display(series:", inplace)
        binding = refresh.split("guard primaryImageCountChanged", 1)[0]
        self.assertIn("windowLevelStateDidChange = { [weak updatedSeries]", binding)
        self.assertIn("transferFunctionStateDidChange = { [weak updatedSeries]", binding)
        self.assertIn("overlayWindowLevelStateDidChange = { [weak overlayForRefresh]", binding)

    def test_slice_identity_survives_insertion_before_current_slice(self):
        update = self.renderer.split("func setPixList(", 1)[1].split("func setDisplayMode", 1)[0]
        self.assertIn("preservingDisplayedImage: Bool = false", update)
        self.assertIn("$0.srcFile == previousPix?.srcFile && $0.frameNo == previousPix?.frameNo", update)
        self.assertIn("currentSliceIndex = matchingSliceIndex ??", update)
        self.assertLess(update.index("currentSliceIndex ="), update.index("loadSlice(at:"))
        for reset in ("zoomScale =", "panOffset =", "stackRotationRadians ="):
            self.assertNotIn(reset, update)

    def test_incoming_images_do_not_reset_window_level(self):
        update = self.window.split("private func updateStudy(", 1)[1].split("context.study = study", 1)[0]
        self.assertIn("series.windowLevelState = previousSeries.windowLevelState", update)
        self.assertNotIn("MetalViewerWindowLevelState()", update)

    def test_initial_frame_cache_is_not_reused_for_growing_series(self):
        self.assertIn("filteredFramesForSeries.count == sortedImages.count ? filteredFramesForSeries : []", self.launcher)

    def test_query_benchmark_starts_before_retrieve_and_records_availability(self):
        action = self.query.split("- (void)retrieveAndViewItem:(id)item\n{", 1)[1].split("- (void)queryOutlineView:", 1)[0]
        self.assertLess(action.index("beginWithStudyUID:"), action.index("[self retrieve:"))
        self.assertIn("localImagesAvailableWithStudyUID:", self.query)
        self.assertIn("lookupDuration: CFAbsoluteTimeGetCurrent() - lookupStarted", self.query)
        self.assertIn("transferFinishedWithStudyUID:", self.query)

    def test_benchmark_has_bounded_non_identifying_console_output(self):
        self.assertIn("UUID().uuidString.prefix(8)", self.benchmark)
        self.assertIn("sessions.count >= 32", self.benchmark)
        self.assertIn("CACurrentMediaTime() - 900", self.benchmark)
        self.assertIn("session.refreshCount < 120", self.benchmark)
        self.assertIn('object(forKey: "HorosQueryViewerBenchmark")', self.benchmark)
        for call in self.benchmark.split("NSLog(")[1:]:
            arguments = call.split(")", 1)[0]
            for identifier in ("studyUID", "seriesUID", "patient", "srcFile"):
                self.assertNotIn(identifier, arguments)

    def test_benchmark_measures_presentation_not_command_submission(self):
        track = self.renderer.split("private func trackRetrievalPresentation", 1)[1].split("func draw(in", 1)[0]
        self.assertIn("drawable.addPresentedHandler", track)
        self.assertIn("presented.presentedTime", track)
        self.assertIn("DispatchQueue.main.async", track)
        self.assertIn("if timestamp > 0 { report(timestamp) }", track)
        self.assertEqual(self.renderer.count("trackRetrievalPresentation(of: drawable, commandBuffer: commandBuffer)"), 3)
        self.assertIn('session.recordedStages.insert(stage).inserted', self.benchmark)

    def test_benchmark_separates_draw_scheduling_from_gpu_completion_and_presentation(self):
        for stage in ("first_draw_attempt", "draw_waiting_for_texture", "draw_waiting_for_drawable",
                      "first_drawable_ready", "first_submitted", "first_command_completed",
                      "first_command_failed", "first_unpresented_drawable"):
            self.assertIn(f'"{stage}"', self.renderer)
        track = self.renderer.split("private func trackRetrievalPresentation", 1)[1].split("func draw(in", 1)[0]
        self.assertIn("commandBuffer.addCompletedHandler", track)
        self.assertIn("buffer.status == .completed", track)
        self.assertNotIn("waitUntilCompleted", track)
        self.assertIn('timestampHandler("first_presented", frames: frames)', self.benchmark)

    def test_benchmark_separates_initial_work_and_live_refresh_work(self):
        for stage in ("launcher_enter", "window_created", "window_shown", "initial_scout_build", "initial_scout_apply"):
            self.assertIn(f'mark("{stage}"', self.launcher)
        self.assertIn('mark("first_slice_ready"', self.renderer)
        self.assertIn('mark("volume_ready"', self.renderer)
        self.assertIn("buildDuration: applyStarted - buildStarted", self.launcher)
        self.assertIn("applyDuration: CACurrentMediaTime() - applyStarted", self.launcher)

    def test_blend_glass_width_is_determined_by_its_contents(self):
        self.assertNotIn("overlayBlendGlassView.widthAnchor.constraint(equalToConstant:", self.pane)
        self.assertIn("overlayBlendSlider.widthAnchor.constraint(equalToConstant: 180)", self.pane)
        self.assertIn("copyAnimatedGIFButton.widthAnchor.constraint(equalToConstant: 30)", self.pane)


if __name__ == "__main__":
    unittest.main()
