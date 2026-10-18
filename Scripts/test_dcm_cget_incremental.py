"""C-GET integration and syntax checks; no application build or PACS access."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


def publication_context(source):
    return "struct HorosCGetStoreContext\n" + source.split("struct HorosCGetStoreContext\n", 1)[1].split("// DCMTK's legacy", 1)[0]


class IncrementalCGetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.query = (SOURCES / "DCMTKQueryNode.mm").read_text()
        cls.context = publication_context(cls.query)
        cls.receive = cls.query.split("static OFCondition HorosReceiveCGet(", 1)[1].split("static void\nsubOpCallback", 1)[0]
        cls.get = cls.query.split("- (OFCondition)getSCU:", 1)[1].split("- (NSManagedObject *)logEntry", 1)[0]

    def test_completion_callback_publishes_after_validation_and_signals_shared_scheduler(self):
        self.assertIn("progress->state != DIMSE_StoreEnd", self.context)
        self.assertLess(self.context.index("HorosValidateReceivedStore("), self.context.index("renamex_np("))
        self.assertLess(self.context.index("context.published = true"), self.context.index("incomingFileDidBecomeAvailable"))
        self.assertIn("RENAME_EXCL", self.context)
        self.assertNotIn("moveItemAtPath:", self.context)
        self.assertNotIn("dispatch_get_main_queue", self.context)
        self.assertNotIn("HorosPublishCGetFiles", self.query)

    def test_streaming_receiver_uses_actual_accepted_syntax_and_completion_callback(self):
        self.assertIn("ASC_findAcceptedPresentationContext(assoc->params, incomingPresentationContext", self.receive)
        self.assertIn("DcmXfer(accepted.acceptedTransferSyntax).getXfer()", self.receive)
        self.assertIn("accepted.abstractSyntax, incomingMessage.msg.CStoreRQ.AffectedSOPClassUID", self.receive)
        self.assertIn("dcmIsaStorageSOPClassUID(incomingMessage.msg.CStoreRQ.AffectedSOPClassUID)", self.receive)
        self.assertIn("HorosCGetStoreContext::callback, &context, blockMode, timeout", self.receive)
        self.assertIn("@autoreleasepool", self.receive)

    def test_local_failure_cannot_be_counted_as_success(self):
        self.assertIn("context.retainStagedFile = true", self.context)
        self.assertIn("STATUS_STORE_Refused_OutOfResources", self.context)
        self.assertIn("context.published && receivedObjectCount != NULL", self.receive)
        self.assertIn("context.status != STATUS_Success && storeFailure == EC_Normal", self.receive)
        self.assertIn("return condition == EC_Normal ? storeFailure : condition", self.receive)
        self.assertIn("MIN((NSUInteger)rsp.NumberOfCompletedSubOperations, receivedObjectCount)", self.get)
        self.assertIn("self.countOfSuboperations = 0", self.get)
        self.assertIn("self.countOfSuccessfulSuboperations = 0", self.get)

    def test_interrupted_files_are_removed_but_valid_failed_publications_are_retained(self):
        self.assertIn("!context.published && !context.retainStagedFile", self.receive)
        self.assertIn("removeItemAtPath:filename", self.receive)
        self.assertIn("rmdir(stagingDirectory.fileSystemRepresentation)", self.get)
        self.assertNotIn("removeItemAtPath:stagingDirectory", self.get)

    def test_database_and_path_lifetimes_are_pinned_for_entire_session(self):
        self.assertIn('objectForKey:@"HorosViewingImportDatabase"', self.get)
        self.assertIn("database ?: [DicomDatabase activeLocalDatabase]", self.get)
        self.assertIn("[database.incomingDirPath copy]", self.get)
        for resource in ("database", "stagingDirectory", "incomingDirectory"):
            self.assertIn(f"[{resource} release]", self.get)
        cleanup = self.get.rsplit("@finally", 1)[1]
        self.assertIn("removeMove:self", cleanup)
        self.assertIn("delete statusDetail", cleanup)
        self.assertIn("delete rspIds", cleanup)
        self.assertLess(self.get.index("if (presId == 0)"), self.get.index("addMove:self"))

    def test_cancellation_sends_cancel_once_and_drains_to_final_response(self):
        self.assertIn("BOOL cancelSent = NO", self.receive)
        self.assertIn("if (!cancelSent && ([NSThread currentThread].isCancelled", self.receive)
        self.assertIn("DIMSE_sendCancelRequest(assoc, getPresentationContext, request->MessageID)", self.receive)
        self.assertIn("cancelSent = YES", self.receive)
        self.assertIn("while (condition == EC_Normal && receivedFinalResponse == NO)", self.receive)
        self.assertEqual(self.get.count("showErrorMessage && !cancelled"), 2)

    def test_shared_validator_has_one_implementation(self):
        server = (SOURCES / "HorosQueryRetrieveServer.cpp").read_text()
        for source in (server, self.query):
            self.assertIn('#include "HorosDICOMStoreValidation.h"', source)
            self.assertIn("HorosValidateReceivedStore(", source)
            self.assertNotIn("DIC_US validateReceivedStore(", source)

    def test_publication_fixture_typechecks_without_building(self):
        products = Path.home() / "Library/Developer/Xcode/DerivedData"
        includes = sorted(products.glob("Horos-*/Build/Products/Debug/DCMTK/include"))
        if not includes:
            self.skipTest("Existing stock DCMTK headers are unavailable")
        with tempfile.TemporaryDirectory(prefix="horos-cget-fixture-") as temporary:
            (Path(temporary) / "HorosCGetStoreContext.inc").write_text(self.context)
            subprocess.run(["xcrun", "clang++", "-fsyntax-only", "-std=c++17", "-fblocks", "-fobjc-exceptions",
                            "-fno-objc-arc", "-I", str(includes[0]), "-I", str(SOURCES), "-I", temporary,
                            str(ROOT / "Scripts/tests/CGetStorePublicationTests.mm")],
                           check=True, timeout=30, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
