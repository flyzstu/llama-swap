# llama-swap spark+turbo variant: combines stock llama-server with:
# 1. /app/llama-server-spark (XHToken/llama.cpp for Spark-X2.5 spark2_5 architecture)
# 2. /app/llama-server-turbo (TheTom/llama-cpp-turboquant for TurboQuant KV cache + MTP)
#
# Build args:
#   BASE                     base llama-swap image (just-built :cuda/:cuda13)
#   CUDA_BUILDER_IMAGE       CUDA devel image matching the base's CUDA major
#   SPARK_COMMIT             XHToken/llama.cpp full commit hash
#   TURBO_COMMIT             TheTom/llama-cpp-turboquant full commit hash
#   CMAKE_CUDA_ARCHITECTURES CUDA compute architectures to target
#   UID/GID                  ownership for copied binaries (matches base variant)

ARG BASE=ghcr.io/flyzstu/llama-swap:cuda
ARG CUDA_BUILDER_IMAGE=nvidia/cuda:12.9.1-devel-ubuntu24.04

# Common build environment to avoid running apt-get update twice
FROM ${CUDA_BUILDER_IMAGE} AS build-env

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Stage 1: Build spark backend
FROM build-env AS spark-builder

ARG SPARK_COMMIT=4a3635c32fc9f044c2bde9ebeabf50c7e1ec5991
ARG CMAKE_CUDA_ARCHITECTURES="60;61;75;86;89"

WORKDIR /src
RUN git init llama-spark \
    && cd llama-spark \
    && git remote add origin https://github.com/XHToken/llama.cpp.git \
    && git fetch --depth=1 origin "${SPARK_COMMIT}" \
    && git checkout FETCH_HEAD

WORKDIR /src/llama-spark
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

# Stage 2: Build turbo backend
FROM build-env AS turbo-builder

ARG TURBO_COMMIT=407f3237bfb3eeaff61546797de3d8c1a96be748
ARG CMAKE_CUDA_ARCHITECTURES="60;61;75;86;89"

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

# Stage 3: Final runtime image
FROM ${BASE}

ARG UID=10001
ARG GID=10001

COPY --from=spark-builder --chown=${UID}:${GID} /src/llama-spark/build/bin/llama-server /app/llama-server-spark
COPY --from=turbo-builder --chown=${UID}:${GID} /src/llama-turbo/build/bin/llama-server /app/llama-server-turbo

RUN test -x /app/llama-server-spark && test -x /app/llama-server-turbo
