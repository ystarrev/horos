"""Non-build checks for background skin preparation, cache lifetime and coalescing."""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_volume import SOURCE, SOURCES, declaration
from test_metal4_scout import declaration as extract


ENSURE = declaration("private func ensureSkinMaskTexture(")
WORKER = declaration("private static func makeSkinShellMask(")
BACKGROUND = extract("DispatchQueue.global(qos: .userInitiated).async", ENSURE)
COMPLETION = extract("DispatchQueue.main.async", BACKGROUND)
RESUME = declaration("private func resumeSkinPreparationIfNeeded(")
INVALIDATE = declaration("private func invalidateSkinPreparation(")
DEPTH = declaration("func setSkinClipDepthMM(")


class MetalSkinBackgroundTests(unittest.TestCase):
    def test_only_one_job_runs_and_new_settings_are_read_after_completion(self):
        self.assertLess(ENSURE.index("skinWorkInFlight == false"), ENSURE.index("cpuVolumeData()"))
        self.assertLess(ENSURE.index("skinWorkInFlight = true"), ENSURE.index("DispatchQueue.global"))
        self.assertLess(COMPLETION.index("self.skinWorkInFlight = false"),
                        COMPLETION.index("self.resumeSkinPreparationIfNeeded()"))
        self.assertIn("pendingTrajectoryCompletion != nil", RESUME)
        self.assertIn("showSkin == false || showSkinSurface || needsTrajectory", RESUME)
        self.assertEqual(ENSURE.count("DispatchQueue.global"), 1)

    def test_worker_uses_value_snapshots_and_never_retains_the_viewer(self):
        work = BACKGROUND.split("DispatchQueue.main.async", 1)[0]
        self.assertNotRegex(work, r"\bself\.|\b(?:pixList|DCMPix|UserDefaults|cpuVolumeData)\b")
        self.assertIn("[weak self]", work)
        self.assertIn("[weak self]", COMPLETION)
        self.assertIn("autoreleasepool", work)
        for name in ("cpuVolumeData()", "skinForegroundThreshold()", "Self.isCTVolume(pixList)",
                     "let dimensions = volumeDimensions", "let spacing = voxelSpacing"):
            self.assertLess(ENSURE.index(name), ENSURE.index("DispatchQueue.global"))
        for name in ("makeSkinShellMask", "prepareSkinEnvelope", "extractSkinSurface", "makeSkinDistanceMask"):
            method = declaration(f"private static func {name}(")
            self.assertNotRegex(method, r"\b(?:pixList|DCMPix|UserDefaults|cpuVolumeData)\b|\bself\.")

    def test_volume_and_depth_generations_protect_installation(self):
        volume_check = COMPLETION.index("volumeGeneration == self.skinVolumeGeneration")
        for name in ("self.skinEnvelopePreparation =", "self.skinMaskTexture =", "self.skinSurfaceVertexBuffer ="):
            self.assertLess(volume_check, COMPLETION.index(name))
        mask_install = extract("if maskGeneration == self.skinMaskGeneration", COMPLETION)
        self.assertIn("self.skinMaskTexture =", mask_install)
        self.assertNotIn("self.skinSurfaceVertexBuffer", mask_install)
        self.assertIn("skinMaskGeneration &+= 1", DEPTH)
        self.assertNotIn("skinVolumeGeneration", DEPTH)
        self.assertNotIn("skinWorkCancellation", DEPTH)  # Finish and keep reusable envelope/mesh.

    def test_one_bounded_cache_is_reused_before_any_voxel_processing(self):
        self.assertIn("skinEnvelopePreparation?.threshold == thresholdResult.threshold", ENSURE)
        self.assertIn("result.preparation.envelope.count <= MetalViewerCachePolicy.renderVolumeCacheBytes / 2", COMPLETION)
        self.assertIn("cachedPreparation ?? volumeData.withUnsafeBytes", WORKER)
        self.assertNotIn("skinEnvelopePreparation = nil", DEPTH)
        cache = declaration("private struct SkinEnvelopePreparation")
        self.assertEqual(cache.count("[UInt8]"), 2)
        self.assertNotRegex(cache, r"Data|MTL|DCMPix")
        distance = declaration("private static func makeSkinDistanceMask(")
        self.assertIn("var mask = Self.invertedMask(preparation.envelope)", distance)
        self.assertIn("maximumDistanceMM: shellThicknessMM", distance)
        self.assertNotIn("prepareSkinEnvelope", distance)

    def test_surface_only_request_does_not_recompute_existing_distance_mask(self):
        self.assertIn("includeMask: needsMask", ENSURE)
        self.assertIn("let mask = includeMask ? makeSkinDistanceMask(", WORKER)
        self.assertIn("if includeSurface {", WORKER)
        self.assertIn("surfaceVertexFloatData = extractSkinSurface(", WORKER)

    def test_volume_replacement_clears_all_geometry_caches_without_overlapping_jobs(self):
        apply = declaration("private func applyPreparedRenderVolume(")
        self.assertLess(apply.index("invalidateSkinPreparation()"), apply.index("volumeTexture ="))
        self.assertLess(apply.index("histogramModel ="), apply.index("resumeSkinPreparationIfNeeded()"))
        for name in ("skinEnvelopePreparation", "skinMaskTexture", "skinSurfaceVertexBuffer", "skinSurfaceVertexFloatData"):
            self.assertIn(f"{name} = nil", INVALIDATE)
        self.assertIn("skinSurfaceWorldPoints = []", INVALIDATE)
        self.assertIn("skinVolumeGeneration &+= 1", INVALIDATE)
        self.assertIn("skinWorkCancellation?.cancel()", INVALIDATE)
        self.assertNotIn("skinWorkInFlight = false", INVALIDATE)

    def test_close_and_reconfigure_cancel_work_and_release_cached_input(self):
        view = (SOURCES / "Metal3DVolumeView.swift").read_text()
        window = (SOURCES / "Metal3DViewerWindowController.swift").read_text()
        configure = extract("func configure(pixList:", view)
        self.assertLess(configure.index("renderer?.stopSkinPreparation()"), configure.index("let renderer ="))
        self.assertIn("volumeView.stopSkinPreparation()", extract("func windowWillClose(", window))
        stop = declaration("func stopSkinPreparation(")
        for line in ("skinWorkStopped = true", "pendingTrajectoryCompletion = nil",
                     "invalidateSkinPreparation()", "cachedCPUVolumeData = nil"):
            self.assertIn(line, stop)
        self.assertLess(COMPLETION.index("self.skinWorkStopped == false"), COMPLETION.index("self.skinEnvelopePreparation ="))
        self.assertIn("skinWorkCancellation?.cancel()", extract("deinit {", SOURCE))

    def test_cancellation_is_locked_and_checked_between_expensive_stages(self):
        token = declaration("private final class SkinWorkCancellation")
        self.assertEqual(token.count("lock.lock()"), 2)
        self.assertEqual(token.count("lock.unlock()"), 2)
        self.assertGreaterEqual(WORKER.count("cancellation.isCancelled == false"), 3)
        prep = declaration("private static func prepareSkinEnvelope(")
        self.assertIn("guard cancellation.isCancelled == false", prep)
        self.assertIn("guard cancellation.isCancelled == false", declaration("private static func extractSkinSurface("))

    def test_failed_jobs_do_not_restart_on_every_draw(self):
        for flag in ("skinMaskExtractionAttempted", "skinSurfaceExtractionAttempted"):
            self.assertIn(f"{flag} == false", ENSURE)
            self.assertLess(ENSURE.index(f"{flag} = true"), ENSURE.index("cpuVolumeData()"))
            self.assertNotIn(f"{flag} = false", COMPLETION)
            self.assertIn(f"{flag} = false", DEPTH)
        self.assertIn("if volumeGeneration == self.skinVolumeGeneration, let result", COMPLETION)
        self.assertIn("self.resumeSkinPreparationIfNeeded()", COMPLETION)

    def test_trajectory_waits_for_surface_and_invalidated_requests_are_dropped(self):
        request = declaration("func showInitialSurgicalTrajectory(")
        finish = declaration("private func finishPendingSurgicalTrajectory(")
        self.assertIn("completion: @escaping (String?) -> Void", request)
        self.assertIn("pendingTrajectoryCompletion = completion", request)
        self.assertIn("skinWorkInFlight || volumeTexture == nil", finish)
        self.assertLess(finish.index("pendingTrajectoryCompletion = nil"), finish.index("completion(makeInitial"))
        for marker in ("func clearTumorSegmentation(", "func setTumorSegmentationLabelmap(", "func setSkinClipDepthMM("):
            self.assertIn("pendingTrajectoryCompletion = nil", declaration(marker))

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS SDK")
    def test_actual_scheduler_and_cpu_algorithms_typecheck_with_surface_bridge(self):
        # Real Foundation/Metal APIs and the real Objective-C bridge; unrelated renderer
        # methods are stubbed. Type-check only, no app build or GPU execution.
        harness = "import Foundation\nimport Metal\nimport simd\n"
        for kind in ("Metal3DSkinDistanceNode", "Metal3DSkinDistanceNeighbor", "Metal3DSkinDistanceHeap"):
            harness += declaration(f"private struct {kind}") + "\n"
        harness += """
final class DCMPix {}
private final class Metal3DVolumeRenderer {
    private var deviceRef: MTLDevice { fatalError() }
    private let volumeDimensions = SIMD3<Int>(11, 13, 7)
    private let voxelSpacing = SIMD3<Float>(0.4, 0.6, 1.3)
    private let pixList = [DCMPix]()
    private var surgicalTrajectory: Int?
    private var tumorCentroidWorldPosition: SIMD3<Float>?
    var contentDidChange: (() -> Void)?
    private func cpuVolumeData() -> Data? { nil }
    private func skinForegroundThreshold() -> (threshold: Float, method: String) { (-500, "ctHU") }
    private static func isCTVolume(_ pixList: [DCMPix]) -> Bool { true }
    private func makeSkinMaskTexture(mask: [UInt8]) -> MTLTexture? { nil }
    private func makeSkinSurfaceVertexBuffer(vertexFloatData: Data) -> (buffer: MTLBuffer, count: Int)? { nil }
    private func worldPositions(fromSurfaceVertexFloatData data: Data) -> [SIMD3<Float>] { [] }
    private func makeInitialSurgicalTrajectory() -> String? { nil }
"""
        fields = ("skinSurfaceWorldPoints", "skinEnvelopePreparation", "skinWorkCancellation", "skinWorkInFlight",
                  "skinWorkStopped", "skinVolumeGeneration", "skinMaskGeneration", "pendingTrajectoryCompletion",
                  "skinMaskTexture", "skinSurfaceVertexBuffer", "skinSurfaceVertexCount", "skinSurfaceVertexFloatData",
                  "skinMaskExtractionAttempted", "skinSurfaceExtractionAttempted", "showSkin", "showSkinSurface",
                  "currentSkinClipDepthMM", "cachedCPUVolumeData", "volumeTexture", "trajectoryHandleHovered",
                  "suppressProjectedTrajectoryOutline", "skinClipDepthPreferenceKey")
        for name in fields:
            harness += re.search(rf"^    private(?:\(set\))? (?:static )?(?:let|var) {name}\b[^\n]+", SOURCE, re.M)[0] + "\n"
        for marker in ("private struct SkinEnvelopePreparation", "private final class SkinWorkCancellation",
                       "private struct SkinShellExtractionResult", "private enum BinaryMorphologyOperation", "func stopSkinPreparation(",
                       "private func invalidateSkinPreparation(", "private func resumeSkinPreparationIfNeeded(",
                       "private func ensureSkinMaskTexture(", "func setSkinClipDepthMM(",
                       "private func skinShellThicknessMM(", "func showInitialSurgicalTrajectory(",
                       "private func finishPendingSurgicalTrajectory("):
            harness += declaration(marker) + "\n"
        for name in ("makeSkinShellMask", "prepareSkinEnvelope", "extractSkinSurface", "makeSkinDistanceMask",
                     "exteriorForegroundSurfaceMask", "surfaceMaskByOpeningZCropCaps", "largestConnectedSurfaceComponentMask",
                     "skinEnvelopeForegroundMask", "skinExternalAirProbeRadiusMM", "externalAirReconstructedEnvelopeMask",
                     "binaryErodedMask", "binaryDilatedMask", "binaryMorphology1D", "floodFillExteriorAirCore",
                     "axialClosedEnvelopeMask", "invertedMask", "markObjectWithinPhysicalDistance"):
            harness += declaration(f"private static func {name}(") + "\n"
        harness += "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-skin-background-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                "-import-objc-header", str(SOURCES / "Metal3DSurfaceExtractor.h"),
                str(path), str(SOURCES / "MetalPerformanceTrace.swift"),
                str(SOURCES / "MetalViewerCachePolicy.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
