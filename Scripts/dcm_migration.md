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
- No build or end-to-end networking test has been performed for this checkpoint.
  The DCM framework is still required and must remain linked for now.

## Remaining Work

1. Establish the DICOM behavioural baseline. The existing fixtures and expected
   pixel hashes in `Horos/Unit Tests/Data/DICOMFiles.plist` are a starting point,
   not adequate coverage of all formats. Add synthetic/anonymized cases for
   enhanced multiframe geometry, dynamic timing, compression, colour, overlays,
   character sets, DA/TM/DT precision and ranges, SR/PDF, SEG, and legacy ROIs.
2. Replace shared tag/UID/transfer-syntax/date utilities. Preserve saved tag-name
   aliases, annotation settings, query ranges, and Horos SOP-class display policy.
   Audit DCMCalendarDate archives before changing its encoded representation.
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
  incremental build location. Verify Sources discovery, self-node filtering,
  quit/relaunch, configured query/send nodes, C-MOVE/C-GET, and direct transfers.
- During parser migration: compare pixel values, physical geometry, metadata,
  export round trips and throughput, not just whether a file opens. Use
  standards-based expectations when legacy and new behaviour disagree.
- Before final removal: inspect every retained plugin's dependencies and dynamic
  class use, verify the packaged app has no DCM load dependency, and confirm that
  no stale embedded framework is masking a missed reference. Do not remove other
  libraries merely because their names contain DCM.
