#!/bin/bash
#
# Build script for unified container with version pinning
#
# Usage:
#   ./build-image.sh --cuda                              # Build CUDA image
#   ./build-image.sh --vulkan                            # Build Vulkan image
#   ./build-image.sh --cuda --no-cache                   # Build without cache
#   LLAMA_REF=b1234 ./build-image.sh --vulkan            # Pin llama.cpp to a commit hash
#   LLAMA_REF=v1.2.3 ./build-image.sh --cuda             # Pin llama.cpp to a tag
#   WHISPER_REF=v1.0.0 ./build-image.sh --vulkan         # Pin whisper.cpp to a tag
#   SD_REF=master ./build-image.sh --cuda                # Pin stable-diffusion.cpp to a branch
#   LS_VERSION=v170 ./build-image.sh --cuda              # Override llama-swap version
#   IK_LLAMA_REF=main ./build-image.sh --cuda            # Pin ik_llama.cpp to main branch (CUDA only)
#

set -euo pipefail

BACKEND=""
NO_CACHE=false
RESOLVE_ONLY=false

for arg in "$@"; do
    case $arg in
        --cuda)
            BACKEND="cuda"
            ;;
        --vulkan)
            BACKEND="vulkan"
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --resolve-only)
            RESOLVE_ONLY=true
            ;;
        --help|-h)
            echo "Usage: ./build-image.sh --cuda|--vulkan [--no-cache] [--resolve-only]"
            echo ""
            echo "Options:"
            echo "  --cuda      Build CUDA image (NVIDIA GPUs)"
            echo "  --vulkan    Build Vulkan image (AMD GPUs and compatible hardware)"
            echo "  --no-cache  Force rebuild without using Docker cache"
            echo "  --resolve-only  Resolve source versions without building"
            echo "  --help, -h  Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  DOCKER_IMAGE_TAG     Set custom image tag (default: llama-swap:unified-cuda or llama-swap:unified-vulkan)"
            echo "  LLAMA_REF            Pin llama.cpp to a commit, tag, or branch (default: latest release)"
            echo "  WHISPER_REF          Pin whisper.cpp to a commit, tag, or branch (default: latest release)"
            echo "  SD_REF               Pin stable-diffusion.cpp to a commit, tag, or branch (default: latest release)"
            echo "  IK_LLAMA_REF         Pin ik_llama.cpp to a commit, tag, or branch (CUDA only)"
            echo "  LS_VERSION           Override llama-swap version (default: latest release)"
            exit 0
            ;;
    esac
done

if [[ -z "$BACKEND" ]]; then
    echo "Error: No backend specified. Please use --cuda or --vulkan."
    echo ""
    echo "Usage: ./build-image.sh --cuda|--vulkan [--no-cache]"
    exit 1
fi

DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-llama-swap:unified-${BACKEND}}"

# Git repository URLs
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"
SD_REPO="https://github.com/leejet/stable-diffusion.cpp.git"
LLAMA_SWAP_REPO="https://github.com/mostlygeek/llama-swap.git"
IK_LLAMA_REPO="https://github.com/ikawrakow/ik_llama.cpp.git"

# Return the tag for the latest non-draft, non-prerelease GitHub release.
get_latest_release_tag() {
    local repo="$1"
    local auth_args=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    curl -fsSL "${auth_args[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/releases/latest" |
        jq -er '.tag_name'
}

# Resolve a git ref (commit hash, tag, or branch) to a full commit hash.
# Requires only: git, network access to the remote.
resolve_ref() {
    local repo_url="$1"
    local ref="$2"

    # Full 40-char SHA — use as-is
    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "${ref}"
        return
    fi

    # Try tag then branch (exact match)
    local hash
    hash=$(git ls-remote "${repo_url}" "refs/tags/${ref}" "refs/heads/${ref}" 2>/dev/null | head -1 | cut -f1)
    if [[ -n "${hash}" ]]; then
        echo "${hash}"
        return
    fi

    # Short hash (7+ chars): scan all refs for a SHA with this prefix
    if [[ "${ref}" =~ ^[0-9a-f]{7,}$ ]]; then
        hash=$(git ls-remote "${repo_url}" 2>/dev/null | grep "^${ref}" | head -1 | cut -f1)
        if [[ -n "${hash}" ]]; then
            echo "${hash}"
            return
        fi
    fi

    echo "ERROR: Could not resolve ref '${ref}' for ${repo_url}" >&2
    if [[ "${ref}" =~ ^[0-9a-f]+$ && ${#ref} -lt 7 ]]; then
        echo "  Short hashes must be at least 7 characters (got ${#ref})." >&2
    else
        echo "  Tried: tag, branch, git ls-remote prefix match" >&2
    fi
    echo "  Use a full 40-char SHA, a tag name, a branch name, or a 7+ char short hash." >&2
    return 1
}

resolve_stable_release() {
    local repo_slug="$1"
    local repo_url="$2"
    local requested_ref="$3"
    local resolved_ref="${requested_ref}"

    if [[ "${resolved_ref}" == "latest" ]]; then
        resolved_ref=$(get_latest_release_tag "${repo_slug}") || return 1
    fi

    local hash
    hash=$(resolve_ref "${repo_url}" "${resolved_ref}") || return 1
    printf '%s %s\n' "${resolved_ref}" "${hash}"
}

echo "=========================================="
echo "llama-swap Unified Build (${BACKEND})"
echo "=========================================="
echo ""

# Resolve stable releases by default. Explicit refs still allow local and
# manually dispatched builds to pin a branch, tag, or commit.
resolved=$(resolve_stable_release "ggml-org/llama.cpp" "${LLAMA_REPO}" "${LLAMA_REF:-latest}")
read -r LLAMA_VERSION LLAMA_HASH <<<"${resolved}"
echo "llama.cpp: ${LLAMA_VERSION} -> ${LLAMA_HASH}"

resolved=$(resolve_stable_release "ggml-org/whisper.cpp" "${WHISPER_REPO}" "${WHISPER_REF:-latest}")
read -r WHISPER_VERSION WHISPER_HASH <<<"${resolved}"
echo "whisper.cpp: ${WHISPER_VERSION} -> ${WHISPER_HASH}"

resolved=$(resolve_stable_release "leejet/stable-diffusion.cpp" "${SD_REPO}" "${SD_REF:-latest}")
read -r SD_VERSION SD_HASH <<<"${resolved}"
echo "stable-diffusion.cpp: ${SD_VERSION} -> ${SD_HASH}"

# Resolve ik_llama.cpp ref (CUDA only)
if [[ "$BACKEND" == "cuda" ]]; then
    IK_LLAMA_VERSION="${IK_LLAMA_REF:-main}"
    IK_LLAMA_HASH=$(resolve_ref "${IK_LLAMA_REPO}" "${IK_LLAMA_VERSION}") || exit 1
    echo "ik_llama.cpp: ${IK_LLAMA_VERSION} -> ${IK_LLAMA_HASH}"
else
    IK_LLAMA_VERSION="n/a"
    IK_LLAMA_HASH="n/a"
    echo "ik_llama.cpp: skipped (vulkan build)"
fi

resolved=$(resolve_stable_release "mostlygeek/llama-swap" "${LLAMA_SWAP_REPO}" "${LS_VERSION:-latest}")
read -r LS_RELEASE LS_HASH <<<"${resolved}"
echo "llama-swap: ${LS_RELEASE} -> ${LS_HASH}"

VERSION_ID=$(
    printf '%s\n' \
        "${BACKEND}" \
        "${LLAMA_HASH}" \
        "${WHISPER_HASH}" \
        "${SD_HASH}" \
        "${IK_LLAMA_HASH}" \
        "${LS_HASH}" |
        sha256sum |
        cut -c1-16
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version_id=${VERSION_ID}"
        echo "llama_ref=${LLAMA_HASH}"
        echo "whisper_ref=${WHISPER_HASH}"
        echo "sd_ref=${SD_HASH}"
        echo "ik_llama_ref=${IK_LLAMA_HASH}"
        echo "llama_swap_version=${LS_RELEASE}"
    } >>"${GITHUB_OUTPUT}"
fi

if [[ "${RESOLVE_ONLY}" == true ]]; then
    echo "version ID: ${VERSION_ID}"
    exit 0
fi

echo ""
echo "=========================================="
echo "Starting Docker build..."
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_ARGS=(
    --build-arg "BACKEND=${BACKEND}"
    --build-arg "LLAMA_COMMIT_HASH=${LLAMA_HASH}"
    --build-arg "WHISPER_COMMIT_HASH=${WHISPER_HASH}"
    --build-arg "SD_COMMIT_HASH=${SD_HASH}"
    --build-arg "IK_LLAMA_COMMIT_HASH=${IK_LLAMA_HASH}"
    --build-arg "LS_VERSION=${LS_RELEASE}"
    -t "${DOCKER_IMAGE_TAG}"
    -f "${SCRIPT_DIR}/Dockerfile"
)

if [[ "$NO_CACHE" == true ]]; then
    BUILD_ARGS+=(--no-cache)
    echo "Note: Building without cache"
elif [[ "${GITHUB_ACTIONS:-}" == "true" && "${ACT:-}" != "true" ]]; then
    CACHE_REF="ghcr.io/flyzstu/llama-swap:unified-${BACKEND}-cache"
    BUILD_ARGS+=(
        --cache-from "type=registry,ref=${CACHE_REF}"
        --cache-to "type=registry,ref=${CACHE_REF},mode=max"
    )
    echo "Note: Using registry cache (${CACHE_REF})"
fi

DOCKER_BUILDKIT=1 docker buildx build --load "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"

echo ""
echo "=========================================="
echo "Verifying build artifacts..."
echo "=========================================="
echo ""

EXPECTED_BINARIES=(llama-server llama-cli whisper-server whisper-cli sd-server sd-cli llama-swap)
if [[ "$BACKEND" == "cuda" ]]; then
    EXPECTED_BINARIES+=(ik-llama-server)
fi

MISSING_BINARIES=()
for binary in "${EXPECTED_BINARIES[@]}"; do
    if ! docker run --rm --entrypoint which "${DOCKER_IMAGE_TAG}" "${binary}" >/dev/null 2>&1; then
        MISSING_BINARIES+=("${binary}")
    fi
done

if [[ ${#MISSING_BINARIES[@]} -gt 0 ]]; then
    echo "ERROR: Build succeeded but the following binaries are missing:"
    for binary in "${MISSING_BINARIES[@]}"; do
        echo "  - ${binary}"
    done
    echo ""
    echo "Try running with --no-cache flag:"
    echo "  ./build-image.sh --${BACKEND} --no-cache"
    exit 1
fi

VERIFIED_LIST="llama-server, llama-cli, whisper-server, whisper-cli, sd-server, sd-cli, llama-swap"
if [[ "$BACKEND" == "cuda" ]]; then
    VERIFIED_LIST="${VERIFIED_LIST}, ik-llama-server"
fi
echo "All expected binaries verified: ${VERIFIED_LIST}"

echo ""
echo "=========================================="
echo "Building rootless image..."
echo "=========================================="
echo ""

ROOTLESS_TAG="${DOCKER_IMAGE_TAG}-rootless"
docker buildx build --load -t "${ROOTLESS_TAG}" - <<EOF
FROM ${DOCKER_IMAGE_TAG}
USER root
RUN groupadd --system --gid 10001 llama-swap && \\
    useradd --system --uid 10001 --gid 10001 \\
      --home /app --shell /sbin/nologin llama-swap && \\
    chown -R 10001:10001 /etc/llama-swap /models
USER 10001
EOF

echo "Rootless image built: ${ROOTLESS_TAG}"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Image tags:"
echo "  ${DOCKER_IMAGE_TAG}"
echo "  ${ROOTLESS_TAG}"
echo ""
echo "Built with:"
echo "  llama.cpp:            ${LLAMA_HASH}"
echo "  whisper.cpp:          ${WHISPER_HASH}"
echo "  stable-diffusion.cpp: ${SD_HASH}"
if [[ "$BACKEND" == "cuda" ]]; then
    echo "  ik_llama.cpp:         ${IK_LLAMA_HASH}"
fi
echo "  llama-swap:           $(docker run --rm --entrypoint cat "${DOCKER_IMAGE_TAG}" /versions.txt | grep llama-swap | cut -d' ' -f2-)"
echo ""
if [[ "$BACKEND" == "vulkan" ]]; then
    echo "Run with:"
    echo "  docker run -it --rm --device /dev/dri:/dev/dri ${DOCKER_IMAGE_TAG}"
    echo ""
    echo "Note: For AMD GPUs, you may also need:"
    echo "  docker run -it --rm --device /dev/dri:/dev/dri --group-add video ${DOCKER_IMAGE_TAG}"
else
    echo "Run with:"
    echo "  docker run -it --rm --gpus all ${DOCKER_IMAGE_TAG}"
fi
