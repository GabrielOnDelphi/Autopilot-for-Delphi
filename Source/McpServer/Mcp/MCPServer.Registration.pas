UNIT MCPServer.Registration;

(*=====================================================
   2026.05.19
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   Name -> factory map for tool registration. Each Autopilot.Mcp.Tool.* unit
   registers a factory in its INITIALIZATION section by calling
       TMCPRegistry.RegisterTool('name', function: IMCPTool begin ... end);
   The JSON-RPC dispatcher pulls the factory back out on first use, instantiates
   one IMCPTool per name, and caches that instance for the server's lifetime.

   Generic surface: only the inner TDictionary, which is the natural fit for a
   name -> ref-to-function map (per the project's "generics where forced" rule).
   The public API surface is generics-free.

   Lifetime: class destructor frees the dictionary so we don't need a
   finalization section (project rule).
=====================================================*)

INTERFACE

USES
  MCPServer.Tool.Base;

TYPE
  /// Each tool unit hands us one of these. We call it (at most) once per tool
  /// name to create the cached IMCPTool. Capturing locals is fine; the produced
  /// IMCPTool owns its state.
  TMCPToolFactory = REFERENCE TO FUNCTION: IMCPTool;

  TMCPRegistry = CLASS
  PUBLIC
    CLASS PROCEDURE RegisterTool(CONST AName: String; AFactory: TMCPToolFactory);
    CLASS FUNCTION  CreateTool(CONST AName: String): IMCPTool;
    CLASS FUNCTION  HasTool(CONST AName: String): Boolean;
    CLASS FUNCTION  GetToolNames: TArray<String>;
    /// For unit tests. Production code never calls this.
    CLASS PROCEDURE Clear;

    CLASS DESTRUCTOR Destroy;
  END;


IMPLEMENTATION

USES
  System.SysUtils,
  System.Generics.Collections,
  Autopilot.Bridge.Log;


VAR
  GFactories: TDictionary<String, TMCPToolFactory> = NIL;


/// Lazy-create the singleton. We deliberately avoid an initialization
/// section so the create order doesn't matter (project rule).
PROCEDURE EnsureMap;
BEGIN
  if GFactories = NIL then
    GFactories := TDictionary<String, TMCPToolFactory>.Create;
END;


CLASS PROCEDURE TMCPRegistry.RegisterTool(CONST AName: String; AFactory: TMCPToolFactory);
BEGIN
  EnsureMap;
  GFactories.AddOrSetValue(AName, AFactory);
  BridgeLogInfo('mcp', 'registered tool: ' + AName);
END;


CLASS FUNCTION TMCPRegistry.CreateTool(CONST AName: String): IMCPTool;
VAR
  Factory: TMCPToolFactory;
BEGIN
  EnsureMap;
  if not GFactories.TryGetValue(AName, Factory) then
    raise Exception.CreateFmt('Tool not registered: %s', [AName]);
  Result := Factory();
END;


CLASS FUNCTION TMCPRegistry.HasTool(CONST AName: String): Boolean;
BEGIN
  EnsureMap;
  Result := GFactories.ContainsKey(AName);
END;


CLASS FUNCTION TMCPRegistry.GetToolNames: TArray<String>;
BEGIN
  EnsureMap;
  Result := GFactories.Keys.ToArray;
END;


CLASS PROCEDURE TMCPRegistry.Clear;
BEGIN
  if GFactories <> NIL then
    GFactories.Clear;
END;


CLASS DESTRUCTOR TMCPRegistry.Destroy;
BEGIN
  FreeAndNil(GFactories);
END;


END.
