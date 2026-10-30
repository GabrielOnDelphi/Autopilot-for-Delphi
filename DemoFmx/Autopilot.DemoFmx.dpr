PROGRAM Autopilot.DemoFmx;

(*=====================================================
   2026.06.10 — Android64 target added (Phase B). Same source, same StartBridge
                call: on Android the bridge listens on an AF_UNIX abstract socket.
   2026.05.14
   Autopilot demo target — FMX.

   Mirrors Autopilot.Demo.dpr (VCL) but uses the FMX twin of the bridge.
   Purpose: exercise Autopilot.Bridge.Fmx end-to-end. Same control names
   as the VCL demo so the same MCP-tool invocations work.

   Adds a TCheckBox (cbxFlag) the VCL demo lacks — checked toggle exercises
   the FMX-specific `IsChecked` property (FMX uses IsChecked, VCL uses Checked).

   AUTOPILOT must be in the project's conditional defines — otherwise StartBridge
   is a no-op and the bridge units only contribute their INTERFACE.
=====================================================*)

USES
  FMX.Forms,
  FormFmxMain                 in 'FormFmxMain.pas' {frmFmxMain},
  Autopilot.Bridge.Core      in '..\Source\Bridge\Autopilot.Bridge.Core.pas',
  Autopilot.Bridge.Log       in '..\Source\Bridge\Autopilot.Bridge.Log.pas',
  Autopilot.Bridge.Fmx       in '..\Source\Bridge\Autopilot.Bridge.Fmx.pas';
  // NamedPipe (Windows) / Socket (Android) and the shared Worker are pulled in
  // transitively by Autopilot.Bridge.Fmx per platform — listing the Win32-only
  // NamedPipe here would break the Android build.

{$R *.res}

BEGIN
  Application.Initialize;
  Application.CreateForm(TfrmFmxMain, frmFmxMain);
  Autopilot.Bridge.Fmx.StartBridge;
  Application.Run;
END.
