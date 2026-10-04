/** Gate for the library: a title is only added once it finished and passed these checks.
 * Pure functions, no I/O, so the rules are unit-tested and shared by upload and relay save.
 */

/** Smaller than this is a stub or a failed transfer, never a movie or an episode. */
export const MIN_VIDEO_BYTES = 5 * 1024 * 1024;
/** A saved stream shorter than this is a clip or an ad, not a title. */
export const MIN_STREAM_SEC = 60;

export type Check = { ok: true; note: string } | { ok: false; reason: string };

const ascii = (b: Uint8Array, at: number, len: number) =>
  String.fromCharCode(...b.slice(at, at + len));

/** True when the first bytes look like the container the extension claims. Unknown extensions pass. */
export function sniffContainer(ext: string, head: Uint8Array): boolean {
  if (head.length < 12) return false;
  switch (ext) {
    case "mp4":
    case "m4v":
    case "mov":
    case "3gp":
    case "3g2":
      return ["ftyp", "moov", "mdat", "wide", "free", "skip"].includes(ascii(head, 4, 4));
    case "mkv":
    case "webm":
      return head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3;
    case "avi":
      return ascii(head, 0, 4) === "RIFF" && ascii(head, 8, 4) === "AVI ";
    case "flv":
      return ascii(head, 0, 3) === "FLV";
    case "wmv":
      return head[0] === 0x30 && head[1] === 0x26 && head[2] === 0xb2 && head[3] === 0x75;
    case "ogv":
      return ascii(head, 0, 4) === "OggS";
    default:
      return true;
  }
}

/** A finished multipart upload must be the size the client declared and look like its container. */
export function checkUpload(input: { ext: string; declared: number; actual: number; head: Uint8Array }): Check {
  const { ext, declared, actual, head } = input;
  if (actual !== declared) return { ok: false, reason: `size_mismatch: stored ${actual}, declared ${declared}` };
  if (actual < MIN_VIDEO_BYTES) return { ok: false, reason: `too_small: ${actual} bytes` };
  if (!sniffContainer(ext, head)) return { ok: false, reason: `not_a_${ext}_file` };
  return { ok: true, note: `${actual} bytes, ${ext} header ok` };
}

/** MPEG-TS packets are 188 bytes and each starts with 0x47. Disguised or empty segments fail this. */
export function isTsSegment(buf: Uint8Array): boolean {
  if (buf.length < 189) return false;
  return buf[0] === 0x47 && buf[188] === 0x47;
}

export function fmtDuration(sec: number): string {
  const m = Math.round(sec / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m` : `${m}m`;
}

/**
 * Compare the stream length (sum of #EXTINF) to the runtime TMDB lists. A truncated, trailer-only
 * or wrong-title stream lands well outside the band. Episodes get a wider band because TMDB only
 * gives a typical episode length. Unknown runtime skips the comparison but is still logged.
 */
export function checkSavedStream(input: {
  mediaType: string;
  total: number;
  done: number;
  bytes: number;
  /** The variant's advertised bits per second; 0 when unknown. */
  bandwidth: number;
  durationSec: number;
  expectedSec: number | null;
  firstSegment: Uint8Array | null;
  lastSegment: Uint8Array | null;
}): Check {
  const { mediaType, total, done, bytes, durationSec, expectedSec } = input;
  if (total < 1 || done !== total) return { ok: false, reason: `incomplete: ${done}/${total} segments` };
  if (bytes < MIN_VIDEO_BYTES) return { ok: false, reason: `too_small: ${bytes} bytes` };
  if (durationSec < MIN_STREAM_SEC) return { ok: false, reason: `too_short: ${fmtDuration(durationSec)}` };
  // What came down must be about what the playlist promised: length x bitrate. Peak bandwidth
  // overstates the average, so only a quarter of it is required; a truncated save falls far below.
  if (input.bandwidth > 0 && bytes < 0.25 * (input.bandwidth / 8) * durationSec) {
    return { ok: false, reason: `too_small_for_stream: ${Math.round(bytes / 1e6)} MB for ${fmtDuration(durationSec)}` };
  }
  for (const [name, seg] of [["first", input.firstSegment], ["last", input.lastSegment]] as const) {
    if (!seg || !isTsSegment(seg)) return { ok: false, reason: `${name}_segment_not_video` };
  }
  if (!expectedSec) return { ok: true, note: `stream ${fmtDuration(durationSec)}, runtime unknown` };
  const ratio = durationSec / expectedSec;
  const [lo, hi] = mediaType === "tv" ? [0.6, 1.5] : [0.85, 1.3];
  const note = `stream ${fmtDuration(durationSec)} of ${fmtDuration(expectedSec)} expected (${Math.round(ratio * 100)}%)`;
  if (ratio < lo || ratio > hi) return { ok: false, reason: `length_mismatch: ${note}` };
  return { ok: true, note };
}
