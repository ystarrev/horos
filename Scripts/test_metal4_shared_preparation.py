"""Non-build checks for shared viewing/registration volume preparation."""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_scout import declaration


SOURCES = Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer"
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
CACHE = declaration("final class MetalPreparedVolumeCache", MODELS)
RESOURCES = declaration("private final class PreparationResources", CACHE)
PREPARE = declaration("private func encodeEntry(", CACHE)
FINISH = declaration("private func finish(", CACHE)
REQUEST = declaration("func requestEntry(", CACHE)
DISPATCH = declaration("func encode<T>(", RESOURCES)
FEEDBACK = declaration("options.addFeedbackHandler", PREPARE)


class Metal4SharedPreparationTests(unittest.TestCase):
    def assert_order(self, source, *steps):
        positions = [source.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_reusable_submission_uses_one_encoder_and_no_cpu_wait(self):
        self.assertIn("let commandQueue: MTL4CommandQueue", CACHE)
        self.assertIn("let commandBuffer: MTL4CommandBuffer", CACHE)
        self.assertEqual(CACHE.count("device.makeCommandBuffer()"), 1)
        self.assertEqual(CACHE.count("makeComputeCommandEncoder()"), 1)
        self.assertNotRegex(CACHE, r"\bMTLCommandBuffer\b|\bMTLComputeCommandEncoder\b|\bMTLCommandQueue\b")
        self.assertNotRegex(CACHE, r"waitUntil|DispatchSemaphore|\.wait\(|OperationQueue|Thread.sleep")
        self.assertNotRegex(CACHE, r"encoder\.set(?:Bytes|Buffer|Texture)\(")
        self.assertIn("encoder.setArgumentTable(resources.arguments)", PREPARE)
        self.assertIn("MTLSize(width: 4, height: 4, depth: 4)", CACHE)
        self.assertIn("dispatchThreadgroups(threadgroupsPerGrid: groups, threadsPerThreadgroup: threads)", CACHE)

    def test_single_inflight_job_includes_gpu_time_and_failure_cleanup(self):
        pump = declaration("private func startNextPreparationIfNeeded()", CACHE)
        self.assert_order(pump, "dispatchPrecondition", "guard isPreparing == false",
                          "isPreparing = true", "pendingPreparations.removeFirst()", "preparation()")
        self.assertIn("pendingPreparations.isEmpty == false", pump)
        self.assertNotIn("isPreparing = false", PREPARE)
        self.assertIn("dispatchPrecondition(condition: .onQueue(preparationQueue))", PREPARE)
        self.assertIn("dispatchPrecondition(condition: .onQueue(preparationQueue))", FINISH)
        self.assert_order(FINISH, "lock.unlock()", "DispatchQueue.main.async", "isPreparing = false",
                          "preparationQueue.async { [self] in startNextPreparationIfNeeded() }")
        self.assertEqual(FINISH.count("startNextPreparationIfNeeded()"), 1)
        self.assertIn("preparationQueue.async { [self, pipelines] in", FEEDBACK)

    def test_hit_coalescing_and_late_primary_reuse_are_preserved(self):
        self.assert_order(REQUEST, "if let entry = entries[key]", "inFlightCompletions[requestKey]?.append(completion)",
                          "inFlightCompletions[requestKey] = [completion]", "preparationQueue.async",
                          "pendingPreparations.append", "encodeEntry(", "existingPreparedEntry(forKey: key)")
        self.assertIn("includeRegistrationPyramid == false || entry.hasRegistrationPyramid", REQUEST)
        self.assertIn(r'let requestKey = "\(key)|pyramid=\(includeRegistrationPyramid ? 1 : 0)"', REQUEST)
        reuse = PREPARE.split("let primaryTexture:", 1)[1].split("} else {", 1)[0]
        self.assertIn("existingEntry.dimensions == outputDimensions", reuse)
        self.assertIn("Self.matricesMatch(existingEntry.voxelToWorld, outputVoxelToWorld)", reuse)
        self.assertIn("primaryTexture = existingEntry.texture", reuse)

    def test_every_dependent_dispatch_has_a_device_barrier(self):
        self.assert_order(DISPATCH, "if uniformOffset > 0", "encoder.barrier(",
                          "encoder.setComputePipelineState", "MetalPreparedVolumeCache.dispatch3D(",
                          "uniformOffset += uniformStride")
        self.assertIn("afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch", DISPATCH)
        self.assertIn("visibilityOptions: .device", DISPATCH)
        self.assertIn("encoder.barrier(afterStages: .dispatch, beforeQueueStages: [.dispatch, .fragment, .blit]", PREPARE)
        for helper in ("encodeStoredConversion", "encodeResample", "encodeGaussianDownsample", "encodeBlur"):
            body = declaration(f"private func {helper}(", CACHE)
            self.assertEqual(body.count("pipelines.resources.encode("), 1)
            self.assertNotIn("endEncoding()", body)

    def test_distinct_bounded_uniform_slots_and_kernel_binding(self):
        stride = int(re.search(r"uniformStride = (\d+)", RESOURCES)[1])
        length = int(re.search(r"makeBuffer\(length: (\d+)", RESOURCES)[1])
        self.assertGreaterEqual(length, (2 + 3 * 4) * stride)
        self.assertEqual(stride % 256, 0)
        self.assert_order(DISPATCH, "MemoryLayout<T>.stride <= uniformStride",
                          "uniformOffset + uniformStride <= uniformBuffer.length", "storeBytes(of: uniforms",
                          "uniformBuffer.gpuAddress + UInt64(uniformOffset)", "dispatch3D(",
                          "uniformOffset += uniformStride")
        self.assertIn("arguments.setAddress(kernel?.gpuAddress ?? 0, index: 1)", DISPATCH)
        self.assertIn("descriptor.maxBufferBindCount = 2", RESOURCES)
        self.assertIn("descriptor.maxTextureBindCount = 2", RESOURCES)
        self.assertIn("descriptor.initializeBindings = true", RESOURCES)
        self.assertIn("arguments.setTexture(source.gpuResourceID, index: 0)", DISPATCH)
        self.assertIn("arguments.setTexture(destination.gpuResourceID, index: 1)", DISPATCH)

    def test_intermediate_resources_are_resident_and_retained_until_feedback(self):
        self.assertIn("retainedResources: [ObjectIdentifier: MTLResource]", RESOURCES)
        self.assertIn("retainedResources.updateValue(resource, forKey: ObjectIdentifier(resource)) == nil", RESOURCES)
        self.assertIn("residency.addAllocation(resource)", RESOURCES)
        self.assertIn("retain(uniformBuffer)", declaration("func begin()", RESOURCES))
        for resource in ("source", "destination", "kernel"):
            self.assertIn(f"retain({resource})", DISPATCH)
        self.assert_order(PREPARE.split("let entry = Entry(", 1)[1], "encoder.endEncoding()",
                          "resources.residency.commit()", "commandBuffer.useResidencySet(resources.residency)",
                          "commandBuffer.endCommandBuffer()", "options.addFeedbackHandler",
                          "pipelines.commandQueue.commit([commandBuffer], options: options)")
        self.assertIn("[self, pipelines] feedback in", FEEDBACK)
        self.assert_order(FEEDBACK, "preparationQueue.async", "pipelines.resources.releaseResources()",
                          "if let error = feedback.error", "entry: nil", "entry: entry")
        self.assert_order(declaration("func releaseResources()", RESOURCES), "residency.removeAllAllocations()",
                          "residency.commit()", "retainedResources.removeAll(keepingCapacity: true)")

    def test_partial_encoding_failure_never_submits_and_unwinds_storage(self):
        failure = PREPARE.split("guard let encoder =", 1)[1].split("\n        }", 1)[0]
        self.assert_order(failure, "commandBuffer.endCommandBuffer()", "resources.releaseResources()",
                          "finish(requestKey: requestKey, key: key, entry: nil)", "return")
        cleanup = declaration("defer {", PREPARE)
        self.assert_order(cleanup, "if submitted == false", "encoder.endEncoding()",
                          "commandBuffer.endCommandBuffer()", "resources.releaseResources()")
        self.assertEqual(PREPARE.count("submitted = true"), 1)
        self.assert_order(PREPARE, "let options = MTL4CommitOptions()", "submitted = true",
                          "pipelines.commandQueue.commit(")
        self.assertNotIn("entry: entry", PREPARE.split("options.addFeedbackHandler", 1)[0])
        self.assertIn("precondition(retainedResources.isEmpty)", RESOURCES)

    def test_conversion_and_gantry_geometry_preserve_voxel_values(self):
        convert = declaration("private func encodeStoredConversion(", CACHE)
        resample = declaration("private func encodeResample(", CACHE)
        self.assertIn("sourceEntry.textureKind == .storedInt16Signed", convert)
        self.assertIn("? pipelines.convertSigned\n                : pipelines.convertUnsigned", convert)
        self.assertIn("SIMD4<Float>(sourceEntry.rescaleSlope, sourceEntry.rescaleIntercept, 0, 0)", convert)
        for value in ("correctGantryTilt && geometry.requiresCorrection()",
                      "appliesGantryCorrection ? geometry.dimensions : sourceDimensions",
                      "geometry.correctedVoxelToPatientMatrix", "geometry.sourceVoxelToPatientMatrix",
                      "backgroundValue: Self.isCTVolume(pixList) ? -1024 : 0",
                      "defaultWindow: sourceEntry.defaultWindow", "fullDynamicWindow: sourceEntry.fullDynamicWindow"):
            self.assertIn(value, PREPARE)
        self.assertIn("outputVoxelToWorld: outputVoxelToWorld", resample)
        self.assertIn("sourceWorldToVoxel: simd_inverse(sourceVoxelToWorld)", resample)
        self.assertIn("descriptor.pixelFormat = .r32Float", CACHE)
        self.assertIn("MetalTextureLimits.supports3DTexture(", CACHE)

    def test_registration_pyramid_keeps_geometry_filters_and_coarse_first_order(self):
        pyramid = declaration("private func encodeRegistrationPyramid(", CACHE)
        downsample = declaration("private func encodeGaussianDownsample(", CACHE)
        kernel = declaration("private func makeKernelBuffer(", CACHE)
        self.assertIn("for _ in 0..<3", pyramid)
        self.assertIn("factor *= 2", pyramid)
        self.assertEqual(pyramid.count("voxelToWorld * Self.scaleMatrix(factor: factor)"), 2)
        self.assertIn("return Array(fineToCoarse.reversed())", pyramid)
        for axis in "xyz":
            self.assertIn(f"max((currentDimensions.{axis} + 1) / 2, 1)", pyramid)
            self.assertIn(f"sigmaMM / max(voxelSpacing.{axis}, 0.0001)", downsample)
            self.assertIn(f"max((dimensions.{axis} + 1) / 2, 1)", downsample)
        self.assert_order(downsample, "let sigmaMM: Float = 1", "source: source, destination: blurX",
                          "source: blurX, destination: blurY", "source: blurY, destination: blurZ",
                          "factor: 2", "source: blurZ, destination: output")
        self.assertIn("max(Int(ceil(clampedSigma * 2.5)), 1)", kernel)
        self.assertIn("exp(-(x * x) / (2 * clampedSigma * clampedSigma))", kernel)
        self.assertIn("kernel = kernel.map { $0 / sum }", kernel)

    def test_cache_policy_and_main_queue_delivery_are_unchanged(self):
        self.assertIn("maximumEntryCount = 3", CACHE)
        self.assertIn("maximumCachedBytes = MetalViewerCachePolicy.volumeCacheBytes", CACHE)
        self.assertIn("current.hasRegistrationPyramid,\n               entry.hasRegistrationPyramid == false", FINISH)
        self.assertIn("resolvedEntry = current", FINISH)
        self.assertIn("isUnderMemoryPressure == false, entry.byteCount <= maximumCachedBytes", FINISH)
        self.assert_order(FINISH, "inFlightCompletions.removeValue(forKey: requestKey)",
                          "lock.unlock()", "DispatchQueue.main.async", "completion(deliveredEntry)")
        self.assertIn('"prepare.sharedVolume.pyramid" : "prepare.sharedVolume.display"', PREPARE)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS Metal SDK")
    def test_entire_actual_cache_typechecks_against_metal4(self):
        # Only application inputs are stubbed: actual queueing, resource ownership,
        # all compute dispatches, cache state and completion handling are checked.
        harness = "import Foundation\nimport Dispatch\nimport Metal\nimport simd\n"
        harness += """
struct MetalViewerWindowLevel { let width, level: Float }
final class DCMPix { var modalityString: String?; var rescaleType: String? }
enum MetalSeriesTextureCache {
    enum TextureKind { case storedInt16Signed, storedInt16Unsigned, rescaledFloat }
    struct Entry {
        let key: String
        let texture: MTLTexture
        let textureKind: TextureKind
        let dimensions: SIMD3<Int>
        let rescaleSlope, rescaleIntercept: Float
        let defaultWindow, fullDynamicWindow: MetalViewerWindowLevel
    }
}
enum MetalViewerGantryTiltGeometryBuilder {
    static func geometry(for pixList: [DCMPix], sourceDimensions: SIMD3<Int>) -> MetalViewerGantryTiltGeometry {
        fatalError()
    }
}
"""
        for marker in ("enum MetalTextureLimits", "struct MetalViewerGantryTiltGeometry",
                       "struct MetalPreparedVolumeLevel", "final class MetalPreparedVolumeCache"):
            harness += declaration(marker, MODELS) + "\n"
        with tempfile.TemporaryDirectory(prefix="horos-shared-preparation-api-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache",
                str(path), str(SOURCES / "MetalPipelineCache.swift"),
                str(SOURCES / "MetalPerformanceTrace.swift"), str(SOURCES / "MetalViewerCachePolicy.swift"),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
