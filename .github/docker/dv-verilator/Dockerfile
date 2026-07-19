# Slim image providing just a prebuilt Verilator (pinned via the
# VERILATOR_VERSION build-arg, sourced from .github/verilator-version by
# publish-dv-image.yml) plus the g++/make/perl toolchain Verilator itself
# needs at runtime to compile the C++ it generates for each simulated
# target, and git (needed by `fusesoc library add` to clone library repos,
# not just for actions/checkout). This is *not* a replacement for
# hpretl/iic-osic-tools - it only exists to avoid rebuilding Verilator from
# source on every CI run, so it deliberately doesn't include the rest of
# that toolchain (OpenROAD, Magic, KLayout, PDKs, ...).
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
# python3.12/python3.12-venv/python3-pip: baked in directly rather than
# relying on actions/setup-python's hermetic prebuilt Python. Pinned to
# python3.12 explicitly (not the generic python3 metapackage) so this stays
# the exact version this repo pins everywhere else even if a future Ubuntu
# 24.04 point release ever changed which interpreter "python3" defaults to.
# python3-pip isn't version-suffixed in Debian/Ubuntu packaging (it's pure
# Python, tied to whichever interpreter invokes it, not packaged per-minor-
# version like the interpreter/venv module are).
# zlib1g-dev (not just zlib1g): every target in this repo runs with
# --trace-fst, and Verilator's FST writer links against zlib for its gzip
# compression layer - the testbench C++ is compiled/linked inside this
# container by `fusesoc run`, so it needs zlib.h and the unversioned
# libz.so (for -lz), not just the runtime .so.1 that zlib1g alone provides.
RUN apt-get update && apt-get install -y --no-install-recommends \
      g++ make perl zlib1g-dev libfl2 ca-certificates lsb-release git \
      python3.12 python3.12-venv python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3
COPY --from=builder /opt/verilator /opt/verilator
ENV PATH="/opt/verilator/bin:${PATH}"

RUN verilator --version && python3.12 --version && python3 --version && pip3 --version
