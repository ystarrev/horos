import AppKit
import UniformTypeIdentifiers
import UserNotifications

private final class GeneralFlippedView: NSView {
  override var isFlipped: Bool { true }
}

private struct GeneralLanguagePreference {
  let folderName: String
  let displayName: String
  var isActive: Bool
}

@objc(HorosNotificationService)
final class HorosNotificationService: NSObject, UNUserNotificationCenterDelegate {
  private static let shared = HorosNotificationService()

  @objc(configure)
  class func configure() {
    let center = UNUserNotificationCenter.current()
    center.delegate = shared

    guard UserDefaults.standard.bool(forKey: "displayNotifications") else { return }
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      requestAuthorization()
    }
  }

  @objc(postWithTitle:description:name:)
  class func post(title: String, description: String, name: String) {
    guard UserDefaults.standard.bool(forKey: "displayNotifications") else { return }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = description
    content.threadIdentifier = name
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        NSLog(
          "User Notification failed for title=[%@] description=[%@] error=[%@]",
          title,
          description.replacingOccurrences(of: "\r", with: "\n"),
          error.localizedDescription
        )
      }
    }
  }

  fileprivate class func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      _, error in
      if let error {
        NSLog(
          "User Notification authorization request failed, error=[%@]",
          error.localizedDescription
        )
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if UserDefaults.standard.bool(forKey: "displayNotifications") {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([])
    }
  }
}

@objc(HorosGeneralPreferences)
final class HorosGeneralPreferences: NSObject {
  private static var pendingLanguages: [GeneralLanguagePreference]?

  @objc(registerDefaults)
  class func registerDefaults() {
    migrateLegacyNotificationPreference()
    UserDefaults.standard.register(defaults: defaultValues)
  }

  private static var defaultValues: [String: Any] {
    [
      "ALLOWDICOMEDITING": false,
      "CheckHorosUpdates": true,
      "CompressionResolutionLimit": 512,
      "CompressionSettings": compressionDefaults(defaultQuality: 1),
      "CompressionSettingsLowRes": compressionDefaults(defaultQuality: 0),
      "SyncPreferencesFromURL": false,
      "SyncPreferencesURL": "",
      "UseJPEGColorSpace": true,
      "displayNotifications": true,
    ]
  }

  @objc(addPreferencesFromURL:)
  class func addPreferences(from url: URL?) {
    autoreleasepool {
      var succeeded = false

      if let url {
        NSLog("--- loading preferences from URL: %@", url.absoluteString)

        do {
          let defaults = UserDefaults.standard
          let wasActivated =
            Thread.isMainThread == false
            ? defaults.bool(forKey: "SyncPreferencesFromURL")
            : false
          try loadPreferences(from: url)
          succeeded = true

          if Thread.isMainThread == false {
            defaults.set(url.absoluteString, forKey: "SyncPreferencesURL")
            defaults.set(wasActivated, forKey: "SyncPreferencesFromURL")
          }
        } catch {
          NSLog(
            "Failed to load Horos preferences from %@: %@", url.absoluteString,
            error.localizedDescription)
        }

        NSLog("--- loading preferences from URL: %@ - DONE", url.absoluteString)
      }

      if succeeded == false {
        DispatchQueue.main.async {
          showPreferenceLoadError(for: url)
        }
      }
    }
  }

  @objc(applyLanguagesIfNeeded)
  class func applyLanguagesIfNeeded() {
    guard let languages = pendingLanguages else { return }

    let fileManager = FileManager.default
    let activePath = Bundle.main.resourcePath ?? ""
    let inactivePath = (activePath as NSString)
      .deletingLastPathComponent
      .appending("/Resources Disabled")

    if fileManager.fileExists(atPath: inactivePath) == false {
      try? fileManager.createDirectory(
        atPath: inactivePath,
        withIntermediateDirectories: false,
        attributes: nil
      )
    }

    for language in languages {
      let languageDirectory =
        (language.folderName as NSString).appendingPathExtension("lproj")
        ?? language.folderName
      let activeLanguagePath = (activePath as NSString).appendingPathComponent(languageDirectory)
      let inactiveLanguagePath = (inactivePath as NSString).appendingPathComponent(
        languageDirectory)

      do {
        if language.isActive, fileManager.fileExists(atPath: inactiveLanguagePath) {
          try? fileManager.removeItem(atPath: activeLanguagePath)
          try fileManager.moveItem(atPath: inactiveLanguagePath, toPath: activeLanguagePath)
        } else if language.isActive == false,
          fileManager.fileExists(atPath: activeLanguagePath)
        {
          try? fileManager.removeItem(atPath: inactiveLanguagePath)
          try fileManager.moveItem(atPath: activeLanguagePath, toPath: inactiveLanguagePath)
        }
      } catch {
        NSLog(
          "*********** applyLanguagesIfNeeded failed: %@ %@", languageDirectory,
          error.localizedDescription)
      }
    }

    pendingLanguages = nil
  }

  fileprivate class func availableLanguages() -> [GeneralLanguagePreference] {
    let fileManager = FileManager.default
    guard let activePath = Bundle.main.resourcePath else { return [] }

    var languagesByFolder: [String: GeneralLanguagePreference] = [:]
    addLanguages(
      from: activePath,
      active: true,
      fileManager: fileManager,
      to: &languagesByFolder
    )

    let inactivePath = (activePath as NSString)
      .deletingLastPathComponent
      .appending("/Resources Disabled")
    addLanguages(
      from: inactivePath,
      active: false,
      fileManager: fileManager,
      to: &languagesByFolder
    )

    return languagesByFolder.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  fileprivate class func stageLanguages(_ languages: [GeneralLanguagePreference]) {
    pendingLanguages = languages
  }

  fileprivate class func savePreferences(to url: URL) throws {
    var defaultPreferences = DefaultsOsiriX.getDefaults() as? [String: Any] ?? [:]
    defaultPreferences.merge(defaultValues) { _, generalDefault in generalDefault }
    let currentPreferences = UserDefaults.standard.dictionaryRepresentation()
    var customizedPreferences: [String: Any] = [:]

    for (key, currentValue) in currentPreferences {
      if let defaultValue = defaultPreferences[key],
        let currentObject = currentValue as? NSObject,
        currentObject.isEqual(defaultValue)
      {
        continue
      }
      customizedPreferences[key] = currentValue
    }

    let data = try PropertyListSerialization.data(
      fromPropertyList: customizedPreferences,
      format: .xml,
      options: 0
    )
    try data.write(to: url, options: .atomic)
  }

  fileprivate class func loadPreferences(from url: URL) throws {
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    guard let customizedPreferences = propertyList as? [String: Any] else {
      throw CocoaError(.propertyListReadCorrupt)
    }

    let defaults = UserDefaults.standard
    for (key, value) in customizedPreferences {
      defaults.set(value, forKey: key)
    }
  }

  private class func addLanguages(
    from path: String,
    active: Bool,
    fileManager: FileManager,
    to languages: inout [String: GeneralLanguagePreference]
  ) {
    let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
    for file in contents where (file as NSString).pathExtension == "lproj" {
      let identifier = (file as NSString).deletingPathExtension
      let displayName = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
      languages[identifier] = GeneralLanguagePreference(
        folderName: identifier,
        displayName: displayName,
        isActive: active
      )
    }
  }

  private class func compressionDefaults(defaultQuality: Int) -> [[String: Any]] {
    let modalities = [
      "default", "CR", "CT", "DX", "ES", "MG", "MR", "NM", "OT", "PT", "RF", "SC", "US", "XA",
    ]
    return modalities.enumerated().map { index, modality in
      [
        "modality": index == 0 ? NSLocalizedString(modality, comment: "") : modality,
        "compression": index == 0 ? "3" : "0",
        "quality": String(defaultQuality),
      ]
    }
  }

  private class func migrateLegacyNotificationPreference() {
    let defaults = UserDefaults.standard
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let persistentPreferences = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]

    if persistentPreferences["displayNotifications"] == nil,
      let legacyValue = persistentPreferences["displayGrowlNotification"] as? NSNumber
    {
      defaults.set(legacyValue.boolValue, forKey: "displayNotifications")
    }
    defaults.removeObject(forKey: "displayGrowlNotification")
  }

  private class func showPreferenceLoadError(for url: URL?) {
    let format = NSLocalizedString(
      "Failed to download and synchronize preferences from this URL: %@",
      comment: ""
    )
    _ = HorosAlertPresenter.run(
      title: NSLocalizedString("Preferences", comment: ""),
      message: String(format: format, url?.absoluteString ?? ""),
      style: .warning,
      firstButton: NSLocalizedString("OK", comment: ""),
      secondButton: nil,
      thirdButton: nil
    )
  }
}

private struct GeneralCompressionPreference {
  var modality: String
  var compression: Int
  var quality: Int

  init(propertyList: [String: Any]) {
    modality = propertyList["modality"] as? String ?? ""
    compression = Self.integerValue(propertyList["compression"])
    quality = Self.integerValue(propertyList["quality"])
  }

  var propertyListRepresentation: [String: Any] {
    [
      "modality": modality,
      "compression": String(compression),
      "quality": String(quality),
    ]
  }

  private static func integerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
  }
}

private final class GeneralCompressionSettingsController: NSWindowController,
  NSTableViewDataSource, NSTableViewDelegate
{
  private enum TableKind: String {
    case lowResolution
    case standard
  }

  private let lowResolutionTable = NSTableView(frame: .zero)
  private let standardTable = NSTableView(frame: .zero)
  private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private var lowResolutionSettings: [GeneralCompressionPreference] = []
  private var standardSettings: [GeneralCompressionPreference] = []

  init() {
    super.init(window: nil)
    loadStoredPreferences()
    buildWindow()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func buildWindow() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 540),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    panel.title = NSLocalizedString("JPEG Compression", comment: "")

    let contentView = GeneralFlippedView(frame: panel.contentView?.bounds ?? .zero)
    contentView.autoresizingMask = [.width, .height]
    panel.contentView = contentView

    let limitLabel = NSTextField(labelWithString: "If matrix size is smaller than:")
    limitLabel.frame = NSRect(x: 20, y: 20, width: 190, height: 22)
    contentView.addSubview(limitLabel)

    for value in [128, 256, 320, 512, 640, 1024, 2048] {
      resolutionPopup.addItem(withTitle: String(value))
      resolutionPopup.lastItem?.tag = value
    }
    resolutionPopup.selectItem(
      withTag: UserDefaults.standard.integer(forKey: "CompressionResolutionLimit"))
    resolutionPopup.frame = NSRect(x: 212, y: 15, width: 90, height: 30)
    contentView.addSubview(resolutionPopup)

    let lowResolutionLabel = NSTextField(labelWithString: "Smaller images")
    lowResolutionLabel.font = .systemFont(ofSize: 15, weight: .medium)
    lowResolutionLabel.frame = NSRect(x: 20, y: 58, width: 220, height: 22)
    contentView.addSubview(lowResolutionLabel)

    let standardLabel = NSTextField(labelWithString: "All other images")
    standardLabel.font = .systemFont(ofSize: 15, weight: .medium)
    standardLabel.frame = NSRect(x: 500, y: 58, width: 220, height: 22)
    contentView.addSubview(standardLabel)

    let lowScrollView = makeTableScrollView(
      tableView: lowResolutionTable,
      kind: .lowResolution
    )
    lowScrollView.frame = NSRect(x: 20, y: 86, width: 460, height: 390)
    contentView.addSubview(lowScrollView)

    let standardScrollView = makeTableScrollView(
      tableView: standardTable,
      kind: .standard
    )
    standardScrollView.frame = NSRect(x: 500, y: 86, width: 460, height: 390)
    contentView.addSubview(standardScrollView)

    let cancelButton = NSButton(
      title: NSLocalizedString("Cancel", comment: ""),
      target: self,
      action: #selector(cancel(_:))
    )
    cancelButton.bezelStyle = .rounded
    cancelButton.frame = NSRect(x: 752, y: 494, width: 96, height: 32)
    contentView.addSubview(cancelButton)

    let saveButton = NSButton(
      title: NSLocalizedString("OK", comment: ""),
      target: self,
      action: #selector(save(_:))
    )
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"
    saveButton.frame = NSRect(x: 856, y: 494, width: 96, height: 32)
    contentView.addSubview(saveButton)

    window = panel
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    settings(for: tableView).count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let tableColumn else { return nil }
    let preference = settings(for: tableView)[row]
    let kind = tableView === lowResolutionTable ? TableKind.lowResolution : TableKind.standard

    switch tableColumn.identifier.rawValue {
    case "modality":
      let label = NSTextField(labelWithString: preference.modality)
      label.alignment = .center
      return label

    case "compression":
      let popup = NSPopUpButton(frame: .zero, pullsDown: false)
      addCompressionItem("Same As Default", tag: 0, to: popup)
      addCompressionItem("No Compression", tag: 1, to: popup)
      addCompressionItem("JPEG2000 Lossless/Lossy", tag: 3, to: popup)
      addCompressionItem("JPEG-LS Lossless/Lossy", tag: 4, to: popup)
      popup.selectItem(withTag: preference.compression)
      popup.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
      popup.tag = row
      popup.target = self
      popup.action = #selector(compressionChanged(_:))
      return popup

    case "quality":
      let slider = NSSlider(
        value: Double(preference.quality),
        minValue: 0,
        maxValue: 3,
        target: self,
        action: #selector(qualityChanged(_:))
      )
      slider.numberOfTickMarks = 4
      slider.allowsTickMarkValuesOnly = true
      slider.tickMarkPosition = .above
      slider.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
      slider.tag = row
      slider.isEnabled = preference.compression == 3 || preference.compression == 4
      return slider

    default:
      return nil
    }
  }

  private func loadStoredPreferences() {
    let defaults = UserDefaults.standard
    if (defaults.array(forKey: "CompressionSettings")?.count ?? 0) < 14 {
      defaults.removeObject(forKey: "CompressionSettings")
    }
    if (defaults.array(forKey: "CompressionSettingsLowRes")?.count ?? 0) < 14 {
      defaults.removeObject(forKey: "CompressionSettingsLowRes")
    }

    standardSettings = Self.compressionPreferences(forKey: "CompressionSettings")
    lowResolutionSettings = Self.compressionPreferences(forKey: "CompressionSettingsLowRes")
  }

  private static func compressionPreferences(forKey key: String) -> [GeneralCompressionPreference] {
    let dictionaries = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
    return dictionaries.map(GeneralCompressionPreference.init(propertyList:))
  }

  private func makeTableScrollView(
    tableView: NSTableView,
    kind: TableKind
  ) -> NSScrollView {
    let modalityColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modality"))
    modalityColumn.title = NSLocalizedString("Modality", comment: "")
    modalityColumn.width = 88
    tableView.addTableColumn(modalityColumn)

    let compressionColumn = NSTableColumn(
      identifier: NSUserInterfaceItemIdentifier("compression"))
    compressionColumn.title = NSLocalizedString("Compression", comment: "")
    compressionColumn.width = 205
    tableView.addTableColumn(compressionColumn)

    let qualityColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quality"))
    qualityColumn.title = NSLocalizedString("Quality", comment: "")
    qualityColumn.width = 145
    tableView.addTableColumn(qualityColumn)

    tableView.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = 28
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.headerView = NSTableHeaderView()
    tableView.frame = NSRect(
      x: 0,
      y: 0,
      width: 458,
      height: max(CGFloat(settings(for: tableView).count) * 30 + 24, 390)
    )
    tableView.autoresizingMask = [.width]

    let scrollView = NSScrollView(frame: .zero)
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = tableView
    return scrollView
  }

  private func addCompressionItem(_ title: String, tag: Int, to popup: NSPopUpButton) {
    popup.addItem(withTitle: NSLocalizedString(title, comment: ""))
    popup.lastItem?.tag = tag
  }

  private func settings(for tableView: NSTableView) -> [GeneralCompressionPreference] {
    tableView === lowResolutionTable ? lowResolutionSettings : standardSettings
  }

  @objc private func compressionChanged(_ sender: NSPopUpButton) {
    guard let kind = TableKind(rawValue: sender.identifier?.rawValue ?? "") else { return }
    let compression = sender.selectedItem?.tag ?? 0
    switch kind {
    case .lowResolution:
      lowResolutionSettings[sender.tag].compression = compression
      lowResolutionTable.reloadData(
        forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 2))
    case .standard:
      standardSettings[sender.tag].compression = compression
      standardTable.reloadData(
        forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 2))
    }
  }

  @objc private func qualityChanged(_ sender: NSSlider) {
    guard let kind = TableKind(rawValue: sender.identifier?.rawValue ?? "") else { return }
    switch kind {
    case .lowResolution:
      lowResolutionSettings[sender.tag].quality = sender.integerValue
    case .standard:
      standardSettings[sender.tag].quality = sender.integerValue
    }
  }

  @objc private func cancel(_ sender: Any?) {
    guard let window else { return }
    window.sheetParent?.endSheet(window, returnCode: .cancel)
  }

  @objc private func save(_ sender: Any?) {
    let defaults = UserDefaults.standard
    defaults.set(
      standardSettings.map(\.propertyListRepresentation),
      forKey: "CompressionSettings"
    )
    defaults.set(
      lowResolutionSettings.map(\.propertyListRepresentation),
      forKey: "CompressionSettingsLowRes"
    )
    defaults.set(resolutionPopup.selectedItem?.tag ?? 512, forKey: "CompressionResolutionLimit")

    guard let window else { return }
    window.sheetParent?.endSheet(window, returnCode: .OK)
  }
}

final class GeneralSettingsPaneViewController: HorosSettingsPaneViewController,
  NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
  private enum DefaultsKey {
    static let allowDICOMEditing = "ALLOWDICOMEDITING"
    static let checkForUpdates = "CheckHorosUpdates"
    static let displayNotifications = "displayNotifications"
    static let syncFromURL = "SyncPreferencesFromURL"
    static let syncURL = "SyncPreferencesURL"
    static let useJPEGColorSpace = "UseJPEGColorSpace"
  }

  private enum Layout {
    static let contentWidth: CGFloat = 780
    static let documentHeight: CGFloat = 970
  }

  private let scrollView = NSScrollView(frame: .zero)
  private let documentView = GeneralFlippedView(frame: .zero)
  private let applicationCard = GeneralFlippedView(frame: .zero)
  private let preferencesCard = GeneralFlippedView(frame: .zero)
  private let compressionCard = GeneralFlippedView(frame: .zero)
  private let languagesCard = GeneralFlippedView(frame: .zero)

  private let notificationsButton = NSButton(
    checkboxWithTitle: NSLocalizedString("Display Notifications", comment: ""),
    target: nil,
    action: nil
  )
  private let updatesButton = NSButton(
    checkboxWithTitle: NSLocalizedString(
      "Automatically check for Horos application updates at startup", comment: ""),
    target: nil,
    action: nil
  )
  private let dicomEditingButton = NSButton(
    checkboxWithTitle: NSLocalizedString(
      "Allow DICOM Editing in the Meta-Data window", comment: ""),
    target: nil,
    action: nil
  )
  private let jpegColorSpaceButton = NSButton(
    checkboxWithTitle: NSLocalizedString(
      "Use the JPEG photometric value for color JPEG DICOMs", comment: ""),
    target: nil,
    action: nil
  )
  private let syncButton = NSButton(
    checkboxWithTitle: NSLocalizedString(
      "Synchronize preferences at startup from this URL", comment: ""),
    target: nil,
    action: nil
  )
  private let syncURLField = NSTextField(frame: .zero)
  private let refreshButton = NSButton(frame: .zero)
  private let languagesTable = NSTableView(frame: .zero)

  private var languages: [GeneralLanguagePreference] = []
  private var compressionController: GeneralCompressionSettingsController?
  private var defaultsObserver: NSObjectProtocol?

  init() {
    super.init(paneTitle: "General")
  }

  deinit {
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
    }
  }

  override func loadView() {
    let rootView = GeneralFlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
    view = rootView

    scrollView.frame = rootView.bounds
    scrollView.autoresizingMask = [.width, .height]
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = documentView
    rootView.addSubview(scrollView)

    configureInterface()
    languages = HorosGeneralPreferences.availableLanguages()
    languagesTable.reloadData()
    updateLanguagesTableFrame()
    updateControlsFromDefaults()
    layoutInterface()

    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateControlsFromDefaults()
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    layoutInterface()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    languages.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let tableColumn else { return nil }
    let language = languages[row]

    if tableColumn.identifier.rawValue == "active" {
      let button = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(languageSelectionChanged(_:))
      )
      button.state = language.isActive ? .on : .off
      button.tag = row
      return button
    }

    return NSTextField(labelWithString: language.displayName)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    saveSyncURL()
  }

  private func configureInterface() {
    let titleLabel = NSTextField(labelWithString: NSLocalizedString("General", comment: ""))
    titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
    titleLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
    titleLabel.frame = NSRect(x: 0, y: 28, width: 400, height: 36)
    titleLabel.identifier = NSUserInterfaceItemIdentifier("generalTitle")
    documentView.addSubview(titleLabel)

    let subtitle = NSTextField(
      wrappingLabelWithString: NSLocalizedString(
        "Application behavior, preference portability, compression, and languages.",
        comment: ""
      ))
    subtitle.font = .systemFont(ofSize: 14)
    subtitle.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
    subtitle.frame = NSRect(x: 0, y: 68, width: Layout.contentWidth, height: 22)
    subtitle.identifier = NSUserInterfaceItemIdentifier("generalSubtitle")
    documentView.addSubview(subtitle)

    configureCard(applicationCard, title: NSLocalizedString("Application", comment: ""))
    configureCard(preferencesCard, title: NSLocalizedString("Preferences", comment: ""))
    configureCard(compressionCard, title: NSLocalizedString("JPEG Compression", comment: ""))
    configureCard(languagesCard, title: NSLocalizedString("Languages", comment: ""))

    configurePreferenceButton(notificationsButton, key: DefaultsKey.displayNotifications)
    notificationsButton.frame = NSRect(x: 22, y: 52, width: 350, height: 22)
    applicationCard.addSubview(notificationsButton)

    configurePreferenceButton(updatesButton, key: DefaultsKey.checkForUpdates)
    updatesButton.frame = NSRect(x: 22, y: 82, width: 520, height: 22)
    applicationCard.addSubview(updatesButton)

    configurePreferenceButton(dicomEditingButton, key: DefaultsKey.allowDICOMEditing)
    dicomEditingButton.frame = NSRect(x: 22, y: 112, width: 460, height: 22)
    applicationCard.addSubview(dicomEditingButton)

    configurePreferenceButton(jpegColorSpaceButton, key: DefaultsKey.useJPEGColorSpace)
    jpegColorSpaceButton.frame = NSRect(x: 22, y: 142, width: 520, height: 22)
    applicationCard.addSubview(jpegColorSpaceButton)

    let resetButton = makeButton(
      title: NSLocalizedString("Reset Preferences", comment: ""),
      action: #selector(resetPreferences(_:))
    )
    resetButton.frame = NSRect(x: 18, y: 50, width: 180, height: 32)
    preferencesCard.addSubview(resetButton)

    let saveButton = makeButton(
      title: NSLocalizedString("Save Preferences…", comment: ""),
      action: #selector(savePreferences(_:))
    )
    saveButton.frame = NSRect(x: 210, y: 50, width: 180, height: 32)
    preferencesCard.addSubview(saveButton)

    let loadButton = makeButton(
      title: NSLocalizedString("Load Preferences…", comment: ""),
      action: #selector(loadPreferences(_:))
    )
    loadButton.frame = NSRect(x: 402, y: 50, width: 180, height: 32)
    preferencesCard.addSubview(loadButton)

    syncButton.target = self
    syncButton.action = #selector(syncPreferenceChanged(_:))
    syncButton.frame = NSRect(x: 22, y: 100, width: 460, height: 22)
    preferencesCard.addSubview(syncButton)

    syncURLField.placeholderString = "https://example.com/Horos-Preferences.plist"
    syncURLField.delegate = self
    syncURLField.target = self
    syncURLField.action = #selector(syncURLChanged(_:))
    syncURLField.frame = NSRect(x: 42, y: 132, width: 590, height: 24)
    preferencesCard.addSubview(syncURLField)

    refreshButton.bezelStyle = .texturedRounded
    refreshButton.image = NSImage(named: NSImage.Name("NSRefreshTemplate"))
    refreshButton.imagePosition = .imageOnly
    refreshButton.target = self
    refreshButton.action = #selector(refreshPreferencesURL(_:))
    refreshButton.frame = NSRect(x: 640, y: 130, width: 32, height: 28)
    preferencesCard.addSubview(refreshButton)

    let compressionDescription = NSTextField(
      wrappingLabelWithString: NSLocalizedString(
        "Choose modality-specific compression and quality settings for imported DICOM images.",
        comment: ""
      ))
    compressionDescription.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
    compressionDescription.frame = NSRect(x: 22, y: 52, width: 560, height: 38)
    compressionCard.addSubview(compressionDescription)

    let compressionButton = makeButton(
      title: NSLocalizedString("Configure…", comment: ""),
      action: #selector(configureCompression(_:))
    )
    compressionButton.frame = NSRect(x: 628, y: 54, width: 126, height: 32)
    compressionCard.addSubview(compressionButton)

    let activeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("active"))
    activeColumn.title = NSLocalizedString("Enabled", comment: "")
    activeColumn.width = 78
    languagesTable.addTableColumn(activeColumn)

    let languageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
    languageColumn.title = NSLocalizedString("Language", comment: "")
    languageColumn.width = 330
    languagesTable.addTableColumn(languageColumn)
    languagesTable.dataSource = self
    languagesTable.delegate = self
    languagesTable.rowHeight = 24
    languagesTable.usesAlternatingRowBackgroundColors = true
    languagesTable.headerView = NSTableHeaderView()

    let languageScrollView = NSScrollView(frame: NSRect(x: 22, y: 54, width: 430, height: 190))
    languageScrollView.borderType = .bezelBorder
    languageScrollView.hasVerticalScroller = true
    languageScrollView.autohidesScrollers = true
    languageScrollView.documentView = languagesTable
    languagesCard.addSubview(languageScrollView)

    let languageDescription = NSTextField(
      wrappingLabelWithString: NSLocalizedString(
        "Restart Horos to apply changes. When multiple languages are enabled, macOS chooses the language according to the app language order.",
        comment: ""
      ))
    languageDescription.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
    languageDescription.frame = NSRect(x: 480, y: 64, width: 270, height: 86)
    languagesCard.addSubview(languageDescription)
  }

  private func layoutInterface() {
    let documentWidth = max(view.bounds.width, 900)
    documentView.frame = NSRect(
      x: 0,
      y: 0,
      width: documentWidth,
      height: Layout.documentHeight
    )
    let x = (documentWidth - Layout.contentWidth) / 2

    setHorizontalOrigin(x, forSubviewIdentifiedBy: "generalTitle")
    setHorizontalOrigin(x, forSubviewIdentifiedBy: "generalSubtitle")
    applicationCard.frame = NSRect(x: x, y: 108, width: Layout.contentWidth, height: 184)
    preferencesCard.frame = NSRect(x: x, y: 312, width: Layout.contentWidth, height: 180)
    compressionCard.frame = NSRect(x: x, y: 512, width: Layout.contentWidth, height: 108)
    languagesCard.frame = NSRect(x: x, y: 640, width: Layout.contentWidth, height: 270)
  }

  private func setHorizontalOrigin(_ x: CGFloat, forSubviewIdentifiedBy identifier: String) {
    guard
      let subview = documentView.subviews.first(where: { $0.identifier?.rawValue == identifier })
    else { return }
    var frame = subview.frame
    frame.origin.x = x
    subview.frame = frame
  }

  private func configureCard(_ card: NSView, title: String) {
    card.wantsLayer = true
    card.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
    card.layer?.cornerRadius = 14
    card.layer?.borderWidth = 1
    card.layer?.borderColor = NSColor(calibratedWhite: 0.24, alpha: 1).cgColor
    documentView.addSubview(card)

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 18, weight: .medium)
    label.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
    label.frame = NSRect(x: 22, y: 18, width: 300, height: 24)
    card.addSubview(label)
  }

  private func configurePreferenceButton(_ button: NSButton, key: String) {
    button.identifier = NSUserInterfaceItemIdentifier(key)
    button.target = self
    button.action = #selector(preferenceChanged(_:))
  }

  private func makeButton(title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  private func updateControlsFromDefaults() {
    guard isViewLoaded else { return }
    let defaults = UserDefaults.standard
    notificationsButton.state = defaults.bool(forKey: DefaultsKey.displayNotifications) ? .on : .off
    updatesButton.state = defaults.bool(forKey: DefaultsKey.checkForUpdates) ? .on : .off
    dicomEditingButton.state = defaults.bool(forKey: DefaultsKey.allowDICOMEditing) ? .on : .off
    jpegColorSpaceButton.state = defaults.bool(forKey: DefaultsKey.useJPEGColorSpace) ? .on : .off
    syncButton.state = defaults.bool(forKey: DefaultsKey.syncFromURL) ? .on : .off

    if syncURLField.currentEditor() == nil {
      syncURLField.stringValue = defaults.string(forKey: DefaultsKey.syncURL) ?? ""
    }

    let isAppStoreBuild = defaults.bool(forKey: "MACAPPSTORE")
    updatesButton.isHidden = isAppStoreBuild
    syncButton.isHidden = isAppStoreBuild
    syncURLField.isHidden = isAppStoreBuild
    refreshButton.isHidden = isAppStoreBuild

    let syncEnabled = syncButton.state == .on && isAppStoreBuild == false
    syncURLField.isEnabled = syncEnabled
    refreshButton.isEnabled = syncEnabled
  }

  private func saveSyncURL() {
    UserDefaults.standard.set(syncURLField.stringValue, forKey: DefaultsKey.syncURL)
  }

  @objc private func preferenceChanged(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    let enabled = sender.state == .on
    UserDefaults.standard.set(enabled, forKey: key)

    if key == DefaultsKey.displayNotifications, enabled {
      HorosNotificationService.requestAuthorization()
    }
  }

  @objc private func syncPreferenceChanged(_ sender: NSButton) {
    UserDefaults.standard.set(sender.state == .on, forKey: DefaultsKey.syncFromURL)
    updateControlsFromDefaults()
  }

  @objc private func syncURLChanged(_ sender: NSTextField) {
    saveSyncURL()
  }

  @objc private func languageSelectionChanged(_ sender: NSButton) {
    guard languages.indices.contains(sender.tag) else { return }
    languages[sender.tag].isActive = sender.state == .on

    if languages.contains(where: \.isActive) == false {
      languages[sender.tag].isActive = true
      NSSound.beep()
    }

    languagesTable.reloadData()
    updateLanguagesTableFrame()
    HorosGeneralPreferences.stageLanguages(languages)
  }

  private func updateLanguagesTableFrame() {
    languagesTable.frame = NSRect(
      x: 0,
      y: 0,
      width: 428,
      height: max(CGFloat(languages.count) * 26 + 24, 190)
    )
    languagesTable.autoresizingMask = [.width]
  }

  @objc private func resetPreferences(_ sender: Any?) {
    let response = HorosAlertPresenter.run(
      title: NSLocalizedString("Reset Preferences", comment: ""),
      message: NSLocalizedString(
        "Are you sure you want to reset ALL preferences of Horos? All preferences will return to their default values.",
        comment: ""
      ),
      style: .informational,
      firstButton: NSLocalizedString("Cancel", comment: ""),
      secondButton: NSLocalizedString("OK", comment: ""),
      thirdButton: nil
    )
    guard response == .alertSecondButtonReturn else { return }

    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
      defaults.removeObject(forKey: key)
    }
    updateControlsFromDefaults()
  }

  @objc private func savePreferences(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.propertyList]
    panel.nameFieldStringValue = "Horos-Preferences.plist"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      try HorosGeneralPreferences.savePreferences(to: url)
    } catch {
      NSLog("Failed to save Horos preferences to %@: %@", url.path, error.localizedDescription)
    }
  }

  @objc private func loadPreferences(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.propertyList]
    panel.message = NSLocalizedString("Select the preferences file to load:", comment: "")
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let response = HorosAlertPresenter.run(
      title: NSLocalizedString("Load Preferences", comment: ""),
      message: NSLocalizedString(
        "Are you sure you want to replace the current preferences with the preferences stored in this file? You cannot undo this operation.",
        comment: ""
      ),
      style: .informational,
      firstButton: NSLocalizedString("Cancel", comment: ""),
      secondButton: NSLocalizedString("OK", comment: ""),
      thirdButton: nil
    )
    guard response == .alertSecondButtonReturn else { return }

    do {
      try HorosGeneralPreferences.loadPreferences(from: url)
      updateControlsFromDefaults()
    } catch {
      NSLog("Failed to load Horos preferences from %@: %@", url.path, error.localizedDescription)
    }
  }

  @objc private func refreshPreferencesURL(_ sender: Any?) {
    view.window?.makeFirstResponder(nil)
    saveSyncURL()

    let urlString = syncURLField.stringValue
    guard let url = URL(string: urlString), url.scheme?.isEmpty == false else {
      _ = HorosAlertPresenter.run(
        title: NSLocalizedString("Sync Preferences", comment: ""),
        message: NSLocalizedString(
          "The provided URL doesn't seem correct. Check its validity.", comment: ""),
        style: .informational,
        firstButton: NSLocalizedString("OK", comment: ""),
        secondButton: nil,
        thirdButton: nil
      )
      return
    }

    let response = HorosAlertPresenter.run(
      title: NSLocalizedString("Sync Preferences", comment: ""),
      message: NSLocalizedString(
        "Are you sure you want to replace the current preferences with the preferences stored at this URL? You cannot undo this operation.",
        comment: ""
      ),
      style: .informational,
      firstButton: NSLocalizedString("Cancel", comment: ""),
      secondButton: NSLocalizedString("OK", comment: ""),
      thirdButton: nil
    )

    if response == .alertSecondButtonReturn {
      Thread.detachNewThread {
        HorosGeneralPreferences.addPreferences(from: url)
      }
    }
  }

  @objc private func configureCompression(_ sender: Any?) {
    guard let parentWindow = view.window else { return }
    let controller = GeneralCompressionSettingsController()
    compressionController = controller
    guard let sheet = controller.window else { return }

    parentWindow.beginSheet(sheet) { [weak self] _ in
      self?.compressionController = nil
    }
  }
}
