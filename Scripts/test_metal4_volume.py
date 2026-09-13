"""Non-build checks for Metal 4 volume display, resource lifetime and bindings."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_viewer import FRAME, SOURCES


SOURCE = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()


def declaration(marker):
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


DRAW = declaration("func draw(in view:")
OVERLAYS = [declaration(f"private func {name}(") for name in (
    "drawCropOverlay", "drawSkinSurfaceOverlay", "drawTumorSurfaceOverlays",
    "drawTumourSeedSpheres", "drawSurgicalTrajectoryOverlay")]


class Metal4VolumeTests(unittest.TestCase):
    def test_display_uses_shared_frame_pool_without_legacy_bindings(self):
        self.assertIn("private let renderQueue: MTL4CommandQueue", SOURCE)
        self.assertIn("renderFrames = try (0..<2).map", SOURCE)
        renderer = declaration("final class Metal3DVolumeRenderer:")
        self.assertEqual(renderer.count("device.makeCommandBuffer()"), 1)
        self.assertIn("view.currentMTL4RenderPassDescriptor", DRAW)
        self.assertIn("frame.makeRenderEncoder(commandBuffer: renderCommandBuffer", DRAW)
        for body in [DRAW] + OVERLAYS:
            self.assertNotRegex(body, r"encoder\.(?:setVertexBytes|setFragmentBytes|setVertexBuffer|setFragmentTexture|setFragmentSamplerState)\(")
            self.assertNotIn("drawPrimitives(type:", body)
            self.assertNotRegex(body, r"waitUntilCompleted|waitUntilScheduled|DispatchSemaphore")
        self.assertNotIn("deviceRef.makeBuffer", OVERLAYS[0])
        self.assertIn("frame.setVertices(edgeVertices)", OVERLAYS[0])
        self.assertIn("frame.setVertices(sphereVertices)", OVERLAYS[0])

    def test_existing_backpressure_and_failure_release_are_preserved(self):
        self.assertIn("singleFrameRayMarchPixelThreshold = 4_000_000", SOURCE)
        self.assertIn("? 1\n            : 2", DRAW)
        self.assertLess(DRAW.index("beginScheduledFrame(concurrencyLimit:"), DRAW.index("view.currentDrawable"))
        self.assertIn("precondition(Thread.isMainThread)", DRAW)
        self.assertIn("renderFrames.first(where: { !$0.inFlight })", DRAW)
        self.assertIn("if frameWasCommitted == false", DRAW)
        self.assertIn("frame?.releaseCompletedResources()", DRAW)
        self.assertIn("completeScheduledFrame(in: view)", DRAW)
        self.assertLess(DRAW.index("guard !frame.encodingFailed"), DRAW.index("renderQueue.commit"))
        completion = DRAW.split("options.addFeedbackHandler", 1)[1]
        self.assertIn("[self, frame, weak view] feedback in", completion)
        self.assertLess(completion.index("DispatchQueue.main.async"), completion.index("frame.releaseCompletedResources()"))
        self.assertLess(completion.index("frame.releaseCompletedResources()"), completion.index("completeScheduledFrame(in: view)"))

    def test_texture_sampler_slots_and_overlay_uniforms_match_shader(self):
        self.assertIn("[volumeTexture, clutTexture, opacityTexture,", DRAW)
        self.assertIn("preIntegratedTransferTexture ?? clutTexture, skinMaskTexture ?? emptySkinMaskTexture,", DRAW)
        self.assertIn("gradientTexture, brickMinMaxTexture, opacityRangeTexture, nil]", DRAW)
        self.assertIn("sampler: samplerState, maskSampler: maskSamplerState", DRAW)
        self.assertIn("samplerDescriptor.supportArgumentBuffers = true", SOURCE)
        self.assertIn("maskSamplerDescriptor.supportArgumentBuffers = true", SOURCE)
        self.assertIn("maskSamplerDescriptor.minFilter = .nearest", SOURCE)
        for body in OVERLAYS:
            self.assertIn("frame.setUniforms(&overlayUniforms, fragmentIndex: 1)", body)
            self.assertIn("encoder.setDepthStencilState(depthStencilState)", body)
        for name in ("skinSurfaceVertexBuffer", "surface.vertexBuffer", "tumourSeedSphereVertexBuffer",
                     "surgicalTrajectory.vertexBuffer", "projectedOutlineVertexBuffer"):
            self.assertIn(f"frame.setVertexBuffer({name})", "\n".join(OVERLAYS))

    def test_draw_order_residency_and_presentation(self):
        steps = ("encoder.setScissorRect(volumeScissorRect)", "width: drawable.texture.width",
                 "drawSkinSurfaceOverlay(with:", "drawTumorSurfaceOverlays(with:",
                 "drawTumourSeedSpheres(with:", "drawSurgicalTrajectoryOverlay(with:",
                 "drawCropOverlay(with:", "encoder.endEncoding()", "frame.residency.commit()",
                 "renderCommandBuffer.useResidencySet(frame.residency)", "renderCommandBuffer.endCommandBuffer()",
                 "frame.inFlight = true", "renderQueue.waitForDrawable(drawable)",
                 "renderQueue.commit([renderCommandBuffer], options: options)",
                 "renderQueue.signalDrawable(drawable)", "drawable.present()")
        positions = [DRAW.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("renderCommandBuffer.useResidencySet(residency)", DRAW)

    def test_cpu_readback_keeps_a_separate_queue_from_display(self):
        body = declaration("private func cpuVolumeData(")
        self.assertIn("let frame = volumeReadbackResources", body)
        self.assertIn("frame.queue.commit([frame.commandBuffer], options: options)", body)
        self.assertNotIn("renderQueue", body)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_display_and_overlays_typecheck_against_metal(self):
        # Application geometry is stubbed. All encoder/frame/submission code is real.
        harness = "import AppKit\nimport Metal\nimport MetalKit\nimport QuartzCore\nimport simd\n" + FRAME
        for name in ("Metal3DVolumeUniforms", "Metal3DOverlayUniforms", "Metal3DOverlayVertex"):
            harness += "\n" + declaration(f"private struct {name}")
        harness += """
private final class VolumeHarness {
    var renderFrames: [MetalViewerRenderFrame] = []
    var renderQueue: MTL4CommandQueue { fatalError() }
    var renderCommandBuffer: MTL4CommandBuffer { fatalError() }
    var volumeTexture, gradientTexture, brickMinMaxTexture, clutTexture, opacityTexture: MTLTexture?
    var opacityRangeTexture, preIntegratedTransferTexture, skinMaskTexture: MTLTexture?
    var emptySkinMaskTexture: MTLTexture { fatalError() }
    var samplerState: MTLSamplerState { fatalError() }
    var maskSamplerState: MTLSamplerState { fatalError() }
    var vertexBuffer: MTLBuffer { fatalError() }
    var pipelineState: MTLRenderPipelineState { fatalError() }
    var overlayPipelineState: MTLRenderPipelineState { fatalError() }
    var depthStencilState: MTLDepthStencilState { fatalError() }
    var skinSurfaceVertexBuffer, tumourSeedSphereVertexBuffer: MTLBuffer?
    var skinSurfaceVertexCount = 0, tumourSeedSphereVertexCount = 0
    var showSkinSurface = false, cropOverlayVisible = false, showTumorSegmentation = false
    var shouldLogQualityFrame = false, highQualityEnabled = false
    let singleFrameRayMarchPixelThreshold = 4_000_000
    struct Surface { let label: UInt8; let vertexBuffer: MTLBuffer; let vertexCount: Int }
    struct Trajectory {
        let vertexBuffer: MTLBuffer; let vertexCount: Int
        let projectedOutlineVertexBuffer: MTLBuffer?; let projectedOutlineVertexCount: Int
    }
    var surgicalTrajectory: Trajectory?
    var tumorSurfaces: [Surface] = []
    var tumorLabelFilter: Set<UInt8>?
    private func currentCameraState(for size: CGSize) -> CameraState { fatalError() }
    private func volumeScissorRect(for size: CGSize, camera: CameraState) -> MTLScissorRect? { nil }
    private func makeUniforms(for size: CGSize, camera: CameraState) -> Metal3DVolumeUniforms { fatalError() }
    func beginScheduledFrame(concurrencyLimit: Int) -> Bool { true }
    func minimumNormalizedVoxelSpacing() -> Float { 0.001 }
    func completeScheduledFrame(in view: MTKView?) {}
    private func makeCropEdgeVertices() -> [Metal3DOverlayVertex] { [] }
    private func makeCropHandleSphereVertices() -> [Metal3DOverlayVertex] { [] }
    func ensureSkinMaskTexture(includeSurface: Bool) {}
    func tumorColor(for label: UInt8) -> SIMD4<Float> { .zero }
""" + declaration("private struct CameraState") + "\n" + DRAW + "\n" + "\n".join(OVERLAYS) + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-volume-api-") as directory:
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
