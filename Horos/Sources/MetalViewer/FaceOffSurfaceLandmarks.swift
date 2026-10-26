// FaceOff detects landmarks on the rendered CT/MR surface, in meters.
// The volume viewer converts its normalized coordinates at the boundary.
import Foundation
import CoreGraphics
import Metal
import Vision
import simd

enum HeadAuxiliaryContourKind: CaseIterable, Hashable, Sendable {
    case leftBrow, rightBrow, midline, faceOutline
    case visionLeftEye, visionRightEye, visionNoseCrest, visionNoseOutline, rawCanthi
    case surfaceEyeSeam, surfaceNoseApex
}

struct HeadImageLandmarks {
    let points: [HeadLandmarkID: CGPoint] // Upright image, normalized, top-left origin.
    let auxiliaryContours: [HeadAuxiliaryContourKind: [CGPoint]]
    let noseSearchRect: CGRect
    let noseAxisX: CGFloat
    let fallbackNoseSearchRect: CGRect?
    let fallbackNoseBridge: CGPoint?
    let fallbackNoseAxisX: CGFloat
    let hasObservedNose: Bool
    let confidence: Float
    let usedImagePoseFallback: Bool
}

struct HeadImageAuxiliaryContourCandidate {
    let contours: [HeadAuxiliaryContourKind: [CGPoint]]
    let confidence: Float
}

struct HeadFaceLandmarkDetection {
    let landmarks: [HeadImageLandmarks]
    let contourCandidates: [HeadImageAuxiliaryContourCandidate]
    let faceCount: Int
    let rawEyeContourCount: Int
    let confidentEyeContourCount: Int
    let acceptablePoseEyeContourCount: Int
    let reorderedEyeContourCount: Int
    let fallbackSpacingCount: Int
    let fallbackLevelCount: Int
    let bestEyeConfidence: Float?
    let bestEyePoseMagnitude: Float?
    let eyeContourCount: Int
    let noseContourCount: Int
}

enum HeadFaceLandmarkDetector {
    private static func eyeCorners(_ eye: [CGPoint]) -> (minX: CGPoint, maxX: CGPoint) {
        let minimumX = eye.map(\.x).min()!
        let maximumX = eye.map(\.x).max()!
        let endWidth = (maximumX - minimumX) * 0.12
        func corner(x: CGFloat, nearLeft: Bool) -> CGPoint {
            let end = eye.filter { nearLeft ? $0.x <= minimumX + endWidth : $0.x >= maximumX - endWidth }
                .map(\.y).sorted()
            // The contour's vertical midpoint can sit on the lower lid; use the local canthus instead.
            let localY = (end[(end.count - 1) / 2] + end[end.count / 2]) * 0.5
            return CGPoint(x: x, y: localY)
        }
        return (corner(x: minimumX, nearLeft: true), corner(x: maximumX, nearLeft: false))
    }

    static func detect(image: CGImage, face: VNFaceObservation? = nil,
                       request: VNDetectFaceLandmarksRequest = VNDetectFaceLandmarksRequest(),
                       revision: Int = VNDetectFaceLandmarksRequestRevision3) throws -> HeadFaceLandmarkDetection {
        request.revision = revision
        if let face { request.inputFaceObservations = [face] }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let observations = request.results ?? []
        var rawEyeContourCount = 0
        var confidentEyeContourCount = 0
        var acceptablePoseEyeContourCount = 0
        var reorderedEyeContourCount = 0
        var fallbackSpacingCount = 0
        var fallbackLevelCount = 0
        var bestEyeConfidence: Float?
        var bestEyePoseMagnitude: Float?
        var eyeContourCount = 0
        var noseContourCount = 0
        var contourCandidates: [HeadImageAuxiliaryContourCandidate] = []
        let landmarks = observations.compactMap { face -> HeadImageLandmarks? in
            guard let features = face.landmarks else { return nil }
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (region?.normalizedPoints ?? []).map {
                    CGPoint(x: face.boundingBox.minX + $0.x * face.boundingBox.width,
                            y: 1 - (face.boundingBox.minY + $0.y * face.boundingBox.height))
                }
            }
            var left = points(features.leftEye), right = points(features.rightEye)
            let crest = points(features.noseCrest), nose = points(features.nose)
            var auxiliaryContours: [HeadAuxiliaryContourKind: [CGPoint]] = [
                .leftBrow: points(features.leftEyebrow),
                .rightBrow: points(features.rightEyebrow),
                .midline: points(features.medianLine),
                .faceOutline: points(features.faceContour),
                .visionLeftEye: left, .visionRightEye: right,
                .visionNoseCrest: crest, .visionNoseOutline: nose
            ]
            let poseMagnitude = max(abs(face.yaw?.floatValue ?? 0),
                                    max(abs(face.roll?.floatValue ?? 0),
                                        abs(face.pitch?.floatValue ?? 0)))
            let confidenceAccepted = face.confidence >= 0.5
            let poseAccepted = poseMagnitude.isFinite && poseMagnitude <= 0.7
            let poseUsable = confidenceAccepted && poseAccepted
            if confidenceAccepted && auxiliaryContours.values.contains(where: { !$0.isEmpty }) {
                contourCandidates.append(HeadImageAuxiliaryContourCandidate(
                    contours: auxiliaryContours, confidence: face.confidence))
            }
            guard left.count >= 4, right.count >= 4 else { return nil }
            rawEyeContourCount += 1
            if left.reduce(CGFloat.zero, { $0 + $1.x }) / CGFloat(left.count) >
               right.reduce(CGFloat.zero, { $0 + $1.x }) / CGFloat(right.count) {
                swap(&left, &right)
                reorderedEyeContourCount += 1
            }
            if confidenceAccepted { confidentEyeContourCount += 1 }
            if poseAccepted { acceptablePoseEyeContourCount += 1 }
            if face.confidence.isFinite {
                bestEyeConfidence = max(bestEyeConfidence ?? face.confidence, face.confidence)
            }
            if poseMagnitude.isFinite {
                bestEyePoseMagnitude = min(bestEyePoseMagnitude ?? poseMagnitude, poseMagnitude)
            }
            let leftCorners = eyeCorners(left), rightCorners = eyeCorners(right)
            auxiliaryContours[.rawCanthi] = [leftCorners.minX, leftCorners.maxX,
                                              rightCorners.minX, rightCorners.maxX]
            if confidenceAccepted {
                contourCandidates.append(HeadImageAuxiliaryContourCandidate(
                    contours: auxiliaryContours, confidence: face.confidence))
            }
            let innerGap = rightCorners.minX.x - leftCorners.maxX.x
            let leftCenter = CGPoint(x: (leftCorners.minX.x + leftCorners.maxX.x) * 0.5,
                                     y: (leftCorners.minX.y + leftCorners.maxX.y) * 0.5)
            let rightCenter = CGPoint(x: (rightCorners.minX.x + rightCorners.maxX.x) * 0.5,
                                      y: (rightCorners.minX.y + rightCorners.maxX.y) * 0.5)
            let eyeSeparation = rightCenter.x - leftCenter.x
            let fallbackSpacing = confidenceAccepted && !poseAccepted && innerGap > 0.02 &&
                eyeSeparation > 0.04
            if fallbackSpacing { fallbackSpacingCount += 1 }
            let usedImagePoseFallback = fallbackSpacing &&
                abs(rightCenter.y - leftCenter.y) < eyeSeparation * 0.25
            if usedImagePoseFallback { fallbackLevelCount += 1 }
            guard poseUsable || usedImagePoseFallback else { return nil }
            eyeContourCount += 1
            if crest.count >= 2 || nose.count >= 3 { noseContourCount += 1 }
            guard innerGap > 0.02 else { return nil }
            let rawEyeY = (leftCorners.minX.y + leftCorners.maxX.y +
                           rightCorners.minX.y + rightCorners.maxX.y) * 0.25
            let browYs = ((auxiliaryContours[.leftBrow] ?? []) +
                          (auxiliaryContours[.rightBrow] ?? [])).map(\.y).sorted()
            let eyeCorrection: CGFloat
            if browYs.count >= 6 {
                let browY = browYs[browYs.count / 2]
                let browGap = rawEyeY - browY
                // Correct only implausibly low canthi, and cap the shift to preserve anatomy.
                eyeCorrection = browGap < eyeSeparation * 0.40
                    ? min(max(0, browGap - eyeSeparation * 0.22), eyeSeparation * 0.09)
                    : 0
            } else {
                eyeCorrection = 0
            }
            let eyeMidline = (leftCorners.maxX.x + rightCorners.minX.x) * 0.5
            let outlineMidline = nose.isEmpty ? eyeMidline : (nose.map(\.x).min()! + nose.map(\.x).max()!) * 0.5
            let noseAxisX = (eyeMidline + outlineMidline) * 0.5
            let eyeY = rawEyeY - eyeCorrection
            let top: CGFloat
            let bottom: CGFloat
            if let crestBottom = crest.map(\.y).max() {
                let outlineTop = nose.map(\.y).min() ?? (crestBottom - innerGap * 0.32)
                let outlineBottom = nose.map(\.y).max() ?? (crestBottom + innerGap * 0.08)
                top = max(outlineTop, crestBottom - innerGap * 0.32)
                bottom = min(max(outlineBottom, crestBottom), crestBottom + innerGap * 0.08)
            } else {
                // A truncated lower face can leave Vision with eyes but no nose crest.
                // Search a bounded central region; 3D geometry and view agreement still validate it.
                top = max(eyeY + innerGap * 0.25,
                          (nose.map(\.y).min() ?? (eyeY + innerGap * 0.43)) - innerGap * 0.18)
                bottom = nose.map(\.y).max() ?? (eyeY + innerGap * 1.6)
            }
            let radius = max(0.018, min(0.05, innerGap * 0.23))
            let clippedTop = max(0.01, top), clippedBottom = min(0.99, bottom)
            let legacyNoseValid = clippedTop < clippedBottom &&
                noseAxisX - radius > 0 && noseAxisX + radius < 1
            let fallbackTop = max(0.01, eyeY + eyeSeparation * 0.38)
            let fallbackBottom = min(0.99, eyeY + eyeSeparation * 0.80)
            // The pose-fallback nose search must not mistake the bridge for the tip.
            let fallbackNoseSearchRect: CGRect? = usedImagePoseFallback &&
                fallbackTop < fallbackBottom && eyeMidline - radius > 0 && eyeMidline + radius < 1
                ? CGRect(x: eyeMidline - radius, y: fallbackTop,
                         width: radius * 2, height: fallbackBottom - fallbackTop)
                : nil
            guard legacyNoseValid || fallbackNoseSearchRect != nil else { return nil }
            let bridgeY = eyeY + eyeSeparation * 0.18
            let medianLine = auxiliaryContours[.midline] ?? []
            let fallbackNoseBridge: CGPoint?
            if let closest = medianLine.min(by: { abs($0.y - bridgeY) < abs($1.y - bridgeY) }),
               abs(closest.y - bridgeY) < eyeSeparation * 0.18 {
                fallbackNoseBridge = CGPoint(x: eyeMidline, y: closest.y)
            } else {
                fallbackNoseBridge = nil
            }
            var values: [HeadLandmarkID: CGPoint] = [
                .leftEyeMinX: CGPoint(x: leftCorners.minX.x, y: leftCorners.minX.y - eyeCorrection),
                .leftEyeMaxX: CGPoint(x: leftCorners.maxX.x, y: leftCorners.maxX.y - eyeCorrection),
                .rightEyeMinX: CGPoint(x: rightCorners.minX.x, y: rightCorners.minX.y - eyeCorrection),
                .rightEyeMaxX: CGPoint(x: rightCorners.maxX.x, y: rightCorners.maxX.y - eyeCorrection)]
            if let bridge = crest.min(by: { $0.y < $1.y }) {
                values[.noseBridge] = CGPoint(x: (bridge.x + eyeMidline) * 0.5, y: bridge.y)
            }
            guard values.values.allSatisfy({ $0.x > 0 && $0.x < 1 && $0.y > 0 && $0.y < 1 }) else { return nil }
            return HeadImageLandmarks(points: values, auxiliaryContours: auxiliaryContours,
                noseSearchRect: legacyNoseValid
                    ? CGRect(x: noseAxisX - radius, y: clippedTop,
                             width: radius * 2, height: clippedBottom - clippedTop)
                    : .zero,
                noseAxisX: noseAxisX, fallbackNoseSearchRect: fallbackNoseSearchRect,
                fallbackNoseBridge: fallbackNoseBridge, fallbackNoseAxisX: eyeMidline,
                hasObservedNose: crest.count >= 2 || nose.count >= 3,
                confidence: face.confidence, usedImagePoseFallback: usedImagePoseFallback)
        }
        return HeadFaceLandmarkDetection(landmarks: landmarks, contourCandidates: contourCandidates,
                                         faceCount: observations.count,
                                         rawEyeContourCount: rawEyeContourCount,
                                         confidentEyeContourCount: confidentEyeContourCount,
                                         acceptablePoseEyeContourCount: acceptablePoseEyeContourCount,
                                         reorderedEyeContourCount: reorderedEyeContourCount,
                                         fallbackSpacingCount: fallbackSpacingCount,
                                         fallbackLevelCount: fallbackLevelCount,
                                         bestEyeConfidence: bestEyeConfidence,
                                         bestEyePoseMagnitude: bestEyePoseMagnitude,
                                         eyeContourCount: eyeContourCount, noseContourCount: noseContourCount)
    }
}

struct HeadSurfaceRenderView {
    let matrix: simd_float4x4
    let towardCamera: SIMD3<Float>
    let up: SIMD3<Float>

    init(minimum: SIMD3<Float>, maximum: SIMD3<Float>, direction: SIMD3<Float>, up: SIMD3<Float>,
         verticalFocus: Float = 0, magnification: Float = 1) {
        let d = simd_normalize(direction), right = simd_normalize(simd_cross(up, d))
        let u = simd_normalize(simd_cross(d, right))
        let extent = (maximum - minimum) * 0.5
        let halfWidth = simd_dot(simd_abs(right), extent), halfHeight = simd_dot(simd_abs(u), extent)
        let center = (minimum + maximum) * 0.5 + u * halfHeight * verticalFocus
        let scale = 0.90 * magnification / max(0.001, max(halfWidth, halfHeight))
        let depthScale = 0.45 / max(0.001, simd_dot(simd_abs(d), extent))
        matrix = simd_float4x4(columns: (
            SIMD4(right.x * scale, u.x * scale, -d.x * depthScale, 0),
            SIMD4(right.y * scale, u.y * scale, -d.y * depthScale, 0),
            SIMD4(right.z * scale, u.z * scale, -d.z * depthScale, 0),
            SIMD4(-simd_dot(right, center) * scale, -simd_dot(u, center) * scale,
                  0.5 + simd_dot(d, center) * depthScale, 1)))
        towardCamera = d
        self.up = u
    }
}

struct HeadSurfaceLandmarkImage {
    let image: CGImage
    let pixels: Data // BGRA shading used only for unconfirmed surface proposals.
    let positions: [SIMD4<Float>]
    let size: Int

    func eyeSeamProposal(contours: [HeadAuxiliaryContourKind: [CGPoint]],
                         towardCamera: SIMD3<Float>) -> [SIMD3<Float>] {
        var proposed: [SIMD3<Float>] = []
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func brightness(_ pixel: SIMD2<Float>) -> Float? {
                let x = Int(pixel.x.rounded()), y = Int(pixel.y.rounded())
                guard x >= 1, y >= 1, x < size - 1, y < size - 1 else { return nil }
                let i = (y * size + x) * 4
                return 0.114 * Float(bytes[i]) + 0.587 * Float(bytes[i + 1]) +
                    0.299 * Float(bytes[i + 2])
            }
            func imagePoint(_ point: CGPoint) -> SIMD2<Float> {
                SIMD2(Float(point.x) * Float(size), Float(point.y) * Float(size))
            }
            for (eyeKind, browKind) in [
                (HeadAuxiliaryContourKind.visionLeftEye, HeadAuxiliaryContourKind.leftBrow),
                (.visionRightEye, .rightBrow)
            ] {
                guard let eye = contours[eyeKind], eye.count >= 4,
                      let brow = contours[browKind], brow.count >= 3 else { continue }
                let eyePixels = eye.map(imagePoint), browPixels = brow.map(imagePoint)
                let eyeCenter = eyePixels.reduce(SIMD2<Float>.zero, +) / Float(eyePixels.count)
                let browCenter = browPixels.reduce(SIMD2<Float>.zero, +) / Float(browPixels.count)
                let browToEye = eyeCenter - browCenter
                let gap = simd_length(browToEye)
                guard gap >= 7 else { continue }
                let down = browToEye / gap
                var endpoints = (eyePixels[0], eyePixels[1])
                var width = simd_distance(endpoints.0, endpoints.1)
                for i in eyePixels.indices {
                    for j in eyePixels.indices where j > i {
                        let distance = simd_distance(eyePixels[i], eyePixels[j])
                        if distance > width {
                            width = distance
                            endpoints = (eyePixels[i], eyePixels[j])
                        }
                    }
                }
                guard width >= 12 else { continue }
                let rawAcross = (endpoints.1 - endpoints.0) / width
                let acrossComponent = rawAcross - down * simd_dot(rawAcross, down)
                guard simd_length(acrossComponent) > 0.5 else { continue }
                let across = simd_normalize(acrossComponent)
                let first = Int(gap * 0.30)
                let last = Int(gap - max(2, width * 0.04))
                guard first < last else { continue }
                for step in 1...7 {
                    let side = Float(step - 4) * width / 8
                    var best: (point: SIMD3<Float>, score: Float)?
                    for offset in first...last {
                        let imageLocation = browCenter + down * Float(offset) + across * side
                        let x = Int(imageLocation.x.rounded()), y = Int(imageLocation.y.rounded())
                        guard x >= 6, y >= 6, x < size - 6, y < size - 6 else { continue }
                        let sample = positions[y * size + x]
                        guard sample.w > 0.5 else { continue }
                        let point = SIMD3(sample.x, sample.y, sample.z)
                        var support = 0
                        for ny in (y - 1)...(y + 1) {
                            for nx in (x - 1)...(x + 1) {
                                let neighbor = positions[ny * size + nx]
                                if neighbor.w > 0.5,
                                   simd_distance(point, SIMD3(neighbor.x, neighbor.y, neighbor.z)) < 0.005 {
                                    support += 1
                                }
                            }
                        }
                        guard support >= 5 else { continue }
                        guard let center = brightness(imageLocation),
                              let above = brightness(imageLocation - down * 4),
                              let below = brightness(imageLocation + down * 4) else { continue }
                        // Shading can be almost flat on a CT skin mesh. Also seek a
                        // small 3D recess between supported pixels above and below.
                        var recess: Float = 0
                        let upperLocation = imageLocation - down * 4
                        let lowerLocation = imageLocation + down * 4
                        let upper = positions[Int(upperLocation.y.rounded()) * size + Int(upperLocation.x.rounded())]
                        let lower = positions[Int(lowerLocation.y.rounded()) * size + Int(lowerLocation.x.rounded())]
                        if upper.w > 0.5, lower.w > 0.5 {
                            let upperPoint = SIMD3(upper.x, upper.y, upper.z)
                            let lowerPoint = SIMD3(lower.x, lower.y, lower.z)
                            if simd_distance(point, upperPoint) < 0.015,
                               simd_distance(point, lowerPoint) < 0.015 {
                                recess = (simd_dot(upperPoint, towardCamera) +
                                          simd_dot(lowerPoint, towardCamera)) * 0.5 -
                                         simd_dot(point, towardCamera)
                            }
                        }
                        // Both channels are proposals, never a fixed shift of Vision's contour.
                        let score = max(min(above - center, below - center), recess * 4000)
                        if score > 1, (best == nil || score > best!.score) {
                            best = (point, score)
                        }
                    }
                    if let best { proposed.append(best.point) }
                }
            }
        }
        return proposed
    }

    func noseApexProposal(mapped: [HeadAuxiliaryContourKind: [SIMD3<Float>]],
                          patientSuperior: SIMD3<Float>, patientAnterior: SIMD3<Float>) -> SIMD3<Float>? {
        guard let left = mapped[.leftBrow], left.count >= 3,
              let right = mapped[.rightBrow], right.count >= 3 else { return nil }
        let browCenter = (left + right).reduce(SIMD3<Float>.zero, +) / Float(left.count + right.count)
        let lateral = simd_normalize(simd_cross(patientSuperior, patientAnterior))
        var best: (point: SIMD3<Float>, score: Float)?
        // Search in patient coordinates so a rolled Vision view cannot move the ROI off the nose.
        for y in stride(from: 2, to: size - 2, by: 2) {
            for x in stride(from: 2, to: size - 2, by: 2) {
                let sample = positions[y * size + x]
                guard sample.w > 0.5 else { continue }
                let point = SIMD3(sample.x, sample.y, sample.z)
                let relative = point - browCenter
                let drop = -simd_dot(relative, patientSuperior)
                let offAxis = abs(simd_dot(relative, lateral))
                let forward = simd_dot(relative, patientAnterior)
                guard (0.025...0.080).contains(drop), offAxis < 0.010,
                      (0.005...0.090).contains(forward) else { continue }
                var support = 0
                for ny in (y - 1)...(y + 1) {
                    for nx in (x - 1)...(x + 1) {
                        let neighbor = positions[ny * size + nx]
                        if neighbor.w > 0.5,
                           simd_distance(point, SIMD3(neighbor.x, neighbor.y, neighbor.z)) < 0.005 {
                            support += 1
                        }
                    }
                }
                guard support >= 6 else { continue }
                let score = forward - 0.5 * offAxis - 0.15 * abs(drop - 0.055)
                if best == nil || score > best!.score { best = (point, score) }
            }
        }
        return best?.point
    }

    func point(at uv: CGPoint) -> SIMD3<Float>? {
        guard uv.x.isFinite, uv.y.isFinite, uv.x > 0, uv.x < 1, uv.y > 0, uv.y < 1 else { return nil }
        let x = Int(uv.x * CGFloat(size)), y = Int(uv.y * CGFloat(size))
        guard x >= 6, y >= 6, x < size - 6, y < size - 6 else { return nil }
        var nearest: (point: SIMD3<Float>, distanceSquared: Int)?
        // Eye corners can land in a small opening in the skin mesh. Keep the
        // search local and require 3D support before snapping to visible skin.
        for yy in (y - 5)...(y + 5) {
            for xx in (x - 5)...(x + 5) {
                let sample = positions[yy * size + xx]
                guard sample.w > 0.5 else { continue }
                let point = SIMD3(sample.x, sample.y, sample.z)
                var support = 0
                for ny in (yy - 1)...(yy + 1) {
                    for nx in (xx - 1)...(xx + 1) {
                        let neighbor = positions[ny * size + nx]
                        if neighbor.w > 0.5,
                           simd_distance(point, SIMD3(neighbor.x, neighbor.y, neighbor.z)) < 0.010 {
                            support += 1
                        }
                    }
                }
                guard support >= 4 else { continue }
                let distanceSquared = (xx - x) * (xx - x) + (yy - y) * (yy - y)
                if nearest == nil || distanceSquared < nearest!.distanceSquared {
                    nearest = (point, distanceSquared)
                }
            }
        }
        return nearest?.point
    }

    func noseTip(in region: CGRect, axisX: CGFloat, towardCamera: SIMD3<Float>) -> SIMD3<Float>? {
        guard region.width > 0, region.height > 0 else { return nil }
        let minX = max(4, Int(region.minX * CGFloat(size)))
        let maxX = min(size - 5, Int(region.maxX * CGFloat(size)))
        let minY = max(4, Int(region.minY * CGFloat(size)))
        let maxY = min(size - 5, Int(region.maxY * CGFloat(size)))
        guard minX <= maxX, minY <= maxY else { return nil }
        let axisPixel = axisX * CGFloat(size)
        let radiusPixels = max(region.width * CGFloat(size) * 0.5, 1)
        var best: (point: SIMD3<Float>, score: Float)?
        for y in minY...maxY {
            for x in minX...maxX {
                let sample = positions[y * size + x]
                guard sample.w > 0.5 else { continue }
                let position = SIMD3(sample.x, sample.y, sample.z)
                var depths: [Float] = []
                for ny in (y - 1)...(y + 1) {
                    for nx in (x - 1)...(x + 1) {
                        let nearby = positions[ny * size + nx]
                        guard nearby.w > 0.5 else { continue }
                        let neighbor = SIMD3(nearby.x, nearby.y, nearby.z)
                        if simd_distance(position, neighbor) < 0.004 {
                            depths.append(simd_dot(neighbor, towardCamera))
                        }
                    }
                }
                guard depths.count >= 5 else { continue }
                depths.sort()
                let medianDepth = depths[depths.count / 2]
                guard abs(simd_dot(position, towardCamera) - medianDepth) < 0.003 else { continue }
                // The nasal apex should project forward near the facial midline, not at an alar rim.
                let offAxis = Float(abs(CGFloat(x) - axisPixel) / radiusPixels)
                let score = medianDepth - 0.004 * offAxis * offAxis
                if best == nil || score > best!.score { best = (position, score) }
            }
        }
        return best?.point
    }

    func anatomicalNoseTip(eyes: [HeadLandmarkID: SIMD3<Float>],
                           patientSuperior: SIMD3<Float>,
                           towardCamera: SIMD3<Float>) -> SIMD3<Float>? {
        guard let a = eyes[.leftEyeMinX], let b = eyes[.leftEyeMaxX],
              let c = eyes[.rightEyeMinX], let d = eyes[.rightEyeMaxX] else { return nil }
        let left = (a + b) * 0.5, right = (c + d) * 0.5
        let eyeWidth = simd_distance(left, right)
        guard (0.035...0.095).contains(eyeWidth) else { return nil }
        let eyeMidpoint = (left + right) * 0.5
        let lateral = simd_normalize(right - left)
        let minimumDrop = max(0.020, eyeWidth * 0.38)
        let maximumDrop = min(0.090, eyeWidth * 1.25)
        var best: (point: SIMD3<Float>, score: Float)?
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let index = y * size + x
                let sample = positions[index]
                guard sample.w > 0.5 else { continue }
                let point = SIMD3(sample.x, sample.y, sample.z)
                let relative = point - eyeMidpoint
                let drop = -simd_dot(relative, patientSuperior)
                guard (minimumDrop...maximumDrop).contains(drop) else { continue }
                let offAxis = abs(simd_dot(relative, lateral))
                guard offAxis <= 0.012 else { continue }
                let forward = simd_dot(relative, towardCamera)
                guard (0.006...0.060).contains(forward) else { continue }
                var support = 0
                for ny in (y - 1)...(y + 1) {
                    for nx in (x - 1)...(x + 1) {
                        let neighbor = positions[ny * size + nx]
                        if neighbor.w > 0.5,
                           simd_distance(point, SIMD3(neighbor.x, neighbor.y, neighbor.z)) < 0.005 {
                            support += 1
                        }
                    }
                }
                guard support >= 5 else { continue }
                let score = forward - 0.40 * offAxis - 0.15 * abs(drop - eyeWidth * 0.72)
                if best == nil || score > best!.score { best = (point, score) }
            }
        }
        return best?.point
    }
}

struct HeadSurfaceLandmarkSearchReport: Sendable {
    let confirmed: HeadLandmarkSet?
    let provisional: HeadLandmarkSet?
    let provisionalUsesImagePoseFallback: Bool
    let provisionalMethod: String?
    let auxiliaryContours: [HeadAuxiliaryContourKind: [SIMD3<Float>]]
    let viewsRendered: Int
    let visionFaces: Int
    let facesWithRawEyes: Int
    let facesWithConfidentEyes: Int
    let facesWithAcceptableEyePose: Int
    let facesWithReorderedEyes: Int
    let facesWithFallbackSpacing: Int
    let facesWithFallbackLevel: Int
    let bestPairedEyeConfidence: Float?
    let bestPairedEyePoseMagnitude: Float?
    let facesWithEyes: Int
    let facesWithNoseContour: Int
    let imageCandidates: Int
    let mappedCandidates: Int
    let anatomicalCandidates: Int
    let rejectedFallbackViews: Int
    let rejectedNosePositions: Int
    let rejectedLowEyes: Int
    let browToEyeGapMM: Float?
    let noseTipMidlineOffsetMM: Float?
    let noseBridgeMidlineOffsetMM: Float?
    let noseTipToApexMM: Float?
    let surfacePreviewFrontal: Int
    let surfaceSeamFound: Int
    let surfaceApexFound: Int
    let bestFallbackViewAlignment: String?
    let closestViewDisagreement: String?

    var failureSummary: String {
        if visionFaces == 0 { return "Vision saw no face in \(viewsRendered) surface views. Check that the scan includes enough of the nose and eye region before re-detecting." }
        if imageCandidates == 0 && facesWithEyes == 0 {
            if facesWithRawEyes > 0 {
                if facesWithConfidentEyes == 0 && facesWithAcceptableEyePose == 0 {
                    return "Vision found both eye contours, but face confidence and pose both failed their gates."
                }
                if facesWithConfidentEyes == 0 { return "Vision found both eye contours, but face confidence stayed below 0.50." }
                if facesWithAcceptableEyePose == 0 {
                    if facesWithFallbackSpacing == 0 {
                        return "Vision rejected the pose, and the eye contours did not form a separated horizontal pair."
                    }
                    return "Vision rejected the pose; the eye contours were separated but not level in the rendered image."
                }
                return "Vision found both eye contours, but no observation passed confidence and pose together."
            }
            return "Vision saw \(visionFaces) face observations, but returned no eye contours. The rendered face may be incomplete."
        }
        if imageCandidates == 0 {
            return "Vision found eye contours in \(facesWithEyes) views and nose contours in \(facesWithNoseContour), but no usable central nose region."
        }
        if mappedCandidates == 0 {
            if rejectedFallbackViews > 0 {
                return "Vision pose fallback was seen only from a non-frontal patient view."
            }
            return "Vision found \(imageCandidates) facial feature sets, but their eye/nose points did not map to nearby outer skin."
        }
        if anatomicalCandidates == 0 {
            if rejectedLowEyes > 0 {
                return "Vision eye corners mapped too far below the brows in patient coordinates."
            }
            if rejectedNosePositions > 0 {
                return "Facial points mapped to skin, but the nose was not below the eyes in patient coordinates."
            }
            if rejectedFallbackViews > 0 {
                return "Vision pose fallback was seen only from a non-frontal patient view."
            }
            return "Facial points mapped to skin, but failed the eye spacing or nose geometry checks."
        }
        if provisionalMethod == "patient-axis 3D nose (unconfirmed)" {
            return "The nose tip was estimated from the 3D skin surface; review these unconfirmed points before use."
        }
        if provisionalUsesImagePoseFallback {
            return "Vision pose fallback (\(provisionalMethod ?? "unrefined")); points remain unconfirmed for review."
        }
        if provisional?.hasObservedNose == false {
            return "Nose contours were absent; estimated landmarks remain unconfirmed."
        }
        let detail = closestViewDisagreement.map { "Closest alternate: \($0)." } ?? "No second usable view."
        return "Nearby views disagree. \(detail)"
    }
}

private func faceOffBrowToEyeGap(
    points: [HeadLandmarkID: SIMD3<Float>],
    contours: [HeadAuxiliaryContourKind: [SIMD3<Float>]],
    patientSuperior: SIMD3<Float>, patientAnterior: SIMD3<Float>
) -> Float? {
    guard let a = points[.leftEyeMinX], let b = points[.leftEyeMaxX],
          let c = points[.rightEyeMinX], let d = points[.rightEyeMaxX] else { return nil }
    let lateral = simd_normalize(simd_cross(patientSuperior, patientAnterior))
    var brows: [(lateral: Float, height: Float)] = []
    for kind in [HeadAuxiliaryContourKind.leftBrow, .rightBrow] {
        guard let contour = contours[kind], contour.count >= 3 else { return nil }
        let heights = contour.map { simd_dot($0, patientSuperior) }.sorted()
        let center = contour.reduce(SIMD3<Float>.zero, +) / Float(contour.count)
        brows.append((simd_dot(center, lateral), heights[heights.count / 2]))
    }
    brows.sort { $0.lateral < $1.lateral }
    let eyes = [(a + b) * 0.5, (c + d) * 0.5].sorted {
        simd_dot($0, lateral) < simd_dot($1, lateral)
    }
    guard zip(brows, eyes).allSatisfy({ abs($0.lateral - simd_dot($1, lateral)) < 0.035 }) else {
        return nil
    }
    return zip(brows, eyes).map { $0.height - simd_dot($1, patientSuperior) }.max()
}

private func faceOffNoseMidlineOffsets(
    points: [HeadLandmarkID: SIMD3<Float>],
    contours: [HeadAuxiliaryContourKind: [SIMD3<Float>]],
    patientSuperior: SIMD3<Float>, patientAnterior: SIMD3<Float>
) -> (tip: Float?, bridge: Float?) {
    guard let left = contours[.leftBrow], left.count >= 3,
          let right = contours[.rightBrow], right.count >= 3 else { return (nil, nil) }
    let lateralAxis = simd_cross(patientSuperior, patientAnterior)
    guard simd_length(lateralAxis) > 0.5 else { return (nil, nil) }
    let lateral = simd_normalize(lateralAxis)
    let browCenter = (left + right).reduce(SIMD3<Float>.zero, +) / Float(left.count + right.count)
    return (points[.noseTip].map { simd_dot($0 - browCenter, lateral) * 1000 },
            points[.noseBridge].map { simd_dot($0 - browCenter, lateral) * 1000 })
}

private struct HeadSurfaceLandmarkObservation {
    let landmarks: HeadLandmarkSet
    let auxiliaryContours: [HeadAuxiliaryContourKind: [SIMD3<Float>]]
    let usedImagePoseFallback: Bool
}

// One worker owns its GPU resources. Cancellation closes the submission gate and
// drains the current command before the app backgrounds; no camera buffers are held.
final class HeadSurfaceLandmarkRenderer: @unchecked Sendable {
    private let vertices: [SIMD3<Float>]
    private let indices: [UInt32]
    private let lock = NSLock()
    private var stopped = false
    private var inFlight: MTLCommandBuffer?
    private var inFlightVision: VNRequest?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var color: MTLTexture?
    private var points: MTLTexture?
    private var depth: MTLTexture?
    private let size = 640

    init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        self.vertices = vertices; self.indices = indices
    }

    func stop() {
        lock.lock()
        stopped = true
        let pending = inFlight
        let vision = inFlightVision
        lock.unlock()
        vision?.cancel()
        pending?.waitUntilCompleted()
    }

    private func checkCancellation() throws {
        lock.lock(); let cancelled = stopped; lock.unlock()
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func prepare() throws {
        try checkCancellation()
        if device != nil { return }
        guard !vertices.isEmpty, !indices.isEmpty, indices.count.isMultiple(of: 3),
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              indices.allSatisfy({ Int($0) < vertices.count }), let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RendererError.unavailable }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "landmarkVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "landmarkFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[1].pixelFormat = .rgba32Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)
        vertexBuffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        indexBuffer = indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        func texture(_ format: MTLPixelFormat, storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            d.storageMode = storage; d.usage = .renderTarget
            return device.makeTexture(descriptor: d)
        }
        color = texture(.bgra8Unorm, storage: .shared)
        points = texture(.rgba32Float, storage: .shared)
        depth = texture(.depth32Float, storage: .private)
        self.device = device; self.queue = queue
    }

    func render(_ view: HeadSurfaceRenderView, lightSide: Float = 0) throws -> HeadSurfaceLandmarkImage {
        try prepare()
        try checkCancellation()
        guard let queue, let pipeline, let depthState, let vertexBuffer, let indexBuffer,
              let color, let points, let depth, let command = queue.makeCommandBuffer() else { throw RendererError.unavailable }
        let pass = MTLRenderPassDescriptor()
        for (i, texture) in [color, points].enumerated() {
            pass.colorAttachments[i].texture = texture
            pass.colorAttachments[i].loadAction = .clear; pass.colorAttachments[i].storeAction = .store
        }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth; pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.unavailable }
        struct Uniforms { var matrix: simd_float4x4; var light: SIMD4<Float> }
        let right = simd_normalize(simd_cross(view.up, view.towardCamera))
        let light = simd_normalize(view.towardCamera + view.up * 0.4 + right * lightSide)
        var uniforms = Uniforms(matrix: view.matrix, light: SIMD4(light, 0))
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.count, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
        lock.lock()
        if stopped { lock.unlock(); throw CancellationError() }
        inFlight = command
        command.commit()
        lock.unlock()
        command.waitUntilCompleted()
        lock.lock(); inFlight = nil; lock.unlock()
        try checkCancellation()
        guard command.status == .completed else { throw RendererError.unavailable }
        var pixels = Data(count: size * size * 4)
        pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: size * 4,
            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        var positions = Array(repeating: SIMD4<Float>.zero, count: size * size)
        positions.withUnsafeMutableBytes { points.getBytes($0.baseAddress!, bytesPerRow: size * 16,
            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RendererError.unavailable }
        return HeadSurfaceLandmarkImage(image: image, pixels: pixels, positions: positions, size: size)
    }

    func findLandmarks(preferredDirection: SIMD3<Float>? = nil,
                       preferredUp: SIMD3<Float>? = nil) throws -> HeadSurfaceLandmarkSearchReport {
        guard let first = vertices.first else { throw RendererError.unavailable }
        let minimum = vertices.reduce(first, simd_min), maximum = vertices.reduce(first, simd_max)
        var viewsRendered = 0
        var visionFaces = 0
        var facesWithRawEyes = 0
        var facesWithConfidentEyes = 0
        var facesWithAcceptableEyePose = 0
        var facesWithReorderedEyes = 0
        var facesWithFallbackSpacing = 0
        var facesWithFallbackLevel = 0
        var bestPairedEyeConfidence: Float?
        var bestPairedEyePoseMagnitude: Float?
        var facesWithEyes = 0
        var facesWithNoseContour = 0
        var imageCandidates = 0
        var mappedCandidates = 0
        var anatomicalCandidates = 0
        var rejectedFallbackViews = 0
        var rejectedNosePositions = 0
        var rejectedLowEyes = 0
        var surfacePreviewFrontal = 0
        var surfaceSeamFound = 0
        var surfaceApexFound = 0
        var bestFallbackFront = -Float.infinity
        var bestFallbackUp = -Float.infinity
        var provisional: HeadLandmarkSet?
        var provisionalScore = -Float.infinity
        var provisionalUsesImagePoseFallback = false
        var provisionalMethod: String?
        var provisionalAuxiliary: [HeadAuxiliaryContourKind: [SIMD3<Float>]] = [:]
        var diagnosticAuxiliary: [HeadAuxiliaryContourKind: [SIMD3<Float>]] = [:]
        var diagnosticScore = -Float.infinity
        var confirmedAuxiliary: [HeadAuxiliaryContourKind: [SIMD3<Float>]] = [:]
        var bestSurfaceSeam: [SIMD3<Float>] = []
        var bestSurfaceSeamScore = -Float.infinity
        var bestSurfaceApex: SIMD3<Float>?
        var bestSurfaceApexScore = -Float.infinity
        var smallestViewMismatch = Float.infinity
        var closestViewDisagreement: String?
        let preferredUnit: SIMD3<Float>? = preferredDirection.flatMap {
            simd_length($0) > 0.5 ? simd_normalize($0) : nil
        }
        let patientSuperior: SIMD3<Float>? = preferredUp.flatMap {
            simd_length($0) > 0.5 ? simd_normalize($0) : nil
        }
        func observation(_ view: HeadSurfaceRenderView,
                         allowLegacyWithoutFace: Bool = false,
                         lightSide: Float = 0) throws -> HeadSurfaceLandmarkObservation? {
            try checkCancellation()
            let rendered = try render(view, lightSide: lightSide)
            viewsRendered += 1
            defer { lock.lock(); inFlightVision = nil; lock.unlock() }
            var viewFaceCount = 0
            var viewRawEyeCount = 0
            var viewConfidentEyeCount = 0
            var viewAcceptablePoseEyeCount = 0
            var viewReorderedEyeCount = 0
            var viewFallbackSpacingCount = 0
            var viewFallbackLevelCount = 0
            var viewBestEyeConfidence: Float?
            var viewBestEyePoseMagnitude: Float?
            var viewEyeCount = 0
            var viewNoseCount = 0
            var faces: [HeadImageLandmarks] = []
            var contourCandidates: [HeadImageAuxiliaryContourCandidate] = []
            // Revision 2 can return eye outlines on a face whose lower
            // extent was cut by the scan, even when revision 3 returns no landmarks.
            for revision in [VNDetectFaceLandmarksRequestRevision3,
                             VNDetectFaceLandmarksRequestRevision2] {
                try checkCancellation()
                let request = VNDetectFaceLandmarksRequest()
                lock.lock()
                if stopped { lock.unlock(); throw CancellationError() }
                inFlightVision = request
                lock.unlock()
                let detection: HeadFaceLandmarkDetection
                if revision == VNDetectFaceLandmarksRequestRevision3 {
                    detection = try HeadFaceLandmarkDetector.detect(image: rendered.image,
                                                                    request: request, revision: revision)
                } else {
                    guard let fallback = try? HeadFaceLandmarkDetector.detect(image: rendered.image,
                        request: request, revision: revision) else { continue }
                    detection = fallback
                }
                viewFaceCount = max(viewFaceCount, detection.faceCount)
                viewRawEyeCount = max(viewRawEyeCount, detection.rawEyeContourCount)
                viewConfidentEyeCount = max(viewConfidentEyeCount, detection.confidentEyeContourCount)
                viewAcceptablePoseEyeCount = max(viewAcceptablePoseEyeCount, detection.acceptablePoseEyeContourCount)
                viewReorderedEyeCount = max(viewReorderedEyeCount, detection.reorderedEyeContourCount)
                viewFallbackSpacingCount = max(viewFallbackSpacingCount, detection.fallbackSpacingCount)
                viewFallbackLevelCount = max(viewFallbackLevelCount, detection.fallbackLevelCount)
                if let confidence = detection.bestEyeConfidence {
                    viewBestEyeConfidence = max(viewBestEyeConfidence ?? confidence, confidence)
                }
                if let pose = detection.bestEyePoseMagnitude {
                    viewBestEyePoseMagnitude = min(viewBestEyePoseMagnitude ?? pose, pose)
                }
                viewEyeCount = max(viewEyeCount, detection.eyeContourCount)
                viewNoseCount = max(viewNoseCount, detection.noseContourCount)
                faces = detection.landmarks
                contourCandidates.append(contentsOf: detection.contourCandidates)
                if !faces.isEmpty ||
                   (revision == VNDetectFaceLandmarksRequestRevision3 && detection.faceCount == 0 && !allowLegacyWithoutFace) {
                    break
                }
            }
            visionFaces += viewFaceCount
            facesWithRawEyes += viewRawEyeCount
            facesWithConfidentEyes += viewConfidentEyeCount
            facesWithAcceptableEyePose += viewAcceptablePoseEyeCount
            facesWithReorderedEyes += viewReorderedEyeCount
            facesWithFallbackSpacing += viewFallbackSpacingCount
            facesWithFallbackLevel += viewFallbackLevelCount
            if let confidence = viewBestEyeConfidence {
                bestPairedEyeConfidence = max(bestPairedEyeConfidence ?? confidence, confidence)
            }
            if let pose = viewBestEyePoseMagnitude {
                bestPairedEyePoseMagnitude = min(bestPairedEyePoseMagnitude ?? pose, pose)
            }
            facesWithEyes += viewEyeCount
            facesWithNoseContour += viewNoseCount
            imageCandidates += faces.count
            try checkCancellation()
            let frontAlignment = preferredUnit.map { max(simd_dot(view.towardCamera, $0), 0) } ?? 0
            func recordSurfaceProposals(
                _ mapped: [HeadAuxiliaryContourKind: [SIMD3<Float>]],
                contours: [HeadAuxiliaryContourKind: [CGPoint]], confidence: Float
            ) {
                guard let patientSuperior, let preferredUnit, frontAlignment >= 0.75 else { return }
                surfacePreviewFrontal += 1
                let seam = rendered.eyeSeamProposal(contours: contours,
                                                     towardCamera: view.towardCamera)
                let seamScore = Float(seam.count) * 0.05 + confidence + 0.35 * frontAlignment
                if !seam.isEmpty, seamScore > bestSurfaceSeamScore {
                    bestSurfaceSeam = seam
                    bestSurfaceSeamScore = seamScore
                }
                if !seam.isEmpty { surfaceSeamFound += 1 }
                if let apex = rendered.noseApexProposal(mapped: mapped,
                    patientSuperior: patientSuperior, patientAnterior: preferredUnit) {
                    surfaceApexFound += 1
                    let apexScore = confidence + 0.35 * frontAlignment
                    if apexScore > bestSurfaceApexScore {
                        bestSurfaceApex = apex
                        bestSurfaceApexScore = apexScore
                    }
                }
            }
            for candidate in contourCandidates {
                if preferredUnit != nil && frontAlignment < 0.75 {
                    continue
                }
                let rawMapped = candidate.contours.mapValues { contour in
                    contour.compactMap { rendered.point(at: $0) }
                }.filter { !$0.value.isEmpty }
                recordSurfaceProposals(rawMapped, contours: candidate.contours,
                                       confidence: candidate.confidence)
                let mapped = rawMapped
                let mappedCount = mapped.values.reduce(0) { $0 + $1.count }
                let score = candidate.confidence + 0.35 * frontAlignment + Float(min(mappedCount, 40)) * 0.002
                if mappedCount >= 4 && score > diagnosticScore {
                    diagnosticAuxiliary = mapped
                    diagnosticScore = score
                }
            }
            for face in faces.sorted(by: { $0.confidence > $1.confidence }) {
                // A roll changes image-space eye ordering, not patient anatomy. Reject
                // a view from the wrong side, but validate roll in 3D below.
                if face.usedImagePoseFallback {
                    if frontAlignment > bestFallbackFront {
                        bestFallbackFront = frontAlignment
                        bestFallbackUp = patientSuperior.map { simd_dot(view.up, $0) } ?? .nan
                    }
                    guard patientSuperior != nil, preferredUnit != nil,
                          frontAlignment >= 0.75 else {
                        rejectedFallbackViews += 1
                        continue
                    }
                }
                var values = face.points.compactMapValues { rendered.point(at: $0) }
                let rawAuxiliary = face.auxiliaryContours.mapValues { contour in
                    contour.compactMap { rendered.point(at: $0) }
                }.filter { !$0.value.isEmpty }
                recordSurfaceProposals(rawAuxiliary, contours: face.auxiliaryContours,
                                       confidence: face.confidence)
                let auxiliary = rawAuxiliary
                values[.noseTip] = rendered.noseTip(in: face.noseSearchRect,
                    axisX: face.noseAxisX, towardCamera: view.towardCamera)
                let invertedNose = face.usedImagePoseFallback &&
                    values[.noseTip] != nil && values[.noseBridge] != nil &&
                    simd_dot(values[.noseBridge]! - values[.noseTip]!, patientSuperior ?? view.up) < -0.008
                func noseOrdered(_ points: [HeadLandmarkID: SIMD3<Float>]) -> [HeadLandmarkID: SIMD3<Float>] {
                    guard invertedNose else { return points }
                    var ordered = points
                    ordered[.noseTip] = points[.noseBridge]
                    ordered[.noseBridge] = points[.noseTip]
                    return ordered
                }
                var candidates: [(points: [HeadLandmarkID: SIMD3<Float>], method: String,
                                  refinedNose: Bool)] = []
                if let region = face.fallbackNoseSearchRect {
                    var refined = values
                    refined[.noseTip] = rendered.noseTip(in: region,
                        axisX: face.fallbackNoseAxisX, towardCamera: view.towardCamera)
                    refined[.noseBridge] = face.fallbackNoseBridge.flatMap { rendered.point(at: $0) }
                    candidates.append((refined, "midline nose, brow-constrained eyes", true))
                }
                candidates.append((noseOrdered(values), face.usedImagePoseFallback
                    ? "Vision nose, brow-constrained eyes" : "Vision landmarks", false))
                if invertedNose { candidates.append((values, "unrefined Vision nose", false)) }
                let geometricNoseMethod = "patient-axis 3D nose (unconfirmed)"
                var countedMapped = candidates.contains(where: { $0.points[.noseTip] != nil && $0.points.count >= 5 })
                if countedMapped {
                    mappedCandidates += 1
                }
                func assess(_ candidate: (points: [HeadLandmarkID: SIMD3<Float>], method: String,
                                          refinedNose: Bool)) -> HeadSurfaceLandmarkObservation? {
                    var points = candidate.points
                    if let patientSuperior, let preferredUnit,
                       let a = points[.leftEyeMinX], let b = points[.leftEyeMaxX],
                       let c = points[.rightEyeMinX], let d = points[.rightEyeMaxX] {
                        let patientImageRight = simd_normalize(simd_cross(patientSuperior, preferredUnit))
                        var first = [a, b].sorted { simd_dot($0, patientImageRight) < simd_dot($1, patientImageRight) }
                        var second = [c, d].sorted { simd_dot($0, patientImageRight) < simd_dot($1, patientImageRight) }
                        if simd_dot(first[0] + first[1], patientImageRight) >
                           simd_dot(second[0] + second[1], patientImageRight) {
                            swap(&first, &second)
                        }
                        let firstCenter = (first[0] + first[1]) * 0.5
                        let secondCenter = (second[0] + second[1]) * 0.5
                        guard abs(simd_dot(secondCenter - firstCenter, patientSuperior)) < 0.015 else { return nil }
                        points[.leftEyeMinX] = first[0]
                        points[.leftEyeMaxX] = first[1]
                        points[.rightEyeMinX] = second[0]
                        points[.rightEyeMaxX] = second[1]
                    }
                    if let patientSuperior, let tip = points[.noseTip], let bridge = points[.noseBridge],
                       simd_dot(bridge - tip, patientSuperior) < 0.008 {
                        points.removeValue(forKey: .noseBridge)
                    }
                    let result = HeadLandmarkSet(points: points, towardCamera: view.towardCamera,
                                                 confidence: face.confidence,
                                                 hasObservedNose: face.hasObservedNose &&
                                                     candidate.method != geometricNoseMethod)
                    guard result.isUsable else { return nil }
                    if let patientSuperior, !result.hasAnatomicalNosePosition(patientSuperior: patientSuperior) {
                        rejectedNosePositions += 1
                        return nil
                    }
                    if let patientSuperior, let preferredUnit, frontAlignment >= 0.75,
                       let browGap = faceOffBrowToEyeGap(points: result.points, contours: auxiliary,
                           patientSuperior: patientSuperior, patientAnterior: preferredUnit),
                       browGap > 0.028 {
                        rejectedLowEyes += 1
                        return nil
                    }
                    anatomicalCandidates += 1
                    let score = result.confidence + 0.35 * frontAlignment +
                        (candidate.refinedNose ? 0.05 : 0) -
                        (candidate.method == geometricNoseMethod ? 0.20 : 0)
                    if score > provisionalScore {
                        provisional = result
                        provisionalScore = score
                        provisionalUsesImagePoseFallback = face.usedImagePoseFallback
                        provisionalMethod = candidate.method
                        provisionalAuxiliary = auxiliary
                    }
                    return HeadSurfaceLandmarkObservation(landmarks: result,
                                                          auxiliaryContours: auxiliary,
                                                          usedImagePoseFallback: face.usedImagePoseFallback)
                }
                for candidate in candidates {
                    if let result = assess(candidate) { return result }
                }
                // If the image-space nose is missing or anatomically implausible, use
                // the visible 3D surface only as an unconfirmed last resort.
                if let patientSuperior, preferredUnit != nil, frontAlignment >= 0.75,
                   let tip = rendered.anatomicalNoseTip(eyes: values,
                       patientSuperior: patientSuperior, towardCamera: view.towardCamera) {
                    var geometry = values
                    geometry[.noseTip] = tip
                    if !countedMapped {
                        mappedCandidates += 1
                        countedMapped = true
                    }
                    if let result = assess((geometry, geometricNoseMethod, true)) { return result }
                }
            }
            return nil
        }
        func report(_ confirmed: HeadLandmarkSet?) -> HeadSurfaceLandmarkSearchReport {
            var selectedAuxiliary = confirmed != nil ? confirmedAuxiliary :
                (provisional != nil ? provisionalAuxiliary : diagnosticAuxiliary)
            // Preview candidates are chosen from patient-frontal renders,
            // independently of the view that supplied the selected Vision landmarks.
            if !bestSurfaceSeam.isEmpty { selectedAuxiliary[.surfaceEyeSeam] = bestSurfaceSeam }
            if let bestSurfaceApex { selectedAuxiliary[.surfaceNoseApex] = [bestSurfaceApex] }
            let selectedGap: Float?
            var noseOffsets: (tip: Float?, bridge: Float?) = (nil, nil)
            var noseTipToApexMM: Float?
            if let selected = confirmed ?? provisional, let patientSuperior, let preferredUnit {
                selectedGap = faceOffBrowToEyeGap(points: selected.points, contours: selectedAuxiliary,
                    patientSuperior: patientSuperior, patientAnterior: preferredUnit).map { $0 * 1000 }
                noseOffsets = faceOffNoseMidlineOffsets(points: selected.points, contours: selectedAuxiliary,
                    patientSuperior: patientSuperior, patientAnterior: preferredUnit)
                if let tip = selected.points[.noseTip], let bestSurfaceApex {
                    noseTipToApexMM = simd_distance(tip, bestSurfaceApex) * 1000
                }
            } else {
                selectedGap = nil
            }
            return HeadSurfaceLandmarkSearchReport(
                confirmed: confirmed, provisional: provisional,
                provisionalUsesImagePoseFallback: provisionalUsesImagePoseFallback,
                provisionalMethod: provisionalMethod,
                auxiliaryContours: selectedAuxiliary,
                viewsRendered: viewsRendered,
                visionFaces: visionFaces, facesWithRawEyes: facesWithRawEyes,
                facesWithConfidentEyes: facesWithConfidentEyes,
                facesWithAcceptableEyePose: facesWithAcceptableEyePose,
                facesWithReorderedEyes: facesWithReorderedEyes,
                facesWithFallbackSpacing: facesWithFallbackSpacing,
                facesWithFallbackLevel: facesWithFallbackLevel,
                bestPairedEyeConfidence: bestPairedEyeConfidence,
                bestPairedEyePoseMagnitude: bestPairedEyePoseMagnitude,
                facesWithEyes: facesWithEyes,
                facesWithNoseContour: facesWithNoseContour, imageCandidates: imageCandidates,
                mappedCandidates: mappedCandidates, anatomicalCandidates: anatomicalCandidates,
                rejectedFallbackViews: rejectedFallbackViews,
                rejectedNosePositions: rejectedNosePositions,
                rejectedLowEyes: rejectedLowEyes, browToEyeGapMM: selectedGap,
                noseTipMidlineOffsetMM: noseOffsets.tip,
                noseBridgeMidlineOffsetMM: noseOffsets.bridge,
                noseTipToApexMM: noseTipToApexMM,
                surfacePreviewFrontal: surfacePreviewFrontal,
                surfaceSeamFound: surfaceSeamFound,
                surfaceApexFound: surfaceApexFound,
                bestFallbackViewAlignment: bestFallbackFront.isFinite
                    ? String(format: "front %.2f, up %.2f", Double(bestFallbackFront), Double(bestFallbackUp)) : nil,
                closestViewDisagreement: closestViewDisagreement
            )
        }
        var orientations: [(direction: SIMD3<Float>, up: SIMD3<Float>)] = []
        if let preferredUnit, let preferredUp, simd_length(preferredUp) > 0.5 {
            orientations.append((preferredUnit, simd_normalize(preferredUp)))
        }
        let directions: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0, 0, -1), SIMD3(0, -1, 0),
                                         SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(-1, 0, 0)]
        for direction in directions {
            let baseUp = abs(direction.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
            for roll in 0..<4 {
                let up = simd_quatf(angle: Float(roll) * .pi / 2, axis: direction).act(baseUp)
                orientations.append((direction, up))
            }
        }
        func corroborated(_ orientation: (direction: SIMD3<Float>, up: SIMD3<Float>),
                          verticalFocus: Float = 0, magnification: Float = 1,
                          allowLegacyWithoutFace: Bool = false,
                          lightSide: Float = 0) throws -> HeadLandmarkSet? {
            let view = HeadSurfaceRenderView(minimum: minimum, maximum: maximum,
                                             direction: orientation.direction, up: orientation.up,
                                             verticalFocus: verticalFocus, magnification: magnification)
            guard let first = try autoreleasepool(invoking: {
                try observation(view, allowLegacyWithoutFace: allowLegacyWithoutFace, lightSide: lightSide)
            }) else { return nil }
            for angle: Float in [0.14, -0.14] {
                let alternate = HeadSurfaceRenderView(minimum: minimum, maximum: maximum,
                    direction: simd_quatf(angle: angle, axis: orientation.up).act(orientation.direction),
                    up: orientation.up, verticalFocus: verticalFocus, magnification: magnification)
                if let second = try autoreleasepool(invoking: {
                    try observation(alternate, allowLegacyWithoutFace: allowLegacyWithoutFace, lightSide: lightSide)
                }) {
                    let deltas = HeadLandmarkID.allCases.compactMap { id -> (HeadLandmarkID, Float)? in
                        guard let a = first.landmarks.points[id], let b = second.landmarks.points[id] else { return nil }
                        return (id, simd_distance(a, b))
                    }
                    if deltas.count >= 5, let worst = deltas.max(by: { $0.1 < $1.1 }),
                       worst.1 < smallestViewMismatch {
                        smallestViewMismatch = worst.1
                        closestViewDisagreement = String(format: "point %d %.1f mm",
                            worst.0.rawValue + 1, Double(worst.1 * 1000))
                    }
                    if first.landmarks.hasObservedNose && second.landmarks.hasObservedNose,
                       first.landmarks.agrees(with: second.landmarks, tolerance: 0.008) {
                        if first.usedImagePoseFallback || second.usedImagePoseFallback {
                            provisionalUsesImagePoseFallback = true
                        } else if let confirmed = HeadLandmarkConsensus.average([first.landmarks, second.landmarks]) {
                            confirmedAuxiliary = first.auxiliaryContours
                            return confirmed
                        }
                    }
                }
            }
            return nil
        }
        for orientation in orientations {
            if let confirmed = try corroborated(orientation) { return report(confirmed) }
        }

        // A head-height frame can leave the eyes and cropped nose in the bottom few
        // pixels. Re-render around the lower face without changing mesh coordinates.
        var focusedOrientations: [(direction: SIMD3<Float>, up: SIMD3<Float>)] = []
        if let preferredUnit, let preferredUp, simd_length(preferredUp) > 0.5 {
            focusedOrientations.append((preferredUnit, simd_normalize(preferredUp)))
        } else {
            for direction in directions {
                let up = abs(direction.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
                focusedOrientations.append((direction, up))
            }
        }
        let focusedFrames: [(focus: Float, zoom: Float)] = [(-0.30, 1.35), (-0.48, 1.55)]
        for (focus, zoom) in focusedFrames {
            for orientation in focusedOrientations {
                if let confirmed = try corroborated(orientation, verticalFocus: focus,
                                                    magnification: zoom,
                                                    allowLegacyWithoutFace: true) { return report(confirmed) }
            }
        }

        // If Vision sees a face but not its features, relight the same geometry
        // from each side before giving up. Keep all 3D checks unchanged.
        if let preferredUnit, let preferredUp, simd_length(preferredUp) > 0.5 {
            let frontal = (direction: preferredUnit, up: simd_normalize(preferredUp))
            for lightSide: Float in [-0.9, 0.9] {
                if let confirmed = try corroborated(frontal, allowLegacyWithoutFace: true,
                                                    lightSide: lightSide) {
                    return report(confirmed)
                }
            }
        }
        return report(nil)
    }

    private enum RendererError: Error { case unavailable }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4x4 matrix; float4 light; };
    struct VertexOut { float4 position [[position]]; float3 local; };
    struct FragmentOut { float4 color [[color(0)]]; float4 local [[color(1)]]; };
    vertex VertexOut landmarkVertex(device const float3 *positions [[buffer(0)]],
        constant Uniforms &u [[buffer(2)]], uint i [[vertex_id]]) {
        VertexOut out;
        out.local = positions[i]; out.position = u.matrix * float4(out.local, 1);
        return out;
    }
    fragment FragmentOut landmarkFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(2)]]) {
        // Derive lighting from actual triangles, independent of display-mesh normals.
        float3 normal = normalize(cross(dfdx(in.local), dfdy(in.local)));
        float shade = 0.25 + 0.75 * abs(dot(normal, normalize(u.light.xyz)));
        FragmentOut out; out.color = float4(float3(0.94, 0.77, 0.69) * shade, 1);
        out.local = float4(in.local, 1); return out;
    }
    """
}

enum HeadLandmarkID: Int, CaseIterable, Sendable {
    case leftEyeMinX, leftEyeMaxX, rightEyeMinX, rightEyeMaxX, noseTip, noseBridge
}
struct HeadLandmarkSet: Sendable {
    var points: [HeadLandmarkID: SIMD3<Float>]
    var towardCamera: SIMD3<Float>
    var confidence: Float
    var hasObservedNose: Bool

    var isUsable: Bool {
        guard confidence >= 0.5, confidence.isFinite,
              let a = points[.leftEyeMinX], let b = points[.leftEyeMaxX],
              let c = points[.rightEyeMinX], let d = points[.rightEyeMaxX], let nose = points[.noseTip],
              points.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              abs(simd_length(towardCamera) - 1) < 0.01 else { return false }
        let left = (a + b) * 0.5, right = (c + d) * 0.5
        let eyeWidth = simd_length(right - left)
        guard (0.035...0.095).contains(eyeWidth),
              (0.008...0.045).contains(simd_length(a - b)),
              (0.008...0.045).contains(simd_length(c - d)) else { return false }
        let mid = (left + right) * 0.5, lateral = (right - left) / eyeWidth
        guard abs(simd_dot(nose - mid, lateral)) <= min(0.010, eyeWidth * 0.18) else { return false }
        if let bridge = points[.noseBridge],
           abs(simd_dot(bridge - mid, lateral)) > min(0.010, eyeWidth * 0.18) { return false }
        let belowEyes = nose - mid - lateral * simd_dot(nose - mid, lateral)
        return (0.012...0.085).contains(simd_length(belowEyes)) &&
            (0.003...0.060).contains(simd_dot(nose - mid, towardCamera))
    }

    func hasAnatomicalNosePosition(patientSuperior: SIMD3<Float>) -> Bool {
        guard let a = points[.leftEyeMinX], let b = points[.leftEyeMaxX],
              let c = points[.rightEyeMinX], let d = points[.rightEyeMaxX],
              let tip = points[.noseTip] else { return false }
        let eyeMidpoint = (a + b + c + d) * 0.25
        let tipHeight = simd_dot(tip - eyeMidpoint, patientSuperior)
        guard (-0.090 ... -0.020).contains(tipHeight) else { return false }
        return true
    }

    func agrees(with other: Self, tolerance: Float = 0.010) -> Bool {
        guard isUsable, other.isUsable else { return false }
        let common = HeadLandmarkID.allCases.filter { points[$0] != nil && other.points[$0] != nil }
        return common.count >= 5 && common.allSatisfy { simd_distance(points[$0]!, other.points[$0]!) <= tolerance }
    }
}
struct HeadLandmarkConsensus {
    static func average(_ observations: [HeadLandmarkSet]) -> HeadLandmarkSet? {
        guard let first = observations.first else { return nil }
        var points: [HeadLandmarkID: SIMD3<Float>] = [:]
        for id in HeadLandmarkID.allCases where observations.allSatisfy({ $0.points[id] != nil }) {
            points[id] = observations.reduce(SIMD3<Float>.zero) { $0 + $1.points[id]! } / Float(observations.count)
        }
        let direction = observations.reduce(SIMD3<Float>.zero) { $0 + $1.towardCamera }
        guard simd_length(direction) > 0.1 else { return nil }
        let result = HeadLandmarkSet(points: points, towardCamera: simd_normalize(direction),
                                     confidence: observations.map(\.confidence).min() ?? first.confidence,
                                     hasObservedNose: observations.allSatisfy(\.hasObservedNose))
        return result.isUsable ? result : nil
    }
}

// A CT-only diagnostic counterpart to PhoneVolumeRender's HU-based eyeball finder.
// These are globe centers inside the volume, not surface eye corners or registration landmarks.
struct HeadCTEyeVolume: Sendable {
    let float32HU: Data
    let dimensions: SIMD3<Int>
    let spacingMM: SIMD3<Float>
    let patientAnterior: SIMD3<Float>
    let patientSuperior: SIMD3<Float>
    let surfaceEyeHints: [SIMD3<Float>] // Unconfirmed skin-eye centers, only for a bounded CT diagnostic fallback.
}

struct HeadCTEyeDiagnostic: Sendable {
    let centers: [SIMD3<Float>] // Same normalized volume coordinates as the FaceOff surface.
    let candidateCount: Int
    let pairSeparationMM: Float?
    let detail: String
}

enum HeadCTEyeballFinder {
    private struct VoxelMask {
        private var words: [UInt64]

        init(count: Int) {
            words = [UInt64](repeating: 0, count: count / 64 + (count % 64 == 0 ? 0 : 1))
        }

        mutating func insert(_ index: Int) {
            words[index >> 6] |= UInt64(1) << (index & 63)
        }

        mutating func take(_ index: Int) -> Bool {
            let word = index >> 6
            let bit = UInt64(1) << (index & 63)
            guard words[word] & bit != 0 else { return false }
            words[word] &= ~bit
            return true
        }
    }

    private struct Candidate {
        let voxel: SIMD3<Float>
        let center: SIMD3<Float>
        let radiusMM: Float
        let lateral: Float
        let anterior: Float
        let superior: Float
    }

    private struct ScanResult {
        let candidates: [Candidate]
        let substantialBlobs: Int
        let sizedBlobs: Int
        let shapedBlobs: Int
    }

    static func detect(_ input: HeadCTEyeVolume) throws -> HeadCTEyeDiagnostic {
        let dimensions = input.dimensions
        let nx = dimensions.x, ny = dimensions.y, nz = dimensions.z
        func unavailable(_ reason: String) -> HeadCTEyeDiagnostic {
            HeadCTEyeDiagnostic(centers: [], candidateCount: 0, pairSeparationMM: nil,
                                detail: reason)
        }
        guard nx >= 16, ny >= 16, nz >= 16 else {
            return unavailable("CT dimensions invalid: \(nx) x \(ny) x \(nz)")
        }
        let (sliceCount, sliceOverflow) = nx.multipliedReportingOverflow(by: ny)
        guard !sliceOverflow else {
            return unavailable("CT dimensions overflow: \(nx) x \(ny) x \(nz)")
        }
        let (voxelCount, volumeOverflow) = sliceCount.multipliedReportingOverflow(by: nz)
        guard !volumeOverflow, voxelCount <= Int.max / MemoryLayout<Float>.stride else {
            return unavailable("CT volume byte count overflow: \(nx) x \(ny) x \(nz)")
        }
        let expectedBytes = voxelCount * MemoryLayout<Float>.stride
        guard input.float32HU.count == expectedBytes else {
            return unavailable("CT voxel data mismatch: \(input.float32HU.count) of \(expectedBytes) bytes (\(nx) x \(ny) x \(nz))")
        }
        // A packed mask allows typical full-resolution head CTs without allocating
        // one additional byte per voxel. Keep a separate bound for extreme volumes.
        guard voxelCount <= 512_000_000 else {
            return unavailable("CT volume exceeds diagnostic scan budget: \(nx) x \(ny) x \(nz)")
        }
        guard (0.05...20).contains(input.spacingMM.x),
              (0.05...20).contains(input.spacingMM.y),
              (0.05...20).contains(input.spacingMM.z) else {
            return unavailable("CT spacing unsupported: \(input.spacingMM.x), \(input.spacingMM.y), \(input.spacingMM.z) mm")
        }
        guard simd_length(input.patientAnterior) > 0.5,
              simd_length(input.patientSuperior) > 0.5 else {
            return unavailable("CT patient orientation unavailable")
        }
        let spacing = input.spacingMM
        let physicalExtent = SIMD3<Float>(Float(nx - 1) * spacing.x,
                                          Float(ny - 1) * spacing.y,
                                          Float(nz - 1) * spacing.z)
        let scaleMM = max(physicalExtent.x, max(physicalExtent.y, physicalExtent.z))
        let anterior = simd_normalize(input.patientAnterior)
        let superior = simd_normalize(input.patientSuperior)
        let lateralAxis = simd_cross(superior, anterior)
        guard simd_length(lateralAxis) > 0.5 else {
            return HeadCTEyeDiagnostic(centers: [], candidateCount: 0, pairSeparationMM: nil,
                                       detail: "CT patient orientation unavailable")
        }
        let lateral = simd_normalize(lateralAxis)
        func world(_ voxel: SIMD3<Float>) -> SIMD3<Float> {
            (voxel * spacing - physicalExtent * 0.5) / scaleMM
        }
        let hints = input.surfaceEyeHints
        let usableHints = hints.count == 2 && hints.allSatisfy { point in
            point.x.isFinite && point.y.isFinite && point.z.isFinite
        } && (30...100).contains(simd_distance(hints[0], hints[1]) * scaleMM)
        let hintMidpoint = usableHints ? (hints[0] + hints[1]) * 0.5 : SIMD3<Float>.zero
        let hintAxes = SIMD3<Float>(simd_dot(hintMidpoint, lateral),
                                    simd_dot(hintMidpoint, anterior),
                                    simd_dot(hintMidpoint, superior))
        func nearHint(_ point: SIMD3<Float>, radiusMM: Float) -> Bool {
            usableHints && hints.contains { simd_distance(point, $0) * scaleMM <= radiusMM }
        }
        return try input.float32HU.withUnsafeBytes { raw -> HeadCTEyeDiagnostic in
            let hu = raw.bindMemory(to: Float.self)
            var minimum = SIMD3<Float>(repeating: .infinity)
            var maximum = SIMD3<Float>(repeating: -.infinity)
            var headSamples = 0
            for k in stride(from: 0, to: nz, by: max(1, nz / 120)) {
                if Task.isCancelled { throw CancellationError() }
                for j in stride(from: 0, to: ny, by: max(1, ny / 160)) {
                    for i in stride(from: 0, to: nx, by: max(1, nx / 160)) {
                        let value = hu[(k * ny + j) * nx + i]
                        guard value.isFinite, (-350...3000).contains(value) else { continue }
                        let point = world(SIMD3<Float>(Float(i), Float(j), Float(k)))
                        let axes = SIMD3<Float>(simd_dot(point, lateral),
                                                simd_dot(point, anterior),
                                                simd_dot(point, superior))
                        minimum = simd_min(minimum, axes)
                        maximum = simd_max(maximum, axes)
                        headSamples += 1
                    }
                }
            }
            guard headSamples >= 100 else {
                return HeadCTEyeDiagnostic(centers: [], candidateCount: 0, pairSeparationMM: nil,
                                           detail: "No usable CT head bounds")
            }
            let headCenter = (minimum + maximum) * 0.5
            let headSize = maximum - minimum
            guard headSize.x * scaleMM >= 70, headSize.y * scaleMM >= 60,
                  headSize.z * scaleMM >= 30 else {
                return HeadCTEyeDiagnostic(centers: [], candidateCount: 0, pairSeparationMM: nil,
                                           detail: "CT head bounds too small")
            }

            let voxelVolume = Double(spacing.x * spacing.y * spacing.z)
            func scanCandidates(in window: ClosedRange<Float>) throws -> ScanResult {
                var mask = VoxelMask(count: voxelCount)
                for k in 0..<nz {
                    if Task.isCancelled { throw CancellationError() }
                    let base = k * sliceCount
                    for offset in 0..<sliceCount {
                        let value = hu[base + offset]
                        guard value.isFinite, window.contains(value) else { continue }
                        if window.lowerBound > 0 {
                            let j = offset / nx
                            let i = offset - j * nx
                            let point = world(SIMD3<Float>(Float(i), Float(j), Float(k)))
                            guard nearHint(point, radiusMM: 40) else { continue }
                        }
                        mask.insert(base + offset)
                    }
                }
                var candidates: [Candidate] = []
                var stack: [Int] = []
                stack.reserveCapacity(8192)
                var substantialBlobs = 0
                var sizedBlobs = 0
                var shapedBlobs = 0
                for seed in 0..<voxelCount {
                    if seed.isMultiple(of: sliceCount), Task.isCancelled { throw CancellationError() }
                    guard mask.take(seed) else { continue }
                    stack.removeAll(keepingCapacity: true)
                    stack.append(seed)
                    var count = 0
                    var sum = SIMD3<Double>.zero
                    var minIndex = SIMD3<Int>(repeating: .max)
                    var maxIndex = SIMD3<Int>(repeating: .min)
                    while let index = stack.popLast() {
                        count += 1
                        if count.isMultiple(of: 100_000), Task.isCancelled { throw CancellationError() }
                        let k = index / sliceCount
                        let remainder = index - k * sliceCount
                        let j = remainder / nx
                        let i = remainder - j * nx
                        let ijk = SIMD3<Int>(i, j, k)
                        sum += SIMD3<Double>(Double(i), Double(j), Double(k))
                        minIndex = simd_min(minIndex, ijk)
                        maxIndex = simd_max(maxIndex, ijk)
                        func visit(_ neighbor: Int) {
                            if mask.take(neighbor) {
                                stack.append(neighbor)
                            }
                        }
                        if i > 0 { visit(index - 1) }
                        if i + 1 < nx { visit(index + 1) }
                        if j > 0 { visit(index - nx) }
                        if j + 1 < ny { visit(index + nx) }
                        if k > 0 { visit(index - sliceCount) }
                        if k + 1 < nz { visit(index + sliceCount) }
                    }
                    guard count >= 80 else { continue }
                    substantialBlobs += 1
                    let radius = Float(cbrt(3 * Double(count) * voxelVolume / (4 * Double.pi)))
                    guard (6...18).contains(radius) else { continue }
                    sizedBlobs += 1
                    let boundsMM = SIMD3<Float>(Float(maxIndex.x - minIndex.x + 1) * spacing.x,
                                                Float(maxIndex.y - minIndex.y + 1) * spacing.y,
                                                Float(maxIndex.z - minIndex.z + 1) * spacing.z)
                    let minDimension = min(boundsMM.x, min(boundsMM.y, boundsMM.z))
                    let maxDimension = max(boundsMM.x, max(boundsMM.y, boundsMM.z))
                    guard minDimension >= 5, maxDimension / minDimension <= 2.2 else { continue }
                    shapedBlobs += 1
                    let voxel = SIMD3<Float>(Float(sum.x / Double(count)),
                                             Float(sum.y / Double(count)),
                                             Float(sum.z / Double(count)))
                    let center = world(voxel)
                    let axes = SIMD3<Float>(simd_dot(center, lateral),
                                            simd_dot(center, anterior),
                                            simd_dot(center, superior))
                    let headOffset = axes - headCenter
                    let inHeadEyeRegion = (0.05...0.32).contains(abs(headOffset.x) / headSize.x) &&
                        (-0.05...0.48).contains(headOffset.y / headSize.y) &&
                        (-0.30...0.40).contains(headOffset.z / headSize.z)
                    guard inHeadEyeRegion || (window.lowerBound > 0 && nearHint(center, radiusMM: 25)) else {
                        continue
                    }
                    let pairOffset = axes - (window.lowerBound > 0 ? hintAxes : headCenter)
                    candidates.append(Candidate(voxel: voxel, center: center, radiusMM: radius,
                                                lateral: pairOffset.x * scaleMM,
                                                anterior: pairOffset.y * scaleMM,
                                                superior: pairOffset.z * scaleMM))
                }
                return ScanResult(candidates: candidates, substantialBlobs: substantialBlobs,
                                  sizedBlobs: sizedBlobs, shapedBlobs: shapedBlobs)
            }
            func bestPair(in candidates: [Candidate]) -> (left: Candidate, right: Candidate, score: Float)? {
                var best: (left: Candidate, right: Candidate, score: Float)?
                for first in candidates where first.lateral < 0 {
                    for second in candidates where second.lateral > 0 {
                        let separation = simd_distance(first.center, second.center) * scaleMM
                        let levelDifference = abs(first.superior - second.superior)
                        let depthDifference = abs(first.anterior - second.anterior)
                        let symmetryError = abs(abs(first.lateral) - abs(second.lateral))
                        let radiusDifference = abs(first.radiusMM - second.radiusMM)
                        guard (35...90).contains(separation), levelDifference <= 15,
                              depthDifference <= 18, symmetryError <= 20,
                              radiusDifference <= 7 else { continue }
                        let score = abs(separation - 62) * 0.15 + levelDifference * 0.2 +
                            depthDifference * 0.2 + symmetryError * 0.3 + radiusDifference +
                            abs(first.radiusMM - 11.5) * 0.4 + abs(second.radiusMM - 11.5) * 0.4
                        if best == nil || score < best!.score { best = (first, second, score) }
                    }
                }
                return best
            }
            // PhoneVolumeRender starts with 0...10 HU. Some CT reconstructions
            // shift vitreous density; try two adjacent narrow windows only when
            // the previous window has no anatomically plausible bilateral pair.
            var attempts: [String] = []
            var candidateTotal = 0
            var selected: (pair: (left: Candidate, right: Candidate, score: Float),
                           candidates: Int, window: ClosedRange<Float>)?
            let windows: [ClosedRange<Float>] = usableHints ? [0...10, 8...22, 16...30] : [0...10]
            for window in windows {
                let scan = try scanCandidates(in: window)
                candidateTotal += scan.candidates.count
                attempts.append("\(Int(window.lowerBound))...\(Int(window.upperBound)) HU: \(scan.substantialBlobs) blobs, \(scan.sizedBlobs) size, \(scan.shapedBlobs) shape, \(scan.candidates.count) ROI")
                if let pair = bestPair(in: scan.candidates) {
                    selected = (pair, scan.candidates.count, window)
                    break
                }
            }
            guard let selected else {
                if !usableHints { attempts.append("wider HU search skipped: no usable skin-eye hints") }
                return HeadCTEyeDiagnostic(centers: [], candidateCount: candidateTotal,
                                           pairSeparationMM: nil,
                                           detail: "No plausible bilateral CT globe pair (\(attempts.joined(separator: "; ")))")
            }
            let best = selected.pair

            // The Phone finder refines each blob around 15 HU. Cap that shift so
            // a neighboring structure cannot pull a diagnostic center away.
            func refinedCenter(_ candidate: Candidate) -> SIMD3<Float> {
                let seed = candidate.voxel
                let radiusMM: Float = 14
                let bounds = SIMD3<Int>(Int(ceil(radiusMM / spacing.x)),
                                        Int(ceil(radiusMM / spacing.y)),
                                        Int(ceil(radiusMM / spacing.z)))
                let centerIndex = SIMD3<Int>(Int(seed.x.rounded()), Int(seed.y.rounded()), Int(seed.z.rounded()))
                var weighted = SIMD3<Double>.zero
                var weightSum = 0.0
                for k in max(0, centerIndex.z - bounds.z)...min(nz - 1, centerIndex.z + bounds.z) {
                    for j in max(0, centerIndex.y - bounds.y)...min(ny - 1, centerIndex.y + bounds.y) {
                        for i in max(0, centerIndex.x - bounds.x)...min(nx - 1, centerIndex.x + bounds.x) {
                            let value = hu[(k * ny + j) * nx + i]
                            guard value.isFinite, (8...22).contains(value) else { continue }
                            let delta = (SIMD3<Float>(Float(i), Float(j), Float(k)) - seed) * spacing
                            let distance = simd_length(delta)
                            guard distance < radiusMM else { continue }
                            let weight = Double((1 - distance / radiusMM) *
                                                max(0.1, 1 - abs(value - 15) / 7))
                            weighted += SIMD3<Double>(Double(i), Double(j), Double(k)) * weight
                            weightSum += weight
                        }
                    }
                }
                guard weightSum > 20 else { return candidate.center }
                let refinedVoxel = SIMD3<Float>(Float(weighted.x / weightSum),
                                                Float(weighted.y / weightSum),
                                                Float(weighted.z / weightSum))
                guard simd_length((refinedVoxel - seed) * spacing) <= 5 else { return candidate.center }
                return world(refinedVoxel)
            }
            let refined = [refinedCenter(best.left), refinedCenter(best.right)]
            let refinedSeparation = simd_distance(refined[0], refined[1]) * scaleMM
            let centers = (35...90).contains(refinedSeparation)
                ? refined : [best.left.center, best.right.center]
            return HeadCTEyeDiagnostic(centers: centers, candidateCount: selected.candidates,
                pairSeparationMM: simd_distance(centers[0], centers[1]) * scaleMM,
                detail: "\(Int(selected.window.lowerBound))...\(Int(selected.window.upperBound)) HU; not surface eye corners")
        }
    }
}

