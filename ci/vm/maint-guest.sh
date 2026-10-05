# shellcheck shell=bash
# The maintainer's journeys (Requirements.md E10), the guest's half: sourced
# by vm-guest.sh and run one step per call, `vm-guest.sh maint <step>`, by
# ci/vm/maint-e2e.sh on the VM host, which watches the screen and listens to
# the sound card between the steps.
#
# A step runs the documents' own commands as the documents write them, read
# out of them by ci/doc-blocks.py and never retyped; everything else a step
# runs only looks. What a later step needs from an earlier one (a boot id, a
# time, the file a "before" was saved in) is kept under $MT, on disk: these
# journeys reboot.

MT=/var/tmp/maint

# A story's title as Requirements.md gives it, so the two sides agree.
mt_title() { sed -n "s/^\*\*$1 \(.*\)\*\*\$/\1/p" Requirements.md; }
mt_begin() { ev_begin "$1" "$(mt_title "$1")" T3; }
mt_put() { mkdir -p "$MT"; printf '%s\n' "$2" > "$MT/$1"; }
mt_get() { cat "$MT/$1" 2>/dev/null || true; }
# A file ev_save wrote in the open story: its output alone, and its exit status.
mt_saved() { sed '1d;$d' "$EV_DIR/$1"; }
mt_saved_rc() { sed -n '$s/^\[exit \([0-9]*\)\]$/\1/p' "$EV_DIR/$1"; }

# The common set's before-and-after pair (Requirements.md E10):
# desktop-preflight's report and systemctl status 'desktop*', saved into the
# open story; mt_state_diff compares two moments of the same story.
mt_state() { # <moment> <when>
    if command -v desktop-preflight >/dev/null; then
        ev_save "preflight-$1" "EV-STATE: desktop-preflight $2" desktop-preflight >/dev/null || true
    else
        ev_text "preflight-$1" "EV-STATE: desktop-preflight $2: there is none, the deploy tree is not on this host yet" \
            "desktop-preflight: command not found"
    fi
    mt_put "$EV_STORY-$1-preflight" "$EV_LAST"
    ev_save "status-$1" "EV-STATE: systemctl status 'desktop*' $2" systemctl --no-pager status 'desktop*' >/dev/null || true
    mt_put "$EV_STORY-$1-status" "$EV_LAST"
}
mt_state_diff() { # <moment before> <moment after> <what happened between them>
    local k a b
    for k in preflight status; do
        a=$(mt_get "$EV_STORY-$1-$k") b=$(mt_get "$EV_STORY-$2-$k")
        if [ -n "$a" ] && [ -n "$b" ]; then
            ev_diff "$k-$1-$2" "EV-DIFF: $k, $1 (-) against $2 (+): $3" "$a" "$b"
        fi
    done
}

# EV-LOG-JOURNAL and EV-LOG-DESKTOP for a step's window, since <epoch>.
mt_logs() { # <since epoch> <the window>
    local at
    at=$(date -u -d "@$1" +%H:%M:%S)
    ev_save journal "EV-LOG-JOURNAL: journalctl -o short-precise --since $at UTC: $2" \
        journalctl --no-pager -o short-precise --since "@$1" >/dev/null || true
    if podman container exists desktop 2>/dev/null; then
        ev_save desktop-log "EV-LOG-DESKTOP: podman logs --since $at UTC desktop: $2" \
            podman logs --since "$1" desktop >/dev/null || true
    else
        ev_note "there is no desktop container to read a log from: $2"
    fi
}

# EV-PIDS: the desktop's processes in the container, the container itself, the
# host login session and every uid-61000 process on the host. The lines
# mt_pids_moved compares ("<what> <id> [<started>]") go to
# $MT/pids-<story>-<moment>.
mt_pids() { # <moment> <when>
    mkdir -p "$MT"
    {
        podman exec desktop ps -o comm=,pid= -C "$S737_COMMS" 2>/dev/null | awk '{print $1, $2}' || true
        echo "container $(podman inspect --format '{{.Id}}' desktop 2>/dev/null || echo none)"
        echo "desktop-session $(systemctl show -p MainPID --value desktop-session.service) $(systemctl show -p ActiveEnterTimestampMonotonic --value desktop-session.service)"
    } > "$MT/pids-$EV_STORY-$1"
    ev_save "pids-$1" "EV-PIDS: $2: the desktop's processes in the container (ps), the container (podman inspect), the host login session (systemctl show, loginctl) and every uid-61000 process on the host (ps -u 61000)" \
        sh -c 'echo "== in the container"; podman exec desktop ps -o pid,ppid,lstart,comm -C '"$S737_COMMS"' 2>&1 || echo "(no desktop container running)"
               echo "== the container"; podman inspect --format "{{.Id}} pid={{.State.Pid}} started={{.State.StartedAt}}" desktop 2>&1 || true
               echo "== the host login session"; systemctl show -p MainPID -p ActiveEnterTimestamp desktop.service desktop-session.service; loginctl list-sessions --no-pager --no-legend
               echo "== every uid-61000 process on the host"; ps -u 61000 -o pid,ppid,lstart,comm,args 2>&1 || echo "(none)"' >/dev/null || true
}
# Every desktop process and the container are new between two mt_pids
# moments, and the host login session started again with them (S5.8.2): a
# restart that was supposed to happen.
mt_pids_moved() { # <moment before> <moment after>
    local a="$MT/pids-$EV_STORY-$1" b="$MT/pids-$EV_STORY-$2" c same s0 s1
    for c in ${S737_COMMS//,/ }; do
        grep -q "^$c " "$a" || fail "there was no $c in the desktop $1"
        grep -q "^$c " "$b" || fail "there is no $c in the desktop $2"
    done
    same=$(awk 'NR == FNR {if ($1 != "desktop-session") seen[$1 " " $2] = 1; next} ($1 " " $2) in seen' "$a" "$b")
    [ -z "$same" ] || fail "the same process or container $1 and $2: $(echo $same)"
    ev_pass "every desktop process ($S737_COMMS) and the container itself are new: no pid and no container id is the same $1 and $2"
    s0=$(awk '$1 == "desktop-session" {print $2, $3}' "$a")
    s1=$(awk '$1 == "desktop-session" {print $2, $3}' "$b")
    [ -n "${s1%% *}" ] && [ "${s1%% *}" != 0 ] || fail "there is no host login session $2 (desktop-session.service MainPID ${s1%% *})"
    [ "${s0%% *}" != "${s1%% *}" ] && [ "${s0#* }" != "${s1#* }" ] \
        || fail "the host login session did not move with the container: desktop-session.service (MainPID, started) $s0 $1, $s1 $2"
    ev_pass "the host login session moved with it: desktop-session.service's MainPID ${s0%% *} -> ${s1%% *}, and it started again"
}

# No getty on any VT now, and none started since <epoch>: a login prompt on
# the operator's screen is a getty.
mt_no_getty() { # <since epoch> <when>
    local units j
    units=$(ev_save gettys "EV-STATE: systemctl list-units 'getty@tty*' 'autovt@*' $2: nothing" \
        systemctl list-units --no-pager --no-legend 'getty@tty*' 'autovt@*') || true
    [ -z "$(grep -v '^[[:space:]]*$' <<<"$units")" ] || fail "a getty runs on a VT $2: $units"
    j=$(ev_save getty-journal "EV-LOG-JOURNAL: journalctl -q -u 'getty@*' -u 'autovt@*' since $(date -u -d "@$1" +%H:%M:%S) UTC: empty, no getty on any VT did anything" \
        journalctl --no-pager -q -o short-precise --since "@$1" -u 'getty@*' -u 'autovt@*') || true
    [ -z "$(grep -v '^[[:space:]]*$' <<<"$j")" ] || fail "a getty was active $2: $(grep -m1 . <<<"$j")"
    ev_pass "no getty runs on any VT $2, and none was started"
}

# --- F10.1: provisioning a stock host from the documents ------------------------

# S10.1.1: deploy/HOST-REQUIRES.md's "Every host" line, run as written, then
# the journey's own tools, kept apart in the evidence.
mt_packages() {
    local raw line out rc=0 stock doc pkgs probes
    mt_begin S10.1.1
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is $(getenforce) on the stock host, not Enforcing"
    ev_save stock-host "EV-STATE: the stock host as this run found it: its release, kernel and SELinux mode, and which of the tools the tree and this journey use are there yet" \
        sh -c 'cat /etc/rocky-release; uname -r; getenforce; for c in podman sshd fuser semanage restorecon rsync paplay aplay; do printf "%-10s %s\n" "$c" "$(command -v "$c" || echo "(not installed)")"; done' >/dev/null || true
    ev_save rpm-stock "EV-STATE: rpm -qa | sort on the stock host, before anything is installed" sh -c 'rpm -qa | sort' >/dev/null \
        || fail "rpm -qa failed on the stock host"
    stock=$EV_LAST
    out=$(python3 ci/doc-blocks.py deploy/HOST-REQUIRES.md "Every host") \
        || fail "deploy/HOST-REQUIRES.md has no \"Every host\" command block: $out"
    ev_text block "EV-PROCEDURE: deploy/HOST-REQUIRES.md's \"Every host\" block, as this run read it" "$out"
    raw=$(python3 ci/doc-blocks.py deploy/HOST-REQUIRES.md "Every host" 1 --commands)
    line=$(cut -f1 <<<"$raw")
    [ "$(grep -c . <<<"$line")" = 1 ] && [ "${line#dnf install }" != "$line" ] \
        || fail "deploy/HOST-REQUIRES.md's \"Every host\" block is no longer one dnf install: $raw"
    ev_note "the block's one command, its continuation joined: $line"
    # dnf asks before it installs anything, and again before it trusts a
    # repository key it has not seen. A maintainer answers y at a terminal;
    # so does this (pty-answer.py: without a terminal, dnf refuses the key
    # outright, which a piped `yes` cannot answer).
    out=$(ev_save dnf-documented "EV-PROCEDURE: the block's command, run unmodified as root in the repository, at a terminal (ci/vm/pty-answer.py), each of dnf's questions answered y: its transcript and exit status" \
        python3 ci/vm/pty-answer.py "$line") || rc=$?
    [ "$rc" = 0 ] || fail "the documented package line exited $rc: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
    ev_pass "the documented line, run as written, exited 0"
    pkgs=$(sed 's/^dnf install //' <<<"$line" | tr ' ' '\n' | grep -v '^-' | grep . | paste -sd' ')
    # shellcheck disable=SC2086
    ev_save rpm-q "EV-STATE: rpm -q of each package the line names" rpm -q $pkgs >/dev/null \
        || fail "not every package the line names is installed: $pkgs"
    ev_pass "every package it names is installed: $pkgs"
    ev_save rpm-documented "EV-STATE: rpm -qa | sort after the documented line" sh -c 'rpm -qa | sort' >/dev/null || true
    doc=$EV_LAST
    ev_diff rpm-documented "EV-DIFF: what the documented line installed: rpm -qa on the stock host (-) against after it (+)" "$stock" "$doc"
    # The journey's own tools, which are not host requirements: rsync applies
    # the tree (deploy/README.md's provisioning tool), and paplay and aplay
    # are the host clients whose tones the VM host listens for.
    probes="rsync pulseaudio-utils alsa-utils"
    # shellcheck disable=SC2086
    ev_save dnf-probes "EV-PROCEDURE: this journey's own tools, installed after the documented line and not host requirements: rsync (the provisioning tool deploy/README.md uses), pulseaudio-utils (paplay) and alsa-utils (aplay)" \
        dnf -y install $probes >/dev/null || fail "could not install the journey's own tools: $probes"
    ev_save rpm-probes "EV-STATE: rpm -qa | sort after the journey's own tools" sh -c 'rpm -qa | sort' >/dev/null || true
    ev_diff rpm-probes "EV-DIFF: what the journey's own tools added after the documented line" "$doc" "$EV_LAST"
    ev_end
}

# The desktop image into podman's storage, which deploy/README.md asks for
# before the tree ("podman load / podman pull during provisioning").
mt_image() {
    mt_begin S10.1.2
    ev_save image-load "EV-PROCEDURE: the desktop image brought into podman's storage with podman load, as deploy/README.md asks before the tree; the archive is the one CI built, copied to /tmp by the VM host" \
        podman load -i /tmp/images-desktop.tar >/dev/null || fail "podman load of the desktop image failed"
    ev_save images "EV-STATE: podman images after the load" podman images >/dev/null || true
    podman image exists localhost/desktop-container:latest \
        || fail "localhost/desktop-container:latest is not in podman's storage after the load"
    ev_pass "localhost/desktop-container:latest is in podman's storage"
    ev_end
}

# S10.1.3's half of the apply step: right after the rsync, the host that
# takes the optional restorecon line runs it as written; the host that skips
# it keeps a dry run (-n) of it, which changes nothing.
mt_after_rsync() { # took|skipped
    local raw line rc=0 out
    mt_begin S10.1.3
    out=$(python3 ci/doc-blocks.py deploy/README.md Apply 2) \
        || fail "deploy/README.md's Apply section has no second command block (the restorecon line): $out"
    ev_text restorecon-block "EV-PROCEDURE: deploy/README.md's restorecon block, as this run read it" "$out"
    raw=$(python3 ci/doc-blocks.py deploy/README.md Apply 2 --commands)
    line=$(cut -f1 <<<"$raw")
    [ "$(grep -c . <<<"$line")" = 1 ] && [ "${line%% *}" = restorecon ] \
        || fail "deploy/README.md's second Apply block is no longer one restorecon command: $raw"
    mt_put restorecon-paths "$(tr ' ' '\n' <<<"$line" | sed 1d | grep -v '^-' | grep . | paste -sd' ')"
    if [ "$1" = took ]; then
        ev_note "this host takes the optional line, right after the rsync, where deploy/README.md places it"
        out=$(ev_save restorecon "EV-PROCEDURE: \`$line\`, as written, right after the rsync: its output and exit status" sh -c "$line") || rc=$?
        if [ "$rc" = 0 ]; then
            ev_pass "the restorecon line, run as written right after the rsync, exited 0"
        else
            # Not fail(): the document's next commands do not depend on it,
            # so the journey goes on and the story keeps the FAIL.
            ev_fail "the restorecon line, run as written right after the rsync, exited $rc: $(grep -m1 . <<<"$out")"
        fi
    else
        ev_note "this host skips the optional line; a dry run of it (-n changes nothing) shows what it would have changed right after the rsync"
        # shellcheck disable=SC2046
        ev_save dry-run-after-rsync "EV-STATE: restorecon -R -n -v over the line's paths right after the rsync (a dry run: -n changes nothing): every label the rsync left that the policy disagrees with, and the exit status" \
            restorecon -R -n -v $(mt_get restorecon-paths) >/dev/null || true
    fi
    ev_end
    mt_begin S10.1.2
}

# S10.1.2: deploy/README.md's "Apply" block, every command as written, its
# closing reboot included: the VM host sees the guest go, and watches the
# screen for the desktop without logging in.
mt_apply() { # took|skipped: whether this host takes S10.1.3's restorecon line
    local line rc n=0 stamps
    local -a cmds
    mt_begin S10.1.2
    mt_put since-apply "$(date +%s)"
    mt_state stock "on the stock host, before the tree"
    ev_save stock-seat "EV-STATE: the stock host before the tree: its getty on tty1 (the login prompt on the screen), no desktop accounts, no desktop units" \
        sh -c 'systemctl is-active getty@tty1.service; id desktop; id desktop-shell; systemctl list-units --all --no-pager --no-legend "desktop*"' >/dev/null || true
    ev_save stamps-before "EV-STATE: stat of /, /etc and /usr and of systemd's update stamps, before the rsync: systemd-sysusers.service runs at boot only while /usr is newer than /etc/.updated (ConditionNeedsUpdate=/etc)" \
        stat -c '%y %a %U:%G %n' / /etc /usr /etc/.updated /var/.updated >/dev/null || true
    stamps=$EV_LAST
    line=$(python3 ci/doc-blocks.py deploy/README.md Apply) || fail "deploy/README.md has no \"Apply\" command block: $line"
    ev_text apply-block "EV-PROCEDURE: deploy/README.md's \"Apply\" block, as this run read it; each command follows, run as written, as root in the repository" "$line"
    mapfile -t cmds < <(python3 ci/doc-blocks.py deploy/README.md Apply 1 --commands | cut -f1)
    [ "${#cmds[@]}" -ge 2 ] && [ "${cmds[-1]}" = reboot ] \
        || fail "deploy/README.md's Apply block no longer ends in reboot: ${cmds[*]}"
    for line in "${cmds[@]:0:${#cmds[@]}-1}"; do
        n=$((n + 1)) rc=0
        ev_save "apply-$n" "EV-PROCEDURE: \`$line\`, as written: its output and exit status" sh -c "$line" >/dev/null || rc=$?
        [ "$rc" = 0 ] || fail "\`$line\` exited $rc"
        ev_pass "\`$line\` exited 0"
        case "$line" in
            rsync\ *) mt_after_rsync "$1" ;;
        esac
    done
    ev_save stamps-after "EV-STATE: the same stat after the commands" \
        stat -c '%y %a %U:%G %n' / /etc /usr /etc/.updated /var/.updated >/dev/null || true
    ev_diff stamps "EV-DIFF: what the rsync did to /, /etc and /usr themselves: rsync -a gives each the time and mode of its deploy/host counterpart" "$stamps" "$EV_LAST"
    ev_save accounts "EV-STATE: id desktop and id desktop-shell before the reboot: neither exists yet, the first boot makes them" \
        sh -c 'id desktop; id desktop-shell' >/dev/null || true
    mt_state applied "after the block's commands, before its reboot"
    mt_state_diff stock applied "what the commands before the reboot changed"
    mt_logs "$(mt_get since-apply)" "from the stock host to the reboot"
    mt_put boot-before "$(cat /proc/sys/kernel/random/boot_id)"
    mt_put reboot-at "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    ev_note "the block's last line, \`reboot\`, runs as written at $(mt_get reboot-at) (the guest's clock); from here the VM host watches the screen, and nobody logs in until the desktop is on it"
    ev_end
    sync
    sh -c "${cmds[-1]}"
}

# A field of one unit's line in the unit-times table: "<unit> K=V K=V ...".
mt_field() { # <table> <unit> <key>
    awk -v u="$2" -v k="$3=" '$1 == u {for (i = 2; i <= NF; i++) if (index($i, k) == 1) {print substr($i, length(k) + 1); exit}}' <<<"$1"
}

# S10.1.2 and S10.1.1 on the first boot, with read-only probes only (the VM
# host has already seen the desktop on the screen).
mt_firstboot() {
    local b0 b1 tck xorg mwm m_x m_mwm first out who line indent u st su tf ds pf
    mt_begin S10.1.2
    b0=$(mt_get boot-before) b1=$(cat /proc/sys/kernel/random/boot_id)
    [ -n "$b0" ] && [ "$b1" != "$b0" ] || fail "this is not a new boot: boot id $b1, before the block's reboot ${b0:-unknown}"
    ev_pass "a new boot: boot id $b0 before the block's reboot, $b1 now"
    wait_for 30 2 "desktop.service active" systemctl is-active --quiet desktop.service
    wait_for 30 2 "the session's mwm" session_up

    # Who came first: the desktop, or a login?
    tck=$(getconf CLK_TCK)
    xorg=$(pgrep -u desktop -x Xorg | head -n1) mwm=$(pgrep -u desktop -x mwm | head -n1)
    [ -n "$xorg" ] && [ -n "$mwm" ] || fail "no Xorg or no mwm of the desktop user's on the host (Xorg '$xorg', mwm '$mwm')"
    m_x=$(awk -v t="$tck" '{printf "%.2f", $22 / t}' "/proc/$xorg/stat") || fail "could not read Xorg's start time"
    m_mwm=$(awk -v t="$tck" '{printf "%.2f", $22 / t}' "/proc/$mwm/stat") || fail "could not read mwm's start time"
    first=$(journalctl -b -u sshd -o json --no-pager | python3 -c '
import json, sys
for line in sys.stdin:
    e = json.loads(line)
    m = e.get("MESSAGE")
    if isinstance(m, str) and m.startswith("Accepted "):
        print("%.2f %s" % (int(e["__MONOTONIC_TIMESTAMP"]) / 1e6, m))
        break')
    ev_text login-order "EV-STATE: when the desktop came up and when anyone first logged in to the host this boot, in seconds since the kernel started: Xorg's and mwm's start (/proc/<pid>/stat) and sshd's first accepted login (journalctl -b -u sshd)" \
        "Xorg (pid $xorg) started at $m_x s
mwm (pid $mwm) started at $m_mwm s
first login: ${first:-(none this boot)}"
    [ -n "$first" ] || fail "sshd accepted no login this boot, yet this step came in over ssh"
    awk -v a="$m_mwm" -v b="${first%% *}" 'BEGIN {exit !(a < b)}' \
        || fail "someone logged in to the host (${first%% *} s) before the desktop's mwm started ($m_mwm s)"
    ev_pass "the desktop was up (mwm at $m_mwm s after the kernel started) before anyone logged in to the host (the first ssh login at ${first%% *} s)"
    ev_save analyze "EV-STATE: systemd-analyze on the first boot: the kernel's and userspace's time to the default target" systemd-analyze >/dev/null || true

    for u in desktop-seat-prep desktop-cdi-refresh desktop-client-cdi desktop-host-shell desktop-selinux; do
        st="$(systemctl show -p ActiveState --value "$u.service")/$(systemctl show -p Result --value "$u.service")"
        [ "$st" = active/success ] || fail "$u.service is $st on the first boot"
    done
    ev_pass "desktop.service is active, mwm runs, and the five boot oneshots are active and succeeded"

    out=$(ev_save accounts "EV-STATE: id desktop and id desktop-shell on the first boot" sh -c 'id desktop; id desktop-shell') \
        || fail "the first boot did not create both accounts: $out"
    grep -q '^uid=61000(desktop) ' <<<"$out" || fail "desktop is not uid 61000: $(head -n1 <<<"$out")"
    ev_pass "the first boot created desktop (uid 61000) and desktop-shell"
    out=$(ev_save unit-times "EV-STATE: each first-boot unit as systemctl show has it: whether its condition held, its result, and when it started (InactiveExit) and was up (ActiveEnter), in microseconds since the kernel started" \
        sh -c 'for u in systemd-sysusers systemd-tmpfiles-setup desktop-selinux desktop-host-shell desktop-seat-prep desktop-session desktop; do
                   printf "%s " "$u"; systemctl show -p ConditionResult -p Result -p InactiveExitTimestampMonotonic -p ActiveEnterTimestampMonotonic "$u.service" | paste -sd" "
               done') || true
    [ "$(mt_field "$out" systemd-sysusers ConditionResult)" = yes ] \
        || fail "systemd-sysusers.service did not run this boot (its ConditionNeedsUpdate=/etc did not hold), and nothing else creates the accounts"
    su=$(mt_field "$out" systemd-sysusers ActiveEnterTimestampMonotonic)
    tf=$(mt_field "$out" systemd-tmpfiles-setup InactiveExitTimestampMonotonic)
    ds=$(mt_field "$out" desktop-session InactiveExitTimestampMonotonic)
    [ "${su:-0}" -gt 0 ] && [ "${tf:-0}" -ge "$su" ] && [ "${ds:-0}" -ge "$su" ] \
        || fail "the first boot's order is wrong: systemd-sysusers up at ${su:-?} us, systemd-tmpfiles-setup started at ${tf:-?} us, desktop-session at ${ds:-?} us"
    ev_pass "systemd-sysusers ran this boot and was done ($su us) before systemd-tmpfiles-setup started ($tf us) and before desktop-session logged in as desktop ($ds us)"
    ev_save first-boot-units "EV-LOG-JOURNAL: journalctl -b -o short-precise -u systemd-sysusers -u systemd-tmpfiles-setup -u 'desktop*': the first boot's order" \
        journalctl -b --no-pager -o short-precise -u systemd-sysusers -u systemd-tmpfiles-setup -u 'desktop*' >/dev/null || true
    ev_save boot-journal "EV-LOG-JOURNAL: the whole first boot (journalctl -b -o short-precise)" \
        journalctl -b --no-pager -o short-precise >/dev/null || true
    ev_save desktop-log "EV-LOG-DESKTOP: podman logs desktop, the first boot" podman logs desktop >/dev/null || true

    # S3.3.3's window probes; the VM host samples the colours.
    out=$(ev_save tree "EV-STATE: xwininfo -root -tree on the first boot: the session's xterm, inside mwm's frame" xtree) \
        || fail "xwininfo could not read the window tree"
    line=$(grep -m1 '"XTerm")' <<<"$out") || fail "there is no xterm on the screen on the first boot"
    # A child of the root window is indented five spaces; mwm's frame puts
    # the xterm deeper.
    indent=${line%%[! ]*}
    [ "${#indent}" -gt 5 ] || fail "the xterm is not inside a window manager's frame: $line"
    ev_pass "the session's xterm is on the screen inside mwm's frame: ${line#"$indent"}"

    mt_state booted "on the first boot, the desktop up"
    pf=$(mt_get S10.1.2-booted-preflight)
    out=$(mt_saved "$pf")
    [ "$(mt_saved_rc "$pf")" = 0 ] && grep -q 'done: 0 FAIL' <<<"$out" \
        || fail "desktop-preflight reported FAILs on the first boot: $(grep 'FAIL:' <<<"$out" | head -n 3 | tr '\n' ' ')"
    ev_pass "desktop-preflight exits 0 on the first boot: 0 FAILs"
    mt_state_diff applied booted "what the first boot did"
    who=$(ev_save ssh-host "EV-STATE: ssh host whoami, run in the desktop container as the session user (S5.7.2): desktop-shell" \
        podman exec -u desktop -e HOME=/home/desktop desktop ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami) || true
    [ "$(tail -n1 <<<"$who")" = desktop-shell ] || fail "ssh host from the container answered '$(tail -n1 <<<"$who")', want desktop-shell"
    ev_pass "from the container, ssh host logs in as desktop-shell"
    ev_end

    # S10.1.1: the host the documented line provisioned has nothing to report.
    mt_begin S10.1.1
    ev_copy "$EV_ROOT/S10.1.2/$pf" preflight "EV-STATE: desktop-preflight's whole report on the first boot of the host the documented line provisioned: no FAIL and no WARN line"
    out=$(mt_saved "$EV_LAST")
    [ "$(mt_saved_rc "$EV_LAST")" = 0 ] || fail "desktop-preflight did not exit 0"
    ! grep -q 'WARN:' <<<"$out" || fail "desktop-preflight has something to report: $(grep 'WARN:' <<<"$out" | head -n 3 | tr '\n' ' ')"
    ev_pass "desktop-preflight exits 0 with no WARN: line: the documented packages leave it nothing to report"
    who=$(ev_save ssh-host "EV-STATE: ssh host whoami from the desktop container as the session user: Host Terminal's path works on this host (S5.7.2)" \
        podman exec -u desktop -e HOME=/home/desktop desktop ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami) || true
    [ "$(tail -n1 <<<"$who")" = desktop-shell ] || fail "ssh host from the container answered '$(tail -n1 <<<"$who")', want desktop-shell"
    ev_pass "Host Terminal's path works: ssh host from the container is desktop-shell"
    # HOST-REQUIRES.md: "No PipeWire/PulseAudio daemon" on the host, the
    # container owning /dev/snd. The documented line's packages bring user
    # units for one, and the desktop user's own host login session is where
    # they would start, in the runtime dir the container's PipeWire serves.
    ev_save user-audio "EV-STATE: the desktop user's host user manager, its PipeWire and WirePlumber units, and who listens on the runtime dir's audio sockets (ss -xlp)" \
        sh -c 'systemctl --user -M desktop@ --no-pager list-units --all "pipewire*" "wireplumber*" 2>&1; echo "== ss -xlp"; ss -xlp | grep -E "/run/user/61000/(pipewire-0|pulse/native)"' >/dev/null || true
    act=$(systemctl --user -M desktop@ list-units --state=active,listening --no-legend --plain 'pipewire*' 'wireplumber*' 2>/dev/null | awk '{print $1}' | paste -sd' ')
    if [ -z "$act" ]; then
        ev_pass "the desktop user's host session runs no PipeWire or WirePlumber unit: the runtime dir's audio sockets are the container's alone"
    else
        ev_fail "the desktop user's host session runs $act: a host audio server on the paths the container's PipeWire serves (HOST-REQUIRES.md: no daemon on the host)"
    fi
    ev_end
}

# After a tone that was not heard, in <story>: every audio server on the
# host and in the container, who listens where, and the container's graph.
mt_audio_diag() { # <story>
    mt_begin "$1"
    ev_save audio-diag "EV-STATE: after a tone that was not heard: every pipewire, wireplumber, pipewire-pulse and pulseaudio process with its user and cgroup, the listeners on /run/user/61000 and /run/desktop-audio, and the container's PipeWire graph (wpctl status)" \
        sh -c 'for p in $(pgrep -x "pipewire|wireplumber|pipewire-pulse|pulseaudio"); do printf "%s %s | %s\n" "$p" "$(ps -o user=,args= -p "$p")" "$(cut -d: -f3 /proc/$p/cgroup)"; done; echo "== ss -xlp"; ss -xlp | grep -E "/run/user/61000|/run/desktop-audio"; echo "== wpctl status in the container"; podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 desktop wpctl status 2>&1 | head -60' >/dev/null || true
    ev_end
}

# S10.1.1's host clients, printed for the VM host, which captures the sound
# card around them: rocky, an ordinary host user, with a clean environment.
mt_host_play() { # paplay|aplay
    local hz=440 rc=0
    [ "$1" = aplay ] && hz=1320
    gen_tone "$hz" "/tmp/mt-$1.wav" 3
    chmod 644 "/tmp/mt-$1.wav"
    echo "== $1 of a $hz Hz tone, as rocky with a clean environment (no PULSE_ or ALSA variables)"
    $ROCKY "$1" "/tmp/mt-$1.wav" || rc=$?
    echo "$1 exited $rc"
}

# S10.1.3 on the first boot: labels, and S7.1.1's confined probes.
mt_selinux() { # took|skipped
    local paths out n
    mt_begin S10.1.3
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is $(getenforce), not Enforcing"
    ev_pass "SELinux is Enforcing on this host, which $1 the restorecon line"
    paths=$(mt_get restorecon-paths)
    [ -n "$paths" ] || fail "the apply step left no restorecon paths"
    # shellcheck disable=SC2086
    out=$(ev_save dry-run-booted "EV-STATE: restorecon -R -n -v over the line's paths on the first boot (a dry run: -n changes nothing): a 'Would relabel' line for every label on disk the policy disagrees with now" \
        restorecon -R -n -v $paths) || true
    n=$(grep -c 'Would relabel' <<<"$out" || true)
    if [ "$n" = 0 ]; then
        ev_note "on the first boot of this host, which $1 the line, restorecon -n would relabel nothing under its paths: the labels agree with the policy everywhere there"
    else
        ev_note "on the first boot of this host, which $1 the line, restorecon -n would relabel $n path(s): $(grep 'Would relabel' <<<"$out" | head -n 3 | tr '\n' ' ')"
    fi
    if grep -qv 'Would relabel' <<<"$out"; then
        ev_note "restorecon -n also said: $(grep -v 'Would relabel' <<<"$out" | head -n 3 | tr '\n' ' ')"
    fi
    out=$(ev_save probe-display "EV-STATE: S7.1.1's confined display probe: a client given only desktop.local/display=all; its own SELinux label, then xdpyinfo's verdict" \
        podman run --rm --device desktop.local/display=all localhost/desktop-container:latest \
        sh -c 'cat /proc/self/attr/current; echo; xdpyinfo >/dev/null && echo XDPYINFO_OK') || true
    grep -q ':container_t:' <<<"$out" && grep -qx XDPYINFO_OK <<<"$out" \
        || fail "a confined display client did not open :0 as container_t: $(echo $out)"
    ev_pass "a confined display client (container_t) opens :0"
    out=$(ev_save probe-audio "EV-STATE: S7.1.1's confined audio probe: a client given only desktop.local/audio=all; its own SELinux label, then pactl info over the export" \
        podman run --rm --device desktop.local/audio=all localhost/desktop-container:latest \
        sh -c 'cat /proc/self/attr/current; echo; pactl info >/dev/null && echo PACTL_OK') || true
    grep -q ':container_t:' <<<"$out" && grep -qx PACTL_OK <<<"$out" \
        || fail "a confined audio client did not reach the export as container_t: $(echo $out)"
    ev_pass "a confined audio client (container_t) reaches the audio export"
    ev_save labels "EV-STATE: ls -Zd of every path the deploy tree installs, then ls -ZA /etc/desktop-container, on this host (which $1 the line)" \
        sh -c 'cd deploy/host && find . -mindepth 1 | sed "s|^\.||" | sort | while read -r p; do ls -Zd "$p"; done; ls -ZA /etc/desktop-container' >/dev/null || true
    ev_end
}

# --- F10.2: verifying a host the way the documents say to ------------------------

# The audio export, as README.md's table gives it to clients.
MT_PIPEWIRE=/run/desktop-audio/pipewire-0
MT_PULSE=unix:/run/desktop-audio/pulse

# Output that matches every <ERE> shows what it should: echoes
# "PASS<tab>shows ..." or "FAIL<tab>does not show ...".
mt_shows() { # <output file> <ERE> <what> [<ERE> <what>]...
    local f=$1 bad="" good=""
    shift
    while [ $# -ge 2 ]; do
        if grep -qE -- "$1" "$f"; then good="${good:+$good; }$2"; else bad="${bad:+$bad; }$2"; fi
        shift 2
    done
    if [ -z "$bad" ]; then printf 'PASS\tshows %s\n' "$good"; else printf 'FAIL\tdoes not show %s\n' "$bad"; fi
}

# A layout is declared when monitors.conf names an output, as the
# container's preflight reads it.
mt_layout_declared() {
    [ -n "$(grep -vE '^[[:space:]]*(#|$)' /etc/desktop-container/monitors.conf 2>/dev/null \
        | grep -vE '^[[:space:]]*(virtual|nvidia-connected|nvidia-edid)[[:space:]]')" ]
}

# What a documented verification line must show, as its comment says, by the
# line as the document writes it (spaces squeezed). A line not listed here
# fails: a new or changed line needs a decision about what it should show.
mt_judge() { # <command> <comment> <exit status> <output file>
    local c=$1 k=$2 rc=$3 f=$4
    case "$c" in
        "systemctl status desktop.service")
            if [ "$k" = "generated from the quadlet" ]; then
                mt_shows "$f" 'Active: active \(running\)' "desktop.service active (running)" \
                    'desktop\.container; generated' "a unit generated from the quadlet"
            else
                mt_shows "$f" 'Active: active \(running\)' "desktop.service active (running)"
            fi ;;
        "podman exec desktop test -f /run/desktop-init-ready && echo booted")
            mt_shows "$f" '^booted$' "booted" ;;
        "podman exec desktop pgrep -u desktop -x mwm")
            mt_shows "$f" '^[0-9]+$' "mwm's pid: the session runs" ;;
        "loginctl list-sessions")
            mt_shows "$f" 'desktop[[:space:]]+seat0[[:space:]]+tty1' "desktop's session on seat0, tty1" ;;
        "podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf")
            mt_shows "$f" 'Driver[[:space:]]+"(modesetting|nvidia)"' "the X driver chosen, modesetting or nvidia" ;;
        "podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf")
            if mt_layout_declared; then
                mt_shows "$f" 'Section "Monitor"' "the declared layout's Monitor sections"
            elif [ "$rc" != 0 ] && grep -q 'No such file' "$f"; then
                printf 'PASS\tno layout is declared, and the file is not there (the comment: "if declared")\n'
            else
                printf 'FAIL\tno layout is declared, yet the line did not say the file is missing\n'
            fi ;;
        "DISPLAY=:0 xrandr")
            mt_shows "$f" ' connected' "a connected output" '^ +[0-9]+x[0-9]+' "its modes" ;;
        "DISPLAY=:0 glxinfo -B")
            mt_shows "$f" 'OpenGL renderer string: .*(NVIDIA|llvmpipe)' "the renderer, NVIDIA or llvmpipe" ;;
        "fgconsole")
            mt_shows "$f" '^1$' "VT 1" ;;
        "podman exec desktop ps -o user= -C Xorg")
            mt_shows "$f" '^desktop$' "desktop, not root" ;;
        "podman logs desktop | grep align")
            mt_shows "$f" 'align' "the gid alignment lines" ;;
        "podman exec -u desktop desktop wpctl status")
            mt_shows "$f" '\[alsa\]' "a sound device (an ALSA device in PipeWire's list)" ;;
        "pw-play /usr/share/sounds/alsa/Front_Center.wav"|"paplay /usr/share/sounds/alsa/Front_Center.wav"|"aplay /usr/share/sounds/alsa/Front_Center.wav")
            if [ "$rc" = 0 ]; then printf 'PASS\texited 0 (whether it was heard is the VM host'"'"'s check, made afterwards)\n'
            else printf 'FAIL\texited %s\n' "$rc"; fi ;;
        "desktop-preflight")
            if [ "$rc" = 0 ]; then mt_shows "$f" 'done: 0 FAIL' "0 FAILs"; else printf 'FAIL\texited %s: a FAIL\n' "$rc"; fi ;;
        "systemctl cat desktop.service")
            mt_shows "$f" '^# /run/systemd/generator/desktop\.service' "the unit as quadlet generated it, from /run/systemd/generator" \
                'ExecStart=/usr/bin/podman run' "its podman run" ;;
        "systemctl is-enabled getty@tty1.service")
            mt_shows "$f" '^masked$' "masked" ;;
        "systemctl get-default")
            mt_shows "$f" '^multi-user\.target$' "multi-user.target" ;;
        "systemctl status desktop-seat-prep")
            mt_shows "$f" 'Active: active \(exited\)' "seat-prep ran" 'status=0/SUCCESS' "and succeeded: the seat converged" ;;
        "systemctl status desktop-cdi-refresh")
            mt_shows "$f" 'Active: active \(exited\)' "it ran" \
                '(wrote stub CDI spec|generated real CDI spec|keeping existing real CDI spec)' "its log line naming the spec it left" ;;
        "head -5 /etc/cdi/nvidia.yaml")
            mt_shows "$f" '(^# Stub CDI spec|^cdiVersion:)' "the stub's marker comment, or a real spec's start" ;;
        "systemctl status desktop-host-shell")
            mt_shows "$f" 'Active: active \(exited\)' "it ran" 'host shell converged: fresh key' "its log line about the fresh key" ;;
        "ls -l /etc/ssh/authorized_keys.d/")
            mt_shows "$f" '^-[-rwxs]+[.+]? +[0-9]+ +root +root .* desktop-shell$' "a desktop-shell entry owned by root" ;;
        "podman logs desktop | grep preflight:")
            if grep -q 'preflight: FAIL' "$f"; then printf 'FAIL\tthe container preflight reports a FAIL\n'
            else mt_shows "$f" 'preflight: PASS' "the container preflight's lines, none of them a FAIL"; fi ;;
        "desktop-monitors-capture")
            mt_shows "$f" '^# Captured from the running desktop' "the capture's header" \
                '^[A-Za-z][A-Za-z0-9._-]* +[0-9]+x[0-9]+@' "an output, as monitors.conf takes one" ;;
        "podman logs desktop | grep xorg-monitor-conf")
            mt_shows "$f" 'xorg-monitor-conf: .*(fixed layout|autodetect)' "the layout applied, or that Xorg autodetects" ;;
        *)
            printf 'FAIL\tthis line is new to the test: decide what it should show (mt_judge, ci/vm/maint-guest.sh)\n' ;;
    esac
}

# The condition a line's comment puts on it, as the environment that meets
# it (README.md's audio table); nothing for a line that runs as written alone.
mt_condition() { # <comment>
    case "$1" in
        "PIPEWIRE_REMOTE set") echo "PIPEWIRE_REMOTE=$MT_PIPEWIRE" ;;
        "PULSE_SERVER set") echo "PULSE_SERVER=$MT_PULSE" ;;
    esac
}
mt_checklist_doc() { # readme|deploy: "<file> <heading>"
    case "$1" in
        readme) echo "README.md|Verification checklist" ;;
        deploy) echo "deploy/README.md|Verify" ;;
        *) fail "no checklist named '$1'" ;;
    esac
}

# The players the README checklist presupposes, installed as declared probes:
# pipewire-utils for pw-play (paplay and aplay came with S10.1.1's probes).
mt_checklist_tools() {
    local before
    mt_begin S10.2.1
    ev_save rpm-before "EV-STATE: rpm -qa | sort before the checklist's own probe" sh -c 'rpm -qa | sort' >/dev/null || true
    before=$EV_LAST
    ev_save dnf-probes "EV-PROCEDURE: pipewire-utils (pw-play), which the README checklist's first audio line uses, installed as a declared probe: not a host requirement" \
        dnf -y install pipewire-utils >/dev/null || fail "could not install pipewire-utils"
    ev_save rpm-after "EV-STATE: rpm -qa | sort after it" sh -c 'rpm -qa | sort' >/dev/null || true
    ev_diff rpm-probe "EV-DIFF: what installing pipewire-utils added: whether it brought PipeWire's daemon (HOST-REQUIRES.md: no PipeWire daemon on the host)" "$before" "$EV_LAST"
    if rpm -q pipewire >/dev/null 2>&1; then
        ev_note "pipewire-utils brought the pipewire package (PipeWire's daemon) onto the host, which deploy/HOST-REQUIRES.md says the host does not have"
    else
        ev_note "pipewire-utils brought no PipeWire daemon (the pipewire package is not installed)"
    fi
    ev_save sounds "EV-STATE: the sample the audio lines play, and the package that owns it" \
        sh -c 'ls -l /usr/share/sounds/alsa/Front_Center.wav; rpm -qf /usr/share/sounds/alsa/Front_Center.wav' >/dev/null || true
    ev_end
}

# S10.2.1: one documented checklist, every line run as written, as root, and
# judged by what its comment says it shows. A line whose comment names a
# condition also runs with the condition met, and that run is judged.
mt_checklist() { # readme|deploy
    local doc heading raw n=0 cmd key k rc out cond verdict why table
    IFS='|' read -r doc heading <<<"$(mt_checklist_doc "$1")"
    mt_begin S10.2.1
    raw=$(python3 ci/doc-blocks.py "$doc" "$heading") || fail "$doc has no \"$heading\" command block"
    ev_text "block-$1" "EV-PROCEDURE: $doc's \"$heading\" block, as this run read it" "$raw"
    table="| # | command | comment | exit | verdict | output |
|---|---|---|---|---|---|"
    while IFS=$'\t' read -r cmd k; do
        n=$((n + 1)) rc=0
        key=$(tr -s ' ' <<<"$cmd")
        ev_save "$1-$n" "EV-STATE: $doc line $n run as written, as root: \`$key\` (its comment: ${k:-none})" \
            timeout 60 sh -c "$cmd" >/dev/null || rc=$?
        out=$EV_LAST
        cond=$(mt_condition "$k")
        if [ -n "$cond" ]; then
            ev_note "$doc line $n as written exited $rc; its comment's condition ($cond) is met for the run judged"
            rc=0
            ev_save "$1-$n-met" "EV-STATE: $doc line $n with the condition its comment names met ($cond): the run judged" \
                timeout 60 env "$cond" sh -c "$cmd" >/dev/null || rc=$?
            out=$EV_LAST
        fi
        verdict=$(mt_judge "$key" "$k" "$rc" "$EV_DIR/$out")
        why=${verdict#*$'\t'}
        table+=$'\n'"| $n | \`${key//|/\\|}\` | ${k//|/\\|} | $rc | ${verdict%%$'\t'*}: ${why//|/\\|} | $out |"
        if [ "${verdict%%$'\t'*}" = PASS ]; then
            ev_pass "$doc line $n, \`$key\`: $why"
        else
            ev_fail "$doc line $n, \`$key\`: $why (exit $rc)"
        fi
    done < <(python3 ci/doc-blocks.py "$doc" "$heading" 1 --commands)
    ev_text "table-$1" "EV-STATE: $doc's checklist, one row per line: the command, its comment, the exit status of the run judged, the verdict, and the file with its output" "$table"
    ev_end
}

# One audio line of the README checklist, printed for the VM host, which
# captures the sound card around it: as written, with its comment's
# condition met, or in a scratch container the way README.md's "Other
# containers" does it.
mt_checklist_play() { # pw-play|paplay|aplay written|met|container
    local cmd k rc=0 cond
    while IFS=$'\t' read -r cmd k; do
        case "$cmd" in "$1 "*) break ;; esac
        cmd=""
    done < <(python3 ci/doc-blocks.py README.md "Verification checklist" 1 --commands)
    [ -n "$cmd" ] || fail "the README checklist has no $1 line"
    cmd=$(tr -s ' ' <<<"$cmd")
    case "$2" in
        written)
            echo "== as written, as root: $cmd"
            timeout 60 sh -c "$cmd" || rc=$? ;;
        met)
            cond=$(mt_condition "$k")
            echo "== with its comment's condition met (${cond:-it names none}): $cmd"
            timeout 60 env ${cond:+"$cond"} sh -c "$cmd" || rc=$? ;;
        container)
            # README.md, "Other containers": mount the socket dir and set the
            # variable, or for ALSA add the deploy tree's two stanzas (a copy,
            # so the container's label goes on the copy and not on the host's).
            local -a o=(-v /run/desktop-audio:/run/desktop-audio)
            case "$1" in
                pw-play) o+=(-e "PIPEWIRE_REMOTE=$MT_PIPEWIRE") ;;
                paplay) o+=(-e "PULSE_SERVER=$MT_PULSE") ;;
                aplay)
                    cp /etc/alsa/conf.d/99-zz-desktop-container.conf /tmp/mt-alsa.conf
                    o+=(-v "/tmp/mt-alsa.conf:/etc/alsa/conf.d/99-zz-desktop-container.conf:ro,z") ;;
            esac
            echo "== in a scratch container of the desktop image: podman run --rm ${o[*]} localhost/desktop-container:latest $cmd"
            timeout 60 podman run --rm "${o[@]}" localhost/desktop-container:latest sh -c "$cmd" || rc=$? ;;
        *) fail "checklist-play: written, met or container" ;;
    esac
    echo "exited $rc"
}

# S10.2.2: a client of the desktop's running through the checklists - an
# xterm on the screen, and a tone the VM host listens to - and the state
# that must not change while they run.
MT_CLIENT=mt-client
mt_quiet() { # start <seconds>|state <moment>|ended|remove
    local f i
    mt_begin S10.2.2
    case "$1" in
        start)
            mkdir -p "$MT"
            # Nothing of the harness's own may come or go meanwhile: the sink
            # xterm of an earlier typing check retires now, not mid-run. The
            # client's xterm keeps its title (no allowTitleOps), so a prompt
            # cannot rename it between the two window trees.
            podman exec desktop pkill -f 'xterm -T inputtest' 2>/dev/null || true
            gen_tone 330 /tmp/mt-client.wav "${2:?seconds}"
            podman rm -f "$MT_CLIENT" >/dev/null 2>&1 || true
            ev_save client "EV-PROCEDURE: the client: a confined container given the display and audio devices, an xterm (mt-client) on the screen and a ${2} s 330 Hz tone through PipeWire's pulse server" \
                podman create --name "$MT_CLIENT" --device desktop.local/display=all --device desktop.local/audio=all \
                localhost/desktop-container:latest \
                sh -c 'xterm -name mt-client -T mt-client -xrm "XTerm*allowTitleOps: false" -geometry 40x6+700+420 & paplay /tmp/mt-client.wav; echo "paplay exited $?"; wait' >/dev/null \
                || fail "could not create the client"
            podman cp /tmp/mt-client.wav "$MT_CLIENT:/tmp/mt-client.wav" || fail "could not give the client its tone"
            podman start "$MT_CLIENT" >/dev/null || fail "the client did not start"
            for i in $(seq 20); do
                f=$(xtree 2>/dev/null || true)
                grep -q '"mt-client"' <<<"$f" && break
                sleep 1
            done
            grep -q '"mt-client"' <<<"$f" || fail "the client's xterm did not appear"
            ev_pass "the client runs: its xterm is on the screen and its tone plays"
            ;;
        state)
            : "${2:?moment}"
            ev_save "pids-$2" "EV-PIDS, $2 the checklists: the desktop's processes (ps in the container) and the client's (podman top: their host pids), the client's container pid and restart count" \
                sh -c 'podman exec desktop ps -o pid,lstart,comm -C desktop-init,Xorg,mwm,pipewire,wireplumber,pipewire-pulse
                       podman inspect --format "client pid={{.State.Pid}} restarts={{.RestartCount}} started={{.State.StartedAt}}" '"$MT_CLIENT"'
                       podman top '"$MT_CLIENT"' hpid comm' >/dev/null || true
            mt_put "quiet-$2-pids" "$EV_LAST"
            ev_save "xrandr-$2" "EV-STATE: xrandr --query --verbose, $2 the checklists" xrv >/dev/null || true
            mt_put "quiet-$2-xrandr" "$EV_LAST"
            ev_save "tree-$2" "EV-STATE: xwininfo -root -tree, $2 the checklists" xtree >/dev/null || true
            mt_put "quiet-$2-tree" "$EV_LAST"
            ev_save "files-$2" "EV-STATE: ls -l --time-style=full-iso of /etc/cdi and /etc/desktop-container on the host and of /etc/X11/xorg.conf.d in the container, $2 the checklists" \
                sh -c 'ls -l --time-style=full-iso /etc/cdi /etc/desktop-container; echo "== in the container"; podman exec desktop ls -l --time-style=full-iso /etc/X11/xorg.conf.d' >/dev/null || true
            mt_put "quiet-$2-files" "$EV_LAST"
            if [ "$2" = after ]; then
                for i in pids xrandr tree files; do
                    ev_diff "$i" "EV-DIFF: $i before (-) and after (+) the checklists: empty" "$(mt_get "quiet-before-$i")" "$(mt_get "quiet-after-$i")"
                    if diff -q "$EV_DIR/$(mt_get "quiet-before-$i")" "$EV_DIR/$(mt_get "quiet-after-$i")" >/dev/null 2>&1; then
                        ev_pass "the checklists changed nothing in the $i"
                    else
                        ev_fail "the checklists changed the $i (see its diff)"
                    fi
                done
            fi
            ;;
        ended)
            for i in $(seq 120); do
                f=$(podman logs "$MT_CLIENT" 2>/dev/null || true)
                grep -q '^paplay exited' <<<"$f" && break
                sleep 1
            done
            f=$(ev_save client-log "EV-LOG-CLIENT: the client's own log: its player's exit status" podman logs "$MT_CLIENT") || true
            grep -qx 'paplay exited 0' <<<"$f" || fail "the client's player did not play its tone through: $(tail -n 3 <<<"$f")"
            ev_pass "the client's player played its whole tone and exited 0"
            ;;
        remove)
            podman rm -f "$MT_CLIENT" >/dev/null 2>&1 || true
            ;;
    esac
    ev_end
}

# --- F10.3: changing a running host's configuration -------------------------------

MT_MONCONF=/etc/desktop-container/monitors.conf
MT_ALT=localhost/desktop-container:alt
MT_PIN=/etc/containers/systemd/desktop.container.d/50-image.conf
MT_UPC=mt-upclient

# A service command one of these journeys runs, with its time, in <story>.
# Its exit status is recorded, not judged: the step after it looks at what
# the command did (a restart with the image gone is meant to fail).
mt_svc() { # <story> restart|start|stop
    local rc=0
    mt_begin "$1"
    ev_save "svc-$2" "EV-PROCEDURE: systemctl $2 desktop.service, and how long it took to return (bash's time)" \
        bash -c "time systemctl $2 desktop.service" >/dev/null || rc=$?
    ev_note "systemctl $2 desktop.service exited $rc"
    ev_end
}

# The first output the capture declared: "<name> <WxH@Hz> <+X+Y>".
mt_captured() { sed -n 1p "$MT/captured-outputs"; }

# S10.3.1: the documented capture, its stdout pasted into monitors.conf as it
# is; the VM host then restarts the desktop. Each F10.3 change is bracketed by
# F10.4's before and after steps (E10's common set: the state, the pids, the
# logs for the window, every desktop process new after the restart).
mt_layout_capture() {
    local rc=0 name
    mt_begin S10.3.1
    ev_save xrandr-before "EV-STATE: xrandr --query --verbose, autodetected" xrv >/dev/null || true
    mt_put S10.3.1-xrv-before "$EV_LAST"
    ev_save geometry-before "EV-STATE: xrandr --query, autodetected: the arrangement to freeze" xr >/dev/null || true
    cp "$MT_MONCONF" "$MT/monitors.conf.shipped"
    desktop-monitors-capture > "$MT/capture.txt" 2> "$MT/capture.err" || rc=$?
    ev_copy "$MT/capture.txt" capture "EV-PROCEDURE: desktop-monitors-capture's stdout, run as root (deploy/README.md \"Fixed monitor layout\": run it, paste, restart); it exited $rc"
    [ "$rc" = 0 ] || fail "desktop-monitors-capture exited $rc: $(cat "$MT/capture.err")"
    grep -vE '^[[:space:]]*(#|$)' "$MT/capture.txt" > "$MT/captured-outputs" || true
    [ -s "$MT/captured-outputs" ] || fail "the capture declares no output"
    name=$(mt_captured | awk '{print $1}')
    mt_put autogeom "$(xr_line "$name" | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)"
    cp "$MT/capture.txt" "$MT_MONCONF"
    ev_copy "$MT_MONCONF" monitors-conf "EV-CONFIG: /etc/desktop-container/monitors.conf after the paste: the capture's stdout, unmodified"
    [ "$(sha256sum < "$MT/capture.txt")" = "$(sha256sum < "$MT_MONCONF")" ] || fail "monitors.conf is not the capture's stdout"
    ev_pass "monitors.conf now holds the capture's stdout unmodified, declaring: $(paste -sd';' "$MT/captured-outputs")"
    ev_end
}

# S10.3.1 after the restart: pinned where it was, said so by the documented
# checks, and S3.4.10's live disconnect holds it.
mt_layout_pinned() {
    local name mode pos geom gen out conn dims0 dims1 m0 m1
    mt_begin S10.3.1
    desk_back
    gen=$(ev_save generated "EV-CONFIG: /etc/X11/xorg.conf.d/30-monitors.conf in the container, as xorg-monitor-conf generated it from the pasted file" \
        podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf) || fail "there is no 30-monitors.conf in the container after the restart"
    ev_save geometry-after "EV-STATE: xrandr --query with the layout pinned" xr >/dev/null || true
    while read -r name mode pos _; do
        geom="${mode%%@*}$pos"
        grep -q "\"$name\"" <<<"$gen" || fail "30-monitors.conf does not name $name"
        xr_is "$name" connected "$geom" || fail "$name is not at the captured geometry $geom: $(xr_line "$name")"
        ev_pass "$name is named in 30-monitors.conf and sits at the captured geometry: $(xr_line "$name")"
    done < "$MT/captured-outputs"
    ev_save xrandr-after "EV-STATE: xrandr --query --verbose with the layout pinned" xrv >/dev/null || true
    ev_diff xrandr "EV-DIFF: xrandr --query --verbose autodetected (-) and pinned (+): the mode names may change to cvt(1)'s, as monitors.conf's comments say" \
        "$(mt_get S10.3.1-xrv-before)" "$EV_LAST"
    m0=$(grep -m1 '\*' "$EV_DIR/$(mt_get S10.3.1-xrv-before)" | awk '{print $1}')
    m1=$(grep -m1 '\*' "$EV_DIR/$EV_LAST" | awk '{print $1}')
    ev_note "the current mode's name: $m0 autodetected, $m1 pinned (the expected change, when there is one, is to the cvt(1) name)"
    out=$(ev_save log-lines "EV-LOG-DESKTOP: the desktop log's xorg-monitor-conf: and preflight: lines" \
        sh -c 'podman logs desktop 2>&1 | grep -E "xorg-monitor-conf:|preflight:"') || true
    grep -q 'preflight: PASS: fixed monitor layout declares' <<<"$out" || fail "the container preflight did not print its fixed-layout PASS line"
    ev_pass "the container preflight says: $(grep -m1 'preflight: PASS: fixed monitor layout declares' <<<"$out" | sed 's/.*preflight: //')"
    read -r name mode pos _ <<<"$(mt_captured)"
    geom="${mode%%@*}$pos"
    conn=$(ls -d /sys/class/drm/card*-"$name" 2>/dev/null | head -n1)
    [ -n "$conn" ] || fail "no DRM connector named $name"
    dims0=$(dpy_dims)
    echo off > "$conn/status"
    [ "$(cat "$conn/status")" = disconnected ] || { echo detect > "$conn/status"; fail "forcing $conn off did not take"; }
    sleep 3
    ev_save forced-off "EV-STATE: xrandr --query with $name's connector forced off under the running server" xr >/dev/null || true
    if ! xr_is "$name" disconnected "$geom"; then
        echo detect > "$conn/status"
        fail "with $name forced off its geometry moved: $(xr_line "$name")"
    fi
    dims1=$(dpy_dims)
    echo detect > "$conn/status"
    wait_for 15 1 "$name connected again" xr_is "$name" connected "$geom"
    [ "$dims0" = "$dims1" ] || fail "the screen went from $dims0 to $dims1 with $name forced off"
    ev_pass "S3.4.10's live disconnect holds: forced off, $name stays at $geom on a $dims0 screen, and it comes back connected there"
    ev_end
}

# S10.3.2: a monitors.conf the maintainer gets wrong, or unusual, one case
# per restart. The VM host restarts the desktop between this and the check.
mt_layout_case() { # malformed|unknown|virtual|nvidia-connected|nvidia-edid
    local name mode pos w h
    mt_begin S10.3.2
    read -r name mode pos _ <<<"$(mt_captured)"
    w=${mode%%x*} h=${mode#*x}
    h=${h%%@*}
    case "$1" in
        malformed) printf '# S10.3.2 (a): a malformed position, on line 2\n%s %s 0+0\n' "$name" "$mode" ;;
        unknown) printf '# S10.3.2 (b): an output name that matches no connector\nHDMI-9 1024x768@60 +0+0\n' ;;
        virtual) printf '# S10.3.2 (c): virtual, beside a valid output line\nvirtual %sx%s\n%s %s +0+0\n' "$((w * 2))" "$h" "$name" "$mode" ;;
        nvidia-connected) printf '# S10.3.2 (c): nvidia-connected, beside a valid output line\nnvidia-connected DFP-0\n%s %s +0+0\n' "$name" "$mode" ;;
        nvidia-edid) printf '# S10.3.2 (c): nvidia-edid, beside a valid output line\nnvidia-edid DFP-0=/etc/desktop-container/edid-dfp0.bin\n%s %s +0+0\n' "$name" "$mode" ;;
        restore) cat "$MT/monitors.conf.shipped" ;;
        *) fail "no layout case named $1" ;;
    esac > "$MT_MONCONF"
    ev_copy "$MT_MONCONF" "monitors-conf-$1" "EV-CONFIG: monitors.conf for the case '$1'"
    ev_end
}
mt_layout_case_check() { # the same case, after the restart
    local name mode pos log pf gen=yes dims
    mt_begin S10.3.2
    desk_back
    read -r name mode pos _ <<<"$(mt_captured)"
    log=$(ev_save "monconf-$1" "EV-LOG-DESKTOP: podman logs desktop | grep xorg-monitor-conf, the case '$1'" \
        sh -c 'podman logs desktop 2>&1 | grep xorg-monitor-conf') || true
    pf=$(ev_save "preflight-$1" "EV-LOG-DESKTOP: podman logs desktop | grep preflight:, the case '$1'" \
        sh -c 'podman logs desktop 2>&1 | grep preflight:') || true
    ev_save "xrandr-$1" "EV-STATE: xrandr --query, the case '$1'" xr >/dev/null || true
    podman exec desktop test -e /etc/X11/xorg.conf.d/30-monitors.conf || gen=no
    case "$1" in
        malformed)
            grep -q "xorg-monitor-conf: ERROR: $MT_MONCONF:2: position wants +X+Y" <<<"$log" \
                || fail "no ERROR line naming line 2's position: $(echo $log)"
            [ "$gen" = no ] || fail "a 30-monitors.conf was generated from a malformed file"
            xr_is "$name" connected "$(mt_get autogeom)" || fail "$name is not at its autodetected geometry: $(xr_line "$name")"
            ev_pass "(a) a malformed position: the log names the file and line 2 ($(grep -m1 'ERROR' <<<"$log" | sed 's/.*ERROR: //')), nothing is generated, and $name autodetects at $(mt_get autogeom)" ;;
        unknown)
            grep -q 'preflight: WARN: fixed monitor layout names output(s) HDMI-9 with no matching DRM connector' <<<"$pf" \
                || fail "the container preflight does not WARN about HDMI-9: $(grep 'fixed monitor layout' <<<"$pf")"
            ev_pass "(b) an output name that matches no connector: the container preflight WARNs, naming it: $(grep -m1 'HDMI-9' <<<"$pf" | sed 's/.*preflight: //')" ;;
        virtual|nvidia-connected|nvidia-edid)
            grep -q "xorg-monitor-conf: fixed layout [0-9]*x[0-9]*: $name " <<<"$log" || fail "the layout with '$1' was not applied: $(echo $log)"
            ! grep -q 'xorg-monitor-conf: ERROR' <<<"$log" || fail "'$1' gave an ERROR: $(grep -m1 ERROR <<<"$log")"
            [ "$gen" = yes ] || fail "no 30-monitors.conf was generated with '$1'"
            if [ "$1" = virtual ]; then
                dims=$(dpy_dims)
                [ "$dims" = "$(grep -m1 '^virtual ' "$MT_MONCONF" | awk '{print $2}')" ] || fail "the screen is $dims, not the declared virtual size"
            fi
            ev_pass "(c) '$1' with a valid value beside a valid output line: the layout is applied ($(grep -m1 'fixed layout' <<<"$log" | sed 's/.*xorg-monitor-conf: //'))" ;;
        restore)
            [ "$gen" = no ] || fail "the shipped monitors.conf still generated a layout"
            ev_pass "the shipped monitors.conf is back: nothing generated, the desktop autodetects" ;;
    esac
    ev_end
}

# S10.3.4: the image the unit names, gone; desktop-preflight names it.
mt_image_gone() {
    local rc=0 out st
    mt_begin S10.3.4
    ev_save stop "EV-PROCEDURE: systemctl stop desktop.service" systemctl stop desktop.service >/dev/null || fail "could not stop the desktop"
    ev_save rmi "EV-PROCEDURE: podman rmi localhost/desktop-container:latest with the unit stopped: the image the unit names leaves podman's storage" \
        podman rmi localhost/desktop-container:latest >/dev/null || fail "could not remove the image"
    ev_save images "EV-STATE: podman images: no desktop image" podman images >/dev/null || true
    ev_save restart "EV-PROCEDURE: systemctl restart desktop.service with the image gone" systemctl restart desktop.service >/dev/null || rc=$?
    sleep 10
    st=$(systemctl show -p ActiveState --value desktop.service)
    ev_save status-gone "EV-STATE: systemctl status desktop.service, the image gone" systemctl --no-pager status desktop.service >/dev/null || true
    [ "$st" != active ] || fail "desktop.service is active with its image gone"
    ev_pass "desktop.service is not active with its image gone: it is $st, and the restart exited $rc"
    ev_save journal "EV-LOG-JOURNAL: journalctl -u desktop.service since the stop: the error as the maintainer sees it" \
        journalctl --no-pager -o short-precise -u desktop.service --since "@$(mt_get since-S10.3.4)" >/dev/null || true
    rc=0
    out=$(ev_save preflight-gone "EV-STATE: desktop-preflight with the image gone" desktop-preflight) || rc=$?
    [ "$rc" = 1 ] || fail "desktop-preflight exited $rc with the image gone, want 1"
    grep -q 'FAIL: image NOT in podman storage: localhost/desktop-container:latest' <<<"$out" || fail "desktop-preflight does not name the missing image"
    ev_pass "desktop-preflight exits 1, naming it: $(grep -m1 'image NOT in podman storage' <<<"$out" | sed 's/^host-preflight: //')"
    mt_state gone "with the image gone"
    mt_state_diff running gone "the image removed"
    ev_end
}
mt_image_load() {
    mt_begin S10.3.4
    ev_save load "EV-PROCEDURE: podman load -i /tmp/images-desktop.tar: the image back in podman's storage, as the preflight's line says (\"podman pull/load it\")" \
        podman load -i /tmp/images-desktop.tar >/dev/null || fail "could not load the image"
    ev_end
}
mt_image_back() {
    local rc=0 out
    mt_begin S10.3.4
    desk_back
    out=$(ev_save preflight-back "EV-STATE: desktop-preflight with the image loaded and the desktop restarted" desktop-preflight) || rc=$?
    [ "$rc" = 0 ] || fail "desktop-preflight still FAILs: $(grep 'FAIL:' <<<"$out" | head -n 3 | tr '\n' ' ')"
    ev_pass "loading the image and restarting was the whole fix: the desktop is back and desktop-preflight reports 0 FAILs"
    mt_state_diff gone back "the image loaded, the desktop restarted"
    ev_end
}

# S10.3.3: the image's facts: "<id> <digest> <sha256 of its toolkit binary>".
mt_image_facts() { # <reference>
    printf '%s %s %s\n' "$(podman image inspect --format '{{.Id}}' "$1")" "$(podman image inspect --format '{{.Digest}}' "$1")" \
        "$(podman run --rm --network=none "$1" sha256sum /usr/libexec/desktop-tools/screenshot | awk '{print $1}')"
}
# A command in the upgrade's client, with the environment CDI gave its main
# process (a podman exec does not inherit it).
MT_UPC_ENV='eval "$(tr "\0" "\n" < /proc/1/environ | grep -E "^(DISPLAY|DESKTOP_TOOLS_BIN|PULSE_SERVER|PIPEWIRE_REMOTE)=" | sed "s/^/export /")"; '
mt_upc() { podman exec "$MT_UPC" sh -c "$MT_UPC_ENV$1"; }
mt_upc_d() { podman exec -d "$MT_UPC" sh -c "$MT_UPC_ENV$1"; }
mt_upgrade_prep() {
    local orig alt
    mt_begin S10.3.3
    ev_save load-alt "EV-PROCEDURE: the second image into podman's storage (podman load): this desktop with another root colour, #2b1b17, and a toolkit binary with another checksum, built for this test" \
        podman load -i /tmp/images-desktop-alt.tar >/dev/null || fail "could not load the second image"
    orig=$(mt_image_facts localhost/desktop-container:latest) alt=$(mt_image_facts "$MT_ALT")
    mt_put img-orig "$orig"
    mt_put img-alt "$alt"
    ev_text images "EV-STATE: the two images: id, digest, and the sha256 of /usr/libexec/desktop-tools/screenshot in each" \
        "first, localhost/desktop-container:latest: $orig
second, $MT_ALT: $alt"
    [ "${orig%% *}" != "${alt%% *}" ] || fail "the two images are the same image"
    [ "${orig##* }" != "${alt##* }" ] || fail "the two images' toolkit binaries have the same checksum"
    ev_pass "two images, different ids and different toolkit checksums"
    podman rm -f "$MT_UPC" >/dev/null 2>&1 || true
    ev_save client "EV-PROCEDURE: the client that runs through every switch (S7.8.1, S7.8.2): sleep infinity in a confined container given the display, audio and tools devices" \
        podman run -d --name "$MT_UPC" --device desktop.local/display=all --device desktop.local/audio=all \
        --device desktop.local/tools=all localhost/desktop-container:latest sleep infinity >/dev/null || fail "the client did not start"
    mt_put upc "$(podman inspect --format '{{.Id}}' "$MT_UPC")"
    ev_end
}
mt_route() { # pin|tag forward|back
    local dg id
    mt_begin S10.3.3
    case "$1:$2" in
        pin:forward)
            dg=$(mt_get img-alt | awk '{print $2}')
            mkdir -p "$(dirname "$MT_PIN")"
            printf '[Container]\nImage=localhost/desktop-container@%s\n' "$dg" > "$MT_PIN"
            ev_copy "$MT_PIN" pin "EV-CONFIG: the documented digest pin (deploy/README.md \"Overriding the image reference\"), naming the second image by digest"
            ev_save daemon-reload "EV-PROCEDURE: systemctl daemon-reload" systemctl daemon-reload >/dev/null || fail "daemon-reload failed" ;;
        pin:back)
            rm -f "$MT_PIN"
            ev_save daemon-reload "EV-PROCEDURE: the pin removed, then systemctl daemon-reload" systemctl daemon-reload >/dev/null || fail "daemon-reload failed" ;;
        tag:forward)
            ev_save tag "EV-PROCEDURE: podman tag $MT_ALT localhost/desktop-container:latest: the unit's default name, moved to the second image" \
                podman tag "$MT_ALT" localhost/desktop-container:latest >/dev/null || fail "podman tag failed" ;;
        tag:back)
            id=$(mt_get img-orig | awk '{print $1}')
            ev_save tag "EV-PROCEDURE: podman tag <the first image's id> localhost/desktop-container:latest: moved back" \
                podman tag "$id" localhost/desktop-container:latest >/dev/null || fail "podman tag failed" ;;
        *) fail "no route $1 $2" ;;
    esac
    ev_save "unit-$1-$2" "EV-CONFIG: systemctl cat desktop.service ($1, $2)" systemctl cat desktop.service >/dev/null || true
    ev_end
}
mt_route_check() { # orig|alt pin|tag
    local id dg sum running pub out rc=0 n inside
    mt_begin S10.3.3
    desk_back
    read -r id dg sum <<<"$(mt_get "img-$1")"
    running=$(ev_save "image-$2-$1" "EV-STATE: podman inspect desktop --format '{{.Image}}' ($2, the $1 image wanted)" \
        podman inspect --format '{{.Image}}' desktop) || true
    [ "$running" = "$id" ] || fail "the desktop runs $running, not the $1 image ($id)"
    pub=$(ev_save "toolkit-$2-$1" "EV-STATE: sha256sum /var/lib/desktop-container/bin/screenshot ($2, $1): the toolkit the desktop published" \
        sha256sum /var/lib/desktop-container/bin/screenshot) || true
    [ "${pub%% *}" = "$sum" ] || fail "the published toolkit is not the $1 image's (${pub%% *}, want $sum)"
    ev_pass "$2 route, the $1 image: the desktop runs it ($id) and published its toolkit (sha256 $sum)"
    out=$(ev_save "preflight-$2-$1" "EV-STATE: desktop-preflight ($2, $1)" desktop-preflight) || rc=$?
    [ "$rc" = 0 ] || fail "desktop-preflight FAILs ($2, $1): $(grep 'FAIL:' <<<"$out" | head -n 3 | tr '\n' ' ')"
    if [ -e "$MT_PIN" ]; then
        grep -q 'PASS: quadlet drop-ins present .* (podman merges them)' <<<"$out" || fail "desktop-preflight does not report the drop-in"
        ev_pass "desktop-preflight: 0 FAILs, and its drop-in line: $(grep -m1 'drop-ins present' <<<"$out" | sed 's/^host-preflight: //')"
    else
        ev_pass "desktop-preflight: 0 FAILs"
    fi
    # The client: the same container, never restarted, and new apps of its
    # work against the new desktop (S7.8.1); the toolkit it sees is the one
    # just published, and it runs (S7.8.2).
    [ "$(podman inspect --format '{{.Id}} {{.RestartCount}}' "$MT_UPC")" = "$(mt_get upc) 0" ] \
        || fail "the client is not the same container, or it restarted: $(podman inspect --format '{{.Id}} {{.RestartCount}}' "$MT_UPC")"
    n=$(( $(mt_get upc-n 2>/dev/null || echo 0) + 1 ))
    mt_put upc-n "$n"
    mt_upc_d "exec xterm -name upclient$n -T upclient$n -xrm 'XTerm*allowTitleOps: false' -geometry 30x3+720+300" || true
    wait_for 20 1 "the client's new xterm, upclient$n, on the screen" win_up "upclient$n"
    inside=$(mt_upc 'sha256sum "$DESKTOP_TOOLS_BIN"/screenshot' 2>/dev/null | awk '{print $1}')
    [ "$inside" = "$sum" ] || fail "the client sees a toolkit of sha256 $inside, not the $1 image's"
    rc=0
    mt_upc '"$DESKTOP_TOOLS_BIN"/screenshot --to-stdout' > "$MT/upc-shot.png" 2>"$MT/upc-shot.err" || rc=$?
    [ "$rc" = 0 ] && [ -s "$MT/upc-shot.png" ] || fail "the client's screenshot failed (exit $rc): $(head -c 300 "$MT/upc-shot.err")"
    ev_copy "$MT/upc-shot.png" "client-shot-$2-$1" "EV-SHOT: the client's own screenshot through the republished toolkit ($2, $1)"
    ev_save "client-$2-$1" "EV-PIDS: the client container ($2, $1): the same id, restart count 0" \
        podman inspect --format '{{.Id}} pid={{.State.Pid}} restarts={{.RestartCount}} started={{.State.StartedAt}}' "$MT_UPC" >/dev/null || true
    ev_pass "the client is the same container, restart count 0; its new xterm upclient$n is on the screen, and the toolkit it sees is the one published, sha256 $sum, which runs"
    ev_end
}
mt_upgrade_done() {
    mt_begin S10.3.3
    podman rm -f "$MT_UPC" >/dev/null 2>&1 || true
    ev_note "the client removed; the desktop runs the first image, with no pin"
    ev_end
}
mt_upc_tone() { # <hz>: a new tone from the upgrade's client, printed for the VM host
    local rc=0
    gen_tone "$1" "/tmp/upc-$1.wav" 3
    podman cp "/tmp/upc-$1.wav" "$MT_UPC:/tmp/upc-$1.wav"
    echo "== paplay of a $1 Hz tone from the client, through the restarted desktop's pulse server"
    mt_upc "paplay /tmp/upc-$1.wav" || rc=$?
    echo "paplay exited $rc"
}

# --- S10.3.5 and S10.3.6: Host Terminal switched off, and on again from its screen ---
# The menu entry itself is the operator's half (operator-e2e.py --maint); these
# steps are the maintainer's commands and what the host says about them.
MT_QUADLET=/etc/containers/systemd/desktop.container
MT_HSKEY=/etc/desktop-container/host-shell-key
MT_HSAK=/etc/ssh/authorized_keys.d/desktop-shell

# The container's own ssh to the host, as the menu entry's wrapper runs it,
# with BatchMode so that a refusal ends it rather than prompting.
mt_container_ssh() { # <moment> <when>
    ev_save "container-ssh-$1" "EV-PROCEDURE: podman exec -u desktop desktop ssh -o BatchMode=yes host whoami ($2): its output and exit status" \
        podman exec -u desktop desktop ssh -o BatchMode=yes -o ConnectTimeout=10 host whoami
}
mt_material() { # <moment> <when>
    ev_save "material-$1" "EV-STATE: ls -l /etc/desktop-container /etc/ssh/authorized_keys.d ($2)" \
        ls -l /etc/desktop-container /etc/ssh/authorized_keys.d >/dev/null || true
    mt_put "$EV_STORY-material-$1" "$EV_LAST"
}

mt_hostterm_before() {
    local out rc=0
    mt_begin S10.3.5
    out=$(mt_container_ssh on "before the switch") || rc=$?
    [ "$rc" = 0 ] && [ "$(tail -n 1 <<<"$out")" = desktop-shell ] \
        || fail "before the switch the container's ssh host whoami did not answer desktop-shell (exit $rc): $out"
    ev_pass "before the switch, the container's \`ssh host whoami\` answers desktop-shell"
    install -m 0600 "$MT_HSKEY" "$MT/kept-host-shell-key" || fail "could not keep a copy of the key in use"
    ev_save kept-key "EV-STATE: the fingerprint of the key in use now; a copy is kept, to try after the switch" \
        ssh-keygen -lf "$MT/kept-host-shell-key" >/dev/null || true
    mt_material before "before the switch"
    ev_end
}

# The off-switch as deploy/README.md "Host Terminal" gives it (comment out
# the two lines), then daemon-reload and a reboot, as S10.3.5 runs it. The
# step ends in the reboot; the VM host watches the screen.
mt_hostterm_switch() {
    local before
    mt_begin S10.3.5
    ev_text switch-doc "EV-PROCEDURE: the off-switch as deploy/README.md \"Host Terminal\" gives it, quoted; it is a sentence, not a command block, so the harness's sed stands in for the editor" \
        "$(sed -n '/^- \*\*Always on\.\*\*/,/^$/p' deploy/README.md)"
    grep -q 'comment out the two' "$EV_DIR/$EV_LAST" || fail "deploy/README.md no longer gives the off-switch as commenting out two lines"
    ev_copy "$MT_QUADLET" quadlet-before "EV-CONFIG: the quadlet before the switch"
    before=$EV_LAST
    ev_save switch "EV-PROCEDURE: the two lines commented out (sed -i -E 's/^(Wants|After)=desktop-host-shell\\.service\$/#&/' $MT_QUADLET)" \
        sed -i -E 's/^(Wants|After)=desktop-host-shell\.service$/#&/' "$MT_QUADLET" >/dev/null || fail "could not edit the quadlet"
    ev_copy "$MT_QUADLET" quadlet-after "EV-CONFIG: the quadlet after the switch"
    ev_diff quadlet "EV-DIFF: the quadlet before (-) and after (+) the switch: the two lines commented out, nothing else" "$before" "$EV_LAST"
    [ "$(grep -cE '^#(Wants|After)=desktop-host-shell\.service$' "$MT_QUADLET")" = 2 ] \
        && ! grep -qE '^(Wants|After)=.*desktop-host-shell' "$MT_QUADLET" \
        || fail "the quadlet's two desktop-host-shell lines are not both commented out"
    ev_pass "the quadlet's two desktop-host-shell lines are commented out, and no active line names the unit"
    ev_save daemon-reload "EV-PROCEDURE: systemctl daemon-reload" systemctl daemon-reload >/dev/null || fail "daemon-reload failed"
    ev_save unit-after "EV-CONFIG: systemctl cat desktop.service after the reload: the unit quadlet generated" \
        systemctl cat desktop.service >/dev/null || true
    # The generated file, not systemctl show: desktop-host-shell.service is
    # still loaded this boot, and its own Before=desktop.service shows up in
    # desktop.service's After= list until the reboot.
    ! systemctl cat desktop.service | grep -qE '^(Wants|After)=.*desktop-host-shell' \
        || fail "the unit quadlet generated still names desktop-host-shell.service in Wants= or After="
    ev_pass "the unit quadlet generated no longer names desktop-host-shell.service in Wants= or After="
    mt_put boot-before "$(cat /proc/sys/kernel/random/boot_id)"
    ev_note "the reboot follows (S10.3.5: the switch, daemon-reload, reboot); the VM host watches the screen"
    ev_end
    sync
    systemctl reboot
}

# After the reboot: what still lets anyone in as desktop-shell.
mt_hostterm_after() {
    local b0 b1 out rc pf f
    mt_begin S10.3.5
    b0=$(mt_get boot-before) b1=$(cat /proc/sys/kernel/random/boot_id)
    [ -n "$b0" ] && [ "$b1" != "$b0" ] || fail "this is not a new boot: boot id $b1, before the reboot ${b0:-unknown}"
    ev_pass "a new boot: boot id $b0 before the switch's reboot, $b1 now"
    ev_save hostshell-unit "EV-STATE: systemctl status desktop-host-shell.service, this boot" \
        systemctl --no-pager status desktop-host-shell.service >/dev/null || true
    if [ "$(systemctl show -p ActiveEnterTimestampMonotonic --value desktop-host-shell.service)" = 0 ]; then
        ev_pass "desktop-host-shell.service did not run this boot: nothing pulls it in"
    else
        ev_fail "desktop-host-shell.service ran this boot ($(systemctl show -p ActiveState --value desktop-host-shell.service))"
    fi
    rc=0
    out=$(ev_save kept-key-login "EV-PROCEDURE: ssh -i <the key kept from before the switch> desktop-shell@127.0.0.1 whoami, on the host: its output and exit status" \
        ssh -i "$MT/kept-host-shell-key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 desktop-shell@127.0.0.1 whoami) || rc=$?
    if [ "$rc" != 0 ]; then
        ev_pass "the key kept from before the switch is refused (ssh exit $rc)"
    else
        ev_fail "the key kept from before the switch still logs in, as $(tail -n 1 <<<"$out"), after the switch and a reboot"
    fi
    rc=0
    out=$(mt_container_ssh off "after the switch and the reboot") || rc=$?
    if [ "$rc" != 0 ]; then
        ev_pass "the container's ssh host is refused (exit $rc)"
    else
        ev_fail "the container's ssh host still logs in, as $(tail -n 1 <<<"$out"), after the switch and a reboot"
    fi
    for f in "$MT_HSKEY" "$MT_HSAK"; do
        if [ -e "$f" ]; then ev_fail "$f still exists after the switch and a reboot"; else ev_pass "$f does not exist"; fi
    done
    pf=$(ev_save preflight-lines "EV-LOG-DESKTOP: podman logs desktop | grep -E 'preflight:|host-shell-setup:', this boot" \
        sh -c 'podman logs desktop 2>&1 | grep -E "preflight:|host-shell-setup:"') || true
    if grep -q 'WARN: no host shell material' <<<"$pf"; then
        ev_pass "the container's preflight WARNs: $(grep -m1 'no host shell material' <<<"$pf" | sed 's/.*preflight: //')"
    else
        ev_fail "the container's preflight does not WARN 'no host shell material'; it says: $(grep -m1 'host shell' <<<"$pf" | sed 's/.*preflight: //')"
    fi
    mt_material off "after the switch and the reboot"
    ev_diff material "EV-DIFF: the host-shell material before (-) the switch and after (+) it and the reboot" \
        "$(mt_get S10.3.5-material-before)" "$(mt_get S10.3.5-material-off)"
    ev_save sshd-journal "EV-LOG-JOURNAL: journalctl -b -u sshd, this boot: every login tried since" \
        journalctl -b --no-pager -o short-precise -u sshd >/dev/null || true
    ev_end
}

# S10.3.6 starts from S10.3.5's intended end state, which the documented
# switch does not reach (S10.3.5's evidence): the harness removes the
# material, a step no document gives, and the VM host restarts the desktop.
mt_hostterm_strip() {
    mt_begin S10.3.6
    mt_material start "what S10.3.5's switch and reboot left"
    ev_save strip "EV-PROCEDURE: harness-only, not a documented step: S10.3.5's intended end state, rm -f $MT_HSKEY $MT_HSKEY.pub $MT_HSAK" \
        rm -f "$MT_HSKEY" "$MT_HSKEY.pub" "$MT_HSAK" >/dev/null || fail "could not remove the host-shell material"
    mt_material stripped "with the material removed"
    ev_end
}
mt_hostterm_start_state() {
    local pf
    mt_begin S10.3.6
    desk_back
    pf=$(ev_save preflight-lines "EV-LOG-DESKTOP: podman logs desktop | grep -E 'preflight:|host-shell-setup:', the desktop restarted without the material" \
        sh -c 'podman logs desktop 2>&1 | grep -E "preflight:|host-shell-setup:"') || true
    grep -q 'WARN: no host shell material' <<<"$pf" || fail "the start state is not S10.3.5's intended one: the container's preflight does not WARN 'no host shell material'"
    ev_pass "the start state: the desktop restarted without host-shell material, and its preflight WARNs: $(grep -m1 'no host shell material' <<<"$pf" | sed 's/.*preflight: //')"
    ev_save dotssh-before "EV-STATE: ls -la /home/desktop/.ssh in the container, before the maintainer's command" \
        podman exec desktop ls -la /home/desktop/.ssh >/dev/null || true
    mt_put S10.3.6-dotssh-before "$EV_LAST"
    ev_end
}
# The command the failure screen gives, as the operator's half read it off
# the screen (base64: a step's arguments are single words), run verbatim.
mt_hostterm_enable() { # <command, base64>
    local cmd rc=0
    mt_begin S10.3.6
    cmd=$(base64 -d <<<"$1") || fail "the command did not decode"
    ev_text screen-command "EV-PROCEDURE: the command the failure screen gives, as the operator's half read it off the screen" "$cmd"
    # Read off a screen, so run only if it has the shape the wrapper prints.
    [[ "$cmd" =~ ^systemctl\ [a-z-]+\ [A-Za-z0-9@._-]+$ ]] || fail "the screen's command is not a systemctl command: $cmd"
    mt_put since-enable "$(date +%s)"
    ev_save enable "EV-PROCEDURE: \`$cmd\`, run verbatim on the host as root: its output and exit status" \
        bash -c "$cmd" >/dev/null || rc=$?
    if [ "$rc" = 0 ]; then ev_pass "\`$cmd\` exited 0"; else ev_fail "\`$cmd\` exited $rc"; fi
    ev_save hostshell-unit "EV-STATE: systemctl status desktop-host-shell.service after it" \
        systemctl --no-pager status desktop-host-shell.service >/dev/null || true
    mt_material enabled "after the command"
    ev_save dotssh-after "EV-STATE: ls -la /home/desktop/.ssh in the container, after the command" \
        podman exec desktop ls -la /home/desktop/.ssh >/dev/null || true
    ev_diff dotssh "EV-DIFF: the container's ~/.ssh before (-) and after (+) the command" "$(mt_get S10.3.6-dotssh-before)" "$EV_LAST"
    ev_end
}
mt_hostterm_journal() {
    mt_begin S10.3.6
    ev_save sshd-journal "EV-LOG-JOURNAL: journalctl -u sshd since the maintainer's command: the second click's login" \
        journalctl --no-pager -o short-precise -u sshd --since "@$(mt_get since-enable)" >/dev/null || true
    ev_end
}

# --- S10.3.7: the look-and-feel loops README.md gives -------------------------------
# The menu, the xterm and the screen are the operator's half and the VM
# host's (operator-e2e.py --maint, maint-e2e.sh); these steps are the edits
# and the commands. Editors are interactive, so sed makes each edit.
MT_LF_LABEL='Refresh the screen now'
mt_lf_mwmrc() {
    local before
    mt_begin S10.3.7
    ev_save mwmrc-before "EV-CONFIG: /home/desktop/.mwmrc in the running container, before the edit" \
        podman exec desktop cat /home/desktop/.mwmrc >/dev/null || fail "there is no ~/.mwmrc in the container"
    before=$EV_LAST
    ev_save mwmrc-edit "EV-PROCEDURE: README.md \"Look and feel\": edit /home/desktop/.mwmrc inside the running container; sed, as the desktop user, makes the root menu's \"Refresh\" label \"$MT_LF_LABEL\"" \
        podman exec -u desktop desktop sed -i "s/^\\( *\\)\"Refresh\"\\( *f\\.refresh\\)/\\1\"$MT_LF_LABEL\"\\2/" /home/desktop/.mwmrc >/dev/null \
        || fail "the edit failed"
    ev_save mwmrc-after "EV-CONFIG: ~/.mwmrc after the edit" podman exec desktop cat /home/desktop/.mwmrc >/dev/null || true
    ev_diff mwmrc "EV-DIFF: ~/.mwmrc before (-) and after (+) the edit: one label" "$before" "$EV_LAST"
    grep -q "\"$MT_LF_LABEL\" *f\\.refresh" "$EV_DIR/$EV_LAST" || fail "the label was not edited"
    ev_pass "the root menu in /home/desktop/.mwmrc now labels f.refresh \"$MT_LF_LABEL\""
    ev_end
}
mt_lf_xdefaults() { # <XTerm*background> <Mwm*menu*background>, hex without '#'
    local before rc x0 x1 x2 term="#$1" menu="#$2"
    mt_begin S10.3.7
    ev_save xdefaults-before "EV-CONFIG: /home/desktop/.Xdefaults in the running container, before the edit" \
        podman exec desktop cat /home/desktop/.Xdefaults >/dev/null || fail "there is no ~/.Xdefaults in the container"
    before=$EV_LAST
    ev_save xdefaults-edit "EV-PROCEDURE: an ~/.Xdefaults change (README.md \"Look and feel\"); sed, as the desktop user: XTerm*background $term, Mwm*menu*background $menu" \
        podman exec -u desktop desktop sed -i -e "s/^\\(XTerm\\*background: *\\)#[0-9a-fA-F]*/\\1$term/" \
        -e "s/^\\(Mwm\\*menu\\*background: *\\)#[0-9a-fA-F]*/\\1$menu/" /home/desktop/.Xdefaults >/dev/null || fail "the edit failed"
    ev_save xdefaults-after "EV-CONFIG: ~/.Xdefaults after the edit" podman exec desktop cat /home/desktop/.Xdefaults >/dev/null || true
    ev_diff xdefaults "EV-DIFF: ~/.Xdefaults before (-) and after (+) the edit: two colours" "$before" "$EV_LAST"
    grep -q "^XTerm\\*background: *$term" "$EV_DIR/$EV_LAST" && grep -q "^Mwm\\*menu\\*background: *$menu" "$EV_DIR/$EV_LAST" \
        || fail "the two colours were not both edited"
    x0=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    rc=0
    ev_save session-restart "EV-PROCEDURE: README.md \"Look and feel\": \"an ~/.Xdefaults change needs a new X session (systemctl restart desktop-session.service in the container)\", run as written, in the container: its output and exit status" \
        podman exec desktop systemctl restart desktop-session.service >/dev/null || rc=$?
    if [ "$rc" = 0 ]; then
        ev_pass "the README's \`systemctl restart desktop-session.service\` in the container exited 0"
    else
        ev_fail "the README's \`systemctl restart desktop-session.service\` in the container exited $rc: $(mt_saved "$EV_LAST" | head -n 2 | tr '\n' ' ')"
    fi
    sleep 3
    x1=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    rc=0
    ev_save session-restart-host "EV-PROCEDURE: the command's other reading, on the host: systemctl restart desktop-session.service, the host's login-session unit of that name: its output and exit status" \
        systemctl restart desktop-session.service >/dev/null || rc=$?
    ev_note "on the host, systemctl restart desktop-session.service exited $rc"
    sleep 5
    x2=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    ev_text xorg-pids "EV-PIDS: the session's Xorg: before the README's command, after it in the container, after the host unit's restart" \
        "before: ${x0:-none}
after the command in the container: ${x1:-none}
after the host's unit restart: ${x2:-none}"
    if [ -n "$x0" ] && { [ "$x1" != "$x0" ] || [ "$x2" != "$x0" ]; }; then
        ev_pass "a new X session started (Xorg $x0 -> $x1 -> $x2)"
    else
        ev_fail "neither reading of the README's command started a new X session: the session's Xorg is pid ${x0:-none} throughout"
    fi
    ev_save session-unit "EV-STATE: systemctl status desktop-session.service on the host, after its restart" \
        systemctl --no-pager status desktop-session.service >/dev/null || true
    ev_end
}
# The image the restarted desktop runs, against the one the README's build
# made (its id, from the maintainer's own storage, passed in by the VM host).
mt_lf_image() { # <the built image's id>
    local running latest
    mt_begin S10.3.7
    running=$(ev_save running-image "EV-STATE: podman inspect desktop --format '{{.Image}}': the image the restarted desktop runs" \
        podman inspect --format '{{.Image}}' desktop) || true
    latest=$(ev_save root-latest "EV-STATE: root's localhost/desktop-container:latest, the storage desktop.service runs from" \
        podman image inspect --format '{{.Id}}' localhost/desktop-container:latest) || true
    ev_note "the README's build made $1; root's localhost/desktop-container:latest is $latest; the desktop runs $running"
    if [ "$running" = "$1" ]; then
        ev_pass "the restarted desktop runs the image the README's build made"
    else
        ev_fail "the restarted desktop runs $running, not the image the README's build made ($1): the build went to a storage desktop.service does not run from"
    fi
    ev_end
}

# --- F10.5: documented faults, staged on a working host -----------------------------
# Each fault is one README.md "Troubleshooting" entry. Entries are prose, so
# the entry is quoted into the evidence and the commands it gives are its
# inline code spans, each run as written (ci/doc-blocks.py --entry --spans).
# Staging and restoring are the harness's, and say so.
mt_entry() { # <lead>: quote the entry
    local text
    text=$(python3 ci/doc-blocks.py README.md Troubleshooting --entry "$1") \
        || fail "README.md's Troubleshooting has no entry starting '$1': $text"
    ev_text entry "EV-PROCEDURE: README.md \"Troubleshooting\", the entry for this fault, quoted as this run read it" "$text"
}
mt_span() { # <lead> <ERE>: the entry's inline command matching it, as written
    local s
    s=$(python3 ci/doc-blocks.py README.md Troubleshooting --entry "$1" --spans | grep -E -m1 -- "$2") \
        || fail "README.md's '$1' entry no longer gives a command matching /$2/"
    printf '%s\n' "$s"
}
# The first stops F10.5 names, in order.
mt_first_stops() { # <moment>
    ev_save "first-stop-preflight-$1" "EV-PROCEDURE: the first stop, desktop-preflight ($1): its report and exit status" \
        desktop-preflight >/dev/null || true
    mt_put "$EV_STORY-preflight-$1" "$EV_LAST"
    ev_save "first-stop-log-$1" "EV-PROCEDURE: the second, podman logs desktop | grep -E 'preflight:|postmortem:' ($1)" \
        sh -c "podman logs desktop 2>&1 | grep -E 'preflight:|postmortem:'" >/dev/null || true
    mt_put "$EV_STORY-log-$1" "$EV_LAST"
}
# The common set's "after" for a remedy that must not restart anything: the
# same pids as before, said either way (EV-PIDS).
mt_after_kept() { # <story> <moment before> <moment after>
    local since c a b moved=""
    mt_begin "$1"
    since=$(mt_get "since-$1")
    desk_back
    mt_pids "$3" "after the remedy"
    for c in ${S737_COMMS//,/ } container; do
        a=$(awk -v c="$c" '$1 == c {print $2; exit}' "$MT/pids-$1-$2")
        b=$(awk -v c="$c" '$1 == c {print $2; exit}' "$MT/pids-$1-$3")
        [ "$a" = "$b" ] || moved="$moved $c ($a -> $b)"
    done
    if [ -z "$moved" ]; then
        ev_pass "nothing restarted: every desktop process ($S737_COMMS) and the container are the ones from before the fault"
    else
        ev_fail "restarted along the way:$moved"
    fi
    mt_no_getty "$since" "between the fault and now"
    mt_state "$3" "after the remedy"
    mt_state_diff "$2" "$3" "the fault and its remedy"
    mt_logs "$since" "from the fault to its remedy"
    ev_end
}

# S10.5.1: a host process holds DRM master.
MT_DRM_LEAD='Xorg: "cannot become DRM master"'
mt_drm_stage() {
    mt_begin S10.5.1
    mt_entry "$MT_DRM_LEAD"
    ev_save stop "EV-PROCEDURE: harness-only staging: systemctl stop desktop.service" \
        systemctl stop desktop.service >/dev/null || fail "could not stop the desktop"
    ev_save holder "EV-PROCEDURE: harness-only staging: a root process opens /dev/dri/card0 first and keeps it, S5.3.3's sleep, as a transient unit (systemd-run --unit=mt-drm-holder sh -c 'exec sleep 3600 < /dev/dri/card0')" \
        systemd-run --unit=mt-drm-holder --collect sh -c 'exec sleep 3600 < /dev/dri/card0' >/dev/null \
        || fail "could not start the holder"
    sleep 1
    mt_put drm-holder "$(systemctl show -p MainPID --value mt-drm-holder.service)"
    ev_save fuser-staged "EV-PIDS: fuser -v /dev/dri/card0, the holder in place (pid $(mt_get drm-holder))" \
        sh -c 'fuser -v /dev/dri/card0 2>&1; true' >/dev/null || true
    mt_put since-start "$(date +%s)"
    ev_save start "EV-PROCEDURE: harness-only staging: systemctl start desktop.service, the holder in place" \
        systemctl start desktop.service >/dev/null || ev_note "systemctl start desktop.service exited nonzero"
    ev_end
}
mt_drm_diagnose() {
    local holder out pf fu line
    mt_begin S10.5.1
    holder=$(mt_get drm-holder)
    ev_save status-desktop "EV-STATE: systemctl status desktop.service, the holder in place" \
        systemctl --no-pager status desktop.service >/dev/null || true
    mt_first_stops held
    pf=$(mt_saved "$(mt_get S10.5.1-preflight-held)")
    if grep -q 'FAIL: .*\/dev\/dri\/card0' <<<"$pf"; then
        ev_pass "desktop-preflight FAILs on the held card: $(grep -m1 'FAIL: .*/dev/dri/card0' <<<"$pf" | sed 's/^host-preflight: //')"
    else
        ev_fail "desktop-preflight reports no FAIL on the held card; it says: $(grep -m1 -E 'DRM/VT|holder' <<<"$pf" | sed 's/^host-preflight: //')"
    fi
    out=$(mt_saved "$(mt_get S10.5.1-log-held)")
    if grep -q 'postmortem: LIKELY CAUSE: another process holds DRM master' <<<"$out"; then
        ev_pass "the postmortem names the cause: $(grep -m1 'LIKELY CAUSE' <<<"$out" | sed 's/.*postmortem: //')"
    else
        ev_fail "the desktop's log has no postmortem naming another DRM master"
    fi
    out=$(ev_save seat-prep-status "EV-STATE: systemctl status desktop-seat-prep, the holder in place" \
        systemctl --no-pager status desktop-seat-prep.service) || true
    if grep -Eq "ERROR: devices still held.*\\(([0-9 ]* )?$holder( [0-9 ]*)?\\)" <<<"$out"; then
        ev_pass "systemctl status desktop-seat-prep shows its ERROR naming pid $holder"
    else
        ev_fail "systemctl status desktop-seat-prep shows no ERROR naming pid $holder: $(grep -m1 -E 'Active:' <<<"$out" | sed 's/^ *//')"
    fi
    line=$(mt_span "$MT_DRM_LEAD" '^fuser ')
    fu=$(ev_save fuser "EV-PROCEDURE: \`$line\`, as the entry writes it, on the host" sh -c "$line 2>&1; true") || true
    if grep -Eq "(^|[^0-9])$holder([^0-9]|\$)" <<<"$fu"; then
        ev_pass "\`$line\` names the holder, pid $holder: $(grep -m1 -E "(^|[^0-9])$holder([^0-9]|\$)" <<<"$fu" | sed 's/  */ /g')"
    else
        ev_fail "\`$line\` does not name the holder, pid $holder"
    fi
    ev_end
}
mt_drm_remedy() {
    local holder
    mt_begin S10.5.1
    holder=$(mt_get drm-holder)
    mt_put since-remedy "$(date +%s)"
    ev_save kill "EV-PROCEDURE: the holder fuser named, killed: kill $holder" kill "$holder" >/dev/null || fail "could not kill pid $holder"
    ev_end
}
mt_drm_after() {
    local out n
    mt_begin S10.5.1
    out=$(ev_save remedy-log "EV-LOG-DESKTOP: podman logs desktop since the kill: the session's next start" \
        podman logs --since "$(mt_get since-remedy)" desktop) || true
    n=$(grep -c 'session exited' <<<"$out" || true)
    if [ "$n" -le 1 ]; then
        ev_pass "the desktop came back on the first session start after the kill: $n session end logged since (the attempt under way when the holder went)"
    else
        ev_fail "$n session ends were logged after the kill before the desktop came back: more than one session-restart cycle"
    fi
    ev_save status-after "EV-STATE: systemctl status desktop-seat-prep desktop after the kill, no other command run" \
        systemctl --no-pager status desktop-seat-prep.service desktop.service >/dev/null || true
    systemctl reset-failed mt-drm-holder.service 2>/dev/null || true
    ev_end
}

# S10.5.2: the session's input devices attached to another seat.
MT_SEAT_LEAD='No input devices'
mt_input_devs() { # every input device with an event node: QMP's events reach X through whichever QEMU routes them to
    local d
    for d in /sys/class/input/input*; do
        if ls -d "$d"/event* >/dev/null 2>&1; then readlink -f "$d"; fi
    done
}
mt_input_events() { local d e; while read -r d; do e=$(ls -d "$d"/event* | head -n 1); echo "/dev/input/${e##*/}"; done < "$MT/seat-devs"; }
mt_seat_stage() {
    local d n=0
    mt_begin S10.5.2
    mt_entry "$MT_SEAT_LEAD"
    mt_input_devs > "$MT/seat-devs"
    [ -s "$MT/seat-devs" ] || fail "no input devices with event nodes"
    ev_save devices "EV-STATE: the input devices staged: every one with an event node, name and node (QMP's typing and clicking reach X through whichever of them QEMU routes it to)" \
        sh -c 'while read -r d; do printf "%s %s %s\n" "$d" "$(cat "$d/name")" "$(ls -d "$d"/event* | head -n 1)"; done < '"$MT"'/seat-devs' >/dev/null || true
    mt_input_events > "$MT/seat-events"
    ev_save udev-before "EV-STATE: udevadm info -q property of each staged event node, before" \
        sh -c 'for e in $(cat '"$MT"'/seat-events); do echo "== $e"; udevadm info -q property -n "$e"; done' >/dev/null || true
    mt_put S10.5.2-udev-before "$EV_LAST"
    mt_put since-stage "$(date +%s)"
    while read -r d; do
        n=$((n + 1))
        loginctl attach seat1 "$d" || fail "loginctl attach seat1 $d failed"
    done < "$MT/seat-devs"
    udevadm settle || true
    ev_note "harness-only staging: loginctl attach seat1 for each of the $n devices (S3.8.6's staging, applied to every input device)"
    ev_save rules "EV-CONFIG: the rules loginctl attach wrote" sh -c 'cat /etc/udev/rules.d/72-seat-*.rules' >/dev/null || true
    ev_end
}
# Harness-only, after a remedy that did not bring input back: what it should
# have done, so the journey's later stories have a keyboard.
mt_seat_restore() {
    mt_begin S10.5.2
    ev_save restore "EV-PROCEDURE: harness-only restore: rm -f /etc/udev/rules.d/72-seat-*.rules, then udev reloaded and re-triggered" \
        sh -c 'rm -f /etc/udev/rules.d/72-seat-*.rules; udevadm control --reload; udevadm trigger; udevadm settle' >/dev/null || true
    ev_end
}
mt_seat_diagnose() {
    local line e out rc=0 bad=""
    mt_begin S10.5.2
    mt_first_stops seat
    line=$(mt_span "$MT_SEAT_LEAD" '^udevadm info ')
    ev_save check-written "EV-PROCEDURE: \`$line\`, as the entry writes it" sh -c "$line; true" >/dev/null || true
    while read -r e; do
        out=$(ev_save "check-${e##*/}" "EV-PROCEDURE: \`${line/\/dev\/input\/event0/$e}\`: the entry's check against a staged node" \
            sh -c "${line/\/dev\/input\/event0/$e}; true") || true
        grep -qi 'ID_SEAT=seat1' <<<"$out" || bad="$bad $e"
    done < "$MT/seat-events"
    if [ -z "$bad" ]; then
        ev_pass "the entry's check, against each staged node, shows the foreign seat: ID_SEAT=seat1"
    else
        ev_fail "the entry's check does not show ID_SEAT=seat1 for:$bad"
    fi
    line=$(mt_span "$MT_SEAT_LEAD" '^systemctl restart desktop-seat-prep')
    mt_put since-remedy "$(date +%s)"
    ev_save remedy "EV-PROCEDURE: \`$line\`, the entry's remedy, run verbatim" sh -c "$line" >/dev/null || rc=$?
    if [ "$rc" = 0 ]; then ev_pass "\`$line\` exited 0"; else ev_fail "\`$line\` exited $rc"; fi
    udevadm settle || true
    sleep 3
    ev_save udev-after "EV-STATE: udevadm info -q property of each staged event node, after the remedy" \
        sh -c 'for e in $(cat '"$MT"'/seat-events); do echo "== $e"; udevadm info -q property -n "$e"; done' >/dev/null || true
    ev_diff udev "EV-DIFF: udevadm info of the staged nodes, staged (-) and after the remedy (+)" "$(mt_get S10.5.2-udev-before)" "$EV_LAST"
    if grep -q 'ID_SEAT=seat1' "$EV_DIR/$EV_LAST"; then ev_fail "a staged node is still tagged ID_SEAT=seat1"; else ev_pass "no staged node is tagged for seat1 any more"; fi
    ev_save xorg-lines "EV-LOG-XORG: the Xorg log's device removal and addition lines" \
        podman exec desktop grep -E 'config/udev: (Adding|removing) input device|Device removed|Adding input device' "$XORG_LOG" >/dev/null || true
    ev_end
}

# S10.5.3: a client-facing directory relabelled; a confined client's display
# loop fails and recovers.
MT_SEL_LEAD='SELinux denials from a client container'
MT_SELC=mt-selclient
mt_sel_client() {
    local i
    mt_begin S10.5.3
    mt_entry "$MT_SEL_LEAD"
    podman rm -f "$MT_SELC" >/dev/null 2>&1 || true
    ev_save client "EV-PROCEDURE: the client: a confined container (container_t) given the display device, opening the display every 2 s (xdpyinfo) and logging each result; a podman client stands in for a pod (F7.7's common set)" \
        podman run -d --name "$MT_SELC" --device desktop.local/display=all localhost/desktop-container:latest \
        sh -c 'while :; do if xdpyinfo >/dev/null 2>&1; then echo "$(date -u +%H:%M:%S) ok"; else echo "$(date -u +%H:%M:%S) FAIL"; fi; sleep 2; done' >/dev/null \
        || fail "the client did not start"
    for i in $(seq 15); do podman logs "$MT_SELC" 2>/dev/null | grep -q ' ok$' && break; sleep 1; done
    podman logs "$MT_SELC" 2>/dev/null | grep -q ' ok$' || fail "the client's loop never opened the display"
    ev_save client-id "EV-PIDS: the client: id, pid, restart count, started" \
        podman inspect --format '{{.Id}} pid={{.State.Pid}} restarts={{.RestartCount}} started={{.State.StartedAt}} label={{.ProcessLabel}}' "$MT_SELC" >/dev/null || true
    mt_put selc "$(podman inspect --format '{{.Id}}' "$MT_SELC")"
    ev_pass "the client's loop opens the display"
    ev_end
}
mt_sel_labels() { # <moment> <when>
    ev_save "labels-$1" "EV-STATE: ls -Zd /tmp/.X11-unix and ls -Z /tmp/.X11-unix/X0 ($2)" \
        sh -c 'ls -Zd /tmp/.X11-unix; ls -Z /tmp/.X11-unix/X0' >/dev/null || true
}
mt_sel_break() {
    local i
    mt_begin S10.5.3
    mt_sel_labels before "before the relabel"
    mt_put since-break "$(date +%s)"
    ev_save relabel "EV-PROCEDURE: harness-only staging: chcon -R -t tmp_t /tmp/.X11-unix, a host type the policy denies container_t" \
        chcon -R -t tmp_t /tmp/.X11-unix >/dev/null || fail "chcon failed"
    for i in $(seq 15); do podman logs --since "$(mt_get since-break)" "$MT_SELC" 2>/dev/null | grep -q ' FAIL$' && break; sleep 1; done
    mt_sel_labels during "relabelled"
    if podman logs --since "$(mt_get since-break)" "$MT_SELC" 2>/dev/null | grep -q ' FAIL$'; then
        ev_pass "the client's loop fails with the directory relabelled"
    else
        ev_fail "the client's loop kept opening the display with /tmp/.X11-unix relabelled tmp_t"
    fi
    ev_save avc "EV-STATE: ausearch -m avc -ts recent, raw: the denial" sh -c 'ausearch -m avc -ts recent 2>&1; true' >/dev/null || true
    grep -q 'avc: *denied' "$EV_DIR/$EV_LAST" && ev_pass "an AVC denial is logged" || ev_fail "no AVC denial is logged"
    ev_end
}
mt_sel_diagnose() {
    local line out rc i xorg0 xorg1
    mt_begin S10.5.3
    mt_first_stops relabelled
    for line in "$(mt_span "$MT_SEL_LEAD" '^systemctl status desktop-selinux')" \
                "$(mt_span "$MT_SEL_LEAD" '^ls -Zd ')" \
                "$(mt_span "$MT_SEL_LEAD" '^ausearch ')"; do
        rc=0
        out=$(ev_save "check-${line%% *}" "EV-PROCEDURE: \`$line\`, as the entry writes it: its output and exit status" sh -c "$line") || rc=$?
        case "$line" in
            ls\ *) grep -q 'tmp_t.*/tmp/\.X11-unix' <<<"$out" && ev_pass "\`$line\` shows /tmp/.X11-unix's wrong label, tmp_t" \
                       || ev_fail "\`$line\` does not show the wrong label" ;;
            ausearch\ *) if [ "$rc" = 0 ] && grep -qi 'denied\|was caused by' <<<"$out"; then ev_pass "\`$line\` names the denial"; else ev_fail "\`$line\` exited $rc without naming the denial: $(head -n 2 <<<"$out" | tr '\n' ' ')"; fi ;;
        esac
    done
    xorg0=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    line=$(mt_span "$MT_SEL_LEAD" '^systemctl restart desktop-selinux')
    mt_put since-remedy "$(date +%s)"
    rc=0
    ev_save remedy "EV-PROCEDURE: \`$line\`, the entry's remedy, run verbatim" sh -c "$line" >/dev/null || rc=$?
    [ "$rc" = 0 ] && ev_pass "\`$line\` exited 0" || ev_fail "\`$line\` exited $rc"
    for i in $(seq 15); do podman logs --since "$(mt_get since-remedy)" "$MT_SELC" 2>/dev/null | grep -q ' ok$' && break; sleep 1; done
    mt_sel_labels after "after the remedy"
    if podman logs --since "$(mt_get since-remedy)" "$MT_SELC" 2>/dev/null | grep -q ' ok$'; then
        ev_pass "the client's loop opens the display again, the client never restarted"
    else
        ev_fail "the client's loop still fails after \`$line\`"
    fi
    out=$(podman inspect --format '{{.Id}} {{.RestartCount}}' "$MT_SELC" 2>/dev/null || true)
    [ "$out" = "$(mt_get selc) 0" ] && ev_pass "the client is the same container, restart count 0" || ev_fail "the client is not the same container, or it restarted: $out"
    xorg1=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    [ -n "$xorg0" ] && [ "$xorg0" = "$xorg1" ] && ev_pass "the X server is the same, pid $xorg0" || ev_fail "the X server changed: pid ${xorg0:-none} -> ${xorg1:-none}"
    ev_save client-log "EV-LOG-CLIENT: the client's loop, every result with its time: the failure and the recovery" \
        podman logs "$MT_SELC" >/dev/null || true
    podman rm -f "$MT_SELC" >/dev/null 2>&1 || true
    ev_note "the client removed"
    ev_end
}

# S10.5.4: the session user's device group out of step with the host's.
MT_GID_LEAD='Keyboard/mouse/GPU dead'
MT_GID_FRESH=64999
mt_gid_view() { # <moment> <when>
    ev_save "gids-$1" "EV-STATE: getent group video, id desktop and ls -ln /dev/dri /dev/input in the container, and ls -ln /dev/dri on the host ($2)" \
        sh -c 'echo "== container"; podman exec desktop getent group video; podman exec desktop id desktop; podman exec desktop ls -ln /dev/dri /dev/input; echo "== host"; ls -ln /dev/dri' >/dev/null || true
}
mt_gid_stage() { # <round>
    local x
    mt_begin S10.5.4
    [ "$1" = b ] || mt_entry "$MT_GID_LEAD"
    mt_gid_view "aligned-$1" "aligned, before the staging"
    podman exec desktop getent group "$MT_GID_FRESH" >/dev/null && fail "gid $MT_GID_FRESH is in use in the container"
    mt_put since-stage "$(date +%s)"
    ev_save groupmod "EV-PROCEDURE: harness-only staging: groupmod -g $MT_GID_FRESH video in the container, the misalignment align-device-groups.sh exists to prevent" \
        podman exec desktop groupmod -g "$MT_GID_FRESH" video >/dev/null || fail "groupmod failed"
    x=$(podman exec desktop pgrep -u desktop -x Xorg || true)
    ev_save kill-x "EV-PROCEDURE: harness-only staging: Xorg (pid ${x:-none}) killed, as the session user (container root holds no CAP_KILL)" \
        podman exec -u desktop desktop pkill -x Xorg >/dev/null || ev_note "no Xorg to kill"
    mt_gid_view "staged-$1" "staged"
    ev_end
}
mt_gid_diagnose() {
    local out
    mt_begin S10.5.4
    mt_first_stops staged
    out=$(ev_save align-lines "EV-PROCEDURE: the entry's check, as it writes it: \`podman logs desktop\` for \`align-device-groups\` lines" \
        sh -c 'podman logs desktop 2>&1 | grep align-device-groups') || true
    out=$(mt_saved "$(mt_get S10.5.4-log-staged)")
    if grep -q 'postmortem: LIKELY CAUSE: device group permissions' <<<"$out"; then
        ev_pass "the postmortem names the cause: $(grep -m1 'LIKELY CAUSE' <<<"$out" | sed 's/.*postmortem: //')"
    else
        ev_fail "the desktop's log has no postmortem naming device group permissions: $(grep -m1 'LIKELY CAUSE' <<<"$out" | sed 's/.*postmortem: //')"
    fi
    out=$(ev_save named "EV-PROCEDURE: the commands the postmortem names, in the container: id desktop; ls -ln /dev/dri /dev/input" \
        sh -c 'podman exec desktop id desktop; podman exec desktop ls -ln /dev/dri /dev/input') || true
    if grep -q "$MT_GID_FRESH" <<<"$out" && ! grep -Eq "^c[^ ]+ +[0-9]+ +[0-9]+ +$MT_GID_FRESH " <<<"$out"; then
        ev_pass "they show the mismatch: desktop's video group is $MT_GID_FRESH, and no device under /dev/dri or /dev/input has that group"
    else
        ev_fail "they do not show the mismatch"
    fi
    ev_end
}
mt_gid_check() { # <path>: the session after a recovery path
    local u
    mt_begin S10.5.4
    desk_back
    mt_gid_view "recovered-$1" "after path $1"
    u=$(ev_save "xorg-user-$1" "EV-PIDS: ps -o user=,pid=,args= -C Xorg in the container (path $1)" podman exec desktop ps -o user=,pid=,args= -C Xorg) || true
    case "$1" in
        a) [ "$(awk 'NR == 1 {print $1}' <<<"$u")" = desktop ] && ev_pass "path A: the session is back, Xorg rootless (user desktop)" \
               || ev_fail "path A: Xorg runs as $(awk 'NR == 1 {print $1}' <<<"$u")" ;;
        b) [ "$(awk 'NR == 1 {print $1}' <<<"$u")" = root ] && ev_pass "path B: the escape hatch gives a session, Xorg as root" \
               || ev_fail "path B: Xorg runs as '$(awk 'NR == 1 {print $1}' <<<"$u")', not root" ;;
        final)
            [ "$(awk 'NR == 1 {print $1}' <<<"$u")" = desktop ] && ev_pass "after the final restart Xorg is rootless again" \
                || ev_fail "after the final restart Xorg runs as $(awk 'NR == 1 {print $1}' <<<"$u")"
            ev_save xwrapper-final "EV-CONFIG: /etc/X11/Xwrapper.config in the container after the final restart" \
                podman exec desktop cat /etc/X11/Xwrapper.config >/dev/null || true
            if podman exec desktop cat /etc/X11/Xwrapper.config | cmp -s - image/xorg/Xwrapper.config; then
                ev_pass "the shipped Xwrapper.config is back"
            else
                ev_fail "Xwrapper.config is not the shipped one (image/xorg/Xwrapper.config)"
            fi ;;
    esac
    ev_end
}
mt_gid_hatch() {
    local line x
    mt_begin S10.5.4
    line=$(mt_span "$MT_GID_LEAD" '^needs_root_rights')
    ev_save xwrapper-before "EV-CONFIG: /etc/X11/Xwrapper.config in the running container, before the escape hatch" \
        podman exec desktop cat /etc/X11/Xwrapper.config >/dev/null || true
    ev_save hatch "EV-PROCEDURE: the entry's escape hatch, \`$line\` in /etc/X11/Xwrapper.config, applied in the running container (sed: the line replaced, or added)" \
        podman exec desktop sh -c "if grep -q '^needs_root_rights' /etc/X11/Xwrapper.config; then sed -i 's/^needs_root_rights.*/$line/' /etc/X11/Xwrapper.config; else echo '$line' >> /etc/X11/Xwrapper.config; fi" >/dev/null \
        || fail "the escape hatch could not be applied"
    ev_save xwrapper-after "EV-CONFIG: /etc/X11/Xwrapper.config with the escape hatch" podman exec desktop cat /etc/X11/Xwrapper.config >/dev/null || true
    x=$(podman exec desktop pgrep -x Xorg || true)
    ev_save kill-x "EV-PROCEDURE: Xorg (pid ${x:-none, the session is between attempts}) killed, so the next session starts under the escape hatch" \
        podman exec -u desktop desktop pkill -x Xorg >/dev/null || ev_note "no Xorg was running to kill"
    ev_end
}

# --- F10.4: routine operations ---------------------------------------------------

# The common set and the pids, before a step that changes the desktop.
mt_before() { # <story> <moment>
    mt_begin "$1"
    mt_put "since-$1" "$(date +%s)"
    mt_state "$2" "while the desktop runs, before the maintainer's command"
    mt_pids "$2" "while the desktop runs, before the maintainer's command"
    ev_end
}
# After the desktop came back: everything new, the session moved, no getty
# was started on the way, and the common set's second half.
mt_after() { # <story> <moment before> <moment after>
    local since
    mt_begin "$1"
    since=$(mt_get "since-$1")
    desk_back
    mt_pids "$3" "the desktop back"
    mt_pids_moved "$2" "$3"
    mt_no_getty "$since" "between the command and now"
    mt_state "$3" "with the desktop back"
    mt_state_diff "$2" "$3" "the desktop went and came back"
    mt_logs "$since" "from the command until the desktop was back"
    ev_end
}

mt_restart() { # S10.4.1
    local rc=0
    mt_begin S10.4.1
    ev_save restart "EV-PROCEDURE: systemctl restart desktop.service, the maintainer's command several documented procedures end in, and how long it took to return (bash's time)" \
        bash -c 'time systemctl restart desktop.service' >/dev/null || rc=$?
    [ "$rc" = 0 ] || fail "systemctl restart desktop.service exited $rc"
    ev_pass "systemctl restart desktop.service exited 0"
    ev_end
}

# S10.4.2's stop: the seat free and the host quiet within logind's stop
# delay, the preflight's account of it, a client turned away cleanly.
mt_stop() {
    local rc=0 t0 i quiet=0 held out t1
    mt_begin S10.4.2
    t0=$(date +%s)
    mt_put stop-at "$t0"
    ev_save stop "EV-PROCEDURE: systemctl stop desktop.service, the maintainer's stop, and how long it took to return (bash's time)" \
        bash -c 'time systemctl stop desktop.service' >/dev/null || rc=$?
    [ "$rc" = 0 ] || fail "systemctl stop desktop.service exited $rc"
    ev_pass "systemctl stop desktop.service exited 0"
    # logind keeps the session's user manager for its stop delay: up to 30 s.
    for i in $(seq 30); do
        held=$(fuser /dev/dri/card* /dev/tty1 2>/dev/null || true)
        if ! pgrep -u desktop >/dev/null && [ -z "${held//[[:space:]]/}" ] \
            && [ -z "$(systemctl list-units --no-pager --no-legend 'getty@tty*' 'autovt@*')" ]; then
            quiet=$i
            break
        fi
        sleep 1
    done
    ev_save uid-procs-stopped "EV-PIDS: every uid-61000 process on the host after the stop (ps -u 61000): none" \
        sh -c 'ps -u 61000 -o pid,ppid,lstart,comm,args || echo "(none)"' >/dev/null || true
    ev_save fuser "EV-STATE: fuser -v /dev/dri/card* /dev/tty1 after the stop: nobody holds them" \
        sh -c 'fuser -v /dev/dri/card* /dev/tty1 2>&1; true' >/dev/null || true
    ev_note "the host's fuser cannot see a container's open device nodes (podman gives the container nodes of its own; S5.3.3), so an empty fuser alone would not rule out the desktop's Xorg: the check that does is pgrep -u desktop, every process of the desktop's user on the host, the container's included"
    [ "$quiet" != 0 ] || fail "30 s after the stop the host is not quiet: desktop processes [$(pgrep -u desktop | paste -sd' ')], holders [$held], gettys [$(systemctl list-units --no-pager --no-legend 'getty@tty*' 'autovt@*' | paste -sd' ')]"
    ev_pass "within $quiet s of the stop no desktop process is left on the host (pgrep -u desktop), nobody holds /dev/dri/card* or /dev/tty1, and no getty runs on any VT"
    mt_put stop-show "$(systemctl show -p ActiveState -p ActiveEnterTimestampMonotonic -p InactiveEnterTimestampMonotonic -p NRestarts desktop.service)"
    mt_no_getty "$t0" "since the stop"
    rc=0
    out=$(ev_save preflight-stopped "EV-STATE: desktop-preflight with the desktop stopped" desktop-preflight) || rc=$?
    grep -q 'WARN: desktop.service not started' <<<"$out" || fail "desktop-preflight does not say 'desktop.service not started'"
    grep -q 'PASS: no DRM/VT holders' <<<"$out" || fail "desktop-preflight does not say 'no DRM/VT holders'"
    [ "$rc" = 0 ] && grep -q 'done: 0 FAIL' <<<"$out" \
        || fail "desktop-preflight reports FAILs with the desktop stopped: $(grep 'FAIL:' <<<"$out" | head -n 3 | tr '\n' ' ')"
    ev_pass "desktop-preflight describes it: desktop.service not started (WARN), no DRM/VT holders (PASS), 0 FAILs"
    t1=$(date +%s.%N)
    out=$(ev_save client "EV-STATE: a confined client given desktop.local/display=all tries the display while the desktop is stopped: what xdpyinfo says, and its exit status" \
        timeout 120 podman run --rm --device desktop.local/display=all localhost/desktop-container:latest \
        sh -c 'xdpyinfo; echo "xdpyinfo exited $?"') || true
    t1=$(awk -v a="$t1" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
    grep -q 'unable to open display' <<<"$out" && grep -q '^xdpyinfo exited [1-9]' <<<"$out" \
        || fail "a client's connect attempt did not fail cleanly: $(echo $out)"
    ev_pass "a client's connect attempt fails cleanly: xdpyinfo says it is unable to open the display and exits nonzero ($(grep '^xdpyinfo exited' <<<"$out")); the whole podman run took $t1 s"
    mt_state stopped "with the desktop stopped"
    mt_state_diff running stopped "the maintenance stop"
    ev_end
}

# S10.4.2: still stopped 120 s after the stop, with nothing having started it.
mt_held() {
    local t0 left st j
    mt_begin S10.4.2
    t0=$(mt_get stop-at)
    [ -n "$t0" ] || fail "the stop step left no time"
    left=$((t0 + 120 - $(date +%s)))
    [ "$left" -le 0 ] || sleep "$left"
    st=$(systemctl show -p ActiveState --value desktop.service)
    ev_save held "EV-STATE: systemctl status desktop.service 120 s after the stop" systemctl --no-pager status desktop.service >/dev/null || true
    [ "$st" = inactive ] || fail "desktop.service is $st 120 s after the stop"
    ev_save held-journal "EV-LOG-JOURNAL: journalctl -u desktop.service since the stop: the stop, and nothing after it" \
        journalctl --no-pager -o short-precise --since "@$t0" -u desktop.service >/dev/null || true
    j=$(ev_save held-show "EV-STATE: systemctl show of desktop.service's state, activation times and restart count 120 s after the stop; the same as right after the stop means nothing started it in between" \
        systemctl show -p ActiveState -p ActiveEnterTimestampMonotonic -p InactiveEnterTimestampMonotonic -p NRestarts desktop.service) || true
    ev_text stop-show "EV-STATE: the same right after the stop" "$(mt_get stop-show)"
    [ "$j" = "$(mt_get stop-show)" ] || fail "desktop.service changed during the maintenance stop: $(echo $j) now, $(mt_get stop-show | paste -sd' ') right after the stop"
    ev_pass "desktop.service is still inactive 120 s after the stop, and nothing started it: its activation times and restart count are what they were right after the stop"
    ev_save uid-procs-held "EV-PIDS: every uid-61000 process on the host 120 s after the stop (ps -u 61000): none" \
        sh -c 'ps -u 61000 -o pid,ppid,lstart,comm,args || echo "(none)"' >/dev/null || true
    ! pgrep -u desktop >/dev/null || fail "a desktop process runs 120 s into the stop: $(pgrep -u desktop -a | head -n 3)"
    mt_no_getty "$t0" "120 s into the stop"
    ev_end
}

mt_start() { # S10.4.2's start
    local rc=0
    mt_begin S10.4.2
    ev_save start "EV-PROCEDURE: systemctl start desktop.service, the end of the maintenance stop, and how long it took to return (bash's time)" \
        bash -c 'time systemctl start desktop.service' >/dev/null || rc=$?
    [ "$rc" = 0 ] || fail "systemctl start desktop.service exited $rc"
    ev_pass "systemctl start desktop.service exited 0"
    ev_end
}

maint() { # <step> [args]
    case "${1:-}" in
        packages) mt_packages ;;
        image) mt_image ;;
        apply) mt_apply "${2:?took|skipped}" ;;
        firstboot) mt_firstboot ;;
        host-play) mt_host_play "${2:?paplay|aplay}" ;;
        selinux) mt_selinux "${2:?took|skipped}" ;;
        checklist-tools) mt_checklist_tools ;;
        checklist) mt_checklist "${2:?readme|deploy}" ;;
        checklist-play) mt_checklist_play "${2:?pw-play|paplay|aplay}" "${3:?written|met|container}" ;;
        quiet) mt_quiet "${2:?start|state|ended|remove}" "${3:-}" ;;
        svc) mt_svc "${2:?story}" "${3:?restart|start|stop}" ;;
        layout-capture) mt_layout_capture ;;
        layout-pinned) mt_layout_pinned ;;
        layout-case) mt_layout_case "${2:?case}" ;;
        layout-case-check) mt_layout_case_check "${2:?case}" ;;
        image-gone) mt_image_gone ;;
        image-load) mt_image_load ;;
        image-back) mt_image_back ;;
        upgrade-prep) mt_upgrade_prep ;;
        route) mt_route "${2:?pin|tag}" "${3:?forward|back}" ;;
        route-check) mt_route_check "${2:?orig|alt}" "${3:?pin|tag}" ;;
        upgrade-done) mt_upgrade_done ;;
        upc-tone) mt_upc_tone "${2:?hz}" ;;
        audio-diag) mt_audio_diag "${2:?story}" ;;
        hostterm-before) mt_hostterm_before ;;
        hostterm-switch) mt_hostterm_switch ;;
        hostterm-after) mt_hostterm_after ;;
        hostterm-strip) mt_hostterm_strip ;;
        hostterm-start-state) mt_hostterm_start_state ;;
        hostterm-enable) mt_hostterm_enable "${2:?the command, base64}" ;;
        hostterm-journal) mt_hostterm_journal ;;
        lf-mwmrc) mt_lf_mwmrc ;;
        lf-xdefaults) mt_lf_xdefaults "${2:?XTerm background, hex}" "${3:?Mwm menu background, hex}" ;;
        lf-image) mt_lf_image "${2:?the id of the image built}" ;;
        drm-stage) mt_drm_stage ;;
        drm-diagnose) mt_drm_diagnose ;;
        drm-remedy) mt_drm_remedy ;;
        drm-after) mt_drm_after ;;
        seat-stage) mt_seat_stage ;;
        seat-diagnose) mt_seat_diagnose ;;
        seat-restore) mt_seat_restore ;;
        sel-client) mt_sel_client ;;
        sel-break) mt_sel_break ;;
        sel-diagnose) mt_sel_diagnose ;;
        gid-stage) mt_gid_stage "${2:?the round, a or b}" ;;
        gid-diagnose) mt_gid_diagnose ;;
        gid-hatch) mt_gid_hatch ;;
        gid-check) mt_gid_check "${2:?a, b or final}" ;;
        after-kept) mt_after_kept "${2:?story}" "${3:?moment before}" "${4:?moment after}" ;;
        before) mt_before "${2:?story}" "${3:?moment}" ;;
        after) mt_after "${2:?story}" "${3:?moment before}" "${4:?moment after}" ;;
        restart) mt_restart ;;
        stop) mt_stop ;;
        held) mt_held ;;
        start) mt_start ;;
        *) fail "maint: no step named '${1:-}' (see the case above)" ;;
    esac
}
