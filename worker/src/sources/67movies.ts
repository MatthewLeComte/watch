/** 67movies.st HLS source implementation. */

import type { Env } from "../env";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";

const BASE = "https://67movies.st";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";

export const source67movies: Source = {
  key: "67movies",
  name: "67movies",

  async search(query: string): Promise<SearchResult[]> {
    const url = `${BASE}/search?keyword=${encodeURIComponent(query)}`;
    const res = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return [];
    const html = await res.text();
    return parseSearchHtml(html);
  },

  async searchByImdb(imdbId: string): Promise<SearchResult | null> {
    const clean = imdbId.startsWith("tt") ? imdbId.slice(2) : imdbId;
    const url = `${BASE}/search?keyword=${clean}`;
    const res = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const html = await res.text();
    const results = parseSearchHtml(html);
    return results.find(r => r.imdbId?.toLowerCase() === imdbId.toLowerCase()) ?? results[0] ?? null;
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const url = `${BASE}/watch/movie/${id}`;
    const res = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const html = await res.text();

    const playerConfig = extractPlayerConfig(html);
    if (!playerConfig?.sources?.length) return null;

    const hlsSource = playerConfig.sources.find((s: any) =>
      s.type === "application/x-mpegURL" || s.file?.includes(".m3u8")
    );
    if (!hlsSource?.file) return null;

    const masterUrl = hlsSource.file.startsWith("http")
      ? hlsSource.file
      : new URL(hlsSource.file, BASE).href;

    const masterRes = await fetch(masterUrl, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(10000) });
    if (!masterRes.ok) return null;
    const masterText = await masterRes.text();
    const { qualities, subtitles } = parseMasterPlaylist(masterText, masterUrl);

    return {
      id,
      title: playerConfig.title || "",
      year: playerConfig.year ?? null,
      imdbId: playerConfig.imdbId ?? null,
      poster: playerConfig.poster ?? null,
      hlsUrl: masterUrl,
      qualities,
      subtitles,
    };
  },

  async downloadAndIngest(
    env: Env,
    stream: StreamInfo,
    quality: Quality,
    subtitle?: SubtitleTrack,
  ): Promise<string> {
    const parsed = parseReleaseName(`${stream.title} ${stream.year ?? ""}.mp4`);
    const id = crypto.randomUUID();
    const now = new Date().toISOString();

    await env.watch.prepare(
      `INSERT INTO movie (id, filename, byte_size, content_type, ext, title, original_title, year, status, created_at, updated_at)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?, 'uploading', ?, ?)`
    ).bind(
      id,
      `${parsed.title}.mp4`,
      "video/mp4",
      "mp4",
      parsed.title,
      stream.title,
      stream.year,
      now,
      now,
    ).run();

    const { size, segments } = await downloadHlsToR2(env, id, stream.hlsUrl, quality, subtitle);
    if (size === 0) throw new Error("no_segments_downloaded");

    await env.watch.prepare("UPDATE movie SET byte_size = ? WHERE id = ?").bind(size, id).run();
    await completeHlsUpload(env, id, size, segments);

    const { ingest } = await import("../ingest");
    await ingest(env, id);

    return id;
  },
};

/** Download HLS master → pick quality → fetch segments → store in R2 as single MP4. */
async function downloadHlsToR2(
  env: Env,
  movieId: string,
  masterUrl: string,
  quality: Quality,
  subtitle?: SubtitleTrack,
): Promise<{ size: number; segments: number }> {
  const masterRes = await fetch(masterUrl, { headers: { "User-Agent": UA } });
  const masterText = await masterRes.text();
  const baseUrl = masterUrl.substring(0, masterUrl.lastIndexOf("/") + 1);

  const segmentUrls = parseMediaPlaylist(masterText, baseUrl);
  if (segmentUrls.length === 0) return { size: 0, segments: 0 };

  const upload = await env.watch_bucket.createMultipartUpload(`video/${movieId}`, {
    httpMetadata: { contentType: "video/mp4" },
  });

  let totalSize = 0;
  let partNumber = 1;
  let partBuffer = new Uint8Array(0);
  const PART = 8 * 1024 * 1024;
  const parts: { partNumber: number; etag: string }[] = [];

  for (const segUrl of segmentUrls) {
    const segRes = await fetch(segUrl, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(15000) });
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
    .bind(movieId, upload.uploadId, JSON.stringify(parts.map(p => ({ ...p, size: PART }))))
    .run();

  return { size: totalSize, segments: segmentUrls.length };
}

async function completeHlsUpload(env: Env, id: string, size: number, segments: number): Promise<void> {
  const row = await env.watch
    .prepare("SELECT upload_id, parts_json FROM upload WHERE movie_id = ?")
    .bind(id)
    .first<{ upload_id: string; parts_json: string }>();
  if (!row) throw new Error("no_upload");

  const parts = JSON.parse(row.parts_json) as { partNumber: number; etag: string }[];
  await env.watch_bucket.resumeMultipartUpload(`video/${id}`, row.upload_id).complete(
    parts.map(p => ({ partNumber: p.partNumber, etag: p.etag }))
  );
  await env.watch.prepare("DELETE FROM upload WHERE movie_id = ?").bind(id).run();
}

/** Parse search results HTML. */
function parseSearchHtml(html: string): SearchResult[] {
  const results: SearchResult[] = [];
  const linkRegex = /<a[^>]+href="\/watch\/movie\/(\d+)"[^>]*>([^<]+)<\/a>/gi;
  let match;
  while ((match = linkRegex.exec(html)) !== null) {
    const id = match[1];
    const text = match[2].trim();
    const yearMatch = text.match(/\((\d{4})\)/);
    const year = yearMatch ? Number(yearMatch[1]) : null;
    const title = yearMatch ? text.replace(/\s*\(\d{4}\)/, "").trim() : text;
    results.push({ id, title, year, imdbId: null, poster: null, type: "movie" });
  }
  return results.slice(0, 20);
}

/** Extract player config from page HTML. */
function extractPlayerConfig(html: string): any {
  const patterns = [
    /playerConfig\s*=\s*({[\s\S]*?});/,
    /data-config\s*=\s*['"]({[\s\S]*?})['"]/,
    /setup\(({[\s\S]*?})\)/,
  ];
  for (const pat of patterns) {
    const m = html.match(pat);
    if (m) {
      try { return JSON.parse(m[1].replace(/'/g, '"')); } catch { /* try next */ }
    }
  }
  const m3u8 = html.match(/(https?:\/\/[^"'\s]+\.m3u8[^"'\s]*)/);
  if (m3u8) return { sources: [{ file: m3u8[1], type: "application/x-mpegURL" }] };
  return null;
}

/** Parse master playlist → qualities + subtitles. */
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

/** Parse media playlist → segment URLs. */
function parseMediaPlaylist(text: string, baseUrl: string): string[] {
  return text.split("\n")
    .map(l => l.trim())
    .filter(l => l && !l.startsWith("#"))
    .map(l => l.startsWith("http") ? l : new URL(l, baseUrl).href);
}