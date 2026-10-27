unit HeaterMain;

{ Heater Simulator - main window
  Left: commands (Start/Stop, setpoint, Auto/Manual, PID, plant, history)
  Right: header chips, gauge and history chart, all drawn with BGRABitmap.
  The layout adapts to the window size (gauge beside or above the chart). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Spin, IniFiles, Math, BGRABitmap, BGRABitmapTypes, BGRAView, HeaterModel;

type

  { TFormHeater }

  TFormHeater = class(TForm)
    btnApplyPID: TButton;
    btnApplySP: TButton;
    btnClear: TButton;
    btnExport: TButton;
    btnResetI: TButton;
    btnStart: TButton;
    btnStop: TButton;
    cbSpeed: TComboBox;
    cbWindow: TComboBox;
    gbHistory: TGroupBox;
    gbMode: TGroupBox;
    gbPID: TGroupBox;
    gbPlant: TGroupBox;
    gbRun: TGroupBox;
    gbSP: TGroupBox;
    lblScenario: TLabel;
    btnNewScenario: TButton;
    chkReveal: TCheckBox;
    lblKd: TLabel;
    lblKi: TLabel;
    lblKp: TLabel;
    lblManual: TLabel;
    lblSpeed: TLabel;
    lblSP: TLabel;
    lblWindow: TLabel;
    pnlRight: TPanel;
    rbAuto: TRadioButton;
    rbManual: TRadioButton;
    sbLeft: TScrollBox;
    seKd: TFloatSpinEdit;
    seKi: TFloatSpinEdit;
    seKp: TFloatSpinEdit;
    seSP: TFloatSpinEdit;
    tbManual: TTrackBar;
    tmrSim: TTimer;
    dlgSave: TSaveDialog;
    procedure btnApplyPIDClick(Sender: TObject);
    procedure btnApplySPClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure btnExportClick(Sender: TObject);
    procedure btnResetIClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure pnlRightResize(Sender: TObject);
    procedure rbModeChange(Sender: TObject);
    procedure btnNewScenarioClick(Sender: TObject);
    procedure chkRevealChange(Sender: TObject);
    procedure tbManualChange(Sender: TObject);
    procedure tmrSimTimer(Sender: TObject);
  private
    FHeater: THeater;
    FHeader, FGauge, FVessel, FChart: TBGRAView;
    FStrip: TPanel;
    FHoverX: Integer;
    FLoading: Boolean;
    // chart series visibility (click the legend): 0 actual, 1 setpoint, 2 output, 3 events, 4 start/stop/gain
    FShow: array[0..4] of Boolean;
    FLegend: array[0..4] of TRect;
    procedure RenderHeader(Sender: TObject; B: TBGRABitmap);
    procedure RenderGauge(Sender: TObject; B: TBGRABitmap);
    procedure RenderVessel(Sender: TObject; B: TBGRABitmap);
    procedure RenderChart(Sender: TObject; B: TBGRABitmap);
    procedure ChartMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ChartMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ChartMouseLeave(Sender: TObject);
    function WindowSeconds: Double;
    function SpeedFactor: Double;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure UpdateControls;
    procedure ShowScenario;
  public
  end;

var
  FormHeater: TFormHeater;

implementation

{$R *.lfm}

const
  C_PV:  TBGRAPixel = (blue: 40; green: 90; red: 230; alpha: 255);
  C_SP:  TBGRAPixel = (blue: 220; green: 110; red: 40; alpha: 255);
  C_OUT: TBGRAPixel = (blue: 110; green: 175; red: 60; alpha: 255);

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

{ arc helper: angles in degrees, 0 = right, counter-clockwise positive (screen y down) }
function ArcPoints(CX, CY, R, A1, A2: Single): ArrayOfTPointF;
var
  N, I: Integer;
  A: Single;
begin
  N := Max(2, Round(Abs(A2 - A1) / 3));
  SetLength(Result, N + 1);
  for I := 0 to N do
  begin
    A := DegToRad(A1 + (A2 - A1) * I / N);
    Result[I] := PointF(CX + R * Cos(A), CY - R * Sin(A));
  end;
end;

{ TFormHeater }

procedure TFormHeater.FormCreate(Sender: TObject);
var
  I: Integer;
begin
  FHeater := THeater.Create(3600);
  // --seed=N replays a scenario (e.g. one shared by a friend)
  for I := 1 to ParamCount do
    if Pos('--seed=', ParamStr(I)) = 1 then
      FHeater.NewScenario(StrToIntDef(Copy(ParamStr(I), 8, 12), 0));
  FHoverX := -1;

  for I := 0 to High(FShow) do FShow[I] := True;

  FHeader := TBGRAView.Create(Self);
  FHeader.Parent := pnlRight;
  FHeader.Align := alTop;
  FHeader.Height := 56;
  FHeader.OnRender := @RenderHeader;

  // top strip: gauge on the left, the pot on the heater on the right
  FStrip := TPanel.Create(Self);
  FStrip.Parent := pnlRight;
  FStrip.Align := alTop;
  FStrip.Top := FHeader.Height;
  FStrip.BevelOuter := bvNone;

  FGauge := TBGRAView.Create(Self);
  FGauge.Parent := FStrip;
  FGauge.Align := alLeft;
  FGauge.OnRender := @RenderGauge;

  FVessel := TBGRAView.Create(Self);
  FVessel.Parent := FStrip;
  FVessel.Align := alClient;
  FVessel.OnRender := @RenderVessel;

  FChart := TBGRAView.Create(Self);
  FChart.Parent := pnlRight;
  FChart.Align := alClient;
  FChart.OnRender := @RenderChart;
  FChart.OnMouseMove := @ChartMouseMove;
  FChart.OnMouseDown := @ChartMouseDown;
  FChart.OnMouseLeave := @ChartMouseLeave;
  FChart.Background := BGRAWhite;

  LoadSettings;
  pnlRightResize(nil);
  UpdateControls;
  ShowScenario; // a random scenario was already created with the heater model
end;

procedure TFormHeater.FormDestroy(Sender: TObject);
begin
  tmrSim.Enabled := False;
  SaveSettings;
  FHeater.Free;
end;

{ ---------- settings ---------- }

procedure TFormHeater.LoadSettings;
var
  Ini: TIniFile;
begin
  FLoading := True;
  Ini := TIniFile.Create(IniName);
  try
    FHeater.SP := Ini.ReadFloat('Heater', 'Setpoint', FHeater.SP);
    FHeater.Kp := Ini.ReadFloat('PID', 'Kp', FHeater.Kp);
    FHeater.Ki := Ini.ReadFloat('PID', 'Ki', FHeater.Ki);
    FHeater.Kd := Ini.ReadFloat('PID', 'Kd', FHeater.Kd);
    FHeater.Manual := Ini.ReadFloat('Heater', 'Manual', FHeater.Manual);
    chkReveal.Checked := Ini.ReadBool('View', 'RevealPlant', False);
    cbSpeed.ItemIndex := Ini.ReadInteger('View', 'Speed', 2);
    cbWindow.ItemIndex := Ini.ReadInteger('View', 'Window', 1);
  finally
    Ini.Free;
  end;
  seSP.Value := FHeater.SP;
  seKp.Value := FHeater.Kp;
  seKi.Value := FHeater.Ki;
  seKd.Value := FHeater.Kd;
  tbManual.Position := Round(FHeater.Manual);
  FLoading := False;
end;

procedure TFormHeater.SaveSettings;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(IniName);
    try
      Ini.WriteFloat('Heater', 'Setpoint', FHeater.SP);
      Ini.WriteFloat('Heater', 'Manual', FHeater.Manual);
      Ini.WriteFloat('PID', 'Kp', FHeater.Kp);
      Ini.WriteFloat('PID', 'Ki', FHeater.Ki);
      Ini.WriteFloat('PID', 'Kd', FHeater.Kd);
      Ini.WriteBool('View', 'RevealPlant', chkReveal.Checked);
      Ini.WriteInteger('View', 'Speed', cbSpeed.ItemIndex);
      Ini.WriteInteger('View', 'Window', cbWindow.ItemIndex);
    finally
      Ini.Free;
    end;
  except
    // settings are only a convenience
  end;
end;

{ ---------- commands ---------- }

procedure TFormHeater.btnStartClick(Sender: TObject);
begin
  FHeater.Start;
  UpdateControls;
end;

procedure TFormHeater.btnStopClick(Sender: TObject);
begin
  FHeater.Stop;
  UpdateControls;
end;

procedure TFormHeater.btnApplySPClick(Sender: TObject);
begin
  FHeater.SetSetpoint(seSP.Value); // a new step to be scored
end;

procedure TFormHeater.btnNewScenarioClick(Sender: TObject);
begin
  // new mystery plant on the fly: temperature, material, chart and Start/Stop continue,
  // only the plant behaviour changes (marked on the chart); the PID gains stay as they are
  FHeater.ChangeScenario;
  ShowScenario;
  FChart.Invalidate;
end;

procedure TFormHeater.chkRevealChange(Sender: TObject);
begin
  ShowScenario;
  FGauge.Invalidate;
end;

procedure TFormHeater.ShowScenario;
var
  Stars: string;
  I: Integer;
begin
  Stars := '';
  for I := 1 to 5 do
    if I <= FHeater.Stars then Stars := Stars + '★' else Stars := Stars + '☆';
  lblScenario.Caption := Format('%s  #%d%sDifficulty %s',
    [FHeater.ScenarioName, FHeater.ScenarioSeed, LineEnding, Stars]);
  lblScenario.Hint := FHeater.PlantText;
  lblScenario.ShowHint := chkReveal.Checked;
end;

procedure TFormHeater.btnApplyPIDClick(Sender: TObject);
begin
  FHeater.SetGains(seKp.Value, seKi.Value, seKd.Value); // also marks the change on the chart
end;

procedure TFormHeater.btnResetIClick(Sender: TObject);
begin
  FHeater.ResetPID;
end;

procedure TFormHeater.rbModeChange(Sender: TObject);
begin
  if FLoading then Exit;
  FHeater.Auto := rbAuto.Checked;
  if not FHeater.Auto then
  begin
    // start manual mode from the current output (bumpless)
    FHeater.Manual := FHeater.OUT;
    tbManual.Position := Round(FHeater.OUT);
  end;
  UpdateControls;
end;

procedure TFormHeater.tbManualChange(Sender: TObject);
begin
  if FLoading then Exit;
  FHeater.Manual := tbManual.Position;
  lblManual.Caption := Format('Manual output: %d %%', [tbManual.Position]);
end;

procedure TFormHeater.btnClearClick(Sender: TObject);
begin
  FHeater.ClearHistory;
  FChart.Invalidate;
end;

procedure TFormHeater.btnExportClick(Sender: TObject);
var
  SL: TStringList;
  I: Integer;
  S: TSample;
  FS: TFormatSettings;
begin
  dlgSave.FileName := 'heater-history.csv';
  if not dlgSave.Execute then Exit;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  SL := TStringList.Create;
  try
    SL.Add('time_s,time,pv_degC,sp_degC,output_pct');
    for I := 0 to FHeater.HistoryCount - 1 do
    begin
      S := FHeater.Sample(I);
      SL.Add(Format('%.0f,%s,%.2f,%.2f,%.2f', [S.T, FmtTime(S.T), S.PV, S.SP, S.OUT], FS));
    end;
    SL.SaveToFile(dlgSave.FileName);
  finally
    SL.Free;
  end;
end;

procedure TFormHeater.UpdateControls;
begin
  btnStart.Enabled := not FHeater.Running;
  btnStop.Enabled := FHeater.Running;
  tbManual.Enabled := not FHeater.Auto;
  lblManual.Enabled := not FHeater.Auto;
  lblManual.Caption := Format('Manual output: %d %%', [tbManual.Position]);
end;

function TFormHeater.SpeedFactor: Double;
const
  Speeds: array[0..4] of Double = (1, 2, 5, 10, 30);
begin
  if (cbSpeed.ItemIndex >= 0) and (cbSpeed.ItemIndex <= High(Speeds)) then
    Result := Speeds[cbSpeed.ItemIndex]
  else
    Result := 1;
end;

function TFormHeater.WindowSeconds: Double;
const
  Mins: array[0..4] of Integer = (1, 5, 10, 30, 60);
begin
  if (cbWindow.ItemIndex >= 0) and (cbWindow.ItemIndex <= High(Mins)) then
    Result := Mins[cbWindow.ItemIndex] * 60
  else
    Result := 300;
end;

procedure TFormHeater.tmrSimTimer(Sender: TObject);
begin
  FHeater.Step(tmrSim.Interval / 1000 * SpeedFactor);
  FHeader.Invalidate;
  FGauge.Invalidate;
  FVessel.Invalidate;
  FChart.Invalidate;
end;

{ ---------- responsive layout ---------- }

procedure TFormHeater.pnlRightResize(Sender: TObject);
begin
  if FStrip = nil then Exit;
  // gauge + pot strip on top, chart takes the rest
  FStrip.Height := EnsureRange(Round(pnlRight.Height * 0.4), 190, 280);
  FGauge.Width := EnsureRange(Round(pnlRight.Width * 0.45), 280, 480);
end;

{ ---------- drawing ---------- }

procedure Chip(B: TBGRABitmap; var X: Single; Y: Single; const AText: string; C: TBGRAPixel);
var
  W: Integer;
begin
  B.FontHeight := 13;
  B.FontStyle := [fsBold];
  W := B.TextSize(AText).cx;
  B.FillRoundRectAntialias(X, Y, X + W + 22, Y + 26, 13, 13, C);
  B.TextOut(X + 11, Y + 4, AText, BGRAWhite);
  X := X + W + 30;
end;

procedure TFormHeater.RenderHeader(Sender: TObject; B: TBGRABitmap);
var
  X: Single;
  H: TBGRAView;
begin
  H := TBGRAView(Sender);
  B.GradientFill(0, 0, H.Width, H.Height, BGRA(32, 40, 62), BGRA(48, 62, 96),
    gtLinear, PointF(0, 0), PointF(H.Width, 0), dmSet);
  B.FontHeight := 20;
  B.FontStyle := [fsBold];
  B.TextOut(18, 6, 'Heater Control Simulator', BGRAWhite);
  B.FontHeight := 12;
  B.FontStyle := [];
  B.TextOut(20, 34, Format('%s #%d  ·  %s  ·  difficulty %d/5  ·  time %s  ·  x%g',
    [FHeater.ScenarioName, FHeater.ScenarioSeed, FHeater.Material.Name, FHeater.Stars,
     FmtTime(FHeater.SimTime), SpeedFactor]), BGRA(180, 195, 225));

  X := Max(300, H.Width - 470);
  if FHeater.Running then Chip(B, X, 15, 'RUNNING', BGRA(35, 160, 80))
  else Chip(B, X, 15, 'STOPPED', BGRA(110, 115, 130));
  if FHeater.Auto then Chip(B, X, 15, 'AUTO (PID)', BGRA(40, 120, 215))
  else Chip(B, X, 15, 'MANUAL', BGRA(150, 100, 200));
  if FHeater.ActiveEventName <> '' then
    Chip(B, X, 15, UpperCase(FHeater.ActiveEventName), BGRA(235, 130, 20));
  if FHeater.Alarm then Chip(B, X, 15, 'OVER TEMP', BGRA(215, 50, 50));
end;

procedure TFormHeater.RenderGauge(Sender: TObject; B: TBGRABitmap);
const
  GMin = 0;
  GMax = 300;
  A0 = 225;   // start angle (bottom-left)
  A1 = -45;   // end angle (bottom-right)
var
  G: TBGRAView;
  CX, CY, R, Th, Frac, A, BarY, BarW, InfoX, Y: Single;
  C: TBGRAPixel;
  I, Sc: Integer;
  S: string;
  Parts: TStringArray;
  Horizontal: Boolean;
begin
  G := TBGRAView(Sender);
  B.FillRectAntialias(0, 0, G.Width, G.Height, BGRA(246, 248, 252));
  // card
  B.FillRoundRectAntialias(10, 10, G.Width - 10, G.Height - 10, 14, 14, BGRAWhite);
  B.RoundRectAntialias(10, 10, G.Width - 10, G.Height - 10, 14, 14, BGRA(220, 225, 235), 1);

  // wide and low card (narrow window): dial on the left, details on the right
  Horizontal := G.Width > G.Height * 1.5;
  if Horizontal then
  begin
    R := Max(40, (G.Height - 70) / 2);
    Th := Max(10, R * 0.16);
    CX := 30 + R + Th;
    CY := 24 + R + Th;
  end
  else
  begin
    R := Max(40, Min(G.Width - 60, G.Height - 120) / 2);
    Th := Max(10, R * 0.16);
    CX := G.Width / 2;
    CY := 30 + R + Th;
  end;

  // background arc + ticks
  B.LineCap := pecRound;
  B.DrawPolyLineAntialias(ArcPoints(CX, CY, R, A0, A1), BGRA(230, 233, 240), Th);
  B.FontHeight := Max(10, Round(R * 0.11));
  B.FontStyle := [];
  for I := 0 to 6 do
  begin
    A := DegToRad(A0 + (A1 - A0) * I / 6);
    B.DrawLineAntialias(CX + (R - Th) * Cos(A), CY - (R - Th) * Sin(A),
      CX + (R - Th - 6) * Cos(A), CY - (R - Th - 6) * Sin(A), BGRA(160, 165, 180), 1.5);
    if R >= 80 then // labels only when the dial is big enough to keep them readable
    begin
      S := IntToStr(GMin + (GMax - GMin) * I div 6);
      B.TextOut(CX + (R - Th - 20) * Cos(A), CY - (R - Th - 20) * Sin(A) - B.FontHeight / 2,
        S, BGRA(130, 135, 150), taCenter);
    end;
  end;

  // value arc: colour from blue (cold) to red (hot)
  Frac := EnsureRange((FHeater.PV - GMin) / (GMax - GMin), 0, 1);
  C := BGRA(Round(40 + 200 * Frac), Round(150 - 80 * Frac), Round(230 - 200 * Frac));
  if Frac > 0.002 then
    B.DrawPolyLineAntialias(ArcPoints(CX, CY, R, A0, A0 + (A1 - A0) * Frac), C, Th);

  // setpoint marker
  Frac := EnsureRange((FHeater.SP - GMin) / (GMax - GMin), 0, 1);
  A := DegToRad(A0 + (A1 - A0) * Frac);
  B.FillPolyAntialias([
    PointF(CX + (R + Th / 2 + 2) * Cos(A), CY - (R + Th / 2 + 2) * Sin(A)),
    PointF(CX + (R + Th / 2 + 14) * Cos(A + 0.07), CY - (R + Th / 2 + 14) * Sin(A + 0.07)),
    PointF(CX + (R + Th / 2 + 14) * Cos(A - 0.07), CY - (R + Th / 2 + 14) * Sin(A - 0.07))], C_SP);

  // value text
  B.FontHeight := Max(18, Round(R * 0.38));
  B.FontStyle := [fsBold];
  B.TextOut(CX, CY - B.FontHeight * 0.75, Format('%.1f', [FHeater.PV]), BGRA(30, 35, 50), taCenter);
  B.FontHeight := Max(11, Round(R * 0.13));
  B.FontStyle := [];
  B.TextOut(CX, CY + R * 0.18, 'actual  °C', BGRA(120, 125, 140), taCenter);
  if FHeater.Error >= 0 then S := '+' else S := '';
  S := Format('setpoint %.1f °C   ·   error %s%.1f', [FHeater.SP, S, FHeater.Error]);

  if Horizontal then
  begin
    // details to the right of the dial
    InfoX := CX + R + Th + 30;
    BarW := G.Width - InfoX - 34;
    BarY := 34;
    B.FontHeight := 14;
    B.TextOut(InfoX, BarY, S, C_SP);
    BarY := BarY + 34;
  end
  else
  begin
    // below the ends of the arc, so it never overlaps the 0 / 300 labels
    B.TextOut(CX, CY + R * 0.78 + 4, S, C_SP, taCenter);
    InfoX := 40;
    BarW := G.Width - 80;
    BarY := CY + R * 0.78 + 4 + B.FontHeight + 14;
  end;

  // output bar + PID values
  if (BarW > 60) and (BarY + 40 < G.Height - 14) then
  begin
    B.FontHeight := 12;
    B.FontStyle := [fsBold];
    B.TextOut(InfoX, BarY, Format('Output  %.1f %%', [FHeater.OUT]), BGRA(70, 75, 90));
    B.FillRoundRectAntialias(InfoX, BarY + 20, InfoX + BarW, BarY + 34, 7, 7, BGRA(230, 233, 240));
    if FHeater.OUT > 0.5 then
      B.FillRoundRectAntialias(InfoX, BarY + 20, InfoX + BarW * FHeater.OUT / 100, BarY + 34, 7, 7, C_OUT);
    if BarY + 62 < G.Height - 14 then
    begin
      B.FontStyle := [];
      B.TextOut(InfoX, BarY + 42, Format('Kp %.2f   Ki %.3f   Kd %.2f', [FHeater.Kp, FHeater.Ki, FHeater.Kd]),
        BGRA(120, 125, 140));
    end;

    // tuning score of the last setpoint step
    Y := BarY + 70;
    if Y + 40 < G.Height - 14 then
    begin
      Sc := FHeater.Score;
      if Sc >= 90 then C := BGRA(35, 160, 80)
      else if Sc >= 75 then C := BGRA(40, 120, 215)
      else if Sc >= 55 then C := BGRA(220, 140, 20)
      else if Sc >= 0 then C := BGRA(215, 50, 50)
      else C := BGRA(130, 135, 150);
      B.FontHeight := 16;
      B.FontStyle := [fsBold];
      S := FHeater.ScoreText;
      if S = '' then S := '-';
      B.TextOut(InfoX, Y, 'Score  ' + S, C);
      B.FontHeight := 12;
      B.FontStyle := [];
      B.TextOut(InfoX, Y + 22, FHeater.ScoreDetail, BGRA(120, 125, 140));
      Y := Y + 46;
    end;

    // the hidden plant, only when the user asks for it
    if chkReveal.Checked then
    begin
      Parts := FHeater.PlantText.Split([' · ']);
      B.FontHeight := 11;
      I := 0;
      while (I <= High(Parts)) and (Y + 14 < G.Height - 14) do
      begin
        S := Parts[I];
        if I + 1 <= High(Parts) then S := S + '  ·  ' + Parts[I + 1];
        B.TextOut(InfoX, Y, S, BGRA(150, 100, 200));
        Y := Y + 16;
        Inc(I, 2);
      end;
    end;
  end;
end;

function Mix(A, B: TBGRAPixel; F: Double): TBGRAPixel;
begin
  F := EnsureRange(F, 0, 1);
  Result := BGRA(Round(A.red + (B.red - A.red) * F), Round(A.green + (B.green - A.green) * F),
    Round(A.blue + (B.blue - A.blue) * F), Round(A.alpha + (B.alpha - A.alpha) * F));
end;

{ The pot with the material, standing on the heating element }
procedure TFormHeater.RenderVessel(Sender: TObject; B: TBGRABitmap);
var
  V: TBGRAView;
  W, H, PW, PH, PX, PY, PB, Inset, CTop, CBot, LTop, Y, X, R, F, Phase, Glow: Single;
  Mat: TMaterial;
  SolidC, LiquidC, CoilC, C: TBGRAPixel;
  Pts: ArrayOfTPointF;
  I, J, NChunks, NBubbles: Integer;
  St: TMaterialState;

  { x of the inner wall at height Y (the pot is a trapezoid) }
  function WallL(AY: Single): Single;
  begin
    Result := PX + Inset + (AY - PY) / (PB - PY) * PW * 0.06;
  end;

  function WallR(AY: Single): Single;
  begin
    Result := PX + PW - Inset - (AY - PY) / (PB - PY) * PW * 0.06;
  end;

begin
  V := TBGRAView(Sender);
  W := V.Width;
  H := V.Height;
  B.FillRectAntialias(0, 0, W, H, BGRA(246, 248, 252));
  B.FillRoundRectAntialias(4, 10, W - 10, H - 10, 14, 14, BGRA(30, 34, 46));
  if (W < 160) or (H < 140) then Exit;

  Mat := FHeater.Material;
  St := FHeater.MaterialState;
  Phase := GetTickCount64 / 1000;
  SolidC := BGRA(Mat.Solid[0], Mat.Solid[1], Mat.Solid[2]);
  LiquidC := BGRA(Mat.Liquid[0], Mat.Liquid[1], Mat.Liquid[2]);
  // very hot liquids glow orange
  LiquidC := Mix(LiquidC, BGRA(255, 150, 60), (FHeater.PV - 180) / 200);

  // texts
  B.FontHeight := 14;
  B.FontStyle := [fsBold];
  B.TextOut(20, 20, Mat.Name, BGRAWhite);
  B.FontHeight := 12;
  B.FontStyle := [];
  case St of
    msSolid: C := BGRA(170, 180, 200);
    msMelting: C := BGRA(255, 190, 80);
    msBoiling: C := BGRA(120, 200, 255);
  else
    C := BGRA(140, 220, 160);
  end;
  B.TextOut(20, 40, FHeater.MaterialStateText, C);

  // geometry: texts on top, pot in the middle, coil + label at the bottom
  PB := H - 74;
  PH := Max(40, (PB - 66) * 0.85);
  PY := PB - PH;
  PW := Min(W * 0.6, PH * 1.8);
  PX := (W - PW) / 2;
  Inset := 6;

  // heating element (coil) under the pot, glowing with the element temperature
  Glow := FHeater.ElementGlow;
  if Glow < 0.5 then CoilC := Mix(BGRA(80, 80, 88), BGRA(230, 60, 20), Glow * 2)
  else CoilC := Mix(BGRA(230, 60, 20), BGRA(255, 210, 90), (Glow - 0.5) * 2);
  SetLength(Pts, 13);
  for I := 0 to 12 do
    Pts[I] := PointF(PX + PW * 0.08 + PW * 0.84 * I / 12, PB + 14 + IfThen(Odd(I), 10, 0));
  if Glow > 0.05 then
    B.DrawPolyLineAntialias(Pts, BGRA(255, 120, 30, Round(90 * Glow)), 12);
  B.LineCap := pecRound;
  B.DrawPolyLineAntialias(Pts, CoilC, 4);
  // base plate
  B.FillRoundRectAntialias(PX - 10, PB + 30, PX + PW + 10, PB + 40, 4, 4, BGRA(70, 75, 90));
  B.FontHeight := 11;
  B.TextOut(W / 2, PB + 44, Format('heater element %.0f %%', [Glow * 100]), CoilC, taCenter);

  // pot body (steel)
  B.FillPolyAntialias([PointF(PX, PY), PointF(PX + PW, PY), PointF(PX + PW * 0.94, PB),
    PointF(PX + PW * 0.06, PB)], BGRA(120, 128, 145));
  B.FillPolyAntialias([PointF(PX + Inset, PY), PointF(PX + PW - Inset, PY),
    PointF(PX + PW * 0.94 - Inset, PB - Inset), PointF(PX + PW * 0.06 + Inset, PB - Inset)], BGRA(22, 25, 34));

  // contents: 70 % of the pot
  CBot := PB - Inset;
  CTop := PY + PH * 0.3;

  // liquid part (bottom), height grows with the molten fraction
  if FHeater.MeltFrac > 0 then
  begin
    LTop := CBot - (CBot - CTop) * FHeater.MeltFrac;
    SetLength(Pts, 0);
    for I := 0 to 24 do
    begin
      X := WallL(LTop) + (WallR(LTop) - WallL(LTop)) * I / 24;
      Y := LTop + Sin(Phase * (2 + FHeater.BoilPower * 6) + I * 0.7) * (1 + FHeater.BoilPower * 3);
      SetLength(Pts, Length(Pts) + 1);
      Pts[High(Pts)] := PointF(X, Y);
    end;
    SetLength(Pts, Length(Pts) + 2);
    Pts[High(Pts) - 1] := PointF(WallR(CBot), CBot);
    Pts[High(Pts)] := PointF(WallL(CBot), CBot);
    B.FillPolyAntialias(Pts, LiquidC);
    // highlight on the surface
    B.DrawLineAntialias(WallL(LTop) + 8, LTop + 3, WallL(LTop) + (WallR(LTop) - WallL(LTop)) * 0.35, LTop + 3,
      BGRA(255, 255, 255, 70), 2);

    // bubbles while boiling
    if FHeater.BoilPower > 0 then
    begin
      NBubbles := 4 + Round(FHeater.BoilPower * 26);
      for I := 0 to NBubbles - 1 do
      begin
        F := Frac(Phase * (0.6 + Frac(I * 0.37) * 0.8) + I * 0.271);
        Y := CBot - F * (CBot - LTop);
        X := WallL(Y) + 6 + Frac(I * 0.618) * (WallR(Y) - WallL(Y) - 12);
        R := 1.5 + Frac(I * 0.43) * 3.5 * (0.5 + F);
        B.EllipseAntialias(X, Y, R, R, BGRA(255, 255, 255, 170), 1.2);
      end;
      // steam above the pot
      for I := 0 to 5 do
      begin
        F := Frac(Phase * 0.35 + I / 6);
        X := PX + PW * (0.2 + 0.12 * I) + Sin(Phase + I) * 8;
        Y := PY - F * (PY - 60);
        B.FillEllipseAntialias(X, Y, 10 + F * 14, 6 + F * 8,
          BGRA(240, 245, 255, Round(150 * FHeater.BoilPower * (1 - F))));
      end;
    end;
  end
  else
    LTop := CBot;

  // remaining solid chunks, sitting on the liquid (or the bottom)
  NChunks := Round(9 * (1 - FHeater.MeltFrac));
  for I := 0 to NChunks - 1 do
  begin
    J := I mod 3;
    R := (CBot - CTop) / 3.2 * (0.55 + 0.45 * (1 - FHeater.MeltFrac));
    Y := Min(LTop, CBot) - R * (I div 3 + 1) + (I div 3) * 2;
    if Y - R < CTop - 4 then Continue;
    X := WallL(Y) + 4 + (WallR(Y) - WallL(Y) - 8) * (J + 0.5) / 3 + IfThen(Odd(I div 3), R * 0.4, 0);
    B.FillRoundRectAntialias(X - R * 0.9, Y, X + R * 0.9, Y + R, 4, 4, SolidC);
    B.RoundRectAntialias(X - R * 0.9, Y, X + R * 0.9, Y + R, 4, 4, Mix(SolidC, BGRA(0, 0, 0), 0.35), 1);
  end;

  // rim
  B.FillRoundRectAntialias(PX - 6, PY - 5, PX + PW + 6, PY + 3, 3, 3, BGRA(160, 168, 185));

  // thermometer probe + reading
  B.DrawLineAntialias(PX + PW * 0.82, PY - 30, PX + PW * 0.78, CBot - 8, BGRA(200, 205, 215), 3);
  B.FillEllipseAntialias(PX + PW * 0.78, CBot - 8, 4, 4, BGRA(220, 60, 50));
  B.FontHeight := 13;
  B.FontStyle := [fsBold];
  B.FillRoundRectAntialias(PX + PW * 0.82 - 4, PY - 52, PX + PW * 0.82 + 74, PY - 30, 6, 6, BGRA(45, 52, 70));
  B.TextOut(PX + PW * 0.82 + 35, PY - 50, Format('%.1f °C', [FHeater.PV]), BGRAWhite, taCenter);
end;

procedure TFormHeater.ChartMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  // click a legend entry to show / hide that series
  for I := 0 to High(FLegend) do
    if FLegend[I].Contains(Point(X, Y)) then
    begin
      FShow[I] := not FShow[I];
      FChart.Invalidate;
      Exit;
    end;
end;

procedure TFormHeater.RenderChart(Sender: TObject; B: TBGRABitmap);
var
  V: TBGRAView;
  L, T, R, Bt: Single;          // plot rectangle
  TEnd, TStart, W, YMax, Y, X, PX, PY: Single;
  I, N, K, Hi: Integer;
  S: TSample;
  Ev: TDisturbance;
  Mk: TMark;
  EvC: TBGRAPixel;
  Pts: ArrayOfTPointF;
  Fill: ArrayOfTPointF;
  Txt: string;
  TW: Integer;

  function XOf(ATime: Double): Single;
  begin
    Result := L + (ATime - TStart) / W * (R - L);
  end;

  function YOfT(ATemp: Double): Single;
  begin
    Result := Bt - ATemp / YMax * (Bt - T);
  end;

  function YOfOut(AOut: Double): Single;
  begin
    Result := Bt - AOut / 100 * (Bt - T);
  end;

begin
  V := TBGRAView(Sender);
  L := 58;
  T := 46;
  R := V.Width - 52;
  Bt := V.Height - 34;
  if (R - L < 50) or (Bt - T < 40) then Exit;

  W := WindowSeconds;
  TEnd := Max(FHeater.SimTime, W);
  TStart := TEnd - W;

  // y scale: rounded up to 50 degC, at least 150
  YMax := Max(FHeater.SP, FHeater.PV);
  N := FHeater.HistoryCount;
  for I := 0 to N - 1 do
  begin
    S := FHeater.Sample(I);
    if S.T >= TStart then YMax := Max(YMax, Max(S.PV, S.SP));
  end;
  // keep the melting / boiling point of the material visible
  if FHeater.Material.MeltPoint > 0 then YMax := Max(YMax, FHeater.Material.MeltPoint);
  if FHeater.Material.BoilPoint > 0 then YMax := Max(YMax, FHeater.Material.BoilPoint);
  YMax := Max(150, Ceil(YMax * 1.1 / 50) * 50);

  // title + legend (click an entry to show / hide it)
  B.FontHeight := 15;
  B.FontStyle := [fsBold];
  B.TextOut(L, 12, 'History', BGRA(40, 45, 60));
  B.FontHeight := 12;
  B.FontStyle := [];
  X := L + 76;
  for I := 0 to High(FShow) do
  begin
    case I of
      0: begin Txt := 'Actual'; EvC := C_PV; end;
      1: begin Txt := 'Setpoint'; EvC := C_SP; end;
      2: begin Txt := 'Output (gain) %'; EvC := BGRA(60, 175, 110); end;
      3: begin Txt := 'Disturbances'; EvC := BGRA(240, 140, 40); end;
    else
      begin Txt := 'Start / Stop / Gain / Plant'; EvC := BGRA(150, 90, 200); end;
    end;
    TW := B.TextSize(Txt).cx;
    FLegend[I] := Rect(Round(X) - 4, 8, Round(X + 24 + TW) + 4, 32);
    if not FShow[I] then EvC := BGRA(200, 203, 210);
    B.FillRoundRectAntialias(X, 16, X + 18, 24, 3, 3, EvC);
    if FShow[I] then B.TextOut(X + 24, 12, Txt, BGRA(80, 85, 100))
    else B.TextOut(X + 24, 12, Txt, BGRA(185, 188, 196));
    X := X + 24 + TW + 18;
  end;

  // grid
  B.FontHeight := 11;
  for I := 0 to 5 do
  begin
    Y := T + (Bt - T) * I / 5;
    B.DrawLineAntialias(L, Y, R, Y, BGRA(232, 235, 242), 1);
    B.TextOut(L - 8, Y - 7, Format('%.0f', [YMax * (5 - I) / 5]), BGRA(130, 135, 150), taRightJustify);
    B.TextOut(R + 8, Y - 7, Format('%d', [100 * (5 - I) div 5]), BGRA(60, 150, 100));
  end;
  for I := 0 to 6 do
  begin
    X := L + (R - L) * I / 6;
    B.DrawLineAntialias(X, T, X, Bt, BGRA(240, 242, 247), 1);
    B.TextOut(X, Bt + 8, FmtTime(TStart + W * I / 6), BGRA(130, 135, 150), taCenter);
  end;
  B.TextOut(L - 8, T - 22, '°C', BGRA(130, 135, 150), taRightJustify);
  B.TextOut(R + 8, T - 22, '%', BGRA(60, 150, 100));
  B.RectangleAntialias(L, T, R, Bt, BGRA(210, 215, 225), 1);

  // melting / boiling point of the material as dotted reference lines
  B.FontHeight := 10;
  for I := 0 to 1 do
  begin
    if I = 0 then Y := FHeater.Material.MeltPoint else Y := FHeater.Material.BoilPoint;
    if (Y <= 0) or (Y >= YMax) then Continue;
    PY := YOfT(Y);
    X := L;
    while X < R do
    begin
      B.DrawLineAntialias(X, PY, Min(X + 5, R), PY, BGRA(150, 90, 200, 160), 1);
      X := X + 10;
    end;
    if I = 0 then Txt := Format('melts %.0f °C', [Y]) else Txt := Format('boils %.0f °C', [Y]);
    B.TextOut(R - 6, PY - 14, Txt, BGRA(150, 90, 200), taRightJustify);
  end;

  if N = 0 then
  begin
    B.FontHeight := 14;
    B.TextOut((L + R) / 2, (T + Bt) / 2 - 8, 'Press Start to run the heater', BGRA(150, 155, 170), taCenter);
    Exit;
  end;

  // disturbance events as shaded bands
  B.FontHeight := 10;
  if FShow[3] then
  for I := 0 to FHeater.EventCount - 1 do
  begin
    Ev := FHeater.Event(I);
    if (Ev.EndT < TStart) or (Ev.StartT > TEnd) then Continue;
    X := XOf(Max(Ev.StartT, TStart));
    PX := XOf(Min(Min(Ev.EndT, FHeater.SimTime), TEnd));
    case Ev.Kind of
      dkDoor:    EvC := BGRA(240, 140, 40);
      dkDraft:   EvC := BGRA(70, 160, 220);
      dkLoad:    EvC := BGRA(150, 100, 200);
    else
      EvC := BGRA(220, 190, 30);
    end;
    B.FillRectAntialias(X, T, Max(PX, X + 2), Bt, BGRA(EvC.red, EvC.green, EvC.blue, 38));
    B.DrawLineAntialias(X, T, X, Bt, BGRA(EvC.red, EvC.green, EvC.blue, 140), 1);
    // labels on 3 staggered rows so close events do not overlap
    B.TextOut(X + 3, T + 3 + (I mod 3) * 13, Ev.Name, BGRA(EvC.red, EvC.green, EvC.blue, 230));
  end;

  // first visible sample
  K := 0;
  while (K < N - 1) and (FHeater.Sample(K).T < TStart) do Inc(K);

  // Start / Stop / gain changes as vertical marks, labels at the bottom on 2 rows
  if FShow[4] then
    for I := 0 to FHeater.MarkCount - 1 do
    begin
      Mk := FHeater.Mark(I);
      if (Mk.T < TStart) or (Mk.T > TEnd) then Continue;
      case Mk.Kind of
        mkStart: EvC := BGRA(35, 160, 80);
        mkStop:  EvC := BGRA(215, 50, 50);
        mkScenario: EvC := BGRA(0, 140, 155);
      else
        EvC := BGRA(150, 90, 200);
      end;
      X := XOf(Mk.T);
      B.DrawLineAntialias(X, T, X, Bt, BGRA(EvC.red, EvC.green, EvC.blue, 200), 1.5);
      B.FontHeight := 10;
      B.FontStyle := [fsBold];
      TW := B.TextSize(Mk.Text).cx;
      PY := Bt - 20 - (I mod 2) * 18;
      PX := EnsureRange(X + 3, L + 2, R - TW - 10);
      B.FillRoundRectAntialias(PX, PY, PX + TW + 8, PY + 15, 4, 4, EvC);
      B.TextOut(PX + 4, PY + 1, Mk.Text, BGRAWhite);
      B.FontStyle := [];
    end;

  // output: filled area
  SetLength(Fill, 0);
  for I := K to N - 1 do
  begin
    S := FHeater.Sample(I);
    SetLength(Fill, Length(Fill) + 1);
    Fill[High(Fill)] := PointF(XOf(S.T), YOfOut(S.OUT));
  end;
  if FShow[2] and (Length(Fill) > 1) then
  begin
    SetLength(Fill, Length(Fill) + 2);
    Fill[High(Fill) - 1] := PointF(Fill[High(Fill) - 2].X, Bt);
    Fill[High(Fill)] := PointF(Fill[0].X, Bt);
    B.FillPolyAntialias(Fill, BGRA(60, 175, 110, 45));
  end;

  // setpoint: step line
  SetLength(Pts, 0);
  for I := K to N - 1 do
  begin
    S := FHeater.Sample(I);
    if Length(Pts) > 0 then
    begin
      SetLength(Pts, Length(Pts) + 1);
      Pts[High(Pts)] := PointF(XOf(S.T), Pts[High(Pts) - 1].Y);
    end;
    SetLength(Pts, Length(Pts) + 1);
    Pts[High(Pts)] := PointF(XOf(S.T), YOfT(S.SP));
  end;
  if FShow[1] and (Length(Pts) > 1) then B.DrawPolyLineAntialias(Pts, C_SP, 2);

  // actual
  SetLength(Pts, N - K);
  for I := K to N - 1 do
  begin
    S := FHeater.Sample(I);
    Pts[I - K] := PointF(XOf(S.T), YOfT(S.PV));
  end;
  if FShow[0] and (Length(Pts) > 1) then B.DrawPolyLineAntialias(Pts, C_PV, 2.5);

  // hover: crosshair + values of the nearest sample
  if (FHoverX >= L) and (FHoverX <= R) then
  begin
    Hi := K;
    for I := K to N - 1 do
      if Abs(XOf(FHeater.Sample(I).T) - FHoverX) < Abs(XOf(FHeater.Sample(Hi).T) - FHoverX) then Hi := I;
    S := FHeater.Sample(Hi);
    PX := XOf(S.T);
    B.DrawLineAntialias(PX, T, PX, Bt, BGRA(120, 125, 140, 160), 1);
    B.FillEllipseAntialias(PX, YOfT(S.PV), 4.5, 4.5, C_PV);
    B.FillEllipseAntialias(PX, YOfT(S.SP), 3.5, 3.5, C_SP);
    Txt := Format('%s   actual %.1f °C   setpoint %.1f °C   output %.1f %%',
      [FmtTime(S.T), S.PV, S.SP, S.OUT]);
    B.FontHeight := 12;
    B.FontStyle := [];
    TW := B.TextSize(Txt).cx;
    PX := EnsureRange(PX + 12, L + 4, R - TW - 20);
    PY := T + 8;
    B.FillRoundRectAntialias(PX, PY, PX + TW + 16, PY + 24, 6, 6, BGRA(35, 40, 55, 230));
    B.TextOut(PX + 8, PY + 4, Txt, BGRAWhite);
  end;
end;

procedure TFormHeater.ChartMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  FHoverX := X;
  FChart.Invalidate;
end;

procedure TFormHeater.ChartMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FChart.Invalidate;
end;

end.
