"""Non-build checks for the database outline's scrolling hot path."""
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/BrowserController.m").read_text()


def method(signature):
    start = SOURCE.index(signature)
    end = SOURCE.index("\n}", start) + 2
    return SOURCE[start:end]


VALUES = method("- (id)intOutlineView:")
CELLS = method("- (void)outlineView: (NSOutlineView *)outlineView willDisplayCell:")


class DatabaseScrollDisplayTests(unittest.TestCase):
    def test_drawing_does_not_probe_or_mutate_reports(self):
        self.assertNotIn("fileExistsAtPath:", CELLS)
        self.assertNotIn("setValue:", CELLS)
        self.assertNotIn("[study reportImage]", VALUES)
        self.assertNotIn("[study reportSRSeries]", VALUES)
        self.assertIn("NSOrderedDescending", VALUES)
        self.assertIn("series.id.intValue != 5003", VALUES)
        self.assertIn('isStructuredReport:series.seriesSOPClassUID', VALUES)

    def test_membership_set_tracks_each_result_refresh(self):
        self.assertIn("_originalOutlineStudies = originalOutlineViewArray ?", SOURCE)
        self.assertIn("[[NSSet alloc] initWithArray:originalOutlineViewArray]", SOURCE)
        self.assertNotIn("[originalOutlineViewArray containsObject:", CELLS)
        self.assertIn("[_originalOutlineStudies containsObject: item]", CELLS)

    def test_series_count_does_not_sort_relationships(self):
        count = VALUES[VALUES.index('isEqualToString:@"noSeries"]') :]
        self.assertIn("displaySeriesWithSOPClassUID:", count)
        self.assertNotIn("sortedArray", count)
        self.assertEqual(count.count('valueForKey:@"imageSeries"'), 1)

    def test_age_cache_is_bounded_and_input_keyed(self):
        self.assertIn("countLimit = 2048", VALUES)
        for dependency in ('@"dateOfBirth"', '@"date"', '(long)mode',
                           'startOfDayForDate:', 'calendar.timeZone.name',
                           'localeIdentifier'):
            self.assertIn(dependency, VALUES)
        self.assertIn("[_databaseAgeDisplayCache release]", SOURCE)

    def test_age_cache_uses_content_hashed_keys(self):
        self.assertIn('NSString *cacheKey = [NSString stringWithFormat:', VALUES)
        self.assertNotIn('NSArray *cacheKey', VALUES)
        self.assertIn('birthDate.timeIntervalSinceReferenceDate', VALUES)
        self.assertIn('studyDate.timeIntervalSinceReferenceDate', VALUES)

    def test_outline_uses_composited_scrolling_without_custom_scroll_events(self):
        outline = (ROOT / "Horos/Sources/MyOutlineView.m").read_text()
        self.assertIn("self.enclosingScrollView.wantsLayer = YES", outline)
        self.assertIn("self.wantsLayer = YES", outline)
        self.assertNotIn("scrollWheel:", outline)

    def test_changed_callbacks_typecheck(self):
        # Check the actual callback bodies against AppKit; no app build or link.
        declarations = r'''
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define DISTANTSTUDYFONT @"Helvetica"
#define N2LogExceptionWithStackTrace(e) ((void)0)
@interface NSObject (TestModel)
- (BOOL)isDistant;
- (BOOL)isLocal;
- (id)displayValueForColumnIdentifier:(id)identifier;
@end
@interface DicomImage : NSObject
@end
@interface DicomSeries : NSObject
@property(retain) NSNumber *id;
@property(retain) NSString *name;
@property(retain) NSString *seriesSOPClassUID;
@property(retain) NSSet *images;
@end
@interface DicomStudy : NSObject
@property(retain) NSSet *series;
+ (BOOL)displaySeriesWithSOPClassUID:(NSString *)uid andSeriesDescription:(NSString *)name;
@end
@interface DCMAbstractSyntaxUID : NSObject
+ (BOOL)isStructuredReport:(NSString *)uid;
@end
@interface ImageAndTextCell : NSTextFieldCell
- (void)setImage:(NSImage *)image;
- (void)setLastImage:(NSImage *)image;
@end
@interface ScrollTestController : NSWindowController {
    NSArray *originalOutlineViewArray;
    NSSet *_originalOutlineStudies;
    NSCache *_databaseAgeDisplayCache;
    id _database, previousItem;
}
- (BOOL)isSurgicalProcedureItem:(id)item;
- (CGFloat)fontSize:(NSString *)key;
- (BOOL)study:(id)study matchesSamePatientAsStudy:(id)other;
@end
@implementation ScrollTestController
'''
        result = subprocess.run(
            ["xcrun", "clang", "-x", "objective-c", "-fsyntax-only", "-fblocks",
             "-Wno-incomplete-implementation", "-"],
            input=declarations + VALUES + "\n" + CELLS + "\n@end\n",
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
