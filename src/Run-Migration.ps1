<#
.SYNOPSIS
  Runs TCMigrator to completion, restarting it after a dropped connection.

.DESCRIPTION
  The migrator checkpoints every batch and resumes exactly where it stopped, so the safe way
  to run a long migration is to keep relaunching it until it reports success. A VPN drop, a
  server restart or a reboot then costs one batch rather than the run.

  Nothing is re-downloaded on a restart: the blob cache is content-addressed and the manifest
  records every revision already fetched.

  The password is read from the TCPWD environment variable so it is never written to this file
  or left in a scheduled task. Set it in the session that launches this script:

      $env:TCPWD = 'the-password'
      .\Run-Migration.ps1

  With -Update it brings an already-migrated work folder up to date instead: only the check-ins
  made in Team Coherence since are added, on top of the tip that is on the remote, and -Push
  publishes the result. An update that finds something it cannot account for exits 5, and this
  supervisor stops rather than retrying.

.EXAMPLE
  $env:TCPWD = '...'; .\Run-Migration.ps1 -Work D:\migration -User jsmith
  $env:TCPWD = '...'; .\Run-Migration.ps1 -Work D:\migration -User jsmith -Tags   # + labels
  $env:TCPWD = '...'; .\Run-Migration.ps1 -Work D:\migration -User jsmith -Tags -Update -Push

  Put the work folder on a volume with room for the blob cache AND the repository - about
  2.5x the size of the history. A 44,450-revision repository needed roughly 12 GB, and running
  out of room mid-fetch is the one failure the supervisor cannot retry its way out of.
#>
[CmdletBinding()]
param(
  [string] $Work    = 'C:\tc-migration',
  # The Team Coherence username to log in with. No default on purpose.
  [Parameter(Mandatory = $true)]
  [string] $User,
  # TC connection name. Empty uses the first connection this client has defined.
  [string] $Conn    = '',
  # Name of the bare git repository created inside -Work.
  [string] $Repo    = 'repo.git',
  # ONE worker. Measured: one worker is roughly forty times faster than four, because two
  # concurrent Get calls on the same archive make Team Coherence return success with no files,
  # which then has to be retried. Raise this only with a measurement in hand.
  [int]    $Threads = 1,
  [string] $Branch  = 'tc/main',
  # 0 = no time limit when grouping revisions into check-ins. Author plus comment identifies a
  # check-in on its own; a 180-second cap shattered 2,620 real check-ins into fragments.
  [int]    $Window  = 0,
  [switch] $Tags,
  # Content is fetched through the TC DLL (TCDVcsCheckOutFile) by default. Measured against a
  # full CLI pull of the same repository: ~100 minutes instead of ~12 hours, and HALF the wrong
  # revisions - 42 against 83, its bad set a strict subset of the CLI's. -NoDll reverts to
  # spawning tc.exe per revision, which is slower and demonstrably less accurate.
  [switch] $NoDll,
  # Windows time zone of the TC server's clock, e.g. 'Eastern Standard Time'. TC stores wall-clock
  # time with no zone; empty means this PC's zone, which is wrong whenever the two differ.
  [string] $TimeZone = '',
  # Add only what Team Coherence has that the repository does not, on top of the remote's tip.
  # Needs the work folder of the original migration.
  [switch] $Update,
  # Push the branch (and with -Tags the tags) to -Remote after a successful run.
  [switch] $Push,
  [string] $Remote = 'origin',
  # The original migration's checkpoint, when it is not state.txt in -Work (a first -Update
  # reads it to learn what the migration put in git).
  [string] $StateFile = '',
  # Content filter every file passes through before it reaches git - e.g. a redact-blobs.pl
  # beside your rules.pl (tools\filters) - for a published history that was redacted.
  [string] $Filter = '',
  # ';'-separated masks of paths never written to git, e.g. '*.pfx'.
  [string] $Exclude = '',
  [int]    $MaxAttempts = 400,
  [int]    $RetrySeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exe = Join-Path $PSScriptRoot 'TCMigrator.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "TCMigrator.exe not found beside this script" }
if (-not $env:TCPWD) { throw 'Set $env:TCPWD to the Team Coherence password before running this.' }

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$supervisorLog = Join-Path $Work 'supervisor.log'

function Say([string] $msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -LiteralPath $supervisorLog -Value $line
}

# Start-Process joins -ArgumentList with spaces and quotes nothing, so a work folder such as
# 'D:\TC Migration' arrived as two arguments. Quote each one the way Delphi's ParamStr reads it
# back: a quote only toggles quoting and backslashes are always literal, so wrapping in quotes
# is enough. A value containing a quote cannot be passed at all, and an empty one ("") is
# skipped by ParamStr, which would shift every argument after it.
function ConvertTo-QuotedArg([string] $s) {
  if ($s -eq '') { throw 'A migrator argument cannot be empty.' }
  if ($s.Contains('"')) { throw "A migrator argument cannot contain a double quote: $s" }
  if ($s -notmatch '\s') { return $s }
  return '"' + $s + '"'
}

# How far the run has got, to tell an attempt that advanced from one that did not: check-ins in
# state.txt for a migration, handled revisions in update.txt for an update.
function Get-Checkpoint {
  if ($Update) { $file = Join-Path $Work 'update.txt'; $key = 'ledger_rows' }
  else { $file = Join-Path $Work 'state.txt'; $key = 'committed' }
  if (-not (Test-Path -LiteralPath $file)) { return 0 }
  $m = Select-String -Path $file -Pattern "^$key=(\d+)" | Select-Object -First 1
  if ($m) { return [int]$m.Matches[0].Groups[1].Value }
  return 0
}

Say "supervisor starting: work=$Work threads=$Threads conn=$Conn repo=$Repo tz=$TimeZone tags=$($Tags.IsPresent) dll=$(-not $NoDll.IsPresent) update=$($Update.IsPresent) push=$($Push.IsPresent) remote=$Remote"

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  $log = Join-Path $Work ("migrate-{0:d3}.log" -f $attempt)
  # No --pwd: the migrator reads TCPWD from the environment it inherits, so the password never
  # appears on a command line where anything listing processes could read it.
  $a = @(
    '--auto', '--user', $User,
    '--work', $Work, '--limit', '0', '--threads', "$Threads",
    '--branch', $Branch, '--window', "$Window", '--log', $log, '--repo', $Repo
  )
  if ($Conn) { $a += @('--conn', $Conn) }
  if ($TimeZone) { $a += @('--tz', $TimeZone) }
  if ($Tags) { $a += '--tags' } else { $a += '--no-tags' }
  if ($NoDll) { $a += '--no-dll' } else { $a += '--dll' }
  if ($Update) { $a += '--update' }
  if ($StateFile) { $a += @('--state', $StateFile) }
  if ($Filter) { $a += @('--filter', $Filter) }
  if ($Exclude) { $a += @('--exclude', $Exclude) }
  if ($Push) { $a += @('--push', '--remote', $Remote) }
  $argLine = ($a | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' '

  $before = Get-Checkpoint
  Say "attempt $attempt starting (checkpoint at $before)"
  $p = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -Wait
  $code = $p.ExitCode
  $after = Get-Checkpoint

  if ($code -eq 0) {
    Say "attempt $attempt COMPLETED (checkpoint $before -> $after). Run finished."
    break
  }
  if ($code -eq 5) {
    Say "attempt $attempt REFUSED to continue (exit 5): something needs a person - see $log. Not retrying."
    break
  }

  # exit 2 = no session (server unreachable), 4 = failed, 1 = stopped
  Say "attempt $attempt ended with exit $code (checkpoint $before -> $after). Retrying in ${RetrySeconds}s."
  if ($after -eq $before -and $attempt -gt 3) {
    # Not advancing: back off further so a genuine outage is not hammered.
    Say "  no progress in this attempt - backing off to $($RetrySeconds * 5)s"
    Start-Sleep -Seconds ($RetrySeconds * 5)
  } else {
    Start-Sleep -Seconds $RetrySeconds
  }
}

Say 'supervisor finished'

