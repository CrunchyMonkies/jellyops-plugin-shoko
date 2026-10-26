#!/usr/bin/env bash
#
# Build and push the Shokofin plugin image-volume payload for JellyOps.
#
# The payload is NOT compiled here — it is the prebuilt Shokofin v12 (.NET 10)
# release artifact `shoko_<version>_for_12.y.z.zip` downloaded from the
# ShokoAnime/Shokofin GitHub release, unzipped into the build context's
# `plugin/` dir, and packaged into a `FROM scratch` image whose root IS the
# Jellyfin plugin directory (Shokofin.dll + SignalR client DLLs + meta.json).
#
# The plugin image is built with --provenance=false so it is a single plain
# manifest the kubelet mounts cleanly as an image volume.
#
# Usage:
#   docker/build-push.sh [TAG]
#
# Environment overrides:
#   REGISTRY          image repo prefix   (default: ghcr.io/crunchymonkies/jellyops-plugin-shoko)
#   SHOKOFIN_REPO     release source repo (default: ShokoAnime/Shokofin)
#   SHOKOFIN_TAG      release tag         (default: v6.0.5-dev.40)
#   SHOKOFIN_ASSET    zip glob            (default: shoko_*_for_12.y.z.zip)
#   PUSH              push to registry    (default: true; set PUSH=false to build only)
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/crunchymonkies/jellyops-plugin-shoko}"
# Full image repo. Defaults to <REGISTRY>/plugin; override IMAGE to rename (e.g. to
# publish to Harbor as harbor.bne1.ouchi.com.au/applications/shokofin-plugin).
IMAGE="${IMAGE:-${REGISTRY}/plugin}"
SHOKOFIN_REPO="${SHOKOFIN_REPO:-ShokoAnime/Shokofin}"
SHOKOFIN_TAG="${SHOKOFIN_TAG:-v6.0.5-dev.40}"
SHOKOFIN_ASSET="${SHOKOFIN_ASSET:-shoko_*_for_12.y.z.zip}"
PUSH="${PUSH:-true}"
# Rolling calendar tag; override by passing an explicit TAG argument.
TAG="${1:-$(date +%Y%m).$(date +%d).1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/plugin"

echo ">> Downloading Shokofin release ${SHOKOFIN_TAG} (${SHOKOFIN_ASSET}) from ${SHOKOFIN_REPO}"
gh release download "${SHOKOFIN_TAG}" \
  --repo "${SHOKOFIN_REPO}" \
  --pattern "${SHOKOFIN_ASSET}" \
  --dir "$CTX" --clobber

ZIP="$(find "$CTX" -maxdepth 1 -name '*.zip' | head -1)"
[ -n "$ZIP" ] || { echo "!! No release zip downloaded" >&2; exit 1; }
echo ">> Unpacking $(basename "$ZIP") into build context"
unzip -o -q "$ZIP" -d "$CTX/plugin"

# Bake the jellyops standard hook scripts into the plugin payload. The operator
# auto-runs firstrun.sh (once) and bootstrap.sh (every start) from the staged dir.
cp "$ROOT/scripts/firstrun.sh"  "$CTX/plugin/firstrun.sh"
cp "$ROOT/scripts/bootstrap.sh" "$CTX/plugin/bootstrap.sh"
chmod +x "$CTX/plugin/firstrun.sh" "$CTX/plugin/bootstrap.sh"

# Sanity-check the payload before baking it into an image.
test -f "$CTX/plugin/Shokofin.dll"  || { echo "!! Shokofin.dll missing from payload"  >&2; exit 1; }
test -f "$CTX/plugin/meta.json"     || { echo "!! meta.json missing from payload"     >&2; exit 1; }
test -f "$CTX/plugin/firstrun.sh"   || { echo "!! firstrun.sh missing from payload"   >&2; exit 1; }
test -f "$CTX/plugin/bootstrap.sh"  || { echo "!! bootstrap.sh missing from payload"  >&2; exit 1; }
echo ">> Payload contents:"
( cd "$CTX/plugin" && ls -1 )

# Derive the plugin version from the payload so the tag/labels stay truthful.
PLUGIN_VERSION="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$CTX/plugin/meta.json" | head -1 | grep -oE '[0-9.]+' || true)"
PLUGIN_VERSION="${PLUGIN_VERSION:-unknown}"
echo ">> Plugin version from meta.json: ${PLUGIN_VERSION}"

cp "$ROOT/docker/Dockerfile.plugin" "$CTX/Dockerfile.plugin"

echo ">> Building ${IMAGE} (tags: ${PLUGIN_VERSION}, ${TAG}, latest)"
docker build --provenance=false \
  -f "$CTX/Dockerfile.plugin" \
  -t "${IMAGE}:${PLUGIN_VERSION}" \
  -t "${IMAGE}:${TAG}" \
  -t "${IMAGE}:latest" \
  "$CTX"

if [ "$PUSH" = "true" ]; then
  echo ">> Pushing tags to ${IMAGE}"
  docker push "${IMAGE}:${PLUGIN_VERSION}"
  docker push "${IMAGE}:${TAG}"
  docker push "${IMAGE}:latest"
  # Pick the RepoDigest for THIS image repo (the image content may be shared with
  # other local tags whose digest would otherwise sort first).
  DIGEST="$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE}:${PLUGIN_VERSION}" | grep "^${IMAGE}@" | head -1)"
  echo ""
  echo ">> Pushed. Pin this digest in k8s/30-jellyfinplugin.yaml (spec.pluginImage.reference):"
  echo "     ${DIGEST}"
else
  echo ">> PUSH=false — built locally only, not pushed."
fi
