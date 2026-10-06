#!/usr/bin/env python3
"""S9.1.1's pull-request half: a pull request that adds assertions to the
test suite names, in its description, the mutation each was seen to fail on.

  pr-mutations.py check BODY DIFF
                          BODY: the pull request's description; DIFF: the
                          pull request's `git diff`, base to head. Prints the
                          assertions the diff adds to the test suite (ci/ and
                          the workflows), file by file, then the
                          description's mutations: the text under a heading
                          named "Mutation" or "Mutations", up to the next
                          heading. Exit 1 when the diff adds an assertion and
                          that text is missing or empty.
  pr-mutations.py --self-test
                          the check on planted descriptions and diffs: it
                          must fail new assertions with no mutations heading
                          and with an empty one, and pass a heading that
                          names one and a diff that adds no assertion.

It reads what a description says, not whether the mutation was run: that is
the reviewer's to see in the pull request's own runs.
"""
import re
import sys

SUITE = re.compile(r"^(?:ci/|\.github/workflows/)")
CODE = (".sh", ".py", ".yml", ".yaml")
# A call that passes or fails a story or a check: in the shell (and the
# workflows' run blocks) ev_pass, ev_fail, ev_check, want and fail with their
# claim; in the Python a StoryWriter's check, an assert, a guard's flag.
SHELL_ASSERTION = re.compile(r"\b(?:ev_pass|ev_fail|ev_check|want|fail)\s+[\"'$]")
PY_ASSERTION = re.compile(r"\.check\(|^\s*assert\s|\brep\.flag\(|\braise StoryFailed\b")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
MUTATIONS = re.compile(r"^mutations?\b", re.I)


def added_assertions(diff):
    """[(file, line)]: each line the diff adds to the suite's code that
    asserts, comments aside."""
    out, path = [], None
    for line in diff.split("\n"):
        if line.startswith("+++ "):
            p = line[4:].strip()
            p = p[2:] if p.startswith("b/") else p
            path = p if SUITE.match(p) and p.endswith(CODE) else None
        elif path and line.startswith("+") and not line.startswith("+++"):
            text = line[1:]
            if text.lstrip().startswith("#"):
                continue
            if (PY_ASSERTION if path.endswith(".py") else SHELL_ASSERTION).search(text):
                out.append((path, text.strip()))
    return out


def mutations(body):
    """The text under the description's Mutation(s) heading, up to the next
    heading; None when there is no such heading."""
    lines = body.replace("\r\n", "\n").split("\n")
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m and MUTATIONS.match(m.group(1)):
            text = []
            for nxt in lines[i + 1:]:
                if HEADING.match(nxt):
                    break
                text.append(nxt)
            return "\n".join(text).strip()
    return None


def check(body, diff, out=print):
    found = added_assertions(diff)
    named = mutations(body)
    files = {}
    for path, text in found:
        files.setdefault(path, []).append(text)
    out(f"pr-mutations: the diff adds {len(found)} assertion line(s) to the test suite"
        + (f", in {len(files)} file(s):" if found else ""))
    for path, texts in sorted(files.items()):
        out(f"  {path}: {len(texts)}")
        for t in texts[:20]:
            out(f"    + {t[:160]}")
        if len(texts) > 20:
            out(f"    ... and {len(texts) - 20} more")
    if named is None:
        out("pr-mutations: the description has no Mutations heading")
    else:
        out("pr-mutations: the description's Mutations section:")
        for line in (named or "(empty)").split("\n"):
            out(f"  | {line}")
    if found and not named:
        out("pr-mutations: FAIL: the pull request adds assertions and its description names no mutation they "
            "were seen to fail on (Requirements.md S9.1.1): add a \"## Mutations\" section saying, for each new "
            "check, what was broken on purpose and that the check failed on it")
        return 1
    out("pr-mutations: PASS: " + ("the description names the mutations" if found else
                                  "the diff adds no assertion to the test suite"))
    return 0


SELF_TEST = [
    # (what, body, diff, expected exit status)
    ("new assertions, no Mutations heading",
     "## Summary\nA new check.\n",
     "+++ b/ci/x.sh\n+ev_pass \"the thing holds\"\n", 1),
    ("new assertions, an empty Mutations section",
     "## Mutations\n\n## Testing\nran it\n",
     "+++ b/ci/vm/y.py\n+    st.check(ok, \"the window moved\")\n", 1),
    ("new assertions, a Mutations section naming one",
     "## Mutations\n- the window left where it was: the check failed\n",
     "+++ b/ci/vm/y.py\n+    st.check(ok, \"the window moved\")\n", 0),
    ("no new assertion: a comment and a doc",
     "## Summary\ndocs only\n",
     "+++ b/ci/x.sh\n+# ev_pass in a comment\n+++ b/Requirements.md\n+ev_pass in prose\n", 0),
]


def self_test():
    bad = 0
    for what, body, diff, want in SELF_TEST:
        got = check(body, diff, out=lambda _line: None)
        ok = got == want
        bad += not ok
        print(f"{'ok' if ok else 'MISSED'}  pr-mutations self-test: {what}: exit {got}, want {want}")
    print(f"pr-mutations self-test: {len(SELF_TEST)} planted case(s), {bad} judged wrong")
    return 1 if bad else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) == 4 and argv[1] == "check":
        with open(argv[2], encoding="utf-8", errors="replace") as f:
            body = f.read()
        with open(argv[3], encoding="utf-8", errors="replace") as f:
            diff = f.read()
        return check(body, diff)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
