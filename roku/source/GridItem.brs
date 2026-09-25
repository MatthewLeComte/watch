sub InitGridItem()
  m.poster = m.top.findNode("poster")
  m.title = m.top.findNode("title")
  m.titleOverlay = m.top.findNode("titleOverlay")
end sub

sub OnContentChange()
  content = m.top.itemContent
  if content = invalid then return
  if content.HDPosterUrl <> invalid then m.poster.uri = content.HDPosterUrl
  m.title.text = content.title
end sub

sub OnFocusChange()
  m.titleOverlay.visible = m.top.itemHasFocus
end sub
