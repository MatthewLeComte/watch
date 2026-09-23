# Watch

Checkout: `/Users/matthew/Developer/GitHub/watch`  
GitHub: `MatthewLeComte/watch`  
Bundle: `watch.apps`  
Scheme: `Watch`  
Worker: `watch`  
Host: `https://watch.cornerstonecoatings.com`  

No `workers.dev`. No preview URLs.

Ship the worker with Make MCP: `ship` `worker=watch`. That git-pushes `origin/main`. Workers Builds is the only uploader. Do not `wrangler deploy` from a laptop.

Library MCP: `https://watch.cornerstonecoatings.com/mcp`. Make proxies it at `https://make.cornerstonecoatings.com/mcp/watch` (same proxy secret as `/mcp/github`). Tools: list, get, edit, rematch, delete.

D1 binding and database name are `watch` (`2d26cd1f-e8e9-41fc-a17f-e36106702537`).  
R2 bucket name is `watch`. The R2 binding is `watch_bucket` because a Worker cannot have two bindings with the same name.

App icon is Eden pixel1, label `Watch`. Generator: `Work/Tooling/generate-wordmark-styles.py`.

## Where to edit

| Task | Open |
|------|------|
| Worker routes | `src/worker.ts` |
| Ingest, OpenSubtitles, Jev | `src/ingest.ts` |
| Filename / hash / score | `src/lib.ts` |
| App UI | `App/UI/` |
| Playback and offline file | `App/Playback/`, `App/Model/MediaStore.swift` |
| Xcode project | `App/project.yml` then `xcodegen generate` |
