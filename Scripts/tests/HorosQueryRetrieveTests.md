# Stock DCMTK Listener Verification

The toolkit stays at the repository's pinned upstream revision. This change
does not upgrade DCMTK, change the database format, or change Horos Direct
Transfer. `HorosQueryRetrieveServer` uses `DcmThreadSCP` for the association
lifecycle, stock find/move contexts, and the public DIMSE providers. Incoming
C-STORE datasets stream unchanged to disk; a Horos completion callback checks
the dataset SOP identifiers before handing the closed file to the import queue.
The stock store context remains available for explicit dataset normalization.
C-GET uses the same SOP validation and publishes each completed file immediately,
before its C-STORE acknowledgement, through the existing incoming-import signal.
Horos's C-GET callback selects a context for each source image and invokes the
registered DCMTK codecs only when the selected representation requires them.

## Checks Without a Build

- Run `python3 -B -m unittest discover -s Scripts -p 'test_dcm_*.py'`.
- Check both listener sources with `clang++ -fsyntax-only` using the existing
  project's compiler options/generated dependency headers.
- `git -C DCMTK diff --exit-code HEAD --` must produce no changes.

The Python suite checks source/project integration, not runtime transfers.

## Synthetic Runtime Fixture

`HorosQueryRetrieveTests.cpp` is deliberately outside the application target.
It includes the listener implementation to exercise internal helpers without
making them public API. Only compile/run it when a build has been approved.
Use the existing project's SDK, C++17 settings, and stock DCMTK libraries
(`dcmqrdb`, `dcmnet`, `dcmdata`, `oflog`, `ofstd`, and their configured dependencies).
Compile the test file alone, not together with a second copy of the server source.
Set `DCMDICTPATH` to the existing build's `DCMTK/dicom.dic` if the dictionary is
not otherwise available to the standalone executable.

The fixture creates tiny synthetic images under its own temporary directory;
it never opens a Horos database or uses patient files. It covers:

- Exact compressed pass-through, even without a registered decoder.
- Compressed/native instances of the same SOP class in one association.
- Native-to-RLE and RLE-to-native conversion with pixel equality checks.
- Rejection of a context in which the receiver has the wrong role.
- Missing decoder and unchanged source-file bytes.
- Missing-file counts, failed UID lists, cancellation after a failure, empty
  results, and database search failure.
- Streamed native/implicit/big-endian/RLE images without a decoder, unchanged
  SR/PDF payloads, UID mismatches, partial-file publication prevention, storage
  refusal, database failure, missing files, and ignore-store behavior.
- AE validation, default-role C-STORE, negotiated C-GET receiving roles, and
  study-root service enable/disable behavior.

## Application Transfer Checks

After the normal incremental Horos build, use a small, known test study first:

1. C-ECHO, study C-FIND, series expansion, and C-STORE into Horos. Include a
   compressed study and an SR/PDF report. Check imports, displayed pixels,
   report viewing, and the recorded transfer syntax. Cancel an incoming transfer
   and confirm no partial image is imported; then retrieve it again.
2. An actual DICOM C-GET from Horos to a client offering compressed and native
   storage contexts. Include a study with mixed compressed/native instances.
   Confirm counts, headers, and displayed pixels. Horos Direct Transfer can
   bypass C-GET, so a successful direct transfer alone does not test this path.
3. C-GET to a native-only client, forcing decompression, and a receiver offering
   the stored compressed syntax, allowing unchanged pass-through.
4. Cancel a larger C-GET, then query/retrieve again. No stuck association or
   falsely successful final status should remain.
5. Normal PACS C-MOVE retrieval into Horos, and C-MOVE served by Horos to a
   configured destination. These continue to use stock handlers.
6. Repeated and concurrent connections in the configured listener process mode;
   quit/relaunch and reconnect. Also exercise the TLS listener when used.

No build, synthetic runtime execution, or live transfer is implied by passing
the source checks.

## C-GET Publication Fixture

`CGetStorePublicationTests.mm` is another standalone fixture, not an app source.
`test_dcm_cget_incremental.py` extracts `HorosCGetStoreContext` unchanged from
`DCMTKQueryNode.mm` into a temporary include and syntax-checks the fixture. It
does not compile an executable or run the fixture. After explicit build approval,
the same include can be used to build the fixture against Foundation and the
existing stock DCMTK libraries. Its database object is a notification counter;
no patient database or network connection is involved.

Runtime cases cover publication of successive image/SR/PDF files before the
session ends, unchanged bytes, no publication during partial receipt, rejection
of mismatched dataset UIDs, destination collision without overwrite, failed
publication retaining the completed source, and transport failure without an
import notification.

For application verification, use an actual C-GET retrieve-and-view, not C-MOVE
or Horos Direct Transfer. Confirm the viewer opens before retrieval completes,
then cancel a larger transfer and verify the completed images remain available.
Retry it and check the final object count and report viewing. The console line
`C-GET published ... completed object(s)` confirms this path was exercised.
