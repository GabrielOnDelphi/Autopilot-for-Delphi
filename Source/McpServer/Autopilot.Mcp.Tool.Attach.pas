UNIT Autopilot.Mcp.Tool.Attach;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: attach
   Lists the active Autopilot targets discovered via %TEMP%\Autopilot\active\.
   Optional pid: also verifies the named pid is alive and pipe is reachable.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.PipeClient;

TYPE
  TAttachParams = CLASS
  PRIVATE
    FPid: Integer;
  PUBLIC
    [Optional]
    [SchemaDescription('Optional process ID. Without it, returns all discovered targets.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TAttachTool = CLASS(TMCPToolBase<TAttachParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TAttachParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TAttachTool.Create;
BEGIN
  inherited;
  FName := 'attach';
  FDescription := 'List active Autopilot targets, or verify a specific PID is reachable.';
END;


FUNCTION TAttachTool.ExecuteWithParams(CONST Params: TAttachParams): String;
VAR
  Targets: TTargetList;
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  i: Integer;
  Filter: Cardinal;
BEGIN
  Targets := ListTargets;
  Filter := Cardinal(Params.Pid);

  Arr := TJSONArray.Create;
  for i := 0 to High(Targets) do
    if (Filter = 0) or (Targets[i].Pid = Filter) then
    begin
      Item := TJSONObject.Create;
      Item.AddPair('pid', TJSONNumber.Create(Targets[i].Pid));
      Item.AddPair('pipe', Targets[i].PipeName);
      Arr.AddElement(Item);
    end;

  Root := TJSONObject.Create;
  TRY
    Root.AddPair('targets', Arr);
    Root.AddPair('count', TJSONNumber.Create(Arr.Count));
    Result := Root.ToJSON;
  FINALLY
    Root.Free;
  END;
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('attach',
    FUNCTION: IMCPTool
    BEGIN
      Result := TAttachTool.Create;
    END
  );


END.
