#!/bin/bash
# Align the container's "desktop" user with a host account at boot.
#
# The image had to pick a uid at build time (useradd -u 1000); the host
# account this desktop stands in for is only known on the host, at deploy
# time. So the numeric identity is converged here instead, from material the
# host exports into /etc/desktop-container (mounted read-only, written by
# desktop-user-sync.service -- see deploy/README.md "Desktop user identity"):
#
#   desktop-user.env    uid/gid/group/gecos/shell of the host account
#   desktop-user.hash   its /etc/shadow password field (root-only, 0400)
#
# NUMBERS, not names: the login name inside the container stays "desktop"
# whatever the host account is called -- every unit, path and helper in this
# image references it -- while the kernel only ever compares numeric uids and
# gids for ownership on the shared mounts (/tmp/.X11-unix, /run/desktop-audio,
# any host volume). Matching numerically is what makes those line up; matching
# the name would only change what has to be typed at an su prompt.
#
# Runs as root from xorg-conf.service, FIRST: align-device-groups (usermod
# -aG), host-shell-setup (chown into ~desktop) and preflight all report on or
# write to the final identity. Degrades gracefully -- with no host material
# the built-in uid 1000 is kept and everything behaves as it did before.
set -u

SRC=/etc/desktop-container
ENVF="$SRC/desktop-user.env"
HASHF="$SRC/desktop-user.hash"
DHOME=/home/desktop

log() { echo "align-desktop-user: $*"; }

final() {
    log "final: $(id desktop 2>/dev/null || echo '<no desktop user>')"
    exit 0
}

if [ ! -f "$ENVF" ]; then
    log "no $ENVF; keeping the image's built-in identity"
    log "to mirror a host account: name it in /etc/desktop-container/desktop-user on the host (deploy/README.md)"
    final
fi

# Read, don't source: the file is root-written on the host, but a config file
# that can silently execute is a bad shape for something a container boots on.
getval() { sed -n "s/^$1=//p" "$ENVF" | tail -n1; }
host_user=$(getval DESKTOP_HOST_USER)
want_uid=$(getval DESKTOP_UID)
want_gid=$(getval DESKTOP_GID)
want_group=$(getval DESKTOP_GROUP)
want_gecos=$(getval DESKTOP_GECOS)
want_shell=$(getval DESKTOP_SHELL)

case "$want_uid" in ''|*[!0-9]*) log "REFUSING: DESKTOP_UID='$want_uid' is not a number"; final ;; esac
case "$want_gid" in ''|*[!0-9]*) log "REFUSING: DESKTOP_GID='$want_gid' is not a number"; final ;; esac
if [ "$want_uid" = 0 ] || [ "$want_gid" = 0 ]; then
    log "REFUSING: host account '$host_user' is uid $want_uid/gid $want_gid; the session user must not be root"
    final
fi

log "mirroring host account '${host_user:-?}': uid $want_uid, gid $want_gid (${want_group:-?})"

cur_uid=$(id -u desktop)
cur_gid=$(id -g desktop)

# --- primary group ------------------------------------------------------------
# Renumber the image's own "desktop" group when the gid is free. When it is
# not -- host users whose primary group is a stock one (gid 100 "users" is
# ordinary on Debian/SUSE hosts) -- point the user at the group that already
# holds the number instead of renumbering an image group out from under
# whatever uses it. Either way the NUMBER on the files ends up right, which
# is the whole contract; the name it resolves to inside the container is
# cosmetic.
if [ "$want_gid" != "$cur_gid" ]; then
    other=$(getent group "$want_gid" | cut -d: -f1)
    if [ -z "$other" ]; then
        if groupmod -g "$want_gid" desktop; then
            log "group desktop: gid $cur_gid -> $want_gid"
        else
            log "groupmod to gid $want_gid FAILED; identity not aligned"
            final
        fi
    else
        log "gid $want_gid is group '$other' in this image; using it as the primary group rather than renumbering '$other'"
    fi
fi

# --- uid ----------------------------------------------------------------------
# A uid collision is different: two accounts sharing a uid is genuinely
# broken, and the image only has system accounts below 1000, so this means
# the host account really does clash. Say so and keep the built-in identity.
if [ "$want_uid" != "$cur_uid" ]; then
    other=$(getent passwd "$want_uid" | cut -d: -f1)
    if [ -n "$other" ] && [ "$other" != desktop ]; then
        log "REFUSING uid $want_uid: already held by account '$other' in this image"
        final
    fi
    # usermod rechowns files it finds under the home directory; the explicit
    # pass below covers the group and anything it skipped.
    if usermod -u "$want_uid" desktop; then
        log "user desktop: uid $cur_uid -> $want_uid"
    else
        log "usermod to uid $want_uid FAILED (session processes still running?); identity not aligned"
        final
    fi
fi

prev_gid=$(id -g desktop)
if [ "$prev_gid" != "$want_gid" ]; then
    if usermod -g "$want_gid" desktop; then
        log "user desktop: primary gid $prev_gid -> $want_gid"
    else
        log "usermod to gid $want_gid FAILED; ownership on the shared mounts will not match the host"
    fi
fi

# Idempotent and cheap (a skel-sized home); also fixes the gid, which
# groupmod does not touch on existing files.
chown -R "$want_uid:$want_gid" "$DHOME" 2>/dev/null \
    || log "WARNING: could not chown $DHOME to $want_uid:$want_gid"

# --- shell / gecos ------------------------------------------------------------
if [ -n "$want_shell" ] && [ "$want_shell" != "$(getent passwd desktop | cut -d: -f7)" ]; then
    if [ -x "$want_shell" ]; then
        usermod -s "$want_shell" desktop && log "login shell: $want_shell"
    else
        log "host login shell '$want_shell' is not installed in this image; keeping $(getent passwd desktop | cut -d: -f7)"
    fi
fi
# Conditional: an unconditional usermod prints "no changes" to the journal
# on every boot once the identity has settled.
if [ -n "$want_gecos" ] && [ "$want_gecos" != "$(getent passwd desktop | cut -d: -f5)" ]; then
    usermod -c "$want_gecos" desktop
fi

# --- password -----------------------------------------------------------------
# The hash is copied verbatim, so `su desktop` (and anything else running the
# container's PAM stack) takes the same password as the host account. The
# session itself never authenticates: desktop-session.service's PAMName=login
# runs account/session modules only.
if [ ! -f "$HASHF" ]; then
    log "no $HASHF; container password field unchanged"
else
    hash=$(head -n1 "$HASHF")
    case "$hash" in
        ''|'!'|'!!'|'*'|'x')
            log "host account '$host_user' has no usable password ('${hash}'); leaving the container account without one"
            ;;
        '!'*)
            printf 'desktop:%s\n' "$hash" | chpasswd -e \
                && log "password hash adopted, but it is LOCKED on the host: su/sudo as desktop will refuse it"
            ;;
        *)
            # Log the crypt scheme id ($6$ sha512, $y$ yescrypt, ...): if the
            # host hashes with something this image's libcrypt cannot verify,
            # the password is simply never accepted, with nothing else to see.
            if printf 'desktop:%s\n' "$hash" | chpasswd -e; then
                log "password hash adopted from host account '$host_user' (crypt scheme '\$$(echo "$hash" | cut -d'$' -f2)\$')"
            else
                log "chpasswd FAILED: the container account keeps its own password field"
            fi
            ;;
    esac
fi

final
