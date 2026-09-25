' Shared auth helpers. Imported via <script> where needed.
' Device ID is per-device, generated once, stored in the registry.
' No sub Init() here (see Config.brs).

function RegistrySection() as Object
  return CreateObject("roRegistrySection", "WatchApp")
end function

function GetDeviceId() as String
  reg = RegistrySection()
  id = reg.Read("deviceId")
  if id <> invalid and type(id) = "String" and Len(id) > 0
    return id
  end if
  id = CreateObject("roDeviceInfo").GetRandomUUID()
  reg.Write("deviceId", id)
  reg.Flush()
  return id
end function

function AuthHeaders() as Object
  headers = {}
  headers["X-Key-ID"] = PublicKey()
  headers["X-API-Key"] = PrivateKey()
  headers["X-Device-ID"] = GetDeviceId()
  return headers
end function
