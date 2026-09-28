sub InitShelfItem()
  m.poster = m.top.findNode("poster")
  m.focusRing = m.top.findNode("focusRing")
  m.focusBorder = m.top.findNode("focusBorder")
  m.progressOverlay = m.top.findNode("progressOverlay")
  m.progressBar = m.top.findNode("progressBar")
end sub

sub OnContentChange()
  content = m.top.itemContent
  if content = invalid then return

  if content.HDPosterUrl <> invalid
    m.poster.uri = content.HDPosterUrl
  end if
end sub

sub OnFocusChange()
  focused = m.top.itemHasFocus
  m.focusRing.visible = focused
  m.focusBorder.visible = focused

  if focused
    m.top.scale = [1.06, 1.06]
    m.top.translation = [-8, -8]
  else
    m.top.scale = [1.0, 1.0]
    m.top.translation = [0, 0]
  end if
end sub

sub OnProgressChange()
  p = m.top.progress
  if p > 0 and p < 1.0
    m.progressOverlay.visible = true
    m.progressBar.width = 280 * p
  else
    m.progressOverlay.visible = false
  end if
end sub