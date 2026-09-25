import assert from "node:assert/strict";
import test from "node:test";
import { pickTrailerId } from "../src/lib.ts";

const EN_TRAILER = { youtube_video_id: "abc", language: "en", categories: ["Trailer"], views: 100 };
const EN_CLIP = { youtube_video_id: "clip", language: "en", categories: ["Clip"], views: 999999 };
const DE_TRAILER = { youtube_video_id: "de", language: "de", categories: ["Trailer"], views: 999999 };
const EN_COMPILATION = { youtube_video_id: "comp", language: "en", categories: ["Trailer", "Clip"], views: 999999 };

test("picks the featured trailer when it is a pure trailer", () => {
  assert.equal(pickTrailerId({ trailer: EN_TRAILER, videos: [EN_CLIP] }), "abc");
});

test("skips clips, talks, compilations and non-english tracks", () => {
  assert.equal(pickTrailerId({ videos: [EN_CLIP, DE_TRAILER, EN_COMPILATION] }), null);
});

test("picks most-viewed pure trailer from the list", () => {
  const big = { ...EN_TRAILER, youtube_video_id: "big", views: 500 };
  assert.equal(pickTrailerId({ videos: [EN_TRAILER, big] }), "big");
});

test("empty payload resolves to null", () => {
  assert.equal(pickTrailerId({}), null);
});
