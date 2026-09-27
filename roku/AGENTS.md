# Roku

Checkout: `/Users/matthew/Developer/GitHub/watch/roku`
Channel: `Watch` (private, sideloaded to 10.0.0.115)

Target: Roku TV, SceneGraph, FHD. Direct MP4 from the `watch` worker.
Single `MainScene`: grid + player, manual back handling. Main thread fetches
the catalog and hands it to the scene via the `WatchCache` registry section
(chunked keys `catalog0..N` + `catalogChunks`, registry values are
size-limited). Scene reads keypair + device ID from the same section.

## Build + install

```bash
cd /Users/matthew/Developer/GitHub/watch/roku
cp .env.example .env   # fill in values (see below)
./build.sh             # creates app.zip, keypair injected from .env
./build.sh --install   # build + sideload + verify installed version
```

`.env` / `app.zip` are gitignored — secrets never touch git.

## Sideload

Needs Developer Mode on the Roku (Settings → System → Advanced system
settings → Developer settings). The installer user is `rokudev` with the
Developer Mode password:

- `ROKU_HOST` — Roku IP (10.0.0.115 = Streaming Stick 4K)
- `ROKU_DEV_USER` — `rokudev`
- `ROKU_DEV_PASSWORD` — Developer Mode password

`--install` POSTs with digest auth + `mysubmit=Install`, then checks the
installed version from `:8060/query/apps` matches the manifest.

## Auth (worker gate)

Same auth as the iOS app. `build.sh` injects `WATCH_KEY` into `Main.brs`.

- Catalog is `GET /v1/items` with `Authorization: Bearer <WATCH_KEY>`.
- Playback is `/v1/items/{id}/media?key=<WATCH_KEY>` plus the same Bearer
  header. The query param stays on Range follow-ups.
- Posters stay public.
