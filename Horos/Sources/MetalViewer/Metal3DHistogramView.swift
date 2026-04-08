import AppKit

final class Metal3DHistogramView: NSView {
    var opacityPoints = [SIMD2<Float>]() {
        didSet {
            opacityPoints.sort { lhs, rhs in lhs.x < rhs.x }
            needsDisplay = true
        }
    }

    var opacityPointsChanged: (([SIMD2<Float>]) -> Void)?

    private let plotInsets = NSEdgeInsets(top: 10, left: 22, bottom: 34, right: 12)
    private let handleRadius: CGFloat = 5
    private var activePointIndex: Int?

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
        let subtitleRect = NSRect(x: bounds.minX, y: bounds.maxY - 18, width: bounds.width, height: 16)
        let plotRect = self.plotRect(in: bounds)

        let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let subtitleAttributes = makeAttributes(font: subtitleFont, color: NSColor.secondaryLabelColor)
        let axisAttributes = makeAttributes(font: axisFont, color: NSColor.tertiaryLabelColor)

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

        if opacityPoints.count >= 2 {
            let curvePath = NSBezierPath()
            for (index, point) in opacityPoints.enumerated() {
                let screenPoint = screenPoint(forOpacityPoint: point, in: plotRect, histogram: histogram)
                if index == 0 {
                    curvePath.move(to: screenPoint)
                } else {
                    curvePath.line(to: screenPoint)
                }
            }
            NSColor.systemOrange.setStroke()
            curvePath.lineWidth = 2
            curvePath.stroke()

            for point in opacityPoints {
                let screenPoint = screenPoint(forOpacityPoint: point, in: plotRect, histogram: histogram)
                let handleRect = NSRect(
                    x: screenPoint.x - handleRadius,
                    y: screenPoint.y - handleRadius,
                    width: handleRadius * 2,
                    height: handleRadius * 2
                )
                let handlePath = NSBezierPath(ovalIn: handleRect)
                NSColor.systemOrange.setFill()
                handlePath.fill()
                NSColor.black.withAlphaComponent(0.45).setStroke()
                handlePath.lineWidth = 1
                handlePath.stroke()
            }
        }

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

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let histogram else { return }
        let location = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds.insetBy(dx: 16, dy: 16)
        let plotRect = self.plotRect(in: bounds)

        activePointIndex = nil
        for (index, point) in opacityPoints.enumerated() {
            let handlePoint = screenPoint(forOpacityPoint: point, in: plotRect, histogram: histogram)
            let distance = hypot(handlePoint.x - location.x, handlePoint.y - location.y)
            if distance <= handleRadius + 4 {
                activePointIndex = index
                break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let histogram, let activePointIndex, opacityPoints.indices.contains(activePointIndex) else { return }
        let location = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds.insetBy(dx: 16, dy: 16)
        let plotRect = self.plotRect(in: bounds)
        guard plotRect.width > 1, plotRect.height > 1 else { return }

        var xFraction = (location.x - plotRect.minX) / plotRect.width
        var yFraction = (location.y - plotRect.minY) / plotRect.height
        xFraction = min(max(xFraction, 0), 1)
        yFraction = min(max(yFraction, 0), 1)

        var newHU = Float(histogram.minimumHU) + Float(xFraction) * Float(histogram.maximumHU - histogram.minimumHU)
        let newOpacity = Float(min(max(yFraction, 0), 1))

        if activePointIndex == 0 {
            newHU = Float(histogram.minimumHU)
        } else if activePointIndex == opacityPoints.count - 1 {
            newHU = Float(histogram.maximumHU)
        } else {
            let previous = opacityPoints[activePointIndex - 1].x + 1
            let next = opacityPoints[activePointIndex + 1].x - 1
            newHU = min(max(newHU, previous), next)
        }

        opacityPoints[activePointIndex] = SIMD2<Float>(newHU, newOpacity)
        opacityPointsChanged?(opacityPoints)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activePointIndex = nil
    }

    private func plotRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + plotInsets.left,
            y: bounds.minY + plotInsets.bottom,
            width: bounds.width - plotInsets.left - plotInsets.right,
            height: bounds.height - plotInsets.top - plotInsets.bottom - 18
        )
    }

    private func screenPoint(forOpacityPoint point: SIMD2<Float>, in plotRect: CGRect, histogram: Metal3DHistogramModel) -> CGPoint {
        let xFraction = CGFloat((point.x - Float(histogram.minimumHU)) / Float(max(histogram.maximumHU - histogram.minimumHU, 1)))
        let yFraction = CGFloat(min(max(point.y, 0), 1))
        return CGPoint(
            x: plotRect.minX + min(max(xFraction, 0), 1) * plotRect.width,
            y: plotRect.minY + min(max(yFraction, 0), 1) * plotRect.height
        )
    }

    private func makeAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
        ]
    }
}
