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

    /// The style this recording is written in: its own, or what its old on/off meant.
    public var writing: DictationStyle { style ?? (polish ? .polish : .raw) }

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
    }

    public func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).pcm") }

    public func begin(_ request: SavedDictation) throws -> (HistoryEntry, RecordedAudio) {
        let entry = HistoryEntry(text: "", mode: request.mode, seconds: 0, status: .recording, request: request)
        let audio = try RecordedAudio(url: audioURL(entry.id), create: true)
        do { try persist([entry] + entries) }
        catch { try? audio.finish(); try? FileManager.default.removeItem(at: audio.url); throw error }
        return (entry, audio)
    }

    public func update(_ entry: HistoryEntry) throws {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { throw VoiceError(tr("This history entry has been deleted.")) }
        var next = entries
        next[i] = entry
        try persist(bounded(next))
        if entry.state == .completed, FileManager.default.fileExists(atPath: audioURL(entry.id).path) {
            try FileManager.default.removeItem(at: audioURL(entry.id))
        }
    }

    /// Stores text that arrived already finished, such as text received from another Mac.
    public func add(_ entry: HistoryEntry) throws {
        try persist(bounded([entry] + entries))
    }

    private func bounded(_ items: [HistoryEntry]) -> [HistoryEntry] {
        var completed = 0
        return items.filter { item in
            guard item.state == .completed else { return true }
            completed += 1
            return completed <= 100
        }
    }

    public func remove(_ id: UUID) throws {
        let url = audioURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try persist(entries.filter { $0.id != id })
    }

    public func clear() throws {
        for entry in entries { try remove(entry.id) }
    }

    private func persist(_ next: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
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
