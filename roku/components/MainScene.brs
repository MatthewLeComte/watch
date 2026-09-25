' MainScene: owns the grid -> detail -> player view stack.
' All cross-view communication goes through interface fields; component
' script functions are not callable across SceneGraph scopes.

sub Init()
  m.gridView = m.top.findNode("gridView")
  m.detailView = m.top.findNode("detailView")
  m.playerView = m.top.findNode("playerView")

  m.gridView.ObserveField("selectIndex", "OnGridSelect")
  m.detailView.ObserveField("playIndex", "OnDetailPlay")
  m.detailView.ObserveField("closeIndex", "OnDetailClose")
  m.playerView.ObserveField("finishedIndex", "OnPlaybackFinished")

  m.viewStack = []
  ShowView("grid")
end sub

sub ShowView(name as String)
  m.gridView.visible = (name = "grid")
  m.detailView.visible = (name = "detail")
  m.playerView.visible = (name = "player")
  if name = "grid"
    m.top.findNode("grid").SetFocus(true)
  else if name = "detail"
    m.top.findNode("playBtn").SetFocus(true)
  else if name = "player"
    m.top.findNode("player").SetFocus(true)
  end if
  m.currentView = name
  m.viewStack.Push(name)
end sub

sub PopView()
  if m.viewStack.Count() < 2 then return
  m.viewStack.Pop()
  m.viewStack.Pop()
  prev = m.viewStack[m.viewStack.Count() - 1]
  if prev <> "player"
    m.playerView.stopIndex = m.playerView.stopIndex + 1
    m.playerView.mediaUrl = ""
  end if
  ShowView(prev)
end sub

sub OnGridSelect()
  item = m.gridView.selectedItem
  if item = invalid then return
  m.detailView.itemContent = item
  ShowView("detail")
end sub

sub OnDetailPlay()
  item = m.detailView.itemContent
  if item = invalid then return
  id = item.GetField("itemId")
  if id = invalid or id = "" then return
  m.playerView.mediaUrl = MediaUrlFor(id)
  m.playerView.startIndex = m.playerView.startIndex + 1
  ShowView("player")
end sub

sub OnDetailClose()
  PopView()
end sub

sub OnPlaybackFinished()
  if m.currentView = "player"
    PopView()
  end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
  if not press then return false
  if key <> "back" then return false
  if m.currentView = "detail" or m.currentView = "player"
    PopView()
    return true
  end if
  if m.currentView = "grid" and m.gridView.hasError
    m.gridView.reloadIndex = m.gridView.reloadIndex + 1
    return true
  end if
  return false
end function
