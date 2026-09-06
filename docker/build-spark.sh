#!/bin/bash
# Build the -spark variant: stock llama-swap image plus XHToken/llama.cpp
# llama-server (spark2_5 architecture, e.g. Spark-X2.5) as
# /app/llama-server-spark. The stock llama-server is untouched, so existing
# models keep working; point a model's cmd at /app/llama-server-spark to
# use the spark backend.
#
# Usage:
#   GITHUB_TOKEN=... ./docker/build-spark.sh cuda [push]
#   GITHUB_TOKEN=... ./docker/build-spark.sh cuda13 true
#   SPARK_COMMIT=<full-sha> ./docker/build-spark.sh cuda true
#
# XHToken publishes no prebuilt containers and no tags, so the source commit
# is pinned via SPARK_COMMIT (full 40-char SHA) and the short hash is baked
# into the image tag for traceability, e.g.:
#   ghcr.io/flyzstu/llama-swap:v253-cuda-b10818-spark-4a3635c32fc9

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

# Pinned XHToken/llama.cpp commit (master, 2026-09-04). Override with the
# SPARK_COMMIT env var or the spark_commit workflow_dispatch input.
SPARK_COMMIT=${SPARK_COMMIT:-4a3635c32fc9f044c2bde9ebeabf50c7e1ec5991}
SPARK_SHORT=${SPARK_COMMIT:0:12}

if [[ ! "$SPARK_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  log_info "Error: SPARK_COMMIT must be a full 40-char SHA (got '${SPARK_COMMIT}')."
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
log_info "SPARK_COMMIT: $SPARK_COMMIT"

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
  SPARK_TAG="ghcr.io/${LS_REPO}:v${LS_VER}-${ARCH}-${LCPP_TAG}-spark-${SPARK_SHORT}${SUFFIX}"
  SPARK_LATEST="ghcr.io/${LS_REPO}:${ARCH}-spark${SUFFIX}"

  # Prefer the base built in this workflow run; fall back to the last daily
  # image (e.g. local smoke builds where nothing was pushed).
  BASE="$VERSIONED_BASE"
  if ! docker manifest inspect "$BASE" >/dev/null 2>&1; then
    log_info "Versioned base $BASE not found, falling back to $LATEST_BASE"
    BASE="$LATEST_BASE"
  fi

  log_info "Pulling base $BASE"
  docker pull "$BASE"

  log_info "Building $CONTAINER_TYPE $SPARK_TAG (base: $BASE)"
  docker build \
    -f llama-swap-spark.Containerfile \
    --build-arg BASE="${BASE}" \
    --build-arg CUDA_BUILDER_IMAGE="${CUDA_BUILDER_IMAGE}" \
    --build-arg SPARK_COMMIT="${SPARK_COMMIT}" \
    --build-arg CMAKE_CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES}" \
    --build-arg UID=${USER_UID} \
    --build-arg GID=${USER_GID} \
    -t "${SPARK_TAG}" -t "${SPARK_LATEST}" .

  if [ "$PUSH_IMAGES" == "true" ]; then
    docker push "${SPARK_TAG}"
    docker push "${SPARK_LATEST}"
  fi
done
