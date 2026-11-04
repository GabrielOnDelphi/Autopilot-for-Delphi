unit Tests.Mcp.CrashReport;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - DUnitX tests for the crash-report switches of the MCP server (Autopilot.Mcp.CrashReport):
     the upload is off without '--crash-report', on with it in any letter case and together with
     '--target adb:<port>' in either order, off again when '--no-crash-report' is also given, near misses,
     and the file a crash report is saved to.
=============================================================================================================}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TCrashReportSwitchTests = class
  public
    [Test] procedure Test_Off_NoArguments;
    [Test] procedure Test_Off_OnlyTargetAdb;
    [Test] procedure Test_Off_NoCrashReportAlone;
    [Test] procedure Test_On_Alone;
    [Test] procedure Test_On_UpperCase;
    [Test] procedure Test_On_MixedCase;
    [Test] procedure Test_On_BeforeTargetAdb;
    [Test] procedure Test_On_AfterTargetAdb;
    [Test] procedure Test_On_AfterTargetAdbInOneArgument;
    [Test] procedure Test_NoCrashReportWins_After;
    [Test] procedure Test_NoCrashReportWins_Before;
    [Test] procedure Test_NearMissesAreNotTheSwitch;
    [Test] procedure Test_HasSwitch_FindsEachSwitch;
    [Test] procedure Test_ReportFile_BesideTheLog;
    [Test] procedure Test_ReportFile_EmptyLogPath;
  end;


implementation

uses
  Autopilot.Mcp.CrashReport;


procedure TCrashReportSwitchTests.Test_Off_NoArguments;
begin
  Assert.IsFalse(CrashReportUploadAllowed([]), 'An empty command line must keep the upload off');
end;


procedure TCrashReportSwitchTests.Test_Off_OnlyTargetAdb;
begin
  Assert.IsFalse(CrashReportUploadAllowed(['--target', 'adb:5000']), '--target adb:5000 alone must keep the upload off');
end;


procedure TCrashReportSwitchTests.Test_Off_NoCrashReportAlone;
begin
  Assert.IsFalse(CrashReportUploadAllowed(['--no-crash-report']), '--no-crash-report must keep the upload off');
end;


procedure TCrashReportSwitchTests.Test_On_Alone;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--crash-report']));
end;


procedure TCrashReportSwitchTests.Test_On_UpperCase;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--CRASH-REPORT']), 'The switch is matched without regard to case');
end;


procedure TCrashReportSwitchTests.Test_On_MixedCase;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--Crash-Report']), 'The switch is matched without regard to case');
end;


procedure TCrashReportSwitchTests.Test_On_BeforeTargetAdb;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--crash-report', '--target', 'adb:5000']));
end;


procedure TCrashReportSwitchTests.Test_On_AfterTargetAdb;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--target', 'adb:5000', '--crash-report']));
end;


procedure TCrashReportSwitchTests.Test_On_AfterTargetAdbInOneArgument;
begin
  Assert.IsTrue(CrashReportUploadAllowed(['--target=adb:5000', '--crash-report']));
end;


procedure TCrashReportSwitchTests.Test_NoCrashReportWins_After;
begin
  Assert.IsFalse(CrashReportUploadAllowed(['--crash-report', '--no-crash-report']), '--no-crash-report must win over --crash-report');
end;


procedure TCrashReportSwitchTests.Test_NoCrashReportWins_Before;
begin
  Assert.IsFalse(CrashReportUploadAllowed(['--No-Crash-Report', '--target', 'adb:5000', '--crash-report']), '--no-crash-report must win in any case and position');
end;


procedure TCrashReportSwitchTests.Test_NearMissesAreNotTheSwitch;
begin
  Assert.IsFalse(CrashReportUploadAllowed(['--crash-reports']),   'A longer word is not the switch');
  Assert.IsFalse(CrashReportUploadAllowed(['--crash-report=1']),  'A value glued to the switch is not the switch');
  Assert.IsFalse(CrashReportUploadAllowed(['crash-report']),      'The switch needs its two hyphens');
  Assert.IsFalse(CrashReportUploadAllowed(['--target', 'adb:5000', '--crash']), 'A shorter word is not the switch');
  Assert.IsTrue (CrashReportUploadAllowed(['--crash-report', '--no-crash-reports']), 'A near miss of --no-crash-report does not turn the upload off');
end;


procedure TCrashReportSwitchTests.Test_HasSwitch_FindsEachSwitch;
begin
  Assert.IsTrue (HasSwitch(['--target', 'adb:5000', '--no-crash-report'], NoCrashReportSwitch));
  Assert.IsFalse(HasSwitch(['--no-crash-report'], CrashReportSwitch), '--no-crash-report is not --crash-report');
  Assert.IsFalse(HasSwitch(['--crash-report'], NoCrashReportSwitch),  '--crash-report is not --no-crash-report');
end;


procedure TCrashReportSwitchTests.Test_ReportFile_BesideTheLog;
begin
  Assert.AreEqual('C:\Users\Dev\AppData\Local\Temp\Autopilot\bugreport Autopilot.Mcp.txt',
                  CrashReportFile('C:\Users\Dev\AppData\Local\Temp\Autopilot\Autopilot.Mcp-4242.log'));
end;


procedure TCrashReportSwitchTests.Test_ReportFile_EmptyLogPath;
begin
  Assert.AreEqual('bugreport Autopilot.Mcp.txt', CrashReportFile(''));
end;


initialization
  TDUnitX.RegisterTestFixture(TCrashReportSwitchTests);

end.
