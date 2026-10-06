#!/bin/bash
# S3.2.2's T1 half: align-device-groups.sh, branch by branch, each in a
# scratch container of the built image (its own /etc/group, its own /dev).
# The script reads only whether a node exists and its group (stat -c %g),
# so a plain file given the wanted group stands in for each device node.
#
# Run from the repository root after the image is built:
#   EV_ROOT=artifacts ci/align-groups-tests.sh
# RUN overrides the container runner (default: sudo podman run).
set -uo pipefail

# shellcheck source=ci/evidence.sh
. ci/evidence.sh
IMG=${IMG:-localhost/desktop-container:latest}
read -r -a RUN <<<"${RUN:-sudo podman run}"
GROUPS_SHOWN="video render input audio squatter g60000"
f=0

# One scratch container: <setup> as root, then the groups, the script with
# <args>, the groups again and id desktop, each under a "== " heading.
in_scratch() { # <setup> <args>
    "${RUN[@]}" --rm --network=none --user 0 "$IMG" bash -c "
set -e
$1
echo '== before'
getent group $GROUPS_SHOWN | sort
echo '== align-device-groups.sh $2'
/usr/local/bin/align-device-groups.sh $2
echo '== after'
getent group $GROUPS_SHOWN | sort
echo '== id desktop'
id desktop
" 2>&1
}
section() { awk -v h="== $2" '$0 == h {on = 1; next} /^== / {on = 0} on' <<<"$1"; }
gid_of() { awk -F: -v g="$2" '$1 == g {print $3}' <<<"$1"; }   # <getent lines> <group>
check() { ev_check "$@" || f=1; }

# A branch: run it, keep the transcript, the groups before and after, and
# their diff; the caller then checks the script's log and the after state.
OUT="" LOG="" BEFORE="" AFTER="" ID=""
branch() { # <moment> <what> <setup> <args>
    ev_text "$1-setup" "EV-STATE: the scratch container's setup, as root, before align-device-groups.sh ${4:-(no arguments)}" "$3"
    OUT=$(in_scratch "$3" "$4") || { ev_text "$1-run" "EV-LOG: the scratch container's transcript (it failed)" "$OUT"; ev_fail "$2: the scratch container failed"; f=1; return 1; }
    ev_text "$1-run" "EV-LOG: the scratch container's transcript: the groups, align-device-groups.sh ${4:-(no arguments)} and its log, the groups again, id desktop" "$OUT"
    BEFORE=$(section "$OUT" before)
    AFTER=$(section "$OUT" after)
    LOG=$(section "$OUT" "align-device-groups.sh $4")
    ID=$(section "$OUT" "id desktop")
    ev_text "$1-before" "EV-STATE: getent group before ($GROUPS_SHOWN; absent ones are not listed)" "$BEFORE"
    local b=$EV_LAST
    ev_text "$1-after" "EV-STATE: getent group after" "$AFTER"
    ev_diff "$1-groups" "EV-DIFF: getent group before against after: $2" "$b" "$EV_LAST"
}

ev_begin S3.2.2 "Group gids are aligned to the host's device nodes" T1

# 1. A node whose gid no group has: the group is renumbered to it.
branch renumber "renumber" 'mkdir -p /dev/dri; : > /dev/dri/card0; chgrp 2001 /dev/dri/card0' video
v0=$(gid_of "$BEFORE" video)
check "renumber: the log says video moved to the node's gid ($(grep -m1 'video: gid' <<<"$LOG" || echo none))" \
    grep -qx "align-device-groups: video: gid $v0 -> 2001 (from /dev/dri/card0)" <<<"$LOG"
check "renumber: video is gid 2001 after (was $v0)" test "$(gid_of "$AFTER" video)" = 2001
check "renumber: and the desktop user is in it: $ID" grep -q '2001(video)' <<<"$ID"

# 2. A node whose gid another group holds, with 60000 also taken: the other
#    group moves to the first free gid from 60000, here 60001.
branch collision "collision" 'groupadd -g 2002 squatter; groupadd -g 60000 g60000; mkdir -p /dev/dri; : > /dev/dri/renderD128; chgrp 2002 /dev/dri/renderD128' render
r0=$(gid_of "$BEFORE" render)
check "collision: the log says squatter moves to 60001, the first free gid from 60000 (60000 being taken)" \
    grep -qx "align-device-groups: gid 2002 is taken by group 'squatter'; moving 'squatter' to 60001" <<<"$LOG"
check "collision: squatter is gid 60001 after, g60000 still 60000" \
    test "$(gid_of "$AFTER" squatter):$(gid_of "$AFTER" g60000)" = 60001:60000
check "collision: render is gid 2002 after (was $r0)" test "$(gid_of "$AFTER" render)" = 2002
check "collision: and the log says so" grep -qx "align-device-groups: render: gid $r0 -> 2002 (from /dev/dri/renderD128)" <<<"$LOG"

# 3. A group the image does not have: created with the node's gid, and the
#    desktop user added to it.
branch missing "missing group" 'groupdel input; mkdir -p /dev/input; : > /dev/input/event0; chgrp 2003 /dev/input/event0' input
check "missing group: input is absent before" test -z "$(gid_of "$BEFORE" input)"
check "missing group: the log says it is created with the node's gid" \
    grep -qx "align-device-groups: input: creating with gid 2003 (from /dev/input/event0)" <<<"$LOG"
check "missing group: input is gid 2003 after, and the desktop user is in it: $ID" \
    sh -c '[ "$1" = 2003 ] && printf "%s\n" "$2" | grep -q "2003(input)"' _ "$(gid_of "$AFTER" input)" "$ID"

# 4. A root-group node (as /dev/nvidia* are): skipped, with a log line.
branch rootgroup "root-group node" 'mkdir -p /dev/dri; : > /dev/dri/card0; chgrp 0 /dev/dri/card0' video
check "root-group node: the log says it is skipped" \
    grep -qx "align-device-groups: video: /dev/dri/card0 has group root, skipping" <<<"$LOG"
check "root-group node: video's gid is unchanged ($(gid_of "$BEFORE" video))" \
    test "$(gid_of "$AFTER" video)" = "$(gid_of "$BEFORE" video)"

# 5. No node at all: skipped, with a log line.
branch absent "absent node" 'rm -rf /dev/snd' audio
check "absent node: the log says there is nothing to align" \
    grep -qx "align-device-groups: audio: no device nodes present, skipping" <<<"$LOG"
check "absent node: audio's gid is unchanged ($(gid_of "$BEFORE" audio))" \
    test "$(gid_of "$AFTER" audio)" = "$(gid_of "$BEFORE" audio)"

# 6. The boot path, no arguments, every node already on the image's own
#    gids: nothing changes, and the final table and id desktop are logged.
branch aligned "already aligned" 'mkdir -p /dev/dri /dev/input /dev/snd
for p in video:/dev/dri/card0 render:/dev/dri/renderD128 input:/dev/input/event0 audio:/dev/snd/controlC0; do
    : > "${p#*:}"; chgrp "$(getent group "${p%%:*}" | cut -d: -f3)" "${p#*:}"
done' ""
check "already aligned: no group changes (getent group is the same before and after)" test "$BEFORE" = "$AFTER"
check "already aligned: the log moves nothing" sh -c '! printf "%s\n" "$1" | grep -qE " -> |creating|moving"' _ "$LOG"
check "already aligned: the final table names all four groups, each with its device's gid" \
    sh -c '[ "$(printf "%s\n" "$1" | grep -cE "^align-device-groups:   (video|render|input|audio): container gid [0-9]+, device /dev/[^ ]+ has gid [0-9]+ mode [0-7]+$")" = 4 ]' _ "$LOG"
check "already aligned: and it ends with id desktop" grep -q '^align-device-groups: desktop user: uid=61000(desktop) ' <<<"$LOG"

# 7. The narrow form: only the named group is touched, and only it is in
#    the final table, though every node is on a gid no group has.
branch narrow "narrow form" 'mkdir -p /dev/dri /dev/input /dev/snd
: > /dev/dri/card0; chgrp 2011 /dev/dri/card0
: > /dev/dri/renderD128; chgrp 2012 /dev/dri/renderD128
: > /dev/input/event0; chgrp 2013 /dev/input/event0
: > /dev/snd/controlC0; chgrp 2014 /dev/snd/controlC0' audio
check "narrow form: audio is renumbered to 2014" test "$(gid_of "$AFTER" audio)" = 2014
for g in video render input; do
    check "narrow form: $g is untouched ($(gid_of "$BEFORE" $g))" test "$(gid_of "$AFTER" $g)" = "$(gid_of "$BEFORE" $g)"
done
check "narrow form: the final table has the audio row alone" \
    sh -c 'printf "%s\n" "$1" | grep -E "^align-device-groups:   [a-z]+:" | grep -vq "^align-device-groups:   audio:" && exit 1; printf "%s\n" "$1" | grep -q "^align-device-groups:   audio: container gid 2014, device /dev/snd/controlC0 has gid 2014"' _ "$LOG"

# 8. A name the script does not know: logged, nothing done.
branch unknown "unknown group" ':' bogus
check "unknown group: the log names it and the known ones" \
    grep -qx "align-device-groups: unknown group 'bogus'; known: video render input audio" <<<"$LOG"
check "unknown group: no group changes" test "$BEFORE" = "$AFTER"

ev_end
# Each failed check again, last, where the end of the job log shows it
# (Requirements.md S9.2.3).
ev_failures
exit "$f"
