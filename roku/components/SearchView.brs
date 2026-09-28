sub InitSearchView()
  m.searchBar = m.top.findNode("searchBar")
  m.queryBox = m.top.findNode("queryBox")
  m.resultsGrid = m.top.findNode("resultsGrid")
  m.loading = m.top.findNode("loading")
  m.emptyState = m.top.findNode("emptyState")

  m.queryBox.ObserveField("text", "OnQueryChange")
  m.resultsGrid.ObserveField("itemSelected", "OnItemSelected")
  m.top.ObserveField("searchQuery", "OnSearchQueryChange")
end sub

sub OnVisibleChange()
  if m.top.visible then
    m.queryBox.SetFocus(true)
    m.queryBox.text = ""
    m.top.searchQuery = ""
    m.resultsGrid.content = invalid
    m.emptyState.visible = false
  end if
end sub

sub OnSearchQueryChange()
  query = m.top.searchQuery
  if query <> invalid and query <> "" and Len(query) >= 2 then
    PerformSearch(query)
  else
    m.resultsGrid.content = invalid
    m.emptyState.visible = false
  end if
end sub

sub OnQueryChange()
  m.top.searchQuery = m.queryBox.text
end sub

sub PerformSearch(query as String)
  m.loading.visible = true
  m.resultsGrid.content = invalid
  m.emptyState.visible = false

  url = "https://watch.cornerstonecoatings.com/v1/sources/search?q=" + Escape(query) + "&source=meta"

  u = CreateObject("roUrlTransfer")
  u.SetUrl(url)
  u.SetCertificatesFile("common:/certs/ca-bundle.crt")
  headers = GetAuthHeaders()
  u.AddHeader("X-Key-ID", headers["X-Key-ID"])
  u.AddHeader("X-API-Key", headers["X-API-Key"])
  u.AddHeader("X-Device-ID", headers["X-Device-ID"])
  u.RetainBodyOnError(true)

  resp = u.GetToString()
  code = u.GetResponseCode()

  m.loading.visible = false

  if code <> 200 or resp = invalid
    m.emptyState.visible = true
    return
  end if

  parsed = ParseJSON(resp)
  if parsed = invalid or type(parsed) <> "roArray" or parsed.Count() = 0
    m.emptyState.visible = true
    return
  end if

  ' Build results grid content
  content = CreateObject("roSGNode", "ContentNode")
  section = content.CreateChild("ContentNode")

  for each raw in parsed
    node = section.CreateChild("ContentNode")
    node.title = raw.title
    if raw.year <> invalid and raw.year <> 0
      node.title = node.title + " (" + StrI(raw.year).Trim() + ")"
    end if
    node.HDPosterUrl = ValidStr(raw.poster)
    node.itemId = ValidStr(raw.id)
    node.itemTitle = ValidStr(raw.title)
    node.year = SafeInt(raw.year)
    node.itemOverview = ""
    node.itemYear = SafeInt(raw.year)
    node.itemRuntime = 0
    node.itemImdbId = ValidStr(raw.imdbId)
    node.itemGenres = []
    node.backdropUrl = ""
  end for

  m.resultsGrid.content = content
  m.emptyState.visible = false
end sub

sub OnItemSelected()
  idx = m.resultsGrid.itemSelected
  if idx = invalid then return

  content = m.resultsGrid.content
  if content = invalid then return

  section = content.GetChild(0)
  if section = invalid then return

  item = section.GetChild(idx)
  if item = invalid then return

  m.top.selectedItem = item
  m.top.selectIndex = m.top.selectIndex + 1
end sub

function GetAuthHeaders() as Object
  reg = CreateObject("roRegistrySection", "watch")
  headers = {}
  headers["X-Key-ID"] = reg.Read("key_id")
  headers["X-API-Key"] = reg.Read("api_key")
  headers["X-Device-ID"] = reg.Read("device_id")
  if headers["X-Key-ID"] = invalid then headers["X-Key-ID"] = ""
  if headers["X-API-Key"] = invalid then headers["X-API-Key"] = ""
  if headers["X-Device-ID"] = invalid then headers["X-Device-ID"] = ""
  return headers
end function