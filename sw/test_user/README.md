# User Accelerator Test Suite

This directory contains software tests for the memory-mapped systolic-array accelerator in the Croc user domain.

The accelerator is currently tested with a 4x4 systolic array using 16-bit signed operands and 32-bit accumulation, unless stated otherwise.

## Tests

### 01 — Basic 2x2 Test

Checks a simple 2x2 matrix multiplication with small positive values.

Purpose:

* Basic accelerator smoke test.
* Verifies CPU writes to A/B buffers.
* Verifies accelerator start/done behavior.
* Verifies CPU reads from C buffer.

### 02 — Negative INT16 Test

Checks signed 16-bit input behavior using positive and negative values.

Purpose:

* Verifies signed multiplication.
* Verifies signed accumulation.
* Verifies sign extension from INT16 operands into INT32 results.

### 03 — Repeated Runs Test

Runs two matrix multiplications back-to-back.

Purpose:

* Verifies that PE accumulators are cleared correctly.
* Verifies that the C buffer is overwritten correctly.
* Verifies that the FSM can restart cleanly after finishing.

### 04 — Basic 4x4 Test

Checks a full 4x4 matrix multiplication with mixed positive, negative, and zero values.

Purpose:

* Verifies full-size 4x4 operation.
* Verifies buffer indexing for larger matrices.
* Verifies the systolic dataflow across the complete array.

### 05 — Zero Matrices Test

Checks cases where either A or B is a zero matrix.

Purpose:

* Verifies that zero inputs produce zero outputs.
* Verifies that stale accumulator or buffer values do not leak into new results.

### 06 — Identity Matrix Test

Checks both `A * I = A` and `I * A = A`.

Purpose:

* Verifies row/column placement.
* Verifies B-buffer indexing.
* Helps catch transposition or matrix-layout mistakes.

### 07 — INT16 Accumulation Stress Test

Uses large INT16 values close to the signed INT32 accumulation limit.

Purpose:

* Verifies `INT16 x INT16 -> INT32` accumulation.
* Tests both large positive and large negative accumulated results.
* Confirms that the accumulator width is sufficient for near-limit cases.

## Notes

All tests compare hardware results against software reference results or known expected values.

Most tests also print software and hardware cycle counts for rough performance comparison. These cycle counts include software overhead such as writing input buffers, starting the accelerator, polling status, and reading output buffers.
