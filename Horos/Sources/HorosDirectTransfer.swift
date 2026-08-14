import Foundation
import Network

private struct HorosDirectFileEntry {
    let url: URL
    let nameData: Data
    let size: UInt64
}

private final class HorosDirectRemoteCapability {
    let host: String
    var dicomPort: Int
    var calledAET: String
    var directPort: Int
    var token: String
    var controlConnection: NWConnection?
    var isConnecting = false

    init(host: String, dicomPort: Int, calledAET: String, directPort: Int, token: String) {
        self.host = host
        self.dicomPort = dicomPort
        self.calledAET = calledAET
        self.directPort = directPort
        self.token = token
    }
}

private final class HorosDirectServerSession {
    let identifier: String
    let connection: NWConnection
    let name: String
    let aeTitle: String
    let dicomPort: Int
    let address: String
    let sendQueue: DispatchQueue

    init(identifier: String, connection: NWConnection, name: String, aeTitle: String, dicomPort: Int, address: String) {
        self.identifier = identifier
        self.connection = connection
        self.name = name
        self.aeTitle = aeTitle
        self.dicomPort = dicomPort
        self.address = address
        self.sendQueue = DispatchQueue(label: "org.horos.direct-transfer.session.\(identifier)")
    }
}

private enum HorosDirectSessionOperation: UInt32 {
    case checkIn = 1
}

private enum HorosDirectControlCommand: UInt32 {
    case retrieveItems = 1
    case ping = 2
}

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
    private static let sessionMagic = Data("HOROSFT2".utf8)
    private static let sessionProtocolVersion: UInt32 = 4
    private static let sessionConnectedNotification = Notification.Name("HorosDirectSessionDidConnect")
    private static let sessionDisconnectedNotification = Notification.Name("HorosDirectSessionDidDisconnect")
    private static let chunkSize = 4 * 1_024 * 1_024
    private static let streamBufferSize = chunkSize
    private static let bulkIOTimeout: TimeInterval = 90
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
    private var remoteCapabilities: [String: HorosDirectRemoteCapability] = [:]
    private var serverSessions: [String: HorosDirectServerSession] = [:]

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
            guard let self else { return }
            self.shouldRun = false
            self.listener?.cancel()
            self.listener = nil
            self.listeningPort = 0
            for capability in self.remoteCapabilities.values {
                capability.controlConnection?.stateUpdateHandler = nil
                capability.controlConnection?.cancel()
                capability.controlConnection = nil
            }
            for session in self.serverSessions.values {
                session.connection.cancel()
                self.postSessionDisconnected(session.identifier)
            }
            self.serverSessions.removeAll()
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

        do {
            let entries = try prepareEntries(for: uniqueFiles)
            let totalBytes = try totalSize(of: entries)

            return sendFileBatch(
                entries: entries,
                totalBytes: totalBytes,
                host: host,
                port: port,
                token: token,
                activityThread: activityThread
            )
        } catch {
            NSLog("Horos direct transfer could not prepare files: %@", error.localizedDescription)
            return false
        }
    }

    private func sendFileBatch(
        entries: [HorosDirectFileEntry],
        totalBytes: UInt64,
        host: String,
        port: Int,
        token: String,
        activityThread: Thread?
    ) -> Bool {

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

            try sendFileContents(
                entries,
                totalBytes: totalBytes,
                over: connection,
                activityThread: activityThread
            )

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
            self?.receiveConnection(over: connection)
        }
    }

    private func receiveConnection(over connection: NWConnection) {
        do {
            try waitUntilReady(connection, timeout: 8, thread: nil)
            let magic = try receiveExactly(Self.magic.count, from: connection, timeout: 30, thread: nil)
            if magic == Self.magic {
                receiveFileBatch(over: connection)
            } else if magic == Self.sessionMagic {
                receiveSessionRequest(over: connection)
            } else {
                throw DirectTransferError.invalidProtocol
            }
        } catch {
            connection.cancel()
            NSLog("Horos direct transfer rejected a connection: %@", error.localizedDescription)
        }
    }

    // A C-FIND response from another Horos advertises this endpoint. Keep the
    // control connection outbound from the querying Mac so changing client IPs
    // and NAT do not prevent a later drag-and-drop transfer back to it.
    @objc(registerQueryCapabilityForHost:dicomPort:calledAET:version:port:token:)
    public func registerQueryCapability(
        host: String,
        dicomPort: Int,
        calledAET: String,
        version: Int,
        port: Int,
        token: String
    ) {
        guard version >= Int(Self.sessionProtocolVersion),
              !host.isEmpty,
              dicomPort > 0,
              port > 0,
              port <= Int(UInt16.max),
              !token.isEmpty else { return }

        stateQueue.async { [weak self] in
            guard let self else { return }
            let key = self.capabilityKey(host: host, dicomPort: dicomPort, calledAET: calledAET)
            let capability: HorosDirectRemoteCapability
            if let existing = self.remoteCapabilities[key] {
                existing.dicomPort = dicomPort
                existing.calledAET = calledAET
                existing.directPort = port
                existing.token = token
                capability = existing
            } else {
                capability = HorosDirectRemoteCapability(
                    host: host,
                    dicomPort: dicomPort,
                    calledAET: calledAET,
                    directPort: port,
                    token: token
                )
                self.remoteCapabilities[key] = capability
            }
            self.connectControlSessionIfNeeded(capability, key: key)
        }
    }

    @objc(requestRetrieveQueryItems:toSession:activityThread:)
    public func requestRetrieve(
        queryItems items: [[String: String]],
        toSession sessionID: String,
        activityThread: Thread?
    ) -> Bool {
        guard !items.isEmpty,
              items.allSatisfy({ item in
                  let level = item["level"] ?? ""
                  let hasStudy = !(item["studyUID"] ?? "").isEmpty
                  let hasSeries = !(item["seriesUID"] ?? "").isEmpty
                  return (level == "STUDY" && hasStudy) || (level == "SERIES" && hasStudy && hasSeries)
              }),
              let requestData = try? JSONSerialization.data(withJSONObject: items),
              requestData.count <= 4 * 1_024 * 1_024 else { return false }
        guard let session = stateQueue.sync(execute: { serverSessions[sessionID] }) else { return false }

        do {
            let started = CFAbsoluteTimeGetCurrent()
            NSLog(
                "Horos checked-in C-GET request starting: %d item(s) for %@",
                items.count,
                session.name
            )
            activityThread?.setStatus(String(
                format: NSLocalizedString("Requesting %ld series on %@...", comment: ""),
                items.count,
                session.name
            ))
            activityThread?.setProgress(-1)
            try session.sendQueue.sync {
                try sendControlCommand(.retrieveItems, data: requestData, over: session.connection)
                let acknowledgement = try receiveExactly(
                    4,
                    from: session.connection,
                    timeout: 30 * 60,
                    thread: activityThread
                )
                guard acknowledgement.networkUInt32(at: 0) == 0 else {
                    throw DirectTransferError.receiverRejected
                }
            }
            activityThread?.setStatus(NSLocalizedString("Transfer complete", comment: ""))
            activityThread?.setProgress(1)
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            NSLog(String(
                format: "Horos checked-in C-GET request completed: %d item(s) in %.2f s",
                items.count,
                elapsed
            ))
            return true
        } catch {
            session.connection.cancel()
            removeServerSession(sessionID, connection: session.connection)
            NSLog("Horos checked-in C-GET request failed: %@", error.localizedDescription)
            return false
        }
    }

    private func receiveSessionRequest(over connection: NWConnection) {
        do {
            let header = try receiveExactly(12, from: connection, timeout: 30, thread: nil)
            guard header.networkUInt32(at: 0) == Self.sessionProtocolVersion,
                  let operation = HorosDirectSessionOperation(rawValue: header.networkUInt32(at: 4)) else {
                throw DirectTransferError.invalidProtocol
            }
            let tokenLength = Int(header.networkUInt32(at: 8))
            guard tokenLength > 0, tokenLength <= 256 else { throw DirectTransferError.invalidProtocol }
            let receivedToken = try receiveExactly(tokenLength, from: connection, timeout: 10, thread: nil)
            guard receivedToken == Data(token.utf8) else { throw DirectTransferError.unauthorized }

            switch operation {
            case .checkIn:
                receiveCheckIn(over: connection)
            }
        } catch {
            connection.cancel()
            NSLog("Horos direct session request failed: %@", error.localizedDescription)
        }
    }

    private func capabilityKey(host: String, dicomPort: Int, calledAET: String) -> String {
        "\(host.lowercased())|\(dicomPort)|\(calledAET.uppercased())"
    }

    private func makeConnection(host: String, port: Int) -> NWConnection {
        NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: Self.connectionParameters()
        )
    }

    private func connectControlSessionIfNeeded(_ capability: HorosDirectRemoteCapability, key: String) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard shouldRun,
              !capability.isConnecting,
              capability.controlConnection == nil else { return }

        capability.isConnecting = true
        let connection = makeConnection(host: capability.host, port: capability.directPort)
        let connectionToken = capability.token
        capability.controlConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed(let error):
                NSLog("Horos direct check-in to %@ failed: %@", capability.host, error.localizedDescription)
                self.controlConnectionEnded(connection, capability: capability, key: key)
            case .cancelled:
                self.controlConnectionEnded(connection, capability: capability, key: key)
            default:
                break
            }
        }
        connection.start(queue: Self.ioQueue)
        Self.ioQueue.async { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                try self.waitUntilReady(connection, timeout: 8, thread: nil)
                try self.sendSessionHeader(operation: .checkIn, token: connectionToken, over: connection, thread: nil)
                let defaults = UserDefaults.standard
                let configuredName = defaults.string(forKey: "bonjourServiceName")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (configuredName?.isEmpty == false ? configuredName : nil)
                    ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first
                    ?? "Horos"
                let metadata: [String: Any] = [
                    "name": displayName,
                    "aeTitle": defaults.string(forKey: "AETITLE") ?? "HOROS",
                    "dicomPort": defaults.integer(forKey: "AEPORT"),
                ]
                let metadataData = try JSONSerialization.data(withJSONObject: metadata)
                try self.sendLengthPrefixed(metadataData, over: connection, thread: nil)
                let status = try self.receiveExactly(4, from: connection, timeout: 15, thread: nil).networkUInt32(at: 0)
                guard status == 0 else { throw DirectTransferError.receiverRejected }
                let sessionID = try self.receiveString(from: connection, maximumLength: 256)

                self.stateQueue.async {
                    guard capability.controlConnection === connection else { return }
                    capability.isConnecting = false
                }
                NSLog("Horos direct check-in connected to %@ as session %@", capability.host, sessionID)
                self.runControlLoop(connection, capability: capability, key: key)
            } catch {
                NSLog("Horos direct check-in to %@ failed: %@", capability.host, error.localizedDescription)
                connection.cancel()
                self.controlConnectionEnded(connection, capability: capability, key: key)
            }
        }
    }

    private func controlConnectionEnded(
        _ connection: NWConnection,
        capability: HorosDirectRemoteCapability,
        key: String
    ) {
        stateQueue.async { [weak self, weak capability] in
            guard let self, let capability, capability.controlConnection === connection else { return }
            connection.stateUpdateHandler = nil
            capability.controlConnection = nil
            capability.isConnecting = false
            guard self.shouldRun else { return }
            self.stateQueue.asyncAfter(deadline: .now() + 3) { [weak self, weak capability] in
                guard let self, let capability,
                      self.remoteCapabilities[key] === capability else { return }
                self.connectControlSessionIfNeeded(capability, key: key)
            }
        }
    }

    private func runControlLoop(
        _ connection: NWConnection,
        capability: HorosDirectRemoteCapability,
        key: String
    ) {
        do {
            while connection.state == .ready {
                let header = try receiveExactly(8, from: connection, timeout: 45, thread: nil)
                guard let command = HorosDirectControlCommand(rawValue: header.networkUInt32(at: 0)) else {
                    throw DirectTransferError.invalidProtocol
                }
                let valueLength = Int(header.networkUInt32(at: 4))
                guard valueLength >= 0, valueLength <= 4 * 1_024 * 1_024 else {
                    throw DirectTransferError.invalidProtocol
                }
                let valueData = valueLength > 0
                    ? try receiveExactly(valueLength, from: connection, timeout: 10, thread: nil)
                    : Data()
                switch command {
                case .ping:
                    var acknowledgement = Data()
                    acknowledgement.appendNetwork(UInt32(0))
                    try sendData(acknowledgement, over: connection, timeout: 10, thread: nil)
                case .retrieveItems:
                    guard let items = try JSONSerialization.jsonObject(with: valueData) as? [[String: String]],
                          !items.isEmpty else {
                        throw DirectTransferError.invalidProtocol
                    }
                    let started = CFAbsoluteTimeGetCurrent()
                    NSLog(
                        "Horos checked-in client retrieving %d item(s) from %@:%d with C-GET",
                        items.count,
                        capability.host,
                        capability.dicomPort
                    )
                    let succeeded = HorosRetrieveDICOMQueryItems(
                        items,
                        capability.host,
                        capability.dicomPort,
                        capability.calledAET
                    )
                    var acknowledgement = Data()
                    acknowledgement.appendNetwork(UInt32(succeeded ? 0 : 1))
                    try sendData(acknowledgement, over: connection, timeout: 10, thread: nil)
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    NSLog(
                        "Horos checked-in client C-GET %@ after %.2f s",
                        succeeded ? "completed" : "failed",
                        elapsed
                    )
                }
            }
        } catch {
            NSLog("Horos direct check-in control connection to %@ ended: %@", capability.host, error.localizedDescription)
            connection.cancel()
        }
        controlConnectionEnded(connection, capability: capability, key: key)
    }

    private func receiveCheckIn(over connection: NWConnection) {
        var registeredSession: HorosDirectServerSession?
        do {
            let metadataData = try receiveLengthPrefixed(from: connection, maximumLength: 64 * 1_024)
            guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
                  let name = metadata["name"] as? String,
                  !name.isEmpty,
                  let aeTitle = metadata["aeTitle"] as? String,
                  !aeTitle.isEmpty,
                  let dicomPort = metadata["dicomPort"] as? Int,
                  dicomPort > 0,
                  dicomPort <= Int(UInt16.max) else {
                throw DirectTransferError.invalidProtocol
            }
            let sessionID = UUID().uuidString
            let address = remoteAddress(for: connection)
            let session = HorosDirectServerSession(
                identifier: sessionID,
                connection: connection,
                name: name,
                aeTitle: aeTitle,
                dicomPort: dicomPort,
                address: address
            )

            stateQueue.sync {
                let replaced = serverSessions.values.filter {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame &&
                    $0.aeTitle.caseInsensitiveCompare(aeTitle) == .orderedSame
                }
                for oldSession in replaced {
                    serverSessions.removeValue(forKey: oldSession.identifier)
                    oldSession.connection.cancel()
                    postSessionDisconnected(oldSession.identifier)
                }
                serverSessions[sessionID] = session
            }
            registeredSession = session

            var acknowledgement = Data()
            acknowledgement.appendNetwork(UInt32(0))
            try sendData(acknowledgement, over: connection, thread: nil)
            try sendString(sessionID, over: connection, thread: nil)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .failed = state {
                    self.removeServerSession(sessionID, connection: connection)
                } else if case .cancelled = state {
                    self.removeServerSession(sessionID, connection: connection)
                }
            }
            postSessionConnected(session)
            schedulePing(for: sessionID)
            NSLog("Horos direct client checked in: %@ (%@) from %@", name, aeTitle, address)
        } catch {
            connection.cancel()
            if let registeredSession {
                removeServerSession(registeredSession.identifier, connection: connection)
            }
            NSLog("Horos direct check-in rejected: %@", error.localizedDescription)
        }
    }

    private func remoteAddress(for connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return String(describing: host)
        }
        return "Horos"
    }

    private func postSessionConnected(_ session: HorosDirectServerSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.sessionConnectedNotification,
                object: self,
                userInfo: [
                    "sessionID": session.identifier,
                    "name": session.name,
                    "aeTitle": session.aeTitle,
                    "dicomPort": session.dicomPort,
                    "address": session.address,
                ]
            )
        }
    }

    private func postSessionDisconnected(_ sessionID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.sessionDisconnectedNotification,
                object: self,
                userInfo: ["sessionID": sessionID]
            )
        }
    }

    private func removeServerSession(_ sessionID: String, connection: NWConnection) {
        stateQueue.async { [weak self] in
            guard let self,
                  let session = self.serverSessions[sessionID],
                  session.connection === connection else { return }
            self.serverSessions.removeValue(forKey: sessionID)
            self.postSessionDisconnected(sessionID)
            NSLog("Horos direct client disconnected: %@", session.name)
        }
    }

    private func schedulePing(for sessionID: String) {
        stateQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let session = self.serverSessions[sessionID] else { return }
            Self.ioQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try session.sendQueue.sync {
                        try self.sendControlCommand(.ping, data: Data(), over: session.connection)
                        let acknowledgement = try self.receiveExactly(4, from: session.connection, timeout: 10, thread: nil)
                        guard acknowledgement.networkUInt32(at: 0) == 0 else {
                            throw DirectTransferError.receiverRejected
                        }
                    }
                    self.schedulePing(for: sessionID)
                } catch {
                    NSLog("Horos direct heartbeat to %@ failed: %@", session.name, error.localizedDescription)
                    session.connection.cancel()
                    self.removeServerSession(sessionID, connection: session.connection)
                }
            }
        }
    }

    private func sendControlCommand(
        _ command: HorosDirectControlCommand,
        data: Data,
        over connection: NWConnection
    ) throws {
        guard data.count <= 4 * 1_024 * 1_024 else { throw DirectTransferError.invalidProtocol }
        var message = Data()
        message.appendNetwork(command.rawValue)
        message.appendNetwork(UInt32(data.count))
        message.append(data)
        try sendData(message, over: connection, timeout: 15, thread: nil)
    }

    @objc(queryCapabilityForCallingAET:)
    public func queryCapability(forCallingAET callingAET: String?) -> [String: Any] {
        guard isRunning else { return [:] }
        return [
            "version": Int(Self.sessionProtocolVersion),
            "port": port,
            "token": token,
        ]
    }

    @objc public var activeSessionDictionaries: [[String: Any]] {
        stateQueue.sync {
            serverSessions.values.map { session in
                [
                    "sessionID": session.identifier,
                    "name": session.name,
                    "aeTitle": session.aeTitle,
                    "dicomPort": session.dicomPort,
                    "address": session.address,
                ]
            }
        }
    }

    private func sendSessionHeader(
        operation: HorosDirectSessionOperation,
        token: String,
        over connection: NWConnection,
        thread: Thread?
    ) throws {
        let tokenData = Data(token.utf8)
        guard !tokenData.isEmpty, tokenData.count <= 256 else { throw DirectTransferError.unauthorized }
        var header = Data()
        header.append(Self.sessionMagic)
        header.appendNetwork(Self.sessionProtocolVersion)
        header.appendNetwork(operation.rawValue)
        header.appendNetwork(UInt32(tokenData.count))
        header.append(tokenData)
        try sendData(header, over: connection, thread: thread)
    }

    private func sendLengthPrefixed(_ data: Data, over connection: NWConnection, thread: Thread?) throws {
        guard data.count <= Int(UInt32.max) else { throw DirectTransferError.invalidProtocol }
        var packet = Data()
        packet.appendNetwork(UInt32(data.count))
        packet.append(data)
        try sendData(packet, over: connection, thread: thread)
    }

    private func receiveLengthPrefixed(from connection: NWConnection, maximumLength: Int) throws -> Data {
        let lengthData = try receiveExactly(4, from: connection, timeout: 30, thread: nil)
        let length = Int(lengthData.networkUInt32(at: 0))
        guard length >= 0, length <= maximumLength else { throw DirectTransferError.invalidProtocol }
        return length > 0 ? try receiveExactly(length, from: connection, timeout: 30, thread: nil) : Data()
    }

    private func sendString(_ string: String, over connection: NWConnection, thread: Thread?) throws {
        try sendLengthPrefixed(Data(string.utf8), over: connection, thread: thread)
    }

    private func receiveString(from connection: NWConnection, maximumLength: Int) throws -> String {
        let data = try receiveLengthPrefixed(from: connection, maximumLength: maximumLength)
        guard let string = String(data: data, encoding: .utf8) else { throw DirectTransferError.invalidProtocol }
        return string
    }

    private func prepareEntries(for files: [String]) throws -> [HorosDirectFileEntry] {
        guard !files.isEmpty, files.count <= Self.maximumFiles else { throw DirectTransferError.invalidProtocol }
        var entries: [HorosDirectFileEntry] = []
        entries.reserveCapacity(files.count)
        for path in files {
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
            entries.append(HorosDirectFileEntry(url: url, nameData: nameData, size: size))
        }
        return entries
    }

    private func totalSize(of entries: [HorosDirectFileEntry]) throws -> UInt64 {
        var result: UInt64 = 0
        for entry in entries {
            let (newResult, overflow) = result.addingReportingOverflow(entry.size)
            guard !overflow else { throw DirectTransferError.invalidProtocol }
            result = newResult
        }
        return result
    }

    private func wireSize(of entries: [HorosDirectFileEntry], fileBytes: UInt64) throws -> UInt64 {
        var result = fileBytes
        for entry in entries {
            let framingBytes = UInt64(12 + entry.nameData.count)
            let (newResult, overflow) = result.addingReportingOverflow(framingBytes)
            guard !overflow else { throw DirectTransferError.invalidProtocol }
            result = newResult
        }
        return result
    }

    private func sendFileContents(
        _ entries: [HorosDirectFileEntry],
        totalBytes: UInt64,
        over connection: NWConnection,
        activityThread: Thread?
    ) throws {
        // TCP is a byte stream, so file boundaries do not need to match
        // individual NWConnection sends. Coalescing headers and small DICOM
        // files avoids paying one contentProcessed round trip per image on
        // higher-latency links.
        let totalWireBytes = try wireSize(of: entries, fileBytes: totalBytes)
        var streamBuffer = Data()
        streamBuffer.reserveCapacity(Self.streamBufferSize)
        var lastActivityUpdate = CFAbsoluteTimeGetCurrent()
        var lastPerformanceLog = lastActivityUpdate
        let transferStarted = lastActivityUpdate
        var wireBytesSent: UInt64 = 0
        var currentFileNumber = 0

        func flushStreamBuffer() throws {
            guard !streamBuffer.isEmpty else { return }
            let byteCount = streamBuffer.count
            try sendData(
                streamBuffer,
                over: connection,
                timeout: Self.bulkIOTimeout,
                thread: activityThread
            )
            wireBytesSent += UInt64(byteCount)
            streamBuffer.removeAll(keepingCapacity: true)

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastActivityUpdate >= 0.2 || wireBytesSent == totalWireBytes {
                activityThread?.setStatus(String(
                    format: NSLocalizedString("Sending file %d of %d...", comment: ""),
                    currentFileNumber,
                    entries.count
                ))
                activityThread?.setProgress(
                    totalWireBytes > 0 ? CGFloat(wireBytesSent) / CGFloat(totalWireBytes) : 1
                )
                if now - lastPerformanceLog >= 5 {
                    let elapsed = max(now - transferStarted, 0.001)
                    NSLog(String(
                        format: "Horos direct bulk send progress: %.1f/%.1f MiB (%.1f MiB/s)",
                        Double(wireBytesSent) / (1_024 * 1_024),
                        Double(totalWireBytes) / (1_024 * 1_024),
                        Double(wireBytesSent) / (1_024 * 1_024) / elapsed
                    ))
                    lastPerformanceLog = now
                }
                lastActivityUpdate = now
            }
        }

        func appendToStream(_ data: Data) throws {
            if streamBuffer.count + data.count > Self.streamBufferSize {
                try flushStreamBuffer()
            }
            streamBuffer.append(data)
        }

        for (index, entry) in entries.enumerated() {
            if activityThread?.isCancelled == true { throw DirectTransferError.cancelled }
            currentFileNumber = index + 1
            var fileHeader = Data()
            fileHeader.appendNetwork(UInt32(entry.nameData.count))
            fileHeader.appendNetwork(entry.size)
            fileHeader.append(entry.nameData)
            try appendToStream(fileHeader)

            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            var remaining = entry.size
            while remaining > 0 {
                if activityThread?.isCancelled == true { throw DirectTransferError.cancelled }
                let requested = Int(min(UInt64(Self.chunkSize), remaining))
                let data = try handle.read(upToCount: requested) ?? Data()
                guard !data.isEmpty else { throw DirectTransferError.truncatedFile(entry.url.path) }
                try appendToStream(data)
                remaining -= UInt64(data.count)
            }
        }
        try flushStreamBuffer()
    }

    private func receiveIncomingFiles(
        fileCount: Int,
        declaredTotal: UInt64,
        over connection: NWConnection,
        activityThread: Thread?
    ) throws -> UInt64 {
        guard let database = DicomDatabase.activeLocal() else { throw DirectTransferError.databaseUnavailable }
        let fileManager = FileManager.default
        let incomingURL = URL(fileURLWithPath: database.incomingDirPath(), isDirectory: true)
        let stagingRoot = URL(fileURLWithPath: database.tempDirPath(), isDirectory: true)
            .appendingPathComponent("Horos Direct Transfer", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        removeAbandonedBatches(in: stagingRoot, fileManager: fileManager)
        let batchURL = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: batchURL, withIntermediateDirectories: false)
        var cleanupURL: URL? = batchURL
        defer {
            if let cleanupURL { try? fileManager.removeItem(at: cleanupURL) }
        }

        let receivedTotal = try receiveFramedFiles(
            fileCount: fileCount,
            declaredTotal: declaredTotal,
            into: batchURL,
            over: connection,
            activityThread: activityThread
        )

        guard receivedTotal == declaredTotal else { throw DirectTransferError.invalidProtocol }
        try fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: true)
        let completedBatch = incomingURL.appendingPathComponent(".HorosDirect-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: batchURL, to: completedBatch)
        cleanupURL = completedBatch
        let visibleBatch = incomingURL.appendingPathComponent("HorosDirect-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: completedBatch, to: visibleBatch)
        cleanupURL = nil
        database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
        return receivedTotal
    }

    private func receiveFramedFiles(
        fileCount: Int,
        declaredTotal: UInt64,
        into batchURL: URL,
        over connection: NWConnection,
        activityThread: Thread?
    ) throws -> UInt64 {
        var streamBuffer = Data()
        var streamOffset = 0

        func readFromStream(_ length: Int, timeout: TimeInterval) throws -> Data {
            guard length >= 0 else { throw DirectTransferError.invalidProtocol }
            while streamBuffer.count - streamOffset < length {
                if streamOffset > 0 {
                    streamBuffer.removeSubrange(0..<streamOffset)
                    streamOffset = 0
                }
                let availableBytes = streamBuffer.count - streamOffset
                let needed = length - availableBytes
                let chunk = try receiveSome(
                    minimumLength: min(max(needed, 1), 256 * 1_024),
                    maximumLength: Self.chunkSize,
                    from: connection,
                    timeout: max(timeout, Self.bulkIOTimeout),
                    thread: activityThread
                )
                streamBuffer.append(chunk)
            }

            let range = streamOffset..<(streamOffset + length)
            let result = streamBuffer.subdata(in: range)
            streamOffset += length
            if streamOffset == streamBuffer.count {
                streamBuffer.removeAll(keepingCapacity: true)
                streamOffset = 0
            }
            return result
        }

        let receivedTotal = try unpackFramedFiles(
            fileCount: fileCount,
            declaredTotal: declaredTotal,
            into: batchURL,
            activityThread: activityThread
        ) { length in
            try readFromStream(length, timeout: 60)
        }

        guard receivedTotal == declaredTotal,
              streamBuffer.count == streamOffset else {
            throw DirectTransferError.invalidProtocol
        }
        return receivedTotal
    }

    private func unpackFramedFiles(
        fileCount: Int,
        declaredTotal: UInt64,
        into batchURL: URL,
        activityThread: Thread?,
        readData: (_ length: Int) throws -> Data
    ) throws -> UInt64 {
        let fileManager = FileManager.default
        var receivedTotal: UInt64 = 0
        var lastActivityUpdate = CFAbsoluteTimeGetCurrent()

        for index in 0..<fileCount {
            if activityThread?.isCancelled == true { throw DirectTransferError.cancelled }
            let fileHeader = try readData(12)
            let nameLength = Int(fileHeader.networkUInt32(at: 0))
            let fileSize = fileHeader.networkUInt64(at: 4)
            guard nameLength > 0,
                  nameLength <= Self.maximumFilenameBytes,
                  fileSize > 0,
                  fileSize <= Self.maximumFileBytes else { throw DirectTransferError.invalidProtocol }
            let nameData = try readData(nameLength)
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
                    let data = try readData(Int(min(UInt64(Self.chunkSize), remaining)))
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                    receivedTotal += UInt64(data.count)

                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastActivityUpdate >= 0.2 || receivedTotal == declaredTotal {
                        activityThread?.setStatus(String(
                            format: NSLocalizedString("Receiving file %d of %d...", comment: ""),
                            index + 1,
                            fileCount
                        ))
                        activityThread?.setProgress(
                            CGFloat(receivedTotal) / CGFloat(declaredTotal)
                        )
                        lastActivityUpdate = now
                    }
                }
            } catch {
                try? output.close()
                throw error
            }
            try output.close()
        }

        guard receivedTotal == declaredTotal else { throw DirectTransferError.invalidProtocol }
        return receivedTotal
    }

    private func receiveFileBatch(over connection: NWConnection) {
        do {
            let header = try receiveExactly(20, from: connection, timeout: 30, thread: nil)
            let version = header.networkUInt32(at: 0)
            let fileCount = Int(header.networkUInt32(at: 4))
            let declaredTotal = header.networkUInt64(at: 8)
            let tokenLength = Int(header.networkUInt32(at: 16))
            guard version == Self.protocolVersion,
                  fileCount > 0,
                  fileCount <= Self.maximumFiles,
                  tokenLength > 0,
                  tokenLength <= 256 else {
                throw DirectTransferError.invalidProtocol
            }
            let receivedToken = try receiveExactly(tokenLength, from: connection, timeout: 10, thread: nil)
            guard receivedToken == Data(token.utf8) else { throw DirectTransferError.unauthorized }
            let receivedTotal = try receiveIncomingFiles(
                fileCount: fileCount,
                declaredTotal: declaredTotal,
                over: connection,
                activityThread: nil
            )

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

        while result.count < length {
            let remaining = length - result.count
            let minimumLength = min(remaining, 256 * 1_024)
            result.append(try receiveSome(
                minimumLength: minimumLength,
                maximumLength: remaining,
                from: connection,
                timeout: timeout,
                thread: thread
            ))
        }
        return result
    }

    private func receiveSome(
        minimumLength: Int,
        maximumLength: Int,
        from connection: NWConnection,
        timeout: TimeInterval,
        thread: Thread?
    ) throws -> Data {
        guard minimumLength > 0, maximumLength >= minimumLength else {
            throw DirectTransferError.invalidProtocol
        }

        let deadline = Date().addingTimeInterval(timeout)
        let semaphore = DispatchSemaphore(value: 0)
        var received: Data?
        var receiveError: NWError?
        var complete = false
        connection.receive(
            minimumIncompleteLength: minimumLength,
            maximumLength: maximumLength
        ) { data, _, isComplete, error in
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
        if let received, !received.isEmpty { return received }
        if complete { throw DirectTransferError.connectionClosed }
        throw DirectTransferError.invalidProtocol
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
