unit Async;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type

  // Contract: TAsyncFun/TAsyncNotify should not have anything to do with VCL/LCL, while TAsyncCallObjectNotify can.
  TAsyncFun = procedure(Param: Pointer);
  TAsyncObjectNotify = procedure(Param: Pointer) of object;
  TAsyncNotify = procedure(Param: Pointer);


procedure AsyncCall(Fun: TAsyncFun; FunParam: Pointer;
  Notify: TAsyncObjectNotify; NotifyParam: Pointer); overload;
procedure AsyncCall(Fun: TAsyncFun; FunParam: Pointer;
  Notify: TAsyncNotify; NotifyParam: Pointer); overload;

// Options can be specified in Cfg:
//   GroupSize: number of elements in a group that is processed by a worker thread
//   PoolSize : number of worker threads
procedure AsyncForEach(Fun: TAsyncFun;
  ParamArray: Pointer; const ArrayLength, ParamSize: Cardinal;
  Notify: TAsyncNotify; NotifyParam: Pointer); overload;
procedure AsyncForEach(Fun: TAsyncFun;
  ParamArray: Pointer; const ArrayLength, ParamSize: Cardinal;
  Notify: TAsyncObjectNotify; NotifyParam: Pointer); overload;
procedure AsyncForEach(Fun: TAsyncFun;
  ParamArray: Pointer; const ArrayLength, ParamSize: Cardinal;
  Notify: TAsyncNotify; NotifyParam: Pointer; Cfg: array of Variant); overload;
procedure AsyncForEach(Fun: TAsyncFun;
  ParamArray: Pointer; const ArrayLength, ParamSize: Cardinal;
  Notify: TAsyncObjectNotify; NotifyParam: Pointer; Cfg: array of Variant); overload;

function PropListGet(Field: variant; Def: variant; Cfg: array of Variant): Variant;

implementation

var
  DefaultPoolSize: Integer = 2;

type

  { TAsyncObjNotifyClass }

  TAsyncObjNotifyClass = class
  private
    FNotify: TAsyncObjectNotify;
    FNotifyParam: Pointer;
    procedure Call;
  end;

  { TAsyncCallThread }

  TAsyncCallThread = class(TThread)
  private
    FFun: TAsyncFun;
    FFunParam: Pointer;
    FNotify: TAsyncNotify;
    FNotifyParam: Pointer;
    procedure DoNotify;
  public
    constructor Create(Fun: TAsyncFun; FunParam: Pointer;
      Notify: TAsyncNotify; NotifyParam: Pointer);
  protected
    procedure Execute; override;
  end;

procedure CallAsyncObjNotify(Param: Pointer);
var
  P: TAsyncObjNotifyClass;
  M: TThreadMethod;
begin
  P := TAsyncObjNotifyClass(Param);
  if Assigned(P) then
  begin
    M := P.Call;
    TThread.Synchronize(nil, M);
    P.Free;
  end;
end;

{ TAsyncObjNotifyClass }

procedure TAsyncObjNotifyClass.Call;
begin
  if Assigned(FNotify) then FNotify(FNotifyParam);
end;

{ TAsyncWhileThread }

procedure TAsyncCallThread.DoNotify;
begin
  FNotify(FNotifyParam);
end;

constructor TAsyncCallThread.Create(Fun: TAsyncFun; FunParam: Pointer;
  Notify: TAsyncNotify; NotifyParam: Pointer);
begin
  inherited Create(True);
  FFun := Fun;
  FFunParam := FunParam;
  FNotify := Notify;
  FNotifyParam := NotifyParam;
  FreeOnTerminate := True;
  Suspended := False;
end;

procedure TAsyncCallThread.Execute;
label
  Quit;
begin
  if @FFun = nil then
    goto Quit;
  try
    FFun(FFunParam);
  except
  end;

Quit:
  if Assigned(FNotify) then
    DoNotify;
end;

function ExcludeFileExt(FileName: string): string;
var
  i: longint;
  EndSep: set of char;
begin
  I := Length(FileName);
  EndSep := AllowDirectorySeparators + AllowDriveSeparators + [ExtensionSeparator];
  while (I > 0) and not (FileName[I] in EndSep) do
    Dec(I);
  if (I > 0) and (FileName[I] = ExtensionSeparator) then
    Result := Copy(FileName, 1, I - 1)
  else
    Result := FileName;
end;

procedure AsyncCall(Fun: TAsyncFun; FunParam: Pointer;
  Notify: TAsyncObjectNotify; NotifyParam: Pointer);
var
  P: TAsyncObjNotifyClass;
begin
  P := TAsyncObjNotifyClass.Create;
  P.FNotifyParam := NotifyParam;
  P.FNotify := Notify;
  AsyncCall(Fun, FunParam, @CallAsyncObjNotify, P);
end;

procedure AsyncCall(Fun: TAsyncFun; FunParam: Pointer;
  Notify: TAsyncNotify; NotifyParam: Pointer);
begin
  TAsyncCallThread.Create(Fun, FunParam, Notify, NotifyParam);
end;

type
  // let's write something portable:
  // RTLEventWaitFor could only wait for one object
  // so, worker thread, when a worker done,
  //     1) enter the cs,
  //     2) set the WorkerReady event
  //     3) wait for JobScheduled event
  //     4) JobScheduled event then leave cs;
  //    scheduler thread
  //     1) wait for the WorkerReady event, reset WorkerReady,
  //     2) schedule jobs, set JobScheduled event for the worker
  TAsyncWorker = record
    JobScheduled: PRTLEvent;
    I, J: Integer;
  end;
  PAsyncWorker = ^TAsyncWorker;

  TAsyncSchedule = record
    GroupSize: integer;
    PoolSize: integer;
    Fun: TAsyncFun;
    ParamArray: Pointer;
    Total: Cardinal;
    ParamSize: Cardinal;

    CriticalSection: TRTLCriticalSection;
    WorkerReady: PRTLEvent;
    ReadyWorker: PAsyncWorker;
  end;
  PAsyncSchedule = ^TAsyncSchedule;

procedure AsyncWorker(Schedule: PAsyncSchedule);
var
  W: TAsyncWorker;
  Fun: TAsyncFun;
  ParamArray: Pointer;
  K: integer;
begin
  Fun := Schedule.Fun;
  ParamArray := Schedule.ParamArray;
  W.I := 0;
  W.J := -1;
  W.JobScheduled := RTLEventCreate;

  repeat
    EnterCriticalSection(Schedule^.CriticalSection);
    Schedule.ReadyWorker := @W;
    RTLEventSetEvent(Schedule^.WorkerReady);
    RTLEventWaitFor(W.JobScheduled);
    RTLeventResetEvent(W.JobScheduled);
    LeaveCriticalSection(Schedule.CriticalSection);
    for K := W.I to W.J do
      try
       Fun(ParamArray + Schedule.ParamSize * Cardinal(K));
      except
      end;
  until (W.I > W.J);

  RTLEventDestroy(W.JobScheduled);
end;

procedure AsyncSchedule(Schedule: PAsyncSchedule);
var
  I: integer;
  Active: Integer;
  Total: integer;
  Group: Integer;
  Flags: array of Boolean;
  Start: integer;

  procedure DistributeJobs;
  var
    K, L: Integer;
    W: PAsyncWorker;
  begin
    W := Schedule.ReadyWorker;
    for K := W.I to W.J do
      Flags[K] := True;
    K := Start;
    while (K < Total) and Flags[K] do Inc(K);
    if K >= Total then
    begin
      Dec(Active);
      W.I := 0;
      W.J := -1;
      RTLeventSetEvent(W.JobScheduled);
      Exit;
    end;

    W.I := K;
    L := 1;
    while (K < Total) and (not Flags[K]) and (L < Group) do
    begin
      Inc(K);
      Inc(L);
    end;
    if (K >= Total) or Flags[K] then Dec(K);
    W.J := K;
    Start := K + 1;
    RTLeventSetEvent(W.JobScheduled);
    Exit;
  end;

begin
  InitCriticalSection(Schedule.CriticalSection);
  Schedule.WorkerReady := RTLEventCreate;
  SetLength(Flags, Schedule.Total);
  Total := Schedule.Total;
  Start := 0;
  Group := Schedule.GroupSize;

  for I := 1 to Schedule^.PoolSize do
  begin
    AsyncCall(TAsyncFun(@AsyncWorker), Schedule, TAsyncNotify(nil), nil);
  end;

  Active := Schedule^.PoolSize;
  while Active > 0 do
  begin
    RTLEventWaitFor(Schedule.WorkerReady);
    RTLeventResetEvent(Schedule.WorkerReady);
    DistributeJobs;
  end;

  RTLEventDestroy(Schedule.WorkerReady);
  DoneCriticalsection(Schedule.CriticalSection);
end;

procedure AsyncForEach(Fun: TAsyncFun; ParamArray: Pointer; const ArrayLength,
  ParamSize: Cardinal; Notify: TAsyncNotify; NotifyParam: Pointer);
begin
  AsyncForEach(Fun, ParamArray, ArrayLength, ParamSize, Notify, NotifyParam, []);
end;

procedure AsyncForEach(Fun: TAsyncFun; ParamArray: Pointer; const ArrayLength,
  ParamSize: Cardinal; Notify: TAsyncObjectNotify; NotifyParam: Pointer);
var
  P: TAsyncObjNotifyClass;
begin
  P := TAsyncObjNotifyClass.Create;
  P.FNotifyParam := NotifyParam;
  P.FNotify := Notify;
  AsyncForEach(Fun, ParamArray, ArrayLength, ParamSize, CallAsyncObjNotify, P, []);
end;

procedure AsyncForEach(Fun: TAsyncFun; ParamArray: Pointer; const ArrayLength,
  ParamSize: Cardinal; Notify: TAsyncObjectNotify; NotifyParam: Pointer;
  Cfg: array of Variant);
var
  P: TAsyncObjNotifyClass;
begin
  P := TAsyncObjNotifyClass.Create;
  P.FNotifyParam := NotifyParam;
  P.FNotify := Notify;
  AsyncForEach(Fun, ParamArray, ArrayLength, ParamSize, CallAsyncObjNotify, P, Cfg);
end;

procedure AsyncForEach(Fun: TAsyncFun;
  ParamArray: Pointer; const ArrayLength, ParamSize: Cardinal;
  Notify: TAsyncNotify; NotifyParam: Pointer; Cfg: array of Variant);
var
  Schedule: PAsyncSchedule;
  Total: integer;
  Max, Def: integer;
begin
  Total := ArrayLength;
  if Total < 1 then
  begin
    Notify(NotifyParam);
    Exit;
  end;

  New(Schedule);

  Schedule^.GroupSize := PropListGet('GroupSize', 0, Cfg);
  if Schedule.GroupSize > Total then
    Schedule.GroupSize := Total
  else if Schedule.GroupSize < 0 then
    Schedule.GroupSize := 0;

  if Schedule.GroupSize > 0 then
  begin
    Max := (Total + Schedule.GroupSize - 1) div Schedule.GroupSize;
    Def := Max;
  end
  else
  begin
    Max := Total;
    Def := DefaultPoolSize;
  end;

  Schedule.PoolSize := PropListGet('PoolSize', Def, Cfg);
  if Schedule.PoolSize < 1 then
    Schedule.PoolSize := 1
  else if Schedule.PoolSize > Max then
    Schedule.PoolSize := Max;

  if Schedule.GroupSize = 0 then
    Schedule.GroupSize := (Total + Schedule.PoolSize - 1) div Schedule.PoolSize;

  Schedule.Fun := Fun;
  Schedule.ParamArray := ParamArray;
  Schedule.Total := Total;
  Schedule.ParamSize := ParamSize;
  AsyncCall(TAsyncFun(@AsyncSchedule), Schedule, Notify, NotifyParam);
end;

function PropListGet(Field: variant; Def: variant; Cfg: array of Variant
  ): Variant;
var
  I: Integer;
begin
  Result := Def;
  I := 0;
  while I < High(Cfg) do
  begin
    if Cfg[I] = Field then
    begin
      Result := Cfg[I + 1];
      Exit;
    end;
    Inc(I, 2);
  end;
end;

end.
