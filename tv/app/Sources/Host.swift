// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: the unattended life of the virtual Mac on an Apple TV.
//
//   wait for JIT  ->  (first run) download macOS, install it  ->  boot  ->  run
//
// Nobody is in front of the TV, so every step proceeds on its own and reports
// through `Host.status`, which the VNC screen and the status page both show.
// One machine start per launch (the engine's rule): after installing, the app
// exits and the Windows side's keeper relaunches it with JIT for the first boot.
import Foundation
import UIKit

struct HostStatus: Codable {
    var phase = "starting"        // starting, waiting-for-jit, downloading, installing, booting, running, stopped, failed
    var detail = ""
    var progress: Double? = nil   // 0...1 when the phase has one
    var installed = false
    var guestRAMMB: UInt64 = 0
    var cpusOn: Int32 = 0
    var gpuFrames: UInt64 = 0
    var freeGB: Double = 0
    var addresses: [String] = []
    /// The VNC server's ZRLE works (older builds sent empty ZRLE rectangles,
    /// so the PC side strips ZRLE from what the viewer offers when this is missing).
    var vncZRLE = true
    /// 2: ZRLE and non-native pixel formats keep all three colours (v7); the PC
    /// relays older builds through Raw in the app's own format.
    var vncRev = 2
    /// Where the guest says its pointer is (display pixels), when it says.
    var pointer: [Int]? = nil
    /// The Apple TV's memory and paging, refreshed with the [memory] log line.
    var memory = ""
}

struct MachineConfig: Codable {
    var ecid: UInt64
    var seed: UInt64 = 0
    var ramMB: UInt64 = 4096
    var cpus: Int32 = 4
    var width: UInt32 = 1920
    var height: UInt32 = 1080
    var installed = false
    var release = Release.recommended.id
}

/// The macOS restore image to install. Sequoia 15.6.1 is the build the engine is tested with.
struct Release {
    let id: String, name: String, url: URL, bytes: Int64
    static let recommended = Release(
        id: "24G90", name: "macOS Sequoia 15.6.1",
        url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
        bytes: 16_035 << 20)
}

@_silgen_name("csops")
private func csops(_ pid: Int32, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

final class Host {
    static let shared = Host()

    private let lock = NSLock()
    private var _status = HostStatus()
    var status: HostStatus {
        lock.lock(); defer { lock.unlock() }
        var s = _status
        s.freeGB = Double(Storage.freeBytes) / Double(1 << 30)
        s.addresses = LAN.addresses()
        if henge_vm_state() == 1 {
            s.cpusOn = henge_vm_cpus_on()
            s.gpuFrames = henge_vm_gpu_frames()
            s.pointer = Pointer.shared.position.map { [$0.x, $0.y] }
        }
        return s
    }
    private func set(_ phase: String, _ detail: String = "", progress: Double? = nil) {
        lock.lock()
        _status.phase = phase; _status.detail = detail; _status.progress = progress
        lock.unlock()
        if progress == nil || Int((progress ?? 0) * 1000) % 50 == 0 { Log.line("host", "\(phase) \(detail)") }
    }

    private let configURL = Storage.machine.appendingPathComponent("machine.json")
    private var rom: URL { Storage.machine.appendingPathComponent("AVPBooter.vmapple2.bin") }
    private var disk: URL { Storage.machine.appendingPathComponent("disk.img") }
    private var aux: URL { Storage.machine.appendingPathComponent("auxiliary.bin") }
    private var ipsw: URL { Storage.root.appendingPathComponent("\(Release.recommended.id).ipsw") }

    /// JIT code cache. An Apple TV 4K has 4 GB of RAM in all and every page of
    /// this region is touched (made resident) when it is granted, so it is kept
    /// smaller than on an iPhone. Override with `jitMB` in UserDefaults.
    /// Tuning passed by the PC's keeper at launch (data/atv-macos.json there), so it can
    /// change without reinstalling: ATV_RAM_MB, ATV_CPUS, ATV_JIT_MB.
    private static func env(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0) }
    }

    /// JIT code cache. An Apple TV 4K has 4 GB of RAM in all and every page of this
    /// region is made resident when it is granted, so it is much smaller than on an iPhone.
    private var jitBytes: Int {
        let mb = Host.env("ATV_JIT_MB") ?? 256
        return max(128, mb) << 20
    }

    private let launched = DispatchSemaphore(value: 0)

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true   // the screensaver would suspend us
        henge_ios_jit_install_trap_handler()
        // The JIT grant remaps a large stretch of address space. Done while UIKit was still
        // loading its frameworks, an image lost its data segment (three crashes at launch, in
        // FrontBoardServices/UIKit init); so it waits until the app has finished launching.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: nil) { [weak self] _ in self?.launched.signal() }
        Thread.detachNewThread { [self] in
            Thread.current.name = "atv-host"
            do { try run() } catch {
                set("failed", error.localizedDescription)
                Log.line("host", "FAILED: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - The sequence

    private func run() throws {
        var config = loadConfig()
        lock.lock(); _status.installed = config.installed; lock.unlock()

        if launched.wait(timeout: .now() + 20) == .timedOut { Log.line("host", "no didBecomeActive after 20 s; going on") }
        Thread.sleep(forTimeInterval: 2)
        try waitForJIT()

        if !config.installed {
            try download()
            try install(&config)
            set("stopped", "macOS is installed. Relaunching for the first boot.")
            Log.line("host", "install finished; exiting so the next launch can start the machine (one start per launch)")
            Thread.sleep(forTimeInterval: 3)
            exit(0)
        }
        try boot(config)
        while henge_vm_state() == 1 { Thread.sleep(forTimeInterval: 1) }
        let reason = String(cString: henge_vm_exit_reason())
        set("stopped", "The Mac stopped (\(reason)).")
        Log.line("host", "machine stopped: \(reason); exiting so the keeper can relaunch")
        Thread.sleep(forTimeInterval: 3)
        exit(0)
    }

    private func waitForJIT() throws {
        set("waiting-for-jit", "Run atv-jit on the Windows PC to attach and grant JIT.")
        while !isDebuggerAttached() { Thread.sleep(forTimeInterval: 1) }
        Log.line("jit", "debugger attached; claiming \(jitBytes >> 20) MiB of JIT memory")
        henge_ios_jit_log_footprint("before-jit")
        guard henge_ios_jit_prewarm(jitBytes) else {
            throw HostError("The debugger attached but did not grant JIT memory. Check the atv-jit window on the PC.")
        }
        henge_ios_jit_detach()   // tells the PC side it can let go
        henge_ios_jit_log_footprint("after-jit")
        Log.line("jit", "JIT ready")
    }

    private func isDebuggerAttached() -> Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x10000000 /* CS_DEBUGGED */ != 0
    }

    // MARK: - First run: download and install

    private func download() throws {
        let release = Release.recommended
        let have = (try? FileManager.default.attributesOfItem(atPath: ipsw.path)[.size] as? Int64) ?? 0
        if have == release.bytes { return }
        let needed = release.bytes - have + (24 << 30)
        guard Storage.freeBytes > needed else {
            throw HostError(String(format: "Not enough storage: %.1f GB free, %.1f GB needed for the download and the new Mac.",
                                   Double(Storage.freeBytes) / Double(1 << 30), Double(needed) / Double(1 << 30)))
        }
        try Downloader(url: release.url, to: ipsw, expected: release.bytes) { done, total in
            self.set("downloading", "\(release.name): \(done >> 20) of \(total >> 20) MB",
                     progress: total > 0 ? Double(done) / Double(total) : nil)
        }.run()
    }

    private func install(_ config: inout MachineConfig) throws {
        set("installing", "Fetching the virtual Mac's boot ROM from Apple")
        if !FileManager.default.fileExists(atPath: rom.path) {
            // Henge's BootROM.file() caches in Application Support, which tvOS apps may not
            // write; download() returns the verified ROM and we keep it beside the disk.
            try BootROM.syncDownload().write(to: rom, options: .atomic)
        }

        set("installing", "Creating a 64 GB disk (sparse) and the auxiliary storage")
        try? FileManager.default.removeItem(at: disk)
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let h = try FileHandle(forWritingTo: disk)
        try h.truncate(atOffset: UInt64(64) << 30)
        try h.close()
        try? FileManager.default.removeItem(at: aux)
        guard henge_make_aux(aux.path) == 0 else { throw HostError("Cannot create the auxiliary storage.") }

        // The restore system fills whatever memory it gets with cache; 2 GB is what it needs.
        let ram = guestMemory(asked: 2048, mode: "file")
        setenv("HV_WRITE_CACHE", "0", 1)
        let work = Storage.machine.appendingPathComponent("restore", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var err = [CChar](repeating: 0, count: 512)
        Log.line("install", "ECID \(config.ecid), restore RAM \(ram) MB, \(config.cpus) CPUs")
        guard henge_vm_install(rom.path, disk.path, aux.path, config.ecid, ipsw.path, work.path, ram, config.cpus,
                               &err, err.count) == 0 else {
            throw HostError("The installer did not start: \(String(cString: err))")
        }
        while true {
            Thread.sleep(forTimeInterval: 1)
            let step = Int(henge_install_step())
            set("installing", Host.stepName(step), progress: henge_install_progress())
            if step == 100 { break }
            if step == 101 { throw HostError("The restore failed; the log says why.") }
            if henge_vm_state() == 2 {
                // The restore ends with the machine restarting; give idevicerestore time to finish.
                for _ in 0..<90 where henge_install_step() < 100 { Thread.sleep(forTimeInterval: 1) }
                if henge_install_step() == 100 { break }
                throw HostError("The machine stopped during the restore (\(String(cString: henge_vm_exit_reason()))).")
            }
        }
        if henge_vm_state() == 1 { henge_vm_stop() }
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: ipsw)   // 16 GB back
        config.installed = true
        saveConfig(config)
        lock.lock(); _status.installed = true; lock.unlock()
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "Waiting for the Mac to enter DFU mode"
        case 1: return "Preparing the restore"
        case 2: return "Writing the system image"
        case 3: return "Verifying"
        case 4: return "Installing firmware"
        case 6: return "Updating firmware"
        case 7: return "Personalizing boot images"
        case 100: return "Done"
        case 101: return "Failed"
        default: return "Step \(step)"
        }
    }

    // MARK: - Boot

    private func boot(_ config: MachineConfig) throws {
        set("booting", "Starting the Mac")
        let ram = guestMemory(asked: UInt64(Host.env("ATV_RAM_MB") ?? 2048),
                              mode: ProcessInfo.processInfo.environment["ATV_RAM_MODE"] ?? "anon")
        let cpus = Int32(min(6, max(1, Host.env("ATV_CPUS") ?? Int(config.cpus))))
        henge_vm_set_display(config.width, config.height)
        henge_vm_set_display_mm(0, 0)
        var err = [CChar](repeating: 0, count: 512)
        guard henge_vm_boot(rom.path, disk.path, aux.path, config.ecid, config.seed, ram, cpus, &err, err.count) == 0 else {
            throw HostError("The Mac did not start: \(String(cString: err))")
        }
        lock.lock(); _status.guestRAMMB = ram; lock.unlock()
        set("running", "\(ram) MB, \(cpus) CPUs, \(config.width)x\(config.height)")
        HostMemory.startLogging(every: Host.env("ATV_MEMLOG") ?? 30) { [weak self] line in
            guard let self else { return }
            self.lock.lock(); self._status.memory = line; self.lock.unlock()
        }
    }

    /// Guest RAM, by ATV_RAM_MODE (the PC side sets it; no reinstall to change it):
    /// - "anon" (default): Henge's anonymous memory kept off the app's footprint ledger.
    ///   Fast; under pressure tvOS compresses it. At 4 GB of guest RAM the compressor
    ///   filled and the system killed us (vm-compressor-space-shortage); 2 GB leaves room.
    ///   If the kernel refuses it, the file below is used instead.
    /// - "file": a MAP_SHARED file the kernel can write out and drop. Survives more memory
    ///   pressure, but every first touch and every page brought back is flash I/O: with
    ///   3 GB the guest ran about 20 thousand blocks a second.
    /// - "file-prefault": the file, with a background thread touching every page early.
    private func guestMemory(asked: UInt64, mode: String) -> UInt64 {
        setenv("HV_RAM_FILE", Storage.machine.appendingPathComponent("ram.tmp").path, 1)
        if mode == "anon" { unsetenv("HV_RAM_NO_LEDGER") } else { setenv("HV_RAM_NO_LEDGER", "1", 1) }
        if mode == "file-prefault" { unsetenv("HV_RAM_NO_PREFAULT") } else { setenv("HV_RAM_NO_PREFAULT", "1", 1) }
        let free = Storage.freeBytes
        let room = free > (2 << 30) ? UInt64(free - (2 << 30)) >> 20 : 0
        let reach = henge_largest_mapping_mb()
        let ram = min(asked, room, reach > 512 ? reach - 512 : 0) / 512 * 512
        Log.line("memory", "guest RAM \(ram) MB, mode \(mode) (asked \(asked), storage room \(room), largest mapping \(reach), "
                 + "available before jetsam \(henge_available_memory() >> 20) MB)")
        return ram
    }

    // MARK: - Config

    private func loadConfig() -> MachineConfig {
        if let data = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(MachineConfig.self, from: data) {
            return c
        }
        let c = MachineConfig(ecid: UInt64.random(in: 1 << 40 ..< 1 << 62))   // a new machine identity
        saveConfig(c)
        return c
    }

    private func saveConfig(_ c: MachineConfig) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: configURL, options: .atomic)
    }
}

struct HostError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

extension BootROM {
    /// The async fetch (downloaded, unpacked and checked against its SHA-256), waited for
    /// from the host thread.
    static func syncDownload() throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(HostError("no result"))
        Task.detached {
            do { result = .success(try await BootROM.download()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}


// MARK: - Host memory

/// Logs the Apple TV's memory every few seconds: what is free, what the compressor
/// holds, paging to and from storage, and this app's footprint. This is what decides
/// guest RAM size and ATV_RAM_MODE.
enum HostMemory {
    private static var timer: DispatchSourceTimer?

    struct Sample {
        var free: UInt64 = 0, compressed: UInt64 = 0, pageins: UInt64 = 0, pageouts: UInt64 = 0
        var compressions: UInt64 = 0, decompressions: UInt64 = 0, faults: UInt64 = 0
    }

    static func sample() -> Sample? {
        var s = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return Sample(free: UInt64(s.free_count) * page, compressed: UInt64(s.compressor_page_count) * page,
                      pageins: UInt64(s.pageins), pageouts: UInt64(s.pageouts),
                      compressions: UInt64(s.compressions), decompressions: UInt64(s.decompressions),
                      faults: UInt64(s.faults))
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func startLogging(every seconds: Int, update: @escaping (String) -> Void) {
        guard seconds > 0, timer == nil, var last = sample() else { return }
        var lastTime = Date()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        t.setEventHandler {
            guard let now = sample() else { return }
            let dt = max(0.001, Date().timeIntervalSince(lastTime))
            func rate(_ a: UInt64, _ b: UInt64) -> Int { Int(Double(a &- b) / dt) }
            let mb = { (b: UInt64) in b >> 20 }
            let line = "free \(mb(now.free)) MB, compressed \(mb(now.compressed)) MB, "
                + "page-ins \(rate(now.pageins, last.pageins))/s, page-outs \(rate(now.pageouts, last.pageouts))/s, "
                + "compressions \(rate(now.compressions, last.compressions))/s, "
                + "decompressions \(rate(now.decompressions, last.decompressions))/s, "
                + "faults \(rate(now.faults, last.faults))/s; app footprint \(mb(footprint())) MB, "
                + "before jetsam \(henge_available_memory() >> 20) MB"
            Log.line("memory", line)
            update(line)
            last = now
            lastTime = Date()
        }
        t.resume()
        timer = t
    }
}
