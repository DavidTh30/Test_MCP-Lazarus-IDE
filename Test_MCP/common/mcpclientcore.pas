unit McpClientCore;

{ MCP client over Streamable HTTP (JSON-RPC 2.0 via POST)
  - handles the Mcp-Session-Id / MCP-Protocol-Version headers
  - accepts both application/json and text/event-stream (SSE) replies
  - every request is reported through OnTraffic for logging }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, fphttpclient;

type
  TMcpTrafficEvent = procedure(const ADirection, AText: string) of object;

  EMcpClient = class(Exception);

  { TMcpClient }

  TMcpClient = class
  private
    FUrl: string;
    FTimeout: Integer;
    FSessionId: string;
    FProtocolVersion: string;
    FConnected: Boolean;
    FNextId: Integer;
    FServerInfo: TJSONObject;
    FOnTraffic: TMcpTrafficEvent;
    FLastStatus: Integer;
    FLastMs: Int64;
    FLastContentType: string;
    FRequests: Integer;
    FErrors: Integer;
    FClientName, FClientVersion: string;
    FLastTrafficAt: TDateTime;
    FReconnects: Integer;
    FLastTool: string;
    procedure Traffic(const ADir, AText: string);
    function ExtractJson(const ABody, AContentType: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    { Send a raw body, return the response body (JSON) — used by the Raw tab }
    function PostRaw(const ABody: string; const AMethod: string = 'POST'): string;
    { Send a request (AParams is freed for you), return the whole response object (caller frees) }
    function Request(const AMethod: string; AParams: TJSONObject = nil): TJSONObject;
    { Like Request but returns only "result" (clone) and raises when there is an "error" }
    function Call(const AMethod: string; AParams: TJSONObject = nil): TJSONObject;
    procedure Notify(const AMethod: string; AParams: TJSONObject = nil);
    { initialize + notifications/initialized }
    procedure Connect(const AClientName, AClientVersion: string);
    procedure Disconnect;
    property Url: string read FUrl write FUrl;
    property Timeout: Integer read FTimeout write FTimeout;
    property SessionId: string read FSessionId;
    property ProtocolVersion: string read FProtocolVersion;
    property Connected: Boolean read FConnected;
    property ServerInfo: TJSONObject read FServerInfo; // result of initialize
    property LastStatus: Integer read FLastStatus;
    property LastMs: Int64 read FLastMs;
    property LastContentType: string read FLastContentType;
    property Requests: Integer read FRequests;
    property Errors: Integer read FErrors;
    property LastTrafficAt: TDateTime read FLastTrafficAt;
    { Last tool called through this connection (set by the caller, shown on the Topology link) }
    property LastTool: string read FLastTool write FLastTool;
    property Reconnects: Integer read FReconnects;
    property OnTraffic: TMcpTrafficEvent read FOnTraffic write FOnTraffic;
  end;

const
  MCP_CLIENT_PROTOCOL = '2025-06-18';

implementation

{ TMcpClient }

constructor TMcpClient.Create;
begin
  FUrl := 'http://127.0.0.1:8765/mcp';
  FTimeout := 10000;
  FNextId := 1;
end;

destructor TMcpClient.Destroy;
begin
  FServerInfo.Free;
  inherited Destroy;
end;

procedure TMcpClient.Traffic(const ADir, AText: string);
begin
  if Assigned(FOnTraffic) then FOnTraffic(ADir, AText);
end;

function TMcpClient.ExtractJson(const ABody, AContentType: string): string;
var
  SL: TStringList;
  I: Integer;
  Line, Data: string;
begin
  if Pos('text/event-stream', LowerCase(AContentType)) = 0 then
    Exit(ABody);
  // SSE: take the data: of the last event that has data
  Result := '';
  Data := '';
  SL := TStringList.Create;
  try
    SL.Text := ABody;
    for I := 0 to SL.Count - 1 do
    begin
      Line := SL[I];
      if Pos('data:', Line) = 1 then
        Data := Data + TrimLeft(Copy(Line, 6, MaxInt))
      else if (Trim(Line) = '') and (Data <> '') then
      begin
        Result := Data;
        Data := '';
      end;
    end;
    if Data <> '' then Result := Data;
  finally
    SL.Free;
  end;
end;

function TMcpClient.PostRaw(const ABody: string; const AMethod: string): string;
var
  Http: TFPHTTPClient;
  Req, Resp: TStringStream;
  T0: QWord;
  Sid: string;
begin
  Inc(FRequests);
  Http := TFPHTTPClient.Create(nil);
  Req := TStringStream.Create(ABody);
  Resp := TStringStream.Create('');
  try
    Http.ConnectTimeout := FTimeout;
    Http.IOTimeout := FTimeout;
    Http.AddHeader('Content-Type', 'application/json');
    Http.AddHeader('Accept', 'application/json, text/event-stream');
    if FProtocolVersion <> '' then Http.AddHeader('MCP-Protocol-Version', FProtocolVersion);
    if FSessionId <> '' then Http.AddHeader('Mcp-Session-Id', FSessionId);
    if ABody <> '' then Http.RequestBody := Req;

    Traffic('>>', AMethod + ' ' + FUrl + LineEnding + ABody);
    T0 := GetTickCount64;
    try
      Http.HTTPMethod(AMethod, FUrl, Resp, []); // accept every status code
    except
      on E: Exception do
      begin
        FLastMs := GetTickCount64 - T0;
        FLastStatus := 0;
        Inc(FErrors);
        Traffic('!!', E.ClassName + ': ' + E.Message);
        raise EMcpClient.Create('HTTP error: ' + E.Message);
      end;
    end;
    FLastMs := GetTickCount64 - T0;
    FLastStatus := Http.ResponseStatusCode;
    FLastTrafficAt := Now;
    FLastContentType := TFPHTTPClient.GetHeader(Http.ResponseHeaders, 'Content-Type');
    Sid := TFPHTTPClient.GetHeader(Http.ResponseHeaders, 'Mcp-Session-Id');
    if Sid <> '' then FSessionId := Sid;

    Result := ExtractJson(Resp.DataString, FLastContentType);
    Traffic('<<', Format('HTTP %d  %d ms  %s', [FLastStatus, FLastMs, FLastContentType]) +
      LineEnding + Result);
    if (FLastStatus < 200) or (FLastStatus >= 300) then Inc(FErrors);
  finally
    Resp.Free;
    Req.Free;
    Http.Free;
  end;
end;

function TMcpClient.Request(const AMethod: string; AParams: TJSONObject): TJSONObject;
var
  Msg: TJSONObject;
  Body: string;
  Data: TJSONData;
begin
  Msg := TJSONObject.Create(['jsonrpc', '2.0', 'id', FNextId, 'method', AMethod]);
  Inc(FNextId);
  try
    if AParams <> nil then
    begin
      Msg.Add('params', AParams);
      AParams := nil;
    end;
    Body := PostRaw(Msg.AsJSON);
    // 404 + session = server restarted / session expired -> initialize again and retry
    if (FLastStatus = 404) and (FSessionId <> '') and (AMethod <> 'initialize') then
    begin
      Traffic('..', 'session expired -> re-initialize');
      Inc(FReconnects);
      Connect(FClientName, FClientVersion);
      Body := PostRaw(Msg.AsJSON);
    end;
  finally
    AParams.Free;
    Msg.Free;
  end;

  if (FLastStatus < 200) or (FLastStatus >= 300) then
    raise EMcpClient.CreateFmt('HTTP %d from server', [FLastStatus]);
  if Trim(Body) = '' then
    raise EMcpClient.Create('Empty response');
  Data := GetJSON(Body);
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise EMcpClient.Create('Response is not a JSON object');
  end;
  Result := TJSONObject(Data);
end;

function TMcpClient.Call(const AMethod: string; AParams: TJSONObject): TJSONObject;
var
  Resp: TJSONObject;
  Err: TJSONData;
begin
  Resp := Request(AMethod, AParams);
  try
    Err := Resp.Find('error');
    if Err <> nil then
    begin
      Inc(FErrors);
      if Err is TJSONObject then
        raise EMcpClient.CreateFmt('RPC error %d: %s',
          [TJSONObject(Err).Get('code', 0), TJSONObject(Err).Get('message', '')])
      else
        raise EMcpClient.Create('RPC error: ' + Err.AsJSON);
    end;
    if Resp.Find('result', jtObject) = nil then
      raise EMcpClient.Create('Response has no result');
    Result := TJSONObject(Resp.Objects['result'].Clone);
  finally
    Resp.Free;
  end;
end;

procedure TMcpClient.Notify(const AMethod: string; AParams: TJSONObject);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create(['jsonrpc', '2.0', 'method', AMethod]);
  try
    if AParams <> nil then Msg.Add('params', AParams);
    PostRaw(Msg.AsJSON);
  finally
    Msg.Free;
  end;
end;

procedure TMcpClient.Connect(const AClientName, AClientVersion: string);
var
  Res: TJSONObject;
begin
  Disconnect;
  FClientName := AClientName;
  FClientVersion := AClientVersion;
  Res := Call('initialize', TJSONObject.Create([
    'protocolVersion', MCP_CLIENT_PROTOCOL,
    'capabilities', TJSONObject.Create,
    'clientInfo', TJSONObject.Create(['name', AClientName, 'version', AClientVersion])]));
  FServerInfo := Res;
  FProtocolVersion := Res.Get('protocolVersion', MCP_CLIENT_PROTOCOL);
  FConnected := True;
  Notify('notifications/initialized');
end;

procedure TMcpClient.Disconnect;
begin
  if FConnected and (FSessionId <> '') then
    try
      PostRaw('', 'DELETE'); // close the session (if the server uses sessions)
    except
      // ignore
    end;
  FConnected := False;
  FSessionId := '';
  FProtocolVersion := '';
  FreeAndNil(FServerInfo);
end;

end.
