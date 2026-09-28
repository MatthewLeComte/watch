/** Meta-source: RiveStream only (TMDB ID → HLS via headless). */

import type { Env } from "../env";
import { parseReleaseName } from "../lib";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";

const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";

export class TmdbUnconfigured extends Error {
  constructor() { super("tmdb_unconfigured"); }
}

let cachedBearer: string | null = null;
let cachedKey: string | null = null;

async function secretText(value: string | { get?: () => Promise<string> } | undefined): Promise<string> {
  if (!value) return "";
  if (typeof value === "string") return value;
  try { return (await value.get?.()) || ""; } catch { return ""; }
}

async function tmdbAuth(env: Env): Promise<{ bearer: string; apiKey: string }> {
  if (cachedBearer === null) cachedBearer = await secretText(env.WATCH_TMDB_API_READ_ACCESS_TOKEN);
  if (cachedKey === null) cachedKey = await secretText(env.WATCH_TMDB_API_KEY);
  return { bearer: cachedBearer, apiKey: cachedKey };
}

async function tmdbFetch(env: Env, pathAndQuery: string): Promise<Response> {
  const headers: Record<string, string> = { Accept: "application/json", "User-Agent": "Watch/1" };
  let url = `${TMDB_BASE}${pathAndQuery}`;
  const { bearer, apiKey } = await tmdbAuth(env);
  if (bearer) {
    headers.Authorization = `Bearer ${bearer}`;
  } else if (apiKey) {
    url += `${url.includes("?") ? "&" : "?"}api_key=${encodeURIComponent(apiKey)}`;
  } else {
    throw new TmdbUnconfigured();
  }
  const cacheKey = new Request(`https://tmdb-cache.watch.internal${pathAndQuery}`);
  const hit = await caches.default.match(cacheKey);
  if (hit) return hit;
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
  if (res.ok) {
    const stored = new Response(res.clone().body, { status: res.status, headers: { "content-type": "application/json", "cache-control": "public, max-age=600" } });
    await caches.default.put(cacheKey, stored);
  }
  return res;
}

type TmdbHit = {
  id: number;
  media_type?: "movie" | "tv" | "person";
  title?: string;
  name?: string;
  release_date?: string;
  first_air_date?: string;
  poster_path?: string | null;
};

/** `meta:10719` is a movie. `meta:tv:60625:1:1` is a series episode. A bare series id plays season 1 episode 1. */
function parseMetaId(id: string): { mediaType: "movie" | "tv"; tmdbId: number; season: number; episode: number } | null {
  const rest = id.replace(/^meta:/, "");
  if (rest.startsWith("tv:")) {
    const parts = rest.split(":");
    const tmdbId = Number(parts[1]);
    if (!tmdbId) return null;
    return { mediaType: "tv", tmdbId, season: Number(parts[2]) || 1, episode: Number(parts[3]) || 1 };
  }
  const tmdbId = Number(rest);
  if (!tmdbId) return null;
  return { mediaType: "movie", tmdbId, season: 1, episode: 1 };
}

function toResult(hit: TmdbHit): SearchResult {
  const mediaType = hit.media_type === "tv" ? "tv" : "movie";
  const aired = hit.release_date || hit.first_air_date;
  return {
    id: mediaType === "tv" ? `meta:tv:${hit.id}:1:1` : `meta:${hit.id}`,
    tmdbId: hit.id,
    title: hit.title || hit.name || "",
    year: aired ? Number(aired.slice(0, 4)) : null,
    imdbId: null,
    poster: hit.poster_path ? `${TMDB_IMAGE}${hit.poster_path}` : null,
    type: mediaType === "tv" ? "series" : "movie",
  };
}

export const sourceMeta: Source = {
  key: "meta",
  name: "TMDB",

  async search(query: string, env: Env): Promise<SearchResult[]> {
    const res = await tmdbFetch(env, `/search/multi?query=${encodeURIComponent(query)}&language=en-US&include_adult=false`);
    if (!res.ok) return [];
    const data = await res.json() as { results?: TmdbHit[] };
    const hits = (data.results ?? []).filter((r) => r.media_type === "movie" || r.media_type === "tv").slice(0, 10);
    return hits.map((r) => toResult(r));
  },

  async searchByImdb(imdbId: string, env: Env): Promise<SearchResult | null> {
    const res = await tmdbFetch(env, `/find/${encodeURIComponent(imdbId)}?external_source=imdb_id`);
    if (!res.ok) return null;
    const body = await res.json() as { movie_results?: TmdbHit[]; tv_results?: TmdbHit[] };
    const movie = body.movie_results?.[0];
    const tv = body.tv_results?.[0];
    const hit = movie || tv;
    if (!hit?.id) return null;
    hit.media_type = movie ? "movie" : "tv";
    const result = toResult(hit);
    result.imdbId = imdbId;
    return result;
  },

  async seasons(env: Env, tmdbId: number): Promise<{ number: number; name: string; episodeCount: number }[]> {
    const res = await tmdbFetch(env, `/tv/${tmdbId}?language=en-US`);
    if (!res.ok) return [];
    const body = await res.json() as { seasons?: { season_number: number; name?: string; episode_count?: number }[] };
    return (body.seasons ?? [])
      .filter((s) => (s.episode_count ?? 0) > 0)
      .map((s) => ({
        number: s.season_number,
        name: s.season_number === 0 ? "Specials" : (s.name || `Season ${s.season_number}`),
        episodeCount: s.episode_count ?? 0,
      }));
  },

  async episodes(env: Env, tmdbId: number, season: number): Promise<{ number: number; name: string }[]> {
    const res = await tmdbFetch(env, `/tv/${tmdbId}/season/${season}?language=en-US`);
    if (!res.ok) return [];
    const body = await res.json() as { episodes?: { episode_number: number; name?: string }[] };
    return (body.episodes ?? []).map((ep) => ({
      number: ep.episode_number,
      name: ep.name || `Episode ${ep.episode_number}`,
    }));
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const parsed = parseMetaId(id);
    if (!parsed) return null;
    const { mediaType, tmdbId, season, episode } = parsed;
    const res = await tmdbFetch(env, `/${mediaType}/${tmdbId}?language=en-US&append_to_response=external_ids`);
    if (!res.ok) return null;
    const detail = await res.json() as { title?: string; name?: string; release_date?: string; first_air_date?: string; poster_path?: string | null; external_ids?: { imdb_id?: string } };

    const { extractHlsFromRiveStream } = await import("./rivestream");
    const pageUrl = mediaType === "tv"
      ? `https://www.rivestream.app/watch?type=tv&id=${tmdbId}&season=${season}&episode=${episode}`
      : `https://www.rivestream.app/watch?type=movie&id=${tmdbId}`;
    const browserResult = await extractHlsFromRiveStream(env, pageUrl, tmdbId, mediaType);
    if (!browserResult) return null;

    const aired = detail.release_date || detail.first_air_date;
    const title = mediaType === "tv" ? `${detail.name || "Episode"} S${season}E${episode}` : (detail.title || "");
    return {
      id: mediaType === "tv" ? `meta:tv:${tmdbId}:${season}:${episode}` : `meta:${tmdbId}`,
      title,
      year: aired ? Number(aired.slice(0, 4)) : null,
      imdbId: detail.external_ids?.imdb_id ?? null,
      poster: detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null,
      hlsUrl: browserResult.hlsUrl,
      qualities: browserResult.qualities,
      subtitles: browserResult.subtitles,
    };
  },

  async downloadAndIngest(
    env: Env,
    stream: StreamInfo,
    quality: Quality,
    subtitle?: SubtitleTrack,
  ): Promise<string> {
    const hlsRes = await fetch(stream.hlsUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(30000) });
    if (!hlsRes.ok || !hlsRes.body) throw new Error("hls_fetch_failed");

    const masterText = await hlsRes.text();
    const { qualities, subtitles } = parseMasterPlaylist(masterText, stream.hlsUrl);
    const selectedQuality = qualities.find(q => q.height === quality.height)
      || qualities.reduce<Quality | undefined>((best, q) => (!best || q.height > best.height || (q.height === best.height && q.bandwidth > best.bandwidth) ? q : best), undefined);
    if (!selectedQuality) throw new Error("no_quality");

    const baseUrl = stream.hlsUrl.substring(0, stream.hlsUrl.lastIndexOf("/") + 1);
    const variantUrl = selectedQuality.uri.startsWith("http") ? selectedQuality.uri : baseUrl + selectedQuality.uri;
    const variantRes = await fetch(variantUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!variantRes.ok) throw new Error("variant_fetch_failed");
    const variantText = await variantRes.text();
    const segmentUrls = parseMediaPlaylist(variantText, variantUrl.substring(0, variantUrl.lastIndexOf("/") + 1));
    if (segmentUrls.length === 0) throw new Error("no_segments");

    const parsed = parseReleaseName(`${stream.title} ${stream.year ?? ""}.mp4`);
    const id = crypto.randomUUID();
    const now = new Date().toISOString();

    await env.watch.prepare(
      `INSERT INTO movie (id, filename, byte_size, content_type, ext, title, original_title, year, status, created_at, updated_at)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?, 'uploading', ?, ?)`
    ).bind(id, `${parsed.title}.mp4`, "video/mp4", "mp4", parsed.title, stream.title, stream.year, now, now).run();

    const upload = await env.watch_bucket.createMultipartUpload(`video/${id}`, {
      httpMetadata: { contentType: "video/mp4" },
    });

    let totalSize = 0;
    let partNumber = 1;
    let partBuffer = new Uint8Array(0);
    const PART = 8 * 1024 * 1024;
    const parts: { partNumber: number; etag: string }[] = [];

    for (const segUrl of segmentUrls) {
      const segRes = await fetch(segUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(15000) });
      if (!segRes.ok || !segRes.body) continue;
      const chunk = new Uint8Array(await segRes.arrayBuffer());
      totalSize += chunk.length;

      const newBuf = new Uint8Array(partBuffer.length + chunk.length);
      newBuf.set(partBuffer);
      newBuf.set(chunk, partBuffer.length);
      partBuffer = newBuf;

      if (partBuffer.length >= PART) {
        const upPart = await upload.uploadPart(partNumber, partBuffer);
        parts.push({ partNumber, etag: upPart.etag });
        partNumber++;
        partBuffer = new Uint8Array(0);
      }
    }

    if (partBuffer.length > 0) {
      const upPart = await upload.uploadPart(partNumber, partBuffer);
      parts.push({ partNumber, etag: upPart.etag });
    }

    await env.watch.prepare("INSERT INTO upload (movie_id, upload_id, parts_json) VALUES (?, ?, ?)")
      .bind(id, upload.uploadId, JSON.stringify(parts.map(p => ({ ...p, size: PART }))))
      .run();

    await env.watch.prepare("UPDATE movie SET byte_size = ? WHERE id = ?").bind(totalSize, id).run();
    await completeHlsUpload(env, id, totalSize, parts.length);

    const { ingest } = await import("../ingest");
    await ingest(env, id);

    return id;
  },
};