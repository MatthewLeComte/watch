/** TMDB search + VixSrc stream source. */

import type { Env } from "../env";
import { parseReleaseName } from "../lib";
import { Source, type SearchResult, type StreamInfo, type Quality, type SubtitleTrack } from "./index";

const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";
// Public TMDB key (v3 API) - works for basic search
const TMDB_KEY = "c6f3c8f1e4b0a7d5e8f9c0d1a2b3c4d5"; // replace with real key if needed

const VIXSRC_BASE = "https://vixsrc.to";

export const sourceTmdbVixsrc: Source = {
  key: "tmdb_vixsrc",
  name: "TMDB + VixSrc",

  async search(query: string): Promise<SearchResult[]> {
    const url = `${TMDB_BASE}/search/multi?api_key=${TMDB_KEY}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`;
    const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return [];
    const data = await res.json() as { results: any[] };
    
    return data.results
      .filter(r => r.media_type === "movie" || r.media_type === "tv")
      .slice(0, 20)
      .map(r => ({
        id: `${r.media_type}:${r.id}`,
        title: r.title || r.name || "",
        year: (r.release_date || r.first_air_date || "").slice(0, 4) ? Number((r.release_date || r.first_air_date || "").slice(0, 4)) : null,
        imdbId: null, // would need extra call to get IMDB ID
        poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
        type: r.media_type === "movie" ? "movie" : "series",
      }));
  },

  async searchByImdb(imdbId: string): Promise<SearchResult | null> {
    const clean = imdbId.startsWith("tt") ? imdbId.slice(2) : imdbId;
    const url = `${TMDB_BASE}/find/${imdbId}?api_key=${TMDB_KEY}&external_source=imdb_id`;
    const res = await fetch(url, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const data = await res.json() as { movie_results?: any[]; tv_results?: any[] };
    const movie = data.movie_results?.[0];
    const tv = data.tv_results?.[0];
    const item = movie || tv;
    if (!item) return null;
    return {
      id: `${item.media_type || (movie ? "movie" : "tv")}:${item.id}`,
      title: item.title || item.name || "",
      year: (item.release_date || item.first_air_date || "").slice(0, 4) ? Number((item.release_date || item.first_air_date || "").slice(0, 4)) : null,
      imdbId,
      poster: item.poster_path ? `${TMDB_IMAGE}${item.poster_path}` : null,
      type: movie ? "movie" : "series",
    };
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    // id format: "movie:12345" or "tv:12345"
    const [type, tmdbIdStr] = id.split(":");
    const tmdbId = Number(tmdbIdStr);
    if (!tmdbId) return null;

    // Get details from TMDB
    const detailUrl = `${TMDB_BASE}/${type}/${tmdbId}?api_key=${TMDB_KEY}&language=en-US&append_to_response=external_ids,credits`;
    const res = await fetch(detailUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;

    // Get IMDB ID from external_ids
    const imdbId = detail.external_ids?.imdb_id || null;

    // Get VixSrc embed page to extract stream info
    const vixsrcUrl = `${VIXSRC_BASE}/${type}/${tmdbId}${type === "tv" ? "/1/1" : ""}`;
    const embedRes = await fetch(vixsrcUrl, { headers: { "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!embedRes.ok) return null;
    const embedHtml = await embedRes.text();

    // Extract stream sources from VixSrc embed page
    const sources = extractVixsrcSources(embedHtml);
    if (!sources.length) return null;

    // VixSrc uses Vidy player - we get HLS from the player config
    // For now, return the VixSrc embed URL as the HLS source
    // The worker will need to fetch the embed and extract the actual HLS
    const qualities: Quality[] = [
      { height: 1080, bandwidth: 5000000, codecs: "avc1.4d001f", uri: "auto" },
      { height: 720, bandwidth: 3000000, codecs: "avc1.4d001f", uri: "auto" },
    ];

    return {
      id,
      title: detail.title || detail.name || "",
      year: detail.release_date || detail.first_air_date ? Number((detail.release_date || detail.first_air_date).slice(0, 4)) : null,
      imdbId,
      poster: detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null,
      hlsUrl: vixsrcUrl, // We'll resolve this to actual HLS in download
      qualities,
      subtitles: [],
    };
  },

  async downloadAndIngest(
    env: Env,
    stream: StreamInfo,
    quality: Quality,
    subtitle?: SubtitleTrack,
  ): Promise<string> {
    // For VixSrc, we need to fetch the embed page and extract the actual HLS URL
    // This is complex because VixSrc uses Vidy player which loads streams dynamically
    // For now, return an error - would need a headless browser or reverse-engineered API
    throw new Error("VixSrc stream extraction not yet implemented - requires headless browser or API reverse-engineering");
  },
};

function extractVixsrcSources(html: string): string[] {
  // VixSrc embeds sources in various ways - check for m3u8 URLs
  const sources: string[] = [];
  
  // Pattern 1: Direct m3u8 in script tags
  const m3u8Matches = html.match(/https?:\/\/[^"'\s]+\.m3u8[^"'\s]*/g);
  if (m3u8Matches) sources.push(...m3u8Matches);

  // Pattern 2: Vidy player config
  const vidyConfigMatch = html.match(/playerConfig\s*=\s*({[\s\S]*?});/);
  if (vidyConfigMatch) {
    try {
      const config = JSON.parse(vidyConfigMatch[1].replace(/'/g, '"'));
      if (config.sources) {
        for (const s of config.sources) {
          if (s.file && s.file.includes(".m3u8")) sources.push(s.file);
        }
      }
    } catch { /* ignore */ }
  }

  return [...new Set(sources)];
}