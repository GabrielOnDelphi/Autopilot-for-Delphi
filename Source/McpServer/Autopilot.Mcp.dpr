PROGRAM Autopilot.Mcp;

(*=====================================================
   2026.05.19
   Autopilot MCP server.

   Stdio-only JSON-RPC translator between Claude Code and the bridge running
   inside a Delphi target app. Claude Code spawns this exe, pipes JSON-RPC
   over stdin/stdout. Each tool call resolves to a single named-pipe round-trip
   to the target's bridge.

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
     screenshot     - capture the main form as a base64 PNG

   No HTTP transport, no settings.ini. The previous version embedded the
   GDKsoftware/Delphi-MCP-Server vendor stack — replaced 2026-05-19 by our
   own minimal MCP units under Mcp\.
=====================================================*)

{$APPTYPE CONSOLE}

USES
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
  Autopilot.Mcp.PipeClient     in '..\Common\Autopilot.Mcp.PipeClient.pas',
  Autopilot.Mcp.SocketClient   in '..\Common\Autopilot.Mcp.SocketClient.pas',
  Autopilot.Mcp.AdbForward     in '..\Common\Autopilot.Mcp.AdbForward.pas',
  Autopilot.Mcp.TargetMode     in 'Autopilot.Mcp.TargetMode.pas',
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
  Autopilot.Mcp.Tool.SetKeepAwake in 'Autopilot.Mcp.Tool.SetKeepAwake.pas';


BEGIN
  ReportMemoryLeaksOnShutdown := TRUE;
  IsMultiThread := TRUE;

  BridgeLogInfo('mcp', 'server starting (stdio) v' + BridgeVersion);

  // Transport selection. No flag → Windows named-pipe path (unchanged). The
  // `--target adb:<hostPort>` flag routes every command over a loopback socket
  // that `adb forward` has tunnelled to an Android target's bridge. NOTE: the
  // server does NOT run `adb forward` itself yet — the device-side endpoint spec
  // (tcp vs localabstract) is a Phase-B decision (the device bridge isn't
  // listening until then). For now the operator runs `adb forward` out-of-band;
  // Autopilot.Mcp.AdbForward provides the helper for the Phase-B wiring. See
  // " Plans\05_AndroidTransport.md".
  if ParseTargetModeFromCmdLine then
    BridgeLogInfo('mcp', 'target mode = adb-socket, host port ' + IntToStr(AdbHostPort))
  else
    BridgeLogInfo('mcp', 'target mode = named-pipe (default)');

  TRY
    RunStdioServer;
  EXCEPT
    ON E: Exception DO
      BridgeLogError('mcp', 'fatal: ' + E.ClassName + ': ' + E.Message);
  END;
  BridgeLogInfo('mcp', 'server stopped');
END.
