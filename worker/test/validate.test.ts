import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { checkSavedStream, checkUpload, isTsSegment, sniffContainer, MIN_VIDEO_BYTES } from "../src/validate.ts";

const bytes = (...v: number[]) => Uint8Array.from(v);
const mp4Head = Uint8Array.from([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d]);
const ts = (() => {
  const b = new Uint8Array(376);
  b[0] = 0x47;
  b[188] = 0x47;
  return b;
})();
const MB = 1024 * 1024;

describe("sniffContainer", () => {
  it("accepts an mp4 ftyp box and rejects zero fill", () => {
    assert.equal(sniffContainer("mp4", mp4Head), true);
    assert.equal(sniffContainer("mp4", new Uint8Array(16)), false);
  });
  it("accepts matroska EBML and rejects an mp4 header under .mkv", () => {
    assert.equal(sniffContainer("mkv", bytes(0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0)), true);
    assert.equal(sniffContainer("mkv", mp4Head), false);
  });
  it("rejects a header shorter than 12 bytes and passes unknown extensions", () => {
    assert.equal(sniffContainer("mp4", bytes(1, 2, 3)), false);
    assert.equal(sniffContainer("ts", new Uint8Array(16)), true);
  });
});

describe("checkUpload", () => {
  const ok = { ext: "mp4", declared: 100 * MB, actual: 100 * MB, head: mp4Head };
  it("passes a full-size file with a real header", () => assert.equal(checkUpload(ok).ok, true));
  it("fails when the stored size differs from the declared size", () => {
    const r = checkUpload({ ...ok, actual: 99 * MB });
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.reason, /size_mismatch/);
  });
  it("fails a stub under the minimum even when the header is fine", () => {
    const r = checkUpload({ ...ok, declared: MIN_VIDEO_BYTES - 1, actual: MIN_VIDEO_BYTES - 1 });
    assert.match(r.ok ? "" : r.reason, /too_small/);
  });
  it("fails padded data that is not the claimed container", () => {
    const r = checkUpload({ ...ok, declared: 10 * MB, actual: 10 * MB, head: new Uint8Array(16) });
    assert.match(r.ok ? "" : r.reason, /not_a_mp4_file/);
  });
});

describe("isTsSegment", () => {
  it("needs sync bytes at 0 and 188", () => {
    assert.equal(isTsSegment(ts), true);
    assert.equal(isTsSegment(new Uint8Array(376)), false);
    assert.equal(isTsSegment(ts.slice(0, 100)), false);
  });
});

describe("checkSavedStream", () => {
  const base = {
    mediaType: "movie",
    total: 1200,
    done: 1200,
    bytes: 900 * MB,
    durationSec: 7200,
    expectedSec: 7260,
    firstSegment: ts,
    lastSegment: ts,
  };
  it("passes a stream within the movie band and logs both lengths", () => {
    const r = checkSavedStream(base);
    assert.equal(r.ok, true);
    assert.match(r.ok ? r.note : "", /stream 2h00m of 2h01m expected \(99%\)/);
  });
  it("fails a truncated stream", () => {
    const r = checkSavedStream({ ...base, durationSec: 3000 });
    assert.match(r.ok ? "" : r.reason, /length_mismatch/);
  });
  it("fails a stream far longer than the runtime", () => {
    assert.equal(checkSavedStream({ ...base, durationSec: 12000 }).ok, false);
  });
  it("uses a wider band for episodes", () => {
    const tv = { ...base, mediaType: "tv", durationSec: 1500, expectedSec: 2400, bytes: 200 * MB, total: 250, done: 250 };
    assert.equal(checkSavedStream(tv).ok, true);
    assert.equal(checkSavedStream({ ...tv, durationSec: 1000 }).ok, false);
  });
  it("skips the comparison when TMDB has no runtime but still enforces the floor", () => {
    assert.equal(checkSavedStream({ ...base, expectedSec: null }).ok, true);
    assert.match(
      (() => {
        const r = checkSavedStream({ ...base, expectedSec: null, durationSec: 30 });
        return r.ok ? "" : r.reason;
      })(),
      /too_short/,
    );
  });
  it("fails incomplete saves, tiny byte counts and non-video segments", () => {
    assert.match((checkSavedStream({ ...base, done: 1199 }) as { reason: string }).reason, /incomplete/);
    assert.match((checkSavedStream({ ...base, bytes: 1000 }) as { reason: string }).reason, /too_small/);
    assert.match((checkSavedStream({ ...base, firstSegment: new Uint8Array(376) }) as { reason: string }).reason, /first_segment/);
    assert.match((checkSavedStream({ ...base, lastSegment: null }) as { reason: string }).reason, /last_segment/);
  });
});
