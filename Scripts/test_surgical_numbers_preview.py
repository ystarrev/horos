"""Read-only importer checks. Runs the embedded JXA reader against mock Numbers tables.

No Numbers documents, Horos databases, or application builds are created.
"""
import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/SurgicalProcedureImporter.swift").read_text()
SCRIPT = SOURCE.split('static let script = #"""', 1)[1].split('"""#', 1)[0]
HEADERS = ["Date", "Name", "ID", "Operation", "Diagnosis", "Results", "Optics", "Assistants"]


def read_tables(tables):
    mock = r"""
    var fixture = __FIXTURE__;
    var closed = false;
    function MockPath(path) { return path; }
    function cells(values) {
        return {
            value: function () { return values.map(function (v) {
                return v && v.date ? new Date(Date.UTC(v.date[0], v.date[1] - 1, v.date[2], 0, 0, 0))
                    : (v && typeof v === 'object' ? v.value : v);
            }); },
            formattedValue: function () { return values.map(function (v) {
                return v && typeof v === 'object' ? v.formatted : v;
            }); }
        };
    }
    function MockApplication(path) {
        return {open: function (file) { return {
            sheets: function () { return [{
                name: function () { return 'Surgical Log'; },
                tables: function () { return fixture.map(function (f, index) {
                    return {
                        name: function () { return 'Table ' + index; },
                        rowCount: function () { return f.rows.length; },
                        footerRowCount: function () { return f.footers || 0; },
                        rows: f.rows.map(function (row) { return {cells: cells(row)}; }),
                        columns: f.rows[0].map(function (_, c) {
                            return {cells: cells(f.rows.map(function (row) { return row[c]; }))};
                        })
                    };
                }); }
            }]; },
            close: function (options) {
                if (options.saving !== 'no') throw new Error('Reader tried to save');
                closed = true;
            }
        }; }};
    }
    """.replace("__FIXTURE__", json.dumps(tables))
    # Hide the reader's run() from osascript's entry point so its result and cleanup
    # can both be asserted, including the error paths.
    wrapper = r"""
    function run() {
        var result;
        try { result = {table: JSON.parse(readDocument(['Numbers', 'copy.numbers']))}; }
        catch (error) { result = {error: String(error)}; }
        result.closed = closed;
        return JSON.stringify(result);
    }
    """
    reader = SCRIPT.replace("function run(argv)", "function readDocument(argv)", 1)
    reader = reader.replace("Application(argv[0])", "MockApplication(argv[0])")
    reader = reader.replace("Path(argv[1])", "MockPath(argv[1])")
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e",
         mock + reader + wrapper],
        check=False, capture_output=True, text=True, timeout=20,
    )
    if result.returncode:
        raise AssertionError(result.stderr)
    return json.loads(result.stdout)


class NumbersReaderTests(unittest.TestCase):
    def test_typed_dates_ids_and_multiline_text(self):
        row = [
            {"date": [2024, 3, 21], "formatted": "21 Mar 2024"},
            "Test Patient",
            {"value": 1234, "formatted": "001234"},
            "Endoscopic surgery", "First line\nSecond line", 'Result: "benign"', "", "Assistant",
        ]
        result = read_tables([{"rows": [HEADERS, row]}])
        self.assertTrue(result["closed"])
        self.assertEqual(result["table"]["rows"][1],
                         ["2024-03-21", "Test Patient", "001234", *row[3:]])

    def test_date_only_cell_does_not_shift_to_previous_day(self):
        row = [{"date": [2007, 2, 14], "formatted": "Feb 14, 2007"},
               "Anderson, Ruth", "1008254730", "RF Crani Planum Meningioma", "", "", "", ""]
        result = read_tables([{"rows": [HEADERS, row]}])
        self.assertEqual(result["table"]["rows"][1][0], "2007-02-14")

    def test_title_rows_case_and_footer(self):
        row = ["2026-08-01", "Example Person", 123456, "Operation", "", "", "", ""]
        result = read_tables([{"rows": [
            ["My surgical log"] + [""] * 7,
            [name.lower() for name in HEADERS], row, ["Total"] + [""] * 7,
        ], "footers": 1}])
        self.assertEqual(result["table"]["headerRow"], 2)
        self.assertEqual(len(result["table"]["rows"]), 2)
        self.assertEqual(result["table"]["rows"][1][2], "123456")

    def test_no_matching_table(self):
        result = read_tables([{"rows": [["Unrelated", "Table"]]}])
        self.assertIn("No surgical log table", result["error"])
        self.assertTrue(result["closed"])

    def test_ambiguous_tables(self):
        result = read_tables([{"rows": [HEADERS]}, {"rows": [HEADERS]}])
        self.assertIn("More than one surgical log table", result["error"])
        self.assertTrue(result["closed"])

    def test_duplicate_header_rejected(self):
        result = read_tables([{"rows": [HEADERS + ["ID"]]}])
        self.assertIn("Duplicate column", result["error"])

    def test_preview_does_not_write_until_commit(self):
        preview_path = SOURCE.split("private func performPreview", 1)[1].split(
            "private func performCommit", 1
        )[0]
        self.assertNotIn("storeSurgicalProcedureRecordPayloads", preview_path)
        self.assertNotIn("storePayloads(", preview_path)
        self.assertNotIn("importProcedures(", preview_path)

    def test_commit_reuses_the_established_import_path(self):
        self.assertIn("private func payload(", SOURCE)
        self.assertIn("private func storePayloads(", SOURCE)
        self.assertIn("private func importProcedures(", SOURCE)
        self.assertIn("try storePayloads(payloads, databaseBasePath: databaseBasePath)", SOURCE)
        self.assertIn("candidate.record == expected.record", SOURCE)
        self.assertIn("candidate.path == expected.path", SOURCE)
        self.assertIn("surgicalProcedureSourceStamp(preview.sourceURL) == preview.sourceStamp", SOURCE)
        self.assertIn("if action == .add || action == .update", SOURCE)
        self.assertIn("SQLITE_OPEN_READONLY", SOURCE)
        self.assertIn("procedure.patientKey", SOURCE)
        self.assertIn("SurgicalProcedureImportLastNumbersBookmark", SOURCE)

    def test_provenance_does_not_trigger_update(self):
        comparison = SOURCE.split("private func procedureFields", 1)[1].split("private func previewProcedures", 1)[0]
        for provenance in ("anchorStudyInstanceUID", "sourceFile", "sourceRow", "sourceFingerprint",
                           "matchedPatientName", "matchedPatientID"):
            self.assertNotIn(provenance, comparison)
        for material in ("procedureDate", "operation", "diagnosis", "results", "optics", "assistants"):
            self.assertIn(material, comparison)

    def test_update_classification_uses_only_displayed_changes(self):
        preview = SOURCE.split("private func previewProcedures", 1)[1].split("@MainActor", 1)[0]
        self.assertIn("let changes = zip(previous, fields).filter", preview)
        self.assertIn("if changes.isEmpty", preview)
        self.assertIn("bySourceRow[procedure.sourceRow]", preview)


if __name__ == "__main__":
    unittest.main()
