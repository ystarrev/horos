"""Source guards for opt-in Metal timing; no app build or GPU execution."""

from pathlib import Path
import unittest

from test_macos_baseline import project_objects
from test_metal4_scout import declaration


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
TRACE = (SOURCES / "MetalPerformanceTrace.swift").read_text()


class MetalPerformanceTraceTests(unittest.TestCase):
    def test_trace_is_compiled_once_in_horos(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        refs = [key for key, obj in objects.items()
                if obj.get("isa") == "PBXFileReference"
                and obj.get("path") == "Horos/Sources/MetalViewer/MetalPerformanceTrace.swift"]
        self.assertEqual(len(refs), 1)
        owners = []
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] == "PBXSourcesBuildPhase":
                    for build_id in phase["files"]:
                        if objects[build_id]["fileRef"] == refs[0]:
                            owners.append(target["name"])
        self.assertEqual(owners, ["Horos"])

    def test_disabled_trace_does_not_install_handlers_or_evaluate_labels(self):
        self.assertIn('private static let enabled = UserDefaults.standard.bool(forKey: "HorosMetalPerformanceLogging")', TRACE)
        self.assertIn("enabled ? CACurrentMediaTime() : nil", TRACE)
        self.assertIn("_ operation: @autoclosure () -> String", TRACE)
        track = TRACE.split("static func track(", 1)[1].split("\n    }", 1)[0]
        self.assertLess(track.index("guard let startedAt"), track.index("addFeedbackHandler"))
        self.assertLess(track.index("guard let startedAt"), track.index("addPresentedHandler"))
        self.assertNotIn("register(defaults:", TRACE)

    def test_trace_never_submits_or_waits_or_reads_patient_objects(self):
        self.assertNotRegex(TRACE, r"\.(?:commit|waitUntilCompleted|waitUntilScheduled|makeCommandBuffer|present)\(")
        self.assertNotRegex(TRACE, r"\b(?:DCMPix|NSManagedObject|MetalStudyROI|MTLTexture|MTLBuffer)\b")
        self.assertNotIn("DispatchQueue.main", TRACE)
        self.assertNotIn("[weak self]", TRACE)
        self.assertIn("duration.isFinite, duration >= 0", TRACE)

    def test_gpu_and_display_timestamps_are_not_inferred_from_callbacks(self):
        self.assertIn("feedback.gpuStartTime", TRACE)
        self.assertIn("feedback.gpuEndTime", TRACE)
        self.assertIn("feedback.error == nil, gpuStart > 0, gpuEnd >= gpuStart", TRACE)
        self.assertIn("duration: gpuEnd - gpuStart", TRACE)
        self.assertIn("duration: observedAt - gpuEnd", TRACE)
        self.assertIn("presented.presentedTime > 0", TRACE)
        self.assertIn("duration: presented.presentedTime - submittedAt", TRACE)
        self.assertIn("duration: observedAt - waitStartedAt", TRACE)

    def test_metal4_feedback_uses_real_gpu_times_and_the_same_opt_in_gate(self):
        track = TRACE.split("_ options: MTL4CommitOptions,", 1)[1].split("\n    }", 1)[0]
        self.assertLess(track.index("guard let startedAt"), track.index("options.addFeedbackHandler"))
        self.assertIn("feedback.gpuStartTime", track)
        self.assertIn("feedback.gpuEndTime", track)
        self.assertIn("feedback.error == nil, gpuStart > 0, gpuEnd >= gpuStart", track)
        self.assertIn("duration: gpuEnd - gpuStart", track)
        self.assertIn("duration: presented.presentedTime - submittedAt", track)

    def test_summary_is_locked_and_rate_limited(self):
        record = TRACE.split("private static func record(", 1)[1]
        self.assertLess(record.index("lock.lock()"), record.index("summaries[operation] = summary"))
        self.assertLess(record.index("summaries[operation] = summary"), record.index("lock.unlock()"))
        self.assertLess(record.index("lock.unlock()"), record.index("NSLog("))
        self.assertIn("summary.count == 1 || summary.count % 60 == 0", record)
        self.assertIn("METALPERF %@ n=%ld mean=%.3fms max=%.3fms last=%.3fms", record)

    def test_registration_traces_after_completion_without_extra_diagnostic_handlers(self):
        renderer = (SOURCES / "MetalViewerRenderer.swift").read_text()
        resources = renderer.split("private final class RegistrationGPUResources", 1)[1].split(
            "private final class RegistrationJob", 1)[0]
        self.assertLess(resources.index("queue.commit("), resources.index("let waitStartedAt ="))
        self.assertLess(resources.index("completion.wait()"), resources.index("MetalPerformanceTrace.completed("))
        self.assertEqual(resources.count("addFeedbackHandler"), 1)  # One per submission, solely for completion.
        submit = resources.split("func performCompute(", 1)[1]
        self.assertLess(submit.index("let options = MTL4CommitOptions()"), submit.index("options.addFeedbackHandler"))
        self.assertLess(submit.index("options.addFeedbackHandler"), submit.index("queue.commit("))
        self.assertNotIn("MetalPerformanceTrace.track(", resources)
        for signature, name in (("directionalMetricValue", "directional"),
                                ("primaryMetricValues", "batch"),
                                ("registrationSupportMetricValues", "support")):
            method = renderer.split(f"private func {signature}(", 1)[1].split("\n    }", 1)[0]
            self.assertIn("let performanceStartedAt = MetalPerformanceTrace.begin()", method)
            self.assertIn(f'operation: "registration.{name}"', method)
            self.assertNotIn("MetalPerformanceTrace.track(", method)
            self.assertEqual(method.count("job.performCompute("), 1)
            self.assertNotIn("addFeedbackHandler", method)

    def test_rendering_and_volume_preparation_are_traced_before_commit(self):
        for filename, operations in (
            ("MetalPreviewImageView.swift", ("draw.preview",)),
            ("MetalViewerScoutView.swift", ("draw.scoutROI",)),
            ("Metal3DVolumeRenderer.swift", ("draw.volume", "prepare.volume", "pick.surface", "readback.volume")),
        ):
            source = (SOURCES / filename).read_text()
            for operation in operations:
                suffix = source.split(f'MetalPerformanceTrace.track(options, operation: "{operation}"', 1)[1]
                before_return = suffix.split("\n    }", 1)[0]
                commit = {
                    "draw.preview": "commandQueue.commit([commandBuffer], options: options)",
                    "draw.scoutROI": "renderQueue.commit([renderCommandBuffer], options: options)",
                    "draw.volume": "renderQueue.commit([renderCommandBuffer], options: options)",
                    "prepare.volume": "renderQueue.commit([renderCommandBuffer], options: options)",
                    "pick.surface": "frame.queue.commit([frame.commandBuffer], options: options)",
                    "readback.volume": "frame.queue.commit([frame.commandBuffer], options: options)",
                }[operation]
                self.assertIn(commit, before_return)
                if operation.startswith("draw."):
                    self.assertIn("drawable: drawable", before_return)

        source = (SOURCES / "MetalViewerRenderer.swift").read_text()
        for operation in ("draw.planar", "draw.mpr", "draw.mpr3D"):
            self.assertIn(f'submitDisplayFrame(frame, drawable: drawable, view: view, operation: "{operation}", since: performanceStartedAt)', source)
        submit = source.split("private func submitDisplayFrame(", 1)[1].split("func draw(in", 1)[0]
        self.assertLess(submit.index("MetalPerformanceTrace.track(options, operation: operation"),
                        submit.index("renderQueue.commit([renderCommandBuffer], options: options)"))
        self.assertIn("since: startedAt, drawable: drawable", submit)

    def test_skin_cpu_stage_timings_bracket_the_existing_work(self):
        source = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
        extract = declaration("private static func prepareSkinEnvelope(", source)
        extract += declaration("private static func makeSkinDistanceMask(", source)
        extract += declaration("private func ensureSkinMaskTexture(", source)
        stages = (
            ("foreground", "skin.foreground.cpu", "var foreground = [UInt8]", "foregroundVoxelCount += 1"),
            ("envelopeForeground", "skin.envelopeForeground.cpu", "Self.skinEnvelopeForegroundMask(", "rejectHighDensity: isCT"),
            ("envelope", "skin.envelope.cpu", "Self.externalAirReconstructedEnvelopeMask(", "exteriorAir: Self.invertedMask(fallbackEnvelope.mask)"),
            ("exteriorSurface", "skin.exteriorSurface.cpu", "Self.exteriorForegroundSurfaceMask(", "Self.largestConnectedSurfaceComponentMask("),
            ("vertexBuffer", "skin.vertexBuffer.cpu", "makeSkinSurfaceVertexBuffer(vertexFloatData:", "makeSkinSurfaceVertexBuffer(vertexFloatData:"),
            ("distance", "skin.distanceMask.cpu", "var mask = Self.invertedMask(preparation.envelope)", "maximumDistanceMM: shellThicknessMM"),
        )
        for variable, label, first, last in stages:
            with self.subTest(stage=label):
                begin = f"let {variable}StartedAt = MetalPerformanceTrace.begin()"
                end = f'MetalPerformanceTrace.end("{label}", since: {variable}StartedAt)'
                self.assertLess(extract.index(begin), extract.index(first))
                self.assertLessEqual(extract.index(first), extract.index(last))
                self.assertLess(extract.index(last), extract.index(end))
                self.assertEqual(extract.count(end), 1)

    def test_skin_worker_timings_separate_cached_work_and_main_thread_request(self):
        source = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
        wrapper = declaration("private static func makeSkinShellMask(", source)
        self.assertLess(wrapper.index("MetalPerformanceTrace.begin()"), wrapper.index("volumeData.withUnsafeBytes"))
        for label in ("skin.shellWithSurface.total", "skin.shellMaskOnly.total", "skin.shellMaskCached.total"):
            self.assertIn(label, declaration("defer {", wrapper))
        self.assertNotIn("cpuVolumeData()", wrapper)
        ensure = declaration("private func ensureSkinMaskTexture(", source)
        self.assertLess(ensure.index("guard needsMask || buildSurface"), ensure.index("let requestStartedAt"))
        self.assertLess(ensure.index("let requestStartedAt"), ensure.index("cpuVolumeData()"))
        self.assertIn('MetalPerformanceTrace.end("skin.request.cpu", since: requestStartedAt)', ensure)
        upload = declaration("if maskGeneration == self.skinMaskGeneration", ensure)
        self.assertLess(upload.index("MetalPerformanceTrace.begin()"), upload.index("makeSkinMaskTexture(mask:"))
        self.assertLess(upload.index("makeSkinMaskTexture(mask:"), upload.index('MetalPerformanceTrace.end("skin.maskTexture.cpu"'))

    def test_surface_calls_measure_host_totals_even_on_failure_not_fake_gpu_time(self):
        source = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
        surface = declaration("private static func extractSkinSurface(", source)
        for name, call, check in (
            ("mesh", "Metal3DSurfaceExtractor.extractSkinSurface(", "guard let extractedSurface = extractedSurfaceResult"),
            ("visibility", "Metal3DSurfaceExtractor.filterSurfaceVertexFloatData(", "guard let filteredSurfaceData = filteredSurfaceResult"),
        ):
            end = f'MetalPerformanceTrace.end("skin.{name}.total", since: {name}StartedAt)'
            self.assertLess(surface.index(f"let {name}StartedAt = MetalPerformanceTrace.begin()"), surface.index(call))
            self.assertLess(surface.index(call), surface.index(end))
            self.assertLess(surface.index(end), surface.index(check))
        self.assertNotRegex(surface, r"\.gpu\"|MetalPerformanceTrace.track|addFeedbackHandler|\.wait\(")

    def test_world_point_conversion_timing_covers_early_returns_without_identifiers(self):
        source = (SOURCES / "Metal3DVolumeRenderer.swift").read_text()
        points = declaration("private func worldPositions(fromSurfaceVertexFloatData", source)
        self.assertIn('MetalPerformanceTrace.end("surface.worldPoints.cpu", since: startedAt)', declaration("defer {", points))
        self.assertLess(points.index("MetalPerformanceTrace.begin()"), points.index("guard vertexFloatData.count"))
        self.assertNotIn("NSLog", points)


if __name__ == "__main__":
    unittest.main()
