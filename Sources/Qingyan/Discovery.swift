import Foundation

/// The Macs that Tailscale itself says are online, asked through its command-line tool.
/// Tailscale is the only one who knows who is on the tailnet; nothing here scans the network.
enum TailscalePeers {
    struct Node: Sendable {
        let name: String
        let address: String
    }

    static func online() async -> [Node] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: load()) }
        }
    }

    private static func load() -> [Node] {
        let tools = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        for path in tools where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            // A tool that hangs must not hold the search up for good.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let peers = object["Peer"] as? [String: Any] else { continue }
            return peers.values.compactMap { value in
                guard let peer = value as? [String: Any], peer["Online"] as? Bool == true, peer["OS"] as? String == "macOS",
                      let address = (peer["TailscaleIPs"] as? [String])?.first(where: { $0.contains(".") }) else { return nil }
                return Node(name: peer["HostName"] as? String ?? address, address: address)
            }
        }
        return []
    }
}
