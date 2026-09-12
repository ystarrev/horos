"""Query double-click source contracts; no build, PACS, or database access.

Interactive checks after rebuilding: double-click a study and an expanded series,
repeat with an already-local item, then cancel a large retrieval. Single-click
highlighting, disclosure triangles, and the retrieve-only button should be unchanged.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def method(source, signature, next_signature):
    return source.split(signature + "\n{", 1)[1].split(next_signature, 1)[0]


class QueryRetrieveAndViewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "Horos/Sources/QueryController.mm").read_text()
        cls.outline = (ROOT / "Horos/Sources/QueryOutlineView.m").read_text()
        cls.mouse = method(cls.outline, "- (void)mouseDown:(NSEvent *)event", "- (NSMenu*)menuForEvent:")
        cls.open = method(cls.source, "- (BOOL) openAvailableLocalImagesForQueryItem:(id) item",
                          "- (BOOL) addPendingRetrieveAndViewItem:")
        cls.poll = method(cls.source, "- (void) checkAndView:(NSDictionary *)request",
                          "- (BOOL) openAvailableLocalImagesForQueryItem:")
        cls.retrieve = method(cls.source, "-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable forViewing: (BOOL) forViewing items:(NSArray*) items showGUI:(BOOL) showGUI",
                              "-(void) retrieve:(id)sender onlyIfNotAvailable:")

    def test_custom_highlight_handler_explicitly_delivers_double_click(self):
        self.assertIn("[event clickCount] == 2", self.mouse)
        delivery = "[controller queryOutlineView: self retrieveAndViewAtRow: row];"
        self.assertIn(delivery, self.mouse)
        self.assertLess(self.mouse.index(delivery), self.mouse.index("toggleHighlightAtRow: row"))
        self.assertIn("return;", self.mouse.split(delivery, 1)[1].split("toggleHighlightAtRow:", 1)[0])

    def test_retrieve_button_and_disclosure_keep_native_handling(self):
        self.assertLess(self.mouse.index('@"Button"'), self.mouse.index("[event clickCount]"))
        button = self.mouse.split('@"Button"', 1)[1].split("if( row >= 0", 1)[0]
        self.assertIn("[super mouseDown: event];", button)
        self.assertIn("return;", button)
        self.assertIn("NSPointInRect( point, [self frameOfOutlineCellAtRow: row]) == NO", self.mouse)

    def test_double_click_uses_actual_clicked_row_not_highlighted_selection(self):
        callback = method(self.source, "- (void)queryOutlineView:(NSOutlineView *)sender retrieveAndViewAtRow:(NSInteger)row",
                          "- (IBAction) retrieveAndViewClick:")
        self.assertIn("row >= 0 && row < [outlineView numberOfRows]", callback)
        self.assertIn("[self retrieveAndViewItem: [outlineView itemAtRow: row]]", callback)
        self.assertNotIn("selectedRow", callback)
        fallback = method(self.source, "- (IBAction) retrieveAndViewClick: (id) sender", "- (void) retrieveClick:")
        self.assertIn("retrieveAndViewAtRow: [outlineView clickedRow]", fallback)

    def test_clicked_item_uses_existing_retrieval_without_extra_query(self):
        action = method(self.source, "- (void)retrieveAndViewItem:(id)item", "- (void)queryOutlineView:")
        for expected in ("DCMTKStudyQueryNode", "DCMTKSeriesQueryNode",
                         "onlyIfNotAvailable: YES forViewing: YES items: @[item] showGUI: YES",
                         "[self viewQueryItem: item]"):
            self.assertIn(expected, action)
        for forbidden in ("queryWithValues:", "queryNodesWithSingleAssociation:", "seriesSelectedForRetrieve", "move:"):
            self.assertNotIn(forbidden, action)

    def test_context_menu_keeps_existing_multi_selection_retrieval(self):
        action = method(self.source, "- (IBAction) retrieveAndView: (id) sender", "- (void)retrieveAndViewItem:")
        self.assertIn("[self retrieve: self onlyIfNotAvailable: YES forViewing: YES]", action)

    def test_remote_destination_is_rejected_before_transfer_bookkeeping(self):
        self.assertLess(self.retrieve.index("if( forViewing &&"), self.retrieve.index("[previousAutoRetrieve setValue:"))
        validation = self.retrieve.split("if([items count])", 1)[0]
        self.assertIn("HorosPresentCriticalAlert", validation)
        self.assertIn("return;", validation)

    def test_first_local_images_launch_without_waiting_for_entire_retrieve(self):
        self.assertNotIn("previousAutoRetrieve", self.open)
        self.assertNotIn("expectedCount", self.open)
        self.assertIn("BOOL success = [imagesToOpen count] > 0", self.open)
        self.assertIn("[browser openMetalViewerForImages: imagesToOpen]", self.open)

    def test_study_launch_does_not_mix_series_in_initial_stack(self):
        study = self.open.split("if( isStudy)", 1)[1].split("else", 1)[0]
        self.assertIn("if( [images count])", study)
        self.assertIn("[loadList addObjectsFromArray: images];", study)
        self.assertIn("break;", study)

    def test_local_lookup_uses_uids_not_patient_name_or_selection(self):
        self.assertIn('@"studyInstanceUID == %@", [item uid]', self.open)
        self.assertIn('@"seriesDICOMUID == %@ AND study.studyInstanceUID == %@", [item uid], [item studyInstanceUID]', self.open)
        for forbidden in ("selectedRow", "patientID ==", "name =="):
            self.assertNotIn(forbidden, self.open)

    def test_open_occurs_on_main_after_database_work_returns(self):
        self.assertIn("NSAssert([NSThread isMainThread]", self.open)
        self.assertLess(self.open.index("\n\t});"), self.open.index("[browser openMetalViewerForImages:"))
        self.assertIn("imagesToOpen = [loadList copy]", self.open)
        self.assertIn("[imagesToOpen release]", self.open)

    def test_pending_request_is_consumed_before_viewer_notifications(self):
        self.assertLess(self.open.index("[self removePendingRetrieveAndViewItem: item]"),
                        self.open.index("[browser openMetalViewerForImages:"))
        self.assertIn("[pendingRetrieveAndViewItems containsObject: item] == NO", self.open)

    def test_retry_budget_belongs_to_request_not_controller(self):
        self.assertNotIn("checkAndViewTry", self.source)
        self.assertIn('@"remainingAttempts": @(attempts - 1)', self.poll)
        self.assertNotIn("removePendingRetrieveAndViewItem", self.poll)
        action = method(self.source, "- (void)viewQueryItem:(id)item", "- (QueryFilter*) getModalityQueryFilter:")
        self.assertIn("if( [self addPendingRetrieveAndViewItem: item])", action)

    def test_long_retrievals_recheck_on_completion_and_import(self):
        worker = method(self.source, "- (void) performRetrieve:(NSArray*) array", "- (void) checkAndView:")
        completion = worker.split("BOOL cancelled = [NSThread currentThread].isCancelled;", 1)[1]
        self.assertIn("dispatch_async(dispatch_get_main_queue()", completion)
        self.assertIn("if( cancelled)", completion)
        self.assertIn("[self removePendingRetrieveAndViewItem: item]", completion)
        self.assertIn("initiateImportFilesFromIncomingDirUnlessAlreadyImporting", completion)
        self.assertIn("[self openPendingRetrieveAndViewItemsIfPossible]", completion)
        notification = method(self.source, "-(void)observeDatabaseAddNotification:(NSNotification*)notification", "- (BOOL)splitView:")
        self.assertIn("performSelectorOnMainThread:@selector(openPendingRetrieveAndViewItemsIfPossible)", notification)

    def test_closing_query_window_clears_pending_opens(self):
        close = method(self.source, "- (void)windowWillClose:(NSNotification *)notification", "- (int) dicomEcho:")
        self.assertIn("[pendingRetrieveAndViewItems removeAllObjects]", close)


if __name__ == "__main__":
    unittest.main()
