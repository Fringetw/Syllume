"""Verify the unsigned iPhone package against the checked-out release sources."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import zipfile

repo = Path(__file__).resolve().parents[2]
ipa = Path(sys.argv[1]).resolve()
project = (repo / "ios/Folia.xcodeproj/project.pbxproj").read_text()
versions = set()
for settings in re.findall(r"buildSettings\s*=\s*\{(.*?)\};", project, re.S):
    if re.search(r'INFOPLIST_FILE\s*=\s*"?Folia/Resources/Info\.plist"?\s*;', settings):
        version = re.search(r"MARKETING_VERSION\s*=\s*([0-9.]+)\s*;", settings)
        build = re.search(r"CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)\s*;", settings)
        assert version and build, "Missing application version"
        versions.add((version[1], build[1]))
assert len(versions) == 1, "Application configurations disagree on version"
expected_version, expected_build = versions.pop()
source_info = plistlib.loads((repo / "ios/Folia/Resources/Info.plist").read_bytes())
entries = subprocess.check_output(
    ["git", "-C", str(repo), "ls-tree", "-r", "HEAD", "ios/Folia/Resources"], text=True
).splitlines()
resources = []
for line in entries:
    fields, path = line.split("\t", 1)
    mode, kind, sha = fields.split()
    if path.endswith("Info.plist") or "/Assets.xcassets/" in path:
        continue
    assert kind == "blob"
    resources.append((path.removeprefix("ios/Folia/Resources/"), sha))
assert len(resources) >= 12, "Incomplete source resource manifest"

with zipfile.ZipFile(ipa) as app:
    prefix = "Payload/Folia.app/"
    names = app.namelist()
    assert len(names) == len(set(names)), "Duplicate package paths"
    info = plistlib.loads(app.read(prefix + "Info.plist"))
    assert info["CFBundleShortVersionString"] == expected_version
    assert info["CFBundleVersion"] == expected_build
    assert info["MinimumOSVersion"] == "17.0"
    assert info["UIFileSharingEnabled"] is True
    assert info["LSSupportsOpeningDocumentsInPlace"] is True
    assert "audio" in info["UIBackgroundModes"]
    for path, sha in resources:
        data = app.read(prefix + path)
        blob = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
        assert hashlib.sha1(blob).hexdigest() == sha, "Source resource mismatch: " + path
    binary = app.read(prefix + info["CFBundleExecutable"])
    assert struct.unpack("<II", binary[:8]) == (0xFEEDFACF, 0x0100000C), "Expected iPhone ARM64"
    for flag in (b"--youtube-playback-fixture", b"--playlist-sync-fixture", b"--playlist-sync-reset"):
        assert flag not in binary, "Debug fixture in Release"
    assert not any("/_CodeSignature/" in name for name in names), "Expected unsigned package"
    for key in ("FoliaGoogleClientID", "FoliaGoogleBundleID", "CFBundleURLTypes"):
        assert info[key] == source_info[key], "Google login configuration changed: " + key
    assert info["FoliaGoogleClientID"] and info["FoliaGoogleBundleID"]
    schemes = [scheme for item in info["CFBundleURLTypes"] for scheme in item.get("CFBundleURLSchemes", [])]
    assert ".".join(reversed(info["FoliaGoogleClientID"].split("."))) in schemes
    assert "folia-spotify" in schemes

print(json.dumps({
    "version": expected_version,
    "build": expected_build,
    "source_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
    "arm64": True,
    "minimum_ios": info["MinimumOSVersion"],
    "files_access_enabled": True,
    "verified_resources": len(resources),
    "debug_fixtures_absent": True,
    "google_configuration_matches_source": True,
    "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
}))
