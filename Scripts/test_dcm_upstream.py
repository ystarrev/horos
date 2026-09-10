"""Non-build checks for stock DCMTK and the Horos listener integration."""

import subprocess
import unittest

from test_dcm_extraction import DCMExtractionTests, ROOT


class DCMTKUpstreamTests(DCMExtractionTests):
    def test_dcmtk_has_no_tracked_source_edits(self):
        subprocess.run(["git", "-C", str(ROOT / "DCMTK"), "diff", "--exit-code", "HEAD", "--"],
                       check=True, capture_output=True)

    def test_dependency_script_cannot_reapply_patches(self):
        script = (ROOT / "Horos/Scripts/DCMTK/CMake.sh").read_text()
        self.assertNotIn("git apply", script)
        self.assertNotIn("patch_file", script)
        self.assertIn('git -C "$source_dir" diff --quiet HEAD --', script)
        self.assertFalse(list((ROOT / "Horos/Scripts/DCMTK").rglob("*.patch")))

    def test_listener_is_wired_once(self):
        self.assertEqual(self.target_files("Horos", "PBXSourcesBuildPhase").count(
            "HorosQueryRetrieveServer.cpp"), 1)
        listener = (ROOT / "Horos/Sources/DCMTKQueryRetrieveSCP.mm").read_text()
        self.assertIn("new HorosQueryRetrieveServer(", listener)
        self.assertNotIn("new DcmQueryRetrieveSCP(", listener)
        self.assertIn('"dcmtk.dcmqrdb.progress"', listener)
        self.assertIn('objectForKey:@"TLSEnabled"', listener)

    def test_standard_services_still_use_dcmtk(self):
        source = (ROOT / "Horos/Sources/HorosQueryRetrieveServer.cpp").read_text()
        for service in ("Find", "Move", "Store"):
            self.assertIn(f"DcmQueryRetrieve{service}Context", source)
            self.assertIn(f"DIMSE_{service.lower()}Provider(", source)
        for public_api in ("public DcmThreadSCP", "DcmSCP::handleAssociation()",
                           "DIMSE_getProvider(", "DIMSE_storeUser(", "chooseRepresentation(",
                           "ASC_setParentProcessMode("):
            self.assertIn(public_api, source)
        self.assertNotIn("DcmQueryRetrieveGetContext", source)
        self.assertNotIn("#define private", source)

    def test_cget_only_reads_source_files(self):
        source = (ROOT / "Horos/Sources/HorosQueryRetrieveServer.cpp").read_text()
        get_source = source.split("struct GetSource", 1)[1].split("void findCallback", 1)[0]
        self.assertIn("lock(path, false)", get_source)
        self.assertIn("ASC_SC_ROLE_SCP", get_source)
        self.assertIn("ASC_SC_ROLE_SCUSCP", get_source)
        self.assertIn("getOriginalXfer()", get_source)
        self.assertIn("source.datasetToSend ? NULL : path", get_source)
        for write_api in ("saveFile(", "deleteFile(", "unlink(", "rename("):
            self.assertNotIn(write_api, get_source)

    def test_child_cleanup_only_waits_for_listener_workers(self):
        source = (ROOT / "Horos/Sources/HorosQueryRetrieveServer.cpp").read_text()
        self.assertIn("waitpid(process.id, &status, WNOHANG)", source)
        self.assertNotIn("waitpid(-1,", source)
        self.assertNotIn("DcmQueryRetrieveProcessTable", source)

    def test_native_fixture_exists_without_joining_app_target(self):
        self.assertTrue((ROOT / "Scripts/tests/HorosQueryRetrieveTests.cpp").is_file())
        self.assertNotIn("HorosQueryRetrieveTests.cpp", self.target_files("Horos", "PBXSourcesBuildPhase"))


if __name__ == "__main__":
    unittest.main()
