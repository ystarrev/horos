import AppKit
import CoreData

private final class HorosSettingsRootView: NSView {
    override var isFlipped: Bool { true }
}

private struct HorosSettingsPaneDescriptor {
    let identifier: String
    let title: String
    let imageName: String
}

private final class HorosSettingsPaneContainerView: NSView {
    override var isFlipped: Bool { true }
}

private class HorosSettingsPaneViewController: NSViewController {
    let paneTitle: String

    init(paneTitle: String) {
        self.paneTitle = paneTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum AnnotationPlaceholderPosition: String, CaseIterable {
    case topLeft = "TopLeft"
    case topMiddle = "TopMiddle"
    case topRight = "TopRight"
    case middleLeft = "MiddleLeft"
    case middleRight = "MiddleRight"
    case lowerLeft = "LowerLeft"
    case lowerMiddle = "LowerMiddle"
    case lowerRight = "LowerRight"

    var alignment: NSTextAlignment {
        switch self {
        case .topLeft, .middleLeft, .lowerLeft:
            return .left
        case .topMiddle, .lowerMiddle:
            return .center
        case .topRight, .middleRight, .lowerRight:
            return .right
        }
    }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topMiddle: return "Top Middle"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .middleRight: return "Middle Right"
        case .lowerLeft: return "Lower Left"
        case .lowerMiddle: return "Lower Middle"
        case .lowerRight: return "Lower Right"
        }
    }

    var slotCapacity: Int {
        switch self {
        case .topLeft:
            return 5
        case .topMiddle, .middleLeft, .middleRight, .lowerMiddle:
            return 1
        case .topRight:
            return 4
        case .lowerLeft:
            return 4
        case .lowerRight:
            return 3
        }
    }
}

private struct AnnotationSelection: Equatable {
    let position: AnnotationPlaceholderPosition
    let index: Int?
}

private struct AnnotationDropTarget: Equatable {
    let position: AnnotationPlaceholderPosition
    let insertionIndex: Int
}

private struct DICOMFieldDescriptor {
    let group: Int
    let element: Int
    let name: String

    var title: String {
        String(format: "(0x%04x,0x%04x) %@", group, element, name)
    }
}

private struct HorosAnnotationItem {
    var title: String
    var content: [String]

    var isOrientationWidget: Bool {
        title == "Orientation" && content == ["Special_Orientation"]
    }

    init(title: String, content: [String]) {
        self.title = title
        self.content = content
    }

    init?(propertyList: [String: Any]) {
        guard let title = propertyList["title"] as? String,
              let content = propertyList["content"] as? [String]
        else {
            return nil
        }

        self.init(title: title, content: content)
    }

    func propertyListRepresentation() -> [String: Any] {
        [
            "title": title,
            "content": content,
            "fullContent": content.map { token in
                if token.hasPrefix("DICOM_") {
                    var field: [String: Any] = [
                        "type": "DICOM",
                        "tokenTitle": token
                    ]

                    let suffix = String(token.dropFirst(6))
                    let components = suffix.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
                    if components.count >= 2,
                       let group = UInt32(components[0], radix: 16),
                       let element = UInt32(components[1], radix: 16) {
                        field["group"] = Int(group)
                        field["element"] = Int(element)
                        if components.count > 2 {
                            field["name"] = components.dropFirst(2).joined(separator: "_")
                        }
                    } else {
                        field["name"] = suffix
                    }

                    return field
                }

                if token.hasPrefix("DB_") {
                    let suffix = String(token.dropFirst(3))
                    let components = suffix.split(separator: ".", maxSplits: 1).map(String.init)
                    if components.count == 2 {
                        return [
                            "type": "DB",
                            "level": components[0],
                            "field": components[1]
                        ]
                    }
                }

                if token.hasPrefix("Special_") {
                    return [
                        "type": "Special",
                        "field": String(token.dropFirst(8))
                    ]
                }

                return [
                    "type": "Manual",
                    "field": token
                ]
            }
        ]
    }
}

private struct HorosAnnotationLayout {
    var sameAsDefault: Bool
    var placeholders: [AnnotationPlaceholderPosition: [HorosAnnotationItem]]

    init(sameAsDefault: Bool = false, placeholders: [AnnotationPlaceholderPosition: [HorosAnnotationItem]] = [:]) {
        self.sameAsDefault = sameAsDefault
        self.placeholders = placeholders

        for position in AnnotationPlaceholderPosition.allCases where self.placeholders[position] == nil {
            self.placeholders[position] = []
        }
    }

    init(propertyList: [String: Any]) {
        let sameValue = propertyList["sameAsDefault"]
        sameAsDefault = (sameValue as? String) == "1" || (sameValue as? NSNumber)?.boolValue == true
        placeholders = [:]

        for position in AnnotationPlaceholderPosition.allCases {
            let items = (propertyList[position.rawValue] as? [[String: Any]])?.compactMap(HorosAnnotationItem.init(propertyList:)) ?? []
            placeholders[position] = items
        }
    }

    var hasAnyAnnotations: Bool {
        placeholders.values.contains { !$0.isEmpty }
    }

    func propertyListRepresentation(forInheritedMode inherited: Bool) -> [String: Any] {
        if inherited {
            return ["sameAsDefault": "1"]
        }

        var representation: [String: Any] = ["sameAsDefault": "0"]
        for position in AnnotationPlaceholderPosition.allCases {
            representation[position.rawValue] = (placeholders[position] ?? []).map { $0.propertyListRepresentation() }
        }
        return representation
    }
}

private final class HorosAnnotationsPreferenceStore {
    static let defaultsKey = "CUSTOM_IMAGE_ANNOTATIONS"

    private let defaultLayouts: [String: HorosAnnotationLayout]
    private var storedLayouts: [String: HorosAnnotationLayout]

    init() {
        defaultLayouts = Self.loadLayouts(from: Self.defaultPropertyList()) ?? [:]
        storedLayouts = Self.loadLayouts(from: UserDefaults.standard.dictionary(forKey: Self.defaultsKey)) ?? [:]
    }

    func availableModalities() -> [String] {
        let keys = Set(defaultLayouts.keys).union(storedLayouts.keys)
        let sortedKeys = keys.sorted { lhs, rhs in
            if lhs == "Default" { return true }
            if rhs == "Default" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedKeys.isEmpty ? ["Default"] : sortedKeys
    }

    func editableLayout(for modality: String) -> (layout: HorosAnnotationLayout, inherited: Bool) {
        let fallback = defaultLayouts[modality] ?? defaultLayouts["Default"] ?? HorosAnnotationLayout()

        if modality == "Default" {
            if let stored = storedLayouts[modality], stored.hasAnyAnnotations {
                var layout = stored
                layout.sameAsDefault = false
                return (layout, false)
            }
            var layout = fallback
            layout.sameAsDefault = false
            return (layout, false)
        }

        if let stored = storedLayouts[modality] {
            if stored.sameAsDefault || !stored.hasAnyAnnotations {
                return (fallback, true)
            }

            var layout = stored
            layout.sameAsDefault = false
            return (layout, false)
        }

        return (fallback, true)
    }

    func save(layout: HorosAnnotationLayout, modality: String, inherited: Bool) {
        if modality == "Default" {
            var saved = layout
            saved.sameAsDefault = false
            storedLayouts[modality] = saved
        } else if inherited {
            storedLayouts[modality] = HorosAnnotationLayout(sameAsDefault: true)
        } else {
            var saved = layout
            saved.sameAsDefault = false
            storedLayouts[modality] = saved
        }

        let propertyList = storedLayouts.mapValues { layout in
            layout.propertyListRepresentation(forInheritedMode: layout.sameAsDefault)
        }
        UserDefaults.standard.set(propertyList, forKey: Self.defaultsKey)
    }

    func restoreSavedState(for modality: String) -> (layout: HorosAnnotationLayout, inherited: Bool) {
        editableLayout(for: modality)
    }

    private static func defaultPropertyList() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "AnnotationsDefault", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
        else {
            return nil
        }

        return dictionary
    }

    private static func loadLayouts(from propertyList: [String: Any]?) -> [String: HorosAnnotationLayout]? {
        guard let propertyList else {
            return nil
        }

        var layouts: [String: HorosAnnotationLayout] = [:]
        for (key, value) in propertyList {
            if let layoutDictionary = value as? [String: Any] {
                layouts[key] = HorosAnnotationLayout(propertyList: layoutDictionary)
            }
        }
        return layouts
    }
}

private final class AnnotationsCanvasView: NSView {
    private enum CanvasMetrics {
        static let outerInsetX: CGFloat = 22
        static let outerInsetY: CGFloat = 22
        static let placeholderTopInset: CGFloat = 11
        static let placeholderBottomInset: CGFloat = 11
        static let chipHorizontalInset: CGFloat = 8
        static let chipHeight: CGFloat = 22
        static let chipVerticalGap: CGFloat = 6
        static let chipCornerRadius: CGFloat = 7
        static let placeholderCornerRadius: CGFloat = 12
    }

    private struct ChipLayout {
        let frame: CGRect
        let item: HorosAnnotationItem
        let index: Int
    }

    private struct DragState {
        let sourceSelection: AnnotationSelection
        let item: HorosAnnotationItem
        let dragOffset: CGPoint
        var currentPoint: CGPoint
        var dropTarget: AnnotationDropTarget?
    }

    override var isFlipped: Bool { true }

    var layout = HorosAnnotationLayout() {
        didSet { needsDisplay = true }
    }

    var selected = AnnotationSelection(position: .topLeft, index: nil) {
        didSet { needsDisplay = true }
    }

    var editingEnabled = true {
        didSet { needsDisplay = true }
    }

    var selectionHandler: ((AnnotationSelection) -> Void)?
    var moveHandler: ((AnnotationSelection, AnnotationDropTarget) -> Void)?

    private var mouseDownPoint: CGPoint?
    private var mouseDownSelection: AnnotationSelection?
    private var mouseDownItem: HorosAnnotationItem?
    private var dragState: DragState?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownSelection = nil
        mouseDownItem = nil
        dragState = nil

        for position in AnnotationPlaceholderPosition.allCases {
            let placeholderRect = placeholderRect(for: position)
            if let chip = chipLayouts(for: position).first(where: { $0.frame.contains(point) }) {
                let selection = AnnotationSelection(position: position, index: chip.index)
                mouseDownSelection = selection
                mouseDownItem = chip.item
                selectionHandler?(selection)
                return
            }

            if placeholderRect.contains(point) {
                let selection = AnnotationSelection(position: position, index: nil)
                mouseDownSelection = selection
                selectionHandler?(selection)
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editingEnabled,
              let mouseDownPoint,
              let sourceSelection = mouseDownSelection,
              let sourceIndex = sourceSelection.index,
              let sourceItem = mouseDownItem
        else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let delta = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        guard delta >= 4 else { return }

        if dragState == nil {
            guard let sourceChip = chipLayouts(for: sourceSelection.position).first(where: { $0.index == sourceIndex }) else {
                return
            }

            dragState = DragState(
                sourceSelection: sourceSelection,
                item: sourceItem,
                dragOffset: CGPoint(x: point.x - sourceChip.frame.minX, y: point.y - sourceChip.frame.minY),
                currentPoint: point,
                dropTarget: dropTarget(at: point, ignoring: sourceSelection)
            )
        } else {
            dragState?.currentPoint = point
            dragState?.dropTarget = dropTarget(at: point, ignoring: sourceSelection)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownSelection = nil
            mouseDownItem = nil
            dragState = nil
            needsDisplay = true
        }

        guard let dragState else { return }
        guard let dropTarget = dragState.dropTarget else { return }
        moveHandler?(dragState.sourceSelection, dropTarget)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        bounds.fill()

        let dashPattern: [CGFloat] = [4, 4]

        for position in AnnotationPlaceholderPosition.allCases {
            let rect = placeholderRect(for: position)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let isDropTarget = dragState?.dropTarget?.position == position

            if isDropTarget {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            } else if selected.position == position {
                NSColor(calibratedWhite: 0.27, alpha: 1).setFill()
            } else {
                NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
            }
            path.fill()

            path.lineWidth = 1.25
            path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            let strokeColor: NSColor
            if isDropTarget {
                strokeColor = NSColor.systemBlue
            } else {
                strokeColor = editingEnabled
                    ? NSColor(calibratedWhite: 0.45, alpha: 1)
                    : NSColor(calibratedWhite: 0.30, alpha: 1)
            }
            strokeColor.setStroke()
            path.stroke()

            drawSlotGuides(in: rect, for: position)

            for chip in chipLayouts(for: position) {
                if let dragState,
                   dragState.sourceSelection.position == position,
                   dragState.sourceSelection.index == chip.index {
                    continue
                }

                drawChip(item: chip.item, in: chip.frame, selected: selected.position == position && selected.index == chip.index, alpha: 1)
            }
        }

        if let dragState {
            let dragRect = CGRect(
                x: dragState.currentPoint.x - dragState.dragOffset.x,
                y: dragState.currentPoint.y - dragState.dragOffset.y,
                width: min(max(chipWidth(for: dragState.item.title), 72), 220),
                height: CanvasMetrics.chipHeight
            )
            drawChip(item: dragState.item, in: dragRect, selected: true, alpha: 0.92)
        }

        if !editingEnabled {
            let notice = NSAttributedString(
                string: "Using the Default layout for this modality",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
                ]
            )
            let size = notice.size()
            let origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12)
            notice.draw(at: origin)
        }
    }

    private func placeholderRect(for position: AnnotationPlaceholderPosition) -> CGRect {
        let usable = bounds.insetBy(dx: CanvasMetrics.outerInsetX, dy: CanvasMetrics.outerInsetY)

        let leftWidth = min(usable.width * 0.22, 188)
        let centerWidth = min(usable.width * 0.15, 136)
        let rightWidth = min(usable.width * 0.24, 210)

        let topLeftHeight = placeholderHeight(for: .topLeft)
        let topMiddleHeight = placeholderHeight(for: .topMiddle)
        let topRightHeight = placeholderHeight(for: .topRight)
        let middleLeftHeight = placeholderHeight(for: .middleLeft)
        let middleRightHeight = placeholderHeight(for: .middleRight)
        let lowerLeftHeight = placeholderHeight(for: .lowerLeft)
        let lowerMiddleHeight = placeholderHeight(for: .lowerMiddle)
        let lowerRightHeight = placeholderHeight(for: .lowerRight)

        let topY = usable.minY + 10
        let middleLeftY = usable.midY - middleLeftHeight / 2
        let middleRightY = usable.midY - middleRightHeight / 2
        let lowerY = usable.maxY - max(lowerLeftHeight, lowerRightHeight) - 10

        switch position {
        case .topLeft:
            return CGRect(x: usable.minX, y: topY, width: leftWidth, height: topLeftHeight)
        case .topMiddle:
            return CGRect(x: usable.midX - centerWidth / 2, y: topY + 4, width: centerWidth, height: topMiddleHeight)
        case .topRight:
            return CGRect(x: usable.maxX - rightWidth, y: topY, width: rightWidth, height: topRightHeight)
        case .middleLeft:
            return CGRect(x: usable.minX, y: middleLeftY, width: leftWidth, height: middleLeftHeight)
        case .middleRight:
            return CGRect(x: usable.maxX - 146, y: middleRightY, width: 146, height: middleRightHeight)
        case .lowerLeft:
            return CGRect(x: usable.minX, y: lowerY + max(lowerLeftHeight, lowerRightHeight) - lowerLeftHeight, width: leftWidth + 24, height: lowerLeftHeight)
        case .lowerMiddle:
            return CGRect(x: usable.midX - centerWidth / 2, y: lowerY + max(lowerLeftHeight, lowerRightHeight) - lowerMiddleHeight, width: centerWidth, height: lowerMiddleHeight)
        case .lowerRight:
            return CGRect(x: usable.maxX - rightWidth, y: lowerY + max(lowerLeftHeight, lowerRightHeight) - lowerRightHeight, width: rightWidth, height: lowerRightHeight)
        }
    }

    private func chipLayouts(for position: AnnotationPlaceholderPosition) -> [ChipLayout] {
        let rect = placeholderRect(for: position)
        let items = layout.placeholders[position] ?? []
        var layouts: [ChipLayout] = []

        for (index, item) in items.enumerated() {
            let chipY = rect.minY + CanvasMetrics.placeholderTopInset + CGFloat(index) * rowPitch
            let width = min(max(chipWidth(for: item.title), 72), rect.width - (CanvasMetrics.chipHorizontalInset * 2))
            let chipX: CGFloat
            switch position.alignment {
            case .left:
                chipX = rect.minX + CanvasMetrics.chipHorizontalInset
            case .center:
                chipX = rect.midX - width / 2
            case .right:
                chipX = rect.maxX - width - CanvasMetrics.chipHorizontalInset
            default:
                chipX = rect.minX + CanvasMetrics.chipHorizontalInset
            }

            layouts.append(ChipLayout(frame: CGRect(x: chipX, y: chipY, width: width, height: CanvasMetrics.chipHeight), item: item, index: index))
        }

        return layouts
    }

    private var rowPitch: CGFloat {
        CanvasMetrics.chipHeight + CanvasMetrics.chipVerticalGap
    }

    private func placeholderHeight(for position: AnnotationPlaceholderPosition) -> CGFloat {
        let slotCount = max(position.slotCapacity, layout.placeholders[position]?.count ?? 0)
        guard slotCount > 0 else { return 0 }
        return CanvasMetrics.placeholderTopInset +
            CanvasMetrics.placeholderBottomInset +
            CGFloat(slotCount) * CanvasMetrics.chipHeight +
            CGFloat(max(0, slotCount - 1)) * CanvasMetrics.chipVerticalGap
    }

    private func drawSlotGuides(in rect: CGRect, for position: AnnotationPlaceholderPosition) {
        let slotCount = max(position.slotCapacity, layout.placeholders[position]?.count ?? 0)
        guard slotCount > 1 else { return }

        let guidePath = NSBezierPath()
        for slotIndex in 1..<slotCount {
            let y = rect.minY + CanvasMetrics.placeholderTopInset - (CanvasMetrics.chipVerticalGap / 2) + CGFloat(slotIndex) * rowPitch
            guidePath.move(to: CGPoint(x: rect.minX + CanvasMetrics.chipHorizontalInset, y: y))
            guidePath.line(to: CGPoint(x: rect.maxX - CanvasMetrics.chipHorizontalInset, y: y))
        }

        guidePath.lineWidth = 1
        guidePath.setLineDash([2, 4], count: 2, phase: 0)
        NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
        guidePath.stroke()
    }

    private func chipWidth(for title: String) -> CGFloat {
        let size = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]
        ).size()
        return ceil(size.width) + 22
    }

    private func dropTarget(at point: CGPoint, ignoring sourceSelection: AnnotationSelection) -> AnnotationDropTarget? {
        guard let position = AnnotationPlaceholderPosition.allCases.first(where: { placeholderRect(for: $0).contains(point) }) else {
            return nil
        }

        let chipLayouts = chipLayouts(for: position)
        let visibleLayouts = chipLayouts.filter { chip in
            !(sourceSelection.position == position && sourceSelection.index == chip.index)
        }

        var insertionIndex = visibleLayouts.count
        for chip in visibleLayouts {
            if point.y < chip.frame.midY {
                insertionIndex = chip.index
                break
            }
        }

        if sourceSelection.position == position,
           let sourceIndex = sourceSelection.index,
           insertionIndex > sourceIndex {
            insertionIndex -= 1
        }

        return AnnotationDropTarget(position: position, insertionIndex: insertionIndex)
    }

    private func drawChip(item: HorosAnnotationItem, in frame: CGRect, selected: Bool, alpha: CGFloat) {
        let chipPath = NSBezierPath(
            roundedRect: frame,
            xRadius: CanvasMetrics.chipCornerRadius,
            yRadius: CanvasMetrics.chipCornerRadius
        )
        let isOrientation = item.isOrientationWidget

        let fillColor: NSColor
        let borderColor: NSColor
        if selected {
            fillColor = NSColor.systemBlue.withAlphaComponent(alpha)
            borderColor = (NSColor.systemBlue.blended(withFraction: 0.25, of: .white) ?? .systemBlue).withAlphaComponent(alpha)
        } else if isOrientation {
            fillColor = NSColor(calibratedWhite: 0.46, alpha: alpha)
            borderColor = NSColor(calibratedWhite: 0.62, alpha: alpha)
        } else {
            fillColor = NSColor(calibratedRed: 1.0, green: 0.47, blue: 0.09, alpha: alpha)
            borderColor = NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.11, alpha: alpha)
        }

        fillColor.setFill()
        chipPath.fill()
        chipPath.lineWidth = 1
        borderColor.setStroke()
        chipPath.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph
        ]

        let titleRect = frame.insetBy(dx: 8, dy: 3)
        NSAttributedString(string: item.title, attributes: titleAttributes).draw(in: titleRect)
    }
}

private final class AnnotationsSettingsPaneViewController: HorosSettingsPaneViewController, NSTokenFieldDelegate {
    private enum Layout {
        static let specialFields: [String] = [
            "Image Size",
            "View Size",
            "Window Level / Window Width",
            "Image Position",
            "Zoom",
            "Rotation Angle",
            "Mouse Position (px)",
            "Mouse Position (mm)",
            "Thickness / Location / Position",
            "Patient's Actual Age",
            "Patient's Age At Acquisition",
            "Plugin",
        ]
    }

    private let store = HorosAnnotationsPreferenceStore()

    private var modalities: [String] = []
    private var currentModality = "Default"
    private var currentLayout = HorosAnnotationLayout()
    private var currentInherited = false
    private var selection = AnnotationSelection(position: .topLeft, index: nil)
    private var dicomFields: [DICOMFieldDescriptor] = []
    private var databaseStudyFields: [String] = []
    private var databaseSeriesFields: [String] = []
    private var databaseImageFields: [String] = []

    private let modalityLabel = NSTextField(labelWithString: "Modality:")
    private let modalityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resetButton = NSButton(title: "Revert", target: nil, action: nil)
    private let sameAsDefaultButton = NSButton(checkboxWithTitle: "Same as Default", target: nil, action: nil)
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let orientationButton = NSButton(checkboxWithTitle: "Orientation", target: nil, action: nil)
    private let canvasView = AnnotationsCanvasView(frame: .zero)
    private let titleField = NSTextField(frame: .zero)
    private let contentTokenField = NSTokenField(frame: .zero)
    private let selectedRegionLabel = NSTextField(labelWithString: "")
    private let helperLabel = NSTextField(labelWithString: "Changes are saved automatically.")
    private let addDICOMPrefixButton = NSButton(title: "+", target: nil, action: nil)
    private let dicomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addCustomDICOMButton = NSButton(title: "Add Custom DICOM", target: nil, action: nil)
    private let dicomGroupField = NSTextField(frame: .zero)
    private let dicomElementField = NSTextField(frame: .zero)
    private let dicomNameField = NSTextField(frame: .zero)
    private let addDatabasePrefixButton = NSButton(title: "+", target: nil, action: nil)
    private let databasePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addSpecialPrefixButton = NSButton(title: "+", target: nil, action: nil)
    private let specialPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(paneTitle: "Annotations")
    }

    override func loadView() {
        let rootView = HorosSettingsPaneContainerView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        view = rootView

        loadTokenSources()
        configureControls()
        layoutControls()
        reloadModalities()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutControls()
    }

    private func configureControls() {
        modalityLabel.font = .systemFont(ofSize: 16, weight: .medium)
        modalityLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        view.addSubview(modalityLabel)

        modalityPopUp.target = self
        modalityPopUp.action = #selector(modalityChanged(_:))
        view.addSubview(modalityPopUp)

        resetButton.target = self
        resetButton.action = #selector(revertCurrentModality(_:))
        view.addSubview(resetButton)

        sameAsDefaultButton.target = self
        sameAsDefaultButton.action = #selector(toggleSameAsDefault(_:))
        view.addSubview(sameAsDefaultButton)

        addButton.target = self
        addButton.action = #selector(addAnnotation(_:))
        view.addSubview(addButton)

        removeButton.target = self
        removeButton.action = #selector(removeAnnotation(_:))
        view.addSubview(removeButton)

        orientationButton.target = self
        orientationButton.action = #selector(toggleOrientationWidgets(_:))
        view.addSubview(orientationButton)

        canvasView.selectionHandler = { [weak self] selection in
            self?.apply(selection: selection)
        }
        canvasView.moveHandler = { [weak self] source, destination in
            self?.moveAnnotation(from: source, to: destination)
        }
        view.addSubview(canvasView)

        selectedRegionLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        selectedRegionLabel.textColor = NSColor(calibratedWhite: 0.70, alpha: 1)
        view.addSubview(selectedRegionLabel)

        let titleLabel = NSTextField(labelWithString: "Selected Annotation Title:")
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("AnnotationsTitleLabel")
        view.addSubview(titleLabel)

        titleField.target = self
        titleField.action = #selector(titleChanged(_:))
        view.addSubview(titleField)

        let contentLabel = NSTextField(labelWithString: "Content:")
        contentLabel.font = .systemFont(ofSize: 14, weight: .medium)
        contentLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        contentLabel.identifier = NSUserInterfaceItemIdentifier("AnnotationsContentLabel")
        view.addSubview(contentLabel)

        contentTokenField.delegate = self
        contentTokenField.target = self
        contentTokenField.action = #selector(tokensChanged(_:))
        contentTokenField.tokenStyle = .rounded
        contentTokenField.tokenizingCharacterSet = .whitespacesAndNewlines
        view.addSubview(contentTokenField)

        helperLabel.font = .systemFont(ofSize: 12)
        helperLabel.textColor = NSColor(calibratedWhite: 0.66, alpha: 1)
        view.addSubview(helperLabel)

        configureTokenControls()
    }

    private func layoutControls() {
        let bounds = view.bounds
        let sideInset: CGFloat = 34
        let topY: CGFloat = 28

        modalityLabel.frame = NSRect(x: sideInset, y: topY + 7, width: 78, height: 22)
        modalityPopUp.frame = NSRect(x: sideInset + 86, y: topY, width: 160, height: 28)
        resetButton.frame = NSRect(x: sideInset + 256, y: topY, width: 84, height: 28)
        sameAsDefaultButton.frame = NSRect(x: sideInset + 354, y: topY + 6, width: 138, height: 18)
        addButton.frame = NSRect(x: bounds.midX - 70, y: topY, width: 64, height: 28)
        removeButton.frame = NSRect(x: bounds.midX + 2, y: topY, width: 84, height: 28)
        orientationButton.frame = NSRect(x: bounds.maxX - sideInset - 136, y: topY + 6, width: 136, height: 18)

        let canvasTop = topY + 48
        let editorHeight: CGFloat = 312
        let helperHeight: CGFloat = 18
        let canvasBottomPadding: CGFloat = 20
        let canvasHeight = max(320, bounds.height - canvasTop - editorHeight - helperHeight - canvasBottomPadding - 36)
        canvasView.frame = NSRect(x: sideInset, y: canvasTop, width: bounds.width - sideInset * 2, height: canvasHeight)

        selectedRegionLabel.frame = NSRect(x: sideInset + 6, y: canvasView.frame.maxY + 8, width: 260, height: 16)

        let titleLabel = view.subviews.first { $0.identifier?.rawValue == "AnnotationsTitleLabel" } as? NSTextField
        titleLabel?.frame = NSRect(x: sideInset, y: canvasView.frame.maxY + 34, width: 190, height: 22)
        titleField.frame = NSRect(x: sideInset + 196, y: canvasView.frame.maxY + 30, width: bounds.width - (sideInset * 2) - 196, height: 28)

        let contentLabel = view.subviews.first { $0.identifier?.rawValue == "AnnotationsContentLabel" } as? NSTextField
        contentLabel?.frame = NSRect(x: sideInset, y: canvasView.frame.maxY + 70, width: 80, height: 22)
        contentTokenField.frame = NSRect(x: sideInset + 92, y: canvasView.frame.maxY + 66, width: bounds.width - (sideInset * 2) - 92, height: 56)

        let controlsTop = canvasView.frame.maxY + 136
        let rowHeight: CGFloat = 28
        let plusSize: CGFloat = 24
        let popupX = sideInset + 150
        let popupWidth = bounds.width - popupX - sideInset

        if let dicomLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsDICOMSectionLabel" }) as? NSTextField {
            dicomLabel.frame = NSRect(x: sideInset + 30, y: controlsTop + 2, width: 120, height: 22)
        }
        addDICOMPrefixButton.frame = NSRect(x: sideInset, y: controlsTop, width: plusSize, height: plusSize)
        dicomPopup.frame = NSRect(x: popupX, y: controlsTop - 2, width: popupWidth, height: rowHeight)

        if let customLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsCustomDICOMSectionLabel" }) as? NSTextField {
            customLabel.frame = NSRect(x: sideInset + 30, y: controlsTop + 42, width: 180, height: 22)
        }
        addCustomDICOMButton.frame = NSRect(x: sideInset, y: controlsTop + 40, width: plusSize, height: plusSize)

        if let groupLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsGroupLabel" }) as? NSTextField {
            groupLabel.frame = NSRect(x: popupX - 92, y: controlsTop + 42, width: 84, height: 22)
        }
        dicomGroupField.frame = NSRect(x: popupX, y: controlsTop + 38, width: 128, height: rowHeight)

        if let elementLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsElementLabel" }) as? NSTextField {
            elementLabel.frame = NSRect(x: popupX + 150, y: controlsTop + 42, width: 84, height: 22)
        }
        dicomElementField.frame = NSRect(x: popupX + 238, y: controlsTop + 38, width: 128, height: rowHeight)

        if let nameLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsNameLabel" }) as? NSTextField {
            nameLabel.frame = NSRect(x: popupX - 92, y: controlsTop + 78, width: 84, height: 22)
        }
        dicomNameField.frame = NSRect(x: popupX, y: controlsTop + 74, width: popupWidth, height: rowHeight)

        if let databaseLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsDatabaseSectionLabel" }) as? NSTextField {
            databaseLabel.frame = NSRect(x: sideInset + 30, y: controlsTop + 122, width: 160, height: 22)
        }
        addDatabasePrefixButton.frame = NSRect(x: sideInset, y: controlsTop + 120, width: plusSize, height: plusSize)
        databasePopup.frame = NSRect(x: popupX, y: controlsTop + 118, width: popupWidth, height: rowHeight)

        if let specialLabel = view.subviews.first(where: { $0.identifier?.rawValue == "AnnotationsSpecialSectionLabel" }) as? NSTextField {
            specialLabel.frame = NSRect(x: sideInset + 30, y: controlsTop + 162, width: 120, height: 22)
        }
        addSpecialPrefixButton.frame = NSRect(x: sideInset, y: controlsTop + 160, width: plusSize, height: plusSize)
        specialPopup.frame = NSRect(x: popupX, y: controlsTop + 158, width: popupWidth, height: rowHeight)

        helperLabel.frame = NSRect(x: sideInset, y: bounds.height - 24, width: bounds.width - sideInset * 2, height: helperHeight)
    }

    private func reloadModalities() {
        modalities = store.availableModalities()
        modalityPopUp.removeAllItems()
        modalityPopUp.addItems(withTitles: modalities)
        currentModality = modalities.contains(currentModality) ? currentModality : (modalities.first ?? "Default")
        modalityPopUp.selectItem(withTitle: currentModality)
        loadCurrentModality()
    }

    @objc private func modalityChanged(_ sender: NSPopUpButton) {
        currentModality = sender.selectedItem?.title ?? "Default"
        loadCurrentModality()
    }

    @objc private func revertCurrentModality(_ sender: NSButton) {
        let state = store.restoreSavedState(for: currentModality)
        currentLayout = state.layout
        currentInherited = state.inherited
        refreshSelectionFromCurrentLayout()
        refreshUI()
    }

    @objc private func toggleSameAsDefault(_ sender: NSButton) {
        currentInherited = sender.state == .on && currentModality != "Default"
        if currentInherited {
            currentLayout = store.editableLayout(for: currentModality).layout
        }
        persistCurrentLayout()
        refreshSelectionFromCurrentLayout()
        refreshUI()
    }

    @objc private func addAnnotation(_ sender: NSButton) {
        guard !currentInherited else { return }

        let targetPosition = selection.position
        var items = currentLayout.placeholders[targetPosition] ?? []
        let nextIndex = currentLayout.placeholders.values.flatMap { $0 }.count + 1
        items.append(HorosAnnotationItem(title: "Annotation \(nextIndex)", content: []))
        currentLayout.placeholders[targetPosition] = items
        selection = AnnotationSelection(position: targetPosition, index: items.count - 1)
        persistCurrentLayout()
        refreshUI()
    }

    @objc private func removeAnnotation(_ sender: NSButton) {
        guard !currentInherited, let index = selection.index else { return }

        var items = currentLayout.placeholders[selection.position] ?? []
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        currentLayout.placeholders[selection.position] = items
        selection = AnnotationSelection(position: selection.position, index: items.indices.isEmpty ? nil : min(index, items.count - 1))
        persistCurrentLayout()
        refreshUI()
    }

    @objc private func toggleOrientationWidgets(_ sender: NSButton) {
        guard !currentInherited else { return }

        let orientationPositions: [AnnotationPlaceholderPosition] = [.topMiddle, .middleLeft, .middleRight, .lowerMiddle]
        let enabled = sender.state == .on

        for position in orientationPositions {
            var items = currentLayout.placeholders[position] ?? []
            items.removeAll { $0.isOrientationWidget }
            if enabled {
                items.insert(HorosAnnotationItem(title: "Orientation", content: ["Special_Orientation"]), at: 0)
            }
            currentLayout.placeholders[position] = items
        }

        if selection.index != nil {
            refreshSelectionFromCurrentLayout()
        }
        persistCurrentLayout()
        refreshUI()
    }

    @objc private func titleChanged(_ sender: NSTextField) {
        guard !currentInherited, let index = selection.index else { return }

        var items = currentLayout.placeholders[selection.position] ?? []
        guard items.indices.contains(index) else { return }
        items[index].title = sender.stringValue.isEmpty ? "Untitled" : sender.stringValue
        currentLayout.placeholders[selection.position] = items
        persistCurrentLayout()
        refreshUI()
    }

    @objc private func tokensChanged(_ sender: NSTokenField) {
        guard !currentInherited, let index = selection.index else { return }

        var items = currentLayout.placeholders[selection.position] ?? []
        guard items.indices.contains(index) else { return }

        let tokens = (sender.objectValue as? [Any])?.compactMap { value -> String? in
            if let string = value as? String, !string.isEmpty {
                return string
            }
            return nil
        } ?? []

        items[index].content = tokens
        currentLayout.placeholders[selection.position] = items
        persistCurrentLayout()
        refreshUI()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let textField = obj.object as? NSTextField, textField == titleField {
            titleChanged(titleField)
        } else if let tokenField = obj.object as? NSTokenField, tokenField == contentTokenField {
            tokensChanged(contentTokenField)
        }
    }

    private func loadCurrentModality() {
        let state = store.editableLayout(for: currentModality)
        currentLayout = state.layout
        currentInherited = state.inherited
        refreshSelectionFromCurrentLayout()
        refreshUI()
    }

    private func refreshSelectionFromCurrentLayout() {
        for position in AnnotationPlaceholderPosition.allCases {
            if let firstIndex = currentLayout.placeholders[position]?.indices.first {
                selection = AnnotationSelection(position: position, index: firstIndex)
                return
            }
        }

        selection = AnnotationSelection(position: .topLeft, index: nil)
    }

    private func apply(selection: AnnotationSelection) {
        self.selection = selection
        refreshUI()
    }

    private func moveAnnotation(from source: AnnotationSelection, to destination: AnnotationDropTarget) {
        guard !currentInherited, let sourceIndex = source.index else { return }

        var sourceItems = currentLayout.placeholders[source.position] ?? []
        guard sourceItems.indices.contains(sourceIndex) else { return }

        let movedItem = sourceItems.remove(at: sourceIndex)
        currentLayout.placeholders[source.position] = sourceItems

        var destinationItems = currentLayout.placeholders[destination.position] ?? []
        let insertionIndex = min(max(destination.insertionIndex, 0), destinationItems.count)
        destinationItems.insert(movedItem, at: insertionIndex)
        currentLayout.placeholders[destination.position] = destinationItems

        selection = AnnotationSelection(position: destination.position, index: insertionIndex)
        persistCurrentLayout()
        refreshUI()
    }

    private func loadTokenSources() {
        dicomFields = loadDICOMFields()
        let databaseFields = loadDatabaseFields()
        databaseStudyFields = databaseFields.study
        databaseSeriesFields = databaseFields.series
        databaseImageFields = databaseFields.image
    }

    private func configureTokenControls() {
        let dicomLabel = makeSectionLabel("DICOM fields", id: "AnnotationsDICOMSectionLabel")
        view.addSubview(dicomLabel)

        addDICOMPrefixButton.target = self
        addDICOMPrefixButton.action = #selector(insertDICOMPrefix(_:))
        view.addSubview(addDICOMPrefixButton)

        dicomPopup.target = self
        dicomPopup.action = #selector(insertSelectedDICOMField(_:))
        dicomPopup.addItems(withTitles: ["DICOM Fields"] + dicomFields.map(\.title))
        dicomPopup.selectItem(at: 0)
        view.addSubview(dicomPopup)

        let customLabel = makeSectionLabel("Custom DICOM field", id: "AnnotationsCustomDICOMSectionLabel")
        view.addSubview(customLabel)

        addCustomDICOMButton.target = self
        addCustomDICOMButton.action = #selector(insertCustomDICOMField(_:))
        view.addSubview(addCustomDICOMButton)

        let groupLabel = makeSectionLabel("Group", id: "AnnotationsGroupLabel")
        view.addSubview(groupLabel)
        dicomGroupField.placeholderString = "0x0000"
        view.addSubview(dicomGroupField)

        let elementLabel = makeSectionLabel("Element", id: "AnnotationsElementLabel")
        view.addSubview(elementLabel)
        dicomElementField.placeholderString = "0x0000"
        view.addSubview(dicomElementField)

        let nameLabel = makeSectionLabel("Name", id: "AnnotationsNameLabel")
        view.addSubview(nameLabel)
        dicomNameField.placeholderString = "Optional"
        view.addSubview(dicomNameField)

        let databaseLabel = makeSectionLabel("Database fields", id: "AnnotationsDatabaseSectionLabel")
        view.addSubview(databaseLabel)

        addDatabasePrefixButton.target = self
        addDatabasePrefixButton.action = #selector(insertDatabasePrefix(_:))
        view.addSubview(addDatabasePrefixButton)

        databasePopup.target = self
        databasePopup.action = #selector(insertSelectedDatabaseField(_:))
        rebuildDatabasePopupMenu()
        view.addSubview(databasePopup)

        let specialLabel = makeSectionLabel("Other infos", id: "AnnotationsSpecialSectionLabel")
        view.addSubview(specialLabel)

        addSpecialPrefixButton.target = self
        addSpecialPrefixButton.action = #selector(insertSpecialPrefix(_:))
        view.addSubview(addSpecialPrefixButton)

        specialPopup.target = self
        specialPopup.action = #selector(insertSelectedSpecialField(_:))
        specialPopup.addItems(withTitles: Layout.specialFields)
        if !Layout.specialFields.isEmpty {
            specialPopup.selectItem(at: 0)
        }
        view.addSubview(specialPopup)
    }

    private func makeSectionLabel(_ string: String, id: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        label.identifier = NSUserInterfaceItemIdentifier(id)
        return label
    }

    private func rebuildDatabasePopupMenu() {
        databasePopup.removeAllItems()
        databasePopup.addItem(withTitle: "Study level")
        if let item = databasePopup.item(at: databasePopup.numberOfItems - 1) {
            item.isEnabled = false
        }
        for field in databaseStudyFields {
            databasePopup.addItem(withTitle: "  \(field)")
            databasePopup.lastItem?.representedObject = "study.\(field)"
        }

        databasePopup.menu?.addItem(.separator())
        databasePopup.addItem(withTitle: "Series level")
        if let item = databasePopup.item(at: databasePopup.numberOfItems - 1) {
            item.isEnabled = false
        }
        for field in databaseSeriesFields {
            databasePopup.addItem(withTitle: "  \(field)")
            databasePopup.lastItem?.representedObject = "series.\(field)"
        }

        databasePopup.menu?.addItem(.separator())
        databasePopup.addItem(withTitle: "Image level")
        if let item = databasePopup.item(at: databasePopup.numberOfItems - 1) {
            item.isEnabled = false
        }
        for field in databaseImageFields {
            databasePopup.addItem(withTitle: "  \(field)")
            databasePopup.lastItem?.representedObject = "image.\(field)"
        }
        databasePopup.selectItem(at: 0)
    }

    @objc private func insertDICOMPrefix(_ sender: NSButton) {
        insertToken("DICOM_")
    }

    @objc private func insertSelectedDICOMField(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }
        let field = dicomFields[sender.indexOfSelectedItem - 1]
        insertToken("DICOM_\(field.name)")
    }

    @objc private func insertCustomDICOMField(_ sender: NSButton) {
        let groupString = normalizedHexString(from: dicomGroupField.stringValue)
        let elementString = normalizedHexString(from: dicomElementField.stringValue)
        guard !groupString.isEmpty, !elementString.isEmpty else { return }

        let suffix = dicomNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            insertToken("DICOM_\(groupString)_\(elementString)")
        } else {
            insertToken("DICOM_\(groupString)_\(elementString)_\(suffix)")
        }

        dicomGroupField.stringValue = ""
        dicomElementField.stringValue = ""
        dicomNameField.stringValue = ""
    }

    @objc private func insertDatabasePrefix(_ sender: NSButton) {
        insertToken("DB_")
    }

    @objc private func insertSelectedDatabaseField(_ sender: NSPopUpButton) {
        guard let represented = sender.selectedItem?.representedObject as? String else { return }
        insertToken("DB_\(represented)")
    }

    @objc private func insertSpecialPrefix(_ sender: NSButton) {
        insertToken("Special_")
    }

    @objc private func insertSelectedSpecialField(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, !title.isEmpty else { return }
        insertToken("Special_\(title)")
    }

    private func insertToken(_ token: String) {
        guard !currentInherited, let index = selection.index else { return }
        var items = currentLayout.placeholders[selection.position] ?? []
        guard items.indices.contains(index) else { return }

        items[index].content.append(token)
        currentLayout.placeholders[selection.position] = items
        persistCurrentLayout()
        refreshUI()
    }

    private func normalizedHexString(from string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let cleaned = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        guard let value = UInt16(cleaned, radix: 16) else { return "" }
        return String(format: "0x%04x", value)
    }

    private func loadDICOMFields() -> [DICOMFieldDescriptor] {
        guard let url = Bundle.main.url(forResource: "tagDictionary", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: [String: Any]]
        else {
            return []
        }

        var results: [DICOMFieldDescriptor] = []
        for (tag, values) in dictionary {
            let components = tag.split(separator: ",")
            guard components.count == 2,
                  let group = Int(components[0], radix: 16),
                  let element = Int(components[1], radix: 16),
                  group > 0,
                  let name = values["Description"] as? String
            else {
                continue
            }
            results.append(DICOMFieldDescriptor(group: group, element: element, name: name))
        }

        return results.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                if lhs.group == rhs.group {
                    return lhs.element < rhs.element
                }
                return lhs.group < rhs.group
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadDatabaseFields() -> (study: [String], series: [String], image: [String]) {
        guard let modelURL = Bundle.main.url(forResource: "OsiriXDB_DataModel", withExtension: "momd")
            ?? Bundle.main.url(forResource: "OsiriXDB_DataModel", withExtension: "mom"),
              let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            return ([], [], [])
        }

        let studyFields = model.entitiesByName["Study"]?.attributesByName.keys.filter { $0 != "windowsState" }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
        let seriesFields = model.entitiesByName["Series"]?.attributesByName.keys.filter { $0 != "thumbnail" }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
        let imageFields = model.entitiesByName["Image"]?.attributesByName.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
        return (studyFields, seriesFields, imageFields)
    }

    private func persistCurrentLayout() {
        store.save(layout: currentLayout, modality: currentModality, inherited: currentInherited)
    }

    private func refreshUI() {
        canvasView.layout = currentLayout
        canvasView.selected = selection
        canvasView.editingEnabled = !currentInherited

        sameAsDefaultButton.isHidden = (currentModality == "Default")
        sameAsDefaultButton.state = currentInherited ? .on : .off

        let orientationEnabled = [.topMiddle, .middleLeft, .middleRight, .lowerMiddle].allSatisfy { position in
            (currentLayout.placeholders[position] ?? []).contains { $0.isOrientationWidget }
        }
        orientationButton.state = orientationEnabled ? .on : .off
        orientationButton.isEnabled = !currentInherited
        addButton.isEnabled = !currentInherited
        removeButton.isEnabled = !currentInherited && selection.index != nil
        titleField.isEnabled = !currentInherited && selection.index != nil
        contentTokenField.isEnabled = !currentInherited && selection.index != nil
        addDICOMPrefixButton.isEnabled = !currentInherited && selection.index != nil
        dicomPopup.isEnabled = !currentInherited && selection.index != nil
        addCustomDICOMButton.isEnabled = !currentInherited && selection.index != nil
        dicomGroupField.isEnabled = !currentInherited && selection.index != nil
        dicomElementField.isEnabled = !currentInherited && selection.index != nil
        dicomNameField.isEnabled = !currentInherited && selection.index != nil
        addDatabasePrefixButton.isEnabled = !currentInherited && selection.index != nil
        databasePopup.isEnabled = !currentInherited && selection.index != nil
        addSpecialPrefixButton.isEnabled = !currentInherited && selection.index != nil
        specialPopup.isEnabled = !currentInherited && selection.index != nil

        let regionTitle = selection.position.title + (selection.index == nil ? "" : " • Annotation")
        selectedRegionLabel.stringValue = regionTitle

        if let index = selection.index,
           let items = currentLayout.placeholders[selection.position],
           items.indices.contains(index) {
            let item = items[index]
            titleField.stringValue = item.title
            contentTokenField.objectValue = item.content
        } else {
            titleField.stringValue = ""
            contentTokenField.objectValue = []
        }
    }
}

private final class GeneralSettingsPaneViewController: HorosSettingsPaneViewController {
    private enum Layout {
        static let contentWidth: CGFloat = 780
    }

    init() {
        super.init(paneTitle: "General")
    }

    override func loadView() {
        let rootView = HorosSettingsPaneContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor

        let titleLabel = makeLabel(
            string: "General",
            font: .systemFont(ofSize: 28, weight: .semibold),
            color: NSColor(calibratedWhite: 0.95, alpha: 1)
        )
        titleLabel.frame = NSRect(x: 42, y: 36, width: 240, height: 36)
        rootView.addSubview(titleLabel)

        let subtitleLabel = makeWrappingLabel(
            string: "This new settings shell is now hosted in Swift/AppKit. We’ll migrate the old Horos preference panes into this window one by one, keeping the existing stored preferences unchanged.",
            font: .systemFont(ofSize: 14),
            color: NSColor(calibratedWhite: 0.68, alpha: 1)
        )
        subtitleLabel.frame = NSRect(x: 42, y: 80, width: Layout.contentWidth, height: 44)
        rootView.addSubview(subtitleLabel)

        let cardView = NSView(frame: NSRect(x: 42, y: 150, width: Layout.contentWidth, height: 220))
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        cardView.layer?.cornerRadius = 14
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor(calibratedWhite: 0.24, alpha: 1).cgColor
        rootView.addSubview(cardView)

        let cardTitle = makeLabel(
            string: "Migration Status",
            font: .systemFont(ofSize: 18, weight: .medium),
            color: NSColor(calibratedWhite: 0.92, alpha: 1)
        )
        cardTitle.frame = NSRect(x: 22, y: 20, width: 240, height: 24)
        cardView.addSubview(cardTitle)

        let statusLines = [
            "New settings window and top navigation are in place.",
            "The old preferences window remains available as OldSettings.",
            "Next we can start moving real panes into this shell, beginning with General."
        ]

        for (index, line) in statusLines.enumerated() {
            let bullet = makeLabel(
                string: "•",
                font: .systemFont(ofSize: 18, weight: .semibold),
                color: NSColor.systemBlue
            )
            bullet.frame = NSRect(x: 22, y: 62 + CGFloat(index) * 42, width: 16, height: 22)
            cardView.addSubview(bullet)

            let text = makeWrappingLabel(
                string: line,
                font: .systemFont(ofSize: 15),
                color: NSColor(calibratedWhite: 0.84, alpha: 1)
            )
            text.frame = NSRect(x: 42, y: 60 + CGFloat(index) * 42, width: Layout.contentWidth - 70, height: 28)
            cardView.addSubview(text)
        }

        self.view = rootView
    }

    private func makeLabel(string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        return label
    }

    private func makeWrappingLabel(string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = font
        label.textColor = color
        return label
    }
}

private final class PlaceholderSettingsPaneViewController: HorosSettingsPaneViewController {
    init(title: String) {
        super.init(paneTitle: title)
    }

    override func loadView() {
        let rootView = HorosSettingsPaneContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor

        let titleLabel = NSTextField(labelWithString: paneTitle)
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        titleLabel.frame = NSRect(x: 42, y: 36, width: 320, height: 36)
        rootView.addSubview(titleLabel)

        let subtitle = NSTextField(wrappingLabelWithString: "\(paneTitle) will move into this new settings system in a later step.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        subtitle.frame = NSRect(x: 42, y: 84, width: 700, height: 24)
        rootView.addSubview(subtitle)

        self.view = rootView
    }
}

@objc(HorosModernSettingsWindowController)
final class HorosSettingsWindowController: NSWindowController {
    private enum Layout {
        static let windowSize = NSSize(width: 1280, height: 820)
        static let minWindowSize = NSSize(width: 1120, height: 720)
        static let topBarHeight: CGFloat = 78
        static let toolbarInsetX: CGFloat = 18
        static let toolbarInsetY: CGFloat = 4
        static let buttonSize = NSSize(width: 88, height: 58)
        static let buttonSpacing: CGFloat = 14
    }

    private static let panes: [HorosSettingsPaneDescriptor] = [
        .init(identifier: "general", title: "General", imageName: "GeneralPreferences"),
        .init(identifier: "database", title: "Database", imageName: "DatabaseIcon"),
        .init(identifier: "cddvd", title: "CD/DVD", imageName: "CD"),
        .init(identifier: "protocols", title: "Protocols", imageName: "ZoomToFit"),
        .init(identifier: "hotkeys", title: "Hot Keys", imageName: "key"),
        .init(identifier: "viewers", title: "Viewers", imageName: "AxialSmall"),
        .init(identifier: "3d", title: "3D", imageName: "VolumeRendering"),
        .init(identifier: "pet", title: "PET", imageName: "SUV"),
        .init(identifier: "annotations", title: "Annotations", imageName: "CustomImageAnnotations"),
        .init(identifier: "dicomprint", title: "DICOM Print", imageName: "Print"),
        .init(identifier: "listener", title: "Listener", imageName: "Network"),
        .init(identifier: "locations", title: "Locations", imageName: "AccountPreferences"),
        .init(identifier: "routing", title: "Routing", imageName: "route"),
        .init(identifier: "webserver", title: "Web Server", imageName: "Safari"),
        .init(identifier: "ondemand", title: "On-Demand", imageName: "Cloud"),
    ]

    private var toolbarButtons: [NSButton] = []
    private let contentContainer = HorosSettingsRootView(frame: .zero)
    private var selectedPaneIdentifier: String?
    private var paneControllers: [String: NSViewController] = [:]
    private var activePaneViewController: NSViewController?

    @objc(sharedWindowController)
    class func sharedWindowController() -> HorosSettingsWindowController {
        Shared.instance
    }

    private enum Shared {
        static let instance = HorosSettingsWindowController()
    }

    private init() {
        let rect = NSRect(origin: .zero, size: Layout.windowSize)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Horos Settings"
        window.minSize = Layout.minWindowSize
        window.setFrameAutosaveName("HorosModernSettingsWindow")
        window.center()

        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildInterface() {
        guard let window else { return }

        let rootView = HorosSettingsRootView(frame: window.contentView?.bounds ?? .zero)
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1.0).cgColor
        window.contentView = rootView

        let topBar = HorosSettingsRootView(frame: NSRect(x: 0, y: 0, width: rootView.bounds.width, height: Layout.topBarHeight))
        topBar.autoresizingMask = [.width]
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor
        rootView.addSubview(topBar)

        let separator = NSBox(frame: NSRect(x: 0, y: Layout.topBarHeight - 1, width: rootView.bounds.width, height: 1))
        separator.autoresizingMask = [.width]
        separator.boxType = .separator
        rootView.addSubview(separator)

        let scrollHeight = Layout.topBarHeight - (Layout.toolbarInsetY * 2)
        let scrollView = NSScrollView(frame: NSRect(
            x: Layout.toolbarInsetX,
            y: Layout.toolbarInsetY,
            width: topBar.bounds.width - (Layout.toolbarInsetX * 2),
            height: scrollHeight
        ))
        scrollView.autoresizingMask = [.width]
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScroller?.controlSize = .small
        topBar.addSubview(scrollView)

        let stackView = NSStackView(frame: .zero)
        stackView.orientation = .horizontal
        stackView.spacing = Layout.buttonSpacing
        stackView.alignment = .centerY

        toolbarButtons = Self.panes.map { descriptor in
            let button = paneButton(for: descriptor)
            stackView.addArrangedSubview(button)
            return button
        }

        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        stackView.frame = NSRect(x: 0, y: 0, width: max(fitting.width, scrollView.bounds.width), height: scrollHeight)
        scrollView.documentView = stackView

        contentContainer.frame = NSRect(
            x: 0,
            y: Layout.topBarHeight,
            width: rootView.bounds.width,
            height: rootView.bounds.height - Layout.topBarHeight
        )
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
        rootView.addSubview(contentContainer)

        if let annotationsButton = toolbarButtons.first(where: { $0.identifier?.rawValue == "annotations" }) {
            updateSelection(annotationsButton)
        } else if let first = toolbarButtons.first {
            updateSelection(first)
        }
    }

    private func paneButton(for descriptor: HorosSettingsPaneDescriptor) -> NSButton {
        let button = NSButton(frame: NSRect(origin: .zero, size: Layout.buttonSize))
        button.title = descriptor.title
        button.image = NSImage(named: descriptor.imageName)
        button.identifier = NSUserInterfaceItemIdentifier(descriptor.identifier)
        button.setButtonType(.toggle)
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.target = self
        button.action = #selector(selectPaneButton(_:))
        button.contentTintColor = .white
        button.imageScaling = .scaleProportionallyUpOrDown
        button.attributedTitle = attributedTitle(for: descriptor.title, selected: false)
        button.wantsLayer = true
        button.layer?.cornerRadius = 14
        return button
    }

    private func attributedTitle(for title: String, selected: Bool) -> NSAttributedString {
        let color = selected ? NSColor.white : NSColor(calibratedWhite: 0.82, alpha: 1.0)
        return NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: color
            ]
        )
    }

    @objc private func selectPaneButton(_ sender: NSButton) {
        updateSelection(sender)
    }

    private func updateSelection(_ selectedButton: NSButton) {
        guard let identifier = selectedButton.identifier?.rawValue else { return }
        selectedPaneIdentifier = identifier

        for button in toolbarButtons {
            let isSelected = (button == selectedButton)
            button.state = isSelected ? .on : .off
            button.attributedTitle = attributedTitle(for: button.title, selected: isSelected)
            button.layer?.borderWidth = isSelected ? 1.0 : 0.0
            button.layer?.borderColor = isSelected ? NSColor(calibratedWhite: 0.38, alpha: 1.0).cgColor : nil
            button.layer?.backgroundColor = isSelected
                ? NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
                : NSColor.clear.cgColor
        }

        displayPane(withIdentifier: identifier, title: selectedButton.title)
    }

    private func displayPane(withIdentifier identifier: String, title: String) {
        let controller = paneController(for: identifier, title: title)

        if activePaneViewController === controller {
            return
        }

        activePaneViewController?.view.removeFromSuperview()
        activePaneViewController = controller

        let paneView = controller.view
        paneView.frame = contentContainer.bounds
        paneView.autoresizingMask = [.width, .height]
        contentContainer.addSubview(paneView)
    }

    private func paneController(for identifier: String, title: String) -> NSViewController {
        if let existing = paneControllers[identifier] {
            return existing
        }

        let controller: NSViewController
        switch identifier {
        case "general":
            controller = GeneralSettingsPaneViewController()
        case "annotations":
            controller = AnnotationsSettingsPaneViewController()
        default:
            controller = PlaceholderSettingsPaneViewController(title: title)
        }

        paneControllers[identifier] = controller
        return controller
    }
}
