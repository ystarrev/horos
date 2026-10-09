"""Non-build regression checks for surgery database row presentation."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Horos/Sources"


class SurgeryRowDisplayTests(unittest.TestCase):
    def test_columns_and_patient_name_preferences(self):
        source = (ROOT / "SurgicalProcedureTimeline.swift").read_text()
        display = source.split("func displayValue(forColumnIdentifier", 1)[1].split("func detailsHTML", 1)[0]
        self.assertNotIn("return displayTitle", display)
        self.assertIn('bool(forKey: "HIDEPATIENTNAME")', display)
        self.assertIn('bool(forKey: "CapitalizedString")', display)
        self.assertIn('name.replacingOccurrences(of: "^", with: " ")', display)
        self.assertIn('case "studyName", "seriesDescription": return studyName', display)
        self.assertIn("var studyName: String { operation }", source)
        self.assertIn('("Diagnosis", diagnosis)', source)

    def test_surgery_color_remains_without_name_icon(self):
        source = (ROOT / "BrowserController.m").read_text()
        drawing = source.split("willDisplayCell:", 1)[1].split("@try", 1)[0]
        self.assertIn("[NSColor systemOrangeColor]", drawing)
        self.assertNotIn("cross.case.fill", drawing)

    def test_surgery_patient_query_uses_event_identity(self):
        source = (ROOT / "BrowserController.m").read_text()
        query = source.split("- (IBAction)querySelectedStudy:", 1)[1].split("- (void)queryDICOM:", 1)[0]
        self.assertIn("[sender representedObject]", query)
        self.assertIn("isSurgicalProcedureItem:item", query)
        self.assertIn("event.patientID", query)
        self.assertIn("event.name", query)
        self.assertIn("openPatientQueryWithID:patientID name:name", query)
        self.assertIn("patientID.length == 0 && name.length == 0", query)
        self.assertIn("patientQueryItem.representedObject = [databaseOutline itemAtRow:patientQueryRow]", source)

    def test_double_click_opens_associated_imaging(self):
        source = (ROOT / "BrowserController.m").read_text()
        double_click = source.split("- (IBAction)databaseDoublePressed:", 1)[1].split(
            "- (BOOL)outlineView:", 1)[0]
        self.assertIn("[self openMetalViewerForSurgicalProcedure:item]", double_click)
        opening = source.split("- (void)openMetalViewerForSurgicalProcedure:", 1)[1].split(
            "- (void)openMetalViewerForDatabaseObject:", 1)[0]
        self.assertIn("event.backingStudyXID", opening)
        self.assertIn("self.database objectWithID:[NSManagedObject UidForXid:event.backingStudyXID]", opening)
        self.assertNotIn("NSManagedObjectID *studyID = [NSManagedObject UidForXid:", opening)
        self.assertIn("studiesForDisplayOnlyThisPatientMatchingStudy:backingStudy", opening)
        self.assertIn("childrenArray:study onlyImages:YES", opening)
        self.assertIn("isDICOMSegmentationSeries:series", opening)
        self.assertIn("NSMutableOrderedSet", opening)
        self.assertIn("openMetalViewerForImages:images.array", opening)
        self.assertIn('NSLocalizedString(@"No associated images"', opening)


if __name__ == "__main__":
    unittest.main()
