# Autopilot for Delphi

An AI assistant can already write and compile your Delphi code — but it cannot push the buttons. 
**Autopilot for Delphi** hands the controls of your running **VCL** or **FMX** app (supports Android) to the AI: it clicks, types, reads state, and screenshots the live form over [MCP](https://modelcontextprotocol.io). 

The assistant runs the whole open-click-check-fix-recompile loop on its own — no human at the keyboard.



For full overview, demos, tool reference & quick start see **[www.GabrielMoraru.com/autopilot](https://www.GabrielMoraru.com/autopilot)**


## Native OS dialogs

A `TForm.ShowModal` dialog is an ordinary VCL/FMX form, so the component tools (`click`, `set_text`, …) drive it directly. A native OS dialog — `Application.MessageBox`, the Vista Task Dialog behind a default `ShowMessage`/`MessageDlg`, a common file dialog — is a raw Win32 window with no `TComponent`, so those tools cannot see it and return `not_found`. The `dismiss_dialog` tool reaches it through Win32 instead: it lists the dialogs that are up and dismisses one by clicking a button (by role, caption, or control id). A visible modal dialog runs a message loop, so the bridge still reaches the main thread to act even while the app looks blocked.

| Popup | How the AI drives it |
| --- | --- |
| Your own `TForm.ShowModal` | Component tools — it is in `Screen.Forms[]` |
| `ShowMessage` / `MessageDlg` in a VCL-styled app | Component tools — it renders as a `TForm` |
| `ShowMessage` / `MessageDlg`, default (native Task Dialog) | `dismiss_dialog` |
| `Application.MessageBox`, `TOpenDialog` / `TSaveDialog` | `dismiss_dialog` |

Windows targets only; against an Android FMX target `dismiss_dialog` reports `supported:false`.

## Future plans  
Support for Mac.
Star this repository if you like it. I set priorities to my repositories based on their accumulated stars. 
