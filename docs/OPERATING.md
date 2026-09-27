# TC Migrator

A single Windows application that migrates Team Coherence history into a git repository.
It replaces the PowerShell/Node toolset in [`..`](..): same pipeline, one executable, nothing
an operator can edit by accident.


## Running it

Double-click `TCMigrator.exe`. There is no command line and nothing to remember.

1. **Connect** — logs in through the Team Coherence client's own session. *You are never asked
   for a password*, because the client already holds one. It also lists the API entry points and
   the defined connections, which doubles as a VPN check.
2. **List projects** — ticks every project it finds (`Documents`, `Source`, `ThirdParty`).
   Untick anything you do not want.
3. Check the settings (working folder, branch name, grouping window).
4. **Run migration** — confirms once, then works through six phases with live progress.

**Stop** is safe at any point: it finishes the item in flight and stops. Re-running starts clean.

## Settings

| Setting | What it does |
|---|---|
| TC client Bin folder | Where `tc.exe` and the API DLLs live. Only change this if TC is installed elsewhere |
| Working folder | Everything is written here: `meta\` (CSVs), `blobs\` (file cache), `repo.git` (the repository) |
| Git branch | The branch the history lands on. `tc/main` keeps it clearly separate from any existing `main` |
| Group check-ins within | Team Coherence records one revision per *file*; git wants one commit per *change*. Revisions by the same author with the same comment inside this many seconds become one commit. 180 is a sensible default |
| Author map | Optional text file, one `login = Full Name <email>` per line. Unmapped authors become `login <login@tc.local>` so they are obvious rather than invented |
| Rebuild version labels as tags | Reproduces each label as an exact tree. Accurate but slow: it costs one server round trip per revision |

Settings are remembered in `TCMigrator.ini` in your home folder.

## What it does, in order

1. **Reads the repository structure** — folders and files for each selected project.
2. **Reads revision history** — author, date and check-in comment for every revision.
3. **Matches labels to revisions** — only when tags are enabled. The slowest phase.
4. **Checks that revision selection works** — see the warning below.
5. **Fetches file contents** — `tc Get -VR<rev>` per revision into a content-addressed cache,
   so identical content is stored once.
6. **Builds and imports** — writes a `git fast-import` stream and runs it into a bare repository,
   then verifies with `git fsck` and a commit count.

## Unattended runs

The same executable runs without a window-driver for testing or a scheduled job. It still shows
its window so you can watch, but asks nothing and exits when finished.

```
TCMigrator.exe --auto --work C:\tc-migration-test --projects 10014 --limit 25 --no-tags --log run.log
```

| Flag | Meaning |
|---|---|
| `--auto` | Connect and run with no prompts, then exit |
| `--work <dir>` | Working folder |
| `--projects <ids>` | Comma-separated project ids, e.g. `10014,10015`. Omit for all |
| `--limit <n>` | **Test run**: use only the first *n* files. `0` = all |
| `--no-tags` / `--tags` | Whether to rebuild version labels as tags |
| `--branch <name>` | Target branch |
| `--window <seconds>` | Check-in grouping window |
| `--authors <file>` | Author map |
| `--tcbin <dir>` | TC client Bin folder |
| `--log <file>` | Write the on-screen log to this file on exit |

Exit codes: `0` success, `1` stopped, `2` no session, `3` no such project id, `4` failed.

**Start with `--limit`.** A run over the whole repository is 44,446 revisions and one `tc Get`
each; a 25-file run exercises every phase in a couple of minutes and tells you whether the
settings, the view and the git output are right before you commit hours to it.

## How long it takes, and why

### The VPN tunnel type matters more than anything else

Measured on the same machine, same server, same command - a recursive `Get` of
one folder of 241 files totalling 93 MB:

| VPN | Elapsed | Throughput | Per file |
|---|---|---|---|
| SSL | 306 s | 307 KB/s | 1,270 ms |
| **IPsec** | **47 s** | **2,045 KB/s** | **193 ms** |

**6.7x faster on IPsec.** Round-trip latency was unchanged (64 ms vs 69 ms) and per-call
overhead was unchanged, so this is not latency - it is throughput lost to the SSL tunnel.

The whole migration moves **~10 GB** (44,446 revisions, mean 235 KB each), so this single
setting is worth more than every other optimisation combined. **Check you are on IPsec before
starting a full run.**

### Per-call costs (IPsec)

| What | Cost |
|---|---|
| `tc.exe` process startup | ~980 ms - paid on every call |
| Round trip to the server | 69 ms |
| One `Get` of a small file | ~2.5 s (almost all of it startup) |
| Bulk transfer rate | ~2 MB/s |

Because process startup dominates small files and bandwidth dominates large ones, the fetch
phase is bound by whichever is larger. Both are addressed by running several fetch workers.

### What helps, in order

1. **Be on the IPsec VPN, not SSL.** 6.7x, measured. Nothing else comes close.
2. **Fetch threads: 8.** Measured 4.1x over serial. It plateaus around there.
3. **Leave "Rebuild version labels as tags" off unless you need tags.** One round trip per
   revision. The application first asks each *file* whether it carries any label at all and
   skips every revision of files that have none, but that only helps when labels are
   concentrated in a few files.
4. **Use "Test run: first N files" before any full run.**

### Rough totals for a full migration (44,446 revisions, ~10 GB)

| Setup | Fetch phase |
|---|---|
| SSL VPN, 8 threads | ~9.5 hours (bandwidth-bound) |
| **IPsec VPN, 8 threads** | **~1.5 - 2 hours** |
| On the LAN | limited only by per-call overhead |

### Concurrency: ONE worker. More is dramatically slower.

Measured on the same region of history, after the folder-cache bug was fixed:

| Workers | Failures | Effective rate | ETA for the remainder |
|---|---|---|---|
| 4 | 55 | 0.1/sec | 49 hours |
| **1** | **2** | **3.9 - 12.9/sec** | **36 minutes** |

One worker is roughly **forty times faster** than four. The mechanism: above one concurrent
fetch the server starts returning exit 0 with no files, each of those costs eight attempts with
backing-off pauses (~35 seconds), and the retries consume all the capacity. One worker that
succeeds beats four that fail.

An earlier measurement suggested 4 was the sweet spot and that concurrency was not the main
cause of failures. That measurement was taken while the folder-cache bug was corrupting every
result, and it was wrong. Large files (100-500 KB) are the ones that fail under concurrency. Above about four concurrent fetches the server starts
returning exit 0 with no files, each of those costs eight retries, and the retries consume the
capacity that would otherwise have fetched real content. There is nothing to gain by raising it.

An empty result is indistinguishable from "this revision has no content", which is what makes
this dangerous rather than merely wasteful - see the hazards above.

### Three kinds of failure, only one of which concurrency affects

| Symptom | Cause | Fix |
|---|---|---|
| exit 0, no files, metadata says bytes exist | load; **succeeds on a serial retry** | retry, then a serial cleanup pass |
| file absent from `tc Dir`, nothing at any revision | deleted from Team Coherence | none - content is unreachable |
| exit 85 / exit 61 | no stored file / damaged archive | none - the server cannot produce it |

The first kind is recoverable and must be retried until it succeeds: a revision whose content is
missing does **not** leave a hole in the history. No `M` line is emitted, so the file silently
keeps its previous content at that commit - it looks like "unchanged here" rather than "missing".
That is why the run is only trustworthy once failures reach zero.

**Two-pass strategy:** run the main pass at 4 workers for speed, then re-run with the checkpoint
deleted (keeping `blobs/` and `meta/`) to fetch only what is missing. Cached revisions are skipped
instantly, so a cleanup pass costs minutes. Repeat until the failure count stops falling; whatever
remains is of the second or third kind and is enumerated in `failed.csv`.

### An optimisation deliberately not implemented

`tc Get` accepts several files in one command, and batching ten archives cut the per-archive
cost from 2,054 ms to 924 ms by amortising the process startup - a 2.2x win on small files.

It is **not** implemented, because the output of a batched `Get` **flattens** into the target
folder: every file arrives in one directory with no indication of which archive it came from.
Since a Team Coherence archive is a file *group* (`MyForm.pas` brings `MyForm.dfm` with it),
attributing each returned file to the right archive means guessing from file names. Guessing
wrong writes one file's bytes under another file's path - silent history corruption, which is
precisely what this tool exists to prevent.

It would need a runtime check proving a batched fetch returns byte-identical content to
individual fetches, and batches restricted to archives whose names cannot be confused. On IPsec
the win is smaller anyway, since bandwidth rather than per-call overhead now dominates.

**And for migrating history it would barely help at all, which settles it.** `-VR` selects one
revision *per command*, there is no per-file revision syntax in an `@filelist`, and there is no
date selector - so the only thing that can be batched is the set of files inside one check-in that
happen to share the same revision number. Counted against this repository's own metadata:

```
revisions                44450
check-ins                17287
batchable groups         38268
Get calls if batched      39414   ->  1.1x
```

**81.2%** of revisions sit alone in their group, mean 1.16 files per group, because Team Coherence
increments each file's revision independently - a 50-file check-in produces 50 *different*
revision numbers with nothing to group. Batching is worth 11% of the calls in exchange for the
flattening risk above. Spend the effort on `TCDVcsCheckOutFile` instead, which removes the whole
930 ms overhead rather than amortising it across the rare group.

## The one thing that can silently ruin a migration

The **active Team Coherence view** decides what a revision number means. Under some views every
`-VR` request quietly returns the *tip*, with a success code — which would produce a repository
where every "historical" revision contains today's content.

Phase 4 proves this cannot happen: it asks for an impossible revision (`99.99`) and requires the
client to **fail**. If it succeeds, the migration aborts and tells you to switch to the
`<default>` view. Never bypass that check.

## Hazards found the hard way

Every one of these produced a migration that looked successful while being wrong. They are
recorded because none of them is visible in the code, and each cost a run to find.

### A finished run's failure count proves nothing

The 2026-09-26 full run reported `failed 0` and `All 44450 check-ins migrated`. **77 revisions had
never been fetched at all** - not fetched, not recorded as empty, not recorded as failed. It
resumed from check-in 35,307 and never revisited what lay behind its own checkpoint, and the
earlier sessions' attempts left no trace because `failed.csv` was never written.

A revision with no blob does not produce an error or an empty file. It leaves **the previous
revision's bytes in place**, so the history looks plausible and is wrong.

Verify a finished migration by reconciliation, not by the failure count:

```sh
# every revision key the metadata knows about
awk -F, 'NR>1{print $1"@"$(NF-5)}' meta/revisions.csv | LC_ALL=C sort -u > /tmp/all
# the ones we have content for, and the ones TC genuinely has no file for
awk -F, 'NR>1{print $1"@"$2}' meta/blobs.csv   | LC_ALL=C sort -u > /tmp/have
awk -F, 'NR>1{print $1"@"$3}' meta/skipped.csv | LC_ALL=C sort -u > /tmp/skip
# anything in none of them is an undocumented gap
LC_ALL=C comm -23 /tmp/all <(LC_ALL=C sort -u /tmp/have /tmp/skip)
```

That should print nothing. `git fsck` should also report no dangling blobs (see below).

To compare two repositories, use git, not shell text processing - **these paths contain spaces**,
and splitting `git ls-tree` output on whitespace yields confident nonsense:

```sh
REF=$(git -C old.git rev-parse tc/main^{tree})
GIT_ALTERNATE_OBJECT_DIRECTORIES=old.git/objects \
  git -C new.git diff --name-status "$REF" tc/main^{tree}
```

### Commit grouping: split a group when a file repeats in it

Revisions are grouped into check-ins by **author + comment**, over contiguous revisions in date
order, with no time limit. That is right for telling one check-in from another, and a 180-second
cap was wrong - it shattered 2,620 real check-ins into fragments.

But it is not sufficient on its own. A git tree holds **one** version of a path, so if a group
contains two revisions of the *same file*, only the last one survives and the earlier revision
disappears from history. On the 2026-09-26 full run that hid **9,327 revisions** across 2,349
files - visible only as dangling blobs in `git fsck`, because the content was fetched and written
but never referenced by a commit.

The rule must therefore be: **start a new commit as soon as a group would contain a second
revision of a file already in it.** No time window, nothing hidden, still one commit per check-in.

A clean way to check any future run: `git fsck` should report **no** dangling blobs. If it does,
count them - that is how many revisions are missing from the history.

### The app does not exit when it finishes

On completion `WorkerDone` logs `MIGRATION COMPLETE`, sets exit code 0 and calls
`Application.Terminate` - and then the main thread spins at ~96% CPU and the process never ends.
The supervisor is blocked on `-Wait`, so it never records completion and an unattended run never
reports done.

The work is genuinely finished when the log says `MIGRATION COMPLETE` and `state.txt` shows
`committed=` equal to the revision total; verify the repository with `git` and stop the processes
**supervisor first**, or it will relaunch on the non-zero exit code of the kill.

### Progress counters re-base at batch boundaries

After each batch commits, the overall percentage can step *backwards* and the rate can read
`0.0/s` with an ETA of tens of hours. The job is not stalled. The trustworthy numbers are the
revision count `(n/total)` and `committed=` in `state.txt`; the rate and ETA are computed from a
window that resets. This has repeatedly looked like a hang to the operator and is worth fixing
before anything else cosmetic.

### Never fetch one archive from two processes at once

Team Coherence returns **exit 0 with no files** when two `tc Get` calls touch the same archive
concurrently. Nothing reports an error. Because revisions are migrated in date order,
consecutive revisions usually belong to the *same* archive, so a naive worker pool does exactly
this and silently drops content.

The application marks an archive in-flight while fetching and hands each worker a revision whose
archive is free. Fetching may therefore run out of order; **committing is always in date order**.

That rule costs parallelism: a window dominated by one heavily-revised archive drops to a single
worker. Fetching from a wide window (several batches ahead) keeps enough distinct archives in
play. Do not "fix" the throughput by relaxing the one-archive rule.

### A count is not a diagnosis - verify

Two bugs came from inferring a cause from a failure count:

- Five failures in a row were treated as a dropped connection. They were five revisions of one
  unfetchable file. The run stopped for nothing. Now the server is **asked** whether it is still
  answering before the run gives up.
- Three failures on a file were treated as "this file cannot be fetched", and all its remaining
  revisions were skipped. That wrote off 15 healthy files - 10,900 revisions, **24% of the
  history** - when the real cause was concurrent archive access. Now a file is only written off
  after its **tip** has been fetched and failed, which proves the archive is bad.

### Three different "nothing came back", with three different meanings

| Signal | Meaning | Correct response |
|---|---|---|
| exit 0, no files, metadata size > 0 | concurrent-access corruption, or a transient fault | retry; never accept as empty |
| exit 85, "No file is available for this Revision" | TC holds no content for that revision - permanent | record in `skipped.csv`, never retry |
| exit 0, "No files found under \<path\>" | the path does not resolve - the file was deleted from TC | record in `failed.csv`; content is unreachable |

Collapsing these into one bucket caused silent data loss in one direction and abandoned runs in
the other. The metadata's recorded revision size is what makes the first case detectable.

### Deleted files enumerate but cannot be fetched

`TCDVcsEnumFiles` returns files that are no longer present at their path, so their revisions
appear in the metadata and then fail on fetch with "No files found under ...". `tc Dir` on the
folder does not list them. Their history is in the repository's metadata but their **content is
unreachable** - there is no fetch-by-file-id in the CLI and no content call in the API at all.
`failed.csv` records each one so the gap is documented rather than silent.

### Throughput, and where the time actually goes

Measured on the 2026-09-26 full run, a revision late in the job cost about **2,600 ms**. That
splits in two, and the split is what matters:

| | ms | |
|---|---|---|
| `tc.exe` process start, DLL load, connect, authenticate, exit | ~930 | pure overhead |
| server-side delta-chain reconstruction and transfer | ~1,670 | unavoidable here |

The 930 ms was measured with `tc Whoami`, which touches no archive at all (912/946/934 ms). It is
paid on **every** revision because the fetcher spawns the CLI per revision - **11.5 hours** across
44,450 revisions, spent entirely on starting processes.

The rest is TC reconstructing each revision by walking its delta chain from the beginning, which
is why a file at revision 1.165 costs many times what the same file at 1.1 does. Late in a run, when only
the heavily-revised archives are left, throughput drops to **0.2-0.4/s**; a whole-job average is
nearer 1/s. Expect **12+ hours** for a full migration and do not read the early figures as
representative - a resume races through already-cached revisions without contacting the server at
all, and will happily report 37/s.

The overhead half is avoidable: `TCDVcsCheckOutFile` with `Lock := False` fetches a revision by
file id straight through the DLL on the session already open, with no process to start. See
finding L21 in `Documents/12-Team-Coherence-to-Git-Migration.md`. It is the single biggest
speed-up available and it is not implemented yet.

### Run it under the supervisor

[`Run-Migration.ps1`](Run-Migration.ps1) relaunches the migrator until it reports success, which
is what makes a twelve-hour job practical. The migrator checkpoints every batch and resumes
bit-identically - verified by killing a run mid-flight and confirming the resumed repository had
the same commit count **and the same tip SHA** as an uninterrupted one.

Do not launch the migrator from a shell that may be reaped: a backgrounded subshell was killed
with its parent and cost a whole night's run, with a log that made it look as though the app had
been running the entire time.

## Safety

- Team Coherence is read from with a single verb: `Get`. No check-in, checkout, label,
  promotion or delete operation exists anywhere in the code.
- **One piece of state is changed, and always restored**: the active view. The migration runs
  under `<default>`, where revision numbers resolve correctly, and your own view is put back in
  a `finally` - after success, after an error, and after Stop. The view in force is logged at the
  start of every run, so if a previous run was force-killed before it could restore, you can see
  that immediately.
- Nothing is pushed. The result is a local bare repository; publishing it is a separate, deliberate act.
- No password is handled, prompted for, or stored by this program.

## Building

Win32 only — the Team Coherence DLLs are 32-bit, so the application must be too.

```
"C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc32.exe" -B TCMigrator.dpr
```

No IDE, no project file, no `.dfm`, no resources. The form is built in code so the whole thing
is plain text that compiles in one command.

| File | Contains |
|---|---|
| `TCMigrator.dpr` | Entry point |
| `uTCApi.pas` | Team Coherence API bindings and metadata extraction |
| `uPipeline.pas` | Fetch, fast-import stream building, import, verify |
| `uMain.pas` | The window |

### If you extend it

Two traps are worth knowing, both of which cost real time to find:

- **The API is ANSI.** `TCVcsApi.chm` says `PChar`, but Team Coherence 7.1 predates Delphi 2009,
  so it means `PAnsiChar`. Build it with a modern Delphi's `PChar` and every string is garbage
  while the numbers look perfect — and outgoing strings mangle too (`'Alice'` arrives as `"A"`).
  `uTCApi.pas` declares `PTCChar = PAnsiChar` for exactly this reason.
- **`TCVcsInitialize` must be called before `TCVcsLogin`**, or the login dies on a nil object.
  It returns code 59 here and the login still succeeds, so 59 is not fatal.

When a call fails unexpectedly, **check the VPN before suspecting the code**. A dropped VPN shows
up as an access violation inside `GPVMain.dll`, which looks exactly like a broken binding.
Pressing **Connect** re-tests reachability in about two seconds.
