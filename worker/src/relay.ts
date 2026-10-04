/** HLS relay: turn a client-captured upstream playlist into a worker-served one.
 *
 * Flow: iOS loads the documented Rive embed page, captures the .m3u8 URL,
 * hands it here. We serve a rewritten playlist whose segment/key/variant
 * URIs point back at /v1/relay/*, fetching upstream with the embed Referer.
 * No headless browser, no provider API in the worker.
 */

import type { Env } from "./env";
import { edgeCache } from "./lib.ts";
import { checkSavedStream } from "./validate.ts";

const UA = "Watch/1";

/** A saved stream is a rental for this long, then it deletes itself unless the user keeps it. */
export const RENTAL_DAYS = 45;

function bad(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return true;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return true;
  if (u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "0.0.0.0") return true;
  if (u.hostname === "169.254.169.254" || u.hostname.endsWith(".internal")) return true;
  return false;
}

export function relayHeaders(referer: string | null): HeadersInit {
  const h: Record<string, string> = { "User-Agent": UA };
  if (referer) h.Referer = referer;
  return h;
}

/** Rewrite one absolute upstream URI to a relay endpoint. */
function relayFor(origin: string, kind: "pl" | "seg", upstream: string, referer: string | null): string {
  const q = `u=${encodeURIComponent(upstream)}${referer ? `&ref=${encodeURIComponent(referer)}` : ""}`;
  return `${origin}/v1/relay/${kind}?${q}`;
}

/** Rewrite URI="..." attributes inside a tag line (EXT-X-KEY, EXT-X-MAP, EXT-X-MEDIA). */
function rewriteQuotedUris(line: string, origin: string, base: string, referer: string | null): string {
  return line.replace(/URI="([^"]+)"/g, (_m, raw: string) => {
    let abs = raw;
    try {
      abs = new URL(raw, base).href;
    } catch { /* keep raw */ }
    if (bad(abs)) return `URI="${raw}"`;
    const isPl = /\.m3u8(\?|$)/i.test(abs);
    return `URI="${relayFor(origin, isPl ? "pl" : "seg", abs, referer)}"`;
  });
}

/**
 * Rewrite an upstream playlist so every fetchable URI goes through the relay.
 * Master playlists (EXT-X-STREAM-INF) chain to /v1/relay/pl, media playlists
 * to /v1/relay/seg. Returns null when the text is not a playlist.
 */
export function rewritePlaylist(
  text: string,
  upstreamUrl: string,
  origin: string,
  referer: string | null,
): string | null {
  if (!text.includes("#EXTM3U")) return null;
  const base = upstreamUrl.slice(0, upstreamUrl.lastIndexOf("/") + 1);
  const out: string[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trimEnd();
    const t = line.trim();
    if (!t) {
      out.push(line);
      continue;
    }
    if (t.startsWith("#")) {
      out.push(t.includes("URI=") ? rewriteQuotedUris(t, origin, base, referer) : t);
      continue;
    }
    let abs = t;
    try {
      abs = t.startsWith("http") ? t : new URL(t, base).href;
    } catch {
      out.push(line);
      continue;
    }
    if (bad(abs)) {
      out.push(line);
      continue;
    }
    out.push(relayFor(origin, /\.m3u8(\?|$)/i.test(abs) ? "pl" : "seg", abs, referer));
  }
  return out.join("\n");
}

export async function handleRelayPl(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const upstream = url.searchParams.get("u") || "";
  const referer = url.searchParams.get("ref");
  if (!upstream || bad(upstream)) return json({ error: "bad_url" }, 400);
  const res = await fetch(upstream, {
    headers: relayHeaders(referer),
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) return json({ error: "upstream_fetch_failed" }, 502);
  const text = await res.text();
  const rewritten = rewritePlaylist(text, upstream, url.origin, referer);
  if (!rewritten) return json({ error: "not_a_playlist" }, 502);
  return new Response(rewritten, {
    headers: {
      "content-type": "application/vnd.apple.mpegurl",
      "cache-control": "private, no-store",
    },
  });
}

export async function handleRelaySeg(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const upstream = url.searchParams.get("u") || "";
  const referer = url.searchParams.get("ref");
  if (!upstream || bad(upstream)) return json({ error: "bad_url" }, 400);
  const cacheKey = new Request(`https://watch.internal/relay/seg?u=${encodeURIComponent(upstream)}`);
  const cached = await edgeCache().match(cacheKey);
  if (cached) return cached;
  const res = await fetch(upstream, {
    headers: relayHeaders(referer),
    signal: AbortSignal.timeout(30000),
  });
  if (!res.ok || !res.body) return json({ error: "upstream_fetch_failed" }, 502);
  const out = new Response(res.body, {
    headers: {
      "content-type": res.headers.get("content-type") || "video/mp2t",
      "cache-control": "public, max-age=86400",
    },
  });
  await edgeCache().put(cacheKey, out.clone());
  return out;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

// MARK: - Save to R2 (chunked HLS persist)

export type SaveMessage = {
  jobId: string;
  height: number;
  referer: string | null;
  segs: { i: number; u: string }[];
};

type Variant = { height: number; bandwidth: number; uri: string };

/** 1080p-sane picker: never >1080p, prefer tallest within a 4GB estimate. */
export const SAVE_BUDGET_BYTES = 4 * 1024 * 1024 * 1024;

export function pickSaveVariant(variants: Variant[], runtimeSec: number | null): number {
  const video = variants
    .map((v, i) => ({ ...v, i }))
    .filter((v) => v.height > 0 && v.height <= 1080 && v.uri);
  if (!video.length) return -1;
  if (runtimeSec && runtimeSec > 0) {
    const pool = video.filter((v) => (v.bandwidth * runtimeSec) / 8 <= SAVE_BUDGET_BYTES);
    if (pool.length) {
      pool.sort((a, b) => b.height - a.height || b.bandwidth - a.bandwidth);
      return pool[0]!.i;
    }
  }
  const hd = video.filter((v) => v.height === 1080);
  if (hd.length) {
    hd.sort((a, b) => a.bandwidth - b.bandwidth);
    return hd[0]!.i;
  }
  video.sort((a, b) => b.height - a.height || b.bandwidth - a.bandwidth);
  return video[0]!.i;
}

export function parseMasterVariants(text: string): Variant[] {
  const out: Variant[] = [];
  const lines = text.split("\n");
  let cur: Partial<Variant> = {};
  for (const raw of lines) {
    const t = raw.trim();
    if (t.startsWith("#EXT-X-STREAM-INF:")) {
      cur = {};
      const res = t.match(/RESOLUTION=\d+x(\d+)/);
      const bw = t.match(/BANDWIDTH=(\d+)/);
      cur.height = res ? Number(res[1]) : 0;
      cur.bandwidth = bw ? Number(bw[1]) : 0;
    } else if (t && !t.startsWith("#")) {
      if (cur.height !== undefined) {
        out.push({ height: cur.height ?? 0, bandwidth: cur.bandwidth ?? 0, uri: t });
        cur = {};
      }
    }
  }
  return out;
}

export function parseMediaSegments(text: string, base: string): { u: string; d: number }[] {
  const out: { u: string; d: number }[] = [];
  let dur = 0;
  for (const raw of text.split("\n")) {
    const t = raw.trim();
    if (t.startsWith("#EXTINF:")) {
      dur = Number(t.slice(8).split(",")[0]) || 0;
    } else if (t && !t.startsWith("#")) {
      try {
        out.push({ u: t.startsWith("http") ? t : new URL(t, base).href, d: dur });
      } catch { /* skip bad uri */ }
      dur = 0;
    }
  }
  return out;
}

const segName = (i: number) => `seg${String(i).padStart(6, "0")}.ts`;

async function tmdbRuntimeSec(env: Env, mediaType: string, tmdbId: number): Promise<number | null> {
  const bearer = await secretText(env.WATCH_TMDB_API_READ_ACCESS_TOKEN);
  const apiKey = await secretText(env.WATCH_TMDB_API_KEY);
  const headers: Record<string, string> = { Accept: "application/json", "User-Agent": "Watch/1" };
  let url = `https://api.themoviedb.org/3/${mediaType}/${tmdbId}?language=en-US`;
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  else if (apiKey) url += `&api_key=${encodeURIComponent(apiKey)}`;
  else return null;
  try {
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const body = await res.json() as { runtime?: number; episode_run_time?: number[] };
    const min = body.runtime ?? body.episode_run_time?.[0] ?? null;
    return min ? min * 60 : null;
  } catch {
    return null;
  }
}

async function secretText(value: string | { get?: () => Promise<string> } | undefined): Promise<string> {
  if (!value) return "";
  if (typeof value === "string") return value;
  try { return (await value.get?.()) || ""; } catch { return ""; }
}

type SaveBody = {
  playlistUrl?: string;
  referer?: string;
  tmdbId?: number;
  mediaType?: "movie" | "tv";
  season?: number;
  episode?: number;
};

/** POST /v1/relay/save — fan out a chunked persist job. */
export async function handleRelaySave(request: Request, env: Env): Promise<Response> {
  let body: SaveBody;
  try {
    body = (await request.json()) as SaveBody;
  } catch {
    return json({ error: "bad_body" }, 400);
  }
  const playlistUrl = String(body.playlistUrl || "");
  const referer = body.referer ? String(body.referer) : null;
  const tmdbId = Number(body.tmdbId);
  const mediaType = body.mediaType === "tv" ? "tv" : "movie";
  if (!playlistUrl || bad(playlistUrl) || !tmdbId) return json({ error: "playlistUrl_tmdbId_required" }, 400);
  if (!env.HLS_SAVE_QUEUE) return json({ error: "save_queue_unconfigured" }, 503);

  const masterRes = await fetch(playlistUrl, { headers: relayHeaders(referer), signal: AbortSignal.timeout(15000) });
  if (!masterRes.ok) return json({ error: "playlist_fetch_failed" }, 502);
  const masterText = await masterRes.text();
  if (!masterText.includes("#EXTM3U")) return json({ error: "not_a_playlist" }, 502);

  // Captured URL may already be a media playlist.
  let variantUrl = playlistUrl;
  let variantText = masterText;
  if (masterText.includes("#EXT-X-STREAM-INF")) {
    const base = playlistUrl.slice(0, playlistUrl.lastIndexOf("/") + 1);
    const variants = parseMasterVariants(masterText).map((v) => ({
      ...v,
      uri: v.uri.startsWith("http") ? v.uri : new URL(v.uri, base).href,
    }));
    const runtimeSec = await tmdbRuntimeSec(env, mediaType, tmdbId);
    const pick = pickSaveVariant(variants, runtimeSec);
    if (pick < 0) return json({ error: "no_usable_variant" }, 502);
    variantUrl = variants[pick]!.uri;
    const vRes = await fetch(variantUrl, { headers: relayHeaders(referer), signal: AbortSignal.timeout(15000) });
    if (!vRes.ok) return json({ error: "variant_fetch_failed" }, 502);
    variantText = await vRes.text();
  }
  const vBase = variantUrl.slice(0, variantUrl.lastIndexOf("/") + 1);
  const segs = parseMediaSegments(variantText, vBase);
  if (!segs.length) return json({ error: "no_segments" }, 502);

  // Variant meta for the picker record (best effort).
  const variants = parseMasterVariants(masterText);
  const picked = variants.find((v) => v.uri && variantUrl.endsWith(v.uri));
  const vHeight = picked?.height ?? 0;
  const vBandwidth = picked?.bandwidth ?? 0;

  const now = new Date().toISOString();
  const jobId = crypto.randomUUID();
  const season = Number(body.season) || 1;
  const episode = Number(body.episode) || 1;
  await env.watch
    .prepare(
      `INSERT INTO hls_job (id, title, tmdb_id, media_type, season, episode, variant_url, referer,
        vheight, vbandwidth, durations_json, total, done, bytes, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'saving', ?, ?)`,
    )
    .bind(
      jobId, `tmdb:${tmdbId}`, tmdbId, mediaType, season, episode,
      variantUrl, referer, vHeight, vBandwidth,
      JSON.stringify(segs.map((s) => s.d)), segs.length, now, now,
    )
    .run();

  const BATCH = 20;
  const height = vHeight;
  for (let i = 0; i < segs.length; i += BATCH * 5) {
    const msgs: SaveMessage[] = [];
    for (let j = i; j < Math.min(i + BATCH * 5, segs.length); j += BATCH) {
      msgs.push({
        jobId,
        height,
        referer,
        segs: segs.slice(j, j + BATCH).map((s, k) => ({ i: j + k, u: s.u })),
      });
    }
    await env.HLS_SAVE_QUEUE.sendBatch(msgs.map((m) => ({ body: m })));
  }
  return json({ id: jobId, total: segs.length, status: "saving" }, 201);
}

/** GET /v1/relay/save/:jobId — job status. */
export async function handleRelaySaveStatus(env: Env, jobId: string): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT id, title, total, done, bytes, status, movie_id, error FROM hls_job WHERE id = ?")
    .bind(jobId)
    .first<{ id: string; title: string; total: number; done: number; bytes: number; status: string; movie_id: string | null; error: string | null }>();
  if (!row) return json({ error: "not_found" }, 404);
  return json(row);
}

type JobRow = {
  id: string;
  variant_url: string;
  referer: string | null;
  vheight: number;
  durations_json: string;
  total: number;
  done: number;
  status: string;
};

/** Queue consumer: fetch one batch of segments into R2. */
export async function handleSaveBatch(msg: SaveMessage, env: Env): Promise<void> {
  const job = await env.watch
    .prepare("SELECT id, variant_url, referer, vheight, durations_json, total, done, status FROM hls_job WHERE id = ?")
    .bind(msg.jobId)
    .first<JobRow>();
  if (!job || (job.status !== "saving" && job.status !== "finalizing")) return;

  const ref = msg.referer ?? job.referer;
  let bytes = 0;
  let ok = 0;
  const PAR = 6;
  for (let i = 0; i < msg.segs.length; i += PAR) {
    const slice = msg.segs.slice(i, i + PAR);
    const results = await Promise.all(
      slice.map(async (s) => {
        try {
          const res = await fetch(s.u, { headers: relayHeaders(ref), signal: AbortSignal.timeout(30000) });
          if (!res.ok || !res.body) return null;
          const buf = new Uint8Array(await res.arrayBuffer());
          if (!buf.length) return null;
          await env.watch_bucket.put(`hls/${msg.jobId}/${msg.height}p/${segName(s.i)}`, buf, {
            httpMetadata: { contentType: "video/mp2t" },
          });
          return buf.length;
        } catch {
          return null;
        }
      }),
    );
    for (const n of results) {
      if (n) {
        ok++;
        bytes += n;
      }
    }
  }
  if (ok) {
    await env.watch
      .prepare("UPDATE hls_job SET done = done + ?, bytes = bytes + ?, updated_at = ? WHERE id = ?")
      .bind(ok, bytes, new Date().toISOString(), msg.jobId)
      .run();
  }
  await maybeFinalize(env, msg.jobId);
}

class SaveCheckError extends Error {}

/** First 376 bytes of a saved segment: enough to see two MPEG-TS sync bytes. */
async function sampleSegment(env: Env, key: string): Promise<Uint8Array | null> {
  const obj = await env.watch_bucket.get(key, { range: { offset: 0, length: 376 } });
  return obj ? new Uint8Array(await obj.arrayBuffer()) : null;
}

export async function purgeJob(env: Env, jobId: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await env.watch_bucket.list({ prefix: `hls/${jobId}/`, cursor, limit: 1000 });
    if (page.objects.length) await env.watch_bucket.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

async function maybeFinalize(env: Env, jobId: string): Promise<void> {
  const claim = await env.watch
    .prepare(
      `UPDATE hls_job SET status = 'finalizing', updated_at = ?
       WHERE id = ? AND status = 'saving' AND done >= total`,
    )
    .bind(new Date().toISOString(), jobId)
    .run();
  const claimed = (claim.meta?.changes ?? 0) > 0;
  if (!claimed) return;

  const job = await env.watch
    .prepare("SELECT * FROM hls_job WHERE id = ?")
    .bind(jobId)
    .first<JobRow & { title: string; tmdb_id: number; media_type: string; season: number; episode: number; referer: string | null; bytes: number; vbandwidth: number }>();
  if (!job) return;
  try {
    const durations = JSON.parse(job.durations_json) as number[];
    const prefix = `hls/${jobId}/${job.vheight}p`;
    const durationSec = durations.reduce((a, b) => a + b, 0);
    const [firstSegment, lastSegment, expectedSec] = await Promise.all([
      sampleSegment(env, `${prefix}/${segName(0)}`),
      sampleSegment(env, `${prefix}/${segName(durations.length - 1)}`),
      tmdbRuntimeSec(env, job.media_type, job.tmdb_id),
    ]);
    const check = checkSavedStream({
      mediaType: job.media_type, total: job.total, done: job.done, bytes: job.bytes, bandwidth: job.vbandwidth,
      durationSec, expectedSec, firstSegment, lastSegment,
    });
    console.log(JSON.stringify({
      evt: "relay_save_check", jobId, tmdbId: job.tmdb_id, season: job.season, episode: job.episode,
      durationSec: Math.round(durationSec), expectedSec, bytes: job.bytes,
      ...(check.ok ? { ok: true, note: check.note } : { ok: false, reason: check.reason }),
    }));
    if (!check.ok) throw new SaveCheckError(check.reason);
    const lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:12", "#EXT-X-PLAYLIST-TYPE:VOD"];
    for (let i = 0; i < durations.length; i++) {
      lines.push(`#EXTINF:${(durations[i] ?? 6).toFixed(3)},`);
      lines.push(segName(i));
    }
    lines.push("#EXT-X-ENDLIST");
    await env.watch_bucket.put(`${prefix}/index.m3u8`, lines.join("\n") + "\n", {
      httpMetadata: { contentType: "application/vnd.apple.mpegurl" },
    });
    await env.watch_bucket.put(
      `hls/${jobId}/master.m3u8`,
      `#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n${job.vheight}p/index.m3u8\n`,
      { httpMetadata: { contentType: "application/vnd.apple.mpegurl" } },
    );

    const movieId = crypto.randomUUID();
    const now = new Date().toISOString();
    const label = job.title.startsWith("tmdb:") ? `tmdb ${job.tmdb_id}` : job.title;
    await env.watch
      .prepare(
        `INSERT INTO movie (id, filename, byte_size, content_type, ext, title, original_title, year, status,
          match_source, match_note, runtime_min, hls_url, created_at, updated_at)
         VALUES (?, ?, ?, 'video/mp4', 'mp4', ?, ?, NULL, 'ready', 'rive-save', ?, ?, ?, ?, ?)`,
      )
      .bind(
        movieId, `${label}.mp4`, job.bytes, label, label,
        `Saved ${job.media_type} ${job.tmdb_id} S${job.season}E${job.episode} ${job.vheight}p · ${check.note}`,
        Math.round(durationSec / 60), `/v1/hls/${jobId}/master.m3u8`, now, now,
      )
      .run();
    await env.watch
      .prepare("UPDATE hls_job SET status = 'done', movie_id = ?, updated_at = ? WHERE id = ?")
      .bind(movieId, now, jobId)
      .run();
  } catch (err) {
    const message = err instanceof Error ? err.message : "finalize_failed";
    // A failed check means the saved chunks are not a title; drop them. Other errors may be transient.
    if (err instanceof SaveCheckError) await purgeJob(env, jobId);
    await env.watch
      .prepare("UPDATE hls_job SET status = 'error', error = ?, updated_at = ? WHERE id = ?")
      .bind(message.slice(0, 500), new Date().toISOString(), jobId)
      .run();
  }
}

/** GET /v1/hls/:jobId/... — serve persisted chunks. */
export async function handleHlsServe(env: Env, jobId: string, rest: string, request: Request): Promise<Response> {
  if (rest.includes("..")) return json({ error: "bad_path" }, 400);
  const key = `hls/${jobId}/${rest}`;
  const head = await env.watch_bucket.head(key);
  if (!head) return json({ error: "not_found" }, 404);
  const isPl = rest.endsWith(".m3u8");
  const headers = new Headers({
    "content-type": isPl ? "application/vnd.apple.mpegurl" : "video/mp2t",
    "cache-control": isPl ? "public, max-age=3600" : "public, max-age=31536000",
    "accept-ranges": "bytes",
  });
  const rangeHeader = request.headers.get("range");
  const m = rangeHeader?.match(/bytes=(\d+)-(\d*)/);
  if (m) {
    const start = Number(m[1]);
    const end = m[2] ? Number(m[2]) : head.size - 1;
    if (Number.isFinite(start) && start < head.size && end >= start) {
      const len = Math.min(end, head.size - 1) - start + 1;
      const obj = await env.watch_bucket.get(key, { range: { offset: start, length: len } });
      if (obj) {
        headers.set("content-length", String(len));
        headers.set("content-range", `bytes ${start}-${start + len - 1}/${head.size}`);
        return new Response(obj.body, { status: 206, headers });
      }
    }
  }
  const obj = await env.watch_bucket.get(key);
  if (!obj) return json({ error: "not_found" }, 404);
  return new Response(obj.body, { headers });
}
