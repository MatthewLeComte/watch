' Detail panel: item metadata with Play / Close buttons.
' Communicates via interface fields only (playIndex / closeIndex counters
' so repeated presses always fire observer callbacks).

sub Init()
  m.poster = m.top.findNode("poster")
  m.backdrop = m.top.findNode("backdrop")
  m.title = m.top.findNode("title")
  m.year = m.top.findNode("year")
  m.overview = m.top.findNode("overview")
  m.meta = m.top.findNode("meta")
  m.playBtn = m.top.findNode("playBtn")
  m.closeBtn = m.top.findNode("closeBtn")

  m.playBtn.ObserveField("buttonSelected", "OnPlay")
  m.closeBtn.ObserveField("buttonSelected", "OnClose")
  m.top.ObserveField("itemContent", "OnItemContent")
  if m.top.itemContent <> invalid
    OnItemContent()
  end if
end sub

sub OnItemContent()
  item = m.top.itemContent
  if item = invalid then return
  m.title.text = ValidStr(item.GetField("title"))
  year = item.GetField("year")
  m.year.text = ""
  if year <> invalid and year <> 0
    m.year.text = "(" + StrI(year).Trim() + ")"
  end if
  m.overview.text = ValidStr(item.GetField("overview"))
  m.meta.text = MetaLine(item)
  poster = item.GetField("HDPosterUrl")
  if poster <> invalid and poster <> ""
    m.poster.uri = poster
  end if
  backdrop = item.GetField("backdropUrl")
  if backdrop <> invalid and backdrop <> ""
    m.backdrop.uri = backdrop
  end if
end sub

function MetaLine(item as Object) as String
  parts = []
  runtime = item.GetField("runtimeMin")
  if runtime <> invalid and runtime > 0
    h = runtime \ 60
    mm = runtime mod 60
    if h > 0
      parts.Push(StrI(h).Trim() + "h " + StrI(mm).Trim() + "m")
    else
      parts.Push(StrI(mm).Trim() + "m")
    end if
  end if
  genres = item.GetField("genres")
  if genres <> invalid
    for each g in genres
      parts.Push(g)
    end for
  end if
  out = ""
  for each p in parts
    if out <> "" then out = out + "  |  "
    out = out + p
  end for
  return out
end function

sub OnPlay()
  m.playBtn.buttonSelected = false
  m.top.playIndex = m.top.playIndex + 1
end sub

sub OnClose()
  m.closeBtn.buttonSelected = false
  m.top.closeIndex = m.top.closeIndex + 1
end sub
