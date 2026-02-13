// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0/
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

#include "clint.h"
#include "uart.h"
#include "printf.h"
#include "util.h"

#include "regs/cheshire.h"
#include "params.h"

#define SDHCI_BASE_ADDR 0x01001000

struct sdhc_cfg cfg = {0};

static unsigned int s_Seed = 1;
unsigned int rand(void) {
    s_Seed = s_Seed * 1103515245 + 12345;
    return s_Seed;
}

#define SIZE     512
#define BLOCKS   5
static u_char scratch[SIZE * BLOCKS] = { 0 };
_Static_assert(sizeof(scratch) >= 512, "Scratch buffer needs to be atleast 512bytes");

int test_rw(int size, unsigned int seed) {
    printf("Running read write test with size %d and seed %x\n", size, seed);

    bzero((void*) scratch, size);

    // Reset Block
    if ((rc = sdhc_write(&cfg, 0, scratch, size)) != SDHC_SUCCESS) {
        printf("First sdhc_write failed with RC %d\n", rc);
    }

    memset((void*) scratch, 0xFF, size);

    if ((rc = sdhc_read(&cfg, 0, scratch, size)) != SDHC_SUCCESS) {
        printf("First sdhc_read failed with RC %d\n", rc);
    }

    int err = 0;
    for (size_t i = 0; i < size; ++i) {
        if (scratch[i] != 0) {
            printf("scratch[%d] not as expected, should be zeroed, got %x\n", i, scratch[i]);
            err = 1;
        }
    }
    if (err) return 1;


    s_Seed = seed;
    for (size_t i = 0; i < size; ++i) scratch[i] = rand();

    if ((rc = sdhc_write(&cfg, 0, scratch, size)) != SDHC_SUCCESS) {
        printf("Second sdhc_write failed with RC %d\n", rc);
    }

    memset((void*) scratch, 0xFF, size);

    if ((rc = sdhc_read(&cfg, 0, scratch, size)) != SDHC_SUCCESS) {
        printf("Second sdhc_read failed with RC %d\n", rc);
    }

    s_Seed = seed;
    for (size_t i = 0; i < size; ++i) {
        char exp = rand();
        if (scratch[i] != exp) {
            printf("scratch[%d] not as expected, should be %x, got %x\n", i, exp, scratch[i]);
            err = 1;
        }
    }
    if (err) return 1;

    printf("Succesfuly ran read write test\n");

    return 0;
}

int main() {
    uint32_t rtc_freq = *reg32((unsigned int) &__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, 1000000);

    printf("Hello world!\n");
    uart_write_flush(&__base_uart);

    sdhc_error_e rc = SDHC_SUCCESS;
    if ((rc = sdhc_init_library(&cfg, SDHCI_BASE_ADDR, true)) != SDHC_SUCCESS) {
        printf("Init library failed with RC %d\n", rc);
    }
    if ((rc = sdhc_init_card(&cfg, SDHCI_BASE_ADDR, SDHC_25MHZ)) != SDHC_SUCCESS) {
        printf("Init card failed with RC %d\n", rc);
    }

    // Single block RW
    ASSERT_OK(test_rw(SIZE, 0xDEADBEEF));

    // Multiple block RW
    ASSERT_OK(test_rw(BLOCKS*SIZE, 0x70EDADA1));

    printf("Success\n");
    uart_write_flush(&__base_uart);

    return 0xC007;
}
