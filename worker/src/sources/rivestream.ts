/** RiveStream source: TMDB metadata in, documented embed links out.
 *
 * Documented endpoints only (worker/RIVESTREAM_EMBED_DOCS.md):
 *   /embed?type=movie&id={tmdbId}
 *   /embed?type=tv&id={tmdbId}&season={season}&episode={episode}
 *   /embed/torrent, /embed/agg, /download — same params.
 * The client loads the embed page and captures the playlist itself.
 * No backendfetch, no headless browser, no worker-side HLS fetch.
 */

import type { Env } from "../env";
import { Source, type SearchResult, type StreamInfo } from "./index";

async function secretText(value: string | { get?: () => Promise<string> } | undefined): Promise<string> {
  if (!value) return "";
  if (typeof value === "string") return value;
  try { return (await value.get?.()) || ""; } catch { return ""; }
}

const BASE = "https://www.rivestream.app";
const TMDB_BASE = "https://api.themoviedb.org/3";
const TMDB_IMAGE = "https://image.tmdb.org/t/p/w500";

export function buildEmbedUrls(
  tmdbId: number,
  mediaType: "movie" | "tv",
  season = 1,
  episode = 1,
): { embedUrl: string; torrentUrl: string; aggUrl: string; downloadUrl: string } {
  const q =
    mediaType === "tv"
      ? `type=tv&id=${tmdbId}&season=${season}&episode=${episode}`
      : `type=movie&id=${tmdbId}`;
  return {
    embedUrl: `${BASE}/embed?${q}`,
    torrentUrl: `${BASE}/embed/torrent?${q}`,
    aggUrl: `${BASE}/embed/agg?${q}`,
    downloadUrl: `${BASE}/download?${q}`,
  };
}

/** Parse `rivestream:movie:27205`, `rivestream:tv:60625`, `rivestream:tv:60625:1:2`. */
export function parseRiveId(id: string): { mediaType: "movie" | "tv"; tmdbId: number; season: number; episode: number } | null {
  const parts = id.replace(/^rivestream:/, "").split(":");
  const mediaType = parts[0] as "movie" | "tv";
  const tmdbId = Number(parts[1]);
  if (!tmdbId || (mediaType !== "movie" && mediaType !== "tv")) return null;
  return {
    mediaType,
    tmdbId,
    season: Number(parts[2]) || 1,
    episode: Number(parts[3]) || 1,
  };
}

async function tmdbHeaders(env: Env): Promise<HeadersInit> {
  const bearer = await secretText(env.WATCH_TMDB_API_READ_ACCESS_TOKEN);
  if (bearer) return { Authorization: `Bearer ${bearer}`, Accept: "application/json" };
  return { Accept: "application/json" };
}

async function tmdbKeyParam(env: Env): Promise<string | null> {
  const key = await secretText(env.WATCH_TMDB_API_KEY);
  return key ? `api_key=${key}` : null;
}

export const sourceRiveStream: Source = {
  key: "rivestream",
  name: "RiveStream",

  async search(query: string, env: Env): Promise<SearchResult[]> {
    const keyParam = await tmdbKeyParam(env);
    if (!keyParam) return [];
    const headers = await tmdbHeaders(env);
    const [movieRes, tvRes] = await Promise.all([
      fetch(`${TMDB_BASE}/search/movie?${keyParam}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`,
        { headers: { ...headers, "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) }),
      fetch(`${TMDB_BASE}/search/tv?${keyParam}&query=${encodeURIComponent(query)}&language=en-US&include_adult=false`,
        { headers: { ...headers, "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) }),
    ]);
    const results: SearchResult[] = [];
    if (movieRes.ok) {
      const data = await movieRes.json() as { results: any[] };
      results.push(...data.results.slice(0, 10).map(r => ({
        id: `rivestream:movie:${r.id}`,
        tmdbId: r.id,
        title: r.title || "",
        year: r.release_date ? Number(r.release_date.slice(0, 4)) : null,
        imdbId: null,
        poster: r.poster_path ? `${TMDB_IMAGE}${r.poster_path}` : null,
        type: "movie" as const,
      })));
    }
    if (tvRes.ok) {
      const data = await tvRes.json() as { results: any[] };
      results.push(...data.results.slice(0, 10).map(r => ({
        id: `rivestream:tv:${r.id}`,
        tmdbId: r.id,
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
    const keyParam = await tmdbKeyParam(env);
    if (!keyParam) return null;
    const headers = await tmdbHeaders(env);
    const res = await fetch(`${TMDB_BASE}/find/${imdbId}?${keyParam}&external_source=imdb_id`,
      { headers: { ...headers, "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const data = await res.json() as { movie_results?: any[]; tv_results?: any[] };
    const movie = data.movie_results?.[0];
    const tv = data.tv_results?.[0];
    const item = movie || tv;
    if (!item) return null;
    return {
      id: `rivestream:${movie ? "movie" : "tv"}:${item.id}`,
      tmdbId: item.id,
      title: item.title || item.name || "",
      year: (item.release_date || item.first_air_date) ? Number((item.release_date || item.first_air_date).slice(0, 4)) : null,
      imdbId,
      poster: item.poster_path ? `${TMDB_IMAGE}${item.poster_path}` : null,
      type: movie ? "movie" : "series",
    };
  },

  async resolve(env: Env, id: string): Promise<StreamInfo | null> {
    const parsed = parseRiveId(id);
    if (!parsed) return null;
    const { mediaType, tmdbId, season, episode } = parsed;

    const keyParam = await tmdbKeyParam(env);
    if (!keyParam) return null;
    const headers = await tmdbHeaders(env);
    const res = await fetch(`${TMDB_BASE}/${mediaType}/${tmdbId}?${keyParam}&language=en-US&append_to_response=external_ids`,
      { headers: { ...headers, "User-Agent": "Watch/1" }, signal: AbortSignal.timeout(10000) });
    if (!res.ok) return null;
    const detail = await res.json() as any;

    const links = buildEmbedUrls(tmdbId, mediaType, season, episode);
    return {
      id,
      title: detail.title || detail.name || "",
      year: (detail.release_date || detail.first_air_date) ? Number((detail.release_date || detail.first_air_date).slice(0, 4)) : null,
      imdbId: detail.external_ids?.imdb_id ?? null,
      poster: detail.poster_path ? `${TMDB_IMAGE}${detail.poster_path}` : null,
      hlsUrl: links.embedUrl,
      ...links,
      qualities: [],
      subtitles: [],
    };
  },
};
