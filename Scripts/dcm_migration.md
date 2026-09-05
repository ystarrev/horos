# DCM Removal Checkpoints

Remove the legacy DCM parser and framework, not Horos image classes such as
DCMPix. Keep the Core Data schema and existing DICOM files unchanged.

## Current Checkpoint

- Dependency inventory completed: approximately 60 application/preference source
  and header files reference DCM types (including imports and inactive code).
- Moved DCMNetServiceDelegate into Horos/Sources and the Horos target. Its class
  name, method signatures, notification names, defaults, and implementation are
  preserved. DCM.h no longer exposes the application networking helper.
- Source/project regression checks: `python3 -B Scripts/test_dcm_extraction.py`.
- User confirmed that the networking/HorosCloud checkpoint compiles and launches.
  End-to-end networking has not been independently retested here.
- Replaced the standard identifiers in DCMAbstractSyntaxUID with DCMTK's UID
  definitions, retaining the Horos display categories, private identifiers and
  additional/hidden SOP-class preferences. Corrected the retired standalone
  curve UID (previously the modality LUT UID) and the malformed colour-print UID.
  Lazy display-list initialization is now thread-safe and hidden lists initialize
  correctly even when requested before the visible-image list.
- Replaced DCMTransferSyntax's hand-built mutable dictionary with DcmXfer for
  encoding facts and names. Factories retain their UIDs, unknown private UIDs
  retain the legacy fallback, and copying preserves explicit custom properties.
  DCMTK recognition of a syntax does not add legacy decoder/encoder support.
- These two implementation files now use Objective-C++ (.mm). Their Objective-C
  interfaces and target ownership remain compatible while parser callers are
  migrated. This is replacement of their internals, not framework removal.
- Checks: `python3 -B Scripts/test_dcm_syntax.py` compares the frozen identifier,
  display-policy and encoding baseline with source and project wiring. The
  standalone runtime harness in `Scripts/tests/DCMSyntaxTests.mm` should be run
  against `Scripts/tests/dcm_syntax_baseline.json` in fresh processes, both with
  and without `--display-overrides`, after a user-approved build. It uses only
  volatile preference overrides and does not modify a database.
- No build or runtime execution of this new checkpoint has been performed.
  The DCM framework is still required and must remain linked for now.

## Remaining Work

1. Establish the DICOM behavioural baseline. The existing fixtures and expected
   pixel hashes in `Horos/Unit Tests/Data/DICOMFiles.plist` are a starting point,
   not adequate coverage of all formats. Add synthetic/anonymized cases for
   enhanced multiframe geometry, dynamic timing, compression, colour, overlays,
   character sets, DA/TM/DT precision and ranges, SR/PDF, SEG, and legacy ROIs.
2. Replace the remaining shared tag/date utilities. Preserve saved tag-name
   aliases, annotation settings and query ranges. Audit DCMCalendarDate archives
   before changing its encoded representation. Retire compatibility syntax
   wrappers once their remaining DCMObject/metadata callers are migrated.
3. Extend ModernDCMTKBridge for bulk attributes, nested sequence traversal, and
   the remaining writers. Do not reopen a dataset for each requested attribute.
4. Migrate XMLController, metadata editing, anonymization UI, secondary capture,
   PDF encapsulation, key-image metadata, and transfer conversion. Verify writes
   on copies; preserve private data and unrelated attributes.
5. Compare DCMPix's modern loader against the DCM fallback and migrate remaining
   metadata/format handling before deleting that fallback. Include RTSTRUCT,
   PET, ultrasound and ophthalmic geometry; do not silently drop support.
6. Remove the framework target, scheme, source directory, obsolete subclasses,
   resources, build references and unused codec dependencies after all callers
   are migrated. Check plugin headers and aliases separately from DCM.framework.

## Gates

- After this checkpoint: rebuild only with explicit approval using the existing
  incremental build location. Verify MR/CT display, enhanced multiframe scans,
  reports, SEG/legacy ROIs, hidden/additional SOP-class preferences, DICOM export,
  and transfer of compressed/uncompressed files. Keep the earlier networking
  smoke tests (Sources, query/retrieve and direct transfers) in the baseline.
- During parser migration: compare pixel values, physical geometry, metadata,
  export round trips and throughput, not just whether a file opens. Use
  standards-based expectations when legacy and new behaviour disagree.
- Before final removal: inspect every retained plugin's dependencies and dynamic
  class use, verify the packaged app has no DCM load dependency, and confirm that
  no stale embedded framework is masking a missed reference. Do not remove other
  libraries merely because their names contain DCM.
