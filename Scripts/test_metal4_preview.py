"""Non-build source guards for the Metal 4 database preview pilot."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/MetalViewer/MetalPreviewImageView.swift").read_text()
RENDERER = SOURCE.split("@objcMembers\nfinal class MetalPreviewImageView", 1)[0]
DRAW = RENDERER.split("func draw(in view: MTKView)", 1)[1]


class Metal4PreviewTests(unittest.TestCase):
    def test_preview_uses_metal4(self):
        self.assertIn("private let commandQueue: MTL4CommandQueue", RENDERER)
        self.assertIn("private let commandBuffer: MTL4CommandBuffer", RENDERER)
        self.assertEqual(RENDERER.count("device.makeCommandBuffer()"), 1)
        self.assertNotIn("makeCommandBuffer()", DRAW)
        self.assertIn("view.currentMTL4RenderPassDescriptor", DRAW)
        self.assertNotRegex(RENDERER, r"\b(?:setVertexBytes|setFragmentBytes|setVertexBuffer|setFragmentTexture)\(")
        self.assertNotIn("commandBuffer.commit()", DRAW)

    def test_frame_pool_never_waits_or_resets_an_inflight_allocator(self):
        self.assertIn("frames = try (0..<3).map", RENDERER)
        self.assertLess(DRAW.index("frames.first(where: { !$0.inFlight })"), DRAW.index("frame.allocator.reset()"))
        self.assertLess(DRAW.index("frame.allocator.reset()"), DRAW.index("commandBuffer.beginCommandBuffer"))
        self.assertNotRegex(RENDERER, r"waitUntilCompleted|waitUntilScheduled|DispatchSemaphore|Thread.sleep")
        self.assertIn("pendingRedraw = true", DRAW)
        self.assertIn("view?.needsDisplay = true", DRAW)
        self.assertNotIn("view?.draw()", DRAW)
        self.assertLess(DRAW.index("frame.inFlight = true"), DRAW.index("commandQueue.commit("))

    def test_completion_owns_resources_and_releases_on_main_thread(self):
        self.assertIn("[self, frame, weak view] feedback in", DRAW)
        completion = DRAW.split("options.addFeedbackHandler", 1)[1]
        self.assertLess(completion.index("DispatchQueue.main.async"), completion.index("frame.releaseCompletedResources()"))
        frame = RENDERER.split("private final class FrameResources", 1)[1].split("private let deviceRef", 1)[0]
        for retained in ("let allocator:", "let uniforms:", "let residency:", "var sampledTextures:",
                         "var drawable:", "var renderPass:", "var drawableResidency:"):
            self.assertIn(retained, frame)
        self.assertIn("inFlight = false", frame.split("func releaseCompletedResources()", 1)[1])

    def test_residency_includes_buffers_textures_and_the_view_drawables(self):
        self.assertIn("residency.addAllocation(vertexBuffer)", RENDERER)
        self.assertIn("residency.addAllocation(uniforms)", RENDERER)
        self.assertIn("frame.sampledTextures = textures.compactMap { $0 }", DRAW)
        self.assertIn("frame.residency.addAllocation(texture)", DRAW)
        self.assertLess(DRAW.index("frame.residency.commit()"), DRAW.index("commandBuffer.useResidencySet(frame.residency)"))
        self.assertIn("commandBuffer.useResidencySet(layer.residencySet)", DRAW)
        self.assertLess(DRAW.index("commandBuffer.beginCommandBuffer"), DRAW.index("commandBuffer.useResidencySet("))

    def test_separate_stage_tables_preserve_all_shader_slots_and_clear_nil_bindings(self):
        self.assertIn("vertexDescriptor.maxBufferBindCount = 2", RENDERER)
        self.assertIn("fragmentDescriptor.maxBufferBindCount = 1", RENDERER)
        self.assertIn("fragmentDescriptor.maxTextureBindCount = 6", RENDERER)
        self.assertEqual(RENDERER.count(".initializeBindings = true"), 2)
        self.assertIn("vertexArguments.setAddress(vertexBuffer.gpuAddress, index: 0)", RENDERER)
        self.assertIn("vertexArguments.setAddress(frame.uniforms.gpuAddress, index: 1)", DRAW)
        self.assertIn("fragmentArguments.setAddress(frame.uniforms.gpuAddress, index: 0)", DRAW)
        self.assertIn("[signedVolumeTexture, unsignedVolumeTexture, signedImageTexture, unsignedImageTexture]", DRAW)
        self.assertIn("texture?.gpuResourceID ?? MTLResourceID(), index: index + 2", DRAW)
        self.assertIn("encoder.setArgumentTable(vertexArguments, stages: .vertex)", DRAW)
        self.assertIn("encoder.setArgumentTable(fragmentArguments, stages: .fragment)", DRAW)

    def test_drawable_wait_commit_signal_and_present_order_is_explicit(self):
        steps = ("encoder.endEncoding()", "commandBuffer.endCommandBuffer()",
                 "commandQueue.waitForDrawable(drawable)", "commandQueue.commit([commandBuffer], options: options)",
                 "commandQueue.signalDrawable(drawable)", "drawable.present()")
        # Use the last endCommandBuffer; the earlier one handles encoder failure.
        positions = [DRAW.rindex(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_failed_encoder_ends_recording_without_leaking_a_slot(self):
        failure = DRAW.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        self.assertIn("commandBuffer.endCommandBuffer()", failure)
        self.assertIn("frame.releaseCompletedResources()", failure)
        self.assertNotIn("commandQueue.commit", failure)
        self.assertIn("return", failure)

    def test_uploads_reuse_only_unreferenced_matching_textures(self):
        pool = RENDERER.split("private func texture(width:", 1)[1].split("\n    }", 1)[0]
        self.assertIn("precondition(Thread.isMainThread)", pool)
        self.assertIn("$0.width != width || $0.height != height || $0.pixelFormat != pixelFormat", pool)
        self.assertIn("frame.inFlight && frame.sampledTextures.contains { $0 === candidate }", pool)
        self.assertLess(pool.index("imageTexturePool.first(where:"), pool.index("deviceRef.makeTexture("))
        self.assertIn("descriptor.storageMode = .shared", pool)
        self.assertIn("imageTexturePool.append(newTexture)", pool)

    def test_blank_preview_still_clears_and_shader_math_is_untouched(self):
        self.assertIn("if imageTexture != nil || sampledVolumeEntry != nil {", DRAW)
        self.assertIn("encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4)", DRAW)
        self.assertIn("MemoryLayout<MetalPreviewUniforms>.stride", RENDERER)
        self.assertIn("withUnsafeBytes(of: &uniforms)", DRAW)
        self.assertIn("frame.uniforms.contents().copyMemory", DRAW)
        self.assertIn("clearColor = MTLClearColorMake(0, 0, 0, 1)", SOURCE)
        self.assertIn('pipelines.renderPipeline(vertex: "metalPreviewVertex", fragment: "metalPreviewFragment")', RENDERER)


if __name__ == "__main__":
    unittest.main()
