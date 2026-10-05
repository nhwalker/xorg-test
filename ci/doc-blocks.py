#!/usr/bin/env python3
"""The fenced command blocks of the repository's documents, as written, for
the maintainer journeys (Requirements.md E10) to run verbatim.

  doc-blocks.py FILE HEADING [N]    the Nth (default 1) ```sh block under the
                                    first heading whose text starts with HEADING
  doc-blocks.py FILE HEADING N --commands
                                    the same block as commands, one per line:
                                    continuation lines joined, comments and
                                    blank lines dropped, a trailing "# ..."
                                    comment kept apart after a tab

Exits 1, saying why, when the heading or the block is not there, so a
document reorganised under a journey fails the journey rather than running
something else.
"""
import re
import sys


def block(path, heading, n=1):
    lines = open(path, encoding="utf-8").read().split("\n")
    start = None
    for i, l in enumerate(lines):
        m = re.match(r"^(#+)\s+(.*)$", l)
        if m and m.group(2).startswith(heading):
            start, level = i + 1, len(m.group(1))
            break
    if start is None:
        raise SystemExit(f"{path}: no heading starting {heading!r}")
    found, inside, cur = 0, False, []
    for l in lines[start:]:
        m = re.match(r"^(#+)\s", l)
        if not inside and m and len(m.group(1)) <= level:
            break                                   # the section ended
        if not inside and re.match(r"^```(sh|bash)?\s*$", l):
            inside, cur = True, []
            continue
        if inside and l.startswith("```"):
            inside = False
            found += 1
            if found == n:
                return cur
            continue
        if inside:
            cur.append(l)
    raise SystemExit(f"{path}: under {heading!r} there are {found} command blocks, not {n}")


def commands(text_lines):
    """One command per line: continuations joined; comment-only and blank
    lines dropped; a trailing comment kept after a tab."""
    out, cur = [], ""
    for l in text_lines:
        s = l.rstrip()
        if not cur and (not s.strip() or s.lstrip().startswith("#")):
            continue
        if s.endswith("\\"):
            cur += s[:-1].rstrip() + " "
            continue
        cur += s.strip() if cur else s.strip()
        cmd, comment = split_comment(cur)
        out.append(cmd + (f"\t{comment}" if comment else ""))
        cur = ""
    return out


def split_comment(line):
    """The command and its trailing "# ..." comment, quotes respected."""
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i].rstrip(), line[i + 1:].strip()
    return line.rstrip(), ""


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        raise SystemExit(__doc__)
    path, heading = a[0], a[1]
    n = int(a[2]) if len(a) > 2 and a[2].isdigit() else 1
    b = block(path, heading, n)
    print("\n".join(commands(b) if "--commands" in a else b))


if __name__ == "__main__":
    main()
