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

See [WHATS-NEW.md](WHATS-NEW.md).
