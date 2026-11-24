#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "${RUNNER_OS:-}" != macOS || "$(uname -s)" != Darwin ]]; then
    echo "Run the Navidrome integration check on a GitHub-hosted macOS runner." >&2
    exit 1
fi

delayed_start="${SYLLUME_NAVIDROME_DELAYED_START:-0}"
if [[ "$delayed_start" == 1 && "${SYLLUME_NAVIDROME_SIMULATOR:-}" != 1 ]]; then
    echo "The delayed Navidrome startup check requires the simulator mode." >&2
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
proxy_pid=""
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
import datetime, json, math, os, pathlib, re, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
password = os.environ.get("SYLLUME_REDACT_PASSWORD", "")

def sanitized(text):
    if password:
        text = text.replace(password, "<redacted>")
    text = re.sub(r'(?im)^.*\bType\b.*SecureTextField.*$', "<secure input redacted>", text)
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

for name in ["test-summary.json", "xcodebuild.log", "server.log", "native-transport.log", "delayed-stream-proxy.jsonl"]:
    path = source / name
    if path.is_file():
        content = path.read_text(errors="replace")
        if name.endswith(".json") and content:
            content = json.dumps(sanitized_json(json.loads(content)), indent=2, ensure_ascii=False)
        else:
            content = sanitized(content)
        (destination / name).write_text(content, encoding="utf-8")
player_evidence = {
    "Syllume-Navidrome-confirmed-timeout": ".png",
    "Syllume-Navidrome-confirmed-retry": ".png",
    "Syllume-Navidrome-recovery-samples": ".txt",
    "Syllume-Navidrome-delayed-start": ".png",
    "Syllume-Navidrome-delayed-start-samples": ".txt",
}
private_attachments = source / "SimulatorAttachments"
for manifest in private_attachments.rglob("manifest.json"):
    for test in json.loads(manifest.read_text()):
        if not test.get("testIdentifier", "").endswith(("testLiveNavidromeResumesAtConfirmedTimeAfterTimeout()",
                                                       "testLiveNavidromeStartsAfterDelayedInitialRange()")):
            continue
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            expected = next((item for item in player_evidence if name.startswith(item + "_")), None)
            filename = attachment.get("exportedFileName", "")
            if expected and pathlib.Path(filename).name == filename and filename.lower().endswith(player_evidence[expected]):
                artifact = manifest.parent / filename
                if artifact.is_file():
                    output = destination / (expected + player_evidence[expected])
                    if output.suffix == ".txt":
                        output.write_text(sanitized(artifact.read_text(errors="replace")), encoding="utf-8")
                    else:
                        shutil.copyfile(artifact, output)

paths = ["/rest/getCoverArt", "/rest/getLyricsBySongId", "/rest/getLyrics", "/rest/stream"]
counts = {phase: dict.fromkeys(paths, 0) for phase in ["total", "beforeRetry", "afterRetry", "unknownPhase"]}
samples = destination / "Syllume-Navidrome-recovery-samples.txt"
retry_second = None
if samples.is_file():
    epoch = re.search(r"(?m)^retryEpoch=([0-9]+(?:\.[0-9]+)?)$", samples.read_text())
    if epoch:
        value = float(epoch.group(1))
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        if math.isfinite(value) and 946684800 <= value <= now + 60:
            retry_second = math.floor(value)
offset_file = source / "simulator-log-offset"
server_log = source / "server.log"
if offset_file.is_file() and server_log.is_file():
    offset = int(offset_file.read_text())
    with server_log.open("rb") as logfile:
        partial_line = False
        if offset > 0:
            logfile.seek(offset - 1)
            partial_line = logfile.read(1) != b"\n"
        logfile.seek(offset)
        lines = logfile.read().decode("utf-8", errors="replace").splitlines()
    if partial_line:
        lines = lines[1:]
    request_path = re.compile(r"API: New request (/rest/[A-Za-z0-9]+)(?=[\s\"']|$)")
    timestamp = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})")
    for line in lines:
        request = request_path.search(line)
        if not request or request.group(1) not in paths:
            continue
        path = request.group(1)
        counts["total"][path] += 1
        phase = "unknownPhase"
        stamp = timestamp.search(line)
        if retry_second is not None and stamp:
            try:
                second = math.floor(datetime.datetime.fromisoformat(stamp.group().replace("Z", "+00:00")).timestamp())
                phase = "afterRetry" if second >= retry_second else "beforeRetry"
            except ValueError:
                pass
        counts[phase][path] += 1
(destination / "simulator-request-counts.json").write_text(json.dumps(counts, indent=2) + "\n", encoding="utf-8")
PY
}
cleanup() {
    local status=$?
    export_simulator_evidence || true
    if [[ -n "$simulator_id" ]]; then
        xcrun simctl shutdown "$simulator_id" 2>/dev/null || true
        xcrun simctl delete "$simulator_id" 2>/dev/null || true
    fi
    if [[ -n "$proxy_pid" ]]; then
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
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
if [[ "${SYLLUME_NAVIDROME_SIMULATOR:-}" == 1 ]]; then
    cp "$ios_dir/Syllume/Resources/Assets.xcassets/AppIcon.appiconset/SyllumeIcon.png" "$work_dir/music/cover.png"
    printf '%s\n' '[00:00.00]Navidrome 測試歌詞' >"$work_dir/music/exact.lrc"
fi

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
log_level=info
if [[ "${SYLLUME_NAVIDROME_SIMULATOR:-}" == 1 ]]; then log_level=debug; fi
ND_ADDRESS=127.0.0.1 ND_PORT="$port" ND_MUSICFOLDER="$work_dir/music" ND_DATAFOLDER="$work_dir/data" \
    ND_TLSCERT="$work_dir/chain.pem" ND_TLSKEY="$work_dir/server.key" ND_FFMPEGPATH="$ffmpeg_path" \
    ND_ENABLEEXTERNALSERVICES=false ND_ENABLEDOWNLOADS=true ND_DEVAUTOCREATEADMINPASSWORD="$password" ND_LOGLEVEL="$log_level" \
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
    python3 - "$work_dir/server.log" "$work_dir/simulator-log-offset" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[2]).write_text(str(pathlib.Path(sys.argv[1]).stat().st_size))
PY
    simulator_evidence="${RUNNER_TEMP:?}/SyllumeNavidromePlayback"
    mkdir -p "$simulator_evidence"
    simulator_url="$server_url"
    simulator_test=testLiveNavidromeResumesAtConfirmedTimeAfterTimeout
    if [[ "$delayed_start" == 1 ]]; then
        simulator_test=testLiveNavidromeStartsAfterDelayedInitialRange
        proxy_ready="$work_dir/proxy-ready"
        python3 "$ios_dir/Checks/delayed_navidrome_proxy.py" --upstream-port "$port" \
            --ca "$work_dir/ca.pem" --chain "$work_dir/chain.pem" --key "$work_dir/server.key" \
            --log "$work_dir/delayed-stream-proxy.jsonl" --ready-file "$proxy_ready" &
        proxy_pid=$!
        for ((attempt = 0; attempt < 50; attempt++)); do
            if [[ -s "$proxy_ready" ]]; then break; fi
            if ! kill -0 "$proxy_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if [[ ! -s "$proxy_ready" ]]; then
            echo "The delayed media proxy did not start." >&2
            exit 1
        fi
        read -r simulator_url < "$proxy_ready"
        # Check both TLS legs without requesting media or putting authentication in proxy logs.
        proxy_status="$(curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
            --cacert "$work_dir/ca.pem" --output /dev/null --write-out '%{http_code}' "$simulator_url/rest/ping")"
        case "$proxy_status" in
            200|400|401|403) ;;
            *) echo "The delayed media proxy preflight returned HTTP $proxy_status." >&2; exit 1 ;;
        esac
        echo "LIVE PLAYBACK: first Navidrome audio range body delayed by 12 seconds after the first GET."
    fi
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

    build="$work_dir/SimulatorBuild"
    destination="platform=iOS Simulator,id=$simulator_id"
    echo "LIVE PLAYBACK: the app uses the trusted Navidrome HTTPS service and normal AVPlayer."
    status=0
    TEST_RUNNER_SYLLUME_NAVIDROME_URL="$simulator_url" TEST_RUNNER_SYLLUME_NAVIDROME_USER=admin \
        TEST_RUNNER_SYLLUME_NAVIDROME_PASSWORD="$password" \
        xcodebuild -project "$ios_dir/Syllume.xcodeproj" -scheme Syllume -configuration Debug \
        -destination "$destination" -derivedDataPath "$build" \
        -resultBundlePath "${RUNNER_TEMP:?}/SyllumeNavidromePlayback.xcresult" \
        -only-testing:"SyllumeUITests/SyllumeUITests/$simulator_test" \
        -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test \
        >"$work_dir/xcodebuild.log" 2>&1 || status=$?
    if [[ "$delayed_start" == 1 ]]; then
        if ! python3 - "$work_dir/delayed-stream-proxy.jsonl" "$status" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as evidence:
    events = [json.loads(line) for line in evidence]
releases = [event["elapsedMs"] for event in events if event["event"] == "stream-released"]
body = sum(event["bodyBytes"] for event in events if event["event"] == "stream-body")
print(f"Navidrome delayed start: bulk releases at {releases} ms, completed bulk response bytes={body}")
assert any(event["event"] == "proxy-preflight" and event["status"] in {200, 400, 401, 403} for event in events), "Expected verified loopback HTTPS"
assert any(event["event"] == "stream-gated" for event in events), "Expected AVPlayer to wait for a media body"
assert releases and min(releases) >= 11990, "Expected the shared 12-second delay before releasing a media body"
if sys.argv[2] == "0":
    assert body > 0, "Playback success requires the proxy to send delayed audio bytes"
PY
        then
            status=1
        fi
    fi
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
