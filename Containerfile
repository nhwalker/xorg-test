# Desktop APPLICATION layer: configuration, session logic, and services on
# top of the prebuilt base image (Containerfile.base holds all package /
# network dependencies). This build is fully offline:
#
#   podman build --network=none -t localhost/desktop-container:latest -f Containerfile .
#
# Override the base with --build-arg BASE_IMAGE=<ref> (e.g. a registry copy).
# Run via quadlet/desktop.container or charts/ (see install.sh / README.md).

ARG BASE_IMAGE=localhost/desktop-container-base:latest
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

# --- Session ----------------------------------------------------------------
COPY image/session/start-session /usr/local/bin/start-session
COPY image/session/session-postmortem /usr/local/bin/session-postmortem
COPY image/session/host-shell-setup.sh /usr/local/bin/host-shell-setup.sh
COPY image/session/host-terminal /usr/local/bin/host-terminal
COPY image/session/xinitrc.desktop /etc/X11/xinit/xinitrc.desktop
COPY image/session/mwmrc /etc/skel/.mwmrc
RUN chmod 0755 /usr/local/bin/xorg-gpu-conf.sh /usr/local/bin/ensure-vt-devices.sh \
        /usr/local/bin/start-session \
        /usr/local/bin/session-postmortem /usr/local/bin/align-device-groups.sh \
        /usr/local/bin/preflight-check.sh /usr/local/bin/host-shell-setup.sh \
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
COPY image/systemd/pipewire-umask.conf /etc/systemd/user/pipewire.service.d/10-umask.conf
COPY image/systemd/pipewire-umask.conf /etc/systemd/user/pipewire-pulse.service.d/10-umask.conf
# The exported sockets are served by the daemons themselves (not socket
# activation), so start the audio stack with every user manager.
RUN mkdir -p /etc/systemd/user/default.target.wants \
    && ln -sf /usr/lib/systemd/user/pipewire.service \
        /etc/systemd/user/default.target.wants/pipewire.service \
    && ln -sf /usr/lib/systemd/user/pipewire-pulse.service \
        /etc/systemd/user/default.target.wants/pipewire-pulse.service \
    && ln -sf /usr/lib/systemd/user/wireplumber.service \
        /etc/systemd/user/default.target.wants/wireplumber.service

# --- systemd ----------------------------------------------------------------
COPY image/systemd/xorg-conf.service /etc/systemd/system/xorg-conf.service
COPY image/systemd/desktop-session.service /etc/systemd/system/desktop-session.service
COPY image/systemd/journal-console.service /etc/systemd/system/journal-console.service
COPY image/systemd/logind-container.conf /etc/systemd/logind.conf.d/10-container.conf
# The UBI base image ships logind masked (containers normally have no seat);
# this container manages its own seat0, so unmask it.
RUN systemctl unmask systemd-logind.service dbus-org.freedesktop.login1.service \
    # keep /run/desktop-audio working even if the host mount is absent
    && echo 'd /run/desktop-audio 1777 root root -' > /etc/tmpfiles.d/desktop-audio.conf \
    && systemctl enable xorg-conf.service desktop-session.service \
        journal-console.service \
    # host udev owns the devices; /run/udev is mounted read-only from the host
    && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket \
        systemd-udevd-control.socket systemd-udev-trigger.service \
    # the session service owns tty1
    && systemctl mask getty@tty1.service console-getty.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
