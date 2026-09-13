#!/usr/bin/env python3
"""Remove libtool's literal quote wrapper around LTO archiver flags."""

from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} RULES_DIR", file=sys.stderr)
        return 2

    rules_dir = Path(sys.argv[1])
    if not rules_dir.is_dir():
        print(f"rules directory not found: {rules_dir}", file=sys.stderr)
        return 1

    malformed = r'AR_FLAGS="\"cru $(LTOPLUGIN)\""'
    corrected = 'AR_FLAGS="cru $(LTOPLUGIN)"'
    files_changed = 0
    replacements = 0

    for path in sorted(rules_dir.rglob("*.mk")):
        with path.open("r", encoding="utf-8", errors="surrogateescape", newline="") as stream:
            original = stream.read()
        count = original.count(malformed)
        if not count:
            continue
        updated = original.replace(malformed, corrected)
        with path.open("w", encoding="utf-8", errors="surrogateescape", newline="") as stream:
            stream.write(updated)
        files_changed += 1
        replacements += count

    print(f"fixed {replacements} AR_FLAGS assignment(s) in {files_changed} rule file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
