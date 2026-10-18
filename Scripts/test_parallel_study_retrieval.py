"""Whole-study retrieval source contracts; no build, database, or PACS access.

After rebuilding, retrieve a whole study containing images and reports, repeat
with a study plus one of its series selected, and cancel during discovery and
during transfer. Also check single-association, C-GET, and remote destinations.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


def body(source, signature, next_signature):
    return source.split(signature + "\n{", 1)[1].split(next_signature, 1)[0]


class ParallelStudyRetrievalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = (SOURCES / "QueryController.mm").read_text()
        cls.node = (SOURCES / "DCMTKQueryNode.mm").read_text()
        cls.study = (SOURCES / "DCMTKStudyQueryNode.mm").read_text()
        cls.plan = body(cls.controller, "- (NSArray *)retrieveJobsByExpandingStudies:(NSArray *)jobs",
                        "- (void) performRetrieve:")
        cls.worker = body(cls.controller, "- (void) performRetrieve:(NSArray*) array",
                          "- (void) checkAndView:")
        cls.validation = body(cls.controller, "static NSArray *HorosQRCompleteSeriesForStudy(DCMTKStudyQueryNode *study, DCMTKStudyQueryNode *query)",
                              "static NSString *HorosQRRetrieveStatusForObject")

    def test_expansion_only_for_local_cmove_and_parallel_preference(self):
        gate = self.worker.split("BOOL canRetrieveConcurrently", 1)[1].split("if( concurrentRetrieveCount > 1)", 1)[0]
        self.assertIn("allowNonCMOVE && HorosQRSeriesRetrieveConcurrencyLimit(2) > 1", gate)
        self.assertIn('[[d objectForKey: @"retrieveMode"] intValue] != CMOVERetrieveMode', gate)
        self.assertIn("if( canRetrieveConcurrently)", gate)
        self.assertIn("[self retrieveJobsByExpandingStudies: moveArray]", gate)
        self.assertIn("HorosQRSeriesRetrieveConcurrencyLimit( moveArray.count)", gate)

    def test_private_discovery_node_preserves_connection_and_retrieve_settings(self):
        clone = body(self.study, "- (DCMTKStudyQueryNode *)queryNodeForSeriesDiscovery", "- (DcmDataset *)moveDataset")
        for value in ("_callingAET", "_calledAET", "_hostname", "_port", "_transferSyntax",
                      "_compression", "_extraParameters", "_isAutoRetrieve", "_noSmartMode", "showErrorMessage"):
            self.assertIn(value, clone)
        self.assertIn("[self moveDataset]", clone)
        self.assertIn("@finally", clone)
        self.assertIn("delete dataset", clone)
        self.assertNotIn("[self purgeChildren]", clone)
        self.assertNotIn("[self setChildren:", clone)

    def test_study_series_lookups_share_association_per_endpoint(self):
        self.assertIn("[self queryEndpointIdentifierForItem: query]", self.plan)
        self.assertIn("[queries addObject: query]", self.plan)
        self.assertIn("[[queries firstObject] queryNodesWithSingleAssociation: queries]", self.plan)
        self.assertIn("node.uid.length == 0", self.plan)

    def test_discovery_requires_final_success_not_just_transport_success(self):
        find = self.node.split("- (OFCondition)findSCU:", 1)[1].split("- (OFCondition) cfind:", 1)[0]
        self.assertIn("_queryCompletedSuccessfully = NO", find)
        self.assertIn("T_DIMSE_C_FindRSP rsp = {}", find)
        self.assertIn("cond == EC_Normal && rsp.DimseStatus == STATUS_Success && _abortAssociation == NO", find)
        batch = body(self.node, "- (BOOL)queryNodesWithSingleAssociation:(NSArray *)nodes", "- (void) move:")
        self.assertIn("node->_queryCompletedSuccessfully = NO", batch)
        self.assertIn("completedQueries != [nodes count]", batch)
        self.assertIn("node.queryCompletedSuccessfully == NO", batch)
        self.assertIn("query.queryCompletedSuccessfully == NO", self.validation)

    def test_raw_series_includes_reports_and_does_not_use_ui_filters(self):
        self.assertIn("[query children]", self.validation)
        for excluded in ("visibleQueryChildren", "seriesSelectedForRetrieve", "seriesFilterMatchesItem",
                         "headOnly", "ignoreMPR", "modality"):
            self.assertNotIn(excluded, self.validation + self.plan)

    def test_incomplete_discovery_keeps_original_study_request(self):
        self.assertIn("node.uid.length == 0", self.validation)
        self.assertIn("[node.studyInstanceUID isEqualToString: study.uid] == NO", self.validation)
        self.assertIn("[seriesUIDs containsObject: node.uid]", self.validation)
        self.assertIn("allCountsKnown", self.validation)
        self.assertIn("imageCount != study.numberImages.unsignedIntegerValue", self.validation)
        self.assertIn("if( series == nil)", self.plan)
        failure = self.plan.split("if( series == nil)", 1)[1].split("node.countOfSuboperations", 1)[0]
        self.assertIn("[result addObject: job]", failure)
        self.assertIn("continue;", failure)

    def test_deduplication_is_scoped_to_endpoint_study_and_destination(self):
        key = body(self.controller, "static NSArray *HorosQRMoveStudyIdentifier(NSDictionary *job)",
                   "static NSArray *HorosQRCompleteSeriesForStudy")
        for value in ("callingAET", "calledAET", "_hostname", "_port", "studyInstanceUID", "retrieveMode", "moveDestination"):
            self.assertIn(value, key)
        series = self.plan.split("if( [node isKindOfClass: [DCMTKSeriesQueryNode class]])", 1)[1]
        self.assertLess(series.index("[studies objectForKey: identifier]"), series.index("arrayByAddingObject: node.uid"))
        self.assertIn("[scheduled containsObject: identifier]", self.plan)

    def test_pending_series_prevent_premature_parent_completion(self):
        self.assertIn("node.countOfSuboperations = series.count", self.plan)
        self.assertIn('forKey: @"studyQuery"', self.plan)
        parallel = self.worker.split("[progressLock lock];", 1)[1].split("[progressLock unlock];", 1)[0]
        self.assertIn("studyQuery.countOfSuboperations += MAX((NSUInteger)1, object.countOfSuboperations) - 1", parallel)
        self.assertIn("studyQuery.countOfSuccessfulSuboperations += object.countOfSuccessfulSuboperations", parallel)
        self.assertIn("[outlineView reloadItem: studyQuery ?: object]", self.worker)

    def test_cancelled_discovery_cannot_schedule_transfer(self):
        self.assertGreaterEqual(self.plan.count("if( [NSThread currentThread].isCancelled)\n            return @[];"), 1)
        before_queue = self.plan.split("NSMutableArray *result", 1)[0]
        self.assertTrue(before_queue.rstrip().endswith("return @[];"))
        self.assertIn("while( [retrieveThread isCancelled] == NO)", self.worker)
        sequential = self.worker.split("int i = 0;", 1)[1]
        self.assertIn("if( [NSThread currentThread].isCancelled)\n                    break;", sequential)

    def test_bookkeeping_and_viewer_completion_use_original_selection(self):
        cleanup = self.worker.split("BOOL cancelled = [NSThread currentThread].isCancelled;", 1)
        final_cleanup = cleanup[0].rsplit("@synchronized( previousAutoRetrieve)", 1)[1]
        self.assertIn("for( DCMTKQueryNode *object in array)", final_cleanup)
        self.assertIn("removeObjectForKey: [QueryController stringIDForStudy: object]", final_cleanup)
        self.assertIn("for( id item in array)", cleanup[1])
        self.assertIn("transferFinishedWithStudyUID:", cleanup[1])
        self.assertIn("[self removePendingRetrieveAndViewItem: item]", cleanup[1])


if __name__ == "__main__":
    unittest.main()
