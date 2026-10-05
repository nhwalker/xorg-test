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
    # repository key it has not seen. A maintainer answers y; so does this.
    out=$(ev_save dnf-documented "EV-PROCEDURE: the block's command, run unmodified as root in the repository, each of dnf's questions answered y: its transcript and exit status" \
        sh -c "yes | $line") || rc=$?
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
            # xterm of an earlier typing check retires now, not mid-run.
            podman exec desktop pkill -f 'xterm -T inputtest' 2>/dev/null || true
            gen_tone 330 /tmp/mt-client.wav "${2:?seconds}"
            podman rm -f "$MT_CLIENT" >/dev/null 2>&1 || true
            ev_save client "EV-PROCEDURE: the client: a confined container given the display and audio devices, an xterm (mt-client) on the screen and a ${2} s 330 Hz tone through PipeWire's pulse server" \
                podman create --name "$MT_CLIENT" --device desktop.local/display=all --device desktop.local/audio=all \
                localhost/desktop-container:latest \
                sh -c 'xterm -T mt-client -geometry 40x6+700+420 & paplay /tmp/mt-client.wav; echo "paplay exited $?"; wait' >/dev/null \
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
        before) mt_before "${2:?story}" "${3:?moment}" ;;
        after) mt_after "${2:?story}" "${3:?moment before}" "${4:?moment after}" ;;
        restart) mt_restart ;;
        stop) mt_stop ;;
        held) mt_held ;;
        start) mt_start ;;
        *) fail "maint: packages, image, apply, firstboot, host-play, selinux, checklist-tools, checklist, checklist-play, quiet, before, after, restart, stop, held or start" ;;
    esac
}
