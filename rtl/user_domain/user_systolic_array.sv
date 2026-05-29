// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Parametrizable systolic array datapath.
// A values enter from the left, B values enter from the top.
// Each PE forwards A to the right, B downward, and accumulates locally.
module user_systolic_array #(
  /// Input operand width, e.g. 16 for INT16.
  parameter int unsigned DATA_WIDTH = 16,
  /// Accumulator width, e.g. 32 for INT16 x INT16 accumulation.
  parameter int unsigned ACC_WIDTH  = 32,
  /// Number of PE rows.
  parameter int unsigned ARRAY_ROWS = 4,
  /// Number of PE columns.
  parameter int unsigned ARRAY_COLS = 4
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  /// Synchronously clears all PE accumulators.
  input  logic clear_i,
  /// Advances the systolic array by one cycle.
  input  logic enable_i,

  /// Valid signals for A streams entering from the left.
  input  logic [ARRAY_ROWS-1:0] valid_i,

  /// A input streams entering from the left side of the array.
  input  logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] a_i,
  /// B input streams entering from the top side of the array.
  input  logic signed [ARRAY_COLS-1:0][DATA_WIDTH-1:0] b_i,

  /// A values leaving the right side of the array, useful for debug/chaining.
  output logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] a_o,
  /// B values leaving the bottom side of the array, useful for debug/chaining.
  output logic signed [ARRAY_COLS-1:0][DATA_WIDTH-1:0] b_o,

  /// Valid outputs from each PE.
  output logic [ARRAY_ROWS-1:0][ARRAY_COLS-1:0] valid_o,

  /// Accumulated C outputs from each PE.
  output logic signed [ARRAY_ROWS-1:0][ARRAY_COLS-1:0][ACC_WIDTH-1:0] c_o
);

  // Horizontal A interconnect: one extra column for left input and right output.
  logic signed [ARRAY_ROWS-1:0][ARRAY_COLS:0][DATA_WIDTH-1:0] a_bus;

  // Vertical B interconnect: one extra row for top input and bottom output.
  logic signed [ARRAY_ROWS:0][ARRAY_COLS-1:0][DATA_WIDTH-1:0] b_bus;

  // Valid follows the A stream horizontally.
  logic [ARRAY_ROWS-1:0][ARRAY_COLS:0] valid_bus;

  // Connect left/top array boundaries.
  for (genvar row = 0; row < ARRAY_ROWS; row++) begin : gen_input_a
    assign a_bus[row][0]     = a_i[row];
    assign valid_bus[row][0] = valid_i[row];
    assign a_o[row]          = a_bus[row][ARRAY_COLS];
  end

  for (genvar col = 0; col < ARRAY_COLS; col++) begin : gen_input_b
    assign b_bus[0][col] = b_i[col];
    assign b_o[col]      = b_bus[ARRAY_ROWS][col];
  end

  // Instantiate PE grid.
  for (genvar row = 0; row < ARRAY_ROWS; row++) begin : gen_rows
    for (genvar col = 0; col < ARRAY_COLS; col++) begin : gen_cols

      user_pe #(
        .DATA_WIDTH ( DATA_WIDTH ),
        .ACC_WIDTH  ( ACC_WIDTH  )
      ) i_user_pe (
        .clk_i   ( clk_i               ),
        .rst_ni  ( rst_ni              ),

        .clear_i ( clear_i             ),
        .enable_i( enable_i            ),
        .valid_i ( valid_bus[row][col] ),

        .a_i     ( a_bus[row][col]     ),
        .b_i     ( b_bus[row][col]     ),

        .a_o     ( a_bus[row][col+1]   ),
        .b_o     ( b_bus[row+1][col]   ),
        .valid_o ( valid_bus[row][col+1] ),

        .c_o     ( c_o[row][col]       )
      );

      assign valid_o[row][col] = valid_bus[row][col+1];

    end
  end

endmodule