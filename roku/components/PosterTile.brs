sub OnContent()
  item = m.top.itemContent
  if item = invalid then return
  m.top.findNode("img").uri = item.HDPosterUrl
end sub

' The outline fades with focus as it moves between posters, and only shows while the shelves have focus.
sub OnFocus()
  shown = 0.0
  if m.top.rowListHasFocus and m.top.rowHasFocus then shown = m.top.focusPercent
  m.top.findNode("ring").opacity = shown
end sub
