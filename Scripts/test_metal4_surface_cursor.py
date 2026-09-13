"""Non-build regression checks for reusable Metal 4 surface cursor picking."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_volume import SOURCES, SOURCE, declaration
from test_metal4_scout import declaration as source_declaration


FRAME = declaration("private final class Metal3DSurfaceCursorPickResources")
PREPARE = source_declaration("func prepare(", FRAME)
RELEASE = source_declaration("func releaseCompletedResources(", FRAME)
PICK = declaration("private func startNextSurfaceCursorPickIfNeeded(")
UPDATE = declaration("func updateSurfaceCursor(")
CLEAR = declaration("func clearSurfaceCursor(")
FEEDBACK = PICK.split("options.addFeedbackHandler", 1)[1]


class Metal4SurfaceCursorTests(unittest.TestCase):
    def test_lazy_slot_reuses_buffers_and_has_its_own_submission_queue(self):
        self.assertIn("if surfaceCursorPickResources == nil", PICK)
        self.assertEqual(FRAME.count("device.makeMTL4CommandQueue()"), 1)
        self.assertEqual(FRAME.count("device.makeCommandBuffer()"), 1)
        self.assertEqual(FRAME.count("device.makeCommandAllocator()"), 1)
        self.assertEqual(FRAME.count("device.makeBuffer("), 3)
        self.assertNotRegex(PREPARE + PICK, r"makeBuffer\(|makeCommandBuffer\(|makeMTL4CommandQueue\(")
        self.assertIn("frame.queue.commit([frame.commandBuffer], options: options)", PICK)
        self.assertNotRegex(PICK, r"renderQueue|waitForDrawable|currentDrawable|present\(|waitUntil|DispatchSemaphore|\.wait\(")
        self.assertNotIn("commandQueue.makeCommandBuffer", PICK)

    def test_argument_table_and_uniform_buffers_match_the_existing_shader(self):
        self.assertIn("descriptor.maxBufferBindCount = 3", FRAME)
        self.assertIn("descriptor.maxTextureBindCount = 6", FRAME)
        self.assertIn("descriptor.maxSamplerStateBindCount = 2", FRAME)
        self.assertIn("descriptor.initializeBindings = true", FRAME)
        for buffer, index in (("volumeUniformBuffer", 0), ("pickUniformBuffer", 1), ("resultBuffer", 2)):
            self.assertIn(f"arguments.setAddress({buffer}.gpuAddress, index: {index})", FRAME)
        self.assertIn("textures: [volumeTexture, nil, opacityTexture, preIntegratedTransferTexture ?? clutTexture,", PICK)
        self.assertIn("skinMaskTexture, gradientTexture]", PICK)
        self.assertIn("arguments.setTexture(texture?.gpuResourceID ?? MTLResourceID(), index: index)", PREPARE)
        self.assertIn("arguments.setSamplerState(sampler.gpuResourceID, index: 0)", PREPARE)
        self.assertIn("arguments.setSamplerState(maskSampler.gpuResourceID, index: 1)", PREPARE)
        shader = source_declaration("kernel void metal3DSurfaceCursorPick", (SOURCES / "MetalShaders.metal").read_text())
        for binding in ("uniforms [[buffer(0)]]", "cursor [[buffer(1)]]", "result [[buffer(2)]]",
                        "volumeTexture [[texture(0)]]", "opacityTexture [[texture(2)]]",
                        "preIntegratedTransferTexture [[texture(3)]]", "skinMaskTexture [[texture(4)]]",
                        "gradientTexture [[texture(5)]]", "textureSampler [[sampler(0)]]", "maskSampler [[sampler(1)]]"):
            self.assertIn(binding, shader)

    def test_one_dispatch_preserves_request_coordinates_and_camera_settings(self):
        self.assertIn("currentCameraState(for: request.bounds.size)", PICK)
        self.assertIn("makeUniforms(for: request.bounds.size, camera: camera)", PICK)
        for axis, extent in (("x", "width"), ("y", "height")):
            self.assertIn(f"Float((request.point.{axis} - request.bounds.min{axis.upper()}) / request.bounds.{extent}) * 2.0 - 1.0", PICK)
        self.assertEqual(PICK.count("encoder.dispatchThreads("), 1)
        self.assertIn("threadsPerGrid: MTLSize(width: 1, height: 1, depth: 1)", PICK)
        self.assertIn("threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)", PICK)
        self.assertIn("encoder.setComputePipelineState(surfaceCursorPickPipelineState)", PICK)
        self.assertIn("encoder.setArgumentTable(frame.arguments)", PICK)
        self.assertNotRegex(PICK, r"encoder\.set(?:Bytes|Texture|Buffer|SamplerState)\(")

    def test_busy_slot_is_never_overwritten_and_new_requests_are_coalesced(self):
        steps = ("surfaceCursorPickInFlight == false", "let request = pendingSurfaceCursorPick",
                 "pendingSurfaceCursorPick = nil", "surfaceCursorPickInFlight = true",
                 "if surfaceCursorPickResources == nil", "frame.prepare(")
        positions = [PICK.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("surfaceCursorPickGeneration &+= 1", UPDATE)
        self.assertIn("pendingSurfaceCursorPick = (point, bounds, surfaceCursorPickGeneration)", UPDATE)
        self.assertIn("startNextSurfaceCursorPickIfNeeded()", UPDATE)
        self.assertNotIn("surfaceCursorPickInFlight = false", UPDATE)
        self.assertLess(FEEDBACK.index("self.surfaceCursorPickInFlight = false"),
                        FEEDBACK.index("self.startNextSurfaceCursorPickIfNeeded()"))

    def test_leaving_the_view_invalidates_pending_and_inflight_results(self):
        self.assertIn("bounds.contains(point)", UPDATE)
        self.assertIn("clearSurfaceCursor()", UPDATE)
        self.assertIn("surfaceCursorPickGeneration &+= 1", CLEAR)
        self.assertIn("pendingSurfaceCursorPick = nil", CLEAR)
        self.assertNotRegex(CLEAR, r"allocator|releaseCompletedResources|surfaceCursorPickInFlight = false")
        self.assertEqual(FEEDBACK.count("requestGeneration == self.surfaceCursorPickGeneration"), 2)
        self.assertIn("result.positionAndHit.w > 0.5", FEEDBACK)
        for check in ("position.x.isFinite, position.y.isFinite, position.z.isFinite",
                      "normal.x.isFinite, normal.y.isFinite, normal.z.isFinite",
                      "normalizedDepth.isFinite", "simd_length_squared(normal) > 0.000001",
                      "normal: simd_normalize(normal)", "normalizedDepth: min(max(normalizedDepth, 0), 1)"):
            self.assertIn(check, FEEDBACK)

    def test_residency_keeps_replaced_textures_alive_and_releases_after_readback(self):
        self.assertIn("retainedTextures = textures.compactMap { $0 }", PREPARE)
        self.assertIn("for buffer in [volumeUniformBuffer, pickUniformBuffer, resultBuffer]", PREPARE)
        self.assertIn("if let texture { residency.addAllocation(texture) }", PREPARE)
        self.assertIn("residency.commit()", PREPARE)
        self.assertIn("[self, frame] feedback in", FEEDBACK)
        steps = ("feedback.error == nil", "let result = completedSuccessfully",
                 "frame.resultBuffer.contents().load", "DispatchQueue.main.async { [self, frame]",
                 "frame.releaseCompletedResources()", "self.surfaceCursorPickInFlight = false",
                 "self.startNextSurfaceCursorPickIfNeeded()")
        positions = [FEEDBACK.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("residency.removeAllAllocations()", RELEASE)
        self.assertIn("retainedTextures.removeAll(keepingCapacity: true)", RELEASE)
        for method in (PREPARE, RELEASE, PICK, UPDATE, CLEAR):
            self.assertIn("precondition(Thread.isMainThread", method)

    def test_reused_results_are_cleared_and_failure_releases_the_slot(self):
        self.assertIn("resultBuffer.contents().storeBytes(of: Metal3DSurfaceCursorPickResult()", PREPARE)
        self.assertIn("allocator.reset()", PREPARE)
        failure = PICK.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        steps = ("frame.commandBuffer.endCommandBuffer()", "frame.releaseCompletedResources()", "return")
        positions = [failure.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("commit", failure)
        self.assertIn("if !submitted", PICK)
        self.assertLess(PICK.index("if !submitted"), PICK.index("if surfaceCursorPickResources == nil"))
        self.assertIn("surfaceCursorPickInFlight = false", PICK.split("if !submitted", 1)[1].split("let performanceStartedAt", 1)[0])
        self.assertIn(": Metal3DSurfaceCursorPickResult()", FEEDBACK)

    def test_submission_and_optional_timing_precede_commit(self):
        steps = ("frame.prepare(", "frame.commandBuffer.beginCommandBuffer", "encoder.endEncoding()",
                 "frame.commandBuffer.useResidencySet(frame.residency)", "options.addFeedbackHandler",
                 'MetalPerformanceTrace.track(options, operation: "pick.surface"', "submitted = true",
                 "frame.queue.commit([frame.commandBuffer], options: options)")
        positions = [PICK.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_pick_resources_submission_and_completion_typecheck(self):
        # Geometry/model creation is stubbed, not the Metal API, uniform layout,
        # resource ownership, request handling or result validation.
        harness = "import Foundation\nimport Metal\nimport simd\n"
        for name in ("Metal3DVolumeUniforms", "Metal3DSurfaceCursorPickUniforms", "Metal3DSurfaceCursorPickResult",
                     "Metal3DSurfaceCursorHit"):
            harness += declaration(f"private struct {name}") + "\n"
        harness += FRAME + """
private final class PickHarness {
    var deviceRef: MTLDevice { fatalError() }
    var surfaceCursorPickPipelineState: MTLComputePipelineState { fatalError() }
    var samplerState: MTLSamplerState { fatalError() }
    var maskSamplerState: MTLSamplerState { fatalError() }
    var volumeTexture, opacityTexture, gradientTexture, skinMaskTexture: MTLTexture?
    var emptySkinMaskTexture, preIntegratedTransferTexture, clutTexture: MTLTexture?
    private var surfaceCursorPickResources: Metal3DSurfaceCursorPickResources?
    private var surfaceCursorHit: Metal3DSurfaceCursorHit?
    var surfaceCursorPickGeneration: UInt64 = 0
    var surfaceCursorPickInFlight = false
    var pendingSurfaceCursorPick: (point: CGPoint, bounds: CGRect, generation: UInt64)?
    var surfaceCursorDidChange: (() -> Void)?
    private func currentCameraState(for size: CGSize) -> Int { 0 }
    private func makeUniforms(for size: CGSize, camera: Int) -> Metal3DVolumeUniforms { fatalError() }
""" + UPDATE + "\n" + CLEAR + "\n" + PICK + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-surface-cursor-api-") as directory:
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
