# Roku

Checkout: `/Users/matthew/Developer/GitHub/watch/roku`
GitHub: `MatthewLeComte/watch` (roku subdir)
Channel: `Watch` (private, sideloaded)

Target: Roku TV, SceneGraph, FHD (`ui_resolutions=fhd`). Direct MP4 from the
`watch` worker. Built for the home network; the worker gates the expensive
endpoints (see Auth).

## Build

```bash
cd /Users/matthew/Developer/GitHub/watch/roku
cp .env.example .env   # add WATCH_PUBLIC_KEY + WATCH_PRIVATE_KEY (match worker)
./build.sh             # injects key into a staging copy, creates app.zip
```

`build.sh` never mutates the source tree, and `app.zip` / `.env` are
gitignored — the API key must never be committed. Sideload into Developer Mode:

```
curl -F "archive=@app.zip" http://<roku-ip>/plugin_install
```

## Auth

| Endpoint | Gate |
|----------|------|
| `GET /v1/catalog` | `X-Key-ID` + `X-API-Key` + `X-Device-ID` headers |
| `GET /v1/items/{id}/media` | `X-Key-ID` + `X-API-Key` + `X-Device-ID` (Video `httpHeaders`) |
| `GET /v1/items/{id}/poster`, `/backdrop` | Public (unguessable UUID URLs) |

Posters stay public because Roku `Poster` nodes cannot send auth headers —
gating them would break all artwork with no way to fix client-side. Catalog
and media (the bandwidth-expensive endpoints) are gated.

- `X-Key-ID`: public key ID, injected at build time into `source/Config.brs`.
  Must match the worker's `WATCH_PUBLIC_KEY` secret.
- `X-API-Key`: private secret, injected at build time. Must match the
  worker's `WATCH_PRIVATE_KEY` secret. Never committed (build stages to a
  temp dir; `app.zip` / `.env` are gitignored).
- `X-Device-ID`: per-device UUID from `roDeviceInfo.GetRandomUUID()`,
  generated on first run, stored in the `WatchApp` registry section.
- Worker optionally restricts to known devices via `ROKU_ALLOWED_DEVICES`
  (comma-separated UUIDs). Get a device's ID from the telnet/log line
  `Device ID: <uuid>` on first launch, then add it.

## Architecture

```
source/          # merged into Main's scope; shared helpers ONLY (no sub Init)
├── Main.brs     # entry point
├── Config.brs   # PublicKey/PrivateKey/URLs/helpers (__WATCH_* placeholders)
└── Auth.brs     # registry, device ID, AuthHeaders()

components/      # one .xml + .brs per SceneGraph component (isolated scopes)
├── MainScene.*  # grid -> detail -> player view stack, back-key handling
├── GridView.*   # catalog fetch + registry cache, PosterGrid, loading/error
├── DetailView.* # metadata panel, Play / Close
└── PlayerView.* # Video node, loading/error
```

### Rules that keep this app from breaking

1. **No `const`** — BrightScript has no `const` keyword; it fails compile.
   Shared values are functions in `Config.brs` (`ApiBase()`, ...).
2. **Component scopes are isolated.** A function defined in one component's
   `.brs` is not callable from another. Cross-view communication goes only
   through interface fields + `ObserveField`.
3. **Counters, not values, for triggers.** Setting a field to the value it
   already holds fires no event, so actions use `*Index` integer counters
   (`selectIndex`, `playIndex`, `startIndex`, ...) that increment every time.
4. **Component scripts live in `components/`, not `source/`.** All of
   `source/*.brs` merges into Main's scope, so a second `sub Init()` there
   is a redefinition collision.
5. **PosterGrid has no custom item component.** Feed it `ContentNode`s with
   `HDPosterUrl`; there is no `itemComponentName` / `PosterGridItem`.
6. **Only existing Roku APIs.** No `roUrlTransfer.SetTimeout`,
   no `roDateTime.GetSecondsSinceEpoch` (use `AsSeconds`, seconds not ms —
   millisecond epochs overflow 32-bit ints), no `roRandom` (use
   `roDeviceInfo.GetRandomUUID()`), `type(x)` of a string is `"String"`.
7. **Registry cache is size-guarded.** Values over ~12KB are skipped, not
   truncated, and expire after `CacheTtlSec()` (300s).

## Worker secrets needed (Secrets Store, account-level — no vars)

| Secret | Store secret name | Description |
|--------|-------------------|-------------|
| `WATCH_PUBLIC_KEY` | `WATCH_PUBLIC_KEY` | Public key ID, must match Roku `.env` |
| `WATCH_PRIVATE_KEY` | `WATCH_PRIVATE_KEY` | Private secret, must match Roku `.env` |

Bound in `wrangler.jsonc` (`secrets_store_secrets`); read via `.get()` and
cached per isolate, fail-closed on any error. `store_id` in `wrangler.jsonc`
must be the account Secrets Store ID (not secret). After rotating a secret,
redeploy so isolates drop the cached copy.
| `ROKU_ALLOWED_DEVICES` | Worker secret (optional) | Comma-separated device UUID allowlist |

Deploy worker with `ship worker=watch` (git-pushes origin/main). Set/rotate
secrets in the Cloudflare dashboard, never in `wrangler.jsonc`.
