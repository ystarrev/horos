"""Source guards for stored-pixel loading, without a build or patient data.

The Swift runtime harness exercises the real normalizer, including exhaustive
8/16-bit inputs. It is deliberately not compiled or run by this source suite.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Horos/Sources/MetalViewer/SwiftDICOMReader.swift").read_text()
NORMALIZE = SOURCE.split("private static func normalizedStoredData(", 1)[1].split(
    "\n    private static func nestedFloat(", 1
)[0]
HARNESS = (ROOT / "Scripts/tests/SwiftDICOMStoredPixelTests.swift").read_text()


class StoredPixelNormalizationTests(unittest.TestCase):
    def test_only_canonical_full_width_words_bypass_normalization(self):
        gate = "if bitsAllocated == 16, bitsStored == 16, highBit == 15 {"
        fast = NORMALIZE.split(gate, 1)[1].split("let lowBit", 1)[0]
        self.assertIn("return sourceData", fast)
        self.assertNotIn("isSigned", fast)  # Full-width signed words need no extension.
        self.assertLess(NORMALIZE.index("guard pixelCount > 0"), NORMALIZE.index(gate))
        self.assertLess(NORMALIZE.index("guard sourceData.count >="), NORMALIZE.index(gate))
        self.assertLess(NORMALIZE.index(gate), NORMALIZE.index("var output ="))

    def test_fast_path_preserves_exact_length_and_zero_based_indices(self):
        self.assertIn("sourceData.count == outputByteCount, sourceData.startIndex == 0", NORMALIZE)
        self.assertIn("return Data(sourceData.prefix(outputByteCount))", NORMALIZE)
        self.assertNotIn("bytesNoCopy", NORMALIZE)

    def test_conversion_writes_directly_to_one_output_data_buffer(self):
        self.assertIn("var output = Data(count: outputByteCount)", NORMALIZE)
        self.assertIn("output.withUnsafeMutableBytes", NORMALIZE)
        self.assertIn("return output\n", NORMALIZE)
        self.assertNotIn("[UInt16]", NORMALIZE)
        self.assertNotIn("Data($0)", NORMALIZE)
        self.assertIn("outputBytes[byteOffset] = UInt8(truncatingIfNeeded: normalizedValue)", NORMALIZE)
        self.assertIn("outputBytes[byteOffset + 1] = UInt8(truncatingIfNeeded: normalizedValue >> 8)", NORMALIZE)

    def test_mask_shift_and_sign_extension_are_retained(self):
        for expression in (
            "max(highBit - bitsStored + 1, 0)",
            "bitsStored == 16 ? UInt16.max : UInt16((1 << bitsStored) - 1)",
            "UInt16(1 << max(bitsStored - 1, 0))",
            "UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)",
            "rawValue = UInt16(bytes[index])",
            "(rawValue >> UInt16(lowBit)) & mask",
            "isSigned && storedValue & signBit != 0",
            "storedValue | ~mask",
        ):
            self.assertIn(expression, NORMALIZE)

    def test_runtime_harness_covers_all_sample_bits_and_buffer_edge_cases(self):
        for expression in (
            "for bitsAllocated in [8, 16]", "let pixelCount = 1 << bitsAllocated",
            "for bitsStored in 1...bitsAllocated", "for highBit in (bitsStored - 1)..<bitsAllocated",
            "for isSigned in [false, true]", "try normalizedStoredData(",
            "sliced.startIndex != 0", "copy-on-write isolation",
            "Empty frame accepted", "Truncated frame accepted",
        ):
            self.assertIn(expression, HARNESS)
        # Tests call the production private helper; they do not redefine it.
        self.assertNotIn("func normalizedStoredData", HARNESS)


if __name__ == "__main__":
    unittest.main()
