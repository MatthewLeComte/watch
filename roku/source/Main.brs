' Entry point. Main scope merges all of source/*.brs, so PublicKey(),
' PrivateKey() and GetDeviceId() (Config.brs, Auth.brs) are callable here.

Sub Main()
  if PublicKey() = "" or PublicKey() = "__WATCH_PUBLIC_KEY__" or PrivateKey() = "" or PrivateKey() = "__WATCH_PRIVATE_KEY__"
    print "ERROR: keypair not injected. Rebuild with ./build.sh and WATCH_PUBLIC_KEY / WATCH_PRIVATE_KEY set."
  end if
  print "Device ID: " + GetDeviceId()

  screen = CreateObject("roSGScreen")
  port = CreateObject("roMessagePort")
  screen.SetMessagePort(port)
  scene = screen.CreateScene("MainScene")
  screen.Show()

  while true
    msg = Wait(0, port)
    if msg <> invalid and type(msg) = "roSGScreenEvent" and msg.IsScreenClosed()
      return
    end if
  end while
End Sub
