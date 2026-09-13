"""Source-contract checks for imaging cache reuse; does not build or launch Horos."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
RENDERER = (SOURCES / "MetalViewerRenderer.swift").read_text()
IMAGE_VIEW = (SOURCES / "MetalImageView.swift").read_text()
PREVIEW = (SOURCES / "MetalPreviewImageView.swift").read_text()
VOLUME = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
SERIES = MODELS.split("final class MetalSeriesTextureCache {", 1)[1].split(
    "\nenum MetalDynamicDetectionConfidence", 1
)[0]


def method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class MetalImagingReuseTests(unittest.TestCase):
    def test_contour_geometry_compares_every_sampling_input(self):
        geometry = RENDERER.split("struct MetalMPRROISliceGeometry: Equatable {", 1)[1]
        fields = geometry.split("    func worldPoint", 1)[0]
        for field in ("planeRawValue", "imageRect", "topLeftWorld", "topRightWorld",
                      "bottomLeftWorld", "bottomRightWorld"):
            self.assertIn(f"let {field}:", fields)

    def test_display_changes_redraw_without_discarding_contours(self):
        callback = IMAGE_VIEW.split("renderer.stateDidChange = { [weak self] state in", 1)[1]
        callback = callback.split("\n        }", 1)[0]
        self.assertNotIn("studyROIContourCache", callback)
        self.assertIn("mprPreviewOverlayView.needsDisplay = true", callback)
        layout = method(IMAGE_VIEW, "override func layout()")
        self.assertNotIn("studyROIContourCache = nil", layout)
        self.assertIn("mprPreviewOverlayView.needsDisplay = true", layout)

    def test_contour_reuse_requires_same_roi_revision_and_actual_geometry(self):
        draw = method(IMAGE_VIEW, "fileprivate func drawStudyROIOverlay()")
        self.assertIn("let slices = studyROISliceGeometries()", draw)
        self.assertIn("existing.storeRevision == store.revision", draw)
        self.assertIn("existing.roiIdentifier == roi.id", draw)
        self.assertIn("existing.slices == slices", draw)
        self.assertNotIn("stateDescription", draw)
        self.assertLess(draw.index("cache = existing"), draw.index("} else {"))
        self.assertLess(draw.index("} else {"), draw.index("MetalStudyROIContourBuilder.segments"))
        geometry = method(IMAGE_VIEW, "private func studyROISliceGeometries()")
        self.assertIn("renderer.mprROISliceGeometries(in: bounds)", geometry)
        self.assertIn("applyingWorldTransform(studyROICurrentToCanonicalTransform)", geometry)

    def test_store_changes_and_explicit_edits_still_discard_contours(self):
        for signature in ("func configureStudyROI(", "func refreshStudyROIOverlay()"):
            body = method(IMAGE_VIEW, signature)
            self.assertIn("studyROIContourCache = nil", body)
            self.assertIn("mprPreviewOverlayView.needsDisplay = true", body)

    def test_anchor_hits_use_current_geometry_even_before_redraw(self):
        hit = method(IMAGE_VIEW, "private func studyROIAnchorHit(")
        self.assertIn("let slices = studyROISliceGeometries()", hit)
        self.assertNotIn("studyROIContourCache", hit)
        self.assertIn("slice.screenPoint(for: roi.anchors[anchorIndex].vector)", hit)

    def test_series_request_binds_identity_to_pixels_and_device(self):
        request = SERIES.split("struct Request {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("let key: String", request)
        self.assertIn("fileprivate let pixList: [DCMPix]", request)
        self.assertIn("fileprivate let device: MTLDevice", request)
        factory = method(SERIES, "func makeRequest(")
        self.assertIn("pixList.contains(where: Self.isDICOMSegmentation) == false", factory)
        self.assertIn('device.registryID', factory)
        self.assertIn('pix.value(forKey: "frameNo")', factory)
        self.assertIn('components.append("\\(index):\\(revision.cacheKey):f\\(frameNumber)")', factory)
        self.assertIn('Request(key: components.joined(separator: "|"), pixList: pixList, device: device,', factory)
        self.assertIn('sourceRevisions: sourceRevisions)', factory)

    def test_lookup_does_not_reconstruct_identity(self):
        for signature in ("func cachedEntry(", "func isEntryKnownUnavailable(",
                          "func requestEntry(\n        for request: Request,"):
            with self.subTest(signature=signature):
                body = method(SERIES, signature)
                self.assertIn("request.key", body)
                self.assertNotIn("makeRequest(", body)
                self.assertNotIn("joined(separator:", body)
                self.assertIn("lock.lock()", body)

    def test_all_viewer_lookups_prepare_identity_once(self):
        for source, signature in (
            (RENDERER, "private func requestStackVolumeTexture()"),
            (RENDERER, "private func requestOverlayVolumeTexture()"),
            (PREVIEW, "private func requestVolumeTexture("),
            (VOLUME, "private func requestVolumeTexture()"),
        ):
            with self.subTest(signature=signature):
                body = method(source, signature)
                self.assertEqual(body.count("MetalSeriesTextureCache.shared.makeRequest("), 1)
                self.assertIn("cachedEntry(for: request)", body)
                self.assertRegex(body, r"requestEntry\(\s*for: request")
                self.assertNotIn("MetalSeriesTextureCache.shared.key(", body)
                if "requestOverlay" not in signature:
                    self.assertIn("isEntryKnownUnavailable(for: request)", body)

    def test_one_shot_request_preserves_async_failure_and_delegates(self):
        request = method(SERIES, "func requestEntry(\n        for pixList: [DCMPix],")
        self.assertIn("guard let request = makeRequest(for: pixList, device: device)", request)
        self.assertIn("DispatchQueue.main.async {\n                completion(nil)", request)
        self.assertIn("requestEntry(for: request, decodedSliceSeed: decodedSliceSeed, completion: completion)", request)

    def test_prepared_request_keeps_deduplication_and_initial_slice_reuse(self):
        request = method(SERIES, "func requestEntry(\n        for request: Request,")
        self.assertIn("inFlightCompletions[key]?.append(completion)", request)
        self.assertIn("pixList: request.pixList", request)
        self.assertIn("device: request.device", request)
        self.assertIn("decodedSliceSeed: decodedSliceSeed", request)
        self.assertIn("self.finishRequest(key: key, entry: entry)", request)

    def test_volume_geometry_changes_invalidate_scale_and_seed_mesh(self):
        for field in ("baseVolumeDimensions", "fixedVoxelToWorld", "baseVolumeCenterWorld"):
            declaration = RENDERER.split(f"private var {field} =", 1)[1].split("\n    }", 1)[0]
            self.assertIn("didSet { invalidateMPRVolumeGeometryCaches() }", declaration)
        invalidation = method(RENDERER, "private func invalidateMPRVolumeGeometryCaches()")
        self.assertIn("cachedMPRDisplayScale = nil", invalidation)
        self.assertIn("mprTumourSeedMesh = nil", invalidation)
        seeds = RENDERER.split("private var tumourSeeds:", 1)[1].split("\n    }", 1)[0]
        self.assertIn("didSet { mprTumourSeedMesh = nil }", seeds)

    def test_seed_draw_reuses_buffer_but_updates_camera_uniforms(self):
        prepare = method(RENDERER, "private func prepareMPRTumourSeedMeshIfNeeded()")
        self.assertIn("guard mprTumourSeedMesh == nil, tumourSeeds.isEmpty == false", prepare)
        self.assertLess(prepare.index("guard"), prepare.index("makeMPRTumourSeedSphereVertices()"))
        self.assertIn("mprTumourSeedMesh = (buffer: buffer, vertexCount: vertices.count)", prepare)
        draw = method(RENDERER, "private func drawMPR(in view:")
        seed_draw = draw.split("prepareMPRTumourSeedMeshIfNeeded()", 1)[1].split("let highlightVertices", 1)[0]
        self.assertIn("frame.setVertexBuffer(seedMesh.buffer", seed_draw)
        self.assertIn("frame.setUniforms(&uniforms", seed_draw)
        self.assertIn("vertexCount: seedMesh.vertexCount", seed_draw)
        self.assertNotIn("makeBuffer", seed_draw)
        self.assertNotIn("makeMPRTumourSeedSphereVertices", draw)

    def test_scene_scale_reuses_exact_existing_formula(self):
        scale = method(RENDERER, "private func mprDisplayScale()")
        self.assertIn("if let cachedMPRDisplayScale { return cachedMPRDisplayScale }", scale)
        self.assertIn(".map { simd_length(mprDisplayWorldPosition(for: $0) - baseVolumeCenterWorld) }", scale)
        self.assertIn("let scale = 0.92 / max(maxDistance, 0.0001)", scale)
        self.assertIn("cachedMPRDisplayScale = scale", scale)


if __name__ == "__main__":
    unittest.main()
