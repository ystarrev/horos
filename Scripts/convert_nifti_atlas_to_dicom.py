#!/usr/bin/env python3
"""Convert a NIfTI atlas image and label map into DICOM MR and DICOM SEG.

The image conversion intentionally uses only Python's standard library.  DICOM
SEG creation is delegated to Horos' existing modern DCMTK bridge so the output
uses the same standards-compliant writer as Metal ROI authoring.
"""

from __future__ import annotations

import argparse
import array
import ctypes
import gzip
import json
import math
import os
from pathlib import Path
import struct
import sys
import uuid


MR_IMAGE_STORAGE_UID = "1.2.840.10008.5.1.4.1.1.4"
EXPLICIT_VR_LITTLE_ENDIAN_UID = "1.2.840.10008.1.2.1"
IMPLEMENTATION_CLASS_UID = "1.2.826.0.1.3680043.10.543.1"
UID_NAMESPACE = uuid.UUID("d4f50299-9762-4a5a-baf5-548e7e822895")

LONG_VRS = {"OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UR", "UT", "UN"}
TEXT_VRS = {"AE", "AS", "CS", "DA", "DS", "DT", "IS", "LO", "LT", "PN", "SH", "ST", "TM", "UC", "UR", "UT"}


def deterministic_uid(name: str) -> str:
    return f"2.25.{uuid.uuid5(UID_NAMESPACE, name).int}"


def vector_length(vector: tuple[float, float, float]) -> float:
    return math.sqrt(sum(component * component for component in vector))


def normalize(vector: tuple[float, float, float]) -> tuple[float, float, float]:
    length = vector_length(vector)
    if length <= 0:
        raise ValueError("NIfTI affine contains a zero-length direction vector")
    return tuple(component / length for component in vector)


def cross(
    lhs: tuple[float, float, float], rhs: tuple[float, float, float]
) -> tuple[float, float, float]:
    return (
        lhs[1] * rhs[2] - lhs[2] * rhs[1],
        lhs[2] * rhs[0] - lhs[0] * rhs[2],
        lhs[0] * rhs[1] - lhs[1] * rhs[0],
    )


def dot(lhs: tuple[float, float, float], rhs: tuple[float, float, float]) -> float:
    return sum(a * b for a, b in zip(lhs, rhs))


def ras_to_lps(vector: tuple[float, float, float]) -> tuple[float, float, float]:
    return (-vector[0], -vector[1], vector[2])


def format_decimal(value: float) -> str:
    if abs(value) < 5e-13:
        value = 0.0
    text = f"{value:.10g}"
    return text[:16]


def dicom_text(value: str) -> bytes:
    return value.encode("ascii", errors="replace")


def encode_value(vr: str, value) -> bytes:
    if isinstance(value, bytes):
        encoded = value
    elif vr == "US":
        values = value if isinstance(value, (tuple, list)) else [value]
        encoded = struct.pack("<" + "H" * len(values), *values)
    elif vr == "SS":
        values = value if isinstance(value, (tuple, list)) else [value]
        encoded = struct.pack("<" + "h" * len(values), *values)
    elif vr == "UL":
        values = value if isinstance(value, (tuple, list)) else [value]
        encoded = struct.pack("<" + "I" * len(values), *values)
    elif vr in TEXT_VRS or vr == "UI":
        encoded = dicom_text(str(value))
    else:
        raise ValueError(f"Unsupported DICOM VR {vr}")

    if len(encoded) % 2:
        encoded += b"\0" if vr in {"UI", "OB", "OW", "UN"} else b" "
    return encoded


def dicom_element(group: int, element: int, vr: str, value) -> bytes:
    encoded = encode_value(vr, value)
    tag_and_vr = struct.pack("<HH2s", group, element, vr.encode("ascii"))
    if vr in LONG_VRS:
        return tag_and_vr + b"\0\0" + struct.pack("<I", len(encoded)) + encoded
    if len(encoded) > 0xFFFF:
        raise ValueError(f"DICOM element ({group:04x},{element:04x}) is too large for VR {vr}")
    return tag_and_vr + struct.pack("<H", len(encoded)) + encoded


class NiftiVolume:
    _ARRAY_TYPES = {
        2: ("B", 1),
        4: ("h", 2),
        8: ("i", 4),
        16: ("f", 4),
        64: ("d", 8),
        256: ("b", 1),
        512: ("H", 2),
        768: ("I", 4),
    }

    def __init__(self, path: Path):
        self.path = path
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rb") as stream:
            header = stream.read(352)
            if len(header) < 352:
                raise ValueError(f"{path} has an incomplete NIfTI-1 header")
            if struct.unpack("<i", header[:4])[0] == 348:
                self.endian = "<"
            elif struct.unpack(">i", header[:4])[0] == 348:
                self.endian = ">"
            else:
                raise ValueError(f"{path} is not a NIfTI-1 file")

            dimensions = struct.unpack(self.endian + "8h", header[40:56])
            if dimensions[0] < 3:
                raise ValueError(f"{path} is not a three-dimensional volume")
            self.shape = tuple(int(value) for value in dimensions[1:4])
            self.datatype, self.bitpix = struct.unpack(self.endian + "2h", header[70:74])
            if self.datatype not in self._ARRAY_TYPES:
                raise ValueError(f"Unsupported NIfTI datatype {self.datatype} in {path}")
            self.pixdim = struct.unpack(self.endian + "8f", header[76:108])
            self.vox_offset = int(round(struct.unpack(self.endian + "f", header[108:112])[0]))
            self.scl_slope = struct.unpack(self.endian + "f", header[112:116])[0]
            self.scl_intercept = struct.unpack(self.endian + "f", header[116:120])[0]
            self.qform_code, self.sform_code = struct.unpack(self.endian + "2h", header[252:256])
            if self.sform_code <= 0:
                raise ValueError(f"{path} has no sform affine; atlas conversion requires explicit geometry")
            self.affine = (
                struct.unpack(self.endian + "4f", header[280:296]),
                struct.unpack(self.endian + "4f", header[296:312]),
                struct.unpack(self.endian + "4f", header[312:328]),
                (0.0, 0.0, 0.0, 1.0),
            )
            stream.seek(self.vox_offset)
            type_code, byte_count = self._ARRAY_TYPES[self.datatype]
            expected_values = self.shape[0] * self.shape[1] * self.shape[2]
            raw = stream.read(expected_values * byte_count)
            if len(raw) != expected_values * byte_count:
                raise ValueError(f"{path} has incomplete voxel data")

        self.values = array.array(type_code)
        self.values.frombytes(raw)
        if (self.endian == ">") == (sys.byteorder == "little"):
            self.values.byteswap()

    def linear_index(self, indices: tuple[int, int, int]) -> int:
        return indices[0] + self.shape[0] * (indices[1] + self.shape[1] * indices[2])

    def value(self, indices: tuple[int, int, int]):
        return self.values[self.linear_index(indices)]

    def axis_vector_ras(self, axis: int) -> tuple[float, float, float]:
        return tuple(self.affine[row][axis] for row in range(3))

    def position_ras(self, indices: tuple[int, int, int]) -> tuple[float, float, float]:
        return tuple(
            sum(self.affine[row][axis] * indices[axis] for axis in range(3))
            + self.affine[row][3]
            for row in range(3)
        )

    def physical_value(self, raw_value) -> float:
        slope = self.scl_slope if math.isfinite(self.scl_slope) and self.scl_slope != 0 else 1.0
        intercept = self.scl_intercept if math.isfinite(self.scl_intercept) else 0.0
        return float(raw_value) * slope + intercept


class DicomGeometry:
    def __init__(self, volume: NiftiVolume, slice_axis: int):
        if slice_axis not in {0, 1, 2}:
            raise ValueError("slice axis must be 0, 1 or 2")
        self.slice_axis = slice_axis
        remaining = [axis for axis in range(3) if axis != slice_axis]
        self.column_axis, self.row_axis = remaining
        self.columns = volume.shape[self.column_axis]
        self.rows = volume.shape[self.row_axis]

        self.column_vector = ras_to_lps(volume.axis_vector_ras(self.column_axis))
        self.row_vector = ras_to_lps(volume.axis_vector_ras(self.row_axis))
        self.slice_vector = ras_to_lps(volume.axis_vector_ras(self.slice_axis))
        self.column_direction = normalize(self.column_vector)
        self.row_direction = normalize(self.row_vector)

        # DICOM viewers place pixel row zero at the top of the viewport.  When
        # the NIfTI row axis points predominantly toward patient superior (+Z),
        # preserving its storage order therefore displays coronal/sagittal
        # anatomy upside down.  Reverse both the pixels and their physical row
        # direction; Image Position is moved to the opposite edge below, so the
        # represented patient-space geometry is unchanged.
        self.reverse_rows = (
            self.row_direction[2] > 0
            and abs(self.row_direction[2])
            >= max(abs(self.row_direction[0]), abs(self.row_direction[1]))
        )
        if self.reverse_rows:
            self.row_vector = tuple(-component for component in self.row_vector)
            self.row_direction = tuple(-component for component in self.row_direction)
        self.normal = normalize(cross(self.column_direction, self.row_direction))
        self.column_spacing = vector_length(self.column_vector)
        self.row_spacing = vector_length(self.row_vector)
        self.slice_spacing = vector_length(self.slice_vector)

        slice_indices = list(range(volume.shape[slice_axis]))
        if dot(normalize(self.slice_vector), self.normal) < 0:
            slice_indices.reverse()
        self.slice_indices = slice_indices

    def voxel_indices(self, column: int, row: int, slice_index: int) -> tuple[int, int, int]:
        indices = [0, 0, 0]
        indices[self.column_axis] = column
        indices[self.row_axis] = self.rows - 1 - row if self.reverse_rows else row
        indices[self.slice_axis] = slice_index
        return tuple(indices)


def stored_pixel_description(volume: NiftiVolume) -> tuple[int, int, float, float]:
    slope = volume.scl_slope if math.isfinite(volume.scl_slope) and volume.scl_slope != 0 else 1.0
    intercept = volume.scl_intercept if math.isfinite(volume.scl_intercept) else 0.0
    if volume.datatype == 4:
        return 16, 1, slope, intercept
    if volume.datatype == 512:
        return 16, 0, slope, intercept
    raise ValueError("Atlas MR conversion currently supports int16 and uint16 NIfTI source images")


def image_frame_bytes(
    volume: NiftiVolume, geometry: DicomGeometry, slice_index: int, signed: int
) -> bytes:
    pixels = array.array("h" if signed else "H")
    append = pixels.append
    for row in range(geometry.rows):
        for column in range(geometry.columns):
            append(int(volume.value(geometry.voxel_indices(column, row, slice_index))))
    if sys.byteorder != "little":
        pixels.byteswap()
    return pixels.tobytes()


def mask_frame_bytes(
    volume: NiftiVolume, geometry: DicomGeometry, slice_index: int, label_value: int
) -> bytes:
    mask = bytearray(geometry.rows * geometry.columns)
    offset = 0
    for row in range(geometry.rows):
        for column in range(geometry.columns):
            if int(volume.value(geometry.voxel_indices(column, row, slice_index))) == label_value:
                mask[offset] = 1
            offset += 1
    return bytes(mask)


def robust_window(volume: NiftiVolume) -> tuple[float, float]:
    value_count = len(volume.values)
    stride = max(1, value_count // 200_000)
    sampled = sorted(volume.physical_value(volume.values[index]) for index in range(0, value_count, stride))
    if not sampled:
        return 0.0, 1.0
    low = sampled[int((len(sampled) - 1) * 0.01)]
    high = sampled[int((len(sampled) - 1) * 0.995)]
    if high <= low:
        high = low + 1.0
    return (low + high) * 0.5, high - low


def write_dicom_image(
    output_path: Path,
    pixel_data: bytes,
    instance_number: int,
    slice_index: int,
    volume: NiftiVolume,
    geometry: DicomGeometry,
    identifiers: dict[str, str],
    metadata: dict,
) -> None:
    sop_instance_uid = deterministic_uid(f"{identifiers['series_uid']}:{instance_number}")
    bits, signed, rescale_slope, rescale_intercept = stored_pixel_description(volume)
    window_center, window_width = identifiers["window"]
    position = ras_to_lps(volume.position_ras(geometry.voxel_indices(0, 0, slice_index)))
    orientation = geometry.column_direction + geometry.row_direction
    slice_location = dot(position, geometry.normal)

    meta_elements = b"".join(
        [
            dicom_element(0x0002, 0x0001, "OB", b"\0\1"),
            dicom_element(0x0002, 0x0002, "UI", MR_IMAGE_STORAGE_UID),
            dicom_element(0x0002, 0x0003, "UI", sop_instance_uid),
            dicom_element(0x0002, 0x0010, "UI", EXPLICIT_VR_LITTLE_ENDIAN_UID),
            dicom_element(0x0002, 0x0012, "UI", IMPLEMENTATION_CLASS_UID),
            dicom_element(0x0002, 0x0013, "SH", "HOROSATLAS1"),
        ]
    )
    file_meta = dicom_element(0x0002, 0x0000, "UL", len(meta_elements)) + meta_elements

    elements = [
        (0x0008, 0x0008, "CS", "DERIVED\\SECONDARY\\OTHER"),
        (0x0008, 0x0016, "UI", MR_IMAGE_STORAGE_UID),
        (0x0008, 0x0018, "UI", sop_instance_uid),
        (0x0008, 0x0020, "DA", identifiers["study_date"]),
        (0x0008, 0x0021, "DA", identifiers["study_date"]),
        (0x0008, 0x0022, "DA", identifiers["study_date"]),
        (0x0008, 0x0030, "TM", identifiers["study_time"]),
        (0x0008, 0x0031, "TM", identifiers["study_time"]),
        (0x0008, 0x0032, "TM", identifiers["study_time"]),
        (0x0008, 0x0050, "SH", identifiers["accession_number"]),
        (0x0008, 0x0060, "CS", str(metadata.get("Modality", "MR"))),
        (0x0008, 0x0070, "LO", str(metadata.get("Manufacturer", "OpenNeuro"))),
        (0x0008, 0x0080, "LO", str(metadata.get("InstitutionName", "OpenNeuro ds006248"))),
        (0x0008, 0x0090, "PN", ""),
        (0x0008, 0x1030, "LO", "Pituitary Atlas - Expert Segmentation"),
        (0x0008, 0x103E, "LO", f"Pituitary Atlas {identifiers['subject_id']} CE Cor T1"),
        (0x0008, 0x1090, "LO", "NIfTI-derived reference"),
        (
            0x0008,
            0x2111,
            "ST",
            "Derived from OpenNeuro ds006248; Cerny et al.; CC BY-NC 4.0",
        ),
        (0x0010, 0x0010, "PN", identifiers["patient_name"]),
        (0x0010, 0x0020, "LO", identifiers["patient_id"]),
        (0x0010, 0x0030, "DA", ""),
        (0x0010, 0x0040, "CS", ""),
        (0x0018, 0x0015, "CS", "HEAD"),
        (0x0018, 0x0050, "DS", format_decimal(geometry.slice_spacing)),
        (0x0018, 0x0080, "DS", format_decimal(float(metadata.get("RepetitionTime", 0.0)))),
        (0x0018, 0x0081, "DS", format_decimal(float(metadata.get("EchoTime", 0.0)))),
        (0x0018, 0x0088, "DS", format_decimal(geometry.slice_spacing)),
        (0x0018, 0x1314, "DS", format_decimal(float(metadata.get("FlipAngle", 0.0)))),
        (0x0018, 0x5100, "CS", "HFS"),
        (0x0020, 0x000D, "UI", identifiers["study_uid"]),
        (0x0020, 0x000E, "UI", identifiers["series_uid"]),
        (0x0020, 0x0010, "SH", identifiers["study_id"]),
        (0x0020, 0x0011, "IS", "1"),
        (0x0020, 0x0012, "IS", "1"),
        (0x0020, 0x0013, "IS", str(instance_number)),
        (0x0020, 0x0032, "DS", "\\".join(format_decimal(value) for value in position)),
        (0x0020, 0x0037, "DS", "\\".join(format_decimal(value) for value in orientation)),
        (0x0020, 0x0052, "UI", identifiers["frame_of_reference_uid"]),
        (0x0020, 0x1040, "LO", ""),
        (0x0020, 0x1041, "DS", format_decimal(slice_location)),
        (0x0028, 0x0002, "US", 1),
        (0x0028, 0x0004, "CS", "MONOCHROME2"),
        (0x0028, 0x0010, "US", geometry.rows),
        (0x0028, 0x0011, "US", geometry.columns),
        (
            0x0028,
            0x0030,
            "DS",
            f"{format_decimal(geometry.row_spacing)}\\{format_decimal(geometry.column_spacing)}",
        ),
        (0x0028, 0x0100, "US", bits),
        (0x0028, 0x0101, "US", bits),
        (0x0028, 0x0102, "US", bits - 1),
        (0x0028, 0x0103, "US", signed),
        (0x0028, 0x1050, "DS", format_decimal(window_center)),
        (0x0028, 0x1051, "DS", format_decimal(window_width)),
        (0x0028, 0x1052, "DS", format_decimal(rescale_intercept)),
        (0x0028, 0x1053, "DS", format_decimal(rescale_slope)),
        (0x7FE0, 0x0010, "OW", pixel_data),
    ]
    dataset = b"".join(dicom_element(*item) for item in sorted(elements))
    output_path.write_bytes(b"\0" * 128 + b"DICM" + file_meta + dataset)


def locate_bridge(explicit_path: str | None) -> Path:
    candidates = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived_data.exists():
        candidates.extend(derived_data.glob("Horos-*/Build/Products/Debug/DCMTK/libHorosModernDCMTKBridge.dylib"))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("Could not locate libHorosModernDCMTKBridge.dylib; pass --bridge")


def write_segmentations(
    bridge_path: Path,
    output_directory: Path,
    source_paths: list[Path],
    segmentation: NiftiVolume,
    geometry: DicomGeometry,
    labels: dict[int, str],
    subject_id: str,
) -> list[Path]:
    library = ctypes.CDLL(str(bridge_path))
    write_seg = library.HorosModernDCMTKWriteBinarySegmentation
    write_seg.restype = ctypes.c_int
    write_seg.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_double,
        ctypes.c_double,
        ctypes.c_double,
        ctypes.POINTER(ctypes.c_char_p),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
        ctypes.c_int,
        ctypes.c_ushort,
        ctypes.c_ushort,
        ctypes.POINTER(ctypes.c_char_p),
    ]
    free_string = library.HorosModernDCMTKFreeString
    free_string.argtypes = [ctypes.c_void_p]

    source_array = (ctypes.c_char_p * len(source_paths))(
        *(os.fsencode(path) for path in source_paths)
    )
    colors = [
        (1.0, 0.78, 0.0),
        (0.2, 0.85, 0.3),
        (0.2, 0.65, 1.0),
        (0.8, 0.35, 1.0),
        (1.0, 0.35, 0.35),
    ]
    outputs = []
    for color_index, (label_value, label_name) in enumerate(labels.items()):
        frames = [
            mask_frame_bytes(segmentation, geometry, slice_index, label_value)
            for slice_index in geometry.slice_indices
        ]
        if not any(any(frame) for frame in frames):
            print(f"Skipping absent label {label_value}: {label_name}")
            continue
        frame_buffers = [(ctypes.c_ubyte * len(frame)).from_buffer_copy(frame) for frame in frames]
        frame_array = (ctypes.POINTER(ctypes.c_ubyte) * len(frame_buffers))(
            *(ctypes.cast(frame, ctypes.POINTER(ctypes.c_ubyte)) for frame in frame_buffers)
        )
        safe_name = "".join(character if character.isalnum() else "_" for character in label_name).strip("_")
        output = output_directory / f"SEG_{label_value:02d}_{safe_name}.dcm"
        tracking_uid = deterministic_uid(f"OpenNeuro-ds006248-{subject_id}:{label_value}:{label_name}")
        authoring = json.dumps(
            {
                "source": f"OpenNeuro ds006248 {subject_id} ground truth",
                "license": "CC BY-NC 4.0",
                "segmentLabelValue": label_value,
                "segmentLabel": label_name,
                "segmentationType": "Manual expert-reviewed atlas",
            },
            separators=(",", ":"),
        )
        failure = ctypes.c_char_p()
        red, green, blue = colors[color_index % len(colors)]
        success = write_seg(
            os.fsencode(output),
            label_name.encode("utf-8"),
            tracking_uid.encode("ascii"),
            authoring.encode("utf-8"),
            red,
            green,
            blue,
            source_array,
            frame_array,
            len(source_paths),
            geometry.rows,
            geometry.columns,
            ctypes.byref(failure),
        )
        if not success:
            message = failure.value.decode("utf-8", errors="replace") if failure.value else "unknown error"
            if failure:
                free_string(failure)
            raise RuntimeError(f"Could not create DICOM SEG for {label_name}: {message}")
        if failure:
            free_string(failure)
        outputs.append(output)
    return outputs


def parse_labels(path: Path) -> dict[int, str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    label_map = payload.get("LabelMap")
    if not isinstance(label_map, dict):
        raise ValueError(f"{path} contains no LabelMap object")
    return {
        int(label): str(name)
        for label, name in label_map.items()
        if int(label) != 0
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--segmentation", required=True, type=Path)
    parser.add_argument("--image-metadata", required=True, type=Path)
    parser.add_argument("--segmentation-metadata", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--slice-axis", type=int, default=2, choices=(0, 1, 2))
    parser.add_argument("--bridge")
    parser.add_argument("--subject-id", default="sub-001")
    arguments = parser.parse_args()

    image = NiftiVolume(arguments.image)
    segmentation = NiftiVolume(arguments.segmentation)
    if image.shape != segmentation.shape:
        raise ValueError(f"Image shape {image.shape} does not match segmentation {segmentation.shape}")
    for row in range(3):
        for column in range(4):
            if abs(image.affine[row][column] - segmentation.affine[row][column]) > 1e-4:
                raise ValueError("Image and segmentation NIfTI affines do not match")

    geometry = DicomGeometry(image, arguments.slice_axis)
    segmentation_geometry = DicomGeometry(segmentation, arguments.slice_axis)
    if (
        geometry.rows != segmentation_geometry.rows
        or geometry.columns != segmentation_geometry.columns
        or geometry.slice_indices != segmentation_geometry.slice_indices
    ):
        raise ValueError("Image and segmentation geometry do not match")

    metadata = json.loads(arguments.image_metadata.read_text(encoding="utf-8"))
    labels = parse_labels(arguments.segmentation_metadata)
    arguments.output.mkdir(parents=True, exist_ok=True)
    image_directory = arguments.output / "MR"
    segmentation_directory = arguments.output / "SEG"
    image_directory.mkdir(exist_ok=True)
    segmentation_directory.mkdir(exist_ok=True)

    subject_id = arguments.subject_id.strip().lower()
    subject_token = "".join(character for character in subject_id.upper() if character.isalnum())
    identifiers = {
        "subject_id": subject_id,
        "patient_name": f"PITUITARY^ATLAS^{subject_token}",
        "patient_id": f"PITUITARY_ATLAS_{subject_token}",
        "accession_number": f"ATLAS{subject_token[-3:]}",
        "study_id": f"ATLAS{subject_token[-3:]}",
        "study_uid": deterministic_uid(f"OpenNeuro-ds006248-{subject_id}:study"),
        "series_uid": deterministic_uid(f"OpenNeuro-ds006248-{subject_id}:CECorT1:series"),
        "frame_of_reference_uid": deterministic_uid(f"OpenNeuro-ds006248-{subject_id}:frame-of-reference"),
        "study_date": "20250111",
        "study_time": "080000",
        "window": robust_window(image),
    }
    source_paths = []
    for instance_number, slice_index in enumerate(geometry.slice_indices, start=1):
        output_path = image_directory / f"IM_{instance_number:04d}.dcm"
        frame = image_frame_bytes(image, geometry, slice_index, stored_pixel_description(image)[1])
        write_dicom_image(
            output_path,
            frame,
            instance_number,
            slice_index,
            image,
            geometry,
            identifiers,
            metadata,
        )
        source_paths.append(output_path)

    segmentations = write_segmentations(
        locate_bridge(arguments.bridge),
        segmentation_directory,
        source_paths,
        segmentation,
        segmentation_geometry,
        labels,
        subject_id,
    )
    manifest = {
        "studyInstanceUID": identifiers["study_uid"],
        "seriesInstanceUID": identifiers["series_uid"],
        "source": f"OpenNeuro ds006248 {subject_id}",
        "license": "CC BY-NC 4.0",
        "mrImages": [str(path) for path in source_paths],
        "segmentations": [str(path) for path in segmentations],
    }
    (arguments.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(source_paths)} MR instances and {len(segmentations)} DICOM SEG objects to {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
