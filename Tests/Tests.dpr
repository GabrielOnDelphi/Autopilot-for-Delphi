PROGRAM Tests;

{=====================================================
   2026.05.12
   Autopilot — bridge test suite

   Console-mode DUnitX runner. No LightSaber dependency.
   The fixture form is created lazily in each test's Setup.
=====================================================}

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

USES
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
  Bridge.TestClient           in 'Bridge.TestClient.pas',
  Bridge.Tests                in 'Bridge.Tests.pas',
  Tests.Bridge.Worker         in 'Tests.Bridge.Worker.pas',
  Tests.Bridge.NativeDialogs  in 'Tests.Bridge.NativeDialogs.pas',
  Tests.Bridge.PathsAndActions in 'Tests.Bridge.PathsAndActions.pas',
  Tests.Bridge.PropertyTypes  in 'Tests.Bridge.PropertyTypes.pas',
  Tests.RaiseCounter          in 'Tests.RaiseCounter.pas',
  Tests.LeakSuppressor        in 'Tests.LeakSuppressor.pas';

VAR
  Runner       : ITestRunner;
  Results      : IRunResults;
  ConsoleLogger: ITestLogger;
  NUnitLogger  : ITestLogger;

BEGIN
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
      Writeln(E.ClassName, ': ', E.Message);
  END;
END.
