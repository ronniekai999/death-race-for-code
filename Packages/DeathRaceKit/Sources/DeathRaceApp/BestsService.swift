import AppCore
import Foundation
import VTCore

/// The app's record of how fast each command has been, shared by every pane and kept on disk.
///
/// Shared, not per-pane, because a record that only counted within one pane would be a
/// different claim from the one the badge makes: `swift build` is `swift build` whichever split
/// you ran it in, and a "personal best" that resets when you open a second pane is not one.
///
/// On disk through `BestsStore`, unless `bests-on-disk` is off, in which case this is exactly
/// what it was before — in memory, for one run.
@MainActor
final class BestsService {
    private var bests: CommandBests
    private var store: BestsStore?
    /// A write is pending because something changed; see `save(soon:)`.
    private var dirty = false
    /// So a loop of distinct commands writes the file a few times rather than a thousand.
    private var saving = false

    /// How long a change waits for others before the file is written.
    static let settleSeconds = 3.0

    /// `store` nil means in memory only. A file that cannot be read leaves the records empty
    /// rather than failing the launch: losing your records is a disappointment, and not being
    /// able to open a terminal is not a trade anyone would make.
    init(store: BestsStore?) {
        self.store = store
        if let store, let loaded = try? store.load() {
            bests = loaded
        } else {
            bests = CommandBests()
        }
    }

    /// The fastest `command` has been, or nil for one never seen.
    func best(for command: String) -> UInt32? { bests.best(for: command) }

    /// A command ended. Remembers its time when it is one worth remembering, and answers the
    /// best it beat so the words can say by how much.
    ///
    /// Successful runs only, with a duration and some text: a command that failed after four
    /// seconds set no record, and offering it as one next time would be a lie in the shape of a
    /// compliment. `CommandBests` also refuses one typed with a leading space.
    @discardableResult
    func record(_ command: CommandRecord) -> UInt32? {
        guard command.exitCode == 0, let milliseconds = command.durationMilliseconds, !command.text.isEmpty else {
            return nil
        }
        let had = bests.count
        let beaten = bests.record(command: command.text, milliseconds: milliseconds)
        // Nothing changed when a slower run of a command already known comes in, which is most
        // of them, and an unchanged file is not worth writing.
        guard beaten != nil || bests.count != had else { return nil }
        save(soon: true)
        return beaten
    }

    /// Whether the records are kept between runs; the setting turns this off and empties the
    /// file's future, not its past — deleting it is yours to do, and the help says so.
    func setKeepingOnDisk(_ keeping: Bool, store makeStore: () -> BestsStore?) {
        if keeping {
            guard store == nil else { return }
            store = makeStore()
            save(soon: false)
        } else {
            store = nil
            dirty = false
        }
    }

    /// Writes the file, at most once every `settleSeconds` when `soon`. At quit, call with
    /// `soon: false` so the last records are not lost to a timer that never fires.
    func save(soon: Bool) {
        guard let store else { return }
        dirty = true
        guard !soon else {
            guard !saving else { return }
            saving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
                self?.saving = false
                self?.save(soon: false)
            }
            return
        }
        guard dirty else { return }
        dirty = false
        // A file this build must not replace — one a newer build wrote, or one it cannot read —
        // is left exactly as it is. There is nothing to tell the user about that they could act
        // on, and a record is not worth a sheet, so it goes to the log.
        do {
            try store.save(bests)
        } catch {
            NSLog("death-race: could not write \(store.path): \(error)")
        }
    }
}
