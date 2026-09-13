"""Non-build checks for the optional half-step volume rendering mode."""

import math
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
RENDERER = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
VIEW = (SOURCES / "Metal3DVolumeView.swift").read_text()
TOOLBAR = (SOURCES / "Metal3DViewerToolbarController.swift").read_text()
WINDOW = (SOURCES / "Metal3DViewerWindowController.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def half_step_opacity(alpha):
    alpha = min(max(alpha, 0), 1)
    return alpha / (1 + math.sqrt(1 - alpha))


class MetalVolumeQualityTests(unittest.TestCase):
    def test_mode_defaults_off_and_halves_the_existing_step(self):
        for source in (TOOLBAR, VIEW, RENDERER):
            self.assertIn("var highQualityEnabled = false", source)
        step = declaration(RENDERER, "private func rayMarchStepSize()")
        self.assertIn("let normalStep = max(minimumNormalizedVoxelSpacing(), 0.000125)", step)
        self.assertIn("highQualityEnabled ? normalStep * 0.5 : normalStep", step)
        self.assertNotIn("isRotating", step)

    def test_toggle_reuses_volumes_and_refreshes_opacity_picking_and_display(self):
        setter = declaration(RENDERER, "func setHighQualityEnabled(")
        self.assertIn("guard highQualityEnabled != enabled", setter)
        self.assertLess(setter.index("highQualityEnabled = enabled"), setter.index("rebuildTransferTextures()"))
        self.assertNotIn("prepareVolumeTexture", setter)
        self.assertNotIn("requestVolumeTexture", setter)
        property_body = declaration(VIEW, "var highQualityEnabled = false")
        self.assertIn("renderer?.setHighQualityEnabled(highQualityEnabled)", property_body)
        self.assertIn("refreshSurfaceCursor()", property_body)
        self.assertIn("metalView.setNeedsDisplay(metalView.bounds)", property_body)
        configure = declaration(VIEW, "func configure(pixList:")
        self.assertIn("renderer.setHighQualityEnabled(highQualityEnabled)", configure)
        self.assertIn("toolbarController.highQualityHandler = { [weak self] isEnabled in", WINDOW)
        self.assertIn("self?.volumeView.highQualityEnabled = isEnabled", WINDOW)

    def test_both_transfer_paths_correct_for_half_steps(self):
        correction = declaration(RENDERER, "private func opacityForRayStep(")
        self.assertIn("guard highQualityEnabled else { return opacity }", correction)
        self.assertIn("alpha / (1 + sqrt(1 - alpha))", correction)
        self.assertIn("return opacityForRayStep(correctedOpacity)", declaration(RENDERER, "private func correctedOpacityForScalar("))
        composite = declaration(RENDERER, "private func applyCompositeOpacityCorrection(")
        self.assertIn("guard needsCorrection || highQualityEnabled", composite)
        self.assertIn("values[index] = opacityForRayStep(values[index])", composite)
        preintegrated = declaration(RENDERER, "private func makePreIntegratedTransferTexture()")
        self.assertIn("correctedOpacityForScalar(", preintegrated)
        self.assertIn("visibility * colorForScalar(scalar)", preintegrated)

    def test_toggle_diagnostic_logs_only_the_next_submitted_volume_frame(self):
        setter = declaration(RENDERER, "func setHighQualityEnabled(")
        self.assertIn("shouldLogQualityFrame = true", setter)
        draw = declaration(RENDERER, "func draw(in view:")
        self.assertIn("shouldLogQualityFrame && rayMarchScissorRect != nil", draw)
        self.assertIn("uniforms.stepSize / minimumNormalizedVoxelSpacing()", draw)
        self.assertLess(draw.index("let qualityDetails:"), draw.index("options.addFeedbackHandler"))
        feedback = draw.split("options.addFeedbackHandler", 1)[1].split("MetalPerformanceTrace.track", 1)[0]
        self.assertIn("if let qualityDetails", feedback)
        self.assertIn("feedback.gpuStartTime", feedback)
        self.assertIn("feedback.gpuEndTime", feedback)
        self.assertIn("feedback.error == nil, start.isFinite, end.isFinite, start > 0, end >= start", feedback)
        self.assertNotIn("highQualityEnabled", feedback)
        self.assertIn("VRQUALITY %@ gpu=%.3fms", feedback)
        self.assertIn("GPU timing unavailable", feedback)
        self.assertLess(draw.index("guard !frame.encodingFailed"),
                        draw.index("if qualityDetails != nil { shouldLogQualityFrame = false }"))
        self.assertNotRegex(draw, r"waitUntilCompleted|waitUntilScheduled|Thread.sleep")

    def test_two_half_steps_preserve_opacity_and_premultiplied_color(self):
        for alpha in (0, 1e-12, 1e-6, 0.0001, 0.01, 0.2, 0.8, 0.9999, 1):
            half = half_step_opacity(alpha)
            self.assertAlmostEqual(half + (1 - half) * half, alpha, places=14)
            self.assertGreaterEqual(half, 0)
            self.assertLessEqual(half, 1)
            for color in (0.0, 0.3, 1.0):
                composite = half * color + (1 - half) * half * color
                self.assertAlmostEqual(composite, alpha * color, places=14)
            for count in (1, 8, 256):
                self.assertAlmostEqual((1 - half) ** (count * 2), (1 - alpha) ** count, places=12)
        self.assertGreater(half_step_opacity(1e-12), 0)

    def test_step_budget_covers_the_volume_in_both_modes(self):
        uniforms = declaration(RENDERER, "private func makeUniforms(")
        self.assertIn("UInt32(max(Int(ceil(rayLength / stepSize)) + 8, 256))", uniforms)
        self.assertNotIn("8192", uniforms)
        for spacing in (0.00001, 0.001, 0.01):
            for quality_scale in (1, 0.5):
                step = max(spacing, 0.000125) * quality_scale
                length = math.sqrt(3)
                budget = max(math.ceil(length / step) + 8, 256)
                self.assertGreater(budget * step, length)
                self.assertLess(budget, 28000)
        picking = declaration(RENDERER, "private func startNextSurfaceCursorPickIfNeeded()")
        self.assertIn("makeUniforms(for: request.bounds.size, camera: camera)", picking)

    def test_toolbar_is_a_real_toggle_including_overflow(self):
        for method in ("func toolbarDefaultItemIdentifiers(", "func toolbarAllowedItemIdentifiers("):
            self.assertIn("ItemIdentifier.highQuality", declaration(TOOLBAR, method))
        item = TOOLBAR.split("case ItemIdentifier.highQuality:", 1)[1].split("case ItemIdentifier.visibility:", 1)[0]
        self.assertIn('NSLocalizedString("High Quality"', item)
        self.assertIn("button.setButtonType(.pushOnPushOff)", item)
        self.assertIn("button.setAccessibilityLabel(item.label)", item)
        self.assertIn("item.visibilityPriority = .high", item)
        self.assertIn("item.menuFormRepresentation = menuItem", item)
        self.assertIn("if flag {", item)  # Palette previews must not replace the real button reference.
        toggle = declaration(TOOLBAR, "private func toggleHighQuality(")
        self.assertIn("highQualityButton?.state = highQualityEnabled ? .on : .off", toggle)
        self.assertIn("highQualityMenuItem?.state = highQualityEnabled ? .on : .off", toggle)
        self.assertIn("highQualityHandler?(highQualityEnabled)", toggle)

    def test_saved_layout_gets_the_button_once_without_resetting_customization(self):
        install = declaration(TOOLBAR, "func installHighQualityItemIfNeeded(")
        self.assertIn('toolbar.identifier + ".highQualityItemInstalled"', install)
        self.assertIn("guard !UserDefaults.standard.bool(forKey: key)", install)
        self.assertIn("toolbar.items.contains", install)
        self.assertIn("toolbar.insertItem(withItemIdentifier: ItemIdentifier.highQuality", install)
        self.assertIn("UserDefaults.standard.set(true, forKey: key)", install)
        self.assertNotIn("removeItem", install)
        self.assertNotIn("configurationDictionary", install)
        self.assertLess(WINDOW.index("window?.toolbar = toolbar"),
                        WINDOW.index("toolbarController.installHighQualityItemIfNeeded(in: toolbar)"))

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires AppKit SDK")
    def test_toolbar_and_sampling_methods_typecheck(self):
        harness = """
import AppKit
final class DCMPix { var modalityString: String?; var rescaleType: String? }
private final class SamplingHarness {
    var highQualityEnabled = false
    var shouldLogQualityFrame = false
    let superSampling: Float = 1
    func rebuildTransferTextures() {}
    func minimumNormalizedVoxelSpacing() -> Float { 0.001 }
    func baseOpacityForScalar(_ scalar: Float, opacityPoints: [(x: Float, y: Float)], rawOpacityPoints: [(x: Float, y: Float)]) -> Float { 0.5 }
"""
        for name in ("setHighQualityEnabled", "rayMarchStepSize", "opacityCorrectionFactor",
                     "opacityForRayStep", "applyCompositeOpacityCorrection", "correctedOpacityForScalar"):
            harness += "\n" + declaration(RENDERER, f"func {name}(")
        harness += "\n}\n"
        with tempfile.TemporaryDirectory(prefix="horos-quality-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                str(path), str(SOURCES / "Metal3DViewerToolbarController.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
