# Raw-wire Android smoke probe: connects to the adb-forwarded bridge socket,
# reads the hello frame, replies helloAck, runs one list_tree.
# Prerequisites: app foreground + screen ON (see HANDOVER "freezer" footgun), and
#   adb forward tcp:<Port> localabstract:Autopilot.<pid>
# Usage: .\smoke-android-hello.ps1 -Port 18011        (add -HelloOnly to stop after the hello frame)
param([int]$Port = 18011, [int]$TimeoutMs = 15000, [switch]$HelloOnly)
$ErrorActionPreference = 'Stop'

function Read-Frame($s) {
  $len = New-Object byte[] 4; $got = 0
  while ($got -lt 4) { $r = $s.Read($len, $got, 4 - $got); if ($r -le 0) { throw "EOF in length prefix (got $got/4)" }; $got += $r }
  $n = [BitConverter]::ToUInt32($len, 0)
  if ($n -gt 10485760) { throw "absurd frame length $n" }
  $buf = New-Object byte[] $n; $got = 0
  while ($got -lt $n) { $r = $s.Read($buf, $got, [int]($n - $got)); if ($r -le 0) { throw "EOF in payload ($got/$n)" }; $got += $r }
  [Text.Encoding]::UTF8.GetString($buf)
}

function Write-Frame($s, [string]$json) {
  $payload = [Text.Encoding]::UTF8.GetBytes($json)
  $len = [BitConverter]::GetBytes([uint32]$payload.Length)
  $s.Write($len, 0, 4); $s.Write($payload, 0, $payload.Length); $s.Flush()
}

$c = New-Object System.Net.Sockets.TcpClient
$c.ReceiveTimeout = $TimeoutMs
$c.Connect('127.0.0.1', $Port)
$s = $c.GetStream()
"connected to 127.0.0.1:$Port; waiting for hello (timeout $TimeoutMs ms)..."
$hello = Read-Frame $s
"HELLO: $hello"
if (-not $HelloOnly) {
  Write-Frame $s '{"helloAck":{"protocolVersion":1}}'
  "helloAck sent"
  Write-Frame $s '{"id":1,"cmd":"list_tree","args":{},"timeoutMs":8000}'
  $resp = Read-Frame $s
  $max = [Math]::Min(1200, $resp.Length)
  "LIST_TREE ($($resp.Length) bytes): $($resp.Substring(0, $max))"
}
$c.Close()
"WIRE TEST OK"
