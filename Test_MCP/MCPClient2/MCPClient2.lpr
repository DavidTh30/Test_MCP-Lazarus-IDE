program MCPClient2;

{ MCP Client 2 : same screen as MCPClient but compiled with -dCLIENT2
  -> node id = client-2, control port = 8776, connects to server-2 by default }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, MainForm in '..\MCPClient\mainform.pas', McpClientCore;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'MCP Client 2';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormClient, FormClient);
  Application.Run;
end.
