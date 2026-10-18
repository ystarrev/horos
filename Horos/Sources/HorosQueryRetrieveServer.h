#ifndef HOROS_QUERY_RETRIEVE_SERVER_H
#define HOROS_QUERY_RETRIEVE_SERVER_H

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/dcasccfg.h>
#include <dcmtk/dcmqrdb/dcmqrdba.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <memory>

class HorosAssociationProcesses;
class HorosAssociationThreads;

// Enter Cocoa with an autorelease pool on each C++ association worker.
extern "C" void HorosRunListenerWorker(void (*operation)(void*), void* context);

// Application integration over stock DCMTK. DCMTK owns association/DIMSE
// processing; Horos supplies database access, streamed-store validation and
// per-image C-GET selection.
class HorosQueryRetrieveServer
{
public:
    HorosQueryRetrieveServer(const DcmQueryRetrieveConfig& config,
                             const DcmQueryRetrieveOptions& options,
                             const DcmQueryRetrieveDatabaseHandleFactory& factory,
                             const DcmAssociationConfiguration& associations,
                             OFBool secureConnection);
    ~HorosQueryRetrieveServer();

    OFCondition waitForAssociation(T_ASC_Network* network);
    void waitForWorkers();

private:
    const DcmQueryRetrieveConfig& config_;
    const DcmQueryRetrieveOptions& options_;
    const DcmQueryRetrieveDatabaseHandleFactory& factory_;
    const DcmAssociationConfiguration& associations_;
    OFBool secureConnection_;
    std::unique_ptr<HorosAssociationProcesses> processes_;
    std::unique_ptr<HorosAssociationThreads> threads_;

    HorosQueryRetrieveServer(const HorosQueryRetrieveServer&) = delete;
    HorosQueryRetrieveServer& operator=(const HorosQueryRetrieveServer&) = delete;
};

#endif
