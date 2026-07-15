#!/bin/bash
# Golden assertions over helm template output for both charts.
set -euo pipefail
cd "$(dirname "$0")/.."

ck() { echo "$2" | grep -q "$1" && echo "PASS: $3" || { echo "FAIL: $3"; exit 1; }; }
nk() { echo "$2" | grep -q "$1" && { echo "FAIL: $3"; exit 1; } || echo "PASS: $3"; }

DT=$(helm template d charts/desktop-container)
GPU=$(helm template d charts/desktop-container --set gpu.enabled=true)
NOPROBE=$(helm template d charts/desktop-container --set readinessProbe.enabled=false)
LIVE=$(helm template d charts/desktop-container --set livenessProbe.enabled=true)
DP=$(helm template p charts/desktop-device-plugin)
DPP=$(helm template p charts/desktop-device-plugin --set priorityClassName=system-node-critical \
      --set resourceName=corp.example/desk --set slots=3)

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

# device-plugin chart
ck 'kind: DaemonSet'                         "$DP"  "plugin: daemonset"
ck 'path: /var/lib/kubelet/device-plugins'   "$DP"  "plugin: kubelet dir hostPath"
ck 'readOnly: true'                          "$DP"  "plugin: x11 mounted ro"
ck 'value: "desktop.local/display"'          "$DP"  "plugin: default resource name"
ck 'value: "10"'                             "$DP"  "plugin: default slots"
nk 'priorityClassName'                       "$DP"  "plugin: no priorityClassName by default"
ck 'priorityClassName: system-node-critical' "$DPP" "plugin: priorityClassName renders when set"
ck 'value: "corp.example/desk"'              "$DPP" "plugin: custom resource name"
ck 'value: "3"'                              "$DPP" "plugin: custom slots"

echo "== all helm assertions passed"
