Sub Main()
  print "Watch build 23 start"
  EnsureKeys()
  catalog = FetchCatalog()
  if catalog = invalid then catalog = []
  
  ' Save to registry for scene to read (chunked: registry values are size-limited)
  reg = CreateObject("roRegistrySection", "WatchCache")
  json = "["
  for i = 0 to catalog.Count() - 1
    if i > 0 then json = json + ","
    it = catalog[i]
    t = JsonEscape(it.title)
    u = JsonEscape(it.HDPosterUrl)
    d = JsonEscape(it.itemId)
    ti = JsonEscape(it.itemTitle)
    json = json + "{""title"":""" + t + """,""HDPosterUrl"":""" + u + """,""itemId"":""" + d + """,""itemTitle"":""" + ti + """"
    json = json + ",""itemYear"":""" + JsonEscape(it.itemYear) + """,""itemRuntime"":""" + JsonEscape(it.itemRuntime) + """"
    json = json + ",""itemTrailer"":""" + JsonEscape(it.itemTrailer) + """,""itemSaved"":""" + JsonEscape(it.itemSaved) + """"
    json = json + ",""itemOverview"":""" + JsonEscape(it.itemOverview) + """"
    json = json + ",""itemCaps"":""" + JsonEscape(it.itemCaps) + """,""itemGenre"":""" + JsonEscape(it.itemGenre) + """,""itemAnim"":""" + JsonEscape(it.itemAnim) + """,""itemSubs"":""" + JsonEscape(it.itemSubs) + """,""itemSeries"":""" + JsonEscape(it.itemSeries) + """,""itemSeason"":""" + JsonEscape(it.itemSeason) + """,""itemEpisode"":""" + JsonEscape(it.itemEpisode) + """,""itemRental"":""" + JsonEscape(it.itemRental) + """}"
  end for
  json = json + "]"
  WriteChunks(reg, "catalog", json)
  
  screen = CreateObject("roSGScreen")
  port = CreateObject("roMessagePort")
  screen.SetMessagePort(port)
  scene = screen.CreateScene("MainScene")
  screen.Show()
  grid = scene.FindNode("grid")
  if grid = invalid
    print "grid NOT FOUND"
  else
    if grid.visible then print "grid visible" else print "grid HIDDEN"
    if grid.focusable then print "grid focusable" else print "grid NOT focusable"
    if grid.HasFocus() then print "grid already focused"
    if grid.SetFocus(true) then print "focus ok" else print "focus FAILED"
  end if

  while true
    msg = Wait(0, port)
    if msg <> invalid
      msgType = type(msg)
      if msgType = "roSGScreenEvent"
        if msg.IsScreenClosed()
          return
        end if
      end if
    end if
  end while
End Sub

function LibraryKey() as String
  return "__WATCH_KEY__"
end function

function GetDeviceId() as String
  reg = CreateObject("roRegistrySection", "WatchCache")
  id = reg.Read("deviceId")
  if id <> invalid and type(id) = "String" and Len(id) > 0 then return id
  id = CreateObject("roDeviceInfo").GetRandomUUID()
  reg.Write("deviceId", id)
  reg.Flush()
  return id
end function

sub EnsureKeys()
  reg = CreateObject("roRegistrySection", "WatchCache")
  reg.Write("apiKey", LibraryKey())
  reg.Write("deviceId", GetDeviceId())
  reg.Flush()
end sub

sub WriteChunks(reg as Object, key as String, value as String)
  n = 0
  i = 1
  total = Len(value)
  while i <= total
    reg.Write(key + StrI(n).Trim(), Mid(value, i, 10000))
    n = n + 1
    i = i + 10000
  end while
  reg.Write(key + "Chunks", StrI(n).Trim())
  reg.Flush()
end sub

function JsonEscape(value as Dynamic) as String
  if value = invalid then return ""
  s = value
  if type(s) <> "String" and type(s) <> "roString" then s = Str(s)
  s = s.Replace(Chr(92), Chr(92) + Chr(92))
  s = s.Replace(Chr(34), Chr(92) + Chr(34))
  return s
end function

function FetchCatalog() as Object
  u = CreateObject("roUrlTransfer")
  u.SetUrl("https://watch.cornerstonecoatings.com/v1/items")
  u.AddHeader("Authorization", "Bearer " + LibraryKey())
  resp = u.GetToString()
  print "Fetch len: " + StrI(Len(resp))
  if resp = invalid or Len(resp) = 0 then return invalid
  
  j = ParseJSON(resp)
  if j = invalid or j.items = invalid then return invalid
  
  items = []
  for each i in j.items
    l = i.title
    if i.year <> invalid and i.year <> 0
      l = l + " (" + StrI(i.year).Trim() + ")"
    end if
    item = {title: l, HDPosterUrl: i.posterUrl, itemId: i.id, itemTitle: i.title}
    item.itemYear = ""
    if i.year <> invalid and i.year <> 0 then item.itemYear = StrI(i.year).Trim()
    item.itemRuntime = ""
    if i.runtimeMin <> invalid and i.runtimeMin > 0 then item.itemRuntime = StrI(i.runtimeMin).Trim()
    ' 1 when the worker has a trailer file for this title
    item.itemTrailer = ""
    if type(i.trailerFile) = "String" and Len(i.trailerFile) > 0 then item.itemTrailer = "1"
    item.itemOverview = ""
    if type(i.overview) = "String" then item.itemOverview = Left(i.overview, 180)
    ' Episodes saved from an online source group by show, then season
    item.itemSeries = ""
    item.itemSeason = ""
    item.itemEpisode = ""
    if type(i.series) = "String" and Len(i.series) > 0
      item.itemSeries = i.series
      if i.season <> invalid then item.itemSeason = StrI(i.season).Trim()
      if i.episode <> invalid then item.itemEpisode = StrI(i.episode).Trim()
    end if
    item.itemSubs = ""
    if type(i.subtitles) = "roArray" and i.subtitles.Count() > 0 then item.itemSubs = "1"
    item.itemCaps = ""
    if type(i.trailerCaptions) = "String" and Len(i.trailerCaptions) > 0 then item.itemCaps = "1"
    ' First genre decides the shelf
    item.itemGenre = ""
    item.itemAnim = ""
    if type(i.genres) = "roArray"
      for each g in i.genres
        if g = "Animation"
          item.itemAnim = "1"
        else if item.itemGenre = ""
          item.itemGenre = g
        end if
      end for
    end if
    ' A rental has an expiry date and sits on the Rented shelf
    item.itemRental = ""
    if type(i.expiresAt) = "String" and Len(i.expiresAt) > 0 then item.itemRental = "1"
    ' A saved stream (rental) plays from its HLS playlist; everything else is one MP4 behind /media
    item.itemSaved = ""
    if type(i.hlsUrl) = "String" and Left(i.hlsUrl, 8) = "/v1/hls/" then item.itemSaved = i.hlsUrl
    items.Push(item)
  end for
  
  return items
end function
