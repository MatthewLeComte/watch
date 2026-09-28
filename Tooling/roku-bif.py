#!/usr/bin/env python3
"""Build a Roku BIF scrub strip from a stored movie and upload it to R2.

One JPEG every 10 seconds, 480x270. The worker serves it at
GET /v1/items/{id}/trick.bif. Playback keeps working when the object is missing.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import subprocess
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT_KEY = ROOT / "ios/Model/Movie.swift"
API = "https://watch.cornerstonecoatings.com"
INTERVAL_S = 10


def library_key() -> str:
    text = SWIFT_KEY.read_text()
    match = re.search(r'static let key = "([0-9a-f]{64})"', text)
    if not match:
        raise SystemExit("library key not found")
    return match.group(1)


def pack_bif(frames: list[bytes]) -> bytes:
    count = len(frames)
    header = struct.pack("<8sIII", b"\x89BIF\r\n\x1a\n", 0, count, 1000)
    header += b"\x00" * 44
    data_start = 64 + (count + 1) * 8
    offset = data_start
    index = bytearray()
    body = bytearray()
    for i, frame in enumerate(frames):
        index += struct.pack("<II", i * INTERVAL_S, offset)
        body += frame
        offset += len(frame)
    index += struct.pack("<II", 0xFFFFFFFF, offset)
    return header + index + body


def catalog(key: str) -> list[dict]:
    request = urllib.request.Request(
        f"{API}/v1/items",
        headers={"Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    rows = payload["items"] if isinstance(payload, dict) else payload
    rows.sort(key=lambda row: row.get("runtimeMin") or 10_000)
    return rows


def object_exists(movie_id: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="roku-bif-head-") as tmp:
        dest = Path(tmp) / "trick.bif"
        result = subprocess.run(
            [
                "npx",
                "wrangler",
                "r2",
                "object",
                "get",
                f"watch/bif/{movie_id}.bif",
                "--remote",
                "--file",
                str(dest),
            ],
            cwd=ROOT / "worker",
            capture_output=True,
            text=True,
        )
        return result.returncode == 0 and dest.stat().st_size > 64


def upload(movie_id: str, path: Path) -> None:
    result = subprocess.run(
        [
            "npx",
            "wrangler",
            "r2",
            "object",
            "put",
            f"watch/bif/{movie_id}.bif",
            "--remote",
            "--content-type",
            "application/octet-stream",
            "--file",
            str(path),
        ],
        cwd=ROOT / "worker",
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "r2 put failed")


def frames_for(movie_id: str, key: str, dest: Path) -> list[bytes]:
    dest.mkdir(parents=True, exist_ok=True)
    url = f"{API}/v1/items/{movie_id}/media?key={key}"
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            url,
            "-map",
            "0:v:0",
            "-vf",
            "fps=1/10,scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2:black",
            "-q:v",
            "12",
            str(dest / "%05d.jpg"),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ffmpeg failed")
    paths = sorted(dest.glob("*.jpg"))
    if not paths:
        raise RuntimeError("no frames")
    return [path.read_bytes() for path in paths]


def build_one(movie_id: str, key: str) -> int:
    with tempfile.TemporaryDirectory(prefix="roku-bif-") as tmp:
        frames = frames_for(movie_id, key, Path(tmp) / "frames")
        blob = pack_bif(frames)
        out = Path(tmp) / "trick.bif"
        out.write_bytes(blob)
        upload(movie_id, out)
        return len(frames)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", help="one movie id")
    parser.add_argument("--limit", type=int, default=0, help="stop after this many new files")
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg missing")
    key = library_key()
    if args.id:
        rows = [{"id": args.id, "title": args.id}]
    else:
        rows = catalog(key)
    made = 0
    for row in rows:
        movie_id = row.get("id")
        if not movie_id:
            continue
        title = row.get("title") or movie_id
        if object_exists(movie_id):
            print(f"skip {title}", flush=True)
            continue
        print(f"build {title}", flush=True)
        count = build_one(movie_id, key)
        print(f"uploaded {title} frames={count}", flush=True)
        made += 1
        if args.limit and made >= args.limit:
            break
    print(f"done new={made}", flush=True)


if __name__ == "__main__":
    main()
