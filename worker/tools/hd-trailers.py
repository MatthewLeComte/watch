#!/usr/bin/env python3
"""Replace every library trailer with a 1080p H.264 + AAC copy from YouTube.

The stored trailers were saved at 480p and look soft on a TV. This downloads the best 1080p MP4
for each unique trailer_key and PUTs it to the worker, which dedupes titles that share a trailer.
Safe to re-run: a trailer is simply replaced again.

Usage: WATCH_KEY=... hd-trailers.py [--workers 2] [--limit N] [--titles "A|B"]
Needs yt-dlp and ffmpeg.
"""
import glob
import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = "https://watch.cornerstonecoatings.com"
MAX_BYTES = 95 * 1024 * 1024  # one request body must stay under the platform limit
FORMAT = "bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]"


def library(key):
    for attempt in range(5):
        try:
            req = urllib.request.Request(BASE + "/v1/items", headers={"Authorization": f"Bearer {key}"})
            with urllib.request.urlopen(req, timeout=60) as res:
                return json.loads(res.read())["items"]
        except (OSError, ValueError, http.client.HTTPException):
            time.sleep(2 * (attempt + 1))
    raise SystemExit("could not read the library")


def put_trailer(item, path, key):
    data = open(path, "rb").read()
    req = urllib.request.Request(f"{BASE}/v1/items/{item}/trailer", data=data, method="PUT")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "video/mp4")
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=600) as res:
                return json.loads(res.read())
        except urllib.error.HTTPError as e:
            if e.code < 500:
                raise RuntimeError(f"upload {e.code} {e.read()[:150]!r}")
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(3 * (attempt + 1))
    raise RuntimeError("upload failed after retries")


def download(yt, work, fmt):
    out = os.path.join(work, "t.%(ext)s")
    subprocess.run(
        ["yt-dlp", "--no-playlist", "-q", "--no-warnings", "-f", fmt, "--merge-output-format", "mp4", "-o", out,
         f"https://www.youtube.com/watch?v={yt}"],
        check=True,
    )
    files = glob.glob(os.path.join(work, "t.*"))
    if not files:
        raise RuntimeError("download produced no file")
    return files[0]


def transcode(src, work):
    """H.264 + AAC at a size that fits one upload; used when the clean format is missing or too big."""
    dst = os.path.join(work, "fallback.mp4")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src, "-vf", "scale=-2:'min(1080,ih)'", "-c:v", "libx264",
         "-crf", "23", "-preset", "veryfast", "-maxrate", "6M", "-bufsize", "12M", "-c:a", "aac", "-b:a", "128k",
         "-movflags", "+faststart", dst],
        check=True,
    )
    return dst


def one(item, yt, key):
    with tempfile.TemporaryDirectory() as work:
        try:
            path = download(yt, work, FORMAT)
        except subprocess.CalledProcessError:
            # Clean 1080p H.264 not offered: take any format up to 1080p and transcode it.
            path = transcode(download(yt, work, "bv*[height<=1080]+ba/b[height<=1080]/b"), work)
        if os.path.getsize(path) > MAX_BYTES:
            path = transcode(path, work)
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            raise RuntimeError(f"{size / 1e6:.0f} MB is over the upload limit")
        res = put_trailer(item, path, key)
        return size, res.get("deduped", 0)


def main():
    flags = sys.argv[1:]
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    workers = int(flags[flags.index("--workers") + 1]) if "--workers" in flags else 2
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0
    only = set(flags[flags.index("--titles") + 1].split("|")) if "--titles" in flags else None

    seen, todo = set(), []
    for it in library(key):
        yt = it.get("trailerKey")
        if not yt or yt in seen:
            continue
        seen.add(yt)
        if only and it["title"] not in only:
            continue
        todo.append((it["id"], yt, it["title"]))
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} unique trailers", flush=True)

    done = failed = 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(one, i, y, key): t for i, y, t in todo}
        for fut in as_completed(jobs):
            try:
                size, dupes = fut.result()
                done += 1
                print(f"[{done + failed}/{len(todo)}] {jobs[fut]}: {size / 1e6:.0f} MB (+{dupes} shared)", flush=True)
            except BaseException as e:
                failed += 1
                print(f"[{done + failed}/{len(todo)}] FAILED {jobs[fut]}: {e}", flush=True)
    print(f"finished: {done} replaced, {failed} failed, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
