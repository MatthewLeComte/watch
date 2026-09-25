import type { Env } from "./env";
import { cinemetaMeta } from "./cinemeta";
import { ingest, saveCache } from "./ingest";
import { contentTypeFor, extOf, parseByteRange, parseReleaseName, pickTrailerId, srtToVtt } from "./lib";
import type { TrailerVideo } from "./lib";
import { handleWatchMcp } from "./mcp";

/** R2 requires every part except the last to be at least 5 MiB. 8 MiB matches that rule. */
const PART = 8 * 1024 * 1024;

type MovieRow = {
  id: string;
  filename: string;
  byte_size: number;
  content_type: string;
  ext: string;
  title: string;
  original_title: string | null;
  year: number | null;
  overview: string;
  runtime_min: number | null;
  genres_json: string;
  imdb_id: string | null;
  os_hash: string | null;
  stream_uid: string | null;
  hls_url: string | null;
  thumbnail_url: string | null;
  download_url: string | null;
  ready_to_stream: number;
  trailer_site: string | null;
  trailer_key: string | null;
  trailer_url: string | null;
  trailer_r2_key: string | null;
  trailer_bytes: number | null;
  trailer_quality: string | null;
  trailer_status: string | null;
  trailer_note: string | null;
  status: string;
  match_source: string;
  match_p: number | null;
  match_note: string;
  created_at: string;
  updated_at: string;
};

type SubRow = {
  lang: string;
  label: string;
  source: string;
  release_name: string | null;
  hearing_impaired: number;
};

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    if (request.method === "GET" && (path === "/" || path === "/health" || path === "/v1/health")) {
      return json({ ok: true, name: "watch" });
    }
    if (path === "/v1/catalog" && request.method === "GET") {
      if (!(await rokuAuthorized(request, env))) return json({ error: "unauthorized" }, 401);
      return rokuCatalog(env);
    }
    const pull = path.match(/^\/v1\/pull\/([0-9a-f-]{36})$/i);
    if (pull && (request.method === "GET" || request.method === "HEAD")) return pullForStream(env, pull[1]!, request);
    const asset = path.match(/^\/v1\/items\/([0-9a-f-]{36})\/(poster|backdrop)$/i);
    if (asset && (request.method === "GET" || request.method === "HEAD")) {
      // Public by design: Roku Poster nodes cannot send auth headers, so
      // images stay ungated. URLs are unguessable UUIDs; catalog and media
      // (the expensive endpoints) are gated above and below.
      const id = asset[1]!;
      const kind = asset[2]!.toLowerCase();
      return kind === "poster" ? posterAsset(env, id, request) : backdropAsset(env, id, request);
    }
    const publicMedia = path.match(/^\/v1\/items\/([0-9a-f-]{36})\/media$/i);
    if (publicMedia && (request.method === "GET" || request.method === "HEAD")) {
      // iOS app streams with Bearer key or ?key=; Roku channel with keypair headers.
      const ok = (await rokuAuthorized(request, env)) || authorized(request, env.WATCH_KEY || "") || queryKey(request, env);
      if (!ok) return json({ error: "unauthorized" }, 401);
      return media(request, env, publicMedia[1]!);
    }
    const publicTrailer = path.match(/^\/v1\/items\/([0-9a-f-]{36})\/trailer$/i);
    if (publicTrailer && (request.method === "GET" || request.method === "HEAD")) {
      const ok = (await rokuAuthorized(request, env)) || authorized(request, env.WATCH_KEY || "") || queryKey(request, env);
      if (!ok) return json({ error: "unauthorized" }, 401);
      try {
        return await trailerFile(request, env, publicTrailer[1]!);
      } catch (err) {
        const message = err instanceof Error ? err.message : "failed";
        return json({ error: message }, 500);
      }
    }
    if (path === "/mcp" || path === "/api/mcp") {
      if (!authorized(request, env.WATCH_KEY || "")) return json({ ok: false, error: "unauthorized" }, 401);
      return handleWatchMcp(request, env);
    }
    if (!authorized(request, env.WATCH_KEY || "")) return json({ error: "unauthorized" }, 401);
    try {
      if (request.method === "GET" && path === "/v1/items") return listItems(env);
      if (request.method === "POST" && path === "/v1/items") return createItem(request, env);
      if (path === "/v1/items/all/rematch" && request.method === "POST") return rematchAll(env);
      if (path === "/v1/trailers/backfill" && request.method === "POST") return backfillTrailers(request, env);
      const item = path.match(/^\/v1\/items\/([0-9a-f-]{36})(?:\/(.*))?$/i);
      if (!item) return json({ error: "not_found" }, 404);
      const id = item[1]!;
      const rest = item[2] ?? "";
      if (!rest && request.method === "GET") return oneItem(env, id);
      if (!rest && request.method === "PATCH") return patchItem(request, env, id);
      if (!rest && request.method === "DELETE") return deleteItem(env, id);
      if (rest === "complete" && request.method === "POST") return completeItem(env, id);
      if (rest === "stream" && request.method === "POST") return publishItem(env, id);
      if (rest === "purge" && request.method === "POST") return purgeOriginal(env, id);
      if (rest === "playback" && request.method === "GET") return playbackItem(env, id);
      if (rest === "rematch" && request.method === "POST") return rematch(env, id);
      if (rest === "trailer/resolve" && request.method === "POST") return resolveTrailerRoute(env, id);
      if (rest === "poster" && request.method === "PUT") return putPoster(request, env, id);
      const part = rest.match(/^parts\/(\d+)$/);
      if (part && request.method === "PUT") return uploadPart(request, env, id, Number(part[1]));
      const sub = rest.match(/^subtitles\/([a-z]{2,3})$/);
      if (sub && request.method === "GET") return subtitle(env, id, sub[1]!);
      if (sub && request.method === "PUT") return putSubtitle(request, env, id, sub[1]!);
      return json({ error: "not_found" }, 404);
    } catch (err) {
      const message = err instanceof Error ? err.message : "failed";
      return json({ error: message }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

function authorized(request: Request, key: string): boolean {
  if (!key) return false;
  const header = request.headers.get("authorization") || "";
  const got = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (got.length !== key.length) return false;
  let n = 0;
  for (let i = 0; i < got.length; i++) n |= got.charCodeAt(i) ^ key.charCodeAt(i);
  return n === 0;
}

/** Validate Roku app request: public key ID + private secret + device ID.
 * Secrets come from Secrets Store (cached per isolate); any failure denies. */
async function rokuAuthorized(request: Request, env: Env): Promise<boolean> {
  const secrets = await rokuSecrets(env);
  if (!secrets) return false;
  const keyId = request.headers.get("x-key-id") || "";
  const apiKey = request.headers.get("x-api-key") || "";
  const deviceId = request.headers.get("x-device-id") || "";
  if (!deviceId) return false;
  if (!constantTimeEqual(keyId, secrets.pub) || !constantTimeEqual(apiKey, secrets.priv)) return false;
  const allowed = (env.ROKU_ALLOWED_DEVICES || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (allowed.length > 0 && !allowed.includes(deviceId)) return false;
  return true;
}

type RokuSecrets = { pub: string; priv: string };
let rokuSecretsCache: RokuSecrets | null = null;

async function rokuSecrets(env: Env): Promise<RokuSecrets | null> {
  if (rokuSecretsCache) return rokuSecretsCache;
  try {
    const getPub = env.WATCH_PUBLIC_KEY?.get?.();
    const getPriv = env.WATCH_PRIVATE_KEY?.get?.();
    if (!getPub || !getPriv) return null;
    const [pub, priv] = await Promise.all([getPub, getPriv]);
    if (!pub || !priv) return null;
    rokuSecretsCache = { pub, priv };
    return rokuSecretsCache;
  } catch {
    return null;
  }
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let n = 0;
  for (let i = 0; i < a.length; i++) n |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return n === 0;
}

/** Key via ?key= query param (Apple clients send it in the URL so auth
 * survives redirects and range follow-ups that can drop custom headers). */
function queryKey(request: Request, env: Env): boolean {
  if (!env.WATCH_KEY) return false;
  const got = new URL(request.url).searchParams.get("key") || "";
  return constantTimeEqual(got, env.WATCH_KEY);
}

function json(data: unknown, status = 200, extra?: HeadersInit): Response {
  const headers = new Headers(extra);
  headers.set("content-type", "application/json");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(data), { status, headers });
}

async function pullForStream(env: Env, token: string, request: Request): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT id, content_type, byte_size FROM movie WHERE pull_token = ?")
    .bind(token)
    .first<{ id: string; content_type: string; byte_size: number }>();
  if (!row) return json({ error: "not_found" }, 404);
  const headers = new Headers();
  headers.set("content-type", row.content_type || "video/mp4");
  headers.set("accept-ranges", "bytes");
  headers.set("content-length", String(row.byte_size));
  if (request.method === "HEAD") return new Response(null, { headers });
  const rangeHeader = request.headers.get("range");
  const range = rangeHeader ? parseByteRange(rangeHeader, row.byte_size) : null;
  const obj = range
    ? await env.watch_bucket.get(`video/${row.id}`, { range: { offset: range.offset, length: range.length } })
    : await env.watch_bucket.get(`video/${row.id}`);
  if (!obj) return json({ error: "missing_object" }, 404);
  if (range) {
    headers.set("content-length", String(range.length));
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${row.byte_size}`);
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
}

async function publishItem(env: Env, id: string): Promise<Response> {
  const row = await env.watch.prepare("SELECT id, title, stream_uid FROM movie WHERE id = ?").bind(id).first<{
    id: string;
    title: string;
    stream_uid: string | null;
  }>();
  if (!row) return json({ error: "not_found" }, 404);
  if (row.stream_uid) return playbackItem(env, id);
  try {
    await processToStream(env, id);
  } catch (err) {
    const message = err instanceof Error ? err.message : "stream_upload_failed";
    return json({ error: message }, 502);
  }
  return json(await loadItem(env, id));
}

async function playbackItem(env: Env, id: string): Promise<Response> {
  const row = await env.watch.prepare("SELECT stream_uid FROM movie WHERE id = ?").bind(id).first<{ stream_uid: string | null }>();
  if (!row?.stream_uid) return json({ error: "not_on_stream" }, 409);
  const video = await env.STREAM.video(row.stream_uid).details();
  let downloadUrl: string | null = null;
  try {
    const downloads = await env.STREAM.video(row.stream_uid).downloads.generate();
    downloadUrl = downloads.default?.url ?? null;
  } catch {
    try {
      const existing = await env.STREAM.video(row.stream_uid).downloads.get();
      downloadUrl = existing.default?.url ?? null;
    } catch {
      downloadUrl = null;
    }
  }
  await saveStream(env, id, video, downloadUrl);
  return json(await loadItem(env, id));
}

async function saveStream(env: Env, id: string, video: StreamVideo, downloadUrl?: string | null): Promise<void> {
  await env.watch
    .prepare(
      `UPDATE movie SET stream_uid = ?, hls_url = ?, thumbnail_url = ?, download_url = COALESCE(?, download_url),
       ready_to_stream = ?, runtime_min = CASE WHEN ? > 0 THEN ? ELSE runtime_min END, updated_at = ? WHERE id = ?`,
    )
    .bind(
      video.id,
      video.hlsPlaybackUrl,
      video.thumbnail,
      downloadUrl ?? null,
      video.readyToStream ? 1 : 0,
      video.duration,
      Math.round(video.duration / 60),
      new Date().toISOString(),
      id,
    )
    .run();
}

export async function listItems(env: Env): Promise<Response> {
  const rows = await env.watch.prepare("SELECT * FROM movie ORDER BY created_at DESC").all<MovieRow>();
  const subs = await env.watch.prepare("SELECT movie_id, lang, label, source, release_name, hearing_impaired FROM subtitle").all<
    SubRow & { movie_id: string }
  >();
  const byMovie = new Map<string, SubRow[]>();
  for (const sub of subs.results) {
    const list = byMovie.get(sub.movie_id) ?? [];
    list.push(sub);
    byMovie.set(sub.movie_id, list);
  }
  return json({ items: rows.results.map((row) => toItem(row, byMovie.get(row.id) ?? [])) });
}

export async function oneItem(env: Env, id: string): Promise<Response> {
  const item = await loadItem(env, id);
  if (!item) return json({ error: "not_found" }, 404);
  return json(item);
}

async function createItem(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as { filename?: string; byteSize?: number; contentType?: string };
  const filename = String(body.filename || "").slice(0, 300);
  const ext = extOf(filename);
  const byteSize = Number(body.byteSize);
  if (!ext) return json({ error: "use_mp4_m4v_or_mov" }, 400);
  if (!Number.isFinite(byteSize) || byteSize <= 0 || byteSize > 20 * 1024 * 1024 * 1024) {
    return json({ error: "bad_size" }, 400);
  }
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const contentType = contentTypeFor(ext);
  const upload = await env.watch_bucket.createMultipartUpload(`video/${id}`, {
    httpMetadata: { contentType },
  });
  const parsedTitle = parseReleaseName(filename).title;
  await env.watch
    .prepare(
      `INSERT INTO movie (id, filename, byte_size, content_type, ext, title, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'uploading', ?, ?)`,
    )
    .bind(id, filename, byteSize, contentType, ext, parsedTitle, now, now)
    .run();
  await env.watch
    .prepare("INSERT INTO upload (movie_id, upload_id, parts_json) VALUES (?, ?, '[]')")
    .bind(id, upload.uploadId)
    .run();
  return json({ id, partSize: PART }, 201);
}

async function uploadPart(request: Request, env: Env, id: string, partNumber: number): Promise<Response> {
  if (!request.body || partNumber < 1 || partNumber > 10000) return json({ error: "bad_part" }, 400);
  const row = await env.watch
    .prepare("SELECT upload_id, parts_json FROM upload WHERE movie_id = ?")
    .bind(id)
    .first<{ upload_id: string; parts_json: string }>();
  if (!row) return json({ error: "no_upload" }, 409);
  const size = Number(request.headers.get("content-length") || "0");
  const uploaded = await env.watch_bucket
    .resumeMultipartUpload(`video/${id}`, row.upload_id)
    .uploadPart(partNumber, request.body);
  const parts = JSON.parse(row.parts_json) as { partNumber: number; etag: string; size: number }[];
  const next = parts.filter((p) => p.partNumber !== partNumber);
  next.push({ partNumber, etag: uploaded.etag, size });
  await env.watch
    .prepare("UPDATE upload SET parts_json = ? WHERE movie_id = ?")
    .bind(JSON.stringify(next), id)
    .run();
  return json({ partNumber, etag: uploaded.etag, size });
}

async function completeItem(env: Env, id: string): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT upload_id, parts_json FROM upload WHERE movie_id = ?")
    .bind(id)
    .first<{ upload_id: string; parts_json: string }>();
  if (!row) {
    const existing = await loadItem(env, id);
    if (!existing) return json({ error: "not_found" }, 404);
    return json(existing);
  }
  const parts = (JSON.parse(row.parts_json) as { partNumber: number; etag: string; size: number }[]).sort(
    (a, b) => a.partNumber - b.partNumber,
  );
  if (!parts.length) return json({ error: "no_parts" }, 400);
  const last = parts[parts.length - 1]!.partNumber;
  for (const part of parts) {
    if (part.partNumber !== last && part.size < 5 * 1024 * 1024) {
      return json({ error: "part_too_small", part: part.partNumber }, 400);
    }
  }
  await env.watch_bucket.resumeMultipartUpload(`video/${id}`, row.upload_id).complete(
    parts.map((p) => ({ partNumber: p.partNumber, etag: p.etag })),
  );
  await env.watch.prepare("DELETE FROM upload WHERE movie_id = ?").bind(id).run();
  try {
    await ingest(env, id);
  } catch (err) {
    const note = err instanceof Error ? err.message : "ingest_failed";
    await env.watch
      .prepare("UPDATE movie SET status = 'ready', match_source = 'filename', match_note = ?, updated_at = ? WHERE id = ?")
      .bind(note.slice(0, 500), new Date().toISOString(), id)
      .run();
  }
  // Codec work stays on-device (Watch app VideoToolbox transcode).
  // Server only ingests metadata here; Stream publish stays manual.
  const item = await loadItem(env, id);
  return json(item);
}

/** Shared ingest→process step: upload the R2 original to Stream for encoding. */
async function processToStream(env: Env, id: string): Promise<void> {
  const row = await env.watch
    .prepare("SELECT id, title, stream_uid, status FROM movie WHERE id = ?")
    .bind(id)
    .first<{ id: string; title: string; stream_uid: string | null; status: string }>();
  if (!row || row.stream_uid || row.status === "uploading") return;
  const token = crypto.randomUUID();
  await env.watch.prepare("UPDATE movie SET pull_token = ?, status = 'processing', updated_at = ? WHERE id = ?")
    .bind(token, new Date().toISOString(), id)
    .run();
  const source = `https://watch.cornerstonecoatings.com/v1/pull/${token}`;
  const video = await env.STREAM.upload(source, {
    creator: "watch",
    meta: { movieId: id, title: row.title },
  });
  await saveStream(env, id, video);
}

/** Dump the R2 original once Stream holds a ready copy. Media then serves Stream. */
async function purgeOriginal(env: Env, id: string): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT stream_uid, ready_to_stream, download_url FROM movie WHERE id = ?")
    .bind(id)
    .first<{ stream_uid: string | null; ready_to_stream: number; download_url: string | null }>();
  if (!row?.stream_uid) return json({ error: "not_on_stream" }, 409);
  if (!row.ready_to_stream) return json({ error: "stream_not_ready" }, 409);
  if (!row.download_url) {
    try {
      const existing = await env.STREAM.video(row.stream_uid).downloads.get();
      const url = existing.default?.url ?? null;
      if (!url) return json({ error: "no_stream_download" }, 409);
      await env.watch.prepare("UPDATE movie SET download_url = ?, updated_at = ? WHERE id = ?")
        .bind(url, new Date().toISOString(), id)
        .run();
    } catch {
      return json({ error: "no_stream_download" }, 409);
    }
  }
  await env.watch_bucket.delete([`video/${id}`]);
  await env.watch.prepare("UPDATE movie SET pull_token = NULL, updated_at = ? WHERE id = ?")
    .bind(new Date().toISOString(), id)
    .run();
  return json(await loadItem(env, id));
}

export async function rematch(env: Env, id: string): Promise<Response> {
  const row = await env.watch.prepare("SELECT status FROM movie WHERE id = ?").bind(id).first<{ status: string }>();
  if (!row) return json({ error: "not_found" }, 404);
  if (row.status === "uploading") return json({ error: "still_uploading" }, 409);
  await ingest(env, id);
  return json(await loadItem(env, id));
}

export async function rematchAll(env: Env, limit = 500): Promise<Response> {
  const rows = await env.watch
    .prepare("SELECT id FROM movie ORDER BY created_at ASC LIMIT ?")
    .bind(limit)
    .all<{ id: string }>();
  const results: { id: string; ok: boolean; title?: string; overviewLen?: number; runtimeMin?: number | null; genres?: string[]; error?: string }[] = [];
  // Run ingests in parallel, 6 at a time, so a single worker invocation
  // finishes well under the 30s CPU cap while still burning the full
  // outbound concurrency budget. One slow movie does not block the queue.
  const BATCH = 6;
  for (let i = 0; i < rows.results.length; i += BATCH) {
    const slice = rows.results.slice(i, i + BATCH);
    const batch = await Promise.all(slice.map(async (row) => {
      try {
        await ingest(env, row.id);
        const item = await loadItem(env, row.id);
        return {
          id: row.id,
          ok: true as const,
          title: item?.title,
          overviewLen: item?.overview?.length ?? 0,
          runtimeMin: item?.runtimeMin ?? null,
          genres: item?.genres ?? [],
        };
      } catch (e) {
        return { id: row.id, ok: false as const, error: e instanceof Error ? e.message : "failed" };
      }
    }));
    for (const r of batch) results.push(r);
  }
  const filled = results.filter((r) => r.ok && ((r.overviewLen ?? 0) > 0 || (r.runtimeMin ?? null) != null || (r.genres?.length ?? 0) > 0)).length;
  return json({ processed: results.length, filled, failed: results.filter((r) => !r.ok).length, results });
}

export async function patchItem(request: Request, env: Env, id: string): Promise<Response> {
  const body = (await request.json()) as {
    title?: string;
    year?: number | null;
    overview?: string;
    imdbId?: string;
  };
  const imdbId = typeof body.imdbId === "string" ? body.imdbId.trim().toLowerCase() : "";
  if (/^tt\d{7,8}$/.test(imdbId)) {
    const page = await cinemetaMeta(imdbId);
    if (!page) return json({ error: "imdb_not_found" }, 404);
    // Store both images to R2 — same write path the matcher uses, so the
    // Roku endpoints light up immediately after a manual correction.
    if (page.poster) {
      try {
        const img = await fetch(page.poster, { signal: AbortSignal.timeout(8000) });
        if (img.ok) {
          const buf = await img.arrayBuffer();
          if (buf.byteLength >= 4096 && buf.byteLength <= 1_000_000) {
            await env.watch_bucket.put(`poster/${id}`, buf, {
              httpMetadata: { contentType: img.headers.get("content-type") || "image/jpeg" },
            });
          }
        }
      } catch { /* keep going without poster */ }
    }
    if (page.background) {
      try {
        const img = await fetch(page.background, { signal: AbortSignal.timeout(8000) });
        if (img.ok) {
          const buf = await img.arrayBuffer();
          if (buf.byteLength >= 4096 && buf.byteLength <= 1_500_000) {
            await env.watch_bucket.put(`backdrop/${id}`, buf, {
              httpMetadata: { contentType: img.headers.get("content-type") || "image/jpeg" },
            });
          }
        }
      } catch { /* keep going without backdrop */ }
    }
    const year = page.year ? Number(page.year) || null : null;
    const trailerSite = page.trailerKey ? "youtube" : null;
    const trailerKey = page.trailerKey || null;
    const trailerUrl = page.trailerKey ? `https://www.youtube.com/watch?v=${page.trailerKey}` : null;
    await env.watch
      .prepare(
        `UPDATE movie SET title = ?, year = ?, overview = ?, runtime_min = ?, genres_json = ?,
         imdb_id = ?, trailer_site = ?, trailer_key = ?, trailer_url = ?,
         match_source = 'manual', match_note = ?, updated_at = ? WHERE id = ?`,
      )
      .bind(
        page.name || imdbId,
        year,
        page.description,
        page.runtimeMin,
        JSON.stringify(page.genres),
        imdbId,
        trailerSite,
        trailerKey,
        trailerUrl,
        `Corrected to ${imdbId}`,
        new Date().toISOString(),
        id,
      )
      .run();
    // Refresh the per-imdbId cache so the next file that resolves to
    // this id inherits the manual correction instead of re-fetching.
    if (page.name || page.description || page.poster) {
      await saveCache(env, imdbId, {
        title: page.name,
        year,
        overview: page.description,
        posterUrl: page.poster,
        backdropUrl: page.background,
        runtimeMin: page.runtimeMin,
        genres: page.genres,
        imdbId,
        trailerKey: page.trailerKey,
      });
    }
    return json(await loadItem(env, id));
  }
  const current = await env.watch.prepare("SELECT id FROM movie WHERE id = ?").bind(id).first();
  if (!current) return json({ error: "not_found" }, 404);
  const title = typeof body.title === "string" ? body.title.slice(0, 300) : null;
  const overview = typeof body.overview === "string" ? body.overview.slice(0, 2000) : null;
  const clearYear = Object.prototype.hasOwnProperty.call(body, "year") && body.year === null;
  const year = typeof body.year === "number" && Number.isFinite(body.year) ? body.year : null;
  await env.watch
    .prepare(
      `UPDATE movie SET
         title = COALESCE(?, title),
         year = CASE WHEN ? THEN NULL ELSE COALESCE(?, year) END,
         overview = COALESCE(?, overview),
         match_source = 'manual',
         match_note = 'Edited in Settings',
         updated_at = ?
       WHERE id = ?`,
    )
    .bind(title, clearYear ? 1 : 0, year, overview, new Date().toISOString(), id)
    .run();
  return json(await loadItem(env, id));
}

export async function deleteItem(env: Env, id: string): Promise<Response> {
  const upload = await env.watch
    .prepare("SELECT upload_id FROM upload WHERE movie_id = ?")
    .bind(id)
    .first<{ upload_id: string }>();
  if (upload) {
    try {
      await env.watch_bucket.resumeMultipartUpload(`video/${id}`, upload.upload_id).abort();
    } catch {
      /* already gone */
    }
  }
  const subs = await env.watch.prepare("SELECT r2_key FROM subtitle WHERE movie_id = ?").bind(id).all<{ r2_key: string }>();
  await env.watch_bucket.delete([
    `video/${id}`,
    `poster/${id}`,
    ...subs.results.map((s) => s.r2_key),
  ]);
  await env.watch.prepare("DELETE FROM subtitle WHERE movie_id = ?").bind(id).run();
  await env.watch.prepare("DELETE FROM upload WHERE movie_id = ?").bind(id).run();
  await env.watch.prepare("DELETE FROM movie WHERE id = ?").bind(id).run();
  return json({ ok: true });
}

async function media(request: Request, env: Env, id: string): Promise<Response> {
  const movie = await env.watch
    .prepare("SELECT byte_size, content_type, status, download_url, stream_uid FROM movie WHERE id = ?")
    .bind(id)
    .first<{ byte_size: number; content_type: string; status: string; download_url: string | null; stream_uid: string | null }>();
  if (!movie || movie.status === "uploading" || movie.status === "processing") return json({ error: "not_found" }, 404);
  const headers = new Headers();
  headers.set("content-type", movie.content_type);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", "private, no-store");
  if (request.method === "HEAD") {
    const head = await env.watch_bucket.get(`video/${id}`, { range: { offset: 0, length: 1 } });
    if (head) {
      headers.set("content-length", String(movie.byte_size));
      return new Response(null, { status: 200, headers });
    }
    if (movie.download_url) return Response.redirect(movie.download_url, 302);
    return json({ error: "use_playback", hls: true }, 409);
  }
  const rangeHeader = request.headers.get("range");
  if (!rangeHeader) {
    const obj = await env.watch_bucket.get(`video/${id}`);
    if (obj) {
      headers.set("content-length", String(obj.size));
      return new Response(obj.body, { status: 200, headers });
    }
    // Original purged after Stream processing — serve the Stream copy.
    if (movie.download_url) return Response.redirect(movie.download_url, 302);
    return json({ error: "use_playback", hls: true }, 409);
  }
  const range = parseByteRange(rangeHeader, movie.byte_size);
  if (!range) {
    headers.set("content-range", `bytes */${movie.byte_size}`);
    return new Response(null, { status: 416, headers });
  }
  const obj = await env.watch_bucket.get(`video/${id}`, {
    range: { offset: range.offset, length: range.length },
  });
  if (obj) {
    const end = range.offset + range.length - 1;
    headers.set("content-range", `bytes ${range.offset}-${end}/${movie.byte_size}`);
    headers.set("content-length", String(range.length));
    return new Response(obj.body, { status: 206, headers });
  }
  // Original purged: proxy the byte range from the Stream download so
  // existing players keep working without the R2 original.
  if (movie.download_url) {
    const upstream = await fetch(movie.download_url, { headers: { Range: rangeHeader } });
    const out = new Headers();
    out.set("content-type", movie.content_type);
    out.set("accept-ranges", "bytes");
    out.set("cache-control", "private, no-store");
    const cr = upstream.headers.get("content-range");
    const cl = upstream.headers.get("content-length");
    if (cr) out.set("content-range", cr);
    if (cl) out.set("content-length", cl);
    return new Response(upstream.body, { status: upstream.status === 206 ? 206 : 200, headers: out });
  }
  return json({ error: "use_playback", hls: true }, 409);
}

// MARK: - Trailers: HD files on R2, deduped by YouTube id, quality-checked.
//
// Pick: Kinocheck (matched to our IMDb id, English pure trailers, most views).
// Fetch: Piped API resolves the YouTube id to a direct ≤1080p h264 MP4 URL,
// which the worker downloads straight into R2. One R2 object per YouTube id,
// shared by every movie that uses it.

const KINOCHECK = "https://api.kinocheck.com/movies";
const PIPED_DEFAULTS = [
  "https://pipedapi.reallyaweso.me",
  "https://pipedapi.adminforge.de",
  "https://pipedapi.kavin.rocks",
];
const TRAILER_MAX_BYTES = 400 * 1024 * 1024;
const TRAILER_MIN_BYTES = 512 * 1024;

function pipedInstances(env: Env): string[] {
  const custom = (env.TRAILER_RESOLVER || "")
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter(Boolean);
  return custom.length > 0 ? custom : PIPED_DEFAULTS;
}

async function kinocheckTrailerId(imdbId: string): Promise<string | null> {
  const res = await fetch(`${KINOCHECK}?imdb_id=${encodeURIComponent(imdbId)}&language=en`, {
    headers: { "User-Agent": "Watch/1", Accept: "application/json" },
  });
  if (!res.ok) return null;
  const obj = (await res.json()) as { trailer?: TrailerVideo; videos?: TrailerVideo[] };
  return pickTrailerId(obj);
}

type PipedStream = { fileUrl: string; quality: string };

async function pipedStream(env: Env, ytId: string): Promise<PipedStream | null> {
  for (const base of pipedInstances(env)) {
    try {
      const res = await fetch(`${base}/streams/${ytId}`, {
        headers: { "User-Agent": "Watch/1", Accept: "application/json" },
      });
      if (!res.ok) continue;
      const obj = (await res.json()) as {
        videoStreams?: Array<{ url?: string; quality?: string; codec?: string; mimeType?: string; format?: string }>;
      };
      const cands: Array<{ url: string; h: number }> = [];
      for (const s of obj.videoStreams ?? []) {
        if (!s.url) continue;
        const m = /^(\d+)p/.exec(s.quality ?? "");
        if (!m) continue;
        const h = Number(m[1]);
        if (h < 720 || h > 1080) continue;
        const codec = (s.codec ?? "").toLowerCase();
        const mime = (s.mimeType ?? "").toLowerCase();
        const format = (s.format ?? "").toLowerCase();
        if (!codec.includes("avc") && !mime.includes("mp4") && !format.includes("mp4")) continue;
        cands.push({ url: s.url, h });
      }
      cands.sort((a, b) => b.h - a.h);
      if (cands[0]) return { fileUrl: cands[0].url, quality: `${cands[0].h}p` };
    } catch {
      continue;
    }
  }
  return null;
}

type ResolveResult = { http: number; body: Record<string, unknown> };

async function markTrailer(
  env: Env,
  id: string,
  patch: { r2?: string | null; bytes?: number | null; quality?: string | null; status: string; note?: string | null },
): Promise<void> {
  await env.watch
    .prepare(
      "UPDATE movie SET trailer_r2_key = ?, trailer_bytes = ?, trailer_quality = ?, trailer_status = ?, trailer_note = ?, updated_at = ? WHERE id = ?",
    )
    .bind(patch.r2 ?? null, patch.bytes ?? null, patch.quality ?? null, patch.status, patch.note ?? null, new Date().toISOString(), id)
    .run();
}

async function resolveTrailerFile(env: Env, id: string): Promise<ResolveResult> {
  await ensureTrailerSchema(env);
  const movie = await env.watch
    .prepare("SELECT id, imdb_id, trailer_key, trailer_status, trailer_r2_key FROM movie WHERE id = ?")
    .bind(id)
    .first<{ id: string; imdb_id: string | null; trailer_key: string | null; trailer_status: string | null; trailer_r2_key: string | null }>();
  if (!movie) return { http: 404, body: { ok: false, error: "not_found" } };
  if (movie.trailer_status === "ready" && movie.trailer_r2_key && (await env.watch_bucket.head(movie.trailer_r2_key))) {
    return { http: 200, body: { ok: true, deduped: true } };
  }
  const ytId = movie.trailer_key || (movie.imdb_id ? await kinocheckTrailerId(movie.imdb_id) : null);
  if (!ytId) {
    await markTrailer(env, id, { status: "failed", note: "no_trailer_found" });
    return { http: 404, body: { ok: false, error: "no_trailer_found" } };
  }
  const key = `trailers/${ytId}.mp4`;
  if (await env.watch_bucket.head(key)) {
    const existing = await env.watch
      .prepare("SELECT trailer_bytes, trailer_quality FROM movie WHERE trailer_r2_key = ? LIMIT 1")
      .bind(key)
      .first<{ trailer_bytes: number | null; trailer_quality: string | null }>();
    await markTrailer(env, id, {
      r2: key,
      bytes: existing?.trailer_bytes ?? null,
      quality: existing?.trailer_quality ?? null,
      status: "ready",
      note: "deduped",
    });
    return { http: 200, body: { ok: true, deduped: true, quality: existing?.trailer_quality ?? null } };
  }
  const stream = await pipedStream(env, ytId);
  if (!stream) {
    await markTrailer(env, id, { status: "failed", note: "no_hd_stream" });
    return { http: 502, body: { ok: false, error: "no_hd_stream" } };
  }
  const up = await fetch(stream.fileUrl, { headers: { "User-Agent": "Watch/1" } });
  const ctype = up.headers.get("content-type") || "";
  const clen = Number(up.headers.get("content-length") || "0");
  if (!up.ok || !up.body || !ctype.startsWith("video/") || clen > TRAILER_MAX_BYTES || (clen > 0 && clen < TRAILER_MIN_BYTES)) {
    await markTrailer(env, id, { status: "failed", note: "bad_upstream" });
    return { http: 502, body: { ok: false, error: "bad_upstream" } };
  }
  await env.watch_bucket.put(key, up.body, { httpMetadata: { contentType: "video/mp4" } });
  const bytes = (await env.watch_bucket.head(key))?.size ?? 0;
  if (bytes < TRAILER_MIN_BYTES) {
    await env.watch_bucket.delete(key);
    await markTrailer(env, id, { status: "failed", note: "too_small" });
    return { http: 502, body: { ok: false, error: "too_small" } };
  }
  await markTrailer(env, id, { r2: key, bytes, quality: stream.quality, status: "ready" });
  return { http: 200, body: { ok: true, deduped: false, quality: stream.quality, bytes } };
}

async function resolveTrailerRoute(env: Env, id: string): Promise<Response> {
  const r = await resolveTrailerFile(env, id);
  return json(r.body, r.http);
}

/** Self-healing schema: D1 migrations only run when the deploy pipeline runs
 * them. If they didn't, resolve would 500 on missing columns forever. */
let trailerSchemaReady = false;
async function ensureTrailerSchema(env: Env): Promise<void> {
  if (trailerSchemaReady) return;
  trailerSchemaReady = true;
  const alters = [
    "ALTER TABLE movie ADD COLUMN trailer_r2_key TEXT",
    "ALTER TABLE movie ADD COLUMN trailer_bytes INTEGER",
    "ALTER TABLE movie ADD COLUMN trailer_quality TEXT",
    "ALTER TABLE movie ADD COLUMN trailer_status TEXT DEFAULT 'missing'",
    "ALTER TABLE movie ADD COLUMN trailer_note TEXT",
  ];
  for (const sql of alters) {
    try {
      await env.watch.prepare(sql).run();
    } catch {
      // Column already exists.
    }
  }
}

async function backfillTrailers(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as { limit?: number };
  const limit = Math.min(Math.max(Number(body.limit) || 3, 1), 10);
  const rows = await env.watch
    .prepare("SELECT id FROM movie WHERE trailer_status IS NULL OR trailer_status IN ('missing','failed') ORDER BY created_at ASC LIMIT ?")
    .bind(limit)
    .all<{ id: string }>();
  const results: Array<Record<string, unknown>> = [];
  for (const r of rows.results ?? []) {
    const out = await resolveTrailerFile(env, r.id);
    results.push({ id: r.id, ...out.body });
  }
  return json({ ok: true, results });
}

async function trailerFile(request: Request, env: Env, id: string): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT trailer_r2_key, trailer_bytes FROM movie WHERE id = ?")
    .bind(id)
    .first<{ trailer_r2_key: string | null; trailer_bytes: number | null }>();
  if (!row?.trailer_r2_key) return json({ error: "no_trailer" }, 404);
  const headers = new Headers();
  headers.set("content-type", "video/mp4");
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", "public, max-age=86400");
  const rangeHeader = request.headers.get("range");
  if (!rangeHeader) {
    const obj = await env.watch_bucket.get(row.trailer_r2_key);
    if (!obj) return json({ error: "missing_object" }, 404);
    headers.set("content-length", String(obj.size));
    return new Response(obj.body, { status: 200, headers });
  }
  const size = row.trailer_bytes ?? (await env.watch_bucket.head(row.trailer_r2_key))?.size ?? 0;
  const range = parseByteRange(rangeHeader, size);
  if (!range || size <= 0) {
    headers.set("content-range", `bytes */${size}`);
    return new Response(null, { status: 416, headers });
  }
  const obj = await env.watch_bucket.get(row.trailer_r2_key, { range: { offset: range.offset, length: range.length } });
  if (!obj) return json({ error: "missing_object" }, 404);
  headers.set("content-length", String(range.length));
  headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`);
  return new Response(obj.body, { status: 206, headers });
}

async function rokuCatalog(env: Env): Promise<Response> {
  const res = await listItems(env);
  const body = await res.text();
  const headers = new Headers(ASSET_CORS);
  headers.set("content-type", "application/json");
  // private: this endpoint requires auth, so shared caches must not store it.
  headers.set("cache-control", "private, max-age=60");
  return new Response(body, { status: 200, headers });
}

async function posterAsset(env: Env, id: string, request: Request): Promise<Response> {
  return serveImageAsset(env, id, request, "poster", "no_poster");
}

async function backdropAsset(env: Env, id: string, request: Request): Promise<Response> {
  return serveImageAsset(env, id, request, "backdrop", "no_backdrop");
}

async function serveImageAsset(
  env: Env,
  id: string,
  request: Request,
  kind: "poster" | "backdrop",
  notFoundError: string,
): Promise<Response> {
  const obj = await env.watch_bucket.get(`${kind}/${id}`);
  const type = obj?.httpMetadata?.contentType || "";
  const valid = obj && (type === "image/jpeg" || type === "image/webp") && obj.size >= 4096 && obj.size <= 2 * 1024 * 1024;
  if (!valid) {
    const headers = new Headers(ASSET_CORS);
    headers.set("content-type", "application/json");
    headers.set("cache-control", "public, max-age=300");
    return new Response(JSON.stringify({ error: notFoundError }), { status: 404, headers });
  }
  const etag = `"${obj.etag}"`;
  const headers = new Headers(ASSET_CORS);
  headers.set("etag", etag);
  headers.set("cache-control", "public, max-age=604800, immutable");
  const inm = request.headers.get("if-none-match");
  if (inm && inm.split(",").map((s) => s.trim()).includes(etag)) {
    return new Response(null, { status: 304, headers });
  }
  obj.writeHttpMetadata(headers);
  return new Response(obj.body, { headers });
}

const ASSET_CORS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, HEAD",
};

async function putPoster(request: Request, env: Env, id: string): Promise<Response> {
  const type = request.headers.get("content-type") || "";
  if (!type.startsWith("image/")) return json({ error: "not_image" }, 400);
  const buf = await request.arrayBuffer();
  if (buf.byteLength < 32 || buf.byteLength > 8_000_000) return json({ error: "bad_image" }, 400);
  await env.watch_bucket.put(`poster/${id}`, buf, { httpMetadata: { contentType: type } });
  return json({ ok: true });
}

async function subtitle(env: Env, id: string, lang: string): Promise<Response> {
  const row = await env.watch
    .prepare("SELECT r2_key FROM subtitle WHERE movie_id = ? AND lang = ?")
    .bind(id, lang)
    .first<{ r2_key: string }>();
  if (!row) return json({ error: "no_subtitle" }, 404);
  const obj = await env.watch_bucket.get(row.r2_key);
  if (!obj) return json({ error: "no_subtitle" }, 404);
  return new Response(obj.body, {
    headers: { "content-type": "text/vtt; charset=utf-8", "cache-control": "private, max-age=86400" },
  });
}

async function putSubtitle(request: Request, env: Env, id: string, lang: string): Promise<Response> {
  const movie = await env.watch.prepare("SELECT id FROM movie WHERE id = ?").bind(id).first();
  if (!movie) return json({ error: "not_found" }, 404);
  const raw = await request.text();
  if (raw.length < 8 || raw.length > 2_000_000) return json({ error: "bad_subtitle" }, 400);
  const vtt = raw.trimStart().startsWith("WEBVTT") ? raw : srtToVtt(raw);
  const key = `sub/${id}/${lang}.vtt`;
  await env.watch_bucket.put(key, vtt, { httpMetadata: { contentType: "text/vtt" } });
  const label = new URL(request.url).searchParams.get("label") || lang;
  await env.watch
    .prepare(
      `INSERT INTO subtitle (movie_id, lang, label, r2_key, hearing_impaired, source, release_name)
       VALUES (?, ?, ?, ?, 0, 'upload', NULL)
       ON CONFLICT(movie_id, lang) DO UPDATE SET label = excluded.label, r2_key = excluded.r2_key, source = 'upload'`,
    )
    .bind(id, lang, label.slice(0, 40), key)
    .run();
  return json(await loadItem(env, id));
}

async function loadItem(env: Env, id: string) {
  const row = await env.watch.prepare("SELECT * FROM movie WHERE id = ?").bind(id).first<MovieRow>();
  if (!row) return null;
  const subs = await env.watch
    .prepare("SELECT lang, label, source, release_name, hearing_impaired FROM subtitle WHERE movie_id = ?")
    .bind(id)
    .all<SubRow>();
  return toItem(row, subs.results);
}

function toItem(row: MovieRow, subs: SubRow[]) {
  let genres: string[] = [];
  try {
    const parsed = JSON.parse(row.genres_json);
    if (Array.isArray(parsed)) genres = parsed.map((g) => String(g));
  } catch {
    genres = [];
  }
  return {
    id: row.id,
    filename: row.filename,
    byteSize: row.byte_size,
    contentType: row.content_type,
    ext: row.ext,
    title: row.title,
    originalTitle: row.original_title,
    year: row.year,
    overview: row.overview,
    runtimeMin: row.runtime_min,
    genres,
    imdbId: row.imdb_id,
    osHash: row.os_hash,
    streamId: row.stream_uid,
    hlsUrl: row.hls_url,
    thumbnailUrl: row.thumbnail_url,
    downloadUrl: row.download_url,
    readyToStream: Boolean(row.ready_to_stream),
    posterUrl: `https://watch.cornerstonecoatings.com/v1/items/${row.id}/poster`,
    backdropUrl: `https://watch.cornerstonecoatings.com/v1/items/${row.id}/backdrop`,
    trailerSite: row.trailer_site,
    trailerKey: row.trailer_key,
    trailerUrl: row.trailer_url,
    trailerFileUrl: row.trailer_r2_key ? `https://watch.cornerstonecoatings.com/v1/items/${row.id}/trailer` : null,
    trailerStatus: row.trailer_status ?? "missing",
    status: row.status,
    matchSource: row.match_source,
    matchP: row.match_p,
    matchNote: row.match_note,
    subtitles: subs.map((s) => ({
      lang: s.lang,
      label: s.label,
      source: s.source,
      releaseName: s.release_name,
      hearingImpaired: Boolean(s.hearing_impaired),
    })),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}
