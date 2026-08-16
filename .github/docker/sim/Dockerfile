# Slim image providing a prebuilt Verilator (pinned via the VERILATOR_VERSION
# build-arg, sourced from .github/verilator-version), a bare-metal RISC-V GCC
# (pinned via RISCV_TOOLCHAIN_VERSION, sourced from
# .github/riscv-toolchain-version) and Python 3.12, for use in RTL simulation
# workflows.
#
# The image tag combines BOTH pins - see .github/workflows/publish-sim-image.yml.
# Bump either version file to publish a new image; sim-ci.yml composes the same
# tag, so it picks the new one up automatically.
ARG VERILATOR_VERSION=v5.048
ARG RISCV_TOOLCHAIN_VERSION=14.2.0-3

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
ARG RISCV_TOOLCHAIN_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      g++ make perl zlib1g-dev libfl2 ca-certificates lsb-release git \
      curl xz-utils \
      python3.12 python3.12-venv python3.12-dev python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3
COPY --from=builder /opt/verilator /opt/verilator

# Bare-metal RISC-V GCC, needed by sw/scripts/build_fw.sh to build the firmware
# image that ahb_rom loads. Any target with a build_fw pre_build hook - the
# whole grouper_soc_tb / grouper_soc_directed family - cannot run without it.
#
# xPack rather than Ubuntu's gcc-riscv64-unknown-elf: the distro package is
# configured around rv64gc/lp64d and does not ship an rv32e multilib, which is
# exactly what this SoC needs (see the verification step below).
RUN curl -fsSL -o /tmp/riscv.tar.gz \
      "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${RISCV_TOOLCHAIN_VERSION}/xpack-riscv-none-elf-gcc-${RISCV_TOOLCHAIN_VERSION}-linux-x64.tar.gz" \
    && mkdir -p /opt/riscv \
    && tar -xzf /tmp/riscv.tar.gz -C /opt/riscv --strip-components=1 \
    && rm /tmp/riscv.tar.gz

ENV PATH="/opt/verilator/bin:/opt/riscv/bin:${PATH}"

# build_fw.sh defaults CROSS to riscv64-unknown-elf-; the xPack toolchain uses
# the riscv-none-elf- prefix. Setting it here wires the two together without
# every CI target having to pass it.
ENV CROSS="riscv-none-elf-"

RUN verilator --version && python3.12 --version && python3 --version && pip3 --version \
    && riscv-none-elf-gcc --version

# Prove the toolchain can actually build for this CPU, at image build time.
#
# cpu_ss.sv instantiates picorv32 as RV32EMC (ENABLE_REGS_16_31=0,
# COMPRESSED_ISA=1, ENABLE_MUL/ENABLE_DIV), so build_fw.sh compiles
# -march=rv32emc -mabi=ilp32e. A toolchain without that multilib does not fail
# here - it fails much later inside a CI simulation leg, with an obscure
# "Cannot find suitable multilib set for '-march=rv32emc'/'-mabi=ilp32e'".
# Fail loudly now instead, while the version pin is the obvious thing to change.
RUN printf 'int main(void){return 0;}\n' > /tmp/mlcheck.c \
    && riscv-none-elf-gcc -march=rv32emc -mabi=ilp32e -nostdlib -c /tmp/mlcheck.c -o /tmp/mlcheck.o \
    && rm -f /tmp/mlcheck.c /tmp/mlcheck.o
