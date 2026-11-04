PROGRAM TestsMcp;

{=====================================================
   2026.10.30
   Autopilot — MCP server test suite (PRIVATE)

   Tests the MCP server units in Source\McpServer\. A separate runner beside Tests\Tests.dpr (the bridge and
   client suite); the two suites together are the whole suite.
   Console-mode DUnitX runner. No LightSaber dependency.
=====================================================}

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

USES
  {$IFDEF DEBUG}
  FastMM4,  { Must be the first unit: FastMM4 does not install once another unit has allocated memory. Leaks go to <exe>_MemoryManager_EventLog.txt (C:\Delphi\FastMM\FastMM4Options.inc). }
  {$ENDIF}
  System.SysUtils,
  System.IOUtils,
  Winapi.Windows,
  Vcl.Forms,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Autopilot.Bridge.Core      in '..\..\Source\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.Log       in '..\..\Source\Bridge\Autopilot.Bridge.Log.pas',
  MCPServer.Types             in '..\..\Source\McpServer\Mcp\MCPServer.Types.pas',
  MCPServer.Schema.Generator  in '..\..\Source\McpServer\Mcp\MCPServer.Schema.Generator.pas',
  MCPServer.Serializer        in '..\..\Source\McpServer\Mcp\MCPServer.Serializer.pas',
  MCPServer.Tool.Base         in '..\..\Source\McpServer\Mcp\MCPServer.Tool.Base.pas',
  MCPServer.Registration      in '..\..\Source\McpServer\Mcp\MCPServer.Registration.pas',
  Autopilot.Mcp.JsonRpc      in '..\..\Source\McpServer\Mcp\Autopilot.Mcp.JsonRpc.pas',
  Autopilot.Mcp.Stdio        in '..\..\Source\McpServer\Mcp\Autopilot.Mcp.Stdio.pas',
  Autopilot.Mcp.SocketClient in '..\..\Source\McpServer\Common\Autopilot.Mcp.SocketClient.pas',
  Autopilot.Mcp.PipeClient   in '..\..\Source\McpServer\Common\Autopilot.Mcp.PipeClient.pas',
  Autopilot.Mcp.TargetMode   in '..\..\Source\McpServer\Autopilot.Mcp.TargetMode.pas',
  Autopilot.Mcp.CrashReport  in '..\..\Source\McpServer\Autopilot.Mcp.CrashReport.pas',
  Autopilot.Mcp.ToolBase     in '..\..\Source\McpServer\Autopilot.Mcp.ToolBase.pas',
  Autopilot.Mcp.Tool.Attach        in '..\..\Source\McpServer\Autopilot.Mcp.Tool.Attach.pas',
  Autopilot.Mcp.Tool.ListTree      in '..\..\Source\McpServer\Autopilot.Mcp.Tool.ListTree.pas',
  Autopilot.Mcp.Tool.Click         in '..\..\Source\McpServer\Autopilot.Mcp.Tool.Click.pas',
  Autopilot.Mcp.Tool.GetText       in '..\..\Source\McpServer\Autopilot.Mcp.Tool.GetText.pas',
  Autopilot.Mcp.Tool.SetText       in '..\..\Source\McpServer\Autopilot.Mcp.Tool.SetText.pas',
  Autopilot.Mcp.Tool.SetChecked    in '..\..\Source\McpServer\Autopilot.Mcp.Tool.SetChecked.pas',
  Autopilot.Mcp.Tool.SetProperty   in '..\..\Source\McpServer\Autopilot.Mcp.Tool.SetProperty.pas',
  Autopilot.Mcp.Tool.ReadProperty  in '..\..\Source\McpServer\Autopilot.Mcp.Tool.ReadProperty.pas',
  Autopilot.Mcp.Tool.ExecuteAction in '..\..\Source\McpServer\Autopilot.Mcp.Tool.ExecuteAction.pas',
  Autopilot.Mcp.Tool.WaitFor       in '..\..\Source\McpServer\Autopilot.Mcp.Tool.WaitFor.pas',
  Autopilot.Mcp.Tool.Screenshot    in '..\..\Source\McpServer\Autopilot.Mcp.Tool.Screenshot.pas',
  Autopilot.Mcp.Tool.SetKeepAwake  in '..\..\Source\McpServer\Autopilot.Mcp.Tool.SetKeepAwake.pas',
  Autopilot.Mcp.Tool.DismissDialog in '..\..\Source\McpServer\Autopilot.Mcp.Tool.DismissDialog.pas',
  Autopilot.Mcp.Tool.SendKeys      in '..\..\Source\McpServer\Autopilot.Mcp.Tool.SendKeys.pas',
  Tests.Mcp.Schema            in 'Tests.Mcp.Schema.pas',
  Tests.Mcp.Serializer        in 'Tests.Mcp.Serializer.pas',
  Tests.Mcp.JsonRpc           in 'Tests.Mcp.JsonRpc.pas',
  Tests.Mcp.Stdio             in 'Tests.Mcp.Stdio.pas',
  Tests.Mcp.SocketClient      in 'Tests.Mcp.SocketClient.pas',
  Tests.Mcp.PipeClient        in 'Tests.Mcp.PipeClient.pas',
  Tests.Mcp.Tools             in 'Tests.Mcp.Tools.pas',
  Tests.Mcp.CrashReport       in 'Tests.Mcp.CrashReport.pas',
  Tests.LeakSuppressor        in '..\Tests.LeakSuppressor.pas';

VAR
  Runner       : ITestRunner;
  Results      : IRunResults;
  ConsoleLogger: ITestLogger;
  NUnitLogger  : ITestLogger;

BEGIN
  {$IFDEF DEBUG}
  FastMM4.SuppressMessageBoxes:= TRUE;  { Leaks and heap errors go only to <exe>_MemoryManager_EventLog.txt; a message box would stop the unattended run }
  if FastMM4.FastMM_GetInstallationState = FastMM4.mmisInstalled
  then Writeln('FastMM4 ', FastMM4.FastMMVersion, ': installed')
  else Writeln('FastMM4: NOT INSTALLED (FastMM_FullDebugMode.dll not found, or FastMM4 is not the first unit) - leaks and heap errors go undetected');
  {$ENDIF}
  Application.Initialize;
  ReportMemoryLeaksOnShutdown := TRUE;
  // Install a vectored exception handler that suppresses the one-shot
  // EInOutError that intermittently leaks when stdout is a pipe. See
  // Tests.LeakSuppressor.pas for the root-cause analysis and tradeoff.
  InstallEInOutErrorLeakSuppressor;

  TRY
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    ConsoleLogger := TDUnitXConsoleLogger.Create(TRUE);
    Runner.AddLogger(ConsoleLogger);
    // NUnit XML output goes to %TEMP% so we don't fight TestsMcp.exe's directory locks.
    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create(
      TPath.Combine(TPath.GetTempPath, 'Autopilot_TestsMcp_results.xml'));
    Runner.AddLogger(NUnitLogger);
    { No test of this suite asserts on a worker thread (the fake bridges in Tests.Mcp.PipeClient and Tests.Mcp.SocketClient only serve the pipe/socket), so a test without an assertion fails. }
    Runner.FailsOnNoAsserts := TRUE;

    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  EXCEPT
    ON E: Exception DO
      begin
        Writeln(E.ClassName, ': ', E.Message);
        System.ExitCode := EXIT_ERRORS;  { A runner that crashed must not exit 0 }
      end;
  END;
END.
