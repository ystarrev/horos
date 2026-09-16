# Bundled NIfTI library

The files listed in `UPSTREAM.json` are byte-for-byte copies from
[NIFTI-Imaging/nifti_clib](https://github.com/NIFTI-Imaging/nifti_clib), pinned to
commit `8f72d1165aa62320cc6982d6ddd71a7f6b9924c5` (December 20, 2024).
This is a post-3.0.1 snapshot, not a new tagged release. Its NIfTI-1 I/O component
identifies itself as 2.1.0; the package and component version numbers differ.
The upstream public-domain notice is included as `LICENSE`.

## Integration

Horos compiles `nifti1_io.c` and `znzlib.c` directly. Upstream's `niftilib/` and
`znzlib/` files are flattened into this directory so the existing Xcode paths
remain valid. No upstream source, header, licence or whitespace is modified.
Keep Horos-specific changes in Horos's callers or project settings.

Only the NIfTI-1/Analyze-compatible API is bundled, not upstream's incompatible
NIfTI-2 API, command-line tools, examples or build system. This update preserves
the existing compile definitions and import routing; it does not enable new
formats or change Horos's orientation, scaling or pixel-conversion policies.
In particular, it does not introduce direct `.nii.gz` import support.

All dependency files are committed with Horos. Building on another computer
does not require a download, submodule checkout or separate NIfTI build.

## Verification and updates

From the repository root, run the non-build checks:

```sh
python3 -B -m unittest discover -s Scripts -p test_nifti_upstream.py
```

These check file hashes, Xcode membership, C/Objective-C/Objective-C++ API
compatibility and Apple-silicon syntax. They do not execute the image reader
or build Horos. After rebuilding, smoke-test a known `.nii` image and an
Analyze `.hdr`/`.img` pair: compare dimensions, voxel spacing, slice order,
orientation and intensities, and inspect NIfTI metadata.

For a future update:

1. Select an exact upstream commit, not a moving branch URL.
2. Download its archive and review changes affecting Horos's callers.
3. Copy only the files in the manifest from their `upstream_path` locations,
   without editing or reformatting them. Include any new required headers.
4. Update the revision, archive URL and SHA-256 hashes in `UPSTREAM.json`, and
   adjust Xcode references if the file list changed.
5. Run the non-build checks and repeat the image smoke tests after rebuilding.

The archive hash records the downloaded snapshot; per-file hashes verify the
vendored content offline. Harmless trailing whitespace in upstream files is
intentionally retained.
