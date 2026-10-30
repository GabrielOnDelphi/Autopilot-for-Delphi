unit MCPServer.Registration;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Name -> factory map for tool registration. Each Autopilot.Mcp.Tool.* unit registers a factory
   in its initialization section by calling:
       TMCPRegistry.RegisterTool('name', function: IMCPTool begin ... end);
   The JSON-RPC dispatcher pulls the factory back out on first use, instantiates one IMCPTool per
   name, and caches that instance for the server's lifetime.

   Generic surface: only the inner TDictionary, which is the natural fit for a name -> anonymous
   method map (per the project's "generics where forced" rule). The public API surface is
   generics-free.

   Lifetime: class destructor frees the dictionary so we don't need a finalization section
   (project rule).
=============================================================================================================}

interface

uses
  System.Generics.Collections,
  MCPServer.Tool.Base;

type
  /// Each tool unit hands us one of these. We call it (at most) once per tool
  /// name to create the cached IMCPTool. Capturing locals is fine; the produced
  /// IMCPTool owns its state.
  TMCPToolFactory = reference to function: IMCPTool;

  TMCPRegistry = class
  strict private
    /// The name -> factory singleton. A class var (not a unit global) so it is
    /// owned by the class and torn down by the class destructor — same pattern
    /// as TToolCache.FMap in Autopilot.Mcp.JsonRpc.pas.
    class var FFactories: TDictionary<String, TMCPToolFactory>;
    /// Lazy-create the singleton. We deliberately avoid an initialization
    /// section so the create order doesn't matter (project rule).
    class procedure EnsureMap;
  public
    class procedure RegisterTool(const AName: String; AFactory: TMCPToolFactory);
    class function  CreateTool(const AName: String): IMCPTool;
    class function  HasTool(const AName: String): Boolean;
    class function  GetToolNames: TArray<String>;
    /// For unit tests. Production code never calls this.
    class procedure Clear;

    class destructor Destroy;
  end;


implementation

uses
  System.SysUtils,
  Autopilot.Bridge.Log;


class procedure TMCPRegistry.EnsureMap;
begin
  if FFactories = nil then
    FFactories := TDictionary<String, TMCPToolFactory>.Create;
end;


class procedure TMCPRegistry.RegisterTool(const AName: String; AFactory: TMCPToolFactory);
begin
  EnsureMap;
  FFactories.AddOrSetValue(AName, AFactory);
  BridgeLogInfo('mcp', 'registered tool: ' + AName);
end;


class function TMCPRegistry.CreateTool(const AName: String): IMCPTool;
var
  Factory: TMCPToolFactory;
begin
  EnsureMap;
  if not FFactories.TryGetValue(AName, Factory) then
    raise Exception.CreateFmt('Tool not registered: %s', [AName]);
  Result := Factory();
end;


class function TMCPRegistry.HasTool(const AName: String): Boolean;
begin
  EnsureMap;
  Result := FFactories.ContainsKey(AName);
end;


class function TMCPRegistry.GetToolNames: TArray<String>;
begin
  EnsureMap;
  Result := FFactories.Keys.ToArray;
end;


class procedure TMCPRegistry.Clear;
begin
  if FFactories <> nil then
    FFactories.Clear;
end;


class destructor TMCPRegistry.Destroy;
begin
  FreeAndNil(FFactories);
end;


end.
