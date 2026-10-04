import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { rewritePlaylist, pickSaveVariant, parseMasterVariants, parseMediaSegments, parseAudioRenditions, pickAudio, SAVE_BUDGET_BYTES } from "../src/relay.ts";

const ORIGIN = "https://watch.cornerstonecoatings.com";
const REF = "https://www.rivestream.app/embed?type=movie&id=533535";

describe("rewritePlaylist", () => {
  it("rewrites variant URIs to /v1/relay/pl and keeps structure", () => {
    const master = [
      "#EXTM3U",
      "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080",
      "1080/index.m3u8?token=abc",
      "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720",
      "https://cdn.example.com/720/index.m3u8?token=abc",
      "",
    ].join("\n");
    const out = rewritePlaylist(master, "https://cdn.example.com/master.m3u8?token=abc", ORIGIN, REF);
    assert.ok(out?.includes("#EXTM3U"));
    assert.ok(out?.includes("/v1/relay/pl?u=https%3A%2F%2Fcdn.example.com%2F1080%2Findex.m3u8%3Ftoken%3Dabc"));
    assert.ok(out?.includes("/v1/relay/pl?u=https%3A%2F%2Fcdn.example.com%2F720%2Findex.m3u8%3Ftoken%3Dabc"));
    assert.ok(out?.includes(`ref=${encodeURIComponent(REF)}`));
  });

  it("rewrites segments to /v1/relay/seg and proxies key URIs", () => {
    const media = [
      "#EXTM3U",
      "#EXT-X-KEY:METHOD=AES-128,URI=\"keys/k.key?token=abc\"",
      "#EXTINF:6.0,",
      "seg0.ts?token=abc",
      "#EXTINF:6.0,",
      "seg1.ts?token=abc",
      "#EXT-X-ENDLIST",
      "",
    ].join("\n");
    const out = rewritePlaylist(media, "https://cdn.example.com/v/720/index.m3u8?token=abc", ORIGIN, REF);
    assert.ok(out?.includes('/v1/relay/seg?u=https%3A%2F%2Fcdn.example.com%2Fv%2F720%2Fseg0.ts%3Ftoken%3Dabc'));
    assert.ok(out?.includes('URI="https://watch.cornerstonecoatings.com/v1/relay/seg?u=https%3A%2F%2Fcdn.example.com%2Fv%2F720%2Fkeys%2Fk.key%3Ftoken%3Dabc'));
    assert.ok(out?.includes("#EXT-X-ENDLIST"));
  });

  it("rejects non-playlists and blocks localhost", () => {
    assert.equal(rewritePlaylist("<html>nope</html>", "https://cdn.example.com/a.m3u8", ORIGIN, REF), null);
    const out = rewritePlaylist("#EXTM3U\nseg0.ts\n", "https://cdn.example.com/a/index.m3u8", ORIGIN, REF);
    assert.ok(!out?.includes("localhost"));
  });
});

describe("pickSaveVariant", () => {
  const V = (height: number, mbps: number, uri = "v.m3u8") => ({ height, bandwidth: mbps * 1_000_000, uri });
  const RUNTIME_2H = 7200;

  it("picks sane 1080p over 4K and bloated 1080p", () => {
    const vs = [V(2160, 18), V(1080, 12), V(1080, 4.5), V(720, 3)];
    // 4K: 16GB, 1080p12: 10.8GB over, 1080p4.5: 4.05GB in 4GiB budget, 720p3: 2.7GB
    assert.equal(pickSaveVariant(vs, RUNTIME_2H), 2);
  });

  it("prefers 1080p inside budget", () => {
    const vs = [V(2160, 18), V(1080, 4), V(720, 3)];
    // 1080p4: 3.6GB in budget
    assert.equal(pickSaveVariant(vs, RUNTIME_2H), 1);
  });

  it("falls back to lowest-bandwidth 1080p without runtime", () => {
    const vs = [V(1080, 12), V(1080, 8), V(720, 3)];
    assert.equal(pickSaveVariant(vs, null), 1);
  });

  it("excludes audio-only and 4K-only pools", () => {
    assert.equal(pickSaveVariant([{ height: 0, bandwidth: 128000, uri: "a.m3u8" }], RUNTIME_2H), -1);
    assert.equal(pickSaveVariant([], RUNTIME_2H), -1);
  });

  it("budget constant is 4GB", () => {
    assert.equal(SAVE_BUDGET_BYTES, 4 * 1024 * 1024 * 1024);
  });
});

describe("playlist parsing", () => {
  it("parseMasterVariants reads heights and bandwidths", () => {
    const vs = parseMasterVariants("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nb.m3u8\n");
    assert.deepEqual(vs, [{ height: 1080, bandwidth: 5000000, uri: "b.m3u8" }]);
  });

  it("parseMediaSegments resolves relative URIs with durations", () => {
    const segs = parseMediaSegments("#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXTINF:4.5,\nseg1.ts\n", "https://c.example.com/v/");
    assert.deepEqual(segs, [
      { u: "https://c.example.com/v/seg0.ts", d: 6 },
      { u: "https://c.example.com/v/seg1.ts", d: 4.5 },
    ]);
  });
});

describe("separate audio streams", () => {
  const master = [
    "#EXTM3U",
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",LANGUAGE="es",DEFAULT=YES,URI="es/index.m3u8"',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="en/index.m3u8"',
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",URI="subs.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,AUDIO="aud"',
    "720/index.m3u8",
    "",
  ].join("\n");

  it("reads the audio group off the variant and lists only audio renditions", () => {
    assert.equal(parseMasterVariants(master)[0]!.audio, "aud");
    const audio = parseAudioRenditions(master);
    assert.equal(audio.length, 2);
    assert.deepEqual(audio.map((a) => a.lang), ["es", "en"]);
  });

  it("prefers English over the default track", () => {
    const pick = pickAudio(parseAudioRenditions(master), "aud");
    assert.equal(pick?.uri, "en/index.m3u8");
  });

  it("falls back to the default, then the first, and returns null with none", () => {
    const only = parseAudioRenditions(master.replace('LANGUAGE="en"', 'LANGUAGE="fr"'));
    assert.equal(pickAudio(only, "aud")?.uri, "es/index.m3u8");
    assert.equal(pickAudio([], undefined), null);
  });

  it("leaves a variant with muxed sound without an audio group", () => {
    const muxed = ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720", "720/index.m3u8", ""].join("\n");
    assert.equal(parseMasterVariants(muxed)[0]!.audio, undefined);
    assert.equal(parseAudioRenditions(muxed).length, 0);
  });
});
