#!/bin/bash
# Pull-or-build the two base images, content-addressed by their inputs.
# A base is reused from GHCR when nothing that goes into it changed;
# otherwise it is rebuilt (and pushed when PUSH_BASES=1).
set -euo pipefail
# A command that fails where nothing handles it would end the script, under
# errexit, with no word of why: say which, and where (Requirements.md S9.2.3).
# The main shell reports; a substitution's subshell leaves it to the
# assignment that then fails.
set -E
on_unhandled() {
    [ "$BASH_SUBSHELL" = 0 ] || return 0
    trap - ERR
    echo "FAIL: build-bases.sh: unhandled failure (exit $1) at $3: $2" >&2
}
trap 'on_unhandled $? "$BASH_COMMAND" "${BASH_SOURCE[0]}:$LINENO"' ERR

REG="${REGISTRY:?REGISTRY must be set, e.g. ghcr.io/owner}"
PUSH="${PUSH_BASES:-0}"

content_tag() {
    sha256sum "$@" | sha256sum | cut -c1-16
}

ensure_base() {
    local name="$1" containerfile="$2"
    shift 2
    local tag ref
    tag="base-$(content_tag "$containerfile" "$@")"
    ref="$REG/$name:$tag"
    if podman pull "$ref" >/dev/null 2>&1; then
        podman tag "$ref" "localhost/$name:latest"
        echo "== reused cached base $ref"
        return 0
    fi
    echo "== building $name (cache miss for $ref)"
    # Deliberately NOT --network=none: the bases are the layer that installs
    # packages, and they are the ONLY layer allowed to reach the network. The
    # application layers on top are built with --network=none in the workflows,
    # which is what makes "no dependency appears without a base rebuild" an
    # enforced property rather than a convention. No -t beyond :latest here -
    # the content-addressed ref is applied separately below, only when pushing.
    podman build -t "localhost/$name:latest" -f "$containerfile" .
    if [ "$PUSH" = 1 ]; then
        podman tag "localhost/$name:latest" "$ref"
        podman push "$ref" || echo "== push failed; continuing with local image"
    fi
}

ensure_base desktop-container-base Containerfile.base image/rocky9.repo
ensure_base cdi-device-plugin-base Containerfile.plugin.base \
    cdi-device-plugin/go.mod cdi-device-plugin/go.sum
ensure_base screenshot-base Containerfile.screenshot.base \
    screenshot/go.mod screenshot/go.sum
