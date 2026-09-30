/** Generic source interface: TMDB metadata in, documented Rive embed links out.
 *
 * Per worker/RIVESTREAM_EMBED_DOCS.md the worker never extracts HLS and never
 * downloads video bytes. It resolves a TMDB id to documented embed URLs and
 * the client (WKWebView hook on iOS) captures the playlist itself.
 */

import type { Env } from "../env";

export type SearchResult = {
  id: string;
  /** TMDB movie id. This is the id the add search is for. */
  tmdbId?: number | null;
  title: string;
  year: number | null;
  imdbId: string | null;
  poster: string | null;
  type: "movie" | "series";
};

export type StreamInfo = {
  id: string;
  title: string;
  year: number | null;
  imdbId: string | null;
  poster: string | null;
  /** Documented default embed page. The client loads this and captures HLS. */
  hlsUrl: string;
  /** Same as hlsUrl, named honestly. */
  embedUrl: string;
  /** Documented variants from /embed/docs. */
  torrentUrl: string;
  aggUrl: string;
  downloadUrl: string;
  /** Always empty: the worker does not extract variants. The client picks. */
  qualities: Quality[];
  /** Always empty: the worker does not extract subtitles. The client picks. */
  subtitles: SubtitleTrack[];
  cookieHeader?: string;
  httpHeaders?: Record<string, string>;
};

export type Quality = {
  height: number;
  bandwidth: number;
  codecs: string;
  uri: string;
};

export type SubtitleTrack = {
  lang: string;
  label: string;
  uri: string;
  forced: boolean;
};

export interface Source {
  readonly key: string;
  readonly name: string;
  search(query: string, env: Env): Promise<SearchResult[]>;
  searchByImdb(imdbId: string, env: Env): Promise<SearchResult | null>;
  resolve(env: Env, id: string): Promise<StreamInfo | null>;
  seasons?(env: Env, tmdbId: number): Promise<{ number: number; name: string; episodeCount: number }[]>;
  episodes?(env: Env, tmdbId: number, season: number): Promise<{ number: number; name: string }[]>;
}

export const SOURCES: Map<string, Source> = new Map();

export function registerSource(source: Source): void {
  SOURCES.set(source.key, source);
}

export function getSource(key: string): Source | undefined {
  return SOURCES.get(key);
}

export function listSources(): Source[] {
  return [...SOURCES.values()];
}
