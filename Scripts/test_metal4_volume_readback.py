"""Non-build checks for Metal 4 CPU volume readback and buffer ownership."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_volume import SOURCES, SOURCE, declaration
from test_metal4_scout import declaration as source_declaration


RESOURCES = declaration("private final class Metal3DVolumeReadbackResources")
READBACK = declaration("private func cpuVolumeData(")
FEEDBACK = source_declaration("options.addFeedbackHandler", READBACK)


class Metal4VolumeReadbackTests(unittest.TestCase):
    def assert_order(self, source, *steps):
        positions = [source.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_readback_reuses_separate_lazy_metal4_submission_resources(self):
        for kind in ("MTL4CommandQueue", "MTL4CommandBuffer", "MTL4CommandAllocator", "MTLResidencySet"):
            self.assertIn(kind, RESOURCES)
        for factory in ("makeMTL4CommandQueue()", "makeCommandBuffer()", "makeCommandAllocator()", "makeResidencySet("):
            self.assertEqual(RESOURCES.count(factory), 1)
            self.assertNotIn(factory, READBACK)
        self.assertIn("if volumeReadbackResources == nil", READBACK)
        self.assertIn("volumeReadbackResources = Metal3DVolumeReadbackResources(device: deviceRef)", READBACK)
        self.assertIn("frame.queue.commit([frame.commandBuffer], options: options)", READBACK)
        self.assertNotRegex(READBACK, r"renderQueue|renderCommandBuffer|waitForDrawable|currentDrawable|present\(")
        self.assertNotIn("feedbackQueue", RESOURCES)  # Metal's internal queue, never the blocked main queue.
        self.assertNotRegex(SOURCE, r"\bMTLCommandQueue\b|\bMTLCommandBuffer\b|makeBlitCommandEncoder|waitUntilCompleted")

    def test_cache_hit_skips_all_gpu_work_and_allocation(self):
        self.assert_order(READBACK, "precondition(Thread.isMainThread)", "if let cachedCPUVolumeData",
                          "return cachedCPUVolumeData", "guard let volumeTexture", "MetalPerformanceTrace.begin()",
                          "deviceRef.makeBuffer(", "frame.allocator.reset()")
        apply = declaration("private func applyPreparedRenderVolume(")
        self.assert_order(apply, "volumeTexture = prepared.volume", "cachedCPUVolumeData = nil", "resumeSkinPreparationIfNeeded()")

    def test_float_volume_geometry_is_validated_before_allocating_or_copying(self):
        for check in ("volumeTexture.textureType == .type3D", "volumeTexture.pixelFormat == .r32Float",
                      "volumeTexture.width == volumeDimensions.x", "volumeTexture.height == volumeDimensions.y",
                      "volumeTexture.depth == volumeDimensions.z", "MetalTextureLimits.supports3DTexture(",
                      "byteCount <= deviceRef.maxBufferLength"):
            self.assertLess(READBACK.index(check), READBACK.index("deviceRef.makeBuffer("))
        self.assertIn("let width = volumeDimensions.x", READBACK)
        self.assertIn("let height = volumeDimensions.y", READBACK)
        self.assertIn("let depth = volumeDimensions.z", READBACK)
        self.assertIn("let bytesPerRow = width * MemoryLayout<Float>.stride", READBACK)
        self.assertIn("let bytesPerImage = bytesPerRow * height", READBACK)
        self.assertIn("let byteCount = bytesPerImage * depth", READBACK)

    def test_single_copy_preserves_packed_xyz_order_including_depth_one(self):
        self.assertEqual(READBACK.count("makeComputeCommandEncoder()"), 1)
        self.assertEqual(READBACK.count("encoder.copy("), 1)
        for value in ("sourceTexture: volumeTexture", "sourceSlice: 0", "sourceLevel: 0",
                      "sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0)",
                      "sourceSize: MTLSize(width: width, height: height, depth: depth)",
                      "destinationBuffer: buffer", "destinationOffset: 0",
                      "destinationBytesPerRow: bytesPerRow",
                      "destinationBytesPerImage: depth > 1 ? bytesPerImage : 0"):
            self.assertIn(value, READBACK)
        self.assertNotRegex(READBACK, r"dispatchThreads|setComputePipelineState|setArgumentTable|makeTexture|\.getBytes\(")

    def test_resources_remain_alive_and_resident_until_the_wait_finishes(self):
        self.assertIn("let resources: [MTLResource] = [volumeTexture, buffer]", READBACK)
        self.assert_order(READBACK, "frame.allocator.reset()", "frame.residency.addAllocation(resource)",
                          "frame.residency.commit()", "frame.commandBuffer.beginCommandBuffer(",
                          "frame.commandBuffer.useResidencySet(frame.residency)",
                          "frame.commandBuffer.makeComputeCommandEncoder()")
        cleanup = source_declaration("defer {", READBACK)
        self.assert_order(cleanup, "frame.residency.removeAllAllocations()", "frame.residency.commit()",
                          "withExtendedLifetime(resources)")
        self.assertNotIn("release", FEEDBACK)
        self.assertEqual(READBACK.count("frame.allocator.reset()"), 1)

    def test_success_or_failure_feedback_always_unblocks_the_synchronous_caller(self):
        self.assertIn("var succeeded = false", RESOURCES)
        self.assertIn("let semaphore = DispatchSemaphore(value: 0)", RESOURCES)
        self.assert_order(FEEDBACK, "completion.succeeded = feedback.error == nil",
                          "if let error = feedback.error", "completion.semaphore.signal()")
        self.assertNotIn("return", FEEDBACK)
        self.assertNotIn("DispatchQueue.main", FEEDBACK)
        self.assert_order(READBACK, "frame.commandBuffer.endCommandBuffer()", "options.addFeedbackHandler",
                          'MetalPerformanceTrace.track(options, operation: "readback.volume"',
                          "frame.queue.commit(", "completion.semaphore.wait()", "guard completion.succeeded",
                          "Data(bytesNoCopy:", "cachedCPUVolumeData = data")
        self.assertEqual(READBACK.count("completion.semaphore.wait()"), 1)
        self.assertIn('MetalPerformanceTrace.end("readback.volume.cpu_wait", since: waitStartedAt)', READBACK)

    def test_encoder_failure_ends_recording_without_submitting(self):
        failure = READBACK.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        self.assert_order(failure, "frame.commandBuffer.endCommandBuffer()", "return nil")
        self.assertNotIn("commit", failure)
        self.assertNotIn("cachedCPUVolumeData", failure)
        self.assertLess(READBACK.index("defer {"), READBACK.index("guard let encoder ="))

    def test_data_owns_a_fresh_allocation_without_copying_or_freeing_metal_memory(self):
        self.assertIn("makeBuffer(length: byteCount, options: .storageModeShared)", READBACK)
        self.assertIn("Data(bytesNoCopy: buffer.contents(), count: byteCount", READBACK)
        self.assertIn("deallocator: .custom { [buffer] _, _ in", READBACK)
        self.assertIn("withExtendedLifetime(buffer) {}", READBACK)
        self.assertNotRegex(READBACK, r"Data\(bytes:|\.copyMemory\(|deallocate\(|\.free\b|\.none\b")
        self.assertNotIn("MTLBuffer", RESOURCES)  # Reuse command storage, never the result allocation.
        self.assertNotIn("volumeReadbackResources = nil", READBACK)
        segmentation = declaration("func segmentationInput(")
        self.assertIn("guard let data = cpuVolumeData()", segmentation)
        for value in ("dimensions: volumeDimensions", "spacing: voxelSpacing",
                      "sourceSpacing: sourceVoxelSpacing", "float32VolumeData: data",
                      "sourceVoxelToVolumeVoxelMatrix: sourceVoxelToVolumeVoxelMatrix()"):
            self.assertIn(value, segmentation)
        self.assertIn("guard let volumeData = cpuVolumeData()", declaration("private func ensureSkinMaskTexture("))

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_resource_owner_readback_and_data_handoff_typecheck(self):
        # No Metal or Data stubs: check the actual synchronous GPU submission,
        # callback, residency/lifetime cleanup and zero-copy Data initializer.
        models = (SOURCES / "MetalViewerModels.swift").read_text()
        harness = "import Foundation\nimport Metal\nimport simd\n"
        harness += source_declaration("enum MetalTextureLimits", models) + "\n" + RESOURCES
        harness += """
private final class ReadbackHarness {
    var deviceRef: MTLDevice { fatalError() }
    var volumeDimensions = SIMD3<Int>(7, 11, 3)
    var volumeTexture: MTLTexture?
    var cachedCPUVolumeData: Data?
    private var volumeReadbackResources: Metal3DVolumeReadbackResources?
""" + READBACK + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-volume-readback-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                str(path), str(SOURCES / "MetalPerformanceTrace.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
