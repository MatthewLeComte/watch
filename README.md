# Watch

Private movies for iPhone, iPad, and Mac. The library lives on Cloudflare. Playback writes the file to the device as it streams, and Download saves the rest for offline.

Host: `https://watch.cornerstonecoatings.com`  
Bundle: `watch.apps`  
Worker name: `watch`

Upload MP4, M4V, or MOV from Settings. At ingest the worker reads the filename, looks up the film (OpenSubtitles hash for that exact file when `OPENSUBTITLES_API_KEY` is set, TMDB when `TMDB_API_KEY` is set, otherwise Wikipedia), and stores the poster. If several films still fit, one Jev call on the Make unified-billing gateway picks among those ids. It does not call again.

MKV does not play on this device.

## App

```bash
cd App && xcodegen generate && open Watch.xcodeproj
```

The library key is already in the app and the worker. Change it in Settings only if you change `WATCH_KEY`.

## Worker

Push `main` with Make MCP (`ship`, `worker=watch`). Workers Builds runs `npm run deploy`. Laptop `wrangler deploy` is refused.

```bash
npm test
```

Optional secrets, not required for a filename match:

```bash
npx wrangler secret put OPENSUBTITLES_API_KEY
npx wrangler secret put TMDB_API_KEY
```

Those `secret put` commands are local Wrangler and do not upload the script.
