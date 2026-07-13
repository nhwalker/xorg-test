# Containerized desktop: UBI 9 base + Rocky 9 fill-in repos,
# Xorg + mwm (Motif) + PipeWire audio, systemd as PID 1.
#
# Build:  podman build -t localhost/desktop-container:latest -f Containerfile .
# Run:    via quadlet/desktop.container (see install.sh / README.md)

FROM registry.access.redhat.com/ubi9/ubi

# --- Rocky Linux 9 repos, at LOWER priority than the UBI repos -------------
# UBI repos default to priority=99; rocky9.repo sets priority=200, so any
# package Red Hat ships in UBI is always preferred and Rocky only fills in
# what UBI lacks (Xorg server, motif, pipewire, ...).
RUN curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9 \
        https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9 \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
COPY image/rocky9.repo /etc/yum.repos.d/rocky9.repo

# --- Packages ---------------------------------------------------------------
# NOTE: no NVIDIA bits here; the nvidia container toolkit injects the driver
# userspace (and Xorg driver module) at run time when a GPU is present.
RUN dnf -y install \
        systemd \
        xorg-x11-server-Xorg \
        xorg-x11-xinit \
        xorg-x11-xauth \
        xorg-x11-drv-libinput \
        mesa-dri-drivers \
        mesa-libGL \
        mesa-libEGL \
        glx-utils \
        xrandr \
        xset \
        xsetroot \
        xhost \
        xdpyinfo \
        motif \
        xterm \
        xorg-x11-fonts-misc \
        dejavu-sans-fonts \
        pipewire \
        pipewire-alsa \
        pipewire-pulseaudio \
        pipewire-utils \
        pulseaudio-utils \
        wireplumber \
        alsa-utils \
        procps-ng \
    && dnf clean all

# --- Xorg -------------------------------------------------------------------
# Rootless: Xorg runs as the desktop user and opens devices by group
# permission; align-device-groups.sh renumbers the container's groups to
# the host device nodes' gids at boot (see Xwrapper.config comments).
COPY image/xorg/Xwrapper.config /etc/X11/Xwrapper.config
COPY image/xorg/xorg-gpu-conf.sh /usr/local/bin/xorg-gpu-conf.sh
COPY image/xorg/align-device-groups.sh /usr/local/bin/align-device-groups.sh

# --- Session ----------------------------------------------------------------
COPY image/session/start-session /usr/local/bin/start-session
COPY image/session/xinitrc.desktop /etc/X11/xinit/xinitrc.desktop
COPY image/session/mwmrc /etc/skel/.mwmrc
RUN chmod 0755 /usr/local/bin/xorg-gpu-conf.sh /usr/local/bin/start-session \
        /usr/local/bin/align-device-groups.sh /etc/X11/xinit/xinitrc.desktop

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
COPY image/systemd/logind-container.conf /etc/systemd/logind.conf.d/10-container.conf
# The UBI base image ships logind masked (containers normally have no seat);
# this container manages its own seat0, so unmask it.
RUN systemctl unmask systemd-logind.service dbus-org.freedesktop.login1.service \
    # keep /run/desktop-audio working even if the host mount is absent
    && echo 'd /run/desktop-audio 1777 root root -' > /etc/tmpfiles.d/desktop-audio.conf \
    && systemctl enable xorg-conf.service desktop-session.service \
    # host udev owns the devices; /run/udev is mounted read-only from the host
    && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket \
        systemd-udevd-control.socket systemd-udev-trigger.service \
    # the session service owns tty1
    && systemctl mask getty@tty1.service console-getty.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
