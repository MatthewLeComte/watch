' PlayerView: fullscreen Video + loading/error states.
' Driven by fields: MainScene sets mediaUrl, then bumps startIndex to play
' (counter, so replaying the same URL still fires). stopIndex stops.

sub Init()
  m.player = m.top.findNode("player")
  m.loading = m.top.findNode("loading")
  m.errorBox = m.top.findNode("errorBox")
  m.errorLabel = m.top.findNode("errorLabel")

  m.player.notificationInterval = 10
  m.top.ObserveField("mediaUrl", "OnMediaUrl")
  m.top.ObserveField("startIndex", "OnStart")
  m.top.ObserveField("stopIndex", "OnStop")
  m.player.ObserveField("state", "OnPlayerState")
end sub

sub OnMediaUrl()
  OnStart()
end sub

sub OnStart()
  url = m.top.mediaUrl
  if url = invalid or url = "" then return
  m.errorBox.visible = false
  m.player.visible = false
  m.loading.visible = true
  m.player.httpHeaders = AuthHeaders()
  m.player.streamFormat = "mp4"
  m.player.url = url
  m.player.control = "play"
end sub

sub OnStop()
  m.player.control = "stop"
end sub

sub OnPlayerState()
  state = m.player.state
  if state = "playing" or state = "buffering"
    m.loading.visible = false
    m.errorBox.visible = false
    m.player.visible = true
  else if state = "finished"
    m.top.finishedIndex = m.top.finishedIndex + 1
  else if state = "error"
    m.player.control = "stop"
    m.player.visible = false
    m.loading.visible = false
    m.errorLabel.text = "Playback failed. Press Back to return."
    m.errorBox.visible = true
  end if
end sub
