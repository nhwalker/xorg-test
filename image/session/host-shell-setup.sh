#!/bin/bash
# Boot-time setup for the "Host Terminal" menu entry: installs the ssh key
# and client config for the desktop user from the host-provided material in
# /etc/desktop-container (mounted read-only; created by install.sh when run
# with a --shell-user, see README "Host terminal from the desktop").
#
# Runs as root from xorg-conf.service. Degrades gracefully: without the
# mount the menu entry fails visibly and everything else is unaffected.
set -u

SRC=/etc/desktop-container
DHOME=/home/desktop

log() { echo "host-shell-setup: $*"; }

if [ ! -f "$SRC/host-shell-key" ]; then
    log "no host shell key at $SRC/host-shell-key; the 'Host Terminal' menu entry will not work"
    log "enable it on the host: ./install.sh [--host-prep-only] --shell-user <user>"
    exit 0
fi

user=$(cat "$SRC/shell-user" 2>/dev/null)
if [ -z "$user" ]; then
    log "warning: $SRC/shell-user missing or empty; cannot configure the host shell"
    exit 0
fi

install -d -m 0700 -o desktop -g desktop "$DHOME/.ssh"
install -m 0400 -o desktop -g desktop "$SRC/host-shell-key" "$DHOME/.ssh/host-shell-key"
cat > "$DHOME/.ssh/config" <<EOF
# Generated at boot by host-shell-setup.sh - do not edit (edits are lost).
Host host
    HostName 127.0.0.1
    User $user
    IdentityFile ~/.ssh/host-shell-key
    IdentitiesOnly yes
    # Loopback to the host we run on: host-key churn on reinstalls is
    # expected and TOFU adds nothing here.
    NoHostAuthenticationForLocalhost yes
EOF
chown desktop:desktop "$DHOME/.ssh/config"
chmod 0600 "$DHOME/.ssh/config"
log "host shell configured: 'ssh host' connects to 127.0.0.1 as $user"
