#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalTumourSeedSRBridge : NSObject

+ (NSArray<NSDictionary<NSString *, id> *> *)seedDictionariesForPixList:(NSArray *)pixList
    NS_SWIFT_NAME(seedDictionaries(forPixList:));

+ (nullable NSString *)archiveSeedWithIdentifier:(NSString *)identifier
                                          pixelX:(double)pixelX
                                          pixelY:(double)pixelY
                                      sliceIndex:(NSInteger)sliceIndex
                                          dicomX:(double)dicomX
                                          dicomY:(double)dicomY
                                          dicomZ:(double)dicomZ
                                      diameterMM:(double)diameterMM
                                       createdAt:(NSDate *)createdAt
                                         pixList:(NSArray *)pixList
    NS_SWIFT_NAME(archiveSeed(identifier:pixelX:pixelY:sliceIndex:dicomX:dicomY:dicomZ:diameterMM:createdAt:pixList:));

@end

NS_ASSUME_NONNULL_END
