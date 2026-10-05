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

  doc-blocks.py FILE HEADING --para PHRASE [--spans]
                                    the paragraph under HEADING that contains
                                    PHRASE, as one line; --spans: its inline
                                    code spans, one per line (a sequence the
                                    document gives in prose)
  doc-blocks.py FILE HEADING --entry LEAD [--spans]
                                    the list entry under HEADING whose bold
                                    lead starts with LEAD ("- **LEAD..."), as
                                    one line; --spans: its inline code spans,
                                    one per line (the commands a prose entry
                                    such as README.md's "Troubleshooting"
                                    gives)

Exits 1, saying why, when the heading, the block or the entry is not there,
so a document reorganised under a journey fails the journey rather than
running something else.
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


def section(path, heading):
    """The lines under the first heading starting with HEADING, to the next
    heading of the same or a higher level (a "# comment" in a code block is
    not one)."""
    lines = open(path, encoding="utf-8").read().split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"^(#+)\s+(.*)$", l)
        if m and m.group(2).startswith(heading):
            level, out, inside = len(m.group(1)), [], False
            for l2 in lines[i + 1:]:
                if l2.startswith("```"):
                    inside = not inside
                m2 = re.match(r"^(#+)\s", l2)
                if not inside and m2 and len(m2.group(1)) <= level:
                    break
                out.append(l2)
            return out
    raise SystemExit(f"{path}: no heading starting {heading!r}")


def entry(path, heading, lead):
    """The list entry whose bold lead starts with LEAD, its lines joined."""
    lines, out = section(path, heading), None
    for l in lines:
        if out is None:
            if re.match(r"^- \*\*" + re.escape(lead), l):
                out = [l[2:].strip()]
            continue
        if not l.strip() or re.match(r"^\s*- ", l) or l.startswith("#"):
            break
        out.append(l.strip())
    if out is None:
        raise SystemExit(f"{path}: under {heading!r} no entry starts **{lead}")
    return " ".join(out)


def para(path, heading, phrase):
    """The paragraph (blank-line separated, outside code blocks) containing
    PHRASE, its lines joined; PHRASE is matched with the lines joined too."""
    paras, cur, inside = [], [], False
    for l in section(path, heading) + [""]:
        if l.startswith("```"):
            inside = not inside
            continue
        if inside:
            continue
        if l.strip():
            cur.append(l.strip())
        elif cur:
            paras.append(" ".join(cur))
            cur = []
    hits = [p for p in paras if phrase in p]
    if not hits:
        raise SystemExit(f"{path}: under {heading!r} no paragraph contains {phrase!r}")
    return hits[0]


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
    if "--para" in a:
        text = para(path, heading, a[a.index("--para") + 1])
        print("\n".join(re.findall(r"`([^`]+)`", text)) if "--spans" in a else text)
        return
    if "--entry" in a:
        text = entry(path, heading, a[a.index("--entry") + 1])
        print("\n".join(re.findall(r"`([^`]+)`", text)) if "--spans" in a else text)
        return
    n = int(a[2]) if len(a) > 2 and a[2].isdigit() else 1
    b = block(path, heading, n)
    print("\n".join(commands(b) if "--commands" in a else b))


if __name__ == "__main__":
    main()
