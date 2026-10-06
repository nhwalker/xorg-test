#!/usr/bin/env python3
"""Evidence for every test tier: one directory per story, one format.

Requirements.md ("Evidence standard") asks every story to leave a directory a
reviewer can read without re-running anything:

    <root>/<story>/
      evidence.md        the index: PASS/FAIL, the checks in order, what was
                         recorded, one line per file saying what to look for
      meta.tsv           title, tier, the job that ran it
      checks.tsv         time, PASS|FAIL, claim           (one per assertion)
      notes.tsv          time, text                       (observed, not asserted)
      files.tsv          time, file, what to look for     (every evidence file)
      result             PASS or FAIL, and why
      timeline.log       everything the story did, timestamped
      NN-<moment>.<ext>  the evidence itself, numbered in the order taken

Two writers produce it: ci/evidence.sh for the shell phases (T0 and T2 on the
runner, the VM guest at T3) and StoryWriter below for the Python ones. A VM
story can be written from both sides at once: the guest writes the plain
names and the host adds files with an "h" prefix (h-checks.tsv, h01-...), so
pulling the guest's copy over the host's never loses either half.

This file is also the command line that renders evidence.md and that checks
a run's evidence against the document:

    evlib.py render <dir>...           write evidence.md for each story dir
    evlib.py check  <root>...          every story dir complete and readable,
                                       and its evidence the kind a reviewer
                                       can read (discipline() below: each
                                       before/after pair diffed, with the
                                       lines expected to differ; each claim
                                       that something lived through an event
                                       measured before and after)
    evlib.py gate --requirements Requirements.md [--report out.md] <root>...
                                       check, then: every story the document
                                       marks ✅ has a passing evidence dir
    evlib.py gate --workflow maintainer.yml --requirements ... <root>...
                                       the same for a workflow other than
                                       ci.yml: only the stories whose Coverage
                                       line names it ("(workflow `NAME`)")

Standard library only: it runs on the CI runner and inside the Rocky guest.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

STORY_RE = re.compile(r"^S\d+\.\d+\.\d+$")
SIDES = ("", "h-")
BOOKKEEPING = {"evidence.md", "meta.tsv", "result", ".n", ".hn"}


def stamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def one_line(text):
    """TSV-safe: no tabs, newlines or carriage returns inside a field."""
    return " ".join(str(text).replace("\t", " ").replace("\r", " ").split("\n")).strip()


# --- writing ------------------------------------------------------------------

class StoryWriter:
    """The Python twin of ci/evidence.sh: same files, same names."""

    def __init__(self, root, sid, title, tier="", source="", intro="", side=""):
        if not STORY_RE.match(sid):
            raise ValueError(f"not a story id: {sid}")
        self.root, self.sid, self.side = root, sid, side
        self.dir = os.path.join(root, sid)
        os.makedirs(self.dir, exist_ok=True)
        if side == "":
            with open(self._p("meta.tsv"), "w") as f:
                for k, v in (("title", title), ("tier", tier), ("source", source), ("intro", intro)):
                    f.write(f"{k}\t{one_line(v)}\n")
            for name in ("result",):
                try:
                    os.remove(self._p(name))
                except FileNotFoundError:
                    pass
        self.log("begin", title)

    def _p(self, name):
        return os.path.join(self.dir, name)

    def _append(self, name, *fields):
        with open(self._p(self.side + name), "a") as f:
            f.write("\t".join(one_line(x) for x in fields) + "\n")

    def log(self, kind, text):
        line = f"{stamp()} {self.sid:<8} {kind:<6} {one_line(text)}"
        with open(os.path.join(self.root, "timeline.log"), "a") as f:
            f.write(line + "\n")
        with open(self._p(self.side + "timeline.log"), "a") as f:
            f.write(line + "\n")

    def check(self, ok, claim):
        status = "PASS" if ok else "FAIL"
        self._append("checks.tsv", stamp(), status, claim)
        self.log("check", f"{status} {claim}")
        return bool(ok)

    def note(self, text):
        self._append("notes.tsv", stamp(), text)
        self.log("note", text)

    def name(self, moment, ext):
        counter = self._p(".hn" if self.side else ".n")
        try:
            n = int(open(counter).read().strip() or 0) + 1
        except FileNotFoundError:
            n = 1
        with open(counter, "w") as f:
            f.write(str(n))
        prefix = "h" if self.side else ""
        return f"{prefix}{n:02d}-{moment}.{ext}" if ext else f"{prefix}{n:02d}-{moment}"

    def path(self, name):
        return self._p(name)

    def attach(self, name, what):
        self._append("files.tsv", stamp(), name, what)
        self.log("file", f"{name}: {what}")
        self.last = name            # evidence.sh's $EV_LAST: the file indexed last

    def write(self, moment, text, what, ext="txt"):
        name = self.name(moment, ext)
        with open(self._p(name), "w") as f:
            f.write(text)
        self.attach(name, what)
        return name

    def finish(self, error=None, trace=None):
        """Primary side only: settle the result and render evidence.md."""
        failed = [c for c in read_checks(self.dir) if c[1] != "PASS"]
        status = "FAIL" if (error or failed) else "PASS"
        reason = error or (failed[0][2] if failed else "")
        with open(self._p("result"), "w") as f:
            f.write(status + (f"\t{one_line(reason)}" if reason else "") + "\n")
        if trace:
            with open(self._p("trace.txt"), "w") as f:
                f.write(trace)
            self.attach("trace.txt", "the failure's traceback")
        self.log("end", status)
        render(self.dir)
        return status


# --- reading ------------------------------------------------------------------

def _rows(path, width):
    out = []
    try:
        # Rows end at \n alone: a stray \r inside a field (an ssh message
        # kept before the writers dropped them) is not a row break.
        with open(path, newline="\n") as f:
            for line in f:
                line = line.rstrip("\n").replace("\r", " ")
                if not line:
                    continue
                parts = line.split("\t")
                parts += [""] * (width - len(parts))
                out.append(tuple(parts[:width - 1]) + ("\t".join(parts[width - 1:]),))
    except FileNotFoundError:
        pass
    return out


def read_checks(d):
    rows = []
    for side in SIDES:
        rows += _rows(os.path.join(d, side + "checks.tsv"), 3)
    return sorted(rows, key=lambda r: r[0])


def read_notes(d):
    rows = []
    for side in SIDES:
        rows += _rows(os.path.join(d, side + "notes.tsv"), 2)
    return sorted(rows, key=lambda r: r[0])


def read_files(d):
    rows = []
    for side in SIDES:
        rows += _rows(os.path.join(d, side + "files.tsv"), 3)
    return sorted(rows, key=lambda r: r[0])


def read_meta(d):
    meta = {}
    for k, v in _rows(os.path.join(d, "meta.tsv"), 2):
        meta[k] = v
    return meta


def read_result(d):
    """('PASS'|'FAIL'|'INCOMPLETE', reason). A host-side failed check fails
    the story even though only the guest side writes `result`."""
    try:
        first = open(os.path.join(d, "result"), newline="\n").read().replace("\r", " ").strip().split("\t", 1)
    except FileNotFoundError:
        first = None
    failed = [c for c in read_checks(d) if c[1] != "PASS"]
    if first is None:
        return ("FAIL", failed[0][2]) if failed else ("INCOMPLETE", "the story never finished")
    status, reason = first[0], (first[1] if len(first) > 1 else "")
    if failed and status == "PASS":
        return "FAIL", failed[0][2]
    return status, reason


# --- rendering ----------------------------------------------------------------

def render(d):
    sid = os.path.basename(os.path.normpath(d))
    meta = read_meta(d)
    status, reason = read_result(d)
    out = [f"# {sid} — {meta.get('title', '')}", ""]
    out.append(f"**{status}**" + (f" — {reason}" if reason and status != "PASS" else ""))
    spec = f"Spec: `Requirements.md`, {sid}."
    if meta.get("tier"):
        spec += f" Tier {meta['tier']}."
    if meta.get("source"):
        spec += f" Ran in {meta['source']}."
    if meta.get("intro"):
        spec += " " + meta["intro"]
    out += ["", spec, "", "## Checks, in the order they ran", ""]
    checks = read_checks(d)
    for i, (_, st, claim) in enumerate(checks, 1):
        out.append(f"{i}. {'✅' if st == 'PASS' else '❌'} {claim}")
    if not checks:
        out.append("(none ran)")
    notes = read_notes(d)
    if notes:
        out += ["", "## Recorded (observed, not asserted)", ""]
        out += [f"- {text}" for _, text in notes]
    out += ["", "## Files", "", "| File | What to look for |", "|---|---|"]
    for _, name, what in read_files(d):
        out.append(f"| `{name}` | {what} |")
    for side in SIDES:
        if os.path.exists(os.path.join(d, side + "timeline.log")):
            who = "the VM host's side" if side else "this story"
            out.append(f"| `{side}timeline.log` | everything {who} did, timestamped (EV-TIMELINE) |")
    if os.path.exists(os.path.join(d, "qemu.log")):
        out.append("| `qemu.log` | every QMP command sent: input events, screendumps, "
                   "monitor commands (EV-QEMU) |")
    with open(os.path.join(d, "evidence.md"), "w") as f:
        f.write("\n".join(out) + "\n")


def story_dirs(root):
    """Every story directory under root, at any depth (a run's artifacts are
    gathered per job: evidence/<job>/<story>/)."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        if STORY_RE.match(os.path.basename(dirpath)) and (
                "meta.tsv" in filenames or "evidence.md" in filenames):
            found.append(dirpath)
            dirnames[:] = []
    return sorted(found)


# --- checking -----------------------------------------------------------------

def check_dir(d):
    """Problems that make a story's evidence unreviewable (S9.3.1)."""
    problems = []
    if not os.path.exists(os.path.join(d, "evidence.md")):
        problems.append("no evidence.md")
    if not os.path.exists(os.path.join(d, "meta.tsv")):
        problems.append("no meta.tsv (not written by evlib or evidence.sh)")
    listed = set()
    for _, name, _ in read_files(d):
        listed.add(name.rstrip("/"))
        p = os.path.join(d, name)
        if name.endswith("/"):
            # A directory of evidence (EV-VIDEO frames): present and not empty.
            if not os.path.isdir(p):
                problems.append(f"indexed directory missing: {name}")
            elif not os.listdir(p):
                problems.append(f"indexed directory empty: {name}")
        elif not os.path.isfile(p):
            problems.append(f"indexed file missing: {name}")
        elif os.path.getsize(p) == 0:
            problems.append(f"indexed file empty: {name}")
    for name in sorted(os.listdir(d)):
        if (name in BOOKKEEPING or name.endswith(".tsv") or name.endswith("timeline.log")
                or name == "qemu.log" or name.startswith(".")):
            continue
        if name not in listed:
            problems.append(f"file not in the index: {name}")
    status, _ = read_result(d)
    if status == "INCOMPLETE":
        problems.append("the story never finished (no result)")
    return problems


# --- evidence discipline (Requirements.md F9.3) -------------------------------
#
# check_dir asks that a story's directory be complete (S9.3.1). These ask that
# what it holds be evidence a reviewer can read without re-running anything;
# `check` and `gate` run them on every story directory too:
#   S9.3.2  each before/after pair of states (two text files whose names differ
#           in "before" and "after") has a diff comparing them, and each diff's
#           line in the index says which lines are expected to differ
#           ("expected to differ: ...", which ev_diff and Ctx.diff write); a
#           diff expected to differ in nothing differs in nothing
#   S9.3.3  a passing check that says a container or process lived through an
#           event (the same container, kept its pid, not restarted,
#           restartCount 0, ...) is measured: its story holds two states of
#           the pids, or of the container's id and restart count for a
#           container, either a before/after pair or the two files a diff
#           compares

NUMBERED = re.compile(r"^h?\d+-(.+)$")
MEDIA = (".png", ".gif", ".wav", ".mp4", ".ppm", ".jpg")
EXPECT = re.compile(r"expected to differ: *(.*?)\s*$")
# A check that says something lived through an event, in the words the
# harness's checks use; a check that something did not ("neither ...") is not
# one.
SURVIVAL = re.compile(
    r"\bsame (?:containers?|process(?:es)?|pids?|pods?|application|desktop-init|xorg|mwm)\b"
    r"|\bkept (?:its|their) pids?\b|\bkept running\b|\bran on as one process\b|\b(?:is|are) still running\b"
    r"|\b(?:not|never) (?:been )?(?:restarted|re-?created)\b|\bdid not restart\b|\bno restarts?\b"
    r"|\brestarted no\b|\bstarted no new\b|\bwithout (?:being )?(?:restart|recreat)"
    r"|\brestart ?count:? 0\b|\brestarts:? 0\b|\bpids? (?:and start times )?unchanged\b"
    r"|\bone (?:\w+ )?process\b|\b(?:desktop|container|process|pod)s? (?:\w+ )?surviv", re.I)
ABOUT_A_CONTAINER = re.compile(r"\b(?:containers?|pods?)\b", re.I)
PID_MEASURE = re.compile(r"\bpids?\b|\bPID\b|MainPID", re.I)
CONTAINER_MEASURE = re.compile(r"restartCount|RestartCount|\brestarts=\d|containerID|ContainerID|\bId\b|\bid=|"
                               r"StartedAt|startedAt", re.I)


def unnumbered(name):
    """A file's name past the number its writer gave it (01-, h01-)."""
    m = NUMBERED.match(name)
    return m.group(1) if m else name


def pair_half(name):
    """('before'|'after', key) when a text file is one half of a pair: one
    dash-separated word of its name is "before" or "after", and the rest (the
    key) names what was captured. None otherwise."""
    if name.endswith("/") or name.endswith(".diff") or name.lower().endswith(MEDIA):
        return None
    base = unnumbered(name)
    stem, dot, ext = base.rpartition(".")
    if not dot:
        stem, ext = base, ""
    words = stem.split("-")
    at = [i for i, w in enumerate(words) if w in ("before", "after")]
    if len(at) != 1:
        return None
    return words[at[0]], "-".join(words[:at[0]] + ["*"] + words[at[0] + 1:]) + dot + ext


def pairs(files):
    """{key: {"before": [names], "after": [names]}} of the pairs in an index."""
    out = {}
    for _, name, _ in files:
        h = pair_half(name)
        if h:
            out.setdefault(h[1], {"before": [], "after": []})[h[0]].append(name)
    return {k: v for k, v in out.items() if v["before"] and v["after"]}


def diff_names(text):
    """The two names a diff compares: its ---/+++ header, or the line ev_diff
    and Ctx.diff write when the two files are the same."""
    a = re.search(r"^--- (\S+)", text, re.M)
    b = re.search(r"^\+\+\+ (\S+)", text, re.M)
    if a and b:
        return os.path.basename(a.group(1)), os.path.basename(b.group(1))
    m = re.search(r"\(no differences between (\S+) and (\S+)\)", text)
    if m:
        return os.path.basename(m.group(1)), os.path.basename(m.group(2))
    return None


def diff_changes(text):
    """The lines a unified diff removes or adds."""
    return [l for l in text.split("\n") if l.startswith(("-", "+")) and not l.startswith(("--- ", "+++ "))]


def names_file(compared, name):
    """A name a diff compares is the story's file: the same name, or the same
    past the number (ev_diff_paths compares the files the story was given
    copies of)."""
    return compared in (name, unnumbered(name))


def _text(d, name):
    try:
        with open(os.path.join(d, name), errors="replace") as f:
            return f.read()
    except OSError:
        return None                      # check_dir reports it


def pair_problems(d, files):
    """S9.3.2 for one story directory."""
    problems, diffs = [], []
    for _, name, what in files:
        if not name.endswith(".diff"):
            continue
        text = _text(d, name)
        if text is None:
            continue
        compared = diff_names(text)
        diffs.append(compared)
        if compared is None:
            problems.append(f"{name} does not name the two files it compares (a ---/+++ header, "
                            "or 'no differences between A and B')")
        m = EXPECT.search(what)
        if not m or not m.group(1):
            problems.append(f"{name}: its line in the index does not say which lines are expected "
                            "to differ ('expected to differ: ...')")
        elif m.group(1).lower().startswith("nothing") and diff_changes(text):
            problems.append(f"{name} is expected to differ in nothing, but {len(diff_changes(text))} "
                            "line(s) differ")
    for key, half in sorted(pairs(files).items()):
        for after in half["after"]:
            if not any(c and names_file(c[1], after) and any(names_file(c[0], b) for b in half["before"])
                       for c in diffs):
                problems.append(f"{after} has no diff against its before ({', '.join(half['before'])})")
    return problems


def compared(d, files):
    """(a, b) story file names of the two files each diff in the index
    compares, where both are the story's."""
    names = [n for _, n, _ in files]
    out = []
    for n in names:
        if not n.endswith(".diff"):
            continue
        text = _text(d, n)
        c = diff_names(text) if text is not None else None
        if not c:
            continue
        a = next((f for f in names if names_file(c[0], f)), None)
        b = next((f for f in names if names_file(c[1], f)), None)
        if a and b:
            out.append((a, b))
    return out


def survival_problems(d, files):
    """S9.3.3 for one story directory: the claims its passing checks make."""
    claims = [c for _, status, c in read_checks(d) if status == "PASS" and SURVIVAL.search(c)]
    if not claims:
        return []
    have = set()
    states = [(half["before"][0], half["after"][-1]) for half in pairs(files).values()] + compared(d, files)
    for b_name, a_name in states:
        b, a = _text(d, b_name), _text(d, a_name)
        if b is None or a is None:
            continue
        if PID_MEASURE.search(b) and PID_MEASURE.search(a):
            have.add("pid")
        if CONTAINER_MEASURE.search(b) and CONTAINER_MEASURE.search(a):
            have.add("container")
    problems = []
    for c in claims:
        need = "container" if ABOUT_A_CONTAINER.search(c) else "pid"
        if need not in have:
            problems.append(f"the check '{c[:120]}' says a {'container' if need == 'container' else 'process'} "
                            "lived through an event, but the story holds no two states of "
                            + ("the container's id and restart count" if need == "container" else "its pids")
                            + " (a before/after pair, or the two files a diff compares)")
    return problems


def discipline(d):
    """[(rule, problem)]: what in a story's directory the F9.3 rules find."""
    files = read_files(d)
    out = [("S9.3.2", p) for p in pair_problems(d, files)]
    out += [("S9.3.3", p) for p in survival_problems(d, files)]
    return out


# --- the document -------------------------------------------------------------

MARKS = ("✅", "🟡", "❌", "🔧")


def parse_requirements(path):
    """{story: {title, tier, coverage, mark}} using the document's own
    counting rule (Appendix D): weakest mark wins; a line whose only mark is
    🔧 counts as 🔧."""
    stories, cur = {}, None
    head = re.compile(r"^\*\*(S\d+\.\d+\.\d+)\s+(.*?)\*\*\s*$")
    tierline = re.compile(r"^- Tier:\s*(.*?)\s*·\s*Coverage:\s*(.*)$")
    for line in open(path, encoding="utf-8"):
        m = head.match(line.strip())
        if m:
            cur = m.group(1)
            stories[cur] = {"title": m.group(2), "tier": "", "coverage": "", "mark": ""}
            continue
        if line.startswith("## "):
            cur = None
        if cur:
            t = tierline.match(line.strip())
            if t:
                cov = t.group(2)
                if "❌" in cov:
                    mark = "❌"
                elif "🟡" in cov:
                    mark = "🟡"
                elif "✅" in cov:
                    mark = "✅"
                elif "🔧" in cov:
                    mark = "🔧"
                else:
                    mark = ""
                stories[cur].update(tier=t.group(1), coverage=cov, mark=mark)
    return stories


# --- command line -------------------------------------------------------------

def cmd_render(args):
    for d in args.dirs:
        for s in (story_dirs(d) if not STORY_RE.match(os.path.basename(os.path.normpath(d))) else [d]):
            render(s)
    return 0


def collect(roots):
    by_story = {}
    for root in roots:
        for d in story_dirs(root):
            by_story.setdefault(os.path.basename(d), []).append(d)
    return by_story


def cmd_check(args):
    bad = 0
    for sid, dirs in sorted(collect(args.roots).items()):
        for d in dirs:
            for p in check_dir(d):
                print(f"{d}: {p}")
                bad += 1
            for rule, p in discipline(d):
                print(f"{d}: {rule}: {p}")
                bad += 1
    print(f"evidence check: {bad} problem(s)")
    return 1 if bad else 0


def cmd_gate(args):
    stories = parse_requirements(args.requirements)
    found = collect(args.roots)
    errors, upgrades, rows, elsewhere = [], [], [], []
    for sid, dirs in sorted(found.items()):
        if sid not in stories:
            errors.append(f"{sid}: evidence for a story that Requirements.md does not define ({dirs[0]})")
        for d in dirs:
            for p in check_dir(d):
                errors.append(f"{sid}: {p} ({d})")
            for rule, p in discipline(d):
                errors.append(f"{sid}: {rule}: {p} ({d})")
            st, why = read_result(d)
            if st == "FAIL":
                errors.append(f"{sid}: FAIL in {d}: {why}")
    for sid, s in stories.items():
        dirs = found.get(sid, [])
        # A Coverage line may file a story's evidence under another story's
        # directory ("evidence under `artifacts/S11.1.1/`"): that counts too.
        for other in re.findall(r"artifacts/(S\d+\.\d+\.\d+)/", s["coverage"]):
            dirs = dirs + [d for d in found.get(other, []) if d not in dirs]
        results = [read_result(d)[0] for d in dirs]
        passed = bool(results) and all(r == "PASS" for r in results)
        # A story whose evidence another workflow keeps names it on its
        # Coverage line ("(workflow `base-rebuild.yml`)"): a run of this one
        # need not carry it, but any evidence it does carry still counts.
        other = re.search(r"\(workflow `([\w.-]+\.yml)`\)", s["coverage"])
        if args.workflow:
            # That workflow's own gate: its stories are the ones in scope.
            # Any other story's evidence it left was checked above, and is
            # listed, but its absence is ci.yml's business.
            if not other or other.group(1) != args.workflow:
                if dirs:
                    rows.append((sid, s["mark"], ", ".join(sorted({os.path.relpath(d, os.path.commonpath([d] + list(args.roots))) for d in dirs})),
                                 "/".join(results) + " (not this workflow's story)"))
                continue
            other = None
        if s["mark"] == "✅" and not passed and not dirs and other:
            elsewhere.append(f"{sid}: its evidence is kept by {other.group(1)}")
            rows.append((sid, s["mark"], f"workflow {other.group(1)}", "-"))
            continue
        if s["mark"] == "✅" and not passed:
            errors.append(f"{sid}: marked ✅ in Requirements.md but this run has "
                          + ("no evidence for it" if not dirs else "no passing evidence for it"))
        if s["mark"] in ("❌", "🟡") and passed:
            upgrades.append(sid)
        rows.append((sid, s["mark"], ", ".join(sorted({os.path.relpath(d, os.path.commonpath([d] + list(args.roots))) for d in dirs})) or "-",
                     "/".join(results) or "-"))
    marks = {m: sum(1 for s in stories.values() if s["mark"] == m) for m in MARKS}
    scope = ""
    if args.workflow:
        mine = [sid for sid, s in stories.items()
                if re.search(r"\(workflow `" + re.escape(args.workflow) + "`\\)", s["coverage"])]
        scope = (f" {len(mine)} of them name `{args.workflow}` on their Coverage line, and only "
                 "those are this run's to prove.")
    lines = ["# Coverage gate", "",
             f"{len(stories)} stories in `{args.requirements}`; this run left evidence for "
             f"{len(found)}.{scope}", "",
             "| Mark | Stories |", "|---|---|"] + [f"| {m} | {n} |" for m, n in marks.items()]
    lines += ["", f"## Errors ({len(errors)})", ""] + ([f"- {e}" for e in errors] or ["none"])
    lines += ["", f"## Evidence kept by another workflow ({len(elsewhere)})", ""] + ([f"- {e}" for e in elsewhere] or ["none"])
    lines += ["", f"## Evidence that would support a better mark ({len(upgrades)})", ""]
    lines += ([f"- {u} (marked {stories[u]['mark']})" for u in upgrades] or ["none"])
    lines += ["", "## Every story", "", "| Story | Mark | Evidence | Result |", "|---|---|---|---|"]
    lines += [f"| {a} | {b} | {c} | {d} |" for a, b, c, d in rows]
    report = "\n".join(lines) + "\n"
    if args.report:
        with open(args.report, "w") as f:
            f.write(report)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"errors": errors, "upgrades": upgrades, "elsewhere": elsewhere, "marks": marks,
                       "stories": {r[0]: {"mark": r[1], "evidence": r[2], "result": r[3]} for r in rows}},
                      f, indent=1, ensure_ascii=False)
    print("\n".join(lines[:lines.index("## Every story")]))
    return 1 if errors else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("dirs", nargs="+")
    c = sub.add_parser("check")
    c.add_argument("roots", nargs="+")
    g = sub.add_parser("gate")
    g.add_argument("--requirements", required=True)
    g.add_argument("--report")
    g.add_argument("--json")
    g.add_argument("--workflow", help="gate only the stories whose Coverage line names this "
                   "workflow (\"(workflow `maintainer.yml`)\"), for that workflow's own runs")
    g.add_argument("roots", nargs="+")
    args = ap.parse_args(argv)
    return {"render": cmd_render, "check": cmd_check, "gate": cmd_gate}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
