/** Headless browser source: Cloudflare Browser Rendering to extract HLS from any page. */

import type { Env } from "../env";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";
import { parseReleaseName } from "../lib";

interface BrowserResult {
  hlsUrl: string;
  qualities: Quality[];
  subtitles: SubtitleTrack[];
  title: string;
  year: number | null;
  poster: string | null;
}

export const sourceHeadless: Source = {
  key: "headless",
  name: "Headless Browser (Cloudflare)",

  async search(query: string): Promise<SearchResult[]> {
    // Use Cinemeta for search, then resolve via headless
    const { cinemetaSearch } = await import("../cinemeta");
    const hits = await cinemetaSearch(query);
    return hits.slice(0, 20).map(h => ({
      id: `headless:${h.id}`,
      title: h.name,
      year: h.year ? Number(h.year) : null,
      imdbId: h.id,
      poster: h.poster,
      type: "movie" as const,
    }));
  },

  async searchByImdb(imdbId: string): Promise<SearchResult | null> {
    const { cinemetaSearch } = await import("../cinemeta");
    const hits = await cinemetaSearch(imdbId);
    const hit = hits.find(h => h.id === imdbId) || hits[0];
    if (!hit) return null;
    return {
      id: `headless:${hit.id}`,
      title: hit.name,
      year: hit.year ? Number(hit.year) : null,
      imdbId: hit.id,
      poster: hit.poster,
      type: "movie" as const,
    };
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const imdbId = id.replace("headless:", "");
    if (!/^tt\d{7,8}$/.test(imdbId)) return null;

    // Get metadata from Cinemeta
    const { cinemetaMeta } = await import("../cinemeta");
    const meta = await cinemetaMeta(imdbId);
    if (!meta) return null;

    // Find streaming page URL - try multiple sources
    const pageUrl = await findStreamingPage(env, imdbId, meta.name, meta.year);
    if (!pageUrl) return null;

    // Use Cloudflare Browser Rendering to extract HLS
    const browserResult = await extractHlsFromPage(env, pageUrl);
    if (!browserResult) return null;

    return {
      id,
      title: browserResult.title || meta.name,
      year: browserResult.year ?? (meta.year ? Number(meta.year) : null),
      imdbId: meta.imdbId,
      poster: browserResult.poster ?? meta.poster,
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
    // Download HLS directly from the resolved URL
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

    // Create movie row
    const parsed = parseReleaseName(`${stream.title} ${stream.year ?? ""}.mp4`);
    const id = crypto.randomUUID();
    const now = new Date().toISOString();

    await env.watch.prepare(
      `INSERT INTO movie (id, filename, byte_size, content_type, ext, title, original_title, year, status, created_at, updated_at)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?, 'uploading', ?, ?)`
    ).bind(id, `${parsed.title}.mp4`, "video/mp4", "mp4", parsed.title, stream.title, stream.year, now, now).run();

    // Download segments to R2 multipart
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

/** Find a streaming page URL for a movie by searching known sites. */
async function findStreamingPage(env: Env, imdbId: string, title: string, year: number | null): Promise<string | null> {
  const sites = [
    `https://67movies.st/watch/movie/${imdbId}`,
    `https://cineby.gdn/movie/${imdbId}`,
    `https://www.rivestream.app/watch?type=movie&id=${imdbId}`,
    `https://hydrahd.ws/movie/${imdbId}`,
    `https://movy.sx/movie/${imdbId}`,
    `https://flixer.gd/movie/${imdbId}`,
  ];

  for (const url of sites) {
    try {
      const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(8000) });
      if (res.ok) {
        const html = await res.text();
        if (html.includes(".m3u8") || html.includes("playerConfig") || html.includes("data-config")) {
          return url;
        }
      }
    } catch { /* try next */ }
  }
  return null;
}

/** Use Cloudflare Browser Rendering to extract HLS from a page. */
async function extractHlsFromPage(env: Env, pageUrl: string): Promise<BrowserResult | null> {
  // Check if Browser Rendering is available
  const browser = env.BROWSER; // Cloudflare Browser Rendering binding
  if (!browser) {
    console.log("Browser Rendering not available");
    return null;
  }

  try {
    // Use Puppeteer via Cloudflare Browser Rendering
    const page = await browser.newPage();
    
    // Block unnecessary resources to speed up
    await page.setRequestInterception(true);
    page.on('request', (req: any) => {
      const resourceType = req.resourceType();
      if (['image', 'stylesheet', 'font', 'media'].includes(resourceType)) {
        req.abort();
      } else {
        req.continue();
      }
    });

    await page.goto(pageUrl, { waitUntil: 'networkidle2', timeout: 30000 });

    // Extract HLS from page
    const result = await page.evaluate(() => {
      // Try multiple extraction methods
      const m3u8Matches = document.body.innerHTML.match(/https?:\/\/[^"'\s]+\.m3u8[^"'\s]*/g);
      
      // Check for player config
      let playerConfig = null;
      const scripts = document.querySelectorAll('script');
      for (const script of scripts) {
        const text = script.textContent || '';
        if (text.includes('playerConfig') || text.includes('data-config')) {
          const match = text.match(/playerConfig\s*=\s*({[\s\S]*?});/);
          if (match) {
            try { playerConfig = JSON.parse(match[1].replace(/'/g, '"')); } catch {}
          }
        }
      }

      // Get title
      const title = document.querySelector('h1')?.textContent?.trim() || 
                    document.querySelector('meta[property="og:title"]')?.getAttribute('content') ||
                    document.title;

      // Get poster
      const poster = document.querySelector('meta[property="og:image"]')?.getAttribute('content') ||
                     document.querySelector('img.poster')?.getAttribute('src');

      // Extract qualities from master playlist if found
      let qualities: any[] = [];
      let subtitles: any[] = [];

      if (playerConfig?.sources) {
        for (const source of playerConfig.sources) {
          if (source.file && source.file.includes('.m3u8')) {
            // We'd need to fetch the master playlist to parse qualities
            qualities.push({ uri: source.file, height: 1080 });
          }
        }
      }

      return {
        hlsUrls: m3u8Matches || [],
        playerConfig,
        title,
        poster,
        qualities,
        subtitles,
      };
    });

    await page.close();

    if (!result.hlsUrls?.length && !result.playerConfig?.sources?.length) {
      return null;
    }

    // Get the first HLS URL
    const hlsUrl = result.hlsUrls[0] || result.playerConfig?.sources?.find((s: any) => s.file?.includes('.m3u8'))?.file;
    if (!hlsUrl) return null;

    // Fetch master playlist to parse qualities
    const masterRes = await fetch(hlsUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!masterRes.ok) return null;
    const masterText = await masterRes.text();
    const { qualities, subtitles } = parseMasterPlaylist(masterText, hlsUrl);

    return {
      hlsUrl,
      qualities,
      subtitles,
      title: result.title,
      year: null,
      poster: result.poster,
    };
  } catch (err) {
    console.log("Browser rendering error:", err);
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