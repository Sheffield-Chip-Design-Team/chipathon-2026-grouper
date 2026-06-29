# Trouper DSP Chip Specification

## Document Control

| Field | Value |
|---|---|
| Document ID | GRPR-SPEC-001 |
| Version | 0.1 |
| Status | DRAFT |
| Date | 2026-06-20 |
| Project | SSCS PICO Chipathon 2026 — Grouper  |

> **Requirement notation:** SHALL = mandatory, SHOULD = strongly recommended, MAY = optional.
> **Columns:** ID · Priority (C=Critical / H=High / M=Medium / L=Low) · Type (F=Functional / P=Performance / I=Interface / HW=Physical) · Requirement · Verification (T=Test/Simulation / A=Analysis / I=Inspection)

---

## 1. Scope

G
---

## 2. Definitions

| Term | Definition |
|---|---|
| AHB-Lite | AMBA 3 AHB-Lite protocol used on the inter-project Grouper-to-Trouper control link and within Trouper's local register/peripheral fabric |
---

## 3. System-Level Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| GRPR-SYS-001 | C | F | Grouper shall receive four independent 1-bit I+Q ΣΔ bitstreams from SX1257 AFEs at 32 MS/s per branch. | T |

### 3.1 Clock Architecture

Trouper uses two internal clock domains derived from the single external 32 MHz input (`IQ_CLK`):

| Domain | Clock | Period | Blocks |
|---|---|---|---|
| 32 MHz tier | `IQ_CLK` | 31.25 ns | `sd_decimator` ×4, `sd_remod`, `psram_buf_ctrl`, `sc_detector` |
| 16 MHz tier | `CLK_16M` (IQ_CLK÷2) | 62.5 ns | `dc_removal`, `training_acc`, `mrc_combiner`, `frontend_buf_ctrl`, `packet_ctrl_fsm`, `reg_bank` (incl. interrupt aggregation), `spi_slave` |

`CLK_16M` is generated as a single registered divide-by-2 at the top level and distributed as a normal clock tree. The divider FF is synchronously reset so CLK_16M phase is deterministic after RESETB de-assertion. Because CLK_16M is phase-aligned with IQ_CLK, no metastability synchronisers are needed at domain crossings — the SDC declares it as a generated clock (`create_generated_clock -divide_by 2 -source IQ_CLK`) and the timing analyser constrains crossings automatically.

**Known limitation — SC detector TDM FSM:** The SC detector internally runs an 8-step time-division multiplexed autocorrelation. Each step is a single-cycle dependency (result feeds the next step's accumulator). The combinatorial chain (8×8 multiply → sign-extend → two 24-bit adds) needs ~72 ns at SS/125 °C/3.0 V, which exceeds the 31.25 ns single-cycle budget. Moving the SC detector to CLK_16M does not help — the TDM steps must still complete in one cycle of whatever clock the block uses, and at 16 MHz that cycle is only 62.5 ns (still short). Closing this violation requires restructuring the TDM FSM into a 2-cycle pipeline. See TRPR-PHY-008, TRPR-SYS-015.

---
## 4. Block Requirements

---


### 4.2 AHB QSPI Peripheral (`ahb_qspi.v`) — TRPR-PSR

Compatible with APS6404L external PSRAM interface. 
Mandatory for same-packet MRC (see TRPR-SYS-017). Continuously streams all decimated I/Q samples to PSRAM; 

#### Same-Packet MRC Replay Sequence

```
Power-on: PSRAM initialises (REPLAY_ACTIVE de-asserts; circular write resumes
```

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| GRPR-PSR-001 | C | F | The controller SHALL implement a QSPI master interface compatible with APS6404L (8 MB, 32 MHz QPI mode). Initialisation (enter QPI, set drive strength) SHALL complete within 1 ms of RESETB de-assertion. | T |
| GRPR-PSR-002 | C | F | The controller SHALL continuously stream all decimated I/Q samples to PSRAM in a circular buffer pattern, recording every sample from power-on. On `sc_lock`, the controller SHALL latch the current PSRAM write address as the packet start pointer. | T |
| GRPR-PSR-004 | C | F | `REPLAY_MISSED` SHALL assert and latch if `W_COMMIT` is not received before the payload window closes, preventing replay of an already-passed portion. The combiner SHALL fall back to next-packet weights for the remainder. | T |
| GRPR-PSR-005 | H | F | The controller SHALL store samples in int8 format: 1 byte per I component + 1 byte per Q component per branch = **8 bytes per sample** for NR=4, in order i0,q0,i1,q1,i2,q2,i3,q3. No other storage width is implemented. | T |
| GRPR-PSR-013 | C | P | **Maximum PSRAM write data rate (nominal operating point):** 4 channels × 2 bytes (int8 I + int8 Q) × 250 000 S/s = **2 MB/s (16 Mbit/s)**. The APS6404L rated maximum is ~66 MB/s (QPI at 133 MHz); nominal utilisation is ~3% of device capacity. | A |
| GRPR-PSR-014 | C | P | **QPI timing headroom (32 MHz controller clock):** `iq_valid` arrives every 64 cycles (2.0 µs at 500 kS/s). S_WRITE = 25 (write) + 19 (SC delay read) = 44 cycles, leaving **20 spare**. S_REPLAY = 25 (write) + 31 (replay read) = 56 cycles, leaving **8 spare**. Both phases SHALL complete before the next `iq_valid`. See Gate 8 in `planning/decimator-hb-migration-impact-plan.md`. | A |
| GRPR-PSR-015 | C | P | **Buffer capacity (worst case SF12, int8 I/Q mode):** maximum occupied depth ≈ 8 × 2^12 × 8 bytes = **256 kB**. The APS6404L provides 8 MB; headroom ≥ 32×. No overflow SHALL occur for SF ≤ 12 at either supported bandwidth. | A |
| GRPR-PSR-006 | H | I | `PSRAM_STATUS` (0x71) SHALL expose: `state[1:0]`, `SAMPLE_SKIP[2]`, `INIT_DONE[3]`, `REPLAY_ACTIVE[4]`, `REPLAY_MISSED[5]`, `OVERFLOW[6]`, `BUF_ACTIVE[7]`. STATE occupies 2 bits (only 4 FSM states); the freed bit [2] carries `SAMPLE_SKIP`. | T |
| GRPR-PSR-007 | H | F | Sticky error flags (`OVERFLOW`, `REPLAY_MISSED`, `SAMPLE_SKIP`) SHALL be clearable by writing `PSRAM_CLR_ERR` (0x70[1]). The `PSRAM_CLR_ERR` pulse SHALL be routed into `psram_buf_ctrl` (`clr_err` port); a genuine error coinciding with a clear in the same cycle SHALL NOT be lost. | T |
| TRPR-PSR-009 | M | F | A disable mode (`PSRAM_EN=0`, 0x70[0]) SHALL be supported for factory test and bring-up only. In this mode the controller SHALL remain idle and SHALL NOT assert any QSPI pad outputs. | T |
| TRPR-PSR-010 | C | I | `PSRAM_CTRL.QSPI_OWNER` (0x70[3]) SHALL select the active QSPI master: `0` = Trouper `psram_buf_ctrl` owns the pads for capture/replay, `1` = ownership is transferred away from the replay controller for a future firmware-managed external-memory mode. While `QSPI_OWNER=1`, the local replay controller SHALL de-assert CE#, hold SCK low, tri-state SIO[3:0], and suspend BUFFERING/REPLAY activity. | T |
| TRPR-PSR-011 | H | F | Writes to `QSPI_OWNER` during BUFFERING or REPLAY SHALL NOT glitch the pads. The ownership change SHALL take effect only when `PSRAM_STATUS.STATE=IDLE`, after which the newly selected owner has exclusive control of the PSRAM QSPI pads. | T |
| TRPR-PSR-012 | L | F | `PAD_CONFLICT` SHALL assert if any PSRAM QSPI pad is driven by another block simultaneously. | T |
| TRPR-PSR-016 | C | F | **SC correlator delay reads:** on each `iq_valid` (pre-lock), the controller SHALL issue a QPI read of branch-0 I/Q at address `(write_ptr − M)`, where M = 1 << (SF + sample_shift), and present the result as `sc_delayed_sample` to the SC detector before the next `iq_valid`. SC delay reads SHALL be interleaved with circular writes in the idle cycles between writes; they SHALL NOT delay or preempt same-packet capture writes. After `sc_lock`, SC delay reads cease until the FSM returns to IDLE. | T |
| TRPR-PSR-017 | H | F | **PSRAM debug readback (host SPI, no Grouper required):** When `PSRAM_STATUS.STATE=IDLE` (`packet_active=0`) and `QSPI_OWNER=0`, the controller SHALL accept register-mediated QPI read requests from the host SPI slave: (1) Host writes a 23-bit byte address to `PSRAM_DBG_ADDR_LO/MID/HI` (0x72–0x74). (2) Host writes `PSRAM_DBG_CTRL.RD_TRIG=1` (0x75[0]); the controller asserts `DBG_BUSY` (0x75[7]) and issues a QPI burst read of 8 bytes from the target address. (3) Host polls `DBG_BUSY` until clear (≤ 31 QSPI cycles ≈ 0.97 µs at 32 MHz). (4) Host reads `PSRAM_DBG_DATA` (0x76) eight times; bytes arrive in order i0,q0,i1,q1,i2,q2,i3,q3. (5) If `AUTO_INC=1` (0x75[1]), the address advances by 8 after the last byte is read and a new fetch begins automatically. `DBG_BUSY` SHALL remain asserted and reads of `PSRAM_DBG_DATA` SHALL return 0x00 while `packet_active=1` or `QSPI_OWNER=1`. Debug reads are serviced in the spare sub-cycles between `iq_valid` pulses and SHALL NOT delay or preempt circular capture writes. | T |
| TRPR-PSR-019 | C | F | **Spreading factor is fixed per session.** SF SHALL be programmed at start-up before acquisition begins and SHALL NOT change during operation in the current revision. The SC delay distance (`M = 1 << (SF + sample_shift)`) and the delay-line warm-up window depend on SF and BW; changing either live would otherwise present a stale delayed sample read from an address not yet written with `N = M` fresh samples at the new distance. The controller SHALL re-arm the SC delay warm-up (suppress `del_valid` until `N` fresh samples are buffered) whenever `sf` or `sample_shift` changes. | T |
| TRPR-PSR-020 | C | F | **No-skip detection.** The controller SHALL latch a sticky `SAMPLE_SKIP` flag (`PSRAM_STATUS` 0x71[2], clearable via `PSRAM_CLR_ERR` 0x70[1]) if any `iq_valid` is asserted while a prior QPI transaction is still in progress — i.e. any decimated sample that cannot be captured. Under all supported bandwidths (125 kHz, 250 kHz) the timing budget of TRPR-PSR-014 guarantees this condition never occurs and `SAMPLE_SKIP` SHALL remain 0; the flag exists to make any out-of-budget condition observable rather than silent. Verified by a directed sustained-`iq_valid` test that asserts `SAMPLE_SKIP=0` across a full packet at 125 and 250 kHz. | T |
| TRPR-PSR-018 | C | I | **QPI-only interface mandate:** The PSRAM interface SHALL use QPI (4-bit) mode exclusively; SPI (1-bit) mode is not a supported operating point. Rationale: at the 500 kS/s `iq_valid` rate (64-cycle period at 32 MHz), one period must accommodate a write (25 QPI cycles) + SC delay read (19 QPI cycles) = 44 cycles (20 spare). SPI equivalents (~200 cycles) are >3× over the 64-cycle budget. Additionally, SIO[3:0] occupy four dedicated pads (TRPR-PHY-003), so QPI incurs zero additional pad cost versus SPI. | A |

---

### 4.3 AHB SPI Slave (`spi_slave.v`) — TRPR-SPS

Host (Raspberry Pi) configuration and debug interface. The register map is constrained to the 7-bit address space `0x00`–`0x7F` (see `planning/Register Map.md`); the former extended firmware-load frame is removed (Trouper has no CPU SRAM to load).

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-SPS-001 | C | F | The SPI slave SHALL accept standard Mode 0 SPI transactions from the host RPi on `SPI_MOSI`, `SPI_SCK`, `HOST_CS` and return data on `SPI_MISO`. | T |
| TRPR-SPS-002 | C | F | Each transaction SHALL consist of a command byte followed by one or more data bytes. Command byte: bit [7] = R/W# (0 = write, 1 = read), bits [6:0] = 7-bit register address. The entire register map SHALL fit in `0x00`–`0x7F`; there is no extended-address or bank-select mechanism. | T |
| TRPR-SPS-003 | C | I | The SPI slave SHALL translate transactions to accesses on the internal register bank bus. | T |
| TRPR-SPS-004 | C | P | Maximum SPI clock rate SHALL be 10 MHz. | A |
| TRPR-SPS-005 | C | HW | `HOST_CS`, `SPI_SCK`, and `SPI_MOSI` are asynchronous to the 32 MHz core clock. A 2-FF synchroniser SHALL be applied to `HOST_CS` and `SPI_SCK` edges, or the SPI slave FSM SHALL run in the SPI clock domain with an AHB-Lite handshake. | I |
| TRPR-SPS-006 | H | F | `CHIP_ID` (0x00) SHALL return 0xA7 on any SPI read, confirming interface health on first bring-up. | T |
| TRPR-SPS-007 | H | F | The SPI slave SHALL arbitrate with Grouper register-bus accesses; host SPI transactions SHALL be queued or stalled during an in-progress inter-project bus cycle. Priority: Grouper path > SPI Slave (host). | T |
| TRPR-SPS-008 | M | F | The SPI slave SHALL tri-state `SPI_MISO` when `HOST_CS` is de-asserted to avoid bus contention with other SPI devices sharing the bus. | T |
| TRPR-SPS-009 | C | F | **Read-data timing:** the slave SHALL latch the register address on the final (8th) rising `SPI_SCK` edge of the command byte, so that read data is valid on `SPI_MISO` for every bit of the immediately following data byte. A 2-byte read transaction (command + data) SHALL return the addressed register's value in the data byte. | T |
| TRPR-SPS-010 | H | F | **Burst access:** if `HOST_CS` remains asserted after the first data byte, each additional data byte SHALL access the next consecutive register address (auto-increment, wrapping modulo 128). Exception: `PSRAM_DBG_DATA` (`0x76`) SHALL NOT auto-increment — repeated data bytes re-access the same port. | T |
| TRPR-SPS-011 | M | I | Register `0x7F` SHALL NOT be implemented (reads return 0x00, writes ignored). The command byte `0x7F` is reserved as a future protocol-escape code; current hardware SHALL treat it as a write to `0x7F` and discard it. | I |

---

### 4.4 AHB SPI Master — GRPR-SPM

Trouper does not contain an on-chip SPI master for SX1257 configuration in the current revision. AFE configuration is provided externally at board/system level and is outside Trouper's hardened RTL contract.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| GRPR-SPM-001 | C | F | Trouper SHALL NOT instantiate an on-chip SPI master or expose `CS_A[1:0]` AFE-select outputs in the current revision. | I |
---


### 4.5 GPIO CTRL

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-JTG-001 | — | — | **TODO** GPIO removed; `0x00`–`0x07` reserved. | — |

---

## 5. Control-Plane Integration (On-Chip AHB-Lite + Host SPI) — TRPR-INT

Trouper is a MIMO RX ASIC connected to a companion **Grouper** project on the same MPW. The control plane lives inside Grouper (PicoRV32 hardened macro), while Trouper acts as an AHB-Lite peripheral to Grouper.

### 5.1 Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Grouper SoC                           │
│                                                              │
│  [Host SPI Slave] ─┐                                         │
│                    ├─► [AHB Bridge / Slave] ─► [Reg Bank]    │
│  [AHB-Lite Port] ──┘                 │                       │
│      (from Grouper)                  ├─► IRQ controller      │
│                                      └─► DSP control/status  │
└──────────────────────────────────────────────────────────────┘
```


### 5.2 Integration Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| GRPR-INT-001 | C | I | Grouper SHALL contain an internal control fabric linking the inter-project AHB-Lite slave endpoint, the SPI slave bridge, and the register/peripheral fabric. | I |

### 5.4 CPU-Held-Reset Operation

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-INT-010 | C | F | When the Grouper firmware path is inactive or no `W_COMMIT` is received, Trouper SHALL operate in bypass mode: the combiner routes the lowest-enabled antenna to the re-modulator output without MRC weighting. | T |
| TRPR-INT-011 | H | F | The host RPi SHALL be able to pre-configure Trouper registers such as SC thresholds, antenna enable, and mode via the SPI slave without requiring firmware execution. | T |
| TRPR-INT-012 | M | F | Grouper-inactive Trouper with Mode 1 (passthrough) SHALL provide a functional single-antenna LoRa receive path for bring-up and basic system validation. | T |

---

## 6. Physical Design Requirements — TRPR-PHY

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PHY-001 | C | HW | The design SHALL be submitted in GF180MCU (gf180mcuD), targeting `gf180mcu_fd_sc_mcu7t5v0` standard cells. AS cells (`gf180mcu_as_sc_mcu7t3v3`) are not the current plan and carry tapeout risk; new work SHALL NOT target AS cells without explicit team decision. | I |
| TRPR-PHY-015 | C | HW | Supply voltages SHALL be: VDD_CORE = 3.3 V (±5%), VDD_IO = 5.0 V (±5%). The `gf180mcu_fd_sc_mcu7t5v0` standard-cell library is rated for 5 V IO and 3.3 V core operation. Board designs SHALL NOT apply 3.3 V to VDD_IO or 5 V to VDD_CORE. | I |
| TRPR-PHY-002 | C | HW | The chip-level integration baseline SHALL use the Chipathon workshop padring: die `[0, 0, 2935, 2935]` um and user-core `[442, 442, 2493, 2493]` um. | I |
| TRPR-PHY-003 | C | HW | The standalone Trouper hard macro SHALL fit within the Chipathon quarter-slot budget. The current Trouper target is **`1100 um × 1100 um`**. | I |
| TRPR-PHY-004 | C | HW | Final package-pad allocation SHALL be validated at the later chip-top integration stage against the Chipathon padring. | I |
| TRPR-PHY-005 | H | HW | Physical design SHALL use LibreLane inside the `hpretl/iic-osic-tools:chipathon26` Docker image. `:latest` and `:2026.04` tags are prohibited. | I |
| TRPR-PHY-006 | H | HW | No on-chip SRAM macro instances are required. The frontend buffer SRAM (`gf180mcu_fd_ip_sram__sram512x8m8wm1`) has been removed; the SC correlator delay line is served by the off-chip APS6404L PSRAM (see TRPR-FBC-001). | I |
| TRPR-PHY-007 | H | P | Post-PNR WNS at TT/25 °C/3.3 V (setup) SHALL be ≥ 0 ns. | A |
| TRPR-PHY-008 | H | P | Post-PNR WNS at SS/125 °C/3.0 V SHALL be documented each run. The SS gap is a known FD cell library limitation (cells rated 5 V, characterised at 3 V); −7 to −10 ns at MCP=2 is accepted for chipathon submission. Trouper is guaranteed only at TT ≥ 0 °C, 3.3 V ±5%. | A |
| TRPR-PHY-009 | H | P | Post-PNR hold WNS at FF/−40 °C/3.6 V SHALL be ≥ 0 ns. | A |
| TRPR-PHY-010 | H | HW | Magic DRC error count SHALL be 0 before tapeout submission. | A |
| TRPR-PHY-011 | H | P | Estimated total power at TT/25 °C/3.3 V SHALL be ≤ 60 mW. | A |
| TRPR-PHY-012 | M | HW | Core utilisation SHOULD be in the range 65–75%. | I |
| TRPR-PHY-013 | M | HW | Power-pad count and placement are chip-top integration concerns under the Chipathon padring. Standalone Trouper floorplanning SHALL still document estimated current draw and any local PDN hotspots so the later padring/power-grid integration can assign sufficient DVDD/DVSS resources. | A |
| TRPR-PHY-014 | C | P | The PNR and signoff SDC SHALL declare both clocks: `create_clock -period 31.25 [get_ports IQ_CLK]` and `create_generated_clock -divide_by 2 -source [get_ports IQ_CLK] [get_pins clk_div_reg/Q] -name CLK_16M`. No global `set_multicycle_path` override is required — each domain is analysed at its own period. IQ_CLK-tier blocks are analysed at 31.25 ns; CLK_16M-tier blocks at 62.5 ns. | I |
---
