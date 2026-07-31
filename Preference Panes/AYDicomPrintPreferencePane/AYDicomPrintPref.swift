import AppKit
import PreferencePanes
import UniformTypeIdentifiers

@objc(AYDicomPrintPref)
final class AYDicomPrintPref: NSPreferencePane {
  @IBOutlet private var printerController: NSArrayController!
  @IBOutlet private var mainWindow: NSWindow!

  private var retainedTopLevelObjects: [Any] = []

  override init(bundle: Bundle) {
    super.init(bundle: bundle)

    let nib = NSNib(nibNamed: "AYDicomPrintPref", bundle: nil)
    var topLevelObjects: NSArray?
    nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
    retainedTopLevelObjects = topLevelObjects as? [Any] ?? []

    if let contentView = mainWindow?.contentView {
      mainView = contentView
      mainViewDidLoad()
    }
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    DICOMPrintWindowController.updateAllPreferencesFormat()

    for (index, printer) in printers.enumerated()
    where printer["defaultPrinter"] as? String == "1" {
      printerController.setSelectionIndex(index)
      break
    }
  }

  override func willUnselect() {
    mainView.window?.makeFirstResponder(nil)
  }

  @IBAction private func saveList(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.propertyList]
    panel.nameFieldStringValue = NSLocalizedString("DICOMPrinters.plist", comment: "")

    panel.begin { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }

      do {
        let data = try PropertyListSerialization.data(
          fromPropertyList: self.printers,
          format: .xml,
          options: 0
        )
        try data.write(to: url, options: .atomic)
      } catch {
        NSLog("Failed to save DICOM printers to %@: %@", url.path, error.localizedDescription)
      }
    }
  }

  @IBAction private func loadList(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.propertyList]

    panel.begin { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }

      do {
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
          from: data,
          options: [.mutableContainersAndLeaves],
          format: nil
        )
        guard let loadedPrinters = propertyList as? [[String: Any]] else { return }

        let choice = HorosAlertPresenter.run(
          title: NSLocalizedString("Load printers", comment: ""),
          message: NSLocalizedString(
            "Should I add or replace the printer list? If you choose 'replace', the current list will be deleted.",
            comment: ""
          ),
          style: .informational,
          firstButton: NSLocalizedString("Add", comment: ""),
          secondButton: NSLocalizedString("Replace", comment: ""),
          thirdButton: nil
        )

        let existingPrinters = choice == .alertFirstButtonReturn ? self.printers : []
        self.printerController.content = self.removingDuplicates(
          from: existingPrinters + loadedPrinters.map { NSMutableDictionary(dictionary: $0) }
        )
      } catch {
        NSLog("Failed to load DICOM printers from %@: %@", url.path, error.localizedDescription)
      }
    }
  }

  @IBAction private func addPrinter(_ sender: Any?) {
    let printerNumber = printers.count + 1
    let printer = NSMutableDictionary(dictionary: [
      "printerName": "Printer \(printerNumber)",
      "host": "localhost",
      "port": "4080",
      "aeTitle": "Printer_\(printerNumber)",
      "imageDisplayFormatTag": "0",
      "borderDensityTag": "0",
      "emptyImageDensityTag": "0",
      "filmOrientationTag": "0",
      "filmDestinationTag": "0",
      "magnificationTypeTag": "0",
      "trimTag": "0",
      "filmSizeTag": "0",
      "configurationInformation": "",
      "priorityTag": "0",
      "mediumTag": "0",
      "copies": "1",
    ])

    printerController.addObject(printer)
    printerController.setSelectedObjects([printer])

    if printers.count == 1 {
      setDefaultPrinter(nil)
    }
  }

  @IBAction private func setDefaultPrinter(_ sender: Any?) {
    for printer in printers {
      printer.removeObject(forKey: "defaultPrinter")
    }
    printerController.setValue("1", forKeyPath: "selection.defaultPrinter")
  }

  private var printers: [NSMutableDictionary] {
    printerController?.arrangedObjects as? [NSMutableDictionary] ?? []
  }

  private func removingDuplicates(
    from candidates: [NSMutableDictionary]
  ) -> [NSMutableDictionary] {
    var identities = Set<String>()
    var uniquePrinters: [NSMutableDictionary] = []

    for printer in candidates {
      let host = printer["host"] as? String ?? ""
      let port = printer["port"] as? String ?? ""
      let identity = "\(host)\u{0}\(port)"
      guard identities.insert(identity).inserted else { continue }
      uniquePrinters.append(printer)
    }

    return uniquePrinters
  }
}
