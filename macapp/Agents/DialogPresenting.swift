import AppKit

/// Distinguishes "the user confirmed, leaving the message field empty (or
/// there was no field at all)" from "the user cancelled" — a distinction
/// the old `promptLandMessage`'s `String?` return could NOT represent: it
/// collapsed blank input and Cancel down to the same `nil`, and its caller
/// (`AppActions`) treated any `nil` as "cancelled". The result was that
/// confirming with an empty message field silently did nothing at all, with
/// no feedback — a real bug, not a hypothetical one. This enum exists
/// specifically so that class of bug is unrepresentable going forward, not
/// just patched at today's one call site.
enum LandDecision: Equatable {
    case cancel
    case land(message: String?)
}

/// Abstracts AppKit dialog presentation away from `AppActions` so its
/// routing logic can be tested without a running NSAlert/NSOpenPanel modal
/// loop — mirrors the `SessionTerminating`/`WorkspaceEngineProviding` seams
/// already used by `AppStore`. `LiveDialogPresenter` (below) is the
/// production conformer, forwarding to the real `Dialogs` enum; tests
/// inject a fake. Covers the 7 operations `AppActions` actually calls.
/// `promptRename` has two callers: this seam, for the selection-targeted
/// menu item/shortcut routed through `AppActions`, and a direct call from
/// SidebarView's row-targeted "Rename…" context-menu item, which acts on a
/// specific row rather than `store.selection` and so has no need of
/// `AppActions` or this seam at all. `promptNewWorkspaceLabel` is the same
/// shape: this seam for the global `.newWorkspace` action, plus a direct
/// `Dialogs.promptNewWorkspaceLabel()` call from SidebarView's
/// project-header "New Workspace" item, which acts on a specific project
/// rather than app-wide state. `promptWorkspaceLabel(currentLabel:)` is the
/// odd one out, like `promptRename`'s second caller: it's called ONLY from
/// SidebarView's row-targeted "Change Label…" context-menu item, which acts
/// on a specific workspace row rather than `store.selection`, so it has no
/// need of `AppActions` or this seam at all. `confirmLand`/
/// `confirmRebaseOntoTrunk` are a THIRD shape: both of their callers — the
/// selection-targeted `.keepWorkspaceChanges` case in `AppActions`, and
/// SidebarView's row-targeted "Keep Changes…" context-menu item — reach
/// this seam only indirectly, through `AppStore.reviewAndLandWorkspace(_:
/// dialogs:)`. Landing now needs an async preview fetched before any dialog
/// can be shown at all, so that orchestration (preview → dialog → land →
/// optional rebase-offer) lives on `AppStore` and takes a `DialogPresenting`
/// as a parameter; `AppActions` passes its own `dialogs` through, and
/// SidebarView constructs a fresh `LiveDialogPresenter()` the same way it
/// already does for its other direct `Dialogs` calls.
@MainActor
protocol DialogPresenting {
    func chooseProjectDirectory() -> String?
    func confirmRemove(_ project: Project) -> Bool
    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool
    func confirmLand(workspace: WorkspaceRow, preview: LandPreview) -> LandDecision
    func confirmRebaseOntoTrunk(count: Int, bookmark: String) -> Bool
    func promptRename(currentName: String) -> String?
    func promptNewWorkspaceLabel() -> String?
}

/// Production conformer: forwards straight through to `Dialogs`.
@MainActor
struct LiveDialogPresenter: DialogPresenting {
    // Explicitly nonisolated, same reasoning as WorkspaceEngineCLI's init:
    // conforming to the @MainActor protocol infers whole-type MainActor
    // isolation, which would otherwise make this initializer MainActor-
    // isolated too — and AppActions.init's default argument
    // (`dialogs: ... = LiveDialogPresenter()`) is evaluated in a
    // synchronous, nonisolated context, so it couldn't call an isolated
    // init. The init itself touches no actor-isolated state, so opting it
    // out here is safe.
    nonisolated init() {}

    func chooseProjectDirectory() -> String? { Dialogs.chooseProjectDirectory() }
    func confirmRemove(_ project: Project) -> Bool { Dialogs.confirmRemove(project) }
    func confirmDeleteWorkspace(_ ws: WorkspaceRow) -> Bool { Dialogs.confirmDeleteWorkspace(ws) }
    func confirmLand(workspace: WorkspaceRow, preview: LandPreview) -> LandDecision {
        Dialogs.confirmLand(workspace: workspace, preview: preview)
    }
    func confirmRebaseOntoTrunk(count: Int, bookmark: String) -> Bool {
        Dialogs.confirmRebaseOntoTrunk(count: count, bookmark: bookmark)
    }
    func promptRename(currentName: String) -> String? { Dialogs.promptRename(currentName: currentName) }
    func promptNewWorkspaceLabel() -> String? { Dialogs.promptNewWorkspaceLabel() }
}
