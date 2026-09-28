/**
 * StealthBrowser: Hardened Puppeteer wrapper for RiveStream.
 * Uses puppeteer-extra with stealth + anonymize-ua plugins.
 * Implements human-like interaction patterns.
 */

import puppeteer from "@cloudflare/puppeteer";
import puppeteerExtra from "puppeteer-extra";
import StealthPlugin from "puppeteer-extra-plugin-stealth";
import AnonymizeUaPlugin from "puppeteer-extra-plugin-anonymize-ua";
import type { Browser, Page } from "@cloudflare/puppeteer";

interface PuppeteerLaunchOptions {
  headless?: boolean;
  args?: string[];
  [key: string]: any;
}

// Initialize plugins once
puppeteerExtra.use(StealthPlugin());
puppeteerExtra.use(AnonymizeUaPlugin());

export interface StealthBrowserConfig {
  proxy?: string; // http://user:pass@host:port
  viewport?: { width: number; height: number; deviceScaleFactor: number };
  timezone?: string;
  locale?: string;
  userAgent?: string;
}

const DEFAULT_CONFIG: Required<StealthBrowserConfig> = {
  proxy: "",
  viewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
  timezone: "America/Los_Angeles",
  locale: "en-US,en;q=0.9",
  userAgent: "",
};

export class StealthBrowser {
  private browser: Browser | null = null;
  private config: Required<StealthBrowserConfig>;
  private requestCount = 0;
  private readonly maxRequests = 10;
  private readonly maxAgeMs = 5 * 60 * 1000; // 5 minutes
  private createdAt = Date.now();

  constructor(config: StealthBrowserConfig = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  async launch(env: { BROWSER: any }): Promise<Browser> {
    if (this.browser && this.isHealthy()) {
      return this.browser;
    }
    await this.close();

    const launchOpts: PuppeteerLaunchOptions = {
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-accelerated-2d-canvas",
        "--disable-gpu",
        "--window-size=1920,1080",
        "--lang=en-US",
        "--disable-blink-features=AutomationControlled",
        "--disable-features=IsolateOrigins,site-per-process",
      ],
    };

    const args = launchOpts.args || [];
    if (this.config.proxy) {
      args.push(`--proxy-server=${this.config.proxy}`);
    }
    launchOpts.args = args;

    this.browser = await puppeteerExtra.launch(env.BROWSER);
    // Apply launch options via newPage or CDP
    const browser = this.browser;
    if (browser) {
      const page = await browser.newPage();
      await page.setViewport(this.config.viewport);
      await page.close();
    }
    
    this.requestCount = 0;
    this.createdAt = Date.now();
    return this.browser!;
  }

  async newPage(): Promise<Page> {
    if (!this.browser || !this.isHealthy()) {
      throw new Error("Browser not launched or unhealthy");
    }

    const browser = this.browser;
    const page = await browser.newPage();

    // Realistic viewport
    await page.setViewport(this.config.viewport);

    // Timezone & locale
    await page.emulateTimezone(this.config.timezone);
    await page.setExtraHTTPHeaders({
      "Accept-Language": this.config.locale,
    });

    // Override navigator properties that stealth might miss
    await page.evaluateOnNewDocument((cfg: StealthBrowserConfig) => {
      // Ensure webdriver is undefined
      Object.defineProperty(navigator, "webdriver", {
        get: () => undefined,
        configurable: true,
      });

      // Realistic hardware concurrency
      Object.defineProperty(navigator, "hardwareConcurrency", {
        get: () => 8,
        configurable: true,
      });

      // Realistic device memory
      Object.defineProperty(navigator, "deviceMemory", {
        get: () => 8,
        configurable: true,
      });

      // Platform
      Object.defineProperty(navigator, "platform", {
        get: () => "MacIntel",
        configurable: true,
      });

      // Permissions - deny notifications
      const nav = navigator as Navigator & { permissions?: { query: (p: any) => Promise<any> } };
      const originalQuery = nav.permissions?.query;
      if (originalQuery) {
        nav.permissions.query = (parameters: any) => {
          if (parameters.name === "notifications") {
            return Promise.resolve({ state: "denied" });
          }
          return originalQuery(parameters);
        };
      }
    }, this.config);

    // Block unnecessary resources to speed up
    await page.setRequestInterception(true);
    page.on("request", (req: any) => {
      const type = req.resourceType();
      const url = req.url();
      // Block fonts, analytics, tracking, CSS (but allow images for poster detection)
      if (
        ["font", "stylesheet", "image", "media", "websocket", "manifest", "other"].includes(type) &&
        !url.includes(".m3u8") &&
        !url.includes("mpegurl")
      ) {
        req.abort();
      } else {
        req.continue();
      }
    });

    this.requestCount++;
    return page;
  }

  private isHealthy(): boolean {
    if (!this.browser) return false;
    if (this.requestCount >= this.maxRequests) return false;
    if (Date.now() - this.createdAt > this.maxAgeMs) return false;
    return true;
  }

  async close(): Promise<void> {
    if (this.browser) {
      try {
        await this.browser.close();
      } catch {
        // Ignore close errors
      }
      this.browser = null;
    }
  }

  getRequestCount(): number {
    return this.requestCount;
  }

  getAgeMs(): number {
    return Date.now() - this.createdAt;
  }
}

/**
 * Human-like interaction utilities
 */
export async function humanWait(minMs: number, maxMs: number): Promise<void> {
  const delay = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
  await new Promise((resolve) => setTimeout(resolve, delay));
}

export async function humanClick(page: Page, selector: string, options: { retries?: number } = {}): Promise<boolean> {
  const retries = options.retries ?? 3;

  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      // Wait for element
      await page.waitForSelector(selector, { visible: true, timeout: 5000 });

      // Get element bounds
      const bounds = await page.evaluate((sel: string) => {
        const el = document.querySelector(sel);
        if (!el) return null;
        const rect = el.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      }, selector);

      if (!bounds) continue;

      // Human-like mouse movement
      await page.mouse.move(bounds.x, bounds.y, { steps: Math.floor(Math.random() * 20) + 10 });
      await humanWait(100, 300);

      // Click with slight offset
      await page.mouse.click(bounds.x + (Math.random() - 0.5) * 4, bounds.y + (Math.random() - 0.5) * 4);
      await humanWait(300, 800);

      return true;
    } catch (e) {
      if (attempt === retries - 1) throw e;
      await humanWait(500, 1000);
    }
  }
  return false;
}

export async function humanScroll(page: Page, pixels: number = 200): Promise<void> {
  await page.evaluate((px: number) => window.scrollBy(0, px), pixels);
  await humanWait(300, 600);
}

export async function clickCenterOfPlayer(page: Page): Promise<void> {
  const viewport = page.viewport();
  if (viewport) {
    await page.mouse.move(viewport.width / 2, viewport.height / 2, { steps: 15 });
    await humanWait(100, 300);
    await page.mouse.click(viewport.width / 2, viewport.height / 2);
    await humanWait(500, 1500);
  }
}

/**
 * Multiple selector strategies for play button
 */
export const PLAY_SELECTORS = [
  "button:has-text('Play')",
  "button:has-text('play')",
  "[data-testid='play-button']",
  ".play-button",
  ".player-play-btn",
  "button[aria-label*='play' i]",
  "button:has-text('Server')",
  "button:has-text('server')",
  "[role='button']:has-text('Play')",
  ".server-btn",
  "#play-btn",
];

export async function tryClickPlay(page: Page): Promise<boolean> {
  // Try each selector
  for (const selector of PLAY_SELECTORS) {
    try {
      const clicked = await humanClick(page, selector, { retries: 1 });
      if (clicked) {
        console.log(`[StealthBrowser] Clicked play via selector: ${selector}`);
        return true;
      }
    } catch {
      // Continue to next selector
    }
  }

  // Fallback: click center of viewport
  console.log("[StealthBrowser] All selectors failed, clicking center");
  await clickCenterOfPlayer(page);
  return true;
}