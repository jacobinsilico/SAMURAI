// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// gives us the `FF(...) macro making it easy to have properly defined flip-flops
`include "common_cells/registers.svh"

// Matrix buffers for the systolic-array accelerator.
//
// Stores:
//   A: ARRAY_ROWS x K_DIM
//   B: K_DIM x ARRAY_COLS
//   C: ARRAY_ROWS x ARRAY_COLS
//
// Linear address layout:
//   A[row, k] = A[row*K_DIM + k]
//   B[k, col] = B[k*ARRAY_COLS + col]
//   C[row, col] = C[row*ARRAY_COLS + col]
//
// During computation, this module generates the skewed A/B streams expected by
// user_systolic_array:
//   A[row, k] enters row `row` at cycle k + row
//   B[k, col] enters col `col` at cycle k + col
module user_buffers #(
  /// Input operand width, e.g. 16 for INT16.
  parameter int unsigned DATA_WIDTH = 16,
  /// Accumulator/output width, e.g. 32 for INT16 x INT16 accumulation.
  parameter int unsigned ACC_WIDTH  = 32,

  /// Number of systolic-array rows / A rows / C rows.
  parameter int unsigned ARRAY_ROWS = 4,
  /// Number of systolic-array columns / B columns / C columns.
  parameter int unsigned ARRAY_COLS = 4,
  /// Reduction dimension: A is MxK, B is KxN.
  parameter int unsigned K_DIM      = 4,

  /// Derived buffer sizes.
  parameter int unsigned A_ELEMS = ARRAY_ROWS * K_DIM,
  parameter int unsigned B_ELEMS = K_DIM * ARRAY_COLS,
  parameter int unsigned C_ELEMS = ARRAY_ROWS * ARRAY_COLS,

  /// Derived address widths.
  parameter int unsigned A_ADDR_WIDTH = (A_ELEMS > 1) ? $clog2(A_ELEMS) : 1,
  parameter int unsigned B_ADDR_WIDTH = (B_ELEMS > 1) ? $clog2(B_ELEMS) : 1,
  parameter int unsigned C_ADDR_WIDTH = (C_ELEMS > 1) ? $clog2(C_ELEMS) : 1,

  /// Enough bits to index all systolic compute/drain cycles.
  parameter int unsigned COMPUTE_STEP_WIDTH =
      (K_DIM + ARRAY_ROWS + ARRAY_COLS > 1) ? $clog2(K_DIM + ARRAY_ROWS + ARRAY_COLS) : 1
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  // ---------------------------------------------------------------------------
  // CPU/register-side access to A buffer
  // ---------------------------------------------------------------------------

  input  logic                              cpu_a_we_i,
  input  logic [A_ADDR_WIDTH-1:0]           cpu_a_addr_i,
  input  logic signed [DATA_WIDTH-1:0]      cpu_a_wdata_i,
  output logic signed [DATA_WIDTH-1:0]      cpu_a_rdata_o,

  // ---------------------------------------------------------------------------
  // CPU/register-side access to B buffer
  // ---------------------------------------------------------------------------

  input  logic                              cpu_b_we_i,
  input  logic [B_ADDR_WIDTH-1:0]           cpu_b_addr_i,
  input  logic signed [DATA_WIDTH-1:0]      cpu_b_wdata_i,
  output logic signed [DATA_WIDTH-1:0]      cpu_b_rdata_o,

  // ---------------------------------------------------------------------------
  // CPU/register-side access to C buffer
  // ---------------------------------------------------------------------------

  input  logic                              cpu_c_we_i,
  input  logic [C_ADDR_WIDTH-1:0]           cpu_c_addr_i,
  input  logic signed [ACC_WIDTH-1:0]       cpu_c_wdata_i,
  output logic signed [ACC_WIDTH-1:0]       cpu_c_rdata_o,

  /// Clear the whole C buffer.
  input  logic                              c_clear_i,

  // ---------------------------------------------------------------------------
  // Accelerator-side interface
  // ---------------------------------------------------------------------------

  /// Current systolic compute step, driven by user_fsm.
  input  logic [COMPUTE_STEP_WIDTH-1:0]     compute_step_i,

  /// Skewed A streams to the left side of user_systolic_array.
  output logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] a_stream_o,
  /// Skewed B streams to the top side of user_systolic_array.
  output logic signed [ARRAY_COLS-1:0][DATA_WIDTH-1:0] b_stream_o,
  /// Valid signals for A streams.
  output logic [ARRAY_ROWS-1:0]             valid_stream_o,

  /// Final C values from the systolic array.
  input  logic signed [ARRAY_ROWS-1:0][ARRAY_COLS-1:0][ACC_WIDTH-1:0] array_c_i,
  /// Store all final C values into the C buffer.
  input  logic                              array_c_we_i
);

  // Internal storage.
  logic signed [A_ELEMS-1:0][DATA_WIDTH-1:0] a_d, a_q;
  logic signed [B_ELEMS-1:0][DATA_WIDTH-1:0] b_d, b_q;
  logic signed [C_ELEMS-1:0][ACC_WIDTH-1:0]  c_d, c_q;

  // ---------------------------------------------------------------------------
  // Buffer write/update logic
  // ---------------------------------------------------------------------------

  always_comb begin
    a_d = a_q;
    b_d = b_q;
    c_d = c_q;

    // CPU writes.
    if (cpu_a_we_i) begin
      a_d[cpu_a_addr_i] = cpu_a_wdata_i;
    end

    if (cpu_b_we_i) begin
      b_d[cpu_b_addr_i] = cpu_b_wdata_i;
    end

    if (cpu_c_we_i) begin
      c_d[cpu_c_addr_i] = cpu_c_wdata_i;
    end

    // Clear C buffer before a new multiplication if desired.
    if (c_clear_i) begin
      c_d = '0;
    end

    // Capture final systolic-array outputs into C buffer.
    if (array_c_we_i) begin
      for (int unsigned row = 0; row < ARRAY_ROWS; row++) begin
        for (int unsigned col = 0; col < ARRAY_COLS; col++) begin
          c_d[row*ARRAY_COLS + col] = array_c_i[row][col];
        end
      end
    end
  end

  `FF(a_q, a_d, '0)
  `FF(b_q, b_d, '0)
  `FF(c_q, c_d, '0)

  // ---------------------------------------------------------------------------
  // CPU/register-side reads
  // ---------------------------------------------------------------------------

  assign cpu_a_rdata_o = a_q[cpu_a_addr_i];
  assign cpu_b_rdata_o = b_q[cpu_b_addr_i];
  assign cpu_c_rdata_o = c_q[cpu_c_addr_i];

  // ---------------------------------------------------------------------------
  // Skewed stream generation for systolic array
  // ---------------------------------------------------------------------------

  for (genvar row = 0; row < ARRAY_ROWS; row++) begin : gen_a_stream
    always_comb begin
      a_stream_o[row]     = '0;
      valid_stream_o[row] = 1'b0;

      // A[row, k] enters at compute step k + row.
      if ((compute_step_i >= row) && (compute_step_i < row + K_DIM)) begin
        a_stream_o[row]     = a_q[row*K_DIM + int'(compute_step_i - row)];
        valid_stream_o[row] = 1'b1;
      end
    end
  end

  for (genvar col = 0; col < ARRAY_COLS; col++) begin : gen_b_stream
    always_comb begin
      b_stream_o[col] = '0;

      // B[k, col] enters at compute step k + col.
      if ((compute_step_i >= col) && (compute_step_i < col + K_DIM)) begin
        b_stream_o[col] = b_q[int'(compute_step_i - col)*ARRAY_COLS + col];
      end
    end
  end

endmodule