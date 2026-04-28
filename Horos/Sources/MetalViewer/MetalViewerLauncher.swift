import AppKit

private func metalTimingLog(_ message: String, since start: CFAbsoluteTime? = nil) {
    if let start {
        print(String(format: "HOROS_METAL_TIMING %@ %.3f s", message, CFAbsoluteTimeGetCurrent() - start))
    } else {
        print("HOROS_METAL_TIMING \(message)")
    }
}

@objc(HorosMetalViewerLauncher)
final class MetalViewerLauncher: NSObject {
    private static var retainedControllers: [MetalViewerWindowController] = []

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

        let initialStudyStart = CFAbsoluteTimeGetCurrent()
        let study = buildInitialStudy(from: frames, fallbackTitle: title)
        metalTimingLog("MetalViewerLauncher buildInitialStudy", since: initialStudyStart)
        let controllerStart = CFAbsoluteTimeGetCurrent()
        let controller = MetalViewerWindowController(study: study)
        metalTimingLog("MetalViewerLauncher create window controller", since: controllerStart)
        retainedControllers.append(controller)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak controller] _ in
            guard let controller else { return }
            retainedControllers.removeAll { $0 === controller }
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

    private class func applyFastPresentationFrame(to window: NSWindow?) {
        guard let window,
              let screen = window.screen ?? NSScreen.main else {
            return
        }

        window.setFrame(screen.visibleFrame.integral, display: true)
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

        let browser = BrowserController.currentBrowser()
        let currentPatientUID = currentStudy.patientUID ?? ""

        let relatedStudies: [DicomStudy]
        if let comparativeStudies = browser?.comparativeStudies as? [Any], currentPatientUID.isEmpty == false {
            relatedStudies = comparativeStudies.compactMap { $0 as? DicomStudy }.filter {
                ($0.patientUID ?? "").caseInsensitiveCompare(currentPatientUID) == .orderedSame
            }
        } else {
            relatedStudies = (currentStudy.perform(NSSelectorFromString("studiesForThisPatient"))?.takeUnretainedValue() as? [DicomStudy]) ?? [currentStudy]
        }

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

    private class func splitSeriesImages(
        _ images: [NSManagedObject],
        seriesObject: NSManagedObject,
        baseTitle: String,
        currentImageObject: NSManagedObject,
        frames: [DCMPix]
    ) -> [SeriesImageGroup] {
        let sortedImages = sortImages(images)
        let cachedFramesForSeries = filteredFrames(frames, matching: sortedImages)
        guard sortedImages.count > 1 else {
            let containsCurrentImage = sortedImages.first?.objectID == currentImageObject.objectID
            return [
                SeriesImageGroup(
                    identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                    title: baseTitle,
                    imageObjects: sortedImages,
                    containsCurrentImage: containsCurrentImage,
                    initialPixList: containsCurrentImage ? cachedFramesForSeries : nil
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
                initialPixList: containsCurrentImage ? cachedFramesForSeries : nil
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
