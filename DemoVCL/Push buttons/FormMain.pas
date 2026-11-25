unit FormMain;

{=============================================================================================================
   2026.11.25
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - VCL demo form for the Autopilot bridge.
   - One form with four controls (btnIncrement, lblIncrement, edtName, lblNameEcho) to exercise list_tree, click, and get_text end-to-end.
   - Test fixtures for "Tests\E2E tests\Test-AllTools.ps1": an action bound to a TButton and a TSpeedButton
     (actFixture -> lblActionResult), a check box (chkFixture -> lblCheckState), a label placed on a panel
     (pnlFixture.lblInPanel) for the path rule, a button whose label changes one second later (btnDelayed -> tmrDelayed -> lblDelayed) for wait_for,
     a popup menu item that opens the native dialog (pmDialog.mnuPopupDialog, never shown) for click mode='message' on a TMenuItem,
     a MessageDlg (btnMsgDlg, a Task Dialog) and an Open and a Save file dialog (btnOpenFile, btnSaveFile), whose results go to lblDialogResult, for dismiss_dialog.
   - AutopilotGuide (AUTOPILOT builds only): the guide text that list_tree shows on the frmMain node.
   - registerAutopilotCommands (called by the constructor): two app commands for the MCP tool call_method (demo.setName, demo.increment).
   - The form remembers its position (Left, Top) in Autopilot.PushBtnsDemo.ini, beside the exe (loadFormPosition, saveFormPosition).
=============================================================================================================}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes, System.Actions, System.UITypes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Buttons, Vcl.ActnList, Vcl.Imaging.jpeg, Vcl.Menus;

type
  TfrmMain = class(TForm)
    imgLogo        : TImage;
    btnIncrement   : TButton;
    lblIncrement: TLabel;
    edtName        : TEdit;
    lblNameEcho    : TLabel;
    lblHeader      : TLabel;
    btnDialog      : TButton;
    lblActionResult: TLabel;
    lblCheckState  : TLabel;
    sbAction       : TSpeedButton;
    pnlFixture     : TPanel;
    lblInPanel     : TLabel;
    btnAction      : TButton;
    chkFixture     : TCheckBox;
    actlFixture    : TActionList;
    actFixture     : TAction;
    lblDelayed     : TLabel;
    btnDelayed     : TButton;
    tmrDelayed     : TTimer;
    lblLastKey     : TLabel;
    lblSaveCount   : TLabel;
    actSave        : TAction;
    lblWebsite     : TLinkLabel;
    lblBook        : TLinkLabel;
    mnuMain        : TMainMenu;
    mnuHelp        : TMenuItem;
    mnuCheckUpdates: TMenuItem;
    mnuAbout       : TMenuItem;
    pmDialog       : TPopupMenu;
    mnuPopupDialog : TMenuItem;
    lblDialogResult: TLabel;
    btnMsgDlg      : TButton;
    btnOpenFile    : TButton;
    btnSaveFile    : TButton;
    dlgOpen        : TOpenDialog;
    dlgSave        : TSaveDialog;
    procedure actFixtureExecute    (Sender: TObject);
    procedure btnMsgDlgClick       (Sender: TObject);
    procedure btnOpenFileClick     (Sender: TObject);
    procedure btnSaveFileClick     (Sender: TObject);
    procedure actSaveExecute       (Sender: TObject);
    procedure btnDelayedClick      (Sender: TObject);
    procedure btnDialogClick       (Sender: TObject);
    procedure btnIncrementClick    (Sender: TObject);
    procedure chkFixtureClick      (Sender: TObject);
    procedure edtNameChange        (Sender: TObject);
    procedure edtNameKeyDown       (Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure lblBookLinkClick     (Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure lblWebsiteLinkClick  (Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure mnuAboutClick        (Sender: TObject);
    procedure mnuCheckUpdatesClick (Sender: TObject);
    procedure tmrDelayedTimer      (Sender: TObject);
    procedure FormClose            (Sender: TObject; var Action: TCloseAction);
  private
    FCounter: Integer;
    FActionRuns: Integer;
    FDelayedRuns: Integer;
    FSaveRuns: Integer;
    procedure registerAutopilotCommands;
    procedure loadFormPosition;
    procedure saveFormPosition;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  {$IFDEF AUTOPILOT}
  private
    function GetAutopilotGuide: string;
  published
    // The bridge's list_tree sends this text as the field guide of the frmMain node
    property AutopilotGuide: string read GetAutopilotGuide;
  {$ENDIF}
  end;

var
  frmMain: TfrmMain;


implementation

{$R *.dfm}

uses
  Winapi.ShellAPI, System.Types, System.JSON, System.IniFiles, Autopilot.Bridge.Core, Autopilot.Bridge.Commands, Autopilot.Bridge.Log;


const
  CmdSetName      = 'demo.setName';
  CmdIncrement    = 'demo.increment';
  PositionSection = 'MainForm';
  NoValue         = Low(Integer);


{ Registered in the constructor, as in the FMX demo (where the .dpr cannot do it: FMX creates the form only in Application.Run). }
constructor TfrmMain.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  loadFormPosition;
  registerAutopilotCommands;
end;


{ The INI file lies beside the exe, not in AppData.
  A program started by an app that is an MSIX package (example: the Claude desktop app) may get its new AppData folders
  and its HKCU writes redirected into a private copy of the package, so a person who starts the same exe by hand would not see them.
  The exe's own folder is not redirected, so every start reads the same file. }
function positionFileName: string;
begin
  Result:= ChangeFileExt(Application.ExeName, '.ini');
end;


{ Restores the position that saveFormPosition wrote. The size stays the DFM's.
  No file, a missing value, or a caption bar on no monitor (a monitor was removed): the form keeps the DFM's poScreenCenter. }
procedure TfrmMain.loadFormPosition;
var
  Ini: TIniFile;
  SavedLeft, SavedTop: Integer;
  CaptionPoint: TPoint;
begin
  if not FileExists(positionFileName) then EXIT;

  Ini:= TIniFile.Create(positionFileName);
  try
    SavedLeft:= Ini.ReadInteger(PositionSection, 'Left', NoValue);
    SavedTop := Ini.ReadInteger(PositionSection, 'Top',  NoValue);
  finally
    FreeAndNil(Ini);
  end;

  if (SavedLeft = NoValue) or (SavedTop = NoValue) then EXIT;

  // The middle of the caption bar must lie on a monitor, so the user can still drag the window.
  CaptionPoint:= Point(SavedLeft + Width div 2, SavedTop + GetSystemMetrics(SM_CYCAPTION) div 2);
  if Screen.MonitorFromPoint(CaptionPoint, mdNull) = NIL then EXIT;

  Position      := poDesigned;
  DefaultMonitor:= dmDesktop;     // SetWindowToMonitor must not move the form to another monitor
  SetBounds(SavedLeft, SavedTop, Width, Height);
end;


{ Saves only the position of a normal window: a minimized window lies at -32000 (TAutopilotApp.Start starts the demo minimized),
  and a maximized one lies at the monitor's corner.
  A folder the user cannot write to (Program Files) gives an EIniFileException: logged, and the form still closes. }
procedure TfrmMain.saveFormPosition;
var
  Ini: TIniFile;
begin
  if WindowState <> wsNormal then EXIT;
  if HandleAllocated and IsIconic(Handle) then EXIT;

  Ini:= TIniFile.Create(positionFileName);
  try
    try
      Ini.WriteInteger(PositionSection, 'Left', Left);
      Ini.WriteInteger(PositionSection, 'Top',  Top);
    except
      on E: EIniFileException do
        BridgeLogWarn('demo', 'The window position was not saved: ' + E.Message);
    end;
  finally
    FreeAndNil(Ini);
  end;
end;


procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  saveFormPosition;
end;


{ The app commands that the MCP tool call_method can call (sample for the E2E script).
  Without AUTOPILOT, RegisterAutopilotCommand does nothing. }
procedure TfrmMain.registerAutopilotCommands;
begin
  RegisterAutopilotCommand(CmdSetName, 'Puts a name into edtName and lblNameEcho. args: text (string). Returns echo (string). Raises without text.',
    function(AArgs: TJSONObject): TJSONValue
    var
      V: TJSONValue;
    begin
      V := AArgs.GetValue('text');
      if not (V is TJSONString)
      then raise EArgumentException.Create(CmdSetName + ' needs args.text (a string)');
      edtName.Text := TJSONString(V).Value;
      lblNameEcho.Caption := edtName.Text;
      Result := TJSONObject.Create(TJSONPair.Create('echo', lblNameEcho.Caption));
    end);

  RegisterAutopilotCommand(CmdIncrement, 'Adds to the counter shown in lblIncrement. args: by (number, optional, default 1). Returns counter (number).',
    function(AArgs: TJSONObject): TJSONValue
    var
      V: TJSONValue;
    begin
      V := AArgs.GetValue('by');
      if V = NIL
      then Inc(FCounter)
      else
        if V is TJSONNumber
        then Inc(FCounter, TJSONNumber(V).AsInt)
        else raise EArgumentException.Create(CmdIncrement + ' args.by must be a number');
      lblIncrement.Caption := IntToStr(FCounter);
      Result := TJSONObject.Create(TJSONPair.Create('counter', TJSONNumber.Create(FCounter)));
    end);
end;


{ The handlers use this form: remove them before it is freed. }
destructor TfrmMain.Destroy;
begin
  UnregisterAutopilotCommand(CmdSetName);
  UnregisterAutopilotCommand(CmdIncrement);
  inherited Destroy;
end;


procedure TfrmMain.btnIncrementClick(Sender: TObject);
begin
  Inc(FCounter);
  lblIncrement.Caption := IntToStr(FCounter);
end;


procedure TfrmMain.edtNameChange(Sender: TObject);
begin
  lblNameEcho.Caption := edtName.Text;
end;


// send_keys fixture: the last key that reached edtName.OnKeyDown, e.g. 'Key 13' or 'Key 90 Ctrl'.
procedure TfrmMain.edtNameKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if ssCtrl in Shift
  then lblLastKey.Caption := 'Key ' + IntToStr(Key) + ' Ctrl'
  else lblLastKey.Caption := 'Key ' + IntToStr(Key);
end;


procedure TfrmMain.actSaveExecute(Sender: TObject);
begin
  Inc(FSaveRuns);
  lblSaveCount.Caption := 'Saved ' + IntToStr(FSaveRuns);
end;


// Raises a native Win32 modal dialog: the main thread now spins in MessageBox's own modal
// loop, so this OnClick never returns until the dialog closes. The component tools cannot
// see this dialog (it has no TComponent) — dismiss_dialog reaches it through Win32.
procedure TfrmMain.btnDialogClick(Sender: TObject);
begin
  Application.MessageBox('This is a native Windows message box (Application.MessageBox).' + sLineBreak + sLineBreak +
                         'The main thread waits inside this box until you close it. That is how a Windows message box works; Autopilot does not cause it.' + sLineBreak + sLineBreak +
                         'An AI can close it with the Autopilot tool dismiss_dialog.',
                         'Native Dialog', MB_YESNOCANCEL or MB_ICONWARNING);
end;


{ MessageDlg shows a Task Dialog (Vcl.Dialogs.pas, MessageDlgPosHelp): its buttons have no control id, unlike those of Application.MessageBox.
  The returned TModalResult goes to lblDialogResult, so a test can check which button the app really got: mrYes = 6, mrNo = 7, mrAbort = 3. }
procedure TfrmMain.btnMsgDlgClick(Sender: TObject);
var
  Answer: Integer;
begin
  Answer := MessageDlg('Autopilot MessageDlg fixture: which button closes this dialog?', mtConfirmation, [mbYes, mbNo, mbAbort], 0);
  lblDialogResult.Caption := 'MessageDlg closed with ' + IntToStr(Answer);
end;


// The file dialogs only report the name the user chose: the demo opens and writes no file.
procedure TfrmMain.btnOpenFileClick(Sender: TObject);
begin
  if dlgOpen.Execute
  then lblDialogResult.Caption := 'Open: ' + dlgOpen.FileName
  else lblDialogResult.Caption := 'Open: cancelled';
end;


procedure TfrmMain.btnSaveFileClick(Sender: TObject);
begin
  if dlgSave.Execute
  then lblDialogResult.Caption := 'Save: ' + dlgSave.FileName
  else lblDialogResult.Caption := 'Save: cancelled';
end;


// Sender is the action itself when the run went through TCustomAction.Execute, and the control when its copied OnClick was called directly.
procedure TfrmMain.actFixtureExecute(Sender: TObject);
begin
  Inc(FActionRuns);
  lblActionResult.Caption := 'Action ran ' + IntToStr(FActionRuns) + ' times, sender ' + Sender.ClassName;
end;


procedure TfrmMain.chkFixtureClick(Sender: TObject);
begin
  if chkFixture.Checked
  then lblCheckState.Caption := 'checked'
  else lblCheckState.Caption := 'unchecked';
end;


procedure TfrmMain.btnDelayedClick(Sender: TObject);
begin
  lblDelayed.Caption := 'waiting';
  tmrDelayed.Enabled := TRUE;   // Interval is the default 1000 ms
end;


procedure TfrmMain.tmrDelayedTimer(Sender: TObject);
begin
  tmrDelayed.Enabled := FALSE;
  Inc(FDelayedRuns);
  lblDelayed.Caption := 'Delayed done ' + IntToStr(FDelayedRuns);
end;


// TLinkLabel only reports the click; opening the browser is our job. The <a> in the DFM has no href, so the URL lives only in Autopilot.Bridge.Core.
procedure TfrmMain.lblWebsiteLinkClick(Sender: TObject; const Link: string; LinkType: TSysLinkType);
begin
  ShellExecute(Handle, 'open', HomePageURL, NIL, NIL, SW_SHOWNORMAL);
end;


procedure TfrmMain.lblBookLinkClick(Sender: TObject; const Link: string; LinkType: TSysLinkType);
begin
  ShellExecute(Handle, 'open', BookURL, NIL, NIL, SW_SHOWNORMAL);
end;


procedure TfrmMain.mnuCheckUpdatesClick(Sender: TObject);
begin
  ShellExecute(Handle, 'open', WhatsNewUrl, NIL, NIL, SW_SHOWNORMAL);
end;


procedure TfrmMain.mnuAboutClick(Sender: TObject);
begin
  ShellExecute(Handle, 'open', HomePageUrl, NIL, NIL, SW_SHOWNORMAL);
end;


{$IFDEF AUTOPILOT}
// Facts about this form, never orders: list_tree shows them on the frmMain node.
function TfrmMain.GetAutopilotGuide: string;
const
  Guide = 'frmMain is a test fixture. ' +
          'btnDelayed: its result arrives 1 second after the click. ' +
          'lblDelayed first reads waiting, then Delayed done <N>, where N counts the runs since start. ' +
          'chkFixture: its OnClick writes checked or unchecked into lblCheckState. ' +
          'btnIncrement adds 1 to the number in lblIncrement.';
begin
  Result := Guide;
end;
{$ENDIF}


end.
