"""Non-build checks for Metal 4 Planar/MPR display submission and capture."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
SOURCE = (SOURCES / "MetalViewerRenderer.swift").read_text()


def declaration(marker):
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


FRAME = declaration("final class MetalViewerRenderFrame")
FRAME_BEGIN = declaration("    func makeRenderEncoder(")
DRAW = declaration("func draw(in view:")
MPR = declaration("private func drawMPR(in view:")
MPR3D = declaration("private func drawMPR3D(in view:")
INSETS = declaration("private func drawMPRPreviewPanes(")
BEGIN = declaration("private func makeDisplayEncoder(")
SUBMIT = declaration("private func submitDisplayFrame(")
CAPTURE = declaration("private func encodePendingFrameCapture(")
TRACK = declaration("private func trackRetrievalPresentation(")


class Metal4ViewerTests(unittest.TestCase):
    def test_display_uses_metal4_while_registration_remains_separate(self):
        self.assertIn("private let renderQueue: MTL4CommandQueue", SOURCE)
        self.assertIn("private let renderCommandBuffer: MTL4CommandBuffer", SOURCE)
        self.assertEqual(SOURCE.count("device.makeCommandBuffer()"), 2)  # Display and per-job registration.
        for body, operation in ((DRAW, "draw.planar"), (MPR, "draw.mpr"), (MPR3D, "draw.mpr3D")):
            self.assertIn("view.currentMTL4RenderPassDescriptor", body)
            self.assertIn("makeDisplayEncoder(", body)
            self.assertIn(f'operation: "{operation}"', body)
            self.assertNotIn("makeCommandBuffer()", body)
            self.assertNotIn("commandBuffer.commit()", body)
        self.assertNotIn("private let commandQueue: MTLCommandQueue", SOURCE)
        self.assertIn("job.performCompute(", declaration("private func directionalMetricValue("))

    def test_display_has_no_legacy_bindings_or_inline_byte_paths(self):
        for body in (DRAW, MPR, MPR3D, INSETS):
            self.assertNotRegex(body, r"encoder\.(?:setVertexBytes|setFragmentBytes|setVertexBuffer|setFragmentTexture|setFragmentSamplerState)\(")
            self.assertNotIn("drawPrimitives(type:", body)
        self.assertNotIn("setMPRVertexData", SOURCE)
        self.assertNotIn("maximumInlineMetalVertexBytes", SOURCE)

    def test_pool_coalesces_without_waiting_and_does_not_consume_pending_capture(self):
        self.assertIn("renderFrames = try (0..<3).map", SOURCE)
        busy = DRAW.split("guard let frame = renderFrames.first", 1)[1].split("pendingRender = false", 1)[0]
        self.assertIn("!$0.inFlight", busy)
        self.assertIn("pendingRender = true", busy)
        self.assertNotIn("failPendingFrameCapture", busy)
        self.assertNotIn("currentDrawable", busy)
        for body in (FRAME, DRAW, MPR, MPR3D, BEGIN, SUBMIT, CAPTURE):
            self.assertNotRegex(body, r"waitUntilCompleted|waitUntilScheduled|DispatchSemaphore|Thread.sleep")
        self.assertIn("view?.needsDisplay = true", SUBMIT)
        self.assertNotIn("view?.draw()", SUBMIT)

    def test_uniform_and_vertex_uploads_are_per_frame_and_non_overlapping(self):
        self.assertIn("precondition(Thread.isMainThread && !inFlight)", FRAME)
        self.assertIn("allocator.reset()", FRAME)
        self.assertIn("uploadBufferIndex = 0", FRAME)
        self.assertIn("var offset = (uploadOffset + 255) & ~255", FRAME)
        self.assertIn("uploadBufferIndex += 1", FRAME)
        self.assertIn("uploadOffset = offset + bytes.count", FRAME)
        self.assertIn("buffer.gpuAddress + UInt64(offset)", FRAME)
        self.assertIn("vertexArguments.setAddress(address, index: 1)", FRAME)
        self.assertIn("fragmentArguments.setAddress(address, index: fragmentIndex)", FRAME)
        self.assertIn("frame.setUniforms(&roiUniforms, fragmentIndex: 1)", MPR)
        self.assertIn("frame.setUniforms(&previewUniforms)", INSETS)

    def test_sampler_and_all_texture_slots_are_explicit(self):
        self.assertIn("fragmentDescriptor.maxTextureBindCount = 9", FRAME)
        self.assertIn("fragmentDescriptor.maxSamplerStateBindCount = 2", FRAME)
        self.assertIn("maskSampler?.gpuResourceID ?? MTLResourceID(), index: 1", FRAME)
        self.assertIn("samplerDescriptor.supportArgumentBuffers = true", SOURCE)
        self.assertIn("fragmentArguments.setSamplerState(sampler.gpuResourceID, index: 0)", FRAME)
        self.assertIn("precondition(textures.count == 9)", FRAME)
        self.assertIn("texture?.gpuResourceID ?? MTLResourceID()", FRAME)
        self.assertIn("[nil, overlayVolumeTexture, floatDisplayVolumeTexture,", DRAW)
        self.assertIn("signedDisplayVolumeTexture, unsignedDisplayVolumeTexture]", DRAW)
        for body, binding in (
            (MPR, "[baseMPRTexture, overlayMPRTexture, nil,"),
            (INSETS, "[basePreparedVolume?.sourceTexture ?? baseVolumeTexture, overlayMPRTexture, nil,"),
        ):
            self.assertIn(binding, body)
            self.assertIn("baseCLUTTexture, baseOpacityTexture, overlayCLUTTexture, overlayOpacityTexture,", body)
            self.assertIn("nil, nil], sampler: samplerState", body)

    def test_depth_is_private_to_each_frame_and_matches_target_size(self):
        self.assertIn("private var depthTexture: MTLTexture?", FRAME)
        self.assertIn("depthTexture?.width != width", FRAME)
        self.assertIn("depthTexture?.height != height", FRAME)
        self.assertIn("depthTexture?.sampleCount != sampleCount", FRAME)
        self.assertIn("descriptor.storageMode = .private", FRAME)
        self.assertIn("retainResource(depthTexture)", FRAME)
        self.assertIn("frame.makeRenderEncoder(commandBuffer: renderCommandBuffer", BEGIN)
        self.assertIn("prepareDepth(width: drawable.texture.width, height: drawable.texture.height", FRAME_BEGIN)
        self.assertIn("descriptor.depthAttachment.texture = depth", FRAME_BEGIN)
        self.assertIn("descriptor.depthAttachment.loadAction = .clear", FRAME_BEGIN)
        self.assertIn("descriptor.depthAttachment.storeAction = .dontCare", FRAME_BEGIN)

    def test_roi_depth_opacity_and_draw_order_are_preserved(self):
        self.assertIn("mprDepthStencilDescriptor.depthCompareFunction = .lessEqual", SOURCE)
        self.assertIn("mprDepthStencilDescriptor.isDepthWriteEnabled = true", SOURCE)
        self.assertIn("color: SIMD4<Float>(surface.color, mprROISurfaceOpacity)", MPR)
        order = [MPR.index(marker) for marker in (
            "frame.setVertices(vertices)", "for surface in mprROISurfaceBuffers",
            "if let seedMesh", "let highlightVertices", "let borderVertices",
            "let intersectionVertices", "drawMPRPreviewPanes(")]
        self.assertEqual(order, sorted(order))
        self.assertIn("encoder.setCullMode(.none)", MPR)
        self.assertIn("encoder.setViewport(pane.viewport)", INSETS)
        self.assertIn("encoder.setScissorRect(pane.scissor)", INSETS)

    def test_resources_are_retained_and_resident_until_completion(self):
        for marker in ("resources: [ObjectIdentifier: MTLResource]", "var drawable:", "var renderPass:", "var drawableResidency:"):
            self.assertIn(marker, FRAME)
        self.assertIn("retainResource(buffer)", FRAME)
        self.assertIn("if let texture { retainResource(texture) }", FRAME)
        self.assertIn("retainResource(texture)", FRAME_BEGIN)
        self.assertIn("drawableResidency = layer.residencySet", FRAME_BEGIN)
        self.assertLess(SUBMIT.index("frame.residency.commit()"), SUBMIT.index("renderCommandBuffer.useResidencySet(frame.residency)"))
        self.assertIn("renderCommandBuffer.useResidencySet(residency)", SUBMIT)
        feedback = SUBMIT.split("options.addFeedbackHandler", 1)[1]
        self.assertIn("[self, frame, weak view] feedback in", feedback)
        self.assertLess(feedback.index("DispatchQueue.main.async"), feedback.index("frame.releaseCompletedResources()"))

    def test_submission_and_presentation_are_ordered(self):
        order = [SUBMIT.rindex(marker) for marker in (
            "encodePendingFrameCapture(", "frame.residency.commit()", "renderCommandBuffer.endCommandBuffer()",
            "frame.inFlight = true", "renderQueue.waitForDrawable(drawable)",
            "renderQueue.commit([renderCommandBuffer], options: options)",
            "renderQueue.signalDrawable(drawable)", "drawable.present()")]
        self.assertEqual(order, sorted(order))
        for body in (DRAW, MPR, MPR3D):
            self.assertLess(body.index("encoder.endEncoding()"), body.index("submitDisplayFrame("))

    def test_failed_recording_does_not_submit_partial_rois_or_capture(self):
        self.assertIn("encodingFailed = true", FRAME)
        self.assertIn("guard !encodingFailed else { return nil }", FRAME)
        failure = SUBMIT.split("guard !frame.encodingFailed else {", 1)[1].split("let options", 1)[0]
        self.assertIn("renderCommandBuffer.endCommandBuffer()", failure)
        self.assertIn("frame.releaseCompletedResources()", failure)
        self.assertIn("failPendingFrameCapture()", failure)
        self.assertNotIn("renderQueue.commit", failure)
        self.assertIn("releaseCompletedResources()", FRAME_BEGIN)

    def test_closed_window_does_not_strand_a_deferred_capture(self):
        self.assertIn("if view?.window?.isVisible != true { failPendingFrameCapture() }", SUBMIT)
        self.assertIn("failPendingFrameCapture()", declaration("    deinit {"))
        failure = declaration("private func failPendingFrameCapture()")
        self.assertLess(failure.index("pendingFrameCapture = nil"), failure.index("request.completion(nil)"))

    def test_capture_waits_for_attachment_store_and_reads_only_after_completion(self):
        self.assertIn("into commandBuffer: MTL4CommandBuffer", CAPTURE)
        self.assertIn("commandBuffer.makeComputeCommandEncoder()", CAPTURE)
        self.assertIn("barrier(afterQueueStages: .fragment, beforeStages: .blit, visibilityOptions: .device)", CAPTURE)
        order = [CAPTURE.index(marker) for marker in (
            "frame.retainResource(captureBuffer)", "copyEncoder.barrier(", "copyEncoder.copy(",
            "copyEncoder.endEncoding()", "options.addFeedbackHandler", "guard feedback.error == nil",
            "captureBuffer.contents()")]
        self.assertEqual(order, sorted(order))
        self.assertIn("destinationBytesPerImage: 0", CAPTURE)
        self.assertIn("DispatchQueue.main.async { request.completion(frame) }", CAPTURE)
        self.assertIn("(packedBytesPerRow + 255) & ~255", CAPTURE)
        self.assertIn("row * alignedBytesPerRow", CAPTURE)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_frame_submission_and_capture_typecheck_against_real_metal_api(self):
        # No app build, binary or GPU execution. Only the non-Metal app types are stand-ins.
        harness = """
import AppKit
import Metal
import MetalKit
import QuartzCore
struct MetalPrintFrame { let bgraPixels: Data; let width: Int; let height: Int }
enum MetalViewerRetrievalBenchmark {
    static func mark(_ name: String, frames: [Int]) {}
    static func timestampHandler(_ name: String, frames: [Int]) -> ((CFTimeInterval) -> Void)? { nil }
}
""" + FRAME + "\n" + declaration("private struct MetalViewerFrameCaptureRequest") + """
private final class DisplayHarness {
    let deviceRef: MTLDevice
    let renderQueue: MTL4CommandQueue
    let renderCommandBuffer: MTL4CommandBuffer
    var pendingFrameCapture: MetalViewerFrameCaptureRequest?
    var pendingRender = false
    var pendingRetrievalPresentation: ((CFTimeInterval) -> Void)?
    var pixList: [Int] = []
    init() { fatalError("Type checking only") }
""" + "\n".join((BEGIN, SUBMIT, CAPTURE, TRACK, declaration("private func failPendingFrameCapture()"))) + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-metal4-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", str(Path(directory) / "Modules"),
                str(path), str(SOURCES / "MetalPerformanceTrace.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
