#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalStudyROISegBridge : NSObject

+ (NSDictionary<NSString *, NSString *> *)writeSegmentationWithLabel:(NSString *)label
                                                          trackingUID:(NSString *)trackingUID
                                                        authoringJSON:(NSString *)authoringJSON
                                                              colorRed:(double)colorRed
                                                            colorGreen:(double)colorGreen
                                                             colorBlue:(double)colorBlue
                                                     sourceImagePaths:(NSArray<NSString *> *)sourceImagePaths
                                                           frameMasks:(NSArray<NSData *> *)frameMasks
                                                                 rows:(NSUInteger)rows
                                                              columns:(NSUInteger)columns
                                                              pixList:(NSArray *)pixList
                                                         existingPath:(nullable NSString *)existingPath
    NS_SWIFT_NAME(writeSegmentation(label:trackingUID:authoringJSON:colorRed:colorGreen:colorBlue:sourceImagePaths:frameMasks:rows:columns:pixList:existingPath:));

+ (nullable NSString *)deleteSegmentationAtPath:(NSString *)path
                                         pixList:(NSArray *)pixList
    NS_SWIFT_NAME(deleteSegmentation(atPath:pixList:));

@end

NS_ASSUME_NONNULL_END
