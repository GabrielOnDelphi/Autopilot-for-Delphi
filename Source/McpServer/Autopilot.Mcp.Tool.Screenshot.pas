unit Autopilot.Mcp.Tool.Screenshot;

{=============================================================================================================
   2026.10.12
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - MCP tool: screenshot
   - Captures a form as a PNG. Form name optional; defaults to the target's main form.
   - Optional path crops the image to one control; optional maxWidth scales it down (both done in the bridge).
   - The bridge answers with the PNG as base64 in result.image. ExtractImage moves it out, so the tools/call
     result is an MCP image content block (which a host shows as a picture), followed by a text block with
     the rest of the bridge's answer: form, width, height, licenseNotice and any other field, but no base64.
     Until 1.1.0 the base64 went out inside the text block: the model never saw a picture, and a 64 KB
     result was written to a file instead (Kai, 2026-08-25).
   - Runs in Autopilot.Mcp.exe (Windows PC-side MCP server); target may be any platform.
=============================================================================================================}

interface

uses
  System.SysUtils, System.JSON,
  MCPServer.Tool.Base, MCPServer.Types,
  Autopilot.Bridge.Core,
  Autopilot.Mcp.ToolBase;

type
  TScreenshotParams = class
  private
    FForm    : String;
    FPid     : Integer;
    FPath    : String;
    FMaxWidth: Integer;
  public
    [Optional]
    [SchemaDescription('Form name. Omit for the main form. Ignored when path is given.')]
    property Form: String read FForm write FForm;

    [Optional]
    [SchemaDescription('Target PID. Needed only when several targets run.')]
    property Pid: Integer read FPid write FPid;

    [Optional]
    [SchemaDescription('Control path from list_tree. Crops the image to that control, children included.')]
    property Path: String read FPath write FPath;

    [Optional]
    [SchemaDescription('Scale a wider image down to this width in pixels, aspect kept. 0 or omitted = full size.')]
    property MaxWidth: Integer read FMaxWidth write FMaxWidth;
  end;

  TScreenshotTool = class(TMCPToolBase<TScreenshotParams>)
  protected
    function ExecuteWithParams(const Params: TScreenshotParams): String; override;
  public
    constructor Create; override;
    function ExtractImage(var AText: String; OUT AImageBase64, AMimeType: String): Boolean; override;
  end;


implementation

uses
  MCPServer.Registration;


constructor TScreenshotTool.Create;
begin
  inherited;
  FName := 'screenshot';
  FDescription := 'Capture a form, or one control of it, as a PNG image.';
end;


function TScreenshotTool.ExecuteWithParams(const Params: TScreenshotParams): String;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('form', Params.Form);
  // Forwarded only when given, so a call without them is the request every older server sent.
  // A negative maxWidth is forwarded too: the bridge answers it with -32600.
  if Params.Path <> ''
  then Args.AddPair('path', Params.Path);
  if Params.MaxWidth <> 0
  then Args.AddPair('maxWidth', TJSONNumber.Create(Params.MaxWidth));
  // Per-command default of 30 s lives on the bridge side (DefaultTimeoutScreenshotMs).
  Result := RunCommandOnTarget(Cardinal(Params.Pid),
                               BuildRequest(1, 'screenshot', Args),
                               DefaultTimeoutScreenshotMs);
end;


// AText without the characters base64 does not use. The bridge encodes with TNetEncoding.Base64, which puts a
// CRLF after every 76 characters (System.NetEncoding.pas, TCustomBase64Encoding.kCharsPerLine / kLineSeparator).
function StripBase64Breaks(const AText: String): String;
var
  i, n: Integer;
begin
  SetLength(Result, Length(AText));
  n := 0;
  for i := 1 to Length(AText) do
    if AText[i] > ' ' then
    begin
      Inc(n);
      Result[n] := AText[i];
    end;
  SetLength(Result, n);
end;


// AText is the bridge's answer: {"id":..,"ok":true,"result":{"form":..,"width":..,"height":..,
// "encoding":"base64","format":"png","image":"<base64>"}}, plus "licenseNotice" on the first answer of
// an installation. Only "image" leaves AText. FALSE (AText untouched) for any answer without a picture,
// a failed capture or a -3209x envelope among them.
function TScreenshotTool.ExtractImage(var AText: String; OUT AImageBase64, AMimeType: String): Boolean;
var
  Root, Res, V: TJSONValue;
  ImagePair: TJSONPair;
  ImageFormat: String;
begin
  AImageBase64 := '';
  AMimeType    := '';
  Root := TJSONObject.ParseJSONValue(AText);
  try
    if not (Root is TJSONObject) then EXIT(FALSE);
    Res := TJSONObject(Root).GetValue('result');
    if not (Res is TJSONObject) then EXIT(FALSE);
    V := TJSONObject(Res).GetValue('image');
    if not (V is TJSONString) then EXIT(FALSE);
    AImageBase64 := StripBase64Breaks(TJSONString(V).Value);
    if AImageBase64 = '' then EXIT(FALSE);

    V := TJSONObject(Res).GetValue('format');
    if V is TJSONString
    then ImageFormat := LowerCase(TJSONString(V).Value)
    else ImageFormat := 'png';
    AMimeType := 'image/' + ImageFormat;

    ImagePair := TJSONObject(Res).RemovePair('image');   // RemovePair hands the pair to the caller
    FreeAndNil(ImagePair);
    AText := Root.ToJSON;
    Result := TRUE;
  finally
    FreeAndNil(Root);
  end;
end;


initialization
  TMCPRegistry.RegisterTool('screenshot',
    function: IMCPTool
    begin
      Result := TScreenshotTool.Create;
    end
  );


end.
