import Foundation

/// One attempted import parse. Results remain in source-path order even though
/// the parsing work is performed concurrently.
@objc(HorosDICOMImportMetadataResult)
final class DICOMImportMetadataResult: NSObject {
    @objc let path: String
    @objc let metadata: NSMutableDictionary?

    init(path: String, metadata: NSMutableDictionary?) {
        self.path = path
        self.metadata = metadata
        super.init()
    }
}

private final class DICOMImportMetadataParseState: @unchecked Sendable {
    let paths: [String]
    let dicomOnly: Bool

    private let cancellationCheck: @convention(block) () -> Bool
    private let progressHandler: @convention(block) (Int) -> Void
    private let importSettings: SwiftDICOMImportSettings
    private let lock = NSLock()
    private var results: [DICOMImportMetadataResult?]
    private var nextIndex = 1
    private var completedCount = 0

    init(
        paths: [String],
        dicomOnly: Bool,
        cancellationCheck: @escaping @convention(block) () -> Bool,
        progressHandler: @escaping @convention(block) (Int) -> Void
    ) {
        self.paths = paths
        self.dicomOnly = dicomOnly
        self.cancellationCheck = cancellationCheck
        self.progressHandler = progressHandler
        importSettings = SwiftDICOMImportSettings()
        results = Array(repeating: nil, count: paths.count)
    }

    var isCancelled: Bool {
        cancellationCheck()
    }

    func parseFirstPath() {
        guard let path = paths.first, !isCancelled else {
            return
        }
        record(parse(path: path), at: 0)
    }

    func runWorker() {
        while !isCancelled {
            guard let index = claimNextIndex(), !isCancelled else {
                return
            }
            record(parse(path: paths[index]), at: index)
        }
    }

    func orderedResults() -> [DICOMImportMetadataResult] {
        lock.lock()
        defer { lock.unlock() }
        return results.compactMap { $0 }
    }

    private func claimNextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard nextIndex < paths.count else {
            return nil
        }
        defer { nextIndex += 1 }
        return nextIndex
    }

    private func parse(path: String) -> DICOMImportMetadataResult {
        autoreleasepool {
            // Every DICOM file takes the native Swift path. The legacy object
            // remains reachable only when the caller explicitly permits
            // non-DICOM imports and the file is not readable as DICOM.
            let swiftMetadata = SwiftDICOMImportMetadata.dictionary(
                fileAtPath: path,
                settings: importSettings
            )
            let metadata = swiftMetadata ?? (dicomOnly
                ? nil
                : DicomFile.metadataDictionary(fileAtPath: path, dicomOnly: false))
            return DICOMImportMetadataResult(
                path: path,
                metadata: metadata
            )
        }
    }

    private func record(_ result: DICOMImportMetadataResult, at index: Int) {
        lock.lock()
        results[index] = result
        completedCount += 1
        progressHandler(completedCount)
        lock.unlock()
    }
}

/// Bounded parallel metadata parsing for database imports.
///
/// DICOM decoding is independent per file, so this work can use several CPU
/// cores. The caller still performs all Core Data changes serially after this
/// method returns.
@objc(HorosDICOMImportMetadataParser)
final class DICOMImportMetadataParser: NSObject {
    @objc(parsePaths:dicomOnly:isCancelled:progress:)
    static func parsePaths(
        _ paths: [String],
        dicomOnly: Bool,
        isCancelled: @escaping @convention(block) () -> Bool,
        progress: @escaping @convention(block) (Int) -> Void
    ) -> [DICOMImportMetadataResult] {
        guard !paths.isEmpty, !isCancelled() else {
            return []
        }

        let state = DICOMImportMetadataParseState(
            paths: paths,
            dicomOnly: dicomOnly,
            cancellationCheck: isCancelled,
            progressHandler: progress
        )

        // Parse one file before opening the worker pool so format and settings
        // initialization complete on a single thread before concurrent work.
        state.parseFirstPath()

        guard paths.count > 1, !state.isCancelled else {
            return state.orderedResults()
        }

        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let workerLimit = min(6, max(1, processorCount - 2))
        let workerCount = paths.count < 8 ? 1 : min(workerLimit, paths.count - 1)

        let queue = OperationQueue()
        queue.name = "org.horos.dicom-import-metadata"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = workerCount

        for _ in 0..<workerCount {
            queue.addOperation {
                state.runWorker()
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return state.orderedResults()
    }
}
