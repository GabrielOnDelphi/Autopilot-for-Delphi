# Autopilot for Delphi — instructions for AI sessions

> **This file is a briefing** for an AI coding assistant (Claude Code, Claude Desktop, Cursor, Cline, or any MCP-aware host) that has the `autopilot` MCP server registered and wants to drive a running Delphi VCL or FMX application. Read it once at the start of a session; you do not need to re-read.
> 
> **Two audiences, same content:** the **product developer** (us) links it from the repo CLAUDE.md; the **customer** drops a copy into their own Delphi project and links it from *their* CLAUDE.md so AI sessions there know how to drive their app.

---

## TL;DR — the eight rules

1. **Minimize turns, not tool calls.** One LLM turn ≈ 1–8 s of inference cost. The bridge itself is sub-millisecond. Ten tool calls in one turn is ~10× cheaper than one call per turn for ten turns.
2. **Use `count=N` on `click` for repetitive same-action work.** Range 1..1000. One tool call, one turn, regardless of N.
3. **Bundle independent tool calls into a single assistant turn (parallel tool_use).** If you need to click A, set text on B, and read C, emit all three tool_use blocks in one response — do not split into three turns.
4. **Don't pre-flight with `list_tree` if you already know the path.** Discovery once, then act.
5. **`set_property` returns `availableProperties` on a typo.** A single failed call gives you every writable property with its `kind` and live `currentValue`. Use it — do not blind-guess property names twice.
6. **`screenshot` is a fallback, not a verification.** For correctness checks, `get_text(...)` returns the exact string in a few ms with no image tokens. Reserve `screenshot` for layout/visual bugs you cannot read structurally.
7. **`set_property` skips writes that wouldn't change the value (write-side elision).** The response carries `elided: true|false` — `true` means `OnChange` did NOT fire. Use that to distinguish "I caused a change" from "the value was already correct".
8. **Hand off scripted sequences of ≥ 5 sequential tool calls to a dedicated subagent.** Not relevant on hosts other than Claude Code; on Claude Code, see "Subagent dispatch" below.

**Launching an app no longer steals the keyboard focus** — a LightSaber VCL app built with `AUTOPILOT` comes up visible but unfocused (`TLightForm` gates its startup windows with `WS_EX_NOACTIVATE`), so you can launch and drive it while the user keeps typing elsewhere; this does NOT apply to FMX, nor to an app that calls `SetForegroundWindow` / `Application.BringToFront` during startup — including an app with a `TCoolTrayIcon` whose `FocusFormOnShow` is still TRUE (that component grabs the foreground on every show of its owner form; clear the field in `FormCreate`, under an AUTOPILOT conditional) — see `Issues\No focus steal\`.

---

## The thirteen MCP tools — full reference

The MCP server is registered as `autopilot`. Tool names appear in your tool list as `mcp__autopilot__<name>`. Every tool accepts an optional `pid` argument when more than one Delphi target is running — omit it when only one target is present and the bridge auto-attaches.

### `attach`

`attach(pid?)`

Establishes the pipe connection to a running target. **You almost never need to call this explicitly.** Every other tool calls `attach` lazily on its first invocation. Call `attach` only:

- When the previous tool returned `-32099 target_not_running` AND you want to retry after the user has restarted the target.
- When `ListTargets` reports multiple live targets and you need to choose by PID.

Return shape on success: `{pid, exe, pipeName, bridgeVersion, protocolVersion}`.

### `list_tree`

`list_tree(pid?)`

Enumerates all forms and their controls. Returns a JSON array. Each node carries:

- `form` — owning form name (e.g. `"frmMain"`).
- `name` — component name, or a synthetic `@TButton#N` for unnamed components.
- `path` — the dotted path you paste directly into `click`/`get_text`/`set_text` etc.
- `class` — Delphi class name.
- Optional `text` — `Caption`/`Text`/`Lines.Text` where readable. Missing on classes that have no text property OR where the getter threw.
- Optional `enabled`, `visible` — boolean state where readable.
- Optional `synthetic: true` — flag on synthetic names.

The first node is the form itself (with the form's path equal to its name). Subsequent nodes are children. The walk recurses into runtime-owned containers (frames, dynamic panels) — for design-time-placed frames, controls already appear at the form level because the Delphi streaming system reparents them at load time.

**Path forms accepted by every tool that takes `path`:**

- `Form` — the form itself (e.g. `frmMain`).
- `Form.Leaf` — BFS shallow-first search for `Leaf` anywhere under `Form` (e.g. `frmMain.btnSave`). Convenient but ambiguous if `Leaf` appears in multiple branches.
- `Form.A.B.C` — anchored. Each segment is a direct child of the previous (e.g. `frmMain.pnlToolbar.btnSave`). Unambiguous; use this for nested controls.

### `click`

`click(path, count?, mode?, timeoutMs?, pid?)`

Default behavior: invokes the control's `Click` (`TButton.Click` for buttons, `TWinControlClass(Ctrl).Click` cast for other TWinControl descendants, falling back to `OnClick(Self)` for non-TWinControl visuals like TLabel/TImage with `OnClick` handlers).

- `count` (1..1000, default 1) — fires N clicks in one round-trip. Bridge resolves the dispatch path once, re-checks `Enabled` between iterations, stops early with `stoppedReason='disabled'` if the control becomes disabled mid-loop.
- `timeoutMs` — overrides the bridge's main-thread wait for this call, in milliseconds. Default 5000 for a single click, 5000 + (count-1)*100 for batched clicks. Pass a short value (e.g. 500) when the click will open a modal dialog — expect `-32004 main_thread_blocked`, then call `dismiss_dialog`.
- `mode='message'` (VCL-on-Windows only, implemented 2026-07-07) — posts `BM_CLICK` to the control and returns at once; the click runs when the app next pumps messages, AFTER this response. Only button-class controls handle `BM_CLICK` (`TButton`/`TBitBtn`/`TCheckBox`/`TRadioButton`) — any other class is rejected with `-32005` instead of silently no-opping. **The main use: a button whose `OnClick` opens a modal dialog** — `mode='message'` returns immediately (no `-32004`), then call `dismiss_dialog`. FMX targets reject the mode with `-32005` (use the `timeoutMs` recipe there). Windows caveat (documented BM_CLICK behavior): a button inside a native dialog box may ignore `BM_CLICK` when that dialog is not the active window — but for native dialogs you should be using `dismiss_dialog` anyway.

Return shape: `{dispatchedVia: 'click' | 'onclick' | 'message', clicksDispatched: N, stoppedReason?: 'disabled'}` — `'click'` = the control's `Click` method ran (buttons and other windowed controls), `'onclick'` = the `OnClick` handler was invoked directly (non-windowed visuals like `TLabel`), `'message'` = a `BM_CLICK` was posted (async). With `mode='message'` + `count`, all posted clicks run after the response returns, so the between-iterations `Enabled` re-check cannot see those clicks' own effects.

**Click the control, not the `TAction` — or use `execute_action`.** A `TAction` / `TBasicAction` has no `OnClick` (it carries `OnExecute`), so `click(path='Form.actFileExit')` fails with `-32005 unsupported_action` ("has no OnClick"). Two ways out:
- **`execute_action(path='Form.actFileExit')`** — fires the action's `OnExecute` directly. Use this for shortcut-only actions (no menu item or button), and for actions shared by several controls when you don't want to pick one. See `### execute_action` below.
- **`click(path='Form.btnExit')`** — click the control bound to the action. Runs the action's `OnExecute` through the normal action dispatch. Use this when you want to verify the *control's* binding, not just the action.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action`, `-32600 invalid_request` (a `count` outside 1..1000, or non-integer like `1.5`).

### `execute_action`

`execute_action(path, pid?)`

Fires `TBasicAction.Execute` directly — runs the action's `OnExecute` handler. Use this when the command is bound to a `TAction` whose handler carries the logic:

- **Shortcut-only actions** that no control clicks (e.g. `actFileExit` triggered only by Alt+F4 / a hotkey). `click` cannot reach these; `execute_action` is the only way.
- **Actions shared by several controls** (toolbar button + menu item + shortcut). One `execute_action` is more direct than picking one of the bound controls and clicking it.

`path` must resolve to a `TBasicAction` descendant (`class:"TAction"` in `list_tree`). Plain controls are rejected — use `click` for those.

`execute_action` honors `Enabled`: a disabled action refuses with `-32003 control_disabled`. (Base `TBasicAction.Execute` fires `OnExecute` regardless of `Enabled` — the bridge adds the guard so you don't get a false-positive on a logically-disabled command.)

Return shape: `{path, dispatchedVia: 'Execute', executed: true | false}`. `executed: false` means the action had no `OnExecute` handler assigned — a real, reportable state, not an error.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action` (path resolved but isn't a `TBasicAction` — use `click`), `-32603 internal_error` (the `OnExecute` handler raised).

### `get_text`

`get_text(path, pid?)`

Reads `Caption` / `Text` / `Lines.Text` via RTTI. Returns the exact string (including embedded `#10` newlines — that's why the wire framing is length-prefixed instead of newline-delimited).

Use this (NOT `screenshot`) to verify that a click produced the expected state. It is ~1000× cheaper.

### `set_text`

`set_text(path, text, pid?)`

Writes `Text` (or `Caption` for label-class controls) via RTTI. `OnChange` fires synchronously as a side effect of the RTL setter chain. There is no `mode='message'` opt-in yet — file a feature request if you hit a fidelity gap.

### `set_checked`

`set_checked(path, checked, pid?)`

`checked: true | false`. Flips `Checked` (VCL) / `IsChecked` (FMX) and fires `OnChange` / `OnClick`.

### `set_property`

`set_property(path, propName, value, pid?)`

**The Swiss army knife.** Writes any published, writable property on any control via RTTI. Use this when `set_text` and `set_checked` don't fit. Examples:

- `set_property(path='frmMain.pnlMain', propName='Tag', value='42')`
- `set_property(path='frmMain.lblStatus', propName='Color', value='clRed')` — VCL TColor: `clName`, `#RRGGBB`, `$00BBGGRR`, or decimal.
- `set_property(path='frmMain.rectBox', propName='Fill.Color', value='#FF8000')` — FMX TAlphaColor: `#RRGGBB` (alpha=FF), `#AARRGGBB`, `claName`, or decimal.
- `set_property(path='frmMain.cmbItems', propName='ItemIndex', value='2')`
- `set_property(path='frmMain.pnlToolbar', propName='BevelEdges', value='[beLeft,beTop]')` — set-of-enum: `[a,b]`, `a,b`, `[]`, or ordinal.
- `set_property(path='frmMain.btnSave', propName='Font.Size', value='14')` — one-level dotted path through a tkClass outer to a simple inner.
- `set_property(path='frmMain.lstLog', propName='Lines.Text', value='line one'#10'line two')`

**Supported property kinds:** string (and L/W/U variants), integer, int64, boolean, other enumerations (by identifier `'poDesigned'` or ordinal `'1'`), set-of-enum (see above), float (Single / Double / TDateTime), TAlphaColor (FMX), TColor (VCL).

**Discovery on unknown property name:** the failure response carries `error.data.availableProperties` — a JSON array of `{name, kind, currentValue?}` entries covering every writable published property. **Use this aggressively.** One failed `set_property` shows you the entire writable surface AND the live values — much cheaper than a chain of `get_text` calls or a `screenshot`. `kind:'class'` entries (Font, Lines, Brush, Fill, …) are candidates for one-level dotted writes.

**Write-side elision** (this is important): before each write, the bridge reads the live value and skips `SetValue` if the coerced new value equals it. The response carries `elided: true|false`:

- `elided: true` — value was already what you asked for; `OnChange` did NOT fire.
- `elided: false` — a real write happened; `OnChange` did fire (if the control has one).

Comparison is type-aware: string identity, integer/int64 equality (TAlphaColor/TColor as 32-bit), boolean equality, enum/set ordinal equality (so `[fcRed,fcBlue]` elides against `[fcBlue,fcRed]`), float exact-bits (no epsilon). This means you can resend the same value harmlessly and the host app won't see a phantom `OnChange`.

**Parent-inheritance auto-flip (VCL only):** when a write to `Font.*`, `Color`, `BiDiMode`, `ShowHint`, `DoubleBuffered`, `CustomHint`, or `Ctl3D` SUCCEEDS (including an elided resend), the bridge sets the matching `Parent<X>:=FALSE`, so the state is always "the control owns this property". (The VCL only does that flip itself on a *value-changing* write, which an elided resend never reaches.) Success-only since 2026-07-07: a REJECTED value (bad coercion, read-only inner) leaves `Parent<X>` untouched instead of detaching inheritance as a side effect of a failed call. Silent (no response field). To restore inheritance, write `ParentFont:=true` (or the matching `Parent<X>`) afterward. FMX has no equivalent and does not flip.

### `read_property`

`read_property(path, propName, pid?)`

**The general-purpose live-state reader.** Returns any readable published property by RTTI. The returned `value` string is exactly what `set_property` would accept back — round-trip-safe.

- Examples:
  - `read_property(path='frmMain.btnSave', propName='Tag')` → `{value: '42', kind: 'integer'}`
  - `read_property(path='frmMain.lblStatus', propName='Color')` → `{value: 'clRed', kind: 'color'}` (VCL) or `{value: 'claRed', kind: 'alphacolor'}` (FMX)
  - `read_property(path='frmMain.cmbItems', propName='ItemIndex')` → `{value: '2', kind: 'integer'}`
  - `read_property(path='frmMain.btnSave', propName='Font.Size')` → `{value: '14', kind: 'integer'}` (one-level dotted)
  - `read_property(path='frmMain.pnlToolbar', propName='BevelEdges')` → `{value: '[beLeft,beTop]', kind: 'set'}`

**Use this instead of writing diagnostic files in the target.** A common anti-pattern: the AI patches the host source with `Diag := TStringList.Create; Diag.Add('X = ' + ...); Diag.SaveToFile(...)`, recompiles, runs, reads the file. If `X` is a published property on a discoverable component, `read_property` returns it in one round-trip with **no recompile**. (If `X` is a local variable or a function return — see "Debug channel selection" below.)

**Does NOT enforce Enabled.** Reading state off a disabled control is a legitimate debug case ("why is btnSave greyed out? what's its Tag? what's its Action.Enabled?"). Contrast with `click` / `set_property`, which refuse to act on disabled controls.

**Discovery on unknown propName:** the `rtti_property_missing` response carries `error.data.availableProperties` — same shape as `set_property` but filtered by `IsReadable` instead of `IsWritable`. So write-only-then-removed properties on legacy components still show up.

**Class-typed leaves** (`Font`, `Brush`, `Lines`, `Fill`) cannot be read directly — the response would be a meaningless object pointer. The tool returns `unsupported_action` with a hint to use a dotted propName (`Font.Size`, `Lines.Text`, `Fill.Color`).

**vs. `get_text`:** `get_text` is specialized for `Text` / `Caption` / `Lines.Text` and handles the variation in property name across control classes. `read_property` is general but requires you to know the exact property name. Use `get_text` for the common text-readback case; use `read_property` for everything else.

### `wait_for`

`wait_for(path, expectedText, timeoutMs?, pollIntervalMs?, pid?)`

Polls the control's `Text`/`Caption` every `pollIntervalMs` (default 100) until it equals `expectedText` exactly, or `timeoutMs` (default 10000) expires. Use after kicking off asynchronous work (a `TTask`, a database query, a Win32 timer). Text/Caption only — other properties (`Checked`, `Enabled`) are not pollable yet; read them with `read_property`.

Returns `{matched, currentValue, expectedValue, pollCount}`. A timeout is `matched: false` carrying the last observed value (a reportable state, not an error), so branch on the field.

### `screenshot`

`screenshot(form?, pid?)`

Captures the named form (or the main form if `form` omitted) as a PNG. Returns a base64 string.

**Use sparingly.** PNGs cost image tokens in the LLM context and the encode round-trip is the most expensive single bridge call (~30 ms for a typical form vs sub-ms for everything else). Justified for: layout bugs, color/theme issues, font rendering glitches, "the AI cannot tell whether the form is in the state it thinks it's in" tiebreakers.

### `set_keep_awake`

`set_keep_awake(enabled, pid?)`

Android only — keeps the device screen on while you drive the app, by setting the `FLAG_KEEP_SCREEN_ON` window flag. The FMX bridge turns this ON automatically at startup, so you rarely call it; pass `enabled=false` to release it, `enabled=true` to re-assert it. On a Windows (VCL) target it is a no-op (`applied:false`, `platform:windows`) — a desktop app is never OS-frozen while you drive it.

Response: `{enabled, platform:'android'|'windows', applied}`. `applied:true` means the window flag was changed; `applied:false` means the platform ignores it.

Why it matters on Android: a backgrounded or screen-off app is frozen by the OS (it gets no CPU), which stalls the bridge. Keep-awake holds the screen on so the foreground app keeps running. It does NOT cover the cold-start window before the bridge starts — keep the device screen on through app launch.

### `dismiss_dialog`

`dismiss_dialog(button?, hwnd?, pid?)`

Lists and dismisses native OS dialogs that the component tools cannot see. `Application.MessageBox`, a default `ShowMessage`/`MessageDlg` (a Vista Task Dialog), and the common file dialogs are raw Win32 windows with no `TComponent`, so `list_tree`/`click` return `-32001 not_found` against them. This tool reaches them through Win32 directly.

- Call with **no `button`** to LIST the dialogs currently up. Response: `{dialogs:[{hwnd, class, caption, text, buttons:[{id, caption, enabled}]}], supported, platform}`.
- Call with **`button`** to dismiss one. `button` is a role (`ok`/`cancel`/`yes`/`no`/`retry`/`abort`/`ignore`/`close`/`tryagain`/`continue`), a button caption (exact then substring, case-insensitive), or a numeric control id. `hwnd` targets a specific dialog when several are stacked; omit it for the topmost. Response adds `{clicked, clickedId, clickedCaption, dialogHwnd, via, reason?}`. `reason` is `no_dialog`, `button_not_found`, or `send_failed` (button found, but the OS reported the click was not delivered) when `clicked:false`.
- **Check `via` before you trust `clicked:true`.** `via:'BM_CLICK'` means the button's own window was found and clicked — verified. `via:'WM_COMMAND'` means the button is not a separate window (a Task Dialog common button, or a role/id that dialog does not actually have) so the command was dispatched **by id, blind**: a dialog with no such command silently ignores it and the send still reports success. After a `WM_COMMAND` dismiss, call `dismiss_dialog` again with no `button` — an empty `dialogs` array is the only proof the dialog is gone.

**The footgun this solves.** When you `click` a control whose `OnClick` opens a modal dialog, that click never returns — the main thread enters the dialog's modal loop. Two recipes:

- **Preferred (VCL button-class controls, 2026-07-07):** `click(path, mode='message')` — returns immediately (the `BM_CLICK` is posted; the dialog opens after the response), then `dismiss_dialog(button=...)`. No error, no timeout burned.
- **Fallback (FMX targets, or non-button controls):** pass a short `timeoutMs` to the `click`, expect `-32004 main_thread_blocked`, then call `dismiss_dialog(button=...)`.

Either way the dialog's own modal loop still pumps the bridge, so the dismiss lands and the app unblocks.

Windows targets only. Against an Android FMX target the response is `supported:false` (Android dialogs are ART windows, out of Win32 reach).

---

## Debug-channel selection — read live state without a recompile

When you need to inspect the host app's state during a debug session, pick the cheapest channel that works. In order:

1. **`get_text` / `read_property`** — for any value that lives on a published property of a discoverable component. Both are one round-trip, no host changes. This is ~70% of debug cases.
2. **`set_property` with a deliberate bogus propName** — when you don't know the property name yet. The `availableProperties` payload returns the entire writable surface with live values in one round-trip. Once you know the name, use `read_property` on subsequent calls.
3. **Host-side `Log.Write` / `RamLog.AddInfo`** — when the value is NOT a published property (a local variable, a function return like `IsDarkStyle`, an intermediate computed value, or state inside a method during a specific code path). Add a logging call in the host source, recompile, run, then read the log file at `%TEMP%\Autopilot\<ExeBaseName>-<PID>.log` (the bridge's own log) — or in LightSaber projects, `AppData.RamLog`'s file.
4. **Host-side `Diag.SaveToFile` scratchpad** — last resort. Only when (1)–(3) all fail to fit. Each scratchpad file you write requires a recompile cycle AND leaves a stray file in the host's data folder; prefer logging.

**Critical anti-pattern: writing a scratchpad file when read_property would work.** Before patching the host with `Diag.SaveToFile(...)` to dump a value, ask: is it a published property on a named component? If yes — call `read_property` instead (no recompile, one round-trip). **When a recompile IS unavoidable**, batch every value you want into ONE logging block, not separate `Diag.SaveToFile` calls — one cycle, one read.

---

## Efficiency rules — read once, follow always

The bridge round-trip is sub-millisecond; the cost is **per-turn LLM inference**:

```
total_time ≈ (turns × per_turn_inference) + (tool_calls × ~1ms bridge_time)
```

Per-turn inference is ~1–8 s on Opus 4.7, ~0.3–1 s on Haiku 4.5 — the bridge is noise next to either. Measured warm-cache Opus 4.7 (2026-05): a turn costs ~20–26 s whether it carries one tool call or many, and `click(count=1000)` spent 62 ms of total bridge time. **The LLM turn dominates every scenario — the eight rules above all exist to remove *turns*, not bridge calls.** The one case where extra turns are unavoidable is a react-to-result loop ("click Save; if status shows 'error', read the error label"): the LLM must see each intermediate result, so use the most capable model and don't micro-optimize.

**Prompt-cache awareness.** Anthropic's prompt cache TTL is 5 minutes (cached input tokens cost 10% of base). Back-to-back calls within 5 minutes ride a warm cache; the first call after a long pause eats full input cost. When measuring latency, control for cache state — a cold first call against a warm second call is meaningless.

---

## Subagent dispatch (Claude Code only)

On Claude Code with the project-scoped `delphi-driver` agent installed (`.claude/agents/delphi-driver.md`), delegate **scripted sequences of ≥ 5 sequential tool calls** to it. It runs on Haiku 4.5 at `effort: low` — no extended thinking, pure tool dispatch, ~2.5 s/call.

**When to delegate to `delphi-driver`:**

- You have a known, linear script of UI actions with no need to react to intermediate results.
- The script has at least 5 sequential tool calls (otherwise the ~14 s of subagent spin-up overhead doesn't pay back).

**When NOT to delegate:**

- The next step depends on the previous step's result (judgment is required — keep it in the parent session).
- The script has fewer than 5 sequential calls (just use parallel tool_use in the parent turn).
- You need to write code, propose alternatives, or analyze results (subagent is locked down to MCP tool calls only).

Invoke via the `Agent` tool with `subagent_type: delphi-driver`. The agent returns a compact `RESULT / STEPS / FINAL STATE / NOTES` report.

---

## Error envelope

All bridge errors use JSON-RPC error envelopes with custom codes:

| Code   | Name                    | Meaning                              | Common cause                                                                    |
| ------ | ----------------------- | ------------------------------------ | ------------------------------------------------------------------------------- |
| -32001 | `not_found`             | No component matches path            | Typo, control not yet created, form not visible                                 |
| -32002 | `ambiguous_path`        | Multiple matches without form prefix | Use a `Form.Leaf` or `Form.A.B.C` anchored path                                 |
| -32003 | `control_disabled`      | Found but `Enabled = False`          | The UI deliberately blocks this action                                          |
| -32004 | `main_thread_blocked`   | Dispatch timed out                   | Target main thread is busy (long handler, modal with custom message loop)       |
| -32005 | `unsupported_action`    | Class doesn't support the request    | e.g. clicking a `TPanel` with no `OnClick`, set_property on a non-writable kind |
| -32006 | `rtti_property_missing` | Property not exposed via RTTI        | Property isn't `published`, or doesn't exist                                    |
| -32098 | `target_not_responding` | I/O deadline expired after connect (MCP side) | Whole target frozen (IDE breakpoint, hang) — the call fails after per-call timeout + 2 s instead of hanging |
| -32099 | `target_not_running`    | Pipe not connected (MCP side)        | Discovery file absent; ask the user to launch the target                        |

`set_property` failures with code `rtti_property_missing` carry `error.data.availableProperties` — use it to self-correct.

---

## What this bridge deliberately does NOT do

- **No `SendInput` / synthetic mouse-keyboard.** This bridge acts directly on Delphi objects. Bugs that only reproduce through the real Windows input pipeline are not testable: focus-driven validation (`OnExit`, `EN_KILLFOCUS`), IME composition, keyboard accelerators routed via `WM_KEYDOWN` / `IsDialogMessage`, hover (`CM_MOUSEENTER`), real drag-drop initiated from a mouse-down + mouse-move. If your test relies on those, this is the wrong layer — use `SendInput`-based tools (AutoIt, TestComplete, Ranorex). `mode='message'` on `click` bridges the gap for buttons (uses `BM_CLICK`).
- **No workflow engine / test-recorder.** You write the scenarios in conversation or in your test harness. The bridge gives you the primitives.
- **No source modification of the target.** The integration cost is one `uses` clause and one `StartBridge` call.
- **No propagation of exceptions raised inside an event handler — the bridge is an exception firewall.** `click` dispatches inside `try..except` (`Source\Bridge\Autopilot.Bridge.Fmx.pas:1155-1166`, and the same shape in `.Vcl`): it catches anything the event handler raises, returns `stoppedReason: "exception:<ClassName>"`, and lets the session continue. That is deliberate (one crashing click must not kill the automation run), but it means the exception **never reaches `Application.HandleException`**, so anything hanging off the global handler does not fire: madExcept, `Application.OnException`, `LightFmx.Common.CrashHandler`, a custom `TApplicationEvents.OnException`.

  So **you cannot test a global error path by clicking a button that raises.** Measured 2026-08-07 in SciVance Tester against a binary verified armed with madExcept: the click returned `stoppedReason:"exception:Exception"`, no dialog appeared and no crash report was written — which looks exactly like "madExcept is broken" when in fact it was never invoked.

  **Trigger the crash off the click instead.** A short `TTimer` armed by the event handler works and is the smallest change: the tick runs from the normal message loop, outside the bridge's protected call, so the exception takes the same route it would from any real user action. A clean `clicksDispatched: 1` with **no** `stoppedReason` is the tell that the raise happened outside the dispatch. Same applies to `execute_action` and any other handler-invoking tool.

---

## Quick verification when something looks wrong

Three checks, in order:

1. **Is the target running with the bridge?** From PowerShell:
   
   ```powershell
   Get-ChildItem "$env:TEMP\Autopilot\active\"
   ```
   
   If empty: target is not running, or was built without the `AUTOPILOT` conditional define.

2. **Is the pipe alive?**
   
   ```powershell
   Get-ChildItem \\.\pipe\ | Where-Object Name -like "Autopilot.*"
   ```
   
   If empty but the discovery file exists: bridge crashed or `StopBridge` was called.

3. **Is the MCP server registered?** Tool names appear in your tool list as `mcp__autopilot__*`. If absent, the customer needs to re-register the MCP server with their host (`claude mcp add autopilot ...` on Claude Code). **Registering does NOT help the session you are in right now** — an MCP host reads its server list once at session start, so `mcp__autopilot__*` tools only appear in the *next* session. Confirm with `claude mcp list` that it shows `✓ Connected`, then either start a fresh session, or, if you need to act in the current one, drive the pipe directly (next subsection).

---

## Driving the bridge without the MCP tools (raw named pipe)

When the `mcp__autopilot__*` tools are not loaded (you just registered the server this session, you're on a host that hasn't picked it up, or you're scripting from a shell), you can talk to the bridge directly over its Windows named pipe. The protocol is small and stable.

**Wire format** (from `Autopilot.Bridge.Core.pas`): every frame is a **4-byte little-endian length** followed by that many bytes of **UTF-8 JSON**.

**Connection sequence:**

1. Find the pipe: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>` (enumerate `\\.\pipe\` for `Autopilot.*`, or read the discovery file in `%TEMP%\Autopilot\active\<PID>.pipe` whose contents ARE the pipe name).
2. Connect. The target sends a `{"hello":{"protocolVersion":1,...}}` frame **first**.
3. Reply with `{"helloAck":{"protocolVersion":1}}`. (Mismatched version → the worker drops the session.)
4. Send requests `{"id":N,"cmd":"...","args":{...}}`; read one response frame `{"id":N,"ok":true,"result":{...}}` per request. `args` keys are `path`, `count`, `text`, `checked`, `propName`, `value`, `form` (camelCase, matching the tool args above).

**Minimal PowerShell client** (handshake + one command):

```powershell
$full = [System.IO.Directory]::GetFiles("\\.\pipe\") |
        Where-Object { $_ -like "*Autopilot.<ExeBaseName>.*" } | Select-Object -First 1
$name = ($full -split '\\')[-1]   # strip the \\.\pipe\ prefix ( -split is an operator, not a Select-Object arg )
$c = New-Object System.IO.Pipes.NamedPipeClientStream(".", $name, "InOut"); $c.Connect(5000)
function RF($s){ $b=[byte[]]::new(4); $g=0; while($g-lt4){$n=$s.Read($b,$g,4-$g); if($n-le0){throw "EOF"}; $g+=$n}
  $len=[BitConverter]::ToUInt32($b,0); if($len-eq0){return ""}; $p=[byte[]]::new($len); $g=0
  while($g-lt$len){$n=$s.Read($p,$g,$len-$g); if($n-le0){throw "EOF"}; $g+=$n}; [Text.Encoding]::UTF8.GetString($p) }
function WF($s,$t){ $p=[Text.Encoding]::UTF8.GetBytes($t); $s.Write([BitConverter]::GetBytes([uint32]$p.Length),0,4)
  if($p.Length){$s.Write($p,0,$p.Length)}; $s.Flush() }
$null = RF $c                                        # read hello
WF $c '{"helloAck":{"protocolVersion":1}}'           # send ack
WF $c '{"id":1,"cmd":"list_tree"}'; RF $c            # one command + its response
```

This is a fallback, not the preferred path — the MCP tools handle framing, retries, and `availableProperties` recovery for you. Use the raw pipe only when the tools are genuinely unavailable in the current session.

---

## Shutting down the target — prefer the bridge, kill only when it's actually faster

**Bridge close path** — one `click` on File→Exit or the form's close button. The app runs `OnCloseQuery`/`OnClose`/`FormPreRelease`, writes its INI, deletes the discovery file, tears down the pipe. One tool call, one turn, ~1 ms.

- `click(path='frmMain.mniFileExit')` — whatever the host names its File→Exit item. Click the menu item or button, NOT the `TAction` behind it (`-32005`, see the `click` reference). If the only close path is an unbound action, kill instead.

**Kill path** — `Stop-Process` when the app is hung or its saved state is disposable. AI sessions waste turns wrapping this in a `Get-Process` pre-check, a screenshot, or window-rect math that fails on minimized/renamed targets. Just kill, one line — `-ErrorAction SilentlyContinue` makes the no-such-process case a no-op:

```powershell
Stop-Process -Name OrinocoReaderFMX -Force -ErrorAction SilentlyContinue
```

**Side effects of killing:** `FormPreRelease` doesn't run, so INI position/size (TLightForm) + AutoState GUI state are lost; the discovery file goes stale until the next MCP startup sweeps files >24 h old; the pipe breaks harmlessly. **Rule of thumb:** if the app can answer a `click`, use the bridge close path — same one turn, no lost state. Kill only when hung, when state is disposable, or when the close path doesn't work for this target.
