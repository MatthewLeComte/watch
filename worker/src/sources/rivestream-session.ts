/**
 * RiveStream Session Persistence
 * Stores cookies, localStorage, and session data in KV per tmdbId.
 * Enables session reuse across resolves to bypass auth/token expiry.
 */

import type { KVNamespace } from "@cloudflare/workers-types";
import type { Page } from "@cloudflare/puppeteer";

export interface RiveStreamSession {
  tmdbId: number;
  mediaType: "movie" | "tv";
  cookies: CookieData[];
  localStorage: Record<string, string>;
  userAgent: string;
  proxy?: string;
  createdAt: number;
  lastUsed: number;
  useCount: number;
}

export interface CookieData {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number; // Unix timestamp (seconds), 0 = session
  httpOnly: boolean;
  secure: boolean;
  sameSite: "Strict" | "Lax" | "None";
}

const SESSION_TTL_DAYS = 7;
const SESSION_TTL_SECONDS = SESSION_TTL_DAYS * 24 * 60 * 60;
const MAX_USE_COUNT = 50; // Rotate session after N uses

export function sessionKey(tmdbId: number, mediaType: "movie" | "tv"): string {
  return `rivestream:${mediaType}:${tmdbId}`;
}

export async function getSession(
  kv: KVNamespace,
  tmdbId: number,
  mediaType: "movie" | "tv"
): Promise<RiveStreamSession | null> {
  const key = sessionKey(tmdbId, mediaType);
  const data = await kv.get(key, { type: "json" }) as RiveStreamSession | null;
  if (!data) return null;

  // Check expiry
  const now = Math.floor(Date.now() / 1000);
  if (data.createdAt + SESSION_TTL_SECONDS < now) {
    await kv.delete(key);
    return null;
  }

  // Check use count
  if (data.useCount >= MAX_USE_COUNT) {
    await kv.delete(key);
    return null;
  }

  return data;
}

export async function saveSession(
  kv: KVNamespace,
  session: RiveStreamSession
): Promise<void> {
  const key = sessionKey(session.tmdbId, session.mediaType);
  session.lastUsed = Math.floor(Date.now() / 1000);
  session.useCount += 1;
  await kv.put(key, JSON.stringify(session), { expirationTtl: SESSION_TTL_SECONDS });
}

export async function deleteSession(
  kv: KVNamespace,
  tmdbId: number,
  mediaType: "movie" | "tv"
): Promise<void> {
  const key = sessionKey(tmdbId, mediaType);
  await kv.delete(key);
}

/**
 * Convert Puppeteer cookies to our format
 */
export function puppeteerCookiesToSession(cookies: any[]): CookieData[] {
  return cookies.map((c) => ({
    name: c.name,
    value: c.value,
    domain: c.domain,
    path: c.path,
    expires: c.expires ?? 0,
    httpOnly: c.httpOnly ?? false,
    secure: c.secure ?? false,
    sameSite: c.sameSite ?? "Lax",
  }));
}

/**
 * Apply session cookies to a Puppeteer page
 */
export async function applySessionToPage(page: Page, session: RiveStreamSession): Promise<void> {
  // Set cookies
  if (session.cookies.length > 0) {
    await page.setCookie(...session.cookies.map((c) => ({
      name: c.name,
      value: c.value,
      domain: c.domain,
      path: c.path,
      expires: c.expires,
      httpOnly: c.httpOnly,
      secure: c.secure,
      sameSite: c.sameSite,
    })));
  }

  // Set localStorage
  if (Object.keys(session.localStorage).length > 0) {
    await page.evaluateOnNewDocument((storage: Record<string, string>) => {
      for (const [key, value] of Object.entries(storage)) {
        try {
          localStorage.setItem(key, value);
        } catch {}
      }
    }, session.localStorage);
  }
}

/**
 * Extract session data from a page after interaction
 */
export async function extractSessionFromPage(page: Page, tmdbId: number, mediaType: "movie" | "tv"): Promise<RiveStreamSession> {
  const cookies = await page.cookies();
  let localStorage: Record<string, string> = {};
  try {
    localStorage = await page.evaluate(() => {
      const data: Record<string, string> = {};
      const ls = window.localStorage;
      for (let i = 0; i < ls.length; i++) {
        const key = ls.key(i);
        if (key) data[key] = ls.getItem(key) || "";
      }
      return data;
    });
  } catch (e) {
    console.log(JSON.stringify({ event: "rivestream_localstorage_error", error: String(e) }));
  }
  const userAgent = await page.evaluate(() => navigator.userAgent);

  return {
    tmdbId,
    mediaType,
    cookies: puppeteerCookiesToSession(cookies),
    localStorage,
    userAgent,
    createdAt: Math.floor(Date.now() / 1000),
    lastUsed: Math.floor(Date.now() / 1000),
    useCount: 0,
  };
}

/**
 * Format cookies for Roku Video node HttpHeaders
 * Returns "Cookie: name1=value1; name2=value2" header value
 */
export function formatCookiesForPlayback(session: RiveStreamSession): string {
  return session.cookies
    .filter((c) => c.expires === 0 || c.expires > Math.floor(Date.now() / 1000))
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
}