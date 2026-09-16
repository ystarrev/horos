#import "Metal3DSurfaceExtractor.h"

#if !__has_feature(objc_arc)
#error Metal3DSurfaceExtractor requires ARC (-fobjc-arc).
#endif

#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <dispatch/dispatch.h>
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

static id<MTLComputePipelineState> Metal3DSurfaceComputePipeline(id<MTL4Compiler> compiler,
                                                               id<MTLLibrary> library,
                                                               NSString *functionName,
                                                               NSError **error)
{
    MTL4LibraryFunctionDescriptor *function = [[MTL4LibraryFunctionDescriptor alloc] init];
    function.library = library;
    function.name = functionName;
    MTL4ComputePipelineDescriptor *descriptor = [[MTL4ComputePipelineDescriptor alloc] init];
    descriptor.computeFunctionDescriptor = function;
    return [compiler newComputePipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:error];
}

static BOOL Metal3DSurfaceExtractorGetComputeResources(id<MTLDevice> *deviceOut,
                                                       id<MTL4CommandQueue> *commandQueueOut,
                                                       id<MTLComputePipelineState> *surfaceMaskCountPipelineOut,
                                                       id<MTLComputePipelineState> *marchingCubesCountPipelineOut,
                                                       id<MTLComputePipelineState> *marchingCubesEmitPipelineOut,
                                                       id<MTLComputePipelineState> *visibilityDepthPipelineOut,
                                                       id<MTLComputePipelineState> *visibilityMarkPipelineOut)
{
    static id<MTLDevice> cachedDevice = nil;
    static id<MTL4CommandQueue> cachedCommandQueue = nil;
    static id<MTLComputePipelineState> cachedSurfaceMaskCountPipeline = nil;
    static id<MTLComputePipelineState> cachedMarchingCubesCountPipeline = nil;
    static id<MTLComputePipelineState> cachedMarchingCubesEmitPipeline = nil;
    static id<MTLComputePipelineState> cachedVisibilityDepthPipeline = nil;
    static id<MTLComputePipelineState> cachedVisibilityMarkPipeline = nil;
    static NSString *initializationFailure = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        cachedDevice = MTLCreateSystemDefaultDevice();
        cachedCommandQueue = [cachedDevice newMTL4CommandQueue];
        id<MTLLibrary> library = [cachedDevice newDefaultLibrary];
        if (cachedDevice == nil || cachedCommandQueue == nil || library == nil) {
            initializationFailure = @"Metal device, command queue, or default library unavailable";
            return;
        }

        NSError *error = nil;
        id<MTL4Compiler> compiler = [cachedDevice newCompilerWithDescriptor:[[MTL4CompilerDescriptor alloc] init]
                                                                    error:&error];
        if (compiler == nil) {
            initializationFailure = [[NSString alloc] initWithFormat:@"Metal 4 surface compiler unavailable: %@", error];
            return;
        }

        cachedSurfaceMaskCountPipeline = Metal3DSurfaceComputePipeline(compiler, library, @"metal3DCountSurfaceFaces", &error);
        if (cachedSurfaceMaskCountPipeline == nil) {
            initializationFailure = [[NSString alloc] initWithFormat:@"Metal surface-mask pipeline unavailable: %@", error];
            return;
        }

        error = nil;
        cachedMarchingCubesCountPipeline = Metal3DSurfaceComputePipeline(compiler, library, @"metal3DCountSurfaceMarchingCubes", &error);
        if (cachedMarchingCubesCountPipeline == nil) {
            initializationFailure = [[NSString alloc] initWithFormat:@"Metal marching-cubes count pipeline unavailable: %@", error];
            return;
        }

        error = nil;
        cachedMarchingCubesEmitPipeline = Metal3DSurfaceComputePipeline(compiler, library, @"metal3DEmitSurfaceMarchingCubes", &error);
        if (cachedMarchingCubesEmitPipeline == nil) {
            initializationFailure = [[NSString alloc] initWithFormat:@"Metal marching-cubes emit pipeline unavailable: %@", error];
            return;
        }

        if ([library.functionNames containsObject:@"metal3DSplatSurfaceVisibilityDepth"] &&
            [library.functionNames containsObject:@"metal3DMarkSurfaceVisibility"]) {
            error = nil;
            cachedVisibilityDepthPipeline = Metal3DSurfaceComputePipeline(compiler, library, @"metal3DSplatSurfaceVisibilityDepth", &error);
            if (cachedVisibilityDepthPipeline == nil) {
                NSLog(@"Metal3DSurfaceExtractor Metal visibility-depth pipeline unavailable: %@", error);
            }

            error = nil;
            cachedVisibilityMarkPipeline = Metal3DSurfaceComputePipeline(compiler, library, @"metal3DMarkSurfaceVisibility", &error);
            if (cachedVisibilityMarkPipeline == nil) {
                NSLog(@"Metal3DSurfaceExtractor Metal visibility-mark pipeline unavailable: %@", error);
            }
        } else {
            NSLog(@"Metal3DSurfaceExtractor Metal visibility filter functions unavailable");
        }
    });

    if (cachedDevice == nil ||
        cachedCommandQueue == nil ||
        cachedSurfaceMaskCountPipeline == nil ||
        cachedMarchingCubesCountPipeline == nil ||
        cachedMarchingCubesEmitPipeline == nil) {
        if (initializationFailure != nil) {
            NSLog(@"Metal3DSurfaceExtractor %@", initializationFailure);
        }
        return NO;
    }

    if ((visibilityDepthPipelineOut != nullptr && cachedVisibilityDepthPipeline == nil) ||
        (visibilityMarkPipelineOut != nullptr && cachedVisibilityMarkPipeline == nil)) {
        return NO;
    }

    if (deviceOut != nullptr) {
        *deviceOut = cachedDevice;
    }
    if (commandQueueOut != nullptr) {
        *commandQueueOut = cachedCommandQueue;
    }
    if (surfaceMaskCountPipelineOut != nullptr) {
        *surfaceMaskCountPipelineOut = cachedSurfaceMaskCountPipeline;
    }
    if (marchingCubesCountPipelineOut != nullptr) {
        *marchingCubesCountPipelineOut = cachedMarchingCubesCountPipeline;
    }
    if (marchingCubesEmitPipelineOut != nullptr) {
        *marchingCubesEmitPipelineOut = cachedMarchingCubesEmitPipeline;
    }
    if (visibilityDepthPipelineOut != nullptr) {
        *visibilityDepthPipelineOut = cachedVisibilityDepthPipeline;
    }
    if (visibilityMarkPipelineOut != nullptr) {
        *visibilityMarkPipelineOut = cachedVisibilityMarkPipeline;
    }
    return YES;
}

// One synchronous extraction owns this state. Completed passes can reuse it,
// while simultaneous extractions share only the immutable pipelines and queue.
@interface Metal3DSurfaceComputeSession : NSObject {
    id<MTLDevice> _device;
    id<MTL4CommandQueue> _queue;
    id<MTL4CommandBuffer> _commandBuffer;
    id<MTL4CommandAllocator> _allocator;
    id<MTL4ArgumentTable> _arguments;
    id<MTLResidencySet> _residency;
    id<MTLBuffer> _uniformBuffer;
    NSArray<id<MTLBuffer>> *_buffers;
    dispatch_semaphore_t _completion;
    id<MTL4CommitFeedback> _feedback;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device queue:(id<MTL4CommandQueue>)queue;
- (BOOL)performWithBuffers:(NSArray<id<MTLBuffer>> *)buffers
                  uniforms:(const void *)uniforms
                    length:(NSUInteger)length
                 operation:(NSString *)operation
                    encode:(void (^)(id<MTL4ComputeCommandEncoder>, id<MTL4ArgumentTable>, id<MTLBuffer>))encode;

@end

@implementation Metal3DSurfaceComputeSession

- (instancetype)initWithDevice:(id<MTLDevice>)device queue:(id<MTL4CommandQueue>)queue
{
    self = [super init];
    if (self) {
        _device = device;
        _queue = queue;
        _commandBuffer = [device newCommandBuffer];
        _allocator = [device newCommandAllocator];
        MTL4ArgumentTableDescriptor *descriptor = [[MTL4ArgumentTableDescriptor alloc] init];
        descriptor.maxBufferBindCount = 5;
        descriptor.initializeBindings = YES;
        _arguments = [device newArgumentTableWithDescriptor:descriptor error:nil];
        _residency = [device newResidencySetWithDescriptor:[[MTLResidencySetDescriptor alloc] init] error:nil];
        _completion = dispatch_semaphore_create(0);
        if (_commandBuffer == nil || _allocator == nil || _arguments == nil || _residency == nil) {
            return nil;
        }
    }
    return self;
}

- (BOOL)performWithBuffers:(NSArray<id<MTLBuffer>> *)buffers
                  uniforms:(const void *)uniforms
                    length:(NSUInteger)length
                 operation:(NSString *)operation
                    encode:(void (^)(id<MTL4ComputeCommandEncoder>, id<MTL4ArgumentTable>, id<MTLBuffer>))encode
{
    if (_uniformBuffer.length < length) {
        _uniformBuffer = [_device newBufferWithLength:std::max<NSUInteger>(length, 256)
                                             options:MTLResourceStorageModeShared];
    }
    if (_uniformBuffer == nil) {
        return NO;
    }
    std::memcpy(_uniformBuffer.contents, uniforms, length);
    [_allocator reset];
    _feedback = nil;
    for (NSUInteger index = 0; index < 5; index++) {
        [_arguments setAddress:0 atIndex:index];
    }
    [_commandBuffer beginCommandBufferWithAllocator:_allocator];
    id<MTL4ComputeCommandEncoder> encoder = [_commandBuffer computeCommandEncoder];
    if (encoder == nil) {
        [_commandBuffer endCommandBuffer];
        return NO;
    }
    _buffers = buffers;
    for (id<MTLBuffer> buffer in _buffers) {
        [_residency addAllocation:buffer];
    }
    [_residency addAllocation:_uniformBuffer];
    encoder.label = operation;
    [encoder setArgumentTable:_arguments];
    encode(encoder, _arguments, _uniformBuffer);
    [encoder endEncoding];
    [_residency commit];
    [_commandBuffer useResidencySet:_residency];
    [_commandBuffer endCommandBuffer];

    // Feedback handlers are consumed at commit. Never reuse their options.
    MTL4CommitOptions *options = [[MTL4CommitOptions alloc] init];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        self->_feedback = feedback;
        dispatch_semaphore_signal(self->_completion);
    }];
    id<MTL4CommandBuffer> commandBuffers[] = {_commandBuffer};
    [_queue commit:commandBuffers count:1 options:options];
    // Keep buffers resident and alive until the GPU finishes, including failures.
    dispatch_semaphore_wait(_completion, DISPATCH_TIME_FOREVER);
    const BOOL succeeded = _feedback != nil && _feedback.error == nil;
    if (!succeeded) {
        NSLog(@"Metal3DSurfaceExtractor %@ failed: %@", operation, _feedback.error);
    }
    [_residency removeAllAllocations];
    [_residency commit];
    _buffers = nil;
    _feedback = nil;
    return succeeded;
}

@end

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

+ (nullable NSData *)filterSurfaceVertexFloatDataByRotatingVisibility:(NSData *)vertexFloatData
                                                              spacingX:(float)spacingX
                                                              spacingY:(float)spacingY
                                                              spacingZ:(float)spacingZ
                                                           vertexCount:(NSInteger * _Nullable)vertexCount
                                                         triangleCount:(NSInteger * _Nullable)triangleCount
{
    const NSUInteger floatsPerVertex = 6;
    const NSUInteger floatsPerTriangle = floatsPerVertex * 3;
    const NSUInteger bytesPerTriangle = floatsPerTriangle * sizeof(float);
    if (vertexCount != nullptr) {
        *vertexCount = (NSInteger)(vertexFloatData.length / (floatsPerVertex * sizeof(float)));
    }
    if (triangleCount != nullptr) {
        *triangleCount = (NSInteger)(vertexFloatData.length / bytesPerTriangle);
    }
    if (vertexFloatData.length < bytesPerTriangle ||
        vertexFloatData.length % bytesPerTriangle != 0) {
        return vertexFloatData;
    }

    const NSUInteger sourceTriangleCount = vertexFloatData.length / bytesPerTriangle;
    if (sourceTriangleCount == 0 || sourceTriangleCount > UINT32_MAX) {
        return vertexFloatData;
    }

    const float *floats = (const float *)vertexFloatData.bytes;
    float minimumX = std::numeric_limits<float>::max();
    float minimumY = std::numeric_limits<float>::max();
    float minimumZ = std::numeric_limits<float>::max();
    float maximumX = -std::numeric_limits<float>::max();
    float maximumY = -std::numeric_limits<float>::max();
    float maximumZ = -std::numeric_limits<float>::max();
    const NSUInteger sourceVertexCount = sourceTriangleCount * 3;
    for (NSUInteger vertexIndex = 0; vertexIndex < sourceVertexCount; vertexIndex++) {
        const NSUInteger base = vertexIndex * floatsPerVertex;
        const float x = floats[base + 0];
        const float y = floats[base + 1];
        const float z = floats[base + 2];
        if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
            continue;
        }
        minimumX = std::min(minimumX, x);
        minimumY = std::min(minimumY, y);
        minimumZ = std::min(minimumZ, z);
        maximumX = std::max(maximumX, x);
        maximumY = std::max(maximumY, y);
        maximumZ = std::max(maximumZ, z);
    }

    if (!std::isfinite(minimumX) || !std::isfinite(minimumY) || !std::isfinite(minimumZ) ||
        maximumX <= minimumX || maximumY <= minimumY || maximumZ <= minimumZ) {
        return vertexFloatData;
    }

    const float xyCenterX = (minimumX + maximumX) * 0.5f;
    const float xyCenterY = (minimumY + maximumY) * 0.5f;
    float xyRadius = 1.0f;
    for (NSUInteger vertexIndex = 0; vertexIndex < sourceVertexCount; vertexIndex++) {
        const NSUInteger base = vertexIndex * floatsPerVertex;
        xyRadius = std::max(xyRadius, hypotf(floats[base + 0] - xyCenterX, floats[base + 1] - xyCenterY));
    }
    xyRadius = std::max(xyRadius + 4.0f, 1.0f);

    minimumZ -= 4.0f;
    maximumZ += 4.0f;
    const float zRange = std::max(maximumZ - minimumZ, 1.0f);
    const float minSpacing = std::min(std::min(fabsf(spacingX), fabsf(spacingY)), fabsf(spacingZ));
    const float maxSpacing = std::max(std::max(fabsf(spacingX), fabsf(spacingY)), fabsf(spacingZ));
    const float visibilityPixelSize = std::max(minSpacing * 1.5f, 0.75f);
    const uint32_t gridWidth = (uint32_t)std::min(std::max((int)ceilf((xyRadius * 2.0f) / visibilityPixelSize), 192), 384);
    const uint32_t gridHeight = (uint32_t)std::min(std::max((int)ceilf(zRange / visibilityPixelSize), 192), 384);
    const uint32_t viewCount = 72;
    const uint32_t gridVoxelCount = gridWidth * gridHeight;
    const uint64_t totalDepthCount64 = (uint64_t)gridVoxelCount * (uint64_t)viewCount;
    if (totalDepthCount64 == 0 || totalDepthCount64 > UINT32_MAX) {
        return vertexFloatData;
    }

    struct VisibilityUniforms {
        uint32_t triangleCount;
        uint32_t triangleBase;
        uint32_t viewCount;
        uint32_t gridWidth;
        uint32_t gridHeight;
        uint32_t gridVoxelCount;
        float xyCenterX;
        float xyCenterY;
        float xyRadius;
        float minimumZ;
        float zRange;
        float depthTolerance;
    };
    VisibilityUniforms uniforms = {
        (uint32_t)sourceTriangleCount,
        0,
        viewCount,
        gridWidth,
        gridHeight,
        gridVoxelCount,
        xyCenterX,
        xyCenterY,
        xyRadius,
        minimumZ,
        zRange,
        std::max(maxSpacing * 4.0f, 6.0f)
    };

    id<MTLDevice> device = nil;
    id<MTL4CommandQueue> commandQueue = nil;
    id<MTLComputePipelineState> visibilityDepthPipeline = nil;
    id<MTLComputePipelineState> visibilityMarkPipeline = nil;
    if (!Metal3DSurfaceExtractorGetComputeResources(&device,
                                                    &commandQueue,
                                                    nullptr,
                                                    nullptr,
                                                    nullptr,
                                                    &visibilityDepthPipeline,
                                                    &visibilityMarkPipeline)) {
        return nil;
    }

    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertexFloatData.bytes
                                                     length:vertexFloatData.length
                                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> depthBuffer = [device newBufferWithLength:(NSUInteger)totalDepthCount64 * sizeof(uint32_t)
                                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> visibleBuffer = [device newBufferWithLength:sourceTriangleCount * sizeof(uint32_t)
                                                      options:MTLResourceStorageModeShared];
    if (vertexBuffer == nil || depthBuffer == nil || visibleBuffer == nil) {
        return nil;
    }
    std::memset(depthBuffer.contents, 0, (NSUInteger)totalDepthCount64 * sizeof(uint32_t));
    std::memset(visibleBuffer.contents, 0, sourceTriangleCount * sizeof(uint32_t));

    Metal3DSurfaceComputeSession *session = [[Metal3DSurfaceComputeSession alloc] initWithDevice:device queue:commandQueue];
    if (session == nil) {
        return nil;
    }

    const NSUInteger trianglesPerDispatch = 262144;
    const NSUInteger uniformStride = 256;
    static_assert(sizeof(VisibilityUniforms) <= uniformStride, "Visibility uniforms exceed their aligned slot");
    const NSUInteger chunkCount = (sourceTriangleCount + trianglesPerDispatch - 1) / trianglesPerDispatch;
    NSMutableData *chunkUniformData = [NSMutableData dataWithLength:chunkCount * uniformStride];
    // Every dispatch reads its own immutable parameters after encoding ends.
    // Depth and marking reuse the same slot for the same triangle chunk.
    for (NSUInteger chunk = 0; chunk < chunkCount; chunk++) {
        VisibilityUniforms chunkUniforms = uniforms;
        chunkUniforms.triangleBase = (uint32_t)(chunk * trianglesPerDispatch);
        std::memcpy((uint8_t *)chunkUniformData.mutableBytes + chunk * uniformStride,
                    &chunkUniforms, sizeof(chunkUniforms));
    }
    const NSUInteger depthThreadWidth = std::max<NSUInteger>(visibilityDepthPipeline.threadExecutionWidth, 1);
    const MTLSize depthThreadgroup = MTLSizeMake(std::min<NSUInteger>(depthThreadWidth, 256), 1, 1);
    const NSUInteger markThreadWidth = std::max<NSUInteger>(visibilityMarkPipeline.threadExecutionWidth, 1);
    const MTLSize markThreadgroup = MTLSizeMake(std::min<NSUInteger>(markThreadWidth, 256), 1, 1);
    if (![session performWithBuffers:@[vertexBuffer, depthBuffer, visibleBuffer]
                            uniforms:chunkUniformData.bytes
                              length:chunkUniformData.length
                           operation:@"surface.visibility"
                              encode:^(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> arguments, id<MTLBuffer> uniformBuffer) {
        [arguments setAddress:vertexBuffer.gpuAddress atIndex:0];
        [arguments setAddress:depthBuffer.gpuAddress atIndex:1];
        [encoder setComputePipelineState:visibilityDepthPipeline];
        for (NSUInteger triangleBase = 0; triangleBase < sourceTriangleCount; triangleBase += trianglesPerDispatch) {
            const NSUInteger chunkTriangleCount = std::min<NSUInteger>(trianglesPerDispatch, sourceTriangleCount - triangleBase);
            const NSUInteger offset = (triangleBase / trianglesPerDispatch) * uniformStride;
            [arguments setAddress:uniformBuffer.gpuAddress + offset atIndex:2];
            const MTLSize depthThreads = MTLSizeMake(chunkTriangleCount, viewCount, 1);
            [encoder dispatchThreads:depthThreads threadsPerThreadgroup:depthThreadgroup];
        }

        // Depth chunks atomically accumulate into a shared map. Marking must
        // see the completed map from all chunks; mark chunks write disjoint flags.
        [encoder barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch
                         visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder setComputePipelineState:visibilityMarkPipeline];
        [arguments setAddress:visibleBuffer.gpuAddress atIndex:2];
        for (NSUInteger triangleBase = 0; triangleBase < sourceTriangleCount; triangleBase += trianglesPerDispatch) {
            const NSUInteger chunkTriangleCount = std::min<NSUInteger>(trianglesPerDispatch, sourceTriangleCount - triangleBase);
            const NSUInteger offset = (triangleBase / trianglesPerDispatch) * uniformStride;
            [arguments setAddress:uniformBuffer.gpuAddress + offset atIndex:3];
            const MTLSize markThreads = MTLSizeMake(chunkTriangleCount, viewCount, 1);
            [encoder dispatchThreads:markThreads threadsPerThreadgroup:markThreadgroup];
        }
    }]) {
        return nil;
    }

    const uint32_t *visibleFlags = (const uint32_t *)visibleBuffer.contents;
    NSUInteger visibleTriangleCount = 0;
    for (NSUInteger triangleIndex = 0; triangleIndex < sourceTriangleCount; triangleIndex++) {
        visibleTriangleCount += visibleFlags[triangleIndex] != 0 ? 1 : 0;
    }
    if (visibleTriangleCount < std::max<NSUInteger>(128, sourceTriangleCount / 20)) {
        return vertexFloatData;
    }

    NSMutableData *filteredData = [NSMutableData dataWithLength:visibleTriangleCount * bytesPerTriangle];
    uint8_t *destination = (uint8_t *)filteredData.mutableBytes;
    const uint8_t *source = (const uint8_t *)vertexFloatData.bytes;
    NSUInteger outputTriangleIndex = 0;
    for (NSUInteger triangleIndex = 0; triangleIndex < sourceTriangleCount; triangleIndex++) {
        if (visibleFlags[triangleIndex] == 0) {
            continue;
        }
        std::memcpy(destination + outputTriangleIndex * bytesPerTriangle,
                    source + triangleIndex * bytesPerTriangle,
                    bytesPerTriangle);
        outputTriangleIndex++;
    }

    if (vertexCount != nullptr) {
        *vertexCount = (NSInteger)(visibleTriangleCount * 3);
    }
    if (triangleCount != nullptr) {
        *triangleCount = (NSInteger)visibleTriangleCount;
    }
    return filteredData;
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

    id<MTLDevice> device = nil;
    id<MTL4CommandQueue> commandQueue = nil;
    id<MTLComputePipelineState> surfaceMaskCountPipeline = nil;
    id<MTLComputePipelineState> marchingCubesCountPipeline = nil;
    id<MTLComputePipelineState> marchingCubesEmitPipeline = nil;
    if (!Metal3DSurfaceExtractorGetComputeResources(&device,
                                                    &commandQueue,
                                                    &surfaceMaskCountPipeline,
                                                    &marchingCubesCountPipeline,
                                                    &marchingCubesEmitPipeline,
                                                    nullptr,
                                                    nullptr)) {
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

    Metal3DSurfaceComputeSession *session = [[Metal3DSurfaceComputeSession alloc] initWithDevice:device queue:commandQueue];
    if (session == nil) {
        return nil;
    }

    const NSUInteger countThreadWidth = std::max<NSUInteger>(surfaceMaskCountPipeline.threadExecutionWidth, 1);
    const MTLSize countThreads = MTLSizeMake((NSUInteger)voxelCount, 1, 1);
    const MTLSize countThreadgroup = MTLSizeMake(std::min<NSUInteger>(countThreadWidth, 256), 1, 1);
    if (![session performWithBuffers:@[volumeBuffer, faceCountBuffer, surfaceMaskBuffer]
                            uniforms:&maskUniforms
                              length:sizeof(maskUniforms)
                           operation:@"surface.maskCount"
                              encode:^(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> arguments, id<MTLBuffer> uniformBuffer) {
        [encoder setComputePipelineState:surfaceMaskCountPipeline];
        [arguments setAddress:volumeBuffer.gpuAddress atIndex:0];
        [arguments setAddress:faceCountBuffer.gpuAddress atIndex:1];
        [arguments setAddress:surfaceMaskBuffer.gpuAddress atIndex:2];
        [arguments setAddress:uniformBuffer.gpuAddress atIndex:3];
        [encoder dispatchThreads:countThreads threadsPerThreadgroup:countThreadgroup];
    }]) {
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

    // Fill shared GPU storage directly, avoiding a second full padded volume.
    id<MTLBuffer> paddedVolumeBuffer = [device newBufferWithLength:(NSUInteger)paddedVoxelCount * sizeof(float)
                                                          options:MTLResourceStorageModeShared];
    if (paddedVolumeBuffer == nil) {
        return nil;
    }
    std::memset(paddedVolumeBuffer.contents, 0, (NSUInteger)paddedVoxelCount * sizeof(float));
    const float *sourceVoxels = (const float *)volumeData.bytes;
    float *paddedVoxels = (float *)paddedVolumeBuffer.contents;
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

    id<MTLBuffer> triangleCountBuffer = [device newBufferWithLength:(NSUInteger)cubeCellCount * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
    if (triangleCountBuffer == nil) {
        return nil;
    }
    std::memset(triangleCountBuffer.contents, 0, (NSUInteger)cubeCellCount * sizeof(uint32_t));

    const NSUInteger marchingCubesCountThreadWidth = std::max<NSUInteger>(marchingCubesCountPipeline.threadExecutionWidth, 1);
    const MTLSize marchingCubesCountThreads = MTLSizeMake((NSUInteger)cubeCellCount, 1, 1);
    const MTLSize marchingCubesCountThreadgroup = MTLSizeMake(std::min<NSUInteger>(marchingCubesCountThreadWidth, 256), 1, 1);
    if (![session performWithBuffers:@[paddedVolumeBuffer, triangleCountBuffer]
                            uniforms:&marchingCubesUniforms
                              length:sizeof(marchingCubesUniforms)
                           operation:@"surface.triangleCount"
                              encode:^(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> arguments, id<MTLBuffer> uniformBuffer) {
        [encoder setComputePipelineState:marchingCubesCountPipeline];
        [arguments setAddress:paddedVolumeBuffer.gpuAddress atIndex:0];
        [arguments setAddress:triangleCountBuffer.gpuAddress atIndex:1];
        [arguments setAddress:uniformBuffer.gpuAddress atIndex:2];
        [encoder dispatchThreads:marchingCubesCountThreads threadsPerThreadgroup:marchingCubesCountThreadgroup];
    }]) {
        return nil;
    }

    const uint32_t *triangleCounts = (const uint32_t *)triangleCountBuffer.contents;
    id<MTLBuffer> triangleOffsetBuffer = [device newBufferWithLength:(NSUInteger)cubeCellCount * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
    if (triangleOffsetBuffer == nil) {
        return nil;
    }
    uint32_t *triangleOffsets = (uint32_t *)triangleOffsetBuffer.contents;
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

    id<MTLBuffer> vertexBuffer = [device newBufferWithLength:(NSUInteger)vertexByteCount64
                                                     options:MTLResourceStorageModeShared];
    if (vertexBuffer == nil) {
        return nil;
    }

    const NSUInteger emitThreadWidth = std::max<NSUInteger>(marchingCubesEmitPipeline.threadExecutionWidth, 1);
    const MTLSize emitThreads = MTLSizeMake((NSUInteger)cubeCellCount, 1, 1);
    const MTLSize emitThreadgroup = MTLSizeMake(std::min<NSUInteger>(emitThreadWidth, 256), 1, 1);
    if (![session performWithBuffers:@[paddedVolumeBuffer, triangleCountBuffer, triangleOffsetBuffer, vertexBuffer]
                            uniforms:&marchingCubesUniforms
                              length:sizeof(marchingCubesUniforms)
                           operation:@"surface.emit"
                              encode:^(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> arguments, id<MTLBuffer> uniformBuffer) {
        [encoder setComputePipelineState:marchingCubesEmitPipeline];
        [arguments setAddress:paddedVolumeBuffer.gpuAddress atIndex:0];
        [arguments setAddress:triangleCountBuffer.gpuAddress atIndex:1];
        [arguments setAddress:triangleOffsetBuffer.gpuAddress atIndex:2];
        [arguments setAddress:vertexBuffer.gpuAddress atIndex:3];
        [arguments setAddress:uniformBuffer.gpuAddress atIndex:4];
        [encoder dispatchThreads:emitThreads threadsPerThreadgroup:emitThreadgroup];
    }]) {
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
