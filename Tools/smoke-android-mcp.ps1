# Full Android MCP smoke: spawns Autopilot.Mcp.exe --target adb:<Port> and drives the
# demo-form tool burst over stdio JSON-RPC (set_text, wait_for, set_checked, get_text,
# screenshot — the screenshot PNG is decoded to disk for visual confirmation).
# Prerequisites: app foreground + screen ON (see HANDOVER "freezer" footgun), and
#   adb forward tcp:<Port> localabstract:Autopilot.<pid>
# Usage: .\smoke-android-mcp.ps1 -Port 18011
param(
  [int]$Port = 18011,
  [string]$ExePath = "$PSScriptRoot\..\Source\McpServer\Autopilot.Mcp.exe",
  [int]$TimeoutMs = 120000,
  [string]$PngOut = "$env:TEMP\autopilot-android-screenshot.png"
)
$ErrorActionPreference = 'Stop'

$reqs = @(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}',
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}',
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_text","arguments":{"path":"frmFmxMain.edtName","text":"ping"}}}',
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_text","arguments":{"path":"frmFmxMain.lblNameEcho"}}}',
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wait_for","arguments":{"path":"frmFmxMain.lblNameEcho","expectedtext":"ping","timeoutms":3000,"pollintervalms":100}}}',
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click","arguments":{"path":"frmFmxMain.btnIncrement","count":3}}}',
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_text","arguments":{"path":"frmFmxMain.lblCounter"}}}',
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"set_checked","arguments":{"path":"frmFmxMain.cbxFlag","checked":true}}}',
  '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_text","arguments":{"path":"frmFmxMain.lblFlag"}}}',
  '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"screenshot","arguments":{"form":"frmFmxMain"}}}'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Resolve-Path $ExePath).Path
$psi.Arguments = "--target adb:$Port"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
"server started, pid=$($p.Id), args=$($psi.Arguments)"

$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
foreach ($r in $reqs) { $p.StandardInput.WriteLine($r) }
$p.StandardInput.Close()
if (-not $p.WaitForExit($TimeoutMs)) { "TIMEOUT - killing"; $p.Kill() }
[void]$outTask.Wait(5000)
[void]$errTask.Wait(2000)
$out = $outTask.Result
$err = $errTask.Result

"===== SERVER STDOUT ====="
foreach ($line in ($out -split "`r?`n")) {
  if ($line.Trim().Length -eq 0) { continue }
  if ($line -match '"id":9') {
    "[id 9 = screenshot response, length $($line.Length) - parsing]"
    try {
      $j = $line | ConvertFrom-Json
      $c0 = $j.result.content[0]
      $b64 = $null
      if ($c0.type -eq 'image') { $b64 = $c0.data }
      elseif ($c0.type -eq 'text') {
        $inner = $c0.text | ConvertFrom-Json
        foreach ($prop in $inner.result.PSObject.Properties) {
          if (($prop.Value -is [string]) -and ($prop.Value.Length -gt 1000)) { $b64 = $prop.Value; "  base64 found in result.$($prop.Name)" }
        }
      }
      if ($null -ne $b64) {
        [IO.File]::WriteAllBytes($PngOut, [Convert]::FromBase64String($b64))
        "  PNG saved: $PngOut ($((Get-Item $PngOut).Length) bytes)"
      } else {
        "  no base64 payload recognized; head: " + $line.Substring(0, 300)
      }
    } catch {
      "  parse failed: $($_.Exception.Message); head: " + $line.Substring(0, [Math]::Min(300, $line.Length))
    }
  }
  elseif ($line.Length -gt 300) { $line.Substring(0, 280) + " ...(len=$($line.Length))" }
  else { $line }
}
if ($err -and $err.Trim().Length -gt 0) { "===== STDERR ====="; $err }
"===== DONE (exit $($p.ExitCode)) ====="
