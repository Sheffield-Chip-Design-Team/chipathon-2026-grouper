
### Feature overview/Use Case information (INFO)

#### Master enable and independent TX/RX enables

- `CTRL.ENABLE` is the block's master gate, gating the clock divider that provides baud ticks.
- `TX_EN` and `RX_EN` gate each direction independently.
- `TX_EN`/`RX_EN` leave the divider running, so the block still sees baud ticks.
- Dropping `TX_EN` parks `uart_tx` at the idle mark.
- Dropping `ENABLE` freezes the tick itself holds whatever level it was last driven to. See limitation [`L6`](#known-limitations). 
- The safe shutdown sequence is to poll `TX_ACTIVE=0` *first* and only then clear the enables — polling it after clearing `TX_EN` proves nothing, because `tx_active` is itself qualified by the transmit enable and reads 0 the moment `TX_EN` goes away.
- Neither enable touches a FIFO. With `TX_EN=0` firmware can still queue up to four bytes through `TXDATA` and they go out as soon as `TX_EN` is set; an `RX_EN=0` receiver stops capturing frames but leaves whatever is already in the RX FIFO readable. 
- Only `HRESETn` or an explicit flush clears a FIFO.

#### RX resynchronisation (`RX_RESYNC_EN`)

- The receiver phases itself on the falling edge of the start bit and then samples each bit at sample 4 of 8. 
- Across a 10-bit frame any baud mismatch between the two ends walks that sample point away from the bit centre.
- With `CTRL.RX_RESYNC_EN=1` (the reset value) the receiver watches for a `uart_rx` transition inside a ±1-sample window around each bit boundary (`sample_ctr` ∈ {7, 0, 1}) during the data and stop bits, and restarts the sample counter on it.T
- This resync feature allows at most one correction per bit, so a noisy line cannot repeatedly drag the sampling point around. The start bit is never resynced. 
- With `RX_RESYNC_EN=0` the phase is fixed for the whole frame by the start edge alone.

#### TX break generation (`TX_BREAK`)

- `CTRL.TX_BREAK` drives `uart_tx` low continuously — a space longer than a character frame, which the far end sees as a break. It is sampled only at frame boundaries.
- A break asserted mid-character lets that character finish and then takes hold.
- It is not a mid-character abort. 
- Queued bytes are not discarded while the break is asserted; they stay in the FIFO and go out after it clears. 
- On clearing, the  `CTRL.TX_BREAK`, the idle transition requires `uart_tx` to already be high, which forces at least one bit period of mark between the end of the break and the next start bit.

#### TX/RX FIFO flush (`FLUSH_TX_FIFO`, `FLUSH_RX_FIFO`)

- Both flush bits are write-1 one-shots: the write asserts the register bit for exactly one `HCLK` and it self-clears so it always reads back 0. 
- The pulse resets that FIFO's read/write pointers, its `full`/`empty` flags and its read-data register in a single cycle.
- A TX flush also inhibits the launch of a new frame on that baud tick, but it does not abort a character already in the shift register — that character completes on the wire.

#### RX break detection and sticky error flags

- `break_detect` is armed at the start-bit edge and AND-accumulated with the inverted line every baud tick, so it survives only if `uart_rx` never went high.
- A break is an all-zero character **and** a low stop bit. 
- When the stop-bit sample finds the line low with `break_detect` still set, the receiver enters a dedicated break state and stays there until the line returns high. - A break therefore always co-asserts `RX_FRAME_ERROR` — the low stop bit is a framing error in its own right — and pulses `rx_error_irq`.
- `STATUS.RX_FRAME_ERROR` and `STATUS.RX_BREAK` are sticky: set by the event, held until read. Both clear together on any `STATUS` read that selects byte lane 0. 
- Set beats clear — an event coincident with the clearing read leaves the bit set rather than losing it.
- A frame that fails either the start-bit or the stop-bit check is discarded: nothing is pushed to the RX FIFO and `rx_irq` does not pulse.

#### FIFO status reporting

`STATUS` exposes `TX_EMPTY`/`TX_FULL` and `RX_EMPTY`/`RX_FULL` straight from the two `small_sync_fifo` instances, plus `TX_ACTIVE`. These are the flow-control handles: firmware polls `TX_FULL` before writing `TXDATA` and `RX_EMPTY` before reading `RXDATA`, because getting either wrong is a bus error rather than a silent no-op.

- `TX_EMPTY` tracks the FIFO only — the transmitter pops a byte into its shift register as soon as it starts the frame, so `TX_EMPTY=1` means "nothing queued", not "nothing on the wire.
- `TX_ACTIVE` is the signal for the latter.
-  And `TX_ACTIVE` reads 0 as soon as the transmit enable is removed even if a character is still part-way out. so should be polled by firmware before touching the enables, not after.

#### Oversampling architecture (`OVERSAMPLE = 8`)

The `uart` core runs both directions from one baud tick at 8× the bit rate. The transmitter updates `uart_tx` once every 8 ticks (`sample_ctr == 0`); the receiver samples at tick 4 of 8 — the bit centre — and uses ticks 7/0/1 as its resync window. The 8× factor is why `CLK_DIV` divides to 8× the bit rate rather than to the bit rate itself (see [`GRPR-UART-010`](#parameters-and-configurations)), and it sets the receiver's static timing margin at roughly ±½ sample ≈ ±6 % of a bit period before resynchronisation is needed.