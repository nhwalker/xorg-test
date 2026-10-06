#!/bin/bash
# ci/hw/acceptance.sh's helpers on canned input, with no hardware, no root
# and no desktop: the ones that parse or rewrite what a host gives them (a
# CDI spec, xrandr's and wpctl's output, the container log's size). The
# functions are sourced out of the script, its command line not run.
#   ci/hw/acceptance-tests.sh      exit status: the number of failures
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# The functions only: everything above the command line.
sed -n '1,/^# --- the command line/p' "$REPO/ci/hw/acceptance.sh" | sed "s#^REPO=.*#REPO=$REPO#" > "$T/fns.sh"
export HW_STATE=$T/state EV_ROOT=$T/state/artifacts
mkdir -p "$EV_ROOT"
# shellcheck disable=SC1091
. "$T/fns.sh"
# The script's own traps undo what a story staged; nothing is staged here.
trap 'rm -rf "${T:?}"' EXIT
trap - INT TERM

# --- a spec shaped as nvidia-ctk writes it -------------------------------------
cat > "$T/spec.yaml" <<'EOF'
---
cdiVersion: 0.5.0
containerEdits:
  deviceNodes:
  - path: /dev/nvidia-modeset
  - path: /dev/nvidiactl
  env:
  - NVIDIA_VISIBLE_DEVICES=void
  hooks:
  - args:
    - nvidia-ctk
    - hook
    - create-symlinks
    - --link
    - libglxserver_nvidia.so.550.54.14::/usr/lib64/xorg/modules/extensions/libglxserver_nvidia.so
    hookName: createContainer
    path: /usr/bin/nvidia-ctk
  mounts:
  - containerPath: /usr/lib64/libEGL_nvidia.so.550.54.14
    hostPath: /usr/lib64/libEGL_nvidia.so.550.54.14
    options:
    - ro
    - nosuid
    - nodev
    - bind
  - containerPath: /usr/lib64/xorg/modules/drivers/nvidia_drv.so
    hostPath: /usr/lib64/xorg/modules/drivers/nvidia_drv.so
    options:
    - ro
    - nosuid
    - nodev
    - bind
  - containerPath: /usr/lib64/xorg/modules/extensions/libglxserver_nvidia.so.550.54.14
    hostPath: /usr/lib64/xorg/modules/extensions/libglxserver_nvidia.so.550.54.14
    options:
    - ro
    - nosuid
    - nodev
    - bind
  - containerPath: /usr/lib64/libnvidia-glcore.so.550.54.14
    hostPath: /usr/lib64/libnvidia-glcore.so.550.54.14
    options:
    - ro
    - nosuid
    - nodev
    - bind
devices:
- containerEdits:
    deviceNodes:
    - path: /dev/nvidia0
    - path: /dev/dri/card1
  name: "0"
kind: nvidia.com/gpu
EOF
n=$(spec_without_xdriver "$T/spec.yaml" "$T/staged.yaml")
[ "$n" = 2 ] && ok "two X driver mounts dropped" || bad "dropped '$n', want 2"
grep -q 'hostPath: .*nvidia_drv\.so' "$T/staged.yaml" && bad "nvidia_drv.so's mount is still there" || ok "no nvidia_drv.so mount left"
grep -q 'hostPath: .*libglxserver_nvidia' "$T/staged.yaml" && bad "libglxserver's mount is still there" || ok "no libglxserver mount left"
grep -q 'hostPath: /usr/lib64/libEGL_nvidia.so.550.54.14' "$T/staged.yaml" && grep -q 'hostPath: /usr/lib64/libnvidia-glcore.so.550.54.14' "$T/staged.yaml" \
    && ok "the other mounts kept" || bad "another mount went too"
grep -q 'create-symlinks' "$T/staged.yaml" && grep -q 'kind: nvidia.com/gpu' "$T/staged.yaml" && grep -q 'name: "0"' "$T/staged.yaml" \
    && ok "hooks, devices and kind untouched" || bad "something outside the mounts changed"
[ "$(diff "$T/spec.yaml" "$T/staged.yaml" | grep -c '^<')" = 14 ] && ok "exactly the two 7-line items removed" || bad "diff: $(diff "$T/spec.yaml" "$T/staged.yaml" | grep -c '^<') lines removed"
if python3 -c 'import yaml' 2>/dev/null; then
    python3 - "$T/staged.yaml" <<'PY' && ok "the staged spec parses as YAML, 2 mounts" || bad "the staged spec is not valid YAML"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert len(d["containerEdits"]["mounts"]) == 2, d["containerEdits"]["mounts"]
PY
else echo "(no PyYAML here: YAML parse not checked)"; fi

# --- stale_spec's rewrite ---------------------------------------------------------
cp "$T/spec.yaml" "$T/stale.yaml"
ver=$(grep -oE 'libnvidia-glcore\.so\.[0-9][0-9.]*' "$T/stale.yaml" | head -n1 | sed 's/^libnvidia-glcore\.so\.//')
[ "$ver" = 550.54.14 ] && ok "version read from the spec: $ver" || bad "version read: '$ver'"
sed -i "s/\\.so\\.${ver//./\\.}/.so.${ver}-gone/g" "$T/stale.yaml"
[ "$(grep -c '550.54.14-gone' "$T/stale.yaml")" = 7 ] && ok "every .so.$ver path renamed (7)" || bad "renamed: $(grep -c '550.54.14-gone' "$T/stale.yaml")"
grep -q '\.so\.550\.54\.14[^-]' "$T/stale.yaml" && bad "an unrenamed .so.$ver is left" || ok "none left unrenamed"

# --- arrangement -------------------------------------------------------------------
cat > "$T/x0.txt" <<'EOF'
$ xq xrandr --query
Screen 0: minimum 8 x 8, current 3840 x 1080, maximum 32767 x 32767
DP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+  59.94
DP-2 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+
HDMI-1 disconnected (normal left inverted right x axis y axis)
[exit 0]
EOF
sed 's/60.00\*+/60.00 +/; s/^   1920x1080     60.00 +  59.94/   1920x1080_60.00  59.96*/' "$T/x0.txt" > "$T/x1.txt"
[ "$(arrangement "$T/x0.txt")" = "$(arrangement "$T/x1.txt")" ] && ok "same arrangement despite renamed modes: $(arrangement "$T/x0.txt" | tr '\n' ';')" || bad "arrangement differs"
sed 's/1920x1080+1920+0/1920x1080+0+1080/' "$T/x0.txt" > "$T/x2.txt"
[ "$(arrangement "$T/x0.txt")" != "$(arrangement "$T/x2.txt")" ] && ok "a moved output is a different arrangement" || bad "a moved output went unnoticed"

# --- wp_devices on wpctl status -----------------------------------------------------
cat > "$T/wpctl.txt" <<'EOF'
PipeWire 'pipewire-0' [0.3.67, desktop@host, cookie:1]
 └─ Clients:
        31. WirePlumber                         [0.3.67, desktop@host, pid:120]

Audio
 ├─ Devices:
 │      42. Built-in Audio                      [alsa]
 │      55. USB Audio                           [alsa]
 │
 ├─ Sinks:
 │  *   48. Built-in Audio Analog Stereo        [vol: 0.40]
 │
 ├─ Sources:
 │
 ├─ Filters:
 │
 └─ Streams:
        70. paplay

Video
 ├─ Devices:
 │      60. some camera                         [v4l2]
EOF
desk() { cat "$T/wpctl.txt"; }
got=$(wp_devices)
[ "$got" = "$(printf '42. Built-in Audio                      [alsa]\n55. USB Audio                           [alsa]')" ] \
    && ok "wp_devices: the two Audio devices, not the Video one" || { bad "wp_devices gave:"; echo "$got"; }

# --- log_sample with a fake podman ---------------------------------------------------
mkdir -p "$T/bin"
printf 'x%.0s' $(seq 1000) > "$T/ctr.log"
cat > "$T/bin/podman" <<EOF
#!/bin/bash
case "\$*" in
    *LogConfig.Path*) echo "$T/ctr.log" ;;
    *State.StartedAt*) echo "2026-10-06 01:00:00 +0000 UTC" ;;
    *"json .HostConfig.LogConfig"*) echo '{"Type":"k8s-file","Path":"$T/ctr.log","Size":"64MB"}' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/podman"
PATH=$T/bin:$PATH log_sample 2>/dev/null
[ "$(cat "$EV_ROOT/S8.3.2/result")" = PASS ] && ok "a 1000-byte sample passes" || bad "sample result: $(cat "$EV_ROOT/S8.3.2/result")"
[ "$(wc -l < "$HW_STATE/log-bound.tsv")" = 2 ] && ok "the table has its header and one row" || bad "table: $(cat "$HW_STATE/log-bound.tsv")"
PATH=$T/bin:$PATH log_check 2>/dev/null
grep -q $'FAIL\t2 samples over 0 h' "$EV_ROOT/S8.3.2/checks.tsv" && ok "two samples at once: the check wants days" || { bad "check rows:"; cut -f2- "$EV_ROOT/S8.3.2/checks.tsv"; }
grep -q $'PASS\tthe running container.s LogConfig carries the 64 MB bound' "$EV_ROOT/S8.3.2/checks.tsv" && ok "the LogConfig bound is read" || bad "LogConfig not read"
[ -s "$EV_ROOT/S8.3.2/evidence.md" ] && ok "evidence.md rendered" || bad "no evidence.md"

# --- tester: HW_TESTER, else the kept name; a rehearsal keeps none ---------------
rm -f "$HW_STATE/tester"
got=$(HW_TESTER='A. Tester' tester)
[ "$got" = "A. Tester" ] && ok "HW_TESTER names the tester" || bad "HW_TESTER gave '$got'"
got=$(HW_REHEARSE=1 tester)
[ "$got" = rehearsal ] && [ ! -e "$HW_STATE/tester" ] && ok "a rehearsal is 'rehearsal' and keeps no name" || bad "rehearsal gave '$got'"
echo "B. Kept" > "$HW_STATE/tester"
got=$(tester)
[ "$got" = "B. Kept" ] && ok "a later run takes the kept name" || bad "the kept name read as '$got'"

echo "---- $fails failure(s)"
exit "$fails"
