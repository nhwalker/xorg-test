#!/usr/bin/env python3
"""Hold the unit quadlet generated from desktop.container to what it must say.

  unit-directives.py <story> <generated unit> <desktop.container>

Prints one "PASS<TAB>claim" or "FAIL<TAB>claim" line per check, for the
caller to record as evidence. Directives are read per section of the
generated unit, never as text that appears somewhere: quadlet copies the
source's comments into its output, so a grep cannot tell an emitted
directive from a mention of one.

  S5.2.3  the [Unit]/[Service]/[Install] directives Requirements.md lists
  S5.2.4  every Volume=, Tmpfs=, Mount= and AddDevice= of the source as the
          podman argument it becomes in ExecStart
"""
import os
import shlex
import sys

LISTS = {"Wants", "After", "Before", "Requires", "Conflicts", "WantedBy", "PartOf"}
# The units desktop.service pulls in and orders itself after.
PULLED = ["desktop-seat-prep.service", "desktop-cdi-refresh.service",
          "desktop-client-cdi.service", "desktop-selinux.service",
          "desktop-tools-cdi.path", "desktop-host-shell.service"]


def sections(text):
    """{section: {key: [values]}}; list-valued keys split on whitespace."""
    out, cur = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = out.setdefault(line[1:-1], {})
            continue
        if cur is None or "=" not in line:
            continue
        key, val = line.split("=", 1)
        vals = val.split() if key in LISTS else [val]
        cur.setdefault(key, []).extend(vals)
    return out


def say(ok, claim):
    print(("PASS" if ok else "FAIL") + "\t" + claim)
    return ok


def s5_2_3(unit):
    u, svc, inst = unit.get("Unit", {}), unit.get("Service", {}), unit.get("Install", {})
    say("multi-user.target" in inst.get("WantedBy", []), "[Install] WantedBy=multi-user.target")
    for c in ("getty@tty1.service", "display-manager.service"):
        say(c in u.get("Conflicts", []), f"[Unit] Conflicts={c}")
    for p in PULLED:
        say(p in u.get("Wants", []), f"[Unit] Wants={p}")
        say(p in u.get("After", []), f"[Unit] After={p}")
    say("desktop-session.service" in u.get("Wants", []), "[Unit] Wants=desktop-session.service")
    say(svc.get("Restart") == ["always"], f"[Service] Restart=always (found {svc.get('Restart')})")
    say(svc.get("TimeoutStartSec") == ["300"],
        f"[Service] TimeoutStartSec=300 (found {svc.get('TimeoutStartSec')})")


def argv_pairs(unit):
    """ExecStart as (flag, value) pairs, both spellings: --f=v and --f v."""
    execs = unit.get("Service", {}).get("ExecStart", [])
    if not execs:
        say(False, "[Service] has an ExecStart")
        return set()
    args = shlex.split(execs[0])
    pairs = set()
    for i, a in enumerate(args):
        if a.startswith("--") and "=" in a:
            pairs.add(tuple(a.split("=", 1)))
        elif a.startswith("-") and i + 1 < len(args):
            pairs.add((a, args[i + 1]))
    return pairs


def s5_2_4(unit, source):
    pairs = argv_pairs(unit)
    src = sections(source).get("Container", {})
    flags = {"Volume": ("-v", "--volume"), "Tmpfs": ("--tmpfs",), "Mount": ("--mount",)}
    for key, accept in flags.items():
        vals = src.get(key, [])
        say(bool(vals), f"the source has {key}= lines ({len(vals)})")
        for v in vals:
            say(any((f, v) in pairs for f in accept),
                f"{key}={v} reaches ExecStart as {accept[0]} {v}")
    for v in src.get("AddDevice", []):
        optional = v.startswith("-")
        dev = v[1:] if optional else v
        present = any((f, dev) in pairs for f in ("--device",))
        if optional and not os.path.exists(dev):
            say(not present, f"AddDevice={v}: {dev} is absent here, so no --device {dev}")
        else:
            say(present, f"AddDevice={v} reaches ExecStart as --device {dev}"
                + (f" ({dev} exists where the unit was generated)" if optional else ""))


def main():
    story, unit_path, source_path = sys.argv[1:4]
    unit = sections(open(unit_path).read())
    if story == "S5.2.3":
        s5_2_3(unit)
    elif story == "S5.2.4":
        s5_2_4(unit, open(source_path).read())
    else:
        sys.exit(f"unknown story {story}")


if __name__ == "__main__":
    main()
