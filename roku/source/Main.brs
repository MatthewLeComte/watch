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
    json = json + "{""title"":""" + t + """,""HDPosterUrl"":""" + u + """,""itemId"":""" + d + """,""itemTitle"":""" + ti + """}"
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
    items.Push(item)
  end for
  
  return items
end function
