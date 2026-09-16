import Foundation
import Network

@objc protocol HorosDatabaseServerDelegate: AnyObject {
    func databaseServerDidStart(_ server: HorosDatabaseServer)
    func databaseServer(_ server: HorosDatabaseServer, didFail error: NSError)
}

/// Owns the listener on the main queue; protocol handlers run on bounded workers.
@objc(HorosDatabaseServer)
final class HorosDatabaseServer: NSObject {
    @objc weak var delegate: HorosDatabaseServerDelegate?
    @objc private(set) var port = 0
    private let requestedPort: NWEndpoint.Port
    private let handler: (HorosDatabasePeer) -> Void
    private var listener: NWListener?
    private var peers: [UUID: HorosDatabasePeer] = [:]
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.horosproject.database-server-workers"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()

    @objc(initWithPort:handler:)
    init(port: UInt16, handler: @escaping (HorosDatabasePeer) -> Void) {
        requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.handler = handler
        super.init()
    }

    @objc func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: requestedPort)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = Int(listener.port?.rawValue ?? 0)
                    self.delegate?.databaseServerDidStart(self)
                case .waiting(let error):
                    self.port = 0
                    self.delegate?.databaseServer(self, didFail: error as NSError)
                case .failed(let error):
                    self.stop()
                    self.delegate?.databaseServer(self, didFail: error as NSError)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: .main)
        } catch {
            delegate?.databaseServer(self, didFail: error as NSError)
        }
    }

    @objc func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = 0
        workers.cancelAllOperations()
        for peer in peers.values { peer.cancel() }
        peers.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        // Limit accepted and queued requests as well as actively executing workers.
        guard peers.count < 32 else {
            connection.cancel()
            return
        }
        let identifier = UUID()
        let peer = HorosDatabasePeer(connection: connection)
        peers[identifier] = peer
        let handler = handler
        workers.addOperation { [weak self] in
            autoreleasepool {
                defer {
                    peer.cancel()
                    DispatchQueue.main.async { [weak self] in
                        self?.peers.removeValue(forKey: identifier)
                    }
                }
                do {
                    try peer.start()
                    handler(peer)
                } catch {
                    NSLog("Shared-database connection from %@ failed: %@", peer.address, error as NSError)
                }
            }
        }
    }

    deinit {
        listener?.cancel()
        workers.cancelAllOperations()
        for peer in peers.values { peer.cancel() }
    }
}

/// Synchronous protocol access stays on one worker; callbacks never run that handler.
@objc(HorosDatabasePeer)
final class HorosDatabasePeer: NSObject {
    @objc let address: String
    private static let networkQueue = DispatchQueue(label: "org.horosproject.database-server-io")
    private static let chunkSize = 128 * 1024
    private static let idleTimeout: TimeInterval = 45
    private let connection: NWConnection
    private let condition = NSCondition()
    // Callback state is protected by condition; there is only one protocol consumer.
    private var failure: Error?
    private var ready = false
    private var sent = false
    private var received: (Data?, Bool)?
    private var remoteFinished = false

    fileprivate init(connection: NWConnection) {
        self.connection = connection
        if case .hostPort(let host, _) = connection.endpoint {
            address = String(describing: host)
        } else {
            address = String(describing: connection.endpoint)
        }
        super.init()
    }

    fileprivate func start() throws {
        condition.lock()
        let cancelled = failure != nil
        condition.unlock()
        guard !cancelled else { throw URLError(.cancelled) }
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
        connection.start(queue: Self.networkQueue)
        _ = try wait { ready ? true : nil }
    }

    @objc(receiveDataWithError:)
    func receiveData() throws -> Data {
        if remoteFinished { return Data() }
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
        let (data, complete) = try wait { received }
        remoteFinished = complete
        if let data, !data.isEmpty { return data }
        guard complete else { throw URLError(.networkConnectionLost) }
        return Data()
    }

    @objc(writeData:error:)
    func writeData(_ data: Data) throws {
        for offset in stride(from: 0, to: data.count, by: Self.chunkSize) {
            try autoreleasepool {
                let end = min(offset + Self.chunkSize, data.count)
                try send(data.subdata(in: offset..<end), final: false)
            }
        }
    }

    @objc(finishWithError:)
    func finish() throws {
        try send(nil, final: true)
    }

    private func send(_ data: Data?, final: Bool) throws {
        condition.lock()
        sent = false
        condition.unlock()
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.condition.lock()
            if let error { self.failure = error }
            self.sent = true
            self.condition.broadcast()
            self.condition.unlock()
        })
        // Wait for processed chunks, not a protocol-level acknowledgment per image.
        _ = try wait { sent ? true : nil }
    }

    fileprivate func cancel() {
        condition.lock()
        failure = URLError(.cancelled)
        condition.broadcast()
        condition.unlock()
        connection.cancel()
    }

    private func wait<Value>(_ result: () -> Value?) throws -> Value {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.idleTimeout
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let failure { throw failure }
            if let value = result() { return value }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 1)))
        }
    }
}
