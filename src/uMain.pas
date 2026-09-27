unit uMain;
{
  TC Migrator - operator window.

  The form is built in code on purpose: no .dfm, no .res, so the whole application is plain
  source that compiles with a single dcc32 command and has nothing binary to drift.

  Everything runs on the main thread with Application.ProcessMessages pumped inside the long
  loops. The Team Coherence DLLs date from 2009 and are not documented as thread-safe, so the
  UI stays responsive without ever calling them from a background thread.
}

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.IOUtils,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  Vcl.Dialogs, Vcl.CheckLst, Winapi.Windows, Winapi.Messages,
  System.Generics.Collections, System.Types,
  uTCApi, uPipeline, uWorker;

type
  TMainForm = class(TForm)
  private
    // settings
    edTcBin, edWork, edBranch, edWindow, edAuthors, edLimit, edThreads: TEdit;
    cbTags: TCheckBox;
    lbProjects: TCheckListBox;
    // actions
    btnConnect, btnRefresh, btnRun, btnStop, btnOpen: TButton;
    // feedback
    pbOverall, pbPhase: TProgressBar;
    lblPhase, lblStatus, lblDetail, lblCounters, lblOverall, lblBanner: TLabel;
    FPhaseStarted: TDateTime;
    FPhaseName: string;
    FRunStart: TDateTime;
    FRunFrom: Integer;
    memLog: TMemo;
    FSession: TTCSession;
    FCancel: Boolean;
    FRunning: Boolean;
    FStep, FSteps: Integer;
    // unattended mode (testing / scheduled runs) - see ParseCommandLine
    FAuto: Boolean;
    FLayoutCheck: Boolean;
    FAutoProjects: string;
    FTcUser, FTcPwd, FTcConn: string;   // optional non-interactive login; never persisted
    FAutoLog: string;
    FLogWriter: TStreamWriter;   // opened once; TFile.AppendAllText needs the file to exist
    FLogStream: TFileStream;     // opened shared so the log can be read while it is running
    FAutoTimer: TTimer;
    FExitTimer: TTimer;
    // Fetch content through TCDVcsCheckOutFile rather than by spawning tc.exe (--dll).
    FUseDll: Boolean;
    // Name of the bare repository inside the work folder (--repo). Default repo.git.
    FRepoName: string;
    FWorker: TMigrationThread;
    // layout metrics, all derived from the rendered font in BuildUi
    FRowH, FBtnH, FPad, FGap, FLineH: Integer;
    procedure ParseCommandLine;
    procedure AutoTick(Sender: TObject);
    procedure ForceExit(Sender: TObject);
    procedure FinishAuto(Code: Integer);
    procedure BuildUi;
    function TextW(const S: string): Integer;
    function LayoutReport: string;
    function NewLabel(Parent: TWinControl; const Text: string; Bold: Boolean = False): TLabel;
    function NewEdit(Parent: TWinControl; const Text: string): TEdit;
    function NewButton(Parent: TWinControl; const Caption: string; OnClick: TNotifyEvent): TButton;
    procedure LoadSettings;
    procedure SaveSettings;
    function SettingsFile: string;
    procedure DoLog(const Msg: string);
    procedure DoItem(const Detail: string);
    procedure DoCounters(const S: string);
    procedure DoOverall(const Phase: string; Done, Total: Integer);
    procedure DoProgress(const Phase: string; Done, Total: Integer);
    function DoCancel: Boolean;
    procedure SetBusy(Busy: Boolean);
    procedure NextStep(const Name: string);
    procedure ConnectClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
    procedure WorkerDone(Success: Boolean; const Summary: string);
    procedure StopClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

uses
  Winapi.ShellAPI, System.Math, System.DateUtils;

const
  DEF_TCBIN = 'C:\Program Files (x86)\Qsc\Team Coherence\Client\Bin';

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FUseDll := True;   // measured faster AND more accurate than spawning tc.exe; --no-dll opts out
  BuildUi;
  LoadSettings;
  ParseCommandLine;
  if FLayoutCheck then
  begin
    DoLog(LayoutReport);
    FinishAuto(IfThen(Pos('FAIL', LayoutReport) > 0, 1, 0));
    Exit;
  end;
  DoLog('TC Migrator ready.');
  DoLog('Nothing is written to Team Coherence: the only command ever issued is Get.');
  if FAuto then
  begin
    DoLog('Unattended mode: connecting and running without prompts.');
    // Start from a timer rather than the constructor so the window is painted first and
    // the log is visible while it works.
    FAutoTimer := TTimer.Create(Self);
    FAutoTimer.Interval := 400;
    FAutoTimer.OnTimer := AutoTick;
    FAutoTimer.Enabled := True;
  end;
end;

function TMainForm.LayoutReport: string;
// Self-check for the thing that actually goes wrong in a hand-built form: two controls
// sitting on top of each other at some font size or DPI. VCL labels are TGraphicControl
// and have no window handle, so an external tool cannot see them - the form has to check
// itself. Run with --layout-check.
var
  Items: TList<TControl>;
  SB: TStringBuilder;
  Bad: Integer;

  procedure Collect(Parent: TWinControl);
  var
    I: Integer;
    C: TControl;
  begin
    for I := 0 to Parent.ControlCount - 1 do
    begin
      C := Parent.Controls[I];
      if not C.Visible then Continue;
      if C is TWinControl then
      begin
        // a container legitimately encloses its children, so recurse instead of testing it
        if (C is TGroupBox) or (C is TPanel) then
        begin
          Collect(TWinControl(C));
          Continue;
        end;
        Collect(TWinControl(C));
      end;
      Items.Add(C);
    end;
  end;

  function AbsRect(C: TControl): TRect;
  var
    P: TPoint;
  begin
    P := C.ClientToScreen(Point(0, 0));
    Result := Rect(P.X, P.Y, P.X + C.Width, P.Y + C.Height);
  end;

var
  I, J, OX, OY: Integer;
  A, B: TRect;
  Na, Nb: string;
begin
  Items := TList<TControl>.Create;
  SB := TStringBuilder.Create;
  try
    Collect(Self);
    Bad := 0;
    SB.AppendLine(Format('Layout check: %d visible controls, %d DPI, font %s %dpt',
      [Items.Count, Monitor.PixelsPerInch, Font.Name, Font.Size]));

    for I := 0 to Items.Count - 1 do
      for J := I + 1 to Items.Count - 1 do
      begin
        // skip anything nested inside the other
        if (Items[I].Parent = Items[J]) or (Items[J].Parent = Items[I]) then Continue;
        A := AbsRect(Items[I]);
        B := AbsRect(Items[J]);
        OX := Min(A.Right, B.Right) - Max(A.Left, B.Left);
        OY := Min(A.Bottom, B.Bottom) - Max(A.Top, B.Top);
        if (OX > 1) and (OY > 1) then
        begin
          Inc(Bad);
          if Items[I] is TLabel then Na := TLabel(Items[I]).Caption
          else Na := Items[I].Name + '/' + Items[I].ClassName;
          if Items[J] is TLabel then Nb := TLabel(Items[J]).Caption
          else Nb := Items[J].Name + '/' + Items[J].ClassName;
          SB.AppendLine(Format('  OVERLAP %dx%dpx: "%s" [%s] <-> "%s" [%s]',
            [OX, OY, Na, Items[I].ClassName, Nb, Items[J].ClassName]));
        end;
      end;

    // also catch anything hanging outside the window
    for I := 0 to Items.Count - 1 do
      if (Items[I].Left + Items[I].Width > Items[I].Parent.ClientWidth + 1) or
         (Items[I].Top + Items[I].Height > Items[I].Parent.ClientHeight + 1) then
      begin
        Inc(Bad);
        SB.AppendLine(Format('  CLIPPED: %s [%s] extends past its parent',
          [Items[I].Name + Items[I].ClassName, Items[I].ClassName]));
      end;

    if Bad = 0 then SB.AppendLine('  PASS - no overlapping or clipped controls')
    else SB.AppendLine(Format('  FAIL - %d problem(s)', [Bad]));
    Result := SB.ToString;
  finally
    SB.Free;
    Items.Free;
  end;
end;

procedure TMainForm.ParseCommandLine;
var
  I: Integer;
  A: string;

  function Next(Ix: Integer): string;
  begin
    if Ix < ParamCount then Result := ParamStr(Ix + 1) else Result := '';
  end;

begin
  I := 1;
  while I <= ParamCount do
  begin
    A := LowerCase(ParamStr(I));
    if A = '--auto' then FAuto := True
    else if A = '--layout-check' then FLayoutCheck := True
    else if A = '--no-tags' then cbTags.Checked := False
    else if A = '--tags' then cbTags.Checked := True
    else if A = '--dll' then FUseDll := True
    else if A = '--no-dll' then FUseDll := False
    else if A = '--repo'     then begin FRepoName := Next(I); Inc(I); end
    else if A = '--work'     then begin edWork.Text := Next(I); Inc(I); end
    else if A = '--tcbin'    then begin edTcBin.Text := Next(I); Inc(I); end
    else if A = '--branch'   then begin edBranch.Text := Next(I); Inc(I); end
    else if A = '--window'   then begin edWindow.Text := Next(I); Inc(I); end
    else if A = '--authors'  then begin edAuthors.Text := Next(I); Inc(I); end
    else if A = '--limit'    then begin edLimit.Text := Next(I); Inc(I); end
    else if A = '--threads'  then begin edThreads.Text := Next(I); Inc(I); end
    else if A = '--projects' then begin FAutoProjects := Next(I); Inc(I); end
    else if A = '--log'      then begin FAutoLog := Next(I); Inc(I); end
    else if A = '--user'     then begin FTcUser := Next(I); Inc(I); end
    else if A = '--pwd'      then begin FTcPwd := Next(I); Inc(I); end
    else if A = '--conn'     then begin FTcConn := Next(I); Inc(I); end
    else if A = '--font'     then Inc(I);   // consumed in BuildUi
    ;
    Inc(I);
  end;

  if FAutoLog <> '' then
  begin
    try
      FLogStream := TFileStream.Create(FAutoLog, fmCreate or fmShareDenyNone);
      FLogWriter := TStreamWriter.Create(FLogStream, TEncoding.UTF8);
    except
      // The default ACL on C: lets a standard user create FOLDERS but not FILES, so a log
      // path in the drive root fails while the working folder beside it succeeds. Fall back
      // rather than run blind.
      FLogWriter := nil;
      try
        FAutoLog := TPath.Combine(edWork.Text, 'migrator.log');
        ForceDirectories(edWork.Text);
        FLogStream := TFileStream.Create(FAutoLog, fmCreate or fmShareDenyNone);
        FLogWriter := TStreamWriter.Create(FLogStream, TEncoding.UTF8);
      except
        FreeAndNil(FLogStream);
        FLogWriter := nil;
      end;
    end;
    if Assigned(FLogWriter) then FLogWriter.AutoFlush := True;   // readable while running
  end;
end;

procedure TMainForm.AutoTick(Sender: TObject);
var
  I, Wanted: Integer;
  IdStr: string;
begin
  FAutoTimer.Enabled := False;
  try
    ConnectClick(nil);
    if (FSession = nil) or not FSession.Connected then
    begin
      DoLog('Unattended run: could not establish a session.');
      FinishAuto(2);
      Exit;
    end;

    // --projects 10014,10015 selects by id; without it, everything found is migrated.
    if FAutoProjects <> '' then
    begin
      Wanted := 0;
      for I := 0 to lbProjects.Items.Count - 1 do
      begin
        IdStr := IntToStr(Cardinal(lbProjects.Items.Objects[I]));
        lbProjects.Checked[I] := Pos(',' + IdStr + ',', ',' + FAutoProjects + ',') > 0;
        if lbProjects.Checked[I] then Inc(Wanted);
      end;
      DoLog(Format('Unattended run: %d project(s) selected by id.', [Wanted]));
      if Wanted = 0 then
      begin
        DoLog('None of the requested project ids exist.');
        FinishAuto(3);
        Exit;
      end;
    end;

    // RunClick now returns immediately; the run ends in WorkerDone, which calls FinishAuto.
    RunClick(nil);
  except
    on E: Exception do
    begin
      DoLog('Unattended run failed: ' + E.Message);
      FinishAuto(4);
    end;
  end;
end;

procedure TMainForm.FinishAuto(Code: Integer);
begin
  if Assigned(FLogWriter) then
  try
    FLogWriter.Flush;
  except
    // a failed log write must not change the exit code of the run itself
  end;
  ExitCode := Code;
  Application.Terminate;

  // Backstop, because Application.Terminate alone does not reliably end this process. After
  // the 2026-09-26 run it logged MIGRATION COMPLETE, set exit code 0, called Terminate - and
  // then spun the main thread at ~96% CPU for 444 CPU-seconds without exiting, so the
  // supervisor (blocked on -Wait) never recorded the run as finished. The spin is somewhere in
  // VCL or GPVMain.dll shutdown; it has not been traced, so this does not claim to fix the
  // cause.
  //
  // By this point everything is safely on disk: git fast-import has exited, the checkpoint is
  // written and the log is flushed above, so leaving by the shortest route costs nothing.
  FExitTimer := TTimer.Create(Self);
  FExitTimer.Interval := 4000;
  FExitTimer.OnTimer := ForceExit;
  FExitTimer.Enabled := True;
end;

procedure TMainForm.ForceExit(Sender: TObject);
begin
  FExitTimer.Enabled := False;
  // Halt first: it still runs unit finalization, so it is the tidier of the two.
  try
    Halt(ExitCode);
  except
    // ignore - the next line leaves regardless
  end;
  // If finalization is itself what hangs, Halt never returns and never gets here; if it does
  // return, go out the hard way rather than spin.
  ExitProcess(UINT(ExitCode));
end;

destructor TMainForm.Destroy;
begin
  FLogWriter.Free;
  FLogStream.Free;
  FSession.Free;
  inherited;
end;

// ---------------------------------------------------------------- ui
//
// Layout rule: nothing is positioned with a magic pixel number. Every size comes from the
// actual rendered text (Canvas.TextWidth / TextHeight), so the window lays itself out
// correctly at any DPI, font size or Windows text-scaling setting. Controls are anchored so
// resizing moves them instead of letting them collide.

function TMainForm.TextW(const S: string): Integer;
begin
  Result := Canvas.TextWidth(S);
end;

function TMainForm.NewLabel(Parent: TWinControl; const Text: string;
  Bold: Boolean = False): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Parent := Parent;
  Result.AutoSize := True;          // never clip, never overlap the control beside it
  Result.Caption := Text;
  if Bold then Result.Font.Style := [fsBold];
end;

function TMainForm.NewEdit(Parent: TWinControl; const Text: string): TEdit;
begin
  Result := TEdit.Create(Parent);
  Result.Parent := Parent;
  Result.Text := Text;
  Result.Height := FRowH;
end;

function TMainForm.NewButton(Parent: TWinControl; const Caption: string;
  OnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Parent);
  Result.Parent := Parent;
  Result.Caption := Caption;
  Result.OnClick := OnClick;
  Result.Height := FBtnH;
  Result.Width := TextW(Caption) + FPad * 4;
end;

procedure TMainForm.BuildUi;
var
  Box: TGroupBox;
  L, L2: TLabel;
  Y, LabelCol, RightEdge, BoxW, ListW, X: Integer;
  Captions: TArray<string>;
  C: string;
begin
  Caption := 'TC Migrator - Team Coherence to git';
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  // --font lets the layout be checked at other text sizes, which is what Windows text
  // scaling really changes. Parsed here because BuildUi runs before ParseCommandLine.
  for var Pi := 1 to ParamCount - 1 do
    if LowerCase(ParamStr(Pi)) = '--font' then
      Font.Size := StrToIntDef(ParamStr(Pi + 1), 9);
  Canvas.Font := Font;

  // every metric below is derived from the rendered font
  FRowH  := Canvas.TextHeight('Wg') + 10;
  FBtnH  := Canvas.TextHeight('Wg') + 14;
  FPad   := Canvas.TextWidth('n');
  FGap   := FPad;
  FLineH := FRowH + FPad;

  // the label column is as wide as the widest caption actually renders
  Captions := ['TC client Bin folder', 'Working folder', 'Git branch',
               'Author map (optional)'];
  LabelCol := 0;
  for C in Captions do
    if TextW(C) > LabelCol then LabelCol := TextW(C);
  Inc(LabelCol, FPad * 3);

  ListW := TextW('ThirdParty  (id 10015)') + FPad * 6;
  BoxW  := LabelCol + TextW(DEF_TCBIN) + ListW + FPad * 8;
  ClientWidth  := FGap * 2 + BoxW;
  ClientHeight := Round(FLineH * 23);   // provisional; corrected once the box is sized
  Position := poScreenCenter;
  Constraints.MinWidth  := Round(ClientWidth * 0.75);
  Constraints.MinHeight := Round(FLineH * 15);
  OnCloseQuery := FormCloseQuery;
  RightEdge := ClientWidth - FGap;

  lblBanner := NewLabel(Self,
    'READ-ONLY against Team Coherence. Nothing is pushed anywhere unless you do it yourself.',
    True);
  lblBanner.Font.Color := clGreen;
  lblBanner.Left := FGap;
  lblBanner.Top := FGap;

  Y := lblBanner.Top + lblBanner.Height + FGap;

  // ---- settings ------------------------------------------------------------------
  Box := TGroupBox.Create(Self);
  Box.Parent := Self;
  Box.Caption := ' Settings ';
  Box.SetBounds(FGap, Y, ClientWidth - FGap * 2, Round(FLineH * 6.6));
  Box.Anchors := [akLeft, akTop, akRight];

  if ListW > Box.Width div 3 then ListW := Box.Width div 3;
  X := Box.Width - FGap - ListW;      // left edge of the right-hand column

  Y := Round(FLineH * 0.9);

  L := NewLabel(Box, 'TC client Bin folder');
  L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  edTcBin := NewEdit(Box, DEF_TCBIN);
  edTcBin.SetBounds(LabelCol, Y, X - LabelCol - FGap * 2, FRowH);
  edTcBin.Anchors := [akLeft, akTop, akRight];
  Inc(Y, FLineH);

  L := NewLabel(Box, 'Working folder');
  L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  btnOpen := NewButton(Box, 'Open', OpenClick);
  btnOpen.SetBounds(X - FGap * 2 - btnOpen.Width, Y - 2, btnOpen.Width, FBtnH);
  btnOpen.Anchors := [akTop, akRight];
  edWork := NewEdit(Box, 'C:\tcmig');
  edWork.SetBounds(LabelCol, Y, btnOpen.Left - LabelCol - FGap, FRowH);
  edWork.Anchors := [akLeft, akTop, akRight];
  Inc(Y, FLineH);

  L := NewLabel(Box, 'Git branch');
  L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  edBranch := NewEdit(Box, 'tc/main');
  edBranch.SetBounds(LabelCol, Y, TextW('nnnnnnnnnnnnnn'), FRowH);

  L := NewLabel(Box, 'Group check-ins within');
  L.SetBounds(edBranch.Left + edBranch.Width + FGap * 2,
              Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  edWindow := NewEdit(Box, '0');   // 0 = no limit; a check-in can legitimately take hours
  edWindow.SetBounds(L.Left + L.Width + FGap, Y, TextW('99999'), FRowH);
  L2 := NewLabel(Box, 'seconds');
  L2.SetBounds(edWindow.Left + edWindow.Width + FGap,
               Y + (FRowH - L2.Height) div 2, L2.Width, L2.Height);
  Inc(Y, FLineH);

  L := NewLabel(Box, 'Author map (optional)');
  L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  edAuthors := NewEdit(Box, '');
  edAuthors.SetBounds(LabelCol, Y, X - LabelCol - FGap * 2, FRowH);
  edAuthors.Anchors := [akLeft, akTop, akRight];
  Inc(Y, FLineH);

  cbTags := TCheckBox.Create(Box);
  cbTags.Parent := Box;
  cbTags.Caption := 'Rebuild version labels as tags (slower)';
  cbTags.Checked := True;
  cbTags.SetBounds(LabelCol, Y, TextW(cbTags.Caption) + FPad * 4, FRowH);
  Inc(Y, FLineH);

  L := NewLabel(Box, 'Test run: first');
  L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  edLimit := NewEdit(Box, '0');
  edLimit.SetBounds(LabelCol, Y, TextW('99999'), FRowH);
  L2 := NewLabel(Box, 'files (0 = all)');
  L2.SetBounds(edLimit.Left + edLimit.Width + FGap,
               Y + (FRowH - L2.Height) div 2, L2.Width, L2.Height);

  // 'Fetch threads' shares this row only if it genuinely fits before the projects column;
  // at larger text sizes it drops to its own row instead of running off the group box.
  L := NewLabel(Box, 'Fetch threads');
  if L2.Left + L2.Width + FGap * 3 + L.Width + FGap + TextW('999') + FPad * 2 < X - FGap then
    L.SetBounds(L2.Left + L2.Width + FGap * 3, Y + (FRowH - L.Height) div 2, L.Width, L.Height)
  else
  begin
    Inc(Y, FLineH);
    L.SetBounds(FPad * 2, Y + (FRowH - L.Height) div 2, L.Width, L.Height);
  end;
  edThreads := NewEdit(Box, '1');   // measured fastest: see the note in uPipeline.FetchRange
  edThreads.SetBounds(L.Left + L.Width + FGap, Y, TextW('999') + FPad * 2, FRowH);
  Inc(Y, FLineH);

  // projects list fills the right-hand column, below its own caption
  L := NewLabel(Box, 'Projects', True);
  L.SetBounds(X, Round(FLineH * 0.45), L.Width, L.Height);
  L.Anchors := [akTop, akRight];
  lbProjects := TCheckListBox.Create(Box);
  lbProjects.Parent := Box;
  lbProjects.SetBounds(X, L.Top + L.Height + FPad div 2, ListW, FRowH * 4);
  lbProjects.Anchors := [akTop, akRight];

  // the box is exactly as tall as whichever column is longer
  Box.ClientHeight := Max(Y, lbProjects.Top + lbProjects.Height + FPad) + FPad;
  // ---- actions -------------------------------------------------------------------
  Y := Box.Top + Box.Height + FGap;
  X := FGap;
  btnConnect := NewButton(Self, 'Connect', ConnectClick);
  btnConnect.SetBounds(X, Y, btnConnect.Width, FBtnH);
  Inc(X, btnConnect.Width + FGap);

  btnRefresh := NewButton(Self, 'List projects', RefreshClick);
  btnRefresh.SetBounds(X, Y, btnRefresh.Width, FBtnH);
  Inc(X, btnRefresh.Width + FGap);

  btnRun := NewButton(Self, 'Run migration', RunClick);
  btnRun.Font.Style := [fsBold];
  btnRun.Width := TextW('Run migration') + FPad * 6;
  btnRun.SetBounds(X, Y, btnRun.Width, FBtnH);
  Inc(X, btnRun.Width + FGap);

  btnStop := NewButton(Self, 'Stop', StopClick);
  btnStop.SetBounds(X, Y, btnStop.Width, FBtnH);
  btnStop.Enabled := False;

  // ---- progress ------------------------------------------------------------------
  Y := Y + FBtnH + FGap;
  lblPhase := NewLabel(Self, 'Idle', True);
  lblPhase.SetBounds(FGap, Y, lblPhase.Width, lblPhase.Height);
  Y := Y + lblPhase.Height + FPad div 2;

  pbPhase := TProgressBar.Create(Self);
  pbPhase.Parent := Self;
  pbPhase.SetBounds(FGap, Y, RightEdge - FGap, FPad * 2);
  pbPhase.Anchors := [akLeft, akTop, akRight];
  Y := Y + pbPhase.Height + FPad div 2;

  lblStatus := NewLabel(Self, '');
  lblStatus.AutoSize := False;
  lblStatus.SetBounds(FGap, Y, RightEdge - FGap, Canvas.TextHeight('Wg'));
  lblStatus.Anchors := [akLeft, akTop, akRight];
  Y := Y + Canvas.TextHeight('Wg') + FPad div 2;

  // running totals: blobs, no-content, failures, position in the window
  lblCounters := NewLabel(Self, '');
  lblCounters.AutoSize := False;
  lblCounters.Font.Style := [fsBold];
  lblCounters.SetBounds(FGap, Y, RightEdge - FGap, Canvas.TextHeight('Wg'));
  lblCounters.Anchors := [akLeft, akTop, akRight];
  Y := Y + Canvas.TextHeight('Wg') + FPad div 2;

  // the live "what is happening right now" line
  lblDetail := NewLabel(Self, '');
  lblDetail.AutoSize := False;
  lblDetail.EllipsisPosition := epPathEllipsis;   // long TC paths stay readable
  lblDetail.Font.Color := clGrayText;
  lblDetail.SetBounds(FGap, Y, RightEdge - FGap, Canvas.TextHeight('Wg'));
  lblDetail.Anchors := [akLeft, akTop, akRight];
  Y := Y + Canvas.TextHeight('Wg') + FPad div 2;

  lblOverall := NewLabel(Self, 'Overall: waiting to start', True);
  lblOverall.AutoSize := False;
  lblOverall.SetBounds(FGap, Y, RightEdge - FGap, Canvas.TextHeight('Wg'));
  lblOverall.Anchors := [akLeft, akTop, akRight];
  Y := Y + Canvas.TextHeight('Wg') + FPad div 2;

  pbOverall := TProgressBar.Create(Self);
  pbOverall.Parent := Self;
  pbOverall.SetBounds(FGap, Y, RightEdge - FGap, FPad * 2);
  pbOverall.Anchors := [akLeft, akTop, akRight];
  Y := Y + pbOverall.Height + FGap;

  memLog := TMemo.Create(Self);
  memLog.Parent := Self;
  if ClientHeight < Y + FRowH * 8 then ClientHeight := Y + FRowH * 8;
  memLog.SetBounds(FGap, Y, RightEdge - FGap, ClientHeight - Y - FGap);
  memLog.ScrollBars := ssBoth;
  memLog.WordWrap := False;
  memLog.ReadOnly := True;
  memLog.Font.Name := 'Consolas';
  memLog.Font.Size := Font.Size;
  memLog.Anchors := [akLeft, akTop, akRight, akBottom];
end;
// ---------------------------------------------------------------- settings

function TMainForm.SettingsFile: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'TCMigrator.ini');
end;

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
begin
  if not TFile.Exists(SettingsFile) then Exit;
  Ini := TIniFile.Create(SettingsFile);
  try
    edTcBin.Text   := Ini.ReadString('main', 'tcbin', edTcBin.Text);
    edWork.Text    := Ini.ReadString('main', 'work', edWork.Text);
    edBranch.Text  := Ini.ReadString('main', 'branch', edBranch.Text);
    edWindow.Text  := Ini.ReadString('main', 'window', edWindow.Text);
    edAuthors.Text := Ini.ReadString('main', 'authors', edAuthors.Text);
    // The file limit is deliberately NOT restored. It is a test-only control, and a stale
    // value silently turning a full migration into a 2-file one is exactly the kind of
    // quiet wrong answer this tool must not produce. It already did once.
    edLimit.Text := '0';
    edThreads.Text := Ini.ReadString('main', 'threads', edThreads.Text);
    cbTags.Checked := Ini.ReadBool('main', 'tags', True);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(SettingsFile);
  try
    Ini.WriteString('main', 'tcbin', edTcBin.Text);
    Ini.WriteString('main', 'work', edWork.Text);
    Ini.WriteString('main', 'branch', edBranch.Text);
    Ini.WriteString('main', 'window', edWindow.Text);
    Ini.WriteString('main', 'authors', edAuthors.Text);
    Ini.WriteString('main', 'threads', edThreads.Text);
    Ini.WriteBool('main', 'tags', cbTags.Checked);
  finally
    Ini.Free;
  end;
end;

// ---------------------------------------------------------------- feedback

procedure TMainForm.DoLog(const Msg: string);
var
  Line: string;
begin
  Line := FormatDateTime('hh:nn:ss  ', Now) + Msg;
  memLog.Lines.Add(Line);
  SendMessage(memLog.Handle, EM_LINESCROLL, 0, memLog.Lines.Count);
  // Append as we go. Writing the log only at exit turns a long unattended run into a
  // black box - you cannot tell progress from a hang.
  if Assigned(FLogWriter) then
  try
    FLogWriter.WriteLine(Line);
  except
    // never let logging break the run
  end;
end;

procedure TMainForm.DoProgress(const Phase: string; Done, Total: Integer);
var
  Secs, Rate: Double;
  Left: Integer;
  S: string;
begin
  lblPhase.Caption := Phase;
  if Phase <> FPhaseName then
  begin
    FPhaseName := Phase;
    FPhaseStarted := Now;      // rate and ETA are per phase, not for the whole run
  end;

  if Total > 0 then
  begin
    pbPhase.Max := Total;
    pbPhase.Position := Done;
    S := Format('%d of %d  (%d%%)', [Done, Total, Round(Done / Total * 100)]);

    // A count alone reads as stalled on the slow phases. Rate and a finishing time say
    // whether it is moving and roughly how long you are waiting.
    Secs := SecondsBetween(Now, FPhaseStarted);
    if (Secs >= 2) and (Done > 0) then
    begin
      Rate := Done / Secs;
      if Rate > 0 then
      begin
        Left := Round((Total - Done) / Rate);
        S := S + Format('   %.1f/sec   elapsed %s   remaining ~%s',
          [Rate, FormatDateTime('hh:nn:ss', Secs / SecsPerDay),
                 FormatDateTime('hh:nn:ss', Left / SecsPerDay)]);
      end;
    end;
    lblStatus.Caption := S;
  end
  else
  begin
    // Total = 0 marks the start of a phase
    Inc(FStep);
    pbOverall.Max := FSteps;
    if FStep <= FSteps then pbOverall.Position := FStep;
    pbPhase.Position := 0;
    lblStatus.Caption := '';
    lblDetail.Caption := '';
  end;
end;

procedure TMainForm.DoOverall(const Phase: string; Done, Total: Integer);
var
  S2: string;
  Secs, L2: Integer;
  R: Double;
begin
  // The whole-migration percentage. The overall bar used to track the five phases, which
  // told an operator nothing across a run lasting hours.
  if Total <= 0 then Exit;
  pbOverall.Max := Total;
  pbOverall.Position := Done;
  // Include elapsed and a finish estimate: "43%%" alone does not tell an operator whether
  // to wait or come back tomorrow.
  if FRunStart = 0 then FRunStart := Now;
  if FRunFrom = 0 then FRunFrom := Done;
  S2 := '';
  Secs := SecondsBetween(Now, FRunStart);
  if (Secs > 10) and (Done > FRunFrom) then
  begin
    R := (Done - FRunFrom) / Secs;
    if R > 0.001 then
    begin
      L2 := Round((Total - Done) / R);
      S2 := Format('   -   %.1f/sec   elapsed %s   finishes in about %s',
        [R, FormatDateTime('hh:nn:ss', Secs / SecsPerDay),
            FormatDateTime('hh:nn:ss', L2 / SecsPerDay)]);
    end;
  end;
  lblOverall.Caption := Format('Overall: %.1f%%   -   %d of %d revisions migrated%s',
    [Done / Total * 100, Done, Total, S2]);
end;

procedure TMainForm.DoCounters(const S: string);
begin
  // Running totals, updated twice a second. Without this the window looked frozen during
  // the slow stretches - the phase bar only moved every 200 revisions, which at half a
  // revision per second is once every six minutes.
  lblCounters.Caption := S;
end;

procedure TMainForm.DoItem(const Detail: string);
begin
  // The "what is it doing right now" line. Deliberately NOT written to the log: it changes
  // ten times a second, and a log full of it would bury the things worth keeping.
  lblDetail.Caption := Detail;
end;
function TMainForm.DoCancel: Boolean;
begin
  Result := FCancel;
end;

procedure TMainForm.SetBusy(Busy: Boolean);
begin
  FRunning := Busy;
  btnRun.Enabled := not Busy;
  btnConnect.Enabled := not Busy;
  btnRefresh.Enabled := not Busy;
  btnStop.Enabled := Busy;
  // NO hourglass: the work runs on a worker thread and this window stays responsive.
  // A busy cursor here only makes a healthy long run look stalled.
  Screen.Cursor := crDefault;
end;

procedure TMainForm.NextStep(const Name: string);
begin
  Inc(FStep);
  pbOverall.Max := FSteps;
  pbOverall.Position := FStep;
  lblPhase.Caption := Name;
  DoLog('');
  DoLog('=== ' + Name + ' ===');
  Application.ProcessMessages;
end;

// ---------------------------------------------------------------- actions

procedure TMainForm.ConnectClick(Sender: TObject);
var
  Conns: TArray<string>;
  C: string;
begin
  try
    FreeAndNil(FSession);
    FSession := TTCSession.Create(edTcBin.Text);
    // No hardcoded connection name: take what the operator gave, otherwise the first
    // connection this TC client has defined. Guessing a name that does not exist fails with
    // Err_ConnectionNotDefined and looks like a credential problem.
    FSession.ConnectionName := FTcConn;
    if FSession.ConnectionName = '' then
    begin
      Conns := FSession.ListConnections;
      if Length(Conns) > 0 then
      begin
        FSession.ConnectionName := Conns[0];
        DoLog(Format('No connection given; using the first one defined: %s',
          [FSession.ConnectionName]));
      end
      else
      begin
        DoLog('This TC client has no connections defined. Set one up in Connection Manager,');
        DoLog('or pass --conn <name>.');
        Exit;
      end;
    end;
    FSession.UserName := FTcUser;
    FSession.Password := FTcPwd;
    FSession.OnLog := DoLog;
    FSession.OnProgress := DoProgress;
    FSession.OnCancel := DoCancel;

    DoLog(Format('API entry points available: %d', [FSession.ProbeEntryPoints]));
    Conns := FSession.ListConnections;
    for C in Conns do DoLog('Connection: ' + C);
    if Length(Conns) = 0 then
      DoLog('No connections came back - check the VPN, then the TC client configuration.');

    // TCVcsLogin never returns when the server is unreachable, so test the socket first.
    if not FSession.ServerReachable then
    begin
      DoLog('');
      DoLog('*** CANNOT REACH THE TEAM COHERENCE SERVER ***');
      DoLog('Check the VPN is connected, then try again.');
      DoLog('Nothing has been changed. A migration in progress continues where it stopped.');
      if not FAuto then
        MessageDlg('Cannot reach the Team Coherence server.'#13#10#13#10 +
          'Check the VPN is connected, then try again.', mtError, [mbOK], 0);
      Exit;
    end;
    DoLog('Server is reachable.');

    if FSession.Login then
    begin
      DoLog('Connected. You were not asked for a password: the session comes from your TC client.');
      RefreshClick(nil);
    end;
  except
    on E: Exception do
    begin
      DoLog('ERROR: ' + E.Message);
      MessageDlg(E.Message, mtError, [mbOK], 0);
    end;
  end;
end;

procedure TMainForm.RefreshClick(Sender: TObject);
var
  I: Integer;
begin
  if (FSession = nil) or not FSession.Connected then
  begin
    DoLog('Connect first.');
    Exit;
  end;
  FSession.EnumProjects;
  lbProjects.Items.Clear;
  for I := 0 to FSession.Projects.Count - 1 do
  begin
    lbProjects.Items.AddObject(
      Format('%s  (id %d)', [FSession.Projects[I].Name, FSession.Projects[I].ID]),
      TObject(FSession.Projects[I].ID));
    lbProjects.Checked[I] := True;
  end;
  FSession.EnumViews;
end;

procedure TMainForm.StopClick(Sender: TObject);
begin
  FCancel := True;
  if Assigned(FWorker) then FWorker.Terminate;
  DoLog('Stopping after the current item...');
  btnStop.Enabled := False;
end;

procedure TMainForm.OpenClick(Sender: TObject);
begin
  if TDirectory.Exists(edWork.Text) then
    ShellExecute(0, 'open', PChar(edWork.Text), nil, nil, SW_SHOWNORMAL)
  else
    MessageDlg('That folder does not exist yet.', mtInformation, [mbOK], 0);
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FRunning then
  begin
    CanClose := MessageDlg('A migration is running. Stop it and close?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes;
    if CanClose then
    begin
      FCancel := True;
      if Assigned(FWorker) then FWorker.Terminate;
    end;
  end;
  if CanClose then SaveSettings;
end;

procedure TMainForm.RunClick(Sender: TObject);
var
  Opt: TPipelineOptions;
  I, Chosen: Integer;
  Roots: TArray<Cardinal>;
begin
  if (FSession = nil) or not FSession.Connected then
  begin
    if not FAuto then MessageDlg('Connect to Team Coherence first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if FRunning then Exit;

  Roots := nil;
  Chosen := 0;
  for I := 0 to lbProjects.Items.Count - 1 do
    if lbProjects.Checked[I] then
    begin
      SetLength(Roots, Chosen + 1);
      Roots[Chosen] := Cardinal(lbProjects.Items.Objects[I]);
      Inc(Chosen);
    end;
  if Chosen = 0 then
  begin
    if not FAuto then MessageDlg('Tick at least one project to migrate.', mtInformation, [mbOK], 0);
    Exit;
  end;

  if not FAuto then
    if MessageDlg(
         Format('Migrate %d project(s) into a new git repository under'#13#10'%s ?'#13#10#13#10 +
                'Team Coherence is only ever read from.', [Chosen, edWork.Text]),
         mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  SaveSettings;
  FCancel := False;
  SetBusy(True);
  FStep := 0;
  FSteps := 5;
  pbOverall.Max := FSteps;
  pbOverall.Position := 0;

  Opt := Default(TPipelineOptions);
  Opt.TcExe   := TPath.Combine(edTcBin.Text, 'tc.exe');
  Opt.GitExe  := 'git.exe';
  Opt.WorkDir := edWork.Text;
  Opt.MetaDir := TPath.Combine(edWork.Text, 'meta');
  Opt.CacheDir:= TPath.Combine(edWork.Text, 'blobs');
  if FRepoName = '' then FRepoName := 'repo.git';
  Opt.RepoDir := TPath.Combine(edWork.Text, FRepoName);
  // The folder to re-anchor to with CD after any view change. Derived from the first project
  // ticked rather than hardcoded: a TC project sits at //<name>, and re-anchoring to a folder
  // that does not exist silently leaves relative paths resolving against the wrong place -
  // which once produced 788 phantom "unfetchable" revisions.
  Opt.Project := '';
  if Length(Roots) > 0 then
    for I := 0 to FSession.Projects.Count - 1 do
      if FSession.Projects[I].ID = Roots[0] then
      begin
        Opt.Project := '//' + FSession.Projects[I].Name;
        Break;
      end;
  Opt.Branch  := edBranch.Text;
  Opt.WindowSeconds := StrToIntDef(edWindow.Text, 180);
  Opt.AuthorMapFile := edAuthors.Text;
  Opt.IncludeTags := cbTags.Checked;
  Opt.UseDll := FUseDll;
  Opt.FetchThreads := StrToIntDef(edThreads.Text, 8);
  // Check-ins per resumable batch. Larger batches also give the fetch workers more
  // distinct archives to choose from, which matters because one archive is never fetched
  // by two workers at once.
  Opt.BatchSize := 600;

  TDirectory.CreateDirectory(Opt.WorkDir);
  TDirectory.CreateDirectory(Opt.MetaDir);

  // Hand the work to the migration thread. This method returns immediately, which is the
  // whole point: the window keeps painting and Stop stays clickable.
  FWorker := TMigrationThread.Create(FSession, Opt, Roots,
    StrToIntDef(edLimit.Text, 0), DoLog, DoItem, DoCounters, DoOverall, DoProgress, WorkerDone);
end;

procedure TMainForm.WorkerDone(Success: Boolean; const Summary: string);
begin
  FWorker := nil;           // FreeOnTerminate - the thread disposes of itself
  SetBusy(False);
  DoLog('');
  if Success then
  begin
    pbOverall.Position := pbOverall.Max;
    DoLog('MIGRATION COMPLETE: ' + Summary);
    if not FAuto then
      MessageDlg('Migration complete.'#13#10#13#10 + Summary, mtInformation, [mbOK], 0);
  end
  else
  begin
    DoLog('FINISHED WITHOUT SUCCESS: ' + Summary);
    if not FAuto then MessageDlg(Summary, mtError, [mbOK], 0);
  end;
  if FAuto then FinishAuto(IfThen(Success, 0, 1));
end;
end.
