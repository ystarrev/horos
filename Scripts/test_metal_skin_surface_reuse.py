"""Non-build guards for reusing the skin mesh when only removal depth changes."""

import unittest

from test_metal4_volume import SOURCE, declaration
from test_metal4_scout import declaration as source_declaration


SET_DEPTH = declaration("func setSkinClipDepthMM(")
ENSURE = declaration("private func ensureSkinMaskTexture(")
EXTRACT = declaration("private static func extractSkinSurface(")


class MetalSkinSurfaceReuseTests(unittest.TestCase):
    def test_depth_change_retains_depth_independent_mesh_and_world_points(self):
        for field in ("skinSurfaceVertexBuffer", "skinSurfaceVertexCount",
                      "skinSurfaceVertexFloatData", "skinSurfaceWorldPoints"):
            self.assertNotRegex(SET_DEPTH, rf"\b{field}\s*=")

    def test_depth_change_still_invalidates_mask_and_trajectory_and_allows_retry(self):
        for statement in (
            "let clampedDepth = min(max(depthMM, 0), 20)",
            "guard abs(currentSkinClipDepthMM - clampedDepth) > 0.01 else { return }",
            "currentSkinClipDepthMM = clampedDepth",
            "UserDefaults.standard.set(clampedDepth, forKey: Self.skinClipDepthPreferenceKey)",
            "skinMaskTexture = nil",
            "skinMaskExtractionAttempted = false",
            "skinSurfaceExtractionAttempted = false",
            "surgicalTrajectory = nil",
            "trajectoryHandleHovered = false",
            "suppressProjectedTrajectoryOutline = false",
            "if showSkin == false || showSkinSurface",
            "ensureSkinMaskTexture(includeSurface: showSkinSurface)",
        ):
            self.assertIn(statement, SET_DEPTH)
        self.assertLess(SET_DEPTH.index("skinMaskTexture = nil"), SET_DEPTH.index("ensureSkinMaskTexture("))
        self.assertNotIn("cachedCPUVolumeData = nil", SET_DEPTH)

    def test_cached_surface_skips_extraction_but_missing_or_failed_surface_can_build(self):
        for condition in (
            "let hasSurface = skinSurfaceVertexBuffer != nil &&",
            "skinSurfaceVertexCount > 0 &&",
            "skinSurfaceVertexFloatData != nil",
            "let needsMask = skinMaskTexture == nil && skinMaskExtractionAttempted == false",
            "let needsSurface = includeSurface && hasSurface == false && skinSurfaceExtractionAttempted == false",
            "(needsSurfacePoints && skinSurfaceVertexFloatData == nil && skinSurfaceExtractionAttempted == false)",
            "includeSurface: buildSurface, cancellation: cancellation",
        ):
            self.assertIn(condition, ENSURE)
        install = source_declaration("if buildSurface, let vertexFloatData", ENSURE)
        for field in ("skinSurfaceVertexBuffer", "skinSurfaceVertexCount", "skinSurfaceVertexFloatData"):
            self.assertEqual(ENSURE.count(f"self.{field} ="), 1)
            self.assertIn(f"self.{field} =", install)
        self.assertIn("self.skinMaskTexture = self.makeSkinMaskTexture(mask: mask)", ENSURE)

    def test_mesh_generation_has_no_dependency_on_removal_depth(self):
        surface = EXTRACT
        self.assertNotRegex(surface, r"shellThicknessMM|skinShellThicknessMM|currentSkinClipDepthMM")
        self.assertIn("Metal3DSurfaceExtractor.extractSkinSurface(", surface)
        self.assertIn("Metal3DSurfaceExtractor.filterSurfaceVertexFloatData(", surface)
        self.assertIn("threshold: thresholdResult.threshold", surface)
        self.assertIn("openMinimumZCap: true", surface)
        self.assertEqual(ENSURE.count("skinShellThicknessMM()"), 1)
        distance = declaration("private static func makeSkinDistanceMask(")
        self.assertEqual(distance.count("maximumDistanceMM: shellThicknessMM"), 1)
        self.assertIn("mask: &mask", distance)

    def test_surface_cache_is_local_to_immutable_source_geometry(self):
        for declaration in (
            "private let pixList: [DCMPix]",
            "private let sourceCropBounds: Metal3DVolumeCropBounds",
            "private let volumeDimensions: SIMD3<Int>",
            "private let voxelSpacing: SIMD3<Float>",
            "private var skinSurfaceVertexBuffer: MTLBuffer?",
            "private var skinSurfaceVertexFloatData: Data?",
            "private var skinSurfaceWorldPoints = [SIMD3<Float>]()",
        ):
            self.assertIn(declaration, SOURCE)


if __name__ == "__main__":
    unittest.main()
