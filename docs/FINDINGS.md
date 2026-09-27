# What Team Coherence does, and what it does quietly

Everything here was learned by doing a real migration, and every item cost at least one run. They
are written down because none of them is visible in the code, and most of them return success.

Measured against **Team Coherence 7.1** (client files dated 2009). The repository was a few thousand file
archives and tens of thousands of revisions, spanning more than two decades.

---

## The API

### `PChar` in the documentation means `PAnsiChar`

TC 7.1 predates Delphi 2009. Compile against `TCVcsApi.chm`'s signatures with a modern Delphi,
where `PChar` is `PWideChar`, and every string crossing the boundary is garbage **while the numeric
fields stay perfect** — a connection enumerator returning `Port=2004` correctly beside a host name
of `?????????????`. It corrupts outgoing strings too: `'Alice'` as UTF-16 is read as `"A"`, so early
login attempts authenticate a user that does not exist.

Declare `PTCChar = PAnsiChar` and marshal through `AnsiString`.

### The CHM will not decompile from under `Program Files`

`hh.exe -decompile <outdir> TCVcsApi.chm` silently produces **nothing** while the CHM sits in
`Program Files`. Copy it elsewhere first. It then yields 162 pages, which are authoritative — guessed
prototypes cause access violations.

This is worth stating loudly because a failed extraction reads as "undocumented". It cost the
discovery of a whole bulk-export API twice.

### `TCVcsInitialize` must precede `TCVcsLogin`

`TCVcsInitialize(Handle, LoadCache, ProgressProc)` then `TCVcsLogin` reuses the credentials the TC
client already holds, so a tool can log in without handling a password at all. `TCVcsInitialize`
returns **59** and the login still succeeds — that code is not fatal. Calling `TCVcsLogin` without
initialising dies on a nil object.

`TCDVcsConnect(connection, user, password)` is the non-interactive alternative.

### `RootID` must be a **file** id to read a revision's labels

`TCDVcsEnumLabels(RootID, RevID, LabelType, …)` documents `RootID` as "a Project, Folder, **or a
File**". Per-revision labels only work when it is a **file** id. Pass a *project* id and it returns
**nothing at all, silently, with `Err_OK`** — tens of thousands of calls produced an empty attachment file.

**An empty attachment list is a failure, not a repository without labels.** Assert it.

### `RevID = 0` answers a different question, convincingly

With a real `RevID` you get that revision's labels. With **0** you get the labels on the whole
**file**, for every revision alike, with `Err_OK`. If your metadata does not persist TC's internal
revision id, a run working from saved metadata passes 0 and cheerfully produces a complete-looking
dataset in which every revision of a file carries all of that file's labels.

That ran for five hours before anyone looked at the shape of the data: 36 attachments per revision
is not a dense region, it is the signature of the bug. **Persist `rev_id`, and refuse to run the
label pass without it.**

### `VerCount` is free, and it makes the label pass affordable

The revision enumeration callback hands you `VerCount` — how many version labels that revision
carries — and `PromoCount`. Keeping it means only revisions with `VerCount > 0` need to be asked
*which* labels they carry: **a fifth of the calls**, because only 18% of revisions carried
a label. It also makes a "does this file have any label" pre-scan pointless — that scan took 2.5
hours across every file in the repository to answer a weaker question.

Better still, it is an **independent cross-check**: TC states the total before anything asks what
the labels are, so the two numbers must agree.

**Read the whole callback signature.** Two fields were being discarded that between them saved
hours and caught a class of error.

### Content can be fetched through the DLL, and should be

`TCDVcsCheckOutFile(FileID, var RevisionID, PCheckOutInfo)` is titled, in QSC's own help, *"**Get**
or Check out a file"*. With `Lock := False` it is a pure read — verified by `tc ListLockedFiles`
being empty after tens of thousands of calls.

Measured against spawning `tc.exe` per revision: **0.21 s vs 2.6 s per revision**, because a bare
`tc Whoami` — touching no archive at all — costs **~930 ms** of process start, DLL load, connect and
authenticate. Multiplied by every revision that is hours spent purely on starting processes. A full pull went
from roughly twelve hours to under two - about 8x end to end.

It also produced **fewer wrong revisions** than the CLI path (42 against 83, a strict subset), and
needs no workaround for paths containing spaces, because a path is a parameter rather than something
a command line can misparse.

The 7.1 record has **no `Flags` field** (later headers do). Declare it and zero it: a 7.1 DLL ignores
a trailing field, while omitting one a newer DLL expects makes it read the stack. Buffer sizes from
`InitializeCheckOutInfo`: `Comments` and `Extra` 65536, `Revision` 255, `LocalPath` 512 — the DLL
writes back into them, so they must be allocated.

### There is a bulk export API, undocumented in the CLI

`TCDVcsBeginExport` / `GetExportSize` / `GetExportData` / `GetExportProgress` / `EndExport`, plus
`VcsExport(What, ProjectID, FileName, Progress)` where `What` combines `IE_HasUsers` and
`IE_HasArchives`. Also exported and genuinely undocumented: `TCDVcsGetFileArchiveName`,
`TCDVcsBeginAction` / `EndAction`, `TCDVcsEnumNewFiles`.

Not used here — the format is TC's own and would need reverse-engineering — but if you need whole
archives rather than individual revisions, start there.

---

## The command line

`tc.exe Help` lists 34 commands; `tc.exe Options` details every switch. Both are worth reading in
full before writing anything.

### `-VR` selects one revision **per command**

There is no per-file revision syntax inside an `@filelist`, and **no date selector** — the only
whole-tree selectors are latest, a version label (`-VL`), or a promotion level (`-VP`). So you
cannot ask for "the tree as of 3 March 2004", which is the one thing that would make this easy.

Consequently **batching barely helps for history**. Counted against a real repository: the only
files that can share a `Get` are those inside one check-in that happen to share a revision number,
and TC increments each file's revision independently. the revisions collapse to 89% as many calls —
**1.1×** — with 81% of revisions sitting alone in their group.

### `tc.exe` cannot parse a path containing a space, even quoted

It silently falls back to the current folder and reports "No files found under …". This affected 117
files and 4.3% of all revisions. Passing the path in a list file (`Get "@list.txt"`) bypasses the
command-line parser and works. The DLL path has no such problem.

### Changing the view leaves the current folder stale

After `SetView`, the client's current-folder cache is stale and absolute paths resolve against the
wrong folder. This produced **788 phantom "unfetchable" revisions**. Re-anchor with `CD <project>`
after every view change.

Run migrations under the **`<default>`** view. Some views return the *tip* for any revision
requested, which would store today's content under every historical revision — test for it by
requesting an impossible revision and confirming it is rejected.

### Never fetch one archive from two processes at once

TC returns **exit 0 with no files** when two `Get` calls touch the same archive concurrently.
Nothing reports an error. Revisions are migrated in date order and consecutive revisions usually
belong to the *same* archive, so a naive worker pool does exactly this and silently drops content.

Measured, after fixing the folder-cache bug above: **one worker is about forty times faster than
four**. An earlier "four is the sweet spot" measurement was taken *through* that bug and was wrong.

---

## Three different "nothing came back"

| Signal | Meaning | Correct response |
|---|---|---|
| exit 0, no files, metadata size > 0 | concurrent-access corruption, or transient | retry; never accept as empty |
| exit 85, "No file is available for this Revision" | TC holds no content for that revision — permanent | record it; never retry |
| exit 0, "No files found under \<path\>" | the path does not resolve — the file was deleted from TC | record it; the content is unreachable |
| exit 43 / 61 | damaged revision | retry, then record. Ours failed identically through the CLI *and* the DLL, which is how we knew the archive was damaged rather than our access being wrong |

Collapsing these into one bucket caused silent data loss in one direction and abandoned runs in the
other. The metadata's recorded revision size is what makes the first case detectable.

`TCDVcsEnumFiles` also returns files that no longer exist at their path, so their revisions appear
in the metadata and then fail on fetch. There is no fetch-by-file-id in the CLI, so their content is
genuinely unreachable.

---

## Modelling TC in git

### TC records no changeset

A check-in of 50 files increments each file's revision **independently**, so there is no changeset
to recover. Reconstruct one from contiguous revisions sharing an author and a comment.

**Do not use a time window.** A genuine check-in can take hours to upload — one here spans 16 hours
and 652 files — and a 180-second cap shattered thousands of real check-ins into fragments.

### But you must split when a file repeats

A git tree holds **one** version of a path. If a group contains two revisions of the same file, only
the last survives and the earlier revision disappears — fetched, written as a blob, then referenced
by nothing. That hid **a fifth of the revisions, across hundreds of files**, visible only as dangling blobs in
`git fsck`.

Start a new commit as soon as a group would contain a second revision of a file already in it. No
time window needed, nothing hidden.

**Acceptance test: `git fsck` should report no dangling blobs.** If it does, that count is how many
revisions are missing from your history.

### A version label is not a pointer to a commit

It is a list of (file, revision) pairs that can mix revisions from any point in history and need not
correspond to any commit that ever existed. So emit each label as a **root commit with `deleteall`
plus exactly the labelled revisions**, as a tag.

Put them in `refs/tags/`. `refs/heads/<branch>/label/<name>` **cannot exist** while
`refs/heads/<branch>` does: git keeps a ref as a *file*, so the same path cannot also be a directory.
Get this wrong and `fast-import` writes every label commit and then fails every ref update, leaving
dangling commits and no tags.

Sanitise label names for git, and check the sanitised names for collisions — "V 4.2" and "V/4.2"
both reduce to `V_4.2`, and the second would silently replace the first.

### Deletions cannot be dated

A deleted file simply stops being listed; its revisions remain in the metadata. What *can* be
established is which files no longer exist now, so remove those in one final commit that says
plainly it is a tip correction rather than history.

---

## Verification, and why most of it is weak

Two independent migrations of the same repository — one fetching content via `tc.exe`, one via the
DLL — agreed on the commit count, the tag count, the same tip tree, the same 6 unfetchable revisions, and
the same label totals. **They differed in 4,166 commit trees: 16% of the history.**

One bad revision contaminates every later commit's tree until some revision replaces it, so a
handful of wrong revisions produced 16%.

The check that resolved it: **sum each archive's member sizes and compare with the size TC recorded
for that revision.** Those are different calls. For one file's revision 1.5 the DLL run's members
summed to exactly TC's recorded 225,933; the CLI run's summed to 91,312.

Ranked by strength:

1. **Fetched size vs TC's recorded size** — the only check that catches content which arrived but is
   wrong. A *match* is strong evidence; a *mismatch* only says the two disagree
2. **`git fsck` dangling blobs** — catches content fetched but not committed
3. **Revisions vs fetched + known-empty** — catches revisions never attempted. A resumed run cannot
   find a gap that lies behind its own checkpoint, so this must be run over the whole repository
4. **Comparing two of your own runs** — catches non-determinism, but two runs can agree while both
   are wrong

A run's own failure count is not verification. One reported `failed 0` while 77 revisions had never
been fetched, because it resumed past them and nothing recorded the earlier attempts.

### Distinguishing a real size mismatch from TC's own bookkeeping

Not every mismatch is lost content. A **large shortfall**, or a revision where a second migration
matched and this one did not, means wrong content was fetched. A **small constant gap across a
contiguous run of one file's revisions** is TC's recorded size being wrong — re-fetching returns
byte-identical content, and there is no third source to arbitrate. This repository ended with 42 of
the second kind and none of the first.

---

## Operational notes

- **The VPN tunnel type dominates everything else.** IPsec against SSL, same machine, same server,
  same command: **~6.7×**.
- **A dropped VPN looks exactly like an API failure.** An API call died with an access violation
  inside the TC DLL and showed TC's own "Connection Error" dialog. Check the link before suspecting
  the code.
- **A dead socket will hang you forever.** After a VPN blip, TCP still reports `Established` while
  the TC DLL waits with no timeout. One pass sat for 73 minutes having used 7.8 seconds of CPU.
  Diagnosis: zero CPU over 45 seconds with a frozen handle count, while a fresh connection works.
  Add a watchdog that abandons an attempt making no progress, and let the supervisor resume it.
- **Checkpoint anything long.** And never let a crash log and a derived file be the same file: a
  routine that rewrites a file from an in-memory list will truncate the log you are flushing to it.
- **Paths in a real repository contain spaces *and* commas.** Splitting `git ls-tree` output on
  whitespace produced a confident "47,584 differing paths" where the real answer was four. Compare
  repositories with git (`GIT_ALTERNATE_OBJECT_DIRECTORIES` and `git diff`), and parse CSVs from the
  right, since only the path field contains the delimiter.
- **Keep the content cache.** It is content-addressed, so re-importing the whole history from it
  takes minutes and needs no server at all. Re-fetching takes hours.
