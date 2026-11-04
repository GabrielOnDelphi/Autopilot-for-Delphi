unit FormMain;

{=============================================================================================================
   2026.11.04
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - VCL demo form for the Autopilot bridge.
   - One form with four controls (btnIncrement, lblIncrement, edtName, lblNameEcho) to exercise list_tree, click, and get_text end-to-end.
   - Test fixtures for "Tests\E2E tests\Test-AllTools.ps1": an action bound to a TButton and a TSpeedButton
     (actFixture -> lblActionResult), a check box (chkFixture -> lblCheckState), a label placed on a panel
     (pnlFixture.lblInPanel) for the path rule, and a button whose label changes one second later (btnDelayed -> tmrDelayed -> lblDelayed) for wait_for.
   - AutopilotGuide (AUTOPILOT builds only): the guide text that list_tree shows on the frmMain node.
=============================================================================================================}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes, System.Actions,
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
    procedure actFixtureExecute    (Sender: TObject);
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
  private
    FCounter: Integer;
    FActionRuns: Integer;
    FDelayedRuns: Integer;
    FSaveRuns: Integer;
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
  Winapi.ShellAPI, Autopilot.Bridge.Core;


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
