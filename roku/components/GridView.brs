' GridView: fetches the catalog (registry cache + TTL), renders the
' PosterGrid, reports selection via selectedItem + selectIndex counter.
' Self-contained: MainScene never calls functions here, it only observes
' interface fields (SceneGraph components cannot share function scope).

sub Init()
  m.grid = m.top.findNode("grid")
  m.loading = m.top.findNode("loading")
  m.errorBox = m.top.findNode("errorBox")
  m.errorLabel = m.top.findNode("errorLabel")
  m.retryBtn = m.top.findNode("retryBtn")

  m.grid.ObserveField("itemSelected", "OnItemSelected")
  m.retryBtn.ObserveField("buttonSelected", "OnRetry")
  m.top.ObserveField("reloadIndex", "OnReload")

  RefreshCatalog()
end sub

sub OnReload()
  RefreshCatalog()
end sub

sub OnRetry()
  m.retryBtn.buttonSelected = false
  RefreshCatalog()
end sub

sub OnItemSelected()
  idx = m.grid.itemSelected
  if idx = invalid then return
  node = m.grid.content.GetChild(idx)
  if node = invalid then return
  m.top.selectedItem = node
  m.top.selectIndex = m.top.selectIndex + 1
end sub

sub RefreshCatalog()
  m.grid.visible = false
  m.errorBox.visible = false
  m.loading.visible = true
  items = GetCatalogItems()
  if items = invalid or items.Count() = 0
    m.loading.visible = false
    m.errorLabel.text = "Couldn't load your library. Check the network connection, then retry."
    m.errorBox.visible = true
    m.top.hasError = true
    m.retryBtn.SetFocus(true)
    return
  end if
  root = CreateObject("roSGNode", "ContentNode")
  for each item in items
    n = root.CreateChild("ContentNode")
    n.SetFields(item)
  end for
  m.grid.content = root
  m.top.hasError = false
  m.loading.visible = false
  m.errorBox.visible = false
  m.grid.visible = true
  m.grid.SetFocus(true)
end sub

function GetCatalogItems() as Object
  cached = ReadCatalogCache()
  if cached <> invalid then return cached
  items = FetchCatalog()
  if items <> invalid then WriteCatalogCache(items)
  return items
end function

function FetchCatalog() as Object
  u = CreateObject("roUrlTransfer")
  u.SetUrl(CatalogUrl())
  u.SetCertificatesFile("common:/certs/ca-bundle.crt")
  headers = AuthHeaders()
  u.AddHeader("X-Key-ID", headers["X-Key-ID"])
  u.AddHeader("X-API-Key", headers["X-API-Key"])
  u.AddHeader("X-Device-ID", headers["X-Device-ID"])
  u.RetainBodyOnError(true)
  resp = u.GetToString()
  if u.GetResponseCode() <> 200 or resp = invalid
    print "catalog fetch failed: "; u.GetResponseCode()
    return invalid
  end if
  parsed = ParseJSON(resp)
  if parsed = invalid or parsed.items = invalid then return invalid
  items = []
  for each raw in parsed.items
    gridItem = {}
    gridItem.title = GridLabel(raw)
    gridItem.HDPosterUrl = ValidStr(raw.posterUrl)
    gridItem.itemId = ValidStr(raw.id)
    gridItem.itemTitle = ValidStr(raw.title)
    gridItem.year = SafeInt(raw.year)
    gridItem.overview = ValidStr(raw.overview)
    gridItem.runtimeMin = SafeInt(raw.runtimeMin)
    gridItem.genres = SafeArray(raw.genres)
    gridItem.backdropUrl = ValidStr(raw.backdropUrl)
    items.Push(gridItem)
  end for
  print "catalog: fetched "; items.Count(); " items"
  return items
end function

function GridLabel(raw as Object) as String
  label = ValidStr(raw.title)
  if raw.year <> invalid and raw.year <> 0
    label = label + " (" + StrI(raw.year).Trim() + ")"
  end if
  return label
end function

function ReadCatalogCache() as Object
  reg = RegistrySection()
  stored = reg.Read("catalog")
  ts = reg.Read("catalogTs")
  if stored = invalid or ts = invalid then return invalid
  now = CreateObject("roDateTime").AsSeconds()
  if now - Val(ts) > CacheTtlSec()
    print "catalog: cache expired"
    return invalid
  end if
  cached = ParseJSON(stored)
  if cached = invalid or type(cached) <> "roArray" or cached.Count() = 0 then return invalid
  print "catalog: loaded "; cached.Count(); " items from cache"
  return cached
end function

sub WriteCatalogCache(items as Object)
  payload = FormatJSON(items)
  if payload = invalid then return
  ' Registry values are size-limited; skip caching rather than truncating.
  if Len(payload) > 12000
    print "catalog: too large to cache, skipping"
    return
  end if
  reg = RegistrySection()
  reg.Write("catalog", payload)
  reg.Write("catalogTs", StrI(CreateObject("roDateTime").AsSeconds()).Trim())
  reg.Flush()
end sub
