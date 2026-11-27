import Foundation

public struct SavedDictation: Codable {
    public var mode: WritingMode
    /// The on/off from before styles; `style` is the real choice, this is kept for old recordings.
    public var polish: Bool
    /// The style chosen when the recording was made. Absent in recordings saved before styles.
    public var style: DictationStyle?
    public var targetLanguage: String
    public var speechModel: String
    public var textModel: String
    public var dictionary: [String]
    public var selection: String
    /// Which platform each model belongs to. Absent in recordings saved before there was a choice: OpenAI.
    public var speechPlatform: String?
    public var textPlatform: String?

    /// The style this recording is written in: its own, or Raw for a recording from before styles,
    /// whatever its old on/off said — put polishes only once a style is chosen in Settings (user 2026-11-20).
    public var writing: DictationStyle { style ?? .raw }

    public init(mode: WritingMode, polish: Bool, targetLanguage: String, speechModel: String,
                textModel: String, dictionary: [String], selection: String,
                speechPlatform: String? = nil, textPlatform: String? = nil,
                style: DictationStyle? = nil) {
        self.mode = mode; self.polish = polish; self.style = style; self.targetLanguage = targetLanguage
        self.speechModel = speechModel; self.textModel = textModel
        self.dictionary = dictionary; self.selection = selection
        self.speechPlatform = speechPlatform; self.textPlatform = textPlatform
    }
}

public enum RecordingStatus: String, Codable {
    case recording, processing, pending, failed, completed
    public var title: String {
        switch self {
        case .recording: return tr("Recording")
        case .processing: return tr("Transcribing")
        case .pending: return tr("Waiting for network")
        case .failed: return tr("Retry pending")
        case .completed: return tr("Completed")
        }
    }
}

public struct HistoryEntry: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var text: String
    public var mode: WritingMode
    public var seconds: Double
    // Optional fields keep the original text-only history decodable.
    public var status: RecordingStatus?
    public var problem: String?
    public var request: SavedDictation?
    public var transcript: String?
    /// How many attempts to turn this recording into text have failed in a row, the first one
    /// included. Kept with the entry, so a restart does not start the count again.
    public var failures: Int?
    /// The Mac it was dictated on, when that is another of the owner's Macs (HistorySync), or the
    /// Mac whose text this one received: its key in the list of Macs, and its name as that Mac gave
    /// it. Nil: this Mac.
    public var origin: String?
    public var originName: String?
    /// When it last changed on any Mac: of two Macs that differ, the later change is kept.
    public var updated: Date?
    public var changed: Date { updated ?? date }
    public var state: RecordingStatus { status ?? .completed }
    public var canRetry: Bool { request != nil && (state == .pending || state == .failed) }

    public init(text: String, mode: WritingMode, seconds: Double, status: RecordingStatus = .completed,
                request: SavedDictation? = nil, problem: String? = nil) {
        self.text = text; self.mode = mode; self.seconds = seconds
        self.status = status; self.request = request; self.problem = problem
    }
}

/// Audio persistence and network consumption have independent lifetimes. A slow or dead
/// socket never backpressures the microphone. Readers pull bounded chunks from the file.
@MainActor
public final class RecordedAudio {
    public let url: URL
    public private(set) var bytes: Int
    private var writer: FileHandle?
    private var finished: Bool
    public var seconds: Double { Double(bytes) / 48000 }

    public init(url: URL, create: Bool) throws {
        self.url = url
        if create {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw VoiceError(tr("Cannot save the recording. Check the free disk space on this Mac.")) }
            writer = try FileHandle(forWritingTo: url)
            bytes = 0; finished = false
        } else {
            bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            finished = true
        }
    }

    public func append(_ data: Data) throws {
        guard let writer, !finished else { throw VoiceError(tr("The recording file is closed.")) }
        try writer.write(contentsOf: data)
        bytes += data.count
    }

    public func finish() throws {
        finished = true
        guard let writer else { return }
        self.writer = nil
        defer { try? writer.close() }
        try writer.synchronize()
    }

    public func stream() throws -> AsyncThrowingStream<Data, Error> {
        let reader = try AudioReader(url: url)
        return AsyncThrowingStream(unfolding: { @MainActor in
            while true {
                try Task.checkCancellation()
                if let data = try reader.file.read(upToCount: 24000), !data.isEmpty { return data }
                if self.finished { return nil }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        })
    }

    deinit { try? writer?.close() }
}

@MainActor private final class AudioReader {
    let file: FileHandle
    init(url: URL) throws { file = try FileHandle(forReadingFrom: url) }
    deinit { try? file.close() }
}

@MainActor
public final class DictationArchive {
    public private(set) var entries: [HistoryEntry]
    public let directory: URL
    private var index: URL { directory.appendingPathComponent("history.json") }

    public init(directory: URL, legacy: [HistoryEntry] = []) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        entries = []
        entries = FileManager.default.fileExists(atPath: index.path)
            ? try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: index)) : legacy
        for i in entries.indices where entries[i].state == .recording || entries[i].state == .processing {
            let audio = try? RecordedAudio(url: audioURL(entries[i].id), create: false)
            entries[i].seconds = audio?.seconds ?? entries[i].seconds
            entries[i].status = .failed
            entries[i].problem = tr("The last processing did not finish. The original recording is kept and can be retried by hand.")
        }
        try persist(entries)
        sweep()
    }

    public func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).pcm") }

    public func begin(_ request: SavedDictation) throws -> (HistoryEntry, RecordedAudio) {
        let entry = HistoryEntry(text: "", mode: request.mode, seconds: 0, status: .recording, request: request)
        let audio = try RecordedAudio(url: audioURL(entry.id), create: true)
        do { try persist([entry] + entries) }
        catch { try? audio.finish(); try? FileManager.default.removeItem(at: audio.url); throw error }
        return (entry, audio)
    }

    /// The recording kept with a record, where this Mac has one: none for a record made on another
    /// Mac, for text received, or for one finished before recordings were kept.
    public func recording(_ id: UUID) -> URL? {
        let url = audioURL(id)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? url : nil
    }

    /// A finished record keeps its recording (user 2026-11-27: kept, and played back from History),
    /// until the record itself goes.
    public func update(_ entry: HistoryEntry) throws {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { throw VoiceError(tr("This history entry has been deleted.")) }
        var next = entries
        next[i] = entry
        try persist(bounded(next))
    }

    /// Stores text that arrived already finished, such as text received from another Mac.
    public func add(_ entry: HistoryEntry) throws {
        try persist(bounded([entry] + entries))
    }

    /// The last 100 finished records are kept.
    public static let kept = 100

    /// The oldest finished record that would still be kept here: one older goes at once once 100 are kept.
    public var horizon: Date {
        let finished = entries.filter { $0.state == .completed }
        return finished.count >= Self.kept ? finished.map(\.date).min() ?? .distantPast : .distantPast
    }

    /// Takes a finished record from another Mac: a new one, or a later change of one here. A record
    /// still being recorded, transcribed or waiting here is not replaced. Returns whether it is kept.
    @discardableResult
    public func take(_ entry: HistoryEntry) throws -> Bool {
        guard entry.state == .completed else { return false }
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) {
            guard next[index].state == .completed, entry.changed > next[index].changed else { return false }
            next.remove(at: index)
        } else if entry.date <= horizon {
            return false
        }
        let place = next.firstIndex(where: { $0.date < entry.date }) ?? next.endIndex
        next.insert(entry, at: place)
        try persist(bounded(next))
        return entries.contains { $0.id == entry.id }
    }

    /// Removes the finished records another Mac removed. Nothing waiting for transcription here goes.
    public func drop(_ ids: Set<UUID>) throws {
        let next = entries.filter { !(ids.contains($0.id) && $0.state == .completed) }
        if next.count != entries.count { try persist(next) }
    }

    /// Removes what another Mac cleared: the finished records last changed by `moment`. A recording
    /// here waiting to be transcribed stays: that Mac's confirmation spoke of its own audio alone.
    public func drop(clearedAt moment: Date) throws {
        let next = entries.filter { !($0.state == .completed && $0.changed <= moment) }
        if next.count != entries.count { try persist(next) }
    }

    private func bounded(_ items: [HistoryEntry]) -> [HistoryEntry] {
        var completed = 0
        return items.filter { item in
            guard item.state == .completed else { return true }
            completed += 1
            return completed <= Self.kept
        }
    }

    /// The index first: a save that fails leaves the record with its recording, to play or to retry.
    public func remove(_ id: UUID) throws {
        try persist(entries.filter { $0.id != id })
    }

    public func clear() throws {
        try persist([])
    }

    /// Recordings whose record is gone go: one that could not be deleted when its record went, or
    /// one left by a stop between the index being saved and the file being deleted.
    private func sweep() {
        let kept = Set(entries.map { audioURL($0.id).lastPathComponent })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(".pcm") && UUID(uuidString: String(name.dropLast(4))) != nil && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func persist(_ next: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        // A record that goes takes its recording with it: past the last 100, removed or cleared on
        // another Mac, or deleted here.
        let kept = Set(next.map(\.id))
        for entry in entries where !kept.contains(entry.id) { try? FileManager.default.removeItem(at: audioURL(entry.id)) }
        entries = next
    }
}

/// How long a recording that could not be turned into text waits before it is tried again:
/// a minute, five, then every quarter of an hour. After about a day of failures it is left
/// for the user to retry by hand.
public enum RetryPace {
    public static let limit = 98

    /// `failures`: how many attempts have failed so far, the first one included. Nil: no more.
    public static func wait(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case ...1: return 60
        case 2: return 300
        case 3...limit: return 900
        default: return nil
        }
    }
}
