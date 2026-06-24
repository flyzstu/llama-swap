#!/bin/bash
#
# Build the unified CUDA images on a local x86-64 machine.
#
# Usage:
#   ./build-local.sh
#   ./build-local.sh --no-cache
#   ./build-local.sh --push
#   ./build-local.sh --image ghcr.io/example/llama-swap
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_REPO="ghcr.io/flyzstu/llama-swap"
BUILDER_NAME="${BUILDX_BUILDER:-llama-swap-local}"
CUDA_ARCHITECTURES="${CMAKE_CUDA_ARCHITECTURES:-60;61;75;86;89}"
NO_CACHE=false
PUSH=false

usage() {
    cat <<EOF
Usage: ./build-local.sh [options]

Options:
  --image <repository>  Image repository (default: ${IMAGE_REPO})
  --builder <name>      Persistent Buildx builder (default: ${BUILDER_NAME})
  --cuda-architectures <list>
                        CMake CUDA architectures (default: ${CUDA_ARCHITECTURES})
  --no-cache            Rebuild without Docker layer cache
  --push                Push rolling and immutable tags after building
  --help, -h            Show this help message

Optional source overrides:
  LLAMA_REF, WHISPER_REF, SD_REF, IK_LLAMA_REF, LS_VERSION
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --image requires a repository" >&2
                exit 1
            }
            IMAGE_REPO="$2"
            shift 2
            ;;
        --builder)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --builder requires a name" >&2
                exit 1
            }
            BUILDER_NAME="$2"
            shift 2
            ;;
        --cuda-architectures)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --cuda-architectures requires a semicolon-separated list" >&2
                exit 1
            }
            CUDA_ARCHITECTURES="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for command in docker git curl jq sha256sum; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: ${command}" >&2
        exit 1
    }
done

docker info >/dev/null 2>&1 || {
    echo "ERROR: Cannot connect to Docker. Start Docker and ensure this user can access its socket." >&2
    exit 1
}

docker buildx version >/dev/null 2>&1 || {
    echo "ERROR: Docker Buildx is required." >&2
    exit 1
}

architecture=$(uname -m)
if [[ "${architecture}" != "x86_64" && "${architecture}" != "amd64" ]]; then
    echo "ERROR: The CUDA image currently supports x86-64 hosts only (found ${architecture})." >&2
    exit 1
fi

available_gb=$(df -Pk "${SCRIPT_DIR}" | awk 'NR == 2 {print int($4 / 1024 / 1024)}')
memory_gb=$(awk '/MemTotal/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
if (( available_gb < 40 )); then
    echo "ERROR: At least 40 GiB of free disk space is required; found ${available_gb} GiB." >&2
    exit 1
fi
if (( memory_gb < 16 )); then
    echo "WARNING: ${memory_gb} GiB RAM detected; the build may run out of memory." >&2
fi

if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    docker buildx create \
        --name "${BUILDER_NAME}" \
        --driver docker-container
fi
docker buildx inspect "${BUILDER_NAME}" --bootstrap >/dev/null

echo "Local build environment:"
echo "  CPUs:       $(nproc)"
echo "  Memory:     ${memory_gb} GiB"
echo "  Free disk:  ${available_gb} GiB"
echo "  Builder:    ${BUILDER_NAME}"
echo "  Repository: ${IMAGE_REPO}"
echo "  CUDA arch:  ${CUDA_ARCHITECTURES}"

output_file=$(mktemp)
trap 'rm -f "${output_file}"' EXIT

GITHUB_OUTPUT="${output_file}" "${SCRIPT_DIR}/build-image.sh" --cuda --resolve-only
# shellcheck disable=SC1090
source "${output_file}"

build_args=(--cuda)
if [[ "${NO_CACHE}" == true ]]; then
    build_args+=(--no-cache)
fi

export BUILDX_BUILDER="${BUILDER_NAME}"
export DOCKER_IMAGE_TAG="${IMAGE_REPO}:unified-cuda"
export LLAMA_REF="${llama_ref}"
export WHISPER_REF="${whisper_ref}"
export SD_REF="${sd_ref}"
export IK_LLAMA_REF="${ik_llama_ref}"
export LS_VERSION="${llama_swap_version}"
export CMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}"

"${SCRIPT_DIR}/build-image.sh" "${build_args[@]}"

version_tag="${IMAGE_REPO}:unified-cuda-${version_id}"
rootless_tag="${IMAGE_REPO}:unified-cuda-rootless"
rootless_version_tag="${version_tag}-rootless"

docker tag "${DOCKER_IMAGE_TAG}" "${version_tag}"
docker tag "${rootless_tag}" "${rootless_version_tag}"

echo "Built images:"
echo "  ${DOCKER_IMAGE_TAG}"
echo "  ${version_tag}"
echo "  ${rootless_tag}"
echo "  ${rootless_version_tag}"

if [[ "${PUSH}" == true ]]; then
    docker push "${DOCKER_IMAGE_TAG}"
    docker push "${version_tag}"
    docker push "${rootless_tag}"
    docker push "${rootless_version_tag}"
fi
