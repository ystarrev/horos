import Foundation

struct Metal3DHistogramModel {
    let minimumHU: Int
    let maximumHU: Int
    let binCount: Int
    let counts: [Int]
    let maxCount: Int

    init(voxels: [Float], minimumHU: Int = -1200, maximumHU: Int = 3200, binCount: Int = 512) {
        let clampedBinCount = max(binCount, 32)
        let lower = min(minimumHU, maximumHU)
        let upper = max(minimumHU, maximumHU)
        let span = max(upper - lower, 1)
        var histogram = [Int](repeating: 0, count: clampedBinCount)

        for voxel in voxels {
            let clampedValue = min(max(voxel, Float(lower)), Float(upper))
            let normalized = (clampedValue - Float(lower)) / Float(span)
            let bin = min(max(Int(normalized * Float(clampedBinCount - 1)), 0), clampedBinCount - 1)
            histogram[bin] += 1
        }

        self.minimumHU = lower
        self.maximumHU = upper
        self.binCount = clampedBinCount
        self.counts = histogram
        self.maxCount = histogram.max() ?? 0
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
