"""DICOM geometry helpers for Horos Metal 3D tumour segmentation."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

import numpy as np
import pydicom

try:
    from scipy import ndimage as scipy_ndimage
except Exception:  # pragma: no cover - optional acceleration path
    scipy_ndimage = None


@dataclass
class ResampledSeries:
    volume: np.ndarray
    summary: dict[str, Any]


def channel_worker_count(series_count: int) -> int:
    if series_count <= 1:
        return 1

    explicit = os.environ.get("HOROS_TUMOR_SEGMENTATION_CHANNEL_WORKERS")
    if explicit:
        try:
            return max(1, min(int(explicit), series_count))
        except ValueError:
            pass

    cpu_count = os.cpu_count() or 1
    return max(1, min(series_count, cpu_count, 4))


def normalize_role(role: str) -> str:
    role = role.lower().strip()
    if role in ("t1ce", "t1gd", "t1-gd", "t1 post", "t1 postcontrast"):
        return "t1c"
    return role


def classify_series_role(series: dict) -> str:
    role = str(series.get("suggestedRole") or series.get("role") or "").strip().lower()
    if role:
        return normalize_role(role)

    text = " ".join(
        str(series.get(key) or "")
        for key in ("seriesDescription", "localSeriesDescription", "seriesNumber")
    ).lower().replace("_", " ").replace("-", " ")

    if "flair" in text or "fluid attenuated" in text:
        return "flair"
    if "t2" in text and not any(token in text for token in ("flair", "dwi", "diff", "adc", "localizer", "scout")):
        return "t2"
    if any(token in text for token in ("t1", "mprage", "spgr", "bravo", "ir fspgr")):
        if any(token in text for token in ("post", "gad", "gadavist", "contrast", "ce", "+c", "c+", "t1c", "t1ce", "gd")):
            return "t1c"
        return "t1"
    return "selected"


def target_shape_from_job(job: dict) -> tuple[int, int, int]:
    width, height, depth = [int(value) for value in job["dimensions"]]
    return depth, height, width


def affine_from_job(job: dict) -> np.ndarray:
    matrix = job.get("referenceVoxelToPatientMatrix") or job.get("voxelToPatientMatrix")
    if isinstance(matrix, list):
        affine = np.asarray(matrix, dtype=np.float64)
        if affine.shape == (4, 4) and np.isfinite(affine).all():
            return affine

    spacing = [float(value) for value in job["spacingMM"]]
    return np.diag([spacing[0], spacing[1], spacing[2], 1.0]).astype(np.float64)


def nifti_affine_from_job(job: dict) -> np.ndarray:
    # DICOM patient coordinates are LPS. NIfTI tools conventionally consume RAS.
    lps_to_ras = np.diag([-1.0, -1.0, 1.0, 1.0])
    return lps_to_ras @ affine_from_job(job)


def _safe_float_sequence(value: Any, expected_count: int) -> list[float] | None:
    if value is None:
        return None
    try:
        value_count = len(value)
    except TypeError:
        return None
    if value_count < expected_count:
        return None
    try:
        return [float(value[index]) for index in range(expected_count)]
    except (TypeError, ValueError):
        return None


def _dataset_position(dataset: Any) -> np.ndarray | None:
    values = _safe_float_sequence(getattr(dataset, "ImagePositionPatient", None), 3)
    return np.asarray(values, dtype=np.float64) if values is not None else None


def _dataset_orientation(dataset: Any) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    values = _safe_float_sequence(getattr(dataset, "ImageOrientationPatient", None), 6)
    if values is None:
        return None

    row = np.asarray(values[:3], dtype=np.float64)
    column = np.asarray(values[3:], dtype=np.float64)
    row_norm = np.linalg.norm(row)
    column_norm = np.linalg.norm(column)
    if row_norm <= 1e-8 or column_norm <= 1e-8:
        return None

    row = row / row_norm
    column = column / column_norm
    normal = np.cross(row, column)
    normal_norm = np.linalg.norm(normal)
    if normal_norm <= 1e-8:
        return None
    return row, column, normal / normal_norm


def _dataset_spacing(dataset: Any) -> tuple[float, float]:
    values = _safe_float_sequence(getattr(dataset, "PixelSpacing", None), 2)
    if values is None:
        return 1.0, 1.0

    row_spacing = max(abs(values[0]), 1e-6)
    column_spacing = max(abs(values[1]), 1e-6)
    return row_spacing, column_spacing


def _slice_sort_key(dataset: Any, normal: np.ndarray) -> tuple[int, float | str]:
    position = _dataset_position(dataset)
    if position is not None:
        return 0, float(np.dot(position, normal))

    try:
        return 1, float(getattr(dataset, "InstanceNumber"))
    except (TypeError, ValueError):
        return 2, str(getattr(dataset, "SOPInstanceUID", ""))


def _load_dicom_datasets(paths: list[str]) -> list[Any]:
    datasets = []
    for path in paths:
        try:
            dataset = pydicom.dcmread(path, force=True)
            if hasattr(dataset, "PixelData"):
                datasets.append(dataset)
        except Exception:
            continue
    return datasets


def _source_volume_and_affine(paths: list[str]) -> tuple[np.ndarray, np.ndarray, dict[str, Any]] | None:
    datasets = _load_dicom_datasets(paths)
    if len(datasets) < 2:
        return None

    orientation = _dataset_orientation(datasets[0])
    first_position = _dataset_position(datasets[0])
    if orientation is None or first_position is None:
        return None

    row, column, normal = orientation
    datasets.sort(key=lambda dataset: _slice_sort_key(dataset, normal))
    rows = []
    row_positions = []
    expected_shape = None
    for dataset in datasets:
        try:
            pixels = dataset.pixel_array.astype(np.float32)
        except Exception:
            continue
        if pixels.ndim == 3:
            pixels = pixels[0]
        if pixels.ndim != 2:
            continue
        if expected_shape is None:
            expected_shape = pixels.shape
        if pixels.shape != expected_shape:
            continue

        position = _dataset_position(dataset)
        if position is None:
            continue

        slope = float(getattr(dataset, "RescaleSlope", 1.0) or 1.0)
        intercept = float(getattr(dataset, "RescaleIntercept", 0.0) or 0.0)
        rows.append(pixels * slope + intercept)
        row_positions.append(position)

    if len(rows) < 2 or len(row_positions) < 2:
        return None

    volume = np.stack(rows, axis=0)
    volume = np.nan_to_num(volume, nan=0.0, posinf=0.0, neginf=0.0).astype(np.float32, copy=False)

    row_spacing, column_spacing = _dataset_spacing(datasets[0])
    origin = row_positions[0]
    slice_step = (row_positions[-1] - row_positions[0]) / max(len(row_positions) - 1, 1)

    if np.linalg.norm(slice_step) <= 1e-8:
        slice_step = normal

    affine = np.eye(4, dtype=np.float64)
    affine[:3, 0] = row * column_spacing
    affine[:3, 1] = column * row_spacing
    affine[:3, 2] = slice_step
    affine[:3, 3] = origin

    summary = {
        "sourceSlices": int(volume.shape[0]),
        "sourceRows": int(volume.shape[1]),
        "sourceColumns": int(volume.shape[2]),
        "sourceSpacingMM": [
            float(np.linalg.norm(affine[:3, 0])),
            float(np.linalg.norm(affine[:3, 1])),
            float(np.linalg.norm(affine[:3, 2])),
        ],
        "mode": "dicom-patient-geometry",
    }
    return volume, affine, summary


def _target_source_slice_mapping(
    source_affine: np.ndarray,
    target_affine: np.ndarray,
    target_shape: tuple[int, int, int],
) -> list[float | None]:
    depth, height, width = target_shape
    if depth < 1:
        return []

    inverse_source = np.linalg.inv(source_affine)
    target_voxels = np.vstack([
        np.full(depth, (width - 1) * 0.5, dtype=np.float64),
        np.full(depth, (height - 1) * 0.5, dtype=np.float64),
        np.arange(depth, dtype=np.float64),
        np.ones(depth, dtype=np.float64),
    ])
    source_voxels = inverse_source @ (target_affine @ target_voxels)
    return [float(value) if np.isfinite(value) else None for value in source_voxels[2]]


def _fallback_slice_mapping(source_depth: int, target_depth: int) -> list[float]:
    if target_depth <= 1:
        return [0.0]
    scale = float(max(source_depth - 1, 0)) / float(max(target_depth - 1, 1))
    return [float(index) * scale for index in range(target_depth)]


def _resize_fallback(
    paths: list[str],
    target_shape: tuple[int, int, int],
    include_slice_mapping: bool,
):
    from skimage import transform

    datasets = _load_dicom_datasets(paths)
    slices = []
    for dataset in datasets:
        try:
            pixels = dataset.pixel_array.astype(np.float32)
            if pixels.ndim == 3:
                pixels = pixels[0]
            if pixels.ndim != 2:
                continue
            slope = float(getattr(dataset, "RescaleSlope", 1.0) or 1.0)
            intercept = float(getattr(dataset, "RescaleIntercept", 0.0) or 0.0)
            slices.append((_slice_sort_key(dataset, np.asarray([0.0, 0.0, 1.0])), pixels * slope + intercept))
        except Exception:
            continue

    if len(slices) < 2:
        return None

    slices.sort(key=lambda item: item[0])
    volume = np.stack([item[1] for item in slices], axis=0)
    volume = np.nan_to_num(volume, nan=0.0, posinf=0.0, neginf=0.0).astype(np.float32, copy=False)
    source_shape = volume.shape
    if volume.shape != target_shape:
        volume = transform.resize(
            volume,
            target_shape,
            order=1,
            mode="edge",
            preserve_range=True,
            anti_aliasing=True,
        ).astype(np.float32, copy=False)
    summary = {
        "mode": "shape-resize-fallback",
        "sourceSlices": int(source_shape[0]),
        "sourceRows": int(source_shape[1]),
        "sourceColumns": int(source_shape[2]),
        "reason": "missing-or-invalid-dicom-patient-geometry",
    }
    if include_slice_mapping:
        summary["sourceSliceByTargetSlice"] = _fallback_slice_mapping(source_shape[0], target_shape[0])
    return ResampledSeries(volume=volume, summary=summary)


def _trilinear_sample(volume: np.ndarray, source_xyz: np.ndarray) -> np.ndarray:
    depth, height, width = volume.shape
    x = source_xyz[0]
    y = source_xyz[1]
    z = source_xyz[2]
    valid = (x >= 0.0) & (x <= width - 1) & (y >= 0.0) & (y <= height - 1) & (z >= 0.0) & (z <= depth - 1)

    x0 = np.floor(np.clip(x, 0, width - 1)).astype(np.int64)
    y0 = np.floor(np.clip(y, 0, height - 1)).astype(np.int64)
    z0 = np.floor(np.clip(z, 0, depth - 1)).astype(np.int64)
    x1 = np.minimum(x0 + 1, width - 1)
    y1 = np.minimum(y0 + 1, height - 1)
    z1 = np.minimum(z0 + 1, depth - 1)

    xd = (x - x0).astype(np.float32)
    yd = (y - y0).astype(np.float32)
    zd = (z - z0).astype(np.float32)

    c000 = volume[z0, y0, x0]
    c100 = volume[z0, y0, x1]
    c010 = volume[z0, y1, x0]
    c110 = volume[z0, y1, x1]
    c001 = volume[z1, y0, x0]
    c101 = volume[z1, y0, x1]
    c011 = volume[z1, y1, x0]
    c111 = volume[z1, y1, x1]

    c00 = c000 * (1.0 - xd) + c100 * xd
    c10 = c010 * (1.0 - xd) + c110 * xd
    c01 = c001 * (1.0 - xd) + c101 * xd
    c11 = c011 * (1.0 - xd) + c111 * xd
    c0 = c00 * (1.0 - yd) + c10 * yd
    c1 = c01 * (1.0 - yd) + c11 * yd
    sampled = c0 * (1.0 - zd) + c1 * zd
    return np.where(valid, sampled, 0.0).astype(np.float32, copy=False)


def resample_volume_to_target(
    source_volume: np.ndarray,
    source_affine: np.ndarray,
    target_shape: tuple[int, int, int],
    target_affine: np.ndarray,
) -> np.ndarray:
    inverse_source = np.linalg.inv(source_affine)
    target_to_source = inverse_source @ target_affine
    if scipy_ndimage is not None:
        matrix = np.asarray([
            [target_to_source[2, 2], target_to_source[2, 1], target_to_source[2, 0]],
            [target_to_source[1, 2], target_to_source[1, 1], target_to_source[1, 0]],
            [target_to_source[0, 2], target_to_source[0, 1], target_to_source[0, 0]],
        ], dtype=np.float64)
        offset = np.asarray([
            target_to_source[2, 3],
            target_to_source[1, 3],
            target_to_source[0, 3],
        ], dtype=np.float64)
        return scipy_ndimage.affine_transform(
            source_volume,
            matrix,
            offset=offset,
            output_shape=target_shape,
            order=1,
            mode="constant",
            cval=0.0,
            prefilter=False,
        ).astype(np.float32, copy=False)

    depth, height, width = target_shape
    output = np.zeros(target_shape, dtype=np.float32)
    block_depth = 8

    for z0 in range(0, depth, block_depth):
        z1 = min(z0 + block_depth, depth)
        zz, yy, xx = np.mgrid[z0:z1, 0:height, 0:width]
        ones = np.ones(xx.size, dtype=np.float64)
        target_voxels = np.vstack([
            xx.reshape(-1).astype(np.float64),
            yy.reshape(-1).astype(np.float64),
            zz.reshape(-1).astype(np.float64),
            ones,
        ])
        source_voxels = target_to_source @ target_voxels
        sampled = _trilinear_sample(source_volume, source_voxels[:3])

        output[z0:z1, :, :] = sampled.reshape((z1 - z0, height, width))

    return output


def load_dicom_series_registered(
    paths: list[str],
    target_shape: tuple[int, int, int],
    target_affine: np.ndarray,
    include_slice_mapping: bool = False,
) -> ResampledSeries | None:
    source = _source_volume_and_affine(paths)
    if source is None:
        return _resize_fallback(paths, target_shape, include_slice_mapping)

    source_volume, source_affine, summary = source
    registered = resample_volume_to_target(source_volume, source_affine, target_shape, target_affine)
    summary["targetSlices"] = int(target_shape[0])
    summary["targetRows"] = int(target_shape[1])
    summary["targetColumns"] = int(target_shape[2])
    if include_slice_mapping:
        summary["sourceSliceByTargetSlice"] = _target_source_slice_mapping(source_affine, target_affine, target_shape)
    return ResampledSeries(volume=registered, summary=summary)
