"""Non-build MPR source checks and CPU reference sampling/geometry tests.

The numerical tests exercise the reconstruction math, not a running GPU shader.
"""

from itertools import permutations, product
import math
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

from test_metal4_scout import declaration


SOURCES = Path(__file__).resolve().parents[1] / "Horos/Sources/MetalViewer"
SHADER = (SOURCES / "MetalShaders.metal").read_text()
RENDERER = (SOURCES / "MetalViewerRenderer.swift").read_text()
MODELS = (SOURCES / "MetalViewerModels.swift").read_text()
SAMPLE = declaration("static float metalViewerMPRSample(", SHADER)
FRAGMENT = declaration("fragment float4 metalViewerMPRFragment(", SHADER)
CACHE = declaration("final class MetalPreparedVolumeCache", MODELS)


def weight(x):
    x = abs(x)
    if x <= 1:
        return (1.5 * x - 2.5) * x * x + 1
    if x < 2:
        return ((-0.5 * x + 2.5) * x - 4) * x + 2
    return 0


def sample(size, value, position):
    position = [min(max(p, 0), n - 1) for p, n in zip(position, size)]
    position = [round(p) if abs(p - round(p)) < 0.0001 else p for p in position]
    if all(p == round(p) for p in position):
        return value(*(int(p) for p in position))
    base = [math.floor(p) for p in position]
    fraction = [p - b for p, b in zip(position, base)]
    values, weighted, total = [], 0, 0
    for offsets in product(range(-1, 3), repeat=3):
        w = math.prod(weight(o - f) for o, f in zip(offsets, fraction))
        if w == 0:
            continue
        point = [min(max(b + o, 0), n - 1) for b, o, n in zip(base, offsets, size)]
        v = value(*point)
        values.append(v)
        weighted += w * v
        total += w
    return min(max(weighted / max(total, 0.0001), min(values)), max(values))


class MPRReconstructionTests(unittest.TestCase):
    def test_shader_uses_cubic_on_every_axis_and_exact_voxel_reads(self):
        for axis in "xyz":
            self.assertIn(f"metalViewerCubicWeight(offset - fraction.{axis})", SAMPLE)
        self.assertIn("if (all(position == nearest))", SAMPLE)
        self.assertIn("return volumeTexture.read(uint3(nearest)).r", SAMPLE)
        self.assertIn("volumeTexture.read(samplePosition).r", SAMPLE)
        self.assertNotIn("volumeTexture.sample(", SAMPLE)
        self.assertNotIn("depth < 4", SAMPLE)
        self.assertIn("minimumSample, maximumSample", SAMPLE)
        self.assertEqual(FRAGMENT.count("metalViewerMPRSample("), 2)

    def test_original_values_and_constant_thin_volumes_are_preserved(self):
        size = (7, 6, 5)
        value = lambda x, y, z: (x * 137 + y * 71 - z * 19) % 4096 - 2048
        for p in product(*(range(n) for n in size)):
            self.assertEqual(sample(size, value, p), value(*p))
        for size in ((1, 1, 1), (1, 2, 3), (8, 7, 2), (3, 2, 8)):
            for p in product((-0.5, 0.25, 1.4, 6.8), repeat=3):
                self.assertAlmostEqual(sample(size, lambda *p: -1024, p), -1024)

    def test_interior_linear_ramp_and_axis_symmetry(self):
        size = (8, 9, 10)
        p = (3.25, 4.5, 5.75)
        ramp = lambda x, y, z: 2 * x - 3 * y + 5 * z
        self.assertAlmostEqual(sample(size, ramp, p), ramp(*p))
        value = lambda x, y, z: math.sin(x) * 13 + y * y - z * 3
        expected = sample(size, value, p)
        for axes in permutations(range(3)):
            def permuted_value(*q):
                original = [q[axes.index(i)] for i in range(3)]
                return value(*original)
            self.assertAlmostEqual(sample(tuple(size[i] for i in axes), permuted_value,
                                          tuple(p[i] for i in axes)), expected)

    def test_subvoxel_signal_is_sharper_than_linear_without_exceeding_local_range(self):
        for axis in range(3):
            p = [4, 4, 4]
            p[axis] = 5.5
            value = lambda *q: math.sin(math.pi * q[axis] / 2)
            result = sample((12, 12, 12), value, p)
            expected = math.sin(math.pi * 5.5 / 2)
            linear = 0.5
            self.assertLess(abs(result - expected), abs(linear - expected))
            for coordinate in (3.1, 3.5, 3.9, 4.1, 4.5, 4.9):
                p[axis] = coordinate
                result = sample((10, 10, 10), lambda *q: 100 if q[axis] >= 4 else 0, p)
                self.assertGreaterEqual(result, 0)
                self.assertLessEqual(result, 100)

    def test_gantry_composition_preserves_patient_coordinates(self):
        # Anisotropic source grid with shear and nonzero patient-space origins.
        sx, sy, sz = 0.6, 0.8, 1.25
        origin = (120, -87, 33)
        corrected_origin = (115, -87, 33)
        for shear in (-0.4, 0.4):
            for x, y, z in ((0, 0, 0), (30.25, 45.5, 12.75), (100, 70, 40)):
                world = (corrected_origin[0] + sx * x, origin[1] + sy * y, origin[2] + sz * z)
                source = ((world[0] - origin[0] - shear * z) / sx, y, z)
                combined = (x - shear / sx * z + (corrected_origin[0] - origin[0]) / sx, y, z)
                for actual, expected in zip(combined, source):
                    self.assertAlmostEqual(actual, expected)
                reconstructed = (origin[0] + sx * combined[0] + shear * combined[2],
                                 origin[1] + sy * combined[1], origin[2] + sz * combined[2])
                for actual, expected in zip(reconstructed, world):
                    self.assertAlmostEqual(actual, expected)

    def test_display_and_registration_use_distinct_grids(self):
        prepare = declaration("private func encodeEntry(", CACHE)
        entry = declaration("final class Entry", CACHE)
        self.assertIn("sourceTexture = convertedTexture", prepare)
        self.assertIn("primaryTexture = correctedTexture", prepare)
        self.assertIn("source: primaryTexture", prepare)
        self.assertIn("sourceTexture = existingEntry.sourceTexture", prepare)
        self.assertIn("sourceInverse * voxelToWorld : matrix_identity_float4x4", entry)
        self.assertIn("sourceTexture === texture ? 0", entry)
        self.assertIn("sourceByteCount + levels.reduce", entry)
        uniforms = declaration("private func makeMPRUniforms(", RENDERER)
        self.assertIn("basePreparedVolume?.voxelToSourceVoxel", uniforms)
        self.assertIn("overlayPreparedVolume?.sourceWorldToVoxel", uniforms)
        self.assertIn("fixedVoxelToWorld: fixedVoxelToWorld", uniforms)
        self.assertIn("baseUsesGantryTiltCorrectedVolume ? -1024 : 0", uniforms)
        self.assertIn("uniforms.fixedVoxelToSourceVoxel * float4(in.baseVoxel, 1.0)", FRAGMENT)
        self.assertIn("float3(uniforms.fixedVolumeSize)", FRAGMENT)
        self.assertIn("metalViewerMPRSample(baseTexture, sourceVoxel) : uniforms.baseBackgroundValue", FRAGMENT)
        self.assertIn("metalViewerMPRSample(overlayTexture, movingVoxel.xyz)", FRAGMENT)
        self.assertIn("if baseVolumeTexture == nil { basePreparedVolume = nil }", RENDERER)
        self.assertIn("if overlayVolumeTexture == nil { overlayPreparedVolume = nil }", RENDERER)

    def test_swift_and_metal_uniform_fields_have_identical_order_and_types(self):
        swift = declaration("private struct MetalMPRUniforms", RENDERER)
        metal = declaration("struct MetalMPRUniforms", SHADER)
        mapping = {"simd_float4x4": "float4x4", "Float": "float", "UInt32": "uint",
                   "SIMD3<Float>": "float3", "SIMD3<UInt32>": "uint3"}
        swift_fields = [(mapping[t], n) for n, t in re.findall(r"var (\w+): ([\w<>]+)", swift)]
        metal_fields = re.findall(r"\b(\w+) (\w+);", metal)
        self.assertEqual(swift_fields, metal_fields)

    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "Needs macOS SDK")
    def test_actual_uniform_builder_and_texture_lifetime_properties_typecheck(self):
        harness = "import Metal\nimport simd\n"
        harness += declaration("private struct MetalMPRUniforms", RENDERER)
        harness += """
private enum MetalPreparedVolumeCache {
    final class Entry {
        var sourceTexture: MTLTexture?
        var sourceWorldToVoxel = matrix_identity_float4x4
        var voxelToSourceVoxel = matrix_identity_float4x4
    }
}
private final class RendererCheck {
    var windowLevel: Float = 0, windowWidth: Float = 1
    var overlayWindowLevel: Float = 0, overlayWindowWidth: Float = 1, overlayBlend: Float = 0.5
    var overlayTranslationWorld = SIMD3<Float>.zero
    var movingRotationCenterWorld = SIMD3<Float>.zero
    var overlayRotationRadians = SIMD3<Float>.zero
    var fixedVoxelToWorld = matrix_identity_float4x4
    var movingWorldToVoxel = matrix_identity_float4x4
    var baseHasCustomCLUT = false, overlayHasCustomCLUT = false, baseUsesGantryTiltCorrectedVolume = false
    func inverseRotationMatrix(for value: SIMD3<Float>) -> simd_float4x4 { matrix_identity_float4x4 }
"""
        for name in ("base", "overlay"):
            harness += f"private var {name}PreparedVolume: MetalPreparedVolumeCache.Entry?\n"
            harness += declaration(f"private var {name}VolumeTexture:", RENDERER) + "\n"
            harness += declaration(f"private var {name}MPRTexture:", RENDERER) + "\n"
        harness += declaration("private func makeMPRUniforms(", RENDERER) + "\n}\n"
        with tempfile.TemporaryDirectory(prefix="horos-mpr-reconstruction-") as directory:
            path = Path(directory) / "Check.swift"
            path.write_text(harness)
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-warnings-as-errors",
                "-target", "arm64-apple-macos27.0", "-module-cache-path", "/tmp/horos-swift-check-cache", str(path),
            ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
