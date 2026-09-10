// Standalone runtime fixture, not an app source. Build/run only with user approval.
// Includes the implementation to test private integration helpers without
// exporting test-only API. Link against stock DCMTK, not Horos or a patient DB.
#include "../../Horos/Sources/HorosQueryRetrieveServer.cpp"
#include <dcmtk/dcmdata/dcrleerg.h>
#include <dcmtk/dcmdata/dcrledrg.h>
#include <fstream>
#include <iterator>

static void Check(bool condition, const char* message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

struct TestAssociation
{
    TestAssociation()
    {
        Check(ASC_createAssociationParameters(&value.params, ASC_DEFAULTMAXPDU, 5).good(), "Create parameters");
    }
    ~TestAssociation() { ASC_destroyAssociationParameters(&value.params); }

    void accept(int id, const char* syntax, T_ASC_SC_ROLE role = ASC_SC_ROLE_SCP)
    {
        Check(ASC_addPresentationContext(value.params, id, UID_MRImageStorage, &syntax, 1, role).good(),
              "Propose context");
        Check(ASC_acceptPresentationContext(value.params, id, syntax, role).good(), "Accept context");
    }

    T_ASC_Association value = {};
};

static std::string ReadBytes(const std::string& path)
{
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), {});
}

static void WriteImage(const std::string& path, E_TransferSyntax syntax)
{
    DcmFileFormat file;
    DcmDataset& dataset = *file.getDataset();
    dataset.putAndInsertString(DCM_SOPClassUID, UID_MRImageStorage);
    dataset.putAndInsertString(DCM_SOPInstanceUID, "2.25.101");
    dataset.putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
    dataset.putAndInsertUint16(DCM_Rows, 16);
    dataset.putAndInsertUint16(DCM_Columns, 16);
    dataset.putAndInsertUint16(DCM_SamplesPerPixel, 1);
    dataset.putAndInsertUint16(DCM_BitsAllocated, 16);
    dataset.putAndInsertUint16(DCM_BitsStored, 16);
    dataset.putAndInsertUint16(DCM_HighBit, 15);
    dataset.putAndInsertUint16(DCM_PixelRepresentation, 0);
    Uint16 pixels[256];
    for (unsigned i = 0; i < 256; ++i) pixels[i] = i * 7;
    dataset.putAndInsertUint16Array(DCM_PixelData, pixels, 256);
    Check(dataset.chooseRepresentation(syntax, NULL).good(), "Prepare synthetic image");
    Check(file.saveFile(path.c_str(), syntax).good(), "Save synthetic image");
}

static void CheckConvertedPixels(GetSource& source)
{
    Check(source.datasetToSend != NULL, "Conversion returns a dataset");
    Check(source.datasetToSend->chooseRepresentation(EXS_LittleEndianExplicit, NULL).good(), "Decode result");
    const Uint16* pixels = NULL;
    unsigned long count = 0;
    Check(source.datasetToSend->findAndGetUint16Array(DCM_PixelData, pixels, &count).good() && count == 256,
          "Converted pixel count");
    for (unsigned i = 0; i < count; ++i) Check(pixels[i] == i * 7, "Lossless pixel values");
}

static void TestFormats(const std::string& directory)
{
    const std::string native = directory + "/native.dcm", compressed = directory + "/rle.dcm";
    DcmRLEEncoderRegistration::registerCodecs();
    DcmRLEDecoderRegistration::registerCodecs();
    WriteImage(native, EXS_LittleEndianExplicit);
    WriteImage(compressed, EXS_RLELossless);
    const std::string original = ReadBytes(compressed);
    {
        TestAssociation association;
        association.accept(1, UID_LittleEndianExplicitTransferSyntax);
        association.accept(3, UID_RLELosslessTransferSyntax);
        GetSource source(compressed.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, compressed.c_str()).good(), "Compressed exact match");
        Check(source.presentationID == 3 && source.datasetToSend == NULL, "Exact compressed file is streamed");
        GetSource plain(native.c_str());
        Check(plain.prepare(&association.value, UID_MRImageStorage, native.c_str()).good(), "Mixed series native match");
        Check(plain.presentationID == 1 && plain.datasetToSend == NULL, "Native file uses its own context");
    }
    {
        TestAssociation association;
        association.accept(1, UID_RLELosslessTransferSyntax, ASC_SC_ROLE_SCU);
        association.accept(3, UID_LittleEndianExplicitTransferSyntax);
        GetSource source(compressed.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, compressed.c_str()).good(), "Decompress for receiver");
        Check(source.presentationID == 3, "Wrong-role exact context is ignored");
        CheckConvertedPixels(source);
    }
    {
        TestAssociation association;
        association.accept(1, UID_RLELosslessTransferSyntax);
        GetSource source(native.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, native.c_str()).good(), "Compress for receiver");
        Check(source.datasetToSend && source.datasetToSend->canWriteXfer(EXS_RLELossless), "RLE available");
        CheckConvertedPixels(source);
    }
    {
        TestAssociation association;
        association.accept(1, UID_RLELosslessTransferSyntax, ASC_SC_ROLE_SCU);
        GetSource source(compressed.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, compressed.c_str()).bad(), "Reject wrong role");
        Check(source.presentationID == 0, "No send context on refusal");
    }
    DcmRLEDecoderRegistration::cleanup();
    {
        TestAssociation association;
        association.accept(1, UID_LittleEndianExplicitTransferSyntax);
        GetSource source(compressed.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, compressed.c_str()).bad(), "Missing codec fails cleanly");
    }
    {
        TestAssociation association;
        association.accept(1, UID_RLELosslessTransferSyntax);
        GetSource source(compressed.c_str());
        Check(source.prepare(&association.value, UID_MRImageStorage, compressed.c_str()).good(), "Exact match needs no decoder");
        Check(source.datasetToSend == NULL, "No decoding for compressed pass-through");
    }
    Check(ReadBytes(compressed) == original, "Source file is byte-for-byte unchanged");
    DcmRLEEncoderRegistration::cleanup();
    unlink(native.c_str());
    unlink(compressed.c_str());
}

class TestDatabase : public DcmQueryRetrieveDatabaseHandle
{
public:
    unsigned remaining = 2, starts = 0, nexts = 0, cancels = 0;
    bool failStart = false, failNext = false;
    std::string missingPath;

    OFCondition startMoveRequest(const char*, DcmDataset*, DcmQueryRetrieveDatabaseStatus* status) override
    {
        ++starts;
        status->setStatus(remaining ? STATUS_Pending : STATUS_Success);
        return failStart ? EC_IllegalCall : EC_Normal;
    }
    OFCondition nextMoveResponse(char* sopClass, size_t classSize, char* instance, size_t instanceSize,
                                 char* path, size_t pathSize, unsigned short* left,
                                 DcmQueryRetrieveDatabaseStatus* status) override
    {
        ++nexts;
        if (failNext) return EC_IllegalCall;
        status->setStatus(remaining ? STATUS_Pending : STATUS_Success);
        if (remaining) --remaining;
        *left = remaining;
        OFStandard::strlcpy(sopClass, UID_MRImageStorage, classSize);
        OFStandard::strlcpy(instance, remaining ? "2.25.101" : "2.25.102", instanceSize);
        OFStandard::strlcpy(path, missingPath.c_str(), pathSize);
        return EC_Normal;
    }
    OFCondition cancelMoveRequest(DcmQueryRetrieveDatabaseStatus* status) override
    {
        ++cancels;
        status->setStatus(STATUS_Success); // The handler must still report C-CANCEL.
        return EC_Normal;
    }
    OFCondition makeNewStoreFileName(const char*, const char*, char*, size_t) override { return EC_IllegalCall; }
    OFCondition storeRequest(const char*, const char*, const char*, DcmQueryRetrieveDatabaseStatus*, OFBool) override { return EC_IllegalCall; }
    OFCondition startFindRequest(const char*, DcmDataset*, DcmQueryRetrieveDatabaseStatus*) override { return EC_IllegalCall; }
    OFCondition nextFindResponse(DcmDataset**, DcmQueryRetrieveDatabaseStatus*, const DcmQueryRetrieveCharacterSetOptions&) override { return EC_IllegalCall; }
    OFCondition cancelFindRequest(DcmQueryRetrieveDatabaseStatus*) override { return EC_IllegalCall; }
    OFCondition pruneInvalidRecords() override { return EC_Normal; }
    void setIdentifierChecking(OFBool, OFBool) override {}
};

static T_DIMSE_C_GetRSP Respond(GetContext& context, int count, bool cancelled, OFString* failedUIDs = NULL)
{
    T_DIMSE_C_GetRQ request = {};
    request.MessageID = 5;
    OFStandard::strlcpy(request.AffectedSOPClassUID, UID_GETStudyRootQueryRetrieveInformationModel,
                        sizeof(request.AffectedSOPClassUID));
    DcmDataset identifiers;
    T_DIMSE_C_GetRSP response = {};
    DcmDataset* detail = NULL;
    DcmDataset* failures = NULL;
    GetContext::callback(&context, cancelled, &request, &identifiers, count, &response, &detail, &failures);
    if (failures && failedUIDs) failures->findAndGetOFStringArray(DCM_FailedSOPInstanceUIDList, *failedUIDs);
    delete failures;
    delete detail;
    return response;
}

static void TestResponses(const std::string& directory)
{
    DcmQueryRetrieveOptions options;
    TestAssociation association;
    {
        TestDatabase database;
        database.missingPath = directory + "/absent.dcm";
        GetContext context(database, options, &association.value, 1);
        auto response = Respond(context, 1, false);
        Check(response.DimseStatus == STATUS_Pending && response.NumberOfFailedSubOperations == 1 &&
              response.NumberOfRemainingSubOperations == 1, "Failed file counted in pending response");
        OFString failures;
        response = Respond(context, 2, true, &failures);
        Check(response.DimseStatus == STATUS_GET_Cancel_SubOperationsTerminatedDueToCancelIndication,
              "Earlier failure does not overwrite cancellation");
        Check(database.cancels == 1 && database.nexts == 1 && database.starts == 1, "Cancel stops enumeration");
        Check(failures == "2.25.101", "Cancel retains failed instance list");
    }
    {
        TestDatabase database;
        database.missingPath = directory + "/absent.dcm";
        GetContext context(database, options, &association.value, 1);
        Respond(context, 1, false);
        Respond(context, 2, false);
        OFString failures;
        auto response = Respond(context, 3, false, &failures);
        Check(response.DimseStatus == STATUS_GET_Refused_OutOfResourcesSubOperations &&
              response.NumberOfFailedSubOperations == 2 && response.NumberOfRemainingSubOperations == 0,
              "All failed is reported as failure, not success");
        Check(failures == "2.25.101\\2.25.102", "All failed UIDs are returned");
    }
    {
        TestDatabase database;
        database.failStart = true;
        GetContext context(database, options, &association.value, 1);
        Check(Respond(context, 1, false).DimseStatus == STATUS_GET_Refused_OutOfResourcesNumberOfMatches,
              "Start failure cannot leave a pending loop");
        Check(database.nexts == 0, "No enumeration after start failure");
    }
    {
        TestDatabase database;
        database.failNext = true;
        GetContext context(database, options, &association.value, 1);
        Check(Respond(context, 1, false).DimseStatus == STATUS_GET_Refused_OutOfResourcesSubOperations,
              "Enumeration failure terminates the request");
    }
    {
        TestDatabase database;
        database.remaining = 0;
        GetContext context(database, options, &association.value, 1);
        Check(Respond(context, 1, false).DimseStatus == STATUS_Success, "Empty result is successful");
        Check(database.nexts == 0, "No suboperation for empty result");
    }
}

class TestFactory : public DcmQueryRetrieveDatabaseHandleFactory
{
    DcmQueryRetrieveDatabaseHandle* createDBHandle(const char*, const char*, OFCondition& result) const override
    {
        result = EC_Normal;
        return new TestDatabase;
    }
};

class NegotiationFixture : public QueryRetrieveAssociation
{
public:
    using QueryRetrieveAssociation::QueryRetrieveAssociation;
    using QueryRetrieveAssociation::negotiateAssociation;
    using QueryRetrieveAssociation::checkCalledAETitleAccepted;
    using QueryRetrieveAssociation::handleIncomingCommand;
};

static void TestNegotiation(const std::string& directory)
{
    const std::string configPath = directory + "/listener.cfg";
    {
        std::ofstream output(configPath);
        output << "NetworkTCPPort 11112\nMaxPDUSize 16384\nMaxAssociations 8\n"
                  "HostTable BEGIN\nHostTable END\nVendorTable BEGIN\nVendorTable END\n"
                  "AETable BEGIN\nHOROS \"" << directory << "\" RW (20000, 1024mb) ANY\nAETable END\n";
    }
    DcmQueryRetrieveConfig config;
    Check(config.init(configPath.c_str()), "Load isolated listener config");
    DcmQueryRetrieveOptions options;
    options.singleProcess_ = OFTrue;
    options.supportPatientRoot_ = OFFalse;
    options.supportPatientStudyOnly_ = OFFalse;
    options.supportStudyRoot_ = OFTrue;
    options.incomingProfile = "TEST";
    DcmAssociationConfiguration profiles;
    profiles.setAlwaysAcceptDefaultRole(OFTrue);
    Check(profiles.addTransferSyntax("SYNTAXES", UID_LittleEndianExplicitTransferSyntax).good(), "Native profile syntax");
    Check(profiles.addTransferSyntax("SYNTAXES", UID_RLELosslessTransferSyntax).good(), "Compressed profile syntax");
    Check(profiles.addPresentationContext("CONTEXTS", UID_MRImageStorage, "SYNTAXES", OFFalse).good(), "Storage profile");
    Check(profiles.addRole("ROLES", UID_MRImageStorage, ASC_SC_ROLE_SCUSCP).good(), "Storage roles");
    Check(profiles.addProfile("TEST", "CONTEXTS", "ROLES").good(), "Association profile");
    TestFactory factory;
    HorosAssociationProcesses processes;
    TestAssociation association;
    ASC_setAPTitles(association.value.params, "CLIENT", "HOROS", NULL);
    const char* native = UID_LittleEndianExplicitTransferSyntax;
    const char* compressed = UID_RLELosslessTransferSyntax;
    auto propose = [&](int id, const char* sopClass, const char* syntax, T_ASC_SC_ROLE role = ASC_SC_ROLE_DEFAULT) {
        Check(ASC_addPresentationContext(association.value.params, id, sopClass, &syntax, 1, role).good(),
              "Propose listener service");
    };
    propose(1, UID_MRImageStorage, compressed, ASC_SC_ROLE_SCP);
    propose(3, UID_MRImageStorage, native);
    propose(5, UID_VerificationSOPClass, native);
    propose(7, UID_FINDStudyRootQueryRetrieveInformationModel, native);
    propose(9, UID_MOVEStudyRootQueryRetrieveInformationModel, native);
    propose(11, UID_GETStudyRootQueryRetrieveInformationModel, native);
    propose(13, UID_FINDPatientRootQueryRetrieveInformationModel, native);
    NegotiationFixture worker(&association.value, config, options, factory, profiles, processes, OFFalse);
    Check(worker.checkCalledAETitleAccepted("HOROS"), "Configured AE accepted");
    Check(!worker.checkCalledAETitleAccepted("UNKNOWN"), "Unknown AE rejected");
    Check(worker.negotiateAssociation().good(), "Negotiate storage plus services");
    auto accepted = [&](int id) {
        T_ASC_PresentationContext context;
        return ASC_findAcceptedPresentationContext(association.value.params, id, &context).good();
    };
    for (int id : {1, 3, 5, 7, 9, 11}) Check(accepted(id), "Expected service accepted");
    Check(!accepted(13), "Unsupported patient-root service refused");
    T_ASC_PresentationContext storage;
    Check(ASC_findAcceptedPresentationContext(association.value.params, 1, &storage).good() &&
          (storage.acceptedRole == ASC_SC_ROLE_SCP || storage.acceptedRole == ASC_SC_ROLE_SCUSCP),
          "C-GET receiver role retained");
    options.disableGetSupport_ = OFTrue;
    Check(worker.negotiateAssociation().good() && !accepted(11), "Disabled C-GET not negotiated");
    Check(accepted(3) && accepted(7) && accepted(9), "Store/find/move remain available");
    T_DIMSE_Message message = {};
    message.CommandField = DIMSE_C_GET_RQ;
    OFStandard::strlcpy(message.msg.CGetRQ.AffectedSOPClassUID, UID_GETStudyRootQueryRetrieveInformationModel,
                        sizeof(message.msg.CGetRQ.AffectedSOPClassUID));
    DcmPresentationContextInfo echoContext;
    echoContext.presentationContextID = 5;
    echoContext.abstractSyntax = UID_VerificationSOPClass;
    Check(worker.handleIncomingCommand(&message, echoContext) == DIMSE_BADMESSAGE,
          "Cannot retrieve using a verification context");
    unlink(configPath.c_str());
}

int main()
{
    char temporary[] = "/tmp/horos-query-retrieve-tests-XXXXXX";
    Check(mkdtemp(temporary) != NULL, "Create isolated fixture directory");
    TestFormats(temporary);
    TestResponses(temporary);
    TestNegotiation(temporary);
    rmdir(temporary);
    printf("Horos query/retrieve tests passed.\n");
    return EXIT_SUCCESS;
}
