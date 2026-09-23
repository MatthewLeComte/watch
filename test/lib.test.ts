import assert from "node:assert/strict";
import test from "node:test";
import {
  jevPick,
  needsJev,
  openSubtitlesHash,
  parseByteRange,
  parseJevProbs,
  parseReleaseName,
  scoreCandidate,
  srtToVtt,
} from "../src/lib.ts";

test("scene name keeps the film year, not the resolution", () => {
  const parsed = parseReleaseName("The.Apartment.1960.1080p.BluRay.x264-GROUP.mkv");
  assert.equal(parsed.title, "The Apartment");
  assert.equal(parsed.year, 1960);
});

test("parenthetical year beats a year in the title", () => {
  const parsed = parseReleaseName("2001 A Space Odyssey (1968).mp4");
  assert.equal(parsed.year, 1968);
  assert.match(parsed.title, /2001/);
});

test("imdb id in the filename is kept", () => {
  const parsed = parseReleaseName("Breakfast.at.Tiffany's.1961.tt0054698.m4v");
  assert.equal(parsed.imdbId, "tt0054698");
  assert.equal(parsed.year, 1961);
});

test("opensubtitles hash is a 16-digit hex of size plus both ends", () => {
  const head = new Uint8Array(65536);
  const tail = new Uint8Array(65536);
  head[0] = 1;
  tail[0] = 2;
  assert.equal(openSubtitlesHash(131072, head, tail), "0000000000020003");
});

test("srt becomes webvtt and drops cue numbers", () => {
  const vtt = srtToVtt("1\n00:00:01,000 --> 00:00:04,000\nHello\n");
  assert.ok(vtt.startsWith("WEBVTT"));
  assert.match(vtt, /00:00:01\.000 --> 00:00:04\.000/);
  assert.match(vtt, /Hello/);
  assert.equal(vtt.includes("\n1\n"), false);
});

test("an exact title and year does not ask Jev", () => {
  const parsed = parseReleaseName("The Apartment (1960).mp4");
  const exact = scoreCandidate(parsed, {
    id: "a", title: "The Apartment", year: 1960, overview: "", posterUrl: null,
    imdbId: null, tmdbId: null, runtimeMin: null, genres: [], source: "wikipedia",
  });
  const other = scoreCandidate(parsed, {
    id: "b", title: "The Apartment", year: 1996, overview: "", posterUrl: null,
    imdbId: null, tmdbId: null, runtimeMin: null, genres: [], source: "wikipedia",
  });
  assert.equal(needsJev([exact, other]), false);
});

test("two close titles need one Jev call", async () => {
  assert.equal(needsJev([80, 70]), true);
  let calls = 0;
  const picked = await jevPick(
    [
      { id: "a", label: "The Apartment (1960)" },
      { id: "b", label: "Apartment for Peggy (1948)" },
    ],
    "The.Apartment.1960.mkv",
    async () => {
      calls += 1;
      return JSON.stringify({ probs: [{ id: "a", p: 0.8 }, { id: "b", p: 0.2 }] });
    },
  );
  assert.equal(calls, 1);
  assert.equal(picked?.id, "a");
  assert.ok(Math.abs((picked?.p ?? 0) - 0.8) < 0.001);
});

test("Jev rejects an id that was not offered", () => {
  const parsed = parseJevProbs('{"probs":[{"id":"nope","p":1},{"id":"a","p":0}]}', new Set(["a", "b"]));
  assert.equal(parsed, null);
});

test("byte ranges stay inside an 8 megabyte window", () => {
  const open = parseByteRange("bytes=0-", 50_000_000);
  assert.equal(open?.offset, 0);
  assert.equal(open?.length, 8 * 1024 * 1024);
  assert.equal(parseByteRange("bytes=10-19", 100)?.length, 10);
  assert.equal(parseByteRange("bytes=100-120", 100), null);
});
