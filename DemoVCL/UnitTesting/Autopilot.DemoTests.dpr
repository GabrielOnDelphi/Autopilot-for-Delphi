program Autopilot.DemoTests;

{=============================================================================================================
   2026.10.13
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Console DUnitX runner of the GUI tests of the VCL demo app (DemoTests.Main.pas)
   - Exit code 0 when every test passed, non-zero when a test failed or the runner could not start, so a build
     server can run it as a step
   - --xmlfile:<path> names the NUnit XML result file (DUnitX creates a missing folder); without it DUnitX writes
     dunitx-results.xml beside this EXE
   - Build the demo app (..\Autopilot.Demo.dproj) first: the tests start it (where they look: DemoExePath in
     DemoTests.Main.pas)
=============================================================================================================}

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Autopilot.Bridge.Core in '..\..\Source\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.Log  in '..\..\Source\Bridge\Autopilot.Bridge.Log.pas',
  Autopilot.Client      in '..\..\Source\Client\Autopilot.Client.pas',
  DemoTests.Main        in 'DemoTests.Main.pas';

var
  Runner : ITestRunner;
  Results: IRunResults;

begin
  ReportMemoryLeaksOnShutdown := TRUE;   // a console program writes the leak report to stderr, never a box
  try
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.AddLogger(TDUnitXConsoleLogger.Create(TRUE));
    Runner.AddLogger(TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile));   // '' = DUnitX's default file
    Runner.FailsOnNoAsserts := TRUE;   // a test that asserts nothing fails

    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      { The runner could not start (a bad switch, an XML file that cannot be created) or crashed: a build server
        must not read that as "all passed". CheckCommandLine has already set EXIT_OPTIONS_ERROR for a bad switch. }
      if System.ExitCode = EXIT_OK then
        System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
