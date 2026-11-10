"""Open the virtual Mac on the Apple TV in TigerVNC Viewer, already logged in.

Reads the Apple TV's address (data\\connection.json) and the VNC password the
keeper hands the app (data\\atv-macos.json), writes TigerVNC's password file
(the standard VNC obfuscation: DES with a fixed key), and starts the viewer.
The keeper (ATV-Mac-Keeper.cmd) must be running, since it is what keeps the
app alive on the TV.

App builds before v5 sent empty ZRLE rectangles, which TigerVNC (it always
offers ZRLE) rejects by closing the connection. For those, the viewer is
pointed at a small relay on this PC that removes ZRLE from the encodings the
viewer offers, so the app answers in Raw. The relay runs without a window and
ends when the viewer is closed; it logs to data\\vnc-relay.log.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
VNC_PORT, STATUS_PORT = 5900, 8080
ZRLE = 16
# TigerVNC's d3des key {23,82,107,6,35,78,88,7}, bit-reversed per byte for standard DES.
OBFUSCATION_KEY = bytes.fromhex("e84ad660c4721ae0")
DETACHED = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def say(msg: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def obfuscate(password: str) -> bytes:
    block = password.encode("latin-1", "replace")[:8].ljust(8, b"\0")
    try:
        from Crypto.Cipher import DES
        return DES.new(OBFUSCATION_KEY, DES.MODE_ECB).encrypt(block)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
    except ImportError:
        from cryptography.hazmat.primitives.ciphers.algorithms import TripleDES
    from cryptography.hazmat.primitives.ciphers import Cipher, modes
    enc = Cipher(TripleDES(OBFUSCATION_KEY * 3), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def find_viewer(lab: Path) -> Path | None:
    candidates = [lab / "tools" / "TigerVNC-Viewer.exe"]
    candidates += sorted((lab / "tools").glob("vncviewer*.exe"), reverse=True)
    for env in ("ProgramFiles", "ProgramFiles(x86)"):
        if os.environ.get(env):
            candidates.append(Path(os.environ[env]) / "TigerVNC" / "vncviewer.exe")
    return next((c for c in candidates if c.is_file()), None)


def port_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def tv_status(host: str) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://{host}:{STATUS_PORT}/status", timeout=3) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return None


def viewer_command(viewer: Path, lab: Path, password: str, target: str) -> list[str]:
    cmd = [str(viewer), "-AlwaysCursor=1", "-PreferredEncoding=ZRLE"]
    if password:
        pw_file = lab / "data" / "vnc.passwd"
        pw_file.write_bytes(obfuscate(password))
        cmd += ["-PasswordFile", str(pw_file)]
    cmd.append(target)
    return cmd


# ---------------------------------------------------------------- relay

class ClientFilter:
    """Parses what the viewer sends and drops ZRLE from its SetEncodings."""

    HANDSHAKE = {"version": 12, "security": 1, "auth": 16, "init": 1}   # RFB 3.8, client side

    def __init__(self) -> None:
        self.buf = bytearray()
        self.stage = "version"
        self.raw = False   # gave up parsing: pass everything through

    def feed(self, data: bytes) -> bytes:
        if self.raw:
            return data
        self.buf += data
        out = bytearray()
        while True:
            if self.stage != "normal":
                need = self.HANDSHAKE[self.stage]
                if len(self.buf) < need:
                    break
                chunk = bytes(self.buf[:need]); del self.buf[:need]; out += chunk
                if self.stage == "version":
                    self.stage = "security"
                elif self.stage == "security":
                    self.stage = "auth" if chunk[0] == 2 else "init"   # 2 = VNC password
                elif self.stage == "auth":
                    self.stage = "init"
                else:
                    self.stage = "normal"
                continue
            if not self.buf:
                break
            t = self.buf[0]
            size = {0: 20, 3: 10, 4: 8, 5: 6}.get(t)
            if t == 2:
                if len(self.buf) < 4:
                    break
                n = int.from_bytes(self.buf[2:4], "big")
                size = 4 + 4 * n
                if len(self.buf) < size:
                    break
                encs = [int.from_bytes(self.buf[4 + 4 * i:8 + 4 * i], "big", signed=True) for i in range(n)]
                del self.buf[:size]
                keep = [e for e in encs if e != ZRLE]
                out += bytes([2, 0]) + len(keep).to_bytes(2, "big")
                for e in keep:
                    out += e.to_bytes(4, "big", signed=True)
                continue
            if t == 6:
                if len(self.buf) < 8:
                    break
                size = 8 + int.from_bytes(self.buf[4:8], "big")
            if size is None:   # a message this server never advertised: stop interpreting
                out += self.buf; self.buf.clear(); self.raw = True
                break
            if len(self.buf) < size:
                break
            out += self.buf[:size]; del self.buf[:size]
        return bytes(out)


def pump(src: socket.socket, dst: socket.socket, transform=None) -> None:
    try:
        while True:
            data = src.recv(1 << 18)
            if not data:
                break
            if transform:
                data = transform(data)
            if data:
                dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve_one(client: socket.socket, host: str) -> None:
    try:
        upstream = socket.create_connection((host, VNC_PORT), timeout=10)
    except OSError as e:
        say(f"relay: cannot reach {host}:{VNC_PORT}: {e}")
        client.close()
        return
    upstream.settimeout(None)
    for s in (client, upstream):
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    say("relay: viewer connected")
    f = ClientFilter()
    t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    t.start()
    pump(client, upstream, f.feed)
    t.join(timeout=5)
    client.close(); upstream.close()
    say("relay: viewer disconnected")


def relay(lab: Path, host: str) -> int:
    log = open(lab / "data" / "vnc-relay.log", "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = log
    viewer = find_viewer(lab)
    password = load_password(lab)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    port = listener.getsockname()[1]
    say(f"relay: 127.0.0.1:{port} -> {host}:{VNC_PORT} (ZRLE removed from the viewer's encodings)")

    def accept_loop() -> None:
        while True:
            try:
                c, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=serve_one, args=(c, host), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    proc = subprocess.Popen(viewer_command(viewer, lab, password, f"127.0.0.1::{port}"), cwd=str(lab))
    rc = proc.wait()
    say(f"relay: viewer closed (exit {rc})")
    listener.close()
    return 0


# ---------------------------------------------------------------- main

def load_password(lab: Path) -> str:
    try:
        return json.loads((lab / "data" / "atv-macos.json").read_text(encoding="utf-8")).get("vnc_password", "")
    except (OSError, ValueError):
        return ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lab", type=Path, default=HERE.parent)
    ap.add_argument("--host", help="Apple TV address (default: from data\\connection.json)")
    ap.add_argument("--wait", type=int, default=180, help="seconds to wait for the app's VNC port")
    ap.add_argument("--relay", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--direct", action="store_true", help="connect the viewer straight to the TV")
    args = ap.parse_args()
    lab = args.lab.resolve()

    host = args.host
    if not host:
        try:
            host = json.loads((lab / "data" / "connection.json").read_text(encoding="utf-8"))["host"]
        except (OSError, KeyError, ValueError):
            say("data\\connection.json 里没有 Apple TV 的地址；先运行一次 ATV-Mac-Keeper.cmd，或用 --host 指定。")
            return 1
    if args.relay:
        return relay(lab, host)

    viewer = find_viewer(lab)
    if not viewer:
        say("没找到 TigerVNC Viewer（应在 tools\\TigerVNC-Viewer.exe）。")
        return 1

    deadline = time.monotonic() + args.wait
    if not port_open(host, VNC_PORT):
        say(f"Apple TV {host} 上的虚拟 Mac 还没开（{VNC_PORT} 端口没响应）。"
            "请先运行 ATV-Mac-Keeper.cmd 并保持它开着；这里会等它起来…")
        while not port_open(host, VNC_PORT):
            if time.monotonic() > deadline:
                say("等太久了，还是连不上。检查 Keeper 窗口里的报错，或者 Apple TV 是否睡眠了。")
                return 1
            time.sleep(3)
    status = tv_status(host) or {}
    if status:
        say(f"电视上的状态：{status.get('phase', '?')}  {status.get('detail', '')}".rstrip())

    if args.direct or status.get("vncZRLE"):
        cmd = viewer_command(viewer, lab, load_password(lab), f"{host}::{VNC_PORT}")
        subprocess.Popen(cmd, cwd=str(lab), creationflags=DETACHED, close_fds=True)
    else:
        # The relay outlives this window: run it under pythonw (no console) when there is one.
        exe = Path(sys.executable)
        quiet = exe.with_name("pythonw.exe")
        runner = str(quiet if quiet.is_file() else exe)
        cmd = [runner, str(Path(__file__).resolve()), "--relay", "--lab", str(lab), "--host", host]
        subprocess.Popen(cmd, cwd=str(lab), creationflags=DETACHED | NO_WINDOW, close_fds=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    say(f"已打开 TigerVNC Viewer → {host}:{VNC_PORT}（F8 是查看器菜单：全屏、发送 Ctrl+Alt+Del 等）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
