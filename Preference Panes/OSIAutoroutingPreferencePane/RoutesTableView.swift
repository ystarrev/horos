import AppKit

@objc(RoutesTableView)
final class RoutesTableView: NSTableView {
  override func keyDown(with event: NSEvent) {
    guard let character = event.characters?.unicodeScalars.first?.value else { return }

    let isDelete =
      character == UInt32(NSDeleteCharacter)
      || character == UInt32(NSBackspaceCharacter)

    guard isDelete, selectedRow >= 0, numberOfRows > 0 else {
      super.keyDown(with: event)
      return
    }

    let response = HorosAlertPresenter.run(
      title: NSLocalizedString("Delete Route", comment: ""),
      message: NSLocalizedString(
        "Are you sure you want to delete the selected route?", comment: ""),
      style: .informational,
      firstButton: NSLocalizedString("OK", comment: ""),
      secondButton: NSLocalizedString("Cancel", comment: ""),
      thirdButton: nil
    )

    if response == .alertFirstButtonReturn {
      (delegate as? OSIAutoroutingPreferencePanePref)?.deleteSelectedRow(self)
    }
  }
}
