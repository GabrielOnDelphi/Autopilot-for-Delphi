unit MCPServer.Tool.Base;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   The two base shapes our tool units inherit from:

     TMCPToolBase                — non-generic. Tools that don't have a typed params class can
                                   subclass this and override BuildSchema and Execute by hand.
                                   Unused by the bridge tools today, kept for future tools that
                                   take no parameters.

     TMCPToolBase<T: class,
                  constructor>   — generic. Inherits IMCPTool, owns a T-shaped params class with
                                   RTTI annotations. Override ExecuteWithParams to do the work.
                                   Execute() does the deserialize->dispatch->return-string wiring
                                   on your behalf.

   IMCPTool.Execute returns a plain String (a JSON string in practice — the dispatcher wraps it
   into the MCP tools/call content[] array). GDK had a TValue return because of an unused second
   generic variant; we dropped that. None of the nine tool units reference Execute or TValue
   directly — they only override ExecuteWithParams — so this is a safe simplification.

   No threads. RTTI walking happens on whatever thread DispatchLine runs on (the stdio thread
   today). Tool instances are cached by the dispatcher.

   Stdlib only.
=============================================================================================================}

interface

uses
  System.JSON;

type
  /// What the JSON-RPC dispatcher sees. Each tool advertises Name / Description /
  /// InputSchema (used by tools/list) and runs via Execute (used by tools/call).
  IMCPTool = interface
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    function GetName: String;
    function GetTitle: String;
    function GetDescription: String;
    function GetInputSchema: TJSONObject;
    function Execute(const AArguments: TJSONObject): String;

    property Name        : String       read GetName;
    property Title       : String       read GetTitle;
    property Description : String       read GetDescription;
    property InputSchema : TJSONObject  read GetInputSchema;
  end;

  /// Non-generic base. For tools without a typed params class. Override
  /// BuildSchema (returns the inputSchema JSON object) and Execute (does
  /// the work and returns the result string).
  TMCPToolBase = class(TInterfacedObject, IMCPTool)
  protected
    FName        : String;
    FTitle       : String;
    FDescription : String;
    function BuildSchema: TJSONObject; virtual; abstract;
  public
    constructor Create; virtual;

    function GetName: String;
    function GetTitle: String;
    function GetDescription: String;
    function GetInputSchema: TJSONObject;
    function Execute(const AArguments: TJSONObject): String; virtual; abstract;
  end;

  /// Generic base used by all nine bridge tools. T is the params class — a plain
  /// TObject descendant with published / public writable properties marked with
  /// [Optional] and [SchemaDescription]. Schema and deserialization both come for
  /// free; the subclass only needs to set FName/FDescription in its constructor
  /// and override ExecuteWithParams.
  TMCPToolBase<T: class, constructor> = class(TInterfacedObject, IMCPTool)
  protected
    FName        : String;
    FTitle       : String;
    FDescription : String;
    function ExecuteWithParams(const AParams: T): String; virtual; abstract;
  public
    constructor Create; virtual;

    function GetName: String;
    function GetTitle: String;
    function GetDescription: String;
    function GetInputSchema: TJSONObject;
    function Execute(const AArguments: TJSONObject): String;
  end;


implementation

uses
  System.SysUtils,
  MCPServer.Schema.Generator,
  MCPServer.Serializer;


{ TMCPToolBase }

constructor TMCPToolBase.Create;
begin
  inherited Create;
end;

function TMCPToolBase.GetName: String;
begin
  Result := FName;
end;

function TMCPToolBase.GetTitle: String;
begin
  // If the subclass didn't set a separate title, fall back to the name so the
  // tools/list response always has a usable label.
  if FTitle <> ''
    then Result := FTitle
    else Result := FName;
end;

function TMCPToolBase.GetDescription: String;
begin
  Result := FDescription;
end;

function TMCPToolBase.GetInputSchema: TJSONObject;
begin
  Result := BuildSchema;
end;


{ TMCPToolBase<T> }

constructor TMCPToolBase<T>.Create;
begin
  inherited Create;
end;

function TMCPToolBase<T>.GetName: String;
begin
  Result := FName;
end;

function TMCPToolBase<T>.GetTitle: String;
begin
  if FTitle <> ''
    then Result := FTitle
    else Result := FName;
end;

function TMCPToolBase<T>.GetDescription: String;
begin
  Result := FDescription;
end;

function TMCPToolBase<T>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

function TMCPToolBase<T>.Execute(const AArguments: TJSONObject): String;
var
  Params: T;
begin
  // GDK invariant: a fresh params instance per call. Each tool unit's
  // ExecuteWithParams just reads fields, no shared state.
  Params := TMCPSerializer.Deserialize<T>(AArguments);
  try
    Result := ExecuteWithParams(Params);
  finally
    Params.Free;
  end;
end;


end.
