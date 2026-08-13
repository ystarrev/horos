import Foundation
import Network

@objcMembers
@objc(HorosDirectTransferService)
public final class HorosDirectTransferService: NSObject {
    @objc(sharedService)
    public static let shared = HorosDirectTransferService()

    private var listeningPort: UInt16 = 0
    @objc public var port: Int { Int(stateQueue.sync { listeningPort }) }
    @objc public var isRunning: Bool { port != 0 }
    @objc public let token: String = UUID().uuidString

    private static let magic = Data("HOROSFT1".utf8)
    private static let protocolVersion: UInt32 = 1
    private static let chunkSize = 4 * 1_024 * 1_024
    private static let maximumFiles = 1_000_000
    private static let maximumFilenameBytes = 1_024
    private static let maximumFileBytes: UInt64 = 1 << 40
    private static let ioQueue = DispatchQueue(
        label: "org.horos.direct-transfer",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "org.horos.direct-transfer.listener")
    private var shouldRun = false

    public override init() {
        super.init()
    }

    private static func connectionParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    @objc public func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.startListenerIfNeeded()
        }
    }

    private func startListenerIfNeeded() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard shouldRun, listener == nil else { return }

        do {
            let listener = try NWListener(using: Self.connectionParameters(), on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.listeningPort = listener.port?.rawValue ?? 0
                    NSLog("Horos direct transfer receiver listening on port \(self.listeningPort)")
                case .failed(let error):
                    NSLog("Horos direct transfer receiver failed: %@", error.localizedDescription)
                    self.listener = nil
                    self.listeningPort = 0
                    self.stateQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.startListenerIfNeeded()
                    }
                case .cancelled:
                    self.listener = nil
                    self.listeningPort = 0
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: stateQueue)
        } catch {
            NSLog("Horos direct transfer receiver could not start: %@", error.localizedDescription)
            stateQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startListenerIfNeeded()
            }
        }
    }

    @objc public func stop() {
        stateQueue.async { [weak self] in
            self?.shouldRun = false
            self?.listener?.cancel()
            self?.listener = nil
            self?.listeningPort = 0
        }
    }

    @objc(sendFiles:toHost:port:token:activityThread:)
    public func send(files: [String], toHost host: String, port: Int, token: String, activityThread: Thread?) -> Bool {
        let uniqueFiles = NSOrderedSet(array: files).array.compactMap { $0 as? String }
        guard !uniqueFiles.isEmpty,
              !host.isEmpty,
              port > 0,
              port <= Int(UInt16.max),
              !token.isEmpty,
              token.utf8.count <= 256 else { return false }

        guard uniqueFiles.count <= Self.maximumFiles else { return false }

        var entries: [(url: URL, nameData: Data, size: UInt64)] = []
        entries.reserveCapacity(uniqueFiles.count)
        var totalBytes: UInt64 = 0

        do {
            for path in uniqueFiles {
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
                    throw DirectTransferError.invalidFile(path)
                }
                let nameData = url.lastPathComponent.data(using: .utf8) ?? Data()
                guard !nameData.isEmpty, nameData.count <= Self.maximumFilenameBytes else {
                    throw DirectTransferError.invalidFile(path)
                }
                let size = UInt64(fileSize)
                guard size <= Self.maximumFileBytes else { throw DirectTransferError.invalidFile(path) }
                let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
                guard !overflow else { throw DirectTransferError.invalidFile(path) }
                entries.append((url, nameData, size))
                totalBytes = newTotal
            }
        } catch {
            NSLog("Horos direct transfer could not prepare files: %@", error.localizedDescription)
            return false
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: Self.connectionParameters()
        )
        connection.start(queue: Self.ioQueue)
        let started = CFAbsoluteTimeGetCurrent()

        do {
            activityThread?.setStatus(NSLocalizedString("Connecting to Horos...", comment: ""))
            try waitUntilReady(connection, timeout: 8, thread: activityThread)

            var header = Data()
            header.append(Self.magic)
            header.appendNetwork(Self.protocolVersion)
            header.appendNetwork(UInt32(entries.count))
            header.appendNetwork(totalBytes)
            let tokenData = Data(token.utf8)
            header.appendNetwork(UInt32(tokenData.count))
            header.append(tokenData)
            try sendData(header, over: connection, thread: activityThread)

            var sentBytes: UInt64 = 0

            for (index, entry) in entries.enumerated() {
                if activityThread?.isCancelled == true { throw DirectTransferError.cancelled }

                var fileHeader = Data()
                fileHeader.appendNetwork(UInt32(entry.nameData.count))
                fileHeader.appendNetwork(entry.size)
                fileHeader.append(entry.nameData)
                try sendData(fileHeader, over: connection, thread: activityThread)

                let handle = try FileHandle(forReadingFrom: entry.url)
                do {
                    var remaining = entry.size
                    activityThread?.setStatus(String(
                        format: NSLocalizedString("Sending file %d of %d...", comment: ""),
                        index + 1,
                        entries.count
                    ))
                    while remaining > 0 {
                        if activityThread?.isCancelled == true { throw DirectTransferError.cancelled }
                        let requested = Int(min(UInt64(Self.chunkSize), remaining))
                        let data = try handle.read(upToCount: requested) ?? Data()
                        let readCount = data.count
                        guard readCount > 0 else { throw DirectTransferError.truncatedFile(entry.url.path) }
                        try sendData(data, over: connection, thread: activityThread)
                        remaining -= UInt64(readCount)
                        sentBytes += UInt64(readCount)
                        activityThread?.setProgress(totalBytes > 0 ? CGFloat(sentBytes) / CGFloat(totalBytes) : 1)
                    }
                } catch {
                    try? handle.close()
                    throw error
                }
                try handle.close()
            }

            let acknowledgement = try receiveExactly(4, from: connection, timeout: 30, thread: activityThread)
            guard acknowledgement.networkUInt32(at: 0) == 0 else {
                throw DirectTransferError.receiverRejected
            }

            connection.cancel()
            activityThread?.setProgress(1)
            activityThread?.setStatus(NSLocalizedString("Transfer complete", comment: ""))
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let mibps = elapsed > 0 ? Double(totalBytes) / (1_024 * 1_024) / elapsed : 0
            let mbps = elapsed > 0 ? Double(totalBytes) * 8 / 1_000_000 / elapsed : 0
            NSLog(String(
                format: "Horos direct transfer completed: %d files, %.1f MiB in %.2f s (%.1f MiB/s, %.1f Mbit/s)",
                entries.count,
                Double(totalBytes) / (1_024 * 1_024),
                elapsed,
                mibps,
                mbps
            ))
            return true
        } catch {
            connection.cancel()
            NSLog("Horos direct transfer failed: %@", error.localizedDescription)
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: Self.ioQueue)
        Self.ioQueue.async { [weak self] in
            self?.receiveBatch(over: connection)
        }
    }

    private func receiveBatch(over connection: NWConnection) {
        let fileManager = FileManager.default
        var stagingDirectory: URL?

        do {
            try waitUntilReady(connection, timeout: 8, thread: nil)
            let header = try receiveExactly(Self.magic.count + 20, from: connection, timeout: 30, thread: nil)
            guard header.prefix(Self.magic.count) == Self.magic else { throw DirectTransferError.invalidProtocol }
            let version = header.networkUInt32(at: Self.magic.count)
            let fileCount = Int(header.networkUInt32(at: Self.magic.count + 4))
            let declaredTotal = header.networkUInt64(at: Self.magic.count + 8)
            let tokenLength = Int(header.networkUInt32(at: Self.magic.count + 16))
            guard version == Self.protocolVersion,
                  fileCount > 0,
                  fileCount <= Self.maximumFiles,
                  tokenLength > 0,
                  tokenLength <= 256 else {
                throw DirectTransferError.invalidProtocol
            }
            let receivedToken = try receiveExactly(tokenLength, from: connection, timeout: 10, thread: nil)
            guard receivedToken == Data(token.utf8) else { throw DirectTransferError.unauthorized }

            guard let database = DicomDatabase.activeLocal() else {
                throw DirectTransferError.databaseUnavailable
            }
            let incomingURL = URL(fileURLWithPath: database.incomingDirPath(), isDirectory: true)
            let stagingRoot = URL(fileURLWithPath: database.tempDirPath(), isDirectory: true)
                .appendingPathComponent("Horos Direct Transfer", isDirectory: true)
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            removeAbandonedBatches(in: stagingRoot, fileManager: fileManager)
            let batchID = UUID().uuidString
            let batchURL = stagingRoot.appendingPathComponent(batchID, isDirectory: true)
            try fileManager.createDirectory(at: batchURL, withIntermediateDirectories: false)
            stagingDirectory = batchURL

            var receivedTotal: UInt64 = 0
            for index in 0..<fileCount {
                let fileHeader = try receiveExactly(12, from: connection, timeout: 30, thread: nil)
                let nameLength = Int(fileHeader.networkUInt32(at: 0))
                let fileSize = fileHeader.networkUInt64(at: 4)
                guard nameLength > 0,
                      nameLength <= Self.maximumFilenameBytes,
                      fileSize > 0,
                      fileSize <= Self.maximumFileBytes else {
                    throw DirectTransferError.invalidProtocol
                }

                let nameData = try receiveExactly(nameLength, from: connection, timeout: 30, thread: nil)
                guard let proposedName = String(data: nameData, encoding: .utf8) else {
                    throw DirectTransferError.invalidProtocol
                }
                let safeName = URL(fileURLWithPath: proposedName).lastPathComponent
                let destination = batchURL.appendingPathComponent(String(format: "%08d-%@", index, safeName))
                guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                    throw DirectTransferError.cannotCreateFile(destination.path)
                }
                let output = try FileHandle(forWritingTo: destination)
                do {
                    var remaining = fileSize
                    while remaining > 0 {
                        let length = Int(min(UInt64(Self.chunkSize), remaining))
                        let data = try receiveExactly(length, from: connection, timeout: 60, thread: nil)
                        try output.write(contentsOf: data)
                        remaining -= UInt64(data.count)
                        receivedTotal += UInt64(data.count)
                    }
                } catch {
                    try? output.close()
                    throw error
                }
                try output.close()
            }

            guard receivedTotal == declaredTotal, connection.state == .ready else {
                throw DirectTransferError.invalidProtocol
            }
            try fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: true)
            let completedBatch = incomingURL.appendingPathComponent(".HorosDirect-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: batchURL, to: completedBatch)
            stagingDirectory = completedBatch
            let visibleBatch = incomingURL.appendingPathComponent("HorosDirect-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: completedBatch, to: visibleBatch)
            stagingDirectory = nil
            database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()

            var acknowledgement = Data()
            acknowledgement.appendNetwork(UInt32(0))
            try sendData(acknowledgement, over: connection, thread: nil)
            connection.cancel()
            NSLog(String(
                format: "Horos direct transfer received: %d files, %.1f MiB",
                fileCount,
                Double(receivedTotal) / (1_024 * 1_024)
            ))
        } catch {
            if let stagingDirectory {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            connection.cancel()
            NSLog("Horos direct transfer receiver rejected a batch: %@", error.localizedDescription)
        }
    }

    private func removeAbandonedBatches(in root: URL, fileManager: FileManager) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private func waitUntilReady(_ connection: NWConnection, timeout: TimeInterval, thread: Thread?) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if thread?.isCancelled == true { throw DirectTransferError.cancelled }
            switch connection.state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw DirectTransferError.connectionClosed
            default:
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw DirectTransferError.timeout
    }

    private func sendData(
        _ data: Data,
        over connection: NWConnection,
        timeout: TimeInterval = 60,
        thread: Thread?
    ) throws {
        if thread?.isCancelled == true { throw DirectTransferError.cancelled }
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: NWError?
        let deadline = Date().addingTimeInterval(timeout)
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if thread?.isCancelled == true {
                connection.cancel()
                throw DirectTransferError.cancelled
            }
            guard Date() < deadline else {
                connection.cancel()
                throw DirectTransferError.timeout
            }
        }
        if let sendError { throw sendError }
    }

    private func receiveExactly(_ length: Int, from connection: NWConnection, timeout: TimeInterval, thread: Thread?) throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        let deadline = Date().addingTimeInterval(timeout)

        while result.count < length {
            if thread?.isCancelled == true { throw DirectTransferError.cancelled }
            guard Date() < deadline else { throw DirectTransferError.timeout }

            let semaphore = DispatchSemaphore(value: 0)
            var received: Data?
            var receiveError: NWError?
            var complete = false
            let remaining = length - result.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                received = data
                receiveError = error
                complete = isComplete
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                if thread?.isCancelled == true {
                    connection.cancel()
                    throw DirectTransferError.cancelled
                }
                guard Date() < deadline else {
                    connection.cancel()
                    throw DirectTransferError.timeout
                }
            }
            if let receiveError { throw receiveError }
            if let received, !received.isEmpty {
                result.append(received)
            } else if complete {
                throw DirectTransferError.connectionClosed
            }
        }
        return result
    }
}

private enum DirectTransferError: LocalizedError {
    case cancelled
    case cannotCreateFile(String)
    case connectionClosed
    case databaseUnavailable
    case invalidFile(String)
    case invalidProtocol
    case receiverRejected
    case timeout
    case truncatedFile(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Transfer cancelled"
        case .cannotCreateFile(let path): return "Cannot create \(path)"
        case .connectionClosed: return "Connection closed"
        case .databaseUnavailable: return "The receiving database is unavailable"
        case .invalidFile(let path): return "Cannot transfer \(path)"
        case .invalidProtocol: return "Invalid Horos transfer data"
        case .receiverRejected: return "The receiving Horos rejected the transfer"
        case .timeout: return "The Horos transfer timed out"
        case .truncatedFile(let path): return "File changed while being transferred: \(path)"
        case .unauthorized: return "The transfer was not authorized by the receiving Horos"
        }
    }
}

private extension Data {
    mutating func appendNetwork(_ value: UInt32) {
        var network = value.bigEndian
        Swift.withUnsafeBytes(of: &network) { append(contentsOf: $0) }
    }

    mutating func appendNetwork(_ value: UInt64) {
        var network = value.bigEndian
        Swift.withUnsafeBytes(of: &network) { append(contentsOf: $0) }
    }

    func networkUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    func networkUInt64(at offset: Int) -> UInt64 {
        subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }
}
