import Foundation

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

    private var activities: [ObjectIdentifier: HorosActivityTask] = [:]
    private var completionHandlers: [ObjectIdentifier: [UUID: () -> Void]] = [:]

    @objc(registerThread:)
    func register(thread: Thread) -> HorosActivityTask {
        let activity = activity(for: thread, createIfNeeded: true)!
        activity.isListed = true
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
}
