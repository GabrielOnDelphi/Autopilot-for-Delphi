# RUNBOOK — Autopilot for Delphi

Day-to-day operational commands, split out of `HANDOVER.md` (which now tracks only state + next steps + gotchas). Build, test, and bridge-liveness recipes live here.

---

## Re-run the test suite

Build `Tests\Tests.dproj` via the light-compiler agent, then run `Tests\Tests.exe`.

Expected: **105 pass, 0 ignored, 0 leaked** (last verified 2026-06-25 PM). `Tests.LeakSuppressor.pas` swallows the 3rd-party `EInOutError` + companion FMessage leak.

---

## Rebuild the MCP server

Build `Source\McpServer\Autopilot.Mcp.dproj` via the light-compiler agent.

**Kill the running instance first** (`Stop-Process -Name Autopilot.Mcp -Force`) — the registered MCP server locks `Autopilot.Mcp.exe` for the whole Claude Code session, so an in-session rebuild silently leaves the old EXE on disk (HANDOVER Footguns). After rebuilding, Claude Code needs a restart to pick up the new EXE. Confirm the new build by checking the EXE timestamp.

---

## Verify the bridge is alive without writing code (Windows)

```powershell
Get-ChildItem "$env:TEMP\Autopilot\active\"
Get-Content "$env:TEMP\Autopilot\active\$pid.pipe"
Get-ChildItem \\.\pipe\ | Where-Object Name -like "Autopilot.*"
```

---

## Verify the bridge is alive (Android)

```powershell
adb shell pidof com.embarcadero.Autopilot_DemoFmx                  # app runs?
adb shell "cat /proc/net/unix | grep Autopilot"                   # @Autopilot.<pid> listening? (a second St=02 row = a connect queued while the app was FROZEN)
adb shell run-as com.embarcadero.Autopilot_DemoFmx cat cache/Autopilot/-<pid>.log
```

The `adb.exe` to use: `c:\Delphi\Delphi 13\CatalogRepository\AndroidSDK-37.0.59082.6021\platform-tools\adb.exe`.

---

## Android smoke probes (from the PC)

`Tools\smoke-android-mcp.ps1` runs the full tool burst over `--target adb:<port>`; `Tools\smoke-android-hello.ps1` is the raw-wire hello + `list_tree` probe. The full driving recipe (wake, dismiss-keyguard, forward, attach) is in `HANDOVER.md` → "Driving the demo on Android".
