unit HeaterModel;

{ Heater simulation: a heating element + a thermal mass, controlled by a PID loop.
  - Dead time:  the controller output reaches the element after DeadTime seconds
  - Element:    E' = (u - E) / TauElement          (u = output 0..100 %)
  - Plant:      T' = (Gain * LoadFactor * E / 100 - (T - AmbientNow) - Loss) / TauPlant
  - Sensor:     PV = T + noise (sample and hold every 0.2 s)
  - Scenario:   every plant parameter is randomised ("mystery plant"), plus a drifting
                ambient temperature and random disturbance events (door open, draft, load ...)
  - PID:        parallel form, derivative on measurement, conditional integration anti-windup
  - Score:      after Start / a setpoint change: overshoot, settling time and IAE -> 0..100
  - History:    one sample per simulated second, ring buffer
  - Material:   the pot holds a random material that melts and/or boils. Latent heat makes
                the temperature stay at the melting point until everything has melted, and
                it cannot rise above the boiling point while the liquid boils.
  - Marks:      Start / Stop / gain changes are logged for the chart }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

type
  TSample = record
    T: Double;      // simulated time (s)
    PV: Single;     // actual temperature (degC)
    SP: Single;     // setpoint (degC)
    OUT: Single;    // controller output (%)
  end;

  TDisturbKind = (dkDoor, dkDraft, dkLoad, dkVoltage);

  TDisturbance = record
    Kind: TDisturbKind;
    Name: string;
    StartT, EndT: Double;
    Magnitude: Double;   // degC of extra loss, or gain factor for load / voltage
  end;

  TMarkKind = (mkStart, mkStop, mkGain, mkSetpoint, mkScenario);

  TMark = record
    T: Double;
    Kind: TMarkKind;
    Text: string;
  end;

  TMaterial = record
    Name: string;
    MeltPoint: Double;    // 0 = already liquid at room temperature
    BoilPoint: Double;    // 0 = does not boil below 300 degC
    Latent: Double;       // melting energy, as degC of heating (bigger = longer plateau)
    Solid: array[0..2] of Byte;   // RGB
    Liquid: array[0..2] of Byte;  // RGB
  end;

  TMaterialState = (msSolid, msMelting, msLiquid, msBoiling);

  { THeater }

  THeater = class
  private
    FInteg: Double;
    FPrevPV: Double;
    FElement: Double;
    FTrue: Double;                 // true temperature (PV = FTrue + noise)
    FNextSensor: Double;
    FDelay: array of Double;       // dead time buffer of the output (0.1 s per slot)
    FDelayPos: Integer;
    FHist: array of TSample;
    FHead, FCount: Integer;
    FNextSample: Double;
    FEvents: array of TDisturbance;
    FNextEvent: Double;
    // score
    FScoreOn: Boolean;
    FScoreManual: Boolean;
    FScoreStartT, FScoreStartPV, FScoreSP: Double;
    FMaxOver, FIAE: Double;
    FInBandSince: Double;
    FSettleTime: Double;           // -1 = not settled yet
    FMarks: array of TMark;
    procedure AddSample;
    procedure SubStep(dt: Double);
    procedure ScheduleNextEvent;
    procedure StartRandomEvent;
    procedure UpdateScore(dt: Double);
    procedure RandomizePlant(ASeed: Cardinal);
  public
    // command / status
    Running: Boolean;
    Auto: Boolean;        // True = PID, False = manual output
    SP: Double;           // setpoint degC
    PV: Double;           // measured degC
    OUT: Double;          // output %
    Manual: Double;       // manual output %
    // PID
    Kp, Ki, Kd: Double;   // Ki in 1/s, Kd in s
    // plant (randomised by NewScenario)
    Ambient: Double;      // mean ambient degC
    AmbientNow: Double;   // ambient incl. drift
    DriftAmp: Double;     // degC
    DriftPeriod: Double;  // s
    Gain: Double;         // degC above ambient at 100 % output (steady state)
    TauPlant: Double;     // s
    TauElement: Double;   // s
    DeadTime: Double;     // s
    Noise: Double;        // degC (sensor noise amplitude)
    DisturbLevel: Double; // 0..1 strength of random events
    EventEvery: Double;   // mean seconds between events
    LoadFactor: Double;   // current gain factor from events
    Loss: Double;         // current extra loss from events (degC)
    AlarmLimit: Double;   // degC
    SimTime: Double;      // s
    // scenario
    ScenarioName: string;
    ScenarioSeed: Cardinal;
    Stars: Integer;       // difficulty 1..5
    // material in the pot
    Material: TMaterial;
    MeltFrac: Double;     // 0 = solid .. 1 = fully molten
    BoilPower: Double;    // 0..1 how hard it boils (smoothed)
    function ElementGlow: Double;   // 0..1 heater element temperature
    function MaterialState: TMaterialState;
    function MaterialStateText: string;
    // chart marks (Start / Stop / gain changes), 0 = oldest
    procedure AddMark(AKind: TMarkKind; const AText: string);
    procedure SetGains(AKp, AKi, AKd: Double);
    function MarkCount: Integer;
    function Mark(AIndex: Integer): TMark;
    constructor Create(ACapacity: Integer = 3600);
    { new random plant; keeps the PID gains (tuning them is the game) }
    procedure NewScenario(ASeed: Cardinal = 0);
    { new random plant parameters while running: temperature, material, history and
      Start/Stop state continue; the change is marked on the chart }
    procedure ChangeScenario(ASeed: Cardinal = 0);
    procedure Start;
    procedure Stop;
    procedure SetSetpoint(AValue: Double);
    procedure ResetPID;
    procedure ClearHistory;
    { advance the simulation by ADt simulated seconds (internally 0.1 s steps) }
    procedure Step(ADt: Double);
    function Alarm: Boolean;
    function Error: Double;
    function HistoryCount: Integer;
    { 0 = oldest sample }
    function Sample(AIndex: Integer): TSample;
    function Capacity: Integer;
    // disturbance events (for the chart), 0 = oldest
    function EventCount: Integer;
    function Event(AIndex: Integer): TDisturbance;
    function ActiveEventName: string;
    // score of the last setpoint step: -1 = not available yet
    function Score: Integer;
    function ScoreText: string;
    function ScoreDetail: string;
    function PlantText: string;
  end;

implementation

const
  DT_FIXED = 0.1;
  MAX_EVENTS = 200;
  PlantNames: array[0..7] of string = ('Melting Pot', 'Lab Crucible', 'Old Kettle', 'Workshop Pot',
    'Steel Vat', 'Cast Iron Pot', 'Hot Plate', 'Foundry Ladle');
  Materials: array[0..7] of TMaterial = (
    (Name: 'Paraffin wax'; MeltPoint: 58;  BoilPoint: 0;   Latent: 60; Solid: (238, 230, 205); Liquid: (250, 235, 170)),
    (Name: 'Water';        MeltPoint: 0;   BoilPoint: 100; Latent: 0;  Solid: (200, 225, 245); Liquid: (90, 160, 230)),
    (Name: 'Salt water';   MeltPoint: 0;   BoilPoint: 104; Latent: 0;  Solid: (215, 225, 235); Liquid: (110, 170, 220)),
    (Name: 'Solder';       MeltPoint: 183; BoilPoint: 0;   Latent: 35; Solid: (160, 162, 170); Liquid: (215, 220, 230)),
    (Name: 'Sugar';        MeltPoint: 160; BoilPoint: 0;   Latent: 45; Solid: (250, 250, 245); Liquid: (205, 125, 40)),
    (Name: 'Tin';          MeltPoint: 232; BoilPoint: 0;   Latent: 30; Solid: (150, 152, 160); Liquid: (225, 230, 240)),
    (Name: 'Chocolate';    MeltPoint: 40;  BoilPoint: 0;   Latent: 40; Solid: (110, 65, 40);   Liquid: (130, 75, 45)),
    (Name: 'Glycerin';     MeltPoint: 0;   BoilPoint: 290; Latent: 0;  Solid: (235, 240, 240); Liquid: (225, 235, 230)));

{ THeater }

constructor THeater.Create(ACapacity: Integer);
begin
  SetLength(FHist, ACapacity);
  Auto := True;
  SP := 120;
  Manual := 30;
  Kp := 2.0;
  Ki := 0.05;
  Kd := 5.0;
  AlarmLimit := 250;
  Randomize;
  NewScenario;
end;

{ new random plant parameters from the seed (does not touch the state) }
procedure THeater.RandomizePlant(ASeed: Cardinal);
var
  Difficulty: Double;
begin
  ScenarioSeed := ASeed;
  RandSeed := ASeed;
  Gain := 220 + Random * 200;
  TauPlant := 30 + Random * 110;
  TauElement := 3 + Random * 22;
  DeadTime := Random * 12;
  Noise := 0.05 + Random * 0.75;
  Ambient := 12 + Random * 23;
  DriftAmp := Random * 4;
  DriftPeriod := 300 + Random * 900;
  DisturbLevel := 0.2 + Random * 0.8;
  EventEvery := 90 + Random * 150;
  Difficulty := EnsureRange(DeadTime / 12 * 0.4 + TauElement / 25 * 0.2 +
    Noise / 0.8 * 0.15 + DisturbLevel * 0.25, 0, 1);
  Stars := 1 + Round(Difficulty * 4);
end;

procedure THeater.ChangeScenario(ASeed: Cardinal);
var
  OldLen, I: Integer;
  Held: Double;
begin
  if ASeed = 0 then ASeed := Cardinal(Random(99999) + 1);
  RandomizePlant(ASeed);
  Randomize;
  // new dead time: the output already "in the pipe" is kept as the current output
  OldLen := Length(FDelay);
  if OldLen > 0 then Held := FDelay[FDelayPos] else Held := OUT;
  SetLength(FDelay, Max(1, Round(DeadTime / DT_FIXED)));
  for I := 0 to High(FDelay) do FDelay[I] := Held;
  FDelayPos := 0;
  // events continue with the new strength / rhythm
  FNextEvent := Min(FNextEvent, SimTime + EventEvery * (0.5 + Random));
  AddMark(mkScenario, Format('NEW PLANT #%d', [ASeed]));
  // the plant changed: score the response from here
  if Running then SetSetpoint(SP);
end;

procedure THeater.NewScenario(ASeed: Cardinal);
begin
  if ASeed = 0 then ASeed := Cardinal(Random(99999) + 1);
  RandomizePlant(ASeed);
  ScenarioName := PlantNames[Random(Length(PlantNames))];
  Material := Materials[Random(Length(Materials))];
  // a slightly different latent heat each time
  Material.Latent := Material.Latent * (0.7 + Random * 0.6);

  // fresh start: cold plant, empty history, heater off
  Running := False;
  OUT := 0;
  SimTime := 0;
  FTrue := Ambient;
  PV := Ambient;
  AmbientNow := Ambient;
  FElement := 0;
  LoadFactor := 1;
  Loss := 0;
  SetLength(FDelay, Max(1, Round(DeadTime / DT_FIXED)));
  FillChar(FDelay[0], Length(FDelay) * SizeOf(Double), 0);
  FDelayPos := 0;
  SetLength(FEvents, 0);
  SetLength(FMarks, 0);
  // solid at room temperature unless it melts below the ambient
  if (Material.MeltPoint > 0) and (Material.MeltPoint > Ambient) then MeltFrac := 0 else MeltFrac := 1;
  BoilPower := 0;
  FNextSample := 0;
  FNextSensor := 0;
  ClearHistory;
  ResetPID;
  FScoreOn := False;
  FSettleTime := -1;
  ScheduleNextEvent;
  Randomize; // events / noise after this point are not reproducible from the seed
end;

procedure THeater.Start;
begin
  if Running then Exit;
  Running := True;
  ResetPID;
  AddMark(mkStart, 'START');
  SetSetpoint(SP); // starts scoring
end;

procedure THeater.Stop;
begin
  if Running then AddMark(mkStop, 'STOP');
  Running := False;
  OUT := 0;
  FInteg := 0;
  FScoreOn := False;
end;

procedure THeater.AddMark(AKind: TMarkKind; const AText: string);
var
  I: Integer;
begin
  if Length(FMarks) >= MAX_EVENTS then
  begin
    for I := 1 to High(FMarks) do FMarks[I - 1] := FMarks[I];
    SetLength(FMarks, Length(FMarks) - 1);
  end;
  SetLength(FMarks, Length(FMarks) + 1);
  FMarks[High(FMarks)].T := SimTime;
  FMarks[High(FMarks)].Kind := AKind;
  FMarks[High(FMarks)].Text := AText;
end;

procedure THeater.SetGains(AKp, AKi, AKd: Double);
begin
  if (AKp = Kp) and (AKi = Ki) and (AKd = Kd) then Exit;
  Kp := AKp;
  Ki := AKi;
  Kd := AKd;
  AddMark(mkGain, Format('Kp %.2f  Ki %.3f  Kd %.2f', [Kp, Ki, Kd]));
end;

function THeater.MarkCount: Integer;
begin
  Result := Length(FMarks);
end;

function THeater.Mark(AIndex: Integer): TMark;
begin
  Result := FMarks[AIndex];
end;

function THeater.ElementGlow: Double;
begin
  Result := EnsureRange(FElement / 100, 0, 1);
end;

function THeater.MaterialState: TMaterialState;
begin
  if BoilPower > 0.02 then Result := msBoiling
  else if MeltFrac <= 0 then Result := msSolid
  else if MeltFrac < 1 then Result := msMelting
  else Result := msLiquid;
end;

function THeater.MaterialStateText: string;
begin
  case MaterialState of
    msSolid:   Result := Format('Solid  (melts at %.0f °C)', [Material.MeltPoint]);
    msMelting: Result := Format('Melting  %.0f %%', [MeltFrac * 100]);
    msBoiling: Result := Format('Boiling at %.0f °C', [Material.BoilPoint]);
  else
    if Material.BoilPoint > 0 then
      Result := Format('Liquid  (boils at %.0f °C)', [Material.BoilPoint])
    else
      Result := 'Liquid';
  end;
end;

procedure THeater.SetSetpoint(AValue: Double);
begin
  SP := AValue;
  if not Running then Exit;
  // a new step to be scored
  FScoreOn := True;
  FScoreManual := not Auto;
  FScoreStartT := SimTime;
  FScoreStartPV := PV;
  FScoreSP := SP;
  FMaxOver := 0;
  FIAE := 0;
  FInBandSince := -1;
  FSettleTime := -1;
end;

procedure THeater.ResetPID;
begin
  FInteg := 0;
  FPrevPV := PV;
end;

procedure THeater.ClearHistory;
begin
  FHead := 0;
  FCount := 0;
end;

function THeater.Alarm: Boolean;
begin
  Result := PV >= AlarmLimit;
end;

function THeater.Error: Double;
begin
  Result := SP - PV;
end;

function THeater.Capacity: Integer;
begin
  Result := Length(FHist);
end;

function THeater.HistoryCount: Integer;
begin
  Result := FCount;
end;

function THeater.Sample(AIndex: Integer): TSample;
var
  I: Integer;
begin
  // FHead = position where the next sample will be written
  I := (FHead - FCount + AIndex + Length(FHist) * 2) mod Length(FHist);
  Result := FHist[I];
end;

function THeater.EventCount: Integer;
begin
  Result := Length(FEvents);
end;

function THeater.Event(AIndex: Integer): TDisturbance;
begin
  Result := FEvents[AIndex];
end;

function THeater.ActiveEventName: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FEvents) do
    if (SimTime >= FEvents[I].StartT) and (SimTime < FEvents[I].EndT) then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + FEvents[I].Name;
    end;
end;

function THeater.PlantText: string;
begin
  Result := Format('gain %.0f °C · τ plant %.0f s · τ element %.1f s · dead time %.1f s · ' +
    'noise ±%.2f · ambient %.1f ±%.1f °C · disturbances %.0f %%',
    [Gain, TauPlant, TauElement, DeadTime, Noise / 2, Ambient, DriftAmp, DisturbLevel * 100]);
end;

procedure THeater.AddSample;
begin
  FHist[FHead].T := SimTime;
  FHist[FHead].PV := PV;
  FHist[FHead].SP := SP;
  FHist[FHead].OUT := OUT;
  FHead := (FHead + 1) mod Length(FHist);
  if FCount < Length(FHist) then Inc(FCount);
end;

{ ---------- disturbances ---------- }

procedure THeater.ScheduleNextEvent;
begin
  // the first minute is always calm
  FNextEvent := Max(SimTime, 60) + EventEvery * (0.5 + Random);
end;

procedure THeater.StartRandomEvent;
var
  E: TDisturbance;
  I: Integer;
begin
  E.Kind := TDisturbKind(Random(4));
  E.StartT := SimTime;
  case E.Kind of
    dkDoor:
      begin
        E.Name := 'Door open';
        E.Magnitude := (20 + Random * 40) * DisturbLevel;
        E.EndT := SimTime + 15 + Random * 30;
      end;
    dkDraft:
      begin
        E.Name := 'Cold draft';
        E.Magnitude := (8 + Random * 12) * DisturbLevel;
        E.EndT := SimTime + 60 + Random * 90;
      end;
    dkLoad:
      begin
        E.Name := 'Load added';
        E.Magnitude := 1 - (0.15 + Random * 0.2) * DisturbLevel;
        E.EndT := SimTime + 60 + Random * 120;
      end;
  else
    begin
      E.Name := 'Voltage dip';
      E.Magnitude := 1 - (0.2 + Random * 0.25) * DisturbLevel;
      E.EndT := SimTime + 10 + Random * 20;
    end;
  end;
  if Length(FEvents) >= MAX_EVENTS then
  begin
    for I := 1 to High(FEvents) do FEvents[I - 1] := FEvents[I];
    FEvents[High(FEvents)] := E;
  end
  else
  begin
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := E;
  end;
end;

{ ---------- score ---------- }

procedure THeater.UpdateScore(dt: Double);
var
  Band, Dir: Double;
begin
  if not FScoreOn or (FSettleTime >= 0) then Exit;
  if not Auto then FScoreManual := True;
  if FScoreSP >= FScoreStartPV then Dir := 1 else Dir := -1;
  FMaxOver := Max(FMaxOver, (PV - FScoreSP) * Dir);
  FIAE := FIAE + Abs(FScoreSP - PV) * dt;
  // settled = inside the band for 20 s in a row
  Band := Max(1.5, Abs(FScoreSP) * 0.015);
  if Abs(FScoreSP - PV) <= Band then
  begin
    if FInBandSince < 0 then FInBandSince := SimTime;
    if SimTime - FInBandSince >= 20 then
      FSettleTime := FInBandSince - FScoreStartT;
  end
  else
    FInBandSince := -1;
end;

function THeater.Score: Integer;
var
  StepSize, OvPct, Ratio, IAEn, S: Double;
begin
  if not FScoreOn or (FSettleTime < 0) or FScoreManual then Exit(-1);
  StepSize := Max(5, Abs(FScoreSP - FScoreStartPV));
  OvPct := FMaxOver / StepSize * 100;
  // settling time compared with how slow this plant is
  Ratio := FSettleTime / (TauPlant + TauElement + DeadTime * 2);
  IAEn := FIAE / (StepSize * (TauPlant + TauElement + DeadTime));
  S := 100 - Min(35, OvPct * 1.5) - Min(45, Max(0, (Ratio - 2) * 12)) - Min(20, Max(0, (IAEn - 0.6) * 15));
  Result := EnsureRange(Round(S), 0, 100);
end;

function THeater.ScoreText: string;
var
  S: Integer;
begin
  if not FScoreOn then Exit('');
  if FScoreManual then Exit('manual - not scored');
  S := Score;
  if S < 0 then Exit('settling...');
  if S >= 90 then Result := Format('%d  Excellent', [S])
  else if S >= 75 then Result := Format('%d  Good', [S])
  else if S >= 55 then Result := Format('%d  OK', [S])
  else Result := Format('%d  Needs tuning', [S]);
end;

function THeater.ScoreDetail: string;
var
  StepSize: Double;
begin
  if not FScoreOn then Exit('Press Start (or change the setpoint) to score a step');
  StepSize := Max(5, Abs(FScoreSP - FScoreStartPV));
  Result := Format('overshoot %.1f %%   ·   ', [FMaxOver / StepSize * 100]);
  if FSettleTime >= 0 then
    Result := Result + Format('settled in %.0f s', [FSettleTime])
  else
    Result := Result + Format('running %.0f s', [SimTime - FScoreStartT]);
end;

{ ---------- simulation ---------- }

procedure THeater.SubStep(dt: Double);
var
  Err, P, D, U, NewInteg, UDelayed: Double;
  NewT, M, Boil: Double;
  I: Integer;
begin
  // ---- controller ----
  if not Running then
    U := 0
  else if Auto then
  begin
    Err := SP - PV;
    P := Kp * Err;
    D := -Kd * (PV - FPrevPV) / dt;
    NewInteg := FInteg + Ki * Err * dt;
    U := P + NewInteg + D;
    // conditional integration: freeze the integral while saturated in the same direction
    if ((U > 100) and (Err > 0)) or ((U < 0) and (Err < 0)) then
      U := P + FInteg + D
    else
      FInteg := NewInteg;
    U := EnsureRange(U, 0, 100);
  end
  else
  begin
    U := EnsureRange(Manual, 0, 100);
    // bumpless transfer back to auto
    FInteg := U - Kp * (SP - PV);
  end;
  OUT := U;
  FPrevPV := PV;

  // ---- dead time ----
  UDelayed := FDelay[FDelayPos];
  FDelay[FDelayPos] := U;
  FDelayPos := (FDelayPos + 1) mod Length(FDelay);

  // ---- disturbances ----
  if SimTime >= FNextEvent then
  begin
    StartRandomEvent;
    ScheduleNextEvent;
  end;
  LoadFactor := 1;
  Loss := 0;
  for I := 0 to High(FEvents) do
    if (SimTime >= FEvents[I].StartT) and (SimTime < FEvents[I].EndT) then
      case FEvents[I].Kind of
        dkDoor, dkDraft: Loss := Loss + FEvents[I].Magnitude;
        dkLoad, dkVoltage: LoadFactor := LoadFactor * FEvents[I].Magnitude;
      end;
  AmbientNow := Ambient + DriftAmp * Sin(2 * Pi * SimTime / DriftPeriod);

  // ---- plant ----
  FElement := FElement + (UDelayed - FElement) / TauElement * dt;
  NewT := FTrue + (Gain * LoadFactor * FElement / 100 - (FTrue - AmbientNow) - Loss) / TauPlant * dt;

  // ---- latent heat: melting / freezing plateau ----
  if (Material.MeltPoint > 0) and (Material.Latent > 0) then
  begin
    M := Material.MeltPoint;
    if (MeltFrac < 1) and (NewT > M) then
    begin
      // the heat above the melting point melts the material instead
      MeltFrac := MeltFrac + (NewT - Max(FTrue, M)) / Material.Latent;
      NewT := M;
      if MeltFrac > 1 then
      begin
        NewT := M + (MeltFrac - 1) * Material.Latent;
        MeltFrac := 1;
      end;
    end
    else if (MeltFrac > 0) and (NewT < M) then
    begin
      // cooling below the melting point freezes it first
      MeltFrac := MeltFrac - (Min(FTrue, M) - NewT) / Material.Latent;
      NewT := M;
      if MeltFrac < 0 then
      begin
        NewT := M + MeltFrac * Material.Latent;
        MeltFrac := 0;
      end;
    end;
  end;

  // ---- boiling: the liquid cannot get hotter than its boiling point ----
  Boil := 0;
  if (Material.BoilPoint > 0) and (MeltFrac >= 1) and (NewT > Material.BoilPoint) then
  begin
    Boil := EnsureRange((NewT - Material.BoilPoint) / dt * TauPlant / 60, 0, 1);
    NewT := Material.BoilPoint;
  end;
  BoilPower := BoilPower + (Boil - BoilPower) * Min(1, dt / 2);
  if BoilPower < 0.005 then BoilPower := 0;
  FTrue := NewT;

  SimTime := SimTime + dt;

  // ---- sensor: sample and hold with noise ----
  if SimTime >= FNextSensor then
  begin
    PV := FTrue + (Random - 0.5) * Noise;
    FNextSensor := SimTime + 0.2;
  end;

  if Running then UpdateScore(dt);

  if SimTime >= FNextSample then
  begin
    AddSample;
    FNextSample := SimTime + 1.0;
  end;
end;

procedure THeater.Step(ADt: Double);
var
  N, I: Integer;
begin
  N := Max(1, Round(ADt / DT_FIXED));
  for I := 1 to N do SubStep(ADt / N);
end;

end.
