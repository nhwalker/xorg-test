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

RUN for g in input render video audio tty; do \
        getent group "$g" >/dev/null || groupadd -r "$g"; \
    done \
    && useradd -m -u 1000 -G video,input,audio,render,tty desktop

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
COPY image/systemd/pipewire-umask.conf /etc/systemd/user/pipewire.service.d/10-umask.conf
COPY image/systemd/pipewire-umask.conf /etc/systemd/user/pipewire-pulse.service.d/10-umask.conf
# Realtime limits, the other half of masking rtkit - see the file's header.
# systemd does not pass its own rlimits to the units it starts, so the
# quadlet's --ulimit stops at PID 1 without these.
COPY image/systemd/realtime-limits.conf /etc/systemd/system.conf.d/10-realtime.conf
COPY image/systemd/realtime-limits.conf /etc/systemd/user.conf.d/10-realtime.conf
# The exported sockets are served by the daemons themselves (not socket
# activation), so start the audio stack with every user manager.
RUN mkdir -p /etc/systemd/user/default.target.wants \
    && ln -sf /usr/lib/systemd/user/pipewire.service \
        /etc/systemd/user/default.target.wants/pipewire.service \
    && ln -sf /usr/lib/systemd/user/pipewire-pulse.service \
        /etc/systemd/user/default.target.wants/pipewire-pulse.service \
    && ln -sf /usr/lib/systemd/user/wireplumber.service \
        /etc/systemd/user/default.target.wants/wireplumber.service

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

# --- systemd ----------------------------------------------------------------
COPY image/systemd/desktop-tools-publish.service /etc/systemd/system/desktop-tools-publish.service
COPY image/systemd/xorg-conf.service /etc/systemd/system/xorg-conf.service
COPY image/systemd/desktop-session.service /etc/systemd/system/desktop-session.service
COPY image/systemd/journal-console.service /etc/systemd/system/journal-console.service
# Bound the container's own (RAM-backed) journal - see the file's header. The
# host-side half of the same concern is LogDriver=/--log-opt in the quadlet.
COPY image/systemd/journald-bounds.conf /etc/systemd/journald.conf.d/10-bounds.conf
COPY image/systemd/logind-container.conf /etc/systemd/logind.conf.d/10-container.conf
# The UBI base image ships logind masked (containers normally have no seat);
# this container manages its own seat0, so unmask it.
RUN systemctl unmask systemd-logind.service dbus-org.freedesktop.login1.service \
    # keep /run/desktop-audio working even if the host mount is absent
    && echo 'd /run/desktop-audio 1777 root root -' > /etc/tmpfiles.d/desktop-audio.conf \
    && systemctl enable xorg-conf.service desktop-session.service \
        journal-console.service desktop-tools-publish.service \
    # host udev owns the devices; /run/udev is mounted read-only from the host
    && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket \
        systemd-udevd-control.socket systemd-udev-trigger.service \
    # the session service owns tty1
    && systemctl mask getty@tty1.service console-getty.service \
    # rtkit cannot work in this container and must not be left failing.
    #
    # It hands PipeWire its realtime thread priorities, and to do that it wants
    # CAP_SYS_PTRACE and CAP_DAC_READ_SEARCH (to verify the calling process)
    # plus CAP_NET_ADMIN (its own PrivateNetwork= sandbox needs to configure
    # loopback). The quadlet deliberately grants none of those - they are three
    # of the most powerful capabilities there are, and not granting them is
    # most of the point of not being --privileged. Without them rtkit's
    # cap_set_proc() returns EPERM and the unit hits its start limit.
    #
    # A failed unit is not cosmetic here: systemctl is-system-running then
    # reports "degraded" rather than "running", which is what the deploy checks
    # wait for. Masking is the honest resolution - the service genuinely cannot
    # run, so say so - and PipeWire gets its realtime priorities from
    # RLIMIT_RTPRIO instead, which the quadlet sets and which needs no
    # capability at all. See "Container privileges" in README.md.
    && systemctl mask rtkit-daemon.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
