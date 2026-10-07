"""Non-build checks for Frame resources and launch wiring."""
import json
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CATALOGUE = ROOT / "Horos/Resources/FrameElectrodes"


class FrameViewerChecks(unittest.TestCase):
    def test_catalogue(self):
        entries = list(CATALOGUE.glob("*.txt"))
        self.assertEqual(len(entries), 33)
        for entry in entries:
            lines = entry.read_text().split()
            self.assertIn(lines[0], ("true", "false"), entry.name)
            points = [float(value) for value in lines[1:]]
            self.assertGreaterEqual(len(points), 2, entry.name)
            self.assertEqual(points[0], 0, entry.name)
            self.assertTrue(all(math.isfinite(p) and 0 <= p <= 2000 for p in points))
            self.assertEqual(points, sorted(points), entry.name)

    def test_reference_catalogue_entries(self):
        self.assertEqual((CATALOGUE / "3389S-40.txt").read_text().split(),
                         "false 0.0 0.5 2.0 2.5 4.0 4.5 6.0 6.5 8.0 390.0 400.0".split())
        self.assertTrue((CATALOGUE / "6142.txt").read_text().startswith("true"))
        self.assertTrue((CATALOGUE / "LICENSE").exists())

    def test_project_resources(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("FramePlan.swift", "FrameElectrodeGeometry.swift", "FrameViewerWindowController.swift",
                     "MetalViewerSceneSurface.swift", "FramePlanSRStore.swift", "LeksellFrameReader.swift"):
            self.assertIn(f"{name} in Sources", project)
        self.assertIn("FrameElectrodes in Resources", project)
        asset = ROOT / "Horos/Resources/Assets.xcassets/FrameViewer.imageset"
        description = json.loads((asset / "Contents.json").read_text())
        self.assertTrue((asset / description["images"][0]["filename"]).exists())

    def test_launch_and_calibration_boundary(self):
        browser = (ROOT / "Horos/Sources/BrowserController.m").read_text()
        self.assertIn('launcherName:@"HorosFrameViewerLauncher"', browser)
        self.assertIn('@"Open in Frame"', browser)
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn("Not frame calibrated", viewer)
        self.assertIn("MetalViewerPaneView(series: series)", viewer)
        model = (ROOT / "Horos/Sources/FrameViewer/FramePlan.swift").read_text()
        self.assertIn('coordinateSystem = "DICOM-LPS-mm"', model)
        self.assertIn("guard self.image == image", model)

    def test_overlay_coordinate_conversion(self):
        view = (ROOT / "Horos/Sources/MetalViewer/MetalImageView.swift").read_text()
        self.assertIn("imageRect: convert(slice.imageRect, from: owner)", view)
        self.assertIn("topLeftWorld: flip ? slice.bottomLeftWorld : slice.topLeftWorld", view)
        self.assertIn("bottomRightWorld: flip ? slice.topRightWorld : slice.bottomRightWorld", view)

    def test_electrodes_only_render_in_main_scene(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        overlay = viewer.split("pane.sliceOverlayDrawHandler =", 1)[1].split("buildInterface(in:", 1)[0]
        self.assertNotIn("plan.electrodes", overlay)
        self.assertIn("FrameElectrodeGeometry.localizerRods(self.plan.frameFit)", overlay)
        self.assertIn("let surfaces = plan.electrodes.flatMap", viewer)
        self.assertIn("pane.setSceneSurfaces(surfaces)", viewer)

    def test_empty_plan_controls(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn("model.isEnabled = isReady", viewer)
        self.assertIn("place.isEnabled = isReady", viewer)
        placement = viewer.split("@objc private func togglePlacement()", 1)[1].split("@objc private func goToTarget", 1)[0]
        self.assertIn("next.electrodes.append(electrode)", placement)
        self.assertIn("specification: self.chosenSpecification", placement)

    def test_sr_autosave_contract(self):
        store = (ROOT / "Horos/Sources/FrameViewer/FramePlanSRStore.swift").read_text()
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn("existing?.plan == expectedPlan", store)
        self.assertIn("try plan.validate(for: reference)", store)
        self.assertIn("try readPlan(at: temporary) == plan", store)
        self.assertIn("options: .atomic", store)
        self.assertIn("managedObjectContext.performAndWait", store)
        self.assertIn("source.independentDatabase()", store)
        self.assertIn("existing?.sopUID ?? Self.uid()", store)
        self.assertIn('"0008,0020"', store)
        apply = viewer.split("private func apply(", 1)[1].split("private func refresh()", 1)[0]
        self.assertIn("autosave()", apply)
        self.assertIn("if pendingSaves > 0 { closeAfterSaving = true; return false }", viewer)
        self.assertIn("store.load", viewer)
        self.assertNotIn('addButton(withTitle: "Discard")', viewer)
        self.assertNotIn("confirmDiscard", viewer)
        database = (ROOT / "Horos/Sources/DicomDatabase.mm").read_text()
        annotation = database.split('isEqualToString:@"Horos Frame Plan SR"]', 1)[1].split("}", 1)[0]
        self.assertIn("DICOMSR = YES", annotation)

    def test_target_placement_on_scene_planes(self):
        renderer = (ROOT / "Horos/Sources/MetalViewer/MetalViewerRenderer.swift").read_text()
        picking = renderer.split("func mprPlacementWorldPoint", 1)[1].split("func mprROISliceGeometries", 1)[0]
        self.assertIn("mprROIWorldPoint(at: point, in: bounds)", picking)
        self.assertIn("mprPlaneHit(at: point, in: bounds)", picking)
        self.assertIn("mprDisplayWorldPosition(for: hit.baseVoxel)", picking)
        view = (ROOT / "Horos/Sources/MetalViewer/MetalImageView.swift").read_text()
        self.assertIn("renderer.mprPlacementWorldPoint(at: dragAnchor, in: bounds)", view)
        self.assertIn("didSet { updateMouseToolCursor(modifierFlags: NSEvent.modifierFlags) }", view)
        cursor = view.split("private func updatePointerCursor(\n", 1)[1]
        self.assertIn("if patientPointPlacementHandler != nil", cursor)
        self.assertIn("NSCursor.crosshair.set()", cursor)
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        placement = viewer.split("@objc private func togglePlacement()", 1)[1].split("@objc private func goToTarget", 1)[0]
        self.assertIn("next.electrodes[index].isVisible = true", placement)
        self.assertNotIn("focusMPR", placement)

    def test_sr_metadata_rewrite_safety(self):
        bridge = (ROOT / "Horos/Sources/ModernDCMTKBridge.cpp").read_text()
        rewrite = bridge.split("int HorosModernDCMTKReplaceTagValue(", 1)[1].split("int HorosModernDCMTKGetDecompressionInfo", 1)[0]
        self.assertLess(rewrite.index("status = fileformat.loadAllDataIntoMemory()"),
                        rewrite.index("fileformat.saveFile(path"))
        store = (ROOT / "Horos/Sources/FrameViewer/FramePlanSRStore.swift").read_text()
        final_edit = store.index("guard writeTag(temporary")
        final_verification = store.index("guard try readPlan(at: temporary) == plan", final_edit)
        self.assertLess(final_verification, store.index("options: .atomic", final_edit))

    def test_existing_sr_autosaves_do_not_reimport(self):
        store = (ROOT / "Horos/Sources/FrameViewer/FramePlanSRStore.swift").read_text()
        atomic_write = store.index("options: .atomic")
        existing_save = store.index("if existing != nil", atomic_write)
        first_import = store.index("database.addFiles(", existing_save)
        self.assertIn("expectedPlan = plan", store[existing_save:first_import])
        self.assertIn("return", store[existing_save:first_import])
        self.assertEqual(store.count("database.addFiles("), 1)
        self.assertIn("postNotifications: true", store[first_import:])

    def test_electrode_list_frame_coordinates(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        cell = viewer.split("func tableView(_ tableView:", 1)[1].split("func tableViewSelectionDidChange", 1)[0]
        self.assertIn("let electrode = plan.electrodes[row]", cell)
        self.assertIn("guard let fit = plan.frameFit, fit.reviewed", cell)
        self.assertIn("fit.coordinates(of: electrode.targetLPS)", cell)
        self.assertIn('zip(["X", "Y", "Z"]', cell)
        self.assertIn('"Electrodes - Leksell (mm)"', viewer)

    def test_angle_controls_and_precision(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn("NSSlider(value: 90, minValue: 0, maxValue: 180", viewer)
        self.assertIn("slider.isContinuous = true", viewer)
        self.assertIn("imageDeclinationDegrees = value", viewer)
        self.assertIn('String(format: "%.1f", locale:', viewer)
        self.assertIn('String(format: "%@ %.1f", locale:', viewer)
        self.assertIn("if self.plan != snapshot { self.autosave() }", viewer)

    def test_target_controls_and_frame_lines(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn('coordinateFrame == nil ? "Image LPS (mm)" : "Leksell (mm)"', viewer)
        self.assertIn("setTargetCoordinates(target, in: coordinateFrame)", viewer)
        self.assertIn('[["R", "L"], ["A", "P"], ["S", "I"]]', viewer)
        self.assertIn("nudgeTarget(axis: axis", viewer)
        self.assertIn("field.widthAnchor.constraint(equalToConstant: 64)", viewer)
        self.assertNotIn("scroll.heightAnchor.constraint(equalToConstant: 160)", viewer)
        self.assertIn("sidebar.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor)", viewer)
        self.assertIn("pane.setSceneLines(FrameElectrodeGeometry.localizerLines", viewer)
        geometry = (ROOT / "Horos/Sources/FrameViewer/FrameElectrodeGeometry.swift").read_text()
        self.assertIn("color: SIMD3(0.9, 0, 0.8)", geometry)

    def test_reusable_brain_extraction(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("MRIBrainVolume.swift", "MRIBrainExtractor.swift", "MRIBrainDICOMLoader.swift", "MetalBrainVolume.swift"):
            self.assertIn(name + " in Sources", project)
        core = (ROOT / "Horos/Sources/ImageProcessing/MRIBrainExtractor.swift").read_text()
        self.assertNotIn("import AppKit", core)
        self.assertNotIn("FramePlan", core)
        for setting in ("brainThreshold = 0.7", "minimumRadiusMM = 8.0", "maximumRadiusMM = 10.0",
                        "minimumSearchMM = 7", "maximumSearchMM = 3", "iterations = 1000"):
            self.assertIn(setting, core)
        self.assertTrue((CATALOGUE / "BRAIN-EXTRACTOR-LICENSE").exists())
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        extraction = viewer.split("@objc private func toggleBrain()", 1)[1].split("@objc private func readFrame()", 1)[0]
        self.assertIn("DispatchQueue.global", extraction)
        self.assertIn("progress.cancel()", extraction)
        self.assertNotIn("autosave()", extraction)
        self.assertIn("self.brainProgress === progress", extraction)

    def test_brain_uses_clipped_volume_not_shell(self):
        viewer = (ROOT / "Horos/Sources/FrameViewer/FrameViewerWindowController.swift").read_text()
        self.assertIn("MRIBrainMaskedVolume(result: brain", viewer)
        self.assertIn("pane.setBrainVolume(brainButton.state == .on ? brainVolume : nil)", viewer)
        self.assertNotIn("MetalBrainSurface.make", viewer)
        shader = (ROOT / "Horos/Sources/MetalViewer/MetalShaders.metal").read_text()
        ray = shader.split("fragment MetalBrainOutput metalBrainVolumeFragment", 1)[1].split("struct MetalMPRROIVertex", 1)[0]
        for plane in ("axial", "coronal", "sagittal"):
            self.assertIn(f"metalBrainPlaneDistance(origin, direction, u.{plane})", ray)
        self.assertIn("sample.x / sample.y", ray)
        self.assertIn("float4(1, 0.7, 0.6, 0.2)", ray)
        self.assertIn("float4(1, 1, 0.9, 0.8)", ray)
        self.assertIn("out.depth =", ray)

    def test_mpr_shader_color_contract(self):
        shader = (ROOT / "Horos/Sources/MetalViewer/MetalShaders.metal").read_text()
        roi = shader.split("vertex MetalMPRROIRasterizerData metalViewerMPRROIVertex(", 1)[1].split("vertex Metal3DRasterizerData", 1)[0]
        self.assertNotIn(".color", roi)
        plane = shader.split("vertex MetalMPRRasterizerData metalViewerMPRVertex(", 1)[1].split("vertex MetalMPRBorderRasterizerData", 1)[0]
        self.assertIn("out.color = vertices[vertexID].color;", plane)


if __name__ == "__main__":
    unittest.main()
