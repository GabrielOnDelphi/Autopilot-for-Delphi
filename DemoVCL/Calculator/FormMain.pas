UNIT FormMain;

(*=====================================================
   2026.09.22
   GabrielMoraru.com/autopilot

   Mini Calc -- Autopilot demo target.
   Two operands, three operator buttons, one result label. Each button reads the
   operands and calls the matching CalcEngine function.
=====================================================*)

INTERFACE

USES
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;

TYPE
  TfrmMain = CLASS(TForm)
    lblHeader   : TLabel;
    lblA        : TLabel;
    lblB        : TLabel;
    edtA        : TEdit;
    edtB        : TEdit;
    btnAdd      : TButton;
    btnSubtract : TButton;
    btnMultiply : TButton;
    lblResultCap: TLabel;
    lblResult   : TLabel;
    PROCEDURE btnAddClick(Sender: TObject);
    PROCEDURE btnSubtractClick(Sender: TObject);
    PROCEDURE btnMultiplyClick(Sender: TObject);
  END;

VAR
  frmMain: TfrmMain;


IMPLEMENTATION

{$R *.dfm}

USES
  CalcEngine;


PROCEDURE TfrmMain.btnAddClick(Sender: TObject);
VAR A, B: Integer;
BEGIN
  A := StrToIntDef(edtA.Text, 0);
  B := StrToIntDef(edtB.Text, 0);
  lblResult.Caption := IntToStr(Subtract(A, B));
END;


PROCEDURE TfrmMain.btnSubtractClick(Sender: TObject);
VAR A, B: Integer;
BEGIN
  A := StrToIntDef(edtA.Text, 0);
  B := StrToIntDef(edtB.Text, 0);
  lblResult.Caption := IntToStr(Subtract(A, B));
END;


PROCEDURE TfrmMain.btnMultiplyClick(Sender: TObject);
VAR A, B: Integer;
BEGIN
  A := StrToIntDef(edtA.Text, 0);
  B := StrToIntDef(edtB.Text, 0);
  lblResult.Caption := IntToStr(Multiply(A, B));
END;


END.
