# shellcheck shell=bash
# Evidence writer for the shell test phases: T0 and T2 on the CI runner, and
# the VM guest at T3. Source it; it defines ev_* functions and nothing runs.
#
# It writes the same per-story directory as ci/evlib.py's StoryWriter (see the
# docstring there for the layout), and evlib.py renders evidence.md from it.
#
#   EV_ROOT    where story directories go; empty = evidence off (every
#              assertion still runs and still fails the test)
#   EV_SIDE    "" (default) for the story's own side; "h-" when the VM host
#              adds files to a story the guest is writing
#   EV_SOURCE  the job that ran it, recorded in meta.tsv ("build-smoke", ...)
#
#   ev_begin <story> <title> [tier]   open a story (closes nothing)
#   ev_check <claim> <cmd...>         run cmd; record PASS/FAIL; return its status
#   ev_pass <claim> / ev_fail <claim> record a check already decided
#   ev_failures                       each FAIL recorded in this shell, again:
#                                     what a script or step that went on past
#                                     its failures prints last, before failing
#   ev_note <text>                    observed, recorded, deliberately not asserted
#   ev_save <moment> <what> <cmd...>  save cmd's output, stderr included, and
#                                     its exit status as a numbered file; also
#                                     prints that output and returns the status,
#                                     so `out=$(ev_save ...)` both keeps and uses
#                                     it (the same with evidence off). A command
#                                     that fails has the end of its output
#                                     printed to stderr too, for the job log
#   ev_copy <src> <moment> <what>     copy a file in (EV-CONFIG)
#   ev_text <moment> <what> <text>    write text you already have
#   ev_diff <moment> <what> <a> <b> <expected>
#                                     diff -u of two evidence files; <expected>
#                                     says which lines are expected to differ,
#                                     "nothing" (or "nothing: why") when none
#                                     is, and goes into the index after <what>
#                                     (Requirements.md S9.3.2: the gate fails
#                                     a diff without it, and one expected to
#                                     differ in nothing that differs)
#   $EV_LAST                          the file the last ev_save/ev_copy/ev_text
#                                     wrote (not set when called inside $(...))
#   ev_last                           the file the story indexed last: what
#                                     $EV_LAST would hold after an ev_save run
#                                     inside $(...)
#   ev_named <moment>                 the file the story indexed under a moment,
#                                     in this run of the script or an earlier
#                                     one (a VM phase): the "before" to diff
#   ev_attach <file> <what>           index a file already in the directory
#   ev_end [reason]                   settle PASS/FAIL, render evidence.md
#   ev_abort <reason>                 record a failure and end (for fail())
#   ev_log <kind> <text>              one line of the timeline (EV-TIMELINE):
#                                     the run's and the open story's
#   ev_mark <label>                   an event a recording running now names
#                                     the frame of (EV-VIDEO, S9.3.5): a
#                                     "mark" line of the timeline
#
# Sourcing it also wraps podman and kubectl: each call a script makes while
# evidence is on is a line of the timeline before it runs (Requirements.md
# S9.3.6). The binary runs as ever; a call inside sh -c, timeout or xargs
# runs it directly and is not logged (ev_save, which keeps such a command,
# logs the file it writes).
#
# Human-readable progress goes to stderr, never stdout: callers capture
# stdout with $(...) and must get only the command output they asked for.

EV_ROOT="${EV_ROOT:-}"
EV_SIDE="${EV_SIDE:-}"
EV_SOURCE="${EV_SOURCE:-}"
EV_STORY=""
EV_DIR=""
EV_LAST=""
EV_FAILED=()
EV_LIB_DIR="${EV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_ev_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
podman() { ev_log podman "$*"; command podman "$@"; }
kubectl() { ev_log kubectl "$*"; command kubectl "$@"; }
# One TSV field: no tab, newline or carriage return inside it (ssh ends its
# messages with \r\n, and a reader splitting on \r would break the row).
_ev_one() { printf '%s' "$*" | tr '\t\n\r' '   '; }

# The first line of a command's output, read whole first: a reader that stops
# early (head -1) would fail the pipeline under pipefail once its producer
# writes again (Requirements.md S9.1.5). The command's own status is not kept.
first_of() { local o; o=$("$@" 2>/dev/null) || true; printf '%s' "${o%%$'\n'*}"; }

# A log, read until it has the line an assertion is about: <cmd...> (podman
# logs, journalctl, kubectl logs, or a helper that prints one) run every
# <interval> s until a line of its output (stderr included, CRs dropped)
# matches <ERE>, at most <tries> times. Prints the last output read, so
# `log=$(log_wait ...)` hands the assertion all of it; returns 1 if no line
# matched. A log lags what it records, journald most of all, so a log line
# is polled where a process or a socket may be read once (Requirements.md
# S9.1.4). An assertion that a line is absent reads after a log_wait for a
# line the same stream writes later, or polls for the absent line itself
# over a few seconds, its status 1 the pass.
log_wait() { # <tries> <interval> <ERE> <cmd...>
    local tries=$1 interval=$2 ere=$3 out="" i
    shift 3
    for ((i = 1; i <= tries; i++)); do
        out=$("$@" 2>&1 | tr -d '\r') || true
        if grep -qE -- "$ere" <<<"$out"; then
            printf '%s\n' "$out"
            return 0
        fi
        [ "$i" = "$tries" ] || sleep "$interval"
    done
    printf '%s\n' "$out"
    return 1
}

# An assertion over a generated artefact (a CDI spec, an Xorg config, a unit
# as systemd has it, a rendered chart) reads it without its comment lines, so
# a comment that names what is asserted cannot answer it (Requirements.md
# S9.1.2). gen_grep takes grep's options and pattern, then the file;
# gen_grep_text the same, then the text. Each keeps grep's own matching and
# exit status. No pipe: the comments are dropped before grep reads a line.
gen_uncommented() { grep -v -E '^[[:space:]]*(#|;)' -- "$@" || true; }
gen_grep() { local t; t=$(gen_uncommented "${@: -1}"); grep "${@:1:$#-1}" <<<"$t"; }
gen_grep_text() { local t; t=$(gen_uncommented <<<"${@: -1}"); grep "${@:1:$#-1}" <<<"$t"; }

ev_log() { # <kind> <text>
    [ -n "$EV_ROOT" ] || return 0
    local line
    line="$(_ev_ts) $(printf '%-8s' "${EV_STORY:--}") $(printf '%-6s' "$1") $(_ev_one "$2")"
    # The timeline never fails its caller: a podman call a script makes
    # before its first story (whose ev_begin makes $EV_ROOT) still runs.
    [ -d "$EV_ROOT" ] || mkdir -p "$EV_ROOT" 2>/dev/null || true
    { printf '%s\n' "$line" >> "$EV_ROOT/timeline.log"; } 2>/dev/null || true
    [ -z "$EV_DIR" ] || { printf '%s\n' "$line" >> "$EV_DIR/${EV_SIDE}timeline.log"; } 2>/dev/null || true
}

# The event a recording should name the frame of: what the harness did, as
# it does it (Requirements.md S9.3.5). The recorder reads the "mark" lines of
# the story's timeline when it stops (evlib.py video-events).
ev_mark() { ev_log mark "$1"; }

ev_begin() { # <story> <title> [tier]
    EV_STORY=$1
    EV_DIR=""
    echo "== ev($1): $2" >&2
    [ -n "$EV_ROOT" ] || return 0
    EV_DIR="$EV_ROOT/$1"
    mkdir -p "$EV_DIR"
    if [ -z "$EV_SIDE" ]; then
        {
            printf 'title\t%s\n' "$(_ev_one "$2")"
            printf 'tier\t%s\n' "$(_ev_one "${3:-}")"
            printf 'source\t%s\n' "$(_ev_one "$EV_SOURCE")"
        } > "$EV_DIR/meta.tsv"
        rm -f "$EV_DIR/result"
    fi
    ev_log begin "$2"
}

_ev_record() { # <PASS|FAIL> <claim>
    echo "== ev(${EV_STORY:--}): $1 $2" >&2
    [ "$1" = PASS ] || EV_FAILED+=("${EV_STORY:+$EV_STORY: }$2")
    [ -z "$EV_DIR" ] || printf '%s\t%s\t%s\n' "$(_ev_ts)" "$1" "$(_ev_one "$2")" >> "$EV_DIR/${EV_SIDE}checks.tsv"
    ev_log check "$1 $2"
}
ev_pass() { _ev_record PASS "$1"; }
ev_fail() { _ev_record FAIL "$1"; }
# Each failed claim this shell recorded, one "FAIL: <story>: <claim>" line
# each: what a script or a workflow step that checks several claims and goes
# on prints last, before it fails, where the end of the job log shows it
# (Requirements.md S9.2.3).
ev_failures() {
    [ "${#EV_FAILED[@]}" = 0 ] || printf 'FAIL: %s\n' "${EV_FAILED[@]}" >&2
}

ev_check() { # <claim> <cmd...>
    local claim=$1 rc=0
    shift
    "$@" || rc=$?
    if [ "$rc" = 0 ]; then ev_pass "$claim"; else ev_fail "$claim (exit $rc)"; fi
    return "$rc"
}

ev_note() { # <text>
    echo "== ev(${EV_STORY:--}): note: $1" >&2
    [ -z "$EV_DIR" ] || printf '%s\t%s\n' "$(_ev_ts)" "$(_ev_one "$1")" >> "$EV_DIR/${EV_SIDE}notes.tsv"
    ev_log note "$1"
}

ev_name() { # <moment> <ext> -> the next numbered file name
    local counter="$EV_DIR/.${EV_SIDE:+h}n" n
    n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter"
    printf '%s%02d-%s%s' "${EV_SIDE:+h}" "$n" "$1" "${2:+.$2}"
}

ev_last() { [ -z "$EV_DIR" ] || tail -n 1 "$EV_DIR/${EV_SIDE}files.tsv" 2>/dev/null | cut -f2; }
ev_named() { # <moment>
    [ -n "$EV_DIR" ] || return 0
    cut -f2 "$EV_DIR/${EV_SIDE}files.tsv" 2>/dev/null | grep -E "^h?[0-9]+-$1\.[a-z]+\$" | tail -n 1 || true
}

ev_attach() { # <file> <what>
    [ -n "$EV_DIR" ] || return 0
    printf '%s\t%s\t%s\n' "$(_ev_ts)" "$1" "$(_ev_one "$2")" >> "$EV_DIR/${EV_SIDE}files.tsv"
    ev_log file "$1: $2"
}

ev_save() { # <moment> <what> <cmd...>
    local moment=$1 what=$2 rc=0 name out
    shift 2
    if [ -z "$EV_DIR" ]; then
        "$@" 2>&1
        return
    fi
    name=$(ev_name "$moment" txt)
    out=$("$@" 2>&1) || rc=$?
    {
        printf '$ %s\n' "$*"
        printf '%s\n' "$out"
        printf '[exit %s]\n' "$rc"
    } > "$EV_DIR/$name"
    ev_attach "$name" "$what"
    EV_LAST=$name
    # A failed command's output reaches the job log too, not only its file:
    # the end of it, where a command says why (Requirements.md S9.2.3).
    if [ "$rc" != 0 ]; then
        echo "== ev(${EV_STORY:--}): $moment exited $rc; the end of its output ($name has all of it):" >&2
        tail -n 20 <<<"$out" >&2
    fi
    printf '%s\n' "$out"
    return "$rc"
}

ev_text() { # <moment> <what> <text>
    [ -n "$EV_DIR" ] || return 0
    local name
    name=$(ev_name "$1" txt)
    printf '%s\n' "$3" > "$EV_DIR/$name"
    ev_attach "$name" "$2"
    EV_LAST=$name
}

ev_copy() { # <src> <moment> <what>
    [ -n "$EV_DIR" ] || return 0
    local src=$1 ext name
    ext=${src##*/}
    case "$ext" in *.*) ext=${ext##*.} ;; *) ext=txt ;; esac
    name=$(ev_name "$2" "$ext")
    if cp "$src" "$EV_DIR/$name" 2>/dev/null; then
        ev_attach "$name" "$3"
        EV_LAST=$name
    else
        ev_note "could not copy $src for: $3"
    fi
}

ev_diff() { # <moment> <what> <a> <b> <expected>   (names inside the story directory)
    [ -n "$EV_DIR" ] || return 0
    local name
    name=$(ev_name "$1" diff)
    diff -u "$EV_DIR/$3" "$EV_DIR/$4" > "$EV_DIR/$name" || true
    [ -s "$EV_DIR/$name" ] || echo "(no differences between $3 and $4)" > "$EV_DIR/$name"
    ev_attach "$name" "$2${5:+; expected to differ: $5}"
}

ev_end() { # [reason]
    if [ -n "$EV_DIR" ] && [ -z "$EV_SIDE" ]; then
        local status=PASS reason=${1:-}
        if grep -q $'\tFAIL\t' "$EV_DIR/checks.tsv" 2>/dev/null || [ -n "$reason" ]; then
            status=FAIL
            [ -n "$reason" ] || reason=$(grep -m1 $'\tFAIL\t' "$EV_DIR/checks.tsv" | cut -f3)
        fi
        printf '%s%s\n' "$status" "${reason:+	$(_ev_one "$reason")}" > "$EV_DIR/result"
        ev_log end "$status"
        python3 "$EV_LIB_DIR/evlib.py" render "$EV_DIR" >/dev/null 2>&1 \
            || ev_log note "evidence.md not rendered here (no python3); the collector renders it"
    fi
    EV_STORY=""
    EV_DIR=""
}

ev_abort() { # <reason>
    [ -n "$EV_STORY" ] || return 0
    ev_fail "$1"
    ev_end "$1"
}
