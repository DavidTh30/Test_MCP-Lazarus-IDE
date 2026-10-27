program HeaterSimApp;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, HeaterMain, HeaterModel, BGRAView;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Heater Simulator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormHeater, FormHeater);
  Application.Run;
end.
