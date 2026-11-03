"""Non-build checks for the Planar rectangle-based WL/WW command."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer"
MODEL = (ROOT / "MetalViewerModels.swift").read_text()
RENDERER = (ROOT / "MetalViewerRenderer.swift").read_text()
VIEW = (ROOT / "MetalImageView.swift").read_text()
SHADER = (ROOT / "MetalShaders.metal").read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def run_swift(source, *, typecheck=False):
    swift = subprocess.check_output(["xcrun", "--find", "swiftc" if typecheck else "swift"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="horos-roi-window-") as directory:
        path = Path(directory) / "ROIWindow.swift"
        path.write_text(source)
        arguments = [swift, "-swift-version", "5", "-target", "arm64-apple-macosx27.0",
                     "-sdk", sdk, "-module-cache-path", "/tmp/horos-frame-module-cache"]
        arguments += ["-typecheck"] if typecheck else ["-Xfrontend", "-parse-as-library"]
        subprocess.run(arguments + [str(path)], check=True, timeout=90)


POLICY = declaration(MODEL, "enum MetalViewerROIWindow")
WINDOW = declaration(MODEL, "struct MetalViewerWindowLevel: Equatable")


class PlanarROIWindowTests(unittest.TestCase):
    def test_range_and_retina_rectangle_math(self):
        run_swift("import Foundation\nimport CoreGraphics\n" + POLICY + "\n" + WINDOW + r'''
@main struct Test {
    static func main() {
        func window(_ pixels: [Float], width: Int? = nil, height: Int = 1, rowStride: Int? = nil) -> MetalViewerWindowLevel? {
            pixels.withUnsafeBufferPointer {
                MetalViewerROIWindow.window(pixels: $0, width: width ?? pixels.count,
                                            height: height, rowStride: rowStride ?? pixels.count)
            }
        }
        precondition(window([-1000, -300, 0, 1000]) == MetalViewerWindowLevel(level: 0, width: 2000))
        precondition(window([100, 200, 300]) == MetalViewerWindowLevel(level: 200, width: 200))
        precondition(window([-300, -100]) == MetalViewerWindowLevel(level: -200, width: 200))
        precondition(window([42, 42]) == MetalViewerWindowLevel(level: 42, width: 1))
        precondition(window([0.25, 0.75]) == MetalViewerWindowLevel(level: 0.5, width: 1))
        precondition(window([.nan, -.infinity, 100, 200, .infinity]) == MetalViewerWindowLevel(level: 150, width: 100))
        precondition(window([.nan, .infinity, -.infinity]) == nil)
        precondition(window([]) == nil)
        precondition(window([1], width: 2, rowStride: 2) == nil)
        // Ignore row padding: it is neither an image pixel nor part of the range.
        precondition(window([100, 200, -9999, 300, 400, 9999], width: 2, height: 2, rowStride: 3)
                     == MetalViewerWindowLevel(level: 250, width: 300))
        precondition(window([-.greatestFiniteMagnitude, .greatestFiniteMagnitude]) == nil)

        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let size = CGSize(width: 400, height: 200)
        func rect(_ selection: CGRect, flipped: Bool = false, bounds testBounds: CGRect? = nil) -> CGRect? {
            MetalViewerROIWindow.pixelRect(selection: selection, bounds: testBounds ?? bounds, drawableSize: size, isFlipped: flipped)
        }
        precondition(rect(CGRect(x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 20, y: 80, width: 60, height: 80))
        precondition(rect(CGRect(x: 10, y: 20, width: 30, height: 40), flipped: true) == CGRect(x: 20, y: 40, width: 60, height: 80))
        precondition(rect(CGRect(x: 40, y: 60, width: -30, height: -40)) == CGRect(x: 20, y: 80, width: 60, height: 80))
        precondition(rect(CGRect(x: -10, y: -20, width: 50, height: 80)) == CGRect(x: 0, y: 80, width: 80, height: 120))
        precondition(rect(CGRect(x: 200, y: 0, width: 1, height: 10)) == nil)
        precondition(rect(.zero) == nil)
        precondition(rect(bounds, bounds: .zero) == nil)
        precondition(rect(CGRect(x: 10.25, y: 20.25, width: 30, height: 40)) == CGRect(x: 20, y: 79, width: 61, height: 81))
        precondition(rect(CGRect(x: 20, y: 40, width: 30, height: 40), bounds: CGRect(x: 10, y: 20, width: 200, height: 100))
                     == CGRect(x: 20, y: 80, width: 60, height: 80))
        print("ROI range, nonfinite pixels, stride, clipping, flipped views and Retina checks passed")
    }
}
''')

    def test_new_metal_and_appkit_apis_typecheck(self):
        request = declaration(RENDERER, "private struct MetalViewerROIWindowRequest")
        capture = declaration(RENDERER, "    func captureROIWindow(")
        cancel = declaration(RENDERER, "    func cancelROIWindowCapture(")
        encode = declaration(RENDERER, "    private func encodePendingROIWindow(")
        fields = VIEW.split("    private var roiWindowCompletion:", 1)[1].split("    var patientPointPlacementHandler:", 1)[0]
        interaction = VIEW.split("    func selectROIWindow(", 1)[1].split("    override func printView(", 1)[0]
        run_swift("import MetalKit\n" + POLICY + "\n" + WINDOW + "\n" + request + r'''
final class MetalPipelineCache {
    static func shared(for device: MTLDevice) throws -> MetalPipelineCache { fatalError() }
    func renderPipeline(vertex: String, fragment: String, colorPixelFormat: MTLPixelFormat,
                        depthPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState { fatalError() }
}
final class MetalViewerRenderFrame {
    var vertexArguments: MTL4ArgumentTable { fatalError() }
    var fragmentArguments: MTL4ArgumentTable { fatalError() }
    var encodingFailed = false
    func retainResource(_ resource: MTLResource) {}
}
final class Renderer {
    var deviceRef: MTLDevice { fatalError() }
    var renderCommandBuffer: MTL4CommandBuffer { fatalError() }
    enum Mode { case stack2D, mpr }
    var displayMode = Mode.stack2D
    var isOverlayWindowLevelActive = false
    func updateMPRHover(at point: CGPoint?, in bounds: CGRect) {}
    private var pendingROIWindow: MetalViewerROIWindowRequest?
''' + capture + "\n" + cancel + "\n" + encode + r'''
}
final class SelectionView: MTKView {
    let renderer = Renderer()
    let mprPreviewOverlayView = NSView()
    var windowLevelInteractionAllowedHandler: (() -> Bool)?
    func updateMouseToolCursor(modifierFlags: NSEvent.ModifierFlags) {}
    private var roiWindowCompletion:''' + fields + "    func selectROIWindow(" + interaction + "\n}", typecheck=True)

    def test_raw_values_are_taken_before_windowing_in_both_display_paths(self):
        for marker in ("fragment float4 metalViewerFragment(", "fragment float4 metalViewerMPRFragment("):
            shader = declaration(SHADER, marker)
            self.assertLess(shader.index("if (uniforms.roiWindowTarget == 1u)"), shader.index("const float baseMinValue"))
            self.assertLess(shader.index("return float4(overlayPixelValue,"), shader.index("const float overlayMinValue"))
            outside = shader.split("if (overlayCoord.x < 0.0", 1)[1].split("const float overlayPixelValue", 1)[0]
            self.assertIn("if (uniforms.roiWindowTarget == 2u) { discard_fragment(); }", outside)
        self.assertIn("if (!insideSource) { discard_fragment(); }", declaration(SHADER, "fragment float4 metalViewerMPRFragment("))
        for marker in ("private struct MetalUniforms", "private struct MetalMPRUniforms"):
            self.assertIn("var roiWindowTarget: UInt32 = 0", declaration(RENDERER, marker))

    def test_capture_is_asynchronous_and_resources_survive_gpu_completion(self):
        capture = declaration(RENDERER, "    private func encodePendingROIWindow(")
        self.assertIn("colorPixelFormat: .r32Float", capture)
        self.assertIn("MTLClearColorMake(.nan", capture)
        self.assertIn("frame.retainResource(texture)", capture)
        self.assertIn("frame.retainResource(depth)", capture)
        self.assertIn("frame.retainResource(buffer)", capture)
        self.assertIn("copy.barrier(afterQueueStages: .fragment, beforeStages: .blit", capture)
        self.assertIn("sourceSize: MTLSize(width: regionWidth, height: regionHeight, depth: 1)", capture)
        self.assertLess(capture.index("options.addFeedbackHandler"), capture.index("MetalViewerROIWindow.window(pixels:"))
        self.assertIn("DispatchQueue.global(qos: .userInitiated).async", capture)
        self.assertIn("DispatchQueue.main.async { request.completion(window) }", capture)
        self.assertNotRegex(capture, r"waitUntilCompleted|DispatchSemaphore|Thread.sleep")
        previews = declaration(RENDERER, "    private func drawMPRPreviewPanes(")
        self.assertLess(previews.index("if imagePipeline != nil { continue }"), previews.index("let intersectionVertices"))

    def test_selection_can_cancel_without_creating_a_study_roi(self):
        selection = VIEW.split("    func selectROIWindow(", 1)[1].split("    override func printView(", 1)[0]
        self.assertIn("self.roiWindowSelectionID == identifier", selection)
        self.assertIn("renderer.cancelROIWindowCapture()", selection)
        self.assertIn("override func resignFirstResponder()", selection)
        self.assertNotIn("studyROIStore", selection)
        self.assertIn("if event.keyCode == 53 { cancelROIWindowSelection() }", VIEW)
        self.assertIn("if roiWindowOwnsMouseGesture", declaration(VIEW, "    private func dragMouseInteraction("))
        self.assertIn("if !isSelectingROIWindow { updateMouseAnnotationState", declaration(VIEW, "    override func mouseMoved("))
        self.assertIn("if !isSelectingROIWindow { renderer.updateMPRHover", declaration(VIEW, "    override func mouseExited("))
        self.assertIn("self.cancelROIWindowSelection()", VIEW.split("renderer.stateDidChange =", 1)[1].split("renderer.mprRotationDidChange", 1)[0])
        controller = (ROOT / "MetalViewerWindowController.swift").read_text()
        toolbar = (ROOT / "MetalViewerToolbarView.swift").read_text()
        self.assertIn('"ROI WL/WW", comment: ""), command: .roiWindow', toolbar)
        self.assertIn("case .roiWindow:", controller)
        self.assertIn("activePaneView.selectROIWindow", controller)
        pane = (ROOT / "MetalViewerPaneView.swift").read_text()
        self.assertIn("self.applyWindowLevel(window)", declaration(pane, "    func selectROIWindow("))
        self.assertIn("renderer.applyWindowLevel(window, asCustom: true)", pane)

    def test_glass_hint_arms_immediately_and_disappears_on_mouse_down(self):
        controller = (ROOT / "MetalViewerWindowController.swift").read_text()
        command = controller.split("        case .roiWindow:", 1)[1].split("        case .preset(", 1)[0]
        self.assertIn("activePaneView.selectROIWindow", command)
        self.assertNotIn("NSAlert", command)
        self.assertNotIn("beginSheetModal", command)
        self.assertIn("showROIWindowHint()", declaration(VIEW, "    func selectROIWindow("))
        hint = declaration(VIEW, "    private func showROIWindowHint(")
        self.assertIn("roiWindowHintView.style = .regular", hint)
        self.assertIn("roiWindowHintView.effectIsInteractive = false", hint)
        self.assertIn("mprPreviewOverlayView.addSubview(roiWindowHintView)", hint)
        self.assertIn("cellSize(forBounds:", hint)
        overlay = declaration(VIEW, "private final class MetalMPRPreviewOverlayView")
        hit_test = declaration(overlay, "    override func hitTest(")
        self.assertIn("!owner.isSelectingROIWindow", hit_test)
        self.assertIn("return nil", hit_test)
        mouse_down = declaration(VIEW, "    private func beginMouseInteraction(")
        selection = mouse_down.split("        if isSelectingROIWindow {", 1)[1]
        self.assertLess(selection.index("roiWindowHintView.isHidden = true"), selection.index("roiWindowAnchor = dragAnchor"))
        self.assertIn("roiWindowHintView.isHidden = true", declaration(VIEW, "    private func clearROIWindowSelection("))


if __name__ == "__main__":
    unittest.main()
