# iOS player — gold standard

The iOS player is the reference implementation. It streams, it downloads in
the background, it never black-frames, and it never builds custom video UI.
Anything new (Roku, web) should match this contract.

## Files

- `ios/Playback/PlayerModel.swift` — owns the `AVPlayer`, start/stop,
  position observer, error watching.
- `ios/UI/PlayerView.swift` — `FullScreenPlayer` view modifier; presents
  `AVPlayerViewController` modally.
- `ios/Model/MediaStore.swift` — actor that owns the local sparse file
  (`spans.json` index of downloaded byte ranges), the prefetch job, and
  the seek-by-offset reader.

## Contract

1. **Offline-first.** On `start`, `MediaStore.playableFile(movie)` returns
   the local `movie.<ext>` URL iff every byte range is covered
   (`fraction >= 0.999`). If local, hand AVFoundation the file URL — no
   network, no auth, no Range. If not, hand it the worker URL.
2. **Stream or download, never both racing.** When the file is incomplete,
   `AVURLAsset` opens the worker URL and reads with Range. The prefetch
   job in `MediaStore.fill` runs in 4 MiB holes but **yields to active
   playback** via `playerWaiters` — while a player is reading, prefetch
   sleeps 40 ms. Player and downloader share the same sparse file
   without stepping on each other.
3. **Key in the URL, Bearer too.** AVFoundation drops custom headers on
   Range follow-ups, so the worker URL carries `?key=<apiKey>`. The
   `Authorization: Bearer` header is sent as well for the initial
   request. The worker honors both.
4. **Worker honors exact byte ranges.** `parseByteRange` in
   `worker/src/lib.ts` no longer caps open-ended ranges at 8 MiB.
   AVFoundation asks for the whole remainder up front; a 206 that comes
   back short stalls the player forever. The cap was the bug; the fix
   keeps the open-ended path whole.
5. **Zero custom video UI.** `AVPlayerViewController` is presented
   modally full-screen. Done, scrubber, PiP, AirPlay, the caption
   picker — all native. The app never draws over the video.
6. **Position persists, resume on start.** `library.positions[movie.id]`
   is written on a 0.25 s periodic time observer. On `start(position:)`
   we seek to it asynchronously, then `play()`. Sub-1 s positions are
   ignored so restart-from-beginning feels right.
7. **Errors surface, no black frames.** `PlayerModel.watch(item:)`
   polls `AVPlayerItem.status` and listens for
   `failedToPlayToEndTimeNotification`. On failure, `fail(_:)` tears
   down, calls `onError`, and the UI dismisses with the real message
   (401, offline, bad media). A 15 s timeout fires the same path if
   the item never reaches `.readyToPlay`.
8. **Audio session for movies.** `setCategory(.playback, mode: .moviePlayback)`
   before `play()`. Background audio is on (see `UIBackgroundModes`
   in `ios/project.yml`).
9. **Legible (caption) tracks auto.** `loadMediaSelectionGroup(for: .legible)`
   then `selectMediaOptionAutomatically(in:)` — the native caption
   picker just works, and the right track picks itself when the asset
   carries one.

## Public URL shape

```
GET https://watch.cornerstonecoatings.com/v1/items/{id}/media?key=<apiKey>
Authorization: Bearer <apiKey>
Range: bytes=<offset>-<end>
```

Worker responses: `206 Partial Content` for Range with exact
`Content-Range` and `Content-Length`; `200 OK` for the no-header default
(bounded by `size` only, not by the old 8 MiB cap).

## What the Roku player must match

- Local-first gate before opening the network URL.
- `?key=<apiKey>` on the media URL (Roku `Video` node can't set
  `Range` itself but Range support on the worker is what makes
  `HttpHeaders`+seek workable).
- One in-flight prefetch that yields to active playback, not two
  competing readers.
- Real error messages, not a retry-from-zero that loses the user's
  place.
- Native transport (`Video` node, not a custom overlay).
