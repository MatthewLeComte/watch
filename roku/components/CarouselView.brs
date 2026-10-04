sub InitCarouselView()
  m.top.itemComponentName = "CarouselItem"
  m.top.itemSize = [1800, 162]
  m.top.rowItemSize = [[108, 162]]
  m.top.rowItemSpacing = [[12, 0]]
  m.top.numRows = 1
  m.top.showRowLabel = [false]
  m.top.rowFocusAnimationStyle = "floatingFocus"
  m.top.translation = [20, 1020]
end sub

sub OnCarouselItems()
  row = CreateObject("roSGNode", "ContentNode")
  for each item in m.top.items
    node = row.CreateChild("ContentNode")
    node.SetFields(item)
  end for
  content = CreateObject("roSGNode", "ContentNode")
  content.AppendChild(row)
  m.top.content = content
end sub
