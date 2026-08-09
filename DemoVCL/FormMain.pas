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
    PROCEDURE btnIncrementClick(Sender: TObject);
    PROCEDURE edtNameChange(Sender: TObject);
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


END.
