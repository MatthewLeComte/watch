sub InitCarouselItem()
  m.poster = m.top.findNode("poster")
  m.focusRing = m.top.findNode("focusRing")
  m.focusBorder = m.top.findNode("focusBorder")
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
    ' Animate focus ring
    m.focusRing.color = "0xE5091480"
    m.top.scale = [1.08, 1.08]
    m.top.translation = [-4, -4]
  else
    m.top.scale = [1.0, 1.0]
    m.top.translation = [0, 0]
  end if
end sub