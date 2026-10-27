unit NodeState;

{ Identity and specific status of each program (node) + poller that reads the status of the other nodes (peers)
  - TLocalNode : our own status, readable from any thread (answers GET /node)
  - TPeerPoller: thread that GETs http://peer/node every second to build the Topology }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DateUtils, fpjson, jsonparser, fphttpclient;

type
  TNodeRole = (nrServer, nrClient, nrExternal, nrUnknown);
  TNodeState = (nsOffline, nsStarting, nsWaiting, nsConnected, nsBusy, nsError, nsStopped);

  { TLocalNode }

  TLocalNode = class
  private
    FLock: TCriticalSection;
    FId, FName, FKind: string;
    FRole: TNodeRole;
    FHost: string;
    FPort: Word;
    FUrl: string;
    FBaseState: TNodeState;
    FStateNote: string;
    FStartedAt: TDateTime;
    FBusyUntil: TDateTime;
    FErrorUntil: TDateTime;
    FLastCommand, FLastCommandFrom, FLastError: string;
    FLastCommandAt: TDateTime;
    FCommands: Int64;
    FCommandsFailed: Int64;
    FDetail: TJSONObject;
    FLinks: TJSONArray;
  public
    constructor Create(const AId, AName, AKind: string; ARole: TNodeRole;
      const AHost: string; APort: Word);
    destructor Destroy; override;
    { Base state (Waiting/Connected/Stopped/Error) + extra note }
    procedure SetBaseState(AState: TNodeState; const ANote: string = '');
    { Call when a command arrives / work starts and when it is done (Busy is kept for 1.5 s so it is visible) }
    procedure CommandStarted(const AFrom, ACommand: string);
    procedure CommandDone(AOk: Boolean; const AError: string = '');
    { Program specific status (takes ownership) }
    procedure SetDetail(ADetail: TJSONObject);
    { Outgoing connections (client -> server) [{url, state, lastTrafficAgo}] (takes ownership) }
    procedure SetLinks(ALinks: TJSONArray);
    procedure SetEndpoint(const AHost: string; APort: Word; const AUrl: string);
    function State: TNodeState;
    { Display text of the state, e.g. "Waiting for commands (2 clients)" / "Busy: add_control" }
    function StateDisplay: string;
    function ToJSONObject: TJSONObject; // thread-safe snapshot (caller frees)
    function ToJSON: string;           // thread-safe
    property Id: string read FId;
    property Name: string read FName;
    property Role: TNodeRole read FRole;
    property Port: Word read FPort;
  end;

  { TPeerPoller }

  TPeerPoller = class(TThread)
  private
    FLock: TCriticalSection;
    FPeers: TStringList;    // spec: id@host:port
    FResults: TStringList;  // last json of each peer, same order as FPeers ('' = offline)
    FFails: array of Integer; // consecutive failures per peer (one miss is tolerated)
    FSkipPort: Word;
    FInterval: Integer;
    function Fetch(const AHostPort: string): string;
  protected
    procedure Execute; override;
  public
    constructor Create(const APeers: string; ASkipPort: Word);
    destructor Destroy; override;
    procedure StopAndWait;
    { Copy of the latest results: ASpecs[i] = id@host:port, AJsons[i] = json ('' = offline) }
    procedure GetResults(ASpecs, AJsons: TStrings);
    procedure SetPeers(const APeers: string);
  end;

const
  NodeStateText: array[TNodeState] of string =
    ('Offline', 'Starting', 'Waiting for commands', 'Connected', 'Busy', 'Error', 'Stopped');
  NodeStateCode: array[TNodeState] of string =
    ('offline', 'starting', 'waiting', 'connected', 'busy', 'error', 'stopped');
  NodeRoleCode: array[TNodeRole] of string = ('server', 'client', 'external', 'unknown');

  DEFAULT_PEERS =
    'server-1@127.0.0.1:8765,server-2@127.0.0.1:8766,' +
    'client-1@127.0.0.1:8775,client-2@127.0.0.1:8776';

function StateFromCode(const S: string): TNodeState;
function RoleFromCode(const S: string): TNodeRole;
{ Split "id@host:port" }
procedure ParsePeerSpec(const ASpec: string; out AId, AHost: string; out APort: Word);
{ Read --name=value from the command line }
function CmdLineValue(const AName, ADefault: string): string;
{ Find a peer by id (e.g. server-2) or URL -> URL of its MCP endpoint + whether it is online
  Returns False when it is not one of the peers }
function FindPeer(APoller: TPeerPoller; const AIdOrUrl: string;
  out AUrl, AId: string; out AOnline: Boolean): Boolean;
{ Summary of ourselves + every peer (used by the get_topology tool); caller frees }
function TopologySnapshot(ALocal: TLocalNode; APoller: TPeerPoller): TJSONObject;

implementation

function StateFromCode(const S: string): TNodeState;
var
  St: TNodeState;
begin
  for St := Low(TNodeState) to High(TNodeState) do
    if NodeStateCode[St] = S then Exit(St);
  Result := nsOffline;
end;

function RoleFromCode(const S: string): TNodeRole;
var
  R: TNodeRole;
begin
  for R := Low(TNodeRole) to High(TNodeRole) do
    if NodeRoleCode[R] = S then Exit(R);
  Result := nrUnknown;
end;

procedure ParsePeerSpec(const ASpec: string; out AId, AHost: string; out APort: Word);
var
  S: string;
  P: Integer;
begin
  S := Trim(ASpec);
  P := Pos('@', S);
  if P > 0 then
  begin
    AId := Copy(S, 1, P - 1);
    Delete(S, 1, P);
  end
  else
    AId := '';
  P := LastDelimiter(':', S);
  if P > 0 then
  begin
    AHost := Copy(S, 1, P - 1);
    APort := StrToIntDef(Copy(S, P + 1, 10), 0);
  end
  else
  begin
    AHost := S;
    APort := 0;
  end;
  if AHost = '' then AHost := '127.0.0.1';
  if AId = '' then AId := AHost + ':' + IntToStr(APort);
end;

function CmdLineValue(const AName, ADefault: string): string;
var
  I: Integer;
  Prefix: string;
begin
  Result := ADefault;
  Prefix := '--' + AName + '=';
  for I := 1 to ParamCount do
    if Pos(Prefix, ParamStr(I)) = 1 then
      Exit(Copy(ParamStr(I), Length(Prefix) + 1, MaxInt));
end;

function FindPeer(APoller: TPeerPoller; const AIdOrUrl: string;
  out AUrl, AId: string; out AOnline: Boolean): Boolean;
var
  Specs, Jsons: TStringList;
  I: Integer;
  Id, Host, NodeId, McpUrl, Key: string;
  Port: Word;
  D: TJSONData;
begin
  Result := False;
  AUrl := '';
  AId := '';
  AOnline := False;
  if APoller = nil then Exit;
  Key := LowerCase(Trim(AIdOrUrl));
  Specs := TStringList.Create;
  Jsons := TStringList.Create;
  try
    APoller.GetResults(Specs, Jsons);
    for I := 0 to Specs.Count - 1 do
    begin
      ParsePeerSpec(Specs[I], Id, Host, Port);
      NodeId := Id;
      McpUrl := Format('http://%s:%d/mcp', [Host, Port]);
      if Jsons[I] <> '' then
        try
          D := GetJSON(Jsons[I]);
          try
            if D is TJSONObject then
            begin
              NodeId := TJSONObject(D).Get('id', Id);
              McpUrl := TJSONObject(D).Get('mcpUrl', McpUrl);
            end;
          finally
            D.Free;
          end;
        except
        end;
      if (Key = LowerCase(Id)) or (Key = LowerCase(NodeId)) or (Key = LowerCase(McpUrl)) or
         ((Pos('://', Key) > 0) and (Pos(LowerCase(Format(':%d/', [Port])), Key) > 0) and
          ((Pos('127.0.0.1', Key) > 0) or (Pos('localhost', Key) > 0) or (Pos(LowerCase(Host), Key) > 0))) then
      begin
        AUrl := McpUrl;
        AId := NodeId;
        AOnline := Jsons[I] <> '';
        Exit(True);
      end;
    end;
  finally
    Jsons.Free;
    Specs.Free;
  end;
end;

function TopologySnapshot(ALocal: TLocalNode; APoller: TPeerPoller): TJSONObject;
var
  Specs, Jsons: TStringList;
  Arr: TJSONArray;
  I: Integer;
  O: TJSONObject;
  D: TJSONData;
  Id, Host: string;
  Port: Word;
begin
  Result := TJSONObject.Create;
  Result.Add('self', ALocal.ToJSONObject);
  Arr := TJSONArray.Create;
  Result.Add('peers', Arr);
  if APoller = nil then Exit;
  Specs := TStringList.Create;
  Jsons := TStringList.Create;
  try
    APoller.GetResults(Specs, Jsons);
    for I := 0 to Specs.Count - 1 do
    begin
      ParsePeerSpec(Specs[I], Id, Host, Port);
      O := TJSONObject.Create(['peer', Specs[I], 'online', Jsons[I] <> '']);
      if Jsons[I] <> '' then
        try
          D := GetJSON(Jsons[I]);
          O.Add('node', D);
        except
          O.Booleans['online'] := False;
        end
      else
        O.Add('state', 'offline');
      Arr.Add(O);
    end;
  finally
    Jsons.Free;
    Specs.Free;
  end;
end;

function SecondsAgo(T: TDateTime): Int64;
begin
  if T <= 0 then Result := -1 else Result := SecondsBetween(Now, T);
end;

{ TLocalNode }

constructor TLocalNode.Create(const AId, AName, AKind: string; ARole: TNodeRole;
  const AHost: string; APort: Word);
begin
  FLock := TCriticalSection.Create;
  FId := AId;
  FName := AName;
  FKind := AKind;
  FRole := ARole;
  FHost := AHost;
  FPort := APort;
  FBaseState := nsStarting;
  FStartedAt := Now;
  FDetail := TJSONObject.Create;
  FLinks := TJSONArray.Create;
end;

destructor TLocalNode.Destroy;
begin
  FLinks.Free;
  FDetail.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLocalNode.SetBaseState(AState: TNodeState; const ANote: string);
begin
  FLock.Enter;
  try
    FBaseState := AState;
    FStateNote := ANote;
  finally
    FLock.Leave;
  end;
end;

procedure TLocalNode.CommandStarted(const AFrom, ACommand: string);
begin
  FLock.Enter;
  try
    FLastCommand := ACommand;
    FLastCommandFrom := AFrom;
    FLastCommandAt := Now;
    Inc(FCommands);
    FBusyUntil := IncMilliSecond(Now, 1500);
  finally
    FLock.Leave;
  end;
end;

procedure TLocalNode.CommandDone(AOk: Boolean; const AError: string);
begin
  FLock.Enter;
  try
    FBusyUntil := IncMilliSecond(Now, 1500);
    if not AOk then
    begin
      Inc(FCommandsFailed);
      FLastError := AError;
      FErrorUntil := IncSecond(Now, 4);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLocalNode.SetDetail(ADetail: TJSONObject);
begin
  FLock.Enter;
  try
    FDetail.Free;
    FDetail := ADetail;
  finally
    FLock.Leave;
  end;
end;

procedure TLocalNode.SetLinks(ALinks: TJSONArray);
begin
  FLock.Enter;
  try
    FLinks.Free;
    FLinks := ALinks;
  finally
    FLock.Leave;
  end;
end;

procedure TLocalNode.SetEndpoint(const AHost: string; APort: Word; const AUrl: string);
begin
  FLock.Enter;
  try
    FHost := AHost;
    FPort := APort;
    FUrl := AUrl;
  finally
    FLock.Leave;
  end;
end;

function TLocalNode.State: TNodeState;
begin
  FLock.Enter;
  try
    Result := FBaseState;
    if Result in [nsWaiting, nsConnected] then
    begin
      if Now < FErrorUntil then Result := nsError
      else if Now < FBusyUntil then Result := nsBusy;
    end;
  finally
    FLock.Leave;
  end;
end;

function TLocalNode.StateDisplay: string;
var
  St: TNodeState;
begin
  St := State;
  FLock.Enter;
  try
    Result := NodeStateText[St];
    if (St = nsBusy) and (FLastCommand <> '') then
      Result := 'Busy: ' + FLastCommand
    else if (St = nsError) and (FLastError <> '') then
      Result := 'Error: ' + FLastError
    else if FStateNote <> '' then
      Result := Result + ' (' + FStateNote + ')';
  finally
    FLock.Leave;
  end;
end;

function TLocalNode.ToJSONObject: TJSONObject;
var
  St: TNodeState;
  Txt: string;
begin
  St := State;
  Txt := StateDisplay;
  FLock.Enter;
  try
    Result := TJSONObject.Create([
      'id', FId,
      'name', FName,
      'kind', FKind,
      'role', NodeRoleCode[FRole],
      'host', FHost,
      'port', FPort,
      'url', FUrl,
      'pid', Int64(GetProcessID),
      'state', NodeStateCode[St],
      'stateText', Txt,
      'startedAt', FormatDateTime('yyyy-mm-dd hh:nn:ss', FStartedAt),
      'uptimeSec', SecondsBetween(Now, FStartedAt),
      'commands', FCommands,
      'commandsFailed', FCommandsFailed,
      'lastCommand', FLastCommand,
      'lastCommandFrom', FLastCommandFrom,
      'lastCommandAgo', SecondsAgo(FLastCommandAt),
      'lastError', FLastError,
      'time', FormatDateTime('hh:nn:ss', Now)]);
    Result.Add('detail', FDetail.Clone);
    Result.Add('links', FLinks.Clone);
  finally
    FLock.Leave;
  end;
end;

function TLocalNode.ToJSON: string;
var
  O: TJSONObject;
begin
  O := ToJSONObject;
  try
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ TPeerPoller }

constructor TPeerPoller.Create(const APeers: string; ASkipPort: Word);
begin
  FLock := TCriticalSection.Create;
  FPeers := TStringList.Create;
  FResults := TStringList.Create;
  FSkipPort := ASkipPort;
  FInterval := 1000;
  SetPeers(APeers);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TPeerPoller.Destroy;
begin
  inherited Destroy;
  FResults.Free;
  FPeers.Free;
  FLock.Free;
end;

procedure TPeerPoller.SetPeers(const APeers: string);
var
  SL: TStringList;
  I: Integer;
  Id, Host: string;
  Port: Word;
begin
  SL := TStringList.Create;
  try
    SL.StrictDelimiter := True;
    SL.Delimiter := ',';
    SL.DelimitedText := APeers;
    FLock.Enter;
    try
      FPeers.Clear;
      FResults.Clear;
      for I := 0 to SL.Count - 1 do
      begin
        if Trim(SL[I]) = '' then Continue;
        ParsePeerSpec(SL[I], Id, Host, Port);
        // do not poll ourselves
        if (Port = FSkipPort) and ((Host = '127.0.0.1') or SameText(Host, 'localhost')) then
          Continue;
        FPeers.Add(Trim(SL[I]));
        FResults.Add('');
      end;
      SetLength(FFails, FPeers.Count);
      for I := 0 to High(FFails) do FFails[I] := 0;
    finally
      FLock.Leave;
    end;
  finally
    SL.Free;
  end;
end;

function TPeerPoller.Fetch(const AHostPort: string): string;
var
  Http: TFPHTTPClient;
begin
  Result := '';
  Http := TFPHTTPClient.Create(nil);
  try
    Http.ConnectTimeout := 400;
    Http.IOTimeout := 1500;
    try
      Result := Http.Get('http://' + AHostPort + '/node');
      if Http.ResponseStatusCode <> 200 then Result := '';
    except
      Result := '';
    end;
  finally
    Http.Free;
  end;
end;

procedure TPeerPoller.Execute;
var
  Specs: TStringList;
  I, J: Integer;
  Id, Host, Json: string;
  Port: Word;
begin
  Specs := TStringList.Create;
  try
    while not Terminated do
    begin
      FLock.Enter;
      try
        Specs.Assign(FPeers);
      finally
        FLock.Leave;
      end;
      for I := 0 to Specs.Count - 1 do
      begin
        if Terminated then Break;
        ParsePeerSpec(Specs[I], Id, Host, Port);
        Json := Fetch(Host + ':' + IntToStr(Port));
        FLock.Enter;
        try
          J := FPeers.IndexOf(Specs[I]);
          if J >= 0 then
          begin
            if Json <> '' then
            begin
              FFails[J] := 0;
              FResults[J] := Json;
            end
            else
            begin
              // a single missed poll keeps the last answer; offline after 2 misses in a row
              Inc(FFails[J]);
              if FFails[J] >= 2 then FResults[J] := '';
            end;
          end;
        finally
          FLock.Leave;
        end;
      end;
      for I := 1 to FInterval div 50 do
        if Terminated then Break else Sleep(50);
    end;
  finally
    Specs.Free;
  end;
end;

procedure TPeerPoller.StopAndWait;
begin
  Terminate;
  WaitFor;
end;

procedure TPeerPoller.GetResults(ASpecs, AJsons: TStrings);
begin
  FLock.Enter;
  try
    ASpecs.Assign(FPeers);
    AJsons.Assign(FResults);
  finally
    FLock.Leave;
  end;
end;

end.
