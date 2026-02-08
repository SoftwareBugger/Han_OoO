# HanOoO — Out-of-Order RV32I RISC-V SoC

HanOoO is a **from-scratch RV32I out-of-order RISC-V processor** integrated into a small SoC and running real bare-metal C firmware on FPGA.  
The design focuses on **microarchitectural correctness**, precise state, and end-to-end hardware/software integration.

This is an **educational microarchitecture project**, not a production CPU.

---

## Key Features

### Core Microarchitecture
- RV32I baseline ISA
- Out-of-order execution, in-order commit
- Register renaming with physical register file (PRF)
- Reservation stations with wakeup/select
- Reorder buffer (ROB) for precise state
- ROB-based recovery on branch mispredicts and flushes
- Conservative load policy (no speculative replay)
- Store-at-commit policy for memory correctness

### SoC Integration
- Memory-mapped I/O (MMIO) bus
- UART TX/RX peripheral
- SPI controller with MISO support
- Boot ROM + application memory layout
- Bare-metal firmware toolchain

### FPGA Demonstration
- Implemented on FPGA using BRAM and PLL IP
- Runs interactive C firmware
- Drives SPI OLED display
- Accepts UART input
- Demonstrates a simple Dino runner game

---

## Architecture Overview

![OoO Core Diagram](OoO_RV32I.drawio.png)

---

## SoC Block Overview
    +------------------+
    |   OoO RV32I CPU  |
    |  (rename, ROB,   |
    |   RS, LSU, BRU)  |
    +---------+--------+
              |
          MMIO/DMEM
              |
    +---------+-----------+
    |                     |
    +----+----+ +----+----+
    | UART    | | SPI     |
    | TX / RX | | OLED    |
    +---------+ +---------+


---

## Memory Map

| Address Range           | Region               |
|-------------------------|----------------------|
| 0x0000_0000–0x0000_5FFF | .text, .data, .bss   |
| 0x0000_6000–0x0000_7FFF | Stack                |
| 0x8000_0000–0x8000_0014 | SPI controller       |
| 0x8000_1000–0x8000_100C | UART controller      |

See:
- `app.ld`
- `crt0.S`

for boot and memory layout details.

---

## Firmware Demo

The SoC runs bare-metal C programs.  
The main demonstration is a **Dino runner game**:

- UART input controls the dinosaur
- SPI OLED displays graphics
- Partial screen updates for efficiency
- Collision detection and game-over state

This demonstrates:

- CPU correctness
- MMIO interaction
- Peripheral control
- Real-time firmware execution

---

## Design Goals

This project was built to understand and implement:

- Register renaming and physical register tracking
- Out-of-order issue and execution
- Precise architectural state via ROB commit
- Correct memory ordering policies
- Full stack: CPU → SoC → peripherals → firmware

---

## Current Status

- OoO core functional
- SoC with UART and SPI peripherals
- Bare-metal firmware running on FPGA
- Interactive graphics demo

---

## Future Work (optional)
- AXI-Lite peripheral interface
- Instruction/data caches
- Branch predictor improvements
- CDC analysis and synchronizers

---

## License
Educational and research use.



