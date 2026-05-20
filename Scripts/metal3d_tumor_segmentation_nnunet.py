#!/usr/bin/env python3
"""Local nnU-Net tumour segmentation helper for Horos Metal 3D.

This helper keeps all data local. It converts the checked local DICOM series
from the Horos job into nnU-Net channel files, runs a local trained model folder,
and converts the predicted NIfTI labelmap back to Horos' UInt8 raw labelmap.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
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


ensure_scientific_python()

import nibabel as nib
import numpy as np
import pydicom
from skimage import measure, transform


DEFAULT_CHANNEL_ORDER = ["flair", "t1", "t1c", "t2"]


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_config() -> dict:
    config_path = Path.home() / ".horos_metal3d_tumor_segmentation.json"
    if config_path.exists():
        return load_json(config_path)
    return {}


def configured_model_folder(config: dict) -> Path:
    path = (
        os.environ.get("HOROS_TUMOR_NNUNET_MODEL_FOLDER")
        or config.get("nnunet_model_folder")
        or config.get("model_folder")
        or ""
    )
    if not str(path).strip():
        raise RuntimeError(
            "No local nnU-Net model folder configured. Set HOROS_TUMOR_NNUNET_MODEL_FOLDER "
            "or add nnunet_model_folder to ~/.horos_metal3d_tumor_segmentation.json."
        )
    folder = Path(path).expanduser()
    if not folder.exists():
        raise RuntimeError(f"Configured nnU-Net model folder does not exist: {folder}")
    return folder


def configured_channel_order(config: dict) -> list[str]:
    value = os.environ.get("HOROS_TUMOR_NNUNET_CHANNELS") or config.get("nnunet_channels")
    if isinstance(value, str) and value.strip():
        return [item.strip().lower() for item in value.split(",") if item.strip()]
    if isinstance(value, list) and value:
        return [str(item).strip().lower() for item in value if str(item).strip()]
    return DEFAULT_CHANNEL_ORDER


def classify_role(series: dict) -> str:
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


def normalize_role(role: str) -> str:
    role = role.lower().strip()
    if role in ("t1ce", "t1gd", "t1-gd", "t1 post", "t1 postcontrast"):
        return "t1c"
    return role


def dicom_sort_key(dataset) -> tuple:
    image_position = getattr(dataset, "ImagePositionPatient", None)
    if image_position is not None and len(image_position) >= 3:
        try:
            return (0, float(image_position[2]))
        except (TypeError, ValueError):
            pass

    instance_number = getattr(dataset, "InstanceNumber", None)
    try:
        return (1, int(instance_number))
    except (TypeError, ValueError):
        return (2, str(getattr(dataset, "SOPInstanceUID", "")))


def load_displayed_volume(job: dict) -> np.ndarray:
    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_count = int(job["expectedVoxelCount"])
    values = np.fromfile(job["inputVolume"], dtype="<f4", count=expected_count)
    if values.size != expected_count:
        raise RuntimeError(f"input voxel count mismatch: {values.size} != {expected_count}")
    return values.reshape((depth, height, width)).astype(np.float32, copy=False)


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


def seed_selection_radius_mm(job: dict) -> float:
    try:
        return max(float(job.get("tumourSeedSelectionRadiusMM", 60.0)), 2.5)
    except (TypeError, ValueError):
        return 60.0


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


def seed_mask_volume(job: dict, shape: tuple[int, int, int]) -> tuple[np.ndarray, int]:
    seed_points = tumour_seed_points(job, shape)
    mask = seed_ball_mask(shape, seed_points, job, radius_mm=2.5).astype(np.float32)
    return mask, len(seed_points)


def constrain_labels_to_tumour_seeds(labels: np.ndarray, job: dict) -> tuple[np.ndarray, dict]:
    seed_points = tumour_seed_points(job, labels.shape)
    summary = {
        "provided": int(tumour_seed_count(job)),
        "usable": int(len(seed_points)),
        "used": False,
        "mode": "none",
    }
    if not seed_points:
        return labels, summary

    foreground = labels > 0
    seed_neighborhood = seed_ball_mask(labels.shape, seed_points, job, radius_mm=8.0)
    components = measure.label(foreground, connectivity=1)
    touched_components = np.unique(components[seed_neighborhood & (components > 0)])
    touched_components = touched_components[touched_components > 0]
    if touched_components.size:
        locality = seed_ball_mask(labels.shape, seed_points, job, radius_mm=seed_selection_radius_mm(job))
        keep = np.isin(components, touched_components) & locality
        if not np.any(keep):
            keep = np.isin(components, touched_components)
        constrained = np.where(keep, labels, 0).astype(np.uint8, copy=False)
        summary["used"] = True
        summary["mode"] = "label-components-touching-seeds-local"
        return constrained, summary

    seed_region = seed_ball_mask(labels.shape, seed_points, job, radius_mm=2.5)
    constrained = np.zeros_like(labels, dtype=np.uint8)
    constrained[seed_region] = 1
    summary["used"] = True
    summary["mode"] = "seed-spheres-fallback"
    return constrained, summary


def load_dicom_series(paths: list[str], target_shape: tuple[int, int, int]) -> np.ndarray | None:
    slices = []
    for path in paths:
        try:
            dataset = pydicom.dcmread(path, force=True)
            if not hasattr(dataset, "PixelData"):
                continue
            pixels = dataset.pixel_array.astype(np.float32)
            if pixels.ndim == 3:
                pixels = pixels[0]
            slope = float(getattr(dataset, "RescaleSlope", 1.0) or 1.0)
            intercept = float(getattr(dataset, "RescaleIntercept", 0.0) or 0.0)
            slices.append((dicom_sort_key(dataset), pixels * slope + intercept))
        except Exception:
            continue

    if len(slices) < 2:
        return None

    slices.sort(key=lambda item: item[0])
    volume = np.stack([item[1] for item in slices], axis=0)
    volume = np.nan_to_num(volume, nan=0.0, posinf=0.0, neginf=0.0).astype(np.float32, copy=False)
    if volume.shape != target_shape:
        volume = transform.resize(
            volume,
            target_shape,
            order=1,
            mode="edge",
            preserve_range=True,
            anti_aliasing=True,
        ).astype(np.float32, copy=False)
    return volume


def selected_modalities(job: dict, displayed: np.ndarray) -> dict[str, np.ndarray]:
    modalities: dict[str, np.ndarray] = {}
    target_shape = displayed.shape
    selected_series = job.get("selectedDICOMSeries") or []
    if not isinstance(selected_series, list):
        return modalities

    for series in selected_series:
        if not isinstance(series, dict):
            continue
        paths = series.get("localPaths") or []
        if not isinstance(paths, list) or not paths:
            continue
        role = classify_role(series)
        if role in modalities:
            continue
        volume = load_dicom_series([str(path) for path in paths], target_shape)
        if volume is not None:
            modalities[role] = volume
    return modalities


def write_nnunet_inputs(job: dict, modalities: dict[str, np.ndarray], input_dir: Path, channel_order: list[str]) -> list[str]:
    input_dir.mkdir(parents=True, exist_ok=True)
    spacing = [float(value) for value in job["spacingMM"]]
    affine = np.diag([spacing[0], spacing[1], spacing[2], 1.0])

    missing = [role for role in channel_order if role not in modalities]
    if missing:
        raise RuntimeError(
            "Selected local series did not provide required nnU-Net channels: "
            + ", ".join(missing)
            + ". Expected channels: "
            + ", ".join(channel_order)
        )

    written_roles = []
    for index, role in enumerate(channel_order):
        volume = modalities[role]
        image = volume.transpose(2, 1, 0)
        nib.save(nib.Nifti1Image(image.astype(np.float32), affine), str(input_dir / f"horos_{index:04d}.nii.gz"))
        written_roles.append(role)
    return written_roles


def nnunet_device(config: dict) -> str:
    explicit = os.environ.get("HOROS_TUMOR_NNUNET_DEVICE") or config.get("nnunet_device")
    if explicit:
        return str(explicit)
    try:
        import torch
        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def apply_nnunet_runtime_environment(work_dir: Path) -> None:
    os.environ.update({
        "KMP_DUPLICATE_LIB_OK": "TRUE",
        "KMP_INIT_AT_FORK": "FALSE",
        "KMP_WARNINGS": "FALSE",
        "OMP_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1",
        "NUMEXPR_NUM_THREADS": "1",
        "PYTORCH_ENABLE_MPS_FALLBACK": "1",
        "MPLCONFIGDIR": str(work_dir / "matplotlib-cache"),
    })


def nnunet_folds(config: dict) -> list[str]:
    folds = os.environ.get("HOROS_TUMOR_NNUNET_FOLDS") or config.get("nnunet_folds") or "0"
    if isinstance(folds, list):
        return [str(fold) for fold in folds]
    return [item for item in str(folds).replace(",", " ").split() if item]


def torch_device_for_nnunet(config: dict):
    import torch

    device_name = nnunet_device(config).lower()
    torch.set_num_threads(max(1, int(config.get("torch_threads", 1))))
    if device_name == "cuda" and torch.cuda.is_available():
        return torch.device("cuda")
    if device_name == "mps" and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def sync_torch_device(torch_module, device) -> None:
    try:
        if device.type == "cuda":
            torch_module.cuda.synchronize()
        elif device.type == "mps" and hasattr(torch_module, "mps"):
            torch_module.mps.synchronize()
    except Exception:
        pass


def elapsed_since(start: float) -> float:
    return round(time.perf_counter() - start, 3)


def run_nnunet(config: dict, model_folder: Path, input_dir: Path, output_dir: Path, channel_order: list[str]) -> tuple[Path, dict[str, float | str]]:
    timings: dict[str, float | str] = {}
    phase_start = time.perf_counter()
    output_dir.mkdir(parents=True, exist_ok=True)
    work_dir = input_dir.parent
    apply_nnunet_runtime_environment(work_dir)

    import torch
    from nnunetv2.inference.export_prediction import export_prediction_from_logits
    from nnunetv2.inference.predict_from_raw_data import nnUNetPredictor

    fold_args = nnunet_folds(config)
    checkpoint = os.environ.get("HOROS_TUMOR_NNUNET_CHECKPOINT") or config.get("nnunet_checkpoint") or "checkpoint_final.pth"
    requested_device = nnunet_device(config).lower()
    device = torch_device_for_nnunet(config)
    timings["setupSeconds"] = elapsed_since(phase_start)
    timings["requestedDevice"] = requested_device
    timings["device"] = device.type
    if requested_device != device.type:
        timings["deviceFallback"] = f"requested {requested_device}, using {device.type}"

    phase_start = time.perf_counter()
    predictor = nnUNetPredictor(
        tile_step_size=float(config.get("nnunet_step_size", 0.5)),
        use_gaussian=True,
        use_mirroring=not bool(config.get("nnunet_disable_tta", True)),
        perform_everything_on_device=(device.type == "cuda"),
        device=device,
        verbose=bool(config.get("nnunet_verbose", False)),
        verbose_preprocessing=bool(config.get("nnunet_verbose", False)),
        allow_tqdm=False,
    )
    predictor.initialize_from_trained_model_folder(str(model_folder), fold_args, checkpoint_name=str(checkpoint))
    timings["modelInitializationSeconds"] = elapsed_since(phase_start)

    case_files = [str(input_dir / f"horos_{index:04d}.nii.gz") for index in range(len(channel_order))]
    missing = [path for path in case_files if not Path(path).exists()]
    if missing:
        raise RuntimeError("Missing nnU-Net channel files: " + ", ".join(missing))

    preprocessor = predictor.configuration_manager.preprocessor_class(verbose=predictor.verbose_preprocessing)
    phase_start = time.perf_counter()
    data, _, data_properties = preprocessor.run_case(
        case_files,
        None,
        predictor.plans_manager,
        predictor.configuration_manager,
        predictor.dataset_json,
    )
    timings["preprocessSeconds"] = elapsed_since(phase_start)

    phase_start = time.perf_counter()
    prediction_logits = predictor.predict_logits_from_preprocessed_data(torch.from_numpy(data)).cpu()
    sync_torch_device(torch, device)
    timings["inferenceSeconds"] = elapsed_since(phase_start)

    phase_start = time.perf_counter()
    export_prediction_from_logits(
        prediction_logits,
        data_properties,
        predictor.configuration_manager,
        predictor.plans_manager,
        predictor.dataset_json,
        str(output_dir / "horos"),
        save_probabilities=False,
        num_threads_torch=max(1, int(config.get("nnunet_export_threads", 1))),
    )
    timings["exportSeconds"] = elapsed_since(phase_start)
    prediction = output_dir / "horos.nii.gz"
    if not prediction.exists():
        candidates = sorted(output_dir.glob("*.nii.gz"))
        if not candidates:
            raise RuntimeError(f"nnU-Net completed but wrote no NIfTI predictions in {output_dir}")
        prediction = candidates[0]
    return prediction, timings


def convert_prediction_to_horos(job: dict, prediction_path: Path, output_raw: Path) -> tuple[dict[str, int], dict]:
    width, height, depth = [int(value) for value in job["dimensions"]]
    expected_shape = (width, height, depth)
    data = np.asarray(nib.load(str(prediction_path)).get_fdata(), dtype=np.float32)
    if tuple(data.shape[:3]) != expected_shape:
        data = transform.resize(
            data,
            expected_shape,
            order=0,
            mode="edge",
            preserve_range=True,
            anti_aliasing=False,
        )

    labels = np.rint(data).clip(0, 255).astype(np.uint8)
    labels[labels == 3] = 4
    labels_zyx, seed_guidance = constrain_labels_to_tumour_seeds(labels.transpose(2, 1, 0), job)
    labels = labels_zyx.transpose(2, 1, 0)
    raw = labels_zyx.reshape(int(job["expectedVoxelCount"]))
    output_raw.write_bytes(raw.tobytes())

    counts: dict[str, int] = {}
    for value in np.unique(labels):
        value = int(value)
        if value == 0:
            continue
        counts[str(value)] = int(np.sum(labels == value))
    return counts, seed_guidance


def main() -> int:
    total_start = time.perf_counter()
    timings: dict[str, float | str] = {}
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args()

    phase_start = time.perf_counter()
    job_path = Path(args.job)
    job = load_json(job_path)
    work_dir = Path(job.get("workingDirectory") or job_path.parent)
    config = load_config()
    model_folder = configured_model_folder(config)
    timings["configurationSeconds"] = elapsed_since(phase_start)

    phase_start = time.perf_counter()
    displayed = load_displayed_volume(job)
    timings["displayedVolumeLoadSeconds"] = elapsed_since(phase_start)

    phase_start = time.perf_counter()
    modalities = selected_modalities(job, displayed)
    seed_mask, usable_seed_count = seed_mask_volume(job, displayed.shape)
    if usable_seed_count > 0:
        modalities["seed"] = seed_mask
        modalities["tumourseed"] = seed_mask
        modalities["tumorseed"] = seed_mask
    timings["dicomSeriesLoadSeconds"] = elapsed_since(phase_start)

    channel_order = configured_channel_order(config)
    input_dir = work_dir / "nnunet-input"
    output_dir = work_dir / "nnunet-output"

    phase_start = time.perf_counter()
    written_roles = write_nnunet_inputs(job, modalities, input_dir, channel_order)
    timings["nnunetInputWriteSeconds"] = elapsed_since(phase_start)

    prediction, nnunet_timings = run_nnunet(config, model_folder, input_dir, output_dir, channel_order)
    timings["nnunet"] = nnunet_timings

    output_raw = Path(job["outputLabelmap"])
    result_path = Path(job.get("resultJSON") or (work_dir / "result.json"))
    phase_start = time.perf_counter()
    counts, output_seed_guidance = convert_prediction_to_horos(job, prediction, output_raw)
    timings["horosLabelmapWriteSeconds"] = elapsed_since(phase_start)
    timings["totalSeconds"] = elapsed_since(total_start)

    seed_channel_used = any(role in written_roles for role in ("seed", "tumourseed", "tumorseed"))
    seed_mode = output_seed_guidance.get("mode", "none")
    if seed_channel_used and seed_mode != "none":
        seed_mode = f"nnunet-channel+{seed_mode}"
    elif seed_channel_used:
        seed_mode = "nnunet-channel"

    result = {
        "status": "ok",
        "backend": "nnunet-local-trained-model",
        "modelFolder": str(model_folder),
        "channels": written_roles,
        "tumourSeedGuidance": {
            "provided": tumour_seed_count(job),
            "usable": usable_seed_count,
            "used": bool(seed_channel_used or output_seed_guidance.get("used")),
            "mode": seed_mode if seed_mode != "none" else "job-metadata-only",
        },
        "predictionNIfTI": str(prediction),
        "outputLabelmap": str(output_raw),
        "labelVoxelCounts": counts,
        "timings": timings,
        "labels": {
            "0": "background",
            "1": "tumour core / non-enhancing label",
            "2": "edema",
            "4": "enhancing tumour",
        },
        "message": "Local trained nnU-Net tumour segmentation completed.",
    }
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"metal3d_tumor_segmentation_nnunet.py: {error}", file=sys.stderr)
        sys.exit(1)
