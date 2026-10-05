#!/usr/bin/env python3
"""Fetch English subtitles for every library movie that has none and upload them to the worker.

Source: the public OpenSubtitles addon endpoint used by Stremio (no account, no key), looked up by the
title's IMDb id. Several English files exist per film, so each candidate is downloaded and the one whose
timing fits this copy of the movie is kept:
  - the last cue must end between 80% and 100% of the movie's runtime (a different cut or a stray sync
    offset shows up as a cue that runs past the end or stops far short), and
  - files made for a different frame rate than 23.976/24 fps are skipped.
A title with no fitting candidate is left without subtitles rather than given a wrong track.

Usage: WATCH_KEY=... subtitles.py [--limit N]
"""
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

WATCH = "https://watch.cornerstonecoatings.com"
ADDON = "https://opensubtitles-v3.strem.io/subtitles/movie/{imdb}.json"
UA = "MatFlix/1.0"
CUE = re.compile(r"(\d+):(\d\d):(\d\d)[,.](\d{3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{3})")


def get(url, headers=None, timeout=60):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
            with urllib.request.urlopen(req, timeout=timeout) as res:
                return res.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429:
                return None
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(2 * (attempt + 1))
    return None


def last_cue_end(text):
    """Seconds at which the final cue ends, and how many cues there are."""
    last, n = 0.0, 0
    for m in CUE.finditer(text):
        h, mi, s, ms = map(int, m.groups()[4:])
        last = max(last, h * 3600 + mi * 60 + s + ms / 1000)
        n += 1
    return last, n


def decode(raw):
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def pick(candidates, runtime_s):
    """The best-fitting English file for this runtime, or None."""
    best = None
    for c in candidates:
        fps = c.get("fpsMilli") or 0
        if fps and not (23900 <= fps <= 24100):
            continue
        raw = get(c["url"])
        if not raw:
            continue
        text = decode(raw)
        end, cues = last_cue_end(text)
        ratio = end / runtime_s if runtime_s else 0
        if cues < 300 or not (0.80 <= ratio <= 1.0):
            continue
        # closest to the usual "credits roll after the last line" position wins
        score = abs(ratio - 0.96)
        if best is None or score < best[0]:
            best = (score, text, c.get("subtitleFileName", ""), ratio)
    return best


def main():
    flags = sys.argv[1:]
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0

    items = json.loads(get(WATCH + "/v1/items", {"Authorization": f"Bearer {key}"}))["items"]
    todo = [i for i in items if not i.get("subtitles") and i.get("imdbId") and not i.get("series")]
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} movies without subtitles", flush=True)

    done = skipped = 0
    for n, item in enumerate(todo, 1):
        runtime = (item.get("runtimeMin") or 0) * 60
        data = get(ADDON.format(imdb=item["imdbId"]))
        english = [s for s in (json.loads(data).get("subtitles", []) if data else []) if s.get("lang") in ("eng", "en")]
        found = pick(english[:8], runtime) if english and runtime else None
        if not found:
            skipped += 1
            print(f"[{n}/{len(todo)}] no fitting subtitle: {item['title']} ({len(english)} candidates)", flush=True)
            continue
        _, text, name, ratio = found
        req = urllib.request.Request(
            f"{WATCH}/v1/items/{item['id']}/subtitles/en?label=English",
            data=text.encode("utf-8"), method="PUT",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "text/plain; charset=utf-8"},
        )
        try:
            urllib.request.urlopen(req, timeout=120).read()
            done += 1
            print(f"[{n}/{len(todo)}] {item['title']}: {name} (ends at {ratio:.0%} of runtime)", flush=True)
        except (urllib.error.URLError, OSError) as e:
            skipped += 1
            print(f"[{n}/{len(todo)}] upload failed: {item['title']}: {e}", flush=True)
        time.sleep(0.5)
    print(f"finished: {done} uploaded, {skipped} skipped", flush=True)


if __name__ == "__main__":
    main()
