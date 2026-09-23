import assert from "node:assert/strict";
import test from "node:test";
import { parseImdbSuggestions, parseImdbTitlePage, youtubeKey } from "../src/imdb.ts";

test("IMDb suggestions keep feature titles and their tt ids", () => {
  const hits = parseImdbSuggestions({
    d: [
      { id: "tt0053604", l: "The Apartment", y: 1960, q: "feature", qid: "movie", i: { imageUrl: "https://img/poster.jpg" } },
      { id: "nm0000034", l: "Not a movie", y: 1920, q: "name" },
      { id: "tt0000001", l: "Short", y: 1890, qid: "short" },
    ],
  });
  assert.equal(hits.length, 1);
  assert.equal(hits[0]?.id, "tt0053604");
  assert.equal(hits[0]?.image, "https://img/poster.jpg");
});

test("IMDb title page supplies the plot, poster, and trailer", () => {
  const html = `<html><script type="application/ld+json">{
    "@type": "Movie",
    "name": "The Apartment",
    "description": "A clerk lends his apartment.",
    "datePublished": "1960-06-15",
    "genre": ["Comedy", "Drama"],
    "duration": "PT2H5M",
    "image": "https://img/wide.jpg",
    "trailer": { "@type": "VideoObject", "embedUrl": "https://www.imdb.com/video/embed/vi123" }
  }</script></html>`;
  const title = parseImdbTitlePage(html, "tt0053604");
  assert.equal(title?.title, "The Apartment");
  assert.equal(title?.year, 1960);
  assert.equal(title?.runtimeMin, 125);
  assert.equal(title?.trailerSite, "imdb");
  assert.equal(title?.trailerUrl, "https://www.imdb.com/video/embed/vi123");
  assert.deepEqual(title?.genres, ["Comedy", "Drama"]);
});

test("a YouTube trailer is stored as a key, not a page", () => {
  assert.equal(youtubeKey("https://www.youtube.com/embed/abc_def-1"), "abc_def-1");
  const html = `<script type="application/ld+json">{"@type":"Movie","name":"X","trailer":{"embedUrl":"https://www.youtube.com/embed/abc_def-1"}}</script>`;
  const title = parseImdbTitlePage(html, "tt0000002");
  assert.equal(title?.trailerSite, "youtube");
  assert.equal(title?.trailerKey, "abc_def-1");
  assert.equal(title?.trailerUrl, null);
});
