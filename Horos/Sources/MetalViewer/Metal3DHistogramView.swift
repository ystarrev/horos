import AppKit

final class Metal3DHistogramView: NSView {
    var histogram: Metal3DHistogramModel? {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.96).cgColor
        layer?.cornerRadius = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 16, dy: 16)
        let titleRect = NSRect(x: bounds.minX, y: bounds.maxY - 22, width: bounds.width, height: 20)
        let subtitleRect = NSRect(x: bounds.minX, y: bounds.maxY - 42, width: bounds.width, height: 16)
        let plotRect = NSRect(x: bounds.minX + 6, y: bounds.minY + 30, width: bounds.width - 12, height: bounds.height - 86)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let axisAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        NSString(string: NSLocalizedString("CT Histogram", comment: "")).draw(in: titleRect, withAttributes: titleAttributes)
        NSString(string: NSLocalizedString("X: Hounsfield units   Y: voxel count (log scale)", comment: "")).draw(in: subtitleRect, withAttributes: subtitleAttributes)

        NSColor(calibratedWhite: 0.18, alpha: 1.0).setFill()
        plotRect.fill()

        let framePath = NSBezierPath(rect: plotRect)
        NSColor(calibratedWhite: 0.32, alpha: 1.0).setStroke()
        framePath.lineWidth = 1
        framePath.stroke()

        guard let histogram, histogram.binCount > 1 else {
            NSString(string: NSLocalizedString("No histogram data", comment: "")).draw(
                in: plotRect.insetBy(dx: 12, dy: 12),
                withAttributes: subtitleAttributes
            )
            return
        }

        let horizontalGridValues = [0.25, 0.5, 0.75]
        for value in horizontalGridValues {
            let y = plotRect.minY + CGFloat(value) * plotRect.height
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.line(to: CGPoint(x: plotRect.maxX, y: y))
            NSColor(calibratedWhite: 0.25, alpha: 1.0).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let barPath = NSBezierPath()
        let step = plotRect.width / CGFloat(histogram.binCount)
        let barWidth = max(step, 1)

        for index in 0..<histogram.binCount {
            let normalizedHeight = histogram.normalizedLogCount(forBin: index)
            let height = CGFloat(normalizedHeight) * plotRect.height
            guard height > 0.5 else { continue }
            let x = plotRect.minX + CGFloat(index) * step
            let barRect = NSRect(x: x, y: plotRect.minY, width: barWidth, height: height)
            barPath.appendRect(barRect)
        }

        let histogramColor = NSColor(calibratedRed: 0.48, green: 0.82, blue: 1.0, alpha: 0.9)
        histogramColor.setFill()
        barPath.fill()

        let ticks = [
            histogram.minimumHU,
            -1000,
            0,
            1000,
            2000,
            histogram.maximumHU,
        ].filter { $0 >= histogram.minimumHU && $0 <= histogram.maximumHU }

        for tick in ticks {
            let fraction = CGFloat(tick - histogram.minimumHU) / CGFloat(max(histogram.maximumHU - histogram.minimumHU, 1))
            let x = plotRect.minX + fraction * plotRect.width
            let tickPath = NSBezierPath()
            tickPath.move(to: CGPoint(x: x, y: plotRect.minY))
            tickPath.line(to: CGPoint(x: x, y: plotRect.minY - 5))
            NSColor.tertiaryLabelColor.setStroke()
            tickPath.lineWidth = 1
            tickPath.stroke()

            let label = "\(tick)"
            let labelSize = label.size(withAttributes: axisAttributes)
            let labelOrigin = CGPoint(x: x - labelSize.width * 0.5, y: plotRect.minY - 18)
            NSString(string: label).draw(at: labelOrigin, withAttributes: axisAttributes)
        }

        let yLabels = [
            NSLocalizedString("low", comment: ""),
            NSLocalizedString("mid", comment: ""),
            NSLocalizedString("high", comment: ""),
        ]
        for (index, label) in yLabels.enumerated() {
            let fraction = CGFloat(index + 1) / CGFloat(yLabels.count)
            let y = plotRect.minY + fraction * plotRect.height - 6
            NSString(string: label).draw(
                at: CGPoint(x: plotRect.minX - 30, y: y),
                withAttributes: axisAttributes
            )
        }
    }
}
