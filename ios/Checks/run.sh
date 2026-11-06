#!/usr/bin/env bash
set -euo pipefail

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d)"
audio_server_pid=""
trap 'if [ -n "$audio_server_pid" ]; then kill "$audio_server_pid" 2>/dev/null || true; fi; rm -rf "$check_dir"' EXIT
node --test "$ios_dir"/SubtitleEngine/test/*.test.mjs "$ios_dir"/Visualizer/test/*.test.mjs
python3 -m unittest discover -s "$ios_dir/Checks" -p 'test_*.py'
python3 "$ios_dir/Checks/audio_server.py" --port-file "$check_dir/audio-port" --audio "$ios_dir/Folia/Resources/tide.m4a" &
audio_server_pid=$!
for attempt in {1..200}; do
    if [ -s "$check_dir/audio-port" ]; then break; fi
    if ! kill -0 "$audio_server_pid" 2>/dev/null; then
        echo "Audio fixture server exited before becoming ready" >&2
        exit 1
    fi
    sleep 0.1
done
if [ ! -s "$check_dir/audio-port" ]; then
    echo "Audio fixture server did not become ready" >&2
    exit 1
fi
audio_port="$(cat "$check_dir/audio-port")"
export FOLIA_AUDIO_TEST_URL="http://127.0.0.1:$audio_port"
swiftc -swift-version 6 "$ios_dir"/Folia/Core/*.swift "$ios_dir"/Folia/YouTube/YouTubePlayback.swift \
    "$ios_dir"/Folia/Subtitles/SubtitleProviders.swift "$ios_dir"/Folia/Library/OnlineLyrics.swift \
    "$ios_dir"/Folia/Library/PlaylistAudioTransfer.swift "$ios_dir"/Checks/*.swift -o "$check_dir/checks"
"$check_dir/checks" "$ios_dir"
