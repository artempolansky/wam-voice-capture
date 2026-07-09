import Foundation

/// Per-meeting speaker registry.
///
/// Maps Deepgram's per-final `(channel, speaker_id)` pair to a stable
/// internal ID + a display label, numbered in order of first appearance
/// starting at Speaker 1.
///
/// **v1.0.4 behavior change.** Before v1.0.4 the mic channel (channel 0)
/// was hard-locked to Speaker 1 and Deepgram's per-word `speaker` was
/// discarded there — so if two people spoke through the mic (e.g. laptop
/// speakers bleeding a call participant's voice back into the built-in
/// mic, which is the common single-Mac setup), the whole meeting came out
/// as "Speaker 1" with no way to tell who said what. Now every distinct
/// `(channel, dgSpeaker)` pair reserves its own slot, and speakers are
/// numbered in order of first appearance — the very first voice heard
/// ends up as Speaker 1 (still almost always the user), the second voice
/// as Speaker 2, and so on.
///
/// User-supplied custom names ("Anya" for Speaker 2) are stored here and
/// substituted in the transcript file.
@MainActor
final class SpeakerLabels {

    /// Stable internal ID: "speaker-1", "speaker-2", ... assigned in order
    /// of first appearance (any channel).
    typealias InternalID = String

    /// Fired when a new speaker appears or an existing one is renamed.
    /// Status bar uses this to refresh the Rename submenu.
    var onChange: (() -> Void)?

    /// Display label currently used in the transcript file. For a speaker
    /// without a custom name, equals "Speaker N". After rename, equals the
    /// custom name. Tracked separately from `customNames` so the file
    /// rewrite knows what to find-and-replace.
    private var currentLabel: [InternalID: String] = [:]

    /// User-supplied custom names. Persists for the meeting; cleared on reset.
    private var customNames: [InternalID: String] = [:]

    /// Order-of-first-appearance for all voices. Index 0 → Speaker 1,
    /// index 1 → Speaker 2, ... Each entry is a key of the form
    /// "ch{channel}-dg{dgSpeaker}". A meeting always starts with a single
    /// entry (whoever spoke first — usually the user on mic) and grows as
    /// new voices are heard.
    private var speakerOrder: [String] = []

    // MARK: - Lookup

    /// Resolve `(channel, dg-speaker)` to a stable internal ID.
    /// Registers the speaker on first sight.
    func internalID(channel: Int, dgSpeaker: Int?) -> InternalID {
        // Normalize the identity key. dgSpeaker is nil when Deepgram is
        // running without `diarize=true` (or on a final that has no
        // words[]); treat as speaker 0 within its channel so the numbering
        // stays deterministic.
        let key = "ch\(channel)-dg\(dgSpeaker ?? 0)"

        if let existing = speakerOrder.firstIndex(of: key) {
            return "speaker-\(existing + 1)"
        }

        speakerOrder.append(key)
        let idx = speakerOrder.count   // Speaker 1 on first call, then 2, 3, ...
        let id = "speaker-\(idx)"
        currentLabel[id] = "Speaker \(idx)"
        onChange?()
        return id
    }

    /// Display label as it appears in the transcript file right now.
    func displayName(for id: InternalID) -> String {
        currentLabel[id] ?? id
    }

    /// All known speakers in stable order (Speaker 1 first, then 2, 3, ...).
    /// Used by the tray menu to list active speakers.
    func activeSpeakers() -> [(id: InternalID, label: String)] {
        var out: [(InternalID, String)] = []
        for i in 0..<speakerOrder.count {
            let id = "speaker-\(i + 1)"
            out.append((id, currentLabel[id] ?? "Speaker \(i + 1)"))
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
        speakerOrder.removeAll()
        onChange?()
    }
}
