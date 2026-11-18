import Foundation

/// Where new builds of the app come from: our own site. It serves every signed build as
/// `input-<version>.zip` (released from the repository by its workflow) and a `latest.json` naming the newest.
/// The address needs no sign-in, so each Mac checks by itself. That it is open does not matter
/// for what gets installed: a build is ours by its signature, which the app proves before it
/// replaces itself (see `Updater`). The build number is the last part of the version and only grows.
public enum UpdateFeed {
    public static let base = URL(string: "https://dashboard.subnsub.com/api/input/")!
    public static let bundleIdentifier = "local.hopo.qingyan"
    /// No build is anywhere near this; a manifest that says more is not believed.
    public static let largest = 200 * 1024 * 1024

    public struct Build: Equatable, Sendable {
        public let version: String
        public let number: Int
        public let asset: URL
        public let size: Int
        /// SHA-256 of the zip, in lower-case hex.
        public let digest: String
    }

    public static var latest: URL { base.appendingPathComponent("latest.json") }

    /// "0.1.57" → 57. Nil for anything that is not digits and dots.
    public static func number(of version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let last = parts.last else { return nil }
        return Int(last)
    }

    /// The build `latest.json` announces:
    /// `{"version": "0.1.57", "file": "input-0.1.57.zip", "size": 1209759, "sha256": "<64 hex digits>"}`.
    /// Nil when it is not that. The zip is always fetched from beside the manifest, under the one
    /// name its version gives it: the manifest says which build, never where from.
    public static func build(in manifest: Any) -> Build? {
        guard let object = manifest as? [String: Any], let version = object["version"] as? String,
              let number = number(of: version), object["file"] as? String == "input-\(version).zip",
              let size = object["size"] as? Int, size > 0, size <= largest,
              let stated = object["sha256"] as? String else { return nil }
        let digest = stated.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return Build(version: version, number: number, asset: base.appendingPathComponent("input-\(version).zip"), size: size, digest: digest)
    }

    /// Always asked afresh: an answer kept from earlier would hide a new build.
    public static func request(_ url: URL, file: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: file ? 120 : 20)
        request.setValue(file ? "application/zip" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("input-updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// What a failed answer means, in words that say what to do.
    public static func problem(status: Int) -> VoiceError {
        switch status {
        case 404: return VoiceError(tr("No version is available from the update server yet."))
        case 403, 429: return VoiceError(tr("Too many update checks. input will try again automatically."), retryable: true)
        default: return VoiceError(tr("Update check failed (HTTP %ld).", status), retryable: true)
        }
    }
}
