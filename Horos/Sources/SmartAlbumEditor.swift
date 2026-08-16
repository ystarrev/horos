import AppKit
import CoreData

@objc(HorosSmartAlbumEditor)
final class HorosSmartAlbumEditor: NSObject {
    @objc(presentForParentWindow:managedObjectContext:albumName:predicateFormat:existingAlbumNames:completion:)
    static func present(
        for parentWindow: NSWindow,
        managedObjectContext: NSManagedObjectContext,
        albumName: String?,
        predicateFormat: String?,
        existingAlbumNames: [String],
        completion: @escaping (String, String) -> Void
    ) {
        let editor = SmartAlbumEditorWindowController(
            managedObjectContext: managedObjectContext,
            albumName: albumName,
            predicateFormat: predicateFormat,
            existingAlbumNames: existingAlbumNames
        )

        guard let editorWindow = editor.window else { return }
        parentWindow.beginSheet(editorWindow) { [editor] response in
            guard response == .OK, let result = editor.result else { return }
            completion(result.name, result.predicateFormat)
        }
    }
}

private enum SmartAlbumMatchMode: Int {
    case all
    case any

    var title: String {
        switch self {
        case .all: return NSLocalizedString("All", comment: "Smart Album rule match mode")
        case .any: return NSLocalizedString("Any", comment: "Smart Album rule match mode")
        }
    }
}

private enum SmartAlbumField: Int, CaseIterable {
    case patientName
    case patientID
    case modality
    case studyDescription
    case seriesDescription
    case seriesDICOMDescription
    case accessionNumber
    case comments
    case referringPhysician
    case performingPhysician
    case institution
    case hasLegacyBrushROIs

    var title: String {
        switch self {
        case .patientName: return NSLocalizedString("Patient Name", comment: "Smart Album field")
        case .patientID: return NSLocalizedString("Patient ID", comment: "Smart Album field")
        case .modality: return NSLocalizedString("Modality", comment: "Smart Album field")
        case .studyDescription: return NSLocalizedString("Study Description", comment: "Smart Album field")
        case .seriesDescription: return NSLocalizedString("Series Description", comment: "Smart Album field")
        case .seriesDICOMDescription: return NSLocalizedString("Series DICOM Description", comment: "Smart Album field")
        case .accessionNumber: return NSLocalizedString("Accession Number", comment: "Smart Album field")
        case .comments: return NSLocalizedString("Comments", comment: "Smart Album field")
        case .referringPhysician: return NSLocalizedString("Referring Physician", comment: "Smart Album field")
        case .performingPhysician: return NSLocalizedString("Performing Physician", comment: "Smart Album field")
        case .institution: return NSLocalizedString("Institution", comment: "Smart Album field")
        case .hasLegacyBrushROIs: return NSLocalizedString("Has Legacy OsiriX Brush Masks", comment: "Smart Album field")
        }
    }

    var keyPath: String? {
        switch self {
        case .patientName: return "name"
        case .patientID: return "patientID"
        case .modality: return "modality"
        case .studyDescription: return "studyName"
        case .seriesDescription: return "series.name"
        case .seriesDICOMDescription: return "series.seriesDescription"
        case .accessionNumber: return "accessionNumber"
        case .comments: return "comment"
        case .referringPhysician: return "referringPhysician"
        case .performingPhysician: return "performingPhysician"
        case .institution: return "institutionName"
        case .hasLegacyBrushROIs: return nil
        }
    }

    var isSeriesField: Bool {
        switch self {
        case .seriesDescription, .seriesDICOMDescription: return true
        default: return false
        }
    }

    static func field(for keyPath: String, usesAny: Bool) -> SmartAlbumField? {
        allCases.first { field in
            guard let fieldKeyPath = field.keyPath else { return false }
            return fieldKeyPath == keyPath && field.isSeriesField == usesAny
        }
    }
}

private enum SmartAlbumOperator: Int, CaseIterable {
    case contains
    case beginsWith
    case isEqual
    case isNotEqual

    var title: String {
        switch self {
        case .contains: return NSLocalizedString("contains", comment: "Smart Album operator")
        case .beginsWith: return NSLocalizedString("begins with", comment: "Smart Album operator")
        case .isEqual: return NSLocalizedString("is", comment: "Smart Album operator")
        case .isNotEqual: return NSLocalizedString("is not", comment: "Smart Album operator")
        }
    }

    var predicateOperator: String {
        switch self {
        case .contains: return "CONTAINS[cd]"
        case .beginsWith: return "BEGINSWITH[cd]"
        case .isEqual: return "==[cd]"
        case .isNotEqual: return "!=[cd]"
        }
    }

    static func predicateOperator(named name: String) -> SmartAlbumOperator? {
        switch name.uppercased() {
        case "CONTAINS": return .contains
        case "BEGINSWITH": return .beginsWith
        case "==": return .isEqual
        case "!=": return .isNotEqual
        default: return nil
        }
    }
}

private struct SmartAlbumRule {
    var field: SmartAlbumField
    var comparison: SmartAlbumOperator
    var value: String

    private var booleanValue: Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "YES", "TRUE", "1": return true
        case "NO", "FALSE", "0": return false
        default: return nil
        }
    }

    func makePredicate() -> NSPredicate? {
        if field == .hasLegacyBrushROIs {
            guard comparison == .isEqual, let booleanValue else { return nil }
            let predicate = NSPredicate(format: HorosLegacyOsiriXBrushROIPredicateFormat)
            return booleanValue ? predicate : NSCompoundPredicate(notPredicateWithSubpredicate: predicate)
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false, let keyPath = field.keyPath else { return nil }

        let prefix = field.isSeriesField ? "ANY " : ""
        return NSPredicate(
            format: "\(prefix)\(keyPath) \(comparison.predicateOperator) %@",
            trimmedValue
        )
    }
}

private struct SmartAlbumPreviewStudy {
    let patientName: String
    let studyDescription: String
    let date: Date?
}

private struct SmartAlbumEditorResult {
    let name: String
    let predicateFormat: String
}

private final class SmartAlbumRuleRowView: NSView, NSTextFieldDelegate {
    var onChange: ((SmartAlbumRule) -> Void)?
    var onRemove: (() -> Void)?

    private let fieldPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let operatorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueField = NSTextField(frame: .zero)
    private let booleanValuePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeButton = NSButton(frame: .zero)

    private var rule: SmartAlbumRule

    init(rule: SmartAlbumRule) {
        self.rule = rule
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for field in SmartAlbumField.allCases {
            let item = NSMenuItem(title: field.title, action: nil, keyEquivalent: "")
            item.tag = field.rawValue
            fieldPopUp.menu?.addItem(item)
        }
        fieldPopUp.selectItem(withTag: rule.field.rawValue)
        fieldPopUp.target = self
        fieldPopUp.action = #selector(fieldChanged(_:))

        for comparison in SmartAlbumOperator.allCases {
            let item = NSMenuItem(title: comparison.title, action: nil, keyEquivalent: "")
            item.tag = comparison.rawValue
            operatorPopUp.menu?.addItem(item)
        }
        operatorPopUp.selectItem(withTag: rule.comparison.rawValue)
        operatorPopUp.target = self
        operatorPopUp.action = #selector(operatorChanged(_:))

        valueField.stringValue = rule.value
        valueField.placeholderString = NSLocalizedString("Value", comment: "Smart Album rule value placeholder")
        valueField.delegate = self

        let yesItem = NSMenuItem(title: NSLocalizedString("Yes", comment: "Smart Album Boolean value"), action: nil, keyEquivalent: "")
        yesItem.tag = 1
        booleanValuePopUp.menu?.addItem(yesItem)
        let noItem = NSMenuItem(title: NSLocalizedString("No", comment: "Smart Album Boolean value"), action: nil, keyEquivalent: "")
        noItem.tag = 0
        booleanValuePopUp.menu?.addItem(noItem)
        booleanValuePopUp.target = self
        booleanValuePopUp.action = #selector(booleanValueChanged(_:))

        removeButton.bezelStyle = .circular
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: NSLocalizedString("Remove Rule", comment: "Smart Album button"))
        removeButton.imagePosition = .imageOnly
        removeButton.toolTip = NSLocalizedString("Remove this rule", comment: "Smart Album button tooltip")
        removeButton.target = self
        removeButton.action = #selector(removeRule(_:))

        let stack = NSStackView(views: [fieldPopUp, operatorPopUp, valueField, booleanValuePopUp, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        booleanValuePopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        booleanValuePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            fieldPopUp.widthAnchor.constraint(equalToConstant: 185),
            operatorPopUp.widthAnchor.constraint(equalToConstant: 125),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 38)
        ])

        updateControlsForSelectedField()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        guard let field = SmartAlbumField(rawValue: sender.selectedTag()) else { return }
        let wasBooleanField = rule.field == .hasLegacyBrushROIs
        rule.field = field
        if field == .hasLegacyBrushROIs {
            rule.comparison = .isEqual
            rule.value = "YES"
        } else if wasBooleanField {
            rule.value = ""
        }
        updateControlsForSelectedField()
        onChange?(rule)
    }

    @objc private func operatorChanged(_ sender: NSPopUpButton) {
        guard let comparison = SmartAlbumOperator(rawValue: sender.selectedTag()) else { return }
        rule.comparison = comparison
        onChange?(rule)
    }

    func controlTextDidChange(_ notification: Notification) {
        rule.value = valueField.stringValue
        onChange?(rule)
    }

    @objc private func booleanValueChanged(_ sender: NSPopUpButton) {
        rule.value = sender.selectedTag() == 1 ? "YES" : "NO"
        onChange?(rule)
    }

    private func updateControlsForSelectedField() {
        let isBooleanField = rule.field == .hasLegacyBrushROIs
        if isBooleanField {
            rule.comparison = .isEqual
            let normalizedValue = rule.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if ["YES", "TRUE", "1"].contains(normalizedValue) {
                rule.value = "YES"
                booleanValuePopUp.selectItem(withTag: 1)
            } else {
                rule.value = "NO"
                booleanValuePopUp.selectItem(withTag: 0)
            }
        }

        operatorPopUp.selectItem(withTag: rule.comparison.rawValue)
        operatorPopUp.isEnabled = isBooleanField == false
        valueField.stringValue = rule.value
        valueField.isHidden = isBooleanField
        booleanValuePopUp.isHidden = isBooleanField == false
    }

    @objc private func removeRule(_ sender: NSButton) {
        onRemove?()
    }
}

private final class SmartAlbumEditorWindowController: NSWindowController,
    NSTextFieldDelegate,
    NSTextViewDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let managedObjectContext: NSManagedObjectContext
    private let originalName: String?
    private let existingAlbumNames: [String]

    private let nameField = NSTextField(frame: .zero)
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeControl = NSSegmentedControl(
        labels: [
            NSLocalizedString("Rules", comment: "Smart Album editor mode"),
            NSLocalizedString("Advanced", comment: "Smart Album editor mode")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let matchPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rulesStack = NSStackView()
    private let rulesContainer = NSView(frame: .zero)
    private let advancedContainer = NSView(frame: .zero)
    private let predicateTextView = NSTextView(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(frame: .zero)
    private let previewTable = NSTableView(frame: .zero)

    private var rules: [SmartAlbumRule] = []
    private var previewStudies: [SmartAlbumPreviewStudy] = []
    private var previewWorkItem: DispatchWorkItem?
    private var previewGeneration = 0
    private var advancedPredicateWasEdited = false
    private var isUpdatingPredicateProgrammatically = false

    fileprivate var result: SmartAlbumEditorResult?

    private var matchMode: SmartAlbumMatchMode {
        SmartAlbumMatchMode(rawValue: matchPopUp.selectedTag()) ?? .all
    }

    private var isAdvancedMode: Bool {
        modeControl.selectedSegment == 1
    }

    init(
        managedObjectContext: NSManagedObjectContext,
        albumName: String?,
        predicateFormat: String?,
        existingAlbumNames: [String]
    ) {
        self.managedObjectContext = managedObjectContext
        self.originalName = albumName
        self.existingAlbumNames = existingAlbumNames

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = albumName == nil
            ? NSLocalizedString("New Smart Album", comment: "Smart Album window title")
            : NSLocalizedString("Edit Smart Album", comment: "Smart Album window title")
        window.minSize = NSSize(width: 760, height: 610)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        configureInterface()
        configureInitialState(albumName: albumName, predicateFormat: predicateFormat)
        refreshValidationAndPreview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureInterface() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("Collect studies automatically", comment: "Smart Album heading"))
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "A Smart Album is a saved study query. Series rules include a study when any of its series matches.",
            comment: "Smart Album explanation"
        ))
        subtitleLabel.textColor = .secondaryLabelColor

        let nameLabel = NSTextField(labelWithString: NSLocalizedString("Name:", comment: "Smart Album name label"))
        nameLabel.alignment = .right
        nameField.placeholderString = NSLocalizedString("e.g. Sella MRI Cohort", comment: "Smart Album name placeholder")
        nameField.delegate = self

        presetPopUp.addItem(withTitle: NSLocalizedString("Custom", comment: "Smart Album preset"))
        presetPopUp.addItem(withTitle: NSLocalizedString("Sella MRI", comment: "Smart Album preset"))
        presetPopUp.addItem(withTitle: NSLocalizedString("Dynamic Sella MRI", comment: "Smart Album preset"))
        presetPopUp.addItem(withTitle: NSLocalizedString("Added in the Last Week", comment: "Smart Album preset"))
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged(_:))
        presetPopUp.toolTip = NSLocalizedString("Start with a useful cohort predicate", comment: "Smart Album preset tooltip")

        let nameRow = NSStackView(views: [nameLabel, nameField, presetPopUp])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 10
        nameLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        presetPopUp.widthAnchor.constraint(equalToConstant: 190).isActive = true

        modeControl.selectedSegment = 0
        modeControl.role = .tabs
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setWidth(110, forSegment: 0)
        modeControl.setWidth(110, forSegment: 1)

        configureRulesContainer()
        configureAdvancedContainer()
        configurePreviewTable()

        let previewTitle = NSTextField(labelWithString: NSLocalizedString("Matching Studies", comment: "Smart Album preview heading"))
        previewTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor

        let previewHeader = NSStackView(views: [previewTitle, NSView(), countLabel])
        previewHeader.orientation = .horizontal
        previewHeader.alignment = .centerY

        let previewScroll = NSScrollView(frame: .zero)
        previewScroll.borderType = .bezelBorder
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.documentView = previewTable
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Smart Album button"), target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.title = originalName == nil
            ? NSLocalizedString("Create", comment: "Smart Album button")
            : NSLocalizedString("Save", comment: "Smart Album button")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        window?.defaultButtonCell = saveButton.cell as? NSButtonCell

        let footer = NSStackView(views: [statusLabel, NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let rootStack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            nameRow,
            modeControl,
            rulesContainer,
            advancedContainer,
            previewHeader,
            previewScroll,
            footer
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.setCustomSpacing(5, after: titleLabel)
        rootStack.setCustomSpacing(18, after: subtitleLabel)
        rootStack.setCustomSpacing(16, after: nameRow)
        rootStack.setCustomSpacing(6, after: modeControl)
        rootStack.setCustomSpacing(16, after: advancedContainer)
        contentView.addSubview(rootStack)

        for view in [subtitleLabel, nameRow, modeControl, rulesContainer, advancedContainer, previewHeader, previewScroll, footer] {
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
    }

    private func configureRulesContainer() {
        rulesContainer.translatesAutoresizingMaskIntoConstraints = false

        for mode in [SmartAlbumMatchMode.all, .any] {
            let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
            item.tag = mode.rawValue
            matchPopUp.menu?.addItem(item)
        }
        matchPopUp.selectItem(withTag: SmartAlbumMatchMode.all.rawValue)
        matchPopUp.target = self
        matchPopUp.action = #selector(matchModeChanged(_:))

        let matchSuffix = NSTextField(labelWithString: NSLocalizedString("of the following rules", comment: "Smart Album rule match label"))
        let addButton = NSButton(title: NSLocalizedString("Add Rule", comment: "Smart Album button"), target: self, action: #selector(addRule(_:)))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading

        let header = NSStackView(views: [matchPopUp, matchSuffix, NSView(), addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 2
        rulesStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.documentView = rulesStack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        rulesContainer.addSubview(header)
        rulesContainer.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: rulesContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rulesContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: rulesContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: rulesContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rulesContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: rulesContainer.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 132),
            rulesStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12)
        ])
    }

    private func configureAdvancedContainer() {
        advancedContainer.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "Use an NSPredicate for queries that need dates, nested groups, or fields not listed in Rules. Existing advanced predicates are preserved exactly.",
            comment: "Smart Album advanced explanation"
        ))
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false

        predicateTextView.isRichText = false
        predicateTextView.isAutomaticQuoteSubstitutionEnabled = false
        predicateTextView.isAutomaticDashSubstitutionEnabled = false
        predicateTextView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        predicateTextView.delegate = self
        predicateTextView.textContainerInset = NSSize(width: 7, height: 7)

        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = predicateTextView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tokenHelp = NSTextField(labelWithString: NSLocalizedString(
            "Relative dates: $NSDATE_TODAY, $NSDATE_WEEK, $NSDATE_MONTH, $NSDATE_YEAR",
            comment: "Smart Album advanced date help"
        ))
        tokenHelp.textColor = .tertiaryLabelColor
        tokenHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tokenHelp.translatesAutoresizingMaskIntoConstraints = false

        advancedContainer.addSubview(explanation)
        advancedContainer.addSubview(scroll)
        advancedContainer.addSubview(tokenHelp)

        NSLayoutConstraint.activate([
            explanation.leadingAnchor.constraint(equalTo: advancedContainer.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: advancedContainer.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: advancedContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: advancedContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: advancedContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 8),
            scroll.heightAnchor.constraint(equalToConstant: 96),
            tokenHelp.leadingAnchor.constraint(equalTo: advancedContainer.leadingAnchor),
            tokenHelp.trailingAnchor.constraint(equalTo: advancedContainer.trailingAnchor),
            tokenHelp.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            tokenHelp.bottomAnchor.constraint(equalTo: advancedContainer.bottomAnchor)
        ])
    }

    private func configurePreviewTable() {
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.rowHeight = 22
        previewTable.headerView = NSTableHeaderView()
        previewTable.delegate = self
        previewTable.dataSource = self

        let patientColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("patient"))
        patientColumn.title = NSLocalizedString("Patient", comment: "Smart Album preview column")
        patientColumn.width = 210
        patientColumn.minWidth = 120

        let descriptionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("description"))
        descriptionColumn.title = NSLocalizedString("Study Description", comment: "Smart Album preview column")
        descriptionColumn.width = 390
        descriptionColumn.minWidth = 180

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = NSLocalizedString("Date", comment: "Smart Album preview column")
        dateColumn.width = 130
        dateColumn.minWidth = 100

        previewTable.addTableColumn(patientColumn)
        previewTable.addTableColumn(descriptionColumn)
        previewTable.addTableColumn(dateColumn)
    }

    private func configureInitialState(albumName: String?, predicateFormat: String?) {
        nameField.stringValue = albumName ?? ""

        if let format = predicateFormat?.trimmingCharacters(in: .whitespacesAndNewlines),
           format.isEmpty == false {
            if let parsed = SmartAlbumPredicateParser.parse(format) {
                rules = parsed.rules
                matchPopUp.selectItem(withTag: parsed.matchMode.rawValue)
                modeControl.selectedSegment = 0
            } else {
                rules = [SmartAlbumRule(field: .studyDescription, comparison: .contains, value: "")]
                setAdvancedPredicate(format, consideredEdited: true)
                modeControl.selectedSegment = 1
            }
        } else {
            rules = [SmartAlbumRule(field: .studyDescription, comparison: .contains, value: "")]
            modeControl.selectedSegment = 0
        }

        rebuildRuleRows()
        updateModeVisibility()
    }

    private func rebuildRuleRows() {
        rulesStack.arrangedSubviews.forEach { view in
            rulesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for index in rules.indices {
            let row = SmartAlbumRuleRowView(rule: rules[index])
            row.onChange = { [weak self] updatedRule in
                guard let self, self.rules.indices.contains(index) else { return }
                self.rules[index] = updatedRule
                self.advancedPredicateWasEdited = false
                self.presetPopUp.selectItem(at: 0)
                self.refreshValidationAndPreview()
            }
            row.onRemove = { [weak self] in
                guard let self, self.rules.indices.contains(index) else { return }
                self.rules.remove(at: index)
                if self.rules.isEmpty {
                    self.rules.append(SmartAlbumRule(field: .studyDescription, comparison: .contains, value: ""))
                }
                self.advancedPredicateWasEdited = false
                self.presetPopUp.selectItem(at: 0)
                self.rebuildRuleRows()
                self.refreshValidationAndPreview()
            }
            rulesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rulesStack.widthAnchor, constant: -4).isActive = true
        }
    }

    private func updateModeVisibility() {
        rulesContainer.isHidden = isAdvancedMode
        advancedContainer.isHidden = !isAdvancedMode
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 && advancedPredicateWasEdited == false {
            setAdvancedPredicate(rulesPredicate()?.predicateFormat ?? "", consideredEdited: false)
        }
        updateModeVisibility()
        refreshValidationAndPreview()
    }

    @objc private func matchModeChanged(_ sender: NSPopUpButton) {
        advancedPredicateWasEdited = false
        presetPopUp.selectItem(at: 0)
        refreshValidationAndPreview()
    }

    @objc private func addRule(_ sender: NSButton) {
        rules.append(SmartAlbumRule(field: .studyDescription, comparison: .contains, value: ""))
        advancedPredicateWasEdited = false
        presetPopUp.selectItem(at: 0)
        rebuildRuleRows()
        refreshValidationAndPreview()
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let predicate: String?
        let suggestedName: String?

        switch sender.indexOfSelectedItem {
        case 1:
            suggestedName = NSLocalizedString("Sella MRI", comment: "Smart Album suggested name")
            predicate = "modality CONTAINS[cd] \"MR\" AND (studyName CONTAINS[cd] \"SELLA\" OR studyName CONTAINS[cd] \"PITUITARY\" OR SUBQUERY(series, $series, $series.name CONTAINS[cd] \"SELLA\" OR $series.name CONTAINS[cd] \"PITUITARY\" OR $series.seriesDescription CONTAINS[cd] \"SELLA\" OR $series.seriesDescription CONTAINS[cd] \"PITUITARY\").@count > 0)"
        case 2:
            suggestedName = NSLocalizedString("Dynamic Sella MRI", comment: "Smart Album suggested name")
            predicate = "modality CONTAINS[cd] \"MR\" AND (studyName CONTAINS[cd] \"SELLA\" OR studyName CONTAINS[cd] \"PITUITARY\" OR SUBQUERY(series, $series, $series.name CONTAINS[cd] \"SELLA\" OR $series.name CONTAINS[cd] \"PITUITARY\" OR $series.seriesDescription CONTAINS[cd] \"SELLA\" OR $series.seriesDescription CONTAINS[cd] \"PITUITARY\").@count > 0) AND SUBQUERY(series, $series, $series.name CONTAINS[cd] \"DYNAMIC\" OR $series.seriesDescription CONTAINS[cd] \"DYNAMIC\").@count > 0"
        case 3:
            suggestedName = NSLocalizedString("Added in the Last Week", comment: "Smart Album suggested name")
            predicate = "dateAdded >= $NSDATE_WEEK"
        default:
            return
        }

        if originalName == nil || nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nameField.stringValue = suggestedName ?? ""
        }
        setAdvancedPredicate(predicate ?? "", consideredEdited: true)
        modeControl.selectedSegment = 1
        updateModeVisibility()
        refreshValidationAndPreview()
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshValidationAndPreview()
    }

    func textDidChange(_ notification: Notification) {
        guard isUpdatingPredicateProgrammatically == false else { return }
        advancedPredicateWasEdited = true
        presetPopUp.selectItem(at: 0)
        refreshValidationAndPreview()
    }

    private func setAdvancedPredicate(_ predicate: String, consideredEdited: Bool) {
        isUpdatingPredicateProgrammatically = true
        predicateTextView.string = predicate
        isUpdatingPredicateProgrammatically = false
        advancedPredicateWasEdited = consideredEdited
    }

    private func rulesPredicate() -> NSPredicate? {
        let predicates = rules.compactMap { $0.makePredicate() }
        guard predicates.count == rules.count, predicates.isEmpty == false else { return nil }

        switch matchMode {
        case .all: return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        case .any: return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        }
    }

    private func resolvedPredicate() -> NSPredicate? {
        let predicate: NSPredicate?
        if isAdvancedMode {
            let format = predicateTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard format.isEmpty == false else { return nil }
            predicate = BrowserController.safeSmartAlbumPredicate(withFormat: format)
        } else {
            predicate = rulesPredicate()
        }
        guard let predicate else { return nil }
        return BrowserController.optimizedSmartAlbumPredicate(predicate)
    }

    private func predicateFormatForSaving() -> String? {
        if isAdvancedMode {
            let format = predicateTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return format.isEmpty ? nil : format
        }
        return rulesPredicate()?.predicateFormat
    }

    private func nameValidationMessage() -> String? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else {
            return NSLocalizedString("Enter an album name.", comment: "Smart Album validation")
        }

        let duplicate = existingAlbumNames.contains { existingName in
            let isOriginalName = originalName.map {
                existingName.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? false
            guard isOriginalName == false else { return false }
            return existingName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        if duplicate {
            return NSLocalizedString("An album with this name already exists.", comment: "Smart Album validation")
        }
        return nil
    }

    private func refreshValidationAndPreview() {
        previewWorkItem?.cancel()
        previewGeneration += 1

        if let nameMessage = nameValidationMessage() {
            statusLabel.stringValue = nameMessage
            statusLabel.textColor = .systemRed
            saveButton.isEnabled = false
        } else if resolvedPredicate() == nil {
            statusLabel.stringValue = isAdvancedMode
                ? NSLocalizedString("Enter a valid predicate.", comment: "Smart Album validation")
                : NSLocalizedString("Complete every rule.", comment: "Smart Album validation")
            statusLabel.textColor = .systemRed
            saveButton.isEnabled = false
        } else {
            statusLabel.stringValue = NSLocalizedString("The album updates automatically as the database changes.", comment: "Smart Album status")
            statusLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = true
        }

        guard let predicate = resolvedPredicate() else {
            previewStudies = []
            previewTable.reloadData()
            countLabel.stringValue = NSLocalizedString("No valid query", comment: "Smart Album match count")
            return
        }

        let generation = previewGeneration
        countLabel.stringValue = NSLocalizedString("Counting…", comment: "Smart Album match count")
        let workItem = DispatchWorkItem { [weak self] in
            self?.loadPreview(predicate: predicate, generation: generation)
        }
        previewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func loadPreview(predicate: NSPredicate, generation: Int) {
        managedObjectContext.perform { [weak self] in
            guard let self else { return }

            do {
                let previewRequest = NSFetchRequest<NSDictionary>(entityName: "Study")
                previewRequest.predicate = predicate
                previewRequest.includesSubentities = false
                previewRequest.resultType = .dictionaryResultType
                previewRequest.propertiesToFetch = ["name", "studyName", "date"]
                previewRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                let rows = try self.managedObjectContext.fetch(previewRequest)
                let studies = rows.prefix(12).map { row in
                    SmartAlbumPreviewStudy(
                        patientName: row["name"] as? String ?? "",
                        studyDescription: row["studyName"] as? String ?? "",
                        date: row["date"] as? Date
                    )
                }
                let count = rows.count

                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    self.previewStudies = studies
                    self.previewTable.reloadData()
                    self.countLabel.stringValue = String.localizedStringWithFormat(
                        NSLocalizedString("%ld studies", comment: "Smart Album match count"),
                        count
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    self.previewStudies = []
                    self.previewTable.reloadData()
                    self.countLabel.stringValue = NSLocalizedString("Unable to preview", comment: "Smart Album match count")
                    self.statusLabel.stringValue = error.localizedDescription
                    self.statusLabel.textColor = .systemRed
                    self.saveButton.isEnabled = false
                }
            }
        }
    }

    @objc private func cancel(_ sender: NSButton) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }

    @objc private func save(_ sender: NSButton) {
        guard nameValidationMessage() == nil,
              resolvedPredicate() != nil,
              let predicateFormat = predicateFormatForSaving(),
              let window
        else { return }

        result = SmartAlbumEditorResult(
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            predicateFormat: predicateFormat
        )
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        previewStudies.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previewStudies.indices.contains(row), let tableColumn else { return nil }

        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let newCell = NSTableCellView(frame: .zero)
            newCell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(label)
            newCell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
            ])
            return newCell
        }()

        let study = previewStudies[row]
        switch identifier.rawValue {
        case "patient":
            cell.textField?.stringValue = study.patientName
        case "description":
            cell.textField?.stringValue = study.studyDescription
        case "date":
            if let date = study.date {
                cell.textField?.stringValue = Self.previewDateFormatter.string(from: date)
            } else {
                cell.textField?.stringValue = ""
            }
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    private static let previewDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private enum SmartAlbumPredicateParser {
    struct ParsedPredicate {
        let matchMode: SmartAlbumMatchMode
        let rules: [SmartAlbumRule]
    }

    static func parse(_ format: String) -> ParsedPredicate? {
        let expression = strippingOuterParentheses(from: format.trimmingCharacters(in: .whitespacesAndNewlines))
        guard expression.isEmpty == false else { return nil }

        let andParts = topLevelParts(in: expression, separator: " AND ")
        let orParts = topLevelParts(in: expression, separator: " OR ")

        let matchMode: SmartAlbumMatchMode
        let parts: [String]
        if andParts.count > 1 && orParts.count == 1 {
            matchMode = .all
            parts = andParts
        } else if orParts.count > 1 && andParts.count == 1 {
            matchMode = .any
            parts = orParts
        } else if andParts.count == 1 && orParts.count == 1 {
            matchMode = .all
            parts = [expression]
        } else {
            return nil
        }

        let rules = parts.compactMap { parseRule(strippingOuterParentheses(from: $0)) }
        guard rules.count == parts.count, rules.isEmpty == false else { return nil }
        return ParsedPredicate(matchMode: matchMode, rules: rules)
    }

    private static func parseRule(_ expression: String) -> SmartAlbumRule? {
        if let hasLegacyBrushROIsRule = parseHasLegacyBrushROIsRule(expression) {
            return hasLegacyBrushROIsRule
        }

        let pattern = #"^\s*(ANY\s+)?([A-Za-z][A-Za-z0-9_.]*)\s+(CONTAINS|BEGINSWITH|==|!=)(?:\[cd\])?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        guard let match = regex.firstMatch(in: expression, options: [], range: range), match.numberOfRanges == 5 else { return nil }

        let usesAny = match.range(at: 1).location != NSNotFound
        guard let keyPathRange = Range(match.range(at: 2), in: expression),
              let operatorRange = Range(match.range(at: 3), in: expression),
              let valueRange = Range(match.range(at: 4), in: expression),
              let field = SmartAlbumField.field(for: String(expression[keyPathRange]), usesAny: usesAny),
              let comparison = SmartAlbumOperator.predicateOperator(named: String(expression[operatorRange]))
        else { return nil }

        let value = unquoted(String(expression[valueRange]))
        guard value.isEmpty == false else { return nil }
        return SmartAlbumRule(field: field, comparison: comparison, value: value)
    }

    private static func parseHasLegacyBrushROIsRule(_ expression: String) -> SmartAlbumRule? {
        for value in ["YES", "NO"] {
            let rule = SmartAlbumRule(field: .hasLegacyBrushROIs, comparison: .isEqual, value: value)
            let isTrue = value == "YES"
            let legacyCountComparison = isTrue ? "> 0" : "== 0"
            let legacyPredicate = NSPredicate(format: "SUBQUERY(series, $series, ($series.name ==[cd] \"OsiriX ROI SR\" OR $series.seriesDescription ==[cd] \"OsiriX ROI SR\") AND SUBQUERY($series.images, $image, $image.scale > 0).@count > 0).@count \(legacyCountComparison)")
            let candidates = [rule.makePredicate()?.predicateFormat, legacyPredicate.predicateFormat].compactMap { $0 }
            if candidates.contains(where: { normalizedPredicate(expression) == normalizedPredicate($0) }) {
                return rule
            }
        }
        return nil
    }

    private static func normalizedPredicate(_ expression: String) -> String {
        strippingOuterParentheses(from: expression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .lowercased()
    }

    private static func topLevelParts(in expression: String, separator: String) -> [String] {
        var parts: [String] = []
        var start = expression.startIndex
        var index = expression.startIndex
        var depth = 0
        var quote: Character?
        var escaped = false

        while index < expression.endIndex {
            let character = expression[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = expression.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }

            if depth == 0, expression[index...].hasPrefix(separator) {
                parts.append(String(expression[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                index = expression.index(index, offsetBy: separator.count)
                start = index
                continue
            }
            index = expression.index(after: index)
        }

        parts.append(String(expression[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func strippingOuterParentheses(from expression: String) -> String {
        var result = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.first == "(", result.last == ")", outerParenthesesEncloseWholeExpression(result) {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func outerParenthesesEncloseWholeExpression(_ expression: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false

        for (offset, character) in expression.enumerated() {
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 && offset < expression.count - 1 { return false }
            }
        }
        return depth == 0
    }

    private static func unquoted(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" || first == "'"),
              first == last
        else { return trimmed }

        var value = String(trimmed.dropFirst().dropLast())
        value = value.replacingOccurrences(of: "\\\"", with: "\"")
        value = value.replacingOccurrences(of: "\\'", with: "'")
        value = value.replacingOccurrences(of: "\\\\", with: "\\")
        return value
    }
}
