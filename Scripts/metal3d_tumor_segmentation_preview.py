#!/usr/bin/env python3
"""Write resampled tumour-segmentation input channels for Horos review."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def ensure_scientific_python() -> None:
    preferred_python = Path("/Users/ystarrev/miniconda3/bin/python3")
    if preferred_python.exists() and os.environ.get("HOROS_TUMOR_SEGMENTATION_BOOTSTRAPPED") != "1":
        clean_environment = dict(os.environ)
        for key in ("PYTHONHOME", "PYTHONEXECUTABLE"):
            clean_environment.pop(key, None)
        clean_environment["PYTHONPATH"] = ":".join([
            "/opt/homebrew/lib/python3.13/site-packages",
            "/Users/ystarrev/Development/ToolCursorbin/lib/python3.13/site-packages",
        ])
        clean_environment["HOROS_TUMOR_SEGMENTATION_BOOTSTRAPPED"] = "1"
        os.execve(str(preferred_python), [str(preferred_python)] + sys.argv, clean_environment)

    try:
        import numpy  # noqa: F401
        import scipy  # noqa: F401
        import skimage  # noqa: F401
        import pydicom  # noqa: F401
        return
    except (ImportError, ModuleNotFoundError) as error:
        raise RuntimeError(
            "Could not import numpy/scipy/skimage/pydicom for segmentation input preview. "
            f"Python executable: {sys.executable}"
        ) from error


ensure_scientific_python()

import numpy as np

from metal3d_dicom_geometry import (
    affine_from_job,
    channel_worker_count,
    classify_series_role,
    load_dicom_series_registered,
    target_shape_from_job,
)


PREFERRED_CHANNEL_ORDER = ["flair", "t1", "t1c", "t2"]


def load_job(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def channel_sort_key(channel: dict) -> tuple[int, str]:
    role = str(channel.get("role") or "")
    try:
        order = PREFERRED_CHANNEL_ORDER.index(role)
    except ValueError:
        order = len(PREFERRED_CHANNEL_ORDER)
    return order, role


def robust_window(volume: np.ndarray) -> tuple[float, float]:
    values = volume[np.isfinite(volume)]
    if values.size == 0:
        return 0.0, 1.0

    low, high = np.percentile(values, [1.0, 99.0])
    if not np.isfinite(low) or not np.isfinite(high) or high <= low:
        low = float(np.min(values))
        high = float(np.max(values))
    if high <= low:
        high = low + 1.0
    return float(low), float(high)


def series_label(series: dict, role: str) -> str:
    description = str(series.get("seriesDescription") or series.get("localSeriesDescription") or "").strip()
    number = str(series.get("seriesNumber") or "").strip()
    parts = [role.upper()]
    if number:
        parts.append(f"#{number}")
    if description:
        parts.append(description)
    return " ".join(parts)


def write_preview_channel(job_item: tuple[int, str, dict, list[str], tuple[int, int, int], np.ndarray, Path, tuple[int, int, int]]):
    index, role, series, paths, target_shape, target_affine, output_dir, dimensions = job_item
    width, height, depth = dimensions
    resampled = load_dicom_series_registered(
        paths,
        target_shape,
        target_affine,
        include_slice_mapping=True,
    )
    if resampled is None:
        return None

    window_min, window_max = robust_window(resampled.volume)
    file_name = f"{index:02d}_{role}.float32.raw"
    path = output_dir / file_name
    resampled.volume.astype("<f4", copy=False).tofile(path)

    summary = dict(resampled.summary)
    summary.update({
        "role": role,
        "label": series_label(series, role),
        "seriesDescription": series.get("seriesDescription") or series.get("localSeriesDescription") or "",
        "seriesNumber": series.get("seriesNumber") or "",
        "path": str(path),
        "scalarType": "float32-le",
        "dimensions": [width, height, depth],
        "windowMin": window_min,
        "windowMax": window_max,
    })
    return summary


def preview_channel_jobs(job: dict, output_dir: Path, target_shape: tuple[int, int, int], target_affine: np.ndarray) -> list[tuple[int, str, dict, list[str], tuple[int, int, int], np.ndarray, Path, tuple[int, int, int]]]:
    dimensions = (int(job["dimensions"][0]), int(job["dimensions"][1]), int(job["dimensions"][2]))
    selected_series = job.get("selectedDICOMSeries") or []
    if not isinstance(selected_series, list):
        return []

    jobs = []
    used_roles: set[str] = set()

    for index, series in enumerate(selected_series):
        if not isinstance(series, dict):
            continue
        paths = series.get("localPaths") or []
        if not isinstance(paths, list) or not paths:
            continue

        role = classify_series_role(series)
        if role in used_roles:
            role = f"{role}_{index + 1}"
        used_roles.add(role)
        jobs.append((index, role, series, [str(path) for path in paths], target_shape, target_affine, output_dir, dimensions))

    return jobs


def selected_preview_channels(job: dict, output_dir: Path) -> list[dict]:
    target_shape = target_shape_from_job(job)
    target_affine = affine_from_job(job)
    output_dir.mkdir(parents=True, exist_ok=True)
    jobs = preview_channel_jobs(job, output_dir, target_shape, target_affine)
    if not jobs:
        return []

    workers = channel_worker_count(len(jobs))
    if workers > 1:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            results = list(executor.map(write_preview_channel, jobs))
    else:
        results = [write_preview_channel(item) for item in jobs]

    loaded = [channel for channel in results if channel is not None]
    loaded.sort(key=channel_sort_key)
    return loaded


def main() -> int:
    started = time.perf_counter()
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args()

    job_path = Path(args.job)
    job = load_job(job_path)
    work_dir = Path(job.get("workingDirectory") or job_path.parent)
    output_dir = work_dir / "input-channel-preview"
    manifest_path = work_dir / "input-channel-preview.json"
    channels = selected_preview_channels(job, output_dir)

    manifest = {
        "status": "ok",
        "schema": "com.horos.metal3d.tumor-input-preview.v1",
        "dimensions": [int(job["dimensions"][0]), int(job["dimensions"][1]), int(job["dimensions"][2])],
        "spacingMM": job.get("spacingMM") or [],
        "coordinateSystem": job.get("coordinateSystem") or "DICOM patient LPS mm",
        "channels": channels,
        "channelRegistration": [
            {
                "role": channel.get("role"),
                "mode": channel.get("mode"),
                "seriesDescription": channel.get("seriesDescription"),
                "seriesNumber": channel.get("seriesNumber"),
            }
            for channel in channels
        ],
        "elapsedSeconds": round(time.perf_counter() - started, 3),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": "ok", "manifest": str(manifest_path), "channels": len(channels)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"metal3d_tumor_segmentation_preview.py: {error}", file=sys.stderr)
        sys.exit(1)
