"""Non-build checks for Metal 4 surface extraction and visibility filtering."""

import platform
import shlex
import shutil
import subprocess
import unittest

from test_metal4_scout import declaration
from test_metal4_viewer import SOURCES
from test_macos_baseline import project_objects


SOURCE = (SOURCES / "Metal3DSurfaceExtractor.mm").read_text()
SHADERS = (SOURCES / "MetalShaders.metal").read_text()
CACHE = declaration("static BOOL Metal3DSurfaceExtractorGetComputeResources(", SOURCE)
FACTORY = declaration("static id<MTLComputePipelineState> Metal3DSurfaceComputePipeline(", SOURCE)
SESSION = SOURCE.split("@implementation Metal3DSurfaceComputeSession", 1)[1].split("@end", 1)[0]
INITIALIZE = declaration("- (instancetype)initWithDevice:", SESSION)
PERFORM = declaration("- (BOOL)performWithBuffers:", SESSION)
EXTRACTOR = SOURCE.split("@implementation Metal3DSurfaceExtractor", 1)[1]
EXTRACT = declaration("+ (nullable Metal3DSurfaceExtractionResult *)extractSkinSurfaceWithMetalFromVolume:", EXTRACTOR)
VISIBILITY = declaration("+ (nullable NSData *)filterSurfaceVertexFloatDataByRotatingVisibility:", EXTRACTOR)


def encoding(operation, source=EXTRACT):
    return declaration("encode:^", source.split(f'operation:@"{operation}"', 1)[1])


def surface_compile_entries():
    objects = project_objects("Horos.xcodeproj/project.pbxproj")
    entries = []
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget":
            continue
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_id in phase["files"]:
                build_file = objects[build_id]
                path = objects[build_file["fileRef"]].get("path", "")
                if path == "Horos/Sources/MetalViewer/Metal3DSurfaceExtractor.mm":
                    flags = shlex.split(build_file.get("settings", {}).get("COMPILER_FLAGS", ""))
                    entries.append((target["name"], flags))
    return entries


class Metal4SurfaceExtractionTests(unittest.TestCase):
    def assert_order(self, source, *steps):
        positions = [source.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_compiler_and_five_pipelines_keep_the_existing_once_cache(self):
        self.assertIn("dispatch_once(&onceToken", CACHE)
        self.assertEqual(CACHE.count("newMTL4CommandQueue"), 1)
        self.assertEqual(CACHE.count("newCompilerWithDescriptor:"), 1)
        self.assertEqual(CACHE.count("newDefaultLibrary"), 1)
        for name in ("metal3DCountSurfaceFaces", "metal3DCountSurfaceMarchingCubes",
                     "metal3DEmitSurfaceMarchingCubes", "metal3DSplatSurfaceVisibilityDepth",
                     "metal3DMarkSurfaceVisibility"):
            self.assertIn(f'Metal3DSurfaceComputePipeline(compiler, library, @"{name}", &error)', CACHE)
            self.assertIn(f"kernel void {name}", SHADERS)
        self.assert_order(FACTORY, "function.library = library", "function.name = functionName",
                          "descriptor.computeFunctionDescriptor = function",
                          "newComputePipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:error")
        self.assertNotRegex(SOURCE, r"newFunctionWithName:|newComputePipelineStateWithFunction:|\bMTLCommandQueue\b|\bMTLCommandBuffer\b|\bMTLComputeCommandEncoder\b|waitUntilCompleted")

    def test_required_and_optional_pipeline_failures_are_checked(self):
        for name in ("cachedSurfaceMaskCountPipeline", "cachedMarchingCubesCountPipeline", "cachedMarchingCubesEmitPipeline"):
            self.assertIn(f"if ({name} == nil)", CACHE)
        self.assertIn("visibilityDepthPipelineOut != nullptr && cachedVisibilityDepthPipeline == nil", CACHE)
        self.assertIn("visibilityMarkPipelineOut != nullptr && cachedVisibilityMarkPipeline == nil", CACHE)
        for source in (EXTRACT, VISIBILITY):
            self.assertIn("if (!Metal3DSurfaceExtractorGetComputeResources(", source)
            self.assertIn("if (session == nil)", source)

    def test_mutable_resources_are_per_extraction_and_reused_between_passes(self):
        for factory in ("newCommandBuffer", "newCommandAllocator", "newArgumentTableWithDescriptor:",
                        "newResidencySetWithDescriptor:", "dispatch_semaphore_create(0)"):
            self.assertEqual(INITIALIZE.count(factory), 1)
            self.assertNotIn(factory, PERFORM)
        self.assertNotIn("static", SESSION)
        self.assertNotIn("Metal3DSurfaceComputeSession", CACHE)
        self.assertEqual(EXTRACT.count("[[Metal3DSurfaceComputeSession alloc] initWithDevice:device queue:commandQueue]"), 1)
        self.assertEqual(EXTRACT.count("[session performWithBuffers:"), 3)
        self.assertEqual(VISIBILITY.count("[session performWithBuffers:"), 1)
        self.assertIn("if (_uniformBuffer.length < length)", PERFORM)
        self.assert_order(PERFORM, "std::memcpy(_uniformBuffer.contents, uniforms, length)",
                          "[_allocator reset]", "[_commandBuffer beginCommandBufferWithAllocator:_allocator]")

    def test_residency_and_strong_buffer_ownership_cover_gpu_execution(self):
        self.assertIn("NSArray<id<MTLBuffer>> *_buffers;", SOURCE)
        self.assert_order(PERFORM, "_buffers = buffers", "for (id<MTLBuffer> buffer in _buffers)",
                          "[_residency addAllocation:buffer]", "[_residency addAllocation:_uniformBuffer]",
                          "encode(encoder, _arguments, _uniformBuffer)", "[encoder endEncoding]",
                          "[_residency commit]", "[_commandBuffer useResidencySet:_residency]",
                          "[_queue commit:commandBuffers count:1 options:options]",
                          "dispatch_semaphore_wait(_completion, DISPATCH_TIME_FOREVER)",
                          "[_residency removeAllAllocations]", "_buffers = nil")
        cleanup = PERFORM.split("[_residency removeAllAllocations]", 1)[1]
        self.assert_order(cleanup, "[_residency commit]", "_buffers = nil", "_feedback = nil", "return succeeded")

    def test_completion_options_are_fresh_and_never_depend_on_the_waiting_queue(self):
        self.assertEqual(PERFORM.count("[[MTL4CommitOptions alloc] init]"), 1)
        self.assertNotIn("MTL4CommitOptions", INITIALIZE)
        callback = declaration("[options addFeedbackHandler:", PERFORM)
        self.assert_order(callback, "self->_feedback = feedback", "dispatch_semaphore_signal(self->_completion)")
        self.assertNotRegex(callback, r"dispatch_async|dispatch_sync|_residency|_allocator|\.error")
        self.assertNotIn("feedbackQueue", SOURCE)
        self.assert_order(PERFORM, "MTL4CommitOptions *options", "[options addFeedbackHandler:",
                          "[_queue commit:commandBuffers count:1 options:options]",
                          "dispatch_semaphore_wait(_completion, DISPATCH_TIME_FOREVER)",
                          "const BOOL succeeded = _feedback != nil && _feedback.error == nil")
        waiting = PERFORM.split("[_queue commit:", 1)[1].split("dispatch_semaphore_wait", 1)[0]
        self.assertNotRegex(waiting, r"return|reset|removeAll|cancel")
        self.assertEqual(PERFORM.count("dispatch_semaphore_wait"), 1)

    def test_encoder_failure_ends_recording_before_resources_are_registered(self):
        failure = declaration("if (encoder == nil)", PERFORM)
        self.assert_order(failure, "[_commandBuffer endCommandBuffer]", "return NO")
        self.assertNotRegex(failure, r"commit|semaphore_wait")
        self.assert_order(PERFORM, "if (encoder == nil)", "_buffers = buffers", "[_residency addAllocation:buffer]")
        self.assertIn("if (_uniformBuffer == nil)", PERFORM)

    def test_cpu_count_offset_and_output_reads_wait_for_successful_passes(self):
        self.assert_order(EXTRACT, 'operation:@"surface.maskCount"', "const uint32_t *faceCounts",
                          "if (surfaceVoxelCount == 0)", 'operation:@"surface.triangleCount"',
                          "const uint32_t *triangleCounts", "triangleOffsets[index] = (uint32_t)triangleCount64",
                          "triangleCount64 += triangleCounts[index]", "if (triangleCount64 > UINT32_MAX)",
                          'operation:@"surface.emit"', "NSData *surfaceVoxelMask", "NSData *vertexFloatData")
        self.assert_order(VISIBILITY, 'operation:@"surface.visibility"', "const uint32_t *visibleFlags")
        for source, expected in ((EXTRACT, 3), (VISIBILITY, 1)):
            self.assertEqual(source.count("if (![session performWithBuffers:"), expected)
            self.assertEqual(source.count("}]) {\n        return nil;\n    }"), expected)
        # Preserve the existing synchronous public contract, including callers on main.
        self.assertNotIn("isMainThread", SESSION)

    def test_padding_is_written_once_into_shared_gpu_storage_with_zero_border(self):
        self.assertNotIn("paddedVolumeData", EXTRACT)
        self.assertIn("paddedVolumeBuffer = [device newBufferWithLength:(NSUInteger)paddedVoxelCount * sizeof(float)\n"
                      "                                                          options:MTLResourceStorageModeShared]", EXTRACT)
        self.assert_order(EXTRACT, "if (paddedVolumeBuffer == nil)",
                          "std::memset(paddedVolumeBuffer.contents, 0, (NSUInteger)paddedVoxelCount * sizeof(float))",
                          "float *paddedVoxels = (float *)paddedVolumeBuffer.contents",
                          "for (NSInteger z = 0; z < depth; z++)",
                          'operation:@"surface.triangleCount"', 'operation:@"surface.emit"')
        self.assertIn("return nil;", declaration("if (paddedVolumeBuffer == nil)", EXTRACT))
        # The one-voxel border and row ordering are identical to the old CPU array.
        padding = declaration("for (NSInteger z = 0; z < depth; z++)", EXTRACT)
        for expression in (
            "const NSInteger sourceSliceOffset = z * sourceSliceCount;",
            "const NSInteger paddedSliceOffset = (z + 1) * paddedSliceCount;",
            "for (NSInteger y = 0; y < height; y++)",
            "const float *sourceRow = sourceVoxels + sourceSliceOffset + y * width;",
            "float *paddedRow = paddedVoxels + paddedSliceOffset + (y + 1) * paddedWidth + 1;",
            "std::memcpy(paddedRow, sourceRow, (NSUInteger)width * sizeof(float));",
        ):
            self.assertIn(expression, padding)

    def test_prefix_sum_writes_directly_to_checked_shared_offset_buffer(self):
        self.assertNotIn("triangleOffsetData", EXTRACT)
        self.assertNotIn("newBufferWithBytes:triangleOffsets", EXTRACT)
        self.assertIn("triangleOffsetBuffer = [device newBufferWithLength:(NSUInteger)cubeCellCount * sizeof(uint32_t)\n"
                      "                                                            options:MTLResourceStorageModeShared]", EXTRACT)
        self.assert_order(EXTRACT, 'operation:@"surface.triangleCount"',
                          "const uint32_t *triangleCounts = (const uint32_t *)triangleCountBuffer.contents",
                          "if (triangleOffsetBuffer == nil)",
                          "uint32_t *triangleOffsets = (uint32_t *)triangleOffsetBuffer.contents",
                          "for (uint64_t index = 0; index < cubeCellCount; index++)",
                          "triangleOffsets[index] = (uint32_t)triangleCount64",
                          "triangleCount64 += triangleCounts[index]", "if (triangleCount64 > UINT32_MAX)",
                          "if (triangleCount64 == 0)", "if (vertexByteCount64 > NSUIntegerMax",
                          "if (vertexBuffer == nil)", 'operation:@"surface.emit"')
        self.assertIn("return nil;", declaration("if (triangleOffsetBuffer == nil)", EXTRACT))
        self.assertIn("return nil;", declaration("if (vertexBuffer == nil)", EXTRACT))

    def test_extraction_argument_slots_match_shader_signatures(self):
        cases = (
            ("surface.maskCount", "surfaceMaskCountPipeline", "metal3DCountSurfaceFaces",
             ("volumeBuffer", "faceCountBuffer", "surfaceMaskBuffer", "uniformBuffer"),
             ("volume", "faceCounts", "surfaceMask", "uniforms")),
            ("surface.triangleCount", "marchingCubesCountPipeline", "metal3DCountSurfaceMarchingCubes",
             ("paddedVolumeBuffer", "triangleCountBuffer", "uniformBuffer"),
             ("volume", "triangleCounts", "uniforms")),
            ("surface.emit", "marchingCubesEmitPipeline", "metal3DEmitSurfaceMarchingCubes",
             ("paddedVolumeBuffer", "triangleCountBuffer", "triangleOffsetBuffer", "vertexBuffer", "uniformBuffer"),
             ("volume", "triangleCounts", "triangleOffsets", "vertices", "uniforms")),
        )
        for operation, pipeline, function, buffers, arguments in cases:
            with self.subTest(operation=operation):
                body = encoding(operation)
                kernel = declaration(f"kernel void {function}", SHADERS)
                self.assertIn(f"[encoder setComputePipelineState:{pipeline}]", body)
                for index, (buffer, argument) in enumerate(zip(buffers, arguments)):
                    self.assertIn(f"[arguments setAddress:{buffer}.gpuAddress atIndex:{index}]", body)
                    self.assertIn(f"{argument} [[buffer({index})]]", kernel)
                self.assertIn("performWithBuffers:@[" + ", ".join(buffers[:-1]) + "]", EXTRACT)
        self.assertIn("descriptor.maxBufferBindCount = 5", INITIALIZE)
        self.assertIn("descriptor.initializeBindings = YES", INITIALIZE)
        self.assert_order(PERFORM, "for (NSUInteger index = 0; index < 5; index++)",
                          "[_arguments setAddress:0 atIndex:index]", "[encoder setArgumentTable:_arguments]")
        self.assertNotRegex(SOURCE, r"\bsetBytes:|\bsetBuffer:")

    def test_visibility_uses_one_encoder_and_barrier_between_producer_and_consumer(self):
        body = encoding("surface.visibility", VISIBILITY)
        self.assertEqual(SESSION.count("computeCommandEncoder]"), 1)
        self.assertNotIn("computeCommandEncoder]", VISIBILITY)
        self.assert_order(body, "setComputePipelineState:visibilityDepthPipeline",
                          "dispatchThreads:depthThreads", "barrierAfterEncoderStages:MTLStageDispatch",
                          "beforeEncoderStages:MTLStageDispatch", "visibilityOptions:MTL4VisibilityOptionDevice",
                          "setComputePipelineState:visibilityMarkPipeline", "setAddress:visibleBuffer.gpuAddress atIndex:2",
                          "dispatchThreads:markThreads")
        self.assertEqual(body.count("barrierAfterEncoderStages:"), 1)
        self.assertIn("atomic_fetch_max_explicit", declaration("static inline void metal3DSplatVisibilitySample(", SHADERS))
        self.assertIn("atomic_store_explicit(&visibleFlags[sourceTriangleIndex], 1u, memory_order_relaxed)", SHADERS)

    def test_visibility_chunks_have_distinct_immutable_aligned_uniform_slots(self):
        self.assertIn("const NSUInteger trianglesPerDispatch = 262144", VISIBILITY)
        self.assertIn("const NSUInteger uniformStride = 256", VISIBILITY)
        self.assertIn("static_assert(sizeof(VisibilityUniforms) <= uniformStride", VISIBILITY)
        self.assert_order(VISIBILITY, "dataWithLength:chunkCount * uniformStride",
                          "chunkUniforms.triangleBase = (uint32_t)(chunk * trianglesPerDispatch)",
                          "chunkUniformData.mutableBytes + chunk * uniformStride", "[session performWithBuffers:")
        body = encoding("surface.visibility", VISIBILITY)
        self.assertEqual(body.count("const NSUInteger offset = (triangleBase / trianglesPerDispatch) * uniformStride"), 2)
        self.assertIn("setAddress:uniformBuffer.gpuAddress + offset atIndex:2", body)
        self.assertIn("setAddress:uniformBuffer.gpuAddress + offset atIndex:3", body)
        self.assertNotRegex(body, r"memcpy|contents|mutableBytes|triangleBase = \(uint32_t\)")
        stride, chunk_size = 256, 262144
        for count in (1, chunk_size, chunk_size + 1, 3 * chunk_size + 17, 2**32 - 1):
            bases = list(range(0, count, chunk_size))
            offsets = [(base // chunk_size) * stride for base in bases]
            self.assertEqual(offsets, list(range(0, len(bases) * stride, stride)))
            self.assertEqual(sum(min(chunk_size, count - base) for base in bases), count)

    def test_dimensions_spacing_counts_and_geometry_postprocessing_are_preserved(self):
        for field in ("width", "height", "depth", "voxelCount", "cellWidth", "cellHeight", "cellDepth", "cellCount",
                      "spacingX", "spacingY", "spacingZ", "threshold"):
            self.assertIn(field + ";", declaration("struct SurfaceUniforms", EXTRACT))
        for source in (EXTRACT, VISIBILITY):
            self.assertIn("sizeof(float)", source)
            self.assertIn("UINT32_MAX", source)
        self.assertIn("const uint32_t viewCount = 72", VISIBILITY)
        self.assertIn("std::max(maxSpacing * 4.0f, 6.0f)", VISIBILITY)
        self.assertIn("visibleTriangleCount < std::max<NSUInteger>(128, sourceTriangleCount / 20)", VISIBILITY)
        self.assertIn("Metal3DVertexFloatDataByRemovingZCropCaps(vertexFloatData, spacingZ)", EXTRACT)
        self.assertIn('initWithExtractionMethod:@"metalComputeMarchingCubesOuter"', EXTRACT)
        self.assertIn("triangleVertexCount64 * 6", EXTRACT)
        self.assertEqual(EXTRACT.count("MTLSizeMake((NSUInteger)cubeCellCount, 1, 1)"), 2)
        self.assertIn("MTLSizeMake((NSUInteger)voxelCount, 1, 1)", EXTRACT)

    def test_actual_horos_source_entry_explicitly_enables_arc(self):
        entries = surface_compile_entries()
        self.assertEqual([target for target, _ in entries], ["Horos"])
        flags = entries[0][1]
        self.assertIn("-fobjc-arc", flags)
        self.assertNotIn("-fno-objc-arc", flags)

    def sdk_syntax_check(self, flags):
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        return subprocess.run([
            "xcrun", "clang++", "-fsyntax-only", "-fblocks", "-std=c++17",
            "-target", "arm64-apple-macos27.0", "-isysroot", sdk, "-Wall", "-Wextra", "-Werror",
            *flags, str(SOURCES / "Metal3DSurfaceExtractor.mm"),
        ], capture_output=True, text=True, timeout=90)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_actual_complete_objcpp_file_passes_sdk_syntax_check_with_arc(self):
        # Use the actual source entry's override, not a test-only ARC assumption.
        entries = surface_compile_entries()
        self.assertEqual(len(entries), 1)
        result = self.sdk_syntax_check(["-fno-objc-arc", *entries[0][1]])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_source_guard_rejects_manual_memory_management(self):
        self.assertIn("#if !__has_feature(objc_arc)", SOURCE)
        result = self.sdk_syntax_check(["-fno-objc-arc"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Metal3DSurfaceExtractor requires ARC", result.stderr)


if __name__ == "__main__":
    unittest.main()
