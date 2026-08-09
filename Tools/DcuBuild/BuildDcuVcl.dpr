program BuildDcuVcl;

{ Internal release tool, 2026.06.10. Compiling this program produces the five shippable bridge DCUs (VCL flavor) with AUTOPILOT defined and Release settings; SHIP-CHECKLIST.md gives the per-Delphi-version invocation (RSVARS_PATH + DCC_DcuOutput). Never shipped. The Start/StopBridge calls force the linker to pull the bridge implementation when link-verifying an already-built DCU set. }

{$APPTYPE CONSOLE}

uses
  Autopilot.Bridge.Core,
  Autopilot.Bridge.Log,
  Autopilot.Bridge.NamedPipe,
  Autopilot.Bridge.Vcl;

begin
  StartBridge;
  StopBridge;
end.
