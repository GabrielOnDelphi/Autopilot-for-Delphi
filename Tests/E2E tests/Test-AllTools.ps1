# WHAT: end-to-end regression test of all 14 Autopilot MCP tools and of the documented error codes, through the real MCP server EXE, the way an AI host drives it.
#   It starts the target app (-ExePath), starts its OWN copy of Autopilot.Mcp.exe with redirected standard input/output/error, speaks MCP JSON-RPC to it
#   (initialize, notifications/initialized, tools/list, tools/call), and checks every answer against the contract in AI-INSTRUCTIONS.md, "AI-INSTRUCTIONS - tool reference.md" and CLAUDE.md
#   (sections "Click dispatch", "Path rule", "screenshot", "Native dialogs", "TColor coercion", "Parent-inheritance auto-flip", "Error model").
#   It prints one line per case: PASS or FAIL | case name | expected | actual. At the end it closes the app it started (WM_CLOSE), closes the server's
#   standard input, and checks that standard output carried only JSON-RPC lines and that standard error stayed empty.
#   The section "protocol robustness" sends lines that are not valid requests (server/discover, text that is not JSON, a cut-off JSON line,
#   an empty array, bytes that are not UTF-8), tools/call requests the MCP specification calls protocol errors (unknown tool, arguments
#   that are not an object) or tool execution errors (a pid that is not a number), checks that every pid in tools/list is an integer,
#   and sends non-ASCII text, once as raw UTF-8 and once as \uXXXX escapes; after a bad line the same server must answer ping.
#   If the server crashes or hangs there, that is a FAIL line, and a fresh server takes over so the later sections still run.
#   Every line goes to the server as UTF-8 bytes plus LF, written straight to its pipe (WriteServerLine, which says why).
#   No AI model judges anything: the expected values are fixed (rule: "GUI testing - automatic, without AI.md").
#
# CALLER: run by hand (or by a Claude session) before each Autopilot release, after the MCP server or the bridge changed. Written by work package 6 of
#   "Experiment in progress - Finish known issues\" (2026-10-06).
#
# HOW TO RUN (Windows PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "c:\Projects\Projects AI\Autopilot for Delphi\Tests\E2E tests\Test-AllTools.ps1" -Framework VCL -ExePath "c:\Projects\Projects AI\Autopilot for Delphi\DemoVCL\Push buttons\Autopilot.PushBtnsDemo.exe"
#   Outputs go to -OutDir (default: this folder) as "<OutPrefix><Framework> exchange.txt" (every request and answer, base64 cut to 80 characters),
#   "<OutPrefix><Framework> results.txt" (the PASS/FAIL lines), "<OutPrefix><Framework> screenshot.png" (the form), "... screenshot path.png" (the panel crop)
#   and "... screenshot maxWidth.png" (the form scaled to 200 pixels wide).
#   -ProveFail runs the default-click case against a wrong expectation (dispatchedVia = onclick on VCL, click on FMX): that one case must print FAIL.
#   -Framework FMX: powershell -NoProfile -ExecutionPolicy Bypass -File "...\Test-AllTools.ps1" -Framework FMX -ExePath "c:\Projects\Projects AI\Autopilot for Delphi\DemoFmx\Autopilot.DemoFmx.exe"
#   Exit code: 0 = every case passed; 1 = a case failed or a section could not run.
#
# TARGET APPS: the fixtures this script needs (an action bound to a TButton and a TSpeedButton, a check box, a label placed on a panel, a button that
#   opens a native message box, a button whose label changes 1000 ms later through a TTimer) are in DemoVCL\Push buttons\FormMain.dfm and DemoFmx\FormFmxMain.fmx
#   (FMX adds a TRectangle for a TAlphaColor property). The control paths of both apps are in $Maps below.
#   The app is started minimized and not activated (Gabriel's rule of 2026-10-12: a demo window must never take his focus or his clicks).
#
# SAFETY: kills only the two processes it started (the app and its own Autopilot.Mcp.exe, by pid) and only when they do not exit by themselves.
#   Never touches other Autopilot targets or other Autopilot.Mcp processes: every tool call passes the pid of the app it started.
param(
  [ValidateSet('VCL','FMX')][string]$Framework = 'VCL',
  [Parameter(Mandatory)][string]$ExePath,
  [string]$ServerExe = 'c:\Projects\Projects AI\Autopilot for Delphi\Source\McpServer\Autopilot.Mcp.exe',
  [string]$OutDir    = $PSScriptRoot,
  [string]$OutPrefix = 'Last run - ',
  [switch]$ProveFail,
  [int]$ReadTimeoutMs = 60000
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty in a parameter default of a script with [Parameter()] attributes when it runs
# through "powershell -File" (measured 2026-11-01; the body sees it), and Join-Path then fails on the empty -OutDir.
if ($OutDir -eq '') { $OutDir = $PSScriptRoot }

# { Control map per framework }
# Keys are roles; values are the dotted paths list_tree shows. Every value is checked by the list_tree case.
$Maps = @{
  VCL = [ordered]@{
    Form         = 'frmMain'
    Button       = 'frmMain.btnIncrement'      # TButton: OnClick increments lblIncrement
    Counter      = 'frmMain.lblIncrement'
    Edit         = 'frmMain.edtName'           # TEdit: OnChange copies the text to lblNameEcho
    Echo         = 'frmMain.lblNameEcho'
    Label        = 'frmMain.lblHeader'
    DialogButton = 'frmMain.btnDialog'         # OnClick opens Application.MessageBox (MB_YESNOCANCEL, caption 'Native Dialog')
    ActionButton = 'frmMain.btnAction'         # TButton,      Action = actFixture
    ActionSpeed  = 'frmMain.sbAction'          # TSpeedButton, Action = actFixture
    ActionList   = 'frmMain.actlFixture'
    Action       = 'frmMain.actFixture'        # OnExecute writes 'Action ran <N> times, sender <Sender.ClassName>' to lblActionResult
    ActionResult = 'frmMain.lblActionResult'
    Check        = 'frmMain.chkFixture'        # OnClick writes 'checked' / 'unchecked' to lblCheckState
    CheckState   = 'frmMain.lblCheckState'
    Panel        = 'frmMain.pnlFixture'
    InPanel      = 'frmMain.lblInPanel'        # owned by the form, placed on pnlFixture
    DelayButton  = 'frmMain.btnDelayed'        # OnClick writes 'waiting' to lblDelayed and starts tmrDelayed (1000 ms)
    DelayTimer   = 'frmMain.tmrDelayed'        # OnTimer writes 'Delayed done <N>' to lblDelayed
    DelayLabel   = 'frmMain.lblDelayed'
    LastKey      = 'frmMain.lblLastKey'        # edtName.OnKeyDown writes 'Key <code>' or 'Key <code> Ctrl'
    SaveCount    = 'frmMain.lblSaveCount'      # actSave (ShortCut Ctrl+S) writes 'Saved <N>'
  }
  FMX = [ordered]@{
    Form         = 'frmFmxMain'
    Button       = 'frmFmxMain.btnIncrement'      # TButton without an action: OnClick increments lblCounter
    Counter      = 'frmFmxMain.lblCounter'
    Edit         = 'frmFmxMain.edtName'           # TEdit: OnChangeTracking copies the text to lblNameEcho
    Echo         = 'frmFmxMain.lblNameEcho'
    Label        = 'frmFmxMain.lblHeader'
    DialogButton = 'frmFmxMain.btnDialog'         # OnClick opens TDialogService.MessageDialog (mtWarning, YesNoCancel) = a native message box on Windows
    DialogResult = 'frmFmxMain.lblDialogResult'   # 'Dialog closed with <TModalResult>'
    ActionButton = 'frmFmxMain.btnAction'         # TButton,      Action = actFixture
    ActionSpeed  = 'frmFmxMain.sbAction'          # TSpeedButton, Action = actFixture
    ActionList   = 'frmFmxMain.actlFixture'
    Action       = 'frmFmxMain.actFixture'        # OnExecute writes 'Action ran <N> times, sender <Sender.ClassName>' to lblActionResult
    ActionResult = 'frmFmxMain.lblActionResult'
    Check        = 'frmFmxMain.cbxFlag'           # OnChange writes 'on' / 'off' to lblFlag
    CheckState   = 'frmFmxMain.lblFlag'
    Panel        = 'frmFmxMain.pnlFixture'
    InPanel      = 'frmFmxMain.lblInPanel'        # owned by the form, placed on pnlFixture (FMX Children)
    ColorTarget  = 'frmFmxMain.rectFixture'       # TRectangle: Fill.Color is a TAlphaColor
    DelayButton  = 'frmFmxMain.btnDelayed'
    DelayTimer   = 'frmFmxMain.tmrDelayed'
    DelayLabel   = 'frmFmxMain.lblDelayed'
    LastKey      = 'frmFmxMain.lblLastKey'        # edtName.OnKeyDown writes 'Key <code>' or 'Key <code> Ctrl'
    SaveCount    = 'frmFmxMain.lblSaveCount'      # actSave (ShortCut Ctrl+S) writes 'Saved <N>'
  }
}
$M = $Maps[$Framework]

# Expectations that differ by framework, all from the contract ("AI-INSTRUCTIONS - tool reference.md", section click: "Other controls fall back to OnClick(Self):
# ... every FMX control without an action"; CLAUDE.md "TColor coercion is VCL-only", "Parent-inheritance auto-flip (VCL only)").
$Fw = @{
  VCL = @{ DefaultVia = 'click';   CheckedProp = 'Checked';   CheckOn = 'checked'; CheckOff = 'unchecked'; DialogCaption = 'Native Dialog' }
  FMX = @{ DefaultVia = 'onclick'; CheckedProp = 'IsChecked'; CheckOn = 'on';      CheckOff = 'off';       DialogCaption = 'Warning' }
}
$F = $Fw[$Framework]

$IsVcl          = ($Framework -eq 'VCL')
$InPanelText    = 'Inside the panel'
$InPanelVisual  = $M.Panel + '.' + ($M.InPanel -split '\.')[-1]      # Form.Panel.Control: needs the visual-parent fallback of the path rule
$CheckedProp    = $F.CheckedProp
$FontSizeProp   = 'Font.Size'
$ExpectedTools  = @('attach','click','dismiss_dialog','execute_action','get_text','list_tree','read_property','screenshot','send_keys','set_checked','set_keep_awake','set_property','set_text','wait_for')

$ExchangeFile   = Join-Path $OutDir "$OutPrefix$Framework exchange.txt"
$ResultsFile    = Join-Path $OutDir "$OutPrefix$Framework results.txt"
$PngFile        = Join-Path $OutDir "$OutPrefix$Framework screenshot.png"
$PngPathFile    = Join-Path $OutDir "$OutPrefix$Framework screenshot path.png"        # the panel crop
$PngScaledFile  = Join-Path $OutDir "$OutPrefix$Framework screenshot maxWidth.png"    # the form at maxWidth 200

$script:Lines        = New-Object Collections.Generic.List[string]
$script:Results      = New-Object Collections.Generic.List[string]
$script:BadStdout    = New-Object Collections.Generic.List[string]
$script:StdoutLines  = 0
$script:Total        = 0
$script:Passed       = 0
$script:NextId       = 0
$script:LastMs       = 0
$script:LastRequest  = ''
$script:Abort        = ''
$script:App          = $null
$script:Server       = $null
$script:TargetPid    = 0
$script:FormShotW    = 0     # size of the form screenshot, for the maxWidth cases
$script:FormShotH    = 0
$script:ErrTask      = $null # the standard-error reader of the current server
$script:EarlierErr   = ''    # standard error of a server that RestartServer replaced
$script:StdinStream  = $null # the pipe under the current server's standard input (WriteServerLine)
$script:PendingRead  = $null # a read of standard output that timed out and still runs (ReadServerLine)
$script:ReadTimedOut = $false
$Utf8NoBom           = New-Object Text.UTF8Encoding $false
$InitParams          = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'e2e-test-all-tools'; version = '1.0' } }

# { Helpers: log, cases }
function Log([string]$s) { $script:Lines.Add($s) }
function Short([string]$s, [int]$n = 400) {
  if ($null -eq $s) { return '<null>' }
  $t = ($s -replace "`r", '\r') -replace "`n", '\n'
  if ($t.Length -gt $n) { return $t.Substring(0, $n) + '...' } else { return $t }
}
function Case([string]$name, [bool]$ok, [string]$expected, [string]$actual) {
  $script:Total++
  if ($ok) { $script:Passed++; $tag = 'PASS' } else { $tag = 'FAIL' }
  $line = "$tag | $name | expected: $(Short $expected) | actual: $(Short $actual)"
  Write-Host $line
  $script:Results.Add($line)
  Log "CASE $line"
}

$cutData = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $m.Groups[2].Value + '...[base64 cut to 80 of ' + ($m.Groups[2].Length + $m.Groups[3].Length) + ' characters]' + $m.Groups[4].Value }
$cutAny  = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + '...[base64 cut to 80 of ' + $m.Length + ' characters]' }
function CutBase64([string]$s) {
  $s = [regex]::Replace($s, '("data"\s*:\s*")([^"]{80})([^"]*)(")', $cutData)
  return [regex]::Replace($s, '([A-Za-z0-9+/]{80})[A-Za-z0-9+/=\\]{200,}', $cutAny)
}

# { Helpers: JSON-RPC over the server's standard input/output }
# Starts our own copy of the MCP server with redirected standard input/output/error.
function StartServer() {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $ServerExe
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
  $psi.StandardErrorEncoding  = New-Object Text.UTF8Encoding $false
  $psi.CreateNoWindow = $true
  $script:Server = [Diagnostics.Process]::Start($psi)
  $script:StdinStream = $script:Server.StandardInput.BaseStream
  $script:PendingRead = $null
  $script:ErrTask = $script:Server.StandardError.ReadToEndAsync()
  Log "MCP server started, pid $($script:Server.Id)"
  $enc = $script:Server.StandardInput.Encoding
  Log "driver: Process.StandardInput would encode as $($enc.WebName) (code page $($enc.CodePage), preamble $($enc.GetPreamble().Length) bytes; ProcessStartInfo.StandardInputEncoding exists: $($null -ne $psi.PSObject.Properties['StandardInputEncoding'])). This script writes UTF-8 bytes to the pipe instead."
}
# One line to the server's standard input: UTF-8 bytes plus LF, as Claude Code sends it, written straight to the pipe.
# Never through Process.StandardInput, a StreamWriter: .NET Framework has no ProcessStartInfo.StandardInputEncoding, and that writer
# takes the console code page (measured 2026-11-01: 437 when PowerShell runs from Git Bash, 65001 from a UTF-8 console), so on a
# console that is not UTF-8 it cannot carry CJK text or a character outside the Basic Multilingual Plane. Returns the number of bytes written.
function WriteServerLine([string]$line) {
  return WriteServerBytes ($Utf8NoBom.GetBytes($line + "`n"))
}
function WriteServerBytes([byte[]]$bytes) {
  $script:StdinStream.Write($bytes, 0, $bytes.Length)
  $script:StdinStream.Flush()
  return $bytes.Length
}
# The next line of the server's standard output; $null at its end. After $ms without a line, $script:ReadTimedOut is TRUE and the read
# stays pending: the next call waits on that same read, because a StreamReader allows only one ReadLineAsync at a time.
function ReadServerLine([int]$ms) {
  $script:ReadTimedOut = $false
  if ($null -eq $script:PendingRead) { $script:PendingRead = $script:Server.StandardOutput.ReadLineAsync() }
  if (-not $script:PendingRead.Wait($ms)) { $script:ReadTimedOut = $true; return $null }
  $line = $script:PendingRead.Result
  $script:PendingRead = $null
  return $line
}
# The next JSON-RPC message of standard output, or $null when none comes within $ms. A line that is not JSON-RPC is recorded for the
# final standard-output case and skipped. Throws CRASH at the end of standard output.
function ReadJsonRpc([int]$ms, [string]$what) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $line = ReadServerLine ([math]::Max(1, $ms - $sw.ElapsedMilliseconds))
    if ($script:ReadTimedOut) { return $null }
    if ($null -eq $line) { Log '<<< end of standard output'; throw "CRASH: the server closed its standard output during $what (last request: $($script:LastRequest))" }
    $script:StdoutLines++
    $r = $null
    try { $r = $line | ConvertFrom-Json } catch { $r = $null }
    if (($null -eq $r) -or ($r.jsonrpc -ne '2.0')) { $script:BadStdout.Add((Short $line 200)); Log ('<<< NOT JSON-RPC: ' + (CutBase64 $line)); continue }
    Log ("<<< ($($sw.ElapsedMilliseconds) ms) " + (CutBase64 $line))
    return $r
  }
}
# The JSON text with every character above 127 written as \uXXXX, one escape per UTF-16 code unit (a character outside the Basic
# Multilingual Plane becomes its surrogate pair). Safe on any JSON text: such a character can stand only inside a string.
function ToAsciiJson([string]$json) {
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    if ([int]$ch -gt 127) { [void]$sb.Append('\u' + ([int]$ch).ToString('x4')) } else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}
# The text with every character outside printable ASCII shown as <U+XXXX> (UTF-16 code units), so a console that is not UTF-8 shows it intact.
function Visible([string]$s) {
  if ($null -eq $s) { return '<null>' }
  return -join ($s.ToCharArray() | ForEach-Object { if (([int]$_ -ge 32) -and ([int]$_ -le 126)) { [string]$_ } else { '<U+{0:X4}>' -f [int]$_ } })
}

# One request (or, with -Notification, one notification) built by ConvertTo-Json, which writes non-ASCII text raw; -AsciiOnly sends it
# as \uXXXX escapes instead. Returns the answer with the request's id. Throws HANG when no answer comes within -TimeoutMs (default -ReadTimeoutMs).
function Send([string]$method, $params, [switch]$Notification, [switch]$AsciiOnly, [int]$TimeoutMs = 0) {
  $o = [ordered]@{ jsonrpc = '2.0' }
  if (-not $Notification) { $script:NextId++; $o.id = $script:NextId }
  $o.method = $method
  if ($null -ne $params) { $o.params = $params }
  $json = $o | ConvertTo-Json -Depth 10 -Compress
  if ($AsciiOnly) { $json = ToAsciiJson $json }
  $script:LastRequest = (Get-Date -Format 'HH:mm:ss.fff') + ' ' + $json
  Log ">>> $(Get-Date -Format 'HH:mm:ss.fff') $json"
  $n = WriteServerLine $json
  if ($n -ne ($json.Length + 1)) { Log "    ($n bytes of UTF-8 for $($json.Length + 1) UTF-16 code units)" }
  if ($Notification) { return $null }
  if ($TimeoutMs -le 0) { $TimeoutMs = $ReadTimeoutMs }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $r = ReadJsonRpc $TimeoutMs $method
    if ($null -eq $r) { Log "<<< no answer within $TimeoutMs ms"; throw "HANG: no answer to $method within $TimeoutMs ms (last request: $($script:LastRequest))" }
    if (($null -ne $r.PSObject.Properties['id']) -and ($r.id -eq $script:NextId)) { $script:LastMs = $sw.ElapsedMilliseconds; return $r }
  }
}
# One line sent exactly as given (not built by ConvertTo-Json). Returns the first JSON-RPC answer, or $null when none comes within $ms.
function SendRaw([string]$line, [int]$ms = 10000) {
  $script:LastRequest = (Get-Date -Format 'HH:mm:ss.fff') + ' RAW ' + $line
  Log ">>> $(Get-Date -Format 'HH:mm:ss.fff') RAW $line"
  [void](WriteServerLine $line)
  $r = ReadJsonRpc $ms 'a raw line'
  if ($null -eq $r) { Log "<<< no answer within $ms ms" }
  return $r
}
# One line given as bytes (LF added here), for bytes that are not valid UTF-8. Returns the first JSON-RPC answer, or $null after $ms.
function SendRawBytes([byte[]]$bytes, [int]$ms = 10000) {
  $hex = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
  $script:LastRequest = (Get-Date -Format 'HH:mm:ss.fff') + ' RAW BYTES ' + $hex
  Log ">>> $(Get-Date -Format 'HH:mm:ss.fff') RAW BYTES $hex"
  [void](WriteServerBytes ($bytes + [byte[]]@(10)))
  $r = ReadJsonRpc $ms 'a raw byte line'
  if ($null -eq $r) { Log "<<< no answer within $ms ms" }
  return $r
}
# Ends the current server (standard input closed first; killed by its own process only when it has not exited 5 s later), keeps its
# standard error for the final case, then starts and initializes a fresh server, so the sections after a CRASH or HANG still run.
function RestartServer([string]$why) {
  $old = $script:Server
  Log "restarting the MCP server (pid $($old.Id)): $why"
  try { $script:StdinStream.Close() } catch { Log "closing standard input failed: $($_.Exception.Message)" }
  if (-not $old.WaitForExit(5000)) {
    Log "MCP server pid $($old.Id) still running 5 s after standard input closed: killed (it is the copy this script started)"
    $old.Kill()
  }
  if (($null -ne $script:ErrTask) -and $script:ErrTask.Wait(2000)) { $script:EarlierErr += $script:ErrTask.Result }
  StartServer
  [void](Send 'initialize' $InitParams)
  [void](Send 'notifications/initialized' @{} -Notification)
}

# One tools/call. Never throws on a tool error: the cases check errors.
# .J = the first text block parsed as JSON; .Code/.Msg = error.code/message of a {ok:false,error:{...}} envelope; .Ms = round-trip time.
function Tool([string]$name, [hashtable]$a, [switch]$AsciiOnly) {
  $r = Send 'tools/call' @{ name = $name; arguments = $a } -AsciiOnly:$AsciiOnly
  $res = [pscustomobject]@{ Name = $name; Content = @(); IsError = $false; Text = $null; J = $null; Code = $null; Msg = $null; Ms = $script:LastMs }
  if (($null -eq $r.PSObject.Properties['result']) -or ($null -eq $r.result)) {
    $res.IsError = $true
    $res.Text = 'JSON-RPC error: ' + ($r.error | ConvertTo-Json -Compress -Depth 5)
    return $res
  }
  $res.Content = @($r.result.content)
  $res.IsError = ($r.result.isError -eq $true)
  $tb = $res.Content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
  if ($null -ne $tb) {
    $res.Text = [string]$tb.text
    try { $res.J = $res.Text | ConvertFrom-Json } catch { $res.J = $null }
    if (($null -ne $res.J) -and ($null -ne $res.J.PSObject.Properties['error']) -and ($null -ne $res.J.error)) {
      $res.Code = [int]$res.J.error.code
      $res.Msg  = [string]$res.J.error.message
    }
  }
  return $res
}
function IsOk($res) { return ((-not $res.IsError) -and ($null -ne $res.J) -and ($res.J.ok -eq $true)) }
function Describe($res) {
  if ($res.IsError) {
    if ($null -ne $res.Code) { return "isError, code $($res.Code): $($res.Msg)" }
    return "isError: $($res.Text)"
  }
  return [string]$res.Text
}
function ExpectCode([string]$case, $res, [int]$code) {
  Case $case ($res.IsError -and ($res.Code -eq $code)) "isError=true, error.code $code" ("$(Describe $res) [$($res.Ms) ms]")
}
function GetText([string]$path) {
  $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $path }
  if (IsOk $r) { return [string]$r.J.result.text }
  return "<error: $(Describe $r)>"
}
function ExpectText([string]$case, [string]$path, [string]$expected) {
  $a = GetText $path
  Case $case ($a -ceq $expected) "get_text $path = '$expected'" "'$a'"
}
function ReadProp([string]$path, [string]$prop) { return Tool 'read_property' @{ pid = $script:TargetPid; path = $path; propName = $prop } }
function SetProp([string]$path, [string]$prop, [string]$value) { return Tool 'set_property' @{ pid = $script:TargetPid; path = $path; propName = $prop; value = $value } }
function ToInt([string]$s) { $n = 0; if ([int]::TryParse($s, [ref]$n)) { return $n } else { return -1000000 } }
function ActionRuns() {
  $t = GetText $M.ActionResult
  if ($t -match '^Action ran (\d+) times') { return [int]$Matches[1] } else { return 0 }
}
# dismiss_dialog with no button, repeated until the dialog list has (or has not) entries. Returns the last answer.
function PollDialogs([bool]$wantAny, [int]$tries = 20) {
  $d = $null
  for ($i = 0; $i -lt $tries; $i++) {
    $d = Tool 'dismiss_dialog' @{ pid = $script:TargetPid }
    $n = 0
    if (IsOk $d) { $n = @($d.J.result.dialogs).Count }
    if ($wantAny -and ($n -gt 0)) { break }
    if ((-not $wantAny) -and (IsOk $d) -and ($n -eq 0)) { break }
    Start-Sleep -Milliseconds 250
  }
  return $d
}
# Width and height of the PNG in the first content block, read from its IHDR chunk (bytes 16-23, big-endian). -1, -1 when there is no PNG.
function PngSize($res) {
  $c = @($res.Content)
  if (($c.Count -lt 1) -or ($c[0].type -ne 'image')) { return @(-1, -1) }
  $b = [Convert]::FromBase64String([string]$c[0].data)
  if ($b.Length -lt 24) { return @(-1, -1) }
  $w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
  $h = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
  return @($w, $h)
}
function DialogSummary($d) {
  if (-not (IsOk $d)) { return Describe $d }
  $parts = @($d.J.result.dialogs | ForEach-Object { "hwnd $($_.hwnd) class $($_.class) caption '$($_.caption)' buttons [$(@($_.buttons | ForEach-Object { $_.caption }) -join ',')]" })
  return "supported=$($d.J.result.supported), $($parts.Count) dialog(s): $($parts -join '; ')"
}

# Runs one group of cases. A HANG or CRASH stops every later section, which is then reported as not run.
function Section([string]$title, [scriptblock]$body) {
  Log ''
  Log "=== $title ==="
  if ($script:Abort -ne '') { Case "$title (section)" $false 'the section runs' "not run: $($script:Abort)"; return }
  try { & $body }
  catch {
    $msg = $_.Exception.Message
    Case "$title (section)" $false 'the section runs to its end' "stopped: $msg"
    if (($msg -like 'HANG*') -or ($msg -like 'CRASH*') -or (($null -ne $script:Server) -and $script:Server.HasExited)) { $script:Abort = $msg }
  }
}

# { Helpers: protocol robustness }
# Runs one protocol case. A CRASH or HANG inside it is one FAIL line, and RestartServer gives the later cases a fresh server.
function Guarded([string]$name, [scriptblock]$body) {
  try { & $body }
  catch {
    $msg = $_.Exception.Message
    Case "$name (stopped)" $false 'the server answers and stays alive' "stopped: $msg"
    if (($msg -like 'HANG*') -or ($msg -like 'CRASH*') -or $script:Server.HasExited) { RestartServer $msg }
  }
}
function RpcText($r) { if ($null -eq $r) { return 'no answer' } else { return ($r | ConvertTo-Json -Compress -Depth 6) } }
# An error answer with "id": null. JSON-RPC 2.0 specification, section 5: "If there was an error in detecting the id in the Request object
# (e.g. Parse error/Invalid Request), it MUST be Null."
function ExpectNullIdError([string]$case, $r, [int]$code) {
  $ok = ($null -ne $r) -and ($null -ne $r.PSObject.Properties['error']) -and ([int]$r.error.code -eq $code) -and ($null -ne $r.PSObject.Properties['id']) -and ($null -eq $r.id) -and ($null -eq $r.PSObject.Properties['result'])
  Case $case $ok "error.code $code, id null, no result" (RpcText $r)
}
# The same server process still answers ping after a bad line.
function ExpectPing([string]$after) {
  $p = Send 'ping' @{} -TimeoutMs 10000
  $ok = ($null -ne $p.PSObject.Properties['result']) -and ($null -eq $p.PSObject.Properties['error']) -and (-not $script:Server.HasExited)
  Case "protocol: ping answers after $after" $ok "a result for ping id $($script:NextId), server pid $($script:Server.Id) still running" "$(RpcText $p), server running: $(-not $script:Server.HasExited)"
}
function ExpectExactText([string]$case, [string]$path, [string]$expected) {
  $a = GetText $path
  Case $case ($a -ceq $expected) "get_text $path = '$(Visible $expected)'" "'$(Visible $a)'"
}

# { Header }
$fv = (Get-Item -LiteralPath $ServerExe).VersionInfo
Log "=== Test-AllTools - $Framework - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "MCP server : $ServerExe (FileVersion $($fv.FileVersion), LastWriteTime $((Get-Item -LiteralPath $ServerExe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
Log "Target app : $ExePath (LastWriteTime $((Get-Item -LiteralPath $ExePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
if ($ProveFail) { Log 'MODE       : -ProveFail (the default-click case expects the wrong dispatchedVia on purpose)' }

try {
  # { Start the target and wait for its discovery file }
  Section 'Start the target' {
    # Started minimized and NOT activated (WScript.Shell.Run style 7 = SW_SHOWMINNOACTIVE, the method of
    # "Issues\No focus steal\Start-NoFocus.ps1"), so the demo never takes the focus or a click meant for Gabriel's window.
    $t0 = (Get-Date).AddSeconds(-1)
    [void](New-Object -ComObject WScript.Shell).Run('"' + $ExePath + '"', 7, $false)
    $full = (Get-Item -LiteralPath $ExePath).FullName
    $sw0 = [Diagnostics.Stopwatch]::StartNew()
    $script:App = $null
    while (($null -eq $script:App) -and ($sw0.ElapsedMilliseconds -lt 10000)) {
      $script:App = Get-Process -ErrorAction SilentlyContinue | Where-Object { ($_.Path -eq $full) -and ($_.StartTime -ge $t0) } | Select-Object -First 1
      if ($null -eq $script:App) { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $script:App) { throw "CRASH: $ExePath did not start" }
    $script:TargetPid = $script:App.Id
    Log "target started, pid $($script:TargetPid)"
    $disc = Join-Path $env:TEMP "Autopilot\active\$($script:TargetPid).pipe"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((-not (Test-Path -LiteralPath $disc)) -and ($sw.ElapsedMilliseconds -lt 20000)) { Start-Sleep -Milliseconds 200 }
    $found = Test-Path -LiteralPath $disc
    Case 'target announces itself (discovery file)' $found "$disc exists" $(if ($found) { "exists after $($sw.ElapsedMilliseconds) ms: $((Get-Content -LiteralPath $disc -Raw).Trim())" } else { 'missing after 20 s' })
    if (-not $found) { throw 'CRASH: the target never wrote its discovery file' }
  }

  # { Start our own MCP server }
  StartServer

  Section 'initialize and tools/list' {
    $init = Send 'initialize' $InitParams
    # The version the server reports must match the version resource of its own EXE (McpServerVersion and the .dproj version info move together).
    $wantVer = "$($fv.FileMajorPart).$($fv.FileMinorPart).$($fv.FileBuildPart)"
    Case 'initialize: server version' ($init.result.serverInfo.version -eq $wantVer) "serverInfo.version = $wantVer (the EXE's FileVersion)" "$($init.result.serverInfo.name) $($init.result.serverInfo.version)"
    [void](Send 'notifications/initialized' @{} -Notification)
    $tl = Send 'tools/list' @{}
    $names = @($tl.result.tools | ForEach-Object { [string]$_.name } | Sort-Object)
    $want  = @($ExpectedTools | Sort-Object)
    Case 'tools/list: the 14 tools' (($names.Count -eq 14) -and (($names -join ',') -eq ($want -join ','))) "14 tools: $($want -join ',')" "$($names.Count) tools: $($names -join ',')"
  }

  # Bad lines and non-ASCII text on the server's standard input. The expected values come from the JSON-RPC 2.0 specification
  # (https://www.jsonrpc.org/specification, read 2026-11-01): section 5.1, "-32700 Parse error: Invalid JSON was received by the server"
  # and "-32600 Invalid Request: The JSON sent is not a valid Request object"; section 7, "rpc call with invalid JSON" answers -32700 with
  # "id": null, and "rpc call with an empty Array" answers -32600 with "id": null.
  # server/discover must stay -32601 Method not found (CLAUDE.md, decision "MCP transport"): on that answer Claude Code falls back to
  # initialize (measured 2026-11-01, Claude Code 2.1.309); a server that answered it would push Claude Code onto MCP 2026-07-28.
  Section 'protocol robustness' {
    Guarded 'protocol: server/discover' {
      $r = Send 'server/discover' @{} -TimeoutMs 10000
      $ok = ($null -ne $r.PSObject.Properties['error']) -and ([int]$r.error.code -eq -32601) -and ($null -eq $r.PSObject.Properties['result'])
      Case 'protocol: server/discover answers -32601 Method not found' $ok "error.code -32601, id $($script:NextId), no result" (RpcText $r)
      ExpectPing 'server/discover'
    }
    Guarded 'protocol: a line that is not JSON' {
      $r = SendRaw 'this is not json'
      ExpectNullIdError 'protocol: a line that is not JSON answers -32700 Parse error' $r -32700
      ExpectPing 'a line that is not JSON'
    }
    Guarded 'protocol: a cut-off JSON line' {
      $r = SendRaw '{"jsonrpc":"2.0","id":77,"method":"ping"'
      ExpectNullIdError 'protocol: a cut-off JSON line answers -32700 Parse error' $r -32700
      ExpectPing 'a cut-off JSON line'
    }
    Guarded 'protocol: an empty array' {
      $r = SendRaw '[]'
      ExpectNullIdError 'protocol: an empty array answers -32600 Invalid Request' $r -32600
      ExpectPing 'an empty array'
    }
    # Bytes that are not valid UTF-8 (C3 starts a 2-byte sequence, 28 cannot continue it) inside a string of a ping request:
    # the line is not valid JSON text, so -32700, not a ping answered with a replacement character.
    Guarded 'protocol: a line that is not valid UTF-8' {
      $bytes = $Utf8NoBom.GetBytes('{"jsonrpc":"2.0","id":88,"method":"ping","params":{"note":"a') + [byte[]]@(0xC3, 0x28) + $Utf8NoBom.GetBytes('b"}}')
      $r = SendRawBytes ([byte[]]$bytes)
      ExpectNullIdError 'protocol: a line that is not valid UTF-8 answers -32700 Parse error' $r -32700
      ExpectPing 'a line that is not valid UTF-8'
    }
    # tools/call errors. MCP specification 2025-11-25 (https://modelcontextprotocol.io/specification/2025-11-25/server/tools, section
    # "Error Handling", read 2026-11-01): "Protocol Errors: Standard JSON-RPC errors for issues like: Unknown tools, Malformed requests
    # (requests that fail to satisfy CallToolRequest schema)", its example answers an unknown tool with -32602; "Tool Execution Errors:
    # Reported in tool results with isError: true: ... Input validation errors (e.g., date in wrong format, value out of range)".
    Guarded 'protocol: tools/call with an unknown tool' {
      $r = Send 'tools/call' @{ name = 'no_such_tool_e2e'; arguments = @{} } -TimeoutMs 10000
      $ok = ($null -ne $r.PSObject.Properties['error']) -and ([int]$r.error.code -eq -32602) -and ($null -eq $r.PSObject.Properties['result'])
      Case 'protocol: tools/call with an unknown tool answers -32602' $ok "error.code -32602, id $($script:NextId), no result" (RpcText $r)
      ExpectPing 'tools/call with an unknown tool'
    }
    Guarded 'protocol: tools/call with arguments that are not an object' {
      $r = Send 'tools/call' @{ name = 'get_text'; arguments = 'not an object' } -TimeoutMs 10000
      $ok = ($null -ne $r.PSObject.Properties['error']) -and ([int]$r.error.code -eq -32602) -and ($null -eq $r.PSObject.Properties['result'])
      Case 'protocol: tools/call with arguments that are a string answers -32602' $ok "error.code -32602, id $($script:NextId), no result" (RpcText $r)
    }
    Guarded 'protocol: tools/call with a pid that is not a number' {
      $r = Send 'tools/call' @{ name = 'get_text'; arguments = @{ pid = 'abc'; path = $M.Counter } } -TimeoutMs 10000
      $txt = ''
      if (($null -ne $r.PSObject.Properties['result']) -and ($null -ne $r.result)) { $txt = [string](@($r.result.content | Where-Object { $_.type -eq 'text' }) | Select-Object -First 1).text }
      # The text must name both the parameter and the refused value: "call attach(pid) first" alone names pid but not the bad value.
      $ok = ($null -eq $r.PSObject.Properties['error']) -and ($null -ne $r.PSObject.Properties['result']) -and ($r.result.isError -eq $true) -and ($txt -match '\bpid\b') -and ($txt -match '\babc\b')
      Case 'protocol: get_text with pid "abc" answers a result with isError: true that names pid and abc' $ok 'a result (no JSON-RPC error) with isError=true, its text names pid and abc' (RpcText $r)
    }
    Guarded 'protocol: tools/list pid type' {
      $tl = Send 'tools/list' @{} -TimeoutMs 10000
      $withPid = @($tl.result.tools | Where-Object { ($null -ne $_.inputSchema.properties) -and ($null -ne $_.inputSchema.properties.PSObject.Properties['pid']) })
      $notInt  = @($withPid | Where-Object { [string]$_.inputSchema.properties.pid.type -ne 'integer' })
      $types   = @($withPid | ForEach-Object { "$($_.name)=$($_.inputSchema.properties.pid.type)" })
      Case 'tools/list: the pid property of every tool has type integer' (($withPid.Count -eq 14) -and ($notInt.Count -eq 0)) '14 tools with a pid property, each of type integer' "$($withPid.Count) tools with pid, $($notInt.Count) not integer: $($types -join ', ')"
    }
    # Latin-1, Romanian, CJK and U+1F600 (the surrogate pair D83D DE00), built from code units: Windows PowerShell 5.1 reads a .ps1
    # without a byte order mark as ANSI, so this file holds no raw non-ASCII character.
    $intl = -join [char[]]@(0xE4, 0xF6, 0xFC, 0xDF, 0x20, 0xE9, 0x20, 0x103, 0xEE, 0x219, 0x21B, 0x20, 0x65E5, 0x672C, 0x8A9E, 0x20, 0xD83D, 0xDE00)
    Guarded 'protocol: non-ASCII text as raw UTF-8' {
      $t = 'raw UTF-8 ' + $intl
      $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Edit; text = $t }
      Case 'protocol: set_text with non-ASCII text sent as raw UTF-8' (IsOk $r) 'ok' (Describe $r)
      ExpectExactText 'protocol: get_text returns the raw UTF-8 text exactly' $M.Edit $t
    }
    Guarded 'protocol: non-ASCII text as \u escapes' {
      $t = 'escaped ' + $intl
      $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Edit; text = $t } -AsciiOnly
      Case 'protocol: set_text with non-ASCII text sent as \uXXXX escapes' (IsOk $r) 'ok' (Describe $r)
      ExpectExactText 'protocol: get_text returns the escaped text exactly' $M.Edit $t
    }
  }

  Section 'attach' {
    $a = Tool 'attach' @{}
    $pids = @($a.J.targets | ForEach-Object { [int]$_.pid })
    Case 'attach: lists the target' ((-not $a.IsError) -and ($pids -contains $script:TargetPid)) "targets[] holds pid $($script:TargetPid)" "count $($a.J.count), pids $($pids -join ',')"
    $a = Tool 'attach' @{ pid = $script:TargetPid }
    $ok = (-not $a.IsError) -and ($a.J.count -eq 1) -and ([int]$a.J.targets[0].pid -eq $script:TargetPid) -and ([string]$a.J.targets[0].pipe -like "*.$($script:TargetPid)")
    Case 'attach(pid): selects the target' $ok "count 1, pid $($script:TargetPid), pipe ...$($script:TargetPid)" "count $($a.J.count), pid $($a.J.targets[0].pid), pipe $($a.J.targets[0].pipe)"
  }

  Section 'list_tree' {
    $lt = Tool 'list_tree' @{ pid = $script:TargetPid }
    $comps = @($lt.J.result.components)
    $paths = @($comps | ForEach-Object { [string]$_.path })
    foreach ($k in $M.Keys) {
      $p = $M[$k]
      $node = $comps | Where-Object { $_.path -ceq $p } | Select-Object -First 1
      Case "list_tree: lists $p" ($null -ne $node) "a node with path $p" $(if ($null -ne $node) { "found, class $($node.class)" } else { "not among $($paths.Count) paths" })
    }
    $node = $comps | Where-Object { $_.path -ceq $M.InPanel } | Select-Object -First 1
    Case 'list_tree: a control on a panel of its own form has no parent field' (($null -ne $node) -and ($null -eq $node.PSObject.Properties['parent'])) 'no "parent" field' $(if ($null -eq $node) { 'node missing' } else { ($node | ConvertTo-Json -Compress) })
  }

  Section 'click' {
    $c0 = ToInt (GetText $M.Counter)
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button }
    $wantVia = $F.DefaultVia
    if ($ProveFail) { $wantVia = $(if ($wantVia -eq 'click') { 'onclick' } else { 'click' }) }
    Case 'click: default dispatch on a TButton'((IsOk $r) -and ($r.J.result.dispatchedVia -eq $wantVia) -and ($r.J.result.clicksDispatched -eq 1)) "dispatchedVia=$wantVia, clicksDispatched=1" (Describe $r)
    ExpectText 'click: default dispatch ran OnClick once' $M.Counter ([string]($c0 + 1))

    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button; count = 5 }
    Case 'click: count=5' ((IsOk $r) -and ($r.J.result.clicksDispatched -eq 5) -and ($null -eq $r.J.result.PSObject.Properties['stoppedReason'])) 'clicksDispatched=5, no stoppedReason' (Describe $r)
    ExpectText 'click: count=5 ran OnClick 5 times' $M.Counter ([string]($c0 + 6))

    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Edit; mode = 'message' }
    ExpectCode 'click: mode=message on a non-button control' $r -32005

    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button; mode = 'bogus' }
    ExpectCode 'click: bad mode value' $r -32600

    $n0 = ActionRuns
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.ActionButton }
    Case 'click: action-bound TButton' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq 'click')) 'dispatchedVia=click' (Describe $r)
    ExpectText 'click: action-bound TButton ran the action (Sender = the action)' $M.ActionResult "Action ran $($n0 + 1) times, sender TAction"
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.ActionSpeed }
    Case 'click: action-bound TSpeedButton' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq 'click')) 'dispatchedVia=click' (Describe $r)
    ExpectText 'click: action-bound TSpeedButton ran the action (Sender = the action)' $M.ActionResult "Action ran $($n0 + 2) times, sender TAction"
  }

  Section 'click mode=message and wait_for' {
    $c0 = ToInt (GetText $M.Counter)
    if ($IsVcl) {
      $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button; mode = 'message' }
      Case 'click: mode=message on a TButton' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq 'message')) 'dispatchedVia=message' (Describe $r)
    }
    else {
      $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button; mode = 'message' }
      ExpectCode 'click: mode=message on FMX (rejected on every control)' $r -32005
      $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.Button }
    }
    $want = [string]($c0 + 1)
    $w = Tool 'wait_for' @{ pid = $script:TargetPid; path = $M.Counter; expectedText = $want; timeoutMs = 5000 }
    Case 'wait_for: matches the text that the click changed' ((-not $w.IsError) -and ($w.J.matched -eq $true) -and ([string]$w.J.currentValue -ceq $want)) "matched=true, currentValue=$want" "$(Describe $w) [$($w.Ms) ms]"

    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.DelayButton }
    Case 'click: the delayed-text button' ((IsOk $r) -and ($r.J.result.clicksDispatched -eq 1)) 'clicksDispatched=1' (Describe $r)
    $w = Tool 'wait_for' @{ pid = $script:TargetPid; path = $M.DelayLabel; expectedText = 'Delayed done 1'; timeoutMs = 5000 }
    Case 'wait_for: polls until a label changed 1000 ms after the click matches' ((-not $w.IsError) -and ($w.J.matched -eq $true) -and ([string]$w.J.currentValue -ceq 'Delayed done 1') -and ($w.J.pollCount -ge 2) -and ($w.Ms -ge 700) -and ($w.Ms -lt 4000)) "matched=true, currentValue='Delayed done 1', pollCount>=2, after 700..4000 ms" "$(Describe $w) [$($w.Ms) ms]"

    $w = Tool 'wait_for' @{ pid = $script:TargetPid; path = $M.Counter; expectedText = 'never-E2E'; timeoutMs = 1000 }
    Case 'wait_for: deadline passes while the target answers' ((-not $w.IsError) -and ($w.J.matched -eq $false) -and ([string]$w.J.currentValue -ceq $want) -and ($w.J.pollCount -ge 2)) "isError absent, matched=false, currentValue=$want, pollCount>=2" "$(Describe $w) [$($w.Ms) ms]"
  }

  Section 'get_text and set_text' {
    $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Edit; text = 'E2E name' }
    Case 'set_text: edit' (IsOk $r) 'ok' (Describe $r)
    ExpectText 'get_text: edit after set_text' $M.Edit 'E2E name'
    ExpectText 'set_text: edit OnChange fired' $M.Echo 'E2E name'
    $nl = "E2E line 1`nline 2"
    $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Edit; text = $nl }
    Case 'set_text: edit, text with #10' (IsOk $r) 'ok' (Describe $r)
    if ($IsVcl) { ExpectText 'get_text: edit keeps the #10' $M.Edit $nl }
    else {
      # The FMX TEdit itself keeps only the text before the first #10/#13: TCustomEditModel.DoTruncating, FMX.Edit.pas:1928-1939 (Delphi 13).
      # The wire carries the #10 intact: the label case below proves it on both frameworks.
      ExpectText 'get_text: FMX TEdit keeps only the first line (its own DoTruncating)' $M.Edit 'E2E line 1'
    }
    $orig = GetText $M.Label
    $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Label; text = 'E2E label' }
    Case 'set_text: label' (IsOk $r) 'ok' (Describe $r)
    ExpectText 'get_text: label after set_text' $M.Label 'E2E label'
    $nl = "E2E label`nline 2"
    $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Label; text = $nl }
    Case 'set_text: label, text with #10' (IsOk $r) 'ok' (Describe $r)
    ExpectText 'get_text: label keeps the #10' $M.Label $nl
    [void](Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Label; text = $orig })
  }

  Section 'set_checked' {
    $r = Tool 'set_checked' @{ pid = $script:TargetPid; path = $M.Check; checked = $true }
    Case 'set_checked: true' ((IsOk $r) -and ($r.J.result.checked -eq $true)) 'ok, checked=true' (Describe $r)
    ExpectText 'set_checked: true ran the handler' $M.CheckState $F.CheckOn
    $r = ReadProp $M.Check $CheckedProp
    Case "read_property: $CheckedProp after set_checked true" ((IsOk $r) -and ([string]$r.J.result.value -ieq 'true')) "value 'True' (any case)" (Describe $r)
    $r = Tool 'set_checked' @{ pid = $script:TargetPid; path = $M.Check; checked = $false }
    Case 'set_checked: false' ((IsOk $r) -and ($r.J.result.checked -eq $false)) 'ok, checked=false' (Describe $r)
    ExpectText 'set_checked: false ran the handler' $M.CheckState $F.CheckOff
  }

  Section 'set_property and read_property' {
    $r = SetProp $M.Panel 'Hint' 'E2E hint'
    Case 'set_property: string Hint' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
    $r = ReadProp $M.Panel 'Hint'
    Case 'read_property: string Hint' ((IsOk $r) -and ([string]$r.J.result.value -ceq 'E2E hint') -and ($r.J.result.kind -eq 'string')) "value 'E2E hint', kind string" (Describe $r)

    $r = SetProp $M.Panel 'Tag' '42'
    Case 'set_property: integer Tag=42' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
    $r = ReadProp $M.Panel 'Tag'
    Case 'read_property: integer Tag' ((IsOk $r) -and ([string]$r.J.result.value -eq '42') -and ($r.J.result.kind -eq 'integer')) "value '42', kind integer" (Describe $r)
    $r = SetProp $M.Panel 'Tag' '42'
    Case 'set_property: same value again is elided' ((IsOk $r) -and ($r.J.result.elided -eq $true)) 'ok, elided=true' (Describe $r)

    if ($IsVcl) {
      $r = ReadProp $M.InPanel 'ParentFont'
      Case 'read_property: ParentFont before the Font.Size write' ((IsOk $r) -and ([string]$r.J.result.value -ieq 'true')) "value 'True' (any case)" (Describe $r)
    }
    $r = SetProp $M.InPanel $FontSizeProp '14'
    Case "set_property: $FontSizeProp=14" (IsOk $r) 'ok' (Describe $r)
    $r = ReadProp $M.InPanel $FontSizeProp
    # VCL Font.Size is an Integer, FMX Font.Size a Single: compare the number, not the text.
    $num = 0.0
    $isNum = (IsOk $r) -and [double]::TryParse([string]$r.J.result.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$num)
    Case "read_property: $FontSizeProp" ($isNum -and ($num -eq 14)) 'a value equal to 14' (Describe $r)
    if ($IsVcl) {
      $r = ReadProp $M.InPanel 'ParentFont'
      Case 'read_property: ParentFont flipped to FALSE after Font.Size' ((IsOk $r) -and ([string]$r.J.result.value -ieq 'false')) "value 'False' (any case)" (Describe $r)

      $r = SetProp $M.Panel 'Color' 'clRed'
      Case 'set_property: TColor clRed' (IsOk $r) 'ok' (Describe $r)
      $r = ReadProp $M.Panel 'Color'
      Case 'read_property: TColor after clRed' ((IsOk $r) -and ([string]$r.J.result.value -ceq 'clRed') -and ($r.J.result.kind -eq 'color')) "value 'clRed', kind color" (Describe $r)
      $r = SetProp $M.Panel 'Color' '#FF0080'
      Case 'set_property: TColor #FF0080' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
      $r = ReadProp $M.Panel 'Color'
      $v = [string]$r.J.result.value
      # #FF0080 = R FF, G 00, B 80 -> TColor $00BBGGRR = $008000FF = 8388863
      Case 'read_property: TColor after #FF0080' ((IsOk $r) -and (@('#FF0080', '$008000FF', '8388863') -contains $v.ToUpper())) "value '#FF0080' or '`$008000FF' or '8388863'" (Describe $r)
      $r = SetProp $M.Panel 'Color' $v
      Case 'set_property: the read Color value written back is elided (round trip)' ((IsOk $r) -and ($r.J.result.elided -eq $true)) "ok, elided=true for value '$v'" (Describe $r)
    }
    else {
      # FMX has no TColor property; its colors are TAlphaColor ("AI-INSTRUCTIONS - tool reference.md", set_property and read_property examples: Fill.Color, 'claRed', kind alphacolor).
      $r = SetProp $M.ColorTarget 'Fill.Color' 'claRed'
      Case 'set_property: TAlphaColor Fill.Color=claRed' (IsOk $r) 'ok' (Describe $r)
      $r = ReadProp $M.ColorTarget 'Fill.Color'
      Case 'read_property: TAlphaColor after claRed' ((IsOk $r) -and ([string]$r.J.result.value -ceq 'claRed') -and ($r.J.result.kind -eq 'alphacolor')) "value 'claRed', kind alphacolor" (Describe $r)
      $v = [string]$r.J.result.value
      $r = SetProp $M.ColorTarget 'Fill.Color' $v
      Case 'set_property: the read named color written back is elided (round trip)' ((IsOk $r) -and ($r.J.result.elided -eq $true)) "ok, elided=true for value '$v'" (Describe $r)
      $r = SetProp $M.ColorTarget 'Fill.Color' '#FF8000'
      Case 'set_property: TAlphaColor Fill.Color=#FF8000' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
      $r = ReadProp $M.ColorTarget 'Fill.Color'
      $v = [string]$r.J.result.value
      # #FF8000 with alpha FF = $FFFF8000 = 4294934528
      Case 'read_property: TAlphaColor after #FF8000' ((IsOk $r) -and (@('#FF8000', '#FFFF8000', '$FFFF8000', 'XFFFF8000', '4294934528') -contains $v.ToUpper())) "value '#FF8000' or '#FFFF8000' or '`$FFFF8000' or 'xFFFF8000' or '4294934528'" (Describe $r)
      $r = SetProp $M.ColorTarget 'Fill.Color' $v
      Case 'set_property: the read Fill.Color value written back is elided (round trip)' ((IsOk $r) -and ($r.J.result.elided -eq $true)) "ok, elided=true for value '$v'" (Describe $r)
    }

    $r = SetProp $M.Panel 'NoSuchProp' '1'
    $avail = 0
    if (($null -ne $r.J) -and ($null -ne $r.J.PSObject.Properties['error']) -and ($null -ne $r.J.error.PSObject.Properties['data'])) { $avail = @($r.J.error.data.availableProperties).Count }
    Case 'set_property: a property that does not exist' ($r.IsError -and ($r.Code -eq -32006) -and ($avail -gt 0)) 'isError=true, error.code -32006, error.data.availableProperties not empty' "code $($r.Code), $avail availableProperties: $(Short $r.Msg 150)"
    $r = ReadProp $M.Panel 'NoSuchProp'
    ExpectCode 'read_property: a property that does not exist' $r -32006
  }

  Section 'execute_action' {
    $n0 = ActionRuns
    $r = Tool 'execute_action' @{ pid = $script:TargetPid; path = $M.Action }
    Case 'execute_action: runs the action' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq 'Execute') -and ($r.J.result.executed -eq $true)) 'dispatchedVia=Execute, executed=true' (Describe $r)
    ExpectText 'execute_action: OnExecute ran (Sender = the action)' $M.ActionResult "Action ran $($n0 + 1) times, sender TAction"
  }

  Section 'send_keys' {
    $via = if ($IsVcl) { 'keymessages' } else { 'formkeydown' }
    $r = Tool 'set_text' @{ pid = $script:TargetPid; path = $M.Edit; text = '' }
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; path = $M.Edit; text = 'key42' }
    Case 'send_keys: type text' ((IsOk $r) -and ($r.J.result.keysSent -eq 5) -and ([string]$r.J.result.target -eq $M.Edit) -and ([string]$r.J.result.via -eq $via)) "ok, keysSent=5, target=$($M.Edit), via=$via" (Describe $r)
    ExpectText 'send_keys: the typed text is in the edit' $M.Edit 'key42'
    ExpectText 'send_keys: typing fired OnChange' $M.Echo 'key42'
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; keys = 'Enter' }
    Case 'send_keys: Enter to the focused control (no path)' ((IsOk $r) -and ([string]$r.J.result.target -eq $M.Edit)) "ok, target=$($M.Edit)" (Describe $r)
    ExpectText 'send_keys: Enter reached OnKeyDown' $M.LastKey 'Key 13'
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; path = $M.Edit; keys = 'Ctrl+S' }
    Case 'send_keys: Ctrl+S' (IsOk $r) 'ok' (Describe $r)
    ExpectText 'send_keys: Ctrl+S ran the action ShortCut' $M.SaveCount 'Saved 1'
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; path = $M.Edit; keys = 'A Ctrl+Bogus'; text = 'zz' }
    Case 'send_keys: unknown key name' ($r.IsError -and ($r.Code -eq -32600) -and ($r.Msg -like '*Bogus*')) 'isError=true, error.code -32600, message names Bogus' "code $($r.Code): $(Short $r.Msg 150)"
    ExpectText 'send_keys: nothing typed after a bad key name' $M.Edit 'key42'
    # Last, because Ctrl+Z is also the edit's own Undo.
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; path = $M.Edit; keys = 'Ctrl+Z' }
    ExpectText 'send_keys: Ctrl+Z reached OnKeyDown with Ctrl' $M.LastKey 'Key 90 Ctrl'
    $r = Tool 'send_keys' @{ pid = $script:TargetPid; path = $M.Label; keys = 'A' }
    ExpectCode 'send_keys: a label cannot take the focus' $r -32005
  }

  # A control disabled through set_property cannot be enabled again through any tool: "AI-INSTRUCTIONS - tool reference.md", section read_property,
  # "Contrast with click / set_property, which refuse to act on disabled controls". So this test uses the check box, which no later case needs.
  Section 'disabled control' {
    # The delayed-text button: it has an OnClick on both frameworks (the FMX cbxFlag has only OnChange, so an FMX click on it is -32005 by contract),
    # and nothing after this section needs it.
    $D = $M.DelayButton
    $r = ReadProp $D 'Enabled'
    Case 'read_property: Boolean Enabled before the write' ((IsOk $r) -and ([string]$r.J.result.value -ieq 'true') -and ($r.J.result.kind -eq 'boolean')) "value 'True' (any case), kind boolean" (Describe $r)
    $r = SetProp $D 'Enabled' 'false'
    Case 'set_property: Boolean Enabled=false' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
    $r = ReadProp $D 'Enabled'
    Case 'read_property: Boolean Enabled after the write (read_property ignores Enabled)' ((IsOk $r) -and ([string]$r.J.result.value -ieq 'false') -and ($r.J.result.kind -eq 'boolean')) "value 'False' (any case), kind boolean" (Describe $r)
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $D }
    ExpectCode 'click: a disabled control' $r -32003
    # Contract (Gabriel, 2026-10-06): on a disabled control set_property may change Enabled (exact name) and nothing else.
    $r = SetProp $D 'Tag' '7'
    ExpectCode 'set_property: another property (Tag) on the disabled control' $r -32003
    $r = SetProp $D 'Enabled' 'false'
    Case 'set_property: Enabled=false again on the disabled control is elided' ((IsOk $r) -and ($r.J.result.elided -eq $true)) 'ok, elided=true' (Describe $r)
    $r = SetProp $D 'Enabled' 'true'
    Case 'set_property: Enabled=true on the disabled control' ((IsOk $r) -and ($r.J.result.elided -eq $false)) 'ok, elided=false' (Describe $r)
    $r = ReadProp $D 'Enabled'
    Case 'read_property: Enabled after the re-enable' ((IsOk $r) -and ([string]$r.J.result.value -ieq 'true')) "value 'True' (any case)" (Describe $r)
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $D }
    Case 'click: the re-enabled control' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq $F.DefaultVia) -and ($r.J.result.clicksDispatched -eq 1)) "ok, dispatchedVia=$($F.DefaultVia), clicksDispatched=1" (Describe $r)
    ExpectText 'click: the re-enabled control ran its OnClick' $M.DelayLabel 'waiting'
  }

  Section 'paths' {
    ExpectText 'path Form.Control: a control inside a panel' $M.InPanel $InPanelText
    ExpectText 'path Form.Panel.Control: the visual-parent fallback' $InPanelVisual $InPanelText
    $r = Tool 'get_text' @{ pid = $script:TargetPid; path = "$($M.Form).noSuchControlE2E" }
    ExpectCode 'path that does not exist' $r -32001
  }

  Section 'screenshot' {
    $r = Tool 'screenshot' @{ pid = $script:TargetPid; form = $M.Form }
    $c = @($r.Content)
    Case 'screenshot: two content blocks' ((-not $r.IsError) -and ($c.Count -eq 2)) '2 blocks, no isError' "$($c.Count) blocks, isError=$($r.IsError): $(Short $r.Text 200)"
    if ($c.Count -ge 1) {
      $data = [string]$c[0].data
      $noBreaks = ($data.Length -gt 0) -and ($data.IndexOf("`n") -lt 0) -and ($data.IndexOf("`r") -lt 0)
      Case 'screenshot: block 1 is an image/png with base64 and no line breaks' (($c[0].type -eq 'image') -and ($c[0].mimeType -eq 'image/png') -and $noBreaks) 'type=image, mimeType=image/png, data without CR/LF' "type=$($c[0].type), mimeType=$($c[0].mimeType), data length $($data.Length), no line breaks=$noBreaks"
      if ($c[0].type -eq 'image') {
        $bytes = [Convert]::FromBase64String($data)
        [IO.File]::WriteAllBytes($PngFile, $bytes)
        $sig = ($bytes[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Case 'screenshot: the data is a PNG' ($sig -eq '89 50 4E 47 0D 0A 1A 0A') 'PNG signature 89 50 4E 47 0D 0A 1A 0A' "$sig, $($bytes.Length) bytes, saved to $PngFile"
      }
    }
    if ($c.Count -ge 2) {
      $j = $null
      try { $j = ([string]$c[1].text) | ConvertFrom-Json } catch { $j = $null }
      $ok = ($c[1].type -eq 'text') -and ($null -ne $j) -and ($j.result.form -eq $M.Form) -and ($j.result.width -gt 0) -and ($j.result.height -gt 0) -and ($null -eq $j.result.PSObject.Properties['image'])
      Case 'screenshot: block 2 is text with form/width/height and no image field' $ok "type=text, result.form=$($M.Form), width>0, height>0, no result.image" "type=$($c[1].type), text=$(Short ([string]$c[1].text) 300)"
      if ($null -ne $j) {
        $script:FormShotW = [int]$j.result.width
        $script:FormShotH = [int]$j.result.height
        $pw, $ph = PngSize $r
        Case 'screenshot: width/height are the PNG size, scaled=false' (($pw -eq $script:FormShotW) -and ($ph -eq $script:FormShotH) -and ($j.result.scaled -eq $false)) "PNG $($script:FormShotW) x $($script:FormShotH), scaled=false" "PNG $pw x $ph, scaled=$($j.result.scaled)"
      }
    }
  }

  # path crops to one control, maxWidth scales down ("AI-INSTRUCTIONS - tool reference.md", section screenshot). The expected sizes come from read_property and the form shot above.
  Section 'screenshot path and maxWidth' {
    $pw0 = [double]::NaN; $ph0 = [double]::NaN
    $rw = ReadProp $M.Panel 'Width'
    $rh = ReadProp $M.Panel 'Height'
    $okW = (IsOk $rw) -and [double]::TryParse([string]$rw.J.result.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pw0)
    $okH = (IsOk $rh) -and [double]::TryParse([string]$rh.J.result.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ph0)
    Case 'read_property: the panel Width and Height' ($okW -and $okH) 'two numbers' "Width: $(Describe $rw) | Height: $(Describe $rh)"
    $wantW = [int][math]::Round($pw0)
    $wantH = [int][math]::Round($ph0)

    $r = Tool 'screenshot' @{ pid = $script:TargetPid; path = $M.Panel }
    $sw, $sh = PngSize $r
    if ($sw -gt 0) { [IO.File]::WriteAllBytes($PngPathFile, [Convert]::FromBase64String([string]@($r.Content)[0].data)) }
    $ok = (IsOk $r) -and (@($r.Content).Count -eq 2) -and ($r.J.result.path -eq $M.Panel) -and ($r.J.result.form -eq $M.Form) -and ($r.J.result.width -eq $wantW) -and ($r.J.result.height -eq $wantH) -and ($r.J.result.scaled -eq $false) -and ($sw -eq $wantW) -and ($sh -eq $wantH)
    Case 'screenshot path: the image is the panel, at its own size' $ok "2 blocks, path=$($M.Panel), form=$($M.Form), width=$wantW, height=$wantH, scaled=false, PNG $wantW x $wantH" "PNG $sw x $sh | $(Short (Describe $r) 300)"

    $mw = 200
    $wantSh = [math]::Round($script:FormShotH * $mw / $script:FormShotW)
    $r = Tool 'screenshot' @{ pid = $script:TargetPid; form = $M.Form; maxWidth = $mw }
    $sw, $sh = PngSize $r
    if ($sw -gt 0) { [IO.File]::WriteAllBytes($PngScaledFile, [Convert]::FromBase64String([string]@($r.Content)[0].data)) }
    $ok = (IsOk $r) -and ($script:FormShotW -gt $mw) -and ($r.J.result.width -eq $mw) -and ([math]::Abs($r.J.result.height - $wantSh) -le 1) -and ($r.J.result.scaled -eq $true) -and ($sw -eq $mw) -and ($sh -eq $r.J.result.height)
    Case "screenshot maxWidth=$($mw): the form scaled down, aspect kept" $ok "width=$mw, height=$wantSh (+-1), scaled=true, PNG the same size (form shot was $($script:FormShotW) x $($script:FormShotH))" "PNG $sw x $sh | $(Short (Describe $r) 300)"

    $mw = 100
    $wantSh = [math]::Round($wantH * $mw / $wantW)
    $r = Tool 'screenshot' @{ pid = $script:TargetPid; path = $M.Panel; maxWidth = $mw }
    $sw, $sh = PngSize $r
    $ok = (IsOk $r) -and ($r.J.result.width -eq $mw) -and ([math]::Abs($r.J.result.height - $wantSh) -le 1) -and ($r.J.result.scaled -eq $true) -and ($sw -eq $mw) -and ($sh -eq $r.J.result.height)
    Case "screenshot path + maxWidth=$($mw): the panel scaled down" $ok "width=$mw, height=$wantSh (+-1), scaled=true, PNG the same size" "PNG $sw x $sh | $(Short (Describe $r) 300)"

    $r = Tool 'screenshot' @{ pid = $script:TargetPid; path = $M.Panel; maxWidth = 5000 }
    Case 'screenshot path + maxWidth wider than the image: never scaled up' ((IsOk $r) -and ($r.J.result.width -eq $wantW) -and ($r.J.result.height -eq $wantH) -and ($r.J.result.scaled -eq $false)) "width=$wantW, height=$wantH, scaled=false" (Short (Describe $r) 300)

    $r = Tool 'screenshot' @{ pid = $script:TargetPid; path = "$($M.Form).noSuchControlE2E" }
    ExpectCode 'screenshot path: a path that does not exist' $r -32001
    $r = Tool 'screenshot' @{ pid = $script:TargetPid; form = $M.Form; maxWidth = -1 }
    ExpectCode 'screenshot maxWidth: a negative value' $r -32600
    $r = Tool 'screenshot' @{ pid = $script:TargetPid; path = $M.DelayTimer }
    ExpectCode 'screenshot path: a component that is not a control' $r -32005
  }

  Section 'set_keep_awake' {
    $r = Tool 'set_keep_awake' @{ pid = $script:TargetPid; enabled = $true }
    Case 'set_keep_awake: no-op on Windows' ((IsOk $r) -and ($r.J.result.applied -eq $false) -and ($r.J.result.platform -eq 'windows')) 'applied=false, platform=windows' (Describe $r)
  }

  Section 'modal recipe' {
    if ($IsVcl) {
      $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.DialogButton; mode = 'message' }
      Case 'modal recipe: click mode=message returns at once' ((IsOk $r) -and ($r.J.result.dispatchedVia -eq 'message')) 'dispatchedVia=message' "$(Describe $r) [$($r.Ms) ms]"
    }
    else {
      $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.DialogButton; timeoutMs = 500 }
      ExpectCode 'modal recipe (FMX): click with timeoutMs=500' $r -32004
    }
    $d = PollDialogs $true
    $dl = @()
    if (IsOk $d) { $dl = @($d.J.result.dialogs) }
    Case 'modal recipe: dismiss_dialog with no button lists the dialog' ((IsOk $d) -and ($d.J.result.supported -eq $true) -and ($dl.Count -ge 1) -and ([string]$dl[0].caption -eq $F.DialogCaption) -and (@($dl[0].buttons).Count -ge 1)) "supported=true, 1+ dialog with caption '$($F.DialogCaption)' and buttons" (DialogSummary $d)
    $r = Tool 'dismiss_dialog' @{ pid = $script:TargetPid; button = 'cancel' }
    # Application.MessageBox has real child Button windows, so the contract answer is via=BN_CLICKED (WM_COMMAND = dispatched blind by id).
    Case 'modal recipe: dismiss_dialog button=cancel' ((IsOk $r) -and ($r.J.result.clicked -eq $true) -and ([string]$r.J.result.via -eq 'BN_CLICKED') -and ([string]$r.J.result.clickedCaption -eq 'Cancel')) 'clicked=true, via=BN_CLICKED, clickedCaption=Cancel' "clicked=$($r.J.result.clicked), via=$($r.J.result.via), clickedCaption=$($r.J.result.clickedCaption), reason=$($r.J.result.reason) | $(Short (Describe $r) 150)"
    $d = PollDialogs $false
    Case 'modal recipe: the dialog is gone' ((IsOk $d) -and (@($d.J.result.dialogs).Count -eq 0)) 'dialogs=[]' (DialogSummary $d)
    $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $M.Counter }
    Case 'modal recipe: the form answers again' (IsOk $r) 'get_text ok' "$(Describe $r) [$($r.Ms) ms]"
    if ($M.Contains('DialogResult')) { ExpectText 'modal recipe: the dialog returned Cancel (mrCancel = 2)' $M.DialogResult 'Dialog closed with 2' }
  }

  Section 'blocked main thread' {
    $r = Tool 'click' @{ pid = $script:TargetPid; path = $M.DialogButton }
    Case 'blocked: a default click on the dialog button gives -32004 after its 5000 ms timeout' ($r.IsError -and ($r.Code -eq -32004) -and ($r.Ms -ge 4500) -and ($r.Ms -le 8000)) 'isError=true, error.code -32004, after 4500..8000 ms' "$(Describe $r) [$($r.Ms) ms]"
    $d = PollDialogs $true
    $dl = @()
    if (IsOk $d) { $dl = @($d.J.result.dialogs) }
    Case 'blocked: dismiss_dialog lists the dialog' ($dl.Count -ge 1) '1+ dialog' (DialogSummary $d)
    $args2 = @{ pid = $script:TargetPid; button = 'no' }
    if ($dl.Count -ge 1) { $args2.hwnd = [long]$dl[0].hwnd }
    $r = Tool 'dismiss_dialog' $args2
    Case 'blocked: dismiss_dialog button=no with hwnd frees the app' ((IsOk $r) -and ($r.J.result.clicked -eq $true) -and ([string]$r.J.result.via -eq 'BN_CLICKED') -and ([string]$r.J.result.clickedCaption -eq 'No')) 'clicked=true, via=BN_CLICKED, clickedCaption=No' "clicked=$($r.J.result.clicked), via=$($r.J.result.via), clickedCaption=$($r.J.result.clickedCaption), dialogHwnd=$($r.J.result.dialogHwnd), reason=$($r.J.result.reason) | $(Short (Describe $r) 150)"
    $d = PollDialogs $false
    Case 'blocked: the dialog is gone' ((IsOk $d) -and (@($d.J.result.dialogs).Count -eq 0)) 'dialogs=[]' (DialogSummary $d)
    $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $M.Counter }
    Case 'blocked: the app answers again' ((IsOk $r) -and ($r.Ms -lt 3000)) 'get_text ok within 3000 ms' "$(Describe $r) [$($r.Ms) ms]"
    if ($M.Contains('DialogResult')) { ExpectText 'blocked: the dialog returned No (mrNo = 7)' $M.DialogResult 'Dialog closed with 7' }
  }

  Section 'busy pipe (-32098)' {
    $disc = Join-Path $env:TEMP "Autopilot\active\$($script:TargetPid).pipe"
    $full = (Get-Content -LiteralPath $disc -Raw).Trim()
    $short = $full -replace '^\\\\\.\\pipe\\', ''
    $holder = New-Object IO.Pipes.NamedPipeClientStream('.', $short, [IO.Pipes.PipeDirection]::InOut)
    try {
      $holder.Connect(5000)
      Log "holding the pipe $full"
      $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $M.Counter }
      Case 'busy pipe: a tool call answers -32098 after its timeout' ($r.IsError -and ($r.Code -eq -32098) -and ($r.Ms -ge 4500) -and ($r.Ms -le 9000)) 'isError=true, error.code -32098, after 4500..9000 ms' "$(Describe $r) [$($r.Ms) ms]"
      $w = Tool 'wait_for' @{ pid = $script:TargetPid; path = $M.Counter; expectedText = 'never-E2E'; timeoutMs = 30000 }
      Case 'busy pipe: wait_for answers -32098 at its first poll, not at its 30000 ms deadline' ($w.IsError -and ($w.Code -eq -32098) -and ($w.Ms -lt 12000)) 'isError=true, error.code -32098, well before 30000 ms' "$(Describe $w) [$($w.Ms) ms]"
    }
    finally {
      $holder.Dispose()
      Log 'pipe released'
    }
    $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $M.Counter }
    Case 'busy pipe: after the pipe is released the next call works' (IsOk $r) 'get_text ok' "$(Describe $r) [$($r.Ms) ms]"
  }

  Section 'target not running (-32099)' {
    $bad = 3999996
    while ($null -ne (Get-Process -Id $bad -ErrorAction SilentlyContinue)) { $bad -= 4 }
    $r = Tool 'get_text' @{ pid = $bad; path = $M.Counter }
    ExpectCode "target not running: pid $bad does not exist" $r -32099
  }

  Section 'close the target' {
    [void]$script:App.CloseMainWindow()
    $exited = $script:App.WaitForExit(15000)
    Case 'the target closes on WM_CLOSE' $exited 'exits within 15 s' $(if ($exited) { "exit code $($script:App.ExitCode)" } else { 'still running' })
    $r = Tool 'get_text' @{ pid = $script:TargetPid; path = $M.Counter }
    ExpectCode 'target not running: a tool call after the app was closed' $r -32099
    $w = Tool 'wait_for' @{ pid = $script:TargetPid; path = $M.Counter; expectedText = 'never-E2E'; timeoutMs = 10000 }
    Case 'target not running: wait_for ends at once' ($w.IsError -and ($w.Code -eq -32099) -and ($w.Ms -lt 3000)) 'isError=true, error.code -32099, within 3000 ms' "$(Describe $w) [$($w.Ms) ms]"
    $disc = Join-Path $env:TEMP "Autopilot\active\$($script:TargetPid).pipe"
    $gone = -not (Test-Path -LiteralPath $disc)
    Case 'the discovery file of the closed app is gone' $gone "$disc does not exist" $(if ($gone) { 'gone' } else { 'still there' })
  }
}
catch {
  Case 'run (unexpected stop)' $false 'the run reaches its end' "stopped: $($_.Exception.Message)"
}
finally {
  # { Shut down our server, check its standard output and standard error }
  if ($null -ne $script:Server) {
    try { $script:StdinStream.Close() } catch { Log "closing standard input failed: $($_.Exception.Message)" }
    $exited = $script:Server.WaitForExit(15000)
    if (-not $exited) {
      Log "MCP server pid $($script:Server.Id) still running 15 s after standard input closed: killed (it is the copy this script started)"
      $script:Server.Kill()
    }
    else {
      # A read that timed out earlier still owns the reader: take its line first (ReadServerLine).
      $rest = ''
      if (($null -ne $script:PendingRead) -and $script:PendingRead.Wait(5000) -and ($null -ne $script:PendingRead.Result)) { $rest = $script:PendingRead.Result + "`n" }
      $script:PendingRead = $null
      $rest += $script:Server.StandardOutput.ReadToEnd()
      foreach ($line in ($rest -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l -eq '') { continue }
        $script:StdoutLines++
        $r = $null
        try { $r = $l | ConvertFrom-Json } catch { $r = $null }
        if (($null -eq $r) -or ($r.jsonrpc -ne '2.0')) { $script:BadStdout.Add((Short $l 200)) }
        Log ('<<< (after standard input closed) ' + (CutBase64 $l))
      }
    }
    Case 'server: exits when its standard input closes' $exited 'exit within 15 s' $(if ($exited) { "exit code $($script:Server.ExitCode)" } else { 'killed' })
    Case 'server: standard output carries only JSON-RPC lines' ($script:BadStdout.Count -eq 0) '0 lines that are not JSON-RPC' "$($script:StdoutLines) lines read, $($script:BadStdout.Count) not JSON-RPC: $($script:BadStdout -join ' || ')"
    $errText = $script:EarlierErr
    if (($null -ne $script:ErrTask) -and $script:ErrTask.Wait(5000)) { $errText += $script:ErrTask.Result }
    $errBytes = [Text.Encoding]::UTF8.GetByteCount($errText)
    Case 'server: standard error stays empty' ($errBytes -eq 0) '0 bytes' "$errBytes bytes: $(Short $errText 300)"
  }
  # { Never leave the app we started running }
  if (($null -ne $script:App) -and (-not $script:App.HasExited)) {
    Log "target pid $($script:TargetPid) still running at the end: killed (it is the app this script started)"
    $script:App.Kill()
  }
  $summary = "RESULT: $($script:Passed) of $($script:Total) PASS"
  Write-Host $summary
  $script:Results.Add($summary)
  Log ''
  Log $summary
  [IO.File]::WriteAllLines($ExchangeFile, $script:Lines,   (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllLines($ResultsFile,  $script:Results, (New-Object Text.UTF8Encoding $false))
}
if ($script:Passed -eq $script:Total) { exit 0 } else { exit 1 }
