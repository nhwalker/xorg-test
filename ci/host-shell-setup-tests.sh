#!/bin/bash
# S5.7.7's T1 half: the container side of the Host Terminal, the image's
# host-shell-setup.sh, with and without its key material, each case in a
# scratch container of the built image (/etc/desktop-container written
# there, as the quadlet's read-only mount would provide it).
#
# Run from the repository root after the image is built:
#   EV_ROOT=artifacts ci/host-shell-setup-tests.sh
# RUN overrides the container runner (default: sudo podman run).
set -uo pipefail

# shellcheck source=ci/evidence.sh
. ci/evidence.sh
IMG=${IMG:-localhost/desktop-container:latest}
read -r -a RUN <<<"${RUN:-sudo podman run}"
f=0
check() { ev_check "$@" || f=1; }

# One scratch container: <setup> as root, then the script, its exit status,
# what it left in the session user's home, and the preflight's host-shell
# row, each under a "== " heading.
in_scratch() { # <setup>
    "${RUN[@]}" --rm --network=none --user 0 "$IMG" bash -c "
$1
echo '== /etc/desktop-container'
ls -l /etc/desktop-container 2>&1 || true
echo '== host-shell-setup.sh'
/usr/local/bin/host-shell-setup.sh; rc=\$?
echo '== exit'
echo \$rc
echo '== ~desktop/.ssh'
if [ -d /home/desktop/.ssh ]; then stat -c '%a %U:%G %n' /home/desktop/.ssh /home/desktop/.ssh/*; else echo '(no /home/desktop/.ssh)'; fi
echo '== config'
cat /home/desktop/.ssh/config 2>/dev/null || echo '(no config)'
echo '== key'
sha256sum /etc/desktop-container/host-shell-key /home/desktop/.ssh/host-shell-key 2>&1
echo '== preflight'
/usr/local/bin/preflight-check.sh 2>&1 | grep -E 'host shell material' || echo '(no host-shell row)'
" 2>&1
}
section() { awk -v h="== $2" '$0 == h {on = 1; next} /^== / {on = 0} on' <<<"$1"; }

OUT=""
scenario() { # <moment> <what> <setup>
    ev_text "$1-setup" "EV-STATE: the scratch container's setup, as root: $2" "$3"
    OUT=$(in_scratch "$3") || true
    ev_text "$1-run" "EV-LOG: the scratch container's transcript: /etc/desktop-container, host-shell-setup.sh's output and exit status, ~desktop/.ssh, its config, sha256sum of the key and its copy, the preflight's host-shell row" "$OUT"
}

ev_begin S5.7.7 "Container side degrades gracefully without key material" T1

# 1. No key at all (the mount absent, as with the feature switched off).
scenario no-key "no /etc/desktop-container" 'rm -rf /etc/desktop-container'
log=$(section "$OUT" host-shell-setup.sh)
check "no key: the hint names the missing key" \
    grep -qx "host-shell-setup: no host shell key at /etc/desktop-container/host-shell-key; the 'Host Terminal' menu entry will not work" <<<"$log"
check "no key: and how to enable it" \
    grep -qx "host-shell-setup: enable it on the host: start desktop-host-shell.service (see deploy/README.md)" <<<"$log"
check "no key: exit 0" test "$(section "$OUT" exit)" = 0
check "no key: no ~/.ssh is made" test "$(section "$OUT" '~desktop/.ssh')" = "(no /home/desktop/.ssh)"
check "no key: the preflight WARNs no host shell material" \
    grep -q '^preflight: WARN: no host shell material at /etc/desktop-container' <<<"$(section "$OUT" preflight)"

# 2. A key and no shell-user file; 3. a key and an empty one.
for c in "missing-user:no shell-user file:rm -f /etc/desktop-container/shell-user" \
         "empty-user:an empty shell-user file:: > /etc/desktop-container/shell-user"; do
    moment=${c%%:*} rest=${c#*:}
    what=${rest%%:*} step=${rest#*:}
    scenario "$moment" "a key and $what" "mkdir -p /etc/desktop-container
printf 'not a real key\\n' > /etc/desktop-container/host-shell-key
$step"
    check "$what: the warning names shell-user" \
        grep -qx "host-shell-setup: warning: /etc/desktop-container/shell-user missing or empty; cannot configure the host shell" <<<"$(section "$OUT" host-shell-setup.sh)"
    check "$what: exit 0" test "$(section "$OUT" exit)" = 0
    check "$what: no ssh config is written" test "$(section "$OUT" config)" = "(no config)"
done

# 4. Both present: the config and a 0400 copy of the key.
scenario both "a key and shell-user 'rocky'" "mkdir -p /etc/desktop-container
printf 'not a real key\\n' > /etc/desktop-container/host-shell-key
chmod 0400 /etc/desktop-container/host-shell-key
echo rocky > /etc/desktop-container/shell-user"
check "both: it says so" \
    grep -qx "host-shell-setup: host shell configured: 'ssh host' connects to 127.0.0.1 as rocky" <<<"$(section "$OUT" host-shell-setup.sh)"
check "both: exit 0" test "$(section "$OUT" exit)" = 0
ssh_dir=$(section "$OUT" '~desktop/.ssh')
check "both: ~/.ssh is 0700 desktop:desktop" grep -qx '700 desktop:desktop /home/desktop/.ssh' <<<"$ssh_dir"
check "both: the key copy is 0400 desktop:desktop" grep -qx '400 desktop:desktop /home/desktop/.ssh/host-shell-key' <<<"$ssh_dir"
check "both: the config is 0600 desktop:desktop" grep -qx '600 desktop:desktop /home/desktop/.ssh/config' <<<"$ssh_dir"
sums=$(section "$OUT" key)
check "both: the copy is byte-identical to the mounted key (sha256 $(awk 'NR == 1 {print substr($1, 1, 12)}' <<<"$sums")...)" \
    test "$(awk '{print $1}' <<<"$sums" | sort -u | grep -c .)" = 1 -a "$(grep -c . <<<"$sums")" = 2
cfg=$(section "$OUT" config)
ev_text config "EV-CONFIG: the ~/.ssh/config host-shell-setup.sh wrote" "$cfg"
for want in 'Host host' 'HostName 127.0.0.1' 'User rocky' 'IdentityFile ~/.ssh/host-shell-key' 'IdentitiesOnly yes'; do
    check "both: the config says $want" grep -qx " *$want" <<<"$cfg"
done
check "both: the preflight PASSes the material, naming the user" \
    grep -q "^preflight: PASS: host shell material mounted (Host Terminal -> ssh as 'rocky')" <<<"$(section "$OUT" preflight)"

ev_end
# Each failed check again, last, where the end of the job log shows it
# (Requirements.md S9.2.3).
ev_failures
exit "$f"
