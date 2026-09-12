"""Source/project contracts for the Network.framework discovery checkpoint.

These do not browse a live network or replace desktop/laptop integration testing.
"""

from pathlib import Path
import plistlib
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
BROWSER = (SOURCES / "HorosBonjourBrowser.swift").read_text()
SOURCE_LIST = (SOURCES / "BrowserController+Sources.m").read_text()
QUERY = (SOURCES / "DCMNetServiceDelegate.m").read_text()
PUBLISHER = (SOURCES / "BonjourPublisher.m").read_text()
APP = (SOURCES / "AppController.m").read_text()


class BonjourBrowserTests(unittest.TestCase):
    def test_sources_and_query_use_the_same_network_browser(self):
        self.assertEqual(SOURCE_LIST.count("[[HorosBonjourBrowser alloc] init]"), 3)
        self.assertEqual(QUERY.count("[[HorosBonjourBrowser alloc] init]"), 1)
        for path in SOURCES.rglob("*"):
            if path.suffix in (".h", ".m", ".mm", ".swift"):
                self.assertNotIn("NSNetServiceBrowser", path.read_text(), str(path))
        self.assertIn("HorosBonjourBrowserDelegate", SOURCE_LIST)
        self.assertIn("<HorosBonjourBrowserDelegate>", QUERY)
        self.assertIn('import Network', BROWSER)
        self.assertIn(".bonjourWithTXTRecord(type: type", BROWSER)
        self.assertIn("parameters.includePeerToPeer = true", BROWSER)

    def test_service_identity_retains_domain_and_aggregates_interfaces(self):
        identity = BROWSER.split("private struct Identity:", 1)[1].split("private struct Discovery", 1)[0]
        for field in ("name", "type", "domain"):
            self.assertIn(f"self.{field} = {field}.lowercased()", identity)
        self.assertNotIn("interface:", identity)
        self.assertIn("grouped[Identity(name: name, type: type, domain: domain), default: []].insert(result)", BROWSER)
        self.assertIn("where grouped[identity] == nil", BROWSER)
        self.assertIn("existing.results != observations", BROWSER)
        self.assertIn("didUpdate: existing.service", BROWSER)

    def test_callbacks_are_serial_and_stale_searches_are_rejected(self):
        self.assertIn("browser.start(queue: .main)", BROWSER)
        self.assertGreaterEqual(BROWSER.count("self.generation == currentGeneration"), 3)
        self.assertGreaterEqual(BROWSER.count("guard generation == currentGeneration"), 3)
        stop = BROWSER.split("@objc func stop()", 1)[1].split("private func announceSearchIfNeeded", 1)[0]
        for text in ("generation &+= 1", "stateUpdateHandler = nil", "browseResultsChangedHandler = nil",
                     "browser?.cancel()", "discoveries.removeAll()", "discovery.service.delegate = nil"):
            self.assertIn(text, stop)
        self.assertIn("guard !didAnnounceSearch else { return }", BROWSER)

    def test_transient_waiting_does_not_clear_sources_or_restart_loop(self):
        waiting = BROWSER.split("case .waiting(let error):", 1)[1].split("case .failed", 1)[0]
        self.assertIn("NSLog(", waiting)
        self.assertNotIn("self.fail(", waiting)
        self.assertNotIn("stop()", waiting)
        self.assertNotIn("apply(", waiting)
        self.assertNotIn("asyncAfter", waiting)
        failure = BROWSER.split("private func fail(", 1)[1].split("deinit", 1)[0]
        self.assertLess(failure.index("apply([], generation:"), failure.index("didNotSearch: errorInfo"))

    def test_refreshes_existing_resolvers_and_rejects_late_resolve_results(self):
        for source in (SOURCE_LIST, QUERY):
            self.assertIn("didUpdateService:(NSNetService*)service" if source == SOURCE_LIST
                          else "didUpdateService:(NSNetService *)aNetService", source)
        self.assertIn("if (_invalidated) return;", SOURCE_LIST)
        self.assertIn("if (!_dicomNetBrowser || ![_dicomServices containsObject:aNetService]) return;", QUERY)
        self.assertNotIn("if (!source.location && address.count >= 2)", SOURCE_LIST)
        start = QUERY.split("- (void)_startDICOMBonjourSearch", 1)[1].split("- (void)observeValue", 1)[0]
        self.assertIn('![[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"]', start)

    def test_native_resolvers_publication_and_peer_checks_remain(self):
        self.assertIn("NetService(domain: domain, type: type, name: name)", BROWSER)
        self.assertIn("service.includesPeerToPeer = true", BROWSER)
        self.assertIn("[service resolveWithTimeout:30]", SOURCE_LIST)
        self.assertIn("_verifyBonjourSource:", SOURCE_LIST)
        self.assertIn("reconcileHorosDirectSources", SOURCE_LIST)
        self.assertIn("_resolvedBonjourServiceIsThisHorosType:serviceType", SOURCE_LIST)
        self.assertEqual(SOURCE_LIST.count('@"BonjourServiceKey"'), 2)
        self.assertNotIn("workaround may be removable", SOURCE_LIST)
        self.assertIn('type:@"_osirixdb._tcp" name:[NSUserDefaults bonjourSharingName] port:[_listener port]', PUBLISHER)
        self.assertIn("[NSNetService dataFromTXTRecordDictionary:txtrec]", PUBLISHER)
        self.assertIn("[_bonjour publish]", PUBLISHER)
        self.assertIn("[_bonjour stop]", PUBLISHER)
        self.assertIn('type:@"_dicom._tcp"', APP)
        self.assertIn("[BonjourDICOMService publish]", APP)
        self.assertIn("[BonjourDICOMService stop]", APP)
        self.assertIn('@"HorosDirectTransferToken"', APP)
        for publisher in (PUBLISHER, APP):
            self.assertIn("didNotPublish:", publisher)
            self.assertIn("did not publish", publisher)
        self.assertNotIn("NWListener", BROWSER)

    def test_no_subprocess_fallback_or_orphan_helper_bookkeeping_remains(self):
        for path in SOURCES.rglob("*"):
            if path.suffix in (".h", ".m", ".mm", ".swift"):
                source = path.read_text()
                for obsolete in ("/usr/bin/dns-sd", "DNSSDBrowseFallback", "DNSRegistration",
                                 "BonjourDNSSDTask", "_dnssd", "_bonjourRegisterTask",
                                 "BonjourDICOMRegisterTask", "dnsSDTXTArgumentsForDictionary",
                                 "requiresLegacyFallback"):
                    self.assertNotIn(obsolete, source, str(path))
        self.assertNotIn("import dnssd", BROWSER)

    def test_terminal_failures_report_original_error_and_retry_native_browser(self):
        self.assertIn("NetService.errorCode: nsError.code", BROWSER)
        self.assertIn("NetService.errorDomain: nsError.domain", BROWSER)
        self.assertIn("NSLocalizedDescriptionKey: nsError.localizedDescription", BROWSER)
        for source in (BROWSER, SOURCE_LIST, QUERY):
            self.assertNotIn("MissingRequiredConfigurationError", source)
            self.assertNotIn("missingRequiredConfigurationError", source)
        sources_failure = SOURCE_LIST.split("didNotSearch:(NSDictionary*)errorDict", 1)[1].split(
            "-(void)netServiceDidResolveAddress:", 1)[0]
        self.assertEqual(sources_failure.count("afterDelay:10.0"), 3)
        self.assertEqual(sources_failure.count("setDelegate:nil"), 3)
        query_failure = QUERY.split("didNotSearch:(NSDictionary *)errorDict", 1)[1].split(
            "didUpdateService:", 1)[0]
        self.assertIn("@selector(_startDICOMBonjourSearch)", query_failure)
        self.assertIn("afterDelay:10.0", query_failure)

    def test_service_types_are_declared_for_local_network_access(self):
        info = plistlib.loads((ROOT / "Horos/Info.plist").read_bytes())
        for service in ("_dicom._tcp", "_osirixdb._tcp", "_horosiphone._tcp"):
            self.assertIn(service, info["NSBonjourServices"])
        self.assertTrue(info["NSLocalNetworkUsageDescription"])

    def test_swift_browser_is_compiled_once_in_application(self):
        project = subprocess.check_output([
            "plutil", "-convert", "xml1", "-o", "-", str(ROOT / "Horos.xcodeproj/project.pbxproj")
        ])
        objects = plistlib.loads(project)["objects"]
        owners = []
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] != "PBXSourcesBuildPhase":
                    continue
                for build_id in phase["files"]:
                    file = objects[objects[build_id]["fileRef"]]
                    if file.get("path", "").endswith("HorosBonjourBrowser.swift"):
                        self.assertEqual(file["sourceTree"], "SOURCE_ROOT")
                        self.assertTrue((ROOT / file["path"]).is_file())
                        owners.append(target["name"])
        self.assertEqual(owners, ["Horos"])


if __name__ == "__main__":
    unittest.main()
