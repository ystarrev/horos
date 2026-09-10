#include "HorosQueryRetrieveServer.h"

#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmnet/scpthrd.h>
#include <dcmtk/dcmqrdb/dcmqrcbf.h>
#include <dcmtk/dcmqrdb/dcmqrcbm.h>
#include <dcmtk/dcmqrdb/dcmqrcbs.h>
#include <dcmtk/dcmqrdb/dcmqrdbs.h>
#include <dcmtk/ofstd/ofstd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <sys/file.h>
#include <sys/param.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

class HorosAssociationProcesses
{
public:
    size_t countChildProcesses() const { return processes_.size(); }

    bool haveProcessWithWriteAccess(const char* calledAE) const
    {
        return std::any_of(processes_.begin(), processes_.end(), [&](const Process& process) {
            return process.canStore && process.calledAE == calledAE;
        });
    }

    void addProcessToTable(pid_t pid, T_ASC_Association* association)
    {
        bool canStore = false;
        for (int index = 0; index < ASC_countPresentationContexts(association->params); ++index)
        {
            T_ASC_PresentationContext context;
            if (ASC_getPresentationContext(association->params, index, &context).good() &&
                context.resultReason == ASC_P_ACCEPTANCE && dcmIsaStorageSOPClassUID(context.abstractSyntax) &&
                context.acceptedRole != ASC_SC_ROLE_SCP)
                canStore = true;
        }
        processes_.push_back({pid, association->params->DULparams.calledAPTitle, canStore});
    }

    void cleanChildren()
    {
        // Never use waitpid(-1): Numbers, Bonjour and other Horos helpers own
        // their child processes, as does the other (TLS/non-TLS) listener.
        processes_.erase(std::remove_if(processes_.begin(), processes_.end(), [](const Process& process) {
            int status = 0;
            const pid_t result = waitpid(process.id, &status, WNOHANG);
            return result == process.id || (result < 0 && errno == ECHILD);
        }), processes_.end());
    }

private:
    struct Process { pid_t id; OFString calledAE; bool canStore; };
    std::vector<Process> processes_;
};

namespace {

class ScopedFileLock
{
public:
    ScopedFileLock(const char* path, bool writing)
        : fd_(open(path, writing ? O_WRONLY | O_CREAT : O_RDONLY, 0666))
    {
        if (fd_ >= 0)
        {
            int result;
            do { result = flock(fd_, writing ? LOCK_EX : LOCK_SH); }
            while (result < 0 && errno == EINTR);
            if (result < 0)
            {
                close(fd_);
                fd_ = -1;
            }
        }
    }

    ~ScopedFileLock()
    {
        if (fd_ >= 0)
        {
            flock(fd_, LOCK_UN);
            close(fd_);
        }
    }

    bool valid() const { return fd_ >= 0; }

private:
    int fd_;
    ScopedFileLock(const ScopedFileLock&) = delete;
    ScopedFileLock& operator=(const ScopedFileLock&) = delete;
};

struct GetSource
{
    explicit GetSource(const char* path) : lock(path, false) {}

    OFCondition prepare(T_ASC_Association* association, const char* sopClass, const char* path)
    {
        if (!lock.valid()) return EC_InvalidStream;
        OFCondition result = file.loadFileUntilTag(path, EXS_Unknown, EGL_noChange,
            DCM_MaxReadLength, ERM_autoDetect, DCM_PixelData);
        if (result.bad()) return result;

        const E_TransferSyntax original = file.getDataset()->getOriginalXfer();
        struct Candidate { T_ASC_PresentationContextID id; E_TransferSyntax syntax; int rank; };
        std::vector<Candidate> candidates;
        for (int index = 0; index < ASC_countPresentationContexts(association->params); ++index)
        {
            T_ASC_PresentationContext context;
            if (ASC_getPresentationContext(association->params, index, &context).bad() ||
                context.resultReason != ASC_P_ACCEPTANCE || strcmp(context.abstractSyntax, sopClass) != 0 ||
                (context.acceptedRole != ASC_SC_ROLE_SCP && context.acceptedRole != ASC_SC_ROLE_SCUSCP))
                continue;

            const DcmXfer accepted(context.acceptedTransferSyntax);
            if (!accepted.isValid()) continue;
            const int rank = accepted.getXfer() == original ? 0 :
                accepted.getXfer() == EXS_LittleEndianExplicit ? 1 :
                accepted.getXfer() == EXS_BigEndianExplicit ? 2 :
                accepted.getXfer() == EXS_LittleEndianImplicit ? 3 : 4;
            candidates.push_back({context.presentationContextID, accepted.getXfer(), rank});
        }
        std::stable_sort(candidates.begin(), candidates.end(),
            [](const Candidate& lhs, const Candidate& rhs) { return lhs.rank < rhs.rank; });

        bool loaded = false;
        result = DIMSE_NOVALIDPRESENTATIONCONTEXTID;
        for (const Candidate& candidate : candidates)
        {
            const DcmXfer accepted(candidate.syntax);
            const DcmXfer source(original);
            // Exact matches stay on DCMTK's file-streaming path. Only pixel
            // representation changes need a fully loaded dataset and codecs.
            const bool convert = accepted.getXfer() != original &&
                (accepted.usesEncapsulatedFormat() || source.usesEncapsulatedFormat());
            if (convert)
            {
                if (!loaded)
                {
                    result = file.loadFile(path);
                    if (result.bad()) return result;
                    loaded = true;
                }
                DcmDataset* dataset = file.getDataset();
                if (!dataset->canWriteXfer(accepted.getXfer()))
                {
                    result = dataset->chooseRepresentation(accepted.getXfer(), NULL);
                    if (result.bad()) continue;
                }
                if (!dataset->canWriteXfer(accepted.getXfer()))
                {
                    result = DIMSE_SENDFAILED;
                    continue;
                }
                datasetToSend = dataset;
            }
            presentationID = candidate.id;
            return EC_Normal;
        }
        return result;
    }

    ScopedFileLock lock;
    DcmFileFormat file;
    DcmDataset* datasetToSend = NULL;
    T_ASC_PresentationContextID presentationID = 0;
};

class GetContext
{
public:
    GetContext(DcmQueryRetrieveDatabaseHandle& database, const DcmQueryRetrieveOptions& options,
               T_ASC_Association* association, T_ASC_PresentationContextID presentationID)
        : database_(database), options_(options), association_(association), presentationID_(presentationID) {}

    static void callback(void* data, OFBool cancelled, T_DIMSE_C_GetRQ* request,
                         DcmDataset* identifiers, int responseCount, T_DIMSE_C_GetRSP* response,
                         DcmDataset** detail, DcmDataset** responseIdentifiers)
    {
        static_cast<GetContext*>(data)->respond(cancelled, request, identifiers, responseCount,
                                               response, detail, responseIdentifiers);
    }

private:
    void respond(OFBool cancelled, T_DIMSE_C_GetRQ* request, DcmDataset* identifiers,
                 int responseCount, T_DIMSE_C_GetRSP* response, DcmDataset** detail,
                 DcmDataset** responseIdentifiers)
    {
        DcmQueryRetrieveDatabaseStatus status(STATUS_Pending);
        OFCondition result = EC_Normal;
        if (responseCount == 1)
            result = database_.startMoveRequest(request->AffectedSOPClassUID, identifiers, &status);
        if (result.bad() && status.status() == STATUS_Pending)
            status.setStatus(STATUS_GET_Refused_OutOfResourcesNumberOfMatches);

        if (cancelled && status.status() == STATUS_Pending)
            cancel(status);
        if (status.status() == STATUS_Pending)
        {
            DIC_UI sopClass = {}, sopInstance = {};
            char path[MAXPATHLEN + 1] = {};
            result = database_.nextMoveResponse(sopClass, sizeof(sopClass), sopInstance, sizeof(sopInstance),
                path, sizeof(path), &remaining_, &status);
            if (result.bad())
                status.setStatus(STATUS_GET_Refused_OutOfResourcesSubOperations);
            else if (status.status() == STATUS_Pending)
                sendImage(request, sopClass, sopInstance, path, status);
        }

        // Do not turn a cancellation or database error into success/warning.
        if (status.status() == STATUS_Success && (failed_ || warnings_))
            status.setStatus(failed_ && !completed_ && !warnings_
                ? STATUS_GET_Refused_OutOfResourcesSubOperations
                : STATUS_GET_Warning_SubOperationsCompleteOneOrMoreFailures);
        if (status.status() != STATUS_Success && status.status() != STATUS_Pending && !failedUIDs_.empty())
        {
            *responseIdentifiers = new DcmDataset;
            (*responseIdentifiers)->putAndInsertString(DCM_FailedSOPInstanceUIDList, failedUIDs_.c_str());
        }
        response->DimseStatus = status.status();
        response->NumberOfRemainingSubOperations = remaining_;
        response->NumberOfCompletedSubOperations = completed_;
        response->NumberOfFailedSubOperations = failed_;
        response->NumberOfWarningSubOperations = warnings_;
        *detail = status.extractStatusDetail();
    }

    void cancel(DcmQueryRetrieveDatabaseStatus& status)
    {
        database_.cancelMoveRequest(&status);
        status.setStatus(STATUS_GET_Cancel_SubOperationsTerminatedDueToCancelIndication);
    }

    void failed(const char* sopInstance)
    {
        ++failed_;
        if (sopInstance[0])
        {
            if (!failedUIDs_.empty()) failedUIDs_ += "\\";
            failedUIDs_ += sopInstance;
        }
    }

    void sendImage(T_DIMSE_C_GetRQ* request, const char* sopClass, const char* sopInstance,
                   const char* path, DcmQueryRetrieveDatabaseStatus& status)
    {
        GetSource source(path);
        OFCondition result = source.prepare(association_, sopClass, path);
        if (result.bad())
        {
            failed(sopInstance);
            DCMQRDB_ERROR("Horos C-GET: cannot prepare instance " << sopInstance << ": " << result.text());
            return;
        }

        T_DIMSE_C_StoreRQ storeRequest = {};
        storeRequest.MessageID = association_->nextMsgID++;
        storeRequest.Priority = request->Priority;
        storeRequest.DataSetType = DIMSE_DATASET_PRESENT;
        OFStandard::strlcpy(storeRequest.AffectedSOPClassUID, sopClass, sizeof(storeRequest.AffectedSOPClassUID));
        OFStandard::strlcpy(storeRequest.AffectedSOPInstanceUID, sopInstance, sizeof(storeRequest.AffectedSOPInstanceUID));
        T_DIMSE_C_StoreRSP response = {};
        T_DIMSE_DetectedCancelParameters cancellation = {};
        DcmDataset* detail = NULL;
        result = DIMSE_storeUser(association_, source.presentationID, &storeRequest,
            source.datasetToSend ? NULL : path, source.datasetToSend, NULL, NULL,
            options_.blockMode_, options_.dimse_timeout_, &response, &detail, &cancellation);
        delete detail;

        if (result.good() && response.DimseStatus == STATUS_Success)
            ++completed_;
        else if (result.good() && DICOM_WARNING_STATUS(response.DimseStatus))
            ++warnings_;
        else
        {
            failed(sopInstance);
            DCMQRDB_ERROR("Horos C-GET: store sub-operation failed: " << result.text()
                << ", status " << response.DimseStatus);
        }
        if (result.bad())
        {
            // A failed DIMSE exchange may have left the association unusable.
            // Stop rather than consuming the remaining database results.
            DcmQueryRetrieveDatabaseStatus cleanup;
            database_.cancelMoveRequest(&cleanup);
            status.setStatus(STATUS_GET_Refused_OutOfResourcesSubOperations);
        }
        if (cancellation.cancelEncountered && cancellation.presId == presentationID_ &&
            cancellation.req.MessageIDBeingRespondedTo == request->MessageID)
            cancel(status);
    }

    DcmQueryRetrieveDatabaseHandle& database_;
    const DcmQueryRetrieveOptions& options_;
    T_ASC_Association* association_;
    T_ASC_PresentationContextID presentationID_;
    unsigned short remaining_ = 0, completed_ = 0, failed_ = 0, warnings_ = 0;
    OFString failedUIDs_;
};

void findCallback(void* data, OFBool cancelled, T_DIMSE_C_FindRQ* request, DcmDataset* identifiers,
                  int count, T_DIMSE_C_FindRSP* response, DcmDataset** detail, DcmDataset** responseIdentifiers)
{
    static_cast<DcmQueryRetrieveFindContext*>(data)->callbackHandler(
        cancelled, request, identifiers, count, response, detail, responseIdentifiers);
}

void moveCallback(void* data, OFBool cancelled, T_DIMSE_C_MoveRQ* request, DcmDataset* identifiers,
                  int count, T_DIMSE_C_MoveRSP* response, DcmDataset** detail, DcmDataset** responseIdentifiers)
{
    static_cast<DcmQueryRetrieveMoveContext*>(data)->callbackHandler(
        cancelled, request, identifiers, count, response, detail, responseIdentifiers);
}

void storeCallback(void* data, T_DIMSE_StoreProgress* progress, T_DIMSE_C_StoreRQ* request,
                   char* path, DcmDataset** dataset, T_DIMSE_C_StoreRSP* response, DcmDataset** detail)
{
    static_cast<DcmQueryRetrieveStoreContext*>(data)->callbackHandler(
        progress, request, path, dataset, response, detail);
}

class QueryRetrieveAssociation : public DcmThreadSCP
{
public:
    QueryRetrieveAssociation(T_ASC_Association* association, const DcmQueryRetrieveConfig& config,
                              const DcmQueryRetrieveOptions& options,
                              const DcmQueryRetrieveDatabaseHandleFactory& factory,
                              const DcmAssociationConfiguration& profiles,
                              HorosAssociationProcesses& processes, OFBool secureConnection)
        : association_(association), config_(config), options_(options), factory_(factory),
          profiles_(profiles), processes_(processes), secureConnection_(secureConnection)
    {
        setRespondWithCalledAETitle(OFTrue);
        forceAssociationRefuse(options_.refuse_);
        setACSETimeout(options_.acse_timeout_);
        setDIMSEBlockingMode(DIMSE_BLOCKING);
        setProgressNotificationMode(OFFalse);
    }

protected:
    void notifyAssociationRequest(const T_ASC_Parameters& parameters, DcmSCPActionType& action) override
    {
        if ((options_.rejectWhenNoImplementationClassUID_ && !parameters.theirImplementationClassUID[0]) ||
            processes_.countChildProcesses() >= static_cast<size_t>(options_.maxAssociations_))
            action = DCMSCP_ACTION_REFUSE_ASSOCIATION;
    }

    OFBool checkCalledAETitleAccepted(const OFString& calledAE) override
    {
        const auto& parameters = association_->params->DULparams;
        return config_.peerInAETitle(calledAE.c_str(), parameters.callingAPTitle,
                                     parameters.callingPresentationAddress);
    }

    OFCondition negotiateAssociation() override
    {
        OFCondition result = profiles_.evaluateAssociationParameters(options_.incomingProfile.c_str(), *association_);
        if (result.bad())
        {
            DCMQRDB_ERROR("Horos listener: association profile failed: " << result.text());
            refuseAssociation(DCMSCP_INTERNAL_ERROR);
            return result;
        }
        std::vector<const char*> syntaxes;
        DcmXfer preferred(options_.networkTransferSyntax_);
        if (preferred.isValid()) syntaxes.push_back(preferred.getXferID());
        if (options_.networkTransferSyntax_ != EXS_LittleEndianImplicit)
        {
            syntaxes.push_back(UID_LittleEndianExplicitTransferSyntax);
            syntaxes.push_back(UID_BigEndianExplicitTransferSyntax);
            syntaxes.push_back(UID_LittleEndianImplicitTransferSyntax);
        }
        const char* services[] = {
            UID_VerificationSOPClass,
            UID_FINDPatientRootQueryRetrieveInformationModel, UID_MOVEPatientRootQueryRetrieveInformationModel,
            UID_GETPatientRootQueryRetrieveInformationModel,
            UID_FINDStudyRootQueryRetrieveInformationModel, UID_MOVEStudyRootQueryRetrieveInformationModel,
            UID_GETStudyRootQueryRetrieveInformationModel,
            UID_RETIRED_FINDPatientStudyOnlyQueryRetrieveInformationModel,
            UID_RETIRED_MOVEPatientStudyOnlyQueryRetrieveInformationModel,
            UID_RETIRED_GETPatientStudyOnlyQueryRetrieveInformationModel
        };
        std::vector<const char*> enabled(1, services[0]);
        const bool roots[] = {bool(options_.supportPatientRoot_), bool(options_.supportStudyRoot_),
                              bool(options_.supportPatientStudyOnly_)};
        for (int root = 0; root < 3; ++root)
            if (roots[root])
                for (int service = 0; service < (options_.disableGetSupport_ ? 2 : 3); ++service)
                    enabled.push_back(services[1 + root * 3 + service]);
        result = ASC_acceptContextsWithPreferredTransferSyntaxes(association_->params,
            enabled.data(), static_cast<int>(enabled.size()), syntaxes.data(), static_cast<int>(syntaxes.size()));
        if (result.bad()) return result;

        const char* calledAE = association_->params->DULparams.calledAPTitle;
        const bool refuseStorage = !config_.writableStorageArea(calledAE) ||
            (options_.refuseMultipleStorageAssociations_ && processes_.haveProcessWithWriteAccess(calledAE));
        for (int index = 0; index < ASC_countPresentationContexts(association_->params); ++index)
        {
            T_ASC_PresentationContext context;
            if (ASC_getPresentationContext(association_->params, index, &context).bad() ||
                context.resultReason != ASC_P_ACCEPTANCE) continue;
            if (refuseStorage && dcmIsaStorageSOPClassUID(context.abstractSyntax) &&
                context.acceptedRole != ASC_SC_ROLE_SCP)
                ASC_refusePresentationContext(association_->params, context.presentationContextID, ASC_P_USERREJECTION);
            if (options_.requireFindForMove_)
                for (int root = 0; root < 3; ++root)
                    if (strcmp(context.abstractSyntax, services[2 + root * 3]) == 0 &&
                        !ASC_findAcceptedPresentationContextID(association_, services[1 + root * 3]))
                        ASC_refusePresentationContext(association_->params, context.presentationContextID, ASC_P_USERREJECTION);
        }
        return EC_Normal;
    }

    void handleAssociation() override
    {
        // Preserve Horos's existing single-process/fork listener policy. No
        // database handle is opened in the parent before a worker is forked.
        bool child = false;
#ifdef HAVE_FORK
        if (!options_.singleProcess_)
        {
            const pid_t pid = fork();
            if (pid < 0)
            {
                DCMQRDB_ERROR("Horos listener: cannot fork association worker");
                abortAssociation();
                return;
            }
            if (pid > 0)
            {
                ASC_setParentProcessMode(association_);
                processes_.addProcessToTable(pid, association_);
                return;
            }
            child = true;
        }
#endif
        DcmSCP::handleAssociation();
        database_.reset(); // The Horos handle schedules import of received files.
        if (child)
        {
            dropAndDestroyAssociation();
            exit(0);
        }
    }

    OFCondition handleIncomingCommand(T_DIMSE_Message* message, const DcmPresentationContextInfo& context) override
    {
        if (message->CommandField == DIMSE_C_CANCEL_RQ) return EC_Normal; // Late cancellation.
        const char* sopClass = NULL;
        switch (message->CommandField)
        {
            case DIMSE_C_ECHO_RQ: sopClass = message->msg.CEchoRQ.AffectedSOPClassUID; break;
            case DIMSE_C_STORE_RQ: sopClass = message->msg.CStoreRQ.AffectedSOPClassUID; break;
            case DIMSE_C_FIND_RQ: sopClass = message->msg.CFindRQ.AffectedSOPClassUID; break;
            case DIMSE_C_MOVE_RQ: sopClass = message->msg.CMoveRQ.AffectedSOPClassUID; break;
            case DIMSE_C_GET_RQ: sopClass = message->msg.CGetRQ.AffectedSOPClassUID; break;
            default: return DIMSE_BADCOMMANDTYPE;
        }
        if (context.abstractSyntax != sopClass) return DIMSE_BADMESSAGE;
        T_ASC_PresentationContext accepted;
        if (ASC_findAcceptedPresentationContext(association_->params, context.presentationContextID, &accepted).bad() ||
            accepted.acceptedRole == ASC_SC_ROLE_SCP)
            return DIMSE_NOVALIDPRESENTATIONCONTEXTID;

        OFCondition result = EC_Normal;
        if (!database_)
        {
            database_.reset(factory_.createDBHandle(association_->params->DULparams.callingAPTitle,
                association_->params->DULparams.calledAPTitle, result));
            if (result.bad() || !database_) return result.bad() ? result : EC_IllegalCall;
            database_->setIdentifierChecking(OFFalse, OFFalse);
        }
        result = dispatch(message, context);
        if (!options_.keepDBHandleDuringAssociation_) database_.reset();
        return result;
    }

private:
    OFCondition dispatch(T_DIMSE_Message* message, const DcmPresentationContextInfo& context)
    {
        const auto id = context.presentationContextID;
        const char* calledAE = association_->params->DULparams.calledAPTitle;
        switch (message->CommandField)
        {
            case DIMSE_C_ECHO_RQ:
                return DcmSCP::handleIncomingCommand(message, context);
            case DIMSE_C_STORE_RQ:
                return store(message->msg.CStoreRQ, id);
            case DIMSE_C_FIND_RQ:
            {
                DcmQueryRetrieveFindContext find(*database_, options_, STATUS_Pending, config_.getCharacterSetOptions());
                find.setOurAETitle(calledAE);
                return DIMSE_findProvider(association_, id, &message->msg.CFindRQ, findCallback, &find,
                    options_.blockMode_, options_.dimse_timeout_);
            }
            case DIMSE_C_MOVE_RQ:
            {
                auto& request = message->msg.CMoveRQ;
                DcmQueryRetrieveMoveContext move(*database_, options_, profiles_, &config_, STATUS_Pending,
                    association_, request.MessageID, request.Priority, secureConnection_);
                move.setOurAETitle(calledAE);
                return DIMSE_moveProvider(association_, id, &request, moveCallback, &move,
                    options_.blockMode_, options_.dimse_timeout_);
            }
            case DIMSE_C_GET_RQ:
            {
                GetContext get(*database_, options_, association_, id);
                return DIMSE_getProvider(association_, id, &message->msg.CGetRQ, GetContext::callback, &get,
                    options_.blockMode_, options_.dimse_timeout_);
            }
            default:
                return DIMSE_BADCOMMANDTYPE;
        }
    }

    OFCondition store(T_DIMSE_C_StoreRQ& request, T_ASC_PresentationContextID id)
    {
        DcmFileFormat file;
        DcmQueryRetrieveStoreContext context(*database_, options_, STATUS_Success, &file, options_.correctUIDPadding_);
        char path[MAXPATHLEN + 1] = {};
        if (!dcmIsaStorageSOPClassUID(request.AffectedSOPClassUID))
            context.setStatus(STATUS_STORE_Refused_SOPClassNotSupported);
        else if (!options_.ignoreStoreData_ && database_->makeNewStoreFileName(request.AffectedSOPClassUID,
            request.AffectedSOPInstanceUID, path, sizeof(path)).bad())
            context.setStatus(STATUS_STORE_Refused_OutOfResources);
        if (!path[0] || context.getStatus() != STATUS_Success)
            OFStandard::strlcpy(path, NULL_DEVICE_NAME, sizeof(path));

        ScopedFileLock lock(path, true);
        if (!lock.valid())
        {
            context.setStatus(STATUS_STORE_Refused_OutOfResources);
            OFStandard::strlcpy(path, NULL_DEVICE_NAME, sizeof(path));
        }
        context.setFileName(path);
        file.getMetaInfo()->putAndInsertString(DCM_SourceApplicationEntityTitle,
            association_->params->DULparams.callingAPTitle);
        DcmDataset* dataset = file.getDataset();
        // Even a refused store must consume the incoming dataset before replying.
        OFCondition result = DIMSE_storeProvider(association_, id, &request,
            options_.bitPreserving_ ? path : NULL, options_.useMetaheader_,
            options_.bitPreserving_ ? NULL : &dataset, storeCallback, &context,
            options_.blockMode_, options_.dimse_timeout_);
        if (!options_.ignoreStoreData_ && (result.bad() || context.getStatus() != STATUS_Success))
        {
            if (strcmp(path, NULL_DEVICE_NAME) != 0) OFStandard::deleteFile(path);
            database_->pruneInvalidRecords();
        }
        return result;
    }

    T_ASC_Association* association_; // Borrowed; DcmThreadSCP owns it after run().
    const DcmQueryRetrieveConfig& config_;
    const DcmQueryRetrieveOptions& options_;
    const DcmQueryRetrieveDatabaseHandleFactory& factory_;
    const DcmAssociationConfiguration& profiles_;
    HorosAssociationProcesses& processes_;
    OFBool secureConnection_;
    std::unique_ptr<DcmQueryRetrieveDatabaseHandle> database_;
};

} // namespace

HorosQueryRetrieveServer::HorosQueryRetrieveServer(const DcmQueryRetrieveConfig& config,
    const DcmQueryRetrieveOptions& options, const DcmQueryRetrieveDatabaseHandleFactory& factory,
    const DcmAssociationConfiguration& associations, OFBool secureConnection)
    : config_(config), options_(options), factory_(factory), associations_(associations),
      secureConnection_(secureConnection), processes_(new HorosAssociationProcesses) {}

HorosQueryRetrieveServer::~HorosQueryRetrieveServer() = default;

OFCondition HorosQueryRetrieveServer::waitForAssociation(T_ASC_Network* network)
{
    processes_->cleanChildren();
    if (!ASC_associationWaiting(network, 1)) return EC_Normal;

    T_ASC_Association* association = NULL;
    OFCondition result = ASC_receiveAssociation(network, &association, options_.maxPDU_, NULL, NULL,
        secureConnection_, DUL_BLOCK, options_.acse_timeout_);
    if (result.bad())
    {
        if (association)
        {
            ASC_dropAssociation(association);
            ASC_destroyAssociation(&association);
        }
        return result;
    }
    QueryRetrieveAssociation worker(association, config_, options_, factory_, associations_, *processes_, secureConnection_);
    return worker.run(association);
}
