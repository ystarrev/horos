# Frame Viewer

Native Swift electrode planning using the existing Metal Planar image pipeline.

## Implemented

- Database Frame toolbar item and Open in Frame context menu.
- Linked MPR slices and scene; shared navigation, annotations and rendering.
- Complete 33-entry Tactics electrode catalogue, retained without edits.
- Multiple electrodes, contact/insulation surfaces, slice intersections and targets.
- Numeric target, image-angle and depth editing; slice-click target placement.
- Visibility, duplicate/delete, undo/redo and JSON save/open with image identity checks.
- Model selection before creating an electrode; Place Target can create the first electrode.
- Automatic DICOM SR persistence after completed edits, including undo/redo and deletion.
  Reopening the source series restores its plan. One unverified local Frame Plan SR is
  updated in place; this is a working plan, not a signed or calibrated clinical report.
  Writes run off the UI thread, are read back before replacement, and reject conflicting
  external changes. Failed saves remain marked unsaved. JSON remains an optional export.
- Read Frame: Swift bright-component extraction and side-localizer rod fitting adapted
  from AIRS, with sample coverage, N-pattern geometry, parallelism and residual checks.
  First pass supports axial acquisitions with both side plates, near the patient axes;
  it does not yet refine with anterior/posterior plates or register another MRI.
- Detected rods are displayed for review. Accept Frame enables Leksell target coordinates;
  editor fields and stored electrode positions remain in source image LPS millimetres.
- The fitted transform and review state are persisted with the plan. Clear and undo work
  for frame detection too. Fitting residuals measure rod consistency, not clinical accuracy.
- SR TEXT now carries a versioned base64 binary-property-list payload for lossless geometry,
  with backward reading of JSON SRs. Normal close waits for autosave, without a discard dialog.

## Brain Extraction

The Brain toggle runs the reusable Swift extractor in `Sources/ImageProcessing`
off the main thread, uses its mesh as a volume stencil, and ray-marches the MRI
inside it in the Metal scene. Clicking again hides the cached volume, or cancels an
extraction in progress. Closing the window cancels pending work. MRI pixels and
the Frame Plan SR are not changed; the derived volume is cached for this window.

The deformation equations and settings come from Tactics/AIRS:
BT 0.7, RMin/RMax 8/10 mm, D1/D2 7/3 mm, 1000 iterations and four subdivisions.
The implementation replaces VTK's constrained sphere smoothing with projected
sphere subdivision and uses a bounded histogram for rescaled float intensities.
These differences mean numerical identity with Tactics is not claimed.
Rendering uses Tactics' RGB and scalar-opacity transfer-function stops, with
shading off, linear interpolation and physical-step opacity correction. The
display range uses the clipped-volume 98th percentile with 10% upper expansion.
Unlike Tactics' approximately 1 mm resampling, the cropped stencil retains the
native MRI voxel grid. Rays stop at the finite opaque MPR planes and write scene
depth for electrode occlusion. The extraction boundary is not rendered as a shell.

Inputs must be a complete, regular, single-volume MR stack. Oblique orientation
and reversed slice ordering are supported; gaps, duplicate positions and shear
are rejected. Synthetic tests cover extraction against a bright outer shell,
patient-coordinate mapping, invalid stacks, blank input and cancellation.
Real-image comparison with Tactics and clinical validation remain necessary.
The AIRS license is included with the bundled resources.

## Coordinate Contract

The coordinate editor shows Leksell millimetres when a frame has been accepted,
and explicitly labelled image LPS millimetres otherwise. Editing Leksell values
uses the inverse fitted transform; the stored target remains in image LPS.
R/L, A/P and S/I buttons move 1 mm along the active coordinate system's anatomical
axes, accounting for Leksell's reversed Y/Z signs. Frame rods are unlit magenta
(0.9, 0, 0.8), one-pixel lines matching the Tactics actor's color/default width.

Targets are double-precision DICOM patient LPS millimetres. The electrode shaft
extends from the target in direction (-cos(a), -sin(a) cos(d), sin(a) sin(d)).
This preserves Tactics' negative-Z azimuth then negative-X declination rotation
order in LAI axes, followed by the Y/Z flip back to image LPS coordinates.
Both angles initially equal 90 degrees, so the shaft extends superiorly in LPS.
Earlier saved plans without an angle convention marker retain their physical
trajectories; their displayed declination is converted by 180 degrees.
These angles are NOT calibrated Leksell
settings. Each catalogue distance s is placed at target + direction * (depth+s),
matching Tactics' translated local negative-X geometry. Tactics uses a fixed
0.5 mm tube radius for every model; its catalogue does not supply diameters.

Plans embed the specification used and the source DICOM frame identities. Opening
a plan on another series is rejected. Registration must later be represented by
a separate, explicitly directed transform, not by rewriting the original targets.

## Remaining Milestones

1. Extract the shared registration engine; add secondary images and review controls.
2. Extend frame fitting to larger tilts, other acquisition planes and optional anterior/posterior plates.
3. Compose planning-image to frame-image to Leksell transforms and validate angles,
   handedness, depth and target locations against Tactics and independent fixtures.
4. Trajectory-aligned views, interactive shaft handles and brain/surface visualization.
5. Tactics plan import, registration/calibration persistence, screenshots and reports.
6. End-to-end known-frame and clinical workflow validation before clinical use.

Source checks: Scripts/test_frame_viewer.py. Synthetic Swift fixtures:
Scripts/tests/FramePlanTests.swift, LeksellFrameReaderTests.swift and FramePlanSRTests.swift.
Include FramePlan.swift and LeksellFrameReader.swift; the SR test also uses the existing
ModernDCMTKBridge library. These are not a substitute for anatomical or stereotactic validation.
