"""First-pass slice/annotation source contracts; no build or patient data access."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
PIX = (SOURCES / "DCMPix.m").read_text()
PANE = (SOURCES / "MetalViewer/MetalViewerPaneView.swift").read_text()
MODELS = (SOURCES / "MetalViewer/MetalViewerModels.swift").read_text()
RENDERER = (SOURCES / "MetalViewer/MetalViewerRenderer.swift").read_text()
VIEW = (SOURCES / "MetalViewer/MetalImageView.swift").read_text()


def objc_method(signature):
    return PIX.split(signature + "\n{", 1)[1].split("\n}", 1)[0]


def swift_method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class MetalSliceAnnotationTests(unittest.TestCase):
    def test_prepared_annotations_are_visible_to_swift_without_prefix_header(self):
        header = (SOURCES / "DCMPix.h").read_text()
        viewer_only = header.split("#ifdef OSIRIX_VIEWER", 1)[1].split("#endif", 1)[0]
        declaration = "- (NSDictionary*)preparedDisplayAnnotations;"
        self.assertIn(declaration, header)
        self.assertNotIn("preparedDisplayAnnotations", viewer_only)
        self.assertIn(declaration, header.split("#ifdef OSIRIX_VIEWER", 1)[1].split("#endif", 1)[1])

    def test_first_slice_prepares_metadata_without_loading_pixels(self):
        prepared = objc_method("- (NSDictionary*)preparedDisplayAnnotations")
        self.assertIn("if (!customImageAnnotationsLoaded)", prepared)
        self.assertIn("[self loadCustomImageAnnotations]", prepared)
        self.assertLess(prepared.index("loadCustomImageAnnotations"), prepared.index("[annotationsDictionary copy]"))
        for body in (prepared, objc_method("- (void)loadCustomImageAnnotations")):
            for pixel_load in ("CheckLoad", "loadDICOM", "fImage", "setWidthWithoutLoading"):
                self.assertNotIn(pixel_load, body)

    def test_complete_layout_is_published_once(self):
        load = objc_method("- (void)loadCustomImageAnnotations")
        self.assertIn("NSMutableDictionary *resolvedAnnotations", load)
        self.assertIn("[resolvedAnnotations setObject:annotationsOUT forKey: key]", load)
        self.assertEqual(load.count("self.annotationsDictionary = resolvedAnnotations;"), 1)
        self.assertLess(load.index("[resolvedAnnotations setObject:"), load.index("self.annotationsDictionary ="))
        self.assertNotIn("[annotationsDictionary setObject:", load)
        self.assertNotIn("removeAllObjects", load)

    def test_readers_and_writers_share_stable_recursive_lock(self):
        for signature in ("- (NSDictionary*)preparedDisplayAnnotations",
                          "- (void)loadCustomImageAnnotations",
                          "- (NSMutableDictionary*) annotationsDictionary",
                          "- (void) setAnnotationsDictionary: (NSMutableDictionary*) d",
                          "- (void) reloadAnnotations"):
            with self.subTest(signature=signature):
                body = objc_method(signature)
                self.assertIn("[checking lock]", body)
                self.assertIn("@finally { [checking unlock]; }", body)
                self.assertNotIn("@synchronized( annotationsDictionary)", body)
        self.assertIn("checking = [[NSRecursiveLock alloc] init]", PIX)

    def test_intentionally_empty_layout_is_cached_and_invalidation_reloads(self):
        setter = objc_method("- (void) setAnnotationsDictionary: (NSMutableDictionary*) d")
        self.assertIn("customImageAnnotationsLoaded = d != nil", setter)
        self.assertIn("[d mutableCopy]", setter)
        self.assertNotIn("d.count", setter)
        self.assertIn("customImageAnnotationsLoaded = NO", objc_method("- (void) reloadAnnotations"))
        for signature in ("- (id)copyWithZone:(NSZone *)zone", "-(void) copySUVfrom: (DCMPix*)from"):
            self.assertIn("customImageAnnotationsLoaded", objc_method(signature))

    def test_pixel_load_does_not_publish_an_empty_intermediate_layout(self):
        for signature in ("- (BOOL)loadDICOMModernNonImage", "- (BOOL)loadDICOMModernDCMTK"):
            body = objc_method(signature)
            self.assertIn("[self loadCustomImageAnnotations]", body)
            self.assertNotIn("[annotationsDictionary removeAllObjects]", body)

    def test_draw_uses_snapshot_and_never_loads_orientation_from_dcmpix(self):
        annotation = PANE.split("private final class AnnotationOverlayView:", 1)[1].split(
            "private final class AnnotatedPrintImageView:", 1
        )[0]
        state = annotation.split("struct State {", 1)[1].split("\n        }", 1)[0]
        self.assertIn("let imageMetadata: ImageMetadata", state)
        self.assertNotIn("DCMPix", state)
        self.assertIn("typealias ImageMetadata = MetalViewerImageMetadata", annotation)
        metadata = MODELS.split("struct MetalViewerImageMetadata {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("pix.preparedDisplayAnnotations()", metadata)
        self.assertNotIn("preparedDisplayAnnotations", annotation)
        self.assertIn("let annotationsDictionary = state.imageMetadata.annotations", annotation)
        self.assertIn("orientationText(for: geometry.row", annotation)
        self.assertIn("orientationText(for: geometry.column", annotation)
        self.assertNotIn("state.pix", annotation)
        self.assertNotIn('NSSelectorFromString("orientation:")', annotation)
        self.assertNotIn("CheckLoad", annotation)
        self.assertEqual(PANE.count("imageMetadata: AnnotationOverlayView.ImageMetadata(pix: pix)"), 1)  # Printing only.
        live = swift_method(PANE, "private func updateAnnotationOverlay()")
        self.assertIn("imageMetadata: metadata", live)
        self.assertIn("metalView.renderer.currentImageMetadata", live)

    def test_source_dimensions_are_stable_before_first_texture_and_annotation(self):
        cache = MODELS.split("private final class MetalDICOMFrameGeometryCache", 1)[1].split(
            "struct MetalViewerSliceGeometry", 1
        )[0]
        self.assertIn('reader.integerValue(forTag: "0028,0011")', cache)
        self.assertIn('reader.integerValue(forTag: "0028,0010")', cache)
        geometry = MODELS.split("struct MetalViewerSliceGeometry", 1)[1].split(
            "init?(attributes:", 1
        )[0]
        self.assertIn("self.width = Double(metadata.width)", geometry)
        self.assertIn("self.height = Double(metadata.height)", geometry)
        self.assertNotIn("widthWithoutLoading", geometry)
        load = swift_method(RENDERER, "private func loadSlice(at index: Int,")
        self.assertLess(load.index("setWidthWithoutLoading"), load.index("imageAspectRatio ="))
        self.assertLess(load.index("imageAspectRatio ="), load.index("makeImmediateStackSliceTextureEntry"))
        self.assertLess(load.index("makeImmediateStackSliceTextureEntry"), load.index("stateDidChange?"))

    def test_legacy_roi_drawing_does_not_reintroduce_lazy_pixel_load(self):
        for draw in (swift_method(VIEW, "fileprivate func drawLegacyROIOverlay()"),
                     swift_method(RENDERER, "func stackScreenPoint(for pixelPoint:")):
            self.assertIn("pix.widthWithoutLoading()", draw)
            self.assertIn("pix.heightWithoutLoading()", draw)
            self.assertNotIn("pix.pwidth", draw)
            self.assertNotIn("pix.pheight", draw)

    def test_unsuccessful_presentation_wait_is_removed(self):
        self.assertNotIn("presentsWithTransaction = true", VIEW)
        self.assertNotIn("waitUntilScheduled()", RENDERER)
        self.assertEqual(RENDERER.count("commandBuffer.present(drawable)"), 3)
        self.assertEqual(RENDERER.count("trackRetrievalPresentation(of: drawable, commandBuffer: commandBuffer)"), 3)


if __name__ == "__main__":
    unittest.main()
