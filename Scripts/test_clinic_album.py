"""Non-build integration checks for the clipboard clinic album feature."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTROLLER = (ROOT / "Horos/Sources/ClinicAlbumImportController.swift").read_text()
MATCHING = (ROOT / "Horos/Sources/ClinicAlbumMatching.swift").read_text()
OCR = (ROOT / "Horos/Sources/ClinicAlbumOCR.swift").read_text()


class ClinicAlbumIntegrationTests(unittest.TestCase):
    def test_menu_and_project_wiring(self):
        self.assertIn("[ClinicAlbumImportController installMenuItem]", (ROOT / "Horos/Sources/AppController.m").read_text())
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("ClinicAlbumMatching.swift", "ClinicAlbumImportController.swift", "ClinicAlbumOCR.swift"):
            self.assertIn(name + " in Sources", project)

    def test_local_clipboard_ocr(self):
        self.assertIn("clipboard.data(forType: .png)", CONTROLLER)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: 3000", OCR)
        self.assertIn("VNRecognizeTextRequest()", OCR)
        self.assertIn("request.usesLanguageCorrection = false", OCR)
        self.assertNotIn("URLSession", CONTROLLER + OCR)

    def test_accurate_ocr_stays_off_main_actor(self):
        self.assertIn("request.recognitionLevel = .accurate", OCR)
        self.assertNotIn(".fast", OCR)
        self.assertIn("queue.async", OCR)
        self.assertIn("withTaskCancellationHandler", OCR)
        self.assertIn("job.cancel()", OCR)
        self.assertIn("request?.cancel()", OCR)
        self.assertIn("VNImageRequestHandler(cgImage: image).perform([request])", OCR)
        self.assertIn("ClinicAlbumOCR.recognizedNames(observations)", OCR)
        self.assertIn("observations=%ld names=%ld", OCR)

    def test_accurate_ocr_uses_supported_cpu_devices(self):
        self.assertIn("try request.supportedComputeStageDevices", OCR)
        self.assertIn("if case .cpu = $0", OCR)
        self.assertIn("request.setComputeDevice(cpu, for: stage)", OCR)
        self.assertIn("if cpuOnly && ClinicAlbumOCR.isReaderInitializationFailure(failure)", OCR)
        self.assertNotIn("request.usesCPUOnly", OCR)

    def test_failed_ocr_does_not_leave_preview_loading(self):
        failure = CONTROLLER.split("self.retry.isHidden = !self.rows.isEmpty", 1)[0].rsplit("} catch {", 1)[1]
        self.assertIn("self.loading = false", failure)
        self.assertIn("self.add.isEnabled = true", failure)
        self.assertIn("#selector(retryRecognition)", CONTROLLER)
        self.assertIn("rows.isEmpty, let data = clipboardData", CONTROLLER)
        self.assertIn("self.updateStatus()", CONTROLLER.split("self.retry.isHidden = !self.rows.isEmpty", 1)[1])

    def test_isolated_and_revalidated_commit(self):
        self.assertIn(".privateQueueConcurrencyType", CONTROLLER)
        self.assertIn("study(object) == expected", CONTROLLER)
        self.assertIn("context.rollback()", CONTROLLER)
        self.assertIn("browser.database === database", CONTROLLER)
        self.assertIn("!database.isReadOnly", CONTROLLER)
        self.assertIn("try context.save()", CONTROLLER)
        self.assertNotIn("mainContext.save", CONTROLLER)
        self.assertNotIn("mainContext.rollback", CONTROLLER)
        self.assertIn("mutableSetValue(forKey: \"studies\")", CONTROLLER)
        self.assertIn("usedNames.contains(uniqueName)", CONTROLLER)

    def test_database_matching_and_one_click_commit(self):
        self.assertIn("browser.patientsnamePredicate(search)", CONTROLLER)
        self.assertIn("browser.samePatientStudiesPredicate(forStudy: values)", CONTROLLER)
        self.assertIn(".dictionaryResultType", CONTROLLER)
        self.assertIn("surgicalProcedureSeriesDescription()", CONTROLLER)
        self.assertNotIn("ClinicAlbumStore.snapshot", CONTROLLER)
        self.assertNotIn("Choose patient", CONTROLLER)
        self.assertNotIn("alertFirstButtonReturn", CONTROLLER)
        self.assertIn("commit(name: name, studies: studies)", CONTROLLER)
        self.assertIn("self.rows[index].revision == revision", CONTROLLER)
        self.assertIn("rows[index].included = false", CONTROLLER)
        self.assertIn("seen.insert($0.uri).inserted", CONTROLLER)
        self.assertIn("!loading && searches.isEmpty", CONTROLLER)

    def test_validation_uses_stored_name_not_display_getter(self):
        snapshot = CONTROLLER.split("static func study(", 1)[1].split("static func fetch(", 1)[0]
        self.assertIn('object.willAccessValue(forKey: "name")', snapshot)
        self.assertIn('object.didAccessValue(forKey: "name")', snapshot)
        self.assertIn('object.primitiveValue(forKey: "name")', snapshot)
        self.assertNotIn('object.value(forKey: "name")', snapshot)
        self.assertIn('name: row["name"] as? String ?? ""', CONTROLLER)
        self.assertIn("study(object) == expected", CONTROLLER)

    def test_uli_matching_prefers_identifier(self):
        self.assertIn("if let id = parsed?.patientID", CONTROLLER)
        self.assertIn("fetch(exactID, in: context)", CONTROLLER)
        self.assertIn("seedPredicate = exactID", CONTROLLER)
        self.assertIn("query: $0.searchQuery", CONTROLLER)
        self.assertIn("ULI not found; matched by name", MATCHING)

    def test_pacs_search_and_refresh(self):
        self.assertIn("let name = ClinicAlbumMatching.searchName(parsed?.name ?? row.query)", CONTROLLER)
        self.assertIn("QueryController.openPatientQuery(patientID: id, name: name)", CONTROLLER)
        self.assertIn("parsed?.patientID ?? numericID", CONTROLLER)
        self.assertIn("ids.count == 1", CONTROLLER)
        self.assertIn("@objc private func refreshStudies()", CONTROLLER)
        self.assertIn("self.rows[index].included || self.rows[index].studies.isEmpty", CONTROLLER)
        self.assertIn("browser.database === database", CONTROLLER)
        query = (ROOT / "Horos/Sources/QueryController.mm").read_text()
        route = query.split("+ (BOOL)openPatientQueryWithID:", 1)[1].split("- (NSArray*) queryPatientID:", 1)[0]
        self.assertIn("controller->performingCFind", route)
        self.assertIn("[controller emptyPreset:controller]", route)
        self.assertIn("[controller query:controller]", route)
        self.assertNotIn("retrieve:", route)


class ClinicAlbumRuntimeTests(unittest.TestCase):
    def test_matching_and_ocr_recovery(self):
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="horos-clinic-tests-") as folder:
            for name, source in (
                ("Matching", MATCHING + "\n" + (ROOT / "Scripts/tests/ClinicAlbumMatchingTests.swift").read_text()),
                ("OCR", MATCHING + "\n" + OCR + "\n" + (ROOT / "Scripts/tests/ClinicAlbumOCRTests.swift").read_text()),
            ):
                path = pathlib.Path(folder) / (name + ".swift")
                path.write_text(source)
                subprocess.run([swift, "-Xfrontend", "-parse-as-library", "-swift-version", "5",
                                "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
                                "-module-cache-path", "/tmp/horos-ocr-module-cache", str(path),
                                *(["--vision"] if name == "OCR" and os.environ.get("HOROS_TEST_CLINIC_OCR") == "1" else [])],
                               check=True, timeout=120)


if __name__ == "__main__":
    unittest.main()
