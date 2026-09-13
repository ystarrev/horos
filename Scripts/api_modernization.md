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

## Completed discovery and slice-failure checkpoint

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
- Retained at that checkpoint: `NSNetService` address/TXT resolution and
  publication, plus all transfer protocols, liveness checks and source
  reconciliation. Publication is now handled by the checkpoint below.
- User validation before fallback removal: iPhonePlanner discovery and transfer
  work. Laptop validation remains pending; the user elected not to retain the
  fallbacks while waiting for that test.
- Fixed subsequently: iPhone legacy ROI export reads managed objects through
  the export context, using object IDs rather than background access to the
  main database context. Live viewer ROI snapshots stay on the main thread.
- Verification: 347 non-build source/project checks passed; Swift browser
  type-checking passes with warnings treated as errors. No app build or live
  network validation was run by the agent.

## Completed Bonjour publication checkpoint

- DICOM and database sharing now use Swift `HorosBonjourAdvertisement` with
  Apple's in-process `DNSServiceRegister`. This advertises the existing listener
  ports; it does not open another listener or restore the subprocess fallback.
- Preserved service types, names, UID, DICOM port, C-GET/compression capabilities,
  and direct-transfer version/port/token. Native TXT construction handles UTF-8
  values and byte limits; changed TXT records update the existing registration.
- Publication, callbacks, record updates and reference disposal are serialized
  on the main queue. Transient daemon failures release the dead registration and
  retry with bounded backoff; stop cancels retries and rejects stale callbacks.
  Invalid configuration/permission failures are logged without a retry loop.
- DICOM listener restart cancels the previous delayed publication; shutdown
  cancels it too. Query/Retrieve reads the current publisher identity instead of
  holding an unretained pointer to a stopped publisher. Auto-renamed service
  names remain available to the self-filter.
- Removed the unused database `netService` accessor and publication delegates.
  Address/TXT resolution still uses `NSNetService`; transfers are unchanged.
- Verification: 355 non-build checks pass, including native TXT wire-format
  checks without network traffic. Both Swift Bonjour helpers type-check with
  warnings treated as errors; the generated Objective-C interface and project
  syntax were checked. No app build or live publication/transfer test was run.
- API lifecycle reference: [DNSServiceSetDispatchQueue](https://developer.apple.com/documentation/dnssd/dnsservicesetdispatchqueue(_:_:)).
- User validation: rebuilt and reported that this checkpoint works.

## Completed Bonjour resolution checkpoint

- Replaced the remaining `NSNetService` resolver with Swift
  `HorosBonjourService`. Native `DNSServiceResolve` gets the SRV/TXT data and
  `DNSServiceGetAddrInfo` gets numeric addresses. Neither operation makes a
  connection to the advertised DICOM/database listener.
- The browser passes the currently discovered interface indexes to each service,
  refreshing them when observations change. Resolution includes peer-to-peer
  interfaces, aggregates available address batches, prefers IPv4, and preserves
  IPv6 link-local scope. A missing A/AAAA record does not discard the other family.
  An unavailable second interface does not hold up a successful resolution.
- Main-queue callbacks, reference identity checks, cancellable deadlines and
  generation checks prevent cancelled lookups from publishing stale results.
  Address, host, port and TXT are committed as one snapshot; failure leaves the
  previous snapshot intact for the existing liveness policy. Snapshot reads are
  locked because node lists can also be inspected by transfer workers.
- Sources and Query/Retrieve use the same resolved address. Removed duplicate
  socket-address parsing and unused legacy delegate methods. All TXT decoding
  now uses the native DNS-SD parser, retaining binary and empty values.
  No application `NSNetService` usage remains. Transfer protocols are unchanged.
- Verification: 364 non-build checks pass, including native TXT parsing and
  numeric IPv6 scope checks without network traffic. All three Swift Bonjour
  helpers type-check with warnings treated as errors. The resolver's generated
  Objective-C interface and project syntax were checked. No application build
  or live peer-resolution/transfer test was run by the agent.
- API reference: [DNSServiceResolve](https://developer.apple.com/documentation/dnssd/dnsserviceresolve(_:_:_:_:_:_:_:_:)).
- User validation: rebuilt and confirmed discovery/transfer still works with
  iPhonePlanner, including its disappearance and return on a new port. Laptop
  integration validation remains pending.

## Parked checkpoint: shared-database request client

Status: pause further network changes until the user has the laptop available
for shared-database testing. The implementation remains in the working tree;
source/type checks do not replace peer testing. Resume with the checklist below
before changing the inbound server.

- Shared-database requests in `RemoteDicomDatabase` now use Swift
  `HorosDatabaseTransport` and `NWConnection`, including the `GETDI` destination
  lookup. The six-byte commands, integer byte order, archives and EOF-delimited
  responses are unchanged. This is the existing plaintext database protocol;
  no TLS-enabled callers were redirected to plaintext.
- Bounded sends/receives replace the per-request stream thread and run loop.
  Native callbacks only publish locked connection state on a dedicated queue;
  response consumers run on the caller's thread with bounded buffering and
  per-chunk autorelease pools. Cancellation and the existing 45-second idle
  timeout now produce explicit failure, not a successful partial response.
- Removed the five-attempt automatic replay, which could repeat remote mutations
  or reuse partly written download state. Objective-C parser exceptions become
  errors before crossing Swift, then propagate to existing caller error handling.
- Image downloads validate response counts, split headers, file completion and
  the echoed destination paths. Missing files, malformed/truncated replies and
  write/move errors fail explicitly. Incomplete temporary files are removed;
  completed cached images are not deleted when another request downloads them.
  Index transfer failure also closes/removes its temporary file. The separately
  requested index size is only a progress estimate, not an exact-size invariant.
- The inbound `O2DatabaseConnection`/`N2ConnectionListener` server is unchanged
  in this checkpoint. Fast `HorosDirectTransfer` and DICOM/DCMTK transport are
  untouched. This change alone is not a measured throughput improvement.
- Verification: 374 non-build checks pass. The Swift helper type-checks with
  warnings treated as errors; its generated Objective-C interface, the request
  bridge, both response handlers and project syntax were checked. No app build
  or live shared-database request was run by the agent.

### Shared-database manual checks

1. Open a peer's shared database from Sources and view an uncached series. Check
   the index, image loading and refreshing after the peer's database changes.
2. Exercise a shared-album change and a normal upload to that shared database.
3. Cancel a large index/image download, then retry; interrupt the peer and retry
   after relaunch. Failed transfers should not leave empty/partial cached images.
4. Recheck an ordinary DICOM query/retrieve and fast Horos/iPhone transfers.
   These use separate transports; iPhone transfer alone does not validate the
   shared-database request client.

### Bonjour manual checks

1. Confirm the laptop appears once in Sources and remains available in
   Query/Retrieve; test a transfer in each direction and a query/retrieve.
2. Quit/relaunch and exercise Xcode stop/relaunch on either peer. Check that
   stale rows disappear and the returning peer becomes usable without rebooting.
3. Check sleep/wake and switching Wi-Fi/Ethernet, including both interfaces active.
4. Toggle DICOM Bonjour discovery off and back on; confirm no delayed restart
   happens while disabled. Check an ordinary DICOM peer and the iPhone destination.
5. Toggle database sharing and DICOM publication separately, rename the shared
   database, and restart the DICOM listener. Confirm the peer sees the current
   name/port once, disabled services stay absent, and fast transfers still work.
6. If an unreadable slice is encountered, verify the warning, navigation past it,
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

### Bonjour integration validation

Discovery uses Network.framework; publication, resolution and TXT handling use
native DNS-SD. The legacy service API and subprocess workaround are removed.
Validate this resolution checkpoint against desktop/laptop discovery, abrupt
Xcode termination, relaunch, sleep/wake, multiple interfaces, ordinary DICOM peers,
the iPhone destination, and checked-in non-Bonjour peers.

### Remaining stream-based remote database transport

The request client is migrated in the current checkpoint. Next migrate the
inbound O2DatabaseConnection/N2ConnectionListener server off NSStream/CFSocket,
then remove the unused N2 client APIs and delegate adapter. Preserve command
framing, partial reads/writes, EOF, backpressure, timeout, cancellation, subclass
callbacks and callback-thread ownership.
The fast HorosDirectTransfer transport already uses Network.framework and is not
part of this legacy transport rewrite.

### Metal 4

The current Metal command API is supported, not deprecated. Adopt Metal 4
incrementally and measure CPU submission overhead first. Explicit resource
lifetime, residency and synchronization replace assumptions made by the original
encoders. Preserve image math, registration scoring and cancellation behavior.

Completed compiler checkpoint: the shared per-device pipeline cache uses `MTL4Compiler`
and Metal 4 render/compute/function descriptors. It keeps the existing shader
library, cache keys, locking, caller API, formats, sample counts and blend factors.
Metal 4 has no pipeline depth-format property; the existing render-pass depth
textures and depth-stencil states remain in place. Compilation failures propagate
without a legacy compiler fallback. No shader source, image math, threadgroup
sizes, command encoding, resource ownership or registration decisions changed
in that checkpoint. The user rebuilt and reported that the initial workflows
work well; the supplied log had no Metal errors or performance measurements.

Completed checkpoint: database preview command encoding (`MetalPreviewImageView`).
The user rebuilt and reported that both the preview and window/level look good.

- The preview now owns an `MTL4CommandQueue`, one reusable command buffer, separate
  vertex/fragment argument tables and three allocator/uniform/residency slots.
  Slots cannot reset or accept new uploads until commit feedback confirms GPU
  completion. Argument bindings are snapshotted at draw encoding; nil texture
  slots are explicitly cleared between signed/unsigned and 2D/volume draws.
- Each submission retains its sampled textures, drawable, render-pass descriptor,
  layer residency set and renderer until completion, including when the view
  closes. Buffer/texture residency and drawable wait/commit/signal/present ordering
  are explicit. Immutable published cache volumes need no new cross-queue fence;
  their CPU uploads finish before publication. Shader code is unchanged.
- A small slice-texture pool only reuses matching textures that no outstanding
  frame references. Changing dimensions/type or clearing releases unused textures;
  in-flight frames retain what they need. CPU scrolling cannot overwrite an image
  that is still being sampled by the GPU. Busy slots coalesce into one redraw of
  the latest selection, without a semaphore wait on the UI thread.
- Preview timing reads Metal 4 commit feedback and actual presentation timestamps
  under the same optional launch flag. Blank previews still submit a clear pass.
  This pilot left the main viewer, scout and volume command encoding unchanged.

Also fixed preview window/level in response to the user's report: MR now uses
the same sampled, background-rejecting automatic calculation as Planar. Other
modalities keep valid DICOM windows, falling back to sampled intensities when
those are missing/invalid, and only then to the stored bit range. A different
Series Instance UID resets window defaults even if a thumbnail update passes
`resetWindowLevel: false`. Ordinary same-series scrolling and delayed volume
publication preserve manual adjustments. A zero-width request means automatic
windowing, not a width-one image. A single decode feeds both upload and window
calculation, and cached-volume scrolling does not decode just to reapply a window.

Current checkpoint: Planar/MPR display submission (`MetalViewerRenderer`).

- All three on-screen modes (`stack2D`, `mpr`, `mpr3D`), including inset planes,
  now share a Metal 4 display queue and reusable command buffer. Three independent
  frame slots own allocators, argument tables, reusable shared upload buffers and
  depth textures. CPU uploads get distinct aligned ranges for every draw, so ROI
  and inset uniforms cannot overwrite an earlier draw. Slots only recycle after
  GPU feedback. Busy draws coalesce without adding a CPU wait.
- Texture bindings explicitly clear all nine slots when switching signed,
  unsigned, float, base/overlay and transfer-function inputs. The sampler opts
  into argument-table binding. Texture formats, shaders, window/level, geometry,
  viewports, ROI opacity/colors and draw order are unchanged. Each frame has its
  own cleared depth attachment, preserving plane/ROI occlusion without sharing a
  writable depth texture across in-flight command buffers.
- Every bound buffer, texture, attachment and drawable remains retained and
  resident until GPU completion; completion also owns the renderer's pipelines
  and sampler. Input volume/CLUT/slice textures are immutable once published.
  `MetalPreparedVolumeCache` already checks GPU completion before publishing its
  output, so this checkpoint needs no new cross-queue waits in registration.
- GIF capture uses a Metal 4 compute encoder's texture-to-buffer copy with an
  explicit fragment-to-blit barrier. CPU readback occurs only after successful
  feedback, preserves packed BGRA rows, and delivers completion on the main
  thread. Allocation/encoder failures and closing a window while a capture waits
  for a free slot complete the request rather than leaving the exporter waiting.
- Submission retains wait/commit/signal/present ordering. Retrieval timing still
  distinguishes submission, successful/failed GPU completion and actual drawable
  presentation. The opt-in display benchmark uses Metal 4 feedback.
- Removed the display-only inline-vertex helper. Large and small dynamic MPR
  vertices now use the same per-frame upload pool; cached ROI/seed meshes stay
  cached. Registration compute and synchronous offscreen printing deliberately
  remain on their existing queue, not as fallbacks. Scout and volume-renderer
  command encoding were left for later checkpoints (volume display is below). Networking stays parked until
  the laptop is available.

Verification: 412 non-build checks pass, including an isolated warnings-as-errors
Swift type-check of the actual frame owner, submission, capture and retrieval
feedback methods against the macOS 27 Metal APIs (non-Metal application types are
stand-ins). The full renderer passes Swift syntax parsing. No app build or live
GPU run was performed by the agent. The user subsequently reported that the
Planar/MPR checkpoint works. The validation checklist covered rapid CT/MR scrolling,
window/level and CLUT changes, registered blending, MPR rotation with several ROIs,
plane occlusion/opacity, inset panes and `3D MPR`, GIF export, resize and close/reopen
while images load. Offscreen printing and registration should also remain working.

### Volume Display Checkpoint

- Volume drawing now uses a reusable Metal 4 command buffer and the shared
  `MetalViewerRenderFrame` owner. Two slots retain their own allocators, argument
  tables, upload buffers, depth targets, sampled textures and drawable resources.
  The existing one-frame limit for large ray-march regions and two-frame limit
  for smaller regions remain; pending redraws coalesce without a CPU wait.
- The second sampler slot preserves nearest-neighbor skin-mask sampling. Every
  sampled texture and cached overlay mesh is retained/resident through feedback.
  Frame resources are released on the main thread before admitting another frame.
  Crop geometry uses the per-frame upload pool instead of new buffers each draw.
- Volume preparation, surface picking and CPU readback remain on their existing
  compute queue. Prepared textures are published only after successful completion.
  These are separate workloads, not fallback rendering paths.
- Investigating the reported fine lines on bone exposed two renderer defects:
  linearly filtering octahedrally encoded normals interpolates across a discontinuity,
  and empty-brick skips erased the original ray jitter by landing on brick faces.
  Normals now use filterable Cartesian XYZ in RGBA8Snorm, normalized after sampling;
  gradient generation samples the corresponding source texel centers. Empty skips
  advance by whole ray steps to retain the original sampling phase.
- The lighting cache costs four rather than two bytes per voxel. Its existing
  memory accounting uses actual texture allocations. This does not modify source
  voxels, segmentation, CLUTs or opacity presets. The obsolete normal codec is removed.

Verification: 424 non-build checks pass, including numerical normal-wrap and
sampling-phase regressions and isolated warnings-as-errors Swift type checks of
the actual volume draw/overlay methods against the macOS 27 Metal API. Both changed
Swift renderers pass syntax parsing; the diff passes whitespace checks. No app or
shader build and no live GPU validation were performed by the agent. Recheck the
reported skull at the same zoom/CLUT/opacity while still and rotating, plus volume
zoom, window/level, crop handles, ROI/skin/trajectory overlays, picking and resize.
The numerical tests establish the defects, not proof that all visible artifacts
in the supplied screenshot are resolved. No performance improvement is claimed.

The user subsequently confirmed that the volume display and artifact fix look
great. A follow-on **High Quality** toolbar toggle now selects half-length ray
steps while retaining the normal setting when off (default, per window). Both
transfer-table paths compensate opacity with `1 - sqrt(1 - alpha)`, evaluated in
a numerically stable form, so doubling the sampling does not double optical
density. Picking uses the same quality settings, and the iteration budget covers
the full volume with shorter steps. Switching quality reuses source/gradient
textures; it does not resample the scan or change lighting smoothing. Existing
customized toolbars receive the button once without resetting their layout.

Verification for the toggle: 432 non-build checks pass, including the actual
toolbar and opacity/sampling methods type-checked against macOS 27, plus numerical
opacity/transmission and iteration-budget checks. Changed Swift files parse and
the diff passes whitespace checks. No app build or live toggle test was run.
Compare thin structures, rotation speed, opacity presets and picking in both
modes; test toolbar overflow and an existing customized toolbar. Performance is
not yet fully characterized: benchmark timings before further optimization, and
do not equate twice the visible ray samples with twice the total frame time.

The user reported little visible or performance difference between quality modes.
Source inspection confirms half-length steps, with pre-integrated transfer tables
already enabled in normal viewing. Added a bounded `VRQUALITY` console diagnostic
on the first submitted volume frame after each quality change. It snapshots the
actual uniforms, drawable dimensions and pre-integration flag, and reports GPU
execution time from successful Metal feedback (or explicitly unavailable). It
adds no GPU work or waits and does not require enabling the general profiler.
Compare on/off at the same camera and window size; one frame is a sanity check,
not a steady-state benchmark. 433 non-build checks pass; no app build performed.

The user subsequently supplied toggle timings at 5836 x 3322 pixels with
pre-integration enabled: normal 20.958/22.684 ms and high 30.279/33.018 ms.
The logged steps are 1.0 and 0.5 voxels respectively. High quality used about
45% more GPU time on average in these two samples, with little visible benefit
in this case. This confirms the toggle changes sampling and cost; it is not a
steady-state benchmark. Normal quality remains the default.

### Metal 4 ROI scout display checkpoint

`MetalViewerScoutROIRenderer` now uses a reusable Metal 4 command buffer and two
instances of the shared `MetalViewerRenderFrame`. Each in-flight frame owns its
allocator, argument tables, uniform storage, depth attachment and retained mesh.
Rotation updates reuse the existing mesh buffer. ROI edits replace that buffer
without overwriting vertices still being read by the GPU. The completion handler
retains the renderer and submitted resources even if its scout is removed.
Busy draw requests coalesce to the latest state and are rescheduled on the main
thread after completion; there is no added CPU wait for GPU completion.

Mesh generation, shader math, colors, single-sample rasterization, depth testing,
MPR-linked rotation, selection, context menus and transfer dragging are unchanged.
Regular image scouts remain on their existing thumbnail path. Optional
`METALPERF draw.scoutROI` timing covers CPU preparation, queue latency, GPU work
and presentation using the same opt-in logging as the other renderers. No
measured performance gain is claimed for this checkpoint.

Verification: 441 non-build checks pass, including eight scout checks and an
isolated macOS 27 type-check of the actual renderer initialization/submission,
shared frame resources, pipeline cache, rotation helpers and preview view. ROI
data and mesh generation are stubbed only in that API harness. The full scout
file passes syntax parsing, and the diff passes whitespace checks. No app build
or live GPU validation was performed. After rebuilding, test rotation in both
directions between scouts and MPR, multiple ROIs, colors, context menus, transfer
dragging, resizing, and deleting/replacing an ROI during rotation.

The user subsequently confirmed the scout checkpoint works. Their log contains
no Metal errors or performance timings. A read-only inspection confirmed that
the file generating the missing `Columns` warnings is a Basic Text SR report,
not an image; the image-reader probe is unnecessary. The other report warnings
concern missing SR observer metadata and WebKit service/sandbox failures. These
are separate from Metal submission; no report data or rendering was changed.

### Metal 4 offscreen print checkpoint

The Planar viewer's active 2D image print now uses the existing Metal 4 render
queue and reusable command buffer, with a separate lazily allocated print frame
and a reusable size-matched output texture. It does not consume an on-screen
frame slot or acquire a drawable. Vertex/uniform/texture bindings use the shared
frame argument tables, with explicit residency and retained input/output data.
The former single-use legacy render encoder helper has been removed.

Printing now completes asynchronously rather than waiting on the main thread
for GPU completion. Successful feedback copies BGRA pixels into owned `Data`
off the main thread, then releases the print slot and starts the print panel on
the main thread. Preparation and GPU errors complete with failure exactly once;
an in-flight print slot cannot be reset, resized or overwritten. The renderer,
pipeline and sampler stay alive through feedback/readback, including if the
pane is closed. The window captures the original job title, ignores duplicate
print commands while preparing/printing, and does not open a late print panel
after its window is closed. Existing slice preparation still runs on the main
thread; this checkpoint removes the GPU wait, not all possible loading work.

Pixel dimensions (including the existing 4096 maximum), aspect correction,
orientation, window/level, interpolation, CLUTs and registered overlays are
unchanged. Database image printing, its annotation overlays, report printing,
screen capture and GIF export are unchanged. Optional `METALPERF render.print`
timings cover preparation/submission/GPU work; `render.print.readback` separately
measures the CPU pixel copy. No performance gain has been measured yet.

Verification: 450 non-build checks pass, including nine print checks and an
isolated macOS 27 type-check of the actual print submission, shared resources,
image conversion, pane callback, controller print action and print view. Only
image-loading/model state is stubbed in that harness. All three changed Swift
files parse and the diff passes whitespace checks. No app build or live print
test was run. Rebuild and test File > Print in an active 2D Planar pane: ordinary
CT/MR, non-square images, changed window/level/CLUT and a registered overlay.
Compare orientation and framing, cancel and print again, switch panes while the
image is preparing, and close the viewer during preparation. Recheck database
image/report printing as an unchanged-path regression check.

Planar print follow-up: the focused `MetalImageView` inherited `NSView.print:`,
which handled File > Print before `MetalViewerWindow.printWindow` could render
the image. AppKit then attempted to print the Metal layer as an ordinary view,
producing blank pages. The view now forwards Print to its window's existing
image-print handler. Database/report printing and the rendering path are unchanged.
An isolated native AppKit responder check verified the interception and forwarding;
source regression coverage and the SDK type-check include the actual override.
User validation: Planar printing works after this responder-chain correction.

### Volume preparation

`Metal3DVolumeRenderer.prepareVolumeTexture` now uses one Metal 4 compute
encoder for optional resampling, gradients, brick ranges and the histogram.
It reuses the renderer's command buffer and queue, with a separate per-job
allocator, argument table and residency set. This is a cold-cache job rather
than per-frame allocation; a prepared-render cache hit still skips all of it.

Each uniform block has its own aligned region in one shared buffer, so later
dispatches cannot overwrite earlier inputs. An intrapass dispatch barrier makes
resampled voxels visible to all three consumers. Those consumers write separate
outputs and have no barriers between them. A producer barrier publishes the
results for subsequent GPU readers. All resources and pipelines stay alive
through feedback, including if the viewer closes during preparation. GPU errors
are logged and do not publish a partial cache entry or histogram. CPU histogram
readback and main-thread result publication still happen only after completion.

Shader calculations, texture formats, geometry, window presets, histogram bins,
render caching and quality settings are unchanged. Cursor picking, CPU volume
readback, shared source-volume preprocessing and registration submissions remain
on their existing paths. Optional `METALPERF prepare.volume` timing now uses
Metal 4 feedback; no performance gain has been measured.

Verification: 459 non-build checks pass, including eight targeted preparation
checks and an isolated SDK type-check of the actual preparation code, texture
allocation, cache and uniform structures. Swift parsing and whitespace checks
pass. No app build or live GPU-output comparison was run. After rebuilding,
open fresh CT and MR volumes (including anisotropic/cropped or gantry-corrected
data), inspect lighting and histogram, test clipping and high quality, and close
then reopen the same volume to check the cached path. Also close a viewer while
its volume is preparing. Compare `prepare.volume` timings on equivalent cold
cache workloads; a cache hit intentionally produces no preparation sample.

User validation: the volume-preparation checkpoint builds and works normally.

### Surface cursor picking

The volume viewer's surface cursor now uses Metal 4 with a lazy, reusable
command buffer, allocator, argument table, uniform buffers and result buffer.
Picking retains its own queue, separate from display's drawable waits. There is
still only one GPU pick in flight; newer mouse positions replace the pending
request, and completion starts the latest pending request instead of queuing
every mouse event.

Input textures remain resident and strongly retained until feedback has copied
the result. The main-thread callback then releases those textures and allows the
slot to be reused. The renderer holds pipelines and samplers through completion.
Failed submissions clear the busy state; GPU errors do not read or publish the
output buffer. Clearing the cursor invalidates pending/in-flight results without
resetting resources that the GPU could still be using. Coordinate mapping, hit
validation, normals, opacity/clipping behavior and the shader are unchanged.

Optional `METALPERF pick.surface` measurements cover preparation, submission and
GPU execution. No latency improvement has been measured. CPU volume readback,
shared source preprocessing and registration remain unchanged.

Verification: 468 non-build checks pass, including nine new cursor checks and an
isolated macOS SDK type-check of the actual resource owner, request handling,
submission, feedback and result validation. Swift parsing and whitespace checks
pass. No app build or live GPU comparison was run. Rebuild, move the cursor over
the 3D volume and empty space, rapidly move it out and back, rotate/zoom, and
exercise crop and skin clipping plus opacity/high-quality changes. Close a viewer
while picking is active and reopen it. The cursor should follow the surface as
before and must not reappear outside the view from a stale result.

User validation: the surface-cursor checkpoint works normally.

### Shared volume preparation

`MetalPreparedVolumeCache` now prepares source volumes for viewing and registration
using a reusable Metal 4 queue, command buffer, allocator, argument table and
uniform buffer per device. Conversion, optional gantry correction and the three
Gaussian/downsample pyramid levels share one compute encoder. Each dependent
dispatch has an explicit device-visible barrier and its own aligned uniform
slot. Input, output, scratch and kernel resources stay resident and strongly
retained until GPU feedback.

The cache no longer blocks an operation-queue worker in `waitUntilCompleted`.
A serial submission pump retains the previous one-preparation-at-a-time limit,
including GPU execution, so scratch volumes cannot overlap. Success and failure
both advance the queue, but never before partial-encoding cleanup has unwound.
Only successful GPU feedback publishes a result; callbacks still run on the main
queue. Coalesced requests, late cached-primary reuse, pyramid-upgrade preference,
memory-pressure retention rules and cache budgets are unchanged.

Signed/unsigned conversion, slope/intercept, CT background, voxel matrices,
Gaussian kernels, four-level coarse-to-fine pyramid order and texture formats
are unchanged. No shader changes were needed. Optional timings distinguish
`prepare.sharedVolume.display` and `prepare.sharedVolume.pyramid`; queue waiting
before encoding is not included. No performance gain has been measured.

Verification: 479 non-build checks pass, including 11 new shared-preparation
checks and an isolated macOS 27 SDK type-check of the entire actual cache,
resource owner, encoding helpers and completion handling. Swift parsing and
whitespace checks pass. No app build or live GPU-output comparison was run.
Rebuild and open fresh CT/MR volumes in MPR and volume rendering, including
gantry-corrected CT. Register a pair after first viewing it, then try another
registration and close/reopen volumes to exercise the cached paths. Also open
multiple volumes and close one while preparation is active. Image geometry,
window/level and registration results should remain unchanged.

User validation: shared volume preparation works normally.

### CPU volume readback

`Metal3DVolumeRenderer.cpuVolumeData` now copies the prepared float texture with a
Metal 4 compute encoder. The renderer no longer owns a legacy command queue.
Readback lazily creates and reuses its own queue, command buffer, allocator and
residency set, separate from display's potentially open encoder and drawable
waits. Texture/buffer lifetime and residency extend through GPU completion;
encoding or GPU failures return no data and cannot populate the CPU cache.

The successful shared buffer is handed to `Data(bytesNoCopy:)` with a custom
deallocator that retains the Metal buffer. This removes the explicit second
full-volume CPU allocation/copy. The output buffer is never reused for another
readback, so segmentation inputs may safely outlive the renderer or a cache
replacement. Float values, packed XYZ ordering, dimensions, spacing and transforms
are unchanged. Format, bounds and buffer-size checks precede submission, and a
single-depth copy uses the SDK's zero bytes-per-image convention.

Skin extraction and segmentation still expose synchronous input APIs. The cold
readback therefore still waits, now for Metal 4 feedback on Metal's internal
queue; this is not an asynchronous-tools change or a claim of eliminated UI
blocking. Warm CPU-cache hits skip all GPU work. Optional `readback.volume`
timings cover preparation/submission/GPU execution and `readback.volume.cpu_wait`
records the remaining wait. No speedup has been measured.

Verification: 488 non-build checks pass, including nine readback guards and a
macOS 27 SDK type-check of the actual resource owner, copy, feedback, cleanup and
Data ownership code. Swift parsing and whitespace checks pass. No app build or
live GPU comparison was run. After rebuilding, open a fresh CT volume and check
skin hiding, the skin surface and clip depth, then repeat to exercise CPU caching.
Check segmentation input/export and trajectory skin access where available;
also close/reopen the volume and recheck ordinary rotation/rendering.

User validation: CPU volume readback works normally.

### Registration submissions

The initial block match, directional metric, candidate batch and multi-series
support metrics now submit through Metal 4. Each registration job lazily owns
its own reusable queue, command buffer, allocator, argument table, inline buffer
and residency set. Its semaphore is reused, but fresh completion options register
one handler for every submission. Display submissions and overlapping
cancelled/replacement jobs do not share this mutable state.

Argument tables bind the existing texture inputs and working buffers by GPU
address/resource ID. Forward/reverse and support-pair dispatches still share one
submission, with separate uniform storage and disjoint output ranges. They need
no inter-dispatch barriers because none consumes another's output. Buffers and
textures stay strongly retained and resident until feedback, and submitted work
is always awaited even after cancellation before storage can be reset/released.
Failure or cancellation prevents CPU consumption of its result.

Kernel selection, sampling grids, candidate tiling, geometry, histogram layouts,
CPU reductions, registration metrics and optimization are unchanged. Source
comparison confirms the four CPU reduction bodies and the optimizer/transform
helpers match the preceding checkpoint. The CPU optimizer still waits on its
worker for each set of GPU scores; Metal 4 alone does not remove that dependency.
No measured speedup is claimed. Optional timing now includes the initial
`registration.blockMatch` submission alongside directional/batch/support metrics;
measurement reads existing feedback after the wait without an extra handler.

Verification: 498 non-build checks pass, including ten new registration checks
and an isolated macOS 27 SDK type-check of the actual resource owner, job, all
four complete dispatch paths and their CPU reductions (unrelated optimizer inputs
are stubbed). Swift parsing and whitespace checks pass. No app build or live GPU
comparison was run. After rebuilding, compare CT/MR registrations, thin-slab
coronal/sagittal registrations, multi-series support and refinement against the
previous results. Cancel or replace an overlay while registration is active,
then close/reopen and repeat. Check that the current job alone updates its viewer.

User validation found a hang in the first registration checkpoint. A live process
sample showed both workers waiting on the registration completion semaphore. A
no-build Metal API probe with a 16-byte GPU fill reproduced the cause: reusing
`MTL4CommitOptions` delivered feedback only on the first commit, although the
second fill completed (independently confirmed with a shared GPU event). Fresh
options restored callbacks on successive submissions. The fix creates options
and registers completion inside each submission, preserving reusable GPU storage
and all registration mathematics. Regression guards now prohibit retaining
completion options across submissions. End-to-end registration awaits retesting.

### Timing and remaining sequence

Optional timing now covers cold pipeline compilation, database preview drawing,
Planar/MPR and ROI scout drawing, offscreen printing, volume drawing/preparation,
shared viewing/registration volume preparation, CPU volume readback, surface picking,
and block-match/directional/batched/support registration submissions. This is the first measurement checkpoint, not
an end-to-end startup profiler or evidence of a speedup. Full startup includes
file reads, decoding, CPU volume work and UI updates outside these measurements.
The pre-migration compiler baseline has not been collected.

To benchmark, add `-HorosMetalPerformanceLogging YES` to the Xcode scheme's
arguments passed on launch. It defaults off; remove the argument after testing.
No preference is changed by the implementation. `METALPERF` lines report the
first sample and then cumulative count/mean/maximum/last every 60 samples per
operation, across viewers on that launch. Logs contain operation/shader names
only, not patient identifiers. Warm cache hits do not compile or emit compile
timings. Compare the same workloads, since candidate counts and volume sizes
affect these per-command-buffer measurements.

- `cpu_prepare`: work from entry to the measured draw/compute preparation through
  the submission point, including drawable acquisition in draw methods. It is
  not pure command-encoder overhead or a measure of asynchronous image loading.
- `submit_to_gpu`: submission/driver/queue latency up to GPU start.
- `gpu`: actual command-buffer GPU start/end timestamps, not callback duration.
- `cpu_wait`: time in the synchronous registration or CPU volume readback wait,
  excluding diagnostic output. Registration uses no extra completion handler or
  wait for measurement.
- `submit_to_observed` and `gpu_to_observed`: when the host observes completion,
  either in a callback or after an existing wait. These include host scheduling
  and earlier completion-handler work, not just GPU execution.
- `submit_to_present`: the drawable's actual presentation timestamp relative to
  submission. Missing GPU/presentation timestamps are omitted, not treated as zero.

Proposed sequence:

1. Record cold/warm viewer startup, CPU encoding/submission, GPU execution, waits
   and frame presentation separately. Cover scrolling, MPR rotation with ROIs,
   first-volume preparation, and single/multi-series registration.
2. Implemented, initial user validation passed: `MetalPipelineCache.swift` compiler integration
   while retaining the existing per-device immutable pipeline cache, shader
   functions, formats and blending settings. Compilation is already cached, so
   do not expect this alone to speed up steady-state registration or scrolling.
3. Preview, Planar/MPR and volume display (including the optional high-quality
   toggle), ROI scout rendering and offscreen printing user-validated.
   Rendering uses reusable command
   buffers, allocators, argument tables and residency sets with explicit per-in-flight resource
   ownership. Do not reset allocators or overwrite uniforms before GPU completion.
   Preserve drawable presentation, captures, ROI depth/opacity and texture formats.
4. Volume resampling, gradients, brick ranges and histogram preparation now use
   one Metal 4 encoder with explicit barriers and are user-validated. Surface
   cursor picking uses reusable Metal 4 resources and is user-validated.
   Shared source-volume preprocessing now uses one Metal 4 encoder and nonblocking
   completion-driven scheduling, and is user-validated. CPU volume readback now
   uses Metal 4 and transfers buffer ownership without an extra full-volume copy;
   it retains the synchronous input contract and is user-validated.
   Registration submissions now use per-job reusable Metal 4 resources and await
   user validation. Candidate batching and working-buffer reuse are preserved.
   CPU histogram reductions require completed GPU output, so wait removal or
   further batching is a separate measured change, not an automatic consequence
   of Metal 4 adoption. The remaining legacy GPU queue in `MetalViewer` belongs
   to `MetalStudyROIGPUSolver` in `MetalStudyROI.swift`; its dependent red/black
   relaxation phases are the next candidate, preserving their barriers, workspace
   ownership and refinement results.
5. Consider the ML encoder/tensor APIs when integrating a trained segmentation
   model. This is GPU inference, not a new direct Neural Engine training API.
   Keep MetalFX frame generation, upscaling and denoising out of diagnostic image,
   measurement and registration paths.

The Metal 4 core supports M1, but optional features have separate GPU-family
requirements. Unified compute encoding does not eliminate render or ML encoders.
Residency and synchronization must be addressed together; argument bindings alone
do not establish resource lifetime or safe producer/consumer ordering.

Compare rendered pixels, slice identity, annotations, registration scores and
transforms as well as timings on M1-class hardware before expanding adoption.
Include concurrent viewers/jobs, cancellation, resizing, captures and memory
pressure. Do not claim a speedup from API replacement alone. No build without
the user's explicit request.

References: [Metal 4 adoption](https://developer.apple.com/videos/play/wwdc2025/205/),
[Metal 4 rendering sample](https://developer.apple.com/documentation/metal/drawing-a-triangle-with-metal-4),
[resource synchronization](https://developer.apple.com/documentation/metal/resource-synchronization),
[core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api),
[GPU ML integration](https://developer.apple.com/videos/play/wwdc2025/262/),
[hardware feature tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf).
