/** Generic source interface for HLS-based movie sources. */

import type { Env } from "../env";
import { parseReleaseName } from "../lib";

export type SearchResult = {
  id: string;
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
  hlsUrl: string;
  qualities: Quality[];
  subtitles: SubtitleTrack[];
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
  readonly key: string;           // e.g., "67movies"
  readonly name: string;          // Display name
  search(query: string, env: Env): Promise<SearchResult[]>;
  searchByImdb(imdbId: string, env: Env): Promise<SearchResult | null>;
  resolve(env: Env, id: string): Promise<StreamInfo | null>;
  downloadAndIngest(env: Env, stream: StreamInfo, quality: Quality, subtitle?: SubtitleTrack): Promise<string>;
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