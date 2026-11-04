# WHAT: runs the two DUnitX test exes of Autopilot for Delphi and fails on a red test, a leak log or (with --release) a stale exe.
# CALLER: a session or person after a build through light-compiler; a release script that must stop on red.
# Run-AllTests.ps1 - runs every DUnitX test exe of Autopilot for Delphi: Tests\Tests.exe (bridge + client) and Tests\Mcp\TestsMcp.exe (MCP server).
# It only RUNS the exes. It never builds: build Tests.dproj and Mcp\TestsMcp.dproj through the light-compiler agent first.
# The end-to-end script "E2E tests\Test-AllTools.ps1" is not run here: it needs a running target program.
#
# What it checks, for each exe:
#   - the exe's exit code and its DUnitX summary (a failed or errored test fails the run);
#   - a FastMM4 leak log "<exe name>_MemoryManager_EventLog.txt" beside the exe after the run (fails the run). An old log is sent to the Recycle Bin before the run;
#   - an exe older than the newest .pas/.dpr of its own test project (the units its .dpr names): a warning, or a failure with --release.
# The runners have no fixture folders to check (their tests write only to %TEMP%).
# Each run appends one line per exe to "Test runs.log" beside this script: date and time, exe, found, passed, failed, errored, FastMM log yes/no.
# The console output of each exe goes to "Temp\<exe name> - last run.txt" beside this script.
#
# Usage:   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Projects\Projects AI\Autopilot for Delphi\Tests\Run-AllTests.ps1" [--release]
# Exit codes: 0 = every exe ran green, no leak log, no stale exe (stale is only a warning without --release)
#             1 = at least one check failed; a line starting with "FAIL:" says which and why.

$ErrorActionPreference = 'Stop'
$Release = ($args -contains '--release') -or ($args -contains '-Release')

$TestsDir   = $PSScriptRoot
$LogFile    = Join-Path $TestsDir 'Test runs.log'
$OutDir     = Join-Path $TestsDir 'Temp'
$RecycleBin = 'c:\AI\Tools\System\RecycleBin.exe'

$Suites = @(
  @{ Exe = Join-Path $TestsDir 'Tests.exe';        Dpr = Join-Path $TestsDir 'Tests.dpr' },
  @{ Exe = Join-Path $TestsDir 'Mcp\TestsMcp.exe'; Dpr = Join-Path $TestsDir 'Mcp\TestsMcp.dpr' }
)

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$Failures = New-Object System.Collections.Generic.List[string]

# The newest of the .dpr and of every unit it names with "in '<path>'"
function Get-NewestSource([string]$DprPath) {
  $DprDir = Split-Path -Parent $DprPath
  $Files  = @($DprPath)
  foreach ($M in [regex]::Matches((Get-Content -LiteralPath $DprPath -Raw), "\bin\s+'([^']+\.pas)'", 'IgnoreCase')) {
    $P = Join-Path $DprDir $M.Groups[1].Value
    if (Test-Path -LiteralPath $P) { $Files += (Resolve-Path -LiteralPath $P).Path }
  }
  $Files | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Reads "Tests Found   : 93" and the like from the DUnitX console summary; -1 when the line is missing
function Get-Count([string[]]$Lines, [string]$Label) {
  $Hit = $Lines | Select-String -Pattern ("^Tests " + $Label + "\s*:\s*(\d+)") | Select-Object -Last 1
  if ($Hit) { [int]$Hit.Matches[0].Groups[1].Value } else { -1 }
}

foreach ($S in $Suites) {
  $Exe     = $S.Exe
  $ExeName = [IO.Path]::GetFileNameWithoutExtension($Exe)
  $ExeDir  = Split-Path -Parent $Exe

  if (-not (Test-Path -LiteralPath $Exe)) {
    $Failures.Add("$ExeName.exe not found ($Exe) - build it through light-compiler")
    continue
  }

  # Stale exe: older than the newest source of its own test project
  $Newest = Get-NewestSource $S.Dpr
  $ExeTime = (Get-Item -LiteralPath $Exe).LastWriteTime
  if ($Newest.LastWriteTime -gt $ExeTime) {
    $Msg = "$ExeName.exe ($ExeTime) is older than $($Newest.FullName) ($($Newest.LastWriteTime)) - rebuild it"
    if ($Release) { $Failures.Add($Msg) } else { Write-Host "WARNING: $Msg" }
  }

  # An old leak log must not fail a clean run: recycle it first
  $LeakPattern = "$ExeName*_MemoryManager_EventLog.txt"
  foreach ($Old in @(Get-ChildItem -LiteralPath $ExeDir -Filter $LeakPattern -File)) {
    & $RecycleBin $Old.FullName | Out-Null
  }

  Write-Host "Running $Exe ..."
  $OutFile = Join-Path $OutDir "$ExeName - last run.txt"
  Push-Location $ExeDir
  $SavedPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # PowerShell 5.1 turns each stderr line of a native exe into an error record; with 'Stop' the first one would end this script
  try {
    & $Exe *> $OutFile
    $ExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $SavedPref
    Pop-Location
  }

  $Lines   = @(Get-Content -LiteralPath $OutFile)
  $Found   = Get-Count $Lines 'Found'
  $Passed  = Get-Count $Lines 'Passed'
  $Failed  = Get-Count $Lines 'Failed'
  $Errored = Get-Count $Lines 'Errored'
  $LeakLog = @(Get-ChildItem -LiteralPath $ExeDir -Filter $LeakPattern -File)
  $HasLeak = $LeakLog.Count -gt 0

  $Summary = "$ExeName.exe: found $Found, passed $Passed, failed $Failed, errored $Errored, exit code $ExitCode, FastMM log " + $(if ($HasLeak) { 'yes' } else { 'no' })
  Write-Host $Summary
  Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("{0}  {1}  found {2}  passed {3}  failed {4}  errored {5}  FastMM log {6}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), "$ExeName.exe", $Found, $Passed, $Failed, $Errored, $(if ($HasLeak) { 'yes' } else { 'no' }))

  if ($Found -lt 0)                    { $Failures.Add("$ExeName.exe printed no DUnitX summary (crashed?) - see $OutFile") }
  if ($Failed -gt 0 -or $Errored -gt 0) { $Failures.Add("$ExeName.exe: $Failed failed, $Errored errored - see $OutFile") }
  if ($ExitCode -ne 0)                 { $Failures.Add("$ExeName.exe ended with exit code $ExitCode - see $OutFile") }
  if ($HasLeak)                        { $Failures.Add("$ExeName.exe left a FastMM4 leak log: $($LeakLog[0].FullName)") }
}

if ($Failures.Count -gt 0) {
  foreach ($F in $Failures) { Write-Host "FAIL: $F" }
  Write-Host "RESULT: FAILED ($($Failures.Count) problem(s))"
  exit 1
}
Write-Host 'RESULT: ALL GREEN'
exit 0
