' HomeGridView: MarkupGrid-based home screen with Hero + Carousel + Shelves
' Fetches catalog, builds sections, reports selection via selectedItem + selectIndex

sub Init()
  m.grid = m.top.findNode("grid")
  m.homeHeader = m.top.findNode("homeHeader")
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

  ' For MarkupGrid, itemSelected returns section and item indices
  sectionIdx = idx[0]
  itemIdx = idx[1]

  content = m.grid.content
  if content = invalid then return

  section = content.GetChild(sectionIdx)
  if section = invalid then return

  item = section.GetChild(itemIdx)
  if item = invalid then return

  m.top.selectedItem = item
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

  BuildHomeGrid(items)

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
    ' Additional fields for detail view
    gridItem.itemOverview = ValidStr(raw.overview)
    gridItem.itemYear = SafeInt(raw.year)
    gridItem.itemRuntime = SafeInt(raw.runtimeMin)
    gridItem.itemImdbId = ValidStr(raw.imdbId)
    gridItem.itemGenres = SafeArray(raw.genres)
    ' Download state (will be populated by app)
    gridItem.itemDownloaded = false
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

sub BuildHomeGrid(items as Object)
  ' Build shelves (sections) from items
  shelves = BuildShelves(items)

  ' Set hero item (first movie or featured)
  heroItem = shelves.heroItem
  if heroItem <> invalid
    m.homeHeader.heroItem = heroItem
    m.homeHeader.carouselItems = shelves.allItems
  end if

  ' Build MarkupGrid content
  gridContent = CreateObject("roSGNode", "ContentNode")

  for each shelf in shelves.sections
    if shelf.items.Count() > 0
      section = gridContent.CreateChild("ContentNode")
      section.sectionLabel = shelf.title
      section.items = shelf.items
    end if
  end for

  m.grid.content = gridContent
end sub

function BuildShelves(items as Object) as Object
  shelves = {}
  shelves.sections = []
  shelves.allItems = []

  ' Continue Watching - items with position > 30 seconds
  continueItems = []
  for each item in items
    pos = GetPlayPosition(item.itemId)
    if pos > 30
      item.progress = GetPlayProgress(item)
      continueItems.Push(item)
    end if
  end for
  if continueItems.Count() > 0
    shelves.sections.Push({ title: "Continue Watching", items: BuildRowContent(continueItems) })
  end if

  ' On This Device - downloaded items
  deviceItems = []
  for each item in items
    if item.itemDownloaded = true
      deviceItems.Push(item)
    end if
  end for
  if deviceItems.Count() > 0
    shelves.sections.Push({ title: "On This Device", items: BuildRowContent(deviceItems) })
  end if

  ' Genre shelves
  genreMap = {}
  for each item in items
    genres = item.genres
    if genres <> invalid and genres.Count() > 0
      for each g in genres
        if genreMap[g] = invalid then genreMap[g] = []
        genreMap[g].Push(item)
      end for
    else
      if genreMap["Movies"] = invalid then genreMap["Movies"] = []
      genreMap["Movies"].Push(item)
    end if
  end for

  ' Sort genres alphabetically
  genreKeys = []
  for each key in genreMap
    genreKeys.Push(key)
  end for
  genreKeys.Sort()

  for each genre in genreKeys
    genreItems = genreMap[genre]
    if genreItems.Count() > 0
      shelves.sections.Push({ title: genre, items: BuildRowContent(genreItems) })
    end if
  end for

  ' All items for carousel
  shelves.allItems = items
  shelves.heroItem = items[0]

  return shelves
end function

function BuildRowContent(items as Object) as Object
  row = CreateObject("roSGNode", "ContentNode")
  for each item in items
    node = row.CreateChild("ContentNode")
    node.SetFields(item)
  end for
  return row
end function

function GetPlayPosition(itemId as String) as Integer
  ' Read from registry - stored by player
  reg = CreateObject("roRegistrySection", "watch")
  key = "pos_" + itemId
  pos = reg.Read(key)
  if pos = invalid then return 0
  return Val(pos)
end function

function GetPlayProgress(item as Object) as Float
  pos = GetPlayPosition(item.itemId)
  if item.itemRuntime <> invalid and item.itemRuntime > 0
    duration = item.itemRuntime * 60
    if duration > 0
      return pos / duration
    end if
  end if
  return 0.0
end function

function CatalogUrl() as String
  return "https://watch.cornerstonecoatings.com/v1/catalog"
end function

function AuthHeaders() as Object
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

function ReadCatalogCache() as Object
  reg = CreateObject("roRegistrySection", "watch")
  stored = reg.Read("catalog")
  ts = reg.Read("catalogTs")
  if stored = invalid or ts = invalid then return invalid
  now = CreateObject("roDateTime").AsSeconds()
  if now - Val(ts) > 60  ' 60 second TTL
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
  if Len(payload) > 12000
    print "catalog: too large to cache, skipping"
    return
  end if
  reg = CreateObject("roRegistrySection", "watch")
  reg.Write("catalog", payload)
  reg.Write("catalogTs", StrI(CreateObject("roDateTime").AsSeconds()).Trim())
  reg.Flush()
end sub