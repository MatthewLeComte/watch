import type { Env } from "./env";
import { cinemetaMeta, cinemetaSearch } from "./cinemeta";
import { openSubtitlesHash, parseReleaseName, srtToVtt } from "./lib";

type SubHit = {
  lang: string;
  label: string;
  fileId: number;
  hearingImpaired: boolean;
  releaseName: string;
  downloads: number;
};

type CachedWinner = {
  title: string;
  year: number | null;
  overview: string;
  poster_url: string | null;
  backdrop_url: string | null;
  runtime_min: number | null;
  genres: string[];
  source: string;
};

export async function ingest(env: Env, movieId: string): Promise<void> {
  const movie = await env.watch
    .prepare("SELECT id, filename, byte_size, ext FROM movie WHERE id = ?")
    .bind(movieId)
    .first<{ id: string; filename: string; byte_size: number; ext: string }>();
  if (!movie) return;

  const parsed = parseReleaseName(movie.filename);
  const now = new Date().toISOString();
  await env.watch
    .prepare("UPDATE movie SET status = 'ingesting', title = ?, year = ?, updated_at = ? WHERE id = ?")
    .bind(parsed.title, parsed.year, now, movieId)
    .run();

  // One source, no fallbacks: Stremio Cinemeta. If the filename carries an
  // IMDb id we use it directly; otherwise we search by title (and year, when
  // the filename has one) and pick the best hit. Every successful fetch
  // is cached by imdbId, so a second file for the same film is free.
  const imdbId = await resolveImdbId(parsed.imdbId, parsed.title, parsed.year);
  let matchSource: string;
  let matchP: number | null;
  let matchNote: string;

  const cached = imdbId ? await loadCached(env, imdbId) : null;
  let detail: CinemetaLike | null = null;

  if (cached && cached.overview) {
    matchSource = parsed.imdbId ? "imdb" : "cinemeta";
    matchP = 1;
    matchNote = parsed.imdbId
      ? `IMDb id in the filename (${imdbId})`
      : `Cinemeta search (${imdbId})`;
    matchNote += " Details from cache.";
    detail = cachedToDetail(cached, imdbId!);
  } else if (imdbId) {
    const meta = await cinemetaMeta(imdbId);
    if (meta) {
      detail = metaToDetail(meta);
      matchSource = parsed.imdbId ? "imdb" : "cinemeta";
      matchP = 1;
      matchNote = parsed.imdbId
        ? `IMDb id in the filename (${imdbId})`
        : `Cinemeta search (${imdbId})`;
    } else {
      matchSource = "filename";
      matchP = null;
      matchNote = `No Cinemeta entry for ${imdbId || "this title"}.`;
    }
  } else {
    matchSource = "filename";
    matchP = null;
    matchNote = "No catalog hit. Title is the filename.";
  }

  // OpenSubtitles hash for subtitle matching only (not used to identify
  // the film — Cinemeta does that).
  let osHash: string | null = null;
  const subs: SubHit[] = [];
  const osKey = (env.OPENSUBTITLES_API_KEY || "").trim();
  if (movie.byte_size >= 131072) {
    try {
      osHash = await hashObject(env, movieId, movie.byte_size);
    } catch {
      osHash = null;
    }
    if (osKey && osHash) {
      try {
        const found = await openSubtitlesByHash(osKey, osHash);
        subs.push(...found.subs);
      } catch {
        /* keep going without subs */
      }
    }
  }

  // Persist both images to R2 in parallel.
  if (detail?.posterUrl) await storeImage(env, movieId, "poster", detail.posterUrl);
  if (detail?.backdropUrl) await storeImage(env, movieId, "backdrop", detail.backdropUrl);

  // Persist the per-imdbId cache so the next file for the same film is free.
  if (imdbId && detail && (detail.overview || detail.posterUrl)) {
    await saveCache(env, imdbId, detail);
  }

  // If OpenSubtitles found nothing for the exact hash, retry by IMDb id
  // (other releases of the same film).
  if (osKey && osHash && subs.length === 0 && imdbId) {
    try {
      const fb = await openSubtitlesByImdb(osKey, imdbId);
      if (fb.subs.length) {
        subs.push(...fb.subs);
        matchNote += " Subtitles from another release of the same film.";
      }
    } catch {
      /* keep the exact-only result */
    }
  }

  const keptSubs = pickSubs(subs);
  for (const sub of keptSubs) {
    const vtt = await downloadSub(osKey, sub.fileId);
    if (!vtt) continue;
    const key = `sub/${movieId}/${sub.lang}.vtt`;
    await env.watch_bucket.put(key, vtt, { httpMetadata: { contentType: "text/vtt" } });
    await env.watch
      .prepare(
        `INSERT INTO subtitle (movie_id, lang, label, r2_key, hearing_impaired, source, release_name)
         VALUES (?, ?, ?, ?, ?, 'opensubtitles', ?)
         ON CONFLICT(movie_id, lang) DO UPDATE SET
           label = excluded.label, r2_key = excluded.r2_key,
           hearing_impaired = excluded.hearing_impaired, source = 'opensubtitles',
           release_name = excluded.release_name`,
      )
      .bind(movieId, sub.lang, sub.label, key, sub.hearingImpaired ? 1 : 0, sub.releaseName)
      .run();
  }
  if (osHash && keptSubs.length === 0) {
    matchNote += " No OpenSubtitles file matched this exact version.";
  }

  const title = detail?.title || parsed.title;
  const year = detail?.year ?? parsed.year;
  const trailerKey = detail?.trailerKey ?? null;

  await env.watch
    .prepare(
      `UPDATE movie SET title = ?, original_title = ?, year = ?, overview = ?, runtime_min = ?,
       genres_json = ?, imdb_id = ?, os_hash = ?, trailer_site = ?, trailer_key = ?,
       trailer_url = ?, status = 'ready',
       match_source = ?, match_p = ?, match_note = ?, updated_at = ? WHERE id = ?`,
    )
    .bind(
      title,
      detail?.title ?? null,
      year,
      (detail?.overview || "").slice(0, 2000),
      detail?.runtimeMin ?? null,
      JSON.stringify(detail?.genres ?? []),
      detail?.imdbId ?? parsed.imdbId,
      osHash,
      trailerKey ? "youtube" : null,
      trailerKey,
      trailerKey ? `https://www.youtube.com/watch?v=${trailerKey}` : null,
      matchSource,
      matchP,
      matchNote.slice(0, 500),
      new Date().toISOString(),
      movieId,
    )
    .run();
}

type CinemetaLike = {
  title: string;
  year: number | null;
  overview: string;
  posterUrl: string | null;
  backdropUrl: string | null;
  runtimeMin: number | null;
  genres: string[];
  imdbId: string;
  trailerKey: string | null;
};

function metaToDetail(meta: Awaited<ReturnType<typeof cinemetaMeta>>): CinemetaLike {
  if (!meta) {
    return { title: "", year: null, overview: "", posterUrl: null, backdropUrl: null, runtimeMin: null, genres: [], imdbId: "", trailerKey: null };
  }
  return {
    title: meta.name,
    year: meta.year ? Number(meta.year) || null : null,
    overview: meta.description,
    posterUrl: meta.poster,
    backdropUrl: meta.background,
    runtimeMin: meta.runtimeMin,
    genres: meta.genres,
    imdbId: meta.imdbId,
    trailerKey: meta.trailerKey,
  };
}

function cachedToDetail(c: CachedWinner, imdbId: string): CinemetaLike {
  return {
    title: c.title,
    year: c.year,
    overview: c.overview,
    posterUrl: c.poster_url,
    backdropUrl: c.backdrop_url,
    runtimeMin: c.runtime_min,
    genres: c.genres,
    imdbId,
    trailerKey: null,
  };
}

async function resolveImdbId(
  filenameId: string | null,
  title: string,
  year: number | null,
): Promise<string | null> {
  if (filenameId && /^tt\d{7,8}$/.test(filenameId)) return filenameId.toLowerCase();
  if (!title) return null;
  // CamelCase titles like "ShangChi" need splitting before they can match
  // Cinemeta's "Shang-Chi" or "Shang Chi". "Lilo&Stich" still works because
  // the ampersand is non-alphanumeric and the norm already treats it as a
  // separator, so the existing scoring path handles it.
  const queries = Array.from(new Set([title, splitCamelCase(title)].filter(Boolean)));
  try {
    let hits: Awaited<ReturnType<typeof cinemetaSearch>> = [];
    for (const q of queries) {
      const found = await cinemetaSearch(q);
      if (found.length) { hits = found; break; }
    }
    if (!hits.length) return null;
    if (year) {
      const byYear = hits.find((h) => h.year === String(year));
      if (byYear) return byYear.id;
    }
    // No year, or no year match: pick the hit where the query's words appear
    // in the same order in the candidate title. "Joseph King of Dreams" should
    // beat "King of Dreams" because the first query word starts the candidate.
    const scored = hits
      .map((h) => ({ h, score: scoreTitle(queries[0]!, h.name) }))
      .sort((a, b) => b.score - a.score);
    return scored[0]?.h.id ?? null;
  } catch {
    return null;
  }
}

/** Split a camelCase or run-together word into separate words.
 *  "ShangChi" → "Shang Chi", "AWonderfulLife" → "A Wonderful Life". */
function splitCamelCase(s: string): string {
  return s
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2");
}

/** Score a Cinemeta hit against a parsed title. Higher = better match.
 *  - +100 if the candidate title starts with the first query word
 *  - +50  if the full query appears as a contiguous substring of the candidate
 *  - +10  for every query word found in the candidate (any position)
 *  - -50  if a query word is missing from the candidate entirely
 *  - -5   per extra word in the candidate beyond the query
 *  Short tokens (the, a, 2, e) are kept so "Patlabor 2" and "Titan A.E."
 *  can still discriminate against "Patlabor" and "Titanic".
 *  Word membership is checked with a set so a single miss (e.g. camelCase
 *  "ShangChi" vs "Shang Chi") does not poison the rest of the scoring. */
function scoreTitle(query: string, candidate: string): number {
  const q = norm(query);
  const c = norm(candidate);
  if (!q || !c) return 0;
  const qWords = q.split(" ").filter((w) => w.length > 0);
  const cWords = c.split(" ");
  if (!qWords.length) return 0;
  const cSet = new Set(cWords);
  let score = 0;
  if (cWords[0] === qWords[0]) score += 100;
  if (c.includes(q)) score += 50;
  for (const w of qWords) {
    if (cSet.has(w)) score += 10;
    else score -= 50;
  }
  if (cWords.length > qWords.length) score -= 5 * (cWords.length - qWords.length);
  return score;
}

function norm(s: string): string {
  return s
    .toLowerCase()
    .replace(/['\u2018\u2019']/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

async function loadCached(env: Env, imdbId: string): Promise<CachedWinner | null> {
  const row = await env.watch
    .prepare(
      "SELECT title, year, overview, poster_url, backdrop_url, runtime_min, genres_json, source FROM movie_cache WHERE imdb_id = ?",
    )
    .bind(imdbId)
    .first<{
      title: string;
      year: number | null;
      overview: string;
      poster_url: string | null;
      backdrop_url: string | null;
      runtime_min: number | null;
      genres_json: string;
      source: string;
    }>();
  if (!row) return null;
  let genres: string[] = [];
  try {
    const parsed = JSON.parse(row.genres_json);
    if (Array.isArray(parsed)) genres = parsed.map((g) => String(g));
  } catch {
    genres = [];
  }
  return {
    title: row.title,
    year: row.year,
    overview: row.overview,
    poster_url: row.poster_url,
    backdrop_url: row.backdrop_url,
    runtime_min: row.runtime_min,
    genres,
    source: row.source,
  };
}

export async function saveCache(env: Env, imdbId: string, detail: CinemetaLike): Promise<void> {
  await env.watch
    .prepare(
      `INSERT OR REPLACE INTO movie_cache
         (imdb_id, title, year, overview, poster_url, backdrop_url, runtime_min, genres_json, source, fetched_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      imdbId,
      detail.title || "",
      detail.year,
      detail.overview || "",
      detail.posterUrl,
      detail.backdropUrl,
      detail.runtimeMin,
      JSON.stringify(detail.genres || []),
      "cinemeta",
      new Date().toISOString(),
    )
    .run();
}

async function hashObject(env: Env, movieId: string, size: number): Promise<string> {
  const key = `video/${movieId}`;
  const head = await env.watch_bucket.get(key, { range: { offset: 0, length: 65536 } });
  const tail = await env.watch_bucket.get(key, { range: { offset: size - 65536, length: 65536 } });
  if (!head || !tail) throw new Error("missing");
  return openSubtitlesHash(size, new Uint8Array(await head.arrayBuffer()), new Uint8Array(await tail.arrayBuffer()));
}

async function storeImage(env: Env, movieId: string, kind: "poster" | "backdrop", url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const type = res.headers.get("content-type") || (kind === "backdrop" ? "image/jpeg" : "image/jpeg");
    const buf = await res.arrayBuffer();
    // Backdrop is wider and can be larger; poster must stay small for the TV grid.
    const max = kind === "backdrop" ? 1_500_000 : 1_000_000;
    if (buf.byteLength < 4096 || buf.byteLength > max) return null;
    const key = `${kind}/${movieId}`;
    await env.watch_bucket.put(key, buf, { httpMetadata: { contentType: type } });
    return key;
  } catch {
    return null;
  }
}

function pickSubs(subs: SubHit[]): SubHit[] {
  const byLang = new Map<string, SubHit>();
  const ranked = [...subs].sort((a, b) => {
    if (a.hearingImpaired !== b.hearingImpaired) return a.hearingImpaired ? 1 : -1;
    return b.downloads - a.downloads;
  });
  for (const sub of ranked) {
    if (!byLang.has(sub.lang)) byLang.set(sub.lang, sub);
  }
  const chosen: SubHit[] = [];
  const en = byLang.get("en");
  if (en) chosen.push(en);
  for (const sub of byLang.values()) {
    if (chosen.length >= 3) break;
    if (!chosen.some((c) => c.lang === sub.lang)) chosen.push(sub);
  }
  return chosen;
}

async function openSubtitlesByHash(
  apiKey: string,
  hash: string,
): Promise<{ candidates: never[]; subs: SubHit[] }> {
  const res = await fetch(
    `https://api.opensubtitles.com/api/v1/subtitles?moviehash=${hash}&languages=en`,
    { headers: osHeaders(apiKey), signal: AbortSignal.timeout(8000) },
  );
  if (!res.ok) return { candidates: [], subs: [] };
  const body = (await res.json()) as { data?: OsRow[] };
  const subs: SubHit[] = [];
  for (const row of body.data ?? []) {
    const a = row.attributes;
    if (!a) continue;
    const fileId = a.files?.[0]?.file_id;
    if (fileId && a.language) {
      subs.push({
        lang: a.language,
        label: a.language === "en" ? "English" : a.language,
        fileId,
        hearingImpaired: Boolean(a.hearing_impaired),
        releaseName: a.release || "",
        downloads: a.download_count || 0,
      });
    }
  }
  return { candidates: [], subs };
}

async function openSubtitlesByImdb(
  apiKey: string,
  imdbId: string,
): Promise<{ subs: SubHit[] }> {
  const tt = imdbId.startsWith("tt") ? imdbId : `tt${imdbId.padStart(7, "0")}`;
  const res = await fetch(
    `https://api.opensubtitles.com/api/v1/subtitles?imdb_id=${tt.slice(2)}&languages=en`,
    { headers: osHeaders(apiKey), signal: AbortSignal.timeout(8000) },
  );
  if (!res.ok) return { subs: [] };
  const body = (await res.json()) as { data?: OsRow[] };
  const subs: SubHit[] = [];
  for (const row of body.data ?? []) {
    const a = row.attributes;
    if (!a) continue;
    const fileId = a.files?.[0]?.file_id;
    if (fileId && a.language) {
      subs.push({
        lang: a.language,
        label: a.language === "en" ? "English" : a.language,
        fileId,
        hearingImpaired: Boolean(a.hearing_impaired),
        releaseName: a.release || "",
        downloads: a.download_count || 0,
      });
    }
  }
  return { subs };
}

type OsRow = {
  attributes?: {
    language?: string;
    hearing_impaired?: boolean;
    release?: string;
    download_count?: number;
    files?: { file_id?: number }[];
  };
};

function osHeaders(apiKey: string): HeadersInit {
  return {
    "Api-Key": apiKey,
    "User-Agent": "Watch v1.0",
    Accept: "application/json",
    "Content-Type": "application/json",
  };
}

async function downloadSub(apiKey: string, fileId: number): Promise<string | null> {
  if (!apiKey) return null;
  const res = await fetch("https://api.opensubtitles.com/api/v1/download", {
    method: "POST",
    headers: osHeaders(apiKey),
    body: JSON.stringify({ file_id: fileId }),
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) return null;
  const body = (await res.json()) as { link?: string };
  if (!body.link) return null;
  const file = await fetch(body.link, { signal: AbortSignal.timeout(8000) });
  if (!file.ok) return null;
  const raw = await file.text();
  if (raw.includes("-->") && raw.trimStart().startsWith("WEBVTT")) return raw;
  return srtToVtt(raw);
}
