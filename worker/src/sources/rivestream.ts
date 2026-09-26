/** RiveStream source: TMDB search → TMDB ID → RiveStream URL → Headless browser → HLS. */

import type { Env } from "../env";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";
import { parseReleaseName } from "../lib";

const BASE = "https://www.rivestream.app";
const TMDB_BASE = "https://api.themoviedb.org/3";
// TMDB API key needed - use env or public
const TMDB_KEY = "c6f3c8f1e4b0a7d5e8f9c0d1a2b3c4d5";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";

export const sourceRiveStream: Source = {
  key: "rivestream",
  name: "RiveStream (TMDB + Headless)",

  async search(query: string): Promise<SearchResult[]> {
    const url = `${TMDB_BASE}/search/movie?api_key=${TMDB_KEY}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`;
    const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return [];
    const data = await res.json() as { results: any[] };
    
    return data.results.slice(0, 20).map(r => ({
      id: `rivestream:${r.id}`,
      title: r.title || "",
      year: r.release_date ? Number(r.release_date.slice(0, 4)) : null,
      imdbId: null, // Would need extra call
      poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
      type: "movie" as const,
    }));
  },

  async searchByImdb(imdbId: string): Promise<SearchResult | null> {
    const clean = imdbId.startsWith("tt") ? imdbId.slice(2) : imdbId;
    const url = `${TMDB_BASE}/find/${imdbId}?api_key=${TMDB_KEY}&external_source=imdb_id`;
    const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const data = await res.json() as { movie_results?: any[] };
    const movie = data.movie_results?.[0];
    if (!movie) return null;
    return {
      id: `rivestream:${movie.id}`,
      title: movie.title || "",
      year: movie.release_date ? Number(movie.release_date.slice(0, 4)) : null,
      imdbId,
      poster: movie.poster_path ? `${TMDB_IMAGE}${movie.poster_path}` : null,
      type: "movie" as const,
    };
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    // id format: "rivestream:TMDB_ID"
    const tmdbIdStr = id.replace("rivestream:", "");
    const tmdbId = Number(tmdbIdStr);
    if (!tmdbId) return null;

    // Get full metadata from TMDB
    const detailUrl = `${TMDB_BASE}/movie/${tmdbId}?api_key=${TMDB_KEY}&language=en-US&append_to_response=external_ids`;
    const res = await fetch(detailUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;

    const imdbId = detail.external_ids?.imdb_id || null;

    // RiveStream URL uses TMDB ID directly
    const pageUrl = `${BASE}/watch?type=movie&id=${tmdbId}`;

    // Use headless browser to extract HLS
    const browserResult = await extractHlsFromRiveStream(env, pageUrl);
    if (!browserResult) return null;

    return {
      id,
      title: browserResult.title || detail.title,
      year: browserResult.year ?? (detail.release_date ? Number(detail.release_date.slice(0, 4)) : null),
      imdbId,
      poster: browserResult.poster ?? (detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null),
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

/** Extract HLS from RiveStream page using Cloudflare Browser Rendering. */
async function extractHlsFromRiveStream(env: Env, pageUrl: string): Promise<{
  hlsUrl: string;
  qualities: Quality[];
  subtitles: SubtitleTrack[];
  title: string;
  year: number | null;
  poster: string | null;
} | null> {
  const browser = env.BROWSER;
  if (!browser) {
    console.log("Browser Rendering not available in env.BROWSER");
    return null;
  }

  try {
    const page = await browser.newPage();
    
    await page.setRequestInterception(true);
    page.on('request', (req: any) => {
      const resourceType = req.resourceType();
      if (['image', 'stylesheet', 'font'].includes(resourceType)) {
        req.abort();
      } else {
        req.continue();
      }
    });

    await page.goto(pageUrl, { waitUntil: 'networkidle2', timeout: 30000 });

    // Wait for source selector to appear (indicates streams loaded)
    await page.waitForSelector('#nonEmbedSourcesIndex, .serverSelect, [aria-label="Select Direct Server"]', { timeout: 15000 }).catch(() => {});

    const result = await page.evaluate(() => {
      // Try __NEXT_DATA__ first
      const nextData = document.getElementById('__NEXT_DATA__');
      if (nextData) {
        try {
          const data = JSON.parse(nextData.textContent || '{}');
          const pageProps = data.props?.pageProps;
          
          // Look for stream sources
          const sources = pageProps?.sources || pageProps?.servers || pageProps?.streams;
          if (sources) {
            return { sources, pageProps };
          }
        } catch { /* ignore */ }
      }

      // Fallback: scan for m3u8 in page
      const m3u8Matches = document.body.innerHTML.match(/https?:\/\/[^"'\s]+\.m3u8[^"'\s]*/g);
      
      // Check for player config
      const scripts = document.querySelectorAll('script');
      let playerConfig = null;
      for (const script of scripts) {
        const text = script.textContent || '';
        if (text.includes('playerConfig') || text.includes('sources') || text.includes('servers')) {
          const match = text.match(/(?:playerConfig|sources|servers)\s*[=:]\s*(\[[\s\S]*?\])/);
          if (match) {
            try { playerConfig = JSON.parse(match[1].replace(/'/g, '"')); } catch {}
          }
        }
      }

      return { m3u8: m3u8Matches, playerConfig };
    });

    await page.close();

    let hlsUrl: string | null = null;
    let title = "";
    let poster: string | null = null;

    if (result?.m3u8?.length) {
      hlsUrl = result.m3u8[0];
    } else if (result?.playerConfig?.sources) {
      const hlsSource = result.playerConfig.sources.find((s: any) => s.file?.includes('.m3u8') || s.type === 'application/x-mpegURL');
      hlsUrl = hlsSource?.file;
    } else if (result?.sources) {
      const hlsSource = result.sources.find((s: any) => s.file?.includes('.m3u8') || s.url?.includes('.m3u8') || s.type === 'application/x-mpegURL');
      hlsUrl = hlsSource?.file || hlsSource?.url;
    }

    if (!hlsUrl) return null;

    const masterRes = await fetch(hlsUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!masterRes.ok) return null;
    const masterText = await masterRes.text();
    const { qualities, subtitles } = parseMasterPlaylist(masterText, hlsUrl);

    return {
      hlsUrl,
      qualities,
      subtitles,
      title: "",
      year: null,
      poster: null,
    };
  } catch (err) {
    console.log("RiveStream browser rendering error:", err);
    return null;
  }
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