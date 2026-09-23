"""Non-build integration checks for the clipboard clinic album feature."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTROLLER = (ROOT / "Horos/Sources/ClinicAlbumImportController.swift").read_text()
MATCHING = (ROOT / "Horos/Sources/ClinicAlbumMatching.swift").read_text()


class ClinicAlbumIntegrationTests(unittest.TestCase):
    def test_menu_and_project_wiring(self):
        self.assertIn("[ClinicAlbumImportController installMenuItem]", (ROOT / "Horos/Sources/AppController.m").read_text())
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for name in ("ClinicAlbumMatching.swift", "ClinicAlbumImportController.swift"):
            self.assertIn(name + " in Sources", project)

    def test_local_clipboard_ocr(self):
        self.assertIn("clipboard.data(forType: .png)", CONTROLLER)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: 3000", CONTROLLER)
        self.assertIn("RecognizeTextRequest()", CONTROLLER)
        self.assertIn("request.usesLanguageCorrection = false", CONTROLLER)
        self.assertNotIn("URLSession", CONTROLLER)

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


if __name__ == "__main__":
    unittest.main()
