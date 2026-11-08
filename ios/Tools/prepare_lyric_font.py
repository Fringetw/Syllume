#!/usr/bin/env python3
"""Prepare the unmodified JP Medium face for the offline iOS resource folder."""

import hashlib
from pathlib import Path
import tempfile
import urllib.request

FONT = "GenSenRounded2JP-M.otf"
SIZE = 15_956_876
SHA256 = "9b836915a7da58317fd8002a33d7bb75cb4ae397294850a4ec917527bce0120c"
URL = (
    "https://raw.githubusercontent.com/ButTaiwan/gensen-font/"
    "6107da89595059ea2d9a4ff15db240b0a086a98a/otf/JP/" + FONT
)


def verified(data: bytes) -> bool:
    return len(data) == SIZE and hashlib.sha256(data).hexdigest() == SHA256


def main() -> None:
    destination = Path(__file__).resolve().parents[1] / "Folia" / "Resources" / "FoliaStage" / FONT
    if destination.is_file() and destination.stat().st_size == SIZE and verified(destination.read_bytes()):
        print("Verified bundled lyric font:", FONT)
        return

    with urllib.request.urlopen(URL, timeout=30) as response:
        data = response.read(SIZE + 1)
    if not verified(data):
        raise SystemExit("The lyric font did not match the pinned upstream size and SHA-256.")

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        temporary.chmod(0o644)
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Prepared bundled lyric font:", FONT)


if __name__ == "__main__":
    main()
