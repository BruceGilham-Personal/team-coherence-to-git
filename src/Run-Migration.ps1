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

.EXAMPLE
  $env:TCPWD = '...'; .\Run-Migration.ps1 -Work D:\migration -User jsmith
  $env:TCPWD = '...'; .\Run-Migration.ps1 -Work D:\migration -User jsmith -Tags   # + labels

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

Say "supervisor starting: work=$Work threads=$Threads conn=$Conn repo=$Repo tags=$($Tags.IsPresent) dll=$(-not $NoDll.IsPresent)"

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  $log = Join-Path $Work ("migrate-{0:d3}.log" -f $attempt)
  $a = @(
    '--auto', '--user', $User, '--pwd', $env:TCPWD,
    '--work', $Work, '--limit', '0', '--threads', "$Threads",
    '--branch', $Branch, '--window', "$Window", '--log', $log, '--repo', $Repo
  )
  if ($Conn) { $a += @('--conn', $Conn) }
  if ($Tags) { $a += '--tags' } else { $a += '--no-tags' }
  if ($NoDll) { $a += '--no-dll' } else { $a += '--dll' }

  $before = 0
  $state = Join-Path $Work 'state.txt'
  if (Test-Path -LiteralPath $state) {
    $m = Select-String -Path $state -Pattern '^committed=(\d+)' | Select-Object -First 1
    if ($m) { $before = [int]$m.Matches[0].Groups[1].Value }
  }

  Say "attempt $attempt starting (checkpoint at $before check-ins)"
  $p = Start-Process -FilePath $exe -ArgumentList $a -PassThru -Wait
  $code = $p.ExitCode

  $after = 0
  if (Test-Path -LiteralPath $state) {
    $m = Select-String -Path $state -Pattern '^committed=(\d+)' | Select-Object -First 1
    if ($m) { $after = [int]$m.Matches[0].Groups[1].Value }
  }

  if ($code -eq 0) {
    Say "attempt $attempt COMPLETED (checkpoint $before -> $after). Migration finished."
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

