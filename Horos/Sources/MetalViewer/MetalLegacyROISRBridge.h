#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Read-only access to ROI geometry archived in legacy OsiriX ROI SR objects.
@interface MetalLegacyROISRBridge : NSObject

+ (NSArray<NSDictionary<NSString *, id> *> *)roiDictionariesForPixList:(NSArray *)pixList
    NS_SWIFT_NAME(roiDictionaries(forPixList:));

/// File paths and exact source-slice indexes, shared by legacy ROI readers.
+ (NSArray<NSDictionary<NSString *, id> *> *)sourceRecordsForPixList:(NSArray *)pixList;

@end

NS_ASSUME_NONNULL_END
