# Quick local overlay: combine llama-server-spark and llama-server-turbo
# by copying /app/llama-server-turbo from an existing turbo image into a spark image.
#
# Usage:
#   docker build -f docker/llama-swap-overlay.Containerfile -t llama-swap:cuda13-combo .
#   docker build --build-arg SPARK_BASE=ghcr.io/flyzstu/llama-swap:cuda-spark \
#                --build-arg TURBO_BASE=ghcr.io/flyzstu/llama-swap:cuda-turbo \
#                -f docker/llama-swap-overlay.Containerfile -t llama-swap:cuda-combo .

ARG SPARK_BASE=ghcr.io/flyzstu/llama-swap:cuda13-spark
ARG TURBO_BASE=ghcr.io/flyzstu/llama-swap:cuda13-turbo

FROM ${TURBO_BASE} AS turbo-source
FROM ${SPARK_BASE}

ARG UID=10001
ARG GID=10001

COPY --from=turbo-source --chown=${UID}:${GID} /app/llama-server-turbo /app/llama-server-turbo

RUN test -x /app/llama-server-spark && test -x /app/llama-server-turbo
