
## Known Issues

Status of `hw/rtl/spi_m/` against the [SPI Master Specification](../../../docs/hardware/design/blocks/SPI%20Master%20Specification.md), updated **29 August 2026**.

The block is **functional**. All four required commands (`SPI_READ`,
`FAST_READ`, `SPI_WRITE`, `FAST_WRITE` — `GRPR-SPIM-006`) produce a correct
waveform, in both mode 0 and mode 3, and are checked byte-for-byte against the
decoded MOSI stream by `hw/tb/spi_m/test_spi_m.py` (23 tests, all passing).
`ahb_spi_m_directed` is registered in `.github/sim-ci-targets.yaml`.

The block is now **integrated**: `hw/rtl/periph_ss.sv` instantiates `ahb_spi_m`
in the SPI Master fabric slot, with its pads routed through `io_ss` onto GPIO
pins 4–7. `sw/tests/test_spi_m.c` drives it at the top level against an
APS6404L device model (`hw/tb/models/aps6404l.py`), registered in
`.github/sim-ci-targets.yaml` as `sw_spi_m`.

The block's pad ports were renamed from `SPI_MOSI`/`SPI_SCK`/`SPI_CS_N`/
`SPI_MISO` to `spi_m_mosi_o`/`spi_m_sck_o`/`spi_m_cs_n_o`/`spi_m_miso_i`, which
matches both the specification's IO table and the surrounding RTL's naming.

### Fixed

| ID | Issue | Fix |
|---|---|---|
| `SPIM-ISSUE-001` | Phase FSM not gated on the SPI clock enable | Every phase counter now advances only on `sck_sample`, one pulse per SCK period. |
| `SPIM-ISSUE-002` | Command phase skipped, opcode never transmitted | Fixed by `-001`, plus keying the shift-data mux on `next_state` so the entry load sees the right source. |
| `SPIM-ISSUE-004` | Data phase could hang, divider-dependent | Fixed by `-001`; behaviour is now independent of `CLKDIV`. |
| `SPIM-ISSUE-005` | `CMD.START` did not self-clear | START is a single-cycle pulse; `test_start_self_clears` asserts exactly one CS_N window. |
| `SPIM-ISSUE-006` | Dummy cycles emitted at half the programmed count | `dummy_count` advances on `sck_sample`, i.e. whole SCK periods. |
| `SPIM-ISSUE-007` | RX datapath free-running, ignored `CMD.DIR` | `spi_m_rx` is gated on `data_phase && dir` and samples once per SCK period. |
| `SPIM-ISSUE-008` | RX ignored `CPOL`/`CPHA` | RX samples on `sck_sample`, which is derived from CPOL/CPHA in `spi_m_tx`. |
| `SPIM-ISSUE-009` | `CMD.DIR` unused in the transmit datapath | MOSI is driven only in CMD/ADDR and in a **write** data phase. |
| `SPIM-ISSUE-010` | First TX data byte was `0x00` | A holding register absorbs `small_sync_fifo`'s one-cycle read latency. |
| `SPIM-ISSUE-011` | `DATA` reads returned the previous byte | The RX pop is issued in the AHB *address* phase, so the FIFO's registered `rdata` is valid in the data phase. |
| `SPIM-ISSUE-012` | Address phase sent the wrong bytes, one too many | `addr_shift` is pre-aligned at START so the low-order `ADDR_BYTES+1` bytes are sent MSB-first; the count compares correctly. |
| `SPIM-ISSUE-013` | `HWDATA` captured one cycle early | Register writes use `HWDATA` directly in the data phase. The TB now uses the shared `hw/tb/tb_utils/ahb_utils.py` driver, which drives `HWDATA` in the correct phase. |
| `SPIM-ISSUE-014` | No AHB error response | Two-cycle ERROR: `HREADYOUT` low with `HRESP` high, then `HREADYOUT` high with `HRESP` high. |
| `SPIM-ISSUE-018` | In-transfer FIFO over/underrun not detected | `rx_overrun` and `tx_underrun` are reported by the core and latched into `IRQ_STATUS`. |
| `SPIM-ISSUE-019` | `ADDR` writes ignored byte strobes | All four byte lanes are qualified on `byte_select_r`. |
| `SPIM-ISSUE-022` | No FIFO flush path | `CMD.RX_FLUSH` / `CMD.TX_FLUSH` (bits 28/29) drive the FIFO flush inputs. |
| `SPIM-ISSUE-025` | SCK divider free-ran; no CS hold | SCK is held at its idle level while idle and starts from a known phase; `CS_N` covers `ST_DONE`, giving a half-period of hold. |
| `SPIM-ISSUE-026` | Dead `CLK_DIV_BITS`/`SPI_DATA_W` localparams | Removed. |
| `SPIM-ISSUE-027` | **A back-to-back `DATA` store was silently dropped**, losing that byte. `push_start` was gated on `!push_active`, and `push_active` only clears the cycle *after* the last lane drains — so a store landing in that window never latched, and its byte never reached the FIFO. Byte-at-a-time pushes (three stores of one byte) put `0xDE 0x00` on the wire and hung `test_spi_write`, `test_fast_write`, `test_tx_fifo_stall`. | `push_start` is now gated on `!(\|push_pending)` — the lanes actually outstanding, which is already zero on the cycle the next store lands. |
| `SPIM-ISSUE-029` | **The split interrupt bits were declared but dead.** `int_underflow`/`int_overflow` and `ie_underflow`/`ie_overflow` existed and were reset, but nothing set them, they were absent from the `IRQ_STATUS`/`IRQ_EN` readback (28'b0 + 4 bits), had no W1C path and were missing from the `irq` equation — Verilator flagged all four as unused. The AHB access errors still landed on the wire-event bits, so the split was nominal only. | Both AHB errors now set their own bit: an empty-RX read sets `UNDERFLOW`, a full-TX write sets `OVERFLOW`. Readback widened to 6 bits, W1C and `IRQ_EN` extended to bits 4/5, and all four sources added to `irq`. Covered by `test_irq_status_w1c` and `test_tx_overrun`, which now also assert the wire-event bit stays clear. |
| `SPIM-ISSUE-028` | **`push_tx` in the TB pushed with word stores.** A 32-bit store of one byte strobes all four byte lanes, so the DATA register correctly queued that byte plus three zeros (the 1–4 byte behaviour the spec's `DATA` row calls for). The RTL was right and the testbench was wrong. | `hw/tb/spi_m/test_spi_m.py`'s `push_tx` now uses `HSIZE_BYTE`. |

Also fixed, and not previously listed: `ahb_spi_m.sv` did not elaborate
cleanly — `ctrl_enable` was an undeclared implicit net, `spi_m_core`'s `.addr()`
was left unconnected, `cmd_en` was undriven, and `spi_start_rise_p` was
assigned from the malformed expression `& ~spi_start_r`.

### Outstanding

| ID | Issue | Affects |
|---|---|---|
| `SPIM-ISSUE-020` | **The register block aliases every 32 bytes** across its 4 KiB window — only `HADDR[4:2]` is decoded. Harmless today, but it should be a stated decision rather than an accident. | Register map |
| `SPIM-ISSUE-021` | **Reserved-offset reads and writes now both error**, which resolves the old asymmetry — but the behaviour is still not stated in the spec. | `GRPR-SPIM-001` |
| `SPIM-ISSUE-023` | **The shift-register width is not actually configurable.** `DATA_WIDTH` exists as a parameter, but `ahb_spi_m` hardcodes `.DATA_WIDTH(8)` and `spi_m_tx` still contains fixed 32-bit address slices. No other width will elaborate correctly. | `GRPR-SPIM-011` |

### Specification defects and gaps

Resolved in this round:

| ID | Resolution |
|---|---|
| `SPIM-SPEC-001` | The AHB access errors are split onto their own bits — `UNDERFLOW` (4) for an empty-RX read and `OVERFLOW` (5) for a full-TX write — leaving `UNDERRUN` (1) and `OVERRUN` (2) as the in-transfer wire events. All four are independently enabled and W1C-cleared. See `SPIM-ISSUE-029` for the RTL that was missing. |
| `SPIM-SPEC-007` | Reset mid-transfer is now specified: the transaction is **dropped**, not resumed or replayed (`GRPR-SPIM-021`). `CTRL.ENABLE` is specified as *not* aborting an in-flight transfer — a `CTRL` write while BUSY is rejected with `CFG_ERR`, so a started transaction always completes (`GRPR-SPIM-022`). Reset is the only abort mechanism, by decision. |
| `SPIM-SPEC-010` | Duplicate requirement IDs removed. The SPI Transactions requirements that reused `GRPR-SPIM-014`/`-016`/`-017` are now `-018`/`-019`/`-020`, plus the two new `-021`/`-022`; the `FIFO_DEPTH` requirement that collided on `-017` is now `-023`. `GRPR-SPIM-016` is left to the mode restriction alone. |
| `SPIM-SPEC-011` | `GRPR-SPIM-003` states the transmit port as MOSI. The CDC section's claim that MISO is "sampled on the rising bus clock edge" is corrected to the SCK sampling edge, which is what `hw/rtl/spi_m/spi_m_rx.sv` actually does (`shift_bit = rx_active && sck_sample`). |

Still open — see the Open Items section of the specification:

| ID | Item |
|---|---|
| `SPIM-SPEC-003` | FIFO depth is fixed at 4 by `FIFO_DEPTH`, but is still not stated as a requirement. |
| `SPIM-SPEC-012` | Register naming is inconsistent between the map, the section headings and the interrupt equation. |

### Test coverage

`hw/tb/spi_m/test_spi_m.py` — 23 directed tests, all passing:

* **Registers** — reset values, `CTRL`/`CMD` field placement, `START` reads 0,
  `ADDR` byte strobes, `IRQ_STATUS` W1C, TX overrun, illegal-mode and
  read-only-write ERROR responses, `CFG_ERR` on START-while-busy.
* **Transactions** — `SPI_WRITE`, `FAST_WRITE`, `SPI_READ`, `FAST_READ` checked
  against the expected MOSI byte stream and SCK cycle count; mode 3;
  command-only transfers; all four `ADDR_BYTES` widths; the `CLKDIV` ratio;
  the TX-FIFO stall path; FIFO flush; and the `irq` output.
* **Abort semantics** — `test_reset_mid_transfer_drops` (a reset mid-transfer
  drops the transaction and does not replay it, `GRPR-SPIM-021`) and
  `test_disable_mid_transfer_completes` (clearing `CTRL.ENABLE` while BUSY is
  rejected with `CFG_ERR` and the transfer still completes, `GRPR-SPIM-022`).

`hw/tb/spi_m/spi_m_utils.py` holds the register-field helpers and the
wire-level `SpiMonitor`, which decodes MOSI and drives MISO on the CPOL/CPHA-
correct edges. The monitor is what gives these tests their value: every
functional defect above showed up as a wrong byte, a wrong bit count or a wrong
number of SCK cycles, none of which is visible from the register interface.
