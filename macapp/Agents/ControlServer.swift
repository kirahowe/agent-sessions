import AppKit
import Darwin
import Foundation

/// A tiny local control channel: a Unix domain socket that lets a process
/// running *inside* one of this app's terminals ask the app to do something
/// that process cannot do for itself.
///
/// Exactly one verb today — `overlay-run`, which drives `OverlayCenter` on
/// behalf of the revdiff launcher. See that type for why a review TUI cannot
/// simply draw into the terminal that asked for it.
///
/// Why a Unix socket rather than the two obvious alternatives:
///
/// - **AppleScript** is what stock Ghostty and iTerm2 expose, and what
///   revdiff's bundled launcher reaches for. It would mean shipping an
///   `.sdef`, and it drags in TCC: the first call raises an Automation
///   consent prompt, and Claude Code's own sandbox blocks Apple Events
///   outright unless the launcher is added to `excludedCommands`. A socket
///   needs none of that.
/// - **A URL scheme** (`open agents://…`) is less code here, but LaunchServices
///   resolves a scheme to *one* bundle, so the Debug and Release builds —
///   which deliberately differ only by bundle id — would fight over it, and a
///   review fired from the dev build could surface in the release app. It is
///   also fire-and-forget, with no way to report completion.
///
/// The socket path carries the bundle id, so each build gets its own endpoint,
/// AND the pid of the process that bound it, so two launches of the same
/// binary can never contend for one endpoint either — including a test-host
/// launch, which boots this same `AgentsApp.init` (see `AgentsApp`) and would
/// otherwise steal the running app's socket file for the seconds it takes to
/// run and exit, leaving the real app listening on an unlinked inode with no
/// way back in. The path is stamped into every session's environment as
/// `AGENTS_CONTROL_SOCK` (see `TerminalCenter.sessionEnvVars`), so a client
/// always finds its own instance directly — no discovery, no guessing, no
/// cross-build mixups, and no cross-instance contention.
///
/// The connection is the completion signal: the server holds it open for the
/// life of the overlay and writes its reply only once the command has exited.
/// A caller blocks on a socket read instead of polling for a sentinel file,
/// and a caller that dies takes nothing with it.
final class ControlServer: @unchecked Sendable {
    /// Absolute path of this process's socket.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, which is the real
    /// constraint on where this can live; Application Support keeps it well
    /// inside that with room for the longest bundle id in use, and the pid
    /// suffix only ever adds another five to seven digits on top.
    static let socketPath: String = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let directory = base.appendingPathComponent("Agents", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kirahowe.agents"
        let pid = ProcessInfo.processInfo.processIdentifier
        return directory.appendingPathComponent("\(bundleID).control.\(pid).sock").path
    }()

    /// Directory holding every build's control sockets, live or dead —
    /// `socketPath` with its last component removed. Shared by the startup
    /// sweep, which has to look at siblings this instance did not create.
    private static var socketDirectory: String {
        (socketPath as NSString).deletingLastPathComponent
    }

    /// Prefix shared by every socket file this bundle id could ever have
    /// created, at any pid, past or present: `<bundleid>.control.`. Scoping
    /// the sweep to this prefix is what keeps a dev build from ever touching
    /// a release build's socket, or vice versa.
    private static var socketPrefix: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kirahowe.agents"
        return "\(bundleID).control."
    }

    private struct Request: Decodable {
        let cmd: String
        let command: String?
        let cwd: String?
        let session: String?
    }

    /// What one request line asks the app to do, after syntactic validation
    /// but before any main-actor state (live sessions, open reviews) is
    /// consulted. Extracted from `serve` so the wire-format rules — the
    /// contract the revdiff launcher is written against — can be pinned in
    /// tests without standing up a socket.
    enum RequestDecision: Equatable {
        case refuse(String)
        case run(command: String, cwd: String, session: String)
    }

    static func decide(line: String) -> RequestDecision {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
            return .refuse("malformed request")
        }
        guard request.cmd == "overlay-run" else {
            return .refuse("unknown cmd: \(request.cmd)")
        }
        guard let command = request.command, !command.isEmpty else {
            return .refuse("missing command")
        }
        guard let session = request.session, !session.isEmpty else {
            // An old launcher that predates session scoping omits this field.
            // The message names the fix because the launcher prints it verbatim.
            return .refuse("missing session — update the revdiff launcher to forward AGENTS_SESSION_ID")
        }
        return .run(command: command, cwd: request.cwd ?? NSHomeDirectory(), session: session)
    }

    private let overlays: OverlayCenter
    private let queue = DispatchQueue(label: "com.kirahowe.agents.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Answers whether a session id names a live session row. Wired by
    /// `AgentsApp` once the store exists; a request arriving before then (or
    /// naming a session this app has never heard of) is refused. Refusal is
    /// deliberate — there is no app-global fallback, so a review either
    /// belongs to a live session or does not open at all.
    @MainActor var validateSession: ((String) -> Bool)?

    /// The clients waiting on live overlays, keyed by invoking session id —
    /// mirroring `OverlayCenter`'s one-review-per-session map. Only ever
    /// touched on the main actor, alongside the overlay state it mirrors, so
    /// "is a review running for this session" has exactly one answer rather
    /// than two that can disagree.
    @MainActor private var pendingClients: [String: Int32] = [:]

    init(overlays: OverlayCenter) {
        self.overlays = overlays
    }

    @MainActor
    func start() {
        overlays.onClosed = { [weak self] sessionID, outcome in
            switch outcome {
            case .finished:
                self?.completePending(forSession: sessionID, ok: true, error: nil)
            case .cancelled:
                self?.completePending(
                    forSession: sessionID,
                    ok: false,
                    error: "the session that requested this review was closed"
                )
            }
        }
        queue.async { [weak self] in self?.bindAndListen() }

        // A clean quit is the one shutdown path worth handling explicitly: it
        // is the only one where something is still around to act. A crash or
        // a force-quit leaves the socket file behind regardless, which is
        // exactly what the startup sweep below exists to clean up on the
        // next launch, so there is no need to duplicate that recovery here —
        // just don't litter the disk on the ordinary path.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.shutdown()
        }
    }

    private func shutdown() {
        // Synchronous on purpose: termination does not drain dispatch queues,
        // so an async hop here would race exit(2) and lose often enough to
        // make this cleanup decorative. The control queue cannot deadlock a
        // sync call — bindAndListen has long since finished, accepts only run
        // when the listen fd is readable, and requests are served off-queue.
        queue.sync { [weak self] in
            guard let self else { return }
            if let acceptSource = self.acceptSource {
                acceptSource.cancel()
                self.acceptSource = nil
            }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            unlink(Self.socketPath)
        }
    }

    // MARK: - Socket setup

    private func bindAndListen() {
        let path = Self.socketPath
        // Two different processes can never collide on this exact path — it
        // is scoped to our own pid — but pids do wrap and get reused across
        // reboots, so on the small chance a stale file already sits here from
        // some earlier life of this same pid, clear it before bind(2)
        // refuses to reuse it.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("ControlServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("ControlServer: socket path too long: \(path)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bound == 0 else {
            NSLog("ControlServer: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Owner-only: the socket grants the ability to run a command in this
        // app, so it must not be reachable by other users on the machine.
        chmod(path, S_IRUSR | S_IWUSR)

        guard listen(fd, 8) == 0 else {
            NSLog("ControlServer: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source

        // Now that our own endpoint exists (and is therefore excluded by
        // path), sweep the rest of the directory for anything this bundle id
        // left behind that nobody is listening on any more — see
        // `sweepDeadSockets` for why a crash or a test-host launch produces
        // exactly that kind of leftover.
        Self.sweepDeadSockets(in: Self.socketDirectory, prefix: Self.socketPrefix, ownPath: path)
    }

    /// Removes control sockets under `directory` whose name starts with
    /// `prefix` and ends in `.sock`, other than `ownPath`, provided nothing
    /// is listening on them any more.
    ///
    /// A crashed instance's per-pid socket file has nobody left to unlink it
    /// — the process that would have done so is gone — and the pre-per-instance
    /// fixed-name file can be orphaned the exact same way by an older build.
    /// `stat` cannot tell a dead file from a live one; they look identical on
    /// disk. Attempting a `connect()` can: a live listener accepts it (the
    /// probe then closes without sending a line, which `serve` already treats
    /// as a no-op, so this never disturbs whatever session is using that
    /// endpoint), while a dead file refuses the connection and is safe to
    /// unlink. Scoping to `prefix` keeps a Debug build's sweep from ever
    /// touching a Release build's socket, and excluding `ownPath` keeps an
    /// instance from probing — let alone removing — the endpoint it just
    /// bound. Free-standing so it can be exercised directly in tests without
    /// standing up a whole `ControlServer`.
    static func sweepDeadSockets(in directory: String, prefix: String, ownPath: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".sock") else { continue }
            let path = "\(directory)/\(name)"
            guard path != ownPath, !isSocketLive(at: path) else { continue }
            unlink(path)
        }
    }

    /// Whether some process is listening on the AF_UNIX socket at `path`,
    /// determined the only reliable way: trying to connect to it.
    private static func isSocketLive(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // can't probe — assume live and leave it alone
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        return result == 0
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // A launcher can vanish mid-review — its `nc` gets Ctrl-C'd, its
        // shell exits out from under it — and the next write(2) to that dead
        // peer would otherwise raise SIGPIPE with the default disposition,
        // which terminates the whole app rather than just failing this one
        // write. SO_NOSIGPIPE turns that into an ordinary EPIPE return, which
        // `reply(to:...)`'s `n <= 0` check below already treats as "stop
        // writing, the peer is gone."
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Each connection is served off the accept queue: a request blocks
        // for as long as its review is open, which would otherwise stall
        // every later connection behind it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serve(client: client)
        }
    }

    // MARK: - Request handling

    private func serve(client: Int32) {
        guard let line = readLine(from: client), !line.isEmpty else {
            close(client)
            return
        }
        let command: String
        let cwd: String
        let session: String
        switch Self.decide(line: line) {
        case .refuse(let error):
            reply(to: client, ok: false, error: error, closing: true)
            return
        case .run(let decidedCommand, let decidedCwd, let decidedSession):
            command = decidedCommand
            cwd = decidedCwd
            session = decidedSession
        }

        Task { @MainActor [weak self] in
            guard let self else {
                close(client)
                return
            }
            guard self.validateSession?(session) == true else {
                self.reply(to: client, ok: false, error: "unknown session: \(session)", closing: true)
                return
            }
            guard self.pendingClients[session] == nil else {
                self.reply(
                    to: client,
                    ok: false,
                    error: "a review is already open in this session",
                    closing: true
                )
                return
            }
            do {
                try self.overlays.present(command: command, workingDirectory: cwd, sessionID: session)
                // No reply yet — the overlay is live, and this connection is
                // the thing the caller is blocked on. `completePending` answers
                // it when the command exits.
                self.pendingClients[session] = client
            } catch {
                self.reply(
                    to: client,
                    ok: false,
                    error: "a review is already open in this session",
                    closing: true
                )
            }
        }
    }

    @MainActor
    private func completePending(forSession sessionID: String, ok: Bool, error: String?) {
        guard let client = pendingClients.removeValue(forKey: sessionID) else { return }
        reply(to: client, ok: ok, error: error, closing: true)
    }

    private func reply(to client: Int32, ok: Bool, error: String?, closing: Bool) {
        var payload: [String: Any] = ["ok": ok]
        if let error { payload["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"ok":false}"#.utf8)
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        if closing { close(client) }
    }

    /// Reads one newline-terminated request. Capped because this socket takes
    /// a single small JSON object and nothing else — an unbounded read here
    /// would let any local process grow the app's memory at will.
    private func readLine(from fd: Int32, limit: Int = 64 * 1024) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
