unit Autopilot.Mcp.Tool.DismissDialog;

{=============================================================================================================
   2026.11.15
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: dismiss_dialog
   - Lists and dismisses native OS dialogs (MessageBox, Vista Task Dialog, common file dialogs) raised by the target.
     These are raw Win32 windows with no TComponent, so the path-based tools (list_tree / click) cannot see them - they return not_found while the app's main thread is blocked in the dialog's modal loop.
   - Call with no 'button' to LIST the dialogs currently up; call with 'button' to dismiss one.
   - 'waitMs' polls until a dialog is up, for the call that follows the click which opens it.
   - Windows targets only.
     Against an Android FMX target the response is supported:false.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

type
  TDismissDialogParams = class
  private
    FButton  : String;
    FFileName: String;
    FHwnd    : Int64;
    FWaitMs  : Integer;
    FPid     : Integer;
  public
    [Optional]
    [SchemaDescription('Button to click: a caption (exact, case-insensitive), a role ("ok", "cancel", ' + '"yes", "no", "retry", "abort", "ignore", "close", "tryagain", "continue"), a caption ' + 'substring or a numeric control id. It must match exactly one button, else ' + 'clicked:false. On a Task Dialog (MessageDlg) every button has id 0: use its caption. ' + 'Omit to only list the open dialogs and their buttons.')]
    property Button: String read FButton write FButton;

    [Optional]
    [SchemaDescription('Text for the File name box of an Open or Save dialog, typed before the button ' + 'is clicked (a full path is safest). The dialog must have exactly one visible text box. ' + 'The button is clicked only when the box reads back this text (answer field fileNameSet). ' + 'Without button: only the box is filled.')]
    property FileName: String read FFileName write FFileName;

    [Optional]
    [SchemaDescription('Dialog hwnd from a prior list. Omit for the topmost dialog.')]
    property Hwnd: Int64 read FHwnd write FHwnd;

    [Optional]
    [SchemaDescription('Wait up to this many ms (max 10000) for a dialog to appear. Pass e.g. 2000 right ' + 'after the click that opens it. Default 0: answer at once.')]
    property WaitMs: Integer read FWaitMs write FWaitMs;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;
  end;

  TDismissDialogTool = class(TMCPToolBase<TDismissDialogParams>)
  private
    function pollTarget(const Params: TDismissDialogParams; AWithButton, AWithFileName: Boolean; AHwnd: Int64; AWaitMs: Integer): String;
    function runWithFileName(const Params: TDismissDialogParams): String;
  protected
    function ExecuteWithParams(const Params: TDismissDialogParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TDismissDialogTool.Create;
begin
  inherited;
  FName := 'dismiss_dialog';
  FDescription := 'List or dismiss native dialogs (MessageBox, Task Dialog, file dialogs) that the other tools cannot reach. Windows only.';
end;


{ TRUE when AAnswer needs no further poll: an error, a platform without native dialogs, a click that found a dialog (clicked or not), or a list that is not empty.
  FALSE only for "no dialog yet": a click with reason 'no_dialog', or an empty 'dialogs' list. }
function AnswerIsFinal(const AAnswer: String; AClicking: Boolean): Boolean;
var
  Root, Dialogs: TJSONValue;
  Res: TJSONObject;
begin
  Result := TRUE;
  Root := TJSONObject.ParseJSONValue(AAnswer);
  try
    if not (Root is TJSONObject) then EXIT;
    if not TJSONObject(Root).GetValue<Boolean>('ok', FALSE) then EXIT;
    if not (TJSONObject(Root).GetValue('result') is TJSONObject) then EXIT;
    Res := TJSONObject(TJSONObject(Root).GetValue('result'));
    if not Res.GetValue<Boolean>('supported', TRUE) then EXIT;
    if AClicking
    then Result := Res.GetValue<String>('reason', '') <> 'no_dialog'
    else
      begin
        Dialogs := Res.GetValue('dialogs');
        Result := not ((Dialogs is TJSONArray) and (TJSONArray(Dialogs).Count = 0));
      end;
  finally
    FreeAndNil(Root);
  end;
end;


{ With waitMs the command is sent again every PollEveryMs until a dialog shows up or the time is over.
  The wait runs here, in the MCP server, never in the bridge: the bridge answers on the target's main thread, which must stay free to run the click that opens the dialog.
  A call with fileName waits like a click: until the answer's reason is no longer 'no_dialog'. }
function TDismissDialogTool.pollTarget(const Params: TDismissDialogParams; AWithButton, AWithFileName: Boolean; AHwnd: Int64; AWaitMs: Integer): String;
const
  PollEveryMs = 50;
var
  Args: TJSONObject;
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + UInt64(AWaitMs);
  repeat
    Args := TJSONObject.Create;   // BuildRequest consumes it, and RunCommandOnTarget frees the request: build both anew for every poll
    if AWithButton
    then Args.AddPair('button', Params.Button);
    if AWithFileName
    then Args.AddPair('fileName', Params.FileName);
    if AHwnd <> 0
    then Args.AddPair('hwnd', TJSONNumber.Create(AHwnd));
    Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'dismiss_dialog', Args));
    if (AWaitMs = 0) or AnswerIsFinal(Result, AWithButton or AWithFileName) or (TThread.GetTickCount64 >= Deadline)
    then EXIT;
    Sleep(PollEveryMs);
  until FALSE;
end;


{ fileName in two calls, so a bridge older than 3.8.0 never clicks Save with the wrong name: it ignores fileName and would click the button at once.
  Call 1 sends fileName alone (no button). A 3.8.0 bridge fills the box and answers fileNameSet; an older one only lists the dialogs and answers no fileNameSet, and then the tool stops with an error.
  Call 2 (only when a button is asked for and the box holds the name) sends fileName, button and the hwnd of the dialog of call 1, so the name is set and read back again and the click goes to that same dialog, in one dispatch. }
function TDismissDialogTool.runWithFileName(const Params: TDismissDialogParams): String;
var
  Root: TJSONValue;
  Res: TJSONObject;
  NameSet: TJSONValue;
  DlgHwnd: Int64;
begin
  Result := pollTarget(Params, FALSE, TRUE, Params.Hwnd, Params.WaitMs);
  Root := TJSONObject.ParseJSONValue(Result);
  try
    { An error answer, or a target with no native dialogs (Android): passed on as it is. }
    if not (Root is TJSONObject) then EXIT;
    if not TJSONObject(Root).GetValue<Boolean>('ok', FALSE) then EXIT;
    if not (TJSONObject(Root).GetValue('result') is TJSONObject) then EXIT;
    Res := TJSONObject(TJSONObject(Root).GetValue('result'));
    if not Res.GetValue<Boolean>('supported', TRUE) then EXIT;

    NameSet := Res.GetValue('fileNameSet');
    if not (NameSet is TJSONBool)
    then raise Exception.Create('fileName: the Autopilot bridge in the target app is older than 3.8.0 and ignores fileName, '
                              + 'so no button was clicked. Update the bridge units of the app to 3.8.0 or newer and rebuild it.');

    if not TJSONBool(NameSet).AsBoolean then
      begin
        { The name was refused: nothing was clicked. With a button asked for, the answer says so in clicked:false too. }
        if (Trim(Params.Button) <> '') and (Res.GetValue('clicked') = NIL) then
          begin
            Res.AddPair('clicked', TJSONBool.Create(FALSE));
            Result := Root.ToJSON;
          end;
        EXIT;
      end;

    if Trim(Params.Button) = '' then EXIT;
    DlgHwnd := Res.GetValue<Int64>('dialogHwnd', Params.Hwnd);
  finally
    FreeAndNil(Root);
  end;
  Result := pollTarget(Params, TRUE, TRUE, DlgHwnd, 0);
end;


function TDismissDialogTool.ExecuteWithParams(const Params: TDismissDialogParams): String;
const
  MaxWaitMs = 10000;
begin
  if (Params.WaitMs < 0) or (Params.WaitMs > MaxWaitMs)
  then raise EArgumentException.Create('waitMs must be 0..' + IntToStr(MaxWaitMs) + ', got ' + IntToStr(Params.WaitMs));
  if Params.FileName <> ''
  then Result := runWithFileName(Params)
  else Result := pollTarget(Params, Trim(Params.Button) <> '', FALSE, Params.Hwnd, Params.WaitMs);
end;


initialization
  TMCPRegistry.RegisterTool('dismiss_dialog',
    function: IMCPTool
    begin
      Result := TDismissDialogTool.Create;
    end
  );


end.
