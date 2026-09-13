"""Non-build checks for Metal 4 ROI scout submission and resource ownership."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_viewer import FRAME, SOURCES


SOURCE = (SOURCES / "MetalViewerScoutView.swift").read_text()


def declaration(marker, source=SOURCE):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


RENDERER = declaration("private final class MetalViewerScoutROIRenderer")
DRAW = declaration("func draw(in view:", RENDERER)
UPDATE = declaration("func update(roi:", RENDERER)
PREVIEW = declaration("private final class MetalViewerScoutROIPreviewView")


class Metal4ScoutTests(unittest.TestCase):
    def test_renderer_reuses_commands_and_shared_frame_resources(self):
        self.assertIn("private let renderQueue: MTL4CommandQueue", RENDERER)
        self.assertIn("private let renderCommandBuffer: MTL4CommandBuffer", RENDERER)
        self.assertIn("try? (0..<2).map({ _ in try MetalViewerRenderFrame(device: device) })", RENDERER)
        self.assertEqual(RENDERER.count("device.makeCommandBuffer()"), 1)
        self.assertNotIn("makeCommandBuffer()", DRAW)
        self.assertIn("view.currentMTL4RenderPassDescriptor", DRAW)
        self.assertIn("frame.makeRenderEncoder(commandBuffer: renderCommandBuffer", DRAW)
        self.assertNotRegex(RENDERER, r"\bMTLCommandQueue\b|\bMTLCommandBuffer\b")
        self.assertNotRegex(DRAW, r"encoder\.(?:setVertexBytes|setFragmentBytes|setVertexBuffer)\(")

    def test_busy_frames_coalesce_before_drawable_acquisition_without_cpu_wait(self):
        self.assertIn("precondition(Thread.isMainThread)", DRAW)
        self.assertLess(DRAW.index("renderFrames.first(where: { !$0.inFlight })"),
                        DRAW.index("view.currentMTL4RenderPassDescriptor"))
        busy = DRAW.split("guard let frame =", 1)[1].split("pendingRender = false", 1)[0]
        self.assertIn("pendingRender = true", busy)
        self.assertIn("return", busy)
        self.assertNotRegex(RENDERER, r"waitUntilCompleted|waitUntilScheduled|DispatchSemaphore|Thread.sleep")
        completion = DRAW.split("options.addFeedbackHandler", 1)[1]
        steps = ("DispatchQueue.main.async", "frame.releaseCompletedResources()",
                 "if pendingRender", "pendingRender = false", "view?.needsDisplay = true")
        positions = [completion.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("view?.draw()", completion)

    def test_geometry_replacement_cannot_overwrite_inflight_vertices(self):
        self.assertIn("let buffer = vertices.isEmpty", UPDATE)
        self.assertIn("device.makeBuffer(", UPDATE)
        self.assertNotIn("contents()", UPDATE)
        self.assertNotIn("renderFrames", UPDATE)
        self.assertLess(UPDATE.index("stateLock.lock()"), UPDATE.index("vertexBuffer = buffer"))
        self.assertLess(DRAW.index("stateLock.lock()"), DRAW.index("let vertexBuffer = self.vertexBuffer"))
        self.assertLess(DRAW.index("stateLock.unlock()"), DRAW.index("frame.setVertexBuffer(vertexBuffer)"))
        self.assertIn("retainResource(buffer)", FRAME)
        self.assertIn("resources: [ObjectIdentifier: MTLResource]", FRAME)
        self.assertIn("[self, frame, weak view] feedback in", DRAW)

    def test_shader_slots_color_depth_and_orientation_are_preserved(self):
        shaders = (SOURCES / "MetalShaders.metal").read_text()
        vertex = declaration("vertex MetalViewerScoutROIRasterData metalViewerScoutROIVertex", shaders)
        fragment = declaration("fragment float4 metalViewerScoutROIFragment", shaders)
        self.assertIn("*vertices [[buffer(0)]]", vertex)
        self.assertIn("&uniforms [[buffer(1)]]", vertex)
        self.assertIn("&uniforms [[buffer(1)]]", fragment)
        self.assertIn("frame.setVertexBuffer(vertexBuffer)", DRAW)
        self.assertIn("frame.setUniforms(&uniforms, fragmentIndex: 1)", DRAW)
        self.assertIn("rotation: MetalViewerMPRSceneRotation.viewMatrix(for: rotationState)", DRAW)
        self.assertIn("depthDescriptor.depthCompareFunction = .less", RENDERER)
        self.assertIn("depthDescriptor.isDepthWriteEnabled = true", RENDERER)
        self.assertIn("encoder.setCullMode(.none)", DRAW)
        self.assertIn("drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: vertexCount)", DRAW)
        self.assertIn("colorPixelFormat = .bgra8Unorm", PREVIEW)
        self.assertIn("depthStencilPixelFormat = .depth32Float", PREVIEW)
        # The preview keeps MTKView's single-sample default, with no shared MSAA target.
        self.assertNotIn("sampleCount =", PREVIEW)

    def test_uniform_failure_ends_recording_without_submitting_or_leaking_a_slot(self):
        failure = DRAW.split("guard frame.setUniforms", 1)[1].split("\n        }", 1)[0]
        steps = ("encoder.endEncoding()", "renderCommandBuffer.endCommandBuffer()",
                 "frame.releaseCompletedResources()", "return")
        positions = [failure.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("renderQueue.commit", failure)
        self.assertNotIn("frame.inFlight = true", failure)

    def test_residency_and_presentation_are_explicit_and_ordered(self):
        steps = ("encoder.endEncoding()", "frame.residency.commit()",
                 "renderCommandBuffer.useResidencySet(frame.residency)",
                 "renderCommandBuffer.useResidencySet(residency)",
                 "renderCommandBuffer.endCommandBuffer()", "frame.inFlight = true",
                 "renderQueue.waitForDrawable(drawable)",
                 "renderQueue.commit([renderCommandBuffer], options: options)",
                 "renderQueue.signalDrawable(drawable)", "drawable.present()")
        positions = [DRAW.rindex(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("precondition(Thread.isMainThread && !inFlight)", FRAME)

    def test_scout_interaction_remains_event_driven(self):
        self.assertIn("isPaused = true", PREVIEW)
        self.assertIn("enableSetNeedsDisplay = true", PREVIEW)
        self.assertIn("onContextMenu?(event)", PREVIEW)
        self.assertIn("onSelect?()", PREVIEW)
        self.assertIn("isRotating = event.modifierFlags.contains(.option)", PREVIEW)
        self.assertIn("MetalViewerMPRSceneRotation.applyingDrag(", PREVIEW)
        self.assertIn("onRotation?(rotation)", PREVIEW)
        self.assertIn("onTransferDrag?(event)", PREVIEW)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_renderer_initializer_submission_and_view_typecheck(self):
        # Stub only ROI data/meshing. Frame ownership, bindings, submission, pipeline
        # creation, rotation and the MTKView itself come from production source.
        renderer = RENDERER.split("    private static func makeSurfaceVertices(", 1)[0]
        renderer += """
    private static func makeSurfaceVertices(for roi: MetalStudyROI) -> [MetalStudyROISurfaceVertex] { [] }
}
"""
        harness = "import AppKit\nimport MetalKit\nimport QuartzCore\nimport simd\n" + FRAME
        harness += """
private struct MetalStudyROI { var colorRed, colorGreen, colorBlue: Double }
"""
        harness += "\n" + declaration("struct MetalStudyROISurfaceVertex")
        harness += "\n" + declaration("private struct MetalViewerScoutROIUniforms")
        harness += "\n" + declaration("enum MetalViewerMPRSceneRotation", (SOURCES / "MetalViewerModels.swift").read_text())
        harness += "\n" + renderer + "\n" + PREVIEW
        with tempfile.TemporaryDirectory(prefix="horos-scout-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                str(path), str(SOURCES / "MetalPipelineCache.swift"), str(SOURCES / "MetalPerformanceTrace.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
