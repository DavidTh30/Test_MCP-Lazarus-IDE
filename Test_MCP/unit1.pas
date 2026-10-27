unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, Menus,
  LCLIntf, LCLType, TypInfo, fpjson, base64, McpConfig, McpServer, McpClientCore, NodeState;

type

  { TForm1 }

  TForm1 = class(TForm)
    MainMenu1: TMainMenu;
    miFile: TMenuItem;
    miFileExit: TMenuItem;
    miMcp: TMenuItem;
    miMcpConfig: TMenuItem;
    miMcpStatus: TMenuItem;
    miMcpTopology: TMenuItem;
    miMcpUplink: TMenuItem;
    procedure miMcpUplinkClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure miFileExitClick(Sender: TObject);
    procedure miMcpConfigClick(Sender: TObject);
    procedure miMcpStatusClick(Sender: TObject);
    procedure miMcpTopologyClick(Sender: TObject);
  private
    FMcp: TMcpServerThread;
    FNode: TLocalNode;
    FPoller: TPeerPoller;
    FNodeTimer: TTimer;
    FNodePanel: TPanel; // node status bar (Owner = nil -> not touched by clear_form / get_form)
    FSettings: TMcpSettings;
    FClickMsgs: TStringList;
    FLogLines: TStringList;
    FLogVersion: Integer;
    FLogFile: string;
    FUplink: TMcpClient;     // server-1 -> server-2 (this server acting as a client of another server)
    FUplinkTry: QWord;
    FUplinkId: string;
    procedure UplinkTick(AForce: Boolean = False);
    procedure UplinkDisconnect;
    function UplinkJSON: TJSONObject;
    procedure CreateNode;
    procedure FreeNode;
    procedure NodeTimer(Sender: TObject);
    function SessionsFunc: TJSONArray;
    procedure McpLog(const AMsg: string);
    procedure McpToolsList(ATools: TJSONArray);
    procedure McpToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
    procedure DoToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
    function FindTarget(const AName: string): TComponent;
    function ControlInfo(C: TControl): TJSONObject;
    procedure DynClick(Sender: TObject);
    // tools
    procedure ToolGetForm(AResult: TJSONObject);
    procedure ToolSetForm(AArgs, AResult: TJSONObject);
    procedure ToolAddControl(AArgs, AResult: TJSONObject);
    procedure ToolSetProperty(AArgs, AResult: TJSONObject);
    procedure ToolGetProperty(AArgs, AResult: TJSONObject);
    procedure ToolDeleteControl(AArgs, AResult: TJSONObject);
    procedure ToolClearForm(AResult: TJSONObject);
    procedure ToolScreenshot(AResult: TJSONObject);
    procedure ToolGetStatus(AArgs, AResult: TJSONObject);
    procedure UpdateMcpMenu;
  public
    procedure StartServer;
    procedure StopServer;
    function ServerActive: Boolean;
    procedure ClearLog;
    { Full status (app / server / client / settings / form) for the Status window and the get_status tool }
    function BuildStatusJSON: TJSONObject;
    property Settings: TMcpSettings read FSettings;
    property LogLines: TStringList read FLogLines;
    property LogVersion: Integer read FLogVersion;
  end;

var
  Form1: TForm1;

implementation

uses
  Math, StrUtils, IniFiles, LCLVersion, BGRABitmapTypes, ConfigForm, StatusForm, TopoView;

{$R *.lfm}

{ ---------- helpers ---------- }

function ParseColor(const S: string): TColor;
var
  V: string;
  R, G, B: Integer;
begin
  V := Trim(S);
  if (Length(V) = 7) and (V[1] = '#') then
  begin
    R := StrToInt('$' + Copy(V, 2, 2));
    G := StrToInt('$' + Copy(V, 4, 2));
    B := StrToInt('$' + Copy(V, 6, 2));
    Result := RGBToColor(R, G, B);
  end
  else
    Result := StringToColor(V); // clRed, clBtnFace, $00FF0000, 255
end;

function ArgStr(AArgs: TJSONObject; const AKey: string; const ADef: string = ''): string;
var
  D: TJSONData;
begin
  D := AArgs.Find(AKey);
  if (D = nil) or (D.JSONType = jtNull) then Result := ADef else Result := D.AsString;
end;

function ArgInt(AArgs: TJSONObject; const AKey: string; ADef: Integer): Integer;
var
  D: TJSONData;
begin
  D := AArgs.Find(AKey);
  if (D = nil) or (D.JSONType = jtNull) then Result := ADef
  else if D.JSONType = jtNumber then Result := D.AsInteger
  else Result := StrToIntDef(D.AsString, ADef);
end;

function HasArg(AArgs: TJSONObject; const AKey: string): Boolean;
begin
  Result := (AArgs.Find(AKey) <> nil) and (AArgs.Find(AKey).JSONType <> jtNull);
end;

{ Split "Font.Color" -> target object + last property name }
function ResolvePath(AObj: TObject; const APath: string; out AProp: string): TObject;
var
  Parts: TStringArray;
  I: Integer;
begin
  Parts := APath.Split(['.']);
  Result := AObj;
  for I := 0 to High(Parts) - 1 do
  begin
    if not IsPublishedProp(Result, Parts[I]) then
      raise Exception.CreateFmt('Unknown property "%s"', [Parts[I]]);
    Result := GetObjectProp(Result, Parts[I]);
    if Result = nil then
      raise Exception.CreateFmt('Property "%s" is nil', [Parts[I]]);
  end;
  AProp := Parts[High(Parts)];
end;

procedure SetPropFromString(AObj: TObject; const APath, AValue: string);
var
  Obj, Sub: TObject;
  PropName: string;
  PI: PPropInfo;
begin
  Obj := ResolvePath(AObj, APath, PropName);
  PI := GetPropInfo(Obj, PropName);
  if PI = nil then
    raise Exception.CreateFmt('Unknown property "%s" on %s', [PropName, Obj.ClassName]);
  case PI^.PropType^.Kind of
    tkInteger:
      if (PI^.PropType^.Name = 'TColor') or (PI^.PropType^.Name = 'TGraphicsColor') then
        SetOrdProp(Obj, PI, ParseColor(AValue))
      else
        SetOrdProp(Obj, PI, StrToInt(AValue));
    tkInt64, tkQWord:
      SetInt64Prop(Obj, PI, StrToInt64(AValue));
    tkChar, tkWChar:
      if AValue <> '' then SetOrdProp(Obj, PI, Ord(AValue[1]));
    tkEnumeration:
      SetEnumProp(Obj, PI, AValue);
    tkBool:
      SetOrdProp(Obj, PI, Ord(StrToBool(AValue)));
    tkSet:
      SetSetProp(Obj, PI, AValue);
    tkFloat:
      SetFloatProp(Obj, PI, StrToFloat(AValue, DefaultFormatSettings));
    tkSString, tkLString, tkAString, tkUString, tkWString:
      SetStrProp(Obj, PI, AValue);
    tkClass:
      begin
        Sub := GetObjectProp(Obj, PI);
        if Sub is TStrings then
          TStrings(Sub).Text := AValue
        else
          raise Exception.CreateFmt('Cannot set object property "%s" from text', [PropName]);
      end;
  else
    raise Exception.CreateFmt('Unsupported property type for "%s"', [PropName]);
  end;
end;

function GetPropAsString(AObj: TObject; const APath: string): string;
var
  Obj, Sub: TObject;
  PropName: string;
  PI: PPropInfo;
begin
  Obj := ResolvePath(AObj, APath, PropName);
  PI := GetPropInfo(Obj, PropName);
  if PI = nil then
    raise Exception.CreateFmt('Unknown property "%s" on %s', [PropName, Obj.ClassName]);
  if PI^.PropType^.Kind = tkClass then
  begin
    Sub := GetObjectProp(Obj, PI);
    if Sub is TStrings then Result := TStrings(Sub).Text
    else if Sub = nil then Result := 'nil'
    else Result := Sub.ClassName;
  end
  else if (PI^.PropType^.Kind = tkInteger) and
          ((PI^.PropType^.Name = 'TColor') or (PI^.PropType^.Name = 'TGraphicsColor')) then
    Result := ColorToString(GetOrdProp(Obj, PI))
  else
    Result := GetPropValue(Obj, PI, True);
end;

function ControlClassFor(const AType: string): TControlClass;
var
  T: string;
begin
  T := LowerCase(AType);
  if (T <> '') and (T[1] = 't') then Delete(T, 1, 1);
  case T of
    'label':       Result := TLabel;
    'button':      Result := TButton;
    'edit':        Result := TEdit;
    'memo':        Result := TMemo;
    'checkbox':    Result := TCheckBox;
    'radiobutton': Result := TRadioButton;
    'combobox':    Result := TComboBox;
    'listbox':     Result := TListBox;
    'panel':       Result := TPanel;
    'groupbox':    Result := TGroupBox;
    'shape':       Result := TShape;
    'image':       Result := TImage;
  else
    Result := nil;
  end;
end;

{ ---------- tool schema ---------- }

function Prop(const AType, ADesc: string): TJSONObject;
begin
  Result := TJSONObject.Create(['type', AType, 'description', ADesc]);
end;

function Tool(const AName, ADesc: string; AProps: TJSONObject;
  const ARequired: array of string): TJSONObject;
var
  Schema: TJSONObject;
  Req: TJSONArray;
  S: string;
begin
  Schema := TJSONObject.Create(['type', 'object']);
  if AProps = nil then AProps := TJSONObject.Create;
  Schema.Add('properties', AProps);
  if Length(ARequired) > 0 then
  begin
    Req := TJSONArray.Create;
    for S in ARequired do Req.Add(S);
    Schema.Add('required', Req);
  end;
  Result := TJSONObject.Create(['name', AName, 'description', ADesc]);
  Result.Add('inputSchema', Schema);
end;

procedure TForm1.McpToolsList(ATools: TJSONArray);
begin
  ATools.Add(Tool('get_form',
    'Get the form''s caption, size, color and the list of all controls on it.', nil, []));

  ATools.Add(Tool('set_form', 'Change the form itself (any field optional).',
    TJSONObject.Create([
      'caption', Prop('string', 'Window title'),
      'width', Prop('integer', 'Client width in pixels'),
      'height', Prop('integer', 'Client height in pixels'),
      'color', Prop('string', 'Background color: clRed, clBtnFace, #RRGGBB ...')]), []));

  ATools.Add(Tool('add_control',
    'Add a control to the form. type: Label, Button, Edit, Memo, CheckBox, RadioButton, ' +
    'ComboBox, ListBox, Panel, GroupBox, Shape, Image.',
    TJSONObject.Create([
      'type', Prop('string', 'Control type, e.g. Button'),
      'name', Prop('string', 'Component name (identifier). Auto-generated if empty'),
      'parent', Prop('string', 'Name of a Panel/GroupBox to place it in (default: the form)'),
      'text', Prop('string', 'Caption or Text. For Memo/ListBox/ComboBox: lines separated by \n'),
      'left', Prop('integer', 'X position'),
      'top', Prop('integer', 'Y position'),
      'width', Prop('integer', 'Width'),
      'height', Prop('integer', 'Height'),
      'onclick_message', Prop('string', 'Optional: show this message box when the control is clicked')]),
    ['type']));

  ATools.Add(Tool('set_property',
    'Set any published property via RTTI on a control or on the form (target "Form1"). ' +
    'Supports dotted paths like Font.Color, Font.Size, Font.Style ("[fsBold]"), Align ("alClient"), ' +
    'Anchors, Enabled, Visible, Lines / Items (text with \n).',
    TJSONObject.Create([
      'target', Prop('string', 'Control name, or Form1'),
      'property', Prop('string', 'Property name, e.g. Caption or Font.Size'),
      'value', Prop('string', 'New value as text')]),
    ['target', 'property', 'value']));

  ATools.Add(Tool('get_property', 'Read a published property (dotted paths allowed).',
    TJSONObject.Create([
      'target', Prop('string', 'Control name, or Form1'),
      'property', Prop('string', 'Property name')]),
    ['target', 'property']));

  ATools.Add(Tool('delete_control', 'Remove a control (and its children) from the form.',
    TJSONObject.Create(['name', Prop('string', 'Control name')]), ['name']));

  ATools.Add(Tool('clear_form', 'Remove every control, returning to an empty form.', nil, []));

  ATools.Add(Tool('screenshot', 'Capture the form client area as a PNG image.', nil, []));

  ATools.Add(Tool('get_status',
    'Diagnostics: app info, MCP server state/stats, connected client, settings, ' +
    'form summary and recent log lines (same data as MCP > Status window).',
    TJSONObject.Create(['log_lines', Prop('integer', 'How many recent log lines to include (default 20)')]),
    []));

  ATools.Add(Tool('get_topology',
    'State of this node and of every peer node (servers / clients) seen on the network, ' +
    'including which clients are connected to which servers.', nil, []));

  ATools.Add(Tool('uplink_status',
    'This server is also a client of another server (uplink, default server-2). Shows that link.', nil, []));
  ATools.Add(Tool('uplink_list_tools', 'List the tools of the uplink server (server-2).', nil, []));
  ATools.Add(Tool('uplink_call',
    'Call a tool on the uplink server (server-2) through this server; returns its result.',
    TJSONObject.Create([
      'name', Prop('string', 'Tool name on the uplink server, e.g. set_output'),
      'arguments', Prop('object', 'Arguments object for that tool')]), ['name']));
end;

{ ---------- form ---------- }

procedure TForm1.FormCreate(Sender: TObject);
begin
  FClickMsgs := TStringList.Create;
  FLogLines := TStringList.Create;
  FLogFile := ChangeFileExt(Application.ExeName, '.mcp.log');

  FSettings := DefaultSettings;
  FSettings.UplinkEnabled := True;   // by default server-1 connects to server-2
  FSettings.Uplink := 'server-2';
  LoadSettings(FSettings); // ini + --port= --node= --peers=

  FUplink := TMcpClient.Create;
  FUplink.Timeout := 3000;
  FUplink.OnTraffic := nil;

  // node status bar at the bottom of the form
  FNodePanel := TPanel.Create(nil);
  FNodePanel.Parent := Self;
  FNodePanel.Align := alBottom;
  FNodePanel.Height := 26;
  FNodePanel.BevelOuter := bvNone;
  FNodePanel.Alignment := taLeftJustify;
  FNodePanel.Font.Color := clWhite;
  FNodePanel.Font.Style := [fsBold];
  FNodePanel.ParentBackground := False;
  FNodePanel.ShowHint := True;
  FNodePanel.OnDblClick := @miMcpTopologyClick;

  CreateNode;
  FNodeTimer := TTimer.Create(Self);
  FNodeTimer.Interval := 500;
  FNodeTimer.OnTimer := @NodeTimer;

  if FSettings.Enabled then StartServer else UpdateMcpMenu;
  NodeTimer(nil);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FNodeTimer.Enabled := False;
  FUplink.Timeout := 800; // the other side may be shutting down at the same time
  UplinkDisconnect;
  FreeAndNil(FUplink);
  StopServer;
  FreeNode;
  FreeAndNil(FNodePanel);
  FLogLines.Free;
  FClickMsgs.Free;
end;

procedure TForm1.CreateNode;
begin
  FNode := TLocalNode.Create(FSettings.NodeId, FSettings.NodeName,
    'MCP server: live LCL form designer', nrServer, '127.0.0.1', FSettings.Port);
  FNode.SetEndpoint('127.0.0.1', FSettings.Port, ClientUrl(FSettings));
  FPoller := TPeerPoller.Create(FSettings.Peers, FSettings.Port);
  if TopologyWindowVisible then ShowTopologyWindow(FNode, FPoller, @SessionsFunc);
end;

procedure TForm1.FreeNode;
begin
  DetachTopologyWindow;
  if FPoller <> nil then FPoller.StopAndWait;
  FreeAndNil(FPoller);
  FreeAndNil(FNode);
end;

function TForm1.SessionsFunc: TJSONArray;
begin
  if FMcp <> nil then Result := FMcp.SessionsJSON else Result := TJSONArray.Create;
end;

{ Update the Server 1 specific status every 0.5 s }
procedure TForm1.NodeTimer(Sender: TObject);
var
  St: TMcpStats;
  Sess: TJSONArray;
  NCtl, I, NActive: Integer;
  Summary, Links: TJSONArray;
  NS: TNodeState;
  Clients, UpText: string;
  Ago: Int64;
begin
  if FNode = nil then Exit;
  UplinkTick;
  Sess := SessionsFunc;
  try
    NActive := 0;
    Clients := '';
    for I := 0 to Sess.Count - 1 do
      if Sess.Objects[I].Get('lastSeenAgo', Int64(0)) < 600 then
      begin
        Inc(NActive);
        if Clients <> '' then Clients := Clients + ', ';
        Clients := Clients + Sess.Objects[I].Get('client', '');
      end;
  finally
    Sess.Free;
  end;

  if FMcp = nil then
    FNode.SetBaseState(nsStopped)
  else
  begin
    FMcp.GetStats(St, nil);
    case St.State of
      msStarting: FNode.SetBaseState(nsStarting);
      msRunning:  FNode.SetBaseState(nsWaiting, Format('%d clients', [NActive]));
      msError:    FNode.SetBaseState(nsError, St.LastError);
    else
      FNode.SetBaseState(nsStopped);
    end;
  end;

  NCtl := 0;
  for I := 0 to ComponentCount - 1 do
    if Components[I] is TControl then Inc(NCtl);
  // uplink = the server-1 -> server-2 line in the Topology
  Links := TJSONArray.Create;
  if FUplink.Connected then
  begin
    if FUplink.LastTrafficAt > 0 then Ago := Round((Now - FUplink.LastTrafficAt) * 86400) else Ago := 999;
    Links.Add(TJSONObject.Create(['url', FUplink.Url, 'server', FUplinkId, 'state', 'connected',
      'lastTrafficAgo', Ago, 'lastTool', FUplink.LastTool, 'kind', 'uplink']));
    UpText := 'uplink ' + FUplinkId + ' ✓';
  end
  else if FSettings.UplinkEnabled then
    UpText := 'uplink ' + FSettings.Uplink + ' (waiting)'
  else
    UpText := 'uplink off';
  FNode.SetLinks(Links);

  Summary := TJSONArray.Create([Format('controls %d · clients %d', [NCtl, NActive]), UpText]);
  FNode.SetDetail(TJSONObject.Create(['summary', Summary,
    'formCaption', Caption, 'controls', NCtl, 'activeClients', NActive,
    'clients', Clients, 'uplink', UplinkJSON]));

  NS := FNode.State;
  FNodePanel.Color := BGRAToColor(StateColor(NS));
  FNodePanel.Caption := Format('  %s  ·  %s  ·  %s  ·  clients: %s  ·  %s',
    [FNode.Id, FNode.Name, FNode.StateDisplay, IfThen(Clients = '', '-', Clients), UpText]);
  miMcpUplink.Caption := 'Uplink to ' + FSettings.Uplink;
  miMcpUplink.Checked := FSettings.UplinkEnabled;
  FNodePanel.Hint := ClientUrl(FSettings) + LineEnding + 'Double-click to show the Topology';
end;

procedure TForm1.miMcpTopologyClick(Sender: TObject);
begin
  ShowTopologyWindow(FNode, FPoller, @SessionsFunc);
end;

{ ---------- uplink: server-1 acts as a client of server-2 ---------- }

{ Every 5 s: if the uplink is enabled and the target is online (ask the poller first so we never block) -> connect }
procedure TForm1.UplinkTick(AForce: Boolean);
var
  Url, Id: string;
  Online: Boolean;
begin
  if (FUplink = nil) or not FSettings.UplinkEnabled or (FSettings.Uplink = '') then Exit;
  if FUplink.Connected then Exit;
  if not AForce and (GetTickCount64 - FUplinkTry < 5000) then Exit;
  FUplinkTry := GetTickCount64;
  if not FindPeer(FPoller, FSettings.Uplink, Url, Id, Online) then
  begin
    if Pos('://', FSettings.Uplink) = 0 then Exit; // unknown id
    // URL outside the peers: online state unknown -> only try when forced by the user
    Url := FSettings.Uplink;
    Id := FSettings.Uplink;
    Online := AForce;
  end;
  if not Online then Exit;
  if Pos(Format(':%d/', [FSettings.Port]), Url) > 0 then Exit; // never connect to ourselves
  FUplink.Url := Url;
  try
    FUplink.Connect(FSettings.NodeId, '1.2.0');
    FUplinkId := Id;
    McpLog('uplink connected: ' + Id + ' ' + Url);
  except
    on E: Exception do McpLog('uplink ' + Id + ' failed: ' + E.Message);
  end;
end;

procedure TForm1.UplinkDisconnect;
begin
  if (FUplink <> nil) and FUplink.Connected then
  begin
    try
      FUplink.Disconnect;
    except
    end;
    McpLog('uplink disconnected');
  end;
end;

function TForm1.UplinkJSON: TJSONObject;
begin
  Result := TJSONObject.Create(['enabled', FSettings.UplinkEnabled, 'target', FSettings.Uplink,
    'connected', FUplink.Connected, 'node', FUplinkId, 'url', FUplink.Url,
    'session', FUplink.SessionId, 'requests', FUplink.Requests, 'errors', FUplink.Errors,
    'lastTool', FUplink.LastTool]);
end;

procedure TForm1.miMcpUplinkClick(Sender: TObject);
var
  Ini: TIniFile;
begin
  FSettings.UplinkEnabled := not FSettings.UplinkEnabled;
  Ini := TIniFile.Create(SettingsFileName);
  try
    Ini.WriteBool('Uplink', 'Enabled', FSettings.UplinkEnabled);
    Ini.WriteString('Uplink', 'Target', FSettings.Uplink);
  finally
    Ini.Free;
  end;
  if FSettings.UplinkEnabled then UplinkTick(True) else UplinkDisconnect;
  NodeTimer(nil);
end;

procedure TForm1.StartServer;
begin
  if ServerActive then Exit;
  FreeAndNil(FMcp); // old thread that has stopped / failed
  FMcp := TMcpServerThread.Create(FSettings);
  FMcp.OnLog := @McpLog;
  FMcp.OnToolsList := @McpToolsList;
  FMcp.OnToolCall := @McpToolCall;
  FMcp.OnNodeInfo := @FNode.ToJSON;
  McpLog(Format('starting MCP server %s:%d%s', [FSettings.Address, FSettings.Port, FSettings.Endpoint]));
  FMcp.Start;
  UpdateMcpMenu;
end;

procedure TForm1.StopServer;
begin
  if FMcp = nil then Exit;
  FMcp.StopAndWait;
  FreeAndNil(FMcp);
  UpdateMcpMenu;
end;

function TForm1.ServerActive: Boolean;
begin
  Result := (FMcp <> nil) and not FMcp.Finished;
end;

procedure TForm1.UpdateMcpMenu;
begin
  if ServerActive then
    miMcp.Caption := '&MCP (on)'
  else
    miMcp.Caption := '&MCP (off)';
end;

procedure TForm1.McpLog(const AMsg: string);
var
  F: TextFile;
  Line: string;
begin
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AMsg;
  FLogLines.Add(Line);
  while FLogLines.Count > FSettings.MaxLogLines do FLogLines.Delete(0);
  Inc(FLogVersion);
  if (FMcp <> nil) and FMcp.Finished then UpdateMcpMenu; // server stopped by itself / error

  if not FSettings.LogToFile then Exit;
  try
    AssignFile(F, FLogFile);
    if FileExists(FLogFile) then Append(F) else Rewrite(F);
    WriteLn(F, FormatDateTime('yyyy-mm-dd ', Now), Line);
    CloseFile(F);
  except
    // logging must never crash the program
  end;
end;

procedure TForm1.ClearLog;
begin
  FLogLines.Clear;
  Inc(FLogVersion);
end;

function TForm1.BuildStatusJSON: TJSONObject;
var
  St: TMcpStats;
  Counts: TStringList;
  Srv, Tools, Frm: TJSONObject;
  I, NCtl: Integer;
  Uptime: string;
begin
  Counts := TStringList.Create;
  try
    if FMcp <> nil then
      FMcp.GetStats(St, Counts)
    else
    begin
      FillChar(St, SizeOf(St), 0);
      St.State := msStopped;
    end;

    Result := TJSONObject.Create;
    Result.Add('app', TJSONObject.Create([
      'exe', ParamStr(0),
      'pid', Int64(GetProcessID),
      'time', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
      'fpc', {$I %FPCVERSION%},
      'lcl', lcl_version,
      'target', {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%},
      'iniFile', SettingsFileName,
      'logFile', FLogFile]));

    if St.StartedAt > 0 then
      Uptime := FormatDateTime('hh:nn:ss', Now - St.StartedAt)
    else
      Uptime := '';
    Srv := TJSONObject.Create([
      'state', McpStateNames[St.State],
      'url', ClientUrl(FSettings),
      'bind', Format('%s:%d', [FSettings.Address, FSettings.Port]),
      'startedAt', IfThen(St.StartedAt > 0, FormatDateTime('yyyy-mm-dd hh:nn:ss', St.StartedAt), ''),
      'uptime', Uptime,
      'httpRequests', St.HttpRequests,
      'rpcMessages', St.RpcMessages,
      'toolCalls', St.ToolCalls,
      'errors', St.Errors,
      'bytesIn', St.BytesIn,
      'bytesOut', St.BytesOut,
      'lastRequestAt', IfThen(St.LastRequestAt > 0, FormatDateTime('hh:nn:ss', St.LastRequestAt), ''),
      'lastRemote', St.LastRemote,
      'lastMethod', St.LastMethod,
      'lastTool', St.LastTool,
      'lastError', St.LastError]);
    Tools := TJSONObject.Create;
    for I := 0 to Counts.Count - 1 do
      Tools.Add(Counts.Names[I], StrToIntDef(Counts.ValueFromIndex[I], 0));
    Srv.Add('toolCounts', Tools);
    Result.Add('server', Srv);

    Result.Add('client', TJSONObject.Create([
      'name', St.ClientName,
      'version', St.ClientVersion,
      'protocolVersion', St.ProtocolVersion,
      'claudeCommand', ClaudeAddCommand(FSettings)]));

    Result.Add('settings', SettingsToJSON(FSettings));
    if FNode <> nil then Result.Add('node', FNode.ToJSONObject);
    if FUplink <> nil then Result.Add('uplink', UplinkJSON);
    Result.Add('sessions', SessionsFunc);

    NCtl := 0;
    for I := 0 to ComponentCount - 1 do
      if Components[I] is TControl then Inc(NCtl);
    Frm := TJSONObject.Create([
      'name', Name, 'caption', Caption,
      'clientWidth', ClientWidth, 'clientHeight', ClientHeight,
      'controls', NCtl]);
    Result.Add('form', Frm);

    Result.Add('log', TJSONObject.Create(['lines', FLogLines.Count, 'version', FLogVersion]));
  finally
    Counts.Free;
  end;
end;

procedure TForm1.miFileExitClick(Sender: TObject);
begin
  Close;
end;

procedure TForm1.miMcpConfigClick(Sender: TObject);
var
  S: TMcpSettings;
begin
  S := FSettings;
  if not EditMcpSettings(S) then Exit;
  SaveSettings(S);
  UplinkDisconnect;
  StopServer;
  FreeNode;
  FSettings := S;
  CreateNode;
  McpLog('settings saved: ' + SettingsFileName);
  if FSettings.Enabled then StartServer;
  NodeTimer(nil);
end;

procedure TForm1.miMcpStatusClick(Sender: TObject);
begin
  ShowMcpStatus;
end;

function TForm1.FindTarget(const AName: string): TComponent;
begin
  if (AName = '') or SameText(AName, Name) or SameText(AName, 'form') then
    Exit(Self);
  Result := FindComponent(AName);
  if Result = nil then
    raise Exception.CreateFmt('Control "%s" not found', [AName]);
end;

function TForm1.ControlInfo(C: TControl): TJSONObject;
begin
  Result := TJSONObject.Create([
    'name', C.Name, 'type', C.ClassName,
    'left', C.Left, 'top', C.Top, 'width', C.Width, 'height', C.Height,
    'parent', C.Parent.Name, 'visible', C.Visible]);
  if IsPublishedProp(C, 'Caption') then
    Result.Add('caption', GetStrProp(C, 'Caption'))
  else if IsPublishedProp(C, 'Text') then
    Result.Add('text', GetStrProp(C, 'Text'));
end;

procedure TForm1.DynClick(Sender: TObject);
var
  I: Integer;
begin
  I := FClickMsgs.IndexOfName(TComponent(Sender).Name);
  if I >= 0 then ShowMessage(FClickMsgs.ValueFromIndex[I]);
end;

procedure TForm1.McpToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
var
  Ok: Boolean;
begin
  FNode.CommandStarted(FMcp.CallClient, AName);
  Ok := False;
  try
    DoToolCall(AName, AArgs, AResult);
    Ok := not AResult.Get('isError', False);
  finally
    if Ok then
      FNode.CommandDone(True)
    else if AResult.Find('content', jtArray) <> nil then
      FNode.CommandDone(False, AName + ': ' + AResult.Arrays['content'].Objects[0].Get('text', ''))
    else
      FNode.CommandDone(False, AName + ' failed');
    NodeTimer(nil);
  end;
end;

procedure TForm1.DoToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
var
  Topo, Res: TJSONObject;
  Args: TJSONData;
  Arr: TJSONArray;
  I: Integer;
  S: string;
begin
  case AName of
    'uplink_status':
      begin
        Topo := UplinkJSON;
        try
          McpAddText(AResult, Topo.FormatJSON);
        finally
          Topo.Free;
        end;
      end;
    'uplink_list_tools', 'uplink_call':
      begin
        if not FUplink.Connected then UplinkTick(True);
        if not FUplink.Connected then
        begin
          McpSetError(AResult, Format('uplink to %s is not connected (enabled=%s)',
            [FSettings.Uplink, BoolToStr(FSettings.UplinkEnabled, True)]));
          Exit;
        end;
        if AName = 'uplink_list_tools' then
        begin
          Res := FUplink.Call('tools/list');
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
        end
        else
        begin
          Args := AArgs.Find('arguments');
          if (Args = nil) or (Args.JSONType <> jtObject) then Args := TJSONObject.Create
          else Args := Args.Clone;
          FUplink.LastTool := ArgStr(AArgs, 'name');
          McpLog(Format('uplink_call %s.%s (from %s)', [FUplinkId, FUplink.LastTool, FMcp.CallClient]));
          Res := FUplink.Call('tools/call', TJSONObject.Create(['name', FUplink.LastTool, 'arguments', Args]));
          try
            if Res.Find('content', jtArray) <> nil then
              AResult.Add('content', Res.Arrays['content'].Clone);
            if Res.Get('isError', False) then AResult.Booleans['isError'] := True;
          finally
            Res.Free;
          end;
        end;
      end;
    'get_topology':
      begin
        Topo := TopologySnapshot(FNode, FPoller);
        try
          Topo.Objects['self'].Add('sessions', SessionsFunc);
          McpAddText(AResult, Topo.FormatJSON);
        finally
          Topo.Free;
        end;
      end;
    'get_form':       ToolGetForm(AResult);
    'set_form':       ToolSetForm(AArgs, AResult);
    'add_control':    ToolAddControl(AArgs, AResult);
    'set_property':   ToolSetProperty(AArgs, AResult);
    'get_property':   ToolGetProperty(AArgs, AResult);
    'delete_control': ToolDeleteControl(AArgs, AResult);
    'clear_form':     ToolClearForm(AResult);
    'screenshot':     ToolScreenshot(AResult);
    'get_status':     ToolGetStatus(AArgs, AResult);
  else
    McpSetError(AResult, 'Unknown tool: ' + AName);
  end;
end;

procedure TForm1.ToolGetForm(AResult: TJSONObject);
var
  Info: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Info := TJSONObject.Create([
    'name', Name, 'caption', Caption,
    'clientWidth', ClientWidth, 'clientHeight', ClientHeight,
    'color', ColorToString(Color)]);
  Arr := TJSONArray.Create;
  for I := 0 to ComponentCount - 1 do
    if Components[I] is TControl then
      Arr.Add(ControlInfo(TControl(Components[I])));
  Info.Add('controls', Arr);
  try
    McpAddText(AResult, Info.FormatJSON);
  finally
    Info.Free;
  end;
end;

procedure TForm1.ToolSetForm(AArgs, AResult: TJSONObject);
begin
  if HasArg(AArgs, 'caption') then Caption := ArgStr(AArgs, 'caption');
  if HasArg(AArgs, 'width') then ClientWidth := ArgInt(AArgs, 'width', ClientWidth);
  if HasArg(AArgs, 'height') then ClientHeight := ArgInt(AArgs, 'height', ClientHeight);
  if HasArg(AArgs, 'color') then Color := ParseColor(ArgStr(AArgs, 'color'));
  McpAddText(AResult, Format('Form: "%s" %dx%d %s',
    [Caption, ClientWidth, ClientHeight, ColorToString(Color)]));
end;

procedure TForm1.ToolAddControl(AArgs, AResult: TJSONObject);
var
  Cls: TControlClass;
  C: TControl;
  NewName, ParentName, Txt, Msg: string;
  ParentCtl: TComponent;
  Info: TJSONObject;
  N: Integer;
begin
  Cls := ControlClassFor(ArgStr(AArgs, 'type'));
  if Cls = nil then
  begin
    McpSetError(AResult, 'Unsupported type: ' + ArgStr(AArgs, 'type'));
    Exit;
  end;

  NewName := ArgStr(AArgs, 'name');
  if NewName = '' then
  begin
    N := 1;
    repeat
      NewName := Copy(Cls.ClassName, 2, MaxInt) + IntToStr(N);
      Inc(N);
    until FindComponent(NewName) = nil;
  end
  else if FindComponent(NewName) <> nil then
  begin
    McpSetError(AResult, Format('Name "%s" already exists', [NewName]));
    Exit;
  end;

  ParentName := ArgStr(AArgs, 'parent');
  ParentCtl := FindTarget(ParentName);
  if not (ParentCtl is TWinControl) then
  begin
    McpSetError(AResult, Format('"%s" cannot contain controls', [ParentName]));
    Exit;
  end;

  C := Cls.Create(Self);
  try
    C.Name := NewName;
    C.Parent := TWinControl(ParentCtl);
  except
    C.Free;
    raise;
  end;
  C.SetBounds(ArgInt(AArgs, 'left', 8), ArgInt(AArgs, 'top', 8),
    ArgInt(AArgs, 'width', C.Width), ArgInt(AArgs, 'height', C.Height));

  if HasArg(AArgs, 'text') then
  begin
    Txt := StringReplace(ArgStr(AArgs, 'text'), '\n', LineEnding, [rfReplaceAll]);
    if C is TMemo then TMemo(C).Lines.Text := Txt
    else if C is TListBox then TListBox(C).Items.Text := Txt
    else if C is TComboBox then
    begin
      TComboBox(C).Items.Text := Txt;
      if TComboBox(C).Items.Count > 0 then TComboBox(C).ItemIndex := 0;
    end
    else if IsPublishedProp(C, 'Caption') then SetStrProp(C, 'Caption', Txt)
    else if IsPublishedProp(C, 'Text') then SetStrProp(C, 'Text', Txt);
  end
  else if C is TEdit then
    TEdit(C).Text := ''
  else if C is TMemo then
    TMemo(C).Clear;

  Msg := ArgStr(AArgs, 'onclick_message');
  if Msg <> '' then
  begin
    FClickMsgs.Values[NewName] := Msg;
    C.OnClick := @DynClick;
  end;

  Info := ControlInfo(C);
  try
    McpAddText(AResult, 'Added ' + Info.AsJSON);
  finally
    Info.Free;
  end;
end;

procedure TForm1.ToolSetProperty(AArgs, AResult: TJSONObject);
var
  T: TComponent;
  P, V: string;
begin
  T := FindTarget(ArgStr(AArgs, 'target'));
  P := ArgStr(AArgs, 'property');
  V := StringReplace(ArgStr(AArgs, 'value'), '\n', LineEnding, [rfReplaceAll]);
  SetPropFromString(T, P, V);
  McpAddText(AResult, Format('%s.%s = %s', [T.Name, P, GetPropAsString(T, P)]));
end;

procedure TForm1.ToolGetProperty(AArgs, AResult: TJSONObject);
var
  T: TComponent;
  P: string;
begin
  T := FindTarget(ArgStr(AArgs, 'target'));
  P := ArgStr(AArgs, 'property');
  McpAddText(AResult, GetPropAsString(T, P));
end;

procedure TForm1.ToolDeleteControl(AArgs, AResult: TJSONObject);
var
  T: TComponent;
  I: Integer;
begin
  T := FindTarget(ArgStr(AArgs, 'name'));
  if not (T is TControl) or (T = Self) then
  begin
    McpSetError(AResult, 'Only controls on the form can be deleted');
    Exit;
  end;
  I := FClickMsgs.IndexOfName(T.Name);
  if I >= 0 then FClickMsgs.Delete(I);
  McpAddText(AResult, 'Deleted ' + T.Name);
  T.Free;
end;

procedure TForm1.ToolClearForm(AResult: TJSONObject);
var
  I, N: Integer;
begin
  N := 0;
  for I := ComponentCount - 1 downto 0 do
    if (I < ComponentCount) and (Components[I] is TControl) then
    begin
      Components[I].Free; // children of a Panel may already have been freed with it
      Inc(N);
    end;
  FClickMsgs.Clear;
  McpAddText(AResult, Format('Form cleared (%d controls removed)', [N]));
end;

procedure TForm1.ToolGetStatus(AArgs, AResult: TJSONObject);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  I, N: Integer;
begin
  Root := BuildStatusJSON;
  try
    N := ArgInt(AArgs, 'log_lines', 20);
    Arr := TJSONArray.Create;
    for I := Max(0, FLogLines.Count - N) to FLogLines.Count - 1 do
      Arr.Add(FLogLines[I]);
    Root.Objects['log'].Add('recent', Arr);
    McpAddText(AResult, Root.FormatJSON);
  finally
    Root.Free;
  end;
end;

procedure TForm1.ToolScreenshot(AResult: TJSONObject);
var
  Bmp: TBitmap;
  Png: TPortableNetworkGraphic;
  Ms: TStringStream;
  DC: HDC;
begin
  if WindowState = wsMinimized then WindowState := wsNormal;
  BringToFront;
  Repaint;
  Application.ProcessMessages;

  Bmp := TBitmap.Create;
  Png := TPortableNetworkGraphic.Create;
  Ms := TStringStream.Create('');
  try
    DC := GetDC(Handle);
    try
      Bmp.LoadFromDevice(DC);
    finally
      ReleaseDC(Handle, DC);
    end;
    Png.Assign(Bmp);
    Png.SaveToStream(Ms);
    McpAddImage(AResult, EncodeStringBase64(Ms.DataString), 'image/png');
    McpAddText(AResult, Format('Screenshot %dx%d', [Bmp.Width, Bmp.Height]));
  finally
    Ms.Free;
    Png.Free;
    Bmp.Free;
  end;
end;

end.
