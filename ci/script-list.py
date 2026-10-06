#!/usr/bin/env python3
"""S1.2.6's static half: every shell script shipped under image/ and
deploy/host/usr/local/ is in the shellcheck list of ci.yml's static job.

  script-list.py found    the shipped shell scripts: every file git tracks
                          there whose first line runs sh or bash
  script-list.py listed   the files the "shellcheck (error severity)" step
                          names there, its globs expanded
  script-list.py check    both lists, and their difference; exit 1 unless
                          they are the same
  script-list.py self-test  the check against the step with one listed
                          script taken out of it: it must name that script

Paths print relative to the repository root, one per line, sorted.
"""
import glob
import os
import re
import shlex
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIPPED = ("image/", "deploy/host/usr/local/")
WORKFLOW = ".github/workflows/ci.yml"
STEP = "shellcheck (error severity)"
SHEBANG = re.compile(r"^#!\s*(/usr/bin/env\s+)?(/usr)?(/bin/)?(ba|da)?sh(\s|$)")


def found():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "--", *SHIPPED],
                         capture_output=True, text=True, check=True).stdout.split()
    scripts = []
    for path in out:
        try:
            with open(os.path.join(ROOT, path), "rb") as f:
                first = f.readline().decode(errors="replace")
        except OSError:
            continue
        if SHEBANG.match(first):
            scripts.append(path)
    return sorted(scripts)


def step_command():
    """The shellcheck command in the step's run block, continuation lines joined."""
    lines = open(os.path.join(ROOT, WORKFLOW), encoding="utf-8").read().split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == f"- name: {STEP}"), None)
    if start is None:
        raise SystemExit(f"no step named '{STEP}' in {WORKFLOW}")
    indent = len(lines[start]) - len(lines[start].lstrip())
    body = []
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break                                   # the next step, or the end of the job
        body.append(line)
    text = "\n".join(body).replace("\\\n", " ")
    cmd = next((l for l in text.split("\n") if re.search(r"\bshellcheck\s+-S\s+error\b", l)), None)
    if cmd is None:
        raise SystemExit(f"the step '{STEP}' runs no 'shellcheck -S error'")
    return cmd


def listed(cmd=None):
    words = shlex.split((cmd or step_command()).split("shellcheck", 1)[1])
    paths = set()
    for w in words:
        if w.startswith("-") or w == "error":
            continue
        hits = glob.glob(os.path.join(ROOT, w))
        for h in (hits or [os.path.join(ROOT, w)]):
            paths.add(os.path.relpath(h, ROOT))
    return sorted(p for p in paths if p.startswith(SHIPPED))


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "check"
    if what == "found":
        print("\n".join(found()))
    elif what == "listed":
        print("\n".join(listed()))
    elif what == "check":
        f, l = found(), listed()
        missing = [p for p in f if p not in l]
        extra = [p for p in l if p not in f]
        print(f"shipped shell scripts under {' and '.join(SHIPPED)}: {len(f)}")
        print(f"named by ci.yml's shellcheck step there: {len(l)}")
        for p in missing:
            print(f"not shellchecked: {p}")
        for p in extra:
            print(f"listed but not a shipped shell script: {p}")
        sys.exit(1 if missing or extra else 0)
    elif what == "self-test":
        cmd = step_command()
        victim = next(w for w in shlex.split(cmd) if w.startswith(SHIPPED) and "*" not in w)
        cut = listed(cmd.replace(" " + victim, " ", 1))
        missing = [p for p in found() if p not in cut]
        print(f"the step with {victim} taken out: not shellchecked: {' '.join(missing) or 'nothing'}")
        sys.exit(0 if victim in missing else 1)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
