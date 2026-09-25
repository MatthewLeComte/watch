/** Pure ingest helpers. No network. No second pass. */

export type TrailerVideo = {
  youtube_video_id?: string;
  language?: string;
  categories?: string[];
  views?: number;
};

/** Best English pure-trailer YouTube id: featured trailer, else most-viewed. */
export function pickTrailerId(payload: { trailer?: TrailerVideo; videos?: TrailerVideo[] }): string | null {
  const cands = [...(payload.trailer ? [payload.trailer] : []), ...(payload.videos ?? [])];
  let best: string | null = null;
  let bestViews = -1;
  for (const v of cands) {
    const yt = v.youtube_video_id;
    if (!yt || typeof yt !== "string") continue;
    if (v.language && v.language !== "en") continue;
    const cats = v.categories ?? [];
    if (!cats.includes("Trailer")) continue;
    if (cats.includes("Clip") || cats.includes("Talk") || cats.includes("Special")) continue;
    const views = typeof v.views === "number" ? v.views : 0;
    if (views > bestViews) {
      bestViews = views;
      best = yt;
    }
  }
  return best;
}

export const MAX_RANGE = 8 * 1024 * 1024;
const CHUNK = 65536;

const TAGS = new Set([
  "1080p", "720p", "2160p", "480p", "576p", "540p", "4k", "8k",
  "bluray", "blu-ray", "bdrip", "brrip", "webrip", "web-dl", "webdl", "hdtv",
  "dvdrip", "dvdscr", "hdrip", "x264", "x265", "h264", "h265", "hevc", "avc",
  "aac", "ac3", "dts", "truehd", "atmos", "hdr", "sdr", "hdr10", "dv",
  "10bit", "8bit", "remux", "proper", "repack", "extended", "unrated",
  "theatrical", "limited", "internal", "festival", "yify", "rarbg", "etrg", "eztv",
  "amzn", "nf", "dsnp",
]);

const SMALL = new Set(["a", "an", "the", "of", "and", "or", "in", "on", "at", "to", "for"]);

export type ParsedName = { title: string; year: number | null; imdbId: string | null };

export function parseReleaseName(filename: string): ParsedName {
  const base = filename.split(/[/\\]/).pop() ?? filename;
  const noExt = base.replace(/\.[a-z0-9]{2,4}$/i, "");
  const imdb = noExt.match(/tt\d{7,8}/i)?.[0]?.toLowerCase() ?? null;
  let year: number | null = null;
  let work = noExt;
  const paren = work.match(/\(((?:18|19|20)\d{2})\)/);
  if (paren) {
    year = Number(paren[1]);
    work = work.replace(paren[0], " ");
  }
  work = work.replace(/[._]+/g, " ").replace(/\s+/g, " ").trim();
  let tokens = work.split(" ").filter(Boolean);
  if (year == null) {
    const years: { index: number; year: number }[] = [];
    tokens.forEach((t, i) => {
      if (/^(18|19|20)\d{2}$/.test(t)) {
        const y = Number(t);
        if (y >= 1888 && y <= 2035) years.push({ index: i, year: y });
      }
    });
    const pick = years[years.length - 1];
    if (pick) {
      year = pick.year;
      tokens.splice(pick.index, 1);
    }
  }
  const kept: string[] = [];
  for (const raw of tokens) {
    const t = raw.toLowerCase().replace(/[()[\]]/g, "");
    if (TAGS.has(t) || /^\d{3,4}p$/.test(t)) break;
    if (imdb && t === imdb) continue;
    kept.push(raw);
  }
  // Strip release-group suffix only when it's an all-caps token (YIFY, GROUP, ETRG…).
  // A bare \s+-\s*[A-Za-z0-9]+$ would also eat " - World" from "Captain America - Brave New World".
  let title = kept.join(" ").replace(/\s+-\s*[A-Z][A-Z0-9]{1,}$/, "").trim();
  if (isAllCaps(title)) title = titleCase(title);
  if (!title) title = noExt;
  return { title, year, imdbId: imdb };
}

function isAllCaps(s: string): boolean {
  const letters = s.replace(/[^A-Za-z]/g, "");
  return letters.length > 0 && letters === letters.toUpperCase();
}

function titleCase(s: string): string {
  return s
    .toLowerCase()
    .split(" ")
    .filter(Boolean)
    .map((w, i) => (i > 0 && SMALL.has(w) ? w : w.charAt(0).toUpperCase() + w.slice(1)))
    .join(" ");
}

export function openSubtitlesHash(size: number, head: Uint8Array, tail: Uint8Array): string {
  if (head.byteLength < CHUNK || tail.byteLength < CHUNK) throw new Error("short");
  const mask = (1n << 64n) - 1n;
  let hash = BigInt(size) & mask;
  const add = (buf: Uint8Array) => {
    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    for (let i = 0; i < CHUNK; i += 8) {
      const low = BigInt(view.getUint32(i, true));
      const high = BigInt(view.getUint32(i + 4, true));
      hash = (hash + ((high << 32n) | low)) & mask;
    }
  };
  add(head);
  add(tail);
  return hash.toString(16).padStart(16, "0");
}

export function srtToVtt(srt: string): string {
  const text = srt.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  const blocks = text.split(/\n{2,}/);
  const cues: string[] = [];
  for (const block of blocks) {
    const lines = block.split("\n");
    const timeIdx = lines.findIndex((l) => l.includes("-->"));
    if (timeIdx < 0) continue;
    const time = lines[timeIdx].replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, "$1.$2");
    const body = lines.slice(timeIdx + 1).join("\n").trim();
    if (!body) continue;
    cues.push(`${time}\n${body}`);
  }
  return `WEBVTT\n\n${cues.join("\n\n")}\n`;
}

/// Parse a single HTTP Range header into an exact { offset, length }.
/// Explicit ranges are honored byte-for-byte: AVFoundation asks for the whole
/// remainder up front and stalls forever if a 206 comes back shorter than
/// asked (the old 8MB cap broke every native stream). Only the headerless
/// default is bounded, and no caller serves that path to a player.
export function parseByteRange(
  header: string | null,
  size: number,
): { offset: number; length: number } | null {
  if (!header) return { offset: 0, length: Math.min(MAX_RANGE, size) };
  const m = header.match(/bytes=(\d*)-(\d*)/);
  if (!m) return null;
  const startRaw = m[1] ?? "";
  const endRaw = m[2] ?? "";
  if (startRaw === "" && endRaw === "") return null;
  if (startRaw === "") {
    const suffix = Number(endRaw);
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    const length = Math.min(suffix, size);
    return { offset: Math.max(0, size - length), length };
  }
  const offset = Number(startRaw);
  if (!Number.isFinite(offset) || offset < 0 || offset >= size) return null;
  const end = endRaw === "" ? size - 1 : Number(endRaw);
  if (!Number.isFinite(end) || end < offset) return null;
  const length = Math.min(end, size - 1) - offset + 1;
  if (length <= 0) return null;
  return { offset, length };
}

export function extOf(filename: string): string | null {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";
  if (ext === "mp4" || ext === "m4v" || ext === "mov") return ext;
  return null;
}

export function contentTypeFor(ext: string): string {
  if (ext === "mov") return "video/quicktime";
  if (ext === "m4v") return "video/x-m4v";
  return "video/mp4";
}
