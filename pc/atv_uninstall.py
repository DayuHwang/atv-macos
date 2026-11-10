"""Remove atv-macos from the Apple TV and this PC's credential store.

1. Stops the ATVMac app on the Apple TV and uninstalls it; its container, with
   the installed macOS disk, goes with it.
2. Deletes what atv-sign kept in Windows Credential Manager: the signing
   certificate and key (service "atv-macos") and isideload's anisette state
   (service "isideload").

The result is also written to data\\uninstall-result.txt.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
EXECUTABLE = "ATVMac"
SERVICES = ("atv-macos", "isideload")
lines: list[str] = []


def say(msg: str) -> None:
    line = time.strftime("[%H:%M:%S] ") + msg
    lines.append(line)
    print(line, flush=True)


async def remove_app() -> bool:
    sys.path.insert(0, str(LAB))
    import developer  # the lab's tunnel code
    developer.configure_library()
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    conn = json.loads((LAB / "data" / "connection.json").read_text(encoding="utf-8"))
    async with developer.open_rsd(conn["pairing_identifier"], conn["host"]) as rsd:
        proxy = InstallationProxyService(lockdown=rsd)
        apps = await proxy.get_apps(application_type="User")
        ours = [b for b, info in apps.items() if info.get("CFBundleExecutable") == EXECUTABLE]
        if not ours:
            say("Apple TV 上没有 ATVMac App（已经删掉了）。")
            return True
        for bundle in ours:
            try:
                async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
                    pid = int(await pc.process_identifier_for_bundle_identifier(bundle) or 0)
                    if pid:
                        await pc.kill(pid)
                        say(f"已关掉正在运行的 App（pid {pid}）。")
                        await asyncio.sleep(2)
            except Exception as e:
                say(f"关 App 时出错（{type(e).__name__}），直接卸载。")
            say(f"正在卸载 {bundle}（连同里面的 macOS，可能要一两分钟）…")
            await proxy.uninstall(bundle)
        left = [b for b, info in (await InstallationProxyService(lockdown=rsd).get_apps(application_type="User")).items()
                if info.get("CFBundleExecutable") == EXECUTABLE]
        if left:
            say(f"卸载后还在：{left}")
            return False
        say("Apple TV 上的 ATVMac App 已卸载。")
        return True


def remove_credentials() -> bool:
    if sys.platform != "win32":
        say("不是 Windows，跳过凭据。")
        return True
    import ctypes
    from ctypes import wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("lo", wintypes.DWORD), ("hi", wintypes.DWORD)]

    class CREDENTIALW(ctypes.Structure):
        _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                    ("Comment", wintypes.LPWSTR), ("LastWritten", FILETIME), ("CredentialBlobSize", wintypes.DWORD),
                    ("CredentialBlob", ctypes.c_void_p), ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD),
                    ("Attributes", ctypes.c_void_p), ("TargetAlias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR)]

    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi.CredEnumerateW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                      ctypes.POINTER(ctypes.POINTER(ctypes.POINTER(CREDENTIALW)))]
    advapi.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
    count = wintypes.DWORD()
    creds = ctypes.POINTER(ctypes.POINTER(CREDENTIALW))()
    if not advapi.CredEnumerateW(None, 0, ctypes.byref(count), ctypes.byref(creds)):
        say("凭据管理器里没有可列出的凭据。")
        return True
    found = []
    for i in range(count.value):
        c = creds[i].contents
        name = c.TargetName or ""
        # keyring on Windows names an entry "<key>.<service>"
        if any(name.endswith("." + s) or name == s for s in SERVICES):
            found.append((name, c.Type))
    advapi.CredFree(creds)
    ok = True
    for name, typ in found:
        if advapi.CredDeleteW(name, typ, 0):
            say(f"已删除凭据：{name}")
        else:
            ok = False
            say(f"删不掉凭据：{name}（错误 {ctypes.get_last_error()}）")
    if not found:
        say("凭据管理器里没有 atv-sign 留下的条目。")
    return ok


def main() -> int:
    say("开始清理 atv-macos：Apple TV 上的 App 和电脑上的签名凭据。")
    try:
        app_ok = asyncio.run(remove_app())
    except Exception as e:
        app_ok = False
        say(f"连不上 Apple TV 或卸载失败：{type(e).__name__}: {e}")
        say("可以在电视上手动删：遥控器选中 ATVMac 图标，按住触控板直到图标晃动，选「删除 App」。")
    cred_ok = remove_credentials()
    say("完成。" if app_ok and cred_ok else "有一部分没完成，见上面。")
    try:
        (LAB / "data" / "uninstall-result.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    except OSError:
        pass
    return 0 if app_ok and cred_ok else 1


if __name__ == "__main__":
    sys.exit(main())
