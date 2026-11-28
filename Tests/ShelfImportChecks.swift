import Foundation
import QingyanCore
@testable import Qingyan

// bash Tests/check-shelf-import.sh — no application delegate, clipboard, history, or peer/helper.
@main
struct ShelfImportChecks {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw VoiceError("Run with Tests/check-shelf-import.sh") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
            let files = FileManager.default
            guard files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path == support.resolvingSymlinksInPath().path,
                  !files.fileExists(atPath: support.appendingPathComponent("Qingyan").path) else { throw VoiceError("A fresh, isolated home is required") }
            let shelf = ShelfModel(preview: false)
            guard let store = shelf.store else { throw VoiceError("The test shelf could not be opened") }
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            func source(_ folder: String, _ name: String, _ bytes: Data) throws -> URL {
                let dir = root.appendingPathComponent(folder, isDirectory: true)
                try files.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name)
                try bytes.write(to: url)
                try files.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                return url
            }
            var failures: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

            let a = Data("AAAA".utf8), b = Data("BBBB".utf8)
            let first = try source("A", "report.txt", a), second = try source("B", "report.txt", b)
            let duplicate = try source("C", "report.txt", a)
            check(try await shelf.importFile(first), "first report not added")
            check(try await shelf.importFile(second), "distinct report with matching metadata lost")
            check(try await !shelf.importFile(duplicate), "byte-identical report added again")

            // A difference at the very end must count, even when three imports race for the same name.
            var tailA = Data(repeating: 42, count: (1 << 20) + 11), tailB = tailA
            tailA[tailA.count - 1] = 1; tailB[tailB.count - 1] = 2
            let one = try source("A", "race.bin", tailA), two = try source("B", "race.bin", tailB)
            let three = try source("C", "race.bin", tailA)
            async let r1 = shelf.importFile(one), r2 = shelf.importFile(two), r3 = shelf.importFile(three)
            let results = try await [r1, r2, r3]
            check(results[1] && results[0] != results[2], "concurrent imports did not add exactly one of each payload")
            let reopened = try ShelfStore(directory: store.directory)
            for (name, expected) in [("report.txt", [a, b]), ("race.bin", [tailA, tailB])] {
                let saved = try reopened.items.filter { $0.name == name }.map { try Data(contentsOf: reopened.url($0)) }
                check(saved.count == 2 && Set(saved) == Set(expected), "wrong persisted bytes/count for \(name)")
            }

            let remote = ShelfItem(kind: .file, name: "remote.txt", size: a.count, origin: "Elsewhere", card: true, modified: date)
            try store.acceptCard(remote, thumbnail: nil)
            check((try? await shelf.importFile(store.url(remote))) == nil, "a card's missing local file was reported as already on the Shelf")
            let local = try source("A", "remote.txt", a)
            check(try await shelf.importFile(local), "a card without bytes swallowed a local import")
            check(!store.isPresent(remote.id) && store.items.contains { $0.name == remote.name && store.isOwn($0.id) }, "remote card or local bytes missing")

            let quiet = try source("A", "quiet.txt", a), other = try source("B", "quiet.txt", b)
            shelf.shelveCopied([quiet])
            struct Links: Decodable { let quiet: [UUID] }
            let links = store.directory.appendingPathComponent("links.json")
            func quietIDs() throws -> [UUID] { try JSONDecoder().decode(Links.self, from: Data(contentsOf: links)).quiet }
            let deadline = ContinuousClock.now + .seconds(15)
            while (try? quietIDs().first) == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard let id = try quietIDs().first, store.item(id)?.name == "quiet.txt" else { throw VoiceError("The copied file did not arrive quietly") }
            check(try await shelf.importFile(other), "explicit import promoted a quiet file with different bytes")
            check(try quietIDs() == [id], "unrelated import cleared quiet status")
            check(try await !shelf.importFile(quiet), "promotion added a second item")
            check(try quietIDs().isEmpty, "an explicit duplicate did not promote the quiet file")

            guard failures.isEmpty else { throw VoiceError(failures.joined(separator: "; ")) }
            print("PASS shelf file imports: stored and concurrent collisions, true duplicates, persisted bytes, remote card, quiet promotion")
        } catch { print("FAIL shelf file imports: \(error.localizedDescription)"); exit(1) }
    }
}
