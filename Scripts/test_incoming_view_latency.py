"""Source contracts for immediate, serialized retrieve-and-view imports.

No build, PACS access, or database writes. After rebuilding, benchmark one fresh
series and a larger study; also cancel a retrieve and check a normal bulk import.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class IncomingViewLatencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = (ROOT / "Horos/Sources/DicomDatabase.mm").read_text()
        cls.query = (ROOT / "Horos/Sources/QueryController.mm").read_text()
        cls.receiver = (ROOT / "Horos/Sources/dcmqrdbq.mm").read_text()
        cls.schedule = section(cls.db, "-(void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting {",
                               "+(void)importFilesFromIncomingDirTimerCallback:")
        cls.worker = section(cls.db, "-(void)runScheduledIncomingImport:(HorosIncomingImportTrace *)trace {",
                             "-(HorosIncomingImportTrace *)incomingImportTrace {")
        cls.trace_factory = section(cls.db, "-(HorosIncomingImportTrace *)incomingImportTrace {",
                                    "-(void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting {")
        cls.batch = section(cls.db, "-(void)importFilesFromIncomingDirUsingWorker:(DicomDatabase **)workerDatabase\n{",
                            "-(BOOL)hasInteractiveIncomingImport {")
        cls.importer = section(cls.db, "-(NSInteger)importFilesFromIncomingDirOnContextQueue:",
                               "-(BOOL)waitForCompressThread")

    def test_interactive_lifetime_covers_retrieve_and_cleans_up_on_exception(self):
        wrapper = section(self.query, "- (void)performRetrieveForViewing:(NSArray *)items\n{",
                          "- (void) performRetrieve:")
        self.assertLess(wrapper.index("beginInteractiveIncomingImport"), wrapper.index("performRetrieve:items"))
        cleanup = wrapper.split("@finally", 1)[1]
        self.assertIn("endInteractiveIncomingImport", cleanup)
        self.assertIn("removeObjectForKey:", cleanup)

    def test_retrieve_only_does_not_activate_interactive_imports(self):
        self.assertIn("forViewing ? @selector(performRetrieveForViewing:) : @selector(performRetrieve:)", self.query)
        self.assertIn("if( forViewing && viewingDatabase)", self.query)

    def test_no_legacy_progress_window_wait_when_opening_images(self):
        retrieve = section(self.query, "-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable forViewing: (BOOL) forViewing items:",
                           "-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable forViewing: (BOOL) forViewing\n")
        self.assertIn("if( showGUI && !forViewing)", retrieve)
        self.assertIn("if( wait)\n\t\t\t{\n\t\t\t\t[NSThread sleepForTimeInterval: 0.2]", retrieve)
        self.assertIn('objectForKey:@"HorosViewingImportDatabase"] == nil)\n\t\t\t[NSThread sleepForTimeInterval: 0.5]', self.query)

    def test_receiver_notifies_only_after_successful_file_publication(self):
        store = section(self.receiver, "OFCondition DcmQueryRetrieveOsiriXDatabaseHandle::storeRequest(",
                        "/* ========================= UTILS")
        self.assertLess(store.index("moveItemAtPath:"), store.index("incomingFileDidBecomeAvailable"))
        self.assertLess(store.index("return DcmQROsiriXDatabaseError;"), store.index("incomingFileDidBecomeAvailable"))
        self.assertIn("if (forkedProcess == NO)", store)
        wake = section(self.db, "-(void)incomingFileDidBecomeAvailable {", "-(void)runScheduledIncomingImport:")
        self.assertIn("if ([self hasInteractiveIncomingImport])", wake)

    def test_interactive_imports_bypass_quiet_period(self):
        self.assertIn("showGUI.boolValue && !interactive && coalescingDelay > 0", self.importer)
        self.assertIn("if ([self hasInteractiveIncomingImport])", self.importer)
        self.assertIn("interactive = YES;\n                    break;", self.importer)

    def test_interactive_batch_publishes_promptly_without_starving_first_file(self):
        self.assertIn("if (interactive) maxNumberOfFiles = MIN(maxNumberOfFiles, 64)", self.importer)
        self.assertIn("interactive ? 0.05", self.importer)
        self.assertIn("filesArray.count == 0 ||", self.importer)

    def test_final_batch_keeps_priority_until_drained(self):
        end = section(self.db, "-(void)endInteractiveIncomingImport {", "-(void)incomingFileDidBecomeAvailable {")
        self.assertIn("_interactiveIncomingImportCount--", end)
        self.assertIn("_interactiveIncomingImportDrain = YES", end)
        self.assertIn("initiateImportFilesFromIncomingDirUnlessAlreadyImporting", end)
        self.assertIn("_interactiveIncomingImportCount > 0 || _interactiveIncomingImportDrain", self.worker)
        stopped = self.worker.split("if (!again) {", 1)[1].split("}", 1)[0]
        self.assertIn("_interactiveIncomingImportDrain = NO", stopped)
        self.assertIn("_incomingImportScheduled = NO", stopped)

    def test_one_worker_remembers_arrivals_while_busy(self):
        self.assertIn("[_incomingImportCondition lock]", self.schedule)
        self.assertIn("[_incomingImportCondition unlock]", self.schedule)
        busy = self.schedule.split("if (_incomingImportScheduled)", 1)[1].split("_incomingImportScheduled = YES", 1)[0]
        self.assertIn("_incomingImportRequested = YES", busy)
        self.assertLess(busy.index("[_incomingImportCondition signal]"), busy.index("return;"))
        self.assertIn("return;", busy)
        self.assertIn("_incomingImportRequested && ![NSThread currentThread].isCancelled", self.worker)
        self.assertIn("} while (again);", self.worker)
        self.assertIn("_incomingImportRequested = NO", self.worker)
        self.assertNotIn("initiateImportFilesFromIncomingDirUnlessAlreadyImporting", self.worker)

    def test_packet_gaps_keep_worker_alive_without_delaying_arrivals(self):
        waiting = section(self.worker, "while (!_incomingImportRequested", "again = _incomingImportRequested")
        self.assertIn("_interactiveIncomingImportCount > 0", waiting)
        self.assertIn("![NSThread currentThread].isCancelled", waiting)
        self.assertIn("[_incomingImportCondition waitUntilDate:", waiting)
        self.assertNotIn("sleepForTimeInterval", self.worker)
        self.assertLess(self.worker.index('record:@"worker_finished"'), self.worker.index("waitUntilDate:"))
        self.assertLess(self.worker.index("[_incomingImportCondition unlock]"),
                        self.worker.index("[self importFilesFromIncomingDirUsingWorker:&workerDatabase]"))

    def test_arrivals_and_completion_use_the_same_signal_path(self):
        for start, end in (("-(void)incomingFileDidBecomeAvailable {", "-(void)runScheduledIncomingImport:"),
                           ("-(void)endInteractiveIncomingImport {", "-(void)incomingFileDidBecomeAvailable {")):
            self.assertIn("initiateImportFilesFromIncomingDirUnlessAlreadyImporting", section(self.db, start, end))
        self.assertIn("[_incomingImportCondition signal]", self.schedule)
        self.assertIn("_incomingImportCondition = [[NSCondition alloc] init]", self.db)
        self.assertIn("[_incomingImportCondition release]", self.db)

    def test_no_main_queue_hop_to_start_worker(self):
        self.assertNotIn("performSelectorOnMainThread", self.schedule)
        self.assertNotIn("dispatch_get_main_queue", self.schedule)
        self.assertIn("performSelectorInBackground:@selector(runScheduledIncomingImport:)", self.schedule)

    def test_worker_does_not_hold_lock_across_context_dispatch(self):
        entry = section(self.db, "-(void)importFilesFromIncomingDirThread\n{", "-(BOOL)hasInteractiveIncomingImport {")
        self.assertNotIn("[_importFilesFromIncomingDirLock lock]", entry)
        self.assertIn("[_importFilesFromIncomingDirLock lock]", self.importer)
        self.assertLess(self.worker.index("[_importFilesFromIncomingDirLock unlock]"),
                        self.worker.index("[self importFilesFromIncomingDirUsingWorker:&workerDatabase]"))

    def test_worker_lifetime_covers_all_queued_batches_without_a_database_retain_cycle(self):
        self.assertLess(self.worker.index("DicomDatabase *workerDatabase = nil"), self.worker.index("do {"))
        self.assertLess(self.worker.index("} while (again);"), self.worker.index("[workerDatabase release]"))
        self.assertIn("if (!*workerDatabase)", self.batch)
        self.assertIn("*workerDatabase = [database.independentDatabase retain]", self.batch)
        self.assertNotIn("self.independentDatabase", self.worker)
        self.assertIn("@finally", self.batch)
        self.assertIn("[thread exitOperation]", self.batch)

    def test_worker_reuse_refaults_saved_objects_on_the_context_queue(self):
        refresh = section(self.batch, "N2PerformManagedObjectContextBlockAndWait(context, ^{", "});")
        self.assertIn("if (!context.hasChanges) [context refreshAllObjects]", refresh)
        self.assertNotIn("[context reset]", self.batch)
        self.assertNotIn("dispatch_get_main_queue", self.batch.split("importCount =", 1)[0])

    def test_legacy_direct_worker_entry_still_releases_its_private_database(self):
        entry = section(self.db, "-(void)importFilesFromIncomingDirThread\n{",
                        "-(void)importFilesFromIncomingDirUsingWorker:")
        self.assertIn("[self importFilesFromIncomingDirUsingWorker:&workerDatabase]", entry)
        self.assertIn("@finally", entry)
        self.assertIn("[workerDatabase release]", entry)

    def test_remaining_files_do_not_depend_on_background_run_loop(self):
        tail = self.importer.split("if (enumer.nextObject)", 1)[1]
        self.assertIn("[self initiateImportFilesFromIncomingDirUnlessAlreadyImporting]", tail)
        self.assertNotIn("afterDelay:0", tail)

    def test_complete_file_safety_and_regular_batch_settings_are_retained(self):
        for guard in ("NSFileBusy", "continue; // don't handle this file, it's probably a busy file",
                      "HorosIncomingImportMinBatchSize()", "HorosIncomingImportCoalescingDelay()"):
            self.assertIn(guard, self.importer)

    def test_timings_cover_unmeasured_phases_and_main_queue_delivery(self):
        for stage in ("worker_queue", "scheduler_preflight", "incoming_scan", "worker_database", "worker_reuse", "context_queue",
                      "import_lock", "disk_preflight", "coalescing", "filename_index", "scan_and_stage",
                      "file_classification", "path_allocation", "file_relocation",
                      "parse_add_save_notify", "notification_enqueued", "main_notification_queue",
                      "main_object_resolution", "main_observers", "worker_finished",
                      "main_early_add_queue", "main_early_add_resolution", "main_early_add_observers"):
            self.assertIn(f'@"{stage}"', self.db)

    def test_context_trace_is_propagated_and_restored(self):
        dispatch = section(self.db, "-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI\n           listenerCompressionSettings:",
                           "-(NSInteger)importFilesFromIncomingDirOnContextQueue:")
        self.assertIn("setObject:trace forKey:HorosIncomingTraceKey", dispatch)
        self.assertIn("@finally", dispatch)
        self.assertIn("setObject:previousTrace forKey:HorosIncomingTraceKey", dispatch)
        self.assertIn("[previousTrace release]", dispatch)

    def test_diagnostics_are_bounded_optional_and_non_identifying(self):
        self.assertIn("traceCount++ < 256", self.trace_factory)
        self.assertIn('@"HorosQueryViewerBenchmark"', self.trace_factory)
        trace = section(self.db, "@implementation HorosIncomingImportTrace", "@end")
        log = trace.split("NSLog(", 1)[1].split(";", 1)[0]
        self.assertIn("clock=%.6f", log)
        for identifier in ("patient", "filePath", "studyUID", "seriesUID"):
            self.assertNotIn(identifier, log)


class DatabaseImportRefreshTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.browser = (ROOT / "Horos/Sources/BrowserController.m").read_text()
        cls.observe = section(cls.browser, "-(void)_observeDatabaseAddNotification:(NSNotification*)notification",
                              "-(void)refreshAfterDatabaseImport\n")
        cls.refresh = section(cls.browser, "-(void)refreshAfterDatabaseImport\n", "-(void)cancelPendingDatabaseImportRefresh\n")
        cls.cancel = section(cls.browser, "-(void)cancelPendingDatabaseImportRefresh\n", "-(void)_refreshDatabaseDisplay")

    def test_per_batch_notifications_do_not_reload_all_rows(self):
        self.assertNotIn("[self outlineViewRefresh]", self.observe)
        self.assertNotIn("[self refreshAlbums]", self.observe)
        self.assertIn("[self invalidateSmartAlbumFetch]", self.observe)
        self.assertIn("[self outlineViewRefresh]", self.refresh)
        self.assertIn("[self refreshAlbums]", self.refresh)

    def test_refresh_deadline_is_bounded_not_postponed_by_continuing_arrivals(self):
        self.assertIn("if (!_databaseImportRefreshScheduled)", self.observe)
        self.assertIn("afterDelay:0.5", self.observe)
        self.assertIn("NSRunLoopCommonModes", self.observe)
        self.assertNotIn("cancelPreviousPerformRequests", self.observe)
        self.assertIn("_databaseImportRefreshScheduled = NO", self.refresh)

    def test_imported_study_ids_are_deduplicated_and_resolved_in_current_context(self):
        self.assertIn("[[NSMutableSet alloc] init]", self.observe)
        self.assertIn("addObject:study.objectID", self.observe)
        self.assertIn("image.isDeleted", self.observe)
        self.assertIn("notification.object != self.database", self.observe)
        self.assertIn("[_database objectsWithIDs:studyIDs]", self.refresh)
        self.assertIn("checkIfLocalStudyHasMoreOrSameNumberOfImagesOfADistantStudy:", self.refresh)

    def test_database_or_context_switch_discards_pending_work(self):
        self.assertIn("cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshAfterDatabaseImport)", self.cancel)
        self.assertIn("[_pendingImportedStudyIDs release]", self.cancel)
        self.assertIn("_pendingImportedStudyIDs = nil", self.cancel)
        for start, end in (("-(void)setDatabase:(DicomDatabase*)db", "-(void)"),
                           ("-(void) willChangeContext", "-(void)setDatabase:"),
                           ("-(void)dealloc\n", "-(void)observeValueForKeyPath:")):
            self.assertIn("[self cancelPendingDatabaseImportRefresh]", section(self.browser, start, end))

    def test_refresh_timing_is_bounded_and_non_identifying(self):
        self.assertIn('objectForKey:@"HorosIncomingTrace"', self.observe)
        self.assertIn("if (benchmark)", self.refresh)
        self.assertIn("benchmarkCount++ < 256", self.refresh)
        log = section(self.refresh, "NSLog(", ");")
        self.assertIn("QRBROWSER import_refresh", log)
        for identifier in ("patient", "studyInstanceUID", "filePath"):
            self.assertNotIn(identifier, log)


class DataFilenameAllocationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = (ROOT / "Horos/Sources/DicomDatabase.mm").read_text()
        cls.index = section(cls.db, "-(NSUInteger)computeDataFileIndex {",
                            "-(NSString*)uniquePathForNewDataFileWithExtension:")

    def test_numeric_descending_order_finds_newest_bucket_first(self):
        self.assertIn("a.integerValue, second = b.integerValue", self.index)
        self.assertIn("if (first > second) return NSOrderedAscending", self.index)
        self.assertIn("if (first < second) return NSOrderedDescending", self.index)
        self.assertIn("if (bucket <= 0) break", self.index)
        self.assertIn('stringWithFormat:@"%ld", (long)bucket', self.index)
        self.assertIn("!isDirectory) continue", self.index)

    def test_only_one_bucket_is_opened_and_nothing_is_deleted(self):
        scan = self.index.split("for (NSString *entry in descendingEntries)", 1)[1]
        self.assertEqual(scan.count("contentsOfDirectoryAtPath:"), 1)
        self.assertIn("break;", scan.split("_dataFileIndex.unsignedIntegerValue = MAX", 1)[1])
        self.assertNotIn("enumeratorAtPath:", self.index)
        self.assertNotIn("removeItemAtPath:", self.index)

    def test_empty_bucket_keeps_lower_buckets_reserved(self):
        self.assertIn("(NSUInteger)bucket > folderSize ? (NSUInteger)bucket - folderSize : 0", self.index)
        self.assertIn("if (fileIndex > 0) index = MAX(index, (NSUInteger)fileIndex)", self.index)

    def test_unreadable_bucket_is_not_reused_and_counter_never_rewinds(self):
        self.assertIn("if (!files) index = (NSUInteger)bucket", self.index)
        self.assertIn("MAX(_dataFileIndex.unsignedIntegerValue, index)", self.index)
        self.assertIn("@synchronized (_dataFileIndex)", self.index)

    def test_both_allocation_paths_keep_collision_checks(self):
        allocators = section(self.db, "-(NSString*)uniquePathForNewDataFileWithExtension:",
                             "#pragma mark")
        self.assertEqual(allocators.count("while (fileExists)"), 2)
        self.assertEqual(allocators.count("fileExistsAtPath:path"), 2)
        self.assertEqual(allocators.count("if (firstExists)"), 2)


if __name__ == "__main__":
    unittest.main()
