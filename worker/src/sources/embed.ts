/** Does the stream site have a page for a title? Asked of the site itself, so "available" means something.
 *
 * The answer is the HTTP status of the embed page: a page that does not exist is a no, a page that answers is a yes, and
 * anything else (a timeout, a 5xx, a block) is not known and the title is still offered. Only an answer is remembered.
 */

import { edgeCache } from "../lib.ts";

export function embedVerdict(status: number | null): boolean | null {
  if (status === null) return null;
  if (status === 404 || status === 410) return false;
  // A redirect is the site routing to the page, which is an answer.
  if (status >= 200 && status < 400) return true;
  return null;
}

export async function embedStatus(url: string): Promise<number | null> {
  try {
    const res = await fetch(url, { method: "GET", headers: { "User-Agent": "Watch/1" }, redirect: "manual", signal: AbortSignal.timeout(4000) });
    void res.body?.cancel();
    return res.status;
  } catch {
    return null;
  }
}

/** `key` names the title for the remembered answer; `url` is its embed page, or null when there is nothing to ask about. */
export async function embedAvailable(
  key: string,
  url: string | null,
  probe: (url: string) => Promise<number | null> = embedStatus,
): Promise<boolean | null> {
  if (!url) return null;
  const cacheKey = new Request(`https://embed-probe.watch.internal/${key}`);
  const hit = await edgeCache().match(cacheKey);
  if (hit) {
    const text = await hit.text();
    return text === "yes" ? true : text === "no" ? false : null;
  }
  const verdict = embedVerdict(await probe(url));
  if (verdict !== null) {
    await edgeCache().put(cacheKey, new Response(verdict ? "yes" : "no", { headers: { "cache-control": "public, max-age=3600" } }));
  }
  return verdict;
}
