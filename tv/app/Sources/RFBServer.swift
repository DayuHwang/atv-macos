// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: the virtual Mac's screen, keyboard and mouse over VNC (RFB 3.3–3.8),
// served by the tvOS app itself rather than by macOS. So it works from the very
// first boot (Setup Assistant), shows install progress before the Mac exists,
// and needs no network inside the guest.
//
// Encodings: ZRLE (zlib, raw tiles) when the viewer offers it, otherwise Raw.
// Updates: 64x64 tiles diffed against what each viewer last received.
// Security: VNC password when the PC side launches us with ATV_VNC_PASSWORD,
// otherwise none (LAN only; logged as a warning).
import CommonCrypto
import CoreGraphics
import CoreText
import Foundation
import Network

final class RFBServer {
    static let shared = RFBServer()
    static let port: UInt16 = 5900
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "atv.rfb.accept")
    private var sessions: [ObjectIdentifier: RFBSession] = [:]
    let password = ProcessInfo.processInfo.environment["ATV_VNC_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }

    func start(width: Int, height: Int) {
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: "atv-macos", type: "_rfb._tcp")
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                let s = RFBSession(conn, width: width, height: height, password: self.password) { [weak self] s in
                    self?.queue.async { self?.sessions[ObjectIdentifier(s)] = nil }
                }
                self.queue.async { self.sessions[ObjectIdentifier(s)] = s }
                s.start()
            }
            l.stateUpdateHandler = { state in Log.line("vnc", "listener \(state)") }
            l.start(queue: queue)
            listener = l
            Log.line("vnc", "serving on port \(Self.port), \(password == nil ? "NO PASSWORD (LAN only)" : "password set by the PC")")
        } catch {
            Log.line("vnc", "cannot listen on \(Self.port): \(error)")
        }
    }
}

// MARK: - Pixel formats

struct PixelFormat: Equatable {
    var bpp: UInt8 = 32, depth: UInt8 = 24, bigEndian = false, trueColor = true
    var rMax: UInt16 = 255, gMax: UInt16 = 255, bMax: UInt16 = 255
    var rShift: UInt8 = 16, gShift: UInt8 = 8, bShift: UInt8 = 0
    static let native = PixelFormat()

    var bytes: [UInt8] {
        [bpp, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0,
         UInt8(rMax >> 8), UInt8(rMax & 0xFF), UInt8(gMax >> 8), UInt8(gMax & 0xFF), UInt8(bMax >> 8), UInt8(bMax & 0xFF),
         rShift, gShift, bShift, 0, 0, 0]
    }
    init() {}
    init(_ d: ArraySlice<UInt8>) {
        let b = Array(d)
        bpp = b[0]; depth = b[1]; bigEndian = b[2] != 0; trueColor = b[3] != 0
        rMax = UInt16(b[4]) << 8 | UInt16(b[5]); gMax = UInt16(b[6]) << 8 | UInt16(b[7]); bMax = UInt16(b[8]) << 8 | UInt16(b[9])
        rShift = b[10]; gShift = b[11]; bShift = b[12]
    }
}

/// Converts BGRA canvas pixels to a viewer's pixel format.
struct PixelPacker {
    let pf: PixelFormat
    private let rT: [UInt32], gT: [UInt32], bT: [UInt32]
    let isNative: Bool
    /// ZRLE's 3-byte CPIXEL applies, and whether it holds the low or the high three bytes.
    let cpixel3: Bool, cpixelHigh: Bool

    init(_ pf: PixelFormat) {
        self.pf = pf
        func table(_ max: UInt16, _ shift: UInt8) -> [UInt32] {
            // Swift's << binds tighter than * and /, so the scaling needs its own parentheses.
            (0..<256).map { ((UInt32($0) * UInt32(max) + 127) / 255) << UInt32(shift) }
        }
        rT = table(pf.rMax, pf.rShift); gT = table(pf.gMax, pf.gShift); bT = table(pf.bMax, pf.bShift)
        isNative = pf == .native
        let all = (UInt32(pf.rMax) << UInt32(pf.rShift)) | (UInt32(pf.gMax) << UInt32(pf.gShift)) | (UInt32(pf.bMax) << UInt32(pf.bShift))
        let fitsLow = all < (1 << 24), fitsHigh = all & 0xFF == 0
        cpixel3 = pf.trueColor && pf.bpp == 32 && pf.depth <= 24 && (fitsLow || fitsHigh)
        cpixelHigh = !fitsLow && fitsHigh
    }

    @inline(__always) func value(_ p: UnsafePointer<UInt8>) -> UInt32 { bT[Int(p[0])] | gT[Int(p[1])] | rT[Int(p[2])] }

    /// Raw pixels of a rectangle of the canvas (stride in bytes).
    func pack(_ canvas: UnsafePointer<UInt8>, stride: Int, x: Int, y: Int, w: Int, h: Int, into out: inout [UInt8]) {
        if isNative {
            for row in y..<y + h { out.append(contentsOf: UnsafeBufferPointer(start: canvas + row * stride + x * 4, count: w * 4)) }
            return
        }
        let n = Int(pf.bpp) / 8
        for row in y..<y + h {
            var p = canvas + row * stride + x * 4
            for _ in 0..<w {
                append(value(p), bytes: n, to: &out)
                p += 4
            }
        }
    }

    /// One ZRLE CPIXEL.
    @inline(__always) func appendCPixel(_ p: UnsafePointer<UInt8>, to out: inout [UInt8]) {
        let v = value(p)
        if cpixel3 {
            let t = cpixelHigh ? v >> 8 : v & 0xFF_FFFF
            if pf.bigEndian { out.append(UInt8(t >> 16)); out.append(UInt8(t >> 8 & 0xFF)); out.append(UInt8(t & 0xFF)) }
            else { out.append(UInt8(t & 0xFF)); out.append(UInt8(t >> 8 & 0xFF)); out.append(UInt8(t >> 16)) }
        } else {
            append(v, bytes: Int(pf.bpp) / 8, to: &out)
        }
    }

    @inline(__always) private func append(_ v: UInt32, bytes n: Int, to out: inout [UInt8]) {
        if pf.bigEndian { for i in stride(from: n - 1, through: 0, by: -1) { out.append(UInt8(v >> UInt32(8 * i) & 0xFF)) } }
        else { for i in 0..<n { out.append(UInt8(v >> UInt32(8 * i) & 0xFF)) } }
    }
}

// MARK: - What the screen shows

enum ScreenSource {
    /// Fills a BGRA canvas: the Mac's display when it has one, its boot screen
    /// before that, and our own status card before the Mac starts.
    static func capture(into canvas: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        if henge_vm_state() == 1 {
            if henge_vm_gpu_frames() > 0, henge_vm_snapshot(canvas, Int32(width), Int32(height)) == 0 {
                drawPointer(into: canvas, width: width, height: height)
                return
            }
            var px: UnsafePointer<UInt8>?, w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
            if henge_vm_boot_display(&px, &w, &h, &stride) == 0, let px, w > 0, h > 0 {
                fit(px, Int(w), Int(h), Int(stride), into: canvas, width, height)
                return
            }
        }
        drawStatus(into: canvas, width: width, height: height)
    }

    /// The engine's snapshot is the desktop without the hardware cursor (the GPU
    /// draws that as a separate plane), so viewers would see no pointer at all.
    /// Paint an arrow where the guest says its pointer is: B black, W white.
    private static let arrow: [[UInt8]] = [
        "W           ",
        "WW          ",
        "WBW         ",
        "WBBW        ",
        "WBBBW       ",
        "WBBBBW      ",
        "WBBBBBW     ",
        "WBBBBBBW    ",
        "WBBBBBBBW   ",
        "WBBBBBBBBW  ",
        "WBBBBBBBBBW ",
        "WBBBBBBWWWWW",
        "WBBBWBBW    ",
        "WBBWWBBW    ",
        "WBW  WBBW   ",
        "WW   WBBW   ",
        "W     WBBW  ",
        "      WBBW  ",
        "       WW   ",
    ].map { Array($0.utf8) }

    private static func drawPointer(into canvas: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        var gx: Int32 = 0, gy: Int32 = 0
        guard henge_vm_pointer(&gx, &gy) == 0 else { return }
        let scale = max(1.0, Double(height) / 720.0)
        let rows = arrow.count, cols = arrow[0].count
        for oy in 0..<Int(Double(rows) * scale) {
            let py = Int(gy) + oy
            guard py >= 0, py < height else { continue }
            let row = arrow[min(rows - 1, Int(Double(oy) / scale))]
            for ox in 0..<Int(Double(cols) * scale) {
                let px = Int(gx) + ox
                guard px >= 0, px < width else { continue }
                let c = row[min(cols - 1, Int(Double(ox) / scale))]
                guard c != UInt8(ascii: " ") else { continue }
                let v: UInt8 = c == UInt8(ascii: "B") ? 0 : 255
                let p = canvas + (py * width + px) * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
    }

    /// Nearest-pixel scale of the boot framebuffer into the canvas, letterboxed.
    private static func fit(_ src: UnsafePointer<UInt8>, _ sw: Int, _ sh: Int, _ sstride: Int,
                            into dst: UnsafeMutablePointer<UInt8>, _ dw: Int, _ dh: Int) {
        let scale = min(Double(dw) / Double(sw), Double(dh) / Double(sh))
        let ow = Int(Double(sw) * scale), oh = Int(Double(sh) * scale)
        let ox = (dw - ow) / 2, oy = (dh - oh) / 2
        memset(dst, 0, dw * dh * 4)
        for y in 0..<oh {
            let sy = min(sh - 1, Int(Double(y) / scale))
            let srow = src + sy * sstride
            let drow = dst + ((oy + y) * dw + ox) * 4
            for x in 0..<ow {
                let sx = min(sw - 1, Int(Double(x) / scale))
                (drow + x * 4).update(from: srow + sx * 4, count: 4)
                drow[x * 4 + 3] = 255
            }
        }
    }

    private static var lastStatusDraw = Date.distantPast
    private static var statusCache: [UInt8] = []

    /// A plain status card: what the host is doing, its progress, where to connect.
    private static func drawStatus(into canvas: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        if Date().timeIntervalSince(lastStatusDraw) < 1, statusCache.count == width * height * 4 {
            statusCache.withUnsafeBufferPointer { canvas.update(from: $0.baseAddress!, count: $0.count) }
            return
        }
        lastStatusDraw = Date()
        let s = Host.shared.status
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: canvas, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let u = CGFloat(height) / 1080
        func text(_ str: String, _ size: CGFloat, _ y: CGFloat, _ gray: CGFloat = 1) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size * u, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
            ctx.textPosition = CGPoint(x: 120 * u, y: CGFloat(height) - y * u)
            CTLineDraw(line, ctx)
        }
        text("atv-macos", 64, 220)
        text(Self.phaseTitle(s.phase), 44, 330, 0.92)
        text(s.detail, 30, 390, 0.7)
        if let p = s.progress {
            let w = CGFloat(width) - 240 * u
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(CGRect(x: 120 * u, y: CGFloat(height) - 470 * u, width: w, height: 14 * u))
            ctx.setFillColor(CGColor(red: 0.35, green: 0.62, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 120 * u, y: CGFloat(height) - 470 * u, width: w * CGFloat(min(max(p, 0), 1)), height: 14 * u))
            text(String(format: "%.1f%%", p * 100), 26, 520, 0.7)
        }
        let addr = s.addresses.first.map { "\($0):\(RFBServer.port)" } ?? "no network address yet"
        text("VNC  \(addr)    status  http://\(s.addresses.first ?? "?"):\(StatusServer.port)", 26, CGFloat(height) / u - 110, 0.55)
        text(String(format: "free storage %.1f GB", s.freeGB), 26, CGFloat(height) / u - 70, 0.55)
        statusCache = Array(UnsafeBufferPointer(start: canvas, count: width * height * 4))
    }

    static func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "waiting-for-jit": return "Waiting for JIT from the PC"
        case "downloading": return "Downloading macOS"
        case "installing": return "Installing macOS"
        case "booting": return "Starting the Mac"
        case "running": return "Running"
        case "stopped": return "Stopped"
        case "failed": return "Something went wrong"
        default: return "Starting"
        }
    }
}

// MARK: - The guest's pointer

/// VNC pointers are absolute; the virtual Mac's mouse is relative, macOS
/// accelerates it, and the emulated guest reports where its pointer is only
/// some time after each move. So the pointer is walked to each position in
/// small steps, the next step sent once the guest has shown the last one (or
/// after a short wait), as Henge's own autopilot does. Button and wheel
/// changes wait until the pointer has arrived, so clicks land where the
/// viewer clicked. Moves that arrive while walking only update the target.
final class Pointer {
    static let shared = Pointer()
    private let queue = DispatchQueue(label: "atv.pointer")
    private struct Event { var x: Int, y: Int, mask: UInt8 }
    private var pending: [Event] = []
    private var mask: UInt8 = 0
    private var estimate = (x: 0, y: 0)           // dead reckoning while the guest reports nothing
    private var lastStep: (at: (x: Int, y: Int), time: DispatchTime)? = nil
    private var eventStart = DispatchTime.now()
    private var holdUntil = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var knownLogged: Bool? = nil

    static let maxStep = 24          // before macOS acceleration
    static let arrived = 2           // pixels
    static let guestWait = 0.15      // seconds to wait for the guest to show a step
    static let giveUp = 3.0          // seconds per event before buttons are applied anyway

    /// Where the guest says its pointer is, for /status.
    var position: (x: Int, y: Int)? {
        var x: Int32 = 0, y: Int32 = 0
        return henge_vm_pointer(&x, &y) == 0 ? (Int(x), Int(y)) : nil
    }

    func update(mask newMask: UInt8, x: Int, y: Int) {
        queue.async { [self] in
            // A pure move (same buttons as before it) is replaced by a newer one; a button
            // change keeps its own position, so the click lands where it was made.
            let before = pending.count >= 2 ? pending[pending.count - 2].mask : mask
            if let last = pending.last, last.mask == newMask, last.mask == before {
                pending[pending.count - 1] = Event(x: x, y: y, mask: newMask)
            } else {
                if pending.isEmpty { eventStart = .now() }
                pending.append(Event(x: x, y: y, mask: newMask))
            }
            startTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(12))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func seconds(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1e9
    }

    private func tick() {
        guard let ev = pending.first else { timer?.cancel(); timer = nil; return }
        guard DispatchTime.now() >= holdUntil else { return }
        var gx: Int32 = 0, gy: Int32 = 0
        let known = henge_vm_pointer(&gx, &gy) == 0
        if knownLogged != known {
            knownLogged = known
            Log.line("vnc", known ? "guest reports its pointer: closed-loop pointing" : "guest pointer unknown: dead reckoning")
        }
        let at = known ? (x: Int(gx), y: Int(gy)) : estimate
        let ex = ev.x - at.x, ey = ev.y - at.y
        if (abs(ex) <= Self.arrived && abs(ey) <= Self.arrived) || seconds(since: eventStart) > Self.giveUp {
            applyButtons(ev.mask)
            pending.removeFirst()
            eventStart = .now()
            lastStep = nil
            return
        }
        if known, let last = lastStep, last.at == at, seconds(since: last.time) < Self.guestWait {
            return   // the guest has not shown the last step yet
        }
        let sx = step(ex), sy = step(ey)
        henge_vm_mouse_move(Int32(sx), Int32(sy))
        lastStep = (at, .now())
        estimate = (min(max(at.x + sx, 0), 4095), min(max(at.y + sy, 0), 4095))
    }

    /// Big errors get full steps; small ones a bit less than the error, as macOS
    /// still accelerates slow moves a little.
    private func step(_ e: Int) -> Int {
        guard e != 0 else { return 0 }
        let size = abs(e) > Self.maxStep ? Self.maxStep : max(1, abs(e) * 2 / 3)
        return e > 0 ? size : -size
    }

    private func applyButtons(_ newMask: UInt8) {
        guard newMask != mask else { return }
        // buttons: VNC bit 0 left, 1 middle, 2 right -> engine 0 left, 2 middle, 1 right
        for (bit, button) in [(0, 0), (1, 2), (2, 1)] as [(UInt8, Int32)] {
            let was = mask & (1 << bit) != 0, now = newMask & (1 << bit) != 0
            if was != now { henge_vm_mouse_button(button, now ? 1 : 0) }
        }
        // wheel: bits 3 up, 4 down, 5 left, 6 right; one step per press
        for (bit, dx, dy) in [(3, 0, 1), (4, 0, -1), (5, -1, 0), (6, 1, 0)] as [(UInt8, Int32, Int32)] {
            if newMask & (1 << bit) != 0, mask & (1 << bit) == 0 { henge_vm_mouse_scroll(dx, dy) }
        }
        mask = newMask
        holdUntil = .now() + .milliseconds(60)   // let the guest see a press before the release
    }
}

// MARK: - One viewer

final class RFBSession {
    private enum Stage { case version, security, auth, clientInit, normal }
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "atv.rfb.session")
    private let width: Int, height: Int
    private let password: String?
    private let onClose: (RFBSession) -> Void
    private var stage = Stage.version
    private var minor = 8
    private var input = Data()
    private var challenge = [UInt8]()
    private var packer = PixelPacker(.native)
    private var useZRLE = false
    /// zlib keeps a pointer back to its z_stream, so it lives at one fixed address.
    private var zstream: UnsafeMutablePointer<z_stream>?
    private var current: [UInt8], sent: [UInt8]
    private var haveSent = false
    private var wantFull = false, wantIncremental = false, sending = false
    private var lastCapture = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var closed = false

    init(_ conn: NWConnection, width: Int, height: Int, password: String?, onClose: @escaping (RFBSession) -> Void) {
        self.conn = conn; self.width = width; self.height = height; self.password = password; self.onClose = onClose
        current = [UInt8](repeating: 0, count: width * height * 4)
        sent = current
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
        Log.line("vnc", "viewer connected from \(conn.endpoint)")
        send(Data("RFB 003.008\n".utf8))
        receive()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        if let z = zstream { deflateEnd(z); z.deinitialize(count: 1); z.deallocate(); zstream = nil }
        conn.cancel()
        Log.line("vnc", "viewer disconnected")
        onClose(self)
    }

    private func send(_ data: Data, then: (() -> Void)? = nil) {
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close(); return }
            then?()
        })
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.input.append(data); self.process() }
            if done || error != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    // MARK: protocol

    private func take(_ n: Int) -> [UInt8]? {
        guard input.count >= n else { return nil }
        let out = [UInt8](input.prefix(n))
        input.removeFirst(n)
        return out
    }
    private func peek(_ n: Int) -> [UInt8]? { input.count >= n ? [UInt8](input.prefix(n)) : nil }

    private func process() {
        while !closed {
            switch stage {
            case .version:
                guard let v = take(12) else { return }
                minor = Int(String(decoding: v[8..<11], as: UTF8.self)) ?? 3
                minor = minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
                let type: UInt8 = password == nil ? 1 : 2
                if minor == 3 {
                    send(Data([0, 0, 0, type]))
                    if type == 2 { sendChallenge() } else { stage = .clientInit }
                } else {
                    send(Data([1, type]))
                    stage = .security
                }
            case .security:
                guard let t = take(1) else { return }
                if t[0] == 2, password != nil { sendChallenge() }
                else if t[0] == 1, password == nil {
                    if minor == 8 { send(Data([0, 0, 0, 0])) }
                    stage = .clientInit
                } else { close(); return }
            case .auth:
                guard let r = take(16) else { return }
                if r == vncResponse(challenge, password ?? "") {
                    send(Data([0, 0, 0, 0]))
                    stage = .clientInit
                } else {
                    Log.line("vnc", "wrong VNC password from \(conn.endpoint)")
                    var fail = Data([0, 0, 0, 1])
                    if minor == 8 { let m = Data("Wrong password".utf8); fail.append(contentsOf: be32(m.count)); fail.append(m) }
                    send(fail) { [weak self] in self?.close() }
                    return
                }
            case .clientInit:
                guard take(1) != nil else { return }
                var d = Data(be16(width) + be16(height) + PixelFormat.native.bytes)
                let name = Data("atv-macos".utf8)
                d.append(contentsOf: be32(name.count)); d.append(name)
                send(d)
                stage = .normal
                startTimer()
            case .normal:
                guard let head = peek(1) else { return }
                switch head[0] {
                case 0:   // SetPixelFormat
                    guard let m = take(20) else { return }
                    let pf = PixelFormat(m[4..<20])
                    if pf.trueColor, [8, 16, 32].contains(pf.bpp) { packer = PixelPacker(pf) }
                    else { Log.line("vnc", "viewer asked for a colour-map format; keeping true colour") }
                    haveSent = false   // a new format needs a full picture
                case 2:   // SetEncodings
                    guard let h = peek(4) else { return }
                    let n = Int(h[2]) << 8 | Int(h[3])
                    guard let m = take(4 + 4 * n) else { return }
                    let encs = (0..<n).map { i in Int32(bitPattern: UInt32(m[4 + 4 * i]) << 24 | UInt32(m[5 + 4 * i]) << 16 | UInt32(m[6 + 4 * i]) << 8 | UInt32(m[7 + 4 * i])) }
                    useZRLE = encs.contains(16)
                    Log.line("vnc", "encodings \(encs.filter { $0 >= 0 }) -> \(useZRLE ? "ZRLE" : "Raw")")
                case 3:   // FramebufferUpdateRequest
                    guard let m = take(10) else { return }
                    if m[1] == 0 || !haveSent { wantFull = true } else { wantIncremental = true }
                case 4:   // KeyEvent
                    guard let m = take(8) else { return }
                    let sym = UInt32(m[4]) << 24 | UInt32(m[5]) << 16 | UInt32(m[6]) << 8 | UInt32(m[7])
                    if let usage = Keysyms.hid(sym) { henge_vm_key_hid(usage, m[1] != 0 ? 1 : 0) }
                case 5:   // PointerEvent
                    guard let m = take(6) else { return }
                    let x = Int(m[2]) << 8 | Int(m[3]), y = Int(m[4]) << 8 | Int(m[5])
                    Pointer.shared.update(mask: m[1], x: min(x, width - 1), y: min(y, height - 1))
                case 6:   // ClientCutText: not passed on yet
                    guard let h = peek(8) else { return }
                    let n = Int(h[4]) << 24 | Int(h[5]) << 16 | Int(h[6]) << 8 | Int(h[7])
                    guard take(8 + n) != nil else { return }
                default:
                    Log.line("vnc", "unknown message \(head[0]); closing")
                    close(); return
                }
            }
        }
    }

    private func sendChallenge() {
        challenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
        send(Data(challenge))
        stage = .auth
    }

    /// VNC authentication: the challenge DES-encrypted with the password, each key byte bit-reversed.
    private func vncResponse(_ challenge: [UInt8], _ password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in password.utf8.prefix(8).enumerated() {
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << bit) != 0 { r |= 0x80 >> bit }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                key, kCCKeySizeDES, nil, challenge, 16, &out, 16, &moved)
        return out
    }

    // MARK: updates

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !closed, !sending, wantFull || wantIncremental else { return }
        guard Date().timeIntervalSince(lastCapture) >= 0.066 else { return }   // at most ~15 frames a second
        lastCapture = Date()
        current.withUnsafeMutableBufferPointer { ScreenSource.capture(into: $0.baseAddress!, width: width, height: height) }
        var rects: [(x: Int, y: Int, w: Int, h: Int)]
        if wantFull || !haveSent {
            rects = [(0, 0, width, height)]
        } else {
            rects = dirtyRects()
            if rects.isEmpty { return }   // nothing new: the request stays open
        }
        wantFull = false; wantIncremental = false
        var msg = Data([0, 0] + be16(rects.count))
        current.withUnsafeBufferPointer { cur in
            for r in rects {
                msg.append(contentsOf: be16(r.x) + be16(r.y) + be16(r.w) + be16(r.h))
                if useZRLE, let z = zrle(cur.baseAddress!, r) {
                    msg.append(contentsOf: be32(16))
                    msg.append(contentsOf: be32(z.count)); msg.append(contentsOf: z)
                } else {
                    msg.append(contentsOf: be32(0))
                    var raw = [UInt8](); raw.reserveCapacity(r.w * r.h * Int(packer.pf.bpp) / 8)
                    packer.pack(cur.baseAddress!, stride: width * 4, x: r.x, y: r.y, w: r.w, h: r.h, into: &raw)
                    msg.append(contentsOf: raw)
                }
            }
        }
        swap(&current, &sent)
        sent.withUnsafeBufferPointer { s in current.withUnsafeMutableBufferPointer { c in c.baseAddress!.update(from: s.baseAddress!, count: s.count) } }
        haveSent = true
        sending = true
        send(msg) { [weak self] in self?.queue.async { self?.sending = false } }
    }

    /// Changed 64x64 tiles, merged along each row of tiles.
    private func dirtyRects() -> [(x: Int, y: Int, w: Int, h: Int)] {
        let T = 64
        var out: [(x: Int, y: Int, w: Int, h: Int)] = []
        current.withUnsafeBufferPointer { cur in
            sent.withUnsafeBufferPointer { old in
                for ty in stride(from: 0, to: height, by: T) {
                    let th = min(T, height - ty)
                    var run: (x: Int, w: Int)? = nil
                    for tx in stride(from: 0, to: width, by: T) {
                        let tw = min(T, width - tx)
                        var changed = false
                        for y in ty..<ty + th where !changed {
                            let o = (y * width + tx) * 4
                            changed = memcmp(cur.baseAddress! + o, old.baseAddress! + o, tw * 4) != 0
                        }
                        if changed {
                            if let r = run { run = (r.x, tx + tw - r.x) } else { run = (tx, tw) }
                        } else if let r = run {
                            out.append((r.x, ty, r.w, th)); run = nil
                        }
                    }
                    if let r = run { out.append((r.x, ty, r.w, th)) }
                }
            }
        }
        return out
    }

    /// ZRLE with raw tiles: the compression is all zlib's, kept in one stream per viewer.
    /// nil when zlib fails; the session then drops to Raw for good.
    private func zrle(_ canvas: UnsafePointer<UInt8>, _ r: (x: Int, y: Int, w: Int, h: Int)) -> [UInt8]? {
        var plain = [UInt8](); plain.reserveCapacity(r.w * r.h * 4 + 1024)
        for ty in stride(from: r.y, to: r.y + r.h, by: 64) {
            let th = min(64, r.y + r.h - ty)
            for tx in stride(from: r.x, to: r.x + r.w, by: 64) {
                let tw = min(64, r.x + r.w - tx)
                plain.append(0)   // subencoding: raw CPIXELs
                for y in ty..<ty + th {
                    var p = canvas + (y * width + tx) * 4
                    for _ in 0..<tw { packer.appendCPixel(p, to: &plain); p += 4 }
                }
            }
        }
        if zstream == nil {
            let z = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            z.initialize(to: z_stream())
            if deflateInit_(z, 1, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) != Z_OK {
                z.deinitialize(count: 1); z.deallocate()
                Log.line("vnc", "zlib init failed; using Raw")
                useZRLE = false
                return nil
            }
            zstream = z
        }
        let z = zstream!
        var out = [UInt8](); out.reserveCapacity(plain.count / 2 + 1024)
        var chunk = [UInt8](repeating: 0, count: 1 << 18)
        var failed: Int32? = nil
        plain.withUnsafeMutableBufferPointer { inp in
            z.pointee.next_in = inp.baseAddress
            z.pointee.avail_in = uInt(inp.count)
            chunk.withUnsafeMutableBufferPointer { o in
                repeat {
                    z.pointee.next_out = o.baseAddress
                    z.pointee.avail_out = uInt(o.count)
                    let rc = deflate(z, Z_SYNC_FLUSH)
                    if rc != Z_OK && rc != Z_BUF_ERROR { failed = rc; break }
                    out.append(contentsOf: UnsafeBufferPointer(start: o.baseAddress, count: o.count - Int(z.pointee.avail_out)))
                } while z.pointee.avail_out == 0
            }
            z.pointee.next_in = nil
        }
        if let rc = failed {
            Log.line("vnc", "zlib deflate failed (\(rc)); using Raw")
            useZRLE = false
            return nil
        }
        return out
    }
}

@inline(__always) private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
@inline(__always) private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
