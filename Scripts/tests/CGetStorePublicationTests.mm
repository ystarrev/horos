// Standalone fixture, never an application source. Runtime execution needs build approval.
// test_dcm_cget_incremental.py supplies the actual production callback in this include.
#import <Foundation/Foundation.h>
#include <cerrno>
#include <cstdio>
#include <unistd.h>
#undef verify
#include "HorosDICOMStoreValidation.h"

@interface DicomDatabase : NSObject
{
@public
    NSUInteger arrivals;
}
- (void)incomingFileDidBecomeAvailable;
@end

@implementation DicomDatabase
- (void)incomingFileDidBecomeAvailable { ++arrivals; }
@end

#include "HorosCGetStoreContext.inc"

static void Check(bool condition, const char *message)
{
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(EXIT_FAILURE); }
}

static void WriteStoreFile(NSString *path, const char *sopClass, const char *instance)
{
    DcmFileFormat file;
    file.getDataset()->putAndInsertString(DCM_SOPClassUID, sopClass);
    file.getDataset()->putAndInsertString(DCM_SOPInstanceUID, instance);
    file.getDataset()->putAndInsertString(DCM_PatientName, "SYNTHETIC^TEST");
    Check(file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), "Write synthetic store");
}

static DIC_US Respond(HorosCGetStoreContext& context, const char *sopClass, const char *instance,
                      T_DIMSE_StoreProgressState state = DIMSE_StoreEnd, DIC_US status = STATUS_Success)
{
    T_DIMSE_StoreProgress progress = {};
    progress.state = state;
    T_DIMSE_C_StoreRQ request = {};
    OFStandard::strlcpy(request.AffectedSOPClassUID, sopClass, sizeof(request.AffectedSOPClassUID));
    OFStandard::strlcpy(request.AffectedSOPInstanceUID, instance, sizeof(request.AffectedSOPInstanceUID));
    T_DIMSE_C_StoreRSP response = {};
    response.DimseStatus = status;
    HorosCGetStoreContext::callback(&context, &progress, &request, NULL, NULL, &response, NULL);
    return response.DimseStatus;
}

int main()
{
    @autoreleasepool
    {
        char temporary[] = "/tmp/horos-cget-publication-XXXXXX";
        Check(mkdtemp(temporary) != NULL, "Create isolated directory");
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *root = [files stringWithFileSystemRepresentation:temporary length:strlen(temporary)];
        NSString *staging = [root stringByAppendingPathComponent:@"staging"];
        NSString *incoming = [root stringByAppendingPathComponent:@"incoming"];
        Check([files createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:NULL], "Create staging");
        Check([files createDirectoryAtPath:incoming withIntermediateDirectories:YES attributes:nil error:NULL], "Create incoming");
        DicomDatabase *database = [[[DicomDatabase alloc] init] autorelease];

        NSUInteger index = 0;
        for (const char *sopClass : {UID_MRImageStorage, UID_BasicTextSRStorage, UID_EncapsulatedPDFStorage})
        {
            NSString *filename = [staging stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.dcm", (unsigned long)index]];
            NSString *destination = [incoming stringByAppendingPathComponent:filename.lastPathComponent];
            WriteStoreFile(filename, sopClass, "2.25.101");
            NSData *original = [NSData dataWithContentsOfFile:filename];
            HorosCGetStoreContext context = {database, filename, incoming, EXS_LittleEndianExplicit, OFFalse};
            Respond(context, sopClass, "2.25.101", DIMSE_StoreProgressing);
            Check(!context.published && database->arrivals == index && ![files fileExistsAtPath:destination],
                  "Incomplete file never becomes visible to importer");
            Check(Respond(context, sopClass, "2.25.101") == STATUS_Success, "Accept completed store");
            Check(context.published && ![files fileExistsAtPath:filename] && database->arrivals == ++index,
                  "Each file publishes and signals immediately without waiting for session completion");
            Check([[NSData dataWithContentsOfFile:destination] isEqualToData:original], "Incoming bytes are unchanged");
        }

        NSString *filename = [staging stringByAppendingPathComponent:@"rejected.dcm"];
        WriteStoreFile(filename, UID_MRImageStorage, "2.25.999");
        HorosCGetStoreContext mismatch = {database, filename, incoming, EXS_LittleEndianExplicit, OFFalse};
        Check(Respond(mismatch, UID_MRImageStorage, "2.25.101") == STATUS_STORE_Error_DataSetDoesNotMatchSOPClass,
              "Mismatched dataset gets a failed C-STORE response");
        Check(!mismatch.published && !mismatch.retainStagedFile && database->arrivals == index, "Bad UID cannot trigger import");

        WriteStoreFile(filename, UID_MRImageStorage, "2.25.101");
        NSString *destination = [incoming stringByAppendingPathComponent:filename.lastPathComponent];
        WriteStoreFile(destination, UID_MRImageStorage, "2.25.888");
        NSData *existing = [NSData dataWithContentsOfFile:destination];
        HorosCGetStoreContext collision = {database, filename, incoming, EXS_LittleEndianExplicit, OFFalse};
        Check(Respond(collision, UID_MRImageStorage, "2.25.101") == STATUS_STORE_Refused_OutOfResources,
              "Destination collision must not be acknowledged as successful storage");
        Check(!collision.published && collision.retainStagedFile && [files fileExistsAtPath:filename] && database->arrivals == index,
              "Failed publication retains completed source without import notification");
        Check([[NSData dataWithContentsOfFile:destination] isEqualToData:existing], "Existing arrival is never overwritten");

        HorosCGetStoreContext unavailable = {database, filename, [root stringByAppendingPathComponent:@"missing"], EXS_LittleEndianExplicit, OFFalse};
        Check(Respond(unavailable, UID_MRImageStorage, "2.25.101") == STATUS_STORE_Refused_OutOfResources && unavailable.retainStagedFile,
              "Unavailable incoming directory retains completed source for recovery");

        HorosCGetStoreContext interrupted = {database, filename, incoming, EXS_LittleEndianExplicit, OFFalse};
        Check(Respond(interrupted, UID_MRImageStorage, "2.25.101", DIMSE_StoreEnd, STATUS_STORE_Refused_OutOfResources) == STATUS_STORE_Refused_OutOfResources,
              "Receive failure is preserved");
        Check(!interrupted.published && database->arrivals == index, "Failed receive does not publish or signal");
        Check([files removeItemAtPath:root error:NULL], "Remove isolated fixture directory");
        printf("C-GET store publication tests passed.\n");
    }
    return EXIT_SUCCESS;
}
