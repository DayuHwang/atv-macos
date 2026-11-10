"""atv-macos installer for Windows: sign the tvOS app with your Apple ID and
install it on the Apple TV over the lab's developer connection.

  1. reads the Apple TV's UDID over the developer tunnel,
  2. unpacks ATVMac-unsigned.ipa,
  3. runs atv-sign.exe: you type your Apple ID, password (not shown) and the 2FA
     code in this window; it registers the Apple TV, makes the tvOS development
     profile and signs the app,
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
TOOL = HERE / "atv-sign.exe"


def say(text: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + text, flush=True)


def newest(patterns: list[str], folders: list[Path]) -> Path | None:
    found = [p for folder in folders if folder and folder.exists() for pat in patterns for p in folder.glob(pat)]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def ask_path(prompt: str) -> Path | None:
    """Asks for a path; dragging a file or folder onto the console window types it in."""
    say(prompt)
    try:
        text = input("> ").strip().strip('"').strip()
    except EOFError:
        return None
    return Path(text) if text else None


def find_tool(arg: Path | None) -> tuple[Path, Path | None]:
    """atv-sign.exe (copied beside this script), and the folder it came from."""
    source = arg or newest(["atv-sign*.exe", "atv-sign*.zip"], [DOWNLOADS])
    if source is None and not TOOL.exists():
        source = ask_path("没在“下载”里找到 atv-sign.exe。把它（或它所在的文件夹）拖进这个窗口，然后按回车：")
    if source is not None:
        if source.is_dir():
            source = newest(["atv-sign*.exe", "atv-sign*.zip"], [source]) or source
        if source.is_file() and source.suffix.lower() == ".zip":
            with zipfile.ZipFile(source) as z:
                names = [n for n in z.namelist() if n.lower().endswith("atv-sign.exe")]
                if not names:
                    sys.exit(f"{source} 里没有 atv-sign.exe。")
                TOOL.write_bytes(z.read(names[0]))
        elif source.is_file() and source.suffix.lower() == ".exe":
            if source.resolve() != TOOL.resolve():
                shutil.copy2(source, TOOL)
        else:
            sys.exit(f"在 {source} 没有找到 atv-sign.exe。")
        say(f"签名工具：{source}")
    if not TOOL.exists():
        sys.exit("找不到签名工具 atv-sign.exe。")
    folder = None if source is None else source.parent
    return TOOL, folder


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
    ap.add_argument("--ipa", type=Path, help="ATVMac-unsigned.ipa (default: newest in Downloads, or beside atv-sign)")
    ap.add_argument("--tool", type=Path, help="atv-sign.exe, its zip, or the folder holding it")
    args = ap.parse_args()
    lab = args.lab.resolve()
    sys.path.insert(0, str(lab))
    import developer
    developer.configure_library()

    tool, tool_folder = find_tool(args.tool)
    ipa = args.ipa or newest(["ATVMac-unsigned*.ipa"], [HERE, DOWNLOADS, tool_folder])
    if not ipa:
        picked = ask_path("没找到 ATVMac-unsigned.ipa。把它（或它所在的文件夹）拖进这个窗口，然后按回车：")
        if picked and picked.is_dir():
            picked = newest(["*.ipa"], [picked])
        if not picked or not picked.is_file():
            sys.exit("没有安装包，无法继续。")
        ipa = picked
    say(f"安装包：{ipa}")

    say("读取 Apple TV 的设备 ID…")
    udid, name = asyncio.run(apple_tv_udid(lab))
    say(f"Apple TV：{name}（{udid}）")

    app = unpack_ipa(ipa)
    say("签名：接下来输入 Apple ID、密码（输入时不显示）和双重认证验证码。")
    rc = subprocess.run([str(tool), "--udid", udid, "--name", name, str(app)]).returncode
    if rc != 0:
        sys.exit(f"签名没有成功（退出码 {rc}），上面的输出写了原因。")
    if not (app / "embedded.mobileprovision").exists() or not (app / "_CodeSignature").exists():
        sys.exit("签名工具结束了，但 App 里没有签名文件。")

    say("安装到 Apple TV…")
    asyncio.run(install(lab, app))
    say("完成。现在运行 ATV-Mac-Keeper.cmd 启动它。7 天内重新运行本程序续签。")


if __name__ == "__main__":
    main()
