# RiveStream Headless Hardening Plan

## Error Surface Analysis & Countermeasures

### 1. Cloudflare Challenge / Turnstile / "I'm Under Attack"
| Symptom | Detection | Countermeasure |
|---------|-----------|----------------|
| Challenge page instead of content | `page.content()` contains "challenge", "turnstile", "checking your browser" | **Stealth plugins** + **Residential proxy** + **Cookie persistence** |
| 503/403 on navigation | Response status | **Retry with fresh browser** + **Proxy rotation** |

**Implementation:**
- Add `puppeteer-extra-plugin-stealth` (evades navigator.webdriver, chrome.runtime, permissions)
- Add `puppeteer-extra-plugin-anonymize-ua` (rotate realistic UA)
- Configure Cloudflare Browser Rendering with **residential proxy** (env `RIVESTREAM_PROXY`)
- Persist cookies/storage between runs (KV namespace `rivestream-session`)

### 2. Fingerprinting Detection (Canvas/WebGL/Audio/Fonts)
| Vector | Detection Method | Countermeasure |
|--------|------------------|----------------|
| `navigator.webdriver` | `true` in headless | Stealth plugin patches to `undefined` |
| Canvas fingerprint | `toDataURL()` noise | Stealth plugin adds consistent noise |
| WebGL renderer | "Google Inc. / SwiftShader" | Stealth plugin spoofs to realistic GPU |
| AudioContext | Latency/fingerprint | Stealth plugin normalizes |
| Font enumeration | Local font list | Stealth plugin returns standard set |
| Screen resolution | `window.screen` | Set realistic viewport (1920x1080) |
| Timezone/locale | `Intl.DateTimeFormat` | Match proxy exit node |

**Implementation:** Stealth plugin covers most. Add explicit `page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 })` and `page.emulateTimezone("America/Los_Angeles")`.

### 3. Behavioral Analysis (Mouse/Keyboard/Timing)
| Signal | Detection | Countermeasure |
|--------|-----------|----------------|
| Instant click | No human delay | `await page.waitForTimeout(random(500, 1500))` before click |
| Linear mouse path | `page.mouse.move()` | Use `page.mouse.move(x, y, { steps: random(10, 30) })` |
| No scroll | Bot doesn't scroll | `await page.evaluate(() => window.scrollBy(0, 200))` |
| Immediate navigation | No think time | Random delay 1-3s after `goto` before interaction |

**Implementation:** Wrapper `humanClick(page, selector)` + `humanWait(min, max)` utilities.

### 4. Encrypted/Obfuscated Player Logic
| Scenario | Detection | Countermeasure |
|----------|-----------|----------------|
| HLS URL in encrypted JS | No `.m3u8` in network log | **Reverse-engineer** → find static API endpoint |
| Token in localStorage | Worker has no persistence | **Persist localStorage** to KV, restore on launch |
| WebSocket signaling | Not captured by `page.on("response")` | Listen to `page.on("websocket")` |
| Dynamic iframe src | Playlist in child frame | Recurse frames: `page.frames().forEach(f => f.on("response", ...))` |

**Implementation:**
- Add frame listener for responses
- Add WebSocket listener
- If still failing: **Reverse-engineer once**, replace Puppeteer with direct API call (cache endpoint pattern)

### 5. Short-Lived Tokens / Session Binding
| Issue | Detection | Countermeasure |
|-------|-----------|----------------|
| HLS URL expires in 5 min | Playback fails after resolve | **Resolve on-demand** (don't cache HLS) |
| Token bound to IP | Proxy exit ≠ player IP | **Same proxy for resolve + playback** (not feasible for Roku) → **Don't proxy playback** (HLS CDN usually allows any IP once token obtained) |
| Cookie required for segments | 403 on segment fetch | **Pass cookies** to `Video` node via `subtitleConfig` / `HttpHeaders` (Roku supports `SetCookie` on Video) |

**Implementation:** Roku `Video` node accepts `HttpHeaders` field — pass `Cookie` header from resolve response.

### 6. Concurrency / Resource Limits
| Limit | Current | Countermeasure |
|-------|---------|----------------|
| 30s CPU timeout | 12s deadline + 30s goto | **Reduce timeouts**: 15s goto, 8s playlist wait |
| 128MB memory | Puppeteer + page | **Close page immediately** after playlist found; don't keep browser open |
| Concurrent browsers | CF limit ~3-5 | **Queue/reserve** via Durable Object (singleton browser pool) |

**Implementation:** Durable Object `RiveStreamBrowserPool` manages single browser instance, queues requests.

### 7. Site Structure Changes
| Change | Detection | Countermeasure |
|--------|-----------|----------------|
| New play button selector | Click fails, no playlist | **Multiple selector strategies** + **visual fallback** (click center of player) |
| New domain/embed | `.m3u8` on different origin | **Listen all frames/origins** |
| CAPTCHA on play click | Click → challenge | **Pre-solve**: navigate to player page first, wait for challenge, solve, then click |

**Implementation:** Selector array `["button:has-text('Play')", "[data-testid='play']", ".player-play-btn", "button:has-text('Server')"]`. Fallback: `page.mouse.click(960, 540)` (center).

---

## Solidified Implementation Plan

### Phase 1: Stealth & Reliability (Week 1)
- [ ] Add `puppeteer-extra`, `puppeteer-extra-plugin-stealth`, `puppeteer-extra-plugin-anonymize-ua` to worker dependencies
- [ ] Create `RiveStreamBrowser` class wrapping stealth launch + realistic viewport/timezone
- [ ] Implement `humanClick`, `humanWait`, `humanScroll` utilities
- [ ] Add frame + WebSocket response listeners
- [ ] Add KV session persistence (`rivestream-session` namespace)

### Phase 2: Proxy & Cookie Support (Week 1-2)
- [ ] Add `RIVESTREAM_PROXY` env (format: `http://user:pass@host:port`)
- [ ] Configure `puppeteer.launch({ args: ["--proxy-server=..."] })`
- [ ] Capture `Set-Cookie` headers from resolve → store in KV keyed by `tmdbId`
- [ ] Restore cookies on next resolve for same title
- [ ] Pass cookies to Roku via `Video` node `HttpHeaders`

### Phase 3: Durable Object Browser Pool (Week 2)
- [ ] Create `RiveStreamBrowserPool` Durable Object
- [ ] Singleton browser instance, request queue
- [ ] Health check: restart browser every 10 requests or 5 min
- [ ] Metrics: success rate, latency, errors

### Phase 4: Fallback & Monitoring (Week 2)
- [ ] Add multiple click selector strategies
- [ ] Fallback: center-click player area
- [ ] Structured logging: `console.log(JSON.stringify({ event: "rivestream_resolve", tmdbId, success, latencyMs, error }))`
- [ ] Alert on success rate < 80% (via Logpush to Workers Analytics)

### Phase 5: Reverse-Engineer Escape Hatch (Ongoing)
- [ ] Document RiveStream internal API endpoints found during debugging
- [ ] Create `RiveStreamAPI` class for direct calls (bypass browser)
- [ ] Feature flag: `USE_RIVESTREAM_API` → switch when stable

---

## Worker Code Changes Required

### 1. New Dependencies (`package.json`)
```json
{
  "dependencies": {
    "puppeteer-extra": "^3.3.6",
    "puppeteer-extra-plugin-stealth": "^2.11.2",
    "puppeteer-extra-plugin-anonymize-ua": "^2.4.6"
  }
}
```

### 2. New Files
```
worker/src/sources/
├── rivestream-browser.ts      # Stealth browser wrapper
├── rivestream-pool.ts         # Durable Object browser pool
├── rivestream-session.ts      # KV cookie/session persistence
└── rivestream-api.ts          # Direct API (reverse-engineered)
```

### 3. Modified Files
- `worker/src/sources/rivestream.ts` → use pool, stealth, session
- `worker/wrangler.jsonc` → add Durable Object binding, KV namespace, proxy env var

### 4. Roku Changes
- `roku/source/ResolveView.brs` → call `/v1/sources/resolve`, pass cookies to `Video.HttpHeaders`

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Resolve success rate | > 95% for top 100 titles |
| Median resolve latency | < 8s |
| Browser memory | < 100MB steady state |
| Zero manual intervention | 30 days |

---

## Rollback Plan

If hardening fails:
1. **Disable RiveStream source** → `sourceRiveStream` removed from registry
2. **Rely on `meta` (Cinemeta) + `tmdb_vixsrc`** for streaming
3. **Pre-ingest popular titles** via `downloadAndIngest` (runs offline, no real-time resolve needed)
4. **Revisit in 3 months** — site changes, new tools emerge