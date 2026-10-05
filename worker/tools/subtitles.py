#!/usr/bin/env python3
"""Give every library movie an English subtitle track that matches the film's own sound, or none.

A track found by title alone is often for another cut of the film, or runs early or late. So each
candidate is checked against the stored file itself:

  1. Twelve short stretches of the soundtrack are pulled from the library (a few seconds of work) and
     turned into a "someone is talking" curve.
  2. The track's lines are turned into the same kind of curve ("a line is on screen") and slid against
     it, which shows how early or late the track is in each stretch.
  3. A track that belongs to this cut is off by the same amount everywhere, or drifts evenly, or was
     made for a copy running at another speed (PAL). Those are corrected exactly and uploaded.
     A track for another cut does not line up from one stretch to the next and is thrown away.

Candidates are the track already stored for the title, then the public OpenSubtitles addon used by
Stremio (no account, no key), looked up by IMDb id. A title is left without subtitles rather than
given a track that does not fit.

Usage: WATCH_KEY=... subtitles.py [--only TITLE] [--limit N] [--jobs N] [--dry] [--report FILE]
Needs ffmpeg and numpy. With --dry nothing is uploaded or removed.
"""
import http.client
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import numpy as np

WATCH = "https://watch.cornerstonecoatings.com"
ADDON = "https://opensubtitles-v3.strem.io/subtitles/movie/{imdb}.json"
UA = "MatFlix/1.0"

RATE = 8000
HOP = 0.02  # seconds per step of both curves
WINDOW = 200.0  # seconds of sound per stretch
STRETCHES = 12
REACH = 50.0  # how far early or late a track may be and still be found
AGREE = 0.4  # a stretch agrees when it fits within this many seconds of the pooled answer
# A track made for a copy running at another speed (PAL 25 fps against film 23.976 / 24 fps)...
SPEEDS = [1.0, 23.976 / 25, 25 / 23.976, 24 / 25, 25 / 24]
# ...or drifting evenly because it was timed at 24 fps against 23.976 (seconds gained per second)
DRIFTS = [0.0, 0.001, -0.001]
MAX_CANDIDATES = 14

CUE = re.compile(
    r"(\d+):(\d\d):(\d\d)[,.](\d{3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{3})([^\n]*)\n(.*?)(?=\n\s*\n|\Z)", re.S
)
NOISE = re.compile(r"^\s*[\[(♪#*].*[\])♪#*]\s*$", re.S)
ADVERT = re.compile(
    r"opensubtitles|osdb\.link|subtitles? (by|downloaded)|sync(ed|hronized)? (by|and corrected)|corrected by|"
    r"www\.[a-z0-9-]+\.[a-z]{2,}|addic7ed|yify|\byts\b|advertise your product|become vip member",
    re.I,
)


# ---------------------------------------------------------------- fetching

def get(url, headers=None, timeout=60, tries=8):
    """GET the whole body, retrying when the connection drops mid-body. None on a plain 4xx."""
    last = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
            with urllib.request.urlopen(req, timeout=timeout) as res:
                return res.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429:
                return None
            last = e
        except (OSError, http.client.HTTPException) as e:
            last = e
        time.sleep(min(10, 1 + attempt))
    raise RuntimeError(f"could not read {url.split('?')[0]}: {last}")


def send(method, path, key, body=None):
    req = urllib.request.Request(WATCH + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    if body is not None:
        req.add_header("Content-Type", "text/vtt; charset=utf-8")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as res:
                res.read()
                return True
        except urllib.error.HTTPError as e:
            if e.code == 404 and method == "DELETE":
                return True
            if e.code < 500:
                raise RuntimeError(f"{method} {path} -> {e.code}")
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{method} {path} failed after retries")


def decode(raw):
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def real_length(item, key):
    """Seconds, from the film header at the start of the stored file (the listed runtime is another cut's)."""
    head = get(f"{WATCH}/v1/items/{item}/media", {"Authorization": f"Bearer {key}", "Range": "bytes=0-4095"})
    at = head.find(b"mvhd") if head else -1
    if at >= 4 and len(head) >= at + 36:
        if head[at + 4] == 1:
            scale, length = struct.unpack(">IQ", head[at + 24 : at + 36])
        else:
            scale, length = struct.unpack(">II", head[at + 16 : at + 24])
        if scale and length:
            return length / scale
    # The header is not at the very start of this file: let ffprobe find it.
    cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", f"{WATCH}/v1/items/{item}/media?key={key}"]
    try:
        return float(subprocess.run(cmd, capture_output=True, timeout=120).stdout.strip() or 0)
    except (ValueError, subprocess.TimeoutExpired):
        return 0.0


# ---------------------------------------------------------------- subtitle text

def parse(text):
    """[(start, end, words)] in order, from SRT or WebVTT text, without adverts."""
    out = []
    for m in CUE.finditer(text.replace("\r\n", "\n").replace("\r", "\n")):
        g = list(map(int, m.groups()[:8]))
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
        words = re.sub(r"\{\\[^}]*\}|</?font[^>]*>", "", m.group(10)).strip()
        if words and end > start and not ADVERT.search(words):
            out.append((start, end, words))
    out.sort()
    return out


def spoken(cues):
    """Lines someone says: sound descriptions and lyrics are left out of the check."""
    return [(s, e) for s, e, w in cues if not NOISE.match(re.sub(r"<[^>]+>", "", w))]


def stamp(t):
    ms = int(round(max(0.0, t) * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def write_vtt(cues, speed=1.0, drift=0.0, shift=0.0):
    """WebVTT text with every time moved to new = old * speed * (1 + drift) + shift."""
    k = speed * (1.0 + drift)
    out = ["WEBVTT", ""]
    for s, e, w in cues:
        a, b = s * k + shift, e * k + shift
        if b > 0:
            out += [f"{stamp(a)} --> {stamp(b)}", w, ""]
    return "\n".join(out)


# ---------------------------------------------------------------- the film's sound

def stretch_starts(length):
    out = []
    for i in range(STRETCHES):
        start = length * (0.08 + 0.80 * i / (STRETCHES - 1)) - WINDOW / 2
        out.append(max(0.0, min(start, length - WINDOW - 1)))
    return out


def sound(item, key, start):
    """Mono speech-band sound for one stretch. ffmpeg reads only the audio it needs from the library."""
    cmd = [
        "ffmpeg", "-nostdin", "-v", "error", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
        "-ss", f"{start:.3f}", "-t", f"{WINDOW:.3f}", "-i", f"{WATCH}/v1/items/{item}/media?key={key}",
        "-map", "0:a:0", "-vn", "-sn", "-af", "highpass=f=250,lowpass=f=3200", "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-",
    ]
    kept = os.environ.get("SOUND_CACHE", "")  # a folder to keep pulled sound in, for repeated runs
    path = os.path.join(kept, f"{item}-{int(start)}.raw") if kept else ""
    if path and os.path.exists(path):
        return np.fromfile(path, dtype=np.int16)
    pcm = np.frombuffer(b"", dtype=np.int16)
    for _ in range(3):
        try:
            raw = subprocess.run(cmd, capture_output=True, timeout=600).stdout
        except subprocess.TimeoutExpired:
            continue
        pcm = np.frombuffer(raw[: len(raw) // 2 * 2], dtype=np.int16)
        if len(pcm) >= RATE * WINDOW * 0.9:
            break
    if path and len(pcm):
        pcm.tofile(path)
    return pcm


def talking(pcm):
    """How far each 20 ms step stands above the quiet level around it, 0..1."""
    n = int(RATE * HOP)
    frames = pcm[: len(pcm) // n * n].astype(np.float32).reshape(-1, n) / 32768.0
    level = 10 * np.log10((frames**2).mean(axis=1) + 1e-10)
    # quiet level: the 20th percentile of each 2 s block, taking the lowest of its neighbours
    block = int(2 / HOP)
    count = max(1, len(level) // block)
    floors = np.array([np.percentile(level[i * block : (i + 1) * block], 20) for i in range(count)])
    floors = np.array([floors[max(0, i - 2) : i + 3].min() for i in range(count)])
    floor = np.repeat(floors, block)
    if len(floor) < len(level):
        floor = np.concatenate([floor, np.full(len(level) - len(floor), floors[-1])])
    above = np.clip(level - floor[: len(level)] - 6.0, 0, 18) / 18.0
    return np.convolve(above, np.ones(5) / 5, mode="same")  # ~100 ms, so single clicks do not count


def listen(item, key, length):
    """[(start of stretch, talking curve, where talk begins)] for one film. The only slow part."""
    out = []
    for start in stretch_starts(length):
        pcm = sound(item, key, start)
        if len(pcm) < RATE * 30:
            continue
        curve = talking(pcm)
        rise = np.clip(curve - np.concatenate([np.zeros(5, dtype=curve.dtype), curve[:-5]]), 0, None)
        out.append((start, curve, rise))
    return out


# ---------------------------------------------------------------- matching a track to the sound

def on_screen(lines, start, length):
    """1 where a spoken line is on screen, from `start`, one value per 20 ms."""
    out = np.zeros(int(round(length / HOP)), dtype=np.float32)
    for s, e in lines:
        a = int(np.floor((s - start) / HOP))
        b = int(np.ceil((e - start) / HOP))
        if b > 0 and a < len(out):
            out[max(0, a) : min(len(out), b)] = 1.0
    return out


def line_starts(lines, start, length):
    """A short bump where a line appears after a pause: the moments that should meet talk beginning."""
    out = np.zeros(int(round(length / HOP)), dtype=np.float32)
    last_end = -10.0
    for s, e in lines:
        if s - last_end >= 0.4:
            i = int(round((s - start) / HOP))
            if 2 <= i < len(out) - 2:
                out[i - 2 : i + 3] += np.array([0.2, 0.7, 1.0, 0.7, 0.2], dtype=np.float32)
        last_end = max(last_end, e)
    return out


def slide(track, curve):
    """How well `curve` fits `track` at every 20 ms shift (the same as np.correlate(..., "valid"), but fast)."""
    size = 1 << int(np.ceil(np.log2(len(track))))
    fit = np.fft.irfft(np.fft.rfft(track, size) * np.conj(np.fft.rfft(curve, size)), size)
    return fit[: len(track) - len(curve) + 1]


def fits(heard, lines):
    """One row per stretch: how well the track fits at each shift from +REACH down to -REACH seconds,
    in standard deviations above that stretch's usual level. A stretch with no lines or no sound is zeros."""
    steps = int(round(2 * REACH / HOP)) + 1
    rows = np.zeros((len(heard), steps), dtype=np.float32)
    for n, (start, curve, _) in enumerate(heard):
        length = len(curve) * HOP
        track = on_screen(lines, start - REACH, length + 2 * REACH)
        middle = track[int(REACH / HOP) : int((REACH + length) / HOP)]
        if middle.sum() * HOP < 12 or curve.std() < 1e-4:  # hardly any lines here, or silence
            continue
        fit = slide(track - track.mean(), curve - curve.mean())[:steps]
        spread = fit.std()
        if len(fit) == steps and spread > 0:
            rows[n] = (fit - fit.mean()) / spread
    return rows


def judge(heard, cues, length):
    """Does this track belong to this film, and what correction does it need?

    {"ok", "speed", "drift", "shift", "with", "against", "of", "sure", "why"}:
    new time = old * speed * (1 + drift) + shift.
    """
    lines = spoken(cues)
    result = {"ok": False, "of": len(heard), "with": 0, "against": 0, "sure": 0.0, "speed": 1.0, "drift": 0.0, "shift": 0.0, "why": ""}
    if len(lines) < 150:
        result["why"] = "too few lines"
        return result
    last = max(e for _, e in lines)
    mids = np.array([start + WINDOW / 2 for start, _, _ in heard])
    steps = int(round(2 * REACH / HOP)) + 1
    edge = int(1.0 / HOP)  # ignore the very ends of the search, where a fit is cut short
    near = int(round(AGREE / HOP))
    best = None
    for speed in SPEEDS:
        if not (0.70 * length <= last * speed <= length + 8):
            continue  # at this speed the track would run past the film, or stop far short of it
        scaled = [(s * speed, e * speed) for s, e in lines]
        rows = fits(heard, scaled)
        live = [n for n in range(len(heard)) if rows[n].any()]
        if len(live) < 6:
            continue
        for drift in DRIFTS:
            # A steady drift moves each stretch's best shift by drift * (its time); line the rows up first.
            moves = [int(round(drift * mids[n] / HOP)) for n in live]
            pooled = np.zeros(steps, dtype=np.float32)
            for n, move in zip(live, moves):
                pooled += np.roll(rows[n], move)
            wrap = edge + max(abs(m) for m in moves)
            pooled[:wrap] = pooled[-wrap:] = 0
            peak = int(np.argmax(pooled))
            guard = int(2 / HOP)
            rest = np.concatenate([pooled[wrap : max(wrap, peak - guard)], pooled[peak + guard : steps - wrap]])
            if len(rest) < 100 or rest.std() == 0:
                continue
            sure = float((pooled[peak] - rest.mean()) / rest.std())
            # Stretch by stretch: does it fit at the pooled answer, or does it clearly fit somewhere else?
            members, against = [], 0
            for n, move in zip(live, moves):
                row = rows[n]
                here = peak - move
                lo, hi = max(0, here - near), min(steps, here + near + 1)
                top = int(np.argmax(row[edge : steps - edge])) + edge
                if hi > lo and float(row[lo:hi].max()) >= 2.5:
                    members.append(n)
                elif abs(top - here) > int(1.0 / HOP) and row[top] >= 4.5:
                    against += 1
            plain = speed == 1.0 and drift == 0.0
            score = (len(members) - against, plain, sure)
            if best is None or score > best[0]:
                best = (score, sure, speed, drift, peak, members, against, live, scaled)
    if best is None:
        result["why"] = "wrong length for this film"
        return result
    _, sure, speed, drift, peak, members, against, live, scaled = best
    shift = REACH - peak * HOP  # at the start of the film; a drifting track gains drift * time on top
    result.update(sure=round(sure, 1), speed=speed, drift=drift, shift=shift, against=against, of=len(live))
    result["with"] = len(members)
    # Enough of the film must back the answer: half the stretches; or four of them when the pooled fit
    # stands far above chance, or when the track is simply in step already (no speed change, almost no shift).
    count = len(members)
    in_step = speed == 1.0 and drift == 0.0 and abs(shift) <= 1.5
    backed = (
        (count >= int(np.ceil(len(live) * 0.5)) and against <= 1 and sure >= 4.0)
        or (count >= 4 and against == 0 and sure >= 6.5)
        or (count >= 4 and against == 0 and sure >= 4.5 and in_step)
    )
    if not backed and against < 2:
        result["why"] = "does not line up with the film"
        return result
    others = [n for n in live if n not in members]
    one_end = len(others) >= 3 and (max(members) < min(others) or min(members) > max(others))
    if against >= 2 or one_end:
        result["why"] = "lines up with only part of the film (another cut)"
        return result
    # The on-screen fit sits a little early because lines linger after the talk stops; where line starts
    # clearly meet the talk starting, that sharper answer wins.
    fine, fine_sure = refine(heard, scaled, shift, drift, members)
    if fine_sure >= 5.0:
        result["shift"] = shift + fine
    result["ok"] = True
    return result


def refine(heard, lines, shift, drift, members):
    """Sharpen the offset by lining up line starts with talk starting, across the agreeing stretches."""
    span = 1.5
    steps = int(round(span / HOP))
    total = np.zeros(2 * steps + 1)
    for n in members:
        start, curve, rise = heard[n]
        local = shift + drift * (start + WINDOW / 2)
        moved = [(s + local, e + local) for s, e in lines]
        bumps = line_starts(moved, start - span, len(curve) * HOP + 2 * span)
        if bumps.sum() < 5:
            continue
        fit = np.correlate(bumps, rise - rise.mean(), mode="valid")
        if len(fit) == len(total):
            total += fit
    if not total.any():
        return 0.0, 0.0
    best = int(np.argmax(total))
    rest = np.concatenate([total[: max(0, best - 10)], total[best + 10 :]])
    sure = float((total[best] - rest.mean()) / rest.std()) if len(rest) > 5 and rest.std() > 0 else 0.0
    return float(span - best * HOP), sure


# ---------------------------------------------------------------- one title

def handle(item, key, dry):
    title = item["title"]
    out = {"id": item["id"], "title": title, "action": "none", "detail": ""}
    try:
        length = real_length(item["id"], key)
        if length < 600:
            out["detail"] = "could not read the film's length"
            return out
        out["minutes"] = round(length / 60, 1)
        listed = (item.get("runtimeMin") or 0) * 60
        if listed and abs(length - listed) > max(240, 0.04 * listed):
            out["cut"] = f"file is {length / 60:.0f} min, listed as {listed / 60:.0f}"
        heard = listen(item["id"], key, length)
        if len(heard) < 8:
            out["detail"] = "could not read the film's sound"
            return out

        had = bool(item.get("subtitles"))
        stored = None
        best = None  # (result, name, cues)
        if had:
            raw = get(f"{WATCH}/v1/items/{item['id']}/subtitles/en", {"Authorization": f"Bearer {key}"})
            if raw:
                stored = decode(raw)
                res = judge(heard, parse(stored), length)
                if res["ok"]:
                    best = (res, "stored track", parse(stored))
                else:
                    out["stored"] = res["why"]
        tried = 0
        if best is None and item.get("imdbId"):
            data = get(ADDON.format(imdb=item["imdbId"]))
            listing = json.loads(data).get("subtitles", []) if data else []
            english = [s for s in listing if s.get("lang") in ("eng", "en")]
            for cand in english[:MAX_CANDIDATES]:
                raw = get(cand["url"], tries=4)
                if not raw:
                    continue
                tried += 1
                cues = parse(decode(raw))
                res = judge(heard, cues, length)
                if res["ok"] and (best is None or (res["with"], res["sure"]) > (best[0]["with"], best[0]["sure"])):
                    best = (res, cand.get("subtitleFileName") or "addon track", cues)
                    if res["with"] >= 0.7 * res["of"]:
                        break  # a clear match; no need to look further
        out["tried"] = tried

        if best is None:
            if had:
                out["action"] = "removed"
                out["detail"] = out.get("stored", "no track fits this film")
                if not dry:
                    send("DELETE", f"/v1/items/{item['id']}/subtitles/en", key)
            else:
                out["detail"] = f"no track fits this film ({tried} tried)"
            return out

        res, name, cues = best
        moved = abs(res["shift"]) >= 0.15 or res["speed"] != 1.0 or res["drift"] != 0.0
        vtt = write_vtt(cues, res["speed"], res["drift"], res["shift"] if moved else 0.0)
        out["match"] = f"fits {res['with']} of {res['of']} stretches, {name}"
        how = []
        if res["speed"] != 1.0:
            how.append(f"speed x{res['speed']:.4f}")
        if res["drift"]:
            how.append(f"drift {res['drift'] * 3600:+.1f}s per hour")
        if moved and abs(res["shift"]) >= 0.15:
            how.append(f"moved {res['shift']:+.2f}s")
        if name == "stored track" and not moved and stored is not None and vtt.strip() == stored.strip():
            out["action"] = "kept"
            return out
        out["action"] = ("corrected" if moved else "cleaned") if name == "stored track" else ("replaced" if had else "added")
        out["detail"] = ", ".join(how)
        if not dry:
            send("PUT", f"/v1/items/{item['id']}/subtitles/en?label=English", key, vtt.encode("utf-8"))
        return out
    except Exception as e:  # noqa: BLE001 - one title failing must not stop the run
        out["action"] = "failed"
        out["detail"] = str(e)[:200]
        return out


def main():
    flags = sys.argv[1:]
    key = os.environ.get("WATCH_KEY", "")
    if not key:
        raise SystemExit("WATCH_KEY is not set")
    dry = "--dry" in flags
    limit = int(flags[flags.index("--limit") + 1]) if "--limit" in flags else 0
    jobs = int(flags[flags.index("--jobs") + 1]) if "--jobs" in flags else 3
    only = flags[flags.index("--only") + 1].lower() if "--only" in flags else ""
    report = flags[flags.index("--report") + 1] if "--report" in flags else ""

    items = json.loads(get(WATCH + "/v1/items", {"Authorization": f"Bearer {key}"}))["items"]
    todo = [i for i in items if not i.get("hlsUrl") and not i.get("series") and (i.get("subtitles") or i.get("imdbId"))]
    if only:
        todo = [i for i in todo if only in i["title"].lower()]
    if limit:
        todo = todo[:limit]
    print(f"{len(todo)} movies to check{' (dry run)' if dry else ''}", flush=True)

    rows = []
    counts = {}
    start = time.time()
    with ThreadPoolExecutor(jobs) as pool:
        for n, out in enumerate(pool.map(lambda i: handle(i, key, dry), todo), 1):
            rows.append(out)
            counts[out["action"]] = counts.get(out["action"], 0) + 1
            bits = [b for b in (out.get("match", ""), out["detail"], out.get("cut", "")) if b]
            print(f"[{n}/{len(todo)}] {out['action']:9} {out['title']}: {'; '.join(bits)}", flush=True)
            if report:
                json.dump(rows, open(report, "w"), indent=1)
    summary = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
    print(f"finished in {time.time() - start:.0f}s: {summary}", flush=True)


if __name__ == "__main__":
    main()
