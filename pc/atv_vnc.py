"""Open the virtual Mac on the Apple TV in TigerVNC Viewer, already logged in.

Reads the Apple TV's address (data\\connection.json) and the VNC password the
keeper hands the app (data\\atv-macos.json), writes TigerVNC's password file
(the standard VNC obfuscation: DES with a fixed key), and starts the viewer.
The keeper (ATV-Mac-Keeper.cmd) must be running, since it is what keeps the
app alive on the TV.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
VNC_PORT, STATUS_PORT = 5900, 8080
# TigerVNC's d3des key {23,82,107,6,35,78,88,7}, bit-reversed per byte for standard DES.
OBFUSCATION_KEY = bytes.fromhex("e84ad660c4721ae0")


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lab", type=Path, default=HERE.parent)
    ap.add_argument("--host", help="Apple TV address (default: from data\\connection.json)")
    ap.add_argument("--wait", type=int, default=180, help="seconds to wait for the app's VNC port")
    args = ap.parse_args()
    lab = args.lab.resolve()

    viewer = find_viewer(lab)
    if not viewer:
        say("没找到 TigerVNC Viewer（应在 tools\\TigerVNC-Viewer.exe）。")
        return 1
    host = args.host
    if not host:
        try:
            host = json.loads((lab / "data" / "connection.json").read_text(encoding="utf-8"))["host"]
        except (OSError, KeyError, ValueError):
            say("data\\connection.json 里没有 Apple TV 的地址；先运行一次 ATV-Mac-Keeper.cmd，或用 --host 指定。")
            return 1
    try:
        password = json.loads((lab / "data" / "atv-macos.json").read_text(encoding="utf-8")).get("vnc_password", "")
    except (OSError, ValueError):
        password = ""

    deadline = time.monotonic() + args.wait
    if not port_open(host, VNC_PORT):
        say(f"Apple TV {host} 上的虚拟 Mac 还没开（{VNC_PORT} 端口没响应）。"
            "请先运行 ATV-Mac-Keeper.cmd 并保持它开着；这里会等它起来…")
        while not port_open(host, VNC_PORT):
            if time.monotonic() > deadline:
                say("等太久了，还是连不上。检查 Keeper 窗口里的报错，或者 Apple TV 是否睡眠了。")
                return 1
            time.sleep(3)
    status = tv_status(host)
    if status:
        say(f"电视上的状态：{status.get('phase', '?')}  {status.get('detail', '')}".rstrip())

    cmd = [str(viewer), "-AlwaysCursor=1", "-PreferredEncoding=ZRLE"]
    if password:
        pw_file = lab / "data" / "vnc.passwd"
        pw_file.write_bytes(obfuscate(password))
        cmd += ["-PasswordFile", str(pw_file)]
    cmd.append(f"{host}::{VNC_PORT}")
    flags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen(cmd, cwd=str(lab), creationflags=flags, close_fds=True)
    say(f"已打开 TigerVNC Viewer → {host}:{VNC_PORT}"
        "（F8 是查看器菜单：全屏、发送 Ctrl+Alt+Del 等）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
