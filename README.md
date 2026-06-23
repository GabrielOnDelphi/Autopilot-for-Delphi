# Autopilot for Delphi

> Autopilot for Delphi is in pre-release development — no public build, no purchase link, pricing not final. Feature-complete in testing, but not shipped. The dates and "buy" links below are placeholders until launch.


Today an AI assistant can write your Delphi code and even compile it — but then it stops, because it cannot push the buttons. It needs a human at the keyboard to run the app, click around, and report back whether the GUI actually works. Autopilot for Delphi hands those controls to the AI: it drives and operates your running app directly.

With the controls in hand, the assistant runs the whole loop on its own: open the app, click a button, read the result, take a screenshot, compare it against what it expected — and if something is wrong, change the code, recompile, and try again. You can hand it a goal and walk away.

Full control of your running app unlocks several things:

- **End-to-end AI automation.** Give it one big prompt, leave the computer running, and come back to a GUI app that is built, clicked-through, and working.
- **GUI testing without a recorder.** The assistant drives the form like a tester would — click, type, check state, repeat — and reports what it found.
- **AI-driven debugging.** "The Next button does not work." The assistant runs your app, presses the button, watches the page indicator advance, and tells you what really happens — while you drink your coffee.

It connects an AI coding assistant (Claude Code, or any [MCP](https://modelcontextprotocol.io)-aware host) to a running Delphi **VCL** or **FMX** application: the AI sees your form's real component tree, acts on it, and observes the results — the same loop a human operator runs, driven entirely by the assistant. No IDE plugin, no changes to your app's logic.

It is **not** an end-user GUI test recorder. It is a typed set of MCP tools that an AI calls from a chat session to take full control of your running app.

---

## How it works (one screen)

```
+-------------------------+         stdio JSON-RPC         +--------------------------+
|  AI host (Claude Code,  |  <-------------------------->  |  Autopilot.Mcp.exe       |
|  Claude Desktop, Cursor,|         (Model Context         |  (the MCP server we ship) |
|  Cline, ...)            |          Protocol)             |                          |
|  - calls MCP tools      |                                |                          |
+-------------------------+                                +-----------+--------------+
                                                                       |
                                                                       |  Windows named pipe
                                                                       |  \\.\pipe\Autopilot.<exe>.<pid>
                                                                       v
                                                          +------------------------------+
                                                          |  Your Delphi application     |
                                                          |  (debug build, links in      |
                                                          |   Autopilot.Bridge unit)    |
                                                          |                              |
                                                          |  - Worker thread: pipe I/O   |
                                                          |  - Dispatch via TThread.Queue|
                                                          |  - RTTI: read/write any      |
                                                          |    published property        |
                                                          +------------------------------+
```

Three processes, two hops: the AI ↔ our MCP server ↔ your Delphi app. The two-hop design exists because the AI's MCP server is a short-lived child process while your Delphi app runs for hours across many debug sessions — decoupling them via a named pipe lets either restart without breaking the other.

---

## Autopilot vs. an in-IDE AI like Embarcadero Kai

People ask whether this is the same as [Embarcadero Kai](https://www.embarcadero.com/products/rad-studio/kai) (the agentic AI add-on for RAD Studio). It is not — the two solve different halves of the job, and they work well **together**.

|                                        | Kai | Autopilot |
| -------------------------------------- |:---:|:---------:|
| Write code in the IDE                  | yes | no        |
| Build, fix compiler errors             | yes | no        |
| **Run and operate** the finished app   | no  | yes       |
| Test the GUI (click, type, read state) | no  | yes       |
| Screenshot the running app             | no  | yes       |

Kai works **inside the IDE, on your source code** — it writes, compiles, and fixes compiler errors. The moment the app is built and running, it stops: it cannot press a button or read a label, so a human still has to check the GUI actually works.

Autopilot starts exactly there. It lets the AI **operate the running app the way a user would** — press the real buttons, type into the real edit boxes, read the labels back, take a screenshot. Two things follow:

- **It tests the GUI end-to-end without you watching** — click through a form, verify the result, report what broke.
- **It uses the app to get work done.** If your app were an email client like Thunderbird, the AI could answer customers, search contacts, build templates, harvest addresses — driving your own application, not a copy of it.

Run both: Kai writes and fixes the code; Autopilot runs the result and tells the AI whether it truly works. The loop closes with no human in the middle.

---

## Quick start

Add **one unit** and **one call** to your Delphi project:

```delphi
program MyApp;

uses
  Vcl.Forms,
  Autopilot.Bridge.Vcl,        // <-- 1. add the unit (use Autopilot.Bridge.Fmx for FireMonkey)
  FormMain in 'FormMain.pas' {frmMain};

begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Autopilot.Bridge.Vcl.StartBridge;    // <-- 2. start the bridge
  Application.Run;
end.
```

Add **`AUTOPILOT`** to your Debug build's conditional defines (Project Options → Building → Delphi Compiler → Conditional defines). Release builds without the define compile `StartBridge` as a no-op — no thread, no pipe, no automation tools in production. Your release binaries are exactly as they were.

Then register the MCP server with your AI host. On Claude Code:

```cmd
claude mcp add autopilot -- "C:\Path\To\Autopilot.Mcp.exe"
```

The MCP server auto-discovers your running app via a discovery file in `%TEMP%\Autopilot\active\`. No port to configure, no manual attach.

---

## What you can do

Twelve MCP tools the AI calls into:

| Tool             | Purpose                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `list_tree`      | Enumerate every form and control. Returns names, classes, paths, text, enabled/visible state.                                                                                                                                                                                                                                                                                               |
| `click`          | Click a button (or any control with `OnClick`). Optional `count=N` for repetition.                                                                                                                                                                                                                                                                                                          |
| `execute_action` | Fire a `TAction`'s `OnExecute` directly — for shortcut-only actions and actions shared by several controls. For plain controls use `click`.                                                                                                                                                                                                                                                 |
| `get_text`       | Read `Caption` / `Text` / `Lines.Text`.                                                                                                                                                                                                                                                                                                                                            |
| `set_text`       | Write text into edits, memos, labels. Fires `OnChange`.                                                                                                                                                                                                                                                                                                                                     |
| `set_checked`    | Toggle a checkbox / radio. Fires `OnChange`.                                                                                                                                                                                                                                                                                                                                                |
| `set_property`   | **The Swiss army knife.** Write any published, writable property — `Tag`, `Color`, `Position`, `BorderStyle`, `ItemIndex`, `BevelEdges` (sets), `Font.Size` (one-level dotted writes), AI-friendly color values (`'clRed'` / `'#FF8000'` / `'claSkyBlue'`). On typos returns the full list of writable properties with their live values — the AI self-corrects without another round-trip. |
| `read_property`  | Read any readable published property. Companion to `set_property` — returned string is exactly what `set_property` would accept back.                                                                                                                                                                                                                                              |
| `wait_for`       | Poll a property until it matches a predicate or times out — for async work (`TTask`, database queries, timers).                                                                                                                                                                                                                                                                             |
| `screenshot`     | Capture the form as a PNG. For visual/layout debugging only — `get_text` is much cheaper for state checks.                                                                                                                                                                                                                                                                                  |
| `attach`         | Manual attach when multiple targets are running. Usually unnecessary — every tool auto-attaches.                                                                                                                                                                                                                                                                                            |
| `set_keep_awake` | Keep the device screen on while driving (Android — sets `FLAG_KEEP_SCREEN_ON`, on by default; prevents the OS screen-off app freeze). No-op on Windows targets.                                                                                                                                                                                                                             |

VCL and FMX bridges in the box. Tested against Delphi 13.1 (Florence). DCUs for every supported Delphi version included.

---

## What's inside the box

| Path                                                              | Contents                                                                                                                                                                                                                                                                |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Source\Bridge\Autopilot.Bridge.Vcl.dcu` (one per Delphi version) | The unit you link into your VCL app.                                                                                                                                                                                                                                    |
| `Source\Bridge\Autopilot.Bridge.Fmx.dcu` (one per Delphi version) | The FireMonkey equivalent.                                                                                                                                                                                                                                              |
| `Source\McpServer\Autopilot.Mcp.exe`                              | Pre-built x64 MCP server EXE. Register once with your AI host.                                                                                                                                                                                                          |
| `DemoVCL\Autopilot.Demo.exe`                                      | Working VCL demo — `btnIncrement`, `lblCounter`, `edtName`, `lblNameEcho`. Drive it from an AI session in five minutes.                                                                                                                                                 |
| `DemoFmx\Autopilot.DemoFmx.exe`                                   | Same shape, FMX.                                                                                                                                                                                                                                                        |
| `AI-INSTRUCTIONS.md`                                              | **Brief your AI session with this.** Link it from your project's `CLAUDE.md` (or equivalent) so AI sessions opened in your project know how to drive your app efficiently. Covers tool reference, efficiency rules (minimize turns!), error envelope, decision recipes. |
| `README.md` (this file)                                           | Customer overview.                                                                                                                                                                                                                                                      |

---

## A typical session (what it looks like)

```
You:    Start my app. The customer says btnSave hangs after typing a long name.
        Reproduce.

AI:     [list_tree, no PID, single target auto-attaches → returns frmMain + 30 children]
AI:     [set_text frmMain.edtName="Aaaaaaa...aaa" (250 chars)]
AI:     [click frmMain.btnSave]
AI:     [wait_for frmMain.lblStatus equals "saved" timeoutMs=3000]
AI:     wait_for timed out after 3000 ms. lblStatus shows "Saving...". I see frmMain.btnSave
        is now Enabled=False. The handler is queued on something but never resolves.
        Looking at the OnClick handler in FormMain.pas line 312...
```

That whole sequence is one AI turn with four parallel tool calls, plus the AI reading your source code. No human in the loop.

---

## What this product deliberately does NOT do

This bridge acts **directly on Delphi objects**. It does **not** synthesize Windows input. Bugs that only reproduce through the real input pipeline are not testable through it:

- Focus-change-driven validation (`OnExit`, `EN_KILLFOCUS`)
- IME composition and Asian-language input
- Keyboard accelerators routed via `WM_KEYDOWN` → `IsDialogMessage`
- Hover-driven UI (`CM_MOUSEENTER`)
- Drag-drop initiated from a real mouse-down + mouse-move sequence

`mode='message'` on `click` bridges the gap for buttons (uses `BM_CLICK`). For full input-pipeline coverage, you want a `SendInput`-based tool (TestComplete, Ranorex, AutoIt).

In return for that limitation you get: **direct property access**, no OCR, no coordinate fragility, sub-millisecond round-trips, works with any third-party control pack (DevExpress, TMS, …) because RTTI is universal.


---

## Supported Delphi versions

Initial release: Delphi 11 Alexandria, 12 Athens, 13 Florence.

10.4 Sydney support tracked for a 1.1 release. Earlier versions on request.

---

## Brief your AI session

If you're using an AI coding assistant in this project, add one line to your project's CLAUDE.md (or AGENTS.md / .cursorrules / whatever your host reads):

> See `AI-INSTRUCTIONS.md` for how to drive this application via the Autopilot for Delphi MCP server.

That document covers: the twelve tools, efficiency rules (minimize turns!), how the AI should bundle parallel tool calls in one turn, when to use `click(count=N)`, when `screenshot` is justified, the error envelope, and how to self-discover the set of writable properties in one round-trip. Read once at the start of a session; you do not need to re-read.

---

## License

Autopilot for Delphi is **dual-licensed — free for noncommercial use, paid for commercial use**:

- **Noncommercial use is free** — personal projects, study, research, hobby work, and use by charities, schools, and government — under the [PolyForm Noncommercial License 1.0.0](LICENSE).
- **Commercial use requires a paid license** — any use by or for a business, or with an anticipated commercial application. **$25/developer, perpetual.** [Buy](https://www.GabrielMoraru.com/autopilot) *(live at launch)* — details in [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md), or email **i@gabrielmoraru.com**.

This is **source-available**, not open source: the noncommercial license restricts commercial use, which an OSI-approved open-source license cannot do.

---

## Issues & support

- Web: www.GabrielMoraru.com

Bug reports welcome. Include the `%TEMP%\Autopilot\<ExeBaseName>-<PID>.log` file from a session that reproduces the issue — it captures every command in/out and dispatch timing.

---

## Credits

- The `TWinControlClass(Control).Click` cast trick for generic click dispatch is borrowed from Delphi's own `Vcl.UIACtrlProvider.pas`.
- No 3rd-party dependencies. Stdlib + Winapi only.
