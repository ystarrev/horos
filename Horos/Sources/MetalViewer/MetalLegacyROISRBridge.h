#import <Foundation/Foundation.h>

@class NSManagedObjectContext;

NS_ASSUME_NONNULL_BEGIN

/// Read-only access to ROI geometry archived in legacy OsiriX ROI SR objects.
@interface MetalLegacyROISRBridge : NSObject

/// Viewer convenience entry point; call on the main thread.
+ (NSArray<NSDictionary<NSString *, id> *> *)roiDictionariesForPixList:(NSArray *)pixList
    NS_SWIFT_NAME(roiDictionaries(forPixList:));

/// Background callers supply the context belonging to their source images.
+ (NSArray<NSDictionary<NSString *, id> *> *)roiDictionariesForPixList:(NSArray *)pixList
                                                            context:(NSManagedObjectContext *)context
    NS_SWIFT_NAME(roiDictionaries(forPixList:context:));

/// Main-thread lookup of file paths and exact source-slice indexes for legacy ROI readers.
+ (NSArray<NSDictionary<NSString *, id> *> *)sourceRecordsForPixList:(NSArray *)pixList;

@end

NS_ASSUME_NONNULL_END
