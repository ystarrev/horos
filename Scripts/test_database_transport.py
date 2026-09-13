"""Shared-database client source contracts; live peer behavior needs app testing."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
TRANSPORT = (SOURCES / "HorosDatabaseTransport.swift").read_text()
CLIENT = (SOURCES / "RemoteDicomDatabase.mm").read_text()
SERVER = (SOURCES / "BonjourPublisher.m").read_text()


class DatabaseTransportTests(unittest.TestCase):
    def test_application_requests_no_longer_use_stream_client(self):
        for path in SOURCES.iterdir():
            if path.suffix in (".m", ".mm", ".swift"):
                self.assertNotIn("[N2Connection sendSynchronousRequest:", path.read_text(), str(path))
        self.assertIn("HorosSendDatabaseRequest(request, self.address, self.port, handler)", CLIENT)
        self.assertIn("HorosSendDatabaseRequest(request, address, port, nil)", CLIENT)
        self.assertNotIn('"N2Connection.h"', CLIENT)
        self.assertIn("NWConnection(host:", TRANSPORT)
        self.assertNotIn("NSStream", TRANSPORT)
        self.assertNotIn("RunLoop", TRANSPORT)

    def test_protocol_keeps_existing_commands_lengths_and_byte_order(self):
        for command in ("DBVER", "ISPWD", "PASWD", "DBSIZ", "DATAB", "VERSI", "GETDI", "DICOM"):
            self.assertIn(f'WithBytes:"{command}" length:6', CLIENT)
        self.assertIn("NSSwapHostIntToBig(i)", CLIENT)
        self.assertIn("NSSwapBigIntToHost(big)", CLIENT)
        self.assertIn("NSSwapBigDoubleToHost", CLIENT)
        self.assertIn("HorosUnarchiveUnkeyedObject(response)", CLIENT)
        self.assertIn("strlen( string)+1", SERVER)
        self.assertIn("_mode = DONE", SERVER)

    def test_network_callbacks_only_publish_locked_state(self):
        callbacks = TRANSPORT.split("func start() throws", 1)[1].split("private func wait", 1)[0]
        self.assertEqual(callbacks.count("[weak self]"), 3)
        self.assertEqual(callbacks.count("self.condition.lock()"), 3)
        self.assertEqual(callbacks.count("self.condition.broadcast()"), 3)
        self.assertNotIn("consume(", callbacks)
        self.assertIn("let count = receiver(data, &error)", TRANSPORT)
        self.assertIn("@catch (NSException *exception)", CLIENT)
        self.assertIn("*handlerError = [NSError errorWithDomain:", CLIENT)

    def test_cancellation_timeout_and_cleanup_are_explicit(self):
        self.assertIn("defer { session.connection.cancel() }", TRANSPORT)
        self.assertIn("if cancelled() { throw URLError(.cancelled) }", TRANSPORT)
        self.assertIn("idleTimeout: TimeInterval = 45", TRANSPORT)
        self.assertIn("systemUptime < deadline", TRANSPORT)
        self.assertIn("throw URLError(.timedOut)", TRANSPORT)
        self.assertIn("timeIntervalSinceNow: 0.1", TRANSPORT)
        self.assertNotIn("DISPATCH_TIME_FOREVER", CLIENT)

    def test_no_automatic_replay_or_silent_failure(self):
        requests = CLIENT.split("#pragma mark Communication", 1)[1].split("+(void)_data:", 1)[0]
        self.assertNotIn("retries", requests)
        self.assertNotIn("@catch", requests)
        self.assertIn("@finally", requests)
        self.assertIn("if (!response)", CLIENT)
        self.assertIn("if let failure { throw failure }", TRANSPORT)

    def test_bounded_inflight_data_and_fragmented_headers(self):
        self.assertIn("chunkSize = 128 * 1024", TRANSPORT)
        self.assertIn("completion: .contentProcessed", TRANSPORT)
        self.assertIn("try wait { sent ? true : nil }", TRANSPORT)
        self.assertIn("maximumLength: Self.chunkSize", TRANSPORT)
        self.assertIn("let finished = try autoreleasepool", TRANSPORT)
        self.assertIn("buffer.removeFirst(count)", TRANSPORT)
        self.assertIn("count >= 0, count <= (data?.count ?? 0)", TRANSPORT)
        self.assertIn("guard buffer.count <= Session.chunkSize", TRANSPORT)

    def test_eof_validates_both_header_and_file_state(self):
        self.assertIn("guard buffer.isEmpty", TRANSPORT)
        self.assertIn("consume(nil, using: receiving)", TRANSPORT)
        parser = CLIENT.split("-(NSInteger)handleData_fetchDataForImage:", 2)[2]
        self.assertIn("state.unsignedIntegerValue != 1 || context.count != 3", parser)
        self.assertIn("!= expectedPaths.count", parser)
        self.assertIn("if (n != expectedPaths.count)", parser)
        self.assertIn("Unexpected data after the shared-database images.", parser)
        self.assertNotIn("[connection close]", parser)

    def test_download_destinations_are_bounded_and_expected(self):
        parser = CLIENT.split("-(NSInteger)handleData_fetchDataForImage:", 2)[2]
        self.assertIn("lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1", parser)
        self.assertIn("initWithBytes:pathBytes length:pathSize-1", parser)
        self.assertIn("pathBytes[pathSize-1] != '\\0'", parser)
        self.assertIn("![path isEqualToString:expectedPath]", parser)
        self.assertNotIn("stringWithUTF8String:", parser)
        self.assertIn("error:&moveError", parser)
        self.assertNotIn("removeItemAtPath:path", parser)
        self.assertIn("NSFileWriteFileExistsError", parser)

    def test_partial_downloads_are_removed_without_deleting_completed_images(self):
        download = CLIENT.split("- (NSString*)cacheDataForImage:", 1)[1].split("-(NSInteger)handleData_fetchDataForImage:", 1)[0]
        self.assertIn("@finally", download)
        self.assertIn("[[context objectAtIndex:5] close]", download)
        self.assertIn("removeItemAtPath:[context objectAtIndex:4]", download)
        self.assertNotIn("removeItemAtPath:localPath", download)
        index = CLIENT.split("- (NSString *)fetchDatabaseIndex", 1)[1].split("-(NSTimeInterval)fetchDatabaseTimestamp", 1)[0]
        self.assertIn("if (!completed)", index)
        self.assertIn("removeItemAtPath:path", index)
        self.assertIn("if (!data && !obtainedSize.unsignedIntegerValue)", index)
        self.assertIn("DBSIZ and DATAB are separate snapshots", index)
        self.assertNotIn("obtainedSize.unsignedIntegerValue != databaseIndexSize", index)

    def test_transport_belongs_to_application_target_once(self):
        project = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()
        definitions = re.findall(r"(\w+) /\* HorosDatabaseTransport.swift in Sources \*/ = .*fileRef = (\w+)", project)
        self.assertEqual(len(definitions), 1)
        build_id, file_id = definitions[0]
        self.assertEqual(project.count(build_id + " /* HorosDatabaseTransport.swift in Sources */"), 2)
        self.assertEqual(project.count(file_id + " /* HorosDatabaseTransport.swift */"), 3)


if __name__ == "__main__":
    unittest.main()
