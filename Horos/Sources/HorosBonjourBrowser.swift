import Foundation
import Network

@objc protocol HorosBonjourBrowserDelegate: AnyObject {
    @objc optional func netServiceBrowserWillSearch(_ browser: HorosBonjourBrowser)
    @objc optional func netServiceBrowserDidStopSearch(_ browser: HorosBonjourBrowser)
    @objc(netServiceBrowser:didFindService:moreComing:)
    optional func netServiceBrowser(_ browser: HorosBonjourBrowser, didFind service: HorosBonjourService, moreComing: Bool)
    @objc(netServiceBrowser:didRemoveService:moreComing:)
    optional func netServiceBrowser(_ browser: HorosBonjourBrowser, didRemove service: HorosBonjourService, moreComing: Bool)
    @objc(netServiceBrowser:didUpdateService:)
    optional func netServiceBrowser(_ browser: HorosBonjourBrowser, didUpdate service: HorosBonjourService)
    @objc(netServiceBrowser:didNotSearch:)
    optional func netServiceBrowser(_ browser: HorosBonjourBrowser, didNotSearch error: [String: Any])
}

// Network.framework owns discovery; each stable service resolves through native DNS-SD.
@objc(HorosBonjourBrowser)
final class HorosBonjourBrowser: NSObject {
    private struct Identity: Hashable {
        let name: String
        let type: String
        let domain: String

        init(name: String, type: String, domain: String) {
            self.name = name.lowercased()
            self.type = type.lowercased()
            self.domain = domain.lowercased()
        }
    }

    private struct Discovery {
        let service: HorosBonjourService
        let results: Set<NWBrowser.Result>
    }

    @objc weak var delegate: HorosBonjourBrowserDelegate?
    private var browser: NWBrowser?
    private var generation: UInt = 0
    private var didAnnounceSearch = false
    private var discoveries: [Identity: Discovery] = [:]

    @objc(searchForServicesOfType:inDomain:)
    func searchForServices(ofType type: String, inDomain domain: String) {
        precondition(Thread.isMainThread)
        stop()
        let currentGeneration = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain.isEmpty ? nil : domain),
                                using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == currentGeneration, self.browser != nil else { return }
            switch state {
            case .ready:
                self.announceSearchIfNeeded()
            case .waiting(let error):
                // A disconnected interface can recover on this browser. Preserve
                // results and let the existing Sources liveness checks do their job.
                NSLog("Horos Network Bonjour waiting for %@: %@", type, String(describing: error))
            case .failed(let error):
                self.fail(error)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == currentGeneration, self.browser != nil else { return }
            self.announceSearchIfNeeded()
            guard self.generation == currentGeneration else { return }
            self.apply(results, generation: currentGeneration)
        }
        browser.start(queue: .main)
    }

    @objc func stop() {
        precondition(Thread.isMainThread)
        let wasSearching = browser != nil
        generation &+= 1
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        didAnnounceSearch = false
        let previous = discoveries
        discoveries.removeAll()
        for discovery in previous.values {
            discovery.service.delegate = nil
            discovery.service.stop()
        }
        if wasSearching { delegate?.netServiceBrowserDidStopSearch?(self) }
    }

    private func announceSearchIfNeeded() {
        guard !didAnnounceSearch else { return }
        didAnnounceSearch = true
        delegate?.netServiceBrowserWillSearch?(self)
    }

    private func apply(_ results: Set<NWBrowser.Result>, generation currentGeneration: UInt) {
        var grouped: [Identity: Set<NWBrowser.Result>] = [:]
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            grouped[Identity(name: name, type: type, domain: domain), default: []].insert(result)
        }

        // Use the full snapshot, not individual interface-removal events: losing
        // Wi-Fi must not remove a peer still present on Ethernet (or vice versa).
        for identity in Array(discoveries.keys) where grouped[identity] == nil {
            guard generation == currentGeneration else { return }
            guard let removed = discoveries.removeValue(forKey: identity) else { continue }
            removed.service.delegate = nil
            removed.service.stop()
            delegate?.netServiceBrowser?(self, didRemove: removed.service, moreComing: false)
        }
        for (identity, observations) in grouped {
            guard generation == currentGeneration else { return }
            if let existing = discoveries[identity] {
                guard existing.results != observations else { continue }
                existing.service.interfaceIndexes = interfaceIndexes(in: observations)
                discoveries[identity] = Discovery(service: existing.service, results: observations)
                delegate?.netServiceBrowser?(self, didUpdate: existing.service)
            } else {
                guard let result = observations.first,
                      case let .service(name, type, domain, _) = result.endpoint else { continue }
                let service = HorosBonjourService(domain: domain, type: type, name: name)
                service.interfaceIndexes = interfaceIndexes(in: observations)
                discoveries[identity] = Discovery(service: service, results: observations)
                delegate?.netServiceBrowser?(self, didFind: service, moreComing: false)
            }
        }
    }

    private func interfaceIndexes(in results: Set<NWBrowser.Result>) -> Set<UInt32> {
        Set(results.flatMap { result in
            var interfaces = result.interfaces
            if case let .service(_, _, _, interface) = result.endpoint, let interface {
                interfaces.append(interface)
            }
            return interfaces.compactMap { UInt32(exactly: $0.index) }
        })
    }

    private func fail(_ error: NWError) {
        let nsError = error as NSError
        let errorInfo: [String: Any] = [
            "code": nsError.code,
            "domain": nsError.domain,
            NSLocalizedDescriptionKey: nsError.localizedDescription
        ]
        let currentGeneration = generation
        // Clear this failed search before the consumer schedules a new browser.
        apply([], generation: currentGeneration)
        guard generation == currentGeneration else { return }
        delegate?.netServiceBrowser?(self, didNotSearch: errorInfo)
    }

    deinit {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        let services = discoveries.values.map(\.service)
        let cleanup = {
            for service in services {
                service.delegate = nil
                service.stop()
            }
        }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
    }
}
