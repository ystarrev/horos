# Stock DCMTK Listener Verification

The toolkit stays at the repository's pinned upstream revision. This change
does not upgrade DCMTK, change the database format, or change Horos Direct
Transfer. `HorosQueryRetrieveServer` uses `DcmThreadSCP` for the association
lifecycle, stock find/store/move contexts, and the public DIMSE providers.
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
- AE validation, default-role C-STORE, negotiated C-GET receiving roles, and
  study-root service enable/disable behavior.

## Application Transfer Checks

After the normal incremental Horos build, use a small, known test study first:

1. C-ECHO, study C-FIND, series expansion, and C-STORE into Horos. Check the
   received study imports and opens normally after the association closes.
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
