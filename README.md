# Autopilot for Delphi

**There is a big gap between Claude and your Delphi app. Autopilot closes it.**

You already work hand in hand with an AI assistant: you give a prompt, Claude writes the code and compiles it. And then it stops dead. It cannot test/debug the program for you. If your program has an OK button, you have to click it. The AI can’t.

Everything past “compile” is on the far side of a chasm. The AI needs you at the keyboard to push the buttons and report back.

What if magic exists? What if without adding a single line of code to your project you can remove that gap? 

The full description on: **[GabrielMoraru.com/autopilot](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)**.

![Autopilot for Delphi closes the gap between the AI and your running Delphi app](https://gabrielmoraru.com/wp-content/uploads/2026/10/Logo-Autopilot-Closes-the-Gap-small-robots2-768x429.jpg)

## How to install it

Clone this repository to a folder, then ask your AI assistant to install the MCP server from that folder.
The AI builds it, registers it and tells you when to restart it.
Step by step, with the exact prompt: **[How to install it](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)**.


## How to use it

**Demo app:** open `DemoVCL\Autopilot.Demo.dproj` and run it.
Then ask your AI assistant: *"List the controls of Autopilot.Demo app, then click btnIncrement five times and read lblCounter and confirm it shows the correct answer."*

**Your own app:** ask the AI to wire Autopilot into your project, then talk to it about your app in plain words:

> *"Start my app, type 'Gabriel' in the name field, press Save, and tell me what the status label says."*

**Repeatable GUI tests, with no AI:** your DUnitX tests start the app, click, type, read the labels and check the result with `Assert`.
No AI and no tokens, so the tests run on every build.
See [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/).

The full description on: **[GabrielMoraru.com/autopilot](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)**.

## Supported platforms

- Delphi: Rio, Alexandria, Athens and Florence. Users report that it works on Delphi 10.2 too.
- Platforms: Win32, Win64 (VCL and FMX), Android (FMX). Mac to be added soon.
- An AI assistant that speaks MCP: Claude Code, Kai, Claude Desktop, Cursor, Cline.
- No third-party dependencies.


## Related topics

* [How does it compare with Embarcadero Kai?](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#kai)
* [How it works](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#how-it-works)
* [The tools the AI calls](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#tools)
* [Native OS dialogs](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#native-dialogs)
* [What it deliberately doesn't do](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#limits)
* [Found a bug?](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-details/#found-a-bug)
* [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/)
* [What's new](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi-whats-new/)
* [License](LICENSE)

## Your support

Did Autopilot change your life? (I know, you are not the first one to say that 😊)   
Give it a star on GitHub.

![Even the AI knows which button to click: give Autopilot for Delphi a star](Resources/Star%20bringer.jpg)
