# llama-swap spark variant: adds XHToken/llama.cpp llama-server as
# /app/llama-server-spark alongside the stock llama-server, for the
# spark2_5 architecture (Spark-X2.5) which mainline llama.cpp cannot load.
#
# Built via docker/build-spark.sh on the same daily cadence as
# containers.yml, producing e.g.:
#   ghcr.io/flyzstu/llama-swap:cuda-spark
#   ghcr.io/flyzstu/llama-swap:cuda-spark-non-root
#
# Build args:
#   BASE                 base llama-swap image (just-built :cuda/:cuda13)
#   CUDA_BUILDER_IMAGE   CUDA devel image matching the base's CUDA major
#   SPARK_COMMIT         XHToken/llama.cpp full commit hash (pinned, no tags exist)
#   UID/GID              ownership for the copied binary (matches base variant)

ARG BASE=ghcr.io/flyzstu/llama-swap:cuda
ARG CUDA_BUILDER_IMAGE=nvidia/cuda:12.9.1-devel-ubuntu24.04

FROM ${CUDA_BUILDER_IMAGE} AS spark-builder

ARG SPARK_COMMIT=4a3635c32fc9f044c2bde9ebeabf50c7e1ec5991
# CUDA 12 keeps the legacy arch list. CUDA 13 dropped compute_60/61,
# so it needs the newer list (overridden per-arch by build-spark.sh).
ARG CMAKE_CUDA_ARCHITECTURES="60;61;75;86;89"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

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

FROM ${BASE}

ARG UID=10001
ARG GID=10001

COPY --from=spark-builder --chown=${UID}:${GID} /src/llama-spark/build/bin/llama-server /app/llama-server-spark

RUN test -x /app/llama-server-spark
