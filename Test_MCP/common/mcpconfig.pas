unit McpConfig;

{ MCP communication settings (Server + Client), stored in <exe>.ini next to the exe }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, fpjson, jsonparser;

type
  TMcpSettings = record
    // Server
    Enabled: Boolean;      // start the server when the program starts
    Address: string;       // 127.0.0.1 = this machine only, 0.0.0.0 = every network
    Port: Word;
    Endpoint: string;      // path, e.g. /mcp
    ServerName: string;    // serverInfo.name returned to clients
    // Client (Claude Code)
    ClientName: string;    // server name in .mcp.json
    ClientTimeout: Integer; // ms for the Test connection button
    // Log
    LogToFile: Boolean;
    VerboseLog: Boolean;   // log request/response bodies
    MaxLogLines: Integer;
    // Node / Topology
    NodeId: string;        // e.g. server-1
    NodeName: string;      // display name
    Peers: string;         // id@host:port,... whose status is drawn in the Topology
    Instructions: string;  // instructions text returned on initialize (not saved)
    // Uplink: this server connects to another server as a client (server-1 -> server-2)
    UplinkEnabled: Boolean;
    Uplink: string;        // node id or URL
  end;

function DefaultSettings: TMcpSettings;
function SettingsFileName: string;
procedure LoadSettings(var S: TMcpSettings);
procedure SaveSettings(const S: TMcpSettings);
function SettingsToJSON(const S: TMcpSettings): TJSONObject;

{ URL used by clients (0.0.0.0 -> 127.0.0.1) }
function ClientUrl(const S: TMcpSettings): string;
function ClaudeAddCommand(const S: TMcpSettings): string;
{ Write / merge an entry into <ADir>\.mcp.json, returns the file name }
function WriteMcpJson(const S: TMcpSettings; const ADir: string): string;

implementation

function DefaultSettings: TMcpSettings;
begin
  Result.Enabled := True;
  Result.Address := '127.0.0.1';
  Result.Port := 8765;
  Result.Endpoint := '/mcp';
  Result.ServerName := 'lazarus-form';
  Result.ClientName := 'lazarus-form';
  Result.ClientTimeout := 3000;
  Result.LogToFile := True;
  Result.VerboseLog := False;
  Result.MaxLogLines := 500;
  Result.NodeId := 'server-1';
  Result.NodeName := 'Form Designer';
  Result.Peers := 'server-1@127.0.0.1:8765,server-2@127.0.0.1:8766,' +
    'client-1@127.0.0.1:8775,client-2@127.0.0.1:8776';
  Result.UplinkEnabled := False;
  Result.Uplink := '';
  Result.Instructions := 'This server controls a live Lazarus (LCL) form window. ' +
    'Use get_form to inspect, add_control / set_property to build UI, ' +
    'screenshot to see the result, and get_status for server diagnostics.';
end;

function CmdArg(const AName, ADefault: string): string;
var
  I: Integer;
  Prefix: string;
begin
  Result := ADefault;
  Prefix := '--' + AName + '=';
  for I := 1 to ParamCount do
    if Pos(Prefix, ParamStr(I)) = 1 then
      Exit(Copy(ParamStr(I), Length(Prefix) + 1, MaxInt));
end;

function SettingsFileName: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

function NormEndpoint(const E: string): string;
begin
  Result := Trim(E);
  if Result = '' then Result := '/mcp';
  if Result[1] <> '/' then Result := '/' + Result;
end;

procedure LoadSettings(var S: TMcpSettings);
var
  Ini: TIniFile;
begin
  // the values passed in S are the defaults of that program
  if FileExists(SettingsFileName) then
  begin
    Ini := TIniFile.Create(SettingsFileName);
    try
      S.NodeId := Ini.ReadString('Node', 'Id', S.NodeId);
      S.NodeName := Ini.ReadString('Node', 'Name', S.NodeName);
      S.Peers := Ini.ReadString('Topology', 'Peers', S.Peers);
      S.Enabled := Ini.ReadBool('Server', 'Enabled', S.Enabled);
      S.Address := Ini.ReadString('Server', 'Address', S.Address);
      S.Port := Ini.ReadInteger('Server', 'Port', S.Port);
      S.Endpoint := NormEndpoint(Ini.ReadString('Server', 'Endpoint', S.Endpoint));
      S.ServerName := Ini.ReadString('Server', 'Name', S.ServerName);
      S.ClientName := Ini.ReadString('Client', 'Name', S.ClientName);
      S.ClientTimeout := Ini.ReadInteger('Client', 'Timeout', S.ClientTimeout);
      S.LogToFile := Ini.ReadBool('Log', 'ToFile', S.LogToFile);
      S.VerboseLog := Ini.ReadBool('Log', 'Verbose', S.VerboseLog);
      S.MaxLogLines := Ini.ReadInteger('Log', 'MaxLines', S.MaxLogLines);
      S.UplinkEnabled := Ini.ReadBool('Uplink', 'Enabled', S.UplinkEnabled);
      S.Uplink := Ini.ReadString('Uplink', 'Target', S.Uplink);
    finally
      Ini.Free;
    end;
  end;
  // the command line overrides the ini (not saved): --port= --address= --node= --name= --peers=
  S.Port := StrToIntDef(CmdArg('port', ''), S.Port);
  S.Address := CmdArg('address', S.Address);
  S.NodeId := CmdArg('node', S.NodeId);
  S.NodeName := CmdArg('name', S.NodeName);
  S.Peers := CmdArg('peers', S.Peers);
end;

procedure SaveSettings(const S: TMcpSettings);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(SettingsFileName);
  try
    Ini.WriteBool('Server', 'Enabled', S.Enabled);
    Ini.WriteString('Server', 'Address', S.Address);
    Ini.WriteInteger('Server', 'Port', S.Port);
    Ini.WriteString('Server', 'Endpoint', NormEndpoint(S.Endpoint));
    Ini.WriteString('Server', 'Name', S.ServerName);
    Ini.WriteString('Client', 'Name', S.ClientName);
    Ini.WriteInteger('Client', 'Timeout', S.ClientTimeout);
    Ini.WriteBool('Log', 'ToFile', S.LogToFile);
    Ini.WriteBool('Log', 'Verbose', S.VerboseLog);
    Ini.WriteInteger('Log', 'MaxLines', S.MaxLogLines);
    Ini.WriteString('Node', 'Id', S.NodeId);
    Ini.WriteString('Node', 'Name', S.NodeName);
    Ini.WriteString('Topology', 'Peers', S.Peers);
    Ini.WriteBool('Uplink', 'Enabled', S.UplinkEnabled);
    Ini.WriteString('Uplink', 'Target', S.Uplink);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function SettingsToJSON(const S: TMcpSettings): TJSONObject;
begin
  Result := TJSONObject.Create([
    'enabled', S.Enabled, 'address', S.Address, 'port', S.Port,
    'endpoint', S.Endpoint, 'serverName', S.ServerName,
    'clientName', S.ClientName, 'clientTimeoutMs', S.ClientTimeout,
    'logToFile', S.LogToFile, 'verboseLog', S.VerboseLog,
    'maxLogLines', S.MaxLogLines, 'nodeId', S.NodeId, 'nodeName', S.NodeName,
    'peers', S.Peers, 'uplinkEnabled', S.UplinkEnabled, 'uplink', S.Uplink,
    'iniFile', SettingsFileName]);
end;

function ClientUrl(const S: TMcpSettings): string;
var
  Host: string;
begin
  Host := S.Address;
  if (Host = '') or (Host = '0.0.0.0') then Host := '127.0.0.1';
  Result := Format('http://%s:%d%s', [Host, S.Port, NormEndpoint(S.Endpoint)]);
end;

function ClaudeAddCommand(const S: TMcpSettings): string;
begin
  Result := Format('claude mcp add --transport http %s %s', [S.ClientName, ClientUrl(S)]);
end;

function WriteMcpJson(const S: TMcpSettings; const ADir: string): string;
var
  Root, Servers: TJSONObject;
  Data: TJSONData;
  SL: TStringList;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + '.mcp.json';
  Root := nil;
  SL := TStringList.Create;
  try
    if FileExists(Result) then
    begin
      SL.LoadFromFile(Result);
      try
        Data := GetJSON(SL.Text);
        if Data is TJSONObject then Root := TJSONObject(Data) else Data.Free;
      except
        Root := nil; // broken file -> create a new one
      end;
    end;
    if Root = nil then Root := TJSONObject.Create;

    Servers := Root.Find('mcpServers', jtObject) as TJSONObject;
    if Servers = nil then
    begin
      Servers := TJSONObject.Create;
      Root.Add('mcpServers', Servers);
    end;
    if Servers.IndexOfName(S.ClientName) >= 0 then Servers.Delete(S.ClientName);
    Servers.Add(S.ClientName, TJSONObject.Create(['type', 'http', 'url', ClientUrl(S)]));

    SL.Text := Root.FormatJSON;
    SL.SaveToFile(Result);
  finally
    Root.Free;
    SL.Free;
  end;
end;

end.
