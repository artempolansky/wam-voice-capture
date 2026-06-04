import AppKit

@MainActor
final class StatusBarController: NSObject {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// CoreAudio deviceUID выбранного input устройства. Пусто / nil = system default.
    private static let micDeviceUIDKey = "WAMMicDeviceUID"

    private var trayState = TrayState()
    /// FN-press: capture idempotency. FN-down кидает start, FN-up на том же нажатии — stop.
    private var captureInFlight = false

    // Tray icon: плавный grey↔red, без пульсации — солидный красный пока запись.
    private static let iconTransitionDuration: TimeInterval = 0.35
    private static let iconAnimFPS: Double = 30
    private var iconBlend: CGFloat = 0
    private var animTimer: Timer?

    // Hotkey: CGEventTap on F5 (keycode 96). NSEvent fallback was removed
    // because it cannot swallow events — F5 would still trigger focused-app
    // bindings (Chrome refresh etc.). Without CGEventTap permission, hotkey
    // simply doesn't work and the log says why.
    private var fnTap: FNKeyTap?
    private var lastFNPressAt = Date.distantPast
    private static let fnDebounce: TimeInterval = 0.15

    private var localSession: LocalCaptureSession?

    // MARK: - Init / deinit

    override init() {
        super.init()
        setupStatusItem()
        setupFNListener()
        setupAudio()
        setupMeetingSession()
    }

    private func setupAudio() {
        // Hop to main before touching TrayLog — onError fires on the audio thread.
        AudioCapture.shared.onError = { err in
            DispatchQueue.main.async {
                TrayLog.append("audio: error — \(err.localizedDescription)")
            }
        }
        // Lamp tracks mic availability whenever it flips. We're already on
        // main here; the publisher hops to main internally.
        AudioCapture.shared.onAvailabilityChange = { available in
            TrayLog.append("audio: mic availability -> \(available)")
            LightControl.shared.set(available ? .idle : .disconnected)
        }
        AudioCapture.shared.onAllMicsFailed = { [weak self] in
            guard let self else { return }
            TrayLog.append("audio: all mics produced silence — clearing saved UID, showing MIC badge")
            UserDefaults.standard.removeObject(forKey: Self.micDeviceUIDKey)
            self.allMicsFailed = true
            self.refreshTrayBadge()
        }
        AudioCapture.shared.onMicsRecovered = { [weak self] in
            guard let self else { return }
            TrayLog.append("audio: mic recovered — clearing MIC badge")
            self.allMicsFailed = false
            self.refreshTrayBadge()
        }
        let uid = UserDefaults.standard.string(forKey: Self.micDeviceUIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // On-demand mode: save the user's preferred mic UID but DO NOT start
        // the engine yet. The macOS green mic indicator stays off until the
        // user actually starts a dictation or meeting — much less annoying.
        // Engine starts inside LocalCaptureSession.start / MeetingSession.start
        // via AudioCapture.ensureRunning(), and stops at the end of each.
        AudioCapture.shared.setSelectedDevice((uid?.isEmpty == false) ? uid : nil)
        TrayLog.append("audio: on-demand mode (uid=\(uid ?? "default"), engine starts on first session)")
        // No initial lamp push — the engine isn't running yet; the lamp stays
        // at "disconnected" or whatever its last persisted state was.
    }

    /// True when AudioCapture's silence-probe cycle exhausted every input
    /// device on the system without finding one that produces non-zero audio.
    /// Cleared the moment the user picks a mic from the menu (which restarts
    /// the cycle from scratch) or once a working mic is found again.
    private var allMicsFailed = false

    private func refreshTrayBadge() {
        guard let btn = statusItem.button else { return }
        if allMicsFailed {
            btn.imagePosition = .imageLeft
            btn.title = " MIC"
            btn.toolTip = "No working microphone — every input device produced silence. Reconnect a mic or re-select from the menu to retry."
        } else {
            btn.imagePosition = .imageOnly
            btn.title = ""
            btn.toolTip = nil
        }
    }

    deinit {
        animTimer?.invalidate()
        fnTap?.stop()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        if #available(macOS 11.0, *) { statusItem.isVisible = true }
        guard let btn = statusItem.button else { TrayLog.append("ERROR: button nil"); return }
        btn.imagePosition  = .imageOnly
        btn.imageHugsTitle = true
        btn.imageScaling   = .scaleProportionallyDown
        btn.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        btn.target = self
        btn.action = #selector(itemClicked(_:))
        btn.sendAction(on: [.rightMouseUp, .leftMouseUp])
        renderUI()
    }

    // MARK: - Render

    private func renderUI() {
        applyTrayIcon()
        syncIconAnimator()
    }

    private func applyTrayIcon() {
        guard let btn = statusItem.button else { return }
        btn.image = TrayIcon.crossfadeImage(blend: iconBlend)
    }

    /// Set by LocalCaptureSession.onStallChange. While true, recording icon strobes.
    private var sessionStalled = false

    private var iconBlendTarget: CGFloat { trayState.recording ? 1 : 0 }

    private var needsIconAnimator: Bool {
        if sessionStalled && trayState.recording { return true }
        return abs(iconBlend - iconBlendTarget) > 0.002
    }

    private func syncIconAnimator() {
        if needsIconAnimator {
            if animTimer == nil {
                let interval = 1.0 / Self.iconAnimFPS
                animTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.iconAnimatorStep() }
                }
                iconAnimatorStep()
            }
        } else {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    private func iconAnimatorStep() {
        if sessionStalled && trayState.recording {
            // Strobe red between alpha 0.3 and 1.0 at 2Hz — clear "something's wrong" cue.
            let phase = Date().timeIntervalSinceReferenceDate * 2.0 * 2.0 * .pi
            iconBlend = 0.65 + 0.35 * CGFloat(sin(phase))
            applyTrayIcon()
            syncIconAnimator()
            return
        }

        let target = iconBlendTarget
        let step = CGFloat(1.0 / (Self.iconTransitionDuration * Self.iconAnimFPS))
        if abs(iconBlend - target) > step * 0.5 {
            iconBlend += (target > iconBlend) ? min(step, target - iconBlend) : max(-step, target - iconBlend)
        } else {
            iconBlend = target
        }
        applyTrayIcon()
        syncIconAnimator()
    }

    // MARK: - Error tooltip

    private func showError(_ message: String) {
        TrayLog.append("error: \(message)")
        guard let btn = statusItem.button else { return }
        btn.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak btn] in
            btn?.toolTip = nil
        }
    }

    // MARK: - Tray menu

    @objc private func itemClicked(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if MeetingSession.shared.isRunning {
            // Recording mode — focused menu with status header at top, only
            // the actions relevant during a live meeting. Settings hidden.
            addRecordingMeetingMenuItems(to: menu)
            menu.addItem(.separator())
            addQuitItem(to: menu)
        } else {
            // Idle mode — primary action first, then context-aware previews,
            // then Settings (everything technical), then About/Quit, with a
            // hotkey hint footer.
            addIdleMeetingMenuItems(to: menu)
            menu.addItem(.separator())

            let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
            settings.submenu = buildSettingsSubmenu()
            menu.addItem(settings)

            menu.addItem(.separator())
            let feedback = NSMenuItem(title: "Send feedback (Telegram)",
                                       action: #selector(openFeedbackChat),
                                       keyEquivalent: "")
            feedback.target = self
            menu.addItem(feedback)

            let bug = NSMenuItem(title: "Report a bug (GitHub)",
                                  action: #selector(openBugReport),
                                  keyEquivalent: "")
            bug.target = self
            menu.addItem(bug)

            let about = NSMenuItem(title: "About…",
                                    action: #selector(showAboutDialog),
                                    keyEquivalent: "")
            about.target = self
            menu.addItem(about)

            addQuitItem(to: menu)
            addHotkeyHint(to: menu)
        }
        return menu
    }

    private func addQuitItem(to menu: NSMenu) {
        let quit = NSMenuItem(title: "Quit",
                               action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addHotkeyHint(to menu: NSMenu) {
        let hint = NSMenuItem(title: "Tap right ⌥ for quick dictation",
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    // MARK: - Meeting menu

    /// Recording-state menu: status header (elapsed + speakers + sync), then
    /// the actions you actually need mid-meeting (open file, rename speaker,
    /// stop). No settings — those are an idle-mode concern.
    private func addRecordingMeetingMenuItems(to menu: NSMenu) {
        let elapsed = formatElapsed(MeetingSession.shared.elapsedSeconds)
        let header = NSMenuItem(title: "🔴 Meeting · \(elapsed)",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let speakers = MeetingSession.shared.speakers.activeSpeakers()
        let speakerNote: String = {
            if speakers.isEmpty { return "Waiting for first speech…" }
            if speakers.count == 1 { return "\(speakers.count) speaker detected" }
            return "\(speakers.count) speakers detected"
        }()
        let syncNote = primarySyncStatusLine()
        let statusLine: String
        if let syncNote {
            statusLine = "   \(speakerNote) · \(syncNote)"
        } else {
            statusLine = "   \(speakerNote)"
        }
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        if MeetingSession.shared.transcriptURL != nil {
            let open = NSMenuItem(title: "Open transcript",
                                  action: #selector(openMeetingTranscript),
                                  keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        if !speakers.isEmpty {
            let renameRoot = NSMenuItem(title: "Rename speaker", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in speakers {
                let item = NSMenuItem(title: s.label,
                                      action: #selector(renameSpeakerClicked(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = s.id
                sub.addItem(item)
            }
            renameRoot.submenu = sub
            menu.addItem(renameRoot)
        }

        let stop = NSMenuItem(title: "Stop meeting",
                              action: #selector(stopMeeting),
                              keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
    }

    /// Idle-state primary actions: Start, Today (with event count inline),
    /// Recordings folder (with current path inline). Everything technical
    /// lives in the Settings submenu.
    private func addIdleMeetingMenuItems(to menu: NSMenu) {
        // First-run nudge: if neither STT provider is configured, the app
        // can't actually do anything yet. Surface that up front, otherwise
        // the user clicks Start meeting and gets a silent or confusing
        // failure. Once any provider is ready, this hint disappears.
        if !STTSettings.shared.currentProviderReady {
            let banner = NSMenuItem(title: "⚠ Setup needed — choose a Speech recognition provider",
                                    action: #selector(jumpToSpeechRecognition),
                                    keyEquivalent: "")
            banner.target = self
            menu.addItem(banner)
            menu.addItem(.separator())
        }

        let start = NSMenuItem(title: "Start meeting",
                               action: #selector(startMeeting),
                               keyEquivalent: "")
        start.target = self
        menu.addItem(start)

        let todayCount = CalendarBridge.shared.isAuthorized
            ? CalendarBridge.shared.todaysEvents().count
            : nil
        let todayTitle: String
        if let count = todayCount {
            todayTitle = count == 0 ? "Today · no events" : "Today · \(count) event\(count == 1 ? "" : "s")"
        } else {
            todayTitle = "Today"
        }
        let todayItem = NSMenuItem(title: todayTitle, action: nil, keyEquivalent: "")
        todayItem.submenu = buildTodaySubmenu()
        menu.addItem(todayItem)

        let folderItem = NSMenuItem(title: "Recordings · \(compactFolderLabel())",
                                    action: nil, keyEquivalent: "")
        folderItem.submenu = buildRecordingsFolderSubmenu()
        menu.addItem(folderItem)
    }

    /// Short display string for the current recordings folder. Replaces the
    /// user's home directory with ``~`` and caps total width so the menu
    /// doesn't grow obnoxiously wide on long custom paths.
    private func compactFolderLabel() -> String {
        let url = RecordingsFolder.currentURL()
        var path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            path = "~" + String(path.dropFirst(home.count))
        }
        let maxLen = 40
        if path.count > maxLen {
            return "…" + String(path.suffix(maxLen - 1))
        }
        return path
    }

    /// Returns the first enabled sync target's status as a short line, or
    /// nil if no targets are configured. Used in the recording header.
    private func primarySyncStatusLine() -> String? {
        let enabled = AgentSyncRegistry.shared.targets.filter { $0.enabled }
        guard let target = enabled.first else { return nil }
        switch target.status {
        case .idle:                       return "syncing to \(target.name)"
        case .syncing:                    return "syncing to \(target.name)…"
        case .lastSucceeded:              return "✓ synced to \(target.name)"
        case .lastFailed(_, let err):     return "⚠ \(target.name): \(err.prefix(40))"
        }
    }

    private func buildTodaySubmenu() -> NSMenu {
        let sub = NSMenu(title: "Today")

        let calendar = CalendarBridge.shared
        switch calendar.authorizationStatus {
        case .notDetermined:
            let item = NSMenuItem(title: "Grant Calendar access…",
                                  action: #selector(grantCalendarAccess),
                                  keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        case .denied, .restricted:
            let item = NSMenuItem(title: "Calendar access denied — open System Settings",
                                  action: #selector(openCalendarSettings),
                                  keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        default:
            break
        }

        guard calendar.isAuthorized else { return sub }

        let events = calendar.todaysEvents()
        if events.isEmpty {
            let empty = NSMenuItem(title: "No events today", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            return sub
        }

        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        for event in events {
            let live = event.startDate <= now && event.endDate >= now
            let prefix = live ? "● " : "  "
            let title = "\(prefix)\(timeFmt.string(from: event.startDate))–\(timeFmt.string(from: event.endDate))  \(event.title)"
            let item = NSMenuItem(title: title,
                                  action: #selector(startMeetingForEvent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = event.identifier
            sub.addItem(item)
        }

        return sub
    }

    @objc private func grantCalendarAccess() {
        Task { @MainActor in
            let granted = await CalendarBridge.shared.requestAccess()
            if !granted {
                showError("Calendar access denied — enable it in System Settings → Privacy & Security → Calendar")
            }
        }
    }

    @objc private func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startMeetingForEvent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Look up the freshly-snapshotted event so we use today's actual data,
        // not whatever was cached when the menu was built.
        let event = CalendarBridge.shared.todaysEvents().first(where: { $0.identifier == id })
        do {
            try MeetingSession.shared.start(event: event)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func buildRecordingsFolderSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Recordings folder")

        // Header — shows the current path (truncated if long).
        let header = NSMenuItem(
            title: RecordingsFolder.isCustom
                ? "Custom: \(RecordingsFolder.displayPath())"
                : "Default: ~/Documents/WAM Voice Capture Recordings/",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        sub.addItem(header)

        let open = NSMenuItem(title: "Open in Finder",
                              action: #selector(openRecordingsFolder),
                              keyEquivalent: "")
        open.target = self
        sub.addItem(open)

        let change = NSMenuItem(title: "Change…",
                                action: #selector(changeRecordingsFolder),
                                keyEquivalent: "")
        change.target = self
        sub.addItem(change)

        if RecordingsFolder.isCustom {
            let reset = NSMenuItem(title: "Reset to default",
                                    action: #selector(resetRecordingsFolder),
                                    keyEquivalent: "")
            reset.target = self
            sub.addItem(reset)
        }

        return sub
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    @objc private func startMeeting() {
        if trayState.recording {
            showError("FN dictation in progress — release FN before starting a meeting")
            return
        }
        do {
            try MeetingSession.shared.start()
        } catch {
            showError(error.localizedDescription)
            TrayLog.append("meeting: start failed — \(error.localizedDescription)")
        }
    }

    @objc private func stopMeeting() {
        MeetingSession.shared.stop()
    }

    @objc private func openMeetingTranscript() {
        guard let url = MeetingSession.shared.transcriptURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func renameSpeakerClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(sender.title)"
        alert.informativeText = "New name applies to past and future lines in the transcript."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. Anya"
        alert.accessoryView = field
        let r = alert.runModal()
        guard r == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        _ = MeetingSession.shared.renameSpeaker(id, to: newName)
    }

    @objc private func openRecordingsFolder() {
        let dir = RecordingsFolder.currentURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func changeRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder for meeting transcripts. iCloud Drive, Dropbox, external volumes — all fine."
        panel.prompt = "Choose"
        panel.directoryURL = RecordingsFolder.currentURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingsFolder.setConfigured(url)
        TrayLog.append("recordings: folder set to \(url.path)")
    }

    @objc private func resetRecordingsFolder() {
        RecordingsFolder.setConfigured(nil)
        TrayLog.append("recordings: folder reset to default (\(RecordingsFolder.defaultURL().path))")
    }

    private func setupMeetingSession() {
        MeetingSession.shared.onStateChange = { [weak self] running in
            guard let self else { return }
            // Reuse the existing tray-state machinery: meeting active = red icon.
            self.trayState.recording = running
            self.renderUI()
            // Lamp follows the same convention as FN dictation.
            LightControl.shared.set(running ? .recording : .idle)
        }
        MeetingSession.shared.onError = { [weak self] err in
            self?.showError(err.localizedDescription)
        }
    }

    // Telegram menu removed: TDLib-based delivery was replaced by file-sync
    // (Phase 7a / AgentSyncTarget). See PRs around #17 epic.

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        let newValue = !LoginItemSettings.isLaunchAtLoginEnabled
        do {
            try LoginItemSettings.setLaunchAtLogin(newValue)
            sender.state = newValue ? .on : .off
            TrayLog.append("Launch at login: \(newValue)")
        } catch {
            showError(error.localizedDescription)
            TrayLog.append("Launch at login error: \(error.localizedDescription)")
        }
    }

    // MARK: - FN listener

    private func setupFNListener() {
        let pressHandler: () -> Void = { [weak self] in
            Task { @MainActor in await self?.handleFNPress() }
        }

        let tap = FNKeyTap()
        if tap.start(onPress: pressHandler) {
            fnTap = tap
        } else {
            // No NSEvent fallback: NSEvent global monitor can observe keyDown
            // but cannot swallow the event, so F5 would still trigger Chrome
            // refresh etc. Better to fail loudly and have the user fix
            // permissions than to silently mis-behave.
            TrayLog.append("Hotkey: install failed — F5 will NOT work until Accessibility & Input Monitoring are granted in System Settings → Privacy & Security.")
        }
    }

    /// FN-down. Toggle dictation: start session if idle, stop if already
    /// recording. During a meeting FN is intentionally a no-op — meetings
    /// always record both channels (Phase 4 spec FR-M2), so push-to-record-me
    /// has no purpose.
    private func handleFNPress() async {
        if MeetingSession.shared.isRunning {
            // Meetings record continuously — FN does nothing during one to
            // avoid accidentally starting a parallel dictation that would
            // fight for the mic engine.
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastFNPressAt) >= Self.fnDebounce else {
            TrayLog.append("FN ignored (debounce)")
            return
        }
        lastFNPressAt = now

        guard !captureInFlight else {
            TrayLog.append("FN ignored: capture in flight")
            return
        }

        if trayState.recording {
            doStop()
        } else {
            doStart()
        }
    }

    /// FN-up. No-op now; kept so the FN-tap subscriber API stays uniform with
    /// `handleFNPress`. Push-to-record-me semantics were removed in Phase 4.
    private func handleFNRelease() {
        // Intentionally empty.
    }

    // MARK: - Local capture (Deepgram → paste)

    private func doStart() {
        captureInFlight = true
        defer { captureInFlight = false }

        trayState.recording = true
        renderUI()

        if localSession != nil {
            TrayLog.append("local: session already running — ignoring start")
            return
        }
        let s = LocalCaptureSession()
        s.onTranscript = { text, isFinal in
            if isFinal, !text.isEmpty {
                TrayLog.append("local: final segment — \(text.prefix(80))")
            }
        }
        s.onFinish = { text in
            TrayLog.append("local: finished, pasted \(text.count) chars")
        }
        s.onStallChange = { [weak self] stalled in
            guard let self else { return }
            self.sessionStalled = stalled
            self.renderUI()
        }
        s.onError = { [weak self] err in
            guard let self else { return }
            self.showError(err.localizedDescription)
            TrayLog.append("local: error — \(err.localizedDescription)")
        }
        do {
            try s.start()
            localSession = s
            TrayLog.append("local: session started")
        } catch {
            trayState.recording = false
            renderUI()
            showError(error.localizedDescription)
            TrayLog.append("local: start failed — \(error.localizedDescription)")
        }
    }

    private func doStop() {
        captureInFlight = true
        defer { captureInFlight = false }

        trayState.recording = false
        renderUI()

        guard let s = localSession else {
            TrayLog.append("local: stop called with no session")
            return
        }
        s.stop()
        localSession = nil
        TrayLog.append("local: session stopped (paste pending)")
    }

    private func isDeepgramKeyPresent() -> Bool {
        (try? KeychainHelper.deepgramAPIKey()).map { !$0.isEmpty } ?? false
    }

    // MARK: - Settings submenu (idle-mode only)

    /// Collapses what used to be 4-5 top-level entries (Deepgram key, Mic,
    /// Light, Send to, Launch at login) into one Settings submenu so the
    /// idle menu stays focused on actions. Light auto-hides if not configured.
    private func buildSettingsSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Settings")

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = buildMicSubmenu()
        sub.addItem(micItem)

        let sttItem = NSMenuItem(title: "Speech recognition", action: nil, keyEquivalent: "")
        sttItem.submenu = buildSpeechRecognitionSubmenu()
        sub.addItem(sttItem)

        let sendToItem = NSMenuItem(title: "Forward transcripts to",
                                    action: nil, keyEquivalent: "")
        sendToItem.submenu = buildSendToSubmenu()
        sub.addItem(sendToItem)

        // Light is a niche feature — auto-hide unless the user has set up a
        // host. Reachable for first-time setup by opening the Lamp section
        // in this submenu? No — too rare. They can edit personal_targets or
        // re-add via a feature flag later.
        if !LightControl.shared.host.isEmpty {
            let lightItem = NSMenuItem(title: "Lamp indicator",
                                       action: nil, keyEquivalent: "")
            lightItem.submenu = buildLightSubmenu()
            sub.addItem(lightItem)
        }

        if #available(macOS 13.0, *) {
            sub.addItem(.separator())
            let login = NSMenuItem(
                title: "Start at login",
                action: #selector(toggleLaunchAtLogin(_:)),
                keyEquivalent: ""
            )
            login.target = self
            login.state = LoginItemSettings.isLaunchAtLoginEnabled ? .on : .off
            sub.addItem(login)
        }

        // Updates
        sub.addItem(.separator())
        let autoCheck = NSMenuItem(title: "Check for updates automatically",
                                    action: #selector(toggleUpdateAutoCheck(_:)),
                                    keyEquivalent: "")
        autoCheck.target = self
        autoCheck.state = UpdateNotifier.shared.isEnabled ? .on : .off
        sub.addItem(autoCheck)

        let checkNow = NSMenuItem(title: "Check for updates now",
                                   action: #selector(checkForUpdatesNow),
                                   keyEquivalent: "")
        checkNow.target = self
        sub.addItem(checkNow)

        return sub
    }

    @objc private func toggleUpdateAutoCheck(_ sender: NSMenuItem) {
        UpdateNotifier.shared.isEnabled.toggle()
    }

    @objc private func checkForUpdatesNow() {
        UpdateNotifier.shared.checkNow()
    }

    // MARK: - Speech recognition submenu

    private func buildSpeechRecognitionSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Speech recognition")
        let current = STTSettings.shared.currentProvider

        // One menu item per provider, with the active one checked.
        for provider in STTSettings.Provider.allCases {
            let suffix = providerStatusSuffix(provider)
            let item = NSMenuItem(
                title: "\(provider.rawValue)\(suffix)",
                action: #selector(switchSTTProvider(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = (provider == current) ? .on : .off
            item.representedObject = provider.rawValue
            sub.addItem(item)
        }

        sub.addItem(.separator())

        // Provider-specific config sub-items.
        let dgKey = NSMenuItem(
            title: isDeepgramKeyPresent() ? "Deepgram API key…  (set)" : "Deepgram API key…",
            action: #selector(configureDeepgramKey),
            keyEquivalent: ""
        )
        dgKey.target = self
        sub.addItem(dgKey)

        // Whisper diagnostic row — tells the user what's missing for local mode.
        let whisperStatus = whisperReadinessLine()
        let whisperRow = NSMenuItem(title: whisperStatus, action: nil, keyEquivalent: "")
        whisperRow.isEnabled = false
        sub.addItem(whisperRow)

        return sub
    }

    /// Trailing text for a provider menu item — flags missing prerequisites
    /// (no API key for Deepgram, missing binary/model for Whisper) so the
    /// user can see why an option is greyed out conceptually.
    private func providerStatusSuffix(_ provider: STTSettings.Provider) -> String {
        switch provider {
        case .deepgram:
            return isDeepgramKeyPresent() ? "" : "  (no API key)"
        case .whisperLocal:
            if !WhisperLocalClient.isInstalled { return "  (whisper-cli missing)" }
            if !WhisperLocalClient.modelExists { return "  (no model file)" }
            return ""
        }
    }

    private func whisperReadinessLine() -> String {
        if !WhisperLocalClient.isInstalled {
            return "Local Whisper: install via `brew install whisper-cpp`"
        }
        if !WhisperLocalClient.modelExists {
            return "Local Whisper: drop ggml-base.bin in ~/Library/.../models/"
        }
        let model = (WhisperLocalClient.modelPath as NSString).lastPathComponent
        return "Local Whisper: ready (\(model))"
    }

    /// Convenience for the "⚠ Setup needed" first-run banner: brings up an
    /// NSAlert explaining what's missing + a deep-link to System Settings
    /// if Whisper needs install. Cheaper than rendering a real settings
    /// window for v1.0.0-public.
    @objc private func jumpToSpeechRecognition() {
        let alert = NSAlert()
        alert.messageText = "Set up speech recognition"
        alert.informativeText = """
            WAM Voice Capture needs one of two providers configured before \
            it can transcribe anything.

            • Deepgram (cloud): get an API key from console.deepgram.com, \
            then click Settings → Speech recognition → Deepgram API key…

            • Local Whisper (offline): run `brew install whisper-cpp`, \
            then drop ggml-base.bin or larger into:
            ~/Library/Application Support/WAM Voice Capture/models/

            See README.md for step-by-step instructions.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open setup guide")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/artempolansky/wam-voice-capture#setup") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func switchSTTProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = STTSettings.Provider(rawValue: raw) else { return }
        if chosen == STTSettings.shared.currentProvider { return }
        STTSettings.shared.currentProvider = chosen
        // No menu refresh needed — the next click rebuilds it from scratch.
    }

    @objc private func showAboutDialog() {
        let alert = NSAlert()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        alert.messageText = "WAM Voice Capture"
        alert.informativeText = """
            Version \(version) (\(build))
            MIT License · open source

            Push-to-talk dictation + meeting recording with calendar-aware \
            file naming and configurable sync to a remote agent inbox.

            Code: github.com/artempolansky/wam-voice-capture
            Feedback: t.me/weamclub
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open on GitHub")
        alert.addButton(withTitle: "Telegram community")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://github.com/artempolansky/wam-voice-capture") {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://t.me/weamclub") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    @objc private func openFeedbackChat() {
        if let url = URL(string: "https://t.me/weamclub") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBugReport() {
        if let url = URL(string: "https://github.com/artempolansky/wam-voice-capture/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    private func buildMicSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Microphone")
        let current = UserDefaults.standard.string(forKey: Self.micDeviceUIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let defaultDev = AudioDevices.defaultInputDevice()
        let defaultLabel = defaultDev.map { "System default (\($0.name))" } ?? "System default"
        let defaultItem = NSMenuItem(title: defaultLabel, action: #selector(selectMicDefault), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = current.isEmpty ? .on : .off
        sub.addItem(defaultItem)

        let devices = AudioDevices.inputDevices()
        if !devices.isEmpty {
            sub.addItem(.separator())
            for dev in devices {
                let it = NSMenuItem(title: dev.name, action: #selector(selectMicDevice(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = dev.uid
                it.state = (dev.uid == current) ? .on : .off
                sub.addItem(it)
            }
        }
        return sub
    }

    @objc private func selectMicDefault() {
        UserDefaults.standard.removeObject(forKey: Self.micDeviceUIDKey)
        allMicsFailed = false
        refreshTrayBadge()
        do {
            try AudioCapture.shared.setDeviceUID(nil)
            TrayLog.append("mic: using system default")
        } catch {
            showError(error.localizedDescription)
            TrayLog.append("mic: switch to default failed — \(error.localizedDescription)")
        }
    }

    @objc private func selectMicDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: Self.micDeviceUIDKey)
        allMicsFailed = false
        refreshTrayBadge()
        do {
            try AudioCapture.shared.setDeviceUID(uid)
            TrayLog.append("mic: selected \(sender.title) (\(uid))")
        } catch {
            showError(error.localizedDescription)
            TrayLog.append("mic: switch to \(uid) failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Light submenu

    // MARK: - Send-to (agent sync) submenu

    private func buildSendToSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Send to")
        let targets = AgentSyncRegistry.shared.targets

        if targets.isEmpty {
            let empty = NSMenuItem(title: "No targets configured",
                                    action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for t in targets {
                let title = "\(t.enabled ? "✓ " : "  ")\(t.name)  \(statusGlyph(for: t.status))"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = buildTargetSubmenu(for: t)
                sub.addItem(item)
            }
        }

        sub.addItem(.separator())
        let add = NSMenuItem(title: "Add target…",
                              action: #selector(addAgentSyncTargetClicked),
                              keyEquivalent: "")
        add.target = self
        sub.addItem(add)

        return sub
    }

    private func statusGlyph(for status: AgentSyncTarget.Status) -> String {
        switch status {
        case .idle:                       return ""
        case .syncing:                    return "(syncing…)"
        case .lastSucceeded:              return "(ok)"
        case .lastFailed(_, let err):     return "(failed: \(err.prefix(40)))"
        }
    }

    private func buildTargetSubmenu(for t: AgentSyncTarget) -> NSMenu {
        let sub = NSMenu(title: t.name)

        let header = NSMenuItem(title: "\(t.user)@\(t.host):\(t.remotePath)",
                                 action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)

        let toggle = NSMenuItem(title: "Enabled",
                                 action: #selector(toggleAgentTargetClicked(_:)),
                                 keyEquivalent: "")
        toggle.target = self
        toggle.state = t.enabled ? .on : .off
        toggle.representedObject = t.id
        sub.addItem(toggle)

        let includeDicts = NSMenuItem(title: "Include dictations",
                                       action: #selector(toggleIncludeDictationsClicked(_:)),
                                       keyEquivalent: "")
        includeDicts.target = self
        includeDicts.state = t.includeDictations ? .on : .off
        includeDicts.representedObject = t.id
        sub.addItem(includeDicts)

        sub.addItem(.separator())

        let test = NSMenuItem(title: "Test",
                               action: #selector(testAgentTargetClicked(_:)),
                               keyEquivalent: "")
        test.target = self
        test.representedObject = t.id
        sub.addItem(test)

        let edit = NSMenuItem(title: "Edit…",
                               action: #selector(editAgentTargetClicked(_:)),
                               keyEquivalent: "")
        edit.target = self
        edit.representedObject = t.id
        sub.addItem(edit)

        let remove = NSMenuItem(title: "Remove",
                                 action: #selector(removeAgentTargetClicked(_:)),
                                 keyEquivalent: "")
        remove.target = self
        remove.representedObject = t.id
        sub.addItem(remove)

        return sub
    }

    @objc private func addAgentSyncTargetClicked() {
        runAgentTargetEditor(existing: nil)
    }

    @objc private func editAgentTargetClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = AgentSyncRegistry.shared.target(id: id) else { return }
        runAgentTargetEditor(existing: t)
    }

    @objc private func toggleAgentTargetClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = AgentSyncRegistry.shared.target(id: id) else { return }
        t.enabled.toggle()
        AgentSyncRegistry.shared.addOrUpdate(t)
        TrayLog.append("agent-sync: target '\(t.name)' enabled=\(t.enabled)")
    }

    @objc private func toggleIncludeDictationsClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = AgentSyncRegistry.shared.target(id: id) else { return }
        t.includeDictations.toggle()
        AgentSyncRegistry.shared.addOrUpdate(t)
    }

    @objc private func testAgentTargetClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = AgentSyncRegistry.shared.target(id: id) else { return }
        TrayLog.append("agent-sync: probing '\(t.name)'…")
        t.probe { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.showInfo("Target \"\(t.name)\" reachable",
                                   info: "rsync + ssh both succeeded. Probe file uploaded and deleted.")
                case .failure(let err):
                    self?.showError("Target \"\(t.name)\" failed: \(err.localizedDescription)")
                }
                NotificationCenter.default.post(name: AgentSyncRegistry.didChangeNotification, object: nil)
            }
        }
    }

    @objc private func removeAgentTargetClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = AgentSyncRegistry.shared.target(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove target \"\(t.name)\"?"
        alert.informativeText = "Disables sync to \(t.user)@\(t.host):\(t.remotePath). The remote inbox is not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AgentSyncRegistry.shared.remove(id: id)
        TrayLog.append("agent-sync: removed target '\(t.name)'")
    }

    /// Multi-field NSAlert that creates or edits one target. Pattern modeled
    /// multi-field NSAlert pattern.
    private func runAgentTargetEditor(existing: AgentSyncTarget?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add sync target" : "Edit \(existing!.name)"
        alert.informativeText = "Files are rsync'd to <user>@<host>:<remotePath>. Make sure your SSH key is registered on the remote and you have write permission on the path."

        let rowHeight: CGFloat = 26
        let labelWidth: CGFloat = 100
        let fieldWidth: CGFloat = 260
        let rows: [(String, String, Bool)] = [
            ("Name",        existing?.name ?? "", false),
            ("Host",        existing?.host ?? "", false),
            ("User",        existing?.user ?? "", false),
            ("Remote path", existing?.remotePath ?? "/home/USER/agent/inbox/", false),
            ("SSH key",     existing?.sshKeyPath ?? "~/.ssh/id_ed25519", false),
        ]
        let totalHeight = CGFloat(rows.count) * rowHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: labelWidth + fieldWidth + 8, height: totalHeight))
        var fields: [NSTextField] = []
        for (idx, row) in rows.enumerated() {
            let y = totalHeight - CGFloat(idx + 1) * rowHeight
            let lbl = NSTextField(labelWithString: row.0)
            lbl.frame = NSRect(x: 0, y: y + 4, width: labelWidth - 4, height: rowHeight - 4)
            lbl.alignment = .right
            container.addSubview(lbl)

            let field = NSTextField(frame: NSRect(x: labelWidth, y: y + 2, width: fieldWidth, height: rowHeight - 4))
            field.stringValue = row.1
            field.placeholderString = row.1.isEmpty ? row.0 : ""
            container.addSubview(field)
            fields.append(field)
        }
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields.first
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let values = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            showError("All fields are required.")
            return
        }
        let target = existing ?? AgentSyncTarget(
            name: values[0], host: values[1], user: values[2],
            remotePath: values[3], sshKeyPath: values[4]
        )
        target.name = values[0]
        target.host = values[1]
        target.user = values[2]
        target.remotePath = values[3]
        target.sshKeyPath = values[4]
        AgentSyncRegistry.shared.addOrUpdate(target)
        TrayLog.append("agent-sync: saved target '\(target.name)' (\(target.user)@\(target.host):\(target.remotePath))")
    }

    private func showInfo(_ title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Light submenu

    private func buildLightSubmenu() -> NSMenu {
        let sub = NSMenu(title: "Light")

        let endpoint = "\(LightControl.shared.host):\(LightControl.shared.port)"
        let header = NSMenuItem(title: endpoint, action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)

        let toggle = NSMenuItem(title: "Enabled",
                                 action: #selector(toggleLightEnabled),
                                 keyEquivalent: "")
        toggle.target = self
        toggle.state = LightControl.shared.enabled ? .on : .off
        sub.addItem(toggle)

        let edit = NSMenuItem(title: "Configure host…",
                               action: #selector(configureLightHost),
                               keyEquivalent: "")
        edit.target = self
        sub.addItem(edit)

        sub.addItem(.separator())
        let test = NSMenuItem(title: "Test (red → standby)",
                               action: #selector(testLight),
                               keyEquivalent: "")
        test.target = self
        sub.addItem(test)

        return sub
    }

    @objc private func toggleLightEnabled() {
        LightControl.shared.enabled.toggle()
        // User explicitly turned it on → give the lamp a fresh chance even
        // if the breaker had suspended earlier on a foreign network.
        if LightControl.shared.enabled { LightControl.shared.resetBreaker() }
        TrayLog.append("light: enabled = \(LightControl.shared.enabled)")
    }

    @objc private func configureLightHost() {
        let alert = NSAlert()
        alert.messageText = "Lamp daemon endpoint"
        alert.informativeText = "Хост и порт демона лампочки. Опционально — оставь пусто чтобы отключить."
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        let hostField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 22))
        hostField.placeholderString = "host (e.g. mac-mini.local)"
        hostField.stringValue = LightControl.shared.host
        let portField = NSTextField(frame: NSRect(x: 0, y: 2, width: 320, height: 22))
        portField.placeholderString = "port (e.g. 7420)"
        portField.stringValue = String(LightControl.shared.port)
        container.addSubview(hostField)
        container.addSubview(portField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = hostField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let h = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, let p = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 else {
            showError("host must be non-empty, port must be a positive integer")
            return
        }
        LightControl.shared.host = h
        LightControl.shared.port = p
        TrayLog.append("light: endpoint = \(h):\(p)")
    }

    @objc private func testLight() {
        // Manual test — bypass any active circuit breaker so the user can
        // verify the lamp is reachable again after moving networks.
        LightControl.shared.resetBreaker()
        LightControl.shared.set(.recording, bypassBreaker: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let phase: LightControl.Phase = AudioCapture.shared.isAvailable ? .idle : .disconnected
            LightControl.shared.set(phase, bypassBreaker: true)
        }
    }

    @objc private func configureDeepgramKey() {
        let alert = NSAlert()
        alert.messageText = "Deepgram API key"
        alert.informativeText = "Сохранится в login Keychain (service wam-voice-capture.deepgram.api_key, account deepgram)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = isDeepgramKeyPresent() ? "•••••••• (уже сохранён — введи новый, чтобы перезаписать)" : "сюда вставь ключ"
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainHelper.setDeepgramAPIKey(key)
            TrayLog.append("deepgram key saved to keychain")
        } catch {
            showError(error.localizedDescription)
            TrayLog.append("deepgram key save failed: \(error.localizedDescription)")
        }
    }
}
