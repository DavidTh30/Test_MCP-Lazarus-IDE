unit ExtruderModel;

{ Extrusion line simulation with PID control
  Raw materials (3, any blend) -> dosing screw -> metal detector -> extruder (5 heater zones)
  -> P1 (after extruder) -> screen changer -> P2 (before melt pump) -> melt pump (fixed speed)

  Main relations (all flows in kg/h, pressures in bar, temperatures in degC):
  - Dosing:        Qd = Cd * Nd% * bulk / 0.6                    (0 while metal is rejected)
  - Fill:          dF/dt = (Qd - Qe) / (Minv * 3600)             F = degree of fill 0..1
  - Viscosity:     mu_i(T) = MuRef_i * exp(-B_i * (T - TRef_i)),  ln mu = sum w_i ln mu_i
                   unmelted factor U raises mu, degradation lowers it
  - Extruder:      Qe = (Ce * Ne * F - Bk * P2 / mu) / (1 + Bk * Rs * (1 + S))
                   (drag flow - pressure back flow, P1 = P2 + screen drop)
  - Screen:        dPs = Rs * (1 + S) * mu * Qe ;  P1 = P2 + dPs ;  S = contamination
  - Melt pump:     Qmp = Cmp * Nmp  (positive displacement, fixed speed)
  - P2:            dP2/dt = Kc * (Qe - Qmp) / 3600                (melt compressibility)
  - Zone i:        Cz dTi/dt = Heat - Cool - Lz (Ti - Tamb) - mcp (Ti - Tin) + Shear
                   Shear = Ksh_i * Ne * sqrt(mu)
  - Melt temp:     Tmelt = 0.15 T3 + 0.30 T4 + 0.55 T5 + 0.06 Ne sqrt(mu)
  - PID:           parallel form, derivative on measurement, conditional integration,
                   bumpless manual <-> auto }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

const
  ZONES = 5;
  MATS = 3;
  HIST_CAP = 3600;

type
  TPolymer = record
    Name: string;
    Tm: Double;        // melting / softening point
    TRef: Double;      // reference temperature for the viscosity
    MuRef: Double;     // relative viscosity at TRef
    B: Double;         // temperature sensitivity of the viscosity (1/degC)
    Tdeg: Double;      // degradation temperature
    Bulk: Double;      // bulk density (kg/L)
    Color: array[0..2] of Byte;
  end;

  { TPID }

  TPID = record
    Kp, Ki, Kd: Double;
    Auto: Boolean;
    Manual: Double;
    OutMin, OutMax: Double;
    Integ, PrevPV, Output: Double;
    LastP, LastD: Double;      // last proportional / derivative terms (physics page)
  end;

  TLineEventKind = (leStart, leStop, leMetalRejected, leMetalPassed, leScreenChanged, leTrip, leInfo);

  TLineEvent = record
    T: Double;
    Kind: TLineEventKind;
    Text: string;
  end;

  TLineSample = record
    T: Double;
    Tz, SPz: array[0..ZONES - 1] of Single;
    P1, P2, P2SP: Single;
    Ne, Nd, Nmp: Single;
    Qd, Qe, Qmp: Single;
    Mu, Tmelt, S, F: Single;
    ExtLoad, DoseLoad, PumpLoad, P3: Single;
  end;

  { TExtruderLine }

  TExtruderLine = class
  private
    FHist: array of TLineSample;
    FHead, FCount: Integer;
    FNextSample: Double;
    FEvents: array of TLineEvent;
    FNextMetal: Double;
    FRejectUntil: Double;
    procedure SubStep(dt: Double);
    procedure AddSample;
    procedure ScheduleMetal;
  public
    // ---- materials ----
    Polymers: array[0..MATS - 1] of TPolymer;
    Blend: array[0..MATS - 1] of Double;     // ratio, any scale (normalised internally)
    // ---- commands ----
    HeatersOn: Boolean;
    Running: Boolean;          // line: melt pump + extruder + dosing
    ColdProtect: Boolean;      // block the screws while the barrel is cold
    MetalDetector: Boolean;
    DosingFF: Boolean;         // dosing = melt pump throughput (feed-forward) + PID trim
    // ---- set points ----
    ZoneSP: array[0..ZONES - 1] of Double;
    P2SP: Double;
    MeltPumpRpm: Double;
    // ---- controllers ----
    ZonePID: array[0..ZONES - 1] of TPID;    // output -100..100 (negative = cooling fan)
    ExtruderPID: TPID;                        // output rpm 0..120, PV = P2
    DosingPID: TPID;                          // output % 0..100, PV = P2
    // ---- constants (shown on the physics page) ----
    Cd, Ce, Cmp, Bk, Rs, Kc, Minv: Double;
    Pmax, Pcool, Lz, Cz, Cp, MatShare, Tamb: Double;
    Ksh: array[0..ZONES - 1] of Double;
    MotorRatedW, MotorRatedRpm, FrictionW, Rdie, Density: Double;
    // ---- state ----
    SimTime: Double;
    Tz: array[0..ZONES - 1] of Double;
    HeatW, CoolW, LossW, MatW, ShearW: array[0..ZONES - 1] of Double; // last heat balance
    F: Double;           // extruder fill
    P1, P2, DPScreen: Double;
    S: Double;           // screen contamination (0 = clean)
    Ne, Nd: Double;      // extruder rpm, dosing %
    DosingFFPct: Double; // feed-forward part of the dosing command (%)
    Qd, Qe, Qmp: Double;
    Mu, MuBase, Unmelt: Double;
    Tmelt: Double;
    Degrading, Starving, Flooded, ColdBlocked, Tripped: Boolean;
    MetalRejects, MetalPassed: Integer;
    TotalKg: Double;
    // motors
    ShearTotalW, PressureWorkW, MotorPowerW: Double;
    ExtLoad, DoseLoad, PumpLoad: Double;   // % of rated torque
    P3: Double;                            // die pressure after the melt pump (bar)
    Overload: Boolean;
    FOverloadTime: Double;
    constructor Create;
    procedure Step(ADt: Double);
    procedure StartLine;
    procedure StopLine;
    procedure ChangeScreen;
    procedure ResetTrip;
    procedure AddEvent(AKind: TLineEventKind; const AText: string);
    // blend helpers
    function Weight(I: Integer): Double;   // normalised 0..1
    function BlendTm: Double;
    function BlendTdeg: Double;
    function BlendBulk: Double;
    function BlendText: string;
    function PolymerMu(I: Integer; T: Double): Double;
    function BlendMu(T: Double): Double;
    function MuEstimated: Double;          // viscosity seen by the two pressure sensors
    function Alarms: string;
    // history / events
    function HistoryCount: Integer;
    function Sample(AIndex: Integer): TLineSample;
    function EventCount: Integer;
    function Event(AIndex: Integer): TLineEvent;
  end;

function PIDStep(var C: TPID; SP, PV, dt: Double): Double;
procedure PIDSetAuto(var C: TPID; AAuto: Boolean);

implementation

function PIDStep(var C: TPID; SP, PV, dt: Double): Double;
var
  Err, P, D, U, NewI: Double;
begin
  Err := SP - PV;
  if not C.Auto then
  begin
    U := EnsureRange(C.Manual, C.OutMin, C.OutMax);
    C.Integ := U - C.Kp * Err; // bumpless back to auto
  end
  else
  begin
    P := C.Kp * Err;
    D := -C.Kd * (PV - C.PrevPV) / dt;
    C.LastP := P;
    C.LastD := D;
    NewI := C.Integ + C.Ki * Err * dt;
    U := P + NewI + D;
    // conditional integration (anti-windup)
    if ((U > C.OutMax) and (Err > 0)) or ((U < C.OutMin) and (Err < 0)) then
      U := P + C.Integ + D
    else
      C.Integ := NewI;
    U := EnsureRange(U, C.OutMin, C.OutMax);
  end;
  C.PrevPV := PV;
  C.Output := U;
  Result := U;
end;

procedure PIDSetAuto(var C: TPID; AAuto: Boolean);
begin
  if AAuto = C.Auto then Exit;
  if not AAuto then C.Manual := C.Output; // manual starts from the current output
  C.Auto := AAuto;
end;

function MakePID(AKp, AKi, AKd, AMin, AMax: Double): TPID;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kp := AKp;
  Result.Ki := AKi;
  Result.Kd := AKd;
  Result.OutMin := AMin;
  Result.OutMax := AMax;
  Result.Auto := True;
end;

function MakePolymer(const AName: string; ATm, ATRef, AMuRef, AB, ATdeg, ABulk: Double;
  R, G, B: Byte): TPolymer;
begin
  Result.Name := AName;
  Result.Tm := ATm;
  Result.TRef := ATRef;
  Result.MuRef := AMuRef;
  Result.B := AB;
  Result.Tdeg := ATdeg;
  Result.Bulk := ABulk;
  Result.Color[0] := R;
  Result.Color[1] := G;
  Result.Color[2] := B;
end;

{ TExtruderLine }

constructor TExtruderLine.Create;
const
  SPDefault: array[0..ZONES - 1] of Double = (185, 200, 210, 220, 225);
  ShearK: array[0..ZONES - 1] of Double = (4, 12, 26, 32, 32);
var
  I: Integer;
begin
  Polymers[0] := MakePolymer('PP',   165, 220, 1.0, 0.020, 290, 0.55, 240, 205, 90);
  Polymers[1] := MakePolymer('HDPE', 132, 210, 1.5, 0.015, 300, 0.60, 120, 180, 235);
  Polymers[2] := MakePolymer('PS',   105, 215, 2.2, 0.028, 280, 0.62, 235, 120, 150);
  Blend[0] := 60;
  Blend[1] := 30;
  Blend[2] := 10;

  Cd := 2.4;      // kg/h per % dosing (at bulk 0.6)
  Ce := 2.0;      // kg/h per rpm at full fill
  Cmp := 4.0;     // kg/h per rpm melt pump
  Bk := 0.4;      // kg/h back flow per bar at mu = 1
  Rs := 0.15;     // bar per kg/h of a clean screen at mu = 1
  Kc := 3000;     // bar per kg of melt between extruder and melt pump
  Minv := 2.0;    // kg of material in a full screw
  Pmax := 6000;   // W heater per zone
  Pcool := 2500;  // W cooling fan per zone
  Lz := 12;       // W/K loss to ambient
  Cz := 9000;     // J/K heat capacity of a zone
  Cp := 2000;     // J/(kg K) polymer
  MatShare := 0.25; // part of the melting energy taken from the heaters (rest = shear)
  Tamb := 25;
  MotorRatedW := 22000;   // extruder motor 22 kW
  MotorRatedRpm := 120;
  FrictionW := 20;        // W per rpm (gearbox + bearings)
  Rdie := 1.6;            // bar per kg/h at mu = 1 (die after the melt pump)
  Density := 750;         // kg/m3 melt

  for I := 0 to ZONES - 1 do
  begin
    ZoneSP[I] := SPDefault[I];
    Ksh[I] := ShearK[I];
    ZonePID[I] := MakePID(6, 0.08, 20, -100, 100);
    Tz[I] := Tamb;
  end;
  // P2 is controlled by both screws: the extruder fast, the dosing slowly on top of a
  // feed-forward that matches the melt pump throughput (mass balance)
  ExtruderPID := MakePID(0.6, 0.06, 0, 0, 120);
  ExtruderPID.Manual := 60;
  DosingPID := MakePID(0.1, 0.003, 0, -50, 50);
  DosingPID.Manual := 40;
  P2SP := 80;
  MeltPumpRpm := 25;
  HeatersOn := True;
  ColdProtect := True;
  MetalDetector := True;
  DosingFF := True;
  Mu := 1;
  SetLength(FHist, HIST_CAP);
  Randomize;
  ScheduleMetal;
end;

{ ---------- blend ---------- }

function TExtruderLine.Weight(I: Integer): Double;
var
  Sum: Double;
  J: Integer;
begin
  Sum := 0;
  for J := 0 to MATS - 1 do Sum := Sum + Max(0, Blend[J]);
  if Sum <= 0 then Exit(0);
  Result := Max(0, Blend[I]) / Sum;
end;

function TExtruderLine.BlendTm: Double;
var
  I: Integer;
begin
  // the component with the highest melting point has to melt
  Result := 0;
  for I := 0 to MATS - 1 do
    if Weight(I) > 0.02 then Result := Max(Result, Polymers[I].Tm);
end;

function TExtruderLine.BlendTdeg: Double;
var
  I: Integer;
begin
  Result := 999;
  for I := 0 to MATS - 1 do
    if Weight(I) > 0.02 then Result := Min(Result, Polymers[I].Tdeg);
end;

function TExtruderLine.BlendBulk: Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to MATS - 1 do Result := Result + Weight(I) * Polymers[I].Bulk;
  if Result <= 0 then Result := 0.6;
end;

function TExtruderLine.BlendText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to MATS - 1 do
    if Weight(I) > 0.001 then
    begin
      if Result <> '' then Result := Result + ' / ';
      Result := Result + Format('%s %.0f%%', [Polymers[I].Name, Weight(I) * 100]);
    end;
  if Result = '' then Result := 'no material';
end;

function TExtruderLine.PolymerMu(I: Integer; T: Double): Double;
begin
  Result := Polymers[I].MuRef * Exp(-Polymers[I].B * (T - Polymers[I].TRef));
end;

function TExtruderLine.BlendMu(T: Double): Double;
var
  I: Integer;
  L: Double;
begin
  // logarithmic mixing rule
  L := 0;
  for I := 0 to MATS - 1 do L := L + Weight(I) * Ln(PolymerMu(I, T));
  Result := Exp(L);
end;

function TExtruderLine.MuEstimated: Double;
begin
  // what the two pressure sensors say: dP over the screen / (screen resistance * flow)
  if Qe > 1 then Result := DPScreen / (Rs * (1 + S) * Qe) else Result := 0;
end;

function TExtruderLine.Alarms: string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    if Tripped then L.Add('TRIPPED');
    if Overload then L.Add('MOTOR OVERLOAD');
    if ColdBlocked then L.Add('COLD START INTERLOCK');
    if Starving then L.Add('MELT PUMP STARVING');
    if Flooded then L.Add('EXTRUDER FLOODED');
    if Unmelt > 0.3 then L.Add('UNMELTED MATERIAL');
    if Degrading then L.Add('DEGRADATION');
    if S > 1.5 then L.Add('SCREEN BLOCKED');
    if P2 > 200 then L.Add('HIGH P2');
    L.Delimiter := '|';
    L.StrictDelimiter := True;
    Result := StringReplace(L.DelimitedText, '|', ' · ', [rfReplaceAll]);
  finally
    L.Free;
  end;
end;

{ ---------- commands ---------- }

procedure TExtruderLine.StartLine;
begin
  if Tripped then Exit;
  if not Running then AddEvent(leStart, 'LINE START');
  Running := True;
  ExtruderPID.Integ := ExtruderPID.Manual;
  DosingPID.Integ := 0;
end;

procedure TExtruderLine.StopLine;
begin
  if Running then AddEvent(leStop, 'LINE STOP');
  Running := False;
end;

procedure TExtruderLine.ChangeScreen;
begin
  S := 0;
  AddEvent(leScreenChanged, 'SCREEN CHANGED');
end;

procedure TExtruderLine.ResetTrip;
begin
  if Tripped and (P1 < 250) then
  begin
    Tripped := False;
    FOverloadTime := 0;
    AddEvent(leInfo, 'TRIP RESET');
  end;
end;

procedure TExtruderLine.AddEvent(AKind: TLineEventKind; const AText: string);
var
  I: Integer;
begin
  if Length(FEvents) >= 300 then
  begin
    for I := 1 to High(FEvents) do FEvents[I - 1] := FEvents[I];
    SetLength(FEvents, Length(FEvents) - 1);
  end;
  SetLength(FEvents, Length(FEvents) + 1);
  FEvents[High(FEvents)].T := SimTime;
  FEvents[High(FEvents)].Kind := AKind;
  FEvents[High(FEvents)].Text := AText;
end;

procedure TExtruderLine.ScheduleMetal;
begin
  FNextMetal := SimTime + 90 + Random * 180;
end;

{ ---------- simulation ---------- }

procedure TExtruderLine.SubStep(dt: Double);
var
  I: Integer;
  U, Tin, Mcp, NewT, DoseCmd, ExtCmd, Tm, Sh: Double;
  AnyCold: Boolean;
begin
  // ---- heater zones (heat / cool split range) ----
  Sh := Sqrt(Max(Mu, 0.05));
  Mcp := Qe / 3600 * Cp * MatShare;
  for I := 0 to ZONES - 1 do
  begin
    if HeatersOn then U := PIDStep(ZonePID[I], ZoneSP[I], Tz[I], dt)
    else
    begin
      U := 0;
      ZonePID[I].Output := 0;
      ZonePID[I].PrevPV := Tz[I];
    end;
    HeatW[I] := Pmax * Max(U, 0) / 100;
    CoolW[I] := Pcool * Max(-U, 0) / 100;
    LossW[I] := Lz * (Tz[I] - Tamb);
    if I = 0 then Tin := Tamb else Tin := Tz[I - 1];
    MatW[I] := Mcp * (Tz[I] - Tin);
    ShearW[I] := Ksh[I] * Ne * Sh;
    NewT := Tz[I] + (HeatW[I] - CoolW[I] - LossW[I] - MatW[I] + ShearW[I]) / Cz * dt;
    Tz[I] := NewT;
  end;

  // ---- melt temperature and viscosity ----
  Tmelt := 0.15 * Tz[2] + 0.30 * Tz[3] + 0.55 * Tz[4] + 0.06 * Ne * Sh;
  MuBase := BlendMu(Tmelt);
  Tm := BlendTm;
  Unmelt := EnsureRange((Tm + 20 - Tmelt) / 20, 0, 1);
  Degrading := Tmelt > BlendTdeg;
  Mu := MuBase * (1 + 4 * Sqr(Unmelt));
  if Degrading then Mu := Mu * 0.8;

  // ---- interlocks ----
  AnyCold := False;
  for I := 0 to ZONES - 1 do
    if Tz[I] < ZoneSP[I] - 15 then AnyCold := True;
  ColdBlocked := Running and ColdProtect and AnyCold;

  // ---- controllers for the screws (PV = P2) ----
  ExtCmd := PIDStep(ExtruderPID, P2SP, P2, dt);
  // dosing: with feed-forward the PID only trims (-50..+50 %), without it it is absolute
  if DosingFF then
  begin
    DosingPID.OutMin := -50;
    DosingPID.OutMax := 50;
    DosingFFPct := MeltPumpRpm * Cmp / (Cd * BlendBulk / 0.6);
  end
  else
  begin
    DosingPID.OutMin := 0;
    DosingPID.OutMax := 100;
    DosingFFPct := 0;
  end;
  if not DosingPID.Auto then DosingPID.Manual := EnsureRange(DosingPID.Manual, 0, 100);
  DoseCmd := PIDStep(DosingPID, P2SP, P2, dt);
  if DosingPID.Auto then DoseCmd := EnsureRange(DosingFFPct + DoseCmd, 0, 100)
  else DoseCmd := EnsureRange(DosingPID.Manual, 0, 100);
  if not Running or ColdBlocked or Tripped then
  begin
    ExtCmd := 0;
    DoseCmd := 0;
    // keep the loops from winding up while the screws are blocked
    ExtruderPID.Integ := Min(ExtruderPID.Integ, ExtruderPID.Manual);
    DosingPID.Integ := 0;
  end;
  // the motors follow with a small ramp
  Ne := Ne + (ExtCmd - Ne) * Min(1, dt / 1.5);
  Nd := Nd + (DoseCmd - Nd) * Min(1, dt / 1.0);

  // ---- dosing + metal detector ----
  if Running and (SimTime >= FNextMetal) then
  begin
    if MetalDetector then
    begin
      FRejectUntil := SimTime + 3;
      Inc(MetalRejects);
      AddEvent(leMetalRejected, 'METAL REJECTED');
    end
    else
    begin
      S := S + 0.35;
      Inc(MetalPassed);
      AddEvent(leMetalPassed, 'METAL HIT SCREEN');
    end;
    ScheduleMetal;
  end;
  if SimTime < FRejectUntil then Qd := 0
  else Qd := Cd * Nd * BlendBulk / 0.6;
  if BlendBulk <= 0 then Qd := 0;

  // ---- extruder output (drag flow - back flow) ----
  if Ne > 0.1 then
    Qe := Max(0, (Ce * Ne * F - Bk * P2 / Mu) / (1 + Bk * Rs * (1 + S)))
  else
    Qe := 0;
  // ---- fill of the screw ----
  F := F + (Qd - Qe) / (Minv * 3600) * dt;
  Flooded := F > 1;
  if F > 1 then F := 1;
  // anti-windup for the dosing loop: feeding more cannot raise P2 while the screw is full
  if Flooded and DosingPID.Auto and (DosingPID.Integ > -50) then
    DosingPID.Integ := DosingPID.Integ - 2 * dt;
  if F < 0 then F := 0;

  // ---- screen changer + pressures ----
  DPScreen := Rs * (1 + S) * Mu * Qe;
  // unmelted particles slowly block the screen
  S := S + 0.004 * Unmelt * Qe / 100 * dt;

  // ---- melt pump ----
  if Running and not Tripped then Qmp := Cmp * MeltPumpRpm else Qmp := 0;
  Starving := Running and (P2 <= 0.5) and (Qe < Qmp);
  P2 := P2 + Kc * (Qe - Qmp) / 3600 * dt;
  if P2 < 0 then
  begin
    P2 := 0;
    Qmp := Min(Qmp, Qe); // the pump can only deliver what it gets
  end;
  P1 := P2 + DPScreen;

  // ---- motor loads ----
  // extruder: mechanical power = viscous (shear) dissipation + pressure work + friction,
  // load = torque / rated torque = (P / N) / (Prated / Nrated)
  ShearTotalW := 0;
  for I := 0 to ZONES - 1 do ShearTotalW := ShearTotalW + ShearW[I];
  ShearTotalW := ShearTotalW * (0.4 + 0.6 * F);           // a starved screw shears less
  PressureWorkW := Qe / 3600 / Density * P1 * 1E5;          // m3/s * Pa
  MotorPowerW := ShearTotalW + PressureWorkW + FrictionW * Ne;
  if Ne > 1 then
    ExtLoad := (MotorPowerW / Ne) / (MotorRatedW / MotorRatedRpm) * 100
  else
    ExtLoad := 0;
  // dosing motor: mostly friction of the screw in the pellets
  if Nd > 0.5 then DoseLoad := 12 + 0.55 * Nd * BlendBulk / 0.6 else DoseLoad := 0;
  // melt pump: torque follows the pressure rise across the pump (die pressure - P2)
  P3 := Rdie * Mu * Qmp;
  if (Qmp > 0) and Running then PumpLoad := 10 + 0.3 * Max(0, P3 - P2) else PumpLoad := 0;

  Overload := ExtLoad > 110;
  if ExtLoad > 130 then FOverloadTime := FOverloadTime + dt else FOverloadTime := 0;
  if (FOverloadTime > 5) and not Tripped then
  begin
    Tripped := True;
    Running := False;
    AddEvent(leTrip, 'MOTOR OVERLOAD TRIP');
  end;

  // ---- safety ----
  if (P1 > 350) and not Tripped then
  begin
    Tripped := True;
    Running := False;
    AddEvent(leTrip, 'OVER-PRESSURE TRIP');
  end;

  TotalKg := TotalKg + Qmp / 3600 * dt;
  SimTime := SimTime + dt;
  if SimTime >= FNextSample then
  begin
    AddSample;
    FNextSample := SimTime + 1;
  end;
end;

procedure TExtruderLine.Step(ADt: Double);
var
  N, I: Integer;
begin
  N := Max(1, Round(ADt / 0.05));
  for I := 1 to N do SubStep(ADt / N);
end;

procedure TExtruderLine.AddSample;
var
  I: Integer;
begin
  with FHist[FHead] do
  begin
    T := SimTime;
    for I := 0 to ZONES - 1 do
    begin
      Tz[I] := Self.Tz[I];
      SPz[I] := ZoneSP[I];
    end;
    P1 := Self.P1;
    P2 := Self.P2;
    P2SP := Self.P2SP;
    Ne := Self.Ne;
    Nd := Self.Nd;
    Nmp := MeltPumpRpm;
    Qd := Self.Qd;
    Qe := Self.Qe;
    Qmp := Self.Qmp;
    Mu := Self.Mu;
    Tmelt := Self.Tmelt;
    S := Self.S;
    F := Self.F;
    ExtLoad := Self.ExtLoad;
    DoseLoad := Self.DoseLoad;
    PumpLoad := Self.PumpLoad;
    P3 := Self.P3;
  end;
  FHead := (FHead + 1) mod Length(FHist);
  if FCount < Length(FHist) then Inc(FCount);
end;

function TExtruderLine.HistoryCount: Integer;
begin
  Result := FCount;
end;

function TExtruderLine.Sample(AIndex: Integer): TLineSample;
begin
  Result := FHist[(FHead - FCount + AIndex + 2 * Length(FHist)) mod Length(FHist)];
end;

function TExtruderLine.EventCount: Integer;
begin
  Result := Length(FEvents);
end;

function TExtruderLine.Event(AIndex: Integer): TLineEvent;
begin
  Result := FEvents[AIndex];
end;

end.
