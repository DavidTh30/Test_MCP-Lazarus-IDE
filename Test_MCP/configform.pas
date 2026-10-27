unit ConfigForm;

{ MCP > Config : adjust the communication settings of the Server (this program) and the Client (Claude Code) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Spin, Clipbrd,
  fpjson, jsonparser, fphttpclient, McpConfig;

type

  { TFormConfig }

  TFormConfig = class(TForm)
    btnCancel: TButton;
    btnCopyCmd: TButton;
    btnOK: TButton;
    btnTest: TButton;
    btnWriteMcpJson: TButton;
    cbAddress: TComboBox;
    chkEnabled: TCheckBox;
    chkLogToFile: TCheckBox;
    chkVerbose: TCheckBox;
    edClientName: TEdit;
    edCmd: TEdit;
    edEndpoint: TEdit;
    edServerName: TEdit;
    edUrl: TEdit;
    gbClient: TGroupBox;
    gbLog: TGroupBox;
    gbNode: TGroupBox;
    gbServer: TGroupBox;
    lblNodeId: TLabel;
    lblNodeName: TLabel;
    lblPeers: TLabel;
    edNodeId: TEdit;
    edNodeName: TEdit;
    edPeers: TEdit;
    chkUplink: TCheckBox;
    edUplink: TEdit;
    lblAddress: TLabel;
    lblClientName: TLabel;
    lblCmd: TLabel;
    lblEndpoint: TLabel;
    lblHint: TLabel;
    lblMaxLines: TLabel;
    lblPort: TLabel;
    lblServerName: TLabel;
    lblTimeout: TLabel;
    lblUrl: TLabel;
    seMaxLines: TSpinEdit;
    sePort: TSpinEdit;
    seTimeout: TSpinEdit;
    dlgSelectDir: TSelectDirectoryDialog;
    procedure btnCopyCmdClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure btnTestClick(Sender: TObject);
    procedure btnWriteMcpJsonClick(Sender: TObject);
    procedure SettingChanged(Sender: TObject);
  private
    FLoading: Boolean;
    FBase: TMcpSettings;
    function Current: TMcpSettings;
  public
    procedure LoadFrom(const S: TMcpSettings);
    function GetSettings: TMcpSettings;
  end;

{ Show the Config window modally; returns True when OK was pressed }
function EditMcpSettings(var S: TMcpSettings): Boolean;

implementation

{$R *.lfm}

function EditMcpSettings(var S: TMcpSettings): Boolean;
var
  F: TFormConfig;
begin
  F := TFormConfig.Create(nil);
  try
    F.LoadFrom(S);
    Result := F.ShowModal = mrOK;
    if Result then S := F.GetSettings;
  finally
    F.Free;
  end;
end;

{ TFormConfig }

procedure TFormConfig.LoadFrom(const S: TMcpSettings);
begin
  FLoading := True;
  try
    chkEnabled.Checked := S.Enabled;
    cbAddress.Text := S.Address;
    sePort.Value := S.Port;
    edEndpoint.Text := S.Endpoint;
    edServerName.Text := S.ServerName;
    edClientName.Text := S.ClientName;
    seTimeout.Value := S.ClientTimeout;
    chkLogToFile.Checked := S.LogToFile;
    chkVerbose.Checked := S.VerboseLog;
    seMaxLines.Value := S.MaxLogLines;
    edNodeId.Text := S.NodeId;
    edNodeName.Text := S.NodeName;
    edPeers.Text := S.Peers;
    chkUplink.Checked := S.UplinkEnabled;
    edUplink.Text := S.Uplink;
    FBase := S;
  finally
    FLoading := False;
  end;
  SettingChanged(nil);
end;

function TFormConfig.Current: TMcpSettings;
begin
  Result := FBase; // keep values that are not on this screen (e.g. Instructions)
  Result.NodeId := Trim(edNodeId.Text);
  Result.NodeName := Trim(edNodeName.Text);
  Result.Peers := Trim(edPeers.Text);
  Result.UplinkEnabled := chkUplink.Checked;
  Result.Uplink := Trim(edUplink.Text);
  Result.Enabled := chkEnabled.Checked;
  Result.Address := Trim(cbAddress.Text);
  Result.Port := sePort.Value;
  Result.Endpoint := Trim(edEndpoint.Text);
  if Result.Endpoint = '' then Result.Endpoint := '/mcp';
  if Result.Endpoint[1] <> '/' then Result.Endpoint := '/' + Result.Endpoint;
  Result.ServerName := Trim(edServerName.Text);
  Result.ClientName := Trim(edClientName.Text);
  Result.ClientTimeout := seTimeout.Value;
  Result.LogToFile := chkLogToFile.Checked;
  Result.VerboseLog := chkVerbose.Checked;
  Result.MaxLogLines := seMaxLines.Value;
end;

function TFormConfig.GetSettings: TMcpSettings;
begin
  Result := Current;
end;

procedure TFormConfig.SettingChanged(Sender: TObject);
var
  S: TMcpSettings;
begin
  if FLoading then Exit;
  S := Current;
  edUrl.Text := ClientUrl(S);
  edCmd.Text := ClaudeAddCommand(S);
  if S.Address = '0.0.0.0' then
    lblHint.Caption := 'Warning: 0.0.0.0 lets other machines on the network connect (no authentication)'
  else
    lblHint.Caption := 'Press OK to save to ' + ExtractFileName(SettingsFileName) + ' and restart the server';
end;

procedure TFormConfig.btnOKClick(Sender: TObject);
var
  S: TMcpSettings;
begin
  S := Current;
  if S.Address = '' then
  begin
    MessageDlg('Please enter an address', mtWarning, [mbOK], 0);
    ModalResult := mrNone;
    Exit;
  end;
  if (S.ServerName = '') or (S.ClientName = '') then
  begin
    MessageDlg('Please enter both the server name and the client name', mtWarning, [mbOK], 0);
    ModalResult := mrNone;
    Exit;
  end;
  ModalResult := mrOK;
end;

procedure TFormConfig.btnCopyCmdClick(Sender: TObject);
begin
  Clipboard.AsText := edCmd.Text;
end;

procedure TFormConfig.btnWriteMcpJsonClick(Sender: TObject);
var
  FN: string;
begin
  dlgSelectDir.InitialDir := ExtractFilePath(ParamStr(0));
  if not dlgSelectDir.Execute then Exit;
  FN := WriteMcpJson(Current, dlgSelectDir.FileName);
  MessageDlg('File written:' + LineEnding + FN + LineEnding + LineEnding +
    'Open Claude Code in that folder and approve the server "' + Current.ClientName + '"',
    mtInformation, [mbOK], 0);
end;

procedure TFormConfig.btnTestClick(Sender: TObject);
var
  Http: TFPHTTPClient;
  Body: TStringStream;
  Resp: string;
  Data: TJSONData;
  Info: string;
begin
  Screen.Cursor := crHourGlass;
  Http := TFPHTTPClient.Create(nil);
  Body := TStringStream.Create(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"' +
    '2025-06-18","capabilities":{},"clientInfo":{"name":"config-test","version":"1"}}}');
  try
    try
      Http.ConnectTimeout := seTimeout.Value;
      Http.IOTimeout := seTimeout.Value;
      Http.AddHeader('Content-Type', 'application/json');
      Http.AddHeader('Accept', 'application/json, text/event-stream');
      Http.RequestBody := Body;
      Resp := Http.Post(edUrl.Text);
      Info := 'HTTP ' + IntToStr(Http.ResponseStatusCode);
      Data := GetJSON(Resp);
      try
        Info := Info + LineEnding + 'server: ' +
          Data.FindPath('result.serverInfo.name').AsString + ' ' +
          Data.FindPath('result.serverInfo.version').AsString + LineEnding +
          'protocol: ' + Data.FindPath('result.protocolVersion').AsString;
      finally
        Data.Free;
      end;
      MessageDlg('Connection succeeded', Info, mtInformation, [mbOK], 0);
    except
      on E: Exception do
        MessageDlg('Connection failed', edUrl.Text + LineEnding + E.Message +
          LineEnding + LineEnding + '(if you just changed the settings, press OK first so the server restarts)',
          mtError, [mbOK], 0);
    end;
  finally
    Body.Free;
    Http.Free;
    Screen.Cursor := crDefault;
  end;
end;

end.
