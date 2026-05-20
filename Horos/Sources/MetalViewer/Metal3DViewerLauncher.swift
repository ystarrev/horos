import AppKit
import CoreData

@objc(HorosMetal3DViewerLauncher)
final class Metal3DViewerLauncher: NSObject {
    private static var retainedControllers: [Metal3DViewerWindowController] = []

    @objc(launchWithContext:)
    class func launch(withContext context: NSDictionary) {
        let pixList = (context["pixList"] as? [DCMPix]) ?? ((context["pixList"] as? NSArray)?.compactMap { $0 as? DCMPix } ?? [])
        let volumeData = (context["volumeData"] as? Data) ?? ((context["volumeData"] as? NSData) as Data?)

        guard pixList.isEmpty == false, let volumeData else {
            NSSound.beep()
            return
        }

        let title = (context["title"] as? String) ?? NSLocalizedString("Series", comment: "")
        presentWindowController(
            Metal3DViewerWindowController(
                pixList: pixList,
                volumeData: volumeData,
                title: title
            )
        )
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
