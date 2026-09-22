"""Source contracts and Swift type checks for Planar annotation size; no app build."""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
SETTINGS = (SOURCES / "HorosSettingsWindowController.swift").read_text()
MODELS = (SOURCES / "MetalViewer/MetalViewerModels.swift").read_text()
PANE = (SOURCES / "MetalViewer/MetalViewerPaneView.swift").read_text()
WINDOW = (SOURCES / "MetalViewer/MetalViewerWindowController.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


PREFERENCES = declaration(MODELS, "enum MetalViewerAnnotationPreferences")
OVERLAY = declaration(PANE, "private final class AnnotationOverlayView:")
SETTINGS_PANE = declaration(SETTINGS, "private final class AnnotationsSettingsPaneViewController:")


class MetalAnnotationSizeTests(unittest.TestCase):
    def test_saved_size_preserves_default_and_bounds_invalid_values(self):
        self.assertIn('"HorosMetalViewerAnnotationFontSize"', PREFERENCES)
        self.assertIn("defaultFontSize: CGFloat = 12", PREFERENCES)
        self.assertIn("fontSizeRange: ClosedRange<CGFloat> = 10...24", PREFERENCES)
        self.assertIn("as? NSNumber else", PREFERENCES)
        self.assertIn("guard size.isFinite else { return defaultFontSize }", PREFERENCES)
        self.assertIn("min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)", PREFERENCES)
        self.assertIn("guard size != fontSize else { return }", PREFERENCES)
        self.assertIn("UserDefaults.standard.set(Double(size), forKey: fontSizeDefaultsKey)", PREFERENCES)

    def test_settings_field_and_stepper_share_a_global_persistent_size(self):
        configure = declaration(SETTINGS_PANE, "private func configureAnnotationSizeControls()")
        self.assertIn("MetalViewerAnnotationPreferences.fontSizeRange", configure)
        self.assertIn("formatter.allowsFloats = false", configure)
        self.assertIn("annotationFontSizeStepper.valueWraps = false", configure)
        self.assertEqual(configure.count("#selector(annotationFontSizeChanged(_:))"), 2)
        action = declaration(SETTINGS_PANE, "@objc private func annotationFontSizeChanged(")
        self.assertIn("MetalViewerAnnotationPreferences.setFontSize(CGFloat(sender.doubleValue))", action)
        self.assertIn("annotationFontSizeField.doubleValue = size", action)
        self.assertIn("annotationFontSizeStepper.doubleValue = size", action)
        self.assertNotIn("currentModality", action)
        refresh = declaration(SETTINGS_PANE, "private func refreshUI()")
        self.assertNotIn("annotationFontSize", refresh)  # Inheritance must not disable the global setting.

    def test_all_annotation_styles_and_spacing_use_selected_size(self):
        style = declaration(OVERLAY, "private struct TextStyle")
        self.assertIn("NSFont.systemFont(ofSize: fontSize, weight: .medium)", style)
        self.assertIn("lineHeight = ceil(font.ascender - font.descender + 2)", style)
        self.assertEqual(style.count(".font: font"), 3)
        self.assertNotIn("Self.lineHeight", OVERLAY)
        self.assertNotIn("Self.mainFont", OVERLAY)
        self.assertNotIn("Self.textAttributes", OVERLAY)
        self.assertEqual(OVERLAY.count("let lineHeight = textStyle.lineHeight"), 2)
        draw = declaration(OVERLAY, "override func draw(")
        self.assertIn("if textStyle.fontSize != fontSize", draw)
        self.assertLess(draw.index("textStyle = TextStyle(fontSize: fontSize)"), draw.index("drawOrientation("))

    def test_existing_default_notification_redraws_open_panes_without_pixel_load(self):
        observer = WINDOW.split("annotationDefaultsObserver = NotificationCenter.default.addObserver(", 1)[1]
        observer = observer.split("scoutPlacementObserver =", 1)[0]
        self.assertIn("UserDefaults.didChangeNotification", observer)
        self.assertIn("object: UserDefaults.standard", observer)
        self.assertIn("self.applyAnnotationLevel(MetalViewerAnnotationLevel.current)", observer)
        self.assertIn("pane.setAnnotationLevel(level)", declaration(WINDOW, "private func applyAnnotationLevel("))
        self.assertIn("updateAnnotationOverlay()", declaration(PANE, "func setAnnotationLevel("))
        update = declaration(PANE, "private func updateAnnotationOverlay()")
        self.assertIn("annotationOverlay.overlayState =", update)
        self.assertIn("metalView.renderer.currentImageMetadata", update)
        self.assertNotIn("loadSlice", update)
        self.assertNotIn("DCMPix", OVERLAY)

    def test_settings_toolbar_does_not_overlap_at_minimum_width(self):
        layout = declaration(SETTINGS_PANE, "private func layoutControls()")
        # Evaluate just the numeric frame expressions used by the first toolbar row.
        frames = re.findall(r"(\w+)\.frame = NSRect\(x: ([^,]+), y: (topY[^,]*), width: ([^,]+), height: ([^)]+)\)", layout)
        for width in (1100, 1120, 1280):
            values = {"sideInset": 34, "topY": 28, "fontSizeX": width - 34 - 176}
            rects = []
            for name, x, _, size, _ in frames:
                left = eval(x, {"__builtins__": {}}, values)
                right = left + eval(size, {"__builtins__": {}}, values)
                rects.append((left, right, name))
            self.assertEqual(len(rects), 11)
            rects.sort()
            for previous, current in zip(rects, rects[1:]):
                self.assertLessEqual(previous[1], current[0], (width, previous, current))
            self.assertLessEqual(rects[-1][1], width - 34)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Needs macOS Swift SDK")
    def test_actual_preference_controls_and_overlay_typecheck(self):
        harness = """import AppKit
struct MetalViewerImageMetadata {
    var annotations: [String: Any] = [:]
    var viewPosition: String?, patientPosition: String?, laterality: String?
    var voiLUTApplied = false
}
struct MetalViewerSliceGeometry {
    var row, column: SIMD3<Double>
    var sliceThickness, sliceLocation: Double
}
enum MetalImageView {
    struct MouseAnnotationState {
        var pixelPoint: CGPoint
        var pixelValue: Float
        var dicomPoint: SIMD3<Double>
    }
}
enum MetalViewerAnnotationLevel { case none, graphics, basic, full }
"""
        harness += PREFERENCES + "\n" + OVERLAY
        harness += "\nprivate final class SettingsCheck: NSViewController {\n"
        harness += "\n".join(re.findall(r"    private let annotationFontSize\w+ = [^\n]+", SETTINGS_PANE))
        harness += "\n" + declaration(SETTINGS_PANE, "private func configureAnnotationSizeControls()")
        harness += "\n" + declaration(SETTINGS_PANE, "@objc private func annotationFontSizeChanged(") + "\n}\n"
        with tempfile.TemporaryDirectory(prefix="horos-annotation-size-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run(
                ["xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                 "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache", str(path)],
                capture_output=True, text=True, timeout=90,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
