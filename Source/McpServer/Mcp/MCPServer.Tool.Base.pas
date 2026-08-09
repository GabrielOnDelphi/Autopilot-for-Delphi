UNIT MCPServer.Tool.Base;

(*=====================================================
   2026.05.19
   GabrielMoraru.com / SciVance Tech

   ┌──────────────────────────────────────┐
   │  WINDOWS  (PC-side MCP server)       │   runs in Autopilot.Mcp.exe; target may be any platform
   └──────────────────────────────────────┘

   The two base shapes our nine tool units inherit from:

     TMCPToolBase                — non-generic. Tools that don't have a typed
                                   params class can subclass this and override
                                   BuildSchema and Execute by hand. Unused by
                                   the bridge tools today, kept for future
                                   tools that take no parameters.

     TMCPToolBase<T: class,
                  constructor>   — generic. Inherits IMCPTool, owns a T-shaped
                                   params class with RTTI annotations. Override
                                   ExecuteWithParams to do the work. Execute()
                                   does the deserialize->dispatch->return-string
                                   wiring on your behalf.

   IMCPTool.Execute returns a plain String (a JSON string in practice — the
   dispatcher wraps it into the MCP tools/call content[] array). GDK had a
   TValue return because of an unused second generic variant; we dropped that.
   None of the nine tool units reference Execute or TValue directly — they
   only override ExecuteWithParams — so this is a safe simplification.

   No threads. RTTI walking happens on whatever thread DispatchLine runs on
   (the stdio thread today). Tool instances are cached by the dispatcher.

   Stdlib only.
=====================================================*)

INTERFACE

USES
  System.JSON;

TYPE
  /// What the JSON-RPC dispatcher sees. Each tool advertises Name / Description /
  /// InputSchema (used by tools/list) and runs via Execute (used by tools/call).
  IMCPTool = INTERFACE
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    FUNCTION GetName: String;
    FUNCTION GetTitle: String;
    FUNCTION GetDescription: String;
    FUNCTION GetInputSchema: TJSONObject;
    FUNCTION Execute(CONST AArguments: TJSONObject): String;

    PROPERTY Name        : String       READ GetName;
    PROPERTY Title       : String       READ GetTitle;
    PROPERTY Description : String       READ GetDescription;
    PROPERTY InputSchema : TJSONObject  READ GetInputSchema;
  END;

  /// Non-generic base. For tools without a typed params class. Override
  /// BuildSchema (returns the inputSchema JSON object) and Execute (does
  /// the work and returns the result string).
  TMCPToolBase = CLASS(TInterfacedObject, IMCPTool)
  PROTECTED
    FName        : String;
    FTitle       : String;
    FDescription : String;
    FUNCTION BuildSchema: TJSONObject; VIRTUAL; ABSTRACT;
  PUBLIC
    CONSTRUCTOR Create; VIRTUAL;

    FUNCTION GetName: String;
    FUNCTION GetTitle: String;
    FUNCTION GetDescription: String;
    FUNCTION GetInputSchema: TJSONObject;
    FUNCTION Execute(CONST AArguments: TJSONObject): String; VIRTUAL; ABSTRACT;
  END;

  /// Generic base used by all nine bridge tools. T is the params class — a plain
  /// TObject descendant with published / public writable properties marked with
  /// [Optional] and [SchemaDescription]. Schema and deserialization both come for
  /// free; the subclass only needs to set FName/FDescription in its constructor
  /// and override ExecuteWithParams.
  TMCPToolBase<T: CLASS, CONSTRUCTOR> = CLASS(TInterfacedObject, IMCPTool)
  PROTECTED
    FName        : String;
    FTitle       : String;
    FDescription : String;
    FUNCTION ExecuteWithParams(CONST AParams: T): String; VIRTUAL; ABSTRACT;
  PUBLIC
    CONSTRUCTOR Create; VIRTUAL;

    FUNCTION GetName: String;
    FUNCTION GetTitle: String;
    FUNCTION GetDescription: String;
    FUNCTION GetInputSchema: TJSONObject;
    FUNCTION Execute(CONST AArguments: TJSONObject): String;
  END;


IMPLEMENTATION

USES
  System.SysUtils,
  MCPServer.Schema.Generator,
  MCPServer.Serializer;


{ TMCPToolBase }

CONSTRUCTOR TMCPToolBase.Create;
BEGIN
  inherited Create;
END;

FUNCTION TMCPToolBase.GetName: String;
BEGIN
  Result := FName;
END;

FUNCTION TMCPToolBase.GetTitle: String;
BEGIN
  // If the subclass didn't set a separate title, fall back to the name so the
  // tools/list response always has a usable label.
  if FTitle <> ''
    then Result := FTitle
    else Result := FName;
END;

FUNCTION TMCPToolBase.GetDescription: String;
BEGIN
  Result := FDescription;
END;

FUNCTION TMCPToolBase.GetInputSchema: TJSONObject;
BEGIN
  Result := BuildSchema;
END;


{ TMCPToolBase<T> }

CONSTRUCTOR TMCPToolBase<T>.Create;
BEGIN
  inherited Create;
END;

FUNCTION TMCPToolBase<T>.GetName: String;
BEGIN
  Result := FName;
END;

FUNCTION TMCPToolBase<T>.GetTitle: String;
BEGIN
  if FTitle <> ''
    then Result := FTitle
    else Result := FName;
END;

FUNCTION TMCPToolBase<T>.GetDescription: String;
BEGIN
  Result := FDescription;
END;

FUNCTION TMCPToolBase<T>.GetInputSchema: TJSONObject;
BEGIN
  Result := TMCPSchemaGenerator.GenerateSchema(T);
END;

FUNCTION TMCPToolBase<T>.Execute(CONST AArguments: TJSONObject): String;
VAR
  Params: T;
BEGIN
  // GDK invariant: a fresh params instance per call. Each tool unit's
  // ExecuteWithParams just reads fields, no shared state.
  Params := TMCPSerializer.Deserialize<T>(AArguments);
  TRY
    Result := ExecuteWithParams(Params);
  FINALLY
    Params.Free;
  END;
END;


END.
