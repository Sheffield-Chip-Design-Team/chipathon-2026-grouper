# SRAM Controller

Memory block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Will start from HelloSoC Base RTL
---

## Function

Single-Port SRAM Controller for the GF180MCD RAM macro.
+ Implement Zero page switching logic
+ Should be configurable to be able to be used with different RAM macros.

---

---


---

## SRAM macro path

---

## Verification

FIXME 

| Test | Method | Pass criterion |
| --- | --- | --- |
| Write + read back | cocotb: write known pattern, read back | Byte-identical |
| Arbiter priority | FFT + PicoRV32 simultaneous | FFT gets grant; PicoRV32 stalls then gets access |
| Full address range | Sweep all 136K words | No stuck bits |
| Capture region isolation | Write capture data; run FFT | FFT staging (0x00000–0x3FFFF) unaffected |
| Guarded capture window | Inject preamble with random offset | Frozen window contains `timing_ref-M/2` through `timing_ref+8.5M-1` |

---

## Related blocks

- [PicoRV32 Integration](PicoRV32%20Integration.md) — firmware access + capture region

- [System Architecture](../System%20Diagram.md) — area estimate; OpenRAM action item
