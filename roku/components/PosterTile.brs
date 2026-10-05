sub OnContent()
  item = m.top.itemContent
  if item = invalid then return
  m.top.findNode("img").uri = item.HDPosterUrl
end sub
