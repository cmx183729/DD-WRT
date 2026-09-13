#!/usr/bin/env python3
"""Normalize libtool archiver arguments for the GCC LTO wrappers.

GNU binutils treats an ``l`` modifier in an ``ar`` option bundle as a
libdeps modifier.  The old rules pass a quoted ``cru $(LTOPLUGIN)`` value,
and that can both be parsed incorrectly and add the LTO plugin twice when
the GCC archiver wrapper is used.  Keep one canonical setting instead:
``gcc-ar``/``gcc-ranlib`` plus ``AR_FLAGS=cru``.
"""

from pathlib import Path
import re
import sys


_ASSIGNMENT = re.compile(r"\b(AR_FLAGS|ARFLAGS|AR|RANLIB)\s*=")
_PLUGIN = "$(LTOPLUGIN)"
_REPLACEMENTS = {
    "AR_FLAGS": '"cru"',
    "ARFLAGS": '"cru"',
    "AR": '"$(CROSS_COMPILE)gcc-ar"',
    "RANLIB": '"$(CROSS_COMPILE)gcc-ranlib"',
}


def _quoted_end(line: str, start: int) -> int:
    quote = line[start]
    index = start + 1
    while index < len(line):
        if quote == '"' and line[index] == "\\" and index + 1 < len(line):
            index += 2
            continue
        if line[index] == quote:
            return index + 1
        if line[index] in "\r\n":
            return index
        index += 1
    return index


def _assignment_end(line: str, value_start: int, plugin_start: int) -> int:
    if value_start < len(line) and line[value_start] in "\"'":
        quoted_end = _quoted_end(line, value_start)
        if plugin_start < quoted_end:
            return quoted_end
    # Unquoted AR_FLAGS=cru $(LTOPLUGIN) form: include the plugin token but
    # leave a following continuation, command, or variable assignment intact.
    return plugin_start + len(_PLUGIN)


def _normalize_line(line: str) -> tuple[str, int]:
    replacements = 0
    cursor = 0
    while True:
        match = _ASSIGNMENT.search(line, cursor)
        if match is None:
            break
        name = match.group(1)
        value_start = match.end()
        while value_start < len(line) and line[value_start] in " \t":
            value_start += 1
        plugin_start = line.find(_PLUGIN, value_start)
        next_assignment = _ASSIGNMENT.search(line, match.end())
        if plugin_start < 0 or (
            next_assignment is not None and next_assignment.start() < plugin_start
        ):
            cursor = match.end()
            continue
        value_end = _assignment_end(line, value_start, plugin_start)
        replacement = _REPLACEMENTS[name]
        line = line[:value_start] + replacement + line[value_end:]
        replacements += 1
        cursor = value_start + len(replacement)
    return line, replacements


def _read(path: Path) -> str:
    with path.open(
        "r", encoding="utf-8", errors="surrogateescape", newline=""
    ) as stream:
        return stream.read()


def _write(path: Path, text: str) -> None:
    with path.open(
        "w", encoding="utf-8", errors="surrogateescape", newline=""
    ) as stream:
        stream.write(text)


def _normalize_core_makefile(path: Path) -> int:
    if not path.is_file():
        return 0
    original = _read(path)
    updated = original.replace(
        "export AR := $(CROSS_COMPILE)ar",
        "export AR := $(CROSS_COMPILE)gcc-ar",
    ).replace(
        "export RANLIB := $(CROSS_COMPILE)ranlib",
        "export RANLIB := $(CROSS_COMPILE)gcc-ranlib",
    )
    if updated == original:
        return 0
    _write(path, updated)
    return 1


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            f"usage: {Path(sys.argv[0]).name} RULES_DIR [ROUTER_MAKEFILE]",
            file=sys.stderr,
        )
        return 2

    rules_dir = Path(sys.argv[1])
    if not rules_dir.is_dir():
        print(f"rules directory not found: {rules_dir}", file=sys.stderr)
        return 1

    files_changed = 0
    replacements = 0

    for path in sorted(rules_dir.rglob("*.mk")):
        original = _read(path)
        lines = original.splitlines(keepends=True)
        updated_lines = []
        file_replacements = 0
        for line in lines:
            updated_line, count = _normalize_line(line)
            updated_lines.append(updated_line)
            file_replacements += count
        if not file_replacements:
            continue
        _write(path, "".join(updated_lines))
        files_changed += 1
        replacements += file_replacements

    core_replacements = 0
    if len(sys.argv) == 3:
        core_replacements = _normalize_core_makefile(Path(sys.argv[2]))

    print(
        f"normalized {replacements} archiver assignment(s) in "
        f"{files_changed} rule file(s) and {core_replacements} core Makefile(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
