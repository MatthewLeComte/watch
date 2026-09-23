import type { Env } from "./env";
import { imdbSuggest, imdbTitle, type ImdbTitle } from "./imdb";
import {
  type Candidate,
  jevPick,
  needsJev,
  normTitle,
  openSubtitlesHash,
  parseReleaseName,
  scoreCandidate,
  srtToVtt,
} from "./lib";

const JEV_MODEL = "@cf/ibm-granite/granite-4.0-h-micro";
const JEV_GATEWAY = "make";

type SubHit = {
  lang: string;
  label: string;
  fileId: number;
  hearingImpaired: boolean;
  releaseName: string;
  downloads: number;
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

  let osHash: string | null = null;
  const subs: SubHit[] = [];
  const candidates: Candidate[] = [];

  if (movie.byte_size >= 131072) {
    try {
      osHash = await hashObject(env, movieId, movie.byte_size);
    } catch {
      osHash = null;
    }
  }

  const osKey = (env.OPENSUBTITLES_API_KEY || "").trim();
  if (osKey && osHash) {
    const found = await openSubtitlesByHash(osKey, osHash);
    candidates.push(...found.candidates);
    subs.push(...found.subs);
  }

  const osIds = [
    ...new Set(candidates.map((c) => c.imdbId).filter((id): id is string => Boolean(id))),
  ];
  let lockedId = parsed.imdbId || (osIds.length === 1 ? osIds[0] : null);
  if (!lockedId && parsed.title) {
    const hits = await imdbSuggest(`${parsed.title}${parsed.year ? ` ${parsed.year}` : ""}`);
    for (const hit of hits) {
      candidates.push({
        id: `imdb:${hit.id}`,
        title: hit.title,
        year: hit.year,
        overview: "",
        posterUrl: hit.image,
        imdbId: hit.id,
        tmdbId: null,
        runtimeMin: null,
        genres: [],
        source: "imdb",
      });
    }
  }

  const unique = dedupe(candidates);
  const scored = unique
    .map((c) => ({ c, score: scoreCandidate(parsed, c) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, 8);

  let winner = scored[0]?.c ?? null;
  let matchP: number | null = scored[0] ? 1 : null;
  let matchSource = winner?.source || "filename";
  let matchNote = winner
    ? `Matched from ${winner.source}`
    : "No catalog hit. Title is the filename.";
  let jevConsulted = false;

  if (!lockedId && winner && needsJev(scored.map((s) => s.score))) {
    jevConsulted = true;
    const options = scored.map((s) => ({
      id: s.c.id,
      label: `${s.c.title}${s.c.year ? ` (${s.c.year})` : ""} — ${s.c.source}`,
    }));
    let picked: { id: string; p: number } | null = null;
    try {
      picked = await jevPick(
        options,
        `${movie.filename} | parsed title ${parsed.title}${parsed.year ? ` (${parsed.year})` : ""}`,
        (prompt) => jevComplete(env, prompt),
      );
    } catch {
      picked = null;
    }
    if (picked) {
      const found = scored.find((s) => s.c.id === picked.id);
      if (found) {
        winner = found.c;
        matchP = picked.p;
        matchSource = "jev";
        matchNote = `Jev ${(picked.p * 100).toFixed(0)}% among ${options.length} titles`;
      }
    } else if (scored[0]) {
      matchSource = scored[0].c.source;
      matchNote = jevConsulted
        ? `Filename score ${scored[0].score}. Jev did not return a usable distribution.`
        : `Filename score ${scored[0].score} — single clear match, Jev not needed.`;
    }
  } else if (scored[0] && scored[0].score >= 140) {
    matchNote = `Exact title and year from ${scored[0].c.source}`;
  }

  if (lockedId) {
    matchSource = parsed.imdbId ? "imdb" : "opensubtitles";
    matchNote = parsed.imdbId
      ? `IMDb id in the filename (${lockedId})`
      : `OpenSubtitles hash is ${lockedId}`;
    matchP = 1;
    winner = {
      id: `imdb:${lockedId}`,
      title: parsed.title,
      year: parsed.year,
      overview: "",
      posterUrl: null,
      imdbId: lockedId,
      tmdbId: null,
      runtimeMin: null,
      genres: [],
      source: matchSource,
    };
  }

  const imdbId = winner?.imdbId || lockedId;
  let trailer: Pick<ImdbTitle, "trailerSite" | "trailerKey" | "trailerUrl"> | null = null;
  if (imdbId) {
    const page = await imdbTitle(imdbId);
    if (page) {
      winner = {
        id: `imdb:${imdbId}`,
        title: page.title || winner?.title || parsed.title,
        year: page.year ?? winner?.year ?? parsed.year,
        overview: page.overview || winner?.overview || "",
        posterUrl: page.posterUrl || winner?.posterUrl || null,
        imdbId,
        tmdbId: winner?.tmdbId ?? null,
        runtimeMin: page.runtimeMin,
        genres: page.genres,
        source: winner?.source || "imdb",
      };
      trailer = page;
      if (matchSource !== "jev") {
        matchSource = matchSource === "filename" ? "imdb" : matchSource;
        if (!matchNote.startsWith("IMDb") && !matchNote.startsWith("OpenSubtitles") && !matchNote.startsWith("Jev")) {
          matchNote = `IMDb ${imdbId}`;
        }
      }
    }
  }

  // TMDB fallback: imdbTitle often returns null (blocks/layout), leaving
  // no overview, genres, runtime, or poster. Fill the gaps from TMDB.
  const tmdbKey = (env.TMDB_API_KEY || "").trim();
  if (tmdbKey && parsed.title && (!winner?.overview || !winner?.posterUrl)) {
    try {
      const hits = await tmdbSearch(tmdbKey, parsed.title, parsed.year);
      const best = hits.find((h) => !parsed.year || h.year === parsed.year) ?? hits[0];
      if (best?.tmdbId) {
        const detail = await tmdbDetail(tmdbKey, best.tmdbId);
        if (detail && (detail.overview || detail.posterUrl)) {
          winner = {
            id: winner?.id ?? best.id,
            title: winner?.title || detail.title || parsed.title,
            year: winner?.year ?? detail.year ?? parsed.year,
            overview: winner?.overview || detail.overview || "",
            posterUrl: winner?.posterUrl || detail.posterUrl || null,
            imdbId: winner?.imdbId ?? lockedId ?? detail.imdbId ?? null,
            tmdbId: detail.tmdbId ?? best.tmdbId ?? null,
            runtimeMin: winner?.runtimeMin ?? detail.runtimeMin ?? null,
            genres: winner?.genres?.length ? winner.genres : (detail.genres ?? []),
            source: winner?.source || "tmdb",
          };
          if (matchSource === "filename") matchSource = "tmdb";
          matchNote += ` TMDB filled ${detail.tmdbId}.`;
        }
      }
    } catch {
      /* keep IMDb/filename data */
    }
  }

  const title = winner?.title || parsed.title;
  const year = winner?.year ?? parsed.year;
  let posterKey: string | null = null;
  if (winner?.posterUrl) {
    posterKey = await storePoster(env, movieId, winner.posterUrl);
  }

  // Subs fallback: hash matches one exact version. For unreleased or rare
  // versions the hash finds nothing, so retry by IMDb id (other releases
  // of the same film) before giving up.
  if (osKey && subs.length === 0) {
    const effImdb = winner?.imdbId ?? lockedId ?? parsed.imdbId ?? null;
    if (effImdb) {
      try {
        const fb = await openSubtitlesByImdb(osKey, effImdb);
        if (fb.subs.length) {
          subs.push(...fb.subs);
          matchNote += " Subtitles from another release of the same film.";
        }
      } catch {
        /* keep the exact-only result */
      }
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

  await env.watch
    .prepare(
      `UPDATE movie SET title = ?, original_title = ?, year = ?, overview = ?, runtime_min = ?,
       genres_json = ?, imdb_id = ?, tmdb_id = ?, os_hash = ?, trailer_site = ?, trailer_key = ?,
       trailer_url = ?, status = 'ready',
       match_source = ?, match_p = ?, match_note = ?, updated_at = ? WHERE id = ?`,
    )
    .bind(
      title,
      winner?.title ?? null,
      year,
      (winner?.overview || "").slice(0, 2000),
      winner?.runtimeMin ?? null,
      JSON.stringify(winner?.genres ?? []),
      winner?.imdbId ?? parsed.imdbId,
      winner?.tmdbId ?? null,
      osHash,
      trailer?.trailerSite ?? null,
      trailer?.trailerKey ?? null,
      trailer?.trailerUrl ?? null,
      matchSource,
      matchP,
      matchNote.slice(0, 500),
      new Date().toISOString(),
      movieId,
    )
    .run();
  void posterKey;
}

async function hashObject(env: Env, movieId: string, size: number): Promise<string> {
  const key = `video/${movieId}`;
  const head = await env.watch_bucket.get(key, { range: { offset: 0, length: 65536 } });
  const tail = await env.watch_bucket.get(key, { range: { offset: size - 65536, length: 65536 } });
  if (!head || !tail) throw new Error("missing");
  return openSubtitlesHash(size, new Uint8Array(await head.arrayBuffer()), new Uint8Array(await tail.arrayBuffer()));
}

async function jevComplete(env: Env, prompt: string): Promise<string> {
  const ai = env.AI as unknown as {
    run: (model: string, input: unknown, options?: unknown) => Promise<unknown>;
  };
  const result = await ai.run(
    JEV_MODEL,
    {
      messages: [
        {
          role: "system",
          content: "You assign probabilities over a fixed set of movie ids. Reply with JSON only.",
        },
        { role: "user", content: prompt },
      ],
    },
    { gateway: { id: JEV_GATEWAY, skipCache: true } },
  );
  return textOf(result);
}

function textOf(result: unknown): string {
  if (!result || typeof result !== "object") return "";
  const r = result as Record<string, unknown>;
  if (typeof r.response === "string") return r.response;
  const choices = r.choices as { message?: { content?: unknown } }[] | undefined;
  const content = choices?.[0]?.message?.content;
  return typeof content === "string" ? content : "";
}

function dedupe(list: Candidate[]): Candidate[] {
  const out: Candidate[] = [];
  const seen = new Set<string>();
  for (const c of list) {
    const key = c.imdbId || `${normTitle(c.title)}|${c.year ?? ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(c);
  }
  return out;
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
): Promise<{ candidates: Candidate[]; subs: SubHit[] }> {
  const res = await fetch(
    `https://api.opensubtitles.com/api/v1/subtitles?moviehash=${hash}&languages=en`,
    { headers: osHeaders(apiKey), signal: AbortSignal.timeout(8000) },
  );
  if (!res.ok) return { candidates: [], subs: [] };
  const body = (await res.json()) as { data?: OsRow[] };
  return parseOsData(body);
}

async function openSubtitlesByImdb(
  apiKey: string,
  imdbId: string,
): Promise<{ candidates: Candidate[]; subs: SubHit[] }> {
  const tt = imdbId.startsWith("tt") ? imdbId : `tt${imdbId.padStart(7, "0")}`;
  const res = await fetch(
    `https://api.opensubtitles.com/api/v1/subtitles?imdb_id=${tt.slice(2)}&languages=en`,
    { headers: osHeaders(apiKey), signal: AbortSignal.timeout(8000) },
  );
  if (!res.ok) return { candidates: [], subs: [] };
  const body = (await res.json()) as { data?: OsRow[] };
  return parseOsData(body);
}

function parseOsData(body: { data?: OsRow[] }): { candidates: Candidate[]; subs: SubHit[] } {
  const candidates: Candidate[] = [];
  const subs: SubHit[] = [];
  for (const row of body.data ?? []) {
    const a = row.attributes;
    if (!a) continue;
    const feature = a.feature_details;
    const imdb = feature?.imdb_id ? String(feature.imdb_id) : null;
    const imdbId = imdb && !imdb.startsWith("tt") ? `tt${imdb.padStart(7, "0")}` : imdb;
    const title = feature?.movie_name || feature?.title || "";
    if (title) {
      candidates.push({
        id: imdbId ? `imdb:${imdbId}` : `os:${feature?.feature_id ?? title}`,
        title,
        year: feature?.year ?? null,
        overview: "",
        posterUrl: null,
        imdbId,
        tmdbId: feature?.tmdb_id ? String(feature.tmdb_id) : null,
        runtimeMin: null,
        genres: [],
        source: "opensubtitles",
      });
    }
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
  return { candidates, subs };
}

type OsRow = {
  attributes?: {
    language?: string;
    hearing_impaired?: boolean;
    release?: string;
    download_count?: number;
    files?: { file_id?: number }[];
    feature_details?: {
      feature_id?: number;
      title?: string;
      movie_name?: string;
      year?: number;
      imdb_id?: number | string;
      tmdb_id?: number;
    };
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

async function tmdbSearch(key: string, title: string, year: number | null): Promise<Candidate[]> {
  const url = new URL("https://api.themoviedb.org/3/search/movie");
  url.searchParams.set("api_key", key);
  url.searchParams.set("query", title);
  if (year) url.searchParams.set("year", String(year));
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) return [];
  const body = (await res.json()) as {
    results?: {
      id: number;
      title: string;
      overview?: string;
      poster_path?: string | null;
      release_date?: string;
    }[];
  };
  return (body.results ?? []).slice(0, 5).map((row) => ({
    id: `tmdb:${row.id}`,
    title: row.title,
    year: row.release_date ? Number(row.release_date.slice(0, 4)) : null,
    overview: row.overview || "",
    posterUrl: row.poster_path ? `https://image.tmdb.org/t/p/w780${row.poster_path}` : null,
    imdbId: null,
    tmdbId: String(row.id),
    runtimeMin: null,
    genres: [],
    source: "tmdb",
  }));
}

async function tmdbDetail(key: string, id: string): Promise<Partial<Candidate> | null> {
  const res = await fetch(
    `https://api.themoviedb.org/3/movie/${encodeURIComponent(id)}?api_key=${encodeURIComponent(key)}`,
    { signal: AbortSignal.timeout(8000) },
  );
  if (!res.ok) return null;
  const row = (await res.json()) as {
    overview?: string;
    runtime?: number;
    imdb_id?: string;
    poster_path?: string | null;
    genres?: { name: string }[];
    title?: string;
    release_date?: string;
  };
  return {
    title: row.title,
    year: row.release_date ? Number(row.release_date.slice(0, 4)) : null,
    overview: row.overview || "",
    posterUrl: row.poster_path ? `https://image.tmdb.org/t/p/w780${row.poster_path}` : null,
    imdbId: row.imdb_id || null,
    tmdbId: id,
    runtimeMin: row.runtime || null,
    genres: (row.genres ?? []).map((g) => g.name),
  };
}

async function wikipediaFilms(title: string, year: number | null): Promise<Candidate[]> {
  const q = `${title}${year ? ` ${year}` : ""} film`;
  const url = new URL("https://en.wikipedia.org/w/api.php");
  url.searchParams.set("action", "query");
  url.searchParams.set("generator", "search");
  url.searchParams.set("gsrsearch", q);
  url.searchParams.set("gsrlimit", "5");
  url.searchParams.set("prop", "pageimages|extracts|pageprops");
  url.searchParams.set("piprop", "thumbnail");
  url.searchParams.set("pithumbsize", "780");
  url.searchParams.set("exintro", "1");
  url.searchParams.set("explaintext", "1");
  url.searchParams.set("exchars", "600");
  url.searchParams.set("format", "json");
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) return [];
  const body = (await res.json()) as {
    query?: {
      pages?: Record<
        string,
        {
          title?: string;
          extract?: string;
          thumbnail?: { source?: string };
          pageprops?: { wikibase_item?: string };
        }
      >;
    };
  };
  const pages = Object.values(body.query?.pages ?? {});
  const qids = pages.map((p) => p.pageprops?.wikibase_item).filter((x): x is string => Boolean(x));
  const claims = await wikidata(qids);
  const out: Candidate[] = [];
  for (const page of pages) {
    const cleaned = cleanWikiTitle(page.title || "");
    const qid = page.pageprops?.wikibase_item;
    const extra = qid ? claims.get(qid) : undefined;
    if (extra && extra.film === false) continue;
    const yearHit = extra?.year ?? cleaned.year ?? year;
    out.push({
      id: extra?.imdbId ? `imdb:${extra.imdbId}` : qid ? `wiki:${qid}` : `wiki:${cleaned.title}`,
      title: cleaned.title,
      year: yearHit,
      overview: page.extract || "",
      posterUrl: page.thumbnail?.source || null,
      imdbId: extra?.imdbId ?? null,
      tmdbId: null,
      runtimeMin: extra?.runtimeMin ?? null,
      genres: [],
      source: "wikipedia",
    });
  }
  return out;
}

function cleanWikiTitle(title: string): { title: string; year: number | null } {
  const m = title.match(/^(.*?)\s+\((?:(\d{4})\s+)?film\)$/i);
  if (!m) return { title, year: null };
  return { title: (m[1] || title).trim(), year: m[2] ? Number(m[2]) : null };
}

async function wikidata(
  qids: string[],
): Promise<Map<string, { imdbId: string | null; year: number | null; runtimeMin: number | null; film: boolean }>> {
  const map = new Map<string, { imdbId: string | null; year: number | null; runtimeMin: number | null; film: boolean }>();
  if (!qids.length) return map;
  const url = new URL("https://www.wikidata.org/w/api.php");
  url.searchParams.set("action", "wbgetentities");
  url.searchParams.set("ids", qids.join("|"));
  url.searchParams.set("props", "claims");
  url.searchParams.set("format", "json");
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) return map;
  const body = (await res.json()) as { entities?: Record<string, { claims?: Record<string, Claim[]> }> };
  for (const [qid, entity] of Object.entries(body.entities ?? {})) {
    const claims = entity.claims ?? {};
    const imdbRaw = claimString(claims.P345);
    const imdbId = imdbRaw
      ? imdbRaw.startsWith("tt")
        ? imdbRaw
        : `tt${imdbRaw.replace(/\D/g, "").padStart(7, "0")}`
      : null;
    const time = claimString(claims.P577);
    const year = time ? Number(time.slice(1, 5)) : null;
    const amount = claimString(claims.P2047);
    const runtimeMin = amount ? Math.round(Number(amount)) : null;
    const kinds = (claims.P31 ?? []).map((c) => claimId(c)).filter((id): id is string => Boolean(id));
    const film = kinds.length === 0 || kinds.includes("Q11424") || kinds.includes("Q24869") || kinds.includes("Q506240");
    map.set(qid, {
      imdbId,
      year: Number.isFinite(year) ? year : null,
      runtimeMin: Number.isFinite(runtimeMin) ? runtimeMin : null,
      film,
    });
  }
  return map;
}

type Claim = { mainsnak?: { datavalue?: { value?: { id?: string; time?: string; amount?: string } | string } } };

function claimId(claim: Claim | undefined): string | null {
  const value = claim?.mainsnak?.datavalue?.value;
  if (!value || typeof value === "string") return null;
  return value.id ?? null;
}

function claimString(claims: Claim[] | undefined): string | null {
  const value = claims?.[0]?.mainsnak?.datavalue?.value;
  if (!value) return null;
  if (typeof value === "string") return value;
  return value.time || value.amount || value.id || null;
}

async function storePoster(env: Env, movieId: string, url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const type = res.headers.get("content-type") || "image/jpeg";
    const buf = await res.arrayBuffer();
    if (buf.byteLength < 32 || buf.byteLength > 8_000_000) return null;
    const key = `poster/${movieId}`;
    await env.watch_bucket.put(key, buf, { httpMetadata: { contentType: type } });
    return key;
  } catch {
    return null;
  }
}
