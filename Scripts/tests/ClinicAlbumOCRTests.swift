import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Vision

@main
enum ClinicAlbumOCRTests {
    static func image(width: Int = 640, height: Int = 240, transparent: Bool = false,
                      gray: Bool = false, text: Bool = false) -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.displayP3)!
        let alpha: CGImageAlphaInfo = gray ? .none : (transparent ? .premultipliedLast : .noneSkipLast)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
        if !transparent {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if text {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 30, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            for (index, line) in ["Example, Alice", "46 y.o. / F", "Sample, Bob", "52 y.o. / M"].enumerated() {
                context.textPosition = CGPoint(x: 24, y: height - 45 - index * 48)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            }
        }
        return context.makeImage()!
    }

    static func png(_ image: CGImage, orientation: Int = 1) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func main() async throws {
        let data = png(image())
        let prepared = try ClinicAlbumOCR.preparedImage(data)
        precondition(prepared.width == 640 && prepared.height == 240)
        precondition(prepared.bitsPerComponent == 8 && prepared.bitsPerPixel == 32)
        precondition(prepared.colorSpace?.name == CGColorSpace.sRGB)
        precondition(prepared.alphaInfo == .noneSkipLast)

        let transparent = try ClinicAlbumOCR.preparedImage(png(image(transparent: true)))
        let pixels = CFDataGetBytePtr(transparent.dataProvider!.data!)!
        precondition(pixels[0] == 255 && pixels[1] == 255 && pixels[2] == 255)
        let gray = try ClinicAlbumOCR.preparedImage(png(image(gray: true)))
        precondition(gray.colorSpace?.name == CGColorSpace.sRGB && gray.bitsPerPixel == 32)
        let large = try ClinicAlbumOCR.preparedImage(png(image(width: 3400, height: 340, gray: true)))
        precondition(large.width == 3000 && large.height == 300)
        let rotated = try ClinicAlbumOCR.preparedImage(png(image(width: 160, height: 80), orientation: 6))
        precondition(rotated.width == 80 && rotated.height == 160)
        do {
            _ = try ClinicAlbumOCR.preparedImage(Data("not an image".utf8))
            preconditionFailure("Invalid input was accepted")
        } catch ClinicAlbumOCR.Failure.invalidImage {}

        let readerError = NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        for error in [readerError, NSError(domain: VNErrorDomain, code: VNErrorCode.operationFailed.rawValue,
                                          userInfo: [NSUnderlyingErrorKey: readerError])] {
            let job = ClinicAlbumOCR.Job()
            var attempts = [VNRecognizeTextRequest]()
            let names = try job.recognize(data) { image, request in
                precondition(image.colorSpace?.name == CGColorSpace.sRGB)
                precondition(request.recognitionLevel == .accurate)
                precondition(request.recognitionLanguages == ["en-US"] && !request.usesLanguageCorrection)
                for stage in try request.supportedComputeStageDevices.keys {
                    precondition((request.computeDevice(for: stage) != nil) == attempts.isEmpty)
                }
                attempts.append(request)
                if attempts.count == 1 { throw error }
            }
            precondition(names.isEmpty && attempts.count == 2)
            precondition(attempts[0] !== attempts[1])
        }

        for (error, expectedAttempts) in [(readerError, 2), (NSError(domain: "Other", code: 1), 1),
                                          (NSError(domain: "TextRecognition.CRImageReaderError", code: 2), 1)] {
            var attempts = 0
            do {
                _ = try ClinicAlbumOCR.Job().recognize(data) { _, _ in
                    attempts += 1
                    throw error
                }
                preconditionFailure("Recognition failure was hidden")
            } catch ClinicAlbumOCR.Failure.recognitionFailed {}
            precondition(attempts == expectedAttempts)
        }

        let cancelled = ClinicAlbumOCR.Job()
        cancelled.cancel()
        do {
            _ = try cancelled.recognize(data) { _, _ in preconditionFailure("Cancelled job ran OCR") }
            preconditionFailure("Cancellation was ignored")
        } catch is CancellationError {}
        let inFlight = ClinicAlbumOCR.Job()
        var attempts = 0
        do {
            _ = try inFlight.recognize(data) { _, _ in
                attempts += 1
                inFlight.cancel()
                throw readerError
            }
            preconditionFailure("Cancelled job retried")
        } catch is CancellationError {}
        precondition(attempts == 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClinicAlbumOCR.recognize(data)
        }
        do {
            _ = try await task.value
            preconditionFailure("Cancelled task ran OCR")
        } catch is CancellationError {}

        // Optional on-device smoke test; all patient text here is synthetic.
        if CommandLine.arguments.contains("--vision") {
            let names = try await ClinicAlbumOCR.recognize(png(image(text: true)))
            precondition(names.count == 2)
            precondition(names[0].name == "Example, Alice" && names[0].age == 46 && names[0].sex == "F")
            precondition(names[1].name == "Sample, Bob" && names[1].age == 52 && names[1].sex == "M")
        }
        print("Clinic album OCR image, retry, and cancellation checks passed")
    }
}
