#!/usr/bin/env python3
"""Fill missing trailer files and English YouTube captions for the library.

Matching, posters, and the YouTube id happen in the worker when an upload
completes. This step downloads the picture, the sound, and the captions,
then stores them in R2. Run it on a new upload, or leave the launch agent running.
"""
import json
import re
import subprocess
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path("/Users/matthew/Developer/GitHub/watch")
KEY = (ROOT / "ios/Model/Movie.swift").read_text().split('static let key = "')[1].split('"')[0]
BASE = "https://watch.cornerstonecoatings.com"
OUT = Path("/tmp/watch-trailers")
OUT.mkdir(exist_ok=True)

def call(method, path, timeout=60):
    req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + KEY}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def d1(sql):
    subprocess.run(
        ["npx", "wrangler", "d1", "execute", "watch", "--remote", "--command", sql, "--json"],
        cwd=ROOT / "worker", capture_output=True,
    )

def r2(key, path, content_type):
    proc = subprocess.run(
        ["npx", "wrangler", "r2", "object", "put", f"watch/{key}", "--file", str(path),
         "--content-type", content_type, "--remote"],
        cwd=ROOT / "worker", capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout)[-240:])

def clean_vtt(raw: str) -> str:
    text = re.sub(r"<[^>]+>", "", raw).replace("\r\n", "\n")
    blocks = []
    for block in text.split("\n\n"):
        lines = [ln.strip() for ln in block.split("\n") if ln.strip()]
        timing = next((ln for ln in lines if "-->" in ln), None)
        if not timing:
            continue
        start, end = [part.strip().split(" ")[0] for part in timing.split("-->")[:2]]
        body = " ".join(ln for ln in lines if "-->" not in ln and not ln.startswith("NOTE") and ln != "WEBVTT")
        body = re.sub(r"\s+", " ", body).strip()
        if not body:
            continue
        if blocks and blocks[-1][2] == body:
            continue
        blocks.append((start, end, body))
    out = ["WEBVTT", ""]
    for start, end, body in blocks:
        out.append(f"{start} --> {end}")
        out.append(body)
        out.append("")
    return "\n".join(out) if len(blocks) else ""

def captions(yt: str) -> str:
    dest = OUT / yt
    for p in dest.parent.glob(f"{yt}*.vtt"):
        p.unlink()
    subprocess.run(
        ["yt-dlp", "--skip-download", "--write-subs", "--write-auto-sub", "--sub-langs", "en",
         "--convert-subs", "vtt", "--no-playlist", "-o", str(dest),
         f"https://www.youtube.com/watch?v={yt}"],
        capture_output=True, text=True,
    )
    files = list(OUT.glob(f"{yt}*.vtt"))
    if not files:
        return ""
    text = clean_vtt(files[0].read_text(encoding="utf-8", errors="replace"))
    for f in files:
        f.unlink(missing_ok=True)
    return text

def video(yt: str) -> Path | None:
    dest = OUT / f"{yt}.mp4"
    if dest.exists():
        dest.unlink()
    proc = subprocess.run(
        ["yt-dlp", "-f", "bv*[height<=480]+ba/b[height<=480]", "--merge-output-format", "mp4",
         "--max-filesize", "80M", "--no-playlist", "-o", str(dest),
         f"https://www.youtube.com/watch?v={yt}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not dest.exists() or dest.stat().st_size < 100_000:
        return None
    return dest

def main():
    d1("ALTER TABLE movie ADD COLUMN trailer_caption_key TEXT")
    items = json.loads(call("GET", "/v1/items")[1])["items"]
    groups: dict[str, list[dict]] = {}
    for it in items:
        yt = it.get("trailerKey")
        if yt:
            groups.setdefault(yt, []).append(it)
    todo = []
    for yt, rows in groups.items():
        need_file = any(not r.get("trailerFile") for r in rows)
        need_caps = any(not r.get("trailerCaptions") for r in rows)
        if need_file or need_caps:
            todo.append((yt, rows, need_file, need_caps))
    print(f"ENRICH {len(todo)} of {len(groups)}", flush=True)

    def one(job):
        yt, rows, need_file, need_caps = job
        ids = ",".join(f"'{r['id']}'" for r in rows)
        if need_file:
            path = video(yt)
            if path:
                size = path.stat().st_size
                r2(f"trailers/{yt}.mp4", path, "video/mp4")
                path.unlink()
                d1(
                    "UPDATE movie SET trailer_r2_key='%s', trailer_bytes=%d, trailer_status='ready', trailer_note='enriched' WHERE id IN (%s)"
                    % (f"trailers/{yt}.mp4", size, ids)
                )
        if need_caps:
            text = captions(yt)
            if text:
                vtt = OUT / f"{yt}.vtt"
                vtt.write_text(text, encoding="utf-8")
                r2(f"trailers/{yt}.vtt", vtt, "text/vtt")
                vtt.unlink()
                d1("UPDATE movie SET trailer_caption_key='%s' WHERE id IN (%s)" % (f"trailers/{yt}.vtt", ids))
                return yt, "captions"
            return yt, "no_captions"
        return yt, "file"

    ok = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for fut in as_completed(pool.submit(one, job) for job in todo):
            yt, status = fut.result()
            if status == "captions":
                ok += 1
            print(status, yt, flush=True)
    print(f"DONE captions {ok}", flush=True)

if __name__ == "__main__":
    main()
