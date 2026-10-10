# Autopilot for Delphi

Existing AIs (Claude, etc) can already write and compile your Delphi code - but it test it. It cannot run your app and push the buttons, look at the GUI. 
Through *Autopilot for Delphi* the AI can clicks, type, read state, and record screenshots of the live application/forms. It does all this with no human at the keyboard.

For full overview, demos & tool reference see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**



## Requirements

- Delphi 11 Alexandria, 12 Athens or 13 Florence.
- Targets: Windows 32/64 bit (VCL and FMX) and Android (FMX).
- An AI assistant that speaks MCP: Claude Code, Kai, Claude Desktop, Cursor, Cline.

## Quick start

### Step 1 — The server is ready, nothing to build

The server is `Source\McpServer\Autopilot.Mcp.exe`, already in the download. Keep it in that folder: when your app is not wired yet, the server looks for the bridge units in `Source\Bridge\` beside it to tell your assistant how to link them in.

The EXE is code-signed by SciVance Technologies UG.

**Never start this EXE yourself.** It has no window and it does nothing on its own. Your AI assistant launches it and talks to it through its standard input and output.

### Step 2 — Tell your AI assistant where that EXE is (once)

In Claude Code this is one command:

```
claude mcp add autopilot -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe
```

Write the real full path of that EXE on your disk. Restart the assistant if it was already running. It now has thirteen new tools, all prefixed `autopilot`.

**Register it only where you need it.** Without `--scope`, as above, the server loads only in that project, so a session that never drives a Delphi app pays nothing for it. On the author's machine, moving two machine-wide registrations to this setup took 3,604 characters out of every session that does not drive a Delphi app. One catch: when the project is not a git repository, Claude Code finds such a registration only when the session starts in that exact folder, not in its subfolders. To cover every project and every subfolder at once, register it from the folder that holds all your projects with `claude mcp add autopilot --scope project -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe`. That writes a `.mcp.json` file there, which Claude Code finds from any folder below. It asks you to approve that server; to approve it once for every folder, add `"enabledMcpjsonServers": ["autopilot"]` to `C:\Users\<you>\.claude\settings.json`.

### Step 3 — Try it, on the demo that is already wired

1. Open `DemoVCL\Autopilot.Demo.dproj`, compile it, run it. Leave the app on screen.
2. Ask your assistant: *"List the controls of my running Delphi app, then click btnIncrement five times and read lblCounter."*

You do **not** tell the assistant where `Autopilot.Demo.exe` is. When the demo starts, it writes a small discovery file into `%TEMP%\Autopilot\active\` that holds the name of its communication channel. The server reads that folder. One Delphi app running means it connects to it without being asked; several running means you name the one you want by its process id.

### Step 4 — Wire it into your own application

Two lines in your project's `.dpr`:

```delphi
uses
  Vcl.Forms,
  Autopilot.Bridge.Vcl in '..\Source\Bridge\Autopilot.Bridge.Vcl.pas',   // 1. add the unit
  ...
begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Autopilot.Bridge.Vcl.StartBridge;                                      // 2. start the bridge
  Application.Run;
end.
```

For an FMX application use `Autopilot.Bridge.Fmx` instead of `Autopilot.Bridge.Vcl`.

Then add `AUTOPILOT` to the conditional defines **of your Debug build configuration only** — Project > Options > Building > Delphi Compiler > Conditional defines.

That define carries the whole safety story. The working code of the bridge sits inside `{$IFDEF AUTOPILOT}`. Without the define `StartBridge` compiles down to an empty procedure: your Release build opens no communication channel, starts no thread, and exposes nothing. There is nothing to remember to strip out before you ship.

**You do not have to do step 4 by hand.** Once step 2 is done you can simply say: *"Wire Autopilot into this project."* The assistant gets these steps from the server (its `attach` tool always returns them), edits the `.dpr` and sets the define for you.

A working example of exactly the code above: `DemoVCL\Autopilot.Demo.dpr`.

### Step 5 — Now use it

Talk to the assistant about your own app in plain words. It resolves the control names itself:

> *"Start my app, type 'Gabriel' in the name field, press Save, and tell me what the status label says."*
>
> *"The Next Page button does nothing. Run the app, press it, and find out why."*

## AI-INSTRUCTIONS.md — optional, and you write nothing in it

`AI-INSTRUCTIONS.md` in this repository is already written. It is a briefing **for the AI, not for you**: the thirteen tools, their arguments, the error codes, and how to drive an application in few and cheap turns.

To use it, copy the file into your own project folder and add one line to your project's `CLAUDE.md` so the assistant reads it:

```
Driving the GUI: see AI-INSTRUCTIONS.md
```

Skip this and everything still works. The assistant just finds its way around more slowly and spends more of your tokens.

## When nothing happens

- **The assistant says the target is not running.** The app must be running *at the moment you ask*, and it must be the build that has the `AUTOPILOT` define. A Release build is deaf by design.
- **No tools named `autopilot` in the assistant.** Step 2 did not take effect. Check the path in `claude mcp add` and restart the assistant. If you started the assistant in a subfolder of a project that is not a git repository, use the `.mcp.json` registration described in step 2.
- **Both the app and the server must run as the same Windows user.** The communication channel is locked to the account that created it.

## License

One license, the [SciVance Software License 3.0](LICENSE). Every developer needs a seat:

- **Noncommercial use - free seat** (personal, study, research, hobby, charity, school, public research / health / safety). Register once at <https://www.GabrielMoraru.com/autopilot>. No key, no activation.
- **Commercial or government use - paid seat**, $25 per developer, one-time. See [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

Both seats forbid redistributing the software and decompiling `Autopilot.Mcp.exe`, also through an AI agent acting for you.

**No redistribution, under either tier.** Use it, change it for yourself, and ship your own compiled application with the Autopilot units built in — all free. Handing the code itself to anyone else is not allowed: not the source, not the `.dcu` files, not a changed copy, not folded into a library, component set, template or sample project. Exact wording: [LICENSE](LICENSE) → *Distribution*.

The bridge is source-available, not open source. The server ships as a ready-made EXE.

## Future plans

Support for Mac.

## ⭐ Star this project

I give priority to my GitHub projects based on the number of stars they get. If you like this project, please star it — it tells me to keep working on it.

## What's new

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
- **Lighter on every session.** The text the server gives your AI at the start of every session shrank from 1,397 to 857 characters (39% less). The bridge setup steps used to ride along in every session; now the AI gets them only when it needs them. Want the rest too? Register the server only where you use it - see step 2 below. On the author's machine that took 3,604 characters out of every session that does not drive a Delphi app.
- **A clear answer when your app is not running.** Every tool now answers with error `-32099 target_not_running` plus the steps to start the app or link the bridge in (for an Android target, also the `adb forward` step). `attach` always carries the setup steps too.
- **`wait_for` stops at once** when no app is running, instead of waiting out its whole timeout.
- **Plain-ASCII tool descriptions**, so no AI host shows stray characters where a dash or an arrow was meant.

**August 2026**

- **`dismiss_dialog` tells you when it cannot confirm a click.** When it had to send the click by command id instead of pressing the button itself, the answer says `via:"WM_COMMAND"`, so the AI knows to list the dialogs again and check.
