"""Non-build regression checks for optical-media copy routing."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Horos/Sources/DicomDatabase.mm").read_text()
COPY = DATABASE.split("-(void)copyFilesThread:", 1)[1]
BROWSER = (ROOT / "Horos/Sources/BrowserController.m").read_text()


class OpticalImportTests(unittest.TestCase):
    def test_folder_import_detects_optical_media_before_selecting_batch_size(self):
        self.assertIn('strcmp(info.f_fstypename, "cd9660")', COPY)
        self.assertIn('strcmp(info.f_fstypename, "udf")', COPY)
        self.assertLess(COPY.index("mountedVolume |= opticalVolumes.count > 0"),
                        COPY.index("BOOL preferLargerIndexingBatches"))
        self.assertIn("[checkedVolumes containsObject:volume]", COPY)

    def test_filter_is_per_optical_source_and_precedes_destination_allocation(self):
        filtering = COPY.index("if (copyFiles && opticalSource &&")
        self.assertLess(filtering, COPY.index("dstPath = [self uniquePath"))
        self.assertIn("!HorosIsDICOMCopyCandidate(srcPath)", COPY)
        self.assertIn("![dicomDictionariesByPath objectForKey:srcPath.stringByStandardizingPath]", COPY)
        self.assertIn('isEqualToString:@"DICOMDIR."', COPY)

    def test_deduplication_survives_optical_sort(self):
        self.assertIn("NSOrderedSet orderedSetWithArray:filesInput", COPY)
        self.assertIn("filesInput = [filesInput sortedArrayUsingSelector:@selector(localizedStandardCompare:)]", COPY)

    def test_header_fast_path_preserves_raw_dataset_fallback(self):
        helper = DATABASE.split("static BOOL HorosIsDICOMCopyCandidate", 1)[1].split("static BOOL HorosCopyFileData", 1)[0]
        self.assertIn("unsigned char header[132]", helper)
        self.assertIn('memcmp(header + 128, "DICM", 4)', helper)
        self.assertIn("count == sizeof(header)", helper)
        self.assertIn("n < 0 && errno == EINTR", helper)
        self.assertIn("return [DicomFile isDICOMFile:path]", helper)

    def test_dicomdir_avoids_recursive_copy_and_header_probe(self):
        route = BROWSER.split("- (void) addFilesAndFolderToDatabase:(NSArray*) filenames options:", 1)[1].split("-(NSArray*) addURLToDatabaseFiles", 1)[0]
        self.assertLess(route.index("referencedFilesInDICOMDIR:index"), route.index("enumeratorAtPath: filename"))
        self.assertIn('[copyOptions setObject:dicomdirReferencedPaths forKey:@"dicomdirReferencedPaths"]', route)
        self.assertLess(COPY.index("![dicomdirReferencedPaths containsObject:srcPath]"), COPY.index("!HorosIsDICOMCopyCandidate(srcPath)"))
        scan = (ROOT / "Horos/Sources/DicomDatabase+Scan.mm").read_text()
        reader = scan.split("+(NSArray*)referencedFilesInDICOMDIR:", 1)[1].split("return files.count ? files.array : nil;", 1)[0]
        self.assertIn("DCM_DirectoryRecordSequence", reader)
        self.assertIn("DCM_ReferencedFileID", reader)
        self.assertIn("if (inUse == 0) continue", reader)
        self.assertIn("if (!match) return nil", reader)
        self.assertIn("if (![resolved hasPrefix:rootPrefix]) return nil", reader)
        self.assertNotIn("isDICOMFile:", reader)

    def test_activity_icon_blinks_using_cached_rasters(self):
        coordinator = (ROOT / "Horos/Sources/HorosActivityTaskCoordinator.swift").read_text()
        self.assertIn("Timer(timeInterval: 0.5", coordinator)
        self.assertNotIn("image.size =", coordinator)
        self.assertNotIn("badgeLabel", coordinator)
        self.assertIn("guard isActivityDockIconVisible != visible", coordinator)
        self.assertIn("applicationIconImage = regularDockIcon", coordinator)
        self.assertIn("preparedDockSize != size || preparedDockScale != scale", coordinator)
        self.assertIn("NSImage(cgImage: raster, size: size)", coordinator)
        self.assertIn("dockIconTimer?.invalidate()", coordinator)
        self.assertIn('normalDockIcon = NSImage(named: "Horos.icns")', coordinator)
        self.assertIn("prepareDockIcon(Self.normalDockIcon", coordinator)
        self.assertIn("NSSize(width: 128, height: 128)", coordinator)
        self.assertIn("preparedRegularDockIcon ?? Self.normalDockIcon", coordinator)

    def test_non_sr_studies_skip_description_lookup(self):
        method = BROWSER.split("- (BOOL)isSurgicalProcedureStudy:", 1)[1].split("- (NSArray *)", 1)[0]
        self.assertLess(method.index("return NO;", method.index("NSString *modality")),
                        method.index("NSString *studyDescription"))


if __name__ == "__main__":
    unittest.main()
