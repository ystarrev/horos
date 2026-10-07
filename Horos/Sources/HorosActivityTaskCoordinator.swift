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

    private static let activityDockIcon = NSImage(named: "HorosDownload.png")
    private static let normalDockIcon = NSImage(named: "Horos.icns")

    private var activities: [ObjectIdentifier: HorosActivityTask] = [:]
    private var completionHandlers: [ObjectIdentifier: [UUID: () -> Void]] = [:]
    private var regularDockIcon: NSImage?
    private var preparedRegularDockIcon: NSImage?
    private var preparedActivityDockIcon: NSImage?
    private var preparedDockSize = NSSize.zero
    private var preparedDockScale: CGFloat = 0
    private var dockIconTimer: Timer?
    private var isActivityDockIconVisible = false

    private override init() {
        super.init()
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
        if !hasListedActivities {
            guard dockIconTimer != nil else { return }
            dockIconTimer?.invalidate()
            dockIconTimer = nil
            NSApplication.shared.applicationIconImage = regularDockIcon
            regularDockIcon = nil
            preparedRegularDockIcon = nil
            preparedActivityDockIcon = nil
            isActivityDockIconVisible = false
            return
        }
        guard dockIconTimer == nil else { return }
        regularDockIcon = NSApplication.shared.applicationIconImage
        setActivityDockIconVisible(true)
        let timer = Timer(timeInterval: 0.5, target: self,
                          selector: #selector(toggleActivityDockIcon(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        dockIconTimer = timer
    }

    @objc private func toggleActivityDockIcon(_ timer: Timer) {
        setActivityDockIconVisible(!isActivityDockIconVisible)
    }

    private func setActivityDockIconVisible(_ visible: Bool) {
        guard isActivityDockIconVisible != visible else { return }
        let reportedSize = NSApplication.shared.dockTile.size
        let size = reportedSize.width > 0 && reportedSize.height > 0
            ? reportedSize : NSSize(width: 128, height: 128)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        // Rasterize and colour-convert once, not every blink. Rebuild only if the
        // Dock size or display scale changes; retain the original for restoration.
        if preparedRegularDockIcon == nil || preparedActivityDockIcon == nil ||
            preparedDockSize != size || preparedDockScale != scale {
            // applicationIconImage may be nil when AppKit is using the bundle icon.
            preparedRegularDockIcon = Self.prepareDockIcon(Self.normalDockIcon, size: size, scale: scale)
            preparedActivityDockIcon = Self.prepareDockIcon(Self.activityDockIcon, size: size, scale: scale)
            preparedDockSize = size
            preparedDockScale = scale
        }
        let icon = visible ? (preparedActivityDockIcon ?? Self.activityDockIcon)
            : (preparedRegularDockIcon ?? Self.normalDockIcon)
        guard let icon else { return }
        NSApplication.shared.applicationIconImage = icon
        isActivityDockIconVisible = visible
    }

    private static func prepareDockIcon(_ image: NSImage?, size: NSSize, scale: CGFloat) -> NSImage? {
        guard let image, size.width > 0, size.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                      height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = context.makeImage() else { return nil }
        return NSImage(cgImage: raster, size: size)
    }
}
