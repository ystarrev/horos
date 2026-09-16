"""Source guards for immutable volume preprocessing reuse; no application builds."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
RENDERER = (SOURCES / "MetalViewerRenderer.swift").read_text()
VOLUME = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
POLICY = (SOURCES / "MetalViewerCachePolicy.swift").read_text()
LEVEL = MODELS.split("struct MetalPreparedVolumeLevel {", 1)[1].split(
    "\nfinal class MetalPreparedVolumeCache", 1
)[0]
CACHE = VOLUME.split("private final class Metal3DPreparedRenderCache {", 1)[1].split(
    "\nfinal class Metal3DVolumeRenderer", 1
)[0]


def method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class MetalPreprocessingReuseTests(unittest.TestCase):
    def test_registration_geometry_is_immutable_and_prepared_once(self):
        for field in ("voxelToWorld", "worldToVoxel", "textureDimensions",
                      "textureDimensionsUInt32", "physicalCoverage"):
            self.assertIn(f"let {field}:", LEVEL)
        self.assertEqual(LEVEL.count("simd_inverse(voxelToWorld)"), 1)
        self.assertIn("SIMD3<Int>(texture.width, texture.height, texture.depth)", LEVEL)
        self.assertIn("UInt32(texture.width), UInt32(texture.height), UInt32(texture.depth)", LEVEL)

    def test_physical_coverage_keeps_existing_formula_and_weights(self):
        self.assertIn("MetalViewerGantryTiltGeometry.voxelSpacing(from: voxelToWorld)", LEVEL)
        for axis in "xyz":
            self.assertIn(f"Float(max(dimensions.{axis}, 1)) * spacing.{axis}", LEVEL)
        self.assertIn("max(size.x * size.y * size.z, 0.0001)", LEVEL)
        weights = method(RENDERER, "private func bidirectionalMetricWeights(")
        self.assertIn("let forwardCoverage = level.0.physicalCoverage", weights)
        self.assertIn("let reverseCoverage = level.1.physicalCoverage", weights)
        self.assertIn("min(max(reverseCoverage / max(coverageTotal, 0.0001), 0.25), 0.75)", weights)
        self.assertIn("return baseIsThinSlab", weights)

    def test_all_metric_paths_use_cached_inverse_and_dimensions(self):
        for signature in ("private func directionalMetricValue(",
                          "private func primaryMetricValues(",
                          "private func registrationSupportMetricValues("):
            with self.subTest(signature=signature):
                body = method(RENDERER, signature)
                self.assertNotIn("simd_inverse(", body)
                self.assertIn(".worldToVoxel", body)
                self.assertIn(".textureDimensionsUInt32", body)
                self.assertIn(".textureDimensions", body)
                self.assertIn("job.performCompute(", body)
                self.assertIn("guard completed, job.isCancelled == false", body)
                self.assertIn("smoothedNormalizedMutualInformation(", body)

    def test_reverse_metric_still_uses_fixed_volume_inverse(self):
        primary = method(RENDERER, "private func primaryMetricValues(")
        reverse = primary.split("let reverseUniforms:", 1)[1].split("let histogramEntryCount", 1)[0]
        self.assertIn("reverseRegistrationTextureCoordinateMatrix(", reverse)
        self.assertIn("fixedVoxelToWorld: level.1.voxelToWorld", reverse)
        self.assertIn("movingWorldToVoxel: level.0.worldToVoxel", reverse)
        self.assertIn("movingTextureSize: level.0.textureDimensions", reverse)

    def test_sampling_options_are_outside_candidate_loops(self):
        for signature in ("private func primaryMetricValues(",
                          "private func registrationSupportMetricValues("):
            body = method(RENDERER, signature)
            self.assertEqual(body.count("registrationSamplingOptions(effectiveSamplingStride)"), 1)
            self.assertLess(body.index("let samplingOptions ="), body.index("let uniforms = states.map"))
        grid = method(RENDERER, "private func registrationSampleGridSize(")
        for axis in "xyz":
            self.assertIn(f"max(requestedSamplingStride.{axis}, 1)", grid)
            self.assertIn(f"(level.textureDimensions.{axis} + samplingStride.{axis} - 1) / samplingStride.{axis}", grid)

    def test_render_key_covers_source_device_geometry_and_histogram(self):
        key = CACHE.split("struct Key: Equatable {", 1)[1].split("\n    }", 1)[0]
        for field in ("sourceTextureIdentifier", "deviceRegistryID", "sourceVoxelToWorld",
                      "outputDimensions", "outputVoxelToWorld", "voxelSpacing",
                      "backgroundValue", "histogramDomain", "histogramBinCount"):
            self.assertIn(f"let {field}:", key)
        prepare = method(VOLUME, "private func prepareVolumeTexture(from entry:")
        self.assertIn("sourceTextureIdentifier: ObjectIdentifier(entry.texture)", prepare)
        self.assertIn("deviceRegistryID: deviceRef.registryID", prepare)
        for column in range(4):
            self.assertIn(f"entry.voxelToWorld.columns.{column}", prepare)
            self.assertIn(f"referenceVoxelToPatientMatrix.columns.{column}", prepare)

    def test_source_identity_remains_alive_without_retaining_pyramids_or_viewers(self):
        entry = CACHE.split("struct Entry {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("let sourceTexture: MTLTexture", entry)
        self.assertNotIn("MetalPreparedVolumeCache.Entry", entry)
        self.assertNotIn("Metal3DVolumeRenderer", entry)
        self.assertIn("lastEntry?.key == key", CACHE)

    def test_cache_hit_skips_all_gpu_preparation(self):
        prepare = method(VOLUME, "private func prepareVolumeTexture(from entry:")
        hit = prepare.split("if let cached =", 1)[1].split("\n        }", 1)[0]
        self.assertIn("applyPreparedRenderVolume(cached, sourceEntry: entry)", hit)
        self.assertIn("DispatchQueue.main.async { [weak self] in", hit)
        self.assertLess(hit.index("DispatchQueue.main.async"), hit.index("applyPreparedRenderVolume("))
        self.assertIn("return", hit)
        self.assertLess(prepare.index("if let cached ="), prepare.index("makeCommandAllocator()"))
        self.assertLess(prepare.index("makeCommandAllocator()"), prepare.index("makeGradientTexture("))

    def test_only_completed_gpu_results_are_cached_and_applied(self):
        prepare = method(VOLUME, "private func prepareVolumeTexture(from entry:")
        completion = prepare.split("options.addFeedbackHandler", 1)[1]
        self.assertLess(completion.index("if let error = feedback.error"),
                        completion.index("histogramBuffer.contents()"))
        self.assertLess(completion.index("DispatchQueue.main.async"), completion.index(".retain(prepared)"))
        self.assertIn("self.applyPreparedRenderVolume(prepared, sourceEntry: entry)", completion)
        self.assertNotIn("if Metal3DPreparedRenderCache.shared.retain", completion)

    def test_hit_and_miss_preserve_per_viewer_setup(self):
        apply = method(VOLUME, "private func applyPreparedRenderVolume(")
        for assignment in ("volumeTexture = prepared.volume", "gradientTexture = prepared.gradient",
                           "brickMinMaxTexture = prepared.brickMinMax", "histogramModel = prepared.histogram",
                           "preparedDefaultWindow = sourceEntry.defaultWindow",
                           "preparedFullDynamicWindow = sourceEntry.fullDynamicWindow",
                           "cachedCPUVolumeData = nil"):
            self.assertIn(assignment, apply)
        self.assertIn("applyWLPreset(named: selectedWLPresetName)", apply)
        self.assertIn("resumeSkinPreparationIfNeeded()", apply)
        self.assertIn("startNextSurfaceCursorPickIfNeeded()", apply)
        self.assertIn("contentDidChange?()", apply)
        for viewer_state in ("skinMask", "ROI", "rotation", "selectedWLPresetName", "opacityRangeTexture"):
            self.assertNotIn(viewer_state, CACHE)

    def test_retention_is_one_entry_with_bounded_ram_scaled_cost(self):
        self.assertIn("private var lastEntry: Entry?", CACHE)
        self.assertIn("maximumCachedBytes = MetalViewerCachePolicy.renderVolumeCacheBytes", CACHE)
        self.assertIn("renderVolumeCacheBytes = Int(min(ProcessInfo.processInfo.physicalMemory / 32, 512 * 1_024 * 1_024))", POLICY)
        retain = method(CACHE, "func retain(")
        self.assertIn("guard isUnderMemoryPressure == false, byteCount <= maximumCachedBytes else { return }", retain)
        self.assertLess(retain.index("lock.lock()"), retain.index("isUnderMemoryPressure == false"))
        self.assertLess(retain.index("guard"), retain.index("lastEntry = entry"))
        self.assertNotIn("lastEntry = nil", retain)

    def test_cost_counts_actual_unique_allocations_including_resampling_source(self):
        self.assertIn("for texture in [sourceTexture, volume, gradient, brickMinMax]", CACHE)
        self.assertIn("seen.insert(ObjectIdentifier(texture)).inserted", CACHE)
        self.assertIn("let size = texture.allocatedSize", CACHE)
        self.assertIn("guard size > 0, size <= Int.max - total else { return Int.max }", CACHE)
        self.assertIn("histogram.counts.count * MemoryLayout<Int>.stride", CACHE)

    def test_pressure_does_not_drop_live_textures_or_retain_cache_itself(self):
        observer = CACHE.split("memoryPressureObserver =", 1)[1].split("\n    func cachedEntry", 1)[0]
        self.assertIn("[weak self] constrained in", observer)
        self.assertIn("self.lock.lock()", observer)
        self.assertIn("defer { self.lock.unlock() }", observer)
        self.assertIn("self.isUnderMemoryPressure = constrained", observer)
        self.assertNotIn("lastEntry", observer)


if __name__ == "__main__":
    unittest.main()
