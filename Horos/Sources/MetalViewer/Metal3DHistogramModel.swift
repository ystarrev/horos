import Foundation

struct Metal3DHistogramModel {
    let minimumHU: Int
    let maximumHU: Int
    let binCount: Int
    let counts: [Int]
    let maxCount: Int

    init(counts: [Int], minimumHU: Int = -1200, maximumHU: Int = 3200) {
        let lower = min(minimumHU, maximumHU)
        let upper = max(minimumHU, maximumHU)
        let resolvedCounts = counts.isEmpty ? [0] : counts
        self.minimumHU = lower
        self.maximumHU = upper
        self.binCount = resolvedCounts.count
        self.counts = resolvedCounts
        self.maxCount = resolvedCounts.max() ?? 0
    }

    func huValue(forBin index: Int) -> Double {
        let clampedIndex = min(max(index, 0), max(binCount - 1, 0))
        let fraction = Double(clampedIndex) / Double(max(binCount - 1, 1))
        return Double(minimumHU) + fraction * Double(maximumHU - minimumHU)
    }

    func normalizedLogCount(forBin index: Int) -> Double {
        guard maxCount > 0 else { return 0 }
        let clampedIndex = min(max(index, 0), max(binCount - 1, 0))
        let logValue = log1p(Double(counts[clampedIndex]))
        let logMax = log1p(Double(maxCount))
        return logMax > 0 ? logValue / logMax : 0
    }
}
