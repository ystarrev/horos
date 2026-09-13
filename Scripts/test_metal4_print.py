"""Non-build checks for asynchronous Metal 4 Planar image printing."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_viewer import FRAME, SOURCES, SOURCE, declaration
from test_metal4_scout import declaration as source_declaration


PRINT = declaration("func makePrintFrame(at index:")
PANE_SOURCE = (SOURCES / "MetalViewerPaneView.swift").read_text()
WINDOW_SOURCE = (SOURCES / "MetalViewerWindowController.swift").read_text()
IMAGE_SOURCE = (SOURCES / "MetalImageView.swift").read_text()
IMAGE_PRINT = source_declaration("override func printView(", IMAGE_SOURCE)
PANE_PRINT = source_declaration("func makePrintFrame(completion:", PANE_SOURCE)
WINDOW_PRINT = source_declaration("private func printActiveImage()", WINDOW_SOURCE)


class Metal4PrintTests(unittest.TestCase):
    def test_focused_metal_view_forwards_print_to_the_window_image_handler(self):
        # The first responder inherits NSView.print: and otherwise bypasses the
        # window's offscreen image rendering, leaving AppKit a blank Metal layer.
        self.assertIn("override var acceptsFirstResponder: Bool { true }", IMAGE_SOURCE)
        self.assertIn("window?.makeFirstResponder(self)", IMAGE_SOURCE)
        self.assertIn("window?.printWindow(sender)", IMAGE_PRINT)
        self.assertNotIn("super.printView", IMAGE_PRINT)
        self.assertNotIn("NSPrintOperation", IMAGE_PRINT)
        window_action = source_declaration("override func printWindow(", WINDOW_SOURCE)
        self.assertIn("printImageHandler?()", window_action)
        self.assertIn("self?.printActiveImage()", WINDOW_SOURCE)

    def test_print_reuses_submission_with_a_separate_lazy_frame_slot(self):
        self.assertIn("precondition(Thread.isMainThread)", PRINT)
        self.assertIn("if printRenderFrame == nil", PRINT)
        self.assertIn("try? MetalViewerRenderFrame(device: deviceRef)", PRINT)
        self.assertLess(PRINT.index("guard let frame = printRenderFrame, !frame.inFlight"),
                        PRINT.index("frame.begin()"))
        self.assertLess(PRINT.index("frame.begin()"), PRINT.index("printOutputTexture?.width != width"))
        self.assertIn("printOutputTexture?.height != height", PRINT)
        self.assertNotIn("renderFrames", PRINT)
        self.assertNotRegex(PRINT, r"makeCommandQueue|makeCommandBuffer\(|MTLRenderPassDescriptor\(")
        self.assertIn("MTL4RenderPassDescriptor()", PRINT)

    def test_print_is_async_without_a_replacement_cpu_wait(self):
        self.assertIn("completion: @escaping (MetalPrintFrame?) -> Void", PRINT)
        self.assertNotRegex(PRINT, r"waitUntilCompleted|waitUntilScheduled|DispatchSemaphore|\.wait\(|Thread.sleep|RunLoop")
        self.assertIn("pane.makePrintFrame { [weak self] frame in", WINDOW_PRINT)
        self.assertIn("renderer.makePrintFrame(at: renderer.currentSliceIndex, completion: completion)", PANE_PRINT)
        self.assertIn("DispatchQueue.main.async { completion(nil) }", PANE_PRINT)

    def test_failed_preparation_completes_once_and_does_not_release_a_busy_slot(self):
        self.assertEqual(PRINT.count("completion(nil)"), 1)
        self.assertEqual(PRINT.count("completion(result)"), 1)
        self.assertLess(PRINT.index("if !submitted { DispatchQueue.main.async { completion(nil) } }"),
                        PRINT.index("guard pixList.indices.contains(index)"))
        self.assertLess(PRINT.index("guard let frame = printRenderFrame, !frame.inFlight"),
                        PRINT.index("if !submitted { frame.releaseCompletedResources() }"))
        encoder_failure = PRINT.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        self.assertIn("renderCommandBuffer.endCommandBuffer()", encoder_failure)
        uniform_failure = PRINT.split("guard frame.setUniforms", 1)[1].split("\n        }", 1)[0]
        self.assertLess(uniform_failure.index("encoder.endEncoding()"),
                        uniform_failure.index("renderCommandBuffer.endCommandBuffer()"))
        for failure in (encoder_failure, uniform_failure):
            self.assertIn("return", failure)
            self.assertNotIn("commit(", failure)

    def test_print_uniforms_and_all_texture_slots_preserve_existing_image_settings(self):
        self.assertIn("encoder.setArgumentTable(frame.vertexArguments, stages: .vertex)", PRINT)
        self.assertIn("encoder.setArgumentTable(frame.fragmentArguments, stages: .fragment)", PRINT)
        self.assertIn("frame.setVertexBuffer(vertexBuffer)", PRINT)
        self.assertIn("frame.setUniforms(&uniforms)", PRINT)
        self.assertIn("[nil, overlayVolumeTexture, floatDisplayVolumeTexture,", PRINT)
        self.assertIn("baseCLUTTexture, baseOpacityTexture, overlayCLUTTexture, overlayOpacityTexture,", PRINT)
        self.assertIn("signedDisplayVolumeTexture, unsignedDisplayVolumeTexture], sampler: samplerState", PRINT)
        for setting in ("rotationRadians: stackRotationRadians", "offset: .zero",
                        "baseWindowLevel: windowLevel", "baseWindowWidth: max(windowWidth, 1)",
                        "overlayBlend: overlayBlend", "movingWorldToVoxel: movingWorldToVoxel",
                        "imageInterpolationMode: UInt32(imageInterpolationMode.rawValue)",
                        "baseVolumeRescaleSlope: displayVolumeEntry?.rescaleSlope ?? 1",
                        "baseVolumeRescaleIntercept: displayVolumeEntry?.rescaleIntercept ?? 0"):
            self.assertIn(setting, PRINT)
        self.assertNotRegex(PRINT, r"encoder\.(?:setVertexBytes|setFragmentBytes|setVertexBuffer|setFragmentTexture|setFragmentSamplerState)\(")
        self.assertNotIn("setTransferTextures", SOURCE)

    def test_render_target_and_readback_preserve_dimensions_format_and_rows(self):
        self.assertIn("let maximumDimension = 4_096", PRINT)
        self.assertIn("currentPix.widthWithoutLoading()", PRINT)
        self.assertIn("currentPix.heightWithoutLoading()", PRINT)
        self.assertIn("pixelFormat: .bgra8Unorm", PRINT)
        self.assertIn("textureDescriptor.storageMode = .shared", PRINT)
        self.assertIn("colorAttachments[0].storeAction = .store", PRINT)
        self.assertIn("let bytesPerRow = width * 4", PRINT)
        self.assertIn("Data(count: bytesPerRow * height)", PRINT)
        self.assertIn("from: MTLRegionMake2D(0, 0, width, height)", PRINT)
        self.assertIn("MetalPrintFrame(bgraPixels: bgraPixels, width: width, height: height)", PRINT)
        self.assertNotIn("currentDrawable", PRINT)
        self.assertNotIn("present()", PRINT)

    def test_residency_submission_and_readback_lifetimes_are_ordered(self):
        steps = ("frame.retainResource(outputTexture)", "frame.renderPass = renderPassDescriptor",
                 "renderCommandBuffer.beginCommandBuffer(allocator: frame.allocator)",
                 "encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4)",
                 "encoder.endEncoding()", "frame.residency.commit()",
                 "renderCommandBuffer.useResidencySet(frame.residency)", "renderCommandBuffer.endCommandBuffer()",
                 "frame.inFlight = true", "submitted = true", "renderQueue.commit([renderCommandBuffer], options: options)")
        positions = [PRINT.rindex(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        feedback = PRINT.split("options.addFeedbackHandler", 1)[1]
        self.assertIn("[self, frame, outputTexture] feedback in", feedback)
        steps = ("if let error = feedback.error", "result = nil", "outputTexture.getBytes(",
                 "DispatchQueue.main.async", "withExtendedLifetime(self)",
                 "frame.releaseCompletedResources()", "completion(result)")
        positions = [feedback.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("currentPix", feedback)
        self.assertNotIn("currentSliceIndex", feedback)

    def test_ui_keeps_original_request_ignores_duplicates_and_handles_closed_windows(self):
        self.assertLess(WINDOW_PRINT.index("guard !isPreparingImagePrint"), WINDOW_PRINT.index("pane.makePrintFrame"))
        self.assertLess(WINDOW_PRINT.index("let jobTitle = pane.series.title"), WINDOW_PRINT.index("pane.makePrintFrame"))
        self.assertLess(WINDOW_PRINT.index("isPreparingImagePrint = true"), WINDOW_PRINT.index("pane.makePrintFrame"))
        callback = WINDOW_PRINT.split("pane.makePrintFrame", 1)[1]
        self.assertIn("defer { self.isPreparingImagePrint = false }", callback)
        self.assertLess(callback.index("self.window?.isVisible == true"), callback.index("NSPrintOperation("))
        self.assertIn("operation.jobTitle = jobTitle", callback)
        self.assertNotIn("pane.", callback)
        self.assertNotIn("activePaneView", callback)
        self.assertIn("if previousSliceIndex != currentSliceIndex", PRINT)
        self.assertIn("loadSlice(at: previousSliceIndex)", PRINT)

    def test_optional_timing_separates_gpu_work_and_pixel_readback(self):
        self.assertLess(PRINT.index('MetalPerformanceTrace.track(options, operation: "render.print"'),
                        PRINT.index("renderQueue.commit("))
        self.assertIn('MetalPerformanceTrace.end("render.print.readback", since: readbackStartedAt)', PRINT)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_print_submission_and_ui_typecheck_against_macos(self):
        # Stub image-loading/model state only, not Metal resources or submission.
        harness = "import AppKit\nimport MetalKit\nimport QuartzCore\nimport simd\n" + FRAME
        harness += "\n" + declaration("struct MetalPrintFrame")
        harness += "\n" + declaration("private struct MetalUniforms")
        harness += "\n" + source_declaration("private final class MetalImagePrintView", WINDOW_SOURCE)
        harness += "\nprivate final class ImageViewHarness: MTKView {\n" + IMAGE_PRINT + "\n}"
        harness += """
private struct Pix {
    func widthWithoutLoading() -> Int { 512 }
    func heightWithoutLoading() -> Int { 512 }
}
private enum TextureKind: UInt32 { case rescaledFloat, storedInt16Signed, storedInt16Unsigned }
private struct Entry { var textureKind: TextureKind; var rescaleSlope, rescaleIntercept: Float }
private final class PrintHarness {
    var deviceRef: MTLDevice { fatalError() }
    var renderQueue: MTL4CommandQueue { fatalError() }
    var renderCommandBuffer: MTL4CommandBuffer { fatalError() }
    var pipelineState: MTLRenderPipelineState { fatalError() }
    var samplerState: MTLSamplerState { fatalError() }
    var vertexBuffer: MTLBuffer { fatalError() }
    var printRenderFrame: MetalViewerRenderFrame?
    var printOutputTexture, overlayVolumeTexture, baseCLUTTexture, baseOpacityTexture: MTLTexture?
    var overlayCLUTTexture, overlayOpacityTexture: MTLTexture?
    var pixList: [Pix] = []
    var currentPix: Pix? { pixList.first }
    var currentSliceIndex = 0
    var imageAspectRatio: Float = 1
    var stackRotationRadians = Float(0), windowLevel = Float(0), windowWidth = Float(1)
    var overlayWindowLevel = Float(0), overlayWindowWidth = Float(1), overlayBlend = Float(0)
    var overlayTranslationWorld = SIMD3<Float>.zero
    var movingRotationCenterWorld = SIMD3<Float>.zero
    var overlayRotationRadians = SIMD3<Float>.zero
    var fixedVoxelToWorld = matrix_identity_float4x4, movingWorldToVoxel = matrix_identity_float4x4
    var baseHasCustomCLUT = false, overlayHasCustomCLUT = false
    var imageInterpolationMode = TextureKind.rescaledFloat
    func loadSlice(at index: Int) {}
    func stackDisplayVolumeTexture() -> MTLTexture? { nil }
    func stackDisplayVolumeEntry() -> Entry? { nil }
    func stackDisplayVolumeDimensions(volumeTexture: MTLTexture) -> SIMD3<UInt32> { .one }
    func stackDisplaySliceIndex() -> Float { 0 }
    func inverseRotationMatrix(for rotation: SIMD3<Float>) -> simd_float4x4 { matrix_identity_float4x4 }
""" + PRINT + """
}
private final class PaneHarness {
    struct Series { var title = "Print test" }
    struct MetalView { var renderer = PrintHarness() }
    var metalView: MetalView?
    var series = Series()
    var supportsImagePrinting = true
""" + PANE_PRINT + """
}
private final class WindowHarness: NSWindowController {
    var activePaneView: PaneHarness?
    var paneViews: [PaneHarness] = []
    var isPreparingImagePrint = false
""" + WINDOW_PRINT + "\n" + source_declaration("private func presentPrintAlert(", WINDOW_SOURCE) + "\n}"
        with tempfile.TemporaryDirectory(prefix="horos-print-api-") as directory:
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
