import Foundation
import dnssd

@objc protocol HorosBonjourServiceDelegate: AnyObject {
    @objc optional func netServiceDidResolveAddress(_ service: HorosBonjourService)
    @objc(netService:didNotResolve:)
    optional func netService(_ service: HorosBonjourService, didNotResolve error: [String: Any])
}

/// Resolves discovered services without connecting to their DICOM/database listener.
@objc(HorosBonjourService)
final class HorosBonjourService: NSObject {
    private struct Address: Hashable {
        let host: String
        let isIPv4: Bool
    }

    private struct Snapshot {
        let address: String
        let hostName: String
        let port: Int
        let txt: Data
    }

    private final class Lookup {
        weak var owner: HorosBonjourService?
        var reference: DNSServiceRef?
        var hostName = ""
        var port = 0
        var txt = Data()
        var addresses: Set<Address> = []

        func close() {
            dispatchPrecondition(condition: .onQueue(.main))
            if let reference {
                self.reference = nil
                DNSServiceRefDeallocate(reference)
            }
        }
    }

    @objc let name: String
    @objc let type: String
    @objc let domain: String
    @objc weak var delegate: HorosBonjourServiceDelegate?
    @objc var resolvedAddress: String? { currentSnapshot?.address }
    @objc var hostName: String? { currentSnapshot?.hostName }
    @objc var port: Int { currentSnapshot?.port ?? -1 }
    @objc var TXTRecordData: Data? { currentSnapshot?.txt }

    var interfaceIndexes: Set<UInt32> = []
    private let snapshotLock = NSLock()
    private var snapshot: Snapshot?
    // Node lists can be read by transfer workers while discovery refreshes on main.
    private var currentSnapshot: Snapshot? { snapshotLock.withLock { snapshot } }
    private var lookups: [Lookup] = []
    private var generation: UInt = 0
    private var timeout: DispatchWorkItem?
    private var completionQueued = false

    init(domain: String, type: String, name: String) {
        self.domain = domain
        self.type = type
        self.name = name
        super.init()
    }

    override var description: String { "\(name) \(type) \(domain) \(resolvedAddress ?? "unresolved"):\(port)" }

    @objc(resolveWithTimeout:)
    func resolve(withTimeout interval: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        let currentGeneration = generation
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.fail(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval.isFinite && interval > 0 ? interval : 5), execute: deadline)
        let indexes = interfaceIndexes.isEmpty ? [UInt32(0)] : interfaceIndexes.sorted()
        lookups = indexes.map { _ in
            let lookup = Lookup()
            lookup.owner = self
            return lookup
        }
        for (index, lookup) in zip(indexes, lookups) {
            guard generation == currentGeneration else { return }
            var reference: DNSServiceRef?
            let error = DNSServiceResolve(&reference, kDNSServiceFlagsIncludeP2P, index, name, type, domain,
                                         { reference, _, interface, error, _, host, port, length, txt, context in
                guard let context else { return }
                let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
                guard let owner = lookup.owner, owner.isCurrent(lookup, reference: reference) else { return }
                guard error == kDNSServiceErr_NoError else {
                    owner.failed(lookup, error: error)
                    return
                }
                guard let host, port != 0, length == 0 || txt != nil else {
                    owner.failed(lookup, error: DNSServiceErrorType(kDNSServiceErr_Invalid))
                    return
                }
                lookup.hostName = String(cString: host)
                lookup.port = Int(UInt16(bigEndian: port))
                lookup.txt = txt.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                lookup.close()
                owner.resolveAddresses(lookup, interface: interface)
            }, Unmanaged.passUnretained(lookup).toOpaque())
            schedule(reference, for: lookup, error: error)
        }
    }

    @objc func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        completionQueued = false
        for lookup in lookups { lookup.close() }
        lookups.removeAll()
        // Keep the last complete snapshot available to consumers during refresh/failure.
    }

    private func isCurrent(_ lookup: Lookup, reference: DNSServiceRef?) -> Bool {
        timeout != nil && lookups.contains { $0 === lookup } && lookup.reference == reference
    }

    private func schedule(_ reference: DNSServiceRef?, for lookup: Lookup, error: DNSServiceErrorType) {
        guard error == kDNSServiceErr_NoError, let reference else {
            failed(lookup, error: error == kDNSServiceErr_NoError ? DNSServiceErrorType(kDNSServiceErr_Unknown) : error)
            return
        }
        lookup.reference = reference
        let error = DNSServiceSetDispatchQueue(reference, .main)
        if error != kDNSServiceErr_NoError { failed(lookup, error: error) }
    }

    private func resolveAddresses(_ lookup: Lookup, interface: UInt32) {
        var reference: DNSServiceRef?
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let error = DNSServiceGetAddrInfo(&reference, kDNSServiceFlagsIncludeP2P, interface, protocols, lookup.hostName,
                                         { reference, flags, interface, error, _, address, _, context in
            guard let context else { return }
            let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
            guard let owner = lookup.owner, owner.isCurrent(lookup, reference: reference) else { return }
            // A missing A record is not a failed AAAA lookup (and vice versa).
            if error == kDNSServiceErr_NoSuchRecord {
                owner.queueCompletion()
                return
            }
            guard error == kDNSServiceErr_NoError else {
                owner.failed(lookup, error: error)
                return
            }
            if let address, let value = HorosBonjourService.numericAddress(address, interface: interface) {
                if flags & UInt32(kDNSServiceFlagsAdd) != 0 {
                    lookup.addresses.insert(value)
                } else {
                    lookup.addresses.remove(value)
                }
            }
            if flags & UInt32(kDNSServiceFlagsMoreComing) == 0 { owner.queueCompletion() }
        }, Unmanaged.passUnretained(lookup).toOpaque())
        schedule(reference, for: lookup, error: error)
    }

    private func queueCompletion() {
        guard !completionQueued else { return }
        completionQueued = true
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration, self.timeout != nil else { return }
            self.completionQueued = false
            let candidates = self.lookups.flatMap { lookup in lookup.addresses.map { (lookup, $0) } }
            // Preserve IPv4 preference within the available batch without waiting for
            // a missing address family or an unavailable second interface.
            guard let (lookup, address) = candidates.sorted(by: {
                if $0.1.isIPv4 != $1.1.isIPv4 { return $0.1.isIPv4 }
                return $0.1.host < $1.1.host
            }).first else { return }
            let snapshot = Snapshot(address: address.host, hostName: lookup.hostName, port: lookup.port, txt: lookup.txt)
            self.stop()
            self.snapshotLock.withLock { self.snapshot = snapshot }
            self.delegate?.netServiceDidResolveAddress?(self)
        }
    }

    private func failed(_ lookup: Lookup, error: DNSServiceErrorType) {
        lookup.close()
        lookups.removeAll { $0 === lookup }
        if lookups.isEmpty { fail(error) }
    }

    private func fail(_ error: DNSServiceErrorType) {
        stop()
        delegate?.netService?(self, didNotResolve: ["domain": "DNSServiceErrorDomain", "code": error])
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, interface: UInt32) -> Address? {
        let family = Int32(address.pointee.sa_family)
        var storage = sockaddr_storage()
        let size: Int
        switch family {
        case AF_INET: size = MemoryLayout<sockaddr_in>.size
        case AF_INET6: size = MemoryLayout<sockaddr_in6>.size
        default: return nil
        }
        guard Int(address.pointee.sa_len) >= size else { return nil }
        withUnsafeMutablePointer(to: &storage) { destination in
            UnsafeMutableRawPointer(destination).copyMemory(from: address, byteCount: size)
        }
        // A link-local IPv6 address is unusable without its interface/zone.
        if family == AF_INET6 {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                    let bytes = withUnsafeBytes(of: value.pointee.sin6_addr) { Array($0) }
                    if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && value.pointee.sin6_scope_id == 0 {
                        value.pointee.sin6_scope_id = interface
                    }
                }
            }
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let error = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard error == 0 else { return nil }
        return Address(host: String(cString: host), isIPv4: family == AF_INET)
    }

    @objc(dictionaryFromTXTRecordData:)
    static func dictionary(fromTXTRecord data: Data?) -> [String: Data] {
        guard let data, !data.isEmpty, let length = UInt16(exactly: data.count) else { return [:] }
        return data.withUnsafeBytes { bytes in
            var result: [String: Data] = [:]
            for index in 0..<TXTRecordGetCount(length, bytes.baseAddress) {
                var key = [CChar](repeating: 0, count: 256)
                var valueLength: UInt8 = 0
                var value: UnsafeRawPointer?
                let error = TXTRecordGetItemAtIndex(length, bytes.baseAddress, index, UInt16(key.count),
                                                   &key, &valueLength, &value)
                guard error == kDNSServiceErr_NoError else { return [:] }
                result[String(cString: key)] = value.map { Data(bytes: $0, count: Int(valueLength)) } ?? Data()
            }
            return result
        }
    }

    deinit {
        timeout?.cancel()
        let pending = lookups
        if Thread.isMainThread {
            for lookup in pending { lookup.close() }
        } else {
            DispatchQueue.main.async { for lookup in pending { lookup.close() } }
        }
    }
}
