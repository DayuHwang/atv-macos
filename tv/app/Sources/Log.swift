// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: one log file for everything — our Swift code, the engine's stderr
// and the JIT helper's output — so the status page can serve it to a viewer
// with no screen attached to the Apple TV.
import Foundation

enum Log {
    static let url: URL = Storage.root.appendingPathComponent("atv.log")
    private static let lock = NSLock()
    private static var started = false

    /// Sends stdout and stderr (the engine logs there) into atv.log.
    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        // Keep the previous run's log beside the new one: a crash is easier to read after a relaunch.
        let previous = Storage.root.appendingPathComponent("atv.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = open(url.path, O_WRONLY | O_APPEND)
        if fd >= 0 {
            dup2(fd, STDERR_FILENO)
            dup2(fd, STDOUT_FILENO)
            close(fd)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
    }

    static func line(_ tag: String, _ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        fputs("[\(stamp)] [\(tag)] \(text)\n", stderr)
    }

    /// The last `bytes` of the log, for the status page.
    static func tail(_ bytes: Int = 64 << 10) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where the machine lives. tvOS gives apps no persistent Documents folder, only
/// Caches (which the system may purge when storage runs low) and tmp; the machine
/// goes in Caches/Mac and is excluded from backup.
enum Storage {
    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("atv-macos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let machine: URL = {
        var dir = root.appendingPathComponent("Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
    /// Free space on the app's volume (tvOS has no "important usage" capacity query).
    static var freeBytes: Int64 {
        var s = statfs()
        guard statfs(root.path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }
}
