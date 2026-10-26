@MainActor final class HorosActivityTaskCoordinator {
    static let shared = HorosActivityTaskCoordinator()
    func updateActivityDockIcon() {}
}

@main
@MainActor
private struct ActivityPeerTests {
    private struct RetainedPeer: @unchecked Sendable {
        // The cancelled BlockOperation is retained but never executed.
        let value: HorosDatabasePeer
    }

    static func main() throws {
        // Never start the connection: this fixture opens no sockets.
        let connection = NWConnection(host: "localhost", port: 9, using: .tcp)
        let peer = HorosDatabasePeer(connection: connection)
        let retained = RetainedPeer(value: peer)
        let operation = BlockOperation { retained.value.cancel() }
        precondition(HorosActivityToken.hasActiveOperations)
        operation.cancel()
        peer.cancel()
        precondition(!HorosActivityToken.hasActiveOperations)
        peer.cancel()
        precondition(!HorosActivityToken.hasActiveOperations)
        do {
            try peer.start()
            preconditionFailure("A cancelled peer was started")
        } catch let error as URLError {
            precondition(error.code == .cancelled)
        }
        withExtendedLifetime(operation) {
            precondition(!HorosActivityToken.hasActiveOperations)
        }
        print("Cancelled queued peer stops activity without executing or releasing its worker")
    }
}
