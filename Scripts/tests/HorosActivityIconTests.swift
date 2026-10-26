// Foundation-only substitutes keep the production icon lifecycle under test
// without starting AppKit or changing the real Dock.
private enum MockDock {
    static var prepareCount = 0
    static var onPrepare: (() -> Void)?
}

private final class NSImage: NSObject {
    let name: String
    let size: NSSize
    let pixels: NSSize
    let prepared: Bool
    init?(named name: String) {
        self.name = name
        size = NSSize(width: name == "Horos.icns" ? 1024 : 512, height: name == "Horos.icns" ? 1024 : 512)
        pixels = size
        prepared = false
    }
    init(name: String, size: NSSize, scale: CGFloat) {
        self.name = name
        self.size = size
        pixels = NSSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        prepared = true
    }
}

private final class NSScreen {
    static var screens: [NSScreen] { [] }
    let backingScaleFactor: CGFloat = 2
}

private final class NSApplication {
    static let shared = NSApplication()
    final class DockTile { var size = NSSize(width: 128, height: 128) }
    let dockTile = DockTile()
    var onSet: (() -> Void)?
    var applicationIconImage: NSImage? {
        didSet {
            let callback = onSet
            onSet = nil
            callback?()
        }
    }
}

@main
@MainActor
private struct ActivityIconTests {
    static let coordinator = HorosActivityTaskCoordinator.shared
    private final class TokenBox: @unchecked Sendable {
        var token: HorosActivityToken?
    }

    static var timer: Timer? {
        Mirror(reflecting: coordinator).children.first { $0.label == "dockIconTimer" }?.value as? Timer
    }

    static func tick(_ timer: Timer) {
        coordinator.perform(NSSelectorFromString("toggleActivityDockIcon:"), with: timer)
    }

    static func drainUpdates() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    static func beginInBackground() -> HorosActivityToken {
        let box = TokenBox()
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            precondition(!Thread.isMainThread)
            box.token = HorosActivityToken.begin()
            ready.signal()
        }
        ready.wait()
        return box.token!
    }

    static func checkIdle() {
        precondition(!HorosActivityToken.hasActiveOperations, "Pending operation remained")
        precondition(timer == nil, "Blink timer remained")
        precondition(NSApplication.shared.applicationIconImage?.name == "Horos.icns", "Activity image remained")
        precondition(NSApplication.shared.applicationIconImage?.prepared == true, "Restored an unscaled bundle icon")
    }

    static func main() {
        let app = NSApplication.shared
        let first = HorosActivityToken.begin()
        let oldTimer = timer!
        precondition(app.applicationIconImage?.name == "HorosDownload.png")
        let activityIcon = app.applicationIconImage!
        let second = HorosActivityToken.begin()
        first.stop()
        precondition(timer === oldTimer && oldTimer.isValid)
        tick(oldTimer)
        precondition(app.applicationIconImage?.name == "Horos.icns")
        let regularIcon = app.applicationIconImage!
        precondition(regularIcon.size == activityIcon.size && regularIcon.pixels == activityIcon.pixels)
        tick(oldTimer)
        precondition(app.applicationIconImage?.name == "HorosDownload.png")
        precondition(MockDock.prepareCount == 2)
        second.stop()
        checkIdle()
        precondition(app.applicationIconImage === regularIcon)
        precondition(!oldTimer.isValid)

        let current = HorosActivityToken.begin()
        let currentTimer = timer!
        tick(oldTimer)
        precondition(timer === currentTimer)
        precondition(app.applicationIconImage?.name == "HorosDownload.png")
        current.stop()
        checkIdle()

        // A blink already queued when the final worker completes must stop,
        // even before that worker's main-run-loop refresh has been delivered.
        let pending = HorosActivityToken.begin()
        let pendingTimer = timer!
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            pending.stop()
            stopped.signal()
        }
        stopped.wait()
        precondition(!HorosActivityToken.hasActiveOperations)
        tick(pendingTimer)
        checkIdle()
        drainUpdates()

        // Completion can reenter while AppKit applies or prepares an icon.
        let applying = beginInBackground()
        app.onSet = { applying.stop() }
        coordinator.updateActivityDockIcon()
        checkIdle()
        drainUpdates()

        let preparing = beginInBackground()
        app.dockTile.size = NSSize(width: 160, height: 160)
        MockDock.onPrepare = { preparing.stop() }
        coordinator.updateActivityDockIcon()
        checkIdle()
        drainUpdates()

        let prepareCount = MockDock.prepareCount
        var cachedRegularIcon: NSImage?
        for _ in 0..<20 {
            // Never capture an old activity image as the icon to restore.
            app.applicationIconImage = NSImage(named: "HorosDownload.png")
            let operation = HorosActivityToken.begin()
            let active = app.applicationIconImage!
            precondition(active.size == app.dockTile.size && active.prepared)
            precondition(timer != nil)
            operation.stop()
            operation.stop()
            checkIdle()
            let idle = app.applicationIconImage!
            precondition(idle.size == active.size && idle.pixels == active.pixels)
            if let cachedRegularIcon { precondition(idle === cachedRegularIcon) }
            cachedRegularIcon = idle
        }
        precondition(MockDock.prepareCount == prepareCount, "Rerasterized on every start/stop")
        print("Dock lifecycle, stable icon sizes, cache reuse, stale timer, and nested callback checks passed")
    }
}
