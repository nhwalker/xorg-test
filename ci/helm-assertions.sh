#!/bin/bash
# Golden assertions over helm template output for the cdi-device-plugin
# chart, plus the client manifests (plain YAML: a client only requests a
# resource, so there is nothing to install for it).
#
# The desktop itself is not a helm chart - it is deployed by the quadlet in
# the deploy/ tree. Kubernetes here serves application containers only, and
# the plugin is the single piece that lets them name a CDI device.
set -euo pipefail
cd "$(dirname "$0")/.."
# gen_grep_text: the rendered chart read without its comment lines, so a
# comment that names what is asserted cannot answer it (Requirements.md S9.1.2).
# shellcheck source=ci/evidence.sh
. ci/evidence.sh
# A command that fails where nothing handles it would end the script, under
# errexit, with no word of why: say which, and where (Requirements.md S9.2.3).
# The main shell reports; a substitution's subshell leaves it to the
# assignment that then fails.
set -E
on_unhandled() {
    [ "$BASH_SUBSHELL" = 0 ] || return 0
    trap - ERR
    echo "FAIL: helm-assertions.sh: unhandled failure (exit $1) at $3: $2" >&2
}
trap 'on_unhandled $? "$BASH_COMMAND" "${BASH_SOURCE[0]}:$LINENO"' ERR

ck() { if gen_grep_text -q -- "$1" "$2"; then echo "PASS: $3"; else echo "FAIL: $3"; exit 1; fi; }
nk() { if gen_grep_text -q -- "$1" "$2"; then echo "FAIL: $3"; exit 1; else echo "PASS: $3"; fi; }

DP=$(helm template p charts/cdi-device-plugin --set cdiDevice=desktop.local/display=all --set count=10)
DPA=$(helm template a charts/cdi-device-plugin --set cdiDevice=desktop.local/audio=all --set count=10)
DPO=$(helm template p charts/cdi-device-plugin --set cdiDevice=nvidia.com/gpu=all \
      --set resourceName=desktop.local/gpu --set priorityClassName=system-node-critical)
DPNS=$(helm template p charts/cdi-device-plugin --set cdiDevice=desktop.local/display=all \
       --set seLinuxOptions=null)

# --- cdi-device-plugin chart -------------------------------------------------
ck 'kind: DaemonSet'                         "$DP"  "plugin: daemonset"
ck 'path: /var/lib/kubelet/device-plugins'   "$DP"  "plugin: kubelet dir hostPath"
ck 'value: "desktop.local/display=all"'      "$DP"  "plugin: CDI device passed through"
ck 'value: "desktop.local/display"'          "$DP"  "plugin: resource name defaults to the CDI kind"
ck 'value: "desktop.local/audio=all"'        "$DPA" "plugin: a second release serves the audio device"
ck 'value: "desktop.local/audio"'            "$DPA" "plugin: audio resource name defaults to its kind"
ck 'value: "10"'                             "$DP"  "plugin: count passed through"
ck 'value: "/etc/cdi,/var/run/cdi"'          "$DP"  "plugin: default spec dirs"
ck 'readOnly: true'                          "$DP"  "plugin: CDI specs mounted read-only"
nk 'priorityClassName'                       "$DP"  "plugin: no priorityClassName by default"
ck 'value: "desktop.local/gpu"'              "$DPO" "plugin: resource name override wins over the kind"
ck 'priorityClassName: system-node-critical' "$DPO" "plugin: priorityClassName renders when set"
# The plugin registers against KUBELET's socket, which a confined container may
# not connect to on an enforcing host - without this it loops on "permission
# denied" and the resource never becomes allocatable.
ck 'type: spc_t'                             "$DP"  "plugin: SELinux type for kubelet registration"
nk 'privileged'                              "$DP"  "plugin: spc_t, NOT privileged (no extra caps/devices)"
nk 'seLinuxOptions'                          "$DPNS" "plugin: the SELinux type is opt-out-able"
# cdiDevice is the one value with no sensible default; rendering without it
# would produce a plugin that can never resolve anything.
helm template p charts/cdi-device-plugin >/dev/null 2>&1 \
    && { echo "FAIL: plugin: chart rendered without cdiDevice"; exit 1; } \
    || echo "PASS: plugin: chart refuses to render without cdiDevice"
helm template p charts/cdi-device-plugin --set cdiDevice=missing-equals >/dev/null 2>&1 \
    && { echo "FAIL: plugin: chart accepted an unqualified cdiDevice"; exit 1; } \
    || echo "PASS: plugin: chart rejects an unqualified cdiDevice"

# --- client manifests --------------------------------------------------------
# The resource names are a contract between the plugin releases, the CDI
# generator and every client manifest; nothing at template time would catch
# them drifting apart, so read them back from the rendered chart.
DISPLAY_RES=$(sed -n 's/^[[:space:]]*value: "\(desktop\.local\/display\)"$/\1/p' <<<"$DP")
DISPLAY_RES=${DISPLAY_RES%%$'\n'*}
AUDIO_RES=$(sed -n 's/^[[:space:]]*value: "\(desktop\.local\/audio\)"$/\1/p' <<<"$DPA")
AUDIO_RES=${AUDIO_RES%%$'\n'*}
[ -n "$DISPLAY_RES" ] && [ -n "$AUDIO_RES" ] \
    || { echo "FAIL: could not read the advertised resource names from the chart"; exit 1; }
echo "PASS: plugin advertises $DISPLAY_RES and $AUDIO_RES"

# The generator is the other end of that contract: the kinds in the specs it
# writes must be exactly the resources the manifests request. Read from specs
# it generates, not from its source (Requirements.md S9.1.2): it runs as it
# ships, with only its output directory moved to a scratch one and its host
# config file pointed at one that does not exist.
GEN=deploy/host/usr/local/libexec/desktop-client-cdi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sed -e "s|^CDI_DIR=/etc/cdi\$|CDI_DIR=$T/cdi|" -e "s|^CONF=.*|CONF=$T/no-client-cdi.conf|" "$GEN" > "$T/gen"
grep -qx "CDI_DIR=$T/cdi" "$T/gen" && grep -qx "CONF=$T/no-client-cdi.conf" "$T/gen" \
    || { echo "FAIL: desktop-client-cdi's output directory or config could not be moved to a scratch one"; exit 1; }
bash "$T/gen" >/dev/null || { echo "FAIL: desktop-client-cdi did not run"; exit 1; }
for spec in desktop-display.yaml desktop-audio.yaml; do
    k=$(sed -n 's/^kind: //p' "$T/cdi/$spec")
    case "$k" in
        "$DISPLAY_RES"|"$AUDIO_RES") echo "PASS: the generated $spec's kind, $k, is an advertised resource" ;;
        *) echo "FAIL: the generated $spec's kind, ${k:-none}, is not advertised by any plugin release"; exit 1 ;;
    esac
done

# Pods that want the whole desktop request both capabilities...
for m in examples/x11-client-pod.yaml ci/vm/cdi-verify-pod.yaml ci/vm/testclient-pod.yaml; do
    # Comments stripped: these files DESCRIBE what they deliberately omit
    # ("no env, no volumeMounts"), which would otherwise match below.
    M=$(grep -v '^[[:space:]]*#' "$m")
    ck "$DISPLAY_RES: 1"               "$M" "$m: requests the display resource"
    ck "$AUDIO_RES: 1"                 "$M" "$m: requests the audio resource"
    nk 'volumeMounts'                  "$M" "$m: no volumeMounts of its own"
    nk '^  volumes:'                   "$M" "$m: no volumes of its own"
    nk '^      env:'                   "$M" "$m: no env of its own"
    nk 'cdi\.k8s\.io'                  "$M" "$m: no CDI annotation (it would be silently ignored)"
    # The plugin needs an SELinux type because it talks to kubelet. A CLIENT
    # talks only to the desktop, over directories the node labels
    # container_file_t, so it stays fully confined. If one of these ever grows
    # a securityContext, the confined path has stopped being tested.
    nk 'securityContext'               "$M" "$m: no securityContext (stays a confined container_t)"
    nk 'privileged'                    "$M" "$m: not privileged"
done

# ...and the narrow fixtures request exactly ONE, which is what makes the
# e2e's leak assertions meaningful rather than tautological.
DO=$(grep -v '^[[:space:]]*#' ci/vm/display-only-pod.yaml)
ck "$DISPLAY_RES: 1" "$DO" "display-only: requests display"
nk "$AUDIO_RES"      "$DO" "display-only: does NOT request audio"
AO=$(grep -v '^[[:space:]]*#' ci/vm/audio-only-pod.yaml)
ck "$AUDIO_RES: 1"   "$AO" "audio-only: requests audio"
nk "$DISPLAY_RES"    "$AO" "audio-only: does NOT request display"

# Every client manifest - the example, the whole-desktop and narrow fixtures,
# the test pattern and the journey pods - declares nothing of its own: no
# securityContext (it stays a confined container_t), no volumes, mounts or
# env, no CDI annotation, nothing privileged. All it gets comes from the CDI
# specs through its resource requests (Requirements.md S7.3.3).
for m in examples/x11-client-pod.yaml ci/vm/cdi-verify-pod.yaml ci/vm/testclient-pod.yaml \
         ci/vm/display-only-pod.yaml ci/vm/audio-only-pod.yaml ci/vm/testpattern-pod.yaml \
         ci/vm/journey-pod.yaml ci/vm/early-pod.yaml; do
    M=$(grep -v '^[[:space:]]*#' "$m")
    ck 'desktop\.local/'              "$M" "$m: requests a desktop.local resource"
    nk 'securityContext'               "$M" "$m: no securityContext (stays a confined container_t)"
    nk 'volumeMounts'                  "$M" "$m: no volumeMounts of its own"
    nk '^  volumes:'                   "$M" "$m: no volumes of its own"
    nk '^      env:'                   "$M" "$m: no env of its own"
    nk 'cdi\.k8s\.io'                  "$M" "$m: no CDI annotation"
    nk 'privileged'                    "$M" "$m: not privileged"
done

echo "== all helm assertions passed"
