' Home: the focused title's trailer fades in on top with captions, shelves scroll below.
' Selecting a title plays it full screen. No sub views.
'
' Moving between titles is one fixed sequence so nothing flickers:
'   1. text updates at once and a curtain fades over the old picture
'   2. once focus rests, the new backdrop loads under the curtain
'   3. the curtain lifts to show the backdrop
'   4. when the trailer is really playing, the backdrop fades out to reveal it

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
  m.fadeTick = m.top.findNode("fadeTick")
  m.rowsTick = m.top.findNode("rowsTick")
  m.loadTick = m.top.findNode("loadTick")
  m.ambient = m.top.findNode("ambient")
  m.backdrop = m.top.findNode("backdrop")
  m.curtain = m.top.findNode("curtain")
  m.scrim = m.top.findNode("scrim")
  m.coverLeft = m.top.findNode("coverLeft")
  m.coverBottom = m.top.findNode("coverBottom")
  m.brand = m.top.findNode("brand")
  m.caption = m.top.findNode("caption")
  m.capBg = m.top.findNode("capBg")
  m.loading = m.top.findNode("loading")
  m.loadTitle = m.top.findNode("loadTitle")
  m.loadText = m.top.findNode("loadText")
  m.muteIcon = m.top.findNode("muteIcon")
  m.muteRing = m.top.findNode("muteRing")
  m.onMute = false

  m.player.visible = false
  m.player.ObserveField("state", "OnPlayerState")
  m.rows.ObserveField("rowItemFocused", "OnFocusChanged")
  m.rows.ObserveField("rowItemSelected", "OnSelect")
  m.heroTimer.ObserveField("fire", "OnHeroTimer")
  m.startTimer.ObserveField("fire", "OnStartTimer")
  m.fadeTick.ObserveField("fire", "OnFadeTick")
  m.rowsTick.ObserveField("fire", "OnRowsTick")
  m.loadTick.ObserveField("fire", "OnLoadTick")
  m.hero.ObserveField("state", "OnHeroState")
  m.hero.ObserveField("position", "OnHeroPosition")
  m.backdrop.ObserveField("loadStatus", "OnBackdropLoad")
  StyleTrickPlay()

  m.current = "home"
  m.playTries = 0
  m.focused = invalid
  m.heroId = ""
  m.shownId = ""
  m.pending = invalid
  m.cues = []
  m.capTask = invalid
  m.curtainTarget = 1.0
  m.backdropTarget = 0.0
  m.stopPending = false
  m.dots = 0
  m.reg = CreateObject("roRegistrySection", "WatchCache")
  ' Trailers play with sound. Up past the top shelf reaches the Sound toggle; the choice is remembered.
  m.muted = (m.reg.Read("heroMuted") = "1")
  ShowMuteIcon()

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
  print "Shelves: " + StrI(root.GetChildCount())
  ' Shelves fade in rather than pop in
  m.rows.opacity = 0
  m.rowsTick.control = "start"
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

' Step 1: text at once, curtain down over whatever is showing.
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
  m.caption.text = ""
  m.capBg.visible = false
  if it.itemId <> m.shownId
    m.shownId = ""
    m.stopPending = true
    m.curtainTarget = 1.0
    m.fadeTick.control = "start"
  end if
  m.heroTimer.control = "stop"
  m.heroTimer.control = "start"
end sub

' Step 2: focus has rested. Load the new backdrop (and trailer) while the curtain hides it.
sub OnHeroTimer()
  if m.current <> "home" or m.focused = invalid then return
  it = m.focused
  if it.itemId = m.shownId then return
  ' The old trailer stops once the curtain is down; never start the next one in the same instant
  if m.stopPending
    m.heroTimer.control = "start"
    return
  end if
  m.shownId = it.itemId
  m.backdrop.opacity = 1
  url = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/backdrop"
  m.backdrop.uri = url
  ' The same image decoded tiny and stretched: a soft glow around the trailer
  m.ambient.uri = url
  m.backdropTarget = 1.0
  if it.itemTrailer = "1" then StartHero(it)
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
  if it.itemCaps = "1"
    m.capTask = CreateObject("roSGNode", "CaptionTask")
    m.capTask.ObserveField("cues", "OnCues")
    m.capTask.url = base + "/trailer.vtt?key=" + apiKey
    m.capTask.key = apiKey
    m.capTask.control = "RUN"
  end if
end sub

sub StopHero()
  m.hero.control = "stop"
  m.hero.visible = false
  m.cues = []
  m.caption.text = ""
  m.capBg.visible = false
end sub

sub ShowMuteIcon()
  if m.muted
    m.muteIcon.uri = "pkg:/images/sound-off.png"
  else
    m.muteIcon.uri = "pkg:/images/sound-on.png"
  end if
end sub

' Up from the top shelf reaches the speaker icon (a ring shows it has focus); OK toggles; down returns.
sub FocusMute(on as Boolean)
  m.onMute = on
  m.muteRing.visible = on
  if on
    m.keyCatcher.visible = true
    m.keyCatcher.SetFocus(true)
  else
    m.keyCatcher.visible = false
    m.rows.SetFocus(true)
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

' Step 3: the backdrop is ready (or failed), so lift the curtain.
sub OnBackdropLoad()
  status = m.backdrop.loadStatus
  if (status = "ready" or status = "failed") and m.shownId <> ""
    m.curtainTarget = 0.0
    m.fadeTick.control = "start"
  end if
end sub

' Step 4: the trailer is playing, so fade the backdrop away to reveal it.
sub OnHeroState()
  if m.hero.state = "playing" and m.current = "home" and m.heroId = m.shownId and m.heroId <> ""
    m.hero.visible = true
    m.curtainTarget = 0.0
    m.backdropTarget = 0.0
    m.fadeTick.control = "start"
  end if
end sub

' One timer moves the curtain and the backdrop toward their targets.
sub OnFadeTick()
  settled = true
  c = m.curtain.opacity
  if c < m.curtainTarget
    c = c + 0.14
    if c > m.curtainTarget then c = m.curtainTarget
  else if c > m.curtainTarget
    c = c - 0.1
    if c < m.curtainTarget then c = m.curtainTarget
  end if
  if c <> m.curtainTarget then settled = false
  m.curtain.opacity = c

  b = m.backdrop.opacity
  if b < m.backdropTarget
    b = b + 0.08
    if b > m.backdropTarget then b = m.backdropTarget
  else if b > m.backdropTarget
    b = b - 0.05
    if b < m.backdropTarget then b = m.backdropTarget
  end if
  if b <> m.backdropTarget then settled = false
  m.backdrop.opacity = b

  ' Once the curtain is fully down, the old trailer can stop without anyone seeing it
  if m.stopPending and m.curtain.opacity >= 1
    m.stopPending = false
    m.heroId = ""
    StopHero()
  end if
  if settled then m.fadeTick.control = "stop"
end sub

sub OnRowsTick()
  o = m.rows.opacity + 0.06
  if o >= 1
    o = 1
    m.rowsTick.control = "stop"
  end if
  m.rows.opacity = o
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
  m.onMute = false
  m.muteRing.visible = false
  m.heroTimer.control = "stop"
  m.stopPending = false
  StopHero()
  m.heroId = ""
  m.shownId = ""
  m.rows.visible = false
  SetHomeLayers(false)
  ' Show the title straight away so the screen is never just black while the stream opens
  m.loadTitle.text = it.itemTitle
  m.dots = 0
  m.loadText.text = "Starting"
  m.loading.visible = true
  m.loadTick.control = "start"
  m.keyCatcher.visible = true
  m.keyCatcher.SetFocus(true)
  ' The trailer and the movie cannot share the video decoder, so give it a moment to release
  m.startTimer.control = "start"
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

sub SetHomeLayers(on as Boolean)
  m.ambient.visible = on
  m.backdrop.visible = on
  m.curtain.visible = on
  m.scrim.visible = on
  m.coverLeft.visible = on
  m.coverBottom.visible = on
  m.brand.visible = on
  m.muteIcon.visible = on
  m.muteRing.visible = on and m.onMute
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
  ' Seek previews: a BIF per title when one has been uploaded (the player ignores a missing one)
  bif = base + "/v1/items/" + it.itemId + "/trick.bif?key=" + apiKey
  content.SDBifUrl = bif
  content.HDBifUrl = bif
  content.FHDBifUrl = bif
  if it.itemSubs = "1"
    subUrl = base + "/v1/items/" + it.itemId + "/subtitles/en?key=" + apiKey
    content.SubtitleTracks = [{ Language: "eng", TrackName: subUrl, Description: "English" }]
    m.player.globalCaptionMode = "On"
  end if
  m.player.content = content
  m.player.visible = true
  m.current = "player"
  m.player.control = "play"
  ' The player itself takes focus so left/right/OK open its native seek bar, with BIF previews
  m.player.SetFocus(true)
end sub

sub OnPlayerState()
  print "Player state: " + m.player.state
  if m.player.state = "playing" and m.current = "player"
    HideLoading()
    m.player.SetFocus(true)
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
  HideLoading()
  m.rows.visible = true
  ' Come back behind a closed curtain so the home screen fades in cleanly
  m.curtain.opacity = 1
  m.curtainTarget = 1.0
  m.backdrop.opacity = 0
  m.backdropTarget = 0.0
  SetHomeLayers(true)
  m.keyCatcher.visible = false
  m.rows.SetFocus(true)
  m.current = "home"
  m.shownId = ""
  m.heroTimer.control = "start"
end sub

function OnKeyEvent(k, p) as Boolean
  if not p then return false
  if k = "back" and (m.current = "player" or m.current = "starting")
    m.startTimer.control = "stop"
    ReturnHome()
    return true
  end if
  if m.current = "home"
    ' Up from the top shelf reaches the Sound toggle; down comes back
    if m.onMute
      if k = "OK"
        OnMuteToggle()
        return true
      end if
      if k = "down" or k = "back"
        FocusMute(false)
        return true
      end if
      return true
    end if
    if k = "up" and m.rows.hasFocus()
      at = m.rows.rowItemFocused
      if at <> invalid and at[0] = 0
        FocusMute(true)
        return true
      end if
    end if
  end if
  return false
end function
