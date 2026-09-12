"""Source-contract checks for database file promises; no build or database access."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/BrowserController.m").read_text()
HEADER = (ROOT / "Horos/Sources/BrowserController.h").read_text()
SOURCES = (ROOT / "Horos/Sources/BrowserController+Sources.m").read_text()
PROVIDER = SOURCE.split("@implementation BrowserFilePromise", 1)[1].split("@end", 1)[0]
OUTLINE = SOURCE.split("pasteboardWriterForItem:(id)item", 1)[1].split("- (id<NSPasteboardWriting>)filePromiseForDatabaseObjects:", 1)[0]
DRAG = SOURCE.split("- (id<NSPasteboardWriting>)filePromiseForDatabaseObjects:", 1)[1].split("- (id<NSPasteboardWriting>)filePromiseForJPEGData:", 1)[0]
MATRIX = (ROOT / "Horos/Sources/BrowserMatrix.m").read_text()
MOUSE_DOWN = MATRIX.split("- (void) mouseDown:", 1)[1].split("- (void) rightMouseDown:", 1)[0]
WRITE = SOURCE.split("- (void)writeDatabaseFilePromise:(NSMutableDictionary *)parameters\n", 1)[1].split("- (void)outlineViewItemWillCollapse:", 1)[0]
JPEG_WRITE = SOURCE.split("- (NSError *)writeJPEGImages:", 2)[2].split("- (NSError *)writeReportFileExports:", 1)[0]
PDF_WRITE = SOURCE.split("- (NSError *)writeReportFileExports:", 2)[2].split("- (void)writeDatabaseFilePromise:", 1)[0]
REPORT_KIND = SOURCE.split("+ (BOOL)isReportSeriesForFileExport:", 1)[1].split("- (id<NSPasteboardWriting>)outlineView:", 1)[0]
READER = SOURCE.split("+ (NSArray<NSString *> *)databaseObjectXIDsFromPasteboard:", 1)[1].split("- (BOOL)tableView:", 1)[0]
EXPORT = SOURCE.split("- (NSArray*)exportDICOMFileIntOnContextQueue:", 1)[1].split("+ (void) encryptFiles:", 1)[0]


class FilePromiseTests(unittest.TestCase):
    def test_legacy_promise_callbacks_are_gone(self):
        for token in ("NSFilesPromisePboardType", "namesOfPromisedFilesDroppedAtDestination:",
                      "writeItems:(NSArray *)pbItems", "avoidRecursive"):
            self.assertNotIn(token, SOURCE + HEADER)

    def test_folder_promise_keeps_internal_object_identity(self):
        self.assertIn("NSFilePromiseProvider <NSFilePromiseProviderDelegate>", SOURCE)
        self.assertIn("self.fileType = UTTypeFolder.identifier", PROVIDER)
        self.assertIn("[super writableTypesForPasteboard:pasteboard]", PROVIDER)
        self.assertIn("return self.objectXIDs", PROVIDER)
        self.assertIn("[xids addObject:[item XID]]", DRAG)

    def test_drag_start_does_not_load_all_images_or_write_files(self):
        self.assertIn('@"rootObjectIDs": [objects valueForKey:@"objectID"]', DRAG)
        self.assertIn('@"database": self.database', DRAG)
        for token in ("sortedImages", "completePath", "copyItem", "createDirectory", "sleepForTimeInterval"):
            self.assertNotIn(token, DRAG)

    def test_promises_capture_export_preferences(self):
        for key in ("folderTreeTag", "compressionTag", "addDICOMDIR", "encrypt", "password"):
            self.assertIn(f'@"{key}"', DRAG)
            self.assertIn(f'parameters[@"{key}"]', EXPORT)

    def test_parent_and_selected_series_are_not_exported_twice(self):
        self.assertIn("[outlineView parentForItem:item]", OUTLINE)
        self.assertIn("[outlineView isRowSelected:parentRow]", OUTLINE)

    def test_surgical_records_resolve_to_their_database_object(self):
        self.assertIn("isSurgicalProcedureItem:item", DRAG)
        self.assertIn("[NSManagedObject UidForXid:[item XID]]", DRAG)
        self.assertIn("childrenArray:object onlyImages:NO", WRITE)

    def test_export_is_on_an_activity_thread_with_its_own_context(self):
        self.assertIn("newActivityThreadWithTarget:self selector:@selector(writeDatabaseFilePromise:)", DRAG)
        self.assertIn('[parameters[@"database"] independentDatabase]', WRITE)
        self.assertIn("N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext", WRITE)
        self.assertIn('objectsWithIDs:parameters[@"rootObjectIDs"]', WRITE)
        self.assertNotIn("filesForDatabaseOutlineSelection", WRITE)
        self.assertNotIn("self.database", WRITE)

    def test_remote_images_are_downloaded_from_captured_database(self):
        self.assertIn("[(RemoteDicomDatabase *)database cacheDataForImage:image", WRITE)
        self.assertNotIn("getLocalDCMPath", WRITE)

    def test_export_reuses_existing_dicom_exporter(self):
        self.assertIn("exportDICOMFileIntOnContextQueue:parameters database:database", WRITE)
        self.assertIn("[idatabase processFilesAtPaths:", EXPORT)
        self.assertNotIn("[_database processFilesAtPaths:", EXPORT)

    def test_success_is_published_only_after_export(self):
        self.assertIn("NSItemReplacementDirectory", WRITE)
        export = WRITE.index("exportDICOMFileIntOnContextQueue:")
        check = WRITE.index('error = parameters[@"exportError"]', export)
        publish = WRITE.index("moveItemAtURL:staging toURL:destination", check)
        completion = WRITE.index("completion(resultError)")
        self.assertLess(export, check)
        self.assertLess(check, publish)
        self.assertLess(publish, completion)
        self.assertIn("removeItemAtURL:staging", WRITE)
        self.assertNotIn("removeItemAtURL:destination", WRITE)
        self.assertIn("NSFileWriteFileExistsError", WRITE)

    def test_cancellation_uses_original_activity_thread(self):
        self.assertIn('parameters[@"activityThread"] = activityThread', WRITE)
        self.assertIn('NSThread *activityThread = parameters[@"activityThread"]', EXPORT)
        self.assertIn("activityThread.isCancelled", WRITE)
        self.assertIn("activityThread.isCancelled", EXPORT)
        self.assertIn("activityThread.progress", EXPORT)
        self.assertIn('[parameters removeObjectForKey:@"activityThread"]', WRITE)

    def test_encrypted_drag_rejects_missing_password(self):
        self.assertIn('[parameters[@"encrypt"] boolValue] && [parameters[@"password"] length] == 0', WRITE)
        self.assertIn("password: exportPassword", EXPORT)
        self.assertIn('if (!parameters[@"password"])', EXPORT)

    def test_copy_failures_and_exceptions_propagate(self):
        self.assertGreaterEqual(EXPORT.count('parameters[@"exportError"] ='), 3)
        self.assertIn("completion(resultError)", WRITE)
        self.assertEqual(WRITE.count("completion(resultError)"), 1)

    def test_multiselection_reader_handles_old_and_new_pasteboards(self):
        self.assertIn("for (NSPasteboardItem *item in pasteboard.pasteboardItems)", READER)
        self.assertIn("NSMutableOrderedSet", READER)
        self.assertIn("[values isKindOfClass:[NSData class]]", READER)
        self.assertIn("[values isKindOfClass:[NSArray class]]", READER)
        self.assertIn("[value isKindOfClass:[NSString class]]", READER)
        self.assertIn("[BrowserController databaseObjectXIDsFromPasteboard:pb]", SOURCE)
        self.assertIn("[BrowserController databaseObjectXIDsFromPasteboard:pb]", SOURCES)

    def test_legacy_archive_reading_and_writing_are_preserved(self):
        compatibility = (ROOT / "Horos/Sources/HorosUnkeyedArchiveCompatibility.h").read_text()
        self.assertIn("HorosArchiveUnkeyedObject(id object)", compatibility)
        self.assertIn("HorosUnarchiveUnkeyedObject(NSData *data)", compatibility)
        self.assertNotIn("HorosArchiveUnkeyedObjectToFile", compatibility)
        self.assertNotIn("HorosUnarchiveUnkeyedObjectFromFile", compatibility)

    def test_thumbnails_use_the_same_dicom_export_path(self):
        self.assertIn("filePromiseForDatabaseObjects:objects", MATRIX)
        self.assertIn("cell.isEnabled && cell.tag >= 0 && cell.tag < matrixObjects.count", MATRIX)
        self.assertNotIn("fourSeconds", MATRIX)
        self.assertNotIn("PasteboardCopyPasteLocation", MATRIX)
        self.assertNotIn("kPasteboardTypeFileURLPromise", MATRIX)
        self.assertIn("[selectedImages addObject:object]", WRITE)

    def test_thumbnail_drag_starts_on_movement_without_a_hold_timer(self):
        self.assertIn("NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged", MOUSE_DOWN)
        self.assertIn("dx * dx + dy * dy < 16.0", MOUSE_DOWN)
        self.assertIn("[self startDrag:nextEvent]", MOUSE_DOWN)
        for token in ("Periodic", "timeIntervalSinceNow", "keepOn", "[super mouseDown:nextEvent]"):
            self.assertNotIn(token, MOUSE_DOWN)

    def test_native_clicks_keep_original_event_and_queued_mouse_up(self):
        self.assertIn("dequeue:NO", MOUSE_DOWN)
        mouse_up = MOUSE_DOWN.index("nextEvent.type == NSEventTypeLeftMouseUp")
        native_click = MOUSE_DOWN.index("[super mouseDown:event]", mouse_up)
        dequeue = MOUSE_DOWN.index("dequeue:YES", mouse_up)
        self.assertLess(native_click, dequeue)
        self.assertIn("event.clickCount > 1", MOUSE_DOWN)
        self.assertIn("NSEventTrackingRunLoopMode", MOUSE_DOWN)

    def test_drag_preserves_selected_group_and_selects_unselected_thumbnail(self):
        self.assertIn("if (![self.selectedCells containsObject:cell])", MOUSE_DOWN)
        self.assertLess(MOUSE_DOWN.index("[self selectCellEvent:event]"), MOUSE_DOWN.index("[self startDrag:nextEvent]"))
        selection = MATRIX.split("- (void) selectCellEvent:", 1)[1].split("- (void) startDrag:", 1)[0]
        self.assertIn("self.selectedCells.count > 0", selection)
        self.assertNotIn("isHighlighted", selection)

    def test_jpeg_shortcut_exports_clicked_frame_not_first_of_old_selection(self):
        self.assertIn("NSEventModifierFlagOption", MOUSE_DOWN)
        self.assertNotIn("NSEventModifierFlagShift", MOUSE_DOWN)
        self.assertIn("[self startDragJPEG:event]", MOUSE_DOWN)
        frame = MATRIX.split("- (void) startDragJPEG:", 1)[1].split("- (void) mouseDown:", 1)[0]
        self.assertIn("[self cellAtRow:row column:column]", frame)
        self.assertIn("[self selectCellAtRow:row column:column]", frame)
        self.assertNotIn("[[self selectedCells] objectAtIndex: 0]", frame)

    def test_frame_jpeg_is_captured_before_drag_and_not_overwritten(self):
        self.assertIn("filePromiseForJPEGData:jpeg name:name", MATRIX)
        frame = MATRIX.split("- (void) startDragJPEG:", 1)[1].split("- (void) mouseDown:", 1)[0]
        self.assertLess(frame.index("previewPix:"), frame.index("beginDraggingSessionWithItems:"))
        self.assertIn("promise.fileType = UTTypeJPEG.identifier", SOURCE)
        self.assertIn("NSDataWritingWithoutOverwriting", SOURCE)
        self.assertIn("self.objectXIDs ?", PROVIDER)

    def test_option_drag_chooses_jpeg_for_rows_and_series_thumbnails(self):
        self.assertIn("asJPEG:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0", OUTLINE)
        self.assertNotIn("NSEventModifierFlagShift", OUTLINE)
        self.assertIn("filePromiseForDatabaseObjects:@[selectedObject] asJPEG:YES", MATRIX)
        self.assertIn("filePromiseForDatabaseObjects:items asJPEG:NO", DRAG)
        self.assertIn('@"jpeg": @(jpeg)', DRAG)

    def test_jpeg_promise_is_not_an_internal_dicom_transfer(self):
        self.assertIn("if (!jpeg)\n        promise.objectXIDs =", DRAG)
        self.assertIn('if (!error && !jpeg && [parameters[@"encrypt"] boolValue]', WRITE)
        self.assertRegex(WRITE, r"if \(jpeg\)\s+error = \[self writeJPEGImages:")

    def test_rendered_export_includes_reports_before_resolving_paths(self):
        self.assertIn("return image.isImageStorage.boolValue || [BrowserController isReportSeriesForFileExport:image.series]", WRITE)
        self.assertLess(WRITE.index("return image.isImageStorage.boolValue"), WRITE.index("cacheDataForImage:image"))

    def test_report_types_include_pdf_and_text_but_not_internal_archives(self):
        for token in ("isStructuredReport:", "isPDF:", 'isEqualToString:@"pdf"'):
            self.assertIn(token, REPORT_KIND)
        for name in ("OsiriX ROI SR", "OsiriX Annotations SR", "OsiriX WindowsState SR"):
            self.assertIn(name, REPORT_KIND)
        self.assertNotIn('hasPrefix:@"OsiriX "', REPORT_KIND)

    def test_report_thumbnails_are_never_rasterized_to_jpeg(self):
        frame = MATRIX.split("- (void) startDragJPEG:", 1)[1].split("- (void) mouseDown:", 1)[0]
        self.assertIn("![BrowserController isReportSeriesForFileExport:selectedImage.series]", frame)
        self.assertLess(frame.index("isReportSeriesForFileExport:"), frame.index("previewPix:"))
        self.assertIn("filePromiseForDatabaseObjects:@[selectedObject] asJPEG:YES", frame)

    def test_reports_are_queued_once_per_document_without_expanding_pdf_pages(self):
        self.assertIn("[reportPaths containsObject:paths[index]]", JPEG_WRITE)
        self.assertIn("[reportPaths addObject:paths[index]]", JPEG_WRITE)
        self.assertIn("BOOL expandFrames = !isReport", JPEG_WRITE)
        self.assertIn('Report-%06lu.pdf', JPEG_WRITE)
        self.assertLess(JPEG_WRITE.index("[reportExports addObject:"), JPEG_WRITE.index("initWithPath:paths[index]"))

    def test_pdf_export_preserves_embedded_data_and_uses_existing_sr_renderer(self):
        self.assertIn("encapsulatedPDFForFile:report[@\"path\"]", PDF_WRITE)
        self.assertIn("writePDFForDICOMAtPath:report[@\"path\"] toPath:destination.path", PDF_WRITE)
        self.assertIn('dataWithContentsOfFile:report[@"path"]', PDF_WRITE)
        self.assertIn("document.pageCount > 0", PDF_WRITE)
        self.assertIn("NSDataWritingWithoutOverwriting", PDF_WRITE)
        self.assertIn("activityThread.isCancelled", PDF_WRITE)
        self.assertNotIn("DCMPix", PDF_WRITE)

    def test_report_rendering_releases_context_before_using_main_thread(self):
        end_context = WRITE.index("            });")
        pdf_export = WRITE.index("[self writeReportFileExports:")
        publish = WRITE.index("moveItemAtURL:staging toURL:destination")
        self.assertLess(end_context, pdf_export)
        self.assertLess(pdf_export, publish)
        self.assertNotIn("writePDFForDICOMAtPath:", JPEG_WRITE)
        self.assertNotIn("DicomImage", PDF_WRITE)
        self.assertIn("[error retain]", PDF_WRITE)
        self.assertIn("if (error) return [error autorelease]", PDF_WRITE)

    def test_export_filename_sanitizes_owned_mutable_copy_not_database_name(self):
        copy = JPEG_WRITE.index('[NSMutableString stringWithString:image.series.name ?: @"Series"]')
        sanitize = JPEG_WRITE.index("[BrowserController replaceNotAdmitted:name]")
        self.assertLess(copy, sanitize)
        self.assertNotIn("replaceNotAdmitted:image.series.name", JPEG_WRITE)
        self.assertIn("[name deleteCharactersInRange:NSMakeRange(end, name.length - end)]", JPEG_WRITE)

    def test_export_exceptions_are_caught_inside_database_dispatch_block(self):
        context = WRITE.split("N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{", 1)[1].split("            });", 1)[0]
        self.assertLess(context.index("@try"), context.index("[self writeJPEGImages:"))
        self.assertLess(context.index("[self writeJPEGImages:"), context.index("@catch (NSException *exception)"))
        catch = context.split("@catch (NSException *exception)", 1)[1]
        self.assertIn("resultError = [[NSError errorWithDomain:", catch)
        self.assertIn("removeItemAtURL:staging", WRITE)
        self.assertEqual(WRITE.count("completion(resultError)"), 1)

    def test_jpeg_expands_whole_multiframe_series_without_duplicating_indexed_frames(self):
        self.assertIn("[wholeSeriesIDs containsObject:image.series.objectID]", JPEG_WRITE)
        self.assertIn("image.series.images.count == 1 && image.numberOfFrames.integerValue > 1", JPEG_WRITE)
        self.assertIn("expandFrames ? frame : image.frameID.integerValue", JPEG_WRITE)
        self.assertIn("seriesDirectories[image.series.objectID]", JPEG_WRITE)
        self.assertIn("NSDataWritingWithoutOverwriting", JPEG_WRITE)

    def test_jpeg_uses_full_pixels_windowing_cancellation_and_bounded_memory(self):
        self.assertIn("initWithPath:paths[index]", JPEG_WRITE)
        self.assertIn("image.series.windowWidth.floatValue", JPEG_WRITE)
        self.assertIn("pix.savedWW :pix.savedWL", JPEG_WRITE)
        self.assertIn("!pix.notAbleToLoadImage", JPEG_WRITE)
        self.assertIn("@autoreleasepool", JPEG_WRITE)
        self.assertIn("[error retain];", JPEG_WRITE)
        self.assertIn("if (error) return [error autorelease]", JPEG_WRITE)
        self.assertIn("activityThread.isCancelled", JPEG_WRITE)
        self.assertIn("activityThread.progress", JPEG_WRITE)
        for token in ("NSOpenPanel", "runModal", "self.database", "_database"):
            self.assertNotIn(token, JPEG_WRITE)


if __name__ == "__main__":
    unittest.main()
