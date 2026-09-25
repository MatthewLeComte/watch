Sub Main()
  print "Main: start"
  screen = CreateObject("roSGScreen")
  port = CreateObject("roMessagePort")
  screen.SetMessagePort(port)
  print "Main: screen created"
  scene = screen.CreateScene("MainScene")
  print "Main: scene created"
  screen.Show()
  print "Main: screen shown"

  fetchTimer = CreateObject("roTimespan")
  fetchTimer.SetTime(1000)
  fetchTimer.SetMessagePort(port)
  fetchTimer.Start()
  print "Main: fetch timer started, 1000ms"

  while true
    msg = Wait(0, port)
    if msg <> invalid
      msgType = type(msg)
      print "Main: event " + msgType
      if msgType = "roSGScreenEvent"
        if msg.IsScreenClosed()
          print "Main: screen closed"
          return
        end if
      else if msgType = "roTimespanEvent"
        if scene <> invalid
          FetchCatalog(screen)
        else
          print "Main: no scene"
        end if
      end if
    end if
  end while
End Sub
