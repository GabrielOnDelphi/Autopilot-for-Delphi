[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PipeName)

# Length-prefix framing: [4-byte LE uint32 length][UTF-8 payload]
function Write-Frame {
  param([System.IO.Pipes.NamedPipeClientStream]$Pipe, [string]$Json)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $len = [BitConverter]::GetBytes([uint32]$bytes.Length)
  $Pipe.Write($len, 0, 4)
  $Pipe.Write($bytes, 0, $bytes.Length)
  $Pipe.Flush()
}

function Read-Frame {
  param([System.IO.Pipes.NamedPipeClientStream]$Pipe)
  $lenBuf = New-Object byte[] 4
  $got = 0
  while ($got -lt 4) {
    $n = $Pipe.Read($lenBuf, $got, 4 - $got)
    if ($n -le 0) { throw "EOF reading length" }
    $got += $n
  }
  $len = [BitConverter]::ToUInt32($lenBuf, 0)
  $payload = New-Object byte[] $len
  $got = 0
  while ($got -lt $len) {
    $n = $Pipe.Read($payload, $got, $len - $got)
    if ($n -le 0) { throw "EOF reading payload" }
    $got += $n
  }
  return [System.Text.Encoding]::UTF8.GetString($payload)
}

function Run-Cmd {
  param([System.IO.Pipes.NamedPipeClientStream]$Pipe, [int]$Id, [string]$Cmd, [hashtable]$CmdArgs = $null)
  $req = @{ id = $Id; cmd = $Cmd }
  if ($null -ne $CmdArgs) { $req.args = $CmdArgs }
  $json = $req | ConvertTo-Json -Compress -Depth 10
  Write-Frame -Pipe $Pipe -Json $json
  $reply = Read-Frame -Pipe $Pipe
  return $reply | ConvertFrom-Json
}

# Strip the trailing PID from the pipe form passed in; clients use the full \\.\pipe\name.
# PS named pipe API wants just the unqualified pipe-name.
$short = ($PipeName -replace '^\\\\\.\\pipe\\', '')
Write-Host "Connecting to pipe: $short"

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $short,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
$pipe.Connect(2000)

# Read server's hello, send our helloAck.
$hello = Read-Frame -Pipe $pipe
Write-Host "Server hello: $hello"
$ack = @{ helloAck = @{ protocolVersion = 1 } } | ConvertTo-Json -Compress -Depth 5
Write-Frame -Pipe $pipe -Json $ack

# 1. list_tree
$r = Run-Cmd -Pipe $pipe -Id 1 -Cmd 'list_tree'
Write-Host "list_tree: ok=$($r.ok), components count=$($r.result.components.Count)"
$r.result.components | ForEach-Object { Write-Host ("  - " + $_.name + " (" + $_.'class' + ")") }

# 2. click btnIncrement
$r = Run-Cmd -Pipe $pipe -Id 2 -Cmd 'click' -CmdArgs @{ path = 'frmFmxMain.btnIncrement' }
Write-Host "click btnIncrement: ok=$($r.ok), via=$($r.result.dispatchedVia)"

# 3. get_text lblCounter
$r = Run-Cmd -Pipe $pipe -Id 3 -Cmd 'get_text' -CmdArgs @{ path = 'frmFmxMain.lblCounter' }
Write-Host "get_text lblCounter: ok=$($r.ok), text='$($r.result.text)'"

# 4. set_text edtName
$r = Run-Cmd -Pipe $pipe -Id 4 -Cmd 'set_text' -CmdArgs @{ path = 'frmFmxMain.edtName'; text = 'hello-fmx' }
Write-Host "set_text edtName='hello-fmx': ok=$($r.ok)"

# 5. get_text lblNameEcho — note FMX TEdit may not fire OnChangeTracking until focus change
Start-Sleep -Milliseconds 200
$r = Run-Cmd -Pipe $pipe -Id 5 -Cmd 'get_text' -CmdArgs @{ path = 'frmFmxMain.lblNameEcho' }
Write-Host "get_text lblNameEcho: ok=$($r.ok), text='$($r.result.text)'"

# 6. set_checked cbxFlag = true
$r = Run-Cmd -Pipe $pipe -Id 6 -Cmd 'set_checked' -CmdArgs @{ path = 'frmFmxMain.cbxFlag'; checked = $true }
Write-Host "set_checked cbxFlag=true: ok=$($r.ok)"

# 7. get_text lblFlag (should be 'on' if OnChange fired)
Start-Sleep -Milliseconds 200
$r = Run-Cmd -Pipe $pipe -Id 7 -Cmd 'get_text' -CmdArgs @{ path = 'frmFmxMain.lblFlag' }
Write-Host "get_text lblFlag: ok=$($r.ok), text='$($r.result.text)'"

# 8. screenshot
$r = Run-Cmd -Pipe $pipe -Id 8 -Cmd 'screenshot'
if ($r.ok) {
  Write-Host "screenshot ok, image bytes (base64): $($r.result.image.Length)"
} else {
  Write-Host "screenshot ERR: $($r.error.code) $($r.error.message)"
}

$pipe.Close()
