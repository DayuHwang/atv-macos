"""Adds atv-macos's `tvsign` command to a Sideloader checkout (CI only).

    python3 pc/sideloader/patch.py <sideloader checkout>

Copies tvsign.d into the CLI and registers it in cli_frontend.d. Fails loudly
if upstream has changed shape, rather than producing a CLI without the command.
"""
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
cli = root / "frontends" / "cli" / "source"
shutil.copy(Path(__file__).with_name("tvsign.d"), cli / "tvsign.d")

p = cli / "cli_frontend.d"
s = p.read_text(encoding="utf-8")
edits = [
    ("import tool;\n", "import tool;\nimport tvsign;\n"),
    ("(ToolCommand cmd) => cmd(),\n", "(ToolCommand cmd) => cmd(),\n                (TvSignCommand cmd) => cmd(),\n"),
    ("TeamCommand, ToolCommand, VersionCommand) cmd;", "TeamCommand, ToolCommand, TvSignCommand, VersionCommand) cmd;"),
]
for old, new in edits:
    if s.count(old) != 1:
        sys.exit(f"patch.py: expected exactly one {old!r} in {p}")
    s = s.replace(old, new)
p.write_text(s, encoding="utf-8")
print("tvsign added to", p)
