"""Registration buffer ownership/control-flow guards, not GPU runtime tests."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/MetalViewer/MetalViewerRenderer.swift").read_text()
JOB = SOURCE.split("private final class RegistrationJob:", 1)[1].split(
    "\nprivate enum MetalMPRPreviewLayoutDefaults", 1
)[0]


def method(signature, source=SOURCE):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class RegistrationWorkingBufferTests(unittest.TestCase):
    def test_mutable_buffers_are_owned_by_one_job_and_one_device(self):
        self.assertIn("private let device: MTLDevice", JOB)
        self.assertIn("self.device = device", JOB)
        self.assertIn("private var workingBuffers: [WorkingBufferSlot: MTLBuffer] = [:]", JOB)
        self.assertNotIn("static", JOB)
        run = method("private func runRegistration(")
        self.assertIn("let job = RegistrationJob(\n            device: deviceRef,", run)
        self.assertLess(run.index("let job = RegistrationJob("), run.index("DispatchQueue.global"))
        self.assertEqual(SOURCE.count("let job = RegistrationJob("), 1)
        self.assertEqual(SOURCE.count("DispatchQueue.global"), 1)

    def test_growth_reuses_capacity_without_replacing_a_valid_buffer_on_failure(self):
        allocate = method("func workingBuffer(", JOB)
        self.assertIn("guard length > 0, length <= device.maxBufferLength", allocate)
        self.assertIn("if let buffer = workingBuffers[slot], buffer.length >= length", allocate)
        self.assertLess(allocate.index("return buffer"), allocate.index("device.makeBuffer"))
        self.assertIn("device.makeBuffer(length: length, options: .storageModeShared)", allocate)
        self.assertLess(allocate.index("return nil", allocate.index("device.makeBuffer")),
                        allocate.index("workingBuffers[slot] = buffer"))

    def test_every_uniform_upload_overwrites_the_current_active_bytes(self):
        upload = method("func uniformBuffer(", JOB)
        self.assertIn("workingBuffer(for: .uniforms(slot), length: bytes.count)", upload)
        self.assertIn("buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)", upload)
        self.assertLess(upload.index("workingBuffer("), upload.index("copyMemory("))
        self.assertLess(upload.index("copyMemory("), upload.index("return buffer"))
        primary = method("private func primaryMetricValues(")
        self.assertIn("job.uniformBuffer(uniforms, slot: 0)", primary)
        self.assertIn("job.uniformBuffer(reverseUniforms, slot: 1)", primary)
        support = method("private func registrationSupportMetricValues(")
        self.assertIn("for (pairIndex, pair) in pairs.enumerated()", support)
        self.assertIn("job.uniformBuffer(uniforms, slot: pairIndex)", support)
        self.assertIn("encoder.setBuffer(uniformBuffers[pairIndex], offset: 0, index: 0)", support)

    def test_accumulators_are_cleared_for_each_pass_not_only_on_allocation(self):
        for signature in ("private func directionalMetricValue(", "private func primaryMetricValues(",
                          "private func registrationSupportMetricValues("):
            with self.subTest(method=signature):
                body = method(signature)
                self.assertIn("for: .histogram", body)
                self.assertNotIn("makeBuffer(", body)
                self.assertIn("memset(histogramBuffer.contents(), 0, histogramBufferLength)", body)
                self.assertLess(body.index("memset("), body.index("commandBuffer.commit()"))
                self.assertNotIn("histogramBuffer.length", body)
        # The overload with fixedLevel owns the actual block-matching dispatch.
        block = method("fixedLevel: VolumeLevel,\n        movingLevel: VolumeLevel,")
        self.assertIn("for: .blockMatches", block)
        self.assertIn("memset(resultBuffer.contents(), 0, resultBufferLength)", block)
        self.assertNotIn("makeBuffer(", block)
        self.assertNotIn("resultBuffer.length", block)

    def test_gpu_completion_and_cpu_readback_precede_buffer_reuse(self):
        signatures = (
            ("private func directionalMetricValue(", "let histogram ="),
            ("private func primaryMetricValues(", "let histogram ="),
            ("private func registrationSupportMetricValues(", "let histogram ="),
            ("fixedLevel: VolumeLevel,\n        movingLevel: VolumeLevel,", "let results ="),
        )
        for signature, readback in signatures:
            with self.subTest(method=signature):
                body = method(signature)
                self.assertEqual(body.count("commandBuffer.commit()"), 1)
                self.assertLess(body.index("commandBuffer.commit()"), body.index("commandBuffer.waitUntilCompleted()"))
                self.assertLess(body.index("commandBuffer.waitUntilCompleted()"), body.index("commandBuffer.status == .completed"))
                self.assertLess(body.index("commandBuffer.status == .completed"), body.index(readback))
                self.assertNotRegex(body, r"concurrentPerform|addCompletedHandler|\.async\b")
        metrics = method("private func metricValues(")
        self.assertLess(metrics.index("let primaryMetrics = primaryMetricValues("),
                        metrics.index("let supportMetrics = registrationSupportMetricValues("))

    def test_cancellation_does_not_release_inflight_memory(self):
        cancel = method("func cancel()", JOB)
        self.assertIn("cancelled = true", cancel)
        self.assertNotIn("workingBuffer", cancel)
        self.assertNotIn("releaseWorkingBuffers", cancel)
        release = method("func releaseWorkingBuffers()", JOB)
        self.assertIn("workingBuffers.removeAll()", release)
        run = method("private func runRegistration(")
        worker = run.split("DispatchQueue.global", 1)[1].split("DispatchQueue.main.async", 1)[0]
        self.assertIn("defer { job.releaseWorkingBuffers() }", worker)
        self.assertLess(worker.index("defer { job.releaseWorkingBuffers() }"),
                        worker.index("guard let self, job.isCancelled == false"))
        self.assertEqual(SOURCE.count("job.releaseWorkingBuffers()"), 1)

    def test_histogram_offsets_and_active_counts_are_preserved(self):
        primary = method("private func primaryMetricValues(")
        self.assertIn("histogramPassLength * (usesBidirectionalMetric ? 2 : 1)", primary)
        self.assertIn("encoder.setBuffer(histogramBuffer, offset: histogramPassLength, index: 1)", primary)
        self.assertIn("histogramEntryCount * states.count * (usesBidirectionalMetric ? 2 : 1)", primary)
        support = method("private func registrationSupportMetricValues(")
        self.assertIn("offset: pairIndex * histogramPassEntryCount * MemoryLayout<UInt32>.stride", support)
        self.assertIn("capacity: histogramPassEntryCount * pairs.count", support)
        self.assertIn("by: pairIndex * histogramPassEntryCount", support)
        self.assertIn("+ candidateIndex * histogramEntryCount", support)


if __name__ == "__main__":
    unittest.main()
