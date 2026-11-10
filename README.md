# atv-macos — macOS on Apple TV 4K (3rd gen) via a tvOS port of Henge

## Target
- Apple TV on tvOS 27.2 at 192.168.1.239, already developer-paired from Windows
  (AppleTV-Windows-Lab, pymobiledevice3 11.49.1, userspace RSD tunnel).
- tvOS 27 runs only on Apple TV 4K 2nd gen (A12) and 3rd gen (A15).
  Henge passes Armv8.5 instructions through natively, so **only A15 works**.
  Model still to be confirmed.

## Architecture
1. **tvOS app** (fork of Henge): engine unchanged (C/Metal, no iOS-only APIs);
   new headless SwiftUI shell: install macOS, start machine, show status.
   Dropped on tvOS: trackpad/touch, Files import, clipboard/PasteButton, ShareLink,
   volume-button clicks, haptics, external-display accessory, HengeJITHelper extension.
2. **Built-in RFB (VNC) server in the app**: serves the guest framebuffer and injects
   keyboard/mouse into the virtual Mac, so the machine is usable from Windows from the
   very first boot (Setup Assistant), before macOS Screen Sharing exists.
3. **JIT from Windows** (`jit/`): attach debugserver over the existing RSD tunnel and
   service Henge's BreakpointJIT traps (brk #0x69 probe, brk #0xf00d x16=1 prepare
   region, x16=0 detach). Pipelined page touches: 1 GiB = 65536 pages in ~128 round trips.
4. **Memory**: Henge already keeps guest RAM out of the jetsam limit once a debugger has
   attached, falling back to a file on storage.
5. **Remote use**: VNC on the Apple TV's LAN address; from China via the Tailscale setup.

## Status
- [x] Model confirmed: AppleTV14,1 (Apple TV 4K 3rd gen, A15), tvOS 27.2
- [x] JIT servicer + fake-debugserver test (`python3 jit/test_servicer.py` → PASS)
- [x] Henge engine builds for appletvos (`tv/build-engine.sh`, CI on the xcode-27 image)
- [x] Installer stack builds for appletvos (`tv/build-restore.sh`)
- [x] tvOS compat layer (`tv/compat`): sigaltstack via direct syscall; fork, posix_spawn
      and the EDR log flag stubbed (unreachable on Apple TV)
- [ ] Transport adapter to pymobiledevice3 debugproxy + DVT launch (needs the lab's installed version)
- [ ] Storage capacity (64 or 128 GB)
- [x] tvOS app (`tv/app`): unattended host, built-in VNC (RFB 3.3–3.8, Raw/ZRLE, VNC auth),
      status page on :8080; CI builds an unsigned arm64 tvOS IPA
- [ ] libslirp + glib for appletvos (guest networking)
- [ ] Sign with the owner's Apple ID (Impactor on Windows), install, first boot
- [ ] Windows keeper: launch with debugger, service JIT, relaunch after install/shutdown
