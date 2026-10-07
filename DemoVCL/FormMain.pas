unit FormMain;

{=============================================================================================================
   2026.10.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - VCL demo form for the Autopilot bridge.
   - One form with four controls (btnIncrement, lblCounter, edtName, lblNameEcho) to exercise list_tree, click, and get_text end-to-end.
   - Test fixtures for "_Local info\E2E tests\Test-AllTools.ps1": an action bound to a TButton and a TSpeedButton
     (actFixture -> lblActionResult), a check box (chkFixture -> lblCheckState), a label placed on a panel
     (pnlFixture.lblInPanel) for the path rule, and a button whose label changes one second later (btnDelayed ->
     tmrDelayed -> lblDelayed) for wait_for.
=============================================================================================================}

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes, System.Actions,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Buttons, Vcl.ActnList;

type
  TfrmMain = class(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    btnDialog   : TButton;
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
    procedure btnIncrementClick(Sender: TObject);
    procedure edtNameChange(Sender: TObject);
    procedure btnDialogClick(Sender: TObject);
    procedure actFixtureExecute(Sender: TObject);
    procedure chkFixtureClick(Sender: TObject);
    procedure btnDelayedClick(Sender: TObject);
    procedure tmrDelayedTimer(Sender: TObject);
  private
    FCounter: Integer;
    FActionRuns: Integer;
    FDelayedRuns: Integer;
  end;

var
  frmMain: TfrmMain;


implementation

{$R *.dfm}


procedure TfrmMain.btnIncrementClick(Sender: TObject);
begin
  Inc(FCounter);
  lblCounter.Caption := IntToStr(FCounter);
end;


procedure TfrmMain.edtNameChange(Sender: TObject);
begin
  lblNameEcho.Caption := edtName.Text;
end;


// Raises a native Win32 modal dialog: the main thread now spins in MessageBox's own modal
// loop, so this OnClick never returns until the dialog closes. The component tools cannot
// see this dialog (it has no TComponent) — dismiss_dialog reaches it through Win32.
procedure TfrmMain.btnDialogClick(Sender: TObject);
begin
  Application.MessageBox('A native modal dialog is up. The main thread is blocked in its modal loop.',
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


end.
