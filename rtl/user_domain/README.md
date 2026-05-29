# User Domain Systolic-Array Accelerator

This directory contains the current user-domain hardware design for a memory-mapped systolic-array accelerator integrated into Croc.

The accelerator performs matrix multiplication using signed INT16 operands and signed INT32 accumulation.

Current default configuration:

```text
DATA_WIDTH = 16
ACC_WIDTH  = 32
ARRAY_ROWS = 4
ARRAY_COLS = 4
K_DIM      = 4
```

This corresponds to:

```text
A: 4 x 4, INT16
B: 4 x 4, INT16
C: 4 x 4, INT32
```

## User-Domain Address Map

The user domain is mounted at:

```text
croc_pkg::UserBaseAddr = 0x2000_0000
```

The current user-domain subordinates are:

```text
0x2000_0000 - 0x2000_0FFF : user_rom
0x2000_1000 - 0x2000_1FFF : systolic-array accelerator
other addresses           : error subordinate
```

The address map is defined in `user_pkg.sv`.

## Accelerator Register Map

The systolic-array accelerator is mounted at:

```text
USER_DESIGN_BASE_ADDR = 0x2000_1000
```

Register offsets relative to `USER_DESIGN_BASE_ADDR`:

```text
0x000 : CTRL
0x004 : STATUS
0x008 : CONFIG0
0x00C : CONFIG1

0x100 : A buffer
0x400 : B buffer
0x800 : C buffer
```

Full addresses:

```text
0x2000_1000 : CTRL
0x2000_1004 : STATUS
0x2000_1008 : CONFIG0
0x2000_100C : CONFIG1

0x2000_1100 : A buffer base
0x2000_1400 : B buffer base
0x2000_1800 : C buffer base
```

## Control Register

Address:

```text
0x2000_1000
```

Write:

```text
bit 0 = start
```

To start the accelerator, write:

```c
*reg32(USER_DESIGN_BASE_ADDR, 0x000) = 0x1;
```

The start signal is treated as a one-cycle pulse by the hardware.

## Status Register

Address:

```text
0x2000_1004
```

Read:

```text
bit 0 = busy
bit 1 = done
```

Software should poll the done bit:

```c
while ((*reg32(USER_DESIGN_BASE_ADDR, 0x004) & 0x2) == 0) {
    // wait
}
```

## Configuration Registers

### CONFIG0

Address:

```text
0x2000_1008
```

Layout:

```text
bits [7:0]   = DATA_WIDTH
bits [15:8]  = ACC_WIDTH
```

Expected value for the current design:

```text
0x2010
```

Meaning:

```text
DATA_WIDTH = 0x10 = 16
ACC_WIDTH  = 0x20 = 32
```

### CONFIG1

Address:

```text
0x2000_100C
```

Layout:

```text
bits [7:0]   = ARRAY_ROWS
bits [15:8]  = ARRAY_COLS
bits [23:16] = K_DIM
```

Expected value for the current 4x4 design:

```text
0x40404
```

Meaning:

```text
ARRAY_ROWS = 4
ARRAY_COLS = 4
K_DIM      = 4
```

## Buffer Layout

### A Buffer

Base address:

```text
0x2000_1100
```

A is stored row-major:

```text
A[row][k] -> A_BASE + 4 * (row * K_DIM + k)
```

Example:

```c
uint32_t idx = row * K_DIM + k;
*reg32(USER_DESIGN_BASE_ADDR, 0x100 + 4 * idx) = (uint32_t)((uint16_t)value);
```

### B Buffer

Base address:

```text
0x2000_1400
```

B is stored row-major:

```text
B[k][col] -> B_BASE + 4 * (k * ARRAY_COLS + col)
```

Example:

```c
uint32_t idx = k * ARRAY_COLS + col;
*reg32(USER_DESIGN_BASE_ADDR, 0x400 + 4 * idx) = (uint32_t)((uint16_t)value);
```

### C Buffer

Base address:

```text
0x2000_1800
```

C is stored row-major:

```text
C[row][col] -> C_BASE + 4 * (row * ARRAY_COLS + col)
```

Example:

```c
uint32_t idx = row * ARRAY_COLS + col;
uint32_t result = *reg32(USER_DESIGN_BASE_ADDR, 0x800 + 4 * idx);
```

C values are signed INT32 results.

## Hardware Structure

The accelerator is split into the following modules:

```text
user_domain.sv
  ├── user_rom.sv
  ├── user_top.sv
  │    ├── user_regs.sv
  │    ├── user_buffers.sv
  │    ├── user_fsm.sv
  │    └── user_systolic_array.sv
  │         └── user_pe.sv
  └── obi_err_sbr
```

## Module Responsibilities

### `user_domain.sv`

Connects the user-domain subordinates to Croc using an OBI demultiplexer.

It routes accesses to:

```text
user_rom
user_top
error subordinate
```

### `user_pkg.sv`

Defines the user-domain address map and accelerator parameters.

Important parameters:

```systemverilog
localparam int unsigned UserDataWidth = 16;
localparam int unsigned UserAccWidth  = 32;
localparam int unsigned UserArrayRows = 4;
localparam int unsigned UserArrayCols = 4;
localparam int unsigned UserKDim      = 4;
```

### `user_rom.sv`

Small read-only memory required for the project/submission metadata.

### `user_top.sv`

Top-level accelerator wrapper.

It connects:

```text
user_regs
user_buffers
user_fsm
user_systolic_array
```

### `user_regs.sv`

Implements the memory-mapped OBI register interface.

Responsibilities:

```text
- decode control/status/config accesses
- generate the start pulse
- expose busy/done status
- provide CPU access to A, B, and C buffers
```

### `user_buffers.sv`

Stores matrix data and generates the systolic input streams.

Responsibilities:

```text
- store A matrix
- store B matrix
- store C matrix
- provide CPU read/write access
- feed skewed A/B streams into the systolic array
- capture final C results from the array
```

### `user_fsm.sv`

Controls accelerator execution.

FSM sequence:

```text
IDLE -> CLEAR -> COMPUTE -> STORE -> DONE
```

Responsibilities:

```text
- wait for start
- clear accumulators
- run compute cycles
- store final C values
- expose busy/done status
```

### `user_systolic_array.sv`

Parametrizable systolic-array datapath.

Responsibilities:

```text
- instantiate ARRAY_ROWS x ARRAY_COLS processing elements
- forward A values horizontally
- forward B values vertically
- collect C outputs from processing elements
```

### `user_pe.sv`

Single processing element.

Responsibilities:

```text
- receive A and B operands
- multiply signed INT16 operands
- accumulate into signed INT32 accumulator
- forward A to the right
- forward B downward
```

## Software Usage Pattern

A typical software sequence is:

```text
1. Write all A elements to A buffer.
2. Write all B elements to B buffer.
3. Write 1 to CTRL bit 0.
4. Poll STATUS bit 1 until done.
5. Read all C elements from C buffer.
```

Example:

```c
#define USER_DESIGN_BASE_ADDR 0x20001000UL

#define SA_CTRL_OFFSET    0x000
#define SA_STATUS_OFFSET  0x004
#define SA_A_BASE_OFFSET  0x100
#define SA_B_BASE_OFFSET  0x400
#define SA_C_BASE_OFFSET  0x800

#define SA_STATUS_DONE_MASK 0x2

// Start accelerator
*reg32(USER_DESIGN_BASE_ADDR, SA_CTRL_OFFSET) = 0x1;

// Wait for completion
while ((*reg32(USER_DESIGN_BASE_ADDR, SA_STATUS_OFFSET) & SA_STATUS_DONE_MASK) == 0) {
    // wait
}

// Read C
uint32_t result = *reg32(USER_DESIGN_BASE_ADDR, SA_C_BASE_OFFSET);
```

## Current Limitations

* Matrix dimensions are hardware parameters and cannot be changed dynamically from software.
* Changing `ARRAY_ROWS`, `ARRAY_COLS`, or `K_DIM` requires rebuilding the RTL simulation/synthesis flow.
* The current design assumes each matrix element fits in one 32-bit OBI word.
* Current intended configuration is signed INT16 input operands with signed INT32 accumulation.
* The accelerator is currently controlled by polling, not interrupts.
* The user manager/master OBI port is unused.

## Tested Behavior

The accelerator has been tested using the software tests in `sw/test_user/`.

The test suite currently covers:

```text
01 - basic 2x2 multiplication
02 - negative INT16 values
03 - repeated back-to-back runs
04 - basic 4x4 multiplication
05 - zero matrices
06 - identity matrices
07 - INT16 accumulation stress test
```

These tests verify basic datapath functionality, signed arithmetic, accumulator clearing, buffer overwrite behavior, 4x4 operation, row/column placement, and near-limit INT32 accumulation.
