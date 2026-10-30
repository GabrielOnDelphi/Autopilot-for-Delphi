PROGRAM Autopilot.Mcp;

(*============================================================================================================
   2026.10.30
   GabrielMoraru.com/autopilot
--------------------------------------------------------------------------------------------------------------
   Autopilot MCP server.

   Stdio-only JSON-RPC translator between Claude Code and the bridge running inside a Delphi target app.
   Claude Code spawns this exe, pipes JSON-RPC over stdin/stdout.
   Each tool call resolves to a single named-pipe round-trip to the target's bridge.

   Tools exposed to the AI:
     attach         - list active targets / verify a pid
     list_tree      - enumerate forms+components of the target
     click          - dispatch a click by path (optional count for batched clicks)
     get_text       - read Text/Caption by path
     set_text       - write Text (or Caption) by path
     set_checked    - toggle Checked on a checkbox / radio button by path
     set_property   - write any published property via RTTI
     read_property  - read any readable published property via RTTI
     execute_action - fire a TAction's OnExecute by path (for shortcut-only / shared actions)
     wait_for       - poll a property until it matches a value
     screenshot     - capture a form as a PNG (an MCP image content block + a text block)
     set_keep_awake - keep the device screen on while driving (Android; no-op on Windows)
     dismiss_dialog - list / dismiss native OS dialogs (MessageBox / Task Dialog / file dialogs)

   Command-line parameters, in any order: `--target adb:<port>` (an Android target), `--no-crash-report` (save a crash report, never upload it).
   No HTTP transport, no settings.ini.
   The minimal MCP units under Mcp\ derive from GDKsoftware/Delphi-MCP-Server (MIT, see thirdparty-notices.txt).

   Crash reporting (madExcept) compiles in only with the madshi define. The .dproj sets it only on a PC where
   the madExcept patch script exists, so a PC without madExcept builds the server with no crash reporter.
   The build output goes to Win32_<config>\, never over the published Autopilot.Mcp.exe beside this file.
============================================================================================================*)

{$APPTYPE CONSOLE}
{$R *.res}   // Version resource (SciVance Tech., from the VerInfo keys of the .dproj). A build creates the .res from the .dproj when it is missing.

USES
  {$IFDEF madshi}
  madExcept,                     // Must stay first: its initialization installs the unhandled-exception hook.
  madLinkDisAsm,                 // Disassembles the faulting frames into the report.
  madListModules,                // Lists loaded modules in the report.
  {$ENDIF}
  System.SysUtils,
  Winapi.Windows,
  MCPServer.Types               in 'Mcp\MCPServer.Types.pas',
  MCPServer.Schema.Generator    in 'Mcp\MCPServer.Schema.Generator.pas',
  MCPServer.Serializer          in 'Mcp\MCPServer.Serializer.pas',
  MCPServer.Tool.Base           in 'Mcp\MCPServer.Tool.Base.pas',
  MCPServer.Registration        in 'Mcp\MCPServer.Registration.pas',
  Autopilot.Mcp.JsonRpc        in 'Mcp\Autopilot.Mcp.JsonRpc.pas',
  Autopilot.Mcp.Stdio          in 'Mcp\Autopilot.Mcp.Stdio.pas',
  Autopilot.Bridge.Core        in '..\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.Log         in '..\Bridge\Autopilot.Bridge.Log.pas',
  Autopilot.Mcp.PipeClient     in 'Common\Autopilot.Mcp.PipeClient.pas',
  Autopilot.Mcp.SocketClient   in 'Common\Autopilot.Mcp.SocketClient.pas',
  Autopilot.Mcp.AdbForward     in 'Common\Autopilot.Mcp.AdbForward.pas',
  Autopilot.Mcp.TargetMode     in 'Autopilot.Mcp.TargetMode.pas',
  Autopilot.Mcp.CrashReport    in 'Autopilot.Mcp.CrashReport.pas',
  Autopilot.Mcp.UsageCounter   in 'Autopilot.Mcp.UsageCounter.pas',
  Autopilot.Mcp.ToolBase       in 'Autopilot.Mcp.ToolBase.pas',
  Autopilot.Mcp.Tool.Attach      in 'Autopilot.Mcp.Tool.Attach.pas',
  Autopilot.Mcp.Tool.ListTree    in 'Autopilot.Mcp.Tool.ListTree.pas',
  Autopilot.Mcp.Tool.Click       in 'Autopilot.Mcp.Tool.Click.pas',
  Autopilot.Mcp.Tool.GetText     in 'Autopilot.Mcp.Tool.GetText.pas',
  Autopilot.Mcp.Tool.SetText     in 'Autopilot.Mcp.Tool.SetText.pas',
  Autopilot.Mcp.Tool.SetChecked  in 'Autopilot.Mcp.Tool.SetChecked.pas',
  Autopilot.Mcp.Tool.SetProperty in 'Autopilot.Mcp.Tool.SetProperty.pas',
  Autopilot.Mcp.Tool.ReadProperty in 'Autopilot.Mcp.Tool.ReadProperty.pas',
  Autopilot.Mcp.Tool.ExecuteAction in 'Autopilot.Mcp.Tool.ExecuteAction.pas',
  Autopilot.Mcp.Tool.WaitFor     in 'Autopilot.Mcp.Tool.WaitFor.pas',
  Autopilot.Mcp.Tool.Screenshot  in 'Autopilot.Mcp.Tool.Screenshot.pas',
  Autopilot.Mcp.Tool.SetKeepAwake in 'Autopilot.Mcp.Tool.SetKeepAwake.pas',
  Autopilot.Mcp.Tool.DismissDialog in 'Autopilot.Mcp.Tool.DismissDialog.pas',
  Autopilot.Mcp.Tool.SendKeys in 'Autopilot.Mcp.Tool.SendKeys.pas';


begin
  ReportMemoryLeaksOnShutdown := TRUE;
  IsMultiThread := TRUE;

  {$IFDEF madshi}
  { # Crash reporting }
  // madExcept defaults RequireAuthenticSsl to FALSE (madExcept.pas:1858), which sets
  // SECURITY_FLAG_IGNORE_UNKNOWN_CA / _CERT_CN_INVALID / _CERT_DATE_INVALID (:8886-8889):
  // the upload would be encrypted but not authenticated.
  RequireAuthenticSsl:= TRUE;

  // The crash-report endpoint keeps a server-side allowlist and refuses any product missing
  // from it. These two fields are the key. AdditionalFields is NOT encrypted (madExcept.pas:4095),
  // unlike the password settings, so nothing secret may ever go here.
  MESettings.AdditionalFields['Product']:= 'Autopilot';
  MESettings.AdditionalFields['Version']:= McpServerVersion;
  {$ENDIF}

  BridgeLogInfo('mcp', 'server starting (stdio) v' + McpServerVersion);

  { # Crash report switch }
  // `--no-crash-report`, put by the user into the MCP registration: madExcept saves the crash report to a file
  // beside this log and never uploads it. Without the switch the .mes alone decides, as before.
  // It runs after the first log line because BridgeLogPath is empty until a line is written.
  if NoCrashReportRequested then
    begin
      {$IFDEF madshi}
      // These writes land in the module settings that madExcept holds for the whole run (mySettings,
      // madExcept.pas:19150). The exception object built at crash time has no settings of its own and reads
      // them there (TIMEException.FindProp, madExcept.pas:16078), and the upload is gated on that value
      // (DoExceptionAutoStuff, madExcept.pas:13263).
      MESettings.AutoSend:= FALSE;
      MESettings.AutoSave:= TRUE;
      MESettings.BugReportFile:= NoCrashReportFile(BridgeLogPath);
      BridgeLogInfo('mcp', 'crash report upload is OFF (' + NoCrashReportSwitch + '): a crash report is saved to ' + MESettings.BugReportFile + ' and never sent');
      {$ELSE}
      BridgeLogInfo('mcp', NoCrashReportSwitch + ' given: this build has no crash reporter, so nothing is ever sent');
      {$ENDIF}
    end;

  BridgeLogInfo('license', CommercialLicenseHint);
  TrackUsageAndMaybePromoteBook;

  // Transport selection. No flag: the Windows named-pipe path. The `--target adb:<hostPort>` flag routes
  // every command over a loopback socket that `adb forward` has tunnelled to an Android target's bridge,
  // which listens on the abstract socket Autopilot.<pid> (Autopilot.Bridge.Fmx).
  // The server does not run `adb forward` itself: the device-side name holds the app's process id, which
  // changes on every app start, so automating it would need `adb shell pidof` first. The operator runs
  // `adb forward tcp:<hostPort> localabstract:Autopilot.<pid>` after each app start.
  // Autopilot.Mcp.AdbForward holds a helper for running it from the server; nothing calls it yet.
  if ParseTargetModeFromCmdLine
  then BridgeLogInfo('mcp', 'target mode = adb-socket, host port ' + IntToStr(AdbHostPort))
  else BridgeLogInfo('mcp', 'target mode = named-pipe (default)');

  TRY
    RunStdioServer;
  EXCEPT
    ON E: Exception DO
      begin
        BridgeLogError('mcp', 'fatal: ' + E.ClassName + ': ' + E.Message);
        // Log and RE-RAISE, never swallow. madExcept hooks only UNHANDLED exceptions, so
        // catching one here would make the whole crash-reporting chain dead code - a build
        // that passes every check and reports nothing, forever.
        // RunStdioServer already handles everything survivable inside its own loop (a failed
        // Readln, a dispatcher that escaped, a failed Writeln), so anything arriving here is
        // fatal by construction and there is nothing to continue to.
        RAISE;
      end;
  END;
  BridgeLogInfo('mcp', 'server stopped');
end.
