#!/usr/bin/env python3
"""No client runs privileged or with SELinux separation off (Requirements.md S7.1.2).

Reads every shell script under ci/ and examples/ for `podman run` and
`podman create` commands, every Python file there for the argument lists it
builds them from, and every Kubernetes manifest there, and fails on:

  - --privileged, or --security-opt label=disable, on a podman command;
  - privileged: true, or an seLinuxOptions type of spc_t, in a manifest.

Commands are tokenized the way the shell reads them (shlex, quoted strings
kept whole), so the log lines, comments and failure messages that only NAME
--privileged - which a plain grep matches - are not taken for commands. In
Python, a string constant that IS one of the flags (not a sentence naming
it) is a violation wherever it appears, since an argument list can be built
in pieces. Every
command and manifest it judged is printed, ok or not, so the output is the
evidence.

  client-guard.py              scan ci/ and examples/ from the repo root
  client-guard.py --self-test  first prove it flags what it must, and only that
"""
import ast
import os
import re
import shlex
import sys
import tempfile

OPS = {";", "&&", "||", "|", "&", "(", ")", ";;"}
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def tokens(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    return list(lex)


def logical_commands(path, source=None):
    """(line number, text) for each shell command line, continuations and
    multi-line quoted strings joined, heredoc bodies skipped. `source`, when
    given, is read in place of the file (ci/e9-guard.py: a workflow's run:
    block)."""
    if source is None:
        with open(path, errors="replace") as f:
            source = f.read()
    lines = source.split("\n")
    i, out = 0, []
    while i < len(lines):
        start, text = i, lines[i]
        i += 1
        while text.endswith("\\") and i < len(lines):
            text = text[:-1] + " " + lines[i]
            i += 1
        # A quoted string that spans lines: keep reading until it closes.
        extra = 0
        while True:
            try:
                tokens(text)
                break
            except ValueError:
                if i >= len(lines) or extra > 400:
                    text = None
                    break
                text += "\n" + lines[i]
                i += 1
                extra += 1
        if text is None:
            out.append((start + 1, lines[start], None))
            continue
        out.append((start + 1, text, tokens(text)))
        m = HEREDOC.search(text)
        if m:  # skip the heredoc's body: it is data (python, a script), not commands here
            end = m.group(2)
            while i < len(lines) and lines[i].strip() != end:
                i += 1
            i += 1
    return out


def podman_commands(toks):
    """The argument lists of every podman run/create in a token list."""
    found = []
    for k, t in enumerate(toks):
        if (t == "podman" or t.endswith("/podman")) and k + 1 < len(toks) and toks[k + 1] in ("run", "create"):
            args = []
            for a in toks[k + 2:]:
                if a in OPS:
                    break
                args.append(a)
            found.append([toks[k + 1]] + args)
    return found


def violations(args):
    bad = []
    for n, a in enumerate(args):
        if a == "--privileged" or a.startswith("--privileged="):
            bad.append(a)
        if a.startswith("--security-opt=") and "label=disable" in a:
            bad.append(a)
        if a == "--security-opt" and n + 1 < len(args) and "label=disable" in args[n + 1]:
            bad.append(f"--security-opt {args[n + 1]}")
    return bad


def scan_shell(path, report):
    errors = 0
    for line, text, toks in logical_commands(path):
        if toks is None:
            if re.search(r"\bpodman\s+(run|create)\b", text) and re.search(r"--privileged|label=disable", text):
                report.append(f"VIOLATION {path}:{line}: unparsable line naming podman run and a forbidden flag: {text.strip()[:120]}")
                errors += 1
            continue
        for cmd in podman_commands(toks):
            bad = violations(cmd)
            shown = " ".join(" ".join(["podman"] + cmd).split())[:140]
            if bad:
                report.append(f"VIOLATION {path}:{line}: {shown}  <- {', '.join(bad)}")
                errors += 1
            else:
                report.append(f"ok        {path}:{line}: {shown}")
    return errors


FLAG = re.compile(r"^(--privileged(=.*)?|--security-opt=label=disable|label=disable)$")


def scan_python(path, report):
    errors = 0
    try:
        tree = ast.parse(open(path, errors="replace").read(), path)
    except SyntaxError as e:
        report.append(f"VIOLATION {path}: not parsable as Python ({e})")
        return 1
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and FLAG.match(node.value):
            report.append(f"VIOLATION {path}:{node.lineno}: the string {node.value!r}, a forbidden podman flag")
            errors += 1
        if isinstance(node, (ast.List, ast.Tuple)) and len(node.elts) >= 2:
            first = [e.value if isinstance(e, ast.Constant) else None for e in node.elts[:2]]
            if first[0] == "podman" and first[1] in ("run", "create"):
                shown = " ".join(e.value if isinstance(e, ast.Constant) else f"<{ast.unparse(e)}>" for e in node.elts)
                report.append(f"ok        {path}:{node.lineno}: {shown[:140]}")
    return errors


def scan_manifest(path, report):
    errors = 0
    with open(path, errors="replace") as f:
        body = [l.split("#", 1)[0] for l in f.read().split("\n")]
    text = "\n".join(body)
    if not re.search(r"^\s*kind:\s*(Pod|Deployment|DaemonSet|StatefulSet|Job)\b", text, re.M):
        return 0
    bad = []
    if re.search(r"^\s*privileged:\s*true\b", text, re.M):
        bad.append("privileged: true")
    if re.search(r"^\s*type:\s*['\"]?spc_t\b", text, re.M):
        bad.append("seLinuxOptions type spc_t")
    if bad:
        report.append(f"VIOLATION {path}: {', '.join(bad)}")
        errors += 1
    else:
        report.append(f"ok        {path}: a client manifest with neither privileged: true nor spc_t")
    return errors


def scan(root, report):
    errors = 0
    files = []
    for top in ("ci", "examples"):
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = [d for d in dirnames if d != "artifacts"]
            files += [os.path.join(dirpath, f) for f in filenames]
    for path in sorted(files):
        rel = os.path.relpath(path, root)
        if rel.endswith((".yaml", ".yml")):
            errors += scan_manifest(path, report)
            continue
        if rel.endswith(".py"):
            # The guards themselves (this one and ci/e9-guard.py, which
            # checks S9.2.1 over the same ground) name the flags to find them.
            if rel not in (os.path.join("ci", "client-guard.py"), os.path.join("ci", "e9-guard.py")):
                errors += scan_python(path, report)
            continue
        try:
            with open(path, errors="replace") as f:
                first = f.readline()
        except OSError:
            continue
        if rel.endswith(".sh") or re.match(r"#!.*\b(ba|da)?sh\b", first):
            errors += scan_shell(path, report)
    return errors


SELF_TEST = {
    "bad-privileged.sh": ("podman run --rm --privileged img true\n", 1),
    "bad-label.sh": ("out=$(podman run --rm --security-opt label=disable img sh -c 'id')\n", 1),
    "bad-multiline.sh": ("podman create --rm \\\n  --security-opt=label=disable \\\n  img sh -c '\n    echo \"x\"\n  '\n", 1),
    "ok-message.sh": ("fail \"podman run --privileged would hide this\"\nlog 'never podman run --privileged'\n", 0),
    "ok-comment.sh": ("# podman run --privileged img\npodman run --rm img true  # not --privileged\n", 0),
    "ok-heredoc.sh": ("python3 - <<'PY'\nprint('podman run --privileged x')\nPY\npodman run --rm img true\n", 0),
    "bad-flag.py": ("import subprocess\nsubprocess.run(['podman', 'run', '--rm', '--privileged', 'img'])\n", 1),
    "ok-message.py": ("print('never podman run --privileged')\nargs = ['podman', 'create', '--rm', 'img']\n", 0),
    "bad-pod.yaml": ("apiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: c\n      securityContext:\n        privileged: true\n", 1),
    "ok-pod.yaml": ("apiVersion: v1\nkind: Pod\n# privileged: true, said in a comment\nspec:\n  containers:\n    - name: c\n", 0),
}


def self_test():
    ok = True
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "ci"))
        os.makedirs(os.path.join(d, "examples"))
        for name, (body, want) in SELF_TEST.items():
            path = os.path.join(d, "ci", name)
            with open(path, "w") as f:
                f.write(body)
            rep = []
            scanner = scan_manifest if name.endswith(".yaml") else scan_python if name.endswith(".py") else scan_shell
            got = scanner(path, rep)
            verdict = "flagged" if got else "passed"
            expect = "flagged" if want else "passed"
            print(f"self-test {name}: {verdict} (want {expect})")
            for r in rep:
                print(f"    {r.replace(d + '/', '')}")
            ok &= (got > 0) == (want > 0)
    return ok


def main():
    if "--self-test" in sys.argv[1:]:
        if not self_test():
            print("client-guard: FAIL: the self-test did not flag what it must, or flagged what it must not")
            return 1
        print("client-guard: self-test passed")
    report = []
    errors = scan(".", report)
    print("\n".join(report))
    n_cmd = sum(1 for r in report if re.search(r": podman (run|create)\b", r))
    n_man = sum(1 for r in report if "manifest" in r or r.endswith(("spc_t", "privileged: true")))
    print(f"client-guard: {n_cmd} podman run/create command(s) and {n_man} client manifest(s) read; {errors} violation(s)")
    # Each violation again, last, where the end of the job log shows it
    # (Requirements.md S9.2.3).
    if errors:
        print("\n".join(r for r in report if r.startswith("VIOLATION")))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
