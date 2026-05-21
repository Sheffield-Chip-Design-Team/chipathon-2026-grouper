# Test Plan

## Strategy

**Primary method:** FPGA-in-the-loop, block-level first, then integration

**Golden reference:** Python simulation in `sim/` (numpy/scipy), plus real SX1257 hardware for loopback

**FPGA platform:** Digilent Arty A7-100T (Artix-7 XC7A100T, 63K LUTs). Vivado for synthesis and P&R. Est. ~30% LUT utilisation for full MIMO path.

**Test data:** Real captured LoRa I/Q samples (CF32 format, 125 kHz BW), sigma-delta modulated to 1-bit at 32 MS/s. Real-world impairments from day one. Existing captures in `sim/`.

## Verification pyramid

| Level | Method | When |
| --- | --- | --- |
| L1 — RTL simulation | iverilog + cocotb, numpy/scipy golden models | Block bring-up — catch bugs before FPGA |
| L2 — FPGA-in-the-loop | Arty A7-100T, synthetic + captured data, SX1257 digital loopback | Primary validation of combined MIMO path |
| L3 — Over-the-air | Two real LoRa nodes at f₀±Δf → SX1257 ×4 → ASIC RTL → SX1302 → ChirpStack | Final system validation |

### Block 8 — SPI Master (→ SX1257)

**Pass criterion:** All SX1257 register writes produce correct SPI transactions (correct chip select, correct opcode/address/data sequence). No bus contention with SPI slave during simultaneous activity.

**Method:**
- Logic analyser / cocotb SPI monitor: capture SPI_MOSI/SCK/CSn during a `RegMode` write
- Verify byte sequence matches SX1257 register write format (§5.1 of SX1257 datasheet)
- Verify MISO tristating while acting as master

---

### Block 9 — PicoRV32 + Firmware

**Pass criterion:** Firmware computes correct W matrix (verified against Python reference) within one LoRa symbol period of correlator lock. AGC converges within 3 packets on a static channel. Mode auto-switch triggers correctly on NT=2 preamble pair. When borrow mode is supported with `CPU_RESET=0`, firmware operates correctly while respecting the reserved upper borrow bank.

**Method:**
- Write H matrix and N₀ to registers; release CPU_RESET; read back W matrix after IRQ
- Compare W to Python `W = (H^H @ H + N0*I)^-1 @ H^H`
- Inject two-node preamble (NT=2); verify ACTIVE_MODE register switches to 1

**Additional matrix:**

| Test | Pass criterion |
| --- | --- |
| Linker reservation | `.text/.data/.bss/stack` are placed only in `BANK0`–`BANK2`; map file shows no allocation in reserved `BANK3` |
| Runtime exclusion | C runtime zero/init path does not clear or write reserved `BANK3` |
| Shared borrow with CPU live | With `CPU_RESET=0` and `CPU_SRAM_BORROW_EN=1`, AGC still runs and borrowed-bank sentinel data is preserved |
---


## Tooling

| Task | Tool |
| --- | --- |
| Golden reference model | Python — `sim/` (numpy, scipy) |
| Sigma-delta modulation | Python script |
| RTL simulation | iverilog + cocotb |
| FPGA bitstream | Vivado (Artix-7 XC7A100T) |
| In-circuit debug | Vivado ILA over USB-JTAG |
| SPI traffic capture | Saleae Logic / sigrok |
| Physical synthesis | Yosys + OpenROAD (GF180MCU) |
| Regression runner | Makefile + cocotb |
