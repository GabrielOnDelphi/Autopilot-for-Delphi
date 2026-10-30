unit Autopilot.Mcp.CrashReport;

{=============================================================================================================
   2026.10.28
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - The command-line switch '--no-crash-report': the user's way to stop the MCP server from uploading its
     madExcept crash report. With it a crash report is only saved to a file beside the server's log.
   - Only the parsing lives here. The madExcept settings are changed in Autopilot.Mcp.dpr, in the code that
     compiles only with the madshi define, so this unit builds without madExcept (the MCP test project).
   - Stdlib only.
=============================================================================================================}

interface

const
  NoCrashReportSwitch = '--no-crash-report';

/// TRUE when Args holds NoCrashReportSwitch as one whole argument, in any letter case, at any position.
function HasNoCrashReportSwitch(const Args: array of string): Boolean;

/// HasNoCrashReportSwitch applied to the command line of this process (ParamStr(1)..ParamStr(ParamCount)).
function NoCrashReportRequested: Boolean;

/// The file a crash report is saved to when the switch is given: 'bugreport Autopilot.Mcp.txt' in the folder
/// of LogPath, the server's log file. An empty LogPath gives the bare file name.
function NoCrashReportFile(const LogPath: string): string;


implementation

uses
  System.SysUtils;

const
  CrashReportFileName = 'bugreport Autopilot.Mcp.txt';


function HasNoCrashReportSwitch(const Args: array of string): Boolean;
var
  Arg: string;
begin
  for Arg in Args do
    if SameText(Arg, NoCrashReportSwitch)
    then EXIT(TRUE);
  Result:= FALSE;
end;


function NoCrashReportRequested: Boolean;
var
  Args: TArray<string>;
  i: Integer;
begin
  SetLength(Args, ParamCount);
  for i:= 1 to ParamCount do
    Args[i - 1]:= ParamStr(i);
  Result:= HasNoCrashReportSwitch(Args);
end;


function NoCrashReportFile(const LogPath: string): string;
begin
  Result:= ExtractFilePath(LogPath) + CrashReportFileName;
end;


end.
