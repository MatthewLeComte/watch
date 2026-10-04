' Home: the focused title's trailer fades in on top with captions, shelves scroll below.
' Selecting a title plays it full screen. No sub views.

sub Init()
  m.hero = m.top.findNode("hero")
  m.rows = m.top.findNode("rows")
  m.player = m.top.findNode("player")
  m.keyCatcher = m.top.findNode("keyCatcher")
  m.titleLabel = m.top.findNode("title")
  m.metaLabel = m.top.findNode("meta")
  m.overviewLabel = m.top.findNode("overview")
  m.heroTimer = m.top.findNode("heroTimer")
  m.startTimer = m.top.findNode("startTimer")
  m.veil = m.top.findNode("veil")
  m.ambient = m.top.findNode("ambient")
  m.rowsTick = m.top.findNode("rowsTick")
  m.veilTick = m.top.findNode("veilTick")
  m.backdropTick = m.top.findNode("backdropTick")
  m.backdrop = m.top.findNode("backdrop")
  m.scrim = m.top.findNode("scrim")
  m.coverLeft = m.top.findNode("coverLeft")
  m.coverBottom = m.top.findNode("coverBottom")
  m.brand = m.top.findNode("brand")
  m.caption = m.top.findNode("caption")
  m.capBg = m.top.findNode("capBg")

  m.player.visible = false
  m.player.ObserveField("state", "OnPlayerState")
  m.rows.ObserveField("rowItemFocused", "OnFocusChanged")
  m.rows.ObserveField("rowItemSelected", "OnSelect")
  m.heroTimer.ObserveField("fire", "OnHeroTimer")
  m.startTimer.ObserveField("fire", "OnStartTimer")
  m.hero.ObserveField("state", "OnHeroState")
  m.hero.ObserveField("position", "OnHeroPosition")
  m.backdrop.ObserveField("loadStatus", "OnBackdropLoad")
  m.veilTick.ObserveField("fire", "OnVeilTick")
  m.rowsTick.ObserveField("fire", "OnRowsTick")
  m.backdropTick.ObserveField("fire", "OnBackdropTick")
  StyleTrickPlay()

  m.current = "home"
  m.playTries = 0
  m.focused = invalid
  m.heroId = ""
  m.pending = invalid
  m.cues = []
  m.capTask = invalid
  m.reg = CreateObject("roRegistrySection", "WatchCache")

  json = ReadChunks(m.reg, "catalog")
  if json <> invalid and type(json) = "String" and Len(json) > 0
    j = ParseJSON(json)
    if j <> invalid and type(j) = "roArray" and j.Count() > 0
      LoadCatalog(j)
      print "Loaded " + StrI(j.Count()) + " from registry"
    else
      print "Registry parse failed"
    end if
  else
    print "No registry data"
  end if
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

function NewItem(parent as Object, item as Object) as Object
  n = parent.CreateChild("ContentNode")
  n.AddField("itemId", "string", false)
  n.AddField("itemTitle", "string", false)
  n.AddField("itemYear", "string", false)
  n.AddField("itemRuntime", "string", false)
  n.AddField("itemTrailer", "string", false)
  n.AddField("itemCaps", "string", false)
  n.AddField("itemSaved", "string", false)
  n.AddField("itemOverview", "string", false)
  n.AddField("itemGenre", "string", false)
  n.AddField("itemAnim", "string", false)
  n.AddField("itemSubs", "string", false)
  n.AddField("itemRental", "string", false)
  n.SetFields(item)
  return n
end function

' Shelves: Rented, then Animation, then Live Action.
sub LoadCatalog(items)
  print "LoadCatalog: " + StrI(items.Count()) + " items"
  rented = []
  animation = []
  live = []
  for each item in items
    if item.itemRental = "1"
      rented.Push(item)
    else if item.itemAnim = "1"
      animation.Push(item)
    else
      live.Push(item)
    end if
  end for

  root = CreateObject("roSGNode", "ContentNode")
  if rented.Count() > 0 then AddShelf(root, "Rented", rented)
  if animation.Count() > 0 then AddShelf(root, "Animation", animation)
  if live.Count() > 0 then AddShelf(root, "Live Action", live)

  m.rows.content = root
  m.rows.SetFocus(true)
  ' Shelves fade in rather than pop in
  m.rows.opacity = 0
  m.rowsTick.control = "start"
  print "Shelves: " + StrI(root.GetChildCount())
  if root.GetChildCount() > 0 then FocusHero(root.GetChild(0).GetChild(0))
end sub

sub AddShelf(root as Object, name as String, items as Object)
  shelf = root.CreateChild("ContentNode")
  shelf.title = name
  for each item in items
    NewItem(shelf, item)
  end for
end sub

sub OnFocusChanged()
  at = m.rows.rowItemFocused
  if at = invalid or m.rows.content = invalid then return
  shelf = m.rows.content.GetChild(at[0])
  if shelf = invalid then return
  FocusHero(shelf.GetChild(at[1]))
end sub

' Backdrop and text update at once; the trailer fades in once focus has rested.
sub FocusHero(it as Object)
  if it = invalid then return
  m.focused = it
  m.titleLabel.text = it.itemTitle
  parts = []
  if it.itemYear <> "" then parts.Push(it.itemYear)
  if it.itemRuntime <> ""
    mins = Val(it.itemRuntime)
    parts.Push(StrI(Int(mins / 60)).Trim() + "h " + StrI(mins mod 60).Trim() + "m")
  end if
  if it.itemAnim = "1"
    parts.Push("Animation")
  else if it.itemGenre <> ""
    parts.Push(it.itemGenre)
  end if
  meta = ""
  for each part in parts
    if meta <> "" then meta = meta + "   |   "
    meta = meta + part
  end for
  m.metaLabel.text = meta
  m.overviewLabel.text = it.itemOverview
  if m.heroId <> it.itemId
    StopHero()
    m.backdropTick.control = "stop"
    m.backdrop.opacity = 0
    m.backdrop.uri = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/backdrop"
    ' Same image decoded tiny and stretched: a soft glow that fills the area around the trailer
    m.ambient.uri = m.backdrop.uri
  end if
  m.heroTimer.control = "stop"
  m.heroTimer.control = "start"
end sub

sub StopHero()
  m.veilTick.control = "stop"
  m.hero.control = "stop"
  m.hero.visible = false
  m.veil.opacity = 1
  m.heroId = ""
  m.cues = []
  m.caption.text = ""
  m.capBg.visible = false
end sub

sub OnHeroTimer()
  if m.current <> "home" or m.focused = invalid then return
  it = m.focused
  if it.itemTrailer <> "1" then return
  if it.itemId = m.heroId then return
  m.heroId = it.itemId
  apiKey = m.reg.Read("apiKey")
  base = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId
  content = CreateObject("roSGNode", "ContentNode")
  content.url = base + "/trailer?key=" + apiKey
  content.streamFormat = "mp4"
  content.HttpHeaders = ["Authorization:Bearer " + apiKey]
  m.hero.mute = true
  m.hero.loop = true
  m.hero.content = content
  m.hero.control = "play"
  ' Captions are drawn here, on top of the zoomed video, from the trailer's WebVTT
  m.cues = []
  if it.itemCaps = "1"
    m.capTask = CreateObject("roSGNode", "CaptionTask")
    m.capTask.ObserveField("cues", "OnCues")
    m.capTask.url = base + "/trailer.vtt?key=" + apiKey
    m.capTask.key = apiKey
    m.capTask.control = "RUN"
  end if
end sub

sub OnCues()
  if m.capTask <> invalid then m.cues = m.capTask.cues
end sub

' The backdrop shows until the trailer is actually playing, then the video fades in over it
sub OnHeroState()
  if m.hero.state = "playing" and m.current = "home" and not m.hero.visible
    m.hero.visible = true
    m.veil.opacity = 1
    m.veilTick.control = "start"
  end if
end sub

' The black veil (and the backdrop on it) fades out over the playing trailer
sub OnVeilTick()
  o = m.veil.opacity - 0.04
  if o <= 0
    o = 0
    m.veilTick.control = "stop"
  end if
  m.veil.opacity = o
end sub

sub OnRowsTick()
  o = m.rows.opacity + 0.06
  if o >= 1
    o = 1
    m.rowsTick.control = "stop"
  end if
  m.rows.opacity = o
end sub

sub OnBackdropLoad()
  if m.backdrop.loadStatus = "ready"
    m.backdrop.opacity = 0
    m.backdropTick.control = "start"
  end if
end sub

sub OnBackdropTick()
  o = m.backdrop.opacity + 0.06
  if o >= 1
    o = 1
    m.backdropTick.control = "stop"
  end if
  m.backdrop.opacity = o
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

sub OnSelect()
  at = m.rows.rowItemSelected
  if m.current <> "home" or at = invalid then return
  shelf = m.rows.content.GetChild(at[0])
  if shelf = invalid then return
  it = shelf.GetChild(at[1])
  if it = invalid or it.itemId = invalid then return
  print "Selected: " + it.itemId
  StartPlayback(it)
end sub

sub StyleTrickPlay()
  bar = m.player.trickPlayBar
  if bar = invalid then return
  bar.filledBarImageUri = "pkg:/images/filled-bar.png"
end sub

sub StartPlayback(it as Object)
  if m.current <> "home" then return
  print "Playing: " + it.itemId
  m.current = "starting"
  m.pending = it
  m.heroTimer.control = "stop"
  StopHero()
  m.rows.visible = false
  SetHomeLayers(false)
  m.keyCatcher.visible = true
  m.keyCatcher.SetFocus(true)
  ' The trailer and the movie cannot share the video decoder, so give it a moment to release
  m.startTimer.control = "start"
end sub

sub SetHomeLayers(on as Boolean)
  m.ambient.visible = on
  m.veil.visible = on
  m.scrim.visible = on
  m.coverLeft.visible = on
  m.coverBottom.visible = on
  m.brand.visible = on
  m.titleLabel.visible = on
  m.metaLabel.visible = on
  m.overviewLabel.visible = on
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
  if it.itemSubs = "1"
    subUrl = base + "/v1/items/" + it.itemId + "/subtitles/en?key=" + apiKey
    content.SubtitleTracks = [{ Language: "eng", TrackName: subUrl, Description: "English" }]
    m.player.globalCaptionMode = "On"
  end if
  m.player.content = content
  m.player.visible = true
  m.current = "player"
  m.player.control = "play"
  ShowScrubBar()
end sub

sub ShowScrubBar()
  bar = m.player.trickPlayBar
  if bar = invalid then return
  bar.visible = true
end sub

sub Scrub(dir as Integer)
  at = m.player.position
  if at = invalid then at = 0
  at = at + dir
  if at < 0 then at = 0
  m.player.seek = at
  m.player.control = "play"
  ShowScrubBar()
end sub

sub OnPlayerState()
  print "Player state: " + m.player.state
  if m.player.state = "playing" and m.current = "player"
    m.keyCatcher.SetFocus(true)
    ShowScrubBar()
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

sub ReturnHome()
  m.player.control = "stop"
  m.player.visible = false
  m.rows.visible = true
  SetHomeLayers(true)
  m.keyCatcher.visible = false
  m.rows.SetFocus(true)
  m.current = "home"
  ' Trailer resumes for whatever is focused
  m.heroTimer.control = "start"
end sub

function OnKeyEvent(k, p) as Boolean
  if not p then return false
  if k = "back" and (m.current = "player" or m.current = "starting")
    m.startTimer.control = "stop"
    ReturnHome()
    return true
  end if
  if m.current = "player"
    if k = "right" or k = "fastforward"
      Scrub(1)
      return true
    end if
    if k = "left" or k = "rewind"
      Scrub(-1)
      return true
    end if
    if k = "OK" or k = "play"
      if m.player.state = "paused"
        m.player.control = "resume"
      else
        m.player.control = "pause"
      end if
      ShowScrubBar()
      return true
    end if
  end if
  return false
end function
