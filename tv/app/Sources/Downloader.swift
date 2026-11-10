// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: a 16 GB download that survives Wi-Fi drops. Streams straight into
// the destination file and resumes with a Range request after any error, so no
// second copy of the image is ever needed on the Apple TV's storage.
import Foundation

final class Downloader: NSObject, URLSessionDataDelegate {
    private let url: URL, dest: URL, expected: Int64
    private let progress: (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)
    private var lastReport = Date.distantPast

    init(url: URL, to dest: URL, expected: Int64, progress: @escaping (Int64, Int64) -> Void) {
        self.url = url; self.dest = dest; self.expected = expected; self.progress = progress
    }

    func run() throws {
        if !FileManager.default.fileExists(atPath: dest.path) { FileManager.default.createFile(atPath: dest.path, contents: nil) }
        var attempts = 0
        while true {
            written = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            if written >= expected { return }
            handle = try FileHandle(forWritingTo: dest)
            try handle?.seekToEnd()
            failure = nil
            var request = URLRequest(url: url)
            if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session.dataTask(with: request).resume()
            done.wait()
            session.finishTasksAndInvalidate()
            try? handle?.close()
            if failure == nil, written >= expected { progress(written, expected); return }
            attempts += 1
            Log.line("download", "interrupted at \(written >> 20) MB (\(failure?.localizedDescription ?? "short")); retry \(attempts)")
            if attempts > 50 { throw failure ?? HostError("The download kept failing.") }
            Thread.sleep(forTimeInterval: min(Double(attempts) * 2, 30))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if written > 0 && code == 200 {
            // The server ignored the Range: start over rather than append a second copy.
            try? handle?.truncate(atOffset: 0)
            written = 0
        }
        guard code == 200 || code == 206 else {
            failure = HostError("HTTP \(code) from \(url.host ?? "server")")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        written += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 1 {
            lastReport = Date()
            progress(written, expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = error }
        done.signal()
    }
}

enum LAN {
    /// IPv4 addresses on Wi-Fi/Ethernet, for "connect your VNC viewer to ...".
    static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}
