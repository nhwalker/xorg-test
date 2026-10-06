#!/usr/bin/env python3
"""Requirements.md E9, the test-suite rules a read of the tree can hold.

  S9.1.3  the desktop's processes are found through /run/desktop-init.pid,
          never /proc/1 or a lookup by name;
  S9.1.5  no reader that stops early (grep -q/-m/-l, head, sed q, awk exit,
          read, cmp, a loop or python that breaks) on a live pipeline under
          pipefail;
  S9.2.1  nothing weakens the system under test: no setenforce; no
          --privileged or label=disable on a podman run, create or exec
          (ci/client-guard.py's checks of Python and manifests included); no
          -e or -v that duplicates an edit of a CDI device the container
          requests (the edits read from the generators' specs); an -e of a
          CDI variable into a client only with the value read from that
          client's own pid 1; no write under /etc/containers/systemd but the
          documented procedures ALLOW names. Options a shell array holds
          are not seen;
  S9.2.2  the narrow fixtures stay narrow: an *-only pod requests exactly one
          desktop.local resource, and no pod declares more than requests;
  S9.2.4  a count read from the guest is an integer or a failed read (one
          that fails, or a poll that retries), never a number standing in
          for one: no `|| echo 0` on the read, no `${n:-0}` in a comparison,
          no Python handler that returns one;
  S9.2.5  each write under /etc is put back, and the restore checked: the
          RESTORES registry names, for every write, how (restored, undone
          by the product, a scratch file, the shipped file, a discarded VM)
          and the check, which must come after the write;
  S9.2.6  a documented procedure is run from the document: every
          doc-blocks.py read whose arguments are literal (or the file's
          constants) finds its block, paragraph or entry; no harness file
          types two or more lines of one fenced block of README.md,
          deploy/README.md or deploy/HOST-REQUIRES.md within 20 lines (the
          one line of a one-command block with arguments) unless an ALLOW
          entry pins the block's digest and the lines typed; in a story
          that runs what a document gives, each EV-PROCEDURE step is the
          document's or named harness-only, and each substitution it runs
          or writes is named a placeholder;
  S9.3.1  every story the harness begins is one Requirements.md defines, and
          the evidence check (ci/evlib.py check) fails each kind of
          incomplete story directory.

  ci/e9-guard.py [--rule S9.1.5,...] [--self-test]

Run from the repository root. --self-test first judges the rules' planted
files, violations and allowed forms, and requires each of their ALLOW entries
to excuse something in the tree. Each finding prints as
"VIOLATION <rule> <file>:<line>: <what> -- <fix>"; each rule ends with a
summary line. The output is the evidence. Exit status 1 on any violation or
any self-test misjudgement.
"""
import argparse
import ast
import glob
import hashlib
import importlib.util
import os
import re
import shlex
import sys
import tempfile

# --- data: what a reviewer may need to change ----------------------------------------

# Exceptions, keyed on content, never on line numbers. Each must excuse a
# finding in the tree (the self-test checks), so none outlives its reason.
ALLOW = [
    ("S9.1.3", "ci/vm/vm-guest.sh", r"readlink /proc/1/ns/cgroup",
     "the host's pid 1 on purpose: its cgroup namespace is compared with the container's"),
    ("S9.1.3", "ci/vm/vm-guest.sh", r"cat /proc/1/environ 2>&1 > /dev/null; echo rc=",
     "S6.2.1: container root must be refused the host's pid 1"),
    ("S9.1.3", "ci/vm/vm-guest.sh", r"dd if=/proc/1/mem", "the same refusal, for /proc/1/mem"),
    ("S9.1.3", "ci/vm/vm-guest.sh", r"\"EV-STATE: reading /proc/1/(environ|mem)",
     "the evidence's description of those two refusals, not a read"),
    ("S9.1.3", "ci/vm/vm-guest.sh", r"podman exec op-observer sh -c 'tr \"\\0\" \"\\n\" </proc/1/environ'",
     "op-observer is a client with its own pid namespace: its pid 1 is its own (S9.2.1's exception)"),
    ("S9.1.3", "ci/vm/vm-guest.sh", r"podman exec \"\$S773\" sh -c 'eval \"\$\(tr \"\\0\" \"\\n\" < /proc/1/environ",
     "a client container: its pid 1 is its own"),
    ("S9.1.3", "ci/vm/maint-guest.sh", r"^MT_UPC_ENV=",
     "run in a client container (MT_UPC): its pid 1 is its own"),
    ("S9.1.3", "ci/vm/operator-e2e.py", r"^CLIENT_SHOT = ",
     "run in a client container: its pid 1 is its own"),
    ("S9.1.3", "ci/vm/operator-e2e.py", r"/proc/1/environ \| grep '\^DISPLAY='",
     "run in op-observer, a client: its pid 1 is its own (S9.2.1's exception)"),
    ("S9.1.3", "ci/vm/maint-guest.sh", r"podman exec desktop ps -o pid,lstart,comm -C desktop-init,",
     "evidence only: the listing of the session's processes by name, read beside the pid file's"),
    ("S9.2.1", "ci/hw/acceptance.sh", r"\$DROPIN(_DIR)?\b",
     "S8.1.4: README.md's fallback when the toolkit lacks nvidia_drv.so, a quadlet drop-in of the .container's "
     "commented Volume= lines; written, and removed when the story ends"),
    ("S9.2.1", "ci/smoke-deploy.sh", r'"\$QL"',
     "S5.7.7: deploy/README.md's Host Terminal off-switch (the two Wants=/After= lines commented out), then the saved quadlet put back"),
    ("S9.2.1", "ci/vm/maint-guest.sh", r'"\$MT_PIN"',
     "S10.3.3: deploy/README.md's \"Overriding the image reference\" digest pin, a drop-in; written, then removed"),
    ("S9.2.1", "ci/vm/maint-guest.sh", r"sed -i -E 's/\^\(Wants\|After\)=desktop-host-shell",
     "S10.3.5: deploy/README.md's Host Terminal off-switch, as its \"Always on\" paragraph gives it"),
    ("S9.2.1", "ci/vm/vm-guest.sh", r"/etc/containers/systemd/desktop\.container\.d\b",
     "S5.2.6: deploy/README.md's \"Overriding the image reference\" drop-in (50-image.conf); written, then removed"),
    ("S9.2.1", "ci/preflight-rows.py", r"^/etc/containers/systemd/desktop\.container$",
     "the preflight's rows are staged in a private mount namespace (unshare -m): a tmpfs over desktop.container.d, not the host's quadlet"),
    # S9.2.6: the documented blocks the harness types for its own setup.
    # Each entry pins the block's digest and the lines typed: a change to
    # the block, or to what the harness types, stops it matching, and the
    # retype is flagged again for someone to judge.
    ("S9.2.6", "ci/smoke-deploy.sh",
     "^" + re.escape('deploy/README.md "Apply" [f3d059bc37]: rsync -a --chown=root:root deploy/host/ / | '
                     'systemctl daemon-reload') + "$",
     "the smoke's deploy on the runner, for its own stories, which cannot reboot it; the block runs as written "
     "in maint-guest.sh's mt_apply (S10.1.2)"),
    ("S9.2.6", "ci/smoke-deploy.sh",
     "^" + re.escape('README.md "Install" [ea8b2a10b4]: sudo rsync -a --chown=root:root deploy/host/ / | '
                     'sudo systemctl daemon-reload | sudo systemd-sysusers | sudo systemd-tmpfiles --create') + "$",
     "the same deploy: the block up to systemd-tmpfiles, whose failures on the runner's own entries it "
     "tolerates; the smoke starts the desktop after its own stories. The block runs as written in "
     "maint-guest.sh's mt_live readme (S10.1.4)"),
    ("S9.2.6", "ci/smoke-deploy.sh",
     "^" + re.escape('README.md "Fixed monitor layout (KVM video)" [425e0d716b]: DP-1 1920x1080@60 +0+0 primary | '
                     'DP-2 1920x1080@60 +1920+0') + "$",
     "S3.4.8's declared layout, which is README.md's example: the story checks that a host file reaches the "
     "container and is acted on, so any valid layout serves; the example is not a procedure"),
    ("S9.2.6", "ci/vm/vm-guest.sh",
     "^" + re.escape('deploy/README.md "Apply" [f3d059bc37]: rsync -a --chown=root:root deploy/host/ / | '
                     'systemctl daemon-reload') + "$",
     "phase_deploy, the VM shards' deploy: S5.1.1 (deploy_applied) checks that the block still reads rsync, "
     "daemon-reload and reboot, and names the steps phase_deploy adds harness-only; the reboot is the deploy "
     "tail's (S5.1.3). The block runs as written in maint-guest.sh's mt_apply (S10.1.2)"),
    ("S9.2.6", "ci/vm/vm-guest.sh",
     "^" + re.escape('README.md "Install" [ea8b2a10b4]: sudo rsync -a --chown=root:root deploy/host/ / | '
                     'sudo systemctl daemon-reload | sudo systemd-sysusers | sudo systemd-tmpfiles --create | '
                     'sudo systemctl start desktop.service') + "$",
     "the same deploy, which is this block with the harness's changes: tmpfiles' failures tolerated, sshd "
     "reloaded rather than try-reload-or-restart, S5.3.1's seat-prep run before the start. The block runs as "
     "written in maint-guest.sh's mt_live readme (S10.1.4)"),
    ("S9.2.6", ".github/workflows/ci.yml",
     "^" + re.escape('README.md "Base image vs application layer" [bfbac87260]: sudo podman build --network=none '
                     '-t localhost/screenshot:latest -f Containerfile.screenshot . | sudo podman build '
                     '--network=none -t localhost/desktop-container:latest -f Containerfile .') + "$",
     "the images under test: the block's two application-layer builds, typed. The bases come from "
     "ci/build-bases.sh's content-addressed cache, so the block's first two lines are replaced, not run. No "
     "story runs the block from the document: this entry, pinned to its digest, is its drift check"),
    ("S9.2.6", ".github/workflows/maintainer.yml",
     "^" + re.escape('README.md "Base image vs application layer" [bfbac87260]: sudo podman build --network=none '
                     '-t localhost/screenshot:latest -f Containerfile.screenshot . | sudo podman build '
                     '--network=none -t localhost/desktop-container:latest -f Containerfile .') + "$",
     "the same, for the maintainer journeys' images"),
    ("S9.3.1", "ci/hw/acceptance-tests.sh", r"S9\.9\.9",
     "a planted story id: the test's own fixture, in a scratch evidence root"),
]

# Where pipefail is on (S9.1.5). A file that sets it at top level has it on
# throughout (its functions run after the set line); a sourced library takes
# its sourcer's; these are checked against the tree (a missing source line is
# a finding), so the map cannot rot.
SOURCED_BY = {
    "ci/vm/maint-e2e.sh": ("ci/vm/vm-e2e.sh", r"maint-e2e\.sh"),
    "ci/vm/maint-guest.sh": ("ci/vm/vm-guest.sh", r"maint-guest\.sh"),
    "ci/evidence.sh": ("ci/vm/vm-e2e.sh", r"evidence\.sh"),
}
# A file that turns pipefail on part-way, by sourcing a file that sets it.
PIPEFAIL_FROM_LINE = {"ci/hw/acceptance-tests.sh": r'^\. "\$T/fns\.sh"'}

SSH_READERS = r"(?:vm_ssh_quick|vm_ssh|gqw|gq|guest_ev|ssh)"
NARROW_KEYS = {"name", "image", "imagePullPolicy", "command", "args", "resources", "workingDir"}

# --- reporting ------------------------------------------------------------------------


class Report:
    def __init__(self, allow):
        self.allow = [(r, f, re.compile(p), why) for r, f, p, why in allow]
        self.used = set()
        self.findings = []

    def flag(self, rule, path, line, text, what, fix):
        for n, (r, f, p, why) in enumerate(self.allow):
            if r == rule and f == path and p.search(text):
                self.used.add(n)
                self.findings.append(("allowed", rule, path, line, what, why))
                return
        self.findings.append(("VIOLATION", rule, path, line, what, fix))

    def ok(self, rule, path, line, what):
        self.findings.append(("ok", rule, path, line, what, ""))

    def violations(self, rule=None):
        return [f for f in self.findings if f[0] == "VIOLATION" and (rule is None or f[1] == rule)]

    def lines(self, rule):
        out = []
        for kind, r, path, line, what, extra in self.findings:
            if r != rule:
                continue
            where = f"{path}:{line}" if line else path
            if kind == "VIOLATION":
                out.append(f"VIOLATION {r} {where}: {what} -- {extra}")
            elif kind == "allowed":
                out.append(f"allowed   {r} {where}: {what} -- {extra}")
            else:
                out.append(f"ok        {r} {where}: {what}")
        return out


# --- the shell model ------------------------------------------------------------------


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def shell_files(root):
    out = []
    for path in sorted(glob.glob(os.path.join(root, "ci", "**", "*"), recursive=True)):
        rel = os.path.relpath(path, root)
        if not os.path.isfile(path) or "/artifacts/" in f"/{rel}" or "__pycache__" in rel:
            continue
        if rel.endswith(".sh"):
            out.append(rel)
            continue
        if "." not in os.path.basename(rel):
            try:
                first = read(path).split("\n", 1)[0]
            except OSError:
                continue
            if re.match(r"#!.*\b(ba)?sh\b", first):
                out.append(rel)
    return out


def workflow_runs(root):
    """(file, first line, text, pipefail-from-line or None) for each run: block."""
    out = []
    for path in sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml"))):
        rel = os.path.relpath(path, root)
        lines = read(path).split("\n")
        wf_shell = any(re.match(r"^\s*shell:\s*bash\s*$", l) for l in lines[:40])  # workflow defaults
        i = 0
        while i < len(lines):
            m = re.match(r"^(\s*)(?:-\s+)?run:\s*(\|[-+]?)?\s*(.*)$", lines[i])
            if not m:
                i += 1
                continue
            # the step: back to its "- " and on to the next sibling key at its indent
            j = i
            while j > 0 and not re.match(r"^\s*-\s", lines[j]):
                j -= 1
            step_ind = len(lines[j]) - len(lines[j].lstrip())
            k = i + 1
            while k < len(lines) and (not lines[k].strip() or len(lines[k]) - len(lines[k].lstrip()) > step_ind):
                k += 1
            step = lines[j:k]
            shell_bash = wf_shell or any(re.match(r"^\s*shell:\s*bash\s*$", l) for l in step)
            if m.group(2):
                body, start, ind = [], i + 2, None
                i += 1
                while i < len(lines):
                    l = lines[i]
                    if l.strip():
                        cur = len(l) - len(l.lstrip())
                        if ind is None:
                            ind = cur
                        if cur < ind:
                            break
                        body.append(l[ind:])
                    else:
                        body.append("")
                    i += 1
                text = "\n".join(body)
            else:
                start, text = i + 1, m.group(3)
                i += 1
            pf = 1 if shell_bash else None
            if pf is None:
                for n, l in enumerate(text.split("\n")):
                    if re.match(r"^\s*set\s+(-[a-zA-Z]*o\s+pipefail|(-[a-zA-Z]+\s+)*-o\s+pipefail)\b", l):
                        pf = n + 1
                        break
            out.append((rel, start, text, pf))
    return out


class Pipe:
    def __init__(self, line, producer, reader):
        self.line, self.producer, self.reader = line, producer, reader


def cut_command(src, i):
    """The command starting at src[i]: up to the first unquoted | ; & newline
    or unbalanced ), line continuations joined."""
    j, q, depth = i, None, 0
    while j < len(src):
        c = src[j]
        if q:
            if c == "\\" and q == '"':
                j += 2
                continue
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "\\":
            j += 2
            continue
        elif c in "({":
            depth += 1
        elif c in ")}":
            if depth == 0:
                break
            depth -= 1
        elif c in "|;&\n" and depth == 0:
            break
        j += 1
    return re.sub(r"\\\n", " ", src[i:j])


KEYWORDS = r"(?:!|if|then|elif|else|do|while|until|time|\{|\(|\)|exec|command|sudo|local|export)"
WRAPPERS = r"(?:exec|command|sudo|env|nice)"


def strip_prefix(cmd, keywords=KEYWORDS):
    """A command without its leading keywords (a producer's: if, !, while...;
    a reader keeps its own while) and NAME=value assignments."""
    prev = None
    cmd = cmd.strip()
    while prev != cmd:
        prev = cmd
        cmd = re.sub(rf"^(?:{keywords}\s+|[A-Za-z_]\w*=(?:\"[^\"]*\"|'[^']*'|\S*)\s+|timeout\s+\S+\s+)", "", cmd).strip()
    return cmd


def early_reader(reader, after):
    """Why this reader may stop before EOF, or None. `after` is the source
    from the reader on (to find a loop's end)."""
    r = strip_prefix(reader, WRAPPERS)
    m = re.match(r"(\S+)\s*(.*)$", r, re.S)
    if not m:
        return None
    cmd, rest = os.path.basename(m.group(1)), m.group(2)
    if cmd in ("grep", "egrep", "fgrep", "zgrep"):
        toks = re.findall(r"(?:'[^']*'|\"(?:\\.|[^\"])*\"|[^\s'\"])+", rest)
        skip = False
        for t in toks:
            if skip:
                skip = False
                continue
            if t == "--" or not t.startswith("-"):
                break
            if t.startswith("--"):
                if re.match(r"--(quiet|silent|max-count|files-with)", t):
                    return f"grep {t}"
                if t in ("--regexp", "--file"):
                    skip = True
                continue
            flags = t[1:]
            for n, ch in enumerate(flags):
                if ch in "ef":       # -e PATTERN / -f FILE: the rest is its value
                    skip = n == len(flags) - 1
                    break
                if ch in "qmlL":
                    return f"grep {t}"
        return None
    if cmd == "head":
        if re.search(r"(^|\s)(-n\s*-|--lines=-|-c\s*-|--bytes=-)", rest):
            return None
        return "head"
    if cmd == "sed":
        if re.search(r"(^|[\s;{}'\"/])[qQ]([\s;}'\"]|\d|$)", rest):
            return "sed ...q"
        return None
    if cmd in ("awk", "gawk"):
        if re.search(r"\bexit\b", rest):
            return "awk ...exit"
        return None
    if cmd == "read" or (cmd == "{" and re.match(r"\s*(IFS=\S*\s+)?read\b", rest)):
        return "read"
    if cmd == "cmp":
        return "cmp"
    if cmd in ("while", "until"):
        body, depth = after, 0
        for w in re.finditer(r"\b(do|done)\b", body):
            if w.group(1) == "do":
                depth += 1
            else:
                depth -= 1
                if depth <= 0:
                    body = body[:w.start()]
                    break
        if re.search(r"\b(break|exit|return)\b", body):
            return f"a {cmd} loop that breaks"
        return None
    if cmd in ("python3", "python"):
        if re.search(r"\bbreak\b|sys\.exit|\bexit\(", after[:2000]):
            return "python that stops reading"
        return None
    return None


# A print of a variable already captured is the requirement's own remedy: the
# shell writes the value at once, and no live process is left to be killed.
# (Past the 64 KiB pipe buffer a reader that has stopped could still cut the
# write short: an audit measured 0 failures in 300 up to 16 KiB, 2 at 60 KiB.
# What is printed this way here is a command's short output.)
PRINT_OF_VARIABLE = re.compile(
    r"""^(?:printf\s+(?:'[^']*'|"[^"$`]*")|echo(?:\s+-[neE]+)?)"""
    r"""(?:\s+(?:"\$(?:\{[^}]*\}|\w+)"|'[^']*'|"[^"$`]*"))+\s*$""")


def shell_pipes(src, base=1):
    """Every pipe in shell code (not inside a quoted string, a comment or a
    heredoc body): (line, producer text, reader text)."""
    out = []
    n = len(src)
    # frame: [kind, depth, cmd_start, group_starts, case_depth]
    stack = [["C", 0, 0, [], 0]]
    line = base
    i = 0
    word_start = True
    heredocs = []

    def code_frame():
        return stack[-1][0] in ("C", "B")

    while i < n:
        c = src[i]
        fr = stack[-1]
        kind = fr[0]
        if c == "\n":
            line += 1
            if kind in ("C", "B") and heredocs:
                j = i + 1
                for strip, delim, quoted in heredocs:
                    while j < n:
                        k = src.find("\n", j)
                        k = n if k < 0 else k
                        body = src[j:k]
                        if not quoted:
                            for m in re.finditer(r"\$\(", body):
                                # $(...) in an unquoted heredoc runs in this shell
                                inner = body[m.end():]
                                d, e = 1, 0
                                while e < len(inner) and d:
                                    d += {"(": 1, ")": -1}.get(inner[e], 0)
                                    e += 1
                                for p in shell_pipes(inner[:max(e - 1, 0)], line + 1):
                                    out.append(p)
                        j = k + 1
                        line += 1
                        if (body.lstrip("\t") if strip else body) == delim:
                            break
                heredocs = []
                i = j
                fr[2] = i
                word_start = True
                continue
            if kind in ("C", "B"):
                # a newline ends a command, unless a pipe or && || left it open
                prev = src[:i].rstrip(" \t")
                if not prev.endswith(("|", "&&", "\\")):
                    fr[2] = i + 1
            i += 1
            word_start = True
            continue
        if kind == "S":
            if c == "'":
                stack.pop()
            i += 1
            continue
        if kind == "A":
            if c == "\\":
                i += 2
                continue
            if c == "'":
                stack.pop()
            i += 1
            continue
        if kind == "D":
            if c == "\\":
                if i + 1 < n and src[i + 1] == "\n":
                    line += 1
                i += 2
                continue
            if c == '"':
                stack.pop()
                i += 1
                continue
            if src.startswith("$((", i):
                stack.append(["R", 0, 0, [], 0])
                i += 3
                continue
            if src.startswith("$(", i):
                stack.append(["C", 0, i + 2, [], 0])
                i += 2
                word_start = True
                continue
            if src.startswith("${", i):
                stack.append(["P", 0, 0, [], 0])
                i += 2
                continue
            if c == "`":
                stack.append(["B", 0, i + 1, [], 0])
                i += 1
                continue
            i += 1
            continue
        if kind == "P":
            if c == "\\":
                i += 2
                continue
            if c == "{":
                fr[1] += 1
            elif c == "}":
                if fr[1] == 0:
                    stack.pop()
                else:
                    fr[1] -= 1
            elif c == '"':
                stack.append(["D", 0, 0, [], 0])
            elif c == "'" and not src.startswith("'", i - 1):
                pass
            i += 1
            continue
        if kind == "R":
            if c == "(":
                fr[1] += 1
            elif c == ")":
                if fr[1] == 0:
                    stack.pop()
                    i += 2
                    continue
                fr[1] -= 1
            elif src.startswith("$(", i) and not src.startswith("$((", i):
                stack.append(["C", 0, i + 2, [], 0])
                i += 2
                continue
            i += 1
            continue
        # code: C or B
        if c == "\\":
            if i + 1 < n and src[i + 1] == "\n":
                line += 1
            i += 2
            word_start = False
            continue
        if kind == "B" and c == "`":
            stack.pop()
            i += 1
            word_start = False
            continue
        if c == "#" and word_start:
            k = src.find("\n", i)
            i = n if k < 0 else k
            continue
        if word_start:
            w = re.match(r"(case|esac|\{|\})(?=[\s;]|$)", src[i:])
            if w:
                if w.group(1) == "case":
                    fr[4] += 1
                elif w.group(1) == "esac":
                    fr[4] = max(0, fr[4] - 1)
                elif w.group(1) == "{":
                    fr[3].append(i)
                    fr[2] = i + 1
                elif w.group(1) == "}":
                    fr[2] = fr[3].pop() if fr[3] else fr[2]
                i += 1
                word_start = False
                continue
        if src.startswith("$'", i):
            stack.append(["A", 0, 0, [], 0])
            i += 2
            word_start = False
            continue
        if c == "'":
            k = src.find("'", i + 1)
            k = n if k < 0 else k
            line += src[i:k].count("\n")
            i = k + 1
            word_start = False
            continue
        if c == '"':
            stack.append(["D", 0, 0, [], 0])
            i += 1
            word_start = False
            continue
        if c == "`":
            stack.append(["B", 0, i + 1, [], 0])
            i += 1
            continue
        if src.startswith("$((", i) or (word_start and src.startswith("((", i)):
            stack.append(["R", 0, 0, [], 0])
            i += 3 if src[i] == "$" else 2
            continue
        if src.startswith("$(", i):
            stack.append(["C", 0, i + 2, [], 0])
            i += 2
            word_start = True
            continue
        if src.startswith("${", i):
            stack.append(["P", 0, 0, [], 0])
            i += 2
            continue
        if src.startswith("<<<", i):
            i += 3
            continue
        if src.startswith("<<", i):
            m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", src[i:])
            if m:
                heredocs.append((m.group(1) == "-", m.group(3), bool(m.group(2))))
                i += m.end()
                continue
        if c == "(":
            fr[1] += 1
            fr[3].append(i)
            fr[2] = i + 1
            i += 1
            word_start = True
            continue
        if c == ")":
            if fr[1] > 0:
                fr[1] -= 1
                fr[2] = fr[3].pop() if fr[3] else fr[2]
            elif fr[4] > 0:
                pass                                  # a case pattern's )
            elif len(stack) > 1:
                stack.pop()
            i += 1
            word_start = False
            continue
        if c in ";&":
            j = i + 1
            while j < n and src[j] in ";&":
                j += 1
            fr[2] = j
            i = j
            word_start = True
            continue
        if c == "|":
            if src.startswith("||", i):
                fr[2] = i + 2
                i += 2
                word_start = True
                continue
            j = i + 2 if src.startswith("|&", i) else i + 1
            k = j
            while k < n and src[k] in " \t\n" or src.startswith("\\\n", k):
                k += 2 if src.startswith("\\\n", k) else 1
            reader = cut_command(src, k)
            producer = src[fr[2]:i]
            if fr[4] > 0 and re.match(r"\s*[^\s;&|()]*\)", reader):
                pass                                  # a | between case patterns
            else:
                out.append(Pipe(line, producer, reader).__dict__ | {"after": src[k:k + 4000]})
            fr[2] = j
            i = j
            word_start = True
            continue
        word_start = c in " \t"
        i += 1
    return out


def pipefail_lines(root, rel, text):
    """The first line from which pipefail is on in this file, or None."""
    if rel in PIPEFAIL_FROM_LINE:
        for n, l in enumerate(text.split("\n")):
            if re.search(PIPEFAIL_FROM_LINE[rel], l):
                return n + 1
        return None
    if rel in SOURCED_BY:
        sourcer, _ = SOURCED_BY[rel]
        if os.path.exists(os.path.join(root, sourcer)):
            return 1 if pipefail_lines(root, sourcer, read(os.path.join(root, sourcer))) else None
    for n, l in enumerate(text.split("\n")):
        if re.match(r"^\s*set\s+(-[a-zA-Z]*o\s+pipefail|(-[a-zA-Z]+\s+)*-o\s+pipefail)\b", l):
            return 1 if not l.startswith((" ", "\t")) else n + 1
    return None


# --- the rules ------------------------------------------------------------------------


def rule_s915(root, rep):
    """S9.1.5: no early-exiting reader on a live pipeline under pipefail."""
    units = []
    for rel in shell_files(root):
        units.append((rel, 1, read(os.path.join(root, rel)), None))
    for rel, start, text, pf in workflow_runs(root):
        units.append((rel, start, text, pf if pf is None else start + pf - 1))
    for rel, (sourcer, pattern) in SOURCED_BY.items():
        if os.path.exists(os.path.join(root, rel)) and os.path.exists(os.path.join(root, sourcer)):
            if not re.search(pattern, read(os.path.join(root, sourcer))):
                rep.flag("S9.1.5", rel, 0, "", f"{sourcer} no longer sources it", "update SOURCED_BY")
    read_files = 0
    pipes = 0
    for rel, start, text, pf in units:
        if pf is None and not rel.endswith(".yml"):
            first = pipefail_lines(root, rel, text)
            pf = first
        read_files += 1
        if pf is None:
            continue
        for p in shell_pipes(text, start):
            if p["line"] < pf:
                continue
            why = early_reader(p["reader"], p["after"])
            if not why:
                continue
            pipes += 1
            producer = strip_prefix(p["producer"])
            shown = f"{' '.join(producer.split())[:70]} | {' '.join(p['reader'].split())[:50]}"
            if PRINT_OF_VARIABLE.match(producer):
                rep.ok("S9.1.5", rel, p["line"], f"{shown} (prints a captured variable)")
                continue
            line_text = text.split("\n")[p["line"] - start] if 0 <= p["line"] - start < len(text.split("\n")) else ""
            rep.flag("S9.1.5", rel, p["line"], line_text, f"{shown} ({why})",
                     "capture the producer's output first, then read the variable")
    return f"S9.1.5: {read_files} shell file(s) and workflow block(s) read; {pipes} pipe(s) into an early reader under pipefail; {len(rep.violations('S9.1.5'))} violation(s)"


def rule_s913(root, rep):
    """S9.1.3: the desktop's processes through /run/desktop-init.pid."""
    files = shell_files(root) + [os.path.relpath(p, root) for p in sorted(glob.glob(os.path.join(root, "ci", "**", "*.py"), recursive=True))]
    seen = 0
    for rel in files:
        if rel == "ci/e9-guard.py":
            continue
        for n, l in enumerate(read(os.path.join(root, rel)).split("\n"), 1):
            code = l.split("#", 1)[0] if not rel.endswith(".py") else l
            if rel.endswith(".py") and l.lstrip().startswith("#"):
                continue
            if re.search(r"/proc/1(?![0-9])|\bpidof\b|\bpgrep\b[^\n]*desktop-init|\bps\b[^\n]*-C\s+\S*desktop-init", code):
                seen += 1
                rep.flag("S9.1.3", rel, n, l.strip(), " ".join(l.split())[:110],
                         "read the desktop's processes through /run/desktop-init.pid")
    return f"S9.1.3: {len(files)} file(s) read; {seen} read(s) of pid 1 or by name; {len(rep.violations('S9.1.3'))} violation(s)"


def rule_s924(root, rep):
    """S9.2.4: a count read from the guest is an integer or a failed read,
    never a number standing in for one."""
    seen = 0
    fix = "fail, or retry, on a failed read (host_count, read_pair, guest_count)"
    for rel in shell_files(root):
        text = read(os.path.join(root, rel))
        lines = text.split("\n")
        # Each line's scope: the function it is in (a name reused in another
        # function is another variable), or the file's top level.
        scope, cur = [], "<top>"
        for l in lines:
            m = re.match(r"^([A-Za-z_][\w-]*)\s*\(\)\s*\{\s*(#.*)?$", l)
            if m:
                cur = m.group(1)
            scope.append(cur)
            if cur != "<top>" and re.match(r"^\}\s*(#.*)?$", l):
                cur = "<top>"
        raw = {}
        for m in re.finditer(rf"(?:^|[\s;&|(])(?:local\s+)?([A-Za-z_]\w*)=\$\(\s*(?:[A-Z_]+=\S+\s+)*{SSH_READERS}\b", text):
            start = text.rfind("$(", 0, m.end())
            d, e = 1, start + 2
            while e < len(text) and d:
                d += {"(": 1, ")": -1}.get(text[e], 0)
                e += 1
            at = text.count("\n", 0, m.start(1)) + 1
            shown = " ".join(lines[at - 1].split())[:90]
            dflt = re.search(r"\|\|\s*(?:echo|printf)\s+['\"]?(-?\d+)\b", text[start:e])
            if dflt:
                seen += 1
                rep.flag("S9.2.4", rel, at, lines[at - 1].strip(),
                         f"${m.group(1)} is read over ssh with {dflt.group(1)} standing in for a failed read: {shown}", fix)
                continue
            if re.match(r"\s*\|\|\s*(fail|exit|return)\b", text[e:e + 40]):
                seen += 1
                rep.ok("S9.2.4", rel, at, f"${m.group(1)} is read over ssh, and a failed read fails: {shown}")
                continue
            raw[(scope[at - 1], m.group(1))] = at
        for (sc, name), at in raw.items():
            use = re.compile(rf"\"?\$\{{?{name}\b[^\"\s]*\"?\s+-(eq|ne|lt|le|gt|ge)\b"
                             rf"|-(eq|ne|lt|le|gt|ge)\s+\"?\$\{{?{name}\b"
                             rf"|\$\(\([^)]*(?<![\w%])\$?{name}\b|^\s*\(\([^)]*(?<![\w%])\$?{name}\b")
            for n, l in enumerate(lines, 1):
                if n <= at or scope[n - 1] != sc or not use.search(l):
                    continue
                seen += 1
                shown = " ".join(l.split())[:80]
                if re.search(rf"-n\s+\"\$\{{?{name}\b", l):
                    rep.ok("S9.2.4", rel, n, f"${name}, read over ssh at line {at}, is tested for presence before it is compared: {shown}")
                    continue
                d = re.search(rf"\$\{{{name}:-(-?\d+)", l)
                if d:
                    rep.flag("S9.2.4", rel, n, l.strip(),
                             f"${name}, read over ssh at line {at}, is compared with {d.group(1)} standing in for a failed read: {shown}", fix)
                    continue
                rep.flag("S9.2.4", rel, n, l.strip(), f"${name}, read over ssh at line {at}, is compared as a number unchecked: {shown}", fix)
    for path in sorted(glob.glob(os.path.join(root, "ci", "**", "*.py"), recursive=True)):
        rel = os.path.relpath(path, root)
        try:
            tree = ast.parse(read(path), rel)
        except SyntaxError:
            continue
        for fn in ast.walk(tree):
            if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue
            from_sh = set()
            for node in ast.walk(fn):
                if isinstance(node, ast.Assign) and any(isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr == "sh"
                                                        for c in ast.walk(node.value)):
                    from_sh |= {t.id for t in node.targets if isinstance(t, ast.Name)}
            for node in ast.walk(fn):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "int" and node.args):
                    continue
                arg = node.args[0]
                reads = any(isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr == "sh" for c in ast.walk(arg)) \
                    or any(isinstance(c, ast.Name) and c.id in from_sh for c in ast.walk(arg))
                if not reads:
                    continue
                seen += 1
                shown = " ".join(ast.unparse(node).split())[:90]
                handlers = []
                for t in ast.walk(fn):
                    if isinstance(t, ast.Try) and any(node in list(ast.walk(b)) for b in t.body):
                        handlers += [h for h in t.handlers
                                     if h.type is None or re.search(r"ValueError|RuntimeError|Exception", ast.unparse(h.type))]
                if not handlers:
                    rep.flag("S9.2.4", rel, node.lineno, shown, f"int() of a guest read, with no try: {shown}", fix)
                    continue
                # A handler that yields a number makes it stand in for the read.
                stand_in = [x for h in handlers for x in ast.walk(h)
                            if isinstance(x, (ast.Return, ast.Assign)) and isinstance(x.value, ast.Constant)
                            and isinstance(x.value.value, (int, float)) and not isinstance(x.value.value, bool)]
                if stand_in:
                    rep.flag("S9.2.4", rel, node.lineno, shown,
                             f"int() of a guest read whose failure yields {stand_in[0].value.value!r}: {shown}", fix)
                else:
                    rep.ok("S9.2.4", rel, node.lineno, f"int() of a guest read, its failure caught and not turned into a number: {shown}")
    return f"S9.2.4: {seen} read(s) or numeric use(s) of a guest read judged; {len(rep.violations('S9.2.4'))} violation(s)"


def defined_stories(root):
    head = re.compile(r"^\*\*(S\d+\.\d+\.\d+)\s")
    return {m.group(1) for l in read(os.path.join(root, "Requirements.md")).split("\n") if (m := head.match(l))}


def rule_s931(root, rep):
    """S9.3.1: every story begun is defined; the evidence check fails what it must."""
    defined = defined_stories(root)
    begun = 0
    for rel in shell_files(root):
        for n, l in enumerate(read(os.path.join(root, rel)).split("\n"), 1):
            for m in re.finditer(r"\b(?:ev_begin|story_begin|mt_begin)\s+[\"']?(S\d+\.\d+\.\d+)\b", l):
                begun += 1
                if m.group(1) not in defined:
                    rep.flag("S9.3.1", rel, n, l, f"{m.group(1)} begun, but Requirements.md defines no such story", "fix the id")
    for path in sorted(glob.glob(os.path.join(root, "ci", "**", "*.py"), recursive=True)):
        rel = os.path.relpath(path, root)
        if rel == "ci/e9-guard.py":
            continue
        try:
            tree = ast.parse(read(path), rel)
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and re.fullmatch(r"S\d+\.\d+\.\d+", node.value):
                begun += 1
                if node.value not in defined:
                    rep.flag("S9.3.1", rel, node.lineno, node.value, f"the story id {node.value!r}, which Requirements.md does not define", "fix the id")
    # The evidence check on planted directories.
    spec = importlib.util.spec_from_file_location("evlib", os.path.join(root, "ci", "evlib.py"))
    evlib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(evlib)
    with tempfile.TemporaryDirectory(dir=os.environ.get("RUNNER_TEMP")) as d:
        def story(name, mutate=None):
            st = evlib.StoryWriter(os.path.join(d, name), "S9.3.1", "planted", "T0", "e9-guard.py")
            st.write("state", "a state\n", "EV-STATE: a planted file")
            st.check(True, "a planted check")
            st.finish()
            sd = os.path.join(d, name, "S9.3.1")
            if mutate:
                mutate(sd)
            return sd
        files = lambda sd: sorted(f for f in os.listdir(sd) if re.match(r"\d\d-", f))
        cases = [
            ("a complete story", None, False),
            ("an indexed file missing", lambda sd: os.remove(os.path.join(sd, files(sd)[0])), True),
            ("an indexed file empty", lambda sd: open(os.path.join(sd, files(sd)[0]), "w").close(), True),
            ("a file nothing indexes", lambda sd: open(os.path.join(sd, "99-stray.txt"), "w").write("x\n"), True),
            ("no result", lambda sd: os.remove(os.path.join(sd, "result")), True),
            ("no evidence.md", lambda sd: os.remove(os.path.join(sd, "evidence.md")), True),
        ]
        for n, (what, mutate, want) in enumerate(cases):
            sd = story(f"case{n}", mutate)
            problems = evlib.check_dir(sd)
            if bool(problems) == want:
                rep.ok("S9.3.1", "ci/evlib.py", 0, f"check_dir on {what}: {'; '.join(problems) or 'no problem'}")
            else:
                rep.flag("S9.3.1", "ci/evlib.py", 0, what, f"check_dir on {what}: {'; '.join(problems) or 'no problem'}",
                         "the evidence check must fail an incomplete directory and pass a complete one")
    return f"S9.3.1: {begun} story id(s) begun in the harness, 6 planted evidence directories judged; {len(rep.violations('S9.3.1'))} violation(s)"


def pod_containers(text):
    """[(container name, {key: first line}, {resource: count})] of a pod
    manifest, read by indentation (no YAML library on the runner needed)."""
    lines = [l.split("#", 1)[0].rstrip() if not l.lstrip().startswith("-") or "#" not in l else l.split(" #", 1)[0].rstrip()
             for l in text.split("\n")]
    out = []
    for i, l in enumerate(lines):
        if re.match(r"^\s*containers:\s*$", l):
            base = len(l) - len(l.lstrip())
            j, cur = i + 1, None
            while j < len(lines):
                s = lines[j]
                if not s.strip():
                    j += 1
                    continue
                ind = len(s) - len(s.lstrip())
                if ind <= base and not s.lstrip().startswith("-"):
                    break
                m = re.match(r"^(\s*)-\s+(\w+):\s*(.*)$", s)
                if m and (cur is None or len(m.group(1)) == cur["dash"]):
                    cur = {"dash": len(m.group(1)), "keyind": len(m.group(1)) + 2, "keys": {m.group(2): j + 1},
                           "name": m.group(3) if m.group(2) == "name" else "?", "res": {}}
                    out.append(cur)
                elif cur is not None:
                    k = re.match(r"^(\s*)(\w[\w.-]*):\s*(.*)$", s)
                    if k and len(k.group(1)) == cur["keyind"]:
                        cur["keys"].setdefault(k.group(2), j + 1)
                        if k.group(2) == "name":
                            cur["name"] = k.group(3)
                    r = re.match(r"^\s*(desktop\.local/\w+):\s*(\d+)", s)
                    if r:
                        cur["res"][r.group(1)] = int(r.group(2))
                j += 1
    return out


def rule_s922(root, rep):
    """S9.2.2: narrow fixtures stay narrow; pods declare nothing but requests."""
    paths = sorted(glob.glob(os.path.join(root, "examples", "*.yaml")) + glob.glob(os.path.join(root, "ci", "vm", "*-pod.yaml")))
    for path in paths:
        rel = os.path.relpath(path, root)
        text = read(path)
        if not re.search(r"^kind:\s*Pod\b", text, re.M):
            continue
        body = [l.split("#", 1)[0] for l in text.split("\n")]
        for n, l in enumerate(body, 1):
            for key in ("securityContext", "volumes", "hostNetwork", "hostPID", "hostIPC", "annotations"):
                if re.match(rf"^\s*{key}:", l):
                    rep.flag("S9.2.2", rel, n, l, f"the pod declares {key}", "a client pod declares nothing but requests")
        cs = pod_containers(text)
        if not cs:
            rep.flag("S9.2.2", rel, 0, "", "no container found", "check the manifest")
        for c in cs:
            extra = sorted(set(c["keys"]) - NARROW_KEYS)
            for k in extra:
                rep.flag("S9.2.2", rel, c["keys"][k], k, f"container {c['name']} declares {k}", "a client pod declares nothing but requests")
            if os.path.basename(rel).endswith("-only-pod.yaml"):
                if len(c["res"]) != 1:
                    rep.flag("S9.2.2", rel, 0, "", f"container {c['name']} requests {sorted(c['res']) or 'nothing'}; a narrow fixture requests exactly one desktop.local resource",
                             "request only the one resource the fixture is named for")
                else:
                    rep.ok("S9.2.2", rel, 0, f"narrow: container {c['name']} requests only {next(iter(c['res']))}")
            if not extra:
                rep.ok("S9.2.2", rel, 0, f"container {c['name']}: {', '.join(sorted(c['keys']))}; requests {', '.join(f'{k}={v}' for k, v in sorted(c['res'].items())) or 'none'}")
    return f"S9.2.2: {len(paths)} manifest(s) read; {len(rep.violations('S9.2.2'))} violation(s)"


CDI_GENERATORS = ["deploy/host/usr/local/libexec/desktop-client-cdi",
                  "deploy/host/usr/local/libexec/desktop-tools-cdi",
                  "deploy/host/usr/local/libexec/desktop-cdi-refresh"]
# The host's quadlet directory, not the deploy tree's copy of it
# (deploy/host/etc/containers/systemd).
QUADLET = re.compile(r"(?<![\w.~-])/etc/containers/systemd\b")
REDIRECT = re.compile(r"^(?:\d*|&)>>?\|?(.*)$")
PREFIXES = {"sudo", "env", "exec", "command", "nice", "nohup", "time", "!", "{",
            "if", "then", "elif", "else", "while", "until", "do"}
WRAPPERS_WITH_OPTIONS = {"sudo", "env", "nice", "nohup", "exec", "command"}
EVERY_OPERAND = {"rm", "rmdir", "mkdir", "touch", "truncate", "tee", "chmod", "chown", "chcon", "unlink"}
LAST_OPERAND = {"cp", "install", "ln", "rsync"}
# The harness's functions that run a command after arguments of their own.
RUNNERS = {"ev_save": 2, "ev_check": 1, "wait_for": 3}
# podman run/create/exec options that take no value; every other one does.
BOOL_OPTS = {"--rm", "--detach", "--interactive", "--tty", "--privileged", "--init", "--replace",
             "--read-only", "--quiet", "--latest", "--rmi", "--no-hosts"}


def client_guard():
    """ci/client-guard.py, beside this file: its tokenizer reads the shell the
    way the shell does, and its S7.1.2 checks are part of S9.2.1."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "client-guard.py")
    spec = importlib.util.spec_from_file_location("client_guard", path)
    cg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cg)
    return cg


def cdi_edits(root, rep):
    """{device kind: (env names, container paths)}: the edits of the specs the
    CDI generators write. An -e or a -v of one, on a container that requests
    that kind, duplicates a CDI edit."""
    out = {}
    for gen in CDI_GENERATORS:
        p = os.path.join(root, gen)
        if not os.path.exists(p):
            rep.flag("S9.2.1", gen, 0, "", "a CDI generator is missing, so its edits go unchecked", "update CDI_GENERATORS")
            continue
        text = read(p)
        assigned = dict(re.findall(r'^([A-Z_][A-Z0-9_]*)="?([^"\s]*)"?\s*$', text, re.M))

        def res(v):
            return assigned.get(v.strip("${}"), v) if v.startswith("$") else v
        kind = None
        for l in text.split("\n"):
            m = re.match(r"^kind:\s*(\S+)\s*$", l)
            if m:
                kind = res(m.group(1))
                out.setdefault(kind, (set(), set()))
            elif l.strip() == "EOF":
                kind = None
            elif kind:
                e = re.match(r"^\s*-\s*(\$?\{?[A-Za-z_]\w*\}?)=", l)
                if e:
                    out[kind][0].add(res(e.group(1)))
                c = re.match(r"^\s*containerPath:\s*(\S+)\s*$", l)
                if c:
                    out[kind][1].add(res(c.group(1)).rstrip("/"))
    return out


def token_lists(cg, toks, held, depth=0, extra=None):
    """A command's tokens, and those of every quoted string in it that holds
    a command line of its own (ssh, sh -c, undo_later's, a description that
    names one: the same line either way)."""
    yield toks
    if depth > 2:
        return
    for t in toks:
        if re.search(r"\s", t) and (re.search(r"\b(podman|setenforce)\b", t) or QUADLET.search(t)
                                    or (extra is not None and extra.search(t))
                                    or any(re.search(rf"\$\{{?{h}\b", t) for h in held)):
            try:
                sub = cg.tokens(t)
            except ValueError:
                continue
            yield from token_lists(cg, sub, held, depth + 1, extra)


def simple_commands(cg, toks):
    cur = []
    for t in toks:
        if t in cg.OPS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(t)
    if cur:
        yield cur


def command_word(words):
    """A simple command's verb and arguments, past sudo, env, timeout N, a
    VAR=value and the like."""
    k, wrapper = 0, False
    while k < len(words):
        w = words[k]
        if w in PREFIXES or re.match(r"^[A-Za-z_]\w*=", w):
            wrapper = w in WRAPPERS_WITH_OPTIONS
            k += 1
        elif w == "timeout":
            k += 1
            while k < len(words) and words[k].startswith("-"):
                k += 2 if words[k] in ("-s", "-k", "--signal", "--kill-after") else 1
            k += 1
        elif wrapper and w.startswith("-"):
            k += 2 if w in ("-u", "-g", "-n", "--user", "--group") else 1
        elif w in RUNNERS:
            k += 1 + RUNNERS[w]            # the harness's own: the command follows its arguments
            wrapper = False
        else:
            return os.path.basename(w), words[k + 1:]
    return "", []


def write_targets(words):
    """What a simple command writes: its redirections' targets, and the
    operands a write verb changes (cp's last, sed -i's files, ...)."""
    out, rest, k = [], [], 0
    while k < len(words):
        m = REDIRECT.match(words[k])
        if m:
            target = m.group(1)
            if not target and k + 1 < len(words):
                k += 1
                target = words[k]
            if target and not target.startswith("&"):
                out.append(target)
        else:
            rest.append(words[k])
        k += 1
    verb, args = command_word(rest)
    operands = [a for a in args if not a.startswith("-")]
    if verb in EVERY_OPERAND or verb == "mv":     # mv writes its source too: it is gone
        out += operands
    elif verb in LAST_OPERAND:
        out += operands[-1:] + [args[n + 1] for n, a in enumerate(args[:-1]) if a in ("-t", "--target-directory")]
    elif verb == "sed" and any(a == "--in-place" or a.startswith("--in-place=") or re.match(r"^-[a-zA-Z]*i", a) for a in args):
        out += operands
    elif verb == "dd":
        out += [a[3:] for a in args if a.startswith("of=")]
    return out


def quadlet_holders(text):
    """Variables that hold a path under the quadlet directory: assigned one,
    or built on such a variable."""
    held = set(re.findall(r"^\s*(?:local\s+|readonly\s+)?([A-Za-z_]\w*)=[\"']?/etc/containers/systemd\b", text, re.M))
    built = re.findall(r"^\s*(?:local\s+|readonly\s+)?([A-Za-z_]\w*)=[\"']?\$\{?(\w+)\}?/", text, re.M)
    for _ in range(3):
        held |= {name for name, base in built if base in held}
    return held


def pid1_reads(text):
    """{VAR: its command substitution} for each VAR=$(...) that reads
    /proc/1/environ."""
    out = {}
    for m in re.finditer(r"(?:^|[\s;&|(])(?:local\s+)?([A-Za-z_]\w*)=\$\(", text):
        d, e = 1, m.end()
        while e < len(text) and d:
            d += {"(": 1, ")": -1}.get(text[e], 0)
            e += 1
        body = text[m.end():e - 1]
        if "/proc/1/environ" in body:
            out[m.group(1)] = body
    return out


def podman_calls(cg, toks):
    """(verb, args) of each podman run/create/exec in a token list."""
    for k, t in enumerate(toks):
        if (t == "podman" or t.endswith("/podman")) and k + 1 < len(toks) and toks[k + 1] in ("run", "create", "exec"):
            args = []
            for a in toks[k + 2:]:
                if a in cg.OPS:
                    break
                args.append(a)
            yield toks[k + 1], args


def podman_options(verb, args):
    """A podman run/create/exec argument list's options, as (name, value)
    pairs, and its operand: the image, or the container exec runs in. What
    follows the operand is the command's own (its -e is not podman's)."""
    shorts = "ditl" if verb == "exec" else "ditq"
    opts, k = [], 0
    while k < len(args):
        a = args[k]
        if a == "--":
            return opts, (args[k + 1] if k + 1 < len(args) else None)
        if not a.startswith("-") or a == "-":
            return opts, a
        if a.startswith("--") and "=" in a:
            opts.append(tuple(a.split("=", 1)))
        elif a in BOOL_OPTS or re.fullmatch(rf"-[{shorts}]+", a):
            opts.append((a, None))
        elif re.fullmatch(r"-[a-zA-Z]|--[\w-]+", a):
            opts.append((a, args[k + 1] if k + 1 < len(args) else None))
            k += 1
        else:
            opts.append((a[:2], a[2:]))          # -eNAME=value: a short option's value attached
        k += 1
    return opts, None


def mount_dest(opt, value):
    if opt == "--mount":
        m = re.search(r"(?:^|,)(?:dst|destination|target)=([^,]+)", value)
        return m.group(1) if m else ""
    parts = value.split(":")
    return parts[1] if len(parts) > 1 else parts[0]


def shell_units(root):
    """(file, first line, text) of each shell file and workflow run: block."""
    for rel in shell_files(root):
        yield rel, 1, read(os.path.join(root, rel))
    for rel, start, text, _ in workflow_runs(root):
        yield rel, start, text


def rule_s921(root, rep):
    """S9.2.1: nothing weakens the system under test."""
    cg = client_guard()
    edits = cdi_edits(root, rep)
    all_env = set().union(*(e[0] for e in edits.values())) if edits else set()
    commands = units = 0
    seen = set()

    def flag(rel, line, text, what, fix):
        if (rel, line, what) not in seen:
            seen.add((rel, line, what))
            rep.flag("S9.2.1", rel, line, text, what, fix)

    for rel, start, text in shell_units(root):
        units += 1
        held = quadlet_holders(text)
        pid1 = pid1_reads(text)
        for line, ltext, toks in cg.logical_commands(rel, text):
            if toks is None:
                continue
            at = start + line - 1
            code = " ".join(ltext.split())
            for tl in token_lists(cg, toks, held):
                for words in simple_commands(cg, tl):
                    verb, args = command_word(words)
                    if verb == "setenforce":
                        flag(rel, at, code, f"setenforce {' '.join(args)}".strip(), "tests run enforcing: never switch SELinux off")
                    for t in write_targets(words):
                        if QUADLET.search(t) or any(re.search(rf"\$\{{?{h}\b", t) for h in held):
                            flag(rel, at, code, f"writes {t}, under /etc/containers/systemd: {code[:90]}",
                                 "a test changes the quadlet only by a procedure a document gives (ALLOW names each)")
                for verb, args in podman_calls(cg, tl):
                    commands += 1
                    opts, operand = podman_options(verb, args)
                    shown = " ".join(" ".join(["podman", verb] + args).split())[:120]
                    bad = [o if v is None else f"{o} {v}" for o, v in opts
                           if (o == "--privileged" and v in (None, "true")) or (o == "--security-opt" and v and "label=disable" in v)]
                    if bad:
                        flag(rel, at, code, f"{shown} <- {', '.join(bad)}", "no client runs privileged or unconfined")
                    envs = [(v.partition("=")[0], v.partition("=")[2] if "=" in v else None)
                            for o, v in opts if o in ("-e", "--env") and v]
                    for name, _ in envs:
                        if name == "NVIDIA_CDI_STUB":
                            flag(rel, at, code, f"{shown}: -e {name}, the stub CDI spec's marker, set by hand",
                                 "request nvidia.com/gpu=all and let the spec set it")
                    if verb in ("run", "create"):
                        kinds = sorted({v.split("=", 1)[0] for o, v in opts if o == "--device" and v} & set(edits))
                        if not kinds:
                            continue
                        names = {n: k for k in kinds for n in edits[k][0]}
                        paths = {p: k for k in kinds for p in edits[k][1]}
                        dup = False
                        for name, _ in envs:
                            if name in names and name != "NVIDIA_CDI_STUB":
                                dup = True
                                flag(rel, at, code, f"{shown}: -e {name} duplicates {names[name]}'s CDI edit", "let the CDI spec set it")
                        for o, v in opts:
                            if o not in ("-v", "--volume", "--mount") or not v:
                                continue
                            dst = mount_dest(o, v).rstrip("/")
                            for p, k in sorted(paths.items()):
                                if dst == p or dst.startswith(p + "/") or p.startswith(dst + "/"):
                                    dup = True
                                    flag(rel, at, code, f"{shown}: {o} {v} duplicates {k}'s CDI mount of {p}", "let the CDI spec mount it")
                        if not dup:
                            rep.ok("S9.2.1", rel, at, f"{shown}: requests {', '.join(kinds)}; no -e or -v duplicates its edits")
                    elif verb == "exec" and operand != "desktop":
                        for name, value in envs:
                            if name not in all_env or name == "NVIDIA_CDI_STUB":
                                continue
                            var = re.fullmatch(r"\$\{?(\w+)\}?", value or "")
                            src = pid1.get(var.group(1)) if var else None
                            if src is not None and operand and operand in src:
                                rep.ok("S9.2.1", rel, at, f"{shown}: -e {name} from {operand}'s own pid 1 (S9.2.1's exception)")
                            else:
                                flag(rel, at, code, f"{shown}: -e {name}{'' if value is None else '=' + value} into {operand}, not read from its pid 1",
                                     "read the value from that container's /proc/1/environ (S9.2.1's exception)")
    pys = manifests = 0
    for top in ("ci", "examples"):
        for path in sorted(glob.glob(os.path.join(root, top, "**", "*"), recursive=True)):
            rel = os.path.relpath(path, root)
            if not os.path.isfile(path) or "/artifacts/" in f"/{rel}" or "__pycache__" in rel:
                continue
            found = []
            if rel.endswith((".yaml", ".yml")):
                cg.scan_manifest(path, found)
                manifests += bool(found)
                for l in found:
                    if l.startswith("VIOLATION"):
                        flag(rel, 0, l, l.split(": ", 1)[-1], "a client manifest asks for neither privileged: true nor spc_t (ci/client-guard.py's check)")
                continue
            if not rel.endswith(".py") or rel in ("ci/e9-guard.py", "ci/client-guard.py"):
                continue
            pys += 1
            cg.scan_python(path, found)
            for l in found:
                m = re.match(r"^VIOLATION \S+?:(\d+): (.*)$", l)
                if m:
                    flag(rel, int(m.group(1)), m.group(2), m.group(2), "no client runs privileged or unconfined (ci/client-guard.py's check)")
            try:
                tree = ast.parse(read(path), rel)
            except SyntaxError:
                continue
            for node in ast.walk(tree):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    if QUADLET.search(node.value):
                        flag(rel, node.lineno, node.value, f"names the quadlet directory: {node.value[:80]!r}",
                             "a test changes the quadlet only by a procedure a document gives (ALLOW names each)")
                    if node.value == "setenforce" or re.search(r"(^|[\s;&|(])setenforce\s+([01]|[Pp]ermissive|[Ee]nforcing)\b", node.value):
                        flag(rel, node.lineno, node.value, f"setenforce: {node.value[:80]!r}", "tests run enforcing: never switch SELinux off")
                if not isinstance(node, (ast.List, ast.Tuple)):
                    continue
                elts = node.elts
                vals = [e.value if isinstance(e, ast.Constant) and isinstance(e.value, str) else None for e in elts]
                kinds = {v.split("=", 1)[0] for n, v in enumerate(vals) if n and vals[n - 1] == "--device" and v} & set(edits)
                kinds |= {v[len("--device="):].split("=", 1)[0] for v in vals if v and v.startswith("--device=")} & set(edits)
                for n, v in enumerate(vals):
                    if v not in ("-e", "--env") or n + 1 >= len(elts):
                        continue
                    e = elts[n + 1]
                    name = None
                    if isinstance(e, ast.Constant) and isinstance(e.value, str):
                        name = e.value.partition("=")[0]
                    elif isinstance(e, ast.JoinedStr) and e.values and isinstance(e.values[0], ast.Constant) and "=" in str(e.values[0].value):
                        name = e.values[0].value.partition("=")[0]
                    if name not in all_env:
                        continue
                    shown = " ".join(ast.unparse(node).split())[:120]
                    if name == "NVIDIA_CDI_STUB":
                        flag(rel, node.lineno, shown, f"{shown}: -e {name}, the stub CDI spec's marker, set by hand",
                             "request nvidia.com/gpu=all and let the spec set it")
                    elif vals[:2] in (["podman", "run"], ["podman", "create"]):
                        if any(name in edits[k][0] for k in kinds):
                            flag(rel, node.lineno, shown, f"{shown}: -e {name} duplicates a CDI edit of the device it requests", "let the CDI spec set it")
                    elif "desktop" in vals[n + 2:]:
                        rep.ok("S9.2.1", rel, node.lineno, f"{shown}: -e {name} into the desktop, which is not a CDI client")
                    else:
                        flag(rel, node.lineno, shown, f"{shown}: -e {name} into a container this list does not name as the desktop",
                             "into a CDI client, read the value from its /proc/1/environ (S9.2.1's exception)")
    kinds = "; ".join(f"{k}: {', '.join(sorted(e[0]) + sorted(e[1]))}" for k, e in sorted(edits.items()))
    return (f"S9.2.1: {units} shell file(s) and workflow block(s), {commands} podman run/create/exec command(s) in them "
            f"(quoted command strings included), {pys} Python file(s) and {manifests} manifest(s) read; the CDI edits "
            f"checked, from the generators' specs: {kinds or 'none found'}; {len(rep.violations('S9.2.1'))} violation(s)")


# S9.2.5: what each write under /etc in the tests changes, and what shows it
# is back. An entry covers the writes whose logical line its regex matches;
# its check (a regex) must match a line of the same file after the first
# write it covers. The kinds:
#   restored   the test puts the shipped state back, and checks it;
#   product    the change is a condition the product under test undoes or
#              regenerates itself, and the story checks that it did;
#   scratch    a file the test created and removes again (rm -f under
#              errexit fails loudly when it cannot);
#   shipped    the write installs the deploy tree's own file;
#   container  the write is a command line run in a scratch container, which
#              the line hands to a helper of the test's (scenario, in_scratch);
#   discarded  setup of a VM or runner that is thrown away after the run.
RESTORES = [
    # ci/hw/acceptance.sh (T4: undo_all runs each undo, the story then checks)
    ("ci/hw/acceptance.sh", r"\$DROPIN(_DIR)?\b", "restored",
     r"undone: the (toolkit's own spec back|drop-in gone)", "S8.1.4", "README.md's fallback drop-in, removed by undo_all"),
    ("ci/hw/acceptance.sh", r"\$SPEC\b", "restored",
     r"undone: the toolkit back, a real spec regenerated|the remedy regenerated a real spec",
     "S8.1.2, S5.4.3", "the real spec moved away or made stale; put back by undo_all, or regenerated by README.md's remedy"),
    ("ci/hw/acceptance.sh", r"/etc/desktop-container/monitors\.conf", "restored",
     r"monitors\.conf is not back as it was", "S8.2.3",
     "the captured layout installed; put back unless the tester keeps it for the KVM stories, which the evidence notes"),
    # ci/host-shell-setup-tests.sh (T1: each scenario's setup runs in a scratch container)
    ("ci/host-shell-setup-tests.sh", r"^scenario |^for c in \"missing-user", "container", None, "S5.7.7 (T1 half)",
     "scenario hands its setup to in_scratch, which runs it in a scratch container of the image"),
    # ci/smoke-deploy.sh (T2, the runner)
    ("ci/smoke-deploy.sh", r'rm -f "\$SPEC"', "product", r"back to the stub", "S5.4.2",
     "the NVIDIA spec removed: the converger writes it again"),
    ("ci/smoke-deploy.sh", r'rm -f "\$DISPLAY_SPEC" "\$AUDIO_SPEC"', "product", r"display spec kind wrong", "S5.5.1",
     "the client specs removed: the generator writes them again"),
    ("ci/smoke-deploy.sh", r"/etc/cdi/desktop\.yaml", "product", r"legacy combined spec survived", "S5.5.1",
     "the superseded combined spec planted: the generator removes it"),
    ("ci/smoke-deploy.sh", r"DISPLAY_VALUE|cat > /etc/desktop-container/client-cdi\.conf|rm -f /etc/desktop-container/client-cdi\.conf$|mkdir -p /etc/desktop-container$",
     "restored", r"defaults not restored after removing the override", "S5.5.2", "the override file written and removed: the defaults return"),
    ("ci/smoke-deploy.sh", r"TOOLS_DIR=|rm -f \"\$TOOLS_SPEC\" /etc/desktop-container/client-cdi\.conf", "scratch", None, "S5.5.4",
     "the override file and the spec the case wrote, removed again (the desktop's first publish writes the spec)"),
    ("ci/smoke-deploy.sh", r"72-seat-ci-test|ci-fake-dm|display-manager\.service", "product", r"seat-prep second run not silent", "S5.3.1",
     "a dirty seat staged: seat-prep walks it back, the fake units go, and a second seat-prep run is silent"),
    ("ci/smoke-deploy.sh", r"/etc/desktop-container/monitors\.conf", "restored", r"the shipped monitors\.conf is not back", "S3.4.8, S3.4.11",
     "a declared layout, then the shipped file put back"),
    ("ci/smoke-deploy.sh", r'"\$QL"', "restored", r"desktop\.service did not restart with the quadlet put back", "S5.7.7",
     "deploy/README.md's Host Terminal off-switch, then the saved quadlet put back"),
    ("ci/smoke-deploy.sh", r"host-shell-key", "restored", r"no fresh host-shell key once the quadlet was put back", "S5.7.7",
     "the key material removed: the next start makes a fresh key"),
    # ci/vm/maint-guest.sh (maintainer journeys, a stock VM per shard)
    ("ci/vm/maint-guest.sh", r"\$MT_MONCONF\b", "restored", r"the shipped monitors\.conf still generated a layout", "S10.3.1, S10.3.2",
     "the captured layout and each S10.3.2 case; the shipped file put back"),
    ("ci/vm/maint-guest.sh", r'"\$MT_PIN"', "restored", r"the published toolkit is not the \$1 image's", "S10.3.3",
     "the documented digest pin, then removed: the route back runs the first image"),
    ("ci/vm/maint-guest.sh", r"sed -i -E 's/\^\(Wants\|After\)=desktop-host-shell|rm -f \$MT_HSKEY", "discarded", None, "S10.3.5, S10.3.6",
     "the documented off-switch, and the material it should have left gone, are the journey's end state: S10.3.6 turns the "
     "Host Terminal on from its screen through the product, and the shard's VM is discarded"),
    ("ci/vm/maint-guest.sh", r"rm -f /etc/udev/rules\.d/72-seat-\*\.rules", "restored", r"no staged node is tagged for seat1 any more", "S10.5.2",
     "the seat rule the fault staged, removed by hand after a remedy that did not bring input back"),
    ("ci/vm/maint-guest.sh", r"rm /etc/cdi/desktop-tools\.yaml", "product", r"after the start the node has no tools spec or no published toolkit", "S10.6.2",
     "a never-provisioned node staged: the desktop's start publishes the toolkit and the watcher writes the spec again"),
    # ci/vm/vm-guest.sh (the VM shards)
    ("ci/vm/vm-guest.sh", r"/etc/cdi/desktop\.yaml", "product", r"the superseded combined spec survived", "S5.5.1",
     "the superseded combined spec planted: desktop-client-cdi removes it"),
    ("ci/vm/vm-guest.sh", r"cat > /etc/desktop-container/monitors\.conf|\"\$lines\" > /etc/desktop-container/monitors\.conf|^install -m644 deploy/host/etc/desktop-container/monitors\.conf",
     "restored", r"the shipped monitors\.conf still generated a layout - it is not a no-op", "S3.4.9-S3.4.12",
     "a declared layout (layout-declare, layout-roundtrip); layout-restore puts the shipped file back"),
    ("ci/vm/vm-guest.sh", r"^(two|shipped)\) ", "restored", r"monitors-set shipped: the shipped file is not back", "S3.11.2",
     "the operator phase's two-monitor layout, then the shipped file back"),
    ("ci/vm/vm-guest.sh", r"rm -f /etc/cdi/desktop-display\.yaml", "product", r"came back different", "S5.5.6",
     "the client specs removed: desktop-client-cdi.service writes them again, byte for byte"),
    ("ci/vm/vm-guest.sh", r'rm -f "\$spec"', "product", r"the tools spec to come back", "S5.5.5",
     "the tools spec removed: the .path unit has it written again"),
    ("ci/vm/vm-guest.sh", r"/etc/containers/systemd/desktop\.container\.d", "restored", r"with the drop-in removed the desktop runs", "S5.2.6",
     "deploy/README.md's image pin, then removed: the desktop runs :latest again"),
    ("ci/vm/vm-guest.sh", r"getty@tty1\.service", "restored", r"getty@tty1 is not masked again", "S5.2.5",
     "getty@tty1 unmasked and started on purpose, then masked again"),
    ("ci/vm/vm-guest.sh", r"/etc/systemd/system/display-manager\.service", "restored", r"a display-manager\.service is still installed", "S5.2.5",
     "a stand-in display manager, then removed"),
    ("ci/vm/vm-guest.sh", r"\$SESSION_(AWAY|UNIT|WANTS)\b", "restored", r"desktop-session is not enabled again", "S5.8.4",
     "desktop-session's unit moved away, then back"),
    ("ci/vm/vm-guest.sh", r"/etc/asound\.conf", "restored", r"/etc/asound\.conf is not back as it was", "S4.2.3",
     "a host-local asound.conf routing default to null, then the host's own back (or none)"),
    ("ci/vm/vm-guest.sh", r"/etc/yum\.repos\.d/cri-o\.repo|/etc/crio/crio\.conf\.d", "discarded", None, "S7.3.x (k8s shard setup)",
     "CRI-O's repository and its k3s drop-ins: the k8s shard's environment, on a VM discarded after the run"),
    # .github/workflows/ci.yml (the dry-run step, on the runner)
    (".github/workflows/ci.yml", r"DISPLAY_VALUE=:7|rm -f /etc/desktop-container/client-cdi\.conf|install -d /etc/desktop-container$",
     "restored", r"the default :0 is not back", "S5.5.2 (T0 half)", "the DISPLAY override, then removed: the default comes back"),
    (".github/workflows/ci.yml", r"install -Dm644 deploy/host/etc/desktop-container/shell-user", "shipped", None, "S5.7.x",
     "the deploy tree's own shell-user file"),
]
RESTORE_KINDS = {"restored": True, "product": True, "scratch": False, "shipped": False, "container": False, "discarded": False}
PLANT_RESTORES = []                     # the self-test's own entries, for its planted files
ETC = re.compile(r"(?<![\w.~-])/etc/")


def etc_holders(text):
    """Variables that hold a path under /etc: assigned one, or built on one."""
    held = set(re.findall(r"^\s*(?:local\s+|readonly\s+)?([A-Za-z_]\w*)=[\"']?/etc/", text, re.M))
    built = re.findall(r"^\s*(?:local\s+|readonly\s+)?([A-Za-z_]\w*)=[\"']?\$\{?(\w+)\}?/", text, re.M)
    for _ in range(3):
        held |= {name for name, base in built if base in held}
    return held


def host_token_lists(cg, toks, held, depth=0, inside=False):
    """token_lists, each list with whether it runs in a container: a quoted
    command line given to podman run, create or exec runs there, not on
    the host."""
    yield toks, inside
    if depth > 2:
        return
    podman = False
    for k, t in enumerate(toks):
        if t in cg.OPS:
            podman = False
        elif (t == "podman" or t.endswith("/podman")) and k + 1 < len(toks) and toks[k + 1] in ("run", "create", "exec"):
            podman = True
        elif re.search(r"\s", t) and (ETC.search(t) or any(re.search(rf"\$\{{?{h}\b", t) for h in held)):
            try:
                sub = cg.tokens(t)
            except ValueError:
                continue
            yield from host_token_lists(cg, sub, held, depth + 1, inside or podman)


def etc_writes(cg, rel, start, text):
    """(line, logical line, target) of each write under /etc on the host."""
    held = etc_holders(text)
    seen = set()
    for line, ltext, toks in cg.logical_commands(rel, text):
        if toks is None:
            continue
        at = start + line - 1
        code = " ".join(ltext.split())
        for tl, inside in host_token_lists(cg, toks, held):
            if inside:
                continue
            for words in simple_commands(cg, tl):
                for t in write_targets(words):
                    if (ETC.search(t) or any(re.search(rf"\$\{{?{h}\b", t) for h in held)) and (at, t) not in seen:
                        seen.add((at, t))
                        yield at, code, t


def rule_s925(root, rep):
    """S9.2.5: each write under /etc is restored, and the restore checked."""
    cg = client_guard()
    entries = [(f, re.compile(w, re.M), k, re.compile(c) if c else None, s, why)
               for f, w, k, c, s, why in RESTORES + PLANT_RESTORES]
    first, writes = {}, 0
    for rel, start, text in shell_units(root):
        for at, code, t in etc_writes(cg, rel, start, text):
            writes += 1
            hit = [i for i, e in enumerate(entries) if e[0] == rel and e[1].search(code)]
            if not hit:
                rep.flag("S9.2.5", rel, at, code, f"writes {t}, and no RESTORES entry says how it is put back: {code[:90]}",
                         "restore it, check the restore, and add a RESTORES entry naming the check")
                continue
            i = hit[0]
            first[i] = min(first.get(i, at), at)
            f, w, k, c, s, why = entries[i]
            rep.ok("S9.2.5", rel, at, f"writes {t} ({k}, {s}): {code[:80]}")
    checked = 0
    for i, (f, w, k, c, s, why) in enumerate(entries):
        if k not in RESTORE_KINDS:
            rep.flag("S9.2.5", f, 0, "", f"RESTORES entry for {s} has no kind {k!r}", f"one of {', '.join(RESTORE_KINDS)}")
            continue
        if i not in first:
            rep.flag("S9.2.5", f, 0, w.pattern, f"the RESTORES entry for {s} ({w.pattern}) covers no write", "remove the entry, or fix its regex")
            continue
        if not RESTORE_KINDS[k]:
            rep.ok("S9.2.5", f, first[i], f"{s}: {k}: {why}")
            continue
        lines = read(os.path.join(root, f)).split("\n")
        at = next((n for n, l in enumerate(lines, 1) if n > first[i] and c and c.search(l)), None)
        if at is None:
            rep.flag("S9.2.5", f, first[i], c.pattern if c else "",
                     f"{s}: no check matching /{c.pattern if c else ''}/ after the write at line {first[i]}",
                     "check that the restore took effect, after the write")
        else:
            checked += 1
            rep.ok("S9.2.5", f, at, f"{s}: {k}, checked here: {why}")
    return (f"S9.2.5: {writes} write(s) under /etc read in ci/'s shell and the workflows; {len(entries)} RESTORES "
            f"entr{'y' if len(entries) == 1 else 'ies'}, {checked} with a check found after its first write; "
            f"{len(rep.violations('S9.2.5'))} violation(s)")


DOCS_WITH_PROCEDURES = ["deploy/HOST-REQUIRES.md", "deploy/README.md", "README.md"]
COMMAND_LANGS = {"sh", "bash", "shell", "console"}
# A placeholder in a document's line: "...", "<name>", an example.com host.
PLACEHOLDER = re.compile(r"\.\.\.|<[^<>\s][^<>]*>|\bexample\.com\b")
# Lines too generic to show a retype by themselves: a bare yaml key, an ini section.
GENERIC = re.compile(r"^(?:[\w.-]+:|\[[\w.-]+\])$")
RETYPE_WINDOW = 20
# The harness's wrappers around a command it runs: sudo, and its own
# functions that take arguments before the command (ev_save NAME "TEXT" ...).
RUN_PREFIX = re.compile(r'^(?:(?:sudo|run|exec|command)\s+|ev_save\s+\S+\s+"(?:[^"\\]|\\.)*"\s+'
                        r'|ev_check\s+"(?:[^"\\]|\\.)*"\s+|wait_for\s+\S+\s+\S+\s+"(?:[^"\\]|\\.)*"\s+)+')
RUN_SUFFIX = re.compile(r"(?:\s+(?:\d?>>?\s*/dev/null|2>&1|\|\|.*|&&.*|;\s*\\?$))+$")
DOC_READ = re.compile(r"doc-blocks\.py")
# An EV-PROCEDURE step in a function that runs a documented block is the
# document's own command or block, a step a document gives in prose (the
# text names the document as its source), or the harness's own.
STEP_FROM_DOC = re.compile(r"as written|as this run read it|as the entry writes it|verbatim|unmodified"
                           r"|\$\{?(?:line|cmd)\b")
_DOC = r"(?:deploy/)?(?:README|HOST-REQUIRES)\.md"
STEP_NAMES_DOC = re.compile(rf"{_DOC}(?:'s\b|\s*:|\s+\\?\"|\s+(?:asks|says|gives|writes)\b)|\({_DOC}\b")
# A run, or a write, of what a line holds: a step that uses a substitution.
RUNS_OR_WRITES = re.compile(r"\b(?:sh|bash)\s+-c\b|\beval\s|\bev_save\s|(?<![<>&\d])>>?\s*\"?[$/\w](?!dev/null)")


def norm(line):
    return " ".join(line.split())


def doc_blocks(root):
    """Each fenced block of the documents: (doc, fence line, heading, lang,
    lines, digest). A command block's lines are its commands as
    ci/doc-blocks.py --commands reads them (continuation lines joined,
    comments and blank lines dropped); any other block's are its lines,
    blank and comment lines dropped. Whitespace is normalised. The digest
    (of the lines) is what an ALLOW entry pins."""
    out = []
    for doc in DOCS_WITH_PROCEDURES:
        p = os.path.join(root, doc)
        if not os.path.exists(p):
            continue
        lines = read(p).split("\n")
        heading, i = "", 0
        while i < len(lines):
            h = re.match(r"^#{1,6}\s+(.*?)\s*$", lines[i])
            if h:
                heading = h.group(1)
            m = re.match(r"^\s*```([\w-]*)\s*$", lines[i])
            if not m:
                i += 1
                continue
            lang, j, body, cur = m.group(1), i + 1, [], ""
            while j < len(lines) and not re.match(r"^\s*```\s*$", lines[j]):
                t = lines[j].strip()
                j += 1
                if lang in COMMAND_LANGS:
                    if t.endswith("\\"):
                        cur += t[:-1] + " "
                        continue
                    t, cur = re.sub(r"\s+#.*$", "", cur + t).strip(), ""
                    t = re.sub(r"^\$\s+", "", t)
                if t and not t.startswith("#"):
                    body.append(norm(t))
            if body:
                digest = hashlib.sha256("\n".join(body).encode()).hexdigest()[:10]
                out.append((doc, i + 1, heading, lang, body, digest))
            i = j + 1
    return out


def line_matcher(line, command):
    """The harness lines that type this line of a document: the line itself
    (sudo dropped from a command); a placeholder matches whatever stands in
    its place, and a config line whose value has one matches any value for
    its key."""
    if command:
        line = re.sub(r"^sudo\s+", "", line)
    if not PLACEHOLDER.search(line):
        return re.compile(re.escape(line))
    key = re.match(r"^([\w.*/-]+\s*=\s*|[\w.*/-]+:\s+)", line) if not command else None
    if key:
        return re.compile(re.escape(key.group(1)) + r".*")
    return re.compile(".+?".join(re.escape(p) for p in PLACEHOLDER.split(line)))


def run_forms(line):
    """A harness line as it could type a document's: as it stands, without
    the harness's wrappers, without a trailing redirection or || / && tail,
    without sudo."""
    t = norm(line)
    if not t or t.startswith("#"):
        return []
    forms = {t}
    bare = RUN_PREFIX.sub("", t)
    forms |= {bare, RUN_SUFFIX.sub("", bare), RUN_SUFFIX.sub("", t)}
    forms |= {re.sub(r"^sudo\s+", "", f) for f in list(forms)}
    return sorted(f for f in forms if f)


def harness_lines(root, rel):
    """(line number, forms) for each line of a harness file: its shell or
    workflow lines, a printf or echo format's own lines, and each line of
    a Python string."""
    path = os.path.join(root, rel)
    out = []
    if rel.endswith(".py"):
        try:
            tree = ast.parse(read(path))
        except SyntaxError:
            return out
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                for k, piece in enumerate(node.value.split("\n")):
                    forms = run_forms(piece)
                    if forms:
                        out.append((node.lineno + k, forms))
        return out
    for n, l in enumerate(read(path).split("\n"), 1):
        forms = run_forms(l)
        if "\\n" in l:
            for piece in l.split("\\n"):
                piece = re.sub(r"""^.*?\b(?:printf|echo(?:\s+-e)?)\s+['"]""", "", piece)
                forms += run_forms(piece.rstrip("'\""))
        if forms:
            out.append((n, forms))
    return out


def retypes(root, rel, blocks):
    """(first line, block, the block's lines typed) for each block of which
    the file types two or more lines within RETYPE_WINDOW lines, at least
    one of them not generic; or the one line of a one-command block whose
    command takes arguments. A one-line block of any other kind is not a
    procedure."""
    lines = harness_lines(root, rel)
    out = []
    for blk in blocks:
        doc, at, heading, lang, body, digest = blk
        command = lang in COMMAND_LANGS
        if len(body) == 1 and not (command and len(re.sub(r"^sudo\s+", "", body[0]).split()) >= 2):
            continue
        matchers = [(b, line_matcher(b, command)) for b in body]
        hits = [(n, b) for n, forms in lines for b, m in matchers if any(m.fullmatch(f) for f in forms)]
        need = min(2, len(body))
        for a, _ in hits:
            near = {b for n, b in hits if a <= n <= a + RETYPE_WINDOW}
            if len(near) >= need and any(not GENERIC.match(b) for b in near):
                out.append((a, blk, [b for b in body if b in near]))
                break
    return out


def shell_functions(text):
    """(name, first line, lines) for each top-level function: from
    `name() {` to the next line that is `}`."""
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][\w-]*)\s*\(\)\s*\{", lines[i])
        if not m:
            i += 1
            continue
        j = i
        while j < len(lines) and not re.match(r"^\}\s*(#.*)?$", lines[j]):
            j += 1
        out.append((m.group(1), i + 1, lines[i:j + 1]))
        i = j + 1
    return out


STORY_BEGIN = re.compile(r"\b(?:ev_begin|mt_begin|story_begin)\s")


def story_segments(first, body):
    """A function's lines cut where each story begins: (first line, lines).
    A story that reads a document is judged on its own lines, not on the
    rest of a long function's."""
    cuts = [0] + [k for k, l in enumerate(body) if k and STORY_BEGIN.search(l)]
    return [(first + a, body[a:b]) for a, b in zip(cuts, cuts[1:] + [len(body)])]


def doc_readers(funcs):
    """The functions that read a document: those that run doc-blocks.py,
    and those that take one's output ($(f ...))."""
    direct = {n for n, _, b in funcs if any(DOC_READ.search(l) for l in b)}
    via = {n for n, _, b in funcs if any(re.search(rf"\$\(\s*{re.escape(r)}\b", l) for l in b for r in direct)}
    return direct | via, direct


def doc_vars(body, direct):
    """A reading function's variables that hold what it read: assigned from
    doc-blocks.py, from a reader's output, or from another such variable;
    read from one (read, mapfile, a for loop over one)."""
    held = set()
    src_re = lambda: re.compile("|".join([r"doc-blocks\.py"] + [rf"\$\(\s*{re.escape(r)}\b" for r in direct]
                                         + [rf"\$\{{?{v}\b" for v in held]))
    changed = True
    while changed:
        changed = False
        src = src_re()
        for k, l in enumerate(body):
            if not src.search(l):
                continue
            names = re.findall(r"(?:^|[\s;(])(?:local\s+)?([A-Za-z_]\w*)=", l)
            names += re.findall(r"\bmapfile\s+(?:-\S+\s+)*([A-Za-z_]\w*)", l)
            names += re.findall(r"\bfor\s+([A-Za-z_]\w*)\s+in\b", l)
            m = re.search(r"\bread\s+((?:-\S+\s+)*)([A-Za-z_][\w ]*?)\s*(?:<<<|;|$)", l)
            if m:
                names += m.group(2).split()
            if re.search(r"^\s*done\s*<", l):        # a while-read loop fed from a document
                for b in reversed(body[:k]):
                    w = re.search(r"\bwhile\b.*?\bread\s+(?:-\S+\s+)*([A-Za-z_][\w ]*?)\s*(?:;|$)", b)
                    if w:
                        names += w.group(1).split()
                        break
            for v in names:
                if v not in held and v not in ("IFS",):
                    held.add(v)
                    changed = True
    return held


def doc_calls(root, rel, text, funcs):
    """(line, doc, heading, options) for each doc-blocks.py call in a shell
    file whose arguments are literal, the file's own constants, or a
    function's positional parameters given that way at each of its call
    sites in the file; (line, None, why, None) for one that is not."""
    consts = {}
    for m in re.finditer(r"^([A-Z_][A-Z0-9_]*)=(\"[^\"$`]*\"|'[^']*')\s*(?:#.*)?$", text, re.M):
        consts[m.group(1)] = shlex.split(m.group(2))[0] if len(m.group(2)) > 2 else ""
    lines = text.split("\n")
    owner = {}
    for name, first, body in funcs:
        for k in range(len(body)):
            owner[first + k] = name

    def args_of(s, params):
        """The words of a command's arguments, cut at the first operator
        outside quotes, variables expanded where known."""
        q, cut = None, len(s)
        for i, c in enumerate(s):
            if q:
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
            elif c in ")|;&<>":
                cut = i
                break
        redirect = cut < len(s) and s[cut] in "<>"
        s = s[:cut].rstrip()
        if redirect:
            s = re.sub(r"\s\d+$", "", s)            # the fd of a redirection (2>&1), not a block number
        s = re.sub(r"\$\{?REPO\}?/", "", s)
        unknown = []

        def var(m):
            name = m.group(1) or m.group(2)
            if name.isdigit():
                v = params.get(int(name))
            else:
                v = consts.get(name)
            if v is None:
                unknown.append(name)
                return ""
            return v.replace("\\", "\\\\").replace('"', '\\"')
        s = re.sub(r"\$\{?(\d+|[A-Za-z_]\w*)(?::\?[^}]*)?\}?|\$\{([A-Za-z_]\w*)\}", var, s)
        try:
            return shlex.split(s), unknown
        except ValueError as e:
            return None, [str(e)]

    def call_sites(name):
        """The positional parameters at each call of a function in the file
        (None for a call whose arguments are not readable)."""
        sites = []
        for n, l in enumerate(lines, 1):
            if l.lstrip().startswith("#") or owner.get(n) == name:
                continue
            m = re.search(rf"(?:^|[\s;&|(]){re.escape(name)}\s+(.*)$", l)
            if m:
                words, unknown = args_of(m.group(1), {})
                sites.append({k + 1: w for k, w in enumerate(words)} if words is not None and not unknown else None)
        return sites

    out = []
    for n, l in enumerate(lines, 1):
        m = re.search(r"doc-blocks\.py\"?\s+(.*)$", l)
        if not m or l.lstrip().startswith("#"):
            continue
        rest = m.group(1)
        param_sets = [{}]
        if re.search(r"\$\{?\d", rest):
            sites = call_sites(owner[n]) if n in owner else []
            if not sites or None in sites:
                out.append((n, None, f"a positional parameter, and {owner.get(n, 'the top level')} is called "
                                     f"with arguments this guard cannot read", None))
                continue
            param_sets = sites
        for params in param_sets:
            words, unknown = args_of(rest, params)
            if words is None or unknown or len(words) < 2:
                out.append((n, None, f"arguments this guard cannot read ({', '.join(unknown) or 'too few'})", None))
                continue
            path = re.sub(r"^(?:\.\./|\./)+", "", words[0])
            doc = next((d for d in DOCS_WITH_PROCEDURES if path == d or path.endswith("/" + d)), None)
            if doc is None:
                out.append((n, None, f"a file that is not one of the documents: {words[0]}", None))
                continue
            out.append((n, doc, words[1], words[2:]))
    return out


def check_doc_call(mod, root, doc, heading, opts):
    """Whether doc-blocks.py finds the block, paragraph or entry: None, or
    what it says when it does not."""
    path = os.path.join(root, doc)
    try:
        if "--para" in opts:
            mod.para(path, heading, opts[opts.index("--para") + 1])
        elif "--entry" in opts:
            mod.entry(path, heading, opts[opts.index("--entry") + 1])
        else:
            num = int(opts[0]) if opts and opts[0].isdigit() else 1
            mod.block(path, heading, num, opts[opts.index("--lang") + 1] if "--lang" in opts else None)
    except SystemExit as e:
        return str(e)
    except (IndexError, ValueError) as e:
        return f"the call's options do not parse: {e}"
    return None


def rule_s926(root, rep):
    """S9.2.6: a documented procedure is run from the document: every read
    finds its block, nothing is retyped, placeholders are the only
    substitutions and each is named, a harness step among the document's
    is named harness-only."""
    blocks = doc_blocks(root)
    spec = importlib.util.spec_from_file_location("doc_blocks", os.path.join(root, "ci", "doc-blocks.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    files = shell_files(root) + [os.path.relpath(p, root) for p in
                                 sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml")))
                                 + sorted(glob.glob(os.path.join(root, "ci", "**", "*.py"), recursive=True))]
    found = reads = unread = steps = subs = 0
    for rel in files:
        if rel in ("ci/e9-guard.py", "ci/doc-blocks.py"):
            continue
        for a, (doc, at, heading, lang, body, digest), typed in retypes(root, rel, blocks):
            found += 1
            rep.flag("S9.2.6", rel, a, f'{doc} "{heading}" [{digest}]: {" | ".join(typed)}',
                     f'types {len(typed)} of the {len(body)} line(s) of {doc}\'s {lang or "unlabelled"} block under '
                     f'"{heading}" (line {at}, digest {digest}): {" | ".join(typed)[:160]}',
                     "run the block from the document (ci/doc-blocks.py), its placeholders the only "
                     "substitutions; or, where the harness types it for its own setup, say why in an "
                     "ALLOW entry that pins this digest and these lines")
    for rel in shell_files(root):
        text = read(os.path.join(root, rel))
        funcs = shell_functions(text)
        for n, doc, heading, opts in doc_calls(root, rel, text, funcs):
            if doc is None:
                unread += 1
                rep.ok("S9.2.6", rel, n, f"a doc-blocks.py read not checked: {heading}")
                continue
            reads += 1
            why = check_doc_call(mod, root, doc, heading, opts)
            if why:
                rep.flag("S9.2.6", rel, n, f"{doc}:{heading}",
                         f"reads {doc} under \"{heading}\" ({' '.join(opts)}), which is not there: {why}",
                         "read what the document has now, or put back what it lost")
        readers, direct = doc_readers(funcs)
        reads_doc = re.compile("|".join([r"doc-blocks\.py"] + [rf"\$\(\s*{re.escape(r)}\b" for r in direct]))
        for name, first, body in funcs:
            if name not in readers:
                continue
            held = doc_vars(body, direct)
            for start, seg in story_segments(first, body):
                if not any(reads_doc.search(l) for l in seg):
                    continue
                last_sub = -9
                for k, l in enumerate(seg):
                    for d in re.findall(r'EV-PROCEDURE: ((?:[^"\\]|\\.)*)', l):
                        steps += 1
                        if not (STEP_FROM_DOC.search(d) or STEP_NAMES_DOC.search(d) or "harness-only" in d):
                            rep.flag("S9.2.6", rel, start + k, d,
                                     f"{name}, in a story that runs what a document gives, records a step that "
                                     f"neither is the document's (as written, or naming its document as the source) "
                                     f"nor is named harness-only: {d[:100]}",
                                     "say where the step comes from in its EV-PROCEDURE text: the document's "
                                     "(README.md's ...), or harness-only")
                    sub = [v for v in held if re.search(rf"\$\{{{v}//?", l)
                           or re.search(rf"\bsed\b[^|;]*\bs([|/#,]).*<<<\s*\"?\$\{{?{v}\b", l)]
                    if sub and RUNS_OR_WRITES.search(l) and k - last_sub > 2:
                        subs += 1
                        last_sub = k
                        near = " ".join(seg[max(0, k - 3):k + 4])
                        if "placeholder" not in near:
                            rep.flag("S9.2.6", rel, start + k, l.strip(),
                                     f"{name} runs or writes a substitution into what it read from a document "
                                     f"(${sub[0]}), and no text within three lines names it a placeholder: "
                                     f"{l.strip()[:100]}",
                                     "substitute only the document's placeholders, and name each in the step's "
                                     "EV-PROCEDURE or ev_note text (\"placeholder\")")
    return (f"S9.2.6: {len(blocks)} fenced block(s) in {', '.join(DOCS_WITH_PROCEDURES)}; {reads} doc-blocks.py "
            f"read(s) checked against them ({unread} not readable statically); {found} block(s) typed into the "
            f"harness; {steps} step(s) recorded where a document is run; {subs} substitution(s) run or written "
            f"there; {len(rep.violations('S9.2.6'))} violation(s)")


RULES = {"S9.1.3": rule_s913, "S9.1.5": rule_s915, "S9.2.1": rule_s921, "S9.2.2": rule_s922, "S9.2.4": rule_s924, "S9.2.5": rule_s925, "S9.2.6": rule_s926, "S9.3.1": rule_s931}

# --- the self-test --------------------------------------------------------------------

PLANTS = {
    "S9.1.5": [
        ("ci/p1.sh", "#!/bin/bash\nset -euo pipefail\nx=$(podman ps | grep -q y)\n", True),
        ("ci/p2.sh", "#!/bin/bash\nset -euo pipefail\nfoo | head -n1 || true\n", True),
        ("ci/p3.sh", "#!/bin/bash\nset -euo pipefail\nif journalctl -b | awk '/x/ {print; exit}'; then :; fi\n", True),
        ("ci/p4.sh", "#!/bin/bash\nset -euo pipefail\ns=$(podman ps); grep -q y <<<\"$s\"\n", False),
        ("ci/p5.sh", "#!/bin/bash\nset -euo pipefail\nsh -c 'a | grep -q b'\nprintf '%s\\n' \"$v\" | grep -q x\necho \"$v\" | head -1\n", False),
        ("ci/p6.sh", "#!/bin/bash\nset -u\na | grep -q b\n", False),
        ("ci/p7.sh", "#!/bin/bash\nset -euo pipefail\nn=$(ls | wc -l)  # a | grep -q in a comment\ncase \"$x\" in head|tail) : ;; esac\n", False),
        ("ci/p8.sh", "#!/bin/bash\nset -euo pipefail\npodman logs d 2>&1 | while read -r l; do [ \"$l\" = x ] && break; done\n", True),
        ("ci/p9.sh", "#!/bin/bash\nset -euo pipefail\npodman logs d 2>&1 | grep -c x\npodman ps | sort | head -n -1\n", False),
    ],
    "S9.1.3": [
        ("ci/i1.sh", "podman exec desktop cat /proc/1/environ\n", True),
        ("ci/i2.sh", "pid=$(podman exec desktop cat /run/desktop-init.pid)\n", False),
        ("ci/i3.py", "cmd = 'pidof Xorg'\n", True),
    ],
    "S9.2.4": [
        ("ci/c1.sh", "#!/bin/bash\nset -e\nn=$(vm_ssh_quick 'ls | wc -l')\n[ \"$n\" -gt 0 ]\n", True),
        ("ci/c2.sh", "#!/bin/bash\nset -e\nn=$(vm_ssh_quick 'ls | wc -l' 2>/dev/null || echo 0)\n[ \"$n\" -gt 0 ]\n", True),
        ("ci/c3.sh", "#!/bin/bash\nn=$(gq 'ls | wc -l')\n[ \"${n:-0}\" -gt 0 ]\n", True),
        ("ci/c9.sh", "#!/bin/bash\nxl=$(gq xorg-log-lines 2>/dev/null || echo 0)\ngq xorg-log-since \"$xl\"\n", True),
        ("ci/c10.sh", "#!/bin/bash\nn=$(vm_ssh_quick 'ls | wc -l') || fail \"no count\"\n[ \"$n\" -gt 0 ]\n", False),
        ("ci/c6.sh", "#!/bin/bash\nf() {\n    n=$(gq 'ls | wc -l')\n    echo \"$n\"\n}\ng() {\n    n=3\n    [ \"$n\" -gt 1 ]\n}\n", False),
        ("ci/c7.sh", "#!/bin/bash\nt=$(vm_ssh_quick 'date +%s.%N')\n[ -n \"$t\" ] && [ \"$now\" -ge \"${t%.*}\" ]\n", False),
        ("ci/c8.sh", "#!/bin/bash\nb=$(vm_ssh_quick 'ls /dev/snd | wc -l')\nsleep 1\nwhile [ $((b + 1)) -gt 2 ]; do :; done\n", True),
        ("ci/c4.py", "def f(g):\n    return int(g.sh('ls | wc -l').strip())\n", True),
        ("ci/c5.py", "def f(g):\n    try:\n        return int(g.sh('ls | wc -l').strip())\n    except (RuntimeError, ValueError):\n        return None\n", False),
        ("ci/c11.py", "def f(g):\n    try:\n        return int(g.sh('ls | wc -l').strip())\n    except ValueError:\n        return 0\n", True),
    ],
    "S9.3.1": [
        ("ci/s1.sh", "ev_begin S99.1.1 \"no such story\" T0\n", True),
        ("ci/s2.sh", "ev_begin S9.1.5 \"a story\" T0\n", False),
        ("ci/s3.py", "w = StoryWriter(root, 'S99.1.2', 'no such story', 'T0', 'x')\n", True),
    ],
    "S9.2.1": [
        ("ci/q1.sh", "#!/bin/bash\nvm_ssh \"sudo podman run --rm --privileged img true\"\n", True),
        ("ci/q2.sh", "#!/bin/bash\nsudo setenforce 0\n", True),
        ("ci/q3.sh", "#!/bin/bash\npodman exec -e DISPLAY=:0 op-observer xwininfo -root\n", True),
        ("ci/q4.sh", "#!/bin/bash\ndisp=$(podman exec op-observer sh -c 'tr \"\\0\" \"\\n\" </proc/1/environ' | sed -n 's/^DISPLAY=//p')\n"
                     "podman exec -e DISPLAY=\"$disp\" op-observer xwininfo -root\npodman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo\n", False),
        ("ci/q5.sh", "#!/bin/bash\nQL=/etc/containers/systemd/desktop.container\nsed -i 's/^Image=.*/Image=x/' \"$QL\"\n", True),
        ("ci/q6.sh", "#!/bin/bash\ngrep -E '^AddDevice=' /etc/containers/systemd/desktop.container >/dev/null\n"
                     "cp /etc/containers/systemd/desktop.container /tmp/q\ninstall -m644 deploy/host/etc/containers/systemd/desktop.container \"$tmp/\"\n", False),
        ("ci/q7.sh", "#!/bin/bash\nundo_later \"rm -f '/etc/containers/systemd/desktop.container.d/x.conf'; systemctl daemon-reload\"\n", True),
        ("ci/q8.sh", "#!/bin/bash\npodman run --rm --device desktop.local/audio=all -e PULSE_SERVER=unix:/run/desktop-audio/pulse img pactl info\n", True),
        ("ci/q9.sh", "#!/bin/bash\npodman run --rm --device desktop.local/display=all -v /tmp/.X11-unix:/tmp/.X11-unix img xdpyinfo\n", True),
        ("ci/q10.sh", "#!/bin/bash\npodman run --rm -v /run/desktop-audio:/run/desktop-audio -e PULSE_SERVER=unix:/run/desktop-audio/pulse img pactl info\n"
                      "podman run --rm --device desktop.local/display=all img grep -e DISPLAY=x /etc/f\n", False),
        ("ci/q11.py", "import subprocess\nsubprocess.run(['podman', 'run', '--device', 'nvidia.com/gpu=all', '-e', 'NVIDIA_CDI_STUB=1', 'img'])\n", True),
        ("ci/q12.py", "Q = '/etc/containers/systemd/desktop.container'\n", True),
        (".github/workflows/w.yml", "on: push\njobs:\n  j:\n    runs-on: x\n    steps:\n"
                                    "      - run: sudo podman run --rm --device desktop.local/display=all -e DISPLAY=:0 img true\n", True),
    ],
    "S9.2.5": [
        ("ci/r1.sh", "#!/bin/bash\nset -e\necho 'x=1' > /etc/foo.conf\n", True),
        ("ci/r2.sh", "#!/bin/bash\nset -e\nev_save edit \"the edit\" sed -i 's/a/b/' /etc/foo.conf\n", True),
        ("ci/r3.sh", "#!/bin/bash\nset -e\nvm_ssh \"sudo tee /etc/foo.conf </dev/null\"\nmv /etc/bar.conf /tmp/bar\n", True),
        ("ci/r4.sh", "#!/bin/bash\nset -e\ncp /etc/foo.conf /tmp/x\ngrep -q x /etc/foo.conf >/dev/null\n"
                     "install -m644 deploy/host/etc/foo.conf \"$tmp/\"\n", False),
        ("ci/r5.sh", "#!/bin/bash\nset -e\necho 'x=1' > /etc/plant.conf\nrm -f /etc/plant.conf\n"
                     "[ ! -e /etc/plant.conf ] || fail \"the plant is still there\"\n", False),
        ("ci/r6.sh", "#!/bin/bash\nset -e\n[ ! -e /etc/plant6.conf ] || fail \"the plant6 is still there\"\n"
                     "echo 'x=1' > /etc/plant6.conf\nrm -f /etc/plant6.conf\n", True),
    ],
    "S9.2.6": [
        ("ci/d1.sh", "#!/bin/bash\nset -e\nrsync -a --chown=root:root deploy/host/ /\nsystemctl daemon-reload\n", True),
        ("ci/d2.sh", "#!/bin/bash\nset -e\nsystemctl daemon-reload\nsystemctl status desktop.service\n", False),
        ("ci/d3.sh", "#!/bin/bash\nset -e\nwhile IFS=$'\\t' read -r cmd _; do sh -c \"$cmd\"; done "
                     "< <(python3 ci/doc-blocks.py README.md Install 1 --commands)\n", False),
        ("ci/d4.sh", "#!/bin/bash\nset -e\nprintf '[Container]\\nImage=localhost/x@%s\\n' \"$dg\" > \"$pin\"\n", True),
        ("ci/d5.sh", "#!/bin/bash\nset -e\nst() {\n    raw=$(python3 ci/doc-blocks.py README.md Install)\n"
                     "    ev_save stop \"EV-PROCEDURE: systemctl stop desktop.service\" systemctl stop desktop.service\n}\n", True),
        ("ci/d6.sh", "#!/bin/bash\nset -e\nst() {\n    blk=$(python3 ci/doc-blocks.py README.md Overriding 1 --lang ini)\n"
                     "    sed 's|registry.example.com|localhost|' <<<\"$blk\" > \"$pin\"\n}\n", True),
        ("ci/d7.sh", "#!/bin/bash\nset -e\nst() {\n    blk=$(python3 ci/doc-blocks.py README.md Overriding 1 --lang ini)\n"
                     "    sed 's|registry.example.com|localhost|' <<<\"$blk\" > \"$pin\"\n"
                     "    ev_note \"the block's one placeholder, registry.example.com, is localhost here\"\n"
                     "    ev_save stop \"EV-PROCEDURE: harness-only: systemctl stop desktop.service\" systemctl stop desktop.service\n}\n", False),
        ("ci/d9.sh", "#!/bin/bash\nset -e\nraw=$(python3 ci/doc-blocks.py README.md \"No such heading\" 1 --commands)\n", True),
        ("ci/vm/d8.py", "g.sh('sudo rsync -a --chown=root:root deploy/host/ /\\nsudo systemctl daemon-reload')\n", True),
    ],
    "S9.2.2": [
        ("ci/vm/x-only-pod.yaml", "apiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: c\n      image: i\n      resources:\n"
                                  "        limits:\n          desktop.local/display: 1\n          desktop.local/tools: 1\n", True),
        ("ci/vm/y-pod.yaml", "apiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: c\n      image: i\n      env:\n        - name: DISPLAY\n          value: ':0'\n", True),
        ("ci/vm/z-only-pod.yaml", "apiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: c\n      image: i\n      # env: in a comment\n"
                                  "      resources:\n        limits:\n          desktop.local/audio: 1\n", False),
    ],
}

# RESTORES entries for the planted files: r5 checks its restore after the
# write, r6 only before it.
PLANT_ENTRIES = [
    ("ci/r5.sh", r"/etc/plant\.conf", "restored", r"the plant is still there", "S0.0.1", "a planted write, restored and checked"),
    ("ci/r6.sh", r"/etc/plant6\.conf", "restored", r"the plant6 is still there", "S0.0.2", "a planted write, checked before it was made"),
]

# The self-test tree's README.md: a command block and a config block with a
# placeholder, for S9.2.6's plants.
PLANT_README = """# A project

## Install

```sh
# as root
sudo rsync -a --chown=root:root deploy/host/ /
sudo systemctl daemon-reload
```

## Overriding the image

```ini
# /etc/containers/systemd/desktop.container.d/50-image.conf
[Container]
Image=registry.example.com/desktop-container@sha256:...
```
"""


def self_test(root, rules):
    ok = True
    for rule, plants in PLANTS.items():
        if rule not in rules:
            continue
        PLANT_RESTORES[:] = PLANT_ENTRIES if rule == "S9.2.5" else []
        for path, body, want in plants:
            with tempfile.TemporaryDirectory(dir=os.environ.get("RUNNER_TEMP")) as d:
                os.makedirs(os.path.join(d, ".github", "workflows"))
                os.makedirs(os.path.join(d, "ci", "vm"))
                os.makedirs(os.path.join(d, "examples"))
                # a minimal tree: Requirements.md and evlib for S9.3.1, the
                # CDI generators for S9.2.1
                with open(os.path.join(d, "Requirements.md"), "w") as f:
                    f.write("**S9.1.5 A story**\n**S9.3.1 Another**\n")
                with open(os.path.join(d, "README.md"), "w") as f:
                    f.write(PLANT_README)
                for support in ["ci/evlib.py", "ci/doc-blocks.py"] + CDI_GENERATORS:
                    os.makedirs(os.path.dirname(os.path.join(d, support)), exist_ok=True)
                    with open(os.path.join(root, support)) as src, open(os.path.join(d, support), "w") as dst:
                        dst.write(src.read())
                full = os.path.join(d, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w") as f:
                    f.write(body)
                rep = Report([])
                RULES[rule](d, rep)
                got = any(v[2] == path for v in rep.violations(rule))
                verdict = "flagged" if got else "passed"
                print(f"self-test {rule} {path}: {verdict} (want {'flagged' if want else 'passed'})")
                for l in rep.lines(rule):
                    if path in l:
                        print(f"    {l}")
                ok &= got == want
    PLANT_RESTORES[:] = []
    # Every allow-list entry of these rules excuses something in the tree.
    rep = Report(ALLOW)
    for rule in rules:
        RULES[rule](root, rep)
    for n, entry in enumerate(ALLOW):
        if entry[0] in rules and n not in rep.used:
            print(f"self-test: ALLOW entry {entry[:3]} excuses nothing in the tree")
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rule", help="comma-separated rules (default: all)")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    rules = a.rule.split(",") if a.rule else list(RULES)
    for r in rules:
        if r not in RULES:
            ap.error(f"no rule {r}; the rules are {', '.join(RULES)}")
    ok = True
    if a.self_test:
        if not self_test(".", rules):
            print("e9-guard: FAIL: the self-test misjudged a planted file, or an ALLOW entry excuses nothing")
            ok = False
        else:
            print("e9-guard: self-test passed")
    rep = Report(ALLOW)
    summaries = [RULES[r](".", rep) for r in rules]
    for r, s in zip(rules, summaries):
        print("\n".join(rep.lines(r)))
        print(s)
    bad = sum(len(rep.violations(r)) for r in rules)
    return 0 if ok and not bad else 1


if __name__ == "__main__":
    sys.exit(main())
