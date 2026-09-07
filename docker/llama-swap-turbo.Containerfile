# llama-swap turbo variant: adds TheTom/llama-cpp-turboquant
# llama-server as /app/llama-server-turbo alongside the stock
# llama-server, for TurboQuant KV-cache compression plus MTP
# speculative decoding (e.g. 27B on 16GB cards).
#
# Built via docker/build-turbo.sh on the same daily cadence as
# containers.yml, producing e.g.:
#   ghcr.io/flyzstu/llama-swap:cuda-turbo
#   ghcr.io/flyzstu/llama-swap:cuda-turbo-non-root
#
# Build args:
#   BASE                 base llama-swap image (just-built :cuda/:cuda13)
#   CUDA_BUILDER_IMAGE   CUDA devel image matching the base's CUDA major
#   TURBO_COMMIT         TheTom/llama-cpp-turboquant full commit hash (pinned, branch moves fast)
#   UID/GID              ownership for the copied binary (matches base variant)

ARG BASE=ghcr.io/flyzstu/llama-swap:cuda
ARG CUDA_BUILDER_IMAGE=nvidia/cuda:12.9.1-devel-ubuntu24.04

FROM ${CUDA_BUILDER_IMAGE} AS turbo-builder

ARG TURBO_COMMIT=407f3237bfb3eeaff61546797de3d8c1a96be748
# CUDA 12 keeps the legacy arch list. CUDA 13 dropped compute_60/61,
# so it needs the newer list (overridden per-arch by build-turbo.sh).
ARG CMAKE_CUDA_ARCHITECTURES="60;61;75;86;89"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init llama-turbo \
    && cd llama-turbo \
    && git remote add origin https://github.com/TheTom/llama-cpp-turboquant.git \
    && git fetch --depth=1 origin "${TURBO_COMMIT}" \
    && git checkout FETCH_HEAD

WORKDIR /src/llama-turbo
RUN cmake -B build \
        -DGGML_NATIVE=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_TESTS=OFF \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_NCCL=OFF \
        -DGGML_VULKAN=OFF \
        "-DCMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES}" \
        "-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler" \
    && cmake --build build --config Release -j"$(nproc)" --target llama-server \
    && ls -la build/bin/llama-server

FROM ${BASE}

ARG UID=10001
ARG GID=10001

COPY --from=turbo-builder --chown=${UID}:${GID} /src/llama-turbo/build/bin/llama-server /app/llama-server-turbo

RUN test -x /app/llama-server-turbo
