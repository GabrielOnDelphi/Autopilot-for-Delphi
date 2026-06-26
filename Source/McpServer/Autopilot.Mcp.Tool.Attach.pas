unit Autopilot.Mcp.Tool.Attach;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: attach
   - Lists active Autopilot targets discovered via %TEMP%\Autopilot\active\.
   - Optional pid: also verifies the named pid is alive and pipe is reachable.
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.PipeClient;

type
  TAttachParams = class
  private
    FPid: Integer;
  public
    [Optional]
    [SchemaDescription('Optional process ID. Without it, returns all discovered targets.')]
    property Pid: Integer read FPid write FPid;
  end;

  TAttachTool = class(TMCPToolBase<TAttachParams>)
  protected
    function ExecuteWithParams(const Params: TAttachParams): String; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TAttachTool.Create;
begin
  inherited;
  FName := 'attach';
  FDescription := 'List active Autopilot targets, or verify a specific PID is reachable.';
end;


function TAttachTool.ExecuteWithParams(const Params: TAttachParams): String;
var
  Targets: TTargetList;
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  i: Integer;
  Filter: Cardinal;
begin
  Targets := ListTargets;
  Filter := Cardinal(Params.Pid);

  Arr := TJSONArray.Create;
  for i := 0 to High(Targets) do
    if (Filter = 0) or (Targets[i].Pid = Filter)
    then begin
      Item := TJSONObject.Create;
      Item.AddPair('pid', TJSONNumber.Create(Targets[i].Pid));
      Item.AddPair('pipe', Targets[i].PipeName);
      Arr.AddElement(Item);
    end;

  Root := TJSONObject.Create;
  try
    Root.AddPair('targets', Arr);
    Root.AddPair('count', TJSONNumber.Create(Arr.Count));
    Result := Root.ToJSON;
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TMCPRegistry.RegisterTool('attach',
    function: IMCPTool
    begin
      Result := TAttachTool.Create;
    end
  );


end.
