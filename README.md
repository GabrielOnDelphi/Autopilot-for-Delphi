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

For details see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**

### Step 2 — Now use it

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

## License

One license, the [SciVance Software License 3.1](LICENSE). Every developer needs a seat:

- **Personal use - free seat** (study, research, hobby - done by you for yourself, not for any organization). Register once at <https://www.GabrielMoraru.com/autopilot>. No key/activation needed.
- **Commercial use, or any use by or for an organization - paid seat** (companies, government, charities, schools, universities, public research / health / safety organizations), one per developer. Price and how to buy: <https://www.GabrielMoraru.com/autopilot>. Terms: [LICENSE](LICENSE).


## Future plans

Support for Mac.

## ⭐ Star this project

I give priority to my GitHub projects based on the number of stars they get. If you like this project, please star it — it tells me to keep working on it.

## What's new

See [Autopilot for Delphi - What's New](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-whats-new/).
