unit TopoView;

{ Shared Topology view of every node, drawn with BGRABitmap
  - reads its own state from TLocalNode and the other nodes from TPeerPoller every 0.5 s
  - top row = servers, middle row = clients, bottom row = external clients (e.g. Claude Code)
  - links: green = connected, orange + moving dots = commands in progress, grey = no traffic for a while }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, ExtCtrls, Forms, Math, DateUtils, IniFiles,
  LCLType, fpjson, jsonparser, BGRABitmap, BGRABitmapTypes, NodeState;

type
  TSessionsFunc = function: TJSONArray of object;

  { TTopoNode }

  TTopoNode = class
  public
    Id, Name, Kind, StateText, HostPort: string;
    Role: TNodeRole;
    State: TNodeState;
    IsSelf, Online: Boolean;
    Lines: TStringList;
    HintText: string;
    CX, CY: Single;
    constructor Create;
    destructor Destroy; override;
  end;

  TTopoEdge = record
    FromId, ToId: string;
    Active, Stale: Boolean;
    LabelText: string;
  end;

  { TTopologyView }

  TTopologyView = class(TCustomControl)
  private
    FLocal: TLocalNode;
    FPoller: TPeerPoller;
    FSessionsFunc: TSessionsFunc;
    FNodes: TList;
    FEdges: array of TTopoEdge;
    FKnown: TStringList;    // spec -> last json seen (name / role used while offline)
    FDataTimer, FAnimTimer: TTimer;
    FUpdatedAt: TDateTime;
    FCardW, FCardH: Single;
    FRowCount: Integer;
    FRowTop, FRowY: array[0..2] of Single;
    FHover: TTopoNode;
    // mouse: drag a node to move it, drag the background to pan, double-click to reset
    FManual: TStringList;   // id=fx;fy  manual node position as a fraction of the view size
    FLayoutLoaded: Boolean;
    FDragId: string;        // node being dragged ('' = none)
    FDragDX, FDragDY: Single;
    FPanning: Boolean;
    FPanX, FPanY: Single;
    FPanFromX, FPanFromY, FMouseFromX, FMouseFromY: Integer;
    procedure LoadLayout;
    procedure SaveLayout;
    procedure ShiftNodes(DX, DY: Single);
    procedure DataTimer(Sender: TObject);
    procedure AnimTimer(Sender: TObject);
    procedure ClearModel;
    function FindNode(const AId: string): TTopoNode;
    function NodeAt(X, Y: Integer): TTopoNode;
    function AddNodeFromJSON(O: TJSONObject; const AHostPort: string; AIsSelf: Boolean): TTopoNode;
    procedure AddEdge(const AFrom, ATo: string; AActive, AStale: Boolean; const ALabel: string);
    procedure LayoutNodes;
    procedure DrawNode(B: TBGRABitmap; N: TTopoNode; APhase: Single);
    procedure DrawEdge(B: TBGRABitmap; const E: TTopoEdge; APhase: Single);
    function NeedsAnimation: Boolean;
  protected
    procedure Paint; override;
    procedure EraseBackground(DC: HDC); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RefreshNow;
    { Forget every manual node position and the pan offset }
    procedure ResetLayout;
    { Summary as JSON (used by the get_topology tool) }
    function SummaryJSON: TJSONObject;
    property LocalNode: TLocalNode read FLocal write FLocal;
    property Poller: TPeerPoller read FPoller write FPoller;
    property SessionsFunc: TSessionsFunc read FSessionsFunc write FSessionsFunc;
  end;

{ Separate Topology window (for programs that do not embed it in the main form) }
procedure ShowTopologyWindow(ALocal: TLocalNode; APoller: TPeerPoller;
  ASessions: TSessionsFunc = nil);
{ Drop the node / poller references before they are freed (on exit / settings change) }
procedure DetachTopologyWindow;
function TopologyWindowVisible: Boolean;

function StateColor(S: TNodeState): TBGRAPixel;

implementation

var
  TopoWindow: TForm = nil;

function StateColor(S: TNodeState): TBGRAPixel;
begin
  case S of
    nsOffline:   Result := BGRA(160, 160, 160);
    nsStarting:  Result := BGRA(120, 120, 200);
    nsWaiting:   Result := BGRA(40, 120, 215);
    nsConnected: Result := BGRA(35, 160, 80);
    nsBusy:      Result := BGRA(245, 130, 20);
    nsError:     Result := BGRA(215, 50, 50);
    nsStopped:   Result := BGRA(90, 90, 90);
  else
    Result := BGRA(128, 128, 128);
  end;
end;

function RoleColor(R: TNodeRole): TBGRAPixel;
begin
  case R of
    nrServer:   Result := BGRA(55, 85, 160);
    nrClient:   Result := BGRA(30, 135, 115);
    nrExternal: Result := BGRA(135, 85, 170);
  else
    Result := BGRA(120, 120, 120);
  end;
end;

function NormHost(const H: string): string;
begin
  if (H = '') or (H = '0.0.0.0') or SameText(H, 'localhost') or (H = '::1') then
    Result := '127.0.0.1'
  else
    Result := H;
end;

{ http://host:port/path -> host:port }
function UrlHostPort(const AUrl: string): string;
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
  if P > 0 then
    Result := NormHost(Copy(S, 1, P - 1)) + ':' + Copy(S, P + 1, 10)
  else
    Result := NormHost(S) + ':80';
end;

function RoleGuess(const AId: string): TNodeRole;
begin
  if Pos('server', LowerCase(AId)) = 1 then Result := nrServer
  else if Pos('client', LowerCase(AId)) = 1 then Result := nrClient
  else Result := nrUnknown;
end;

{ TTopoNode }

constructor TTopoNode.Create;
begin
  Lines := TStringList.Create;
end;

destructor TTopoNode.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

{ TTopologyView }

constructor TTopologyView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FNodes := TList.Create;
  FKnown := TStringList.Create;
  FManual := TStringList.Create;
  ControlStyle := ControlStyle + [csOpaque];
  ShowHint := True;
  FCardW := 190;
  FCardH := 96;
  FDataTimer := TTimer.Create(Self);
  FDataTimer.Interval := 500;
  FDataTimer.OnTimer := @DataTimer;
  FAnimTimer := TTimer.Create(Self);
  FAnimTimer.Interval := 60;
  FAnimTimer.OnTimer := @AnimTimer;
end;

destructor TTopologyView.Destroy;
begin
  FDataTimer.Enabled := False;
  FAnimTimer.Enabled := False;
  ClearModel;
  FNodes.Free;
  FKnown.Free;
  FManual.Free;
  inherited Destroy;
end;

{ ---------- manual layout (mouse) ---------- }

function LayoutIniName: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

procedure TTopologyView.LoadLayout;
var
  Ini: TIniFile;
  Keys: TStringList;
  I: Integer;
begin
  FLayoutLoaded := True;
  FManual.Clear;
  if not FileExists(LayoutIniName) then Exit;
  Ini := TIniFile.Create(LayoutIniName);
  Keys := TStringList.Create;
  try
    Ini.ReadSection('TopologyLayout', Keys);
    for I := 0 to Keys.Count - 1 do
      if Keys[I] = '_pan' then
      begin
        FPanX := StrToFloatDef(Copy(Ini.ReadString('TopologyLayout', '_pan', '0;0'), 1,
          Pos(';', Ini.ReadString('TopologyLayout', '_pan', '0;0')) - 1), 0, DefaultFormatSettings);
        FPanY := StrToFloatDef(Copy(Ini.ReadString('TopologyLayout', '_pan', '0;0'),
          Pos(';', Ini.ReadString('TopologyLayout', '_pan', '0;0')) + 1, 30), 0, DefaultFormatSettings);
      end
      else
        FManual.Values[Keys[I]] := Ini.ReadString('TopologyLayout', Keys[I], '');
  finally
    Keys.Free;
    Ini.Free;
  end;
end;

procedure TTopologyView.SaveLayout;
var
  Ini: TIniFile;
  I: Integer;
begin
  try
    Ini := TIniFile.Create(LayoutIniName);
    try
      Ini.EraseSection('TopologyLayout');
      for I := 0 to FManual.Count - 1 do
        Ini.WriteString('TopologyLayout', FManual.Names[I], FManual.ValueFromIndex[I]);
      if (FPanX <> 0) or (FPanY <> 0) then
        Ini.WriteString('TopologyLayout', '_pan',
          FloatToStr(Round(FPanX), DefaultFormatSettings) + ';' + FloatToStr(Round(FPanY), DefaultFormatSettings));
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    // the layout is only a convenience
  end;
end;

procedure TTopologyView.ResetLayout;
begin
  FManual.Clear;
  FPanX := 0;
  FPanY := 0;
  SaveLayout;
  LayoutNodes;
  Invalidate;
end;

procedure TTopologyView.ShiftNodes(DX, DY: Single);
var
  I: Integer;
begin
  for I := 0 to FNodes.Count - 1 do
  begin
    TTopoNode(FNodes[I]).CX := TTopoNode(FNodes[I]).CX + DX;
    TTopoNode(FNodes[I]).CY := TTopoNode(FNodes[I]).CY + DY;
  end;
end;

procedure TTopologyView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  N: TTopoNode;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  Application.CancelHint;
  N := NodeAt(Round(X - FPanX), Round(Y - FPanY));
  if N <> nil then
  begin
    // drag a node
    FDragId := N.Id;
    FDragDX := N.CX - (X - FPanX);
    FDragDY := N.CY - (Y - FPanY);
    Cursor := crSizeAll;
  end
  else
  begin
    // drag the background = pan the whole view
    FPanning := True;
    FPanFromX := Round(FPanX);
    FPanFromY := Round(FPanY);
    FMouseFromX := X;
    FMouseFromY := Y;
    Cursor := crSize;
  end;
  MouseCapture := True;
end;

procedure TTopologyView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (FDragId <> '') or FPanning then
  begin
    FDragId := '';
    FPanning := False;
    MouseCapture := False;
    Cursor := crDefault;
    SaveLayout;
    Invalidate;
  end;
end;

procedure TTopologyView.DblClick;
var
  P: TPoint;
  N: TTopoNode;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  N := NodeAt(Round(P.X - FPanX), Round(P.Y - FPanY));
  if N <> nil then
  begin
    // double-click a node: return it to the automatic position
    FManual.Values[N.Id] := '';
    SaveLayout;
    LayoutNodes;
    Invalidate;
  end
  else
    ResetLayout; // double-click the background: reset everything
end;

procedure TTopologyView.ClearModel;
var
  I: Integer;
begin
  FHover := nil;
  for I := 0 to FNodes.Count - 1 do TTopoNode(FNodes[I]).Free;
  FNodes.Clear;
  SetLength(FEdges, 0);
end;

function TTopologyView.FindNode(const AId: string): TTopoNode;
var
  I: Integer;
begin
  for I := 0 to FNodes.Count - 1 do
    if TTopoNode(FNodes[I]).Id = AId then Exit(TTopoNode(FNodes[I]));
  Result := nil;
end;

function TTopologyView.NodeAt(X, Y: Integer): TTopoNode;
var
  I: Integer;
  N: TTopoNode;
begin
  for I := 0 to FNodes.Count - 1 do
  begin
    N := TTopoNode(FNodes[I]);
    if (Abs(X - N.CX) <= FCardW / 2) and (Abs(Y - N.CY) <= FCardH / 2) then Exit(N);
  end;
  Result := nil;
end;

function TTopologyView.AddNodeFromJSON(O: TJSONObject; const AHostPort: string;
  AIsSelf: Boolean): TTopoNode;
var
  D: TJSONObject;
  Summary: TJSONArray;
  I: Integer;
begin
  Result := TTopoNode.Create;
  Result.Id := O.Get('id', '?');
  Result.Name := O.Get('name', '');
  Result.Kind := O.Get('kind', '');
  Result.Role := RoleFromCode(O.Get('role', ''));
  Result.State := StateFromCode(O.Get('state', ''));
  Result.StateText := O.Get('stateText', NodeStateText[Result.State]);
  Result.HostPort := AHostPort;
  Result.Online := True;
  Result.IsSelf := AIsSelf;
  D := O.Find('detail', jtObject) as TJSONObject;
  if D <> nil then
  begin
    Summary := D.Find('summary', jtArray) as TJSONArray;
    if Summary <> nil then
      for I := 0 to Summary.Count - 1 do Result.Lines.Add(Summary.Items[I].AsString);
  end;
  Result.HintText := Format('%s  (%s)'#10'%s'#10'%s'#10'state: %s'#10'last command: %s from %s'#10'commands: %d',
    [Result.Id, Result.Name, Result.Kind, AHostPort, Result.StateText,
     O.Get('lastCommand', '-'), O.Get('lastCommandFrom', '-'), O.Get('commands', Int64(0))]);
  if Result.Lines.Count > 0 then
    Result.HintText := Result.HintText + #10 + Result.Lines.Text;
  FNodes.Add(Result);
end;

procedure TTopologyView.AddEdge(const AFrom, ATo: string; AActive, AStale: Boolean;
  const ALabel: string);
var
  I: Integer;
begin
  if (AFrom = '') or (ATo = '') or (AFrom = ATo) then Exit;
  for I := 0 to High(FEdges) do
    if (FEdges[I].FromId = AFrom) and (FEdges[I].ToId = ATo) then
    begin
      FEdges[I].Active := FEdges[I].Active or AActive;
      FEdges[I].Stale := FEdges[I].Stale and AStale;
      if (ALabel <> '') and AActive then FEdges[I].LabelText := ALabel;
      Exit;
    end;
  I := Length(FEdges);
  SetLength(FEdges, I + 1);
  FEdges[I].FromId := AFrom;
  FEdges[I].ToId := ATo;
  FEdges[I].Active := AActive;
  FEdges[I].Stale := AStale;
  if AActive then FEdges[I].LabelText := ALabel else FEdges[I].LabelText := '';
end;

procedure TTopologyView.RefreshNow;
var
  Specs, Jsons: TStringList;
  Objs: TList;           // TJSONObject of every online node (including ourselves)
  HostPorts: TStringList; // host:port -> node id
  SelfObj, O, L: TJSONObject;
  Data: TJSONData;
  Links, Sess: TJSONArray;
  I, J, K: Integer;
  Id, Host, HP, Target, ClientName: string;
  Port: Word;
  N: TTopoNode;
  Ago: Int64;
begin
  if FLocal = nil then Exit;
  ClearModel;
  Specs := TStringList.Create;
  Jsons := TStringList.Create;
  Objs := TList.Create;
  HostPorts := TStringList.Create;
  try
    // ---- ourselves ----
    SelfObj := FLocal.ToJSONObject;
    if Assigned(FSessionsFunc) then SelfObj.Add('sessions', FSessionsFunc());
    Objs.Add(SelfObj);
    HP := '127.0.0.1:' + IntToStr(FLocal.Port);
    AddNodeFromJSON(SelfObj, HP, True);
    HostPorts.Values[HP] := FLocal.Id;

    // ---- peers ----
    if FPoller <> nil then FPoller.GetResults(Specs, Jsons);
    for I := 0 to Specs.Count - 1 do
    begin
      ParsePeerSpec(Specs[I], Id, Host, Port);
      HP := NormHost(Host) + ':' + IntToStr(Port);
      O := nil;
      if Jsons[I] <> '' then
        try
          Data := GetJSON(Jsons[I]);
          if Data is TJSONObject then O := TJSONObject(Data) else Data.Free;
        except
          O := nil;
        end;
      if (O <> nil) and (FindNode(O.Get('id', '')) = nil) then
      begin
        Objs.Add(O);
        AddNodeFromJSON(O, HP, False);
        HostPorts.Values[HP] := O.Get('id', '');
        FKnown.Values[Specs[I]] := O.Get('name', '') + '|' + O.Get('role', '');
      end
      else
      begin
        O.Free;
        if FindNode(Id) <> nil then Continue;
        // offline: use the name seen last time
        N := TTopoNode.Create;
        N.Id := Id;
        N.HostPort := HP;
        N.State := nsOffline;
        N.StateText := 'Offline';
        N.Online := False;
        N.Role := RoleGuess(Id);
        K := FKnown.IndexOfName(Specs[I]);
        if K >= 0 then
        begin
          N.Name := Copy(FKnown.ValueFromIndex[K], 1, Pos('|', FKnown.ValueFromIndex[K]) - 1);
          N.Role := RoleFromCode(Copy(FKnown.ValueFromIndex[K], Pos('|', FKnown.ValueFromIndex[K]) + 1, 50));
        end;
        N.Lines.Add(HP);
        N.HintText := Id + #10 + HP + #10 + 'Not responding (program not running?)';
        FNodes.Add(N);
        HostPorts.Values[HP] := Id;
      end;
    end;

    // ---- links ----
    for I := 0 to Objs.Count - 1 do
    begin
      O := TJSONObject(Objs[I]);
      Id := O.Get('id', '');
      // client -> server (as seen by the client)
      Links := O.Find('links', jtArray) as TJSONArray;
      if Links <> nil then
        for J := 0 to Links.Count - 1 do
          if Links.Items[J] is TJSONObject then
          begin
            L := Links.Objects[J];
            Target := HostPorts.Values[UrlHostPort(L.Get('url', ''))];
            if Target = '' then
            begin
              // server that is not in the peers -> draw it as an external node
              Target := 'ext:' + UrlHostPort(L.Get('url', ''));
              if FindNode(Target) = nil then
              begin
                N := TTopoNode.Create;
                N.Id := Target;
                N.Name := 'MCP server';
                N.Role := nrServer;
                N.State := nsConnected;
                N.StateText := 'external';
                N.Online := True;
                N.HostPort := UrlHostPort(L.Get('url', ''));
                N.HintText := L.Get('url', '');
                FNodes.Add(N);
              end;
            end;
            Ago := L.Get('lastTrafficAgo', Int64(999));
            AddEdge(Id, Target, (Ago >= 0) and (Ago < 3), False, L.Get('lastTool', ''));
          end;
      // sessions (as seen by the server) -> clients that command it
      Sess := O.Find('sessions', jtArray) as TJSONArray;
      if Sess <> nil then
        for J := 0 to Sess.Count - 1 do
          if Sess.Items[J] is TJSONObject then
          begin
            L := Sess.Objects[J];
            Ago := L.Get('lastSeenAgo', Int64(0));
            if Ago > 600 then Continue; // silent for more than 10 minutes -> not drawn
            ClientName := L.Get('client', '?');
            if FindNode(ClientName) = nil then
            begin
              Target := 'ext:' + ClientName;
              if FindNode(Target) = nil then
              begin
                N := TTopoNode.Create;
                N.Id := Target;
                N.Name := ClientName + ' ' + L.Get('version', '');
                N.Role := nrExternal;
                if Ago < 3 then N.State := nsBusy else N.State := nsConnected;
                N.StateText := Format('external client (%ds ago)', [Ago]);
                N.Online := True;
                N.HostPort := L.Get('remote', '');
                N.Lines.Add('from ' + L.Get('remote', ''));
                N.Lines.Add(Format('tool calls %d', [L.Get('toolCalls', Int64(0))]));
                N.HintText := Format('%s %s'#10'remote: %s'#10'requests: %d, tool calls: %d'#10'last tool: %s',
                  [ClientName, L.Get('version', ''), L.Get('remote', ''),
                   L.Get('requests', Int64(0)), L.Get('toolCalls', Int64(0)), L.Get('lastTool', '')]);
                FNodes.Add(N);
              end;
            end
            else
              Target := ClientName;
            AddEdge(Target, Id, Ago < 3, Ago > 120, L.Get('lastTool', ''));
          end;
    end;
  finally
    for I := 0 to Objs.Count - 1 do TJSONObject(Objs[I]).Free;
    Objs.Free;
    HostPorts.Free;
    Jsons.Free;
    Specs.Free;
  end;
  FUpdatedAt := Now;
  LayoutNodes;
  FAnimTimer.Enabled := NeedsAnimation;
  Invalidate;
end;

function CompareNodes(A, B: Pointer): Integer;
begin
  Result := CompareText(TTopoNode(A).Id, TTopoNode(B).Id);
end;

procedure TTopologyView.LayoutNodes;
var
  Rows: array[0..2] of TList; // 0 = server, 1 = client, 2 = external client
  I, R, Cols: Integer;
  N: TTopoNode;
  Avail, Gap: Single;
  S: string;

  procedure PlaceRow(AList: TList; AY: Single);
  var
    K: Integer;
    Step: Single;
  begin
    if AList.Count = 0 then Exit;
    Step := Width / AList.Count;
    for K := 0 to AList.Count - 1 do
    begin
      TTopoNode(AList[K]).CX := Step * K + Step / 2;
      TTopoNode(AList[K]).CY := AY;
    end;
  end;

begin
  FNodes.Sort(@CompareNodes);
  for R := 0 to 2 do Rows[R] := TList.Create;
  try
    for I := 0 to FNodes.Count - 1 do
    begin
      N := TTopoNode(FNodes[I]);
      case N.Role of
        nrServer: Rows[0].Add(N);
        nrExternal: Rows[2].Add(N);
      else
        Rows[1].Add(N);
      end;
    end;
    // the 3rd row only exists when there are external clients
    if Rows[2].Count > 0 then FRowCount := 3 else FRowCount := 2;
    Cols := 1;
    for R := 0 to 2 do Cols := Max(Cols, Rows[R].Count);
    Gap := 18;
    FCardW := EnsureRange((Width - Gap * (Cols + 1)) / Cols, 120, 210);
    Avail := Height - 28 - 26;
    FCardH := EnsureRange(Avail / FRowCount - 34, 64, 100);
    for R := 0 to FRowCount - 1 do
    begin
      FRowTop[R] := 28 + Avail * R / FRowCount;
      FRowY[R] := FRowTop[R] + Avail / FRowCount / 2 + 6;
      PlaceRow(Rows[R], FRowY[R]);
    end;
  finally
    for R := 0 to 2 do Rows[R].Free;
  end;

  // nodes moved by the user keep their position
  if not FLayoutLoaded then LoadLayout;
  for I := 0 to FNodes.Count - 1 do
  begin
    N := TTopoNode(FNodes[I]);
    S := FManual.Values[N.Id];
    if S = '' then Continue;
    N.CX := StrToFloatDef(Copy(S, 1, Pos(';', S) - 1), N.CX / Max(1, Width), DefaultFormatSettings) * Width;
    N.CY := StrToFloatDef(Copy(S, Pos(';', S) + 1, 30), N.CY / Max(1, Height), DefaultFormatSettings) * Height;
  end;
end;

function TTopologyView.NeedsAnimation: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FEdges) do
    if FEdges[I].Active then Exit(True);
  for I := 0 to FNodes.Count - 1 do
    if TTopoNode(FNodes[I]).State = nsBusy then Exit(True);
  Result := False;
end;

procedure TTopologyView.DataTimer(Sender: TObject);
begin
  if Visible and (Parent <> nil) then RefreshNow;
end;

procedure TTopologyView.AnimTimer(Sender: TObject);
begin
  if Visible then Invalidate;
end;

procedure TTopologyView.EraseBackground(DC: HDC);
begin
  // everything is painted in Paint -> no background erase (avoids flicker)
end;

procedure TTopologyView.Resize;
begin
  inherited Resize;
  LayoutNodes;
  Invalidate;
end;

procedure TTopologyView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  N: TTopoNode;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragId <> '' then
  begin
    // move the node; its position is kept as a fraction of the view size
    N := FindNode(FDragId);
    if (N <> nil) and (Width > 0) and (Height > 0) then
    begin
      N.CX := X - FPanX + FDragDX;
      N.CY := Y - FPanY + FDragDY;
      FManual.Values[FDragId] := FloatToStr(N.CX / Width, DefaultFormatSettings) + ';' +
        FloatToStr(N.CY / Height, DefaultFormatSettings);
      Invalidate;
    end;
    Exit;
  end;
  if FPanning then
  begin
    FPanX := FPanFromX + (X - FMouseFromX);
    FPanY := FPanFromY + (Y - FMouseFromY);
    Invalidate;
    Exit;
  end;
  N := NodeAt(Round(X - FPanX), Round(Y - FPanY));
  if N <> nil then Cursor := crSizeAll else Cursor := crDefault;
  if N <> FHover then
  begin
    FHover := N;
    Application.CancelHint;
    if N <> nil then Hint := N.HintText else Hint := '';
    Invalidate;
  end;
end;

type
  TPathPts = array of TPointF;

function PathLength(const P: TPathPts): Single;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to High(P) do
    Result := Result + Sqrt(Sqr(P[I].X - P[I - 1].X) + Sqr(P[I].Y - P[I - 1].Y));
end;

{ Point on the path at distance D from the start }
function PathPoint(const P: TPathPts; D: Single): TPointF;
var
  I: Integer;
  L: Single;
begin
  for I := 1 to High(P) do
  begin
    L := Sqrt(Sqr(P[I].X - P[I - 1].X) + Sqr(P[I].Y - P[I - 1].Y));
    if (D <= L) and (L > 0) then
      Exit(PointF(P[I - 1].X + (P[I].X - P[I - 1].X) * D / L,
                  P[I - 1].Y + (P[I].Y - P[I - 1].Y) * D / L));
    D := D - L;
  end;
  Result := P[High(P)];
end;

procedure TTopologyView.DrawEdge(B: TBGRABitmap; const E: TTopoEdge; APhase: Single);
var
  A, Z, N: TTopoNode;
  X1, Y1, X2, Y2, DX, DY, Len, UX, UY, T, PX, PY, Off, MX, MY, S: Single;
  C: TBGRAPixel;
  K, J, Try_: Integer;
  TW: Integer;
  Pts: TPathPts;
  Pt, Q: TPointF;
  Hit: Boolean;
const
  Offsets: array[0..4] of Single = (0, 0.75, -0.75, 1.3, -1.3);
begin
  A := FindNode(E.FromId);
  Z := FindNode(E.ToId);
  if (A = nil) or (Z = nil) then Exit;
  X1 := A.CX;
  X2 := Z.CX;
  // leave from the card edges that face each other
  if A.CY > Z.CY then
  begin
    Y1 := A.CY - FCardH / 2;
    Y2 := Z.CY + FCardH / 2;
  end
  else if A.CY < Z.CY then
  begin
    Y1 := A.CY + FCardH / 2;
    Y2 := Z.CY - FCardH / 2;
  end
  else
  begin
    Y1 := A.CY;
    Y2 := Z.CY;
    if A.CX < Z.CX then begin X1 := A.CX + FCardW / 2; X2 := Z.CX - FCardW / 2; end
    else begin X1 := A.CX - FCardW / 2; X2 := Z.CX + FCardW / 2; end;
  end;
  DX := X2 - X1;
  DY := Y2 - Y1;
  Len := Sqrt(DX * DX + DY * DY);
  if Len < 1 then Exit;
  UX := DX / Len;
  UY := DY / Len;

  // straight line; if it crosses another card -> curve (quadratic bezier) around it
  MX := (X1 + X2) / 2;
  MY := (Y1 + Y2) / 2;
  for Try_ := 0 to High(Offsets) do
  begin
    Off := Offsets[Try_] * FCardW;
    SetLength(Pts, 25);
    for K := 0 to 24 do
    begin
      S := K / 24;
      // control point shifted perpendicular to the line
      Pts[K] := PointF(
        Sqr(1 - S) * X1 + 2 * (1 - S) * S * (MX - UY * Off) + Sqr(S) * X2,
        Sqr(1 - S) * Y1 + 2 * (1 - S) * S * (MY + UX * Off) + Sqr(S) * Y2);
    end;
    Hit := False;
    for J := 0 to FNodes.Count - 1 do
    begin
      N := TTopoNode(FNodes[J]);
      if (N = A) or (N = Z) then Continue;
      for K := 1 to 23 do
        if (Abs(Pts[K].X - N.CX) < FCardW / 2 + 6) and (Abs(Pts[K].Y - N.CY) < FCardH / 2 + 6) then
        begin
          Hit := True;
          Break;
        end;
      if Hit then Break;
    end;
    if not Hit then Break;
  end;
  Len := PathLength(Pts);

  if E.Active then C := BGRA(245, 130, 20)
  else if E.Stale then C := BGRA(185, 185, 185)
  else C := BGRA(35, 160, 80);

  if E.Stale then
  begin
    T := 0;
    while T < Len - 10 do
    begin
      Pt := PathPoint(Pts, T);
      Q := PathPoint(Pts, Min(T + 6, Len - 10));
      B.DrawLineAntialias(Pt.X, Pt.Y, Q.X, Q.Y, C, 2);
      T := T + 12;
    end;
  end
  else
    B.DrawPolyLineAntialias(Pts, C, IfThen(E.Active, 3.5, 2.5));

  // arrow head at the target, following the direction of the last segment
  Pt := PathPoint(Pts, Max(0, Len - 12));
  DX := X2 - Pt.X;
  DY := Y2 - Pt.Y;
  S := Max(0.001, Sqrt(DX * DX + DY * DY));
  UX := DX / S;
  UY := DY / S;
  B.FillPolyAntialias([PointF(X2, Y2),
    PointF(X2 - UX * 12 - UY * 6, Y2 - UY * 12 + UX * 6),
    PointF(X2 - UX * 12 + UY * 6, Y2 - UY * 12 - UX * 6)], C);

  if E.Active then
  begin
    // dots moving in the direction of the command
    for K := 0 to Trunc(Len / 28) do
    begin
      T := Frac(APhase + K * 28 / Len) * Len;
      Pt := PathPoint(Pts, T);
      B.FillEllipseAntialias(Pt.X, Pt.Y, 3.5, 3.5, BGRA(255, 255, 255));
      B.FillEllipseAntialias(Pt.X, Pt.Y, 2.5, 2.5, C);
    end;
    if E.LabelText <> '' then
    begin
      B.FontHeight := 12;
      B.FontStyle := [];
      TW := B.TextSize(E.LabelText).cx;
      // put the label closer to the source so labels of crossing lines do not overlap
      Pt := PathPoint(Pts, Len * 0.3);
      PX := Pt.X + 8;
      PY := Pt.Y - 9;
      B.FillRoundRectAntialias(PX - 4, PY - 1, PX + TW + 4, PY + 16, 5, 5, BGRA(255, 244, 230));
      B.RoundRectAntialias(PX - 4, PY - 1, PX + TW + 4, PY + 16, 5, 5, C, 1);
      B.TextOut(Round(PX), Round(PY), E.LabelText, BGRA(150, 70, 0));
    end;
  end;
end;

procedure DrawIcon(B: TBGRAPixel; Bmp: TBGRABitmap; ARole: TNodeRole; X, Y: Single; const AId: string);
var
  K: Integer;
begin
  case ARole of
    nrServer:
      for K := 0 to 2 do
      begin
        Bmp.FillRoundRectAntialias(X, Y + K * 11, X + 26, Y + K * 11 + 9, 2, 2, B);
        Bmp.FillEllipseAntialias(X + 21, Y + K * 11 + 4.5, 1.8, 1.8, BGRA(120, 255, 140));
      end;
    nrClient:
      begin
        Bmp.FillRoundRectAntialias(X, Y, X + 26, Y + 19, 2, 2, B);
        Bmp.FillRectAntialias(X + 3, Y + 3, X + 23, Y + 16, BGRA(220, 240, 255));
        Bmp.FillRectAntialias(X + 11, Y + 19, X + 15, Y + 25, B);
        Bmp.FillRectAntialias(X + 6, Y + 25, X + 20, Y + 28, B);
      end;
  else
    begin
      Bmp.FillEllipseAntialias(X + 13, Y + 14, 13, 13, B);
      Bmp.FontHeight := 13;
      Bmp.FontStyle := [fsBold];
      Bmp.TextOut(X + 13, Y + 6, UpperCase(Copy(StringReplace(AId, 'ext:', '', []), 1, 2)),
        RoleColor(nrExternal), taCenter);
    end;
  end;
end;

procedure TTopologyView.DrawNode(B: TBGRABitmap; N: TTopoNode; APhase: Single);
var
  X1, Y1, X2, Y2, PX, PY, Glow: Single;
  SC, Border, Fill: TBGRAPixel;
  S: string;
  TW, K: Integer;
begin
  X1 := N.CX - FCardW / 2;
  Y1 := N.CY - FCardH / 2;
  X2 := N.CX + FCardW / 2;
  Y2 := N.CY + FCardH / 2;
  SC := StateColor(N.State);

  // shadow + glowing border while Busy
  B.FillRoundRectAntialias(X1 + 3, Y1 + 4, X2 + 3, Y2 + 4, 10, 10, BGRA(0, 0, 0, 35));
  if N.State = nsBusy then
  begin
    Glow := 3 + 3 * Abs(Sin(APhase * 2 * Pi));
    B.RoundRectAntialias(X1 - Glow, Y1 - Glow, X2 + Glow, Y2 + Glow, 12, 12, BGRA(245, 130, 20, 110), 3);
  end;

  if N.Online then Fill := BGRA(255, 255, 255) else Fill := BGRA(236, 236, 236);
  B.FillRoundRectAntialias(X1, Y1, X2, Y2, 10, 10, Fill);
  // role colour strip on the left
  B.FillRoundRectAntialias(X1, Y1, X1 + 40, Y2, 10, 10, RoleColor(N.Role), [rrTopRightSquare, rrBottomRightSquare]);
  if not N.Online then
    B.FillRoundRectAntialias(X1, Y1, X1 + 40, Y2, 10, 10, BGRA(255, 255, 255, 140), [rrTopRightSquare, rrBottomRightSquare]);
  DrawIcon(BGRA(255, 255, 255), B, N.Role, X1 + 7, Y1 + 12, N.Id);

  // border: ourselves = thick blue
  if N.IsSelf then Border := BGRA(20, 90, 220) else Border := SC;
  if N = FHover then Border := BGRA(0, 0, 0);
  B.RoundRectAntialias(X1, Y1, X2, Y2, 10, 10, Border, IfThen(N.IsSelf, 3.5, 1.8));

  PX := X1 + 48;
  PY := Y1 + 6;
  B.FontName := 'Segoe UI';
  B.FontQuality := fqFineAntialiasing;
  B.FontHeight := 15;
  B.FontStyle := [fsBold];
  S := StringReplace(N.Id, 'ext:', '', []);
  B.TextOut(PX, PY, S, BGRA(30, 30, 40));
  if N.IsSelf then
  begin
    TW := B.TextSize(S).cx;
    B.FontHeight := 10;
    B.FillRoundRectAntialias(PX + TW + 6, PY + 2, PX + TW + 40, PY + 15, 4, 4, BGRA(20, 90, 220));
    B.TextOut(PX + TW + 23, PY + 2, 'THIS', BGRAWhite, taCenter);
  end;

  B.FontHeight := 12;
  B.FontStyle := [];
  B.TextOut(PX, PY + 19, N.Name, BGRA(100, 100, 110));

  // state pill
  B.FontHeight := 12;
  B.FontStyle := [fsBold];
  S := N.StateText;
  while (Length(S) > 3) and (B.TextSize(S).cx > X2 - PX - 18) do
    S := Copy(S, 1, Length(S) - 2);
  if S <> N.StateText then S := S + '…';
  TW := B.TextSize(S).cx;
  B.FillRoundRectAntialias(PX, PY + 37, PX + TW + 14, PY + 54, 8, 8, SC);
  B.TextOut(PX + 7, PY + 38, S, BGRAWhite);

  // node specific details
  B.FontHeight := 11;
  B.FontStyle := [];
  for K := 0 to Min(N.Lines.Count, 2) - 1 do
    if PY + 58 + K * 13 + 12 < Y2 then
    begin
      S := N.Lines[K];
      while (Length(S) > 3) and (B.TextSize(S).cx > X2 - PX - 6) do
        S := Copy(S, 1, Length(S) - 2);
      B.TextOut(PX, PY + 58 + K * 13, S, BGRA(80, 80, 90));
    end;
end;

procedure TTopologyView.Paint;
var
  B: TBGRABitmap;
  I, NOnline, LX: Integer;
  Phase: Single;
  S: string;
  St: TNodeState;
begin
  B := TBGRABitmap.Create(Max(1, Width), Max(1, Height), BGRA(246, 248, 252));
  try
    Phase := Frac(GetTickCount64 / 1400);
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;

    // row backgrounds
    if FRowCount < 2 then LayoutNodes;
    B.FillRectAntialias(0, FRowTop[0], Width, FRowTop[1], BGRA(236, 241, 250));
    if FRowCount = 3 then
      B.FillRectAntialias(0, FRowTop[2], Width, Height - 26, BGRA(243, 238, 248));
    B.FontHeight := 11;
    B.FontStyle := [fsBold];
    B.TextOut(8, FRowTop[0] + 4, 'SERVERS', BGRA(120, 135, 170));
    B.TextOut(8, FRowTop[1] + 4, 'CLIENTS', BGRA(110, 150, 140));
    if FRowCount = 3 then
      B.TextOut(8, FRowTop[2] + 4, 'EXTERNAL CLIENTS', BGRA(140, 110, 165));

    NOnline := 0;
    for I := 0 to FNodes.Count - 1 do
      if TTopoNode(FNodes[I]).Online then Inc(NOnline);

    // title bar
    B.FillRectAntialias(0, 0, Width, 28, BGRA(35, 45, 70));
    B.FontHeight := 14;
    B.FontStyle := [fsBold];
    if FLocal <> nil then S := 'Topology — viewed from ' + FLocal.Id else S := 'Topology';
    B.TextOut(10, 5, S, BGRAWhite);
    LX := B.TextSize(S).cx; // title width
    B.FontHeight := 12;
    B.FontStyle := [];
    S := Format('drag: move node / pan  ·  double-click: reset  ·  nodes %d (online %d)  links %d  ·  %s',
      [FNodes.Count, NOnline, Length(FEdges), FormatDateTime('hh:nn:ss', FUpdatedAt)]);
    // drop the mouse hint when the bar is too narrow for both texts
    if LX + B.TextSize(S).cx + 30 > Width then
      S := Format('nodes %d (online %d)  links %d  ·  %s',
        [FNodes.Count, NOnline, Length(FEdges), FormatDateTime('hh:nn:ss', FUpdatedAt)]);
    B.TextOut(Width - 10, 7, S, BGRA(200, 210, 230), taRightJustify);

    // links and nodes are drawn shifted by the pan offset
    ShiftNodes(FPanX, FPanY);
    try
      for I := 0 to High(FEdges) do DrawEdge(B, FEdges[I], Phase);
      for I := 0 to FNodes.Count - 1 do DrawNode(B, TTopoNode(FNodes[I]), Phase);
    finally
      ShiftNodes(-FPanX, -FPanY);
    end;

    // legend
    B.FontHeight := 11;
    B.FontStyle := [];
    LX := 10;
    for St := nsOffline to nsStopped do
    begin
      if St = nsStarting then Continue;
      B.FillEllipseAntialias(LX + 5, Height - 12, 5, 5, StateColor(St));
      B.TextOut(LX + 14, Height - 19, NodeStateText[St], BGRA(90, 90, 100));
      LX := LX + 22 + B.TextSize(NodeStateText[St]).cx;
    end;
    B.DrawLineAntialias(LX + 4, Height - 12, LX + 28, Height - 12, BGRA(245, 130, 20), 3);
    B.TextOut(LX + 32, Height - 19, 'Command in progress', BGRA(90, 90, 100));

    B.Draw(Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

function TTopologyView.SummaryJSON: TJSONObject;
var
  Arr: TJSONArray;
  I: Integer;
  N: TTopoNode;
begin
  Result := TJSONObject.Create(['updated', FormatDateTime('hh:nn:ss', FUpdatedAt)]);
  if FLocal <> nil then Result.Add('viewFrom', FLocal.Id);
  Arr := TJSONArray.Create;
  for I := 0 to FNodes.Count - 1 do
  begin
    N := TTopoNode(FNodes[I]);
    Arr.Add(TJSONObject.Create(['id', N.Id, 'name', N.Name, 'role', NodeRoleCode[N.Role],
      'state', NodeStateCode[N.State], 'stateText', N.StateText,
      'online', N.Online, 'address', N.HostPort, 'self', N.IsSelf]));
  end;
  Result.Add('nodes', Arr);
  Arr := TJSONArray.Create;
  for I := 0 to High(FEdges) do
    Arr.Add(TJSONObject.Create(['from', FEdges[I].FromId, 'to', FEdges[I].ToId,
      'active', FEdges[I].Active, 'stale', FEdges[I].Stale]));
  Result.Add('links', Arr);
end;

{ ---------- separate window ---------- }

type
  TTopoForm = class(TForm)
  public
    View: TTopologyView;
    procedure DoClose(var CloseAction: TCloseAction); override;
  end;

procedure TTopoForm.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  CloseAction := caHide;
end;

procedure ShowTopologyWindow(ALocal: TLocalNode; APoller: TPeerPoller; ASessions: TSessionsFunc);
var
  F: TTopoForm;
begin
  if TopoWindow = nil then
  begin
    F := TTopoForm.CreateNew(Application);
    F.Caption := 'Topology — ' + ALocal.Id;
    F.Width := 900;
    F.Height := 520;
    F.Position := poScreenCenter;
    F.View := TTopologyView.Create(F);
    F.View.Parent := F;
    F.View.Align := alClient;
    TopoWindow := F;
  end;
  F := TTopoForm(TopoWindow);
  F.View.LocalNode := ALocal;
  F.View.Poller := APoller;
  F.View.SessionsFunc := ASessions;
  F.View.RefreshNow;
  F.Show;
  F.BringToFront;
end;

procedure DetachTopologyWindow;
begin
  if TopoWindow = nil then Exit;
  TTopoForm(TopoWindow).View.LocalNode := nil;
  TTopoForm(TopoWindow).View.Poller := nil;
  TTopoForm(TopoWindow).View.SessionsFunc := nil;
end;

function TopologyWindowVisible: Boolean;
begin
  Result := (TopoWindow <> nil) and TopoWindow.Visible;
end;

end.
