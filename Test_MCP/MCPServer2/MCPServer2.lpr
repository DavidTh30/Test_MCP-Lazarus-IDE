program MCPServer2;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, IoMain;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'MCP Server 2 - IO Device';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormIO, FormIO);
  Application.Run;
end.
