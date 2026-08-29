
## Known Issues

Status of `hw/rtl/spi_m/` against the [SPI Master Specification](../../../docs/hardware/design/blocks/SPI%20Master%20Specification.md), updated **29 August 2026**.

The block is now **functional**. All four required commands (`SPI_READ`,
`FAST_READ`, `SPI_WRITE`, `FAST_WRITE` — `GRPR-SPIM-006`) produce a correct
waveform, in both mode 0 and mode 3, and are checked byte-for-byte against the
decoded MOSI stream by `hw/tb/spi_m/test_spi_m.py` (21 tests, all passing).
`ahb_spi_m_directed` is registered in `.github/sim-ci-targets.yaml`.

The block is still **not integrated** — `hw/rtl/periph_ss.sv` continues to hold
`ahb_stub_slave` in the SPI Master fabric slot. That remains outstanding work.

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

Also fixed, and not previously listed: `ahb_spi_m.sv` did not elaborate
cleanly — `ctrl_enable` was an undeclared implicit net, `spi_m_core`'s `.addr()`
was left unconnected, `cmd_en` was undriven, and `spi_start_rise_p` was
assigned from the malformed expression `& ~spi_start_r`.

### Outstanding

| ID | Issue | Affects |
|---|---|---|
| `SPIM-ISSUE-015` | **`STATUS` level fields are absent.** `TX_LEVEL`/`RX_LEVEL` are not implemented; `STATUS` exposes only the empty/full flags, which is what the current spec table defines. Add them if the level fields are wanted — see `SPIM-SPEC-003`. | Register map |
| `SPIM-ISSUE-017` | **`DATA` writes push only 1 byte**, not the 1–4 the `DATA` register table allows. A 32-bit store pushes only `HWDATA[7:0]`. | Register map |
| `SPIM-ISSUE-020` | **The register block aliases every 32 bytes** across its 4 KiB window — only `HADDR[4:2]` is decoded. Harmless today, but it should be a stated decision rather than an accident. | Register map |
| `SPIM-ISSUE-021` | **Reserved-offset reads and writes now both error**, which resolves the old asymmetry — but the behaviour is still not stated in the spec. | `GRPR-SPIM-001` |
| `SPIM-ISSUE-023` | **The shift-register width is not actually configurable.** `DATA_WIDTH` exists as a parameter, but `ahb_spi_m` hardcodes `.DATA_WIDTH(8)` and `spi_m_tx` still contains fixed 32-bit address slices. No other width will elaborate correctly. | `GRPR-SPIM-011` |
| — | **Not integrated into `periph_ss`.** The SPI Master fabric slot still holds `ahb_stub_slave`. | — |

### Specification defects and gaps

Resolved in the specification as part of this work: the register map now lists
seven registers at `0x00`–`0x18` with `IRQ_EN` restored at `0x10`; `CTRL` gains
`ENABLE` at bit 3, `CLKDIV` at `[15:8]` and the two interrupt enables at
`[17:16]`, resetting to `0x0000_0100` for the 4 MHz default of
`GRPR-SPIM-013`; the `IRQ_EN` table is corrected; the data-phase stall
behaviour is specified; and `SPIM-SPEC-005`/`-006` are answered in prose.

Still open — see the Open Items section of the specification:

| ID | Item |
|---|---|
| `SPIM-SPEC-001` | `OVERRUN`/`UNDERRUN` each cover both an AHB access error and an in-transfer FIFO event. Both are implemented and share a bit; splitting into four bits is still open. |
| `SPIM-SPEC-003` | FIFO depth is fixed at 4 by `FIFO_DEPTH`, but is still not stated as a requirement. |
| `SPIM-SPEC-007` | Flush is now implemented (`CMD.RX_FLUSH`/`TX_FLUSH`), but no transfer-abort mechanism is defined, and behaviour under reset mid-transfer is unstated. |
| `SPIM-SPEC-010` | Duplicate and missing requirement IDs: `GRPR-SPIM-005` is used twice, `GRPR-SPIM-004` is referenced but the Pico item is tagged `GRPR-SPIM-INFO-001`, and `GRPR-SPIM-014`/`-016`/`-017` are each used for two different requirements. |
| `SPIM-SPEC-011` | `GRPR-SPIM-005` says data is transmitted "on the MISO port". A master transmits on MOSI. |
| `SPIM-SPEC-012` | Register naming is inconsistent between the map, the section headings and the interrupt equation. |

### Test coverage

`hw/tb/spi_m/test_spi_m.py` — 21 directed tests, all passing:

* **Registers** — reset values, `CTRL`/`CMD` field placement, `START` reads 0,
  `ADDR` byte strobes, `IRQ_STATUS` W1C, TX overrun, illegal-mode and
  read-only-write ERROR responses, `CFG_ERR` on START-while-busy.
* **Transactions** — `SPI_WRITE`, `FAST_WRITE`, `SPI_READ`, `FAST_READ` checked
  against the expected MOSI byte stream and SCK cycle count; mode 3;
  command-only transfers; all four `ADDR_BYTES` widths; the `CLKDIV` ratio;
  the TX-FIFO stall path; FIFO flush; and the `irq` output.

`hw/tb/spi_m/spi_m_utils.py` holds the register-field helpers and the
wire-level `SpiMonitor`, which decodes MOSI and drives MISO on the CPOL/CPHA-
correct edges. The monitor is what gives these tests their value: every
functional defect above showed up as a wrong byte, a wrong bit count or a wrong
number of SCK cycles, none of which is visible from the register interface.
