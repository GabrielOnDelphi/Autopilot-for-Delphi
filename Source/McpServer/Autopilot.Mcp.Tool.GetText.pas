UNIT Autopilot.Mcp.Tool.GetText;

(*=====================================================
   2026.05.12
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: get_text
   Reads the Text or Caption of a control in the target app.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TGetTextParams = CLASS
  PRIVATE
    FPath: String;
    FPid : Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TGetTextTool = CLASS(TMCPToolBase<TGetTextParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TGetTextParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TGetTextTool.Create;
BEGIN
  inherited;
  FName := 'get_text';
  FDescription := 'Read the Text/Caption of a control in the running target app.';
END;


FUNCTION TGetTextTool.ExecuteWithParams(CONST Params: TGetTextParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'get_text', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('get_text',
    FUNCTION: IMCPTool
    BEGIN
      Result := TGetTextTool.Create;
    END
  );


END.
