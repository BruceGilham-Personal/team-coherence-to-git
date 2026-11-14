unit uPipeline;
{
  Everything after metadata extraction:

    1. Fetch   - every revision's content, into a content-addressed blob cache: through the
                 TC DLL (TCDVcsCheckOutFile with Lock = False) by default, or tc.exe Get -VR<rev>
                 with --no-dll
    2. Build   - turn metadata + blobs into a git fast-import stream, one batch at a time
    3. Import  - git fast-import into a bare repository
    4. Verify  - compare what landed in git against what came out of Team Coherence

  Only two external programs are used, both vendor binaries rather than editable scripts:
  tc.exe (Team Coherence) and git.exe.

  READ-ONLY against Team Coherence: the only content verb ever issued is a Get.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  System.RegularExpressions, Winapi.Windows, uTCApi;

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
    // Bring an already-migrated repository up to date instead of migrating from scratch:
    // re-read Team Coherence and add only what is not yet in git (see BeginUpdate).
    UpdateMode: Boolean;
    Remote: string;       // git remote the repository mirrors to, e.g. 'origin'
    Push: Boolean;        // push the branch and tags to Remote after a successful run
    // The migration's checkpoint file; '' = state.txt in WorkDir. A first update reads it to
    // learn what the migration put in git.
    StateFile: string;
    // A content filter every blob passes through before it is written to git, for a history
    // whose published copy was redacted: '' = none. A script or program, run with one
    // argument - a list file of "<input>TAB<output>" lines - that writes each output. A .pl
    // script is run with Git for Windows' perl. See tools\filters.
    Filter: string;
    // Paths never written to git, as ';'-separated masks matched against the file name, e.g.
    // '*.pfx' for a history that had its certificates removed.
    Exclude: string;
    // The URL for Remote. When the repository has no such remote it is added; when it has one
    // with a different URL the run refuses rather than repoint it. '' = use what is configured.
    RemoteUrl: string;
    // Keep a release/<label> branch for every version label, chained oldest to newest so a fix
    // merged forward carries only itself. See UpdateReleaseBranches.
    ReleaseBranches: Boolean;
    // ';'-separated masks of labels that get no release branch, e.g. the label on the version
    // still being built, which is the branch itself.
    ReleaseSkip: string;
    // The version label whose view the branch follows, e.g. 'V7.0.0'; '' = every revision, in
    // check-in order. Revisions checked in under views based on other labels - fixes to older
    // releases - then stay off the branch. See OnMainLine.
    MainLine: string;
    // Rebuild every release branch tc2git owns from Team Coherence's history, replacing what is
    // there. Pushed with force. See UpdateReleaseBranches.
    RebuildReleaseBranches: Boolean;
    // For testing: an update from the metadata the last run saved, without connecting to Team
    // Coherence. Nothing new is read, deleted files are not looked for, and it never pushes.
    Offline: Boolean;
  end;

  // A state that needs a person to look at it, not a retry: the supervisor stops on it.
  EUpdateRefused = class(Exception);

  // Update mode's record of one path in the branch tip: which archive wrote it, and with what.
  TTreeEntry = record
    FileID: Cardinal;
    Member: string;
    Sha: string;           // sha256, as in blobs.csv
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
    FDone, FFailed, FConsecFail: Integer;
    FConnLost: Boolean;
    FStoppedIncomplete: Boolean;
    FEmpty: Integer;
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
    // ---- update mode ------------------------------------------------------------------
    FLedger: TDictionary<string, Boolean>;     // 'fileid|revision' already handled
    FLedgerNew: TStringList;                   // handled since the last update checkpoint
    FLedgerRows: Integer;                      // rows of imported.csv the checkpoint vouches for
    FTree: TDictionary<string, TTreeEntry>;    // the branch tip's tree, path -> provenance
    FOldFiles: TArray<TTCFile>;                // metadata as the previous run saved it
    FOldRevs: TArray<TTCRevision>;
    FOldAttach: TArray<TTCAttachment>;
    FOldLabels: TArray<TTCLabel>;
    // ---- what is written for a blob: filtered, excluded, or an LFS pointer ---------------
    FFiltered: TDictionary<string, string>;    // sha256 -> the filtered copy of that blob
    FExcludes: TArray<string>;
    FLfsPatterns: TArray<TRegEx>;              // from .gitattributes: paths stored in LFS
    FAttrBlob: string;                         // git id of the tip's .gitattributes, if any
    // ---- labels attached to the branch, release branches -------------------------------
    FBranchShas: TArray<string>;               // the branch's first-parent line, newest first
    FBranchTimes: TArray<Int64>;               // ... and each commit's author time (Unix)
    FReleasePush: TStringList;                 // release branches safe to push this run
    // ---- the line the branch follows: --main-line -------------------------------------------
    FMainLineOn: Boolean;
    FMainAt: TDictionary<Cardinal, string>;    // file id -> its revision in the main-line label
    FOtherAt: TDictionary<Cardinal, string>;   // file id -> other version labels' revisions, ';'
    procedure EnsureMainLine;
    function OnMainLine(const R: TTCRevision): Boolean;
    function InMain(const R: TTCRevision): Boolean;
    function ForkPoint(const AtLabel: TDictionary<Cardinal, string>; out Cut: Int64): string;
    function ReplayRevisions(const Base: string; Revs: TArray<TTCRevision>;
      out Commits: Integer): string;
    function Excluded(const Path: string): Boolean;
    function TreeOf(const Rev: string): string;
    function AttachPoint(NewestUtc: TDateTime): string;
    function LabelParent(const TagRef: string; NewestUtc: TDateTime): string;
    function CommitTree(const Tree: string; const Parents: array of string;
      const Msg, Name, Email, RawDate: string): string;
    procedure ReattachTag(const TagRef: string; NewestUtc: TDateTime);
    procedure EnsureRemote;
    procedure PushBranchInSteps(const Branch: string);
    procedure PushLfsObjects;
    function IsLfsPath(const Path: string): Boolean;
    procedure LoadLfsPatterns(const Commit: string);
    procedure PrepareFiltered(const Shas: TArray<string>);
    function ContentFile(const Sha: string): string;
    function LfsPointer(const Sha: string; Store: Boolean): string;
    function GitFileIds(const Files: TArray<string>): TDictionary<string, string>;
    function GitOut(const Args: string; out Output: string; TimeoutSec: Integer = 300): Integer;
    function RefSha(const Ref: string): string;
    function IsAncestor(const A, B: string): Boolean;
    function RemoteExists: Boolean;
    function TipPaths(const Rev: string = ''): TDictionary<string, string>;
    function UpdateStatePath: string;
    procedure SortChronologically(var Revs: TArray<TTCRevision>);
    function SameCheckIn(const A, B: TTCRevision): Boolean;
    procedure BuildFirstLedger(out Tip: string);
    procedure LoadUpdateState(out Tip: string);
    procedure SaveUpdateCheckpoint;
    procedure VerifyTree(const Tip: string; Prune: Boolean);
    function StatePath: string;
    function TestConnection: Boolean;
    function ReadCheckpoint: Integer;
    procedure WriteCheckpoint(Index: Integer; const Extra: string);
    procedure LoadBlobManifest;
    procedure RewindToCheckpointTip;
    procedure DiscardUncheckpointedBranch;
    function BlobIndex: TObjectDictionary<string, TList<Integer>>;
    function EmitBlob(FS: TStream; const B: TBlob; const Path: string;
      Marks: TDictionary<string, Integer>; var Mark: Integer; out BlobMark: Integer): Boolean;
    procedure FetchRange(StartIdx, EndIdx: Integer);
    function ClaimNext: Integer;
    function PendingCount: Integer;
    procedure ReleaseFile(FileID: Cardinal);
    procedure AppendManifest(const Rows: TArray<string>);
    procedure AppendRows(const Name, Header: string; const Rows: TArray<string>);
    procedure AppendSkipped(const Rows: TArray<string>);
    procedure MergeSaveCsv(const Name, Header: string; Rows: TStrings);
    procedure ImportRange(StartIdx, EndIdx: Integer);
    function StartFastImport(out ProcInfo: TProcessInformation; out StdInWrite: THandle;
      Force: Boolean = False): Boolean;
    function FinishFastImport(var ProcInfo: TProcessInformation; var StdInWrite: THandle;
      out Output: string): Integer;
    procedure FetchOne(Index: Integer);
    procedure Item(const Detail: string);
    procedure Overall(Done, Total: Integer);
    procedure Progress(const Phase: string; Done, Total: Integer);
    function Cancelled: Boolean;
    function RunProcess(const Exe, Params, WorkDir: string; out Output: string;
      const StdInFile: string = ''; Utf8: Boolean = False; TimeoutSec: Integer = 300): Integer;
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
    function CheckRevisionSelection(out Probe: string): Boolean;
    function GetCurrentView: string;
    function SetView(const ViewName: string): Boolean;
  public
    procedure RunIncremental;
    procedure RemoveDeletedFiles;
    procedure Verify;
    procedure VerifySizes;
    // update mode, in the order the worker calls them
    procedure BeginUpdate;
    procedure PrepareLabelCarryOver;
    procedure FollowMovedFiles;
    procedure FollowMainLine;
    procedure RunUpdate;
    procedure UpdateReleaseBranches;
    procedure PushToRemote;
    property Blobs: TList<TBlob> read FBlobs;
  end;

var
  // Where the release-branch work was when it failed: an error from a generic list names the
  // list and the index, never the caller, and Win32 Delphi has no stack trace to say more.
  GStage: string;

implementation

uses
  System.Hash, System.IOUtils, System.DateUtils, System.StrUtils, System.Math,
  System.Generics.Defaults, System.Masks;

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
  FInFlight := TDictionary<Cardinal, Boolean>.Create;
  FPending := TList<Integer>.Create;
  FFailedRows := TStringList.Create;
  FLedger := TDictionary<string, Boolean>.Create;
  FLedgerNew := TStringList.Create;
  FTree := TDictionary<string, TTreeEntry>.Create;
  FFiltered := TDictionary<string, string>.Create;
  FExcludes := FOpt.Exclude.Split([';'], TStringSplitOptions.ExcludeEmpty);
  FReleasePush := TStringList.Create;
  FMainAt := TDictionary<Cardinal, string>.Create;
  FOtherAt := TDictionary<Cardinal, string>.Create;
end;

destructor TPipeline.Destroy;
begin
  FOtherAt.Free;
  FMainAt.Free;
  FReleasePush.Free;
  FFiltered.Free;
  FLedger.Free;
  FLedgerNew.Free;
  FTree.Free;
  FBlobs.Free;
  FAuthors.Free;
  FLock.Free;
  FManifest.Free;
  FHaveBlob.Free;
  FSkippedRows.Free;
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
  const StdInFile: string; Utf8: Boolean; TimeoutSec: Integer): Integer;
// Utf8: decode the output as UTF-8 (git) rather than the ANSI code page (tc.exe).
// TimeoutSec: how long the child may run. Above the default this is a push or a fetch, which
// can legitimately take an hour, so progress is reported every 30 s to keep the stall
// watchdog from mistaking it for a hang.
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  ReadPipe, WritePipe, StdIn: THandle;
  Buf: array[0..4095] of AnsiChar;
  Read, Avail: DWORD;
  Cmd, Cwd: string;
  Res, Chunk: RawByteString;
  WaitRes: DWORD;
  Deadline, Started, NextBeat: UInt64;
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
      // The default 5 minutes is far above the ~11s worst case seen for a single Get.
      Started := GetTickCount64;
      Deadline := Started + UInt64(TimeoutSec) * 1000;
      NextBeat := Started + 30000;
      repeat
        WaitRes := WaitForSingleObject(PI.hProcess, 50);
        // drain the pipe so a chatty child cannot deadlock on a full buffer. Appended by
        // length, not as a C string: `git ls-tree -z` output is full of NULs.
        while PeekNamedPipe(ReadPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
        begin
          if not ReadFile(ReadPipe, Buf, SizeOf(Buf), Read, nil) or (Read = 0) then Break;
          SetString(Chunk, PAnsiChar(@Buf[0]), Read);
          Res := Res + Chunk;
        end;
        if (TimeoutSec > 300) and (GetTickCount64 >= NextBeat) then
        begin
          Item(Format('%s still running (%d s)',
            [ExtractFileName(Exe), (GetTickCount64 - Started) div 1000]));
          Inc(NextBeat, 30000);
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
          Res := Res + RawByteString(Format(' [timed out after %d seconds]', [TimeoutSec]));
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
  if Utf8 then
    Output := UTF8ToString(Res)
  else
  begin
    SetCodePage(Res, CP_ACP, False);
    Output := string(Res);
  end;
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

function TPipeline.CheckRevisionSelection(out Probe: string): Boolean;
// The active View decides what -VR means. Under some views every -VR quietly returns the TIP,
// which would fill the repository with tip content for every revision. Prove that an
// impossible revision FAILS before trusting any of it.
//
// The probe goes through the SAME path the fetch will use. It used to ask tc.exe even when the
// DLL was doing the fetching, so the path that actually ran was never tested. And an
// impossible revision failing proves nothing unless a real one of the same file succeeds:
// tc.exe misreads a path with a space and fails for that reason alone, so probe files are
// chosen without one, and a file whose real revision does not come back is passed over.
const
  MaxCandidates = 5;
var
  DirA, DirB, Out1: string;
  RcA, RcB, GotA, GotB, I, Tried: Integer;
  R: TTCRevision;
  Seen: TDictionary<Cardinal, Boolean>;

  function Fetch(const Rev, Dir: string): Integer;
  begin
    if FOpt.UseDll then
      Result := FSession.GetRevisionContent(R.FileID, Rev, Dir)
    else
      Result := RunProcess(FOpt.TcExe, Format('Get "%s" -VR%s "-GL%s" -W -T',
                           [R.TCPath, Rev, Dir]), FOpt.WorkDir, Out1);
  end;

  function Fresh(const Name: string): string;
  begin
    Result := TPath.Combine(FOpt.WorkDir, Name);
    if TDirectory.Exists(Result) then TDirectory.Delete(Result, True);
    TDirectory.CreateDirectory(Result);
  end;

begin
  Probe := '';
  Tried := 0;
  Seen := TDictionary<Cardinal, Boolean>.Create;
  try
    for I := FSession.Revisions.Count - 1 downto 0 do
    begin
      R := FSession.Revisions[I];
      if (R.Size <= 0) or (Pos(' ', R.TCPath) > 0) or Seen.ContainsKey(R.FileID) then Continue;
      Seen.Add(R.FileID, True);
      Inc(Tried);
      Probe := Format('%s @ %s', [R.TCPath, R.Revision]);
      DirA := Fresh('probe-a');
      DirB := Fresh('probe-b');
      try
        RcA := Fetch(R.Revision, DirA);
        GotA := Length(TDirectory.GetFiles(DirA, '*', TSearchOption.soAllDirectories));
        if (RcA = 0) and (GotA > 0) then
        begin
          RcB := Fetch('99.99', DirB);
          GotB := Length(TDirectory.GetFiles(DirB, '*', TSearchOption.soAllDirectories));
          Exit(not ((RcB = 0) and (GotB > 0)));
        end;
        Log(Format('  probe: %s did not come back (code %d) - trying another file',
          [Probe, RcA]));
      finally
        TDirectory.Delete(DirA, True);
        TDirectory.Delete(DirB, True);
      end;
      if Tried >= MaxCandidates then Break;
    end;
  finally
    Seen.Free;
  end;
  raise Exception.CreateFmt(
    'The revision-selection probe could not fetch a known revision of any of %d file(s), so ' +
    'it proves nothing. Check the connection and run again.', [Tried]);
end;

// ---------------------------------------------------------------- fetch (parallel)

type
  // Each worker pulls the next revision index and fetches it. With --no-dll that is its own
  // tc.exe process, so several can run at once. Through the DLL there is exactly one worker
  // (FetchRange), and the session serialises its calls as well.
  TFetchWorker = class(TThread)
  private
    FPipe: TPipeline;
  protected
    procedure Execute; override;
  public
    constructor Create(APipe: TPipeline);
  end;

constructor TFetchWorker.Create(APipe: TPipeline);
begin
  FPipe := APipe;
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
  Rc, J, Attempt: Integer;
  Ok, NoStoredFile, SuspectLink: Boolean;
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
  // DELIBERATELY NOT SKIPPING WHOLE FILES.
  // Writing off a file after N failures was tried twice and lost real history both times:
  // first 13 files / 5,882 revisions at 10 workers, then 3 more at 6 workers - including
  // files proven fetchable by hand seconds later. Empty results under load are
  // indistinguishable from a dead archive, so every revision gets its own retries and its own
  // entry in failed.csv. The cost is wasted retries on genuinely dead archives; the
  // alternative is silently missing history, which is far worse.
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
          [R.FileID, CsvQ(R.TCPath), CsvQ(R.Revision)]));
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
        FFailedRows.Add(Format('%d,%s,%s,"expected %d bytes, nothing returned"',
          [R.FileID, CsvQ(R.TCPath), CsvQ(R.Revision), R.Size]));
        SuspectLink := (FConsecFail >= 5) and not FConnLost;
      finally
        FLock.Leave;
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
          [R.FileID, CsvQ(R.TCPath), CsvQ(R.Revision)]));
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
        // Content-addressed: identical content is stored once, whoever gets there first.
        // Written under a temporary name and renamed into place, so a process killed
        // mid-copy cannot leave a truncated file under the right hash for every later run to
        // trust. A cached file of the wrong size - left by a version without that rename -
        // is replaced rather than reused.
        if not TFile.Exists(Dest) or (TFile.GetSize(Dest) <> B.Size) then
        begin
          TDirectory.CreateDirectory(TPath.Combine(FOpt.CacheDir, RelDir));
          TFile.Copy(Names[J], Dest + '.partial', True);
          if not MoveFileEx(PChar(Dest + '.partial'), PChar(Dest),
                            MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
            RaiseLastOSError;
        end;
        FBlobs.Add(B);
        FHaveBlob.AddOrSetValue(Format('%d|%s', [B.FileID, B.Revision]), True);
        // Member names can contain commas, so every text field is quoted: unquoted, a resumed
        // run read the wrong columns, lost the cache path and dropped that file's content.
        FManifest.Add(Format('%d,%s,%s,%s,%d,%s',
          [B.FileID, CsvQ(B.Revision), CsvQ(B.Member), B.Sha, B.Size, B.CachePath]));
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

function TPipeline.StartFastImport(out ProcInfo: TProcessInformation;
  out StdInWrite: THandle; Force: Boolean): Boolean;
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

  // --force lets a ref move to a commit that does not descend from it: a label re-applied in
  // TC rebuilds its tag as a new root commit, which fast-import otherwise refuses.
  Cmd := Format('"%s" fast-import --quiet --max-pack-size=1g%s',
    [FOpt.GitExe, IfThen(Force, ' --force', '')]);
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
    Mark: Integer;
  end;

// fast-import is a byte stream, not a text file: a blob is 'data <count>' followed by exactly
// that many raw bytes. Anything that re-encodes would corrupt every binary file (and every
// DFM), so commands are written as UTF-8 bytes and blob content is copied raw.
procedure PutLine(FS: TStream; const Line: string);
var
  B: TBytes;
begin
  B := TEncoding.UTF8.GetBytes(Line + #10);
  FS.WriteBuffer(B[0], Length(B));
end;

// The time part of a fast-import committer line for a UTC instant: Unix seconds, then the TC
// zone's offset at that moment, so git shows each date as the TC server's clock did.
function GitStamp(const Utc: TDateTime): string;
begin
  Result := Format('%d %s', [DateTimeToUnix(Utc, True), TCUtcOffset(Utc)]);
end;

function NowUtc: TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(Now);
end;

// ---- what a blob becomes in git ------------------------------------------------------------
//
// Normally a blob is written exactly as Team Coherence holds it. A history that was cleaned up
// after the migration - secrets redacted, certificates removed, large files moved to LFS - has
// to be continued the same way, or the next update writes back what was taken out. So every
// blob passes through here: excluded paths are not written at all, content goes through the
// --filter, and a path .gitattributes stores in LFS gets a pointer instead of its bytes.

function TPipeline.Excluded(const Path: string): Boolean;
var
  Mask, Name: string;
begin
  Name := Path.Substring(Path.LastIndexOf('/') + 1);
  for Mask in FExcludes do
    if MatchesMask(Name, Mask) or MatchesMask(Path, Mask) then Exit(True);
  Result := False;
end;

function TPipeline.IsLfsPath(const Path: string): Boolean;
var
  Re: TRegEx;
begin
  for Re in FLfsPatterns do
    if Re.IsMatch(Path) then Exit(True);
  Result := False;
end;

function GitAttrPatternToRegex(Pat: string): string;
// A .gitattributes pattern as a regex over the repository path. A pattern with a slash is
// anchored to the root; one without matches a file name at any depth. Bracket expressions,
// [[:space:]] included, are passed through: PCRE reads them the same way.
var
  I, J: Integer;
  Anchored: Boolean;
  R: string;
begin
  Anchored := Pat.Contains('/');
  if Pat.StartsWith('/') then Delete(Pat, 1, 1);
  R := '';
  I := 1;
  while I <= Length(Pat) do
  begin
    if Pat[I] = '[' then
    begin
      J := I + 1;
      if (J <= Length(Pat)) and (Pat[J] = ']') then Inc(J);
      while (J <= Length(Pat)) and (Pat[J] <> ']') do
      begin
        if (Pat[J] = '[') and (J < Length(Pat)) and (Pat[J + 1] = ':') then
          J := Pos(':]', Pat, J) + 1;   // a POSIX class such as [:space:]
        Inc(J);
      end;
      R := R + Copy(Pat, I, J - I + 1);
      I := J + 1;
    end
    else if Copy(Pat, I, 3) = '**/' then
    begin
      R := R + '(?:.*/)?';
      Inc(I, 3);
    end
    else if Copy(Pat, I, 2) = '**' then
    begin
      R := R + '.*';
      Inc(I, 2);
    end
    else
    begin
      case Pat[I] of
        '*': R := R + '[^/]*';
        '?': R := R + '[^/]';
      else
        R := R + TRegEx.Escape(Pat[I]);
      end;
      Inc(I);
    end;
  end;
  if Anchored then Result := '^' + R + '$' else Result := '(?:^|/)' + R + '$';
end;

procedure TPipeline.LoadLfsPatterns(const Commit: string);
// Which paths the published history keeps in LFS, from .gitattributes at Commit.
var
  Out1, Line: string;
  Parts: TArray<string>;
  Pats: TList<TRegEx>;
begin
  FLfsPatterns := nil;
  FAttrBlob := '';
  if GitOut('rev-parse --verify --quiet ' + Commit + ':.gitattributes', Out1) <> 0 then Exit;
  FAttrBlob := Trim(Out1);
  if GitOut('cat-file blob ' + FAttrBlob, Out1) <> 0 then
    raise Exception.Create('Could not read .gitattributes: ' + Trim(Out1));
  Pats := TList<TRegEx>.Create;
  try
    for Line in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
    begin
      if Line.Trim.StartsWith('#') then Continue;
      Parts := Line.Trim.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      if (Length(Parts) >= 2) and string.Join(' ', Parts, 1, Length(Parts) - 1).Contains('filter=lfs') then
        Pats.Add(TRegEx.Create(GitAttrPatternToRegex(Parts[0])));
    end;
    FLfsPatterns := Pats.ToArray;
  finally
    Pats.Free;
  end;
  if Length(FLfsPatterns) > 0 then
    Log(Format('  .gitattributes keeps %d pattern(s) in LFS; matching files are written as ' +
      'LFS pointers.', [Length(FLfsPatterns)]));
end;

function FilterCommand(const Filter: string; out Params: string): string;
// The program that runs a filter, and its leading parameters. A .pl script is run by Perl -
// from PATH, or else the one Git for Windows ships beside git.exe, which is where a Windows
// process will find one.
var
  GitExe: string;
begin
  Params := '';
  if not SameText(ExtractFileExt(Filter), '.pl') then Exit(Filter);
  Params := '"' + Filter + '"';
  Result := FileSearch('perl.exe', GetEnvironmentVariable('PATH'));
  if Result <> '' then Exit;
  GitExe := FileSearch('git.exe', GetEnvironmentVariable('PATH'));
  if GitExe <> '' then
  begin
    Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(GitExe), '..\usr\bin\perl.exe'));
    if TFile.Exists(Result) then Exit;
  end;
  raise EUpdateRefused.Create('The filter is a Perl script but no perl.exe was found, on ' +
    'PATH or in Git for Windows.');
end;

procedure TPipeline.PrepareFiltered(const Shas: TArray<string>);
// Runs the filter once over every blob in Shas not filtered yet in this run, writing the
// results to WorkDir\filtered. Batched because a process per blob would cost minutes.
var
  Dir, ListFile, Out1, Exe, Params, Sha, Raw, Dest: string;
  L: TStringList;
  Pending: TList<string>;
  Rc: Integer;
begin
  if FOpt.Filter = '' then Exit;
  if not TFile.Exists(FOpt.Filter) then
    raise EUpdateRefused.CreateFmt('The filter %s does not exist.', [FOpt.Filter]);
  Dir := TPath.Combine(FOpt.WorkDir, 'filtered');
  // Never trust an earlier run's output: the rules may have changed since.
  if (FFiltered.Count = 0) and TDirectory.Exists(Dir) then TDirectory.Delete(Dir, True);
  TDirectory.CreateDirectory(Dir);
  L := TStringList.Create;
  Pending := TList<string>.Create;
  try
    for Sha in Shas do
    begin
      if FFiltered.ContainsKey(Sha) or Pending.Contains(Sha) then Continue;
      Raw := TPath.Combine(TPath.Combine(FOpt.CacheDir, Copy(Sha, 1, 2)), Sha);
      if not TFile.Exists(Raw) then Continue;   // reported where it is used
      Pending.Add(Sha);
      L.Add(Raw + #9 + TPath.Combine(Dir, Sha));
    end;
    if Pending.Count = 0 then Exit;
    ListFile := TPath.Combine(Dir, 'list.txt');
    L.WriteBOM := False;
    L.SaveToFile(ListFile, TEncoding.UTF8);
    Exe := FilterCommand(FOpt.Filter, Params);
    Item(Format('filtering %d file(s)', [Pending.Count]));
    Rc := RunProcess(Exe, Trim(Params + ' "' + ListFile + '"'), FOpt.WorkDir, Out1, '', False,
                     7200);
    if Rc <> 0 then
      raise Exception.CreateFmt('The content filter failed (exit %d): %s',
        [Rc, Copy(Trim(Out1), 1, 400)]);
    for Sha in Pending do
    begin
      Dest := TPath.Combine(Dir, Sha);
      if not TFile.Exists(Dest) then
        raise Exception.CreateFmt('The content filter wrote no output for %s.', [Sha]);
      FFiltered.Add(Sha, Dest);
    end;
    // The filter's own summary - counts only; a filter must never print what it removed.
    if Trim(Out1) <> '' then Log('  filter: ' + Trim(Out1).Replace(#13#10, ' / '));
  finally
    Pending.Free;
    L.Free;
  end;
end;

function TPipeline.ContentFile(const Sha: string): string;
// The file whose bytes go into git for this blob: the filtered copy, or the cached original.
begin
  Result := TPath.Combine(TPath.Combine(FOpt.CacheDir, Copy(Sha, 1, 2)), Sha);
  if FOpt.Filter = '' then Exit;
  if not FFiltered.ContainsKey(Sha) then PrepareFiltered([Sha]);
  if FFiltered.ContainsKey(Sha) then Result := FFiltered[Sha];
end;

function TPipeline.LfsPointer(const Sha: string; Store: Boolean): string;
// The LFS pointer git holds in place of this blob's content. With Store, the content is also
// put in the repository's LFS store, from where the push uploads it.
var
  F, Oid, Obj: string;
  Size: Int64;
begin
  F := ContentFile(Sha);
  if F.EndsWith(Sha) and not FFiltered.ContainsKey(Sha) then Oid := Sha   // unfiltered
  else Oid := LowerCase(THashSHA2.GetHashStringFromFile(F, SHA256));
  Size := TFile.GetSize(F);
  if Store then
  begin
    Obj := TPath.Combine(FOpt.RepoDir, 'lfs\objects\' + Copy(Oid, 1, 2) + '\' + Copy(Oid, 3, 2));
    TDirectory.CreateDirectory(Obj);
    Obj := TPath.Combine(Obj, Oid);
    if not TFile.Exists(Obj) or (TFile.GetSize(Obj) <> Size) then
    begin
      TFile.Copy(F, Obj + '.partial', True);
      if not MoveFileEx(PChar(Obj + '.partial'), PChar(Obj),
                        MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
        RaiseLastOSError;
      // Remembered until a push has uploaded it, across restarts, so the push can send just
      // these instead of scanning the whole history for what the remote might lack.
      TFile.AppendAllText(TPath.Combine(FOpt.MetaDir, 'lfs_pending.txt'), Oid + #13#10,
        TEncoding.ASCII);
    end;
  end;
  Result := 'version https://git-lfs.github.com/spec/v1'#10 +
            'oid sha256:' + Oid + #10 +
            'size ' + IntToStr(Size) + #10;
end;

function TPipeline.EmitBlob(FS: TStream; const B: TBlob; const Path: string;
  Marks: TDictionary<string, Integer>; var Mark: Integer; out BlobMark: Integer): Boolean;
// Writes what git holds for B at Path into the stream under a mark - once per stream and form
// - and returns that mark in BlobMark. False, and the caller writes no M line, for an excluded
// path or a blob missing from the cache (logged), rather than reference a mark that does not
// exist.
const
  GitHubLimit = Int64(100) * 1024 * 1024;
var
  Key, F: string;
  Lfs: Boolean;
  Src: TStream;
  LF: Byte;
begin
  BlobMark := 0;
  if Excluded(Path) then Exit(False);
  Lfs := IsLfsPath(Path);
  Key := B.Sha + IfThen(Lfs, '|lfs', '');
  if Marks.TryGetValue(Key, BlobMark) then Exit(True);
  F := ContentFile(B.Sha);
  if not TFile.Exists(F) then
  begin
    Log('  missing cached blob: ' + B.CachePath);
    Exit(False);
  end;
  // GitHub refuses the whole push over one file this size, after uploading everything else.
  if FOpt.Push and not Lfs and (TFile.GetSize(F) > GitHubLimit) then
    raise EUpdateRefused.CreateFmt('%s is %d MB - over GitHub''s 100 MB limit - and ' +
      '.gitattributes does not keep it in LFS. Nothing was pushed. Add an LFS rule for it ' +
      'to the published history first.', [Path, TFile.GetSize(F) div (1024 * 1024)]);
  Inc(Mark);
  BlobMark := Mark;
  Marks.Add(Key, Mark);
  PutLine(FS, 'blob');
  PutLine(FS, 'mark :' + IntToStr(Mark));
  if Lfs then Src := TStringStream.Create(LfsPointer(B.Sha, True), TEncoding.ASCII)
  else Src := TFileStream.Create(F, fmOpenRead or fmShareDenyWrite);
  try
    PutLine(FS, 'data ' + IntToStr(Src.Size));
    FS.CopyFrom(Src, 0);
  finally
    Src.Free;
  end;
  LF := 10;
  FS.WriteBuffer(LF, 1);
  Result := True;
end;

function TPipeline.BlobIndex: TObjectDictionary<string, TList<Integer>>;
// 'fileid|revision' -> indices into FBlobs. Scanning every blob for every revision is
// quadratic in the size of the history.
var
  I: Integer;
  Key: string;
  Lst: TList<Integer>;
begin
  Result := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
  for I := 0 to FBlobs.Count - 1 do
  begin
    Key := Format('%d|%s', [FBlobs[I].FileID, FBlobs[I].Revision]);
    if not Result.TryGetValue(Key, Lst) then
    begin
      Lst := TList<Integer>.Create;
      Result.Add(Key, Lst);
    end;
    Lst.Add(I);
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
// A plain TCP connect, so a down link costs a few seconds rather than a hung Get. The same
// check the login makes, including resolving a host name.
begin
  Result := FSession.ServerReachable(3000);
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
  if FOpt.StateFile <> '' then Exit(FOpt.StateFile);
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

procedure TPipeline.DiscardUncheckpointedBranch;
// The first-batch case of RewindToCheckpointTip. With no check-in recorded there is no tip to
// rewind to, so a branch that already exists holds only commits from an import that never
// reached its checkpoint - and the next import would add the same batch again on top of it.
var
  Actual: string;
begin
  RunProcess(FOpt.GitExe, 'rev-parse --verify --quiet refs/heads/' + FOpt.Branch,
             FOpt.RepoDir, Actual);
  Actual := Trim(Actual);
  if Actual = '' then Exit;
  Log(Format('Branch %s exists at %s but no check-in was ever recorded - deleting it so the',
    [FOpt.Branch, Copy(Actual, 1, 8)]));
  Log('interrupted first batch is redone once rather than duplicated.');
  RunProcess(FOpt.GitExe, Format('update-ref -d refs/heads/%s %s', [FOpt.Branch, Actual]),
             FOpt.RepoDir, FLastOut);
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
      C := SplitCsv(L[I]);
      if Length(C) < 6 then Continue;
      // The fields after the member are fixed, so count them from the end. A row written
      // before members were quoted has extra columns wherever the member name holds a comma;
      // read that way, its name is rejoined instead of shifting the sha and cache path.
      B.FileID := StrToUIntDef(C[0], 0);
      B.Revision := C[1];
      B.Member := string.Join(',', C, 2, Length(C) - 5);
      B.Sha := C[High(C) - 2];
      B.Size := StrToInt64Def(C[High(C) - 1], 0);
      B.CachePath := C[High(C)];
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
        C := SplitCsv(L[I]);
        if Length(C) < 4 then Continue;
        // file_id,tc_path,revision,reason. The reason holds no comma, so the revision is
        // second from the end - which also reads older rows whose path was not quoted.
        FHaveBlob.AddOrSetValue(Format('%s|%s', [C[0], C[High(C) - 1]]), True);
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
    Workers[I] := TFetchWorker.Create(Self);
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

procedure TPipeline.AppendRows(const Name, Header: string; const Rows: TArray<string>);
// Appends rows to a metadata CSV, creating it with its header if it does not exist yet.
var
  F: TStreamWriter;
  Path, S: string;
  IsNew: Boolean;
begin
  if Length(Rows) = 0 then Exit;
  Path := TPath.Combine(FOpt.MetaDir, Name);
  IsNew := not TFile.Exists(Path);
  if IsNew then
    F := TStreamWriter.Create(TFileStream.Create(Path, fmCreate or fmShareDenyWrite),
                              TEncoding.UTF8)
  else
    F := TStreamWriter.Create(TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite),
                              TEncoding.UTF8);
  try
    F.OwnStream;
    if IsNew then F.WriteLine(Header)
    else F.BaseStream.Seek(0, soEnd);
    for S in Rows do F.WriteLine(S);
  finally
    F.Free;
  end;
end;

procedure TPipeline.AppendSkipped(const Rows: TArray<string>);
begin
  AppendRows('skipped.csv', 'file_id,tc_path,revision,reason', Rows);
end;

procedure TPipeline.AppendManifest(const Rows: TArray<string>);
begin
  AppendRows('blobs.csv', 'file_id,revision,member,sha256,size,cache_path', Rows);
end;

procedure TPipeline.SortChronologically(var Revs: TArray<TTCRevision>);
// Oldest first, with ties broken by path and revision so the order is the same on every run:
// update mode relies on that to know what a previous run already imported.
begin
  TArray.Sort<TTCRevision>(Revs, TComparer<TTCRevision>.Construct(
    function(const A, B: TTCRevision): Integer
    begin
      Result := CompareDateTime(A.When, B.When);
      if Result = 0 then Result := CompareStr(A.TCPath, B.TCPath);
      if Result = 0 then Result := CompareStr(A.Revision, B.Revision);
    end));
end;

function TPipeline.SameCheckIn(const A, B: TTCRevision): Boolean;
// Team Coherence records no changeset, so a check-in is reconstructed from contiguous
// revisions by one author sharing one comment. Contiguity is what makes that safe: an
// exclusive-lock VCS means two people cannot touch the same file at once, and every human
// check-in here carries a comment (all 14,292 blank ones belong to "build").
//
// WindowSeconds = 0 means no time limit, which is the accurate choice: a genuine check-in can
// take hours to upload - one here spans 16 hours and 652 files - and a 180-second cap
// shattered 2,620 real check-ins into fragments.
//
// This is only used to avoid cutting a batch through the middle of a group. The authoritative
// commit boundary is in ImportRange, which ALSO splits when a file repeats inside a group;
// groups there are therefore never larger than what this predicts, so extending a batch by
// this rule stays conservative.
begin
  Result := (A.Author = B.Author) and (A.Comment = B.Comment) and
            ((FOpt.WindowSeconds <= 0) or
             (SecondsBetween(A.When, B.When) <= FOpt.WindowSeconds));
end;

// ---------------------------------------------------------------- revision lines
//
// Team Coherence numbers a file's revisions 1.0, 1.1, ... on the trunk; the first revision of
// a branch made from 1.5 is 1.5.1.0, its next 1.5.1.1, and a branch made from that 1.5.1.1.2.0.
// Checking in under a view based on a label branches from the label's revision when the trunk
// has moved on, and moves the label to the new revision. So every view is a LINE of revisions
// per file - the revision its label holds and that revision's ancestors - and a revision's
// number says which lines it is on.

function RevOnLine(const A, B: string): Boolean;
// True when revision A is B or one of B's ancestors: A is on the line that leads to B. A is on
// that line when it agrees with B up to its own last number and that number is no greater than
// B's at the same place: 1.49 and 1.49.1.3 lead to 1.49.1.18; 1.50 and 1.49.1.19 do not.
var
  PA, PB: TArray<string>;
  I, N: Integer;
begin
  PA := A.Split(['.']);
  PB := B.Split(['.']);
  N := Length(PA);
  if (N = 0) or (N > Length(PB)) or (A = '') then Exit(False);
  for I := 0 to N - 2 do
    if PA[I] <> PB[I] then Exit(False);
  Result := StrToIntDef(PA[N - 1], MaxInt) <= StrToIntDef(PB[N - 1], -1);
end;

procedure TPipeline.EnsureMainLine;
// Reads --main-line's label: the revision it holds of each file, and what every other version
// label holds, which is what tells a revision checked in under another view from one checked in
// under this label's view or under <default>.
const
  lt_VersionLabel = 1;
var
  L: TTCLabel;
  A: TTCAttachment;
  MainID: Cardinal;
  IsVersion: TDictionary<Cardinal, Boolean>;
  Found: Boolean;
  S: string;
begin
  if FMainLineOn or (FOpt.MainLine = '') then Exit;
  if not FOpt.IncludeTags then
    raise EUpdateRefused.Create('--main-line follows a version label, so it needs --tags too.');
  MainID := 0;
  Found := False;
  IsVersion := TDictionary<Cardinal, Boolean>.Create;
  try
    for L in FSession.Labels do
    begin
      IsVersion.AddOrSetValue(L.ID, L.LabelType = lt_VersionLabel);
      if (L.LabelType = lt_VersionLabel) and SameText(L.Name, FOpt.MainLine) then
      begin
        MainID := L.ID;
        Found := True;
      end;
    end;
    if not Found then
      raise EUpdateRefused.CreateFmt('--main-line: Team Coherence has no version label "%s".',
        [FOpt.MainLine]);
    FMainAt.Clear;
    FOtherAt.Clear;
    for A in FSession.Attachments do
      if A.LabelID = MainID then
        FMainAt.AddOrSetValue(A.FileID, A.Revision)
      else if IsVersion.ContainsKey(A.LabelID) and IsVersion[A.LabelID] then
      begin
        if FOtherAt.TryGetValue(A.FileID, S) then S := S + ';' + A.Revision
        else S := A.Revision;
        FOtherAt.AddOrSetValue(A.FileID, S);
      end;
  finally
    IsVersion.Free;
  end;
  if FMainAt.Count = 0 then
    raise EUpdateRefused.CreateFmt('--main-line: label "%s" holds no revisions here.',
      [FOpt.MainLine]);
  FMainLineOn := True;
  Log(Format('The branch follows label %s''s line: %d file(s) take the revision on its line; ' +
    'files it does not hold take their newest revision.', [FOpt.MainLine, FMainAt.Count]));
end;

function TPipeline.OnMainLine(const R: TTCRevision): Boolean;
// Whether a revision belongs on the branch. For a file the main-line label holds: the label's
// revision and those before it on its line, and a later revision that continues that line -
// unless another version label holds it or a revision after it, which means it was checked in
// under that label's view: a fix to another release. A file the label does not hold keeps
// every revision, as without --main-line.
var
  L, Others, O: string;
begin
  if not FMainLineOn then Exit(True);
  if not FMainAt.TryGetValue(R.FileID, L) then Exit(True);
  if RevOnLine(R.Revision, L) then Exit(True);
  if not RevOnLine(L, R.Revision) then Exit(False);     // on another line altogether
  if FOtherAt.TryGetValue(R.FileID, Others) then
    for O in Others.Split([';']) do
      if RevOnLine(R.Revision, O) then Exit(False);      // claimed by another view
  Result := True;
end;

function TPipeline.InMain(const R: TTCRevision): Boolean;
// Whether the branch's history holds this revision: what an update has handled, or for a
// migration everything on the branch's line.
begin
  if FLedger.Count > 0 then
    Result := FLedger.ContainsKey(Format('%d|%s', [R.FileID, R.Revision]))
  else
    Result := OnMainLine(R);
end;

procedure TPipeline.FollowMainLine;
// Update mode, with --main-line: each file the label holds is put back on the label's line
// where the branch holds something else. A branch built before --main-line took every revision
// in check-in order, so a fix made for an older release after the newer work replaced that
// work on the branch. Like a move, this is one commit, made before the new check-ins.
var
  Want: TDictionary<Cardinal, TTCRevision>;
  Index: TObjectDictionary<string, TList<Integer>>;
  Marks: TDictionary<string, Integer>;
  Changes: TList<TChange>;
  Shas, Listed: TStringList;
  R, W: TTCRevision;
  Lst: TList<Integer>;
  E: TTreeEntry;
  Chg: TChange;
  N, Mark, I: Integer;
  P, Msg, Out1: string;
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
begin
  if FOpt.MainLine = '' then Exit;
  EnsureMainLine;
  Want := TDictionary<Cardinal, TTCRevision>.Create;
  Index := BlobIndex;
  Marks := TDictionary<string, Integer>.Create;
  Changes := TList<TChange>.Create;
  Shas := TStringList.Create;
  Listed := TStringList.Create;
  try
    // the newest revision on the line that git already has, per file the label holds
    for R in FSession.Revisions do
      if FMainAt.ContainsKey(R.FileID) and
         FLedger.ContainsKey(Format('%d|%s', [R.FileID, R.Revision])) and OnMainLine(R) then
        if not Want.TryGetValue(R.FileID, W) or (CompareDateTime(R.When, W.When) > 0) then
          Want.AddOrSetValue(R.FileID, R);

    for W in Want.Values do
    begin
      if not Index.TryGetValue(Format('%d|%s', [W.FileID, W.Revision]), Lst) then Continue;
      for N in Lst do
      begin
        P := MemberPath(W.TCPath, FBlobs[N].Member);
        // only a path the branch has: a file gone from the tip stays gone
        if Excluded(P) or not FTree.TryGetValue(P, E) or (E.Sha = FBlobs[N].Sha) then Continue;
        Chg.Path := P;
        Chg.Sha := FBlobs[N].Sha;
        Chg.Mark := N;          // the blob's index, until the stream gives it a mark
        Changes.Add(Chg);
        Shas.Add(FBlobs[N].Sha);
        Listed.Add(Format('  %s: %s', [P, W.Revision]));
      end;
    end;
    if Changes.Count = 0 then
    begin
      Log(Format('Every file label %s holds is on its line at the tip.', [FOpt.MainLine]));
      Exit;
    end;

    PrepareFiltered(Shas.ToStringArray);
    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import for the main line.');
    FS := THandleStream.Create(GitIn);
    try
      Mark := 0;
      for I := Changes.Count - 1 downto 0 do
      begin
        Chg := Changes[I];
        if not EmitBlob(FS, FBlobs[Chg.Mark], Chg.Path, Marks, Mark, N) then
        begin
          Changes.Delete(I);
          Continue;
        end;
        Chg.Mark := N;
        Changes[I] := Chg;
      end;
      if Changes.Count > 0 then
      begin
        Listed.Sort;
        Msg := Format('Follow label %s''s line in Team Coherence' + #10#10 +
          'The view based on label %s has these files at the revisions below. The branch held ' +
          'a later revision checked in under another release''s view, which belongs to that ' +
          'release''s branch, not this one.' + #10#10 + '%s' + #10,
          [FOpt.MainLine, FOpt.MainLine, string.Join(#10, Listed.ToStringArray)]);
        PutLine(FS, 'commit refs/heads/' + FOpt.Branch);
        PutLine(FS, Format('committer %s %s', [MapAuthor('tc'), GitStamp(NowUtc)]));
        PutLine(FS, 'data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
        PutLine(FS, Msg);
        PutLine(FS, 'from refs/heads/' + FOpt.Branch + '^0');
        for Chg in Changes do
          PutLine(FS, Format('M 100644 :%d %s', [Chg.Mark, Chg.Path]));
      end;
    finally
      FS.Free;
    end;
    if FinishFastImport(GitProc, GitIn, Out1) <> 0 then
    begin
      Log('git fast-import FAILED on the main line:');
      Log(Out1);
      raise Exception.Create('git fast-import failed while following the main line.');
    end;
    if Changes.Count = 0 then Exit;
    for Chg in Changes do
    begin
      E := FTree[Chg.Path];
      E.Sha := Chg.Sha;
      FTree.AddOrSetValue(Chg.Path, E);
    end;
    Log(Format('%d path(s) put back on label %s''s line; they held revisions checked in for ' +
      'other releases:', [Changes.Count, FOpt.MainLine]));
    for P in Listed do Log(P);
    SaveUpdateCheckpoint;
  finally
    Listed.Free;
    Shas.Free;
    Changes.Free;
    Marks.Free;
    Index.Free;
    Want.Free;
  end;
end;

procedure TPipeline.RunIncremental;
var
  Revs: TArray<TTCRevision>;
  Total, Idx, BatchEnd, Done, BatchNo, FetchWindow: Integer;
  StartedAt: TDateTime;
  Secs: Double;
begin
  if not TestConnection then
    raise Exception.Create(
      'The Team Coherence server is not reachable.'#13#10#13#10 +
      'Check the VPN, then run again - the migration continues from where it stopped.');

  LoadAuthorMap;
  LoadBlobManifest;
  EnsureMainLine;

  // Watch the link for the whole run: an outage now pauses the workers instead of failing
  // thousands of revisions and abandoning the batch.
  FHeartbeat := THeartbeatThread.Create(Self);

  // oldest first: the history is replayed forward, exactly as it happened
  Revs := FSession.Revisions.ToArray;
  SortChronologically(Revs);
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
  if Idx > 0 then RewindToCheckpointTip else DiscardUncheckpointedBranch;
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
    while (BatchEnd < Total) and SameCheckIn(Revs[BatchEnd - 1], Revs[BatchEnd]) do
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
    // FConnLost is tested BEFORE the generic Cancelled check, because Cancelled is also true
    // when the link is lost. Testing Cancelled first skipped this block, so a lost connection
    // returned normally, the run reported success with exit 0, and the supervisor stopped
    // relaunching a migration that was only partly done.
    //
    // A dropped connection stops the run without committing, so the checkpoint never
    // marches past a gap. But a revision that is genuinely unfetchable must not block the
    // other 44,000: it is recorded in meta\failed.csv and reported at the end, so it is
    // visible rather than silently missing.
    if FConnLost then
    begin
      Log(Format('Batch %d abandoned: the connection dropped. Nothing committed for it.',
        [BatchNo]));
      FStoppedIncomplete := True;
      Break;
    end;
    if Cancelled then Break;
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
    Log(Format('*** %d revision(s) COULD NOT BE FETCHED - see meta\failed.csv ***',
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
  Index: TObjectDictionary<string, TList<Integer>>;
  Chg: TChange;
  I, Mark, CommitCount, Rc: Integer;
  GroupAuthor, GroupComment, Msg, Out1: string;
  GroupStart: TDateTime;
  FirstCommit, BranchExists: Boolean;

  procedure Put(const Line: string);
  begin
    PutLine(FS, Line);
  end;

  procedure EmitBlobsFor(const Rev: TTCRevision);
  var
    N: Integer;
    Lst: TList<Integer>;
    Was, Entry: TTreeEntry;
  begin
    if not Index.TryGetValue(Format('%d|%s', [Rev.FileID, Rev.Revision]), Lst) then Exit;
    for N in Lst do
    begin
      Chg.Path := MemberPath(Rev.TCPath, FBlobs[N].Member);
      Chg.Sha := FBlobs[N].Sha;
      // Update mode tracks the tip's tree, so a revision that would write the content a path
      // already holds is left out: a check-in made of nothing but those makes no commit.
      if FOpt.UpdateMode and FTree.TryGetValue(Chg.Path, Was) and (Was.Sha = Chg.Sha) then
        Continue;
      if not EmitBlob(FS, FBlobs[N], Chg.Path, Marks, Mark, Chg.Mark) then Continue;
      Pending.Add(Chg);
      if FOpt.UpdateMode then
      begin
        Entry.FileID := Rev.FileID;
        Entry.Member := FBlobs[N].Member;
        Entry.Sha := Chg.Sha;
        FTree.AddOrSetValue(Chg.Path, Entry);
      end;
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
    Put(Format('committer %s %s',
      [MapAuthor(GroupAuthor), GitStamp(GroupStart)]));
    Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
    Put(Msg);
    // Continue the existing history: without this the first commit of a resumed run would
    // start a second root commit and the branch would fork.
    if FirstCommit and BranchExists then
      Put('from refs/heads/' + FOpt.Branch + '^0');
    FirstCommit := False;
    for N := 0 to Pending.Count - 1 do
      Put(Format('M 100644 :%d %s', [Pending[N].Mark, Pending[N].Path]));
    Pending.Clear;
  end;

  // One filter run for the whole batch, before any blob is written.
  procedure FilterBatch;
  var
    I, N: Integer;
    Lst: TList<Integer>;
    Shas: TList<string>;
  begin
    if FOpt.Filter = '' then Exit;
    Shas := TList<string>.Create;
    try
      for I := StartIdx to EndIdx - 1 do
        if Index.TryGetValue(Format('%d|%s', [FSorted[I].FileID, FSorted[I].Revision]), Lst) then
          for N in Lst do Shas.Add(FBlobs[N].Sha);
      PrepareFiltered(Shas.ToArray);
    finally
      Shas.Free;
    end;
  end;

begin
  RunProcess(FOpt.GitExe, 'rev-parse --verify --quiet refs/heads/' + FOpt.Branch,
             FOpt.RepoDir, Out1);
  BranchExists := Trim(Out1) <> '';

  Marks := TDictionary<string, Integer>.Create;
  Pending := TList<TChange>.Create;
  GroupFiles := TDictionary<Cardinal, Boolean>.Create;
  Index := BlobIndex;
  try
    FilterBatch;
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
        // A fix checked in for another release is fetched - its release branch is built
        // from it - but is not part of this branch.
        if FMainLineOn and not OnMainLine(FSorted[I]) then Continue;
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
    Index.Free;
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

function LabelSignature(const Labels: TArray<TTCLabel>; const Att: TArray<TTCAttachment>;
  ID: Cardinal): string;
// What a label is, for telling whether it changed: its name, its comment and exactly which
// revisions it holds. Not its date - that depends on the zone the metadata was read in, and
// a label re-applied in TC changes its revisions anyway. '' for a label not in Labels.
var
  L: TTCLabel;
  A: TTCAttachment;
  Keys: TStringList;
begin
  Result := '';
  for L in Labels do
    if L.ID = ID then
    begin
      Result := L.Name + #1 + L.Comment;
      Break;
    end;
  if Result = '' then Exit;
  Keys := TStringList.Create;
  try
    for A in Att do
      if A.LabelID = ID then Keys.Add(Format('%d|%s', [A.FileID, A.Revision]));
    Keys.Sort;
    Result := Result + #1 + Keys.CommaText;
  finally
    Keys.Free;
  end;
end;

procedure TPipeline.ImportTags;
// Rebuilds each version label as its own ref holding the EXACT tree the label describes.
//
// A TC version label is not a pointer to a check-in - it is a list of (file, revision) pairs,
// which can mix revisions from any point in history and need not correspond to any commit that
// ever existed on the trunk. So a label cannot honestly be a git tag pointing at a trunk
// commit: it is emitted as its own commit with `deleteall` plus exactly the labelled
// revisions, on refs/tags/<name>.
//
// That commit's PARENT is a commit on the branch - see LabelParent. The parent says nothing
// about the label's content, which is the tree alone; it gives the label history in common
// with the branch. A label written as a root commit shares no history with anything, so a
// branch started from it can never be merged with another usefully: git has no common base and
// every file conflicts. That is what release branches (UpdateReleaseBranches) are built on.
//
// This work once lived in a whole-repository import that nothing called, so every run that
// passed --tags enumerated 44,450 attachments and then created no refs whatsoever. The lookups
// here are indexed; the original's nested scan was labels x attachments x 44,450 revisions.
const
  // TC label types. uTCApi declares these in its implementation section, so they are not
  // visible here. A promotion level (2) is attached to revisions just as a version label is -
  // the revision of each file promoted to it - so it is written the same way, under
  // refs/tags/promotion/ so that it is never taken for a version.
  lt_VersionLabel   = 1;
  lt_PromotionLabel = 2;
var
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Marks: TDictionary<string, Integer>;
  RevPath: TDictionary<string, string>;               // 'fileid|revision' -> TC path
  BlobsAt: TObjectDictionary<string, TList<Integer>>; // 'fileid|revision' -> FBlobs indices
  Lst: TList<Integer>;
  I, J, N, Mark, TagCount, Emitted: Integer;
  Key, Ep, Msg, Out1, P: string;
  // one entry per path in this label's tree, as mark + TAB + path. Not a name=value list: git
  // paths here contain spaces and could contain '=', but never a tab.
  Paths: TStringList;
  Parts: TArray<string>;
  UsedRefs: TDictionary<string, Boolean>;
  Refs: TArray<string>;        // per label: the ref to (re)build, '' to leave alone
  Unchanged, BlobMark: Integer;
  HasLfs: Boolean;
  NowLabels: TArray<TTCLabel>;
  NowAttach: TArray<TTCAttachment>;
  RevWhen: TDictionary<string, TDateTime>;            // 'fileid|revision' -> check-in, UTC
  Loose: TStringList;                                 // unchanged tags with no parent
  Newest, W: TDateTime;
  Parent: string;

  procedure Put(const Line: string);
  begin
    PutLine(FS, Line);
  end;

  // the latest check-in among the revisions a label holds content for
  function NewestOf(LabelID: Cardinal): TDateTime;
  var
    K: Integer;
    Key2: string;
    L2: TList<Integer>;
  begin
    Result := 0;
    for K := 0 to FSession.Attachments.Count - 1 do
    begin
      if FSession.Attachments[K].LabelID <> LabelID then Continue;
      Key2 := Format('%d|%s', [FSession.Attachments[K].FileID, FSession.Attachments[K].Revision]);
      if not BlobsAt.TryGetValue(Key2, L2) then Continue;
      if RevWhen.TryGetValue(Key2, W) and (W > Result) then Result := W;
    end;
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
  BlobsAt := BlobIndex;
  Paths := TStringList.Create;
  UsedRefs := TDictionary<string, Boolean>.Create;
  RevWhen := TDictionary<string, TDateTime>.Create;
  Loose := TStringList.Create;
  try
    for I := 0 to FSession.Revisions.Count - 1 do
    begin
      Key := Format('%d|%s', [FSession.Revisions[I].FileID, FSession.Revisions[I].Revision]);
      RevPath.AddOrSetValue(Key, FSession.Revisions[I].TCPath);
      RevWhen.AddOrSetValue(Key, FSession.Revisions[I].When);
    end;

    // ---- which labels to (re)build, and under which ref -----------------------------------
    // Tags, not branches under the branch. 'refs/heads/tc/main/label/x' cannot exist while
    // 'refs/heads/tc/main' does: git keeps a ref as a FILE, so the same path cannot also be a
    // directory. fast-import wrote all 38 label commits and then failed every ref update,
    // leaving 38 dangling commits and no labels - 21 supervisor retries in a row.
    //
    // refs/tags is also the right place semantically: a label IS a named snapshot, and
    // `git tag` is where anyone looking for "what shipped as v4.2.0" will look first.
    //
    // An update rebuilds only labels that changed in TC. The published tags may have been
    // reworked since they were made - re-dated, redacted, given an LFS .gitattributes - and
    // rebuilding an unchanged label would move its tag for nothing.
    SetLength(Refs, FSession.Labels.Count);
    Unchanged := 0;
    NowLabels := FSession.Labels.ToArray;
    NowAttach := FSession.Attachments.ToArray;
    for I := 0 to FSession.Labels.Count - 1 do
    begin
      Refs[I] := '';
      case FSession.Labels[I].LabelType of
        lt_VersionLabel:   Ep := 'refs/tags/' + SanitiseRefName(FSession.Labels[I].Name);
        lt_PromotionLabel: Ep := 'refs/tags/promotion/' + SanitiseRefName(FSession.Labels[I].Name);
      else
        Continue;
      end;
      // Sanitising can map two different TC names onto one ref ("V 4.2" and "V/4.2"), and
      // the second would silently replace the first.
      if UsedRefs.ContainsKey(LowerCase(Ep)) then
      begin
        J := 2;
        while UsedRefs.ContainsKey(LowerCase(Ep + '_' + IntToStr(J))) do Inc(J);
        Log(Format('  note: "%s" collides with an earlier label; using %s_%d',
          [FSession.Labels[I].Name, Ep, J]));
        Ep := Ep + '_' + IntToStr(J);
      end;
      UsedRefs.AddOrSetValue(LowerCase(Ep), True);
      if FOpt.UpdateMode and (LabelSignature(FOldLabels, FOldAttach, FSession.Labels[I].ID) =
         LabelSignature(NowLabels, NowAttach, FSession.Labels[I].ID)) and
         (RefSha(Ep) <> '') then
      begin
        Inc(Unchanged);
        // an unchanged tag written as a root commit, by an earlier version of this tool, is
        // given a parent; its tree stays exactly as published
        if RefSha(Ep + '^1') = '' then Loose.AddObject(Ep, TObject(NativeUInt(FSession.Labels[I].ID)));
        Continue;
      end;
      Refs[I] := Ep;
    end;
    if FOpt.UpdateMode then
      Log(Format('%d label(s) unchanged in TC keep their tags as published.', [Unchanged]));

    // one filter run for every blob the rebuilt labels need
    if FOpt.Filter <> '' then
    begin
      Paths.Clear;
      for J := 0 to FSession.Attachments.Count - 1 do
        for I := 0 to FSession.Labels.Count - 1 do
          if (Refs[I] <> '') and (FSession.Labels[I].ID = FSession.Attachments[J].LabelID) and
             BlobsAt.TryGetValue(Format('%d|%s', [FSession.Attachments[J].FileID,
               FSession.Attachments[J].Revision]), Lst) then
            for N in Lst do Paths.Add(FBlobs[N].Sha);
      PrepareFiltered(Paths.ToStringArray);
    end;

    Log(Format('Rebuilding %d label(s) from %d attachment(s)...',
      [FSession.Labels.Count - Unchanged, FSession.Attachments.Count]));

    // Forced: these refs belong to this tool, and only a label that changed in TC is rebuilt -
    // to move its tag.
    GitIn := 0;
    if not StartFastImport(GitProc, GitIn, True) then
      raise Exception.Create('Could not start git fast-import for the labels.');
    FS := THandleStream.Create(GitIn);
    try
      Mark := 0;
      TagCount := 0;
      for I := 0 to FSession.Labels.Count - 1 do
      begin
        if Cancelled then Break;
        if Refs[I] = '' then Continue;
        Ep := Refs[I];

        Paths.Clear;
        Emitted := 0;
        HasLfs := False;
        for J := 0 to FSession.Attachments.Count - 1 do
        begin
          if FSession.Attachments[J].LabelID <> FSession.Labels[I].ID then Continue;
          Key := Format('%d|%s',
            [FSession.Attachments[J].FileID, FSession.Attachments[J].Revision]);
          if not BlobsAt.TryGetValue(Key, Lst) then Continue;   // no content for it
          if not RevPath.ContainsKey(Key) then Continue;
          for N := 0 to Lst.Count - 1 do
          begin
            P := MemberPath(RevPath[Key], FBlobs[Lst[N]].Member);
            if not EmitBlob(FS, FBlobs[Lst[N]], P, Marks, Mark, BlobMark) then Continue;
            Paths.Add(IntToStr(BlobMark) + #9 + P);
            if IsLfsPath(P) then HasLfs := True;
            Inc(Emitted);
          end;
        end;

        if Emitted = 0 then
        begin
          Log(Format('  label "%s": no content available, skipped.', [FSession.Labels[I].Name]));
          Continue;
        end;

        Inc(TagCount);
        Msg := FSession.Labels[I].Name;
        if Trim(FSession.Labels[I].Comment) <> '' then
          Msg := Msg + #10#10 + FSession.Labels[I].Comment;
        Parent := LabelParent(Ep, NewestOf(FSession.Labels[I].ID));
        Put('commit ' + Ep);
        Put(Format('committer %s %s',
          [MapAuthor('tc'), GitStamp(FSession.Labels[I].When)]));
        Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
        Put(Msg);
        if Parent <> '' then Put('from ' + Parent);
        Put('deleteall');   // a label defines the whole tree, not a delta
        for J := 0 to Paths.Count - 1 do
        begin
          Parts := Paths[J].Split([#9]);
          if Length(Parts) = 2 then
            Put(Format('M 100644 :%s %s', [Parts[0], Parts[1]]));
        end;
        // An LFS pointer is only read as one where .gitattributes says so.
        if HasLfs and (FAttrBlob <> '') then
          Put('M 100644 ' + FAttrBlob + ' .gitattributes');
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

    for I := 0 to Loose.Count - 1 do
    begin
      if Cancelled then Break;
      ReattachTag(Loose[I], NewestOf(Cardinal(NativeUInt(Loose.Objects[I]))));
    end;

    // A label deleted in TC leaves its tag behind. Deleting a published tag is a decision for
    // a person, so they are listed rather than removed.
    if GitOut('for-each-ref --format=%(refname) refs/tags/', Out1) = 0 then
    begin
      Paths.Clear;
      for Key in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
        if not UsedRefs.ContainsKey(LowerCase(Trim(Key))) then Paths.Add(Trim(Key));
      if (Paths.Count > 0) and not Cancelled then
        Log(Format('  %d tag(s) no longer match any TC version label and were left in place: %s',
          [Paths.Count, string.Join(', ', Paths.ToStringArray)]));
    end;
  finally
    Loose.Free;
    RevWhen.Free;
    Paths.Free;
    UsedRefs.Free;
    BlobsAt.Free;
    RevPath.Free;
    Marks.Free;
  end;
end;

// ---------------------------------------------------------------- labels on the branch
//
// Where a label commit hangs. Its content is its tree; the parent only gives it history in
// common with the branch, which is what lets release branches built from labels be merged.

function TPipeline.TreeOf(const Rev: string): string;
begin
  if GitOut('rev-parse --verify --quiet ' + Rev + '^{tree}', Result) <> 0 then Result := '';
  Result := Trim(Result);
end;

function TPipeline.AttachPoint(NewestUtc: TDateTime): string;
// The newest commit on the branch checked in no later than the newest revision the label
// holds: the earliest point at which every file in the label existed. '' when the branch has
// no commits.
var
  Out1, Line: string;
  Parts: TArray<string>;
  L: TList<string>;
  T: TList<Int64>;
  I: Integer;
  At: Int64;
begin
  if Length(FBranchShas) = 0 then
  begin
    L := TList<string>.Create;
    T := TList<Int64>.Create;
    try
      if GitOut(Format('log --first-parent --format=%%H%%x09%%at refs/heads/%s', [FOpt.Branch]),
                Out1, 600) = 0 then
        for Line in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
        begin
          Parts := Trim(Line).Split([#9]);
          if (Length(Parts) = 2) and (Length(Parts[0]) = 40) then
          begin
            L.Add(Parts[0]);
            T.Add(StrToInt64Def(Parts[1], 0));
          end;
        end;
      FBranchShas := L.ToArray;
      FBranchTimes := T.ToArray;
    finally
      L.Free;
      T.Free;
    end;
  end;
  if Length(FBranchShas) = 0 then Exit('');
  At := DateTimeToUnix(NewestUtc, True);
  // newest first: the first commit not after the label's newest revision
  for I := 0 to High(FBranchShas) do
    if FBranchTimes[I] <= At then Exit(FBranchShas[I]);
  Result := FBranchShas[High(FBranchShas)];   // older than the whole branch: its first commit
end;

function TPipeline.LabelParent(const TagRef: string; NewestUtc: TDateTime): string;
// A label already published keeps the parent it has - the tag moves, its place on the branch
// does not - as long as that parent is on the branch. Otherwise it is attached by AttachPoint.
var
  Old: string;
begin
  Old := RefSha(TagRef + '^1');
  if (Old <> '') and IsAncestor(Old, 'refs/heads/' + FOpt.Branch) then Exit(Old);
  Result := AttachPoint(NewestUtc);
end;

function TPipeline.CommitTree(const Tree: string; const Parents: array of string;
  const Msg, Name, Email, RawDate: string): string;
// A commit made without a work tree: git commit-tree, identity and date given explicitly so the
// result does not depend on who runs it or when. The message goes through a file on stdin,
// because a command line cannot carry its newlines.
const
  Vars: array[0..5] of string = ('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
    'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE');
var
  Args, MsgFile, Out1: string;
  P: string;
  V: string;
begin
  Args := 'commit-tree ' + Tree;
  for P in Parents do Args := Args + ' -p ' + P;
  MsgFile := TPath.Combine(FOpt.MetaDir, 'commit-msg.tmp');
  TFile.WriteAllBytes(MsgFile, TEncoding.UTF8.GetBytes(Msg));   // no BOM: git would keep it
  SetEnvironmentVariable('GIT_AUTHOR_NAME', PChar(Name));
  SetEnvironmentVariable('GIT_AUTHOR_EMAIL', PChar(Email));
  SetEnvironmentVariable('GIT_AUTHOR_DATE', PChar(RawDate));
  SetEnvironmentVariable('GIT_COMMITTER_NAME', PChar(Name));
  SetEnvironmentVariable('GIT_COMMITTER_EMAIL', PChar(Email));
  SetEnvironmentVariable('GIT_COMMITTER_DATE', PChar(RawDate));
  try
    if RunProcess(FOpt.GitExe, Args, FOpt.RepoDir, Out1, MsgFile, True) <> 0 then
      raise Exception.Create('git commit-tree failed: ' + Trim(Out1));
  finally
    for V in Vars do SetEnvironmentVariable(PChar(V), nil);
    TFile.Delete(MsgFile);
  end;
  Result := Trim(Out1);
  if Length(Result) <> 40 then
    raise Exception.Create('git commit-tree returned no commit: ' + Result);
end;

procedure TPipeline.ReattachTag(const TagRef: string; NewestUtc: TDateTime);
// Gives a parentless tag a parent on the branch: the same tree, message, identity and date.
var
  Old, Parent, Out1, New: string;
  Id: TArray<string>;
begin
  Old := RefSha(TagRef);
  Parent := AttachPoint(NewestUtc);
  if (Old = '') or (Parent = '') then Exit;
  if (GitOut('log -1 --date=raw --format=%cn%x09%ce%x09%cd ' + Old, Out1) <> 0) then Exit;
  Id := Trim(Out1).Split([#9]);
  if Length(Id) <> 3 then Exit;
  if GitOut('log -1 --format=%B ' + Old, Out1) <> 0 then Exit;
  New := CommitTree(TreeOf(Old), [Parent], TrimRight(Out1) + #10, Id[0], Id[1], Id[2]);
  if GitOut(Format('update-ref %s %s %s', [TagRef, New, Old]), Out1) <> 0 then
    raise Exception.Create('Could not move ' + TagRef + ': ' + Trim(Out1));
  Log(Format('  %s attached to %s at %s (its files are unchanged)',
    [TagRef, FOpt.Branch, Copy(Parent, 1, 8)]));
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
//
// A file is removed only when its folder's listing is TRUSTED. A failed `tc Dir`, or one that
// quietly listed some other folder, used to make every file in that folder look deleted. So a
// folder is skipped - its files kept - when the command fails, when its path has a space
// (tc.exe cannot parse one and lists the current folder instead), or when the listing names
// none of the files known to be in it. The cost is that a folder whose files were ALL deleted
// keeps them; those folders are logged.
var
  Present: TDictionary<string, Boolean>;
  ByFolder: TObjectDictionary<string, TList<Integer>>;   // lower-case folder -> Files indices
  Folders: TStringList;
  GoneIds, Live: TDictionary<Cardinal, string>;           // file id -> TC path
  DelPaths: TStringList;
  Lst: TList<Integer>;
  I, J, Rc, Seen: Integer;
  Output, FolderPath, Line, Name, Why, TCPath: string;
  Lines: TArray<string>;
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Gone, Unchecked: TStringList;
  Cands: TArray<TTCFile>;
  AtTip: TDictionary<string, string>;

  procedure Put(const S: string);
  begin
    PutLine(FS, S);
  end;

begin
  Present := TDictionary<string, Boolean>.Create;
  ByFolder := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
  Folders := TStringList.Create;
  GoneIds := TDictionary<Cardinal, string>.Create;
  Live := TDictionary<Cardinal, string>.Create;
  DelPaths := TStringList.Create;
  Gone := TStringList.Create;
  Unchecked := TStringList.Create;
  try
    // The files to check. In update mode that includes files the previous run knew and TC no
    // longer enumerates - the likeliest deletions of all - checked at their old paths.
    // Absence from the enumeration alone is not trusted: an enumeration cut short by the
    // network, or a run over fewer projects, would look exactly like a mass deletion.
    Cands := FSession.Files.ToArray;
    if FOpt.UpdateMode then
    begin
      for I := 0 to High(Cands) do
        Live.AddOrSetValue(Cands[I].ID, Cands[I].TCPath);
      for I := 0 to High(FOldFiles) do
        if not Live.ContainsKey(FOldFiles[I].ID) then
          Cands := Cands + [FOldFiles[I]];
      Live.Clear;
    end;

    // every distinct folder that holds a migrated file
    for I := 0 to High(Cands) do
    begin
      FolderPath := Cands[I].TCPath;
      J := LastDelimiter('/', FolderPath);
      if J > 0 then FolderPath := Copy(FolderPath, 1, J - 1);
      if not ByFolder.TryGetValue(LowerCase(FolderPath), Lst) then
      begin
        Lst := TList<Integer>.Create;
        ByFolder.Add(LowerCase(FolderPath), Lst);
        Folders.Add(FolderPath);
      end;
      Lst.Add(I);
    end;
    Log(Format('Checking %d folders for files that no longer exist...', [Folders.Count]));

    for I := 0 to Folders.Count - 1 do
    begin
      if Cancelled then Exit;
      WaitIfPaused;
      Lst := ByFolder[LowerCase(Folders[I])];
      Why := '';
      if Pos(' ', Folders[I]) > 0 then
        Why := 'path has a space, which tc.exe cannot list'
      else
      begin
        Rc := RunProcess(FOpt.TcExe, Format('Dir "%s"', [Folders[I]]), FOpt.WorkDir, Output);
        if Rc <> 0 then
          Why := Format('tc Dir failed (exit %d)', [Rc])
        else
        begin
          Present.Clear;
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
          Seen := 0;
          for J in Lst do
            if Present.ContainsKey(LowerCase(Cands[J].TCPath)) then Inc(Seen);
          if Seen = 0 then
            Why := 'the listing names none of its known files'
          else
            for J in Lst do
              if not Present.ContainsKey(LowerCase(Cands[J].TCPath)) then
              begin
                Gone.Add(Cands[J].TCPath);
                GoneIds.AddOrSetValue(Cands[J].ID, Cands[J].TCPath);
              end;
        end;
      end;
      if Why <> '' then
        Unchecked.Add(Format('%s,%d,%s', [CsvQ(Folders[I]), Lst.Count, Why]));
      if (I mod 25 = 0) or (I = Folders.Count - 1) then
        Progress('Looking for deleted files', I + 1, Folders.Count);
    end;

    if Unchecked.Count > 0 then
    begin
      Log(Format('  %d folder(s) could not be checked reliably; their files are KEPT at the ' +
        'tip. Listed in meta\deleted_unchecked.csv.', [Unchecked.Count]));
      Unchecked.Insert(0, 'tc_folder,file_count,reason');
      Unchecked.SaveToFile(TPath.Combine(FOpt.MetaDir, 'deleted_unchecked.csv'), TEncoding.UTF8);
    end;

    if Gone.Count = 0 then
    begin
      Log('No deleted files found - the tip matches Team Coherence.');
      Exit;
    end;

    Log(Format('%d file(s) no longer exist in Team Coherence; removing them at the tip.',
      [Gone.Count]));
    Gone.SaveToFile(TPath.Combine(FOpt.MetaDir, 'deleted.csv'));

    // every path each deleted archive ever produced (all members of its file group), once
    DelPaths.Sorted := True;
    DelPaths.Duplicates := dupIgnore;
    for I := 0 to Gone.Count - 1 do
      DelPaths.Add(GitPathOf(Gone[I]));
    for J := 0 to FBlobs.Count - 1 do
      if GoneIds.TryGetValue(FBlobs[J].FileID, TCPath) then
        DelPaths.Add(MemberPath(TCPath, FBlobs[J].Member));
    // ...except any path an archive that still exists also writes: deleting it would remove
    // live content from the tip.
    for I := 0 to High(Cands) do
      if not GoneIds.ContainsKey(Cands[I].ID) then
        Live.AddOrSetValue(Cands[I].ID, Cands[I].TCPath);
    for J := 0 to FBlobs.Count - 1 do
      if Live.TryGetValue(FBlobs[J].FileID, TCPath) then
      begin
        Rc := DelPaths.IndexOf(MemberPath(TCPath, FBlobs[J].Member));
        if Rc >= 0 then DelPaths.Delete(Rc);
      end;
    // Update mode knows exactly which paths at the tip each archive wrote, wherever it was.
    if FOpt.UpdateMode then
      for TCPath in FTree.Keys do
        if GoneIds.ContainsKey(FTree[TCPath].FileID) then DelPaths.Add(TCPath);

    // Only what is still at the tip. Every run used to add another deletion commit naming
    // files an earlier one had already removed - fast-import does not skip an empty commit.
    AtTip := TipPaths;
    try
      for I := DelPaths.Count - 1 downto 0 do
        if not AtTip.ContainsKey(DelPaths[I]) then DelPaths.Delete(I);
    finally
      AtTip.Free;
    end;
    if DelPaths.Count = 0 then
    begin
      Log('  ...all of them were already removed from the tip by an earlier run.');
      Exit;
    end;

    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import for the deletion commit.');
    FS := THandleStream.Create(GitIn);
    try
      Put('commit refs/heads/' + FOpt.Branch);
      Put(Format('committer %s %s',
        [MapAuthor('tc'), GitStamp(NowUtc)]));
      Line := Format('Remove %d path(s) of files deleted in Team Coherence' + #10 + #10 +
        'These files no longer exist in the Team Coherence repository. TC records no ' +
        'deletion event that can be dated, so they are removed here in a single commit ' +
        'rather than at the point each was actually deleted. See meta/deleted.csv.',
        [DelPaths.Count]);
      Put('data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Line))));
      Put(Line);
      Put('from refs/heads/' + FOpt.Branch + '^0');
      for I := 0 to DelPaths.Count - 1 do
        Put('D ' + DelPaths[I]);
    finally
      FS.Free;
    end;
    if FinishFastImport(GitProc, GitIn, Output) <> 0 then
    begin
      Log('deletion commit failed: ' + Output);
      raise Exception.Create('git fast-import failed on the deletion commit.');
    end;
    Log(Format('Removed %d path(s) at the tip.', [DelPaths.Count]));
    if FOpt.UpdateMode then
    begin
      for I := 0 to DelPaths.Count - 1 do
        FTree.Remove(DelPaths[I]);
      SaveUpdateCheckpoint;
    end;
  finally
    Present.Free;
    ByFolder.Free;
    Folders.Free;
    GoneIds.Free;
    Live.Free;
    DelPaths.Free;
    Gone.Free;
    Unchecked.Free;
  end;
end;

// ---------------------------------------------------------------- update mode
//
// Brings a repository that has already been migrated - and pushed - up to date with the
// check-ins made in Team Coherence since, as a fast-forward on top of what is published.
//
// What is already in git is known exactly rather than inferred. The first update takes it from
// the original migration's own checkpoint: the first N revisions of the order that run saved.
// Every update after that keeps a ledger of what it handled. That record is then CHECKED, not
// trusted: every path in the branch tip must hold exactly the bytes of the TC revision the
// record says it does, or the update stops before changing anything. And the tip must be the
// one on the remote, so an update only ever builds on the published history.
//
// Matching by commit date instead would not work. A commit is dated by the FIRST revision of
// its check-in, which can span hours, and the deletion commit is dated when its run ended - so
// "everything after the tip's date" both skips and repeats revisions at the boundary.
//
// State, written together at every checkpoint (SaveUpdateCheckpoint):
//   meta\imported.csv     every (file, revision) handled: imported, empty, or given up
//   meta\tree.<sha>.csv   the tip's tree with provenance: path, file id, member, sha256
//   update.txt            the tip those describe, and how many ledger rows they cover

function TPipeline.GitOut(const Args: string; out Output: string; TimeoutSec: Integer): Integer;
begin
  Result := RunProcess(FOpt.GitExe, Args, FOpt.RepoDir, Output, '', True, TimeoutSec);
end;

function TPipeline.RefSha(const Ref: string): string;
begin
  if GitOut('rev-parse --verify --quiet ' + Ref + '^{commit}', Result) <> 0 then Result := '';
  Result := Trim(Result);
end;

function TPipeline.IsAncestor(const A, B: string): Boolean;
var
  Out1: string;
begin
  Result := GitOut(Format('merge-base --is-ancestor %s %s', [A, B]), Out1) = 0;
end;

function TPipeline.RemoteExists: Boolean;
var
  Out1: string;
begin
  Result := (FOpt.Remote <> '') and (GitOut('remote get-url ' + FOpt.Remote, Out1) = 0);
end;

function TPipeline.TipPaths(const Rev: string): TDictionary<string, string>;
// path -> git blob id of every file in Rev (the branch tip when empty); empty when there is no
// branch yet.
var
  Out1, Rec, Commit: string;
  Tab: Integer;
  Hdr: TArray<string>;
begin
  Result := TDictionary<string, string>.Create;
  try
    Commit := Rev;
    if Commit = '' then Commit := RefSha('refs/heads/' + FOpt.Branch);
    if Commit = '' then Exit;
    if GitOut('ls-tree -r -z --full-tree ' + Commit, Out1) <> 0 then
      raise Exception.Create('git ls-tree failed: ' + Copy(Trim(Out1), 1, 300));
    // NUL-separated, so no path is ever quoted or escaped: <mode> <type> <id> TAB <path>
    for Rec in Out1.Split([#0], TStringSplitOptions.ExcludeEmpty) do
    begin
      Tab := Pos(#9, Rec);
      if Tab = 0 then Continue;
      Hdr := Copy(Rec, 1, Tab - 1).Split([' ']);
      if (Length(Hdr) = 3) and (Hdr[1] = 'blob') then
        Result.AddOrSetValue(Copy(Rec, Tab + 1, MaxInt), Hdr[2]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TPipeline.GitFileIds(const Files: TArray<string>): TDictionary<string, string>;
// file -> the id git gives its bytes, so files on disk can be compared with a tree. git hashes
// them itself; --no-filters keeps line-ending conversion out of it, exactly as fast-import
// does. A file that does not exist gets no id.
var
  ListFile, Out1, F: string;
  L: TStringList;
  Present: TList<string>;
  Ids: TArray<string>;
  I: Integer;
begin
  Result := TDictionary<string, string>.Create;
  Present := TList<string>.Create;
  L := TStringList.Create;
  try
    try
      for F in Files do
      begin
        if Result.ContainsKey(F) or not TFile.Exists(F) then Continue;
        Result.Add(F, '');   // placeholder: keeps Present free of duplicates
        Present.Add(F);
        L.Add(F);
      end;
      Result.Clear;
      if Present.Count = 0 then Exit;
      ListFile := TPath.Combine(FOpt.WorkDir, 'hash-paths.txt');
      L.WriteBOM := False;
      L.SaveToFile(ListFile, TEncoding.UTF8);
      try
        if RunProcess(FOpt.GitExe, 'hash-object --no-filters --stdin-paths', FOpt.RepoDir,
                      Out1, ListFile, True, 3600) <> 0 then
          raise Exception.Create('git hash-object failed: ' + Copy(Trim(Out1), 1, 300));
      finally
        TFile.Delete(ListFile);
      end;
      Ids := Out1.Split([#10], TStringSplitOptions.ExcludeEmpty);
      if Length(Ids) <> Present.Count then
        raise Exception.CreateFmt('git hash-object returned %d ids for %d files',
          [Length(Ids), Present.Count]);
      for I := 0 to Present.Count - 1 do
        Result.AddOrSetValue(Present[I], Trim(Ids[I]));
    except
      Result.Free;
      raise;
    end;
  finally
    L.Free;
    Present.Free;
  end;
end;

function TPipeline.UpdateStatePath: string;
begin
  Result := TPath.Combine(FOpt.WorkDir, 'update.txt');
end;

procedure TPipeline.BuildFirstLedger(out Tip: string);
// The first update: what the original migration put in git is the first N revisions of the
// order it saved, N being its checkpoint. Revisions it could not fetch or found empty are in
// that range too, and count as handled - the same as they did then.
var
  L: TStringList;
  Old: TArray<TTCRevision>;
  Index: TObjectDictionary<string, TList<Integer>>;
  Lst: TList<Integer>;
  Idx, I, N: Integer;
  StateTip, Key: string;
  E: TTreeEntry;
begin
  if not TFile.Exists(StatePath) then
    raise EUpdateRefused.CreateFmt('There is no migration checkpoint at %s, so there is no ' +
      'migration here to update. Run a full migration first, or name the checkpoint file ' +
      'with --state.', [StatePath]);
  Idx := ReadCheckpoint;
  L := TStringList.Create;
  try
    L.LoadFromFile(StatePath);
    StateTip := Trim(L.Values['tip']);
  finally
    L.Free;
  end;

  Old := FSession.Revisions.ToArray;   // as the migration saved them
  SortChronologically(Old);
  if (Idx <= 0) or (Idx > Length(Old)) then
    raise EUpdateRefused.CreateFmt('state.txt records %d check-ins but the saved metadata ' +
      'has %d revisions, so what was migrated cannot be worked out.', [Idx, Length(Old)]);
  if Idx < Length(Old) then
    Log(Format('  note: the migration stopped at %d of %d revisions; the rest are added now.',
      [Idx, Length(Old)]));

  Tip := RefSha('refs/heads/' + FOpt.Branch);
  if Tip = '' then
    raise EUpdateRefused.CreateFmt('The repository has no branch %s.', [FOpt.Branch]);
  // Not a refusal: a history re-dated after the migration (fast-export, rewrite, fast-import)
  // has every commit hash changed and the same content. Whether this IS the migration's
  // history is settled by VerifyTree, which checks every file's bytes - a stronger test than
  // any hash, and one a re-dating does not disturb.
  if (StateTip <> '') and not IsAncestor(StateTip, Tip) then
    Log(Format('  note: branch %s does not contain %s, the commit the migration recorded - ' +
      'its history has been rewritten since (e.g. re-dated). The content check decides.',
      [FOpt.Branch, Copy(StateTip, 1, 8)]));

  Index := BlobIndex;
  try
    for I := 0 to Idx - 1 do
    begin
      Key := Format('%d|%s', [Old[I].FileID, Old[I].Revision]);
      FLedger.AddOrSetValue(Key, True);
      FLedgerNew.Add(Format('%d,%s', [Old[I].FileID, CsvQ(Old[I].Revision)]));
      // replayed in the same order ImportRange wrote them, so the last write to a path wins
      if Index.TryGetValue(Key, Lst) then
        for N in Lst do
        begin
          E.FileID := Old[I].FileID;
          E.Member := FBlobs[N].Member;
          E.Sha := FBlobs[N].Sha;
          FTree.AddOrSetValue(MemberPath(Old[I].TCPath, E.Member), E);
        end;
    end;
  finally
    Index.Free;
  end;
  Log(Format('First update: %d revisions recorded as migrated, from the migration''s ' +
    'checkpoint.', [Idx]));
end;

procedure TPipeline.LoadUpdateState(out Tip: string);
var
  L: TStringList;
  C: TArray<string>;
  Rows, I: Integer;
  TreeFile, LedgerFile: string;
  E: TTreeEntry;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(UpdateStatePath);
    Tip := Trim(L.Values['tip']);
    Rows := StrToIntDef(Trim(L.Values['ledger_rows']), -1);
    if (Tip = '') or (Rows < 0) then
      raise EUpdateRefused.Create('update.txt is damaged: it names no tip or no ledger size.');

    // Only the rows the checkpoint vouches for. Any after them were appended by an update
    // that stopped before its checkpoint; that work is redone, so they are dropped.
    LedgerFile := TPath.Combine(FOpt.MetaDir, 'imported.csv');
    if not TFile.Exists(LedgerFile) then
      raise EUpdateRefused.Create('update.txt exists but meta\imported.csv does not.');
    L.LoadFromFile(LedgerFile, TEncoding.UTF8);
    if L.Count - 1 < Rows then
      raise EUpdateRefused.CreateFmt('meta\imported.csv has %d rows but update.txt records ' +
        '%d.', [L.Count - 1, Rows]);
    for I := 1 to Rows do
    begin
      C := SplitCsv(L[I]);
      if Length(C) >= 2 then FLedger.AddOrSetValue(C[0] + '|' + C[1], True);
    end;
    if L.Count - 1 > Rows then
    begin
      Log(Format('  dropping %d ledger row(s) an interrupted update wrote after its last ' +
        'checkpoint', [L.Count - 1 - Rows]));
      while L.Count - 1 > Rows do L.Delete(L.Count - 1);
      L.WriteBOM := False;
      L.SaveToFile(LedgerFile, TEncoding.UTF8);
    end;
    FLedgerRows := Rows;

    TreeFile := TPath.Combine(FOpt.MetaDir, 'tree.' + Tip + '.csv');
    if not TFile.Exists(TreeFile) then
      raise EUpdateRefused.CreateFmt('meta\tree.%s.csv, the record of the last update''s ' +
        'tree, is missing.', [Tip]);
    L.LoadFromFile(TreeFile, TEncoding.UTF8);
    for I := 1 to L.Count - 1 do
    begin
      C := SplitCsv(L[I]);
      if Length(C) < 4 then Continue;
      E.FileID := StrToUIntDef(C[1], 0);
      E.Member := C[2];
      E.Sha := C[3];
      FTree.AddOrSetValue(C[0], E);
    end;
  finally
    L.Free;
  end;
  Log(Format('Last update: %d revisions handled, tip %s, %d paths.',
    [FLedger.Count, Copy(Tip, 1, 8), FTree.Count]));
end;

procedure TPipeline.SaveUpdateCheckpoint;
// Order matters, so that a stop at any point leaves a consistent state: ledger rows first (the
// row count in update.txt still excludes them), then the tree under the new tip's own name
// (the old tree file is still there), then update.txt by rename, and only then the old trees.
var
  Tip, TreeFile, Tmp, F: string;
  L: TStringList;
  P: string;
  E: TTreeEntry;
begin
  Tip := RefSha('refs/heads/' + FOpt.Branch);
  if Tip = '' then raise Exception.Create('No branch to record an update checkpoint for.');

  if FLedgerNew.Count > 0 then
  begin
    AppendRows('imported.csv', 'file_id,revision', FLedgerNew.ToStringArray);
    Inc(FLedgerRows, FLedgerNew.Count);
    FLedgerNew.Clear;
  end;

  L := TStringList.Create;
  try
    TreeFile := TPath.Combine(FOpt.MetaDir, 'tree.' + Tip + '.csv');
    L.Add('path,file_id,member,sha256');
    for P in FTree.Keys do
    begin
      E := FTree[P];
      L.Add(Format('%s,%d,%s,%s', [CsvQ(P), E.FileID, CsvQ(E.Member), E.Sha]));
    end;
    L.WriteBOM := False;
    L.SaveToFile(TreeFile, TEncoding.UTF8);

    L.Clear;
    L.Values['tip'] := Tip;
    L.Values['ledger_rows'] := IntToStr(FLedgerRows);
    L.Values['branch'] := FOpt.Branch;
    L.Values['updated'] := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    Tmp := UpdateStatePath + '.tmp';
    L.SaveToFile(Tmp);
    if not MoveFileEx(PChar(Tmp), PChar(UpdateStatePath),
                      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  finally
    L.Free;
  end;

  for F in TDirectory.GetFiles(FOpt.MetaDir, 'tree.*.csv') do
    if not SameText(F, TreeFile) then TFile.Delete(F);
end;

procedure TPipeline.VerifyTree(const Tip: string; Prune: Boolean);
// The check that makes the record trustworthy: every path at Tip must hold exactly what git
// should hold for the TC revision recorded for it - its bytes after the --filter, or the LFS
// pointer to them where .gitattributes says so - and nothing else may be there except git's
// own files (.gitattributes, .gitignore).
//
// Prune is for the first update only. The migration's deletion commit removed some paths that
// the replayed record still has; those are dropped from the record rather than counted.
var
  AtTip, Ids: TDictionary<string, string>;
  Expect: TDictionary<string, string>;    // path -> the file holding what git should have
  Shas: TDictionary<string, Boolean>;
  Rows, Dropped, Own: TStringList;
  P, Want, Got, PtrDir, PtrFile: string;
  E: TTreeEntry;
  Excl: Integer;
begin
  AtTip := TipPaths(Tip);
  Expect := TDictionary<string, string>.Create;
  Shas := TDictionary<string, Boolean>.Create;
  Rows := TStringList.Create;
  Dropped := TStringList.Create;
  Own := TStringList.Create;
  Ids := nil;
  try
    // an excluded path is not expected anywhere
    for P in FTree.Keys do
      if Excluded(P) then Dropped.Add(P);
    for P in Dropped do FTree.Remove(P);
    Excl := Dropped.Count;
    Dropped.Clear;
    if Excl > 0 then
      Log(Format('  %d excluded path(s) are not expected at the tip.', [Excl]));

    for E in FTree.Values do Shas.AddOrSetValue(E.Sha, True);
    PrepareFiltered(Shas.Keys.ToArray);
    PtrDir := TPath.Combine(FOpt.WorkDir, 'lfs-pointers');
    for P in FTree.Keys do
    begin
      E := FTree[P];
      if IsLfsPath(P) then
      begin
        TDirectory.CreateDirectory(PtrDir);
        PtrFile := TPath.Combine(PtrDir, E.Sha);
        TFile.WriteAllText(PtrFile, LfsPointer(E.Sha, False), TEncoding.ASCII);
        Expect.Add(P, PtrFile);
      end
      else
        Expect.Add(P, ContentFile(E.Sha));
    end;
    Ids := GitFileIds(Expect.Values.ToArray);

    for P in FTree.Keys do
    begin
      if not Ids.TryGetValue(Expect[P], Want) then Want := '(not in the blob cache)';
      if not AtTip.TryGetValue(P, Got) then
      begin
        if Prune then Dropped.Add(P)
        else Rows.Add(Format('%s,%s,(absent)', [CsvQ(P), Want]));
      end
      else if Want <> Got then
        Rows.Add(Format('%s,%s,%s', [CsvQ(P), Want, Got]));
    end;
    for P in AtTip.Keys do
      if not FTree.ContainsKey(P) then
        if P.Substring(P.LastIndexOf('/') + 1).StartsWith('.git') then Own.Add(P)
        else Rows.Add(Format('%s,(no Team Coherence revision recorded),%s',
          [CsvQ(P), AtTip[P]]));

    for P in Dropped do FTree.Remove(P);
    if Dropped.Count > 0 then
      Log(Format('  %d path(s) removed by the migration''s deletion commit are no longer ' +
        'expected at the tip.', [Dropped.Count]));
    if Own.Count > 0 then
      Log(Format('  kept as they are: %s (git''s own, not from Team Coherence)',
        [string.Join(', ', Own.ToStringArray)]));

    if Rows.Count > 0 then
    begin
      Rows.Insert(0, 'path,expected_blob,blob_at_tip');
      Rows.SaveToFile(TPath.Combine(FOpt.MetaDir, 'update_mismatch.csv'), TEncoding.UTF8);
      raise EUpdateRefused.CreateFmt(
        '%d path(s) at %s do not hold what the record of the migration says they should; ' +
        'they are listed in meta\update_mismatch.csv. Nothing was changed. Updating on top ' +
        'of a tree that does not match Team Coherence would carry the difference forward.',
        [Rows.Count - 1, Copy(Tip, 1, 8)]);
    end;
    Log(Format('Verified: all %d paths at %s hold exactly the Team Coherence content ' +
      'recorded for them.', [FTree.Count, Copy(Tip, 1, 8)]));
  finally
    if TDirectory.Exists(TPath.Combine(FOpt.WorkDir, 'lfs-pointers')) then
      TDirectory.Delete(TPath.Combine(FOpt.WorkDir, 'lfs-pointers'), True);
    Ids.Free;
    Own.Free;
    Dropped.Free;
    Rows.Free;
    Shas.Free;
    Expect.Free;
    AtTip.Free;
  end;
end;

procedure TPipeline.BeginUpdate;
// Called after the PREVIOUS run's metadata has been loaded and before Team Coherence is read
// again: works out what is already in git, makes the branch match the remote, and verifies the
// tip's content. Refuses, changing nothing, when any of that does not add up.
var
  Recorded, Local, Remote, Out1: string;
  First: Boolean;
begin
  if not TDirectory.Exists(FOpt.RepoDir) then
    raise EUpdateRefused.CreateFmt('There is no repository at %s to update.', [FOpt.RepoDir]);
  // git has no terminal to prompt on here, so a missing credential must fail, not wait.
  SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0');
  LoadBlobManifest;
  FOldFiles := FSession.Files.ToArray;
  FOldRevs := FSession.Revisions.ToArray;
  FOldAttach := FSession.Attachments.ToArray;
  FOldLabels := FSession.Labels.ToArray;

  First := not TFile.Exists(UpdateStatePath);
  if First then BuildFirstLedger(Recorded) else LoadUpdateState(Recorded);

  // An update that stopped between an import and its checkpoint leaves commits nothing
  // vouches for. They are redone, not kept.
  Local := RefSha('refs/heads/' + FOpt.Branch);
  if Local = '' then
    raise EUpdateRefused.CreateFmt('The repository has no branch %s.', [FOpt.Branch]);
  if Local <> Recorded then
  begin
    if not IsAncestor(Recorded, Local) then
      raise EUpdateRefused.CreateFmt('Branch %s is at %s, which does not contain the last ' +
        'update''s checkpoint %s. Something other than tc2git changed it.',
        [FOpt.Branch, Copy(Local, 1, 8), Copy(Recorded, 1, 8)]);
    Log(Format('Branch is at %s, past the last checkpoint %s: an update stopped before ' +
      'recording its work. Discarding that so it is redone once.',
      [Copy(Local, 1, 8), Copy(Recorded, 1, 8)]));
    if GitOut(Format('update-ref refs/heads/%s %s %s', [FOpt.Branch, Recorded, Local]),
              Out1) <> 0 then
      raise Exception.Create('Could not rewind the branch: ' + Trim(Out1));
  end;

  // The remote holds the published history, and an update builds only on that.
  EnsureRemote;
  if RemoteExists then
  begin
    Log(Format('Checking %s on %s...', [FOpt.Branch, FOpt.Remote]));
    if GitOut(Format('ls-remote --heads %s refs/heads/%s', [FOpt.Remote, FOpt.Branch]),
              Out1, 600) <> 0 then
      raise Exception.Create('Could not reach the remote: ' + Copy(Trim(Out1), 1, 300));
    Remote := '';
    if Trim(Out1) <> '' then
    begin
      if GitOut(Format('fetch --no-tags %s +refs/heads/%s:refs/remotes/%s/%s',
                [FOpt.Remote, FOpt.Branch, FOpt.Remote, FOpt.Branch]), Out1, 3600) <> 0 then
        raise Exception.Create('git fetch failed: ' + Copy(Trim(Out1), 1, 300));
      Remote := RefSha(Format('refs/remotes/%s/%s', [FOpt.Remote, FOpt.Branch]));
    end;
    if Remote = '' then
      Log('  the branch is not on the remote yet; a push will create it.')
    else if Remote = Recorded then
      Log(Format('  %s/%s is at %s, the same commit this update starts from.',
        [FOpt.Remote, FOpt.Branch, Copy(Remote, 1, 8)]))
    else if IsAncestor(Remote, Recorded) then
      Log(Format('  %s/%s is at %s, behind this repository - an earlier push did not ' +
        'finish. The push brings it up to date.', [FOpt.Remote, FOpt.Branch, Copy(Remote, 1, 8)]))
    else
      raise EUpdateRefused.CreateFmt('%s/%s is at %s, which this repository does not ' +
        'contain. The mirror is meant to be written only by tc2git, so a commit was made on ' +
        'the remote or its history was rewritten. Nothing was changed; resolve that first.',
        [FOpt.Remote, FOpt.Branch, Copy(Remote, 1, 8)]);
  end
  else if FOpt.Push then
    raise EUpdateRefused.CreateFmt('--push was given but the repository has no remote "%s". ' +
      'Add it once with: git -C "%s" remote add %s <url>',
      [FOpt.Remote, FOpt.RepoDir, FOpt.Remote])
  else
    Log(Format('No remote "%s" in the repository: this update stays local.', [FOpt.Remote]));

  // what the published history keeps in LFS: needed to know what each path should hold
  LoadLfsPatterns(Recorded);
  VerifyTree(Recorded, First);
  if First then SaveUpdateCheckpoint;
end;

procedure TPipeline.PrepareLabelCarryOver;
// The label pass asks TC, one call per labelled revision, which labels each one carries - by
// far the slowest phase. TC also says HOW MANY each carries (ver_count), so a revision whose
// count is unchanged since the last run keeps the answer it got then, and only the rest are
// asked. A label moved from one revision to another changes the count of both, so both are
// asked again.
var
  OldVer: TDictionary<string, Integer>;
  OldLabels: TObjectDictionary<string, TList<Cardinal>>;
  Done, Found: TStringList;
  R: TTCRevision;
  A: TTCAttachment;
  Key: string;
  V, Carried, Asked: Integer;
  Lst: TList<Cardinal>;
  LabelID: Cardinal;
begin
  OldVer := TDictionary<string, Integer>.Create;
  OldLabels := TObjectDictionary<string, TList<Cardinal>>.Create([doOwnsValues]);
  Done := TStringList.Create;
  Found := TStringList.Create;
  try
    // version labels and promotion levels together: both are in the attachment list
    for R in FOldRevs do
      if R.VerCount >= 0 then
        OldVer.AddOrSetValue(Format('%d|%s', [R.FileID, R.Revision]),
          R.VerCount + Max(R.PromoCount, 0));
    for A in FOldAttach do
    begin
      Key := Format('%d|%s', [A.FileID, A.Revision]);
      if not OldLabels.TryGetValue(Key, Lst) then
      begin
        Lst := TList<Cardinal>.Create;
        OldLabels.Add(Key, Lst);
      end;
      Lst.Add(A.LabelID);
    end;

    // the same files and layout EnumAttachments resumes from
    Done.Add('file_id,revision');
    Found.Add('label_id,file_id,revision');
    Carried := 0;
    Asked := 0;
    for R in FSession.Revisions do
    begin
      if (R.VerCount <= 0) and (R.PromoCount <= 0) then Continue;
      Key := Format('%d|%s', [R.FileID, R.Revision]);
      if OldVer.TryGetValue(Key, V) and (V = R.VerCount + Max(R.PromoCount, 0)) and
         OldLabels.TryGetValue(Key, Lst) and (Lst.Count = V) then
      begin
        Done.Add(Format('%d,%s', [R.FileID, R.Revision]));
        for LabelID in Lst do
          Found.Add(Format('%d,%d,%s', [LabelID, R.FileID, R.Revision]));
        Inc(Carried);
      end
      else
        Inc(Asked);
    end;
    Done.WriteBOM := False;
    Found.WriteBOM := False;
    Done.SaveToFile(TPath.Combine(FOpt.MetaDir, 'attach_done.csv'), TEncoding.UTF8);
    Found.SaveToFile(TPath.Combine(FOpt.MetaDir, 'attach_log.csv'), TEncoding.UTF8);
    if TFile.Exists(TPath.Combine(FOpt.MetaDir, 'label_files.csv')) then
      TFile.Delete(TPath.Combine(FOpt.MetaDir, 'label_files.csv'));
    Log(Format('Labels: %d labelled revision(s) unchanged since the last run keep their ' +
      'labels; %d will be asked.', [Carried, Asked]));
  finally
    Found.Free;
    Done.Free;
    OldLabels.Free;
    OldVer.Free;
  end;
end;

procedure TPipeline.FollowMovedFiles;
// A file moved or renamed in TC keeps its id and changes path. Its next revision would be
// written at the new path while the old path stayed, and a file moved with no new revision
// would never appear at the new path at all. So moves are applied first, as their own commit,
// with the content the file already has in git.
var
  NewPath: TDictionary<Cardinal, string>;
  BySha: TDictionary<string, Integer>;
  Marks, MoveMark: TDictionary<string, Integer>;
  Moves: TList<TPair<string, string>>;
  Move: TPair<string, string>;
  Tail: TStringList;
  P, NP, TCPath, Msg, Out1: string;
  E: TTreeEntry;
  I, Mark, Idx, BlobMark: Integer;
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
begin
  NewPath := TDictionary<Cardinal, string>.Create;
  BySha := TDictionary<string, Integer>.Create;
  Marks := TDictionary<string, Integer>.Create;
  MoveMark := TDictionary<string, Integer>.Create;
  Moves := TList<TPair<string, string>>.Create;
  Tail := TStringList.Create;
  try
    for I := 0 to FSession.Files.Count - 1 do
      NewPath.AddOrSetValue(FSession.Files[I].ID, FSession.Files[I].TCPath);
    for P in FTree.Keys do
    begin
      E := FTree[P];
      if not NewPath.TryGetValue(E.FileID, TCPath) then Continue;   // gone: not a move
      NP := MemberPath(TCPath, E.Member);
      if NP <> P then Moves.Add(TPair<string, string>.Create(P, NP));
    end;
    if Moves.Count = 0 then
    begin
      Log('No files moved or renamed in Team Coherence.');
      Exit;
    end;

    for I := 0 to FBlobs.Count - 1 do
      if not BySha.ContainsKey(FBlobs[I].Sha) then BySha.Add(FBlobs[I].Sha, I);
    for Move in Moves do Tail.Add(FTree[Move.Key].Sha);
    PrepareFiltered(Tail.ToStringArray);
    Tail.Clear;

    GitIn := 0;
    if not StartFastImport(GitProc, GitIn) then
      raise Exception.Create('Could not start git fast-import for the moves.');
    FS := THandleStream.Create(GitIn);
    try
      // blobs before the commit: fast-import takes no blob inside a commit's file list
      Mark := 0;
      for I := Moves.Count - 1 downto 0 do
      begin
        E := FTree[Moves[I].Key];
        if not BySha.TryGetValue(E.Sha, Idx) or
           not EmitBlob(FS, FBlobs[Idx], Moves[I].Value, Marks, Mark, BlobMark) then
        begin
          Log(Format('  not moving %s: its content is not in the blob cache, or its new path ' +
            'is excluded; left in place', [Moves[I].Key]));
          Moves.Delete(I);
        end
        else
          MoveMark.AddOrSetValue(Moves[I].Key, BlobMark);
      end;
      if Moves.Count > 0 then
      begin
        PutLine(FS, 'commit refs/heads/' + FOpt.Branch);
        PutLine(FS, Format('committer %s %s',
          [MapAuthor('tc'), GitStamp(NowUtc)]));
        Msg := Format('Follow %d path(s) moved or renamed in Team Coherence' + #10 + #10 +
          'Team Coherence records no date for a move, so the files move here, with the ' +
          'content they already had, before the check-ins that follow.', [Moves.Count]);
        PutLine(FS, 'data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
        PutLine(FS, Msg);
        PutLine(FS, 'from refs/heads/' + FOpt.Branch + '^0');
        // every D before any M, so a move onto a path another move vacates is not undone
        for Move in Moves do PutLine(FS, 'D ' + Move.Key);
        for Move in Moves do
          PutLine(FS, Format('M 100644 :%d %s', [MoveMark[Move.Key], Move.Value]));
      end;
    finally
      FS.Free;
    end;
    if FinishFastImport(GitProc, GitIn, Out1) <> 0 then
    begin
      Log('git fast-import FAILED on the moves:');
      Log(Out1);
      raise Exception.Create('git fast-import failed while applying moves.');
    end;
    if Moves.Count = 0 then Exit;

    for Move in Moves do
    begin
      E := FTree[Move.Key];
      FTree.Remove(Move.Key);
      FTree.AddOrSetValue(Move.Value, E);
      Tail.Add(Move.Key + ' -> ' + Move.Value);
    end;
    Log(Format('Moved %d path(s) to follow Team Coherence: %s', [Moves.Count,
      IfThen(Tail.Count <= 5, string.Join('; ', Tail.ToStringArray), Tail[0] + '; ...')]));
    SaveUpdateCheckpoint;
  finally
    Tail.Free;
    Moves.Free;
    Marks.Free;
    MoveMark.Free;
    BySha.Free;
    NewPath.Free;
  end;
end;

procedure TPipeline.RunUpdate;
// Adds every revision Team Coherence has that git does not, in check-in order, on top of the
// verified tip - except one OLDER than a revision of the same file already in git: adding it
// would put old content over new, so it is listed instead.
var
  Revs: TArray<TTCRevision>;
  LastIdx: TDictionary<Cardinal, Integer>;
  NewRevs: TList<TTCRevision>;
  Behind: TStringList;
  Key: string;
  I, P, Idx, BatchEnd, Total, BatchNo, FetchWindow, OffLine: Integer;
begin
  if not TestConnection then
    raise Exception.Create(
      'The Team Coherence server is not reachable.'#13#10#13#10 +
      'Check the VPN, then run again - the update continues from where it stopped.');
  LoadAuthorMap;
  EnsureMainLine;

  Revs := FSession.Revisions.ToArray;
  SortChronologically(Revs);
  LastIdx := TDictionary<Cardinal, Integer>.Create;
  NewRevs := TList<TTCRevision>.Create;
  Behind := TStringList.Create;
  OffLine := 0;
  try
    // where each file's history in git ends, in today's order - on the branch's line: a fix
    // for another release, handled but kept off the branch, does not count
    for I := 0 to High(Revs) do
      if FLedger.ContainsKey(Format('%d|%s', [Revs[I].FileID, Revs[I].Revision])) and
         OnMainLine(Revs[I]) then
        LastIdx.AddOrSetValue(Revs[I].FileID, I);
    for I := 0 to High(Revs) do
    begin
      Key := Format('%d|%s', [Revs[I].FileID, Revs[I].Revision]);
      if FLedger.ContainsKey(Key) then Continue;
      // still fetched, for its release branch; ImportRange leaves it off this one
      if not OnMainLine(Revs[I]) then
      begin
        Inc(OffLine);
        NewRevs.Add(Revs[I]);
      end
      else if LastIdx.TryGetValue(Revs[I].FileID, P) and (I < P) then
        Behind.Add(Format('%d,%s,%s', [Revs[I].FileID, CsvQ(Revs[I].TCPath),
          CsvQ(Revs[I].Revision)]))
      else
        NewRevs.Add(Revs[I]);
    end;
    if Behind.Count > 0 then
    begin
      Log(Format('  %d revision(s) not in git are older than a revision of the same file ' +
        'that is; left out and listed in meta\update_behind.csv.', [Behind.Count]));
      Behind.Insert(0, 'file_id,tc_path,revision');
      Behind.SaveToFile(TPath.Combine(FOpt.MetaDir, 'update_behind.csv'), TEncoding.UTF8);
    end;
    if OffLine > 0 then
      Log(Format('  %d new revision(s) were checked in under other releases'' views: fetched ' +
        'for their release branches, not added to %s.', [OffLine, FOpt.Branch]));
    FSorted := NewRevs.ToArray;
  finally
    Behind.Free;
    NewRevs.Free;
    LastIdx.Free;
  end;

  Total := Length(FSorted);
  if Total = 0 then
  begin
    Log('Team Coherence has no check-ins that are not already in git.');
    Exit;
  end;
  Log(Format('%d new revision(s) to add, checked in from %s to %s UTC.',
    [Total, DateTimeToStr(FSorted[0].When), DateTimeToStr(FSorted[Total - 1].When)]));

  FOverallTotal := Total;
  FOverallBase := 0;
  FRunStarted := Now;
  FStartedAt := 0;
  FDoneHigh := 0;
  FFetchedTo := 0;
  Idx := 0;
  BatchNo := 0;
  FHeartbeat := THeartbeatThread.Create(Self);
  try
    while (Idx < Total) and not Cancelled do
    begin
      Inc(BatchNo);
      BatchEnd := Idx + FOpt.BatchSize;
      if BatchEnd > Total then BatchEnd := Total;
      while (BatchEnd < Total) and SameCheckIn(FSorted[BatchEnd - 1], FSorted[BatchEnd]) do
        Inc(BatchEnd);
      Item(Format('batch %d: revisions %d-%d of %d', [BatchNo, Idx + 1, BatchEnd, Total]));
      FFailed := 0;
      FOverallBase := Idx;
      Overall(Idx, Total);

      // a wide fetch window for the same reason as RunIncremental
      if FFetchedTo < BatchEnd then
      begin
        FetchWindow := Idx + FOpt.BatchSize * 4;
        if FetchWindow > Total then FetchWindow := Total;
        FetchRange(FFetchedTo, FetchWindow);
        FFetchedTo := FetchWindow;
      end;
      if FConnLost then
      begin
        Log(Format('Batch %d abandoned: the connection dropped. Nothing recorded for it.',
          [BatchNo]));
        FStoppedIncomplete := True;
        Break;
      end;
      if Cancelled then Break;
      if FFailed > 0 then
        Log(Format('Batch %d: %d revision(s) could not be fetched - recorded in failed.csv ' +
          'and left out of the history.', [BatchNo, FFailed]));

      ImportRange(Idx, BatchEnd);
      if Cancelled then Break;
      for I := Idx to BatchEnd - 1 do
      begin
        FLedger.AddOrSetValue(Format('%d|%s', [FSorted[I].FileID, FSorted[I].Revision]), True);
        FLedgerNew.Add(Format('%d,%s', [FSorted[I].FileID, CsvQ(FSorted[I].Revision)]));
      end;
      SaveUpdateCheckpoint;
      Idx := BatchEnd;
      Progress('Adding new check-ins', Idx, Total);
      Overall(Idx, Total);
    end;
  finally
    MergeSaveCsv('skipped.csv', 'file_id,tc_path,revision,reason', FSkippedRows);
    MergeSaveCsv('failed.csv', 'file_id,tc_path,revision,reason', FFailedRows);
    THeartbeatThread(FHeartbeat).Terminate;
    THeartbeatThread(FHeartbeat).WaitFor;
    FHeartbeat.Free;
    FHeartbeat := nil;
  end;

  if FStoppedIncomplete then
    raise Exception.CreateFmt('Stopped after %d of %d new revisions: the connection dropped. ' +
      'Nothing was recorded for the incomplete batch; run again to continue.', [Idx, Total]);
  if Cancelled then
    Log(Format('Stopped after %d of %d new revisions. Run again to continue.', [Idx, Total]))
  else
    Log(Format('Added %d revision(s) from Team Coherence.', [Total]));
end;

// ---------------------------------------------------------------- release branches
//
// One branch per version label, release/<label>, for fixing a released version in git and
// carrying the fix forward: commit it on the oldest release it applies to, then merge each
// release branch into the next.
//
// A label commit is a whole snapshot. Merged as it is, release/v5 into release/v6 would carry
// every difference between the two snapshots, putting v5's files into v6. So each branch after
// the first records, once, that it already includes the one before - a merge that changes no
// file. After that a merge forward brings only what was committed on the older branch since.
//
// The branches belong to the people fixing releases; tc2git only starts them and keeps them
// in step with Team Coherence, and never forces one:
//   - a new label gets its branch, recorded as including the previous release
//   - a label re-applied in TC moves its branch forward with one commit holding the label's
//     new tree - but only while nobody has committed to that branch in git. Otherwise the
//     branch is left alone and listed in meta\release_behind.csv for a person to reconcile.
//   - what TC changes is never merged forward: each label's own re-application is what
//     carries a TC fix to that version, so the next branch records it as included.
// meta\release_branches.csv remembers, per branch, the label commit and the tip tc2git last
// wrote; a tip that differs means someone has committed there.

const
  ReleasePrefix = 'release/';
  ZeroSha = '0000000000000000000000000000000000000000';

function StrCmpLogicalW(psz1, psz2: PWideChar): Integer; stdcall;
  external 'shlwapi.dll' name 'StrCmpLogicalW';

function CompareVersions(const A, B: string): Integer;
// v1.7 < v1.7.01 < v1.8.01 < v4.0.0 < v4.0.0_GA < v4.0.0_HF1 < v4.0.0_HF7 < v4.1.0 < V4.2.0:
// the numbers compared as numbers, then whatever follows them in natural order, none first.
  procedure Split(const S: string; out Nums: TArray<Integer>; out Rest: string);
  var
    I: Integer;
    Head: string;
    Parts: TArray<string>;
  begin
    I := 2;   // after the leading v
    while (I <= Length(S)) and CharInSet(S[I], ['0'..'9', '.']) do Inc(I);
    Head := Copy(S, 2, I - 2);
    while Head.EndsWith('.') do Head := Copy(Head, 1, Length(Head) - 1);
    Rest := Copy(S, I, MaxInt);
    Parts := Head.Split(['.'], TStringSplitOptions.ExcludeEmpty);
    SetLength(Nums, Length(Parts));
    for I := 0 to High(Parts) do Nums[I] := StrToIntDef(Parts[I], 0);
  end;
var
  NA, NB: TArray<Integer>;
  RA, RB: string;
  I: Integer;
begin
  Split(A, NA, RA);
  Split(B, NB, RB);
  for I := 0 to Min(High(NA), High(NB)) do
    if NA[I] <> NB[I] then Exit(NA[I] - NB[I]);
  if Length(NA) <> Length(NB) then Exit(Length(NA) - Length(NB));
  if (RA = '') or (RB = '') then Exit(Ord(RA <> '') - Ord(RB <> ''));
  Result := StrCmpLogicalW(PWideChar(RA), PWideChar(RB));
end;

function TPipeline.ForkPoint(const AtLabel: TDictionary<Cardinal, string>;
  out Cut: Int64): string;
// Where a release's history leaves the branch. Cut is the commit time after which the branch's
// revisions are not in the fork. '' = the release shares no commit with the branch.
//
// Each candidate fork is costed in the file changes the release would not share with the
// branch: the revisions on the label's line still to be replayed after it, plus one for each
// file the branch had already taken off the line by then (the closing "Match label" commit sets
// those). The cheapest fork wins, the later one on a tie. Forking at the FIRST file to leave
// the line instead let one file the release kept at a 2004 revision pull every release's fork
// back to 2005, replaying ten thousand check-ins the branch already had.
//
// The cost follows exactly what History does from a fork: with the fork holding revision C of
// a file, the line's revisions after C are replayed when C is on the line; when it is not, the
// line's revisions from Cut on are replayed and the file is set at the end; a file the fork does
// not hold has its whole line replayed.
type
  TFileCost = record
    Line: TList<string>;     // the file's revisions on the label's line
    Later: Integer;          // how many of them are dated at or after the cut being costed
    Cur: string;             // the branch's newest revision of it before that cut
    Cost: Integer;
  end;
var
  Files: TDictionary<Cardinal, TFileCost>;
  Evs: TList<TTCRevision>;
  Times: TArray<Int64>;      // Evs' times, as the branch's commit times are kept
  Firsts: TDictionary<Cardinal, Int64>;
  Extra: TArray<Int64>;      // when the branch first has each file the label does not hold
  X: Integer;
  R: TTCRevision;
  Fc: TFileCost;
  L: string;
  Id: Cardinal;
  Total, Best, I, J, E, BestI: Integer;
  T, BestCut: Int64;
  Ok: Boolean;

  function CostOf(const F: TFileCost): Integer;
  var
    S: string;
  begin
    if F.Cur = '' then Exit(F.Line.Count);
    if F.Line.IndexOf(F.Cur) >= 0 then
    begin
      Result := 0;
      for S in F.Line do
        if (S <> F.Cur) and RevOnLine(F.Cur, S) then Inc(Result);
    end
    else Result := 1 + F.Later;
  end;

begin
  AttachPoint(0);   // loads the branch's first-parent line
  if Length(FBranchShas) = 0 then
  begin
    Cut := Low(Int64);
    Exit('');
  end;
  Files := TDictionary<Cardinal, TFileCost>.Create;
  Evs := TList<TTCRevision>.Create;
  try
    Total := 0;
    for R in FSession.Revisions do
    begin
      if not AtLabel.TryGetValue(R.FileID, L) then Continue;
      Ok := RevOnLine(R.Revision, L);
      if not Ok and not InMain(R) then Continue;    // touches neither the line nor the branch
      if not Files.TryGetValue(R.FileID, Fc) then
      begin
        Fc.Line := TList<string>.Create;
        Fc.Later := 0;
        Fc.Cur := '';
        Fc.Cost := 0;
      end;
      if Ok then
      begin
        Fc.Line.Add(R.Revision);
        Inc(Fc.Later);
      end;
      Files.AddOrSetValue(R.FileID, Fc);
      Evs.Add(R);
    end;
    // A file the label does not hold that the branch already has at the fork is one more the
    // closing commit removes, so it is costed from the branch's first revision of it. Files no
    // label ever held cost the same at every fork; the term is what keeps a fork from being
    // chosen after years of files the release never had: V6.0.0 forked at the branch's tip
    // without it, and its closing commit removed 2,401 files.
    Firsts := TDictionary<Cardinal, Int64>.Create;
    try
      for R in FSession.Revisions do
        if not AtLabel.ContainsKey(R.FileID) and InMain(R) then
        begin
          T := DateTimeToUnix(R.When, True);
          if not Firsts.TryGetValue(R.FileID, BestCut) or (T < BestCut) then
            Firsts.AddOrSetValue(R.FileID, T);
        end;
      Extra := Firsts.Values.ToArray;
    finally
      Firsts.Free;
    end;
    TArray.Sort<Int64>(Extra);
    X := 0;
    for Fc in Files.Values do Inc(Total, Fc.Line.Count);   // nothing forked: all replayed
    Evs.Sort(TComparer<TTCRevision>.Construct(
      function(const A, B: TTCRevision): Integer
      begin
        Result := CompareDateTime(A.When, B.When);
      end));
    for Id in Files.Keys.ToArray do   // each file starts at its whole line, as Total does
    begin
      Fc := Files[Id];
      Fc.Cost := Fc.Line.Count;
      Files[Id] := Fc;
    end;

    // the root ('' fork) costs Total; then each commit from the oldest, then the tip
    Best := Total;
    BestI := Length(FBranchShas);       // = no shared commit
    BestCut := Low(Int64);
    SetLength(Times, Evs.Count);
    for E := 0 to Evs.Count - 1 do Times[E] := DateTimeToUnix(Evs[E].When, True);
    E := 0;
    GStage := GStage + Format(' (%d revision(s), %d commit(s))', [Evs.Count, Length(FBranchShas)]);
    for I := High(FBranchShas) downto -1 do
    begin
      // fork = FBranchShas[I+1] holds everything dated before FBranchTimes[I]; I = -1 is the tip
      if I >= 0 then T := FBranchTimes[I] else T := High(Int64);
      if I + 1 > High(FBranchShas) then Continue;   // the root is costed above
      // the bound is tested on its own: written as one "(E < Count) and (Evs[E]...)" condition
      // it read Evs[Count] here, though the same loop over a list of a smaller record does not
      while E < Evs.Count do
      begin
        if Times[E] >= T then Break;
        R := Evs[E];
        Inc(E);
        Fc := Files[R.FileID];
        if Fc.Line.IndexOf(R.Revision) >= 0 then Dec(Fc.Later);
        if InMain(R) then Fc.Cur := R.Revision;
        J := CostOf(Fc);
        Inc(Total, J - Fc.Cost);
        Fc.Cost := J;
        Files[R.FileID] := Fc;
      end;
      while (X < Length(Extra)) and (Extra[X] < T) do
      begin
        Inc(Total);
        Inc(X);
      end;
      if Total <= Best then
      begin
        Best := Total;
        BestI := I + 1;
        BestCut := T;
      end;
    end;
    Cut := BestCut;
    if BestI > High(FBranchShas) then Result := '' else Result := FBranchShas[BestI];
  finally
    for Fc in Files.Values do Fc.Line.Free;
    Files.Free;
    Evs.Free;
  end;
end;

function TPipeline.ReplayRevisions(const Base: string; Revs: TArray<TTCRevision>;
  out Commits: Integer): string;
// Commits Revs, oldest first and grouped into check-ins exactly as the branch's are, on top of
// Base ('' = a new root). Written through a scratch ref, so nothing visible moves until the
// caller moves a branch to the result. Returns the last commit, or Base when nothing changed.
const
  Scratch = 'refs/tc2git/replay';
var
  GitProc: TProcessInformation;
  GitIn: THandle;
  FS: TStream;
  Marks: TDictionary<string, Integer>;
  Index: TObjectDictionary<string, TList<Integer>>;
  Pending: TList<TChange>;
  Holds: TDictionary<string, string>;      // path -> sha this replay last wrote there
  GroupFiles: TDictionary<Cardinal, Boolean>;
  Shas: TStringList;
  Lst: TList<Integer>;
  Chg: TChange;
  Rev: TTCRevision;
  GroupAuthor, GroupComment, Msg, Out1, Was: string;
  GroupStart: TDateTime;
  N, Mark: Integer;
  First: Boolean;

  procedure Flush;
  var
    K: Integer;
  begin
    if Pending.Count = 0 then Exit;
    Inc(Commits);
    Msg := GroupComment;
    if Trim(Msg) = '' then Msg := '(no check-in comment)';
    PutLine(FS, 'commit ' + Scratch);
    PutLine(FS, Format('committer %s %s', [MapAuthor(GroupAuthor), GitStamp(GroupStart)]));
    PutLine(FS, 'data ' + IntToStr(Length(TEncoding.UTF8.GetBytes(Msg))));
    PutLine(FS, Msg);
    if First and (Base <> '') then PutLine(FS, 'from ' + Base);
    First := False;
    for K := 0 to Pending.Count - 1 do
      PutLine(FS, Format('M 100644 :%d %s', [Pending[K].Mark, Pending[K].Path]));
    Pending.Clear;
  end;

begin
  Commits := 0;
  Result := Base;
  if Length(Revs) = 0 then Exit;
  SortChronologically(Revs);
  Marks := TDictionary<string, Integer>.Create;
  Index := BlobIndex;
  Pending := TList<TChange>.Create;
  Holds := TDictionary<string, string>.Create;
  GroupFiles := TDictionary<Cardinal, Boolean>.Create;
  Shas := TStringList.Create;
  try
    for Rev in Revs do
      if Index.TryGetValue(Format('%d|%s', [Rev.FileID, Rev.Revision]), Lst) then
        for N in Lst do Shas.Add(FBlobs[N].Sha);
    PrepareFiltered(Shas.ToStringArray);
    GitOut('update-ref -d ' + Scratch, Out1);

    GitIn := 0;
    if not StartFastImport(GitProc, GitIn, True) then
      raise Exception.Create('Could not start git fast-import for a release branch.');
    FS := THandleStream.Create(GitIn);
    try
      Mark := 0;
      First := True;
      GroupAuthor := #0;
      GroupComment := #0;
      GroupStart := 0;
      for Rev in Revs do
      begin
        if Cancelled then Break;
        // the same boundaries as ImportRange, including a new commit when a file repeats
        if (Rev.Author <> GroupAuthor) or (Rev.Comment <> GroupComment) or
           ((FOpt.WindowSeconds > 0) and
            (SecondsBetween(Rev.When, GroupStart) > FOpt.WindowSeconds)) or
           GroupFiles.ContainsKey(Rev.FileID) then
        begin
          Flush;
          GroupFiles.Clear;
          GroupAuthor := Rev.Author;
          GroupComment := Rev.Comment;
          GroupStart := Rev.When;
        end;
        GroupFiles.AddOrSetValue(Rev.FileID, True);
        if not Index.TryGetValue(Format('%d|%s', [Rev.FileID, Rev.Revision]), Lst) then Continue;
        for N in Lst do
        begin
          Chg.Path := MemberPath(Rev.TCPath, FBlobs[N].Member);
          Chg.Sha := FBlobs[N].Sha;
          if Holds.TryGetValue(Chg.Path, Was) and (Was = Chg.Sha) then Continue;
          if not EmitBlob(FS, FBlobs[N], Chg.Path, Marks, Mark, Chg.Mark) then Continue;
          Holds.AddOrSetValue(Chg.Path, Chg.Sha);
          Pending.Add(Chg);
        end;
      end;
      Flush;
    finally
      FS.Free;
    end;
    if FinishFastImport(GitProc, GitIn, Out1) <> 0 then
    begin
      Log('git fast-import FAILED on a release branch:');
      Log(Out1);
      raise Exception.Create('git fast-import failed while building a release branch.');
    end;
    if Commits > 0 then
    begin
      Result := RefSha(Scratch);
      if Result = '' then raise Exception.Create('The replayed history was not written.');
    end;
    GitOut('update-ref -d ' + Scratch, Out1);
  finally
    Shas.Free;
    GroupFiles.Free;
    Holds.Free;
    Pending.Free;
    Index.Free;
    Marks.Free;
  end;
end;

procedure TPipeline.UpdateReleaseBranches;
type
  TRel = record
    Name, Branch, Tag, Tip, StateTag, StateTip: string;
    Managed, Rebuilt: Boolean;
  end;
var
  Out1, Line, Remote, New, Msg, Was: string;
  Seen: TDictionary<string, string>;   // branch -> its remote-tracking sha before this fetch
  Names: TList<string>;
  Rels: TArray<TRel>;
  State: TDictionary<string, TArray<string>>;
  Diverged: TDictionary<string, Boolean>;
  Behind, Rows: TStringList;
  Parts: TArray<string>;
  Skips: TArray<string>;
  Mask: string;
  I, Prev, Created, Advanced, Recorded, Rebuilt, N: Integer;
  Skip: Boolean;
  Id: TArray<string>;
  LabelIds: TDictionary<string, Cardinal>;    // tag name -> the TC version label it was made from
  Lb: TTCLabel;
  AtLabel, Cur: TDictionary<Cardinal, string>;

  function StatePathRel: string;
  begin
    Result := TPath.Combine(FOpt.MetaDir, 'release_branches.csv');
  end;

  procedure MoveBranch(var R: TRel; const NewTip: string; Owned: Boolean);
  var
    O: string;
  begin
    if GitOut(Format('update-ref refs/heads/%s %s %s', [R.Branch, NewTip,
              IfThen(R.Tip = '', ZeroSha, R.Tip)]), O) <> 0 then
      raise Exception.Create('Could not move ' + R.Branch + ': ' + Trim(O));
    R.Tip := NewTip;
    if Owned then R.StateTip := NewTip;
  end;

  // identity and date of a label commit, for the commits made on its branch
  function LabelIdent(const Commit: string): TArray<string>;
  var
    O: string;
  begin
    Result := nil;
    if GitOut('log -1 --date=raw --format=%cn%x09%ce%x09%cd ' + Commit, O) = 0 then
      Result := Trim(O).Split([#9]);
    if Length(Result) <> 3 then
      raise Exception.Create('Cannot read the label commit ' + Commit);
  end;

  // file id -> the revision a label holds of it
  function AttachMap(ID: Cardinal; const Att: TArray<TTCAttachment>): TDictionary<Cardinal, string>;
  var
    A: TTCAttachment;
  begin
    Result := TDictionary<Cardinal, string>.Create;
    for A in Att do
      if A.LabelID = ID then Result.AddOrSetValue(A.FileID, A.Revision);
  end;

  // Replays, on Base, the check-ins on the label's line that come after what Base holds of each
  // file - Cur, a file's revision in Base. A file Base holds off the line gets the revisions
  // from Cut on; with NewFilesFull a file Base lacks gets its whole line. Then, when the result
  // is not exactly the label, one commit makes it so: it drops files the label does not hold
  // and sets any whose revisions could not all be replayed. With no AtLabel, only that commit.
  function History(const R: TRel; const Base: string; Cur, AtLabel: TDictionary<Cardinal, string>;
    Cut: Int64; NewFilesFull: Boolean; out Commits: Integer): string;
  const
    MaxListed = 500;
  var
    Revs: TList<TTCRevision>;
    Rv: TTCRevision;
    L, C, Tip, TagTree, O, Ln: string;
    Id: TArray<string>;
    Removed, I: Integer;
    Sets: TStringList;
  begin
    Commits := 0;
    Tip := Base;
    if AtLabel <> nil then
    begin
      Revs := TList<TTCRevision>.Create;
      try
        for Rv in FSession.Revisions do
        begin
          if not AtLabel.TryGetValue(Rv.FileID, L) or not RevOnLine(Rv.Revision, L) then Continue;
          if Cur.TryGetValue(Rv.FileID, C) then
          begin
            if RevOnLine(C, L) then
            begin
              if (Rv.Revision = C) or not RevOnLine(C, Rv.Revision) then Continue;
            end
            else if DateTimeToUnix(Rv.When, True) < Cut then Continue;
          end
          else if not NewFilesFull then Continue;
          Revs.Add(Rv);
        end;
        GStage := Format('%s: replaying %d revision(s)', [R.Branch, Revs.Count]);
        Tip := ReplayRevisions(Base, Revs.ToArray, Commits);
        GStage := R.Branch + ': the closing commit';
      finally
        Revs.Free;
      end;
    end;
    TagTree := TreeOf(R.Tag);
    if (Tip <> '') and (TreeOf(Tip) = TagTree) then Exit(Tip);
    Id := LabelIdent(R.Tag);
    // The files set are listed: they are what this release does not have of the branch's work
    // (or a revision that could not be replayed), which is what someone reading the branch needs
    // to see. Removals are only counted - they run to thousands, of files added after it.
    Removed := 0;
    Sets := TStringList.Create;
    try
      if (Tip <> '') and (GitOut(Format('diff-tree -r --no-renames --name-status %s %s',
                          [Tip, R.Tag]), O) = 0) then
        for Ln in O.Split([#10], TStringSplitOptions.ExcludeEmpty) do
          if Ln.StartsWith('D') then Inc(Removed)
          else if Pos(#9, Ln) > 0 then Sets.Add(Copy(Ln, Pos(#9, Ln) + 1, MaxInt));
      O := Format('Match label %s as Team Coherence has it'#10#10, [R.Name]);
      if Removed > 0 then
        O := O + Format('%d file(s) removed that label %s does not hold.'#10, [Removed, R.Name]);
      if Sets.Count > 0 then
      begin
        O := O + Format('%d file(s) set to the revision label %s holds - work the branch has ' +
          'that this release does not, or a check-in that could not be replayed here:'#10#10,
          [Sets.Count, R.Name]);
        for I := 0 to Min(Sets.Count, MaxListed) - 1 do O := O + '  ' + Sets[I] + #10;
        if Sets.Count > MaxListed then
          O := O + Format('  ... and %d more'#10, [Sets.Count - MaxListed]);
      end;
    finally
      Sets.Free;
    end;
    if Tip = '' then Result := CommitTree(TagTree, [], O, 'tc2git', 'tc2git@localhost', Id[2])
    else Result := CommitTree(TagTree, [Tip], O, 'tc2git', 'tc2git@localhost', Id[2]);
  end;

  // A release built from where it leaves the branch: the branch's history up to there, then
  // every check-in on the label's line that the branch does not have.
  function FromFork(const R: TRel; LabelID: Cardinal; out Commits: Integer): string;
  var
    AtLabel, Cur: TDictionary<Cardinal, string>;
    Newest: TDictionary<Cardinal, TTCRevision>;
    Rv, Was: TTCRevision;
    Fork: string;
    Cut: Int64;
  begin
    AtLabel := AttachMap(LabelID, FSession.Attachments.ToArray);
    Cur := TDictionary<Cardinal, string>.Create;
    Newest := TDictionary<Cardinal, TTCRevision>.Create;
    try
      GStage := R.Branch + ': choosing the fork';
      Fork := ForkPoint(AtLabel, Cut);
      GStage := R.Branch + ': what the fork holds';
      // what the fork holds of each of the label's files: the branch's newest revision before Cut
      for Rv in FSession.Revisions do
        if AtLabel.ContainsKey(Rv.FileID) and InMain(Rv) and
           (DateTimeToUnix(Rv.When, True) < Cut) then
          if not Newest.TryGetValue(Rv.FileID, Was) or (CompareDateTime(Rv.When, Was.When) > 0) then
            Newest.AddOrSetValue(Rv.FileID, Rv);
      for Rv in Newest.Values do Cur.AddOrSetValue(Rv.FileID, Rv.Revision);
      Result := History(R, Fork, Cur, AtLabel, Cut, True, Commits);
    finally
      Newest.Free;
      Cur.Free;
      AtLabel.Free;
    end;
  end;

begin
  if not FOpt.IncludeTags then
    raise EUpdateRefused.Create('Release branches are built from the version labels: they ' +
      'need --tags as well.');
  FReleasePush.Clear;
  EnsureMainLine;   // which revisions the branch holds decides where each release leaves it
  Skips := FOpt.ReleaseSkip.Split([';'], TStringSplitOptions.ExcludeEmpty);

  // ---- which labels get a branch, oldest version first --------------------------------
  LabelIds := TDictionary<string, Cardinal>.Create;
  Names := TList<string>.Create;
  State := TDictionary<string, TArray<string>>.Create;
  Diverged := TDictionary<string, Boolean>.Create;
  Seen := TDictionary<string, string>.Create;
  Behind := TStringList.Create;
  Rows := TStringList.Create;
  try
    if GitOut('for-each-ref --format=%(refname:short) refs/tags/', Out1) <> 0 then
      raise Exception.Create('Could not list the tags: ' + Trim(Out1));
    for Line in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
    begin
      if not TRegEx.IsMatch(Trim(Line), '^[vV][0-9]') then Continue;   // not a version
      Skip := False;
      for Mask in Skips do
        if MatchesMask(Trim(Line), Mask) then Skip := True;
      if not Skip then Names.Add(Trim(Line));
    end;
    Names.Sort(TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := CompareVersions(A, B);
        if Result = 0 then Result := CompareStr(A, B);
      end));
    if Names.Count = 0 then
    begin
      Log('No version labels to make release branches from.');
      Exit;
    end;

    if TFile.Exists(StatePathRel) then
      for Line in TFile.ReadAllLines(StatePathRel, TEncoding.UTF8) do
      begin
        Parts := Line.Trim([#$FEFF, ' ', #9]).Split([',']);
        if (Length(Parts) = 3) and (Length(Parts[1]) = 40) then
          State.AddOrSetValue(Parts[0], [Parts[1], Parts[2]]);
      end;

    // ---- what people pushed: fixes are committed on the remote, not here -----------------
    EnsureRemote;
    if RemoteExists then
    begin
      // where each branch stood on the remote when this repository last fetched or pushed it
      if GitOut(Format('for-each-ref --format=%%(refname):%%(objectname) refs/remotes/%s/%s',
                [FOpt.Remote, ReleasePrefix]), Out1) = 0 then
        for Line in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
        begin
          Parts := Trim(Line).Split([':']);   // ':' cannot be in a ref name; a space splits the argument
          if Length(Parts) = 2 then
            Seen.AddOrSetValue(Copy(Parts[0], Length('refs/remotes/' + FOpt.Remote + '/') + 1,
              MaxInt), Parts[1]);
        end;
      Log(Format('Fetching %s* from %s...', [ReleasePrefix, FOpt.Remote]));
      if GitOut(Format('fetch --no-tags %s +refs/heads/%s*:refs/remotes/%s/%s*',
                [FOpt.Remote, ReleasePrefix, FOpt.Remote, ReleasePrefix]), Out1, 3600) <> 0 then
        raise Exception.Create('git fetch of the release branches failed: ' +
          Copy(Trim(Out1), 1, 300));
    end;

    SetLength(Rels, Names.Count);
    for I := 0 to Names.Count - 1 do
    begin
      Rels[I].Name := Names[I];
      Rels[I].Branch := ReleasePrefix + Names[I];
      Rels[I].Tag := RefSha('refs/tags/' + Names[I]);
      Rels[I].Tip := RefSha('refs/heads/' + Rels[I].Branch);
      Rels[I].Managed := True;
      Rels[I].Rebuilt := False;
      if State.ContainsKey(Names[I]) then
      begin
        Rels[I].StateTag := State[Names[I]][0];
        Rels[I].StateTip := State[Names[I]][1];
      end;
      if RemoteExists then
      begin
        Remote := RefSha(Format('refs/remotes/%s/%s', [FOpt.Remote, Rels[I].Branch]));
        if (Remote <> '') and (Remote <> Rels[I].Tip) then
          if (Rels[I].Tip = '') or IsAncestor(Rels[I].Tip, Remote) then
          begin
            MoveBranch(Rels[I], Remote, False);   // someone's commits: theirs, not ours
            Log(Format('  %s: brought up to %s from %s', [Rels[I].Branch, Copy(Remote, 1, 8),
              FOpt.Remote]));
          end
          else if not IsAncestor(Remote, Rels[I].Tip) and Seen.TryGetValue(Rels[I].Branch, Was) and
                  (Was = Remote) and (Rels[I].Tip = Rels[I].StateTip) then
          begin
            // tc2git rewrote it here (a rebuild) and that never reached the remote, which has
            // not moved since: nobody else's work is in the way, so it is pushed with a lease
            Rels[I].Rebuilt := True;
            Log(Format('  %s: rewritten here by tc2git and not yet pushed; %s has not moved ' +
              'since, so the push replaces it', [Rels[I].Branch, FOpt.Remote]));
          end
          else if not IsAncestor(Remote, Rels[I].Tip) then
          begin
            Log(Format('*** %s here and on %s have both changed; it is left alone this run. ' +
              'Reconcile them by hand.', [Rels[I].Branch, FOpt.Remote]));
            Rels[I].Managed := False;
            Diverged.Add(Rels[I].Name, True);
          end;
      end;
    end;

    // ---- each branch exists and holds its label --------------------------------------------
    Created := 0;
    Advanced := 0;
    Rebuilt := 0;
    for Lb in FSession.Labels do
      if (Lb.LabelType = 1) and not LabelIds.ContainsKey(SanitiseRefName(Lb.Name)) then
        LabelIds.Add(SanitiseRefName(Lb.Name), Lb.ID);
    for I := 0 to High(Rels) do
    begin
      if not Rels[I].Managed then Continue;
      // --rebuild-release-branches: a branch tc2git owns is built again from TC's history. One
      // somebody has committed to is theirs, and is left as it is.
      if FOpt.RebuildReleaseBranches and (Rels[I].Tip <> '') and LabelIds.ContainsKey(Rels[I].Name) then
      begin
        if (Rels[I].StateTip <> '') and (Rels[I].Tip <> Rels[I].StateTip) then
          Log(Format('*** %s has commits made in git; not rebuilt.', [Rels[I].Branch]))
        else
        begin
          New := FromFork(Rels[I], LabelIds[Rels[I].Name], N);
          MoveBranch(Rels[I], New, True);
          Rels[I].StateTag := Rels[I].Tag;
          Rels[I].Rebuilt := True;
          Inc(Rebuilt);
          Log(Format('  %s rebuilt: %d check-in(s) made under its view', [Rels[I].Branch, N]));
        end;
        Continue;
      end;
      if Rels[I].Tip = '' then
      begin
        if LabelIds.ContainsKey(Rels[I].Name) then
        begin
          New := FromFork(Rels[I], LabelIds[Rels[I].Name], N);
          MoveBranch(Rels[I], New, True);
          Log(Format('  %s created: %d check-in(s) made under its view', [Rels[I].Branch, N]));
        end
        else
        begin
          MoveBranch(Rels[I], Rels[I].Tag, True);   // a tag with no label left: its snapshot
          Log(Format('  %s created from %s', [Rels[I].Branch, Rels[I].Name]));
        end;
        Rels[I].StateTag := Rels[I].Tag;
        Inc(Created);
      end
      else if Rels[I].StateTip = '' then
      begin
        // a branch tc2git did not make: taken on only if it holds exactly the label
        if TreeOf(Rels[I].Tip) = TreeOf(Rels[I].Tag) then
        begin
          Rels[I].StateTag := Rels[I].Tag;
          Rels[I].StateTip := Rels[I].Tip;
          Log(Format('  %s already holds %s; kept up to date from now on',
            [Rels[I].Branch, Rels[I].Name]));
        end
        else
        begin
          Log(Format('*** %s exists but does not hold label %s, and tc2git did not make it. ' +
            'Left alone.', [Rels[I].Branch, Rels[I].Name]));
          Rels[I].Managed := False;
        end;
      end
      else if TreeOf(Rels[I].Tag) <> TreeOf(Rels[I].StateTip) then
      begin
        // the label's files changed in TC since tc2git last wrote this branch
        if TreeOf(Rels[I].Tip) = TreeOf(Rels[I].Tag) then
        begin
          Rels[I].StateTag := Rels[I].Tag;   // someone already brought them in
          Rels[I].StateTip := Rels[I].Tip;
        end
        else if Rels[I].Tip = Rels[I].StateTip then
        begin
          // the check-ins made under its view since, then whatever else the label changed
          N := 0;
          if LabelIds.ContainsKey(Rels[I].Name) then
          begin
            AtLabel := AttachMap(LabelIds[Rels[I].Name], FSession.Attachments.ToArray);
            Cur := AttachMap(LabelIds[Rels[I].Name], FOldAttach);
            try
              New := History(Rels[I], Rels[I].Tip, Cur, AtLabel, High(Int64), False, N);
            finally
              Cur.Free;
              AtLabel.Free;
            end;
          end
          else
            New := History(Rels[I], Rels[I].Tip, nil, nil, High(Int64), False, N);
          MoveBranch(Rels[I], New, True);
          Rels[I].StateTag := Rels[I].Tag;
          Inc(Advanced);
          Log(Format('  %s moved forward: label %s changed in TC (%d check-in(s) under its view)',
            [Rels[I].Branch, Rels[I].Name, N]));
        end
        else
        begin
          Log(Format('*** label %s was re-applied in TC, but %s has commits made in git ' +
            'since. Not changed: bring the label''s changes in by hand (git diff %s %s).',
            [Rels[I].Name, Rels[I].Branch, Rels[I].StateTip, Rels[I].Tag]));
          Behind.Add(Format('%s,%s,%s,%s', [Rels[I].Branch, Rels[I].Tip, Rels[I].StateTip,
            Rels[I].Tag]));
        end;
      end
      else
        Rels[I].StateTag := Rels[I].Tag;   // same files; the tag may have been re-attached
    end;

    // ---- each branch records the one before as included ------------------------------------
    GStage := 'recording which release includes which';
    Recorded := 0;
    Prev := -1;
    for I := 0 to High(Rels) do
    begin
      if not Rels[I].Managed then Continue;
      if (Prev >= 0) and not IsAncestor(Rels[Prev].StateTip, Rels[I].Tip) then
      begin
        Id := LabelIdent(Rels[I].Tag);
        Msg := Format('Record that %s already includes %s'#10#10 +
          'No files change. Later fixes merged from %s bring only themselves, not the %s ' +
          'snapshot.'#10, [Rels[I].Name, Rels[Prev].Name, Rels[Prev].Branch, Rels[Prev].Name]);
        New := CommitTree(TreeOf(Rels[I].Tip), [Rels[I].Tip, Rels[Prev].StateTip], Msg,
          'tc2git', 'tc2git@localhost', Id[2]);
        // a branch someone has committed to stays theirs: the record does not vouch for it
        MoveBranch(Rels[I], New, Rels[I].Tip = Rels[I].StateTip);
        Inc(Recorded);
      end;
      Prev := I;
    end;

    // ---- remember, report ---------------------------------------------------------------------
    GStage := '';
    for I := 0 to High(Rels) do
      if Rels[I].Managed then
      begin
        Rows.Add(Format('%s,%s,%s', [Rels[I].Name, Rels[I].StateTag, Rels[I].StateTip]));
        FReleasePush.AddObject(Rels[I].Branch, TObject(NativeUInt(Ord(Rels[I].Rebuilt))));
      end
      else if State.ContainsKey(Rels[I].Name) then
        Rows.Add(Format('%s,%s,%s', [Rels[I].Name, State[Rels[I].Name][0],
          State[Rels[I].Name][1]]));
    // no BOM: it would become part of the first label's name when read back
    TFile.WriteAllBytes(StatePathRel, TEncoding.UTF8.GetBytes(
      string.Join(#13#10, Rows.ToStringArray) + #13#10));
    if Behind.Count > 0 then
    begin
      Behind.Insert(0, 'branch,tip,tc2git_last_tip,label_commit');
      Behind.SaveToFile(TPath.Combine(FOpt.MetaDir, 'release_behind.csv'), TEncoding.UTF8);
    end
    else if TFile.Exists(TPath.Combine(FOpt.MetaDir, 'release_behind.csv')) then
      TFile.Delete(TPath.Combine(FOpt.MetaDir, 'release_behind.csv'));

    // a release branch whose label is gone is somebody's decision, like a tag
    if GitOut(Format('for-each-ref --format=%%(refname:short) refs/heads/%s', [ReleasePrefix]),
              Out1) = 0 then
      for Line in Out1.Split([#10], TStringSplitOptions.ExcludeEmpty) do
        if not Names.Contains(Copy(Trim(Line), Length(ReleasePrefix) + 1, MaxInt)) then
          Log(Format('  %s matches no version label here and was left in place', [Trim(Line)]));

    Log(Format('Release branches: %d, of which %d new, %d rebuilt, %d moved forward from TC, ' +
      '%d inclusion record(s) added; %d left alone.', [FReleasePush.Count, Created, Rebuilt,
      Advanced, Recorded, Length(Rels) - FReleasePush.Count]));
  finally
    LabelIds.Free;
    Rows.Free;
    Behind.Free;
    Diverged.Free;
    Seen.Free;
    State.Free;
    Names.Free;
  end;
end;

// ---------------------------------------------------------------- remote

procedure TPipeline.EnsureRemote;
// --remote-url: add the remote when it is missing, refuse when it points somewhere else.
var
  Out1: string;
begin
  if (FOpt.RemoteUrl = '') or (FOpt.Remote = '') then Exit;
  if RemoteExists then
  begin
    GitOut('remote get-url ' + FOpt.Remote, Out1);
    if not SameText(Trim(Out1), FOpt.RemoteUrl) then
      raise EUpdateRefused.CreateFmt('Remote "%s" is %s, not %s. Change it yourself if that ' +
        'is intended: git -C "%s" remote set-url %s <url>',
        [FOpt.Remote, Trim(Out1), FOpt.RemoteUrl, FOpt.RepoDir, FOpt.Remote]);
  end
  else
  begin
    if GitOut(Format('remote add %s %s', [FOpt.Remote, FOpt.RemoteUrl]), Out1) <> 0 then
      raise Exception.Create('Could not add the remote: ' + Trim(Out1));
    Log(Format('Remote "%s" added: %s', [FOpt.Remote, FOpt.RemoteUrl]));
  end;
end;

procedure TPipeline.PushBranchInSteps(const Branch: string);
// GitHub refuses a push over 2 GB - after uploading it all, with a bare HTTP 500 - and a
// repository's whole history can be more than that. So a branch far ahead of the remote goes
// up in steps along its first-parent line, the remote branch moving forward with each; a step
// that is refused is retried at half the size. Never forced.
const
  StepCommits = 2000;
var
  Out1, Remote, Range: string;
  Commits: TArray<string>;
  Done, Target, Step: Integer;
begin
  Remote := '';
  if GitOut(Format('ls-remote --heads %s refs/heads/%s', [FOpt.Remote, Branch]), Out1, 600) = 0 then
    Remote := Copy(Trim(Out1), 1, 40);
  Range := 'refs/heads/' + Branch;
  if (Remote <> '') and (RefSha(Remote) <> '') then Range := Range + ' ^' + Remote;
  if GitOut('rev-list --reverse --first-parent ' + Range, Out1, 600) <> 0 then
    raise Exception.Create('Could not list the commits to push: ' + Trim(Out1));
  Commits := Trim(Out1).Split([#10], TStringSplitOptions.ExcludeEmpty);
  Done := -1;
  Step := StepCommits;
  while Done < High(Commits) - StepCommits do
  begin
    Target := Min(Done + Step, High(Commits));
    Log(Format('  %s: up to commit %d of %d', [Branch, Target + 1, Length(Commits)]));
    if GitOut(Format('push --porcelain %s %s:refs/heads/%s',
              [FOpt.Remote, Trim(Commits[Target]), Branch]), Out1, 6 * 3600) = 0 then
    begin
      Done := Target;
      Step := StepCommits;
    end
    else if Step > 50 then
    begin
      Step := Step div 2;
      Log(Format('  refused (%s); retrying %d commits at a time',
        [Copy(Trim(Out1), 1, 120), Step]));
    end
    else
      raise Exception.Create('git push of the branch failed:'#13#10 + Trim(Out1));
  end;
  if GitOut(Format('push --porcelain %s refs/heads/%s:refs/heads/%s',
            [FOpt.Remote, Branch, Branch]), Out1, 6 * 3600) <> 0 then
    raise Exception.Create('git push of the branch failed:'#13#10 + Trim(Out1));
end;

procedure TPipeline.PushLfsObjects;
// The first push to a remote URL uploads every LFS object the history references (lfs push
// --all), which reads every commit - minutes on a long history even when nothing is missing.
// After that, meta\lfs_pushed.<remote>.txt holds the URL it went to, and a push uploads only
// the objects stored since, which meta\lfs_pending.txt lists as they are written. A remote whose
// URL has changed gets a full push again; deleting the marker file forces one.
const
  Chunk = 100;   // object ids per command line: 65 characters each, well inside the limit
var
  Marker, PendFile, Url, Out1, Args, Line: string;
  Pending: TStringList;
  I: Integer;
begin
  PendFile := TPath.Combine(FOpt.MetaDir, 'lfs_pending.txt');
  Marker := TPath.Combine(FOpt.MetaDir, 'lfs_pushed.' + FOpt.Remote + '.txt');
  if GitOut(Format('remote get-url %s', [FOpt.Remote]), Url) <> 0 then
    raise Exception.Create('git remote get-url failed:'#13#10 + Trim(Url));
  Url := Trim(Url);
  if not (TFile.Exists(Marker) and SameText(Trim(TFile.ReadAllText(Marker)), Url)) then
  begin
    // Not pushed to this URL by this version yet: everything, once, if the history uses LFS.
    if Length(FLfsPatterns) > 0 then
    begin
      Log(Format('Uploading all LFS objects to %s (first push to this URL)...', [FOpt.Remote]));
      if GitOut(Format('lfs push --all %s', [FOpt.Remote]), Out1, 6 * 3600) <> 0 then
        raise Exception.Create('git lfs push failed:'#13#10 + Trim(Out1));
    end;
  end
  else if TFile.Exists(PendFile) then
  begin
    Pending := TStringList.Create;
    try
      Pending.Sorted := True;
      Pending.Duplicates := dupIgnore;
      for Line in TFile.ReadAllLines(PendFile) do
        if Trim(Line) <> '' then Pending.Add(Trim(Line));
      Log(Format('Uploading %d new LFS object(s) to %s...', [Pending.Count, FOpt.Remote]));
      I := 0;
      while I < Pending.Count do
      begin
        Args := '';
        while (I < Pending.Count) and (Length(Args) < Chunk * 65) do
        begin
          Args := Args + ' ' + Pending[I];
          Inc(I);
        end;
        if GitOut(Format('lfs push --object-id %s%s', [FOpt.Remote, Args]), Out1,
                  6 * 3600) <> 0 then
          raise Exception.Create('git lfs push failed:'#13#10 + Trim(Out1));
      end;
    finally
      Pending.Free;
    end;
  end
  else
    Log('No new LFS objects to upload.');
  // Only once every upload above has succeeded: a failure leaves the list for the next push.
  if TFile.Exists(PendFile) then TFile.Delete(PendFile);
  TFile.WriteAllText(Marker, Url, TEncoding.ASCII);
end;

procedure TPipeline.PushToRemote;
// The branch is pushed WITHOUT force: the update checked the remote is at or behind this
// repository, so a rejection means someone pushed in the meantime - a reason to stop, never to
// overwrite. Tags are pushed with force, because a label re-applied in TC moves its tag. Release
// branches only ever move forward, so they are pushed without force too - except one
// --rebuild-release-branches has just rebuilt.
var
  Out1, Refs, Lease: string;
  B: string;
  I: Integer;
begin
  SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0');
  EnsureRemote;
  if not RemoteExists then
    raise EUpdateRefused.CreateFmt('There is no remote "%s" to push to. Add it once with: ' +
      'git -C "%s" remote add %s <url>', [FOpt.Remote, FOpt.RepoDir, FOpt.Remote]);
  // LFS content first: a bare repository has no hook to upload it, and a pushed pointer whose
  // object never arrived is a file nobody can check out.
  PushLfsObjects;
  Log(Format('Pushing %s to %s...', [FOpt.Branch, FOpt.Remote]));
  PushBranchInSteps(FOpt.Branch);
  if FOpt.IncludeTags then
  begin
    Log(Format('Pushing tags to %s...', [FOpt.Remote]));
    if GitOut(Format('push --porcelain %s +refs/tags/*:refs/tags/*', [FOpt.Remote]),
              Out1, 6 * 3600) <> 0 then
      raise Exception.Create('git push of the tags failed:'#13#10 + Trim(Out1));
  end;
  if FOpt.ReleaseBranches and (FReleasePush.Count > 0) then
  begin
    Log(Format('Pushing %d release branch(es) to %s...', [FReleasePush.Count, FOpt.Remote]));
    Refs := '';
    Lease := '';
    // A rebuilt branch replaces what is published, so it goes with force - but only over what
    // this run fetched: someone pushing to it since makes the push fail, not vanish.
    for I := 0 to FReleasePush.Count - 1 do
    begin
      B := FReleasePush[I];
      Refs := Refs + Format(' refs/heads/%s:refs/heads/%s', [B, B]);
      if FReleasePush.Objects[I] <> nil then
        Lease := Lease + Format(' --force-with-lease=refs/heads/%s:%s', [B,
          RefSha(Format('refs/remotes/%s/%s', [FOpt.Remote, B]))]);
    end;
    if GitOut(Format('push --porcelain%s %s%s', [Lease, FOpt.Remote, Refs]), Out1,
              6 * 3600) <> 0 then
      raise Exception.Create('git push of the release branches failed (someone may have ' +
        'pushed to one since this run fetched them; run again):'#13#10 + Trim(Out1));
  end;
  Log(Format('Pushed to %s.', [FOpt.Remote]));
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

    // The sizes above are the ones measured when each revision was fetched. What went into git
    // is the CACHED copy, so check that too: a file truncated in the cache under the right
    // hash would otherwise pass the comparison above while git holds the short version.
    Rows.Clear;
    Sums.Clear;
    for I := 0 to FBlobs.Count - 1 do
    begin
      if Sums.ContainsKey(FBlobs[I].Sha) then Continue;
      Key := TPath.Combine(FOpt.CacheDir,
        StringReplace(FBlobs[I].CachePath, '/', PathDelim, [rfReplaceAll]));
      if TFile.Exists(Key) then Got := TFile.GetSize(Key) else Got := -1;
      Sums.Add(FBlobs[I].Sha, Got);
      if Got <> FBlobs[I].Size then
        Rows.Add(Format('%s,%d,%d', [FBlobs[I].Sha, FBlobs[I].Size, Got]));
    end;
    if Rows.Count = 0 then
      Log(Format('cached blobs          : all %d match their fetched size', [Sums.Count]))
    else
    begin
      Log('');
      Log(Format('*** %d cached blob(s) are missing or not the size they were fetched at -',
        [Rows.Count]));
      Log('*** listed in meta\cache_mismatch.csv (-1 = missing). Commits built from them are');
      Log('*** wrong. Delete those cache files, their rows in meta\blobs.csv, state.txt and the');
      Log('*** repository, then run again: everything else is reused from the cache.');
      Rows.Insert(0, 'sha256,fetched_size,cached_size');
      Rows.SaveToFile(TPath.Combine(FOpt.MetaDir, 'cache_mismatch.csv'), TEncoding.UTF8);
    end;
  finally
    Rows.Free;
    Sums.Free;
  end;
end;

end.
