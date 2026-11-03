# Makefile for bare-metal PicoRV32 C programs
#
# This file expects a C program "src/main.c" provided by the user
# plus an assembly language startup program "src/start.c"

# Give the user some easy overrides for local configuration quirks.
# If you change one of these and it breaks, then you get to keep both pieces.
SHELL = bash
PYTHON = python3

# Start wih no optimisation - better for understanding the code
OPTIMISATION = 0

SOFTWARE_OBJS = build/bootloader.o build/start_rv32e.o
HEADER_FILES = src/uart.h src/config.h
ASM_HEADER_FILES =
GCC_WARNS  = -Werror -Wall -Wextra -Wshadow -Wundef -Wpointer-arith -Wcast-qual -Wcast-align -Wwrite-strings
GCC_WARNS += -Wredundant-decls -Wstrict-prototypes # -Wconversion
# TOOLCHAIN_PREFIX = /opt/riscv32i/bin/riscv32-unknown-elf-
# If toolchain is in PATH:
TOOLCHAIN_PREFIX = riscv64-unknown-elf-

# Define optimisation level here
# Start wih no optimisation - better for understanding the code
# OPT = -O0
OPT = -O3 -Os -mpreferred-stack-boundary=3

# debug/stack usage stuff
OPT += -fstack-usage -fdump-rtl-dfinish -fdump-rtl-expand -Wl,--print-memory-usage -Wstack-usage=8

# this controls the instruction set supported by the PicoRV32
# the possible options are:
#
#   rv32i       Integer
#   rv32im      Integer + Hardware multiply and divide
#   rv32ic      Integer + Compressed instruction set
#   rv32imc     Integer + Hardware multiply and divide + Compressed instruction set
#
# (note that the parameters of the PicoRV32 core need to be
#  changed in order to support anything other than rv32i)
#
# RVABI = ilp32
# RVARCH = rv32im
RVABI = ilp32e
RVARCH = rv32emc


#
# makefile rules
#

all: $(SOFTWARE_OBJS) out/bootloader.elf out/bootloader.lst out/bootloader.bin out/bootloader.hex out/bootloader.vmem out/debug.elf # out/stack_usage.pdf

out/bootloader.elf: $(SOFTWARE_OBJS) $(HEADER_FILES) soc.ld
	mkdir -p out
	$(TOOLCHAIN_PREFIX)gcc $(OPT) -mabi=$(RVABI) -march=$(RVARCH) -ffreestanding -nostdlib -o $@ \
		-Wl,--build-id=none,-Bstatic,-T,soc.ld,-Map,out/bootloader.map,--strip-debug \
		$(SOFTWARE_OBJS) -lgcc
	chmod -x $@

out/debug.elf: $(SOFTWARE_OBJS) soc.ld
	mkdir -p out
	$(TOOLCHAIN_PREFIX)gcc $(OPT) -mabi=$(RVABI) -march=$(RVARCH) -ffreestanding -nostdlib -o $@ \
		-Wl,--build-id=none,-Bstatic,-T,soc.ld,-Map,out/debug.map -ggdb \
		$(SOFTWARE_OBJS) -lgcc
	chmod -x $@

out/stack_usage.pdf: out/bootloader.elf
# 	$(TOOLCHAIN_PREFIX)objdump -d code.elf | ./checkstack.pl riscv 0 > "code.stacksizes"
# 	./stacklyze.sh code/*.dfinish -p stack -U1 -D1 -T0 > "code.digraph"
	../stacklyze.sh build/*.dfinish -U1 -D1 -T0 > out/stack_usage.digraph
	../stacklyze.sh build/*.dfinish -p out/stack -U1 | tee out/stack_usage.rpt
	dot -Tpdf out/stack_usage.digraph -o out/stack_usage.pdf

build/%.o: src/%.c $(HEADER_FILES)
	mkdir -p build
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=$(RVABI) -march=$(RVARCH) $(OPT) $(CFLAGS) --std=c99 $(GCC_WARNS) -ffreestanding -nostdlib -o $@ $<

# Uppercase S gets run through the c-preprocessor
build/%.o: src/%.S $(ASM_HEADER_FILES)
	mkdir -p build
	$(TOOLCHAIN_PREFIX)gcc -c -mabi=$(RVABI) -march=$(RVARCH) $(OPT) --std=c99 $(GCC_WARNS) -ffreestanding -nostdlib -o $@ $<
# 	$(TOOLCHAIN_PREFIX)objdump -d $@ > $@.lst
# 	$(TOOLCHAIN_PREFIX)objdump -h $@ > $@.sec
# 	$(TOOLCHAIN_PREFIX)gcc -S $< > $@.pp

%.s: %.c
	$(TOOLCHAIN_PREFIX)gcc -S -c -mabi=$(RVABI) -march=$(RVARCH) $(OPT) $(CFLAGS) --std=c99 $(GCC_WARNS) -ffreestanding -nostdlib -o $@ $<

%.ihex: %.elf
	$(TOOLCHAIN_PREFIX)objcopy -O ihex $< $@

%.bin: %.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@

%.lst: %.elf
	$(TOOLCHAIN_PREFIX)objdump -d $< > $@


# convert the binary file to a 4 byte per line format for $readmemh
%.hex: %.bin
	$(PYTHON) ../../../scripts/bin_to_hex.py $< $@ 4

# convert the binary file to a verilog style memory assignment
# note that the .hex file is always updated when a new .vmem file is created
%.vmem: %.bin %.hex
	$(PYTHON) ../../../scripts/bin_to_hex.py $< $@ 4 vmem


clean:
	rm -vrf build out
