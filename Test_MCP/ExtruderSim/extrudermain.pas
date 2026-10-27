unit ExtruderMain;

{ Extrusion line PID simulator - main window
  Page 1 "Process": controls (left), animated process flow diagram + history chart (right)
  Page 2 "Physics": every equation of the model with its live values and a viscosity plot
  Everything graphical is drawn with BGRABitmap and follows the window size. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Spin, IniFiles, Math, BGRABitmap, BGRABitmapTypes, BGRAView, ExtruderModel;

type
  TZoneEdits = record
    SP, Kp, Ki, Kd: TFloatSpinEdit;
  end;

  TLoopEdits = record
    Auto: TCheckBox;
    Kp, Ki, Kd, Manual: TFloatSpinEdit;
  end;

  { TFormExtruder }

  TFormExtruder = class(TForm)
    PageControl1: TPageControl;
    tsProcess: TTabSheet;
    tsPhysics: TTabSheet;
    tmrSim: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure tmrSimTimer(Sender: TObject);
  private
    FLine: TExtruderLine;
    FLeft: TScrollBox;
    FHeader, FFlow, FChart, FPhys: TBGRAView;
    FPhysBox: TScrollBox;
    FChartBar: TPanel;
    FChartForm: TForm;
    FChartShown: Boolean;
    btnChart: TButton;
    // controls
    chkHeaters, chkCold, chkMetal, chkFF: TCheckBox;
    btnStart, btnStop, btnReset, btnScreen, btnCopyPID: TButton;
    cbSpeed, cbGroup, cbWindow: TComboBox;
    tbMat: array[0..MATS - 1] of TTrackBar;
    lblMat: array[0..MATS - 1] of TLabel;
    lblBlend: TLabel;
    Zone: array[0..ZONES - 1] of TZoneEdits;
    seP2SP, seMeltPump: TFloatSpinEdit;
    ExtLoop, DoseLoop: TLoopEdits;
    FLoading: Boolean;
    FGroupTop: Integer;
    FHoverX: Integer;
    FShow: array[0..9] of Boolean;
    FLegend: array[0..9] of TRect;
    FLegendCount: Integer;
    // ui building
    function AddGroup(const ACaption: string; AHeight: Integer): TGroupBox;
    function MkLabel(AParent: TWinControl; X, Y: Integer; const AText: string): TLabel;
    function MkSpin(AParent: TWinControl; X, Y, W: Integer; AMin, AMax, AInc: Double;
      ADec: Integer; AValue: Double): TFloatSpinEdit;
    function MkCheck(AParent: TWinControl; X, Y: Integer; const AText: string; AChecked: Boolean): TCheckBox;
    function MkButton(AParent: TWinControl; X, Y, W, H: Integer; const AText: string; AClick: TNotifyEvent): TButton;
    procedure BuildControls;
    procedure BuildLoop(G: TGroupBox; Y: Integer; const ATitle, AUnit: string; var E: TLoopEdits;
      const C: TPID; AMax: Double);
    procedure ControlsToModel;
    procedure ModelToControls;
    procedure SyncLoop(var E: TLoopEdits; var C: TPID);
    procedure LoadSettings;
    procedure SaveSettings;
    // events
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure ScreenClick(Sender: TObject);
    procedure CopyPIDClick(Sender: TObject);
    procedure MatChange(Sender: TObject);
    procedure GroupChange(Sender: TObject);
    procedure ChartMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ChartMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ChartMouseLeave(Sender: TObject);
    procedure ChartFormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure ChartClick(Sender: TObject);
    // drawing
    procedure RenderHeader(Sender: TObject; B: TBGRABitmap);
    procedure RenderFlow(Sender: TObject; B: TBGRABitmap);
    procedure RenderChart(Sender: TObject; B: TBGRABitmap);
    procedure RenderPhysics(Sender: TObject; B: TBGRABitmap);
    function SpeedFactor: Double;
    function WindowSeconds: Double;
  public
  end;

var
  FormExtruder: TFormExtruder;

implementation

{$R *.lfm}

const
  ZoneColors: array[0..ZONES - 1] of TBGRAPixel = (
    (blue: 60;  green: 160; red: 240; alpha: 255),
    (blue: 40;  green: 110; red: 235; alpha: 255),
    (blue: 50;  green: 60;  red: 220; alpha: 255),
    (blue: 140; green: 50;  red: 170; alpha: 255),
    (blue: 200; green: 70;  red: 90;  alpha: 255));

type
  TSeriesDef = record
    Name: string;
    Color: TBGRAPixel;
    Right: Boolean;     // right axis
    Code: Integer;      // which value of the sample
    Thin: Boolean;
  end;

function IniName: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

function FmtTime(S: Double): string;
var
  T: Int64;
begin
  T := Trunc(S);
  Result := Format('%.2d:%.2d:%.2d', [T div 3600, (T div 60) mod 60, T mod 60]);
end;

{ number with an explicit sign (FPC's Format has no '+' flag) }
function SignF(V: Double): string;
begin
  Result := FormatFloat('+0.000;-0.000;0.000', V);
end;

function Mix(A, B: TBGRAPixel; F: Double): TBGRAPixel;
begin
  F := EnsureRange(F, 0, 1);
  Result := BGRA(Round(A.red + (B.red - A.red) * F), Round(A.green + (B.green - A.green) * F),
    Round(A.blue + (B.blue - A.blue) * F), Round(A.alpha + (B.alpha - A.alpha) * F));
end;

{ temperature colour: cold blue -> green -> orange -> red }
function TempColor(T: Double): TBGRAPixel;
begin
  if T < 100 then Result := Mix(BGRA(70, 120, 220), BGRA(70, 190, 120), (T - 25) / 75)
  else if T < 200 then Result := Mix(BGRA(70, 190, 120), BGRA(245, 170, 40), (T - 100) / 100)
  else Result := Mix(BGRA(245, 170, 40), BGRA(220, 50, 40), (T - 200) / 80);
end;

{ ---------- series of each chart group ---------- }

function GroupSeries(AGroup: Integer; out S: array of TSeriesDef): Integer;

  procedure Put(I: Integer; const AName: string; C: TBGRAPixel; ARight: Boolean; ACode: Integer;
    AThin: Boolean = False);
  begin
    S[I].Name := AName;
    S[I].Color := C;
    S[I].Right := ARight;
    S[I].Code := ACode;
    S[I].Thin := AThin;
  end;

var
  I: Integer;
begin
  case AGroup of
    0: begin // temperatures
         for I := 0 to ZONES - 1 do Put(I, Format('Zone %d', [I + 1]), ZoneColors[I], False, I);
         Put(5, 'Melt temp', BGRA(30, 30, 40), False, 20);
         Put(6, 'Setpoints', BGRA(150, 150, 160), False, 10, True);
         Result := 7;
       end;
    1: begin // pressures
         Put(0, 'P1 after extruder', BGRA(220, 80, 40), False, 30);
         Put(1, 'P2 before melt pump', BGRA(40, 110, 215), False, 31);
         Put(2, 'P2 setpoint', BGRA(40, 110, 215), False, 32, True);
         Put(3, 'Screen dP', BGRA(150, 90, 200), False, 33);
         Put(4, 'P3 die (after melt pump)', BGRA(40, 160, 160), False, 34);
         Result := 5;
       end;
    2: begin // speeds and flows
         Put(0, 'Extruder rpm', BGRA(220, 80, 40), False, 40);
         Put(1, 'Dosing %', BGRA(60, 160, 90), False, 41);
         Put(2, 'Melt pump rpm', BGRA(40, 110, 215), False, 42);
         Put(3, 'Feed kg/h', BGRA(60, 160, 90), True, 43, True);
         Put(4, 'Extruder kg/h', BGRA(220, 80, 40), True, 44, True);
         Put(5, 'Melt pump kg/h', BGRA(40, 110, 215), True, 45, True);
         Result := 6;
       end;
    3: begin // viscosity and screen
         Put(0, 'Viscosity (rel.)', BGRA(150, 90, 200), False, 50);
         Put(1, 'Screen contamination', BGRA(120, 90, 60), False, 51);
         Put(2, 'Screw fill', BGRA(60, 160, 90), False, 52);
         Result := 3;
       end;
  else
    begin // motor loads
      Put(0, 'Extruder motor %', BGRA(220, 80, 40), False, 60);
      Put(1, 'Dosing motor %', BGRA(60, 160, 90), False, 61);
      Put(2, 'Melt pump motor %', BGRA(40, 110, 215), False, 62);
      Put(3, 'Extruder rpm', BGRA(150, 150, 160), True, 40, True);
      Result := 4;
    end;
  end;
end;

function SeriesValue(const S: TLineSample; ACode: Integer; AZoneSP: Integer = 0): Double;
begin
  case ACode of
    0..4: Result := S.Tz[ACode];
    10: Result := S.SPz[AZoneSP];
    20: Result := S.Tmelt;
    30: Result := S.P1;
    31: Result := S.P2;
    32: Result := S.P2SP;
    33: Result := S.P1 - S.P2;
    34: Result := S.P3;
    60: Result := S.ExtLoad;
    61: Result := S.DoseLoad;
    62: Result := S.PumpLoad;
    40: Result := S.Ne;
    41: Result := S.Nd;
    42: Result := S.Nmp;
    43: Result := S.Qd;
    44: Result := S.Qe;
    45: Result := S.Qmp;
    50: Result := S.Mu;
    51: Result := S.S;
    52: Result := S.F;
  else
    Result := 0;
  end;
end;

{ TFormExtruder }

procedure TFormExtruder.FormCreate(Sender: TObject);
var
  I: Integer;
begin
  FLine := TExtruderLine.Create;
  FHoverX := -1;
  for I := 0 to High(FShow) do FShow[I] := True;

  FHeader := TBGRAView.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.Height := 46;
  FHeader.OnRender := @RenderHeader;
  PageControl1.Align := alClient;

  // ---- process page ----
  FLeft := TScrollBox.Create(Self);
  FLeft.Parent := tsProcess;
  FLeft.Align := alLeft;
  FLeft.Width := 352;
  FLeft.BorderStyle := bsNone;
  FLeft.HorzScrollBar.Visible := False;
  FLeft.VertScrollBar.Tracking := True;

  // the process diagram fills the right side of the page
  FFlow := TBGRAView.Create(Self);
  FFlow.Parent := tsProcess;
  FFlow.Align := alClient;
  FFlow.OnRender := @RenderFlow;

  // ---- history chart in its own window ----
  FChartForm := TForm.CreateNew(Self);
  FChartForm.Caption := 'Extrusion line - history chart';
  FChartForm.Width := 1000;
  FChartForm.Height := 420;
  FChartForm.Position := poDesigned;
  FChartForm.Left := Max(0, Left + 120);
  FChartForm.Top := Max(0, Top + Height - 300);
  FChartForm.OnClose := @ChartFormClose;

  FChartBar := TPanel.Create(Self);
  FChartBar.Parent := FChartForm;
  FChartBar.Align := alTop;
  FChartBar.Height := 32;
  FChartBar.BevelOuter := bvNone;
  cbGroup := TComboBox.Create(Self);
  cbGroup.Parent := FChartBar;
  cbGroup.SetBounds(8, 4, 220, 23);
  cbGroup.Style := csDropDownList;
  cbGroup.Items.CommaText := '"Temperatures (5 zones)","Pressures P1 / P2 / P3","Speeds and flows",' +
    '"Viscosity, screen and fill","Motor loads"';
  cbGroup.ItemIndex := 0;
  cbGroup.OnChange := @GroupChange;
  MkLabel(FChartBar, 240, 8, 'Window');
  cbWindow := TComboBox.Create(Self);
  cbWindow.Parent := FChartBar;
  cbWindow.SetBounds(290, 4, 90, 23);
  cbWindow.Style := csDropDownList;
  cbWindow.Items.CommaText := '"2 min","5 min","10 min","30 min","60 min"';
  cbWindow.ItemIndex := 1;

  FChart := TBGRAView.Create(Self);
  FChart.Parent := FChartForm;
  FChart.Align := alClient;
  FChart.Background := BGRAWhite;
  FChart.OnRender := @RenderChart;
  FChart.OnMouseMove := @ChartMouseMove;
  FChart.OnMouseDown := @ChartMouseDown;
  FChart.OnMouseLeave := @ChartMouseLeave;

  // ---- physics page ----
  FPhysBox := TScrollBox.Create(Self);
  FPhysBox.Parent := tsPhysics;
  FPhysBox.Align := alClient;
  FPhysBox.BorderStyle := bsNone;
  FPhysBox.HorzScrollBar.Visible := False;
  FPhysBox.VertScrollBar.Tracking := True;
  FPhys := TBGRAView.Create(Self);
  FPhys.Parent := FPhysBox;
  FPhys.Left := 0;
  FPhys.Top := 0;
  FPhys.Height := 1400;
  FPhys.Anchors := [akLeft, akTop, akRight];
  FPhys.OnRender := @RenderPhysics;

  BuildControls;
  LoadSettings;
  ModelToControls;
end;

procedure TFormExtruder.FormShow(Sender: TObject);
begin
  // open the chart window below the main window the first time
  if not FChartShown then
  begin
    FChartShown := True;
    FChartForm.Left := Left + 60;
    FChartForm.Top := Min(Top + Height - 120, Screen.WorkAreaHeight - FChartForm.Height);
    FChartForm.Show;
  end;
end;

procedure TFormExtruder.ChartFormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
end;

procedure TFormExtruder.ChartClick(Sender: TObject);
begin
  if FChartForm.Visible then FChartForm.Hide
  else
  begin
    FChartForm.Show;
    FChartForm.BringToFront;
  end;
end;

procedure TFormExtruder.FormDestroy(Sender: TObject);
begin
  tmrSim.Enabled := False;
  SaveSettings;
  FLine.Free;
end;

{ ---------- control building ---------- }

function TFormExtruder.AddGroup(const ACaption: string; AHeight: Integer): TGroupBox;
begin
  Result := TGroupBox.Create(Self);
  Result.Parent := FLeft;
  Result.Caption := ' ' + ACaption + ' ';
  // keep the groups in creation order (alTop sorts by Top)
  Result.Top := FGroupTop;
  Inc(FGroupTop, AHeight + 10);
  Result.Height := AHeight;
  Result.Align := alTop;
  Result.BorderSpacing.Around := 4;
end;

function TFormExtruder.MkLabel(AParent: TWinControl; X, Y: Integer; const AText: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := AText;
end;

function TFormExtruder.MkSpin(AParent: TWinControl; X, Y, W: Integer; AMin, AMax, AInc: Double;
  ADec: Integer; AValue: Double): TFloatSpinEdit;
begin
  Result := TFloatSpinEdit.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 23);
  Result.MinValue := AMin;
  Result.MaxValue := AMax;
  Result.Increment := AInc;
  Result.DecimalPlaces := ADec;
  Result.Value := AValue;
end;

function TFormExtruder.MkCheck(AParent: TWinControl; X, Y: Integer; const AText: string;
  AChecked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := AText;
  Result.Checked := AChecked;
end;

function TFormExtruder.MkButton(AParent: TWinControl; X, Y, W, H: Integer; const AText: string;
  AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, H);
  Result.Caption := AText;
  Result.OnClick := AClick;
end;

procedure TFormExtruder.BuildLoop(G: TGroupBox; Y: Integer; const ATitle, AUnit: string;
  var E: TLoopEdits; const C: TPID; AMax: Double);
begin
  with MkLabel(G, 8, Y + 4, ATitle) do Font.Style := [fsBold];
  E.Auto := MkCheck(G, 150, Y + 2, 'Auto (PID)', C.Auto);
  MkLabel(G, 8, Y + 30, 'Kp');
  E.Kp := MkSpin(G, 28, Y + 26, 62, 0, 50, 0.05, 2, C.Kp);
  MkLabel(G, 96, Y + 30, 'Ki');
  E.Ki := MkSpin(G, 114, Y + 26, 70, 0, 10, 0.005, 3, C.Ki);
  MkLabel(G, 190, Y + 30, 'Kd');
  E.Kd := MkSpin(G, 210, Y + 26, 58, 0, 50, 0.1, 1, C.Kd);
  MkLabel(G, 8, Y + 58, 'Manual ' + AUnit);
  E.Manual := MkSpin(G, 110, Y + 54, 74, 0, AMax, 1, 1, C.Manual);
end;

procedure TFormExtruder.BuildControls;
var
  G: TGroupBox;
  I: Integer;
begin
  // line
  G := AddGroup('Line', 104);
  btnStart := MkButton(G, 6, 2, 98, 30, 'Start line', @StartClick);
  btnStart.Font.Style := [fsBold];
  btnStop := MkButton(G, 108, 2, 98, 30, 'Stop line', @StopClick);
  btnStop.Font.Style := [fsBold];
  btnReset := MkButton(G, 210, 2, 96, 30, 'Reset trip', @ResetClick);
  chkHeaters := MkCheck(G, 8, 40, 'Heaters ON', True);
  chkCold := MkCheck(G, 120, 40, 'Cold-start interlock', True);
  MkLabel(G, 8, 66, 'Speed');
  btnChart := MkButton(G, 160, 61, 146, 25, 'Chart window', @ChartClick);
  cbSpeed := TComboBox.Create(Self);
  cbSpeed.Parent := G;
  cbSpeed.SetBounds(50, 62, 100, 23);
  cbSpeed.Style := csDropDownList;
  cbSpeed.Items.CommaText := 'x1,x2,x5,x10,x30';
  cbSpeed.ItemIndex := 3;

  // raw materials
  G := AddGroup('Raw materials (any blend)', 150);
  for I := 0 to MATS - 1 do
  begin
    lblMat[I] := MkLabel(G, 8, 8 + I * 28, FLine.Polymers[I].Name);
    lblMat[I].Font.Style := [fsBold];
    lblMat[I].Font.Color := RGBToColor(FLine.Polymers[I].Color[0] div 2, FLine.Polymers[I].Color[1] div 2,
      FLine.Polymers[I].Color[2] div 2);
    tbMat[I] := TTrackBar.Create(Self);
    tbMat[I].Parent := G;
    tbMat[I].SetBounds(56, 2 + I * 28, 252, 26);
    tbMat[I].Max := 100;
    tbMat[I].Frequency := 10;
    tbMat[I].Position := Round(FLine.Blend[I]);
    tbMat[I].OnChange := @MatChange;
  end;
  lblBlend := MkLabel(G, 8, 88, '');

  // heater zones
  G := AddGroup('Heater zones PID (out ±100 %, minus = fan)', 196);
  MkLabel(G, 8, 4, 'Zone');
  MkLabel(G, 50, 4, 'SP °C');
  MkLabel(G, 118, 4, 'Kp');
  MkLabel(G, 180, 4, 'Ki');
  MkLabel(G, 248, 4, 'Kd');
  for I := 0 to ZONES - 1 do
  begin
    with MkLabel(G, 14, 26 + I * 27, IntToStr(I + 1)) do Font.Style := [fsBold];
    Zone[I].SP := MkSpin(G, 36, 22 + I * 27, 70, 25, 320, 5, 0, FLine.ZoneSP[I]);
    Zone[I].Kp := MkSpin(G, 108, 22 + I * 27, 60, 0, 100, 0.5, 1, FLine.ZonePID[I].Kp);
    Zone[I].Ki := MkSpin(G, 170, 22 + I * 27, 70, 0, 10, 0.01, 3, FLine.ZonePID[I].Ki);
    Zone[I].Kd := MkSpin(G, 242, 22 + I * 27, 64, 0, 500, 5, 0, FLine.ZonePID[I].Kd);
  end;
  btnCopyPID := MkButton(G, 108, 158, 198, 24, 'Copy zone 1 PID to all zones', @CopyPIDClick);

  // pressure control
  G := AddGroup('P2 control (pressure before melt pump)', 250);
  MkLabel(G, 8, 6, 'P2 setpoint (bar)');
  seP2SP := MkSpin(G, 120, 2, 80, 0, 300, 5, 0, FLine.P2SP);
  BuildLoop(G, 32, 'Extruder speed', '(rpm)', ExtLoop, FLine.ExtruderPID, 120);
  BuildLoop(G, 124, 'Dosing screw speed', '(%)', DoseLoop, FLine.DosingPID, 100);
  chkFF := MkCheck(G, 8, 208, 'Dosing feed-forward = melt pump throughput', FLine.DosingFF);

  // melt pump + screen + metal
  G := AddGroup('Melt pump, screen changer, metal detector', 100);
  MkLabel(G, 8, 6, 'Melt pump speed (rpm, fixed)');
  seMeltPump := MkSpin(G, 196, 2, 80, 0, 60, 1, 0, FLine.MeltPumpRpm);
  btnScreen := MkButton(G, 6, 32, 150, 28, 'Change screen', @ScreenClick);
  chkMetal := MkCheck(G, 166, 38, 'Metal detector ON', True);
end;

{ ---------- model <-> controls ---------- }

procedure TFormExtruder.SyncLoop(var E: TLoopEdits; var C: TPID);
begin
  C.Kp := E.Kp.Value;
  C.Ki := E.Ki.Value;
  C.Kd := E.Kd.Value;
  if E.Auto.Checked <> C.Auto then
  begin
    PIDSetAuto(C, E.Auto.Checked);
    if not C.Auto then E.Manual.Value := C.Manual; // manual starts where the PID was
  end
  else if not C.Auto then
    C.Manual := E.Manual.Value;
  E.Manual.Enabled := not C.Auto;
end;

procedure TFormExtruder.ControlsToModel;
var
  I: Integer;
begin
  if FLoading then Exit;
  FLine.HeatersOn := chkHeaters.Checked;
  FLine.ColdProtect := chkCold.Checked;
  FLine.MetalDetector := chkMetal.Checked;
  FLine.DosingFF := chkFF.Checked;
  for I := 0 to MATS - 1 do FLine.Blend[I] := tbMat[I].Position;
  for I := 0 to ZONES - 1 do
  begin
    FLine.ZoneSP[I] := Zone[I].SP.Value;
    FLine.ZonePID[I].Kp := Zone[I].Kp.Value;
    FLine.ZonePID[I].Ki := Zone[I].Ki.Value;
    FLine.ZonePID[I].Kd := Zone[I].Kd.Value;
  end;
  FLine.P2SP := seP2SP.Value;
  FLine.MeltPumpRpm := seMeltPump.Value;
  SyncLoop(ExtLoop, FLine.ExtruderPID);
  SyncLoop(DoseLoop, FLine.DosingPID);
end;

procedure TFormExtruder.ModelToControls;
var
  I: Integer;
begin
  FLoading := True;
  try
    chkHeaters.Checked := FLine.HeatersOn;
    chkCold.Checked := FLine.ColdProtect;
    chkMetal.Checked := FLine.MetalDetector;
    chkFF.Checked := FLine.DosingFF;
    for I := 0 to MATS - 1 do tbMat[I].Position := Round(FLine.Blend[I]);
    for I := 0 to ZONES - 1 do
    begin
      Zone[I].SP.Value := FLine.ZoneSP[I];
      Zone[I].Kp.Value := FLine.ZonePID[I].Kp;
      Zone[I].Ki.Value := FLine.ZonePID[I].Ki;
      Zone[I].Kd.Value := FLine.ZonePID[I].Kd;
    end;
    seP2SP.Value := FLine.P2SP;
    seMeltPump.Value := FLine.MeltPumpRpm;
    ExtLoop.Auto.Checked := FLine.ExtruderPID.Auto;
    ExtLoop.Kp.Value := FLine.ExtruderPID.Kp;
    ExtLoop.Ki.Value := FLine.ExtruderPID.Ki;
    ExtLoop.Kd.Value := FLine.ExtruderPID.Kd;
    ExtLoop.Manual.Value := FLine.ExtruderPID.Manual;
    DoseLoop.Auto.Checked := FLine.DosingPID.Auto;
    DoseLoop.Kp.Value := FLine.DosingPID.Kp;
    DoseLoop.Ki.Value := FLine.DosingPID.Ki;
    DoseLoop.Kd.Value := FLine.DosingPID.Kd;
    DoseLoop.Manual.Value := FLine.DosingPID.Manual;
  finally
    FLoading := False;
  end;
  MatChange(nil);
end;

procedure TFormExtruder.LoadSettings;
var
  Ini: TIniFile;
  I: Integer;
  K: string;
begin
  if not FileExists(IniName) then Exit;
  Ini := TIniFile.Create(IniName);
  try
    for I := 0 to MATS - 1 do
      FLine.Blend[I] := Ini.ReadFloat('Blend', FLine.Polymers[I].Name, FLine.Blend[I]);
    for I := 0 to ZONES - 1 do
    begin
      K := 'Zone' + IntToStr(I + 1);
      FLine.ZoneSP[I] := Ini.ReadFloat(K, 'SP', FLine.ZoneSP[I]);
      FLine.ZonePID[I].Kp := Ini.ReadFloat(K, 'Kp', FLine.ZonePID[I].Kp);
      FLine.ZonePID[I].Ki := Ini.ReadFloat(K, 'Ki', FLine.ZonePID[I].Ki);
      FLine.ZonePID[I].Kd := Ini.ReadFloat(K, 'Kd', FLine.ZonePID[I].Kd);
    end;
    FLine.P2SP := Ini.ReadFloat('P2', 'SP', FLine.P2SP);
    FLine.ExtruderPID.Kp := Ini.ReadFloat('ExtruderPID', 'Kp', FLine.ExtruderPID.Kp);
    FLine.ExtruderPID.Ki := Ini.ReadFloat('ExtruderPID', 'Ki', FLine.ExtruderPID.Ki);
    FLine.ExtruderPID.Kd := Ini.ReadFloat('ExtruderPID', 'Kd', FLine.ExtruderPID.Kd);
    FLine.DosingPID.Kp := Ini.ReadFloat('DosingPID', 'Kp', FLine.DosingPID.Kp);
    FLine.DosingPID.Ki := Ini.ReadFloat('DosingPID', 'Ki', FLine.DosingPID.Ki);
    FLine.DosingPID.Kd := Ini.ReadFloat('DosingPID', 'Kd', FLine.DosingPID.Kd);
    FLine.DosingFF := Ini.ReadBool('DosingPID', 'FeedForward', FLine.DosingFF);
    FLine.MeltPumpRpm := Ini.ReadFloat('MeltPump', 'Rpm', FLine.MeltPumpRpm);
    cbSpeed.ItemIndex := Ini.ReadInteger('View', 'Speed', cbSpeed.ItemIndex);
    cbWindow.ItemIndex := Ini.ReadInteger('View', 'Window', cbWindow.ItemIndex);
  finally
    Ini.Free;
  end;
end;

procedure TFormExtruder.SaveSettings;
var
  Ini: TIniFile;
  I: Integer;
  K: string;
begin
  try
    Ini := TIniFile.Create(IniName);
    try
      for I := 0 to MATS - 1 do Ini.WriteFloat('Blend', FLine.Polymers[I].Name, FLine.Blend[I]);
      for I := 0 to ZONES - 1 do
      begin
        K := 'Zone' + IntToStr(I + 1);
        Ini.WriteFloat(K, 'SP', FLine.ZoneSP[I]);
        Ini.WriteFloat(K, 'Kp', FLine.ZonePID[I].Kp);
        Ini.WriteFloat(K, 'Ki', FLine.ZonePID[I].Ki);
        Ini.WriteFloat(K, 'Kd', FLine.ZonePID[I].Kd);
      end;
      Ini.WriteFloat('P2', 'SP', FLine.P2SP);
      Ini.WriteFloat('ExtruderPID', 'Kp', FLine.ExtruderPID.Kp);
      Ini.WriteFloat('ExtruderPID', 'Ki', FLine.ExtruderPID.Ki);
      Ini.WriteFloat('ExtruderPID', 'Kd', FLine.ExtruderPID.Kd);
      Ini.WriteFloat('DosingPID', 'Kp', FLine.DosingPID.Kp);
      Ini.WriteFloat('DosingPID', 'Ki', FLine.DosingPID.Ki);
      Ini.WriteFloat('DosingPID', 'Kd', FLine.DosingPID.Kd);
      Ini.WriteBool('DosingPID', 'FeedForward', FLine.DosingFF);
      Ini.WriteFloat('MeltPump', 'Rpm', FLine.MeltPumpRpm);
      Ini.WriteInteger('View', 'Speed', cbSpeed.ItemIndex);
      Ini.WriteInteger('View', 'Window', cbWindow.ItemIndex);
    finally
      Ini.Free;
    end;
  except
    // settings are only a convenience
  end;
end;

{ ---------- events ---------- }

procedure TFormExtruder.StartClick(Sender: TObject);
begin
  ControlsToModel;
  FLine.StartLine;
end;

procedure TFormExtruder.StopClick(Sender: TObject);
begin
  FLine.StopLine;
end;

procedure TFormExtruder.ResetClick(Sender: TObject);
begin
  FLine.ResetTrip;
end;

procedure TFormExtruder.ScreenClick(Sender: TObject);
begin
  FLine.ChangeScreen;
end;

procedure TFormExtruder.CopyPIDClick(Sender: TObject);
var
  I: Integer;
begin
  for I := 1 to ZONES - 1 do
  begin
    Zone[I].Kp.Value := Zone[0].Kp.Value;
    Zone[I].Ki.Value := Zone[0].Ki.Value;
    Zone[I].Kd.Value := Zone[0].Kd.Value;
  end;
end;

procedure TFormExtruder.MatChange(Sender: TObject);
var
  I: Integer;
begin
  if not FLoading then
    for I := 0 to MATS - 1 do FLine.Blend[I] := tbMat[I].Position;
  lblBlend.Caption := Format('%s%sneeds > %.0f °C to melt · degrades > %.0f °C · bulk %.2f kg/L',
    [FLine.BlendText, LineEnding, FLine.BlendTm, FLine.BlendTdeg, FLine.BlendBulk]);
end;

procedure TFormExtruder.GroupChange(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to High(FShow) do FShow[I] := True;
  FChart.Invalidate;
end;

function TFormExtruder.SpeedFactor: Double;
const
  Speeds: array[0..4] of Double = (1, 2, 5, 10, 30);
begin
  if (cbSpeed.ItemIndex >= 0) and (cbSpeed.ItemIndex <= 4) then Result := Speeds[cbSpeed.ItemIndex]
  else Result := 1;
end;

function TFormExtruder.WindowSeconds: Double;
const
  Mins: array[0..4] of Integer = (2, 5, 10, 30, 60);
begin
  if (cbWindow.ItemIndex >= 0) and (cbWindow.ItemIndex <= 4) then Result := Mins[cbWindow.ItemIndex] * 60
  else Result := 300;
end;

procedure TFormExtruder.tmrSimTimer(Sender: TObject);
begin
  ControlsToModel;
  FLine.Step(tmrSim.Interval / 1000 * SpeedFactor);
  FHeader.Invalidate;
  if FChartForm.Visible then FChart.Invalidate;
  if PageControl1.ActivePage = tsProcess then
    FFlow.Invalidate
  else
  begin
    FPhys.Width := FPhysBox.ClientWidth;
    FPhys.Invalidate;
  end;
end;

procedure TFormExtruder.ChartMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  FHoverX := X;
end;

procedure TFormExtruder.ChartMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
end;

procedure TFormExtruder.ChartMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
begin
  for I := 0 to FLegendCount - 1 do
    if FLegend[I].Contains(Point(X, Y)) then
    begin
      FShow[I] := not FShow[I];
      FChart.Invalidate;
      Exit;
    end;
end;

{ ---------- drawing helpers ---------- }

procedure Chip(B: TBGRABitmap; var X: Single; Y: Single; const AText: string; C: TBGRAPixel);
var
  W: Integer;
begin
  B.FontHeight := 12;
  B.FontStyle := [fsBold];
  W := B.TextSize(AText).cx;
  B.FillRoundRectAntialias(X, Y, X + W + 18, Y + 22, 11, 11, C);
  B.TextOut(X + 9, Y + 3, AText, BGRAWhite);
  X := X + W + 24;
end;

procedure ValueBox(B: TBGRABitmap; X, Y: Single; const ATitle, AValue: string; C: TBGRAPixel);
var
  W: Integer;
begin
  B.FontHeight := 11;
  B.FontStyle := [];
  W := Max(B.TextSize(ATitle).cx, 0);
  B.FontHeight := 14;
  B.FontStyle := [fsBold];
  W := Max(W, B.TextSize(AValue).cx);
  B.FillRoundRectAntialias(X - W / 2 - 8, Y, X + W / 2 + 8, Y + 38, 6, 6, BGRA(255, 255, 255, 235));
  B.RoundRectAntialias(X - W / 2 - 8, Y, X + W / 2 + 8, Y + 38, 6, 6, C, 1.5);
  B.FontHeight := 11;
  B.FontStyle := [];
  B.TextOut(X, Y + 3, ATitle, BGRA(100, 105, 120), taCenter);
  B.FontHeight := 14;
  B.FontStyle := [fsBold];
  B.TextOut(X, Y + 17, AValue, C, taCenter);
end;

{ pressure gauge (small dial) }
procedure Gauge(B: TBGRAPixel; Bmp: TBGRABitmap; CX, CY, R: Single; AValue, AMax, ASP: Double;
  const ATitle: string);
var
  A0, A1, F: Single;
  I, N: Integer;
  Pts: ArrayOfTPointF;
begin
  A0 := DegToRad(220);
  A1 := DegToRad(-40);
  Bmp.FillEllipseAntialias(CX, CY, R + 4, R + 4, BGRA(45, 50, 65));
  Bmp.FillEllipseAntialias(CX, CY, R, R, BGRA(250, 251, 253));
  N := 30;
  SetLength(Pts, N + 1);
  F := EnsureRange(AValue / AMax, 0, 1);
  for I := 0 to N do
    Pts[I] := PointF(CX + (R - 5) * Cos(A0 + (A1 - A0) * F * I / N), CY - (R - 5) * Sin(A0 + (A1 - A0) * F * I / N));
  Bmp.LineCap := pecRound;
  if F > 0.01 then Bmp.DrawPolyLineAntialias(Pts, B, 4);
  if ASP > 0 then
  begin
    F := EnsureRange(ASP / AMax, 0, 1);
    Bmp.DrawLineAntialias(CX + (R - 10) * Cos(A0 + (A1 - A0) * F), CY - (R - 10) * Sin(A0 + (A1 - A0) * F),
      CX + R * Cos(A0 + (A1 - A0) * F), CY - R * Sin(A0 + (A1 - A0) * F), BGRA(40, 110, 215), 2.5);
  end;
  Bmp.FontHeight := Max(10, Round(R * 0.42));
  Bmp.FontStyle := [fsBold];
  Bmp.TextOut(CX, CY - Bmp.FontHeight * 0.6, Format('%.0f', [AValue]), BGRA(30, 35, 50), taCenter);
  Bmp.FontHeight := Max(9, Round(R * 0.26));
  Bmp.FontStyle := [];
  Bmp.TextOut(CX, CY + R * 0.3, 'bar', BGRA(110, 115, 130), taCenter);
  Bmp.FontHeight := 11;
  Bmp.FontStyle := [fsBold];
  Bmp.TextOut(CX, CY - R - 20, ATitle, BGRA(40, 45, 60), taCenter);
end;

procedure TFormExtruder.RenderHeader(Sender: TObject; B: TBGRABitmap);
var
  H: TBGRAView;
  X: Single;
  A: string;
  Parts: TStringArray;
  I: Integer;
begin
  H := TBGRAView(Sender);
  B.GradientFill(0, 0, H.Width, H.Height, BGRA(28, 36, 58), BGRA(46, 60, 96), gtLinear,
    PointF(0, 0), PointF(H.Width, 0), dmSet);
  B.FontHeight := 17;
  B.FontStyle := [fsBold];
  B.TextOut(16, 3, 'Extrusion Line PID Simulator', BGRAWhite);
  B.FontHeight := 12;
  B.FontStyle := [];
  B.TextOut(18, 26, Format('time %s  ·  x%g  ·  output %.1f kg/h  ·  produced %.1f kg  ·  %s',
    [FmtTime(FLine.SimTime), SpeedFactor, FLine.Qmp, FLine.TotalKg, FLine.BlendText]), BGRA(180, 195, 225));
  X := Max(440, H.Width * 0.5);
  if FLine.Running then Chip(B, X, 12, 'LINE RUNNING', BGRA(35, 160, 80))
  else Chip(B, X, 12, 'LINE STOPPED', BGRA(110, 115, 130));
  if FLine.HeatersOn then Chip(B, X, 12, 'HEATERS ON', BGRA(220, 110, 30));
  A := FLine.Alarms;
  if A <> '' then
  begin
    Parts := A.Split([' · ']);
    for I := 0 to High(Parts) do
      if X < H.Width - 60 then Chip(B, X, 12, Parts[I], BGRA(215, 50, 50));
  end;
end;

{ ---------- process flow diagram ---------- }

procedure TFormExtruder.RenderFlow(Sender: TObject; B: TBGRABitmap);
var
  V: TBGRAView;
  W, H, Ph, X, Y, X0, X1, BY, BH, BarX0, BarX1, ZW, F, R, MX, Rot: Single;
  I, J: Integer;
  C: TBGRAPixel;
  Pts: ArrayOfTPointF;
  Rejecting: Boolean;
begin
  V := TBGRAView(Sender);
  W := V.Width;
  H := V.Height;
  B.FillRectAntialias(0, 0, W, H, BGRA(240, 243, 248));
  if (W < 300) or (H < 180) then Exit;
  Ph := GetTickCount64 / 1000;
  B.FontName := 'Segoe UI';

  BY := H * 0.56;          // centre line of the barrel
  BH := Max(26, H * 0.13); // barrel height

  // ---- hopper with the 3 materials ----
  X0 := W * 0.015;
  X1 := W * 0.10;
  Y := H * 0.10;
  B.FontHeight := 11;
  B.FontStyle := [fsBold];
  B.TextOut((X0 + X1) / 2, Y - 16, 'Raw materials', BGRA(60, 65, 80), taCenter);
  for I := 0 to MATS - 1 do
  begin
    C := BGRA(FLine.Polymers[I].Color[0], FLine.Polymers[I].Color[1], FLine.Polymers[I].Color[2]);
    MX := X0 + (X1 - X0) * I / 3;
    B.FillRectAntialias(MX + 2, Y, MX + (X1 - X0) / 3 - 2, Y + H * 0.16, BGRA(220, 224, 232));
    F := FLine.Weight(I);
    B.FillRectAntialias(MX + 2, Y + H * 0.16 * (1 - F), MX + (X1 - X0) / 3 - 2, Y + H * 0.16, C);
    B.FontHeight := 10;
    B.TextOut(MX + (X1 - X0) / 6, Y + H * 0.16 + 2, FLine.Polymers[I].Name, BGRA(70, 75, 90), taCenter);
    B.TextOut(MX + (X1 - X0) / 6, Y + H * 0.16 + 14, Format('%.0f%%', [F * 100]), BGRA(70, 75, 90), taCenter);
  end;
  // funnel down to the dosing screw
  B.FillPolyAntialias([PointF(X0, Y + H * 0.16 + 30), PointF(X1, Y + H * 0.16 + 30),
    PointF((X0 + X1) / 2 + 8, BY - BH * 0.9), PointF((X0 + X1) / 2 - 8, BY - BH * 0.9)], BGRA(150, 158, 175));

  // ---- dosing screw ----
  X0 := (W * 0.015 + W * 0.10) / 2 - 10;
  X1 := W * 0.21;
  Y := BY - BH * 0.9;
  B.FillRoundRectAntialias(X0, Y, X1, Y + BH * 0.55, 6, 6, BGRA(120, 128, 145));
  Rot := Frac(Ph * FLine.Nd / 40);
  for J := 0 to 9 do
  begin
    MX := X0 + 6 + (X1 - X0 - 12) * Frac(J / 10 + Rot);
    B.DrawLineAntialias(MX, Y + 3, MX + 7, Y + BH * 0.55 - 3, BGRA(230, 235, 245), 2);
  end;
  ValueBox(B, (X0 + X1) / 2, Y + BH * 0.55 + 6, Format('Dosing · motor %.0f %%', [FLine.DoseLoad]),
    Format('%.0f %%  %.0f kg/h', [FLine.Nd, FLine.Qd]), BGRA(60, 160, 90));

  // ---- metal detector (on the drop to the feed throat) ----
  MX := W * 0.235;
  Rejecting := (FLine.EventCount > 0) and (FLine.Event(FLine.EventCount - 1).Kind = leMetalRejected) and
    (FLine.SimTime - FLine.Event(FLine.EventCount - 1).T < 3);
  if Rejecting then C := BGRA(220, 50, 50) else if FLine.MetalDetector then C := BGRA(40, 150, 90)
  else C := BGRA(150, 150, 160);
  B.FillRectAntialias(X1, Y + BH * 0.15, MX, Y + BH * 0.4, BGRA(150, 158, 175));
  B.FillRectAntialias(MX - 6, Y + BH * 0.15, MX + 6, BY - BH / 2, BGRA(150, 158, 175));
  B.EllipseAntialias(MX, Y + BH * 0.75, 15, 9, C, 4);
  B.FontHeight := 10;
  B.FontStyle := [fsBold];
  B.TextOut(MX, Y - 30, 'Metal', C, taCenter);
  B.TextOut(MX, Y - 18, 'detector', C, taCenter);
  B.FontStyle := [];
  if FLine.MetalDetector then
    B.TextOut(MX, Y + BH * 0.75 + 12, Format('rejects %d', [FLine.MetalRejects]), C, taCenter)
  else
    B.TextOut(MX, Y + BH * 0.75 + 12, 'OFF', C, taCenter);

  // ---- extruder barrel with 5 heater zones ----
  BarX0 := W * 0.22;
  BarX1 := W * 0.66;
  ZW := (BarX1 - BarX0) / ZONES;
  B.FontHeight := 12;
  B.FontStyle := [fsBold];
  B.TextOut((BarX0 + BarX1) / 2, BY + BH / 2 + 50, Format('Extruder  %.0f rpm  ·  fill %.0f %%  ·  %.0f kg/h',
    [FLine.Ne, FLine.F * 100, FLine.Qe]), BGRA(60, 65, 80), taCenter);
  // barrel
  B.FillRoundRectAntialias(BarX0, BY - BH / 2, BarX1, BY + BH / 2, 6, 6, BGRA(95, 100, 115));
  // material inside (fill degree, colour = blend)
  C := BGRA(0, 0, 0);
  for I := 0 to MATS - 1 do
    C := BGRA(C.red + Round(FLine.Weight(I) * FLine.Polymers[I].Color[0]),
      C.green + Round(FLine.Weight(I) * FLine.Polymers[I].Color[1]),
      C.blue + Round(FLine.Weight(I) * FLine.Polymers[I].Color[2]));
  if FLine.F > 0.01 then
    B.FillRectAntialias(BarX0 + 4, BY + BH / 2 - 4 - (BH - 8) * FLine.F, BarX1 - 4, BY + BH / 2 - 4,
      BGRA(C.red, C.green, C.blue, 200));
  // screw flights
  Rot := Frac(Ph * FLine.Ne / 60);
  for J := 0 to 23 do
  begin
    MX := BarX0 + 8 + (BarX1 - BarX0 - 16) * Frac(J / 24 + Rot * 0.25);
    B.DrawLineAntialias(MX, BY - BH / 2 + 4, MX + BH * 0.35, BY + BH / 2 - 4, BGRA(210, 215, 225, 200), 2);
  end;
  B.DrawLineAntialias(BarX0 + 4, BY, BarX1 - 4, BY, BGRA(170, 175, 190), 3);
  // heater bands + labels
  for I := 0 to ZONES - 1 do
  begin
    X := BarX0 + ZW * I;
    C := TempColor(FLine.Tz[I]);
    B.FillRoundRectAntialias(X + 4, BY - BH / 2 - 10, X + ZW - 4, BY - BH / 2 + 2, 3, 3, C);
    B.FillRoundRectAntialias(X + 4, BY + BH / 2 - 2, X + ZW - 4, BY + BH / 2 + 10, 3, 3, C);
    // output bar: heating orange, cooling blue
    F := FLine.ZonePID[I].Output;
    if F > 0 then
      B.FillRectAntialias(X + 6, BY + BH / 2 + 13, X + 6 + (ZW - 12) * F / 100, BY + BH / 2 + 18, BGRA(240, 120, 30))
    else if F < 0 then
      B.FillRectAntialias(X + 6, BY + BH / 2 + 13, X + 6 + (ZW - 12) * (-F) / 100, BY + BH / 2 + 18, BGRA(60, 140, 230));
    ValueBox(B, X + ZW / 2, BY - BH / 2 - 54, Format('Zone %d  SP %.0f', [I + 1, FLine.ZoneSP[I]]),
      Format('%.1f °C', [FLine.Tz[I]]), C);
    B.FontHeight := 10;
    B.FontStyle := [];
    if F >= 0 then
      B.TextOut(X + ZW / 2, BY + BH / 2 + 20, Format('heat %.0f%%', [F]), BGRA(200, 100, 20), taCenter)
    else
      B.TextOut(X + ZW / 2, BY + BH / 2 + 20, Format('cool %.0f%%', [-F]), BGRA(40, 110, 210), taCenter);
  end;
  // motor + gearbox at the feed end
  B.FillRoundRectAntialias(BarX0 - 6, BY - BH / 2 - 2, BarX0 + 4, BY + BH / 2 + 2, 3, 3, BGRA(60, 65, 80));

  // extruder motor load bar (green < 80 %, orange < 110 %, red above)
  F := FLine.ExtLoad;
  if F < 80 then C := BGRA(40, 160, 80) else if F < 110 then C := BGRA(235, 140, 30) else C := BGRA(215, 50, 50);
  X0 := (BarX0 + BarX1) / 2 - 130;
  X1 := (BarX0 + BarX1) / 2 + 130;
  Y := BY + BH / 2 + 70;
  if Y + 14 < H - 4 then
  begin
    B.FontHeight := 11;
    B.FontStyle := [fsBold];
    B.TextOut(X0 - 8, Y - 1, 'Motor load', BGRA(60, 65, 80), taRightJustify);
    B.FillRoundRectAntialias(X0, Y, X1, Y + 14, 7, 7, BGRA(220, 224, 232));
    B.FillRoundRectAntialias(X0, Y, X0 + (X1 - X0) * EnsureRange(F, 0, 150) / 150, Y + 14, 7, 7, C);
    // rated torque mark at 100 %
    B.DrawLineAntialias(X0 + (X1 - X0) / 1.5, Y - 3, X0 + (X1 - X0) / 1.5, Y + 17, BGRA(60, 65, 80), 1.5);
    B.TextOut(X1 + 8, Y - 1, Format('%.0f %%  ·  %.1f kW', [F, FLine.MotorPowerW / 1000]), C);
  end;

  // ---- P1, screen changer, P2, melt pump, die ----
  R := Max(18, Min(H * 0.1, W * 0.028));
  X := W * 0.695;
  B.FillRectAntialias(BarX1, BY - BH * 0.18, W * 0.965, BY + BH * 0.18, BGRA(110, 116, 132));
  Gauge(BGRA(220, 80, 40), B, X, BY - BH / 2 - R - 22, R, FLine.P1, 350, 0, 'P1');
  B.DrawLineAntialias(X, BY - BH / 2 - 22, X, BY - BH * 0.18, BGRA(110, 116, 132), 3);

  // screen changer: colour shows the contamination
  MX := W * 0.755;
  C := Mix(BGRA(200, 205, 215), BGRA(110, 80, 50), FLine.S / 2);
  B.FillRoundRectAntialias(MX - 16, BY - BH * 0.9, MX + 16, BY + BH * 0.9, 4, 4, BGRA(80, 86, 100));
  B.FillRectAntialias(MX - 4, BY - BH * 0.6, MX + 4, BY + BH * 0.6, C);
  for J := -3 to 3 do
    B.DrawLineAntialias(MX - 4, BY + J * BH * 0.16, MX + 4, BY + J * BH * 0.16, BGRA(60, 60, 70, 120), 1);
  B.FontHeight := 11;
  B.FontStyle := [fsBold];
  B.TextOut(MX, BY + BH * 0.9 + 4, 'Screen', BGRA(60, 65, 80), taCenter);
  B.FontStyle := [];
  B.FontHeight := 10;
  B.TextOut(MX, BY + BH * 0.9 + 18, Format('dP %.0f bar', [FLine.DPScreen]), BGRA(120, 80, 160), taCenter);
  B.TextOut(MX, BY + BH * 0.9 + 30, Format('dirt %.2f', [FLine.S]), BGRA(120, 80, 160), taCenter);

  X := W * 0.815;
  Gauge(BGRA(40, 110, 215), B, X, BY - BH / 2 - R - 22, R, FLine.P2, 350, FLine.P2SP, 'P2');
  B.DrawLineAntialias(X, BY - BH / 2 - 22, X, BY - BH * 0.18, BGRA(110, 116, 132), 3);
  B.FontHeight := 10;
  B.TextOut(X, BY + BH * 0.3 + 4, Format('SP %.0f', [FLine.P2SP]), BGRA(40, 110, 215), taCenter);
  B.TextOut(X, BY + BH * 0.3 + 16, Format('visc %.2f', [FLine.MuEstimated]), BGRA(120, 80, 160), taCenter);

  // melt pump: two gears
  MX := W * 0.885;
  R := Max(10, BH * 0.45);
  B.FillRoundRectAntialias(MX - R * 1.3, BY - R * 2.2, MX + R * 1.3, BY + R * 2.2, 6, 6, BGRA(70, 76, 92));
  for J := 0 to 1 do
  begin
    Y := BY + (J * 2 - 1) * R * 0.95;
    B.FillEllipseAntialias(MX, Y, R, R, BGRA(170, 178, 195));
    for I := 0 to 7 do
    begin
      F := Ph * FLine.MeltPumpRpm / 10 * (1 - 2 * J) + I * Pi / 4;
      B.DrawLineAntialias(MX + R * 0.4 * Cos(F), Y + R * 0.4 * Sin(F), MX + R * 1.12 * Cos(F), Y + R * 1.12 * Sin(F),
        BGRA(120, 128, 145), 3);
    end;
  end;
  B.FontHeight := 11;
  B.FontStyle := [fsBold];
  B.TextOut(MX, BY + R * 2.2 + 4, 'Melt pump', BGRA(60, 65, 80), taCenter);
  B.FontStyle := [];
  B.FontHeight := 10;
  B.TextOut(MX, BY + R * 2.2 + 18, Format('%.0f rpm · %.0f kg/h', [FLine.MeltPumpRpm, FLine.Qmp]),
    BGRA(40, 110, 215), taCenter);
  if FLine.PumpLoad < 80 then C := BGRA(40, 160, 80)
  else if FLine.PumpLoad < 110 then C := BGRA(235, 140, 30) else C := BGRA(215, 50, 50);
  B.TextOut(MX, BY + R * 2.2 + 30, Format('motor %.0f %%', [FLine.PumpLoad]), C, taCenter);

  // die + strand
  MX := W * 0.955;
  B.FillPolyAntialias([PointF(MX - 10, BY - BH * 0.4), PointF(MX + 8, BY - BH * 0.15),
    PointF(MX + 8, BY + BH * 0.15), PointF(MX - 10, BY + BH * 0.4)], BGRA(80, 86, 100));
  if FLine.Qmp > 1 then
  begin
    SetLength(Pts, 8);
    for I := 0 to 7 do
      Pts[I] := PointF(MX + 8 + I * (W - MX - 10) / 7, BY + Sin(Ph * 3 + I) * 2 + I * I * 0.6);
    B.DrawPolyLineAntialias(Pts, Mix(C, TempColor(FLine.Tmelt), 0.5), Max(2, BH * 0.12));
  end;
  B.FontHeight := 10;
  B.TextOut(MX, BY + BH * 0.4 + 6, Format('melt %.0f °C', [FLine.Tmelt]), TempColor(FLine.Tmelt), taCenter);
  B.TextOut(MX, BY + BH * 0.4 + 18, Format('P3 %.0f bar', [FLine.P3]), BGRA(40, 160, 160), taCenter);
end;

{ ---------- history chart ---------- }

procedure TFormExtruder.RenderChart(Sender: TObject; B: TBGRABitmap);
var
  V: TBGRAView;
  Defs: array[0..9] of TSeriesDef;
  NS, I, J, K, N, Hi, TW: Integer;
  L, T, R, Bt, TEnd, TStart, W, LMax, RMax, X, Y, PX, PY: Single;
  S: TLineSample;
  Pts: ArrayOfTPointF;
  HasRight: Boolean;
  Ev: TLineEvent;
  C: TBGRAPixel;
  Txt: string;

  function XOf(ATime: Double): Single;
  begin
    Result := L + (ATime - TStart) / W * (R - L);
  end;

  function YOf(AVal: Double; ARight: Boolean): Single;
  begin
    if ARight then Result := Bt - AVal / RMax * (Bt - T)
    else Result := Bt - AVal / LMax * (Bt - T);
  end;

  function NiceMax(AV: Double): Double;
  var
    P: Double;
  begin
    if AV <= 0 then Exit(1);
    P := Power(10, Floor(Log10(AV)));
    if AV / P <= 1 then Result := P
    else if AV / P <= 1.5 then Result := 1.5 * P
    else if AV / P <= 2 then Result := 2 * P
    else if AV / P <= 2.5 then Result := 2.5 * P
    else if AV / P <= 3 then Result := 3 * P
    else if AV / P <= 4 then Result := 4 * P
    else if AV / P <= 5 then Result := 5 * P
    else if AV / P <= 6 then Result := 6 * P
    else if AV / P <= 8 then Result := 8 * P
    else Result := 10 * P;
  end;

begin
  V := TBGRAView(Sender);
  NS := GroupSeries(cbGroup.ItemIndex, Defs);
  L := 56;
  T := 38;
  R := V.Width - 56;
  Bt := V.Height - 30;
  if (R - L < 60) or (Bt - T < 40) then Exit;
  W := WindowSeconds;
  TEnd := Max(FLine.SimTime, W);
  TStart := TEnd - W;
  N := FLine.HistoryCount;
  K := 0;
  while (K < N - 1) and (FLine.Sample(K).T < TStart) do Inc(K);

  // scales
  LMax := 0;
  RMax := 0;
  HasRight := False;
  for J := 0 to NS - 1 do
  begin
    if Defs[J].Right then HasRight := True;
    for I := K to N - 1 do
    begin
      S := FLine.Sample(I);
      if Defs[J].Code = 10 then
        Y := Max(Max(S.SPz[0], S.SPz[1]), Max(Max(S.SPz[2], S.SPz[3]), S.SPz[4]))
      else
        Y := SeriesValue(S, Defs[J].Code);
      if Defs[J].Right then RMax := Max(RMax, Y) else LMax := Max(LMax, Y);
    end;
  end;
  LMax := NiceMax(LMax * 1.08);
  RMax := NiceMax(RMax * 1.08);

  // legend (click to hide / show)
  B.FontHeight := 12;
  B.FontStyle := [];
  X := L;
  FLegendCount := NS;
  for J := 0 to NS - 1 do
  begin
    TW := B.TextSize(Defs[J].Name).cx;
    FLegend[J] := Rect(Round(X) - 3, 6, Round(X + 22 + TW) + 3, 28);
    if FShow[J] then C := Defs[J].Color else C := BGRA(205, 208, 215);
    B.FillRoundRectAntialias(X, 14, X + 16, 20, 2, 2, C);
    if FShow[J] then B.TextOut(X + 21, 9, Defs[J].Name, BGRA(70, 75, 90))
    else B.TextOut(X + 21, 9, Defs[J].Name, BGRA(185, 188, 196));
    X := X + 22 + TW + 14;
  end;

  // grid
  B.FontHeight := 11;
  for I := 0 to 4 do
  begin
    Y := T + (Bt - T) * I / 4;
    B.DrawLineAntialias(L, Y, R, Y, BGRA(232, 235, 242), 1);
    B.TextOut(L - 6, Y - 7, FloatToStrF(LMax * (4 - I) / 4, ffGeneral, 4, 1), BGRA(120, 125, 140), taRightJustify);
    if HasRight then
      B.TextOut(R + 6, Y - 7, FloatToStrF(RMax * (4 - I) / 4, ffGeneral, 4, 1), BGRA(120, 125, 140));
  end;
  for I := 0 to 6 do
  begin
    X := L + (R - L) * I / 6;
    B.DrawLineAntialias(X, T, X, Bt, BGRA(240, 242, 247), 1);
    B.TextOut(X, Bt + 6, FmtTime(TStart + W * I / 6), BGRA(120, 125, 140), taCenter);
  end;
  B.RectangleAntialias(L, T, R, Bt, BGRA(210, 215, 225), 1);

  // events
  B.FontHeight := 10;
  for I := 0 to FLine.EventCount - 1 do
  begin
    Ev := FLine.Event(I);
    if (Ev.T < TStart) or (Ev.T > TEnd) then Continue;
    case Ev.Kind of
      leStart: C := BGRA(35, 160, 80);
      leStop, leTrip: C := BGRA(215, 50, 50);
      leMetalRejected: C := BGRA(220, 160, 30);
      leMetalPassed: C := BGRA(140, 80, 40);
      leScreenChanged: C := BGRA(0, 140, 155);
    else
      C := BGRA(120, 120, 130);
    end;
    X := XOf(Ev.T);
    B.DrawLineAntialias(X, T, X, Bt, BGRA(C.red, C.green, C.blue, 150), 1);
    B.FontStyle := [fsBold];
    TW := B.TextSize(Ev.Text).cx;
    PX := EnsureRange(X + 2, L + 2, R - TW - 8);
    PY := T + 4 + (I mod 3) * 16;
    B.FillRoundRectAntialias(PX, PY, PX + TW + 6, PY + 14, 3, 3, C);
    B.TextOut(PX + 3, PY, Ev.Text, BGRAWhite);
    B.FontStyle := [];
  end;

  // series
  if N > 1 then
    for J := 0 to NS - 1 do
    begin
      if not FShow[J] then Continue;
      if Defs[J].Code = 10 then
      begin
        // the 5 zone setpoints, thin
        for I := 0 to ZONES - 1 do
        begin
          SetLength(Pts, N - K);
          for Hi := K to N - 1 do
          begin
            S := FLine.Sample(Hi);
            Pts[Hi - K] := PointF(XOf(S.T), YOf(S.SPz[I], False));
          end;
          B.DrawPolyLineAntialias(Pts, BGRA(ZoneColors[I].red, ZoneColors[I].green, ZoneColors[I].blue, 110), 1);
        end;
        Continue;
      end;
      SetLength(Pts, N - K);
      for I := K to N - 1 do
      begin
        S := FLine.Sample(I);
        Pts[I - K] := PointF(XOf(S.T), YOf(SeriesValue(S, Defs[J].Code), Defs[J].Right));
      end;
      if Defs[J].Thin then B.DrawPolyLineAntialias(Pts, Defs[J].Color, 1.3)
      else B.DrawPolyLineAntialias(Pts, Defs[J].Color, 2.2);
    end;

  if N = 0 then
  begin
    B.FontHeight := 14;
    B.TextOut((L + R) / 2, (T + Bt) / 2 - 8, 'Heaters warm up first, then press Start line',
      BGRA(150, 155, 170), taCenter);
    Exit;
  end;

  // hover readout
  if (FHoverX >= L) and (FHoverX <= R) and (N > K) then
  begin
    Hi := K;
    for I := K to N - 1 do
      if Abs(XOf(FLine.Sample(I).T) - FHoverX) < Abs(XOf(FLine.Sample(Hi).T) - FHoverX) then Hi := I;
    S := FLine.Sample(Hi);
    PX := XOf(S.T);
    B.DrawLineAntialias(PX, T, PX, Bt, BGRA(120, 125, 140, 160), 1);
    Txt := FmtTime(S.T);
    for J := 0 to NS - 1 do
      if FShow[J] and (Defs[J].Code <> 10) then
        Txt := Txt + Format('   %s %.1f', [Defs[J].Name, SeriesValue(S, Defs[J].Code)]);
    B.FontHeight := 11;
    TW := B.TextSize(Txt).cx;
    PX := EnsureRange(PX + 10, L + 2, R - TW - 16);
    B.FillRoundRectAntialias(PX, Bt - 30, PX + TW + 14, Bt - 8, 5, 5, BGRA(35, 40, 55, 230));
    B.TextOut(PX + 7, Bt - 27, Txt, BGRAWhite);
  end;
end;

{ ---------- physics page ---------- }

procedure TFormExtruder.RenderPhysics(Sender: TObject; B: TBGRABitmap);
var
  V: TBGRAView;
  ColW, X, Y, Y2, MaxY: Single;
  TwoCols: Boolean;
  I, J: Integer;
  Pts: ArrayOfTPointF;
  PL, PT, PR, PB, T, Mu, MuMax: Double;
  C: TBGRAPixel;
  BackFlow: Double;

  procedure Card(var AY: Single; AX: Single; const ATitle: string; ALines: array of string; AColor: TBGRAPixel);
  var
    K: Integer;
    HH: Single;
  begin
    HH := 34 + Length(ALines) * 18;
    B.FillRoundRectAntialias(AX, AY, AX + ColW, AY + HH, 10, 10, BGRAWhite);
    B.FillRoundRectAntialias(AX, AY, AX + 6, AY + HH, 3, 3, AColor);
    B.RoundRectAntialias(AX, AY, AX + ColW, AY + HH, 10, 10, BGRA(220, 224, 232), 1);
    B.FontHeight := 14;
    B.FontStyle := [fsBold];
    B.TextOut(AX + 16, AY + 8, ATitle, BGRA(35, 40, 55));
    B.FontHeight := 12;
    B.FontStyle := [];
    for K := 0 to High(ALines) do
    begin
      if Copy(ALines[K], 1, 1) = '=' then
        B.TextOut(AX + 16, AY + 32 + K * 18, Copy(ALines[K], 2, MaxInt), BGRA(40, 110, 215))
      else if Copy(ALines[K], 1, 1) = '#' then
      begin
        // table rows: fixed-width font so the columns line up
        B.FontName := 'Consolas';
        B.TextOut(AX + 16, AY + 32 + K * 18, Copy(ALines[K], 2, MaxInt), BGRA(50, 55, 70));
        B.FontName := 'Segoe UI';
      end
      else
        B.TextOut(AX + 16, AY + 32 + K * 18, ALines[K], BGRA(70, 75, 90));
    end;
    AY := AY + HH + 12;
  end;

begin
  V := TBGRAView(Sender);
  B.FillRectAntialias(0, 0, V.Width, V.Height, BGRA(240, 243, 248));
  TwoCols := V.Width >= 1000;
  if TwoCols then ColW := (V.Width - 48) / 2 else ColW := V.Width - 32;
  B.FontName := 'Segoe UI';
  B.FontHeight := 18;
  B.FontStyle := [fsBold];
  B.TextOut(16, 12, 'Physics of the line - live values', BGRA(35, 40, 55));
  B.FontHeight := 12;
  B.FontStyle := [];
  B.TextOut(16, 38, 'Every value below is computed by the simulation right now; ' +
    'lines in blue are the equations with the current numbers filled in.', BGRA(110, 115, 130));

  X := 16;
  Y := 64;

  // 1. materials
  Card(Y, X, '1. Raw materials and blend', [
    Format('%-6s  Tm %3.0f °C   mu_ref %.1f @ %3.0f °C   B %.3f /°C   Tdeg %3.0f °C   bulk %.2f   weight %.0f %%',
      [FLine.Polymers[0].Name, FLine.Polymers[0].Tm, FLine.Polymers[0].MuRef, FLine.Polymers[0].TRef,
       FLine.Polymers[0].B, FLine.Polymers[0].Tdeg, FLine.Polymers[0].Bulk, FLine.Weight(0) * 100]),
    Format('%-6s  Tm %3.0f °C   mu_ref %.1f @ %3.0f °C   B %.3f /°C   Tdeg %3.0f °C   bulk %.2f   weight %.0f %%',
      [FLine.Polymers[1].Name, FLine.Polymers[1].Tm, FLine.Polymers[1].MuRef, FLine.Polymers[1].TRef,
       FLine.Polymers[1].B, FLine.Polymers[1].Tdeg, FLine.Polymers[1].Bulk, FLine.Weight(1) * 100]),
    Format('%-6s  Tm %3.0f °C   mu_ref %.1f @ %3.0f °C   B %.3f /°C   Tdeg %3.0f °C   bulk %.2f   weight %.0f %%',
      [FLine.Polymers[2].Name, FLine.Polymers[2].Tm, FLine.Polymers[2].MuRef, FLine.Polymers[2].TRef,
       FLine.Polymers[2].B, FLine.Polymers[2].Tdeg, FLine.Polymers[2].Bulk, FLine.Weight(2) * 100]),
    'Blend melts when the component with the highest Tm melts; degrades at the lowest Tdeg',
    Format('=Tm(blend) = %.0f °C    Tdeg(blend) = %.0f °C    bulk(blend) = %.3f kg/L',
      [FLine.BlendTm, FLine.BlendTdeg, FLine.BlendBulk])], BGRA(240, 170, 40));

  // 2. dosing + metal
  Card(Y, X, '2. Dosing screw and metal detector', [
    'Qd = Cd · Nd · bulk / 0.6          (0 for 3 s while metal is rejected)',
    Format('=Qd = %.1f · %.1f %% · %.3f / 0.6 = %.1f kg/h', [FLine.Cd, FLine.Nd, FLine.BlendBulk, FLine.Qd]),
    Format('feed-forward = Nmp · Cmp / (Cd · bulk / 0.6) = %.1f %%   (%s)',
      [FLine.DosingFFPct, BoolToStr(FLine.DosingFF, 'on', 'off')]),
    Format('metal detector %s · rejected %d · passed to the screen %d (each adds 0.35 to the screen dirt)',
      [BoolToStr(FLine.MetalDetector, 'ON', 'OFF'), FLine.MetalRejects, FLine.MetalPassed])], BGRA(60, 160, 90));

  // 3. extruder
  BackFlow := FLine.Bk * FLine.P2 / Max(FLine.Mu, 0.01);
  Card(Y, X, '3. Extruder (drag flow - pressure back flow) and screw fill', [
    'Qe = (Ce · Ne · F  -  Bk · P2 / mu) / (1 + Bk · Rs · (1 + S))',
    Format('=Qe = (%.1f · %.1f · %.2f  -  %.2f · %.1f / %.2f) / (1 + %.2f · %.2f · %.2f) = %.1f kg/h',
      [FLine.Ce, FLine.Ne, FLine.F, FLine.Bk, FLine.P2, FLine.Mu, FLine.Bk, FLine.Rs, 1 + FLine.S, FLine.Qe]),
    Format('drag flow %.1f kg/h   back flow %.1f kg/h', [FLine.Ce * FLine.Ne * FLine.F, BackFlow]),
    'dF/dt = (Qd - Qe) / (Minv · 3600)        F = 1 means the screw is flooded',
    Format('=dF/dt = (%.1f - %.1f) / (%.1f · 3600) = %.5f /s    F = %.3f',
      [FLine.Qd, FLine.Qe, FLine.Minv, (FLine.Qd - FLine.Qe) / (FLine.Minv * 3600), FLine.F])], BGRA(220, 80, 40));

  // 4. screen + pressures
  Card(Y, X, '4. Screen changer and the two pressure sensors', [
    'dPs = Rs · (1 + S) · mu · Qe          P1 = P2 + dPs',
    Format('=dPs = %.2f · %.2f · %.2f · %.1f = %.1f bar     P1 = %.1f + %.1f = %.1f bar',
      [FLine.Rs, 1 + FLine.S, FLine.Mu, FLine.Qe, FLine.DPScreen, FLine.P2, FLine.DPScreen, FLine.P1]),
    'viscosity seen by the sensors:  mu = (P1 - P2) / (Rs · (1 + S) · Qe)',
    Format('=mu(sensors) = %.1f / (%.2f · %.2f · %.1f) = %.3f', [FLine.DPScreen, FLine.Rs, 1 + FLine.S,
      FLine.Qe, FLine.MuEstimated]),
    Format('screen dirt S = %.2f   (unmelted material adds 0.004 · U · Qe/100 per s, metal adds 0.35)', [FLine.S])],
    BGRA(150, 90, 200));

  // 5. melt pump
  Card(Y, X, '5. Melt pump (fixed speed) and P2', [
    'Qmp = Cmp · Nmp          dP2/dt = Kc · (Qe - Qmp) / 3600',
    Format('=Qmp = %.1f · %.0f = %.1f kg/h     dP2/dt = %.0f · (%.1f - %.1f) / 3600 = %.2f bar/s',
      [FLine.Cmp, FLine.MeltPumpRpm, FLine.Qmp, FLine.Kc, FLine.Qe, FLine.Qmp, FLine.Kc * (FLine.Qe - FLine.Qmp) / 3600]),
    'a faster melt pump takes more melt out -> P2 falls unless the screws deliver more'], BGRA(40, 110, 215));
  MaxY := Y;

  // second column (or continue below)
  if TwoCols then
  begin
    X := 32 + ColW;
    Y := 64;
  end;

  // 6. viscosity plot
  Y2 := Y;
  B.FillRoundRectAntialias(X, Y, X + ColW, Y + 250, 10, 10, BGRAWhite);
  B.RoundRectAntialias(X, Y, X + ColW, Y + 250, 10, 10, BGRA(220, 224, 232), 1);
  B.FillRoundRectAntialias(X, Y, X + 6, Y + 250, 3, 3, BGRA(150, 90, 200));
  B.FontHeight := 14;
  B.FontStyle := [fsBold];
  B.TextOut(X + 16, Y + 8, '6. Viscosity vs temperature  mu_i(T) = mu_ref · exp(-B · (T - T_ref))', BGRA(35, 40, 55));
  PL := X + 50;
  PT := Y + 40;
  PR := X + ColW - 20;
  PB := Y + 220;
  MuMax := 6;
  B.FontHeight := 10;
  B.FontStyle := [];
  for I := 0 to 6 do
  begin
    T := 150 + I * 25;
    B.DrawLineAntialias(PL + (PR - PL) * I / 6, PT, PL + (PR - PL) * I / 6, PB, BGRA(238, 240, 245), 1);
    B.TextOut(PL + (PR - PL) * I / 6, PB + 4, Format('%.0f', [T]), BGRA(120, 125, 140), taCenter);
  end;
  for I := 0 to 3 do
  begin
    B.DrawLineAntialias(PL, PB - (PB - PT) * I / 3, PR, PB - (PB - PT) * I / 3, BGRA(238, 240, 245), 1);
    B.TextOut(PL - 6, PB - (PB - PT) * I / 3 - 6, Format('%.0f', [MuMax * I / 3]), BGRA(120, 125, 140), taRightJustify);
  end;
  for J := 0 to MATS do
  begin
    SetLength(Pts, 61);
    for I := 0 to 60 do
    begin
      T := 150 + I * 2.5;
      if J < MATS then Mu := FLine.PolymerMu(J, T) else Mu := FLine.BlendMu(T);
      Pts[I] := PointF(PL + (T - 150) / 150 * (PR - PL), PB - Min(Mu, MuMax) / MuMax * (PB - PT));
    end;
    if J < MATS then
    begin
      C := BGRA(FLine.Polymers[J].Color[0], FLine.Polymers[J].Color[1], FLine.Polymers[J].Color[2]);
      B.DrawPolyLineAntialias(Pts, C, 2);
      B.TextOut(PL + 8 + J * 70, PT + 2, FLine.Polymers[J].Name, Mix(C, BGRA(0, 0, 0), 0.3));
    end
    else
    begin
      B.DrawPolyLineAntialias(Pts, BGRA(35, 40, 55), 3);
      B.TextOut(PL + 8 + 3 * 70, PT + 2, 'blend', BGRA(35, 40, 55));
    end;
  end;
  // current operating point
  if (FLine.Tmelt > 150) and (FLine.Tmelt < 300) then
  begin
    X := PL + (FLine.Tmelt - 150) / 150 * (PR - PL);
    B.DrawLineAntialias(X, PT, X, PB, BGRA(220, 50, 50, 140), 1);
    B.FillEllipseAntialias(X, PB - Min(FLine.MuBase, MuMax) / MuMax * (PB - PT), 5, 5, BGRA(220, 50, 50));
    B.TextOut(X + 6, PB - Min(FLine.MuBase, MuMax) / MuMax * (PB - PT) - 18,
      Format('Tmelt %.0f °C  mu %.2f', [FLine.Tmelt, FLine.MuBase]), BGRA(220, 50, 50));
  end;
  B.TextOut(PR, PB + 16, '°C', BGRA(120, 125, 140), taRightJustify);
  if TwoCols then X := 32 + ColW else X := 16;
  Y := Y2 + 262;

  // 7. viscosity effects
  Card(Y, X, '7. Melt temperature, melting and degradation', [
    'Tmelt = 0.15 · T3 + 0.30 · T4 + 0.55 · T5 + 0.06 · Ne · sqrt(mu)      (shear heating)',
    Format('=Tmelt = 0.15·%.1f + 0.30·%.1f + 0.55·%.1f + 0.06·%.0f·%.2f = %.1f °C',
      [FLine.Tz[2], FLine.Tz[3], FLine.Tz[4], FLine.Ne, Sqrt(Max(FLine.Mu, 0.05)), FLine.Tmelt]),
    'unmelted U = clamp((Tm + 20 - Tmelt) / 20, 0, 1)      mu = mu_blend · (1 + 4 U²)  (· 0.8 if degrading)',
    Format('=U = %.2f    mu_blend = %.3f    mu = %.3f    degrading: %s',
      [FLine.Unmelt, FLine.MuBase, FLine.Mu, BoolToStr(FLine.Degrading, 'YES', 'no')]),
    'hotter zones -> lower viscosity -> lower P1 - P2 and more back flow in the screw'], BGRA(220, 110, 30));

  // 8. heater zones
  Card(Y, X, '8. Heater zones  Cz · dT/dt = Heat - Cool - Loss - Material + Shear', [
    Format('Cz %.0f J/K · heater %.0f W · fan %.0f W · loss %.0f W/K · material share %.2f · cp %.0f',
      [FLine.Cz, FLine.Pmax, FLine.Pcool, FLine.Lz, FLine.MatShare, FLine.Cp]),
    '#zone    T °C   out %    heat W   cool W   loss W  material W  shear W    dT/dt',
    Format('#  1    %6.1f   %6.1f   %7.0f   %7.0f   %7.0f   %8.0f   %7.0f   %s', [FLine.Tz[0], FLine.ZonePID[0].Output,
      FLine.HeatW[0], FLine.CoolW[0], FLine.LossW[0], FLine.MatW[0], FLine.ShearW[0],
      SignF((FLine.HeatW[0] - FLine.CoolW[0] - FLine.LossW[0] - FLine.MatW[0] + FLine.ShearW[0]) / FLine.Cz)]),
    Format('#  2    %6.1f   %6.1f   %7.0f   %7.0f   %7.0f   %8.0f   %7.0f   %s', [FLine.Tz[1], FLine.ZonePID[1].Output,
      FLine.HeatW[1], FLine.CoolW[1], FLine.LossW[1], FLine.MatW[1], FLine.ShearW[1],
      SignF((FLine.HeatW[1] - FLine.CoolW[1] - FLine.LossW[1] - FLine.MatW[1] + FLine.ShearW[1]) / FLine.Cz)]),
    Format('#  3    %6.1f   %6.1f   %7.0f   %7.0f   %7.0f   %8.0f   %7.0f   %s', [FLine.Tz[2], FLine.ZonePID[2].Output,
      FLine.HeatW[2], FLine.CoolW[2], FLine.LossW[2], FLine.MatW[2], FLine.ShearW[2],
      SignF((FLine.HeatW[2] - FLine.CoolW[2] - FLine.LossW[2] - FLine.MatW[2] + FLine.ShearW[2]) / FLine.Cz)]),
    Format('#  4    %6.1f   %6.1f   %7.0f   %7.0f   %7.0f   %8.0f   %7.0f   %s', [FLine.Tz[3], FLine.ZonePID[3].Output,
      FLine.HeatW[3], FLine.CoolW[3], FLine.LossW[3], FLine.MatW[3], FLine.ShearW[3],
      SignF((FLine.HeatW[3] - FLine.CoolW[3] - FLine.LossW[3] - FLine.MatW[3] + FLine.ShearW[3]) / FLine.Cz)]),
    Format('#  5    %6.1f   %6.1f   %7.0f   %7.0f   %7.0f   %8.0f   %7.0f   %s', [FLine.Tz[4], FLine.ZonePID[4].Output,
      FLine.HeatW[4], FLine.CoolW[4], FLine.LossW[4], FLine.MatW[4], FLine.ShearW[4],
      SignF((FLine.HeatW[4] - FLine.CoolW[4] - FLine.LossW[4] - FLine.MatW[4] + FLine.ShearW[4]) / FLine.Cz)]),
    'shear = Ksh · Ne · sqrt(mu): the screw itself heats the last zones -> their PID may need the fan'],
    BGRA(220, 50, 40));

  // 9. PID
  Card(Y, X, '9. PID controllers  u = Kp·e + Ki·∫e dt - Kd·dPV/dt   (e = SP - PV)', [
    'derivative on the measurement, conditional integration (anti-windup), bumpless manual/auto',
    Format('=Extruder: e = %.1f - %.1f   P %.2f   I %.2f   D %.2f   -> %.1f rpm (%s)',
      [FLine.P2SP, FLine.P2, FLine.ExtruderPID.LastP, FLine.ExtruderPID.Integ, FLine.ExtruderPID.LastD,
       FLine.ExtruderPID.Output, BoolToStr(FLine.ExtruderPID.Auto, 'auto', 'manual')]),
    Format('=Dosing:   e = %.1f - %.1f   P %.2f   I %.2f   D %.2f   -> trim %.1f %% + FF %.1f %% (%s)',
      [FLine.P2SP, FLine.P2, FLine.DosingPID.LastP, FLine.DosingPID.Integ, FLine.DosingPID.LastD,
       FLine.DosingPID.Output, FLine.DosingFFPct, BoolToStr(FLine.DosingPID.Auto, 'auto', 'manual')]),
    Format('=Zone 1:   e = %.1f - %.1f   P %.1f   I %.1f   D %.1f   -> %.1f %%',
      [FLine.ZoneSP[0], FLine.Tz[0], FLine.ZonePID[0].LastP, FLine.ZonePID[0].Integ, FLine.ZonePID[0].LastD,
       FLine.ZonePID[0].Output]),
    'interlocks: cold-start (any zone < SP - 15 °C blocks the screws), P1 > 350 bar trips the line'],
    BGRA(40, 160, 160));

  // 10. motors
  Card(Y, X, '10. Motor loads  (load = torque / rated torque)', [
    'Extruder: P = shear · (0.4 + 0.6 F) + pressure work + friction      load = (P / N) / (Prated / Nrated)',
    Format('=P = %.0f W + %.0f W + %.0f W = %.1f kW      load = (%.0f / %.1f) / (%.0f / %.0f) = %.0f %%',
      [FLine.ShearTotalW, FLine.PressureWorkW, FLine.FrictionW * FLine.Ne, FLine.MotorPowerW / 1000,
       FLine.MotorPowerW, Max(FLine.Ne, 0.1), FLine.MotorRatedW, FLine.MotorRatedRpm, FLine.ExtLoad]),
    Format('pressure work = Qe / 3600 / rho · P1 = %.1f / 3600 / %.0f · %.1f bar = %.0f W',
      [FLine.Qe, FLine.Density, FLine.P1, FLine.PressureWorkW]),
    'higher viscosity (cold zones, PS, unmelted) -> more shear -> more torque; > 110 % warning, > 130 % for 5 s trips',
    'Melt pump: P3 (die) = Rdie · mu · Qmp      load = 10 + 0.3 · (P3 - P2)',
    Format('=P3 = %.1f · %.2f · %.1f = %.0f bar      load = 10 + 0.3 · (%.0f - %.0f) = %.0f %%',
      [FLine.Rdie, FLine.Mu, FLine.Qmp, FLine.P3, FLine.P3, FLine.P2, FLine.PumpLoad]),
    Format('=Dosing: load = 12 + 0.55 · Nd · bulk / 0.6 = 12 + 0.55 · %.1f · %.3f / 0.6 = %.0f %%',
      [FLine.Nd, FLine.BlendBulk, FLine.DoseLoad])],
    BGRA(235, 140, 30));

  MaxY := Max(MaxY, Y);
  // grow the scroll area to the content
  if Abs(V.Height - (MaxY + 20)) > 4 then V.Height := Round(MaxY + 20);
end;

end.
