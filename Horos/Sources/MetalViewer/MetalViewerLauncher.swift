import AppKit

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
        guard let pixList = context["pixList"] as? NSArray,
              let frames = pixList as? [DCMPix],
              let title = context["title"] as? String,
              frames.isEmpty == false else {
            NSSound.beep()
            return
        }

        let study = buildInitialStudy(from: frames, fallbackTitle: title)
        let controller = MetalViewerWindowController(study: study)
        retainedControllers.append(controller)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak controller] _ in
            guard let controller else { return }
            retainedControllers.removeAll { $0 === controller }
        }

        controller.showWindow(NSApp)
        controller.window?.makeKeyAndOrderFront(NSApp)
        controller.window?.zoom(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            let fullStudy = buildStudy(from: frames, fallbackTitle: title)
            controller.updateStudy(fullStudy)
        }
    }

    private class func buildInitialStudy(from frames: [DCMPix], fallbackTitle: String) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject else {
            let series = MetalViewerSeries(
                title: fallbackTitle,
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
        let studyTitle = ((currentImageObject.value(forKeyPath: "series.study.name") as? String)?.isEmpty == false ? (currentImageObject.value(forKeyPath: "series.study.name") as? String) : nil)
            ?? fallbackTitle
        let studyIdentifier = (currentImageObject.value(forKeyPath: "series.study.studyInstanceUID") as? String)
            ?? String(describing: currentImageObject.value(forKeyPath: "series.study") ?? UUID().uuidString)
        let studyDate = currentImageObject.value(forKeyPath: "series.study.date") as? Date
        let splitFrames = splitInitialFrames(frames, currentSeriesID: currentSeriesID, baseTitle: seriesTitle)
        let initialSeriesIdentifier = splitFrames.first(where: { $0.containsCurrentImage })?.identifier ?? currentSeriesID
        let series = splitFrames.enumerated().map { index, group in
            MetalViewerSeries(
                identifier: group.identifier,
                title: group.title,
                studyIdentifier: studyIdentifier,
                studyTitle: studyTitle,
                studyDate: studyDate,
                studyNumber: 1,
                showsStudyHeader: index == 0,
                imageObjects: [],
                isBonjour: isBonjour,
                initialPixList: group.pixList
            )
        }
        return MetalViewerStudy(title: studyTitle, series: series, initialSeriesIdentifier: initialSeriesIdentifier)
    }

    private class func buildStudy(from frames: [DCMPix], fallbackTitle: String) -> MetalViewerStudy {
        guard let currentImageObject = frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject,
              let currentStudy = currentImageObject.value(forKeyPath: "series.study") as? DicomStudy else {
            let series = MetalViewerSeries(
                title: fallbackTitle,
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
        let studyTitle = (currentStudy.name?.isEmpty == false ? currentStudy.name : fallbackTitle) ?? fallbackTitle

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
                    isBonjour: isBonjour,
                    currentImageObject: currentImageObject,
                    frames: frames
                )
                let studyIdentifier = study.studyInstanceUID ?? String(describing: study.objectID)

                for imageGroup in imageGroups {
                    if imageGroup.containsCurrentImage {
                        currentSeriesID = imageGroup.identifier
                    }

                    flattenedSeries.append(
                        MetalViewerSeries(
                            identifier: imageGroup.identifier,
                            title: imageGroup.title,
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
        isBonjour: Bool,
        currentImageObject: NSManagedObject,
        frames: [DCMPix]
    ) -> [SeriesImageGroup] {
        let sortedImages = sortImages(images)
        guard sortedImages.count > 1 else {
            let containsCurrentImage = sortedImages.first?.objectID == currentImageObject.objectID
            return [
                SeriesImageGroup(
                    identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                    title: baseTitle,
                    imageObjects: sortedImages,
                    containsCurrentImage: containsCurrentImage,
                    initialPixList: containsCurrentImage ? filteredFrames(frames, matching: sortedImages) : nil
                )
            ]
        }

        let cachedFramesForSeries = filteredFrames(frames, matching: sortedImages)
        let shouldUseFrameBasedBucketing = cachedFramesForSeries.count > 1

        var orientationByImageID = [String: (key: String, label: String?)]()
        if shouldUseFrameBasedBucketing {
            for pix in cachedFramesForSeries {
                guard let imageObject = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject else {
                    continue
                }
                let imageID = imageObject.objectID.uriRepresentation().absoluteString
                orientationByImageID[imageID] = (
                    key: orientationKey(for: pix),
                    label: orientationLabel(for: pix)
                )
            }
        } else {
            let sampleImages = representativeImages(for: sortedImages)
            let sampleOrientations = sampleImages.compactMap { image -> (String, String?)? in
                guard let previewPix = makePreviewPix(for: image, isBonjour: isBonjour) else {
                    return nil
                }
                return (orientationKey(for: previewPix), orientationLabel(for: previewPix))
            }

            let uniqueSampleKeys = Set(sampleOrientations.map { $0.0 })
            if uniqueSampleKeys.count <= 1 {
                let orientationLabel = sampleOrientations.first?.1
                let title = titledSeries(baseTitle: baseTitle, orientationLabel: orientationLabel)
                let containsCurrentImage = sortedImages.contains(where: { $0.objectID == currentImageObject.objectID })
                return [
                    SeriesImageGroup(
                        identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                        title: title,
                        imageObjects: sortedImages,
                        containsCurrentImage: containsCurrentImage,
                        initialPixList: containsCurrentImage ? cachedFramesForSeries : nil
                    )
                ]
            }

            for image in sortedImages {
                guard let previewPix = makePreviewPix(for: image, isBonjour: isBonjour) else {
                    continue
                }
                let imageID = image.objectID.uriRepresentation().absoluteString
                orientationByImageID[imageID] = (
                    key: orientationKey(for: previewPix),
                    label: orientationLabel(for: previewPix)
                )
            }
        }

        struct Bucket {
            let orientationKey: String
            let orientationLabel: String?
            var images: [NSManagedObject]
            var containsCurrentImage: Bool
        }

        var buckets: [Bucket] = []
        for image in sortedImages {
            let imageID = image.objectID.uriRepresentation().absoluteString
            let orientation = orientationByImageID[imageID] ?? ("unknown", nil)

            if let existingIndex = buckets.firstIndex(where: { $0.orientationKey == orientation.key }) {
                buckets[existingIndex].images.append(image)
                if image.objectID == currentImageObject.objectID {
                    buckets[existingIndex].containsCurrentImage = true
                }
            } else {
                buckets.append(
                    Bucket(
                        orientationKey: orientation.key,
                        orientationLabel: orientation.label,
                        images: [image],
                        containsCurrentImage: image.objectID == currentImageObject.objectID
                    )
                )
            }
        }

        guard buckets.count > 1 else {
            let containsCurrentImage = sortedImages.contains(where: { $0.objectID == currentImageObject.objectID })
            let title = titledSeries(baseTitle: baseTitle, orientationLabel: buckets.first?.orientationLabel)
            return [
                SeriesImageGroup(
                    identifier: seriesObject.objectID.uriRepresentation().absoluteString,
                    title: title,
                    imageObjects: sortedImages,
                    containsCurrentImage: containsCurrentImage,
                    initialPixList: containsCurrentImage ? cachedFramesForSeries : nil
                )
            ]
        }

        return buckets.enumerated().map { index, bucket in
            SeriesImageGroup(
                identifier: "\(seriesObject.objectID.uriRepresentation().absoluteString)#\(index)",
                title: titledSeries(baseTitle: baseTitle, orientationLabel: bucket.orientationLabel),
                imageObjects: bucket.images,
                containsCurrentImage: bucket.containsCurrentImage,
                initialPixList: bucket.containsCurrentImage ? filteredFrames(cachedFramesForSeries, matching: bucket.images) : nil
            )
        }
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

    private class func splitInitialFrames(_ frames: [DCMPix], currentSeriesID: String, baseTitle: String) -> [(identifier: String, title: String, pixList: [DCMPix], containsCurrentImage: Bool)] {
        guard frames.count > 1 else {
            return [(currentSeriesID, baseTitle, frames, true)]
        }

        struct Bucket {
            let orientationKey: String
            let orientationLabel: String?
            var pixList: [DCMPix]
            var containsCurrentImage: Bool
        }

        var buckets: [Bucket] = []
        let currentImageID = (frames.first?.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject)?.objectID.uriRepresentation().absoluteString

        for pix in frames {
            let key = orientationKey(for: pix)
            let label = orientationLabel(for: pix)
            let imageID = (pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSManagedObject)?.objectID.uriRepresentation().absoluteString
            if let existingIndex = buckets.firstIndex(where: { $0.orientationKey == key }) {
                buckets[existingIndex].pixList.append(pix)
                if imageID == currentImageID {
                    buckets[existingIndex].containsCurrentImage = true
                }
            } else {
                buckets.append(
                    Bucket(
                        orientationKey: key,
                        orientationLabel: label,
                        pixList: [pix],
                        containsCurrentImage: imageID == currentImageID
                    )
                )
            }
        }

        guard buckets.count > 1 else {
            let title = titledSeries(baseTitle: baseTitle, orientationLabel: buckets.first?.orientationLabel)
            return [(currentSeriesID, title, frames, true)]
        }

        return buckets.enumerated().map { index, bucket in
            (
                identifier: "\(currentSeriesID)#\(index)",
                title: titledSeries(baseTitle: baseTitle, orientationLabel: bucket.orientationLabel),
                pixList: bucket.pixList,
                containsCurrentImage: bucket.containsCurrentImage
            )
        }
    }

    private class func representativeImages(for images: [NSManagedObject]) -> [NSManagedObject] {
        guard images.count > 4 else { return images }
        return [images.first, images[images.count / 3], images[(2 * images.count) / 3], images.last].compactMap { $0 }
    }

    private class func titledSeries(baseTitle: String, orientationLabel: String?) -> String {
        guard let orientationLabel, baseTitle.localizedCaseInsensitiveContains(orientationLabel) == false else {
            return baseTitle
        }
        return "\(baseTitle) (\(orientationLabel))"
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
    
    private class func makePreviewPix(for imageObject: NSManagedObject, isBonjour: Bool) -> DCMPix? {
        let path = imageObject.value(forKey: "completePath") as? String ?? ""
        let frameID = (imageObject.value(forKey: "frameID") as? NSNumber)?.intValue ?? 0
        let seriesID = (imageObject.value(forKeyPath: "series.id") as? NSNumber)?.intValue ?? 0
        return DCMPix(path: path, 0, 1, nil, frameID, seriesID, isBonjour: isBonjour, imageObj: imageObject)
    }

    private class func orientationKey(for pix: DCMPix) -> String {
        let vector = orientationVector(for: pix)
        return vector
            .map { String(format: "%.2f", $0) }
            .joined(separator: ",")
    }
    
    private class func orientationLabel(for pix: DCMPix) -> String? {
        let vector = orientationVector(for: pix)
        guard vector.count >= 9 else {
            return nil
        }

        let normal = SIMD3<Float>(vector[6], vector[7], vector[8])
        let absolute = SIMD3<Float>(abs(normal.x), abs(normal.y), abs(normal.z))

        if absolute.x >= absolute.y, absolute.x >= absolute.z {
            return "Sagittal"
        }
        if absolute.y >= absolute.x, absolute.y >= absolute.z {
            return "Coronal"
        }
        return "Axial"
    }
    
    private class func orientationVector(for pix: DCMPix) -> [Float] {
        var vector = Array(repeating: Float(0), count: 9)
        let selector = NSSelectorFromString("orientation:")
        typealias OrientationIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>?) -> Void
        let implementation = pix.method(for: selector)
        let function = unsafeBitCast(implementation, to: OrientationIMP.self)
        function(pix, selector, &vector)
        return vector
    }
}
