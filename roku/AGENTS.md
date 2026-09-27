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

Catalog + media require all three headers; posters stay public (Roku
`Poster` nodes can't send headers; URLs are unguessable UUIDs).

- `WATCH_PUBLIC_KEY` / `WATCH_SIGNATURE` / `WATCH_TIMESTAMP` / `WATCH_NONCE`
  (`roku/source/Auth.brs` signs `timestamp.nonce` with `roDSA` Ed25519).
  The public and private key strings are injected by `build.sh` from `.env`.
- Sign immediately before the request. The worker rejects a timestamp
  more than 30 seconds off.
