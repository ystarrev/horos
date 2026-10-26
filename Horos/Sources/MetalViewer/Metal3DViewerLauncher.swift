import AppKit
import CoreData

@objc(HorosMetal3DViewerLauncher)
final class Metal3DViewerLauncher: NSObject {
    private static var retainedControllers: [Metal3DViewerWindowController] = []

    @objc(visibleWindows)
    class func visibleWindows() -> [NSWindow] {
        retainedControllers.compactMap { $0.window }.filter { $0.isVisible }
    }

    @objc(closeAllWindows)
    class func closeAllWindows() {
        retainedControllers.compactMap { $0.window }.forEach { $0.close() }
    }

    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        let pixList = (context["pixList"] as? [DCMPix]) ?? ((context["pixList"] as? NSArray)?.compactMap { $0 as? DCMPix } ?? [])

        guard pixList.isEmpty == false else {
            NSSound.beep()
            return
        }

        let title = (context["title"] as? String) ?? NSLocalizedString("Series", comment: "")
        presentWindowController(
            Metal3DViewerWindowController(
                pixList: pixList,
                title: title
            )
        )
    }

    class func launchFaceOff(withContext context: NSDictionary) {
        let pixList = (context["pixList"] as? [DCMPix]) ?? ((context["pixList"] as? NSArray)?.compactMap { $0 as? DCMPix } ?? [])
        let capabilities = Metal3DViewerContentCapabilities(pixList: pixList)
        guard pixList.count >= 2, capabilities.containsCT || capabilities.containsMRI else {
            NSSound.beep()
            return
        }
        let title = (context["title"] as? String) ?? "Series"
        presentWindowController(Metal3DViewerWindowController(pixList: pixList, title: title, mode: .faceOff))
    }

    @objc(launchWithSeries:)
    class func launch(withSeries seriesObject: NSManagedObject) {
        let seriesDescription = (seriesObject.value(forKey: "name") as? String) ?? NSLocalizedString("series", comment: "")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("3D Metal", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString("The 3D Metal viewer needs image data for %@. Launch it through the database button so the selected series can be prepared first.", comment: ""),
            seriesDescription
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    private class func presentWindowController(_ controller: Metal3DViewerWindowController) {
        retainedControllers.append(controller)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak controller] _ in
            guard let controller else { return }
            retainedControllers.removeAll { $0 === controller }
        }

        controller.presentWindowOnViewerScreen()
    }
}

@objc(HorosFaceOffLauncher)
final class FaceOffLauncher: NSObject {
    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        Metal3DViewerLauncher.launchFaceOff(withContext: context)
    }
}
