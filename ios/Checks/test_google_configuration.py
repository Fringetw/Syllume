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
            {"CFBundleURLName": "Folia Spotify Login", "CFBundleURLSchemes": ["folia-spotify"]}]}))

    def test_configured_rebuild_and_clear_preserve_other_platforms(self):
        for _ in range(2):
            result = module.configure(self.plist, self.config,
                "123-test.apps.googleusercontent.com", "tw.fringe.folia.ios", require=True)
            info = plistlib.loads(self.plist.read_bytes())
            self.assertTrue(result["google_configured"])
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


if __name__ == "__main__":
    unittest.main()
