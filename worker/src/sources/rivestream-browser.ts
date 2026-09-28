/**
 * StealthBrowser: Hardened Puppeteer wrapper for RiveStream.
 * Implements anti-detection manually (no puppeteer-extra, not Workers-compatible).
 * Uses @cloudflare/puppeteer with Cloudflare Browser Rendering.
 */

import puppeteer from "@cloudflare/puppeteer";
import type { Browser, Page, PuppeteerLaunchOptions } from "@cloudflare/puppeteer";

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

// Realistic user agents for rotation
const USER_AGENTS = [
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0",
];

export class StealthBrowser {
  private browser: Browser | null = null;
  private config: Required<StealthBrowserConfig>;
  private requestCount = 0;
  private readonly maxRequests = 10;
  private readonly maxAgeMs = 5 * 60 * 1000; // 5 minutes
  private createdAt = Date.now();

  constructor(config: StealthBrowserConfig = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    // Pick a random UA if not specified
    if (!this.config.userAgent) {
      this.config.userAgent = USER_AGENTS[Math.floor(Math.random() * USER_AGENTS.length)];
    }
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
        "--disable-features=IsolateOrigins,site-per-process,TranslateUI",
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-field-trial-config",
        "--disable-ipc-flooding-protection",
        "--no-first-run",
        "--no-default-browser-check",
        "--no-pings",
        "--password-store=basic",
        "--use-mock-keychain",
      ],
    };

    if (this.config.proxy) {
      launchOpts.args.push(`--proxy-server=${this.config.proxy}`);
    }

    this.browser = await puppeteer.launch(env.BROWSER, launchOpts);
    this.requestCount = 0;
    this.createdAt = Date.now();
    return this.browser;
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
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
      "Accept-Encoding": "gzip, deflate, br",
      "Upgrade-Insecure-Requests": "1",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-User": "?1",
      "Sec-Fetch-Dest": "document",
      "Sec-Ch-Ua": '"Chromium";v="128", "Not;A=Brand";v="24", "Google Chrome";v="128"',
      "Sec-Ch-Ua-Mobile": "?0",
      "Sec-Ch-Ua-Platform": '"macOS"',
    });

    // Override navigator properties to evade detection
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

      // Chrome runtime (used by extensions detection)
      Object.defineProperty(window, "chrome", {
        get: () => ({
          runtime: {},
          loadTimes: () => {},
          csi: () => {},
          app: {},
        }),
        configurable: true,
      });

      // Plugins
      Object.defineProperty(navigator, "plugins", {
        get: () => [
          { name: "Chrome PDF Plugin", filename: "internal-pdf-viewer", description: "Portable Document Format" },
          { name: "Chrome PDF Viewer", filename: "mhjfbmdgcfjbbpaeojofohoefgiehjai", description: "Portable Document Format" },
          { name: "Native Client", filename: "internal-nacl-plugin", description: "Native Client Executable" },
        ],
        configurable: true,
      });

      // Languages
      Object.defineProperty(navigator, "languages", {
        get: () => ["en-US", "en"],
        configurable: true,
      });

      // Screen
      Object.defineProperty(screen, "colorDepth", { get: () => 24, configurable: true });
      Object.defineProperty(screen, "pixelDepth", { get: () => 24, configurable: true });

      // WebGL vendor/renderer
      const getParameter = WebGLRenderingContext.prototype.getParameter;
      WebGLRenderingContext.prototype.getParameter = function(parameter: number) {
        if (parameter === 37445) return "Intel Inc."; // UNMASKED_VENDOR_WEBGL
        if (parameter === 37446) return "Intel Iris OpenGL Engine"; // UNMASKED_RENDERER_WEBGL
        return getParameter.call(this, parameter);
      };
    }, this.config);

    // Block unnecessary resources to speed up
    await page.setRequestInterception(true);
    page.on("request", (req: any) => {
      const type = req.resourceType();
      const url = req.url();
      // Allow images (for poster detection), but block fonts, CSS, analytics, tracking
      if (
        ["font", "stylesheet", "media", "websocket", "manifest", "other"].includes(type) &&
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

      // Human-like mouse movement with random steps
      const steps = Math.floor(Math.random() * 20) + 10;
      await page.mouse.move(bounds.x, bounds.y, { steps });
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