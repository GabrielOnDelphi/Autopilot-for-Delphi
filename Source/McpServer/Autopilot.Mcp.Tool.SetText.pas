UNIT Autopilot.Mcp.Tool.SetText;

(*=====================================================
   2026.05.13
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   MCP tool: set_text
   Writes a control's Text (preferred) or Caption property by path. Refuses if the
   control is disabled, or if the property exists but is read-only.
=====================================================*)

INTERFACE

USES
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Mcp.ToolBase;

TYPE
  TSetTextParams = CLASS
  PRIVATE
    FPath: String;
    FText: String;
    FPid : Integer;
  PUBLIC
    [SchemaDescription('Path to the control. See list_tree for available paths. ' +
                       'Forms: "Form", "Form.Leaf", "Form.A.B.C". Unnamed components: "@TButton#N".')]
    PROPERTY Path: String READ FPath WRITE FPath;

    [SchemaDescription('Value to write to the control''s Text (preferred) or Caption.')]
    PROPERTY Text: String READ FText WRITE FText;

    [Optional]
    [SchemaDescription('Optional PID to disambiguate when multiple targets are active.')]
    PROPERTY Pid: Integer READ FPid WRITE FPid;
  END;

  TSetTextTool = CLASS(TMCPToolBase<TSetTextParams>)
  PROTECTED
    FUNCTION ExecuteWithParams(CONST Params: TSetTextParams): String; OVERRIDE;
  PUBLIC
    CONSTRUCTOR Create; OVERRIDE;
  END;


IMPLEMENTATION

USES
  MCPServer.Registration;


CONSTRUCTOR TSetTextTool.Create;
BEGIN
  inherited;
  FName := 'set_text';
  FDescription := 'Set the Text (preferred) or Caption of a control on a running target form.';
END;


FUNCTION TSetTextTool.ExecuteWithParams(CONST Params: TSetTextParams): String;
VAR
  Args: TJSONObject;
BEGIN
  Args := TJSONObject.Create;
  Args.AddPair('path', Params.Path);
  Args.AddPair('text', Params.Text);
  Result := RunCommandOnTarget(Cardinal(Params.Pid), BuildRequest(1, 'set_text', Args));
END;


INITIALIZATION
  TMCPRegistry.RegisterTool('set_text',
    FUNCTION: IMCPTool
    BEGIN
      Result := TSetTextTool.Create;
    END
  );


END.
