# Watch

Checkout: `/Users/matthew/Developer/GitHub/watch`  
GitHub: `MatthewLeComte/watch`  
Bundle: `watch.apps`  
Scheme: `Watch`  
Worker: `watch`  
Host: `https://watch.cornerstonecoatings.com`  

No `workers.dev`. No preview URLs.

Ship the worker with Make MCP: `ship` `worker=watch`. That git-pushes to the configured remote (xcode cloud; the make ship MCP needs repointing if it still targets `origin`). Workers Builds is the only uploader. Do not `wrangler deploy` from a laptop.

Library MCP: `https://watch.cornerstonecoatings.com/mcp`. Make proxies it at `https://make.cornerstonecoatings.com/mcp/watch` (same proxy secret as `/mcp/github`). Tools: list, get, edit, rematch, delete.

D1 binding and database name are `watch` (`2d26cd1f-e8e9-41fc-a17f-e36106702537`).  
R2 bucket name is `watch`. The R2 binding is `watch_bucket` because a Worker cannot have two bindings with the same name.

App icon is Eden pixel1, label `Watch`. Generator: `Work/Tooling/generate-wordmark-styles.py`.

## Surfaces

| Surface | Path | Notes |
|---------|------|-------|
| Worker (Cloudflare) | `worker/` | `src/`, `test/`, `migrations/`, `tools/`, `wrangler.jsonc`, `package.json` |
| iOS app | `ios/` | `project.yml` then `xcodegen generate` |
| Roku channel | `roku/` | see `roku/AGENTS.md` |

## Where to edit

| Task | Open |
|------|------|
| Worker routes | `worker/src/worker.ts` |
| Ingest, OpenSubtitles, Cinemeta | `worker/src/ingest.ts` |
| Filename / hash | `worker/src/lib.ts` |
| Cinemeta API | `worker/src/cinemeta.ts` |
| iOS UI | `ios/UI/` |
| Playback and offline file | `ios/Playback/`, `ios/Model/MediaStore.swift` |
| Xcode project | `ios/project.yml` then `xcodegen generate` |
| Roku channel | `roku/` (see `roku/AGENTS.md`) |
