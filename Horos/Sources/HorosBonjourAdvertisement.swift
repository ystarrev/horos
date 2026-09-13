import Foundation
import dnssd

/// Publishes an existing listener's port. All operations and callbacks use the main queue.
@objc(HorosBonjourAdvertisement)
final class HorosBonjourAdvertisement: NSObject {
    private final class Registration {
        weak var owner: HorosBonjourAdvertisement?
        var reference: DNSServiceRef?

        func close() {
            dispatchPrecondition(condition: .onQueue(.main))
            if let reference {
                self.reference = nil
                DNSServiceRefDeallocate(reference)
            }
        }
    }

    private let requestedName: String
    @objc private(set) var name: String
    @objc let type: String
    @objc let port: Int
    @objc private(set) var txtRecord: [String: String] = [:]
    private var txtData = Data()
    private var registration: Registration?
    private var isActive = false
    private var generation: UInt = 0
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1

    @objc(initWithName:type:port:)
    init(name: String, type: String, port: Int) {
        requestedName = name
        self.name = name
        self.type = type
        self.port = port
        super.init()
    }

    @objc(publishWithTXTRecord:)
    func publish(txtRecord: [String: String]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let data: Data
        do {
            data = try Self.encodeTXTRecord(txtRecord)
        } catch {
            NSLog("Horos Bonjour invalid TXT record for %@ %@:%ld: %@", name, type, port, error as NSError)
            return
        }
        let changed = txtData != data
        self.txtRecord = txtRecord
        txtData = data
        isActive = true

        if let reference = registration?.reference {
            if changed {
                let error = data.withUnsafeBytes {
                    DNSServiceUpdateRecord(reference, nil, 0, UInt16(data.count), $0.baseAddress, 0)
                }
                if error != kDNSServiceErr_NoError { failed(error) }
            }
        } else if retry == nil {
            register()
        }
    }

    @objc func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        isActive = false
        generation &+= 1
        retry?.cancel()
        retry = nil
        registration?.close()
        registration = nil
        retryDelay = 1
    }

    private func register() {
        guard isActive, registration == nil else { return }
        guard let wirePort = UInt16(exactly: port), wirePort > 0 else {
            failed(DNSServiceErrorType(kDNSServiceErr_BadParam))
            return
        }
        let pending = Registration()
        pending.owner = self
        var reference: DNSServiceRef?
        let error = txtData.withUnsafeBytes { bytes in
            DNSServiceRegister(&reference, 0, 0, requestedName, type, nil, nil,
                               wirePort.bigEndian, UInt16(txtData.count), bytes.baseAddress,
                               { reference, flags, error, name, _, _, context in
                guard let context else { return }
                let pending = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
                guard let owner = pending.owner, owner.registration === pending,
                      pending.reference == reference else { return }
                if error != kDNSServiceErr_NoError {
                    owner.failed(error)
                } else if flags & UInt32(kDNSServiceFlagsAdd) != 0, let name {
                    owner.name = String(cString: name)
                    owner.retryDelay = 1
                    NSLog("Horos Bonjour service published: %@ %@:%ld", owner.name, owner.type, owner.port)
                }
            }, Unmanaged.passUnretained(pending).toOpaque())
        }
        guard error == kDNSServiceErr_NoError, let reference else {
            failed(error == kDNSServiceErr_NoError ? DNSServiceErrorType(kDNSServiceErr_Unknown) : error)
            return
        }
        pending.reference = reference
        registration = pending
        let schedulingError = DNSServiceSetDispatchQueue(reference, .main)
        if schedulingError != kDNSServiceErr_NoError { failed(schedulingError) }
    }

    private func failed(_ error: DNSServiceErrorType) {
        registration?.close()
        registration = nil
        NSLog("Warning: Horos Bonjour service did not publish: %@ %@:%ld DNS-SD error=%d", name, type, port, error)
        // Reconnect to the same native API after a daemon failure; never start a helper process.
        guard isActive, retry == nil, Self.isTransient(error) else { return }
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.generation == currentGeneration else { return }
            self.retry = nil
            self.register()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 10)
    }

    private static func isTransient(_ error: DNSServiceErrorType) -> Bool {
        switch Int(error) {
        case kDNSServiceErr_ServiceNotRunning, kDNSServiceErr_DefunctConnection,
             kDNSServiceErr_Transient, kDNSServiceErr_NotInitialized,
             kDNSServiceErr_Timeout, kDNSServiceErr_NoMemory:
            return true
        default:
            return false
        }
    }

    private static func encodeTXTRecord(_ values: [String: String]) throws -> Data {
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for key in values.keys.sorted() {
            let value = values[key, default: ""]
            guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e && $0 != 0x3d }),
                  let length = UInt8(exactly: value.utf8.count), key.utf8.count + 1 + value.utf8.count <= 255 else {
                throw NSError(domain: "DNSServiceErrorDomain", code: Int(kDNSServiceErr_BadParam))
            }
            let error = value.withCString {
                TXTRecordSetValue(&record, key, length, $0)
            }
            guard error == kDNSServiceErr_NoError else {
                throw NSError(domain: "DNSServiceErrorDomain", code: Int(error))
            }
        }
        let count = Int(TXTRecordGetLength(&record))
        guard count > 0, let bytes = TXTRecordGetBytesPtr(&record) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    deinit {
        retry?.cancel()
        // Keep the callback context alive until its reference is closed on its dispatch queue.
        if let registration {
            if Thread.isMainThread {
                registration.close()
            } else {
                DispatchQueue.main.async { registration.close() }
            }
        }
    }
}
