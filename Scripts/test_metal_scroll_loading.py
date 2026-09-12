"""Non-build contracts for background slice preparation and atomic presentation."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
RENDERER = (SOURCES / "MetalViewerRenderer.swift").read_text()
VIEW = (SOURCES / "MetalImageView.swift").read_text()
PANE = (SOURCES / "MetalViewerPaneView.swift").read_text()


def method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class MetalScrollLoadingTests(unittest.TestCase):
    def test_momentum_scales_with_stack_length_with_bounded_gain(self):
        formula = method(VIEW, "private static func stackMomentumPointsPerSlice(sliceCount:")
        bounds = re.search(r"CGFloat\(min\(max\(sliceCount, (\d+)\), ([\d_]+)\)\)", formula)
        self.assertIsNotNone(bounds)
        minimum, maximum = (int(value.replace("_", "")) for value in bounds.groups())
        reference = re.search(r"return momentumScrollPointsPerSlice \* (\d+) / boundedSliceCount", formula)
        self.assertIsNotNone(reference)
        baseline = float(re.search(r"momentumScrollPointsPerSlice: CGFloat = (\d+)", VIEW)[1])

        def points_per_slice(count):
            return baseline * int(reference[1]) / min(max(count, minimum), maximum)

        # The same momentum delta traverses about the same proportion of each stack.
        self.assertAlmostEqual(baseline / points_per_slice(34), 0.34)
        self.assertAlmostEqual(baseline / points_per_slice(304), 3.04)
        self.assertEqual(points_per_slice(100), baseline)
        self.assertAlmostEqual(points_per_slice(34) * 34, points_per_slice(304) * 304)
        for count in (-1, 0, 1, 10, 34, 100, 304, 1_000, 100_000):
            with self.subTest(count=count):
                self.assertGreater(points_per_slice(count), 0)
                self.assertGreaterEqual(points_per_slice(count), baseline / 10)
                self.assertLessEqual(points_per_slice(count), baseline * 10)

    def test_direct_wheel_and_mpr_scrolling_keep_their_existing_sensitivity(self):
        scroll = method(VIEW, "override func scrollWheel(with event:")
        self.assertIn("renderer.displayMode == .stack2D\n                ? Self.stackMomentumPointsPerSlice(sliceCount: renderer.pixList.count)\n                : Self.momentumScrollPointsPerSlice", scroll)
        self.assertIn("event.momentumPhase.isEmpty\n                ? Self.preciseScrollPointsPerSlice : momentumPointsPerSlice", scroll)
        self.assertIn("private static let preciseScrollPointsPerSlice: CGFloat = 18", VIEW)
        self.assertIn("stepThroughCurrentMode(by: delta > 0 ? 1 : -1", scroll)
        self.assertIn("preciseScrollSliceAccumulator -= CGFloat(stepCount) * scrollPointsPerSlice", scroll)

    def test_scroll_accumulates_from_requested_not_last_displayed_index(self):
        step = method(RENDERER, "func stepSlice(by delta:")
        self.assertIn("(requestedSliceIndex ?? currentSliceIndex) - delta", step)
        self.assertIn("setSliceIndex(nextIndex)", step)
        self.assertNotIn("loadSlice(", step)
        select = method(RENDERER, "func setSliceIndex(_ index:")
        self.assertLess(select.index("requestScrollSlice(at:"), select.index("currentSliceIndex ="))

    def test_old_image_remains_until_complete_latest_result(self):
        request = method(RENDERER, "private func requestScrollSlice(at index:")
        self.assertIn("cancelPendingSliceLoads()", request)
        self.assertIn("guard reloadCurrent || index != currentSliceIndex else { return }", request)
        for guard in ("self.sliceRequestGeneration == generation", "self.displayMode == .stack2D",
                      "self.pixList[index] === pix", "guard let prepared else"):
            self.assertLess(request.index(guard), request.index("self.currentSliceIndex = index"))
        self.assertIn("self.loadSlice(at: index, prepared: prepared)", request)

    def test_pending_work_cancels_on_series_mode_and_sync_load(self):
        cancel = method(RENDERER, "private func cancelPendingSliceLoads()")
        for statement in ("sliceRequestGeneration &+= 1", "requestedSliceIndex = nil", "scrollSliceLoader.cancel()"):
            self.assertIn(statement, cancel)
        self.assertIn("cancelPendingSliceLoads()", method(RENDERER, "func setDisplayMode(_ mode:"))
        self.assertIn("if prepared == nil { cancelPendingSliceLoads() }",
                      method(RENDERER, "private func loadSlice(at index: Int,"))
        self.assertIn("scrollSliceLoader.cancel()", method(RENDERER, "deinit {"))

    def test_live_refresh_preserves_the_pending_source_frame(self):
        refresh = method(RENDERER, "func setPixList(_ newPixList:")
        self.assertIn("let pendingPix = requestedSliceIndex.flatMap", refresh)
        self.assertIn("$0.srcFile == requestedPix.srcFile && $0.frameNo == requestedPix.frameNo", refresh)
        self.assertIn("requestScrollSlice(at: pendingIndex)", refresh)

    def test_worker_queue_is_bounded_and_target_precedes_prefetch(self):
        loader = MODELS.split("final class MetalStackSliceLoader:", 1)[1].split("final class MetalSeriesTextureCache", 1)[0]
        for fragment in ("maxConcurrentOperationCount = 1", "countLimit = 8", "totalCostLimit = 32 * 1_024 * 1_024",
                         "queue.cancelAllOperations()", "[0, 1, -1, 2, -2]", ".veryHigh : .low"):
            self.assertIn(fragment, loader)
        self.assertIn("operation.addExecutionBlock", loader)
        self.assertIn("[weak self, weak operation]", loader)
        self.assertIn("DispatchQueue.main.async", loader)
        self.assertGreaterEqual(loader.count("operation.isCancelled == false"), 3)

    def test_worker_rechecks_file_after_pixels_and_annotations(self):
        prepare = method(MODELS, "private func prepare(pix:")
        self.assertIn("reader.fileRevision == revision", prepare)
        self.assertIn("pixels.fileRevision == revision", prepare)
        self.assertIn("pixels.width == width, pixels.height == height", prepare)
        self.assertIn("frame=\\(frame)", prepare)
        self.assertLess(prepare.index("MetalViewerImageMetadata(pix: pix)"),
                        prepare.index("guard revision == SwiftDICOMFileRevision(contentsOfFile: path)"))
        self.assertLess(prepare.index("guard revision == SwiftDICOMFileRevision(contentsOfFile: path)"),
                        prepare.index("cache.setObject"))

    def test_annotation_preferences_refresh_even_without_another_scroll(self):
        refresh = method(RENDERER, "private func refreshAnnotationPreferences()")
        self.assertIn("guard preferences != annotationPreferences", refresh)
        self.assertIn("requestedSliceIndex ?? currentSliceIndex, reloadCurrent: true", refresh)
        prepare = method(MODELS, "private func prepare(pix:")
        self.assertIn("annotationRevisions.removeAllObjects()", prepare)
        self.assertIn("pix.reloadAnnotations()", prepare)

    def test_unpositioned_images_can_still_scroll_without_a_main_thread_geometry_read(self):
        prepare = method(MODELS, "private func prepare(pix:")
        self.assertIn("let geometry = cached?.geometry ?? MetalViewerSliceGeometry(pix: pix)", prepare)
        self.assertNotIn("let geometry =", prepare.split("guard let pixels", 1)[1])
        self.assertIn("pixels.width == width, pixels.height == height", prepare)
        load = method(RENDERER, "private func loadSlice(at index: Int,")
        self.assertIn("if let prepared {\n            sliceGeometry = prepared.geometry", load)
        self.assertIn("prepared?.pixels.width", load)

    def test_readout_reuses_prepared_pixels_without_io(self):
        sample = method(VIEW, "private func mouseAnnotationState(normalizedImagePoint:")
        self.assertIn("renderer.currentSlicePixels", sample)
        self.assertIn("renderer.currentSliceGeometry", sample)
        for forbidden in ("MetalStoredInt16PixelData(pix:", "SwiftDICOMReader", "MetalViewerSliceGeometry(pix:"):
            self.assertNotIn(forbidden, sample)
        self.assertNotIn("mouseSampleStoredPixels", VIEW)
        self.assertLess(VIEW.index("self.updateMouseAnnotationState(from: point, notify: false)"),
                        VIEW.index("self.titleDidChange?(state)"))

    def test_live_annotations_use_prepared_snapshot(self):
        annotation = method(PANE, "private func updateAnnotationOverlay()")
        self.assertIn("metalView.renderer.currentImageMetadata", annotation)
        self.assertIn("metalView.renderer.currentSliceGeometry", annotation)
        self.assertNotIn("ImageMetadata(pix:", annotation)
        self.assertNotIn("MetalViewerSliceGeometry(pix:", annotation)
        load = method(RENDERER, "private func loadSlice(at index: Int,")
        self.assertIn("prepared?.metadata ?? MetalViewerImageMetadata(pix: pix)", load)
        self.assertIn("sliceGeometry = prepared.geometry", load)
        self.assertIn("immediateStackSliceTextureEntry = prepared.textureEntry", load)
        self.assertLess(load.index("currentSlicePixels = storedPixels"), load.index("stateDidChange?"))

    def test_volume_readback_requires_exact_source_and_never_substitutes(self):
        readback = method(MODELS, "func storedSlice(at index:")
        for check in ("sourceRevisions[reader.sourcePath] == reader.fileRevision", "texture.storageMode == .shared",
                      "substitutedSliceIndexes.contains(index) == false", "index < dimensions.z"):
            self.assertLess(readback.index(check), readback.index("texture.getBytes"))
        self.assertNotIn("storedPixelFrame(", readback)
        self.assertIn("fileRevision: reader.fileRevision", readback)
        build = method(MODELS, "private func buildStoredInt16Entry(")
        self.assertIn("sourceRevisions: sourceRevisions", build)
        self.assertIn("substitutedSliceIndexes: substitutedSliceIndexes", build)


if __name__ == "__main__":
    unittest.main()
