"""Source guards and numerical regressions for volume shading/sampling artifacts.

The numerical checks model the shader arithmetic; they do not run Metal or claim
pixel-level validation of a clinical volume.
"""

import math
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SHADER = (ROOT / "Horos/Sources/MetalViewer/MetalShaders.metal").read_text()
RENDERER = (ROOT / "Horos/Sources/MetalViewer/Metal3DVolumeRenderer.swift").read_text()
GRADIENT_KERNEL = SHADER.split("kernel void metal3DGradientVolume(", 1)[1].split("kernel void", 1)[0]
FRAGMENT = SHADER.split("fragment Metal3DFragmentOutput metal3DVolumeFragment(", 1)[1].split("fragment float4", 1)[0]


def normalize(vector):
    squared = sum(component * component for component in vector)
    return tuple(component / math.sqrt(squared) for component in vector) if squared > 1e-10 else (0, 0, 0)


def quantize_normal(vector):
    return tuple(round(component * 127) / 127 for component in normalize(vector))


def filtered_normal(a, b, weight):
    return normalize(tuple(x * (1 - weight) + y * weight
                           for x, y in zip(quantize_normal(a), quantize_normal(b))))


def old_octahedral_encode(vector):
    scale = sum(abs(component) for component in vector)
    x, y, z = (component / scale for component in vector)
    if z < 0:
        x, y = math.copysign(1 - abs(y), x), math.copysign(1 - abs(x), y)
    return x, y


def old_octahedral_decode(encoded):
    x, y = encoded
    z = 1 - abs(x) - abs(y)
    if z < 0:
        x, y = math.copysign(1 - abs(y), x), math.copysign(1 - abs(x), y)
    return normalize((x, y, z))


class MetalVolumeSamplingTests(unittest.TestCase):
    def test_cartesian_normal_format_and_filter_match(self):
        self.assertIn("descriptor.pixelFormat = .rgba8Snorm", RENDERER)
        self.assertNotIn(".rg8Snorm", RENDERER)
        self.assertNotIn("metal3DEncodeNormal", SHADER)
        self.assertNotIn("metal3DDecodeNormal", SHADER)
        self.assertIn("gradientTexture.write(float4(normal, 0.0f), gid)", GRADIENT_KERNEL)
        self.assertIn("gradientTexture.sample(volumeSampler, texCoord).xyz", SHADER)
        self.assertIn("magnitudeSquared > 1.0e-10f ? normal * rsqrt(magnitudeSquared) : float3(0.0f)", SHADER)

    def test_negative_z_wrap_does_not_turn_a_surface_toward_y(self):
        left, right = normalize((0.01, 0.3, -0.95)), normalize((-0.01, 0.3, -0.95))
        expected = normalize((0, 0.3, -0.95))
        # Nearby directions straddle the old encoding's wraparound. Filtering
        # that encoding produces a normal almost perpendicular to the surface.
        old_midpoint = tuple((a + b) / 2 for a, b in zip(old_octahedral_encode(left), old_octahedral_encode(right)))
        old_result = old_octahedral_decode(old_midpoint)
        self.assertLess(abs(old_result[2]), 0.02)
        result = filtered_normal(left, right, 0.5)
        self.assertLess(result[2], -0.95)
        self.assertGreater(sum(a * b for a, b in zip(result, expected)), 0.9999)

    def test_interpolation_is_continuous_across_all_hemispheres(self):
        for axis in range(3):
            for sign in (-1, 1):
                a, b = [0.2, 0.2, 0.2], [0.21, 0.19, 0.2]
                a[axis], b[axis] = sign, sign
                for step in range(21):
                    weight = step / 20
                    expected = normalize(tuple(x * (1 - weight) + y * weight
                                               for x, y in zip(normalize(a), normalize(b))))
                    result = filtered_normal(a, b, weight)
                    self.assertGreater(sum(x * y for x, y in zip(result, expected)), 0.9999)
        self.assertEqual(filtered_normal((0, 0, 0), (0, 0, 0), 0.5), (0, 0, 0))
        self.assertEqual(filtered_normal((0, 0, 1), (0, 0, -1), 0.5), (0, 0, 0))

    def test_gradient_generation_uses_texel_centers_and_voxel_steps(self):
        self.assertIn("(float3(gid) + 0.5f) / float3(dimensions)", GRADIENT_KERNEL)
        self.assertIn("sampleRadius / max(float3(dimensions), float3(1.0))", SHADER)
        for size in (1, 34, 304, 512):
            for index in (0, size // 2, size - 1):
                coordinate = (index + 0.5) / size
                self.assertAlmostEqual(coordinate * size - 0.5, index)
                for radius in (1.5, 2.75):
                    self.assertAlmostEqual((coordinate + radius / size) * size - 0.5, index + radius)

    def test_empty_brick_skipping_preserves_sample_phase(self):
        self.assertIn("ceil(remainingBrickDistance / uniforms.stepSize)", FRAGMENT)
        self.assertIn("t += (skippedSteps - 1.0f) * uniforms.stepSize", FRAGMENT)
        self.assertNotIn("t += max(remainingBrickDistance - uniforms.stepSize", FRAGMENT)
        for step_size in (0.000125, 0.002, 0.01):
            for phase in (0.07, 0.31, 0.79, 0.99):
                origin = phase * step_size
                t = origin
                for boundary in (0.09, 0.13, 0.6, 0.99):
                    remaining = max(boundary - t, 0)
                    skipped_steps = max(math.ceil(remaining / step_size), 1)
                    t += (skipped_steps - 1) * step_size
                    t += step_size  # Loop increment also applies after continue.
                    sample_index = (t - origin) / step_size
                    self.assertAlmostEqual(sample_index, round(sample_index), places=7)
                    self.assertGreaterEqual(t + 1e-12, boundary)
                    self.assertLess(t, boundary + step_size + 1e-12)

    def test_jitter_is_not_erased_at_the_first_nonempty_brick(self):
        step_size, boundary = 0.01, 0.5
        samples = []
        for phase in (0.1, 0.9):
            t = phase * step_size
            skipped_steps = math.ceil((boundary - t) / step_size)
            samples.append(t + skipped_steps * step_size)
        self.assertAlmostEqual(samples[1] - samples[0], 0.8 * step_size)
        self.assertTrue(all(sample > boundary for sample in samples))


if __name__ == "__main__":
    unittest.main()
