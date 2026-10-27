program MCPClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, MainForm, McpClientCore;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'MCP Client';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormClient, FormClient);
  Application.Run;
end.
