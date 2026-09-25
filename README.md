# Watch

Private movies for iPhone, iPad, and Mac. The library lives on Cloudflare. Playback writes the file to the device as it streams, and Download saves the rest for offline.

Host: `https://watch.cornerstonecoatings.com`  
Bundle: `watch.apps`  
Worker name: `watch`

Upload MP4, M4V, or MOV from Settings. At ingest the worker reads the filename, resolves the IMDb id (from the filename, or by searching Stremio Cinemeta), and pulls the full metadata (title, year, overview, runtime, genres, poster, 16:9 backdrop, YouTube trailer) from Cinemeta in one call. No API key needed, no WAF challenge, no fallbacks. The result is cached by IMDb id so the next file for the same film is a single D1 read.

OpenSubtitles is still consulted for subtitle files when `OPENSUBTITLES_API_KEY` is set, but only as subtitles — never for matching.

MKV does not play on this device.

## iOS app

```bash
cd ios && xcodegen generate && open Watch.xcodeproj
```

The library key is already in the app and the worker. Change it in Settings only if you change `WATCH_KEY`.

## Worker

Push the worker surface with Make MCP (`ship`, `worker=watch`). Workers Builds runs `npm run deploy` from `worker/`. Laptop `wrangler deploy` is refused.

```bash
cd worker && npm test
```

Optional secret, not required for matching:

```bash
npx wrangler secret put OPENSUBTITLES_API_KEY
```

Those `secret put` commands are local Wrangler and do not upload the script.
