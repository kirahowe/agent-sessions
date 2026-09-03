# Project archiving

## Mental model

The sidebar lists the projects you are working in. A project you are not
working in right now can be archived: it leaves the list, its terminals stop,
and everything the app knew about it is kept whole — its sessions with their
names, agent titles and resume hints, and its workspace rows. Restoring the
project puts all of that back exactly as it was.

Archiving is bookkeeping in the app, not an operation on the project. Nothing
on disk changes: not the project directory, not its workspaces, not its
repository. That is the same promise Remove Project already makes; archiving
adds the promise that the app's own record survives too.

Remove Project remains the way to forget a project entirely, whether it is
active or archived.

## Invariants

1. Archiving a project preserves every session row and workspace row it had,
   in order, and restoring it reinstates them unchanged. Session identity
   (ids) survives, so persisted resume metadata and terminal-view identity
   are the same after a restore as before the archive.
2. Archiving touches nothing on disk and never calls the workspace engine.
3. Archived rows are never live: they are not in `sessions`, `workspaces` or
   `projects`, so no consumer of those arrays — the sidebar, the dashboard,
   the Dock badge, navigation, workspace operations — needs to know archiving
   exists. Attention state for archived sessions is dropped, exactly as it is
   for closed sessions; it describes processes that no longer exist.
4. A path is in at most one place: active or archived, never both. Adding a
   project whose path is archived restores it rather than creating a second
   copy.
5. Every terminal in the project is stopped before its rows are parked, the
   same way Remove Project stops them. A session that was running an agent
   keeps its resume hint, so reopening it after a restore prints the resume
   command just as it does after a relaunch.
6. Archiving is reversible in one action and therefore asks no confirmation.
   Removing is not, and keeps its confirmation.

## Experience

**Archiving.** The project row in the sidebar is a List row (previously a
Section header), with its sessions and workspaces nested beneath. Swiping the
row leftward reveals **Archive**; a full swipe archives outright, as in Mail.
The same action is on the row's ellipsis menu and context menu, and on the
File menu as **Archive Project** for the selected session's project. The
selection moves to the next project's first session — the previous project's
when the archived one was last — so the terminal area never goes blank while
other projects remain.

**The Archived section.** When at least one project is archived, a collapsed
**Archived** disclosure appears at the bottom of the project list, above Add
Project, with a count. It is ordered most recently archived first. Each row
shows the project name with its path beneath in secondary text. Clicking a
row restores the project and selects its first session; a project archived
with no sessions gets a fresh one, as Add Project would give it. Swiping the
row rightward reveals **Restore**. The row's ellipsis and context menus offer
**Restore Project** and **Remove Project…**, the latter with the usual
confirmation.

**Naming.** "Archive" is used rather than "Close": Close Workspace moves files
to the Bin, and a Close Project that touched nothing on disk would suggest
otherwise. "Archived" rather than "Recent": the section holds projects that
were deliberately parked, not a history of everything ever opened.

## Integration design

- `ArchivedProject` is a persisted record of `{path, archivedAt, sessions,
  workspaces}`. `PersistedState` gains an optional `archivedProjects` array,
  decoded as empty when absent, so existing state files load unchanged and
  the version stays at 2. `archivedAt` is recorded now so a later automatic
  "archive projects idle for N days" needs no migration; nothing tracks
  per-project activity yet.
- `AppStore.archiveProject(_:)` mirrors `removeProject(_:)` — stop terminals,
  drop live rows, prune attention, drop the lifecycle token, clear
  project-working-copy attention and any close-workspace presentation for
  the project — then parks the rows in `archivedProjects` instead of
  discarding them.
- `AppStore.restoreProject(_:)` appends the project to the end of the active
  list, the same place Add Project puts a new one, reinstates its rows, mints
  a fresh lifecycle token, and seeds the session counters for the restored
  targets so a new session continues the numbering rather than reusing
  "Session 1".
- `removeProject(_:)` also purges the path from `archivedProjects`, so one
  function forgets a project wherever it is.
- `AppAction.archiveProject` is menu-only like `removeProject`, and resolves
  its target the same way (selected session's project, else the sole project).

## Delivery sequence

1. Model and store: `ArchivedProject`, persistence, archive/restore/remove
   semantics, with store tests for the invariants above.
2. Action and menus: `AppAction.archiveProject`, File menu item, action tests.
3. Sidebar: the project header becomes a row with the Archive swipe; the
   Archived section with restore.
4. README and TODO.

## Non-goals

- Automatic archiving by inactivity. The persisted shape allows it later.
- Project reordering and per-project collapse. The row restructure in step 3
  is the prerequisite for both; neither is built here.
- Any change to what Remove Project does to on-disk state (nothing).
