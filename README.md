# Autopilot for Delphi

AI assistants (Claude and others) can already write and compile your Delphi code, but they cannot test it: they cannot run your app, push its buttons and look at its forms.
Through *Autopilot for Delphi* the AI can click, type, read state, and take screenshots of the live application and its forms. It does all this with no human at the keyboard.

For the full overview, demos and tool reference see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**


## Requirements

- Delphi 11 Alexandria, 12 Athens or 13 Florence.
- Targets: Windows 32/64 bit (VCL and FMX) and Android (FMX).
- An AI assistant that speaks MCP: Claude Code, Kai, Claude Desktop, Cursor, Cline.

## What is in the package

- `Source\McpServer\Autopilot.Mcp.exe` - the MCP server your AI assistant talks to (with `thirdparty-notices.txt`).
- `Source\Bridge\` - the bridge units that you build into the debug build of your own app.
- `Source\Client\Autopilot.Client.pas` - the test client, for GUI tests in DUnitX that run with no AI.
- `DemoVCL\` and `DemoFmx\` - two demo apps, each with a demo DUnitX test project in its `UnitTesting\` folder.
- `AI-INSTRUCTIONS.md` - the briefing for your AI assistant. `LICENSE` - the license terms.

## Quick start


### Step 1 - Register the MCP server into your Claude

In Claude Code this is one command:

```
claude mcp add autopilot -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe
```

Write the real full path of that EXE on your disk. Restart the assistant if it was already running. It now has fourteen new tools, all prefixed `autopilot`.

Optional: when `Autopilot.Mcp.exe` crashes, it sends a crash report to SciVance Tech.
To keep that report on your PC, add `--no-crash-report` at the end: `claude mcp add autopilot -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe --no-crash-report`.
A crash report is then only saved to a file in `%TEMP%\Autopilot\`.

For details see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**

### Step 2 - Now use it

Ask the assistant to wire Autopilot into your project. It puts the `Source\Bridge` folder on the unit search path of your project, adds a `StartBridge` call to your `.dpr`, and adds the `AUTOPILOT` define to your Debug build only.

Then talk to the assistant about your own app in plain words. It resolves the control names itself:

> *"Start my app, type 'Gabriel' in the name field, press Save, and tell me what the status label says."*
>
> *"The Next Page button does nothing. Run the app, press it, and find out why."*

GUI tests that run with no AI, in a DUnitX project or as a build step: see the section "Repeatable tests without AI: DUnitX with Autopilot.Client" in [AI-INSTRUCTIONS.md](AI-INSTRUCTIONS.md), and the page [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/).

## AI-INSTRUCTIONS.md - optional, and you write nothing in it

`AI-INSTRUCTIONS.md` in this package is already written. It is a briefing **for the AI, not for you**: the fourteen tools, their arguments, the error codes, and how to drive an application in few and cheap turns.

To use it, copy the file into your own project folder and add one line to your project's `CLAUDE.md` so the assistant reads it:

```
Driving the GUI: see AI-INSTRUCTIONS.md
```

Skip this and everything still works. The assistant just finds its way around more slowly and spends more of your tokens.

## Security and privacy

What Autopilot can read, where the data goes, and how to keep it to test data and one project: [Autopilot for Delphi - Security and privacy](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-security-and-privacy/).

## License

One license, the [SciVance Software License 3.4](LICENSE). Every developer who uses Autopilot for Delphi needs a paid seat: one seat per developer, for any use, commercial or not. A seat is for life and covers every 3.x release; version 4 will be a new purchase. Price and how to buy: <https://www.GabrielMoraru.com/autopilot>.

For testing inside your company, a colleague who holds a seat of their own may get your built test application and the `AUTOPILOT` build of your app, and a build server that you control runs under your seat. Terms: [LICENSE](LICENSE).


## Future plans

Support for Mac.

## What's new

See [Autopilot for Delphi - What's New](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-whats-new/).
