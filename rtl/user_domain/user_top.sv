// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// gives us the `FF(...) macro making it easy to have properly defined flip-flops
`include "common_cells/registers.svh"

// Top-level user design.
//
// Internal address map, relative to croc_pkg::UserBaseAddr:
//
//   0x0000 - 0x0fff: user_rom
//   0x1000 - 0x1fff: systolic-array accelerator registers/buffers
module user_top #(
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
  parameter int unsigned C_ADDR_WIDTH = (C_ELEMS > 1) ? $clog2(C_ELEMS) : 1,

  /// Enough bits to count all systolic compute/drain cycles.
  parameter int unsigned COMPUTE_STEP_WIDTH =
      (K_DIM + ARRAY_ROWS + ARRAY_COLS > 1) ? $clog2(K_DIM + ARRAY_ROWS + ARRAY_COLS) : 1
) (
  /// Clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,

  /// OBI request interface
  input  obi_req_t obi_req_i,
  /// OBI response interface
  output obi_rsp_t obi_rsp_o
);

  // ---------------------------------------------------------------------------
  // Internal OBI routing
  // ---------------------------------------------------------------------------

  typedef enum logic [1:0] {
    RSP_ROM,
    RSP_ACCEL,
    RSP_ERROR
  } rsp_sel_e;

  obi_req_t rom_obi_req;
  obi_rsp_t rom_obi_rsp;

  obi_req_t accel_obi_req;
  obi_rsp_t accel_obi_rsp;

  rsp_sel_e rsp_sel_d, rsp_sel_q;

  logic invalid_req_d, invalid_req_q;
  logic [ObiCfg.IdWidth-1:0] invalid_id_d, invalid_id_q;

  logic sel_rom;
  logic sel_accel;
  logic sel_error;

  // Decode using bits [15:12], i.e. 4 KiB windows.
  assign sel_rom   = obi_req_i.req && (obi_req_i.a.addr[15:12] == 4'h0);
  assign sel_accel = obi_req_i.req && (obi_req_i.a.addr[15:12] == 4'h1);
  assign sel_error = obi_req_i.req && !(sel_rom || sel_accel);

  always_comb begin
    rom_obi_req       = obi_req_i;
    accel_obi_req     = obi_req_i;

    rom_obi_req.req   = sel_rom;
    accel_obi_req.req = sel_accel;
  end

  always_comb begin
    rsp_sel_d = RSP_ERROR;

    if (sel_rom) begin
      rsp_sel_d = RSP_ROM;
    end else if (sel_accel) begin
      rsp_sel_d = RSP_ACCEL;
    end
  end

  assign invalid_req_d = sel_error;
  assign invalid_id_d  = obi_req_i.a.aid;

  `FF(rsp_sel_q,     rsp_sel_d,     RSP_ERROR)
  `FF(invalid_req_q, invalid_req_d, 1'b0)
  `FF(invalid_id_q,  invalid_id_d,  '0)

  // ---------------------------------------------------------------------------
  // Accelerator interconnect
  // ---------------------------------------------------------------------------

  logic start;
  logic busy;
  logic done;

  logic [COMPUTE_STEP_WIDTH-1:0] compute_step;

  logic array_clear;
  logic array_enable;
  logic c_clear;
  logic array_c_we;

  logic                         cpu_a_we;
  logic [A_ADDR_WIDTH-1:0]      cpu_a_addr;
  logic signed [DATA_WIDTH-1:0] cpu_a_wdata;
  logic signed [DATA_WIDTH-1:0] cpu_a_rdata;

  logic                         cpu_b_we;
  logic [B_ADDR_WIDTH-1:0]      cpu_b_addr;
  logic signed [DATA_WIDTH-1:0] cpu_b_wdata;
  logic signed [DATA_WIDTH-1:0] cpu_b_rdata;

  logic                        cpu_c_we;
  logic [C_ADDR_WIDTH-1:0]     cpu_c_addr;
  logic signed [ACC_WIDTH-1:0] cpu_c_wdata;
  logic signed [ACC_WIDTH-1:0] cpu_c_rdata;

  logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] a_stream;
  logic signed [ARRAY_COLS-1:0][DATA_WIDTH-1:0] b_stream;
  logic [ARRAY_ROWS-1:0] valid_stream;

  logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] unused_a_out;
  logic signed [ARRAY_COLS-1:0][DATA_WIDTH-1:0] unused_b_out;
  logic [ARRAY_ROWS-1:0][ARRAY_COLS-1:0] unused_valid_out;

  logic signed [ARRAY_ROWS-1:0][ARRAY_COLS-1:0][ACC_WIDTH-1:0] array_c;

  // ---------------------------------------------------------------------------
  // User ROM
  // ---------------------------------------------------------------------------

  user_rom #(
    .ObiCfg    ( ObiCfg    ),
    .obi_req_t ( obi_req_t ),
    .obi_rsp_t ( obi_rsp_t )
  ) i_user_rom (
    .clk_i     ( clk_i       ),
    .rst_ni    ( rst_ni      ),
    .obi_req_i ( rom_obi_req ),
    .obi_rsp_o ( rom_obi_rsp )
  );

  // ---------------------------------------------------------------------------
  // Register interface
  // ---------------------------------------------------------------------------

  user_regs #(
    .ObiCfg             ( ObiCfg             ),
    .obi_req_t          ( obi_req_t          ),
    .obi_rsp_t          ( obi_rsp_t          ),
    .DATA_WIDTH         ( DATA_WIDTH         ),
    .ACC_WIDTH          ( ACC_WIDTH          ),
    .ARRAY_ROWS         ( ARRAY_ROWS         ),
    .ARRAY_COLS         ( ARRAY_COLS         ),
    .K_DIM              ( K_DIM              ),
    .A_ELEMS            ( A_ELEMS            ),
    .B_ELEMS            ( B_ELEMS            ),
    .C_ELEMS            ( C_ELEMS            ),
    .A_ADDR_WIDTH       ( A_ADDR_WIDTH       ),
    .B_ADDR_WIDTH       ( B_ADDR_WIDTH       ),
    .C_ADDR_WIDTH       ( C_ADDR_WIDTH       )
  ) i_user_regs (
    .clk_i         ( clk_i         ),
    .rst_ni        ( rst_ni        ),

    .obi_req_i     ( accel_obi_req ),
    .obi_rsp_o     ( accel_obi_rsp ),

    .start_o       ( start         ),
    .busy_i        ( busy          ),
    .done_i        ( done          ),

    .cpu_a_we_o    ( cpu_a_we      ),
    .cpu_a_addr_o  ( cpu_a_addr    ),
    .cpu_a_wdata_o ( cpu_a_wdata   ),
    .cpu_a_rdata_i ( cpu_a_rdata   ),

    .cpu_b_we_o    ( cpu_b_we      ),
    .cpu_b_addr_o  ( cpu_b_addr    ),
    .cpu_b_wdata_o ( cpu_b_wdata   ),
    .cpu_b_rdata_i ( cpu_b_rdata   ),

    .cpu_c_we_o    ( cpu_c_we      ),
    .cpu_c_addr_o  ( cpu_c_addr    ),
    .cpu_c_wdata_o ( cpu_c_wdata   ),
    .cpu_c_rdata_i ( cpu_c_rdata   )
  );

  // ---------------------------------------------------------------------------
  // Buffers
  // ---------------------------------------------------------------------------

  user_buffers #(
    .DATA_WIDTH         ( DATA_WIDTH         ),
    .ACC_WIDTH          ( ACC_WIDTH          ),
    .ARRAY_ROWS         ( ARRAY_ROWS         ),
    .ARRAY_COLS         ( ARRAY_COLS         ),
    .K_DIM              ( K_DIM              ),
    .A_ELEMS            ( A_ELEMS            ),
    .B_ELEMS            ( B_ELEMS            ),
    .C_ELEMS            ( C_ELEMS            ),
    .A_ADDR_WIDTH       ( A_ADDR_WIDTH       ),
    .B_ADDR_WIDTH       ( B_ADDR_WIDTH       ),
    .C_ADDR_WIDTH       ( C_ADDR_WIDTH       ),
    .COMPUTE_STEP_WIDTH ( COMPUTE_STEP_WIDTH )
  ) i_user_buffers (
    .clk_i          ( clk_i        ),
    .rst_ni         ( rst_ni       ),

    .cpu_a_we_i     ( cpu_a_we     ),
    .cpu_a_addr_i   ( cpu_a_addr   ),
    .cpu_a_wdata_i  ( cpu_a_wdata  ),
    .cpu_a_rdata_o  ( cpu_a_rdata  ),

    .cpu_b_we_i     ( cpu_b_we     ),
    .cpu_b_addr_i   ( cpu_b_addr   ),
    .cpu_b_wdata_i  ( cpu_b_wdata  ),
    .cpu_b_rdata_o  ( cpu_b_rdata  ),

    .cpu_c_we_i     ( cpu_c_we     ),
    .cpu_c_addr_i   ( cpu_c_addr   ),
    .cpu_c_wdata_i  ( cpu_c_wdata  ),
    .cpu_c_rdata_o  ( cpu_c_rdata  ),

    .c_clear_i      ( c_clear      ),

    .compute_step_i ( compute_step ),
    .a_stream_o     ( a_stream     ),
    .b_stream_o     ( b_stream     ),
    .valid_stream_o ( valid_stream ),

    .array_c_i      ( array_c      ),
    .array_c_we_i   ( array_c_we   )
  );

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------

  user_fsm #(
    .ARRAY_ROWS         ( ARRAY_ROWS         ),
    .ARRAY_COLS         ( ARRAY_COLS         ),
    .K_DIM              ( K_DIM              ),
    .COMPUTE_STEP_WIDTH ( COMPUTE_STEP_WIDTH )
  ) i_user_fsm (
    .clk_i          ( clk_i        ),
    .rst_ni         ( rst_ni       ),

    .start_i        ( start        ),

    .compute_step_o ( compute_step ),

    .array_clear_o  ( array_clear  ),
    .array_enable_o ( array_enable ),

    .c_clear_o      ( c_clear      ),
    .array_c_we_o   ( array_c_we   ),

    .busy_o         ( busy         ),
    .done_o         ( done         )
  );

  // ---------------------------------------------------------------------------
  // Systolic array datapath
  // ---------------------------------------------------------------------------

  user_systolic_array #(
    .DATA_WIDTH ( DATA_WIDTH ),
    .ACC_WIDTH  ( ACC_WIDTH  ),
    .ARRAY_ROWS ( ARRAY_ROWS ),
    .ARRAY_COLS ( ARRAY_COLS )
  ) i_user_systolic_array (
    .clk_i    ( clk_i            ),
    .rst_ni   ( rst_ni           ),

    .clear_i  ( array_clear      ),
    .enable_i ( array_enable     ),

    .valid_i  ( valid_stream     ),

    .a_i      ( a_stream         ),
    .b_i      ( b_stream         ),

    .a_o      ( unused_a_out     ),
    .b_o      ( unused_b_out     ),

    .valid_o  ( unused_valid_out ),
    .c_o      ( array_c          )
  );

  // ---------------------------------------------------------------------------
  // Top-level OBI response mux
  // ---------------------------------------------------------------------------

  always_comb begin
    obi_rsp_o = '0;

    // We accept every request immediately and return either the selected
    // subordinate response or an error response one cycle later.
    obi_rsp_o.gnt = obi_req_i.req;

    unique case (rsp_sel_q)

      RSP_ROM: begin
        obi_rsp_o.rvalid = rom_obi_rsp.rvalid;
        obi_rsp_o.r      = rom_obi_rsp.r;
      end

      RSP_ACCEL: begin
        obi_rsp_o.rvalid = accel_obi_rsp.rvalid;
        obi_rsp_o.r      = accel_obi_rsp.r;
      end

      default: begin
        obi_rsp_o.rvalid       = invalid_req_q;
        obi_rsp_o.r.rdata      = 32'hBADCAB1E;
        obi_rsp_o.r.rid        = invalid_id_q;
        obi_rsp_o.r.err        = invalid_req_q;
        obi_rsp_o.r.r_optional = '0;
      end

    endcase
  end

endmodule