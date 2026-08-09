UNIT MCPServer.Types;

(*=====================================================
   2026.05.19
   GabrielMoraru.com / SciVance Tech

   Protocol constants and the two attributes our tool params classes use.

   Keeps the GDK unit name so the nine Autopilot.Mcp.Tool.* units recompile
   unchanged. We stripped GDK's capability/manager interfaces, response
   classes, and SchemaEnumAttribute — none are referenced by our code.

   Stdlib only.
=====================================================*)

INTERFACE

CONST
  /// Latest MCP protocol version we implement. The dispatcher's initialize handler
  /// echoes the client's requested version when it's in our supported list, otherwise
  /// returns this. See modelcontextprotocol.io/specification/versioning (current as of
  /// 2026-05).
  MCP_PROTOCOL_VERSION = '2025-11-25';

TYPE
  /// Marks a published property on a tool's params class as not-required in the
  /// generated JSON Schema. Default is "required" — no attribute means required.
  OptionalAttribute = CLASS(TCustomAttribute)
  END;

  /// Carries the human-readable description for a single property. Lands in the
  /// generated JSON Schema as properties.<name>.description so Claude sees it when
  /// listing tools.
  SchemaDescriptionAttribute = CLASS(TCustomAttribute)
  PRIVATE
    FDescription: String;
  PUBLIC
    CONSTRUCTOR Create(CONST ADescription: String);
    PROPERTY Description: String READ FDescription;
  END;


IMPLEMENTATION


CONSTRUCTOR SchemaDescriptionAttribute.Create(CONST ADescription: String);
BEGIN
  inherited Create;
  FDescription := ADescription;
END;


END.
