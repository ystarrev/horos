"""Exercise the production token registry without starting AppKit or building Horos."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources"


class ActivityTests(unittest.TestCase):
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
        swift = subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="horos-activity-test-") as directory:
            path = Path(directory) / "ActivityTest.swift"
            path.write_text(token + harness)
            subprocess.run([swift, "-interpret", "-parse-as-library", "-swift-version", "5",
                            "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
                            "-module-cache-path", "/tmp/horos-frame-module-cache", str(path)],
                           check=True, timeout=60)

    def test_icon_not_driven_by_task_list(self):
        source = (SOURCES / "HorosActivityTaskCoordinator.swift").read_text()
        self.assertNotIn("activities.values.contains", source)
        self.assertIn("if !HorosActivityToken.hasActiveOperations", source)
        self.assertIn("RunLoop.main.perform(inModes: [.common])", source)
        self.assertIn("dockIconTimer?.invalidate()", source)

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
