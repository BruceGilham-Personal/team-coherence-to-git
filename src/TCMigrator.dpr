program TCMigrator;
{
  Team Coherence -> git migrator.

  Win32 ONLY: GPVCCore.dll / GPVMain.dll are 32-bit, so this must be built with dcc32.

  Build:
    "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc32.exe" -B TCMigrator.dpr
}
uses
  Vcl.Forms,
  uTCApi in 'uTCApi.pas',
  uPipeline in 'uPipeline.pas',
  uWorker in 'uWorker.pas',
  uMain in 'uMain.pas';

begin
  Application.Initialize;
  Application.Title := 'TC Migrator';
  Application.MainFormOnTaskbar := True;
  // Application.Run does nothing unless Application.MainForm is set, and only
  // Application.CreateForm sets it.
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
