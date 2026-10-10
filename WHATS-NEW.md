# Autopilot for Delphi - what's new

**October 2026 (server 1.1.0)**

- **Screenshots arrive as a picture.** `screenshot` now returns the PNG as an image your assistant can look at, plus a short text part with the form name, width and height. Before, the picture came as a long base64 text, and the AI never saw it as an image.
- **A frozen or busy app gives a clear answer.** When the app is stopped on a breakpoint or hung, so that its connection stays busy, the tools now answer error `-32098 target_not_responding` instead of a raw "could not open pipe" text. `wait_for` stops at the first `-32098` instead of polling on until its deadline.
- **A control moved onto another form is found through the form that shows it.** A panel created on one form and placed on a tab sheet of another can now be reached as `MainForm.tabFixEnters.Container`. If two controls fit such a path, the answer is `-32002 ambiguous_path` with the paths to use instead, and `list_tree` marks a moved control with a `parent` field.
- **A click on a control bound to an action runs the action**, the same as a mouse click: `OnExecute` gets the action as `Sender`, `AutoCheck` works, and a standard action such as `TFileExit` no longer fails.
- **No more debugger stops on third-party components with unusual property types**, such as DevExpress bar items, whose `Visible` is an enumeration. The bridge now checks a property's type before it reads or writes it, so it raises no hidden exception, and a debugger that stops on exceptions no longer halts your app during `list_tree`. The same holds when your app answers after the assistant has stopped waiting.
- **`set_property` can enable a disabled control again.** On a disabled control it now accepts the property `Enabled` (`true` or `false`); every other property still answers `-32003 control_disabled`.
- **Named colors read back as `claRed`**, as documented: a `TAlphaColor` (the FMX color type) used to read back as `Red`. A color with no name reads as `#AARRGGBB`.

**September 2026**

- **No compile step for the server.** `Source\McpServer\Autopilot.Mcp.exe` now comes ready to run in the download: register it with your assistant and go. You compile only the demo and your own app.
- **Lighter on every session.** The text the server gives your AI at the start of every session shrank from 1,397 to 857 characters (39% less). The bridge setup steps used to ride along in every session; now the AI gets them only when it needs them. Want the rest too? Register the server only where you use it - see step 2 of the Quick start in [README.md](README.md). On the author's machine that took 3,604 characters out of every session that does not drive a Delphi app.
- **A clear answer when your app is not running.** Every tool now answers with error `-32099 target_not_running` plus the steps to start the app or link the bridge in (for an Android target, also the `adb forward` step). `attach` always carries the setup steps too.
- **`wait_for` stops at once** when no app is running, instead of waiting out its whole timeout.
- **Plain-ASCII tool descriptions**, so no AI host shows stray characters where a dash or an arrow was meant.

**August 2026**

- **`dismiss_dialog` tells you when it cannot confirm a click.** When it had to send the click by command id instead of pressing the button itself, the answer says `via:"WM_COMMAND"`, so the AI knows to list the dialogs again and check.
