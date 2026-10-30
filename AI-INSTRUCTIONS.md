# Autopilot for Delphi - instructions for AI sessions

> **This file is a briefing** for an AI coding assistant (Claude Code, Claude Desktop, Cursor, Cline, or any MCP-aware host) that has the `autopilot` MCP server registered and wants to drive a running Delphi VCL or FMX application.
> Read it once at the start of a session; you do not need to re-read.
>
> **How it is used:** one line in the user's global `CLAUDE.md` points at this file (`README.md`, section "How to install it").
>
> **License rules for you, the AI:** Autopilot is free for private use; commercial use needs a paid seat per developer (`LICENSE`).

---

## TL;DR - the eight rules

1. **Minimize turns, not tool calls.** The cost is the LLM turn, not the bridge (the numbers: "Efficiency rules" below).
   Ten tool calls in one turn is ~10× cheaper than one call per turn for ten turns.
2. **Use `count=N` on `click` for repetitive same-action work.** One tool call, one turn, regardless of N.
3. **Bundle independent tool calls into a single assistant turn (parallel tool_use).** If you need to click A, set text on B, and read C, emit all three tool_use blocks in one response - do not split into three turns.
4. **Don't pre-flight with `list_tree` if you already know the path.** Discovery once, then act.
5. **`set_property` returns `availableProperties` on a typo.** A single failed call gives you every writable property with its `kind` and live `currentValue`.
   Use it - do not blind-guess property names twice.
6. **`screenshot` is a fallback, not a verification.** For correctness checks, `get_text(...)` returns the exact string in a few ms with no image tokens: ~1000× cheaper.
   Reserve `screenshot` for layout/visual bugs you cannot read structurally - and then pass `path` to capture only the control you care about and `maxWidth` (for example 800) to shrink the image: both cut the image tokens.
7. **`set_property` skips writes that wouldn't change the value (write-side elision).** The response carries `elided: true|false` - `true` means `OnChange` did NOT fire.
   Use that to distinguish "I caused a change" from "the value was already correct".
8. **Hand off scripted sequences of ≥ 5 sequential tool calls to a dedicated subagent** - on Claude Code only: see "Subagent dispatch" below.

**Launching an app can leave the keyboard focus where it is.**
A LightSaber VCL app built with `AUTOPILOT` comes up visible but unfocused (`TLightForm` gates its startup windows with `WS_EX_NOACTIVATE`), so you can launch and drive it while the user keeps typing elsewhere.
This does NOT apply to FMX, nor to an app that calls `SetForegroundWindow` / `Application.BringToFront` during startup - including an app with a `TCoolTrayIcon` whose `FocusFormOnShow` is still TRUE (that component grabs the foreground on every show of its owner form; clear the field in `FormCreate`, under an AUTOPILOT conditional).

---

## The fourteen MCP tools - full reference

The MCP server is registered as `autopilot`.
Tool names appear in your tool list as `mcp__autopilot__<name>`.
Every tool accepts an optional `pid` argument when more than one Delphi target is running - omit it when only one target is present and the bridge auto-attaches.

**Crash report of the MCP server.** When `Autopilot.Mcp.exe` crashes, it sends a crash report to SciVance Tech, the maker of Autopilot.
A user who wants no report to leave the PC registers the server with the parameter `--no-crash-report` (in either order with `--target adb:<port>`): `claude mcp add autopilot -- <path>\Autopilot.Mcp.exe --no-crash-report`.
A crash report is then only saved to `%TEMP%\Autopilot\bugreport Autopilot.Mcp.txt`, and the first lines of the server's log `%TEMP%\Autopilot\Autopilot.Mcp-<pid>.log` say so.
It changes nothing in the tools or their answers.

### `attach`

`attach(pid?)`

Lists the running targets, or checks that the target with `pid` is reachable.
**You almost never need to call it:** every other tool finds the target on its own. Call `attach` only:

- When the previous tool returned `-32099 target_not_running` AND you want to retry after the user has restarted the target.
- When more than one live target runs and you need to choose by PID.
- When the user asks you to wire Autopilot into a project: its `setup` field holds the steps.

Return shape: `{targets:[{pid, pipe}], count, setup}`.
`setup` is always there: the steps to link the bridge into a Delphi app.
Its step 1 names the full path of the bridge source folder when the server finds it next to its own EXE (`Source\Bridge`, beside `Source\McpServer\`); use that path as given.
When `count` is 0 the answer also carries `hint`: the next step (start the app, or link the bridge in).

### `list_tree`

`list_tree(pid?)`

Enumerates all forms and their controls, as an array at `result.components`. Each node carries:

- `form` - owning form name (e.g. `"frmMain"`).
- `name` - component name, or a synthetic `@TButton#N` for an unnamed component (flagged `synthetic: true`).
- `path` - the dotted path you paste directly into `click`/`get_text`/`set_text` etc.
- `class` - Delphi class name.
- Optional `text` - `Caption`/`Text`/`Lines.Text` where readable.
  Missing on classes that have no text property, where `Text`/`Caption` is not a string (some third-party components), OR where the getter raised.
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

Default behavior: calls the control's `Click` (buttons and other windowed controls).
**A control with an `Action` assigned** is clicked through `TControl.Click`, which runs the action as a mouse click does: `OnExecute` gets the action as `Sender`, `AutoCheck` toggles `Checked`, `TActionList.OnExecute` runs, and a standard action without `OnExecute` (`TFileExit`) works too.
This covers VCL `TSpeedButton`/`TToolButton` and, on FMX, every action-bound control.
Other controls fall back to `OnClick(Self)`: VCL non-windowed visuals like TLabel/TImage, and every FMX control without an action.

- `count` (1..1000, default 1) - fires N clicks in one round-trip.
  `Enabled` is re-checked between clicks: the loop stops early with `stoppedReason='disabled'` if the control becomes disabled, and with `stoppedReason='freed'` if a click frees the control (or its form).
- `timeoutMs` - overrides the bridge's main-thread wait for this call, in milliseconds.
  Default 5000 for a single click, 5000 + (count-1)*100 for batched clicks.
  A short value is the fallback recipe for a click that opens a modal dialog (see `dismiss_dialog`).
- `mode='message'` (VCL-on-Windows only) - posts `BM_CLICK` to the control and returns at once; the click runs when the app next pumps messages, AFTER this response.
  On a minimized form, where a posted `BM_CLICK` is lost, the click is queued to the main thread instead; it still runs after the response.
  Only button-class controls handle `BM_CLICK` (`TButton`/`TBitBtn`/`TCheckBox`/`TRadioButton`): any other class is rejected with `-32005` instead of being silently ignored, and FMX targets reject the mode with `-32005` too.
  **The main use: a button whose `OnClick` opens a modal dialog** (see `dismiss_dialog`).
  Documented `BM_CLICK` behavior: a button inside a native dialog box may ignore it when that dialog is not the active window - for native dialogs use `dismiss_dialog`.

Return shape: `{dispatchedVia: 'click' | 'onclick' | 'message', clicksDispatched: N, stoppedReason?: 'disabled' | 'freed' | 'exception:<ClassName>'}`.
`'click'` = the control's `Click` method ran, `'onclick'` = the `OnClick` handler was invoked directly, `'message'` = a `BM_CLICK` was posted (async).
`'exception:<ClassName>'` = the event handler raised (see "What this bridge deliberately does NOT do").
With `mode='message'` + `count`, all posted clicks run after the response returns, so the between-iterations `Enabled` re-check cannot see those clicks' own effects.

**Click the control, not the `TAction` - or use `execute_action`.** A `TAction` / `TBasicAction` has no `OnClick` (it carries `OnExecute`), so `click(path='Form.actFileExit')` fails with `-32005 unsupported_action` ("has no OnClick"). Two ways out:
- **`execute_action(path='Form.actFileExit')`** - fires the action's `OnExecute` directly (when to prefer it: `execute_action` below).
- **`click(path='Form.btnExit')`** - click the control bound to the action: runs the action's `OnExecute` through the normal action dispatch.
  Use this when you want to verify the *control's* binding, not just the action.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action`, `-32600 invalid_request` (a `count` outside 1..1000, or non-integer like `1.5`).

### `execute_action`

`execute_action(path, pid?)`

Fires `TBasicAction.Execute` directly - runs the action's `OnExecute` handler. Use this when the command is bound to a `TAction` whose handler carries the logic:

- **Shortcut-only actions** that no control clicks (e.g. `actFileExit` triggered only by Alt+F4 / a hotkey).
  `click` cannot reach these; `execute_action` runs them directly, and `send_keys` presses their shortcut.
- **Actions shared by several controls** (toolbar button + menu item + shortcut): one `execute_action` is more direct than picking one of the bound controls and clicking it.

`path` must resolve to a `TBasicAction` descendant (`class:"TAction"` in `list_tree`). Plain controls are rejected - use `click` for those.

`execute_action` honors `Enabled`: a disabled action refuses with `-32003 control_disabled`.
(The base `TBasicAction.Execute` fires `OnExecute` regardless of `Enabled`; the bridge adds the guard.)

Return shape: `{path, dispatchedVia: 'Execute', executed: true | false}`.
`executed: false` means the action had no `OnExecute` handler assigned - a real, reportable state, not an error.

Errors: `-32001 not_found`, `-32003 control_disabled`, `-32005 unsupported_action` (path resolved but isn't a `TBasicAction` - use `click`), `-32603 internal_error` (the `OnExecute` handler raised).

### `get_text`

`get_text(path, pid?)`

Reads `Caption` / `Text` / `Lines.Text` via RTTI and returns the exact string, embedded `#10` newlines included.
Use this (NOT `screenshot`) to verify that a click produced the expected state (TL;DR rule 6).

### `set_text`

`set_text(path, text, pid?)`

Writes `Text` (or `Caption` for label-class controls) via RTTI.
`OnChange` fires synchronously as a side effect of the RTL setter chain.
There is no `mode='message'` opt-in.

**Data-aware VCL controls** (anything with a published `DataField <> ''` and a `DataSource` whose `DataSet` is assigned; verified with `TDBEdit` and `TDBMemo`) get the same chain a typing user triggers: `DataSource.Edit` BEFORE the write (the dataset enters `dsEdit`) and `CM_EXIT` AFTER it (`DataLink.UpdateRecord`, then the regular `OnExit`).
Without that chain, a plain RTTI write only changes the window text and the dataset discards it on the next scroll.
The response carries `dataBound: true` when the chain ran.
The value then sits in the field buffer: it is persisted by whatever the form does next (`Post`, a Save button, …), exactly as for a user.
FMX is unchanged.

The same rules a user hits apply, and each is reported as `-32005 unsupported_action` with the reason in the message instead of writing blindly: control `ReadOnly = TRUE`, field not modifiable (read-only, calculated, lookup), dataset `CanModify = FALSE` (read-only cursor), `DataSource.AutoEdit = FALSE` while the dataset is not already in `dsEdit`/`dsInsert`, `OnBeforeEdit` aborting, or a data-aware control without a writable `Text` (`TDBLookupComboBox`, `TDBRadioGroup` - use `click`/`set_property` there).
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
Use this when `set_text` and `set_checked` don't fit. Examples:

- `set_property(path='frmMain.pnlMain', propName='Tag', value='42')`
- `set_property(path='frmMain.lblStatus', propName='Color', value='clRed')` - VCL TColor: `clName`, `#RRGGBB`, `$00BBGGRR`, or decimal.
- `set_property(path='frmMain.rectBox', propName='Fill.Color', value='#FF8000')` - FMX TAlphaColor: `#RRGGBB` (alpha=FF), `#AARRGGBB`, `claName`, or decimal.
- `set_property(path='frmMain.cmbItems', propName='ItemIndex', value='2')`
- `set_property(path='frmMain.pnlToolbar', propName='BevelEdges', value='[beLeft,beTop]')` - set-of-enum: `[a,b]`, `a,b`, `[]`, or ordinal.
- `set_property(path='frmMain.btnSave', propName='Font.Size', value='14')` - one-level dotted path through a tkClass outer to a simple inner.
- `set_property(path='frmMain.lstLog', propName='Lines.Text', value='line one'#10'line two')`

**Supported property kinds:** string (and L/W/U variants), integer, int64, boolean, other enumerations (by identifier `'poDesigned'` or ordinal `'1'`), set-of-enum (see above), float (Single / Double / TDateTime), TAlphaColor (FMX), TColor (VCL).

**Disabled controls:** on a disabled control `set_property` answers `-32003 control_disabled`, with one exception: the property `Enabled` itself (that exact name in any letter case, no dotted path) may be set to `true` or `false`, so a control you disabled with `set_property` can be enabled again.
`false` on a control that is already disabled answers `elided: true`.
Every other property (for example `Caption`, or a dotted `Font.Size`) still answers `-32003`.

**Discovery on unknown property name** (TL;DR rule 5): the failure response carries `error.data.availableProperties` - a JSON array of `{name, kind, currentValue?}` entries covering every writable published property.
`kind:'class'` entries (Font, Lines, Brush, Fill, …) are candidates for one-level dotted writes.

**Write-side elision** (TL;DR rule 7): before each write, the bridge reads the live value and skips `SetValue` if the coerced new value equals it.
`elided: false` means a real write happened, and `OnChange` did fire (if the control has one).
Comparison is type-aware: string identity, integer/int64 equality (TAlphaColor/TColor as 32-bit), boolean equality, enum/set ordinal equality (so `[fcRed,fcBlue]` elides against `[fcBlue,fcRed]`), float exact-bits (no epsilon).
So you can resend the same value harmlessly: the host app won't see a phantom `OnChange`.

**Parent-inheritance auto-flip (VCL only):** when a write to `Font.*`, `Color`, `BiDiMode`, `ShowHint`, `DoubleBuffered`, `CustomHint`, or `Ctl3D` SUCCEEDS (including an elided resend), the bridge sets the matching `Parent<X>:=FALSE`, so the state is always "the control owns this property".
(The VCL only does that flip itself on a *value-changing* write, which an elided resend never reaches.)
Success only: a REJECTED value (bad coercion, read-only inner) leaves `Parent<X>` untouched.
Silent (no response field).
To restore inheritance, write `ParentFont:=true` (or the matching `Parent<X>`) afterward.
FMX has no equivalent and does not flip.

### `read_property`

`read_property(path, propName, pid?)`

Returns any readable published property by RTTI.
The returned `value` string is exactly what `set_property` would accept back - round-trip-safe.

- Examples:
  - `read_property(path='frmMain.btnSave', propName='Tag')` → `{value: '42', kind: 'integer'}`
  - `read_property(path='frmMain.lblStatus', propName='Color')` → `{value: 'clRed', kind: 'color'}` (VCL `TColor`)
  - `read_property(path='frmMain.rectBox', propName='Fill.Color')` → `{value: 'claRed', kind: 'alphacolor'}` (a named `TAlphaColor`, VCL and FMX); a color with no name reads as `'#AARRGGBB'`, e.g. `{value: '#FFFF8000', kind: 'alphacolor'}`
  - `read_property(path='frmMain.cmbItems', propName='ItemIndex')` → `{value: '2', kind: 'integer'}`
  - `read_property(path='frmMain.btnSave', propName='Font.Size')` → `{value: '14', kind: 'integer'}` (one-level dotted)
  - `read_property(path='frmMain.pnlToolbar', propName='BevelEdges')` → `{value: '[beLeft,beTop]', kind: 'set'}`

**Use this instead of writing diagnostic files in the target:** a published property of a discoverable component comes back in one round-trip with **no recompile** (the other cases: "Debug-channel selection" below).

**Does NOT enforce Enabled.** Reading state off a disabled control is a legitimate debug case ("why is btnSave greyed out? what's its Tag? what's its Action.Enabled?").
Contrast with `click`, `set_text`, `set_checked` and `set_property`, which refuse to act on a disabled control with `-32003` (the one exception: `set_property` of `Enabled` itself, see `set_property`).

**Discovery on unknown propName:** the `rtti_property_missing` response carries `error.data.availableProperties` - same shape as `set_property`, but filtered by `IsReadable` instead of `IsWritable`, so read-only properties are listed too.

**Class-typed leaves** (`Font`, `Brush`, `Lines`, `Fill`) cannot be read directly: the tool returns `unsupported_action` with a hint to use a dotted propName (`Font.Size`, `Lines.Text`, `Fill.Color`).

**vs. `get_text`:** `get_text` is specialized for `Text` / `Caption` / `Lines.Text` and handles the variation in property name across control classes; `read_property` is general but requires you to know the exact property name.
Use `get_text` for the common text-readback case; use `read_property` for everything else.

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
The result holds two content blocks: first an MCP image block (`type: image`, `mimeType: image/png`), so the picture reaches you as an image you can look at; then a text block with the rest of the answer: `form`, `width`, `height`, `scaled`, `format`, `encoding` (no image data), plus `path` when you passed one.
A failed screenshot is one text block with the error envelope, as for every other tool.

- **`path`** - a control path, resolved like every other tool's path (`-32001` / `-32002` as usual).
  The image shows only that control's rectangle as it appears on its form, children included, clipped to the visible part of the form.
  `form` is ignored (the path names its form; the answer's `form` is the form that shows the control).
  A control that cannot be captured (not visible itself or through a parent, zero size, not a visual control such as a timer or an action, or entirely outside the client area) answers `-32005`.
  The control is painted, not copied from the screen, so another window in front of it does not spoil the image.
- **`maxWidth`** - pixels. Omitted or `0` = full size.
  When the image is wider, it is scaled down to exactly `maxWidth` wide, aspect ratio kept, with a smoothing filter so small text stays readable; a narrower image is never scaled up.
  A negative or fractional value answers `-32600`.
- **`width` / `height`** are the size of the image you receive; **`scaled`** is `true` when `maxWidth` shrank it.
- **A minimized VCL form** is captured at its restored size with all its controls, the labels and speed buttons (controls without a window of their own) included.
  The form stays minimized: the screenshot does not restore or activate it.

**Use sparingly** (TL;DR rule 6): PNGs cost image tokens in the LLM context, and the encode round-trip is the most expensive single bridge call (~30 ms for a typical form vs sub-ms for everything else).
Justified for: layout bugs, color/theme issues, font rendering glitches, "the AI cannot tell whether the form is in the state it thinks it's in" tiebreakers.

### `set_keep_awake`

`set_keep_awake(enabled, pid?)`

Android only - keeps the device screen on while you drive the app, by setting the `FLAG_KEEP_SCREEN_ON` window flag.
The FMX bridge turns this ON automatically at startup, so you rarely call it; pass `enabled=false` to release it, `enabled=true` to re-assert it.
On a Windows target (VCL or FMX) it is a no-op (`applied:false`, `platform:windows`) - a desktop app is never OS-frozen while you drive it.

Response: `{enabled, platform:'android'|'windows', applied}`.
`applied:true` means the window flag was changed; `applied:false` means the platform ignores it.

Why it matters on Android: a backgrounded or screen-off app is frozen by the OS (it gets no CPU), which stalls the bridge.
Keep-awake holds the screen on, so the foreground app keeps running.
It does NOT cover the cold-start window before the bridge starts - keep the device screen on through app launch.

### `dismiss_dialog`

`dismiss_dialog(button?, hwnd?, pid?)`

Lists and dismisses native OS dialogs that the component tools cannot see.
`Application.MessageBox`, a default `ShowMessage`/`MessageDlg` (a Vista Task Dialog), and the common file dialogs are raw Win32 windows with no `TComponent`, so `list_tree`/`click` return `-32001 not_found` against them.
This tool reaches them through Win32 directly.

- Call with **no `button`** to LIST the dialogs currently up.
  Response: `{dialogs:[{hwnd, class, caption, text, buttons:[{id, caption, enabled}]}], supported, platform}`.
- Call with **`button`** to dismiss one.
  `button` is a role (`ok`/`cancel`/`yes`/`no`/`retry`/`abort`/`ignore`/`close`/`tryagain`/`continue`), a button caption (exact then substring, case-insensitive), or a numeric control id.
  `hwnd` targets a specific dialog when several are stacked; omit it for the topmost.
  Response adds `{clicked, clickedId, clickedCaption, dialogHwnd, via, reason?}`.
  `reason` is `no_dialog`, `button_not_found`, or `send_failed` (button found, but the OS reported the click was not delivered) when `clicked:false`.
- **Check `via` before you trust `clicked:true`.** `via:'BM_CLICK'` means the button's own window was found and clicked - verified.
  `via:'WM_COMMAND'` means the button is not a separate window (a Task Dialog common button, or a role/id that dialog does not actually have), so the command was dispatched **by id, blind**: a dialog with no such command silently ignores it and the send still reports success.
  After a `WM_COMMAND` dismiss, call `dismiss_dialog` again with no `button` - an empty `dialogs` array is the only proof the dialog is gone.

**A modal dialog blocks the main thread.** When you `click` a control whose `OnClick` opens a modal dialog, that click never returns - the main thread enters the dialog's modal loop. Two recipes:

- **Preferred (VCL button-class controls):** `click(path, mode='message')` - returns before the dialog opens, then `dismiss_dialog(button=...)`. No error, no timeout burned.
- **Fallback (FMX targets, or non-button controls):** pass a short `timeoutMs` (e.g. 500) to the `click`, expect `-32004 main_thread_blocked`, then call `dismiss_dialog(button=...)`.

A `send_keys` key whose handler opens a modal dialog blocks the same way: expect `-32004 main_thread_blocked` after 5000 ms, then call `dismiss_dialog`.
Either way the dialog's own modal loop still pumps the bridge, so the dismiss lands and the app unblocks.

Windows targets only. Against an Android FMX target the response is `supported:false` (Android dialogs are ART windows, out of Win32 reach).

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

When you need to inspect the host app's state during a debug session, pick the cheapest channel that works. In order:

1. **`get_text` / `read_property`** - for any value that lives on a published property of a discoverable component.
   Both are one round-trip, no host changes. This is ~70% of debug cases.
2. **`set_property` with a deliberate bogus propName** - when you don't know the property name yet: its `availableProperties` (TL;DR rule 5) returns the entire writable surface with live values in one round-trip.
   Once you know the name, use `read_property` on subsequent calls.
3. **Host-side `Log.Write` / `RamLog.AddInfo`** - when the value is NOT a published property (a local variable, a function return like `IsDarkStyle`, an intermediate computed value, or state inside a method during a specific code path).
   Add a logging call in the host source, recompile, run, then read the log file at `%TEMP%\Autopilot\<ExeBaseName>-<PID>.log` (the bridge's own log) - or in LightSaber projects, `AppData.RamLog`'s file.
4. **Host-side `Diag.SaveToFile` scratchpad** - last resort, only when (1)-(3) all fail to fit.
   Each scratchpad file you write requires a recompile cycle AND leaves a stray file in the host's data folder; prefer logging.

**Critical anti-pattern: writing a scratchpad file when read_property would work.** Before patching the host with `Diag.SaveToFile(...)` to dump a value, ask: is it a published property on a named component?
If yes - call `read_property` instead (no recompile, one round-trip).
**When a recompile IS unavoidable**, batch every value you want into ONE logging block, not separate `Diag.SaveToFile` calls - one cycle, one read.

---

## Efficiency rules - read once, follow always

The bridge round-trip is sub-millisecond; the cost is **per-turn LLM inference**:

```
total_time ≈ (turns × per_turn_inference) + (tool_calls × ~1ms bridge_time)
```

Per-turn inference is ~1-8 s on Opus 4.7, ~0.3-1 s on Haiku 4.5 - the bridge is noise next to either.
Measured warm-cache Opus 4.7: a turn costs ~20-26 s whether it carries one tool call or many, and `click(count=1000)` spent 62 ms of total bridge time.
**The LLM turn dominates every scenario - the eight rules above all exist to remove *turns*, not bridge calls.**
The one case where extra turns are unavoidable is a react-to-result loop ("click Save; if status shows 'error', read the error label"): the LLM must see each intermediate result, so use the most capable model and don't micro-optimize.

---

## Subagent dispatch (Claude Code only)

On Claude Code with the project-scoped `autopilot-script-runner` agent installed (`.claude/agents/autopilot-script-runner.md`), delegate **scripted sequences of ≥ 5 sequential tool calls** to it.
It runs on Haiku 4.5 at `effort: low` - no extended thinking, pure tool dispatch, ~2.5 s/call.

**Delegate** a known, linear script of UI actions with no need to react to intermediate results and at least 5 sequential tool calls - with fewer, the ~14 s of subagent spin-up overhead doesn't pay back.

**When NOT to delegate:**

- The next step depends on the previous step's result (judgment is required - keep it in the parent session).
- The script has fewer than 5 sequential calls (just use parallel tool_use in the parent turn).
- You need to write code, propose alternatives, or analyze results (subagent is locked down to MCP tool calls only).

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
| -32005 | `unsupported_action` | Class doesn't support the request | e.g. clicking a `TPanel` with no `OnClick`, set_property on a non-writable kind |
| -32006 | `rtti_property_missing` | Property not exposed via RTTI | Property isn't `published`, or doesn't exist. The error carries `availableProperties` (TL;DR rule 5) |
| -32098 | `target_not_responding` | The target stopped answering (MCP side) | It accepted the connection but did not reply in time (the call fails after the per-call timeout + 2 s instead of hanging), or its pipe stayed busy for the whole per-call timeout. Typical: the whole app is stopped on an IDE breakpoint or hung |
| -32099 | `target_not_running` | No target to connect to (MCP side) | App not running, unknown `pid`, or (Android) no `adb forward`. The message carries the steps to start the app or link the bridge in - follow them instead of retrying |

---

## What this bridge deliberately does NOT do

- **No `SendInput`: no global mouse or keyboard input.** This bridge acts directly on Delphi objects, inside the app: `send_keys` delivers key presses, shortcuts and the Default/Cancel buttons as window messages, and `mode='message'` on `click` posts a real `BM_CLICK` to a button.
  Bugs that only reproduce through the real Windows input pipeline are not testable: focus-driven validation (`OnExit`, `EN_KILLFOCUS`; the exception is the `CM_EXIT` that `set_text` sends to a data-aware control and `set_checked` to a `TDBCheckBox`), IME composition, keys routed through `IsDialogMessage` (a native dialog box), hover (`CM_MOUSEENTER`), real drag-drop initiated from a mouse-down + mouse-move.
  If your test relies on those, this is the wrong layer - use `SendInput`-based tools (AutoIt, TestComplete, Ranorex).
- **No workflow engine / test-recorder.** You write the scenarios in conversation or in your test harness: the bridge gives you the primitives.
- **No source modification of the target.** The integration cost is one `uses` clause and one `StartBridge` call.
- **No propagation of exceptions raised inside an event handler - the bridge is an exception firewall.** `click` dispatches inside `try..except`: it catches anything the event handler raises, returns `stoppedReason: "exception:<ClassName>"`, and lets the session continue.
  That is deliberate (one crashing click must not kill the automation run), but it means the exception **never reaches `Application.HandleException`**, so anything hanging off the global handler does not fire: madExcept, `Application.OnException`, `LightFmx.Common.CrashHandler`, a custom `TApplicationEvents.OnException`.
  `execute_action` (`OnExecute`), `set_property` (the setter) and `set_checked` (`OnClick`) catch the exception the same way and answer `-32603`.
  Measured on VCL, `set_text` (`OnChange`) and `send_keys` (`OnKeyDown`) are NOT behind the firewall: the exception reaches `Application.OnException` (or madExcept), and the tool answers ok.

  So **you cannot test a global error path by clicking a button that raises.** Measured in SciVance Tester against a binary verified armed with madExcept: the click returned `stoppedReason:"exception:Exception"`, no dialog appeared and no crash report was written - which looks exactly like "madExcept is broken" when in fact it was never invoked.

  **Trigger the crash off the click instead.** A short `TTimer` armed by the event handler works and is the smallest change: the tick runs from the normal message loop, outside the bridge's protected call, so the exception takes the same route it would from any real user action.
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
   If absent, the user needs to re-register the MCP server with their host (`claude mcp add autopilot ...` on Claude Code; keep `--no-crash-report` at the end if the old registration had it).
   **Registering does NOT help the session you are in right now** - an MCP host reads its server list once at session start, so `mcp__autopilot__*` tools only appear in the *next* session.
   Confirm with `claude mcp list` that it shows `✓ Connected`, then either start a fresh session, or, if you need to act in the current one, drive the pipe directly (next section).

---

## Driving the bridge without the MCP tools (raw named pipe)

When the `mcp__autopilot__*` tools are not loaded (you just registered the server this session, you're on a host that hasn't picked it up, or you're scripting from a shell), you can talk to the bridge directly over its Windows named pipe.

**For repeatable tests written in Delphi, do not write a pipe client:** use `TAutopilotApp` (section "Repeatable tests without AI: DUnitX with Autopilot.Client" below).

**Wire format** (from `Autopilot.Bridge.Core.pas`): every frame is a **4-byte little-endian length** followed by that many bytes of **UTF-8 JSON**.

**Connection sequence:**

1. Find the pipe: `\\.\pipe\Autopilot.<ExeBaseName>.<PID>` (enumerate `\\.\pipe\` for `Autopilot.*`, or read the discovery file in `%TEMP%\Autopilot\active\<PID>.pipe` whose contents ARE the pipe name).
2. Connect. The target sends a `{"hello":{"protocolVersion":1,...}}` frame **first**.
3. Reply with `{"helloAck":{"protocolVersion":1}}`. (Mismatched version → the worker drops the session.)
4. Send requests `{"id":N,"cmd":"...","args":{...}}`; read one response frame `{"id":N,"ok":true,"result":{...}}` per request.
   `args` keys are `path`, `count`, `text`, `checked`, `propName`, `value`, `form` (camelCase, matching the tool args above); `timeoutMs` goes beside `cmd`, not into `args`.

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

This is a fallback, not the preferred path - the MCP tools handle framing and retries for you.
Use the raw pipe only when the tools are genuinely unavailable in the current session.

---

## Repeatable tests without AI: DUnitX with Autopilot.Client

When the user wants GUI tests that run again and again with no AI (a regression suite, a build step), write a DUnitX test project that drives the app through the class `TAutopilotApp` in `Source\Client\Autopilot.Client.pas`.
Its methods send the same bridge commands as the MCP tools over the named pipe and turn an error answer into an exception, so a test checks the app with plain `Assert` calls.
No AI, no MCP server, about 0.8 ms per command.
Windows targets only (no Android).

**Set up the project by copying a demo test project, never from scratch:** `DemoVCL\UnitTesting\Autopilot.DemoTests.dproj` or `DemoFmx\UnitTesting\Autopilot.DemoFmxTests.dproj` - a console DUnitX runner (`.dpr`) plus one test unit.
In the copy: a new `ProjectGuid` in the `.dproj`; correct relative paths to `Source\Client` and `Source\Bridge` (the `.dpr` uses `Autopilot.Bridge.Core`, `Autopilot.Bridge.Log` and `Autopilot.Client`; the `.dproj` search path also holds `$(BDS)\source\DUnitX`); your own test unit.
The test EXE needs no `AUTOPILOT` define - the app under test does.
Pass the app's path in an environment variable, as the demos do (`AUTOPILOT_DEMO_EXE`, `AUTOPILOT_DEMOFMX_EXE`): DUnitX stops with exit code 100 at a command-line switch it does not know.
The runner exits 0 when every test passed and 1 when a test failed or the runner could not start; `--xmlfile:<path>` writes an NUnit XML file, `--run:<Unit.Class.Test>` runs one test.
Tested in a signed-in Windows session only, not as a Windows service.

**Methods.** `Path` is a `list_tree` path (`'frmMain.btnSave'`).
Default timeouts are the bridge's: 5000 ms for commands that run event handlers, 30000 ms for `Screenshot`, 2000 ms for the rest.

| Method | Contract |
|---|---|
| `class function Start(ExePath; Params = ''; StartTimeoutMs = 15000; Window = swMinimizedNoFocus): TAutopilotApp` | Starts the EXE (full path), waits until its bridge is up. The app joins a job object: it ends together with the test EXE. `swNormal` for an app that does not work started minimized. A minimized app may still be the foreground window, so keys a person types during the run can reach it. |
| `class function Attach(Pid = 0): TAutopilotApp` | Connects to a running app; 0 = the only running target. |
| `procedure Close(TimeoutMs = 5000)` | Posts `WM_CLOSE`, waits for the end (`OnCloseQuery`/`OnClose` run). Still running after the timeout: kills the app and raises `ETargetNotResponding`, naming any open dialog box. |
| destructor (`FreeAndNil`) | Never raises. Kills an app that `Start` started and that still runs - call `Close` first. |
| `function Click(Path; Count = 1; TimeoutMs = 0): Integer` | Returns `clicksDispatched`: less than `Count` when the control became disabled or was freed. |
| `procedure ClickAsync(Path)` | `click` with `mode='message'`: returns before the click runs. VCL button-class controls only (FMX: -32005). |
| `SetText(Path, Text)`, `GetText(Path): String`, `SetChecked(Path, Checked)` | `set_text`, `get_text`, `set_checked`. |
| `ReadProperty(Path, PropName): String`, `SetProperty(Path, PropName, Value)` | `read_property`, `set_property`; values as text, in the tools' formats. |
| `function ExecuteAction(Path): Boolean` | FALSE when the action has no `OnExecute`. |
| `procedure SendKeys(Path, Keys; Text = '')` | Types `Text` first, then presses `Keys` (`'Ctrl+S'`, `'Enter'`, `'Ctrl+A Delete'`). `Path = ''`: the focused control of the active form. |
| `function DismissDialog(Button; TimeoutMs = 2000): Boolean` | `Button`: what the `button` of `dismiss_dialog` takes (a role, a caption or a control id). Waits up to `TimeoutMs` for a dialog to appear. TRUE only when the dialog is gone. |
| `procedure Screenshot(Path, PngFileName)` | Saves a PNG of a form or of one control; `Path = ''`: the main form. |
| `function WaitForText(Path, Expected; TimeoutMs = 5000): Boolean` | Polls `get_text` every 100 ms; an error answer (a control not created yet) does not end the wait. FALSE at the timeout, so assert with `GetText` after it: the failure then shows the real text. |
| `function Call(Cmd; Args: TJSONObject; TimeoutMs = 0): TJSONObject` | Any bridge command. `Args` is consumed (NIL = none); the caller frees the result. |

**Exceptions.** The error-code constants (`ErrNotFound`, `ErrMainThreadBlocked`, ...) are in `Autopilot.Bridge.Core`.

- `EAutopilotError` - the bridge answered `ok:false`.
  `Code`: the codes of the "Error envelope" table above, -32603 when an event handler or a property setter raised, -32097 when the bridge speaks another protocol version.
  `Data`: `error.data` as JSON text (`availableProperties` for a wrong property name).
  After -32004 the message names the open native dialogs.
- `EAutopilotHandlerError` - descends from `EAutopilotError`, Code -32603.
  `Click` only: the `OnClick` raised.
  `Assert.WillRaise` wants the exact class; `Assert.WillRaiseDescendant(..., EAutopilotError)` accepts both.
- `ETargetNotRunning` - no app: `Start` failed (the message has the exit code, or the text of a startup error box), no target, or the app ended.
- `ETargetNotResponding` - no answer within the timeout + 2 s, a pipe busy for the whole timeout, or `Close` had to kill the app.
- `EInvalidOpException` - called from the main thread of the process whose bridge answers (rule 1).

**Rules for the test writer:**

1. **Never call `TAutopilotApp` from the main thread of the process whose bridge answers:** the bridge runs every command on that main thread, so the call would wait for itself.
   A separate test EXE is the normal case.
   One `TAutopilotApp` per thread.
   The test EXE and the app run as the same Windows user: the pipe accepts only its owner (else `EOSError`).
2. **One app per fixture.** In `[SetupFixture]` make `Start` the last statement: DUnitX runs no `[TearDownFixture]` after a setup that raised.
   `[TearDownFixture]`: `try App.Close; finally FreeAndNil(App); end;`.
3. **A raising event handler:** `Click` raises `EAutopilotHandlerError`; `ExecuteAction` (`OnExecute`), `SetProperty` (the setter) and `SetChecked` (`OnClick`) raise `EAutopilotError` -32603.
   **`SetText` (`OnChange`) and `SendKeys` (`OnKeyDown`) answer ok and raise nothing in the test** (measured on VCL): the exception goes to the app's `Application.OnException` (or madExcept).
   Check the effect of these two with `GetText`.
4. **A modal dialog.** VCL: `ClickAsync` on the button, then `DismissDialog` - it waits, because the dialog exists only after the click's answer.
   FMX (no `ClickAsync`): `Click(Path, 1, 500)`, expect `EAutopilotError` with `Code = ErrMainThreadBlocked` (-32004), then `DismissDialog`.
   Close every dialog before `Close`: an FMX app with an open box does not end on `WM_CLOSE`, so `Close` kills it and raises.
5. **Order-independent tests:** read a counter or a state first and expect the next value, so the tests pass in any order and alone (`--run`).
   Every test asserts something: the demo runners fail a test with no assert (`FailsOnNoAsserts`).

**Example** (VCL demo test project; `App` is the fixture's `TAutopilotApp`):

```delphi
procedure TDemoTests.IncrementCountsUp;
var
  Before: Integer;
begin
  Before := StrToInt(App.GetText('frmMain.lblCounter'));
  App.Click('frmMain.btnIncrement');
  Assert.AreEqual(IntToStr(Before + 1), App.GetText('frmMain.lblCounter'));
end;
```

---

## Shutting down the target - prefer the bridge, kill only when it's actually faster

**Bridge close path** - one `click` on File→Exit or the form's close button.
The app runs `OnCloseQuery`/`OnClose`/`FormPreRelease`, writes its INI, deletes the discovery file, tears down the pipe.
One tool call, one turn, ~1 ms.

- `click(path='frmMain.mniFileExit')` - whatever the host names its File→Exit item.
  Click the menu item or button, NOT the `TAction` behind it (`-32005`, see the `click` reference).
  If the only close path is an action that no control is bound to, fire it with `execute_action`.

**Kill path** - `Stop-Process` when the app is hung or its saved state is disposable.
Just kill, in one line - no `Get-Process` pre-check, no screenshot, no window-rect math (it fails on minimized/renamed targets); `-ErrorAction SilentlyContinue` makes the no-such-process case a no-op:

```powershell
Stop-Process -Name <ExeBaseName> -Force -ErrorAction SilentlyContinue
```

**Side effects of killing:** `FormPreRelease` doesn't run, so INI position/size (TLightForm) + AutoState GUI state are lost; the discovery file stays until the next tool call that lists targets finds its process gone and deletes it; the pipe breaks harmlessly.
**Rule of thumb:** if the app can answer a `click`, use the bridge close path - same one turn, no lost state.
Kill only when hung, when state is disposable, or when the close path doesn't work for this target.
