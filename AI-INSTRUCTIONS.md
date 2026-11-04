# Autopilot for Delphi - instructions for AI sessions

> **This file is a briefing** for an AI coding assistant (Claude Code, Claude Desktop, Cursor, Cline, or any MCP-aware host) that has the `autopilot` MCP server registered and wants to drive a running Delphi VCL or FMX application.
> Read it once at the start of a session.
>
> **How it is used:** one line in the user's global `CLAUDE.md` points at this file (`README.md`, section "How to install it").

---

## TL;DR - the eight rules

1. **Minimize turns, not tool calls.** The cost is the LLM turn, not the bridge (the numbers: "Efficiency rules" below).
   Ten tool calls in one turn is ~10× cheaper than one call per turn for ten turns.
2. **Use `count=N` on `click` for repetitive same-action work.** One tool call, one turn, regardless of N.
3. **Bundle independent tool calls into a single assistant turn (parallel tool_use).** To click A, set text on B and read C, emit all three tool_use blocks in one response.
4. **Don't pre-flight with `list_tree` if you already know the path.** Discovery once, then act.
5. **`set_property` returns `availableProperties` on a typo.** A single failed call gives you every writable property with its `kind` and live `currentValue`.
   Use it instead of guessing names again.
6. **`screenshot` is a fallback, not a verification.** For correctness checks, `get_text(...)` returns the exact string in a few ms with no image tokens: ~1000× cheaper.
   Reserve `screenshot` for layout/visual bugs you cannot read structurally, and then pass `path` (only that control) and `maxWidth` (for example 800) to cut the image tokens.
7. **`set_property` skips writes that wouldn't change the value (write-side elision).** The response carries `elided: true|false`: `true` means the value was already correct and `OnChange` did NOT fire.
8. **Hand off scripted sequences of ≥ 5 sequential tool calls to a dedicated subagent** - on Claude Code only: see "Subagent dispatch" below.

**Launching an app can leave the keyboard focus where it is.**
A LightSaber VCL app built with `AUTOPILOT` comes up visible but unfocused (`TLightForm` gates its startup windows with `WS_EX_NOACTIVATE`), so you can launch and drive it while the user keeps typing elsewhere.
This does NOT apply to FMX, nor to an app that calls `SetForegroundWindow` / `Application.BringToFront` during startup - including an app with a `TCoolTrayIcon` whose `FocusFormOnShow` is still TRUE (it grabs the foreground on every show of its owner form; set it to FALSE in `FormCreate`, under an AUTOPILOT conditional).

## Never drive the app with mouse or keyboard scripts

Do a job through the bridge: `execute_action`, `click`, `set_text`, `set_checked`, `set_property`, `send_keys`, `dismiss_dialog`.
Never move the mouse or send global keys (SendInput, AutoIt, screen-coordinate scripts) to do a job; such tools are only for testing the real Windows input pipeline (section "What this bridge deliberately does NOT do").
The bridge lives only in a build that defines `AUTOPILOT`, normally Debug: never drive a build without the bridge.
A modal dialog is no reason to change the app: `click(path, mode='message')` opens it without blocking, then the tools work on it, and `dismiss_dialog` closes a native one (section `dismiss_dialog`).
Add a named action (a small debug-only command component, described below) to the app only when both are true:
- the tools cannot do the job: a Windows file or folder picker (`dismiss_dialog` clicks its buttons but cannot type a file name), or a dialog where the recipe above failed;
- the job will be repeated, by a regression check or by later sessions on the same app.

For a one-time job, add no code to the app: tell the user in one line which action is missing.

A named action is a small `TComponent` owned by the main form, created under `{$IFDEF AUTOPILOT}` only, with two published string properties: writing `Command` (an action name, a space, a parameter) runs the action, and `Answer` holds the result text.
Each action calls the same routine the GUI calls after its dialog closes, never a copy of it, with `TAppDataCore.Unattended` (LightSaber) or the app's own switch set so no message box blocks the call.
The getter of `Command` returns `''`, so a repeated command is never skipped by write-side elision (TL;DR rule 7).
Call it with `set_property(path='frmMain.Autopilot', propName='Command', value='load_file C:\Data\a.txt')`, then `read_property(path='frmMain.Autopilot', propName='Answer')`.

---

## The fourteen MCP tools - full reference

The MCP server is registered as `autopilot`, so tool names appear in your tool list as `mcp__autopilot__<name>`.
Every tool accepts an optional `pid`, needed only when more than one Delphi target runs; with one target the tools attach to it on their own.

**Crash report of the MCP server.** When `Autopilot.Mcp.exe` crashes, it saves a crash report to `%TEMP%\Autopilot\bugreport Autopilot.Mcp.txt` and never sends it; the first lines of the server's log `%TEMP%\Autopilot\Autopilot.Mcp-<pid>.log` say so (a server built without madExcept has no crash reporter, and its log says that instead).
A user who wants the report sent to SciVance Tech, the maker of Autopilot, registers the server with the parameter `--crash-report` (in either order with `--target adb:<port>`): `claude mcp add autopilot -- <path>\Autopilot.Mcp.exe --crash-report`.
The older parameter `--no-crash-report` is still accepted: it keeps the report on the PC, even beside `--crash-report`.
None of these changes the tools or their answers.

### `attach`

`attach(pid?)`

Lists the running targets, or checks that the target with `pid` is reachable.
**You almost never need to call it:** every other tool finds the target on its own.
Call `attach` only:

- After `-32099 target_not_running`, to retry once the user has restarted the target.
- When several targets run and you must choose by PID.
- When the user asks you to wire Autopilot into a project: its `setup` field holds the steps.

Return shape: `{targets:[{pid, pipe}], count, setup}`; `setup` is always there.
Its step 1 names the full path of the bridge source folder when the server finds it near its own EXE (`Source\Bridge`, for an EXE in `Source\McpServer\` or in its build folder `Source\McpServer\Win32_<config>\`); use that path as given.
When `count` is 0 the answer also carries `hint`: the next step (start the app, or link the bridge in).

### `list_tree`

`list_tree(pid?)`

Enumerates all forms and their controls, as an array at `result.components`.
Each node carries:

- `form` - owning form name (e.g. `"frmMain"`).
- `name` - component name, or a synthetic `@TButton#N` for an unnamed component (flagged `synthetic: true`).
- `path` - the dotted path every other tool takes.
- `class` - Delphi class name.
- Optional `text` - `Caption`/`Text`/`Lines.Text` where readable.
  Missing on classes that have no text property, where `Text`/`Caption` is not a string (some third-party components), OR where the getter raised.
- Optional `hint` - the tooltip text the programmer wrote for the control, menu item or action: often the only description of what a control does, so read it before guessing from the name.
  Only when it is not empty and differs from `text`.
  Raw value: a VCL hint may hold `short|long`.
  A control bound to an action carries the action's hint.
- Optional `enabled`, `visible` - boolean state where readable.
  Missing where the property is not a Boolean (for example an enumeration `Visible` on some third-party components).
- Optional `parent` - only on a re-parented control or embedded form: one that is shown inside a container outside the owner tree it is listed under.
  The value is the `list_tree` path of that container, e.g. `"parent":"MainForm.tabFixEnters"`; left out when the container has no `list_tree` path.

The first node is the form itself (its path is its name).
Then come the components the form **owns** (`Components[]`), at any depth: a component that owns others (a frame, a panel created at run time with an owner) is followed by the components it owns, and `path` is that owner chain.
So a control is listed under the form that owns it, not under the form where it is shown.
Example: a panel created by `frmEnterFix` and re-parented onto a tab sheet of `MainForm` is listed as `frmEnterFix.Container`, with `"parent":"MainForm.tabFixEnters"`.
A control owned by `Application` or by nobody is not listed.

**Path forms accepted by every tool that takes `path`.** A path is resolved in two steps.

Step 1, the owner path (the `path` that `list_tree` shows):

- `Form` - the form itself (e.g. `frmMain`).
- `Form.Leaf` - shallow-first search for `Leaf` among everything `Form` owns, at any depth (e.g. `frmMain.btnSave`).
  If `Leaf` exists in several branches, the shallowest wins with no error; use an anchored path to reach another one.
- `Form.A.B.C` - anchored: each segment is owned by the previous one (e.g. `frmMain.Frame1.btnSave` for a button inside a frame).

Step 2, only when step 1 finds nothing: the same path is tried through the visual tree, where the controls are shown (VCL `Controls[]`, FMX `Children`; FMX also looks through `TTabItemContent` and `TScrollContent`, never into style objects):

- `Form.Leaf` - any control shown anywhere inside `Form`, whoever owns it: `MainForm.Container` finds the re-parented panel above.
- `Form.A.B.C` - each segment is owned by the previous one OR placed directly on it: `MainForm.tabFixEnters.Container`, or `frmMain.pnlToolbar.btnSave` for a button placed on a panel (both owned by the form).
- One match resolves the path.
  Two or more give `-32002 ambiguous_path`; the message names each candidate by its owner path - retry with one of those.
  Non-visual components (`TAction`, `TDataSet`, `TTimer`) are found only by their owner path.

### `click`

`click(path, count?, mode?, timeoutMs?, pid?)`

Default behavior: invokes the control's `Click` (buttons and other windowed controls).
**A control with an `Action` assigned** is clicked through `TControl.Click`, which runs the action as a mouse click does: `OnExecute` gets the action as `Sender`, `AutoCheck` toggles `Checked`, `TActionList.OnExecute` runs, and a standard action without `OnExecute` (`TFileExit`) works too.
This covers VCL `TSpeedButton`/`TToolButton` and, on FMX, every action-bound control.
Other controls fall back to `OnClick(Self)`: VCL non-windowed visuals like TLabel/TImage, and every FMX control without an action.

- `count` (1..1000, default 1) - fires N clicks in one round-trip.
  `Enabled` is re-checked between clicks: the loop stops early with `stoppedReason='disabled'` if the control becomes disabled, and with `stoppedReason='freed'` if a click frees the control (or its form).
- `timeoutMs` - the bridge's main-thread wait for this call, in milliseconds: default 5000, plus 100 per extra click (5000 + (count-1)*100).
  A short value is the fallback recipe for a click that opens a modal dialog (see `dismiss_dialog`).
- `mode` - omit it, or pass `'auto'`, for the normal click described above.
- `mode='message'` (VCL-on-Windows only) - posts `BM_CLICK` to the control and returns at once; the click runs when the app next pumps messages, AFTER this response.
  On a minimized form, where a posted `BM_CLICK` is lost, the click is queued to the main thread instead; it still runs after the response.
  Only button-class controls handle `BM_CLICK` (`TButton`/`TBitBtn`/`TCheckBox`/`TRadioButton`): any other class is rejected with `-32005`, and FMX targets reject the mode with `-32005` too.
  **The main use: a button whose `OnClick` opens a modal dialog** (see `dismiss_dialog`).

Return shape: `{dispatchedVia: 'click' | 'onclick' | 'message', clicksDispatched: N, stoppedReason?: 'disabled' | 'freed' | 'exception:<ClassName>'}`.
`'click'` = the control's `Click` method ran, `'onclick'` = the `OnClick` handler was invoked directly, `'message'` = a `BM_CLICK` was posted (async).
`'exception:<ClassName>'` = the event handler raised (see "What this bridge deliberately does NOT do").
With `mode='message'` + `count`, all posted clicks run after the response returns, so the between-iterations `Enabled` re-check cannot see those clicks' own effects.

**Click the control, not the `TAction` - or use `execute_action`.** A `TAction` / `TBasicAction` has no `OnClick`, so `click(path='Form.actFileExit')` fails with `-32005 unsupported_action` ("has no OnClick").
Two ways out:
- **`execute_action(path='Form.actFileExit')`** - fires the action directly.
- **`click(path='Form.btnExit')`** - clicks the control bound to the action, through the normal action dispatch: this also tests the *control's* binding.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action`, `-32600 invalid_request` (a `count` outside 1..1000, or an unknown `mode`).
A non-integer `count` like `1.5` never reaches the app (section "Error envelope").

### `execute_action`

`execute_action(path, pid?)`

Fires `TBasicAction.Execute` directly - runs the action's `OnExecute` handler.
Use this when the command is bound to a `TAction` whose handler carries the logic:

- **Shortcut-only actions** that no control clicks (e.g. `actFileExit` triggered only by Alt+F4 / a hotkey).
  `click` cannot reach these; `send_keys` can press their shortcut.
- **Actions shared by several controls** (toolbar button + menu item + shortcut): one `execute_action` is more direct than clicking one of the bound controls.

`path` must resolve to a `TBasicAction` descendant (`class:"TAction"` in `list_tree`).
A disabled action refuses with `-32003 control_disabled`.

Return shape: `{path, dispatchedVia: 'Execute', executed: true | false}`.
`executed: false` means nothing handled the action: no `OnExecute` handler (and, for a `TAction`, no `TActionList` or application handler either) - a real, reportable state, not an error.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action` (path resolved but isn't a `TBasicAction` - use `click`), `-32603 internal_error` (the `OnExecute` handler raised).

### `get_text`

`get_text(path, pid?)`

Reads `Caption` / `Text` / `Lines.Text` via RTTI and returns the exact string, embedded `#10` newlines included.
Use this (NOT `screenshot`) to verify that a click produced the expected state (TL;DR rule 6).

### `set_text`

`set_text(path, text, pid?)`

Writes `Text` (or `Caption` for label-class controls) via RTTI.
`OnChange` fires synchronously, through the property setter.
There is no `mode='message'` opt-in.

**Data-aware VCL controls** (anything with a published `DataField <> ''` and a `DataSource` whose `DataSet` is assigned; verified with `TDBEdit` and `TDBMemo`) get the same chain a typing user triggers: `DataSource.Edit` BEFORE the write (the dataset enters `dsEdit`) and `CM_EXIT` AFTER it (`DataLink.UpdateRecord`, then the regular `OnExit`).
The response carries `dataBound: true` when the chain ran.
The value then sits in the field buffer: whatever the form does next (`Post`, a Save button, …) persists it, exactly as for a user.
FMX has no such chain.

The rules a user hits apply too; each answers `-32005 unsupported_action` with the reason in the message: control `ReadOnly = TRUE`, field not modifiable (read-only, calculated, lookup), dataset `CanModify = FALSE` (read-only cursor), `DataSource.AutoEdit = FALSE` while the dataset is not already in `dsEdit`/`dsInsert`, `OnBeforeEdit` aborting, or a data-aware control without a writable `Text` (`TDBLookupComboBox`, `TDBRadioGroup` - use `click`/`set_property` there).
A dataset the app already put into edit mode is left alone.
`TDBComboBox` is untested: `WM_SETTEXT` does not reach its `Change`, so expect the field to stay unchanged there.

### `set_checked`

`set_checked(path, checked, pid?)`

`checked: true | false`.
Flips `Checked` (VCL) / `IsChecked` (FMX) and fires `OnChange` / `OnClick`.

A data-aware VCL `TDBCheckBox` writes to its field only when it is clicked.
So when the state has to change, the bridge sends `BM_CLICK` (synchronous `Perform`: `DataLink.Edit` + `Modified`) instead of writing `Checked`, then `CM_EXIT` (`DataLink.UpdateRecord`).
The state is re-read afterwards: a second `BM_CLICK` covers the `AllowGrayed` step (NULL field = grayed), and if `Checked` still differs (the link refused `Edit`: read-only field/control, `DataSource.AutoEdit = FALSE`) the call fails with `-32005` instead of reporting success.
The response carries `dataBound: true`.
`BM_CLICK` moves the focus to the checkbox like a real click would, so the previously focused control gets its `OnExit`.

### `set_property`

`set_property(path, propName, value, pid?)`

Writes any published, writable property on any control via RTTI.
Use this when `set_text` and `set_checked` don't fit.
Examples:

- `set_property(path='frmMain.pnlMain', propName='Tag', value='42')`
- `set_property(path='frmMain.lblStatus', propName='Color', value='clRed')` - VCL TColor: `clName`, `#RRGGBB`, `$00BBGGRR`, or decimal.
- `set_property(path='frmMain.rectBox', propName='Fill.Color', value='#FF8000')` - FMX TAlphaColor: `#RRGGBB` (alpha=FF), `#AARRGGBB`, `claName`, or decimal.
- `set_property(path='frmMain.cmbItems', propName='ItemIndex', value='2')`
- `set_property(path='frmMain.pnlToolbar', propName='BevelEdges', value='[beLeft,beTop]')` - set-of-enum: `[a,b]`, `a,b`, `[]`, or ordinal.
- `set_property(path='frmMain.btnSave', propName='Font.Size', value='14')` - one-level dotted path into a class-typed property.
- `set_property(path='frmMain.lstLog', propName='Lines.Text', value='line one'#10'line two')`

**Supported property kinds:** string (and L/W/U variants), integer, int64, boolean, other enumerations (by identifier `'poDesigned'` or ordinal `'1'`), set-of-enum (see above), float (Single / Double / TDateTime), TAlphaColor (FMX), TColor (VCL).

**Disabled controls:** on a disabled control `set_property` answers `-32003 control_disabled`, with one exception: the property `Enabled` itself (that exact name in any letter case, no dotted path) may be set to `true` or `false`, so a control you disabled with `set_property` can be enabled again.
`false` on a control that is already disabled answers `elided: true`.

**Discovery on unknown property name** (TL;DR rule 5): the failure response carries `error.data.availableProperties` - a JSON array of `{name, kind, currentValue?}` entries covering every writable published property.
`kind:'class'` entries (Font, Lines, Brush, Fill, …) are candidates for one-level dotted writes.

**Write-side elision** (TL;DR rule 7): before each write, the bridge reads the live value and skips `SetValue` if the coerced new value equals it.
`elided: false` means a real write happened, and `OnChange` did fire (if the control has one).
Comparison is type-aware: string identity, integer/int64 equality (TAlphaColor/TColor as 32-bit), boolean equality, enum/set ordinal equality (so `[fcRed,fcBlue]` elides against `[fcBlue,fcRed]`), float exact-bits (no epsilon).

**Parent-inheritance auto-flip (VCL only):** when a write to `Font.*`, `Color`, `BiDiMode`, `ShowHint`, `DoubleBuffered`, `CustomHint`, or `Ctl3D` SUCCEEDS (including an elided resend), the bridge silently (no response field) sets the matching `Parent<X>:=FALSE`.
A REJECTED value (bad coercion, read-only inner) leaves `Parent<X>` untouched.
To restore inheritance, write `ParentFont:=true` (or the matching `Parent<X>`) afterward.

### `read_property`

`read_property(path, propName, pid?)`

Returns any readable published property by RTTI.
The returned `value` string is exactly what `set_property` would accept back.
Examples:

- `read_property(path='frmMain.btnSave', propName='Tag')` → `{value: '42', kind: 'integer'}`
- `read_property(path='frmMain.lblStatus', propName='Color')` → `{value: 'clRed', kind: 'color'}` (VCL `TColor`)
- `read_property(path='frmMain.rectBox', propName='Fill.Color')` → `{value: 'claRed', kind: 'alphacolor'}` (a named `TAlphaColor`, VCL and FMX); a color with no name reads as `'#AARRGGBB'`, e.g. `{value: '#FFFF8000', kind: 'alphacolor'}`
- `read_property(path='frmMain.cmbItems', propName='ItemIndex')` → `{value: '2', kind: 'integer'}`
- `read_property(path='frmMain.btnSave', propName='Font.Size')` → `{value: '14', kind: 'integer'}` (one-level dotted)
- `read_property(path='frmMain.pnlToolbar', propName='BevelEdges')` → `{value: '[beLeft,beTop]', kind: 'set'}`

**Does NOT enforce Enabled:** reading a disabled control is a legitimate debug case ("why is btnSave greyed out? what's its Tag? its Action.Enabled?").
`click`, `set_text`, `set_checked` and `set_property` refuse a disabled control with `-32003` (except `set_property` of `Enabled` itself).

**Discovery on unknown propName:** the `rtti_property_missing` response carries `error.data.availableProperties` - same shape as for `set_property`, but read-only properties are listed too.

**Class-typed leaves** (`Font`, `Brush`, `Lines`, `Fill`) cannot be read directly: the tool returns `unsupported_action` with a hint to use a dotted propName (`Font.Size`, `Lines.Text`, `Fill.Color`).

**vs. `get_text`:** use `get_text` to read back `Text` / `Caption` / `Lines.Text` (it picks the right property name for each control class), and `read_property` for everything else (it needs the exact property name).

### `wait_for`

`wait_for(path, expectedText, timeoutMs?, pollIntervalMs?, pid?)`

Polls the control's `Text`/`Caption` every `pollIntervalMs` (default 100) until it equals `expectedText` exactly, or `timeoutMs` (default 10000) expires.
Use after kicking off asynchronous work (a `TTask`, a database query, a Win32 timer).
Text/Caption only - other properties (`Checked`, `Enabled`) are not pollable yet; read them with `read_property`.

Returns `{matched, currentValue, expectedValue, pollCount}`.
`matched: false` means only that the deadline passed while the target kept answering; it carries the last observed value (a reportable state, not an error), so branch on the field.
`-32098 target_not_responding` and `-32099 target_not_running` end the wait at once, with `isError: true`.
Any other poll error (for example `-32001` for a control that does not exist yet) does not end the wait.

### `screenshot`

`screenshot(form?, path?, maxWidth?, pid?)`

Captures the named form (or the main form if `form` omitted) as a PNG.
The result holds two content blocks: first an MCP image block (`type: image`, `mimeType: image/png`) that you see as a picture, then a text block with the rest of the answer: `form`, `width`, `height`, `scaled`, `format`, `encoding` (no image data), plus `path` when you passed one.
A failed screenshot answers one text block with the error envelope.

- **`path`** - a control path, resolved like every other tool's path (`-32001` / `-32002` as usual).
  The image shows only that control's rectangle as it appears on its form, children included, clipped to the visible part of the form.
  `form` is ignored (the path names its form; the answer's `form` is the form that shows the control).
  A control that cannot be captured (not visible itself or through a parent, zero size, not a visual control such as a timer or an action, or entirely outside the client area) answers `-32005`.
  The control is painted, not copied from the screen, so another window in front of it does not spoil the image.
- **`maxWidth`** - pixels; omitted or `0` = full size.
  When the image is wider, it is scaled down to exactly `maxWidth` wide, aspect ratio kept, with a smoothing filter so small text stays readable; a narrower image is never scaled up.
  A negative or fractional value answers `-32600`.
- **`width` / `height`** are the size of the image you receive; **`scaled`** is `true` when `maxWidth` shrank it.
- **A minimized VCL form** is captured at its restored size with all its controls, the labels and speed buttons (controls without a window of their own) included.
  The form stays minimized: the screenshot does not restore or activate it.
- **A VCL `THotKey`** shows as an empty box: without a VCL style its text does not appear in the image. Read it with `get_text`.

**Use sparingly** (TL;DR rule 6): PNGs cost image tokens in the LLM context, and the encode round-trip is the most expensive single bridge call (~30 ms for a typical form vs sub-ms for everything else).
Justified for layout bugs, color/theme issues, font rendering glitches, and as a tiebreaker when you cannot tell the form's state otherwise.

### `set_keep_awake`

`set_keep_awake(enabled, pid?)`

Android only - keeps the device screen on (window flag `FLAG_KEEP_SCREEN_ON`), because Android freezes a backgrounded or screen-off app (no CPU), which stalls the bridge.
The FMX bridge turns it ON at startup, so you rarely call it: `enabled=false` releases it, `enabled=true` re-asserts it.
It does NOT cover the cold-start window before the bridge starts - keep the device screen on through app launch.
On a Windows target (VCL or FMX) it is a no-op (`applied:false`, `platform:windows`).

Response: `{enabled, platform:'android'|'windows', applied}`.
`applied:true` means the window flag was changed; `applied:false` means the platform ignores it.

### `dismiss_dialog`

`dismiss_dialog(button?, hwnd?, pid?)`

Lists and dismisses native OS dialogs that the component tools cannot see.
`Application.MessageBox`, a default `ShowMessage`/`MessageDlg` (a Vista Task Dialog), and the common file dialogs are raw Win32 windows with no `TComponent`, so `list_tree`/`click` return `-32001 not_found` against them; this tool reaches them through Win32.

- Call with **no `button`** to LIST the dialogs currently up.
  Response: `{dialogs:[{hwnd, class, caption, text, buttons:[{id, caption, enabled}]}], supported, platform}`.
- Call with **`button`** to dismiss one.
  `button` is a role (`ok`/`cancel`/`yes`/`no`/`retry`/`abort`/`ignore`/`close`/`help`/`tryagain`/`continue`), a button caption (exact then substring, case-insensitive), or a numeric control id.
  `hwnd` targets a specific dialog when several are stacked; omit it for the topmost.
  Response adds `{clicked, clickedId, clickedCaption, dialogHwnd, via, reason?}`.
  `reason` is `no_dialog`, `button_not_found`, or `send_failed` (button found, but the OS reported the click was not delivered) when `clicked:false`.
- **Check `via` before you trust `clicked:true`.** `via:'BM_CLICK'` means the button's own window was found and got the click.
  Documented `BM_CLICK` behavior: a button inside a dialog box may ignore it when that dialog is not the active window, and the bridge never activates the dialog - when the result matters, re-list as below.
  `via:'WM_COMMAND'` means the button is not a separate window (a Task Dialog common button, or a role/id that dialog does not actually have), so the command was dispatched **by id, blind**: a dialog with no such command silently ignores it and the send still reports success.
  After a `WM_COMMAND` dismiss, call `dismiss_dialog` again with no `button` - an empty `dialogs` array is the only proof the dialog is gone.

**A modal dialog blocks the main thread.** When you `click` a control whose `OnClick` opens a modal dialog, that click never returns - the main thread enters the dialog's modal loop.
Two recipes:

- **Preferred (VCL button-class controls):** `click(path, mode='message')` - returns before the dialog opens, then `dismiss_dialog(button=...)`: no error, no timeout burned.
- **Fallback (FMX targets, or non-button controls):** pass a short `timeoutMs` (e.g. 500) to the `click`, expect `-32004 main_thread_blocked`, then call `dismiss_dialog(button=...)`.

A `send_keys` key whose handler opens a modal dialog blocks the same way: expect `-32004 main_thread_blocked` after 5000 ms, then call `dismiss_dialog`.
Either way the dialog's own modal loop still pumps the bridge, so the dismiss lands and the app unblocks.

Windows targets only: against an Android FMX target the response is `supported:false`.

### `send_keys`

`send_keys(path?, keys?, text?, pid?)`

Presses keys and shortcuts, or types text, inside the app.
The same handlers run as for a real key press: `OnKeyDown` / `OnKeyPress` / `OnKeyUp`, the form's `KeyPreview`, action and menu `ShortCut`s, the form's Default button on Enter and Cancel button on Escape, and an edit control inserting the typed characters.

- **`keys`** - chords separated by spaces.
  A chord is optional modifiers joined by `+`, then one key: `Ctrl+S`, `Enter`, `Ctrl+Shift+Z`, `Ctrl+A Delete`.
  Modifiers: `Ctrl`, `Shift`, `Alt`.
  Keys: `A`..`Z`, `0`..`9`, `F1`..`F12`, `Enter`, `Escape` (or `Esc`), `Tab`, `Space`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `PageUp`, `PageDown`, `Up`, `Down`, `Left`, `Right`, case-insensitive.
  An unknown name answers `-32600` naming the bad token, and then nothing at all is sent.
- **`text`** - typed one character at a time, so every character fires the events a user's typing fires.
  With both, `text` is typed first, then `keys` ("type abc, then Enter" is one call).
  At least one of the two is required, else `-32600`.
- **`path`** - the control that receives the keys; it gets the focus inside the app first.
  Disabled: `-32003`.
  A control that cannot take the focus (a `TLabel`): `-32005`.
  Omitted: the focused control of the active form (or the form itself).
- Response: `{keysSent, target, via}` - `keysSent` counts chords plus typed characters, `target` is the path that received them, `via` is `keymessages` (VCL) or `formkeydown` (FMX).

**`set_text` or `send_keys`?** `set_text` assigns the whole value at once (one `OnChange`, no key events): use it to fill in a value.
Use `send_keys` to test keyboard behaviour: a search box that filters on every key, Enter that confirms, Escape that cancels, a shortcut.

**Nothing leaves the app.** The keys never go through global input (`SendInput`): they cannot land in another program, the app does not have to be in front, and no window is activated.
The answer returns after the handlers ran, so check the effect with `get_text` at once.
A key whose handler opens a **modal dialog** blocks the app: see `dismiss_dialog`.

---

## Debug-channel selection - read live state without a recompile

To inspect the host app's state while debugging, use the cheapest channel that works, in this order:

1. **`get_text` / `read_property`** - for any value that lives on a published property of a discoverable component.
   Both are one round-trip with no host changes, and cover ~70% of debug cases.
2. **`read_property` with a deliberate bogus propName** - when you don't know the property name yet: its `availableProperties` returns every readable property, read-only ones included, in one round-trip (`set_property` gives the same list for the writable ones only, TL;DR rule 5).
3. **Host-side `BridgeLogInfo` / `RamLog.AddInfo`** - when the value is NOT a published property (a local variable, a function result like `IsDarkStyle`, an intermediate value, state inside a method).
   Add a logging call in the host source, recompile, run, then read the log: `BridgeLogInfo(Tag, Msg)` (unit `Autopilot.Bridge.Log`) appends to the bridge's own log `%TEMP%\Autopilot\<ExeBaseName>-<PID>.log`; in LightSaber projects `AppData.RamLog.AddInfo` goes to `AppData.RamLog`'s file.
   **When a recompile IS unavoidable**, batch every value you want into ONE logging block - one cycle, one read.
4. **Host-side `Diag.SaveToFile` scratchpad** - last resort, only when (1)-(3) all fail to fit.
   Each scratchpad file you write requires a recompile cycle AND leaves a stray file in the host's data folder; prefer logging.

---

## Efficiency rules - read once, follow always

The bridge round-trip is sub-millisecond; the cost is **per-turn LLM inference**:

```
total_time ≈ (turns × per_turn_inference) + (tool_calls × ~1ms bridge_time)
```

Per-turn inference is ~1-8 s on Opus 4.7, ~0.3-1 s on Haiku 4.5.
Measured warm-cache Opus 4.7: a turn costs ~20-26 s whether it carries one tool call or many, and `click(count=1000)` spent 62 ms of total bridge time.
The one case where extra turns are unavoidable is a react-to-result loop ("click Save; if status shows 'error', read the error label"): the LLM must see each intermediate result, so use the most capable model and don't micro-optimize.

---

## Subagent dispatch (Claude Code only)

On Claude Code with the project-scoped `autopilot-script-runner` agent installed (`.claude/agents/autopilot-script-runner.md`), delegate **scripted sequences of ≥ 5 sequential tool calls** to it.
It runs on Haiku 4.5 at `effort: low` - no extended thinking, pure tool dispatch, ~2.5 s/call.

**Delegate** only a known, linear script of UI actions: with fewer than 5 calls the ~14 s of subagent spin-up overhead doesn't pay back (use parallel tool_use in the parent turn instead).
**Keep the work in the parent session** when the next step depends on the previous step's result, or when you need to write code, propose alternatives or analyze results: the subagent can only call the MCP tools.

Invoke via the `Agent` tool with `subagent_type: autopilot-script-runner`.
The agent returns a compact `RESULT / STEPS / FINAL STATE / NOTES` report.

---

## Error envelope

All bridge errors use JSON-RPC error envelopes with custom codes:

| Code | Name | Meaning | Common cause |
| --- | --- | --- | --- |
| -32001 | `not_found` | No component matches path | Typo, control not yet created, form not visible |
| -32002 | `ambiguous_path` | The path matched 2+ controls through the visual tree | The owner path found nothing and several shown controls fit. The message lists each by its owner path - retry with one of them |
| -32003 | `control_disabled` | Found but `Enabled = False` | The UI deliberately blocks this action. `set_property` of `Enabled` itself is still allowed |
| -32004 | `main_thread_blocked` | Dispatch timed out | Target main thread is busy (long handler, modal with custom message loop) |
| -32005 | `unsupported_action` | Class doesn't support the request | e.g. clicking a `TLabel` with no `OnClick`, set_property on a non-writable kind |
| -32006 | `rtti_property_missing` | Property not exposed via RTTI | Property isn't `published`, or doesn't exist. The error carries `availableProperties` (TL;DR rule 5) |
| -32098 | `target_not_responding` | The target stopped answering (MCP side) | It accepted the connection but did not reply in time (the call fails after the per-call timeout + 2 s instead of hanging), or its pipe stayed busy for the whole per-call timeout. Typical: the whole app is stopped on an IDE breakpoint or hung |
| -32099 | `target_not_running` | No target to connect to (MCP side) | App not running, unknown `pid`, or (Android) no `adb forward`. The message carries the steps to start the app or link the bridge in - follow them instead of retrying |

Two more answers come from the MCP server itself, before anything reaches the app:
- A `tools/call` with an unknown tool name, a missing `name`, or `arguments` that are not an object answers the JSON-RPC error `-32602`.
- An argument of the wrong type, or a required argument that is missing (`"abc"` for `pid`, `1.5` for `count`, `1` for `checked`), answers an `isError: true` result whose text names the argument.

---

## What this bridge deliberately does NOT do

- **No `SendInput`: no global mouse or keyboard input.** This bridge acts directly on Delphi objects, inside the app: `send_keys` delivers key presses, shortcuts and the Default/Cancel buttons as window messages, and `mode='message'` on `click` posts a real `BM_CLICK` to a button.
  Bugs that only reproduce through the real Windows input pipeline are not testable: focus-driven validation (`OnExit`, `EN_KILLFOCUS`; the exception is the `CM_EXIT` that `set_text` sends to a data-aware control and `set_checked` to a `TDBCheckBox`), IME composition, keys routed through `IsDialogMessage` (a native dialog box), hover (`CM_MOUSEENTER`), real drag-drop initiated from a mouse-down + mouse-move.
  If your test relies on those, this is the wrong layer - use `SendInput`-based tools (AutoIt, TestComplete, Ranorex).
- **No workflow engine / test-recorder.** You write the scenarios; the bridge gives you the primitives.
- **No source modification of the target.** The integration cost is one `uses` clause and one `StartBridge` call.
- **No propagation of exceptions raised inside an event handler - the bridge is an exception firewall.** `click` dispatches inside `try..except`: it catches anything the event handler raises, returns `stoppedReason: "exception:<ClassName>"`, and lets the session continue.
  That is deliberate (one crashing click must not kill the automation run), but it means the exception **never reaches `Application.HandleException`**, so anything hanging off the global handler does not fire: madExcept, `Application.OnException`, `LightFmx.Common.CrashHandler`, a custom `TApplicationEvents.OnException`.
  `execute_action` (`OnExecute`), `set_property` (the setter) and `set_checked` (`OnClick`) catch the exception the same way and answer `-32603`.
  Measured on VCL, `set_text` (`OnChange`) and `send_keys` (`OnKeyDown`) are NOT behind the firewall: the exception reaches `Application.OnException` (or madExcept), and the tool answers ok.

  So **you cannot test a global error path by clicking a button that raises.** Measured against a binary verified armed with madExcept: the click returned `stoppedReason:"exception:Exception"`, no dialog appeared and no crash report was written - which looks exactly like "madExcept is broken" when in fact it was never invoked.

  **Trigger the crash off the click instead.** A short `TTimer` armed by the event handler is the smallest change: the tick runs from the normal message loop, outside the bridge's protected call, so the exception takes the route of a real user action.
  A clean `clicksDispatched: 1` with **no** `stoppedReason` is the tell that the raise happened outside the dispatch.

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

3. **Is the MCP server registered?** Tool names appear in your tool list as `mcp__autopilot__*`.
   If absent, the user needs to re-register the MCP server with their host (`claude mcp add autopilot ...` on Claude Code; keep `--crash-report` or `--no-crash-report` at the end if the old registration had it).
   **Registering does NOT help the session you are in right now:** an MCP host reads its server list at session start, so the tools appear only in the *next* session.
   Confirm with `claude mcp list` that it shows `✓ Connected`, then either start a fresh session, or, if you need to act in the current one, drive the pipe directly (next section).

---

## Driving the bridge without the MCP tools (raw named pipe)

When the `mcp__autopilot__*` tools are not loaded (you just registered the server this session, you're on a host that hasn't picked it up, or you're scripting from a shell), you can talk to the bridge directly over its Windows named pipe.

**For repeatable tests written in Delphi, do not write a pipe client:** use `TAutopilotApp` (`Source\Client\Autopilot.Client - how to write GUI tests without AI.md`).

**Wire format** (from `Autopilot.Bridge.Core.pas`): every frame is a **4-byte little-endian length** followed by that many bytes of **UTF-8 JSON**.

**Connection sequence:**

1. Find the pipe: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>` (enumerate `\\.\pipe\` for `Autopilot.*`, or read the discovery file in `%TEMP%\Autopilot\active\<PID>.pipe` whose contents ARE the pipe name).
2. Connect: the target sends a `{"hello":{"protocolVersion":1,...}}` frame **first**.
3. Reply with `{"helloAck":{"protocolVersion":1}}` (a mismatched version → the worker drops the session).
4. Send requests `{"id":N,"cmd":"...","args":{...}}`; read one response frame `{"id":N,"ok":true,"result":{...}}` per request.
   `args` holds the tool's arguments under the same camelCase names (`path`, `count`, `text`, `checked`, `propName`, `value`, `form`, ...), without `pid`; `timeoutMs` goes beside `cmd`, not into `args`.
   `attach` and `wait_for` exist only in the MCP server, not in the bridge: poll `get_text` yourself.

**Minimal PowerShell client** (handshake + one command):

```powershell
$full = [System.IO.Directory]::GetFiles("\\.\pipe\") |
        Where-Object { $_ -like "*Autopilot.<ExeBaseName>.*" } | Select-Object -First 1
$name = ($full -split '\\')[-1]   # strip the \\.\pipe\ prefix
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

---

## Repeatable tests without AI: DUnitX with Autopilot.Client

For GUI tests that run again and again with no AI (a regression suite, a build step), write a DUnitX test project that drives the app through the class `TAutopilotApp` in `Source\Client\Autopilot.Client.pas`: no MCP server, about 0.8 ms per command, Windows targets only.
Before you write such a test project, read `Source\Client\Autopilot.Client - how to write GUI tests without AI.md`: project setup, every method, the exceptions, the rules and an example.

---

## Shutting down the target - prefer the bridge, kill only when it's actually faster

**Bridge close path** - one `click` on File→Exit or the form's close button.
The app runs `OnCloseQuery`/`OnClose`/`FormPreRelease`, writes its INI, deletes the discovery file, tears down the pipe.
One tool call, one turn, ~1 ms.

- `click(path='frmMain.mniFileExit')` - whatever the host names its File→Exit item.
  Click the menu item or button, NOT the `TAction` behind it (`-32005`); an exit action that no control is bound to fires with `execute_action`.

**Kill path** - `Stop-Process` when the app is hung, its saved state is disposable, or the bridge close path doesn't work for this target.
Just kill, in one line - no `Get-Process` pre-check, no screenshot, no window-rect math (it fails on minimized/renamed targets); `-ErrorAction SilentlyContinue` makes the no-such-process case a no-op:

```powershell
Stop-Process -Name <ExeBaseName> -Force -ErrorAction SilentlyContinue
```

**Side effects of killing:** `FormPreRelease` doesn't run, so INI position/size (TLightForm) + AutoState GUI state are lost; the discovery file stays until the next tool call that lists targets finds its process gone and deletes it; the pipe breaks harmlessly.
**Rule of thumb:** if the app can answer a `click`, use the bridge close path - same one turn, no lost state.
