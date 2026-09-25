sub FetchCatalog(screen as Object)
  print "FetchCatalog: entered"
  if screen = invalid
    print "FetchCatalog: screen is invalid"
    return
  end if
  scene = screen.GetScene()
  if scene = invalid
    print "FetchCatalog: scene is invalid"
    return
  end if
  status = scene.FindNode("status")
  if status = invalid
    print "FetchCatalog: status node not found"
    return
  end if

  url = "https://watch.cornerstonecoatings.com/v1/catalog"
  print "FetchCatalog: creating roHttpAgent"
  http = CreateObject("roHttpAgent")
  print "FetchCatalog: roHttpAgent=" + type(http)
  if http = invalid
    status.text = "roHttpAgent = invalid"
    return
  end if

  http.SetRequest("GET")
  http.AddHeader("Authorization", "Bearer a68596aee3429a00eea168ccc408af7f00235119bfce7e07152f92013cecc164")
  http.SetCertificatesFile("common:/certs/ca-bundle.crt")
  port = CreateObject("roMessagePort")
  http.SetMessagePort(port)
  print "FetchCatalog: request setup done"

  rc = http.AsyncSendRequest(url)
  print "FetchCatalog: AsyncSendRequest returned " + StrI(rc)
  if rc <> 0
    status.text = "AsyncSendRequest rc=" + StrI(rc)
    return
  end if

  msg = Wait(0, port)
  print "FetchCatalog: event type=" + type(msg)
  if type(msg) <> "roHttpAgentEvent"
    status.text = "event=" + type(msg)
    return
  end if

  code = http.GetResponseCode()
  print "FetchCatalog: HTTP " + StrI(code)
  if code <> 200
    body = http.GetResponseBody()
    if body <> invalid
      status.text = "HTTP " + StrI(code) + " " + Left(body, 500)
    else
      status.text = "HTTP " + StrI(code)
    end if
    return
  end if

  body = http.GetResponseBody()
  print "FetchCatalog: body len=" + StrI(Len(body))
  if body = invalid or Len(body) = 0
    status.text = "empty body"
    return
  end if

  json = ParseJSON(body)
  print "FetchCatalog: json=" + type(json)
  if json = invalid
    status.text = "ParseJSON invalid. body[0..200]=" + Left(body, 200)
    return
  end if
  if type(json) <> "roAssociativeArray"
    status.text = "json type=" + type(json)
    return
  end if
  if json.items = invalid
    status.text = "json.items invalid. keys=" + FormatJSON(json)
    return
  end if

  items = json.items
  print "FetchCatalog: items.Count=" + StrI(items.Count())
  status.text = "ok: " + StrI(items.Count()) + " items"
  status.visible = false

  headerCount = scene.FindNode("headerCount")
  if headerCount <> invalid
    headerCount.text = StrI(items.Count()) + " titles"
  end if

  grid = scene.FindNode("grid")
  if grid <> invalid
    print "FetchCatalog: building content"
    grid.content = BuildContentGlobal(items)
    grid.visible = true
    print "FetchCatalog: grid set"
  else
    print "FetchCatalog: grid not found"
  end if

  detail = scene.FindNode("detail")
  if detail <> invalid then detail.visible = false
  playerWrap = scene.FindNode("playerWrap")
  if playerWrap <> invalid then playerWrap.visible = false
  hud = scene.FindNode("hud")
  if hud <> invalid then hud.visible = true
end sub

function BuildContentGlobal(items as Object) as Object
  root = CreateObject("roSGNode", "ContentNode")
  for each item in items
    node = root.CreateChild("ContentNode")
    label = item.title
    if item.year <> invalid and item.year <> 0
      label = label + " (" + StrI(item.year).Trim() + ")"
    end if
    fields = {
      title: label
      HDPosterUrl: item.posterUrl
      itemId: item.id
      itemTitle: item.title
    }
    if item.backdropUrl <> invalid then fields.backdropUrl = item.backdropUrl
    if item.overview <> invalid then fields.itemOverview = item.overview
    if item.year <> invalid then fields.itemYear = item.year
    if item.runtimeMin <> invalid then fields.itemRuntime = item.runtimeMin
    if item.imdbId <> invalid then fields.itemImdbId = item.imdbId
    if item.genres <> invalid then fields.itemGenres = item.itemGenres
    node.SetFields(fields)
  end for
  return root
end function

function FormatJSON(obj as Object) as String
  result = ""
  if type(obj) = "roAssociativeArray"
    for each k in obj
      result = result + k + ","
    end for
  end if
  return result
end function
