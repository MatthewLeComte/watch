#!/usr/bin/env python3
"""Fix every library title one at a time: download it from the library, process it locally, upload, delete.

No drive needed. The library already holds every original, so each title is downloaded from there onto this
Mac's internal disk (resuming if the connection drops), worked on, uploaded back, and the local copy deleted
before the next one starts.

Per title, only what is missing is done:
  - re-mux to a standard MP4 (moov first, one mdat) and replace the stored file, so Roku starts it fast;
  - build the seek-preview (BIF) and upload it.
A title that is already fixed is skipped without being downloaded at all.

Usage: WATCH_KEY=... process-all.py [--limit N] [--reverse] [--only TITLE]
"""
import http.client
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


prep = load("prepare_title", "prepare-title.py")
rmx = load("remux_all", "remux-all.py")
bifs = load("bif_all", "bif-all.py")

MIN_FREE_GB = 25
CHUNK = 8 * 1024 * 1024


def download(item, dst, key):
    """Fetch the stored file to dst, resuming from where it stopped if the connection drops."""
    url = f"{prep.BASE}/v1/items/{item['id']}/media"
    want = item["byteSize"]
    have = 0
    stalls = 0
    with open(dst, "wb") as out:
        while have < want:
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}", "Range": f"bytes={have}-"})
            try:
                with urllib.request.urlopen(req, timeout=120) as res:
                    while True:
                        block = res.read(CHUNK)
                        if not block:
                            break
                        out.write(block)
                        have += len(block)
                        stalls = 0
            except (OSError, http.client.HTTPException, urllib.error.HTTPError):
                stalls += 1
                if stalls > 10:
                    raise RuntimeError(f"download kept failing at {have / 1e6:.0f} MB of {want / 1e6:.0f} MB")
                time.sleep(min(30, 3 * stalls))
    if have != want:
        raise RuntimeError(f"downloaded {have} bytes, expected {want}")


def main():
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0

    items = json.loads(rmx.fetch(prep.BASE + "/v1/items", {"Authorization": f"Bearer {key}"}))["items"]
    # Saved streams are HLS chunks with no single file; everything else has one.
    todo = [i for i in items if not i.get("hlsUrl")]
    if "--only" in sys.argv:
        needle = sys.argv[sys.argv.index("--only") + 1].lower()
        todo = [i for i in todo if needle in i["title"].lower()]
    if "--reverse" in sys.argv:
        todo.reverse()  # a second run from the far end, so two runs meet in the middle
    print(f"{len(todo)} titles in the library", flush=True)

    fixed = skipped = failed = 0
    start = time.time()
    for n, item in enumerate(todo, 1):
        if limit and fixed >= limit:
            break
        try:
            standard = rmx.is_standard(item["id"], item["byteSize"], key)
            has_bif = bifs.has_bif(item["id"], key)
            if standard and has_bif:
                skipped += 1
                continue
            if shutil.disk_usage(tempfile.gettempdir()).free < MIN_FREE_GB * 1e9:
                raise RuntimeError(f"less than {MIN_FREE_GB} GB free on this Mac")
            t0 = time.time()
            with tempfile.TemporaryDirectory() as work:
                local = os.path.join(work, "source.mp4")
                download(item, local, key)
                did = []
                preview_from = local
                if not standard:
                    out = os.path.join(work, "movie.mp4")
                    prep.remux(local, out)
                    os.remove(local)  # free the space before the upload
                    prep.upload_video(out, item["id"], key)
                    preview_from = out
                    did.append("remuxed")
                if not has_bif:
                    bif = os.path.join(work, "trick.bif")
                    frames = prep.make_bif(preview_from, bif, work)
                    prep.call("PUT", f"/v1/items/{item['id']}/bif", key, open(bif, "rb").read(), "application/octet-stream")
                    did.append(f"{frames} previews")
            fixed += 1
            print(f"[{n}/{len(todo)}] {item['title']}: {', '.join(did)} in {time.time() - t0:.0f}s ({fixed} done, {skipped} already fine)", flush=True)
        except BaseException as e:  # keep going; a failed title is retried on the next run
            failed += 1
            print(f"[{n}/{len(todo)}] FAILED {item['title']}: {e}", flush=True)
    print(f"finished: {fixed} fixed, {skipped} already fine, {failed} failed, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
