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
              let volumeData = context["volumeData"] as? NSData,
              frames.isEmpty == false else {
            NSSound.beep()
            return
        }

        let study = buildStudy(from: frames, fallbackTitle: title, volumeData: volumeData)
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
    }

    private class func buildStudy(from frames: [DCMPix], fallbackTitle: String, volumeData: NSData) -> MetalViewerStudy {
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
                initialPixList: frames,
                initialVolumeData: volumeData
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
                let imageGroups = splitSeriesImages(images, seriesObject: seriesObject, baseTitle: baseTitle, isBonjour: isBonjour, currentImageObject: currentImageObject, frames: frames)
                let studyIdentifier = study.studyInstanceUID ?? String(describing: study.objectID)

                for imageGroup in imageGroups {
                    if imageGroup.containsCurrentImage {
                        currentSeriesID = imageGroup.identifier
                    }

                    let initialPixList = imageGroup.initialPixList
                    let initialVolumeData = initialPixList != nil ? volumeData : nil

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
                            initialPixList: initialPixList,
                            initialVolumeData: initialVolumeData
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
                initialPixList: frames,
                initialVolumeData: volumeData
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

        struct Bucket {
            let orientationKey: String
            let orientationLabel: String?
            var images: [NSManagedObject]
            var containsCurrentImage: Bool
        }

        var buckets: [Bucket] = []

        for image in sortedImages {
            let previewPix = makePreviewPix(for: image, isBonjour: isBonjour)
            let imageOrientationKey = previewPix.map { Self.orientationKey(for: $0) } ?? "unknown"
            let imageOrientationLabel = previewPix.flatMap { Self.orientationLabel(for: $0) }

            if let existingIndex = buckets.firstIndex(where: { $0.orientationKey == imageOrientationKey }) {
                buckets[existingIndex].images.append(image)
                if image.objectID == currentImageObject.objectID {
                    buckets[existingIndex].containsCurrentImage = true
                }
            } else {
                buckets.append(
                    Bucket(
                        orientationKey: imageOrientationKey,
                        orientationLabel: imageOrientationLabel,
                        images: [image],
                        containsCurrentImage: image.objectID == currentImageObject.objectID
                    )
                )
            }
        }

        guard buckets.count > 1 else {
            let containsCurrentImage = sortedImages.contains(where: { $0.objectID == currentImageObject.objectID })
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

        return buckets.enumerated().map { index, bucket in
            let title: String
            if let orientationLabel = bucket.orientationLabel, baseTitle.localizedCaseInsensitiveContains(orientationLabel) == false {
                title = "\(baseTitle) (\(orientationLabel))"
            } else {
                title = baseTitle
            }

            return SeriesImageGroup(
                identifier: "\(seriesObject.objectID.uriRepresentation().absoluteString)#\(index)",
                title: title,
                imageObjects: bucket.images,
                containsCurrentImage: bucket.containsCurrentImage,
                initialPixList: bucket.containsCurrentImage ? filteredFrames(frames, matching: bucket.images) : nil
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
