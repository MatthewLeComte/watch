sub Init()
  m.grid = m.top.findNode("grid")
  m.player = m.top.findNode("player")
  m.player.visible = false
  m.keyCatcher = m.top.findNode("keyCatcher")
  m.player.ObserveField("state", "OnPlayerState")
  StyleTrickPlay()
  m.grid.ObserveField("itemSelected", "OnGridSelect")
  m.current = "grid"
  m.playTries = 0
  m.gridMode = 6
  m.grid.basePosterSize = [280, 420]
  m.grid.numColumns = 6
  m.grid.itemSpacing = [24, 24]
  m.grid.translation = [60, 140]
  m.header = m.top.findNode("header")
  m.titleLabel = m.top.findNode("title")
  
  ' Read from registry
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

sub LoadCatalog(items)
  print "LoadCatalog: " + StrI(items.Count()) + " items"
  root = CreateObject("roSGNode", "ContentNode")
  for each item in items
    n = root.CreateChild("ContentNode")
    n.AddField("itemId", "string", false)
    n.AddField("itemTitle", "string", false)
    n.SetFields(item)
  end for
  m.grid.content = root
  m.grid.SetFocus(true)
  print "Grid content set, kids: " + StrI(root.GetChildCount())
end sub

sub OnGridSelect()
  if m.current <> "grid" then return
  idx = m.grid.itemSelected
  if idx = invalid then return
  it = m.grid.content.GetChild(idx)
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
  print "Playing: " + it.itemId
  m.playTries = 0
  content = CreateObject("roSGNode", "ContentNode")
  apiKey = m.reg.Read("apiKey")
  bifUrl = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/trick.bif?key=" + apiKey
  content.url = "https://watch.cornerstonecoatings.com/v1/items/" + it.itemId + "/index.m3u8?key=" + apiKey
  content.streamFormat = "hls"
  content.title = it.itemTitle
  content.HttpHeaders = ["Authorization: Bearer " + apiKey]
  content.SDBifUrl = bifUrl
  content.HDBifUrl = bifUrl
  content.FHDBifUrl = bifUrl
  m.player.content = content
  m.player.visible = true
  m.grid.visible = false
  m.header.visible = false
  m.titleLabel.visible = false
  m.keyCatcher.visible = true
  m.player.control = "play"
  m.keyCatcher.SetFocus(true)
  ShowScrubBar()
  m.current = "player"
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
    ReturnToGrid()
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
    ReturnToGrid()
  end if
end sub

sub ReturnToGrid()
  m.player.control = "stop"
  m.player.visible = false
  m.grid.visible = true
  m.header.visible = true
  m.titleLabel.visible = true
  m.keyCatcher.visible = false
  m.grid.SetFocus(true)
  m.current = "grid"
end sub

function OnKeyEvent(k, p) as Boolean
  if not p then return false
  if (k = "OK" or k = "Play") and m.current = "grid"
    idx = m.grid.itemFocused
    if idx <> invalid and type(idx) = "Integer"
      it = m.grid.content.GetChild(idx)
      if it <> invalid and it.itemId <> invalid
        StartPlayback(it)
        return true
      end if
    end if
  end if
  if k = "back" and m.current = "player"
    ReturnToGrid()
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
