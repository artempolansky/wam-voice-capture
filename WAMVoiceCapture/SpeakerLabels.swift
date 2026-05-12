import Foundation

/// Per-meeting speaker registry.
///
/// Maps Deepgram's per-channel `(channel, speaker_id)` pair to a stable
/// internal ID and a display label. Mic (channel 0) is always Speaker 1.
/// System audio (channel 1) speakers are numbered Speaker 2, 3, 4, ... in the
/// order they first appear in the meeting.
///
/// User-supplied custom names ("Anya" for Speaker 2) are stored here and
/// substituted in the transcript file.
@MainActor
final class SpeakerLabels {

    /// Stable internal ID, e.g. "speaker-1" (mic), "speaker-2" (system, dg=0),
    /// "speaker-3" (system, dg=1), ...
    typealias InternalID = String

    /// Fired when a new speaker appears or an existing one is renamed.
    /// Status bar uses this to refresh the Rename submenu.
    var onChange: (() -> Void)?

    /// Display label currently used in the transcript file. For Speaker N
    /// without a custom name, equals "Speaker N". After rename, equals the
    /// custom name. Tracked separately from `customNames` so the file rewrite
    /// knows what to find-and-replace.
    private var currentLabel: [InternalID: String] = [:]

    /// User-supplied custom names. Persists for the meeting; cleared on reset.
    private var customNames: [InternalID: String] = [:]

    /// Order-of-first-appearance for system-audio speakers. Index 0 here
    /// corresponds to Speaker 2, index 1 → Speaker 3, etc.
    private var systemSpeakerOrder: [String] = []  // keys "ch1-dg0", "ch1-dg1", ...

    /// True once the mic side has produced any final transcript.
    private var micSeen: Bool = false

    // MARK: - Lookup

    /// Resolve `(channel, dg-speaker)` to a stable internal ID.
    /// Registers the speaker on first sight.
    func internalID(channel: Int, dgSpeaker: Int?) -> InternalID {
        if channel == 0 {
            if !micSeen {
                micSeen = true
                currentLabel["speaker-1"] = "Speaker 1"
                onChange?()
            }
            return "speaker-1"
        }
        // System audio: number speakers in order of first appearance.
        let key = "ch\(channel)-dg\(dgSpeaker ?? 0)"
        if !systemSpeakerOrder.contains(key) {
            systemSpeakerOrder.append(key)
            let idx = systemSpeakerOrder.count + 1   // Speaker 2, 3, 4, ...
            let id = "speaker-\(idx)"
            currentLabel[id] = "Speaker \(idx)"
            onChange?()
            return id
        }
        let idx = systemSpeakerOrder.firstIndex(of: key)! + 2
        return "speaker-\(idx)"
    }

    /// Display label as it appears in the transcript file right now.
    func displayName(for id: InternalID) -> String {
        currentLabel[id] ?? id
    }

    /// All known speakers in stable order (Speaker 1 first, then 2, 3, ...).
    /// Used by the tray menu to list active speakers.
    func activeSpeakers() -> [(id: InternalID, label: String)] {
        var out: [(InternalID, String)] = []
        if micSeen {
            out.append(("speaker-1", currentLabel["speaker-1"] ?? "Speaker 1"))
        }
        for (i, _) in systemSpeakerOrder.enumerated() {
            let id = "speaker-\(i + 2)"
            out.append((id, currentLabel[id] ?? "Speaker \(i + 2)"))
        }
        return out
    }

    // MARK: - Mutation

    /// Rename a speaker. Returns the (oldLabel, newLabel) so the caller can
    /// rewrite the transcript file. Returns nil if the new name equals the
    /// current label or the speaker isn't known.
    @discardableResult
    func rename(_ id: InternalID, to newName: String) -> (oldLabel: String, newLabel: String)? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let old = currentLabel[id], old != trimmed else { return nil }
        customNames[id] = trimmed
        currentLabel[id] = trimmed
        onChange?()
        return (old, trimmed)
    }

    /// Clear all state — call at the start of a new meeting.
    func reset() {
        currentLabel.removeAll()
        customNames.removeAll()
        systemSpeakerOrder.removeAll()
        micSeen = false
        onChange?()
    }
}
