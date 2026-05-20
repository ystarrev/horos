# Horos Metal 3D Tumour Segmentation Helper Contract

Horos launches a local helper with:

```sh
helper --job /path/to/job.json
```

The helper must write the UInt8 raw labelmap named by `outputLabelmap`. The byte
count must equal `expectedVoxelCount`, using the same voxel order as the input
raw volume: `z, y, x` with `x` fastest.

The helper may also write `resultJSON`. Horos reads it when present and shows
its `message` and `labels` in the completion alert.

Current labels:

- `0`: background
- `1`: tumour core
- `2`: edema
- `4`: enhancing tumour

The current first-step viewer contract exports one displayed/resampled volume:

- `inputVolume`: float32 little-endian raw scalar volume
- `dimensions`: `[width, height, depth]`
- `spacingMM`: `[x, y, z]`

The job also includes `selectedDICOMSeries` when the user selects local study
series in the viewer. Each entry contains local series metadata plus `localPaths`
and `localImageCount`. The user selects these series from a checkbox list before
the helper is launched.

The job includes `tumourSeeds` when the user has placed tumour seed points in
the Metal viewers. Each seed includes source pixel/slice coordinates, DICOM
patient coordinates, diameter, and, when the seed falls inside the 3D segmenter
volume, `volumeVoxel`: `[x, y, z]` in the helper input volume grid. Helpers
should prefer `volumeVoxel` for seed-guided inference because the 3D viewer may
crop air and resample slice spacing before writing `inputVolume`.
The job also includes `tumourSeedSelectionRadiusMM`, currently 60 mm, for
helpers that need a simple seed-locality bound.

`metal3d_tumor_segmentation_candidate.py` is the current local candidate
segmenter. When `selectedDICOMSeries` includes usable local DICOM paths, it
loads the selected series, assigns likely T1/T1c/T2/FLAIR roles from the series
metadata, resizes them to the displayed volume grid, and runs a deterministic
multimodal heuristic. If fewer than two selected series can be decoded, it falls
back to the displayed single-volume path. This is useful for local pipeline
testing and rough candidate visualization, but it is not a trained or diagnostic
tumour model. The candidate restricts its search to a conservative eroded
inner-head mask to reduce skin, face, and sinus false positives.
When `tumourSeeds` are present, the candidate prefers candidate components that
touch a seed neighbourhood, keeps the result local to the seed region, and
falls back to a 5 mm seed sphere if no candidate component touches a seed.
Helpers can report seed handling in `result.json` as `tumourSeedGuidance` with
`provided`, `usable`, `used`, and `mode`; Horos shows this in the completion
details.

`metal3d_tumor_segmentation_mock.py` is only a smoke-test helper.

`metal3d_tumor_segmentation_nnunet.py` is the local trained-model helper. It
requires an existing nnU-Net v2 trained model folder on the local computer and
does not download or upload patient data. Configure it with either:

```sh
export HOROS_TUMOR_NNUNET_MODEL_FOLDER=/local/path/to/nnunet/model
```

or:

```json
{
  "nnunet_model_folder": "/local/path/to/nnunet/model",
  "nnunet_channels": "flair,t1,t1c,t2",
  "nnunet_device": "mps",
  "nnunet_folds": "0"
}
```

The helper writes selected local DICOM series into nnU-Net channel files named
`horos_0000.nii.gz`, `horos_0001.nii.gz`, etc. The default channel order is
`flair,t1,t1c,t2`, matching common BraTS/Medical Segmentation Decathlon
conventions; set `nnunet_channels` if a model expects a different order. nnU-Net
labels with value `3` are remapped to Horos label `4` for enhancing tumour.
If a configured model expects a seed channel, include `seed`, `tumourseed`, or
`tumorseed` in `nnunet_channels`; the helper writes a binary 5 mm seed-mask
channel from `tumourSeeds`. When seeds are present, the helper also post-filters
the returned labelmap to components touching the seed neighbourhood, with a
5 mm seed-sphere fallback if the model output misses the seeds.

`metal3d_tumor_segmentation_external.py` is the bridge for a real local backend.
It converts the raw volume to `input-volume.nii.gz`, runs a command from
`HOROS_TUMOR_SEGMENTATION_COMMAND`, or from
`~/.horos_metal3d_tumor_segmentation.json`, then accepts either:

- raw output written directly to `{output_raw}`
- NIfTI output written to `{output_nii}`, which the adapter converts back
- seed-constrained output when `tumourSeeds` are present, so external backends
  that do not yet understand seeds still return a labelmap around the hint
- result metadata written to `{result}`

Example command template:

```sh
export HOROS_TUMOR_SEGMENTATION_COMMAND='python3 /local/my_infer.py --input {input} --output {output_nii}'
```

Equivalent config file:

```json
{
  "command": "python3 /local/my_infer.py --input {input} --output {output_nii}"
}
```

Then choose `Scripts/metal3d_tumor_segmentation_external.py` from the Horos
Tumour toolbar item.
