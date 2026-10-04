#!/usr/bin/env python3
"""Fetch English subtitles for every library title that has none and upload them to the worker.

Matches by ID, not by file hash: each title's IMDb id (the same identity the TMDB lookup resolves to)
is searched on OpenSubtitles, results whose release year disagrees are dropped, and machine or
foreign-parts-only files are skipped. A sidecar .srt next to the original on disk wins over a download.

Usage:
  OPENSUBTITLES_API_KEY=... OPENSUBTITLES_USERNAME=... OPENSUBTITLES_PASSWORD=... WATCH_KEY=... \\
    subtitles.py ["<movies folder>"] [--limit N]

Stops cleanly when the account's daily download quota is used up; run it again tomorrow and it
carries on with the titles still missing subtitles.
"""
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WATCH = "https://watch.cornerstonecoatings.com"
OS_HOST = "https://api.opensubtitles.com"
UA = "MatFlix v1.0"


def request(method, url, headers, body=None, timeout=60):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, data=body, method=method, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as res:
                return res.status, res.read()
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            return e.code, e.read()
        except (OSError, http.client.HTTPException):
            time.sleep(2 * (attempt + 1))
    return 0, b""


def watch(method, path, key, body=None, ctype=None):
    headers = {"Authorization": f"Bearer {key}"}
    if ctype:
        headers["Content-Type"] = ctype
    return request(method, WATCH + path, headers, body, timeout=120)


def os_headers(api_key, token=None):
    h = {"Api-Key": api_key, "User-Agent": UA, "Accept": "application/json", "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def login(api_key, user, password):
    status, body = request("POST", f"{OS_HOST}/api/v1/login", os_headers(api_key), json.dumps({"username": user, "password": password}).encode())
    if status != 200:
        raise SystemExit(f"OpenSubtitles login failed ({status}): {body[:200]!r}")
    data = json.loads(body)
    base = data.get("base_url") or OS_HOST.replace("https://", "")
    return data["token"], "https://" + base.replace("https://", "")


def best_match(rows, year):
    """Pick the most downloaded English file that is a real, full-length subtitle for this year."""
    good = []
    for row in rows:
        a = row.get("attributes") or {}
        files = a.get("files") or []
        if not files or a.get("language") != "en":
            continue
        if a.get("ai_translated") or a.get("machine_translated") or a.get("foreign_parts_only"):
            continue
        feature_year = (a.get("feature_details") or {}).get("year")
        if year and feature_year and abs(int(feature_year) - int(year)) > 1:
            continue
        score = (0 if a.get("hearing_impaired") else 1, a.get("from_trusted") and 1 or 0, a.get("download_count") or 0)
        good.append((score, files[0]["file_id"], a.get("release") or ""))
    return max(good)[1:] if good else None


def sidecars(root):
    found = {}
    if not root:
        return found
    for dirpath, _, names in os.walk(root):
        for name in names:
            low = name.lower()
            if low.endswith(".srt") and not name.startswith("."):
                stem = low[:-4]
                if stem.endswith(".en"):
                    stem = stem[:-3]
                found.setdefault(stem, os.path.join(dirpath, name))
    return found


def main():
    flags = sys.argv[1:]
    folder = next((a for a in flags if not a.startswith("--") and os.path.isdir(a)), None)
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0
    env = {k: os.environ.get(k, "") for k in ("OPENSUBTITLES_API_KEY", "OPENSUBTITLES_USERNAME", "OPENSUBTITLES_PASSWORD", "WATCH_KEY")}
    missing = [k for k, v in env.items() if not v]
    if missing:
        raise SystemExit("missing environment: " + ", ".join(missing))
    key = env["WATCH_KEY"]

    status, body = watch("GET", "/v1/items", key)
    if status != 200:
        raise SystemExit(f"could not read the library ({status})")
    todo = [i for i in json.loads(body)["items"] if not i.get("subtitles")]
    if limit:
        todo = todo[:limit]
    local = sidecars(folder)
    print(f"{len(todo)} titles without subtitles", flush=True)

    token, base = login(env["OPENSUBTITLES_API_KEY"], env["OPENSUBTITLES_USERNAME"], env["OPENSUBTITLES_PASSWORD"])
    done = skipped = 0
    for n, item in enumerate(todo, 1):
        name = os.path.splitext(item["filename"])[0].lower()
        data, source = None, ""
        if name in local:
            data, source = open(local[name], "rb").read(), "sidecar"
        elif item.get("imdbId"):
            imdb = item["imdbId"].lstrip("t")
            query = urllib.parse.urlencode({"imdb_id": imdb, "languages": "en", "type": "movie", "order_by": "download_count"})
            status, body = request("GET", f"{base}/api/v1/subtitles?{query}", os_headers(env["OPENSUBTITLES_API_KEY"], token))
            pick = best_match(json.loads(body).get("data", []), item.get("year")) if status == 200 else None
            if pick:
                status, body = request("POST", f"{base}/api/v1/download", os_headers(env["OPENSUBTITLES_API_KEY"], token), json.dumps({"file_id": pick[0], "sub_format": "srt"}).encode())
                if status in (406, 429):
                    print(f"daily download quota reached after {done} titles; run again later", flush=True)
                    break
                if status == 200 and json.loads(body).get("link"):
                    status, data = request("GET", json.loads(body)["link"], {"User-Agent": UA})
                    data, source = (data if status == 200 else None), "opensubtitles"
        if not data:
            skipped += 1
            print(f"[{n}/{len(todo)}] no match: {item['title']}", flush=True)
            continue
        status, body = watch("PUT", f"/v1/items/{item['id']}/subtitles/en?label=English", key, data, "text/plain")
        if status == 200:
            done += 1
            print(f"[{n}/{len(todo)}] {item['title']}: {source}", flush=True)
        else:
            skipped += 1
            print(f"[{n}/{len(todo)}] upload failed {status}: {item['title']}", flush=True)
        time.sleep(1)
    print(f"finished: {done} uploaded, {skipped} without a match", flush=True)


if __name__ == "__main__":
    main()
