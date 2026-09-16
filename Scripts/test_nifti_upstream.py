"""Offline pin, project and syntax checks. No build or patient data access."""

import hashlib
import json
import re
import subprocess
import unittest

from test_macos_baseline import ROOT, project_objects


LIBRARY = ROOT / "NIfTI_Library"


class NIfTIUpstreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((LIBRARY / "UPSTREAM.json").read_text())
        cls.objects = project_objects("Horos.xcodeproj/project.pbxproj")
        cls.target = next(obj for obj in cls.objects.values()
                          if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Horos")
        cls.sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()

    def test_pin_uses_an_immutable_revision(self):
        manifest = self.manifest
        self.assertEqual(manifest["repository"], "https://github.com/NIFTI-Imaging/nifti_clib")
        self.assertRegex(manifest["revision"], r"^[0-9a-f]{40}$")
        self.assertEqual(manifest["archive"],
                         "https://codeload.github.com/NIFTI-Imaging/nifti_clib/tar.gz/"
                         + manifest["revision"])
        self.assertRegex(manifest["archive_sha256"], r"^[0-9a-f]{64}$")
        for entry in manifest["files"].values():
            self.assertNotIn("..", entry["upstream_path"].split("/"))
            self.assertFalse(entry["upstream_path"].startswith("/"))

    def test_all_vendored_files_match_upstream_hashes(self):
        expected = {"nifti1.h", "nifti1_io.h", "nifti1_io.c", "nifti1_io_version.h",
                    "znzlib.h", "znzlib.c", "znzlib_version.h", "LICENSE"}
        self.assertEqual(set(self.manifest["files"]), expected)
        self.assertEqual({path.name for path in LIBRARY.iterdir()},
                         expected | {"UPSTREAM.json", "README.horos.md"})
        for filename, entry in self.manifest["files"].items():
            with self.subTest(filename=filename):
                self.assertEqual(hashlib.sha256((LIBRARY / filename).read_bytes()).hexdigest(),
                                 entry["sha256"], "Restore upstream bytes; do not patch the vendor files")

    def test_xcode_keeps_the_nifti1_sources_and_headers(self):
        objects = self.objects
        group = next(obj for obj in objects.values()
                     if obj.get("isa") == "PBXGroup" and obj.get("path") == "NIfTI_Library")
        references = {objects[key]["path"]: key for key in group["children"]}
        self.assertEqual(set(references), set(self.manifest["files"]) |
                         {"UPSTREAM.json", "README.horos.md"})
        for phase_type, suffix in (("PBXSourcesBuildPhase", ".c"), ("PBXHeadersBuildPhase", ".h")):
            build_files = [objects[key] for phase_id in self.target["buildPhases"]
                           if objects[phase_id]["isa"] == phase_type
                           for key in objects[phase_id]["files"]]
            for filename, reference in references.items():
                if filename.endswith(suffix):
                    with self.subTest(filename=filename):
                        matches = [item for item in build_files if item["fileRef"] == reference]
                        self.assertEqual(len(matches), 1)
                        self.assertNotIn("COMPILER_FLAGS", matches[0].get("settings", {}))
        self.assertNotIn("nifti2_io.c", str(objects))

    def syntax_check(self, args, source=None):
        result = subprocess.run(
            ["xcrun", "clang", "-fsyntax-only", "-target", "arm64-apple-macos27.0",
             "-isysroot", self.sdk, "-I", str(LIBRARY), *args],
            input=source, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_upstream_c_sources_parse_with_project_definitions(self):
        for definition in ("DEBUG=1", "NDEBUG"):
            with self.subTest(definition=definition):
                self.syntax_check(["-std=c11", "-D" + definition,
                                   "-include", str(ROOT / "Horos/prefix.pch"),
                                   str(LIBRARY / "nifti1_io.c"), str(LIBRARY / "znzlib.c")])

    def test_consumer_api_and_nifti1_layout(self):
        source = r'''
#include <stddef.h>
#include "nifti1_io.h"
#ifdef __cplusplus
#define CHECK static_assert
#else
#define CHECK _Static_assert
#endif
CHECK(sizeof(nifti_1_header) == 348, "NIfTI-1 header size");
CHECK(sizeof(nifti_analyze75) == 348, "Analyze header size");
CHECK(offsetof(nifti_1_header, magic) == 344, "NIfTI-1 magic offset");
CHECK(offsetof(nifti_1_header, scl_slope) == 112, "scaling offset");
CHECK(offsetof(nifti_1_header, qform_code) == 252, "orientation offset");
CHECK(sizeof(mat44) == 16 * sizeof(float), "single-precision NIfTI-1 transforms");
void horos_nifti_api(const char *path) {
    nifti_1_header *header = nifti_read_header(path, NULL, 0);
    nifti_image *image = nifti_image_read(path, 1);
    int width = header->dim[1], height = header->dim[2], slices = header->dim[3];
    float dx = header->pixdim[1], dy = header->pixdim[2], dz = header->pixdim[3];
    size_t bytes = image->nvox * image->nbyper;
    void *data = image->data;
    int i = 0, j = 0, k = 0;
    nifti_mat44_to_orientation(image->qto_xyz, &i, &j, &k);
    nifti_mat44_to_orientation(image->sto_xyz, &i, &j, &k);
    int directions[] = {NIFTI_L2R, NIFTI_R2L, NIFTI_P2A, NIFTI_A2P, NIFTI_I2S, NIFTI_S2I};
    char *ascii = nifti_image_to_ascii(image);
    nifti1_extension *extension = image->ext_list;
    int count = image->num_ext, code = extension->ecode;
    char *extensionData = extension->edata;
    free(ascii);
    nifti_image_free(image);
    free(header);
}
'''
        for language, standard in (("c", "c11"), ("objective-c", "c11"),
                                   ("objective-c++", "c++17")):
            with self.subTest(language=language):
                self.syntax_check(["-Werror", "-x", language, "-std=" + standard, "-"], source)

    def test_all_horos_nifti_function_calls_are_declared(self):
        calls = set()
        for filename in ("DicomFile.mm", "DCMPix.m"):
            source = (ROOT / "Horos/Sources" / filename).read_text()
            self.assertIn('#include "nifti1_io.h"', source)
            calls.update(re.findall(r"\b(nifti_\w+)\s*\(", source))
        header = (LIBRARY / "nifti1_io.h").read_text()
        self.assertTrue(calls)
        for call in calls:
            self.assertRegex(header, rf"\b{call}\s*\(")


if __name__ == "__main__":
    unittest.main()
