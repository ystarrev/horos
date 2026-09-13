"""Non-build checks for the unified Metal 4 volume preparation pass."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_volume import SOURCES, SOURCE, declaration
from test_metal4_scout import declaration as source_declaration


PREPARE = declaration("private func prepareVolumeTexture(")
FEEDBACK = PREPARE.split("options.addFeedbackHandler", 1)[1]
SHADERS = (SOURCES / "MetalShaders.metal").read_text()


class Metal4VolumePreparationTests(unittest.TestCase):
    def test_single_encoder_reuses_the_renderer_submission_without_cpu_waits(self):
        self.assertIn("precondition(Thread.isMainThread)", PREPARE)
        self.assertEqual(PREPARE.count("makeComputeCommandEncoder()"), 1)
        self.assertEqual(PREPARE.count("encoder.endEncoding()"), 1)
        self.assertEqual(PREPARE.count("encoder.dispatchThreadgroups("), 4)
        self.assertIn("renderCommandBuffer.beginCommandBuffer(allocator: allocator)", PREPARE)
        self.assertIn("renderQueue.commit([renderCommandBuffer], options: options)", PREPARE)
        self.assertNotRegex(PREPARE, r"commandQueue\.|makeCommandBuffer\(|makeBlitCommandEncoder|waitUntil|DispatchSemaphore|\.wait\(")
        self.assertNotRegex(PREPARE, r"encoder\.set(?:Bytes|Buffer|Texture)\(")
        self.assertNotIn("renderFrames", PREPARE)

    def test_resampling_barrier_precedes_all_three_independent_consumers(self):
        start = PREPARE.index("encoder.setComputePipelineState(resampleVolumePipelineState)")
        end = PREPARE.index("let gradientUniforms =")
        resample = PREPARE[start:end]
        self.assertLess(resample.index("encoder.dispatchThreadgroups("), resample.index("encoder.barrier("))
        self.assertIn("afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch", resample)
        self.assertIn("visibilityOptions: .device", resample)
        self.assertEqual(PREPARE.count("afterEncoderStages:"), 1)
        steps = ("let gradientUniforms =", "setComputePipelineState(gradientPipelineState)",
                 "setComputePipelineState(brickMinMaxPipelineState)",
                 "setComputePipelineState(histogramPipelineState)",
                 "encoder.barrier(afterStages: .dispatch, beforeQueueStages: [.fragment, .dispatch, .blit]",
                 "encoder.endEncoding()")
        positions = [PREPARE.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_unresampled_input_is_reused_and_geometry_settings_are_unchanged(self):
        self.assertIn("preparedTexture = entry.texture", PREPARE)
        self.assertIn("if volumeDimensions != entry.dimensions", PREPARE)
        for setting in ("entry.dimensions == sourceDimensions", "Self.isCTVolume(pixList) ? -1024 : 0",
                        "outputVoxelToWorld: referenceVoxelToPatientMatrix",
                        "sourceWorldToVoxel: simd_inverse(entry.voxelToWorld)",
                        "voxelSpacing: SIMD4<Float>(voxelSpacing.x, voxelSpacing.y, voxelSpacing.z, 0)",
                        "MTLSize(width: 4, height: 4, depth: 4)"):
            self.assertIn(setting, PREPARE)
        self.assertEqual(PREPARE.count("Self.threadgroups(for: volumeDimensions,"), 3)
        self.assertIn("Self.threadgroups(for: brickDimensions,", PREPARE)
        self.assertIn("descriptor.pixelFormat = .rgba8Snorm", declaration("private func makeGradientTexture("))
        self.assertIn("descriptor.pixelFormat = .rg32Float", declaration("private func makeBrickMinMaxTexture("))

    def test_resource_residency_and_lifetimes_cover_every_dispatch(self):
        for resource in ("entry.texture", "preparedGradientTexture", "preparedBrickMinMaxTexture",
                         "uniformBuffer", "histogramBuffer"):
            self.assertIn(resource, PREPARE.split("var resources: [MTLResource] =", 1)[1].split("\n        if", 1)[0])
        self.assertIn("if preparedTexture !== entry.texture { resources.append(preparedTexture) }", PREPARE)
        steps = ("for resource in resources { residency.addAllocation(resource) }", "residency.commit()",
                 "renderCommandBuffer.beginCommandBuffer", "renderCommandBuffer.useResidencySet(residency)",
                 "options.addFeedbackHandler", "renderQueue.commit(")
        positions = [PREPARE.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("[self, allocator, arguments, residency, resources] feedback in", FEEDBACK)
        self.assertIn("defer { withExtendedLifetime((self, allocator, arguments, residency, resources)) {} }", FEEDBACK)
        self.assertNotIn("allocator.reset()", PREPARE)

    def test_uniform_storage_is_distinct_and_bindings_match_shaders(self):
        self.assertIn("let uniformStride = 256", PREPARE)
        self.assertIn("length: 3 * uniformStride", PREPARE)
        self.assertIn("MemoryLayout<T>.stride <= uniformStride", PREPARE)
        self.assertIn("let offset = slot * uniformStride", PREPARE)
        for name, slot, index in (("resample", 0, 0), ("gradient", 1, 0), ("histogram", 2, 1)):
            self.assertIn(f"arguments.setAddress(storeUniforms({name}Uniforms, slot: {slot}), index: {index})", PREPARE)
        self.assertIn("argumentDescriptor.maxBufferBindCount = 2", PREPARE)
        self.assertIn("argumentDescriptor.maxTextureBindCount = 2", PREPARE)
        self.assertIn("argumentDescriptor.initializeBindings = true", PREPARE)
        self.assertIn("arguments.setAddress(histogramBuffer.gpuAddress, index: 0)", PREPARE)
        self.assertIn("arguments.setTexture(MTLResourceID(), index: 1)", PREPARE)
        for kernel, uniform in (("metalViewerGantryTiltResample3D", "GantryTiltResampleUniforms"),
                                ("metal3DGradientVolume", "Metal3DGradientUniforms")):
            body = source_declaration(f"kernel void {kernel}", SHADERS)
            self.assertIn(f"constant {uniform} &uniforms [[buffer(0)]]", body)
            self.assertIn("[[texture(0)]]", body)
            self.assertIn("[[texture(1)]]", body)
        histogram = source_declaration("kernel void metal3DHistogram", SHADERS)
        self.assertIn("device atomic_uint *histogram [[buffer(0)]]", histogram)
        self.assertIn("constant Metal3DHistogramUniforms &uniforms [[buffer(1)]]", histogram)

    def test_histogram_is_cleared_before_submission_and_read_after_success(self):
        self.assertIn("let histogramBinCount = 512", PREPARE)
        self.assertIn("repeating: 0,\n            count: histogramBinCount", PREPARE)
        self.assertLess(PREPARE.index("histogramBuffer.contents().initializeMemory"),
                        PREPARE.index("renderCommandBuffer.beginCommandBuffer"))
        steps = ("if let error = feedback.error", "return", "histogramBuffer.contents()",
                 "let counts =", "Metal3DPreparedRenderCache.Entry(",
                 "DispatchQueue.main.async { [weak self]", ".retain(prepared)",
                 "self.applyPreparedRenderVolume(prepared, sourceEntry: entry)")
        positions = [FEEDBACK.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("applyPreparedRenderVolume", PREPARE.split("options.addFeedbackHandler", 1)[0].split("makeCommandAllocator", 1)[1])

    def test_cache_hits_skip_allocations_and_failure_does_not_submit_partial_work(self):
        self.assertLess(PREPARE.index("if let cached ="), PREPARE.index("makeCommandAllocator()"))
        for allocation in ("makeBuffer(", "makeGradientTexture(", "makeBrickMinMaxTexture(",
                           "makeWritableFloatTexture(", "makeArgumentTable(", "makeResidencySet("):
            self.assertLess(PREPARE.index(allocation), PREPARE.index("beginCommandBuffer("))
        failure = PREPARE.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        self.assertIn("renderCommandBuffer.endCommandBuffer()", failure)
        self.assertIn("return", failure)
        self.assertNotIn("commit", failure)
        self.assertNotIn("return", PREPARE.split('encoder.label = "Metal 4 volume preparation"', 1)[1].split("options.addFeedbackHandler", 1)[0])

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_preparation_typechecks_against_metal4(self):
        # Only application input/state is stubbed. The submission, uniforms,
        # buffers, texture allocation, cache, feedback and histogram are real.
        harness = "import Foundation\nimport Metal\nimport simd\n"
        for name in ("Metal3DResampleUniforms", "Metal3DHistogramUniforms", "Metal3DGradientUniforms"):
            harness += declaration(f"private struct {name}") + "\n"
        harness += declaration("private final class Metal3DPreparedRenderCache")
        harness += """
private enum MetalViewerCachePolicy { static let renderVolumeCacheBytes = 1024 }
private final class MetalViewerCacheMemoryPressureObserver { init(_ body: @escaping (Bool) -> Void) {} }
private enum MetalTextureLimits {
    static func supports3DTexture(width: Int, height: Int, depth: Int) -> Bool { true }
}
private enum MetalPreparedVolumeCache {
    struct Entry {
        let dimensions: SIMD3<Int>
        let texture: MTLTexture
        let voxelToWorld: simd_float4x4
    }
}
private final class PreparationHarness {
    var deviceRef: MTLDevice { fatalError() }
    var renderQueue: MTL4CommandQueue { fatalError() }
    var renderCommandBuffer: MTL4CommandBuffer { fatalError() }
    var resampleVolumePipelineState: MTLComputePipelineState { fatalError() }
    var gradientPipelineState: MTLComputePipelineState { fatalError() }
    var brickMinMaxPipelineState: MTLComputePipelineState { fatalError() }
    var histogramPipelineState: MTLComputePipelineState { fatalError() }
    var sourceDimensions = SIMD3<Int>(16, 16, 16)
    var volumeDimensions = SIMD3<Int>(16, 16, 16)
    var referenceVoxelToPatientMatrix = matrix_identity_float4x4
    var voxelSpacing = SIMD3<Float>(1, 1, 1)
    var pixList: [Int] = []
    let histogramDomainMin: Float = -1200
    let histogramDomainMax: Float = 3200
    let metal3DBrickSize = 8
    static func isCTVolume(_ pixList: [Int]) -> Bool { true }
    private func applyPreparedRenderVolume(_ result: Metal3DPreparedRenderCache.Entry,
                                          sourceEntry: MetalPreparedVolumeCache.Entry) {}
"""
        for method in ("makeWritableFloatTexture", "makeGradientTexture", "makeBrickMinMaxTexture", "brickGridDimensions"):
            harness += declaration(f"private func {method}(") + "\n"
        harness += declaration("private static func threadgroups(") + "\n" + PREPARE + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-volume-preparation-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                str(path), str(SOURCES / "MetalPerformanceTrace.swift"),
                str(SOURCES / "Metal3DHistogramModel.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
