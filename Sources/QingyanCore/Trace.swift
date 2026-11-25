import Foundation
import os

/// What out decides while it sends text to another Mac or receives text from one, a line for each
/// step, in the system log (user 2026-11-25: a paste that failed could not be traced afterwards, as
/// nothing said why the sending Mac gave up). Never the text itself: the names of Macs and apps,
/// sizes, reasons and times. Notice level, which the system keeps on disk. Read on each Mac with
/// `log show --last 1h --predicate 'subsystem == "local.hopo.qingyan"'`.
public enum Trace {
    private static let remote = Logger(subsystem: "local.hopo.qingyan", category: "remote")

    /// One step. Callers put no dictated or pasted text in it.
    public static func note(_ line: String) {
        remote.notice("\(line, privacy: .public)")
    }

    /// Milliseconds since `start`, for a line.
    public static func ms(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }
}
