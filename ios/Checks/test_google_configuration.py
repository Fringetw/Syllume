import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "Tools/configure_google_oauth.py"
spec = importlib.util.spec_from_file_location("google_config", TOOLS)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GoogleConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plist = Path(self.temp.name) / "Info.plist"
        self.config = Path(self.temp.name) / "GoogleOAuth.xcconfig"
        self.plist.write_bytes(plistlib.dumps({"CFBundleURLTypes": [
            {"CFBundleURLName": "Syllume Spotify Login", "CFBundleURLSchemes": ["folia-spotify"]},
            {"CFBundleURLName": "Folia Google Login", "CFBundleURLSchemes": ["legacy-client"]}]}))

    def test_configured_rebuild_and_clear_preserve_other_platforms(self):
        for _ in range(2):
            result = module.configure(self.plist, self.config,
                "123-test.apps.googleusercontent.com", "tw.fringe.folia.ios", require=True,
                build_bundle_id="tw.fringe.folia.ios")
            info = plistlib.loads(self.plist.read_bytes())
            self.assertTrue(result["google_configured"])
            self.assertEqual(info["CFBundleURLTypes"][-1]["CFBundleURLName"], "Syllume Google Login")
            self.assertEqual(info["FoliaGoogleBundleID"], "tw.fringe.folia.ios")
            self.assertEqual([e["CFBundleURLSchemes"] for e in info["CFBundleURLTypes"]],
                             [["folia-spotify"], ["com.googleusercontent.apps.123-test"]])
            self.assertIn("FOLIA_APP_BUNDLE_ID = tw.fringe.folia.ios", self.config.read_text())
        module.configure(self.plist, self.config, "", "")
        info = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(info["FoliaGoogleClientID"], "")
        self.assertEqual(len(info["CFBundleURLTypes"]), 1)

    def test_invalid_or_partial_configuration_cannot_modify_outputs(self):
        original = self.plist.read_bytes()
        for client, bundle in [("123-test.apps.googleusercontent.com", ""),
                               ("", "tw.fringe.folia"), ("https://example.com", "tw.fringe.folia"),
                               ("123-test.apps.googleusercontent.com", "tw.fringe.folia\nOTHER=1"),
                               ("123-test.apps.googleusercontent.com", "tw.fringe.*")]:
            with self.subTest(client=client, bundle=bundle), self.assertRaises(ValueError):
                module.configure(self.plist, self.config, client, bundle)
            self.assertEqual(original, self.plist.read_bytes())
            self.assertFalse(self.config.exists())

    def test_required_release_cannot_silently_disable_google_login(self):
        with self.assertRaises(ValueError):
            module.configure(self.plist, self.config, "", "", require=True)
        self.assertFalse(self.config.exists())

    def test_sideloading_does_not_put_registered_suffix_back_into_build(self):
        installed_id = module.DEFAULT_BUNDLE_ID + ".TESTTEAM01"
        for _ in range(2):
            result = module.configure(self.plist, self.config,
                "123-test.apps.googleusercontent.com", installed_id)
            self.assertEqual(result["bundle_id"] + ".TESTTEAM01", installed_id)
            self.assertEqual(plistlib.loads(self.plist.read_bytes())["FoliaGoogleBundleID"], installed_id)
            self.assertNotIn("TESTTEAM01", self.config.read_text())

    def test_native_custom_identifier_is_explicit_and_independent(self):
        result = module.configure(self.plist, self.config,
            "123-test.apps.googleusercontent.com", "tw.example.folia",
            build_bundle_id="tw.example.folia")
        self.assertEqual(result["bundle_id"], result["google_bundle_id"])
        self.assertIn("FOLIA_APP_BUNDLE_ID = tw.example.folia", self.config.read_text())

    def test_invalid_build_identifier_cannot_modify_outputs(self):
        original = self.plist.read_bytes()
        for value in ["tw.example.*", "tw.example.folia\nOTHER=1", "https://example.com"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.configure(self.plist, self.config, "", "", build_bundle_id=value)
            self.assertEqual(self.plist.read_bytes(), original)
            self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
