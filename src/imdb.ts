/** IMDb is the match. Same id local library apps store (tt#######). One lookup, no second pass. */

export type ImdbHit = {
  id: string;
  title: string;
  year: number | null;
  image: string | null;
  kind: string;
};

export type ImdbTitle = {
  id: string;
  title: string;
  year: number | null;
  overview: string;
  posterUrl: string | null;
  genres: string[];
  runtimeMin: number | null;
  trailerUrl: string | null;
  trailerSite: string | null;
  trailerKey: string | null;
};

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

export function parseImdbSuggestions(body: unknown): ImdbHit[] {
  const rows = (body as { d?: unknown }).d;
  if (!Array.isArray(rows)) return [];
  const out: ImdbHit[] = [];
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const item = row as {
      id?: string;
      l?: string;
      y?: number;
      q?: string;
      qid?: string;
      i?: { imageUrl?: string };
    };
    const id = String(item.id || "");
    if (!/^tt\d{7,8}$/.test(id) || !item.l) continue;
    const kind = String(item.qid || item.q || "");
    if (kind && !/movie|feature|tvMovie|video/i.test(kind)) continue;
    out.push({
      id,
      title: item.l,
      year: typeof item.y === "number" ? item.y : null,
      image: item.i?.imageUrl || null,
      kind,
    });
  }
  return out;
}

export function parseImdbTitlePage(html: string, id: string): ImdbTitle | null {
  const re = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(html))) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(match[1] || "");
    } catch {
      continue;
    }
    const found = walkLd(parsed);
    if (found) return { id, ...found };
  }
  return null;
}

function walkLd(node: unknown): Omit<ImdbTitle, "id"> | null {
  if (!node || typeof node !== "object") return null;
  if (Array.isArray(node)) {
    for (const item of node) {
      const hit = walkLd(item);
      if (hit) return hit;
    }
    return null;
  }
  const obj = node as Record<string, unknown>;
  const rawType = obj["@type"];
  const types = (Array.isArray(rawType) ? rawType : [rawType]).map((t) => String(t));
  if (types.some((t) => t === "Movie" || t === "TVMovie" || t === "TVSeries")) {
    return readMovie(obj);
  }
  if (obj["@graph"]) return walkLd(obj["@graph"]);
  return null;
}

function readMovie(obj: Record<string, unknown>): Omit<ImdbTitle, "id"> {
  const trailer = obj.trailer as { embedUrl?: string; contentUrl?: string } | undefined;
  const trailerUrl = stringOrNull(trailer?.embedUrl) || stringOrNull(trailer?.contentUrl);
  const youtube = trailerUrl ? youtubeKey(trailerUrl) : null;
  const date = stringOrNull(obj.datePublished);
  const genre = obj.genre;
  const genres = Array.isArray(genre) ? genre.map((g) => String(g)) : genre ? [String(genre)] : [];
  const image = obj.image;
  const poster =
    typeof image === "string"
      ? image
      : image && typeof image === "object" && "url" in image
        ? String((image as { url?: string }).url || "")
        : "";
  return {
    title: String(obj.name || ""),
    year: date ? Number(date.slice(0, 4)) : null,
    overview: String(obj.description || "").slice(0, 2000),
    posterUrl: poster || null,
    genres,
    runtimeMin: isoMinutes(stringOrNull(obj.duration)),
    trailerUrl: youtube ? null : trailerUrl,
    trailerSite: youtube ? "youtube" : trailerUrl ? "imdb" : null,
    trailerKey: youtube,
  };
}

export function youtubeKey(url: string): string | null {
  if (!/youtu\.?be/.test(url)) return null;
  const match = url.match(/(?:youtu\.be\/|embed\/|v=)([A-Za-z0-9_-]{6,})/);
  return match?.[1] ?? null;
}

function isoMinutes(value: string | null): number | null {
  if (!value) return null;
  const match = value.match(/PT(?:(\d+)H)?(?:(\d+)M)?/);
  if (!match) return null;
  const minutes = Number(match[1] || 0) * 60 + Number(match[2] || 0);
  return minutes > 0 ? minutes : null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

export async function imdbSuggest(query: string): Promise<ImdbHit[]> {
  const url = `https://v3.sg.media-imdb.com/suggestion/x/${encodeURIComponent(query)}.json`;
  const res = await fetch(url, {
    headers: { Accept: "application/json", "User-Agent": UA },
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) return [];
  return parseImdbSuggestions(await res.json());
}

export async function imdbTitle(id: string): Promise<ImdbTitle | null> {
  if (!/^tt\d{7,8}$/.test(id)) return null;
  const res = await fetch(`https://www.imdb.com/title/${id}/`, {
    headers: { "User-Agent": UA, Accept: "text/html", "Accept-Language": "en" },
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) return null;
  return parseImdbTitlePage(await res.text(), id);
}
