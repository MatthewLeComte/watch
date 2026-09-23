/** Pure ingest helpers. No network. No second pass. */

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
  let title = kept.join(" ").replace(/\s+-\s*[A-Za-z0-9]+$/, "").trim();
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

export function normTitle(s: string): string {
  return s
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\b(the|a|an)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
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

export type Candidate = {
  id: string;
  title: string;
  year: number | null;
  overview: string;
  posterUrl: string | null;
  imdbId: string | null;
  tmdbId: string | null;
  runtimeMin: number | null;
  genres: string[];
  source: string;
};

export function scoreCandidate(parsed: ParsedName, c: Candidate): number {
  let score = 0;
  if (parsed.imdbId && c.imdbId && parsed.imdbId === c.imdbId) score += 500;
  if (c.source === "opensubtitles") score += 200;
  const a = normTitle(parsed.title);
  const b = normTitle(c.title);
  if (a && b && a === b) score += 100;
  else if (a && b && (a.includes(b) || b.includes(a))) score += 60;
  else {
    const as = new Set(a.split(" ").filter((t) => t.length > 1));
    for (const t of b.split(" ")) if (as.has(t)) score += 15;
  }
  if (parsed.year != null && c.year != null) {
    if (parsed.year === c.year) score += 40;
    else if (Math.abs(parsed.year - c.year) === 1) score += 10;
  }
  return score;
}

export function needsJev(scores: number[]): boolean {
  if (scores.length < 2) return false;
  const sorted = [...scores].sort((x, y) => y - x);
  const best = sorted[0] ?? 0;
  const second = sorted[1] ?? 0;
  if (best >= 140 && best - second >= 40) return false;
  return true;
}

export type JevOption = { id: string; label: string };

/** Parse one JSON object. Unknown or missing ids fail the whole answer. No retry. */
export function parseJevProbs(
  text: string,
  allowed: ReadonlySet<string>,
): { id: string; p: number }[] | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
  const probs = (parsed as { probs?: unknown }).probs;
  if (!Array.isArray(probs)) return null;
  const out: { id: string; p: number }[] = [];
  for (const row of probs) {
    if (!row || typeof row !== "object") return null;
    const id = String((row as { id?: unknown }).id ?? "");
    const p = Number((row as { p?: unknown }).p);
    if (!allowed.has(id) || !Number.isFinite(p) || p < 0) return null;
    out.push({ id, p });
  }
  if (new Set(out.map((r) => r.id)).size !== allowed.size || out.length !== allowed.size) return null;
  const sum = out.reduce((s, r) => s + r.p, 0);
  if (sum <= 0) return null;
  return out.map((r) => ({ id: r.id, p: r.p / sum })).sort((a, b) => b.p - a.p);
}

/** One completion. Fixed ids only. Returns null if the model is unusable. */
export async function jevPick(
  options: JevOption[],
  context: string,
  complete: (prompt: string) => Promise<string>,
): Promise<{ id: string; p: number } | null> {
  if (options.length < 2) return null;
  const allowed = new Set(options.map((o) => o.id));
  const lines = options.map((o) => `- id: ${o.id}\n  label: ${o.label}`).join("\n");
  const prompt = [
    "Pick the movie this file is.",
    "Reply with JSON only, no markdown.",
    'Schema: {"probs":[{"id":"<one of the ids>","p":<number>}]}',
    "Every id below must appear exactly once. Probabilities are numbers that sum to 1.",
    "Do not invent ids. Do not ask questions.",
    `File: ${context}`,
    "Options:",
    lines,
  ].join("\n");
  const text = await complete(prompt);
  const probs = parseJevProbs(text, allowed);
  return probs?.[0] ?? null;
}

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
    const length = Math.min(suffix, size, MAX_RANGE);
    return { offset: Math.max(0, size - length), length };
  }
  const offset = Number(startRaw);
  if (!Number.isFinite(offset) || offset < 0 || offset >= size) return null;
  const end = endRaw === "" ? Math.min(size - 1, offset + MAX_RANGE - 1) : Number(endRaw);
  if (!Number.isFinite(end) || end < offset) return null;
  const length = Math.min(end, size - 1) - offset + 1;
  if (length <= 0) return null;
  return { offset, length: Math.min(length, MAX_RANGE) };
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
