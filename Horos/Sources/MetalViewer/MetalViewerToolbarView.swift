import AppKit

final class MetalViewerToolbarView: NSView {
    private let contentStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 14
        addSubview(contentStack)

        let items: [(String, NSView)] = [
            ("Annotations", makeAnnotationsContent()),
            ("Mouse button function", makeMouseToolsContent()),
            ("WL/WW & CLUT", makeWLWWContent()),
            ("Sync", makeIconButtonContent(imageName: "Sync.pdf", alternateImageName: "SyncLock.pdf")),
            ("Propagate", makeIconButtonContent(imageName: "Propagate", alternateImageName: "PropagateOn")),
        ]

        items.forEach { title, view in
            contentStack.addArrangedSubview(MetalViewerToolbarItemView(title: title, contentView: view))
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTitle(_ title: String) {
    }

    func updateStatus(_ status: String) {
    }

    private func makeAnnotationsContent() -> NSView {
        let grid = NSGridView(views: [
            [makeToolbarRadio("None", selected: false), makeToolbarRadio("Basic", selected: false)],
            [makeToolbarRadio("Graphic", selected: false), makeToolbarRadio("Full", selected: true)],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 0
        grid.columnSpacing = 10

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 156),
            container.heightAnchor.constraint(equalToConstant: 42),

            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            grid.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeMouseToolsContent() -> NSView {
        let iconsStack = NSStackView()
        iconsStack.translatesAutoresizingMaskIntoConstraints = false
        iconsStack.orientation = .horizontal
        iconsStack.alignment = .centerY
        iconsStack.spacing = 6

        let imageNames = ["WLWW", "Move", "Zoom", "Rotate", "Stack"]
        for (index, imageName) in imageNames.enumerated() {
            let button = NSButton(image: toolbarImage(named: imageName), target: nil, action: nil)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = index == 0 ? NSColor.controlAccentColor : .white
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            iconsStack.addArrangedSubview(button)
        }

        let chevron = NSButton(title: "⌄", target: nil, action: nil)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isBordered = false
        chevron.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        chevron.contentTintColor = .white
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 14),
        ])
        iconsStack.addArrangedSubview(chevron)

        let buttonChoiceStack = NSStackView()
        buttonChoiceStack.translatesAutoresizingMaskIntoConstraints = false
        buttonChoiceStack.orientation = .horizontal
        buttonChoiceStack.alignment = .centerY
        buttonChoiceStack.spacing = 12
        buttonChoiceStack.addArrangedSubview(makeToolbarRadio("Left Button", selected: true, size: 10))
        buttonChoiceStack.addArrangedSubview(makeToolbarRadio("Right Button", selected: false, size: 10))

        let vertical = NSStackView(views: [iconsStack, buttonChoiceStack])
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 2

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vertical)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 230),
            container.heightAnchor.constraint(equalToConstant: 42),

            vertical.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeWLWWContent() -> NSView {
        let labels = ["WL/WW:", "Opacity:"]
        let values = ["Other", "Linear Table"]

        let rows = zip(labels, values).map { label, value in
            let labelField = NSTextField(labelWithString: label)
            labelField.font = NSFont.systemFont(ofSize: 10)
            labelField.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
            labelField.alignment = .right

            let popup = NSPopUpButton()
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.controlSize = .mini
            popup.addItems(withTitles: [value])
            popup.selectItem(at: 0)
            NSLayoutConstraint.activate([
                popup.widthAnchor.constraint(equalToConstant: 116),
            ])

            let row = NSStackView(views: [labelField, popup])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            return row
        }

        let vertical = NSStackView(views: rows)
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 1

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vertical)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 176),
            container.heightAnchor.constraint(equalToConstant: 42),

            vertical.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeIconButtonContent(imageName: String, alternateImageName: String? = nil) -> NSView {
        let button = NSButton(image: toolbarImage(named: imageName), target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = true
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        if let alternateImageName {
            button.alternateImage = toolbarImage(named: alternateImageName)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 46),
            container.heightAnchor.constraint(equalToConstant: 42),

            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])
        return container
    }

    private func makeToolbarRadio(_ title: String, selected: Bool, size: CGFloat = 11) -> NSView {
        let button = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        button.font = NSFont.systemFont(ofSize: size)
        button.state = selected ? .on : .off
        button.setButtonType(.radio)
        return button
    }

    private func toolbarImage(named name: String) -> NSImage {
        if let image = NSImage(named: NSImage.Name(name)) {
            return image
        }
        return NSImage(size: NSSize(width: 24, height: 24))
    }
}

private final class MetalViewerToolbarItemView: NSView {
    init(title: String, contentView: NSView) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        label.alignment = .center

        addSubview(contentView)
        addSubview(label)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
