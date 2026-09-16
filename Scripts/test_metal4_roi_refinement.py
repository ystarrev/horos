"""Non-build checks for Metal 4 ROI relaxation ordering and workspace reuse."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_scout import declaration
from test_metal4_viewer import SOURCES


SOURCE = (SOURCES / "MetalStudyROI.swift").read_text()
SOLVER = declaration("private final class MetalStudyROIGPUSolver", SOURCE)
WORKSPACE = declaration("final class Workspace:", SOLVER)
SOLVE = declaration("func solve(", SOLVER)
FIELD = declaration("private func randomWalkerField(", SOURCE)
SHADERS = (SOURCES / "MetalShaders.metal").read_text()
KERNEL = declaration("kernel void metalStudyROIRedBlackRelaxation(", SHADERS)


class Metal4ROIRefinementTests(unittest.TestCase):
    def assert_order(self, source, *steps):
        positions = [source.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_reusable_encoding_resources_are_per_workspace_not_singleton(self):
        for kind in ("MTL4CommandBuffer", "MTL4CommandAllocator", "MTL4ArgumentTable",
                     "MTLResidencySet", "DispatchSemaphore", "MTL4CommitFeedback"):
            self.assertIn(kind, WORKSPACE)
            self.assertNotIn(kind, SOLVER.replace(WORKSPACE, "").split("func makeEdgeBuffers", 1)[0])
        for factory in ("makeCommandBuffer()", "makeCommandAllocator()", "makeArgumentTable(",
                        "makeResidencySet(", "DispatchSemaphore(value: 0)"):
            self.assertEqual(WORKSPACE.count(factory), 1)
            self.assertNotIn(factory, SOLVE)
        self.assertNotIn("makeBuffer(", SOLVE)
        self.assertEqual(SOLVER.count("device.makeMTL4CommandQueue()"), 1)
        self.assertIn("return Workspace(count: count, device: device)", SOLVER)
        self.assertNotRegex(SOLVER, r"\bMTLCommandQueue\b|\bMTLCommandBuffer\b|waitUntilCompleted|makeCommandQueue\(")

    def test_existing_roi_lock_covers_solve_warm_start_and_cpu_result(self):
        self.assert_order(FIELD, "state.lock.lock()", "defer { state.lock.unlock() }",
                          "let reusesWarmSolution = state.hasWarmSolution", "guard solveRandomWalker(",
                          "state.hasWarmSolution = true", "solver.quantizedProbabilities(in: state.workspace)")
        self.assertIn("precondition(!Thread.isMainThread)", SOLVE)
        controller = (SOURCES / "MetalViewerWindowController.swift").read_text()
        enqueue = declaration("private func enqueueROIRefinement(", controller)
        self.assert_order(enqueue, "studyROIRefinementQueue.async", "let result = request.run(",
                          "DispatchQueue.main.async", "guard generation == self.studyROIRefinementGeneration")
        self.assertIn("if let state = roiStates[identifier] { return state }", SOURCE)

    def test_warm_start_copies_and_input_checks_are_preserved(self):
        for check in ("count > 0", "fixedValues.count == count", "edgeBuffers.count == count",
                      "workspace.count == count", "initialValues?.count != count"):
            self.assertLess(SOLVE.index(check), SOLVE.index("workspace.allocator.reset()"))
        self.assert_order(SOLVE, "copy(fixedValues, to: workspace.fixed)", "if reuseProbability {",
                          "copy(workspace.probability, to: workspace.initial, byteCount: byteCount)",
                          "else if let initialValues", "copy(initialValues, to: workspace.probability)",
                          "copy(initialValues, to: workspace.initial)", "commandBuffer.beginCommandBuffer(")
        self.assertIn("priorWeight: max(priorWeight, 0)", SOLVE)
        self.assertIn("relaxation: 1.35", SOLVE)

    def test_shader_bindings_and_strong_resource_lifetimes_match(self):
        self.assertIn("descriptor.maxBufferBindCount = 7", WORKSPACE)
        self.assertIn("descriptor.initializeBindings = true", WORKSPACE)
        buffers = ("workspace.probability", "workspace.fixed", "workspace.initial", "edgeBuffers.x",
                   "edgeBuffers.y", "edgeBuffers.z", "workspace.phaseUniforms")
        binding_list = SOLVE.split("let buffers = [", 1)[1].split("]", 1)[0]
        self.assertEqual([value.strip() for value in binding_list.split(",")], list(buffers))
        for index, argument in enumerate(("*probabilities", "*fixedValues", "*initialValues",
                                          "*xEdges", "*yEdges", "*zEdges", "&uniforms")):
            self.assertIn(f"{argument} [[buffer({index})]]", KERNEL)
        self.assert_order(SOLVE, "for (index, buffer) in buffers.enumerated()",
                          "workspace.residency.addAllocation(buffer)",
                          "arguments.setAddress(buffer.gpuAddress, index: index)",
                          "encoder.setArgumentTable(arguments)")
        self.assertIn("withExtendedLifetime((self, workspace, edgeBuffers))", SOLVE)
        self.assertNotRegex(SOLVE, r"encoder\.(?:setBytes|setBuffer|setTexture)\(")

    def test_phase_uniforms_are_distinct_aligned_and_immutable_during_dispatch(self):
        self.assertIn("device.makeBuffer(length: 512, options: .storageModeShared)", WORKSPACE)
        self.assertIn("precondition(MemoryLayout<Uniforms>.stride <= 256)", SOLVE)
        self.assert_order(SOLVE, "uniforms.phase = phase",
                          "workspace.phaseUniforms.contents().advanced(by: Int(phase) * 256)",
                          ".storeBytes(of: uniforms, as: Uniforms.self)", "commandBuffer.beginCommandBuffer(")
        loop = declaration("for sweep in 0..<sweepCount", SOLVE)
        self.assertIn("arguments.setAddress(workspace.phaseUniforms.gpuAddress + UInt64(phase) * 256, index: 6)", loop)
        self.assertNotRegex(loop, r"storeBytes|contents\(|uniforms.phase =")
        uniforms = declaration("private struct Uniforms", SOLVER)
        self.assert_order(uniforms, "dimensions: SIMD3<UInt32>", "voxelCount: UInt32",
                          "priorWeight: Float", "relaxation: Float", "phase: UInt32", "padding: UInt32")

    def test_every_dependent_phase_has_an_explicit_dispatch_barrier(self):
        self.assertIn("let sweepCount = max(sweepCount, 1)", SOLVE)
        loop = declaration("for sweep in 0..<sweepCount", SOLVE)
        self.assert_order(loop, "for phase in UInt32(0)...UInt32(1)", "arguments.setAddress(",
                          "encoder.dispatchThreads(threadsPerGrid: threads, threadsPerThreadgroup: threadsPerThreadgroup)",
                          "if sweep + 1 < sweepCount || phase == 0",
                          "encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch,",
                          "visibilityOptions: .device")
        self.assertEqual(SOLVE.count("encoder.barrier("), 1)
        self.assertIn("let threads = MTLSize(width: count, height: 1, depth: 1)", SOLVE)
        self.assertIn("min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup)", SOLVE)
        self.assertIn("if (((x + y + z) & 1u) != uniforms.phase)", KERNEL)
        # With the actual loop condition, 2N phases must yield 2N-1 barriers.
        for requested in (-1, 0, 1, 2, 24, 160):
            sweeps = max(requested, 1)
            barriers = [sweep + 1 < sweeps or phase == 0
                        for sweep in range(sweeps) for phase in range(2)]
            self.assertEqual(barriers, [True] * (2 * sweeps - 1) + [False])

    def test_each_commit_has_fresh_feedback_before_cpu_consumption(self):
        self.assertNotIn("MTL4CommitOptions", WORKSPACE)
        self.assertEqual(SOLVE.count("MTL4CommitOptions()"), 1)
        callback = declaration("options.addFeedbackHandler", SOLVE)
        self.assert_order(callback, "[workspace]", "workspace.feedback = feedback", "workspace.completion.signal()")
        self.assertNotRegex(callback, r"DispatchQueue|feedback.error|allocator|residency|return")
        self.assertNotIn("feedbackQueue", SOLVER)
        self.assert_order(SOLVE[SOLVE.index("encoder.endEncoding()") :],
                          "encoder.endEncoding()", "workspace.residency.commit()",
                          "commandBuffer.useResidencySet(workspace.residency)",
                          "commandBuffer.endCommandBuffer()", "let options = MTL4CommitOptions()",
                          "options.addFeedbackHandler", "commandQueue.commit([commandBuffer], options: options)",
                          "workspace.completion.wait()", "guard let feedback = workspace.feedback",
                          "if let error = feedback.error", "return true")
        waiting = SOLVE.split("commandQueue.commit(", 1)[1].split("workspace.completion.wait()", 1)[0]
        self.assertNotRegex(waiting, r"return|timeout|reset|removeAll")
        self.assertEqual(SOLVE.count("workspace.completion.wait()"), 1)

    def test_cleanup_runs_after_completion_or_recording_failure(self):
        cleanup = declaration("defer {", SOLVE)
        self.assert_order(cleanup, "workspace.residency.removeAllAllocations()", "workspace.residency.commit()",
                          "workspace.feedback = nil", "withExtendedLifetime((self, workspace, edgeBuffers))")
        failure = declaration("guard let encoder =", SOLVE)
        self.assert_order(failure, "commandBuffer.endCommandBuffer()", "return false")
        self.assertNotRegex(failure, r"commandQueue.commit|completion.wait")
        self.assertLess(SOLVE.index("defer {"), SOLVE.index("commandBuffer.beginCommandBuffer("))
        self.assertEqual(SOLVE.count("workspace.allocator.reset()"), 1)

    def test_opt_in_timing_uses_existing_feedback_without_an_extra_wait(self):
        self.assert_order(SOLVE, "let startedAt = MetalPerformanceTrace.begin()", "copy(fixedValues",
                          "let submittedAt = MetalPerformanceTrace.begin()", "commandQueue.commit(",
                          "let waitStartedAt = MetalPerformanceTrace.begin()", "workspace.completion.wait()",
                          'MetalPerformanceTrace.completed(feedback, operation: "roi.refinement", since: startedAt,')
        self.assertEqual(SOLVER.count("addFeedbackHandler"), 1)
        self.assertNotIn("MetalPerformanceTrace.track(", SOLVER)
        self.assertNotIn("UserDefaults", SOLVER)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_complete_solver_typechecks_against_macos_27_sdk(self):
        # Only pipeline-cache construction is stubbed. All workspace allocation,
        # encoding, feedback, memory copies and quantization use the real source.
        harness = "import AppKit\nimport Foundation\nimport Metal\nimport simd\n"
        harness += declaration("struct MetalStudyROIGridDimensions:", SOURCE) + "\n"
        harness += """
private final class MetalPipelineCache {
    static func shared(for device: MTLDevice) throws -> MetalPipelineCache { fatalError() }
    func computePipeline(function: String) throws -> MTLComputePipelineState { fatalError() }
}
""" + SOLVER
        with tempfile.TemporaryDirectory(prefix="horos-roi-refinement-api-") as directory:
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
