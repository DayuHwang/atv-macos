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
- [x] JIT servicer + fake-debugserver test (`python3 jit/test_servicer.py` → PASS)
- [ ] Transport adapter to pymobiledevice3 debugproxy + DVT launch (needs the lab's installed version)
- [ ] Confirm model / storage
- [ ] tvOS target, deps rebuilt for appletvos, headless shell, RFB server
- [ ] Build (macOS + Xcode 27), sign, install, first boot
