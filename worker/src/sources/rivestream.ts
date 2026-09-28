/** RiveStream source: TMDB search → TMDB ID → RiveStream URL → Headless browser → HLS. */

import puppeteer from "@cloudflare/puppeteer";
import type { Env } from "../env";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";
import { parseReleaseName } from "../lib";
import { StealthBrowser, humanWait, tryClickPlay } from "./rivestream-browser";
import { getSession, saveSession, extractSessionFromPage, formatCookiesForPlayback, applySessionToPage, RiveStreamSession } from "./rivestream-session";
import type { KVNamespace } from "@cloudflare/workers-types";

const BASE = "https://www.rivestream.app";
const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";

function getTmdbHeaders(env: Env): HeadersInit {
  const bearer = env.WATCH_TMDB_API_READ_ACCESS_TOKEN;
  const apiKey = env.WATCH_TMDB_API_KEY;
  if (bearer) {
    return { Authorization: `Bearer ${bearer}`, Accept: "application/json" };
  }
  if (apiKey) {
    return { Accept: "application/json" };
  }
  return { Accept: "application/json" };
}

function getTmdbApiKeyParam(env: Env): string | null {
  const apiKey = env.WATCH_TMDB_API_KEY;
  return apiKey ? `api_key=${apiKey}` : null;
}

function buildRiveStreamUrl(tmdbId: number, mediaType: "movie" | "tv", season?: number, episode?: number): string {
  if (mediaType === "tv" && season !== undefined && episode !== undefined) {
    return `${BASE}/watch?type=tv&id=${tmdbId}&season=${season}&episode=${episode}`;
  }
  return `${BASE}/watch?type=movie&id=${tmdbId}`;
}

export const sourceRiveStream: Source = {
  key: "rivestream",
  name: "RiveStream (TMDB + Headless)",

  async search(query: string, env: Env): Promise<SearchResult[]> {
    const apiKeyParam = getTmdbApiKeyParam(env);
    if (!apiKeyParam) return [];
    
    const [movieRes, tvRes] = await Promise.all([
      fetch(`${TMDB_BASE}/search/movie?${apiKeyParam}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`, 
        { headers: { ...getTmdbHeaders(env), "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) }),
      fetch(`${TMDB_BASE}/search/tv?${apiKeyParam}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`, 
        { headers: { ...getTmdbHeaders(env), "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) })
    ]);

    const results: SearchResult[] = [];
    
    if (movieRes.ok) {
      const movieData = await movieRes.json() as { results: any[] };
      results.push(...movieData.results.slice(0, 10).map(r => ({
        id: `rivestream:movie:${r.id}`,
        title: r.title || "",
        year: r.release_date ? Number(r.release_date.slice(0, 4)) : null,
        imdbId: null,
        poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
        type: "movie" as const,
      })));
    }

    if (tvRes.ok) {
      const tvData = await tvRes.json() as { results: any[] };
      results.push(...tvData.results.slice(0, 10).map(r => ({
        id: `rivestream:tv:${r.id}`,
        title: r.name || "",
        year: r.first_air_date ? Number(r.first_air_date.slice(0, 4)) : null,
        imdbId: null,
        poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
        type: "series" as const,
      })));
    }

    return results.slice(0, 20);
  },

  async searchByImdb(imdbId: string, env: Env): Promise<SearchResult | null> {
    const apiKeyParam = getTmdbApiKeyParam(env);
    if (!apiKeyParam) return null;
    const url = `${TMDB_BASE}/find/${imdbId}?${apiKeyParam}&external_source=imdb_id`;
    const res = await fetch(url, { headers: { ...getTmdbHeaders(env), "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const data = await res.json() as { movie_results?: any[]; tv_results?: any[] };
    const movie = data.movie_results?.[0];
    const tv = data.tv_results?.[0];
    const item = movie || tv;
    if (!item) return null;
    return {
      id: `rivestream:${movie ? "movie" : "tv"}:${item.id}`,
      title: item.title || item.name || "",
      year: (item.release_date || item.first_air_date) ? Number((item.release_date || item.first_air_date).slice(0, 4)) : null,
      imdbId,
      poster: item.poster_path ? `${TMDB_IMAGE}${item.poster_path}` : null,
      type: movie ? "movie" : "series",
    };
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const parts = id.replace("rivestream:", "").split(":");
    const mediaType = parts[0] as "movie" | "tv";
    const tmdbId = Number(parts[1]);
    if (!tmdbId || !["movie", "tv"].includes(mediaType)) return null;

    const apiKeyParam = getTmdbApiKeyParam(env);
    if (!apiKeyParam) return null;
    const detailUrl = `${TMDB_BASE}/${mediaType}/${tmdbId}?${apiKeyParam}&language=en-US&append_to_response=external_ids`;
    const res = await fetch(detailUrl, { headers: { ...getTmdbHeaders(env), "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;

    const imdbId = detail.external_ids?.imdb_id || null;

    const pageUrl = buildRiveStreamUrl(tmdbId, mediaType, mediaType === "tv" ? 1 : undefined, mediaType === "tv" ? 1 : undefined);

    const browserResult = await extractHlsFromRiveStream(env, pageUrl, tmdbId, mediaType);
    if (!browserResult) return null;

    return {
      id,
      title: browserResult.title || detail.name || detail.title,
      year: browserResult.year ?? (detail.release_date || detail.first_air_date ? Number((detail.release_date || detail.first_air_date).slice(0, 4)) : null),
      imdbId,
      poster: browserResult.poster ?? (detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null),
      hlsUrl: browserResult.hlsUrl,
      qualities: browserResult.qualities,
      subtitles: browserResult.subtitles,
      // Pass cookies for Roku playback
      cookieHeader: browserResult.cookieHeader,
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
    const selectedQuality = qualities.find(q => q.height === quality.height) || bestQuality(qualities);
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
  qualities.sort((a, b) => b.height - a.height || b.bandwidth - a.bandwidth);
  return { qualities, subtitles };
}

function bestQuality(qualities: Quality[]): Quality | undefined {
  return qualities.reduce<Quality | undefined>((best, q) => {
    if (!best || q.height > best.height || (q.height === best.height && q.bandwidth > best.bandwidth)) return q;
    return best;
  }, undefined);
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

async function bestMasterUrl(urls: string[]): Promise<string | null> {
  let best: { url: string; height: number; bandwidth: number } | null = null;
  for (const url of urls) {
    try {
      const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(8000) });
      if (!res.ok) continue;
      const text = await res.text();
      const { qualities } = parseMasterPlaylist(text, url);
      const top = bestQuality(qualities);
      const height = top?.height ?? 0;
      const bandwidth = top?.bandwidth ?? 0;
      if (!best || height > best.height || (height === best.height && bandwidth > best.bandwidth)) {
        best = { url, height, bandwidth };
      }
    } catch { /* try the next playlist */ }
  }
  return best?.url ?? urls[0] ?? null;
}

function parseMediaPlaylist(text: string, baseUrl: string): string[] {
  return text.split("\n")
    .map(l => l.trim())
    .filter(l => l && !l.startsWith("#"))
    .map(l => l.startsWith("http") ? l : new URL(l, baseUrl).href);
}

export async function extractHlsFromRiveStream(
  env: Env,
  pageUrl: string,
  tmdbId: number,
  mediaType: "movie" | "tv"
): Promise<{
  hlsUrl: string;
  qualities: Quality[];
  subtitles: SubtitleTrack[];
  title: string;
  year: number | null;
  poster: string | null;
  cookieHeader: string;
} | null> {
  if (!env.BROWSER) {
    console.log(JSON.stringify({ event: "rivestream_error", reason: "no_browser_binding" }));
    return null;
  }

  const proxy = env.RIVESTREAM_PROXY || undefined;
  const stealthBrowser = new StealthBrowser({ proxy });
  let session: RiveStreamSession | null = null;

  try {
    // Try to load existing session
    if (env.RIVESTREAM_SESSION) {
      session = await getSession(env.RIVESTREAM_SESSION as KVNamespace, tmdbId, mediaType);
    }

    const browser = await stealthBrowser.launch({ BROWSER: env.BROWSER });
    const page = await stealthBrowser.newPage();

    // Apply session if exists
    if (session) {
      await applySessionToPage(page, session);
    }

    const playlists = new Set<string>();
    const interesting: string[] = [];

    // Listen to all frames for responses (catches iframes)
    const handleResponse = (res: any) => {
      const url = res.url().split("#")[0]!;
      const type = (res.headers()["content-type"] || "").toLowerCase();
      if (url.includes(".m3u8") || type.includes("mpegurl")) {
        playlists.add(url);
      }
      const skip = /fonts\.|gstatic|googletagmanager|cloudflareinsights|tmdb\.org|wtfismyip|_next\/|speculation|\.css(\?|$)/.test(url);
      if (!skip && interesting.length < 20) interesting.push(url.slice(0, 160));
    };

    page.on("response", handleResponse);
    page.on("framecreated", (frame: any) => {
      frame.on("response", handleResponse);
    });

    // Listen for WebSocket messages (some sites signal via WS)
    page.on("websocket", (ws: any) => {
      ws.on("framereceived", ({ payload }: any) => {
        if (payload.includes(".m3u8") || payload.includes("mpegurl")) {
          try {
            const urls = payload.match(/https?:\/\/[^\s"']+\.m3u8[^\s"']*/g) || [];
            urls.forEach((u: string) => playlists.add(u));
          } catch {}
        }
      });
    });

    // Navigate with human-like timing
    await page.goto(pageUrl, { waitUntil: "domcontentloaded", timeout: 20000 });
    await humanWait(1000, 2500); // Think time

    // Check for challenge page
    const isChallenge = await page.evaluate(() => {
      const text = document.body.innerText.toLowerCase();
      return text.includes("checking your browser") ||
             text.includes("challenge") ||
             text.includes("turnstile") ||
             text.includes("verify you are human") ||
             document.querySelector("[data-ray]") !== null;
    });

    if (isChallenge) {
      console.log(JSON.stringify({ event: "rivestream_challenge", tmdbId, mediaType, url: pageUrl }));
      // Wait longer for challenge to potentially auto-solve
      await humanWait(5000, 8000);
    }

    // Scroll a bit (human behavior)
    await page.evaluate(() => window.scrollBy(0, 300));
    await humanWait(500, 1000);

    // Try to click play
    await tryClickPlay(page);

    // Wait for playlist with deadline
    const deadline = Date.now() + 15000; // 15s max wait
    while (playlists.size === 0 && Date.now() < deadline) {
      await humanWait(400, 800);
    }

    const hlsUrl = await bestMasterUrl([...playlists]);
    if (!hlsUrl) {
      const title = await page.title().catch(() => "");
      console.log(JSON.stringify({
        event: "rivestream_no_playlist",
        tmdbId,
        mediaType,
        title,
        interesting: interesting.slice(0, 10)
      }));
      throw new Error("no_playlist");
    }

    // Extract updated session before closing
    let cookieHeader = "";
    if (env.RIVESTREAM_SESSION) {
      const newSession = await extractSessionFromPage(page, tmdbId, mediaType);
      await saveSession(env.RIVESTREAM_SESSION as KVNamespace, newSession);
      cookieHeader = formatCookiesForPlayback(newSession);
    }

    await page.close();

    const masterRes = await fetch(hlsUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!masterRes.ok) return null;
    const masterText = await masterRes.text();
    const { qualities, subtitles } = parseMasterPlaylist(masterText, hlsUrl);

    console.log(JSON.stringify({ event: "rivestream_success", tmdbId, mediaType, hlsUrl, qualities: qualities.length, subtitles: subtitles.length }));

    return {
      hlsUrl,
      qualities,
      subtitles,
      title: "",
      year: null,
      poster: null,
      cookieHeader,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.log(JSON.stringify({ event: "rivestream_error", tmdbId, mediaType, error: message.slice(0, 300) }));
    throw new Error(message.slice(0, 300));
  } finally {
    await stealthBrowser.close();
  }
}