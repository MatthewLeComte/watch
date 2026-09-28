sub InitShelfView()
  m.titleLabel = m.top.findNode("titleLabel")
  m.rowList = m.top.findNode("rowList")

  m.top.ObserveField("title", "OnTitleChange")
  m.top.ObserveField("items", "OnItemsChange")
end sub

sub OnTitleChange()
  m.titleLabel.text = m.top.title
end sub

sub OnItemsChange()
  items = m.top.items
  if items = invalid or items.Count() = 0 then return

  content = CreateObject("roSGNode", "ContentNode")
  row = content.CreateChild("ContentNode")

  for each item in items
    node = row.CreateChild("ContentNode")
    node.SetFields(item)
  end for

  m.rowList.content = content
end sub