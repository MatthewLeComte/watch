sub Init()
  m.bg = m.top.findNode("bg")
  m.grid = m.top.findNode("grid")
  m.detail = m.top.findNode("detail")
  m.playerWrap = m.top.findNode("playerWrap")
  m.player = m.playerWrap.findNode("player")
  m.status = m.top.findNode("status")
  m.hud = m.top.findNode("hud")
  m.headerCount = m.hud.findNode("headerCount")

  m.titleLabel = m.detail.findNode("title")
  m.metaLabel = m.detail.findNode("meta")
  m.genresLabel = m.detail.findNode("genres")
  m.overviewLabel = m.detail.findNode("overview")
  m.backdrop = m.detail.findNode("backdrop")
  m.playGroup = m.detail.findNode("play")
  m.playBg = m.playGroup.findNode("bg")
  m.playText = m.playGroup.findNode("text")

  m.stack = []
  m.current = invalid
  m.detailItem = invalid
  m.playerStarted = false
  m.itemCount = 0

  m.grid.ObserveField("itemSelected", "OnItemSelected")
  m.playGroup.ObserveField("itemHasFocus", "OnPlayFocus")
  m.player.ObserveField("state", "OnPlayerState")
end sub

sub BuildContent(items as Object) as Object
  root = CreateObject("roSGNode", "ContentNode")
  for each item in items
    node = root.CreateChild("ContentNode")
    label = item.title
    if item.year <> invalid and item.year <> 0
      label = label + " (" + StrI(item.year).Trim() + ")"
    end if
    fields = {
      title: label
      HDPosterUrl: item.posterUrl
      itemId: item.id
      itemTitle: item.title
    }
    if item.backdropUrl <> invalid then fields.backdropUrl = item.backdropUrl
    if item.overview <> invalid then fields.itemOverview = item.overview
    if item.year <> invalid then fields.itemYear = item.year
    if item.runtimeMin <> invalid then fields.itemRuntime = item.runtimeMin
    if item.imdbId <> invalid then fields.itemImdbId = item.imdbId
    if item.genres <> invalid then fields.itemGenres = item.genres
    node.SetFields(fields)
  end for
  return root
end sub

sub OnItemSelected()
  if m.current <> "grid" then return
  rowIndex = m.grid.rowItemSelected[0]
  itemIndex = m.grid.rowItemSelected[1]
  content = m.grid.content
  if content = invalid then return
  row = content.GetChild(rowIndex)
  if row = invalid then return
  item = row.GetChild(itemIndex)
  if item = invalid then return

  m.detailItem = item
  PopulateDetail(item)
  PushView("detail")
end sub

sub PopulateDetail(item as Object)
  if item.backdropUrl <> invalid then m.backdrop.uri = item.backdropUrl
  m.titleLabel.text = item.itemTitle

  meta = ""
  if item.itemYear <> invalid and item.itemYear <> 0
    meta = StrI(item.itemYear).Trim()
  end if
  if item.itemRuntime <> invalid and item.itemRuntime > 0
    if meta <> "" then meta = meta + "  •  "
    meta = meta + StrI(item.itemRuntime).Trim() + " min"
  end if
  if item.itemImdbId <> invalid and item.itemImdbId <> ""
    if meta <> "" then meta = meta + "  •  "
    meta = meta + item.itemImdbId
  end if
  m.metaLabel.text = meta

  genres = item.itemGenres
  gText = ""
  if genres <> invalid and genres.Count() > 0
    for each g in genres
      if gText <> "" then gText = gText + "  •  "
      gText = gText + g
    end for
  end if
  m.genresLabel.text = gText

  overview = item.itemOverview
  if overview = invalid then overview = ""
  m.overviewLabel.text = overview
end sub

sub OnPlayFocus()
  focused = m.playGroup.itemHasFocus
  if focused
    m.playBg.color = "0xFFFFFFFF"
    m.playText.color = "0x000000FF"
  else
    m.playBg.color = "0x808080FF"
    m.playText.color = "0xFFFFFFFF"
  end if
end sub

sub OnPlayPressed()
  if m.detailItem = invalid then return
  id = m.detailItem.itemId
  if id = invalid then return

  content = CreateObject("roSGNode", "ContentNode")
  content.url = "https://watch.cornerstonecoatings.com/v1/items/" + id + "/media"
  content.title = m.detailItem.title
  content.streamformat = "mp4"

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
  m.hud.visible = (name <> "player")
  if name = "grid"
    m.grid.SetFocus(true)
  else if name = "detail"
    m.playGroup.SetFocus(true)
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
  if press and key = "OK" and m.current = "detail"
    OnPlayPressed()
    return true
  end if
  if press and key = "back"
    if m.current = "detail"
      PopView()
      return true
    end if
  end if
  return false
end function
