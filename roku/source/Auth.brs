' Shared auth helpers. Imported via <script> where needed.
' Ed25519 signing for Roku requests. Private key never leaves device.
' No sub Init() here (see Config.brs).

function AuthHeaders() as Object
  headers = {}
  timestamp = CreateObject("roDateTime").GetToISO8601()
  nonce = CreateObject("roDeviceInfo").GetRandomUUID()
  message = timestamp + "." + nonce
  sig = SignEd25519(message, PrivateKey())
  headers["WATCH_PUBLIC_KEY"] = PublicKey()
  headers["WATCH_SIGNATURE"] = sig
  headers["WATCH_TIMESTAMP"] = timestamp
  headers["WATCH_NONCE"] = nonce
  return headers
end function

function PublicKey() as String
  return "__WATCH_PUBLIC_KEY__"
end function

function PrivateKey() as String
  return "__WATCH_PRIVATE_KEY__"
end function

function SignEd25519(message as String, privateKeyHex as String) as String
  crypto = CreateObject("roCrypto")
  privBytes = HexToBytes(privateKeyHex)
  if privBytes.Count() <> 32 and privBytes.Count() <> 64
    return ""
  end if
  msgBytes = message.GetBytes()
  sig = crypto.SignEd25519(msgBytes, privBytes)
  return BytesToBase64(sig)
end function

function HexToBytes(hex as String) as Object
  bytes = CreateObject("roByteArray")
  for i = 0 to Len(hex) - 1 step 2
    byteVal = Val("&h" + Mid(hex, i + 1, 2))
    bytes.Append(byteVal)
  end for
  return bytes
end function

function BytesToBase64(bytes as Object) as String
  encoder = CreateObject("roBase64Encoder")
  encoder.SetInput(bytes)
  return encoder.GetOutput()
end function
