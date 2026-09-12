# API modernization

Scope: application-owned code, macOS 27 and Apple silicon. Keep upstream DCMTK
unmodified and retain the ability to read existing patient data.

## Completed drag/export checkpoint

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
- Verification: source-contract checks, plus the user's confirmation that the
  usual thumbnail, study-row and Option-drag export workflows work. The full
  edge-case checklist below remains useful for regression testing.

## Current checkpoint: discovery and slice failures

- Implemented: unreadable scrolling slices show a non-modal warning while the
  previous image and its annotations stay intact. Subsequent navigation advances
  from the failed request instead of repeatedly getting stuck on the same slice.
- Implemented: Sources (DICOM, shared databases and iPhone destinations) and
  Query/Retrieve use the same Swift `HorosBonjourBrowser`, backed by `NWBrowser`.
  Full result snapshots aggregate interfaces by service name/type/domain. TXT or
  interface changes refresh existing resolvers without removing/re-adding rows.
  Generation checks reject callbacks after cancellation; transient network waits
  keep the existing liveness policy. Delayed startup respects disabled discovery.
- Removed at the user's request: DNS-SD subprocess browse/resolve/publication
  fallbacks, output parsing, cached fallback TXT dictionaries, and orphan-helper
  process registry/cleanup. Temporary waits recover on the native browser;
  terminal failures report the original error and retry native discovery.
- Retained deliberately: `NSNetService` address/TXT resolution and publication,
  plus all transfer protocols, liveness checks and source reconciliation.
  This is a discovery checkpoint, not completion of Bonjour modernization.
- User validation before fallback removal: iPhonePlanner discovery and transfer
  work. Laptop validation remains pending; the user elected not to retain the
  fallbacks while waiting for that test.
- Verification: 342 non-build source/project checks pass; Swift browser
  type-checking passes with warnings treated as errors. No app build or live
  network validation was run by the agent.

### Next manual checks

1. Confirm the laptop appears once in Sources and remains available in
   Query/Retrieve; test a transfer in each direction and a query/retrieve.
2. Quit/relaunch and exercise Xcode stop/relaunch on either peer. Check that
   stale rows disappear and the returning peer becomes usable without rebooting.
3. Check sleep/wake and switching Wi-Fi/Ethernet, including both interfaces active.
4. Toggle DICOM Bonjour discovery off and back on; confirm no delayed restart
   happens while disabled. Check an ordinary DICOM peer and the iPhone destination.
5. If an unreadable slice is encountered, verify the warning, navigation past it,
   reversal back to the previous image, and clearing the warning on a good image.
   Do not damage or remove patient files just to induce this condition.

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

### Bonjour resolution and publication

Discovery has moved to Network.framework and the DNS-SD subprocess workaround
has been removed. Address remaining `NSNetService` resolution and publication,
including TXT records. Publication for an existing DICOM
listener cannot simply bind a second `NWListener` to the same port; preserve the
actual listener and choose the appropriate advertisement API.

Validate desktop/laptop discovery, abrupt Xcode termination, relaunch, sleep/wake,
multiple interfaces, ordinary DICOM peers, and checked-in non-Bonjour peers.

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
