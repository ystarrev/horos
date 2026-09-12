import Dispatch
import Foundation

enum MetalViewerCachePolicy {
    // Retention budgets only: active images and in-flight work have separate owners.
    static let volumeCacheBytes = Int(min(ProcessInfo.processInfo.physicalMemory / 8, 1_500_000_000))
    static let readerCacheBytes = Int(min(ProcessInfo.processInfo.physicalMemory / 32, 512 * 1_024 * 1_024))
    static let renderVolumeCacheBytes = Int(min(ProcessInfo.processInfo.physicalMemory / 32, 512 * 1_024 * 1_024))
}

final class MetalViewerCacheMemoryPressureObserver {
    private let source: DispatchSourceMemoryPressure

    // Change future retention, rather than paging in old cache objects to purge them.
    init(handler: @escaping (Bool) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "org.horos.metalviewer.cache-pressure", qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.source.data
            if events.contains(.warning) || events.contains(.critical) {
                handler(true)
            } else if events.contains(.normal) {
                handler(false)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
