#!/usr/bin/env python3
"""Build and upload a Roku seek-preview (BIF) for every library title that has a local original.

Matches local files to library items by filename, skips titles that already have a BIF, and
uploads each preview as it finishes, so it can be stopped and resumed.

Usage: WATCH_KEY=... bif-all.py "<movies folder>" [--workers 3] [--limit N]
"""
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("prepare_title", os.path.join(HERE, "prepare-title.py"))
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


def library(key):
    for attempt in range(5):
        try:
            req = urllib.request.Request(prep.BASE + "/v1/items", headers={"Authorization": f"Bearer {key}"})
            with urllib.request.urlopen(req, timeout=60) as res:
                return json.loads(res.read())["items"]
        except (OSError, ValueError, http.client.HTTPException):
            time.sleep(2 * (attempt + 1))
    raise SystemExit("could not read the library")


def has_bif(item, key):
    req = urllib.request.Request(
        f"{prep.BASE}/v1/items/{item}/trick.bif", method="HEAD", headers={"Authorization": f"Bearer {key}"}
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                return res.status == 200
        except urllib.error.HTTPError:
            return False
        except (OSError, http.client.HTTPException):
            time.sleep(2 * (attempt + 1))
    return False


def local_files(root):
    found = {}
    for dirpath, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith(".mp4") and not name.startswith("."):
                found.setdefault(name.lower(), os.path.join(dirpath, name))
    return found


def one(path, item, key):
    with tempfile.TemporaryDirectory() as work:
        bif = os.path.join(work, "trick.bif")
        count = prep.make_bif(path, bif, work)
        prep.call("PUT", f"/v1/items/{item}/bif", key, open(bif, "rb").read(), "application/octet-stream")
        return count


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    workers = int(flags[flags.index("--workers") + 1]) if "--workers" in flags else 3
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0

    files = local_files(args[0])
    todo, missing = [], []
    for it in library(key):
        path = files.get(it["filename"].lower())
        if not path:
            missing.append(it["filename"])
        elif not has_bif(it["id"], key):
            todo.append((path, it["id"], it["title"]))
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} to do, {len(missing)} library titles with no local file", flush=True)
    for name in missing:
        print("  no local file:", name, flush=True)

    done = failed = 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(one, p, i, key): t for p, i, t in todo}
        for fut in as_completed(jobs):
            try:
                n = fut.result()
                done += 1
                print(f"[{done + failed}/{len(todo)}] {jobs[fut]}: {n} frames", flush=True)
            except BaseException as e:  # keep going; a failed title is retried on the next run
                failed += 1
                print(f"[{done + failed}/{len(todo)}] FAILED {jobs[fut]}: {e}", flush=True)
    print(f"finished: {done} uploaded, {failed} failed, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
