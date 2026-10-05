#!/usr/bin/env python3
"""Fix every library title from its local original, one at a time, without depending on the drive staying up.

For each title: copy the original onto this Mac's internal disk, work only from that copy, then delete it
and move on. If the drive disappears (before or during a copy) the run waits for it to come back and
retries instead of failing.

Per title, only what is missing is done:
  - re-mux to a standard MP4 (moov first, one mdat) and replace the stored file, so Roku starts it fast;
  - build the seek-preview (BIF) and upload it.
A title that is already fixed is skipped without being copied at all.

Usage: WATCH_KEY=... process-all.py "<movies folder>" [--limit N]
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time

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


def wait_for(path):
    """Block until the path is readable again (the drive was unplugged or went to sleep)."""
    waited = 0
    while not os.path.exists(path):
        if waited % 60 == 0:
            print(f"waiting for {path} to come back ({waited // 60} min)", flush=True)
        time.sleep(15)
        waited += 15


def stage(src, dst):
    """Copy a file from the drive to local disk, riding out the drive dropping away."""
    for attempt in range(8):
        try:
            wait_for(src)
            shutil.copyfile(src, dst)
            if os.path.getsize(dst) == os.path.getsize(src):
                return
        except OSError as e:
            print(f"  copy interrupted ({e}); retrying", flush=True)
        if os.path.exists(dst):
            os.remove(dst)
        time.sleep(10)
    raise RuntimeError("could not copy from the drive")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0
    root = args[0]
    wait_for(root)
    files = rmx.local_files(root)

    items = json.loads(rmx.fetch(prep.BASE + "/v1/items", {"Authorization": f"Bearer {key}"}))["items"]
    todo = [(files[i["filename"].lower()], i) for i in items if i["filename"].lower() in files and not i.get("hlsUrl")]
    print(f"{len(todo)} titles with a local original", flush=True)

    fixed = skipped = failed = 0
    start = time.time()
    for n, (src, item) in enumerate(todo, 1):
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
                stage(src, local)
                did = []
                preview_from = local
                if not standard:
                    out = os.path.join(work, "movie.mp4")
                    prep.remux(local, out)
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
