unit uTCApi;
{
  Team Coherence API bindings and metadata extraction.

  Win32 only - GPVCCore.dll / GPVMain.dll are 32-bit.

  All strings crossing this boundary are ANSI. TC 7.1 predates Delphi 2009, so the "PChar"
  in TCVcsApi.chm means PAnsiChar. Compiled under a modern Delphi with PChar = PWideChar,
  every string comes back as garbage while the numeric fields still look perfect - a silent
  corruption that also mangles outgoing strings ('Alice' arrives as "A").

  READ-ONLY. Nothing here creates, modifies, promotes or deletes any Team Coherence object.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  Winapi.Windows;

type
  PTCChar = PAnsiChar;

  TTCFolder = record
    ID, ParentID: Cardinal;
    Name, TCPath: string;
    FileCount: Integer;
  end;

  TTCFile = record
    ID, ParentID: Cardinal;
    Name, TCPath, LocalPath: string;
    RevisionCount, ShareCount: Integer;
  end;

  // ---- content retrieval through the DLL ---------------------------------------------------
  //
  // TCVcsApi.chm titles TCDVcsCheckOutFile "Get or Check out a file", and the Lock field is what
  // chooses between the two: Lock := False is a plain read. Verified - `tc ListLockedFiles` is
  // empty after thousands of these, and the bytes match tc.exe's byte for byte.
  //
  // Worth it because `tc.exe` costs ~930 ms per invocation before it does any work at all
  // (process start, DLL load, connect, authenticate, exit) and this call pays none of that:
  // 0.21 s/revision against 2.6 s, measured across 40 distinct archives.
  //
  // The 7.1 record has NO Flags field; later headers do. It is declared and zeroed, because a
  // 7.1 DLL ignores a trailing field while omitting one a newer DLL expects makes it read the
  // stack. Buffer sizes are InitializeCheckOutInfo's own; the DLL writes back into them, so
  // they must be allocated rather than pointed at Delphi strings. PChar means PAnsiChar (L12).
  TCheckOutInfo = record
    Comments: PTCChar;
    Extra: PTCChar;
    Revision: PTCChar;
    LocalPath: PTCChar;
    VersionID: Cardinal;
    AssignVersionID: Cardinal;
    Overwrite: Boolean;
    Lock: Boolean;
    Flags: Integer;
  end;
  PCheckOutInfo = ^TCheckOutInfo;

  TFnCheckOutFile = function(FileID: Cardinal; var RevisionID: Cardinal;
                             Info: PCheckOutInfo): Integer; stdcall;

  TTCRevision = record
    FileID, RevID: Cardinal;
    TCPath, Revision, Author, Comment: string;
    When: TDateTime;
    Size: Integer;
    // How many version labels this revision carries. TC hands this to the revision callback
    // for free, and it is what makes the label pass cheap: only revisions with VerCount > 0
    // need to be asked WHICH labels they carry. Without it the pass asks all 44,450.
    VerCount: Integer;
  end;

  TTCLabel = record
    ID: Cardinal;
    Name, Comment: string;
    When: TDateTime;
    LabelType: Integer;
  end;

  TTCAttachment = record
    LabelID, FileID: Cardinal;
    Revision: string;
  end;

  TTCView = record
    ID: Cardinal;
    Name, Description: string;
    Shared, Current: Boolean;
  end;

  TTCProject = record
    ID: Cardinal;
    Name: string;
  end;

  TLogProc = procedure(const Msg: string) of object;
  TProgressProc = procedure(const Phase: string; Done, Total: Integer) of object;
  TCancelFunc = function: Boolean of object;

  ETCError = class(Exception);

  TTCSession = class
  private
    FCore, FMain: HMODULE;
    FDllLock: TCriticalSection;   // GetRevisionContent is called from the fetch pool
    FBinDir: string;
    FConnected: Boolean;
    FHost: string;
    FPort: Word;
    FOnLog: TLogProc;
    FOnItem: TLogProc;
    FOnProgress: TProgressProc;
    FOnCancel: TCancelFunc;
    function Api(const Name: string): Pointer;
    procedure Log(const Msg: string);
    procedure Item(const Detail: string);   // "what is happening right now", not logged
    procedure Progress(const Phase: string; Done, Total: Integer);
    function Cancelled: Boolean;
  public
    // collected metadata
    Projects: TList<TTCProject>;
    Folders: TList<TTCFolder>;
    Files: TList<TTCFile>;
    Revisions: TList<TTCRevision>;
    Labels: TList<TTCLabel>;
    Attachments: TList<TTCAttachment>;
    Views: TList<TTCView>;
    // Optional non-interactive login. Left empty, Login uses the client's own dialog and
    // this program handles no password at all.
    ConnectionName: string;
    UserName: string;
    Password: string;

    constructor Create(const ABinDir: string);
    destructor Destroy; override;

    property OnLog: TLogProc read FOnLog write FOnLog;
    property OnItem: TLogProc read FOnItem write FOnItem;
    property OnProgress: TProgressProc read FOnProgress write FOnProgress;
    property OnCancel: TCancelFunc read FOnCancel write FOnCancel;
    property Connected: Boolean read FConnected;
    property Host: string read FHost;
    property Port: Word read FPort;

    function ProbeEntryPoints: Integer;
    function ListConnections: TArray<string>;

    // Logs in through the TC client's own session. No password is handled by this program.
    function Login: Boolean;
    function ServerReachable(TimeoutMs: Integer = 4000): Boolean;
    procedure Logout;

    // Fetches one revision's content into DestDir through the DLL, on the session already
    // open. Returns a TC error code: 0 = OK. See the implementation for why this is a read.
    function GetRevisionContent(FileID: Cardinal; const Revision, DestDir: string): Integer;
    procedure EnumProjects;
    procedure EnumTree(RootID: Cardinal);            // folders + files for one project
    procedure EnumAllRevisions;                      // revisions for every collected file
    procedure EnumLabelsFor(RootID: Cardinal);
    // one call per revision; checkpoints into MetaDir so it can resume after an interruption
    procedure EnumAttachments(const MetaDir: string);
    procedure EnumViews;

    procedure SaveCsvs(const OutDir: string);
    function LoadCsvs(const Dir: string): Boolean;
    function ErrName(Code: Integer): string;
  end;

implementation

uses
  System.DateUtils, System.NetEncoding, System.IOUtils, System.StrUtils, Winapi.WinSock;

const
  lt_VersionLabel   = 1;
  lt_PromotionLabel = 2;

type
  // ---- prototypes exactly as documented in TCVcsApi.chm ---------------------------------
  TIntEnumProjects = function(Context, Data: Pointer; pName: PTCChar; ID: Cardinal): Boolean; stdcall;

  TIntEnumFolders = function(Context, Data: Pointer; pName, pTCPath, pLocalFolder: PTCChar;
    ID, ParentID: Cardinal; FolderCount, FileCount: Integer): Boolean; stdcall;

  TIntEnumFiles = function(Context, Data: Pointer; pName, pLocalPath, pLockedBy: PTCChar;
    ID, ParentID, AncestorID: Cardinal;
    Modified, Timestamp, CompressedSize, RevisionCount, ShareCount, Status: Integer;
    IsVirtual, Frozen: Boolean): Boolean; stdcall;

  TIntEnumRevisions = function(Context, Data: Pointer; pName, pAuthor, pComments, pLockedBy: PTCChar;
    ID, ParentID: Cardinal;
    Modified, Timestamp, CompressedSize, OriginalSize, CRC, VerCount, PromoCount: Integer): Boolean; stdcall;

  TIntEnumLabels = function(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
    ID: Cardinal; Timestamp: Integer): Boolean; stdcall;

  TIntEnumViews = function(Context, Data: Pointer; pName, pDescription: PTCChar;
    ID: Cardinal; Shared, Current: Boolean): Boolean; stdcall;

  TIntEnumConnections = function(Context, Data: Pointer; pName, pDescription, pHost: PTCChar;
    Port: Integer; Current: Boolean): Boolean; stdcall;

  TFnVcsInit       = function(Handle: Cardinal; LoadCache: Boolean; ProgressProc: Pointer): Integer; stdcall;
  TFnConnect       = function(pConnection, pName, pPassword: PTCChar): Integer; stdcall;
  TFnVcsLogin      = function: Boolean; stdcall;
  TFnDisconnect    = function: Integer; stdcall;
  TFnEnumProjects  = function(Context, Data: Pointer; EnumProc: TIntEnumProjects): Integer; stdcall;
  TFnEnumFolders   = function(RootID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumFolders; Recursive: Boolean): Integer; stdcall;
  TFnEnumFiles     = function(RootID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumFiles; Recursive: Boolean): Integer; stdcall;
  TFnEnumRevisions = function(FileID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumRevisions): Integer; stdcall;
  TFnEnumLabels    = function(RootID, RevID: Cardinal; LabelType: Integer; Context, Data: Pointer; EnumProc: TIntEnumLabels): Integer; stdcall;
  TFnEnumViews     = function(Context, Data: Pointer; EnumProc: TIntEnumViews): Integer; stdcall;
  TFnEnumConns     = function(Context, Data: Pointer; EnumProc: TIntEnumConnections): Integer; stdcall;

var
  // The DLL callbacks are plain stdcall functions, so the session in flight is reached
  // through a unit variable. All TC API calls are confined to the single migration thread
  // (see uWorker), so there is no re-entrancy here.
  GSession: TTCSession = nil;
  GCurrentTCPath: string;      // folder path for files being enumerated
  GCurrentFileID: Cardinal;
  GCurrentRev: string;
  GConnNames: TStringList = nil;
  GLabelHits: Integer = 0;      // counts labels on a file, to skip whole files cheaply
  // Set while the attachment pass runs so CbAttach can append each row as it is found.
  GAttachWriter: TStreamWriter = nil;
  // "Login - <connection>" for the window-raising thread; set from the session.
  GLoginTitle: string = '';

function S(P: PTCChar): string;
begin
  if P = nil then Result := '' else Result := string(AnsiString(P));
end;

function UnixToDT(TS: Integer): TDateTime;
begin
  // True = keep it in UTC. With False these are LOCAL times, which round-trip back to the
  // right instant for git but are written to the CSVs with a "Z" that lies about them.
  // If this changes, DateTimeToUnix in uPipeline must change with it or every commit shifts.
  if TS <= 0 then Result := 0 else Result := UnixToDateTime(Int64(TS), True);
end;

// ---------------------------------------------------------------- callbacks

function CbProjects(Context, Data: Pointer; pName: PTCChar; ID: Cardinal): Boolean; stdcall;
var
  P: TTCProject;
begin
  P.ID := ID; P.Name := S(pName);
  GSession.Projects.Add(P);
  Result := True;
end;

function CbFolders(Context, Data: Pointer; pName, pTCPath, pLocalFolder: PTCChar;
  ID, ParentID: Cardinal; FolderCount, FileCount: Integer): Boolean; stdcall;
var
  F: TTCFolder;
begin
  F.ID := ID; F.ParentID := ParentID;
  F.Name := S(pName); F.TCPath := S(pTCPath); F.FileCount := FileCount;
  GSession.Folders.Add(F);
  // this walk can run for minutes on a large project over a VPN, so show every item
  GSession.Item(Format('folder %d: %s', [GSession.Folders.Count, F.TCPath]));
  if (GSession.Folders.Count mod 100) = 0 then
    GSession.Log(Format('    ... %d folders so far', [GSession.Folders.Count]));
  Result := True;
end;

function CbFiles(Context, Data: Pointer; pName, pLocalPath, pLockedBy: PTCChar;
  ID, ParentID, AncestorID: Cardinal;
  Modified, Timestamp, CompressedSize, RevisionCount, ShareCount, Status: Integer;
  IsVirtual, Frozen: Boolean): Boolean; stdcall;
var
  F: TTCFile;
  I: Integer;
begin
  F.ID := ID; F.ParentID := ParentID;
  F.Name := S(pName); F.LocalPath := S(pLocalPath);
  F.RevisionCount := RevisionCount; F.ShareCount := ShareCount;
  // resolve the archive's folder so the file carries a full TC path
  F.TCPath := '';
  for I := 0 to GSession.Folders.Count - 1 do
    if GSession.Folders[I].ID = ParentID then
    begin
      F.TCPath := GSession.Folders[I].TCPath + '/' + F.Name;
      Break;
    end;
  if F.TCPath = '' then F.TCPath := GCurrentTCPath + '/' + F.Name;
  GSession.Files.Add(F);
  GSession.Item(Format('file %d: %s', [GSession.Files.Count, F.TCPath]));
  if (GSession.Files.Count mod 250) = 0 then
    GSession.Log(Format('    ... %d files so far', [GSession.Files.Count]));
  Result := True;
end;

function CbRevisions(Context, Data: Pointer; pName, pAuthor, pComments, pLockedBy: PTCChar;
  ID, ParentID: Cardinal;
  Modified, Timestamp, CompressedSize, OriginalSize, CRC, VerCount, PromoCount: Integer): Boolean; stdcall;
var
  R: TTCRevision;
begin
  R.FileID := GCurrentFileID;
  R.RevID := ID;
  R.TCPath := GCurrentTCPath;
  R.Revision := S(pName);
  R.Author := S(pAuthor);
  R.Comment := S(pComments);
  R.When := UnixToDT(Timestamp);
  R.Size := OriginalSize;
  R.VerCount := VerCount;   // free here; saves tens of thousands of calls in the label pass
  GSession.Revisions.Add(R);
  Result := True;
end;

function CbLabels(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
  ID: Cardinal; Timestamp: Integer): Boolean; stdcall;
var
  L: TTCLabel;
  I: Integer;
begin
  for I := 0 to GSession.Labels.Count - 1 do
    if GSession.Labels[I].ID = ID then Exit(True);      // labels repeat across roots
  L.ID := ID; L.Name := S(pName); L.Comment := S(pComments);
  L.When := UnixToDT(Timestamp); L.LabelType := LabelType;
  GSession.Labels.Add(L);
  Result := True;
end;

function CbAttach(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
  ID: Cardinal; Timestamp: Integer): Boolean; stdcall;
var
  A: TTCAttachment;
begin
  A.LabelID := ID; A.FileID := GCurrentFileID; A.Revision := GCurrentRev;
  GSession.Attachments.Add(A);
  // Persist immediately as well: this pass is long enough that it will be interrupted, and an
  // attachment that exists only in memory is an attachment that has to be fetched again.
  if GAttachWriter <> nil then
  begin
    GAttachWriter.WriteLine(Format('%d,%d,%s', [A.LabelID, A.FileID, A.Revision]));
    GAttachWriter.Flush;
  end;
  Result := True;
end;

function CbCountLabels(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
  ID: Cardinal; Timestamp: Integer): Boolean; stdcall;
begin
  Inc(GLabelHits);
  Result := False;   // one hit is enough: stop the enumeration immediately
end;

function CbViews(Context, Data: Pointer; pName, pDescription: PTCChar;
  ID: Cardinal; Shared, Current: Boolean): Boolean; stdcall;
var
  V: TTCView;
begin
  V.ID := ID; V.Name := S(pName); V.Description := S(pDescription);
  V.Shared := Shared; V.Current := Current;
  GSession.Views.Add(V);
  Result := True;
end;

function CbConns(Context, Data: Pointer; pName, pDescription, pHost: PTCChar;
  Port: Integer; Current: Boolean): Boolean; stdcall;
begin
  GConnNames.Add(Format('%s  (%s:%d)%s',
    [S(pName), S(pHost), Port, IfThen(Current, '  [current]', '')]));
  // remember where the server is, so reachability can be tested before login blocks on it
  if (GSession.FHost = '') or Current then
  begin
    GSession.FHost := S(pHost);
    GSession.FPort := Port;
  end;
  Result := True;
end;

// ---------------------------------------------------------------- TTCSession

constructor TTCSession.Create(const ABinDir: string);
begin
  inherited Create;
  FDllLock := TCriticalSection.Create;
  FBinDir := IncludeTrailingPathDelimiter(ABinDir);
  Projects := TList<TTCProject>.Create;
  Folders := TList<TTCFolder>.Create;
  Files := TList<TTCFile>.Create;
  Revisions := TList<TTCRevision>.Create;
  Labels := TList<TTCLabel>.Create;
  Attachments := TList<TTCAttachment>.Create;
  Views := TList<TTCView>.Create;

  SetDllDirectory(PChar(FBinDir));
  FCore := LoadLibrary(PChar(FBinDir + 'GPVCCore.dll'));
  FMain := LoadLibrary(PChar(FBinDir + 'GPVMain.dll'));
  if FCore = 0 then
    raise ETCError.CreateFmt(
      'Cannot load GPVCCore.dll from'#13#10'%s'#13#10#13#10 +
      'Check the Team Coherence Bin folder. This program must be 32-bit.', [FBinDir]);
  GSession := Self;
end;

destructor TTCSession.Destroy;
begin
  Logout;
  if FCore <> 0 then FreeLibrary(FCore);
  if FMain <> 0 then FreeLibrary(FMain);
  Projects.Free; Folders.Free; Files.Free; Revisions.Free;
  Labels.Free; Attachments.Free; Views.Free;
  FDllLock.Free;
  if GSession = Self then GSession := nil;
  inherited;
end;

function TTCSession.Api(const Name: string): Pointer;
begin
  Result := nil;
  if FCore <> 0 then Result := GetProcAddress(FCore, PChar(Name));
  if (Result = nil) and (FMain <> 0) then Result := GetProcAddress(FMain, PChar(Name));
end;

procedure TTCSession.Log(const Msg: string);
begin
  if Assigned(FOnLog) then FOnLog(Msg);
end;

procedure TTCSession.Item(const Detail: string);
begin
  if Assigned(FOnItem) then FOnItem(Detail);
end;

procedure TTCSession.Progress(const Phase: string; Done, Total: Integer);
begin
  if Assigned(FOnProgress) then FOnProgress(Phase, Done, Total);
end;

function TTCSession.Cancelled: Boolean;
begin
  Result := Assigned(FOnCancel) and FOnCancel;
end;

function TTCSession.ErrName(Code: Integer): string;
begin
  case Code of
    0:  Result := 'OK';
    6:  Result := 'Cannot find revision';
    14: Result := 'Insufficient access';
    29: Result := 'Invalid password';
    40: Result := 'Object not found';
    48: Result := 'Not logged in';
    49: Result := 'Connection not defined';
    73: Result := 'No revisions';
    75: Result := 'No licenses';
    78: Result := 'Invalid connection';
    79: Result := 'Already connected';
    80: Result := 'Not connected';
    81: Result := 'Could not connect to server';
    82: Result := 'Version does not exist';
  else
    Result := 'error ' + IntToStr(Code);
  end;
end;

function TTCSession.ProbeEntryPoints: Integer;
const
  Names: array[0..8] of string = (
    'TCVcsInitialize', 'TCVcsLogin', 'TCDVcsEnumProjects', 'TCDVcsEnumFolders',
    'TCDVcsEnumFiles', 'TCDVcsEnumRevisions', 'TCDVcsEnumLabels', 'TCDVcsEnumViews',
    'TCDVcsEnumConnections');
var
  I: Integer;
begin
  Result := 0;
  for I := Low(Names) to High(Names) do
    if Api(Names[I]) <> nil then Inc(Result)
    else Log('  missing entry point: ' + Names[I]);
end;

function TTCSession.ListConnections: TArray<string>;
var
  Fn: TFnEnumConns;
begin
  Result := nil;
  Fn := Api('TCDVcsEnumConnections');
  if not Assigned(Fn) then Exit;
  GConnNames := TStringList.Create;
  try
    Fn(nil, nil, CbConns);
    Result := GConnNames.ToStringArray;
  finally
    FreeAndNil(GConnNames);
  end;
end;

type
  // TCVcsLogin creates its dialog unowned, so it can render BEHIND our window - the
  // application then looks stuck at "Opening the Team Coherence login" with nothing
  // visible. TCVcsLogin blocks the calling thread, so the only way to push the dialog
  // forward is from another thread while that call is in flight.
  TLoginFronter = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TLoginFronter.Execute;
var
  H: HWND;
  Tries: Integer;
begin
  FreeOnTerminate := True;
  for Tries := 1 to 60 do            // up to ~30 seconds
  begin
    if Terminated then Exit;
    H := FindWindow('TdlgLogin', nil);
    // TC titles the dialog "Login - <connection>", so the fallback has to be built from the
    // connection in use rather than hardcoded.
    if (H = 0) and (GLoginTitle <> '') then H := FindWindow(nil, PChar(GLoginTitle));
    if H <> 0 then
    begin
      SetWindowPos(H, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE);
      BringWindowToTop(H);
      SetForegroundWindow(H);
      FlashWindow(H, True);
      Exit;
    end;
    Sleep(500);
  end;
end;

function TTCSession.ServerReachable(TimeoutMs: Integer): Boolean;
// A plain TCP connect to the repository server, with a timeout.
//
// This exists because TCVcsLogin BLOCKS INDEFINITELY when the server cannot be reached - it
// does not fail, it just never returns, and the application looks hung. Checking the socket
// first turns "frozen forever" into a clear message in about a second.
var
  WSA: TWSAData;
  Sock: TSocket;
  Addr: TSockAddrIn;
  Mode: u_long;
  FDs: TFDSet;
  TV: TTimeVal;
  Rc: Integer;
begin
  Result := False;
  if (FHost = '') or (FPort = 0) then Exit(True);   // nothing to test against; let it try

  if WSAStartup($0202, WSA) <> 0 then Exit(True);
  try
    Sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if Sock = INVALID_SOCKET then Exit(True);
    try
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := htons(FPort);
      Addr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(FHost)));
      if Addr.sin_addr.S_addr = INADDR_NONE then Exit(True);   // a name, not an address

      Mode := 1;                       // non-blocking, so connect() cannot hang
      ioctlsocket(Sock, FIONBIO, Mode);
      Rc := connect(Sock, TSockAddr(Addr), SizeOf(Addr));
      if Rc = 0 then Exit(True);

      FD_ZERO(FDs);
      FD_SET(Sock, FDs);
      TV.tv_sec := TimeoutMs div 1000;
      TV.tv_usec := (TimeoutMs mod 1000) * 1000;
      Result := select(0, nil, @FDs, nil, @TV) > 0;
    finally
      closesocket(Sock);
    end;
  finally
    WSACleanup;
  end;
end;

function TTCSession.Login: Boolean;
var
  InitFn: TFnVcsInit;
  LoginFn: TFnVcsLogin;
  ConnFn: TFnConnect;
  AConn, AUser, APwd: AnsiString;
  Code: Integer;
begin
  // TCVcsInitialize + TCVcsLogin reuse the credentials the Team Coherence client already
  // holds, so this program never sees, prompts for or stores a password. Measured
  // 2026-09-23: Initialize returns 59 and the login still succeeds, so 59 is not fatal.
  // A password, if one was supplied, avoids the dialog entirely - useful for a scheduled
  // run. Nothing is stored: it arrives on the command line and lives in memory only.
  if (UserName <> '') and (Password <> '') then
  begin
    ConnFn := Api('TCDVcsConnect');
    if Assigned(ConnFn) then
    begin
      AConn := AnsiString(ConnectionName);
      AUser := AnsiString(UserName);
      APwd := AnsiString(Password);
      Code := ConnFn(PAnsiChar(AConn), PAnsiChar(AUser), PAnsiChar(APwd));
      Log(Format('TCDVcsConnect("%s", "%s", <supplied>) -> %s',
        [ConnectionName, UserName, ErrName(Code)]));
      if (Code = 0) or (Code = 79) then
      begin
        FConnected := True;
        Exit(True);
      end;
      Log('Password login failed - falling back to the login dialog.');
    end;
  end;

  InitFn := Api('TCVcsInitialize');
  if Assigned(InitFn) then
  begin
    // LoadCache = True: documented as loading the client's internal cache, which may let it
    // reuse the existing session instead of prompting.
    Code := InitFn(0, True, nil);
    Log(Format('TCVcsInitialize(LoadCache) -> %s', [ErrName(Code)]));
  end;

  LoginFn := Api('TCVcsLogin');
  if not Assigned(LoginFn) then
    raise ETCError.Create('TCVcsLogin is not exported by this Team Coherence client.');

  Log('Opening the Team Coherence login...');
  if ConnectionName <> '' then GLoginTitle := 'Login - ' + ConnectionName
  else GLoginTitle := '';
  Log(Format('>>> A "%s" window will appear - click OK. It is brought to the front,',
    [IfThen(GLoginTitle <> '', GLoginTitle, 'Login')]));
  Log('>>> but if you cannot see it, Alt+Tab to it. This run waits for it. <<<');
  TLoginFronter.Create(False);   // pushes the dialog in front while TCVcsLogin blocks
  Result := LoginFn();
  FConnected := Result;
  if Result then Log('Session established.') else Log('Login was cancelled or refused.');
end;

procedure TTCSession.Logout;
var
  Fn: TFnDisconnect;
begin
  if not FConnected then Exit;
  Fn := Api('TCDVcsDisconnect');
  if Assigned(Fn) then Fn();
  FConnected := False;
end;

function TTCSession.GetRevisionContent(FileID: Cardinal;
  const Revision, DestDir: string): Integer;
var
  Fn: TFnCheckOutFile;
  Info: PCheckOutInfo;
  ARev, ADir: AnsiString;
  RevOut: Cardinal;
begin
  Fn := Api('TCDVcsCheckOutFile');
  if not Assigned(Fn) then Exit(-1);

  ARev := AnsiString(Revision);
  ADir := AnsiString(DestDir);
  // The buffers are fixed; refuse rather than truncate a path or a revision name.
  if (Length(ARev) > 254) or (Length(ADir) > 511) then Exit(-2);

  New(Info);
  try
    GetMem(Info.Comments, 65536);  Info.Comments^ := #0;
    GetMem(Info.Extra, 65536);     Info.Extra^ := #0;
    GetMem(Info.Revision, 255);    Info.Revision^ := #0;
    GetMem(Info.LocalPath, 512);   Info.LocalPath^ := #0;
    Info.VersionID := 0;
    Info.AssignVersionID := 0;
    Info.Overwrite := True;   // the caller always supplies a fresh empty folder
    Info.Lock := False;       // READ ONLY - this is the flag that makes it a Get
    Info.Flags := 0;
    StrPLCopy(Info.Revision, ARev, 254);
    StrPLCopy(Info.LocalPath, ADir, 511);
    RevOut := 0;

    // Serialised: the fetch pool is multi-threaded and this DLL's thread-safety is unknown.
    // Concurrency against this server has already caused silent corruption once (two Get
    // calls on one archive returning success with no files), so it is not worth finding out.
    // One worker was measured fastest anyway.
    FDllLock.Enter;
    try
      Result := Fn(FileID, RevOut, Info);
    finally
      FDllLock.Leave;
    end;
  finally
    FreeMem(Info.Comments);
    FreeMem(Info.Extra);
    FreeMem(Info.Revision);
    FreeMem(Info.LocalPath);
    Dispose(Info);
  end;
end;

procedure TTCSession.EnumProjects;
var
  Fn: TFnEnumProjects;
  Rc: Integer;
begin
  Projects.Clear;
  Fn := Api('TCDVcsEnumProjects');
  if not Assigned(Fn) then Exit;
  Rc := Fn(nil, nil, CbProjects);
  Log(Format('Projects: %s, %d found', [ErrName(Rc), Projects.Count]));
end;

procedure TTCSession.EnumTree(RootID: Cardinal);
var
  FnF: TFnEnumFolders;
  FnFi: TFnEnumFiles;
  Rc, Before: Integer;
begin
  FnF := Api('TCDVcsEnumFolders');
  FnFi := Api('TCDVcsEnumFiles');

  if Assigned(FnF) then
  begin
    Before := Folders.Count;
    Rc := FnF(RootID, nil, nil, CbFolders, True);
    Log(Format('  folders: %s, +%d', [ErrName(Rc), Folders.Count - Before]));
  end;

  if Assigned(FnFi) then
  begin
    Before := Files.Count;
    Rc := FnFi(RootID, nil, nil, CbFiles, True);
    Log(Format('  files:   %s, +%d', [ErrName(Rc), Files.Count - Before]));
  end;
end;

procedure TTCSession.EnumAllRevisions;
var
  Fn: TFnEnumRevisions;
  I: Integer;
begin
  Fn := Api('TCDVcsEnumRevisions');
  if not Assigned(Fn) then Exit;
  for I := 0 to Files.Count - 1 do
  begin
    if Cancelled then Exit;
    GCurrentFileID := Files[I].ID;
    GCurrentTCPath := Files[I].TCPath;
    Item(Format('%s  (%d revisions so far)', [Files[I].TCPath, Revisions.Count]));
    Fn(GCurrentFileID, nil, nil, CbRevisions);
    Progress('Reading revision history', I + 1, Files.Count);
  end;
  Log(Format('Revisions: %d', [Revisions.Count]));
end;

procedure TTCSession.EnumLabelsFor(RootID: Cardinal);
var
  Fn: TFnEnumLabels;
begin
  Fn := Api('TCDVcsEnumLabels');
  if not Assigned(Fn) then Exit;
  Fn(RootID, 0, lt_VersionLabel, nil, nil, CbLabels);
  Fn(RootID, 0, lt_PromotionLabel, nil, nil, CbLabels);
  Log(Format('  labels:  %d total', [Labels.Count]));
end;

procedure TTCSession.EnumAttachments(const MetaDir: string);
var
  Fn: TFnEnumLabels;
  I, J, Skipped, Asked: Integer;
  ByFile: TDictionary<Cardinal, Boolean>;
  HasAny: Boolean;
  DoneFiles: TDictionary<Cardinal, Boolean>;
  DoneRevs: TDictionary<string, Boolean>;
  NoLabels, Expected: Integer;
  HaveVerCounts: Boolean;
  WFiles, WRevs, WAttach: TStreamWriter;
  Key: string;

  // Opens a CSV for appending, writing the header if it is new. Flushed after every row by the
  // caller, because the point is to survive being killed.
  function OpenAppend(const Path, Header: string): TStreamWriter;
  var
    IsNew: Boolean;
  begin
    IsNew := not TFile.Exists(Path);
    if IsNew then
      Result := TStreamWriter.Create(
        TFileStream.Create(Path, fmCreate or fmShareDenyWrite), TEncoding.UTF8)
    else
      Result := TStreamWriter.Create(
        TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite), TEncoding.UTF8);
    Result.OwnStream;
    if IsNew then
    begin
      Result.WriteLine(Header);
      Result.Flush;
    end
    else
      Result.BaseStream.Seek(0, soEnd);
  end;

  procedure LoadKeyed(const Path: string; D: TDictionary<Cardinal, Boolean>);
  var
    L: TStringList;
    N: Integer;
    C: TArray<string>;
  begin
    if not TFile.Exists(Path) then Exit;
    L := TStringList.Create;
    try
      L.LoadFromFile(Path, TEncoding.UTF8);
      for N := 1 to L.Count - 1 do
      begin
        if L[N] = '' then Continue;
        C := L[N].Split([',']);
        if Length(C) < 2 then Continue;
        D.AddOrSetValue(StrToUIntDef(C[0], 0), C[1] = '1');
      end;
    finally
      L.Free;
    end;
  end;

  // Reads the crash log back into the in-memory attachment list. Dedupes, because a kill
  // between writing an attachment row and writing its done-marker leaves that revision to be
  // asked again.
  procedure LoadAttachLog(const Path: string);
  var
    L: TStringList;
    N: Integer;
    C: TArray<string>;
    A: TTCAttachment;
    Seen: TDictionary<string, Boolean>;
    K: string;
  begin
    if not TFile.Exists(Path) then Exit;
    L := TStringList.Create;
    Seen := TDictionary<string, Boolean>.Create;
    try
      for N := 0 to Attachments.Count - 1 do
        Seen.AddOrSetValue(Format('%d|%d|%s',
          [Attachments[N].LabelID, Attachments[N].FileID, Attachments[N].Revision]), True);
      L.LoadFromFile(Path, TEncoding.UTF8);
      for N := 1 to L.Count - 1 do
      begin
        if L[N] = '' then Continue;
        C := L[N].Split([',']);
        if Length(C) < 3 then Continue;
        A.LabelID := StrToUIntDef(C[0], 0);
        A.FileID := StrToUIntDef(C[1], 0);
        A.Revision := C[2];
        K := Format('%d|%d|%s', [A.LabelID, A.FileID, A.Revision]);
        if Seen.ContainsKey(K) then Continue;
        Seen.Add(K, True);
        Attachments.Add(A);
      end;
      if Attachments.Count > 0 then
        Log(Format('  recovered %d attachment(s) from attach_log.csv', [Attachments.Count]));
    finally
      Seen.Free;
      L.Free;
    end;
  end;

  procedure LoadDone(const Path: string; D: TDictionary<string, Boolean>);
  var
    L: TStringList;
    N: Integer;
    C: TArray<string>;
  begin
    if not TFile.Exists(Path) then Exit;
    L := TStringList.Create;
    try
      L.LoadFromFile(Path, TEncoding.UTF8);
      for N := 1 to L.Count - 1 do
      begin
        if L[N] = '' then Continue;
        C := L[N].Split([',']);
        if Length(C) < 2 then Continue;
        D.AddOrSetValue(C[0] + '|' + C[1], True);
      end;
    finally
      L.Free;
    end;
  end;

begin
  // Per TCVcsApi.chm: RootID is "an ID pointing to a Project, Folder, or a File", and RevID
  // enumerates the labels on one revision *only when RootID is a File id*. Passing a project
  // id returns nothing at all - silently, with Err_OK - which is exactly what a first run did
  // across 44,446 revisions.
  //
  // This is one server round trip per revision and is by far the slowest phase, so first ask
  // each FILE whether it carries any label at all (RevID = 0). A file with none cannot have
  // a labelled revision, so all of its revisions are skipped. Measured: 20 files produced
  // 10,159 revisions, so the saving is large whenever labels are concentrated in a few files.
  Fn := Api('TCDVcsEnumLabels');
  if not Assigned(Fn) then Exit;

  // REFUSE to run without real revision ids. RevID is the second argument to EnumLabels; at 0
  // the call returns the labels on the FILE, for every revision alike, with Err_OK and output
  // that looks entirely reasonable. That produced 74,223 useless rows over five hours - all 38
  // labels repeated against all 215 revisions of one heavily-revised unit - because revisions.csv did not
  // persist rev_id and the run had reloaded its metadata from it.
  J := 0;
  for I := 0 to Revisions.Count - 1 do
    if Revisions[I].RevID > 0 then Inc(J);
  if J = 0 then
  begin
    Log('');
    Log('*** Every revision has rev_id = 0, so labels CANNOT be matched to revisions: the API');
    Log('*** would return each file''s whole label set for every one of its revisions.');
    Log('*** Delete meta\revisions.csv and run again to re-read the history WITH rev_id.');
    Exit;
  end;
  if J < Revisions.Count then
    Log(Format('  note: %d of %d revisions have no rev_id and will be skipped',
      [Revisions.Count - J, Revisions.Count]));

  ByFile := TDictionary<Cardinal, Boolean>.Create;
  try
    Skipped := 0;
    Asked := 0;
    HasAny := False;

    // ---- resume state ------------------------------------------------------------------
    // This pass is tens of thousands of server round trips and used to keep everything in
    // memory until the end, so one dropped VPN threw away the lot. A run once sat for 73
    // minutes blocked in TCDVcsEnumLabels and produced a 27-byte file. Both loops now record
    // their progress as they go, so a relaunch continues instead of starting again.
    DoneFiles := TDictionary<Cardinal, Boolean>.Create;
    DoneRevs := TDictionary<string, Boolean>.Create;
    WFiles := nil; WRevs := nil; WAttach := nil;
    try
      LoadKeyed(TPath.Combine(MetaDir, 'label_files.csv'), DoneFiles);
      LoadDone(TPath.Combine(MetaDir, 'attach_done.csv'), DoneRevs);
      if DoneFiles.Count > 0 then
        Log(Format('  resuming: %d file(s) already checked for labels', [DoneFiles.Count]));
      if DoneRevs.Count > 0 then
        Log(Format('  resuming: %d revision(s) already asked, %d attachment(s) already known',
          [DoneRevs.Count, Attachments.Count]));

      WFiles := OpenAppend(TPath.Combine(MetaDir, 'label_files.csv'), 'file_id,has_labels');
      WRevs := OpenAppend(TPath.Combine(MetaDir, 'attach_done.csv'), 'file_id,revision');
      // The crash log is attach_log.csv, NOT label_attachments.csv. That distinction matters:
      // SaveCsvs owns label_attachments.csv and rewrites it from the in-memory list, and it
      // runs right after the revision enumeration when that list is empty - so it truncates
      // the file. Appending the log there meant attach_done.csv claimed 4,626 labelled
      // revisions were finished while only 592 of their rows survived. Two writers, one file,
      // opposite ideas of who owns it.
      // Read the log BEFORE opening it for append: the writer holds it fmShareDenyWrite, and
      // loading it afterwards fails with a sharing violation.
      LoadAttachLog(TPath.Combine(MetaDir, 'attach_log.csv'));

      WAttach := OpenAppend(TPath.Combine(MetaDir, 'attach_log.csv'),
                            'label_id,file_id,revision');
      GAttachWriter := WAttach;   // CbAttach appends each row as it is found

      // Work out up front how much there is to do. VerCount comes from the revision
      // enumeration at no cost and is exact, so when it is present the per-file scan below is
      // pointless - it only ever answered the weaker question "does this file have any label
      // at all", and took 2.5 hours to do it across 4,237 files.
      NoLabels := 0;
      Expected := 0;
      HaveVerCounts := False;
      for I := 0 to Revisions.Count - 1 do
        if Revisions[I].VerCount >= 0 then
        begin
          HaveVerCounts := True;
          Inc(Expected, Revisions[I].VerCount);
        end;

      if HaveVerCounts then
      begin
        J := 0;
        for I := 0 to Revisions.Count - 1 do
          if Revisions[I].VerCount > 0 then Inc(J);
        Log(Format('  %d of %d revisions carry a label; expecting %d attachment(s)',
          [J, Revisions.Count, Expected]));
        Log('  skipping the per-file scan: ver_count already says exactly which to ask');
      end
      else
      begin
        for I := 0 to Files.Count - 1 do
        begin
          if Cancelled then Exit;
          if DoneFiles.TryGetValue(Files[I].ID, HasAny) then
          begin
            ByFile.AddOrSetValue(Files[I].ID, HasAny);
            if HasAny then Inc(Asked);
            Continue;
          end;
          GLabelHits := 0;
          Fn(Files[I].ID, 0, lt_VersionLabel, nil, nil, CbCountLabels);
          ByFile.AddOrSetValue(Files[I].ID, GLabelHits > 0);
          WFiles.WriteLine(Format('%d,%d', [Files[I].ID, Ord(GLabelHits > 0)]));
          WFiles.Flush;
          if GLabelHits > 0 then Inc(Asked);
          Item(Format('checking %s', [Files[I].TCPath]));
          if (I mod 25 = 0) or (I = Files.Count - 1) then
            Progress('Finding which files carry labels', I + 1, Files.Count);
        end;
        // report the filter result straight away: this decides how long the next loop takes
        Log(Format('  %d of %d files carry any label', [Asked, Files.Count]));
      end;
      Asked := 0;

      for I := 0 to Revisions.Count - 1 do
      begin
        if Cancelled then Exit;
        if ByFile.TryGetValue(Revisions[I].FileID, HasAny) and not HasAny then
        begin
          Inc(Skipped);
          Continue;
        end;
        if Revisions[I].RevID = 0 then Continue;      // see the guard above
        // The big win: TC already told us how many labels this revision carries, so a
        // revision with none needs no call at all. -1 means the metadata predates this and
        // we have to ask.
        if Revisions[I].VerCount = 0 then
        begin
          Inc(NoLabels);
          Continue;
        end;
        Key := Format('%d|%s', [Revisions[I].FileID, Revisions[I].Revision]);
        if DoneRevs.ContainsKey(Key) then Continue;   // already asked in an earlier attempt
        Inc(Asked);
        GCurrentFileID := Revisions[I].FileID;
        GCurrentRev := Revisions[I].Revision;
        Item(Format('%s @ %s  (%d attachments found)',
          [Revisions[I].TCPath, Revisions[I].Revision, Attachments.Count]));
        Fn(Revisions[I].FileID, Revisions[I].RevID, lt_VersionLabel, nil, nil, CbAttach);
        WRevs.WriteLine(Format('%d,%s', [Revisions[I].FileID, Revisions[I].Revision]));
        WRevs.Flush;
        Progress('Matching labels to revisions', I + 1, Revisions.Count);
      end;
      Log(Format('Label attachments: %d  (asked %d revisions, skipped %d with no label, %d by file)',
        [Attachments.Count, Asked, NoLabels, Skipped]));
      if Attachments.Count = 0 then
        Log('  WARNING: no attachments at all. Tags cannot be reproduced exactly from this.');

      // Independent cross-check. TC told us how many labels each revision carries before we
      // asked what they were, so the two totals must agree. They are produced by different
      // calls, which is what makes this worth checking: the previous attempt returned each
      // FILE's labels for every revision and looked perfectly healthy while doing it.
      if HaveVerCounts then
      begin
        if Attachments.Count = Expected then
          Log(Format('  cross-check OK: %d attachments = sum of ver_count', [Expected]))
        else
          Log(Format('  *** CROSS-CHECK FAILED: found %d attachments, ver_count totals %d ***',
            [Attachments.Count, Expected]));
      end;
    finally
      GAttachWriter := nil;
      WAttach.Free;
      WRevs.Free;
      WFiles.Free;
      DoneRevs.Free;
      DoneFiles.Free;
    end;
  finally
    ByFile.Free;
  end;
end;
procedure TTCSession.EnumViews;
var
  Fn: TFnEnumViews;
  Rc: Integer;
begin
  Views.Clear;
  Fn := Api('TCDVcsEnumViews');
  if not Assigned(Fn) then Exit;
  Rc := Fn(nil, nil, CbViews);
  Log(Format('Views: %s, %d found', [ErrName(Rc), Views.Count]));
end;

// ---------------------------------------------------------------- CSV input
//
// Metadata is saved as soon as it is gathered and reloaded on the next run, so an
// interrupted migration never re-reads 44,000 revisions from the server just to get back
// to where it was.

function SplitCsv(const Line: string): TArray<string>;
var
  I: Integer;
  InQuote: Boolean;
  Cur: string;
  Res: TList<string>;
begin
  Res := TList<string>.Create;
  try
    InQuote := False;
    Cur := '';
    I := 1;
    while I <= Length(Line) do
    begin
      if InQuote then
      begin
        if Line[I] = '"' then
        begin
          if (I < Length(Line)) and (Line[I + 1] = '"') then
          begin
            Cur := Cur + '"';
            Inc(I);
          end
          else
            InQuote := False;
        end
        else
          Cur := Cur + Line[I];
      end
      else if Line[I] = '"' then
        InQuote := True
      else if Line[I] = ',' then
      begin
        Res.Add(Cur);
        Cur := '';
      end
      else
        Cur := Cur + Line[I];
      Inc(I);
    end;
    Res.Add(Cur);
    Result := Res.ToArray;
  finally
    Res.Free;
  end;
end;

function FromB64(const S: string): string;
begin
  if S = '' then Exit('');
  try
    Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(S));
  except
    Result := '';
  end;
end;

function FromIso(const S: string): TDateTime;
var
  Y, M, D, H, N, Sec: Integer;
begin
  Result := 0;
  if Length(S) < 19 then Exit;
  Y := StrToIntDef(Copy(S, 1, 4), 0);
  M := StrToIntDef(Copy(S, 6, 2), 0);
  D := StrToIntDef(Copy(S, 9, 2), 0);
  H := StrToIntDef(Copy(S, 12, 2), 0);
  N := StrToIntDef(Copy(S, 15, 2), 0);
  Sec := StrToIntDef(Copy(S, 18, 2), 0);
  if (Y = 0) or (M = 0) or (D = 0) then Exit;
  Result := EncodeDate(Y, M, D) + EncodeTime(H, N, Sec, 0);
end;

function TTCSession.LoadCsvs(const Dir: string): Boolean;
var
  L: TStringList;
  I: Integer;
  C: TArray<string>;
  F: TTCFile;
  R: TTCRevision;
  Lb: TTCLabel;
  A: TTCAttachment;
  FilesCsv, RevsCsv: string;
begin
  FilesCsv := TPath.Combine(Dir, 'files.csv');
  RevsCsv := TPath.Combine(Dir, 'revisions.csv');
  Result := TFile.Exists(FilesCsv) and TFile.Exists(RevsCsv);
  if not Result then Exit;

  Files.Clear;
  Revisions.Clear;
  Labels.Clear;
  Attachments.Clear;

  L := TStringList.Create;
  try
    L.LoadFromFile(FilesCsv, TEncoding.UTF8);
    for I := 1 to L.Count - 1 do            // row 0 is the header
    begin
      if L[I] = '' then Continue;
      C := SplitCsv(L[I]);
      if Length(C) < 3 then Continue;
      F := Default(TTCFile);
      F.ID := StrToUIntDef(C[0], 0);
      F.Name := C[1];
      F.TCPath := C[2];
      if Length(C) > 4 then F.RevisionCount := StrToIntDef(C[4], 0);
      Files.Add(F);
    end;

    L.LoadFromFile(RevsCsv, TEncoding.UTF8);
    for I := 1 to L.Count - 1 do
    begin
      if L[I] = '' then Continue;
      C := SplitCsv(L[I]);
      if Length(C) < 6 then Continue;
      R := Default(TTCRevision);
      R.FileID := StrToUIntDef(C[0], 0);
      // Two layouts exist. The current one carries rev_id in column 1; files written before
      // that was fixed do not, and leave RevID at 0 - which silently turns the per-revision
      // label query into a per-file one. EnumAttachments refuses to run on such a file.
      if (Length(C) >= 9) and (StrToUIntDef(C[1], 0) > 0) then
      begin
        R.RevID := StrToUIntDef(C[1], 0);
        R.TCPath := C[2];
        R.Revision := C[3];
        R.Author := C[4];
        R.When := FromIso(C[5]);
        R.Comment := FromB64(C[6]);
        if Length(C) > 8 then R.Size := StrToIntDef(C[8], 0);
        // ver_count is optional: -1 means "not recorded", which the label pass treats as
        // "must ask", so an older file still works - just slowly.
        if Length(C) > 9 then R.VerCount := StrToIntDef(C[9], -1) else R.VerCount := -1;
      end
      else
      begin
        R.RevID := 0;
        R.TCPath := C[1];
        R.Revision := C[2];
        R.Author := C[3];
        R.When := FromIso(C[4]);
        R.Comment := FromB64(C[5]);
        if Length(C) > 7 then R.Size := StrToIntDef(C[7], 0);
        R.VerCount := -1;   // old layout: unknown, so the label pass must ask
      end;
      Revisions.Add(R);
    end;

    if TFile.Exists(TPath.Combine(Dir, 'labels.csv')) then
    begin
      L.LoadFromFile(TPath.Combine(Dir, 'labels.csv'), TEncoding.UTF8);
      for I := 1 to L.Count - 1 do
      begin
        if L[I] = '' then Continue;
        C := SplitCsv(L[I]);
        if Length(C) < 5 then Continue;
        Lb := Default(TTCLabel);
        Lb.ID := StrToUIntDef(C[0], 0);
        Lb.Name := C[1];
        Lb.Comment := FromB64(C[2]);
        Lb.When := FromIso(C[4]);
        if Length(C) > 6 then Lb.LabelType := StrToIntDef(C[6], 1);
        Labels.Add(Lb);
      end;
    end;

    if TFile.Exists(TPath.Combine(Dir, 'label_attachments.csv')) then
    begin
      L.LoadFromFile(TPath.Combine(Dir, 'label_attachments.csv'), TEncoding.UTF8);
      for I := 1 to L.Count - 1 do
      begin
        if L[I] = '' then Continue;
        C := SplitCsv(L[I]);
        if Length(C) < 3 then Continue;
        A.LabelID := StrToUIntDef(C[0], 0);
        A.FileID := StrToUIntDef(C[1], 0);
        A.Revision := C[2];
        Attachments.Add(A);
      end;
    end;
  finally
    L.Free;
  end;

  Log(Format('Reloaded metadata: %d files, %d revisions, %d labels, %d attachments',
    [Files.Count, Revisions.Count, Labels.Count, Attachments.Count]));
  Result := (Files.Count > 0) and (Revisions.Count > 0);
end;

// ---------------------------------------------------------------- CSV output

function CsvQ(const V: string): string;
begin
  if (Pos(',', V) > 0) or (Pos('"', V) > 0) or (Pos(#10, V) > 0) or (Pos(#13, V) > 0) then
    Result := '"' + StringReplace(V, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := V;
end;

function B64(const V: string): string;
begin
  if V = '' then Exit('');
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(V));
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
end;

function Iso(const D: TDateTime): string;
begin
  if D = 0 then Exit('');
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', D);
end;

procedure SaveList(const FileName: string; const Header: string; Lines: TStringList);
begin
  Lines.Insert(0, Header);
  Lines.WriteBOM := False;
  Lines.SaveToFile(FileName, TEncoding.UTF8);
end;

procedure TTCSession.SaveCsvs(const OutDir: string);
var
  L: TStringList;
  I: Integer;
begin
  ForceDirectories(OutDir);
  L := TStringList.Create;
  try
    for I := 0 to Files.Count - 1 do
      L.Add(Format('%d,%s,%s,,%d,%d', [Files[I].ID, CsvQ(Files[I].Name),
        CsvQ(Files[I].TCPath), Files[I].RevisionCount, Files[I].ShareCount]));
    SaveList(TPath.Combine(OutDir, 'files.csv'),
      'file_id,name,tc_path,git_path,revision_count,share_count', L);

    L.Clear;
    // rev_id is TC's internal revision id and it MUST be persisted. It is the second argument
    // to TCDVcsEnumLabels, and with it left at 0 that call returns the labels on the whole
    // FILE rather than on one revision - silently, with Err_OK, and with entirely plausible
    // output. Leaving it out of this file cost a 5-hour pass whose every answer was the same
    // 38 labels repeated for all 215 revisions of one heavily-revised unit.
    for I := 0 to Revisions.Count - 1 do
      L.Add(Format('%d,%d,%s,%s,%s,%s,%s,modify,%d,%d',
        [Revisions[I].FileID, Revisions[I].RevID,
         CsvQ(Revisions[I].TCPath), CsvQ(Revisions[I].Revision),
         CsvQ(Revisions[I].Author), Iso(Revisions[I].When), B64(Revisions[I].Comment),
         Revisions[I].Size, Revisions[I].VerCount]));
    SaveList(TPath.Combine(OutDir, 'revisions.csv'),
      'file_id,rev_id,tc_path,revision,author,timestamp_utc,comment_b64,action,size,ver_count', L);

    L.Clear;
    for I := 0 to Labels.Count - 1 do
      L.Add(Format('%d,%s,%s,,%s,,%d', [Labels[I].ID, CsvQ(Labels[I].Name),
        B64(Labels[I].Comment), Iso(Labels[I].When), Labels[I].LabelType]));
    SaveList(TPath.Combine(OutDir, 'labels.csv'),
      'label_id,name,comment_b64,created_by,created_utc,root_project,label_type', L);

    L.Clear;
    for I := 0 to Attachments.Count - 1 do
      L.Add(Format('%d,%d,%s', [Attachments[I].LabelID, Attachments[I].FileID,
        CsvQ(Attachments[I].Revision)]));
    SaveList(TPath.Combine(OutDir, 'label_attachments.csv'), 'label_id,file_id,revision', L);

    L.Clear;
    for I := 0 to Views.Count - 1 do
      L.Add(Format('%d,%s,%s,,,%s,,', [Views[I].ID, CsvQ(Views[I].Name),
        B64(Views[I].Description), BoolToStr(Views[I].Shared, True)]));
    SaveList(TPath.Combine(OutDir, 'views.csv'),
      'view_id,name,description_b64,basis,basis_value,shared,owner,projects', L);

    L.Clear;
    for I := 0 to Folders.Count - 1 do
      L.Add(Format('%d,%d,%s,%s,%d', [Folders[I].ID, Folders[I].ParentID,
        CsvQ(Folders[I].Name), CsvQ(Folders[I].TCPath), Folders[I].FileCount]));
    SaveList(TPath.Combine(OutDir, 'folders.csv'),
      'folder_id,parent_id,name,tc_path,file_count', L);
  finally
    L.Free;
  end;
  Log('Metadata written to ' + OutDir);
end;

end.
