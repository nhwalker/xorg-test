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
#   ev_note <text>                    observed, recorded, deliberately not asserted
#   ev_save <moment> <what> <cmd...>  save cmd's output, stderr included, and
#                                     its exit status as a numbered file; also
#                                     prints that output and returns the status,
#                                     so `out=$(ev_save ...)` both keeps and uses
#                                     it (the same with evidence off)
#   ev_copy <src> <moment> <what>     copy a file in (EV-CONFIG)
#   ev_text <moment> <what> <text>    write text you already have
#   ev_diff <moment> <what> <a> <b>   diff -u of two evidence files
#   $EV_LAST                          the file the last ev_save/ev_copy/ev_text
#                                     wrote (not set when called inside $(...))
#   ev_attach <file> <what>           index a file already in the directory
#   ev_end [reason]                   settle PASS/FAIL, render evidence.md
#   ev_abort <reason>                 record a failure and end (for fail())
#
# Human-readable progress goes to stderr, never stdout: callers capture
# stdout with $(...) and must get only the command output they asked for.

EV_ROOT="${EV_ROOT:-}"
EV_SIDE="${EV_SIDE:-}"
EV_SOURCE="${EV_SOURCE:-}"
EV_STORY=""
EV_DIR=""
EV_LAST=""
EV_LIB_DIR="${EV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_ev_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
_ev_one() { printf '%s' "$*" | tr '\t\n' '  '; }

ev_log() { # <kind> <text>
    [ -n "$EV_ROOT" ] || return 0
    local line
    line="$(_ev_ts) $(printf '%-8s' "${EV_STORY:--}") $(printf '%-6s' "$1") $(_ev_one "$2")"
    printf '%s\n' "$line" >> "$EV_ROOT/timeline.log"
    [ -z "$EV_DIR" ] || printf '%s\n' "$line" >> "$EV_DIR/${EV_SIDE}timeline.log"
}

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
    [ -z "$EV_DIR" ] || printf '%s\t%s\t%s\n' "$(_ev_ts)" "$1" "$(_ev_one "$2")" >> "$EV_DIR/${EV_SIDE}checks.tsv"
    ev_log check "$1 $2"
}
ev_pass() { _ev_record PASS "$1"; }
ev_fail() { _ev_record FAIL "$1"; }

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

ev_diff() { # <moment> <what> <a> <b>   (names inside the story directory)
    [ -n "$EV_DIR" ] || return 0
    local name
    name=$(ev_name "$1" diff)
    diff -u "$EV_DIR/$3" "$EV_DIR/$4" > "$EV_DIR/$name" || true
    [ -s "$EV_DIR/$name" ] || echo "(no differences between $3 and $4)" > "$EV_DIR/$name"
    ev_attach "$name" "$2"
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
