' Shared config. Imported via <script> in every component that needs it.
' Keypair placeholders are replaced at build time by build.sh.
' No sub Init() here: this file merges into Main's scope AND every
' component scope that imports it, so only uniquely-named functions.

function ApiBase() as String
  return "https://watch.cornerstonecoatings.com"
end function

function PublicKey() as String
  return "__WATCH_PUBLIC_KEY__"
end function

function PrivateKey() as String
  return "__WATCH_PRIVATE_KEY__"
end function

function CatalogUrl() as String
  return ApiBase() + "/v1/catalog"
end function

function MediaUrlFor(itemId as String) as String
  return ApiBase() + "/v1/items/" + itemId + "/media"
end function

function CacheTtlSec() as Integer
  return 300
end function

function ValidStr(v as Dynamic) as String
  if v = invalid then return ""
  if type(v) = "String" then return v
  return ""
end function

function SafeInt(v as Dynamic) as Integer
  if v = invalid then return 0
  return Int(v)
end function

function SafeArray(v as Dynamic) as Object
  if v = invalid then return []
  if type(v) = "roArray" then return v
  return []
end function
