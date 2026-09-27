# tc2git — Team Coherence to git migration

Migrates a [Team Coherence](https://www.teamcoherence.com/) repository into git: every file
revision as a commit, every version label as a tag, with verification that the content it wrote is
the content Team Coherence holds.

Built against **Team Coherence 7.1** (QSC, files dated 2009) and used to migrate a real 23-year
repository: **4,237 file archives, 44,450 revisions, ~10 GB, 1996–2019**, producing 25,852 commits
and 38 tags.

## Why this exists

Team Coherence is a lock-based version control system last released around 2009. Its vendor is
gone, its documentation is a CHM file, and its API will answer the wrong question with
`Err_OK` and plausible-looking data if you ask it slightly wrong. There is no supported export.

The hard part is not writing commits — it is knowing that what you wrote is correct. Most of this
codebase is that: the checks, and the comments explaining which failures each one exists to catch.
Every one of those comments describes something that actually happened.

## What it does

- **Commits** — one per check-in, reconstructed from contiguous revisions sharing an author and
  comment, since TC records no changeset
- **Tags** — one per version label, each holding the exact tree that label describes
- **Deletions** — files no longer in TC are removed in one final, honestly-labelled commit
- **Resumable** — checkpoints every batch; a dropped VPN costs one batch, not the run
- **Verified** — reconciles revisions against fetched content, runs `git fsck`, and checks every
  archive's fetched size against the size TC recorded for that revision

## Requirements

- Windows, with the **Team Coherence client installed** (the DLLs are 32-bit)
- **Delphi** to build — `dcc32`, Win32. Tested with Delphi 12; no `.dfm` or `.res`, the form is
  built in code, so it compiles with one command
- `git` on `PATH`
- Read access to a TC server, and a TC login

## Build

```
dcc32 -B src\TCMigrator.dpr          # the migrator (Win32, NOT dcc64)
dcc32 -B tools\tcdump\TCDump.dpr     # metadata/diagnostic console tool
```

## Run

```powershell
$env:TCPWD = 'your-tc-password'      # never written to disk by these tools
.\Run-Migration.ps1 -Work D:\migration -User jsmith -Tags
```

`Run-Migration.ps1` supervises the migrator and relaunches it until it reports success, which is
what makes a multi-hour job practical. Read [docs/OPERATING.md](docs/OPERATING.md) before a real
run — particularly *Hazards found the hard way*, which is the part that will save you a repeat.

## Read this before you trust a migration

Four numbers, produced by different calls than the ones that did the work:

| Check | What it catches |
|---|---|
| revisions vs fetched + known-empty | a revision never fetched at all. A run once reported `failed 0` with 77 revisions never attempted |
| `git fsck` dangling blobs | content fetched but referenced by no commit — 9,327 of them exposed a grouping bug that hid 9,327 revisions |
| label attachments vs TC's own `ver_count` | a label pass that silently answered a per-file question instead of a per-revision one |
| **archive size vs TC's recorded size** | **content that arrived but is wrong.** Two migrations of the same repository differed in 16% of commit trees; this is the check that said which was right |

That last one was added late, after a repository had already passed the other three while holding
wrong bytes across a sixth of its history. A check that two things *you* produced agree with each
other is weak. A check against a number the server stated independently is strong.

## Status and limitations

Used successfully for one large migration. Not widely tested — expect to read the code.

- **Views and promotion levels are not migrated.** TC views are enumerated but not turned into refs
- Commit SHAs are not reproducible across runs (committer timestamps), so compare **trees**
- Some revisions may be unrecoverable: this repository had 6 that failed identically through two
  independent access paths, which is TC's storage being damaged rather than a tool problem
- Windows only, and Win32 only, because the TC client DLLs are

## Licence

**No licence has been chosen yet** — add one before publishing. Until a `LICENSE` file exists, all
rights are reserved by default and others cannot safely reuse this.

## Contributing

If you are migrating off Team Coherence and something here is wrong or missing, an issue describing
what your repository did differently is more useful than a patch. The failure modes documented in
[docs/FINDINGS.md](docs/FINDINGS.md) are all from one repository; yours will have others.
