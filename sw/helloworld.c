// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"

int main() {

    // setup the UART peripheral
    uart_init();
    // the upper bound in the loop below needs to be changed depending on how many words we read from ROM
    printf("Reading eight 32-bit words from ROM:\n");
    for (int i = 0; i < 32; i++) {
        uint32_t word = *reg32(USER_ROM_BASE_ADDR, i * 4);
        printf("%c", word);
    }
    printf("\n");

    // wait until uart has finished sending
    uart_write_flush();

    return 0;
}
