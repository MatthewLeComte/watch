/** Stremio Cinemeta is the open-source movie metadata backend used by Stremio,
 * Plex, Jellyfin, and Kodi media libraries. One HTTP call returns title,
 * year, runtime, genres, overview, poster, background, IMDb id, cast, and
 * YouTube trailer ids. No API key, no WAF challenge. */

const BASE = "https://v3-cinemeta.strem.io";

export type CinemetaHit = {
  id: string;
  name: string;
  year: string | null;
  poster: string | null;
  background: string | null;
};

export type CinemetaMeta = CinemetaHit & {
  description: string;
  runtimeMin: number | null;
  genres: string[];
  imdbId: string;
  cast: string[];
  director: string[];
  writer: string[];
  trailerKey: string | null;
  imdbRating: string | null;
  released: string | null;
};

export async function cinemetaMeta(imdbId: string): Promise<CinemetaMeta | null> {
  if (!/^tt\d{7,8}$/.test(imdbId)) return null;
  const res = await fetch(`${BASE}/meta/movie/${imdbId}.json`, {
    headers: { Accept: "application/json", "User-Agent": "Watch/1" },
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) return null;
  const body = (await res.json()) as { meta?: Record<string, unknown> };
  if (!body.meta) return null;
  return parseMeta(body.meta);
}

/** Search by title. Returns up to ~20 hits sorted by Cinemeta's own relevance.
 * The first hit is the most popular match; the `year` field lets us pick the
 * one that matches a year parsed from the filename. */
export async function cinemetaSearch(query: string): Promise<CinemetaHit[]> {
  const q = query.trim();
  if (!q) return [];
  const url = `${BASE}/catalog/movie/top/search=${encodeURIComponent(q)}.json`;
  const res = await fetch(url, {
    headers: { Accept: "application/json", "User-Agent": "Watch/1" },
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) return [];
  const body = (await res.json()) as { metas?: Record<string, unknown>[] };
  const out: CinemetaHit[] = [];
  for (const m of body.metas ?? []) {
    const id = String(m.id ?? "");
    if (!/^tt\d{7,8}$/.test(id)) continue;
    const name = String(m.name ?? "");
    if (!name) continue;
    const year = typeof m.year === "string" ? m.year : typeof m.releaseInfo === "string" ? m.releaseInfo : null;
    out.push({
      id,
      name,
      year,
      poster: typeof m.poster === "string" ? m.poster : null,
      background: typeof m.background === "string" ? m.background : null,
    });
  }
  return out;
}

function parseMeta(raw: Record<string, unknown>): CinemetaMeta {
  const id = String(raw.id ?? "");
  const name = String(raw.name ?? "");
  const year = typeof raw.year === "string" ? raw.year : typeof raw.releaseInfo === "string" ? raw.releaseInfo : null;
  const runtime = typeof raw.runtime === "string" ? raw.runtime : "";
  const runtimeMin = parseRuntime(runtime);
  const genres = Array.isArray(raw.genres)
    ? raw.genres.map((g) => String(g))
    : Array.isArray(raw.genre)
      ? raw.genre.map((g) => String(g))
      : [];
  const description = typeof raw.description === "string" ? raw.description : "";
  const cast = Array.isArray(raw.cast) ? raw.cast.map((c) => String(c)) : [];
  const director = Array.isArray(raw.director) ? raw.director.map((d) => String(d)) : [];
  const writer = Array.isArray(raw.writer) ? raw.writer.map((w) => String(w)) : [];
  const trailerStreams = Array.isArray(raw.trailerStreams) ? raw.trailerStreams : [];
  const firstTrailer = trailerStreams[0] as { ytId?: string } | undefined;
  const trailerKey = firstTrailer && typeof firstTrailer.ytId === "string" ? firstTrailer.ytId : null;
  return {
    id,
    name,
    year,
    poster: typeof raw.poster === "string" ? raw.poster : null,
    background: typeof raw.background === "string" ? raw.background : null,
    description: description.slice(0, 2000),
    runtimeMin,
    genres,
    imdbId: id,
    cast,
    director,
    writer,
    trailerKey,
    imdbRating: typeof raw.imdbRating === "string" ? raw.imdbRating : null,
    released: typeof raw.released === "string" ? raw.released : null,
  };
}

function parseRuntime(raw: string): number | null {
  const m = raw.match(/(\d+)\s*min/i);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) && n > 0 ? n : null;
}
