#!/usr/bin/env python3
"""Prepare one local movie for the watch library and upload it.

1. Re-mux to a standard MP4 (moov first, one mdat) with no re-encode. The originals have thousands
   of separate mdat boxes, which Roku walks one range request at a time and never finishes opening.
2. Build the Roku seek-preview file (BIF), one frame every 10 seconds.
3. Upload both, plus a sidecar .srt as WebVTT when there is one.

Usage: WATCH_KEY=... prepare-title.py <local file> <item id> [--dry]
Needs ffmpeg and ffprobe. Nothing is uploaded with --dry.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BASE = "https://watch.cornerstonecoatings.com"
PART = 8 * 1024 * 1024
BIF_INTERVAL = 10  # seconds per preview frame


def run(*cmd):
    subprocess.run(cmd, check=True)


def duration(path):
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path]
    )
    return float(out.strip())


def mdat_count(path):
    """Count top-level mdat boxes (a standard file has one or two)."""
    size = os.path.getsize(path)
    n = off = 0
    with open(path, "rb") as f:
        while off < size:
            f.seek(off)
            head = f.read(8)
            if len(head) < 8:
                break
            box_size, kind = struct.unpack(">I4s", head)
            if box_size == 1:
                box_size = struct.unpack(">Q", f.read(8))[0]
            if box_size == 0:
                box_size = size - off
            if kind == b"mdat":
                n += 1
            off += box_size
    return n


def remux(src, dst):
    run("ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src, "-map", "0", "-c", "copy", "-movflags", "+faststart", dst)
    a, b = duration(src), duration(dst)
    if abs(a - b) > 1.0:
        raise SystemExit(f"remux changed the length: {a:.1f}s -> {b:.1f}s")
    if mdat_count(dst) > 2:
        raise SystemExit("remux still has many mdat boxes")


def make_bif(src, dst, work):
    frames = os.path.join(work, "frames")
    os.makedirs(frames, exist_ok=True)
    # Keyframes only: fast, and fps=1/N keeps the spacing even for the BIF index.
    run(
        "ffmpeg", "-nostdin", "-v", "error", "-y", "-skip_frame", "nokey", "-i", src, "-an", "-sn",
        "-vf", f"fps=1/{BIF_INTERVAL},scale=320:-2", "-q:v", "6", os.path.join(frames, "%06d.jpg"),
    )
    names = sorted(os.listdir(frames))
    if not names:
        raise SystemExit("no preview frames were produced")
    images = [open(os.path.join(frames, n), "rb").read() for n in names]
    table = 64 + 8 * (len(images) + 1)
    out = bytearray(b"\x89BIF\r\n\x1a\n")
    out += struct.pack("<III", 0, len(images), BIF_INTERVAL * 1000)
    out += bytes(64 - len(out))
    offset = table
    for i, img in enumerate(images):
        out += struct.pack("<II", i, offset)
        offset += len(img)
    out += struct.pack("<II", 0xFFFFFFFF, offset)
    for img in images:
        out += img
    open(dst, "wb").write(out)
    return len(images)


def call(method, path, key, body=None, ctype=None):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    if ctype:
        req.add_header("Content-Type", ctype)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as res:
                return json.loads(res.read() or b"{}")
        except urllib.error.HTTPError as e:
            if e.code < 500:
                raise SystemExit(f"{method} {path} -> {e.code} {e.read()[:200]!r}")
        except OSError:
            pass
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"{method} {path} failed after retries")


def upload_video(path, item, key):
    size = os.path.getsize(path)
    call("POST", f"/v1/items/{item}/replace", key, json.dumps({"byteSize": size}).encode(), "application/json")
    with open(path, "rb") as f:
        n = 1
        while True:
            chunk = f.read(PART)
            if not chunk:
                break
            call("PUT", f"/v1/items/{item}/parts/{n}", key, chunk, "application/octet-stream")
            n += 1
    call("POST", f"/v1/items/{item}/replace/complete", key, json.dumps({"byteSize": size}).encode(), "application/json")


def sidecar_srt(src):
    stem = os.path.splitext(src)[0]
    for cand in (stem + ".en.srt", stem + ".srt"):
        if os.path.exists(cand):
            return cand
    return None


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, item = sys.argv[1], sys.argv[2]
    dry = "--dry" in sys.argv
    key = os.environ.get("WATCH_KEY", "")
    if not key and not dry:
        raise SystemExit("WATCH_KEY is not set")
    with tempfile.TemporaryDirectory() as work:
        fixed = os.path.join(work, "movie.mp4")
        t0 = time.time()
        remux(src, fixed)
        print(f"remuxed in {time.time() - t0:.0f}s: {os.path.getsize(src) / 1e6:.0f} MB -> {os.path.getsize(fixed) / 1e6:.0f} MB")
        t0 = time.time()
        bif = os.path.join(work, "trick.bif")
        count = make_bif(src, bif, work)
        print(f"bif in {time.time() - t0:.0f}s: {count} frames, {os.path.getsize(bif) / 1e6:.1f} MB")
        if dry:
            print("dry run: nothing uploaded")
            return
        t0 = time.time()
        upload_video(fixed, item, key)
        print(f"video uploaded in {time.time() - t0:.0f}s")
        call("PUT", f"/v1/items/{item}/bif", key, open(bif, "rb").read(), "application/octet-stream")
        print("bif uploaded")
        srt = sidecar_srt(src)
        if srt:
            vtt = os.path.join(work, "en.vtt")
            run("ffmpeg", "-nostdin", "-v", "error", "-y", "-i", srt, vtt)
            call("PUT", f"/v1/items/{item}/subtitles/en?label=English", key, open(vtt, "rb").read(), "text/vtt")
            print("subtitles uploaded")


if __name__ == "__main__":
    main()
