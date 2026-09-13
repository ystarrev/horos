"""Resolver source contracts and native address/TXT checks without network I/O.

The Swift state machine is type-checked separately; live peers remain a manual test.
"""

import ctypes
from pathlib import Path
import re
import socket
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
SERVICE = (SOURCES / "HorosBonjourService.swift").read_text()
BROWSER = (SOURCES / "HorosBonjourBrowser.swift").read_text()
SOURCE_LIST = (SOURCES / "BrowserController+Sources.m").read_text()
QUERY = (SOURCES / "DCMNetServiceDelegate.m").read_text()


class BonjourResolutionTests(unittest.TestCase):
    def test_legacy_service_api_is_removed_from_application(self):
        obsolete = re.compile(r"\b(?:NSNetService|NSNetServiceDelegate|NSNetServiceBrowser|NetService)\b")
        for path in SOURCES.rglob("*"):
            if path.suffix in (".swift", ".m", ".mm", ".h"):
                self.assertIsNone(obsolete.search(path.read_text()), str(path))

    def test_resolution_uses_discovered_interfaces_and_does_not_connect(self):
        self.assertIn("result.interfaces", BROWSER)
        self.assertIn("UInt32(exactly: $0.index)", BROWSER)
        self.assertIn("existing.service.interfaceIndexes = interfaceIndexes(in: observations)", BROWSER)
        self.assertIn("DNSServiceResolve(&reference, kDNSServiceFlagsIncludeP2P, index, name, type, domain", SERVICE)
        self.assertIn("DNSServiceGetAddrInfo(&reference, kDNSServiceFlagsIncludeP2P, interface, protocols", SERVICE)
        self.assertIn("kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6", SERVICE)
        for unwanted in ("NWConnection", "getaddrinfo(", "DNSServiceProcessResult", "waitUntilDone", "semaphore"):
            self.assertNotIn(unwanted, SERVICE)

    def test_cancellation_and_stale_callback_guards(self):
        self.assertIn("DNSServiceSetDispatchQueue(reference, .main)", SERVICE)
        self.assertEqual(SERVICE.count("owner.isCurrent(lookup, reference: reference)"), 2)
        self.assertIn("lookups.contains { $0 === lookup } && lookup.reference == reference", SERVICE)
        self.assertIn("self.generation == currentGeneration", SERVICE)
        stop = SERVICE.split("@objc func stop()", 1)[1].split("private func isCurrent", 1)[0]
        for expected in ("generation &+= 1", "timeout?.cancel()", "timeout = nil", "lookup.close()",
                         "lookups.removeAll()", "completionQueued = false"):
            self.assertIn(expected, stop)
        self.assertNotIn("snapshot =", stop)
        self.assertIn("let pending = lookups", SERVICE)
        self.assertIn("DispatchQueue.main.async { for lookup in pending { lookup.close() } }", SERVICE)

    def test_refresh_commits_a_complete_snapshot_and_failure_keeps_old_result(self):
        completion = SERVICE.split("private func queueCompletion()", 1)[1].split("private func failed(", 1)[0]
        self.assertIn("self.stop()", completion)
        self.assertIn("Snapshot(address: address.host, hostName: lookup.hostName, port: lookup.port, txt: lookup.txt)", completion)
        self.assertLess(completion.index("self.snapshot = snapshot"), completion.index("netServiceDidResolveAddress"))
        self.assertIn("snapshotLock.withLock { snapshot }", SERVICE)
        self.assertIn("service.resolvedAddress", SOURCE_LIST)
        self.assertIn("[sender resolvedAddress]", QUERY)
        self.assertIn("[service resolveWithTimeout:30]", SOURCE_LIST)
        self.assertIn("[aNetService resolveWithTimeout: 5]", QUERY)

    def test_batches_handle_missing_families_removal_and_ipv4_preference(self):
        missing = SERVICE.split("if error == kDNSServiceErr_NoSuchRecord", 1)[1].split("guard error", 1)[0]
        self.assertIn("owner.queueCompletion()", missing)
        self.assertNotIn("owner.failed", missing)
        self.assertIn("kDNSServiceFlagsMoreComing", SERVICE)
        self.assertIn("lookup.addresses.insert(value)", SERVICE)
        self.assertIn("lookup.addresses.remove(value)", SERVICE)
        self.assertIn("if $0.1.isIPv4 != $1.1.isIPv4 { return $0.1.isIPv4 }", SERVICE)
        self.assertIn("if lookups.isEmpty { fail(error) }", SERVICE)

    def test_port_scope_and_native_txt_parser_are_preserved(self):
        self.assertIn("UInt16(bigEndian: port)", SERVICE)
        self.assertIn("value.pointee.sin6_scope_id == 0", SERVICE)
        self.assertIn("value.pointee.sin6_scope_id = interface", SERVICE)
        self.assertIn("NI_NUMERICHOST", SERVICE)
        self.assertIn("sa_len) >= size", SERVICE)
        self.assertIn("TXTRecordGetCount", SERVICE)
        self.assertIn("TXTRecordGetItemAtIndex", SERVICE)
        self.assertIn("UInt16(exactly: data.count)", SERVICE)
        for path in ("BrowserController+Sources.m", "BonjourPublisher.m", "DCMNetServiceDelegate.m"):
            self.assertIn("[HorosBonjourService dictionaryFromTXTRecordData:", (SOURCES / path).read_text())


@unittest.skipUnless(sys.platform == "darwin", "Uses macOS socket and DNS-SD APIs")
class NativeResolutionValueTests(unittest.TestCase):
    def setUp(self):
        self.api = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.api.TXTRecordGetCount.argtypes = [ctypes.c_uint16, ctypes.c_void_p]
        self.api.TXTRecordGetCount.restype = ctypes.c_uint16
        self.api.TXTRecordGetItemAtIndex.argtypes = [ctypes.c_uint16, ctypes.c_void_p, ctypes.c_uint16,
                                                    ctypes.c_uint16, ctypes.c_void_p,
                                                    ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_void_p)]
        self.api.TXTRecordGetItemAtIndex.restype = ctypes.c_int32

    def test_native_txt_parser_preserves_binary_empty_and_flag_values(self):
        wire = b"\x07UID=a=b\x06CGET=1\x05bin=\xff\x04flag\x06empty="
        buffer = ctypes.create_string_buffer(wire)
        parsed = {}
        count = self.api.TXTRecordGetCount(len(wire), buffer)
        for index in range(count):
            key = ctypes.create_string_buffer(256)
            length, value = ctypes.c_uint8(), ctypes.c_void_p()
            error = self.api.TXTRecordGetItemAtIndex(len(wire), buffer, index, len(key), key,
                                                   ctypes.byref(length), ctypes.byref(value))
            self.assertEqual(error, 0)
            parsed[key.value] = ctypes.string_at(value, length.value) if value else b""
        self.assertEqual(parsed, {b"UID": b"a=b", b"CGET": b"1", b"bin": b"\xff", b"flag": b"", b"empty": b""})

    def test_truncated_txt_item_is_rejected(self):
        wire = ctypes.create_string_buffer(b"\x08A=x")
        key, length, value = ctypes.create_string_buffer(256), ctypes.c_uint8(), ctypes.c_void_p()
        self.assertNotEqual(self.api.TXTRecordGetItemAtIndex(4, wire, 0, len(key), key,
                                                           ctypes.byref(length), ctypes.byref(value)), 0)

    def test_numeric_ipv6_rendering_keeps_zone_without_dns_lookup(self):
        class Address6(ctypes.Structure):
            _fields_ = [("length", ctypes.c_uint8), ("family", ctypes.c_uint8), ("port", ctypes.c_uint16),
                        ("flow", ctypes.c_uint32), ("address", ctypes.c_ubyte * 16), ("scope", ctypes.c_uint32)]

        address = Address6()
        address.length = ctypes.sizeof(address)
        address.family = socket.AF_INET6
        address.address = (ctypes.c_ubyte * 16).from_buffer_copy(socket.inet_pton(socket.AF_INET6, "fe80::1234"))
        address.scope = socket.if_nametoindex("lo0")
        host = ctypes.create_string_buffer(1025)
        self.api.getnameinfo.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                                        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int]
        self.api.getnameinfo.restype = ctypes.c_int
        self.assertEqual(self.api.getnameinfo(ctypes.byref(address), ctypes.sizeof(address), host, len(host),
                                             None, 0, socket.NI_NUMERICHOST), 0)
        self.assertEqual(host.value, b"fe80::1234%lo0")


if __name__ == "__main__":
    unittest.main()
