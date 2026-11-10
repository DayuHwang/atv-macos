"""atv-macos installer for Windows: sign the tvOS app with your Apple ID and
install it on the Apple TV over the lab's developer connection.

  1. reads the Apple TV's UDID over the developer tunnel,
  2. unpacks ATVMac-unsigned.ipa,
  3. runs Sideloader's `tvsign` (atv-macos build): you type your Apple ID,
     password and the 2FA code in this window; it registers the Apple TV,
     makes the tvOS development profile and signs the app,
  4. installs the signed app on the Apple TV.

Free Apple IDs sign for 7 days: run this again within a week to renew.

Usage (from the lab folder): runtime313\\python.exe atv-macos\\atv_install.py
GPL-2.0-or-later.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DOWNLOADS = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Downloads"


def say(text: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + text, flush=True)


def newest(patterns: list[str], folders: list[Path]) -> Path | None:
    found = [p for folder in folders if folder.exists() for pat in patterns for p in folder.glob(pat)]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def sideloader_exe(zip_arg: Path | None) -> Path:
    home = HERE / "sideloader"
    exe = home / "sideloader.exe"
    zip_path = zip_arg or newest(["sideloader-tvos-win64*.zip"], [HERE, DOWNLOADS])
    if zip_path and (not exe.exists() or zip_path.stat().st_mtime > exe.stat().st_mtime):
        say(f"解压签名工具：{zip_path}")
        shutil.rmtree(home, ignore_errors=True)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(home)
    if not exe.exists():
        sys.exit("找不到签名工具 sideloader-tvos-win64.zip（放进“下载”文件夹或 atv-macos 文件夹）。")
    for dll in ("plist.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll"):
        if not (home / dll).exists():
            sys.exit(f"签名工具缺少 {dll}，请重新下载 sideloader-tvos-win64.zip。")
    return exe


def unpack_ipa(ipa: Path) -> Path:
    work = HERE / "work"
    shutil.rmtree(work, ignore_errors=True)
    with zipfile.ZipFile(ipa) as z:
        z.extractall(work)
    apps = list((work / "Payload").glob("*.app"))
    if len(apps) != 1:
        sys.exit("安装包里没有找到 .app。")
    return apps[0]


async def apple_tv_udid(lab: Path) -> tuple[str, str]:
    import developer
    conn = json.loads((lab / "data" / "connection.json").read_text(encoding="utf-8"))
    async with developer.open_rsd(conn["pairing_identifier"], conn["host"]) as rsd:
        return rsd.udid, conn.get("device_name") or "Apple TV"


async def install(lab: Path, app: Path) -> None:
    import developer
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    conn = json.loads((lab / "data" / "connection.json").read_text(encoding="utf-8"))
    async with developer.open_rsd(conn["pairing_identifier"], conn["host"]) as rsd:
        proxy = InstallationProxyService(lockdown=rsd)
        await proxy.install_from_local(app)
        apps = await proxy.get_apps(application_type="User")
        ours = [b for b, info in apps.items() if info.get("CFBundleExecutable") == "ATVMac"]
        if not ours:
            raise RuntimeError("安装命令完成了，但电视上没有找到这个 App。")
        say(f"已安装到 Apple TV：{ours[0]}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lab", type=Path, default=HERE.parent)
    ap.add_argument("--ipa", type=Path, help="ATVMac-unsigned.ipa (default: newest in Downloads or atv-macos)")
    ap.add_argument("--sideloader", type=Path, help="sideloader-tvos-win64.zip (default: newest in Downloads or atv-macos)")
    args = ap.parse_args()
    lab = args.lab.resolve()
    sys.path.insert(0, str(lab))
    import developer
    developer.configure_library()

    exe = sideloader_exe(args.sideloader)
    ipa = args.ipa or newest(["ATVMac-unsigned*.ipa"], [HERE, DOWNLOADS])
    if not ipa:
        sys.exit("找不到 ATVMac-unsigned.ipa（放进“下载”文件夹或 atv-macos 文件夹）。")

    say("读取 Apple TV 的设备 ID…")
    udid, name = asyncio.run(apple_tv_udid(lab))
    say(f"Apple TV：{name}（{udid}）")

    app = unpack_ipa(ipa)
    say(f"签名 {app.name}。接下来按提示输入 Apple ID、密码和双重认证验证码。")
    say("注意：Sideloader 输入密码时会把密码显示在屏幕上，输入前确认旁边没人看。")
    rc = subprocess.run([str(exe), "tvsign", "-i", "--udid", udid, "--name", name, str(app)],
                        cwd=exe.parent).returncode
    if rc != 0:
        sys.exit(f"签名没有成功（退出码 {rc}），上面的输出写了原因。")
    if not (app / "embedded.mobileprovision").exists() or not (app / "_CodeSignature").exists():
        sys.exit("签名工具结束了，但 App 里没有签名文件。")

    say("安装到 Apple TV…")
    asyncio.run(install(lab, app))
    say("完成。现在运行 ATV-Mac-Keeper.cmd 启动它。7 天内重新运行本程序续签。")


if __name__ == "__main__":
    main()
