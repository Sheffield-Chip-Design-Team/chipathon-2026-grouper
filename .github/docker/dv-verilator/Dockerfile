# Slim image providing just a prebuilt Verilator (pinned via the
# VERILATOR_VERSION build-arg, sourced from .github/verilator-version by
# publish-dv-image.yml) plus the g++/make/perl toolchain Verilator itself
# needs at runtime to compile the C++ it generates for each simulated
# target. This is *not* a replacement for hpretl/iic-osic-tools - it only
# exists to avoid rebuilding Verilator from source on every CI run, so it
# deliberately doesn't include the rest of that toolchain (OpenROAD, Magic,
# KLayout, PDKs, ...).
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
# lsb-release: not needed by Verilator itself, but actions/setup-python
# (run inside this image as the sim job's container) shells out to
# `lsb_release` to detect the distro when picking a Python build, and fails
# hard if it's missing - confirmed via a real CI run.
RUN apt-get update && apt-get install -y --no-install-recommends \
      g++ make perl zlib1g libfl2 ca-certificates lsb-release \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/verilator /opt/verilator
ENV PATH="/opt/verilator/bin:${PATH}"

RUN verilator --version
