unit MainForm;

{ MCP Client : program to test communication with MCP servers
  - is a node of the Topology (client-1 / client-2) with its own status
  - opens its own MCP (control) endpoint so other sources can command it, e.g.
    connect / call_tool / list_servers  -> the client forwards the command to a server
  - compiled with -dCLIENT2 it becomes Client 2 (different defaults) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Menus, Spin, IniFiles, fpjson, jsonparser, base64, McpClientCore,
  McpConfig, McpServer, McpTools, NodeState, TopoView;

type

  { TFormClient }

  TFormClient = class(TForm)
    btnCall: TButton;
    btnClearLog: TButton;
    btnConnect: TButton;
    btnDisconnect: TButton;
    btnPing: TButton;
    btnRawSend: TButton;
    btnRunTests: TButton;
    btnTemplate: TButton;
    cbRawMethod: TComboBox;
    chkLogBodies: TCheckBox;
    edUrl: TComboBox;
    pnlNode: TPanel;
    pnlConns: TPanel;
    lblConns: TLabel;
    cbConns: TComboBox;
    btnConnectAll: TButton;
    btnDisconnectAll: TButton;
    chkAutoConnect: TCheckBox;
    tsTopology: TTabSheet;
    tmrNode: TTimer;
    imgResult: TImage;
    lbTools: TListBox;
    lblArgs: TLabel;
    lblCallInfo: TLabel;
    lblRaw: TLabel;
    lblTimeout: TLabel;
    lblToolName: TLabel;
    lblUrl: TLabel;
    MainMenu1: TMainMenu;
    memArgs: TMemo;
    memLog: TMemo;
    memRawReq: TMemo;
    memRawResp: TMemo;
    memResult: TMemo;
    memSchema: TMemo;
    memServer: TMemo;
    memTest: TMemo;
    miConnect: TMenuItem;
    miDisconnect: TMenuItem;
    miFile: TMenuItem;
    miFileExit: TMenuItem;
    miMcp: TMenuItem;
    miPing: TMenuItem;
    miRefreshTools: TMenuItem;
    miRunTests: TMenuItem;
    miSep1: TMenuItem;
    miSep2: TMenuItem;
    PageControl1: TPageControl;
    pcResult: TPageControl;
    pnlCall: TPanel;
    pnlLogBar: TPanel;
    pnlRawBar: TPanel;
    pnlRight: TPanel;
    pnlTestBar: TPanel;
    pnlTop: TPanel;
    sbImage: TScrollBox;
    seTimeout: TSpinEdit;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    Splitter3: TSplitter;
    StatusBar1: TStatusBar;
    tsImage: TTabSheet;
    tsLog: TTabSheet;
    tsRaw: TTabSheet;
    tsServer: TTabSheet;
    tsTest: TTabSheet;
    tsText: TTabSheet;
    tsTools: TTabSheet;
    procedure btnCallClick(Sender: TObject);
    procedure btnClearLogClick(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnPingClick(Sender: TObject);
    procedure btnRawSendClick(Sender: TObject);
    procedure btnRunTestsClick(Sender: TObject);
    procedure btnTemplateClick(Sender: TObject);
    procedure cbRawMethodChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lbToolsSelectionChange(Sender: TObject; User: boolean);
    procedure miFileExitClick(Sender: TObject);
    procedure miRefreshToolsClick(Sender: TObject);
    procedure edUrlDropDown(Sender: TObject);
    procedure tmrNodeTimer(Sender: TObject);
    procedure cbConnsChange(Sender: TObject);
    procedure btnConnectAllClick(Sender: TObject);
    procedure btnDisconnectAllClick(Sender: TObject);
  private
    FClient: TMcpClient;   // the "active" connection (used by the Tools / Raw / Test tabs)
    FConns: TList;         // every connection that is open at the same time (TMcpClient)
    FIdle: TMcpClient;     // used when there is no connection yet
    FAuto: TStringList;    // servers to connect automatically (id or URL)
    FLastAutoTry: QWord;
    FTools: TJSONArray;
    FToolsUrl: string;
    FPass, FFail: Integer;
    // node + control endpoint
    FSettings: TMcpSettings;
    FCtl: TMcpServerThread;
    FNode: TLocalNode;
    FPoller: TPeerPoller;
    FTopo: TTopologyView;
    function FindConn(const AUrl: string): TMcpClient;
    function EnsureConn(const AUrl: string): TMcpClient;
    function OpenConn(const AUrl: string; AActivate: Boolean = True): TMcpClient;
    procedure CloseConn(C: TMcpClient);
    procedure ActivateConn(C: TMcpClient);
    procedure PruneConns;
    procedure RefreshConnList;
    function ConnServerName(C: TMcpClient): string;
    function ConnByTarget(const ATarget: string): TMcpClient;
    function ConnectedCount: Integer;
    procedure AutoConnect;
    procedure RemoveAuto(const AUrl: string);
    procedure UpdateNode;
    procedure LocalStart(const ACommand: string);
    procedure LocalDone(AOk: Boolean; const AError: string = '');
    procedure CtlLog(const AMsg: string);
    procedure CtlToolsList(ATools: TJSONArray);
    procedure CtlToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
    procedure DoCtlTool(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
    function ResolveTarget(const ATarget: string): string;
    function CtlSessions: TJSONArray;
    function ServersJSON: TJSONArray;
    procedure ClientTraffic(const ADirection, AText: string);
    procedure PrepareClient;
    procedure UpdateUI(const AMsg: string = '');
    procedure ShowError(const AWhat: string; E: Exception);
    procedure RefreshTools;
    function SelectedTool: TJSONObject;
    function BuildTemplate(ATool: TJSONObject): string;
    procedure ShowToolResult(ARes: TJSONObject);
    procedure LoadImage(const ABase64, AMime: string);
    procedure Check(const AName: string; AOk: Boolean; const AInfo: string);
    function RawJson(const ABody: string; const AMethod: string = 'POST'): TJSONObject;
  public
  end;

var
  FormClient: TFormClient;

implementation

{$R *.lfm}

uses
  StrUtils, BGRABitmapTypes;

const
  CLIENT_VERSION = '1.1.0';
  MAX_LOG_BODY = 4000;
{$IFDEF CLIENT2}
  DEF_NODE_ID = 'client-2';
  DEF_NODE_NAME = 'Client 2';
  DEF_CTL_PORT = 8776;
  DEF_URL = 'http://127.0.0.1:8766/mcp';
{$ELSE}
  DEF_NODE_ID = 'client-1';
  DEF_NODE_NAME = 'Client 1';
  DEF_CTL_PORT = 8775;
  DEF_URL = 'http://127.0.0.1:8765/mcp';
{$ENDIF}

function IniName: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

function Shorten(const S: string; AMax: Integer): string;
begin
  if Length(S) > AMax then
    Result := Copy(S, 1, AMax) + Format(' ... (%d bytes)', [Length(S)])
  else
    Result := S;
end;

function PrettyJson(const S: string): string;
var
  D: TJSONData;
begin
  try
    D := GetJSON(S);
    try
      Result := D.FormatJSON;
    finally
      D.Free;
    end;
  except
    Result := S;
  end;
end;

function UrlPort(const AUrl: string): Integer;
var
  S: string;
  P: Integer;
begin
  S := AUrl;
  P := Pos('://', S);
  if P > 0 then Delete(S, 1, P + 2);
  P := Pos('/', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  P := LastDelimiter(':', S);
  if P > 0 then Result := StrToIntDef(Copy(S, P + 1, 10), 80) else Result := 80;
end;

function IsLoopbackUrl(const AUrl: string): Boolean;
var
  L: string;
begin
  L := LowerCase(AUrl);
  Result := (Pos('://127.', L) > 0) or (Pos('://localhost', L) > 0) or (Pos('://0.0.0.0', L) > 0);
end;

{ TFormClient }

procedure TFormClient.FormCreate(Sender: TObject);
var
  Ini: TIniFile;
begin
  FConns := TList.Create;
  FIdle := TMcpClient.Create;
  FIdle.OnTraffic := @ClientTraffic;
  FClient := FIdle;
  FAuto := TStringList.Create;
  FAuto.StrictDelimiter := True;
  FAuto.Delimiter := ',';
  FAuto.Duplicates := dupIgnore;
  FAuto.Sorted := True;
  Ini := TIniFile.Create(IniName);
  try
    edUrl.Text := Ini.ReadString('Client', 'Url', DEF_URL);
    seTimeout.Value := Ini.ReadInteger('Client', 'Timeout', FClient.Timeout);
    // default: connect to both server-1 and server-2 at the same time
    FAuto.DelimitedText := Ini.ReadString('Remote', 'AutoConnect', 'server-1,server-2');
    chkAutoConnect.Checked := Ini.ReadBool('Remote', 'AutoConnectEnabled', True);
  finally
    Ini.Free;
  end;
  cbRawMethod.ItemIndex := 0;
  cbRawMethodChange(nil);

  // ---- node identity + control endpoint so other sources can command this client ----
  FSettings := DefaultSettings;
  FSettings.Port := DEF_CTL_PORT;
  FSettings.NodeId := DEF_NODE_ID;
  FSettings.NodeName := DEF_NODE_NAME;
  FSettings.ServerName := DEF_NODE_ID + '-control';
  FSettings.ClientName := DEF_NODE_ID;
  FSettings.LogToFile := False;
  FSettings.Instructions := 'This is the control endpoint of an MCP *client* node. ' +
    'Use list_servers to see servers, connect to attach to one, list_tools / call_tool ' +
    'to command that server through this client, get_topology to see the whole network.';
  LoadSettings(FSettings);

  FNode := TLocalNode.Create(FSettings.NodeId, FSettings.NodeName,
    'MCP client (commandable)', nrClient, '127.0.0.1', FSettings.Port);
  FNode.SetEndpoint('127.0.0.1', FSettings.Port, ClientUrl(FSettings));
  FPoller := TPeerPoller.Create(FSettings.Peers, FSettings.Port);

  FTopo := TTopologyView.Create(Self);
  FTopo.Parent := tsTopology;
  FTopo.Align := alClient;
  FTopo.LocalNode := FNode;
  FTopo.Poller := FPoller;
  FTopo.SessionsFunc := @CtlSessions;

  FCtl := TMcpServerThread.Create(FSettings);
  FCtl.OnLog := @CtlLog;
  FCtl.OnToolsList := @CtlToolsList;
  FCtl.OnToolCall := @CtlToolCall;
  FCtl.OnNodeInfo := @FNode.ToJSON;
  FCtl.Start;

  PageControl1.ActivePage := tsTopology;
  pcResult.ActivePage := tsText;
  UpdateNode;
  UpdateUI('Ready — press Connect to connect to a server');
end;

{ ---------- node ---------- }

procedure TFormClient.LocalStart(const ACommand: string);
begin
  FNode.CommandStarted('local (user)', ACommand);
  UpdateNode;
end;

procedure TFormClient.LocalDone(AOk: Boolean; const AError: string);
begin
  FNode.CommandDone(AOk, AError);
  UpdateNode;
end;

procedure TFormClient.UpdateNode;
var
  Links, ConnArr: TJSONArray;
  Ago, Reqs, Errs: Int64;
  Srv, Names, Note: string;
  St: TMcpStats;
  I: Integer;
  C: TMcpClient;
begin
  if FNode = nil then Exit;
  Links := TJSONArray.Create;
  ConnArr := TJSONArray.Create;
  Names := '';
  Reqs := 0;
  Errs := 0;
  // every connection that is open at the same time = one link in the Topology
  for I := 0 to FConns.Count - 1 do
  begin
    C := TMcpClient(FConns[I]);
    Inc(Reqs, C.Requests);
    Inc(Errs, C.Errors);
    if not C.Connected then Continue;
    if C.LastTrafficAt > 0 then
      Ago := Round((Now - C.LastTrafficAt) * 86400)
    else
      Ago := 999;
    Srv := ConnServerName(C);
    if Names <> '' then Names := Names + ', ';
    Names := Names + Srv;
    Links.Add(TJSONObject.Create(['url', C.Url, 'server', Srv, 'state', 'connected',
      'lastTrafficAgo', Ago, 'lastTool', C.LastTool]));
    ConnArr.Add(TJSONObject.Create(['server', Srv, 'url', C.Url, 'active', C = FClient,
      'session', C.SessionId, 'requests', C.Requests, 'errors', C.Errors, 'lastTool', C.LastTool]));
  end;
  if Links.Count > 0 then
    FNode.SetBaseState(nsConnected, Names)
  else
    FNode.SetBaseState(nsWaiting, 'not connected');
  FNode.SetLinks(Links);

  if Links.Count > 0 then Note := Format('%d servers: %s', [Links.Count, Names])
  else Note := 'not connected to any server';
  FNode.SetDetail(TJSONObject.Create([
    'summary', TJSONArray.Create([Note, Format('calls %d · errors %d', [Reqs, Errs])]),
    'connections', ConnArr,
    'activeUrl', IfThen(FClient.Connected, FClient.Url, ''),
    'requests', Reqs,
    'errors', Errs,
    'autoConnect', FAuto.DelimitedText,
    'controlUrl', ClientUrl(FSettings)]));

  if FCtl <> nil then
  begin
    FCtl.GetStats(St, nil);
    if St.State = msError then FNode.SetBaseState(nsError, 'control port: ' + St.LastError);
  end;

  pnlNode.Color := BGRAToColor(StateColor(FNode.State));
  pnlNode.Caption := Format('  %s  ·  %s  ·  %s  ·  commands at %s',
    [FNode.Id, FNode.Name, FNode.StateDisplay, ClientUrl(FSettings)]);
end;

procedure TFormClient.tmrNodeTimer(Sender: TObject);
begin
  AutoConnect;
  UpdateNode;
end;

{ ---------- several connections at the same time ---------- }

function NormUrl(const AUrl: string): string;
begin
  Result := LowerCase(Trim(AUrl));
  Result := StringReplace(Result, '://localhost:', '://127.0.0.1:', []);
end;

function TFormClient.FindConn(const AUrl: string): TMcpClient;
var
  I: Integer;
begin
  for I := 0 to FConns.Count - 1 do
    if NormUrl(TMcpClient(FConns[I]).Url) = NormUrl(AUrl) then
      Exit(TMcpClient(FConns[I]));
  Result := nil;
end;

function TFormClient.EnsureConn(const AUrl: string): TMcpClient;
begin
  Result := FindConn(AUrl);
  if Result <> nil then Exit;
  Result := TMcpClient.Create;
  Result.Url := Trim(AUrl);
  Result.Timeout := seTimeout.Value;
  Result.OnTraffic := @ClientTraffic;
  FConns.Add(Result);
end;

function TFormClient.ConnServerName(C: TMcpClient): string;
var
  Url, Id: string;
  Online: Boolean;
begin
  // use the node id from the topology when known (server-1 / server-2), otherwise serverInfo.name
  if FindPeer(FPoller, C.Url, Url, Id, Online) then Exit(Id);
  if (C.ServerInfo <> nil) and (C.ServerInfo.FindPath('serverInfo.name') <> nil) then
    Result := C.ServerInfo.FindPath('serverInfo.name').AsString
  else
    Result := C.Url;
end;

function TFormClient.ConnectedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FConns.Count - 1 do
    if TMcpClient(FConns[I]).Connected then Inc(Result);
end;

{ Connect (or reuse an existing connection) — other connections stay open }
function TFormClient.OpenConn(const AUrl: string; AActivate: Boolean): TMcpClient;
var
  IsNew: Boolean;
begin
  if (UrlPort(AUrl) = FSettings.Port) and IsLoopbackUrl(AUrl) then
    raise Exception.Create('Cannot connect a client to its own control endpoint');
  IsNew := FindConn(AUrl) = nil;
  Result := EnsureConn(AUrl);
  if not Result.Connected then
    try
      Result.Connect(FSettings.NodeId, CLIENT_VERSION);
    except
      if IsNew then
      begin
        FConns.Remove(Result);
        Result.Free;
      end;
      raise;
    end;
  if AActivate or not FClient.Connected then ActivateConn(Result);
  RefreshConnList;
  UpdateNode;
end;

procedure TFormClient.CloseConn(C: TMcpClient);
begin
  if (C = nil) or (C = FIdle) then Exit;
  RemoveAuto(C.Url);
  C.Disconnect;
  FConns.Remove(C);
  if FClient = C then
  begin
    FClient := FIdle;
    if FConns.Count > 0 then ActivateConn(TMcpClient(FConns[0]))
    else
    begin
      lbTools.Clear;
      FreeAndNil(FTools);
      FToolsUrl := '';
      memServer.Clear;
    end;
  end;
  C.Free;
  RefreshConnList;
  UpdateNode;
end;

procedure TFormClient.PruneConns;
var
  I: Integer;
begin
  for I := FConns.Count - 1 downto 0 do
    if not TMcpClient(FConns[I]).Connected then
      CloseConn(TMcpClient(FConns[I]));
end;

procedure TFormClient.ActivateConn(C: TMcpClient);
begin
  FClient := C;
  edUrl.Text := C.Url;
  if C.Connected then
  begin
    memServer.Text := C.ServerInfo.FormatJSON;
    if NormUrl(FToolsUrl) <> NormUrl(C.Url) then
      try
        RefreshTools;
      except
        on E: Exception do ClientTraffic('!!', 'tools/list: ' + E.Message);
      end;
  end;
  RefreshConnList;
  UpdateUI;
end;

procedure TFormClient.RefreshConnList;
var
  I: Integer;
  C: TMcpClient;
begin
  cbConns.Items.BeginUpdate;
  try
    cbConns.Items.Clear;
    for I := 0 to FConns.Count - 1 do
    begin
      C := TMcpClient(FConns[I]);
      cbConns.Items.AddObject(Format('%s  —  %s  %s',
        [ConnServerName(C), C.Url, IfThen(C.Connected, '', '(off)')]), C);
    end;
  finally
    cbConns.Items.EndUpdate;
  end;
  cbConns.ItemIndex := FConns.IndexOf(FClient);
  lblConns.Caption := Format('Connections (%d)', [ConnectedCount]);
  btnDisconnectAll.Enabled := FConns.Count > 0;
end;

procedure TFormClient.cbConnsChange(Sender: TObject);
begin
  if (cbConns.ItemIndex >= 0) and (cbConns.ItemIndex < FConns.Count) then
    ActivateConn(TMcpClient(FConns[cbConns.ItemIndex]));
end;

{ id (server-2) or URL -> connection (connects automatically if needed)
  empty = the active connection }
function TFormClient.ConnByTarget(const ATarget: string): TMcpClient;
begin
  if Trim(ATarget) = '' then
  begin
    if not FClient.Connected then raise Exception.Create('Not connected (use connect first)');
    Exit(FClient);
  end;
  Result := FindConn(ResolveTarget(ATarget));
  if (Result = nil) or not Result.Connected then
    Result := OpenConn(ResolveTarget(ATarget), False);
end;

procedure TFormClient.RemoveAuto(const AUrl: string);
var
  I: Integer;
  Url, Id: string;
  Online: Boolean;
begin
  for I := FAuto.Count - 1 downto 0 do
    if (NormUrl(FAuto[I]) = NormUrl(AUrl)) or
       (FindPeer(FPoller, FAuto[I], Url, Id, Online) and (NormUrl(Url) = NormUrl(AUrl))) then
      FAuto.Delete(I);
end;

{ Every 5 s: connect the servers in FAuto that are online but not connected yet
  (asks the poller first, so it never blocks on a server that is down) }
procedure TFormClient.AutoConnect;
var
  I: Integer;
  Url, Id: string;
  Online: Boolean;
  C: TMcpClient;
begin
  if not chkAutoConnect.Checked or (FAuto.Count = 0) then Exit;
  if GetTickCount64 - FLastAutoTry < 5000 then Exit;
  FLastAutoTry := GetTickCount64;
  for I := 0 to FAuto.Count - 1 do
  begin
    if not FindPeer(FPoller, FAuto[I], Url, Id, Online) or not Online then Continue;
    C := FindConn(Url);
    if (C <> nil) and C.Connected then Continue;
    try
      OpenConn(Url, False);
      ClientTraffic('..', 'auto-connected to ' + Id);
    except
      on E: Exception do ClientTraffic('!!', 'auto-connect ' + Id + ': ' + E.Message);
    end;
  end;
end;

procedure TFormClient.btnConnectAllClick(Sender: TObject);
var
  Arr: TJSONArray;
  I, N: Integer;
begin
  LocalStart('connect all');
  Screen.Cursor := crHourGlass;
  Arr := ServersJSON;
  try
    N := 0;
    for I := 0 to Arr.Count - 1 do
      if Arr.Objects[I].Get('online', False) then
        try
          OpenConn(Arr.Objects[I].Get('url', ''), False);
          FAuto.Add(Arr.Objects[I].Get('id', ''));
          Inc(N);
        except
          on E: Exception do ClientTraffic('!!', E.Message);
        end;
    LocalDone(True);
    UpdateUI(Format('connected to %d servers at the same time', [ConnectedCount]));
  finally
    Arr.Free;
    Screen.Cursor := crDefault;
  end;
end;

procedure TFormClient.btnDisconnectAllClick(Sender: TObject);
begin
  while FConns.Count > 0 do CloseConn(TMcpClient(FConns[FConns.Count - 1]));
  FAuto.Clear;
  UpdateUI('all connections closed');
end;

procedure TFormClient.edUrlDropDown(Sender: TObject);
var
  Arr: TJSONArray;
  I: Integer;
  Cur: string;
begin
  Cur := edUrl.Text;
  Arr := ServersJSON;
  try
    edUrl.Items.Clear;
    for I := 0 to Arr.Count - 1 do
      edUrl.Items.Add(Arr.Objects[I].Get('url', ''));
  finally
    Arr.Free;
  end;
  edUrl.Text := Cur;
end;

{ Servers known from the peers: [{id, name, url, online, state}] }
function TFormClient.ServersJSON: TJSONArray;
var
  Specs, Jsons: TStringList;
  I: Integer;
  Id, Host, Url: string;
  Port: Word;
  D: TJSONData;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  Specs := TStringList.Create;
  Jsons := TStringList.Create;
  try
    FPoller.GetResults(Specs, Jsons);
    for I := 0 to Specs.Count - 1 do
    begin
      ParsePeerSpec(Specs[I], Id, Host, Port);
      Url := Format('http://%s:%d/mcp', [Host, Port]);
      O := nil;
      if Jsons[I] <> '' then
        try
          D := GetJSON(Jsons[I]);
          if D is TJSONObject then O := TJSONObject(D) else D.Free;
        except
          O := nil;
        end;
      try
        if O <> nil then
        begin
          if O.Get('role', '') <> 'server' then Continue;
          Result.Add(TJSONObject.Create(['id', O.Get('id', Id), 'name', O.Get('name', ''),
            'url', O.Get('mcpUrl', Url), 'online', True, 'state', O.Get('stateText', '')]));
        end
        else if Pos('server', Id) = 1 then
          Result.Add(TJSONObject.Create(['id', Id, 'name', '', 'url', Url,
            'online', False, 'state', 'Offline']));
      finally
        O.Free;
      end;
    end;
  finally
    Jsons.Free;
    Specs.Free;
  end;
end;

function TFormClient.ResolveTarget(const ATarget: string): string;
var
  Arr: TJSONArray;
  I: Integer;
begin
  if Pos('://', ATarget) > 0 then Exit(ATarget);
  Arr := ServersJSON;
  try
    for I := 0 to Arr.Count - 1 do
      if SameText(Arr.Objects[I].Get('id', ''), ATarget) then
        Exit(Arr.Objects[I].Get('url', ''));
  finally
    Arr.Free;
  end;
  raise Exception.CreateFmt('Unknown server "%s" (use list_servers, or pass a full URL)', [ATarget]);
end;

{ ---------- control endpoint: lets other sources command this client ---------- }

function TFormClient.CtlSessions: TJSONArray;
begin
  if FCtl <> nil then Result := FCtl.SessionsJSON else Result := TJSONArray.Create;
end;

procedure TFormClient.CtlLog(const AMsg: string);
begin
  ClientTraffic('CTL', AMsg);
end;

procedure TFormClient.CtlToolsList(ATools: TJSONArray);
begin
  ATools.Add(Tool('get_status', 'Identity and state of this client node and all of its server connections.', nil, []));
  ATools.Add(Tool('get_topology', 'State of every node (servers and clients) seen by this client.', nil, []));
  ATools.Add(Tool('list_servers', 'MCP servers known from the topology, with URL and online state.', nil, []));
  ATools.Add(Tool('list_connections', 'Servers this client is connected to right now (it can hold several at once).', nil, []));
  ATools.Add(Tool('connect', 'Connect this client to a server. Existing connections to other servers stay open.',
    TJSONObject.Create(['target', Prop('string', 'Server node id (e.g. "server-2") or full URL')]), ['target']));
  ATools.Add(Tool('connect_all', 'Connect to every online server at the same time.', nil, []));
  ATools.Add(Tool('disconnect', 'Disconnect from one server (default: the active one), or "all".',
    TJSONObject.Create(['target', Prop('string', 'Server id / URL, "all", or empty for the active connection')]), []));
  ATools.Add(Tool('ping', 'Ping a connected server and return the round-trip time.',
    TJSONObject.Create(['server', Prop('string', 'Server id / URL (default: active connection)')]), []));
  ATools.Add(Tool('list_tools', 'List the tools offered by a connected server.',
    TJSONObject.Create(['server', Prop('string', 'Server id / URL (default: active connection)')]), []));
  ATools.Add(Tool('call_tool', 'Call a tool on a server through this client; returns that server''s result. ' +
    'Connects automatically if needed.',
    TJSONObject.Create([
      'server', Prop('string', 'Server id (e.g. "server-1") or URL; default: the active connection'),
      'name', Prop('string', 'Tool name on that server'),
      'arguments', Prop('object', 'Arguments object for that tool')]), ['name']));
end;

procedure TFormClient.CtlToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
var
  Ok: Boolean;
begin
  FNode.CommandStarted(FCtl.CallClient, AName);
  Ok := False;
  try
    try
      DoCtlTool(AName, AArgs, AResult);
      Ok := not AResult.Get('isError', False);
    except
      on E: Exception do
        McpSetError(AResult, E.Message);
    end;
  finally
    if Ok then FNode.CommandDone(True)
    else FNode.CommandDone(False, AName + ': ' + AResult.Arrays['content'].Objects[0].Get('text', ''));
    UpdateNode;
    UpdateUI('remote: ' + AName + ' from ' + FCtl.CallClient);
  end;
end;

procedure TFormClient.DoCtlTool(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
var
  O, Res: TJSONObject;
  Arr, Content: TJSONArray;
  Args: TJSONData;
  I: Integer;
  S, ToolName: string;
  C: TMcpClient;
begin
  case AName of
    'get_status':
      begin
        O := FNode.ToJSONObject;
        try
          O.Add('connectedServers', ConnectedCount);
          O.Add('activeUrl', IfThen(FClient.Connected, FClient.Url, ''));
          O.Add('sessions', FCtl.SessionsJSON);
          McpAddText(AResult, O.FormatJSON);
        finally
          O.Free;
        end;
      end;
    'get_topology':
      begin
        O := TopologySnapshot(FNode, FPoller);
        try
          McpAddText(AResult, O.FormatJSON);
        finally
          O.Free;
        end;
      end;
    'list_servers':
      begin
        Arr := ServersJSON;
        try
          McpAddText(AResult, Arr.FormatJSON);
        finally
          Arr.Free;
        end;
      end;
    'list_connections':
      begin
        Arr := TJSONArray.Create;
        try
          for I := 0 to FConns.Count - 1 do
          begin
            C := TMcpClient(FConns[I]);
            Arr.Add(TJSONObject.Create(['server', ConnServerName(C), 'url', C.Url,
              'connected', C.Connected, 'active', C = FClient, 'requests', C.Requests,
              'errors', C.Errors, 'lastTool', C.LastTool]));
          end;
          McpAddText(AResult, Arr.FormatJSON);
        finally
          Arr.Free;
        end;
      end;
    'connect':
      begin
        S := ResolveTarget(ArgStr(AArgs, 'target'));
        C := OpenConn(S, True);
        FAuto.Add(ArgStr(AArgs, 'target'));
        McpAddText(AResult, Format('connected to %s (%s), %d tools; open connections: %d',
          [S, ConnServerName(C), lbTools.Count, ConnectedCount]));
      end;
    'connect_all':
      begin
        btnConnectAllClick(nil);
        McpAddText(AResult, Format('connected to %d servers', [ConnectedCount]));
      end;
    'disconnect':
      begin
        S := ArgStr(AArgs, 'target');
        if SameText(S, 'all') then
          btnDisconnectAllClick(nil)
        else if S = '' then
          CloseConn(FClient)
        else
          CloseConn(FindConn(ResolveTarget(S)));
        McpAddText(AResult, Format('disconnected; open connections: %d', [ConnectedCount]));
      end;
    'ping':
      begin
        C := ConnByTarget(ArgStr(AArgs, 'server'));
        C.Call('ping').Free;
        McpAddText(AResult, Format('pong from %s in %d ms', [C.Url, C.LastMs]));
      end;
    'list_tools':
      begin
        C := ConnByTarget(ArgStr(AArgs, 'server'));
        Res := C.Call('tools/list');
        try
          S := '';
          Arr := Res.Find('tools', jtArray) as TJSONArray;
          if Arr <> nil then
            for I := 0 to Arr.Count - 1 do
              S := S + Arr.Objects[I].Get('name', '') + ' — ' + Arr.Objects[I].Get('description', '') + LineEnding;
          McpAddText(AResult, S);
        finally
          Res.Free;
        end;
      end;
    'call_tool':
      begin
        C := ConnByTarget(ArgStr(AArgs, 'server'));
        ToolName := ArgStr(AArgs, 'name');
        Args := AArgs.Find('arguments');
        if (Args = nil) or (Args.JSONType <> jtObject) then Args := TJSONObject.Create
        else Args := Args.Clone;
        C.LastTool := ToolName;
        S := Args.FormatJSON; // Args is freed together with the request
        Res := C.Call('tools/call', TJSONObject.Create(['name', ToolName, 'arguments', Args]));
        try
          ClientTraffic('CTL', Format('%s -> %s.%s', [FCtl.CallClient, ConnServerName(C), ToolName]));
          if C = FClient then
          begin
            ShowToolResult(Res); // so the person at this machine sees the result too
            I := lbTools.Items.IndexOf(ToolName);
            if I >= 0 then lbTools.ItemIndex := I;
            memArgs.Text := S;
          end;
          Content := Res.Find('content', jtArray) as TJSONArray;
          if Content <> nil then AResult.Add('content', Content.Clone);
          if Res.Get('isError', False) then AResult.Booleans['isError'] := True;
        finally
          Res.Free;
        end;
      end;
  else
    McpSetError(AResult, 'Unknown tool: ' + AName);
  end;
end;

procedure TFormClient.FormDestroy(Sender: TObject);
var
  Ini: TIniFile;
  I: Integer;
  C: TMcpClient;
begin
  try
    Ini := TIniFile.Create(IniName);
    try
      Ini.WriteString('Client', 'Url', Trim(edUrl.Text));
      Ini.WriteInteger('Client', 'Timeout', seTimeout.Value);
      Ini.WriteString('Remote', 'AutoConnect', FAuto.DelimitedText);
      Ini.WriteBool('Remote', 'AutoConnectEnabled', chkAutoConnect.Checked);
    finally
      Ini.Free;
    end;
  except
  end;
  tmrNode.Enabled := False;
  FTopo.LocalNode := nil;
  FTopo.Poller := nil;
  FTopo.SessionsFunc := nil;
  if FCtl <> nil then FCtl.StopAndWait;
  FreeAndNil(FCtl);
  for I := 0 to FConns.Count - 1 do
  begin
    C := TMcpClient(FConns[I]);
    C.OnTraffic := nil;
    C.Timeout := 800; // the server may be shutting down at the same time -> do not wait long
    try
      C.Disconnect;
    except
    end;
    C.Free;
  end;
  FConns.Free;
  FIdle.Free;
  FAuto.Free;
  FPoller.StopAndWait;
  FPoller.Free;
  FNode.Free;
  FTools.Free;
end;

procedure TFormClient.ClientTraffic(const ADirection, AText: string);
var
  P: Integer;
  Head, Body: string;
begin
  P := Pos(LineEnding, AText);
  if P > 0 then
  begin
    Head := Copy(AText, 1, P - 1);
    Body := Copy(AText, P + Length(LineEnding), MaxInt);
  end
  else
  begin
    Head := AText;
    Body := '';
  end;
  memLog.Lines.BeginUpdate;
  try
    memLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + ' ' + ADirection + ' ' + Head);
    if chkLogBodies.Checked and (Body <> '') then
      memLog.Lines.Add('    ' + Shorten(Body, MAX_LOG_BODY));
    while memLog.Lines.Count > 3000 do memLog.Lines.Delete(0);
  finally
    memLog.Lines.EndUpdate;
  end;
  memLog.SelStart := Length(memLog.Text);
end;

procedure TFormClient.PrepareClient;
begin
  // an open connection never changes its URL; edUrl is only used while not connected
  if not FClient.Connected then FClient.Url := Trim(edUrl.Text);
  FClient.Timeout := seTimeout.Value;
end;

procedure TFormClient.UpdateUI(const AMsg: string);
var
  S: string;
begin
  btnDisconnect.Enabled := FClient.Connected;
  miDisconnect.Enabled := FClient.Connected;
  btnCall.Enabled := FClient.Connected and (lbTools.ItemIndex >= 0);
  miRefreshTools.Enabled := FClient.Connected;
  if FClient.Connected then
    S := Format('Active: %s | %d connections | protocol %s',
      [ConnServerName(FClient), ConnectedCount, FClient.ProtocolVersion])
  else
    S := 'Disconnected';
  if FClient.SessionId <> '' then S := S + ' | session ' + FClient.SessionId;
  S := S + Format(' | requests %d | errors %d | last %d ms',
    [FClient.Requests, FClient.Errors, FClient.LastMs]);
  if AMsg <> '' then S := S + ' | ' + AMsg;
  StatusBar1.SimpleText := S;
  if FClient.Connected then
    Caption := 'MCP Client — ' + FClient.Url
  else
    Caption := 'MCP Client';
end;

procedure TFormClient.ShowError(const AWhat: string; E: Exception);
begin
  UpdateUI(AWhat + ' failed');
  MessageDlg(AWhat, E.Message, mtError, [mbOK], 0);
end;

procedure TFormClient.btnConnectClick(Sender: TObject);
var
  Url: string;
  C: TMcpClient;
begin
  Url := Trim(edUrl.Text);
  if (UrlPort(Url) = FSettings.Port) and IsLoopbackUrl(Url) then
  begin
    MessageDlg('This URL is the control endpoint of this client itself', mtWarning, [mbOK], 0);
    Exit;
  end;
  LocalStart('connect');
  Screen.Cursor := crHourGlass;
  try
    try
      // add a new connection (existing ones stay open)
      C := FindConn(Url);
      if C <> nil then C.Disconnect; // pressing Connect again = initialize again
      C := OpenConn(Url, True);
      FAuto.Add(Url);
      LocalDone(True);
      UpdateUI(Format('connected: %s (%d tools) — %d servers open',
        [ConnServerName(C), lbTools.Count, ConnectedCount]));
    except
      on E: Exception do
      begin
        LocalDone(False, 'connect: ' + E.Message);
        ShowError('Connect', E);
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TFormClient.btnDisconnectClick(Sender: TObject);
begin
  // close only the active connection
  CloseConn(FClient);
  UpdateUI('disconnected');
end;

procedure TFormClient.btnPingClick(Sender: TObject);
var
  R: TJSONObject;
begin
  PrepareClient;
  LocalStart('ping');
  try
    R := FClient.Call('ping');
    R.Free;
    LocalDone(True);
    UpdateUI(Format('ping OK (%d ms)', [FClient.LastMs]));
  except
    on E: Exception do
    begin
      LocalDone(False, 'ping: ' + E.Message);
      ShowError('Ping', E);
    end;
  end;
end;

procedure TFormClient.miRefreshToolsClick(Sender: TObject);
begin
  try
    RefreshTools;
    UpdateUI(Format('%d tools', [lbTools.Count]));
  except
    on E: Exception do ShowError('tools/list', E);
  end;
end;

procedure TFormClient.RefreshTools;
var
  R: TJSONObject;
  I: Integer;
begin
  R := FClient.Call('tools/list');
  try
    FreeAndNil(FTools);
    FTools := TJSONArray(R.Arrays['tools'].Clone);
    FToolsUrl := FClient.Url;
  finally
    R.Free;
  end;
  lbTools.Items.BeginUpdate;
  try
    lbTools.Clear;
    for I := 0 to FTools.Count - 1 do
      lbTools.Items.Add(FTools.Objects[I].Get('name', '?'));
  finally
    lbTools.Items.EndUpdate;
  end;
  if lbTools.Count > 0 then
  begin
    lbTools.ItemIndex := 0;
    lbToolsSelectionChange(nil, False);
  end;
end;

function TFormClient.SelectedTool: TJSONObject;
begin
  Result := nil;
  if (FTools <> nil) and (lbTools.ItemIndex >= 0) and (lbTools.ItemIndex < FTools.Count) then
    Result := FTools.Objects[lbTools.ItemIndex];
end;

function TFormClient.BuildTemplate(ATool: TJSONObject): string;
var
  Schema, Props, Args: TJSONObject;
  Req: TJSONArray;
  I: Integer;
  PName, PType: string;
  P: TJSONData;
begin
  Args := TJSONObject.Create;
  try
    Schema := ATool.Find('inputSchema', jtObject) as TJSONObject;
    if Schema <> nil then
    begin
      Props := Schema.Find('properties', jtObject) as TJSONObject;
      Req := Schema.Find('required', jtArray) as TJSONArray;
      if (Props <> nil) and (Req <> nil) then
        for I := 0 to Req.Count - 1 do
        begin
          PName := Req.Strings[I];
          P := Props.Find(PName);
          PType := '';
          if P is TJSONObject then PType := TJSONObject(P).Get('type', '');
          case PType of
            'integer', 'number': Args.Add(PName, 0);
            'boolean': Args.Add(PName, False);
            'array': Args.Add(PName, TJSONArray.Create);
            'object': Args.Add(PName, TJSONObject.Create);
          else
            Args.Add(PName, '');
          end;
        end;
    end;
    Result := Args.FormatJSON;
  finally
    Args.Free;
  end;
end;

procedure TFormClient.lbToolsSelectionChange(Sender: TObject; User: boolean);
var
  T: TJSONObject;
  Schema: TJSONData;
begin
  T := SelectedTool;
  if T = nil then Exit;
  lblToolName.Caption := T.Get('name', '');
  memSchema.Lines.Text := T.Get('description', '') + LineEnding + LineEnding;
  Schema := T.Find('inputSchema');
  if Schema <> nil then memSchema.Lines.Add(Schema.FormatJSON);
  memArgs.Text := BuildTemplate(T);
  UpdateUI;
end;

procedure TFormClient.btnTemplateClick(Sender: TObject);
var
  T: TJSONObject;
begin
  T := SelectedTool;
  if T <> nil then memArgs.Text := BuildTemplate(T);
end;

procedure TFormClient.LoadImage(const ABase64, AMime: string);
var
  S: TStringStream;
  Png: TPortableNetworkGraphic;
  Jpg: TJPEGImage;
begin
  S := TStringStream.Create(DecodeStringBase64(ABase64));
  try
    if Pos('png', AMime) > 0 then
    begin
      Png := TPortableNetworkGraphic.Create;
      try
        Png.LoadFromStream(S);
        imgResult.Picture.Assign(Png);
      finally
        Png.Free;
      end;
    end
    else if Pos('jpeg', AMime) > 0 then
    begin
      Jpg := TJPEGImage.Create;
      try
        Jpg.LoadFromStream(S);
        imgResult.Picture.Assign(Jpg);
      finally
        Jpg.Free;
      end;
    end
    else
      imgResult.Picture.LoadFromStream(S);
  finally
    S.Free;
  end;
end;

procedure TFormClient.ShowToolResult(ARes: TJSONObject);
var
  Content: TJSONArray;
  Item: TJSONObject;
  I, NImg: Integer;
  IsErr: Boolean;
  Kind: string;
begin
  memResult.Clear;
  imgResult.Picture.Clear;
  NImg := 0;
  IsErr := ARes.Get('isError', False);
  if IsErr then memResult.Lines.Add('[isError = true]');
  Content := ARes.Find('content', jtArray) as TJSONArray;
  if Content <> nil then
    for I := 0 to Content.Count - 1 do
    begin
      if not (Content.Items[I] is TJSONObject) then Continue;
      Item := Content.Objects[I];
      Kind := Item.Get('type', '');
      if Kind = 'text' then
        memResult.Lines.Add(Item.Get('text', ''))
      else if Kind = 'image' then
      begin
        Inc(NImg);
        LoadImage(Item.Get('data', ''), Item.Get('mimeType', ''));
        memResult.Lines.Add(Format('[image %s, %d bytes base64 -> see the Image tab]',
          [Item.Get('mimeType', ''), Length(Item.Get('data', ''))]));
      end
      else
        memResult.Lines.Add('[' + Kind + '] ' + Item.AsJSON);
    end;
  if ARes.Find('structuredContent') <> nil then
    memResult.Lines.Add('structuredContent: ' + ARes.Find('structuredContent').FormatJSON);

  if NImg > 0 then pcResult.ActivePage := tsImage else pcResult.ActivePage := tsText;
  if IsErr then
  begin
    lblCallInfo.Font.Color := clRed;
    lblCallInfo.Caption := Format('ERROR  (%d ms)', [FClient.LastMs]);
  end
  else
  begin
    lblCallInfo.Font.Color := clGreen;
    lblCallInfo.Caption := Format('OK  (%d ms)', [FClient.LastMs]);
  end;
end;

procedure TFormClient.btnCallClick(Sender: TObject);
var
  T: TJSONObject;
  Args: TJSONData;
  Res: TJSONObject;
  ArgText: string;
begin
  T := SelectedTool;
  if T = nil then Exit;
  ArgText := Trim(memArgs.Text);
  if ArgText = '' then ArgText := '{}';
  try
    Args := GetJSON(ArgText);
  except
    on E: Exception do
    begin
      MessageDlg('Arguments are not valid JSON', E.Message, mtWarning, [mbOK], 0);
      Exit;
    end;
  end;
  if not (Args is TJSONObject) then
  begin
    Args.Free;
    MessageDlg('Arguments must be a JSON object { ... }', mtWarning, [mbOK], 0);
    Exit;
  end;

  PrepareClient;
  FClient.LastTool := T.Get('name', '');
  LocalStart('call ' + FClient.LastTool);
  Screen.Cursor := crHourGlass;
  try
    try
      Res := FClient.Call('tools/call',
        TJSONObject.Create(['name', T.Get('name', ''), 'arguments', Args]));
      try
        ShowToolResult(Res);
        if Res.Get('isError', False) then LocalDone(False, FClient.LastTool + ' returned isError')
        else LocalDone(True);
      finally
        Res.Free;
      end;
      UpdateUI('tools/call ' + T.Get('name', ''));
    except
      on E: Exception do
      begin
        LocalDone(False, FClient.LastTool + ': ' + E.Message);
        lblCallInfo.Font.Color := clRed;
        lblCallInfo.Caption := 'FAILED';
        ShowError('tools/call', E);
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

{ ---------- Raw JSON-RPC ---------- }

procedure TFormClient.cbRawMethodChange(Sender: TObject);
const
  Templates: array[0..7] of string = (
    '{"jsonrpc":"2.0","id":100,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":101,"method":"tools/list"}',
    '{"jsonrpc":"2.0","id":102,"method":"ping"}',
    '{"jsonrpc":"2.0","id":103,"method":"tools/call","params":{"name":"get_status","arguments":{"log_lines":5}}}',
    '[{"jsonrpc":"2.0","id":104,"method":"ping"},{"jsonrpc":"2.0","id":105,"method":"tools/list"}]',
    '{"jsonrpc":"2.0","id":106,"method":"no/such/method"}',
    '{ this is not json');
begin
  if (cbRawMethod.ItemIndex >= 0) and (cbRawMethod.ItemIndex <= High(Templates)) then
    memRawReq.Text := PrettyJson(Templates[cbRawMethod.ItemIndex]);
end;

procedure TFormClient.btnRawSendClick(Sender: TObject);
var
  Body, Resp: string;
  RawC: TMcpClient;
begin
  PrepareClient;
  Body := memRawReq.Text;
  // send as a single line when it is valid JSON
  try
    with GetJSON(Body) do
    try
      Body := AsJSON;
    finally
      Free;
    end;
  except
    // invalid JSON on purpose -> send it as typed
  end;
  Screen.Cursor := crHourGlass;
  try
    try
      // send to the URL in the Server URL box (using that connection's session if there is one)
      RawC := FindConn(Trim(edUrl.Text));
      if RawC = nil then
      begin
        RawC := FIdle;
        FIdle.Url := Trim(edUrl.Text);
      end;
      Resp := RawC.PostRaw(Body);
      memRawResp.Text := Format('HTTP %d  |  %d ms  |  %s',
        [RawC.LastStatus, RawC.LastMs, RawC.LastContentType]) +
        LineEnding + LineEnding + PrettyJson(Resp);
      UpdateUI('raw sent');
    except
      on E: Exception do
      begin
        memRawResp.Text := 'ERROR: ' + E.Message;
        UpdateUI('raw failed');
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

{ ---------- Test suite ---------- }

function TFormClient.RawJson(const ABody: string; const AMethod: string): TJSONObject;
var
  S: string;
  D: TJSONData;
begin
  Result := nil;
  S := FClient.PostRaw(ABody, AMethod);
  if Trim(S) = '' then Exit;
  try
    D := GetJSON(S);
    if D is TJSONObject then Result := TJSONObject(D) else D.Free;
  except
    Result := nil;
  end;
end;

procedure TFormClient.Check(const AName: string; AOk: Boolean; const AInfo: string);
begin
  if AOk then
  begin
    Inc(FPass);
    memTest.Lines.Add(Format('[PASS] %-38s %s', [AName, AInfo]));
  end
  else
  begin
    Inc(FFail);
    memTest.Lines.Add(Format('[FAIL] %-38s %s', [AName, AInfo]));
  end;
  Application.ProcessMessages;
end;

procedure TFormClient.btnRunTestsClick(Sender: TObject);
var
  R, Res: TJSONObject;
  T0: QWord;
  HasGetForm: Boolean;
  I: Integer;

  function Ms: string;
  begin
    Result := Format('(%d ms)', [FClient.LastMs]);
  end;

  function ErrCode(O: TJSONObject): Integer;
  begin
    Result := 0;
    if (O <> nil) and (O.Find('error', jtObject) <> nil) then
      Result := O.Objects['error'].Get('code', 0);
  end;

begin
  PageControl1.ActivePage := tsTest;
  LocalStart('test suite');
  memTest.Clear;
  FPass := 0;
  FFail := 0;
  // test the URL in the Server URL box (added as one more connection, others are not affected)
  FClient := EnsureConn(Trim(edUrl.Text));
  PrepareClient;
  memTest.Lines.Add('MCP test suite -> ' + FClient.Url);
  memTest.Lines.Add(StringOfChar('-', 70));
  T0 := GetTickCount64;
  Screen.Cursor := crHourGlass;
  try
    // 1. initialize + session
    try
      FClient.Connect(FSettings.NodeId, CLIENT_VERSION);
      memServer.Text := FClient.ServerInfo.FormatJSON;
      Check('initialize', FClient.ServerInfo.Find('serverInfo') <> nil,
        Format('server=%s protocol=%s %s',
          [FClient.ServerInfo.FindPath('serverInfo.name').AsString, FClient.ProtocolVersion, Ms]));
      Check('capabilities.tools', FClient.ServerInfo.FindPath('capabilities.tools') <> nil, '');
    except
      on E: Exception do
      begin
        Check('initialize', False, E.Message);
        memTest.Lines.Add('Stopped: cannot connect to server');
        Exit;
      end;
    end;

    // 2. notification -> 202 without a body
    try
      FClient.PostRaw('{"jsonrpc":"2.0","method":"notifications/initialized"}');
      Check('notification -> HTTP 202', FClient.LastStatus = 202, Format('HTTP %d %s', [FClient.LastStatus, Ms]));
    except
      on E: Exception do Check('notification -> HTTP 202', False, E.Message);
    end;

    // 3. tools/list
    HasGetForm := False;
    try
      RefreshTools;
      for I := 0 to lbTools.Count - 1 do
        if lbTools.Items[I] = 'get_form' then HasGetForm := True;
      Check('tools/list', lbTools.Count > 0, Format('%d tools %s', [lbTools.Count, Ms]));
    except
      on E: Exception do Check('tools/list', False, E.Message);
    end;

    // 4. ping
    try
      R := FClient.Call('ping');
      R.Free;
      Check('ping', True, Ms);
    except
      on E: Exception do Check('ping', False, E.Message);
    end;

    // 5. batch
    R := nil;
    try
      try
        FClient.PostRaw('[{"jsonrpc":"2.0","id":901,"method":"ping"},{"jsonrpc":"2.0","id":902,"method":"ping"}]');
        Check('batch request', FClient.LastStatus = 200, Format('HTTP %d %s', [FClient.LastStatus, Ms]));
      except
        on E: Exception do Check('batch request', False, E.Message);
      end;
    finally
      R.Free;
    end;

    // 6. unknown method -> -32601
    R := nil;
    try
      try
        R := RawJson('{"jsonrpc":"2.0","id":903,"method":"no/such/method"}');
        Check('unknown method -> -32601', ErrCode(R) = -32601, Format('code %d %s', [ErrCode(R), Ms]));
      except
        on E: Exception do Check('unknown method -> -32601', False, E.Message);
      end;
    finally
      R.Free;
    end;

    // 7. parse error -> -32700
    R := nil;
    try
      try
        R := RawJson('{ this is not json');
        Check('invalid JSON -> -32700', ErrCode(R) = -32700, Format('code %d %s', [ErrCode(R), Ms]));
      except
        on E: Exception do Check('invalid JSON -> -32700', False, E.Message);
      end;
    finally
      R.Free;
    end;

    // 8. tools/call of a tool that exists
    if HasGetForm then
      try
        Res := FClient.Call('tools/call', TJSONObject.Create(['name', 'get_form', 'arguments', TJSONObject.Create]));
        try
          Check('tools/call get_form', (Res.Find('content', jtArray) <> nil) and not Res.Get('isError', False), Ms);
        finally
          Res.Free;
        end;
      except
        on E: Exception do Check('tools/call get_form', False, E.Message);
      end
    else
      memTest.Lines.Add('[SKIP] tools/call get_form                  server has no such tool');

    // 9. tools/call of a tool that does not exist -> isError
    try
      Res := FClient.Call('tools/call', TJSONObject.Create(['name', 'no_such_tool', 'arguments', TJSONObject.Create]));
      try
        Check('unknown tool -> isError', Res.Get('isError', False), Ms);
      finally
        Res.Free;
      end;
    except
      on E: Exception do
        // some servers reply with a JSON-RPC error instead of isError; that is fine too
        Check('unknown tool -> error', Pos('RPC error', E.Message) > 0, E.Message);
    end;

    // 10. GET endpoint (this server has no SSE stream -> 405)
    try
      FClient.PostRaw('', 'GET');
      Check('GET endpoint -> 405 (no SSE)', FClient.LastStatus = 405,
        Format('HTTP %d %s', [FClient.LastStatus, Ms]));
    except
      on E: Exception do Check('GET endpoint -> 405 (no SSE)', False, E.Message);
    end;

  finally
    Screen.Cursor := crDefault;
    memTest.Lines.Add(StringOfChar('-', 70));
    memTest.Lines.Add(Format('Result: %d passed, %d failed, total %d ms',
      [FPass, FFail, GetTickCount64 - T0]));
    UpdateUI(Format('tests: %d pass / %d fail', [FPass, FFail]));
    LocalDone(FFail = 0, Format('%d tests failed', [FFail]));
    PruneConns; // drop connections that failed
    if FClient.Connected then ActivateConn(FClient) else RefreshConnList;
  end;
end;

procedure TFormClient.btnClearLogClick(Sender: TObject);
begin
  memLog.Clear;
end;

procedure TFormClient.miFileExitClick(Sender: TObject);
begin
  Close;
end;

end.
