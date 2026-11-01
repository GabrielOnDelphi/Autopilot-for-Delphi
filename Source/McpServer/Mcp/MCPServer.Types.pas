unit MCPServer.Types;

{=============================================================================================================
   2026.11.01
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Protocol constants and the two attributes our tool params classes use,
   plus the two RTTI helpers that the schema generator and the serializer share (so the schema and the argument checks agree).

   Keeps the GDK unit name so the nine Autopilot.Mcp.Tool.* units recompile unchanged.
   We stripped GDK's capability/manager interfaces, response classes, and SchemaEnumAttribute — none are referenced by our code.

   Stdlib only.
=============================================================================================================}

interface

uses
  System.Rtti;

const
  { Latest MCP protocol version we implement.
    The dispatcher's initialize handler echoes the client's requested version when it's in our supported list, otherwise returns this.
    See modelcontextprotocol.io/specification/versioning (current as of 2026-05). }
  MCP_PROTOCOL_VERSION = '2025-11-25';

type
  { Marks a published property on a tool's params class as not-required in the generated JSON Schema.
    Default is "required" — no attribute means required. }
  OptionalAttribute = class(TCustomAttribute)
  end;

  { Carries the human-readable description for a single property.
    Lands in the generated JSON Schema as properties.<name>.description so Claude sees it when listing tools. }
  SchemaDescriptionAttribute = class(TCustomAttribute)
  private
    FDescription: String;
  public
    constructor Create(const ADescription: String);
    property Description: String read FDescription;
  end;


{ TRUE when AProp carries [Optional].
  A property without it is required: the schema lists it under "required", and TMCPSerializer.FillObject refuses arguments that leave it out or send null. }
function IsOptionalProperty(AProp: TRttiProperty): Boolean;

// The names of AType's values, in ordinal order.
function EnumValueNames(AType: TRttiEnumerationType): TArray<String>;


implementation

uses
  System.TypInfo;


function IsOptionalProperty(AProp: TRttiProperty): Boolean;
var
  Attr: TCustomAttribute;
begin
  for Attr in AProp.GetAttributes do
    if Attr is OptionalAttribute then EXIT(TRUE);
  Result := FALSE;
end;


function EnumValueNames(AType: TRttiEnumerationType): TArray<String>;
var
  Ordinal: Integer;
begin
  SetLength(Result, AType.MaxValue - AType.MinValue + 1);
  for Ordinal := AType.MinValue to AType.MaxValue do
    Result[Ordinal - AType.MinValue] := GetEnumName(AType.Handle, Ordinal);
end;


constructor SchemaDescriptionAttribute.Create(const ADescription: String);
begin
  inherited Create;
  FDescription := ADescription;
end;


end.
