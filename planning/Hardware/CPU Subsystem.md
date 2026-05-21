# CPU Subsystem

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Not started
---

## Function

PicoRV32 RV32IM soft-core CPU providing optional control-plane and experimental algorithm support. Runs firmware loaded over SPI by the RPi host. Connects to all peripherals via a custom `AHB-Lite` wrapper/interconnect.

Baseline RX packet reception must not depend on this block being operational. If PicoRV32 is held in reset, stalled, or absent from the live control loop, the hardware receive path must still:

- detect packets
- accumulate training data
- compute baseline hardware weights
- control W commit and packet phase
- drive bypass or combined output to the ΣΔ re-modulator

PicoRV32 is therefore a non-critical enhancement block for:

- software weight algorithms such as ALMMSE
- cross-packet EMA smoothing
- AGC policy
- diagnostics and statistics
- TDD TX/RX switching orchestration

**Bus decision.** The project bus is now `AHB-Lite`. PicoRV32 is kept as the CPU, so the master side uses an AHB wrapper.

**Why RV32IM (not RV32I):** MRC weight computation requires computing `S = Σ|H_j|²` and then `w_j = conj(H_j) / S` — a 32-bit integer division plus four complex multiply-accumulates. Hardware MUL/DIV (the M extension) reduces this from ~1000 cycles to ~50 cycles. EGC normalisation uses the same multiply path.

---


## Memory map

| Address | Region | Size | Macro | Notes |
| --- | --- | --- | --- | --- |
| `0x00000` | Unified SRAM (text + data + stack) | 4 KB | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` ×4 | Loaded by host via SPI; `.text` at low addresses, `.data`/`.bss`/stack at high addresses |
| `0x01000` | AHB-Lite peripherals | — | — | Register bank, SPI master, IRQ, JTAG |

A single unified SRAM replaces separate IMEM and DMEM. The linker places `.text` at `0x00000` and `.data`/`.bss`/stack at the top of the 4 KB window. One AHB-Lite port, one BIST instance. This CPU memory uses the experimental `gf180mcu_ocd_ip_sram` library, while the DSP/frontend buffer uses the official GF `gf180mcu_fd_ip_sram` 512x8 macros; see [Memory Strategy](../Memory%20Strategy.md) for the mixed-library rationale and BIST architecture.

---

## CPU SRAM BIST

BIST runs at power-on with `CPU_RESET` held high by the host. March C- on the unified 4 KB SRAM (1 K × 32-bit words). Reports the first failing word address and bit mask.

**Timing:** ~44 ms per macro at 32 MHz (≈ 1.4 M cycles). Total ≈ 88 ms — acceptable at boot.

| Register | Width | Description |
|---|---|---|
| `IMEM_BIST_PASS` | 1 | 1 = no faults found |
| `IMEM_BIST_FAIL_ADDR` | 15 | Word address (×4 = byte address) of first bad IMEM word |
| `IMEM_BIST_FAIL_BITS` | 32 | Failing bit mask at `IMEM_BIST_FAIL_ADDR` |
| `DMEM_BIST_PASS` | 1 | 1 = no faults found |
| `DMEM_BIST_FAIL_ADDR` | 15 | Word address of first bad DMEM word |
| `DMEM_BIST_FAIL_BITS` | 32 | Failing bit mask at `DMEM_BIST_FAIL_ADDR` |

**Boot sequence:**

```
Power-on → DSP SRAM BIST → IMEM BIST → DMEM BIST
  → host reads results via SPI
  → host programs overlay if needed (see below)
  → host loads firmware into IMEM via SPI
  → host releases CPU_RESET
```

---

## Bad-word overlay

Writing a correct value to a stuck SRAM cell does not fix it — the cell overrides the write on every subsequent read. The overlay intercepts reads to known-bad addresses and returns the correct data from a small register file, bypassing the SRAM output.

### Structure

Each macro has a 16-entry CAM overlay:

```
Entry: { valid[1], addr[14:0], data[31:0] }   (16 entries per macro)
```

On every IMEM or DMEM read:

```
if any valid CAM entry matches read_addr → return CAM data  (SRAM output ignored)
else                                     → return SRAM data
```

The CAM lookup is combinational (priority encoder over 16 entries) and adds ≤ 1 pipeline stage — within the 2-cycle AHB-Lite read budget at 32 MHz.

### Programming the overlay

When `IMEM_BIST_PASS = 0`:

1. Host reads `IMEM_BIST_FAIL_ADDR` and `IMEM_BIST_FAIL_BITS`.
2. Host relinks firmware with a linker memory map that excludes the bad word address from `.text` (instruction placed at all other addresses; bad address left as a gap).
3. Host writes the correct instruction for the bad address into `IMEM_OVERLAY_n_ADDR / DATA / VALID` registers via SPI.
4. Host loads firmware into IMEM via SPI (existing burst-write path). The write to the bad address may not stick in silicon, but the overlay will override on read.
5. Host releases `CPU_RESET`. CPU boots; reads to bad addresses return overlay data.

For DMEM faults: adjust stack pointer and linker `.data` / `.bss` placement to avoid the bad region; patch any required variables at bad addresses with DMEM overlay CAM entries.

### Overlay registers

| Register | R/W | Description |
|---|---|---|
| `IMEM_OVERLAY_n_ADDR` (n=0..15) | R/W | IMEM overlay CAM entry n word address |
| `IMEM_OVERLAY_n_DATA` (n=0..15) | R/W | IMEM overlay CAM entry n 32-bit data |
| `IMEM_OVERLAY_n_VALID` (n=0..15) | R/W | 1 = this entry is active |
| `DMEM_OVERLAY_n_ADDR` (n=0..15) | R/W | DMEM overlay CAM entry n word address |
| `DMEM_OVERLAY_n_DATA` (n=0..15) | R/W | DMEM overlay CAM entry n 32-bit data |
| `DMEM_OVERLAY_n_VALID` (n=0..15) | R/W | 1 = this entry is active |

### Coverage

| Scenario | Outcome |
|---|---|
| ≤ 16 isolated bad words, not at reset vector (0x00000) | Recoverable — overlay + firmware relink |
| DMEM bad words outside stack/data regions | Recoverable — linker avoidance |
| Fault at reset vector (first instruction fetch) | Unrecoverable — CPU cannot boot |
| > 16 bad words in a contiguous block | Overlay exhausted — chip cannot execute firmware |

---

## Interface (AHB-Lite)

| Peripheral | WB Address | Notes |
| --- | --- | --- |
| Register bank | `0x10000` | All ASIC config/status registers |
| SPI master | `0x10100` | SX1257 register writes |
| IRQ controller | `0x10200` | IRQ source read/clear |

---

## Implementation notes

**PicoRV32 IP source.** Use the upstream PicoRV32 repo (Clifford Wolf). Enable `ENABLE_MUL`, `ENABLE_DIV`, `ENABLE_IRQ`. Disable `ENABLE_FAST_MUL` to save gates (iterative MUL is fine for firmware latency budget).

**Firmware load flow:**
```
1. Host asserts CPU_RESET=1 via SPI register write
2. Host burst-writes firmware.bin to IMEM (0x00000)
3. Host de-asserts CPU_RESET=0
4. PicoRV32 fetches from 0x00000; executes SX1257 init, then waits for IRQ
```

**IRQ.** Schmidl-Cox lock fires `IRQ_CORR_LOCK` (AGC). Training accumulator completion fires `IRQ_TRAINING_DONE` — this is the W computation trigger for the software path. When `WGT_SRC=SW`, firmware reads Z_j_scaled from registers (`0x70`–`0x8F`), computes W, writes `W_SHADOW` (`0x90`–`0xAF`), then asserts the W commit strobe. When `WGT_SRC=AUTO`, the hardware Weight Generation FSM fires automatically and firmware is not required for the weight path — firmware may still read `W_HW` for EMA smoothing. Hardware copies `W_SHADOW` into `W_ACTIVE` atomically at the next idle boundary and sets `W_valid`. The live combiner falls back to the selected bypass antenna until `W_valid` is set.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Firmware load + boot | Load minimal test binary via SPI; monitor WB bus | CPU fetches from 0x00000 after CPU_RESET=0 |
| MRC weight computation | Pre-load Z_j_scaled registers; assert IRQ_TRAINING_DONE | W matches Python `H* / Σ\|H\|²` to ±2 LSB |
| EGC weight computation | Pre-load Z_j_scaled registers | \|w_j\| = 1, angle(w_j) = −angle(h_j) |
| SC weight computation | Pre-load Z_j with one dominant branch | w_j = 1 on correct branch, 0 elsewhere |
| AGC loop | Static channel; vary SX1257 gain via WB | Gain converges within 3 packets |
| EMA reset on gain change | Trigger AGC step; check ema_reset_pending | Next packet seeds H_prev = H_new, skips blend |
| AHB-Lite bus | Back-to-back peripheral accesses | No missed ack; correct data |
| IMEM BIST — clean | Inject fault-free IMEM model | `IMEM_BIST_PASS=1`; BIST completes within 90 ms |
| IMEM BIST — single stuck-at-0 | Force one IMEM bit to 0 in sim | `IMEM_BIST_PASS=0`; `IMEM_BIST_FAIL_ADDR` matches injected address; `IMEM_BIST_FAIL_BITS` has exactly one bit set |
| DMEM BIST — single stuck-at-1 | Force one DMEM bit to 1 in sim | `DMEM_BIST_PASS=0`; correct address and bit mask reported |
| Overlay — single bad IMEM word | Inject stuck bit; program overlay CAM; load firmware; boot | CPU executes correctly; JTAG readback of bad address returns overlay data |
| Overlay — CAM miss | Access IMEM address not in overlay | SRAM data returned (no CAM interference) |
| Overlay — 16 entries full | Program all 16 entries; access 17th bad address | 17th fault returns bad SRAM data (CAM exhausted); no hang |
| Reset vector fault | Force stuck bit at 0x00000 | CPU halts or crashes; `IMEM_BIST_FAIL_ADDR=0`; recovery impossible (expected) |

---

## Related blocks

- [AHB-Lite Bus](AHB-Lite%20Bus.md) — interconnect
- [SPI Master](SPI%20Master.md) — SX1257 config
- [IRQ Controller](IRQ%20Controller.md) — `training_done`, `corr_lock`, and TX IRQs
- [Packet Control FSM](Packet%20Control%20FSM.md) — packet phase, safe W commit, W missed status
- [Training Accumulator](Training%20Accumulator.md) — Z_j source; triggers `IRQ_TRAINING_DONE`
- [Weight Generation](Weight%20Generation.md) — weight computation detail (HW FSM option)
- [ALMMSE-MRC Combiner](ALMMSE-MRC%20Combiner.md) — W register target
- [Register Map](../Register%20Map.md) — Z_j registers and training diagnostics
- [Register Map](../Register%20Map.md) — `CPU_RESET` at `0x02`
- [Memory Strategy](../Memory%20Strategy.md) — macro selection, BIST architecture, overlay fallback
- [JTAG TAP](JTAG%20TAP.md) — diagnostic complement: halted-CPU memory readback and single-step

# Custom Temporary HALT for testing 

PCPI core custom instruction to 'temp halt' the core.
JTAG -> halt -> CPU_SS

When Halt is set, the CPU pauses until the halt signal is recieved - via JTAG.

replaces:

```
    while (halt) {

    }

```

# Trace interface exposed on JTAG

Logic TBD...

# Single Stepping from Clock gates on s


# Clock Muxing for the CPU


# CPU Boot Procedure and Reset Sequence

1. System reset de-asserted
2. JTAG has control over bus
3. JTAG writes in the boot code to RAM and peripherals
4. JTAG takes cpu out of reset
