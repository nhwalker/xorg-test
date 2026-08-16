#!/bin/bash
# Golden assertions over helm template output for the desktop chart, plus
# the client-side manifests (which are plain YAML, not a chart: the display
# reaches client pods through the host CDI spec and an annotation, so there
# is nothing to install for them).
set -euo pipefail
cd "$(dirname "$0")/.."

ck() { echo "$2" | grep -q "$1" && echo "PASS: $3" || { echo "FAIL: $3"; exit 1; }; }
nk() { echo "$2" | grep -q "$1" && { echo "FAIL: $3"; exit 1; } || echo "PASS: $3"; }

DT=$(helm template d charts/desktop-container)
GPU=$(helm template d charts/desktop-container --set gpu.enabled=true)
NOPROBE=$(helm template d charts/desktop-container --set readinessProbe.enabled=false)
LIVE=$(helm template d charts/desktop-container --set livenessProbe.enabled=true)

# desktop chart
ck 'privileged: true'                        "$DT"  "desktop: privileged"
ck 'tty: true'                               "$DT"  "desktop: tty"
ck 'hostNetwork: true'                       "$DT"  "desktop: hostNetwork"
ck 'medium: Memory'                          "$DT"  "desktop: /run Memory emptyDir"
ck 'emptyDir: {}'                            "$DT"  "desktop: /tmp disk-backed"
ck 'path: /run/udev'                         "$DT"  "desktop: udev hostPath"
ck 'path: /tmp/.X11-unix'                    "$DT"  "desktop: x11 hostPath"
ck 'path: /run/desktop-audio'                "$DT"  "desktop: audio hostPath"
ck 'path: /etc/desktop-container'            "$DT"  "desktop: host-shell hostPath"
ck 'chmod 1777 /export/x11 /export/audio'    "$DT"  "desktop: initContainer chmod"
ck 'type: Recreate'                          "$DT"  "desktop: Recreate"
ck 'value: cri-o'                            "$DT"  "desktop: container env"
ck 'xdpyinfo'                                "$DT"  "desktop: connect-based readiness"
nk 'cdi.k8s.io'                              "$DT"  "desktop: no CDI annotation by default"
nk 'NVIDIA_DRIVER_CAPABILITIES'              "$DT"  "desktop: no NVIDIA env by default"
ck 'cdi.k8s.io/gpu: "nvidia.com/gpu=all"'    "$GPU" "desktop: CDI annotation with gpu.enabled"
ck 'NVIDIA_DRIVER_CAPABILITIES'              "$GPU" "desktop: NVIDIA env with gpu.enabled"
nk 'readinessProbe'                          "$NOPROBE" "desktop: probe disappears when disabled"
ck 'is-system-running'                       "$LIVE" "desktop: liveness renders when enabled"

# --- client manifests + the CDI spec they resolve against --------------------
# The device name is a contract between the generator and every client
# manifest; nothing at template time would catch the two drifting apart.
GEN=deploy/host/usr/local/libexec/desktop-display-cdi
KIND=$(sed -n 's/^CDI_KIND="\(.*\)"$/\1/p' "$GEN")
DEV=$(sed -n 's/^CDI_DEVICE="\(.*\)"$/\1/p' "$GEN")
[ -n "$KIND" ] && [ -n "$DEV" ] || { echo "FAIL: could not read CDI_KIND/CDI_DEVICE from $GEN"; exit 1; }
echo "PASS: generator advertises $KIND=$DEV"

for m in examples/x11-client-pod.yaml ci/vm/cdi-verify-pod.yaml ci/vm/testclient-pod.yaml; do
    # Comments stripped: these files DESCRIBE what they deliberately omit
    # ("no env, no volumeMounts"), which would otherwise match below.
    M=$(grep -v '^[[:space:]]*#' "$m")
    ck "cdi.k8s.io/.*: \"$KIND=$DEV\"" "$M" "$m: annotation matches the generated device"
    # Proof-by-construction: these pods must keep declaring NOTHING that
    # could hand them the display by another route, or they stop proving
    # that CDI is what wired them up.
    nk 'volumeMounts'                  "$M" "$m: no volumeMounts of its own"
    nk '^  volumes:'                   "$M" "$m: no volumes of its own"
    nk '^      env:'                   "$M" "$m: no env of its own"
    nk 'desktop.local/display: 1'      "$M" "$m: no leftover device-plugin resource request"
done

echo "== all helm assertions passed"
