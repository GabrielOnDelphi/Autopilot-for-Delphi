unit Autopilot.Mcp.CrashReport;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - The command-line switches that decide whether the MCP server uploads its madExcept crash report.
     By default a crash report is only saved to a file beside the server's log and never uploaded.
     '--crash-report' allows the upload.
     '--no-crash-report' keeps the default and wins over '--crash-report'.
   - Only the parsing lives here.
     The madExcept settings are changed in Autopilot.Mcp.dpr, in the code that compiles only with the madshi define, so this unit builds without madExcept (the MCP test project).
   - Stdlib only.
=============================================================================================================}

interface

const
  CrashReportSwitch   = '--crash-report';
  NoCrashReportSwitch = '--no-crash-report';

// TRUE when Args holds Switch as one whole argument, in any letter case, at any position.
function HasSwitch(const Args: array of string; const Switch: string): Boolean;

// TRUE only when Args holds CrashReportSwitch and does not hold NoCrashReportSwitch.
function CrashReportUploadAllowed(const Args: array of string): Boolean;

// CrashReportUploadAllowed applied to the command line of this process (ParamStr(1)..ParamStr(ParamCount)).
function CrashReportUploadRequested: Boolean;

{ The file a crash report is saved to when the upload is not allowed: 'bugreport Autopilot.Mcp.txt' in the folder of LogPath, the server's log file.
  An empty LogPath gives the bare file name. }
function CrashReportFile(const LogPath: string): string;


implementation

uses
  System.SysUtils;

const
  CrashReportFileName = 'bugreport Autopilot.Mcp.txt';


function HasSwitch(const Args: array of string; const Switch: string): Boolean;
var
  Arg: string;
begin
  for Arg in Args do
    if SameText(Arg, Switch)
    then EXIT(TRUE);
  Result:= FALSE;
end;


function CrashReportUploadAllowed(const Args: array of string): Boolean;
begin
  Result:= HasSwitch(Args, CrashReportSwitch) AND NOT HasSwitch(Args, NoCrashReportSwitch);
end;


function CrashReportUploadRequested: Boolean;
var
  Args: TArray<string>;
  i: Integer;
begin
  SetLength(Args, ParamCount);
  for i:= 1 to ParamCount do
    Args[i - 1]:= ParamStr(i);
  Result:= CrashReportUploadAllowed(Args);
end;


function CrashReportFile(const LogPath: string): string;
begin
  Result:= ExtractFilePath(LogPath) + CrashReportFileName;
end;


end.
