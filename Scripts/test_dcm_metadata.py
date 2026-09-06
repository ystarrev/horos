"""Metadata migration source/fixture checks. Does not build or run the reader."""

import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

from test_dcm_extraction import DCMExtractionTests

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


class DCMMetadataTests(DCMExtractionTests):
    def test_controller_no_longer_uses_legacy_parser(self):
        for filename in ("XMLController.m", "XMLController.h"):
            source = (SOURCES / filename).read_text()
            self.assertNotRegex(source, r"\b(?:DCMObject|DCMAttribute|dcmDocument)\b")
        source = (SOURCES / "XMLController.m").read_text()
        self.assertIn("metadataDocumentForFile:srcFile", source)
        self.assertIn("getNIfTIXML:srcFile", source)
        self.assertIn("HorosDICOMMetadataText(xmlDocument)", source)
        self.assertIn("HorosMetadataItemIsReadOnly(item)", source)

    def test_reader_is_single_load_read_only_and_has_no_binary_output(self):
        source = (SOURCES / "ModernDCMTKBridge.cpp").read_text()
        reader = source.split("char* HorosModernDCMTKCopyMetadataXML(", 1)[1].split(
            "char* HorosModernDCMTKCopyField(", 1)[0]
        self.assertEqual(reader.count(".loadFile("), 1)
        self.assertIn("file.writeXML(output, 0)", reader)
        self.assertIn("convertToUTF8()", reader)
        self.assertIn("charset.value.c_str()", reader)
        self.assertIn("findAndDeleteElement(DCM_SpecificCharacterSet", reader)
        for call in ("saveFile(", "chooseRepresentation(", "CopyDecodedFrame("):
            self.assertNotIn(call, reader)
        preparation = source.split("static OFCondition HorosModernDCMTKPrepareMetadataXML", 1)[1].split(
            "char* HorosModernDCMTKCopyMetadataXML", 1)[0]
        for vr in ("OB", "OW", "OF", "OD", "OL", "OV", "UN"):
            self.assertIn("case EVR_" + vr + ":", preparation)
        self.assertIn("element->ident() == EVR_SQ", preparation)
        self.assertIn("depth > 128", preparation)

    def test_editing_warning_distinguishes_preference_from_window_toggle(self):
        source = (SOURCES / "XMLController.m").read_text()
        setter = source.split("- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:", 1)[1].split(
            "- (IBAction) validatorWebSite:", 1)[0]
        self.assertIn("DICOM editing is disabled in Settings.", setter)
        self.assertIn("DICOM editing is allowed in Settings, but is not enabled for this window.", setter)
        self.assertIn("Click Edit in the Meta-Data toolbar, just left of Add", setter)
        self.assertNotIn("Activate DICOM editing to change the values.", setter)
        self.assertIn("isDICOM && self.editingActivated", setter)
        xib = ET.parse(ROOT / "Horos/Resources/Base.lproj/XMLViewer.xib")
        button = xib.find(".//button[@id='54']")
        self.assertIn("in this window", button.attrib["toolTip"])
        self.assertEqual(button.find("connections/action").attrib["selector"], "switchEditing:")

    def test_metadata_edit_snapshots_dates_before_reimport_and_keeps_them_when_regrouping(self):
        source = (SOURCES / "XMLController.m").read_text()
        update = source.split("- (NSArray*) updateDB:", 1)[1].split("- (IBAction) executeAdd:", 1)[0]
        self.assertIn("N2PerformManagedObjectContextBlockAndWait", update)
        self.assertIn("image.completePath.stringByStandardizingPath", update)
        self.assertIn('setObject:image.series.dateAdded forKey:@"series"', update)
        self.assertIn('setObject:image.series.study.dateAdded forKey:@"study"', update)
        self.assertLess(update.index("for (DicomImage *image in objects)"),
                        update.index("rereadFilesAtPaths:files originalDatesAdded:originalDatesAdded"))
        self.assertIn("[self updateDB:files objects:nil originalDatesAdded:originalDatesAdded]", update)
        self.assertNotIn("addFilesAtPaths:", update)

    def test_date_preservation_is_opt_in_not_all_rereads(self):
        source = (SOURCES / "DicomDatabase.mm").read_text()
        path_import = source.split("-(NSArray*)addFilesAtPaths:")[-1].split("-(NSArray*)rereadFilesAtPaths:", 1)[0]
        dictionary_import = source.split("-(NSArray*)addFilesDescribedInDictionaries:")[-1].split(
            "-(NSArray*)addFilesDescribedInDictionariesOnContextQueue:", 1)[0]
        for normal_import in (path_import, dictionary_import):
            self.assertIn("originalDatesAdded:nil", normal_import)
        metadata_import = source.split("-(NSArray*)rereadFilesAtPaths:", 1)[1].split(
            "-(NSArray*)addFilesAtPathsOnContextQueue:", 1)[0]
        for option in ("N2PerformManagedObjectContextBlockAndWait", "rereadExistingItems:YES",
                       "importedFiles:NO", "returnArray:YES", "originalDatesAdded:originalDatesAdded ?: @{}"):
            self.assertIn(option, metadata_import)
        path_parser = source.split("-(NSArray*)addFilesAtPathsOnContextQueue:", 1)[1].split(
            "-(NSArray*)addFilesDescribedInDictionaries:", 1)[0]
        self.assertIn("addFilesDescribedInDictionariesOnContextQueue:dicomFilesArray", path_parser)
        self.assertIn("originalDatesAdded:originalDatesAdded", path_parser)

    def test_importer_preserves_existing_dates_and_inherits_dates_for_new_groups(self):
        source = (SOURCES / "DicomDatabase.mm").read_text()
        importer = source.split("-(NSArray*)addFilesDescribedInDictionariesOnContextQueue:", 1)[1]
        importer = importer.split("[self.managedObjectContext save:NULL]", 1)[0]
        self.assertIn("objectForKey:newFile.stringByStandardizingPath", importer)
        self.assertIn('study.dateAdded = sourceDates ? [sourceDates objectForKey:@"study"] : today;', importer)
        self.assertIn('setValue:sourceDates ? [sourceDates objectForKey:@"series"] : today forKey:@"dateAdded"', importer)
        self.assertRegex(importer, r"if \(originalDatesAdded == nil\)\s+tstudy.dateAdded = today;")
        date_reset = (r"if \(DICOMSR == NO && originalDatesAdded == nil\)\s*\{\s*"
                      r'\[seriesTable setValue:today forKey:@"dateAdded"\];\s*study.dateAdded = today;')
        self.assertEqual(len(re.findall(date_reset, importer)), 2)
        # Cover every date assignment, including the duplicate-image path and empty-study placeholder.
        self.assertEqual(len(re.findall(r'\.dateAdded =|forKey:@"dateAdded"', importer)), 7)

    def test_adapter_uses_xml_parser_and_preserves_multivalue_semantics(self):
        source = (SOURCES / "HorosDICOMMetadata.m").read_text()
        self.assertIn("NSXMLNodeLoadExternalEntitiesNever", source)
        self.assertIn("source.DTD == nil", source)
        self.assertIn('attributeForName:@"vm"', source)
        self.assertIn('integerValue] > 1', source)
        self.assertIn('@"readOnly"', source)
        self.assertIn('@"DICOMObject"', source)
        self.assertIn('@"item"', source)
        self.assertIn('@"number"', source)
        self.assertNotIn("DCMObject", source)

    def test_bridge_and_adapter_are_wired_into_existing_targets(self):
        files = self.target_files("Horos", "PBXSourcesBuildPhase")
        self.assertEqual(files.count("HorosDICOMMetadata.m"), 1)
        header = (SOURCES / "ModernDCMTKBridge.h").read_text()
        self.assertIn("char* HorosModernDCMTKCopyMetadataXML(const char* path, char** failureReason)", header)
        editor = (SOURCES / "XMLControllerDCMTKCategory.mm").read_text()
        self.assertIn("[DicomFile metadataDocumentForFile:path error:error]", editor)
        category = (SOURCES / "DicomFileDCMTKCategory.mm").read_text()
        self.assertIn('"HorosModernDCMTKCopyMetadataXML"', category)
        self.assertIn("freeString(xml)", category)
        self.assertIn("freeString(failure)", category)
        self.assertIn("HorosDICOMMetadataDocument(xmlString, error)", category)

    def test_anonymization_tag_menu_uses_shared_reader_and_keeps_tag_identity(self):
        menu = (SOURCES / "AnonymizationTagsPopUpButton.mm").read_text()
        self.assertNotRegex(menu, r"\b(?:DCMObject|DCMAttribute)\b")
        self.assertIn("[DicomFile metadataDocumentForFile:dicomFile error:&error]", menu)
        self.assertIn("document.rootElement.children sortedArrayUsingComparator:", menu)
        self.assertIn("HorosDICOMMetadataShortValue(attribute)", menu)
        self.assertIn("item.representedObject = tag", menu)
        self.assertIn('tag.vr = [[attribute attributeForName:@"vr"] stringValue]', menu)
        self.assertIn("[DCMTagDictionary sharedTagDictionary]", menu)
        self.assertNotIn("isDICOMFile:", menu)  # No preliminary second file read.

    def test_menu_previews_exclude_binary_sequences_and_large_values(self):
        source = (SOURCES / "HorosDICOMMetadata.m").read_text()
        preview = source.split("NSString *HorosDICOMMetadataShortValue(", 1)[1]
        self.assertIn('attributeForName:@"readOnly"', preview)
        self.assertIn('attributeForName:@"len"', preview)
        self.assertIn('elementsForName:@"value"', preview)
        self.assertIn("preview.length < 100", preview)

    def test_pdf_reader_is_single_load_read_only_and_bounds_checks_payload(self):
        source = (SOURCES / "ModernDCMTKBridge.cpp").read_text()
        reader = source.split("int HorosModernDCMTKCopyEncapsulatedPDF(", 1)[1].split(
            "int HorosModernDCMTKWriteBufferByTag(", 1)[0]
        self.assertEqual(reader.count(".loadFile("), 1)
        for required in ("UID_EncapsulatedPDFStorage", "DCM_EncapsulatedDocumentLength",
                         "documentLength > byteCount", "byteCount - documentLength > 1",
                         "bytes[documentLength] != 0", "std::memcmp(bytes, \"%PDF-\", 5)",
                         "converter.selectCharacterSet(*dataset)", "*buffer = nullptr", "*length = 0"):
            self.assertIn(required, reader)
        for forbidden in ("saveFile(", "chooseRepresentation(", "putAndInsert", "convertToUTF8()"):
            self.assertNotIn(forbidden, reader)

    def test_browser_pdf_paths_use_shared_reader_and_unique_safe_filenames(self):
        source = (SOURCES / "BrowserController.m").read_text()
        self.assertNotIn('attributeValueWithName:@"EncapsulatedDocument"', source)
        self.assertIn("[self temporaryPDFForImage:im]", source)
        self.assertIn("[self temporaryPDFForImage:(DicomImage *)curObj]", source)
        self.assertEqual(source.count("[DicomFile encapsulatedPDFForFile:"), 3)
        helper = source.split('- (NSString *)temporaryPDFForImage:', 1)[1].split(
            '- (BOOL)isUsingExternalViewer:', 1)[0]
        for required in ("lastPathComponent", "NSUUID.UUID.UUIDString", "NSDataWritingAtomic", "filename.length > 120"):
            self.assertIn(required, helper)
        category = (SOURCES / "DicomFileDCMTKCategory.mm").read_text()
        for required in ("freeBuffer(buffer)", "freeString(documentTitle)", "freeString(failure)"):
            self.assertIn(required, category)

    def test_report_menu_and_authoring_actions_are_removed(self):
        menu_path = ROOT / "Horos/Resources/Base.lproj/MainMenu.xib"
        menu = ET.parse(menu_path)
        self.assertIsNone(menu.find(".//menu[@title='Report']"))
        self.assertIsNone(menu.find(".//menuItem[@title='Report']"))
        for path in (menu_path, SOURCES / "BrowserController.h", SOURCES / "BrowserController.m"):
            source = path.read_text()
            for action in ("convertReportToPDF:", "convertReportToDICOMSR:", "generateReport:", "deleteReport:"):
                self.assertNotIn(action, source)

    def test_report_authoring_preferences_watchers_and_writers_are_removed(self):
        pane = ROOT / "Preference Panes/OSIDatabasePreferencePane"
        paths = [SOURCES / name for name in (
            "BrowserController.h", "BrowserController.m", "AppController.m", "DicomStudy.h",
            "DicomStudy.m", "DicomDatabase.h", "DicomDatabase.mm", "SRAnnotation.h", "SRAnnotation.mm",
            "DefaultsOsiriX.m", "Notifications.h", "Notifications.m")]
        paths += [pane / name for name in ("OSIDatabasePreferencePanePref.h", "OSIDatabasePreferencePanePref.m",
                                          "Base.lproj/OSIDatabasePreferencePanePref.xib")]
        for path in paths:
            source = path.read_text()
            for symbol in ("REPORTSMODE", "setReportMode:", "reportFilesToCheck", "syncReportsIfNecessary",
                           "archiveReportAsDICOMSR", "checkReportsConsistencyWithDICOMSR",
                           "checkForExistingReport", "importReport:", "initWithFileReport:",
                           "initWithURLReport:", "OsirixReportModeChangedNotification",
                           "OsirixDeletedReportNotification", "ReportToolbarItemIdentifier"):
                self.assertNotIn(symbol, source, str(path))
        browser = (SOURCES / "BrowserController.m").read_text()
        cleanup = browser.split("- (void)removeForbiddenDatabaseToolbarItems", 1)[1].split(
            "- (void)toolbarDidRemoveItem:", 1)[0]
        self.assertIn('@"Report.icns"', cleanup)  # Retire saved toolbar items too.

    def test_report_template_and_cd_conversion_are_removed_without_dangling_ui_references(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        for filename in ("DicomStudy+Report.h", "DicomStudy+Report.mm"):
            self.assertFalse((SOURCES / filename).exists())
            self.assertNotIn(filename, project)
        self.assertFalse((ROOT / "Binaries/OsiriXReport.template.zip").exists())
        self.assertFalse((ROOT / "Horos/Resources/Icons/ReportRTF.icns").exists())
        self.assertNotIn("ReportRTF.icns", project)
        self.assertNotIn("OsiriXReport.template.zip", (ROOT / "Horos/Scripts/Horos/Unzip.sh").read_text())
        self.assertNotIn("saveReportAsPdf", (SOURCES / "BurnerWindowController.m").read_text())
        for relative in ("Horos/Resources/Base.lproj/BurnViewer.xib", "Horos/Resources/Base.lproj/MainMenu.xib",
                         "Preference Panes/OSIDatabasePreferencePane/Base.lproj/OSIDatabasePreferencePanePref.xib"):
            path = ROOT / relative
            self.assertNotIn("copyReportsToCD", path.read_text())
            tree = ET.parse(path)
            ids = {node.attrib["id"] for node in tree.iter() if "id" in node.attrib}
            for node in tree.iter():
                for key in ("firstItem", "secondItem", "destination", "target"):
                    if key in node.attrib:
                        self.assertIn(node.attrib[key], ids, f"{relative}: {node.attrib}")
        self.target_files("Horos", "PBXSourcesBuildPhase")
        self.target_files("Horos", "PBXHeadersBuildPhase")
        self.target_files("Horos", "PBXResourcesBuildPhase")

    def test_automatic_dicom_pdf_generation_is_removed_but_status_saving_remains(self):
        preferences = ROOT / "Preference Panes/OSIDatabasePreferencePane/Base.lproj/OSIDatabasePreferencePanePref.xib"
        ET.parse(preferences)
        for path in (preferences, SOURCES / "HorosDatabaseNetworkSettings.swift", SOURCES / "DicomStudy.m"):
            self.assertNotIn("generateDICOMPDFWhenValidated", path.read_text())
        study = (SOURCES / "DicomStudy.m").read_text()
        status = study.split("- (void) setStateText:", 1)[1].split("- (void) setReportURL:", 1)[0]
        self.assertIn("savedCommentsAndStatusInDICOMFiles", status)
        self.assertIn("archiveAnnotationsAsDICOMSR", status)
        self.assertIn('setPrimitiveValue: c forKey: @"stateText"', status)
        self.assertNotIn("saveReportAsDicom", status)

    def test_unused_pdf_writers_and_project_references_are_removed(self):
        for filename in ("DicomFileDCMTKCategory.h",
                         "DicomFileDCMTKCategory.mm", "ModernDCMTKBridge.h", "ModernDCMTKBridge.cpp"):
            source = (SOURCES / filename).read_text()
            for symbol in ("transformPdfAtPath", "saveReportAsDicom", "writePDFAtPath",
                           "HorosModernDCMTKCreateDICOMPDF", "DCMEncapsulatedPDF"):
                self.assertNotIn(symbol, source)
        for extension in ("h", "m"):
            self.assertFalse((ROOT / f"Horos/Sources/DCMEncapsulatedPDF.{extension}").exists())
        for path in (ROOT / "Horos.xcodeproj/project.pbxproj",):
            self.assertNotIn("DCMEncapsulatedPDF", path.read_text())
        self.target_files("Horos", "PBXSourcesBuildPhase")  # Resolve all retained build references.
        self.target_files("Horos", "PBXHeadersBuildPhase")

    def test_pacs_report_viewing_printing_and_other_sr_uses_are_retained(self):
        browser = (SOURCES / "BrowserController.m").read_text()
        self.assertIn("[StructuredReportSupport writePDFForDICOMAtPath:", browser)
        self.assertIn("[self temporaryPDFForImage:im]", browser)
        self.assertIn("[DicomFile encapsulatedPDFForFile:", browser)
        self.assertIn("openPDFwithPreview", (SOURCES / "HorosDatabaseNetworkSettings.swift").read_text())
        menu = ET.parse(ROOT / "Horos/Resources/Base.lproj/MainMenu.xib")
        self.assertIsNotNone(menu.find(".//action[@selector='print:']"))
        support = (SOURCES / "StructuredReportSupport.m").read_text()
        self.assertIn("HorosModernDCMTKCopyStructuredReportHTML", support)
        self.assertIn("HorosModernDCMTKWriteSurgicalProcedureStructuredReport", support)
        annotation = (SOURCES / "SRAnnotation.mm").read_text()
        for method in ("initWithContentsOfFile:", "initWithROIs:", "initWithWindowsState:", "initWithDictionary:"):
            self.assertIn(method, annotation)
        study = (SOURCES / "DicomStudy.m").read_text()
        for retained in ("@dynamic reportURL", "@dynamic dictateURL", "reportSRSeries", "archiveAnnotationsAsDICOMSR"):
            self.assertIn(retained, study)

    def test_database_print_is_intercepted_before_nsview_prints_the_table(self):
        for name in ("MyOutlineView.m", "BrowserMatrix.m"):
            source = (SOURCES / name).read_text()
            action = source.split("- (void)print:(id)sender", 1)[1].split("\n- (", 1)[0]
            self.assertIn("self.window.windowController", action)
            self.assertIn("[controller printDatabaseSelection:self]", action)
            self.assertIn("if ([controller isKindOfClass:[BrowserController class]])", action)
            self.assertIn("return;", action)
            self.assertIn("[super print:sender]", action)
            self.assertLess(action.index("printDatabaseSelection:self"), action.index("return;"))
            self.assertLess(action.index("return;"), action.index("[super print:sender]"))
        self.assertIn("System/Library/Frameworks/Quartz.framework", self.target_files("Horos", "PBXFrameworksBuildPhase"))

    def test_database_print_reads_selection_without_importing_or_editing_database(self):
        source = (SOURCES / "BrowserController.m").read_text()
        printing = source.split("- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        for required in ("sender == oMatrix", "[self databaseSelection]", "matrixViewArray[cell.tag]",
                         "DicomStudy class", "DicomSeries class", "DicomImage class", "NSMutableOrderedSet",
                         "isSurgicalProcedureItem:", "candidate.sortedImages", 'sortDescriptorWithKey:@"tag"',
                         "image.completePathResolved", "NSTemporaryDirectory()", "NSUUID.UUID.UUIDString"):
            self.assertIn(required, printing)
        for forbidden in ("filesForDatabaseOutlineSelection:", "filesForDatabaseMatrixSelection:",
                          "addFilesAtPaths:", "setReportURL:", "deleteObject:", "save:", "openPDFwithPreview"):
            self.assertNotIn(forbidden, printing)
        self.assertLess(printing.index("image.completePathResolved"), printing.index("writePDFForDICOMAtPath:"))
        self.assertLess(printing.index("image.frameID"), printing.index("[wait showWindow:self]"))

    def test_report_print_includes_all_pages_and_never_falls_back_on_error_or_cancel(self):
        source = (SOURCES / "BrowserController.m").read_text()
        printing = source.split("- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        for required in ("encapsulatedPDFForFile:", "writePDFForDICOMAtPath:", "dataWithContentsOfFile:",
                         "part.pageCount", "part.allowsPrinting", "insertPage:", "preparedEntries == entries.count",
                         "printOperationForPrintInfo:", "kPDFPrintPageScaleDownToFit", "NSPrintSpoolJob",
                         "operation.jobTitle", "operation.showsPrintPanel = YES", "[operation runOperation]",
                         "@catch (NSException *exception)", "removeItemAtPath:directory"):
            self.assertIn(required, printing)
        self.assertNotIn("return NO;", printing)
        self.assertNotIn("super print:", printing)
        self.assertIn("if (images.count == 0)", printing)
        self.assertIn("if (wait.aborted) return;", printing)

    def test_image_print_uses_full_resolution_windowed_pixels_not_thumbnail_or_table_views(self):
        printing = (SOURCES / "BrowserController.m").read_text().split(
            "- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        for required in ('initWithPath:entry[@"path"]', '[entry[@"frame"] longValue]',
                         "isBonjour:NO imageObj:nil", "[pix CheckLoad]", "!pix.notAbleToLoadImage",
                         "pix.fImage", 'entry[@"windowWidth"]', 'entry[@"windowLevel"]', "pix.savedWW", "pix.savedWL",
                         "[pix checkImageAvailble:width :level]", "pix.baseAddr ? [pix image] : nil",
                         "pix.pixelRatio", "pix.pheight * ratio", "printPDFForImage:rendered pix:pix",
                         "initWithData:pageData", "part.pageCount == 1",
                         "[document insertPage:page atIndex:document.pageCount]"):
            self.assertIn(required, printing)
        for forbidden in ("generateThumbnailImage", "previewPixThumbnails", "printOperationWithView:",
                          "dataWithPDFInsideRect:"):
            self.assertNotIn(forbidden, printing)

    def test_image_print_disables_page_rotation_and_shares_planar_annotations(self):
        printing = (SOURCES / "BrowserController.m").read_text().split(
            "- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        self.assertIn("autoRotate:NO", printing)
        self.assertNotIn("autoRotate:YES", printing)
        pane = (SOURCES / "MetalViewer/MetalViewerPaneView.swift").read_text()
        page = pane.split("private final class AnnotatedPrintImageView", 1)[1].split(
            "private final class MeasurementOverlayView", 1)[0]
        for required in ("AnnotationOverlayView(frame: pageView.bounds)", "AnnotationOverlayView.State(",
                         "pageView.addSubview(annotations)", "pageView.dataWithPDF(inside: pageView.bounds)",
                         "image.draw(in: bounds", "respectFlipped: true", "rotationAngleDegrees: 0",
                         "annotationLevel: MetalViewerAnnotationLevel.current", "windowLevel: pix.wl",
                         "windowWidth: pix.ww", "mouseState: nil", "showsSliceOrientation: true"):
            self.assertIn(required, page)
        for forbidden in ("rotate(by", "NSBitmapImageRep", "generateThumbnail", "lockFocus"):
            self.assertNotIn(forbidden, page)
        self.assertEqual(pane.count("private final class AnnotationOverlayView"), 1)

    def test_image_print_snapshots_database_annotations_before_any_modal_loop(self):
        printing = (SOURCES / "BrowserController.m").read_text().split(
            "- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        snapshot, preparation = printing.split("[wait showWindow:self]", 1)
        for required in ("metadataPix.annotationsDBFields", "metadataPix.yearOld", "metadataPix.yearOldAcquisition",
                         'metadata[@"patientName"]', 'metadata[@"patientID"]', 'metadata[@"acquisitionDate"]',
                         'metadata[@"seriesNumber"]', 'metadata[@"sliceIndex"] = @(frame)',
                         'metadata[@"sliceCount"] = @(frameCount)', "imagePositions[image.objectID]"):
            self.assertIn(required, snapshot)
        self.assertNotIn("[metadataPix CheckLoad]", snapshot)
        for required in ("pix.annotationsDBFields =", "pix.yearOld =", "pix.yearOldAcquisition ="):
            self.assertIn(required, preparation)
            self.assertLess(preparation.index(required), preparation.index("[pix CheckLoad]"))
        self.assertNotIn("imageObj:image", preparation)

    def test_image_print_distinguishes_whole_series_from_individual_frames(self):
        printing = (SOURCES / "BrowserController.m").read_text().split(
            "- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        self.assertRegex(printing, r"if \(\[item isKindOfClass:\[DicomImage class\]\]\)\s*"
                                  r"\[images addObject:item\];\s*else\s*\{")
        self.assertIn("[images addObjectsFromArray:seriesImages]", printing)
        self.assertIn("[wholeSeriesImages addObjectsFromArray:seriesImages]", printing)
        self.assertIn("BOOL expandFrames = !isReport && [wholeSeriesImages containsObject:image] &&", printing)
        self.assertIn("image.series.images.count == 1 && image.numberOfFrames.integerValue > 1", printing)
        self.assertIn("frameCount = expandFrames ? image.numberOfFrames.integerValue : 1", printing)
        self.assertIn('expandFrames ? @(frame) : (image.frameID ?: @0)', printing)

    def test_image_print_preparation_is_cancellable_and_keeps_only_display_pixels_between_frames(self):
        printing = (SOURCES / "BrowserController.m").read_text().split(
            "- (void)printDatabaseSelection:", 1)[1].split("- (NSString *)temporaryPDFForImage:", 1)[0]
        for required in ("[wait setCancel:YES]", "setMaxValue:entries.count", "if (wait.aborted) break;",
                         "@autoreleasepool", "error = [entryError retain]", "[error release]",
                         "[wait incrementBy:1]", "if (error) break;", "[wait release]",
                         "preparedEntries == previousPreparedEntries", "Nothing was printed."):
            self.assertIn(required, printing)
        self.assertLess(printing.index("[wait close]"), printing.index("[operation runOperation]"))
        self.assertLess(printing.index("if (wait.aborted) return;"), printing.index("printOperationForPrintInfo:"))
        self.assertNotIn("indexOfObjectIdenticalTo:", printing)

    def test_sr_pdf_preparation_waits_for_webkit_printing_off_the_main_thread(self):
        source = (SOURCES / "StructuredReportSupport.m").read_text()
        printing = source.split("+ (BOOL)writePDFForDICOMAtPath:", 1)[1]
        for required in ("operation.canSpawnSeparateThread = YES", "if (operation)",
                         "runOperationModalForWindow:window", "delegate:session",
                         "@selector(printOperationDidRun:success:contextInfo:)",
                         "while (!session.printFinished)", "runMode:NSDefaultRunLoopMode",
                         "succeeded = session.printSucceeded &&"):
            self.assertIn(required, printing)
        self.assertNotIn("[operation runOperation]", printing)
        self.assertNotIn("createPDFWithConfiguration:", printing)  # Keep real pagination, not a tall screenshot.
        self.assertLess(printing.index("while (!session.printFinished)"),
                        printing.index("fileExistsAtPath:pdfPath"))
        self.assertLess(printing.index("while (!session.printFinished)"),
                        printing.index("window.contentView = nil"))
        callback = source.split("- (void)printOperationDidRun:", 1)[1].split("@end", 1)[0]
        self.assertIn("dispatch_async(dispatch_get_main_queue()", callback)
        self.assertLess(callback.index("dispatch_async"), callback.index("self.printSucceeded = success"))
        self.assertLess(callback.index("self.printSucceeded = success"), callback.index("self.printFinished = YES"))

    def test_sr_pdf_preparation_does_not_inherit_a_previous_print_page_selection(self):
        printing = (SOURCES / "StructuredReportSupport.m").read_text().split(
            "+ (BOOL)writePDFForDICOMAtPath:", 1)[1]
        for setting in ("printDictionary[NSPrintAllPages] = @YES", "printDictionary[NSPrintSelectionOnly] = @NO",
                        "removeObjectForKey:NSPrintFirstPage", "removeObjectForKey:NSPrintLastPage"):
            self.assertIn(setting, printing)
            self.assertLess(printing.index(setting), printing.index("initWithDictionary:printDictionary"))
        self.assertIn("printDictionary[NSPrintJobDisposition] = NSPrintSaveJob", printing)
        self.assertIn("operation.showsPrintPanel = NO", printing)

    def test_fixture_covers_dates_charsets_private_tags_and_sequences(self):
        root = ET.parse(ROOT / "Scripts/tests/dcm_metadata_baseline.xml").getroot()
        elements = {node.attrib["tag"]: node for node in root.iter("element")}
        self.assertEqual(elements["0008,0020"].text, "20260228")
        self.assertEqual(elements["0008,0030"].text, "000000.123456")
        self.assertTrue(elements["0008,002a"].text.endswith("-0700"))
        self.assertIn("J\u00e9r\u00f4me & Example", elements["0010,0010"].text)
        self.assertEqual(elements["0020,0032"].text.split("\\"), ["1.25", "-2.5", "0"])
        self.assertIn("literal \\ slash <tag>\n", elements["0040,a160"].text)
        self.assertEqual(elements["0040,a160"].attrib["vm"], "1")
        self.assertEqual(elements["0071,1001"].text, "text")
        self.assertIsNotNone(root.find(".//sequence/item/sequence/item/element"))
        self.assertEqual(len(root.findall(".//pixel-item")), 2)
        self.assertEqual(elements["0042,0011"].attrib["binary"], "hidden")


if __name__ == "__main__":
    unittest.main()
