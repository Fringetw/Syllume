#!/usr/bin/env bash
set -euo pipefail

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
node --test "$ios_dir"/SubtitleEngine/test/*.test.mjs "$ios_dir"/Visualizer/test/*.test.mjs
python3 -m unittest discover -s "$ios_dir/Checks" -p 'test_*.py'
swiftc -swift-version 6 "$ios_dir"/Folia/Core/*.swift "$ios_dir"/Folia/YouTube/YouTubePlayback.swift \
    "$ios_dir"/Folia/Subtitles/SubtitleProviders.swift "$ios_dir"/Folia/Library/OnlineLyrics.swift "$ios_dir"/Checks/*.swift -o "$check_dir/checks"
"$check_dir/checks" "$ios_dir"
