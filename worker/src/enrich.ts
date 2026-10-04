/** Metadata for a title saved from an online source, straight from TMDB by its id.
 * Saved titles arrive with only a TMDB id, so without this they show as "tmdb 60625" with no poster,
 * overview, genres or trailer. Everything here is best effort: a miss leaves the title playable.
 */

import type { Env } from "./env";
import { storeImage } from "./ingest";

const TMDB = "https://api.themoviedb.org/3";
const IMG = "https://image.tmdb.org/t/p";

type TmdbVideo = { site?: string; key?: string; type?: string; official?: boolean; iso_639_1?: string };

async function secret(value: string | { get?: () => Promise<string> } | undefined): Promise<string> {
  if (!value) return "";
  if (typeof value === "string") return value;
  try {
    return (await value.get?.()) || "";
  } catch {
    return "";
  }
}

async function tmdb<T>(env: Env, pathAndQuery: string): Promise<T | null> {
  const headers: Record<string, string> = { Accept: "application/json", "User-Agent": "Watch/1" };
  let url = `${TMDB}${pathAndQuery}`;
  const bearer = await secret(env.WATCH_TMDB_API_READ_ACCESS_TOKEN);
  const apiKey = await secret(env.WATCH_TMDB_API_KEY);
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  else if (apiKey) url += `${url.includes("?") ? "&" : "?"}api_key=${encodeURIComponent(apiKey)}`;
  else return null;
  try {
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
    return res.ok ? ((await res.json()) as T) : null;
  } catch {
    return null;
  }
}

/** The official English trailer, else any trailer, else a teaser. */
export function pickTrailerKey(results: TmdbVideo[] | undefined): string | null {
  const yt = (results ?? []).filter((x) => x.site === "YouTube" && x.key);
  const trailers = yt.filter((x) => x.type === "Trailer");
  const pool = trailers.length ? trailers : yt.filter((x) => x.type === "Teaser");
  const english = pool.filter((x) => !x.iso_639_1 || x.iso_639_1 === "en");
  const list = english.length ? english : pool;
  return (list.find((x) => x.official) ?? list[0])?.key ?? null;
}

export type SavedTitle = { tmdbId: number; mediaType: "movie" | "tv"; season: number; episode: number };

type Detail = {
  title?: string;
  name?: string;
  release_date?: string;
  first_air_date?: string;
  overview?: string;
  runtime?: number;
  episode_run_time?: number[];
  genres?: { name: string }[];
  poster_path?: string | null;
  backdrop_path?: string | null;
  imdb_id?: string | null;
  external_ids?: { imdb_id?: string | null };
  videos?: { results?: TmdbVideo[] };
};

export async function enrichFromTmdb(env: Env, movieId: string, t: SavedTitle): Promise<boolean> {
  const kind = t.mediaType === "tv" ? "tv" : "movie";
  const d = await tmdb<Detail>(env, `/${kind}/${t.tmdbId}?language=en-US&append_to_response=external_ids,videos`);
  if (!d) return false;
  const show = d.title ?? d.name ?? `tmdb ${t.tmdbId}`;
  let title = show;
  let overview = d.overview ?? "";
  let runtime = d.runtime ?? d.episode_run_time?.[0] ?? null;
  if (kind === "tv") {
    const ep = await tmdb<{ name?: string; overview?: string; runtime?: number | null }>(
      env,
      `/tv/${t.tmdbId}/season/${t.season}/episode/${t.episode}?language=en-US`,
    );
    title = `${show} S${t.season} E${t.episode}${ep?.name ? `: ${ep.name}` : ""}`;
    if (ep?.overview) overview = ep.overview;
    if (ep?.runtime) runtime = ep.runtime;
  }
  const date = d.release_date ?? d.first_air_date ?? "";
  const year = /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null;
  const trailerKey = pickTrailerKey(d.videos?.results);
  const imdb = d.imdb_id ?? d.external_ids?.imdb_id ?? null;

  if (d.poster_path) await storeImage(env, movieId, "poster", `${IMG}/w500${d.poster_path}`);
  if (d.backdrop_path) await storeImage(env, movieId, "backdrop", `${IMG}/w1280${d.backdrop_path}`);

  await env.watch
    .prepare(
      `UPDATE movie SET title = ?, original_title = ?, year = ?, overview = ?,
         runtime_min = COALESCE(?, runtime_min), genres_json = ?, imdb_id = COALESCE(?, imdb_id),
         trailer_key = COALESCE(?, trailer_key), trailer_url = COALESCE(?, trailer_url), updated_at = ?
       WHERE id = ?`,
    )
    .bind(
      title,
      show,
      year,
      overview,
      runtime,
      JSON.stringify((d.genres ?? []).map((g) => g.name)),
      imdb,
      trailerKey,
      trailerKey ? `https://www.youtube.com/watch?v=${trailerKey}` : null,
      new Date().toISOString(),
      movieId,
    )
    .run();
  return true;
}
