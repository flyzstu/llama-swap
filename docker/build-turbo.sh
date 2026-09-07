#!/bin/bash
# Build the -turbo variant: stock llama-swap image plus
# TheTom/llama-cpp-turboquant llama-server (TurboQuant KV-cache
# compression + MTP speculative decoding) as /app/llama-server-turbo.
# The stock llama-server is untouched, so existing models keep working;
# point a model's cmd at /app/llama-server-turbo to use it.
#
# Usage:
#   GITHUB_TOKEN=... ./docker/build-turbo.sh cuda [push]
#   GITHUB_TOKEN=... ./docker/build-turbo.sh cuda13 true
#   TURBO_COMMIT=<full-sha> ./docker/build-turbo.sh cuda true
#
# TheTom publishes no stable tags for the feature branch, so the source
# commit is pinned via TURBO_COMMIT (full 40-char SHA) and the short hash
# is baked into the image tag for traceability, e.g.:
#   ghcr.io/flyzstu/llama-swap:v253-cuda-b10818-turbo-407f3237bfb3

set -euo pipefail

cd $(dirname "$0")

log_info() {
    echo "[INFO] $*"
}

ARCH=$1
PUSH_IMAGES=${2:-false}

ALLOWED_ARCHS=("cuda" "cuda13")

if [[ ! " ${ALLOWED_ARCHS[@]} " =~ " ${ARCH} " ]]; then
  log_info "Error: ARCH must be one of the following: ${ALLOWED_ARCHS[@]}"
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  log_info "Error: GITHUB_TOKEN is not set or is empty."
  exit 1
fi

# Pinned TheTom/llama-cpp-turboquant commit
# (feature/turboquant-kv-cache, 2026-09-06). Override with the
# TURBO_COMMIT env var or the turbo_commit workflow_dispatch input.
TURBO_COMMIT=${TURBO_COMMIT:-407f3237bfb3eeaff61546797de3d8c1a96be748}
TURBO_SHORT=${TURBO_COMMIT:0:12}

if [[ ! "$TURBO_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  log_info "Error: TURBO_COMMIT must be a full 40-char SHA (got '${TURBO_COMMIT}')."
  exit 1
fi

# Builder image must match the base image's CUDA major version.
# CUDA 13 dropped compute_60/61, so cuda13 needs the newer arch list.
case "$ARCH" in
  cuda)
    CUDA_BUILDER_IMAGE=${CUDA_BUILDER_IMAGE:-nvidia/cuda:12.9.1-devel-ubuntu24.04}
    CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES:-"60;61;75;86;89"}
    ;;
  cuda13)
    CUDA_BUILDER_IMAGE=${CUDA_BUILDER_IMAGE:-nvidia/cuda:13.0.2-devel-ubuntu24.04}
    CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES:-"75;80;86;89;90;100;110;120"}
    ;;
esac

LS_REPO=${GITHUB_REPOSITORY:-mostlygeek/llama-swap}
LS_BINARY_REPO=${LS_BINARY_REPO:-mostlygeek/llama-swap}

LS_VER=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/${LS_BINARY_REPO}/releases/latest" \
    | jq -r .tag_name | sed 's/v//')

if [[ -z "$LS_VER" || "$LS_VER" == "null" ]]; then
    log_info "Error: could not resolve latest llama-swap release tag from ${LS_BINARY_REPO}"
    exit 1
fi

# Fetches the most recent llama.cpp tag matching the given prefix.
fetch_llama_tag() {
    local tag_prefix=$1
    local page=1
    local per_page=100

    while true; do
        local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/users/ggml-org/packages/container/llama.cpp/versions?per_page=${per_page}&page=${page}")

        if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
            local error_msg=$(echo "$response" | jq -r '.message')
            log_info "GitHub API error: $error_msg"
            return 1
        fi

        if [ "$(echo "$response" | jq 'length')" -eq 0 ]; then
            return 1
        fi

        local found_tag=$(echo "$response" | jq -r \
            ".[] | select(.metadata.container.tags[]? | startswith(\"$tag_prefix\")) | .metadata.container.tags[] | select(startswith(\"$tag_prefix\"))" \
            | sort -r | head -n1)

        if [ -n "$found_tag" ]; then
            echo "$found_tag" | awk -F '-' '{print $NF}'
            return 0
        fi

        page=$((page + 1))

        if [ $page -gt 50 ]; then
            log_info "Reached pagination safety limit (50 pages)"
            return 1
        fi
    done
}

LCPP_TAG=$(fetch_llama_tag "server-${ARCH}")

if [[ -z "$LCPP_TAG" ]]; then
    log_info "Abort: Could not find llama-server container for arch: $ARCH"
    exit 1
else
    log_info "LCPP_TAG: $LCPP_TAG"
fi
log_info "LS_VER: $LS_VER"
log_info "TURBO_COMMIT: $TURBO_COMMIT"

for CONTAINER_TYPE in non-root root; do
  SUFFIX=""
  USER_UID=0
  USER_GID=0

  if [ "$CONTAINER_TYPE" == "non-root" ]; then
    SUFFIX="-non-root"
    USER_UID=10001
    USER_GID=10001
  fi

  VERSIONED_BASE="ghcr.io/${LS_REPO}:v${LS_VER}-${ARCH}-${LCPP_TAG}${SUFFIX}"
  LATEST_BASE="ghcr.io/${LS_REPO}:${ARCH}${SUFFIX}"
  TURBO_TAG="ghcr.io/${LS_REPO}:v${LS_VER}-${ARCH}-${LCPP_TAG}-turbo-${TURBO_SHORT}${SUFFIX}"
  TURBO_LATEST="ghcr.io/${LS_REPO}:${ARCH}-turbo${SUFFIX}"

  # Prefer the base built in this workflow run; fall back to the last daily
  # image (e.g. local smoke builds where nothing was pushed).
  BASE="$VERSIONED_BASE"
  if ! docker manifest inspect "$BASE" >/dev/null 2>&1; then
    log_info "Versioned base $BASE not found, falling back to $LATEST_BASE"
    BASE="$LATEST_BASE"
  fi

  log_info "Pulling base $BASE"
  docker pull "$BASE"

  log_info "Building $CONTAINER_TYPE $TURBO_TAG (base: $BASE)"
  docker build \
    -f llama-swap-turbo.Containerfile \
    --build-arg BASE="${BASE}" \
    --build-arg CUDA_BUILDER_IMAGE="${CUDA_BUILDER_IMAGE}" \
    --build-arg TURBO_COMMIT="${TURBO_COMMIT}" \
    --build-arg CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}" \
    --build-arg UID=${USER_UID} \
    --build-arg GID=${USER_GID} \
    -t "${TURBO_TAG}" -t "${TURBO_LATEST}" .

  if [ "$PUSH_IMAGES" == "true" ]; then
    docker push "${TURBO_TAG}"
    docker push "${TURBO_LATEST}"
  fi
done
