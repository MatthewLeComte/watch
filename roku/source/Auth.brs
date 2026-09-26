' Shared auth helpers. Imported via <script> where needed.
' Ed25519 public/private key placeholders replaced at build time by build.sh.
' No sub Init() here (see Config.brs).

function AuthHeaders() as Object
  headers = {}
  headers["X-Key-ID"] = PublicKey()
  headers["X-API-Key"] = PrivateKey()
  return headers
end function

function PublicKey() as String
  return "__WATCH_PUBLIC_KEY__"
end function

function PrivateKey() as String
  return "__WATCH_PRIVATE_KEY__"
end function
