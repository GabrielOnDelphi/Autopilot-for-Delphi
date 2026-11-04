[![Autopilot for Delphi closes the gap between the AI and your running Delphi app](https://gabrielmoraru.com/wp-content/uploads/2026/10/Logo-Autopilot-Closes-the-Gap-small-robots2-768x429.jpg)](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)

# Autopilot for Delphi

**There is a big gap between Claude and your Delphi app. Autopilot closes it.**

You already work hand in hand with an AI assistant: you give a prompt, the AI writes the code and compiles it. And then it stops dead. It cannot test the program for you. If your program has an OK button, you have to click it. The AI can’t.

Everything past “compile” is on the far side of a chasm. The AI needs you at the keyboard to push the buttons and report back.

What if magic exists? What if the AI could push the buttons itself, without a single change to your forms or your business code?

Autopilot hands the controls of your running VCL/FMX app to the AI. The AI clicks the buttons, types into the edit boxes, reads the labels, reads and changes any published property, and takes screenshots.
It all happens in the background: Autopilot never moves your mouse, so you keep working while the AI tests your app.

Full description: **[GabrielMoraru.com/autopilot](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/)**.


## How to install it

1. Download this repository to a folder.
2. Ask your AI to register the MCP server from that folder using [this prompt](https://gabrielmoraru.com/my-delphi-code/autopilot-for-delphi/).
3. That's it.


## How to use it

**Demos:**  
Ask the AI to run `DemoVCL\Autopilot.Demo.dproj`.
Then ask it: *"List the controls of the Demo app, then click btnIncrement five times and confirm lblIncrement shows the correct answer (5)."*

**Your own app:**   
Ask the AI to wire Autopilot into your project.
Then talk to the AI about your app in plain words:

> *"Start my app, type 'Magic' in the name field, press Save, and tell me what the status label says."*

**Repeatable GUI tests, with no AI:**   
Your DUnitX tests start the app, click, type, read the labels and check the result with `Assert`.
No AI/no tokens required.
Sample: `DemoVCL\UnitTesting\Autopilot.DemoTests.dproj`.
See [Automated GUI testing in Delphi](https://gabrielmoraru.com/my-delphi-code/automated-gui-testing-delphi/).


## Supported platforms

- Delphi: 10.3 Rio, 11 Alexandria, 12 Athens and 13 Florence. Users report that it works on Delphi 10.2 too.
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
