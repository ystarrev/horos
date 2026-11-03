"""Test model I/O using synthetic volumes, with the helper's scientific Python.

No model inference, app build, or patient data is required.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import nibabel as nib
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
with patch.dict(os.environ, {"HOROS_TUMOR_SEGMENTATION_BOOTSTRAPPED": "1"}):
    import metal3d_tumor_segmentation_nnunet as helper


def installed_model_schema():
    # Same channel names and label definitions as the installed BAMF/BraTS model.
    return {
        "channel_names": {"0": "t1", "1": "t1ce", "2": "t2", "3": "flair"},
        "labels": {"background": 0, "edema": 1, "empty": 3, "enhancing": 4, "nonenhancing": 2},
    }


class TumorModelContractTests(unittest.TestCase):
    def test_installed_model_channels_match_training_order(self):
        self.assertEqual(helper.model_channel_order(installed_model_schema()), ["t1", "t1c", "t2", "flair"])

    def test_channel_indices_not_dictionary_insertion_order_determine_order(self):
        dataset = {"channel_names": {"3": "FLAIR", "1": "T1CE", "0": "T1", "2": "T2"}}
        self.assertEqual(helper.model_channel_order(dataset), ["t1", "t1c", "t2", "flair"])

    def test_sequence_and_seed_aliases_are_normalized(self):
        for name, role in [("T1w", "t1"), ("T1n", "t1"), ("T1gd", "t1c"), ("T1-Gd", "t1c"),
                           ("T2w", "t2"), ("T2f", "flair"), ("TumourSeed", "seed"), ("TumorSeed", "seed")]:
            with self.subTest(name=name):
                self.assertEqual(helper.model_channel_order({"channel_names": {"0": name}}), [role])

    def test_model_channels_are_not_restricted_to_four_sequences(self):
        self.assertEqual(helper.model_channel_order({"channel_names": {"0": "T1ce"}}), ["t1c"])
        dataset = installed_model_schema()
        dataset["channel_names"]["4"] = "seed"
        self.assertEqual(helper.model_channel_order(dataset)[-1], "seed")

    def test_ambiguous_or_invalid_channels_are_rejected(self):
        for channels in [None, {}, [], {"1": "t1"}, {"0": "t1", "2": "t2"},
                         {"00": "t1"}, {"0": "MRI"}, {"0": ""}, {"0": None}]:
            with self.subTest(channels=channels), self.assertRaises(RuntimeError):
                helper.model_channel_order({"channel_names": channels})

    def test_installed_model_labels_swap_edema_and_core_and_discard_empty(self):
        self.assertEqual(helper.model_label_mapping(installed_model_schema()), {0: 0, 1: 2, 2: 1, 3: 0, 4: 4})

    def test_standard_brats_label_three_is_enhancing_only_when_declared(self):
        dataset = {"labels": {"background": 0, "NCR/NET": 1, "edema": 2, "enhancing tumor": 3}}
        self.assertEqual(helper.model_label_mapping(dataset), {0: 0, 1: 1, 2: 2, 3: 4})

    def test_label_aliases_and_ignored_classes(self):
        dataset = {"labels": {"Background": 0, "Non-enhancing tumour core": 2,
                              "Peritumoral oedema": 1, "ET": 4, "unused": 3}}
        self.assertEqual(helper.model_label_mapping(dataset), {0: 0, 2: 1, 1: 2, 4: 4, 3: 0})

    def test_unknown_conflicting_and_region_based_labels_are_rejected(self):
        for labels in [None, {}, [], {"background": 0}, {"background": 0, "unknown tissue": 1},
                       {"background": 0, "edema": 1, "enhancing": 1}, {"background": 1, "enhancing": 0},
                       {"background": 0, "edema": [1, 2]}, {"background": 0, "edema": True},
                       {"background": 0, "edema": -1}, {"background": 0, "edema": "1"}]:
            with self.subTest(labels=labels), self.assertRaises(RuntimeError):
                helper.model_label_mapping({"labels": labels})

    def test_remapping_is_not_an_in_place_swap(self):
        source = np.array([0, 1, 2, 3, 4, 2, 1], dtype=np.float32)
        original = source.copy()
        actual = helper.remap_model_labels(source, helper.model_label_mapping(installed_model_schema()))
        np.testing.assert_array_equal(actual, [0, 2, 1, 0, 4, 1, 2])
        np.testing.assert_array_equal(source, original)
        self.assertEqual(actual.dtype, np.uint8)

    def test_invalid_predictions_are_not_rounded_or_clipped_into_valid_labels(self):
        mapping = helper.model_label_mapping(installed_model_schema())
        for value in [np.nan, np.inf, -np.inf, 1.2, -1, 255, 256]:
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                helper.remap_model_labels(np.array([0, value], dtype=np.float32), mapping)

    def test_remapping_happens_before_seed_component_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = np.array([0, 1, 2, 3, 4], dtype=np.float32).reshape(5, 1, 1)
            prediction = work / "prediction.nii.gz"
            nib.save(nib.Nifti1Image(source, np.eye(4)), prediction)
            job = {"dimensions": [5, 1, 1], "expectedVoxelCount": 5}

            def check_seed_input(labels, passed_job):
                np.testing.assert_array_equal(labels, np.array([0, 2, 1, 0, 4], dtype=np.uint8).reshape(1, 1, 5))
                self.assertIs(passed_job, job)
                return labels, {"used": True}

            with patch.object(helper, "constrain_labels_to_tumour_seeds", side_effect=check_seed_input) as constrain:
                counts, guidance = helper.convert_prediction_to_horos(
                    job, prediction, work / "labels.raw", helper.model_label_mapping(installed_model_schema()))
            constrain.assert_called_once()
            self.assertEqual(counts, {"1": 1, "2": 1, "4": 1})
            self.assertTrue(guidance["used"])

    def test_missing_required_sequence_fails_before_writing_channels(self):
        with tempfile.TemporaryDirectory() as directory:
            input_dir = Path(directory) / "inputs"
            with self.assertRaisesRegex(RuntimeError, "required nnU-Net channels: t1c, t2, flair"):
                helper.write_nnunet_inputs({"spacingMM": [1, 1, 1]}, {"t1": np.zeros((2, 2, 2))},
                                          input_dir, helper.model_channel_order(installed_model_schema()))
            self.assertEqual(list(input_dir.iterdir()), [])

    def test_full_helper_ignores_legacy_order_and_writes_canonical_labels(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            model = work / "model"
            model.mkdir()
            (model / "dataset.json").write_text(json.dumps(installed_model_schema()))
            config = {"nnunet_model_folder": str(model), "nnunet_channels": "flair,t1,t1c,t2"}
            job = {"dimensions": [2, 3, 2], "expectedVoxelCount": 12, "spacingMM": [1, 2, 3],
                   "workingDirectory": str(work), "outputLabelmap": str(work / "labels.raw"),
                   "resultJSON": str(work / "result.json")}
            job_path = work / "job.json"
            job_path.write_text(json.dumps(job))
            volumes = {role: np.full((2, 3, 2), value, dtype=np.float32)
                       for role, value in [("flair", 40), ("t1", 10), ("t1c", 20), ("t2", 30)]}
            prediction = np.array([0, 1, 2, 3, 4, 1, 2, 4, 3, 0, 2, 1], dtype=np.float32).reshape(2, 3, 2)

            def run_model(config, model_folder, input_dir, output_dir, channel_order):
                self.assertEqual(model_folder, model)
                self.assertEqual(channel_order, ["t1", "t1c", "t2", "flair"])
                for index, role in enumerate(channel_order):
                    channel = nib.load(input_dir / f"horos_{index:04d}.nii.gz")
                    np.testing.assert_array_equal(np.asarray(channel.dataobj), volumes[role].transpose(2, 1, 0))
                path = work / "prediction.nii.gz"
                nib.save(nib.Nifti1Image(prediction, helper.nifti_affine_from_job(job)), path)
                return path, {}

            with patch.dict(os.environ, {"HOROS_TUMOR_NNUNET_CHANNELS": "t2,flair,t1c,t1"}, clear=True), \
                    patch.object(sys, "argv", ["helper", "--job", str(job_path)]), \
                    patch.object(helper, "load_config", return_value=config), \
                    patch.object(helper, "selected_modalities", return_value=(volumes, [])), \
                    patch.object(helper, "run_nnunet", side_effect=run_model) as infer, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(helper.main(), 0)
                infer.assert_called_once()

            mapping = helper.model_label_mapping(installed_model_schema())
            expected = np.array([mapping[int(value)] for value in prediction.flat], dtype=np.uint8).reshape(prediction.shape)
            actual = np.fromfile(job["outputLabelmap"], dtype=np.uint8)
            np.testing.assert_array_equal(actual, expected.transpose(2, 1, 0).ravel())
            self.assertEqual(actual.size, job["expectedVoxelCount"])
            result = json.loads(Path(job["resultJSON"]).read_text())
            self.assertEqual(result["channels"], ["t1", "t1c", "t2", "flair"])
            self.assertEqual(result["modelToHorosLabels"], {"0": 0, "1": 2, "2": 1, "3": 0, "4": 4})
            self.assertEqual(result["labelVoxelCounts"], {"1": 3, "2": 3, "4": 2})
            self.assertEqual(result["labels"]["2"], "edema")

    def test_model_label_validation_happens_before_loading_images_or_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            schema = installed_model_schema()
            schema["labels"]["unrecognized"] = 5
            (work / "dataset.json").write_text(json.dumps(schema))
            job_path = work / "job.json"
            job_path.write_text("{}")
            with patch.dict(os.environ, {}, clear=True), \
                    patch.object(sys, "argv", ["helper", "--job", str(job_path)]), \
                    patch.object(helper, "load_config", return_value={"nnunet_model_folder": str(work)}), \
                    patch.object(helper, "selected_modalities") as images, \
                    patch.object(helper, "run_nnunet") as infer, \
                    self.assertRaisesRegex(RuntimeError, "Unsupported model output label"):
                helper.main()
            images.assert_not_called()
            infer.assert_not_called()


if __name__ == "__main__":
    unittest.main()
