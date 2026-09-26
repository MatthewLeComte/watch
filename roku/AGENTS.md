# Roku

Checkout: `/Users/matthew/Developer/GitHub/watch/roku`  
GitHub: `MatthewLeComte/watch`  
Channel: `Watch` (private, sideloaded)

Target: Roku TV, SceneGraph, FHD (`ui_resolutions=fhd`). No HLS, no subtitles — direct MP4 from the `watch` worker. Single shared secret baked into app.zip at build time.

## Build

```
cd /Users/matthew/Developer/GitHub/watch/roku
export ROKU_SHARED_SECRET="<generate once, keep in password manager>"
./build.sh
```

Sideload into Developer Mode (Settings → System → Advanced system settings → Developer settings on the device):

```
curl -F "archive=@app.zip" http://<roku-ip>/plugin_install
```

## Data sources

Roku endpoints require the shared secret header (injected by app):

| Endpoint | Use |
|----------|-----|
| `GET /v1/catalog` | JSON list of all items, CORS, `Cache-Control: 60s` |
| `GET /v1/items/{id}/media` | MP4 with `Accept-Ranges: bytes` for seek |
| `GET /v1/items/{id}/poster` | 2:3 portrait, JPEG/WebP, CORS, immutable |
| `GET /v1/items/{id}/backdrop` | 16:9 landscape, JPEG/WebP, CORS, immutable |

See `watch/POSTERS.md` for the image contract and validation rules.

## Where to edit

| Task | Open |
|------|------|
| Entry, screen lifecycle | `source/Main.brs` |
| Grid + detail + player (single scene) | `components/MainScene.xml`, `source/MainScene.brs` |
| Grid item | `components/GridItem.xml`, `source/GridItem.brs` |
| Catalog fetch | `source/Catalog.brs` |

The app uses a single `MainScene` with three view groups (`grid`, `detail`, `player`) and a manual back stack. Detail and player swap in on selection, back key pops the stack.

## Out of scope for v1

- Resume / watched-state tracking.
- HLS / adaptive bitrate.
- Subtitle tracks.
- Channel icon and splash screen branding.
- Player controls overlay (uses the default `Video` overlay).
