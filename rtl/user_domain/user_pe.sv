// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// gives us the `FF(...) and `FFL(...) macros making it easy to have properly defined flip-flops
`include "common_cells/registers.svh"

// One processing element of the systolic array.
// Forwards A to the right, forwards B downward, and accumulates A*B locally.
module user_pe #(
  /// Input operand width, e.g. 16 for INT16.
  parameter int unsigned DATA_WIDTH = 16,
  /// Accumulator width, e.g. 32 for INT16 x INT16 accumulation.
  parameter int unsigned ACC_WIDTH  = 32
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  /// Synchronously clears the local accumulator.
  input  logic clear_i,
  /// Advances the PE by one systolic step.
  input  logic enable_i,
  /// Input operands are valid in this cycle.
  input  logic valid_i,

  /// Operand A input, propagated horizontally.
  input  logic signed [DATA_WIDTH-1:0] a_i,
  /// Operand B input, propagated vertically.
  input  logic signed [DATA_WIDTH-1:0] b_i,

  /// Registered A output to the PE on the right.
  output logic signed [DATA_WIDTH-1:0] a_o,
  /// Registered B output to the PE below.
  output logic signed [DATA_WIDTH-1:0] b_o,
  /// Registered valid output to neighbouring PEs.
  output logic                     valid_o,

  /// Current accumulated result of this PE.
  output logic signed [ACC_WIDTH-1:0]  c_o
);

  // Make sure sign extension is well-defined.
  localparam int unsigned PROD_W = 2 * DATA_WIDTH;

  logic signed [DATA_WIDTH-1:0] a_d, a_q;
  logic signed [DATA_WIDTH-1:0] b_d, b_q;
  logic                     valid_d, valid_q;

  logic signed [ACC_WIDTH-1:0]  acc_d, acc_q;

  logic signed [PROD_W-1:0] product;
  logic signed [ACC_WIDTH-1:0]  product_ext;

  assign product = a_i * b_i;

  // This assumes ACC_WIDTH >= 2*DATA_WIDTH, e.g. INT16 * INT16 -> INT32.
  assign product_ext = {{(ACC_WIDTH-PROD_W){product[PROD_W-1]}}, product};

  always_comb begin
    a_d     = a_q;
    b_d     = b_q;
    valid_d = valid_q;
    acc_d   = acc_q;

    if (enable_i) begin
      a_d     = a_i;
      b_d     = b_i;
      valid_d = valid_i;

      if (valid_i) begin
        acc_d = acc_q + product_ext;
      end
    end

    if (clear_i) begin
      acc_d = '0;
    end
  end

  `FF(a_q,     a_d,     '0)
  `FF(b_q,     b_d,     '0)
  `FF(valid_q, valid_d, 1'b0)
  `FF(acc_q,   acc_d,   '0)

  assign a_o     = a_q;
  assign b_o     = b_q;
  assign valid_o = valid_q;
  assign c_o     = acc_q;

endmodule