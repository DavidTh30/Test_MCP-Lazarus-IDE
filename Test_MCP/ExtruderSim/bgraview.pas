unit BGRAView;

{ A control that is painted with BGRABitmap through the OnRender event.
  Full repaint every time -> no background erase, no flicker. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, BGRABitmap, BGRABitmapTypes;

type
  TBGRARenderEvent = procedure(Sender: TObject; B: TBGRABitmap) of object;

  { TBGRAView }

  TBGRAView = class(TCustomControl)
  private
    FOnRender: TBGRARenderEvent;
    FBackground: TBGRAPixel;
  protected
    procedure Paint; override;
    procedure EraseBackground(DC: HDC); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Background: TBGRAPixel read FBackground write FBackground;
    property OnRender: TBGRARenderEvent read FOnRender write FOnRender;
    property OnMouseMove;
    property OnMouseDown;
    property OnMouseLeave;
  end;

implementation

constructor TBGRAView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FBackground := BGRA(246, 248, 252);
end;

procedure TBGRAView.EraseBackground(DC: HDC);
begin
  // everything is drawn in Paint
end;

procedure TBGRAView.Paint;
var
  B: TBGRABitmap;
begin
  if (Width <= 0) or (Height <= 0) then Exit;
  B := TBGRABitmap.Create(Width, Height, FBackground);
  try
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    if Assigned(FOnRender) then FOnRender(Self, B);
    B.Draw(Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

end.
