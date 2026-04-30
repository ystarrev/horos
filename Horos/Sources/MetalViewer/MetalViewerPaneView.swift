import AppKit
import WebKit

final class MetalViewerPaneView: NSView {
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
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
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
            CGPoint(
                x: imageRect.minX + (slicePoint.x / imageSize.width) * imageRect.width,
                y: imageRect.minY + (slicePoint.y / imageSize.height) * imageRect.height
            )
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
            let sliceIndex: Int
            let sliceCount: Int
            let zoomScale: Float
            let windowLevel: Float
            let windowWidth: Float
            let mouseState: MetalImageView.MouseAnnotationState?
        }

        private enum TextAlign {
            case left
            case right
            case center
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

            drawAnnotations(state: overlayState)
            drawOverlaySeriesInfo(state: overlayState)
        }

        private func drawAnnotations(state: State) {
            let annotationsDictionary = state.pix.annotationsDictionary as? [String: Any] ?? [:]
            guard annotationsDictionary.isEmpty == false else {
                drawDefaultAnnotations(state: state)
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
                "LowerLeft": size.origin.y + size.size.height - 2,
                "LowerRight": size.origin.y + size.size.height - 2 - lineHeight,
                "LowerMiddle": size.origin.y + size.size.height - 2,
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

            if orientationDrawn {
                for key in orientationPositionKeys {
                    yRasterInit[key, default: 0] += yRasterIncrement[key, default: 0]
                }
            }

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
                    for string in strings where string.isEmpty == false {
                        if isSeriesNumber(string, state: state),
                           let studySeriesNumber = studySeriesNumberString(state: state) {
                            drawAttributedString(studySeriesNumber, atX: xRaster, y: yRaster, align: lineAlign)
                        } else {
                            drawString(string, atX: xRaster, y: yRaster, align: lineAlign)
                        }
                        yRaster += increment
                    }
                }
            }

            drawMadeInHoros()
        }

        private func drawDefaultAnnotations(state: State) {
            let lineHeight = Self.lineHeight
            let leftX = bounds.minX + 6
            let rightX = bounds.maxX - 2
            var topLeftY = bounds.minY + lineHeight + 2
            var topRightY = bounds.minY + lineHeight + 2
            var lowerLeftY = bounds.maxY - 2
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

            drawTopLeft(state.series.title)

            drawTopRightStudySeriesNumber()
            drawTopRight(String(format: "WL: %d WW: %d", Int(state.windowLevel.rounded()), Int(state.windowWidth.rounded())))
            drawTopRight("Im: \(state.sliceIndex + 1)/\(state.sliceCount)")

            if state.pix.sliceThickness != 0 {
                drawLowerRight(String(format: "Thickness: %0.2f mm", state.pix.sliceThickness))
            }
            if state.pix.sliceLocation != 0 {
                drawLowerRight(String(format: "Location: %0.2f mm", state.pix.sliceLocation))
            }

            drawLowerLeft(String(format: "Zoom: %.0f%%", state.zoomScale * 100.0))
            if let mouseState = state.mouseState {
                drawLowerLeft(String(format: "X: %d px Y: %d px Value: %.2f", Int(mouseState.pixelPoint.x), Int(mouseState.pixelPoint.y), mouseState.pixelValue))
            }

            drawOrientation(state: state, in: bounds)
        }

        private func drawOverlaySeriesInfo(state: State) {
            guard let overlaySeries = state.overlaySeries else {
                return
            }

            let yStart = topRightAnnotationBottomY(state: state) + 4
            let xStart: CGFloat = bounds.maxX - 6
            let formatter = Self.overlayDateFormatter
            let dateString = overlaySeries.studyDate.map { formatter.string(from: $0) } ?? ""
            let lines = [overlaySeries.title, dateString].filter { $0.isEmpty == false }

            for (index, line) in lines.enumerated() {
                drawOverlayString(line, atX: xStart, y: yStart + CGFloat(index) * Self.lineHeight, align: .right)
            }
        }

        private func topRightAnnotationBottomY(state: State) -> CGFloat {
            let annotationsDictionary = state.pix.annotationsDictionary as? [String: Any] ?? [:]
            let annotations = annotationsDictionary["TopRight"] as? [[Any]] ?? []
            let orderedAnnotations = Array(annotations)
            var yRaster = Self.lineHeight + 2

            for (index, annotation) in orderedAnnotations.enumerated() {
                let strings = resolve(annotation: annotation, key: "TopRight", index: index, state: state)
                for string in strings where string.isEmpty == false {
                    yRaster += Self.lineHeight
                }
            }

            return max(yRaster, 32)
        }

        private func resolve(annotation: [Any], key: String, index: Int, state: State) -> [String] {
            guard annotationContainsPatientIdentity(annotation, state: state) == false else {
                return []
            }

            var primary = ""
            var secondary: [String] = []

            for item in annotation {
                guard let value = item as? String else {
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
                    primary += " Angle: 0"
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
                        primary += String(format: "WL: %d WW: %d", Int(wl.rounded()), Int(ww.rounded()))
                    }
                case "Thickness / Location / Position":
                    if state.pix.sliceThickness != 0, state.pix.sliceLocation != 0 {
                        if state.pix.sliceThickness < 1.0, state.pix.sliceThickness != 0 {
                            if abs(state.pix.sliceLocation) < 1.0, state.pix.sliceLocation != 0 {
                                primary += String(format: "Thickness: %0.2f \u{00B5}m Location: %0.2f \u{00B5}m", state.pix.sliceThickness * 1000.0, state.pix.sliceLocation * 1000.0)
                            } else {
                                primary += String(format: "Thickness: %0.2f \u{00B5}m Location: %0.2f mm", state.pix.sliceThickness * 1000.0, state.pix.sliceLocation)
                            }
                        } else {
                            primary += String(format: "Thickness: %0.2f mm Location: %0.2f mm", state.pix.sliceThickness, state.pix.sliceLocation)
                        }
                    } else if let viewPosition = state.pix.viewPosition, let patientPosition = state.pix.patientPosition {
                        primary += "Position: \(viewPosition) \(patientPosition)"
                    } else if let viewPosition = state.pix.viewPosition {
                        primary += "Position: \(viewPosition)"
                    } else if let patientPosition = state.pix.patientPosition {
                        primary += "Position: \(patientPosition)"
                    }
                case "PatientName":
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

        private func annotationContainsPatientIdentity(_ annotation: [Any], state: State) -> Bool {
            let patientName = patientName(for: state.pix)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let patientID = patientID(for: state.pix)?.trimmingCharacters(in: .whitespacesAndNewlines)

            for item in annotation {
                guard let value = item as? String else {
                    continue
                }
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
                drawString(bottom, atX: rect.origin.x + rect.width / 2, y: rect.origin.y + rect.height - 4, align: .center)
            }
        }

        private func drawMadeInHoros() {
            drawString("Made In Horos", atX: bounds.maxX - 2, y: bounds.maxY - 2, align: .right)
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
        private static let overlayDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()
    }

    private let contentView = NSView()
    private let closeButton = NSButton()
    private let overlayBlendSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let annotationOverlay = AnnotationOverlayView()
    private let referenceLineOverlay = ReferenceLineOverlayView()
    private let registrationStatusView = RegistrationStatusView()
    private var metalView: MetalImageView?
    private var reportWebView: WKWebView?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    private var dismissRegistrationStatusOnMouseMove = false
    private var displayMode: MetalViewerDisplayMode = .stack2D

    private(set) var series: MetalViewerSeries
    private(set) var overlaySeries: MetalViewerSeries?
    private(set) var currentStateDescription: String = ""
    var stateDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var closeHandler: (() -> Void)?
    var seriesDropHandler: ((String, Bool) -> Void)?
    var windowLevelInteractionHandler: (() -> Void)?
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
        overlayBlendSlider.isHidden = true
        overlayBlendSlider.controlSize = .small
        contentView.addSubview(overlayBlendSlider)

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
        ])

        updateAppearance()
        updateCloseButtonVisibility()
        display(series: series)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        self.series = series
        self.overlaySeries = nil
        overlayBlendSlider.doubleValue = 0.5
        overlayBlendSlider.isHidden = true

        metalView?.removeFromSuperview()
        metalView = nil
        reportWebView?.removeFromSuperview()
        reportWebView = nil
        referenceLineOverlay.removeFromSuperview()
        annotationOverlay.removeFromSuperview()
        registrationStatusView.removeFromSuperview()

        if let html = series.structuredReportHTML() {
            contentView.layoutSubtreeIfNeeded()
            let reportWebView = WKWebView(frame: contentView.bounds)
            reportWebView.autoresizingMask = [.width, .height]
            reportWebView.setValue(true, forKey: "drawsBackground")
            reportWebView.wantsLayer = true
            reportWebView.layer?.backgroundColor = NSColor.white.cgColor
            reportWebView.allowsMagnification = true
            reportWebView.magnification = 1.0
            contentView.addSubview(reportWebView)

            reportWebView.loadHTMLString(html, baseURL: nil)
            self.reportWebView = reportWebView
            currentStateDescription = series.title
            stateDidChange?(currentStateDescription)
            updateAnnotationOverlay()
            updateReferenceLineOverlay()
            return
        }

        let metalView = MetalImageView(
            frame: .zero,
            pixList: series.loadedPixList(),
            windowLevelState: series.windowLevelState,
            windowLevelStateDidChange: { [weak series] state in
                series?.windowLevelState = state
            }
        )
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.activateHandler = { [weak self] in
            self?.activateHandler?()
        }
        metalView.interactionEventHandler = { [weak self] in
            self?.dismissRegistrationStatusIfNeeded()
        }
        metalView.windowLevelInteractionHandler = { [weak self] in
            self?.series.windowLevelPresetTitle = NSLocalizedString("Other", comment: "")
            self?.windowLevelInteractionHandler?()
        }
        metalView.titleDidChange = { [weak self] state in
            self?.currentStateDescription = state
            self?.stateDidChange?(state)
            self?.updateAnnotationOverlay()
            self?.updateReferenceLineOverlay()
        }
        metalView.annotationStateDidChange = { [weak self] in
            self?.updateAnnotationOverlay()
        }

        contentView.addSubview(metalView)
        contentView.addSubview(annotationOverlay, positioned: .above, relativeTo: metalView)
        contentView.addSubview(referenceLineOverlay, positioned: .above, relativeTo: annotationOverlay)
        contentView.addSubview(registrationStatusView, positioned: .above, relativeTo: referenceLineOverlay)
        contentView.addSubview(overlayBlendSlider, positioned: .above, relativeTo: registrationStatusView)

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

            registrationStatusView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            registrationStatusView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -78),
            registrationStatusView.widthAnchor.constraint(equalToConstant: 360),
        ])

        self.metalView = metalView
        metalView.setDisplayMode(displayMode)
        referenceLineOverlay.showsScales = displayMode == .stack2D
        metalView.renderer.registrationDidChange = { [weak self] isRunning, message, progress in
            self?.registrationStatusView.update(isRunning: isRunning, message: message, progress: progress)
            self?.dismissRegistrationStatusOnMouseMove = !isRunning && message.isEmpty == false
        }
        currentStateDescription = metalView.renderer.stateDescription
        stateDidChange?(currentStateDescription)
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
    }

    func overlay(series: MetalViewerSeries) {
        overlaySeries = series
        registrationStatusView.update(isRunning: true, message: "Preparing registration...", progress: 0)
        window?.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.metalView?.renderer.setOverlayPixList(
                series.loadedPixList(),
                windowLevelState: series.windowLevelState,
                windowLevelStateDidChange: { [weak series] state in
                    series?.windowLevelState = state
                }
            )
            self.overlayBlendSlider.doubleValue = 0.5
            self.overlayBlendSlider.isHidden = false
            self.currentStateDescription = self.metalView?.renderer.stateDescription ?? self.currentStateDescription
            self.stateDidChange?(self.currentStateDescription)
            self.updateAnnotationOverlay()
            self.updateReferenceLineOverlay()
        }
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
    }

    @objc private func closeButtonPressed(_ sender: Any?) {
        dismissRegistrationStatusIfNeeded()
        closeHandler?()
    }

    @objc private func overlayBlendSliderChanged(_ sender: NSSlider) {
        dismissRegistrationStatusIfNeeded()
        metalView?.renderer.setOverlayBlend(Float(sender.doubleValue))
    }

    private func dismissRegistrationStatusIfNeeded() {
        if dismissRegistrationStatusOnMouseMove {
            dismissRegistrationStatusOnMouseMove = false
            registrationStatusView.fadeOut()
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = isActive ? 2 : 1
        layer?.borderColor = (isActive ? NSColor.systemBlue : NSColor(calibratedWhite: 0.18, alpha: 1)).cgColor
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

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        displayMode = mode
        metalView?.setDisplayMode(mode)
        referenceLineOverlay.showsScales = mode == .stack2D
        if mode == .mpr {
            referenceLineOverlay.referenceLine = nil
        }
        updateAnnotationOverlay()
        updateReferenceLineOverlay()
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

    func applyRobustSeriesWindowLevelPreset() {
        guard let renderer = metalView?.renderer else { return }
        renderer.applyRobustSeriesWindowLevelPreset()
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
            sliceIndex: metalView.renderer.currentSliceIndex,
            sliceCount: metalView.renderer.pixList.count,
            zoomScale: metalView.renderer.zoomScale,
            windowLevel: metalView.renderer.windowLevel,
            windowWidth: metalView.renderer.windowWidth,
            mouseState: metalView.mouseAnnotationState
        )
    }

    private func updateReferenceLineOverlay() {
        guard let metalView,
              let geometry = metalView.currentSliceGeometry else {
            referenceLineOverlay.imageRect = .zero
            referenceLineOverlay.imageSize = CGSize(width: 1, height: 1)
            referenceLineOverlay.pixelSpacing = CGSize(width: 1, height: 1)
            return
        }

        referenceLineOverlay.imageRect = metalView.displayedImageRect
        referenceLineOverlay.imageSize = CGSize(width: geometry.width, height: geometry.height)
        referenceLineOverlay.pixelSpacing = CGSize(width: geometry.spacingX, height: geometry.spacingY)
    }

    private func draggingSeriesIdentifier(from draggingInfo: NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: .metalViewerSeriesIdentifier)
    }

    private func draggingInfoDropMode(from draggingInfo: NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: .metalViewerDropMode)
    }
}
