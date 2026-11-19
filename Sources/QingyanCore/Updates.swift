import Foundation

/// Where new builds of the app come from. Each place holds every signed build as
/// `put-<version>.zip` and a `put.json` naming the newest. (Its `latest.json` names the one build
/// that copies from before the rename, which read only that, take: see `AppLocation`.)
///
/// - first the public repository's standing release `builds`, where its workflow publishes them:
///   what anybody can check against the source and the build's attestation, so a build changed on
///   our site alone is not installed by a Mac that can reach GitHub;
/// - then our own site, which serves the same builds, for a Mac that cannot: asked at once when
///   somebody checks by hand, and by the automatic check only once GitHub has been out of reach
///   for `githubGrace`. A GitHub that answers (with no build, a manifest that cannot be read, or a
///   package that fails verification) is never a reason to ask the site instead.
///
/// Neither needs a sign-in, so each Mac checks by itself. That they are open does not matter
/// for what gets installed: a build is ours by its signature, which the app proves before it
/// replaces itself (see `Updater`). The build number is the last part of the version and only grows.
public enum UpdateFeed {
    public enum Source: String, CaseIterable, Sendable {
        case github, site

        public var base: URL {
            switch self {
            case .github: return URL(string: "https://github.com/subnsub-tools/subnsub-put/releases/download/builds/")!
            case .site: return URL(string: "https://dashboard.subnsub.com/api/input/")!
            }
        }
        public var manifest: URL { base.appendingPathComponent("put.json") }
    }

    /// How long GitHub must have been out of reach before the automatic check asks the site.
    public static let githubGrace: TimeInterval = 6 * 3600
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
        /// Where the manifest came from, and so the zip.
        public let source: Source
    }

    /// "0.1.57" → 57. Nil for anything that is not digits and dots.
    public static func number(of version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let last = parts.last else { return nil }
        return Int(last)
    }

    /// The build `put.json` announces:
    /// `{"version": "0.1.57", "file": "put-0.1.57.zip", "size": 1209759, "sha256": "<64 hex digits>"}`.
    /// Nil when it is not that. The zip is always fetched from beside the manifest, under the one
    /// name its version gives it: the manifest says which build, never where from.
    public static func build(in manifest: Any, from source: Source) -> Build? {
        guard let object = manifest as? [String: Any], let version = object["version"] as? String,
              let number = number(of: version), object["file"] as? String == "put-\(version).zip",
              let size = object["size"] as? Int, size > 0, size <= largest,
              let stated = object["sha256"] as? String else { return nil }
        let digest = stated.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return Build(version: version, number: number, asset: source.base.appendingPathComponent("put-\(version).zip"),
                     size: size, digest: digest, source: source)
    }

    /// A failure that says nothing about what is published: no answer at all, or the host's own
    /// trouble. Only this moves an update on from GitHub to the site; an answer never does.
    public static func away(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.code != .cancelled
    }

    public static func away(status: Int) -> Bool { status >= 500 || status == 429 }

    /// Since when GitHub has been out of reach, after one attempt at it: kept (or started) when the
    /// attempt as a whole got no answer, whichever request it stopped at; gone once GitHub answered.
    public static func githubDownSince(afterAway away: Bool, was since: Date?, now: Date = Date()) -> Date? {
        away ? (since ?? now) : nil
    }

    /// Whether the site may be asked once GitHub could not be reached: at once for somebody who
    /// asked by hand, and for the automatic check once GitHub has been out of reach for the grace.
    public static func asksSite(manual: Bool, githubDownSince: Date?, now: Date = Date()) -> Bool {
        if manual { return true }
        guard let since = githubDownSince else { return false }
        return now.timeIntervalSince(since) >= githubGrace
    }

    /// GitHub answers a release file with a redirect to where it is stored. A redirect anywhere
    /// else is not followed, and then it is the answer.
    public static func followsRedirect(to url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host)
    }

    /// Always asked afresh: an answer kept from earlier would hide a new build.
    public static func request(_ url: URL, file: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: file ? 120 : 20)
        request.setValue(file ? "application/zip" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("put-updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// What a failed answer means, in words that say what to do.
    public static func problem(status: Int) -> VoiceError {
        switch status {
        case 404: return VoiceError(tr("No version is available from the update server yet."))
        case 403, 429: return VoiceError(tr("Too many update checks. put will try again automatically."), retryable: true)
        default: return VoiceError(tr("Update check failed (HTTP %ld).", status), retryable: true)
        }
    }
}

/// Where the app lives. It was called input before it was called put, and the builds from before
/// the rename install and update it as /Applications/input.app. A copy started from there moves
/// itself to /Applications/put.app, once, unless something is there already; either way, a copy in
/// Applications under either name keeps itself up to date.
public enum AppLocation {
    public static let current = "/Applications/put.app"
    public static let legacy = "/Applications/input.app"

    public enum Step: Equatable, Sendable { case stay, move }

    /// What a copy started from `running` does about where it is.
    public static func step(running: String, currentTaken: Bool) -> Step {
        running == legacy && !currentTaken ? .move : .stay
    }

    /// Only a copy in Applications replaces itself with a new build.
    public static func replaceable(_ running: String) -> Bool { running == current || running == legacy }
}
