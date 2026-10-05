' Sends one resume-point update to the library: PUT {position, duration}, or DELETE to start over.

sub Init()
  m.top.functionName = "Send"
end sub

sub Send()
  u = CreateObject("roUrlTransfer")
  u.SetUrl(m.top.url)
  u.SetCertificatesFile("common:/certs/ca-bundle.crt")
  u.InitClientCertificates()
  u.AddHeader("Authorization", "Bearer " + m.top.key)
  u.AddHeader("Content-Type", "application/json")
  u.SetRequest(m.top.method)
  if m.top.method = "PUT"
    u.PostFromString(m.top.body)
  else
    u.GetToString()
  end if
end sub
