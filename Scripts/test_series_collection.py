#!/usr/bin/env python3
"""Source-level checks for migration-free series collections."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ALBUM = (ROOT / "Horos/Sources/DicomAlbum.m").read_text()
BROWSER = (ROOT / "Horos/Sources/BrowserController.m").read_text()
DATABASE = (ROOT / "Horos/Sources/DicomDatabase.mm").read_text()
MENU = (ROOT / "Horos/Resources/Base.lproj/MainMenu.xib").read_text()


class SeriesCollectionTests(unittest.TestCase):
    def test_type_and_membership_are_separate_from_study_albums(self):
        self.assertIn('horos:series-collection:v1:', ALBUM)
        self.assertIn('!self.smartAlbum.boolValue', ALBUM)
        self.assertIn('series.seriesInstanceUID.length ? series.seriesInstanceUID', ALBUM)
        self.assertIn('self.predicateString = [HorosSeriesCollectionPrefix', ALBUM)
        self.assertIn('[self addStudiesObject:series.study]', ALBUM)
        self.assertIn('[self removeStudiesObject:series.study]', ALBUM)

    def test_drop_routes_only_collections_to_series_membership(self):
        self.assertIn('action:@selector(addSeriesCollection:)', BROWSER)
        self.assertIn('selector="addSeriesCollection:"', MENU)
        self.assertIn('[album addSeriesToCollection:item]', BROWSER)
        self.assertIn('[_database addStudies:studies toAlbum:album]', BROWSER)

    def test_view_and_open_use_only_member_series(self):
        self.assertIn('seriesCollectionSeriesForStudy:item onlyImages:YES', BROWSER)
        self.assertIn('seriesCollectionSeriesForStudy:(DicomStudy*)curObj onlyImages:onlyImages', BROWSER)
        self.assertIn('matrixViewArray = [[self seriesCollectionSeriesForStudy:item onlyImages:YES] retain]', BROWSER)

    def test_export_and_import_preserve_type(self):
        self.assertIn('[entry setObject:[album seriesCollectionKeys] forKey:@"seriesCollectionKeys"]', DATABASE)
        self.assertIn('[a setSeriesCollectionKeys:seriesCollectionKeys]', DATABASE)
        self.assertIn('else if (![a isSeriesCollection])', DATABASE)

    def test_explicit_scan_has_persisted_filters_and_respects_manual_removals(self):
        self.assertIn('horos:series-collection:v2:', ALBUM)
        self.assertIn('HorosSeriesCollectionPrefixV1', ALBUM)
        self.assertIn('[self setSeriesCollectionExcludedKeys:excluded]', ALBUM)
        self.assertIn('updateSeriesCollection:', BROWSER)
        self.assertIn('promptForSeriesCollectionCriteria:', BROWSER)
        self.assertIn('minimumSlices', BROWSER)
        self.assertIn('HorosSeriesCollectionMatchesWeighting', BROWSER)
        self.assertIn('HorosSeriesCollectionSliceCount', BROWSER)
        self.assertIn('if (!key.length || [excluded containsObject:key]) continue;', BROWSER)
        self.assertIn('seriesCollectionCriteria', DATABASE)
        self.assertIn('seriesCollectionExcludedKeys', DATABASE)


if __name__ == "__main__":
    unittest.main()
