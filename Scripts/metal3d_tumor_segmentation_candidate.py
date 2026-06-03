#!/usr/bin/env python3
"""Local tumour-candidate segmentation for Horos Metal 3D.

This helper is intentionally local and deterministic. It is not a trained BraTS
model and is not diagnostic. It gives Horos a real segmentation-producing
backend while multimodal nnU-Net/MONAI integration is being prepared.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
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
            "/Users/ystarrev/Development/vtkbin/lib/python3.13/site-packages",
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
            "Could not import numpy/scipy/skimage even after switching to "
            f"{preferred_python}. Python executable: {sys.executable}"
        ) from error


ensure_scientific_python()

import numpy as np
from scipy import ndimage as ndi
from skimage import filters, measure

from metal3d_dicom_geometry import (
    affine_from_job,
    channel_worker_count,
    classify_series_role,
    load_dicom_series_registered,
)


def load_job(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_volume(job: dict) -> np.ndarray:
    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_count = int(job["expectedVoxelCount"])
    values = np.fromfile(job["inputVolume"], dtype="<f4", count=expected_count)
    if values.size != expected_count:
        raise RuntimeError(f"input voxel count mismatch: {values.size} != {expected_count}")
    volume = values.reshape((depth, height, width))
    volume = np.nan_to_num(volume, nan=0.0, posinf=0.0, neginf=0.0)
    return volume.astype(np.float32, copy=False)


def classify_role(series: dict) -> str:
    return classify_series_role(series)


def load_selected_modality_job(job_item: tuple[str, dict, list[str], tuple[int, int, int], np.ndarray]):
    role, series, paths, target_shape, target_affine = job_item
    resampled = load_dicom_series_registered(paths, target_shape, target_affine)
    if resampled is None:
        return None

    summary = dict(resampled.summary)
    summary["role"] = role
    summary["seriesDescription"] = series.get("seriesDescription") or series.get("localSeriesDescription") or ""
    summary["seriesNumber"] = series.get("seriesNumber") or ""
    return role, resampled.volume, summary


def selected_series_jobs(job: dict, target_shape: tuple[int, int, int], target_affine: np.ndarray) -> list[tuple[str, dict, list[str], tuple[int, int, int], np.ndarray]]:
    jobs = []
    role_counts: dict[str, int] = {}
    selected_series = job.get("selectedDICOMSeries") or []
    if not isinstance(selected_series, list):
        return jobs

    for series in selected_series:
        if not isinstance(series, dict):
            continue
        paths = series.get("localPaths") or []
        if not isinstance(paths, list) or not paths:
            continue
        role = classify_role(series)
        role_count = role_counts.get(role, 0)
        role_counts[role] = role_count + 1
        if role_count > 0:
            role = f"{role}_{role_count + 1}"
        jobs.append((role, series, [str(path) for path in paths], target_shape, target_affine))

    return jobs


def load_selected_modalities(job: dict) -> tuple[dict[str, np.ndarray], list[dict]]:
    depth, height, width = int(job["dimensions"][2]), int(job["dimensions"][1]), int(job["dimensions"][0])
    target_shape = (depth, height, width)
    target_affine = affine_from_job(job)
    modalities: dict[str, np.ndarray] = {}
    registration_summaries: list[dict] = []
    jobs = selected_series_jobs(job, target_shape, target_affine)
    if not jobs:
        return modalities, registration_summaries

    workers = channel_worker_count(len(jobs))
    if workers > 1:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            results = list(executor.map(load_selected_modality_job, jobs))
    else:
        results = [load_selected_modality_job(item) for item in jobs]

    for result in results:
        if result is None:
            continue
        role, volume, summary = result
        modalities[role] = volume
        registration_summaries.append(summary)

    return modalities, registration_summaries


def voxel_volume_ml(job: dict) -> float:
    spacing = [float(value) for value in job["spacingMM"]]
    return spacing[0] * spacing[1] * spacing[2] / 1000.0


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


def tumour_seed_count(job: dict) -> int:
    seeds = job.get("tumourSeeds") or job.get("tumorSeeds") or []
    return len(seeds) if isinstance(seeds, list) else 0


def seed_ball_mask(shape: tuple[int, int, int], seed_points: list[tuple[int, int, int]], job: dict, radius_mm: float) -> np.ndarray:
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


def seed_selection_radius_mm(job: dict) -> float:
    try:
        return max(float(job.get("tumourSeedSelectionRadiusMM", 60.0)), 2.5)
    except (TypeError, ValueError):
        return 60.0


def seed_guided_selection(candidate: np.ndarray, search_mask: np.ndarray, job: dict) -> tuple[np.ndarray | None, dict]:
    seed_points = tumour_seed_points(job, candidate.shape)
    summary = {
        "provided": int(tumour_seed_count(job)),
        "usable": int(len(seed_points)),
        "used": False,
        "mode": "none",
    }
    if not seed_points:
        return None, summary

    labels, count = ndi.label(candidate)
    if count > 0:
        seed_neighborhood = seed_ball_mask(candidate.shape, seed_points, job, radius_mm=8.0)
        touched_labels = np.unique(labels[seed_neighborhood & (labels > 0)])
        touched_labels = touched_labels[touched_labels > 0]
        if touched_labels.size:
            locality = seed_ball_mask(candidate.shape, seed_points, job, radius_mm=seed_selection_radius_mm(job))
            selected = np.isin(labels, touched_labels) & locality
            if not np.any(selected):
                selected = np.isin(labels, touched_labels)
            summary["used"] = True
            summary["mode"] = "candidate-components-touching-seeds-local"
            return selected, summary

    seed_region = seed_ball_mask(candidate.shape, seed_points, job, radius_mm=2.5)
    if np.any(seed_region):
        summary["used"] = True
        summary["mode"] = "seed-spheres-fallback"
        return seed_region, summary
    return None, summary


def largest_component(mask: np.ndarray) -> np.ndarray:
    labels, count = ndi.label(mask)
    if count == 0:
        return np.zeros(mask.shape, dtype=bool)
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    return labels == int(np.argmax(sizes))


def remove_small_components(mask: np.ndarray, minimum_size: int) -> np.ndarray:
    labels, count = ndi.label(mask)
    if count == 0:
        return np.zeros(mask.shape, dtype=bool)
    sizes = np.bincount(labels.ravel())
    keep = sizes >= minimum_size
    keep[0] = False
    return keep[labels]


def body_mask(volume: np.ndarray) -> np.ndarray:
    finite = np.isfinite(volume)
    values = volume[finite]
    if values.size == 0:
        return np.zeros(volume.shape, dtype=bool)

    p02, p98 = np.percentile(values, [2, 98])
    clipped = np.clip(volume, p02, p98)
    smooth = ndi.gaussian_filter(clipped, sigma=1.0)
    smooth_values = smooth[finite]
    try:
        threshold = filters.threshold_otsu(smooth_values)
    except ValueError:
        threshold = np.percentile(smooth_values, 20)

    low_percentile = np.percentile(smooth_values, 15)
    mask = finite & (smooth > min(threshold, low_percentile + 0.25 * (threshold - low_percentile)))
    mask = remove_small_components(mask, max(mask.size // 5000, 64))
    mask = ndi.binary_closing(mask, iterations=2)
    mask = ndi.binary_fill_holes(mask)
    mask = largest_component(mask)
    return ndi.binary_erosion(mask, iterations=1)


def intracranial_search_mask(mask: np.ndarray) -> np.ndarray:
    """Conservative inner-head mask to avoid skin, face, and sinus false positives."""
    if not np.any(mask):
        return mask

    distance = ndi.distance_transform_edt(mask)
    base_radius = max(5, min(14, int(round(min(mask.shape) / 12.0))))
    inner = mask & (distance >= base_radius)

    if np.count_nonzero(inner) < max(128, int(np.count_nonzero(mask) * 0.12)):
        inner = mask & (distance >= max(1, base_radius // 2))

    inner = largest_component(inner)
    if not np.any(inner):
        return mask

    slice_areas = np.count_nonzero(inner, axis=(1, 2))
    max_area = int(slice_areas.max()) if slice_areas.size else 0
    if max_area > 0:
        keep_slices = slice_areas >= max(16, int(max_area * 0.12))
        keep_slices = ndi.binary_closing(keep_slices, iterations=1)
        if np.any(keep_slices):
            slice_mask = keep_slices[:, None, None]
            inner &= slice_mask

    dilated = ndi.binary_dilation(inner, iterations=max(1, base_radius // 3)) & mask
    cleaned = remove_small_components(dilated, max(64, int(np.count_nonzero(mask) * 0.01)))
    if np.count_nonzero(cleaned) < max(128, int(np.count_nonzero(mask) * 0.08)):
        return dilated
    return cleaned


def robust_z(volume: np.ndarray, mask: np.ndarray) -> np.ndarray:
    values = volume[mask]
    if values.size < 32:
        return np.zeros(volume.shape, dtype=np.float32)

    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median)))
    scale = max(1.4826 * mad, float(np.std(values)) * 0.25, 1e-5)
    return ((volume - median) / scale).astype(np.float32)


def component_scores(candidate: np.ndarray, zmap: np.ndarray, voxel_ml: float) -> list[tuple[float, int, np.ndarray]]:
    labels = measure.label(candidate, connectivity=1)
    scored: list[tuple[float, int, np.ndarray]] = []
    minimum_voxels = max(int(round(0.05 / max(voxel_ml, 1e-6))), 12)
    maximum_voxels = max(int(candidate.size * 0.08), minimum_voxels + 1)

    for region in measure.regionprops(labels, intensity_image=zmap):
        if region.area < minimum_voxels or region.area > maximum_voxels:
            continue
        component = labels == region.label
        peak = float(np.max(zmap[component]))
        mean = float(np.mean(zmap[component]))
        score = peak + 0.15 * mean + 0.03 * np.sqrt(float(region.area))
        scored.append((score, int(region.area), component))

    scored.sort(key=lambda item: item[0], reverse=True)
    return scored


def multimodal_body_mask(modalities: dict[str, np.ndarray], fallback: np.ndarray) -> np.ndarray:
    masks = []
    for volume in modalities.values():
        masks.append(body_mask(volume))
    masks = [mask for mask in masks if np.any(mask)]
    if masks:
        combined = np.zeros(next(iter(modalities.values())).shape, dtype=bool)
        for mask in masks:
            combined |= mask
        combined = ndi.binary_closing(combined, iterations=2)
        combined = ndi.binary_fill_holes(combined)
        return intracranial_search_mask(largest_component(combined))
    return intracranial_search_mask(body_mask(fallback))


def first_modality(modalities: dict[str, np.ndarray], *roles: str) -> np.ndarray | None:
    for role in roles:
        if role in modalities:
            return modalities[role]
    for key, volume in modalities.items():
        if any(key.startswith(role) for role in roles):
            return volume
    return None


def segment_multimodal(displayed: np.ndarray, modalities: dict[str, np.ndarray], job: dict) -> tuple[np.ndarray, dict]:
    mask = multimodal_body_mask(modalities, displayed)
    if not np.any(mask):
        raise RuntimeError("could not estimate a foreground/body mask")

    flair = first_modality(modalities, "flair")
    t2 = first_modality(modalities, "t2")
    t1c = first_modality(modalities, "t1c")
    t1 = first_modality(modalities, "t1")

    edema_source = flair if flair is not None else t2 if t2 is not None else displayed
    core_source = t1c if t1c is not None else displayed
    t1_source = t1 if t1 is not None else displayed

    edema_z = robust_z(ndi.gaussian_filter(edema_source, sigma=1.0), mask)
    core_z = robust_z(ndi.gaussian_filter(core_source, sigma=1.0), mask)
    t1_z = robust_z(ndi.gaussian_filter(t1_source, sigma=1.0), mask)
    displayed_z = robust_z(ndi.gaussian_filter(displayed, sigma=1.0), mask)

    edema_values = edema_z[mask]
    core_values = core_z[mask]
    if edema_values.size < 32 or core_values.size < 32:
        return segment(displayed, job)

    edema_threshold = max(1.8, float(np.percentile(edema_values, 97.0)))
    core_threshold = max(2.0, float(np.percentile(core_values, 98.3)))
    hot_threshold = max(2.8, float(np.percentile(core_values, 99.2)))

    lesion_score = np.maximum(edema_z, displayed_z) + 0.55 * np.maximum(core_z, 0) - 0.20 * np.maximum(t1_z, 0)
    lesion_values = lesion_score[mask]
    lesion_threshold = max(2.0, float(np.percentile(lesion_values, 98.0)))

    edema_candidate = mask & ((edema_z >= edema_threshold) | (lesion_score >= lesion_threshold))
    core_candidate = mask & (core_z >= core_threshold)
    edema_candidate = ndi.binary_closing(remove_small_components(edema_candidate, 8), iterations=1)
    core_candidate = remove_small_components(core_candidate, 4)

    whole = ndi.binary_dilation(core_candidate, iterations=2) | edema_candidate
    whole = ndi.binary_closing(whole & mask, iterations=2)

    score_image = lesion_score + 0.35 * np.maximum(core_z, 0)
    scored = component_scores(whole, score_image, voxel_volume_ml(job))
    labels = np.zeros(displayed.shape, dtype=np.uint8)
    seed_summary = None
    if scored:
        selected, seed_summary = seed_guided_selection(whole, mask, job)
        if selected is None:
            selected = np.zeros(displayed.shape, dtype=bool)
            for _, _, component in scored[:4]:
                selected |= component
    else:
        selected, seed_summary = seed_guided_selection(whole, mask, job)

    if selected is not None and np.any(selected):
        edema = selected
        enhancing = selected & (core_z >= hot_threshold)
        enhancing = remove_small_components(enhancing, 4)
        core = selected & (core_candidate | enhancing)
        non_enhancing = core & ~enhancing

        labels[edema] = 2
        labels[non_enhancing] = 1
        labels[enhancing] = 4

    counts = {str(label): int(np.sum(labels == label)) for label in (1, 2, 4) if np.any(labels == label)}
    result = {
        "status": "ok",
        "backend": "local-multimodal-candidate",
        "modalitiesUsed": sorted(modalities.keys()),
        "labels": {
            "0": "background",
            "1": "candidate tumour core",
            "2": "candidate edema/whole tumour",
            "4": "candidate enhancing tumour",
        },
        "labelVoxelCounts": counts,
        "thresholds": {
            "edemaZ": edema_threshold,
            "coreZ": core_threshold,
            "hotZ": hot_threshold,
            "lesionScore": lesion_threshold,
        },
        "searchMask": {
            "type": "intracranial-eroded-head",
            "voxelCount": int(np.count_nonzero(mask)),
        },
        "tumourSeedGuidance": seed_summary or seed_guided_selection(whole, mask, job)[1],
        "message": (
            "Local multimodal candidate segmentation using selected DICOM series. "
            "This is still heuristic and not diagnostic; it is the local plumbing "
            "needed before replacing the heuristic with a trained tumour model."
        ),
    }
    return labels, result


def segment(volume: np.ndarray, job: dict) -> tuple[np.ndarray, dict]:
    mask = intracranial_search_mask(body_mask(volume))
    if not np.any(mask):
        raise RuntimeError("could not estimate a foreground/body mask")

    smooth = ndi.gaussian_filter(volume, sigma=1.0)
    zmap = robust_z(smooth, mask)
    body_values = zmap[mask]

    high_threshold = max(2.5, float(np.percentile(body_values, 98.5)))
    moderate_threshold = max(1.4, float(np.percentile(body_values, 94.0)))
    hot_threshold = max(3.25, float(np.percentile(body_values, 99.5)))

    high = mask & (zmap >= high_threshold)
    high = remove_small_components(high, 8)
    grown = ndi.binary_dilation(high, iterations=2) & mask & (zmap >= moderate_threshold)
    grown = ndi.binary_closing(grown, iterations=1)

    selection_candidate = grown
    scored = component_scores(selection_candidate, zmap, voxel_volume_ml(job))
    if not scored:
        fallback_threshold = max(2.0, float(np.percentile(body_values, 99.0)))
        selection_candidate = mask & (zmap >= fallback_threshold)
        scored = component_scores(selection_candidate, zmap, voxel_volume_ml(job))

    labels = np.zeros(volume.shape, dtype=np.uint8)
    seed_summary = None
    if scored:
        selected, seed_summary = seed_guided_selection(selection_candidate, mask, job)
        if selected is None:
            selected = np.zeros(volume.shape, dtype=bool)
            for _, _, component in scored[:3]:
                selected |= component
    else:
        selected, seed_summary = seed_guided_selection(selection_candidate, mask, job)

    if selected is not None and np.any(selected):
        edema = selected
        enhancing = selected & (zmap >= hot_threshold)
        enhancing = remove_small_components(enhancing, 4)
        non_enhancing = selected & ~enhancing & (zmap >= high_threshold)

        labels[edema] = 2
        labels[non_enhancing] = 1
        labels[enhancing] = 4

    counts = {str(label): int(np.sum(labels == label)) for label in (1, 2, 4) if np.any(labels == label)}
    result = {
        "status": "ok",
        "backend": "single-volume-candidate",
        "labels": {
            "0": "background",
            "1": "non-enhancing high-intensity candidate",
            "2": "moderate-intensity candidate surround",
            "4": "hottest candidate core",
        },
        "labelVoxelCounts": counts,
        "thresholds": {
            "moderateZ": moderate_threshold,
            "highZ": high_threshold,
            "hotZ": hot_threshold,
        },
        "searchMask": {
            "type": "intracranial-eroded-head",
            "voxelCount": int(np.count_nonzero(mask)),
        },
        "tumourSeedGuidance": seed_summary or seed_guided_selection(selection_candidate, mask, job)[1],
        "message": (
            "Single-volume local candidate segmentation. This is not diagnostic; "
            "use it as a local pipeline and visualization test until a trained "
            "multimodal tumour model is configured."
        ),
    }
    return labels, result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args()

    job = load_job(Path(args.job))
    displayed = load_volume(job)
    modalities, registration_summaries = load_selected_modalities(job)
    if len(modalities) >= 2:
        labels, result = segment_multimodal(displayed, modalities, job)
    else:
        labels, result = segment(displayed, job)
        if modalities:
            result["modalitiesLoadedButNotUsed"] = sorted(modalities.keys())
    if registration_summaries:
        result["channelRegistration"] = registration_summaries

    output_path = Path(job["outputLabelmap"])
    output_path.write_bytes(labels.reshape(-1).tobytes())

    result["outputLabelmap"] = str(output_path)
    result_path = job.get("resultJSON")
    if result_path:
        Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"metal3d_tumor_segmentation_candidate.py: {error}", file=sys.stderr)
        sys.exit(1)
