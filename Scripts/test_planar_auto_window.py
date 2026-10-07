"""Non-build checks for Planar's default window/level policy."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer"


class PlanarAutoWindowTests(unittest.TestCase):
    def test_all_pane_creation_paths_default_to_auto(self):
        pane = (ROOT / "MetalViewerPaneView.swift").read_text()
        self.assertEqual(pane.count("usesAutomaticWindowLevel: true"), 3)
        self.assertNotIn("usesAutomaticWindowLevel: series.isMagneticResonance", pane)
        self.assertIn("windowLevelState: series.windowLevelState", pane)

    def test_preset_label_matches_initial_policy(self):
        model = (ROOT / "MetalViewerModels.swift").read_text()
        self.assertIn('var windowLevelPresetTitle = NSLocalizedString("Auto", comment: "")', model)

    def test_existing_window_is_preserved_before_auto_initialization(self):
        renderer = (ROOT / "MetalViewerRenderer.swift").read_text()
        load = renderer.split("private func loadSlice(", 1)[1].split("if let overlayPix", 1)[0]
        self.assertLess(load.index("if let customWindow = customSeriesWindowLevel"),
                        load.index("let defaultWindow = initialWindowLevelDefaults"))
        self.assertLess(load.index("else if let defaultWindow = defaultSeriesWindowLevel"),
                        load.index("let defaultWindow = initialWindowLevelDefaults"))


if __name__ == "__main__":
    unittest.main()
