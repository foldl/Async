unit formu;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, IntfGraphics, FPReadPNG, GraphType;

type

  { TForm1 }

  TForm1 = class(TForm)
    Button1: TButton;
    Image1: TImage;
    Memo1: TMemo;
    procedure Button1Click(Sender: TObject);
  private
    procedure RunDone(Param: Pointer);
    procedure ImageDone(Param: Pointer);
    procedure ForEachDone(Param: Pointer);
    procedure LogTime(const Msg: string);
  public
    { public declarations }
  end;

var
  Form1: TForm1;

implementation

uses
  Async, fphttpclient;

type

  TDownloadImage = record
    URI: string;
    Img: TLazIntfImage;
    S: string;
  end;
  PDownloadImage = ^TDownloadImage;

procedure Run(Param: Pointer);
begin
  Sleep(Integer(Param));
end;

procedure Run2(Param: PInteger);
begin
  Sleep(Param^);
end;

procedure Download(Param: PDownloadImage);
var
  S: TStringStream = nil;
begin
  try
    S := TStringStream.Create(TFPCustomHTTPClient.SimpleGet(Param^.URI));
    S.Position := 0;
    Param^.Img.LoadFromStream(S);
  finally
    S.Free;
  end;
end;

{$R *.lfm}

{ TForm1 }

procedure TForm1.Button1Click(Sender: TObject);
var
  Image: PDownloadImage;
  A: PInteger;
begin
  Image1.Picture.Clear;
  New(Image);
  Image^.URI := 'http://images.newsmth.net/nForum/img/legal/hdfj.jpg';
  Image^.Img := TLazIntfImage.Create(0, 0, [riqfRGB, riqfAlpha]);
  A := PInteger(Getmem(4 * SizeOf(Integer)));
  A[0] := 2000; A[1] := 3000; A[2] := 1000; A[3] := 4000;

  LogTime('Start sleep task (5sec)');
  AsyncCall(@Run, Pointer(5000), @RunDone, nil);

  LogTime('Start download task');
  AsyncCall(TAsyncFun(@Download), Image, @ImageDone, Image);

  LogTime('Start ForEach task');
  AsyncForEach(TAsyncFun(@Run2), A, 4, SizeOf(Integer), @ForEachDone, A, ['PoolSize', 4]);
end;

procedure TForm1.RunDone(Param: Pointer);
begin
  LogTime('Sleep task done.');
end;

procedure TForm1.ImageDone(Param: Pointer);
var
  Image: PDownloadImage;
begin
  Image := PDownloadImage(Param);
  LogTime('image downloaded');
  Image1.Picture.Assign(Image^.Img);
  Image^.Img.Free;
  Dispose(Image);
end;

procedure TForm1.ForEachDone(Param: Pointer);
begin
  LogTime('ForEach Done');
  Freemem(Param);
end;

procedure TForm1.LogTime(const Msg: string);
begin
  Memo1.Lines.Add(FormatDateTime('hh:nn:ss.z', Now) + ': ' + Msg);
end;

end.

