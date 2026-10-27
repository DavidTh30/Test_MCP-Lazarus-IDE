unit StatusForm;

{ MCP > Status : shows every piece of status of the MCP server / client / form
  The same data as the "get_status" tool (JSON), for further development }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, ValEdit, Grids, Clipbrd, fpjson;

type

  { TFormStatus }

  TFormStatus = class(TForm)
    btnClearLog: TButton;
    btnClose: TButton;
    btnCopyJson: TButton;
    btnRefresh: TButton;
    btnSaveJson: TButton;
    btnStartStop: TButton;
    chkAuto: TCheckBox;
    dlgSave: TSaveDialog;
    memJson: TMemo;
    memLog: TMemo;
    PageControl1: TPageControl;
    pnlButtons: TPanel;
    pnlState: TPanel;
    tmrRefresh: TTimer;
    tsJson: TTabSheet;
    tsLog: TTabSheet;
    tsOverview: TTabSheet;
    tsTools: TTabSheet;
    vleOverview: TValueListEditor;
    vleTools: TValueListEditor;
    procedure btnClearLogClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
    procedure btnCopyJsonClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnSaveJsonClick(Sender: TObject);
    procedure btnStartStopClick(Sender: TObject);
    procedure chkAutoChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure tmrRefreshTimer(Sender: TObject);
  private
    FLogVersion: Integer;
    FJsonText: string;
    procedure Flatten(AData: TJSONData; const APrefix: string; AOut: TStrings);
    procedure FillGrid(AGrid: TValueListEditor; AItems: TStrings);
  public
    procedure RefreshStatus;
  end;

var
  FormStatus: TFormStatus;

{ Show / focus the Status window (non-modal) }
procedure ShowMcpStatus;

implementation

uses
  Unit1;

{$R *.lfm}

procedure ShowMcpStatus;
begin
  if FormStatus = nil then
    FormStatus := TFormStatus.Create(Application);
  FormStatus.Show;
  FormStatus.BringToFront;
end;

{ TFormStatus }

procedure TFormStatus.FormCreate(Sender: TObject);
begin
  vleOverview.Options := vleOverview.Options - [goEditing] + [goColSizing];
  vleTools.Options := vleTools.Options - [goEditing];
  FLogVersion := -1;
end;

procedure TFormStatus.FormShow(Sender: TObject);
begin
  RefreshStatus;
end;

procedure TFormStatus.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
end;

procedure TFormStatus.Flatten(AData: TJSONData; const APrefix: string; AOut: TStrings);
var
  I: Integer;
  Key, S: string;
begin
  case AData.JSONType of
    jtObject:
      for I := 0 to AData.Count - 1 do
      begin
        Key := TJSONObject(AData).Names[I];
        if APrefix <> '' then Key := APrefix + '.' + Key;
        Flatten(AData.Items[I], Key, AOut);
      end;
    jtArray:
      begin
        S := '';
        for I := 0 to AData.Count - 1 do
        begin
          if S <> '' then S := S + ', ';
          if AData.Items[I].JSONType in [jtObject, jtArray] then
            S := S + AData.Items[I].AsJSON
          else
            S := S + AData.Items[I].AsString;
        end;
        AOut.Add(APrefix + '=' + S);
      end;
    jtNull:
      AOut.Add(APrefix + '=');
  else
    AOut.Add(APrefix + '=' + AData.AsString);
  end;
end;

procedure TFormStatus.FillGrid(AGrid: TValueListEditor; AItems: TStrings);
var
  TopRow: Integer;
begin
  TopRow := AGrid.TopRow;
  AGrid.BeginUpdate;
  try
    AGrid.Strings.Assign(AItems);
  finally
    AGrid.EndUpdate;
  end;
  if TopRow < AGrid.RowCount then AGrid.TopRow := TopRow;
end;

procedure TFormStatus.RefreshStatus;
var
  Root: TJSONObject;
  Tools: TJSONData;
  L: TStringList;
  State: string;
begin
  if Form1 = nil then Exit;
  Root := Form1.BuildStatusJSON;
  L := TStringList.Create;
  try
    // Overview (without the per-tool counters)
    Tools := Root.FindPath('server.toolCounts');
    if Tools <> nil then Tools := Tools.Clone;
    TJSONObject(Root.Objects['server']).Delete('toolCounts');
    Flatten(Root, '', L);
    FillGrid(vleOverview, L);

    // Tools
    L.Clear;
    if Tools <> nil then
    begin
      Flatten(Tools, '', L);
      TJSONObject(Root.Objects['server']).Add('toolCounts', Tools);
    end;
    FillGrid(vleTools, L);

    // JSON
    FJsonText := Root.FormatJSON;
    if memJson.Text <> FJsonText then memJson.Text := FJsonText;

    // State bar
    State := Root.FindPath('server.state').AsString;
    pnlState.Caption := '  MCP: ' + State + '   ' + Root.FindPath('server.url').AsString;
    if State = 'Running' then pnlState.Color := $00C8F0C8
    else if State = 'Error' then pnlState.Color := $00C8C8F8
    else pnlState.Color := $00D8E8F0;
    if (State = 'Running') or (State = 'Starting') then
      btnStartStop.Caption := 'Stop server'
    else
      btnStartStop.Caption := 'Start server';
  finally
    L.Free;
    Root.Free;
  end;

  // Log (only refreshed when there are new lines)
  if FLogVersion <> Form1.LogVersion then
  begin
    FLogVersion := Form1.LogVersion;
    memLog.Lines.Assign(Form1.LogLines);
    memLog.SelStart := Length(memLog.Text);
  end;
end;

procedure TFormStatus.tmrRefreshTimer(Sender: TObject);
begin
  if Visible then RefreshStatus;
end;

procedure TFormStatus.chkAutoChange(Sender: TObject);
begin
  tmrRefresh.Enabled := chkAuto.Checked;
end;

procedure TFormStatus.btnRefreshClick(Sender: TObject);
begin
  RefreshStatus;
end;

procedure TFormStatus.btnStartStopClick(Sender: TObject);
begin
  if Form1.ServerActive then Form1.StopServer else Form1.StartServer;
  RefreshStatus;
end;

procedure TFormStatus.btnCopyJsonClick(Sender: TObject);
begin
  RefreshStatus;
  Clipboard.AsText := FJsonText;
end;

procedure TFormStatus.btnSaveJsonClick(Sender: TObject);
var
  SL: TStringList;
begin
  RefreshStatus;
  dlgSave.FileName := 'mcp-status.json';
  if not dlgSave.Execute then Exit;
  SL := TStringList.Create;
  try
    SL.Text := FJsonText;
    SL.SaveToFile(dlgSave.FileName);
  finally
    SL.Free;
  end;
end;

procedure TFormStatus.btnClearLogClick(Sender: TObject);
begin
  Form1.ClearLog;
  RefreshStatus;
end;

procedure TFormStatus.btnCloseClick(Sender: TObject);
begin
  Close;
end;

end.
