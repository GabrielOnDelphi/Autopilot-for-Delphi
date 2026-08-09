program BuildDcu;

{ Internal release tool, 2026.06.10. ONE compile produces all five shippable bridge DCUs (AUTOPILOT defined, Release settings) — both framework bridges in a single project, so Core/Log/NamedPipe exist as exactly ONE copy and Vcl.dcu + Fmx.dcu are built against that same copy. Two separate per-framework compiles produce byte-DIFFERING shared DCUs (recorded build metadata differs), which breaks the flat-folder ship invariant; this single-compile form is what makes the invariant hold. SHIP-CHECKLIST.md gives the per-Delphi-version invocation (RSVARS_PATH + DCC_DcuOutput). Never shipped. BuildDcuVcl.dpr / BuildDcuFmx.dpr are the link-verify harnesses for the assembled package folder. }

{$APPTYPE CONSOLE}

uses
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Bridge.Transport,
  Autopilot.Bridge.Worker,
  Autopilot.Bridge.NamedPipe,
  Autopilot.Bridge.Vcl,
  Autopilot.Bridge.Fmx;

begin
  Autopilot.Bridge.Vcl.StartBridge;
  Autopilot.Bridge.Vcl.StopBridge;
  Autopilot.Bridge.Fmx.StartBridge;
  Autopilot.Bridge.Fmx.StopBridge;
end.
