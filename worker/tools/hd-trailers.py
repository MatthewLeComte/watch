#!/usr/bin/env python3
"""Replace every library trailer with a 1080p H.264 + AAC copy from YouTube.

The stored trailers were saved at 480p and look soft on a TV. This downloads the best 1080p MP4
for each unique trailer_key and PUTs it to the worker, which dedupes titles that share a trailer.
Safe to re-run: a trailer is simply replaced again.

Usage: WATCH_KEY=... hd-trailers.py [--workers 2] [--limit N]
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


def one(item, yt, key):
    with tempfile.TemporaryDirectory() as work:
        out = os.path.join(work, "t.%(ext)s")
        subprocess.run(
            ["yt-dlp", "--no-playlist", "-q", "--no-warnings", "-f", FORMAT, "--merge-output-format", "mp4", "-o", out,
             f"https://www.youtube.com/watch?v={yt}"],
            check=True,
        )
        files = glob.glob(os.path.join(work, "t.*"))
        if not files:
            raise RuntimeError("download produced no file")
        path = files[0]
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

    seen, todo = set(), []
    for it in library(key):
        yt = it.get("trailerKey")
        if not yt or yt in seen:
            continue
        seen.add(yt)
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
