// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Near-overflow accumulation test for user systolic-array accelerator.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"

#define M_DIM 4
#define N_DIM 4
#define K_DIM 4

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

#define SA_STATUS_DONE_MASK 0x2

#define STRESS_VALUE 23170

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

static inline uint32_t sa_read_c_raw(uint32_t row, uint32_t col)
{
    uint32_t idx = row * N_DIM + col;
    return *reg32(USER_DESIGN_BASE_ADDR, SA_C_BASE_OFFSET + 4 * idx);
}

static uint32_t compute_expected_raw(int16_t a_val, int16_t b_val)
{
    int32_t acc = 0;

    for (uint32_t k = 0; k < K_DIM; k++) {
        acc += (int32_t)a_val * (int32_t)b_val;
    }

    return (uint32_t)acc;
}

static uint32_t compute_sw_checksum(int16_t a_val, int16_t b_val)
{
    uint32_t checksum = 0;

    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            int32_t acc = 0;

            for (uint32_t k = 0; k < K_DIM; k++) {
                acc += (int32_t)a_val * (int32_t)b_val;
            }

            checksum += (uint32_t)acc;
        }
    }

    return checksum;
}

static void write_constant_matrices(int16_t a_val, int16_t b_val)
{
    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t k = 0; k < K_DIM; k++) {
            sa_write_a(i, k, a_val);
        }
    }

    for (uint32_t k = 0; k < K_DIM; k++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            sa_write_b(k, j, b_val);
        }
    }
}

static uint32_t run_hw_and_check(uint32_t expected_raw)
{
    uint32_t timeout = 100000;
    uint32_t errors = 0;

    *reg32(USER_DESIGN_BASE_ADDR, SA_CTRL_OFFSET) = 0x1;

    while (((*reg32(USER_DESIGN_BASE_ADDR, SA_STATUS_OFFSET) & SA_STATUS_DONE_MASK) == 0) && timeout) {
        timeout--;
    }

    if (timeout == 0) {
        printf("ERROR timeout\n");
        return 1;
    }

    for (uint32_t i = 0; i < M_DIM; i++) {
        for (uint32_t j = 0; j < N_DIM; j++) {
            uint32_t hw = sa_read_c_raw(i, j);

            if (hw != expected_raw) {
                printf("Mismatch\n");
                printf("i 0x%x\n", i);
                printf("j 0x%x\n", j);
                printf("EXP 0x%x\n", expected_raw);
                printf("HW 0x%x\n", hw);
                errors++;
            }
        }
    }

    return errors;
}

int main(void)
{
    uart_init();

    uint32_t t0, t1, t2;
    uint32_t errors = 0;

    uint32_t expected_pos;
    uint32_t expected_neg;
    uint32_t sw_checksum;

    printf("Testing overflow\n");

    uint32_t cfg0 = *reg32(USER_DESIGN_BASE_ADDR, SA_CONFIG0_OFFSET);
    uint32_t cfg1 = *reg32(USER_DESIGN_BASE_ADDR, SA_CONFIG1_OFFSET);

    printf("CONFIG0: 0x%x\n", cfg0);
    printf("CONFIG1: 0x%x\n", cfg1);

    // -------------------------------------------------------------------------
    // Case 0: positive near-overflow
    // -------------------------------------------------------------------------

    printf("Case 0\n");

    t0 = get_mcycle();

    expected_pos = compute_expected_raw(STRESS_VALUE, STRESS_VALUE);
    sw_checksum  = compute_sw_checksum(STRESS_VALUE, STRESS_VALUE);

    t1 = get_mcycle();

    write_constant_matrices(STRESS_VALUE, STRESS_VALUE);
    errors += run_hw_and_check(expected_pos);

    t2 = get_mcycle();

    printf("Expected 0x%x\n", expected_pos);
    printf("Checksum 0x%x\n", sw_checksum);
    printf("SW cycles 0x%x\n", t1 - t0);
    printf("HW cycles 0x%x\n", t2 - t1);

    // -------------------------------------------------------------------------
    // Case 1: negative near-overflow
    // -------------------------------------------------------------------------

    printf("Case 1\n");

    t0 = get_mcycle();

    expected_neg = compute_expected_raw(-STRESS_VALUE, STRESS_VALUE);
    sw_checksum  = compute_sw_checksum(-STRESS_VALUE, STRESS_VALUE);

    t1 = get_mcycle();

    write_constant_matrices(-STRESS_VALUE, STRESS_VALUE);
    errors += run_hw_and_check(expected_neg);

    t2 = get_mcycle();

    printf("Expected 0x%x\n", expected_neg);
    printf("Checksum 0x%x\n", sw_checksum);
    printf("SW cycles 0x%x\n", t1 - t0);
    printf("HW cycles 0x%x\n", t2 - t1);

    if (errors == 0) {
        printf("Systolic array overflow test PASSED\n");
    } else {
        printf("Systolic array overflow test FAILED\n");
        printf("Errors 0x%x\n", errors);
    }

    uart_write_flush();

    return errors;
}