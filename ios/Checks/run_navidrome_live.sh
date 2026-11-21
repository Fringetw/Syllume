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
system_keychain=/Library/Keychains/System.keychain
server_pid=""
certificate_hash=""
cleanup() {
    local status=$?
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$certificate_hash" ]]; then
        if ! sudo -n security remove-trusted-cert -d "$work_dir/ca.pem"; then status=1; fi
        if ! sudo -n security delete-certificate -Z "$certificate_hash" "$system_keychain"; then status=1; fi
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release="navidrome_${version}_darwin_${architecture}.tar.gz"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --output "$work_dir/$release" \
    "https://github.com/navidrome/navidrome/releases/download/v$version/$release"
(
    cd "$work_dir"
    printf '%s  %s\n' "$release_digest" "$release" | shasum -a 256 -c -
    tar -xzf "$release" navidrome
)

if ! command -v ffmpeg >/dev/null; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install ffmpeg
fi
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

xcrun swiftc -swift-version 6 "$ios_dir"/Syllume/Core/*.swift \
    "$ios_dir/Syllume/Library/NavidromeClient.swift" \
    "$ios_dir/Syllume/Library/AudioIntegrity.swift" \
    "$ios_dir/Syllume/YouTubeSync/AudioDownloadService.swift" \
    "$ios_dir/Checks/Live/NavidromeLiveProbe.swift" -o "$work_dir/navidrome-live-probe"

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
certificate_hash="$(openssl x509 -in "$work_dir/ca.pem" -outform der | shasum -a 1 | cut -d ' ' -f 1)"
sudo -n security add-trusted-cert -d -r trustRoot -p ssl -k "$system_keychain" "$work_dir/ca.pem"

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
password="$(openssl rand -hex 24)"
printf '::add-mask::%s\n' "$password"
server_url="https://127.0.0.1:$port"
: > "$work_dir/navidrome.toml"
ND_ADDRESS=127.0.0.1 ND_PORT="$port" ND_MUSICFOLDER="$work_dir/music" ND_DATAFOLDER="$work_dir/data" \
    ND_TLSCERT="$work_dir/server.pem" ND_TLSKEY="$work_dir/server.key" ND_FFMPEGPATH="$ffmpeg_path" \
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
    SYLLUME_NAVIDROME_EXACT_FILE="$exact" "$work_dir/navidrome-live-probe"
