// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// gives us the `FF(...) macro making it easy to have properly defined flip-flops
`include "common_cells/registers.svh"

// Memory-mapped register interface for the systolic-array accelerator.
//
// Register map, relative to this module's 4 KiB window:
//
//   0x000: CTRL
//          write bit 0 = start
//
//   0x004: STATUS
//          bit 0 = busy
//          bit 1 = done
//
//   0x008: CONFIG0
//          bits [7:0]   = DATA_WIDTH
//          bits [15:8]  = ACC_WIDTH
//
//   0x00c: CONFIG1
//          bits [7:0]   = ARRAY_ROWS
//          bits [15:8]  = ARRAY_COLS
//          bits [23:16] = K_DIM
//
//   0x100: A buffer, one 32-bit word per DATA_WIDTH element
//   0x400: B buffer, one 32-bit word per DATA_WIDTH element
//   0x800: C buffer, one 32-bit word per ACC_WIDTH element
module user_regs #(
  /// The OBI configuration for all ports.
  parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
  /// The request struct.
  parameter type obi_req_t = logic,
  /// The response struct.
  parameter type obi_rsp_t = logic,

  /// Input operand width.
  parameter int unsigned DATA_WIDTH = 16,
  /// Accumulator/output width.
  parameter int unsigned ACC_WIDTH  = 32,

  /// Number of systolic-array rows.
  parameter int unsigned ARRAY_ROWS = 4,
  /// Number of systolic-array columns.
  parameter int unsigned ARRAY_COLS = 4,
  /// Reduction dimension.
  parameter int unsigned K_DIM      = 4,

  /// Derived buffer sizes.
  parameter int unsigned A_ELEMS = ARRAY_ROWS * K_DIM,
  parameter int unsigned B_ELEMS = K_DIM * ARRAY_COLS,
  parameter int unsigned C_ELEMS = ARRAY_ROWS * ARRAY_COLS,

  /// Derived address widths.
  parameter int unsigned A_ADDR_WIDTH = (A_ELEMS > 1) ? $clog2(A_ELEMS) : 1,
  parameter int unsigned B_ADDR_WIDTH = (B_ELEMS > 1) ? $clog2(B_ELEMS) : 1,
  parameter int unsigned C_ADDR_WIDTH = (C_ELEMS > 1) ? $clog2(C_ELEMS) : 1
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  /// OBI request interface
  input  obi_req_t obi_req_i,
  /// OBI response interface
  output obi_rsp_t obi_rsp_o,

  /// One-cycle start pulse to user_fsm.
  output logic start_o,

  /// Status from user_fsm.
  input  logic busy_i,
  input  logic done_i,

  /// CPU/register-side access to A buffer.
  output logic                         cpu_a_we_o,
  output logic [A_ADDR_WIDTH-1:0]      cpu_a_addr_o,
  output logic signed [DATA_WIDTH-1:0] cpu_a_wdata_o,
  input  logic signed [DATA_WIDTH-1:0] cpu_a_rdata_i,

  /// CPU/register-side access to B buffer.
  output logic                         cpu_b_we_o,
  output logic [B_ADDR_WIDTH-1:0]      cpu_b_addr_o,
  output logic signed [DATA_WIDTH-1:0] cpu_b_wdata_o,
  input  logic signed [DATA_WIDTH-1:0] cpu_b_rdata_i,

  /// CPU/register-side access to C buffer.
  output logic                        cpu_c_we_o,
  output logic [C_ADDR_WIDTH-1:0]     cpu_c_addr_o,
  output logic signed [ACC_WIDTH-1:0] cpu_c_wdata_o,
  input  logic signed [ACC_WIDTH-1:0] cpu_c_rdata_i
);

  // This simple register map assumes one matrix element fits in one OBI word.
  initial begin
    assert (DATA_WIDTH <= ObiCfg.DataWidth)
      else $error("DATA_WIDTH must be <= OBI data width.");
    assert (ACC_WIDTH <= ObiCfg.DataWidth)
      else $error("ACC_WIDTH must be <= OBI data width.");
  end

  localparam int unsigned WORD_ADDR_WIDTH = 10; // 4 KiB / 4 B = 1024 words

  localparam int unsigned REG_CTRL_WORD   = 10'h000;
  localparam int unsigned REG_STATUS_WORD = 10'h001;
  localparam int unsigned REG_CFG0_WORD   = 10'h002;
  localparam int unsigned REG_CFG1_WORD   = 10'h003;

  localparam int unsigned A_BASE_WORD = 10'h040; // 0x100 / 4
  localparam int unsigned B_BASE_WORD = 10'h100; // 0x400 / 4
  localparam int unsigned C_BASE_WORD = 10'h200; // 0x800 / 4

  logic [WORD_ADDR_WIDTH-1:0] word_addr;

  logic ctrl_access;
  logic status_access;
  logic cfg0_access;
  logic cfg1_access;
  logic a_access;
  logic b_access;
  logic c_access;

  logic req_d, req_q;
  logic [ObiCfg.IdWidth-1:0] id_d, id_q;

  logic [ObiCfg.DataWidth-1:0] rsp_data_d, rsp_data_q;
  logic rsp_err_d, rsp_err_q;

  assign word_addr = obi_req_i.a.addr[11:2];

  assign ctrl_access   = (word_addr == REG_CTRL_WORD);
  assign status_access = (word_addr == REG_STATUS_WORD);
  assign cfg0_access   = (word_addr == REG_CFG0_WORD);
  assign cfg1_access   = (word_addr == REG_CFG1_WORD);

  assign a_access =
      (word_addr >= A_BASE_WORD[WORD_ADDR_WIDTH-1:0]) &&
      (word_addr <  (A_BASE_WORD + A_ELEMS)[WORD_ADDR_WIDTH-1:0]);

  assign b_access =
      (word_addr >= B_BASE_WORD[WORD_ADDR_WIDTH-1:0]) &&
      (word_addr <  (B_BASE_WORD + B_ELEMS)[WORD_ADDR_WIDTH-1:0]);

  assign c_access =
      (word_addr >= C_BASE_WORD[WORD_ADDR_WIDTH-1:0]) &&
      (word_addr <  (C_BASE_WORD + C_ELEMS)[WORD_ADDR_WIDTH-1:0]);

  // ---------------------------------------------------------------------------
  // Buffer-side access
  // ---------------------------------------------------------------------------

  assign cpu_a_we_o    = obi_req_i.req && obi_req_i.a.we && a_access;
  assign cpu_a_addr_o  = word_addr - A_BASE_WORD[WORD_ADDR_WIDTH-1:0];
  assign cpu_a_wdata_o = obi_req_i.a.wdata[DATA_WIDTH-1:0];

  assign cpu_b_we_o    = obi_req_i.req && obi_req_i.a.we && b_access;
  assign cpu_b_addr_o  = word_addr - B_BASE_WORD[WORD_ADDR_WIDTH-1:0];
  assign cpu_b_wdata_o = obi_req_i.a.wdata[DATA_WIDTH-1:0];

  assign cpu_c_we_o    = obi_req_i.req && obi_req_i.a.we && c_access;
  assign cpu_c_addr_o  = word_addr - C_BASE_WORD[WORD_ADDR_WIDTH-1:0];
  assign cpu_c_wdata_o = obi_req_i.a.wdata[ACC_WIDTH-1:0];

  // Start pulse. The FSM decides whether to accept it depending on its state.
  assign start_o = obi_req_i.req && obi_req_i.a.we && ctrl_access && obi_req_i.a.wdata[0];

  // ---------------------------------------------------------------------------
  // Response generation
  // ---------------------------------------------------------------------------

  assign req_d = obi_req_i.req;
  assign id_d  = obi_req_i.a.aid;

  always_comb begin
    rsp_data_d = '0;
    rsp_err_d  = 1'b0;

    if (obi_req_i.req) begin
      if (obi_req_i.a.we) begin
        // Legal writes: CTRL, A, B, C.
        if (!(ctrl_access || a_access || b_access || c_access)) begin
          rsp_err_d = 1'b1;
        end
      end else begin
        // Legal reads.
        if (ctrl_access) begin
          rsp_data_d = '0;
        end else if (status_access) begin
          rsp_data_d      = '0;
          rsp_data_d[0]   = busy_i;
          rsp_data_d[1]   = done_i;
        end else if (cfg0_access) begin
          rsp_data_d       = '0;
          rsp_data_d[7:0]  = DATA_WIDTH[7:0];
          rsp_data_d[15:8] = ACC_WIDTH[7:0];
        end else if (cfg1_access) begin
          rsp_data_d          = '0;
          rsp_data_d[7:0]     = ARRAY_ROWS[7:0];
          rsp_data_d[15:8]    = ARRAY_COLS[7:0];
          rsp_data_d[23:16]   = K_DIM[7:0];
        end else if (a_access) begin
          rsp_data_d = ObiCfg.DataWidth'($signed(cpu_a_rdata_i));
        end else if (b_access) begin
          rsp_data_d = ObiCfg.DataWidth'($signed(cpu_b_rdata_i));
        end else if (c_access) begin
          rsp_data_d = ObiCfg.DataWidth'($signed(cpu_c_rdata_i));
        end else begin
          rsp_err_d = 1'b1;
        end
      end
    end
  end

  `FF(req_q,      req_d,      1'b0)
  `FF(id_q,       id_d,       '0)
  `FF(rsp_data_q, rsp_data_d, '0)
  `FF(rsp_err_q,  rsp_err_d,  1'b0)

  // A channel
  assign obi_rsp_o.gnt = obi_req_i.req;

  // R channel
  assign obi_rsp_o.rvalid       = req_q;
  assign obi_rsp_o.r.rdata      = rsp_data_q;
  assign obi_rsp_o.r.rid        = id_q;
  assign obi_rsp_o.r.err        = rsp_err_q;
  assign obi_rsp_o.r.r_optional = '0;

endmodule