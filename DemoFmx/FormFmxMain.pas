unit FormFmxMain;

{=============================================================================================================
   2026.10.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - FMX demo form for the Autopilot bridge.
   - Mirrors the VCL demo layout; adds cbxFlag (TCheckBox.IsChecked) so the set_checked tool has a target to flip.
   - Test fixtures for "Tests\E2E tests\Test-AllTools.ps1": a button that opens a native message box
     (btnDialog -> lblDialogResult), an action bound to a TButton and a TSpeedButton (actFixture -> lblActionResult),
     a label placed on a panel (pnlFixture.lblInPanel) for the path rule, a TRectangle for a TAlphaColor property,
     and a button whose label changes one second later (btnDelayed -> tmrDelayed -> lblDelayed) for wait_for.
   - registerAutopilotCommands (called by the constructor): two app commands for the MCP tool call_method (demo.setName, demo.increment).
=============================================================================================================}

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Actions,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.Controls.Presentation, FMX.Objects, FMX.ActnList,
  FMX.DialogService, FMX.Menus;

type
  TfrmFmxMain = class(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    imgLogo     : TImage;
    cbxFlag     : TCheckBox;
    lblFlag     : TLabel;
    btnDialog      : TButton;
    lblDialogResult: TLabel;
    pnlFixture     : TPanel;
    lblInPanel     : TLabel;
    btnAction      : TButton;
    sbAction       : TSpeedButton;
    lblActionResult: TLabel;
    rectFixture    : TRectangle;
    btnDelayed     : TButton;
    lblDelayed     : TLabel;
    tmrDelayed     : TTimer;
    actlFixture    : TActionList;
    actFixture     : TAction;
    lblLastKey     : TLabel;
    lblSaveCount   : TLabel;
    actSave        : TAction;
    lblWebsite     : TLabel;
    lblBook        : TLabel;
    mnuMain       : TMainMenu;
    mnuHelp        : TMenuItem;
    mnuCheckUpdates: TMenuItem;
    mnuAbout       : TMenuItem;
    procedure btnIncrementClick(Sender: TObject);
    procedure edtNameKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure actSaveExecute(Sender: TObject);
    procedure edtNameChangeTracking(Sender: TObject);
    procedure cbxFlagChange(Sender: TObject);
    procedure btnDialogClick(Sender: TObject);
    procedure actFixtureExecute(Sender: TObject);
    procedure btnDelayedClick(Sender: TObject);
    procedure tmrDelayedTimer(Sender: TObject);
    procedure lblWebsiteClick(Sender: TObject);
    procedure lblBookClick(Sender: TObject);
    procedure mnuCheckUpdatesClick(Sender: TObject);
    procedure mnuAboutClick(Sender: TObject);
  private
    FCounter: Integer;
    FActionRuns: Integer;
    FDelayedRuns: Integer;
    FSaveRuns: Integer;
    procedure registerAutopilotCommands;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  frmFmxMain: TfrmFmxMain;


implementation

{$R *.fmx}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.ShellAPI,
  {$ENDIF}
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNI.App, Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.Net,
  {$ENDIF}
  System.JSON, Autopilot.Bridge.Core, Autopilot.Bridge.Commands;


const
  CmdSetName   = 'demo.setName';
  CmdIncrement = 'demo.increment';


{ Registered here, not in the .dpr: before Application.Run, the FMX Application.CreateForm only queues the form (FMX.Forms, TApplication.CreateForm),
  so frmFmxMain is still NIL after it and the handlers would capture a NIL Self. }
constructor TfrmFmxMain.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  registerAutopilotCommands;
end;


{ The app commands that the MCP tool call_method can call (sample for the E2E script; the same two as the VCL demo).
  Without AUTOPILOT, RegisterAutopilotCommand does nothing. }
procedure TfrmFmxMain.registerAutopilotCommands;
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
      lblNameEcho.Text := edtName.Text;
      Result := TJSONObject.Create(TJSONPair.Create('echo', lblNameEcho.Text));
    end);

  RegisterAutopilotCommand(CmdIncrement, 'Adds to the counter shown in lblCounter. args: by (number, optional, default 1). Returns counter (number).',
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
      lblCounter.Text := IntToStr(FCounter);
      Result := TJSONObject.Create(TJSONPair.Create('counter', TJSONNumber.Create(FCounter)));
    end);
end;


{ The handlers use this form: remove them before it is freed. }
destructor TfrmFmxMain.Destroy;
begin
  UnregisterAutopilotCommand(CmdSetName);
  UnregisterAutopilotCommand(CmdIncrement);
  inherited Destroy;
end;


procedure OpenUrl(const Url: string);
begin
  {$IFDEF MSWINDOWS}
  ShellExecute(0, 'open', PChar(Url), NIL, NIL, SW_SHOWNORMAL);
  {$ENDIF}
  {$IFDEF ANDROID}
  TAndroidHelper.Activity.startActivity(TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_VIEW, StrToJURI(Url)));
  {$ENDIF}
end;


procedure TfrmFmxMain.btnIncrementClick(Sender: TObject);
begin
  Inc(FCounter);
  lblCounter.Text := IntToStr(FCounter);
end;


procedure TfrmFmxMain.edtNameChangeTracking(Sender: TObject);
begin
  lblNameEcho.Text := edtName.Text;
end;


procedure TfrmFmxMain.cbxFlagChange(Sender: TObject);
begin
  if cbxFlag.IsChecked
  then lblFlag.Text := 'on'
  else lblFlag.Text := 'off';
end;


// send_keys fixture: the last virtual key that reached edtName.OnKeyDown, e.g. 'Key 13' or 'Key 90 Ctrl'. A typed character arrives with Key = 0 and is skipped.
procedure TfrmFmxMain.edtNameKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = 0 then EXIT;
  if ssCtrl in Shift
  then lblLastKey.Text := 'Key ' + IntToStr(Key) + ' Ctrl'
  else lblLastKey.Text := 'Key ' + IntToStr(Key);
end;


procedure TfrmFmxMain.actSaveExecute(Sender: TObject);
begin
  Inc(FSaveRuns);
  lblSaveCount.Text := 'Saved ' + IntToStr(FSaveRuns);
end;


// On Windows this is a native message box (FMX.Dialogs.Win calls MessageBoxIndirect): the main thread waits in
// its modal loop until the dialog closes. The component tools cannot see it; dismiss_dialog reaches it through Win32.
// On Android and iOS TDialogService shows the box without waiting (SetPreferredMode in FMX.DialogService.pas).
procedure TfrmFmxMain.btnDialogClick(Sender: TObject);
const
  {$IFDEF MSWINDOWS}
  DialogText = 'This is a native Windows message box (TDialogService.MessageDialog).' + sLineBreak + sLineBreak +
               'The main thread waits inside this box until you close it. That is how a Windows message box works; Autopilot does not cause it.' + sLineBreak + sLineBreak +
               'An AI can close it with the Autopilot tool dismiss_dialog.';
  {$ELSE}
  DialogText = 'This message box comes from TDialogService.MessageDialog.' + sLineBreak + sLineBreak +
               'The Autopilot tool dismiss_dialog works only on Windows, so close this box by hand.';
  {$ENDIF}
begin
  TDialogService.MessageDialog(DialogText,
                               TMsgDlgType.mtWarning, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo, TMsgDlgBtn.mbCancel], TMsgDlgBtn.mbYes, 0,
                               procedure(const AResult: TModalResult)
                               begin
                                 lblDialogResult.Text := 'Dialog closed with ' + IntToStr(AResult);
                               end);
end;


// Sender is the action itself when the run went through TCustomAction.Execute, and the control when its OnClick was called directly.
procedure TfrmFmxMain.actFixtureExecute(Sender: TObject);
begin
  Inc(FActionRuns);
  lblActionResult.Text := 'Action ran ' + IntToStr(FActionRuns) + ' times, sender ' + Sender.ClassName;
end;


procedure TfrmFmxMain.btnDelayedClick(Sender: TObject);
begin
  lblDelayed.Text := 'waiting';
  tmrDelayed.Enabled := TRUE;   // Interval is the default 1000 ms
end;


procedure TfrmFmxMain.tmrDelayedTimer(Sender: TObject);
begin
  tmrDelayed.Enabled := FALSE;
  Inc(FDelayedRuns);
  lblDelayed.Text := 'Delayed done ' + IntToStr(FDelayedRuns);
end;


procedure TfrmFmxMain.lblWebsiteClick(Sender: TObject);
begin
  OpenUrl(HomePageUrl);
end;


procedure TfrmFmxMain.lblBookClick(Sender: TObject);
begin
  OpenUrl(BookURL);
end;


procedure TfrmFmxMain.mnuCheckUpdatesClick(Sender: TObject);
begin
  OpenUrl(WhatsNewUrl);
end;


procedure TfrmFmxMain.mnuAboutClick(Sender: TObject);
begin
  OpenUrl(HomePageUrl);
end;


end.
