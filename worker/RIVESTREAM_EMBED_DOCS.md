# RiveStream Embed Docs

Source: https://www.rivestream.app/embed/docs
Fetched: 2026-09-30
Base origin: `https://www.rivestream.app`

> Rive Stream — Biggest Streaming API. Free streaming links for movies and episodes integrated via embed links / API.

TMDB IDs come from [The Movie Database API](https://developer.themoviedb.org/docs/getting-started).

On the live docs page the "Endpoint" boxes are filled client-side from `window.location.origin` (see `_next/static/chunks/pages/embed/docs-*.js`):
- Movie template: `{origin}/embed?type=movie&id={tmdbId}`
- TV template: `{origin}/embed?type=tv&id={tmdbId}&season={season}&episode={episode}`
- Torrent / Agg / Download variants are string replaces of `embed` in those templates.

## 1. Default Embed API

### 1.1 Movie Embed
TMDB `id` required.

Endpoint template:
```
https://www.rivestream.app/embed?type=movie&id={tmdbId}
```

Examples:
```
/embed?type=movie&id=533535
/embed?type=movie&id=278
```

Full URLs:
```
https://www.rivestream.app/embed?type=movie&id=533535
https://www.rivestream.app/embed?type=movie&id=278
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed?type=movie&id=533535" allowfullscreen></iframe>
```

### 1.2 TV Show Embed
TMDB `id`, `season`, `episode` required. Season / episode must not be empty.

Endpoint template:
```
https://www.rivestream.app/embed?type=tv&id={tmdbId}&season={season}&episode={episode}
```

Examples:
```
/embed?type=tv&id=1396&season=1&episode=1
/embed?type=tv&id=1399&season=1&episode=1
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed?type=tv&id=1396&season=1&episode=1" allowfullscreen></iframe>
```

## 2. Torrent API

> Streaming high-quality movies and TV shows using torrents.

### 2.1 Movie Embed
```
https://www.rivestream.app/embed/torrent?type=movie&id={tmdbId}
```

Examples:
```
/embed/torrent?type=movie&id=533535
/embed/torrent?type=movie&id=278
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed/torrent?type=movie&id=533535" allowfullscreen></iframe>
```

### 2.2 TV Show Embed
```
https://www.rivestream.app/embed/torrent?type=tv&id={tmdbId}&season={season}&episode={episode}
```

Examples:
```
/embed/torrent?type=tv&id=1396&season=1&episode=1
/embed/torrent?type=tv&id=1399&season=1&episode=1
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed/torrent?type=tv&id=1396&season=1&episode=1" allowfullscreen></iframe>
```

## 3. Aggregator API

> Stream movies and TV shows from multiple aggregator servers.

### 3.1 Movie Embed
```
https://www.rivestream.app/embed/agg?type=movie&id={tmdbId}
```

Examples:
```
/embed/agg?type=movie&id=533535
/embed/agg?type=movie&id=278
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed/agg?type=movie&id=533535" allowfullscreen></iframe>
```

### 3.2 TV Show Embed
```
https://www.rivestream.app/embed/agg?type=tv&id={tmdbId}&season={season}&episode={episode}
```

Examples:
```
/embed/agg?type=tv&id=1396&season=1&episode=1
/embed/agg?type=tv&id=1399&season=1&episode=1
```

Embed:
```html
<iframe src="https://www.rivestream.app/embed/agg?type=tv&id=1396&season=1&episode=1" allowfullscreen></iframe>
```

## 4. Download API

> Download movies and TV shows from multiple aggregator servers.

### 4.1 Movie Download
```
https://www.rivestream.app/download?type=movie&id={tmdbId}
```

Examples:
```
/download?type=movie&id=533535
/download?type=movie&id=278
```

Embed:
```html
<iframe src="https://www.rivestream.app/download?type=movie&id=533535" allowfullscreen></iframe>
```

### 4.2 TV Show Download
```
https://www.rivestream.app/download?type=tv&id={tmdbId}&season={season}&episode={episode}
```

Examples:
```
/download?type=tv&id=1396&season=1&episode=1
/download?type=tv&id=1399&season=1&episode=1
```

Embed:
```html
<iframe src="https://www.rivestream.app/download?type=tv&id=1396&season=1&episode=1" allowfullscreen></iframe>
```

## Parameters

| Param | Required | Notes |
|-------|----------|-------|
| `type` | yes | `movie` or `tv` |
| `id` | yes | TMDB ID, e.g. `533535`, `278`, `1396`, `1399` |
| `season` | TV only | e.g. `1` |
| `episode` | TV only | e.g. `1` |

## Features (from docs page)

- Responsive: player works on Desktop, Mobile, Tablet
- Auto Update: content added daily, updated automatically
- Highest Quality: latest available quality, fastest
- Fast Streaming: list of fastest streaming servers, user-selectable
- Huge Library: contents from various other sources

## Links from docs page

- Demo anchor: `/embed/docs#demo`
- API anchor: `/embed/docs#api`
- Features anchor: `/embed/docs#features`
- Discord: https://discord.gg/6xJmJja8fV
- Contact: developer@rivestream.app
