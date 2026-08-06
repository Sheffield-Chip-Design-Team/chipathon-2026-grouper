# Project Schedule

Tapeout deadline: **1 September 2026**. Design review: **July 2026**. Today: **17 May 2026**.

See [Chipathon 2026](Chipathon%202026.md) for official phase definitions.

---

```mermaid
gantt
    title Grouper SoC — Tapeout Schedule
    dateFormat  YYYY-MM-DD
    axisFormat  %d %b

    section Milestones
    Team kickoff                         :milestone, m1, 2026-05-09, 0d
    Phase 1 close (project defined)      :milestone, m_p1, 2026-05-31, 0d
    Phase 2 close (blocks implemented)   :milestone, m_p2, 2026-06-30, 0d
    Design review (Phase 3)              :milestone, crit, m2, 2026-07-01, 0d
    FPGA validation pass                 :milestone, m3,     2026-08-10, 0d
    GDS freeze (Phase 4)                 :milestone, crit, m4, 2026-09-01, 0d

    section Control Plane
    AHB-Lite 2-Master Bus                :cp1,  2026-05-24, 10d
    CPU Subsystem (PicoRV32)             :crit, cp2, 2026-05-18, 21d
    IRQ Controller                       :cp3,  2026-05-23, 7d
    SPI Master (→ SX1257)                :cp4,  2026-05-17, 21d
    SPI Slave (Host Interface)           :cp5,  2026-05-17, 21d
    AHB UART (Host Interface)            :cp6,  2026-06-15, 14d
    JTAG TAP (PicoRV32 Debug)            :cp7,  2026-07-01, 14d
```

---

