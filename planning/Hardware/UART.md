# AHB UART (Host Interface)

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Design:** Sam
**Verification **
**Status:** RTL Written, Awaiting Randomized Self-checking bench
---

## Function

Configurable AHB UART IP.

---

## Interface

TODO

---

## Protocol

TODO

---

## Integration Guide notes

**Clock and Reset** 

TODO

**Clock domain crossings** 

TODO

**Error Responses ** 

TODO

---

## Verification Strategy

TODO

---

## Related blocks

- [Register Map](../Register%20Map.md) — authoritative plan-of-record memory map set for GrouperSoC

- [PicoRV32 Integration](PicoRV32%20Integration.md) — unified 4 kB CPU SRAM target for firmware load; `CPU_RESET` register

- [AHB-Lite Bus](AHB-Lite%20Bus.md) — internal bus for register access
