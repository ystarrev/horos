"""Streaming C-STORE source checks; no build, database, or live transfers."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StreamingReceiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "Horos/Sources/HorosQueryRetrieveServer.cpp").read_text()
        cls.listener = (ROOT / "Horos/Sources/DCMTKQueryRetrieveSCP.mm").read_text()
        cls.validation = (ROOT / "Horos/Sources/HorosDICOMStoreValidation.h").read_text()
        cls.context = cls.source.split("class StreamedStoreContext", 1)[1].split("class QueryRetrieveAssociation", 1)[0]
        cls.store = cls.source.split("OFCondition store(T_DIMSE_C_StoreRQ& request", 1)[1].split("T_ASC_Association* association_;", 1)[0]

    def test_default_listener_streams_bytes_in_original_transfer_syntax(self):
        self.assertIn("options.bitPreserving_ = OFTrue", self.listener)
        streamed = self.store.split("if (options_.bitPreserving_)", 1)[1].split("\n        else", 1)[0]
        self.assertIn("DcmXfer(accepted.acceptedTransferSyntax).getXfer()", streamed)
        self.assertIn("&request, path, options_.useMetaheader_", streamed)
        self.assertIn("NULL, StreamedStoreContext::callback", streamed)
        self.assertIn("options_.blockMode_, options_.dimse_timeout_", streamed)
        for forbidden in ("DcmFileFormat", "saveFile(", "chooseRepresentation("):
            self.assertNotIn(forbidden, streamed)

    def test_only_sop_identifier_prefix_is_read_and_values_are_bounded(self):
        self.assertIn("loadFileUntilTag(path, syntax, EGL_noChange", self.validation)
        self.assertIn("DIC_UI_LEN, ERM_autoDetect, DcmTagKey(0x0008, 0x0019)", self.validation)
        self.assertIn("element->getLength() > DIC_UI_LEN", self.validation)
        self.assertIn("header.getDataset()", self.validation)
        self.assertIn("DU_findSOPClassAndInstanceInDataSet", self.validation)
        for field in ("AffectedSOPClassUID", "AffectedSOPInstanceUID"):
            self.assertIn(field, self.validation)
        for forbidden in ("loadFile(", "getMetaInfo()", "saveFile(", "DCM_PixelData", "loadAllDataIntoMemory"):
            self.assertNotIn(forbidden, self.validation)

    def test_publication_only_occurs_on_completed_successful_receive(self):
        self.assertIn("progress->state == DIMSE_StoreEnd", self.context)
        self.assertIn("if (response.DimseStatus == STATUS_Success) response.DimseStatus = status_", self.context)
        self.assertIn("response.DimseStatus == STATUS_Success && !options_.ignoreStoreData_", self.context)
        self.assertLess(self.context.index("HorosValidateReceivedStore("), self.context.index("database_.storeRequest("))
        self.assertIn("if (result.bad() && response.DimseStatus == STATUS_Success)", self.context)
        self.assertIn("dbStatus.extractStatusDetail()", self.context)

    def test_rejected_or_interrupted_files_are_not_left_in_staging(self):
        self.assertIn("const OFString stagingPath(path)", self.store)
        self.assertIn("result.bad() || status != STATUS_Success", self.store)
        self.assertIn("stagingPath != NULL_DEVICE_NAME", self.store)
        self.assertIn("OFStandard::deleteFile(stagingPath.c_str())", self.store)
        self.assertIn("if (strcmp(path, NULL_DEVICE_NAME) != 0)", self.store)
        self.assertIn("database_->pruneInvalidRecords()", self.store)

    def test_explicit_normalization_retains_stock_dataset_writer(self):
        writer = self.store.split("// Retain DCMTK's dataset writer", 1)[1]
        self.assertIn("DcmQueryRetrieveStoreContext", writer)
        self.assertIn("DCM_SourceApplicationEntityTitle", writer)
        self.assertIn("&dataset, storeCallback", writer)


if __name__ == "__main__":
    unittest.main()
