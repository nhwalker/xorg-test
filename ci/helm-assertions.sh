#!/bin/bash
# Golden assertions over helm template output for the desktop and
# cdi-device-plugin charts, plus the client manifests (plain YAML: a client
# only requests a resource, so there is nothing to install for it).
set -euo pipefail
cd "$(dirname "$0")/.."

ck() { echo "$2" | grep -q "$1" && echo "PASS: $3" || { echo "FAIL: $3"; exit 1; }; }
nk() { echo "$2" | grep -q "$1" && { echo "FAIL: $3"; exit 1; } || echo "PASS: $3"; }

DT=$(helm template d charts/desktop-container)
GPU=$(helm template d charts/desktop-container --set gpu.enabled=true)
GPURES=$(helm template d charts/desktop-container --set gpu.enabled=true \
         --set resources.limits.memory=2Gi --set resources.requests.cpu=500m)
NOPROBE=$(helm template d charts/desktop-container --set readinessProbe.enabled=false)
LIVE=$(helm template d charts/desktop-container --set livenessProbe.enabled=true)
DP=$(helm template p charts/cdi-device-plugin --set cdiDevice=desktop.local/display=all --set count=10)
DPO=$(helm template p charts/cdi-device-plugin --set cdiDevice=nvidia.com/gpu=all \
      --set resourceName=desktop.local/gpu --set priorityClassName=system-node-critical)

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
nk 'NVIDIA_DRIVER_CAPABILITIES'              "$DT"  "desktop: no NVIDIA env by default"
nk 'nvidia.com/gpu'                          "$DT"  "desktop: no GPU resource by default"
ck 'nvidia.com/gpu: 1'                       "$GPU" "desktop: GPU resource request with gpu.enabled"
ck 'NVIDIA_DRIVER_CAPABILITIES'              "$GPU" "desktop: NVIDIA env with gpu.enabled"
# A pod-spec annotation never reaches the runtime's CDI injection (kubelet
# builds CRI container annotations from device-plugin output only), so its
# reappearance anywhere would be a silent regression to a broken mechanism.
nk 'cdi.k8s.io'                              "$DT"  "desktop: no CDI annotation by default"
nk 'cdi.k8s.io'                              "$GPU" "desktop: GPU uses a resource, NOT an annotation"
# The GPU limit must merge into user-supplied resources, not emit a second
# limits: key (which would be invalid YAML with a silent last-wins parse).
ck 'memory: 2Gi'                             "$GPURES" "desktop: user resources survive gpu.enabled"
ck 'cpu: 500m'                               "$GPURES" "desktop: user requests survive gpu.enabled"
ck 'nvidia.com/gpu: 1'                       "$GPURES" "desktop: GPU limit merged alongside them"
[ "$(echo "$GPURES" | grep -c 'limits:')" = 1 ] \
    && echo "PASS: desktop: exactly one limits: key when merging" \
    || { echo "FAIL: desktop: duplicate limits: key when merging"; exit 1; }
nk 'readinessProbe'                          "$NOPROBE" "desktop: probe disappears when disabled"
ck 'is-system-running'                       "$LIVE" "desktop: liveness renders when enabled"

# --- cdi-device-plugin chart -------------------------------------------------
ck 'kind: DaemonSet'                         "$DP"  "plugin: daemonset"
ck 'path: /var/lib/kubelet/device-plugins'   "$DP"  "plugin: kubelet dir hostPath"
ck 'value: "desktop.local/display=all"'      "$DP"  "plugin: CDI device passed through"
ck 'value: "desktop.local/display"'          "$DP"  "plugin: resource name defaults to the CDI kind"
ck 'value: "10"'                             "$DP"  "plugin: count passed through"
ck 'value: "/etc/cdi,/var/run/cdi"'          "$DP"  "plugin: default spec dirs"
ck 'readOnly: true'                          "$DP"  "plugin: CDI specs mounted read-only"
nk 'priorityClassName'                       "$DP"  "plugin: no priorityClassName by default"
ck 'value: "desktop.local/gpu"'              "$DPO" "plugin: resource name override wins over the kind"
ck 'priorityClassName: system-node-critical' "$DPO" "plugin: priorityClassName renders when set"
# cdiDevice is the one value with no sensible default; rendering without it
# would produce a plugin that can never resolve anything.
helm template p charts/cdi-device-plugin >/dev/null 2>&1 \
    && { echo "FAIL: plugin: chart rendered without cdiDevice"; exit 1; } \
    || echo "PASS: plugin: chart refuses to render without cdiDevice"
helm template p charts/cdi-device-plugin --set cdiDevice=missing-equals >/dev/null 2>&1 \
    && { echo "FAIL: plugin: chart accepted an unqualified cdiDevice"; exit 1; } \
    || echo "PASS: plugin: chart rejects an unqualified cdiDevice"

# --- client manifests --------------------------------------------------------
# The resource name is a contract between the plugin release and every
# client manifest; nothing at template time would catch them drifting apart.
RES=$(echo "$DP" | sed -n 's/.*value: "\(desktop\.local\/display\)"$/\1/p' | head -1)
[ -n "$RES" ] || { echo "FAIL: could not read the advertised resource name from the chart"; exit 1; }
echo "PASS: plugin advertises $RES"

for m in examples/x11-client-pod.yaml ci/vm/cdi-verify-pod.yaml ci/vm/testclient-pod.yaml; do
    # Comments stripped: these files DESCRIBE what they deliberately omit
    # ("no env, no volumeMounts"), which would otherwise match below.
    M=$(grep -v '^[[:space:]]*#' "$m")
    ck "$RES: 1"                       "$M" "$m: requests the advertised resource"
    # Proof-by-construction: these pods must keep declaring NOTHING that
    # could hand them the display by another route, or they stop proving
    # that CDI is what wired them up.
    nk 'volumeMounts'                  "$M" "$m: no volumeMounts of its own"
    nk '^  volumes:'                   "$M" "$m: no volumes of its own"
    nk '^      env:'                   "$M" "$m: no env of its own"
    nk 'cdi\.k8s\.io'                  "$M" "$m: no CDI annotation (it would be silently ignored)"
done

echo "== all helm assertions passed"
