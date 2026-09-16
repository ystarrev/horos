"""Publication source contracts and native TXT encoding checks; no network traffic.

These checks do not execute the Swift publisher or replace live-peer testing.
"""

import ctypes
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
ADVERTISEMENT = (SOURCES / "HorosBonjourAdvertisement.swift").read_text()
APP = (SOURCES / "AppController.m").read_text()
PUBLISHER = (SOURCES / "BonjourPublisher.m").read_text()
QUERY = (SOURCES / "DCMNetServiceDelegate.m").read_text()
SETTINGS = (SOURCES / "HorosDatabaseNetworkSettings.swift").read_text()
SETTINGS_WINDOW = (SOURCES / "HorosSettingsWindowController.swift").read_text()
SOURCE_BROWSER = (SOURCES / "BrowserController+Sources.m").read_text()


class BonjourAdvertisementTests(unittest.TestCase):
    def test_pending_name_edit_is_committed_before_sharing_is_enabled(self):
        checkbox = SETTINGS.split("private final class HorosDefaultsCheckbox", 1)[1].split(
            "private final class HorosDefaultsTextField", 1)[0]
        action = checkbox.split("@objc private func valueChanged(_ sender: NSButton)", 1)[1]
        self.assertIn("editor.isFieldEditor", action)
        self.assertLess(action.index("window?.makeFirstResponder(nil)"), action.index("UserDefaults.standard.set("))
        self.assertIn("sender.state = UserDefaults.standard.bool(forKey: defaultsKey) ? .on : .off", action)
        controller = SETTINGS_WINDOW.split("final class HorosSettingsWindowController:", 1)[1]
        self.assertIn("NSWindowDelegate", controller)
        self.assertIn("window.delegate = self", controller)
        self.assertIn("func windowShouldClose(_ sender: NSWindow) -> Bool {\n        sender.makeFirstResponder(nil)", controller)

    def test_reused_database_source_refreshes_its_advertised_name(self):
        resolve = SOURCE_BROWSER.split("-(void)netServiceDidResolveAddress:", 1)[1].split(
            "-(void)netService:", 1)[0]
        reuse = resolve.index("source = [_browser.sources.content objectAtIndex:i]")
        rename = resolve.index("source.description = service.name;")
        self.assertLess(reuse, rename)
        self.assertIn("else if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && service.name.length)", resolve)
        self.assertIn("source.aetitle = [resolvedAETitle length] ? resolvedAETitle : service.name;", resolve)
        identifiers = (SOURCES / "DataNodeIdentifier.m").read_text()
        remote = identifiers.split("@implementation RemoteDatabaseNodeIdentifier", 1)[1].split("@end", 1)[0]
        self.assertIn("if (![dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]])\n        return NO;", remote)

    def test_network_settings_expose_database_sharing_separately_from_dicom(self):
        listener = SETTINGS.split("private final class ListenerSettingsViewController", 1)[1].split(
            "private final class DICOMNodeEditorView", 1)[0]
        for key in ("bonjourSharing", "bonjourServiceName", "bonjourPasswordProtected", "publishDICOMBonjour"):
            self.assertIn(f'defaultsKey: "{key}"', listener)
        self.assertIn('addCard(title: "Database Sharing"', listener)
        self.assertIn("let sharingPassword = NSSecureTextField", listener)
        self.assertIn('sharingPassword.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.bonjourPassword"', listener)
        self.assertNotIn("UserDefaults.standard.set(", listener)

    def test_sharing_can_be_configured_before_enabling_network_access(self):
        sharing = SETTINGS.split("let sharing = HorosDefaultsCheckbox", 1)[1].split(
            'addCard(title: "Services & Diagnostics"', 1)[0]
        self.assertNotIn("sharingName.isEnabled", sharing)
        self.assertNotIn("passwordProtected.isEnabled", sharing)
        self.assertNotIn("sharing.state", sharing)
        self.assertIn("sharingPassword.isEnabled = passwordProtected.state == .on", sharing)
        self.assertIn("passwordProtected.changeHandler = { enabled in", sharing)
        self.assertIn("sharingPassword.isEnabled = enabled", sharing)

    def test_sharing_and_name_changes_take_effect_without_restarting(self):
        observation = PUBLISHER.split("-(void)observeValueForKeyPath:", 1)[1].split(
            "- (void)toggleSharing:", 1)[0]
        self.assertIn("[self toggleSharing:NSUserDefaults.bonjourSharingIsActive]", observation)
        rename = observation.split("OsirixBonjourSharingNameDefaultsKey", 1)[1].split("return;", 1)[0]
        self.assertIn("[_bonjour stop]", rename)
        self.assertIn("[self updateBonjour]", rename)
        toggle = PUBLISHER.split("- (void)toggleSharing:", 1)[1].split("- (void)updateBonjour", 1)[0]
        self.assertIn("if (activate && !_listener)", toggle)
        self.assertIn("if (!activate && _listener)", toggle)
        self.assertIn("[_listener release]", toggle)
        self.assertIn("[self updateBonjour]", toggle)

    def test_existing_ports_are_advertised_without_another_listener(self):
        self.assertIn("DNSServiceRegister(&reference, 0, 0, requestedName, type, nil, nil", ADVERTISEMENT)
        self.assertIn("UInt16(exactly: port)", ADVERTISEMENT)
        self.assertIn("wirePort > 0", ADVERTISEMENT)
        self.assertIn("wirePort.bigEndian", ADVERTISEMENT)
        for obsolete in ("NWListener", "NetService(", "Process(", "DNSServiceProcessResult"):
            self.assertNotIn(obsolete, ADVERTISEMENT)
        self.assertIn('type:@"_dicom._tcp"', APP)
        self.assertIn('stringForKey:@"AEPORT"] intValue]', APP)
        self.assertIn('type:@"_osirixdb._tcp" port:[_listener port]', PUBLISHER)

    def test_callbacks_and_context_disposal_stay_on_the_same_queue(self):
        self.assertIn("DNSServiceSetDispatchQueue(reference, .main)", ADVERTISEMENT)
        self.assertEqual(ADVERTISEMENT.count("dispatchPrecondition(condition: .onQueue(.main))"), 3)
        self.assertIn("weak var owner: HorosBonjourAdvertisement?", ADVERTISEMENT)
        self.assertIn("owner.registration === pending", ADVERTISEMENT)
        self.assertIn("pending.reference == reference", ADVERTISEMENT)
        deinit = ADVERTISEMENT.split("deinit {", 1)[1]
        self.assertIn("if Thread.isMainThread", deinit)
        self.assertIn("DispatchQueue.main.async { registration.close() }", deinit)
        self.assertNotIn("passRetained", ADVERTISEMENT)

    def test_stop_cancels_retries_and_releases_registration(self):
        stop = ADVERTISEMENT.split("@objc func stop()", 1)[1].split("private func register()", 1)[0]
        for expected in ("isActive = false", "generation &+= 1", "retry?.cancel()", "retry = nil",
                         "registration?.close()", "registration = nil", "retryDelay = 1"):
            self.assertIn(expected, stop)
        self.assertIn("self.generation == currentGeneration", ADVERTISEMENT)
        self.assertIn("self.isActive", ADVERTISEMENT)
        self.assertIn("guard isActive, registration == nil", ADVERTISEMENT)

    def test_only_transient_failures_retry_with_bounded_backoff(self):
        failure = ADVERTISEMENT.split("private func failed(", 1)[1].split("private static func isTransient", 1)[0]
        self.assertLess(failure.index("registration?.close()"), failure.index("asyncAfter"))
        self.assertIn("Self.isTransient(error)", failure)
        self.assertIn("min(retryDelay * 2, 10)", failure)
        self.assertIn("did not publish", failure)
        transient = ADVERTISEMENT.split("private static func isTransient", 1)[1].split("private static func encode", 1)[0]
        self.assertIn("kDNSServiceErr_ServiceNotRunning", transient)
        self.assertIn("kDNSServiceErr_DefunctConnection", transient)
        self.assertIn("default:\n            return false", transient)

    def test_native_txt_encoder_preserves_empty_utf8_values_and_updates_in_place(self):
        for expected in ("TXTRecordCreate", "TXTRecordSetValue", "defer { TXTRecordDeallocate",
                         "value.utf8.count", "value.withCString", "UInt8(exactly:", "<= 255",
                         "DNSServiceUpdateRecord(reference, nil", "let changed = txtData != data"):
            self.assertIn(expected, ADVERTISEMENT)
        for key in ("UID", "AETitle", "CGET", "preferredSyntax", "HorosFastStoreVersion",
                    "HorosFastStorePDU", "HorosDirectTransferVersion", "HorosDirectTransferPort",
                    "HorosDirectTransferToken", "serverDescription"):
            self.assertIn(f'@"{key}"', APP)
        for key in ("UID", "AETitle", "port"):
            self.assertIn(f'@"{key}"', PUBLISHER)

    def test_restart_and_shutdown_cancel_stale_delayed_publication(self):
        restart = APP.split("-(void) restartSTORESCP", 1)[1].split("-(void) displayError:", 1)[0]
        self.assertIn("[dicomBonjourStartTimer invalidate]", restart)
        self.assertIn("dicomBonjourStartTimer = [NSTimer scheduledTimer", restart)
        self.assertLess(restart.index("[BonjourDICOMService stop]"), restart.index("startSTORESCP:"))
        self.assertIn("t != dicomBonjourStartTimer", APP)
        termination = APP.split("- (void) applicationWillTerminate:", 1)[1].split("quitting = YES", 1)[0]
        self.assertIn("[dicomBonjourStartTimer invalidate]", termination)
        self.assertIn("[BonjourDICOMService stop]", termination)
        self.assertIn("[_bonjourPublisher toggleSharing:NO]", termination)

    def test_query_self_filter_reads_current_identity_including_auto_renames(self):
        self.assertIn("owner.name = String(cString: name)", ADVERTISEMENT)
        self.assertIn("[[AppController sharedAppController] dicomBonjourPublisher]", QUERY)
        self.assertIn("[publisher txtRecord]", QUERY)
        self.assertIn("[serviceUID isEqualToString: publisherUID]", QUERY)
        self.assertIn("caseInsensitiveCompare:[publisher name]", QUERY)
        self.assertIn("servicePort == [publisher port]", QUERY)
        self.assertNotIn("setPublisher:", QUERY + APP)
        header = (SOURCES / "DCMNetServiceDelegate.h").read_text()
        self.assertNotIn("NSNetService *publisher", header)


class TXTRecord(ctypes.Union):
    _fields_ = [("storage", ctypes.c_char * 16), ("alignment", ctypes.c_void_p)]


@unittest.skipUnless(sys.platform == "darwin", "Uses Apple's native TXT encoder")
class NativeTXTRecordTests(unittest.TestCase):
    def test_wire_fields_round_trip_without_loss(self):
        api = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        api.TXTRecordCreate.argtypes = [ctypes.POINTER(TXTRecord), ctypes.c_uint16, ctypes.c_void_p]
        api.TXTRecordCreate.restype = None
        api.TXTRecordSetValue.argtypes = [ctypes.POINTER(TXTRecord), ctypes.c_char_p, ctypes.c_uint8, ctypes.c_void_p]
        api.TXTRecordSetValue.restype = ctypes.c_int32
        api.TXTRecordGetLength.argtypes = [ctypes.POINTER(TXTRecord)]
        api.TXTRecordGetLength.restype = ctypes.c_uint16
        api.TXTRecordGetBytesPtr.argtypes = [ctypes.POINTER(TXTRecord)]
        api.TXTRecordGetBytesPtr.restype = ctypes.c_void_p
        api.TXTRecordDeallocate.argtypes = [ctypes.POINTER(TXTRecord)]
        api.TXTRecordDeallocate.restype = None
        values = {"UID": "host|user", "AETitle": "OSIRIX_YPS", "port": "4096", "CGET": "YES",
                  "HorosDirectTransferToken": "a=b+c/123", "HorosDirectTransferPort": "57502",
                  "serverDescription": "M\u00e9decine", "empty": ""}
        record = TXTRecord()
        api.TXTRecordCreate(ctypes.byref(record), 0, None)
        try:
            for key, value in sorted(values.items()):
                encoded = value.encode("utf-8")
                buffer = ctypes.create_string_buffer(encoded)
                self.assertEqual(api.TXTRecordSetValue(ctypes.byref(record), key.encode("ascii"), len(encoded), buffer), 0)
            wire = ctypes.string_at(api.TXTRecordGetBytesPtr(ctypes.byref(record)),
                                    api.TXTRecordGetLength(ctypes.byref(record)))
        finally:
            api.TXTRecordDeallocate(ctypes.byref(record))
        decoded = {}
        while wire:
            count, wire = wire[0], wire[1:]
            self.assertGreater(count, 0)
            self.assertLessEqual(count, len(wire))
            key, separator, value = wire[:count].partition(b"=")
            self.assertEqual(separator, b"=")
            decoded[key.decode("ascii")] = value.decode("utf-8")
            wire = wire[count:]
        self.assertEqual(decoded, values)


if __name__ == "__main__":
    unittest.main()
