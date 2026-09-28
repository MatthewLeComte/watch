sub InitHeroView()
  m.backdrop = m.top.findNode("backdrop")
  m.fadeGradient = m.top.findNode("fadeGradient")
  m.titleLabel = m.top.findNode("title")
  m.metaLabel = m.top.findNode("meta")
  m.overviewLabel = m.top.findNode("overview")
  m.playBtn = m.top.findNode("playBtn")
  m.playBg = m.playBtn.findNode("bg")
  m.playText = m.playBtn.findNode("text")

  m.top.ObserveField("itemContent", "OnContentChange")
  m.playBtn.ObserveField("buttonSelected", "OnPlaySelected")
end sub

sub OnContentChange()
  content = m.top.itemContent
  if content = invalid then return

  if content.backdropUrl <> invalid
    m.backdrop.uri = content.backdropUrl
  end if

  m.titleLabel.text = content.itemTitle

  meta = ""
  if content.itemYear <> invalid and content.itemYear <> 0
    meta = StrI(content.itemYear).Trim()
  end if
  if content.itemRuntime <> invalid and content.itemRuntime > 0
    if meta <> "" then meta = meta + "  •  "
    meta = meta + StrI(content.itemRuntime).Trim() + " min"
  end if
  if content.itemImdbId <> invalid and content.itemImdbId <> ""
    if meta <> "" then meta = meta + "  •  "
    meta = meta + content.itemImdbId
  end if
  m.metaLabel.text = meta

  overview = content.itemOverview
  if overview = invalid then overview = ""
  m.overviewLabel.text = overview

  ' Animate fade gradient
  animateFadeGradient()
end sub

sub animateFadeGradient()
  ' Create gradient: transparent at top, black at bottom
  ' Using a solid color with opacity animation for simplicity
  m.fadeGradient.color = "0x00000080"
end sub

sub OnPlaySelected()
  focused = m.playBtn.buttonSelected
  if focused
    m.playBg.color = "0xFF1A2BFF"  ' Brighter red on focus
    m.playText.color = "0xFFFFFFFF"
    m.playBtn.scale = [1.05, 1.05]
  else
    m.playBg.color = "0xE50914FF"
    m.playText.color = "0xFFFFFFFF"
    m.playBtn.scale = [1.0, 1.0]
  end if
end sub