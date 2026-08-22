
## Known Issues

Status of `hw/rtl/spi_m/` against this specification, as of **9 August 2026**.

The block is **not functional**. None of the four required commands (`SPI_READ`, `FAST_READ`, `SPI_WRITE`, `FAST_WRITE` — `GRPR-SPIM-006`) currently produce a correct waveform: the opcode is never transmitted at all, and every byte is clocked out as 7 bits. The block is also not integrated — `hw/rtl/periph_ss.sv` still holds `ahb_stub_slave` in the SPI Master fabric slot.

Findings marked **[sim]** were reproduced in directed Icarus simulations of `ahb_spi_m`; the rest are from RTL inspection. The existing block TB (`hw/tb/spi_m/test_spi_m.py`) only exercises register read/write — its one transaction-level test, `test_fifo_spi_write`, is `skip=True` and does not configure `CTRL`, push TX data, or check MOSI values. There is no `spi_m` entry in `.github/sim-ci-targets.yaml`, so nothing runs the block in CI.

### Blocking functional defects

| ID | Issue | Affects |
|---|---|---|
| `SPIM-ISSUE-001` | **The phase FSM is not gated on the SPI clock enable.** `next_state` in `spi_m_tx.sv` is derived from `shift_ctr_zero` alone and applied on every system clock, so phase transitions occur at system-clock rate instead of SPI-clock rate. Root cause of issues 002–004. | `GRPR-SPIM-003`, `-005`, `-006`, `-007` |
| `SPIM-ISSUE-002` | **[sim] The command phase is skipped entirely — the opcode is never transmitted.** On entry to `ST_CMD` the shift counter still holds 0 from the previous transaction, so the state is exited immediately. Measured: `ST_CMD` lasts one 10 ns system clock and produces **zero SCK edges**, for both `0x02` and `0x0B`. | `GRPR-SPIM-003`, `-005`, `-006` |
| `SPIM-ISSUE-003` | **[sim] Every byte is clocked out as 7 bits, not 8.** The shift counter loads 7 and reaches zero after 7 shifts, at which point the final bit is on MOSI but has not yet had its sampling edge; the reload/phase change fires one system clock later. Measured: a 3-byte address request produced **28 SCK edges** (4 slots × 7 bits) instead of 24. | `GRPR-SPIM-003`, `-005` |
| `SPIM-ISSUE-004` | **[sim] The data phase can hang indefinitely.** `data_count` only advances when `spi_clk_en` and `shift_ctr_zero` coincide, but `shift_load` clears `shift_ctr_zero` on the next system clock. With `CLKDIV=3` the two never coincide: `CS_N` stayed low and the transfer never completed or asserted `DONE`. With `CLKDIV=1` it terminated. Behaviour is divider-dependent. | `GRPR-SPIM-007`, `-008` |
| `SPIM-ISSUE-005` | **[sim] `CMD.START` does not self-clear.** The bit reads back as 0 via the read mux, but the internal register stays set, so `ST_DONE → ST_IDLE` immediately relaunches the same transaction. Measured: the transfer repeated indefinitely with a one-cycle `CS_N` deassertion between repeats. Contradicts the `CMD` register table ("Self-clearing"). | `GRPR-SPIM-005` |
| `SPIM-ISSUE-006` | **[sim] `FAST_READ`/`FAST_WRITE` emit half the programmed dummy cycles.** `dummy_count` increments on every `spi_clk_en`, i.e. once per SCK *half* period. Measured: `DUMMY=8` produced **4 SCK cycles**. An APS6404L `0x0B` needs 8, so the data phase begins 4 cycles early. | `GRPR-SPIM-003`, `-006` |
| `SPIM-ISSUE-007` | **[sim] The RX datapath is free-running and ignores `CMD.DIR`.** `spi_m_rx` is gated only on `enable` (tied to `1'b1`) and `spi_clk_en`, with no connection to the TX FSM state, `data_en`, `dir`, or `CS_N`. Measured: bytes pushed into the RX FIFO during the command, address **and** dummy phases. It also shifts once per `spi_clk_en` — twice per SCK period — so every bit is double-sampled. | `GRPR-SPIM-006`, `-007` |
| `SPIM-ISSUE-008` | **The RX path ignores `CPOL`/`CPHA` entirely**, so mode 3 reads are unsupported and mode 0 reads do not sample on a defined edge. | `GRPR-SPIM-002`, `-009` |
| `SPIM-ISSUE-009` | **`CMD.DIR` is unused in the transmit datapath.** `dir` is declared as a port on `spi_m_tx` and referenced nowhere, so a read command still drains the TX FIFO onto MOSI during the data phase. | `GRPR-SPIM-006`, `-007` |
| `SPIM-ISSUE-010` | **[sim] TX data is one byte late; the first data byte on the wire is `0x00`.** `small_sync_fifo` registers its `rdata` output, so the shift register loads the *previous* pop. Measured with a FIFO holding `AA, BB`, MOSI carried `00, AA, BB` — and the tail byte would be lost on a transfer that terminated correctly. | `GRPR-SPIM-006`, `-007` |
| `SPIM-ISSUE-011` | **[sim] `DATA` reads return the previous byte.** Same root cause: `HRDATA` is driven combinationally from the FIFO's registered output in the same cycle as the pop. Measured with entries `11, 22, 33`, the master latched `00, 11, 22`. | `GRPR-SPIM-006`, `-007` |
| `SPIM-ISSUE-012` | **The address phase sends the wrong bytes, and one too many.** `spi_m_tx` always sources `addr_shift[31:24]` and shifts left, so it transmits the *top* N+1 bytes of `ADDR` rather than the low-order bytes this spec requires. It also compares `addr_count < addr_bytes + 1` against a post-incremented counter. Measured: `ADDR_BYTES=2` with `ADDR=0x00123456` transmitted 4 byte-slots beginning `0x00, 0x12, 0x34` instead of 3 bytes `0x12, 0x34, 0x56`. | `GRPR-SPIM-003`, `-005` |

### Register and bus-interface defects

| ID | Issue | Affects |
|---|---|---|
| `SPIM-ISSUE-013` | **[sim] `HWDATA` is captured one cycle early.** `ahb_spi_m` samples `HWDATA` on the *address*-phase edge, where AHB-Lite does not define it. Measured with a protocol-compliant master, every register write took the previous transfer's data. The existing block TB drives `HWDATA` during the address phase, which masks this. | `GRPR-SPIM-001` |
| `SPIM-ISSUE-014` | **No AHB error response.** `HREADYOUT` is hardwired to `1'b1` and `HRESP` is combinational, so the `SLVERR` required for an illegal `CPOL`/`CPHA` pair is not the protocol-legal two-cycle response. Already carries a `FIXME` in the RTL. The mode-legality check itself (`CPHA == CPOL`) is correct. | `GRPR-SPIM-001`, `-016` |
| `SPIM-ISSUE-015` | **`STATUS` level fields are misplaced and stubbed.** `TX_LEVEL`/`RX_LEVEL` are declared 3 bits wide and tied to zero, landing at bits [5:3]/[8:6] instead of the specified [9:5]/[14:10]. The reset value `0x0A` is correct. | Register map |
| `SPIM-ISSUE-016` | **`CTRL` reset value is `0x0000_03FC`, not `0x0000_0000`** — `ctrl_clk_div` resets to `'1` (255), giving a 31.25 kHz reset SCK rather than the 4 MHz default of `GRPR-SPIM-013`. Defensible as a safe power-on default, but it contradicts both the register map and the performance target; one of the three must change. | Register map, `GRPR-SPIM-013` |
| `SPIM-ISSUE-017` | **`DATA` writes push only 1 byte**, not the 1–4 the `DATA` register table allows. | Register map |
| `SPIM-ISSUE-018` | **Neither FIFO-overrun nor FIFO-underrun during a transfer is detected.** `INT.OVERRUN` is set only for an AHB write to a full TX FIFO and `INT.UNDERRUN` only for an AHB read of an empty RX FIFO. The in-transfer cases named in the `IRQ_STATUS` table — RX byte arriving with the RX FIFO full, TX byte needed with the TX FIFO empty — are unimplemented, and `spi_m_rx`'s `received` output is left dangling in `spi_m_core`. | Register map |
| `SPIM-ISSUE-019` | **`ADDR` register writes ignore the byte strobes**, unlike `CTRL`/`CMD`/`INT` which all qualify on `byte_select_r[0]`. A sub-word write to `ADDR` updates all 32 bits. | Register map |
| `SPIM-ISSUE-020` | **The register block aliases every 32 bytes** across its 4 KiB window — only `HADDR[4:2]` is decoded. Harmless today, but it should be a stated decision rather than an accident. | Register map |
| `SPIM-ISSUE-021` | **Reserved-offset reads return 0 without an error response**, while reserved-offset *writes* assert `HRESP`. Asymmetric and unspecified. | `GRPR-SPIM-001` |
| `SPIM-ISSUE-022` | **No FIFO flush path.** `flush_tx_fifo`/`flush_rx_fifo` are tied to `1'b0`, so there is no way to recover a known-good state after an overrun, underrun, or aborted transfer. No flush control is defined in this spec either — see `SPIM-SPEC-007`. | Register map |

### Non-conformances to stated design intent

| ID | Issue | Affects |
|---|---|---|
| `SPIM-ISSUE-023` | **The shift-register width is not actually configurable.** `DATA_WIDTH` exists as a parameter, but `ahb_spi_m` hardcodes `.DATA_WIDTH(8)` and `spi_m_tx` contains 8-bit literals (`8'h00`) and fixed slices (`addr_shift[31:24]`), so no other width will elaborate correctly. | `GRPR-SPIM-011` |
| `SPIM-ISSUE-024` | **Reset style differs from this spec.** The RTL uses an asynchronous active-low reset (`always_ff @(posedge clk or negedge rst_n)`); the Reset Strategy section says synchronous. The RTL matches the SoC's async-assert / sync-release scheme, so **this specification is the side that is wrong** — see `SPIM-SPEC-002`. | Reset Strategy |
| `SPIM-ISSUE-025` | **The SCK divider free-runs and is never restarted at transaction start**, so the interval between `CS_N` assertion and the first SCK edge is arbitrary (0 to `CLKDIV` system clocks). `CS_N` also deasserts one system clock after the last data bit, giving no CS hold time. Both matter for a real APS6404L and for `GRPR-SPIM-INFO-001`. No CS timing is specified — see `SPIM-SPEC-005`. | `GRPR-SPIM-INFO-001` |
| `SPIM-ISSUE-026` | **Dead code:** the `CLK_DIV_BITS` and `SPI_DATA_W` localparams in `ahb_spi_m` are unused. | — |

### Specification defects and gaps

Issues with **this document**, found while cross-checking the RTL. These need the block owner's decision before the RTL can be judged conformant.

| ID | Item |
|---|---|
| `SPIM-SPEC-001` | **`OVERRUN` and `UNDERRUN` are defined twice with conflicting meanings.** The `IRQ_STATUS` table defines them as in-transfer FIFO events (RX full on arrival / TX empty on demand); the `DATA` table defines them as AHB-side access errors (read of empty RX / write to full TX). Both are useful, but they cannot share two bits. Either rename and split into four bits, or pick one definition. |
| `SPIM-SPEC-002` | **Reset Strategy says "synchronous reset"** but the SoC uses asynchronous assertion with synchronised release (`hw/rtl/common/sync.sv` at the top level). Correct the text to async-assert / sync-release. |
| `SPIM-SPEC-003` | **FIFO depth is never stated.** The RTL uses 4 entries, yet `STATUS.TX_LEVEL`/`RX_LEVEL` are 5-bit fields implying a depth of at least 16. Fix the depth as a requirement and size the level fields to match. |
| `SPIM-SPEC-004` | **No requirement that each byte occupy exactly 8 SCK cycles**, nor that a phase ends only after the final bit's sampling edge. Obvious in principle, but `SPIM-ISSUE-003` shipped precisely because there was no checkable statement of it. Add it and give it a verification item. |
| `SPIM-SPEC-005` | **No `CS_N` timing requirements** — setup before the first SCK edge, hold after the last, minimum deassertion between transfers, and whether `CS_N` may stay low across back-to-back transactions. |
| `SPIM-SPEC-006` | **The MISO sampling edge is not specified per mode.** State explicitly which SCK edge samples MISO and which launches MOSI for mode 0 and mode 3. |
| `SPIM-SPEC-007` | **No FIFO flush or transfer-abort mechanism** is defined, so there is no specified recovery from `OVERRUN`/`UNDERRUN`/`CFG_ERR`, and no defined behaviour if reset is asserted mid-transfer. |
| `SPIM-SPEC-008` | **The AHB error-response protocol is not specified** — that `SLVERR` is the two-cycle `HREADYOUT`-low-then-high response, and the full list of accesses that produce it (illegal `CPOL`/`CPHA`, writes to read-only `STATUS`, reserved offsets, and whether reads to reserved offsets error). |
| `SPIM-SPEC-009` | **Behaviour when the TX FIFO holds fewer than `DATA_LEN+1` bytes at `START` is undefined** — does the transfer stall waiting for the CPU, or run to completion emitting a fill pattern? The FIFO is 4 deep and `DATA_LEN` can reach 256, so this is the normal case, not an edge case. |
| `SPIM-SPEC-010` | **Duplicate and missing requirement IDs.** `GRPR-SPIM-005` is used for two different requirements (MSB-first serialisation, and command translation). `GRPR-SPIM-004` is referenced in Open Items and the Verification Cross-Reference but is never defined — the Pico item is tagged `GRPR-SPIM-INFO-001`. `GRPR-SPIM-014` does not exist. |
| `SPIM-SPEC-011` | **`GRPR-SPIM-005` says data is transmitted "on the MISO port".** A master transmits on MOSI. |
| `SPIM-SPEC-012` | **Register naming is inconsistent.** The register map calls offset `0x0C` `INT`; its own section heading calls it `IRQ_STATUS`. The `CTRL` field is `IE_COMPLETE` but the interrupt equation refers to `CTRL.IE_DONE`, and `CTRL` bit 14's description refers to `INT.TXN_COMPLETE` while `INT` bit 0 is named `DONE`. Pick one name per object. |

### Suggested repair order

1. Gate the phase FSM on `spi_clk_en` and end a byte only on the final sampling edge (`SPIM-ISSUE-001`/`-002`/`-003`/`-004`). This one change fixes the missing opcode, the 7-bit bytes, and the hang.
2. Make `CMD.START` a self-clearing single-cycle pulse (`SPIM-ISSUE-005`).
3. Gate `spi_m_rx` on the data phase and `DIR`, sample once per SCK period on the CPOL/CPHA-correct edge (`SPIM-ISSUE-007`/`-008`).
4. Fix the FIFO off-by-ones on both TX and RX (`SPIM-ISSUE-010`/`-011`).
5. Fix the address phase byte selection and count (`SPIM-ISSUE-012`) and the dummy-cycle rate (`SPIM-ISSUE-006`).
6. Fix the AHB `HWDATA` capture phase (`SPIM-ISSUE-013`), then the error response (`SPIM-ISSUE-014`).
7. Resolve `SPIM-SPEC-001`, `-003`, `-004`, `-005`, `-009` before writing the directed tests, since each determines an expected value.

Directed transaction tests must land alongside these fixes, and `spi_m` needs adding to `.github/sim-ci-targets.yaml` — every defect above except `SPIM-ISSUE-023`/`-026` would have been caught by a single test that checks the MOSI byte stream against an expected `SPI_READ` waveform.
