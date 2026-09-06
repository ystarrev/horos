"""Query toolbar source/nib checks; no application build or database access."""

from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


class QueryToolbarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nib = ET.parse(ROOT / "Horos/Resources/Base.lproj/Query.xib")
        cls.source = (ROOT / "Horos/Sources/QueryController.mm").read_text()

    def test_shared_nib_does_not_decode_legacy_toolbar_items(self):
        self.assertEqual(self.nib.findall(".//toolbar"), [])
        self.assertEqual(self.nib.findall(".//toolbarItem"), [])
        identifiers = {node.get("id") for node in self.nib.iter() if node.get("id")}
        for node in self.nib.iter():
            for key in ("destination", "reference", "firstItem", "secondItem", "previousBinding"):
                if node.get(key):
                    self.assertIn(node.get(key), identifiers, (node.tag, key))

    def test_existing_custom_controls_keep_their_constraints_and_connections(self):
        for identifier, outlet, width in (("1107", "autoQRNavigationControl", "49"),
                                          ("1111", "authButton", "40"),
                                          ("1159", "autoQRInstancesPopup", "212")):
            control = self.nib.find(f"./objects/*[@id='{identifier}']")
            self.assertIsNotNone(control)
            self.assertEqual(control.get("translatesAutoresizingMaskIntoConstraints"), "NO")
            self.assertEqual(control.find("./constraints/constraint[@firstAttribute='width']").get("constant"), width)
            connection = self.nib.find(f".//outlet[@property='{outlet}']")
            self.assertEqual(connection.get("destination"), identifier)
        for action in ("changeAutoQRInstance:", "authAction:"):
            self.assertIsNotNone(self.nib.find(f".//action[@selector='{action}']"))
        for binding in ("self.currentAutoQR", "self.instancesMenuList"):
            self.assertIsNotNone(self.nib.find(f".//binding[@keyPath='{binding}']"))

    def test_toolbar_is_only_created_for_auto_query(self):
        initialization = self.source.split("- (id) initAutoQuery:", 1)[1].split("- (void)dealloc", 1)[0]
        self.assertEqual(initialization.count("[self configureAutoQueryToolbar]"), 1)
        self.assertRegex(initialization, r'else\s*\{\s*\[self configureAutoQueryToolbar\];')
        self.assertNotIn("self.window.toolbar = nil", initialization)
        construction = self.source.split("- (void)configureAutoQueryToolbar\n", 1)[1].split("- (void)configurePatientModeSelector", 1)[0]
        for deprecated in ("minSize", "maxSize", "setMinSize", "setMaxSize"):
            self.assertNotIn(deprecated, construction)
        for connection in ("item.view = autoQRNavigationControl", "item.view = autoQRInstancesPopup",
                           "item.view = authButton", "@selector(createAutoQRInstance:)",
                           "@selector(deleteAutoQRInstance:)", 'withKeyPath:@"isUnlocked"'):
            self.assertIn(connection, construction)
        self.assertIn("item.autovalidates = NO", construction)

    def test_gif_encoding_does_not_strongly_capture_the_viewer(self):
        pane = (ROOT / "Horos/Sources/MetalViewer/MetalViewerPaneView.swift").read_text()
        encoding = pane.split("let delays = framePlan.map(\\.delay)", 1)[1].split("return", 1)[0]
        self.assertIn("DispatchQueue.global(qos: .userInitiated).async { [weak self] in", encoding)
        self.assertIn("DispatchQueue.main.async { [weak self] in", encoding)
        self.assertIn("self?.finishAnimatedGIFCopy(", encoding)


if __name__ == "__main__":
    unittest.main()
