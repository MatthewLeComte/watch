import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { embedTemplate, fill } from "../src/sources/embeds.ts";

describe("the stream page URLs", () => {
  it("the defaults are the pages the embed docs document, character for character", () => {
    const docs = readFileSync(new URL("../RIVESTREAM_EMBED_DOCS.md", import.meta.url), "utf8");
    const movie = embedTemplate({}, "movie").replace("${id}", "{tmdbId}");
    const tv = embedTemplate({}, "tv").replace("${id}", "{tmdbId}").replace("${season}", "{season}").replace("${episode}", "{episode}");
    assert.ok(docs.includes(movie), movie);
    assert.ok(docs.includes(tv), tv);
  });

  it("fills ${id}, ${season} and ${episode}, and leaves the ones not given", () => {
    const tv = embedTemplate({}, "tv");
    assert.equal(fill(tv, { id: 60625, season: 1, episode: 2 }), "https://www.rivestream.app/embed?type=tv&id=60625&season=1&episode=2");
    assert.equal(fill(tv, { id: 60625 }), "https://www.rivestream.app/embed?type=tv&id=60625&season=${season}&episode=${episode}");
    assert.equal(fill(embedTemplate({}, "movie"), { id: 603 }), "https://www.rivestream.app/embed?type=movie&id=603");
  });

  it("is the configured value for its kind, or the default when unset or not a usable https page", () => {
    const configured = "https://mirror.test/watch/${id}";
    assert.equal(embedTemplate({ WATCH_EMBED_MOVIE: configured }, "movie"), configured);
    assert.equal(embedTemplate({ WATCH_EMBED_MOVIE: configured }, "tv").includes("mirror.test"), false);
    for (const unusable of [undefined, "", "http://plain.test/${id}", "https://no-variable.test/page"]) {
      assert.match(embedTemplate({ WATCH_EMBED_MOVIE: unusable }, "movie"), /^https:\/\/www\.rivestream\.app\/embed\?type=movie&id=\$\{id\}$/);
    }
  });
});
