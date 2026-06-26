unit MCPServer.Types;

{=============================================================================================================
   2026.06
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   Protocol constants and the two attributes our tool params classes use.

   Keeps the GDK unit name so the nine Autopilot.Mcp.Tool.* units recompile unchanged. We stripped
   GDK's capability/manager interfaces, response classes, and SchemaEnumAttribute — none are
   referenced by our code.

   Stdlib only.
=============================================================================================================}

interface

const
  /// Latest MCP protocol version we implement. The dispatcher's initialize handler
  /// echoes the client's requested version when it's in our supported list, otherwise
  /// returns this. See modelcontextprotocol.io/specification/versioning (current as of
  /// 2026-05).
  MCP_PROTOCOL_VERSION = '2025-11-25';

type
  /// Marks a published property on a tool's params class as not-required in the
  /// generated JSON Schema. Default is "required" — no attribute means required.
  OptionalAttribute = class(TCustomAttribute)
  end;

  /// Carries the human-readable description for a single property. Lands in the
  /// generated JSON Schema as properties.<name>.description so Claude sees it when
  /// listing tools.
  SchemaDescriptionAttribute = class(TCustomAttribute)
  private
    FDescription: String;
  public
    constructor Create(const ADescription: String);
    property Description: String read FDescription;
  end;


implementation


constructor SchemaDescriptionAttribute.Create(const ADescription: String);
begin
  inherited Create;
  FDescription := ADescription;
end;


end.
