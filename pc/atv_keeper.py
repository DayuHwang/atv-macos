"""atv-macos keeper for Windows: keeps the virtual Mac on the Apple TV alive.

Runs beside AppleTV-Windows-Lab and reuses its developer pairing with the TV.
In a loop it:
  1. opens the developer tunnel to the Apple TV (the lab's open_rsd),
  2. finds the atv-macos app, launches it suspended with the VNC password in its
     environment (or attaches to it if it is already waiting),
  3. attaches debugserver and services the app's JIT request, then detaches,
  4. follows the app's status page and relaunches it whenever it exits (after
     installing macOS, or when macOS shuts down).

Usage (from the lab folder): runtime313\\python.exe atv-macos\\atv_keeper.py
GPL-2.0-or-later.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import socket
import string
import sys
import time
import urllib.request
from contextlib import asynccontextmanager
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from jit.gdbremote import GdbRemote  # noqa: E402
from jit.servicer import JitServicer  # noqa: E402

DEBUGPROXY = "com.apple.internal.dt.remote.debugproxy"
EXECUTABLE = "ATVMac"


def say(text: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + text, flush=True)


# ---------------------------------------------------------------- settings

def load_settings(lab: Path) -> dict:
    path = lab / "data" / "atv-macos.json"
    settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not settings.get("vnc_password"):
        alphabet = string.ascii_letters + string.digits
        settings["vnc_password"] = "".join(secrets.choice(alphabet) for _ in range(8))  # VNC uses 8 characters
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
    return settings


def tv_host(lab: Path) -> tuple[str, str]:
    conn = json.loads((lab / "data" / "connection.json").read_text(encoding="utf-8"))
    return conn["pairing_identifier"], conn["host"]


# ---------------------------------------------------------------- device

async def find_bundle(rsd) -> str | None:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    apps = await InstallationProxyService(lockdown=rsd).get_apps(application_type="User")
    for bundle_id, info in apps.items():
        if info.get("CFBundleExecutable") == EXECUTABLE:
            return bundle_id
    return None


async def running_pid(rsd, bundle_id: str) -> int:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
        try:
            return int(await pc.process_identifier_for_bundle_identifier(bundle_id) or 0)
        except Exception:
            return 0


async def launch(rsd, bundle_id: str, password: str, suspended: bool = True) -> int:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
        return await pc.launch(bundle_id, kill_existing=True, start_suspended=suspended,
                               environment={"ATV_VNC_PASSWORD": password})


async def launch_for_jit(rsd, bundle_id: str, password: str) -> int:
    """Suspended launch first (the debugger is there before the app runs). If tvOS
    refuses that, a normal launch works too: the app waits for a debugger anyway."""
    try:
        return await launch(rsd, bundle_id, password, suspended=True)
    except Exception as e:
        say(f"挂起启动被拒（{first_line(e)}），改用正常启动后再挂接。")
    pid = await launch(rsd, bundle_id, password, suspended=False)
    await asyncio.sleep(1)
    return pid


def first_line(e: Exception) -> str:
    text = str(e)
    for key in ("NSLocalizedFailureReason': '", "NSLocalizedDescription': '"):
        if key in text:
            return text.split(key, 1)[1].split("'", 1)[0]
    return text.splitlines()[0][:200] if text else type(e).__name__


DIAG_KEYS = ("atvmac", "85f2xjxdth", "amfi", "installd", "pineboard", "frontboard", "runningboard",
             "codesign", "code signature", "provision", "profile", "trust", "developer mode", "dyld",
             "xpcproxy", "launchd", "sleep", "wake", "denied", "not permitted")


async def diagnose(rsd, bundle_id: str, password: str, lab: Path) -> None:
    """Launch with the device log streaming, and show the lines that explain the outcome."""
    from pymobiledevice3.services.os_trace import OsTraceService
    every: list[str] = []
    hits: list[str] = []

    async def collect():
        svc = OsTraceService(lockdown=rsd)
        async for e in svc.syslog():
            name = (e.filename or "").rsplit("/", 1)[-1]
            line = f"{e.timestamp:%H:%M:%S} {name}[{e.pid}] {e.message}"
            every.append(line)
            if any(k in line.lower() for k in DIAG_KEYS):
                hits.append(line)

    task = asyncio.create_task(collect())
    await asyncio.sleep(2)
    for suspended in (True, False):
        try:
            pid = await launch(rsd, bundle_id, password, suspended)
            say(f"诊断：{'挂起' if suspended else '正常'}启动成功，pid {pid}")
        except Exception as e:
            say(f"诊断：{'挂起' if suspended else '正常'}启动失败：{first_line(e)}")
        await asyncio.sleep(5)
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    out = lab / "data" / "atv-launch-diagnose.log"
    out.write_text("\n".join(every), encoding="utf-8")
    say(f"相关日志（共 {len(hits)} 行，完整日志 {len(every)} 行已存到 {out}）：")
    for line in hits[-80:]:
        print("   " + line[:300])


@asynccontextmanager
async def debugproxy_port(rsd):
    """debugserver forwarded to a loopback port, so the (blocking) GDB client can
    talk to it from a worker thread with a plain socket."""
    from pymobiledevice3.tcp_forwarder import LockdownTcpForwarder
    ready = asyncio.Event()
    fwd = LockdownTcpForwarder(rsd, 0, DEBUGPROXY, listening_event=ready)
    task = asyncio.create_task(fwd.start())
    try:
        await asyncio.wait({task, asyncio.create_task(ready.wait())}, return_when=asyncio.FIRST_COMPLETED)
        if not ready.is_set():
            task.result()
        yield fwd.listening_port
    finally:
        fwd.stop()
        await asyncio.gather(task, return_exceptions=True)


class SocketTransport:
    def __init__(self, s: socket.socket):
        self.s = s

    def send(self, b: bytes) -> None:
        self.s.sendall(b)

    def recv(self, n: int) -> bytes:
        return self.s.recv(n)


def service_jit(port: int, pid: int) -> bool:
    """Attach, answer the app's JIT request, detach. Blocking; runs in a thread."""
    with socket.create_connection(("127.0.0.1", port), timeout=30) as s:
        s.settimeout(180)   # the app may take a moment before it asks
        gdb = GdbRemote(SocketTransport(s), log=lambda m: say("  " + m))
        gdb.handshake()
        stop = gdb.attach(pid)
        say(f"  已挂接调试器（pid {pid}），等待 App 申请 JIT 内存…")
        return JitServicer(gdb, log=lambda m: say("  " + m)).run(stop)


async def grant_jit(rsd, pid: int) -> bool:
    async with debugproxy_port(rsd) as port:
        return await asyncio.to_thread(service_jit, port, pid)


# ---------------------------------------------------------------- status page

def status(host: str) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://{host}:8080/status", timeout=4) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return None


PHASES = {
    "waiting-for-jit": "等待 JIT", "downloading": "下载 macOS", "installing": "安装 macOS",
    "booting": "启动中", "running": "运行中", "stopped": "已停止", "failed": "出错",
}


# ---------------------------------------------------------------- evidence

def app_log(host: str) -> str | None:
    try:
        with urllib.request.urlopen(f"http://{host}:8080/log", timeout=4) as r:
            return r.read().decode("utf-8", "replace")
    except Exception:
        return None


CRASH_KEYS = ("exception", "termination", "signal", "reason", "jetsam", "memorystatus",
              "per-process-limit", "vm-pageshortage", "highwater", "fpm", "crashed", "faulting",
              "atvmac", "\"type\"", "codes", "subtype", "largestprocess", "rpages", "lifetimemax")


async def crash_reports(rsd, lab: Path, since: float) -> None:
    """Pulls the app's crash reports and the system's memory (Jetsam) reports written since
    `since`, and prints the lines that say why the app died."""
    from pymobiledevice3.services.crash_reports import CrashReportsManager
    out = lab / "data" / "crash"
    out.mkdir(parents=True, exist_ok=True)
    before = {p.name for p in out.rglob("*") if p.is_file()}
    try:
        async with CrashReportsManager(rsd) as crashes:
            try:
                await crashes.flush()
            except Exception:
                pass
            await crashes.pull(str(out), match=r"(ATVMac|JetsamEvent)", progress_bar=False)
    except Exception as e:
        say(f"取崩溃报告失败：{type(e).__name__}: {e}")
        return
    files = sorted((p for p in out.rglob("*") if p.is_file() and p.stat().st_mtime >= since - 600),
                   key=lambda p: p.stat().st_mtime)
    fresh = [p for p in files if p.name not in before] or files[-4:]
    if not fresh:
        say("电视上没有找到 App 的崩溃报告或内存报告。")
        return
    for p in fresh[-4:]:
        say(f"报告：{p.name}")
        text = p.read_text(encoding="utf-8", errors="replace")
        shown = 0
        for line in text.splitlines():
            low = line.lower()
            if any(k in low for k in CRASH_KEYS):
                print("     " + line.strip()[:220])
                shown += 1
                if shown >= 40:
                    break
    say(f"完整报告在 {out}")


# ---------------------------------------------------------------- main loop

async def keep(lab: Path, once: bool, diag: bool = False, crashes_only: bool = False) -> None:
    sys.path.insert(0, str(lab))
    import developer  # the lab's tunnel code
    developer.configure_library()
    udid, host = tv_host(lab)
    password = load_settings(lab)["vnc_password"]
    say(f"Apple TV {host}；VNC 连接 {host}:5900，密码 {password}；状态页 http://{host}:8080")

    failures = 0
    while True:
        try:
            async with developer.open_rsd(udid, host) as rsd:
                bundle = await find_bundle(rsd)
                if not bundle:
                    say("电视上还没有安装 atv-macos App。先用 Impactor 签名安装，再运行本程序。")
                    return
                say(f"找到 App：{bundle}")
                if diag:
                    await diagnose(rsd, bundle, password, lab)
                    return
                if crashes_only:
                    await crash_reports(rsd, lab, time.time() - 6 * 3600)
                    return
                while True:
                    s = status(host)
                    pid = await running_pid(rsd, bundle)
                    if pid and s and s.get("phase") == "waiting-for-jit":
                        say("App 已在运行、正等 JIT，直接挂接。")
                        ok = await grant_jit(rsd, pid)
                    elif not pid:
                        say("启动 App…")
                        pid = await launch_for_jit(rsd, bundle, password)
                        ok = await grant_jit(rsd, pid)
                    else:
                        ok = True
                    if not ok:
                        raise RuntimeError("JIT 没有成功授予")
                    failures = 0
                    if once:
                        return
                    await follow(rsd, bundle, host, lab)
        except Exception as e:
            failures += 1
            wait = min(10 * failures, 120)
            say(f"出错：{type(e).__name__}: {e}；{wait} 秒后重试")
            await asyncio.sleep(wait)


async def follow(rsd, bundle: str, host: str, lab: Path) -> None:
    """Print phase changes and mirror the app's log; when the app is gone, keep its last
    log and the crash/memory reports, then return so the loop relaunches it."""
    last = None
    misses = 0
    started = time.time()
    mirror = lab / "data" / "atv-app-current.log"
    while True:
        await asyncio.sleep(5)
        s = status(host)
        if s:
            misses = 0
            line = f"{PHASES.get(s['phase'], s['phase'])}：{s.get('detail', '')}"
            if s.get("progress") is not None:
                line += f"  {s['progress'] * 100:.1f}%"
            if line != last:
                say(line)
                last = line
            log = app_log(host)
            if log:
                mirror.write_text(log, encoding="utf-8")
            continue
        misses += 1
        if misses >= 3 and not await running_pid(rsd, bundle):
            say("App 已退出。")
            if mirror.exists():
                kept = lab / "data" / time.strftime("atv-app-exit-%H%M%S.log")
                mirror.replace(kept)
                tail = kept.read_text(encoding="utf-8", errors="replace").splitlines()[-25:]
                say(f"App 最后的日志（完整的在 {kept}）：")
                for t in tail:
                    print("     " + t[:220])
            await asyncio.sleep(3)
            await crash_reports(rsd, lab, started)
            say("重新拉起 App。")
            return


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lab", type=Path, default=HERE.parent, help="AppleTV-Windows-Lab folder (default: parent folder)")
    ap.add_argument("--once", action="store_true", help="grant JIT once and exit instead of keeping the app alive")
    ap.add_argument("--diagnose", action="store_true", help="launch with the device log streaming and show why a launch fails")
    ap.add_argument("--crashes", action="store_true", help="pull and summarise the app's recent crash and memory reports")
    args = ap.parse_args()
    try:
        asyncio.run(keep(args.lab.resolve(), args.once, args.diagnose, args.crashes))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
