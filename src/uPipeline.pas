unit uPipeline;
{
  Everything after metadata extraction:

    1. Fetch   - tc.exe Get -VR<rev> for every revision, into a content-addressed blob cache
    2. Build   - turn metadata + blobs into a git fast-import stream (native; no Node.js)
    3. Import  - git fast-import into a bare repository
    4. Verify  - compare what landed in git against what came out of Team Coherence

  Only two external programs are used, both vendor binaries rather than editable scripts:
  tc.exe (Team Coherence) and git.exe.

  READ-ONLY against Team Coherence: the only verb ever issued is Get.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  Winapi.Windows, uTCApi;

type
  TBlob = record
    FileID: Cardinal;
    Revision: string;
    Member: string;        // name inside the archive's file group ('' = the archive itself)
    Sha, CachePath: string;
    Size: Int64;
  end;

  TPipelineOptions = record
    TcExe, GitExe: string;
    WorkDir, CacheDir, RepoDir, MetaDir: string;
    Project: string;          // e.g. //MyProject - re-anchored after every view change
    Branch: string;
    WindowSeconds: Integer;
    AuthorMapFile: string;
    IncludeTags: Boolean;
    BatchSize: Integer;          // check-ins per resumable batch
    FetchThreads: Integer;      // parallel tc.exe Get workers (1 = serial)
    // Fetch content with TCDVcsCheckOutFile instead of spawning tc.exe. Measured 0.21 s vs
    // 2.6 s per revision, and byte-identical output. Calls are serialised inside the session,
    // so this pins the fetcher to one worker.
    UseDll: Boolean;
  end;

  TPipeline = class
  private
    FSession: TTCSession;
    FOpt: TPipelineOptions;
    FOnLog: TLogProc;
    FOnItem: TLogProc;
    FOnCounters: TLogProc;
    FOnOverall: TProgressProc;
    FOnProgress: TProgressProc;
    FOnCancel: TCancelFunc;
    FBlobs: TList<TBlob>;
    FAuthors: TStringList;
    FLock: TCriticalSection;
    FManifest: TStringList;
    FNextIdx, FDone, FFailed, FConsecFail: Integer;
    FConnLost: Boolean;
    FStoppedIncomplete: Boolean;
    FEmpty: Integer;
    FBadFile: TDictionary<Cardinal, Integer>;   // consecutive failures per file
    FInFlight: TDictionary<Cardinal, Boolean>;  // files being fetched right now
    FPending: TList<Integer>;                   // revisions still to claim in this batch
    FSkippedRows: TStringList;
    FFailedRows: TStringList;
    FGitOutRead: THandle;
    FHaveBlob: TDictionary<string, Boolean>;   // (file|revision) already fetched
    FSorted: TArray<TTCRevision>;              // chronological order, shared with workers
    FRangeStart, FRangeEnd, FFetchedTo: Integer;
    FOverallBase, FOverallTotal: Integer;
    // High-water mark for the displayed position. See StatusLine.
    FDoneHigh: Integer;
    FPaused: Boolean;
    FHeartbeat: TObject;
    FPhaseName: string;
    FCurrentItem: string;
    FRunStarted: TDateTime;
    FStartedAt: Integer;
    FLastOut: string;
    function StatePath: string;
    function TestConnection: Boolean;
    function FileIsFetchable(const TCPath: string): Boolean;
    function ReadCheckpoint: Integer;
    procedure WriteCheckpoint(Index: Integer; const Extra: string);
    procedure LoadBlobManifest;
    procedure RewindToCheckpointTip;
    procedure FetchRange(StartIdx, EndIdx: Integer);
    function ClaimNext: Integer;
    function PendingCount: Integer;
    procedure ReleaseFile(FileID: Cardinal);
    procedure AppendManifest(const Rows: TArray<string>);
    procedure AppendSkipped(const Rows: TArray<string>);
    procedure MergeSaveCsv(const Name, Header: string; Rows: TStrings);
    procedure ImportRange(StartIdx, EndIdx: Integer);
    function FileIdOf(const TCPath: string): Cardinal;
    function StartFastImport(out ProcInfo: TProcessInformation; out StdInWrite: THandle): Boolean;
    function FinishFastImport(var ProcInfo: TProcessInformation; var StdInWrite: THandle;
      out Output: string): Integer;
    procedure FetchOne(Index: Integer);
    procedure Item(const Detail: string);
    procedure Overall(Done, Total: Integer);
    procedure Progress(const Phase: string; Done, Total: Integer);
    function Cancelled: Boolean;
    function RunProcess(const Exe, Params, WorkDir: string; out Output: string;
      const StdInFile: string = ''): Integer;
    function GitPathOf(const TCPath: string): string;
    function MemberPath(const TCPath, Member: string): string;
    function SanitiseRefName(const S: string): string;
    function MapAuthor(const Login: string): string;
    procedure LoadAuthorMap;
  public
    function ServerAnswers: Boolean;
    function StatusLine: string;
    procedure ReAnchorFolder;
    procedure WaitIfPaused;
    procedure Log(const Msg: string);
    procedure Counters(const S: string);
    constructor Create(ASession: TTCSession; const AOpt: TPipelineOptions);
    destructor Destroy; override;
    property OnLog: TLogProc read FOnLog write FOnLog;
    property OnItem: TLogProc read FOnItem write FOnItem;
    property OnCounters: TLogProc read FOnCounters write FOnCounters;
    property OnOverall: TProgressProc read FOnOverall write FOnOverall;
    property OnProgress: TProgressProc read FOnProgress write FOnProgress;
    property OnCancel: TCancelFunc read FOnCancel write FOnCancel;

    procedure ImportTags;
    function CheckRevisionSelection(const TCPath: string): Boolean;
    function GetCurrentView: string;
    function SetView(const ViewName: string): Boolean;
  public
    procedure FetchAll;
    procedure BuildAndImport;
    procedure RunIncremental;
    procedure RemoveDeletedFiles;
    procedure Verify;
    procedure VerifySizes;
    property Blobs: TList<TBlob> read FBlobs;
  end;

implementation

uses
  System.Hash, System.IOUtils, System.DateUtils, System.StrUtils,
  System.Generics.Defaults, Winapi.WinSock;

constructor TPipeline.Create(ASession: TTCSession; const AOpt: TPipelineOptions);
begin
  inherited Create;
  FSession := ASession;
  FOpt := AOpt;
  FBlobs := TList<TBlob>.Create;
  FAuthors := TStringList.Create;
  FAuthors.CaseSensitive := False;
  FLock := TCriticalSection.Create;
  FManifest := TStringList.Create;
  FHaveBlob := TDictionary<string, Boolean>.Create;
  FSkippedRows := TStringList.Create;
  FBadFile := TDictionary<Cardinal, Integer>.Create;
  FInFlight := TDictionary<Cardinal, Boolean>.Create;
  FPending := TList<Integer>.Create;
  FFailedRows := TStringList.Create;
end;

destructor TPipeline.Destroy;
begin
  FBlobs.Free;
  FAuthors.Free;
  FLock.Free;
  FManifest.Free;
  FHaveBlob.Free;
  FSkippedRows.Free;
  FBadFile.Free;
  FInFlight.Free;
  FPending.Free;
  FFailedRows.Free;
  inherited;
end;

procedure TPipeline.Log(const Msg: string);
begin
  if Assigned(FOnLog) then FOnLog(Msg);
end;

procedure TPipeline.Item(const Detail: string);
begin
  FLock.Enter;
  try
    FCurrentItem := Detail;
  finally
    FLock.Leave;
  end;
  if Assigned(FOnItem) then FOnItem(Detail);
end;

procedure TPipeline.Overall(Done, Total: Integer);
begin
  // Progress across the WHOLE migration, not the current phase - that is the number an
  // operator actually wants when a run lasts many hours.
  if Assigned(FOnOverall) then FOnOverall('', Done, Total);
end;

procedure TPipeline.Counters(const S: string);
begin
  if Assigned(FOnCounters) then FOnCounters(S);
end;

procedure TPipeline.Progress(const Phase: string; Done, Total: Integer);
begin
  if Phase <> '' then FPhaseName := Phase;
  if Assigned(FOnProgress) then FOnProgress(Phase, Done, Total);
end;

function TPipeline.Cancelled: Boolean;
begin
  // A lost connection stops the workers just as a Stop from the operator does.
  Result := FConnLost or (Assigned(FOnCancel) and FOnCancel);
end;

// ---------------------------------------------------------------- process runner

function TPipeline.RunProcess(const Exe, Params, WorkDir: string; out Output: string;
  const StdInFile: string): Integer;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  ReadPipe, WritePipe, StdIn: THandle;
  Buf: array[0..4095] of AnsiChar;
  Read, Avail: DWORD;
  Cmd, Cwd: string;
  Res: AnsiString;
  WaitRes: DWORD;
  Deadline: UInt64;
begin
  Output := '';
  Res := '';
  StdIn := INVALID_HANDLE_VALUE;
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then Exit(-1);
  try
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    SI.wShowWindow := SW_HIDE;          // no console window flashing at the operator
    SI.hStdOutput := WritePipe;
    SI.hStdError := WritePipe;
    // CreateProcess runs no shell, so '<' would be passed to the program as a literal
    // argument. Hand the file to the child as its stdin handle instead.
    if StdInFile <> '' then
    begin
      StdIn := CreateFile(PChar(StdInFile), GENERIC_READ, FILE_SHARE_READ, @SA,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
      if StdIn = INVALID_HANDLE_VALUE then Exit(-1);
      SI.hStdInput := StdIn;
    end;
    Cmd := '"' + Exe + '" ' + Params;
    // A missing working directory makes CreateProcess fail for reasons that have nothing
    // to do with the command, so fall back to inheriting ours.
    Cwd := WorkDir;
    if (Cwd <> '') and not DirectoryExists(Cwd) then Cwd := '';
    if Cwd = '' then
    begin
      if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW,
                           nil, nil, SI, PI) then Exit(-1);
    end
    else
      if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW,
                           nil, PChar(Cwd), SI, PI) then Exit(-1);
    CloseHandle(WritePipe);
    WritePipe := 0;
    try
      Deadline := GetTickCount64 + 300000;   // 5 minutes: far above the ~11s worst case seen
      repeat
        WaitRes := WaitForSingleObject(PI.hProcess, 50);
        // drain the pipe so a chatty child cannot deadlock on a full buffer
        while PeekNamedPipe(ReadPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
        begin
          if not ReadFile(ReadPipe, Buf, SizeOf(Buf) - 1, Read, nil) or (Read = 0) then Break;
          Buf[Read] := #0;
          Res := Res + AnsiString(Buf);
        end;
        // No message pumping here: this runs on a worker thread, and
        // Application.ProcessMessages must only ever be called from the UI thread.
        if Cancelled then
        begin
          TerminateProcess(PI.hProcess, 1);
          Break;
        end;
        // A hung child would otherwise stall the whole migration for ever - there is no
        // other timeout anywhere in the fetch path.
        if GetTickCount64 > Deadline then
        begin
          TerminateProcess(PI.hProcess, 1);
          Res := Res + AnsiString(' [timed out after 5 minutes]');
          Break;
        end;
      until WaitRes <> WAIT_TIMEOUT;
      GetExitCodeProcess(PI.hProcess, DWORD(Result));
    finally
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  finally
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
    if StdIn <> INVALID_HANDLE_VALUE then CloseHandle(StdIn);
  end;
  Output := string(Res);
end;

// ---------------------------------------------------------------- paths

function TPipeline.GitPathOf(const TCPath: string): string;
begin
  Result := TCPath;
  while StartsStr('/', Result) do Delete(Result, 1, 1);
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
end;

function TPipeline.MemberPath(const TCPath, Member: string): string;
var
  Base, Dir: string;
  P: Integer;
begin
  Base := GitPathOf(TCPath);
  if Member = '' then Exit(Base);
  P := LastDelimiter('/', Base);
  if P > 0 then Dir := Copy(Base, 1, P) else Dir := '';
  Result := Dir + StringReplace(Member, '\', '/', [rfReplaceAll]);
end;

procedure TPipeline.LoadAuthorMap;
begin
  FAuthors.Clear;
  if (FOpt.AuthorMapFile <> '') and TFile.Exists(FOpt.AuthorMapFile) then
  begin
    FAuthors.LoadFromFile(FOpt.AuthorMapFile);
    Log(Format('Author map: %d entries from %s', [FAuthors.Count, FOpt.AuthorMapFile]));
  end;
end;

function TPipeline.MapAuthor(const Login: string): string;
var
  V: string;
begin
  V := FAuthors.Values[Login];
  if V <> '' then Exit(V);
  // Deliberately obvious rather than invented, so an unmapped author is easy to spot later.
  Result := Format('%s <%s@tc.local>', [Login, LowerCase(Login)]);
end;

// ---------------------------------------------------------------- the active view
//
// The view decides what a revision number resolves to, so the migration runs under
// <default> and puts the operator's own view back afterwards. This is the only Team
// Coherence state this program ever changes, and it is always restored.

function TPipeline.GetCurrentView: string;
var
  Output: string;
  Lines: TArray<string>;
  S: string;
begin
  Result := '';
  RunProcess(FOpt.TcExe, 'CONNECTINFO', FOpt.WorkDir, Output);
  Lines := Output.Split([#13, #10]);
  for S in Lines do
    if S.TrimLeft.StartsWith('View:') then
      Exit(S.TrimLeft.Substring(5).Trim);
end;

function TPipeline.SetView(const ViewName: string): Boolean;
var
  Output: string;
begin
  Result := RunProcess(FOpt.TcExe, Format('SetView "%s" -T', [ViewName]),
                       FOpt.WorkDir, Output) = 0;
  // Switching the view leaves the client's current-folder cache stale: CONNECTINFO still
  // reports the old folder while absolute paths resolve against something else entirely.
  // That made perfectly good revisions return "No files found under ..." and produced 788
  // phantom failures before it was spotted. Re-anchoring the folder makes paths resolve.
  RunProcess(FOpt.TcExe, Format('CD "%s" -T', [FOpt.Project]), FOpt.WorkDir, Output);
  if Result then Log(Format('  view is now %s', [ViewName]))
  else Log(Format('  could not switch to view %s: %s', [ViewName, Trim(Output)]));
end;

// -+ safety gate

function TPipeline.CheckRevisionSelection(const TCPath: string): Boolean;
var
  DirA, DirB, Out1: string;
  RcB: Integer;
  GotB: Integer;
begin
  // The active View decides what -VR means. Under some views every -VR quietly returns the
  // TIP, which would fill the repository with tip content for every revision. Prove that an
  // impossible revision FAILS before trusting any of it.
  DirA := TPath.Combine(FOpt.WorkDir, 'probe-a');
  DirB := TPath.Combine(FOpt.WorkDir, 'probe-b');
  TDirectory.CreateDirectory(DirA);
  TDirectory.CreateDirectory(DirB);
  try
    RunProcess(FOpt.TcExe, Format('Get "%s" "-GL%s" -W -T', [TCPath, DirA]), FOpt.WorkDir, Out1);
    RcB := RunProcess(FOpt.TcExe, Format('Get "%s" -VR99.99 "-GL%s" -W -T', [TCPath, DirB]),
                      FOpt.WorkDir, Out1);
    GotB := Length(TDirectory.GetFiles(DirB, '*', TSearchOption.soAllDirectories));
    Result := not ((RcB = 0) and (GotB > 0));
  finally
    TDirectory.Delete(DirA, True);
    TDirectory.Delete(DirB, True);
  end;
end;

// ---------------------------------------------------------------- fetch (parallel)

type
  // Each worker pulls the next revision index and runs its own tc.exe. No Team Coherence
  // API call happens here - only separate processes - so this is safe to parallelise even
  // though the DLL itself is confined to a single thread.
  TFetchWorker = class(TThread)
  private
    FPipe: TPipeline;
    FCount: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APipe: TPipeline; ACount: Integer);
  end;

constructor TFetchWorker.Create(APipe: TPipeline; ACount: Integer);
begin
  FPipe := APipe;
  FCount := ACount;
  inherited Create(False);
end;

function TPipeline.ClaimNext: Integer;
// Hands a worker the next revision whose ARCHIVE is not already being fetched. Waiting for
// a busy archive would serialise the whole run, because revisions are in date order and
// consecutive ones usually belong to the same file - that cost 4x throughput. Skipping
// ahead to a free archive keeps every worker busy while still never fetching one archive
// from two processes at once.
var
  I, Idx: Integer;
begin
  Result := -1;
  FLock.Enter;
  try
    for I := 0 to FPending.Count - 1 do
    begin
      Idx := FPending[I];
      if not FInFlight.ContainsKey(FSorted[Idx].FileID) then
      begin
        FPending.Delete(I);
        FInFlight.Add(FSorted[Idx].FileID, True);
        Exit(Idx);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPipeline.ReleaseFile(FileID: Cardinal);
begin
  FLock.Enter;
  try
    FInFlight.Remove(FileID);
  finally
    FLock.Leave;
  end;
end;

function TPipeline.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FPending.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TFetchWorker.Execute;
var
  Idx: Integer;
begin
  NameThreadForDebugging('TC fetch');
  while not Terminated and not FPipe.Cancelled do
  begin
    Idx := FPipe.ClaimNext;
    if Idx < 0 then
    begin
      if FPipe.PendingCount = 0 then Break;   // batch finished
      Sleep(15);                              // every remaining archive is busy
      Continue;
    end;
    try
      try
        FPipe.FetchOne(Idx);
      except
        on E: Exception do
        begin
          FPipe.FLock.Enter;
          try
            Inc(FPipe.FFailed);
            FPipe.FManifest.Add('# error ' + E.Message);
          finally
            FPipe.FLock.Leave;
          end;
        end;
      end;
    finally
      // claim and release in the same place, so no path can leak the marker
      FPipe.ReleaseFile(FPipe.FSorted[Idx].FileID);
    end;
    TInterlocked.Increment(FPipe.FDone);
  end;
end;
procedure TPipeline.FetchOne(Index: Integer);
var
  R: TTCRevision;
  Tmp, Sha, Dest, RelDir, Out1, ListFile: string;
  Names: TArray<string>;
  B: TBlob;
  Rc, J, Attempt, GotBytes: Integer;
  Ok, NoStoredFile, SuspectLink, CheckFile: Boolean;
  Keep: TArray<string>;
begin
  R := FSorted[Index];
  // already fetched on an earlier run? nothing to do - this is what makes a resume cheap
  FLock.Enter;
  try
    if FHaveBlob.ContainsKey(Format('%d|%s', [R.FileID, R.Revision])) then Exit;
  finally
    FLock.Leave;
  end;
  // A file that has failed repeatedly is not retried for its remaining revisions. Some
  // archives cannot be fetched at all ("No files found under ..."), and one of them had
  // 1,241 revisions - four retries each would have burnt over an hour to no purpose.
  FLock.Enter;
  try
    // DELIBERATELY NOT SKIPPING WHOLE FILES ANY MORE.
    // Writing off a file after N failures was tried twice and lost real history both times:
    // first 13 files / 5,882 revisions at 10 workers, then 3 more at 6 workers - including
    // files proven fetchable by hand seconds later. Empty results under load are
    // indistinguishable from a dead archive, so every revision now gets its own retries and
    // its own entry in failed.csv. The cost is wasted retries on genuinely dead archives;
    // the alternative is silently missing history, which is far worse.

  finally
    FLock.Leave;
  end;
  WaitIfPaused;
  Item(Format('%s @ %s', [R.TCPath, R.Revision]));
  // one clean folder per revision, so we always know exactly what came back
  Tmp := TPath.Combine(FOpt.WorkDir, 'fetch-' + TGuid.NewGuid.ToString.Substring(1, 8));
  TDirectory.CreateDirectory(Tmp);
  try
    // MEASURED HAZARD: under concurrency tc.exe sometimes returns exit 0 having written
    // NOTHING. Trusting the exit code alone silently drops that revision's content. The
    // metadata records each revision's original size, so that is used as the check: if a
    // revision is supposed to have bytes and none arrived, the fetch failed - retry it.
    Rc := -1;
    Ok := False;
    NoStoredFile := False;
    SuspectLink := False;
    ListFile := '';
    CheckFile := False;
    Names := nil;
    // MEASURED: about 6%% of fetches come back empty under load, at 2 threads as much as 4,
    // and every one of them succeeds on a later serial retry. So the answer is more patience
    // rather than fewer workers: eight attempts with a growing pause, up to ~30s total.
    for Attempt := 1 to 8 do
    begin
      if Cancelled then Exit;
      // MEASURED: tc.exe cannot parse a path containing a space, even quoted - it silently
      // falls back to the current folder and reports "No files found under ...". 117 files
      // and 1,927 revisions (4.3%%) are affected. Passing the path in a list file bypasses
      // the command-line parser and works.
      if FOpt.UseDll then
      begin
        // Straight through the DLL on the session already open: no process to start, no
        // command line to be misparsed, and so no need for the list-file workaround below.
        // ~930 ms per revision cheaper than spawning tc.exe.
        Out1 := '';
        Rc := FSession.GetRevisionContent(R.FileID, R.Revision, Tmp);
      end
      else if Pos(' ', R.TCPath) > 0 then
      begin
        ListFile := TPath.Combine(Tmp, '_path.txt');
        TFile.WriteAllText(ListFile, R.TCPath + sLineBreak, TEncoding.ASCII);
        Rc := RunProcess(FOpt.TcExe,
          Format('Get "@%s" -VR%s "-GL%s" -W -T', [ListFile, R.Revision, Tmp]),
          FOpt.WorkDir, Out1);
      end
      else
        Rc := RunProcess(FOpt.TcExe,
          Format('Get "%s" -VR%s "-GL%s" -W -T', [R.TCPath, R.Revision, Tmp]),
          FOpt.WorkDir, Out1);

      Names := TDirectory.GetFiles(Tmp, '*', TSearchOption.soAllDirectories);
      // the list file itself is not content
      if (Length(Names) > 0) and (ListFile <> '') then
      begin
        Keep := nil;
        for J := 0 to High(Names) do
          if not SameText(Names[J], ListFile) then
          begin
            SetLength(Keep, Length(Keep) + 1);
            Keep[High(Keep)] := Names[J];
          end;
        Names := Keep;
      end;
      GotBytes := 0;
      for J := 0 to High(Names) do
        GotBytes := GotBytes + TFile.GetSize(Names[J]);

      // success is content arriving, or a revision that genuinely has none
      Ok := (Rc = 0) and ((Length(Names) > 0) or (R.Size <= 0));
      if Ok then Break;

      // Exit 85 / "No file is available for this Revision" is Team Coherence telling us it
      // holds no content for this revision - permanent, and common on old revisions of
      // heavily-revised files. Retrying it is pointless and counting it as a network
      // failure is wrong: five of them on one file once looked like a dropped link.
      if (Rc = 85) or ContainsText(Out1, 'No file is available') then
      begin
        NoStoredFile := True;
        Break;
      end;

      if Attempt < 8 then
      begin
        Sleep(800 * Attempt);
        // start each attempt from a clean folder so a partial result cannot be mistaken
        // for a complete one
        try
          TDirectory.Delete(Tmp, True);
          TDirectory.CreateDirectory(Tmp);
        except
          // if the folder cannot be recycled, the next attempt still overwrites into it
        end;
      end;
    end;

    if NoStoredFile then
    begin
      FLock.Enter;
      try
        Inc(FEmpty);
        FSkippedRows.Add(Format('%d,%s,%s,Team Coherence has no stored file for this revision',
          [R.FileID, R.TCPath, R.Revision]));
        // Remember it, and persist it: asking the server again on every restart costs a
        // round trip per revision for an answer that can never change.
        FHaveBlob.AddOrSetValue(Format('%d|%s', [R.FileID, R.Revision]), True);
        if FSkippedRows.Count >= 50 then
        begin
          AppendSkipped(FSkippedRows.ToStringArray);
          FSkippedRows.Clear;
        end;
      finally
        FLock.Leave;
      end;
      Exit;
    end;

    if not Ok then
    begin
      FLock.Enter;
      try
        Inc(FFailed);
        Inc(FConsecFail);
        if Rc <> 0 then
          Log(Format('  FAILED %s@%s (exit %d) %s',
            [R.TCPath, R.Revision, Rc, Copy(Trim(Out1), 1, 120)]))
        else
          Log(Format('  FAILED %s@%s - expected %d bytes, got nothing (after 8 tries)',
            [R.TCPath, R.Revision, R.Size]));
        FFailedRows.Add(Format('%d,%s,%s,expected %d bytes, nothing returned',
          [R.FileID, R.TCPath, R.Revision, R.Size]));
        if FBadFile.ContainsKey(R.FileID) then FBadFile[R.FileID] := FBadFile[R.FileID] + 1
        else FBadFile.Add(R.FileID, 1);
        CheckFile := False;   // see the note above: files are never written off
        SuspectLink := (FConsecFail >= 5) and not FConnLost;
      finally
        FLock.Leave;
      end;

      // Never condemn a file on a count alone - PROVE it is unfetchable by asking for its
      // tip. Counting strikes wrongly wrote off 15 healthy files (10,900 revisions, 24% of
      // the history) when the real cause was concurrent access to one archive.
      if CheckFile then
      begin
        if FileIsFetchable(R.TCPath) then
        begin
          FLock.Enter;
          try
            FBadFile.Remove(R.FileID);
            Log(Format('  (%s does fetch at tip - keeping it, failures were transient)',
              [R.TCPath]));
          finally
            FLock.Leave;
          end;
        end
        else
        begin
          FLock.Enter;
          try
            FBadFile[R.FileID] := 999;     // proven unfetchable
            Log(Format('  -> %s cannot be fetched at any revision; the rest are skipped',
              [R.TCPath]));
          finally
            FLock.Leave;
          end;
        end;
      end;

      // Do not INFER a dropped connection from a run of failures - verify it. Five failures
      // on one unfetchable file is not the same thing as the link being down, and stopping
      // the whole migration for it wasted a run.
      if SuspectLink then
      begin
        if TestConnection then
        begin
          FLock.Enter;
          try
            FConsecFail := 0;
            Log('  (several failures in a row, but the server still answers - carrying on)');
          finally
            FLock.Leave;
          end;
        end
        else
        begin
          FLock.Enter;
          try
            FConnLost := True;
            Log('');
            Log('*** CONNECTION LOST - the server stopped answering. Stopping. ***');
            Log('*** Nothing is committed for an incomplete batch, so re-running once the');
            Log('*** connection is back continues from the last completed check-in.');
          finally
            FLock.Leave;
          end;
        end;
      end;
      Exit;
    end;

    FLock.Enter;
    try
      FConsecFail := 0;      // a success clears the run of failures
    finally
      FLock.Leave;
    end;

    if Length(Names) = 0 then
    begin
      // The metadata says this revision has no bytes, and none arrived. Consistent, so it
      // is recorded and skipped rather than treated as an error.
      FLock.Enter;
      try
        Inc(FEmpty);
        FSkippedRows.Add(Format('%d,%s,%s,metadata size 0 and no content returned',
          [R.FileID, R.TCPath, R.Revision]));
      finally
        FLock.Leave;
      end;
      Exit;
    end;

    for J := 0 to High(Names) do
    begin
      Sha := LowerCase(THashSHA2.GetHashStringFromFile(Names[J], SHA256));
      RelDir := Copy(Sha, 1, 2);
      Dest := TPath.Combine(TPath.Combine(FOpt.CacheDir, RelDir), Sha);

      B.FileID := R.FileID;
      B.Revision := R.Revision;
      B.Member := StringReplace(Names[J].Substring(Length(Tmp) + 1), '\', '/', [rfReplaceAll]);
      B.Sha := Sha;
      B.Size := TFile.GetSize(Names[J]);
      B.CachePath := RelDir + '/' + Sha;

      FLock.Enter;
      try
        // content-addressed: identical content is stored once, whoever gets there first
        if not TFile.Exists(Dest) then
        begin
          TDirectory.CreateDirectory(TPath.Combine(FOpt.CacheDir, RelDir));
          TFile.Copy(Names[J], Dest, True);
        end;
        FBlobs.Add(B);
        FHaveBlob.AddOrSetValue(Format('%d|%s', [B.FileID, B.Revision]), True);
        FManifest.Add(Format('%d,%s,%s,%s,%d,%s',
          [B.FileID, B.Revision, B.Member, B.Sha, B.Size, B.CachePath]));
        // Flush often. The fetch window is thousands of revisions wide, and waiting until
        // the end of it would mean a crash left files on disk that no later run knew about.
        if FManifest.Count >= 100 then
        begin
          AppendManifest(FManifest.ToStringArray);
          FManifest.Clear;
        end;
      finally
        FLock.Leave;
      end;
    end;
  finally
    // the in-flight marker is released by the worker that claimed it, not here - every
    // early exit above would otherwise leave the archive marked busy for ever, which
    // deadlocked the whole run.
    try
      TDirectory.Delete(Tmp, True);
    except
      // a locked temp folder must not fail the whole fetch
    end;
  end;
end;
procedure TPipeline.FetchAll;
var
  Workers: TArray<TFetchWorker>;
  Total, I, N, LastDone: Integer;
  Running: Boolean;
begin
  TDirectory.CreateDirectory(FOpt.CacheDir);
  FBlobs.Clear;
  FManifest.Clear;
  FManifest.Add('file_id,revision,member,sha256,size,cache_path');
  FNextIdx := 0;
  FDone := 0;
  FFailed := 0;
  Total := FSession.Revisions.Count;
  if Total = 0 then Exit;

  N := FOpt.FetchThreads;
  if N < 1 then N := 1;
  if FOpt.UseDll then N := 1;   // see FetchRange
  // MEASURED CEILING: at 10 workers the server began returning empty results for healthy
  // archives, which this program can only read as "unfetchable". Six ran for hours with no
  // failures at all. Do not raise this to chase throughput.
  if N > 6 then
  begin
    Log(Format('  capping fetch workers at 6 (asked for %d): above that the server returns', [N]));
    Log('  empty results for healthy archives, which looks exactly like missing data.');
    N := 6;
  end;
  Log(Format('Fetching %d revisions with %d parallel workers...', [Total, N]));

  SetLength(Workers, N);
  for I := 0 to N - 1 do
    Workers[I] := TFetchWorker.Create(Self, Total);
  try
    LastDone := -1;
    repeat
      Sleep(150);
      if FDone <> LastDone then
      begin
        LastDone := FDone;
        Progress('Fetching file contents', FDone, Total);
        Item(Format('%d blobs cached, %d failures', [FBlobs.Count, FFailed]));
      end;
      Running := False;
      for I := 0 to N - 1 do
        if not Workers[I].Finished then Running := True;
    until not Running;
  finally
    for I := 0 to N - 1 do
    begin
      Workers[I].Terminate;
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
  end;

  FManifest.WriteBOM := False;
  FManifest.SaveToFile(TPath.Combine(FOpt.MetaDir, 'blobs.csv'), TEncoding.UTF8);
  Progress('Fetching file contents', Total, Total);
  Log(Format('Fetched %d blobs from %d revisions, %d failures.', [FBlobs.Count, Total, FFailed]));
end;

function TPipeline.StartFastImport(out ProcInfo: TProcessInformation;
  out StdInWrite: THandle): Boolean;
// Starts git fast-import reading from a pipe instead of a file.
//
// The stream carries every blob inline, so staging it on disk costs as much space again as
// the whole blob cache - about 10 GB for this repository. Feeding git directly removes that
// peak entirely, which is the difference between fitting on this disk and not.
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  ChildRead, OutRead, OutWrite: THandle;
  Cmd: string;
begin
  Result := False;
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;

  if not CreatePipe(ChildRead, StdInWrite, @SA, 1024 * 1024) then Exit;
  // git must not inherit our writing end, or it never sees end-of-input
  SetHandleInformation(StdInWrite, HANDLE_FLAG_INHERIT, 0);

  // A generous output buffer: we only drain git's output after the stream is written, so a
  // chatty error must not block git (and deadlock us) before we get there.
  if not CreatePipe(OutRead, OutWrite, @SA, 1024 * 1024) then
  begin
    CloseHandle(ChildRead);
    CloseHandle(StdInWrite);
    Exit;
  end;
  SetHandleInformation(OutRead, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := ChildRead;
  SI.hStdOutput := OutWrite;
  SI.hStdError := OutWrite;

  Cmd := Format('"%s" fast-import --quiet --max-pack-size=1g', [FOpt.GitExe]);
  Result := CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW,
                          nil, PChar(FOpt.RepoDir), SI, ProcInfo);

  // the child owns its ends now
  CloseHandle(ChildRead);
  CloseHandle(OutWrite);
  if Result then FGitOutRead := OutRead else CloseHandle(OutRead);
  if not Result then CloseHandle(StdInWrite);
end;

function TPipeline.FinishFastImport(var ProcInfo: TProcessInformation;
  var StdInWrite: THandle; out Output: string): Integer;
var
  Buf: array[0..4095] of AnsiChar;
  Read, Avail: DWORD;
  Res: AnsiString;
begin
  // Closing our end is what tells fast-import the stream is complete.
  if StdInWrite <> 0 then
  begin
    CloseHandle(StdInWrite);
    StdInWrite := 0;
  end;

  Res := '';
  repeat
    while PeekNamedPipe(FGitOutRead, nil, 0, nil, @Avail, nil) and (Avail > 0) do
    begin
      if not ReadFile(FGitOutRead, Buf, SizeOf(Buf) - 1, Read, nil) or (Read = 0) then Break;
      Buf[Read] := #0;
      Res := Res + AnsiString(Buf);
    end;
  until WaitForSingleObject(ProcInfo.hProcess, 100) <> WAIT_TIMEOUT;

  GetExitCodeProcess(ProcInfo.hProcess, DWORD(Result));
  Output := string(Res);
  CloseHandle(ProcInfo.hProcess);
  CloseHandle(ProcInfo.hThread);
  CloseHandle(FGitOutRead);
  FGitOutRead := 0;
end;

// ---------------------------------------------------------------- build + import

type
  TChange = record
    Path, Sha: string;
  end;

// ============================================================================================
// DEAD CODE - NOTHING CALLS THIS. Kept only because it is the original whole-repository import.
//
// It cost real damage: it contains the ONLY tag-writing code the project had, so `--tags` looked
// implemented for weeks while every run that used it enumerated 44,450 label attachments and then
// created no refs at all. The live path is RunIncremental -> ImportRange, and labels are now
// handled by ImportTags. Do not add anything here expecting it to run.
// ============================================================================================
procedure TPipeline.BuildAndImport;
var
  StreamFile: string;
  FS: TStream;
  GitProc: TProcessInformation;
  GitIn: THandle;
  Piped: Boolean;
  Marks: TDictionary<string, Integer>;
  Order: TList<Integer>;
  I, J, K, Mark, CommitCount, TagCount: Integer;
  Revs: TArray<TTCRevision>;
  R: TTCRevision;
  B: TBlob;
  Author, Comment, Ep: string;
  GroupStart: TDateTime;
  GroupAuthor, GroupComment: string;
  Pending: TList<TChange>;
  Chg: TChange;
  Out1: string;
  Rc: Integer;

  // fast-import is a byte stream, not a text file: a blob is 'data <count>' followed by
  // exactly that many raw bytes. Anything that re-encodes would corrupt every binary file
  // (and every DFM), so everything is written as bytes.
  procedure Put(const Line: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.UTF8.GetBytes(Line + #10);
    FS.WriteBuffer(Bytes[0], Length(Bytes));
  end;

  procedure PutFileBytes(const FileName: string);
  var
    Src: TFileStream;
    LF: Byte;
  begin
    Src := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      FS.CopyFrom(Src, 0);
    finally
      Src.Free;
    end;
    LF := 10;
    FS.WriteBuffer(LF, 1);
  end;

  procedure EmitBlobsFor(const Rev: TTCRevision);
  var
    N: Integer;
    Bl: TBlob;
    CacheFile: string;
  begin
    for N := 0 to FBlobs.Count - 1 do
    begin
      Bl := FBlobs[N];
      if (Bl.FileID <> Rev.FileID) or (Bl.Revision <> Rev.Revision) then Continue;
      if not Marks.ContainsKey(Bl.Sha) then
      begin
        CacheFile := TPath.Combine(FOpt.CacheDir,
          StringReplace(Bl.CachePath, '/', PathDelim, [rfReplaceAll]));
        if not TFile.Exists(CacheFile) then
        begin
          Log('  missing cached blob: ' + Bl.CachePath);
          Continue;
        end;
        Inc(Mark);
        Marks.Add(Bl.Sha, Mark);
        Put('blob');
        Put('mark :' + IntToStr(Mark));
        Put('data ' + IntToStr(TFile.GetSize(CacheFile)));
        PutFileBytes(CacheFile);
      end;
      Chg.Path := MemberPath(Rev.TCPath, Bl.Member);
      Chg.Sha := Bl.Sha;
      Pending.Add(Chg);
    end;
  end;

  procedure FlushCommit;
  var
    N: Integer;
    Msg: string;
  begin
    if Pending.Count = 0 then Exit;
    Inc(CommitCount);
    Msg := GroupComment;
    if Trim(Msg) = '' then Msg := '(no check-in comment)';
    Put('commit refs/heads/' + FOpt.Branch);
    Put(Format('committer %s %d +0000',
      [MapAuthor(GroupAuthor), DateTimeToUnix(GroupStart, True)]));   // UTC, matching uTCApi
    Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
    Put(Msg);
    for N := 0 to Pending.Count - 1 do
      if Marks.ContainsKey(Pending[N].Sha) then
        Put(Format('M 100644 :%d %s', [Marks[Pending[N].Sha], Pending[N].Path]));
    Pending.Clear;
  end;

begin
  LoadAuthorMap;
  StreamFile := TPath.Combine(FOpt.WorkDir, 'stream.fi');
  Marks := TDictionary<string, Integer>.Create;
  Pending := TList<TChange>.Create;
  Order := TList<Integer>.Create;
  try
    // check-ins in time order; a changeset is a run of revisions by the same author with the
    // same comment inside the grouping window (the cvs2git approach)
    Revs := FSession.Revisions.ToArray;
    TArray.Sort<TTCRevision>(Revs, TComparer<TTCRevision>.Construct(
      function(const A, B: TTCRevision): Integer
      begin
        Result := CompareDateTime(A.When, B.When);
        if Result = 0 then Result := CompareStr(A.Author, B.Author);
      end));

    // the repository must exist before fast-import is started
    if not TDirectory.Exists(FOpt.RepoDir) then
    begin
      TDirectory.CreateDirectory(FOpt.RepoDir);
      RunProcess(FOpt.GitExe, 'init --bare', FOpt.RepoDir, Out1);
      Log('Created bare repository: ' + FOpt.RepoDir);
    end;

    Mark := 0;
    CommitCount := 0;
    TagCount := 0;
    // Feed git directly. The stream contains every blob inline, so writing it to disk
    // would need as much free space again as the entire blob cache.
    GitIn := 0;
    Piped := StartFastImport(GitProc, GitIn);
    if Piped then
    begin
      FS := THandleStream.Create(GitIn);
      Log('Streaming directly into git fast-import (no intermediate file).');
    end
    else
    begin
      FS := TFileStream.Create(StreamFile, fmCreate);
      Log('Could not start git fast-import; writing the stream to disk instead.');
    end;
    try
      GroupAuthor := #0;
      GroupComment := #0;
      GroupStart := 0;
      for I := 0 to High(Revs) do
      begin
        if Cancelled then Break;
        R := Revs[I];
        if (R.Author <> GroupAuthor) or (R.Comment <> GroupComment) or
           (SecondsBetween(R.When, GroupStart) > FOpt.WindowSeconds) then
        begin
          FlushCommit;
          GroupAuthor := R.Author;
          GroupComment := R.Comment;
          GroupStart := R.When;
        end;
        EmitBlobsFor(R);
        if (I mod 50 = 0) or (I = High(Revs)) then
          Progress('Building the git history', I + 1, Length(Revs));
      end;
      FlushCommit;

      // Tags: a label's attachment list IS the label, so rebuild that exact tree.
      if FOpt.IncludeTags then
        for I := 0 to FSession.Labels.Count - 1 do
        begin
          if Cancelled then Break;
          if FSession.Labels[I].LabelType <> 1 then Continue;
          Pending.Clear;
          for J := 0 to FSession.Attachments.Count - 1 do
            if FSession.Attachments[J].LabelID = FSession.Labels[I].ID then
              for K := 0 to FSession.Revisions.Count - 1 do
                if (FSession.Revisions[K].FileID = FSession.Attachments[J].FileID) and
                   (FSession.Revisions[K].Revision = FSession.Attachments[J].Revision) then
                begin
                  EmitBlobsFor(FSession.Revisions[K]);
                  Break;
                end;
          if Pending.Count = 0 then Continue;
          Inc(TagCount);
          Ep := 'refs/heads/tc/label/' + StringReplace(FSession.Labels[I].Name, ' ', '_', [rfReplaceAll]);
          Put('commit ' + Ep);
          Put(Format('committer %s %d +0000',
            [MapAuthor('tc'), DateTimeToUnix(FSession.Labels[I].When, True)]));
          Comment := FSession.Labels[I].Name + #10 + FSession.Labels[I].Comment;
          Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Comment))));
          Put(Comment);
          Put('deleteall');        // the label defines the whole tree, not a delta
          for J := 0 to Pending.Count - 1 do
            if Marks.ContainsKey(Pending[J].Sha) then
              Put(Format('M 100644 :%d %s', [Marks[Pending[J].Sha], Pending[J].Path]));
          Pending.Clear;
          Progress('Rebuilding labels as tags', I + 1, FSession.Labels.Count);
        end;
    finally
      FS.Free;
    end;
    if Piped then
    begin
      Log(Format('Streamed: %d commits, %d label trees, %d blobs. Waiting for git...',
        [CommitCount, TagCount, Marks.Count]));
      Progress('Importing into git', 0, 1);
      Rc := FinishFastImport(GitProc, GitIn, Out1);
    end
    else
    begin
      Log(Format('Stream written: %d commits, %d label trees, %d blobs -> %s',
        [CommitCount, TagCount, Marks.Count, StreamFile]));
      Progress('Importing into git', 0, 1);
      Rc := RunProcess(FOpt.GitExe, 'fast-import --quiet --max-pack-size=1g',
        FOpt.RepoDir, Out1, StreamFile);
    end;
    if Rc <> 0 then
    begin
      Log('git fast-import FAILED:');
      Log(Out1);
      raise Exception.Create('git fast-import failed - see the log.');
    end;
    Progress('Importing into git', 1, 1);
    Log('Import complete.');
  finally
    Marks.Free;
    Pending.Free;
    Order.Free;
  end;
end;

// ---------------------------------------------------------------- connection heartbeat
//
// Watches the link and PAUSES fetching while it is down, instead of letting every revision
// burn eight retries and then abandoning the batch. When the server answers again it
// re-anchors the current folder (a reconnect leaves the client's folder cache stale, which
// makes absolute paths resolve against the wrong folder) and lets the workers carry on.
//
// The effect is that an outage costs only the outage: no lost batch, no phantom failures,
// no restart.

type
  THeartbeatThread = class(TThread)
  private
    FPipe: TPipeline;
    FTick: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APipe: TPipeline);
  end;

constructor THeartbeatThread.Create(APipe: TPipeline);
begin
  FPipe := APipe;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure THeartbeatThread.Execute;
var
  Up: Boolean;
  Waited: Integer;
begin
  NameThreadForDebugging('TC heartbeat');
  Waited := 0;
  while not Terminated do
  begin
    Up := FPipe.ServerAnswers;
    if not Up and not FPipe.FPaused then
    begin
      FPipe.FPaused := True;
      FPipe.Log('');
      FPipe.Log('*** CONNECTION DOWN - pausing. Nothing is retried while it is down. ***');
      FPipe.Counters('connection down - waiting for it to come back');
      Waited := 0;
    end
    else if Up and FPipe.FPaused then
    begin
      // A reconnect can leave the client pointing at the wrong folder, so re-anchor before
      // any more fetches go out.
      FPipe.ReAnchorFolder;
      FPipe.FPaused := False;
      FPipe.Log(Format('*** CONNECTION BACK after %d seconds - resuming. ***', [Waited]));
    end
    else if not Up then
    begin
      Inc(Waited, 10);
      if (Waited mod 60) = 0 then
        FPipe.Counters(Format('connection still down - waiting (%d seconds)', [Waited]));
    end;

    // A status line on a timer, whether or not anything changed: silence and a stall look
    // identical otherwise, and someone watching should never have to guess.
    Inc(FTick);
    if (FTick mod 6) = 0 then FPipe.Log(FPipe.StatusLine);

    // short sleeps so Terminate is honoured promptly
    for var I := 1 to 10 do
    begin
      if Terminated then Exit;
      Sleep(1000);
    end;
  end;
end;

function TPipeline.StatusLine: string;
// One line that answers "is this healthy and how long will it take" without anyone having to
// go digging. Emitted on a timer whether or not anything changed, because a log that only
// speaks when something happens cannot be told apart from a log that has stopped.
var
  Done, Total, Secs, Left: Integer;
  Rate: Double;
  Eta, Cur: string;
begin
  // Never go backwards. FOverallBase is the start of the current batch while FDone counts a
  // fetch window that runs several batches ahead, so at a batch boundary the raw sum drops -
  // the percentage steps back and, because the rate is measured from where this process began,
  // it falls to 0.0/s with an ETA of tens of hours. The job is fine; only the arithmetic is
  // wrong, and it has repeatedly been read as a hang.
  Done := FOverallBase + FDone;
  if Done < FDoneHigh then Done := FDoneHigh else FDoneHigh := Done;
  Total := FOverallTotal;
  if Total <= 0 then Total := 1;
  Secs := SecondsBetween(Now, FRunStarted);
  Rate := 0;
  if (Secs > 0) and (Done > FStartedAt) then Rate := (Done - FStartedAt) / Secs;

  if Rate > 0.01 then
  begin
    Left := Round((Total - Done) / Rate);
    Eta := Format('%.2d:%.2d:%.2d', [Left div 3600, (Left mod 3600) div 60, Left mod 60]);
  end
  else
    Eta := '--:--:--';

  FLock.Enter;
  try
    Cur := FCurrentItem;
  finally
    FLock.Leave;
  end;
  if Cur = '' then Cur := '(nothing in flight)';

  Result := Format(
    'STATUS  %s  %.1f%% (%d/%d)  blobs %d  no-content %d  failed %d  %.1f/s  eta %s%s'#13#10 +
    '        now: %s',
    [FPhaseName, Done / Total * 100, Done, Total, FBlobs.Count, FEmpty, FFailed,
     Rate, Eta, IfThen(FPaused, '  [PAUSED - connection down]', ''), Cur]);
end;

function TPipeline.ServerAnswers: Boolean;
// A plain TCP connect, so a down link costs a second rather than a hung Get.
var
  WSA: TWSAData;
  Sock: TSocket;
  Addr: TSockAddrIn;
  Mode: u_long;
  FDs: TFDSet;
  TV: TTimeVal;
begin
  Result := True;
  if (FSession.Host = '') or (FSession.Port = 0) then Exit;
  if WSAStartup($0202, WSA) <> 0 then Exit;
  try
    Sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if Sock = INVALID_SOCKET then Exit;
    try
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := htons(FSession.Port);
      Addr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(FSession.Host)));
      if Addr.sin_addr.S_addr = INADDR_NONE then Exit;
      Mode := 1;
      ioctlsocket(Sock, FIONBIO, Mode);
      if connect(Sock, TSockAddr(Addr), SizeOf(Addr)) = 0 then Exit(True);
      FD_ZERO(FDs);
      FD_SET(Sock, FDs);
      TV.tv_sec := 3;
      TV.tv_usec := 0;
      Result := select(0, nil, @FDs, nil, @TV) > 0;
    finally
      closesocket(Sock);
    end;
  finally
    WSACleanup;
  end;
end;

procedure TPipeline.ReAnchorFolder;
var
  Output: string;
begin
  if FOpt.Project = '' then Exit;
  RunProcess(FOpt.TcExe, Format('CD "%s" -T', [FOpt.Project]), FOpt.WorkDir, Output);
end;

procedure TPipeline.WaitIfPaused;
begin
  // Called before every fetch. While the link is down the workers idle here instead of
  // failing revisions, so an outage produces no failures at all.
  while FPaused and not Cancelled do
    Sleep(1000);
end;

// ---------------------------------------------------------------- incremental run
//
// The migration is processed in chronological order, oldest check-in first, in batches.
// Each batch is fetched, committed to git, and then recorded in state.txt. A run that is
// stopped - or that dies - resumes from the last completed batch instead of starting again.
//
// Three things make that safe:
//   * the blob cache is content-addressed and blobs.csv records every (file, revision)
//     already fetched, so nothing is downloaded twice;
//   * each batch ends at a changeset boundary, so a commit is never half-written;
//   * git fast-import is run once per batch and the branch tip is picked up from the
//     repository, so commits continue the existing history rather than forking it.



function TPipeline.FileIsFetchable(const TCPath: string): Boolean;
// Asks for the file's tip. If that comes back, the archive is fine and any failures on
// individual revisions were transient - so the file must not be written off.
//
// Tried several times with a pause between: under heavy concurrency the server returns
// empty results even for healthy archives, and a single failed check once condemned 13
// perfectly good files - 5,882 revisions of real history.
var
  Dir, Out1: string;
  Attempt: Integer;
begin
  Result := False;
  for Attempt := 1 to 3 do
  begin
    Dir := TPath.Combine(FOpt.WorkDir, 'check-' + TGuid.NewGuid.ToString.Substring(1, 8));
    TDirectory.CreateDirectory(Dir);
    try
      RunProcess(FOpt.TcExe, Format('Get "%s" "-GL%s" -W -T', [TCPath, Dir]), FOpt.WorkDir, Out1);
      Result := Length(TDirectory.GetFiles(Dir, '*', TSearchOption.soAllDirectories)) > 0;
    finally
      try
        TDirectory.Delete(Dir, True);
      except
      end;
    end;
    if Result then Exit;
    Sleep(2000);
  end;
end;

function TPipeline.TestConnection: Boolean;
// 'Views' is a cheap read that has to reach the server, so it answers "is the link up?"
// in about a second - long before thousands of Get calls start failing one by one.
var
  Out1: string;
begin
  // WorkDir, not RepoDir: the repository may not exist yet at this point, and
  // CreateProcess fails outright if its working directory does not exist - which looked
  // exactly like the server being down.
  Result := RunProcess(FOpt.TcExe, 'Views -T', FOpt.WorkDir, Out1) = 0;
  if not Result then
    Log('Server did not answer: ' + Copy(Trim(Out1), 1, 200));
end;

function TPipeline.StatePath: string;
begin
  Result := TPath.Combine(FOpt.WorkDir, 'state.txt');
end;

function TPipeline.ReadCheckpoint: Integer;
var
  L: TStringList;
begin
  Result := 0;
  if not TFile.Exists(StatePath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(StatePath);
    Result := StrToIntDef(Trim(L.Values['committed']), 0);
  except
    Result := 0;
  end;
  L.Free;
end;

procedure TPipeline.WriteCheckpoint(Index: Integer; const Extra: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Values['committed'] := IntToStr(Index);
    L.Values['branch'] := FOpt.Branch;
    L.Values['updated'] := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    if Extra <> '' then L.Values['note'] := Extra;
    // Record the branch tip with the checkpoint. If a crash lands between an import and
    // this write, the repository holds commits the checkpoint does not know about; on the
    // next run the branch is rewound to this tip so that batch is redone exactly once
    // instead of being duplicated.
    RunProcess(FOpt.GitExe, 'rev-parse --verify --quiet refs/heads/' + FOpt.Branch,
               FOpt.RepoDir, FLastOut);
    L.Values['tip'] := Trim(FLastOut);
    L.SaveToFile(StatePath);
  finally
    L.Free;
  end;
end;


procedure TPipeline.RewindToCheckpointTip;
// Discards anything committed after the last checkpoint, so a resume cannot duplicate a
// batch that was imported but not recorded.
var
  L: TStringList;
  Recorded, Actual: string;
begin
  if not TFile.Exists(StatePath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(StatePath);
    Recorded := Trim(L.Values['tip']);
  finally
    L.Free;
  end;
  if Recorded = '' then Exit;

  RunProcess(FOpt.GitExe, 'rev-parse --verify --quiet refs/heads/' + FOpt.Branch,
             FOpt.RepoDir, Actual);
  Actual := Trim(Actual);
  if (Actual <> '') and (Actual <> Recorded) then
  begin
    Log(Format('Repository tip %s is ahead of the last checkpoint %s - rewinding so the',
      [Copy(Actual, 1, 8), Copy(Recorded, 1, 8)]));
    Log('interrupted batch is redone once rather than duplicated.');
    RunProcess(FOpt.GitExe,
      Format('update-ref refs/heads/%s %s', [FOpt.Branch, Recorded]), FOpt.RepoDir, FLastOut);
  end;
end;

procedure TPipeline.LoadBlobManifest;
var
  L: TStringList;
  I, Known: Integer;
  C: TArray<string>;
  B: TBlob;
  SkipPath: string;
begin
  FBlobs.Clear;
  FHaveBlob.Clear;
  if not TFile.Exists(TPath.Combine(FOpt.MetaDir, 'blobs.csv')) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(TPath.Combine(FOpt.MetaDir, 'blobs.csv'), TEncoding.UTF8);
    for I := 1 to L.Count - 1 do
    begin
      if L[I] = '' then Continue;
      C := L[I].Split([',']);
      if Length(C) < 6 then Continue;
      B.FileID := StrToUIntDef(C[0], 0);
      B.Revision := C[1];
      B.Member := C[2];
      B.Sha := C[3];
      B.Size := StrToInt64Def(C[4], 0);
      B.CachePath := C[5];
      FBlobs.Add(B);
      FHaveBlob.AddOrSetValue(Format('%d|%s', [B.FileID, B.Revision]), True);
    end;
    Log(Format('Resuming with %d blobs already fetched (%d revisions).',
      [FBlobs.Count, FHaveBlob.Count]));
  finally
    L.Free;
  end;

  // Revisions Team Coherence has no stored file for: that answer cannot change, so treat
  // them as done. Without this, every supervisor restart pays a server round trip per
  // revision to be told the same thing again - 200 of them cost three minutes.
  SkipPath := TPath.Combine(FOpt.MetaDir, 'skipped.csv');
  if TFile.Exists(SkipPath) then
  begin
    L := TStringList.Create;
    try
      L.LoadFromFile(SkipPath, TEncoding.UTF8);
      Known := 0;
      for I := 1 to L.Count - 1 do
      begin
        if L[I] = '' then Continue;
        C := L[I].Split([',']);
        if Length(C) < 3 then Continue;
        FHaveBlob.AddOrSetValue(Format('%s|%s', [C[0], C[2]]), True);
        Inc(Known);
      end;
      if Known > 0 then
        Log(Format('Also skipping %d revisions already known to have no stored file.', [Known]));
    finally
      L.Free;
    end;
  end;
end;

procedure TPipeline.FetchRange(StartIdx, EndIdx: Integer);
var
  Workers: TArray<TFetchWorker>;
  I, N, LastLogged: Integer;
  Running: Boolean;
begin
  LastLogged := 0;
  FRangeStart := StartIdx;
  FRangeEnd := EndIdx;
  FNextIdx := 0;
  FDone := 0;
  FStartedAt := FOverallBase;
  // the batch as a claimable pool, so a worker can skip a busy archive instead of waiting
  FLock.Enter;
  try
    FPending.Clear;
    for I := StartIdx to EndIdx - 1 do FPending.Add(I);
  finally
    FLock.Leave;
  end;
  N := FOpt.FetchThreads;
  if N < 1 then N := 1;
  if N > 16 then N := 16;
  // DLL calls are serialised inside the session, so extra workers would only queue on the
  // lock while multiplying the risk of concurrent access to a library whose thread-safety is
  // undocumented. One worker was measured fastest for the CLI path too.
  if FOpt.UseDll then N := 1;

  SetLength(Workers, N);
  for I := 0 to N - 1 do
    Workers[I] := TFetchWorker.Create(Self, EndIdx);
  try
    repeat
      Sleep(100);
      Running := False;
      for I := 0 to N - 1 do
        if not Workers[I].Finished then Running := True;

      // Every poll, so the window never looks frozen: at half a revision per second the
      // old every-200-items update left the display unchanged for six minutes at a time.
      Progress('Fetching file contents', FDone, EndIdx - StartIdx);
      Overall(FOverallBase + FDone, FOverallTotal);
      Counters(Format('blobs %d   no content %d   failed %d   fetching %d of %d in this window',
        [FBlobs.Count, FEmpty, FFailed, FDone, EndIdx - StartIdx]));

      // The fetch window spans thousands of revisions, so without this the log would be
      // silent for a long stretch and a slow run would be indistinguishable from a hung one.
      if FDone - LastLogged >= 200 then
      begin
        LastLogged := FDone;
        Log(Format('    %d of %d in this window: %d blobs, %d with no stored file, %d failed',
          [FDone, EndIdx - StartIdx, FBlobs.Count, FEmpty, FFailed]));
        Progress('Fetching file contents', FDone, EndIdx - StartIdx);
      end;
    until not Running;
  finally
    for I := 0 to N - 1 do
    begin
      Workers[I].Terminate;
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
  end;
  // persist what this batch fetched before the batch is committed, so a crash between
  // fetch and import still leaves the content recorded and reusable
  FLock.Enter;
  try
    AppendManifest(FManifest.ToStringArray);
    FManifest.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TPipeline.MergeSaveCsv(const Name, Header: string; Rows: TStrings);
// Write an exception report WITHOUT discarding what earlier runs recorded.
//
// "Team Coherence has no stored file for this revision" is a permanent fact, accumulated over
// many runs, and it is what stops the next run asking the server the same 2,450 questions.
// The previous code saved only the current run's findings over the top: a from-scratch run on
// 2026-09-26 truncated skipped.csv from 2,450 rows to 7. That does not corrupt the repository -
// a revision with no content contributes nothing either way - but it throws away roughly forty
// minutes of server round trips, and it made the resolved/unresolved accounting look as though
// the run had gone backwards.
var
  Path: string;
  Existing, Merged: TStringList;
  Seen: TDictionary<string, Boolean>;
  I: Integer;
begin
  if Rows.Count = 0 then Exit;
  Path := TPath.Combine(FOpt.MetaDir, Name);
  Existing := TStringList.Create;
  Merged := TStringList.Create;
  Seen := TDictionary<string, Boolean>.Create;
  try
    if TFile.Exists(Path) then
    begin
      Existing.LoadFromFile(Path, TEncoding.UTF8);
      // start at 1: row 0 is the header
      for I := 1 to Existing.Count - 1 do
        if (Existing[I] <> '') and not Seen.ContainsKey(Existing[I]) then
        begin
          Seen.Add(Existing[I], True);
          Merged.Add(Existing[I]);
        end;
    end;
    for I := 0 to Rows.Count - 1 do
      if (Rows[I] <> '') and not Seen.ContainsKey(Rows[I]) then
      begin
        Seen.Add(Rows[I], True);
        Merged.Add(Rows[I]);
      end;
    Merged.Insert(0, Header);
    Merged.SaveToFile(Path, TEncoding.UTF8);
  finally
    Seen.Free;
    Merged.Free;
    Existing.Free;
  end;
end;

procedure TPipeline.AppendSkipped(const Rows: TArray<string>);
var
  F: TStreamWriter;
  Path: string;
  IsNew: Boolean;
begin
  if Length(Rows) = 0 then Exit;
  Path := TPath.Combine(FOpt.MetaDir, 'skipped.csv');
  IsNew := not TFile.Exists(Path);
  if IsNew then
    F := TStreamWriter.Create(TFileStream.Create(Path, fmCreate or fmShareDenyWrite), TEncoding.UTF8)
  else
    F := TStreamWriter.Create(TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite), TEncoding.UTF8);
  try
    F.OwnStream;
    if IsNew then F.WriteLine('file_id,tc_path,revision,reason')
    else F.BaseStream.Seek(0, soEnd);
    for Path in Rows do F.WriteLine(Path);
  finally
    F.Free;
  end;
end;

procedure TPipeline.AppendManifest(const Rows: TArray<string>);
var
  F: TStreamWriter;
  Path, S: string;
  IsNew: Boolean;
begin
  if Length(Rows) = 0 then Exit;
  Path := TPath.Combine(FOpt.MetaDir, 'blobs.csv');
  IsNew := not TFile.Exists(Path);
  if IsNew then
    F := TStreamWriter.Create(TFileStream.Create(Path, fmCreate or fmShareDenyWrite),
                              TEncoding.UTF8)
  else
    F := TStreamWriter.Create(TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite),
                              TEncoding.UTF8);
  try
    F.OwnStream;
    if IsNew then F.WriteLine('file_id,revision,member,sha256,size,cache_path')
    else F.BaseStream.Seek(0, soEnd);
    for S in Rows do F.WriteLine(S);
  finally
    F.Free;
  end;
end;

procedure TPipeline.RunIncremental;
var
  Revs: TArray<TTCRevision>;
  Total, Idx, BatchEnd, Done, BatchNo, FetchWindow: Integer;
  StartedAt: TDateTime;
  Secs: Double;

  function SameGroup(const A, B: TTCRevision): Boolean;
  begin
    // Team Coherence records no changeset, so a check-in is reconstructed from contiguous
    // revisions by one author sharing one comment. Contiguity is what makes that safe: an
    // exclusive-lock VCS means two people cannot touch the same file at once, and every
    // human check-in here carries a comment (all 14,292 blank ones belong to "build").
    //
    // WindowSeconds = 0 means no time limit, which is the accurate choice: a genuine
    // check-in can take hours to upload - one here spans 16 hours and 652 files - and a
    // 180-second cap shattered 2,620 real check-ins into fragments.
    //
    // This is only used to avoid cutting a batch through the middle of a group. The
    // authoritative commit boundary is in ImportRange, which ALSO splits when a file repeats
    // inside a group; groups there are therefore never larger than what this predicts, so
    // extending a batch by this rule stays conservative.
    Result := (A.Author = B.Author) and (A.Comment = B.Comment) and
              ((FOpt.WindowSeconds <= 0) or
               (SecondsBetween(A.When, B.When) <= FOpt.WindowSeconds));
  end;

begin
  if not TestConnection then
    raise Exception.Create(
      'The Team Coherence server is not reachable.'#13#10#13#10 +
      'Check the VPN, then run again - the migration continues from where it stopped.');

  LoadAuthorMap;
  LoadBlobManifest;

  // Watch the link for the whole run: an outage now pauses the workers instead of failing
  // thousands of revisions and abandoning the batch.
  FHeartbeat := THeartbeatThread.Create(Self);

  // oldest first: the history is replayed forward, exactly as it happened
  Revs := FSession.Revisions.ToArray;
  TArray.Sort<TTCRevision>(Revs, TComparer<TTCRevision>.Construct(
    function(const A, B: TTCRevision): Integer
    begin
      Result := CompareDateTime(A.When, B.When);
      if Result = 0 then Result := CompareStr(A.TCPath, B.TCPath);
      if Result = 0 then Result := CompareStr(A.Revision, B.Revision);
    end));
  Total := Length(Revs);
  if Total = 0 then Exit;

  FSorted := Revs;      // the fetch workers index into this same order

  if not TDirectory.Exists(FOpt.RepoDir) then
  begin
    TDirectory.CreateDirectory(FOpt.RepoDir);
    RunProcess(FOpt.GitExe, 'init --bare', FOpt.RepoDir, FLastOut);
    Log('Created bare repository: ' + FOpt.RepoDir);
  end;

  Idx := ReadCheckpoint;
  FFetchedTo := Idx;
  FRunStarted := Now;
  FStartedAt := Idx;
  FDoneHigh := Idx;
  // State this in the log: which fetch path ran is the first thing anyone comparing two
  // migrations needs to know, and it is not otherwise visible after the fact.
  if FOpt.UseDll then
    Log('Fetching content through the DLL (TCDVcsCheckOutFile, Lock=False), one worker.')
  else
    Log(Format('Fetching content by spawning tc.exe, %d worker(s).', [FOpt.FetchThreads]));
  FOverallTotal := Total;
  FOverallBase := Idx;
  if Idx > 0 then RewindToCheckpointTip;
  if Idx > 0 then
    Log(Format('Resuming from check-in %d of %d (previous run stopped there).', [Idx, Total]))
  else
    Log(Format('Starting from the oldest check-in, %d in total.', [Total]));

  StartedAt := Now;
  BatchNo := 0;
  while (Idx < Total) and not Cancelled do
  begin
    Inc(BatchNo);
    BatchEnd := Idx + FOpt.BatchSize;
    if BatchEnd > Total then BatchEnd := Total;
    // never cut a changeset in half: extend to the end of the group in flight
    while (BatchEnd < Total) and SameGroup(Revs[BatchEnd - 1], Revs[BatchEnd]) do
      Inc(BatchEnd);

    Item(Format('batch %d: check-ins %d-%d of %d', [BatchNo, Idx + 1, BatchEnd, Total]));
    FFailed := 0;
    FOverallBase := Idx;
    FOverallTotal := Total;
    Overall(Idx, Total);

    // Fetch from a WIDE window, not just this batch. Only the commits have to follow date
    // order; the downloads do not. A 600-check-in window in date order is dominated by a
    // few heavily-revised archives, and since one archive is never fetched twice at once,
    // that left five of six workers idle and the rate at 1.5/sec. A wider window always
    // offers enough distinct archives to keep every worker busy.
    if FFetchedTo < BatchEnd then
    begin
      FetchWindow := Idx + FOpt.BatchSize * 4;
      if FetchWindow > Total then FetchWindow := Total;
      FetchRange(FFetchedTo, FetchWindow);
      FFetchedTo := FetchWindow;
    end;
    if Cancelled or FConnLost then Break;

    // A dropped connection stops the run without committing, so the checkpoint never
    // marches past a gap. But a revision that is genuinely unfetchable must not block the
    // other 44,000: it is recorded in metaailed.csv and reported at the end, so it is
    // visible rather than silently missing.
    if FConnLost then
    begin
      Log(Format('Batch %d abandoned: the connection dropped. Nothing committed for it.',
        [BatchNo]));
      FStoppedIncomplete := True;
      Break;
    end;
    if FFailed > 0 then
      Log(Format('Batch %d: %d revision(s) could not be fetched - recorded in failed.csv ' +
        'and left out of the history.', [BatchNo, FFailed]));

    ImportRange(Idx, BatchEnd);
    if Cancelled then Break;

    Idx := BatchEnd;
    WriteCheckpoint(Idx, Format('batch %d', [BatchNo]));

    Done := Idx;
    Progress('Migrating check-ins', Done, Total);
    Overall(Idx, Total);
    Secs := SecondsBetween(Now, StartedAt);
    if (Secs > 5) and (Done > 0) then
      Log(Format('  %d of %d check-ins done (%.0f%%), %.1f/sec',
        [Done, Total, Done / Total * 100, Done / Secs]));
  end;

  // persist the exception reports next to the metadata, MERGED with what previous runs found
  MergeSaveCsv('skipped.csv', 'file_id,tc_path,revision,reason', FSkippedRows);
  MergeSaveCsv('failed.csv', 'file_id,tc_path,revision,reason', FFailedRows);
  if FEmpty > 0 then
    Log(Format('%d revision(s) had no content and were skipped (meta\skipped.csv).', [FEmpty]));
  if FFailedRows.Count > 0 then
  begin
    Log('');
    Log(Format('*** %d revision(s) COULD NOT BE FETCHED - see metaailed.csv ***',
      [FFailedRows.Count]));
    Log('*** The history is complete apart from those. ***');
  end;

  if FHeartbeat <> nil then
  begin
    THeartbeatThread(FHeartbeat).Terminate;
    THeartbeatThread(FHeartbeat).WaitFor;
    FHeartbeat.Free;
    FHeartbeat := nil;
  end;

  if FStoppedIncomplete then
    raise Exception.CreateFmt(
      'Stopped after %d of %d check-ins: fetches failed, most likely a dropped ' +
      'connection.'#13#10#13#10'Nothing was committed for the incomplete batch. ' +
      'Run again when the connection is back and it continues from check-in %d.',
      [Idx, Total, Idx]);
  if Cancelled then
    Log(Format('Stopped after %d of %d check-ins. Re-run to continue from here.', [Idx, Total]))
  else
    Log(Format('All %d check-ins migrated.', [Total]));
end;

procedure TPipeline.ImportRange(StartIdx, EndIdx: Integer);
// Emits one fast-import stream for this batch only and waits for git to finish it, so the
// repository is complete and consistent at every checkpoint.
var
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Marks: TDictionary<string, Integer>;
  Pending: TList<TChange>;
  // Which files are already in the commit being built. A git tree holds ONE version of a
  // path, so a group must never contain two revisions of the same file - see the split rule
  // in the grouping loop below.
  GroupFiles: TDictionary<Cardinal, Boolean>;
  Chg: TChange;
  I, Mark, CommitCount, Rc: Integer;
  GroupAuthor, GroupComment, Msg, Out1: string;
  GroupStart: TDateTime;
  FirstCommit, BranchExists: Boolean;

  procedure Put(const Line: string);
  var
    B: TBytes;
  begin
    B := TEncoding.UTF8.GetBytes(Line + #10);
    FS.WriteBuffer(B[0], Length(B));
  end;

  procedure PutFileBytes(const FileName: string);
  var
    Src: TFileStream;
    LF: Byte;
  begin
    Src := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      FS.CopyFrom(Src, 0);
    finally
      Src.Free;
    end;
    LF := 10;
    FS.WriteBuffer(LF, 1);
  end;

  procedure EmitBlobsFor(const Rev: TTCRevision);
  var
    N: Integer;
    Bl: TBlob;
    CacheFile: string;
  begin
    for N := 0 to FBlobs.Count - 1 do
    begin
      Bl := FBlobs[N];
      if (Bl.FileID <> Rev.FileID) or (Bl.Revision <> Rev.Revision) then Continue;
      if not Marks.ContainsKey(Bl.Sha) then
      begin
        CacheFile := TPath.Combine(FOpt.CacheDir,
          StringReplace(Bl.CachePath, '/', PathDelim, [rfReplaceAll]));
        if not TFile.Exists(CacheFile) then
        begin
          Log('  missing cached blob: ' + Bl.CachePath);
          Continue;
        end;
        Inc(Mark);
        Marks.Add(Bl.Sha, Mark);
        Put('blob');
        Put('mark :' + IntToStr(Mark));
        Put('data ' + IntToStr(TFile.GetSize(CacheFile)));
        PutFileBytes(CacheFile);
      end;
      Chg.Path := MemberPath(Rev.TCPath, Bl.Member);
      Chg.Sha := Bl.Sha;
      Pending.Add(Chg);
    end;
  end;

  procedure FlushCommit;
  var
    N: Integer;
  begin
    if Pending.Count = 0 then Exit;
    Inc(CommitCount);
    Msg := GroupComment;
    if Trim(Msg) = '' then Msg := '(no check-in comment)';
    Put('commit refs/heads/' + FOpt.Branch);
    Put(Format('committer %s %d +0000',
      [MapAuthor(GroupAuthor), DateTimeToUnix(GroupStart, True)]));
    Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
    Put(Msg);
    // Continue the existing history: without this the first commit of a resumed run would
    // start a second root commit and the branch would fork.
    if FirstCommit and BranchExists then
      Put('from refs/heads/' + FOpt.Branch + '^0');
    FirstCommit := False;
    for N := 0 to Pending.Count - 1 do
      if Marks.ContainsKey(Pending[N].Sha) then
        Put(Format('M 100644 :%d %s', [Marks[Pending[N].Sha], Pending[N].Path]));
    Pending.Clear;
  end;

begin
  RunProcess(FOpt.GitExe, 'rev-parse --verify --quiet refs/heads/' + FOpt.Branch,
             FOpt.RepoDir, Out1);
  BranchExists := Trim(Out1) <> '';

  Marks := TDictionary<string, Integer>.Create;
  Pending := TList<TChange>.Create;
  GroupFiles := TDictionary<Cardinal, Boolean>.Create;
  try
    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import.');
    FS := THandleStream.Create(GitIn);
    try
      Mark := 0;
      CommitCount := 0;
      FirstCommit := True;
      GroupAuthor := #0;
      GroupComment := #0;
      GroupStart := 0;

      for I := StartIdx to EndIdx - 1 do
      begin
        if Cancelled then Break;
        // A new commit starts when the author or comment changes, when the optional time
        // window is exceeded, OR when this file is already in the commit being built.
        //
        // That last condition is not optional. A git tree holds one version of a path, so a
        // group containing two revisions of the same file keeps only the LAST and the earlier
        // revision vanishes from history - fetched, written as a blob, then referenced by
        // nothing. The 2026-09-26 run hid 9,327 revisions across 2,349 files exactly this way,
        // and the only trace was the dangling-blob count in `git fsck`. Splitting here costs
        // extra commits and loses nothing.
        if (FSorted[I].Author <> GroupAuthor) or (FSorted[I].Comment <> GroupComment) or
           ((FOpt.WindowSeconds > 0) and
            (SecondsBetween(FSorted[I].When, GroupStart) > FOpt.WindowSeconds)) or
           GroupFiles.ContainsKey(FSorted[I].FileID) then
        begin
          FlushCommit;
          GroupFiles.Clear;
          GroupAuthor := FSorted[I].Author;
          GroupComment := FSorted[I].Comment;
          GroupStart := FSorted[I].When;
        end;
        GroupFiles.AddOrSetValue(FSorted[I].FileID, True);
        EmitBlobsFor(FSorted[I]);
      end;
      FlushCommit;
    finally
      FS.Free;
    end;

    Rc := FinishFastImport(GitProc, GitIn, Out1);
    if Rc <> 0 then
    begin
      Log('git fast-import FAILED:');
      Log(Out1);
      raise Exception.Create('git fast-import failed - see the log.');
    end;
    Item(Format('imported %d commits', [CommitCount]));
  finally
    Marks.Free;
    Pending.Free;
    GroupFiles.Free;
  end;
end;

function TPipeline.SanitiseRefName(const S: string): string;
// Turn a Team Coherence label name into something git will accept as a ref. TC allows spaces
// and punctuation that git forbids ("V 4.2.0 (final)"), and a rejected ref fails the whole
// fast-import stream, not just that label.
var
  Ch: Char;
begin
  Result := '';
  for Ch in S do
    if CharInSet(Ch, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then
      Result := Result + Ch
    else
      Result := Result + '_';
  // git rejects a component that is empty, starts with '.', ends with '.lock', or contains '..'
  while Pos('..', Result) > 0 do
    Result := StringReplace(Result, '..', '.', [rfReplaceAll]);
  while Result.StartsWith('.') do Result := Copy(Result, 2, MaxInt);
  while Result.EndsWith('.') do Result := Copy(Result, 1, Length(Result) - 1);
  if Result.EndsWith('.lock') then Result := Copy(Result, 1, Length(Result) - 5) + '_lock';
  if Result = '' then Result := 'unnamed';
end;

procedure TPipeline.ImportTags;
// Rebuilds each version label as its own ref holding the EXACT tree the label describes.
//
// A TC version label is not a pointer to a check-in - it is a list of (file, revision) pairs,
// which can mix revisions from any point in history and need not correspond to any commit that
// ever existed on the trunk. So a label cannot honestly be a git tag pointing at a commit: it is
// emitted as a root commit with `deleteall` plus exactly the labelled revisions, on
// refs/heads/tc/label/<name>.
//
// This work used to live in BuildAndImport, which nothing calls - so every run that passed
// --tags enumerated 44,450 attachments and then created no refs whatsoever. The lookups here are
// indexed; the original's nested scan was labels x attachments x 44,450 revisions.
const
  // TC label types. uTCApi declares these in its implementation section, so they are not
  // visible here; promotion levels (2) are deliberately not turned into refs.
  lt_VersionLabel = 1;
var
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Marks: TDictionary<string, Integer>;
  RevPath: TDictionary<string, string>;               // 'fileid|revision' -> TC path
  BlobsAt: TObjectDictionary<string, TList<Integer>>; // 'fileid|revision' -> FBlobs indices
  Lst: TList<Integer>;
  I, J, N, Mark, TagCount, Emitted: Integer;
  Key, Ep, Msg, Out1, CacheFile: string;
  // one entry per path in this label's tree, as sha + TAB + path. Not a name=value list: git
  // paths here contain spaces and could contain '=', but never a tab.
  Paths: TStringList;
  Parts: TArray<string>;
  UsedRefs: TDictionary<string, Boolean>;

  procedure Put(const Line: string);
  var
    B: TBytes;
  begin
    B := TEncoding.UTF8.GetBytes(Line + #10);
    FS.WriteBuffer(B[0], Length(B));
  end;

begin
  if FSession.Labels.Count = 0 then
  begin
    Log('No version labels found - nothing to tag.');
    Exit;
  end;
  if FSession.Attachments.Count = 0 then
  begin
    // Finding L11: an empty attachment list is a FAILURE, not a repository without labels.
    Log('');
    Log('*** Labels are present but NO attachments were read. Per finding L11 this means the');
    Log('*** attachment pass did not work (RootID must be a FILE id), not that the labels are');
    Log('*** empty. Refusing to write tags from nothing.');
    Exit;
  end;

  Marks := TDictionary<string, Integer>.Create;
  RevPath := TDictionary<string, string>.Create;
  BlobsAt := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
  Paths := TStringList.Create;
  UsedRefs := TDictionary<string, Boolean>.Create;
  try
    for I := 0 to FSession.Revisions.Count - 1 do
      RevPath.AddOrSetValue(
        Format('%d|%s', [FSession.Revisions[I].FileID, FSession.Revisions[I].Revision]),
        FSession.Revisions[I].TCPath);

    for I := 0 to FBlobs.Count - 1 do
    begin
      Key := Format('%d|%s', [FBlobs[I].FileID, FBlobs[I].Revision]);
      if not BlobsAt.TryGetValue(Key, Lst) then
      begin
        Lst := TList<Integer>.Create;
        BlobsAt.Add(Key, Lst);
      end;
      Lst.Add(I);
    end;

    Log(Format('Rebuilding %d label(s) from %d attachment(s)...',
      [FSession.Labels.Count, FSession.Attachments.Count]));

    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import for the labels.');
    FS := THandleStream.Create(GitIn);
    try
      Mark := 0;
      TagCount := 0;
      for I := 0 to FSession.Labels.Count - 1 do
      begin
        if Cancelled then Break;
        if FSession.Labels[I].LabelType <> lt_VersionLabel then Continue;

        Paths.Clear;
        Emitted := 0;
        for J := 0 to FSession.Attachments.Count - 1 do
        begin
          if FSession.Attachments[J].LabelID <> FSession.Labels[I].ID then Continue;
          Key := Format('%d|%s',
            [FSession.Attachments[J].FileID, FSession.Attachments[J].Revision]);
          if not BlobsAt.TryGetValue(Key, Lst) then Continue;   // no content for it
          if not RevPath.ContainsKey(Key) then Continue;
          for N := 0 to Lst.Count - 1 do
          begin
            if not Marks.ContainsKey(FBlobs[Lst[N]].Sha) then
            begin
              CacheFile := TPath.Combine(FOpt.CacheDir,
                StringReplace(FBlobs[Lst[N]].CachePath, '/', PathDelim, [rfReplaceAll]));
              if not TFile.Exists(CacheFile) then Continue;
              Inc(Mark);
              Marks.Add(FBlobs[Lst[N]].Sha, Mark);
              Put('blob');
              Put('mark :' + IntToStr(Mark));
              Put('data ' + IntToStr(TFile.GetSize(CacheFile)));
              // blob bytes must go out raw - a text writer would corrupt every binary
              var Src := TFileStream.Create(CacheFile, fmOpenRead or fmShareDenyWrite);
              try
                FS.CopyFrom(Src, 0);
              finally
                Src.Free;
              end;
              var LF: Byte := 10;
              FS.WriteBuffer(LF, 1);
            end;
            Paths.Add(FBlobs[Lst[N]].Sha + #9 + MemberPath(RevPath[Key], FBlobs[Lst[N]].Member));
            Inc(Emitted);
          end;
        end;

        if Emitted = 0 then
        begin
          Log(Format('  label "%s": no content available, skipped.', [FSession.Labels[I].Name]));
          Continue;
        end;

        Inc(TagCount);
        // Tags, not branches under the branch. 'refs/heads/tc/main/label/x' cannot exist while
        // 'refs/heads/tc/main' does: git keeps a ref as a FILE, so the same path cannot also be
        // a directory. fast-import wrote all 38 label commits and then failed every ref update,
        // leaving 38 dangling commits and no labels - 21 supervisor retries in a row.
        //
        // refs/tags is also the right place semantically: a label IS a named snapshot, and
        // `git tag` is where anyone looking for "what shipped as v4.2.0" will look first.
        Ep := 'refs/tags/' + SanitiseRefName(FSession.Labels[I].Name);
        // Sanitising can map two different TC names onto one ref ("V 4.2" and "V/4.2"), and the
        // second would silently replace the first.
        if UsedRefs.ContainsKey(LowerCase(Ep)) then
        begin
          J := 2;
          while UsedRefs.ContainsKey(LowerCase(Ep + '_' + IntToStr(J))) do Inc(J);
          Log(Format('  note: "%s" collides with an earlier label; using %s_%d',
            [FSession.Labels[I].Name, Ep, J]));
          Ep := Ep + '_' + IntToStr(J);
        end;
        UsedRefs.AddOrSetValue(LowerCase(Ep), True);
        Msg := FSession.Labels[I].Name;
        if Trim(FSession.Labels[I].Comment) <> '' then
          Msg := Msg + #10#10 + FSession.Labels[I].Comment;
        Put('commit ' + Ep);
        Put(Format('committer %s %d +0000',
          [MapAuthor('tc'), DateTimeToUnix(FSession.Labels[I].When, True)]));
        Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
        Put(Msg);
        Put('deleteall');   // a label defines the whole tree, not a delta
        for J := 0 to Paths.Count - 1 do
        begin
          Parts := Paths[J].Split([#9]);
          if Length(Parts) = 2 then
            Put(Format('M 100644 :%d %s', [Marks[Parts[0]], Parts[1]]));
        end;
        Log(Format('  %s -> %d file(s)', [Ep, Paths.Count]));
        if (I mod 5 = 0) or (I = FSession.Labels.Count - 1) then
          Progress('Rebuilding labels as refs', I + 1, FSession.Labels.Count);
      end;
    finally
      FS.Free;
    end;

    if FinishFastImport(GitProc, GitIn, Out1) <> 0 then
    begin
      Log('git fast-import FAILED on the labels:');
      Log(Out1);
      raise Exception.Create('git fast-import failed while writing labels.');
    end;
    Log(Format('%d label(s) written as tags under refs/tags/. List them with: git tag',
      [TagCount]));
  finally
    Paths.Free;
    UsedRefs.Free;
    BlobsAt.Free;
    RevPath.Free;
    Marks.Free;
  end;
end;

procedure TPipeline.RemoveDeletedFiles;
// Team Coherence records no deletion event we can date: a deleted file simply stops being
// listed in its folder, and its revisions remain in the metadata. Emitting only M lines
// therefore leaves every file ever created sitting in the tree for ever, so the tip contains
// files that were removed years ago - and a file deleted and later recreated looks like it
// never went away.
//
// What CAN be established is which files no longer exist NOW. Each folder is listed and any
// file missing from it is deleted in one final commit. The deletion dates are unknown, so this
// is honest about being a tip correction rather than pretending to be history.
var
  Present: TDictionary<string, Boolean>;
  Folders: TList<string>;
  I, J, Removed: Integer;
  Output, FolderPath, Line, Name: string;
  Lines: TArray<string>;
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Gone: TStringList;

  procedure Put(const S: string);
  var
    B: TBytes;
  begin
    B := TEncoding.UTF8.GetBytes(S + #10);
    FS.WriteBuffer(B[0], Length(B));
  end;

begin
  Present := TDictionary<string, Boolean>.Create;
  Folders := TList<string>.Create;
  Gone := TStringList.Create;
  try
    // every distinct folder that holds a migrated file
    for I := 0 to FSession.Files.Count - 1 do
    begin
      FolderPath := FSession.Files[I].TCPath;
      J := LastDelimiter('/', FolderPath);
      if J > 0 then FolderPath := Copy(FolderPath, 1, J - 1);
      if Folders.IndexOf(FolderPath) < 0 then Folders.Add(FolderPath);
    end;
    Log(Format('Checking %d folders for files that no longer exist...', [Folders.Count]));

    for I := 0 to Folders.Count - 1 do
    begin
      if Cancelled then Exit;
      WaitIfPaused;
      RunProcess(FOpt.TcExe, Format('Dir "%s"', [Folders[I]]), FOpt.WorkDir, Output);
      Lines := Output.Split([#13, #10]);
      for Line in Lines do
      begin
        Name := Trim(Line);
        // folder entries are indented and have no extension; skip headers and counts
        if (Name = '') or Name.StartsWith('//') or Name.EndsWith(':') or
           (Pos('item(s)', Name) > 0) or (Pos('Team Coherence', Name) > 0) or
           (Pos('Copyright', Name) > 0) or (Pos('.exe"', Name) > 0) then Continue;
        Present.AddOrSetValue(LowerCase(Folders[I] + '/' + Name), True);
      end;
      if (I mod 25 = 0) or (I = Folders.Count - 1) then
        Progress('Looking for deleted files', I + 1, Folders.Count);
    end;

    for I := 0 to FSession.Files.Count - 1 do
      if not Present.ContainsKey(LowerCase(FSession.Files[I].TCPath)) then
        Gone.Add(FSession.Files[I].TCPath);

    if Gone.Count = 0 then
    begin
      Log('No deleted files found - the tip matches Team Coherence.');
      Exit;
    end;

    Log(Format('%d file(s) no longer exist in Team Coherence; removing them at the tip.',
      [Gone.Count]));
    Gone.SaveToFile(TPath.Combine(FOpt.MetaDir, 'deleted.csv'));

    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import for the deletion commit.');
    FS := THandleStream.Create(GitIn);
    try
      Put('commit refs/heads/' + FOpt.Branch);
      Put(Format('committer %s %d +0000',
        [MapAuthor('tc'), DateTimeToUnix(Now, False)]));
      Line := Format('Remove %d files deleted in Team Coherence' + #10 + #10 +
        'These files no longer exist in the Team Coherence repository. TC records no ' +
        'deletion event that can be dated, so they are removed here in a single commit ' +
        'rather than at the point each was actually deleted. See meta/deleted.csv.',
        [Gone.Count]);
      Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Line))));
      Put(Line);
      Put('from refs/heads/' + FOpt.Branch + '^0');
      Removed := 0;
      for I := 0 to Gone.Count - 1 do
      begin
        // delete every member path of the archive's file group
        for J := 0 to FBlobs.Count - 1 do
          if FBlobs[J].FileID = FileIdOf(Gone[I]) then
          begin
            Put('D ' + MemberPath(Gone[I], FBlobs[J].Member));
            Inc(Removed);
          end;
        Put('D ' + GitPathOf(Gone[I]));
      end;
    finally
      FS.Free;
    end;
    if FinishFastImport(GitProc, GitIn, Output) <> 0 then
    begin
      Log('deletion commit failed: ' + Output);
      raise Exception.Create('git fast-import failed on the deletion commit.');
    end;
    Log(Format('Removed %d path(s) at the tip.', [Removed + Gone.Count]));
  finally
    Present.Free;
    Folders.Free;
    Gone.Free;
  end;
end;

function TPipeline.FileIdOf(const TCPath: string): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FSession.Files.Count - 1 do
    if FSession.Files[I].TCPath = TCPath then Exit(FSession.Files[I].ID);
end;

// ---------------------------------------------------------------- verify

procedure TPipeline.Verify;
var
  Out1: string;
  Commits, Refs: string;
begin
  RunProcess(FOpt.GitExe, 'rev-list --all --count', FOpt.RepoDir, Commits);
  RunProcess(FOpt.GitExe, 'for-each-ref --format=%(refname)', FOpt.RepoDir, Refs);
  Log('--- verification ---');
  Log('commits in repository : ' + Trim(Commits));
  Log('refs                  : ' + IntToStr(Length(Trim(Refs).Split([#10]))));
  Log(Format('revisions from TC     : %d', [FSession.Revisions.Count]));
  Log(Format('blobs fetched         : %d', [FBlobs.Count]));
  Log(Format('labels                : %d', [FSession.Labels.Count]));
  Log(Format('label attachments     : %d', [FSession.Attachments.Count]));
  RunProcess(FOpt.GitExe, 'fsck --no-progress', FOpt.RepoDir, Out1);
  if Trim(Out1) = '' then Log('git fsck              : clean')
  else Log('git fsck              : ' + Trim(Out1));
  VerifySizes;
end;

procedure TPipeline.VerifySizes;
// Checks that the content actually fetched for each revision is the content Team Coherence says
// that revision holds, by comparing the sum of the archive's member sizes against the size TC
// reported when the revision was enumerated. Those two numbers come from different calls, which
// is the entire point.
//
// This is the only check here that can catch a revision whose content arrived but is WRONG.
// Everything else in Verify answers a weaker question: reconciling revisions against blobs
// proves content is PRESENT, and git fsck proves nothing is UNREACHABLE. A migration once
// passed both while holding 83 revisions of wrong bytes - contaminating 4,166 commits, 16% of
// the history - and it took a comparison against a second, independent migration to notice.
// Fetching the wrong revision's bytes is exactly the failure this tool exists to prevent, so
// it is checked directly.
var
  Sums: TDictionary<string, Int64>;
  I, Bad, Checked: Integer;
  Key: string;
  Got: Int64;
  Rows: TStringList;

  // These paths contain commas as well as spaces, so the path field must be quoted or the
  // resulting CSV cannot be parsed by column.
  function Q(const V: string): string;
  begin
    if (Pos(',', V) > 0) or (Pos('"', V) > 0) then
      Result := '"' + StringReplace(V, '"', '""', [rfReplaceAll]) + '"'
    else
      Result := V;
  end;

begin
  Sums := TDictionary<string, Int64>.Create;
  Rows := TStringList.Create;
  try
    for I := 0 to FBlobs.Count - 1 do
    begin
      Key := Format('%d|%s', [FBlobs[I].FileID, FBlobs[I].Revision]);
      if Sums.TryGetValue(Key, Got) then
        Sums[Key] := Got + FBlobs[I].Size
      else
        Sums.Add(Key, FBlobs[I].Size);
    end;

    Bad := 0;
    Checked := 0;
    for I := 0 to FSession.Revisions.Count - 1 do
    begin
      // Size <= 0 means TC recorded no size, so there is nothing to compare against.
      if FSession.Revisions[I].Size <= 0 then Continue;
      Key := Format('%d|%s', [FSession.Revisions[I].FileID, FSession.Revisions[I].Revision]);
      if not Sums.TryGetValue(Key, Got) then Continue;   // no content: skipped.csv / failed.csv
      Inc(Checked);
      if Got <> FSession.Revisions[I].Size then
      begin
        Inc(Bad);
        Rows.Add(Format('%d,%s,%s,%d,%d',
          [FSession.Revisions[I].FileID, Q(FSession.Revisions[I].TCPath),
           FSession.Revisions[I].Revision, FSession.Revisions[I].Size, Got]));
      end;
    end;

    if Bad = 0 then
      Log(Format('content sizes         : all %d revisions match TC''s recorded size', [Checked]))
    else
    begin
      Log('');
      Log(Format('*** %d of %d revisions: the content fetched does not add up to the size Team',
        [Bad, Checked]));
      Log('*** Coherence recorded for that revision. Listed in meta\size_mismatch.csv.');
      Log('***');
      Log('*** A MATCH is strong evidence the right bytes arrived. A mismatch only says the two');
      Log('*** disagree - it does not say which is wrong. Investigate before acting:');
      Log('***   - a large shortfall, or a run of revisions where a second migration matched');
      Log('***     and this one did not, means the WRONG CONTENT was fetched. That also');
      Log('***     corrupts every later commit until some revision replaces it.');
      Log('***   - a small constant gap across a contiguous run of revisions of one file is');
      Log('***     TC''s recorded size being wrong; re-fetching returns identical bytes.');
      Log('*** Re-fetch the listed revisions and compare: identical bytes twice means the');
      Log('*** recorded size is what is wrong, and there is nothing here to repair.');
      Rows.Insert(0, 'file_id,tc_path,revision,tc_size,fetched_size');
      Rows.SaveToFile(TPath.Combine(FOpt.MetaDir, 'size_mismatch.csv'), TEncoding.UTF8);
    end;
  finally
    Rows.Free;
    Sums.Free;
  end;
end;

end.
