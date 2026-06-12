#import "Metal3DSurfaceExtractor.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdint.h>

@interface Metal3DSurfaceExtractionResult ()

@property (nonatomic, readwrite) NSData *surfaceVoxelMask;
@property (nonatomic, readwrite) NSString *extractionMethod;
@property (nonatomic, readwrite) NSData *vertexFloatData;
@property (nonatomic, readwrite) NSInteger triangleVertexCount;
@property (nonatomic, readwrite) NSInteger surfaceVoxelCount;
@property (nonatomic, readwrite) NSInteger pointCount;
@property (nonatomic, readwrite) NSInteger triangleCount;

- (instancetype)initWithExtractionMethod:(NSString *)extractionMethod
                         surfaceVoxelMask:(NSData *)surfaceVoxelMask
                         vertexFloatData:(NSData *)vertexFloatData
                     triangleVertexCount:(NSInteger)triangleVertexCount
                        surfaceVoxelCount:(NSInteger)surfaceVoxelCount
                               pointCount:(NSInteger)pointCount
                            triangleCount:(NSInteger)triangleCount;

@end

@implementation Metal3DSurfaceExtractionResult

- (instancetype)initWithExtractionMethod:(NSString *)extractionMethod
                         surfaceVoxelMask:(NSData *)surfaceVoxelMask
                         vertexFloatData:(NSData *)vertexFloatData
                     triangleVertexCount:(NSInteger)triangleVertexCount
                        surfaceVoxelCount:(NSInteger)surfaceVoxelCount
                               pointCount:(NSInteger)pointCount
                            triangleCount:(NSInteger)triangleCount
{
    self = [super init];
    if (self) {
        _extractionMethod = extractionMethod;
        _surfaceVoxelMask = surfaceVoxelMask;
        _vertexFloatData = vertexFloatData;
        _triangleVertexCount = triangleVertexCount;
        _surfaceVoxelCount = surfaceVoxelCount;
        _pointCount = pointCount;
        _triangleCount = triangleCount;
    }
    return self;
}

@end

static NSData *Metal3DVertexFloatDataByRemovingZCropCaps(NSData *vertexFloatData, float spacingZ)
{
    const NSUInteger floatStride = sizeof(float);
    const NSUInteger floatsPerVertex = 6;
    const NSUInteger floatsPerTriangle = floatsPerVertex * 3;
    if (vertexFloatData.length < floatsPerTriangle * floatStride ||
        vertexFloatData.length % (floatsPerTriangle * floatStride) != 0) {
        return vertexFloatData;
    }

    const float *source = (const float *)vertexFloatData.bytes;
    const NSUInteger triangleCount = vertexFloatData.length / (floatsPerTriangle * floatStride);
    NSMutableData *filteredData = [NSMutableData dataWithCapacity:vertexFloatData.length];
    float minimumZ = std::numeric_limits<float>::max();
    float maximumZ = -std::numeric_limits<float>::max();

    for (NSUInteger triangleIndex = 0; triangleIndex < triangleCount; triangleIndex++) {
        const float *triangle = source + triangleIndex * floatsPerTriangle;
        minimumZ = std::min(minimumZ, triangle[2]);
        minimumZ = std::min(minimumZ, triangle[8]);
        minimumZ = std::min(minimumZ, triangle[14]);
        maximumZ = std::max(maximumZ, triangle[2]);
        maximumZ = std::max(maximumZ, triangle[8]);
        maximumZ = std::max(maximumZ, triangle[14]);
    }

    if (!std::isfinite(minimumZ) || !std::isfinite(maximumZ) || maximumZ <= minimumZ) {
        return vertexFloatData;
    }

    const float capThickness = std::max(std::fabs(spacingZ) * 1.25f, 0.0001f);
    const float minimumCapZLimit = minimumZ + capThickness;
    const float maximumCapZLimit = maximumZ - capThickness;

    for (NSUInteger triangleIndex = 0; triangleIndex < triangleCount; triangleIndex++) {
        const float *triangle = source + triangleIndex * floatsPerTriangle;
        const bool allVerticesInMinimumZCap =
            triangle[2] <= minimumCapZLimit &&
            triangle[8] <= minimumCapZLimit &&
            triangle[14] <= minimumCapZLimit;
        const bool allVerticesInMaximumZCap =
            triangle[2] >= maximumCapZLimit &&
            triangle[8] >= maximumCapZLimit &&
            triangle[14] >= maximumCapZLimit;
        if (!allVerticesInMinimumZCap && !allVerticesInMaximumZCap) {
            [filteredData appendBytes:triangle length:floatsPerTriangle * floatStride];
        }
    }

    return filteredData;
}

@interface Metal3DSurfaceExtractor ()

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceWithMetalFromVolume:(NSData *)volumeData
                                                                             width:(NSInteger)width
                                                                            height:(NSInteger)height
                                                                             depth:(NSInteger)depth
                                                                          spacingX:(float)spacingX
                                                                          spacingY:(float)spacingY
                                                                          spacingZ:(float)spacingZ
                                                                         threshold:(float)threshold
                                                                   openMinimumZCap:(BOOL)openMinimumZCap;

@end

@implementation Metal3DSurfaceExtractor

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceFromVolume:(NSData *)volumeData
                                                                    width:(NSInteger)width
                                                                   height:(NSInteger)height
                                                                    depth:(NSInteger)depth
                                                                 spacingX:(float)spacingX
                                                                 spacingY:(float)spacingY
                                                                 spacingZ:(float)spacingZ
                                                                threshold:(float)threshold
{
    return [self extractSkinSurfaceFromVolume:volumeData
                                        width:width
                                       height:height
                                        depth:depth
                                     spacingX:spacingX
                                     spacingY:spacingY
                                     spacingZ:spacingZ
                                    threshold:threshold
                              openMinimumZCap:NO];
}

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceFromVolume:(NSData *)volumeData
                                                                    width:(NSInteger)width
                                                                   height:(NSInteger)height
                                                                    depth:(NSInteger)depth
                                                                 spacingX:(float)spacingX
                                                                 spacingY:(float)spacingY
                                                                 spacingZ:(float)spacingZ
                                                                threshold:(float)threshold
                                                          openMinimumZCap:(BOOL)openMinimumZCap
{
    return [self extractSkinSurfaceWithMetalFromVolume:volumeData
                                                 width:width
                                                height:height
                                                 depth:depth
                                              spacingX:spacingX
                                              spacingY:spacingY
                                              spacingZ:spacingZ
                                             threshold:threshold
                                       openMinimumZCap:openMinimumZCap];
}

+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceWithMetalFromVolume:(NSData *)volumeData
                                                                             width:(NSInteger)width
                                                                            height:(NSInteger)height
                                                                             depth:(NSInteger)depth
                                                                          spacingX:(float)spacingX
                                                                          spacingY:(float)spacingY
                                                                          spacingZ:(float)spacingZ
                                                                         threshold:(float)threshold
                                                                   openMinimumZCap:(BOOL)openMinimumZCap
{
    if (width <= 1 || height <= 1 || depth <= 1) {
        return nil;
    }

    const NSInteger voxelCount = width * height * depth;
    if ((NSInteger)volumeData.length < voxelCount * (NSInteger)sizeof(float) || voxelCount > UINT32_MAX) {
        return nil;
    }

    struct SurfaceUniforms {
        uint32_t width;
        uint32_t height;
        uint32_t depth;
        uint32_t voxelCount;
        uint32_t cellWidth;
        uint32_t cellHeight;
        uint32_t cellDepth;
        uint32_t cellCount;
        float spacingX;
        float spacingY;
        float spacingZ;
        float threshold;
    };

    const uint64_t maskCellWidth = (uint64_t)width - 1;
    const uint64_t maskCellHeight = (uint64_t)height - 1;
    const uint64_t maskCellDepth = (uint64_t)depth - 1;
    const uint64_t maskCellCount = maskCellWidth * maskCellHeight * maskCellDepth;
    if (maskCellCount > UINT32_MAX) {
        return nil;
    }

    SurfaceUniforms maskUniforms = {
        (uint32_t)width,
        (uint32_t)height,
        (uint32_t)depth,
        (uint32_t)voxelCount,
        (uint32_t)maskCellWidth,
        (uint32_t)maskCellHeight,
        (uint32_t)maskCellDepth,
        (uint32_t)maskCellCount,
        spacingX,
        spacingY,
        spacingZ,
        threshold
    };

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (device == nil || commandQueue == nil || library == nil) {
        return nil;
    }

    NSError *error = nil;
    id<MTLFunction> surfaceMaskCountFunction = [library newFunctionWithName:@"metal3DCountSurfaceFaces"];
    id<MTLFunction> marchingCubesCountFunction = [library newFunctionWithName:@"metal3DCountSurfaceMarchingCubes"];
    id<MTLFunction> marchingCubesEmitFunction = [library newFunctionWithName:@"metal3DEmitSurfaceMarchingCubes"];
    if (surfaceMaskCountFunction == nil || marchingCubesCountFunction == nil || marchingCubesEmitFunction == nil) {
        return nil;
    }

    id<MTLComputePipelineState> surfaceMaskCountPipeline = [device newComputePipelineStateWithFunction:surfaceMaskCountFunction error:&error];
    if (surfaceMaskCountPipeline == nil) {
        NSLog(@"Metal3DSurfaceExtractor Metal surface-mask pipeline unavailable: %@", error);
        return nil;
    }
    error = nil;
    id<MTLComputePipelineState> marchingCubesCountPipeline = [device newComputePipelineStateWithFunction:marchingCubesCountFunction error:&error];
    if (marchingCubesCountPipeline == nil) {
        NSLog(@"Metal3DSurfaceExtractor Metal marching-cubes count pipeline unavailable: %@", error);
        return nil;
    }
    error = nil;
    id<MTLComputePipelineState> marchingCubesEmitPipeline = [device newComputePipelineStateWithFunction:marchingCubesEmitFunction error:&error];
    if (marchingCubesEmitPipeline == nil) {
        NSLog(@"Metal3DSurfaceExtractor Metal marching-cubes emit pipeline unavailable: %@", error);
        return nil;
    }

    id<MTLBuffer> volumeBuffer = [device newBufferWithBytes:volumeData.bytes
                                                     length:(NSUInteger)voxelCount * sizeof(float)
                                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> faceCountBuffer = [device newBufferWithLength:(NSUInteger)voxelCount * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
    id<MTLBuffer> surfaceMaskBuffer = [device newBufferWithLength:(NSUInteger)voxelCount * sizeof(uint8_t)
                                                          options:MTLResourceStorageModeShared];
    if (volumeBuffer == nil || faceCountBuffer == nil || surfaceMaskBuffer == nil) {
        return nil;
    }
    std::memset(faceCountBuffer.contents, 0, (NSUInteger)voxelCount * sizeof(uint32_t));
    std::memset(surfaceMaskBuffer.contents, 0, (NSUInteger)voxelCount * sizeof(uint8_t));

    id<MTLCommandBuffer> countCommandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> countEncoder = [countCommandBuffer computeCommandEncoder];
    if (countCommandBuffer == nil || countEncoder == nil) {
        return nil;
    }

    [countEncoder setComputePipelineState:surfaceMaskCountPipeline];
    [countEncoder setBuffer:volumeBuffer offset:0 atIndex:0];
    [countEncoder setBuffer:faceCountBuffer offset:0 atIndex:1];
    [countEncoder setBuffer:surfaceMaskBuffer offset:0 atIndex:2];
    [countEncoder setBytes:&maskUniforms length:sizeof(maskUniforms) atIndex:3];
    const NSUInteger countThreadWidth = std::max<NSUInteger>(surfaceMaskCountPipeline.threadExecutionWidth, 1);
    const MTLSize countThreads = MTLSizeMake((NSUInteger)voxelCount, 1, 1);
    const MTLSize countThreadgroup = MTLSizeMake(std::min<NSUInteger>(countThreadWidth, 256), 1, 1);
    [countEncoder dispatchThreads:countThreads threadsPerThreadgroup:countThreadgroup];
    [countEncoder endEncoding];
    [countCommandBuffer commit];
    [countCommandBuffer waitUntilCompleted];
    if (countCommandBuffer.status == MTLCommandBufferStatusError) {
        NSLog(@"Metal3DSurfaceExtractor Metal count failed: %@", countCommandBuffer.error);
        return nil;
    }

    const uint32_t *faceCounts = (const uint32_t *)faceCountBuffer.contents;
    NSInteger surfaceVoxelCount = 0;
    for (NSInteger index = 0; index < voxelCount; index++) {
        if (faceCounts[index] != 0) {
            surfaceVoxelCount++;
        }
    }

    if (surfaceVoxelCount == 0) {
        return nil;
    }

    const NSInteger paddedWidth = width + 2;
    const NSInteger paddedHeight = height + 2;
    const NSInteger paddedDepth = depth + 2;
    const NSInteger paddedSliceCount = paddedWidth * paddedHeight;
    const NSInteger paddedVoxelCount = paddedSliceCount * paddedDepth;
    const uint64_t cubeCellWidth = (uint64_t)paddedWidth - 1;
    const uint64_t cubeCellHeight = (uint64_t)paddedHeight - 1;
    const uint64_t cubeCellDepth = (uint64_t)paddedDepth - 1;
    const uint64_t cubeCellCount = cubeCellWidth * cubeCellHeight * cubeCellDepth;
    if (paddedVoxelCount <= 0 || paddedVoxelCount > UINT32_MAX || cubeCellCount == 0 || cubeCellCount > UINT32_MAX) {
        return nil;
    }

    NSMutableData *paddedVolumeData = [NSMutableData dataWithLength:(NSUInteger)paddedVoxelCount * sizeof(float)];
    const float *sourceVoxels = (const float *)volumeData.bytes;
    float *paddedVoxels = (float *)paddedVolumeData.mutableBytes;
    const NSInteger sourceSliceCount = width * height;
    for (NSInteger z = 0; z < depth; z++) {
        const NSInteger sourceSliceOffset = z * sourceSliceCount;
        const NSInteger paddedSliceOffset = (z + 1) * paddedSliceCount;
        for (NSInteger y = 0; y < height; y++) {
            const float *sourceRow = sourceVoxels + sourceSliceOffset + y * width;
            float *paddedRow = paddedVoxels + paddedSliceOffset + (y + 1) * paddedWidth + 1;
            std::memcpy(paddedRow, sourceRow, (NSUInteger)width * sizeof(float));
        }
    }

    SurfaceUniforms marchingCubesUniforms = {
        (uint32_t)paddedWidth,
        (uint32_t)paddedHeight,
        (uint32_t)paddedDepth,
        (uint32_t)paddedVoxelCount,
        (uint32_t)cubeCellWidth,
        (uint32_t)cubeCellHeight,
        (uint32_t)cubeCellDepth,
        (uint32_t)cubeCellCount,
        spacingX,
        spacingY,
        spacingZ,
        threshold
    };

    id<MTLBuffer> paddedVolumeBuffer = [device newBufferWithBytes:paddedVolumeData.bytes
                                                           length:(NSUInteger)paddedVoxelCount * sizeof(float)
                                                          options:MTLResourceStorageModeShared];
    id<MTLBuffer> triangleCountBuffer = [device newBufferWithLength:(NSUInteger)cubeCellCount * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
    if (paddedVolumeBuffer == nil || triangleCountBuffer == nil) {
        return nil;
    }
    std::memset(triangleCountBuffer.contents, 0, (NSUInteger)cubeCellCount * sizeof(uint32_t));

    id<MTLCommandBuffer> marchingCubesCountCommandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> marchingCubesCountEncoder = [marchingCubesCountCommandBuffer computeCommandEncoder];
    if (marchingCubesCountCommandBuffer == nil || marchingCubesCountEncoder == nil) {
        return nil;
    }

    [marchingCubesCountEncoder setComputePipelineState:marchingCubesCountPipeline];
    [marchingCubesCountEncoder setBuffer:paddedVolumeBuffer offset:0 atIndex:0];
    [marchingCubesCountEncoder setBuffer:triangleCountBuffer offset:0 atIndex:1];
    [marchingCubesCountEncoder setBytes:&marchingCubesUniforms length:sizeof(marchingCubesUniforms) atIndex:2];
    const NSUInteger marchingCubesCountThreadWidth = std::max<NSUInteger>(marchingCubesCountPipeline.threadExecutionWidth, 1);
    const MTLSize marchingCubesCountThreads = MTLSizeMake((NSUInteger)cubeCellCount, 1, 1);
    const MTLSize marchingCubesCountThreadgroup = MTLSizeMake(std::min<NSUInteger>(marchingCubesCountThreadWidth, 256), 1, 1);
    [marchingCubesCountEncoder dispatchThreads:marchingCubesCountThreads threadsPerThreadgroup:marchingCubesCountThreadgroup];
    [marchingCubesCountEncoder endEncoding];
    [marchingCubesCountCommandBuffer commit];
    [marchingCubesCountCommandBuffer waitUntilCompleted];
    if (marchingCubesCountCommandBuffer.status == MTLCommandBufferStatusError) {
        NSLog(@"Metal3DSurfaceExtractor Metal marching-cubes count failed: %@", marchingCubesCountCommandBuffer.error);
        return nil;
    }

    const uint32_t *triangleCounts = (const uint32_t *)triangleCountBuffer.contents;
    NSMutableData *triangleOffsetData = [NSMutableData dataWithLength:(NSUInteger)cubeCellCount * sizeof(uint32_t)];
    uint32_t *triangleOffsets = (uint32_t *)triangleOffsetData.mutableBytes;
    uint64_t triangleCount64 = 0;
    for (uint64_t index = 0; index < cubeCellCount; index++) {
        triangleOffsets[index] = (uint32_t)triangleCount64;
        triangleCount64 += triangleCounts[index];
        if (triangleCount64 > UINT32_MAX) {
            return nil;
        }
    }

    if (triangleCount64 == 0) {
        return nil;
    }

    const uint64_t triangleVertexCount64 = triangleCount64 * 3;
    const uint64_t vertexFloatCount64 = triangleVertexCount64 * 6;
    const uint64_t vertexByteCount64 = vertexFloatCount64 * sizeof(float);
    if (vertexByteCount64 > NSUIntegerMax || triangleVertexCount64 > NSIntegerMax || triangleCount64 > NSIntegerMax) {
        return nil;
    }

    id<MTLBuffer> triangleOffsetBuffer = [device newBufferWithBytes:triangleOffsets
                                                             length:(NSUInteger)cubeCellCount * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertexBuffer = [device newBufferWithLength:(NSUInteger)vertexByteCount64
                                                     options:MTLResourceStorageModeShared];
    if (triangleOffsetBuffer == nil || vertexBuffer == nil) {
        return nil;
    }

    id<MTLCommandBuffer> emitCommandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> emitEncoder = [emitCommandBuffer computeCommandEncoder];
    if (emitCommandBuffer == nil || emitEncoder == nil) {
        return nil;
    }

    [emitEncoder setComputePipelineState:marchingCubesEmitPipeline];
    [emitEncoder setBuffer:paddedVolumeBuffer offset:0 atIndex:0];
    [emitEncoder setBuffer:triangleCountBuffer offset:0 atIndex:1];
    [emitEncoder setBuffer:triangleOffsetBuffer offset:0 atIndex:2];
    [emitEncoder setBuffer:vertexBuffer offset:0 atIndex:3];
    [emitEncoder setBytes:&marchingCubesUniforms length:sizeof(marchingCubesUniforms) atIndex:4];
    const NSUInteger emitThreadWidth = std::max<NSUInteger>(marchingCubesEmitPipeline.threadExecutionWidth, 1);
    const MTLSize emitThreads = MTLSizeMake((NSUInteger)cubeCellCount, 1, 1);
    const MTLSize emitThreadgroup = MTLSizeMake(std::min<NSUInteger>(emitThreadWidth, 256), 1, 1);
    [emitEncoder dispatchThreads:emitThreads threadsPerThreadgroup:emitThreadgroup];
    [emitEncoder endEncoding];
    [emitCommandBuffer commit];
    [emitCommandBuffer waitUntilCompleted];
    if (emitCommandBuffer.status == MTLCommandBufferStatusError) {
        NSLog(@"Metal3DSurfaceExtractor Metal emit failed: %@", emitCommandBuffer.error);
        return nil;
    }

    NSData *surfaceVoxelMask = [NSData dataWithBytes:surfaceMaskBuffer.contents length:(NSUInteger)voxelCount * sizeof(uint8_t)];
    NSData *vertexFloatData = [NSData dataWithBytes:vertexBuffer.contents length:(NSUInteger)vertexByteCount64];
    if (openMinimumZCap) {
        vertexFloatData = Metal3DVertexFloatDataByRemovingZCropCaps(vertexFloatData, spacingZ);
    }
    const NSInteger filteredTriangleVertexCount = (NSInteger)(vertexFloatData.length / (sizeof(float) * 6));
    const NSInteger filteredTriangleCount = filteredTriangleVertexCount / 3;
    return [[Metal3DSurfaceExtractionResult alloc]
        initWithExtractionMethod:@"metalComputeMarchingCubesOuter"
                 surfaceVoxelMask:surfaceVoxelMask
                 vertexFloatData:vertexFloatData
             triangleVertexCount:filteredTriangleVertexCount
                surfaceVoxelCount:surfaceVoxelCount
                       pointCount:filteredTriangleVertexCount
                    triangleCount:filteredTriangleCount];
}

@end
