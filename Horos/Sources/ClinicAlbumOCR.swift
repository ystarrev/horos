import Foundation
import CoreGraphics
import ImageIO
import Vision

enum ClinicAlbumOCR {
    private static let queue = DispatchQueue(label: "org.horosproject.clinic-ocr", qos: .userInitiated)

    enum Failure: LocalizedError {
        case invalidImage
        case recognitionFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "The clipboard image could not be read. Copy the screenshot again and try importing it."
            case .recognitionFailed:
                return "Text recognition could not read this image. Try reading it again, or add patients manually."
            }
        }
    }

    static func recognize(_ data: Data) async throws -> [ClinicName] {
        let job = Job()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let names = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ClinicName], Error>) in
                // A closed preview must finish cancelling before another request starts.
                queue.async {
                    do {
                        let names = try autoreleasepool { try job.recognize(data) }
                        continuation.resume(returning: names)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return names
        } onCancel: {
            job.cancel()
        }
    }

    final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var activeRequest: VNRecognizeTextRequest?

        func cancel() {
            let request = lock.withLock {
                cancelled = true
                return activeRequest
            }
            request?.cancel()
        }

        private func checkCancellation() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        func recognize(_ data: Data,
            perform: (CGImage, VNRecognizeTextRequest) throws -> Void = { image, request in
                try VNImageRequestHandler(cgImage: image).perform([request])
            }) throws -> [ClinicName] {
            try checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            let image = try ClinicAlbumOCR.preparedImage(data)
            let prepared = ProcessInfo.processInfo.systemUptime
            for cpuOnly in [true, false] {
                try checkCancellation()
                let mode = cpuOnly ? "CPU" : "automatic"
                let attempt = ProcessInfo.processInfo.systemUptime
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]
                    request.automaticallyDetectsLanguage = false
                    try lock.withLock {
                        if cancelled { throw CancellationError() }
                        activeRequest = request
                    }
                    defer { lock.withLock { activeRequest = nil } }
                    if cpuOnly {
                        for (stage, devices) in try request.supportedComputeStageDevices {
                            guard let cpu = devices.first(where: {
                                if case .cpu = $0 { return true }
                                return false
                            }) else { throw Failure.recognitionFailed }
                            request.setComputeDevice(cpu, for: stage)
                        }
                    }
                    try checkCancellation()
                    try perform(image, request)
                    try checkCancellation()
                    let observations = request.results ?? []
                    let names = ClinicAlbumOCR.recognizedNames(observations)
                    NSLog("CLINICALBUM mode=VN-accurate-%@ prepare=%.0fms OCR=%.0fms observations=%ld names=%ld pixels=%ldx%ld",
                          mode, (prepared - start) * 1000, (ProcessInfo.processInfo.systemUptime - attempt) * 1000,
                          observations.count, names.count, image.width, image.height)
                    return names
                } catch {
                    try checkCancellation()
                    if error is CancellationError { throw error }
                    let failure = error as NSError
                    NSLog("CLINICALBUM OCR failed mode=%@ domain=%@ code=%ld elapsed=%.0fms",
                          mode, failure.domain, failure.code, (ProcessInfo.processInfo.systemUptime - attempt) * 1000)
                    // Retry only reader initialization failures, with a fresh request
                    // and Vision choosing the compute device. Keep accurate recognition.
                    if cpuOnly && ClinicAlbumOCR.isReaderInitializationFailure(failure) { continue }
                    throw Failure.recognitionFailed
                }
            }
            throw Failure.recognitionFailed
        }
    }

    static func preparedImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.invalidImage
        }
        // Give Vision owned, decoded RGB pixels, not a lazy image with a display
        // profile or an unusual clipboard pixel format. Composite transparency on white.
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let prepared = context.makeImage() else { throw Failure.invalidImage }
        return prepared
    }

    private static func isReaderInitializationFailure(_ error: NSError) -> Bool {
        var current = error
        for _ in 0..<8 {
            if current.domain == "TextRecognition.CRImageReaderError", current.code == 1 { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }

    private static func recognizedNames(_ observations: [VNRecognizedTextObservation]) -> [ClinicName] {
        // Join OCR fragments on the same baseline before pairing names with age/sex lines.
        let ordered = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in ordered {
            if let last = lines.last, let first = last.first,
               abs(first.boundingBox.midY - observation.boundingBox.midY) < min(first.boundingBox.height, observation.boundingBox.height) * 0.45 {
                lines[lines.count - 1].append(observation)
            } else { lines.append([observation]) }
        }
        return ClinicAlbumMatching.names(from: lines.map { line in
            let texts = line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first }
            return (texts.map(\.string).joined(separator: " "), texts.map(\.confidence).min() ?? 0)
        })
    }
}
