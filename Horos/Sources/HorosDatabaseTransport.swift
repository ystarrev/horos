import Foundation
import Network

/// The shared-database protocol ends each response by closing its TCP connection.
@objc(HorosDatabaseTransport)
final class HorosDatabaseTransport: NSObject {
    typealias Receiver = (Data?, AutoreleasingUnsafeMutablePointer<NSError?>) -> Int

    @objc(sendRequest:toHost:port:receiving:cancelled:error:)
    static func sendRequest(_ request: Data, toHost host: String, port: Int,
                            receiving: Receiver?, cancelled: @escaping () -> Bool) throws -> Data {
        guard !host.isEmpty, let number = UInt16(exactly: port), number != 0,
              let endpointPort = NWEndpoint.Port(rawValue: number) else {
            throw transportError("Invalid shared-database address or port.")
        }
        let session = Session(host: host, port: endpointPort, cancelled: cancelled)
        defer { session.connection.cancel() }
        try session.start()
        try session.send(request)

        // A streaming consumer runs on the calling thread, never the network queue.
        // Only its unconsumed header bytes survive into the next receive operation.
        var buffer = Data()
        while true {
            let finished = try autoreleasepool {
                let (data, complete) = try session.receive()
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let receiving {
                        let count = try consume(buffer, using: receiving)
                        buffer.removeFirst(count)
                        guard buffer.count <= Session.chunkSize else {
                            throw transportError("The shared-database response contains an oversized header.")
                        }
                    }
                }
                if complete {
                    if let receiving {
                        guard buffer.isEmpty else {
                            throw transportError("The shared-database response ended inside a header.")
                        }
                        _ = try consume(nil, using: receiving)
                    }
                    return true
                }
                guard let data, !data.isEmpty else {
                    throw transportError("The shared-database connection returned no data before completion.")
                }
                return false
            }
            if finished { return buffer }
        }
    }

    private static func consume(_ data: Data?, using receiver: Receiver) throws -> Int {
        var error: NSError?
        let count = receiver(data, &error)
        if let error { throw error }
        guard count >= 0, count <= (data?.count ?? 0) else {
            throw transportError("Invalid shared-database response consumption.")
        }
        return count
    }

    fileprivate static func transportError(_ description: String) -> NSError {
        NSError(domain: "HorosDatabaseTransport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private final class Session {
        static let chunkSize = 128 * 1024
        private static let queue = DispatchQueue(label: "org.horosproject.database-client")
        private static let idleTimeout: TimeInterval = 45

        let connection: NWConnection
        private let cancelled: () -> Bool
        private let condition = NSCondition()
        // All callback state below is protected by condition.
        private var ready = false
        private var sent = false
        private var received: (Data?, Bool)?
        private var failure: Error?

        init(host: String, port: NWEndpoint.Port, cancelled: @escaping () -> Bool) {
            self.cancelled = cancelled
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: nil, tcp: tcp))
        }

        func start() throws {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.condition.lock()
                defer { self.condition.unlock() }
                switch state {
                case .ready: self.ready = true
                case .failed(let error): self.failure = error
                case .cancelled: self.failure = URLError(.cancelled)
                default: break
                }
                self.condition.broadcast()
            }
            connection.start(queue: Self.queue)
            _ = try wait { ready ? true : nil }
        }

        func send(_ data: Data) throws {
            for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
                condition.lock()
                sent = false
                condition.unlock()
                let end = min(data.count, offset + Self.chunkSize)
                connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.condition.lock()
                    if let error { self.failure = error }
                    self.sent = true
                    self.condition.broadcast()
                    self.condition.unlock()
                })
                // Bound in-flight data without adding application-level acknowledgments.
                _ = try wait { sent ? true : nil }
            }
        }

        func receive() throws -> (Data?, Bool) {
            condition.lock()
            received = nil
            condition.unlock()
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, complete, error in
                guard let self else { return }
                self.condition.lock()
                if let error { self.failure = error }
                self.received = (data, complete)
                self.condition.broadcast()
                self.condition.unlock()
            }
            return try wait { received }
        }

        private func wait<Value>(_ result: () -> Value?) throws -> Value {
            let deadline = ProcessInfo.processInfo.systemUptime + Self.idleTimeout
            while true {
                if cancelled() { throw URLError(.cancelled) }
                condition.lock()
                defer { condition.unlock() }
                if let failure { throw failure }
                if let value = result() { return value }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw URLError(.timedOut)
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
    }
}
