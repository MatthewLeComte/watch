# Roku home screen — known good state

This is the baseline that ships, works, and gets a clean remote response.
`roku/components/MainScene.xml` and `roku/source/MainScene.brs` at the
`83a75a8` commit on the `roku` branch (manifest `build_version=00023`,
running on the Roku as `1.0.23`).

## Layout (`MainScene.xml`)

- `Rectangle id="bg"` — full-screen 1920×1080 background, color `#0E0E10`.
- `PosterGrid id="grid"` — the only interactive child. `focusable="true"`,
  `numColumns="6"`, `numRows="3"`, `basePosterSize="[176,264]"`,
  `itemSpacing="[16,16]"`, `translation="[80, 100]"`. It owns arrow-key
  navigation internally; the scene's `OnKeyEvent` only handles OK / Play /
  back.
- `Video id="player"` — `width="1920"`, `height="1080"`,
  `notificationInterval="10"`, `enableTrickPlay="false"`, `visible="false"`
  until playback starts.
- `Rectangle id="keyCatcher"` — 10×10, `opacity="0.01"`, `focusable="true"`,
  `visible="false"`. Stays invisible on the grid; flipped visible and
  focused only while the player is up so it can capture Right/Left seek
  keys without the grid fighting for them.
- `Rectangle id="header"` + `Label id="title"` — top bar with the app name.

No `Dialog` node. A `Dialog` in the scene tree can sit in the focus chain
even when `visible="false"` and steal focus from the `PosterGrid`, which
manifests as "remote doesn't work" — the grid never receives keys.

## Init (`MainScene.brs`)

- Find `grid`, `player`, `keyCatcher`, `header`, `titleLabel`.
- `player.visible = false` up front.
- `m.current = "grid"`, `m.playTries = 0`.
- Override the grid's defaults in code: `basePosterSize = [280, 420]`,
  `numColumns = 6`, `itemSpacing = [24, 24]`, `translation = [60, 140]`.
  (The XML values are the defaults Roku applies before the script runs;
  the code values are the real layout.)
- Read the catalog from the `WatchCache` registry section
  (`ReadChunks(reg, "catalog")`). If present and valid JSON, call
  `LoadCatalog(j)` which builds a `ContentNode` tree and calls
  `m.grid.SetFocus(true)`. The `SetFocus` is what hands the grid to the
  remote — without it the grid has content but no keys.
- `OnPlayerState` is observed on the `Video` node, `OnGridSelect` on the
  `PosterGrid`'s `itemSelected`.

## Selection → playback

- `OnGridSelect` reads `m.grid.itemSelected` (the index the `PosterGrid`
  fires when OK lands on a tile) and calls `StartPlayback(it)`.
- `StartPlayback` builds a `ContentNode` with `streamFormat = "mp4"`,
  the media URL, and the three auth headers read from the registry, then
  flips the player + keyCatcher visible and focuses the keyCatcher.
  `m.player.control = "play"` starts the stream. `m.current = "player"`.
- `OnPlayerState` handles `finished` (return to grid) and `error` (retry
  up to 2 times via `control = "play"`, then return to grid). This is the
  only retry logic; no position resume, no `?key=` query-param auth — the
  known-good state is the simplest one that works.

## Key handling

- Arrow keys on the grid → handled inside `PosterGrid` (moves
  `itemFocused`). Never reaches `OnKeyEvent`.
- OK / Play on the grid → `OnKeyEvent` reads `itemFocused` and calls
  `StartPlayback`. Belt-and-suspenders with `OnGridSelect`.
- Back in the player → `ReturnToGrid()`, which restores the grid,
  re-asserts `m.grid.SetFocus(true)`, and sets `m.current = "grid"`.
- Right / Left in the player → ±10 s seek via `m.player.seek = …` then
  `control = "play"`.
- OK / Play in the player → toggle pause / resume.

## What NOT to add (lessons from the broken states)

- **`Dialog` node for the error path** — steals focus from the grid,
  remote stops responding. Use a non-focusable overlay (a `Rectangle` +
  `Label`) or just `print` to the debug console and return to grid.
- **Blocking `roUrlTransfer.GetToString` in the Main thread's `Wait`
  loop** — the BrightScript VM is shared with SceneGraph, so the grid
  freezes for the duration of every transfer. Use `AsyncGetToString` and
  share the screen's `roMessagePort` if you ever need to warm caches.
- **The bare identifier `pos` as a local variable** — the Roku compiler
  treats it as a builtin function call and rejects `pos = …`. Use `rp` /
  `cur` / `cursor` etc.
- **`Mid(buf, idx, len) = piece` as a string-builder** — the Roku
  compiler rejects the `Mid` write-statement form. Use
  `roArray.Join(",")` for O(n) assembly of the catalog JSON.
