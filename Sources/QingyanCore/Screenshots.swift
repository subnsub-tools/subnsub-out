import Foundation
import UniformTypeIdentifiers

/// Screenshots macOS saves, as they are saved (user 2026-11-27: screenshots go on the Shelf, with a
/// switch after the Shelf's sign; the file stays where macOS put it). While on, the folder the
/// Screenshot app saves to (its Options → Save to, `com.apple.screencapture`'s location; the
/// Desktop when none is set) is watched, and each new image file in it that macOS marks as a screen
/// capture is told once, by the file itself (renamed afterwards, it is not told again). The folder is
/// looked up again every 10 seconds, off the main thread, so a change of Save to is followed, and a
/// screenshot made there since the last look is still new. Files made before it was turned on, screen
/// recordings, and screenshots taken to the clipboard (no file) are left out.
@MainActor
public final class ScreenshotWatcher {
    public var onScreenshot: ((URL) -> Void)?
    /// Where to watch in place of where macOS saves screenshots (the checks).
    public var folderOverride: URL?
    public private(set) var folder: URL?
    public var isOn: Bool { handles.timer != nil }

    /// What must be let go when the watcher goes: kept apart, so that it can be from any thread.
    private final class Handles: @unchecked Sendable {
        var timer: Timer?
        var source: DispatchSourceFileSystemObject?
    }
    private let handles = Handles()
    /// Each folder watched has its own number: a look begun for an earlier one says nothing of it.
    private var generation = 0
    /// The names in the folder at the last look, and whether a look at it has succeeded.
    private var known: Set<String> = []
    private var listed = false
    /// From when a screenshot in the folder watched is new: when it was turned on, or when the
    /// folder before it was last seen to be where screenshots go.
    private var newSince = Date()
    /// When the folder watched was last seen to be where screenshots go.
    private var checked = Date()
    /// New images not marked yet, with when each was first seen: looked at again for 10 seconds,
    /// in case the mark comes after the file.
    private var unmarked: [String: Date] = [:]
    /// The files told, by device and inode.
    private var told: Set<String> = []
    private var scanning = false
    private var again = false
    private var looking = false

    public init() {}

    deinit {
        let handles = self.handles
        DispatchQueue.main.async {
            handles.timer?.invalidate()
            handles.source?.cancel()
        }
    }

    public func set(on: Bool) {
        if on, handles.timer == nil {
            newSince = Date(); checked = newSince; told = []
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            handles.timer = timer
            look()
        } else if !on, let timer = handles.timer {
            timer.invalidate()
            handles.timer = nil
            detach()
        }
    }

    /// Where screenshots go now, found and opened off the main thread (the folder may be on a slow
    /// volume), and watched if it is not the folder watched. One that cannot be opened (not there,
    /// or not allowed yet) is tried again at the next look; so is a folder whose listing failed.
    private func look() {
        guard !looking else { return }
        looking = true
        let override = folderOverride, current = folder, watching = handles.source != nil, generation = self.generation
        Task.detached(priority: .utility) {
            let target = (override ?? Self.saveFolder()).standardizedFileURL
            let same = watching && target == current
            let descriptor: Int32 = same ? -1 : open(target.path, O_EVTONLY)
            await MainActor.run { [weak self] in
                guard let self, self.isOn, self.generation == generation else {
                    if descriptor >= 0 { close(descriptor) }
                    self?.looking = false
                    return
                }
                self.looking = false
                if same {
                    self.checked = Date()
                    if !self.listed { self.scan() }
                } else {
                    self.watch(target, descriptor: descriptor)
                }
            }
        }
    }

    private func watch(_ target: URL, descriptor: Int32) {
        let from = checked
        detach()
        folder = target
        newSince = from
        guard descriptor >= 0 else { return }
        let generation = self.generation
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source, self.generation == generation else { return }
                // The folder itself moved, went, or its volume did: found again by where screenshots go.
                if !source.data.isDisjoint(with: [.rename, .delete, .revoke]) {
                    self.detach()
                    self.look()
                    return
                }
                self.scan()
            }
        }
        source.setCancelHandler { close(descriptor) }
        handles.source = source
        source.resume()
        scan()
    }

    private func detach() {
        handles.source?.cancel()
        handles.source = nil
        folder = nil
        known = []; listed = false; unmarked = [:]
        scanning = false; again = false
        generation += 1
    }

    private enum Seen: Sendable {
        case screenshot(String)
        case unmarkedImage
        case other
    }

    /// Lists the folder off the main thread (a Desktop may hold thousands of files) and tells the
    /// screenshots among the names that were not there at the last look, and among the new images
    /// whose mark had not come yet. A listing that fails leaves what was known as it was.
    private func scan() {
        guard let folder else { return }
        if scanning { again = true; return }
        scanning = true
        let generation = self.generation, known = self.known, since = newSince, waiting = Set(unmarked.keys)
        Task.detached(priority: .utility) {
            let listing = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            var names = Set<String>()
            var found: [(URL, String)] = [], unmarkedNow: [String] = []
            if let listing {
                names = Set(listing.filter { !$0.hasPrefix(".") })
                for name in names.subtracting(known).union(waiting.intersection(names)).sorted() {
                    let url = folder.appendingPathComponent(name)
                    switch Self.seen(url, since: since) {
                    case .screenshot(let identity): found.append((url, identity))
                    case .unmarkedImage: unmarkedNow.append(name)
                    case .other: break
                    }
                }
            }
            let listed = listing != nil, seenNames = names, screenshots = found, notYet = unmarkedNow
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.scanning = false
                guard listed else { return }
                self.known = seenNames
                self.listed = true
                let now = Date()
                var next: [String: Date] = [:]
                for name in notYet {
                    let first = self.unmarked[name] ?? now
                    if now.timeIntervalSince(first) < 10 { next[name] = first }
                }
                self.unmarked = next
                for (url, identity) in screenshots where !self.told.contains(identity) {
                    self.told.insert(identity)
                    self.onScreenshot?(url)
                }
                if self.again {
                    self.again = false
                    self.scan()
                } else if !next.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        MainActor.assumeIsolated { if self?.generation == generation { self?.scan() } }
                    }
                }
            }
        }
    }

    /// A screenshot made since `since` (a moment of leeway: an older one moved into the folder is not
    /// new), with the file's device and inode; an image of that age not marked (yet); or anything else.
    nonisolated private static func seen(_ url: URL, since: Date) -> Seen {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .creationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, values.contentType?.conforms(to: .image) == true,
              (values.creationDate ?? .distantPast) >= since.addingTimeInterval(-2) else { return .other }
        guard isScreenCapture(url) else { return .unmarkedImage }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .other }
        return .screenshot("\(status.st_dev):\(status.st_ino)")
    }

    /// Whether macOS marked the file as a screen capture: the kMDItemIsScreenCapture attribute it
    /// writes with each screenshot (a property list holding true), read without Spotlight.
    public nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW) == size,
              let value = try? PropertyListSerialization.propertyList(from: Data(buffer), format: nil) else { return false }
        return (value as? Bool) == true
    }

    /// Where the Screenshot app saves now: its Save to, else the Desktop.
    public nonisolated static func saveFolder() -> URL {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        if let raw = CFPreferencesCopyAppValue("location" as CFString, domain) as? String {
            let path = (raw as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
