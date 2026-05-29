// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// gives us the `FF(...) macro making it easy to have properly defined flip-flops
`include "common_cells/registers.svh"

// Control FSM for the systolic-array accelerator.
//
// Responsibilities:
//   - wait for a start pulse
//   - clear PE accumulators and C buffer
//   - run the systolic array for the required number of cycles
//   - store final array outputs into the C buffer
//   - expose busy/done status
module user_fsm #(
  /// Number of systolic-array rows.
  parameter int unsigned ARRAY_ROWS = 4,
  /// Number of systolic-array columns.
  parameter int unsigned ARRAY_COLS = 4,
  /// Reduction dimension.
  parameter int unsigned K_DIM      = 4,

  /// Enough bits to count all compute/drain cycles.
  parameter int unsigned COMPUTE_STEP_WIDTH =
      (K_DIM + ARRAY_ROWS + ARRAY_COLS > 1) ? $clog2(K_DIM + ARRAY_ROWS + ARRAY_COLS) : 1
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  /// One-cycle start pulse from user_regs.
  input  logic start_i,

  /// Current systolic compute step, connected to user_buffers.
  output logic [COMPUTE_STEP_WIDTH-1:0] compute_step_o,

  /// Clears PE accumulators in user_systolic_array.
  output logic array_clear_o,
  /// Advances user_systolic_array by one cycle.
  output logic array_enable_o,

  /// Clears C buffer in user_buffers.
  output logic c_clear_o,
  /// Stores final array C outputs into C buffer.
  output logic array_c_we_o,

  /// Accelerator is currently running.
  output logic busy_o,
  /// Accelerator has finished and result is available.
  output logic done_o
);

  typedef enum logic [2:0] {
    IDLE,
    CLEAR,
    COMPUTE,
    STORE,
    DONE
  } state_e;

  // Last cycle on which the array must be enabled.
  // Last useful multiply occurs at:
  //   t = (K_DIM - 1) + (ARRAY_ROWS - 1) + (ARRAY_COLS - 1)
  localparam int unsigned LAST_COMPUTE_STEP =
      K_DIM + ARRAY_ROWS + ARRAY_COLS - 3;

  state_e state_d, state_q;

  logic [COMPUTE_STEP_WIDTH-1:0] step_d, step_q;

  // ---------------------------------------------------------------------------
  // Next-state and counter logic
  // ---------------------------------------------------------------------------

  always_comb begin
    state_d = state_q;
    step_d  = step_q;

    unique case (state_q)

      IDLE: begin
        step_d = '0;

        if (start_i) begin
          state_d = CLEAR;
        end
      end

      CLEAR: begin
        step_d  = '0;
        state_d = COMPUTE;
      end

      COMPUTE: begin
        if (step_q == COMPUTE_STEP_WIDTH'(LAST_COMPUTE_STEP)) begin
          step_d  = '0;
          state_d = STORE;
        end else begin
          step_d = step_q + 1'b1;
        end
      end

      STORE: begin
        step_d  = '0;
        state_d = DONE;
      end

      DONE: begin
        step_d = '0;

        // Allow immediate restart with another start pulse.
        if (start_i) begin
          state_d = CLEAR;
        end
      end

      default: begin
        state_d = IDLE;
        step_d  = '0;
      end

    endcase
  end

  `FF(state_q, state_d, IDLE)
  `FF(step_q,  step_d,  '0)

  // ---------------------------------------------------------------------------
  // Output logic
  // ---------------------------------------------------------------------------

  assign compute_step_o = step_q;

  assign array_clear_o  = (state_q == CLEAR);
  assign c_clear_o      = (state_q == CLEAR);

  assign array_enable_o = (state_q == COMPUTE);

  assign array_c_we_o   = (state_q == STORE);

  assign busy_o         = (state_q == CLEAR) || (state_q == COMPUTE) || (state_q == STORE);
  assign done_o         = (state_q == DONE);

endmodule