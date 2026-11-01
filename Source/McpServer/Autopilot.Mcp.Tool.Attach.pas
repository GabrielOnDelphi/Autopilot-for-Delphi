unit Autopilot.Mcp.Tool.Attach;

{=============================================================================================================
   2026.09
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
    [SchemaDescription('Process ID to check. Omit to list all targets.')]
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
  MCPServer.Registration,
  Autopilot.Mcp.TargetMode,
  Autopilot.Mcp.ToolBase;


{ The next step for an empty target list - the answer a new user's first session gets.
  AFilter = the pid asked for (0 = none); ARunning = how many targets run in total. }
function EmptyListHint(AFilter: Cardinal; ARunning: Integer): String;
begin
  if CurrentTargetMode = tmAdbSocket
  then Result := 'attach lists Windows targets only. This server drives the Android target on 127.0.0.1:' + IntToStr(AdbHostPort) + ' directly: call the tool you need.'
  else
    if (AFilter <> 0) and (ARunning > 0)
    then Result := 'No Autopilot target with pid ' + UIntToStr(AFilter) + ' is running, but ' + IntToStr(ARunning) + ' other target(s) are. Call attach without pid to list them.'
    else Result := 'No running Autopilot target was found. Either the target app is not running (start it), ' + 'or it was built without the Autopilot bridge (link it in with the steps in "setup").';
end;


constructor TAttachTool.Create;
begin
  inherited;
  FName := 'attach';
  FDescription := 'List active Autopilot targets, or verify a specific PID is reachable. ' + 'The answer always carries "setup": the steps to link the bridge into a Delphi app.';
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
    if (Filter = 0) or (Targets[i].Pid = Filter) then
      begin
        Item := TJSONObject.Create;
        Item.AddPair('pid', TJSONNumber.Create(Targets[i].Pid));
        Item.AddPair('pipe', Targets[i].PipeName);
        Arr.AddElement(Item);
      end;

  Root := TJSONObject.Create;
  try
    Root.AddPair('targets', Arr);
    Root.AddPair('count', TJSONNumber.Create(Arr.Count));
    if Arr.Count = 0
    then Root.AddPair('hint', EmptyListHint(Filter, Length(Targets)));
    // Always, also when targets run: "wire Autopilot into this project" is asked while another bridge app (the demo) is running, and the server instructions no longer carry the steps.
    Root.AddPair('setup', BridgeWiringSteps);
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
    end);


end.
