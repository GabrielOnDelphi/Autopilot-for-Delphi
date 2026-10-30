PROGRAM Autopilot.Demo;

(*=====================================================
   2026.05.12
   Autopilot demo target — VCL.

   Drops two lines into a regular VCL project:
     1. Add Autopilot.Bridge.Vcl (and friends) to USES
     2. Call Autopilot.Bridge.Vcl.StartBridge after Application.CreateForm

   AUTOPILOT must be in the project's conditional defines — otherwise StartBridge
   is a no-op and the bridge units only contribute their (always-compiling) INTERFACE.

   Step by step, with an AI driving this demo: the book "Delphi in All Its Glory" Part 5,
   "AI-Assisted Development for Delphi", chapter "We Need a Hero - Enter Autopilot for Delphi".
   https://gabrielmoraru.com/the-delphi-in-all-its-glory-book-5-ai-assisted-development-for-delphi/
=====================================================*)

USES
  Vcl.Forms,
  FormMain                    in 'FormMain.pas' {frmMain},
  Autopilot.Bridge.Core      in '..\Source\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.NamedPipe in '..\Source\Bridge\Autopilot.Bridge.NamedPipe.pas',
  Autopilot.Bridge.NativeDialogs in '..\Source\Bridge\Autopilot.Bridge.NativeDialogs.pas',
  Autopilot.Bridge.Vcl       in '..\Source\Bridge\Autopilot.Bridge.Vcl.pas';

{$R *.res}

BEGIN
  Application.Initialize;
  Application.MainFormOnTaskbar := TRUE;
  Application.CreateForm(TfrmMain, frmMain);
  Autopilot.Bridge.Vcl.StartBridge;
  Application.Run;
END.
