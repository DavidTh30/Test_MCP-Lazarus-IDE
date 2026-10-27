program ExtruderSimApp;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, ExtruderMain, ExtruderModel, BGRAView;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Extrusion Line PID Simulator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormExtruder, FormExtruder);
  Application.Run;
end.
