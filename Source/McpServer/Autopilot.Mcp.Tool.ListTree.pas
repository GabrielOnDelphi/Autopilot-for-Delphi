UNIT Autopilot.Mcp.Tool.ListTree;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: list_tree
   Enumerates every form + component in the target app. Returns the bridge's
   raw JSON response as a string so the AI sees the full payload.
=====================================================*)

INTERFACE

USES
  System.SysUtils,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TListTreeParams = CLASS
  PRIVATE
    FPid: Integer;
  PUBLIC
    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TListTreeTool = CLASS(TMCPToolBase<TListTreeParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TListTreeParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TListTreeTool.Create;
BEGIN
  inherited;
  FName := 'list_tree';
  FDescription :=
    'Enumerate every form and component in the running target Delphi app. ' +
    'Returns a flat array at result.components; each node has form, name, path, class, ' +
    'plus optional text, enabled, visible, and synthetic. ' +
    'Walks containers recursively (frames, panels with owned children), so deep ' +
    'forms can yield many nodes. Path forms accepted by click/get_text/set_text/set_checked/wait_for: ' +
    '"Form" (the form itself), "Form.Leaf" (BFS shallow-wins recursive search), ' +
    '"Form.A.B.C" (anchored — each segment is a direct child of the previous). ' +
    'Unnamed components show up as "@TButton#N" (N = ComponentIndex in owner); ' +
    'prefer anchored paths for synthetic IDs since the index is owner-relative.';
END;


FUNCTION TListTreeTool.ExecuteWithParams(CONST Params: TListTreeParams): String;
BEGIN
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'list_tree', NIL));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('list_tree',
    FUNCTION: IMCPTool
    BEGIN
      Result := TListTreeTool.Create;
    END
  );


END.
