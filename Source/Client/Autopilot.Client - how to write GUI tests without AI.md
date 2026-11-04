# Repeatable tests without AI: DUnitX with Autopilot.Client

When the user wants GUI tests that run again and again with no AI (a regression suite, a build step), write a DUnitX test project that drives the app through the class `TAutopilotApp` in `Source\Client\Autopilot.Client.pas`.
Its methods send the same bridge commands as the MCP tools over the named pipe and turn an error answer into an exception, so a test checks the app with plain `Assert` calls.
No AI, no MCP server, about 0.8 ms per command.
Windows targets only (no Android).
The tool contracts and paths are in `AI-INSTRUCTIONS - tool reference.md`, the error codes in `AI-INSTRUCTIONS.md`, both at the root of this repository.

**Set up the project by copying a demo test project, never from scratch:** `DemoVCL\Push buttons\UnitTesting\Autopilot.DemoTests.dproj` or `DemoFmx\UnitTesting\Autopilot.DemoFmxTests.dproj` - a console DUnitX runner (`.dpr`) plus one test unit.
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
  `Code`: the codes of the "Error envelope" table in `AI-INSTRUCTIONS.md`, -32603 when an event handler or a property setter raised, -32097 when the bridge speaks another protocol version.
  `Data`: `error.data` as JSON text (`availableProperties` for a wrong property name).
  After -32004 the message names the open native dialogs.
- `EAutopilotHandlerError` - descends from `EAutopilotError`, Code -32603.
  `Click` only: the `OnClick` raised.
  `Assert.WillRaise` wants the exact class; `Assert.WillRaiseDescendant(..., EAutopilotError)` accepts both.
- `ETargetNotRunning` - no app: `Start` failed (the message has the exit code, or the text of a startup error box), no target, or the app ended.
- `ETargetNotResponding` - no answer within the timeout + 2 s, a pipe busy for the whole timeout, or `Close` had to kill the app.
- `EInvalidOpException` - called from the main thread of the process whose bridge answers (rule 1 below).

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
  Before := StrToInt(App.GetText('frmMain.lblIncrement'));
  App.Click('frmMain.btnIncrement');
  Assert.AreEqual(IntToStr(Before + 1), App.GetText('frmMain.lblIncrement'));
end;
```
