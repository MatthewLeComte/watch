// The save pipeline must not lose a segment quietly, and the stream site's answer must be what "available" means.
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { recount, storeSegment } from "../src/relay.ts";
import { embedAvailable, embedVerdict } from "../src/sources/embed.ts";

type Put = { key: string; size: number; type: string | undefined };

function bucket(listing: { key: string; size: number }[] = []) {
  const puts: Put[] = [];
  return {
    puts,
    head: async () => null,
    put: async (key: string, body: Uint8Array, options?: { httpMetadata?: { contentType?: string } }) => {
      puts.push({ key, size: body.length, type: options?.httpMetadata?.contentType });
    },
    list: async (options: { cursor?: string }) =>
      options.cursor
        ? { objects: listing.slice(2).map((o) => ({ ...o })), truncated: false }
        : { objects: listing.slice(0, 2).map((o) => ({ ...o })), truncated: listing.length > 2, cursor: "next" },
  };
}

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

const instant = async () => {};
const answers = (...list: Array<Response | Error>) => {
  let calls = 0;
  globalThis.fetch = (async () => {
    const next = list[Math.min(calls++, list.length - 1)]!;
    if (next instanceof Error) throw next;
    return next.clone();
  }) as typeof fetch;
  return () => calls;
};
const body = () => new Response(new Uint8Array([0x47, 1, 2, 3]));

describe("storeSegment", () => {
  it("keeps trying through resets, timeouts and 5xx, and stores the segment", async () => {
    const calls = answers(new Error("reset"), new Response("busy", { status: 503 }), new Response(null, { status: 200 }), body());
    const r2 = bucket();
    const result = await storeSegment({ watch_bucket: r2 } as never, "https://x.test/s0.ts", null, "hls/j/720p/seg000000.ts", "video/mp2t", instant);
    assert.equal(result, "ok");
    assert.equal(calls(), 4);
    assert.deepEqual(r2.puts, [{ key: "hls/j/720p/seg000000.ts", size: 4, type: "video/mp2t" }]);
  });

  it("does not retry a segment the origin says does not exist", async () => {
    const calls = answers(new Response("nope", { status: 404 }));
    const result = await storeSegment({ watch_bucket: bucket() } as never, "https://x.test/s0.ts", null, "k", "video/mp2t", instant);
    assert.equal(result, "gone");
    assert.equal(calls(), 1);
  });

  it("reports a segment that never came as retry, after every attempt", async () => {
    const calls = answers(new Response("busy", { status: 503 }));
    const r2 = bucket();
    const result = await storeSegment({ watch_bucket: r2 } as never, "https://x.test/s0.ts", null, "k", "video/mp2t", instant);
    assert.equal(result, "retry");
    assert.equal(calls(), 4);
    assert.equal(r2.puts.length, 0);
  });

  it("treats a 403 as something that can pass, not as gone", async () => {
    answers(new Response("slow down", { status: 403 }), body());
    const result = await storeSegment({ watch_bucket: bucket() } as never, "https://x.test/s0.ts", null, "k", "video/mp2t", instant);
    assert.equal(result, "ok");
  });
});

describe("recount", () => {
  it("counts the segments that are really stored, video and audio, across pages, and nothing else", async () => {
    const listing = [
      { key: "hls/j/audio/index.m3u8", size: 100 },
      { key: "hls/j/720p/seg000000.ts", size: 1000 },
      { key: "hls/j/720p/seg000001.ts", size: 2000 },
      { key: "hls/j/audio/a000000.ts", size: 300 },
      { key: "hls/j/720p/index.m3u8", size: 50 },
    ];
    const updates: unknown[][] = [];
    const env = {
      watch_bucket: bucket(listing),
      watch: { prepare: (sql: string) => ({ bind: (...args: unknown[]) => ({ run: async () => { updates.push([sql.includes("MAX(done"), ...args]); } }) }) },
    };
    const counted = await recount(env as never, "j");
    assert.deepEqual(counted, { done: 3, bytes: 3300 });
    assert.equal(updates.length, 1);
    assert.equal(updates[0]![0], true, "the count only ever goes up, so a late writer cannot shrink it");
    assert.deepEqual(updates[0]!.slice(1, 3), [3, 3300]);
    assert.equal(updates[0]![4], "j");
  });
});

describe("what available means", () => {
  it("a page that does not exist is no, a page that answers is yes, and anything else is not known", () => {
    assert.equal(embedVerdict(404), false);
    assert.equal(embedVerdict(410), false);
    assert.equal(embedVerdict(200), true);
    assert.equal(embedVerdict(302), true);
    assert.equal(embedVerdict(500), null);
    assert.equal(embedVerdict(429), null);
    assert.equal(embedVerdict(null), null);
  });

  describe("embedAvailable", () => {
    const store = new Map<string, string>();
    beforeEach(() => {
      store.clear();
      (globalThis as unknown as { caches: unknown }).caches = {
        default: {
          match: async (request: Request) => (store.has(request.url) ? new Response(store.get(request.url)!) : undefined),
          put: async (request: Request, response: Response) => { store.set(request.url, await response.text()); },
        },
      };
    });

    it("asks the site once per title, and remembers only an answer", async () => {
      const asked: string[] = [];
      const missing = async (url: string) => { asked.push(url); return 404; };
      assert.equal(await embedAvailable("movie/603", "https://site.test/embed?type=movie&id=603", missing), false);
      assert.equal(await embedAvailable("movie/603", "https://site.test/embed?type=movie&id=603", missing), false);
      assert.deepEqual(asked, ["https://site.test/embed?type=movie&id=603"], "the second answer came from memory");

      let down = true;
      const flaky = async (url: string) => { asked.push(url); return down ? null : 200; };
      assert.equal(await embedAvailable("series/60625", "https://site.test/embed?type=tv&id=60625", flaky), null, "a site that did not answer is not remembered as a no");
      down = false;
      assert.equal(await embedAvailable("series/60625", "https://site.test/embed?type=tv&id=60625", flaky), true);
    });

    it("has no answer for a title with no page to ask about", async () => {
      assert.equal(await embedAvailable("movie/0", null), null);
    });
  });
});
