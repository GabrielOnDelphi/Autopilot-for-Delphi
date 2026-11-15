# Autopilot inside the Delphi IDE - install note

## What the package does

`Autopilot.IdeBridge` is a design-time package that loads the Autopilot VCL bridge into the Delphi IDE itself (`bds.exe`).
The IDE calls the package's `Register` routine at start, and `Register` calls `StartBridge`, then registers four IDE commands (section "IDE commands (call_method)").
From then on the Autopilot MCP tools drive the IDE the same way they drive your own application: they read the IDE's forms, click its buttons, run its actions and take screenshots.
A design-time package shares the VCL with the IDE, so `list_tree` shows the IDE's own forms (`AppBuilder` is the main window, then `PropertyInspector`, `ProjectManagerForm`, `MessageViewForm` and the rest).

## Requirements

- Delphi 13.
  Tested on `bds.exe` 37.0.60952.8797 (the 32-bit IDE), with the Win32 Debug build of this package.
  Other IDE versions were not tested.
- The Autopilot MCP server, registered with your AI host (see `README.md` at the root of this repository).
- This repository as it is: the package compiles the bridge units from `..\Bridge\` (the folder `Source\Bridge\`), by relative path.

The package contains these units:

- `Autopilot.IdeBridge.Register` and `Autopilot.IdeBridge.Commands` (this folder; the second one holds the IDE commands)
- `Autopilot.Bridge.Core`, `Autopilot.Bridge.Log`, `Autopilot.Bridge.Transport`, `Autopilot.Bridge.NamedPipe`, `Autopilot.Bridge.NativeDialogs`, `Autopilot.Bridge.Worker`, `Autopilot.Bridge.Vcl`, `Autopilot.Bridge.Commands` (from `Source\Bridge\`; the last one holds the list of commands that an app registers)

It requires the packages `rtl`, `vcl`, `vclimg` and `designide`, and it is design-time only (`{$DESIGNONLY}`).

The bridge does nothing unless the symbol `AUTOPILOT` is defined.
`Autopilot.IdeBridge.dproj` defines `AUTOPILOT` in its base configuration, so every build of this package (Debug and Release) has a live bridge.

## Security - read this before you install

While the package is loaded, any program that runs under your Windows user account can drive the IDE through the bridge's named pipe.
The pipe accepts only your own user account, not other users of the PC, but every program you run is your own user account.
Such a program can click menu items, run any IDE action (build, run, save, close), open and build projects, change properties and type keys into the editor.

So install the package only into a separate test registry root (next section), never into the IDE you use every day.
Remove it when you no longer need it.

## Install into a test registry root

A registry root is the registry key under which the IDE keeps all its settings, including the list of installed packages ("Known Packages").
The command-line switch `-r<name>` starts the IDE with its own root, so your normal IDE settings and packages stay untouched.

1. Start the IDE with a test root.
   `bds.exe` is in the `bin` folder of your Delphi installation.

   ```
   bds.exe -pDelphi -rAutopilotTest
   ```

   A new root is copied from your normal settings at its first start, and the IDE shows its first-start wizard once.
   Finish the wizard.

2. Build the package.
   Open `Source\IdeBridge\Autopilot.IdeBridge.dproj`, select the platform Win32 and the configuration Debug, and build.
   The output is `Source\IdeBridge\Win32\Debug\Autopilot.IdeBridge370.bpl` (the IDE adds the suffix `370` through `{$LIBSUFFIX AUTO}`).

3. Install the package.
   Component > Install Packages > Add, and select `Autopilot.IdeBridge370.bpl` from `Source\IdeBridge\Win32\Debug\`.
   The package shows in the list as "Autopilot for Delphi - bridge inside the IDE".

The bridge starts as soon as the IDE loads the package, and at every later start of an IDE with the same root.

## Check that it works

1. Wait about 6 seconds after the package loads.
   The bridge then writes its discovery file to `%TEMP%\Autopilot\active\<pid>.pipe`, and its pipe is `\\.\pipe\Autopilot.bds.<pid>` (`<pid>` is the process id of `bds.exe`).
2. Call the MCP tool `attach`.
   `attach` finds the IDE (the process `bds.exe`).
   When other Autopilot targets run at the same time, pass the pid of `bds.exe` to `attach`.
3. Call `call_method` without a name.
   The answer lists the four `ide.` commands.
4. Call `list_tree` with `formsOnly`, to get only the form nodes.
   Then call `list_tree` with `form` for the one form you need.

Never call `list_tree` on the IDE without these arguments: the whole tree is about 580 KB (3,503 components in 41 forms, measured on one IDE with some experts installed).
Sizes measured on the same IDE with one project open:

| Call | Size |
|---|---|
| `list_tree` with `formsOnly` | 42 form nodes, 7.0 KB |
| `list_tree` with `form` = `MessageViewForm` | 11 KB |
| `list_tree` with `form` = `ProjectManagerForm` | 31.8 KB |
| `list_tree` with `form` = `AppBuilder` | about 208 KB |

So never list `AppBuilder` (the main window) whole.

## IDE commands (call_method)

The MCP tool `call_method` runs a command that the app registered by name; without a name, it lists the registered commands with their descriptions.
Only a registered command can be called: no other routine of the IDE is reachable through `call_method`.
The package registers these four commands, through the Open Tools API (the IDE's own interface for packages):

| Command | Arguments | Answer |
|---|---|---|
| `ide.activeProject` | none | `fileName` (`null` when no project is open), `configuration`, `platform`, `frameworkType` |
| `ide.openProject` | `fileName`: the full path of a project or project group | `opened` (Boolean) and `activeProject`; the project opens in a new project group, and the IDE may ask to save the current one |
| `ide.build` | `mode`: `make` or `build` (default `make`) | `succeeded` (Boolean), `mode`, `project`; it compiles the active project with its current configuration and platform |
| `ide.messageGroups` | none | `groups`: the names of the tabs of the Messages view, for example `["Build","Output"]` |

Measured answers:

- `ide.activeProject` with no project open answered `{"fileName":null}`.
- `ide.openProject` of a file that does not exist answered `-32603` with `EFileNotFoundException`.
- `ide.openProject` of a console project (with `timeoutMs` 60000) answered `opened:true` in 1154 ms.
- `ide.build` with `mode` = `build` answered `succeeded:true` in 416 ms; with `mode` = `make`, in 89 ms.
- `ide.build` with `mode` = `bogus` answered `-32603 EArgumentException: ide.build args.mode must be make or build (got bogus)`.
- An unknown command name answered `-32001`, and the message lists the four names.

A build can take long: give `call_method` a `timeoutMs` such as 120000.

**`ide.build` cannot return the error lines of a build.**
The Open Tools API has no routine that reads the text of the Messages view, and no error, warning or hint count.
So `ide.build` returns only `succeeded`.

**A failed build answers `-32004`, and the Compiling dialog stays open.**
Measured with the Compiling dialog on: `ide.build` waited for the whole `timeoutMs`, then answered `-32004 main thread did not respond within <timeoutMs> ms`.
The dialog (`ProgressForm`) then shows the counts.
Read them with `get_text`: `ProgressForm.Action` (`Failed`), `ProgressForm.ErrorCount`, `ProgressForm.WarningCount`, `ProgressForm.HintCount`.
Then close the dialog with `click ProgressForm.CancelButton` and `mode=message`.
Not tested: a failed build with the Compiling dialog off (IDE option "Show compiler progress").

## What works and what does not

- **`execute_action` of a build command answers with a timeout, and that is expected.**
  The IDE builds inside a modal "Compiling" dialog, so `execute_action` of a build command (for example `AppBuilder.ProjectBuildCommand`) answers `-32004 main thread did not respond within 5000 ms` while the build runs.
  The build goes on.
  While the Compiling dialog (`ProgressForm`) stays open after the build, `get_text` and `read_property` can read it (`ProgressForm.Action` reads `Success`).
  Prefer `ide.build`: a successful build answers `succeeded:true` and does not wait for the dialog.
- **Use `click` with `mode=message` on a dialog of the IDE.**
  It reaches the dialog without taking the keyboard focus, and the answer comes back before the click runs, so a modal dialog does not block the call.
- **The Messages view cannot be read with `get_text`.**
  Its list is a virtual tree (`TBetterHintWindowVirtualDrawTree`), and `get_text` cannot read its lines.
  Use `screenshot` of `MessageViewForm` instead.
  If the Messages view is hidden in your layout, open it first with `execute_action MessageViewForm.ViewMessagesCommand`.
- **A clean close of the IDE stops the bridge.**
  When the package unloads, `StopBridge` runs and deletes the discovery file, and the four IDE commands are removed.

## Uninstall

Close every IDE that uses the test root first.
Then do one of these:

- Start the IDE with `-rAutopilotTest`, open Component > Install Packages, select "Autopilot for Delphi - bridge inside the IDE" and click Remove.
- Delete the whole test root.
  This removes the package and every other setting of that root, and your normal IDE settings stay untouched.

  ```
  reg delete "HKCU\Software\Embarcadero\AutopilotTest" /f
  ```
