import AppKit
import UserNotifications

/// Self-rolled update notifier — polls the GitHub Releases API, compares
/// the latest tag to the running ``CFBundleShortVersionString``, and
/// posts a tray notification if a newer release is available.
///
/// Why self-rolled instead of Sparkle 2:
/// - Sparkle requires Developer ID-signed updates; we ship ad-hoc-signed
///   binaries for the friends-beta phase (no $99 ADP yet)
/// - All we want is "nudge the user to download new version" — Sparkle's
///   auto-install would require code-signing parity anyway
///
/// Behavior:
/// - First check fires ~30 s after launch (so it doesn't slow boot)
/// - Subsequent checks every 24 h while the app is running
/// - On finding a newer tag, a system notification appears: clicking it
///   opens the GitHub release page in the default browser
/// - User can opt-out via the Settings toggle (default ON)
/// - "Skip this version" hides one specific tag forever (until a newer
///   one supersedes it)
@MainActor
final class UpdateNotifier: NSObject {

    static let shared = UpdateNotifier()

    private let releasesURL = URL(string:
        "https://api.github.com/repos/artempolansky/wam-voice-capture/releases/latest"
    )!
    private let pollInterval: TimeInterval = 24 * 3600
    private let firstCheckDelay: TimeInterval = 30

    private var timer: Timer?

    // UserDefaults keys
    private let enabledKey         = "WAMUpdateCheckEnabled"
    private let lastCheckAtKey     = "WAMUpdateLastCheckAt"
    private let skippedVersionKey  = "WAMUpdateSkippedVersion"

    /// On/off toggle exposed via the Settings submenu. Defaults to true
    /// — friends-beta is the whole reason this notifier exists.
    var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            // Default true when the key has never been set.
            if d.object(forKey: enabledKey) == nil { return true }
            return d.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            TrayLog.append("updates: auto-check \(newValue ? "enabled" : "disabled")")
        }
    }

    /// Call once at app launch. Idempotent.
    func start() {
        guard timer == nil else { return }
        // Configure the notification center delegate so clicks route through us.
        UNUserNotificationCenter.current().delegate = self
        // Quietly request permission. We can't show notifications without it,
        // but a denial is fine — the menu's "Check now" still works.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkInBackground() }
        }
        // Fire once shortly after boot — don't make the first launch wait
        // a full 24 h to learn about an existing newer release.
        DispatchQueue.main.asyncAfter(deadline: .now() + firstCheckDelay) { [weak self] in
            self?.checkInBackground()
        }
    }

    /// Manual trigger from the tray menu item. Ignores throttling.
    @MainActor
    func checkNow() {
        Task { await performCheck(manuallyTriggered: true) }
    }

    private func checkInBackground() {
        guard isEnabled else { return }
        Task { await performCheck(manuallyTriggered: false) }
    }

    // MARK: - Core flow

    private func performCheck(manuallyTriggered: Bool) async {
        UserDefaults.standard.set(Date(), forKey: lastCheckAtKey)
        do {
            let latest = try await fetchLatestRelease()
            let current = Self.currentVersion()
            guard Self.compareSemver(latest.tag, current) == .orderedDescending else {
                if manuallyTriggered {
                    // Surface a friendly "you're up to date" only on manual
                    // checks — auto-checks stay silent.
                    showInfoAlert(
                        title: "You're up to date",
                        body: "Running v\(current). No newer release on GitHub."
                    )
                }
                TrayLog.append("updates: current=\(current), latest=\(latest.tag) — up to date")
                return
            }
            // Skip-this-version respect: don't auto-notify, but DO notify if
            // the user manually triggered a check.
            let skipped = UserDefaults.standard.string(forKey: skippedVersionKey)
            if !manuallyTriggered, skipped == latest.tag {
                TrayLog.append("updates: \(latest.tag) skipped per user preference")
                return
            }
            TrayLog.append("updates: new release \(latest.tag) (current=\(current))")
            postUpdateAvailableNotification(latest: latest)
        } catch {
            // Auto-check failures stay silent — usually transient network.
            // Manual triggers get a visible error.
            if manuallyTriggered {
                showInfoAlert(
                    title: "Update check failed",
                    body: error.localizedDescription
                )
            }
            TrayLog.append("updates: check failed — \(error.localizedDescription)")
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WAM-Voice-Capture/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "UpdateNotifier", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        if http.statusCode == 404 {
            // Repo private / no releases yet — silent for friends.
            throw NSError(domain: "UpdateNotifier", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "no releases published yet"])
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "UpdateNotifier", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub API returned \(http.statusCode)"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw NSError(domain: "UpdateNotifier", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "malformed JSON from GitHub"])
        }
        let htmlURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
        return Release(tag: tag, releasePageURL: htmlURL)
    }

    // MARK: - Notification

    private func postUpdateAvailableNotification(latest: Release) {
        let content = UNMutableNotificationContent()
        content.title = "WAM Voice Capture \(latest.tag) available"
        content.body = "Click to open the release page."
        content.sound = .default
        if let url = latest.releasePageURL {
            content.userInfo = ["releasePageURL": url.absoluteString,
                                 "tag": latest.tag]
        }

        let request = UNNotificationRequest(
            identifier: "wam.update.\(latest.tag)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DispatchQueue.main.async {
                    TrayLog.append("updates: notification add failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func showInfoAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Skip handling (exposed for the menu)

    func skipCurrentlyAvailable(tag: String) {
        UserDefaults.standard.set(tag, forKey: skippedVersionKey)
        TrayLog.append("updates: \(tag) marked skipped")
    }

    // MARK: - Helpers

    struct Release {
        let tag: String
        let releasePageURL: URL?
    }

    /// ``CFBundleShortVersionString`` from Info.plist (e.g. "1.1.0-dev").
    /// Pre-release suffixes are stripped for comparison.
    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Compare two version strings. Strips leading "v", drops any
    /// suffix after "-" (so "1.2.0-dev" == "1.2.0"). Returns the same
    /// ordering as ``Comparable``: ``orderedAscending`` if lhs < rhs.
    static func compareSemver(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = numericComponents(a)
        let rhs = numericComponents(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let lv = i < lhs.count ? lhs[i] : 0
            let rv = i < rhs.count ? rhs[i] : 0
            if lv < rv { return .orderedAscending }
            if lv > rv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericComponents(_ s: String) -> [Int] {
        var trimmed = s
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let dashIdx = trimmed.firstIndex(of: "-") {
            trimmed = String(trimmed[..<dashIdx])
        }
        return trimmed.split(separator: ".").compactMap { Int($0) }
    }
}

extension UpdateNotifier: UNUserNotificationCenterDelegate {
    /// When the user clicks the notification, open the release page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let urlString = info["releasePageURL"] as? String,
           let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }

    /// Show the notification banner even when the app is foregrounded —
    /// the tray app is "always running" so without this the notification
    /// would only fire visually if the user happened to be in another app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
