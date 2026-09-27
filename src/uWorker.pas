unit uWorker;
{
  The migration worker.

  Threading model
  ---------------
    UI thread        - the window only. Never calls the Team Coherence API and never blocks.
    Migration thread - one thread, and the ONLY thread that touches the TC API DLLs.
    Fetch workers    - a small pool inside TPipeline that runs tc.exe. Separate processes,
                       no DLL calls, so they parallelise safely.

  Why it matters: a single TCDVcsEnumFiles call can sit inside the DLL for minutes. Pumping
  messages between callbacks is not enough - during one long call nothing pumps at all and
  Windows paints the window as "Not Responding". The work has to leave the UI thread.

  Login stays on the UI thread (TCVcsLogin shows a modal dialog and is proven to work there);
  everything after it runs here.

  All UI updates are marshalled with TThread.Queue, which does not block the worker.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.DateUtils,
  System.SyncObjs,
  uTCApi, uPipeline;

const
  // How long a phase may make no progress before the run is abandoned. Every phase reports
  // per file, per folder or per revision, so ten minutes of complete silence is not slowness.
  //
  // This exists because of a real failure: the label-attachment pass sat for 73 minutes having
  // used 7.8 seconds of CPU, blocked inside TCDVcsEnumLabels on a socket the VPN had killed.
  // TCP still reported the connection Established, the TC DLL applies no timeout, and the
  // connection heartbeat only runs during the fetch phase - so nothing would ever have ended it.
  StallMinutes = 10;

type
  TWorkerDone = procedure(Success: Boolean; const Summary: string) of object;

  TMigrationThread = class(TThread)
  private
    FSession: TTCSession;
    FOpt: TPipelineOptions;
    FRoots: TArray<Cardinal>;
    FLimit: Integer;
    FOnLog: TLogProc;
    FOnItem: TLogProc;
    FOnCounters: TLogProc;
    FOnOverall: TProgressProc;
    FOnProgress: TProgressProc;
    FOnDone: TWorkerDone;
    FStep, FSteps: Integer;
    FSummary: string;
    FOk: Boolean;
    FLastItem: TDateTime;
    FLastCounters: TDateTime;
    FLastOverall: TDateTime;
    // Watchdog state. FLastWork is a tick count stamped by every unit of real work; the
    // watchdog thread force-ends the run if it stops moving. FDoneReported makes sure the
    // watchdog and a late-finishing worker cannot both report the outcome.
    FLastWork: Int64;
    FDoneReported: Integer;
    FWatchdog: TThread;
    procedure MarkWork;
    procedure ReportDone(Success: Boolean; const Summary: string);
    procedure QLog(const Msg: string);
    procedure QItem(const Detail: string);
    procedure QCounters(const S: string);
    procedure QOverall(const Phase: string; Done, Total: Integer);
    procedure QProgress(const Phase: string; Done, Total: Integer);
    function IsCancelled: Boolean;
    procedure Phase(const Name: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ASession: TTCSession; const AOpt: TPipelineOptions;
      const ARoots: TArray<Cardinal>; ALimit: Integer;
      ALog: TLogProc; AItem: TLogProc; ACounters: TLogProc;
      AOverall: TProgressProc; AProgress: TProgressProc; ADone: TWorkerDone);
    property Summary: string read FSummary;
  end;

implementation

type
  // Ends a run that has stopped making progress. Declared here so it can reach the worker's
  // private state directly - same unit, so private is visible.
  TStallWatchdog = class(TThread)
  private
    FOwner: TMigrationThread;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMigrationThread);
  end;

constructor TStallWatchdog.Create(AOwner: TMigrationThread);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TStallWatchdog.Execute;
var
  Last, Ticks: Int64;
  Mins: Double;
  I: Integer;
begin
  NameThreadForDebugging('TC stall watchdog');
  while not Terminated do
  begin
    // short naps so Terminate is honoured promptly at the end of a normal run
    for I := 1 to 20 do
    begin
      if Terminated then Exit;
      Sleep(500);
    end;
    Last := TInterlocked.Read(FOwner.FLastWork);
    if Last = 0 then Continue;                  // no work has been reported yet
    Ticks := Int64(TThread.GetTickCount64);
    Mins := (Ticks - Last) / 60000;
    if Mins >= StallMinutes then
    begin
      FOwner.QLog('');
      FOwner.QLog(Format('*** NO PROGRESS FOR %.0f MINUTES - abandoning this attempt. ***',
        [Mins]));
      FOwner.QLog('*** The usual cause is a TC call blocked on a socket the VPN killed: TCP');
      FOwner.QLog('*** still reports the connection open and the DLL applies no timeout. The');
      FOwner.QLog('*** supervisor relaunches and the run resumes from its last checkpoint.');
      FOwner.ReportDone(False, Format(
        'Stalled: no progress for %.0f minutes. A relaunch resumes from the checkpoint.', [Mins]));
      Exit;
    end;
  end;
end;

constructor TMigrationThread.Create(ASession: TTCSession; const AOpt: TPipelineOptions;
  const ARoots: TArray<Cardinal>; ALimit: Integer;
  ALog: TLogProc; AItem: TLogProc; ACounters: TLogProc;
  AOverall: TProgressProc; AProgress: TProgressProc; ADone: TWorkerDone);
begin
  FSession := ASession;
  FOpt := AOpt;
  FRoots := ARoots;
  FLimit := ALimit;
  FOnLog := ALog;
  FOnItem := AItem;
  FOnCounters := ACounters;
  FOnOverall := AOverall;
  FOnProgress := AProgress;
  FOnDone := ADone;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TMigrationThread.QLog(const Msg: string);
var
  M: string;
begin
  M := Msg;
  if Assigned(FOnLog) then
    TThread.Queue(nil,
      procedure
      begin
        FOnLog(M);
      end);
end;

procedure TMigrationThread.MarkWork;
begin
  // One unit of real work happened. Deliberately NOT called from QLog: the status line is
  // emitted on a timer whether or not anything is happening, so treating a log write as
  // progress would make the watchdog blind exactly when it is needed.
  TInterlocked.Exchange(FLastWork, Int64(TThread.GetTickCount64));
end;

procedure TMigrationThread.ReportDone(Success: Boolean; const Summary: string);
var
  Ok: Boolean;
  Sum: string;
begin
  // First caller wins. The watchdog may report a stall while the worker is still blocked in a
  // DLL call that later returns.
  if TInterlocked.CompareExchange(FDoneReported, 1, 0) <> 0 then Exit;
  Ok := Success;
  Sum := Summary;
  if Assigned(FOnDone) then
    TThread.Queue(nil,
      procedure
      begin
        FOnDone(Ok, Sum);
      end);
end;

procedure TMigrationThread.QProgress(const Phase: string; Done, Total: Integer);
var
  P: string;
  D, T: Integer;
begin
  MarkWork;
  P := Phase; D := Done; T := Total;
  if Assigned(FOnProgress) then
    TThread.Queue(nil,
      procedure
      begin
        FOnProgress(P, D, T);
      end);
end;

procedure TMigrationThread.QItem(const Detail: string);
var
  D: string;
begin
  MarkWork;   // before the throttle: every item is real work even if the UI is not told
  // Throttled: the enumerators report every item, and 44,000 queued UI updates would
  // swamp the message queue and slow the run down. Ten a second is plenty to look alive.
  if MilliSecondsBetween(Now, FLastItem) < 100 then Exit;
  FLastItem := Now;
  D := Detail;
  if Assigned(FOnItem) then
    TThread.Queue(nil,
      procedure
      begin
        FOnItem(D);
      end);
end;

procedure TMigrationThread.QOverall(const Phase: string; Done, Total: Integer);
var
  D, T: Integer;
begin
  if MilliSecondsBetween(Now, FLastOverall) < 500 then Exit;
  FLastOverall := Now;
  D := Done; T := Total;
  if Assigned(FOnOverall) then
    TThread.Queue(nil,
      procedure
      begin
        FOnOverall('', D, T);
      end);
end;

procedure TMigrationThread.QCounters(const S: string);
var
  D: string;
begin
  // Twice a second is enough to look alive without flooding the queue.
  if MilliSecondsBetween(Now, FLastCounters) < 500 then Exit;
  FLastCounters := Now;
  D := S;
  if Assigned(FOnCounters) then
    TThread.Queue(nil,
      procedure
      begin
        FOnCounters(D);
      end);
end;

function TMigrationThread.IsCancelled: Boolean;
begin
  Result := Terminated;
end;

procedure TMigrationThread.Phase(const Name: string);
begin
  Inc(FStep);
  QLog('');
  QLog(Format('=== [%d/%d] %s ===', [FStep, FSteps, Name]));
  QProgress(Name, 0, 0);
end;

procedure TMigrationThread.Execute;
var
  Pipe: TPipeline;
  I: Integer;
  Probe, SavedView: string;
begin
  NameThreadForDebugging('TC migration');
  FOk := False;
  FStep := 0;
  FSteps := 6;
  if FOpt.IncludeTags then Inc(FSteps);   // the label pass is a phase of its own
  MarkWork;
  FWatchdog := TStallWatchdog.Create(Self);
  Pipe := TPipeline.Create(FSession, FOpt);
  try
    FSession.OnLog := QLog;
    FSession.OnItem := QItem;
    FSession.OnProgress := QProgress;
    FSession.OnCancel := IsCancelled;
    Pipe.OnLog := QLog;
    Pipe.OnItem := QItem;
    Pipe.OnCounters := QCounters;
    Pipe.OnOverall := QOverall;
    Pipe.OnProgress := QProgress;
    Pipe.OnCancel := IsCancelled;

    SavedView := '';
    try
      // Run under <default>, where revision numbers resolve correctly, and put the
      // operator's own view back in the finally below - whatever happens.
      SavedView := Pipe.GetCurrentView;
      QLog(Format('Active Team Coherence view: %s', [SavedView]));
      if (SavedView <> '') and (SavedView <> '<default>') then
      begin
        QLog('Switching to <default> for the migration; your view will be restored at the end.');
        Pipe.SetView('<default>');
      end;

      // ---- metadata: reload if a previous run already gathered it -------------------
      if FSession.LoadCsvs(FOpt.MetaDir) then
        QLog('Using the metadata saved by a previous run (delete meta\ to re-read it).')
      else
      begin
        Phase('Reading the repository structure');
        FSession.Folders.Clear;
        FSession.Files.Clear;
        FSession.Revisions.Clear;
        FSession.Labels.Clear;
        FSession.Attachments.Clear;
        for I := 0 to High(FRoots) do
        begin
          if Terminated then Break;
          QLog(Format('Project id %d', [FRoots[I]]));
          FSession.EnumTree(FRoots[I]);
          FSession.EnumLabelsFor(FRoots[I]);
        end;

        if (FLimit > 0) and (FSession.Files.Count > FLimit) then
        begin
          QLog('');
          QLog(Format('*** TEST RUN - LIMITED TO THE FIRST %d OF %d FILES ***',
            [FLimit, FSession.Files.Count]));
          QLog('*** This is NOT a full migration. Clear the limit to migrate everything. ***');
          QLog('');
          FSession.Files.DeleteRange(FLimit, FSession.Files.Count - FLimit);
        end;

        if not Terminated then
        begin
          Phase('Reading revision history');
          FSession.EnumAllRevisions;
          // Saved immediately: an interrupted run must never have to re-read 44,000
          // revisions from the server just to get back to where it was.
          FSession.SaveCsvs(FOpt.MetaDir);
          QLog('Metadata saved. A later run will reuse it instead of re-reading the server.');
        end;
      end;

      // ---- labels are optional and separately resumable ----------------------------
      // Always entered when tags are wanted, not only when no attachments are loaded yet: the
      // pass checkpoints, so a partially finished one MUST be allowed to continue. Gating on
      // "Attachments.Count = 0" would have treated any interrupted pass as a completed one.
      // A pass that really is finished costs only the load of its own checkpoint files.
      if not Terminated and FOpt.IncludeTags then
      begin
        Phase('Matching labels to revisions');
        FSession.EnumAttachments(FOpt.MetaDir);
        FSession.SaveCsvs(FOpt.MetaDir);
      end;

      if not Terminated then
      begin
        Phase('Checking that revision selection works');
        if FSession.Files.Count = 0 then
          raise Exception.Create('No files were found - nothing to migrate.');
        Probe := FSession.Files[0].TCPath;
        if not Pipe.CheckRevisionSelection(Probe) then
          raise Exception.Create(
            'This client returns the TIP for any revision requested, so every revision would '
            + 'be stored with today''s content.'#13#10#13#10
            + 'Switch the Team Coherence view to <default> and run again.');
        QLog('Revision selection confirmed: an impossible revision is correctly rejected.');
      end;

      if not Terminated then
      begin
        Phase('Migrating check-ins, oldest first');
        Pipe.RunIncremental;
      end;

      // Labels after the history, because a label's tree is built from blobs the import has
      // already put in the object store, and before the deletion sweep, because a label
      // legitimately contains files that no longer exist today.
      if not Terminated and FOpt.IncludeTags then
      begin
        Phase('Rebuilding version labels as refs');
        Pipe.ImportTags;
      end;

      if not Terminated then
      begin
        Phase('Removing files deleted in Team Coherence');
        Pipe.RemoveDeletedFiles;
        Pipe.Verify;
      end;
      if Terminated then
        FSummary := 'Stopped at your request.'
      else
      begin
        FOk := True;
        FSummary := Format('%d files, %d revisions, %d blobs -> %s',
          [FSession.Files.Count, FSession.Revisions.Count, Pipe.Blobs.Count, FOpt.RepoDir]);
        if FLimit > 0 then
          FSummary := Format('LIMITED TEST RUN (first %d files only) - ', [FLimit]) + FSummary;
      end;
    except
      on E: Exception do
      begin
        FSummary := E.Message;
        QLog('ERROR: ' + E.Message);
      end;
    end;
  finally
    // Always hand the operator back the view they started with, including after an
    // error or a Stop.
    if (SavedView <> '') and (SavedView <> '<default>') then
    begin
      QLog(Format('Restoring your Team Coherence view: %s', [SavedView]));
      Pipe.SetView(SavedView);
    end;
    Pipe.Free;
    // detach the callbacks before this thread goes away
    FSession.OnLog := nil;
    FSession.OnItem := nil;
    FSession.OnProgress := nil;
    FSession.OnCancel := nil;
    if FWatchdog <> nil then
    begin
      FWatchdog.Terminate;
      FWatchdog.WaitFor;
      FWatchdog.Free;
      FWatchdog := nil;
    end;
    ReportDone(FOk, FSummary);
  end;
end;

end.
