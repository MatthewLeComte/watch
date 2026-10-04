sub Init()
  m.bg = m.top.findNode("bg")
  m.grid = m.top.findNode("grid")
  m.detail = m.top.findNode("detail")
  m.playerWrap = m.top.findNode("playerWrap")
  m.player = m.playerWrap.findNode("player")
  m.resolveView = m.top.findNode("resolveView")
  m.searchView = m.top.findNode("searchView")
  m.status = m.top.findNode("status")
  m.hud = m.top.findNode("hud")
  m.headerCount = m.hud.findNode("headerCount")

  m.stack = []
  m.current = invalid
  m.detailItem = invalid
  m.resolvedItem = invalid
  m.playerStarted = false
  m.itemCount = 0

  ' HomeGridView reports selection via selectedItem + selectIndex
  m.grid.ObserveField("selectedItem", "OnItemSelected")
  m.grid.ObserveField("hasError", "OnGridError")
  m.grid.ObserveField("selectIndex", "OnGridSelectIndex")

  ' DetailView reports play via selectedItem + selectIndex
  m.detail.ObserveField("selectedItem", "OnDetailPlay")
  m.detail.ObserveField("selectIndex", "OnDetailSelectIndex")

  ' SearchView reports selection
  m.searchView.ObserveField("selectedItem", "OnSearchSelect")
  m.searchView.ObserveField("selectIndex", "OnSearchSelectIndex")

  m.player.ObserveField("state", "OnPlayerState")
  m.resolveView.ObserveField("resolved", "OnResolved")
end sub

sub OnGridSelectIndex()
  ' Triggered when grid.selectIndex changes (selection made)
  item = m.grid.selectedItem
  if item = invalid then return

  m.detailItem = item
  m.detail.itemContent = item
  PushView("detail")
end sub

sub OnDetailSelectIndex()
  ' Triggered when detail.selectIndex changes (Play pressed)
  item = m.detail.selectedItem
  if item = invalid then return

  m.detailItem = item

  ' Check if this is a source that needs resolution (rivestream, etc.)
  itemId = item.itemId
  if itemId <> invalid and Left(itemId, 10) = "rivestream:" then
    ' Show resolve view and start resolution
    m.resolveView.visible = true
    m.resolveView.sourceId = itemId
    PushView("resolve")
  else
    ' Direct media playback (MP4 from worker)
    PlayDirectMedia(item)
  end if
end sub

sub OnDetailPlay()
  ' Also triggered on play press
  OnDetailSelectIndex()
end sub

sub OnSearchSelect()
  item = m.searchView.selectedItem
  if item = invalid then return

  m.detailItem = item
  m.detail.itemContent = item
  PushView("detail")
end sub

sub OnSearchSelectIndex()
  OnSearchSelect()
end sub

sub OnItemSelected()
  ' Legacy - not used with new components
end sub

sub OnGridError()
  if m.grid.hasError then
    m.status.text = "Failed to load library"
    m.status.visible = true
  end if
end sub

sub PlayDirectMedia(item as Object)
  id = item.itemId
  if id = invalid then return

  content = CreateObject("roSGNode", "ContentNode")
  content.title = item.itemTitle
  hls = item.itemHlsUrl
  if hls <> invalid and Left(hls, 8) = "/v1/hls/" then
    ' Saved stream: HLS chunks in R2, no single file behind /media
    content.url = "https://watch.cornerstonecoatings.com" + hls
    content.streamformat = "hls"
  else
    content.url = "https://watch.cornerstonecoatings.com/v1/items/" + id + "/media"
    content.streamformat = "mp4"
  end if
  ' The Video node sends these on every request, chunks included. Format is "name:value".
  content.HttpHeaders = ["Authorization:Bearer " + LibraryKey()]

  m.playerStarted = false
  m.player.content = content
  PushView("player")
  m.player.control = "play"
end sub

sub OnResolved()
  resolved = m.resolveView.resolved
  if resolved = invalid then return

  ' Store resolved data for playback
  m.resolvedItem = resolved
  m.resolvedItem.title = m.detailItem.title
  m.resolvedItem.itemId = m.detailItem.itemId

  ' If there was an error, go back to detail
  if m.resolveView.hasError then
    PopView()
    return
  end if

  ' Auto-play after successful resolve
  PlayResolvedItem()
end sub

sub PlayResolvedItem()
  if m.resolvedItem = invalid then return
  if m.resolvedItem.hlsUrl = invalid or m.resolvedItem.hlsUrl = "" then return

  content = CreateObject("roSGNode", "ContentNode")
  content.url = m.resolvedItem.hlsUrl
  content.title = m.resolvedItem.title
  content.streamformat = "hls"

  ' Pass cookies if available
  if m.resolvedItem.cookieHeader <> invalid and m.resolvedItem.cookieHeader <> "" then
    content.HttpHeaders = { "Cookie": m.resolvedItem.cookieHeader }
  end if

  m.playerStarted = false
  m.player.content = content
  PushView("player")
  m.player.control = "play"
end sub

sub OnPlayerState()
  state = m.player.state
  if state = "playing" or state = "buffering" then m.playerStarted = true
  if m.playerStarted and (state = "finished" or state = "error")
    m.playerStarted = false
    m.player.control = "stop"
    PopView()
  end if
end sub

sub ShowView(name as String)
  m.grid.visible = (name = "grid")
  m.detail.visible = (name = "detail")
  m.playerWrap.visible = (name = "player")
  m.resolveView.visible = (name = "resolve")
  m.searchView.visible = (name = "search")
  m.hud.visible = (name <> "player")

  if name = "grid"
    m.grid.SetFocus(true)
  else if name = "detail"
    m.detail.visible = true
    ' DetailView handles its own focus via OnVisibleChange
  else if name = "resolve"
    ' ResolveView handles its own focus internally
  else if name = "search"
    m.searchView.visible = true
    ' SearchView handles its own focus via OnVisibleChange
  end if
  m.current = name
end sub

sub PushView(name as String)
  if m.current <> invalid then m.stack.Push(m.current)
  ShowView(name)
end sub

sub PopView()
  if m.stack.Count() = 0 then return
  prev = m.stack.Pop()
  ShowView(prev)
end sub

function OnKeyEvent(key as String, press as Boolean) as Boolean
  if press and key = "back"
    if m.current = "detail"
      PopView()
      return true
    end if
    if m.current = "resolve"
      PopView()
      return true
    end if
  end if
  return false
end function