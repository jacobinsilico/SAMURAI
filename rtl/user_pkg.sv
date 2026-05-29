// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

`include "obi/typedef.svh"

package user_pkg;

  //////////////////
  // User Manager //
  //////////////////

  // None


  ///////////////////////
  // User Subordinates //
  ///////////////////////

  // The base address of the user domain can be retrieved from `croc_pkg::UserBaseAddr`.
  // Recommended: place subordinates at 4KB boundaries, i.e. 32'hXXXX_X000.

  localparam bit [31:0] UserRomBaseAddr    = croc_pkg::UserBaseAddr + 32'h0000_0000;
  localparam bit [31:0] UserDesignBaseAddr = croc_pkg::UserBaseAddr + 32'h0000_1000;
  
  // I added these parameters so we can parametrize systolic array in one place
  localparam int unsigned UserArrayRows = 4;
  localparam int unsigned UserArrayCols = 4;
  localparam int unsigned UserKDim      = 4;
  /// Enum with user-domain demultiplexer subordinate indices.
  typedef enum int {
    UserError  = 0,
    UserRom    = 1,
    UserDesign = 2
  } user_demux_outputs_e;

  /// Address rules given to the user-domain demultiplexer.
  localparam croc_pkg::addr_map_rule_t [1:0] user_addr_map = '{
    '{
      idx:        UserRom,
      start_addr: UserRomBaseAddr,
      end_addr:   UserRomBaseAddr + 32'h0000_1000
    },
    '{
      idx:        UserDesign,
      start_addr: UserDesignBaseAddr,
      end_addr:   UserDesignBaseAddr + 32'h0000_1000
    }
  };

  // All addresses outside the defined address rules go to the error subordinate.
  // +1 for additional OBI error subordinate.
  localparam int unsigned NumDemuxSbr = $size(user_addr_map) + 1;

endpackage