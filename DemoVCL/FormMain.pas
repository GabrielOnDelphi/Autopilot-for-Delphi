UNIT FormMain;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   Demo form for the Autopilot bridge.
   Minimal surface — one form, four controls. Enough to exercise list_tree,
   click, get_text end-to-end. The bigger plan in Plans/03_DemoApp.md adds
   more controls in Phase 2.
=====================================================*)

INTERFACE

USES
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls;

TYPE
  TfrmMain = CLASS(TForm)
    btnIncrement: TButton;
    lblCounter  : TLabel;
    edtName     : TEdit;
    lblNameEcho : TLabel;
    lblHeader   : TLabel;
    btnDialog   : TButton;
    PROCEDURE btnIncrementClick(Sender: TObject);
    PROCEDURE edtNameChange(Sender: TObject);
    PROCEDURE btnDialogClick(Sender: TObject);
  PRIVATE
    FCounter: Integer;
  END;

VAR
  frmMain: TfrmMain;


IMPLEMENTATION

{$R *.dfm}


PROCEDURE TfrmMain.btnIncrementClick(Sender: TObject);
BEGIN
  Inc(FCounter);
  lblCounter.Caption := IntToStr(FCounter);
END;


PROCEDURE TfrmMain.edtNameChange(Sender: TObject);
BEGIN
  lblNameEcho.Caption := edtName.Text;
END;


// Raises a native Win32 modal dialog: the main thread now spins in MessageBox's own modal
// loop, so this OnClick never returns until the dialog closes. The component tools cannot
// see this dialog (it has no TComponent) — dismiss_dialog reaches it through Win32.
PROCEDURE TfrmMain.btnDialogClick(Sender: TObject);
BEGIN
  Application.MessageBox('A native modal dialog is up. The main thread is blocked in its modal loop.',
                        'Native Dialog', MB_YESNOCANCEL or MB_ICONWARNING);
END;


END.
