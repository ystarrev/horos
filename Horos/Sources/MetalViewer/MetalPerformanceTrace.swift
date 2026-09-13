import Foundation
import Metal
import QuartzCore

// Opt in at launch with -HorosMetalPerformanceLogging YES. Only operation and
// shader names belong here, never patient, study, series, ROI or file identifiers.
enum MetalPerformanceTrace {
    private struct Summary {
        var count = 0
        var total: Double = 0
        var maximum: Double = 0
    }

    private static let enabled = UserDefaults.standard.bool(forKey: "HorosMetalPerformanceLogging")
    private static let lock = NSLock()
    private static var summaries: [String: Summary] = [:]

    static func begin() -> CFTimeInterval? {
        enabled ? CACurrentMediaTime() : nil
    }

    static func end(_ operation: @autoclosure () -> String, since startedAt: CFTimeInterval?) {
        guard let startedAt else { return }
        record(operation(), duration: CACurrentMediaTime() - startedAt)
    }

    // Attach immediately before submission. No extra command buffers, waits or
    // main-thread work: GPU timestamps are read only after completion.
    static func track(
        _ options: MTL4CommitOptions,
        operation: String,
        since startedAt: CFTimeInterval?,
        drawable: MTLDrawable? = nil
    ) {
        guard let startedAt else { return }
        let submittedAt = CACurrentMediaTime()
        options.addFeedbackHandler { feedback in
            let observedAt = CACurrentMediaTime()
            record(operation + ".cpu_prepare", duration: submittedAt - startedAt)
            record(operation + ".submit_to_observed", duration: observedAt - submittedAt)
            let gpuStart = feedback.gpuStartTime
            let gpuEnd = feedback.gpuEndTime
            guard feedback.error == nil, gpuStart > 0, gpuEnd >= gpuStart else { return }
            record(operation + ".submit_to_gpu", duration: gpuStart - submittedAt)
            record(operation + ".gpu", duration: gpuEnd - gpuStart)
            record(operation + ".gpu_to_observed", duration: observedAt - gpuEnd)
        }
        drawable?.addPresentedHandler { presented in
            guard presented.presentedTime > 0 else { return }
            record(operation + ".submit_to_present", duration: presented.presentedTime - submittedAt)
        }
    }

    // Synchronous compute jobs call this after their existing wait, avoiding
    // diagnostic completion handlers that would lengthen that wait.
    static func completed(
        _ feedback: MTL4CommitFeedback,
        operation: String,
        since startedAt: CFTimeInterval?,
        submittedAt: CFTimeInterval?,
        waitStartedAt: CFTimeInterval? = nil
    ) {
        guard let startedAt, let submittedAt else { return }
        let observedAt = CACurrentMediaTime()
        if let waitStartedAt {
            record(operation + ".cpu_wait", duration: observedAt - waitStartedAt)
        }
        record(operation + ".cpu_prepare", duration: submittedAt - startedAt)
        record(operation + ".submit_to_observed", duration: observedAt - submittedAt)
        let gpuStart = feedback.gpuStartTime
        let gpuEnd = feedback.gpuEndTime
        guard feedback.error == nil, gpuStart > 0, gpuEnd >= gpuStart else { return }
        record(operation + ".submit_to_gpu", duration: gpuStart - submittedAt)
        record(operation + ".gpu", duration: gpuEnd - gpuStart)
        record(operation + ".gpu_to_observed", duration: observedAt - gpuEnd)
    }

    private static func record(_ operation: String, duration: Double) {
        guard duration.isFinite, duration >= 0 else { return }
        lock.lock()
        var summary = summaries[operation, default: Summary()]
        summary.count += 1
        summary.total += duration
        summary.maximum = max(summary.maximum, duration)
        summaries[operation] = summary
        lock.unlock()

        // Preserve the first cold sample, then summarize without a per-frame log.
        guard summary.count == 1 || summary.count % 60 == 0 else { return }
        NSLog("METALPERF %@ n=%ld mean=%.3fms max=%.3fms last=%.3fms",
              operation, summary.count, summary.total * 1000 / Double(summary.count),
              summary.maximum * 1000, duration * 1000)
    }
}
