#!/usr/bin/env python3
"""Source checks for FaceOff landmark detection (no Horos build required)."""

from pathlib import Path
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer/FaceOffSurfaceLandmarks.swift").read_text()
VIEW = (Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer/Metal3DVolumeView.swift").read_text()
CONTROLLER = (Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer/Metal3DViewerWindowController.swift").read_text()


class FaceOffFramingTests(unittest.TestCase):
    def test_focus_keeps_visible_eyes_and_nose_in_view(self):
        # Representative superior/inferior positions in a head-height image.
        for focus, zoom in [(-0.30, 1.35), (-0.48, 1.55)]:
            eye = (0.9 * zoom) * (-0.50 - focus)
            nose = (0.9 * zoom) * (-0.90 - focus)
            self.assertTrue(-1 < eye < 1)
            self.assertTrue(-1 < nose < 1)
            self.assertGreater(eye, nose)
        self.assertIn("center = (minimum + maximum) * 0.5 + u * halfHeight * verticalFocus", SOURCE)
        self.assertIn("let focusedFrames: [(focus: Float, zoom: Float)]", SOURCE)

    def test_fallback_does_not_bypass_anatomical_confirmation(self):
        self.assertIn("allowLegacyWithoutFace: true", SOURCE)
        self.assertIn("VNDetectFaceLandmarksRequestRevision2]", SOURCE)
        self.assertNotIn("VNDetectFaceLandmarksRequestRevision1", SOURCE)
        self.assertIn("first.landmarks.hasObservedNose && second.landmarks.hasObservedNose", SOURCE)
        self.assertIn("first.landmarks.agrees(with: second.landmarks, tolerance: 0.008)", SOURCE)
        self.assertIn("HeadLandmarkConsensus.average([first.landmarks, second.landmarks])", SOURCE)

    def test_auxiliary_contours_are_diagnostic_and_projected_on_skin(self):
        for vision_region in ("leftEyebrow", "rightEyebrow", "medianLine", "faceContour"):
            self.assertIn(f"points(features.{vision_region})", SOURCE)
        self.assertIn("contourCandidates.append(HeadImageAuxiliaryContourCandidate(", SOURCE)
        self.assertIn("contour.compactMap { rendered.point(at: $0) }", SOURCE)
        self.assertIn("auxiliaryContours: selectedAuxiliary", SOURCE)
        self.assertIn("faceOffLandmarkOverlayView.auxiliaryContours", VIEW)
        self.assertIn("renderer?.faceOffProjection(of: $0, in: bounds)", VIEW)
        self.assertIn("volumeView.faceOffAuxiliaryContours = sender.state == .on", CONTROLLER)
        self.assertIn("Vision on skin: eyes", CONTROLLER)

    def test_raw_vision_contours_are_separate_from_selected_landmarks(self):
        for region in ("visionLeftEye", "visionRightEye", "visionNoseCrest", "visionNoseOutline", "rawCanthi"):
            self.assertIn(region, SOURCE)
            self.assertIn(region, VIEW)
        self.assertIn("auxiliaryContours[.rawCanthi] = [leftCorners.minX", SOURCE)
        self.assertIn("contour.compactMap { rendered.point(at: $0) }", SOURCE)
        self.assertIn("Green/teal: Vision; white: raw corners", CONTROLLER)

    def test_surface_proposals_are_separate_diagnostics_not_registration_inputs(self):
        self.assertIn("func eyeSeamProposal(contours:", SOURCE)
        self.assertIn("let score = max(min(above - center, below - center), recess * 4000)", SOURCE)
        self.assertIn("simd_distance(point, upperPoint) < 0.015", SOURCE)
        self.assertIn("guard support >= 5 else { continue }", SOURCE)
        self.assertIn("func noseApexProposal(mapped:", SOURCE)
        self.assertIn("let offAxis = abs(simd_dot(relative, lateral))", SOURCE)
        self.assertIn("bestSurfaceSeam = seam", SOURCE)
        self.assertIn("bestSurfaceApex = apex", SOURCE)
        self.assertIn("selectedAuxiliary[.surfaceEyeSeam] = bestSurfaceSeam", SOURCE)
        self.assertIn("selectedAuxiliary[.surfaceNoseApex] = [bestSurfaceApex]", SOURCE)
        self.assertIn("let auxiliary = rawAuxiliary", SOURCE)
        self.assertIn("Magenta proposals only (not registration)", CONTROLLER)
        self.assertIn("frontal attempts ", CONTROLLER)
        self.assertIn("surfacePreviewFrontal: surfacePreviewFrontal", SOURCE)
        self.assertIn("case .surfaceEyeSeam, .surfaceNoseApex: color = .magenta", VIEW)
        selection = SOURCE[SOURCE.index("func assess("):SOURCE.index("for candidate in candidates")]
        self.assertNotIn("surfaceEyeSeam", selection)
        self.assertNotIn("surfaceNoseApex", selection)

    def test_proposal_search_accepts_rolled_frontal_views_and_status_is_not_clipped(self):
        preview = SOURCE[SOURCE.index("func recordSurfaceProposals("):SOURCE.index("for candidate in contourCandidates")]
        self.assertIn("frontAlignment >= 0.75", preview)
        self.assertNotIn("simd_dot(view.up, patientSuperior) >=", preview)
        self.assertIn("let down = browToEye / gap", SOURCE)
        self.assertIn("for y in stride(from: 2, to: size - 2, by: 2)", SOURCE)
        self.assertIn("faceOffStatusLabel.maximumNumberOfLines = 0", CONTROLLER)
        self.assertIn("rootView.safeAreaLayoutGuide.topAnchor", CONTROLLER)
        self.assertIn("faceOffStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)", CONTROLLER)

    def test_nose_midline_discrepancy_is_reported_without_moving_landmarks(self):
        self.assertIn("private func faceOffNoseMidlineOffsets(", SOURCE)
        self.assertIn("let lateralAxis = simd_cross(patientSuperior, patientAnterior)", SOURCE)
        self.assertIn("let browCenter = (left + right).reduce(SIMD3<Float>.zero, +)", SOURCE)
        self.assertIn("points[.noseTip].map { simd_dot($0 - browCenter, lateral) * 1000 }", SOURCE)
        self.assertIn("points[.noseBridge].map { simd_dot($0 - browCenter, lateral) * 1000 }", SOURCE)
        self.assertIn("noseTipToApexMM = simd_distance(tip, bestSurfaceApex) * 1000", SOURCE)
        self.assertIn("3D brow-midline offset: tip", CONTROLLER)
        self.assertIn("Tip to magenta apex:", CONTROLLER)
        self.assertIn("(preview only)", CONTROLLER)
        self.assertIn("abs(value) > 5 ?", CONTROLLER)
        selection = SOURCE[SOURCE.index("func assess("):SOURCE.index("for candidate in candidates")]
        self.assertNotIn("faceOffNoseMidlineOffsets", selection)
        self.assertNotIn("noseTipToApexMM", selection)

    def test_ct_globe_diagnostic_uses_volume_and_stays_out_of_registration(self):
        self.assertIn("enum HeadCTEyeballFinder", SOURCE)
        self.assertIn("struct HeadCTEyeVolume: Sendable", SOURCE)
        self.assertIn("private struct VoxelMask", SOURCE)
        self.assertIn("guard mask.take(seed) else { continue }", SOURCE)
        self.assertNotIn("voxelCount <= 100_000_000", SOURCE)
        self.assertIn("CT voxel data mismatch:", SOURCE)
        self.assertIn("CT volume exceeds diagnostic scan budget:", SOURCE)
        self.assertIn("let windows: [ClosedRange<Float>] = usableHints ? [0...10, 8...22, 16...30] : [0...10]", SOURCE)
        self.assertIn("guard value.isFinite, window.contains(value) else { continue }", SOURCE)
        self.assertIn("if let pair = bestPair(in: scan.candidates)", SOURCE)
        self.assertIn("guard nearHint(point, radiusMM: 40) else { continue }", SOURCE)
        self.assertIn("let pairOffset = axes - (window.lowerBound > 0 ? hintAxes : headCenter)", SOURCE)
        self.assertIn("surfaceEyeHints: hints", CONTROLLER)
        self.assertIn("scan.substantialBlobs", SOURCE)
        self.assertIn("scan.shapedBlobs", SOURCE)
        self.assertIn("ctEyeDiagnostic.detail", CONTROLLER)
        self.assertIn("(6...18).contains(radius)", SOURCE)
        self.assertIn("(35...90).contains(separation)", SOURCE)
        self.assertIn("(8...22).contains(value)", SOURCE)
        self.assertIn("if isCT, let preferred, let volume = volumeView.segmentationInput()", CONTROLLER)
        self.assertIn("HeadCTEyeballFinder.detect(guidedInput)", CONTROLLER)
        self.assertIn("faceOffCTGlobeCenters", VIEW)
        self.assertIn("CT globe centers (lime, internal)", CONTROLLER)
        self.assertIn("let visionHeight = simd_dot(delta, preferred.up) * 1000", CONTROLLER)
        self.assertIn("let seam = auxiliary[.surfaceEyeSeam] ?? []", CONTROLLER)
        self.assertIn("negative = below", CONTROLLER)
        self.assertIn("Diagnostic only; not canthi", CONTROLLER)
        selection = SOURCE[SOURCE.index("func assess("):SOURCE.index("for candidate in candidates")]
        self.assertNotIn("HeadCTEyeballFinder", selection)
        self.assertNotIn("ctGlobe", selection)
        self.assertIn("volumeView.faceOffCTGlobeCenters = []", CONTROLLER)

    def test_grossly_low_eye_positions_are_rejected_in_patient_space(self):
        self.assertIn("private func faceOffBrowToEyeGap(", SOURCE)
        self.assertIn("contour.count >= 3", SOURCE)
        self.assertIn("browGap > 0.028", SOURCE)
        self.assertIn("rejectedLowEyes += 1", SOURCE)
        self.assertIn("browToEyeGapMM: selectedGap", SOURCE)
        self.assertIn("low-eye rejects", CONTROLLER)

    def test_report_argument_order_matches_its_stored_properties(self):
        initializer = SOURCE.split("HeadSurfaceLandmarkSearchReport(\n", 1)[1]
        self.assertLess(initializer.index("provisionalUsesImagePoseFallback:"),
                        initializer.index("auxiliaryContours:"))
        self.assertLess(initializer.index("auxiliaryContours:"), initializer.index("viewsRendered:"))

    def test_alternate_lighting_only_follows_standard_and_focused_views(self):
        standard = SOURCE.index("for orientation in orientations {")
        focused = SOURCE.index("for (focus, zoom) in focusedFrames {")
        relighting = SOURCE.index("for lightSide: Float in [-0.9, 0.9] {")
        self.assertLess(standard, focused)
        self.assertLess(focused, relighting)
        self.assertIn("right * lightSide", SOURCE)
        self.assertIn("lightSide: lightSide", SOURCE[relighting:])
        self.assertIn("Eyes paired ", CONTROLLER)

    def test_eye_rejection_reports_confidence_separately_from_pose(self):
        self.assertIn("let poseUsable = confidenceAccepted && poseAccepted", SOURCE)
        self.assertIn("if confidenceAccepted { confidentEyeContourCount += 1 }", SOURCE)
        self.assertIn("if poseAccepted { acceptablePoseEyeContourCount += 1 }", SOURCE)
        self.assertIn("confidence pass ", CONTROLLER)
        self.assertIn("pose pass ", CONTROLLER)

    def test_image_aligned_pose_fallback_cannot_confirm_landmarks(self):
        self.assertIn("confidenceAccepted && !poseAccepted && innerGap > 0.02", SOURCE)
        self.assertIn("let usedImagePoseFallback = fallbackSpacing &&", SOURCE)
        self.assertIn("abs(rightCenter.y - leftCenter.y) < eyeSeparation * 0.25", SOURCE)
        self.assertIn("guard poseUsable || usedImagePoseFallback else { return nil }", SOURCE)
        self.assertIn("if first.usedImagePoseFallback || second.usedImagePoseFallback", SOURCE)
        self.assertIn("provisionalUsesImagePoseFallback = true", SOURCE)

    def test_eye_contours_are_ordered_in_image_space_before_fallback(self):
        ordered = SOURCE.index("swap(&left, &right)")
        eye_gap = SOURCE.index("let innerGap = rightCorners.minX.x - leftCorners.maxX.x")
        self.assertLess(ordered, eye_gap)
        self.assertIn("reorderedEyeContourCount += 1", SOURCE)
        self.assertIn("if fallbackSpacing { fallbackSpacingCount += 1 }", SOURCE)
        self.assertIn("if usedImagePoseFallback { fallbackLevelCount += 1 }", SOURCE)
        self.assertIn("Image-left reorder ", CONTROLLER)

    def test_canthi_use_local_contour_ends_and_brow_correction(self):
        self.assertIn("let localY = (end[(end.count - 1) / 2] + end[end.count / 2]) * 0.5", SOURCE)
        self.assertNotIn("localY * 0.2 + middleY * 0.8", SOURCE)
        self.assertIn("if browYs.count >= 6", SOURCE)
        self.assertIn("browGap - eyeSeparation * 0.22", SOURCE)
        self.assertIn("eyeSeparation * 0.09", SOURCE)
        self.assertNotIn("originalEyes(", SOURCE)
        self.assertIn("let invertedNose = face.usedImagePoseFallback", SOURCE)
        self.assertIn("simd_dot(values[.noseBridge]! - values[.noseTip]!, patientSuperior ?? view.up) < -0.008", SOURCE)
        self.assertIn("candidates.append((refined, \"midline nose, brow-constrained eyes\", true))", SOURCE)
        self.assertIn("if invertedNose { candidates.append((values, \"unrefined Vision nose\", false)) }", SOURCE)

    def test_fallback_nose_search_stays_below_eyes_and_near_midline(self):
        self.assertIn("eyeY + eyeSeparation * 0.38", SOURCE)
        self.assertIn("eyeY + eyeSeparation * 0.80", SOURCE)
        self.assertIn("x: eyeMidline - radius", SOURCE)
        self.assertIn("fallbackNoseBridge = CGPoint(x: eyeMidline, y: closest.y)", SOURCE)
        self.assertIn("points.removeValue(forKey: .noseBridge)", SOURCE)
        self.assertIn("provisionalMethod = candidate.method", SOURCE)

    def test_pose_fallback_allows_roll_but_requires_patient_frontal_view(self):
        self.assertIn("if face.usedImagePoseFallback {", SOURCE)
        self.assertIn("guard patientSuperior != nil, preferredUnit != nil,", SOURCE)
        self.assertIn("frontAlignment >= 0.75", SOURCE)
        self.assertNotIn("simd_dot(view.up, patientSuperior) >= 0.75", SOURCE)
        self.assertIn("let patientImageRight = simd_normalize(simd_cross(patientSuperior, preferredUnit))", SOURCE)
        self.assertIn("abs(simd_dot(secondCenter - firstCenter, patientSuperior)) < 0.015", SOURCE)
        self.assertIn("rejectedFallbackViews += 1", SOURCE)

    def test_nose_must_be_inferior_to_eyes_before_candidate_is_saved(self):
        self.assertIn("guard region.width > 0, region.height > 0 else { return nil }", SOURCE)
        self.assertIn("let tipHeight = simd_dot(tip - eyeMidpoint, patientSuperior)", SOURCE)
        self.assertIn("(-0.090 ... -0.020).contains(tipHeight)", SOURCE)
        self.assertIn("simd_dot(bridge - tip, patientSuperior) < 0.008", SOURCE)
        anatomical = SOURCE.index("!result.hasAnatomicalNosePosition(patientSuperior: patientSuperior)")
        provisional = SOURCE.index("if score > provisionalScore", anatomical)
        self.assertLess(anatomical, provisional)
        self.assertIn("rejectedNosePositions += 1", SOURCE)

    def test_geometric_nose_fallback_is_patient_aligned_and_unconfirmed(self):
        self.assertIn("for yy in (y - 5)...(y + 5)", SOURCE)
        self.assertIn("func anatomicalNoseTip(eyes:", SOURCE)
        self.assertIn("let drop = -simd_dot(relative, patientSuperior)", SOURCE)
        self.assertIn("(minimumDrop...maximumDrop).contains(drop)", SOURCE)
        self.assertIn("offAxis <= 0.012", SOURCE)
        self.assertIn("support >= 5", SOURCE)
        self.assertIn('let geometricNoseMethod = "patient-axis 3D nose (unconfirmed)"', SOURCE)
        self.assertIn("candidate.method != geometricNoseMethod", SOURCE)
        self.assertIn("if let patientSuperior, preferredUnit != nil, frontAlignment >= 0.75", SOURCE)

    def test_diagnostic_contours_exclude_nonfrontal_views(self):
        self.assertIn("if preferredUnit != nil && frontAlignment < 0.75", SOURCE)
        self.assertIn("nonfrontal rejects \\(report.rejectedFallbackViews)", CONTROLLER)
        self.assertIn("Fallback alignment \\(report.bestFallbackViewAlignment", CONTROLLER)
        self.assertIn("nose rejects \\(report.rejectedNosePositions)", CONTROLLER)


if __name__ == "__main__":
    unittest.main()
