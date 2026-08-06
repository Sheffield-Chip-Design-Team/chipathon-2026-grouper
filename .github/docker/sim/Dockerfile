# Slim image providing just a prebuilt Verilator (pinned via the
# VERILATOR_VERSION build-arg, sourced from .github/verilator-version) and Python 3.12, for use in RTL simulation workflows.
ARG VERILATOR_VERSION=v5.048

FROM ubuntu:24.04 AS builder
ARG VERILATOR_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git help2man perl python3 make autoconf g++ flex bison \
      libfl2 libfl-dev zlib1g zlib1g-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${VERILATOR_VERSION}" \
      https://github.com/verilator/verilator /verilator-src
WORKDIR /verilator-src
RUN autoconf && ./configure --prefix=/opt/verilator \
    && make -j"$(nproc)" \
    && make install

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      g++ make perl zlib1g-dev libfl2 ca-certificates lsb-release git \
      python3.12 python3.12-venv python3.12-dev python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3
COPY --from=builder /opt/verilator /opt/verilator
ENV PATH="/opt/verilator/bin:${PATH}"

RUN verilator --version && python3.12 --version && python3 --version && pip3 --version
