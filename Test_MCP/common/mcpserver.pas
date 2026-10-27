unit McpServer;

{ MCP (Model Context Protocol) server over Streamable HTTP
  Runs in its own thread, listening on http://<address>:<port><endpoint>
  - tool calls are passed to the main thread (Synchronize) so they can safely touch the LCL
  - every client is identified by Mcp-Session-Id (issued on initialize)
  - GET /node returns the node status (used to build the Topology)
  - log lines are queued (non-blocking) and statistics are kept for the Status window }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DateUtils, fphttpserver, fpjson, jsonparser, McpConfig;

type
  { The user (form) fills AResult: it must contain "content" (array) and may contain "isError" }
  TMcpToolCallEvent = procedure(const AName: string; AArgs: TJSONObject;
    AResult: TJSONObject) of object;
  TMcpToolsListEvent = procedure(ATools: TJSONArray) of object;
  TMcpLogEvent = procedure(const AMsg: string) of object;
  { Must be thread-safe: called from the server thread }
  TMcpNodeInfoFunc = function: string of object;

  TMcpServerState = (msStopped, msStarting, msRunning, msError);

  TMcpStats = record
    State: TMcpServerState;
    StartedAt: TDateTime;
    LastRequestAt: TDateTime;
    HttpRequests: Int64;
    RpcMessages: Int64;
    ToolCalls: Int64;
    Errors: Int64;
    BytesIn: Int64;
    BytesOut: Int64;
    LastMethod: string;
    LastTool: string;
    LastRemote: string;
    ClientName: string;
    ClientVersion: string;
    ProtocolVersion: string;
    LastError: string;
  end;

  { TMcpSession }

  TMcpSession = class
  public
    Id: string;
    ClientName: string;
    ClientVersion: string;
    Remote: string;
    CreatedAt: TDateTime;
    LastSeen: TDateTime;
    Requests: Int64;
    ToolCalls: Int64;
    LastTool: string;
  end;

  TMcpHttpServer = class(TFPHttpServer)
  public
    property Address;
  end;

  { TMcpServerThread }

  TMcpServerThread = class(TThread)
  private
    FServer: TMcpHttpServer;
    FSettings: TMcpSettings;
    FOnToolCall: TMcpToolCallEvent;
    FOnToolsList: TMcpToolsListEvent;
    FOnLog: TMcpLogEvent;
    FOnNodeInfo: TMcpNodeInfoFunc;
    // statistics + sessions (protected by FLock)
    FLock: TCriticalSection;
    FStats: TMcpStats;
    FToolCounts: TStringList;
    FPendingLog: TStringList;
    FSessions: TList;
    // used inside the server thread during one request
    FCurSession: TMcpSession;
    FCurRemote: string;
    FNewSessionId: string;
    // data passed across threads during Synchronize
    FCallName: string;
    FCallClient: string;
    FCallArgs: TJSONObject;
    FCallResult: TJSONObject;
    FToolsArr: TJSONArray;
    procedure DoRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure DoIdle(Sender: TObject);
    function HandleRpc(AMsg: TJSONObject): TJSONObject;
    procedure SyncToolCall;
    procedure SyncToolsList;
    procedure FlushLog;
    procedure Log(const AMsg: string);
    procedure SetState(AState: TMcpServerState; const AError: string = '');
    procedure CountError(const AMsg: string);
    function FindSession(const AId: string): TMcpSession;
    procedure RemoveSession(const AId: string);
    procedure ExpireSessions;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASettings: TMcpSettings);
    destructor Destroy; override;
    { Copy of the current statistics (thread-safe). AToolCounts = name=count }
    procedure GetStats(out AStats: TMcpStats; AToolCounts: TStrings);
    { Connected clients (thread-safe, caller frees) }
    function SessionsJSON: TJSONArray;
    { Stop the server and wait for the thread to finish (call from the main thread) }
    procedure StopAndWait;
    property Settings: TMcpSettings read FSettings;
    { Name of the client that sent the current tool call (readable inside OnToolCall) }
    property CallClient: string read FCallClient;
    property OnToolCall: TMcpToolCallEvent read FOnToolCall write FOnToolCall;
    property OnToolsList: TMcpToolsListEvent read FOnToolsList write FOnToolsList;
    property OnLog: TMcpLogEvent read FOnLog write FOnLog;
    property OnNodeInfo: TMcpNodeInfoFunc read FOnNodeInfo write FOnNodeInfo;
  end;

const
  McpStateNames: array[TMcpServerState] of string =
    ('Stopped', 'Starting', 'Running', 'Error');
  MCP_PROTOCOL_VERSION = '2025-06-18';
  SESSION_EXPIRE_MIN = 30;

{ Helpers to build tool results }
procedure McpAddText(AResult: TJSONObject; const AText: string);
procedure McpAddImage(AResult: TJSONObject; const ABase64, AMime: string);
procedure McpSetError(AResult: TJSONObject; const AText: string);

implementation

function ContentArr(AResult: TJSONObject): TJSONArray;
begin
  Result := AResult.Find('content', jtArray) as TJSONArray;
  if Result = nil then
  begin
    Result := TJSONArray.Create;
    AResult.Add('content', Result);
  end;
end;

procedure McpAddText(AResult: TJSONObject; const AText: string);
begin
  ContentArr(AResult).Add(TJSONObject.Create(['type', 'text', 'text', AText]));
end;

procedure McpAddImage(AResult: TJSONObject; const ABase64, AMime: string);
begin
  ContentArr(AResult).Add(TJSONObject.Create(['type', 'image',
    'data', ABase64, 'mimeType', AMime]));
end;

procedure McpSetError(AResult: TJSONObject; const AText: string);
begin
  McpAddText(AResult, AText);
  AResult.Booleans['isError'] := True;
end;

function RpcError(AId: TJSONData; ACode: Integer; const AMsg: string): TJSONObject;
begin
  Result := TJSONObject.Create(['jsonrpc', '2.0']);
  if AId <> nil then Result.Add('id', AId.Clone) else Result.Add('id', TJSONNull.Create);
  Result.Add('error', TJSONObject.Create(['code', ACode, 'message', AMsg]));
end;

function Shorten(const S: string; AMax: Integer = 2000): string;
begin
  if Length(S) > AMax then
    Result := Copy(S, 1, AMax) + Format('... (%d bytes)', [Length(S)])
  else
    Result := S;
end;

function NewSessionId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(Copy(GUIDToString(G), 2, 36));
end;

{ TMcpServerThread }

constructor TMcpServerThread.Create(const ASettings: TMcpSettings);
begin
  FSettings := ASettings;
  FLock := TCriticalSection.Create;
  FToolCounts := TStringList.Create;
  FPendingLog := TStringList.Create;
  FSessions := TList.Create;
  FillChar(FStats, SizeOf(FStats), 0);
  FStats.State := msStarting;
  FreeOnTerminate := False;
  inherited Create(True);
end;

destructor TMcpServerThread.Destroy;
var
  I: Integer;
begin
  inherited Destroy;
  for I := 0 to FSessions.Count - 1 do TMcpSession(FSessions[I]).Free;
  FSessions.Free;
  FPendingLog.Free;
  FToolCounts.Free;
  FLock.Free;
end;

procedure TMcpServerThread.GetStats(out AStats: TMcpStats; AToolCounts: TStrings);
begin
  FLock.Enter;
  try
    AStats := FStats;
    if AToolCounts <> nil then AToolCounts.Assign(FToolCounts);
  finally
    FLock.Leave;
  end;
end;

function TMcpServerThread.SessionsJSON: TJSONArray;
var
  I: Integer;
  S: TMcpSession;
begin
  Result := TJSONArray.Create;
  FLock.Enter;
  try
    for I := 0 to FSessions.Count - 1 do
    begin
      S := TMcpSession(FSessions[I]);
      Result.Add(TJSONObject.Create([
        'session', Copy(S.Id, 1, 8),
        'client', S.ClientName,
        'version', S.ClientVersion,
        'remote', S.Remote,
        'connectedAt', FormatDateTime('hh:nn:ss', S.CreatedAt),
        'lastSeenAgo', SecondsBetween(Now, S.LastSeen),
        'requests', S.Requests,
        'toolCalls', S.ToolCalls,
        'lastTool', S.LastTool]));
    end;
  finally
    FLock.Leave;
  end;
end;

function TMcpServerThread.FindSession(const AId: string): TMcpSession;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    for I := 0 to FSessions.Count - 1 do
      if TMcpSession(FSessions[I]).Id = AId then
        Exit(TMcpSession(FSessions[I]));
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServerThread.RemoveSession(const AId: string);
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := FSessions.Count - 1 downto 0 do
      if TMcpSession(FSessions[I]).Id = AId then
      begin
        TMcpSession(FSessions[I]).Free;
        FSessions.Delete(I);
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServerThread.ExpireSessions;
var
  I: Integer;
  S: TMcpSession;
begin
  FLock.Enter;
  try
    for I := FSessions.Count - 1 downto 0 do
    begin
      S := TMcpSession(FSessions[I]);
      if MinutesBetween(Now, S.LastSeen) >= SESSION_EXPIRE_MIN then
      begin
        S.Free;
        FSessions.Delete(I);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServerThread.SetState(AState: TMcpServerState; const AError: string);
begin
  FLock.Enter;
  try
    FStats.State := AState;
    if AState = msRunning then FStats.StartedAt := Now;
    if AError <> '' then FStats.LastError := AError;
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServerThread.CountError(const AMsg: string);
begin
  FLock.Enter;
  try
    Inc(FStats.Errors);
    FStats.LastError := AMsg;
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServerThread.Log(const AMsg: string);
begin
  if not Assigned(FOnLog) then Exit;
  FLock.Enter;
  try
    FPendingLog.Add(AMsg);
  finally
    FLock.Leave;
  end;
  Queue(@FlushLog); // does not block the server thread
end;

procedure TMcpServerThread.FlushLog;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    FLock.Enter;
    try
      L.Assign(FPendingLog);
      FPendingLog.Clear;
    finally
      FLock.Leave;
    end;
    if Assigned(FOnLog) then
      for I := 0 to L.Count - 1 do FOnLog(L[I]);
  finally
    L.Free;
  end;
end;

procedure TMcpServerThread.StopAndWait;
begin
  Terminate;
  // let pending Synchronize/Queue calls run, then wait for the thread to end
  while not Finished do
    CheckSynchronize(20);
  CheckSynchronize(0);
end;

procedure TMcpServerThread.SyncToolCall;
begin
  try
    FOnToolCall(FCallName, FCallArgs, FCallResult);
  except
    on E: Exception do
      McpSetError(FCallResult, 'Exception: ' + E.Message);
  end;
end;

procedure TMcpServerThread.SyncToolsList;
begin
  FOnToolsList(FToolsArr);
end;

procedure TMcpServerThread.DoIdle(Sender: TObject);
begin
  if FStats.State = msStarting then
  begin
    SetState(msRunning);
    Log(Format('MCP server running on %s (bind %s)', [ClientUrl(FSettings), FSettings.Address]));
  end;
  if Terminated then
    FServer.Active := False; // stop the accept loop
end;

function TMcpServerThread.HandleRpc(AMsg: TJSONObject): TJSONObject;
var
  Method: string;
  Id, P, CI: TJSONData;
  Params, Res, Args: TJSONObject;
  I: Integer;
  Sess: TMcpSession;
begin
  Result := nil;
  Method := AMsg.Get('method', '');
  Id := AMsg.Find('id');
  P := AMsg.Find('params');
  if (P <> nil) and (P.JSONType = jtObject) then Params := TJSONObject(P) else Params := nil;

  FLock.Enter;
  try
    Inc(FStats.RpcMessages);
    FStats.LastMethod := Method;
  finally
    FLock.Leave;
  end;

  if Id = nil then Exit; // notification, e.g. notifications/initialized -> no reply

  Res := nil;
  if Method = 'initialize' then
  begin
    Sess := TMcpSession.Create;
    Sess.Id := NewSessionId;
    Sess.Remote := FCurRemote;
    Sess.CreatedAt := Now;
    Sess.LastSeen := Now;
    Sess.Requests := 1;
    Res := TJSONObject.Create;
    FLock.Enter;
    try
      if (Params <> nil) and (Params.Find('protocolVersion', jtString) <> nil) then
        FStats.ProtocolVersion := Params.Strings['protocolVersion']
      else
        FStats.ProtocolVersion := MCP_PROTOCOL_VERSION;
      CI := nil;
      if Params <> nil then CI := Params.Find('clientInfo', jtObject);
      if CI <> nil then
      begin
        FStats.ClientName := TJSONObject(CI).Get('name', '');
        FStats.ClientVersion := TJSONObject(CI).Get('version', '');
      end;
      Sess.ClientName := FStats.ClientName;
      Sess.ClientVersion := FStats.ClientVersion;
      if Sess.ClientName = '' then Sess.ClientName := 'unknown@' + FCurRemote;
      FSessions.Add(Sess);
      Res.Add('protocolVersion', FStats.ProtocolVersion);
    finally
      FLock.Leave;
    end;
    FCurSession := Sess;
    FNewSessionId := Sess.Id;
    Res.Add('capabilities', TJSONObject.Create(['tools', TJSONObject.Create]));
    Res.Add('serverInfo', TJSONObject.Create(['name', FSettings.ServerName, 'version', '1.2.0']));
    Res.Add('instructions', FSettings.Instructions);
    Log(Format('client connected: %s %s from %s (session %s)',
      [Sess.ClientName, Sess.ClientVersion, FCurRemote, Copy(Sess.Id, 1, 8)]));
  end
  else if Method = 'ping' then
    Res := TJSONObject.Create
  else if Method = 'tools/list' then
  begin
    FToolsArr := TJSONArray.Create;
    if Assigned(FOnToolsList) and not Terminated then Synchronize(@SyncToolsList);
    Res := TJSONObject.Create(['tools', FToolsArr]);
  end
  else if Method = 'tools/call' then
  begin
    if Params = nil then
    begin
      CountError('tools/call without params');
      Exit(RpcError(Id, -32602, 'Missing params'));
    end;
    FCallName := Params.Get('name', '');
    Args := Params.Find('arguments', jtObject) as TJSONObject;
    if Args = nil then
    begin
      Args := TJSONObject.Create;
      Params.Add('arguments', Args);
    end;
    FCallArgs := Args;
    FCallResult := TJSONObject.Create;

    FLock.Enter;
    try
      Inc(FStats.ToolCalls);
      FStats.LastTool := FCallName;
      I := FToolCounts.IndexOfName(FCallName);
      if I < 0 then
        FToolCounts.Add(FCallName + '=1')
      else
        FToolCounts.ValueFromIndex[I] := IntToStr(StrToIntDef(FToolCounts.ValueFromIndex[I], 0) + 1);
      if FCurSession <> nil then
      begin
        Inc(FCurSession.ToolCalls);
        FCurSession.LastTool := FCallName;
        FCallClient := FCurSession.ClientName;
      end
      else
        FCallClient := 'anonymous@' + FCurRemote;
    finally
      FLock.Leave;
    end;

    Log(Format('tool: %s  from %s  %s', [FCallName, FCallClient, Shorten(Args.AsJSON, 300)]));
    if Assigned(FOnToolCall) and not Terminated then
      Synchronize(@SyncToolCall)
    else
      McpSetError(FCallResult, 'Server is shutting down');
    if FCallResult.Find('content') = nil then McpAddText(FCallResult, 'ok');
    if FCallResult.Get('isError', False) then
    begin
      CountError(FCallName + ': ' + Shorten(FCallResult.Arrays['content'].Objects[0].Get('text', ''), 200));
      Log('tool error: ' + FStats.LastError);
    end;
    Res := FCallResult;
  end
  else
  begin
    CountError('Method not found: ' + Method);
    Exit(RpcError(Id, -32601, 'Method not found: ' + Method));
  end;

  Result := TJSONObject.Create(['jsonrpc', '2.0']);
  Result.Add('id', Id.Clone);
  Result.Add('result', Res);
end;

procedure TMcpServerThread.DoRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  Data: TJSONData;
  Reply: TJSONData;
  Arr: TJSONArray;
  R, NodeObj: TJSONObject;
  I: Integer;
  Sid: string;
begin
  AResponse.ContentType := 'application/json';
  if Terminated then
  begin
    AResponse.Code := 503;
    Exit;
  end;

  // ---- GET /node : node status for the Topology (not counted as MCP traffic) ----
  if SameText(ARequest.PathInfo, '/node') then
  begin
    NodeObj := nil;
    try
      if Assigned(FOnNodeInfo) then
        NodeObj := GetJSON(FOnNodeInfo()) as TJSONObject
      else
        NodeObj := TJSONObject.Create(['id', FSettings.NodeId]);
      NodeObj.Add('sessions', SessionsJSON);
      NodeObj.Add('mcpUrl', ClientUrl(FSettings));
      AResponse.Code := 200;
      AResponse.Content := NodeObj.AsJSON;
    finally
      NodeObj.Free;
    end;
    Exit;
  end;

  FLock.Enter;
  try
    if FStats.State = msStarting then
    begin
      FStats.State := msRunning;
      FStats.StartedAt := Now;
    end;
    Inc(FStats.HttpRequests);
    Inc(FStats.BytesIn, Length(ARequest.Content));
    FStats.LastRequestAt := Now;
    FStats.LastRemote := ARequest.RemoteAddress;
  finally
    FLock.Leave;
  end;

  if not SameText(ARequest.PathInfo, FSettings.Endpoint) then
  begin
    CountError('404 ' + ARequest.Method + ' ' + ARequest.PathInfo);
    Log('404 ' + ARequest.Method + ' ' + ARequest.PathInfo + ' from ' + ARequest.RemoteAddress);
    AResponse.Code := 404;
    AResponse.Content := '{"error":"not found, use ' + FSettings.Endpoint + '"}';
    Exit;
  end;

  // ---- session ----
  ExpireSessions;
  FCurRemote := ARequest.RemoteAddress;
  FCurSession := nil;
  FNewSessionId := '';
  Sid := ARequest.GetCustomHeader('Mcp-Session-Id');
  if Sid <> '' then
  begin
    FCurSession := FindSession(Sid);
    if FCurSession = nil then
    begin
      // session expired / server restarted -> the client must initialize again (MCP spec)
      CountError('unknown session ' + Copy(Sid, 1, 8));
      AResponse.Code := 404;
      AResponse.Content := '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Session not found"}}';
      Exit;
    end;
    FLock.Enter;
    try
      FCurSession.LastSeen := Now;
      Inc(FCurSession.Requests);
      FCurSession.Remote := FCurRemote;
    finally
      FLock.Leave;
    end;
  end;

  if ARequest.Method = 'GET' then
  begin
    // server-initiated SSE streams are not supported
    AResponse.Code := 405;
    AResponse.Content := '';
    Exit;
  end;
  if ARequest.Method = 'DELETE' then
  begin
    if FCurSession <> nil then
    begin
      Log('client disconnected: ' + FCurSession.ClientName);
      RemoveSession(Sid);
      FCurSession := nil;
    end;
    AResponse.Code := 200;
    Exit;
  end;
  if ARequest.Method <> 'POST' then
  begin
    AResponse.Code := 405;
    Exit;
  end;

  if FSettings.VerboseLog then
    Log('>> ' + ARequest.RemoteAddress + ' ' + Shorten(ARequest.Content));

  Data := nil;
  Reply := nil;
  try
    try
      Data := GetJSON(ARequest.Content);
    except
      on E: Exception do
      begin
        CountError('Parse error: ' + E.Message);
        Reply := RpcError(nil, -32700, 'Parse error: ' + E.Message);
      end;
    end;

    if Reply = nil then
    begin
      if Data.JSONType = jtArray then
      begin
        Arr := TJSONArray.Create;
        for I := 0 to TJSONArray(Data).Count - 1 do
          if TJSONArray(Data).Items[I].JSONType = jtObject then
          begin
            R := HandleRpc(TJSONArray(Data).Objects[I]);
            if R <> nil then Arr.Add(R);
          end;
        if Arr.Count > 0 then Reply := Arr else Arr.Free;
      end
      else if Data.JSONType = jtObject then
        Reply := HandleRpc(TJSONObject(Data))
      else
        Reply := RpcError(nil, -32600, 'Invalid request');
    end;

    if FNewSessionId <> '' then
      AResponse.SetCustomHeader('Mcp-Session-Id', FNewSessionId);

    if Reply = nil then
    begin
      AResponse.Code := 202; // notification only
      AResponse.Content := '';
    end
    else
    begin
      AResponse.Code := 200;
      AResponse.Content := Reply.AsJSON;
      if FSettings.VerboseLog then
        Log('<< ' + Shorten(AResponse.Content));
    end;
    FLock.Enter;
    try
      Inc(FStats.BytesOut, Length(AResponse.Content));
    finally
      FLock.Leave;
    end;
  finally
    Reply.Free;
    Data.Free;
  end;
end;

procedure TMcpServerThread.Execute;
begin
  FServer := TMcpHttpServer.Create(nil);
  try
    FServer.Address := FSettings.Address;
    FServer.Port := FSettings.Port;
    FServer.Threaded := False; // one request at a time -> shared sync variables are safe
    FServer.AcceptIdleTimeout := 200;
    FServer.OnAcceptIdle := @DoIdle;
    FServer.OnRequest := @DoRequest;
    try
      FServer.Active := True; // blocks until stopped
      SetState(msStopped);
      Log('MCP server stopped');
    except
      on E: Exception do
      begin
        SetState(msError, E.Message);
        Log('MCP server error: ' + E.Message);
      end;
    end;
  finally
    FreeAndNil(FServer);
  end;
end;

end.
