sub InitShelfTitle()
  m.title = m.top.findNode("title")
end sub

sub init()
  ' Called when section data is set
  if m.top.sectionLabel <> invalid
    m.title.text = m.top.sectionLabel
  end if
end sub