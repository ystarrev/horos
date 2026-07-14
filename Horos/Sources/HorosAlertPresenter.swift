import AppKit

/// Centralized modern alert presentation for Swift and Objective-C callers.
@objc(HorosAlertPresenter)
final class HorosAlertPresenter: NSObject {
  @objc(runWithTitle:message:style:firstButton:secondButton:thirdButton:)
  static func run(
    title: String,
    message: String,
    style: NSAlert.Style,
    firstButton: String,
    secondButton: String?,
    thirdButton: String?
  ) -> NSApplication.ModalResponse {
    performOnMainThread {
      let alert = makeAlert(
        title: title,
        message: message,
        style: style,
        firstButton: firstButton,
        secondButton: secondButton,
        thirdButton: thirdButton
      )
      return alert.runModal()
    }
  }

  @objc(beginSheetForWindow:title:message:style:firstButton:secondButton:thirdButton:completion:)
  static func beginSheet(
    for window: NSWindow,
    title: String,
    message: String,
    style: NSAlert.Style,
    firstButton: String,
    secondButton: String?,
    thirdButton: String?,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    let present = {
      let alert = makeAlert(
        title: title,
        message: message,
        style: style,
        firstButton: firstButton,
        secondButton: secondButton,
        thirdButton: thirdButton
      )
      alert.beginSheetModal(for: window) { response in
        completion(response)
        _ = alert
      }
    }

    if Thread.isMainThread {
      present()
    } else {
      DispatchQueue.main.async(execute: present)
    }
  }

  private static func makeAlert(
    title: String,
    message: String,
    style: NSAlert.Style,
    firstButton: String,
    secondButton: String?,
    thirdButton: String?
  ) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: firstButton)

    if let secondButton, secondButton.isEmpty == false {
      alert.addButton(withTitle: secondButton)
    }
    if let thirdButton, thirdButton.isEmpty == false {
      alert.addButton(withTitle: thirdButton)
    }

    return alert
  }

  private static func performOnMainThread<Result>(_ work: () -> Result) -> Result {
    if Thread.isMainThread {
      return work()
    }
    return DispatchQueue.main.sync(execute: work)
  }
}
