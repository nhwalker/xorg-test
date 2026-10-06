#!/usr/bin/env python3
"""S10.3.2's static half: the global keywords of monitors.conf, three ways.

The keywords the documents offer, the keywords xorg-monitor-conf.sh accepts
and the keywords the container's preflight skips when it reads output names
must be the same set. A documented keyword the generator rejects costs the
whole layout (`watch` did, once: "mode wants WxH[@Hz], got '5'"), and one
the preflight does not skip is reported as an output with no connector.

  documents   monitors.conf's GLOBAL LINES (the file README.md says
              documents every field), and the keywords README.md's "Fixed
              monitor layout (KVM video)" names where it speaks of the
              global lines (`nvidia-*` standing for every nvidia- keyword)
  generator   the case labels xorg-monitor-conf.sh tries before it reads
              a line as an output
  preflight   the alternation preflight-check.sh drops before it reads the
              output names

  layout-keywords.py check [--evidence ROOT]   exit 1 unless they agree
  layout-keywords.py self-test                 the check against a README
                                               naming a keyword nothing
                                               accepts: it must fail
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = "README.md"
SECTION = "### Fixed monitor layout (KVM video)"
MONCONF = "deploy/host/etc/desktop-container/monitors.conf"
GENERATOR = "image/xorg/xorg-monitor-conf.sh"
PREFLIGHT = "image/xorg/preflight-check.sh"
WORD = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*(-?\*)?$")


def read(path):
    return open(os.path.join(ROOT, path), encoding="utf-8").read()


def monconf_keywords(text):
    """The keyword of each example line under GLOBAL LINES ('#   virtual 3840x1080')."""
    part = text.split("# GLOBAL LINES", 1)
    if len(part) < 2:
        raise SystemExit(f"{MONCONF}: no GLOBAL LINES section")
    return sorted({m.group(1) for m in re.finditer(r"^#   ([a-z][a-z0-9-]*)\s", part[1], re.M)})


def readme_names(text):
    """The backticked keywords in the README section's sentences about the global lines."""
    start = text.find(SECTION)
    if start < 0:
        raise SystemExit(f"{README}: no section '{SECTION}'")
    end = text.find("\n### ", start + len(SECTION))
    body = text[start:end if end > 0 else len(text)]
    names = set()
    for sentence in re.split(r"(?<=[.:;])\s+|\n\n", body):
        if "global" in sentence:
            names |= {t for t in re.findall(r"`([^`]+)`", sentence) if WORD.match(t)}
    return sorted(names)


def generator_keywords(text):
    """The labels of the case before '# --- an output line ---'."""
    head = text.split("# --- an output line ---", 1)[0]
    block = head.rsplit('case "$f1" in', 1)
    if len(block) < 2:
        raise SystemExit(f"{GENERATOR}: no keyword case before the output lines")
    return sorted(set(re.findall(r"^\s{4}([a-z][a-z0-9-]*)\)\s*$", block[1], re.M)))


def preflight_keywords(text):
    m = re.search(r"grep -vE '\^\[\[:space:\]\]\*\(([a-z0-9|-]+)\)\[\[:space:\]\]'", text)
    if not m:
        raise SystemExit(f"{PREFLIGHT}: no global-keyword alternation found")
    return sorted(m.group(1).split("|"))


def covered(name, keywords):
    if name.endswith("*"):
        return [k for k in keywords if k.startswith(name[:-1])]
    return [k for k in keywords if k == name]


def compare(readme_text):
    """(lists, problems): the three lists and every way they disagree."""
    docs = monconf_keywords(read(MONCONF))
    named = readme_names(readme_text)
    gen = generator_keywords(read(GENERATOR))
    pre = preflight_keywords(read(PREFLIGHT))
    problems = []
    for k in sorted(set(docs) | set(gen) | set(pre)):
        where = [n for n, s in (("monitors.conf", docs), ("xorg-monitor-conf.sh", gen), ("preflight-check.sh", pre)) if k in s]
        if len(where) < 3:
            problems.append(f"'{k}' is in {', '.join(where)} only")
    for n in named:
        if not covered(n, gen):
            problems.append(f"README.md names `{n}` as a global line, and the generator accepts no such keyword")
    for k in docs:
        if not any(covered(n, [k]) for n in named):
            problems.append(f"README.md's section does not name the global keyword '{k}' (monitors.conf documents it)")
    return {"monitors.conf": docs, "README.md": named, "xorg-monitor-conf.sh": gen, "preflight-check.sh": pre}, problems


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("check", "self-test"):
        raise SystemExit(__doc__)
    if args[0] == "self-test":
        text = read(README).replace("global `virtual` /", "global `virtual` / `watch` /", 1)
        if text == read(README):
            raise SystemExit("self-test: could not plant `watch` in README.md's global-lines sentence")
        _, problems = compare(text)
        print("\n".join(problems) or "(no problems found)")
        hit = any("`watch`" in p for p in problems)
        print("self-test:", "the planted `watch` was caught" if hit else "the planted `watch` was NOT caught")
        return 0 if hit else 1
    lists, problems = compare(read(README))
    for k, v in lists.items():
        print(f"{k}: {' '.join(v)}")
    print("\n".join(problems) if problems else "all three agree")
    root = args[2] if len(args) > 2 and args[1] == "--evidence" else ""
    if root:
        sys.path.insert(0, os.path.join(ROOT, "ci"))
        import evlib
        st = evlib.StoryWriter(root, "S10.3.2", "A layout the maintainer gets wrong costs no desktop, and the documented checks say what was wrong",
                               tier="T0", source=os.environ.get("EV_SOURCE", "layout-keywords.py"))
        names = {}
        for k, v in lists.items():
            names[k] = st.write(f"keywords-{k.split('.')[0].replace('-', '')}", "\n".join(v) + "\n",
                                f"EV-STATE: the global keywords {k} offers, one per line ({'as README.md names them, a trailing * a prefix' if k == 'README.md' else k})")
        for a, b in (("monitors.conf", "xorg-monitor-conf.sh"), ("monitors.conf", "preflight-check.sh")):
            import difflib
            diff = "".join(difflib.unified_diff(open(st.path(names[a])).readlines(), open(st.path(names[b])).readlines(), a, b))
            st.write(f"diff-{b.split('.')[0].replace('-', '')}", diff or f"(no differences between {a} and {b})\n",
                     f"EV-DIFF: the keywords {a} documents (-) against those {b} {'accepts' if 'conf' in b else 'skips'} (+): empty", ext="diff")
        st.check(lists["monitors.conf"] == lists["xorg-monitor-conf.sh"],
                 "the generator accepts exactly the global keywords monitors.conf documents: " + " ".join(lists["monitors.conf"]))
        st.check(lists["monitors.conf"] == lists["preflight-check.sh"],
                 "the container preflight skips exactly those keywords when it reads output names")
        st.check(not [p for p in problems if p.startswith("README")],
                 "README.md's section names every one of them (`nvidia-*` for the nvidia ones), and nothing else as a global line")
        st.finish()
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
