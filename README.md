# Autopilot for Delphi

**There is a big gap between Claude and your Delphi app. Autopilot closes it.**

An AI assistant can write your Delphi code and compile it, but then it stops: it cannot run the program and click its buttons.
Autopilot for Delphi hands the controls of your running VCL or FMX app to the AI.
The AI can click all controls, type text into edit boxes, read the labels, set and read any property, and take screenshots - the same loop a human operator runs, with no human at the keyboard.
It works in the background and never moves the mouse, so you can keep working while the AI tests.

The full description lives on the website: **[GabrielMoraru.com/autopilot](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)**.
When this file and the website disagree, the website is right.

## How to install it

1. Download or clone this repository to a folder, for example `c:\Autopilot For Delphi\`.
2. Give your AI assistant (Claude, Gemini, etc.) a prompt like this:

   > I have a new MCP server for you in `c:\Autopilot For Delphi\`. Install it as its README.md says.
   > Add this line to your global CLAUDE.md:
   > "To test the GUI of my Delphi programs, use Autopilot. See: c:\Autopilot For Delphi\AI-INSTRUCTIONS.md."
   > Tell me when I must restart you.

3. Restart the AI session when it asks you to, so it can use the new MCP server.

The repository holds the source of the MCP server, not the EXE.
Build it first: open `Source\McpServer\Autopilot.Mcp.dproj` in Delphi and build it (Win32).
The EXE lands in `Source\McpServer\Win32_<config>\`: copy it one folder up, into `Source\McpServer\`, so it finds the bridge folder `Source\Bridge\` beside it.
If you received Autopilot as a ZIP package, it already contains a built `Autopilot.Mcp.exe`: register that one.

To register the MCP server by hand: in Claude Code it is one command (write the real full path of the EXE on your disk).

```
claude mcp add autopilot -- C:\Your\Path\Source\McpServer\Autopilot.Mcp.exe
```

An EXE with madExcept built in sends a crash report to SciVance Tech when it crashes.
To keep the report on your PC instead, add `--no-crash-report` at the end of that command.
A build on a PC without madExcept has no crash reporter, so it never sends a report.

`AI-INSTRUCTIONS.md` is a briefing for the AI, not for you: you write nothing in it.
Without it everything still works, but the AI finds its way more slowly and spends more tokens.

## How to use it

**Demo app:** open `DemoVCL\Autopilot.Demo.dproj` and run it.
Then ask your AI assistant: *"List the controls of Autopilot.Demo app, then click btnIncrement five times and read lblCounter and confirm it shows the correct answer."*

**Your own app:** ask the AI to wire Autopilot into your project, then talk to it about your app in plain words:

> *"Start my app, type 'Gabriel' in the name field, press Save, and tell me what the status label says."*

**Repeatable GUI tests, with no AI:** your DUnitX tests start the app, click, type, read the labels and check the result with `Assert`.
No AI and no tokens, so the tests run on every build.
See [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/).

## Supported platforms

- Delphi: Rio, Alexandria, Athens and Florence. Users report that it works on Delphi 10.2 too.
- Platforms: Win32, Win64 (VCL and FMX), Android (FMX). Mac to be added soon.
- An AI assistant that speaks MCP: Claude Code, Kai, Claude Desktop, Cursor, Cline.
- No third-party dependencies.

## License

Private use is free. Commercial use needs a paid seat per developer.
Read the full terms on the website: [Autopilot for Delphi - License](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-license/) (the same text is in [LICENSE](LICENSE)).

## Related topics

* [How does it compare with Embarcadero Kai?](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#kai)
* [How it works](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#how-it-works)
* [The tools the AI calls](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#tools)
* [Native OS dialogs](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#native-dialogs)
* [What it deliberately doesn't do](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#limits)
* [Found a bug?](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#found-a-bug)
* [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/)
* [What's new in each version](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-whats-new/)
* [Security and privacy](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-security-and-privacy/)

Questions, or something broke? [Write to me](https://gabrielmoraru.com/about-me/).
If Autopilot is useful to you, give it a star on GitHub.

![Even the AI knows which button to click: give Autopilot for Delphi a star](DemoVCL/star_bringer.jpg)
