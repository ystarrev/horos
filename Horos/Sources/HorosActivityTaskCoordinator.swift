import AppKit

@objc(HorosActivityTask)
final class HorosActivityTask: NSObject {
    @objc let thread: Thread
    @objc dynamic fileprivate(set) var isCompleted = false

    fileprivate var isListed = false

    fileprivate init(thread: Thread) {
        self.thread = thread
        super.init()
    }
}

@MainActor
@objc(HorosActivityTaskCoordinator)
final class HorosActivityTaskCoordinator: NSObject {
    @objc(sharedCoordinator)
    static let shared = HorosActivityTaskCoordinator()

    private static let dockIconBlinkInterval: TimeInterval = 0.5
    private static let regularDockIcon = dockIcon(named: "Horos.icns")
    private static let activityDockIcon = dockIcon(named: "HorosDownload.png")

    private var activities: [ObjectIdentifier: HorosActivityTask] = [:]
    private var completionHandlers: [ObjectIdentifier: [UUID: () -> Void]] = [:]
    private var dockIconTimer: Timer?
    private var isActivityDockIconVisible = false

    private override init() {
        super.init()
        NSApplication.shared.applicationIconImage = Self.regularDockIcon
    }

    @objc(registerThread:)
    func register(thread: Thread) -> HorosActivityTask {
        let activity = activity(for: thread, createIfNeeded: true)!
        activity.isListed = true
        updateActivityDockIcon()
        return activity
    }

    @objc(addCompletionHandlerForThread:handler:)
    @discardableResult
    func addCompletionHandler(for thread: Thread, handler: @escaping () -> Void) -> UUID {
        let key = ObjectIdentifier(thread)
        _ = activity(for: thread, createIfNeeded: true)

        let token = UUID()
        completionHandlers[key, default: [:]][token] = handler
        return token
    }

    @objc(removeCompletionHandlerForThread:token:)
    func removeCompletionHandler(for thread: Thread, token: UUID) {
        let key = ObjectIdentifier(thread)
        completionHandlers[key]?[token] = nil

        if completionHandlers[key]?.isEmpty == true {
            completionHandlers[key] = nil
        }

        if completionHandlers[key] == nil, activities[key]?.isListed == false {
            activities[key] = nil
        }
    }

    @objc(completeRegisteredThread:)
    func completeRegisteredThread(_ thread: Thread) {
        let key = ObjectIdentifier(thread)
        guard let activity = activities.removeValue(forKey: key) else {
            return
        }

        activity.isCompleted = true
        let handlers = completionHandlers.removeValue(forKey: key)?.values ?? [:].values
        for handler in handlers {
            handler()
        }
        updateActivityDockIcon()
    }

    @objc(completeThread:)
    nonisolated static func complete(thread: Thread) {
        Task { @MainActor in
            shared.completeRegisteredThread(thread)
        }
    }

    private func activity(for thread: Thread, createIfNeeded: Bool) -> HorosActivityTask? {
        let key = ObjectIdentifier(thread)
        if let activity = activities[key] {
            return activity
        }

        guard createIfNeeded else {
            return nil
        }

        let activity = HorosActivityTask(thread: thread)
        activities[key] = activity
        return activity
    }

    private func updateActivityDockIcon() {
        let hasListedActivities = activities.values.contains(where: \.isListed)
        guard hasListedActivities else {
            dockIconTimer?.invalidate()
            dockIconTimer = nil
            setActivityDockIconVisible(false)
            return
        }

        guard dockIconTimer == nil else { return }
        setActivityDockIconVisible(true)

        let timer = Timer(
            timeInterval: Self.dockIconBlinkInterval,
            target: self,
            selector: #selector(toggleActivityDockIcon(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        dockIconTimer = timer
    }

    @objc private func toggleActivityDockIcon(_ timer: Timer) {
        setActivityDockIconVisible(isActivityDockIconVisible == false)
    }

    private func setActivityDockIconVisible(_ visible: Bool) {
        guard isActivityDockIconVisible != visible else { return }
        isActivityDockIconVisible = visible
        NSApplication.shared.applicationIconImage = visible ? Self.activityDockIcon : Self.regularDockIcon
    }

    private static func dockIcon(named name: NSImage.Name) -> NSImage? {
        guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 1_024, height: 1_024)
        return image
    }
}
