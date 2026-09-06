import AppKit

enum MetalViewerScreenPlacement {
    private enum DefaultsKey {
        static let nonViewerScreens = "NonViewerScreens"
        static let reserveScreenForDatabase = "ReserveScreenForDB"
    }

    static func applyPresentationFrame(to window: NSWindow?, display: Bool) {
        guard let window, let screen = screenForNewViewerWindow(window) else { return }
        window.setFrame(screen.visibleFrame.integral, display: display)
    }

    private static func screenForNewViewerWindow(_ window: NSWindow) -> NSScreen? {
        let viewerScreens = screensUsedForViewers()

        if let windowScreen = window.screen,
           viewerScreens.contains(where: { sameScreen($0, windowScreen) }) {
            return windowScreen
        }

        if let mainScreen = NSScreen.main,
           viewerScreens.contains(where: { sameScreen($0, mainScreen) }) {
            return mainScreen
        }

        return viewerScreens.first ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func screensUsedForViewers() -> [NSScreen] {
        let allScreens = sortLeftToRight(NSScreen.screens)
        guard allScreens.isEmpty == false else { return [] }

        let defaults = UserDefaults.standard
        let nonViewerScreenNumbers = configuredNonViewerScreenNumbers(defaults: defaults, screens: allScreens)
        var viewerScreens = allScreens.filter { screen in
            guard let screenNumber = screenNumber(for: screen) else { return true }
            return nonViewerScreenNumbers.contains(screenNumber) == false
        }

        if viewerScreens.isEmpty {
            viewerScreens = allScreens
        }

        if defaults.bool(forKey: DefaultsKey.reserveScreenForDatabase),
           viewerScreens.count > 1,
           let databaseScreen = BrowserController.currentBrowser()?.window?.screen {
            viewerScreens.removeAll { sameScreen($0, databaseScreen) }
        }

        if viewerScreens.isEmpty {
            viewerScreens = allScreens
        }

        return sortLeftToRight(viewerScreens)
    }

    private static func configuredNonViewerScreenNumbers(defaults: UserDefaults, screens: [NSScreen]) -> Set<UInt32> {
        if defaults.object(forKey: DefaultsKey.nonViewerScreens) != nil {
            return screenNumbers(from: defaults.array(forKey: DefaultsKey.nonViewerScreens) ?? [])
        }

        if defaults.integer(forKey: DefaultsKey.reserveScreenForDatabase) == 2 {
            let mainScreen = NSScreen.main ?? screens.first
            return Set(screens.compactMap { screen in
                if let mainScreen, sameScreen(screen, mainScreen) {
                    return nil
                }
                return screenNumber(for: screen)
            })
        }

        return []
    }

    private static func screenNumbers(from values: [Any]) -> Set<UInt32> {
        Set(values.compactMap { value in
            if let number = value as? NSNumber {
                return number.uint32Value
            }
            if let integer = value as? Int {
                return UInt32(integer)
            }
            if let string = value as? String {
                return UInt32(string)
            }
            return nil
        })
    }

    private static func screenNumber(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func sameScreen(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        if let lhsNumber = screenNumber(for: lhs), let rhsNumber = screenNumber(for: rhs) {
            return lhsNumber == rhsNumber
        }
        return lhs === rhs
    }

    private static func sortLeftToRight(_ screens: [NSScreen]) -> [NSScreen] {
        screens.sorted {
            let lhsCenterX = $0.frame.midX
            let rhsCenterX = $1.frame.midX
            if lhsCenterX == rhsCenterX {
                return $0.frame.midY < $1.frame.midY
            }
            return lhsCenterX < rhsCenterX
        }
    }
}

@objc(HorosMetalViewerLauncher)
final class MetalViewerLauncher: NSObject {
    private static var retainedControllers: [MetalViewerWindowController] = []
    private static var refreshContexts: [ObjectIdentifier: [ViewerRefreshContext]] = [:]
    private static var databaseAddObserver: NSObjectProtocol?
    private static var pendingDatabaseRefresh: DispatchWorkItem?
    private static var pendingRefreshIdentifiers: RefreshIdentifiers?
    private static var pendingRefreshStartedAt: CFAbsoluteTime?
    private static let patientBirthDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func phoneROISnapshot() -> [String: [MetalStudyROI]] {
        precondition(Thread.isMainThread)
        var result: [String: [MetalStudyROI]] = [:]
        for controller in retainedControllers where controller.window?.isVisible == true {
            for (study, rois) in controller.phoneROISnapshot() { result[study] = rois }
        }
        return result
    }

    @objc(visibleWindows)
    class func visibleWindows() -> [NSWindow] {
        retainedControllers.compactMap { $0.window }.filter { $0.isVisible }
    }

    @objc(closeAllWindows)
    class func closeAllWindows() {
        retainedControllers.compactMap { $0.window }.forEach { $0.close() }
    }

    @objc(canAddPatientToCurrentViewer)
    class func canAddPatientToCurrentViewer() -> Bool {
        frontmostController()?.canAddPatient
            ?? false
    }

    @objc(addPatientWithContext:)
    class func addPatient(withContext context: NSDictionary) {
        guard let controller = frontmostController(),
              let pixList = context["pixList"] as? NSArray,
              let frames = pixList as? [DCMPix],
              let title = context["title"] as? String,
              frames.isEmpty == false else {
            NSSound.beep()
            return
        }
        let forceDynamicInterpretation = (context["forceDynamicInterpretation"] as? NSNumber)?.boolValue ?? false
        let identifiers = refreshIdentifiers(from: frames)
        let initialStudy = buildInitialStudy(
            from: frames,
            fallbackTitle: title,
            forceDynamicInterpretation: forceDynamicInterpretation
        )
        guard controller.addPatientStudy(initialStudy, selectInitialSeries: true) else { return }
        upsertRefreshContext(
            ViewerRefreshContext(
                frames: frames,
                fallbackTitle: title,
                identifiers: identifiers,
                forceDynamicInterpretation: forceDynamicInterpretation
            ),
            for: controller
        )
        ensureDatabaseAddObserver()
        controller.window?.makeKeyAndOrderFront(NSApp)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            let fullStudy = buildStudy(
                from: frames,
                fallbackTitle: title,
                forceDynamicInterpretation: forceDynamicInterpretation,
                markScoutStudiesOpened: true
            )
            controller.updatePatientStudy(
                fullStudy,
                selectInitialSeries: true,
                revealSelectedSeriesInScout: true
            )
        }
    }

    private class func frontmostController() -> MetalViewerWindowController? {
        if let keyWindow = NSApp.keyWindow,
           let controller = retainedControllers.first(where: { $0.window === keyWindow }) {
            return controller
        }
        return retainedControllers.reversed().first { $0.window?.isVisible == true }
    }

    private enum DefaultsKey {
        static let incomingImportCoalescingDelay = "HorosIncomingImportCoalescingDelay"
        static let databaseRefreshDelay = "HorosMetalViewerDatabaseRefreshDelay"
        static let databaseRefreshMaxDeferral = "HorosMetalViewerDatabaseRefreshMaxDeferral"
    }

    private struct ViewerRefreshContext {
        let frames: [DCMPix]
        let fallbackTitle: String
        let identifiers: RefreshIdentifiers
        let forceDynamicInterpretation: Bool
    }

    private struct RefreshIdentifiers {
        var studyUIDs: Set<String> = []
        var patientUIDs: Set<String> = []
        var seriesUIDs: Set<String> = []
        var objectURIs: Set<String> = []

        var isEmpty: Bool {
            return studyUIDs.isEmpty && patientUIDs.isEmpty && seriesUIDs.isEmpty && objectURIs.isEmpty
        }

        mutating func formUnion(_ other: RefreshIdentifiers) {
            studyUIDs.formUnion(other.studyUIDs)
            patientUIDs.formUnion(other.patientUIDs)
            seriesUIDs.formUnion(other.seriesUIDs)
            objectURIs.formUnion(other.objectURIs)
        }

        func intersects(_ other: RefreshIdentifiers) -> Bool {
            if studyUIDs.isDisjoint(with: other.studyUIDs) == false { return true }
            if patientUIDs.isDisjoint(with: other.patientUIDs) == false { return true }
            if seriesUIDs.isDisjoint(with: other.seriesUIDs) == false { return true }
            if objectURIs.isDisjoint(with: other.objectURIs) == false { return true }
            return false
        }
    }

    private struct SeriesImageGroup {
        let identifier: String
        let title: String
        let imageObjects: [NSManagedObject]
        let containsCurrentImage: Bool
        let initialPixList: [DCMPix]?
    }

    private struct CrossSeriesIdentityKey: Hashable {
        let modality: String
        let seriesDescription: String
        let protocolName: String
        let sequenceName: String
        let frameOfReferenceUID: String
        let dimensions: String
        let orientation: String
        let pixelSpacing: String
        let echoTime: String
    }

    private struct CrossSeriesTemporalKey: Hashable {
        let identity: CrossSeriesIdentityKey
        let imageCount: Int
        let slicePositions: String
    }

    private struct CrossSeriesTemporalMetadata {
        let key: CrossSeriesTemporalKey
        let temporalPositionCount: Int
        let acquisitionNumber: Int
        let seriesNumber: Int?
        let acquisitionSeconds: Double
    }

    private struct CrossSeriesSlicePartitionKey: Hashable {
        let identity: CrossSeriesIdentityKey
        let timePointCount: Int
    }

    private struct CrossSeriesSlicePartitionMetadata {
        let key: CrossSeriesSlicePartitionKey
        let spatialPosition: String
        let acquisitionNumbers: [Int]
    }

    private struct CrossSeriesMetadata {
        let temporal: CrossSeriesTemporalMetadata
        let slicePartition: CrossSeriesSlicePartitionMetadata?
    }

    private struct PendingSeriesPresentation {
        let imageGroup: SeriesImageGroup
        let displaySeriesNumber: String
        let crossSeriesMetadata: CrossSeriesMetadata?
    }

    private struct CombinedSeriesPresentation {
        let anchorIndex: Int
        let memberIndexes: [Int]
        let orderedImageObjects: [NSManagedObject]
        let timePointCount: Int
    }

    private struct SeriesPresentation {
        let identifier: String
        let title: String
        let seriesNumber: String
        let imageObjects: [NSManagedObject]
        let containsCurrentImage: Bool
        let initialPixList: [DCMPix]?
        let sourceSeriesIdentifiers: Set<String>
        let dynamicTimePointCountHint: Int?
    }

    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        guard let pixList = context["pixList"] as? NSArray,
              let frames = pixList as? [DCMPix],
              let title = context["title"] as? String,
              frames.isEmpty == false else {
            NSSound.beep()
            return
        }
        let forceDynamicInterpretation = (context["forceDynamicInterpretation"] as? NSNumber)?.boolValue ?? false

        let launchIdentifiers = refreshIdentifiers(from: frames)
        if let existingController = existingController(matching: launchIdentifiers) {
            upsertRefreshContext(ViewerRefreshContext(
                frames: frames,
                fallbackTitle: title,
                identifiers: launchIdentifiers,
                forceDynamicInterpretation: forceDynamicInterpretation
            ), for: existingController)
            ensureDatabaseAddObserver()

            let fullStudy = buildStudy(
                from: frames,
                fallbackTitle: title,
                forceDynamicInterpretation: forceDynamicInterpretation,
                markScoutStudiesOpened: true
            )
            existingController.updatePatientStudy(
                fullStudy,
                selectInitialSeries: true,
                revealSelectedSeriesInScout: true
            )
            existingController.window?.makeKeyAndOrderFront(NSApp)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let study = buildInitialStudy(
            from: frames,
            fallbackTitle: title,
            forceDynamicInterpretation: forceDynamicInterpretation
        )
        let controller = MetalViewerWindowController(study: study)
        retainedControllers.append(controller)
        upsertRefreshContext(ViewerRefreshContext(
            frames: frames,
            fallbackTitle: title,
            identifiers: launchIdentifiers,
            forceDynamicInterpretation: forceDynamicInterpretation
        ), for: controller)
        ensureDatabaseAddObserver()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak controller] _ in
            guard let controller else { return }
            retainedControllers.removeAll { $0 === controller }
            refreshContexts.removeValue(forKey: ObjectIdentifier(controller))
        }

        applyFastPresentationFrame(to: controller.window)
        controller.restoreSavedSplitPositionForPresentation()

        controller.window?.makeKeyAndOrderFront(NSApp)

        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            let fullStudy = buildStudy(
                from: frames,
                fallbackTitle: title,
                forceDynamicInterpretation: forceDynamicInterpretation,
                markScoutStudiesOpened: true
            )
            controller.updateStudy(
                fullStudy,
                selectInitialSeries: forceDynamicInterpretation,
                revealSelectedSeriesInScout: true
            )
        }
    }

    private class func ensureDatabaseAddObserver() {
        guard databaseAddObserver == nil else { return }

        databaseAddObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("OsirixAddToDBNotification"),
            object: nil,
            queue: .main
        ) { notification in
            Self.scheduleDatabaseRefresh(for: notification)
        }
    }

    private class func existingController(matching identifiers: RefreshIdentifiers) -> MetalViewerWindowController? {
        guard identifiers.isEmpty == false else { return nil }

        for controller in retainedControllers {
            guard let contexts = refreshContexts[ObjectIdentifier(controller)] else { continue }
            if contexts.contains(where: { $0.identifiers.intersects(identifiers) }) {
                return controller
            }
        }

        return nil
    }

    private class func upsertRefreshContext(
        _ context: ViewerRefreshContext,
        for controller: MetalViewerWindowController
    ) {
        let identifier = ObjectIdentifier(controller)
        var contexts = refreshContexts[identifier] ?? []
        if let index = contexts.firstIndex(where: {
            $0.identifiers.intersects(context.identifiers)
        }) {
            contexts[index] = context
        } else {
            contexts.append(context)
        }
        refreshContexts[identifier] = contexts
    }

    private class func scheduleDatabaseRefresh(for notification: Notification) {
        let identifiers = refreshIdentifiers(from: notification)
        if identifiers == nil {
            pendingRefreshIdentifiers = nil
        } else if identifiers!.isEmpty {
            return
        } else if pendingRefreshIdentifiers == nil {
            pendingRefreshIdentifiers = identifiers
        } else {
            pendingRefreshIdentifiers?.formUnion(identifiers!)
        }

        let now = CFAbsoluteTimeGetCurrent()
        if pendingRefreshStartedAt == nil {
            pendingRefreshStartedAt = now
        }

        pendingDatabaseRefresh?.cancel()

        let delay = databaseRefreshDelay()
        let maxDeferral = databaseRefreshMaxDeferral(forDelay: delay)
        let elapsed = now - (pendingRefreshStartedAt ?? now)
        let scheduledDelay = max(0, min(delay, maxDeferral - elapsed))

        let workItem = DispatchWorkItem {
            let identifiers = pendingRefreshIdentifiers
            pendingRefreshIdentifiers = nil
            pendingRefreshStartedAt = nil
            pendingDatabaseRefresh = nil
            Self.refreshOpenViewersFromDatabase(matching: identifiers)
        }
        pendingDatabaseRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scheduledDelay, execute: workItem)
    }

    private class func databaseRefreshDelay() -> TimeInterval {
        let defaults = UserDefaults.standard
        if let configuredValue = defaults.object(forKey: DefaultsKey.databaseRefreshDelay) as? NSNumber {
            return clampedRefreshInterval(configuredValue.doubleValue, minimum: 0.1, maximum: 30)
        }

        if let configuredValue = defaults.object(forKey: DefaultsKey.incomingImportCoalescingDelay) as? NSNumber {
            return clampedRefreshInterval(configuredValue.doubleValue + 0.2, minimum: 0.4, maximum: 30)
        }

        return 2.2
    }

    private class func databaseRefreshMaxDeferral(forDelay delay: TimeInterval) -> TimeInterval {
        let defaults = UserDefaults.standard
        if let configuredValue = defaults.object(forKey: DefaultsKey.databaseRefreshMaxDeferral) as? NSNumber {
            return clampedRefreshInterval(configuredValue.doubleValue, minimum: delay, maximum: 120)
        }

        return max(8, delay * 4)
    }

    private class func clampedRefreshInterval(_ value: TimeInterval, minimum: TimeInterval, maximum: TimeInterval) -> TimeInterval {
        if value.isNaN {
            return minimum
        }
        return min(max(value, minimum), maximum)
    }

    private class func refreshOpenViewersFromDatabase(matching importedIdentifiers: RefreshIdentifiers?) {
        for controller in retainedControllers {
            let controllerIdentifier = ObjectIdentifier(controller)
            guard let contexts = refreshContexts[controllerIdentifier] else { continue }
            for context in contexts {
                if let importedIdentifiers = importedIdentifiers,
                   importedIdentifiers.isEmpty == false,
                   context.identifiers.isEmpty == false,
                   context.identifiers.intersects(importedIdentifiers) == false {
                    continue
                }

                let updatedStudy = buildStudy(
                    from: context.frames,
                    fallbackTitle: context.fallbackTitle,
                    forceDynamicInterpretation: context.forceDynamicInterpretation,
                    markScoutStudiesOpened: false
                )
                controller.updatePatientStudy(updatedStudy)
            }
        }
    }

    private class func refreshIdentifiers(from notification: Notification) -> RefreshIdentifiers? {
        guard let images = notification.userInfo?["OsiriXAddToDBArray"] as? [NSManagedObject] else {
            return nil
        }

        return refreshIdentifiers(from: images)
    }

    private class func refreshIdentifiers(from frames: [DCMPix]) -> RefreshIdentifiers {
        let imageObjects = frames.compactMap {
            $0.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject
        }
        return refreshIdentifiers(from: imageObjects)
    }

    private class func refreshIdentifiers(from imageObjects: [NSManagedObject]) -> RefreshIdentifiers {
        var identifiers = RefreshIdentifiers()

        for imageObject in imageObjects {
            identifiers.objectURIs.insert(imageObject.objectID.uriRepresentation().absoluteString)

            if let studyUID = imageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String, studyUID.isEmpty == false {
                identifiers.studyUIDs.insert(studyUID)
            }

            if let patientUID = imageObject.value(forKeyPath: "series.study.patientUID") as? String, patientUID.isEmpty == false {
                identifiers.patientUIDs.insert(patientUID)
            }

            if let series = imageObject.value(forKey: "series") as? NSManagedObject {
                identifiers.seriesUIDs.insert(series.objectID.uriRepresentation().absoluteString)

                if let seriesDICOMUID = series.value(forKey: "seriesDICOMUID") as? String, seriesDICOMUID.isEmpty == false {
                    identifiers.seriesUIDs.insert(seriesDICOMUID)
                }

                if let seriesInstanceUID = series.value(forKey: "seriesInstanceUID") as? String, seriesInstanceUID.isEmpty == false {
                    identifiers.seriesUIDs.insert(seriesInstanceUID)
                }
            }
        }

        return identifiers
    }

    private class func applyFastPresentationFrame(to window: NSWindow?) {
        MetalViewerScreenPlacement.applyPresentationFrame(to: window, display: true)
    }

    private class func patientWindowTitle(
        patientName: String?,
        patientID: String?,
        dateOfBirth: Date?,
        fallbackTitle: String
    ) -> String {
        let name = patientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = patientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let patientTitle: String

        if name.isEmpty == false, identifier.isEmpty == false {
            patientTitle = "\(name) (\(identifier))"
        } else if name.isEmpty == false {
            patientTitle = name
        } else if identifier.isEmpty == false {
            patientTitle = identifier
        } else {
            patientTitle = fallbackTitle
        }

        guard let dateOfBirth else { return patientTitle }
        var demographics = ["DOB \(patientBirthDateFormatter.string(from: dateOfBirth))"]
        if let age = currentPatientAge(dateOfBirth: dateOfBirth) {
            demographics.append("age \(age)")
        }
        return "\(patientTitle) [\(demographics.joined(separator: ", "))]"
    }

    private class func currentPatientAge(dateOfBirth: Date) -> String? {
        let today = Date()
        guard dateOfBirth <= today else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: dateOfBirth, to: today)
        let years = max(components.year ?? 0, 0)
        let months = max(components.month ?? 0, 0)
        let days = max(components.day ?? 0, 0)

        if years >= 2 {
            return "\(years) y"
        }
        if years == 1 {
            return "1 y \(months) m"
        }
        if months >= 1 {
            return "\(months) m"
        }
        return "\(days) d"
    }

    private class func seriesNumber(from seriesObject: NSManagedObject?) -> String {
        if let value = seriesObject?.value(forKey: "id") as? NSNumber {
            return value.stringValue
        }
        if let value = seriesObject?.value(forKey: "id") as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private class func patientIdentity(
        patientUID: String?,
        patientName: String?,
        patientID: String?,
        dateOfBirth: Date?,
        fallbackTitle: String
    ) -> MetalViewerPatientIdentity {
        let trimmedName = patientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedName.isEmpty ? fallbackTitle : trimmedName
        let normalizedPatientID = patientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedUID = patientUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let birthComponent = dateOfBirth.map { patientBirthDateFormatter.string(from: $0) } ?? ""
        let normalizedName = displayName.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let identifier = normalizedUID.isEmpty == false
            ? "patient-uid:\(normalizedUID.lowercased())"
            : "demographics:\(normalizedName)|\(birthComponent)|\(normalizedPatientID.lowercased())"
        return MetalViewerPatientIdentity(
            identifier: identifier,
            displayName: displayName,
            patientID: normalizedPatientID,
            dateOfBirth: dateOfBirth
        )
    }

    private class func buildInitialStudy(
        from frames: [DCMPix],
        fallbackTitle: String,
        forceDynamicInterpretation: Bool
    ) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject else {
            let patientIdentity = MetalViewerPatientIdentity.fallback(title: fallbackTitle)
            let series = MetalViewerSeries(
                patientIdentity: patientIdentity,
                title: fallbackTitle,
                seriesNumber: "",
                studyIdentifier: UUID().uuidString,
                studyTitle: fallbackTitle,
                studyDate: nil,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: (BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false),
                initialPixList: frames,
                forceDynamicInterpretation: forceDynamicInterpretation
            )
            return MetalViewerStudy(patientIdentity: patientIdentity, title: fallbackTitle, series: [series], initialSeriesIdentifier: series.identifier)
        }

        let isBonjour = BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false
        let currentSeriesObject = currentImageObject.value(forKeyPath: "series") as? NSManagedObject
        let currentSeriesID = currentSeriesObject?.objectID.uriRepresentation().absoluteString
            ?? String(describing: currentImageObject.value(forKeyPath: "series.id") ?? "current-series")
        let seriesTitle = ((currentSeriesObject?.value(forKey: "name") as? String)?.isEmpty == false ? (currentSeriesObject?.value(forKey: "name") as? String) : nil)
            ?? ((currentSeriesObject?.value(forKey: "seriesDescription") as? String)?.isEmpty == false ? (currentSeriesObject?.value(forKey: "seriesDescription") as? String) : nil)
            ?? fallbackTitle
        let patientName = currentImageObject.value(forKeyPath: "series.study.name") as? String
        let patientID = currentImageObject.value(forKeyPath: "series.study.patientID") as? String
        let dateOfBirth = currentImageObject.value(forKeyPath: "series.study.dateOfBirth") as? Date
        let patientUID = currentImageObject.value(forKeyPath: "series.study.patientUID") as? String
        let patientIdentity = patientIdentity(
            patientUID: patientUID,
            patientName: patientName,
            patientID: patientID,
            dateOfBirth: dateOfBirth,
            fallbackTitle: fallbackTitle
        )
        let studyDate = currentImageObject.value(forKeyPath: "series.study.date") as? Date
        let studyTitle = patientWindowTitle(
            patientName: patientName,
            patientID: patientID,
            dateOfBirth: dateOfBirth,
            fallbackTitle: fallbackTitle
        )
        let studyIdentifier = (currentImageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String)
            ?? String(describing: currentImageObject.value(forKeyPath: "series.study") ?? UUID().uuidString)
        let series = MetalViewerSeries(
            identifier: currentSeriesID,
            patientIdentity: patientIdentity,
            title: seriesTitle,
            seriesNumber: seriesNumber(from: currentSeriesObject),
            studyIdentifier: studyIdentifier,
            studyTitle: studyTitle,
            studyDate: studyDate,
            studyNumber: 1,
            showsStudyHeader: true,
            imageObjects: [],
            isBonjour: isBonjour,
            initialPixList: frames,
            forceDynamicInterpretation: forceDynamicInterpretation
        )
        return MetalViewerStudy(patientIdentity: patientIdentity, title: studyTitle, series: [series], initialSeriesIdentifier: currentSeriesID)
    }

    private class func buildStudy(
        from frames: [DCMPix],
        fallbackTitle: String,
        forceDynamicInterpretation: Bool,
        markScoutStudiesOpened: Bool
    ) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject,
              let currentStudy = currentImageObject.value(forKeyPath: "series.study") as? DicomStudy else {
            let patientIdentity = MetalViewerPatientIdentity.fallback(title: fallbackTitle)
            let series = MetalViewerSeries(
                patientIdentity: patientIdentity,
                title: fallbackTitle,
                seriesNumber: "",
                studyIdentifier: UUID().uuidString,
                studyTitle: fallbackTitle,
                studyDate: nil,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: (BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false),
                initialPixList: frames,
                forceDynamicInterpretation: forceDynamicInterpretation
            )
            return MetalViewerStudy(patientIdentity: patientIdentity, title: fallbackTitle, series: [series], initialSeriesIdentifier: series.identifier)
        }

        refreshObjectGraphAfterImport(currentImageObject)

        let browser = BrowserController.currentBrowser()
        let relatedStudies = databaseRelatedStudies(for: currentStudy, browser: browser)
        let procedureEvents = browser?
            .perform(NSSelectorFromString("surgicalProcedureEventsForStudy:"), with: currentStudy)?
            .takeUnretainedValue() as? [SurgicalProcedureEvent] ?? []

        var uniqueStudies = relatedStudies.filter {
            $0.isDeleted == false && $0.managedObjectContext != nil
        }
        if uniqueStudies.contains(where: { ($0.studyInstanceUID ?? "") == (currentStudy.studyInstanceUID ?? "") }) == false {
            uniqueStudies.append(currentStudy)
        }

        let sortedStudies = uniqueStudies
            .filter { study in
                (study.value(forKey: "series") as? NSSet)?.count ?? 0 > 0
            }
            .sorted {
                let lhs = $0.date ?? .distantPast
                let rhs = $1.date ?? .distantPast
                if lhs != rhs {
                    return lhs > rhs
                }
                return ($0.studyInstanceUID ?? "") < ($1.studyInstanceUID ?? "")
            }

        let isBonjour = browser?.isCurrentDatabaseBonjour ?? false
        let currentSeriesObject = currentImageObject.value(forKeyPath: "series") as? NSManagedObject
        var currentSeriesID = currentSeriesObject?.objectID.uriRepresentation().absoluteString
            ?? String(describing: currentImageObject.value(forKeyPath: "series.id") ?? "current-series")
        let studyTitle = patientWindowTitle(
            patientName: currentStudy.name,
            patientID: currentStudy.patientID,
            dateOfBirth: currentStudy.dateOfBirth,
            fallbackTitle: fallbackTitle
        )
        let patientIdentity = patientIdentity(
            patientUID: currentStudy.patientUID,
            patientName: currentStudy.name,
            patientID: currentStudy.patientID,
            dateOfBirth: currentStudy.dateOfBirth,
            fallbackTitle: fallbackTitle
        )

        var flattenedSeries: [MetalViewerSeries] = []
        var additionalScoutStudies: [DicomStudy] = []

        for (studyIndex, study) in sortedStudies.enumerated() {
            guard let browser else { continue }
            let seriesCountBeforeStudy = flattenedSeries.count
            let seriesObjects = browser.childrenArray(study, onlyImages: false) as? [NSManagedObject] ?? []
            var pendingPresentations: [PendingSeriesPresentation] = []

            for seriesObject in seriesObjects {
                guard shouldShowInScout(seriesObject) else { continue }
                let images = browser.childrenArray(seriesObject) as? [NSManagedObject] ?? []
                guard images.isEmpty == false else { continue }

                let baseTitle = ((seriesObject.value(forKey: "name") as? String)?.isEmpty == false ? (seriesObject.value(forKey: "name") as? String) : nil)
                    ?? ((seriesObject.value(forKey: "seriesDescription") as? String)?.isEmpty == false ? (seriesObject.value(forKey: "seriesDescription") as? String) : nil)
                    ?? NSLocalizedString("Series", comment: "")
                let imageGroups = splitSeriesImages(
                    images,
                    seriesObject: seriesObject,
                    baseTitle: baseTitle,
                    currentImageObject: currentImageObject,
                    frames: frames
                )
                let displaySeriesNumber = seriesNumber(from: seriesObject)

                for imageGroup in imageGroups {
                    pendingPresentations.append(
                        PendingSeriesPresentation(
                            imageGroup: imageGroup,
                            displaySeriesNumber: displaySeriesNumber,
                            crossSeriesMetadata: imageGroups.count == 1
                                ? crossSeriesMetadata(for: imageGroup, seriesObject: seriesObject)
                                : nil
                        )
                    )
                }
            }

            let presentations = makeSeriesPresentations(from: pendingPresentations, frames: frames)
            for (presentationIndex, presentation) in presentations.enumerated() {
                if presentation.containsCurrentImage {
                    currentSeriesID = presentation.identifier
                }

                flattenedSeries.append(
                    MetalViewerSeries(
                        identifier: presentation.identifier,
                        patientIdentity: patientIdentity,
                        title: presentation.title,
                        seriesNumber: presentation.seriesNumber,
                        studyIdentifier: study.studyInstanceUID ?? String(describing: study.objectID),
                        studyTitle: study.name ?? study.studyName ?? fallbackTitle,
                        studyDate: study.date,
                        studyNumber: studyIndex + 1,
                        showsStudyHeader: presentationIndex == 0,
                        imageObjects: presentation.imageObjects,
                        isBonjour: isBonjour,
                        initialPixList: presentation.initialPixList,
                        sourceSeriesIdentifiers: presentation.sourceSeriesIdentifiers,
                        dynamicTimePointCountHint: presentation.dynamicTimePointCountHint
                    )
                )
            }

            if flattenedSeries.count > seriesCountBeforeStudy,
               study.objectID != currentStudy.objectID {
                additionalScoutStudies.append(study)
            }
        }

        if markScoutStudiesOpened, additionalScoutStudies.isEmpty == false {
            browser?.markStudies(asOpened: additionalScoutStudies)
        }

        if flattenedSeries.isEmpty {
            let series = MetalViewerSeries(
                identifier: currentSeriesID,
                patientIdentity: patientIdentity,
                title: fallbackTitle,
                seriesNumber: seriesNumber(from: currentSeriesObject),
                studyIdentifier: currentStudy.studyInstanceUID ?? UUID().uuidString,
                studyTitle: studyTitle,
                studyDate: currentStudy.date,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: isBonjour,
                initialPixList: frames
            )
            flattenedSeries = [series]
        }

        let selectedSourceSeriesIdentifiers = Set(frames.compactMap { frame -> String? in
            guard let imageObject = frame.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject,
                  let seriesObject = imageObject.value(forKey: "series") as? NSManagedObject else {
                return nil
            }
            return seriesObject.objectID.uriRepresentation().absoluteString
        })
        let matchingGroupedSeries = flattenedSeries.first {
            $0.dynamicTimePointCountHint != nil
                && $0.sourceSeriesIdentifiers.isDisjoint(with: selectedSourceSeriesIdentifiers) == false
        }

        if forceDynamicInterpretation, let matchingGroupedSeries {
            currentSeriesID = matchingGroupedSeries.identifier
        } else if forceDynamicInterpretation, frames.count > 1 {
            let dynamicIdentifier = "\(currentStudy.studyInstanceUID ?? studyTitle)::dynamic-selection"
            let dynamicSeries = MetalViewerSeries(
                identifier: dynamicIdentifier,
                patientIdentity: patientIdentity,
                title: NSLocalizedString("Dynamic Selection", comment: ""),
                seriesNumber: "",
                studyIdentifier: currentStudy.studyInstanceUID ?? UUID().uuidString,
                studyTitle: studyTitle,
                studyDate: currentStudy.date,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: isBonjour,
                initialPixList: frames,
                forceDynamicInterpretation: true
            )
            flattenedSeries.insert(dynamicSeries, at: 0)
            currentSeriesID = dynamicIdentifier
        }

        return MetalViewerStudy(
            patientIdentity: patientIdentity,
            title: studyTitle,
            series: flattenedSeries,
            initialSeriesIdentifier: currentSeriesID,
            procedureEvents: procedureEvents
        )
    }

    private class func databaseRelatedStudies(for currentStudy: DicomStudy, browser: BrowserController?) -> [DicomStudy] {
        if let browser,
           let displayOnlyThisPatientStudies = browser.perform(NSSelectorFromString("studiesForDisplayOnlyThisPatientMatchingStudy:"), with: currentStudy)?.takeUnretainedValue() as? [DicomStudy],
           displayOnlyThisPatientStudies.isEmpty == false {
            return displayOnlyThisPatientStudies
        }

        let currentPatientUID = currentStudy.patientUID ?? ""
        guard currentPatientUID.isEmpty == false else { return [currentStudy] }

        if let browser,
           let comparativePatientUID = browser.comparativePatientUID,
           comparativePatientUID.compare(currentPatientUID, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame,
           let comparativeStudies = browser.comparativeStudies {
            return comparativeStudies.compactMap { $0 as? DicomStudy }
        }

        if let browser,
           let studies = browser.perform(NSSelectorFromString("relatedStudiesForStudy:"), with: currentStudy)?.takeUnretainedValue() as? [DicomStudy] {
            return studies
        }

        return [currentStudy]
    }

    private class func refreshObjectGraphAfterImport(_ currentImageObject: NSManagedObject) {
        guard let context = currentImageObject.managedObjectContext else { return }

        if let currentSeries = currentImageObject.value(forKey: "series") as? NSManagedObject {
            context.refresh(currentSeries, mergeChanges: true)
        }
        if let currentStudy = currentImageObject.value(forKeyPath: "series.study") as? NSManagedObject {
            context.refresh(currentStudy, mergeChanges: true)
        }
    }

    private class func makeSeriesPresentations(
        from pending: [PendingSeriesPresentation],
        frames: [DCMPix]
    ) -> [SeriesPresentation] {
        let candidates = pending.enumerated().compactMap { index, item -> (Int, CrossSeriesTemporalMetadata)? in
            guard let metadata = item.crossSeriesMetadata?.temporal else { return nil }
            return (index, metadata)
        }
        let groupedCandidates = Dictionary(grouping: candidates, by: { $0.1.key })
        var combinedPresentationByMember: [Int: CombinedSeriesPresentation] = [:]

        for candidatesWithSameGeometry in groupedCandidates.values {
            let acquisitionNumbersAreDistinct = Set(
                candidatesWithSameGeometry.map(\.1.acquisitionNumber)
            ).count == candidatesWithSameGeometry.count
            let ordered = candidatesWithSameGeometry.sorted { lhs, rhs in
                if acquisitionNumbersAreDistinct {
                    return lhs.1.acquisitionNumber < rhs.1.acquisitionNumber
                }
                if let leftSeries = lhs.1.seriesNumber,
                   let rightSeries = rhs.1.seriesNumber,
                   leftSeries != rightSeries {
                    return leftSeries < rightSeries
                }
                if lhs.1.acquisitionSeconds != rhs.1.acquisitionSeconds {
                    return lhs.1.acquisitionSeconds < rhs.1.acquisitionSeconds
                }
                return lhs.0 < rhs.0
            }
            let declaredCounts = Set(ordered.map(\.1.temporalPositionCount).filter { $0 > 1 })
            guard declaredCounts.count <= 1 else { continue }
            let expectedCount = declaredCounts.first ?? ordered.count
            guard expectedCount > 1,
                  ordered.count == expectedCount,
                  ordered.allSatisfy({ $0.1.temporalPositionCount <= 1 || $0.1.temporalPositionCount == expectedCount }) else {
                continue
            }

            let acquisitionNumbers = ordered.map { $0.1.acquisitionNumber }
            let acquisitionNumbersAreSequential = acquisitionNumbers.first.map {
                acquisitionNumbers == Array($0..<($0 + expectedCount))
            } ?? false
            // Older Siemens scanners keep Acquisition Number at 1 and write each
            // declared dynamic phase as a consecutive Series Number instead.
            let seriesNumbers = ordered.compactMap(\.1.seriesNumber)
            let declaredSeriesNumbersAreSequential = declaredCounts.isEmpty == false
                && seriesNumbers.count == expectedCount
                && seriesNumbers.first.map {
                    seriesNumbers == Array($0..<($0 + expectedCount))
                } == true
            guard acquisitionNumbersAreSequential || declaredSeriesNumbersAreSequential else {
                continue
            }

            let acquisitionTimes = ordered.map { $0.1.acquisitionSeconds }
            guard zip(acquisitionTimes.dropFirst(), acquisitionTimes).allSatisfy({ $0.0 > $0.1 }) else {
                continue
            }

            let memberIndexes = ordered.map(\.0)
            guard let anchorIndex = memberIndexes.min() else { continue }
            let combination = CombinedSeriesPresentation(
                anchorIndex: anchorIndex,
                memberIndexes: memberIndexes,
                orderedImageObjects: memberIndexes.flatMap { pending[$0].imageGroup.imageObjects },
                timePointCount: memberIndexes.count
            )
            for memberIndex in memberIndexes {
                combinedPresentationByMember[memberIndex] = combination
            }
        }

        // Some older scanners transpose a 4D acquisition: one series per slice,
        // with the images inside each series representing successive timepoints.
        let slicePartitionCandidates = pending.enumerated().compactMap {
            index, item -> (Int, CrossSeriesSlicePartitionMetadata)? in
            guard combinedPresentationByMember[index] == nil,
                  let metadata = item.crossSeriesMetadata?.slicePartition else {
                return nil
            }
            return (index, metadata)
        }
        let groupedSlicePartitions = Dictionary(grouping: slicePartitionCandidates, by: { $0.1.key })

        for candidatesWithSameLayout in groupedSlicePartitions.values {
            let ordered = candidatesWithSameLayout.sorted { lhs, rhs in
                let leftSeriesNumber = Int(pending[lhs.0].displaySeriesNumber) ?? Int.max
                let rightSeriesNumber = Int(pending[rhs.0].displaySeriesNumber) ?? Int.max
                return leftSeriesNumber == rightSeriesNumber ? lhs.0 < rhs.0 : leftSeriesNumber < rightSeriesNumber
            }
            guard ordered.count > 1 else { continue }

            let seriesNumbers = ordered.compactMap { Int(pending[$0.0].displaySeriesNumber) }
            guard seriesNumbers.count == ordered.count,
                  let firstSeriesNumber = seriesNumbers.first,
                  seriesNumbers == Array(firstSeriesNumber..<(firstSeriesNumber + ordered.count)) else {
                continue
            }

            let spatialPositions = Set(ordered.map(\.1.spatialPosition))
            guard spatialPositions.count == ordered.count,
                  let acquisitionNumbers = ordered.first?.1.acquisitionNumbers,
                  acquisitionNumbers.count > 1,
                  ordered.allSatisfy({ $0.1.acquisitionNumbers == acquisitionNumbers }) else {
                continue
            }

            let memberIndexes = ordered.map(\.0)
            guard let anchorIndex = memberIndexes.min(),
                  memberIndexes.allSatisfy({ pending[$0].imageGroup.imageObjects.count == acquisitionNumbers.count }) else {
                continue
            }
            let orderedImages = acquisitionNumbers.indices.flatMap { timeIndex in
                memberIndexes.map { pending[$0].imageGroup.imageObjects[timeIndex] }
            }
            let combination = CombinedSeriesPresentation(
                anchorIndex: anchorIndex,
                memberIndexes: memberIndexes,
                orderedImageObjects: orderedImages,
                timePointCount: acquisitionNumbers.count
            )
            for memberIndex in memberIndexes {
                combinedPresentationByMember[memberIndex] = combination
            }
        }

        var presentations: [SeriesPresentation] = []
        var consumedIndexes = Set<Int>()

        for index in pending.indices {
            guard consumedIndexes.contains(index) == false else { continue }
            let item = pending[index]

            if let combination = combinedPresentationByMember[index], combination.anchorIndex == index {
                let members = combination.memberIndexes.map { pending[$0] }
                consumedIndexes.formUnion(combination.memberIndexes)
                let orderedImages = combination.orderedImageObjects
                let sourceIdentifiers = Set(members.map { $0.imageGroup.identifier })
                let cachedFrames = filteredFrames(frames, matching: orderedImages)
                let timePointCount = combination.timePointCount
                let seriesNumbers = members.compactMap { Int($0.displaySeriesNumber) }
                let displaySeriesNumber: String
                if let firstNumber = seriesNumbers.min(), let lastNumber = seriesNumbers.max() {
                    displaySeriesNumber = firstNumber == lastNumber ? "\(firstNumber)" : "\(firstNumber)–\(lastNumber)"
                } else {
                    displaySeriesNumber = item.displaySeriesNumber
                }

                presentations.append(
                    SeriesPresentation(
                        identifier: "\(item.imageGroup.identifier)::dynamic-\(timePointCount)",
                        title: item.imageGroup.title,
                        seriesNumber: displaySeriesNumber,
                        imageObjects: orderedImages,
                        containsCurrentImage: members.contains(where: { $0.imageGroup.containsCurrentImage }),
                        initialPixList: cachedFrames.count == orderedImages.count ? cachedFrames : nil,
                        sourceSeriesIdentifiers: sourceIdentifiers,
                        dynamicTimePointCountHint: timePointCount
                    )
                )
                continue
            }

            if combinedPresentationByMember[index] != nil {
                consumedIndexes.insert(index)
                continue
            }

            consumedIndexes.insert(index)
            presentations.append(
                SeriesPresentation(
                    identifier: item.imageGroup.identifier,
                    title: item.imageGroup.title,
                    seriesNumber: item.displaySeriesNumber,
                    imageObjects: item.imageGroup.imageObjects,
                    containsCurrentImage: item.imageGroup.containsCurrentImage,
                    initialPixList: item.imageGroup.initialPixList,
                    sourceSeriesIdentifiers: [item.imageGroup.identifier],
                    dynamicTimePointCountHint: nil
                )
            )
        }

        return presentations
    }

    private class func crossSeriesMetadata(
        for imageGroup: SeriesImageGroup,
        seriesObject: NSManagedObject
    ) -> CrossSeriesMetadata? {
        guard let firstImage = imageGroup.imageObjects.first else { return nil }
        guard let path = resolvedPath(for: firstImage) else { return nil }
        guard let object = try? SwiftDICOMReader.cached(contentsOfFile: path) else { return nil }

        let modality = normalizedMetadataString(
            attributeString(in: object, tag: "0008,0060")
                ?? seriesObject.value(forKey: "modality") as? String
        )
        guard ["CT", "MR", "NM", "PT", "RF", "US", "XA"].contains(modality) else { return nil }

        let standardTemporalPositionCount = attributeInt(in: object, tag: "0020,0105") ?? 0
        let acquisitionNumber = attributeInt(in: object, tag: "0020,0012")
        let seriesNumber = attributeInt(in: object, tag: "0020,0011")
        let acquisitionSeconds = dicomClockSeconds(attributeString(in: object, tag: "0008,0032"))
        let frameOfReferenceUID = normalizedMetadataString(attributeString(in: object, tag: "0020,0052"))
        guard let acquisitionNumber,
              let acquisitionSeconds,
              frameOfReferenceUID.isEmpty == false else {
            return nil
        }

        let seriesDescription = normalizedMetadataString(
            attributeString(in: object, tag: "0008,103E")
                ?? seriesObject.value(forKey: "seriesDescription") as? String
                ?? imageGroup.title
        )
        guard seriesDescription.isEmpty == false else { return nil }

        let protocolName = normalizedMetadataString(attributeString(in: object, tag: "0018,1030"))
        let sequenceName = normalizedMetadataString(attributeString(in: object, tag: "0018,0024"))
        let acquisitionsInSeries = attributeInt(in: object, tag: "0020,1001") ?? 0
        let identifiesDynamicAcquisition = indicatesDynamicAcquisition([
            seriesDescription,
            protocolName,
            sequenceName,
            normalizedMetadataString(attributeString(in: object, tag: "0020,4000")),
            normalizedMetadataString(attributeString(in: object, tag: "0019,1510"))
        ])
        let temporalPositionCount = standardTemporalPositionCount > 1
            ? standardTemporalPositionCount
            : (acquisitionsInSeries > 1 && identifiesDynamicAcquisition ? acquisitionsInSeries : 0)
        let rows = attributeInt(in: object, tag: "0028,0010")
            ?? (firstImage.value(forKey: "height") as? NSNumber)?.intValue
            ?? 0
        let columns = attributeInt(in: object, tag: "0028,0011")
            ?? (firstImage.value(forKey: "width") as? NSNumber)?.intValue
            ?? 0
        guard rows > 0, columns > 0 else { return nil }

        let orientation = metadataSignature(attributeNumbers(in: object, tag: "0020,0037"), precision: 6)
        let pixelSpacing = metadataSignature(attributeNumbers(in: object, tag: "0028,0030"), precision: 6)
        guard orientation.isEmpty == false, pixelSpacing.isEmpty == false else { return nil }

        let positions = imageGroup.imageObjects.compactMap {
            ($0.value(forKey: "sliceLocation") as? NSNumber)?.doubleValue
        }.sorted()
        guard positions.count == imageGroup.imageObjects.count else { return nil }

        let echoTime = metadataSignature(
            attributeDouble(in: object, tag: "0018,0081").map { [$0] } ?? [],
            precision: 4
        )

        let identity = CrossSeriesIdentityKey(
            modality: modality,
            seriesDescription: seriesDescription,
            protocolName: protocolName,
            sequenceName: sequenceName,
            frameOfReferenceUID: frameOfReferenceUID,
            dimensions: "\(columns)x\(rows)",
            orientation: orientation,
            pixelSpacing: pixelSpacing,
            echoTime: echoTime
        )
        let temporal = CrossSeriesTemporalMetadata(
            key: CrossSeriesTemporalKey(
                identity: identity,
                imageCount: imageGroup.imageObjects.count,
                slicePositions: metadataSignature(positions, precision: 3)
            ),
            temporalPositionCount: temporalPositionCount,
            acquisitionNumber: acquisitionNumber,
            seriesNumber: seriesNumber,
            acquisitionSeconds: acquisitionSeconds
        )
        let slicePartition = crossSeriesSlicePartitionMetadata(
            for: imageGroup,
            firstReader: object,
            identity: identity,
            temporalPositionCount: temporalPositionCount,
            seriesDescription: seriesDescription,
            protocolName: protocolName,
            sequenceName: sequenceName,
            sliceLocations: positions
        )
        return CrossSeriesMetadata(temporal: temporal, slicePartition: slicePartition)
    }

    private class func crossSeriesSlicePartitionMetadata(
        for imageGroup: SeriesImageGroup,
        firstReader: SwiftDICOMReader,
        identity: CrossSeriesIdentityKey,
        temporalPositionCount: Int,
        seriesDescription: String,
        protocolName: String,
        sequenceName: String,
        sliceLocations: [Double]
    ) -> CrossSeriesSlicePartitionMetadata? {
        guard imageGroup.imageObjects.count > 1,
              Set(sliceLocations.map { metadataSignature([$0], precision: 3) }).count == 1,
              temporalPositionCount > 1 || indicatesDynamicAcquisition([
                seriesDescription,
                protocolName,
                sequenceName
              ]) else {
            return nil
        }

        let timePointCount = temporalPositionCount > 1 ? temporalPositionCount : imageGroup.imageObjects.count
        guard timePointCount == imageGroup.imageObjects.count else { return nil }

        var acquisitionNumbers: [Int] = []
        var acquisitionSeconds: [Double] = []
        var spatialPositions: [String] = []
        acquisitionNumbers.reserveCapacity(timePointCount)
        acquisitionSeconds.reserveCapacity(timePointCount)
        spatialPositions.reserveCapacity(timePointCount)

        for (index, imageObject) in imageGroup.imageObjects.enumerated() {
            let object: SwiftDICOMReader
            if index == 0 {
                object = firstReader
            } else {
                guard let path = resolvedPath(for: imageObject),
                      let parsed = try? SwiftDICOMReader.cached(contentsOfFile: path) else {
                    return nil
                }
                object = parsed
            }

            guard let acquisitionNumber = attributeInt(in: object, tag: "0020,0012"),
                  let seconds = dicomClockSeconds(attributeString(in: object, tag: "0008,0032")) else {
                return nil
            }
            let position = metadataSignature(attributeNumbers(in: object, tag: "0020,0032"), precision: 3)
            guard position.isEmpty == false else { return nil }
            acquisitionNumbers.append(acquisitionNumber)
            acquisitionSeconds.append(seconds)
            spatialPositions.append(position)
        }

        guard let firstAcquisition = acquisitionNumbers.first,
              acquisitionNumbers == Array(firstAcquisition..<(firstAcquisition + timePointCount)),
              zip(acquisitionSeconds.dropFirst(), acquisitionSeconds).allSatisfy({ $0.0 > $0.1 }),
              Set(spatialPositions).count == 1,
              let spatialPosition = spatialPositions.first else {
            return nil
        }

        return CrossSeriesSlicePartitionMetadata(
            key: CrossSeriesSlicePartitionKey(identity: identity, timePointCount: timePointCount),
            spatialPosition: spatialPosition,
            acquisitionNumbers: acquisitionNumbers
        )
    }

    private class func indicatesDynamicAcquisition(_ values: [String]) -> Bool {
        let markers: Set<String> = ["DCE", "DSC", "DYN", "DYNAMIC", "CINE", "PERFUSION", "MULTIPHASE"]
        let tokens = Set(values.flatMap {
            normalizedMetadataString($0)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.isEmpty == false }
        })
        return markers.isDisjoint(with: tokens) == false
    }

    private class func resolvedPath(for imageObject: NSManagedObject) -> String? {
        if imageObject.responds(to: NSSelectorFromString("completePathResolved")),
           let path = imageObject.perform(NSSelectorFromString("completePathResolved"))?.takeUnretainedValue() as? String,
           path.isEmpty == false {
            return path
        }
        if let path = imageObject.value(forKey: "completePath") as? String, path.isEmpty == false {
            return path
        }
        return nil
    }

    private class func shouldShowInScout(_ seriesObject: NSManagedObject) -> Bool {
        let modality = (seriesObject.value(forKey: "modality") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if modality == "PR" || modality == "KO" {
            return false
        }

        let sopClassUID = (seriesObject.value(forKey: "seriesSOPClassUID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sopClassUID?.hasPrefix("1.2.840.10008.5.1.4.1.1.11.") == true {
            return false
        }
        return sopClassUID != "1.2.840.10008.5.1.4.1.1.88.59"
    }

    private class func attributeString(in object: SwiftDICOMReader, tag: String) -> String? {
        object.stringValue(forTag: tag)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private class func attributeDouble(in object: SwiftDICOMReader, tag: String) -> Double? {
        object.numberValue(forTag: tag)
    }

    private class func attributeInt(in object: SwiftDICOMReader, tag: String) -> Int? {
        object.integerValue(forTag: tag)
    }

    private class func attributeNumbers(in object: SwiftDICOMReader, tag: String) -> [Double] {
        object.numberValues(forTag: tag)
    }

    private class func normalizedMetadataString(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    private class func metadataSignature(_ values: [Double], precision: Int) -> String {
        let format = "%0.\(precision)f"
        return values.map { String(format: format, $0) }.joined(separator: "\\")
    }

    private class func dicomClockSeconds(_ rawValue: Any?) -> Double? {
        if let date = rawValue as? Date {
            let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            guard let hour = components.hour else { return nil }
            return Double(hour * 3_600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
                + Double(components.nanosecond ?? 0) / 1_000_000_000
        }

        let stringValue: String?
        if let value = rawValue as? String {
            stringValue = value
        } else if let value = rawValue as? NSNumber {
            stringValue = value.stringValue
        } else {
            stringValue = nil
        }
        guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 2 else { return nil }
        let normalized = value.replacingOccurrences(of: ":", with: "")
        let hour = Double(normalized.prefix(2)) ?? 0
        let minuteStart = normalized.index(normalized.startIndex, offsetBy: min(2, normalized.count))
        let minuteEnd = normalized.index(minuteStart, offsetBy: min(2, normalized.distance(from: minuteStart, to: normalized.endIndex)))
        let minute = Double(normalized[minuteStart..<minuteEnd]) ?? 0
        let second = minuteEnd < normalized.endIndex ? Double(normalized[minuteEnd...]) ?? 0 : 0
        return hour * 3_600 + minute * 60 + second
    }

    private class func splitSeriesImages(
        _ images: [NSManagedObject],
        seriesObject: NSManagedObject,
        baseTitle: String,
        currentImageObject: NSManagedObject,
        frames: [DCMPix]
    ) -> [SeriesImageGroup] {
        let sortedImages = sortImages(images)
        let filteredFramesForSeries = filteredFrames(frames, matching: sortedImages)
        let cachedFramesForSeries = filteredFramesForSeries.count == sortedImages.count ? filteredFramesForSeries : []
        guard sortedImages.count > 1 else {
            let containsCurrentImage = sortedImages.first?.objectID == currentImageObject.objectID
            return [
                SeriesImageGroup(
                    identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                    title: baseTitle,
                    imageObjects: sortedImages,
                    containsCurrentImage: containsCurrentImage,
                    initialPixList: containsCurrentImage && cachedFramesForSeries.isEmpty == false ? cachedFramesForSeries : nil
                )
            ]
        }

        let containsCurrentImage = sortedImages.contains(where: { $0.objectID == currentImageObject.objectID })
        return [
            SeriesImageGroup(
                identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                title: baseTitle,
                imageObjects: sortedImages,
                containsCurrentImage: containsCurrentImage,
                initialPixList: containsCurrentImage && cachedFramesForSeries.isEmpty == false ? cachedFramesForSeries : nil
            )
        ]
    }
    
    private class func filteredFrames(_ frames: [DCMPix], matching imageObjects: [NSManagedObject]) -> [DCMPix] {
        let matchingIDs = Set(imageObjects.map { $0.objectID.uriRepresentation().absoluteString })
        let filtered = frames.filter { pix in
            guard let imageObject = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject else {
                return false
            }
            return matchingIDs.contains(imageObject.objectID.uriRepresentation().absoluteString)
        }
        return filtered
    }

    private class func sortImages(_ images: [NSManagedObject]) -> [NSManagedObject] {
        return images.sorted { lhs, rhs in
            let lhsInstance = (lhs.value(forKey: "instanceNumber") as? NSNumber)?.intValue ?? Int.min
            let rhsInstance = (rhs.value(forKey: "instanceNumber") as? NSNumber)?.intValue ?? Int.min
            if lhsInstance != rhsInstance {
                return lhsInstance < rhsInstance
            }

            let lhsFrame = (lhs.value(forKey: "frameID") as? NSNumber)?.intValue ?? Int.min
            let rhsFrame = (rhs.value(forKey: "frameID") as? NSNumber)?.intValue ?? Int.min
            if lhsFrame != rhsFrame {
                return lhsFrame < rhsFrame
            }

            let lhsDate = (lhs.value(forKey: "date") as? Date) ?? .distantPast
            let rhsDate = (rhs.value(forKey: "date") as? Date) ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            let lhsPath = lhs.value(forKey: "completePath") as? String ?? ""
            let rhsPath = rhs.value(forKey: "completePath") as? String ?? ""
            if lhsPath != rhsPath {
                return lhsPath < rhsPath
            }

            return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
        }
    }
}
