import Foundation

/// Central registry of configured agent sync targets.
///
/// Owns persistence:
/// - User-managed targets live in `UserDefaults` (key `WAMAgentSyncTargets`)
/// - Developer's private targets (e.g. personal Angelina) live in
///   `~/Library/Application Support/WAM Voice Capture/personal_targets.json`
///   which is gitignored and never shipped with the public build.
///
/// At app launch, both sources are loaded and **merged by id** (UserDefaults
/// wins on conflict — user always has final say).
///
/// Lifecycle hooks for sessions:
/// - `noteSessionStarted(file:)` — registers a file as "actively syncing"
///   for every enabled target. Schedules a debounced sync.
/// - `noteFileUpdated(file:)` — re-arms the debounce timer.
/// - `noteSessionEnded(file:)` — runs one final sync, then writes the `.done`
///   marker on every target.
@MainActor
final class AgentSyncRegistry {

    static let shared = AgentSyncRegistry()

    /// Notification posted whenever the target list or per-target status changes.
    /// Status bar listens to rebuild the menu and tray indicators.
    static let didChangeNotification = Notification.Name("WAMAgentSyncRegistryDidChange")

    private(set) var targets: [AgentSyncTarget] = []

    /// Per-active-session debounce timers, keyed by file URL.path. We never
    /// fire rsync more often than `debounceInterval` seconds per file/target.
    private var debounceTimers: [String: Timer] = [:]
    private let debounceInterval: TimeInterval = 2.0

    /// File URLs currently associated with an active session — used so a
    /// post-session-stopped late FSEvent (which we don't subscribe to today
    /// but might) doesn't trigger ghost syncs.
    private var activeFiles: Set<String> = []

    // MARK: - Persistence

    private struct StoredTarget: Codable {
        let id: String
        let name: String
        let host: String
        let user: String
        let remotePath: String
        let sshKeyPath: String
        let includeDictations: Bool
        let enabled: Bool
    }

    private let userDefaultsKey = "WAMAgentSyncTargets"

    init() {
        load()
    }

    private func load() {
        var combined: [String: AgentSyncTarget] = [:]

        // Personal targets (gitignored), loaded first so user-defaults can override.
        for t in loadPersonalTargets() {
            combined[t.id] = t
        }
        // UserDefaults — user-managed.
        for t in loadUserDefaultsTargets() {
            combined[t.id] = t
        }
        targets = Array(combined.values).sorted { $0.name.lowercased() < $1.name.lowercased() }
        TrayLog.append("agent-sync: loaded \(targets.count) target(s)")
    }

    private func loadUserDefaultsTargets() -> [AgentSyncTarget] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let stored = try? JSONDecoder().decode([StoredTarget].self, from: data) else {
            return []
        }
        return stored.map { storedToTarget($0) }
    }

    private func loadPersonalTargets() -> [AgentSyncTarget] {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let url = base.appendingPathComponent("WAM Voice Capture/personal_targets.json")
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredTarget].self, from: data) else {
            return []
        }
        TrayLog.append("agent-sync: loaded \(stored.count) personal target(s) from \(url.lastPathComponent)")
        return stored.map { storedToTarget($0) }
    }

    private func save() {
        let stored = targets.map { targetToStored($0) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func targetToStored(_ t: AgentSyncTarget) -> StoredTarget {
        StoredTarget(
            id: t.id, name: t.name, host: t.host, user: t.user,
            remotePath: t.remotePath, sshKeyPath: t.sshKeyPath,
            includeDictations: t.includeDictations, enabled: t.enabled
        )
    }

    private func storedToTarget(_ s: StoredTarget) -> AgentSyncTarget {
        AgentSyncTarget(
            id: s.id, name: s.name, host: s.host, user: s.user,
            remotePath: s.remotePath, sshKeyPath: s.sshKeyPath,
            includeDictations: s.includeDictations, enabled: s.enabled
        )
    }

    // MARK: - CRUD

    func addOrUpdate(_ target: AgentSyncTarget) {
        if let idx = targets.firstIndex(where: { $0.id == target.id }) {
            targets[idx] = target
        } else {
            targets.append(target)
        }
        targets.sort { $0.name.lowercased() < $1.name.lowercased() }
        save()
    }

    func remove(id: String) {
        targets.removeAll { $0.id == id }
        save()
    }

    func target(id: String) -> AgentSyncTarget? {
        targets.first(where: { $0.id == id })
    }

    // MARK: - Session lifecycle

    enum SessionKind { case meeting, dictation }

    /// Begin tracking a session's transcript file. Triggers an immediate
    /// initial sync (header arrives on remote) for every enabled target.
    func noteSessionStarted(file: URL, kind: SessionKind) {
        activeFiles.insert(file.path)
        TrayLog.append("agent-sync: session started for \(file.lastPathComponent) (\(kind))")
        // Initial sync — sends header so the agent knows the meeting exists.
        triggerSync(file: file, kind: kind, force: true)
    }

    /// Called whenever the file content changed (e.g. from MeetingSession's
    /// `appendLine`). Debounced — multiple calls in `debounceInterval` seconds
    /// collapse to one rsync per target.
    func noteFileUpdated(file: URL, kind: SessionKind) {
        guard activeFiles.contains(file.path) else { return }
        scheduleDebouncedSync(file: file, kind: kind)
    }

    /// Final flush + `.done` marker. Always called from the session's `stop`.
    /// Returns after the last sync completes (best-effort; per-target work
    /// happens on background queues, but `.done` writes are sequenced after
    /// the final sync per target).
    func noteSessionEnded(file: URL, kind: SessionKind) {
        debounceTimers[file.path]?.invalidate()
        debounceTimers.removeValue(forKey: file.path)
        activeFiles.remove(file.path)

        for target in enabledTargets(for: kind) {
            target.sync(localFile: file) { result in
                switch result {
                case .success:
                    target.writeDoneMarker(forLocalFile: file) { doneResult in
                        DispatchQueue.main.async {
                            switch doneResult {
                            case .success:
                                TrayLog.append("agent-sync: final + .done OK on \(target.name) for \(file.lastPathComponent)")
                            case .failure(let err):
                                TrayLog.append("agent-sync: final OK but .done failed on \(target.name): \(err.localizedDescription)")
                            }
                            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                        }
                    }
                case .failure(let err):
                    DispatchQueue.main.async {
                        TrayLog.append("agent-sync: final sync failed on \(target.name): \(err.localizedDescription)")
                        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                    }
                }
            }
        }
    }

    // MARK: - Private dispatch

    private func enabledTargets(for kind: SessionKind) -> [AgentSyncTarget] {
        switch kind {
        case .meeting:
            return targets.filter { $0.enabled }
        case .dictation:
            return targets.filter { $0.enabled && $0.includeDictations }
        }
    }

    private func scheduleDebouncedSync(file: URL, kind: SessionKind) {
        let key = file.path
        debounceTimers[key]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerSync(file: file, kind: kind, force: false)
            }
        }
        debounceTimers[key] = timer
    }

    private func triggerSync(file: URL, kind: SessionKind, force: Bool) {
        let targets = enabledTargets(for: kind)
        if targets.isEmpty { return }
        for target in targets {
            target.sync(localFile: file) { result in
                DispatchQueue.main.async {
                    if case .failure(let err) = result {
                        TrayLog.append("agent-sync: sync failed on \(target.name) for \(file.lastPathComponent): \(err.localizedDescription)")
                    }
                    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                }
            }
        }
    }
}
