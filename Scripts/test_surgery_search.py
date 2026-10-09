"""Non-build regression checks for the surgery search integration."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BROWSER = (ROOT / "Horos/Sources/BrowserController.m").read_text()
TIMELINE = (ROOT / "Horos/Sources/SurgicalProcedureTimeline.swift").read_text()


class SurgerySearchTests(unittest.TestCase):
    def test_words_match_across_both_fields(self):
        matcher = TIMELINE.split("class func events(_ events:", 1)[1].split(
            "@objc(eventsForSurgicalProcedureStudies:)", 1)[0]
        self.assertIn("$0.isWhitespace", matcher)
        self.assertIn("words.allSatisfy", matcher)
        self.assertIn("event.operation.range", matcher)
        self.assertIn("event.diagnosis.range", matcher)
        self.assertIn(".diacriticInsensitive", matcher)
        self.assertNotIn("event.name", matcher)

    def test_menu_and_local_only_search(self):
        self.assertIn('initWithTitle:NSLocalizedString(@"Surgeries"', BROWSER)
        self.assertIn("curSearchType == HorosSurgerySearchType", BROWSER)
        self.assertIn("useDistantArray && searchType != HorosSurgerySearchType", BROWSER)
        self.assertIn("searchType != HorosSurgerySearchType && filtered == YES", BROWSER)

    def test_cache_and_unlimited_results(self):
        method = BROWSER.split("- (NSArray *)arrayByPresentingSurgicalProcedureStudies:", 1)[1]
        search = method.split("if( items.count == 0)", 1)[0]
        self.assertIn("modification != _surgerySearchDatabaseModification", search)
        self.assertIn("if (studyEvents == nil)", search)
        self.assertIn("matchingWords:_searchString", search)
        self.assertNotIn("500", search)


if __name__ == "__main__":
    unittest.main()
