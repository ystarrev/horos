"""Source guards for legacy ROI archive decoding; no build or patient data access."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
METAL = ROOT / "Horos/Sources/MetalViewer"


class LegacyROIArchiveTests(unittest.TestCase):
    def test_version_16_consumes_all_four_extension_objects(self):
        source = (ROOT / "Horos/Sources/ROI.m").read_text()
        decoder = source.split("- (instancetype)initWithCoder:", 1)[1].split("- (void)encodeWithCoder:", 1)[0]
        extension = re.search(r"if \(fileVersion >= 16\)\s*\{(.*?)\}", decoder, re.S)
        self.assertIsNotNone(extension)
        self.assertEqual(extension[1].count("[coder decodeObject]"), 4)
        self.assertLess(decoder.index("fileVersion >= 15"), extension.start())

    def test_writer_keeps_version_11_format(self):
        source = (ROOT / "Horos/Sources/ROI.m").read_text()
        self.assertRegex(source, r"#define ROIVERSION 11\b")
        writer = source.split("- (void)encodeWithCoder:", 1)[1].split("- (id)copyWithZone:", 1)[0]
        self.assertIn("[ROI setVersion:ROIVERSION]", writer)
        self.assertNotIn("fileVersion", writer)


class LegacyROIContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = (METAL / "MetalLegacyROISRBridge.mm").read_text()
        cls.exporter = (METAL / "HorosPhoneVolumeExporter.swift").read_text()
        signature = "+ (NSArray<NSDictionary<NSString *, id> *> *)sourceRecordsForPixList:(NSArray *)pixList context:(NSManagedObjectContext *)context\n{"
        cls.lookup = cls.bridge.split(signature, 1)[1].split("+ (DicomImage *)imageForPix:", 1)[0]

    def test_phone_export_passes_its_source_context(self):
        self.assertIn("guard let context = seriesObject.managedObjectContext", self.exporter)
        self.assertIn("roiDictionaries(forPixList: sortedPixels, context: context)", self.exporter)
        self.assertNotIn("roiDictionaries(forPixList: sortedPixels)", self.exporter)
        copy_source = (ROOT / "Horos/Sources/BrowserController+Sources+Copy.m").read_text()
        phone = copy_source.split("-(void)copyImagesToPhoneVolumeRenderThread:", 1)[1].split(
            "-(void)copyRemoteImagesToLocalBrowserSourceThread:", 1)[0]
        self.assertIn("DicomDatabase* database = [io[2] independentDatabase]", phone)
        self.assertLess(phone.index("N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext"),
                        phone.index("[exporter writeImages:[database objectsWithIDs:"))

    def test_lookup_resolves_ids_on_the_supplied_context_queue(self):
        self.assertNotIn("imageForPix:", self.lookup)
        self.assertNotIn("imageObj", self.lookup.replace("imageObjectID", ""))
        self.assertNotIn("currentBrowser", self.lookup)
        queue = self.lookup.index("N2PerformManagedObjectContextBlockAndWait(context")
        resolve = self.lookup.index("[context existingObjectWithID:objectID error:nil]")
        self.assertLess(queue, resolve)
        self.assertLess(resolve, self.lookup.index("image.series.study"))
        self.assertIn("NSManagedObjectID *objectID = pix.imageObjectID", self.lookup)

    def test_lookup_skips_invalid_images_and_preserves_exact_frame_matching(self):
        self.assertIn("pixList.count == 0 || context == nil", self.lookup)
        self.assertIn("objectID == nil || objectID.isTemporaryID", self.lookup)
        self.assertIn("image == nil || image.isDeleted", self.lookup)
        self.assertIn("if (imageStudy != study)", self.lookup)
        self.assertIn("NSInteger frame = image.frameID.integerValue", self.lookup)
        self.assertIn('stringByAppendingFormat:@"-%ld", (long)frame', self.lookup)
        self.assertIn('stringByAppendingString:@"-0"', self.lookup)
        self.assertIn('@"sliceIndex": sliceIndex', self.lookup)

    def test_roi_file_decoding_stays_outside_the_context_lookup(self):
        self.assertNotIn("roiArrayAtPath:", self.lookup)
        explicit = self.bridge.split("context:(NSManagedObjectContext *)context\n{", 1)[1].split(
            "+ (NSArray<NSDictionary<NSString *, id> *> *)roiDictionariesForSourceRecords:", 1)[0]
        self.assertIn("sourceRecordsForPixList:pixList context:context", explicit)
        self.assertIn("return [self roiDictionariesForSourceRecords:sourceRecords]", explicit)
        self.assertNotIn("dispatch_get_main_queue", explicit)
        self.assertNotIn("imageForPix:", explicit)
        decode = self.bridge.split("roiDictionariesForSourceRecords:(NSArray<NSDictionary<NSString *, id> *> *)sourceRecords\n{", 1)[1].split(
            "+ (NSArray<NSDictionary<NSString *, id> *> *)sourceRecordsForPixList:", 1)[0]
        self.assertIn("[self roiArrayAtPath:path]", decode)
        self.assertNotIn("NSManagedObject", decode)

    def test_existing_readers_and_thread_misuse_warning_are_retained(self):
        self.assertIn("[self sourceRecordsForPixList:pixList]", self.bridge)
        self.assertIn("return [self sourceRecordsForPixList:pixList context:context]", self.bridge)
        seed_reader = (METAL / "MetalTumourSeedSRBridge.mm").read_text()
        self.assertIn("[MetalLegacyROISRBridge sourceRecordsForPixList:pixList]", seed_reader)
        pix = (ROOT / "Horos/Sources/DCMPix.m").read_text()
        self.assertIn("warning this object should be used only on the main thread", pix)


if __name__ == "__main__":
    unittest.main()
