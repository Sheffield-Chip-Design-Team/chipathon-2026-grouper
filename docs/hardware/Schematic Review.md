
````markdown

Grouper SoC (A12) — Schematic Review Notes
Extracted from the Grouper Schematic Review deck. Diagrams are described in text rather than reproduced.

Boot Sequence (Section 3a)
Large on-chip non-volatile memory is not feasible, so code is stored externally and loaded into RAM after Power-on-Reset.

UART was chosen as the peripheral for loading code, as the team anticipated it would be simpler to configure in a small handwritten boot ROM than a SPI or QSPI with a flash or PSRAM chip. Either of those options could be used after the initial program code is loaded.

A Bank Switch Reset is implemented as a PCPI custom instruction for the PICORV32 core. It swaps the RAM and ROM memory regions.

Diagram — Boot flow (vertical flowchart):

Power on Reset (pink box) →
Core starts executing from boot ROM (at address 0x0001_0000) →
Boot ROM loads in program over UART →
Bank Switch Reset (yellow box) →
Program Execution from RAM
SoC Memory Map (Section 3b)
Start Address	End Address	Size	Description
0x0000_1000	0x0000_1FFF	4kiB	*ROM
0x0000_2000	0x0000_2FFF	4kiB	*RAM
0x0000_3000	0x0000_3FFF	4kiB	UART
0x0000_4000	0x0000_4FFF	4kiB	GPIO CTRL
0x0000_5000	0x0000_5FFF	4kiB	QSPI
0x0000_6000	0x0000_6FFF	4kiB	SPI M
0x0001_0000	0x0001_FFFF	64kiB	External peripheral
* The bank switch reset instruction swaps the ROM and RAM regions. The ROM region (0x0000_1000) is highlighted as the Reset Vector.

Interconnect Structure (Section 3b — Interconnect Design)
2-Level, single-master interconnect.

L1 Fabric — A register stage used to break up the long combinatorial path between the CPU address bus and the RAM address line.
L2 Fabric — An AHB-Lite decoder for the rest of the peripherals.
Diagram — Interconnect block diagram (top-to-bottom):

Top row of masters/memories: 1024 x 32b SRAM, Bootloader ROM, and RV32EMC CPU (PicoRV32) (the single master, shown in green).
These feed down into the Memory Bus / L1 Fabric block.
Below that, the single master (M) connects to the AHB-Lite Decoder / L2 Fabric block, which fans out to multiple slave (S) ports for the peripherals.
Block Level Design Summary (Section 4)
Current status:

Finalising Functional Requirements, IOs, CDC, Clock and Reset Requirements, and area estimates for each peripheral (Block Level Design Checklist).
Starting RTL design for the SPI M, SPI S and QSPI peripherals.
TODO:

Detailed Requirements Review
GPIO MUX design
Trial Synthesis for individual blocks
Diagram — Example: SPI M Block Diagram: A block diagram of the SPI Master peripheral. On the left is the AHB-Lite CPU Bus interface, with numerous control/data signals entering the core logic block. Internal sub-blocks include:

Registers (SR_TARGET, SR_ADDR, SR_DATA, SR_CTRL — start & busy)
FSM (IDLE, CS_SETUP, TRANSFER, DONE states)
Clock divider (16MHz → xMHz)
Bit counter
MISO Latch (captures data on a rising CLK edge)
Outputs on the right side are the SPI interface signals (MOSI, SCK, CS, MISO).

Verification Summary (Section 5)
Block Level: VIP (Verification IP) development has begun — UART, AHB and SPI are currently in progress.

Top Level: A "hello world" SoC directed test for the top-level chip currently exists, exercising the UART, RAM, ROM and CPU and validating the software build flow (quick start in repo).

Diagram — Block Level Testbench Architecture: A set of five per-peripheral testbenches, each following the same pattern: a VIP connected to the DUT (Device Under Test), an AHB VIP, and a Scoreboard collecting results.

SPI Slave Testbench — SPI VIP (Passive) ↔ SPI S (DUT) ↔ AHB VIP (Active)
SPI Master Testbench — SPI VIP (Active) ↔ SPI M (DUT) ↔ AHB VIP (Active)
QSPI Testbench — QSPI VIP (Active) ↔ QSPI (DUT) ↔ AHB VIP (Active)
GPIO Testbench — GPIO VIP (Active) ↔ GPIO CTRL (DUT) ↔ AHB VIP (Active)
UART Testbench — UART VIP (Active) ↔ UART (DUT) ↔ AHB VIP (Active)
Diagram — Top-Level Testbench Architecture: A full-SoC testbench wrapping the complete chip. The core SoC (SRAM, Bootloader ROM, RV32EMC CPU, Memory Bus / L1 Fabric, and the AHB-Lite Decoder / L2 Fabric) sits in the centre. Surrounding it are the verification components:

Clock + Reset Control (CLK, RST) and an Interrupt Checker / Interrupt Interface at the top.
An External AHB-Lite Interface with an AHB VIP (Passive) on the left.
Peripherals (SPI S, SPI M, QSPI, UART) each connected to their respective VIPs on the right, routed through GPIO IO MUX and MUX CTRL blocks.














# Grouper SoC – A12: Block-Level Design Checklists

Block-level schematic review covering the AHB peripherals of the Grouper SoC.
Peripherals in scope (per the title slide):

- AHB UART
- AHB GPIO Multiplexer
- AHB SPI Master
- AHB SPI Slave
- AHB QSPI

---

## 1. AHB UART

- **Purpose** — *(not yet documented)*
- **Protocols / Standards Conformity** — *(not yet documented)*
- **Key Functionality** — *(not yet documented)*
- **Block Diagram** — *(not yet documented)*
- **Parameters and Configurations** — *(not yet documented)*
- **IOs and External Interfaces** — *(not yet documented)*
- **Clocking Strategy** — *(not yet documented)*
- **Reset Strategy** — *(not yet documented)*
- **CDC Strategy** — *(not yet documented)*
- **Performance Targets** — *(not yet documented)*
- **Size Estimate** — *(not yet documented)*

---

## 2. AHB GPIO Multiplexer

- Hosts a programmable 2-stage synchroniser on each input.


## 3. AHB SPI Master

**Purpose**
SPI master peripheral that lets the PicoRV32 CPU configure and control external
SX1257 transceivers over SPI, via an AHB-Lite slave interface.

**Protocols / Standards Conformity**
- AHB-Lite on the CPU side.
- SPI mode 0, MSB-first on the SX1257 side.
- Reference: APS6404L datasheet (SPI mode).

**Key Functionality**
- Receives read/write commands from the CPU over AHB-Lite.
- Translates commands into SPI transactions (as defined in the APS6404L datasheet).
- Supports `SPI_READ`, `FAST_READ`, `SPI_WRITE`, `FAST_WRITE`.
- Drives the correct SX1257 device; supports both read and write transactions.
- Exposes a busy flag to the CPU.
- CPOL + CPHA shall be programmable (mode 0 or mode 3).

**Block Diagram**
- Micro-architecture based on a shift register (one or two shift registers).

**Parameters and Configurations**
- SCK divider generating 4 MHz from 32 MHz (÷8); max 10 MHz.
- Configurable shift-register width.
- Programmable clock divider + CPOL + CPHA.

**IOs and External Interfaces**
- Grouped logically (AHB-Lite, SPI external, control/status).
- Additional IRQs may be added later.

**Clocking Strategy**
- Single clock domain.
- SCK generated by dividing `clk_32` (32 MHz) by 8.

**Reset Strategy**
- `rst_n` active-low synchronous reset.

**CDC Strategy**
- Fully synchronous design.
- MISO is sampled on rising HCK; needs a 2-stage synchroniser (located inside the
  GPIO MUX), so this block does not handle it directly.

**Performance Targets**
- 4 MHz SPI clock default, 10 MHz max.
- 16-bit transaction time measured at 4 MHz.

**Size Estimate**
- 1,500 – 2,000 gate equivalents (GE).

---

## 4. AHB SPI Slave

**Purpose**
SPI slave interface that lets an external SPI master communicate with the SoC
through the AHB-Lite bus.

**Protocols / Standards Conformity**
- AHB-Lite on the CPU side.
- Custom SPI slave interface on the external side (CPHA/CPOL mode 0/3, MSB-first).
- Reference: APS6404L datasheet.

**Key Functionality**
- Receives and transmits data over the SPI interface; data is accessible through
  the AHB-Lite bus.
- Supports `SPI_READ`, `FAST_READ`, `SPI_WRITE`, `FAST_WRITE`.

**Block Diagram**
Main blocks: Shift Register, Register Bank, AHB Bus Logic, Command FSM Control.
Firmware-load path signals: `SS`, `fw_ld_addr`, `fw_ld_wdata`, `fw_ld_we`, etc.

**Parameters and Configurations**
- 4 kB allocated memory block.
- Data transferred byte-by-byte.
- Hardware controlled by reading/writing registers.

**IOs and External Interfaces**
- AHB-Lite bus interface plus the external SPI slave pins.

**Clocking Strategy**
- Single system clock (`clk`) for everything.

**Reset Strategy**
- Active-low reset (`rst_n`) clears and restarts the design and stops any ongoing
  SPI transfer.

**CDC Strategy**
- Not needed (single clock domain).

**Performance Targets**
- SPI clock speeds up to 10 MHz.
- Firmware-load throughput up to 1.25 MB/s.
- Receives one payload byte every 0.8 µs at maximum SPI clock.

**Size Estimate**
- TBD.

---

## 5. AHB QSPI

**Purpose**
AHB-Lite-controlled QPI master compatible with the APS6404L PSRAM and Micron
N25Q032A NOR flash (read-only). Provides external memory for storing, reading,
and replaying incoming I/Q sample data.

**Protocols / Standards Conformity**
- AMBA 3 AHB-Lite interface on the SoC side.
- Micron N25Q032A (SPI, Quad).
- APS6404L PSRAM — boots in SPI mode, then configured for quad mode.
- Normal transfers use four-bit QPI mode.
- Boot flow: starts in SPI, then configured by the CPU.
  - NOR flash bypasses the serial-monitor code loading.
  - PSRAM extends the default serial-monitor boot flow.

**Key Functionality**
- Single and Quad SPI support.
- Manual command execution with read-back (single command/data/control register)
  for write and read.
- Programmable clock divider (+ CPHA/CPOL, likely mode 0/3 only).
- Configuration bit for single/quad SPI mode.
- Configuration fields for read command (8-bit) and write command (8-bit).
- Configuration bit to enable AHB writes to flash (in the AHB wrapper).
- Fast-read dummy-cycle count configuration field.

**Block Diagram**
Main blocks: Control/Status Registers, Init + QPI Transaction FSM, Buffer/Address
Control, Command/Address Data Path, SCK + SIO Direction Control.
External connections via the GPIO I/O MUX to the APS6404L PSRAM and NOR flash.
Key signals: `qspi_ce_n`, `qspi_sck`, `qspi_sio_i/o/oe[3:0]`; device pins
`CE#`, `SCK`, `SIO[3:0]`; plus I/Q samples with `iq_valid`.

**IOs and External Interfaces**
- **AHB-Lite interface** — CPU bus with control/status signals.
- **Core command interface:**
  - `cmd_en` — asserts chip enable for the duration of a transaction
  - `cmd_read` — 1-cycle pulse
  - `cmd_write` — 1-cycle pulse
  - `cmd_wdata[7:0]`
  - `cmd_rdata[7:0]`
  - `cmd_ready`
- **External QSPI interface** — three four-bit SIO buses connect through the GPIO
  mux onto the same four physical bidirectional `SIO[3:0]` pins.

**Parameters and Configurations**
- APS6404L interface:
  - Capacity: 64 Mbit / 8 MB
  - Addressing: 23-bit byte address
  - Data interface: four-bit QPI
  - Target QPI clock: 32 MHz
  - Memory refresh handled internally by the PSRAM
- Status reporting: `INIT_DONE`, `BUF_ACTIVE`, `REPLAY_ACTIVE`, `REPLAY_MISSED`,
  `OVERFLOW`, `SAMPLE_SKIP`.

**Clocking Strategy**
- QSPI control and transfer logic run from the 32 MHz `IQ_CLK`.
- QSPI SCK runs at 32 MHz during memory transfers; SCK remains low while idle.

**Reset Strategy**
- Single reset, active-low async assert / sync de-assert.
- ~500 kHz SCK at startup with synchronisers enabled for reliable transfers
  (frequency can be raised and the 2-FF synchroniser disabled for better performance).

**CDC Strategy**
- Single clock domain with optional input synchronisers (handled externally in the
  GPIO Mux).
- Cross-domain controls are registered or handshaked.
- Standard asynchronous synchronisers not needed while clocks remain phase-aligned.

**Performance Targets**
- QPI clock: 32 MHz.
- Raw four-bit link bandwidth: 16 MB/s.
- Continuous-write requirement: 2 MB/s.
- Initialisation time: ≤ 1 ms.
- Write + delayed read: 44 of 64 cycles.
- Write + replay read: 56 of 64 cycles.
- Required storage: ~256 kB; available: 8 MB (≥ 32× capacity margin).
- No skipped samples or buffer overflow during supported operation.

**Size Estimate**
- TBD after RTL synthesis.
````