#!/usr/bin/env bash
set -euo pipefail

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 "$ios_dir"/Folia/Core/*.swift "$ios_dir/Checks/Checks.swift" -o "$check_dir/checks"
"$check_dir/checks" "$ios_dir"
