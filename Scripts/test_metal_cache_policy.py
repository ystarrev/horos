"""Cache retention and ownership source guards; no build or pressure injection."""

from pathlib import Path
import unittest

from test_macos_baseline import project_objects


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
POLICY = (SOURCES / "MetalViewerCachePolicy.swift").read_text()
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
READER = (SOURCES / "SwiftDICOMReader.swift").read_text()
SERIES = MODELS.split("final class MetalSeriesTextureCache {", 1)[1].split(
    "\nenum MetalDynamicDetectionConfidence", 1
)[0]
PREPARED = MODELS.split("final class MetalPreparedVolumeCache {", 1)[1]


def method(source, signature):
    return source.split(signature, 1)[1].split("\n    }", 1)[0]


class MetalCachePolicyTests(unittest.TestCase):
    def test_shared_policy_is_compiled_into_horos_once(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        references = [key for key, obj in objects.items()
                      if obj.get("isa") == "PBXFileReference"
                      and obj.get("path") == "Horos/Sources/MetalViewer/MetalViewerCachePolicy.swift"]
        self.assertEqual(len(references), 1)
        owners = []
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] == "PBXSourcesBuildPhase":
                    for build_id in phase["files"]:
                        if objects[build_id]["fileRef"] == references[0]:
                            owners.append(target["name"])
        self.assertEqual(owners, ["Horos"])

    def test_budgets_scale_with_ram_without_exceeding_previous_caps(self):
        self.assertIn("Int(min(ProcessInfo.processInfo.physicalMemory / 8, 1_500_000_000))", POLICY)
        self.assertIn("Int(min(ProcessInfo.processInfo.physicalMemory / 32, 512 * 1_024 * 1_024))", POLICY)
        for source in (SERIES, PREPARED):
            self.assertIn("maximumCachedBytes = MetalViewerCachePolicy.volumeCacheBytes", source)
            self.assertIn("maximumEntryCount = 3", source)
        self.assertIn("cache.totalCostLimit = MetalViewerCachePolicy.readerCacheBytes", READER)
        self.assertIn("cache.countLimit = 512", READER)

    def test_allocation_limit_is_independent_of_retention(self):
        self.assertIn("maximumVolumeTextureBytes = 1_500_000_000", SERIES)
        allocation = method(SERIES, "private func canCreateVolumeTexture(")
        self.assertIn("MetalTextureLimits.supports3DTexture", allocation)
        self.assertIn("guard byteCount <= maximumVolumeTextureBytes", allocation)
        self.assertNotIn("maximumCachedBytes", allocation)
        self.assertNotIn("isUnderMemoryPressure", allocation)

    def test_pressure_observer_handles_recovery_without_a_retain_cycle(self):
        self.assertIn("eventMask: [.normal, .warning, .critical]", POLICY)
        self.assertIn("source.setEventHandler { [weak self]", POLICY)
        self.assertIn("if events.contains(.warning) || events.contains(.critical)", POLICY)
        self.assertIn("handler(true)", POLICY)
        self.assertIn("else if events.contains(.normal)", POLICY)
        self.assertIn("handler(false)", POLICY)
        self.assertLess(POLICY.index("source.setEventHandler"), POLICY.index("source.activate()"))
        self.assertIn("deinit {\n        source.cancel()", POLICY)

    def test_pressure_changes_future_retention_without_traversing_old_caches(self):
        for source in (SERIES, PREPARED):
            with self.subTest(cache=source[:40]):
                self.assertIn("MetalViewerCacheMemoryPressureObserver { [weak self] constrained in", source)
                pressure = method(source, "private func handleMemoryPressure(")
                self.assertIn("lock.lock()", pressure)
                self.assertIn("defer { lock.unlock() }", pressure)
                self.assertIn("isUnderMemoryPressure = constrained", pressure)
                self.assertNotRegex(pressure, r"entries|accessOrder|cachedByteCount|removeAll")
                self.assertNotRegex(pressure, r"inFlight|completion|cancel|Unavailable|pipelines|\.shared")

    def test_completed_volumes_are_delivered_even_when_not_retained(self):
        for source, signature, argument in (
            (SERIES, "private func finishRequest(", "entry"),
            (PREPARED, "private func finish(", "deliveredEntry"),
        ):
            with self.subTest(cache=signature):
                finish = method(source, signature)
                self.assertIn("isUnderMemoryPressure == false, entry.byteCount <= maximumCachedBytes", finish)
                self.assertLess(finish.index("lock.lock()"), finish.index("isUnderMemoryPressure == false"))
                self.assertLess(finish.index("isUnderMemoryPressure == false"), finish.index("entries.updateValue"))
                self.assertIn("cachedByteCount -= previous.byteCount", finish)
                self.assertIn("cachedByteCount += entry.byteCount", finish)
                self.assertIn("inFlightCompletions.removeValue", finish)
                self.assertLess(finish.index("lock.unlock()"), finish.index("DispatchQueue.main.async"))
                self.assertIn(f"completion({argument})", finish)
                self.assertNotIn("return", finish)
        finish = method(SERIES, "private func finishRequest(")
        self.assertLess(finish.index("clearStoredInt16UnavailableLocked"), finish.index("isUnderMemoryPressure"))
        self.assertIn("} else {\n            markStoredInt16UnavailableLocked(key)", finish)

    def test_trim_enforces_both_limits_and_preserves_accounting(self):
        for source in (SERIES, PREPARED):
            trim = method(source, "private func trimLocked()")
            self.assertIn("while accessOrder.count > maximumEntryCount || cachedByteCount > maximumCachedBytes", trim)
            self.assertIn("accessOrder.removeFirst()", trim)
            self.assertIn("entries.removeValue(forKey: key)", trim)
            self.assertIn("cachedByteCount -= removed.byteCount", trim)
            self.assertNotIn("newestKey", trim)
            self.assertNotIn("accessOrder.count > 1", trim)

    def test_reader_does_not_repopulate_during_pressure_or_reject_large_files(self):
        observer = READER.split("private static let readerCachePressureObserver", 1)[1].split("\n    }", 1)[0]
        self.assertIn("readerCacheLock.lock()", observer)
        self.assertIn("defer { readerCacheLock.unlock() }", observer)
        self.assertIn("isReaderCacheUnderMemoryPressure = constrained", observer)
        self.assertNotIn("removeAllObjects", observer)
        cached = method(READER, "static func cached(contentsOfFile")
        self.assertIn("_ = readerCachePressureObserver", cached)
        self.assertIn("if isReaderCacheUnderMemoryPressure == false,", cached)
        self.assertIn("reader.data.count <= MetalViewerCachePolicy.readerCacheBytes", cached)
        self.assertLess(cached.index("try SwiftDICOMReader("), cached.index("readerCacheLock.lock()"))
        self.assertLess(cached.index("readerCacheLock.lock()"), cached.index("readerCache.setObject"))
        self.assertLess(cached.index("readerCache.setObject"), cached.index("readerCacheLock.unlock()"))
        self.assertLess(cached.index("readerCacheLock.unlock()"), cached.index("return reader"))

    def test_prepared_pyramids_are_not_downgraded_by_late_requests(self):
        finish = method(PREPARED, "private func finish(")
        self.assertIn("current.hasRegistrationPyramid,\n               entry.hasRegistrationPyramid == false", finish)
        self.assertIn("resolvedEntry = current", finish)
        self.assertLess(finish.index("resolvedEntry = current"), finish.index("entries.updateValue"))


if __name__ == "__main__":
    unittest.main()
