"""Shared-database server source contracts and SDK syntax checks, without a build.

These do not open sockets, access a patient database, or replace live-peer tests.
"""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"
SERVER = (SOURCES / "HorosDatabaseServer.swift").read_text()
PARSER = (SOURCES / "BonjourPublisher.m").read_text()
HEADER = (SOURCES / "BonjourPublisher.h").read_text()
PROJECT = (ROOT / "Horos.xcodeproj/project.pbxproj").read_text()


class DatabaseServerTests(unittest.TestCase):
    def test_server_replaces_streams_without_changing_port_or_handler_commands(self):
        self.assertIn("NWListener(using: parameters, on: requestedPort)", SERVER)
        self.assertIn("NWParameters(tls: nil, tcp: tcp)", SERVER)
        self.assertIn("initWithPort:8780 handler:", PARSER)
        self.assertIn("@interface O2DatabaseConnection : NSObject", PARSER)
        for command in ("DATAB", "DBSIZ", "GETDI", "VERSI", "DBVER", "ISPWD", "PASWD",
                        "SENDD", "SENDG", "NEWMS", "ADDAL", "REMAL", "SETVA", "MFILE", "DCMSE", "DICOM"):
            self.assertIn(f'strcmp(command, "{command}")', PARSER)
        for old in ("N2Connection", "NSInputStream", "NSOutputStream", "CFSocket", "closeWhenDoneSending"):
            self.assertNotIn(old, SERVER + PARSER + HEADER)

    def test_advertisement_waits_for_listener_readiness(self):
        ready = SERVER.split("case .ready:", 1)[1].split("case .waiting", 1)[0]
        self.assertLess(ready.index("self.port ="), ready.index("databaseServerDidStart(self)"))
        self.assertIn("self.listener === listener", SERVER)
        self.assertIn("listener.start(queue: .main)", SERVER)
        self.assertIn("if (!_listener || !_listener.port)", PARSER)
        self.assertIn("if (server != _listener) return;", PARSER)
        self.assertIn("[self updateBonjour];", PARSER.split("didFail:(NSError*)error", 1)[1])

    def test_workers_are_bounded_and_handler_stays_off_network_queue(self):
        self.assertIn("queue.maxConcurrentOperationCount = 8", SERVER)
        self.assertIn("guard peers.count < 32", SERVER)
        work = SERVER.split("workers.addOperation", 1)[1].split("deinit", 1)[0]
        self.assertLess(work.index("try peer.start()"), work.index("handler(peer)"))
        self.assertIn("defer {\n                    peer.cancel()", work)
        self.assertIn("DispatchQueue.main.async", work)
        callbacks = SERVER.split("fileprivate func start() throws", 1)[1].split("fileprivate func cancel", 1)[0]
        self.assertNotIn("handler(", callbacks)
        self.assertEqual(callbacks.count("self.condition.lock()"), 3)
        self.assertEqual(callbacks.count("self.condition.broadcast()"), 3)
        self.assertIn("Incomplete shared-database request", PARSER)
        self.assertIn("@catch (NSException* exception)", PARSER.split("- (void)run {", 1)[1])

    def test_stop_cancels_pending_and_active_connections(self):
        stop = SERVER.split("@objc func stop()", 1)[1].split("private func accept", 1)[0]
        for token in ("listener?.stateUpdateHandler = nil", "listener?.newConnectionHandler = nil",
                      "listener?.cancel()", "listener = nil", "port = 0", "workers.cancelAllOperations()",
                      "for peer in peers.values { peer.cancel() }", "peers.removeAll()"):
            self.assertIn(token, stop)
        cancel = SERVER.split("fileprivate func cancel()", 1)[1].split("private func wait", 1)[0]
        self.assertLess(cancel.index("condition.broadcast()"), cancel.index("connection.cancel()"))
        self.assertIn("failure = URLError(.cancelled)", cancel)
        self.assertIn("systemUptime + Self.idleTimeout", SERVER)
        self.assertIn("throw URLError(.timedOut)", SERVER)
        self.assertNotIn("DISPATCH_TIME_FOREVER", SERVER)
        toggle = PARSER.split("if (!activate && _listener)", 1)[1].split("[self updateBonjour]", 1)[0]
        self.assertLess(toggle.index("[_listener stop]"), toggle.index("[_listener release]"))

    def test_sends_are_chunked_and_finish_sends_fin_after_payload(self):
        self.assertIn("chunkSize = 128 * 1024", SERVER)
        self.assertIn("maximumLength: Self.chunkSize", SERVER)
        self.assertIn("data.subdata(in: offset..<end)", SERVER)
        self.assertIn("completion: .contentProcessed", SERVER)
        self.assertIn("try wait { sent ? true : nil }", SERVER)
        self.assertIn("try send(nil, final: true)", SERVER)
        self.assertIn("final ? .finalMessage : .defaultMessage", SERVER)
        run = PARSER.split("- (void)run {", 1)[1].split("- (NSUInteger)availableSize", 1)[0]
        self.assertLess(run.index("[self handleData:_readBuffer]"), run.index("[_peer finishWithError:"))
        self.assertIn("if (_mode == NONE && !_readBuffer.length) return;", run)

    def test_parser_preserves_fragment_state_and_rejects_invalid_frames(self):
        self.assertIn("[_readBuffer appendData:data]", PARSER)
        self.assertIn("_hdi = 0", PARSER)
        self.assertIn("if ([e.name isEqualToString:O2NotEnoughData])", PARSER)
        self.assertIn("command[5] != '\\0'", PARSER)
        self.assertIn("if (size < 0)", PARSER)
        self.assertIn("if (value < 0)", PARSER)
        self.assertIn("length < 0 || length > INT_MAX - 4", PARSER)
        self.assertIn("bytes[length-1] != '\\0'", PARSER)
        self.assertIn("initWithBytes:bytes length:length-1 encoding:NSUTF8StringEncoding", PARSER)
        # A null SETVA value is part of the existing wire protocol, distinct from "".
        self.assertIn("if (!length) return nil;", PARSER)
        self.assertIn("[self _stackObject:value ?: NSNull.null]", PARSER)
        self.assertIn("return value == NSNull.null ? nil : value", PARSER)

    def test_existing_wire_encodings_and_password_commands_remain(self):
        for token in ("NSSwapBigIntToHost", "NSSwapHostIntToBig", "NSSwapHostDoubleToBig",
                      "HorosArchiveUnkeyedObject(dictionary)", "NSUserDefaults.bonjourSharingPassword",
                      "NSUnicodeStringEncoding", "strlen( string)+1", "_mode == SENDG"):
            self.assertIn(token, PARSER)
        self.assertNotIn("HorosDirectTransfer", SERVER + PARSER)

    def test_project_membership_and_legacy_removal(self):
        entries = re.findall(r"(\w+) /\* HorosDatabaseServer.swift in Sources \*/ = .*fileRef = (\w+)", PROJECT)
        self.assertEqual(len(entries), 1)
        build_id, file_id = entries[0]
        self.assertEqual(PROJECT.count(build_id + " /* HorosDatabaseServer.swift in Sources */"), 2)
        self.assertEqual(PROJECT.count(file_id + " /* HorosDatabaseServer.swift */"), 3)
        for project in (PROJECT, (ROOT / "Nitrogen/Nitrogen.xcodeproj/project.pbxproj").read_text()):
            self.assertNotIn("N2Connection", project)
        for name in ("N2Connection.h", "N2Connection.mm", "N2ConnectionListener.h", "N2ConnectionListener.mm"):
            self.assertFalse((ROOT / "Nitrogen/Sources" / name).exists())

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Requires the macOS SDK")
    def test_swift_and_objc_bridge_pass_sdk_checks_without_building(self):
        with tempfile.TemporaryDirectory(prefix="horos-server-check-") as folder:
            folder = Path(folder)
            swift_header = folder / "Server-Swift.h"
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-module-name", "ServerCheck", "-module-cache-path", str(folder / "cache"),
                "-emit-objc-header-path", str(swift_header), str(SOURCES / "HorosDatabaseServer.swift"),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            declarations = swift_header.read_text()
            for selector in ("receiveDataWithError:", "writeData:", "finishWithError:", "initWithPort:"):
                self.assertIn(selector, declarations)
            # Check the actual Objective-C implementation with app-only declarations
            # stubbed, using the real SDK and the generated Swift interface.
            source = folder / "Publisher.m"
            source.write_text(SDK_STUBS + '\n#import "Server-Swift.h"\n' +
                              re.sub(r'^#import .*$', '', HEADER, flags=re.M) + '\n' +
                              re.sub(r'^#import .*$', '', PARSER, flags=re.M))
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            result = subprocess.run([
                "xcrun", "clang", "-fsyntax-only", "-fblocks", "-fno-objc-arc",
                "-target", "arm64-apple-macos27.0", "-isysroot", sdk,
                "-Werror", "-Wno-switch", "-Wno-incompatible-pointer-types",
                str(source),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


SDK_STUBS = r'''
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
extern NSString *CurrentDatabaseVersion;
extern NSString *OsirixBonjourSharingIsActiveDefaultsKey;
extern NSString *OsirixBonjourSharingNameDefaultsKey;
extern NSString *OsirixBonjourSharingIsPasswordProtectedDefaultsKey;
extern NSString *OsirixBonjourSharingPasswordDefaultsKey;
extern void N2LogExceptionWithStackTrace(NSException*);
extern void N2PerformManagedObjectContextBlockAndWait(NSManagedObjectContext*, void (^)(void));
extern NSData* HorosArchiveUnkeyedObject(id);
@interface NSUserDefaults (Sharing)
+ (BOOL)bonjourSharingIsActive;
+ (NSString*)bonjourSharingName;
+ (NSString*)bonjourSharingPassword;
@end
@interface NSUserDefaultsController (Sharing)
- (void)addObserver:(NSObject*)observer forValuesKey:(NSString*)key options:(NSKeyValueObservingOptions)options context:(void*)context;
- (void)removeObserver:(NSObject*)observer forValuesKey:(NSString*)key;
@end
@interface DicomDatabase : NSObject
@property(readonly) NSManagedObjectContext* managedObjectContext;
+ (instancetype)defaultDatabase;
- (instancetype)independentDatabase;
- (NSString*)sqlFilePath;
- (NSString*)baseDirPath;
- (NSString*)reportsDirPath;
- (NSString*)uniquePathForNewDataFileWithExtension:(NSString*)extension;
- (void)save;
- (BOOL)save:(NSError**)error;
- (NSTimeInterval)timeOfLastModification;
- (id)objectWithID:(id)objectID;
- (NSArray*)objectsWithIDs:(NSArray*)objectIDs;
- (NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)post dicomOnly:(BOOL)dicom rereadExistingItems:(BOOL)reread generatedByOsiriX:(BOOL)generated;
@end
@interface DicomStudy : NSManagedObject
- (void)archiveAnnotationsAsDICOMSR;
@end
@interface DicomImage : NSManagedObject
@property(readonly) NSNumber* pathNumber;
@end
@interface DicomAlbum : NSManagedObject
@end
@interface BrowserController : NSObject
+ (instancetype)currentBrowser;
+ (int)DefaultFolderSizeForDB;
- (DicomDatabase*)database;
- (void)refreshDatabase:(id)sender;
@end
@class BonjourPublisher;
@interface AppController : NSObject
+ (instancetype)sharedAppController;
+ (NSString*)UID;
- (BonjourPublisher*)bonjourPublisher;
@end
@interface HorosBonjourAdvertisement : NSObject
@property(readonly) NSInteger port;
- (instancetype)initWithName:(NSString*)name type:(NSString*)type port:(NSInteger)port;
- (void)stop;
- (void)publishWithTXTRecord:(NSDictionary*)record;
@end
@interface HorosBonjourService : NSObject
+ (NSDictionary*)dictionaryFromTXTRecordData:(NSData*)data;
@end
@interface DCMTKStoreSCU : NSObject
+ (int)sendSyntaxForListenerSyntax:(NSInteger)syntax;
- (instancetype)initWithCallingAET:(NSString*)calling calledAET:(NSString*)called hostname:(NSString*)host port:(int)port filesToSend:(NSArray*)files transferSyntax:(int)syntax compression:(int)compression extraParameters:(NSDictionary*)parameters;
- (void)run:(id)sender;
@end
'''


if __name__ == "__main__":
    unittest.main()
