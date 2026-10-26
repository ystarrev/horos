"""Exercise the production token registry without starting AppKit or building Horos."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


class ActivityTests(unittest.TestCase):
    def interpret(self, source, name):
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="horos-activity-test-") as directory:
            path = Path(directory) / (name + ".swift")
            path.write_text(source)
            subprocess.run([swift, "-Xfrontend", "-parse-as-library", "-swift-version", "5",
                            "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
                            "-module-cache-path", "/tmp/horos-frame-module-cache", str(path)],
                           check=True, timeout=60)

    def test_token_lifecycle(self):
        source = (SOURCES / "HorosActivityTaskCoordinator.swift").read_text()
        token = source.split("@objc(HorosActivityTask)\n", 1)[0]
        token = token.replace("import AppKit", "import Foundation")
        harness = r'''
@MainActor final class HorosActivityTaskCoordinator {
    static let shared = HorosActivityTaskCoordinator()
    func updateActivityDockIcon() {}
}
@main struct Test {
    static func main() {
        precondition(!HorosActivityToken.hasActiveOperations)
        let first = HorosActivityToken.begin()
        let second = HorosActivityToken.begin()
        first.stop()
        first.stop()
        precondition(HorosActivityToken.hasActiveOperations)
        second.stop()
        precondition(!HorosActivityToken.hasActiveOperations)

        var abandoned: HorosActivityToken? = HorosActivityToken.begin()
        precondition(abandoned != nil && HorosActivityToken.hasActiveOperations)
        abandoned = nil
        precondition(!HorosActivityToken.hasActiveOperations)

        enum Failure: Error { case failed }
        func failedRequest() throws {
            let token = HorosActivityToken.begin()
            defer { token.stop() }
            throw Failure.failed
        }
        do { try failedRequest(); preconditionFailure() } catch {}
        precondition(!HorosActivityToken.hasActiveOperations)

        let pending = HorosActivityToken.begin()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            let token = HorosActivityToken.begin()
            precondition(HorosActivityToken.hasActiveOperations)
            token.stop()
            token.stop()
        }
        precondition(HorosActivityToken.hasActiveOperations)
        pending.stop()
        precondition(!HorosActivityToken.hasActiveOperations)
        print("Token lifecycle, overlap, duplicate stop, deinit, error and concurrency checks passed")
    }
}
'''
        self.interpret(token + harness, "ActivityTest")

    def test_icon_lifecycle_and_stale_callbacks(self):
        source = (SOURCES / "HorosActivityTaskCoordinator.swift").read_text()
        source = source.replace("import AppKit", "import Foundation\nimport CoreGraphics")
        # Exercise the actual coordinator with a fake Dock. Only rasterization
        # is replaced, so the fixture never creates an app or changes its icon.
        source = source.split("    private static func prepareDockIcon(", 1)[0] + r'''
    private static func prepareDockIcon(_ image: NSImage?, size: NSSize, scale: CGFloat) -> NSImage? {
        MockDock.prepareCount += 1
        let callback = MockDock.onPrepare
        MockDock.onPrepare = nil
        callback?()
        return image.map { NSImage(name: $0.name, size: size, scale: scale) }
    }
}
'''
        fixture = (ROOT / "Scripts/tests/HorosActivityIconTests.swift").read_text()
        self.interpret(source + fixture, "ActivityIconTest")

    def test_cancelled_peer_stops_even_while_operation_is_retained(self):
        token = (SOURCES / "HorosActivityTaskCoordinator.swift").read_text().split("@objc(HorosActivityTask)\n", 1)[0]
        token = token.replace("import AppKit", "import Foundation")
        server = (SOURCES / "HorosDatabaseServer.swift").read_text()
        fixture = (ROOT / "Scripts/tests/HorosActivityPeerTests.swift").read_text()
        self.interpret(token + server + fixture, "ActivityPeerTest")

    def test_icon_not_driven_by_task_list(self):
        source = (SOURCES / "HorosActivityTaskCoordinator.swift").read_text()
        self.assertNotIn("activities.values.contains", source)
        self.assertIn("if !HorosActivityToken.hasActiveOperations", source)
        self.assertIn("RunLoop.main.perform(inModes: [.common])", source)
        self.assertIn("dockIconTimer?.invalidate()", source)
        self.assertIn("guard timer === dockIconTimer", source)
        stop = source.split("if !HorosActivityToken.hasActiveOperations {", 1)[1].split("guard dockIconTimer == nil", 1)[0]
        self.assertIn("if let icon = preparedRegularDockIcon", stop)
        self.assertNotIn("preparedRegularDockIcon = nil", stop)
        self.assertNotIn("preparedActivityDockIcon = nil", stop)
        self.assertNotIn("NSApplication.shared.applicationIconImage = nil", source)
        self.assertNotIn("regularDockIcon = NSApplication.shared.applicationIconImage", source)

    def test_network_entry_points_are_scoped(self):
        for filename in ("DCMTKQueryNode.mm", "DCMTKStoreSCU.mm", "DCMTKVerifySCU.mm"):
            self.assertIn("HorosActivityScope activity;", (SOURCES / filename).read_text())
        for filename in ("HorosDatabaseTransport.swift", "HorosDirectTransfer.swift"):
            self.assertIn("defer { activity.stop() }", (SOURCES / filename).read_text())
        server = (SOURCES / "HorosQueryRetrieveServer.cpp").read_text()
        acceptor = server.split("OFCondition HorosQueryRetrieveServer::waitForAssociation", 1)[1]
        self.assertLess(acceptor.index("if (!ASC_associationWaiting"),
                        acceptor.index("HorosActivityScope activity;"))
        self.assertIn("if (finished) HorosEndActivity(process.activity)", server)
        scope = (SOURCES / "HorosActivityScope.h").read_text()
        self.assertIn("~HorosActivityScope() { HorosEndActivity(token_); }", scope)


if __name__ == "__main__":
    unittest.main()
