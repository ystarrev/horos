#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Metal3DSurfaceExtractionResult : NSObject

@property (nonatomic, readonly) NSString *extractionMethod;
@property (nonatomic, readonly) NSData *surfaceVoxelMask;
@property (nonatomic, readonly) NSData *vertexFloatData;
@property (nonatomic, readonly) NSInteger triangleVertexCount;
@property (nonatomic, readonly) NSInteger surfaceVoxelCount;
@property (nonatomic, readonly) NSInteger pointCount;
@property (nonatomic, readonly) NSInteger triangleCount;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface Metal3DSurfaceExtractor : NSObject

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceFromVolume:(NSData *)volumeData
                                                                    width:(NSInteger)width
                                                                   height:(NSInteger)height
                                                                    depth:(NSInteger)depth
                                                                 spacingX:(float)spacingX
                                                                 spacingY:(float)spacingY
                                                                 spacingZ:(float)spacingZ
                                                                threshold:(float)threshold;

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceFromVolume:(NSData *)volumeData
                                                                    width:(NSInteger)width
                                                                   height:(NSInteger)height
                                                                    depth:(NSInteger)depth
                                                                 spacingX:(float)spacingX
                                                                 spacingY:(float)spacingY
                                                                 spacingZ:(float)spacingZ
                                                                threshold:(float)threshold
                                                          openMinimumZCap:(BOOL)openMinimumZCap;

@end

NS_ASSUME_NONNULL_END
