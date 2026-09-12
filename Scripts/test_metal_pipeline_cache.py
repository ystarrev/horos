"""Metal pipeline source/configuration guards; no build, GPU run, or patient data."""

from pathlib import Path
import re
import unittest

from test_macos_baseline import project_objects


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Horos/Sources/MetalViewer"
CACHE = (SOURCES / "MetalPipelineCache.swift").read_text()
CONSUMERS = (
    "MetalViewerRenderer.swift", "MetalViewerScoutView.swift", "MetalPreviewImageView.swift",
    "Metal3DVolumeRenderer.swift", "MetalViewerModels.swift", "MetalStudyROI.swift",
)


def render_configurations(filename):
    source = (SOURCES / filename).read_text()
    configurations = {}
    for variable, arguments in re.findall(
        r"\b(\w+)\s*=\s*try\??\s+pipelines\.renderPipeline\((.*?)\)", source, re.S
    ):
        values = dict(re.findall(r'(\w+):\s*("[^"]*"|[\w.]+)', arguments))
        values = {key: value.strip('"') for key, value in values.items()}
        configurations[variable] = {
            "colorPixelFormat": ".bgra8Unorm", "depthPixelFormat": ".invalid",
            "sampleCount": "1", "alphaBlending": "false", **values,
        }
    return configurations


class MetalPipelineCacheTests(unittest.TestCase):
    def test_shared_cache_is_wired_into_the_horos_target_once(self):
        objects = project_objects("Horos.xcodeproj/project.pbxproj")
        references = [key for key, obj in objects.items()
                      if obj.get("isa") == "PBXFileReference"
                      and obj.get("path") == "Horos/Sources/MetalViewer/MetalPipelineCache.swift"]
        self.assertEqual(len(references), 1)
        self.assertEqual(objects[references[0]]["sourceTree"], "SOURCE_ROOT")
        owners = []
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for phase_id in target["buildPhases"]:
                phase = objects[phase_id]
                if phase["isa"] == "PBXSourcesBuildPhase":
                    for build_id in phase["files"]:
                        if objects[build_id]["fileRef"] == references[0]:
                            owners.append(target["name"])
        self.assertEqual(owners, ["Horos"])

    def test_all_shader_creation_is_centralized_but_queues_remain_local(self):
        for filename in CONSUMERS:
            source = (SOURCES / filename).read_text()
            with self.subTest(consumer=filename):
                self.assertIn("MetalPipelineCache.shared(for: device)", source)
                self.assertIn("device.makeCommandQueue()", source)
        for path in SOURCES.glob("*.swift"):
            if path.name != "MetalPipelineCache.swift":
                self.assertNotRegex(path.read_text(), r"\bmake(?:DefaultLibrary|RenderPipelineState|ComputePipelineState)\(")
        self.assertNotRegex(CACHE, r"\b(?:MTLTexture|MTLBuffer|MTLCommandQueue|DCMPix|MetalStudyROI)\b")

    def test_device_identity_and_all_render_settings_are_part_of_the_key(self):
        self.assertIn("devices: [UInt64: MetalPipelineCache]", CACHE)
        self.assertIn("devices[device.registryID]", CACHE)
        key = CACHE.split("private struct RenderKey: Hashable {", 1)[1].split("\n    }", 1)[0]
        construction = CACHE.split("let key = RenderKey(", 1)[1].split("\n        )", 1)[0]
        for field in ("vertex", "fragment", "colorPixelFormat", "depthPixelFormat", "sampleCount", "alphaBlending"):
            self.assertIn(f"let {field}:", key)
            self.assertIn(f"{field}: {field}", construction)
        self.assertNotIn("label", key)  # Debug labels do not change rendering.

    def test_concurrent_misses_compile_once_and_failures_do_not_poison_cache(self):
        methods = (
            ("static func shared(", "devicesLock", "if let cache = devices[", "try MetalPipelineCache(device: device)", "devices[device.registryID] = cache"),
            ("func renderPipeline(", "lock", "if let pipeline = renderPipelines[", "try device.makeRenderPipelineState", "renderPipelines[key] = pipeline"),
            ("func computePipeline(", "lock", "if let pipeline = computePipelines[", "try device.makeComputePipelineState", "computePipelines[name] = pipeline"),
        )
        for signature, lock, hit, create, insert in methods:
            method = CACHE.split(signature, 1)[1].split("\n    }", 1)[0]
            self.assertIn(f"defer {{ {lock}.unlock() }}", method)
            self.assertLess(method.index(f"{lock}.lock()"), method.index(hit))
            self.assertLess(method.index(hit), method.index(create))
            self.assertLess(method.index(create), method.index(insert))
            self.assertNotIn("catch", method)

    def test_descriptor_defaults_and_transparency_are_unchanged(self):
        for setting in ("colorPixelFormat: MTLPixelFormat = .bgra8Unorm",
                        "depthPixelFormat: MTLPixelFormat = .invalid",
                        "sampleCount: Int = 1", "alphaBlending: Bool = false",
                        "descriptor.colorAttachments[0].pixelFormat = colorPixelFormat",
                        "descriptor.depthAttachmentPixelFormat = depthPixelFormat",
                        "descriptor.rasterSampleCount = sampleCount"):
            self.assertIn(setting, CACHE)
        blend = CACHE.split("if alphaBlending {", 1)[1].split("\n        }", 1)[0]
        for setting in ("isBlendingEnabled = true", "sourceRGBBlendFactor = .sourceAlpha",
                        "destinationRGBBlendFactor = .oneMinusSourceAlpha", "rgbBlendOperation = .add",
                        "sourceAlphaBlendFactor = .one", "destinationAlphaBlendFactor = .oneMinusSourceAlpha",
                        "alphaBlendOperation = .add"):
            self.assertIn("attachment." + setting, blend)

    def test_absent_debug_label_is_not_assigned_to_metal(self):
        self.assertIn("label: String? = nil", CACHE)
        self.assertRegex(
            CACHE,
            r"if let label \{\s*descriptor\.label = label\s*\}",
        )
        self.assertEqual(CACHE.count("descriptor.label ="), 1)

    def test_planar_and_mpr_shader_pairings_preserve_depth_and_blending(self):
        configurations = render_configurations("MetalViewerRenderer.swift")
        expected = {
            "pipelineState": ("metalViewerVertex", "metalViewerFragment", "false"),
            "mprPipelineState": ("metalViewerMPRVertex", "metalViewerMPRFragment", "false"),
            "mprROIPipelineState": ("metalViewerMPRROIVertex", "metalViewerMPRROIFragment", "true"),
            "mprPlaneHighlightPipelineState": ("metalViewerMPRPlaneHighlightVertex", "metalViewerMPRPlaneHighlightFragment", "true"),
            "mprBorderPipelineState": ("metalViewerMPRBorderVertex", "metalViewerMPRBorderFragment", "true"),
            "mprIntersectionPipelineState": ("metalViewerMPRBorderVertex", "metalViewerMPRIntersectionFragment", "true"),
        }
        self.assertEqual(set(configurations), set(expected))
        for name, (vertex, fragment, blend) in expected.items():
            self.assertEqual(configurations[name], {
                "vertex": vertex, "fragment": fragment, "colorPixelFormat": ".bgra8Unorm",
                "depthPixelFormat": ".depth32Float", "sampleCount": "1", "alphaBlending": blend,
            })

    def test_preview_scout_and_volume_formats_do_not_collide(self):
        preview = render_configurations("MetalPreviewImageView.swift")["pipelineState"]
        self.assertEqual(preview["vertex"], "metalPreviewVertex")
        self.assertEqual(preview["fragment"], "metalPreviewFragment")
        self.assertEqual(preview["depthPixelFormat"], ".invalid")
        self.assertEqual(preview["alphaBlending"], "false")
        scout = render_configurations("MetalViewerScoutView.swift")["pipelineState"]
        self.assertEqual(scout["vertex"], "metalViewerScoutROIVertex")
        self.assertEqual(scout["fragment"], "metalViewerScoutROIFragment")
        self.assertEqual(scout["colorPixelFormat"], "view.colorPixelFormat")
        self.assertEqual(scout["depthPixelFormat"], "view.depthStencilPixelFormat")
        self.assertEqual(scout["sampleCount"], "view.sampleCount")
        self.assertEqual(scout["alphaBlending"], "false")
        volume = render_configurations("Metal3DVolumeRenderer.swift")
        for name, vertex, fragment, blend in (
            ("pipelineState", "metal3DVolumeVertex", "metal3DVolumeFragment", "false"),
            ("overlayPipelineState", "metal3DOverlayVertexMain", "metal3DOverlayFragment", "true"),
        ):
            self.assertEqual(volume[name], {
                "vertex": vertex, "fragment": fragment, "colorPixelFormat": ".bgra8Unorm",
                "depthPixelFormat": ".depth32Float", "sampleCount": "1", "alphaBlending": blend,
            })

    def test_requested_functions_exist_and_shared_resampling_uses_one_key(self):
        shaders = "\n".join(path.read_text() for path in SOURCES.glob("*.metal"))
        for filename in CONSUMERS:
            source = (SOURCES / filename).read_text()
            functions = re.findall(r'(?:vertex|fragment|function): "(\w+)"', source)
            self.assertTrue(functions)
            for name in functions:
                self.assertRegex(shaders, r"\b(?:vertex|fragment|kernel)\s+\w+\s+" + name + r"\s*\(")
        for filename in ("MetalViewerModels.swift", "Metal3DVolumeRenderer.swift"):
            self.assertIn('pipelines.computePipeline(function: "metalViewerGantryTiltResample3D")',
                          (SOURCES / filename).read_text())


if __name__ == "__main__":
    unittest.main()
