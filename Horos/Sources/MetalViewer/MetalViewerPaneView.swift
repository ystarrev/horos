import AppKit
import Metal
import simd
import WebKit

final class MetalViewerPaneView: NSView {
    private final class OverlayBlendSlider: NSSlider {
        var trackingStateDidChange: ((Bool) -> Void)?

        override func mouseDown(with event: NSEvent) {
            trackingStateDidChange?(true)
            defer { trackingStateDidChange?(false) }
            super.mouseDown(with: event)
        }
    }

    private final class RegistrationStatusView: NSView {
        private let backgroundView = NSVisualEffectView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let progressIndicator = NSProgressIndicator()
        private var timer: Timer?
        private var registrationStartDate: Date?
        private var baseMessage = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true

            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            backgroundView.material = .hudWindow
            backgroundView.state = .active
            backgroundView.wantsLayer = true
            backgroundView.layer?.cornerRadius = 10
            backgroundView.layer?.masksToBounds = true
            addSubview(backgroundView)

            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.alignment = .left
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.maximumNumberOfLines = 3
            backgroundView.addSubview(titleLabel)

            progressIndicator.translatesAutoresizingMaskIntoConstraints = false
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1
            progressIndicator.style = .bar
            backgroundView.addSubview(progressIndicator)

            NSLayoutConstraint.activate([
                backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
                backgroundView.topAnchor.constraint(equalTo: topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

                titleLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
                titleLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 10),

                progressIndicator.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
                progressIndicator.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
                progressIndicator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                progressIndicator.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -10),
            ])

            alphaValue = 0
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(isRunning: Bool, message: String, progress: Float) {
            if isRunning && registrationStartDate == nil {
                registrationStartDate = Date()
            } else if isRunning == false && message.isEmpty == false && registrationStartDate == nil {
                registrationStartDate = Date()
            }

            baseMessage = message.isEmpty ? "Registered" : message
            progressIndicator.doubleValue = Double(progress)
            progressIndicator.isHidden = !isRunning

            if isRunning || message.isEmpty == false {
                if isHidden {
                    isHidden = false
                    alphaValue = 0
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    animator().alphaValue = 1
                }
            }

            if isRunning {
                startTimerIfNeeded()
                updateDisplayedMessage()
            } else if message.isEmpty == false {
                stopTimer()
                updateDisplayedMessage()
            } else {
                stopTimer()
            }
        }

        func fadeOut() {
            guard isHidden == false else { return }
            stopTimer()
            registrationStartDate = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
            })
        }

        private func updateDisplayedMessage() {
            titleLabel.stringValue = "\(baseMessage)\nElapsed: \(elapsedString())"
        }

        private func elapsedString() -> String {
            guard let registrationStartDate else { return "0.0s" }
            return String(format: "%.1fs", Date().timeIntervalSince(registrationStartDate))
        }

        private func startTimerIfNeeded() {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateDisplayedMessage()
            }
        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }
    }

    private final class ReferenceLineOverlayView: NSView {
        private enum ScaleLayout {
            static let yOffset: CGFloat = 24
            static let xOffset: CGFloat = 32
            static let largeTick: CGFloat = 10
            static let smallTick: CGFloat = 5
        }

        var referenceLine: MetalViewerReferenceLine? {
            didSet { needsDisplay = true }
        }

        var imageRect: CGRect = .zero {
            didSet { needsDisplay = true }
        }

        var imageSize = CGSize(width: 1, height: 1) {
            didSet { needsDisplay = true }
        }

        var pixelSpacing = CGSize(width: 1, height: 1) {
            didSet { needsDisplay = true }
        }

        var imageRotationRadians: CGFloat = 0 {
            didSet { needsDisplay = true }
        }

        var sliceGeometry: MetalViewerSliceGeometry? {
            didSet { needsDisplay = true }
        }

        var tumourSeeds: [MetalViewerTumourSeed] = [] {
            didSet { needsDisplay = true }
        }

        var showsScales = true {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard imageRect.width > 0,
                  imageRect.height > 0,
                  imageSize.width > 0,
                  imageSize.height > 0 else {
                return
            }

            if showsScales {
                drawScales()
            }

            drawTumourSeeds()

            guard let referenceLine else {
                return
            }

            drawReferenceSlab(referenceLine)

            let linePath = NSBezierPath()
            linePath.move(to: viewPoint(for: referenceLine.start))
            linePath.line(to: viewPoint(for: referenceLine.end))
            linePath.lineWidth = 1.0 / max(window?.backingScaleFactor ?? 1.0, 1.0)
            linePath.lineCapStyle = .butt
            NSColor.systemRed.setStroke()
            linePath.stroke()
        }

        private func drawReferenceSlab(_ referenceLine: MetalViewerReferenceLine) {
            guard let offset = referenceLine.thicknessOffset,
                  abs(offset.dx) > 0.000001 || abs(offset.dy) > 0.000001 else {
                return
            }

            let startPlus = viewPoint(for: CGPoint(x: referenceLine.start.x + offset.dx, y: referenceLine.start.y + offset.dy))
            let endPlus = viewPoint(for: CGPoint(x: referenceLine.end.x + offset.dx, y: referenceLine.end.y + offset.dy))
            let endMinus = viewPoint(for: CGPoint(x: referenceLine.end.x - offset.dx, y: referenceLine.end.y - offset.dy))
            let startMinus = viewPoint(for: CGPoint(x: referenceLine.start.x - offset.dx, y: referenceLine.start.y - offset.dy))

            let slabPath = NSBezierPath()
            slabPath.move(to: startPlus)
            slabPath.line(to: endPlus)
            slabPath.line(to: endMinus)
            slabPath.line(to: startMinus)
            slabPath.close()
            NSColor.systemRed.withAlphaComponent(0.30).setFill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: imageRect).addClip()
            slabPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        private func viewPoint(for slicePoint: CGPoint) -> CGPoint {
            let point = CGPoint(
                x: imageRect.minX + (slicePoint.x / imageSize.width) * imageRect.width,
                y: imageRect.minY + (slicePoint.y / imageSize.height) * imageRect.height
            )
            return rotatedImagePoint(point)
        }

        private func rotatedImagePoint(_ point: CGPoint) -> CGPoint {
            guard abs(imageRotationRadians) > 0.000001 else {
                return point
            }

            let center = CGPoint(x: imageRect.midX, y: imageRect.midY)
            let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
            let cosine = cos(imageRotationRadians)
            let sine = sin(imageRotationRadians)
            return CGPoint(
                x: center.x + translated.x * cosine - translated.y * sine,
                y: center.y + translated.x * sine + translated.y * cosine
            )
        }

        private func drawTumourSeeds() {
            guard let sliceGeometry,
                  tumourSeeds.isEmpty == false,
                  imageRect.width > 0,
                  imageRect.height > 0 else {
                return
            }

            let fillColor = NSColor.systemRed.withAlphaComponent(0.52)
            let strokeColor = NSColor.systemRed
            let highlightColor = NSColor.white.withAlphaComponent(0.32)
            let scaleFactor = max(window?.backingScaleFactor ?? 1.0, 1.0)

            for seed in tumourSeeds {
                let radiusMM = max(seed.diameterMM * 0.5, 0.05)
                let distanceFromSlice = simd_dot(seed.dicomPoint - sliceGeometry.origin, sliceGeometry.normal)
                guard abs(distanceFromSlice) <= radiusMM else {
                    continue
                }

                let crossSectionRadiusMM = sqrt(max(radiusMM * radiusMM - distanceFromSlice * distanceFromSlice, 0))
                let slicePoint = sliceGeometry.slicePoint(from: seed.dicomPoint)
                guard slicePoint.x.isFinite,
                      slicePoint.y.isFinite,
                      slicePoint.x >= -1,
                      slicePoint.y >= -1,
                      slicePoint.x <= sliceGeometry.width + 1,
                      slicePoint.y <= sliceGeometry.height + 1 else {
                    continue
                }

                let center = viewPoint(for: slicePoint)
                let radiusX = CGFloat(crossSectionRadiusMM / sliceGeometry.spacingX) * imageRect.width / max(imageSize.width, 1)
                let radiusY = CGFloat(crossSectionRadiusMM / sliceGeometry.spacingY) * imageRect.height / max(imageSize.height, 1)
                let seedRect = CGRect(
                    x: center.x - radiusX,
                    y: center.y - radiusY,
                    width: radiusX * 2,
                    height: radiusY * 2
                )

                let path = NSBezierPath(ovalIn: seedRect)
                fillColor.setFill()
                path.fill()
                path.lineWidth = max(1.5, scaleFactor)
                strokeColor.setStroke()
                path.stroke()

                let highlightRect = seedRect.insetBy(dx: seedRect.width * 0.18, dy: seedRect.height * 0.18)
                    .offsetBy(dx: -seedRect.width * 0.10, dy: -seedRect.height * 0.10)
                let highlightPath = NSBezierPath(ovalIn: highlightRect)
                highlightPath.lineWidth = max(1.0, scaleFactor * 0.75)
                highlightColor.setStroke()
                highlightPath.stroke()
            }
        }

        private func drawScales() {
            let green = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
            let pixelsPerMMX = imageRect.width / max(imageSize.width * pixelSpacing.width, 0.0001)
            let pixelsPerMMY = imageRect.height / max(imageSize.height * pixelSpacing.height, 0.0001)
            let scaleFactor = window?.backingScaleFactor ?? 1.0

            let centerX = bounds.midX
            let centerY = bounds.midY
            let y = bounds.maxY - ScaleLayout.yOffset * scaleFactor
            let x = bounds.minX + ScaleLayout.xOffset * scaleFactor

            let path = NSBezierPath()
            path.lineWidth = scaleFactor
            green.setStroke()

            if pixelSpacing.width != 0, pixelSpacing.width * 1000.0 < 1.0 {
                let halfLengthX = 0.02 * pixelsPerMMX
                let halfLengthY = 0.02 * pixelsPerMMY

                path.move(to: CGPoint(x: centerX - halfLengthX, y: y))
                path.line(to: CGPoint(x: centerX + halfLengthX, y: y))

                path.move(to: CGPoint(x: x, y: centerY - halfLengthY))
                path.line(to: CGPoint(x: x, y: centerY + halfLengthY))

                for i in -20...20 {
                    let tickLength = CGFloat(i % 10 == 0 ? ScaleLayout.largeTick : ScaleLayout.smallTick) * scaleFactor
                    let dx = CGFloat(i) * 0.001 * pixelsPerMMX
                    let dy = CGFloat(i) * 0.001 * pixelsPerMMY

                    path.move(to: CGPoint(x: centerX + dx, y: y))
                    path.line(to: CGPoint(x: centerX + dx, y: y - tickLength))

                    path.move(to: CGPoint(x: x + tickLength, y: centerY + dy))
                    path.line(to: CGPoint(x: x, y: centerY + dy))
                }
            } else if pixelSpacing.width != 0, pixelSpacing.height != 0 {
                let halfLengthX = 50.0 * pixelsPerMMX
                let halfLengthY = 50.0 * pixelsPerMMY

                path.move(to: CGPoint(x: centerX - halfLengthX, y: y))
                path.line(to: CGPoint(x: centerX + halfLengthX, y: y))

                path.move(to: CGPoint(x: x, y: centerY - halfLengthY))
                path.line(to: CGPoint(x: x, y: centerY + halfLengthY))

                for i in -5...5 {
                    let tickLength = CGFloat(i % 5 == 0 ? ScaleLayout.largeTick : ScaleLayout.smallTick) * scaleFactor
                    let dx = CGFloat(i) * 10.0 * pixelsPerMMX
                    let dy = CGFloat(i) * 10.0 * pixelsPerMMY

                    path.move(to: CGPoint(x: centerX + dx, y: y))
                    path.line(to: CGPoint(x: centerX + dx, y: y - tickLength))

                    path.move(to: CGPoint(x: x + tickLength, y: centerY + dy))
                    path.line(to: CGPoint(x: x, y: centerY + dy))
                }
            }

            path.stroke()
        }
    }

    private final class AnnotationOverlayView: NSView {
        struct State {
            let series: MetalViewerSeries
            let overlaySeries: MetalViewerSeries?
            let pix: DCMPix
            let sliceGeometry: MetalViewerSliceGeometry?
            let sliceIndex: Int
            let sliceCount: Int
            let zoomScale: Float
            let rotationAngleDegrees: Float
            let windowLevel: Float
            let windowWidth: Float
            let mouseState: MetalImageView.MouseAnnotationState?
            let showsSliceOrientation: Bool
            let showsGantryTiltCorrectionLabel: Bool
            let annotationLevel: MetalViewerAnnotationLevel
        }

        private enum TextAlign {
            case left
            case right
            case center
        }

        private static func formattedStateValue(_ value: Float) -> String {
            guard value.isFinite else {
                return "--"
            }

            let roundedValue = Double(value.rounded())
            if abs(roundedValue) < 1_000_000_000 {
                return String(format: "%.0f", roundedValue)
            }
            return String(format: "%.3g", roundedValue)
        }

        var overlayState: State? {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard let overlayState else {
                return
            }

            guard overlayState.annotationLevel != .none else {
                return
            }

            if overlayState.annotationLevel == .graphics {
                if overlayState.showsSliceOrientation {
                    drawOrientation(state: overlayState, in: bounds)
                }
                return
            }

            drawAnnotations(state: overlayState)
            if overlayState.showsGantryTiltCorrectionLabel {
                drawGantryTiltCorrectionLabel()
            }
        }

        private func drawAnnotations(state: State) {
            let annotationsDictionary = state.pix.annotationsDictionary as? [String: Any] ?? [:]
            guard annotationsDictionary.isEmpty == false else {
                drawDefaultAnnotations(state: state)
                drawOverlayDateAtFallbackLocation(state: state)
                drawMadeInHoros()
                return
            }

            let lineHeight = ceil(Self.mainFont.ascender - Self.mainFont.descender + 2)
            let size = bounds

            let xRasterInit: [String: CGFloat] = [
                "TopLeft": size.origin.x + 6,
                "MiddleLeft": size.origin.x + 6,
                "LowerLeft": size.origin.x + 6,
                "TopRight": size.origin.x + size.size.width - 2,
                "MiddleRight": size.origin.x + size.size.width - 2,
                "LowerRight": size.origin.x + size.size.width - 2,
                "TopMiddle": size.origin.x + size.size.width / 2,
                "LowerMiddle": size.origin.x + size.size.width / 2,
            ]

            let align: [String: TextAlign] = [
                "TopLeft": .left,
                "MiddleLeft": .left,
                "LowerLeft": .left,
                "TopRight": .right,
                "MiddleRight": .right,
                "LowerRight": .right,
                "TopMiddle": .center,
                "LowerMiddle": .center,
            ]

            var yRasterInit: [String: CGFloat] = [
                "TopLeft": size.origin.y + lineHeight + 2,
                "TopMiddle": size.origin.y + lineHeight,
                "TopRight": size.origin.y + lineHeight + 2,
                "MiddleLeft": size.origin.y + size.size.height / 2,
                "MiddleRight": size.origin.y + size.size.height / 2,
                "LowerLeft": size.origin.y + size.size.height - 2 - lineHeight,
                "LowerRight": size.origin.y + size.size.height - 2 - lineHeight,
                "LowerMiddle": size.origin.y + size.size.height - 2 - lineHeight,
            ]

            let yRasterIncrement: [String: CGFloat] = [
                "TopLeft": lineHeight,
                "TopMiddle": lineHeight,
                "TopRight": lineHeight,
                "MiddleLeft": lineHeight,
                "MiddleRight": lineHeight,
                "LowerLeft": -lineHeight,
                "LowerRight": -lineHeight,
                "LowerMiddle": -lineHeight,
            ]

            let orientationPositionKeys = ["TopMiddle", "MiddleLeft", "MiddleRight", "LowerMiddle"]
            var orientationDrawn = false
            if state.showsSliceOrientation {
                for key in orientationPositionKeys {
                    let lines = annotationsDictionary[key] as? [[Any]] ?? []
                    for line in lines {
                        for item in line {
                            if let value = item as? String, value == "Orientation" {
                                if orientationDrawn == false {
                                    drawOrientation(state: state, in: size)
                                    orientationDrawn = true
                                }
                            }
                        }
                    }
                }
            }

            if orientationDrawn {
                for key in orientationPositionKeys {
                    yRasterInit[key, default: 0] += yRasterIncrement[key, default: 0]
                }
            }

            let overlayDate = overlayDateString(state: state)
            let acquisitionDate = acquisitionDateString(state: state)
            var didDrawOverlayDate = false
            let orderedKeys = ["TopLeft", "TopMiddle", "TopRight", "MiddleLeft", "MiddleRight", "LowerLeft", "LowerMiddle", "LowerRight"]
            for key in orderedKeys {
                let annotations = annotationsDictionary[key] as? [[Any]] ?? []
                var yRaster = yRasterInit[key] ?? 0
                let xRaster = xRasterInit[key] ?? 0
                let increment = yRasterIncrement[key] ?? lineHeight
                let lineAlign = align[key] ?? .left
                let orderedAnnotations = key.hasPrefix("Lower") ? annotations.reversed() : Array(annotations)

                for (index, annotation) in orderedAnnotations.enumerated() {
                    let strings = resolve(annotation: annotation, key: key, index: index, state: state)
                    let isAcquisitionDate = acquisitionDate.map { date in
                        strings.contains { $0.contains(date) }
                    } ?? false

                    if didDrawOverlayDate == false,
                       isAcquisitionDate,
                       key.hasPrefix("Lower") == false,
                       let overlayDate {
                        drawOverlayString(overlayDate, atX: xRaster, y: yRaster, align: lineAlign)
                        yRaster += increment
                        didDrawOverlayDate = true
                    }

                    for string in strings where string.isEmpty == false {
                        if isSeriesNumber(string, state: state),
                           let studySeriesNumber = studySeriesNumberString(state: state) {
                            drawAttributedString(studySeriesNumber, atX: xRaster, y: yRaster, align: lineAlign)
                        } else {
                            drawString(string, atX: xRaster, y: yRaster, align: lineAlign)
                        }
                        yRaster += increment
                    }

                    if didDrawOverlayDate == false,
                       isAcquisitionDate,
                       key.hasPrefix("Lower"),
                       let overlayDate {
                        drawOverlayString(overlayDate, atX: xRaster, y: yRaster, align: lineAlign)
                        yRaster += increment
                        didDrawOverlayDate = true
                    }
                }
            }

            if didDrawOverlayDate == false, overlayDate != nil {
                drawOverlayDateAtFallbackLocation(state: state)
            }

            drawMadeInHoros()
        }

        private func drawDefaultAnnotations(state: State) {
            let lineHeight = Self.lineHeight
            let leftX = bounds.minX + 6
            let rightX = bounds.maxX - 2
            var topLeftY = bounds.minY + lineHeight + 2
            var topRightY = bounds.minY + lineHeight + 2
            var lowerLeftY = bounds.maxY - 2 - lineHeight
            var lowerRightY = bounds.maxY - 2 - lineHeight

            func drawTopLeft(_ text: String) {
                drawString(text, atX: leftX, y: topLeftY, align: .left)
                topLeftY += lineHeight
            }

            func drawTopRight(_ text: String) {
                drawString(text, atX: rightX, y: topRightY, align: .right)
                topRightY += lineHeight
            }

            func drawTopRightStudySeriesNumber() {
                guard let text = studySeriesNumberString(state: state) else {
                    return
                }
                drawAttributedString(text, atX: rightX, y: topRightY, align: .right)
                topRightY += lineHeight
            }

            func drawLowerLeft(_ text: String) {
                drawString(text, atX: leftX, y: lowerLeftY, align: .left)
                lowerLeftY -= lineHeight
            }

            func drawLowerRight(_ text: String) {
                drawString(text, atX: rightX, y: lowerRightY, align: .right)
                lowerRightY -= lineHeight
            }

            if state.annotationLevel == .full,
               let patientName = patientName(for: state.pix),
               patientName.isEmpty == false {
                drawTopLeft(patientName)
            }
            drawTopLeft(state.series.title)

            drawTopRightStudySeriesNumber()
            drawTopRight("WL: \(Self.formattedStateValue(state.windowLevel)) WW: \(Self.formattedStateValue(state.windowWidth))")
            drawTopRight("Im: \(state.sliceIndex + 1)/\(state.sliceCount)")

            if let thickness = state.sliceGeometry?.sliceThickness, thickness != 0 {
                drawLowerRight(String(format: "Thickness: %0.2f mm", thickness))
            }
            if let location = state.sliceGeometry?.sliceLocation, location != 0 {
                drawLowerRight(String(format: "Location: %0.2f mm", location))
            }

            drawLowerLeft(String(format: "Zoom: %.0f%%", state.zoomScale * 100.0))
            if let mouseState = state.mouseState {
                drawLowerLeft(String(format: "X: %d px Y: %d px Value: %.2f", Int(mouseState.pixelPoint.x), Int(mouseState.pixelPoint.y), mouseState.pixelValue))
            }

            if state.showsSliceOrientation {
                drawOrientation(state: state, in: bounds)
            }
        }

        private func overlayDateString(state: State) -> String? {
            guard let overlaySeries = state.overlaySeries else {
                return nil
            }

            guard let studyDate = overlaySeries.studyDate else { return nil }
            return Self.overlayDateFormatter.string(from: studyDate)
        }

        private func acquisitionDateString(state: State) -> String? {
            guard let imageObject = state.pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSObject,
                  let acquisitionDate = imageObject.value(forKey: "date") as? Date else {
                return nil
            }
            return Self.acquisitionDateFormatter.string(from: acquisitionDate)
        }

        private func drawOverlayDateAtFallbackLocation(state: State) {
            guard let overlayDate = overlayDateString(state: state) else { return }
            drawOverlayString(
                overlayDate,
                atX: bounds.maxX - 2,
                y: bounds.maxY - 2 - Self.lineHeight * 2,
                align: .right
            )
        }

        private func resolve(annotation: [Any], key: String, index: Int, state: State) -> [String] {
            var primary = ""
            var secondary: [String] = []

            for item in annotation {
                guard let value = item as? String else {
                    continue
                }
                if state.annotationLevel != .full,
                   annotationItemContainsPatientIdentity(value, state: state) {
                    continue
                }

                switch value {
                case "Image Size":
                    break
                case "View Size":
                    break
                case "Zoom":
                    primary += String(format: "Zoom: %.0f%%", state.zoomScale * 100.0)
                case "Rotation Angle":
                    primary += String(format: " Angle: %0.0f", state.rotationAngleDegrees)
                case "Image Position":
                    primary += "Im: \(state.sliceIndex + 1)/\(state.sliceCount)"
                case "Mouse Position (px)":
                    if let mouseState = state.mouseState {
                        primary += String(format: "X: %d px Y: %d px Value: %.2f", Int(mouseState.pixelPoint.x), Int(mouseState.pixelPoint.y), mouseState.pixelValue)
                    }
                case "Mouse Position (mm)":
                    if let mouseState = state.mouseState {
                        primary += String(format: "X: %.2f mm Y: %.2f mm Z: %.2f mm", mouseState.dicomPoint.x, mouseState.dicomPoint.y, mouseState.dicomPoint.z)
                    }
                case "Window Level / Window Width":
                    let wl = state.windowLevel
                    let ww = state.windowWidth
                    if ww < 50, wl.rounded() != wl || ww.rounded() != ww {
                        primary += String(format: "WL: %0.4f WW: %0.4f", wl, ww)
                    } else {
                        primary += "WL: \(Self.formattedStateValue(wl)) WW: \(Self.formattedStateValue(ww))"
                    }
                case "Thickness / Location / Position":
                    if let geometry = state.sliceGeometry,
                       geometry.sliceThickness != 0,
                       geometry.sliceLocation != 0 {
                        if geometry.sliceThickness < 1.0 {
                            if abs(geometry.sliceLocation) < 1.0 {
                                primary += String(format: "Thickness: %0.2f \u{00B5}m Location: %0.2f \u{00B5}m", geometry.sliceThickness * 1000.0, geometry.sliceLocation * 1000.0)
                            } else {
                                primary += String(format: "Thickness: %0.2f \u{00B5}m Location: %0.2f mm", geometry.sliceThickness * 1000.0, geometry.sliceLocation)
                            }
                        } else {
                            primary += String(format: "Thickness: %0.2f mm Location: %0.2f mm", geometry.sliceThickness, geometry.sliceLocation)
                        }
                    } else if let viewPosition = state.pix.viewPosition, let patientPosition = state.pix.patientPosition {
                        primary += "Position: \(viewPosition) \(patientPosition)"
                    } else if let viewPosition = state.pix.viewPosition {
                        primary += "Position: \(viewPosition)"
                    } else if let patientPosition = state.pix.patientPosition {
                        primary += "Position: \(patientPosition)"
                    }
                case "PatientName", "PatientsName":
                    primary += patientName(for: state.pix) ?? ""
                case "PatientID":
                    primary += patientID(for: state.pix) ?? ""
                case "Orientation":
                    break
                default:
                    if primary.isEmpty {
                        primary = value
                    } else {
                        primary += " \(value)"
                    }
                }
            }

            if key == "TopRight", index == 0 {
                primary = primary.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                primary = primary.replacingOccurrences(of: "  ", with: " ")
            }

            if primary.trimmingCharacters(in: .whitespaces).isEmpty == false {
                secondary.insert(primary.trimmingCharacters(in: .whitespaces), at: 0)
            }

            return secondary
        }

        private func annotationItemContainsPatientIdentity(_ value: String, state: State) -> Bool {
            let patientName = patientName(for: state.pix)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let patientID = patientID(for: state.pix)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedValue == "PatientName" || trimmedValue == "PatientsName" || trimmedValue == "PatientID" {
                return true
            }
            if let patientName, patientName.isEmpty == false, trimmedValue == patientName {
                return true
            }
            if let patientID, patientID.isEmpty == false, trimmedValue == patientID {
                return true
            }
            return false
        }

        private func drawOrientation(state: State, in rect: CGRect) {
            let vectors = orientationVector(for: state.pix)

            let left = orientationText(for: Array(vectors[0...2]), inverted: true)
            let right = orientationText(for: Array(vectors[0...2]), inverted: false)
            let top = orientationText(for: Array(vectors[3...5]), inverted: true)
            let bottom = orientationText(for: Array(vectors[3...5]), inverted: false)

            if left.isEmpty == false {
                drawString(left, atX: rect.origin.x + 6, y: rect.origin.y + 2 + rect.height / 2, align: .left)
            }
            if right.isEmpty == false {
                drawString(right, atX: rect.origin.x + rect.width - 2, y: rect.origin.y + 2 + rect.height / 2, align: .right)
            }

            var yPosition = rect.origin.y + Self.lineHeight + 3
            if top.isEmpty == false {
                drawString(top, atX: rect.origin.x + rect.width / 2, y: yPosition, align: .center)
                yPosition += Self.lineHeight + 3
            }

            if let laterality = state.pix.laterality, laterality.isEmpty == false {
                drawString(laterality, atX: rect.origin.x + rect.width / 2, y: yPosition, align: .center)
                yPosition += Self.lineHeight + 3
            }

            if voiLUTApplied(for: state.pix) {
                drawString("VOI LUT Applied", atX: rect.origin.x + rect.width / 2, y: yPosition, align: .center)
            }

            if bottom.isEmpty == false {
                drawString(
                    bottom,
                    atX: rect.origin.x + rect.width / 2,
                    y: rect.maxY - Self.lineHeight - 2,
                    align: .center
                )
            }
        }

        private func drawMadeInHoros() {
            drawString("Made In Horos", atX: bounds.maxX - 2, y: bounds.maxY - 2, align: .right)
        }

        private func drawGantryTiltCorrectionLabel() {
            drawString(
                NSLocalizedString("Gantry Tilt Corrected", comment: ""),
                atX: bounds.maxX - 6,
                y: bounds.maxY - Self.lineHeight * 2 - 6,
                align: .right
            )
        }

        private func isSeriesNumber(_ text: String, state: State) -> Bool {
            let seriesNumber = state.series.seriesNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seriesNumber.isEmpty == false else {
                return false
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines) == seriesNumber
        }

        private func studySeriesNumberString(state: State) -> NSAttributedString? {
            let seriesNumber = state.series.seriesNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = NSMutableAttributedString(
                string: "\(state.series.studyNumber)",
                attributes: Self.studyNumberTextAttributes
            )

            if seriesNumber.isEmpty == false {
                text.append(NSAttributedString(string: "-\(seriesNumber)", attributes: Self.textAttributes))
            }

            return text
        }

        private func drawString(_ text: String, atX x: CGFloat, y: CGFloat, align: TextAlign) {
            guard text.isEmpty == false else {
                return
            }

            let string = text as NSString
            let size = string.size(withAttributes: Self.textAttributes)
            let drawPoint: CGPoint
            switch align {
            case .left:
                drawPoint = CGPoint(x: x, y: y)
            case .right:
                drawPoint = CGPoint(x: x - size.width, y: y)
            case .center:
                drawPoint = CGPoint(x: x - size.width / 2, y: y)
            }

            string.draw(at: CGPoint(x: drawPoint.x + 1, y: drawPoint.y + 1), withAttributes: Self.shadowAttributes)
            string.draw(at: drawPoint, withAttributes: Self.textAttributes)
        }

        private func drawAttributedString(_ text: NSAttributedString, atX x: CGFloat, y: CGFloat, align: TextAlign) {
            guard text.length > 0 else {
                return
            }

            let size = text.size()
            let drawPoint: CGPoint
            switch align {
            case .left:
                drawPoint = CGPoint(x: x, y: y)
            case .right:
                drawPoint = CGPoint(x: x - size.width, y: y)
            case .center:
                drawPoint = CGPoint(x: x - size.width / 2, y: y)
            }

            (text.string as NSString).draw(at: CGPoint(x: drawPoint.x + 1, y: drawPoint.y + 1), withAttributes: Self.shadowAttributes)
            text.draw(at: drawPoint)
        }

        private func drawOverlayString(_ text: String, atX x: CGFloat, y: CGFloat, align: TextAlign) {
            guard text.isEmpty == false else {
                return
            }

            let string = text as NSString
            let size = string.size(withAttributes: Self.overlayTextAttributes)
            let drawPoint: CGPoint
            switch align {
            case .left:
                drawPoint = CGPoint(x: x, y: y)
            case .right:
                drawPoint = CGPoint(x: x - size.width, y: y)
            case .center:
                drawPoint = CGPoint(x: x - size.width / 2, y: y)
            }

            string.draw(at: CGPoint(x: drawPoint.x + 1, y: drawPoint.y + 1), withAttributes: Self.shadowAttributes)
            string.draw(at: drawPoint, withAttributes: Self.overlayTextAttributes)
        }

        private func patientName(for pix: DCMPix) -> String? {
            guard let imageObject = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSObject else {
                return nil
            }
            return imageObject.value(forKeyPath: "series.study.name") as? String
        }

        private func patientID(for pix: DCMPix) -> String? {
            guard let imageObject = pix.perform(NSSelectorFromString("imageObj"))?.takeUnretainedValue() as? NSObject else {
                return nil
            }
            return imageObject.value(forKeyPath: "series.study.patientID") as? String
        }

        private func orientationText(for vector: [Float], inverted: Bool) -> String {
            guard vector.count == 3 else {
                return ""
            }

            var absX = abs(vector[0])
            var absY = abs(vector[1])
            var absZ = abs(vector[2])
            let xLabel = (inverted ? -vector[0] : vector[0]) < 0 ? "R" : "L"
            let yLabel = (inverted ? -vector[1] : vector[1]) < 0 ? "A" : "P"
            let zLabel = (inverted ? -vector[2] : vector[2]) < 0 ? "I" : "S"

            var result = ""
            for _ in 0..<3 {
                if absX > 0.2, absX >= absY, absX >= absZ {
                    result += xLabel
                    absX = 0
                } else if absY > 0.2, absY >= absX, absY >= absZ {
                    result += yLabel
                    absY = 0
                } else if absZ > 0.2, absZ >= absX, absZ >= absY {
                    result += zLabel
                    absZ = 0
                } else {
                    break
                }
            }

            return result
        }

        private func orientationVector(for pix: DCMPix) -> [Float] {
            var vector = Array(repeating: Float(0), count: 9)
            let selector = NSSelectorFromString("orientation:")
            typealias OrientationIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>?) -> Void
            let implementation = pix.method(for: selector)
            let function = unsafeBitCast(implementation, to: OrientationIMP.self)
            function(pix, selector, &vector)
            return vector
        }

        private func voiLUTApplied(for pix: DCMPix) -> Bool {
            (pix.value(forKey: "VOILUTApplied") as? Bool) ?? false
        }

        private static let mainFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        private static let lineHeight = ceil(mainFont.ascender - mainFont.descender + 2)
        private static let textColor = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
        private static let textAttributes: [NSAttributedString.Key: Any] = [
            .font: mainFont,
            .foregroundColor: textColor,
        ]
        private static let studyNumberTextAttributes: [NSAttributedString.Key: Any] = [
            .font: mainFont,
            .foregroundColor: NSColor.systemRed,
        ]
        private static let shadowAttributes: [NSAttributedString.Key: Any] = [
            .font: mainFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
        ]
        private static let overlayTextAttributes: [NSAttributedString.Key: Any] = [
            .font: mainFont,
            .foregroundColor: NSColor.systemRed,
        ]
        private static let acquisitionDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return formatter
        }()
        private static let overlayDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd, HH:mm:ss"
            return formatter
        }()
    }

    private final class MeasurementOverlayView: NSView {
        var measurements: [MetalViewerMeasurementOverlay] = [] {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { false }
        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            for measurement in measurements {
                drawMeasurement(measurement)
            }
        }

        private func drawMeasurement(_ measurement: MetalViewerMeasurementOverlay) {
            let color = measurement.isActive ? NSColor.systemYellow : Self.measurementColor
            let scaleFactor = max(window?.backingScaleFactor ?? 1.0, 1.0)
            drawLine(from: measurement.startPoint, to: measurement.endPoint, color: color, scaleFactor: scaleFactor)
            drawHandle(at: measurement.startPoint, color: color, scaleFactor: scaleFactor)
            drawHandle(at: measurement.endPoint, color: color, scaleFactor: scaleFactor)
            drawLabel(measurement.label, center: measurement.labelCenter, color: color)
        }

        private func drawLine(from startPoint: CGPoint, to endPoint: CGPoint, color: NSColor, scaleFactor: CGFloat) {
            let shadowPath = NSBezierPath()
            shadowPath.move(to: startPoint)
            shadowPath.line(to: endPoint)
            shadowPath.lineWidth = max(3.0, 3.0 / scaleFactor)
            shadowPath.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.85).setStroke()
            shadowPath.stroke()

            let path = NSBezierPath()
            path.move(to: startPoint)
            path.line(to: endPoint)
            path.lineWidth = max(1.6, 1.6 / scaleFactor)
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }

        private func drawHandle(at point: CGPoint, color: NSColor, scaleFactor: CGFloat) {
            let radius = max(3.2, 3.2 / scaleFactor)
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

            let shadow = NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5))
            NSColor.black.withAlphaComponent(0.85).setFill()
            shadow.fill()

            let handle = NSBezierPath(ovalIn: rect)
            color.setFill()
            handle.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            handle.lineWidth = max(1.0, 1.0 / scaleFactor)
            handle.stroke()
        }

        private func drawLabel(_ label: String, center: CGPoint, color: NSColor) {
            guard label.isEmpty == false else {
                return
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.labelFont,
                .foregroundColor: color,
            ]
            let string = label as NSString
            let textSize = string.size(withAttributes: attributes)
            let paddedSize = CGSize(width: textSize.width + 8, height: textSize.height + 4)
            var origin = CGPoint(
                x: center.x - paddedSize.width * 0.5,
                y: center.y - paddedSize.height * 0.5
            )
            origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - paddedSize.width - 4)
            origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - paddedSize.height - 4)

            let backgroundRect = CGRect(origin: origin, size: paddedSize)
            let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 4, yRadius: 4)
            NSColor.black.withAlphaComponent(0.72).setFill()
            backgroundPath.fill()
            color.withAlphaComponent(0.75).setStroke()
            backgroundPath.lineWidth = 1
            backgroundPath.stroke()

            string.draw(
                at: CGPoint(x: origin.x + 4, y: origin.y + 2),
                withAttributes: attributes
            )
        }

        private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        private static let measurementColor = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.28, alpha: 1.0)
    }

    private final class DynamicControlsView: NSVisualEffectView {
        private let previousButton = NSButton(title: "|◀", target: nil, action: nil)
        private let playButton = NSButton(title: "▶", target: nil, action: nil)
        private let nextButton = NSButton(title: "▶|", target: nil, action: nil)
        private let timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        private let timeLabel = NSTextField(labelWithString: "1/1")
        private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)

        var previousHandler: (() -> Void)?
        var playHandler: (() -> Void)?
        var nextHandler: (() -> Void)?
        var timeHandler: ((Int) -> Void)?
        var speedHandler: ((Double) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            material = .hudWindow
            blendingMode = .withinWindow
            state = .active
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true

            for button in [previousButton, playButton, nextButton] {
                button.translatesAutoresizingMaskIntoConstraints = false
                button.bezelStyle = .texturedRounded
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            }
            previousButton.toolTip = NSLocalizedString("Previous time point", comment: "")
            playButton.toolTip = NSLocalizedString("Play or pause the dynamic series", comment: "")
            nextButton.toolTip = NSLocalizedString("Next time point", comment: "")
            previousButton.target = self
            previousButton.action = #selector(previousPressed(_:))
            playButton.target = self
            playButton.action = #selector(playPressed(_:))
            nextButton.target = self
            nextButton.action = #selector(nextPressed(_:))

            timeSlider.translatesAutoresizingMaskIntoConstraints = false
            timeSlider.isContinuous = true
            timeSlider.target = self
            timeSlider.action = #selector(timeChanged(_:))
            timeSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timeLabel.textColor = .white
            timeLabel.alignment = .center
            timeLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true

            speedPopup.translatesAutoresizingMaskIntoConstraints = false
            speedPopup.controlSize = .small
            for rate in [0.25, 0.5, 1.0, 2.0, 4.0] {
                speedPopup.addItem(withTitle: String(format: "%gx", rate))
                speedPopup.lastItem?.representedObject = NSNumber(value: rate)
            }
            speedPopup.selectItem(withTitle: "1x")
            speedPopup.target = self
            speedPopup.action = #selector(speedChanged(_:))

            let stack = NSStackView(views: [previousButton, playButton, nextButton, timeSlider, timeLabel, speedPopup])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(index: Int, count: Int, isPlaying: Bool) {
            let safeCount = max(count, 1)
            timeSlider.maxValue = Double(max(safeCount - 1, 0))
            timeSlider.doubleValue = Double(min(max(index, 0), safeCount - 1))
            timeLabel.stringValue = "\(min(max(index, 0), safeCount - 1) + 1)/\(safeCount)"
            playButton.title = isPlaying ? "❚❚" : "▶"
        }

        @objc private func previousPressed(_ sender: Any?) { previousHandler?() }
        @objc private func playPressed(_ sender: Any?) { playHandler?() }
        @objc private func nextPressed(_ sender: Any?) { nextHandler?() }
        @objc private func timeChanged(_ sender: NSSlider) { timeHandler?(Int(sender.doubleValue.rounded())) }
        @objc private func speedChanged(_ sender: NSPopUpButton) {
            guard let rate = sender.selectedItem?.representedObject as? NSNumber else { return }
            speedHandler?(rate.doubleValue)
        }
    }

    private let contentView = NSView()
    private let closeButton = NSButton()
    private let overlayBlendSlider = OverlayBlendSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let annotationOverlay = AnnotationOverlayView()
    private let referenceLineOverlay = ReferenceLineOverlayView()
    private let measurementOverlay = MeasurementOverlayView()
    private let orientationOverlay = MetalOrientationOverlayView()
    private let registrationStatusView = RegistrationStatusView()
    private let dynamicControls = DynamicControlsView(frame: .zero)
    private var metalView: MetalImageView?
    private var reportWebView: WKWebView?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    private var dismissRegistrationStatusOnMouseMove = false
    private var isAdjustingOverlayBlend = false
    private var displayMode: MetalViewerDisplayMode = .stack2D
    private var mouseToolAssignments = MetalViewerMouseToolAssignments()
    private var tumourSeeds: [MetalViewerTumourSeed] = []
    private var tumourSeedObserver: NSObjectProtocol?
    private var dynamicSequence: MetalDynamicSequence?
    private var dynamicTimeIndex = 0
    private var dynamicPlaybackRate = 1.0
    private var dynamicPlaybackTimer: Timer?
    private var annotationLevel = MetalViewerAnnotationLevel.current

    private(set) var series: MetalViewerSeries
    private(set) var overlaySeries: MetalViewerSeries?
    private(set) var currentStateDescription: String = ""
    var stateDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var closeHandler: (() -> Void)?
    var seriesDropHandler: ((String, Bool) -> Void)?
    var displayedSeriesDidChange: (() -> Void)?
    var windowLevelInteractionHandler: (() -> Void)?
    var windowLevelTargetDidChange: ((MetalViewerSeries) -> Void)?
    var registrationInitialTransformProvider: ((MetalViewerSeries, MetalViewerSeries) -> MetalViewerRegistrationWorldTransform?)?
    var registrationSupportSelectionProvider: ((MetalViewerSeries, MetalViewerSeries) -> MetalViewerRegistrationSupportSelection?)?
    var registrationTransformDidComplete: ((MetalViewerSeries, MetalViewerSeries, MetalViewerRegistrationWorldTransform) -> Void)?
    var canClose: Bool = true {
        didSet { updateCloseButtonVisibility() }
    }
    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    init(series: MetalViewerSeries) {
        self.series = series
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.cornerRadius = 8
        addSubview(contentView)
        registerForDraggedTypes([.metalViewerSeriesIdentifier])

        annotationOverlay.translatesAutoresizingMaskIntoConstraints = false
        referenceLineOverlay.translatesAutoresizingMaskIntoConstraints = false
        measurementOverlay.translatesAutoresizingMaskIntoConstraints = false
        orientationOverlay.translatesAutoresizingMaskIntoConstraints = false

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.title = "\u{2715}"
        closeButton.font = NSFont.systemFont(ofSize: 30, weight: .black)
        closeButton.contentTintColor = .systemRed
        closeButton.wantsLayer = false
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        addSubview(closeButton)

        overlayBlendSlider.translatesAutoresizingMaskIntoConstraints = false
        overlayBlendSlider.target = self
        overlayBlendSlider.action = #selector(overlayBlendSliderChanged(_:))
        overlayBlendSlider.trackingStateDidChange = { [weak self] isTracking in
            self?.isAdjustingOverlayBlend = isTracking
        }
        overlayBlendSlider.isHidden = true
        overlayBlendSlider.controlSize = .small
        contentView.addSubview(overlayBlendSlider)

        dynamicControls.isHidden = true
        dynamicControls.previousHandler = { [weak self] in self?.stepDynamicTime(by: -1) }
        dynamicControls.playHandler = { [weak self] in self?.toggleDynamicPlayback() }
        dynamicControls.nextHandler = { [weak self] in self?.stepDynamicTime(by: 1) }
        dynamicControls.timeHandler = { [weak self] index in self?.setDynamicTimeIndex(index) }
        dynamicControls.speedHandler = { [weak self] rate in
            guard let self else { return }
            self.dynamicPlaybackRate = rate
            if self.dynamicPlaybackTimer != nil {
                self.startDynamicPlayback()
            }
        }
        contentView.addSubview(dynamicControls)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            overlayBlendSlider.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            overlayBlendSlider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            overlayBlendSlider.widthAnchor.constraint(equalToConstant: 180),

            dynamicControls.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dynamicControls.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        updateAppearance()
        updateCloseButtonVisibility()

        tumourSeedObserver = NotificationCenter.default.addObserver(
            forName: MetalViewerTumourSeedStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.tumourSeedsDidChange(notification)
        }

        display(series: series)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        dynamicPlaybackTimer?.invalidate()
        if let tumourSeedObserver {
            NotificationCenter.default.removeObserver(tumourSeedObserver)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    func display(series: MetalViewerSeries) {
        stopDynamicPlayback()
        dynamicSequence = nil
        dynamicTimeIndex = 0
        dynamicControls.isHidden = true
        self.series = series
        self.overlaySeries = nil
        displayedSeriesDidChange?()
        overlayBlendSlider.doubleValue = 0.5
        overlayBlendSlider.isHidden = true

        let reusableMetalView = metalView
        metalView?.removeFromSuperview()
        metalView = nil
        reportWebView?.removeFromSuperview()
        reportWebView = nil
        referenceLineOverlay.removeFromSuperview()
        measurementOverlay.removeFromSuperview()
        measurementOverlay.measurements = []
        orientationOverlay.removeFromSuperview()
        annotationOverlay.removeFromSuperview()
        registrationStatusView.removeFromSuperview()

        let structuredReportHTML = series.structuredReportHTML()

        if let html = structuredReportHTML {
            let reportWebView = WKWebView(frame: .zero)
            reportWebView.translatesAutoresizingMaskIntoConstraints = false
            reportWebView.setValue(true, forKey: "drawsBackground")
            reportWebView.wantsLayer = true
            reportWebView.layer?.backgroundColor = NSColor.white.cgColor
            reportWebView.allowsMagnification = true
            reportWebView.magnification = 1.0
            contentView.addSubview(reportWebView)
            NSLayoutConstraint.activate([
                reportWebView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                reportWebView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                reportWebView.topAnchor.constraint(equalTo: contentView.topAnchor),
                reportWebView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])

            reportWebView.loadHTMLString(html, baseURL: nil)
            self.reportWebView = reportWebView
            tumourSeeds = []
            currentStateDescription = series.title
            stateDidChange?(currentStateDescription)
            updateAnnotationOverlay()
            updateReferenceLineOverlay()
            updateOrientationOverlay()
            return
        }

        let pixList = series.loadedPixList()
        let windowLevelStateDidChange: (MetalViewerWindowLevelState) -> Void = { [weak series] state in
            series?.windowLevelState = state
        }
        let transferFunctionStateDidChange: (MetalViewerTransferFunctionState) -> Void = { [weak series] state in
            series?.transferFunctionState = state
        }
        let metalView: MetalImageView
        if let reusableMetalView, pixList.isEmpty == false {
            reusableMetalView.replaceSeries(
                pixList: pixList,
                windowLevelState: series.windowLevelState,
                windowLevelStateDidChange: windowLevelStateDidChange,
                usesAutomaticWindowLevel: series.isMagneticResonance,
                transferFunctionState: series.transferFunctionState,
                transferFunctionStateDidChange: transferFunctionStateDidChange
            )
            metalView = reusableMetalView
        } else {
            metalView = MetalImageView(
                frame: .zero,
                pixList: pixList,
                windowLevelState: series.windowLevelState,
                windowLevelStateDidChange: windowLevelStateDidChange,
                usesAutomaticWindowLevel: series.isMagneticResonance,
                transferFunctionState: series.transferFunctionState,
                transferFunctionStateDidChange: transferFunctionStateDidChange
            )
        }
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.mouseToolAssignments = mouseToolAssignments
        metalView.activateHandler = { [weak self] in
            self?.activateHandler?()
        }
        metalView.interactionEventHandler = { [weak self] in
            self?.dismissRegistrationStatusIfNeeded()
        }
        metalView.windowLevelInteractionHandler = { [weak self] in
            self?.activeWindowLevelSeries.windowLevelPresetTitle = NSLocalizedString("Other", comment: "")
            self?.windowLevelInteractionHandler?()
        }
        metalView.windowLevelInteractionAllowedHandler = { [weak self] in
            self?.isAdjustingOverlayBlend == false
        }
        metalView.titleDidChange = { [weak self] state in
            guard let self else { return }
            self.updateCurrentStateDescription(rendererState: state)
            self.updateAnnotationOverlay()
            self.updateReferenceLineOverlay()
            self.updateOrientationOverlay()
        }
        metalView.annotationStateDidChange = { [weak self] in
            self?.updateAnnotationOverlay()
        }
        metalView.measurementsDidChange = { [weak self] measurements in
            self?.measurementOverlay.measurements = measurements
        }
        metalView.tumourSeedPlacementHandler = { [weak self] placement in
            guard let self else { return }
            do {
                _ = try MetalViewerTumourSeedStore.shared.addSeed(placement: placement, for: self.series)
            } catch {
                NSSound.beep()
                NSLog("MetalViewerPaneView failed to autosave tumour seed: %@", error.localizedDescription)
            }
        }
        metalView.tumourSeedDeletionHandler = { [weak self] identifier in
            guard let self else { return }
            do {
                try MetalViewerTumourSeedStore.shared.deleteSeed(identifier: identifier, for: self.series)
            } catch {
                NSSound.beep()
                NSLog("MetalViewerPaneView failed to delete tumour seed: %@", error.localizedDescription)
            }
        }

        contentView.addSubview(metalView)
        contentView.addSubview(annotationOverlay, positioned: .above, relativeTo: metalView)
        contentView.addSubview(referenceLineOverlay, positioned: .above, relativeTo: annotationOverlay)
        contentView.addSubview(measurementOverlay, positioned: .above, relativeTo: referenceLineOverlay)
        contentView.addSubview(orientationOverlay, positioned: .above, relativeTo: measurementOverlay)
        contentView.addSubview(registrationStatusView, positioned: .above, relativeTo: orientationOverlay)
        contentView.addSubview(overlayBlendSlider, positioned: .above, relativeTo: registrationStatusView)
        contentView.addSubview(dynamicControls, positioned: .above, relativeTo: overlayBlendSlider)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: contentView.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            annotationOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            annotationOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            annotationOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            annotationOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            referenceLineOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            referenceLineOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            referenceLineOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            referenceLineOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            measurementOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            measurementOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            measurementOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            measurementOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            orientationOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            orientationOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            orientationOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            orientationOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            registrationStatusView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            registrationStatusView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -78),
            registrationStatusView.widthAnchor.constraint(equalToConstant: 360),
        ])

        self.metalView = metalView
        reloadTumourSeeds()
        metalView.setDisplayMode(displayMode)
        referenceLineOverlay.showsScales = displayMode == .stack2D && annotationLevel != .none
        metalView.renderer.registrationDidChange = { [weak self] isRunning, message, progress in
            self?.registrationStatusView.update(isRunning: isRunning, message: message, progress: progress)
            self?.dismissRegistrationStatusOnMouseMove = !isRunning && message.isEmpty == false
        }
        metalView.renderer.registrationTransformDidComplete = { [weak self] transform in
            guard let self, let overlaySeries = self.overlaySeries else { return }
            self.registrationTransformDidComplete?(self.series, overlaySeries, transform)
        }
        updateCurrentStateDescription(rendererState: metalView.renderer.stateDescription)
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
        updateOrientationOverlay()
        detectDynamicSequence(for: series)
    }

    private func detectDynamicSequence(for series: MetalViewerSeries) {
        series.detectDynamicSequence { [weak self, weak series] sequence in
            guard let self, let series, self.series === series, let sequence else { return }
            self.applyDynamicSequence(sequence)
        }
    }

    private func applyDynamicSequence(_ sequence: MetalDynamicSequence) {
        guard sequence.count > 1 else { return }
        dynamicSequence = sequence
        dynamicTimeIndex = 0
        dynamicControls.isHidden = false
        dynamicControls.toolTip = sequence.evidence.joined(separator: " • ")
        setDynamicTimeIndex(0, preservingSliceIndex: false)

        if sequence.confidence == .manual {
            startDynamicPlayback()
        }
    }

    private func setDynamicTimeIndex(_ requestedIndex: Int, preservingSliceIndex: Bool = true) {
        guard let dynamicSequence, dynamicSequence.timePoints.isEmpty == false else { return }
        let count = dynamicSequence.timePoints.count
        let index = (requestedIndex % count + count) % count
        dynamicTimeIndex = index

        if overlaySeries != nil {
            let previousWindowLevelSeries = activeWindowLevelSeries
            stopDynamicPlayback()
            overlaySeries = nil
            displayedSeriesDidChange?()
            overlayBlendSlider.isHidden = true
            metalView?.renderer.clearOverlayPixList()
            let currentWindowLevelSeries = activeWindowLevelSeries
            if previousWindowLevelSeries !== currentWindowLevelSeries {
                windowLevelTargetDidChange?(currentWindowLevelSeries)
            }
        }

        metalView?.display(
            pixList: dynamicSequence.timePoints[index],
            preservingSliceIndex: preservingSliceIndex
        )
        dynamicControls.update(index: index, count: count, isPlaying: dynamicPlaybackTimer != nil)
        updateCurrentStateDescription(rendererState: metalView?.renderer.stateDescription ?? currentStateDescription)
        prefetchDynamicTimePoint(at: index + 1)
    }

    private func stepDynamicTime(by offset: Int) {
        guard dynamicSequence != nil else { return }
        setDynamicTimeIndex(dynamicTimeIndex + offset)
    }

    private func toggleDynamicPlayback() {
        if dynamicPlaybackTimer == nil {
            startDynamicPlayback()
        } else {
            stopDynamicPlayback()
        }
    }

    private func startDynamicPlayback() {
        guard let dynamicSequence, dynamicSequence.count > 1 else { return }
        dynamicPlaybackTimer?.invalidate()
        let interval = max(dynamicSequence.frameDuration / max(dynamicPlaybackRate, 0.01), 1.0 / 60.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.stepDynamicTime(by: 1)
        }
        dynamicPlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        dynamicControls.update(index: dynamicTimeIndex, count: dynamicSequence.count, isPlaying: true)
    }

    private func stopDynamicPlayback() {
        dynamicPlaybackTimer?.invalidate()
        dynamicPlaybackTimer = nil
        if let dynamicSequence {
            dynamicControls.update(index: dynamicTimeIndex, count: dynamicSequence.count, isPlaying: false)
        }
    }

    private func prefetchDynamicTimePoint(at requestedIndex: Int) {
        guard let dynamicSequence, dynamicSequence.count > 1,
              let device = MTLCreateSystemDefaultDevice() else { return }
        let index = (requestedIndex % dynamicSequence.count + dynamicSequence.count) % dynamicSequence.count
        let pixList = dynamicSequence.timePoints[index]
        guard pixList.count > 1 else { return }
        MetalSeriesTextureCache.shared.requestEntry(
            for: pixList,
            device: device
        ) { _ in }
    }

    private func updateCurrentStateDescription(rendererState: String) {
        if let dynamicSequence {
            currentStateDescription = "\(rendererState)  •  Time \(dynamicTimeIndex + 1)/\(dynamicSequence.count)"
        } else {
            currentStateDescription = rendererState
        }
        stateDidChange?(currentStateDescription)
    }

    func overlay(series: MetalViewerSeries) {
        stopDynamicPlayback()
        dynamicSequence = nil
        dynamicControls.isHidden = true
        overlaySeries = series
        displayedSeriesDidChange?()
        registrationStatusView.update(isRunning: true, message: "Preparing registration...", progress: 0)
        window?.displayIfNeeded()
        let suggestedTransform = registrationInitialTransformProvider?(self.series, series)
        let supportSelection = registrationSupportSelectionProvider?(self.series, series)
        let supportInputs = supportSelection?.items.compactMap { item -> MetalViewerRegistrationSupportInput? in
            let pixList = item.series.loadedPixList()
            let pairedPixList = item.pairedSeries?.loadedPixList()
            guard pixList.isEmpty == false,
                  item.pairedSeries == nil || pairedPixList?.isEmpty == false else {
                return nil
            }
            return MetalViewerRegistrationSupportInput(
                identifier: [item.series.identifier, item.pairedSeries?.identifier]
                    .compactMap { $0 }
                    .joined(separator: "|"),
                pixList: pixList,
                pairedPixList: pairedPixList,
                sharesBaseFrame: item.sharesBaseFrame,
                weight: item.weight
            )
        } ?? []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.metalView?.renderer.setOverlayPixList(
                series.loadedPixList(),
                suggestedRegistrationWorldTransform: suggestedTransform,
                registrationPrimaryWeight: supportSelection?.primaryWeight ?? 1,
                registrationSupportInputs: supportInputs,
                windowLevelState: series.windowLevelState,
                windowLevelStateDidChange: { state in
                    series.windowLevelState = state
                },
                usesAutomaticWindowLevel: series.isMagneticResonance,
                transferFunctionState: series.transferFunctionState,
                transferFunctionStateDidChange: { state in
                    series.transferFunctionState = state
                }
            )
            self.setOverlayBlend(0.5)
            self.overlayBlendSlider.isHidden = false
            self.updateCurrentStateDescription(
                rendererState: self.metalView?.renderer.stateDescription ?? self.currentStateDescription
            )
            self.updateAnnotationOverlay()
            self.updateReferenceLineOverlay()
            self.updateOrientationOverlay()
        }
    }

    func refreshAfterDatabaseUpdate(series updatedSeries: MetalViewerSeries, overlaySeries updatedOverlaySeries: MetalViewerSeries?) -> Bool {
        let primaryImageCountChanged = updatedSeries.imageCount != series.imageCount
        let overlayForRefresh = updatedOverlaySeries ?? overlaySeries
        let overlayImageCountChanged: Bool
        if let overlaySeries, let overlayForRefresh {
            overlayImageCountChanged = overlayForRefresh.imageCount != overlaySeries.imageCount
        } else {
            overlayImageCountChanged = false
        }

        guard primaryImageCountChanged || overlayImageCountChanged else {
            updatedSeries.retainLoadedPixelCache(from: series)
            series = updatedSeries
            if let overlaySeries, let overlayForRefresh {
                overlayForRefresh.retainLoadedPixelCache(from: overlaySeries)
                self.overlaySeries = overlayForRefresh
            }
            displayedSeriesDidChange?()
            reloadTumourSeeds()
            updateAnnotationOverlay()
            updateReferenceLineOverlay()
            updateOrientationOverlay()
            return false
        }

        let preservedDisplayMode = displayMode
        let preservedSliceIndex = metalView?.renderer.currentSliceIndex ?? 0
        let preservedOverlayBlend = overlayBlendSlider.doubleValue
        let shouldRestoreOverlay = overlayForRefresh != nil && overlaySeries != nil

        display(series: updatedSeries)
        setDisplayMode(preservedDisplayMode)
        metalView?.renderer.setSliceIndex(preservedSliceIndex)

        if shouldRestoreOverlay, let overlayForRefresh {
            overlay(series: overlayForRefresh)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self else { return }
                self.setOverlayBlend(preservedOverlayBlend)
            }
        }

        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(point) == false {
            activateHandler?()
        }
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCloseButtonVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        dismissRegistrationStatusIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateCloseButtonVisibility()
    }

    override func layout() {
        super.layout()
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
        updateOrientationOverlay()
    }

    @objc private func closeButtonPressed(_ sender: Any?) {
        dismissRegistrationStatusIfNeeded()
        closeHandler?()
    }

    @objc private func overlayBlendSliderChanged(_ sender: NSSlider) {
        dismissRegistrationStatusIfNeeded()
        setOverlayBlend(sender.doubleValue)
    }

    private func setOverlayBlend(_ value: Double) {
        let previousWindowLevelSeries = activeWindowLevelSeries
        overlayBlendSlider.doubleValue = value
        metalView?.renderer.setOverlayBlend(Float(value))
        let currentWindowLevelSeries = activeWindowLevelSeries
        if previousWindowLevelSeries !== currentWindowLevelSeries {
            windowLevelTargetDidChange?(currentWindowLevelSeries)
        }
    }

    private func dismissRegistrationStatusIfNeeded() {
        if dismissRegistrationStatusOnMouseMove {
            dismissRegistrationStatusOnMouseMove = false
            registrationStatusView.fadeOut()
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = isActive ? 3 : 1
        layer?.borderColor = (isActive ? metalViewerActiveSelectionBlue : NSColor(calibratedWhite: 0.18, alpha: 1)).cgColor
        layer?.shadowColor = metalViewerActiveSelectionBlue.cgColor
        layer?.shadowOpacity = isActive ? 0.95 : 0
        layer?.shadowRadius = isActive ? 6 : 0
        layer?.shadowOffset = .zero
    }

    private func updateCloseButtonVisibility() {
        closeButton.isHidden = !(isHovering && canClose)
    }

    func currentSliceGeometry() -> MetalViewerSliceGeometry? {
        guard metalView?.renderer.displayMode == .stack2D else {
            return nil
        }
        return metalView?.currentSliceGeometry
    }

    var supportsImagePrinting: Bool {
        metalView?.renderer.displayMode == .stack2D
    }

    func makePrintFrame() -> MetalPrintFrame? {
        guard let renderer = metalView?.renderer else { return nil }
        return renderer.makePrintFrame(at: renderer.currentSliceIndex)
    }

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        displayMode = mode
        metalView?.setDisplayMode(mode)
        referenceLineOverlay.showsScales = mode == .stack2D && annotationLevel != .none
        if mode.isMPRLike {
            referenceLineOverlay.referenceLine = nil
        }
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
        updateOrientationOverlay()
    }

    func setAnnotationLevel(_ level: MetalViewerAnnotationLevel) {
        annotationLevel = level
        referenceLineOverlay.showsScales = displayMode == .stack2D && level != .none
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
        updateOrientationOverlay()
    }

    func setMouseToolAssignments(_ assignments: MetalViewerMouseToolAssignments) {
        mouseToolAssignments = assignments
        metalView?.mouseToolAssignments = assignments
    }

    var currentScale: Float? {
        metalView?.renderer.zoomScale
    }

    func setScale(_ scale: Float) {
        metalView?.renderer.setZoomScale(scale)
    }

    func focusImageView() {
        guard let metalView else { return }
        window?.makeFirstResponder(metalView)
    }

    func setReferenceLine(_ line: MetalViewerReferenceLine?) {
        referenceLineOverlay.referenceLine = line
        updateReferenceLineOverlay()
    }

    var currentWindowLevel: MetalViewerWindowLevel? {
        guard let renderer = metalView?.renderer else { return nil }
        return MetalViewerWindowLevel(level: renderer.activeWindowLevel, width: renderer.activeWindowWidth)
    }

    var activeWindowLevelSeries: MetalViewerSeries {
        if let overlaySeries, metalView?.renderer.isOverlayWindowLevelActive == true {
            return overlaySeries
        }
        return series
    }

    var activeTransferFunctionState: MetalViewerTransferFunctionState {
        metalView?.renderer.activeTransferFunctionState ?? activeWindowLevelSeries.transferFunctionState
    }

    func applyCLUT(named presetName: String) {
        metalView?.renderer.applyCLUT(named: presetName)
    }

    func applyOpacity(named presetName: String) {
        metalView?.renderer.applyOpacity(named: presetName)
    }

    func applyWindowLevel(_ window: MetalViewerWindowLevel) {
        guard let renderer = metalView?.renderer else { return }
        renderer.applyWindowLevel(window, asCustom: true)
        updateAnnotationOverlay()
    }

    func applyDefaultWindowLevelPreset() {
        guard let renderer = metalView?.renderer else { return }
        renderer.applyDefaultWindowLevelPreset()
        updateAnnotationOverlay()
    }

    func applyFullDynamicWindowLevelPreset() {
        guard let renderer = metalView?.renderer else { return }
        renderer.applyFullDynamicWindowLevelPreset()
        updateAnnotationOverlay()
    }

    func applyAutomaticWindowLevelPreset() {
        guard let renderer = metalView?.renderer else { return }
        renderer.applyAutomaticWindowLevelPreset()
        updateAnnotationOverlay()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggingSeriesIdentifier(from: sender) != nil else {
            return []
        }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggingSeriesIdentifier(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let identifier = draggingSeriesIdentifier(from: sender) else {
            return false
        }
        let isOverlay = draggingInfoDropMode(from: sender) == "overlay"
        seriesDropHandler?(identifier, isOverlay)
        return true
    }

    private func updateAnnotationOverlay() {
        guard let metalView, let pix = metalView.renderer.currentPix else {
            annotationOverlay.overlayState = nil
            return
        }

        annotationOverlay.overlayState = AnnotationOverlayView.State(
            series: series,
            overlaySeries: overlaySeries,
            pix: pix,
            sliceGeometry: MetalViewerSliceGeometry(pix: pix),
            sliceIndex: metalView.renderer.currentSliceIndex,
            sliceCount: metalView.renderer.pixList.count,
            zoomScale: metalView.renderer.zoomScale,
            rotationAngleDegrees: metalView.renderer.displayedStackRotationDegrees,
            windowLevel: metalView.renderer.windowLevel,
            windowWidth: metalView.renderer.windowWidth,
            mouseState: metalView.mouseAnnotationState,
            showsSliceOrientation: displayMode == .stack2D,
            showsGantryTiltCorrectionLabel: metalView.renderer.displaysGantryTiltCorrectedImage,
            annotationLevel: annotationLevel
        )
    }

    private func updateOrientationOverlay() {
        guard annotationLevel != .none, displayMode == .mpr, let metalView else {
            orientationOverlay.overlayState = nil
            return
        }

        orientationOverlay.overlayState = metalView.renderer.orientationOverlayState(in: metalView.bounds)
    }

    private func updateReferenceLineOverlay() {
        guard displayMode == .stack2D else {
            referenceLineOverlay.imageRect = .zero
            referenceLineOverlay.imageSize = CGSize(width: 1, height: 1)
            referenceLineOverlay.pixelSpacing = CGSize(width: 1, height: 1)
            referenceLineOverlay.imageRotationRadians = 0
            referenceLineOverlay.sliceGeometry = nil
            referenceLineOverlay.tumourSeeds = []
            return
        }

        guard let metalView,
              let geometry = metalView.currentSliceGeometry else {
            referenceLineOverlay.imageRect = .zero
            referenceLineOverlay.imageSize = CGSize(width: 1, height: 1)
            referenceLineOverlay.pixelSpacing = CGSize(width: 1, height: 1)
            referenceLineOverlay.imageRotationRadians = 0
            referenceLineOverlay.sliceGeometry = nil
            referenceLineOverlay.tumourSeeds = []
            return
        }

        referenceLineOverlay.imageRect = metalView.displayedImageRect
        referenceLineOverlay.imageSize = CGSize(width: geometry.width, height: geometry.height)
        referenceLineOverlay.pixelSpacing = CGSize(width: geometry.spacingX, height: geometry.spacingY)
        referenceLineOverlay.imageRotationRadians = CGFloat(metalView.renderer.stackRotationRadians)
        referenceLineOverlay.sliceGeometry = geometry
        referenceLineOverlay.tumourSeeds = tumourSeeds
    }

    private func tumourSeedsDidChange(_ notification: Notification) {
        guard MetalViewerTumourSeedStore.notification(notification, matches: series.tumourSeedScope) else {
            return
        }
        reloadTumourSeeds()
    }

    private func reloadTumourSeeds() {
        tumourSeeds = MetalViewerTumourSeedStore.shared.seeds(for: series)
        metalView?.renderer.setTumourSeeds(tumourSeeds)
        referenceLineOverlay.tumourSeeds = tumourSeeds
        updateReferenceLineOverlay()
    }

    private func draggingSeriesIdentifier(from draggingInfo: NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: .metalViewerSeriesIdentifier)
    }

    private func draggingInfoDropMode(from draggingInfo: NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: .metalViewerDropMode)
    }
}
