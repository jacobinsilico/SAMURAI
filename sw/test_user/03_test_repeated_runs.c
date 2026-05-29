// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Repeated-run test for user systolic-array accelerator.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"

#define M_DIM 2
#define N_DIM 2
#define K_DIM 2

#ifndef USER_DESIGN_BASE_ADDR
#define USER_DESIGN_BASE_ADDR 0x20001000UL
#endif

#define SA_CTRL_OFFSET    0x000
#define SA_STATUS_OFFSET  0x004
#define SA_CONFIG0_OFFSET 0x008
#define SA_CONFIG1_OFFSET 0x00c

#define SA_A_BASE_OFFSET  0x100
#define SA_B_BASE_OFFSET  0x400
#define SA_C_BASE_OFFSET  0x800

#define SA_STATUS_BUSY_MASK 0x1
#define SA_STATUS_DONE_MASK 0x2

static inline void sa_write_a(uint32_t row, uint32_t k, int16_t value)
{
    uint32_t idx = row * K_DIM + k;
    *reg32(USER_DESIGN_BASE_ADDR, SA_A_BASE_OFFSET + 4 * idx) = (uint32_t)((uint16_t)value);
}

static inline void sa_write_b(uint32_t k, uint32_t col, int16_t value)
{
    uint32_t idx = k * N_DIM + col;
    *reg32(USER_DESIGN_BASE_ADDR, SA_B_BASE_OFFSET + 4 * idx) = (uint32_t)((uint16_t)value);
}

static inline int32_t sa_read_c(uint32_t row, uint32_t col)
{
    uint32_t idx = row * N_DIM + col;
    return (int32_t)(*reg32(USER_DESIGN_BASE_ADDR, SA_C_BASE_OFFSET + 4 * idx));
}

static void matmul_sw(
    int16_t a[M_DIM][K_DIM],
    int16_t b[K_DIM][N_DIM],
    int32_t c[M_DIM][N_DIM]
) {
    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            int32_t acc = 0;
            for (uint32_t k = 0; k < K_DIM; k++) {
                acc += (int32_t)a[i][k] * (int32_t)b[k][j];
            }
            c[i][j] = acc;
        }
    }
}

static void sa_write_matrices(
    int16_t a[M_DIM][K_DIM],
    int16_t b[K_DIM][N_DIM]
) {
    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t k = 0; k < K_DIM; k++) {
            sa_write_a(i, k, a[i][k]);
        }
    }

    for (uint32_t k = 0; k < K_DIM; k++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            sa_write_b(k, j, b[k][j]);
        }
    }
}

static uint32_t sa_run_and_read(
    int32_t c_hw[M_DIM][N_DIM]
) {
    uint32_t timeout;

    // Start accelerator.
    *reg32(USER_DESIGN_BASE_ADDR, SA_CTRL_OFFSET) = 0x1;

    // Poll done bit.
    timeout = 100000;
    while (((*reg32(USER_DESIGN_BASE_ADDR, SA_STATUS_OFFSET) & SA_STATUS_DONE_MASK) == 0) && timeout) {
        timeout--;
    }

    if (timeout == 0) {
        printf("ERROR: accelerator timeout\n");
        return 1;
    }

    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            c_hw[i][j] = sa_read_c(i, j);
        }
    }

    return 0;
}

static uint32_t compare_results(
    const char *label,
    int32_t c_sw[M_DIM][N_DIM],
    int32_t c_hw[M_DIM][N_DIM]
) {
    uint32_t errors = 0;

    printf("%s\n", label);

    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            printf("C[%x][%x]: SW=0x%x HW=0x%x\n",
                   i, j, (uint32_t)c_sw[i][j], (uint32_t)c_hw[i][j]);

            if (c_sw[i][j] != c_hw[i][j]) {
                errors++;
            }
        }
    }

    return errors;
}

int main(void)
{
    uart_init();

    int16_t a0[M_DIM][K_DIM] = {
        {1, 2},
        {3, 4}
    };

    int16_t b0[K_DIM][N_DIM] = {
        {5, 6},
        {7, 8}
    };

    int16_t a1[M_DIM][K_DIM] = {
        {2, 0},
        {0, 2}
    };

    int16_t b1[K_DIM][N_DIM] = {
        {1, 3},
        {4, 5}
    };

    int32_t c0_sw[M_DIM][N_DIM];
    int32_t c0_hw[M_DIM][N_DIM];

    int32_t c1_sw[M_DIM][N_DIM];
    int32_t c1_hw[M_DIM][N_DIM];

    uint32_t t0, t1, t2;
    uint32_t errors = 0;

    printf("Testing repeated systolic array accelerator runs\n");

    uint32_t cfg0 = *reg32(USER_DESIGN_BASE_ADDR, SA_CONFIG0_OFFSET);
    uint32_t cfg1 = *reg32(USER_DESIGN_BASE_ADDR, SA_CONFIG1_OFFSET);

    printf("CONFIG0: 0x%x\n", cfg0);
    printf("CONFIG1: 0x%x\n", cfg1);

    // Software reference timing for both matrix multiplications.
    t0 = get_mcycle();

    matmul_sw(a0, b0, c0_sw);
    matmul_sw(a1, b1, c1_sw);

    t1 = get_mcycle();

    // Hardware timing includes writing inputs, starting accelerator, polling,
    // and reading outputs for both runs.
    sa_write_matrices(a0, b0);
    if (sa_run_and_read(c0_hw)) {
        uart_write_flush();
        return 1;
    }

    sa_write_matrices(a1, b1);
    if (sa_run_and_read(c1_hw)) {
        uart_write_flush();
        return 1;
    }

    t2 = get_mcycle();

    errors += compare_results("Run 0 results:", c0_sw, c0_hw);
    errors += compare_results("Run 1 results:", c1_sw, c1_hw);

    printf("Software cycles: 0x%x\n", t1 - t0);
    printf("Hardware cycles: 0x%x\n", t2 - t1);

    if (errors == 0) {
        printf("Systolic array repeated test PASSED\n");
    } else {
        printf("Systolic array repeated test FAILED with 0x%x errors\n", errors);
    }

    uart_write_flush();

    return errors;
}