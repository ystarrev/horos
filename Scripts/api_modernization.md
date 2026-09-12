# API modernization

Scope: application-owned code, macOS 27 and Apple silicon. Keep upstream DCMTK
unmodified and retain the ability to read existing patient data.

## Current checkpoint

- Implemented: database outline and thumbnail file promises using
  `NSFilePromiseProvider`. No four-second main-thread wait. The dragged object
  IDs, database and export settings are captured before the drop. DICOM exports
  use the existing exporter, with staging, completion/error reporting and
  cancellation. Album and Sources drops aggregate every pasteboard item.
- Implemented: Option-drag exports JPEG images and PDF reports from database rows and thumbnails.
  Study/series rows and series thumbnails promise a folder of full-resolution
  JPEGs; individual image thumbnails capture the displayed frame before the drag.
  Ordinary drags remain DICOM. Export folders share the staging/cancellation path.
  Embedded PDFs are extracted intact; text SRs use the existing PDF renderer,
  outside the managed-object context. Internal ROI/annotation/window-state SRs
  remain excluded. Older single-record multi-frame series expand without
  duplicating frames in normally indexed series, and report pages export once
  as a complete PDF document rather than as JPEGs.
- Reviewed: unkeyed archive usage. Removed unused file-based helper methods.
  The remaining writers encode legacy ROI or Bonjour protocol data; retain them
  until an explicit format migration and peer negotiation are implemented.
- Verification: source-contract tests only. No application build or live
  JPEG/PDF drag-and-drop validation has been performed for this checkpoint. The user
  confirmed ordinary study-row and thumbnail dragging works.

## Manual checks before the network pass

1. Drag one study, one series, and several selected rows into Finder. Each
   dragged row promises its own folder containing the usual DICOM export tree.
   Selecting both a study and its child series must not duplicate that series.
2. Drag one and several thumbnails into Finder. They should produce one export
   folder containing exactly the selected images/series. Option-drag an image
   thumbnail to export its displayed frame as JPEG. Option-drag a series
   thumbnail or a study/series row to export a JPEG/PDF folder, with no dialog.
   Check multi-frame series, PDF/text-SR report thumbnails, and studies containing
   both images and reports. Reports should retain all pages and internal ROI SRs
   should not be exported as reports.
3. Drag multiple rows/thumbnails into an ordinary album and into a laptop Source.
   Confirm all selected objects arrive, including surgery SR records.
4. Start a large Finder export, change the browser selection, and cancel from
   Activity. It must not switch the exported objects or publish a partial export.
5. Check ordinary Export to DICOM Files with the usual compression/DICOMDIR
   settings. Check encrypted export if used; an encrypted drag without a password
   must fail rather than quietly write unencrypted patient files.

## Remaining work

### Bonjour discovery and publication

Replace `NSNetServiceBrowser` discovery with Network.framework. Review resolution,
TXT records, per-interface identities, removal/liveness handling, peer deduplication
and the DNS-SD subprocess workaround together. Publication for an existing DICOM
listener cannot simply bind a second `NWListener` to the same port; preserve the
actual listener and choose the appropriate advertisement API.

Validate desktop/laptop discovery, abrupt Xcode termination, relaunch, sleep/wake,
multiple interfaces, ordinary DICOM peers, and checked-in non-Bonjour peers.
Do not remove the existing workaround until the replacement has passed these tests.

### Remaining stream-based remote database transport

Move N2Connection/N2ConnectionListener off NSStream/CFSocket with their calling
contracts intact. Audit framing, partial reads/writes, EOF, backpressure, timeout,
cancellation, TLS, subclass callbacks and callback-thread ownership before editing.
The fast HorosDirectTransfer transport already uses Network.framework and is not
part of this legacy transport rewrite.

### Metal 4

The current Metal command API is supported, not deprecated. Adopt Metal 4
incrementally and measure CPU submission overhead first. Explicit resource
lifetime, residency and synchronization replace assumptions made by the original
encoders. Preserve image math, registration scoring and cancellation behavior.

Compare rendered output and registration results as well as timings on M1-class
hardware before expanding adoption. Do not claim a speedup from API replacement
alone.
