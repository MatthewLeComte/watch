' ResolveView: Calls worker /v1/sources/resolve to get HLS URL for a source item
' Reports result via resolved field (ContentNode with hlsUrl, cookieHeader, qualities, subtitles)

sub Init()
  m.loading = m.top.findNode("loading")
  m.errorBox = m.top.findNode("errorBox")
  m.errorLabel = m.top.findNode("errorLabel")
  m.retryBtn = m.top.findNode("retryBtn")

  m.retryBtn.ObserveField("buttonSelected", "OnRetry")
  m.top.ObserveField("sourceId", "OnSourceIdChange")
end sub

sub OnSourceIdChange()
  sourceId = m.top.sourceId
  if sourceId <> invalid and sourceId <> "" then
    ResolveSource(sourceId)
  end if
end sub

sub OnRetry()
  m.retryBtn.buttonSelected = false
  ResolveSource(m.top.sourceId)
end sub

sub ResolveSource(sourceId as String)
  m.loading.visible = true
  m.errorBox.visible = false
  m.top.hasError = false
  m.top.resolved = invalid

  ' Parse sourceId to get source and id
  ' Format: "rivestream:movie:27205" or "rivestream:tv:12345:1:2"
  parts = sourceId.Split(":")
  if parts.Count() < 3 then
    ShowError("Invalid source ID format")
    return
  end if

  source = parts[0]
  mediaType = parts[1]
  tmdbId = parts[2]

  ' Reconstruct the full ID for the worker
  workerId = source + ":" + mediaType + ":" + tmdbId
  if parts.Count() > 3
    for i = 3 to parts.Count() - 1
      workerId = workerId + ":" + parts[i]
    end for
  end if

  ' Worker expects GET /v1/sources/:source/resolve/:id
  encodedId = Escape(workerId)
  url = "https://watch.cornerstonecoatings.com/v1/sources/" + source + "/resolve/" + encodedId

  u = CreateObject("roUrlTransfer")
  u.SetUrl(url)
  u.SetRequest("GET")
  u.SetCertificatesFile("common:/certs/ca-bundle.crt")

  ' Auth headers
  headers = GetAuthHeaders()
  u.AddHeader("X-Key-ID", headers["X-Key-ID"])
  u.AddHeader("X-API-Key", headers["X-API-Key"])
  u.AddHeader("X-Device-ID", headers["X-Device-ID"])

  u.RetainBodyOnError(true)

  resp = u.GetToString()
  code = u.GetResponseCode()

  m.loading.visible = false

  if code <> 200 or resp = invalid
    msg = "Resolve failed: HTTP " + StrI(code)
    if resp <> invalid and Len(resp) > 0
      parsed = ParseJSON(resp)
      if parsed <> invalid and parsed.message <> invalid
        msg = msg + " - " + parsed.message
      end if
    end if
    ShowError(msg)
    return
  end if

  parsed = ParseJSON(resp)
  if parsed = invalid
    ShowError("Invalid response from server")
    return
  end if

  if parsed.hlsUrl = invalid or parsed.hlsUrl = ""
    ShowError("No playable stream found")
    return
  end if

  ' Build result ContentNode
  result = CreateObject("roSGNode", "ContentNode")
  result.hlsUrl = parsed.hlsUrl
  if parsed.cookieHeader <> invalid then result.cookieHeader = parsed.cookieHeader
  if parsed.qualities <> invalid then result.qualities = parsed.qualities
  if parsed.subtitles <> invalid then result.subtitles = parsed.subtitles
  if parsed.title <> invalid then result.title = parsed.title
  if parsed.year <> invalid then result.year = parsed.year
  if parsed.poster <> invalid then result.poster = parsed.poster

  m.top.resolved = result
  m.top.hasError = false
end sub

sub ShowError(msg as String)
  m.errorLabel.text = msg
  m.errorBox.visible = true
  m.top.hasError = true
  m.top.errorMessage = msg
  m.retryBtn.SetFocus(true)
end sub

function GetAuthHeaders() as Object
  ' These should match the worker's expected headers
  ' In practice, these come from the app's keypair
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