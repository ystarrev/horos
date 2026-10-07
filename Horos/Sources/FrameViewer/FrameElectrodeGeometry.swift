// Swift adaptation of Tactics electrode geometry; see FrameElectrodes/LICENSE.
import AppKit
import simd

enum FrameElectrodeGeometry {
    static func localizerLines(_ fit: LeksellFrameFit?) -> [MetalViewerSceneLine] {
        guard let fit else { return [] }
        return stride(from: 0, to: fit.rodEndpointsLPS.count, by: 2).map {
            MetalViewerSceneLine(start: SIMD3<Float>(fit.rodEndpointsLPS[$0]),
                end: SIMD3<Float>(fit.rodEndpointsLPS[$0 + 1]), color: SIMD3(0.9, 0, 0.8))
        }
    }

    static func localizerRods(_ fit: LeksellFrameFit?) -> [FrameElectrode] {
        guard let fit else { return [] }
        return stride(from: 0, to: fit.rodEndpointsLPS.count, by: 2).compactMap { i in
            let a = fit.rodEndpointsLPS[i], b = fit.rodEndpointsLPS[i + 1]
            let length = simd_distance(a, b)
            guard length > 0, var spec = try? FrameElectrodeSpecification(identifier: "Localizer", text: "true\n0\n\(length)") else { return nil }
            spec.radiusMM = 0.6
            let direction = (b - a) / length
            var rod = FrameElectrode(name: "Rod \(i / 2 + 1)", specification: spec, targetLPS: a)
            rod.azimuthDegrees = acos(min(1, max(-1, -direction.x))) * 180 / .pi
            rod.imageDeclinationDegrees = atan2(direction.z, -direction.y) * 180 / .pi
            return rod
        }
    }

    static func surfaces(for electrode: FrameElectrode, selected: Bool) -> [MetalViewerSceneSurface] {
        guard electrode.isVisible else { return [] }
        let direction = electrode.shaftDirectionLPS
        let reference = abs(direction.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
        let u = simd_normalize(simd_cross(direction, reference))
        let v = simd_cross(direction, u)
        let spec = electrode.specification
        var contacts: [MetalViewerSurfaceVertex] = []
        var insulation: [MetalViewerSurfaceVertex] = []
        func vertex(_ position: SIMD3<Double>, _ normal: SIMD3<Double>) -> MetalViewerSurfaceVertex {
            MetalViewerSurfaceVertex(position: SIMD3<Float>(position), normal: SIMD3<Float>(normal))
        }
        for i in 0..<(spec.boundariesMM.count - 1) {
            let start = electrode.point(at: spec.boundariesMM[i])
            let end = electrode.point(at: spec.boundariesMM[i + 1])
            guard simd_distance(start, end) > 1e-8 else { continue }
            var vertices: [MetalViewerSurfaceVertex] = []
            for side in 0..<26 {
                let a = Double(side) * 2 * .pi / 26
                let b = Double(side + 1) * 2 * .pi / 26
                let n0 = u * cos(a) + v * sin(a)
                let n1 = u * cos(b) + v * sin(b)
                let p0 = start + n0 * spec.radiusMM
                let p1 = start + n1 * spec.radiusMM
                let p2 = end + n0 * spec.radiusMM
                let p3 = end + n1 * spec.radiusMM
                vertices += [vertex(p0, n0), vertex(p1, n1), vertex(p2, n0),
                             vertex(p1, n1), vertex(p3, n1), vertex(p2, n0)]
                if i == 0 { vertices += [vertex(start, -direction), vertex(p1, -direction), vertex(p0, -direction)] }
                if i == spec.boundariesMM.count - 2 {
                    vertices += [vertex(end, direction), vertex(p2, direction), vertex(p3, direction)]
                }
            }
            if spec.isContact(segment: i) { contacts += vertices } else { insulation += vertices }
        }
        return [
            MetalViewerSceneSurface(vertices: contacts, color: selected ? SIMD3(1, 0.5, 0) : SIMD3(0.65, 0.4, 0.15)),
            MetalViewerSceneSurface(vertices: insulation, color: selected ? SIMD3(repeating: 1) : SIMD3(repeating: 0.6))
        ].filter { !$0.vertices.isEmpty }
    }

    /// Draw only the portion intersecting a thin slab around each slice; do not
    /// project an out-of-plane electrode onto the anatomy as if it were in-plane.
    static func draw(_ electrodes: [FrameElectrode], selectedID: UUID?, slices: [MetalMPRROISliceGeometry], localizerStyle: Bool = false) {
        for slice in slices {
            let normal = simd_normalize(simd_cross(slice.topRightWorld - slice.topLeftWorld,
                                                 slice.bottomLeftWorld - slice.topLeftWorld))
            guard normal.x.isFinite else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: slice.imageRect).addClip()
            for electrode in electrodes where electrode.isVisible {
                let spec = electrode.specification
                let selected = electrode.id == selectedID
                for i in 0..<(spec.boundariesMM.count - 1) {
                    let a = electrode.point(at: spec.boundariesMM[i])
                    let b = electrode.point(at: spec.boundariesMM[i + 1])
                    let da = simd_dot(a - slice.topLeftWorld, normal)
                    let db = simd_dot(b - slice.topLeftWorld, normal)
                    let tolerance = spec.radiusMM
                    var lower = 0.0, upper = 1.0
                    if abs(db - da) < 1e-10 {
                        if abs(da) > tolerance { continue }
                    } else {
                        let t0 = (-tolerance - da) / (db - da)
                        let t1 = (tolerance - da) / (db - da)
                        lower = max(0, min(t0, t1)); upper = min(1, max(t0, t1))
                        if lower > upper { continue }
                    }
                    // Clip in slice coordinates as well as normal distance.
                    let p = a + (b - a) * lower
                    let q = a + (b - a) * upper
                    let x = slice.topRightWorld - slice.topLeftWorld
                    guard let start = slice.projectedScreenPoint(for: p),
                          let end = slice.projectedScreenPoint(for: q) else { continue }
                    let color: NSColor = localizerStyle ? NSColor(srgbRed: 0.9, green: 0, blue: 0.8, alpha: 1)
                        : (spec.isContact(segment: i) ? .systemOrange : .white)
                    color.withAlphaComponent(localizerStyle || selected ? 1 : 0.65).setStroke()
                    let path = NSBezierPath()
                    let transform = NSGraphicsContext.current?.cgContext.ctm ?? .identity
                    let pixelScale = max(hypot(transform.a, transform.b), 1)
                    path.lineWidth = localizerStyle ? 1 / pixelScale : max(1.5, 2 * spec.radiusMM * slice.imageRect.width / simd_length(x))
                    path.lineCapStyle = .round
                    path.move(to: start)
                    path.line(to: hypot(end.x - start.x, end.y - start.y) < 0.1
                              ? CGPoint(x: start.x + 0.1, y: start.y) : end)
                    path.stroke()
                }
                if !localizerStyle, let target = slice.screenPoint(for: electrode.targetLPS, planeToleranceMM: 0.5) {
                    (selected ? NSColor.systemCyan : .systemOrange).setStroke()
                    let marker = NSBezierPath(ovalIn: CGRect(x: target.x - 4, y: target.y - 4, width: 8, height: 8))
                    marker.lineWidth = 1.5
                    marker.stroke()
                    (electrode.name as NSString).draw(at: CGPoint(x: target.x + 7, y: target.y + 5),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
