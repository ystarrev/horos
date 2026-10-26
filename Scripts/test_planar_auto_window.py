"""Non-build checks for Planar's default window/level policy."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer"


class PlanarAutoWindowTests(unittest.TestCase):
    def test_all_pane_creation_paths_pass_series_window_before_auto(self):
        pane = (ROOT / "MetalViewerPaneView.swift").read_text()
        self.assertEqual(pane.count("usesAutomaticWindowLevel: true"), 3)
        self.assertNotIn("usesAutomaticWindowLevel: series.isMagneticResonance", pane)
        self.assertIn("windowLevelState: series.windowLevelState", pane)

    def test_preset_label_matches_initial_policy(self):
        model = (ROOT / "MetalViewerModels.swift").read_text()
        self.assertIn('var windowLevelPresetTitle = NSLocalizedString("Auto", comment: "")', model)
        series = model.split("final class MetalViewerSeries {", 1)[1].split("func sharesSourceSeries", 1)[0]
        self.assertIn("MetalViewerWindowLevel.initialPreset(for: modality)", series)
        self.assertIn("windowLevelState.defaultWindow = preset.window", series)
        self.assertIn("windowLevelPresetTitle = preset.title", series)
        self.assertNotIn("windowLevelState.customWindow =", series)

    def test_existing_window_is_preserved_before_auto_initialization(self):
        renderer = (ROOT / "MetalViewerRenderer.swift").read_text()
        load = renderer.split("private func loadSlice(", 1)[1].split("if let overlayPix", 1)[0]
        self.assertLess(load.index("if let customWindow = customSeriesWindowLevel"),
                        load.index("let defaultWindow = initialWindowLevelDefaults"))
        self.assertLess(load.index("else if let defaultWindow = defaultSeriesWindowLevel"),
                        load.index("let defaultWindow = initialWindowLevelDefaults"))

    def test_live_retrieval_preserves_current_window_and_title(self):
        controller = (ROOT / "MetalViewerWindowController.swift").read_text()
        update = controller.split("private func updateStudy(", 1)[1].split("context.study = study", 1)[0]
        self.assertIn("series.windowLevelState = previousSeries.windowLevelState", update)
        self.assertIn("series.windowLevelPresetTitle = previousSeries.windowLevelPresetTitle", update)

    def test_scouts_and_viewer_share_window_resolution(self):
        scout = (ROOT / "MetalViewerScoutView.swift").read_text()
        thumbnail = scout.split("private func makeThumbnail(for series:", 1)[1].split("private static func structuredReportIconThumbnail", 1)[0]
        self.assertIn("series.windowLevelState.resolvedWindow(", thumbnail)
        self.assertIn("modality: series.modality", thumbnail)
        self.assertNotIn("MetalViewerAutomaticWindowLevel.window", thumbnail)
        renderer = (ROOT / "MetalViewerRenderer.swift").read_text()
        initial = renderer.split("private func initialWindowLevelDefaults(", 1)[1].split("private func applyBaseWindowLevel", 1)[0]
        self.assertIn("MetalViewerWindowLevelState().resolvedWindow(", initial)

    def test_ct_brain_preset_values_without_building(self):
        model = (ROOT / "MetalViewerModels.swift").read_text()
        window = model.split("struct MetalViewerWindowLevel: Equatable {", 1)[1].split("enum MetalViewerAutomaticWindowLevel", 1)[0]
        state = model.split("struct MetalViewerWindowLevelState {", 1)[1].split("struct MetalViewerTransferFunctionState", 1)[0]
        inferred = model.split("    var inferredWindow: MetalViewerWindowLevel {", 1)[1].split("    var storedRangeWindow:", 1)[0]
        pixel_fixture = r'''
// Pixel sampling is tested separately. Exercise the production window policy
// and inferred-window fallback with known histogram results and DICOM values.
struct MetalStoredInt16PixelData {
    var automaticWindow: MetalViewerWindowLevel?
    var defaultWindow: MetalViewerWindowLevel?
    var storedRangeWindow: MetalViewerWindowLevel
    var inferredWindow: MetalViewerWindowLevel {
''' + inferred + "}\n"
        source = "import Foundation\nstruct MetalViewerWindowLevel: Equatable {" + window + "\nstruct MetalViewerWindowLevelState {" + state + pixel_fixture + r'''
enum MetalViewerAutomaticWindowLevel {
    static var calls = 0
    static func window(for pixels: MetalStoredInt16PixelData, modality: String?) -> MetalViewerWindowLevel? {
        calls += 1
        return pixels.automaticWindow
    }
}
@main struct Test {
    static func main() {
        let defaults = UserDefaults(suiteName: "org.horosproject.test-planar-window." + UUID().uuidString)!
        func setPreset(_ values: Any?) {
            let presets: [String: Any] = values.map { ["CT - Brain": $0] } ?? [:]
            defaults.setVolatileDomain(["WLWW3": presets], forName: UserDefaults.argumentDomain)
        }
        func preset(_ modality: String = "CT") -> (title: String, window: MetalViewerWindowLevel)? {
            MetalViewerWindowLevel.initialPreset(for: modality, defaults: defaults)
        }
        setPreset(nil)
        precondition(preset()?.title == "CT - Brain")
        precondition(preset()?.window == MetalViewerWindowLevel(level: 50, width: 100))
        for modality in ["MR", "PT", "NM", "SR", "OT", "", "CTP"] {
            precondition(preset(modality) == nil)
        }
        for values: Any in [[35.0, 90.0], [Float(35), Float(90)], [NSNumber(value: 35), NSNumber(value: 90)]] {
            setPreset(values)
            precondition(preset(" ct \n")?.window == MetalViewerWindowLevel(level: 35, width: 90))
        }
        for values: Any in [[50], [50, 0], [50, -100], [Double.nan, 100], [50, Double.infinity], ["bad", "values"]] {
            setPreset(values)
            precondition(preset()?.window == MetalViewerWindowLevel(level: 50, width: 100))
        }
        setPreset([25, 0.5])
        precondition(preset()?.window == MetalViewerWindowLevel(level: 25, width: 1))

        setPreset([35, 90])
        let automatic = MetalViewerWindowLevel(level: 300, width: 600)
        let dicom = MetalViewerWindowLevel(level: 1000, width: 2000)
        let range = MetalViewerWindowLevel(level: 1500, width: 4000)
        let pixels = MetalStoredInt16PixelData(automaticWindow: automatic, defaultWindow: dicom, storedRangeWindow: range)
        let initialState = MetalViewerWindowLevelState()
        precondition(initialState.resolvedWindow(for: pixels, modality: "CT", defaults: defaults) == preset()?.window)
        precondition(MetalViewerAutomaticWindowLevel.calls == 0)
        precondition(initialState.resolvedWindow(for: pixels, modality: "MR", defaults: defaults) == automatic)
        precondition(MetalViewerAutomaticWindowLevel.calls == 1)
        let saved = MetalViewerWindowLevel(level: 45, width: 120)
        let custom = MetalViewerWindowLevel(level: 65, width: 150)
        let savedState = MetalViewerWindowLevelState(defaultWindow: saved)
        let customState = MetalViewerWindowLevelState(defaultWindow: saved, customWindow: custom)
        for modality in ["CT", "MR"] {
            precondition(savedState.resolvedWindow(for: pixels, modality: modality, defaults: defaults) == saved)
            precondition(customState.resolvedWindow(for: pixels, modality: modality, defaults: defaults) == custom)
        }
        precondition(MetalViewerAutomaticWindowLevel.calls == 1)
        let missingHistogram = MetalStoredInt16PixelData(automaticWindow: nil, defaultWindow: dicom, storedRangeWindow: range)
        precondition(initialState.resolvedWindow(for: missingHistogram, modality: "MR", defaults: defaults) == dicom)
        for invalidWindow in [nil, MetalViewerWindowLevel(level: .nan, width: 100),
                              MetalViewerWindowLevel(level: 50, width: .infinity),
                              MetalViewerWindowLevel(level: 50, width: 0)] {
            let missingDefaults = MetalStoredInt16PixelData(automaticWindow: nil, defaultWindow: invalidWindow, storedRangeWindow: range)
            precondition(initialState.resolvedWindow(for: missingDefaults, modality: "MR", defaults: defaults) == range)
        }
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        print("Shared MR/CT window policy, saved settings, CT Brain presets, and fallback checks passed")
    }
}
'''
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="horos-planar-window-") as directory:
            path = pathlib.Path(directory) / "PlanarWindow.swift"
            path.write_text(source)
            subprocess.run([swift, "-Xfrontend", "-parse-as-library", "-swift-version", "5",
                            "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
                            "-module-cache-path", "/tmp/horos-frame-module-cache", str(path)],
                           check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
