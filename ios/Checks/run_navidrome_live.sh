#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "${RUNNER_OS:-}" != macOS || "$(uname -s)" != Darwin ]]; then
    echo "Run the Navidrome integration check on a GitHub-hosted macOS runner." >&2
    exit 1
fi

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=0.64.2
case "$(uname -m)" in
    arm64) architecture=arm64; release_digest=8b0a7798001453719ad50c12f7025a6044546c4a3568efe51feb296681f29956 ;;
    x86_64) architecture=amd64; release_digest=bc872847dcd1c0d760bb9b8730f2a3c876e0ff0679e5440755c37697f2804a23 ;;
    *) echo "Unsupported macOS architecture." >&2; exit 1 ;;
esac

umask 077
work_dir="$(mktemp -d "${RUNNER_TEMP:?}/syllume-navidrome.XXXXXX")"
server_pid=""
simulator_id=""
simulator_evidence=""
export_simulator_evidence() {
    [[ -n "$simulator_evidence" ]] || return 0
    mkdir -p "$simulator_evidence" || return 0
    local result="${RUNNER_TEMP:?}/SyllumeNavidromePlayback.xcresult"
    if [[ -d "$result" ]]; then
        xcrun xcresulttool get test-results summary --path "$result" \
            >"$work_dir/test-summary.json" || true
        xcrun xcresulttool export attachments --path "$result" \
            --output-path "$work_dir/SimulatorAttachments" || true
    fi
    if [[ -n "$simulator_id" ]]; then
        xcrun simctl spawn "$simulator_id" log show --last 20m --style compact \
            --predicate 'process == "Syllume" AND eventMessage CONTAINS "Syllume native transport:"' \
            >"$work_dir/native-transport.log" 2>/dev/null || true
    fi
    SYLLUME_REDACT_PASSWORD="${password:-}" python3 - "$work_dir" "$simulator_evidence" <<'PY' || true
import json, os, pathlib, re, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
password = os.environ.get("SYLLUME_REDACT_PASSWORD", "")

def sanitized(text):
    if password:
        text = text.replace(password, "<redacted>")
    text = re.sub(r"(?im)^.*(?:TEST_RUNNER_)?SYLLUME_NAVIDROME_(?:URL|USER|PASSWORD).*$",
                  "<Navidrome test environment redacted>", text)
    text = re.sub(r"\badmin\b", "<redacted-user>", text)
    return re.sub(r"(?i)([?&](?:u|t|s|password|token)=)[^&\s\"'<>]+", r"\1<redacted>", text)

def sanitized_json(value):
    if isinstance(value, str):
        return sanitized(value)
    if isinstance(value, list):
        return [sanitized_json(item) for item in value]
    if isinstance(value, dict):
        return {key: sanitized_json(item) for key, item in value.items()}
    return value

for name in ["test-summary.json", "xcodebuild.log", "server.log", "native-transport.log"]:
    path = source / name
    if path.is_file():
        content = path.read_text(errors="replace")
        if name.endswith(".json") and content:
            content = json.dumps(sanitized_json(json.loads(content)), indent=2, ensure_ascii=False)
        else:
            content = sanitized(content)
        (destination / name).write_text(content, encoding="utf-8")
screenshots = {"Syllume-Navidrome-confirmed-timeout", "Syllume-Navidrome-confirmed-retry"}
private_attachments = source / "SimulatorAttachments"
for manifest in private_attachments.rglob("manifest.json"):
    for test in json.loads(manifest.read_text()):
        if not test.get("testIdentifier", "").endswith("testLiveNavidromeResumesAtConfirmedTimeAfterTimeout()"):
            continue
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            expected = next((item for item in screenshots if name.startswith(item + "_")), None)
            filename = attachment.get("exportedFileName", "")
            if expected and pathlib.Path(filename).name == filename and filename.lower().endswith(".png"):
                image = manifest.parent / filename
                if image.is_file():
                    shutil.copyfile(image, destination / (expected + ".png"))
PY
}
cleanup() {
    local status=$?
    export_simulator_evidence || true
    if [[ -n "$simulator_id" ]]; then
        xcrun simctl shutdown "$simulator_id" 2>/dev/null || true
        xcrun simctl delete "$simulator_id" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_dir"
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release="navidrome_${version}_darwin_${architecture}.tar.gz"
echo "Downloading Navidrome v$version for macOS $architecture."
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --output "$work_dir/$release" \
    "https://github.com/navidrome/navidrome/releases/download/v$version/$release"
(
    cd "$work_dir"
    printf '%s  %s\n' "$release_digest" "$release" | shasum -a 256 -c -
    tar -xzf "$release" navidrome
)

if ! command -v ffmpeg >/dev/null; then
    echo "Installing ffmpeg on the runner."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install ffmpeg
fi
echo "Preparing the three Navidrome library recordings."
ffmpeg_path="$(command -v ffmpeg)"
mkdir "$work_dir/music" "$work_dir/data"
exact="$work_dir/music/exact.m4a"
make_recording() {
    "$ffmpeg_path" -hide_banner -loglevel error -nostdin \
        -i "$ios_dir/Syllume/Resources/tide.m4a" -map 0:a:0 -map_metadata -1 -c:a copy \
        -metadata "title=$1" -metadata "artist=$2" -metadata "album=$3" \
        -movflags +faststart "$4"
}
make_recording '潮汐之間' 'Syllume Fixture' 'Syllume Originals' "$exact"
make_recording '潮汐之間' 'Other Performer' 'Other Recordings' "$work_dir/music/wrong-performer.m4a"
make_recording '潮汐之間 (Live)' 'Syllume Fixture' 'Syllume Live' "$work_dir/music/live-version.m4a"

echo "Compiling the Swift Navidrome integration probe."
xcrun swiftc -swift-version 6 -D SYLLUME_LIVE_NAVIDROME "$ios_dir"/Syllume/Core/*.swift \
    "$ios_dir/Syllume/Library/NavidromeClient.swift" \
    "$ios_dir/Syllume/Library/AudioIntegrity.swift" \
    "$ios_dir/Syllume/YouTubeSync/AudioDownloadService.swift" \
    "$ios_dir/Checks/Live/NavidromeLiveProbe.swift" -o "$work_dir/navidrome-live-probe"

echo "Generating the loopback HTTPS certificate."
cat > "$work_dir/ca.cnf" <<'EOF'
[req]
distinguished_name = subject
[subject]
[ca_extensions]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
cat > "$work_dir/leaf.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -subj "/CN=Syllume Navidrome CI ${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}" \
    -config "$work_dir/ca.cnf" -extensions ca_extensions \
    -keyout "$work_dir/ca.key" -out "$work_dir/ca.pem" 2>"$work_dir/tls.log"
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj /CN=localhost \
    -config "$work_dir/ca.cnf" -keyout "$work_dir/server.key" -out "$work_dir/server.csr" 2>>"$work_dir/tls.log"
openssl x509 -req -sha256 -days 2 -in "$work_dir/server.csr" -extfile "$work_dir/leaf.ext" \
    -CA "$work_dir/ca.pem" -CAkey "$work_dir/ca.key" -CAcreateserial \
    -out "$work_dir/server.pem" 2>>"$work_dir/tls.log"
rm -f -- "$work_dir/ca.key"
openssl x509 -in "$work_dir/ca.pem" -outform DER -out "$work_dir/ca.der"
security verify-cert -c "$work_dir/server.pem" -r "$work_dir/ca.pem" -p ssl -s localhost
cat "$work_dir/server.pem" "$work_dir/ca.pem" >"$work_dir/chain.pem"

echo "Starting Navidrome and waiting for its HTTPS listener."
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
password="$(openssl rand -hex 24)"
printf '::add-mask::%s\n' "$password"
server_url="https://localhost:$port"
: > "$work_dir/navidrome.toml"
ND_ADDRESS=127.0.0.1 ND_PORT="$port" ND_MUSICFOLDER="$work_dir/music" ND_DATAFOLDER="$work_dir/data" \
    ND_TLSCERT="$work_dir/chain.pem" ND_TLSKEY="$work_dir/server.key" ND_FFMPEGPATH="$ffmpeg_path" \
    ND_ENABLEEXTERNALSERVICES=false ND_ENABLEDOWNLOADS=true ND_DEVAUTOCREATEADMINPASSWORD="$password" ND_LOGLEVEL=info \
    "$work_dir/navidrome" --configfile "$work_dir/navidrome.toml" >"$work_dir/server.log" 2>&1 &
server_pid=$!

ready=false
for ((attempt = 0; attempt < 25; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
    if curl --fail --silent --noproxy '*' --connect-timeout 1 --max-time 2 --cacert "$work_dir/ca.pem" \
        --output /dev/null "$server_url/"; then
        ready=true
        break
    fi
    sleep 1
done
if [[ "$ready" != true ]]; then
    tail -n 30 "$work_dir/server.log" >&2
    echo "Navidrome v$version did not start on the runner's loopback interface." >&2
    exit 1
fi

echo "LIVE SERVICE: Navidrome v$version over HTTPS using Syllume's demo media on the macOS runner."
SYLLUME_NAVIDROME_URL="$server_url" SYLLUME_NAVIDROME_USER=admin SYLLUME_NAVIDROME_PASSWORD="$password" \
    SYLLUME_NAVIDROME_CA_FILE="$work_dir/ca.der" SYLLUME_NAVIDROME_EXACT_FILE="$exact" \
    "$work_dir/navidrome-live-probe"

if [[ "${SYLLUME_NAVIDROME_SIMULATOR:-}" == 1 ]]; then
    simulator_evidence="${RUNNER_TEMP:?}/SyllumeNavidromePlayback"
    mkdir -p "$simulator_evidence"
    echo "Preparing the production Navidrome playback path on a disposable iOS 26 simulator."
    python3 "$ios_dir/Tools/prepare_lyric_font.py"
    selection="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, group in devices.items():
    if "iOS-26" not in runtime:
        continue
    for device in group:
        if device["name"].startswith("iPhone") and device.get("deviceTypeIdentifier"):
            print(device["deviceTypeIdentifier"], runtime)
            sys.exit(0)
sys.exit("No available iOS 26 iPhone runtime and device type")
')"
    read -r device_type runtime <<<"$selection"
    simulator_id="$(xcrun simctl create "Syllume Navidrome ${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}" "$device_type" "$runtime")"
    xcrun simctl boot "$simulator_id"
    xcrun simctl bootstatus "$simulator_id" -b
    xcrun simctl keychain "$simulator_id" add-root-cert "$work_dir/ca.pem"

    echo "LIVE PLAYBACK: the app uses the trusted Navidrome HTTPS service and normal AVPlayer."
    status=0
    TEST_RUNNER_SYLLUME_NAVIDROME_URL="$server_url" TEST_RUNNER_SYLLUME_NAVIDROME_USER=admin \
        TEST_RUNNER_SYLLUME_NAVIDROME_PASSWORD="$password" \
        xcodebuild -project "$ios_dir/Syllume.xcodeproj" -scheme Syllume -configuration Debug \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        -derivedDataPath "$work_dir/SimulatorBuild" \
        -resultBundlePath "${RUNNER_TEMP:?}/SyllumeNavidromePlayback.xcresult" \
        -only-testing:SyllumeUITests/SyllumeUITests/testLiveNavidromeResumesAtConfirmedTimeAfterTimeout \
        -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test \
        >"$work_dir/xcodebuild.log" 2>&1 || status=$?
    if [[ "$status" == 0 ]]; then
        xcrun xcresulttool get test-results summary --path "$RUNNER_TEMP/SyllumeNavidromePlayback.xcresult" \
            >"$work_dir/test-summary.json"
        if ! python3 - "$work_dir/test-summary.json" <<'PY'
import json, sys
with open(sys.argv[1]) as report:
    result = json.load(report)
sys.exit(0 if result.get("passedTests") == 1 and result.get("failedTests") == 0 and result.get("skippedTests") == 0 else 1)
PY
        then
            echo "The Navidrome simulator test must run and pass without skipping."
            status=1
        fi
    fi
    echo "Navidrome simulator XCTest finished with status $status; evidence is exported on exit."
    exit "$status"
fi
