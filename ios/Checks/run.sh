#!/usr/bin/env bash
set -euo pipefail

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
python3 "$ios_dir/Tools/prepare_lyric_font.py"
node --test "$ios_dir"/SubtitleEngine/test/*.test.mjs "$ios_dir"/Visualizer/test/*.test.mjs
python3 -m unittest discover -s "$ios_dir/Checks" -p 'test_*.py'
swiftc -swift-version 6 "$ios_dir"/Syllume/Core/*.swift "$ios_dir"/Syllume/YouTube/YouTubePlayback.swift \
    "$ios_dir"/Syllume/Library/AudioIntegrity.swift "$ios_dir"/Syllume/YouTubeSync/AudioDownloadService.swift "$ios_dir"/Syllume/Library/NavidromeClient.swift \
    "$ios_dir"/Syllume/Subtitles/SubtitleProviders.swift "$ios_dir"/Syllume/Subtitles/NativeSubtitleConverter.swift \
    "$ios_dir"/Syllume/Library/OnlineLyrics.swift "$ios_dir"/Checks/*.swift -o "$check_dir/checks"
"$check_dir/checks" "$ios_dir"
