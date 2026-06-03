#!/usr/bin/env python3
"""Adapter from the Horos Metal 3D local job contract to a local ML backend.

The adapter keeps patient data local. It converts Horos' raw float32 volume to
NIfTI when nibabel/numpy are available, runs a command supplied by the user, and
converts the resulting segmentation back to Horos' raw UInt8 labelmap format.

Set HOROS_TUMOR_SEGMENTATION_COMMAND, or create
~/.horos_metal3d_tumor_segmentation.json with a "command" field, containing a
shell-style command template. Supported placeholders:

  {job}        path to the Horos job JSON
  {work}       local working directory
  {input}      generated input-volume.nii.gz
  {output_nii} expected output-labelmap.nii.gz
  {output_raw} expected Horos output tumor-labelmap.uint8.raw
  {result}     expected result metadata JSON

The command may write either {output_raw} directly or {output_nii}.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def configured_command_template() -> str:
    command = os.environ.get("HOROS_TUMOR_SEGMENTATION_COMMAND", "").strip()
    if command:
        return command

    config_path = Path.home() / ".horos_metal3d_tumor_segmentation.json"
    if config_path.exists():
        config = load_json(config_path)
        command = str(config.get("command", "")).strip()
        if command:
            return command

    return ""


def require_numpy_and_nibabel():
    try:
        import nibabel as nib  # type: ignore
        import numpy as np  # type: ignore
    except ImportError as error:
        raise RuntimeError(
            "This adapter needs numpy and nibabel unless the backend writes "
            "the raw Horos output directly. Install them in the local Python "
            "environment used by the helper."
        ) from error
    return np, nib


def raw_volume_to_nifti(job: dict, input_nii: Path) -> None:
    np, nib = require_numpy_and_nibabel()

    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_count = int(job["expectedVoxelCount"])
    input_path = Path(job["inputVolume"])

    volume = np.fromfile(input_path, dtype="<f4", count=expected_count)
    if volume.size != expected_count:
        raise RuntimeError(f"input voxel count mismatch: {volume.size} != {expected_count}")

    # Horos raw order is z, y, x with x fastest. NIfTI arrays are x, y, z here.
    image = volume.reshape((depth, height, width)).transpose(2, 1, 0)
    matrix = job.get("referenceVoxelToPatientMatrix")
    if isinstance(matrix, list):
        affine = np.asarray(matrix, dtype=np.float64)
        if affine.shape != (4, 4) or not np.isfinite(affine).all():
            affine = None
    else:
        affine = None
    if affine is None:
        spacing = [float(value) for value in job["spacingMM"]]
        affine = np.diag([spacing[0], spacing[1], spacing[2], 1.0])
    affine = np.diag([-1.0, -1.0, 1.0, 1.0]) @ affine
    nib.save(nib.Nifti1Image(image.astype(np.float32), affine), str(input_nii))


def nifti_labelmap_to_raw(job: dict, output_nii: Path, output_raw: Path) -> None:
    np, nib = require_numpy_and_nibabel()

    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_count = int(job["expectedVoxelCount"])
    nii = nib.load(str(output_nii))
    data = np.asarray(nii.get_fdata(), dtype=np.float32)
    expected_shape = (width, height, depth)
    if tuple(data.shape[:3]) != expected_shape:
        raise RuntimeError(f"output NIfTI shape mismatch: {data.shape[:3]} != {expected_shape}")

    labels = np.rint(data).clip(0, 255).astype(np.uint8)
    raw = labels.transpose(2, 1, 0).reshape(expected_count)
    output_raw.write_bytes(raw.tobytes())


def tumour_seed_count(job: dict) -> int:
    seeds = job.get("tumourSeeds") or job.get("tumorSeeds") or []
    return len(seeds) if isinstance(seeds, list) else 0


def tumour_seed_points(job: dict, shape: tuple[int, int, int]) -> list[tuple[int, int, int]]:
    seeds = job.get("tumourSeeds") or job.get("tumorSeeds") or []
    if not isinstance(seeds, list):
        return []

    depth, height, width = shape
    points: list[tuple[int, int, int]] = []
    seen: set[tuple[int, int, int]] = set()
    for seed in seeds:
        if not isinstance(seed, dict):
            continue
        coordinate = seed.get("volumeVoxel")
        if not coordinate:
            source_pixel = seed.get("sourcePixel")
            slice_index = seed.get("sliceIndex")
            if isinstance(source_pixel, list) and len(source_pixel) >= 2 and slice_index is not None:
                coordinate = [source_pixel[0], source_pixel[1], slice_index]
        if not isinstance(coordinate, list) or len(coordinate) < 3:
            continue
        try:
            x = int(round(float(coordinate[0])))
            y = int(round(float(coordinate[1])))
            z = int(round(float(coordinate[2])))
        except (TypeError, ValueError):
            continue
        if 0 <= x < width and 0 <= y < height and 0 <= z < depth:
            point = (z, y, x)
            if point not in seen:
                seen.add(point)
                points.append(point)
    return points


def seed_selection_radius_mm(job: dict) -> float:
    try:
        return max(float(job.get("tumourSeedSelectionRadiusMM", 60.0)), 2.5)
    except (TypeError, ValueError):
        return 60.0


def seed_ball_mask(np, shape: tuple[int, int, int], seed_points: list[tuple[int, int, int]], job: dict, radius_mm: float):
    mask = np.zeros(shape, dtype=bool)
    if not seed_points:
        return mask

    spacing_x, spacing_y, spacing_z = [max(float(value), 1e-6) for value in job["spacingMM"]]
    radius_x = max(int(np.ceil(radius_mm / spacing_x)), 1)
    radius_y = max(int(np.ceil(radius_mm / spacing_y)), 1)
    radius_z = max(int(np.ceil(radius_mm / spacing_z)), 1)
    depth, height, width = shape
    for seed_z, seed_y, seed_x in seed_points:
        z0 = max(seed_z - radius_z, 0)
        z1 = min(seed_z + radius_z + 1, depth)
        y0 = max(seed_y - radius_y, 0)
        y1 = min(seed_y + radius_y + 1, height)
        x0 = max(seed_x - radius_x, 0)
        x1 = min(seed_x + radius_x + 1, width)
        zz, yy, xx = np.ogrid[z0:z1, y0:y1, x0:x1]
        distance_mm = np.sqrt(
            ((xx - seed_x) * spacing_x) ** 2
            + ((yy - seed_y) * spacing_y) ** 2
            + ((zz - seed_z) * spacing_z) ** 2
        )
        mask[z0:z1, y0:y1, x0:x1] |= distance_mm <= radius_mm
    return mask


def constrain_raw_labelmap_to_tumour_seeds(job: dict, output_raw: Path) -> dict:
    np, _ = require_numpy_and_nibabel()
    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_count = int(job["expectedVoxelCount"])
    labels = np.fromfile(output_raw, dtype=np.uint8, count=expected_count)
    if labels.size != expected_count:
        raise RuntimeError(f"raw output size mismatch: {labels.size} != {expected_count}")
    labels = labels.reshape((depth, height, width))

    seed_points = tumour_seed_points(job, labels.shape)
    summary = {
        "provided": int(tumour_seed_count(job)),
        "usable": int(len(seed_points)),
        "used": False,
        "mode": "none",
    }
    if not seed_points:
        return summary

    seed_neighborhood = seed_ball_mask(np, labels.shape, seed_points, job, radius_mm=8.0)
    if np.any(labels[seed_neighborhood] > 0):
        locality = seed_ball_mask(np, labels.shape, seed_points, job, radius_mm=seed_selection_radius_mm(job))
        labels = np.where(locality, labels, 0).astype(np.uint8, copy=False)
        summary["used"] = True
        summary["mode"] = "seed-locality-filter"
    else:
        seed_region = seed_ball_mask(np, labels.shape, seed_points, job, radius_mm=2.5)
        labels = np.zeros_like(labels, dtype=np.uint8)
        labels[seed_region] = 1
        summary["used"] = True
        summary["mode"] = "seed-spheres-fallback"

    output_raw.write_bytes(labels.reshape(expected_count).tobytes())
    return summary


def label_counts(output_raw: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in output_raw.read_bytes():
        if value == 0:
            continue
        key = str(value)
        counts[key] = counts.get(key, 0) + 1
    return counts


def write_default_result(job: dict, output_raw: Path, result_path: Path, seed_guidance: dict | None = None) -> None:
    if result_path.exists():
        result = load_json(result_path)
        result["labelVoxelCounts"] = label_counts(output_raw)
        if seed_guidance and seed_guidance.get("provided", 0) > 0:
            result["tumourSeedGuidance"] = seed_guidance
        result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return

    result = {
        "status": "ok",
        "backend": "external-command",
        "outputLabelmap": str(output_raw),
        "labels": job.get("labels", {}),
        "labelVoxelCounts": label_counts(output_raw),
        "message": "External local tumour segmentation command completed.",
    }
    if seed_guidance and seed_guidance.get("provided", 0) > 0:
        result["tumourSeedGuidance"] = seed_guidance
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_backend(command_template: str, substitutions: dict[str, str], work_dir: Path) -> None:
    command = command_template.format(**substitutions)
    argv = shlex.split(command)
    if not argv:
        raise RuntimeError("HOROS_TUMOR_SEGMENTATION_COMMAND expanded to an empty command")
    subprocess.check_call(argv, cwd=str(work_dir))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args()

    job_path = Path(args.job)
    job = load_json(job_path)
    work_dir = Path(job.get("workingDirectory") or job_path.parent)
    output_raw = Path(job["outputLabelmap"])
    result_path = Path(job.get("resultJSON") or (work_dir / "result.json"))
    input_nii = work_dir / "input-volume.nii.gz"
    output_nii = work_dir / "output-labelmap.nii.gz"

    command_template = configured_command_template()
    if not command_template:
        raise RuntimeError(
            "Set HOROS_TUMOR_SEGMENTATION_COMMAND, or create "
            "~/.horos_metal3d_tumor_segmentation.json with a command field, "
            "or choose the mock helper for pipeline smoke testing."
        )

    raw_volume_to_nifti(job, input_nii)
    run_backend(
        command_template,
        {
            "job": str(job_path),
            "work": str(work_dir),
            "input": str(input_nii),
            "output_nii": str(output_nii),
            "output_raw": str(output_raw),
            "result": str(result_path),
        },
        work_dir,
    )

    if output_raw.exists():
        actual = output_raw.stat().st_size
        expected = int(job["expectedVoxelCount"])
        if actual != expected:
            raise RuntimeError(f"raw output size mismatch: {actual} != {expected}")
    elif output_nii.exists():
        nifti_labelmap_to_raw(job, output_nii, output_raw)
    else:
        raise RuntimeError(f"backend wrote neither {output_raw} nor {output_nii}")

    seed_guidance = constrain_raw_labelmap_to_tumour_seeds(job, output_raw)
    write_default_result(job, output_raw, result_path, seed_guidance)
    print(json.dumps({"status": "ok", "outputLabelmap": str(output_raw), "resultJSON": str(result_path)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"metal3d_tumor_segmentation_external.py: {error}", file=sys.stderr)
        sys.exit(1)
