sub InitDetailView()
  m.backdrop = m.top.findNode("backdrop")
  m.scrimGradient = m.top.findNode("scrimGradient")
  m.titleLabel = m.top.findNode("title")
  m.metaLabel = m.top.findNode("meta")
  m.genresLabel = m.top.findNode("genres")
  m.overviewLabel = m.top.findNode("overview")
  m.playBtn = m.top.findNode("playBtn")
  m.playBg = m.playBtn.findNode("bg")
  m.playText = m.playBtn.findNode("text")
  m.downloadBtn = m.top.findNode("downloadBtn")
  m.downloadBg = m.downloadBtn.findNode("bg")
  m.downloadText = m.downloadBtn.findNode("text")

  m.top.ObserveField("itemContent", "OnContentChange")
  m.playBtn.ObserveField("buttonSelected", "OnPlayFocus")
  m.downloadBtn.ObserveField("buttonSelected", "OnDownloadFocus")
  m.playBtn.ObserveField("buttonSelected", "OnPlayPressed")
  m.downloadBtn.ObserveField("buttonSelected", "OnDownloadPressed")
end sub

sub OnVisibleChange()
  if m.top.visible then
    m.playBtn.SetFocus(true)
  end if
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

  genres = content.itemGenres
  gText = ""
  if genres <> invalid and genres.Count() > 0
    for each g in genres
      if gText <> "" then gText = gText + "  •  "
      gText = gText + g
    end for
  end if
  m.genresLabel.text = gText

  overview = content.itemOverview
  if overview = invalid then overview = ""
  m.overviewLabel.text = overview

  ' Update download button text based on state
  if content.itemDownloaded <> invalid and content.itemDownloaded = true
    m.downloadText.text = "Downloaded"
    m.downloadBg.color = "0x444444FF"
    m.downloadBtn.enabled = false
  else
    m.downloadText.text = "Download"
    m.downloadBg.color = "0x333333FF"
    m.downloadBtn.enabled = true
  end if
end sub

sub OnPlayFocus()
  focused = m.playBtn.buttonSelected
  if focused
    m.playBg.color = "0xFF1A2BFF"
    m.playBtn.scale = [1.05, 1.05]
  else
    m.playBg.color = "0xE50914FF"
    m.playBtn.scale = [1.0, 1.0]
  end if
end sub

sub OnDownloadFocus()
  focused = m.downloadBtn.buttonSelected
  if focused and m.downloadBtn.enabled
    m.downloadBg.color = "0x444444FF"
    m.downloadBtn.scale = [1.05, 1.05]
  else
    m.downloadBg.color = "0x333333FF"
    m.downloadBtn.scale = [1.0, 1.0]
  end if
end sub

sub OnPlayPressed()
  if m.playBtn.buttonSelected then
    m.top.selectedItem = m.top.itemContent
    m.top.selectIndex = m.top.selectIndex + 1
  end if
end sub

sub OnDownloadPressed()
  if m.downloadBtn.buttonSelected and m.downloadBtn.enabled then
    ' TODO: Trigger download via worker
    print "Download requested for: "; m.top.itemContent.itemId
  end if
end sub