# Posters

The Roku app and the web app need two images per movie: a portrait poster (grid) and a 16:9 backdrop (detail screen). A separate poster worker is responsible for fetching, sizing, and writing both images to the `watch` R2 bucket. The watch worker only serves them.

## R2 layout

Both images live next to the existing video object, keyed by movie id.

| Key | Aspect | Use |
|-----|--------|-----|
| `poster/{id}` | 2:3 (e.g. 540x810 or 1000x1500) | Poster grid tile |
| `backdrop/{id}` | 16:9 (e.g. 1920x1080) | Detail screen background |

Write both with a valid `httpMetadata.contentType` (`image/jpeg` or `image/webp`). The poster worker may overwrite; the watch worker never writes these keys.

The existing `storePoster` in `src/ingest.ts:672` and `putPoster` in `src/worker.ts:527` are the only writers today — they will keep writing `poster/{id}` from the IMDb/TMDB image URL during ingest. The poster worker will additionally write `backdrop/{id}` and may replace `poster/{id}` with a higher-quality source.

## Image spec

- **Format:** JPEG preferred, WebP acceptable. No PNG (too large for a TV grid).
- **Poster:** exactly 2:3, longest side at least 1000px, max 1 MiB.
- **Backdrop:** exactly 16:9, longest side at least 1920px, max 1.5 MiB.
- **No letterbox bars.** Crop to fill, centered, or pick a different source frame.
- **Color space:** sRGB, no embedded ICC profile larger than 4 KiB.

Anything that fails these is rejected by the watch worker (see "Validation" below). The poster worker should pre-validate before PUT.

## Watch worker contract

The watch worker exposes two GETs. Both are public (no `WATCH_KEY` required) and Roku-friendly.

```
GET https://watch.cornerstonecoatings.com/v1/items/{id}/poster
GET https://watch.cornerstonecoatings.com/v1/items/{id}/backdrop
```

Response headers, on success and 404:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, HEAD
Cache-Control: public, max-age=604800, immutable
Content-Type: image/jpeg    # from R2 httpMetadata
```

On 404, return JSON `{ "error": "no_poster" }` or `{ "error": "no_backdrop" }` with `Content-Type: application/json` and the same CORS + `Cache-Control: public, max-age=300` (so the poster worker's PUT is picked up soon after).

## Validation (watch worker side)

The watch worker only checks: object exists, declared `contentType` is `image/jpeg` or `image/webp`, size between 4 KiB and 2 MiB. Anything else → 404 with the JSON above. The poster worker is responsible for the aspect ratio and dimension guarantees — the worker cannot re-encode cheaply and Roku will not display a mis-cropped image gracefully.

## Catalog response shape

`/v1/items` and `/v1/items/{id}` add two fields:

```json
{
  "id": "...",
  "title": "Fred Claus",
  "year": 2007,
  "posterUrl": "https://watch.cornerstonecoatings.com/v1/items/{id}/poster",
  "backdropUrl": "https://watch.cornerstonecoatings.com/v1/items/{id}/backdrop"
}
```

Both are always present in the response. They point at the endpoints above; the consumer does a HEAD first if it wants to know availability. The Roku app renders a placeholder tile when the HEAD returns 404.

`thumbnailUrl` stays as-is (Cloudflare Stream HLS thumbnail, set by `saveStream` in `src/worker.ts:175`). It is independent of the poster/backdrop pipeline.

## What the poster worker needs from the movie row

To do its job, the poster worker reads from the `movie` D1 table:

- `id` (R2 key prefix)
- `imdb_id` (preferred source)
- `tmdb_id` (fallback source)
- `title`, `year` (last-resort search query)

The poster worker should poll for movies where `poster/{id}` or `backdrop/{id}` is missing in R2. The watch worker does not signal "needs poster" — absence in R2 is the signal.
