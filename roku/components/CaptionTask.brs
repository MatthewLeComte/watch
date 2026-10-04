' Fetches a WebVTT file and turns it into cues: [{ s: start secs, e: end secs, t: text }].

sub Init()
  m.top.functionName = "FetchCues"
end sub

sub FetchCues()
  cues = []
  u = CreateObject("roUrlTransfer")
  u.SetUrl(m.top.url)
  u.SetCertificatesFile("common:/certs/ca-bundle.crt")
  u.InitClientCertificates()
  u.AddHeader("Authorization", "Bearer " + m.top.key)
  txt = u.GetToString()
  if txt <> invalid and Len(txt) > 0
    tags = CreateObject("roRegex", "<[^>]+>", "")
    blocks = txt.Replace(Chr(13), "").Split(Chr(10) + Chr(10))
    for each block in blocks
      lines = block.Split(Chr(10))
      for i = 0 to lines.Count() - 1
        if lines[i].Instr("-->") >= 0
          times = lines[i].Split(" --> ")
          if times.Count() = 2
            body = ""
            for j = i + 1 to lines.Count() - 1
              if body <> "" then body = body + Chr(10)
              body = body + lines[j]
            end for
            body = tags.ReplaceAll(body, "")
            cues.Push({ s: ToSeconds(times[0]), e: ToSeconds(times[1].Split(" ")[0]), t: body })
          end if
          exit for
        end if
      end for
    end for
  end if
  m.top.cues = cues
end sub

function ToSeconds(stamp as String) as Float
  secs = 0.0
  for each part in stamp.Trim().Split(":")
    secs = secs * 60 + Val(part.Replace(",", "."))
  end for
  return secs
end function
