/** Meta-source: RiveStream only (TMDB ID → HLS via headless). */

import type { Env } from "../env";
import { parseReleaseName } from "../lib";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";

const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";

export const sourceMeta: Source = {
  key: "meta",
  name: "Meta (RiveStream)",

  async search(query: string, env: Env): Promise<SearchResult[]> {
    const apiKey = env.WATCH_TMDB_API_KEY;
    if (!apiKey) return [];
    const url = `${TMDB_BASE}/search/movie?api_key=${apiKey}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`;
    const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return [];
    const data = await res.json() as { results: any[] };
    return data.results.slice(0, 20).map(r => ({
      id: `meta:${r.id}`, // TMDB ID as universal key
      title: r.title || "",
      year: r.release_date ? Number(r.release_date.slice(0, 4)) : null,
      imdbId: null,
      poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
      type: "movie" as const,
    }));
  },

  async searchByImdb(imdbId: string, env: Env): Promise<SearchResult | null> {
    const tmdbId = await getTmdbIdFromImdb(env, imdbId);
    if (!tmdbId) return null;
    const apiKey = env.WATCH_TMDB_API_KEY;
    if (!apiKey) return null;
    const detailUrl = `${TMDB_BASE}/movie/${tmdbId}?api_key=${apiKey}&language=en-US`;
    const res = await fetch(detailUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;
    return {
      id: `meta:${tmdbId}`,
      title: detail.title || "",
      year: detail.release_date ? Number(detail.release_date.slice(0, 4)) : null,
      imdbId,
      poster: detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null,
      type: "movie" as const,
    });
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const tmdbIdStr = id.replace("meta:", "");
    const tmdbId = Number(tmdbIdStr);
    if (!tmdbId) return null;

    const apiKey = env.WATCH_TMDB_API_KEY;
    if (!apiKey) return null;
    const detailUrl = `${TMDB_BASE}/movie/${tmdbId}?api_key=${apiKey}&language=en-US&append_to_response=external_ids`;
    const res = await fetch(detailUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;

    // Single provider: RiveStream (TMDB ID → headless → HLS)
    const { extractHlsFromRiveStream } = await import("./rivestream");
    const pageUrl = `https://www.rivestream.app/watch?type=movie&id=${tmdbId}`;
    const browserResult = await extractHlsFromRiveStream(env, `https://www.rivestream.app/watch?type=movie&id=${tmdbId}`);
    if (!browserResult) return null;

    return {
      id: `meta:${tmdbId}`,
      title: detail.title,
      year: detail.release_date ? Number(detail.release_date.slice(0, 4)) : null,
      imdbId: detail.external_ids?.imdb_id,
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
    const selectedQuality = qualities.find(q => q.height === quality.height) || qualities[0];
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

async function completeHlsUpload(env: Env, id: string, size: number, segments: number): Promise<void> {
  const row = await env.watch.prepare("SELECT upload_id, parts_json FROM upload WHERE movie_id = ?").bind(id).first<{ upload_id: string; parts_json: string }>();
  if (!row) throw new Error("no_upload");
  const parts = JSON.parse(row.parts_json) as { partNumber: number; etag: string }[];
  await env.watch_bucket.resumeMultipartUpload(`video/${id}`, row.upload_id).complete(
    parts.map(p => ({ partNumber: p.partNumber, etag: p.etag }))
  );
  await env.watch.prepare("DELETE FROM upload WHERE movie_id = ?").bind(id).run();
}

function parseMasterPlaylist(text: string, masterUrl: string): { qualities: Quality[]; subtitles: SubtitleTrack[] } {
  const qualities: Quality[] = [];
  const subtitles: SubtitleTrack[] = [];
  const lines = text.split("\n");
  let current: Partial<Quality> = {};

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#EXT-X-STREAM-INF:")) {
      current = parseStreamInf(trimmed);
    } else if (trimmed.startsWith("#EXT-X-MEDIA:")) {
      const sub = parseMedia(trimmed, masterUrl);
      if (sub) subtitles.push(sub);
    } else if (trimmed && !trimmed.startsWith("#")) {
      if (current.height) {
        qualities.push({ ...current, uri: trimmed } as Quality);
        current = {};
      }
    }
  }
  return { qualities, subtitles };
}

function parseStreamInf(line: string): Partial<Quality> {
  const attrs: Record<string, string> = {};
  const regex = /([A-Z-]+)=("(?:[^"]*)"|[^,]+)/g;
  let m;
  while ((m = regex.exec(line)) !== null) {
    attrs[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  const res = attrs.RESOLUTION?.match(/(\d+)x(\d+)/);
  const height = res ? Number(res[2]) : 0;
  const bandwidth = Number(attrs.BANDWIDTH || "0");
  const codecs = attrs.CODECS || "";
  return { height, bandwidth, codecs };
}

function parseMedia(line: string, masterUrl: string): SubtitleTrack | null {
  const attrs: Record<string, string> = {};
  const regex = /([A-Z-]+)=("(?:[^"]*)"|[^,]+)/g;
  let m;
  while ((m = regex.exec(line)) !== null) {
    attrs[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  if (attrs.TYPE !== "SUBTITLES") return null;
  return {
    lang: attrs.LANGUAGE || "und",
    label: attrs.NAME || attrs.LANGUAGE || "Subtitle",
    uri: attrs.URI || "",
    forced: attrs.FORCED === "YES",
  };
}

function parseMediaPlaylist(text: string, baseUrl: string): string[] {
  return text.split("\n")
    .map(l => l.trim())
    .filter(l => l && !l.startsWith("#"))
    .map(l => l.startsWith("http") ? l : new URL(l, baseUrl).href);
}

async function getTmdbIdFromImdb(env: Env, imdbId: string): Promise<number | null> {
  const apiKey = env.WATCH_TMDB_API_KEY;
  if (!apiKey) return null;
  const url = `${TMDB_BASE}/find/${imdbId}?api_key=${apiKey}&external_source=imdb_id`;
  const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(8000) });
  if (!res.ok) return null;
  const data = await res.json() as { movie_results?: any[] };
  return data.movie_results?.[0]?.id || null;
}

async function completeHlsUpload(env: Env, id: string, size: number, segments: number): Promise<void> {
  const row = await env.watch.prepare("SELECT upload_id, parts_json FROM upload WHERE movie_id = ?").bind(id).first<{ upload_id: string; parts_json: string }>();
  if (!row) throw new Error("no_upload");
  const parts = JSON.parse(row.parts_json) as { partNumber: number; etag: string }[];
  await env.watch_bucket.resumeMultipartUpload(`video/${id}`, row.upload_id).complete(
    parts.map(p => ({ partNumber: p.partNumber, etag: p.etag }))
  );
  await env.watch.prepare("DELETE FROM upload WHERE movie_id = ?").bind(id).run();
}

const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";