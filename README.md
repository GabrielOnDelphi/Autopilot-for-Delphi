# Autopilot for Delphi

Existing AIs (Claude, etc) can already write and compile your Delphi code - but it test it. It cannot run your app and push the buttons, look at the GUI. 
Through *Autopilot for Delphi* the AI can click, type, read state, and record screenshots of the live application/forms. It does all this with no human at the keyboard.

For full overview, demos & tool reference see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**



## Requirements

- Delphi 11 Alexandria, 12 Athens or 13 Florence.
- Targets: Windows 32/64 bit (VCL and FMX) and Android (FMX).
- An AI assistant that speaks MCP: Claude Code, Kai, Claude Desktop, Cursor, Cline.

## Quick start


### Step 1 — Register the MCP server into your Claude

In Claude Code this is one command:

```
claude mcp add autopilot -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe
```

Write the real full path of that EXE on your disk. Restart the assistant if it was already running. It now has thirteen new tools, all prefixed `autopilot`.

**Register it only where you need it.** Without `--scope`, as above, the server loads only in that project, so a session that never drives a Delphi app pays nothing for it. On the author's machine, moving two machine-wide registrations to this setup took 3,604 characters out of every session that does not drive a Delphi app. One catch: when the project is not a git repository, Claude Code finds such a registration only when the session starts in that exact folder, not in its subfolders. To cover every project and every subfolder at once, register it from the folder that holds all your projects with `claude mcp add autopilot --scope project -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe`. That writes a `.mcp.json` file there, which Claude Code finds from any folder below. It asks you to approve that server; to approve it once for every folder, add `"enabledMcpjsonServers": ["autopilot"]` to `C:\Users\<you>\.claude\settings.json`.

### Step 3 — Now use it

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
- **No tools named `autopilot` in the assistant.** Step 1 did not take effect. Check the path in `claude mcp add` and restart the assistant. If you started the assistant in a subfolder of a project that is not a git repository, use the `.mcp.json` registration described in step 1.
- **Both the app and the server must run as the same Windows user.** The communication channel is locked to the account that created it.

## License

One license, the [SciVance Software License 3.1](LICENSE). Every developer needs a seat:

- **Personal use - free seat** (study, research, hobby - done by you for yourself, not for any organization). Register once at <https://www.GabrielMoraru.com/autopilot>. No key, no activation.
- **Commercial use, or any use by or for an organization - paid seat** (companies, government, charities, schools, universities, public research / health / safety organizations), one per developer. Price and how to buy: <https://www.GabrielMoraru.com/autopilot>. Terms: [LICENSE](LICENSE).

Both seats forbid redistributing the software and decompiling `Autopilot.Mcp.exe`, also through an AI agent acting for you.

**No redistribution, under either tier.** Use it, change it for yourself, and build it into your own application for your own use. You may ship your application freely only when it is built without the `AUTOPILOT` define (the bridge is then inactive). Giving anyone, customers included, a build with the bridge active needs a separate distribution license, bought from the licensor. Handing the code itself to anyone else is not allowed: not the source, not the `.dcu` files, not a changed copy, not folded into a library, component set, template or sample project. Exact wording: [LICENSE](LICENSE) → *Distribution*.

The bridge is source-available, not open source. The server ships as a ready-made EXE.

## Future plans

Support for Mac.

## ⭐ Star this project

I give priority to my GitHub projects based on the number of stars they get. If you like this project, please star it — it tells me to keep working on it.

## What's new

See [WHATS-NEW.md](WHATS-NEW.md).
