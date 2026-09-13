"""Non-build checks for Metal 4 registration ownership, dispatch and readback."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_viewer import SOURCE, SOURCES, declaration
from test_metal4_scout import declaration as source_declaration


RESOURCES = declaration("private final class RegistrationGPUResources")
JOB = declaration("private final class RegistrationJob")
SUBMIT = source_declaration("func performCompute(", RESOURCES)
BLOCK = declaration("private func blockMatchingInitialGuess(\n"
                    "        startingAt initialState: RigidTransformState,\n"
                    "        fixedLevel:")
DIRECTIONAL = declaration("private func directionalMetricValue(")
BATCH = declaration("private func primaryMetricValues(")
SUPPORT = declaration("private func registrationSupportMetricValues(")
PASSES = (BLOCK, DIRECTIONAL, BATCH, SUPPORT)


class Metal4RegistrationTests(unittest.TestCase):
    def assert_order(self, source, *steps):
        positions = [source.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_one_lazy_submission_owner_per_job_not_shared_with_display(self):
        for kind in ("MTL4CommandQueue", "MTL4CommandBuffer", "MTL4CommandAllocator",
                     "MTL4ArgumentTable", "MTLResidencySet"):
            self.assertIn(kind, RESOURCES)
        for factory in ("makeMTL4CommandQueue()", "makeCommandBuffer()", "makeCommandAllocator()",
                        "makeArgumentTable(", "makeResidencySet(", "makeBuffer("):
            self.assertEqual(RESOURCES.count(factory), 1)
            self.assertNotIn(factory, SUBMIT)
        self.assertIn("private var gpuResources: RegistrationGPUResources?", JOB)
        self.assertIn("if gpuResources == nil", JOB)
        self.assertIn("RegistrationGPUResources(device: device)", JOB)
        self.assertNotRegex(RESOURCES, r"\bstatic\b|renderQueue|renderFrames|currentDrawable|present\(")
        self.assertNotRegex(SOURCE, r"\bMTLCommandQueue\b|\bMTLCommandBuffer\b|waitUntilCompleted|makeCommandQueue\(")

    def test_arguments_hold_gpu_addresses_and_track_strong_resident_resources(self):
        self.assertIn("descriptor.maxBufferBindCount = 3", RESOURCES)
        self.assertIn("descriptor.maxTextureBindCount = 2", RESOURCES)
        self.assertIn("descriptor.initializeBindings = true", RESOURCES)
        self.assertIn("resources.updateValue(resource, forKey: ObjectIdentifier(resource)) == nil", RESOURCES)
        self.assertIn("residency.addAllocation(resource)", RESOURCES)
        self.assertIn("[ObjectIdentifier: MTLResource]", RESOURCES)
        self.assert_order(source_declaration("func setTexture(", RESOURCES),
                          "retain(texture)", "arguments.setTexture(texture.gpuResourceID, index: index)")
        self.assert_order(source_declaration("func setBuffer(", RESOURCES),
                          "retain(buffer)", "arguments.setAddress(buffer.gpuAddress + UInt64(offset), index: index)")
        self.assert_order(SUBMIT, "allocator.reset()", "arguments.setAddress(0, index: index)",
                          "arguments.setTexture(MTLResourceID(), index: index)",
                          "commandBuffer.beginCommandBuffer(", "encoder.setArgumentTable(arguments)")
        self.assert_order(SUBMIT[SUBMIT.index("encode(encoder)"):],
                          "encode(encoder)", "encoder.endEncoding()", "residency.commit()",
                          "commandBuffer.useResidencySet(residency)", "commandBuffer.endCommandBuffer()")

    def test_uniforms_and_candidate_count_use_distinct_aligned_storage(self):
        self.assertIn("device.makeBuffer(length: 512, options: .storageModeShared)", RESOURCES)
        upload = source_declaration("func setUniforms<T>", RESOURCES)
        self.assert_order(upload, "precondition(MemoryLayout<T>.stride <= 256)",
                          "inlineBuffer.contents().storeBytes(of: uniforms, as: T.self)",
                          "setBuffer(inlineBuffer, index: 0)")
        self.assertIn("inlineBuffer.contents().advanced(by: 256).storeBytes(of: count, as: UInt32.self)", RESOURCES)
        self.assertIn("setBuffer(inlineBuffer, offset: 256, index: 2)", RESOURCES)
        for body in (BLOCK, DIRECTIONAL):
            self.assertEqual(body.count("gpu.setUniforms(uniforms)"), 1)
            self.assertNotIn("gpu.setCandidateCount", body)
        for body in (BATCH, SUPPORT):
            self.assertEqual(body.count("gpu.setCandidateCount(candidateCount)"), 1)
            self.assertNotIn("gpu.setUniforms", body)  # Array uniforms must not alias the inline buffer.
            self.assertIn("job.uniformBuffer(", body)

    def test_each_submission_registers_fresh_completion_options(self):
        self.assertEqual(RESOURCES.count("MTL4CommitOptions()"), 1)
        self.assertEqual(RESOURCES.count("DispatchSemaphore(value: 0)"), 1)
        self.assertEqual(RESOURCES.count("addFeedbackHandler"), 1)
        self.assertIn("let options = MTL4CommitOptions()", SUBMIT)
        self.assertNotIn("MTL4CommitOptions", source_declaration("init(device:", RESOURCES))
        self.assertNotRegex(RESOURCES, r"private (?:let|var) \w+.*MTL4CommitOptions")
        callback = source_declaration("options.addFeedbackHandler", SUBMIT)
        self.assert_order(callback, "[self]", "self.feedback = feedback",
                          "self.completion.signal()")
        self.assertNotRegex(callback, r"DispatchQueue|isCancelled|feedback.error|allocator|residency")
        self.assertNotIn("feedbackQueue", RESOURCES)  # Metal's internal callback queue unblocks the worker.
        self.assert_order(SUBMIT, "let options = MTL4CommitOptions()", "options.addFeedbackHandler",
                          "queue.commit([commandBuffer], options: options)",
                          "completion.wait()", "guard let feedback", "MetalPerformanceTrace.completed(",
                          "if let error = feedback.error", "return !isCancelled()")
        self.assertIn("withExtendedLifetime((self, pipeline))", SUBMIT)

    def test_cancellation_never_abandons_inflight_work_or_reuses_its_memory(self):
        self.assertIn("precondition(!Thread.isMainThread && resources.isEmpty)", SUBMIT)
        self.assertIn("precondition(!Thread.isMainThread)", JOB)
        commit = SUBMIT.index("queue.commit(")
        self.assertIn("guard !isCancelled() else { return false }", SUBMIT[:commit])
        after_commit = SUBMIT[commit:SUBMIT.index("completion.wait()")]
        self.assertNotRegex(after_commit, r"return|isCancelled|timeout|reset|removeAll")
        self.assertEqual(SUBMIT.count("completion.wait()"), 1)
        cancel = source_declaration("func cancel()", JOB)
        self.assertNotRegex(cancel, r"gpuResources|workingBuffers|releaseWorkingBuffers")
        release = source_declaration("func releaseWorkingBuffers()", JOB)
        self.assertIn("gpuResources = nil", release)
        self.assertIn("defer { job.releaseWorkingBuffers() }", declaration("private func runRegistration("))
        cleanup = source_declaration("defer {", SUBMIT)
        self.assert_order(cleanup, "residency.removeAllAllocations()", "residency.commit()",
                          "resources.removeAll(keepingCapacity: true)", "feedback = nil",
                          "withExtendedLifetime((self, pipeline))")

    def test_encoder_failure_ends_recording_without_commit_or_wait(self):
        failure = source_declaration("guard let encoder =", SUBMIT)
        self.assert_order(failure, "commandBuffer.endCommandBuffer()", "return false")
        self.assertNotRegex(failure, r"queue.commit|completion.wait")
        self.assertLess(SUBMIT.index("defer {"), SUBMIT.index("guard let encoder ="))

    def test_every_pass_checks_completion_before_reading_cpu_results(self):
        for body, operation, result in ((BLOCK, "blockMatch", "let results ="),
                                        (DIRECTIONAL, "directional", "let histogram ="),
                                        (BATCH, "batch", "let histogram ="),
                                        (SUPPORT, "support", "let histogram =")):
            with self.subTest(operation=operation):
                self.assertEqual(body.count("job.performCompute("), 1)
                self.assertIn(f'operation: "registration.{operation}"', body)
                self.assert_order(body, "MetalPerformanceTrace.begin()", "memset(",
                                  "job.performCompute(", "guard completed, job.isCancelled == false", result)
                self.assertNotRegex(body, r"encoder\.(?:setBytes|setBuffer|setTexture)\(|waitUntilCompleted|\.commit\(")
        self.assertIn("return .greatestFiniteMagnitude", DIRECTIONAL)
        self.assertIn("return Array(repeating: .greatestFiniteMagnitude, count: states.count)", BATCH)
        self.assertIn("return pairs.map { _ in Array(repeating: nil, count: states.count) }", SUPPORT)

    def test_dispatch_sizes_kernels_and_candidate_tiling_are_preserved(self):
        self.assertIn("pipeline: registrationBlockMatchingPipelineState", BLOCK)
        self.assertIn("threadsPerGrid: MTLSize(width: blockGrid.x, height: blockGrid.y, depth: blockGrid.z)", BLOCK)
        self.assertIn("threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 2)", BLOCK)
        self.assertIn("pipeline: registrationPipelineState", DIRECTIONAL)
        for body in (DIRECTIONAL, BATCH, SUPPORT):
            self.assertIn("MTLSize(width: 8, height: 8, depth: 4)", body)
            self.assertIn("dispatchThreadgroups(threadgroupsPerGrid: threadgroups, threadsPerThreadgroup: threadsPerGroup)", body)
        self.assertIn("private let registrationCandidateTileSize = 4", SOURCE)
        for body in (BATCH, SUPPORT):
            self.assertIn("pipeline: registrationBatchPipelineState", body)
            self.assertIn("let candidateCount = UInt32(states.count)", body)
            self.assertIn("states.count + registrationCandidateTileSize - 1", body)
            self.assertIn(".z * candidateTileCount + threadsPerGroup.depth - 1", body)

    def test_batched_passes_use_separate_storage_without_extra_submissions(self):
        self.assert_order(BATCH, "if evaluatesForwardDirection {", "gpu.setTexture(baseVolumeTexture, index: 0)",
                          "gpu.setTexture(overlayVolumeTexture, index: 1)", "gpu.setBuffer(uniformBuffer, index: 0)",
                          "gpu.setBuffer(histogramBuffer, index: 1)", "if evaluatesReverseDirection {",
                          "gpu.setTexture(overlayVolumeTexture, index: 0)", "gpu.setTexture(baseVolumeTexture, index: 1)",
                          "gpu.setBuffer(reverseUniformBuffer, index: 0)",
                          "gpu.setBuffer(histogramBuffer, offset: histogramPassLength, index: 1)")
        self.assertIn("job.uniformBuffer(uniforms, slot: 0)", BATCH)
        self.assertIn("job.uniformBuffer(reverseUniforms, slot: 1)", BATCH)
        self.assertIn("job.uniformBuffer(uniforms, slot: pairIndex)", SUPPORT)
        self.assertIn("gpu.setBuffer(uniformBuffers[pairIndex], index: 0)", SUPPORT)
        self.assertIn("offset: pairIndex * histogramPassEntryCount * MemoryLayout<UInt32>.stride", SUPPORT)
        for body in (BATCH, SUPPORT):
            self.assertEqual(body.count("job.performCompute("), 1)
            self.assertNotRegex(body, r"barrier|\.commit\(")  # These passes have no producer/consumer dependency.

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_resources_job_and_all_four_dispatch_paths_typecheck(self):
        # Only unrelated viewer/optimizer inputs are stubbed. Typecheck the real
        # submissions, complete pass bodies and CPU reductions against the SDK.
        models = (SOURCES / "MetalViewerModels.swift").read_text()
        harness = "import Foundation\nimport Metal\nimport QuartzCore\nimport simd\n"
        harness += SOURCE[SOURCE.index("private let registrationHistogramBins"):
                          SOURCE.index("struct MetalViewerRegistrationWorldTransform")]
        for marker in ("private struct RegistrationUniforms", "private struct BlockMatchingUniforms",
                       "private struct BlockMatchResult", "private struct BlockCorrespondence",
                       "private enum BlockMatchingMetric", "private struct RigidTransformState",
                       "private struct RegistrationSupportMetricPair"):
            harness += declaration(marker) + "\n"
        harness += source_declaration("struct MetalViewerWindowLevel:", models) + "\n"
        harness += """
private struct VolumeLevel {
    var texture: MTLTexture
    var dimensions: SIMD3<Int>
    var voxelToWorld: simd_float4x4
    var worldToVoxel: simd_float4x4
    var textureDimensions: SIMD3<Int>
    var textureDimensionsUInt32: SIMD3<UInt32>
}
""" + RESOURCES + "\n" + JOB + """
private final class RegistrationHarness {
    var baseRegistrationWindowLevel: Float = 0
    var baseRegistrationWindowWidth: Float = 1
    var overlayRegistrationWindowLevel: Float = 0
    var overlayRegistrationWindowWidth: Float = 1
    var registrationPipelineState: MTLComputePipelineState { fatalError() }
    var registrationBatchPipelineState: MTLComputePipelineState { fatalError() }
    var registrationBlockMatchingPipelineState: MTLComputePipelineState { fatalError() }
"""
        # Preserve helper signatures verbatim to catch mismatched arguments/types.
        for marker in ("metricOptions", "registrationTextureCoordinateMatrix",
                       "reverseRegistrationTextureCoordinateMatrix", "robustRigidState",
                       "usesBidirectionalSlabMetric", "bidirectionalMetricWeights", "registrationOverlapPenalty"):
            helper = declaration(f"private func {marker}(")
            harness += helper.split("{", 1)[0] + "{ fatalError() }\n"
        for marker in ("voxelSpacing", "normalizedRegistrationSamplingStride", "registrationSampleGridSize",
                       "registrationSamplingOptions", "registrationVoxelCount", "mindMetricComponents",
                       "smoothedNormalizedMutualInformation"):
            harness += declaration(f"private func {marker}(") + "\n"
        harness += "\n".join(PASSES) + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-registration-api-") as directory:
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
