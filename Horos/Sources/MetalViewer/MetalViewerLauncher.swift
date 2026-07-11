import AppKit

private func metalTimingLog(_ message: String, since start: CFAbsoluteTime? = nil) {
    if let start {
        MetalViewerDiagnostics.timingLog(message, since: start)
    } else {
        MetalViewerDiagnostics.timingLog(message)
    }
}

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
    private static var refreshContexts: [ObjectIdentifier: ViewerRefreshContext] = [:]
    private static var databaseAddObserver: NSObjectProtocol?
    private static var pendingDatabaseRefresh: DispatchWorkItem?
    private static var pendingRefreshIdentifiers: RefreshIdentifiers?
    private static var pendingRefreshStartedAt: CFAbsoluteTime?

    private enum DefaultsKey {
        static let incomingImportCoalescingDelay = "HorosIncomingImportCoalescingDelay"
        static let databaseRefreshDelay = "HorosMetalViewerDatabaseRefreshDelay"
        static let databaseRefreshMaxDeferral = "HorosMetalViewerDatabaseRefreshMaxDeferral"
    }

    private struct ViewerRefreshContext {
        let frames: [DCMPix]
        let fallbackTitle: String
        let identifiers: RefreshIdentifiers
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

    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        let launchStart = CFAbsoluteTimeGetCurrent()
        guard let pixList = context["pixList"] as? NSArray,
              let frames = pixList as? [DCMPix],
              let title = context["title"] as? String,
              frames.isEmpty == false else {
            NSSound.beep()
            return
        }

        let launchIdentifiers = refreshIdentifiers(from: frames)
        if let existingController = existingController(matching: launchIdentifiers) {
            let controllerIdentifier = ObjectIdentifier(existingController)
            refreshContexts[controllerIdentifier] = ViewerRefreshContext(
                frames: frames,
                fallbackTitle: title,
                identifiers: launchIdentifiers
            )
            ensureDatabaseAddObserver()

            let fullStudyStart = CFAbsoluteTimeGetCurrent()
            let fullStudy = buildStudy(from: frames, fallbackTitle: title)
            metalTimingLog("MetalViewerLauncher build reused study", since: fullStudyStart)
            let updateStart = CFAbsoluteTimeGetCurrent()
            existingController.updateStudy(fullStudy, selectInitialSeries: true)
            metalTimingLog("MetalViewerLauncher update reused window", since: updateStart)
            existingController.window?.makeKeyAndOrderFront(NSApp)
            NSApp.activate(ignoringOtherApps: true)
            metalTimingLog("MetalViewerLauncher reused existing window total", since: launchStart)
            return
        }

        let initialStudyStart = CFAbsoluteTimeGetCurrent()
        let study = buildInitialStudy(from: frames, fallbackTitle: title)
        metalTimingLog("MetalViewerLauncher buildInitialStudy", since: initialStudyStart)
        let controllerStart = CFAbsoluteTimeGetCurrent()
        let controller = MetalViewerWindowController(study: study)
        metalTimingLog("MetalViewerLauncher create window controller", since: controllerStart)
        retainedControllers.append(controller)
        let controllerIdentifier = ObjectIdentifier(controller)
        refreshContexts[controllerIdentifier] = ViewerRefreshContext(
            frames: frames,
            fallbackTitle: title,
            identifiers: launchIdentifiers
        )
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

        let presentationStart = CFAbsoluteTimeGetCurrent()
        applyFastPresentationFrame(to: controller.window)
        controller.restoreSavedSplitPositionForPresentation()
        metalTimingLog("MetalViewerLauncher prepare presentation frame", since: presentationStart)

        let showStart = CFAbsoluteTimeGetCurrent()
        let orderStart = CFAbsoluteTimeGetCurrent()
        controller.window?.makeKeyAndOrderFront(NSApp)
        metalTimingLog("MetalViewerLauncher order window", since: orderStart)

        let activateStart = CFAbsoluteTimeGetCurrent()
        NSApp.activate(ignoringOtherApps: true)
        metalTimingLog("MetalViewerLauncher activate app", since: activateStart)
        metalTimingLog("MetalViewerLauncher show/order window", since: showStart)
        metalTimingLog("MetalViewerLauncher synchronous launch total", since: launchStart)

        DispatchQueue.main.async {
            let fullStudyStart = CFAbsoluteTimeGetCurrent()
            let fullStudy = buildStudy(from: frames, fallbackTitle: title)
            metalTimingLog("MetalViewerLauncher build full study", since: fullStudyStart)
            let updateStart = CFAbsoluteTimeGetCurrent()
            controller.updateStudy(fullStudy)
            metalTimingLog("MetalViewerLauncher update full study", since: updateStart)
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
            guard let context = refreshContexts[ObjectIdentifier(controller)] else { continue }
            if context.identifiers.intersects(identifiers) {
                return controller
            }
        }

        return nil
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
            guard let context = refreshContexts[controllerIdentifier] else { continue }
            if let importedIdentifiers = importedIdentifiers {
                if importedIdentifiers.isEmpty == false,
                   context.identifiers.isEmpty == false,
                   context.identifiers.intersects(importedIdentifiers) == false {
                    continue
                }
            }

            let refreshStart = CFAbsoluteTimeGetCurrent()
            let updatedStudy = buildStudy(from: context.frames, fallbackTitle: context.fallbackTitle)
            let changedPaneCount = controller.updateStudy(updatedStudy)
            if changedPaneCount > 0 {
                metalTimingLog("MetalViewerLauncher refreshed open viewer panes=\(changedPaneCount)", since: refreshStart)
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

    private class func patientWindowTitle(patientName: String?, patientID: String?, fallbackTitle: String) -> String {
        let name = patientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = patientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if name.isEmpty == false, identifier.isEmpty == false {
            return "\(name) (\(identifier))"
        }
        if name.isEmpty == false {
            return name
        }
        if identifier.isEmpty == false {
            return identifier
        }
        return fallbackTitle
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

    private class func buildInitialStudy(from frames: [DCMPix], fallbackTitle: String) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject else {
            let series = MetalViewerSeries(
                title: fallbackTitle,
                seriesNumber: "",
                studyIdentifier: UUID().uuidString,
                studyTitle: fallbackTitle,
                studyDate: nil,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: (BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false),
                initialPixList: frames
            )
            return MetalViewerStudy(title: fallbackTitle, series: [series], initialSeriesIdentifier: series.identifier)
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
        let studyTitle = patientWindowTitle(patientName: patientName, patientID: patientID, fallbackTitle: fallbackTitle)
        let studyIdentifier = (currentImageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String)
            ?? String(describing: currentImageObject.value(forKeyPath: "series.study") ?? UUID().uuidString)
        let studyDate = currentImageObject.value(forKeyPath: "series.study.date") as? Date
        let series = MetalViewerSeries(
            identifier: currentSeriesID,
            title: seriesTitle,
            seriesNumber: seriesNumber(from: currentSeriesObject),
            studyIdentifier: studyIdentifier,
            studyTitle: studyTitle,
            studyDate: studyDate,
            studyNumber: 1,
            showsStudyHeader: true,
            imageObjects: [],
            isBonjour: isBonjour,
            initialPixList: frames
        )
        return MetalViewerStudy(title: studyTitle, series: [series], initialSeriesIdentifier: currentSeriesID)
    }

    private class func buildStudy(from frames: [DCMPix], fallbackTitle: String) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject,
              let currentStudy = currentImageObject.value(forKeyPath: "series.study") as? DicomStudy else {
            let series = MetalViewerSeries(
                title: fallbackTitle,
                seriesNumber: "",
                studyIdentifier: UUID().uuidString,
                studyTitle: fallbackTitle,
                studyDate: nil,
                studyNumber: 1,
                showsStudyHeader: true,
                imageObjects: [],
                isBonjour: (BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false),
                initialPixList: frames
            )
            return MetalViewerStudy(title: fallbackTitle, series: [series], initialSeriesIdentifier: series.identifier)
        }

        refreshObjectGraphAfterImport(currentImageObject)

        let browser = BrowserController.currentBrowser()
        let relatedStudies = databaseRelatedStudies(for: currentStudy, browser: browser)

        var uniqueStudies = relatedStudies
        if uniqueStudies.contains(where: { ($0.studyInstanceUID ?? "") == (currentStudy.studyInstanceUID ?? "") }) == false {
            uniqueStudies.append(currentStudy)
        }

        let sortedStudies = uniqueStudies
            .filter { ($0.series.count) > 0 }
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
        let studyTitle = patientWindowTitle(patientName: currentStudy.name, patientID: currentStudy.patientID, fallbackTitle: fallbackTitle)

        var flattenedSeries: [MetalViewerSeries] = []

        for (studyIndex, study) in sortedStudies.enumerated() {
            guard let browser else { continue }
            let seriesObjects = browser.childrenArray(study, onlyImages: false) as? [NSManagedObject] ?? []
            var hasShownStudyHeader = false

            for seriesObject in seriesObjects {
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
                let studyIdentifier = study.studyInstanceUID ?? String(describing: study.objectID)
                let displaySeriesNumber = seriesNumber(from: seriesObject)

                for imageGroup in imageGroups {
                    if imageGroup.containsCurrentImage {
                        currentSeriesID = imageGroup.identifier
                    }

                    flattenedSeries.append(
                        MetalViewerSeries(
                            identifier: imageGroup.identifier,
                            title: imageGroup.title,
                            seriesNumber: displaySeriesNumber,
                            studyIdentifier: studyIdentifier,
                            studyTitle: study.name ?? study.studyName ?? fallbackTitle,
                            studyDate: study.date,
                            studyNumber: studyIndex + 1,
                            showsStudyHeader: hasShownStudyHeader == false,
                            imageObjects: imageGroup.imageObjects,
                            isBonjour: isBonjour,
                            initialPixList: imageGroup.initialPixList
                        )
                    )
                    hasShownStudyHeader = true
                }
            }
        }

        if flattenedSeries.isEmpty {
            let series = MetalViewerSeries(
                identifier: currentSeriesID,
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

        return MetalViewerStudy(title: studyTitle, series: flattenedSeries, initialSeriesIdentifier: currentSeriesID)
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
