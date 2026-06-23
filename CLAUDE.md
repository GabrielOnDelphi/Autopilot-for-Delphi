# CLAUDE.md

This file is the **internal architectural reference for future-Claude sessions** working on the bridge / MCP server / tests. It is NOT customer-facing and NOT a tool reference.

- Customer-facing overview, quick start, tool list: `README.md`.
- AI-driver brief (efficiency rules, decision recipes, anti-patterns, error envelope, subagent dispatch): `AI-INSTRUCTIONS.md`.
- Current operational state (what's done, what's next, footguns, resolved history): `HANDOVER.md`.
- Day-to-day operational commands (rerun tests, rebuild the MCP server, verify the bridge is alive): `RUNBOOK.md`.
- This file: locked architectural decisions, threading model, error codes, build/logging conventions, sources to lift technique from.


---

## Read order on a fresh session

1. `HANDOVER.md` — current state, gotchas, immediate next step. Read this FIRST.
2. `README.md` — customer-facing overview (so you know what we're shipping).
3. `AI-INSTRUCTIONS.md` — the AI-facing brief (customers receive this too). Efficiency model, tool reference, error envelope, subagent rule.
4. This file (`CLAUDE.md`) — architectural decisions + threading + build conventions.
5. `_Competition\Delphi AI debuggers - Competition.md` — AI-driver-niche competitive landscape. Read when discussing product/release decisions.
6. `_Competition\Delphi debuggers - Competition.md` — broader Delphi GUI test-automation survey (TestComplete / Ranorex). Different category; kept for context. §5.8 is the twelve-month launch checklist.
7. `_Competition\Commercialization.md` — pricing tiers, distribution plan, launch checklist.
8. `Plans/01_TargetUnit.md` — bridge unit (most plan content now reflected in code).
9. `Plans/02_McpServer.md` — MCP server.
10. `Plans/03_DemoApp.md` — demo app.
11. `Plans/04_Risks_OpenQuestions.md` — locked decisions and known risks.

When the plans conflict with the code, the code is authoritative.

---

## Keep the MD files current — every session

The .md files in the repo root (`CLAUDE.md`, `HANDOVER.md`, `README.md`, `AI-INSTRUCTIONS.md`) plus `_Competition\*.md` plus the four `Plans\*.md` files are the only continuity between sessions. Treat them as load-bearing project state, not commentary.

**Rule:** at the end of any session that changes code, update the affected .md files before stopping. Specifically:

- `HANDOVER.md` — the *what's next + what just happened* doc. Bump the "Last updated" header, move completed work out of "Pick up here", add a one-line resolved-history entry for the change. This is the file future-Claude reads first; if it lies, the next session burns 30 minutes rediscovering what you already knew.
- `CLAUDE.md` — the *architecture* doc. The "Architectural decisions" section reflects locked decisions; if you reopened one, mark it revised with the date. Do NOT add operational status here — that belongs in HANDOVER.
- `README.md` — the *customer-facing* doc. Tool list, quick start, supported Delphi versions, pricing placeholder. Update when adding tools, dropping/adding Delphi version support, or revising the licensing model. Do NOT add internal status tracking here.
- `AI-INSTRUCTIONS.md` — the *AI-facing* brief that customers also receive. Update whenever a tool's contract changes (new field, new error code, new coercion), the per-turn cost model changes (new model, new measurement), or the subagent dispatch rule changes. This file ships to customers — keep it free of internal R-numbers / HANDOVER references / private dates.
- `_Competition\*.md` files — refresh when a competitor ships a major release. Pricing benchmarks decay — re-verify the cited numbers before quoting them in marketing copy.
- `Plans\*.md` — if you implemented or changed the contract of something a plan describes (a tool signature, a wire field, a decision in `04_Risks`), update that plan in the same change. Don't carry "to-do" rows for things that are now done.

**Why this matters:** there is no git history at the project root, and the context-window summarizer drops detail you can't recover. The .md files ARE the history.

**Practical check before claiming a task done:** grep the .md files for the symbol/file/decision you touched. Every hit either still describes reality or gets edited in the same turn.

---

## What the project is (one sentence)

Autopilot for Delphi — a three-process pipeline that lets an AI assistant take control of and operate a running Delphi VCL or FMX application from the outside (click controls, set text, read state, drive workflows), not merely inspect it: AI host ↔ stdio MCP server (`Autopilot.Mcp.exe`) ↔ named pipe ↔ target app (which links in the `Autopilot.Bridge` unit). Customer-facing version of this picture is in `README.md`; AI-facing tool reference is in `AI-INSTRUCTIONS.md`.

**Status: NOT released yet.** Feature-complete in testing (12 MCP tools, VCL + FMX bridges, 101 tests passing; Android transport device-verified 2026-06-12, keep-screen-on device-verified 2026-06-14), but no public build, no public listing, pricing not final. **Licensed PolyForm Noncommercial 1.0.0 (free noncommercial / paid commercial) since 2026-06-23** — see the License decision below. Operational state lives in `HANDOVER.md`.

---

## How it works (architectural narrative)

A typical session uses three processes and one named pipe.

**Setup — one-time, done once per target project:**

The developer adds two lines to their Delphi project:

```delphi
uses
  ..., Autopilot.Bridge.Vcl;   // <-- 1. add the unit

begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Autopilot.Bridge.Vcl.StartBridge;  // <-- 2. start the bridge
  Application.Run;
end.
```

Then they add `AUTOPILOT` to the project's debug conditional defines. Release builds don't define it, so `StartBridge` becomes a no-op — no pipe, no thread, no automation surface in production.

**Step 1 — Target app starts.** The developer runs their Delphi app the normal way (F9 from the IDE, or from Explorer). `StartBridge` runs. The "bridge" is just code inside the app — it isn't a separate process. It does four things:

- Creates a worker thread (so blocking pipe I/O doesn't freeze the GUI).
- Creates a Windows named pipe at `\\.\pipe\Autopilot.<ExeName>.<PID>`, with an owner-only ACL (current Windows user SID resolved via `GetTokenInformation`).
- Writes a small text file at `%TEMP%\Autopilot\active\<PID>.pipe`. That file's only content is the full pipe name. This is the *discovery file* — it lets the MCP server find a target without enumerating Windows processes.
- The worker thread calls `ConnectNamedPipe`, which blocks until a client connects.

**Step 2 — AI host invokes an MCP tool.** Claude Code spawns `Autopilot.Mcp.exe` as a child process. The MCP server talks MCP-protocol JSON-RPC over stdio to Claude Code. It's a stateless translator: every tool call comes in, goes out to the pipe, comes back, goes out to Claude.

**Step 3 — MCP server attaches to the target.**

- The MCP server scans `%TEMP%\Autopilot\active\` for `.pipe` files.
- Exactly one file present → use that pipe name and connect. Multiple files → the AI must call `attach(pid)` explicitly. Zero files → return error `target_not_running`.
- After `CreateFile` on the pipe name succeeds, the bridge writes a `hello` frame: `{"hello":{"protocolVersion":1,"bridgeVersion":"0.1.0","pid":12345,"exe":"Autopilot.Demo.exe"}}`. The MCP server replies `{"helloAck":{"protocolVersion":1}}`. Mismatched versions = hard disconnect.

All frames on the pipe use **length-prefix framing**: a 4-byte little-endian uint32 giving the byte length of the JSON payload, then the UTF-8 payload itself. Newline-delimited JSON would corrupt `TMemo.Text` and similar string properties that legitimately contain `#10`.

**Step 4 — Each MCP tool call becomes one pipe round-trip.** Example: `click(path="MainForm.btnSave")`.

- MCP server writes one frame: `{"id":17,"cmd":"click","args":{"path":"MainForm.btnSave"},"timeoutMs":5000}`.
- Bridge worker thread reads the frame and parses JSON.
- The worker cannot touch VCL directly — VCL is single-threaded. It uses `TThread.Queue` to schedule an anonymous method on the **main thread**, then blocks on a `TEvent`.
- On the main thread, the anonymous method walks `Screen.Forms[]` to find the form, walks `Components[]` recursively to find the control, dispatches the click using the policy from Architectural decisions below, builds the response JSON, signals the `TEvent`.
- Worker wakes, writes response frame.
- MCP server reads frame and returns the result to Claude Code.

**Step 5 — Cleanup and recovery.** If the MCP server exits, the pipe goes into `ERROR_BROKEN_PIPE` on the bridge side. The worker catches that, calls `DisconnectNamedPipe`, loops back to `ConnectNamedPipe`. The bridge survives across many MCP-server lifetimes. Only `StopBridge` or `Application.OnDestroy` actually tears the bridge down — and that deletes the discovery file.

**Why three processes instead of one?** The MCP server's lifecycle is owned by Claude Code (spawned/killed by it). The target app's lifecycle is owned by the developer (runs for hours, possibly across many debug sessions). Decoupling them via a pipe lets either restart without breaking the other.

---

## Architectural decisions (see Plans/04)

These are decided. Do not relitigate unless the constraint that drove them has changed.

- **Compile guard:** `{$IFDEF AUTOPILOT}` — explicit opt-in. Lives in the *implementation* section only; interface always compiles. `StartBridge`/`StopBridge` are no-ops without the define. Reason: opening an IPC channel as a side-effect of `DEBUG` is too invasive — some debug builds ship to internal users.

- **MCP transport:** our own stdio JSON-RPC server at `Source\McpServer\Mcp\` (2026-05-19). Replaces the vendored GDK code. Protocol surface deliberately minimal: only the five methods Claude Code uses (`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`). Everything else returns -32601. Single-threaded read-line/dispatch loop on stdin/stdout.

- **Click dispatch:** default = `Btn.Click` for `TButton`. For other `TWinControl` descendants with a protected `Click`, use the `TWinControlClass(Control).Click` cast trick (`Vcl.UIACtrlProvider.pas:299`). Fall back to `OnClick(Self)` only when neither path exists (`TLabel`, `TImage`). Opt-in `mode='message'` → `PostMessage(BM_CLICK)`. Response always reports `dispatchedVia`. Optional `count` (1..1000, default 1) runs N clicks in one round-trip — dispatch path resolved once, `Enabled` re-checked between iterations, stops early with `stoppedReason='disabled'`. Response carries `clicksDispatched`.
  
  TODO: actions. If the button has an Action connected, we should execute the action.

- **Pipe security:** owner-only ACL via `ConvertStringSecurityDescriptorToSecurityDescriptor` with SDDL `'D:(A;;GA;;;<currentUserSid>)'`. Earlier attempt with the well-known SID `OW` blocked our own client; current implementation resolves the actual user SID via `GetTokenInformation(TokenUser)` and embeds it in the SDDL. Falls back to default ACL with a warning log if SD conversion fails. MCP server must run as the same OS user as the target. Plans/04 R7 RESOLVED.

- **Pipe name:** `\\.\pipe\Autopilot.<ExeName>.<PID>` (dot-delimited, no backslash hierarchy).

- **Pipe framing:** length-prefix from day one — `[4-byte LE uint32 length][UTF-8 JSON payload]`. Reason: `TMemo.Text` and similar string properties commonly contain `#10`; newline-delimited would corrupt them.

- **Discovery:** target writes `%TEMP%\Autopilot\active\<PID>.pipe` (single line, full pipe name) on `StartBridge`, deletes on shutdown. MCP server enumerates that folder. Stale files (>24h) cleaned on MCP startup.

- **Protocol handshake:** first pipe frame after `ConnectNamedPipe` is `{"hello":{"protocolVersion":1,"bridgeVersion":...,"pid":...,"exe":...}}`. MCP server replies `{"helloAck":{"protocolVersion":1}}`. Mismatch is a hard error.

- **Per-command timeout:** request carries optional `timeoutMs`. Defaults: 2000 ms (list/get), 5000 ms (click/set), 30000 ms (screenshot). `wait_for` is caller-supplied.

- **Connection recovery:** worker handles `ERROR_BROKEN_PIPE`/`ERROR_NO_DATA` by `DisconnectNamedPipe` + loop to `ConnectNamedPipe`. Bridge survives MCP-server restarts.

- **Bridge has zero LightSaber dependency.** Stdlib + VCL/FMX only.

- **Keep-screen-on (Android, 2026-06-14).** The FMX bridge sets `FLAG_KEEP_SCREEN_ON` on the activity window (`TAndroidHelper.Activity.getWindow.addFlags`/`clearFlags`, main-thread only). It is ON by default at `StartBridge` — the bridge exists only in AUTOPILOT builds, where the app is being driven and the OxygenOS/AOSP screen-off freezer would otherwise stall the socket accept — and toggleable at runtime via the new `set_keep_awake(enabled)` command/tool (the 12th). The VCL twin accepts the command as a no-op (`applied:false`, `platform:windows`): a Windows target is never OS-frozen while an automation client drives it, so keep-awake is meaningless there, but the command is accepted (not `unknown cmd`) so the shared MCP tool behaves uniformly across VCL and FMX targets. Does NOT fix the cold-start race — the screen must stay on until `StartBridge` runs. JNI symbols verified against `c:\Delphi\Delphi 13\source\rtl\android\Androidapi.JNI.GraphicsContentViewText.pas` (`JWindow.addFlags`/`clearFlags`, `TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON`).

- **TColor coercion is VCL-only.** The VCL bridge's `set_property` accepts `TColor` values as `'clRed'`/`'#FF0080'`/etc.; the FMX bridge does NOT. Reason: a 2026-05-15 source scan of `c:\Delphi\Delphi 13\source\fmx\` found **zero** uses of `System.UITypes.TColor` in 322 FMX `.pas` files — FMX uses `TAlphaColor` exclusively for color properties. Adding TColor support to the FMX bridge would be dead code. If a future FMX version introduces TColor properties, re-open this decision. **Delphi 11 note (2026-06-10):** the coercion is implemented with local helpers (`ColorToWebHex` / `ColorToDelphiHex` / `TryStringToColorCompat` in `Autopilot.Bridge.Vcl.pas`) because `ColorToStringExt` / `TryStringToColor` only exist from Delphi 12 — do not reintroduce those RTL calls.

- **Parent-inheritance auto-flip (VCL only, 2026-05-20).** `set_property` flips the matching `Parent<X>` to FALSE before writing `<X>` / `<X>.Inner` (Font.Size / Color / BiDiMode / ShowHint / DoubleBuffered / CustomHint / Ctl3D). Mostly redundant with VCL's own SetColor/FontChanged auto-flip; the real correctness gain is in the **elision path** — an `elided:true` resend never calls `SetValue`, so VCL never gets to do its own auto-flip. Pre-flipping makes the resulting state ("control owns this property") consistent regardless of elision. FMX bridge unchanged — FMX has no ParentFont equivalent.

- **Transport abstraction (2026-06-10/11, Phase B).** The session loop lives in `Autopilot.Bridge.Worker.pas` and drives an `IBridgeTransport` (`Autopilot.Bridge.Transport.pas`): `StartListening / AcceptConnection / ConnectionStream / RecycleConnection / WakeAndStop(AWorkerThread) / EndpointLabel`. Two implementations: `TPipeTransport` (Windows — absorbs the three pipe quirks: `ERROR_PIPE_CONNECTED` race, `FILE_FLAG_FIRST_PIPE_INSTANCE`, phantom self-connect swallowed via an internal stopping flag) and `TSocketTransport` (POSIX — AF_UNIX ABSTRACT socket `Autopilot.<pid>`, `select()` on {listen fd, self-pipe}, wake = one byte; fds close only in the destructor, after the worker join). Contracts: `AcceptConnection` returns TRUE only for a real serviceable client (FALSE = shutdown wake or transient failure, transport already cleaned up); `ConnectionStream` returns a NEW caller-freed stream per call (`THandleStream` in both transports — on POSIX its Read/Write map to `__read`/`__write`, valid on socket fds); `WakeAndStop` closes nothing and takes the worker `TThread` (the pipe needs its `Handle` for `CancelSynchronousIo`; the socket ignores it). The wire protocol is byte-identical across transports — a Phase-A MCP server talks to either bridge unmodified. The duplicated `StartBridgeInternal` in `Vcl.pas`/`Fmx.pas` stays duplicated on purpose (plan 05 risk rule 3).

- **License model (2026-06-23): PolyForm Noncommercial 1.0.0 — free noncommercial, paid commercial.** Relicensed from MPL-2.0. Source-available, **NOT open source**. `LICENSE` = a dual-license header + the verbatim PolyForm text; `COMMERCIAL-LICENSE.md` = the $25/developer commercial tier (PayProGlobal checkout `products[1][id]=134850`). This supersedes the old §2.3 hybrid (bridge-MPL + MCP-server-closed) and reverses §3.3 in `_Competition\Commercialization.md`. **Going-forward only:** the whole tree (incl. the MCP server source) had been pushed under MPL on 2026-06-22, and MPL grants are irrevocable for anyone who cloned that commit. **In-product nudge — debug/AUTOPILOT only, LOG-ONLY, no UI, no browser** (the MCP server is headless and runs unattended; an auto-opened browser would steal focus, fire to an empty chair, and break the very automation — rejected): `CommercialLicenseURL` + `CommercialLicenseHint` in `Autopilot.Bridge.Core.pas`, logged once per `StartBridge` / MCP boot under tag `license`; plus a one-time Book 5 cross-promo after 5+ MCP launches (`Autopilot.Mcp.UsageCounter.pas`, counter in `%APPDATA%\Autopilot\usage.ini`, tag `book`). **Caution:** `134850` is the TOOL licence; the Book 5 promo URL is separate (a placeholder until the book's own checkout is set).

---

## Threading model (critical — read before writing bridge code)

The bridge's transport runs on a **worker thread** (blocking pipe `ReadFile`/`WriteFile` on Windows, blocking `select()`/`accept()`/`__read` on Android — both behind `IBridgeTransport`, driven by `Autopilot.Bridge.Worker.pas`). Every VCL/FMX access **must** marshal to the main thread via `TThread.Queue` + `TEvent` to wait for completion. See `Plans/01_TargetUnit.md` for the pattern.

Per the global CLAUDE.md compiler-quirks note: `TThread.Queue`/`ForceQueue` only accept `TThreadProcedure` (parameterless `reference to procedure`). `TProc` and `TNotifyEvent` are not auto-compatible. Wrap them:

```delphi
TThread.ForceQueue(NIL, procedure begin Cb(); end);
```

Code-review rule: every VCL/FMX-touching helper inside the bridge dispatcher asserts main-thread affinity at the top in debug builds (risk R5). VCL bridge: `Assert(GetCurrentThreadId = MainThreadID)`. FMX bridge: `Assert(TThread.CurrentThread.ThreadID = MainThreadID)` — cross-platform form, since Fmx.pas no longer uses Winapi.Windows.

---

## Folder layout (current)

```
Autopilot for Delphi\
├── README.md                        repo copy — FULL internals (private; NOT the shipped one)
├── CLAUDE.md                        this file (internal architecture)
├── HANDOVER.md                      operational state
├── AI-INSTRUCTIONS.md               repo copy — FULL internals (private; NOT the shipped one)
├── _Release Package\                the SANITIZED shippable copy (see SHIP-CHECKLIST.md inside)
│   ├── README.md                    black-boxed customer overview (no transport/framing/ACL/cast)
│   ├── AI-INSTRUCTIONS.md           tool contracts + error codes only — zero build internals
│   ├── SHIP-CHECKLIST.md            internal: package contents, build steps, pre-zip leak-scan
│   ├── DCUs\Delphi11..13\           per-version bridge DCUs (built + link-verified 2026-06-10)
│   └── Demo\                        VCL + FMX demo EXEs
├── Plans\                           four .md files: Bridge, Mcp, Demo, Risks (real folder name has a LEADING SPACE — see HANDOVER footguns)
├── _Competition\                    three .md files: AI-driver niche, broader survey, Commercialization
├── Tools\
│   ├── DcuBuild\                    DCU release harness: BuildDcu.dproj (producer — links BOTH bridges in one compile) + BuildDcuVcl/Fmx.dproj (link-verify); procedure in SHIP-CHECKLIST §2
│   └── smoke-fmx.ps1
├── Source\
│   ├── Bridge\                      Autopilot.Bridge.Core/Transport/Worker/NamedPipe/Socket/Vcl/Fmx/Log.pas
│   ├── Common\                      shared types, MCP-side pipe client
│   └── McpServer\
│       ├── Autopilot.Mcp.dpr       + twelve Autopilot.Mcp.Tool.*.pas units (one per MCP tool)
│       └── Mcp\                     our minimal stdio MCP server (~640 LOC, 7 units)
├── DemoVCL\                         VCL dogfood app
├── DemoFmx\                         FMX dogfood app
└── Tests\                           DUnitX suite
```

The bridge ships as eight units, not one: `Core.pas` (shared types + framing), `Transport.pas` (the `IBridgeTransport` seam), `Worker.pas` (shared session loop — accept/handshake/serve/recycle, stdlib-only), `NamedPipe.pas` (Windows transport: pipe + ACL + discovery + CSI wake), `Socket.pas` (POSIX transport: AF_UNIX abstract socket + self-pipe wake; whole body POSIX-gated, so it compiles to an empty unit on Windows), `Vcl.pas` / `Fmx.pas` (framework-specific dispatcher), `Log.pas` (file logger, Win32 + POSIX write paths). The transport seam is what made Android possible without touching the dispatcher (Phase B, 2026-06-10/11). The Win32 DCU package ships seven of the eight — `Socket.dcu` is POSIX-only and never linked on Windows.

---

## Error model (locked)

JSON-RPC error envelope. Custom codes used across bridge and MCP server:

- `-32001 not_found` — no component matches path
- `-32002 ambiguous_path` — multiple matches without form prefix
- `-32003 control_disabled` — found but cannot act
- `-32004 main_thread_blocked` — `TThread.Queue` timed out
- `-32005 unsupported_action` — control class doesn't support requested action
- `-32006 rtti_property_missing` — property not exposed via RTTI
- `-32098 target_not_responding` — pipe write timeout (MCP side)
- `-32099 target_not_running` — pipe not connected (MCP side)

`AI-INSTRUCTIONS.md` has the same table tagged for the AI driver; this copy is the canonical one for bridge code changes.

---

## Build & tooling

- Use the `delphi-compiler` agent. It expects a `Build.cmd` per project.
- Bash quirk reminder (from `c:\Projects\CLAUDE.md`): never `cd /path && cmd //c Build.cmd`. Always `cmd //c "c:\\Full\\Path\\To\\Build.cmd" 2>&1`.
- Unit tests: DUnitX + TestInsight. Bridge tests build a synthetic form programmatically and exercise it over a synthetic pipe — works without a visible form.
- For debugging the running target: the DPT McpDebugger MCP is already registered (see global CLAUDE.md). Start session against the compiled EXE.

---

## Logging convention

Both bridge and MCP server log to `%TEMP%\Autopilot\<ExeName>-<PID>.log`. Every command in/out, errors, dispatch timings. Per the global zero-tolerance rule: no swallowed exceptions — log and re-raise, or return a typed error response. Never silently pass. (Exception, same as the logger's own outer handler: the usage-counter promo in `Autopilot.Mcp.UsageCounter.pas` logs-and-continues rather than reraising — a cosmetic nudge must not crash the host.)

Two product-nudge tags ride this same log, debug/AUTOPILOT only and never as UI (see the License decision above): `license` (the commercial-license reminder, every startup) and `book` (the one-time Book 5 link after 5+ MCP launches).

---

## Android support (Phase B 2026-06-10/11; device-verified 2026-06-12)

The FMX bridge is **cross-platform since Phase B**: on Windows it listens on the
named pipe, on Android on an AF_UNIX ABSTRACT socket `Autopilot.<pid>` reached via
`adb forward tcp:<hostPort> localabstract:Autopilot.<pid>`. Same dispatcher, same
framing, same twelve tools, byte-identical wire protocol. The VCL bridge stays
Windows-only by nature (VCL is Windows-only).

What the transport swap re-answered (the old "why it's hard" list, each item resolved):

1. **The pipe** → `Autopilot.Bridge.Socket.pas`: AF_UNIX abstract socket, `select()`
   on {listen fd, self-pipe} for the shutdown wake. The MCP side reuses Phase A's
   `Autopilot.Mcp.SocketClient.pas` over the adb-forwarded loopback port.
2. **Discovery file** → none needed on Android: the abstract name embeds the pid and
   the kernel removes it when the socket closes; the MCP server is told the endpoint
   explicitly via `--target adb:<port>`.
3. **Owner ACL** → accepted trade-off: abstract sockets have no access control;
   mitigations are the per-process name, the protocolVersion handshake, and the
   AUTOPILOT compile guard (debug builds only). Optional shared-secret frame remains
   a documented ~20-LOC add-on if parity is ever wanted.
4. **Same-machine assumption** → broken by `adb forward` (host TCP port → device
   abstract socket), the same mechanism Chrome remote debugging uses.
5. **Same-OS-user assumption** → replaced by the adb trust boundary (any process
   that can talk to the adb server can reach the forwarded port — same exposure
   class as every adb-based tool).
6. **`TThread.Queue` marshalling** → unchanged; it was always framework-agnostic.

**On-device validation: DONE (2026-06-12, OnePlus Nord, Android 12).** The full
checklist in `" Plans\05_AndroidTransport.md"` passed: adb-forward round-trip,
hello/helloAck, every drivable tool through `Autopilot.Mcp.exe --target adb:<port>`
(screenshot included), and the kill → restart → re-forward → re-attach cycle. The
kernel removes the abstract name on process death (verified in `/proc/net/unix`).
One platform constraint, not a bug: **the app must be foreground with the screen
on** — OxygenOS freezes the app ~25 s after screen-off (`OplusHansManager`), a
frozen process gets zero CPU, so a queued connect is only accepted on unfreeze.
**Mitigated 2026-06-14:** the FMX bridge sets keep-screen-on by default (`set_keep_awake`), so once `StartBridge` runs the screen stays on and the foreground app is never frozen; the residual is the cold-start window before `StartBridge` runs (hold the screen on for the first ~3 s of launch).
Recipe + evidence: HANDOVER → "Driving the demo on Android" + the freezer footgun.
Graceful `StopBridge` never runs on Android (BACK backgrounds the app; teardown is
SIGKILL) — the self-pipe wake contract stays pinned by the Windows fake-transport
tests. **Customer-facing copy still does NOT claim Android support** — lifting
that gate (claim it in v0.1 vs hold for v1.1) is the user's product decision.

**Getting the app onto the device without the IDE** — the generic headless `rsvars` + `msbuild /t:Make;Deploy` + `adb install` + `am start` loop and the one `.deployproj` IDE dependency now live in the cross-platform master doc (`c:\Projects\FMX\Compiling FMX projects for cross-platform targets\` → Stage 3). `Headless Android Build.md` here keeps only the Autopilot-specific bits (the committed `DemoFmx\DeployAndroid.cmd` entry point, package name, APK path). Plan 05 is the bridge bring-up once the app is running.

Android-side failure diagnosis stays passive (no interactive debugger):
`Logcat-Android.cmd`, the bridge log via `adb shell run-as <pkg> cat
cache/Autopilot/<name>-<pid>.log`, and `LightCore.ExceptionLogger.pas` —
the toolset survey lives in `c:\Projects\FMX\Bug reporter FMX\`.

### Embedding in a cross-platform host (post-Phase-B)

`Autopilot.Bridge.Fmx` now compiles for Windows + POSIX, so an FMX host needs **no
platform gating** — `uses Autopilot.Bridge.Fmx` + `StartBridge` work on both (the
AUTOPILOT define still rules whether any of it exists). The old Orinoco-style double
`{$IFDEF MSWINDOWS}` gate (around the `uses` AND the call) is still HARMLESS and
still correct for hosts that want automation strictly Windows-side — but it is no
longer required. `Socket.pas` is whole-body POSIX-gated and `NamedPipe.pas` is only
referenced from Fmx.pas's MSWINDOWS branch, so neither leaks into the wrong platform.
One .dpr rule remains: do NOT list `Autopilot.Bridge.NamedPipe` explicitly in a
cross-platform .dpr's uses (it is Win32-only; Fmx.pas pulls it transitively where it
belongs — see `DemoFmx\Autopilot.DemoFmx.dpr`).

---

## Sources to read for technique (not to depend on)

- `DPT.MCP.Server.pas` — structurally similar JSON-RPC stdio handler. Reference, not dependency.
- `c:\Delphi\Delphi 13\source\vcl\Vcl.UIACtrlProvider.pas` — `TUIAutomationCustomControlProvider`, fully implemented `IRawElementProviderSimple`/`IInvokeProvider`. The VCL never instantiates it (verified: every `WM_GETOBJECT` for `UiaRootObjectId` falls through `Vcl.Controls.pas:9474` to nil), but the class works. Two reuses:
  - Lift the `TWinControlClass(Control).Click` cast trick (line 299) for our click dispatcher.
  - Future: subclass it and populate `TForm.UIAutomationProvider` ourselves, giving Inspect.exe / Accessibility-Insights visibility as a free bonus on top of the bridge.
- Delphi 13's `UIAutomation` provider is otherwise inert skeleton code (verified via `Vcl.Controls.pas:9474-9477` returning nil and zero subclass instantiations across the entire Delphi 13 VCL source tree).

## Also see
c:\Projects\FMX\Compiling FMX projects for cross-platform targets\ — the cross-platform compile + headless Android deploy master doc. `Headless Android Build.md` (this folder) now keeps only the Autopilot-specific deploy entry point; the generic toolchain lives in the master.