program TCDump;
{
  TCDump - Team Coherence metadata extractor for the TC -> git migration.
  Win32 console application (the TC DLLs are 32-bit: build with dcc32, NOT dcc64).

    TCDump.exe -probe                                 which API entry points are available
    TCDump.exe -connect -user <u> [-pwd <p>]          test a session only
    TCDump.exe -raw     -user <u> [-pwd <p>]          show the first rows of each enumerator
    TCDump.exe -extract -out <dir> -user <u> [-pwd <p>]   write the metadata CSVs

  All signatures below are the documented ones from TCVcsApi.chm (shipped in the TC client
  Bin folder; extract it with:  hh.exe -decompile <outdir> TCVcsApi.chm  - copy it out of
  Program Files first, or the decompile silently produces nothing).

  Measured 2026-09-23: without TCDVcsConnect every enumerator returns 80 = Err_NotConnected.
  TCDVcsConnect must be called before anything else.

  Everything here is READ-ONLY. No TC object is created, modified or deleted.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.NetEncoding,
  System.DateUtils,
  System.IOUtils,
  System.Hash,
  Winapi.Windows;

const
  DLL_CORE = 'GPVCCore.dll';
  DLL_MAIN = 'GPVMain.dll';

  Err_OK           = 0;
  Err_NotConnected = 80;

  lt_VersionLabel   = 1;
  lt_PromotionLabel = 2;

type
  // TC 7.1 was built before Delphi 2009, so the "PChar" in TCVcsApi.chm means PAnsiChar.
  // Passing PWideChar here returns garbage strings and makes the login see "A" for "Alice".
  PTCChar = PAnsiChar;

  // ---- documented in TCVcsApi.chm -------------------------------------------------------
  TIntEnumProjects = function(Context, Data: Pointer; pName: PTCChar;
    ID: Cardinal): Boolean; stdcall;

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

  // ---- content retrieval, documented in TCVcsApi.chm as "Get or Check out a file" --------
  //
  // This is the call the migrator does NOT use, and should: it fetches one revision by file id
  // straight through the DLL, on the session already open, with no tc.exe process to start.
  // A bare `tc Whoami` costs ~930 ms before it does any work at all.
  //
  // Lock := False makes it a pure READ. That is not a trick: QSC's own help titles the page
  // "Get or Check out a file", and the Lock field is what chooses between the two. Nothing here
  // writes to the repository.
  //
  // Buffer sizes are the ones InitializeCheckOutInfo uses (TCVcsUtils.pas): the DLL writes back
  // into these, so they must be allocated, not pointed at Delphi strings.
  //
  // Flags is NOT in the 7.1 documented record but IS in later headers. It is included and
  // zeroed: a 7.1 DLL ignores the trailing field, while omitting one a newer DLL expects would
  // have it read whatever follows on the stack.
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

  TFnCheckOutFile  = function(FileID: Cardinal; var RevisionID: Cardinal;
                              Info: PCheckOutInfo): Integer; stdcall;

  TFnConnect       = function(pConnection, pName, pPassword: PTCChar): Integer; stdcall;
  TFnLogin         = function: Boolean; stdcall;   // TC's own login dialog
  // "should be called before any other functions are called. May prompt for a Connection,
  // Username and Password." Calling TCVcsLogin without it dies on a nil object.
  TFnVcsInit       = function(Handle: Cardinal; LoadCache: Boolean; ProgressProc: Pointer): Integer; stdcall;
  TFnEnumConns     = function(Context, Data: Pointer; EnumProc: TIntEnumConnections): Integer; stdcall;
  TFnDisconnect    = function: Integer; stdcall;
  TFnEnumProjects  = function(Context, Data: Pointer; EnumProc: TIntEnumProjects): Integer; stdcall;
  TFnEnumFolders   = function(RootID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumFolders; Recursive: Boolean): Integer; stdcall;
  TFnEnumFiles     = function(RootID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumFiles; Recursive: Boolean): Integer; stdcall;
  TFnEnumRevisions = function(FileID: Cardinal; Context, Data: Pointer; EnumProc: TIntEnumRevisions): Integer; stdcall;
  TFnEnumLabels    = function(RootID, RevID: Cardinal; LabelType: Integer; Context, Data: Pointer; EnumProc: TIntEnumLabels): Integer; stdcall;
  TFnEnumViews     = function(Context, Data: Pointer; EnumProc: TIntEnumViews): Integer; stdcall;

var
  CoreLib, MainLib: HMODULE;
  BinDir, OutDir: string;
  ConnName: string = '';   // pass -conn <name>; empty means the client's first connection
  UserName: string = '';
  Password: string = '';
  ModeProbe: Boolean = False;
  ModeRaw: Boolean = False;
  ModeExtract: Boolean = False;
  ModeConnect: Boolean = False;
  ModeDialog: Boolean = False;
  ModeConns: Boolean = False;
  ModeGet: Boolean = False;
  GetList: string = '';      // a file of "file_id,revision" lines
  GetFileID: Cardinal = 0;
  GetRev: string = '';
  RootID: Cardinal = 0;
  RawLeft: Integer = 0;
  Connected: Boolean = False;
  CurrentFileID: Cardinal = 0;

  FoldersCsv, FilesCsv, RevsCsv, LabelsCsv, ViewsCsv, ProjectsCsv: TStringList;
  FileIds: TStringList;       // file_id=name
  RevIds: TStringList;        // rev_id=file_id|revision - drives the label-attachment pass
  AttachCsv: TStringList;
  CurRevName: string;

// ---------------------------------------------------------------- helpers

procedure Say(const S: string); begin Writeln(S); end;

function ErrName(Code: Integer): string;
begin
  case Code of
    0:  Result := 'Err_OK';
    6:  Result := 'Err_CannotFindRevision';
    14: Result := 'Err_InsufficientAccess';
    29: Result := 'Err_InvalidPassword';
    40: Result := 'Err_ObjectNotFound';
    48: Result := 'Err_NotLoggedIn';
    49: Result := 'Err_ConnectionNotDefined';
    73: Result := 'Err_NoRevisions';
    75: Result := 'Err_NoLicenses';
    78: Result := 'Err_InvalidConnection';
    79: Result := 'Err_AlreadyConnected';
    80: Result := 'Err_NotConnected';
    81: Result := 'Err_CouldNotConnectToServer';
    82: Result := 'Err_VersionDoesNotExist';
  else
    Result := 'code ' + IntToStr(Code);
  end;
end;

function B64(const S: string): string;
begin
  if S = '' then Exit('');
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(S));
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
end;

function CsvQ(const S: string): string;
begin
  if (Pos(',', S) > 0) or (Pos('"', S) > 0) or (Pos(#10, S) > 0) or (Pos(#13, S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

function UnixToIso(TS: Integer): string;
begin
  if TS <= 0 then Exit('');
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', UnixToDateTime(Int64(TS), False));
end;

function Api(const Name: string): Pointer;
begin
  Result := nil;
  if CoreLib <> 0 then Result := GetProcAddress(CoreLib, PChar(Name));
  if (Result = nil) and (MainLib <> 0) then Result := GetProcAddress(MainLib, PChar(Name));
end;

// ---------------------------------------------------------------- content retrieval

function NewCheckOutInfo: PCheckOutInfo;
begin
  New(Result);
  GetMem(Result.Comments, 65536);  Result.Comments^ := #0;
  GetMem(Result.Extra, 65536);     Result.Extra^ := #0;
  GetMem(Result.Revision, 255);    Result.Revision^ := #0;
  GetMem(Result.LocalPath, 512);   Result.LocalPath^ := #0;
  Result.VersionID := 0;
  Result.AssignVersionID := 0;
  Result.Overwrite := True;     // we always fetch into a fresh empty folder
  Result.Lock := False;         // READ ONLY - see the comment on TCheckOutInfo
  Result.Flags := 0;
end;

procedure FreeCheckOutInfo(Info: PCheckOutInfo);
begin
  if Info = nil then Exit;
  FreeMem(Info.Comments);
  FreeMem(Info.Extra);
  FreeMem(Info.Revision);
  FreeMem(Info.LocalPath);
  Dispose(Info);
end;

// Fetches one revision into DestDir, which must exist and should be empty so that whatever
// arrives can be attributed. A Team Coherence archive is a file GROUP, so one call can produce
// several files (MyForm.pas brings MyForm.dfm), which is why the caller lists the folder
// rather than assuming a single name.
function GetRevision(FileID: Cardinal; const Rev, DestDir: string;
  var RevIDOut: Cardinal): Integer;
var
  Fn: TFnCheckOutFile;
  Info: PCheckOutInfo;
  ARev, ADir: AnsiString;
begin
  Fn := Api('TCDVcsCheckOutFile');
  if not Assigned(Fn) then
  begin
    Say('TCDVcsCheckOutFile is not exported by this client build.');
    Exit(-1);
  end;
  Info := NewCheckOutInfo;
  try
    ARev := AnsiString(Rev);
    ADir := AnsiString(DestDir);
    if Length(ARev) > 254 then Exit(-2);
    if Length(ADir) > 511 then Exit(-2);
    StrPLCopy(Info.Revision, ARev, 254);
    StrPLCopy(Info.LocalPath, ADir, 511);
    RevIDOut := 0;
    Result := Fn(FileID, RevIDOut, Info);
  finally
    FreeCheckOutInfo(Info);
  end;
end;

function RawOk: Boolean;   // in -raw mode, print at most 15 rows per enumerator
begin
  if not ModeRaw then Exit(True);
  Dec(RawLeft);
  Result := RawLeft > 0;
end;

// ---------------------------------------------------------------- callbacks

function CbProjects(Context, Data: Pointer; pName: PTCChar; ID: Cardinal): Boolean; stdcall;
begin
  if ModeRaw then Say(Format('  project id=%d name="%s"', [ID, string(pName)]));
  ProjectsCsv.Add(Format('%d,%s', [ID, CsvQ(string(pName))]));
  Result := RawOk;
end;

function CbFolders(Context, Data: Pointer; pName, pTCPath, pLocalFolder: PTCChar;
  ID, ParentID: Cardinal; FolderCount, FileCount: Integer): Boolean; stdcall;
begin
  if ModeRaw then
    Say(Format('  folder id=%d parent=%d name="%s" tcpath="%s" folders=%d files=%d',
      [ID, ParentID, string(pName), string(pTCPath), FolderCount, FileCount]));
  FoldersCsv.Add(Format('%d,%d,%s,%s,%d,%d',
    [ID, ParentID, CsvQ(string(pName)), CsvQ(string(pTCPath)), FolderCount, FileCount]));
  Result := RawOk;
end;

function CbFiles(Context, Data: Pointer; pName, pLocalPath, pLockedBy: PTCChar;
  ID, ParentID, AncestorID: Cardinal;
  Modified, Timestamp, CompressedSize, RevisionCount, ShareCount, Status: Integer;
  IsVirtual, Frozen: Boolean): Boolean; stdcall;
begin
  if ModeRaw then
    Say(Format('  file id=%d parent=%d name="%s" revs=%d shares=%d local="%s"',
      [ID, ParentID, string(pName), RevisionCount, ShareCount, string(pLocalPath)]));
  FilesCsv.Add(Format('%d,%s,%s,,%d,%d,%s,%s',
    [ID, CsvQ(string(pName)), CsvQ(string(pLocalPath)), RevisionCount, ShareCount,
     BoolToStr(IsVirtual, True), BoolToStr(Frozen, True)]));
  FileIds.Add(Format('%d=%s', [ID, string(pName)]));
  Result := RawOk;
end;

function CbRevisions(Context, Data: Pointer; pName, pAuthor, pComments, pLockedBy: PTCChar;
  ID, ParentID: Cardinal;
  Modified, Timestamp, CompressedSize, OriginalSize, CRC, VerCount, PromoCount: Integer): Boolean; stdcall;
begin
  if ModeRaw then
    Say(Format('  rev "%s" author="%s" ts=%s size=%d id=%d parent=%d comment="%s"',
      [string(pName), string(pAuthor), UnixToIso(Timestamp), OriginalSize, ID, ParentID,
       Copy(string(pComments), 1, 50)]));
  // file_id,tc_path,revision,author,timestamp_utc,comment_b64,action,size
  RevIds.Add(Format('%d=%d|%s', [ID, CurrentFileID, string(pName)]));
  RevsCsv.Add(Format('%d,,%s,%s,%s,%s,modify,%d',
    [CurrentFileID, CsvQ(string(pName)), CsvQ(string(pAuthor)), UnixToIso(Timestamp),
     B64(string(pComments)), OriginalSize]));
  Result := RawOk;
end;

function CbAttach(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
  ID: Cardinal; Timestamp: Integer): Boolean; stdcall;
begin
  // Called once per label attached to the revision being asked about. This list IS the
  // label: the importer rebuilds exactly this tree, so a label spanning mixed revisions
  // still produces a byte-exact tag.
  AttachCsv.Add(Format('%d,%d,%s', [ID, CurrentFileID, CsvQ(CurRevName)]));
  Result := True;
end;

function CbLabels(Context, Data: Pointer; LabelType: Integer; pName, pComments: PTCChar;
  ID: Cardinal; Timestamp: Integer): Boolean; stdcall;
begin
  if ModeRaw then
    Say(Format('  label id=%d type=%d name="%s" ts=%s comment="%s"',
      [ID, LabelType, string(pName), UnixToIso(Timestamp), Copy(string(pComments), 1, 40)]));
  LabelsCsv.Add(Format('%d,%s,%s,,%s,,%d',
    [ID, CsvQ(string(pName)), B64(string(pComments)), UnixToIso(Timestamp), LabelType]));
  Result := RawOk;
end;

function CbViews(Context, Data: Pointer; pName, pDescription: PTCChar;
  ID: Cardinal; Shared, Current: Boolean): Boolean; stdcall;
begin
  if ModeRaw then
    Say(Format('  view id=%d name="%s" shared=%s current=%s desc="%s"',
      [ID, string(pName), BoolToStr(Shared, True), BoolToStr(Current, True), string(pDescription)]));
  ViewsCsv.Add(Format('%d,%s,%s,,,%s,,', [ID, CsvQ(string(pName)), B64(string(pDescription)),
    BoolToStr(Shared, True)]));
  Result := RawOk;
end;

function CbConns(Context, Data: Pointer; pName, pDescription, pHost: PTCChar;
  Port: Integer; Current: Boolean): Boolean; stdcall;
begin
  Say(Format('  %-20s host=%s:%d  %s  "%s"',
    [string(pName), string(pHost), Port,
     IfThen(Current, '(current)', '         '), string(pDescription)]));
  Result := True;
end;

procedure ListConnections;
var
  Fn: TFnEnumConns;
begin
  Fn := Api('TCDVcsEnumConnections');
  if not Assigned(Fn) then begin Say('TCDVcsEnumConnections not exported'); Exit; end;
  Say('Defined connections (names and hosts only - no credentials are read):');
  Say(Format('  -> %s', [ErrName(Fn(nil, nil, CbConns))]));
end;

// ---------------------------------------------------------------- credentials

function PromptHidden(const Prompt: string): string;
var
  H: THandle;
  Mode: DWORD;
begin
  Mode := 0;
  Write(Prompt);
  H := GetStdHandle(STD_INPUT_HANDLE);
  if GetConsoleMode(H, Mode) then
    SetConsoleMode(H, Mode and not ENABLE_ECHO_INPUT);
  try
    Readln(Result);
  finally
    if Mode <> 0 then SetConsoleMode(H, Mode);
  end;
  Writeln;
end;

// ---------------------------------------------------------------- session

function Connect: Boolean;
var
  Fn: TFnConnect;
  LoginFn: TFnLogin;
  InitFn: TFnVcsInit;
  AConn, AUser, APwd: AnsiString;
  Code: Integer;
begin
  // Default path. TCVcsInitialize + TCVcsLogin reuse the credentials the TC client already
  // holds, so no password is needed here at all - confirmed live 2026-09-23.
  // -dialog hands the whole thing to TC''s own login dialog, so whatever credential this
  // site expects (password, Windows user, an encryption key the server asks for) is entered
  // in the client''s UI rather than here. Nothing is typed into, or seen by, this program.
  if ModeDialog or (UserName = '') then
  begin
    InitFn := Api('TCVcsInitialize');
    if Assigned(InitFn) then
    begin
      Say('TCVcsInitialize (may prompt for connection and login)...');
      // LoadCache=False: we only want a session, not the client's local cache.
      Say(Format('  -> %s', [ErrName(InitFn(0, False, nil))]));
    end;
    LoginFn := Api('TCVcsLogin');
    if not Assigned(LoginFn) then begin Say('TCVcsLogin not exported'); Exit(False); end;
    Say('Opening the Team Coherence login dialog...');
    Result := LoginFn();
    Say(Format('  dialog returned %s', [BoolToStr(Result, True)]));
    Connected := Result;
    Exit;
  end;

  Fn := Api('TCDVcsConnect');
  if not Assigned(Fn) then begin Say('TCDVcsConnect not exported'); Exit(False); end;
  if UserName = '' then begin Write('TC user: '); Readln(UserName); end;
  // Never accept the password on the command line by default: it would sit in the
  // process list and the shell history. Prompt with the echo off instead.
  if Password = '' then Password := PromptHidden('TC password: ');
  // ANSI, not PChar: see PTCChar above.
  AConn := AnsiString(ConnName); AUser := AnsiString(UserName); APwd := AnsiString(Password);
  Code := Fn(PAnsiChar(AConn), PAnsiChar(AUser), PAnsiChar(APwd));
  Say(Format('TCDVcsConnect("%s", "%s", %s) -> %s',
    [ConnName, UserName, IfThen(Password = '', '<empty>', '<supplied>'), ErrName(Code)]));
  Result := (Code = Err_OK) or (Code = 79 { already connected });
  Connected := Result;
end;

procedure Disconnect;
var
  Fn: TFnDisconnect;
begin
  if not Connected then Exit;
  Fn := Api('TCDVcsDisconnect');
  if Assigned(Fn) then Fn();
  Connected := False;
end;

// ---------------------------------------------------------------- work

procedure EnumerateAll;
var
  FnProjects: TFnEnumProjects;
  FnFolders: TFnEnumFolders;
  FnFiles: TFnEnumFiles;
  FnRevs: TFnEnumRevisions;
  FnLabels: TFnEnumLabels;
  FnViews: TFnEnumViews;
  Roots: TStringList;
  Rc, I, R: Integer;
  ThisRoot: Cardinal;
  Parts: string;
begin
  Roots := TStringList.Create;
  try
    Say('Projects...');
    FnProjects := Api('TCDVcsEnumProjects');
    if Assigned(FnProjects) then
    begin
      RawLeft := 15;
      Rc := FnProjects(nil, nil, CbProjects);
      Say(Format('  %s, %d project(s)', [ErrName(Rc), ProjectsCsv.Count]));
    end;

    // -root 0 means "every project". The repository has Documents, Source and ThirdParty,
    // and a 1-to-1 migration wants all of them, not just the first one.
    if RootID <> 0 then
      Roots.Add(UIntToStr(RootID))
    else
      for I := 0 to ProjectsCsv.Count - 1 do
        Roots.Add(Copy(ProjectsCsv[I], 1, Pos(',', ProjectsCsv[I]) - 1));
    Say(Format('  enumerating %d root(s): %s', [Roots.Count, StringReplace(Roots.Text, sLineBreak, ' ', [rfReplaceAll])]));

    FnFolders := Api('TCDVcsEnumFolders');
    FnFiles   := Api('TCDVcsEnumFiles');
    FnLabels  := Api('TCDVcsEnumLabels');

    for R := 0 to Roots.Count - 1 do
    begin
      ThisRoot := StrToUIntDef(Roots[R], 0);
      Say(Format('Root %d:', [ThisRoot]));

      if Assigned(FnFolders) then
      begin
        RawLeft := 15;
        Rc := FnFolders(ThisRoot, nil, nil, CbFolders, True);
        Say(Format('  folders: %s, %d total', [ErrName(Rc), FoldersCsv.Count]));
      end;

      if Assigned(FnFiles) then
      begin
        RawLeft := 15;
        Rc := FnFiles(ThisRoot, nil, nil, CbFiles, True);
        Say(Format('  files:   %s, %d total', [ErrName(Rc), FilesCsv.Count]));
      end;

      if Assigned(FnLabels) then
      begin
        RawLeft := 15;
        FnLabels(ThisRoot, 0, lt_VersionLabel, nil, nil, CbLabels);
        RawLeft := 15;
        FnLabels(ThisRoot, 0, lt_PromotionLabel, nil, nil, CbLabels);
        Say(Format('  labels:  %d total', [LabelsCsv.Count]));
      end;
    end;

    Say('Revisions...');
    FnRevs := Api('TCDVcsEnumRevisions');
    if Assigned(FnRevs) then
    begin
      RawLeft := 15;
      if ModeRaw then
      begin
        if FileIds.Count > 0 then
        begin
          CurrentFileID := StrToUIntDef(FileIds.Names[0], 0);
          FnRevs(CurrentFileID, nil, nil, CbRevisions);
        end;
      end
      else
        for I := 0 to FileIds.Count - 1 do
        begin
          CurrentFileID := StrToUIntDef(FileIds.Names[I], 0);
          FnRevs(CurrentFileID, nil, nil, CbRevisions);
          if (I mod 200) = 0 then Write(Format(#13'  %d/%d files', [I, FileIds.Count]));
        end;
      if not ModeRaw then Writeln;
      Say(Format('  %d revision(s)', [RevsCsv.Count]));
    end;

    // One call per revision: TCDVcsEnumLabels takes a RevID, so this returns exactly which
    // revision each label points at - the thing that makes a tag byte-exact.
    if (not ModeRaw) and Assigned(FnLabels) and (RevIds.Count > 0) then
    begin
      Say('Label attachments (one call per revision)...');
      for I := 0 to RevIds.Count - 1 do
      begin
        Parts := RevIds.ValueFromIndex[I];
        CurrentFileID := StrToUIntDef(Copy(Parts, 1, Pos('|', Parts) - 1), 0);
        CurRevName := Copy(Parts, Pos('|', Parts) + 1, MaxInt);
        FnLabels(StrToUIntDef(Roots[0], 0), StrToUIntDef(RevIds.Names[I], 0),
                 lt_VersionLabel, nil, nil, CbAttach);
        if (I mod 500) = 0 then Write(Format(#13'  %d/%d revisions', [I, RevIds.Count]));
      end;
      Writeln;
      Say(Format('  %d attachment(s)', [AttachCsv.Count]));
    end;

    Say('Views...');
    FnViews := Api('TCDVcsEnumViews');
    if Assigned(FnViews) then
    begin
      RawLeft := 15;
      Rc := FnViews(nil, nil, CbViews);
      Say(Format('  %s, %d view(s)', [ErrName(Rc), ViewsCsv.Count]));
    end;
  finally
    Roots.Free;
  end;
end;

procedure SaveCsv(List: TStringList; const FileName, Header: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(Header);
    Lines.AddStrings(List);
    Lines.WriteBOM := False;
    Lines.SaveToFile(TPath.Combine(OutDir, FileName), TEncoding.UTF8);
    Say(Format('  %-24s %d rows', [FileName, List.Count]));
  finally
    Lines.Free;
  end;
end;

procedure DoProbe;
const
  Names: array[0..9] of string = (
    'TCDVcsConnect', 'TCDVcsDisconnect', 'TCDVcsEnumProjects', 'TCDVcsEnumFolders',
    'TCDVcsEnumFiles', 'TCDVcsEnumRevisions', 'TCDVcsEnumLabels', 'TCDVcsEnumViews',
    'TCDVcsGetBranchInfo', 'TCDVcsGetObjectNotes');
var
  I, Found: Integer;
begin
  Found := 0;
  Say('Entry points (signatures from TCVcsApi.chm):');
  for I := Low(Names) to High(Names) do
    if Api(Names[I]) <> nil then begin Say('  available  ' + Names[I]); Inc(Found); end
    else Say('  MISSING    ' + Names[I]);
  Say(Format('%d of %d available', [Found, Length(Names)]));
  Say('');
  Say('Note: every enumerator returns Err_NotConnected (80) until TCDVcsConnect succeeds.');
end;

// ---------------------------------------------------------------- main

// Fetches revisions through the DLL and reports the SHA-256 of everything that arrives, so the
// output can be compared against meta\blobs.csv from a migration that used tc.exe. Equal hashes
// prove the two routes return identical bytes; that is the whole point of this mode.
procedure DoGetRevisions;
var
  Lines: TStringList;
  I, Rc, Okc, Failc: Integer;
  Parts: TArray<string>;
  Fid, RevID: Cardinal;
  Rev, Dest, F: string;
  Produced: TArray<string>;
begin
  Lines := TStringList.Create;
  try
    if GetList <> '' then
    begin
      if not FileExists(GetList) then begin Say('no such list file: ' + GetList); Halt(2); end;
      Lines.LoadFromFile(GetList);
    end
    else
      Lines.Add(Format('%d,%s', [GetFileID, GetRev]));

    Okc := 0; Failc := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then Continue;
      if StartsText('file_id', Lines[I]) then Continue;   // tolerate a CSV header
      Parts := Lines[I].Split([',']);
      if Length(Parts) < 2 then begin Say('skipping unparsable line: ' + Lines[I]); Continue; end;
      Fid := StrToUIntDef(Trim(Parts[0]), 0);
      Rev := Trim(Parts[1]);
      if (Fid = 0) or (Rev = '') then begin Say('skipping: ' + Lines[I]); Continue; end;

      // a fresh empty folder per revision, so whatever arrives can be attributed to it
      Dest := TPath.Combine(OutDir, Format('%d_%s', [Fid, StringReplace(Rev, '.', '_', [rfReplaceAll])]));
      if TDirectory.Exists(Dest) then TDirectory.Delete(Dest, True);
      ForceDirectories(Dest);

      RevID := 0;
      Rc := GetRevision(Fid, Rev, Dest, RevID);
      Produced := TDirectory.GetFiles(Dest, '*', TSearchOption.soAllDirectories);
      Say(Format('%d %s -> %s  revid=%d  files=%d',
        [Fid, Rev, ErrName(Rc), RevID, Length(Produced)]));
      for F in Produced do
        Say(Format('    %-44s %10d  %s',
          [ExtractFileName(F), TFile.GetSize(F),
           LowerCase(THashSHA2.GetHashStringFromFile(F, SHA256))]));
      if (Rc = Err_OK) and (Length(Produced) > 0) then Inc(Okc) else Inc(Failc);
    end;

    Say('');
    Say(Format('%d fetched, %d failed', [Okc, Failc]));
  finally
    Lines.Free;
  end;
end;

procedure Usage;
begin
  Say('TCDump - Team Coherence metadata extractor (Win32, read-only)');
  Say('');
  Say('  TCDump.exe -probe');
  Say('  TCDump.exe -connections                        list the defined connections');
  Say('  TCDump.exe -connect -user <u> [-pwd <p>]        log in with a password');
  Say('  TCDump.exe -connect -dialog                     log in via TC''s own dialog');
  Say('  TCDump.exe -raw     -user <u> [-pwd <p>]');
  Say('  TCDump.exe -extract -out <dir> -user <u> [-pwd <p>] [-root <id>]');
  Say('');
  Say('  TCDump.exe -getrev -out <dir> -user <u> [-pwd <p>] -file <id> -rev <1.x>');
  Say('  TCDump.exe -getrev -out <dir> -user <u> [-pwd <p>] -list <file_id,revision file>');
  Say('        Fetch revisions through the DLL instead of tc.exe and print the SHA-256 of');
  Say('        everything that arrives, for comparison with meta\blobs.csv. Read-only: the');
  Say('        checkout is made with Lock=False, which QSC''s help calls a Get.');
end;

var
  I: Integer;
  A: string;
begin
  try
    BinDir := 'C:\Program Files (x86)\Qsc\Team Coherence\Client\Bin';
    I := 1;
    while I <= ParamCount do
    begin
      A := LowerCase(ParamStr(I));
      if A = '-probe' then ModeProbe := True
      else if A = '-raw' then ModeRaw := True
      else if A = '-extract' then ModeExtract := True
      else if A = '-connect' then ModeConnect := True
      else if A = '-dialog' then ModeDialog := True
      else if A = '-connections' then ModeConns := True
      else if (A = '-bin')  and (I < ParamCount) then begin Inc(I); BinDir := ParamStr(I); end
      else if (A = '-out')  and (I < ParamCount) then begin Inc(I); OutDir := ParamStr(I); end
      else if (A = '-conn') and (I < ParamCount) then begin Inc(I); ConnName := ParamStr(I); end
      else if (A = '-user') and (I < ParamCount) then begin Inc(I); UserName := ParamStr(I); end
      else if (A = '-pwd')  and (I < ParamCount) then begin Inc(I); Password := ParamStr(I); end
      else if (A = '-root') and (I < ParamCount) then begin Inc(I); RootID := StrToUIntDef(ParamStr(I), 0); end
      else if A = '-getrev' then ModeGet := True
      else if (A = '-list') and (I < ParamCount) then begin Inc(I); GetList := ParamStr(I); end
      else if (A = '-file') and (I < ParamCount) then begin Inc(I); GetFileID := StrToUIntDef(ParamStr(I), 0); end
      else if (A = '-rev')  and (I < ParamCount) then begin Inc(I); GetRev := ParamStr(I); end
      else begin Usage; Halt(2); end;
      Inc(I);
    end;

    if not (ModeProbe or ModeRaw or ModeExtract or ModeConnect or ModeConns or ModeGet) then begin Usage; Halt(2); end;
    if ModeExtract and (OutDir = '') then begin Say('-extract needs -out <dir>'); Halt(2); end;
    if ModeGet then
    begin
      if OutDir = '' then begin Say('-getrev needs -out <dir>'); Halt(2); end;
      if (GetList = '') and ((GetFileID = 0) or (GetRev = '')) then
      begin
        Say('-getrev needs either -list <file> or both -file <id> and -rev <1.x>');
        Halt(2);
      end;
    end;

    SetDllDirectory(PChar(BinDir));
    CoreLib := LoadLibrary(PChar(IncludeTrailingPathDelimiter(BinDir) + DLL_CORE));
    MainLib := LoadLibrary(PChar(IncludeTrailingPathDelimiter(BinDir) + DLL_MAIN));
    if CoreLib = 0 then
    begin
      Say(Format('cannot load %s from %s (error %d) - is this a 32-bit build?',
        [DLL_CORE, BinDir, GetLastError]));
      Halt(3);
    end;

    ProjectsCsv := TStringList.Create; FoldersCsv := TStringList.Create;
    FilesCsv := TStringList.Create;    RevsCsv := TStringList.Create;
    LabelsCsv := TStringList.Create;   ViewsCsv := TStringList.Create;
    FileIds := TStringList.Create;   RevIds := TStringList.Create;
    AttachCsv := TStringList.Create;
    try
      if ModeProbe then begin DoProbe; Halt(0); end;
      if ModeConns then begin ListConnections; Halt(0); end;

      if not Connect then
      begin
        Say('');
        Say('Could not establish a session. TCDVcsConnect takes (connection, user, password);');
        Say('pass -user and -pwd. The CLI session from tc.exe is NOT shared with the DLL.');
        Halt(4);
      end;
      if ModeConnect then begin Say('session established'); Disconnect; Halt(0); end;

      // before EnumerateAll: fetching needs the session, not the metadata, and enumerating
      // everything first would cost the best part of an hour for nothing
      if ModeGet then
      begin
        ForceDirectories(OutDir);
        DoGetRevisions;
        Disconnect;
        Halt(0);
      end;

      if ModeExtract then ForceDirectories(OutDir);
      EnumerateAll;

      if ModeExtract then
      begin
        Say('');
        Say('Writing CSVs:');
        SaveCsv(ProjectsCsv, 'projects.csv',  'project_id,name');
        SaveCsv(FoldersCsv,  'folders.csv',   'folder_id,parent_id,name,tc_path,folder_count,file_count');
        SaveCsv(FilesCsv,    'files.csv',     'file_id,name,local_path,git_path,revision_count,share_count,is_virtual,frozen');
        SaveCsv(RevsCsv,     'revisions.csv', 'file_id,tc_path,revision,author,timestamp_utc,comment_b64,action,size');
        SaveCsv(LabelsCsv,   'labels.csv',    'label_id,name,comment_b64,created_by,created_utc,root_project,label_type');
        SaveCsv(AttachCsv,   'label_attachments.csv', 'label_id,file_id,revision');
        SaveCsv(ViewsCsv,    'views.csv',     'view_id,name,description_b64,basis,basis_value,shared,owner,projects');
        Say('');
        Say('Next: fill tc_path in files.csv/revisions.csv from folders.csv, then run');
        Say('  ..\ps\20-FetchRevisions.ps1  and  ..\node\30-BuildFastImport.js');
      end;

      Disconnect;
    finally
      ProjectsCsv.Free; FoldersCsv.Free; FilesCsv.Free;
      RevsCsv.Free; LabelsCsv.Free; ViewsCsv.Free; FileIds.Free;
      RevIds.Free; AttachCsv.Free;
      if CoreLib <> 0 then FreeLibrary(CoreLib);
      if MainLib <> 0 then FreeLibrary(MainLib);
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR: ' + E.Message);
      Halt(1);
    end;
  end;
end.

