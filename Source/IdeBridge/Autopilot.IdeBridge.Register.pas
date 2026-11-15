UNIT Autopilot.IdeBridge.Register;

{=============================================================================================================
   2026.11.14
   GabrielMoraru.com/autopilot
--------------------------------------------------------------------------------------------------------------
   Loads the Autopilot VCL bridge into the Delphi IDE (bds.exe), so the Autopilot MCP tools can drive the IDE itself.
   Install the design-time package Autopilot.IdeBridge; the IDE calls Register, which starts the bridge.

   The pipe is named after bds.exe and its PID (Autopilot.Bridge.NamedPipe), and list_tree shows the IDE's own forms:
   a design-time package shares vcl370.bpl with the IDE, so Application and Screen are the IDE's.

   StartBridge does nothing when the bridge already runs, so a second Register call is harmless.
   No finalization here: the finalization of Autopilot.Bridge.Vcl calls StopBridge when the package unloads,
   and the finalization of Autopilot.IdeBridge.Commands removes the ide.* commands.
=============================================================================================================}

INTERFACE

procedure Register;

IMPLEMENTATION

USES
  Autopilot.Bridge.Vcl, Autopilot.IdeBridge.Commands;


procedure Register;
begin
  Autopilot.Bridge.Vcl.StartBridge;
  RegisterIdeCommands;   // the ide.* commands of call_method; registering again replaces them
end;


END.
