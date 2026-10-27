unit McpTools;

{ Helpers to declare tools (JSON schema) and read their arguments }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

function Prop(const AType, ADesc: string): TJSONObject;
function Tool(const AName, ADesc: string; AProps: TJSONObject;
  const ARequired: array of string): TJSONObject;

function HasArg(AArgs: TJSONObject; const AKey: string): Boolean;
function ArgStr(AArgs: TJSONObject; const AKey: string; const ADef: string = ''): string;
function ArgInt(AArgs: TJSONObject; const AKey: string; ADef: Integer): Integer;
function ArgFloat(AArgs: TJSONObject; const AKey: string; ADef: Double): Double;
function ArgBool(AArgs: TJSONObject; const AKey: string; ADef: Boolean): Boolean;

implementation

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

function HasArg(AArgs: TJSONObject; const AKey: string): Boolean;
begin
  Result := (AArgs <> nil) and (AArgs.Find(AKey) <> nil) and
    (AArgs.Find(AKey).JSONType <> jtNull);
end;

function ArgStr(AArgs: TJSONObject; const AKey: string; const ADef: string): string;
begin
  if HasArg(AArgs, AKey) then Result := AArgs.Find(AKey).AsString else Result := ADef;
end;

function ArgInt(AArgs: TJSONObject; const AKey: string; ADef: Integer): Integer;
var
  D: TJSONData;
begin
  if not HasArg(AArgs, AKey) then Exit(ADef);
  D := AArgs.Find(AKey);
  if D.JSONType = jtNumber then Result := D.AsInteger
  else Result := StrToIntDef(D.AsString, ADef);
end;

function ArgFloat(AArgs: TJSONObject; const AKey: string; ADef: Double): Double;
var
  D: TJSONData;
begin
  if not HasArg(AArgs, AKey) then Exit(ADef);
  D := AArgs.Find(AKey);
  if D.JSONType = jtNumber then Result := D.AsFloat
  else Result := StrToFloatDef(D.AsString, ADef, DefaultFormatSettings);
end;

function ArgBool(AArgs: TJSONObject; const AKey: string; ADef: Boolean): Boolean;
var
  D: TJSONData;
begin
  if not HasArg(AArgs, AKey) then Exit(ADef);
  D := AArgs.Find(AKey);
  case D.JSONType of
    jtBoolean: Result := D.AsBoolean;
    jtNumber: Result := D.AsInteger <> 0;
  else
    Result := StrToBoolDef(D.AsString, ADef);
  end;
end;

end.
