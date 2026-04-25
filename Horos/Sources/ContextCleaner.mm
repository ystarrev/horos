/*=========================================================================\
  Program:   Horos

  Lightweight compatibility implementation for the legacy DCMTK Query/Retrieve
  cleanup hook.  Modern DCMTK owns accepted association cleanup internally, but
  Horos still calls this class while shutting the SCP loop down.
=========================================================================*/

#import "ContextCleaner.h"
#import <CoreData/CoreData.h>

int AbortAssociationTimeOut = -1;
BOOL forkedProcess = NO;
int gPutDstAETitleInPrivateInformationCreatorUID = 0;
int gPutSrcAETitleInSourceApplicationEntityTitle = 0;
NSManagedObjectContext *staticContext = nil;


@implementation ContextCleaner

+ (void)waitForHandledAssociations
{
    // Legacy DCMTK tracked worker associations here. Modern DcmQueryRetrieveSCP
    // handles association lifetime internally, so there is nothing to drain.
}

@end
