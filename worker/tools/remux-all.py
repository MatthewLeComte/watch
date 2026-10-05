#!/usr/bin/env python3
"""Re-mux every library title that still has the many-mdat layout and replace it in the library.

Roku opens an MP4 by walking its top-level boxes. The originals have thousands of small mdat boxes, so
a title takes 30s or more to start (or never does). A standard file (moov first, one mdat) starts in
seconds. The re-mux is a lossless copy; each replacement only lands when every part arrives and the size
matches, and the original stays on the SSD.

Titles that are already standard are detected from the stored file and skipped, so this is safe to stop
and re-run.

Usage: WATCH_KEY=... remux-all.py "<movies folder>" [--limit N]
"""
import http.client
import importlib.util
import json
import os
import struct
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("prepare_title", os.path.join(HERE, "prepare-title.py"))
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


def fetch(url, headers):
    """GET with retries: the connection occasionally drops mid-body."""
    for attempt in range(10):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as res:
                return res.read()
        except (OSError, http.client.HTTPException):
            time.sleep(min(30, 3 * (attempt + 1)))
    raise RuntimeError(f"could not read {url}")


def ranged(item, key, start, end):
    return fetch(
        f"{prep.BASE}/v1/items/{item}/media",
        {"Authorization": f"Bearer {key}", "Range": f"bytes={start}-{end}"},
    )


def is_standard(item, size, key):
    """True when the stored file has one big mdat right after moov."""
    head = ranged(item, key, 0, 31)
    ftyp = struct.unpack(">I", head[:4])[0]
    moov = struct.unpack(">I", ranged(item, key, ftyp, ftyp + 7)[:4])[0]
    off = ftyp + moov
    for _ in range(4):
        nxt = ranged(item, key, off, off + 15)
        box, kind = struct.unpack(">I4s", nxt[:8])
        if kind in (b"free", b"skip", b"wide"):  # padding some muxers leave before mdat
            off += box
            continue
        if box == 1:
            box = struct.unpack(">Q", nxt[8:16])[0]
        return kind == b"mdat" and box >= 0.9 * size
    return False


def local_files(root):
    found = {}
    for dirpath, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith(".mp4") and not name.startswith("."):
                found.setdefault(name.lower(), os.path.join(dirpath, name))
    return found


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0
    files = local_files(args[0])

    items = json.loads(fetch(prep.BASE + "/v1/items", {"Authorization": f"Bearer {key}"}))["items"]
    todo = [(files[i["filename"].lower()], i) for i in items if i["filename"].lower() in files and not i.get("hlsUrl")]
    print(f"{len(todo)} titles with a local original", flush=True)

    done = skipped = failed = 0
    start = time.time()
    for n, (path, item) in enumerate(todo, 1):
        if limit and done >= limit:
            break
        try:
            if is_standard(item["id"], item["byteSize"], key):
                skipped += 1
                continue
            with tempfile.TemporaryDirectory() as work:
                fixed = os.path.join(work, "movie.mp4")
                t0 = time.time()
                prep.remux(path, fixed)
                prep.upload_video(fixed, item["id"], key)
            done += 1
            print(f"[{n}/{len(todo)}] {item['title']}: replaced in {time.time() - t0:.0f}s ({done} done, {skipped} already fine)", flush=True)
        except BaseException as e:  # keep going; a failed title is retried on the next run
            failed += 1
            print(f"[{n}/{len(todo)}] FAILED {item['title']}: {e}", flush=True)
    print(f"finished: {done} replaced, {skipped} already standard, {failed} failed, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
