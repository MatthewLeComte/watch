' Ed25519 request signing. The worker checks these four headers on /v1/catalog and /v1/items/*/media.
' source/*.brs is in main scope. MainScene.xml also scripts this file.

function AuthHeaders() as Object
  timestamp = CreateObject("roDateTime").ToISOString()
  nonce = CreateObject("roDeviceInfo").GetRandomUUID()
  message = timestamp + "." + nonce
  sig = SignEd25519(message, PrivateKey())
  return {
    WATCH_PUBLIC_KEY: PublicKey(),
    WATCH_SIGNATURE: sig,
    WATCH_TIMESTAMP: timestamp,
    WATCH_NONCE: nonce
  }
end function

function AuthHeaderList() as Object
  h = AuthHeaders()
  return [
    "WATCH_PUBLIC_KEY: " + h.WATCH_PUBLIC_KEY,
    "WATCH_SIGNATURE: " + h.WATCH_SIGNATURE,
    "WATCH_TIMESTAMP: " + h.WATCH_TIMESTAMP,
    "WATCH_NONCE: " + h.WATCH_NONCE
  ]
end function

function PublicKey() as String
  return "__WATCH_PUBLIC_KEY__"
end function

function PrivateKey() as String
  return "__WATCH_PRIVATE_KEY__"
end function

function SignEd25519(message as String, privateKey as String) as String
  dsa = CreateObject("roDSA")
  dsa.SetDigestAlgorithm("sha512")
  dsa.SetSignAlgorithm("Ed25519")
  path = "tmp:/watch-ed25519.pem"
  der = invalid
  body = CreateObject("roByteArray")
  if Instr(1, privateKey, "BEGIN") > 0
    body.FromAsciiString(privateKey)
  else
    hex = privateKey
    if Len(hex) > 64 then hex = Left(hex, 64)
    der = CreateObject("roByteArray")
    der.FromHexString("302e020100300506032b657004220420" + hex)
    pem = "-----BEGIN PRIVATE KEY-----" + Chr(10) + der.ToBase64String() + Chr(10) + "-----END PRIVATE KEY-----" + Chr(10)
    body.FromAsciiString(pem)
  end if
  body.WriteFile(path)
  rc = dsa.SetPrivateKey(path)
  if rc <> 1 and der <> invalid
    rc = dsa.SetPrivateKeyFromByteArray(der)
  end if
  if rc <> 1 then print "Ed25519 key rejected: " + StrI(rc)
  msg = CreateObject("roByteArray")
  msg.FromAsciiString(message)
  sig = dsa.Sign(msg)
  if sig = invalid then return ""
  return sig.ToBase64String()
end function
