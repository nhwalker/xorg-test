# Desktop APPLICATION layer: configuration, session logic, and services on
# top of the prebuilt base image (Containerfile.base holds all package /
# network dependencies). This build is fully offline:
#
#   podman build --network=none -t localhost/desktop-container:latest -f Containerfile .
#
# Override the base with --build-arg BASE_IMAGE=<ref> (e.g. a registry copy).
# Requires localhost/screenshot:latest to exist (override with
# --build-arg TOOLS_IMAGE=<ref>): its binaries are staged into this image and
# published to clients at boot. Build Containerfile.screenshot first.
# Run via the deploy tree's quadlet unit
# (deploy/host/etc/containers/systemd/desktop.container; see README.md).

# BOTH args must sit here, above the FIRST FROM. An ARG declared before any
# FROM is global and usable in every FROM line; one declared after a FROM
# belongs to that stage alone. Putting BASE_IMAGE between the two FROMs below
# scopes it to the tools stage, leaving `FROM ${BASE_IMAGE}` empty and the
# build dying with "no FROM statement found".
ARG BASE_IMAGE=localhost/desktop-container-base:latest
# Image carrying the client tools staged into this one; see "client tools".
ARG TOOLS_IMAGE=localhost/screenshot:latest

# A named stage rather than `COPY --from=${TOOLS_IMAGE}` further down: global
# ARGs are in scope for FROM instructions but NOT inside a build stage, so the
# variable would be empty there. Referring to the stage by name sidesteps it.
FROM ${TOOLS_IMAGE} AS tools

FROM ${BASE_IMAGE}

# --- Xorg -------------------------------------------------------------------
# Rootless: Xorg runs as the desktop user and opens devices by group
# permission; align-device-groups.sh renumbers the container's groups to
# the host device nodes' gids at boot (see Xwrapper.config comments).
COPY image/xorg/Xwrapper.config /etc/X11/Xwrapper.config
COPY image/xorg/xorg-gpu-conf.sh /usr/local/bin/xorg-gpu-conf.sh
COPY image/xorg/ensure-vt-devices.sh /usr/local/bin/ensure-vt-devices.sh
COPY image/xorg/align-device-groups.sh /usr/local/bin/align-device-groups.sh
COPY image/xorg/preflight-check.sh /usr/local/bin/preflight-check.sh
# Fixed monitor layout (KVM video). Opt-in per host: without the config file
# this generator writes nothing and Xorg autodetects as before. See README.md.
COPY image/xorg/xorg-monitor-conf.sh /usr/local/bin/xorg-monitor-conf.sh

# --- Session ----------------------------------------------------------------
COPY image/session/start-session /usr/local/bin/start-session
COPY image/session/session-postmortem /usr/local/bin/session-postmortem
COPY image/session/host-shell-setup.sh /usr/local/bin/host-shell-setup.sh
COPY image/session/host-terminal /usr/local/bin/host-terminal
COPY image/session/xinitrc.desktop /etc/X11/xinit/xinitrc.desktop
COPY image/session/mwmrc /etc/skel/.mwmrc
# Appearance (frame/menu/icon colors). Read straight from ~/.Xdefaults
# because nothing sets RESOURCE_MANAGER — see the file's header comment.
COPY image/session/Xdefaults /etc/skel/.Xdefaults
RUN chmod 0755 /usr/local/bin/xorg-gpu-conf.sh /usr/local/bin/ensure-vt-devices.sh \
        /usr/local/bin/start-session \
        /usr/local/bin/session-postmortem /usr/local/bin/align-device-groups.sh \
        /usr/local/bin/preflight-check.sh /usr/local/bin/host-shell-setup.sh \
        /usr/local/bin/xorg-monitor-conf.sh \
        /usr/local/bin/host-terminal /etc/X11/xinit/xinitrc.desktop

# uid 61000, matching the HOST desktop account the deploy tree creates
# (deploy/host/etc/sysusers.d/desktop-container.conf) - one contract, stated
# in both places. The container shares the host pid namespace with no user
# namespace, so this uid is a host-global identity: the host's
# desktop-session.service opens the logind session as it, the session
# processes in here run as it, and it must NEVER collide with a real host
# user's uid (1000 did, on the e2e VM, with real casualties - see the KILL
# note in the quadlet).
RUN for g in input render video audio tty; do \
        getent group "$g" >/dev/null || groupadd -r "$g"; \
    done \
    && groupadd -g 61000 desktop \
    && useradd -m -u 61000 -g desktop -G video,input,audio,render,tty desktop

# --- Audio export (PipeWire native + Pulse sockets in /run/desktop-audio) ---
# The native socket can't be added via a conf.d fragment (protocol-native
# refuses to load twice), so patch the stock module args to also serve
# /run/desktop-audio/pipewire-0.
RUN sed -i 's|#sockets = \[ { name = "pipewire-0" }, { name = "pipewire-0-manager" } \]|sockets = [ { name = "pipewire-0" }, { name = "pipewire-0-manager" }, { name = "/run/desktop-audio/pipewire-0" } ]|' \
        /usr/share/pipewire/pipewire.conf \
    && grep -q 'desktop-audio' /usr/share/pipewire/pipewire.conf
COPY image/pipewire/pipewire-pulse-export.conf /etc/pipewire/pipewire-pulse.conf.d/10-desktop-audio-export.conf
# Realtime without RTKit, for the daemon and for RT clients (pipewire-pulse).
#
# rtkit-daemon is masked in this container (it wants SYS_PTRACE,
# DAC_READ_SEARCH and NET_ADMIN - three of the capabilities the quadlet
# deliberately withholds), and module-rt PREFERS RTKit when PipeWire is built
# with D-Bus support rather than falling back to it only when direct
# scheduling fails. Left alone it queries RTKit, finds it masked, and settles
# for SCHED_FIFO at priority 1. Raising RLIMIT_RTPRIO does not change that on
# its own, because nothing was asking for the rlimit path.
#
# This edits the STOCK module-rt args rather than adding a conf.d drop-in. A
# drop-in was tried first and did NOT reach module-rt - the run with it in
# place still logged "mod.rt: RTKit does not give us MaxRealtimePriority",
# which module-rt cannot do once rtkit.enabled=false has been applied to it.
# Whether PipeWire merges context.modules entries by name is evidently not
# something to rely on, so the entry that definitely loads is edited directly:
# the same conclusion the protocol-native socket patch above reached, for the
# same reason.
#
# Only the three settings that decide WHERE realtime comes from. rt.prio is
# deliberately not set here: the stock conf carries an uncommented rt.prio = 60
# below the insertion point, which wins anyway, and a shadowed duplicate reads
# as a contradiction to the next person. 60 is under the 95 the rlimit grants,
# which is all that matters.
#
# Targeted by range (the `args = {` inside the module-rt block) rather than by
# matching a specific setting, so it does not depend on which lines the distro
# leaves commented out. If it does not apply exactly once, the BUILD fails and
# prints the block it could not patch - a five-minute signal instead of a
# thirteen-minute one, and it says what the file actually contains.
RUN for f in /usr/share/pipewire/pipewire.conf /usr/share/pipewire/client-rt.conf; do \
        [ -f "$f" ] || continue; \
        sed -i '/name = libpipewire-module-rt/,/flags/ s/^\([[:space:]]*\)args = {/\1args = {\n\1    rlimits.enabled  = true\n\1    rtportal.enabled = false\n\1    rtkit.enabled    = false/' "$f" \
        && [ "$(grep -c 'rtkit.enabled' "$f")" = 1 ] \
        || { echo "module-rt patch did not apply exactly once to $f; the block reads:"; \
             grep -n -A 12 'libpipewire-module-rt' "$f"; exit 1; }; \
    done
# No systemd in this image (see the init section at the bottom): the audio
# daemons are started by start-session as plain children of the session.
# Their socket umask is set inline there (was pipewire-umask.conf), and the
# quadlet's --ulimit rtprio/memlock/nice reach them verbatim by ordinary
# rlimit inheritance - the DefaultLimit* relay drop-ins this image used to
# carry (realtime-limits.conf) existed only because systemd does not pass
# its own rlimits to the units it starts, and are gone with it.

# --- client tools -----------------------------------------------------------
# The tools client containers run against this desktop (currently just
# screenshot). They ship here, not on the host, so their version is an
# attribute of the desktop image: the display server and the tools that speak
# to it update together and cannot disagree about the protocol. At boot
# publish-tools.sh copies them into the host directory the desktop.local/tools
# CDI device mounts into clients.
#
# Copied from the `tools` stage above, so this stays an offline build - nothing
# is fetched, the screenshot image just has to exist locally first (the CI
# workflows build it before this layer).
COPY --from=tools /screenshot /usr/libexec/desktop-tools/screenshot
COPY image/tools/publish-tools.sh /usr/local/bin/publish-tools.sh
RUN chmod 0755 /usr/local/bin/publish-tools.sh /usr/libexec/desktop-tools/*

# --- init -------------------------------------------------------------------
# desktop-init is the container's entrypoint: a small supervisor that runs
# the boot oneshots and keeps the session alive - see its header for why
# this image runs no systemd (the quadlet puts the container in the HOST
# pid namespace for window-to-pod identity, and a systemd system manager
# cannot run without being PID 1 of its namespace).
COPY image/init/desktop-init /usr/local/bin/desktop-init
RUN chmod 0755 /usr/local/bin/desktop-init

# SIGTERM, not systemd's SIGRTMIN+3: desktop-init traps TERM, stops the
# session tree (via setpriv; see the CAP_KILL note in its header) and exits.
STOPSIGNAL SIGTERM
CMD ["/usr/local/bin/desktop-init"]
