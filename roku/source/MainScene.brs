' Home, the way Netflix lays out a TV screen: a bar across the top (sound, search, Home, Shows, Movies),
' then rows. The focused title is a wide tile at the left of its row with its details underneath and its
' trailer playing inside it; the rest of the row and the next row are posters. One focus owner (keyCatcher)
' receives every key, so the whole screen is drawn from four numbers: zone, tab, row and column.

sub Init()
  m.hero = m.top.findNode("hero")
  m.player = m.top.findNode("player")
  m.keyCatcher = m.top.findNode("keyCatcher")
  m.homeUI = m.top.findNode("homeUI")
  m.rowsUI = m.top.findNode("rowsUI")
  m.searchUI = m.top.findNode("searchUI")
  m.emptyLabel = m.top.findNode("empty")
  m.rowTitle = m.top.findNode("rowTitle")
  m.nextTitle = m.top.findNode("nextTitle")
  m.ring = m.top.findNode("ring")
  m.titleLabel = m.top.findNode("title")
  m.metaLabel = m.top.findNode("meta")
  m.overviewLabel = m.top.findNode("overview")
  m.backdrop = m.top.findNode("backdrop")
  m.caption = m.top.findNode("caption")
  m.capBg = m.top.findNode("capBg")
  m.heroTimer = m.top.findNode("heroTimer")
  m.startTimer = m.top.findNode("startTimer")
  m.fadeTick = m.top.findNode("fadeTick")
  m.loadTick = m.top.findNode("loadTick")
  m.loading = m.top.findNode("loading")
  m.loadTitle = m.top.findNode("loadTitle")
  m.loadText = m.top.findNode("loadText")
  m.muteIcon = m.top.findNode("muteIcon")
  m.muteRing = m.top.findNode("muteRing")
  m.menu = m.top.findNode("menu")
  m.btn1 = m.top.findNode("btn1")
  m.menuTick = m.top.findNode("menuTick")
  m.menuHide = m.top.findNode("menuHide")

  m.player.visible = false
  m.player.ObserveField("state", "OnPlayerState")
  m.player.ObserveField("position", "OnPlayPosition")
  m.heroTimer.ObserveField("fire", "OnHeroTimer")
  m.startTimer.ObserveField("fire", "OnStartTimer")
  m.fadeTick.ObserveField("fire", "OnFadeTick")
  m.loadTick.ObserveField("fire", "OnLoadTick")
  m.menuTick.ObserveField("fire", "OnMenuTick")
  m.menuHide.ObserveField("fire", "CloseMenu")
  m.hero.ObserveField("state", "OnHeroState")
  m.hero.ObserveField("position", "OnHeroPosition")
  StyleTrickPlay()
  ShrinkPreviews()

  m.current = "home"
  m.zone = "rows"
  m.tab = "home"
  m.barFocus = 2
  m.rowsData = []
  m.row = 0
  m.cols = []
  m.inSeries = ""
  m.saved = invalid
  m.shows = {}
  m.tiles = []
  m.shownKey = ""
  m.focused = invalid
  m.heroId = ""
  m.cues = []
  m.capTask = invalid
  m.backdropTarget = 1.0
  m.playTries = 0
  m.pending = invalid
  m.dots = 0
  m.catalog = invalid
  m.playItem = invalid
  m.startAt = 0
  m.lastSaved = 0
  m.progTask = invalid
  m.menuOpen = false
  m.menuSel = 0
  m.menuTarget = 0.0
  m.playSubs = false
  m.subTrack = ""
  m.subsApplied = false
  m.query = ""
  m.found = []
  m.keyAt = [0, 0]
  m.resAt = 0
  m.reg = CreateObject("roRegistrySection", "WatchCache")
  ' Trailers play with sound unless the speaker in the top bar is switched off; the choice is remembered.
  m.muted = (m.reg.Read("heroMuted") = "1")
  ' Subtitles stay as the viewer last left them (off until switched on in the player)
  m.subsOn = (m.reg.Read("subsOn") = "1")
  ShowMuteIcon()
  BuildKeys()

  json = ReadChunks(m.reg, "catalog")
  if json <> invalid and type(json) = "String" and Len(json) > 0
    j = ParseJSON(json)
    if j <> invalid and type(j) = "roArray" and j.Count() > 0 then m.catalog = j
  end if
  if m.catalog = invalid then m.catalog = []
  BuildRows()
  if m.rowsData.Count() = 0 then m.zone = "bar"
  Render()
  m.keyCatcher.SetFocus(true)
end sub

function S(value as Dynamic) as String
  if value = invalid then return ""
  return value
end function

' ---------------------------------------------------------------- rows

' The rows of the current tab. Every row lists the most recently opened first. A show is one tile that
' opens its seasons and episodes.
sub BuildRows()
  rented = []
  animation = []
  live = []
  resuming = []
  tiles = []
  m.shows = {}
  showNames = []
  for each item in m.catalog
    if Val(S(item.itemResume)) > 30 then resuming.Push(item)
    if S(item.itemSeries) <> ""
      if m.shows[item.itemSeries] = invalid
        m.shows[item.itemSeries] = []
        showNames.Push(item.itemSeries)
      end if
      item.episodeNum = Val(S(item.itemEpisode))
      item.seasonNum = Val(S(item.itemSeason))
      m.shows[item.itemSeries].Push(item)
    else if item.itemRental = "1"
      rented.Push(item)
    else if item.itemAnim = "1"
      animation.Push(item)
    else
      live.Push(item)
    end if
  end for
  movieRented = []
  movieRented.Append(rented)
  movieAnimation = []
  movieAnimation.Append(animation)
  movieLive = []
  movieLive.Append(live)

  showNames.Sort()
  for each name in showNames
    eps = m.shows[name]
    eps.SortBy("episodeNum")
    eps.SortBy("seasonNum")
    tile = {}
    tile.Append(eps[0])
    tile.itemTitle = name
    tile.itemTile = "1"
    tile.itemEpCount = StrI(eps.Count()).Trim()
    tile.itemRuntime = ""
    tile.itemYear = ""
    tile.itemResume = ""
    anyRental = false
    for each ep in eps
      if S(ep.itemPlayed) > S(tile.itemPlayed) then tile.itemPlayed = ep.itemPlayed
      if ep.itemRental = "1" then anyRental = true
    end for
    tiles.Push(tile)
    if anyRental
      rented.Push(tile)
    else if tile.itemAnim = "1"
      animation.Push(tile)
    else
      live.Push(tile)
    end if
  end for
  m.tiles = tiles

  rows = []
  if m.tab = "shows"
    AddRow(rows, "Shows", tiles)
  else if m.tab = "movies"
    AddRow(rows, "Rented", movieRented)
    AddRow(rows, "Animation", movieAnimation)
    AddRow(rows, "Live Action", movieLive)
  else
    AddRow(rows, "Continue Watching", resuming)
    AddRow(rows, "Rented", rented)
    AddRow(rows, "Animation", animation)
    AddRow(rows, "Live Action", live)
  end if
  m.rowsData = rows
  m.row = 0
  m.cols = []
  for each row in rows
    m.cols.Push(0)
  end for
  m.inSeries = ""
end sub

sub AddRow(rows as Object, name as String, items as Object)
  if items.Count() = 0 then return
  items.SortBy("itemPlayed", "r")
  rows.Push({ title: name, items: items })
end sub

function PosterOf(it as Object) as String
  return "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/poster"
end function

' How far through a title the viewer is, 0 when there is nothing to resume.
function Progress(it as Object) as Float
  at = Val(S(it.itemResume))
  mins = Val(S(it.itemRuntime))
  if at <= 30 or mins <= 0 then return 0.0
  part = at / (mins * 60)
  if part < 0.03 then part = 0.03
  if part > 1 then part = 1
  return part
end function

sub Bar(track as Object, fill as Object, it as Dynamic, width as Integer)
  part = 0.0
  if it <> invalid then part = Progress(it)
  track.visible = (part > 0)
  fill.visible = (part > 0)
  if part > 0 then fill.width = Int(width * part)
end sub

function MetaText(it as Object) as String
  parts = []
  if S(it.itemYear) <> "" then parts.Push(it.itemYear)
  if S(it.itemRuntime) <> ""
    mins = Val(it.itemRuntime)
    if Val(S(it.itemResume)) > 30
      left = Int(mins - Val(it.itemResume) / 60)
      if left < 1 then left = 1
      if left >= 60
        parts.Push(StrI(Int(left / 60)).Trim() + "h " + StrI(left mod 60).Trim() + "m left")
      else
        parts.Push(StrI(left).Trim() + "m left")
      end if
    else
      parts.Push(StrI(Int(mins / 60)).Trim() + "h " + StrI(mins mod 60).Trim() + "m")
    end if
  end if
  if S(it.itemTile) = "1"
    if it.itemEpCount = "1"
      parts.Push("1 episode")
    else
      parts.Push(S(it.itemEpCount) + " episodes")
    end if
  end if
  if S(it.itemAnim) = "1"
    parts.Push("Animation")
  else if S(it.itemGenre) <> ""
    parts.Push(it.itemGenre)
  end if
  out = ""
  for each part in parts
    if out <> "" then out = out + "   " + Chr(8226) + "   "
    out = out + part
  end for
  return out
end function

' Draw the whole home screen from the current zone, tab, row and column.
sub Render()
  RenderBar()
  if m.tab = "search"
    m.rowsUI.visible = false
    m.emptyLabel.visible = false
    m.searchUI.visible = true
    RenderSearch()
    return
  end if
  m.searchUI.visible = false
  rows = m.rowsData
  if rows.Count() = 0
    m.rowsUI.visible = false
    StopHero()
    m.emptyLabel.text = "Nothing here yet"
    m.emptyLabel.visible = true
    return
  end if
  m.emptyLabel.visible = false
  m.rowsUI.visible = true
  row = rows[m.row]
  at = m.cols[m.row]
  m.rowTitle.text = row.title
  m.ring.visible = (m.zone = "rows")
  for i = 0 to 3
    n = StrI(i).Trim()
    node = m.top.findNode("fp" + n)
    it = invalid
    if at + 1 + i < row.items.Count() then it = row.items[at + 1 + i]
    node.visible = (it <> invalid)
    if it <> invalid then node.uri = PosterOf(it)
    Bar(m.top.findNode("ft" + n), m.top.findNode("ff" + n), it, 285)
  end for
  below = invalid
  if m.row + 1 < rows.Count() then below = rows[m.row + 1]
  if below <> invalid
    m.nextTitle.text = below.title
  else
    m.nextTitle.text = ""
  end if
  for i = 0 to 6
    node = m.top.findNode("np" + StrI(i).Trim())
    it = invalid
    if below <> invalid and m.cols[m.row + 1] + i < below.items.Count() then it = below.items[m.cols[m.row + 1] + i]
    node.visible = (it <> invalid)
    if it <> invalid then node.uri = PosterOf(it)
  end for
  ShowItem(row.items[at])
end sub

' The wide tile and the details under it. Its trailer starts once focus has rested on it.
sub ShowItem(it as Object)
  m.focused = it
  Bar(m.top.findNode("wt"), m.top.findNode("wf"), it, 760)
  key = it.itemId + S(it.itemTile)
  if key = m.shownKey then return
  m.shownKey = key
  m.titleLabel.text = S(it.itemTitle)
  m.metaLabel.text = MetaText(it)
  m.overviewLabel.text = S(it.itemOverview)
  StopHero()
  m.backdrop.uri = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/backdrop"
  m.backdrop.opacity = 1
  m.backdropTarget = 1.0
  m.fadeTick.control = "stop"
  m.heroTimer.control = "stop"
  m.heroTimer.control = "start"
end sub

sub OnHeroTimer()
  it = m.focused
  if m.current <> "home" or m.tab = "search" or it = invalid then return
  if S(it.itemTrailer) = "1" then StartHero(it)
end sub

sub StartHero(it as Object)
  m.heroId = it.itemId
  apiKey = m.reg.Read("apiKey")
  base = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId
  content = CreateObject("roSGNode", "ContentNode")
  content.url = base + "/trailer?key=" + apiKey
  content.streamFormat = "mp4"
  content.HttpHeaders = ["Authorization:Bearer " + apiKey]
  m.hero.mute = m.muted
  m.hero.loop = true
  m.hero.content = content
  m.hero.control = "play"
  ' Captions are drawn here, on top of the video, from the trailer's WebVTT
  m.cues = []
  if S(it.itemCaps) = "1"
    m.capTask = CreateObject("roSGNode", "CaptionTask")
    m.capTask.ObserveField("cues", "OnCues")
    m.capTask.url = base + "/trailer.vtt?key=" + apiKey
    m.capTask.key = apiKey
    m.capTask.control = "RUN"
  end if
end sub

sub StopHero()
  m.heroTimer.control = "stop"
  if m.heroId <> "" then m.hero.control = "stop"
  m.heroId = ""
  m.hero.visible = false
  m.cues = []
  m.caption.text = ""
  m.capBg.visible = false
end sub

' The trailer is really playing: fade the still picture away to reveal it.
sub OnHeroState()
  if m.hero.state = "playing" and m.current = "home" and m.focused <> invalid and m.heroId = m.focused.itemId
    m.hero.visible = true
    m.backdropTarget = 0.0
    m.fadeTick.control = "start"
  end if
end sub

sub OnFadeTick()
  b = m.backdrop.opacity
  if b < m.backdropTarget
    b = b + 0.1
    if b > m.backdropTarget then b = m.backdropTarget
  else if b > m.backdropTarget
    b = b - 0.06
    if b < m.backdropTarget then b = m.backdropTarget
  end if
  m.backdrop.opacity = b
  if b = m.backdropTarget then m.fadeTick.control = "stop"
end sub

' Open a show: its seasons as rows, episodes in order. Back returns to where it was opened from.
sub OpenSeries(name as String)
  eps = m.shows[name]
  if eps = invalid then return
  m.saved = { rows: m.rowsData, row: m.row, cols: m.cols, tab: m.tab }
  rows = []
  season = -1
  for each ep in eps
    if ep.seasonNum <> season
      season = ep.seasonNum
      rows.Push({ title: name + "   " + Chr(8226) + "   Season " + StrI(season).Trim(), items: [] })
    end if
    rows[rows.Count() - 1].items.Push(ep)
  end for
  m.rowsData = rows
  m.row = 0
  m.cols = []
  for each row in rows
    m.cols.Push(0)
  end for
  if m.tab = "search" then m.tab = "home"
  m.inSeries = name
  m.zone = "rows"
  Render()
end sub

sub CloseSeries()
  m.inSeries = ""
  if m.saved <> invalid
    m.tab = m.saved.tab
    m.rowsData = m.saved.rows
    m.row = m.saved.row
    m.cols = m.saved.cols
  end if
  m.saved = invalid
  if m.tab = "search" then m.zone = "results"
  Render()
end sub

sub SelectItem(it as Object)
  if S(it.itemTile) = "1"
    OpenSeries(it.itemSeries)
    return
  end if
  ' A title with a resume point simply resumes; Start Over is in the player's controls
  StartPlayback(it, Int(Val(S(it.itemResume))))
end sub

' ---------------------------------------------------------------- top bar

sub Paint(n as Integer, fill as String, words as String, shown as Float)
  key = "bar" + StrI(n).Trim()
  m.top.findNode(key + "Pill").opacity = shown
  m.top.findNode(key + "L").blendColor = fill
  m.top.findNode(key + "M").color = fill
  m.top.findNode(key + "R").blendColor = fill
  if n = 1
    m.top.findNode(key + "Icon").blendColor = words
  else
    m.top.findNode(key + "Label").color = words
  end if
end sub

' The focused bar item is a white pill; the current section keeps a grey pill while focus is elsewhere.
sub RenderBar()
  names = ["", "search", "home", "shows", "movies"]
  for n = 1 to 4
    if m.zone = "bar" and m.barFocus = n
      Paint(n, "0xFFFFFFFF", "0x101012FF", 1.0)
    else if names[n] = m.tab
      Paint(n, "0x3A3A3EFF", "0xFFFFFFFF", 1.0)
    else
      Paint(n, "0xFFFFFFFF", "0xE0E0E0FF", 0.0)
    end if
  end for
  m.muteRing.visible = (m.zone = "bar" and m.barFocus = 0)
end sub

sub SetTab(name as String)
  if name = m.tab and m.inSeries = "" then return
  m.tab = name
  m.saved = invalid
  m.shownKey = ""
  if name = "search"
    StopHero()
  else
    BuildRows()
  end if
end sub

' ---------------------------------------------------------------- search

sub BuildKeys()
  m.keyRows = ["ABCDEF", "GHIJKL", "MNOPQR", "STUVWX", "YZ1234", "567890"]
  m.keyWide = ["space", "delete", "clear"]
  keys = m.top.findNode("keys")
  for r = 0 to 5
    for c = 0 to 5
      cell = keys.CreateChild("Label")
      cell.id = "key" + StrI(r).Trim() + StrI(c).Trim()
      cell.translation = [96 + c * 74, 250 + r * 66]
      cell.width = 68
      cell.height = 60
      cell.horizAlign = "center"
      cell.vertAlign = "center"
      cell.font = "font:MediumBoldSystemFont"
      cell.text = Mid(m.keyRows[r], c + 1, 1)
    end for
  end for
  for c = 0 to 2
    cell = keys.CreateChild("Label")
    cell.id = "key6" + StrI(c).Trim()
    cell.translation = [96 + c * 148, 250 + 6 * 66]
    cell.width = 142
    cell.height = 60
    cell.horizAlign = "center"
    cell.vertAlign = "center"
    cell.font = "font:SmallBoldSystemFont"
    cell.text = m.keyWide[c]
  end for
  results = m.top.findNode("results")
  for i = 0 to 9
    tile = results.CreateChild("Poster")
    tile.id = "res" + StrI(i).Trim()
    tile.translation = [600 + (i mod 5) * 256, 150 + Int(i / 5) * 384]
    tile.width = 240
    tile.height = 360
    tile.loadDisplayMode = "scaleToZoom"
  end for
end sub

' Titles whose name contains what was typed; a show appears once. Nothing typed lists the latest opened.
sub Search()
  pool = []
  for each item in m.catalog
    if S(item.itemSeries) = "" then pool.Push(item)
  end for
  pool.Append(m.tiles)
  want = LCase(m.query)
  first = []
  rest = []
  for each item in pool
    name = LCase(S(item.itemTitle))
    at = Instr(1, name, want)
    if want = "" or at = 1
      first.Push(item)
    else if at > 1
      rest.Push(item)
    end if
  end for
  if want = "" then first.SortBy("itemPlayed", "r")
  first.Append(rest)
  m.found = first
  if m.resAt >= m.found.Count() or m.resAt > 9 then m.resAt = 0
end sub

sub RenderSearch()
  Search()
  query = m.top.findNode("query")
  if m.query = ""
    query.text = "Search"
    query.color = "0x8C8C8CFF"
  else
    query.text = m.query
    query.color = "0xFFFFFFFF"
  end if
  hi = m.top.findNode("keyHi")
  hi.visible = (m.zone = "keys")
  for r = 0 to 6
    last = 5
    if r = 6 then last = 2
    for c = 0 to last
      cell = m.top.findNode("key" + StrI(r).Trim() + StrI(c).Trim())
      on = (m.zone = "keys" and m.keyAt[0] = r and m.keyAt[1] = c)
      if on
        cell.color = "0x101012FF"
        hi.translation = cell.translation
        hi.width = cell.width
      else
        cell.color = "0xFFFFFFFF"
      end if
    end for
  end for
  shown = m.found.Count()
  if shown > 10 then shown = 10
  for i = 0 to 9
    tile = m.top.findNode("res" + StrI(i).Trim())
    tile.visible = (i < shown)
    if i < shown then tile.uri = PosterOf(m.found[i])
  end for
  resHi = m.top.findNode("resHi")
  resHi.visible = (m.zone = "results" and shown > 0)
  resHi.translation = [594 + (m.resAt mod 5) * 256, 144 + Int(m.resAt / 5) * 384]
  title = m.top.findNode("resTitle")
  meta = m.top.findNode("resMeta")
  if m.zone = "results" and shown > 0
    title.text = S(m.found[m.resAt].itemTitle)
    meta.text = MetaText(m.found[m.resAt])
  else if shown = 0
    title.text = "No titles match"
    meta.text = ""
  else
    title.text = ""
    meta.text = ""
  end if
end sub

sub TypeKey()
  r = m.keyAt[0]
  c = m.keyAt[1]
  if r < 6
    m.query = m.query + Mid(m.keyRows[r], c + 1, 1)
  else if c = 0
    if m.query <> "" then m.query = m.query + " "
  else if c = 1
    if Len(m.query) > 0 then m.query = Left(m.query, Len(m.query) - 1)
  else
    m.query = ""
  end if
  m.resAt = 0
end sub

' ---------------------------------------------------------------- keys on the home screen

function HomeKey(k as String) as Boolean
  if Left(k, 4) = "Lit_" and m.tab = "search"
    m.query = m.query + UCase(Mid(k, 5))
    m.resAt = 0
    Render()
    return true
  end if
  if m.zone = "bar"
    if k = "left" and m.barFocus > 0
      m.barFocus = m.barFocus - 1
    else if k = "right" and m.barFocus < 4
      m.barFocus = m.barFocus + 1
    else if k = "OK" and m.barFocus = 0
      OnMuteToggle()
      return true
    else if k = "down" or k = "OK"
      if m.barFocus = 0 then m.barFocus = 2
      if m.tab = "search"
        m.zone = "keys"
      else if m.rowsData.Count() > 0
        m.zone = "rows"
      end if
    else if k = "back"
      return false
    else
      return true
    end if
    names = ["", "search", "home", "shows", "movies"]
    if m.zone = "bar" and m.barFocus > 0 then SetTab(names[m.barFocus])
    Render()
    return true
  end if
  if m.zone = "keys"
    r = m.keyAt[0]
    c = m.keyAt[1]
    if k = "OK"
      TypeKey()
    else if k = "up"
      if r = 0
        m.zone = "bar"
        m.barFocus = 1
      else if r = 6
        m.keyAt = [5, c * 2]
      else
        m.keyAt = [r - 1, c]
      end if
    else if k = "down"
      if r = 5
        m.keyAt = [6, Int(c / 2)]
      else if r < 5
        m.keyAt = [r + 1, c]
      end if
    else if k = "left"
      if c > 0 then m.keyAt = [r, c - 1]
    else if k = "right"
      last = 5
      if r = 6 then last = 2
      if c < last
        m.keyAt = [r, c + 1]
      else if m.found.Count() > 0
        m.zone = "results"
      end if
    else if k = "back"
      m.zone = "bar"
      m.barFocus = 1
    else if k = "replay" or k = "rewind"
      if Len(m.query) > 0 then m.query = Left(m.query, Len(m.query) - 1)
    end if
    Render()
    return true
  end if
  if m.zone = "results"
    shown = m.found.Count()
    if shown > 10 then shown = 10
    if k = "OK"
      if m.resAt < shown then SelectItem(m.found[m.resAt])
      return true
    else if k = "left"
      if m.resAt mod 5 = 0
        m.zone = "keys"
      else
        m.resAt = m.resAt - 1
      end if
    else if k = "right"
      if m.resAt mod 5 < 4 and m.resAt + 1 < shown then m.resAt = m.resAt + 1
    else if k = "down"
      if m.resAt + 5 < shown then m.resAt = m.resAt + 5
    else if k = "up"
      if m.resAt >= 5
        m.resAt = m.resAt - 5
      else
        m.zone = "bar"
        m.barFocus = 1
      end if
    else if k = "back"
      m.zone = "keys"
    end if
    Render()
    return true
  end if
  ' rows
  row = m.rowsData[m.row]
  at = m.cols[m.row]
  if k = "OK"
    SelectItem(row.items[at])
    return true
  else if k = "right"
    if at + 1 < row.items.Count() then m.cols[m.row] = at + 1
  else if k = "left"
    if at > 0 then m.cols[m.row] = at - 1
  else if k = "down"
    if m.row + 1 < m.rowsData.Count() then m.row = m.row + 1
  else if k = "up"
    if m.row > 0
      m.row = m.row - 1
    else if m.inSeries = ""
      m.zone = "bar"
      names = ["", "search", "home", "shows", "movies"]
      for n = 1 to 4
        if names[n] = m.tab then m.barFocus = n
      end for
    end if
  else if k = "back"
    if m.inSeries <> ""
      CloseSeries()
      return true
    end if
    m.zone = "bar"
    names = ["", "search", "home", "shows", "movies"]
    for n = 1 to 4
      if names[n] = m.tab then m.barFocus = n
    end for
  else
    return true
  end if
  Render()
  return true
end function

function OnKeyEvent(k, p) as Boolean
  if not p then return false
  if m.current = "player" and m.menuOpen then return MenuKey(k)
  if k = "back" and (m.current = "player" or m.current = "starting")
    m.startTimer.control = "stop"
    ReturnHome()
    return true
  end if
  if m.current = "player" and (k = "down" or k = "up")
    state = m.player.state
    if state = "playing" or state = "paused"
      OpenMenu()
      return true
    end if
  end if
  if m.current = "home" then return HomeKey(k)
  return false
end function

' ---------------------------------------------------------------- playing a title

sub StartPlayback(it as Object, startAt as Integer)
  if m.current <> "home" then return
  m.playItem = it
  m.startAt = startAt
  m.lastSaved = startAt
  print "Playing: " + it.itemId
  m.current = "starting"
  m.pending = it
  StopHero()
  m.homeUI.visible = false
  ' Show the title straight away so the screen is never just black while the stream opens
  m.loadTitle.text = S(it.itemTitle)
  m.dots = 0
  m.loadText.text = "Starting"
  m.loading.visible = true
  m.loadTick.control = "start"
  m.keyCatcher.visible = true
  m.keyCatcher.SetFocus(true)
  ' The trailer and the movie cannot share the video decoder, so give it a moment to release
  m.startTimer.control = "start"
end sub

sub ReturnHome()
  wasPlaying = (m.playItem <> invalid and m.current = "player")
  if wasPlaying then SaveProgress(m.player.state = "finished")
  m.playItem = invalid
  m.menuOpen = false
  m.menuHide.control = "stop"
  m.menuTick.control = "stop"
  m.menuTarget = 0.0
  m.menu.opacity = 0
  m.menu.visible = false
  m.player.control = "stop"
  m.player.visible = false
  HideLoading()
  m.homeUI.visible = true
  m.keyCatcher.visible = true
  m.keyCatcher.SetFocus(true)
  m.current = "home"
  m.shownKey = ""
  ' What was just watched moves to the front of Continue Watching
  if wasPlaying and m.inSeries = "" and m.tab <> "search" then BuildRows()
  Render()
end sub

function ReadChunks(reg as Object, key as String) as Dynamic
  c = reg.Read(key + "Chunks")
  if c = invalid then return invalid
  out = ""
  for n = 0 to Val(c) - 1
    part = reg.Read(key + StrI(n).Trim())
    if part = invalid then return invalid
    out = out + part
  end for
  return out
end function

sub ShowMuteIcon()
  if m.muted
    m.muteIcon.uri = "pkg:/images/sound-off.png"
  else
    m.muteIcon.uri = "pkg:/images/sound-on.png"
  end if
end sub

sub OnMuteToggle()
  m.muted = not m.muted
  if m.muted
    m.reg.Write("heroMuted", "1")
  else
    m.reg.Write("heroMuted", "0")
  end if
  m.reg.Flush()
  m.hero.mute = m.muted
  ShowMuteIcon()
end sub

sub OnCues()
  if m.capTask <> invalid then m.cues = m.capTask.cues
end sub

sub OnHeroPosition()
  secs = m.hero.position
  text = ""
  for each cue in m.cues
    if secs >= cue.s and secs < cue.e
      text = cue.t
      exit for
    end if
  end for
  if text <> m.caption.text then m.caption.text = text
  m.capBg.visible = (text <> "")
end sub

sub StyleTrickPlay()
  bar = m.player.trickPlayBar
  if bar = invalid then return
  bar.filledBarImageUri = "pkg:/images/filled-bar.png"
end sub

' Seek previews: the stock strip is five large frames across the whole screen. Shrink it toward the
' progress bar it sits on, so the film stays visible while scrubbing.
sub ShrinkPreviews()
  strip = m.player.bifDisplay
  if strip = invalid then return
  if strip.translation = invalid then return
  m.strip = strip
  was = strip.scale
  m.stripWas = [1.0, 1.0]
  if was <> invalid and was.Count() = 2 then m.stripWas = [was[0], was[1]]
  m.stripBy = 0.6
  strip.scale = [m.stripWas[0] * m.stripBy, m.stripWas[1] * m.stripBy]
  AnchorPreviews()
  strip.ObserveField("translation", "AnchorPreviews")
end sub

' Keep the shrunken strip centred and resting on the bar (bottom centre of the stock strip: 960, 928),
' wherever the player moves it.
sub AnchorPreviews()
  if m.strip = invalid then return
  at = m.strip.translation
  if at = invalid then return
  k = m.stripBy
  cx = 0.0
  cy = 0.0
  dx = 1.0 - k * m.stripWas[0]
  dy = 1.0 - k * m.stripWas[1]
  if dx <> 0 then cx = (1.0 - k) * (960 - at[0]) / dx
  if dy <> 0 then cy = (1.0 - k) * (928 - at[1]) / dy
  m.strip.scaleRotateCenter = [cx, cy]
end sub

' Forget the resume point and begin again from the start
sub StartOver()
  it = m.playItem
  if it = invalid then return
  SendProgress(it.itemId, "DELETE", "")
  SetLocalResume(it.itemId, "")
  m.startAt = 0
  m.lastSaved = 0
  m.player.seek = 0
end sub

' Player controls: Up or Down during the film shows Start Over and, when the title has them, Subtitles.
' Left and right move, OK chooses, anything else puts them away. They leave on their own after a few seconds.
sub OpenMenu()
  m.menuOpen = true
  m.menuSel = 0
  m.btn1.visible = m.playSubs
  m.menu.visible = true
  PaintMenu()
  m.menuTarget = 1.0
  m.menuTick.control = "start"
  m.menuHide.control = "stop"
  m.menuHide.control = "start"
  m.keyCatcher.visible = true
  m.keyCatcher.SetFocus(true)
end sub

sub CloseMenu()
  if not m.menuOpen then return
  m.menuOpen = false
  m.menuHide.control = "stop"
  m.menuTarget = 0.0
  m.menuTick.control = "start"
  m.keyCatcher.visible = false
  if m.current = "player" then m.player.SetFocus(true)
end sub

sub OnMenuTick()
  ' The words are measured once they have been drawn, so size the pills again while fading in
  if m.menuTarget > 0 then PaintMenu()
  o = m.menu.opacity
  if o < m.menuTarget
    o = o + 0.2
    if o > m.menuTarget then o = m.menuTarget
  else if o > m.menuTarget
    o = o - 0.25
    if o < m.menuTarget then o = m.menuTarget
  end if
  m.menu.opacity = o
  if o = m.menuTarget
    m.menuTick.control = "stop"
    if o <= 0 then m.menu.visible = false
  end if
end sub

sub PaintMenu()
  if m.subsOn
    m.top.findNode("btn1Label").text = "Subtitles On"
  else
    m.top.findNode("btn1Label").text = "Subtitles Off"
  end if
  x = 96
  for i = 0 to 1
    key = "btn" + StrI(i).Trim()
    label = m.top.findNode(key + "Label")
    icon = m.top.findNode(key + "Icon")
    pill = m.top.findNode(key + "Pill")
    ' The focused button is a white pill with dark words; the other is a faint pill with white words
    if i = m.menuSel
      pill.opacity = 1.0
      icon.blendColor = "0x101012FF"
      label.color = "0x101012FF"
    else
      pill.opacity = 0.18
      icon.blendColor = "0xFFFFFFFF"
      label.color = "0xFFFFFFFF"
    end if
    ' Each pill is as wide as its words
    w = label.boundingRect().width
    if w < 40
      w = 232
      if i = 0 then w = 180
    end if
    total = 80 + w + 30
    m.top.findNode(key + "Mid").width = total - 72
    m.top.findNode(key + "CapR").translation = [total - 36, 0]
    m.top.findNode(key).translation = [x, 836]
    x = x + total + 18
  end for
end sub

function MenuKey(k as String) as Boolean
  m.menuHide.control = "stop"
  m.menuHide.control = "start"
  count = 1
  if m.playSubs then count = 2
  if k = "right"
    if m.menuSel < count - 1 then m.menuSel = m.menuSel + 1
    PaintMenu()
  else if k = "left"
    if m.menuSel > 0 then m.menuSel = m.menuSel - 1
    PaintMenu()
  else if k = "OK"
    if m.menuSel = 0
      CloseMenu()
      StartOver()
    else
      ToggleSubtitles()
      PaintMenu()
    end if
  else if k = "play"
    CloseMenu()
    if m.player.state = "paused"
      m.player.control = "resume"
    else
      m.player.control = "pause"
    end if
  else
    CloseMenu()
  end if
  return true
end function

' Subtitles follow the viewer's last choice. Off only hides them in this player.
sub ApplySubtitles()
  if not m.playSubs
    m.player.suppressCaptions = false
    return
  end if
  if m.subsOn
    m.player.suppressCaptions = false
    m.player.globalCaptionMode = "On"
    tracks = m.player.availableSubtitleTracks
    if tracks <> invalid and tracks.Count() > 0
      m.player.subtitleTrack = tracks[0].TrackName
    else
      m.player.subtitleTrack = m.subTrack
    end if
  else
    m.player.suppressCaptions = true
  end if
end sub

sub ToggleSubtitles()
  m.subsOn = not m.subsOn
  if m.subsOn
    m.reg.Write("subsOn", "1")
  else
    m.reg.Write("subsOn", "0")
    ' Switching them off here also switches the Roku caption setting off, so nothing can still draw them
    m.player.globalCaptionMode = "Off"
  end if
  m.reg.Flush()
  ApplySubtitles()
end sub

function ClockText(secs as Integer) as String
  h = Int(secs / 3600)
  mm = Int((secs mod 3600) / 60)
  ss = secs mod 60
  out = StrI(mm).Trim() + ":" + Right("0" + StrI(ss).Trim(), 2)
  if h > 0 then out = StrI(h).Trim() + ":" + Right("0" + StrI(mm).Trim(), 2) + ":" + Right("0" + StrI(ss).Trim(), 2)
  return out
end function

' One resume-point update to the library (PUT position and duration, or DELETE to start over).
sub SendProgress(id as String, method as String, body as String)
  t = CreateObject("roSGNode", "ProgressTask")
  t.url = "https://watch.cornerstonecoatings.com/v1/items/" + id + "/progress"
  t.key = m.reg.Read("apiKey")
  t.method = method
  t.body = body
  t.control = "RUN"
  m.progTask = t
end sub

' Keep the in-memory catalog current so Continue Watching reflects what was just watched.
sub SetLocalResume(id as String, resume as String)
  if m.catalog = invalid then return
  now = CreateObject("roDateTime").ToISOString()
  for each entry in m.catalog
    if entry.itemId = id
      entry.itemResume = resume
      entry.itemPlayed = now
    end if
  end for
end sub

sub SaveProgress(finishedHint as Boolean)
  it = m.playItem
  if it = invalid then return
  here = m.player.position
  dur = m.player.duration
  if here = invalid then return
  ' Never overwrite a resume point when playback never actually began
  if here <= 0 and m.startAt > 0 then return
  if dur = invalid then dur = 0
  at = Int(here)
  body = "{""position"":" + StrI(at).Trim() + ",""duration"":" + StrI(Int(dur)).Trim() + "}"
  SendProgress(it.itemId, "PUT", body)
  m.lastSaved = at
  done = (finishedHint or (dur > 0 and (at >= dur * 0.95 or dur - at < 120)))
  if at >= 30 and not done
    SetLocalResume(it.itemId, StrI(at).Trim())
  else
    SetLocalResume(it.itemId, "")
  end if
end sub

sub OnPlayPosition()
  ' While watching, save the point about every 30 seconds
  if m.current <> "player" or m.playItem = invalid then return
  if m.player.position - m.lastSaved >= 30 then SaveProgress(false)
end sub

sub OnLoadTick()
  m.dots = (m.dots + 1) mod 4
  text = "Starting"
  for i = 1 to m.dots
    text = text + " ."
  end for
  m.loadText.text = text
end sub

sub HideLoading()
  m.loadTick.control = "stop"
  m.loading.visible = false
end sub

sub OnStartTimer()
  it = m.pending
  if it = invalid or m.current <> "starting" then return
  m.playTries = 0
  content = CreateObject("roSGNode", "ContentNode")
  apiKey = m.reg.Read("apiKey")
  base = "https://watch.cornerstonecoatings.com"
  if it.itemSaved <> ""
    ' Saved stream: HLS chunks in R2. The Bearer header below covers every chunk request.
    content.url = base + it.itemSaved + "?key=" + apiKey
    content.streamFormat = "hls"
  else
    content.url = base + "/v1/items/" + it.itemId + "/media?key=" + apiKey
    content.streamFormat = "mp4"
  end if
  content.title = it.itemTitle
  content.HttpHeaders = ["Authorization:Bearer " + apiKey]
  ' Seek previews: a BIF per title when one has been uploaded (the player ignores a missing one)
  bif = base + "/v1/items/" + it.itemId + "/trick.bif?key=" + apiKey
  content.SDBifUrl = bif
  content.HDBifUrl = bif
  content.FHDBifUrl = bif
  m.playSubs = false
  m.subTrack = ""
  m.subsApplied = false
  if it.itemSubs = "1"
    m.subTrack = base + "/v1/items/" + it.itemId + "/subtitles/en?key=" + apiKey
    content.SubtitleTracks = [{ Language: "eng", TrackName: m.subTrack, Description: "English" }]
    m.playSubs = true
  end if
  ' Earlier builds switched the Roku caption setting on for every title; put it back once
  if m.reg.Read("capsReset") <> "1"
    if not m.subsOn then m.player.globalCaptionMode = "Off"
    m.reg.Write("capsReset", "1")
    m.reg.Flush()
  end if
  if m.startAt > 0 then content.PlayStart = m.startAt
  m.player.content = content
  m.player.visible = true
  m.current = "player"
  m.player.control = "play"
  ApplySubtitles()
  ' The player itself takes focus so left/right/OK open its native seek bar, with BIF previews
  m.player.SetFocus(true)
end sub

sub OnPlayerState()
  print "Player state: " + m.player.state
  if m.player.state = "playing" and m.current = "player"
    HideLoading()
    if not m.menuOpen then m.player.SetFocus(true)
    ' The subtitle tracks are known once the film is playing, so settle the choice then
    if not m.subsApplied
      m.subsApplied = true
      ApplySubtitles()
    end if
  end if
  if m.player.state = "finished"
    print "Player finished"
    ReturnHome()
    return
  end if
  if m.player.state = "error"
    msg = m.player.errorMsg
    if msg = invalid then msg = ""
    print "Player error: " + StrI(m.player.errorCode) + " " + msg
    if m.playTries < 2
      m.playTries = m.playTries + 1
      print "Playback retry: " + StrI(m.playTries)
      m.player.control = "play"
      return
    end if
    ReturnHome()
  end if
end sub
