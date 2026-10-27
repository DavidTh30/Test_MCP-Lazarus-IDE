unit IoMain;

{ MCP Server 2 : IO Device
  Simulated device: 8 digital outputs (lamps) + 4 analog outputs (0..100 %)
  External clients command it over MCP; it also shows the shared Topology with the other nodes }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, Menus,
  Clipbrd, Math, StrUtils, fpjson, BGRABitmap, BGRABitmapTypes,
  McpConfig, McpServer, McpTools, NodeState, TopoView;

type

  { TFormIO }

  TFormIO = class(TForm)
    MainMenu1: TMainMenu;
    memLog: TMemo;
    miCopyStatus: TMenuItem;
    miFile: TMenuItem;
    miFileExit: TMenuItem;
    miMcp: TMenuItem;
    miReset: TMenuItem;
    miSep1: TMenuItem;
    miStartStop: TMenuItem;
    pbIO: TPaintBox;
    pnlHeader: TPanel;
    pnlLeft: TPanel;
    pnlTopo: TPanel;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    tmrNode: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure miCopyStatusClick(Sender: TObject);
    procedure miFileExitClick(Sender: TObject);
    procedure miResetClick(Sender: TObject);
    procedure miStartStopClick(Sender: TObject);
    procedure pbIOMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbIOPaint(Sender: TObject);
    procedure tmrNodeTimer(Sender: TObject);
  private
    FSettings: TMcpSettings;
    FMcp: TMcpServerThread;
    FNode: TLocalNode;
    FPoller: TPeerPoller;
    FTopo: TTopologyView;
    FDO: array[0..7] of Boolean;
    FAO: array[0..3] of Double;
    FFlash: array[0..7] of QWord; // time of the last state change (flash effect)
    FWrites: Int64;
    procedure Log(const AMsg: string);
    procedure StartServer;
    procedure StopServer;
    function SessionsFunc: TJSONArray;
    function OutputsText: string;
    function IOJSON: TJSONObject;
    function LampRect(I: Integer): TRect;
    procedure SetOutput(I: Integer; AOn: Boolean);
    procedure UpdateNode;
    procedure McpToolsList(ATools: TJSONArray);
    procedure McpToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
    procedure DoToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
  public
  end;

var
  FormIO: TFormIO;

implementation

{$R *.lfm}

{ TFormIO }

procedure TFormIO.FormCreate(Sender: TObject);
begin
  FSettings := DefaultSettings;
  FSettings.Port := 8766;
  FSettings.ServerName := 'io-device';
  FSettings.ClientName := 'io-device';
  FSettings.NodeId := 'server-2';
  FSettings.NodeName := 'IO Device';
  FSettings.LogToFile := False;
  FSettings.Instructions := 'Simulated IO device: 8 digital outputs (lamps DO0..DO7) and ' +
    '4 analog outputs (AO0..AO3, 0..100 %). Use get_io to read, set_output / toggle_output / ' +
    'set_outputs / set_analog to change, get_topology to see the other nodes.';
  LoadSettings(FSettings);

  FNode := TLocalNode.Create(FSettings.NodeId, FSettings.NodeName,
    'MCP server: simulated IO device', nrServer, '127.0.0.1', FSettings.Port);
  FNode.SetEndpoint('127.0.0.1', FSettings.Port, ClientUrl(FSettings));
  FPoller := TPeerPoller.Create(FSettings.Peers, FSettings.Port);

  FTopo := TTopologyView.Create(Self);
  FTopo.Parent := pnlTopo;
  FTopo.Align := alClient;
  FTopo.LocalNode := FNode;
  FTopo.Poller := FPoller;
  FTopo.SessionsFunc := @SessionsFunc;

  Caption := Format('MCP Server 2 — %s (%s)', [FSettings.NodeName, FSettings.NodeId]);
  StartServer;
  UpdateNode;
end;

procedure TFormIO.FormDestroy(Sender: TObject);
begin
  tmrNode.Enabled := False;
  FTopo.LocalNode := nil;
  FTopo.Poller := nil;
  FTopo.SessionsFunc := nil;
  StopServer;
  FPoller.StopAndWait;
  FPoller.Free;
  FNode.Free;
end;

procedure TFormIO.Log(const AMsg: string);
begin
  memLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AMsg);
  while memLog.Lines.Count > FSettings.MaxLogLines do memLog.Lines.Delete(0);
  memLog.SelStart := Length(memLog.Text);
end;

procedure TFormIO.StartServer;
begin
  if (FMcp <> nil) and not FMcp.Finished then Exit;
  FreeAndNil(FMcp);
  FMcp := TMcpServerThread.Create(FSettings);
  FMcp.OnLog := @Log;
  FMcp.OnToolsList := @McpToolsList;
  FMcp.OnToolCall := @McpToolCall;
  FMcp.OnNodeInfo := @FNode.ToJSON;
  Log(Format('starting MCP server %s', [ClientUrl(FSettings)]));
  FMcp.Start;
  miStartStop.Caption := 'Stop server';
end;

procedure TFormIO.StopServer;
begin
  if FMcp = nil then Exit;
  FMcp.StopAndWait;
  FreeAndNil(FMcp);
  miStartStop.Caption := 'Start server';
end;

function TFormIO.SessionsFunc: TJSONArray;
begin
  if FMcp <> nil then Result := FMcp.SessionsJSON else Result := TJSONArray.Create;
end;

function TFormIO.OutputsText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to 7 do
    if FDO[I] then Result := Result + '1' else Result := Result + '0';
end;

function TFormIO.IOJSON: TJSONObject;
var
  D, A: TJSONArray;
  I: Integer;
begin
  D := TJSONArray.Create;
  for I := 0 to 7 do D.Add(FDO[I]);
  A := TJSONArray.Create;
  for I := 0 to 3 do A.Add(FAO[I]);
  Result := TJSONObject.Create(['DO', D, 'AO', A, 'DOmask', OutputsText, 'writes', FWrites]);
end;

procedure TFormIO.SetOutput(I: Integer; AOn: Boolean);
begin
  if FDO[I] <> AOn then FFlash[I] := GetTickCount64;
  FDO[I] := AOn;
  Inc(FWrites);
end;

procedure TFormIO.UpdateNode;
var
  St: TMcpStats;
  Sess: TJSONArray;
  I, NActive, NOn: Integer;
  Clients: string;
  Detail: TJSONObject;
begin
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

  NOn := 0;
  for I := 0 to 7 do if FDO[I] then Inc(NOn);
  Detail := IOJSON;
  Detail.Add('summary', TJSONArray.Create([
    Format('DO %s (%d on)', [OutputsText, NOn]),
    Format('AO %.0f / %.0f / %.0f / %.0f', [FAO[0], FAO[1], FAO[2], FAO[3]])]));
  Detail.Add('activeClients', NActive);
  Detail.Add('clients', Clients);
  FNode.SetDetail(Detail);

  pnlHeader.Color := BGRAToColor(StateColor(FNode.State));
  pnlHeader.Caption := Format('  %s  ·  %s  ·  %s  ·  %s  ·  clients: %s',
    [FNode.Id, FNode.Name, FNode.StateDisplay, ClientUrl(FSettings), IfThen(Clients = '', '-', Clients)]);
end;

procedure TFormIO.tmrNodeTimer(Sender: TObject);
begin
  UpdateNode;
  pbIO.Invalidate;
end;

{ ---------- draw the IO with BGRABitmap ---------- }

function TFormIO.LampRect(I: Integer): TRect;
var
  Col, Row, W: Integer;
begin
  W := Max(60, (pbIO.Width - 20) div 4);
  Col := I mod 4;
  Row := I div 4;
  Result := Rect(10 + Col * W, 36 + Row * 92, 10 + Col * W + W - 8, 36 + Row * 92 + 84);
end;

procedure TFormIO.pbIOPaint(Sender: TObject);
var
  B: TBGRABitmap;
  I: Integer;
  R: TRect;
  CX, CY, Rad, Glow, BarW, Y0: Single;
  C: TBGRAPixel;
  Age: QWord;
begin
  B := TBGRABitmap.Create(pbIO.Width, pbIO.Height, BGRA(30, 34, 44));
  try
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := 14;
    B.FontStyle := [fsBold];
    B.TextOut(10, 8, 'DIGITAL OUTPUTS', BGRA(170, 185, 210));

    for I := 0 to 7 do
    begin
      R := LampRect(I);
      B.FillRoundRectAntialias(R.Left, R.Top, R.Right, R.Bottom, 10, 10, BGRA(44, 50, 64));
      CX := (R.Left + R.Right) / 2;
      CY := R.Top + 34;
      Rad := 22;
      if FDO[I] then
      begin
        C := BGRA(255, 190, 40);
        Age := GetTickCount64 - FFlash[I];
        if Age < 600 then Glow := 18 * (1 - Age / 600) + 8 else Glow := 8;
        B.FillEllipseAntialias(CX, CY, Rad + Glow, Rad + Glow, BGRA(255, 190, 40, 60));
        B.FillEllipseAntialias(CX, CY, Rad, Rad, C);
        B.FillEllipseAntialias(CX - 7, CY - 7, 6, 6, BGRA(255, 255, 230, 200));
      end
      else
      begin
        B.FillEllipseAntialias(CX, CY, Rad, Rad, BGRA(70, 74, 86));
        B.EllipseAntialias(CX, CY, Rad, Rad, BGRA(100, 105, 120), 2);
      end;
      B.FontHeight := 13;
      B.FontStyle := [fsBold];
      if FDO[I] then C := BGRA(235, 235, 245) else C := BGRA(140, 140, 150);
      B.TextOut(CX, R.Bottom - 22, Format('DO%d  %s', [I, IfThen(FDO[I], 'ON', 'off')]), C, taCenter);
    end;

    Y0 := 36 + 2 * 92 + 14;
    B.FontHeight := 14;
    B.TextOut(10, Y0, 'ANALOG OUTPUTS (%)', BGRA(170, 185, 210));
    BarW := pbIO.Width - 90;
    for I := 0 to 3 do
    begin
      CY := Y0 + 28 + I * 30;
      B.FontHeight := 13;
      B.TextOut(10, CY - 2, Format('AO%d', [I]), BGRA(200, 205, 220));
      B.FillRoundRectAntialias(50, CY, 50 + BarW, CY + 16, 6, 6, BGRA(55, 60, 75));
      if FAO[I] > 0 then
        B.FillRoundRectAntialias(50, CY, 50 + BarW * FAO[I] / 100, CY + 16, 6, 6,
          BGRA(40 + Round(FAO[I] * 1.8), 170, 230 - Round(FAO[I] * 1.2)));
      B.TextOut(56 + BarW, CY - 1, Format('%.0f', [FAO[I]]), BGRAWhite, taLeftJustify);
    end;

    B.FontHeight := 11;
    B.FontStyle := [];
    B.TextOut(10, pbIO.Height - 18, 'Click a lamp to toggle ON/OFF (local command)', BGRA(130, 135, 150));
    B.Draw(pbIO.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

procedure TFormIO.pbIOMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  for I := 0 to 7 do
    if LampRect(I).Contains(Point(X, Y)) then
    begin
      FNode.CommandStarted('local (mouse)', Format('toggle DO%d', [I]));
      SetOutput(I, not FDO[I]);
      FNode.CommandDone(True);
      Log(Format('local: DO%d -> %s', [I, BoolToStr(FDO[I], 'ON', 'OFF')]));
      UpdateNode;
      pbIO.Invalidate;
      Exit;
    end;
end;

{ ---------- MCP tools ---------- }

procedure TFormIO.McpToolsList(ATools: TJSONArray);
begin
  ATools.Add(Tool('get_io', 'Read all digital outputs (DO0..DO7) and analog outputs (AO0..AO3).', nil, []));
  ATools.Add(Tool('set_output', 'Switch one digital output (lamp) on or off.',
    TJSONObject.Create([
      'index', Prop('integer', 'Output index 0..7'),
      'on', Prop('boolean', 'true = ON, false = OFF')]), ['index', 'on']));
  ATools.Add(Tool('toggle_output', 'Toggle one digital output.',
    TJSONObject.Create(['index', Prop('integer', 'Output index 0..7')]), ['index']));
  ATools.Add(Tool('set_outputs', 'Set all 8 digital outputs at once from a mask such as "10100001" (DO0 first).',
    TJSONObject.Create(['mask', Prop('string', '8 characters of 0/1')]), ['mask']));
  ATools.Add(Tool('set_analog', 'Set one analog output in percent.',
    TJSONObject.Create([
      'index', Prop('integer', 'Analog index 0..3'),
      'value', Prop('number', '0..100')]), ['index', 'value']));
  ATools.Add(Tool('reset_io', 'Turn every output off and set analog outputs to 0.', nil, []));
  ATools.Add(Tool('get_status', 'Node identity, state, MCP sessions (connected clients) and IO summary.', nil, []));
  ATools.Add(Tool('get_topology',
    'State of this node and of every peer node (servers / clients) seen on the network.', nil, []));
end;

procedure TFormIO.McpToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
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
    UpdateNode;
    pbIO.Invalidate;
  end;
end;

procedure TFormIO.DoToolCall(const AName: string; AArgs: TJSONObject; AResult: TJSONObject);
var
  I: Integer;
  V: Double;
  Mask: string;
  O: TJSONObject;
begin
  case AName of
    'get_io':
      begin
        O := IOJSON;
        try
          McpAddText(AResult, O.FormatJSON);
        finally
          O.Free;
        end;
      end;
    'set_output', 'toggle_output':
      begin
        I := ArgInt(AArgs, 'index', -1);
        if (I < 0) or (I > 7) then
        begin
          McpSetError(AResult, 'index must be 0..7');
          Exit;
        end;
        if AName = 'toggle_output' then SetOutput(I, not FDO[I])
        else SetOutput(I, ArgBool(AArgs, 'on', True));
        McpAddText(AResult, Format('DO%d = %s  (mask %s)', [I, BoolToStr(FDO[I], 'ON', 'OFF'), OutputsText]));
      end;
    'set_outputs':
      begin
        Mask := Trim(ArgStr(AArgs, 'mask'));
        if (Length(Mask) <> 8) or (Mask.Trim(['0', '1']) <> '') then
        begin
          McpSetError(AResult, 'mask must be 8 characters of 0/1, e.g. "10100001"');
          Exit;
        end;
        for I := 0 to 7 do SetOutput(I, Mask[I + 1] = '1');
        McpAddText(AResult, 'DO mask = ' + OutputsText);
      end;
    'set_analog':
      begin
        I := ArgInt(AArgs, 'index', -1);
        V := ArgFloat(AArgs, 'value', -1);
        if (I < 0) or (I > 3) or (V < 0) or (V > 100) then
        begin
          McpSetError(AResult, 'index must be 0..3 and value 0..100');
          Exit;
        end;
        FAO[I] := V;
        Inc(FWrites);
        McpAddText(AResult, Format('AO%d = %.1f %%', [I, V]));
      end;
    'reset_io':
      begin
        for I := 0 to 7 do SetOutput(I, False);
        for I := 0 to 3 do FAO[I] := 0;
        McpAddText(AResult, 'all outputs reset');
      end;
    'get_status':
      begin
        O := FNode.ToJSONObject;
        try
          O.Add('sessions', SessionsFunc);
          O.Add('mcpUrl', ClientUrl(FSettings));
          McpAddText(AResult, O.FormatJSON);
        finally
          O.Free;
        end;
      end;
    'get_topology':
      begin
        O := TopologySnapshot(FNode, FPoller);
        try
          O.Objects['self'].Add('sessions', SessionsFunc);
          McpAddText(AResult, O.FormatJSON);
        finally
          O.Free;
        end;
      end;
  else
    McpSetError(AResult, 'Unknown tool: ' + AName);
  end;
  Log(Format('%s from %s -> DO %s', [AName, FMcp.CallClient, OutputsText]));
end;

{ ---------- menu ---------- }

procedure TFormIO.miStartStopClick(Sender: TObject);
begin
  if (FMcp <> nil) and not FMcp.Finished then StopServer else StartServer;
  UpdateNode;
end;

procedure TFormIO.miResetClick(Sender: TObject);
var
  I: Integer;
begin
  FNode.CommandStarted('local (menu)', 'reset_io');
  for I := 0 to 7 do SetOutput(I, False);
  for I := 0 to 3 do FAO[I] := 0;
  FNode.CommandDone(True);
  UpdateNode;
  pbIO.Invalidate;
end;

procedure TFormIO.miCopyStatusClick(Sender: TObject);
var
  O: TJSONObject;
begin
  O := TopologySnapshot(FNode, FPoller);
  try
    O.Objects['self'].Add('sessions', SessionsFunc);
    Clipboard.AsText := O.FormatJSON;
  finally
    O.Free;
  end;
end;

procedure TFormIO.miFileExitClick(Sender: TObject);
begin
  Close;
end;

end.
