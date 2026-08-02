import Foundation

/// Abstracts terminal-lifecycle teardown away from `AppStore` so it can be
/// tested without spinning up real `TerminalView`/`GhosttyTerminal` state.
/// `TerminalCenter` is the production conformer; tests inject a spy.
@MainActor
protocol SessionTerminating: AnyObject {
    var onProcessExit: ((String) -> Void)? { get set }
    func closeSession(_ id: String)
}
