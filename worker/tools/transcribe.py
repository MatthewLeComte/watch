#!/usr/bin/env python3
"""Make English subtitles for every library title that has none, by transcribing the local original.

No accounts or quotas: the audio is extracted with ffmpeg, transcribed by whisper.cpp on this Mac, and the
WebVTT is uploaded to the worker. The timing matches the exact file, so it never drifts.

Setup (once):
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp && cd whisper.cpp
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON && cmake --build build -j --target whisper-cli
  curl -L -o models/ggml-small.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin

Usage:
  WATCH_KEY=... WHISPER_DIR=/path/to/whisper.cpp transcribe.py "<movies folder>" [--workers 2] [--limit N]

Safe to stop and re-run: titles that already have subtitles are skipped.
"""
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


def call(method, path, key, body=None, ctype=None):
    headers = {"Authorization": f"Bearer {key}"}
    if ctype:
        headers["Content-Type"] = ctype
    for attempt in range(5):
        try:
            req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers)
            with urllib.request.urlopen(req, timeout=120) as res:
                return res.read()
        except urllib.error.HTTPError as e:
            if e.code < 500:
                raise RuntimeError(f"{method} {path} -> {e.code}")
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{method} {path} failed after retries")


def local_files(root):
    found = {}
    for dirpath, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith(".mp4") and not name.startswith("."):
                found.setdefault(name.lower(), os.path.join(dirpath, name))
    return found


def transcribe(src, item, key, whisper_dir, threads):
    cli = os.path.join(whisper_dir, "build", "bin", "whisper-cli")
    model = os.path.join(whisper_dir, "models", "ggml-small.en.bin")
    with tempfile.TemporaryDirectory() as work:
        wav = os.path.join(work, "audio.wav")
        subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", src, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav],
            check=True,
        )
        out = os.path.join(work, "subs")
        subprocess.run([cli, "-m", model, "-f", wav, "-ovtt", "-of", out, "-t", str(threads), "-np"], check=True, stdout=subprocess.DEVNULL)
        vtt = open(out + ".vtt", "rb").read()
    cues = vtt.count(b"-->")
    if cues < 50:
        raise RuntimeError(f"only {cues} cues; not uploading")
    call("PUT", f"/v1/items/{item}/subtitles/en?label=English", key, vtt, "text/vtt")
    return cues


def main():
    flags = sys.argv[1:]
    folder = next((a for a in flags if not a.startswith("--") and os.path.isdir(a)), None)
    key = os.environ.get("WATCH_KEY", "")
    whisper_dir = os.environ.get("WHISPER_DIR", "")
    if not folder or not key or not whisper_dir:
        raise SystemExit(__doc__)
    workers = int(flags[flags.index("--workers") + 1]) if "--workers" in flags else 2
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0
    threads = max(2, (os.cpu_count() or 8) // workers)

    files = local_files(folder)
    items = json.loads(call("GET", "/v1/items", key))["items"]
    todo = [(files[i["filename"].lower()], i["id"], i["title"]) for i in items if not i.get("subtitles") and i["filename"].lower() in files]
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} titles to transcribe", flush=True)

    done = failed = 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(transcribe, p, i, key, whisper_dir, threads): t for p, i, t in todo}
        for fut in as_completed(jobs):
            try:
                cues = fut.result()
                done += 1
                print(f"[{done + failed}/{len(todo)}] {jobs[fut]}: {cues} cues", flush=True)
            except BaseException as e:
                failed += 1
                print(f"[{done + failed}/{len(todo)}] FAILED {jobs[fut]}: {e}", flush=True)
    print(f"finished: {done} uploaded, {failed} failed, {time.time() - start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
