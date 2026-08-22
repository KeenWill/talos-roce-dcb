#!/usr/bin/env bash
# Build (and optionally push) the extension image.
#
#   IMAGE     image reference; defaults to ghcr.io/keenwill/roce-dcb:<manifest version>
#   PUSH      "true" to push instead of loading into the local docker daemon
#   PLATFORM  defaults to linux/amd64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_VERSION="$(awk '/^  version:/ { print $2; exit }' "${SCRIPT_DIR}/manifest.yaml")"
IMAGE="${IMAGE:-ghcr.io/keenwill/roce-dcb:${MANIFEST_VERSION}}"
PUSH="${PUSH:-false}"
PLATFORM="${PLATFORM:-linux/amd64}"

if ! command -v docker >/dev/null 2>&1; then
	echo "error: required command not found: docker" >&2
	exit 1
fi

output_mode="--load"
if [[ "$PUSH" == "true" ]]; then
	output_mode="--push"
fi

# Talos expects a plain single-platform image, so provenance attestations
# (which turn the result into an image index) are disabled.
docker buildx build \
	--platform "$PLATFORM" \
	--provenance=false \
	--tag "$IMAGE" \
	"$output_mode" \
	"$SCRIPT_DIR"

echo "built ${IMAGE}"

if [[ "$PUSH" == "true" ]]; then
	echo
	echo "Use a digest-pinned reference when building Talos images:"
	docker buildx imagetools inspect "$IMAGE" |
		awk -v image="$IMAGE" '/^Digest:[[:space:]]+/ { print "  " image "@" $2 }'
fi
