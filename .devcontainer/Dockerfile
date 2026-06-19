FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git \
        libssl-dev libtss2-dev pkg-config procps \
        python3 python3-dev swtpm swtpm-tools \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/0.11.21/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /workspace
