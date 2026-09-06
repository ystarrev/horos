# DCM Removal Checkpoints

Remove the legacy DCM parser and framework, not Horos image classes such as
DCMPix. Keep the Core Data schema and existing DICOM files unchanged.

## Completed Checkpoints

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
- User confirmed that the UID/transfer-syntax checkpoint works after building
  and testing, including transfers to the laptop.

## Tag Dictionary Checkpoint

- DCMTagDictionary now uses a private, process-lifetime DCMTK DcmDataDictionary
  loaded once from the packaged dicom.dic. It does not alter DCMTK's global
  dictionary, open image files, or load dictionaries separately for each tag.
  Initialization is thread-safe; subsequent lookups use immutable caches.
- Removed the two full legacy runtime plist dictionaries and their project
  references, including stale references in the old DicomImporter project.
  Removed the commented-out plist generator in AppController.
- A compact DCMTagDictionaryCompatibility.json preserves the differing names,
  VRs, and VMs for 694 legacy entries. All 3,672 valid legacy numeric tags retain
  their metadata. This deliberately preserves reader-specific VR conventions
  until the parser is replaced, rather than changing parsing in this step.
  Obsolete dictionary "Version" annotations, unused by callers, are not retained.
- Name lookup accepts both modern DCMTK keywords and the legacy names saved in
  annotation, anonymization, and predicate settings. Two ambiguous old names
  retain their original mappings. Three malformed legacy mappings are handled
  explicitly: CurveDescription14 now uses 5014,0022; IllegalPrivateCreator has
  a valid representative tag; the nonnumeric GenericGroupLengthToEnd is omitted.
- Numeric tag lookup resolves repeating groups using DCMTK without expanding
  huge ranges into the tag menus. Unknown vendor-specific tags are not assigned
  a guessed private creator. The existing PhilipsFactor exception is retained.
- DCMAttributeTag validates numeric ranges and strings, accepts optional
  parentheses/0x prefixes, and canonicalizes lowercase hex. Copying preserves
  an explicit VR; packed values avoid signed shifts; equality and hash agree.
  The public class names and instance layout remain compatible.
- Packaged dicom.dic and the compatibility JSON belong to DCM.framework. Horos
  still bundles its existing dicom.dic for its other DCMTK consumers.
- Checks: `python3 -B Scripts/test_dcm_tags.py` verifies the full metadata/name
  baseline and project/resource wiring. The UID/syntax and extraction checks
  also pass. Syntax-only compiler checks passed for the changed helpers and
  `Scripts/tests/DCMTagTests.mm`; no app or dependency build was run.
- The runtime harness must be linked against a newly built DCM.framework and
  run with `Scripts/tests/dcm_tags_baseline.tsv` after a user-approved build.
  It covers concurrent initialization, resources, aliases, repeating groups,
  invalid input, private-tag fallback, copying, and dictionary-key behavior.
  The TSV is test data only, not a second runtime dictionary.
- User confirmed that the tag-dictionary checkpoint builds and works in Horos.

## DICOM Dates Checkpoint

- DCMCalendarDate now delegates DA/TM/DT parsing and DICOM output to DCMTK.
  It remains an NSDate subclass with the same class name, instance variables,
  archive keys and unchanged coding methods. No Core Data model changes or
  database/data-file migration is involved. Generic calendar-format methods
  remain available for existing callers; no new public C++ interface is exposed.
- Preserved legacy dotted DA, abbreviated year/month DA, colon-separated TM,
  and unmodified DA/TM query ranges. Output still uses full DA and six fractional
  digits for TM/DT; this step does not add source-precision preservation.
- Midnight is no longer rejected by a numeric-nonzero test. Fractional seconds
  survive NSDate conversion and combining DA/TM; pre-2001 dates use signed-safe
  arithmetic. Integral HHMMSS remains the database comparison representation.
- Explicit DT offsets are applied when constructing the instant, including
  negative sub-hour offsets and partial DT values. Dates with no explicit offset
  use Foundation's local timezone rules for that date, not today's DST offset.
  Foundation still formats the optional offset to avoid OFTime's fractional-hour
  truncation for some minute offsets.
- Calendar round-trip validation rejects impossible days and nonexistent local
  DST times instead of normalizing them. Leap-second labels are rejected because
  NSDate cannot represent them; lossless leap-second support remains a future
  value-representation concern, not an invented adjacent timestamp.
- DCMDataContainer's single/multiple date readers now use these same helpers.
  Removed its duplicate formatter parser and the guard that dropped a multi-value
  TM when its first value was midnight. Byte consumption remains unchanged.
- Source checks: `python3 -B Scripts/test_dcm_dates.py`, plus the earlier DCM
  checks. The date implementation, data container and runtime harness pass
  syntax-only compiler checks; no app/dependency build was run.
- `Scripts/tests/DCMDateTests.mm` uses the synthetic dcm_dates_baseline.json
  fixture to test midnight, fractions, early dates, offsets, DST, range pass-through,
  copying, concurrency and in-memory data-container reads after an approved build.
  This runtime harness has not been executed here. Archive payload round-trip
  testing is still needed before changing the retained compatibility class or
  its encoding; this checkpoint changes neither.
- DCM.framework remains required. Test query date/time ranges, acquired-date
  display, SR/SEG and export timestamps before advancing to parser migration.
- User rebuilt and compared database screenshots: visible stored dates/times
  were unchanged. The February 1 to March 1, 2026 query sent 20260201-20260301;
  21 series / 1,156 instances were retrieved and parsed without logged failures.
  This does not replace timestamp round-trip or archive fixture tests.

## Deferred Follow-Ups

- [ ] Investigate the six unreadable legacy ROI archives. The identical
  NSUnarchiver "inconsistency between written and read data" errors appear in
  August 22/23 logs, before the current DCM migration. Preserve originals and
  investigate decoding compatibility on copies, including ROI display/counting.
  Paths relative to the T7 database's DATABASE.noindex directory:
  5760000/5750477.dcm, 5780000/5778823.dcm, 5790000/5783636.dcm,
  5860000/5850889.dcm, 5860000/5852632.dcm, 5860000/5850887.dcm.

## Meta-Data Reader Checkpoint

- XMLController no longer constructs DCMObject or DCMAttribute instances. The
  modern bridge loads the file once and uses DCMTK's XML writer for the metadata
  tree, including file meta information, private tags and nested sequence items.
  The new HorosDICOMMetadata adapter preserves the outline's DICOMObject /
  attribute / item / value structure, zero-based item paths and search columns.
  Tag labels come from DCMTK; the add-field dictionary still accepts old aliases.
- The read-only bridge loads deferred text/numeric metadata, not deferred binary
  payloads, and does not decode pixels. Binary data is identified but not dumped
  into the window or XML/text exports. Compressed pixel fragments are not exposed
  as editable sequence items. Nesting depth is bounded and read errors are shown
  explicitly, rather than silently falling back to the old parser.
- Character conversion to UTF-8 happens only in the temporary display dataset.
  Original Specific Character Set declarations, including nested declarations,
  are retained in the displayed metadata. DA/TM/DT values remain raw DICOM text;
  they are not interpreted or normalized by the date wrappers in this path.
- NIfTI metadata keeps its existing reader. XML and text exports use the same
  in-memory display tree; text export includes nested tag paths. These are display
  exports, not lossless DICOM interchange files or replacements for source data.
- Adding a field updates a copy of the display tree until Apply is selected.
  The existing top-level DCMTK save mechanism is unchanged. Hidden/unloaded binary
  values and sequences (including their children) are read-only: the existing
  writer does not support sequence paths. Do not mistake a placeholder for data
  that can be written back. Full metadata editing is a separate migration step.
- Consolidated the two outline reload paths and guarded restoration of a missing
  selection. No window layout, database schema, patient file or preference changes
  were made during implementation.
- Checks: all 52 DCM source/project checks pass, including the new
  Scripts/test_dcm_metadata.py and synthetic XML fixture. Syntax-only checks pass
  for the bridge, adapter, XMLController, its DCMTK category and runtime harness;
  the project plist and whitespace checks pass. No build was run.
- Scripts/tests/DCMMetadataTests.mm is a standalone, not-yet-executed runtime
  harness. After an approved build, it takes dcm_metadata_baseline.xml and the
  newly built bridge path. It checks outline semantics and creates only temporary
  synthetic DICOM files to test explicit/implicit little endian, explicit big
  endian, Unicode/nested charset conversion, long text, raw dates, hidden pixels
  and unchanged source bytes. It does not open a patient database.
- User gate: rebuild, open File > Meta-Data on a CT/MR and an SR/SEG or enhanced
  multiframe image, expand sequences, search tags, switch images, and export XML
  and text. Check names, raw dates/times and nested values. Test field additions
  and ordinary top-level edits only on exported disposable copies. Pixel loading,
  anonymization, remaining DCMObject callers and framework removal remain ahead.

### Metadata Edit Date Added Follow-Up

- Metadata edits now use an explicit reimport path that leaves existing study
  and series Date Added values unchanged, before saving and posting updates.
  Ordinary imports, including imports that reread or replace existing files,
  retain their previous date behavior.
- The editor snapshots original study/series dates by file path on the context
  queue. Newly created groups inherit those dates if an edit changes identifiers;
  the snapshot survives the second reimport used for regrouping. Missing original
  dates remain missing. Existing destination groups retain their own dates.
- Regression checks cover the opt-in, snapshot reuse, and all importer date
  assignments. Runtime check after rebuilding: edit a description on a disposable
  copy, check study and series Date Added, then close/reopen Horos and check again.
  Also test an identifier edit that creates a new series/study and a normal import.
  Previously overwritten dates cannot be recovered by this change.

## Checkpoint: Anonymization Tag Menu and PDF Readers

- Moved the shared metadata-reader entry point into DicomFile's DCMTK category;
  XMLController delegates to it. Anonymization's File(s) tags menu now reads the
  same DCMTK metadata tree, with one load and no legacy DCMObject/DCMAttribute.
  Only top-level tags are listed. Numeric tag identities, legacy display aliases,
  actual file VRs, custom tags and saved presets are preserved. Short scalar
  previews exclude sequences, binary placeholders and long values.
- Replaced BrowserController's three remaining embedded-PDF reads: opening in
  Preview, the preview action, and PDF image extraction for QuickTime/HTML export.
  A PDF-specific bridge entry point loads once, checks the storage class and PDF
  header, checks a nonempty MIME type, and bounds-checks EncapsulatedDocumentLength
  before removing a declared padding byte. Older files without that length keep
  their original payload. Optional titles are converted to UTF-8 separately;
  an invalid title charset does not prevent extracting the PDF itself.
- Interactive PDF exports share one helper that writes atomically into a unique
  temporary directory. Document titles are treated as leaf filenames, never paths;
  repeated titles cannot overwrite earlier exports. Read/write failures are
  reported instead of creating empty PDFs or claiming an absent file was opened.
- The generic EncapsulatedDocument reader used by legacy ROI archives is unchanged.
  Anonymization writes remain on their existing GDCM path; metadata writes,
  report/PDF creation, SR rendering, pixel loading, database schema and patient
  source files are unchanged. No new target, framework or resource is required.
- Checks: all 60 DCM source/project checks pass. Syntax-only checks cover the
  bridge, changed readers/controllers and expanded metadata harness. The harness
  adds tag-menu previews and synthetic PDF payloads, including padded lengths,
  legacy missing lengths, Latin-1 titles, malformed lengths, MIME/SOP mismatches,
  missing payloads, source-byte preservation and unchanged generic SR extraction.
  The compiled harness has not been run. No build or patient-data operation ran.
- User gate: rebuild, open the anonymization tag picker on an existing DICOM,
  inspect File(s) tags and a saved preset, and export only to disposable copies.
  Open an existing encapsulated DICOM PDF in Preview; check its title and contents.
  Check PDF inclusion in HTML/QuickTime export if that workflow is used. Ordinary
  MR/CT, SR/SEG and legacy ROI viewing should remain unchanged. DCM.framework is
  still needed for the remaining parser and writer consumers.

## Current Checkpoint: Remove Report Authoring

- Removed Report > Convert to PDF and Report > Convert to DICOM PDF, including
  their action declarations, menu/toolbar validation and database import actions.
  These commands required a separately attached report document (reportURL);
  they did not operate on an SR report retrieved from PACS.
- Removed automatic DICOM PDF creation on report validation and its checkbox in
  both the Swift settings and legacy preference pane. Existing saved preferences
  are not edited; the old key is simply no longer used. Saving status/comments
  and archiving annotations as SR are unchanged.
- Deleted the new PDF packaging bridge and adapter from the preceding checkpoint
  rather than retaining unused code. Removed all PDF-to-DICOM methods from the
  report category, plus the unused legacy DCMEncapsulatedPDF files, umbrella
  import and Xcode build/header references. Removed packaging-only tests.
- Removed the entire File > Report menu, Open/Delete actions and Report toolbar
  item, including saved-toolbar cleanup, selection observers and the file-change
  watcher. Removed the Word/Pages/TextEdit/LibreOffice editor preference.
- Removed attached-document import/discovery, automatic archive-as-SR writers,
  rebuild-time report consistency scans, file/URL report SR constructors and
  their now-unused content-date override. Other SR writers keep their current
  date/time behavior, with one timestamp shared by date and time fields.
- Removed the Copy Reports to CD conversion option and DicomStudy+Report category,
  the bundled OsiriX report template, unused RTF icon and associated project and
  unpack-script references. Ordinary DICOM file export, including SR/PDF, remains.
- Preserved PACS SR rendering through StructuredReportSupport, embedded PDF
  extraction/opening/export and normal Print. Surgical procedure SRs, ROI and
  annotation archives, key objects and viewer state are not report authoring and
  remain supported. Existing legacy report archives can still be read.
- No active dictation engine was found. Retained legacy reportURL/dictateURL
  database fields and study-status/hotkey values to preserve database and saved
  preference compatibility. No database files or stored reports are deleted.
- Fixed database Print routing after a user test showed AppKit printing the
  database table ("Documents DB"). MyOutlineView and BrowserMatrix now intercept
  Print for selected SR/PDF records, render existing SR content through the shared
  reader, and print all pages with PDFKit and a report-specific job title. Multiple
  selected reports form one print job; read failures do not print a partial set
  or fall through to the table. Image printing was subsequently added in the
  Database Image Printing Follow-Up below.
  Printing does not import files or alter database records; temporary SR PDFs are
  removed when the print operation finishes or is cancelled.
- Source checks cover removal of menus/actions, preferences, authoring entry
  points, templates and project references, valid remaining XIB connections,
  and retention of PACS viewing/printing, other SR uses and status saving.
  The existing PDF reader tests remain in place; no app build has been run.
- User gate: rebuild, confirm File > Report and the Report toolbar item are gone,
  then retrieve/open/print an existing PACS SR report and an embedded PDF as usual.
  Also check the Burn dialog layout and a surgical procedure / ROI. The earlier
  instruction to test report conversion on a PACS SR was not applicable.

### SR Print Pagination Follow-Up

- Xcode stopped in AppKit pagination validation because WKPrintingView had not
  initialized its frame when its page-range callback returned. The report had
  already been read successfully as HTML; the failure was in PDF preparation.
- The hidden SR-to-PDF operation now uses AppKit's document-modal API with
  separate-thread printing enabled. The synchronous adapter services the main
  run loop until completion so WebKit can calculate and render all pages. The
  completion callback marshals its state back to the main thread, and the view
  and window remain alive until printing finishes. Merely enabling the thread
  flag while keeping runOperation would not spawn a printing thread.
- Internal PDF preparation clears inherited page-range/selection-only settings.
  The subsequent user-facing print dialog still controls the actual print job.
  This changes neither the DICOM report nor the database.
- Source checks cover the threading, completion/lifetime ordering and full-report
  settings. Rebuild and retry the SR report; verify the last page of a long
  report and cancellation. No app build or live print test was run here.

### Database Image Printing Follow-Up

- Database Print now handles image selections as well as SR/PDF reports. A
  selected series (including a series thumbnail) contributes its full sorted
  image list; individual image thumbnails contribute only their selected frames,
  in displayed order. Overlapping study/series/image selections are deduplicated.
  Single-object legacy multi-frame series expand only for whole-series selections;
  already indexed frames and individual image selections are not expanded again.
- Image pages use DCMPix's full-resolution display pixels, saved series window
  settings with DICOM/automatic fallback, and pixel-aspect correction. Each image
  occupies one PDF page in the standard print dialog. This is not a database-row
  capture or an enlarged thumbnail. Existing SR/PDF pages remain paginated.
- Multi-item preparation has progress and cancellation. Pixel decoding uses only
  snapshotted paths/settings, without passing database objects through the nested
  run loop, and releases each frame's raw buffers before preparing the next.
  A failed image/report stops the entire job; cancellation or an empty selection
  cannot fall back to printing the database table. No database writes are added.
- Source checks cover selection routing, order, multi-frame handling, full-size
  rendering and failure/cancellation. Rebuild and compare a small series' page
  count with its image count, then select two image thumbnails and expect two
  pages. Also recheck an SR report and cancel a larger preparation. No app build
  or live print test was run here.

### Printed Image Orientation And Annotations

- Disable PDFKit's automatic page rotation so images retain their native orientation.
- Use the same annotation drawing code as Metal Planar, including the configured
  modality-specific corner fields and None/Graphics/Basic/Full setting. Database
  annotation values, patient identity, acquisition date and series frame positions
  are snapshotted before preparation starts servicing the run loop. The decoder
  still receives no live database objects. There is no mouse-position annotation
  for a printed image, or viewer-specific study ordinal for a database print job.
- Each image page draws the full-resolution image with its pixel proportions and
  vector text in a stable PDF coordinate space. No screenshot or thumbnail is used.
- Recheck the axial CT orientation and configured acquisition-date placement in
  print preview; also check individual frames, a multiframe series, and Basic/None
  annotation modes. No app build or live print test was run here.

## Remaining Work

1. Establish the DICOM behavioural baseline. The existing fixtures and expected
   pixel hashes in `Horos/Unit Tests/Data/DICOMFiles.plist` are a starting point,
   not adequate coverage of all formats. Add synthetic/anonymized cases for
   enhanced multiframe geometry, dynamic timing, compression, colour, overlays,
   character sets, DA/TM/DT precision and ranges, SR/PDF, SEG, and legacy ROIs.
2. Retire the compatibility tag, syntax and date wrappers once their remaining
   DCMObject/metadata callers are migrated. Preserve saved tag-name aliases,
   annotation settings and query ranges. Verify historical DCMCalendarDate
   archive payloads before changing its class identity or encoded representation.
3. Extend ModernDCMTKBridge beyond the new bulk metadata display tree for typed
   attribute access and the remaining writers. Do not reopen a dataset per tag.
4. Complete remaining metadata editing, secondary capture, key-image metadata,
   and transfer conversion migration. The anonymization tag menu and report PDF
   readers are migrated; the unused report PDF creation commands/writers are
   removed. Verify writes on copies; preserve private data and unrelated attributes.
5. Compare DCMPix's modern loader against the DCM fallback and migrate remaining
   metadata/format handling before deleting that fallback. Include RTSTRUCT,
   PET, ultrasound and ophthalmic geometry; do not silently drop support.
6. Remove the framework target, scheme, source directory, obsolete subclasses,
   resources, build references and unused codec dependencies after all callers
   are migrated. Check plugin headers and aliases separately from DCM.framework.

## Gates

- After this checkpoint: rebuild only with explicit approval using the existing
  incremental build location. Check saved annotation layouts, the metadata tag
  browser, smart album predicates and anonymization presets (export to copies).
  Verify MR/CT display, enhanced multiframe scans,
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
