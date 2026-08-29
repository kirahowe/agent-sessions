# Workspace closing

## Mental model

A project has shared, integrated progress. Each workspace is an isolated draft
containing changes to that project. Closing a workspace either adds its draft
to the project's current progress and removes the workspace, or closes it
without adding those changes.

Branches, bookmarks, rebases, forks, divergence, and commit IDs are storage
implementation details. They do not belong in the normal closing flow.

When two workspaces begin from the same project state, closing one advances the
project. The other remains a valid draft. It reconciles with the latest project
state automatically when it is eventually closed. Open agent workspaces must
not be eagerly rewritten underneath running sessions.

An overlap is the exceptional case. The operation changes nothing, preserves
the workspace, and explains that its changes need attention.

## Invariants

1. A workspace can add only changes owned by that workspace.
2. Adding changes is atomic: every change reaches project progress, or nothing
   changes and the workspace remains open.
3. Active workspaces retain stable files and history while sibling workspaces
   close.
4. Reconciliation with newer project progress is automatic and lazy.
5. The project working copy follows newly integrated progress automatically
   only while no session is open in the project root, and only when it can do
   so without conflict. A root session's files must not change underneath it,
   exactly as invariant 3 protects sibling workspaces. Otherwise the project
   is flagged for attention and the user brings it up to date from the project
   menu. Neither a deferral nor an overlap retroactively turns a successful
   close into a failure.
6. Concurrent repository activity must not be lost by speculative previews or
   rollback of unrelated operations.
7. Every terminal rooted in the workspace is stopped before the engine begins
   a land or forget operation. Stopping ends the process, so the sheet states
   that cost before the user commits to it, and a refused operation brings each
   session back as a fresh shell with its saved resume hint. Rows and resume
   metadata remain intact until the engine confirms whether the workspace was
   removed.

## Experience

The workspace menu has one primary operation: **Close Workspace…**

For a workspace with changes, the sheet names the workspace and project, lists
human-readable change summaries, and offers:

- **Add Changes & Close** — add the draft to project progress, then remove the
  workspace.
- **Close Without Adding…** — remove the workspace without advancing project
  progress. This is destructive and visually secondary.
- **Cancel**.

The sheet says “changes,” not “commits.” It does not show trunk names, bookmark
hashes, clean-conflict checkmarks, divergence warnings, or instructions to
rebase. If undescribed working-copy changes need a summary, the sheet asks for
one only in that case.

Because the workspace's files are about to be rewritten, either operation
first stops every session in the workspace. The sheet says how many sessions
it will stop; a session that comes back after a refused close prints its
resume hint.

A workspace with no changes offers **Close Workspace** and **Cancel**.

A project with no shared progress yet is offered **Set Up Project & Close**,
which establishes the project's starting progress from these changes. The
trunk name the engine creates for that (`main`) is an engine default the sheet
never shows.

If changes overlap newer project progress, the attempted add changes nothing
and leaves the workspace open. The result explains that the changes need
attention and offers **Return to Workspace** plus the separately destructive
**Close Without Adding…** path. It never offers an add action known to fail.

If new work reaches the workspace while its changes are being added, the
changes are still added but the workspace stays open: the sheet says so and
offers **Return to Workspace**, and closing it again reviews only the newer
work.

The sheet remains present while preparing, adding, and closing. Success reports
the number of changes added and any follow-up notice, and dismisses on
**Done**; the workspace row is removed the moment the engine confirms the
close. There is no second rebase dialog.

## Integration design

Use `workstream-manager` as the standalone workspace engine instead of
maintaining or copying an implementation inside Agents. Until the library is
published, the thin `agents-cli` wrapper temporarily adds the external
checkout's `src` directory to Babashka's classpath, resolving the checkout from
a nonblank `WORKSTREAM_MANAGER_ROOT` or from
`~/code/projects/workstream-manager` by default. The external checkout remains
the source of truth. The next step is vendoring rather than publishing:
Babashka git dependencies need a JVM to resolve, which these machines do not
have, and Jujutsu makes git submodules awkward. A `bb vendor` task will copy
`src/wsm` at a pinned commit into a bundled resource directory that the wrapper
falls back to when `WORKSTREAM_MANAGER_ROOT` is unset and the default checkout
is absent, so release builds carry workspace features without a sibling
checkout. Only this bootstrap changes when that lands.

The app and Xcode release builds bundle only the thin wrapper, so they continue
to compile without the local checkout. In that environment workspace operations
are unavailable and the wrapper returns its single JSON error envelope rather
than a stack trace. Repository and copied-script integration tests point
`WORKSTREAM_MANAGER_ROOT` at a provisioned checkout. CI provisions that
checkout and runs integration tests in required mode: an unavailable checkout,
missing dependency, or skipped manager case fails the build rather than reducing
coverage.

The app-facing CLI remains a stable JSON subprocess boundary. It delegates
workspace creation, listing, forgetting, previewing, and landing to
`workstream-manager`, adding only app-specific defaults such as the `agents`
namespace if the library does not already provide them.

Every successful land payload includes a required workspace_retained boolean.
The app removes sessions and rows only when it is false; when it is true, the
workspace remains open and its terminals are recreated with their resume hints.
Every successful preview also carries an opaque snapshot of the exact target and
preferred project progress used to compute its change list. The application
retains that value with the prepared sheet without presenting it to the user.
Before any land, the app frees the workspace's terminal surfaces, supplies the
manager's explicit quiesced-finalization flag, and round-trips the preview
snapshot. The manager rechecks that exact state after quiescence and before its
first mutation. If either workspace or preferred project progress changed, it
refuses the stale application; Agents preserves all rows and persistence,
resumes the sessions with their saved OMP metadata, clears any summary written
for the stale preview, and immediately prepares the current project-oriented
change list.

A no-changes preview is advisory rather than deletion authorization. After
quiescing terminals, the app asks the manager to forget only if the workspace is
still unchanged; a race-time change preserves the workspace, resumes its
sessions, and refreshes the sheet with the new changes. Only the separately
confirmed **Close Without Adding** path uses an explicitly destructive forget.
Any forget failure leaves all live and persisted app state intact, while local
folder cleanup after manager success is only a non-fatal notice.

Speculative Jujutsu conflict checks must not perform a repository-wide
`jj op restore` after temporarily integrating a rebase. Use an unintegrated
operation and inspect it with `--at-operation`, or an equivalent targeted
transaction supplied by `workstream-manager`. Actual application must recheck
current state and remain the enforcement point because project progress can
change after a preview.

Other agent workspaces are not rebased after a successful close; their future
land operation already reconciles them with current project progress. The
project working copy is reconciled automatically only while no root session is
open; with a root session live the app defers, flags the project, and leaves
reconciliation to the project menu's manual refresh, which is never gated. A
conflict or a deferral is reported as structured, non-fatal follow-up
attention while the workspace close itself remains successful.

## Delivery sequence

1. Replace the duplicated workspace script with the local
   `workstream-manager` dependency while preserving the app's JSON contract.
2. Harden Jujutsu preview/application transactions for concurrent operations.
3. Unify keep/delete affordances into the close-workspace sheet and remove
   branch-oriented language and the post-land rebase prompt.
4. Add contract and behavioral coverage for clean close, close without adding,
   no changes, automatic reconciliation, overlap rollback, and concurrent
   repository activity.
5. Review the complete diff in the main loop, delegate repairs, run focused
   CLI and macOS verification, then complete interactive RevDiff review.
