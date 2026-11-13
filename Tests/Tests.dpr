PROGRAM Tests;

{=====================================================
   2026.05.12
   Autopilot — bridge test suite

   Console-mode DUnitX runner. No LightSaber dependency.
   The fixture form is created lazily in each test's Setup.
   Letting an AI write and run DUnitX tests: the book "Delphi in All Its Glory" Part 5, "AI-Assisted Development
   for Delphi", chapter "Common Workflows for Delphi Developers", section "Working with Tests (DUnitX)".
   https://gabrielmoraru.com/the-delphi-in-all-its-glory-book-5-ai-assisted-development-for-delphi/
=====================================================}

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}
{$R *.res}  { Links the runtime-themes manifest that Tests.dproj names (Manifest_File), so the VCL creates the same native controls as in a customer's app }

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
  Autopilot.Bridge.Core     in '..\Source\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.Log      in '..\Source\Bridge\Autopilot.Bridge.Log.pas',
  Autopilot.Bridge.Transport in '..\Source\Bridge\Autopilot.Bridge.Transport.pas',
  Autopilot.Bridge.Worker    in '..\Source\Bridge\Autopilot.Bridge.Worker.pas',
  Autopilot.Bridge.NamedPipe in '..\Source\Bridge\Autopilot.Bridge.NamedPipe.pas',
  Autopilot.Bridge.NativeDialogs in '..\Source\Bridge\Autopilot.Bridge.NativeDialogs.pas',
  Autopilot.Bridge.Vcl       in '..\Source\Bridge\Autopilot.Bridge.Vcl.pas',
  Autopilot.Client           in '..\Source\Client\Autopilot.Client.pas',
  Bridge.TestClient           in 'Bridge.TestClient.pas',
  Bridge.Tests                in 'Bridge.Tests.pas',
  Tests.Bridge.Worker         in 'Tests.Bridge.Worker.pas',
  Tests.Bridge.NativeDialogs  in 'Tests.Bridge.NativeDialogs.pas',
  Tests.Bridge.PathsAndActions in 'Tests.Bridge.PathsAndActions.pas',
  Tests.Bridge.PropertyTypes  in 'Tests.Bridge.PropertyTypes.pas',
  Tests.Bridge.DBGrid         in 'Tests.Bridge.DBGrid.pas',
  Tests.Bridge.Screenshot     in 'Tests.Bridge.Screenshot.pas',
  Tests.Bridge.ScreenshotNative in 'Tests.Bridge.ScreenshotNative.pas',
  Tests.Bridge.SendKeys       in 'Tests.Bridge.SendKeys.pas',
  Tests.Client                in 'Tests.Client.pas',
  Tests.RaiseCounter          in 'Tests.RaiseCounter.pas',
  Tests.LeakSuppressor        in 'Tests.LeakSuppressor.pas',
  Tests.ErrorCodes            in 'Tests.ErrorCodes.pas',
  Tests.Bridge.KeyNames       in 'Tests.Bridge.KeyNames.pas',
  Tests.Bridge.Guide          in 'Tests.Bridge.Guide.pas',
  Tests.Bridge.EventHandlers  in 'Tests.Bridge.EventHandlers.pas';

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
    // NUnit XML output goes to %TEMP% so we don't fight Tests.exe's directory locks.
    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create(
      TPath.Combine(TPath.GetTempPath, 'Autopilot_Tests_results.xml'));
    Runner.AddLogger(NUnitLogger);
    // FailsOnNoAsserts disabled because our test assertions happen on worker threads
    // and DUnitX's per-test counter is fiber-local. RunOnWorkerAndPump re-emits the
    // assertion on the parent thread so DUnitX still sees pass/fail.
    Runner.FailsOnNoAsserts := FALSE;

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
